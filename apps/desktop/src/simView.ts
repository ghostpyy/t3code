import { BrowserWindow, ipcMain } from "electron";
import path from "node:path";
import fs from "node:fs";

// Resolve the native CALayerHost addon at runtime from either dev or packaged
// location. Not imported as an npm workspace to avoid polluting the staged
// production install with a workspace-only package.
function resolveSimViewNative(): { SimView: any } | null {
  const candidates: string[] = [];
  if (process.resourcesPath) {
    candidates.push(path.join(process.resourcesPath, "simview.node"));
  }
  // Dev: relative to the compiled apps/desktop/dist-electron/main.cjs
  candidates.push(
    path.join(__dirname, "..", "native", "simview", "build", "Release", "simview.node"),
  );
  candidates.push(
    path.join(__dirname, "..", "..", "native", "simview", "build", "Release", "simview.node"),
  );
  for (const p of candidates) {
    if (fs.existsSync(p)) {
      try {
        return require(p);
      } catch (err) {
        console.error("[simview] failed to load native addon at", p, err);
      }
    }
  }
  return null;
}

const nativeModule = resolveSimViewNative();
const SimView: any = nativeModule?.SimView ?? null;

export interface SimInputEvent {
  kind: "down" | "move" | "up" | "ax-hit" | "ax-hover" | "ax-hover-exit" | "key-down" | "key-up";
  x?: number;
  y?: number;
  usage?: number;
  modifiers?: number;
  chars?: string;
}

export interface SimViewBounds {
  x: number;
  y: number;
  width: number;
  height: number;
  refWidth?: number;
  refHeight?: number;
  /**
   * Inner corner radius (CSS px) of the bezel's screen socket. The native
   * view rounds its CALayer by this amount so the live screen's four
   * corners match the bezel's rounded cutout instead of square-cornering
   * past the titanium arc. Omit or set 0 to disable rounding.
   */
  cornerRadius?: number;
  /**
   * UIDeviceOrientation: 1 portrait, 2 portraitUpsideDown, 3 landscapeRight,
   * 4 landscapeLeft. Renderer publishes the rotated AABB as `width/height`
   * and we invert the rotation in `projectPointer` so HID still receives
   * portrait-native pixel coordinates the simulator's touch digitizer
   * expects (Apple's HID stack rotates touches in-OS based on the
   * UIDeviceOrientation, so the daemon must send native pixels).
   */
  orientation?: 1 | 2 | 3 | 4;
}

export type SimViewMode = "input" | "inspect";

interface SimDisplayMetrics {
  pixelWidth: number;
  pixelHeight: number;
  scale: number;
}

const SIM_BOUNDS_CHANNEL = "sim:bounds-update";
const SIM_MODE_CHANNEL = "sim:mode";
const SIM_OUTLINES_CHANNEL = "sim:outlines";

export class SimViewHost {
  private readonly window: BrowserWindow;
  private view: InstanceType<typeof SimView> | null = null;
  private bounds: SimViewBounds = { x: 0, y: 0, width: 0, height: 0 };
  private displayMetrics: SimDisplayMetrics | null = null;
  private mode: SimViewMode = "input";
  private attachedContextId: number | null = null;
  public onEvent: (ev: SimInputEvent) => void = () => {};

  constructor(window: BrowserWindow) {
    this.window = window;
  }

  setBounds(rect: SimViewBounds): void {
    const next: SimViewBounds = {
      x: rect.x,
      y: rect.y,
      width: rect.width,
      height: rect.height,
    };
    if (rect.refWidth != null) next.refWidth = rect.refWidth;
    if (rect.refHeight != null) next.refHeight = rect.refHeight;
    if (rect.cornerRadius != null) next.cornerRadius = rect.cornerRadius;
    if (rect.orientation != null) next.orientation = rect.orientation;
    this.bounds = next;
    this.view?.setBounds(next);
  }

  setMode(mode: SimViewMode): void {
    this.mode = mode;
    this.view?.setMode(mode);
    // Switching out of inspect kills any lingering highlight immediately —
    // waiting for the next daemon frame would leave a stale outline while
    // the user is already back in touch mode.
    if (mode !== "inspect") this.view?.setOutlines([], 1);
  }

  /**
   * Paint the selected rect atop the simulator. `chain` is in display points.
   * Each entry may carry `cornerRadius` so the native stroke can round its
   * path to match the iOS element's own corners. Pass `[]` to clear.
   * Silently no-ops when display metrics aren't known yet because the
   * point→pixel scale is required for the rects to land pixel-aligned on
   * CALayerHost.
   */
  setOutlines(
    chain: ReadonlyArray<{
      x: number;
      y: number;
      width: number;
      height: number;
      cornerRadius?: number;
    }>,
    selectedIndex = 0,
  ): void {
    if (!this.view) return;
    const metrics = this.displayMetrics;
    const scale = metrics && metrics.scale > 0 ? metrics.scale : 1;
    const selected = chain[Math.max(0, Math.min(selectedIndex, chain.length - 1))];
    this.view.setOutlines(selected ? [selected] : [], scale);
  }

  updateDisplayMetrics(metrics: Partial<SimDisplayMetrics> | null): void {
    if (metrics == null) {
      this.displayMetrics = null;
      return;
    }
    const prev = this.displayMetrics;
    const next: SimDisplayMetrics = {
      pixelWidth: metrics.pixelWidth ?? prev?.pixelWidth ?? 0,
      pixelHeight: metrics.pixelHeight ?? prev?.pixelHeight ?? 0,
      scale: metrics.scale ?? prev?.scale ?? 1,
    };
    this.displayMetrics = next;
    if (this.view && next.pixelWidth > 0 && next.pixelHeight > 0) {
      this.view.setSourcePixelSize({ width: next.pixelWidth, height: next.pixelHeight });
    }
  }

  attach(contextId: number): void {
    if (this.window.isDestroyed()) return;
    if (SimView == null) {
      console.warn("[sim-view] native addon unavailable — simulator rendering disabled");
      return;
    }
    // Re-attaching with the same contextId is a no-op — avoid tearing down
    // a healthy surface when the daemon resends displayReady.
    if (this.view && this.attachedContextId === contextId) return;
    // contextId=0 is the daemon's signal to detach (device shutdown).
    if (contextId === 0) {
      this.view?.destroy();
      this.view = null;
      this.attachedContextId = null;
      return;
    }

    this.view?.destroy();
    this.view = null;
    this.attachedContextId = null;

    let view: InstanceType<typeof SimView>;
    try {
      view = new SimView(contextId);
    } catch (error) {
      console.warn("[sim-view] failed to construct SimView:", error);
      return;
    }

    try {
      const handle = this.window.getNativeWindowHandle();
      view.attach(handle);
      view.setMode(this.mode);
      view.setBounds(this.bounds);
      if (
        this.displayMetrics &&
        this.displayMetrics.pixelWidth > 0 &&
        this.displayMetrics.pixelHeight > 0
      ) {
        view.setSourcePixelSize({
          width: this.displayMetrics.pixelWidth,
          height: this.displayMetrics.pixelHeight,
        });
      }
      view.on((json: string) => {
        try {
          const parsed = JSON.parse(json) as SimInputEvent;
          // Rate-limit move logs; tap-related events are always logged to
          // confirm the touch pipeline is reaching the Electron layer.
          if (parsed.kind === "down" || parsed.kind === "up" || parsed.kind === "ax-hit") {
            console.info(
              `[sim-view] event kind=${parsed.kind} x=${parsed.x ?? "?"} y=${parsed.y ?? "?"}`,
            );
          }
          this.onEvent(parsed);
        } catch {
          /* malformed payload: drop */
        }
      });
      console.info(
        `[sim-view] attached contextId=${contextId} bounds=${JSON.stringify(this.bounds)}`,
      );
    } catch (error) {
      console.warn("[sim-view] failed to attach SimView:", error);
      try {
        view.destroy();
      } catch {
        /* ignore */
      }
      return;
    }

    this.view = view;
    this.attachedContextId = contextId;
  }

  dispose(): void {
    if (this.view) {
      try {
        this.view.destroy();
      } catch {
        /* already torn down */
      }
    }
    this.view = null;
    this.attachedContextId = null;
    this.displayMetrics = null;
  }

  mapEvent(ev: SimInputEvent): Record<string, unknown> | null {
    return mapEventToProtocol(ev, {
      bounds: this.bounds,
      display: this.displayMetrics,
    });
  }
}

export function registerSimViewIpc(host: SimViewHost): () => void {
  const boundsHandler = (_event: Electron.IpcMainInvokeEvent, rawRect: unknown) => {
    const rect = normalizeBounds(rawRect);
    if (!rect) return;
    host.setBounds(rect);
  };
  const modeHandler = (_event: Electron.IpcMainInvokeEvent, rawMode: unknown) => {
    if (rawMode !== "input" && rawMode !== "inspect") return;
    host.setMode(rawMode);
  };
  const outlinesHandler = (
    _event: Electron.IpcMainInvokeEvent,
    rawRects: unknown,
    rawIndex: unknown,
  ) => {
    host.setOutlines(
      normalizeOutlineRects(rawRects),
      typeof rawIndex === "number" && Number.isFinite(rawIndex) ? rawIndex : 0,
    );
  };

  ipcMain.handle(SIM_BOUNDS_CHANNEL, boundsHandler);
  ipcMain.handle(SIM_MODE_CHANNEL, modeHandler);
  ipcMain.handle(SIM_OUTLINES_CHANNEL, outlinesHandler);

  return () => {
    ipcMain.removeHandler(SIM_BOUNDS_CHANNEL);
    ipcMain.removeHandler(SIM_MODE_CHANNEL);
    ipcMain.removeHandler(SIM_OUTLINES_CHANNEL);
  };
}

function normalizeOutlineRects(value: unknown): ReadonlyArray<{
  x: number;
  y: number;
  width: number;
  height: number;
  cornerRadius?: number;
}> {
  if (!Array.isArray(value)) return [];
  return value.flatMap((item) => {
    if (!item || typeof item !== "object") return [];
    const { x, y, width, height, cornerRadius } = item as Record<string, unknown>;
    if (
      typeof x !== "number" ||
      typeof y !== "number" ||
      typeof width !== "number" ||
      typeof height !== "number" ||
      !Number.isFinite(x) ||
      !Number.isFinite(y) ||
      !Number.isFinite(width) ||
      !Number.isFinite(height)
    ) {
      return [];
    }
    const radius =
      typeof cornerRadius === "number" && Number.isFinite(cornerRadius) && cornerRadius > 0
        ? cornerRadius
        : undefined;
    return radius != null
      ? [{ x, y, width, height, cornerRadius: radius }]
      : [{ x, y, width, height }];
  });
}

function normalizeBounds(value: unknown): SimViewBounds | null {
  if (typeof value !== "object" || value === null) return null;
  const { x, y, width, height } = value as Partial<SimViewBounds>;
  if (
    typeof x !== "number" ||
    typeof y !== "number" ||
    typeof width !== "number" ||
    typeof height !== "number"
  ) {
    return null;
  }
  if (
    !Number.isFinite(x) ||
    !Number.isFinite(y) ||
    !Number.isFinite(width) ||
    !Number.isFinite(height)
  ) {
    return null;
  }
  const rawRefW = (value as { refWidth?: unknown }).refWidth;
  const rawRefH = (value as { refHeight?: unknown }).refHeight;
  const rawRadius = (value as { cornerRadius?: unknown }).cornerRadius;
  const rawOrientation = (value as { orientation?: unknown }).orientation;
  const refWidth = typeof rawRefW === "number" && Number.isFinite(rawRefW) ? rawRefW : undefined;
  const refHeight = typeof rawRefH === "number" && Number.isFinite(rawRefH) ? rawRefH : undefined;
  const cornerRadius =
    typeof rawRadius === "number" && Number.isFinite(rawRadius) && rawRadius >= 0
      ? rawRadius
      : undefined;
  const orientation: 1 | 2 | 3 | 4 | undefined =
    rawOrientation === 1 || rawOrientation === 2 || rawOrientation === 3 || rawOrientation === 4
      ? rawOrientation
      : undefined;

  // Subpixel-precise bounds: the bezel's SVG socket is rendered at the
  // exact CSS px from React layout, so the native view must match without
  // integer rounding. Any drift here shows as a 1-backing-pixel bright
  // hairline at the screen edge.
  return {
    x,
    y,
    width: Math.max(0, width),
    height: Math.max(0, height),
    ...(refWidth != null && refWidth > 0 ? { refWidth } : {}),
    ...(refHeight != null && refHeight > 0 ? { refHeight } : {}),
    ...(cornerRadius != null ? { cornerRadius } : {}),
    ...(orientation != null ? { orientation } : {}),
  };
}

export function mapEventToProtocol(
  ev: SimInputEvent,
  context?: { bounds?: SimViewBounds; display?: SimDisplayMetrics | null },
): Record<string, unknown> | null {
  switch (ev.kind) {
    case "down": {
      const point = projectPointer(ev, context, "pixels");
      return { type: "inputTap", x: point?.x ?? ev.x, y: point?.y ?? ev.y, phase: "down" };
    }
    case "up": {
      const point = projectPointer(ev, context, "pixels");
      return { type: "inputTap", x: point?.x ?? ev.x, y: point?.y ?? ev.y, phase: "up" };
    }
    case "move":
      // Single-point move — the daemon aggregates into drags.
      return {
        type: "inputDrag",
        points: [
          {
            x: projectPointer(ev, context, "pixels")?.x ?? ev.x,
            y: projectPointer(ev, context, "pixels")?.y ?? ev.y,
            t: 0,
          },
        ],
      };
    case "ax-hit":
    case "ax-hover":
      return {
        type: "axHit",
        x: projectPointer(ev, context, "points")?.x ?? ev.x,
        y: projectPointer(ev, context, "points")?.y ?? ev.y,
        mode: ev.kind === "ax-hover" ? "hover" : "select",
      };
    case "key-down":
      return { type: "inputKey", usage: ev.usage, down: true, modifiers: ev.modifiers ?? 0 };
    case "key-up":
      return { type: "inputKey", usage: ev.usage, down: false, modifiers: ev.modifiers ?? 0 };
    default:
      return null;
  }
}

function projectPointer(
  ev: SimInputEvent,
  context: { bounds?: SimViewBounds; display?: SimDisplayMetrics | null } | undefined,
  space: "pixels" | "points",
): { x: number; y: number } | null {
  if (typeof ev.x !== "number" || typeof ev.y !== "number") {
    return null;
  }
  const bounds = context?.bounds;
  const display = context?.display;
  if (
    !bounds ||
    !display ||
    bounds.width <= 0 ||
    bounds.height <= 0 ||
    display.pixelWidth <= 0 ||
    display.pixelHeight <= 0
  ) {
    return null;
  }
  // `bounds` is the rotated AABB of the bezel cutout (CSS px). The HID
  // coord system iOS expects is always the device's native portrait
  // pixel grid regardless of UIDeviceOrientation, so we project the
  // click into portrait ratios first and then scale by the portrait
  // pixel dims. Apple's framebuffer service may republish the surface
  // with rotated dims after rotation, which we normalize here with
  // min/max — `display.pixelWidth/Height` could arrive in either order
  // depending on iOS's republish timing.
  //
  // Mapping derived from rotating a portrait box around its center,
  // with screen-CW positive (CSS rotate(+deg) = CW):
  //   1 portrait        : rPX = rLX,     rPY = rLY
  //   2 upside-down     : rPX = 1 - rLX, rPY = 1 - rLY
  //   3 landscapeRight  : rPX = 1 - rLY, rPY = rLX        (CSS -90° = CCW)
  //   4 landscapeLeft   : rPX = rLY,     rPY = 1 - rLX    (CSS +90° = CW)
  // where rLX/rLY are the click ratios in the rotated AABB and rPX/rPY
  // are the equivalent ratios in the un-rotated portrait box.
  const ratioLX = clamp(ev.x / bounds.width);
  const ratioLY = clamp(ev.y / bounds.height);
  let ratioPX: number;
  let ratioPY: number;
  switch (bounds.orientation) {
    case 2:
      ratioPX = 1 - ratioLX;
      ratioPY = 1 - ratioLY;
      break;
    case 3:
      ratioPX = 1 - ratioLY;
      ratioPY = ratioLX;
      break;
    case 4:
      ratioPX = ratioLY;
      ratioPY = 1 - ratioLX;
      break;
    default:
      ratioPX = ratioLX;
      ratioPY = ratioLY;
      break;
  }
  const scale = display.scale > 0 ? display.scale : 1;
  const portraitW = Math.min(display.pixelWidth, display.pixelHeight);
  const portraitH = Math.max(display.pixelWidth, display.pixelHeight);
  const width = space === "points" ? portraitW / scale : portraitW;
  const height = space === "points" ? portraitH / scale : portraitH;
  return {
    x: ratioPX * width,
    y: ratioPY * height,
  };
}

function clamp(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  if (value <= 0) {
    return 0;
  }
  if (value >= 1) {
    return 1;
  }
  return value;
}

export const SimViewChannels = {
  BOUNDS: SIM_BOUNDS_CHANNEL,
  MODE: SIM_MODE_CHANNEL,
  OUTLINES: SIM_OUTLINES_CHANNEL,
} as const;
