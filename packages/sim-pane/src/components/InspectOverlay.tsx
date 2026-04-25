import type { CSSProperties, ReactElement } from "react";
import type { AXElement, InspectableAnchor } from "../protocol.ts";
import { anchorDisplay, parseInspectable } from "../lib/parseInspectable.ts";
import { tokens } from "../tokens.ts";

export interface InspectOverlayProps {
  active: boolean;
  hovered: AXElement | null;
  selected: AXElement | null;
  /** CSS px per device px. */
  scale: number;
  /** Skip motion when the user prefers reduced motion. */
  reduceMotion: boolean;
}

type Precision = "anchored" | "labeled" | "stub";

const ACCENT_ANCHOR = tokens.color.accentLive;
const ACCENT_LABEL = tokens.color.accentInfo;
const ACCENT_STUB = "rgba(255,255,255,0.55)";

function isCoordinateStub(el: AXElement): boolean {
  if (el.role === "TapPoint" || el.role === "Visible region") return true;
  return el.frame.width <= 1 && el.frame.height <= 1;
}

function classify(el: AXElement | null, anchor: InspectableAnchor | null): Precision {
  if (!el) return "stub";
  if (anchor) return "anchored";
  if (isCoordinateStub(el)) return "stub";
  if (el.label && el.label.trim().length > 0) return "labeled";
  return "stub";
}

function accentFor(precision: Precision): string {
  switch (precision) {
    case "anchored":
      return ACCENT_ANCHOR;
    case "labeled":
      return ACCENT_LABEL;
    case "stub":
      return ACCENT_STUB;
  }
}

function frameBoxStyle(el: AXElement, scale: number, transitions: boolean): CSSProperties {
  return {
    position: "absolute",
    left: el.frame.x * scale,
    top: el.frame.y * scale,
    width: el.frame.width * scale,
    height: el.frame.height * scale,
    pointerEvents: "none",
    boxSizing: "border-box",
    transition: transitions ? "all 110ms cubic-bezier(0.2, 0.8, 0.2, 1)" : undefined,
  };
}

/** Pixel-aligned border radius that honors the iOS view's CALayer shape so
 *  the outline wraps squircle buttons, material cards and pill badges —
 *  not a hard rectangle slapped over everything. */
function shapeRadius(el: AXElement, scale: number): number {
  return Math.max(0, (el.frame.cornerRadius ?? 0) * scale);
}

export function InspectOverlay({
  active,
  hovered,
  selected,
  scale,
  reduceMotion,
}: InspectOverlayProps): ReactElement | null {
  if (!active) return null;

  const selectedAnchor = parseInspectable(selected?.identifier);
  const hoveredAnchor = parseInspectable(hovered?.identifier);
  const selectedPrecision = classify(selected, selectedAnchor);
  const hoveredPrecision = classify(hovered, hoveredAnchor);
  const selectedAccent = accentFor(selectedPrecision);
  const hoveredAccent = accentFor(hoveredPrecision);

  const showHover =
    hovered && !isCoordinateStub(hovered) && (!selected || hovered.id !== selected.id);

  return (
    <>
      {showHover ? (
        <div
          aria-hidden
          style={{
            ...frameBoxStyle(hovered, scale, !reduceMotion),
            borderRadius: shapeRadius(hovered, scale),
            boxShadow: [
              `inset 0 0 0 1px ${rgba(hoveredAccent, 0.55)}`,
              `0 0 0 1px rgba(0,0,0,0.35)`,
            ].join(", "),
            background: rgba(hoveredAccent, 0.04),
          }}
        />
      ) : null}
      {selected ? (
        isCoordinateStub(selected) ? (
          <Crosshair
            x={selected.frame.x * scale}
            y={selected.frame.y * scale}
            color={selectedAccent}
            animate={!reduceMotion}
          />
        ) : (
          <SelectionFrame
            el={selected}
            scale={scale}
            accent={selectedAccent}
            animate={!reduceMotion}
          />
        )
      ) : null}
      {selected ? (
        <FloatingLabel
          target={selected}
          anchor={selectedAnchor}
          precision={selectedPrecision}
          accent={selectedAccent}
          scale={scale}
          animate={!reduceMotion}
        />
      ) : null}
    </>
  );
}

function SelectionFrame({
  el,
  scale,
  accent,
  animate,
}: {
  el: AXElement;
  scale: number;
  accent: string;
  animate: boolean;
}): ReactElement {
  const w = el.frame.width * scale;
  const h = el.frame.height * scale;
  const radius = shapeRadius(el, scale);
  const showDim = w >= 56 && h >= 30;
  return (
    <div
      aria-hidden
      style={{
        ...frameBoxStyle(el, scale, animate),
        borderRadius: radius,
        // Shape-conforming double-ring: a crisp accent stroke riding the
        // view's own corner curve, separated from the live pixels by a
        // 1px black hairline so the accent reads cleanly against any
        // background, then a soft outer glow for depth. No corner ticks
        // — they clashed with rounded shapes and made the picker read as
        // a CAD tool instead of a design tool.
        boxShadow: [
          `inset 0 0 0 1.5px ${accent}`,
          `inset 0 0 0 2.5px rgba(0,0,0,0.55)`,
          `0 0 0 1px ${rgba(accent, 0.32)}`,
          `0 0 26px 2px ${rgba(accent, 0.22)}`,
        ].join(", "),
        background: rgba(accent, 0.035),
      }}
    >
      {showDim ? <DimensionChip w={w} h={h} accent={accent} /> : null}
    </div>
  );
}

function DimensionChip({ w, h, accent }: { w: number; h: number; accent: string }): ReactElement {
  return (
    <div
      style={{
        position: "absolute",
        right: 6,
        top: 6,
        display: "inline-flex",
        alignItems: "center",
        gap: 4,
        padding: "2px 7px",
        background: "rgba(6,8,11,0.9)",
        border: `1px solid ${rgba(accent, 0.4)}`,
        borderRadius: 999,
        color: accent,
        fontFamily: tokens.font.mono,
        fontSize: 9,
        letterSpacing: "0.06em",
        textTransform: "uppercase",
        backdropFilter: "blur(8px)",
        boxShadow: `0 4px 10px -4px rgba(0,0,0,0.6)`,
      }}
    >
      {Math.round(w)}
      <span style={{ color: tokens.color.textFaint }}>×</span>
      {Math.round(h)}
    </div>
  );
}

function Crosshair({
  x,
  y,
  color,
  animate,
}: {
  x: number;
  y: number;
  color: string;
  animate: boolean;
}): ReactElement {
  return (
    <>
      <div
        aria-hidden
        style={{
          position: "absolute",
          left: x - 14,
          top: y - 14,
          width: 28,
          height: 28,
          borderRadius: 999,
          border: `1.5px solid ${color}`,
          background: rgba(color, 0.1),
          boxShadow: `0 0 0 1px rgba(0,0,0,0.45), 0 0 18px ${rgba(color, 0.4)}`,
          pointerEvents: "none",
          animation: animate ? "t3sim-tap-pulse 900ms ease-out infinite" : undefined,
        }}
      />
      <div
        aria-hidden
        style={{
          position: "absolute",
          left: x - 0.5,
          top: y - 28,
          width: 1,
          height: 56,
          background: `linear-gradient(180deg, transparent 0%, ${color} 45%, ${color} 55%, transparent 100%)`,
          opacity: 0.55,
          pointerEvents: "none",
        }}
      />
      <div
        aria-hidden
        style={{
          position: "absolute",
          left: x - 28,
          top: y - 0.5,
          width: 56,
          height: 1,
          background: `linear-gradient(90deg, transparent 0%, ${color} 45%, ${color} 55%, transparent 100%)`,
          opacity: 0.55,
          pointerEvents: "none",
        }}
      />
    </>
  );
}

function FloatingLabel({
  target,
  anchor,
  precision,
  accent,
  scale,
  animate,
}: {
  target: AXElement;
  anchor: InspectableAnchor | null;
  precision: Precision;
  accent: string;
  scale: number;
  animate: boolean;
}): ReactElement {
  const badge = precision === "anchored" ? "source" : precision === "labeled" ? "ax" : "coord";
  const primary = target.label ?? target.role;
  const anchorText = anchor ? anchorDisplay(anchor) : null;
  const frameX = target.frame.x * scale;
  const frameY = (target.frame.y + target.frame.height) * scale;
  const isAnchored = precision === "anchored";
  return (
    <div
      style={{
        position: "absolute",
        left: Math.max(6, frameX),
        top: Math.max(6, frameY + 10),
        display: "inline-flex",
        alignItems: "center",
        gap: 9,
        padding: "6px 11px 6px 9px",
        background: `linear-gradient(180deg, rgba(17,19,24,0.96), rgba(9,11,15,0.96))`,
        border: `1px solid ${rgba(accent, isAnchored ? 0.4 : 0.22)}`,
        backdropFilter: "blur(18px) saturate(140%)",
        borderRadius: tokens.radius.lg,
        color: tokens.color.text,
        fontFamily: tokens.font.mono,
        fontSize: 11,
        letterSpacing: "0.01em",
        pointerEvents: "none",
        maxWidth: 380,
        boxShadow: [
          `0 14px 28px -14px rgba(0,0,0,0.95)`,
          `0 2px 6px -2px rgba(0,0,0,0.6)`,
          `inset 0 1px 0 rgba(255,255,255,0.04)`,
          isAnchored ? `0 0 24px -6px ${rgba(accent, 0.45)}` : "none",
        ]
          .filter(Boolean)
          .join(", "),
        animation: animate ? "t3sim-fade-in 140ms ease-out" : undefined,
      }}
    >
      <span
        style={{
          display: "inline-flex",
          alignItems: "center",
          gap: 6,
          color: accent,
          fontSize: 9.5,
          letterSpacing: "0.16em",
        }}
      >
        <span
          style={{
            width: 6,
            height: 6,
            borderRadius: 999,
            background: accent,
            boxShadow: isAnchored ? `0 0 10px ${accent}` : `0 0 0 1px rgba(0,0,0,0.5)`,
            animation:
              isAnchored && animate ? "t3sim-inspect-pulse 1.6s ease-in-out infinite" : undefined,
          }}
        />
        <span style={{ textTransform: "uppercase", fontWeight: 500 }}>{badge}</span>
      </span>
      <span
        style={{
          maxWidth: anchorText ? 140 : 240,
          overflow: "hidden",
          textOverflow: "ellipsis",
          whiteSpace: "nowrap",
          color: tokens.color.text,
        }}
      >
        {primary}
      </span>
      {anchorText ? (
        <span
          title={anchorText}
          style={{
            display: "inline-flex",
            alignItems: "center",
            gap: 4,
            paddingLeft: 9,
            marginLeft: 1,
            borderLeft: `1px solid ${tokens.color.hairline}`,
            color: tokens.color.textMuted,
            fontSize: 10,
            maxWidth: 210,
            overflow: "hidden",
            textOverflow: "ellipsis",
            whiteSpace: "nowrap",
          }}
        >
          {shorten(anchorText)}
        </span>
      ) : null}
    </div>
  );
}

function shorten(anchor: string): string {
  const [path, line] = anchor.split(":");
  if (!path || !line) return anchor;
  const parts = path.split("/");
  if (parts.length <= 3) return anchor;
  return `${parts[0]}/…/${parts.slice(-2).join("/")}:${line}`;
}

function rgba(color: string, alpha: number): string {
  if (color.startsWith("rgba(") || color.startsWith("rgb(")) return color;
  const hex = color.replace("#", "");
  if (hex.length !== 3 && hex.length !== 6) return color;
  const full =
    hex.length === 3
      ? hex
          .split("")
          .map((c) => c + c)
          .join("")
      : hex;
  const r = Number.parseInt(full.slice(0, 2), 16);
  const g = Number.parseInt(full.slice(2, 4), 16);
  const b = Number.parseInt(full.slice(4, 6), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}
