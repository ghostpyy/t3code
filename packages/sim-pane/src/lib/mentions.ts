import type {
  AXElement,
  AXFrame,
  AXSourceHint,
  InspectableAnchor,
  SimAppInfo,
} from "../protocol.ts";
import { anchorDisplay, parseInspectable } from "./parseInspectable.ts";

export interface AncestorRef {
  role: string;
  label: string | null;
  anchor: InspectableAnchor | null;
}

export interface SimElementMention {
  kind: "sim-element";
  role: string;
  label: string | null;
  identifier: string | null;
  value: string | null;
  frame: AXFrame;
  anchor: InspectableAnchor | null;
  ancestors: AncestorRef[];
  appContext: SimAppInfo | null;
  sourceHints: AXSourceHint[];
}

export const SIM_INSPECT_MARKER_START = "<!-- @here:sim-element:start -->";
export const SIM_INSPECT_MARKER_END = "<!-- @here:sim-element:end -->";
const MAX_CONTEXT_LINES = 2;

/** Build a mention payload from an AX element + its hit chain.
 *  `chain[0]` is the target; the rest are ancestors leaf→root. */
export function buildSimElementMention(element: AXElement, chain: AXElement[]): SimElementMention {
  const ancestors: AncestorRef[] = chain.slice(1).map((ancestor) => ({
    role: ancestor.role,
    label: ancestor.label,
    anchor: parseInspectable(ancestor.identifier),
  }));
  const appContext = element.appContext ?? chain.find((c) => c.appContext)?.appContext ?? null;
  return {
    kind: "sim-element",
    role: element.role,
    label: element.label,
    identifier: element.identifier,
    value: element.value,
    frame: element.frame,
    anchor: parseInspectable(element.identifier),
    ancestors,
    appContext,
    sourceHints: element.sourceHints ?? [],
  };
}

/** Render a tight chat mention. One fact per field, no duplicate `file:line`
 *  references, and the code snippet only when the bridge verified an
 *  on-disk location. Compressed for AI consumption — every unnecessary word
 *  costs tokens. */
export function renderMentionMarkdown(m: SimElementMention): string {
  const anchoredAncestors = m.ancestors.filter(
    (a): a is AncestorRef & { anchor: InspectableAnchor } => a.anchor !== null,
  );
  const verifiedHint = pickVerifiedHint(m.sourceHints);
  const openAnchor = m.anchor ?? anchoredAncestors[0]?.anchor ?? null;

  const lines: string[] = [SIM_INSPECT_MARKER_START];

  // Identity line: the verified file:line doubles as the Open link — no
  // separate `[Open →]` row further down. Alias, role+label, size, and
  // app name follow as mid-dot-separated facts, each appearing at most once.
  const parts: string[] = [];
  if (openAnchor) {
    const display = anchorDisplay(openAnchor);
    const href = verifiedHint ? `${verifiedHint.absolutePath}:${verifiedHint.line}` : null;
    parts.push(href ? `[\`${display}\`](${href})` : `**${display}**`);
    if (openAnchor.alias) parts.push(openAnchor.alias);
  } else if (verifiedHint) {
    parts.push(
      `[\`${sourceHintDisplay(verifiedHint)}\`](${verifiedHint.absolutePath}:${verifiedHint.line})`,
    );
  }
  const elementSummary = describeElement(m);
  const identityHasAnchor = openAnchor != null;
  if (!identityHasAnchor || elementSummary.toLowerCase() !== `\`${m.role.toLowerCase()}\``) {
    parts.push(elementSummary);
  }
  parts.push(`${round(m.frame.width)}×${round(m.frame.height)}`);
  const appLabel = describeApp(m.appContext);
  if (appLabel) parts.push(appLabel);
  lines.push(parts.join(" · "));

  if (m.value && m.value !== m.label) {
    lines.push(`Value: \`${truncate(m.value, 160)}\``);
  }

  const snippetHint = pickSnippetHint(verifiedHint ? [verifiedHint] : []);
  if (snippetHint) {
    lines.push("```swift");
    lines.push(...formatSnippetLines(snippetHint));
    lines.push("```");
  }

  const contextAnchors = usefulContextLinks(anchoredAncestors, openAnchor);
  if (contextAnchors.length > 0) {
    lines.push(`Parents: ${contextAnchors.map((a) => `\`${a}\``).join(" · ")}`);
  }

  lines.push(SIM_INSPECT_MARKER_END);
  return lines.join("\n");
}

function describeElement(m: SimElementMention): string {
  const label = m.label ? truncate(m.label, 120) : null;
  if (label && label.toLowerCase() !== m.role.toLowerCase()) {
    return `\`${m.role}\` · "${label}"`;
  }
  return `\`${m.role}\``;
}

function describeApp(app: SimAppInfo | null): string | null {
  if (!app) return null;
  const name = app.name && app.name !== app.bundleId ? app.name : app.bundleId;
  return name;
}

function usefulContextLinks(
  ancestors: ReadonlyArray<AncestorRef & { anchor: InspectableAnchor }>,
  primary: InspectableAnchor | null,
): string[] {
  const primaryKey = primary ? anchorDisplay(primary) : null;
  const seen = new Set<string>();
  const out: string[] = [];
  for (const ancestor of ancestors) {
    if (out.length >= MAX_CONTEXT_LINES) break;
    const key = anchorDisplay(ancestor.anchor);
    if (key === primaryKey) continue;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(key);
  }
  return out;
}

function round(n: number): number {
  return Math.round(n);
}

function truncate(s: string, max: number): string {
  return s.length <= max ? s : `${s.slice(0, max - 1)}…`;
}

function sourceHintDisplay(hint: AXSourceHint): string {
  const path = hint.absolutePath.replace(/\\/g, "/");
  const sources = "/Sources/";
  const idx = path.lastIndexOf(sources);
  const rel = idx === -1 ? basename(path) : path.slice(idx + sources.length);
  return `${rel}:${hint.line}`;
}

function basename(path: string): string {
  const slash = path.lastIndexOf("/");
  return slash === -1 ? path : path.slice(slash + 1);
}

/** First verified hint that actually carries snippet text. */
function pickSnippetHint(
  hints: ReadonlyArray<AXSourceHint>,
): (AXSourceHint & { snippet: string; snippetStartLine: number }) | null {
  for (const hint of hints) {
    if (
      typeof hint.snippet === "string" &&
      hint.snippet.length > 0 &&
      typeof hint.snippetStartLine === "number"
    ) {
      return hint as AXSourceHint & { snippet: string; snippetStartLine: number };
    }
  }
  return null;
}

function pickVerifiedHint(hints: ReadonlyArray<AXSourceHint>): AXSourceHint | null {
  return hints.find((hint) => hint.reason.startsWith(".inspectable()")) ?? null;
}

/** Turns a raw snippet into a fenced block of right-aligned, line-numbered
 *  Swift with a `>` marker on the target row. Keeps trailing whitespace out
 *  of the markdown to avoid downstream linter thrash. */
function formatSnippetLines(
  hint: AXSourceHint & { snippet: string; snippetStartLine: number },
): string[] {
  const rows = hint.snippet.split("\n");
  const lastLineNumber = hint.snippetStartLine + rows.length - 1;
  const pad = String(lastLineNumber).length;
  return rows.map((row, idx) => {
    const lineNumber = hint.snippetStartLine + idx;
    const marker = lineNumber === hint.line ? ">" : " ";
    const gutter = String(lineNumber).padStart(pad, " ");
    return `${marker} ${gutter} │ ${row.replace(/\s+$/, "")}`;
  });
}
