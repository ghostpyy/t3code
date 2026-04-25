export const SIM_BRIDGE_DEFAULT_PORT = 17323;

export type DeviceState =
  | "shutdown"
  | "booting"
  | "booted"
  | "shuttingDown"
  | "creating"
  | "unknown";

export interface DeviceInfo {
  udid: string;
  name: string;
  runtime: string;
  model: string;
  state: DeviceState;
}

export interface AXFrame {
  x: number;
  y: number;
  width: number;
  height: number;
  /** Corner radius of the backing iOS view (display points). Forwarded to
   *  the native picker so the outline shape matches the element — rounded
   *  for squircle buttons and material cards, zero for plain rectangles. */
  cornerRadius?: number;
}

export interface SimAppInfo {
  bundleId: string;
  name: string | null;
  pid: number;
  bundlePath: string | null;
  dataContainer: string | null;
  executablePath: string | null;
  projectPath: string | null;
}

export interface AXSourceHint {
  absolutePath: string;
  line: number;
  reason: string;
  confidence: number;
  /** Raw source neighborhood (newline-joined) centered on `line`. Only set
   *  when the bridge could read the file; unresolved hints stay terse. */
  snippet?: string | null;
  /** 1-indexed file line matching the first row of `snippet`. */
  snippetStartLine?: number | null;
}

export interface AXElement {
  id: string;
  role: string;
  label: string | null;
  value: string | null;
  frame: AXFrame;
  identifier: string | null;
  enabled: boolean;
  selected: boolean;
  children: AXElement[] | null;
  appContext: SimAppInfo | null;
  sourceHints: AXSourceHint[] | null;
}

/** Flat BFS node for the full-snapshot feed. Mirrors `AXNode` in the bridge
 *  — the pane rebuilds topology via `parentId` instead of shipping nested
 *  trees, which keeps the outline overlay + gap math cheap. */
export interface AXNode {
  id: string;
  parentId: string | null;
  role: string;
  label: string | null;
  value: string | null;
  identifier: string | null;
  frame: AXFrame;
  enabled: boolean;
  selected: boolean;
}

/** Parsed from `.inspectable()`'s `accessibilityIdentifier` stamp.
 *  Format: `ModuleName/File.swift:42` or `ModuleName/File.swift:42|name=Alias`. */
export interface InspectableAnchor {
  module: string | null;
  file: string;
  line: number;
  alias: string | null;
  sourcePath: string;
  absolutePath: string | null;
}

export type AXHitMode = "hover" | "select";

export type HardwareButtonKind = "home" | "lock" | "siri" | "side" | "applePay" | "keyboard";

export type PaneToBridge =
  | { type: "deviceList" }
  | { type: "deviceBoot"; udid: string }
  | { type: "deviceShutdown"; udid: string }
  | { type: "inputTap"; x: number; y: number; phase: "down" | "up" }
  | { type: "inputDrag"; points: { x: number; y: number; t: number }[] }
  | { type: "inputKey"; usage: number; down: boolean; modifiers: number }
  | { type: "inputButton"; kind: HardwareButtonKind; down: boolean }
  | { type: "axEnable" }
  | { type: "axHit"; x: number; y: number; mode: AXHitMode }
  | { type: "axTree" }
  | { type: "axSnapshot" }
  | { type: "axAction"; elementId: string; action: string }
  | { type: "rotate"; orientation: number };

export type BridgeToPane =
  | { type: "deviceListResponse"; devices: DeviceInfo[] }
  | { type: "deviceState"; udid: string; state: DeviceState; bootStatus: string | null }
  | {
      type: "displayReady";
      contextId: number;
      pixelWidth: number;
      pixelHeight: number;
      scale: number;
    }
  | { type: "displaySurfaceChanged"; pixelWidth: number; pixelHeight: number }
  | { type: "axHitResponse"; chain: AXElement[]; hitIndex: number; mode: AXHitMode }
  | { type: "axTreeResponse"; root: AXElement }
  | {
      type: "axSnapshotResponse";
      nodes: AXNode[];
      appContext: SimAppInfo | null;
    }
  | { type: "error"; code: string; message: string; detail?: Record<string, string> };
