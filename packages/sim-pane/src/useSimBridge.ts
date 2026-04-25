import { useCallback, useEffect, useRef, useState } from "react";
import type {
  AXElement,
  AXHitMode,
  AXNode,
  BridgeToPane,
  DeviceInfo,
  DeviceState,
  HardwareButtonKind,
  PaneToBridge,
  SimAppInfo,
} from "./protocol.ts";
import { computePinRanks } from "./lib/computePinRanks.ts";
import { normalizeAxChain, normalizeAxElement } from "./lib/normalizeAx.ts";

export interface SimSnapshot {
  nodes: AXNode[];
  appContext: SimAppInfo | null;
  receivedAt: number;
}

export type SimBridgeStatus = "connecting" | "ready" | "error" | "disconnected";

export interface SimBridgeState {
  status: SimBridgeStatus;
  devices: DeviceInfo[];
  selectedUdid: string | null;
  selectedState: DeviceState;
  bootStatus: string | null;
  displayPixel: { width: number; height: number } | null;
  displayScale: number | null;
  error: { code: string; message: string } | null;
  hoveredHit: { chain: AXElement[]; hitIndex: number } | null;
  /** `pinRanks[i]` identifies which instance of `chain[i].identifier` the
   *  user actually pinned, when the identifier maps to multiple on-screen
   *  instances (e.g., a ForEach of book covers). Scroll-invariant — see
   *  `computePinRanks`. `null` entries fall back to centroid-nearest in
   *  `refreshPinFrames`. Captured at click time from the freshest available
   *  snapshot; late-arriving snapshots resolve nulls if the click-time
   *  frames are still present in the snapshot bucket. */
  selectedHit: {
    chain: AXElement[];
    hitIndex: number;
    pinRanks: (number | null)[];
  } | null;
  /** Monotonic counter bumped only on a fresh `axHitResponse` with `mode != "hover"`
   *  (i.e., a genuine click from the user). Consumers use this for event-driven
   *  side effects (like auto-injecting a @here mention) instead of watching
   *  derived state — state-driven effects re-fire on toggle/mount with the
   *  previous pin and mistakenly treat it as a new click. */
  selectEventSeq: number;
  lastTree: AXElement | null;
  lastSnapshot: SimSnapshot | null;
}

const INITIAL_STATE: SimBridgeState = {
  status: "connecting",
  devices: [],
  selectedUdid: null,
  selectedState: "unknown",
  bootStatus: null,
  displayPixel: null,
  displayScale: null,
  error: null,
  hoveredHit: null,
  selectedHit: null,
  selectEventSeq: 0,
  lastTree: null,
  lastSnapshot: null,
};

interface SimulatorBridge {
  sendMessage: (msg: unknown) => Promise<void>;
  onMessage: (listener: (payload: unknown) => void) => () => void;
  screenshotToClipboard?: (udid: string) => Promise<boolean>;
}

function resolveSimulatorBridge(): SimulatorBridge | null {
  if (typeof window === "undefined") return null;
  const w = window as unknown as { desktopBridge?: { simulator?: SimulatorBridge } };
  return w.desktopBridge?.simulator ?? null;
}

function reduce(state: SimBridgeState, msg: BridgeToPane): SimBridgeState {
  switch (msg.type) {
    case "deviceListResponse": {
      const explicit = state.selectedUdid
        ? (msg.devices.find((device) => device.udid === state.selectedUdid) ?? null)
        : null;
      const autoPick = explicit
        ? null
        : (msg.devices.find((device) => device.state === "booted") ?? msg.devices[0] ?? null);
      const selected = explicit ?? autoPick;
      const selectedUdid = selected?.udid ?? state.selectedUdid;
      const selectedState = selected?.state ?? state.selectedState;
      const bootStatus =
        selected == null
          ? state.bootStatus
          : selectedState === "booted"
            ? "Booted"
            : selectedState === "shutdown" ||
                selectedState === "shuttingDown" ||
                selectedState === "unknown"
              ? null
              : state.bootStatus;
      return {
        ...state,
        devices: msg.devices,
        selectedUdid,
        selectedState,
        bootStatus,
        error: selectedState === "booted" ? null : state.error,
      };
    }
    case "deviceState": {
      const deviceChanged = state.selectedUdid !== null && state.selectedUdid !== msg.udid;
      const leavingBooted = state.selectedState === "booted" && msg.state !== "booted";
      // Any device swap or boot/shutdown transition invalidates pinned
      // selection coordinates — the on-screen content is about to change
      // under the captured frames and a stale outline would render in
      // empty space.
      const resetHits = deviceChanged || leavingBooted;
      return {
        ...state,
        selectedUdid: msg.udid,
        selectedState: msg.state,
        bootStatus: msg.bootStatus,
        error: msg.state === "booted" ? null : state.error,
        ...(resetHits ? { hoveredHit: null, selectedHit: null } : {}),
      };
    }
    case "displayReady":
      return {
        ...state,
        displayPixel: { width: msg.pixelWidth, height: msg.pixelHeight },
        displayScale: msg.scale,
        // Brand-new surface (boot, runtime reattach) invalidates any pin.
        hoveredHit: null,
        selectedHit: null,
      };
    case "displaySurfaceChanged":
      return {
        ...state,
        displayPixel: { width: msg.pixelWidth, height: msg.pixelHeight },
        // Rotation / size-class changes shuffle layout under pinned frames.
        hoveredHit: null,
        selectedHit: null,
      };
    case "axHitResponse": {
      const chain = normalizeAxChain(msg.chain);
      if (msg.mode === "hover") {
        return { ...state, hoveredHit: { chain, hitIndex: msg.hitIndex } };
      }
      const pinRanks = computePinRanks(chain, state.lastSnapshot?.nodes);
      return {
        ...state,
        hoveredHit: { chain, hitIndex: msg.hitIndex },
        selectedHit: { chain, hitIndex: msg.hitIndex, pinRanks },
        // Bump on every genuine click — even one into empty space. Consumers
        // treat this as "user expressed select intent at this point in time"
        // and may choose to act on the new pin (non-empty chain) or no-op
        // (empty chain).
        selectEventSeq: state.selectEventSeq + 1,
      };
    }
    case "axTreeResponse":
      return { ...state, lastTree: normalizeAxElement(msg.root) };
    case "axSnapshotResponse": {
      const lastSnapshot = {
        nodes: msg.nodes,
        appContext: msg.appContext,
        receivedAt: Date.now(),
      };
      // Late-snapshot rank resolution: if the click raced ahead of the first
      // snapshot poll, selectedHit.pinRanks is all-null. The NEXT snapshot
      // to arrive usually still contains the click-time frames (Satira's
      // registry updates in sync with layout passes, 250ms poll cadence is
      // faster than most human scroll gestures). Recompute ranks and latch
      // any non-null entries; leave existing non-null ranks alone so a
      // later stale snapshot can't regress a known-good rank.
      if (state.selectedHit && state.selectedHit.pinRanks.some((r) => r === null)) {
        const candidateRanks = computePinRanks(state.selectedHit.chain, msg.nodes);
        const merged = state.selectedHit.pinRanks.map((existing, i) =>
          existing === null ? (candidateRanks[i] ?? null) : existing,
        );
        if (merged.some((v, i) => v !== state.selectedHit!.pinRanks[i])) {
          return {
            ...state,
            lastSnapshot,
            selectedHit: { ...state.selectedHit, pinRanks: merged },
          };
        }
      }
      return { ...state, lastSnapshot };
    }
    case "error":
      return { ...state, error: { code: msg.code, message: msg.message } };
    default:
      return state;
  }
}

// Exported for tests. Consumers should not call this directly.
export { reduce as __reduceForTest };
export type { BridgeToPane, PaneToBridge };

function coerceToMessage(payload: unknown): BridgeToPane | null {
  if (payload && typeof payload === "object" && "type" in payload) {
    return payload as BridgeToPane;
  }
  if (typeof payload === "string") {
    try {
      return JSON.parse(payload) as BridgeToPane;
    } catch {
      return null;
    }
  }
  return null;
}

export interface UseSimBridgeApi {
  state: SimBridgeState;
  send: (msg: PaneToBridge) => void;
  refreshDevices: () => void;
  bootDevice: (udid: string) => void;
  shutdownDevice: (udid: string) => void;
  selectUdid: (udid: string) => void;
  hitTest: (x: number, y: number, mode?: AXHitMode) => void;
  requestTree: () => void;
  requestSnapshot: () => void;
  pressButton: (kind: HardwareButtonKind, down: boolean) => void;
  tapButton: (kind: HardwareButtonKind) => void;
  rotate: (orientation: number) => void;
  /** Capture a PNG screenshot of the booted simulator and copy it to the
   *  macOS clipboard. Resolves to `true` on success. No-op when the host
   *  doesn't expose the capability or no device is selected. */
  screenshotToClipboard: () => Promise<boolean>;
  enableAx: () => void;
  /** Drop both hoveredHit and selectedHit without bumping `selectEventSeq`.
   *  Used when inspect mode toggles off or the user explicitly deselects.
   *  Does NOT trigger auto-inject because seq is unchanged. */
  clearSelection: () => void;
}

export function useSimBridge(): UseSimBridgeApi {
  const [state, setState] = useState<SimBridgeState>(INITIAL_STATE);
  const bridgeRef = useRef<SimulatorBridge | null>(null);
  // Tracks which udid we've already issued a `deviceBoot` for in this
  // session, so the auto-wire effect doesn't spam the daemon on every
  // `deviceListResponse`. Cleared when the pane unmounts.
  const wiredUdidRef = useRef<string | null>(null);

  const send = useCallback((msg: PaneToBridge): void => {
    const bridge = bridgeRef.current;
    if (!bridge) return;
    void bridge.sendMessage(msg);
  }, []);

  useEffect(() => {
    const bridge = resolveSimulatorBridge();
    bridgeRef.current = bridge;
    if (!bridge) {
      setState((s) => ({ ...s, status: "error" }));
      return;
    }

    const unsubscribe = bridge.onMessage((payload) => {
      const msg = coerceToMessage(payload);
      if (!msg) return;
      setState((s) => reduce(s, msg));
    });

    setState((s) => ({ ...s, status: "ready" }));
    void bridge.sendMessage({ type: "deviceList" } satisfies PaneToBridge);

    return () => {
      unsubscribe();
      bridgeRef.current = null;
      wiredUdidRef.current = null;
    };
  }, []);

  // Auto-wire the display when we land on a device that simctl says is
  // already booted but the daemon hasn't published a display surface for.
  // This happens when sim-bridge is (re)spawned while the iOS runtime is
  // still live — e.g. after `desktop:reinstall-current` kills the daemon
  // without shutting down simctl. Without this the pane stays black and
  // "Stop" is a no-op (the daemon's `currentDevice` is nil, so it has no
  // session to tear down). Sending `deviceBoot` is idempotent: the daemon's
  // `startDevice` adopts the already-booted runtime and wires the display.
  useEffect(() => {
    if (state.status !== "ready") return;
    const { selectedUdid, selectedState, displayPixel } = state;
    if (!selectedUdid || selectedState !== "booted" || displayPixel !== null) return;
    if (wiredUdidRef.current === selectedUdid) return;
    wiredUdidRef.current = selectedUdid;
    send({ type: "deviceBoot", udid: selectedUdid });
  }, [state, send]);

  const refreshDevices = useCallback(() => send({ type: "deviceList" }), [send]);

  const bootDevice = useCallback(
    (udid: string) => {
      setState((s) => ({
        ...s,
        selectedUdid: udid,
        selectedState: "booting",
        bootStatus: "Starting",
      }));
      send({ type: "deviceBoot", udid });
    },
    [send],
  );

  const shutdownDevice = useCallback(
    (udid: string) => send({ type: "deviceShutdown", udid }),
    [send],
  );

  const selectUdid = useCallback((udid: string) => {
    setState((s) => (s.selectedUdid === udid ? s : { ...s, selectedUdid: udid }));
  }, []);

  const hitTest = useCallback(
    (x: number, y: number, mode: AXHitMode = "select") => send({ type: "axHit", x, y, mode }),
    [send],
  );

  const requestTree = useCallback(() => send({ type: "axTree" }), [send]);

  const requestSnapshot = useCallback(() => send({ type: "axSnapshot" }), [send]);

  const pressButton = useCallback(
    (kind: HardwareButtonKind, down: boolean) => send({ type: "inputButton", kind, down }),
    [send],
  );

  const tapButton = useCallback(
    (kind: HardwareButtonKind) => {
      send({ type: "inputButton", kind, down: true });
      setTimeout(() => send({ type: "inputButton", kind, down: false }), 40);
    },
    [send],
  );

  const rotate = useCallback(
    (orientation: number) => send({ type: "rotate", orientation }),
    [send],
  );

  const screenshotToClipboard = useCallback(async (): Promise<boolean> => {
    const bridge = bridgeRef.current;
    if (!bridge?.screenshotToClipboard) return false;
    const udid = state.selectedUdid;
    if (!udid) return false;
    try {
      return await bridge.screenshotToClipboard(udid);
    } catch (error) {
      // eslint-disable-next-line no-console
      console.warn("[sim-bridge] screenshotToClipboard failed", error);
      return false;
    }
  }, [state.selectedUdid]);

  const enableAx = useCallback(() => send({ type: "axEnable" }), [send]);

  const clearSelection = useCallback(() => {
    setState((s) =>
      s.hoveredHit === null && s.selectedHit === null
        ? s
        : { ...s, hoveredHit: null, selectedHit: null },
    );
  }, []);

  return {
    state,
    send,
    refreshDevices,
    bootDevice,
    shutdownDevice,
    selectUdid,
    hitTest,
    requestTree,
    requestSnapshot,
    pressButton,
    tapButton,
    rotate,
    screenshotToClipboard,
    enableAx,
    clearSelection,
  };
}
