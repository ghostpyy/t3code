import type { AXElement, AXFrame, AXSourceHint, SimAppInfo } from "../protocol.ts";

type RawNestedFrame = { origin: { x: number; y: number }; size: { width: number; height: number } };

function isNestedFrame(value: unknown): value is RawNestedFrame {
  if (!value || typeof value !== "object") return false;
  const f = value as Record<string, unknown>;
  return (
    typeof f.origin === "object" &&
    f.origin !== null &&
    typeof f.size === "object" &&
    f.size !== null
  );
}

function toFrame(raw: unknown): AXFrame {
  if (isNestedFrame(raw)) {
    const { origin, size } = raw;
    const cr = toCornerRadius((raw as { cornerRadius?: unknown }).cornerRadius);
    return {
      x: Number(origin.x) || 0,
      y: Number(origin.y) || 0,
      width: Number(size.width) || 0,
      height: Number(size.height) || 0,
      ...(cr != null ? { cornerRadius: cr } : {}),
    };
  }
  if (raw && typeof raw === "object") {
    const f = raw as Partial<AXFrame>;
    const cr = toCornerRadius((raw as { cornerRadius?: unknown }).cornerRadius);
    return {
      x: Number(f.x) || 0,
      y: Number(f.y) || 0,
      width: Number(f.width) || 0,
      height: Number(f.height) || 0,
      ...(cr != null ? { cornerRadius: cr } : {}),
    };
  }
  return { x: 0, y: 0, width: 0, height: 0 };
}

function toCornerRadius(raw: unknown): number | null {
  if (typeof raw !== "number" || !Number.isFinite(raw) || raw <= 0) return null;
  return raw;
}

function toAppContext(raw: unknown): SimAppInfo | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Partial<SimAppInfo>;
  if (typeof r.bundleId !== "string" || r.bundleId.length === 0) return null;
  return {
    bundleId: r.bundleId,
    name: typeof r.name === "string" ? r.name : null,
    pid: typeof r.pid === "number" ? r.pid : 0,
    bundlePath: typeof r.bundlePath === "string" ? r.bundlePath : null,
    dataContainer: typeof r.dataContainer === "string" ? r.dataContainer : null,
    executablePath: typeof r.executablePath === "string" ? r.executablePath : null,
    projectPath: typeof r.projectPath === "string" ? r.projectPath : null,
  };
}

function toSourceHints(raw: unknown): AXSourceHint[] | null {
  if (!Array.isArray(raw)) return null;
  const hints = raw.flatMap((item) => {
    if (!item || typeof item !== "object") return [];
    const hint = item as Partial<AXSourceHint>;
    if (typeof hint.absolutePath !== "string" || hint.absolutePath.length === 0) return [];
    if (typeof hint.line !== "number" || hint.line <= 0) return [];
    return [
      {
        absolutePath: hint.absolutePath,
        line: hint.line,
        reason: typeof hint.reason === "string" ? hint.reason : "",
        confidence: typeof hint.confidence === "number" ? hint.confidence : 0,
      },
    ];
  });
  return hints.length > 0 ? hints : null;
}

/** Swift's `CGRect` Codable synthesis emits `{origin:{x,y},size:{w,h}}`; our
 *  wire format is `{x,y,width,height}`. Accept both. */
export function normalizeAxElement(raw: unknown): AXElement {
  const r = (raw ?? {}) as Record<string, unknown>;
  const children = Array.isArray(r.children) ? r.children.map(normalizeAxElement) : null;
  return {
    id: String(r.id ?? ""),
    role: typeof r.role === "string" ? r.role : "unknown",
    label: typeof r.label === "string" ? r.label : null,
    value: typeof r.value === "string" ? r.value : null,
    frame: toFrame(r.frame),
    identifier: typeof r.identifier === "string" ? r.identifier : null,
    enabled: Boolean(r.enabled),
    selected: Boolean(r.selected),
    children,
    appContext: toAppContext((r as { appContext?: unknown }).appContext),
    sourceHints: toSourceHints((r as { sourceHints?: unknown }).sourceHints),
  };
}

/** Dedupe the hit chain before it enters reducer state. An element that
 *  ships the same `identifier` and the same `frame` in two chain slots is
 *  the same on-screen element twice — SwiftUI's anchor pipeline can emit
 *  one per render pass (containers + leaves sharing a `.inspectable()`),
 *  and without this the inspector card shows doubled rows and the outline
 *  layer gets redundant writes for the same rect. Entries differing by
 *  position survive — those are genuinely distinct instances of the same
 *  source anchor, like a book cover repeated down a timeline list.
 *  First occurrence wins so the innermost-first ordering from the daemon
 *  is preserved. */
export function normalizeAxChain(raw: unknown): AXElement[] {
  if (!Array.isArray(raw)) return [];
  const out: AXElement[] = [];
  const seen = new Set<string>();
  for (const entry of raw) {
    const el = normalizeAxElement(entry);
    const key = `${el.identifier ?? el.id}|${el.frame.x}|${el.frame.y}|${el.frame.width}|${el.frame.height}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(el);
  }
  return out;
}
