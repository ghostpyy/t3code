export const SIM_BRIDGE_DEFAULT_PORT = 17323;

export type SourceRef = {
  readonly file: string;
  readonly line: number;
  readonly function?: string;
  readonly kind?: string;
  readonly name?: string;
  readonly role?: string;
  readonly title?: string;
  readonly value?: string;
  readonly help?: string;
  readonly identifier?: string;
};

export type Frame = {
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
};

export type AXNode = SourceRef & {
  readonly frame: Frame;
};

export type SimInfo = {
  readonly udid: string;
  readonly name: string;
  readonly model: string;
  readonly status: "booted" | "shutdown" | "unknown";
  readonly screenW: number;
  readonly screenH: number;
};

export type BridgeToPane =
  | {
      readonly type: "frame";
      readonly image: string;
      readonly mime: string;
      readonly w: number;
      readonly h: number;
      readonly ts: number;
    }
  | { readonly type: "ax-snapshot"; readonly nodes: ReadonlyArray<AXNode>; readonly ts: number }
  | {
      readonly type: "source-clicked";
      readonly ref: SourceRef;
      readonly frame: Frame;
      readonly ts: number;
    }
  | { readonly type: "sim-info"; readonly info: SimInfo }
  | { readonly type: "error"; readonly message: string }
  | {
      readonly type: "inspect-result";
      readonly requestId: string;
      readonly ref: SourceRef | null;
    };

export type PaneToBridge =
  | { readonly type: "tap"; readonly x: number; readonly y: number }
  | {
      readonly type: "drag";
      readonly fromX: number;
      readonly fromY: number;
      readonly toX: number;
      readonly toY: number;
      readonly durationMs: number;
    }
  | { readonly type: "type-text"; readonly text: string }
  | { readonly type: "press-key"; readonly key: string }
  | {
      readonly type: "inspect-at";
      readonly x: number;
      readonly y: number;
      readonly requestId: string;
    }
  | { readonly type: "subscribe-frames"; readonly fps: number }
  | { readonly type: "subscribe-ax"; readonly intervalMs: number };

export const SOURCE_REFERENCE_EVENT = "simpane:source-reference";
export const OPEN_SOURCE_EVENT = "simpane:open-source";

export type SourceReferenceEventDetail = {
  readonly ref: SourceRef;
  readonly label: string;
};

export type OpenSourceEventDetail = {
  readonly ref: SourceRef;
  readonly url: string;
};

export function sourceRefLabel(ref: SourceRef): string {
  if (ref.file && ref.line > 0) {
    const where = `${ref.file}:${ref.line}`;
    if (ref.name && ref.name.length > 0) return `${ref.kind ?? "view"} ${ref.name} (${where})`;
    if (ref.kind && ref.kind.length > 0) return `${ref.kind} (${where})`;
    return where;
  }
  const role = (ref.role ?? "AXElement").replace(/^AX/, "");
  const label = ref.title ?? ref.value ?? ref.identifier ?? "";
  return label ? `${role} \u201C${label}\u201D` : role;
}

export function sourceRefHasLocation(ref: SourceRef): boolean {
  return Boolean(ref.file) && ref.line > 0;
}

export function isAbsolutePath(file: string): boolean {
  return file.startsWith("/") || /^[a-zA-Z]:\\/.test(file);
}

export function openSourceUrl(ref: SourceRef, scheme: string = "cursor"): string | null {
  if (!isAbsolutePath(ref.file)) return null;
  return `${scheme}://file/${ref.file}:${ref.line}`;
}
