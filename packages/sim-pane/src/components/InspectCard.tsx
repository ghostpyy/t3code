import type { CSSProperties, ReactElement } from "react";
import type { AXElement, AXFrame, AXSourceHint, InspectableAnchor } from "../protocol.ts";
import { parseInspectable } from "../lib/parseInspectable.ts";
import { tokens } from "../tokens.ts";

const EMPTY_HINTS: AXSourceHint[] = [];

/** Roles Satira's `.inspectable()` modifier and SwiftUI runtime emit that
 *  carry no semantic meaning — every stamped view yields role="Inspectable",
 *  and AX containers leak "AXUIElement" / "Group" / "Other". */
const NOISY_ROLES = new Set(["Inspectable", "AXUIElement", "Group", "Other", "Generic"]);

/** Labels we treat as indistinguishable from the role. */
const GENERIC_LABELS = new Set([
  "axuielement",
  "element",
  "view",
  "group",
  "button",
  "image",
  "text",
  "inspectable",
]);

export interface InspectorSourceContext {
  directAnchor: InspectableAnchor | null;
  nearestAncestor: { element: AXElement; anchor: InspectableAnchor } | null;
  sourceHints: ReadonlyArray<AXSourceHint>;
}

export function deriveInspectorSourceContext(
  element: AXElement | null,
  chain: AXElement[],
): InspectorSourceContext {
  if (!element) {
    return {
      directAnchor: null,
      nearestAncestor: null,
      sourceHints: EMPTY_HINTS,
    };
  }
  const directAnchor = parseInspectable(element.identifier);
  const nearestAncestor =
    chain
      .slice(1)
      .map((ancestor) => {
        const anchor = parseInspectable(ancestor.identifier);
        return anchor ? { element: ancestor, anchor } : null;
      })
      .find(
        (entry): entry is { element: AXElement; anchor: InspectableAnchor } => entry !== null,
      ) ?? null;
  const sourceHints = element.sourceHints ?? EMPTY_HINTS;
  return {
    directAnchor,
    nearestAncestor,
    sourceHints,
  };
}

export interface InspectCardProps {
  hovered: AXElement | null;
  selected: AXElement | null;
  previewChain: AXElement[];
  sourceContext: InspectorSourceContext;
  onSyncChat: () => void;
  onCopy: () => void;
  onClearSelection: () => void;
  onExit: () => void;
  onOpenSource?: (absolutePath: string, line: number) => void;
}

/** Dockable inspector panel. Renders as a flex sibling *below* the simulator
 *  stage — never absolute-positioned over the CALayerHost, so the native
 *  NSView can't occlude any of the source or actions. */
export function InspectCard({
  hovered,
  selected,
  previewChain,
  sourceContext,
  onSyncChat,
  onCopy,
  onClearSelection,
  onExit,
  onOpenSource,
}: InspectCardProps): ReactElement {
  const preview = selected ?? hovered;
  const tone: "pinned" | "hover" | "idle" = selected ? "pinned" : hovered ? "hover" : "idle";
  const accent =
    tone === "pinned"
      ? tokens.color.accentLive
      : tone === "hover"
        ? tokens.color.accentInfo
        : tokens.color.textMuted;

  const anchor = sourceContext.directAnchor ?? sourceContext.nearestAncestor?.anchor ?? null;
  const sourceHint = pickVerifiedHint(sourceContext.sourceHints);
  const sourcePath = sourceHint?.absolutePath ?? null;
  const sourceLine = sourceHint?.line ?? null;
  const sourceLabel = sourceHint
    ? sourceContext.directAnchor
      ? "direct anchor"
      : "via ancestor"
    : null;

  const primary = preview
    ? primaryTitle(preview, previewChain, anchor)
    : "Click anywhere on the simulator";
  const frame = preview ? bestDisplayFrame(previewChain) : null;
  const subtitle = preview
    ? buildSubtitle(anchor, frame)
    : "Inspect mode is on — tap or hover to see source anchors";

  const canAct = Boolean(selected);

  return (
    <div
      role="region"
      aria-label="Inspector"
      style={{
        flex: "0 0 auto",
        boxSizing: "border-box",
        display: "grid",
        gap: 10,
        padding: "12px 16px 14px",
        borderTop: `1px solid ${tokens.color.hairline}`,
        background: "linear-gradient(180deg, rgba(11,13,17,0.92), rgba(9,10,14,0.96))",
        backdropFilter: "blur(12px)",
        animation: "t3sim-fade-in 140ms ease-out",
      }}
    >
      <HeaderRow
        accent={accent}
        tone={tone}
        primary={primary}
        subtitle={subtitle}
        canAct={canAct}
        onSyncChat={onSyncChat}
        onCopy={onCopy}
        onClearSelection={onClearSelection}
        onExit={onExit}
      />

      {sourcePath && sourceLine !== null ? (
        <SourceRow
          path={sourcePath}
          line={sourceLine}
          label={sourceLabel}
          {...(onOpenSource ? { onOpen: () => onOpenSource(sourcePath, sourceLine) } : {})}
        />
      ) : null}
    </div>
  );
}

function HeaderRow({
  accent,
  tone,
  primary,
  subtitle,
  canAct,
  onSyncChat,
  onCopy,
  onClearSelection,
  onExit,
}: {
  accent: string;
  tone: "pinned" | "hover" | "idle";
  primary: string;
  subtitle: string | null;
  canAct: boolean;
  onSyncChat: () => void;
  onCopy: () => void;
  onClearSelection: () => void;
  onExit: () => void;
}): ReactElement {
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: 10,
        flexWrap: "wrap",
        rowGap: 8,
      }}
    >
      <span
        aria-hidden
        style={{
          width: 9,
          height: 9,
          borderRadius: 999,
          background: tone === "pinned" ? accent : "transparent",
          border: `1.5px solid ${accent}`,
          boxShadow: tone === "pinned" ? `0 0 10px ${hex(accent, 0.55)}` : "none",
          flexShrink: 0,
          animation:
            tone === "pinned" ? "t3sim-inspect-pulse 1.6s ease-in-out infinite" : undefined,
        }}
      />
      <div style={{ minWidth: 0, flex: "1 1 160px" }}>
        <div
          style={{
            color: tokens.color.text,
            fontSize: 14,
            lineHeight: 1.2,
            fontWeight: 600,
            whiteSpace: "nowrap",
            overflow: "hidden",
            textOverflow: "ellipsis",
          }}
          title={primary}
        >
          {primary}
        </div>
        {subtitle ? (
          <div
            style={{
              marginTop: 3,
              color: tokens.color.textMuted,
              fontFamily: tokens.font.mono,
              fontSize: 10.5,
              letterSpacing: 0,
              whiteSpace: "nowrap",
              overflow: "hidden",
              textOverflow: "ellipsis",
            }}
            title={subtitle}
          >
            {subtitle}
          </div>
        ) : null}
      </div>
      <div
        style={{
          display: "flex",
          gap: 6,
          alignItems: "center",
          flexShrink: 0,
          marginLeft: "auto",
        }}
      >
        <ToolbarButton
          onClick={onSyncChat}
          disabled={!canAct}
          variant="primary"
          hint="⌘↵"
          title="Mention element in chat"
        >
          Mention in the Chat
        </ToolbarButton>
        <ToolbarButton onClick={onCopy} disabled={!canAct} hint="⌘⇧K" title="Copy mention">
          Copy
        </ToolbarButton>
        <ToolbarButton
          onClick={onClearSelection}
          disabled={!canAct}
          title="Clear pinned selection (stay in inspect mode)"
        >
          Clear
        </ToolbarButton>
        <span
          aria-hidden
          style={{ width: 1, height: 20, background: tokens.color.hairline, margin: "0 2px" }}
        />
        <ToolbarButton onClick={onExit} variant="danger" hint="⌘⇧C" title="Exit inspect mode">
          Exit
        </ToolbarButton>
      </div>
    </div>
  );
}

function SourceRow({
  path,
  line,
  label,
  onOpen,
}: {
  path: string;
  line: number;
  label: string | null;
  onOpen?: () => void;
}): ReactElement {
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        gap: 10,
        padding: "8px 10px",
        borderRadius: 10,
        border: `1px solid ${tokens.color.hairline}`,
        background: "rgba(255,255,255,0.03)",
      }}
    >
      <div style={{ minWidth: 0, display: "grid", gap: 2 }}>
        <span
          style={{
            color: tokens.color.text,
            fontFamily: tokens.font.mono,
            fontSize: 11,
            lineHeight: 1.35,
            whiteSpace: "nowrap",
            overflow: "hidden",
            textOverflow: "ellipsis",
          }}
          title={`${path}:${line}`}
        >
          {shortenAnchorPath(path)}:{line}
        </span>
        {label ? (
          <span
            style={{
              color: tokens.color.textMuted,
              fontFamily: tokens.font.mono,
              fontSize: 9.5,
              letterSpacing: 0,
              textTransform: "uppercase",
            }}
          >
            {label}
          </span>
        ) : null}
      </div>
      {onOpen ? (
        <ToolbarButton onClick={onOpen} variant="ghost" title="Open in editor">
          Open
        </ToolbarButton>
      ) : null}
    </div>
  );
}

function ToolbarButton({
  children,
  onClick,
  disabled,
  variant = "ghost",
  hint,
  title,
}: {
  children: string;
  onClick: () => void;
  disabled?: boolean;
  variant?: "primary" | "ghost" | "danger";
  hint?: string;
  title?: string;
}): ReactElement {
  const label = title ?? children;
  const baseTitle = hint ? `${label} (${hint})` : label;
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      title={baseTitle}
      style={toolbarButtonStyle(variant, Boolean(disabled))}
    >
      {children}
    </button>
  );
}

function toolbarButtonStyle(
  variant: "primary" | "ghost" | "danger",
  disabled: boolean,
): CSSProperties {
  const accent =
    variant === "primary"
      ? tokens.color.accentLive
      : variant === "danger"
        ? tokens.color.accentError
        : null;
  const border = accent ? hex(accent, 0.4) : "rgba(255,255,255,0.12)";
  const bg = accent ? hex(accent, 0.14) : "rgba(255,255,255,0.04)";
  const fg = accent ? tokens.color.text : tokens.color.textMuted;
  return {
    appearance: "none",
    border: `1px solid ${border}`,
    background: bg,
    color: fg,
    borderRadius: 8,
    padding: "6px 12px",
    fontSize: 11.5,
    fontWeight: 600,
    cursor: disabled ? "default" : "pointer",
    opacity: disabled ? 0.42 : 1,
    letterSpacing: 0,
    lineHeight: 1.2,
    whiteSpace: "nowrap",
  };
}

function primaryTitle(
  element: AXElement,
  chain: AXElement[],
  anchor: InspectableAnchor | null,
): string {
  const semantic = usefulLabel(element);
  if (semantic) return semantic;
  if (anchor?.alias) return anchor.alias;
  for (const ancestor of chain.slice(1)) {
    const text = usefulLabel(ancestor);
    if (text) return text;
  }
  if (anchor) return `${basename(anchor.file)}:${anchor.line}`;
  const role = element.role?.trim() ?? "";
  if (role && !NOISY_ROLES.has(role)) return role;
  return "Element";
}

function usefulLabel(element: AXElement): string | null {
  const label = element.label?.trim();
  if (label && !GENERIC_LABELS.has(label.toLowerCase())) return label;
  const value = element.value?.trim();
  if (value && value !== label && !GENERIC_LABELS.has(value.toLowerCase())) return value;
  return null;
}

function buildSubtitle(anchor: InspectableAnchor | null, frame: AXFrame | null): string | null {
  const sizePart = frame ? `${Math.round(frame.width)}×${Math.round(frame.height)}` : null;
  if (anchor) {
    const sourcePart = `${basename(anchor.file)}:${anchor.line}`;
    return sizePart ? `${sourcePart} · ${sizePart}` : sourcePart;
  }
  if (frame) {
    return `${sizePart} · ${Math.round(frame.x)},${Math.round(frame.y)}`;
  }
  return null;
}

function bestDisplayFrame(chain: AXElement[]): AXFrame | null {
  return (
    chain.find((element) => element.frame.width > 2 && element.frame.height > 2)?.frame ?? null
  );
}

function pickVerifiedHint(hints: ReadonlyArray<AXSourceHint>): AXSourceHint | null {
  return hints.find((hint) => hint.reason.startsWith(".inspectable()")) ?? null;
}

function shortenAnchorPath(absolutePath: string): string {
  const parts = absolutePath.split("/").filter((part) => part.length > 0);
  if (parts.length <= 3) return parts.join("/");
  return `…/${parts.slice(-3).join("/")}`;
}

function basename(path: string): string {
  const slash = path.lastIndexOf("/");
  return slash === -1 ? path : path.slice(slash + 1);
}

function hex(color: string, alpha: number): string {
  if (color.startsWith("rgba(") || color.startsWith("rgb(")) return color;
  const raw = color.replace("#", "");
  const full =
    raw.length === 3
      ? raw
          .split("")
          .map((c) => c + c)
          .join("")
      : raw;
  if (full.length !== 6) return color;
  const r = Number.parseInt(full.slice(0, 2), 16);
  const g = Number.parseInt(full.slice(2, 4), 16);
  const b = Number.parseInt(full.slice(4, 6), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}
