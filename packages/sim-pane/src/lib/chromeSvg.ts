import type { DeviceDescriptor } from "./deviceDescriptors.ts";

export interface ChromeGeometry {
  outerWidth: number;
  outerHeight: number;
  screenX: number;
  screenY: number;
  screenWidth: number;
  screenHeight: number;
  cornerRadius: number;
  /** SVG path `d=` for island/notch; `null` for home-button / generic / ipad. */
  islandPath: string | null;
  /**
   * Small "Face ID camera" dot that sits at the right end of the Dynamic
   * Island. Only populated for the `dynamic-island` chrome family; it
   * makes the island read as a real sensor cluster rather than a flat
   * paint blob at glance distance.
   */
  islandCameraDot: { cx: number; cy: number; r: number } | null;
}

export function computeChromeGeometry(
  d: DeviceDescriptor,
  screenWidthCss: number,
  screenHeightCss: number,
): ChromeGeometry {
  const b = d.bezelThickness;
  const outerWidth = screenWidthCss + 2 * b;
  const outerHeight = screenHeightCss + 2 * b;

  let islandPathStr: string | null = null;
  let islandCameraDot: ChromeGeometry["islandCameraDot"] = null;

  if (d.family === "dynamic-island") {
    const island = islandGeometry(screenWidthCss, b);
    islandPathStr = island.path;
    islandCameraDot = island.cameraDot;
  } else if (d.family === "notch") {
    islandPathStr = notchPath(screenWidthCss, b);
  }

  return {
    outerWidth,
    outerHeight,
    screenX: b,
    screenY: b,
    screenWidth: screenWidthCss,
    screenHeight: screenHeightCss,
    cornerRadius: d.cornerRadius,
    islandPath: islandPathStr,
    islandCameraDot,
  };
}

/**
 * Dynamic Island geometry. Real iPhone 17 Pro: ~126×37 pt pill sitting
 * ~11 pt below the screen's top edge. We scale off the screen width so
 * proportions stay right at every CSS render size.
 */
function islandGeometry(
  screenWidth: number,
  bezel: number,
): { path: string; cameraDot: { cx: number; cy: number; r: number } } {
  // Pill: Apple's island is ~30% of the screen width on Pro models.
  // Pill aspect is wider than tall → ≈ 3.4 : 1. Clamps keep the shape
  // reasonable at extreme render sizes.
  const w = Math.max(98, Math.min(156, screenWidth * 0.3));
  const h = Math.max(26, Math.min(36, screenWidth * 0.082));
  // Distance from the screen's top edge to the top of the island.
  // Apple draws ~11 pt on iPhone 17 Pro; scale lightly off screen
  // width so the spacing feels correct at smaller render sizes.
  const topGap = Math.max(4, Math.min(11, screenWidth * 0.022));
  const cy = bezel + topGap + h / 2;
  const cx = bezel + screenWidth / 2;
  const r = h / 2;

  const path = `M ${cx - w / 2 + r} ${cy - r} H ${cx + w / 2 - r} A ${r} ${r} 0 0 1 ${cx + w / 2 - r} ${cy + r} H ${cx - w / 2 + r} A ${r} ${r} 0 0 1 ${cx - w / 2 + r} ${cy - r} Z`;

  // Camera dot: tiny circle at the right third of the island, giving
  // the hint of a Face ID / TrueDepth sensor cluster.
  const cameraDot = {
    cx: cx + w / 2 - r - 2,
    cy,
    r: Math.max(1.8, r * 0.28),
  };

  return { path, cameraDot };
}

function notchPath(screenWidth: number, bezel: number): string {
  const w = Math.max(150, Math.min(210, screenWidth * 0.52));
  const h = Math.max(24, Math.min(32, screenWidth * 0.078));
  const cx = bezel + screenWidth / 2;
  const r = h / 2.2;
  // Rounded-bottom notch so it doesn't read as a sharp rectangular cutout.
  return `M ${cx - w / 2} ${bezel} H ${cx + w / 2} V ${bezel + h - r} A ${r} ${r} 0 0 1 ${cx + w / 2 - r} ${bezel + h} H ${cx - w / 2 + r} A ${r} ${r} 0 0 1 ${cx - w / 2} ${bezel + h - r} Z`;
}
