import type { ReactElement, ReactNode } from "react";
import { computeChromeGeometry } from "../lib/chromeSvg.ts";
import type { DeviceDescriptor } from "../lib/deviceDescriptors.ts";
import { tokens } from "../tokens.ts";

export interface DeviceChromeProps {
  descriptor: DeviceDescriptor;
  /** CSS px width of the framebuffer's screen area. */
  screenWidth: number;
  /** CSS px height of the framebuffer's screen area. */
  screenHeight: number;
  /** Rendered inside the framebuffer cutout (e.g. inspect overlays). */
  children?: ReactNode;
}

/**
 * Pixel-accurate iPhone chrome designed to read identical to the Xcode 26
 * Simulator device window at normal viewing distance.
 *
 * Design rules we follow (kept tight so this file doesn't drift):
 *
 *   1. Titanium body is **dark**. Xcode renders Natural Titanium closer to
 *      near-black than to mid-grey. Most "pretty render" mistakes come from
 *      trying to show off the metal with bright highlights — real hardware
 *      under ambient office light is a calm, unified value.
 *   2. The frame is a **hairline**, not a chunky bezel. We use the
 *      bezelThickness from the descriptor verbatim; that value is already
 *      tuned to what Xcode draws (≈ 5–8 CSS px at typical render sizes).
 *   3. No drawn outer border. Titanium has a physical edge, not a 1px ink
 *      stroke; relying on the body gradient plus the ambient drop-shadow is
 *      enough to define the silhouette.
 *   4. Screen "socket" is jet black (#000) and gets a single 1px inset
 *      shadow so the bezel reads as raised material.
 *   5. Side buttons stick out ~3 CSS px. Anything more looks cartoonish;
 *      anything less and they disappear at small sizes.
 *   6. Dynamic Island is two stacked shapes: outer pill + a small inner
 *      darker pill, so it looks like a real cutout with Face-ID / TrueDepth
 *      sensor grouping rather than a flat paint blob.
 */
export function DeviceChrome({
  descriptor,
  screenWidth,
  screenHeight,
  children,
}: DeviceChromeProps): ReactElement {
  const g = computeChromeGeometry(descriptor, screenWidth, screenHeight);
  const innerRadius = Math.max(0, g.cornerRadius - descriptor.bezelThickness);

  const bodyGradId = `sim-body-${descriptor.family}`;
  const rimGradId = `sim-rim-${descriptor.family}`;
  const islandGradId = `sim-island-${descriptor.family}`;
  const btnGradId = `sim-btn-${descriptor.family}`;
  const btnEdgeId = `sim-btn-edge-${descriptor.family}`;

  const buttons = sideButtonGeometry(descriptor, g.outerWidth, g.outerHeight);

  // Expand the SVG canvas so physical buttons that extrude past the
  // chassis don't get clipped. Layout math upstream uses outerWidth /
  // outerHeight verbatim; the extra room is purely visual.
  const PAD = 6;

  return (
    <div
      data-sim-chrome={descriptor.family}
      style={{
        position: "relative",
        width: g.outerWidth,
        height: g.outerHeight,
        // Xcode's Simulator window casts a very soft ambient shadow —
        // two stacked filters, a tight contact shadow plus a diffuse
        // ambient one. No inner shadow: the titanium itself carries it.
        filter:
          "drop-shadow(0 1px 1.2px rgba(0,0,0,0.45)) drop-shadow(0 22px 40px rgba(0,0,0,0.42))",
      }}
    >
      <svg
        aria-hidden
        width={g.outerWidth + PAD * 2}
        height={g.outerHeight + PAD * 2}
        viewBox={`${-PAD} ${-PAD} ${g.outerWidth + PAD * 2} ${g.outerHeight + PAD * 2}`}
        style={{
          position: "absolute",
          inset: -PAD,
          pointerEvents: "none",
          overflow: "visible",
        }}
      >
        <defs>
          {/* Natural Titanium — deliberately close to jet black, with a
              faint 1-stop lift top/bottom to read as metal under ambient
              light. Centre stop is the true body value (#1E1E21). */}
          <linearGradient id={bodyGradId} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="#2B2B2E" />
            <stop offset="8%" stopColor="#232326" />
            <stop offset="50%" stopColor="#1E1E21" />
            <stop offset="92%" stopColor="#232326" />
            <stop offset="100%" stopColor="#2B2B2E" />
          </linearGradient>

          {/* Inner reflective rim — a whisper of white just inside the
              outer edge. Real titanium catches a single highlight band,
              not a mirror sheen, so opacity stays low. */}
          <linearGradient id={rimGradId} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="rgba(255,255,255,0.16)" />
            <stop offset="50%" stopColor="rgba(255,255,255,0.04)" />
            <stop offset="100%" stopColor="rgba(255,255,255,0.12)" />
          </linearGradient>

          {/* Physical side-button gradient. Darker centre, brighter
              outside-facing edge so buttons read as rounded pills. */}
          <linearGradient id={btnGradId} x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stopColor="#3A3A3D" />
            <stop offset="35%" stopColor="#222225" />
            <stop offset="65%" stopColor="#1E1E21" />
            <stop offset="100%" stopColor="#303033" />
          </linearGradient>

          {/* 1px bright hairline along the outside-facing button face. */}
          <linearGradient id={btnEdgeId} x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stopColor="rgba(255,255,255,0.38)" />
            <stop offset="100%" stopColor="rgba(255,255,255,0)" />
          </linearGradient>

          {/* Dynamic Island — top-to-bottom gradient so it doesn't read
              as a flat paint blob. Pure black at centre. */}
          <linearGradient id={islandGradId} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="#0B0B0E" />
            <stop offset="60%" stopColor="#000" />
            <stop offset="100%" stopColor="#000" />
          </linearGradient>
        </defs>

        {/* Hardware buttons render FIRST so the chassis overlaps the
            inner face of each button. */}
        {buttons.map((b) => (
          <g key={`${b.side}-${b.x}-${b.y}-${b.width}-${b.height}`}>
            <rect
              x={b.x}
              y={b.y}
              width={b.width}
              height={b.height}
              rx={Math.min(b.width, b.height) / 2}
              ry={Math.min(b.width, b.height) / 2}
              fill={`url(#${btnGradId})`}
              stroke="rgba(0,0,0,0.55)"
              strokeWidth={0.5}
            />
            {/* Hairline highlight along the outward face. */}
            <rect
              x={b.side === "right" ? b.x + b.width - 0.9 : b.x + 0.1}
              y={b.y + 0.6}
              width={0.8}
              height={Math.max(2, b.height - 1.2)}
              rx={0.4}
              fill={`url(#${btnEdgeId})`}
              opacity={0.65}
              transform={
                b.side === "left" ? `rotate(180 ${b.x + 0.5} ${b.y + b.height / 2})` : undefined
              }
            />
          </g>
        ))}

        {/* Titanium chassis (matte body fill). */}
        <rect
          x={0}
          y={0}
          width={g.outerWidth}
          height={g.outerHeight}
          rx={g.cornerRadius}
          ry={g.cornerRadius}
          fill={`url(#${bodyGradId})`}
        />

        {/* Inner reflective rim — 1px inside the chassis edge. No outer
            hairline: the drop-shadow defines the silhouette. */}
        <rect
          x={1}
          y={1}
          width={g.outerWidth - 2}
          height={g.outerHeight - 2}
          rx={g.cornerRadius - 1}
          ry={g.cornerRadius - 1}
          fill="none"
          stroke={`url(#${rimGradId})`}
          strokeWidth={1}
        />

        {/* Screen socket. Flat jet black; the CALayerHost NSView
            composites the live framebuffer on top of this. */}
        <rect
          x={g.screenX}
          y={g.screenY}
          width={g.screenWidth}
          height={g.screenHeight}
          rx={innerRadius}
          ry={innerRadius}
          fill="#000"
        />

        {/* 1px inset screen shadow so the bezel reads as raised. */}
        <rect
          x={g.screenX + 0.5}
          y={g.screenY + 0.5}
          width={g.screenWidth - 1}
          height={g.screenHeight - 1}
          rx={innerRadius - 0.5}
          ry={innerRadius - 0.5}
          fill="none"
          stroke="rgba(0,0,0,0.9)"
          strokeWidth={1}
        />

        {/* Dynamic Island — outer pill. */}
        {g.islandPath ? <path d={g.islandPath} fill={`url(#${islandGradId})`} /> : null}

        {/* Dynamic Island — tiny inner sensor dot (Face ID camera).
            Positioned at the right third of the island. */}
        {g.islandCameraDot ? (
          <circle
            cx={g.islandCameraDot.cx}
            cy={g.islandCameraDot.cy}
            r={g.islandCameraDot.r}
            fill="#0F0F12"
            stroke="rgba(255,255,255,0.06)"
            strokeWidth={0.5}
          />
        ) : null}

        {/* Home button — only the SE-generation family. */}
        {descriptor.family === "home-button" ? (
          <circle
            cx={g.screenX + g.screenWidth / 2}
            cy={g.outerHeight - descriptor.bezelThickness / 2}
            r={descriptor.bezelThickness * 0.42}
            fill="#0A0A0C"
            stroke="rgba(255,255,255,0.08)"
            strokeWidth={0.8}
          />
        ) : null}
      </svg>

      {/* Framebuffer cutout. The CALayerHost NSView lives above the
          webContents in macOS view order; pointer-events:none keeps the
          DOM out of hit-testing so the NSEvent monitor is the only
          input path. */}
      <div
        data-sim-framebuffer-cutout
        style={{
          position: "absolute",
          left: g.screenX,
          top: g.screenY,
          width: g.screenWidth,
          height: g.screenHeight,
          borderRadius: innerRadius,
          overflow: "hidden",
          pointerEvents: "none",
          background: tokens.color.ink,
        }}
      >
        {children}
      </div>
    </div>
  );
}

interface SideButtonRect {
  x: number;
  y: number;
  width: number;
  height: number;
  side: "left" | "right";
}

/**
 * Physical side-button geometry, anchored off the chassis height so
 * buttons stay proportional at every render size. Buttons **extend
 * past** the chassis outer edge (negative-x on left, > outerWidth on
 * right) and are over-painted by the chassis rect so they read as
 * "protruding from the side".
 */
function sideButtonGeometry(
  d: DeviceDescriptor,
  outerWidth: number,
  outerHeight: number,
): SideButtonRect[] {
  if (d.family === "home-button" || d.family === "generic" || d.family === "ipad") {
    return [];
  }
  // Depth: how far the button extrudes past the chassis edge.
  // Xcode renders this as a visible but restrained lip — ~3 CSS px at
  // typical render sizes, clamped for very small / very large panes.
  const depth = Math.min(3.8, Math.max(2, outerHeight * 0.003));
  const buttons: SideButtonRect[] = [];

  // Right edge: single long Side / Lock / Power pill. Top ~21% down.
  if (d.buttons.includes("side") || d.buttons.includes("lock")) {
    buttons.push({
      x: outerWidth - 0.6,
      y: outerHeight * 0.2,
      width: depth,
      height: outerHeight * 0.125,
      side: "right",
    });
  }

  // Left edge — Action (small), Volume Up, Volume Down.
  if (d.buttons.includes("siri")) {
    buttons.push({
      x: -depth + 0.6,
      y: outerHeight * 0.14,
      width: depth,
      height: outerHeight * 0.048,
      side: "left",
    });
  }
  if (d.buttons.includes("volume-up")) {
    buttons.push({
      x: -depth + 0.6,
      y: outerHeight * 0.205,
      width: depth,
      height: outerHeight * 0.072,
      side: "left",
    });
  }
  if (d.buttons.includes("volume-down")) {
    buttons.push({
      x: -depth + 0.6,
      y: outerHeight * 0.293,
      width: depth,
      height: outerHeight * 0.072,
      side: "left",
    });
  }

  return buttons;
}
