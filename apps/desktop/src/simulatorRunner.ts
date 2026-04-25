import * as ChildProcess from "node:child_process";
import * as FS from "node:fs";
import * as Path from "node:path";

const SIM_BRIDGE_PORT = 17323;
const RESTART_BACKOFF_MS = 1500;
const RESTART_BACKOFF_CAP_MS = 15_000;
const TERMINATE_TIMEOUT_MS = 2_000;

const WS_CONNECT_INITIAL_DELAY_MS = 500;
const WS_CONNECT_BACKOFF_MS = 1_000;
const WS_CONNECT_BACKOFF_CAP_MS = 10_000;

let bridgeProcess: ChildProcess.ChildProcess | null = null;
let restartTimer: NodeJS.Timeout | null = null;
let restartAttempt = 0;
let stopping = false;

type DaemonMessageHandler = (msg: unknown) => void;

interface BridgeClient {
  socket: WebSocket | null;
  reconnectTimer: NodeJS.Timeout | null;
  reconnectAttempt: number;
  outboundQueue: string[];
}

const client: BridgeClient = {
  socket: null,
  reconnectTimer: null,
  reconnectAttempt: 0,
  outboundQueue: [],
};

const daemonMessageHandlers = new Set<DaemonMessageHandler>();

export function startSimBridge(repoRoot: string, resourcesPath: string): void {
  if (process.platform !== "darwin") return;
  if (bridgeProcess || stopping) return;

  const binary = resolveBridgeBinary(repoRoot, resourcesPath);
  if (!binary) {
    console.warn(
      "[sim-bridge] SimBridge.app not found. Run `cd apps/sim-bridge && bash scripts/build-app-bundle.sh` to build it.",
    );
    return;
  }

  console.info(`[sim-bridge] launching ${binary}`);
  let child: ChildProcess.ChildProcess;
  try {
    child = ChildProcess.spawn(binary, ["--port", String(SIM_BRIDGE_PORT)], {
      stdio: ["ignore", "pipe", "pipe"],
      detached: false,
    });
  } catch (error) {
    console.error("[sim-bridge] failed to spawn:", error);
    scheduleRestart(repoRoot, resourcesPath, "spawn-error");
    return;
  }

  bridgeProcess = child;
  restartAttempt = 0;

  child.stdout?.on("data", (chunk) => {
    process.stderr.write(`[sim-bridge:stdout] ${chunk}`);
  });
  child.stderr?.on("data", (chunk) => {
    process.stderr.write(`[sim-bridge:stderr] ${chunk}`);
  });

  child.on("exit", (code, signal) => {
    if (bridgeProcess === child) bridgeProcess = null;
    teardownWsClient();
    if (stopping) return;
    console.warn(`[sim-bridge] exited code=${code} signal=${signal}`);
    scheduleRestart(repoRoot, resourcesPath, `exit:${code ?? signal ?? "?"}`);
  });

  child.on("error", (error) => {
    console.error("[sim-bridge] error:", error);
  });

  scheduleWsConnect(WS_CONNECT_INITIAL_DELAY_MS);
}

export function stopSimBridge(): void {
  stopping = true;
  if (restartTimer) {
    clearTimeout(restartTimer);
    restartTimer = null;
  }
  teardownWsClient();
  const child = bridgeProcess;
  bridgeProcess = null;
  if (!child) return;

  console.info("[sim-bridge] terminating");
  try {
    child.kill("SIGTERM");
  } catch (error) {
    console.warn("[sim-bridge] SIGTERM failed:", error);
  }

  const killTimer = setTimeout(() => {
    try {
      if (!child.killed) child.kill("SIGKILL");
    } catch (error) {
      console.warn("[sim-bridge] SIGKILL failed:", error);
    }
  }, TERMINATE_TIMEOUT_MS);
  killTimer.unref();
}

/**
 * Register a callback that receives every JSON frame the daemon sends on the
 * WebSocket. Returns a function that unregisters the handler. Safe to call
 * before {@link startSimBridge}; handlers persist across reconnects.
 */
export function onDaemonMessage(handler: DaemonMessageHandler): () => void {
  daemonMessageHandlers.add(handler);
  return () => {
    daemonMessageHandlers.delete(handler);
  };
}

/**
 * Send a JSON-serializable frame to the daemon. If the socket is not yet open
 * the frame is queued and flushed once the connection is established.
 */
export function sendToDaemon(msg: unknown): void {
  let serialized: string;
  try {
    serialized = JSON.stringify(msg);
  } catch (error) {
    console.warn("[sim-bridge] failed to serialize daemon message:", error);
    return;
  }

  const socket = client.socket;
  if (socket && socket.readyState === 1 /* OPEN */) {
    try {
      socket.send(serialized);
      return;
    } catch (error) {
      console.warn("[sim-bridge] socket send failed:", error);
    }
  }

  // Bound the queue to avoid unbounded growth if the daemon is unreachable.
  if (client.outboundQueue.length >= 512) {
    client.outboundQueue.shift();
  }
  client.outboundQueue.push(serialized);
}

function scheduleWsConnect(delayMs: number): void {
  if (stopping) return;
  if (client.reconnectTimer) return;
  client.reconnectTimer = setTimeout(() => {
    client.reconnectTimer = null;
    openWsClient();
  }, delayMs);
  client.reconnectTimer.unref();
}

function openWsClient(): void {
  if (stopping || client.socket) return;

  let socket: WebSocket;
  try {
    socket = new WebSocket(`ws://127.0.0.1:${SIM_BRIDGE_PORT}`);
  } catch (error) {
    console.warn("[sim-bridge] failed to construct WebSocket:", error);
    scheduleWsReconnect();
    return;
  }

  client.socket = socket;

  socket.addEventListener("open", () => {
    client.reconnectAttempt = 0;
    flushQueuedMessages();
  });

  socket.addEventListener("message", (event: MessageEvent) => {
    const data = event.data;
    const text = typeof data === "string" ? data : null;
    if (text === null) return;

    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch (error) {
      console.warn("[sim-bridge] dropped malformed frame:", error);
      return;
    }
    for (const handler of daemonMessageHandlers) {
      try {
        handler(parsed);
      } catch (error) {
        console.warn("[sim-bridge] daemon message handler threw:", error);
      }
    }
  });

  socket.addEventListener("error", () => {
    // The close handler runs after error; log once there to avoid duplicates.
  });

  socket.addEventListener("close", () => {
    if (client.socket === socket) client.socket = null;
    scheduleWsReconnect();
  });
}

function scheduleWsReconnect(): void {
  if (stopping) return;
  const delay = Math.min(
    WS_CONNECT_BACKOFF_MS * 2 ** client.reconnectAttempt,
    WS_CONNECT_BACKOFF_CAP_MS,
  );
  client.reconnectAttempt += 1;
  scheduleWsConnect(delay);
}

function flushQueuedMessages(): void {
  const socket = client.socket;
  if (!socket || socket.readyState !== 1) return;
  const queue = client.outboundQueue;
  client.outboundQueue = [];
  for (const message of queue) {
    try {
      socket.send(message);
    } catch (error) {
      console.warn("[sim-bridge] failed to flush queued message:", error);
      // Preserve unsent frames at the head of the queue.
      client.outboundQueue.unshift(message);
      break;
    }
  }
}

function teardownWsClient(): void {
  if (client.reconnectTimer) {
    clearTimeout(client.reconnectTimer);
    client.reconnectTimer = null;
  }
  const socket = client.socket;
  client.socket = null;
  client.reconnectAttempt = 0;
  if (socket) {
    try {
      socket.close();
    } catch {
      /* already closed */
    }
  }
}

function scheduleRestart(repoRoot: string, resourcesPath: string, reason: string): void {
  if (stopping || restartTimer) return;
  const delay = Math.min(RESTART_BACKOFF_MS * 2 ** restartAttempt, RESTART_BACKOFF_CAP_MS);
  restartAttempt += 1;
  console.warn(`[sim-bridge] restarting in ${delay}ms (reason=${reason})`);
  restartTimer = setTimeout(() => {
    restartTimer = null;
    startSimBridge(repoRoot, resourcesPath);
  }, delay);
  restartTimer.unref();
}

function resolveBridgeBinary(repoRoot: string, resourcesPath: string): string | null {
  const candidates = [
    Path.join(resourcesPath, "SimBridge.app", "Contents", "MacOS", "sim-bridge"),
    Path.join(resourcesPath, "sim-bridge"),
    Path.join(
      repoRoot,
      "apps",
      "sim-bridge",
      ".build",
      "release",
      "SimBridge.app",
      "Contents",
      "MacOS",
      "sim-bridge",
    ),
    Path.join(
      repoRoot,
      "apps",
      "sim-bridge",
      ".build",
      "arm64-apple-macosx",
      "release",
      "SimBridge.app",
      "Contents",
      "MacOS",
      "sim-bridge",
    ),
    Path.join(repoRoot, "apps", "sim-bridge", ".build", "release", "sim-bridge"),
    Path.join(
      repoRoot,
      "apps",
      "sim-bridge",
      ".build",
      "arm64-apple-macosx",
      "release",
      "sim-bridge",
    ),
  ];
  for (const candidate of candidates) {
    if (FS.existsSync(candidate)) return candidate;
  }
  return null;
}
