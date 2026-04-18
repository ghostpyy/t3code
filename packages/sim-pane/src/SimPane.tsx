import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type PointerEvent as ReactPointerEvent,
  type ReactElement,
} from "react";
import {
  openSourceUrl,
  sourceRefHasLocation,
  sourceRefLabel,
  OPEN_SOURCE_EVENT,
  SOURCE_REFERENCE_EVENT,
  type OpenSourceEventDetail,
  type SourceRef,
  type SourceReferenceEventDetail,
} from "./protocol.ts";
import { useSimBridge, type UseSimBridgeOptions } from "./useSimBridge.ts";

export type SimPaneMode = "tap" | "inspect";

export type SimPaneProps = UseSimBridgeOptions & {
  readonly className?: string;
  readonly defaultMode?: SimPaneMode;
  readonly showStatusBar?: boolean;
  readonly onSourceReference?: (ref: SourceRef) => void;
  readonly autoEmitDomEvent?: boolean;
  readonly editorScheme?: string;
};

const SIM_BEZEL_PADDING = 12;
const MODE_STORAGE_KEY = "simpane:mode";

function readStoredMode(fallback: SimPaneMode): SimPaneMode {
  if (typeof window === "undefined") return fallback;
  const raw = window.localStorage.getItem(MODE_STORAGE_KEY);
  return raw === "tap" || raw === "inspect" ? raw : fallback;
}

export function SimPane(props: SimPaneProps): ReactElement {
  const showStatusBar = props.showStatusBar ?? true;
  const autoEmit = props.autoEmitDomEvent ?? true;
  const onSourceReference = props.onSourceReference;
  const editorScheme = props.editorScheme ?? "cursor";
  const defaultMode = props.defaultMode ?? "tap";

  const [mode, setMode] = useState<SimPaneMode>(() => readStoredMode(defaultMode));

  useEffect(() => {
    if (typeof window === "undefined") return;
    window.localStorage.setItem(MODE_STORAGE_KEY, mode);
  }, [mode]);

  const { state, lastError, info, frameImageUrl, frameSize, lastClicked, inspectAt, tap } =
    useSimBridge(props);

  const containerRef = useRef<HTMLDivElement>(null);
  const imgRef = useRef<HTMLImageElement>(null);
  const [hoverPoint, setHoverPoint] = useState<{ x: number; y: number } | null>(null);
  const [resolvedRef, setResolvedRef] = useState<SourceRef | null>(null);

  const aspect = useMemo(() => (frameSize ? frameSize.w / frameSize.h : 9 / 19.5), [frameSize]);

  const emitReference = useCallback(
    (ref: SourceRef): void => {
      setResolvedRef(ref);
      onSourceReference?.(ref);
      if (autoEmit && typeof window !== "undefined") {
        const detail: SourceReferenceEventDetail = { ref, label: sourceRefLabel(ref) };
        window.dispatchEvent(new CustomEvent(SOURCE_REFERENCE_EVENT, { detail }));
      }
    },
    [autoEmit, onSourceReference],
  );

  const emitOpenSource = useCallback(
    (ref: SourceRef): void => {
      if (typeof window === "undefined") return;
      const url = openSourceUrl(ref, editorScheme);
      if (!url) return;
      const detail: OpenSourceEventDetail = { ref, url };
      window.dispatchEvent(new CustomEvent(OPEN_SOURCE_EVENT, { detail }));
    },
    [editorScheme],
  );

  const toSimCoords = useCallback(
    (clientX: number, clientY: number): { x: number; y: number } | null => {
      const img = imgRef.current;
      const size = frameSize;
      if (!img || !size) return null;
      const rect = img.getBoundingClientRect();
      if (rect.width === 0 || rect.height === 0) return null;
      const localX = clientX - rect.left;
      const localY = clientY - rect.top;
      const sx = (localX / rect.width) * size.w;
      const sy = (localY / rect.height) * size.h;
      return { x: Math.round(sx), y: Math.round(sy) };
    },
    [frameSize],
  );

  const handleClick = useCallback(
    async (event: ReactPointerEvent<HTMLDivElement>): Promise<void> => {
      const coords = toSimCoords(event.clientX, event.clientY);
      if (!coords) return;
      if (mode === "inspect" || event.altKey) {
        const ref = await inspectAt(coords.x, coords.y);
        if (ref) {
          emitReference(ref);
          if (sourceRefHasLocation(ref)) emitOpenSource(ref);
        }
        return;
      }
      tap(coords.x, coords.y);
    },
    [mode, toSimCoords, inspectAt, tap, emitReference, emitOpenSource],
  );

  const handlePointerMove = useCallback(
    (event: ReactPointerEvent<HTMLDivElement>): void => {
      const coords = toSimCoords(event.clientX, event.clientY);
      if (coords) setHoverPoint(coords);
    },
    [toSimCoords],
  );

  const surfaceStyle: CSSProperties = {
    aspectRatio: `${aspect}`,
  };

  const activeRef = resolvedRef ?? lastClicked;

  return (
    <div
      ref={containerRef}
      className={`flex h-full w-full flex-col overflow-hidden bg-card text-foreground ${props.className ?? ""}`}
    >
      {showStatusBar ? (
        <div className="flex h-8 shrink-0 items-center justify-between gap-2 border-b border-border bg-background px-3 text-[11px] font-medium text-muted-foreground">
          <div className="flex min-w-0 items-center gap-2">
            <span
              className={`size-1.5 shrink-0 rounded-full ${
                state === "open"
                  ? "bg-emerald-400"
                  : state === "connecting"
                    ? "bg-amber-400"
                    : "bg-rose-400"
              }`}
              aria-hidden
            />
            <span className="truncate tabular-nums">
              {state === "open"
                ? info
                  ? `${info.name} \u00b7 ${info.model}`
                  : "Connected"
                : state === "connecting"
                  ? "Connecting to sim-bridge\u2026"
                  : state === "closed"
                    ? "Disconnected. Retrying\u2026"
                    : "sim-bridge offline"}
            </span>
          </div>
          <div className="flex shrink-0 items-center gap-2">
            {hoverPoint ? (
              <span className="tabular-nums">
                {hoverPoint.x}, {hoverPoint.y}
              </span>
            ) : null}
            <ModeToggle mode={mode} onChange={setMode} />
          </div>
        </div>
      ) : null}

      <div
        className="relative flex flex-1 items-center justify-center bg-black/40 select-none"
        style={{ padding: SIM_BEZEL_PADDING }}
      >
        <div
          className={`relative flex max-h-full max-w-full items-center justify-center overflow-hidden rounded-[34px] bg-black ring-1 shadow-2xl shadow-black/40 ${
            mode === "inspect" ? "ring-cyan-400/70 cursor-crosshair" : "ring-white/10"
          }`}
          style={surfaceStyle}
          onPointerDown={handleClick}
          onPointerMove={handlePointerMove}
          onPointerLeave={() => setHoverPoint(null)}
        >
          {frameImageUrl ? (
            <img
              ref={imgRef}
              src={frameImageUrl}
              alt="iOS Simulator"
              draggable={false}
              className="block h-full w-full object-cover"
            />
          ) : (
            <SimPlaceholder state={state} lastError={lastError} />
          )}
          {mode === "inspect" ? (
            <div className="pointer-events-none absolute inset-x-0 top-0 flex justify-center pt-2">
              <span className="rounded-full bg-cyan-500/90 px-2 py-0.5 text-[10px] font-semibold tracking-wide text-black uppercase">
                Inspect
              </span>
            </div>
          ) : null}
        </div>
      </div>

      {activeRef ? <RefStrip refValue={activeRef} onOpenSource={emitOpenSource} /> : null}
    </div>
  );
}

function ModeToggle({
  mode,
  onChange,
}: {
  mode: SimPaneMode;
  onChange: (next: SimPaneMode) => void;
}): ReactElement {
  return (
    <div className="flex items-center overflow-hidden rounded-md border border-border bg-muted/40 p-0.5 text-[10px] font-semibold uppercase tracking-wide">
      <button
        type="button"
        onClick={() => onChange("tap")}
        className={`px-2 py-0.5 transition-colors ${
          mode === "tap"
            ? "bg-foreground text-background"
            : "text-muted-foreground hover:text-foreground"
        }`}
      >
        Tap
      </button>
      <button
        type="button"
        onClick={() => onChange("inspect")}
        className={`px-2 py-0.5 transition-colors ${
          mode === "inspect"
            ? "bg-cyan-400 text-black"
            : "text-muted-foreground hover:text-foreground"
        }`}
      >
        Inspect
      </button>
    </div>
  );
}

function RefStrip({
  refValue,
  onOpenSource,
}: {
  refValue: SourceRef;
  onOpenSource: (ref: SourceRef) => void;
}): ReactElement {
  const hasLocation = sourceRefHasLocation(refValue);
  const role = refValue.role?.replace(/^AX/, "") ?? null;
  const label = refValue.title ?? refValue.value ?? refValue.identifier ?? null;
  return (
    <div className="flex shrink-0 items-center justify-between gap-2 border-t border-border bg-background/80 px-3 py-2 text-[11px] text-muted-foreground">
      <div className="flex min-w-0 flex-1 flex-col gap-0.5">
        {role || label ? (
          <div className="flex items-baseline gap-1.5 truncate">
            {role ? (
              <span className="rounded bg-muted/60 px-1.5 py-0.5 text-[10px] font-semibold tracking-wide text-foreground uppercase">
                {role}
              </span>
            ) : null}
            {label ? (
              <span className="truncate text-foreground">&ldquo;{label}&rdquo;</span>
            ) : null}
          </div>
        ) : null}
        {hasLocation ? (
          <code className="truncate rounded bg-muted/60 px-1.5 py-0.5 text-[10px] tracking-tight">
            {refValue.kind ? `${refValue.kind} ` : ""}
            {refValue.name ? `${refValue.name} ` : ""}
            {refValue.file}:{refValue.line}
          </code>
        ) : (
          <span className="text-[10px] italic text-muted-foreground/80">
            No source location (app does not expose #fileID)
          </span>
        )}
      </div>
      {hasLocation ? (
        <button
          type="button"
          onClick={() => onOpenSource(refValue)}
          className="shrink-0 rounded-md border border-border bg-muted/40 px-2 py-1 text-[10px] font-semibold uppercase tracking-wide text-foreground hover:bg-muted/70"
        >
          Open
        </button>
      ) : null}
    </div>
  );
}

function SimPlaceholder({
  state,
  lastError,
}: {
  state: string;
  lastError: string | null;
}): ReactElement {
  return (
    <div className="flex h-full w-full flex-col items-center justify-center gap-2 px-6 text-center text-[11px] text-muted-foreground">
      <div
        className="size-10 rounded-full border border-dashed border-muted-foreground/40"
        aria-hidden
      />
      <div className="font-medium text-foreground">
        {state === "open" ? "Waiting for first frame\u2026" : "iOS Simulator pane"}
      </div>
      <div className="leading-snug">
        Run <code className="rounded bg-muted/70 px-1 py-0.5">bun run sim:dev</code> in another
        shell to start the bridge.
      </div>
      {lastError ? <div className="mt-1 text-rose-300/80">{lastError}</div> : null}
    </div>
  );
}
