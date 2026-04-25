import { useMemo, type ReactElement } from "react";
import type { AXNode } from "../protocol.ts";
import { tokens } from "../tokens.ts";

export interface OutlineLayerProps {
  /** Full BFS snapshot for the current device. */
  nodes: ReadonlyArray<AXNode>;
  /** CSS px per device px — the renderer's current display scale. */
  scale: number;
  /** Ids to dim so the selected/hover chain reads above the sea of outlines. */
  selectedId?: string | null;
  hoveredId?: string | null;
  /** Absolute upper bound for how many rects we paint at once. Keeps the
   *  overlay from lagging on dense hierarchies; the snapshot is already
   *  prefiltered to on-screen visible nodes but a modal stack can still
   *  push hundreds through. */
  maxRects?: number;
}

/** Paints a soft outline around every visible snapshot node. Anchored
 *  (`.inspectable()`-stamped) rects get a brighter stroke so the user
 *  can see at a glance "these map directly to code". Deliberately no
 *  fills — fills would obscure the live screen we're inspecting. */
export function OutlineLayer({
  nodes,
  scale,
  selectedId,
  hoveredId,
  maxRects = 220,
}: OutlineLayerProps): ReactElement | null {
  const visible = useMemo(() => nodes.slice(0, maxRects), [nodes, maxRects]);
  if (visible.length === 0) return null;

  return (
    <div
      aria-hidden
      style={{
        position: "absolute",
        inset: 0,
        pointerEvents: "none",
        overflow: "hidden",
      }}
    >
      {visible.map((node) => {
        if (node.id === selectedId || node.id === hoveredId) return null;
        const anchored = Boolean(node.identifier);
        const stroke = anchored ? "rgba(142,255,154,0.32)" : "rgba(255,255,255,0.12)";
        const lineWidth = anchored ? 1 : 0.75;
        // Shape-conform to the underlying iOS view. The inspectable source
        // forwards `CALayer.cornerRadius`; without
        // this, every squircle button reads as a hard rectangle and the
        // overlay looks crude.
        const radius = Math.max(0, (node.frame.cornerRadius ?? 0) * scale);
        return (
          <div
            key={node.id}
            style={{
              position: "absolute",
              left: node.frame.x * scale,
              top: node.frame.y * scale,
              width: Math.max(0, node.frame.width * scale),
              height: Math.max(0, node.frame.height * scale),
              border: `${lineWidth}px solid ${stroke}`,
              borderRadius: radius > 0 ? radius : 2,
              boxSizing: "border-box",
              mixBlendMode: "screen",
            }}
          />
        );
      })}
      <span
        style={{
          position: "absolute",
          right: 8,
          top: 8,
          padding: "2px 7px",
          borderRadius: 999,
          background: "rgba(11,13,17,0.78)",
          border: `1px solid ${tokens.color.hairline}`,
          color: tokens.color.textMuted,
          fontFamily: tokens.font.mono,
          fontSize: 9.5,
          letterSpacing: "0.08em",
          textTransform: "uppercase",
        }}
      >
        {nodes.length} nodes
      </span>
    </div>
  );
}
