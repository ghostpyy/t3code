import { useCallback, useEffect, useMemo, useRef, useState, type ReactElement } from "react";
import { DeviceChrome } from "./components/DeviceChrome.tsx";
import { DeviceToolbar } from "./components/DeviceToolbar.tsx";
import { InspectCard, deriveInspectorSourceContext } from "./components/InspectCard.tsx";
import { getDeviceDescriptor } from "./lib/deviceDescriptors.ts";
import { buildSimElementMention, renderMentionMarkdown } from "./lib/mentions.ts";
import { refreshPinFrames } from "./lib/refreshPinFrames.ts";
import type { AXElement } from "./protocol.ts";
import { tokens } from "./tokens.ts";
import { useSimBridge } from "./useSimBridge.ts";

export interface SimPaneBounds {
  x: number;
  y: number;
  width: number;
  height: number;
  refWidth?: number;
  refHeight?: number;
  /** Inner-socket corner radius (CSS px) for the native layer to clip the
   *  live screen against — matches the bezel's rounded cutout so the two
   *  render as one continuous device, like Simulator.app. */
  cornerRadius?: number;
  /** UIDeviceOrientation of the rotated chrome; the host inverts this when
   *  projecting pointer events into portrait-native pixel coordinates the
   *  simulator HID expects. */
  orientation?: 1 | 2 | 3 | 4;
}

export interface SimPaneOutlineRect {
  x: number;
  y: number;
  width: number;
  height: number;
  /** Corner radius (display points) of the element this rect traces. The
   *  native picker rounds its stroke by this amount so the highlight shape
   *  matches the underlying iOS element. */
  cornerRadius?: number;
}

export type SimPaneMode = "input" | "inspect";

export interface SimPaneProps {
  /** Publish cutout bounds (CSS px, viewport-relative) to the Electron main SimView. */
  publishBounds: (rect: SimPaneBounds) => void;
  /** Publish input/inspect mode to the Electron main SimView. */
  publishMode: (mode: SimPaneMode) => void;
  /** Publish the selected inspect frame for the native CALayer overlay. */
  publishOutlines?: (rects: readonly SimPaneOutlineRect[], selectedIndex?: number) => void;
  /** Sync a simulator inspect markdown block into the chat composer. */
  insertChatMention: (
    markdown: string,
    options?: { replaceExisting?: boolean; focusComposer?: boolean },
  ) => void;
  /** Copy a markdown block to the system clipboard. */
  copyToClipboard?: (markdown: string) => void;
  /** Open a resolved source location in the preferred editor. */
  openSource?: (absolutePath: string, line: number) => void;
  /** Maximum CSS px width of the chrome + bezel on screen. */
  maxWidth?: number;
}

const FALLBACK_PIXEL = { width: 1170, height: 2532 };
const FALLBACK_SCALE = 3;
const EMPTY_AX_CHAIN: AXElement[] = [];

// When a dropdown is open we push the native CALayerHost NSView off-screen so
// it can't composite above the portaled menu. Apple doesn't expose a "hide"
// knob for simView — bounds off the viewport is the only reliable way.
const OFF_SCREEN_BOUNDS: SimPaneBounds = { x: -9999, y: -9999, width: 0, height: 0 };

/** CSS px radius of the bezel's inner screen socket. Kept in sync with
 *  DeviceChrome's `innerRadius = cornerRadius - bezelThickness` so the
 *  native CALayer and the bezel SVG arc use the same value. */
function innerCornerRadius(descriptor: { cornerRadius: number; bezelThickness: number }): number {
  return Math.max(0, descriptor.cornerRadius - descriptor.bezelThickness);
}

export function SimPane({
  publishBounds,
  publishMode,
  publishOutlines,
  insertChatMention,
  copyToClipboard,
  openSource,
  maxWidth,
}: SimPaneProps): ReactElement {
  const {
    state: {
      devices,
      selectedUdid,
      selectedState,
      bootStatus,
      displayPixel,
      displayScale,
      displayOrientation,
      error,
      hoveredHit,
      selectedHit,
      lastSnapshot,
    },
    enableAx,
    tapButton,
    rotate,
    screenshotToClipboard,
    selectUdid,
    bootDevice,
    shutdownDevice,
    clearSelection,
    requestSnapshot,
  } = useSimBridge();

  const [inspectOn, setInspectOn] = useState(false);
  const [simSuppressed, setSimSuppressed] = useState(false);
  // UIDeviceOrientation: 1 portrait, 2 portraitUpsideDown, 3 landscapeRight,
  // 4 landscapeLeft. State (not ref) so the rotation wrapper, fit calc, and
  // publishBounds re-render together — the host's pointer-event projection
  // depends on this value being current.
  const [orientation, setOrientation] = useState<1 | 2 | 3 | 4>(1);
  const cutoutRef = useRef<HTMLDivElement | null>(null);
  const stageRef = useRef<HTMLDivElement | null>(null);
  const [stageSize, setStageSize] = useState<{ width: number; height: number } | null>(null);

  const deviceInfo = useMemo(
    () => devices.find((device) => device.udid === selectedUdid) ?? null,
    [devices, selectedUdid],
  );

  const descriptor = useMemo(
    () => (deviceInfo ? getDeviceDescriptor(deviceInfo.model) : getDeviceDescriptor("")),
    [deviceInfo],
  );

  useEffect(() => {
    const stage = stageRef.current;
    if (!stage) return;
    const publish = (): void => {
      const rect = stage.getBoundingClientRect();
      setStageSize({ width: rect.width, height: rect.height });
    };
    publish();
    const ro = typeof ResizeObserver !== "undefined" ? new ResizeObserver(publish) : null;
    ro?.observe(stage);
    window.addEventListener("resize", publish);
    return () => {
      ro?.disconnect();
      window.removeEventListener("resize", publish);
    };
  }, []);

  const resolvedMaxWidth = useMemo(() => {
    if (typeof maxWidth === "number") return maxWidth;
    const width = stageSize?.width ?? 0;
    if (width <= 0) return 420;
    return Math.max(240, width - 48);
  }, [maxWidth, stageSize]);

  const availableHeight = useMemo(() => {
    const height = stageSize?.height ?? 0;
    if (height <= 0) return Infinity;
    return Math.max(240, height - 48);
  }, [stageSize]);

  // Minimum CSS width for the *screen area* (not including chrome) so the
  // device stays legible when a drawer eats the vertical space.
  const MIN_SCREEN_WIDTH = 220;

  const isLandscape = orientation === 3 || orientation === 4;
  const rotationDeg =
    orientation === 2 ? 180 : orientation === 3 ? -90 : orientation === 4 ? 90 : 0;

  const { screenWidth, screenHeight, envelopeWidth, envelopeHeight, needsScroll } = useMemo(() => {
    const px = displayPixel ?? FALLBACK_PIXEL;
    const devicePxPerPoint = displayScale ?? FALLBACK_SCALE;
    const deviceCssWidth = Math.min(px.width, px.height) / devicePxPerPoint;
    const deviceCssHeight = Math.max(px.width, px.height) / devicePxPerPoint;
    const bezel2 = 2 * descriptor.bezelThickness;
    // The chrome is laid out in PORTRAIT and CSS-rotated. Its rotated AABB is
    // (outerHeight, outerWidth) in landscape — the visible envelope on stage.
    // To keep that AABB inside the available stage box, swap the constraints
    // so portrait-outer-height ≤ stage-width and portrait-outer-width ≤
    // stage-height. (For portrait/upside-down the AABB matches the unrotated
    // box, so the swap is a no-op.)
    const constraintWidth = isLandscape ? availableHeight : resolvedMaxWidth;
    const constraintHeight = isLandscape ? resolvedMaxWidth : availableHeight;
    const availableWidth = Math.max(100, constraintWidth - bezel2);
    const availableH = Math.max(100, constraintHeight - bezel2);
    const widthFit = availableWidth / deviceCssWidth;
    const heightFit = availableH / deviceCssHeight;
    const fitScale = Math.min(1, widthFit, heightFit);
    const minScale = MIN_SCREEN_WIDTH / deviceCssWidth;
    const finalScale = Math.max(fitScale, minScale);
    const finalWidth = deviceCssWidth * finalScale;
    const finalHeight = deviceCssHeight * finalScale;
    const portraitOuterWidth = finalWidth + bezel2;
    const portraitOuterHeight = finalHeight + bezel2;
    const aabbWidth = isLandscape ? portraitOuterHeight : portraitOuterWidth;
    const aabbHeight = isLandscape ? portraitOuterWidth : portraitOuterHeight;
    const wouldOverflow = aabbWidth > resolvedMaxWidth + 0.5 || aabbHeight > availableHeight + 0.5;
    return {
      screenWidth: finalWidth,
      screenHeight: finalHeight,
      envelopeWidth: aabbWidth,
      envelopeHeight: aabbHeight,
      needsScroll: wouldOverflow,
    };
  }, [
    displayPixel,
    displayScale,
    resolvedMaxWidth,
    availableHeight,
    descriptor.bezelThickness,
    isLandscape,
  ]);

  // Publish cutout bounds on mount + whenever layout changes. Electron main
  // positions the native CALayerHost NSView over these coordinates. When the
  // device picker is open we publish off-screen bounds so the NSView stops
  // occluding the portaled menu.
  useEffect(() => {
    const cutout = cutoutRef.current;
    const stage = stageRef.current;
    if (!cutout) return;
    if (simSuppressed) {
      publishBounds(OFF_SCREEN_BOUNDS);
      return;
    }
    const radius = innerCornerRadius(descriptor);
    const publish = (): void => {
      // getBoundingClientRect returns the AABB of the rotated cutout in
      // viewport coords — that's exactly what the native CALayerHost
      // wants. The host inverts `orientation` to project pointer events
      // back into portrait-native pixel coords.
      const rect = cutout.getBoundingClientRect();
      publishBounds({
        x: rect.left,
        y: rect.top,
        width: rect.width,
        height: rect.height,
        refWidth: window.innerWidth || document.documentElement.clientWidth,
        refHeight: window.innerHeight || document.documentElement.clientHeight,
        cornerRadius: radius,
        orientation,
      });
    };
    publish();
    const ro = typeof ResizeObserver !== "undefined" ? new ResizeObserver(publish) : null;
    ro?.observe(cutout);
    if (stage) ro?.observe(stage);
    window.addEventListener("scroll", publish, true);
    window.addEventListener("resize", publish);
    return () => {
      ro?.disconnect();
      window.removeEventListener("scroll", publish, true);
      window.removeEventListener("resize", publish);
    };
  }, [publishBounds, screenWidth, screenHeight, simSuppressed, descriptor, orientation]);

  useEffect(() => {
    publishMode(inspectOn ? "inspect" : "input");
    if (inspectOn) enableAx();
  }, [inspectOn, publishMode, enableAx]);

  useEffect(() => {
    setOrientation(displayOrientation);
  }, [displayOrientation]);

  useEffect(
    () => () => {
      publishBounds(OFF_SCREEN_BOUNDS);
      publishMode("input");
    },
    [publishBounds, publishMode],
  );

  const hoveredChain = hoveredHit?.chain ?? EMPTY_AX_CHAIN;
  const storedPinnedChain = selectedHit?.chain ?? EMPTY_AX_CHAIN;
  // The pin chain captured at click time becomes stale as soon as the iOS
  // app shifts layout under it — scroll, sheet, focus animation, etc. We
  // re-resolve each chain element by `.inspectable()` identifier against
  // the latest snapshot so the outline tracks the element instead of
  // sticking to the original click coordinates.
  const pinnedChain = useMemo(
    () => refreshPinFrames(storedPinnedChain, lastSnapshot?.nodes, selectedHit?.pinRanks),
    [storedPinnedChain, lastSnapshot, selectedHit?.pinRanks],
  );
  const hoveredSafeIndex =
    hoveredChain.length > 0
      ? Math.min(Math.max(0, hoveredHit?.hitIndex ?? 0), hoveredChain.length - 1)
      : 0;
  const hovered = hoveredChain[hoveredSafeIndex] ?? null;
  const safeIndex =
    pinnedChain.length > 0
      ? Math.min(Math.max(0, selectedHit?.hitIndex ?? 0), pinnedChain.length - 1)
      : 0;
  const selected = pinnedChain[safeIndex] ?? null;
  const selectedChain = selected ? pinnedChain.slice(safeIndex) : EMPTY_AX_CHAIN;
  const hoveredPreviewChain = hovered ? hoveredChain.slice(hoveredSafeIndex) : EMPTY_AX_CHAIN;
  const preview = selected ?? hovered;
  const previewChain = selected ? selectedChain : hoveredPreviewChain;

  // Poll for snapshots the whole time inspect is on, not just after a pin
  // is set. The pinRanks oracle in `axHitResponse` needs a fresh snapshot
  // AT click time to stamp the scroll-invariant rank; gating the poll on
  // `selectedHit !== null` means the first click always races the first
  // snapshot and falls back to centroid-nearest (which picks the wrong
  // ForEach instance after large scrolls — Bug B). The cost is one BFS
  // walk per 250ms while the user has inspect open; cheap because the
  // daemon pulls directly from the app's in-process inspector when present.
  useEffect(() => {
    if (!inspectOn) return;
    requestSnapshot();
    const handle = setInterval(requestSnapshot, 250);
    return () => clearInterval(handle);
  }, [inspectOn, requestSnapshot]);
  const previewSource = useMemo(
    () => deriveInspectorSourceContext(preview, previewChain),
    [preview, previewChain],
  );

  // Single authoritative writer for the native outline layer. The pin wins
  // over live hover — otherwise rapid mouse motion after a click would paint
  // transient outlines under the cursor and visually obliterate the selected
  // element the user just locked in. Hover is only surfaced when there's no
  // pin, giving pre-click users live feedback without fighting the pin.
  useEffect(() => {
    if (!publishOutlines) return;
    if (!inspectOn) {
      publishOutlines([], 0);
      return;
    }
    if (selected) {
      publishOutlines(
        pinnedChain.map((element) => element.frame),
        safeIndex,
      );
      return;
    }
    if (hovered) {
      publishOutlines(
        hoveredChain.map((element) => element.frame),
        hoveredSafeIndex,
      );
      return;
    }
    publishOutlines([], 0);
  }, [
    hovered,
    hoveredChain,
    hoveredSafeIndex,
    inspectOn,
    pinnedChain,
    publishOutlines,
    safeIndex,
    selected,
  ]);
  const selectedMentionMarkdown = useMemo(() => {
    if (!selected) return null;
    const mention = buildSimElementMention(selected, selectedChain);
    return renderMentionMarkdown(mention);
  }, [selected, selectedChain]);

  const syncSelectedToChat = useCallback(
    (focusComposer: boolean) => {
      if (!selectedMentionMarkdown) return;
      insertChatMention(selectedMentionMarkdown, {
        replaceExisting: true,
        focusComposer,
      });
    },
    [insertChatMention, selectedMentionMarkdown],
  );

  const copySelectedToClipboard = useCallback(() => {
    if (!selectedMentionMarkdown) return;
    if (copyToClipboard) {
      copyToClipboard(selectedMentionMarkdown);
      return;
    }
    if (typeof navigator !== "undefined" && navigator.clipboard?.writeText) {
      void navigator.clipboard.writeText(selectedMentionMarkdown);
    }
  }, [copyToClipboard, selectedMentionMarkdown]);

  // Turning inspect off resets the pin so re-enabling starts clean — a
  // lingering selectedHit would otherwise render a phantom outline when the
  // user re-enters inspect mode on a completely different screen. Tap no
  // longer auto-injects into the composer; the user drives that through
  // the "Mention in the Chat" button or ⌘↵.
  useEffect(() => {
    if (!inspectOn) clearSelection();
  }, [clearSelection, inspectOn]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent): void => {
      const mod = event.metaKey || event.ctrlKey;
      if (mod && event.shiftKey && (event.key === "c" || event.key === "C")) {
        event.preventDefault();
        setInspectOn((value) => !value);
        return;
      }
      if (!inspectOn) return;
      // Two-stage Escape: first press drops the pin so the picker becomes
      // ambient-hover again; second press (no pin to clear) leaves inspect
      // mode entirely. Mirrors how Apple's own picker dismisses selection
      // before tearing down its overlay.
      if (event.key === "Escape") {
        event.preventDefault();
        if (selected) {
          clearSelection();
        } else {
          setInspectOn(false);
        }
        return;
      }
      if (mod && event.key === "Enter") {
        if (!selected) return;
        event.preventDefault();
        syncSelectedToChat(true);
        return;
      }
      if (mod && event.shiftKey && (event.key === "k" || event.key === "K")) {
        if (!selected) return;
        event.preventDefault();
        copySelectedToClipboard();
        return;
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [clearSelection, copySelectedToClipboard, inspectOn, selected, syncSelectedToChat]);

  const handleHome = useCallback(() => tapButton("home"), [tapButton]);
  // Cycle UIDeviceOrientation values: portrait → landscapeLeft → upside-down →
  // landscapeRight → portrait. backboardd accepts any of the four; the guest
  // app rotates if its supported-orientations mask permits it. See GSEvent.h
  // for the on-wire enum. The renderer keeps the orientation in state so the
  // chrome rotates in lockstep with the daemon-side surface transform; the
  // bridge mirrors this value via `.rotate(_)` and re-applies its IOSurface
  // rotation on every onSurface from then on.
  const handleRotate = useCallback(() => {
    setOrientation((prev) => {
      const cycle = [1, 4, 2, 3] as const;
      const idx = cycle.indexOf(prev);
      const next = cycle[(idx + 1) % cycle.length] ?? 1;
      rotate(next);
      return next;
    });
  }, [rotate]);
  const handleScreenshot = useCallback(() => {
    void screenshotToClipboard();
  }, [screenshotToClipboard]);

  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        height: "100%",
        color: tokens.color.text,
        background: `var(--background, ${tokens.color.panel})`,
        fontFamily: tokens.font.prose,
        position: "relative",
      }}
    >
      <Keyframes />
      <DeviceToolbar
        devices={devices}
        selectedUdid={selectedUdid}
        state={selectedState}
        onPick={selectUdid}
        onBoot={() => selectedUdid && bootDevice(selectedUdid)}
        onShutdown={() => selectedUdid && shutdownDevice(selectedUdid)}
        inspectOn={inspectOn}
        onToggleInspect={() => setInspectOn((value) => !value)}
        bootStatus={bootStatus}
        onHome={handleHome}
        onScreenshot={handleScreenshot}
        onRotate={handleRotate}
        onMenuOpenChange={setSimSuppressed}
      />
      <div
        ref={stageRef}
        style={{
          flex: 1,
          minHeight: 0,
          display: "flex",
          flexDirection: "column",
          overflowX: "hidden",
          overflowY: needsScroll ? "auto" : "hidden",
          padding: "16px 24px 24px",
          background: "transparent",
        }}
      >
        <div
          style={{
            flex: "1 1 auto",
            minWidth: 0,
            minHeight: 0,
            display: "flex",
            justifyContent: needsScroll ? "flex-start" : "center",
            alignItems: needsScroll ? "flex-start" : "center",
            position: "relative",
          }}
        >
          {/* Rotation envelope. The chrome is laid out in portrait and CSS
           *  rotated to land its AABB in the envelope's box, so the parent
           *  flex layout reserves the rotated footprint correctly. The
           *  inner div is absolutely centered so the rotation pivots
           *  around the envelope center regardless of natural chrome size. */}
          <div
            style={{
              position: "relative",
              width: envelopeWidth,
              height: envelopeHeight,
              flex: "0 0 auto",
            }}
          >
            <div
              style={{
                position: "absolute",
                left: "50%",
                top: "50%",
                transform: `translate(-50%, -50%) rotate(${rotationDeg}deg)`,
                transformOrigin: "center",
                // No CSS transition: the simView NSView (positioned by the
                // bridge's exported CALayerHost) can't follow an interpolated
                // transform, so animating the chrome would desync the bezel
                // and the iOS content for ~280ms. Snap matches Simulator.app's
                // own rotation-shortcut behavior anyway.
              }}
            >
              <DeviceChrome
                descriptor={descriptor}
                screenWidth={screenWidth}
                screenHeight={screenHeight}
              >
                {/* Empty cutout. The CALayerHost NSView is mounted above the
                 *  HTML by Electron's main process (NSWindowAbove), so anything
                 *  painted in this div is invisible. Outlines + hit highlights
                 *  are drawn natively on the layer — see apps/desktop/src/simView.ts
                 *  setOutlines(). */}
                <div
                  ref={cutoutRef}
                  data-sim-cutout
                  style={{ width: "100%", height: "100%", position: "relative" }}
                />
              </DeviceChrome>
            </div>
          </div>
        </div>
      </div>
      {inspectOn ? (
        <InspectCard
          hovered={hovered}
          selected={selected}
          previewChain={previewChain}
          sourceContext={previewSource}
          onSyncChat={() => syncSelectedToChat(true)}
          onCopy={copySelectedToClipboard}
          onClearSelection={clearSelection}
          onExit={() => setInspectOn(false)}
          {...(openSource ? { onOpenSource: openSource } : {})}
        />
      ) : null}
      {error ? (
        <div
          role="alert"
          style={{
            borderTop: "1px solid rgba(255,122,138,0.3)",
            background: "rgba(255,122,138,0.08)",
            color: tokens.color.accentError,
            padding: "10px 14px",
            fontFamily: tokens.font.mono,
            fontSize: 11,
            letterSpacing: "0.04em",
          }}
        >
          <span style={{ textTransform: "uppercase", opacity: 0.7, marginRight: 10 }}>
            {error.code}
          </span>
          {error.message}
        </div>
      ) : null}
    </div>
  );
}

function Keyframes(): ReactElement {
  return (
    <style>{`
      @keyframes t3sim-live-pulse {
        0%, 100% { opacity: 1; transform: scale(1); }
        50% { opacity: 0.55; transform: scale(0.92); }
      }
      @keyframes t3sim-fade-in {
        from { opacity: 0; transform: translateY(4px); }
        to { opacity: 1; transform: translateY(0); }
      }
      @keyframes t3sim-spin {
        from { transform: rotate(0deg); }
        to { transform: rotate(360deg); }
      }
      @keyframes t3sim-tap-pulse {
        0% { transform: scale(0.6); opacity: 1; }
        70% { transform: scale(1.15); opacity: 0.35; }
        100% { transform: scale(1.35); opacity: 0; }
      }
      @keyframes t3sim-inspect-pulse {
        0%, 100% { opacity: 1; transform: scale(1); }
        50% { opacity: 0.55; transform: scale(0.78); }
      }
    `}</style>
  );
}
