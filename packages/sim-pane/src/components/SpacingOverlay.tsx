import type { ReactElement } from "react";
import type { GapMeasurement, GapSet } from "../lib/computeGaps.ts";
import { tokens } from "../tokens.ts";

export interface SpacingOverlayProps {
  gaps: GapSet;
  /** CSS px per device px. */
  scale: number;
}

/** Figma-style redline overlay for the four cardinal gaps between the
 *  selected element and its nearest visible neighbors. Only renders
 *  measurements that actually exist — missing sides stay silent. */
export function SpacingOverlay({ gaps, scale }: SpacingOverlayProps): ReactElement | null {
  const entries = [gaps.top, gaps.right, gaps.bottom, gaps.left].filter(
    (gap): gap is GapMeasurement => gap !== null,
  );
  if (entries.length === 0) return null;

  return (
    <div aria-hidden style={{ position: "absolute", inset: 0, pointerEvents: "none" }}>
      {entries.map((gap) => (
        <GapRedline key={`${gap.direction}-${gap.neighborId}`} gap={gap} scale={scale} />
      ))}
    </div>
  );
}

const ACCENT = "#FF4F7E";

function GapRedline({ gap, scale }: { gap: GapMeasurement; scale: number }): ReactElement {
  const left = gap.rect.x * scale;
  const top = gap.rect.y * scale;
  const width = Math.max(1, gap.rect.width * scale);
  const height = Math.max(1, gap.rect.height * scale);
  const horizontal = gap.direction === "left" || gap.direction === "right";
  const label = `${Math.round(gap.distance)}`;

  return (
    <>
      <div
        style={{
          position: "absolute",
          left,
          top,
          width,
          height,
          background: `${ACCENT}18`,
          border: `1px dashed ${ACCENT}`,
          boxSizing: "border-box",
        }}
      />
      {horizontal ? (
        <div
          style={{
            position: "absolute",
            left,
            top: top + height / 2 - 0.5,
            width,
            height: 1,
            background: ACCENT,
          }}
        />
      ) : (
        <div
          style={{
            position: "absolute",
            left: left + width / 2 - 0.5,
            top,
            width: 1,
            height,
            background: ACCENT,
          }}
        />
      )}
      <span
        style={{
          position: "absolute",
          left: left + width / 2,
          top: top + height / 2,
          transform: "translate(-50%, -50%)",
          padding: "2px 6px",
          borderRadius: 4,
          background: "rgba(11,13,17,0.92)",
          color: ACCENT,
          fontFamily: tokens.font.mono,
          fontSize: 10,
          letterSpacing: "0.02em",
          border: `1px solid ${ACCENT}66`,
          whiteSpace: "nowrap",
        }}
      >
        {label}
      </span>
    </>
  );
}
