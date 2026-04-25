#!/usr/bin/env node
// Standalone smoke test for SimBridge.app:
//  1. Spawn the bundled binary on port 17323
//  2. Connect via WebSocket
//  3. Subscribe to frames + AX, request sim-info + permission-state
//  4. Print arrivals for 6 seconds, then exit non-zero if anything critical missing.
import { spawn } from "node:child_process";
import { setTimeout as wait } from "node:timers/promises";
import Path from "node:path";
import { fileURLToPath } from "node:url";
// Node 22+ ships native WebSocket on globalThis.

const HERE = Path.dirname(fileURLToPath(import.meta.url));
const ROOT = Path.resolve(HERE, "..");
const BINARY = Path.join(
  ROOT,
  ".build",
  "release",
  "SimBridge.app",
  "Contents",
  "MacOS",
  "sim-bridge",
);
const PORT = Number(process.env.SIM_BRIDGE_PORT) || 17323;

const counts = Object.create(null);
const samples = Object.create(null);
let bridgeStdoutFirstLine = null;
let connected = false;

function bump(type, payload) {
  counts[type] = (counts[type] ?? 0) + 1;
  if (!(type in samples)) samples[type] = payload;
}

console.log(`[probe] spawning ${BINARY}`);
const child = spawn(BINARY, ["--port", String(PORT)], {
  stdio: ["ignore", "pipe", "pipe"],
});
child.stdout.on("data", (d) => {
  if (!bridgeStdoutFirstLine) bridgeStdoutFirstLine = d.toString().split("\n")[0];
  process.stderr.write(`[bridge:stdout] ${d}`);
});
child.stderr.on("data", (d) => {
  process.stderr.write(`[bridge:stderr] ${d}`);
});
child.on("exit", (code, sig) => {
  console.log(`[probe] bridge exited code=${code} sig=${sig}`);
});

await wait(700);

let ws;
try {
  ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
} catch (err) {
  console.error("[probe] failed to construct WebSocket:", err);
  process.exit(2);
}

ws.addEventListener("open", () => {
  connected = true;
  console.log("[probe] WebSocket open; sending subscribe + request messages");
  ws.send(JSON.stringify({ type: "subscribe-frames", fps: 10 }));
  ws.send(JSON.stringify({ type: "subscribe-ax", intervalMs: 500 }));
  ws.send(JSON.stringify({ type: "request-permission-state" }));
  ws.send(JSON.stringify({ type: "request-sim-info" }));
});
ws.addEventListener("message", (event) => {
  const text =
    typeof event.data === "string" ? event.data : Buffer.from(event.data).toString("utf8");
  let msg;
  try {
    msg = JSON.parse(text);
  } catch {
    bump("non-json", text.slice(0, 80));
    return;
  }
  bump(msg.type, summarize(msg));
});
ws.addEventListener("error", (event) => console.error("[probe] ws error event"));
ws.addEventListener("close", (event) => console.log(`[probe] ws closed code=${event.code}`));

function summarize(msg) {
  switch (msg.type) {
    case "frame":
      return { mime: msg.mime, w: msg.w, h: msg.h, base64Len: (msg.image ?? "").length };
    case "ax-snapshot":
      return { count: (msg.nodes ?? []).length, sample: msg.nodes?.[0] };
    case "sim-info":
      return msg.info;
    case "permission-state":
      return msg.state;
    case "inspect-result":
      return msg;
    case "error":
      return msg.message;
    default:
      return msg;
  }
}

await wait(6000);

console.log("\n[probe] === RESULT ===");
console.log(`[probe] connected: ${connected}`);
console.log("[probe] message counts:", counts);
for (const [k, v] of Object.entries(samples)) {
  let pretty;
  try {
    pretty = JSON.stringify(v, null, 2);
  } catch {
    pretty = String(v);
  }
  console.log(`[probe] sample ${k}:\n${pretty}`);
}

ws.close();
child.kill("SIGTERM");
await wait(400);
if (!child.killed) child.kill("SIGKILL");

const ok = connected && counts["sim-info"] >= 1 && counts["permission-state"] >= 1;
process.exit(ok ? 0 : 1);
