import { useCallback, useEffect, useRef, useState } from "react";
import {
  SIM_BRIDGE_DEFAULT_PORT,
  type AXNode,
  type BridgeToPane,
  type PaneToBridge,
  type SimInfo,
  type SourceRef,
} from "./protocol.ts";

export type ConnectionState = "idle" | "connecting" | "open" | "closed" | "error";

export type SimBridgeState = {
  readonly state: ConnectionState;
  readonly lastError: string | null;
  readonly info: SimInfo | null;
  readonly frameImageUrl: string | null;
  readonly frameSize: { w: number; h: number } | null;
  readonly axNodes: ReadonlyArray<AXNode>;
  readonly lastClicked: SourceRef | null;
};

export type SimBridgeApi = SimBridgeState & {
  readonly send: (msg: PaneToBridge) => void;
  readonly inspectAt: (x: number, y: number) => Promise<SourceRef | null>;
  readonly tap: (x: number, y: number) => void;
};

export type UseSimBridgeOptions = {
  readonly url?: string;
  readonly autoSubscribeFps?: number;
  readonly autoSubscribeAxIntervalMs?: number;
};

export function useSimBridge(options: UseSimBridgeOptions = {}): SimBridgeApi {
  const url = options.url ?? `ws://127.0.0.1:${SIM_BRIDGE_DEFAULT_PORT}`;
  const fps = options.autoSubscribeFps ?? 30;
  const axMs = options.autoSubscribeAxIntervalMs ?? 500;

  const wsRef = useRef<WebSocket | null>(null);
  const inspectPromisesRef = useRef<Map<string, (ref: SourceRef | null) => void>>(new Map());
  const lastFrameUrlRef = useRef<string | null>(null);
  const reconnectTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const [state, setState] = useState<ConnectionState>("idle");
  const [lastError, setLastError] = useState<string | null>(null);
  const [info, setInfo] = useState<SimInfo | null>(null);
  const [frameImageUrl, setFrameImageUrl] = useState<string | null>(null);
  const [frameSize, setFrameSize] = useState<{ w: number; h: number } | null>(null);
  const [axNodes, setAxNodes] = useState<ReadonlyArray<AXNode>>([]);
  const [lastClicked, setLastClicked] = useState<SourceRef | null>(null);

  const send = useCallback((msg: PaneToBridge): void => {
    const ws = wsRef.current;
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify(msg));
  }, []);

  const inspectAt = useCallback(
    (x: number, y: number): Promise<SourceRef | null> => {
      const requestId = crypto.randomUUID();
      return new Promise((resolve) => {
        inspectPromisesRef.current.set(requestId, resolve);
        send({ type: "inspect-at", x, y, requestId });
        setTimeout(() => {
          if (inspectPromisesRef.current.delete(requestId)) resolve(null);
        }, 1500);
      });
    },
    [send],
  );

  const tap = useCallback(
    (x: number, y: number): void => {
      send({ type: "tap", x, y });
    },
    [send],
  );

  useEffect(() => {
    let cancelled = false;
    let activeWs: WebSocket | null = null;

    const handleOpen = (): void => {
      if (cancelled || !activeWs) return;
      setState("open");
      activeWs.send(JSON.stringify({ type: "subscribe-frames", fps } satisfies PaneToBridge));
      activeWs.send(
        JSON.stringify({ type: "subscribe-ax", intervalMs: axMs } satisfies PaneToBridge),
      );
    };

    const handleMessage = (ev: MessageEvent): void => {
      if (typeof ev.data !== "string") return;
      let msg: BridgeToPane;
      try {
        msg = JSON.parse(ev.data) as BridgeToPane;
      } catch {
        return;
      }
      switch (msg.type) {
        case "frame": {
          const blob = base64ToBlob(msg.image, msg.mime || "image/jpeg");
          const objectUrl = URL.createObjectURL(blob);
          const prev = lastFrameUrlRef.current;
          lastFrameUrlRef.current = objectUrl;
          setFrameImageUrl(objectUrl);
          setFrameSize({ w: msg.w, h: msg.h });
          if (prev) URL.revokeObjectURL(prev);
          return;
        }
        case "ax-snapshot":
          setAxNodes(msg.nodes);
          return;
        case "source-clicked":
          setLastClicked(msg.ref);
          return;
        case "sim-info":
          setInfo(msg.info);
          return;
        case "error":
          setLastError(msg.message);
          return;
        case "inspect-result": {
          const resolve = inspectPromisesRef.current.get(msg.requestId);
          if (resolve) {
            inspectPromisesRef.current.delete(msg.requestId);
            resolve(msg.ref);
          }
          return;
        }
      }
    };

    const handleError = (): void => {
      if (cancelled) return;
      setLastError("WebSocket error");
      setState("error");
    };

    const handleClose = (): void => {
      if (cancelled) return;
      setState("closed");
      scheduleReconnect();
    };

    const detach = (ws: WebSocket): void => {
      ws.removeEventListener("open", handleOpen);
      ws.removeEventListener("message", handleMessage);
      ws.removeEventListener("error", handleError);
      ws.removeEventListener("close", handleClose);
    };

    const connect = (): void => {
      if (cancelled) return;
      setState("connecting");
      setLastError(null);

      let ws: WebSocket;
      try {
        ws = new WebSocket(url);
      } catch (err) {
        setLastError(err instanceof Error ? err.message : "Failed to construct WebSocket");
        setState("error");
        scheduleReconnect();
        return;
      }
      activeWs = ws;
      wsRef.current = ws;
      ws.binaryType = "arraybuffer";

      ws.addEventListener("open", handleOpen);
      ws.addEventListener("message", handleMessage);
      ws.addEventListener("error", handleError);
      ws.addEventListener("close", handleClose);
    };

    const scheduleReconnect = (): void => {
      if (cancelled) return;
      if (reconnectTimerRef.current) clearTimeout(reconnectTimerRef.current);
      reconnectTimerRef.current = setTimeout(connect, 1500);
    };

    connect();

    return (): void => {
      cancelled = true;
      if (reconnectTimerRef.current) clearTimeout(reconnectTimerRef.current);
      const ws = wsRef.current;
      wsRef.current = null;
      if (ws) {
        detach(ws);
        ws.close();
      }
      activeWs = null;
      const lastUrl = lastFrameUrlRef.current;
      lastFrameUrlRef.current = null;
      if (lastUrl) URL.revokeObjectURL(lastUrl);
    };
  }, [url, fps, axMs]);

  return {
    state,
    lastError,
    info,
    frameImageUrl,
    frameSize,
    axNodes,
    lastClicked,
    send,
    inspectAt,
    tap,
  };
}

function base64ToBlob(b64: string, mime: string): Blob {
  const bin = atob(b64);
  const len = bin.length;
  const buf = new Uint8Array(len);
  for (let i = 0; i < len; i++) buf[i] = bin.charCodeAt(i);
  return new Blob([buf], { type: mime });
}
