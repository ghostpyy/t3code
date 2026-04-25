import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type ReactElement,
  type ReactNode,
} from "react";
import { createPortal } from "react-dom";
import type { DeviceInfo, DeviceState } from "../protocol.ts";
import { tokens } from "../tokens.ts";

export interface DeviceToolbarProps {
  devices: DeviceInfo[];
  selectedUdid: string | null;
  state: DeviceState;
  onPick: (udid: string) => void;
  onBoot: () => void;
  onShutdown: () => void;
  inspectOn: boolean;
  onToggleInspect: () => void;
  bootStatus: string | null;
  onHome: () => void;
  onScreenshot: () => void;
  onRotate: () => void;
  /** Fires when the device menu opens/closes so the parent can temporarily
   * suppress the native CALayerHost NSView (which otherwise composites
   * above any HTML dropdown and occludes it). */
  onMenuOpenChange?: (open: boolean) => void;
}

interface StateAppearance {
  dot: string;
  pulsing: boolean;
  tooltip: string;
}

function stateAppearance(state: DeviceState, bootStatus: string | null): StateAppearance {
  switch (state) {
    case "booted":
      return { dot: tokens.color.accentLive, pulsing: true, tooltip: "Live" };
    case "booting":
    case "creating":
      return {
        dot: tokens.color.accentBoot,
        pulsing: true,
        tooltip: bootStatus ?? "Booting",
      };
    case "shuttingDown":
      return { dot: tokens.color.accentBoot, pulsing: true, tooltip: "Stopping" };
    case "shutdown":
      return { dot: tokens.color.textFaint, pulsing: false, tooltip: "Idle" };
    default:
      return { dot: tokens.color.textFaint, pulsing: false, tooltip: "No device" };
  }
}

/**
 * Apple-Simulator-style toolbar. A single floating capsule that owns the
 * entire device control surface so the pane below stays uncluttered —
 * the phone is the hero.
 *
 *   ╭──────────────────────────────────────────────────────────╮
 *   │ ●  iPhone 17 Pro  26.2     ⌂ 📷 ↻  ◎  ▶                │
 *   ╰──────────────────────────────────────────────────────────╯
 */
export function DeviceToolbar(props: DeviceToolbarProps): ReactElement {
  const {
    devices,
    selectedUdid,
    state,
    onPick,
    onBoot,
    onShutdown,
    inspectOn,
    onToggleInspect,
    bootStatus,
    onHome,
    onScreenshot,
    onRotate,
    onMenuOpenChange,
  } = props;

  const selected = useMemo(
    () => devices.find((d) => d.udid === selectedUdid) ?? null,
    [devices, selectedUdid],
  );
  const running = state === "booted";
  const transitioning = state === "booting" || state === "shuttingDown";
  const { dot, pulsing, tooltip } = stateAppearance(state, bootStatus);

  const hostRef = useRef<HTMLDivElement | null>(null);
  const [hostWidth, setHostWidth] = useState<number>(Infinity);
  useEffect(() => {
    const el = hostRef.current;
    if (!el) return;
    const sync = (): void => setHostWidth(el.getBoundingClientRect().width);
    sync();
    const ro = typeof ResizeObserver !== "undefined" ? new ResizeObserver(sync) : null;
    ro?.observe(el);
    window.addEventListener("resize", sync);
    return () => {
      ro?.disconnect();
      window.removeEventListener("resize", sync);
    };
  }, []);

  const showRuntime = hostWidth >= 500;
  const showHardware = hostWidth >= 380;
  const compact = hostWidth < 440;

  return (
    <div
      ref={hostRef}
      style={{
        padding: "12px 14px 10px",
        background: tokens.color.panel,
        fontFamily: tokens.font.prose,
        color: tokens.color.text,
        position: "relative",
        zIndex: 2,
      }}
    >
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 10,
          padding: "5px 6px 5px 12px",
          borderRadius: 999,
          border: `1px solid ${tokens.color.hairlineStrong}`,
          background: "linear-gradient(180deg, rgba(20,22,26,0.88), rgba(12,14,18,0.92))",
          boxShadow:
            "inset 0 1px 0 rgba(255,255,255,0.05), 0 14px 30px -18px rgba(0,0,0,0.8), 0 1px 0 rgba(0,0,0,0.5)",
          backdropFilter: "blur(20px)",
        }}
      >
        <LiveDot color={dot} pulsing={pulsing} title={tooltip} />
        <DevicePicker
          devices={devices}
          selected={selected}
          onPick={onPick}
          disabled={transitioning}
          compact={compact}
          onOpenChange={onMenuOpenChange}
        />
        {showRuntime && selected?.runtime ? <MetaTag>{selected.runtime}</MetaTag> : null}

        <Spacer />

        {showHardware ? (
          <HardwareCluster
            enabled={running}
            onHome={onHome}
            onScreenshot={onScreenshot}
            onRotate={onRotate}
          />
        ) : null}

        <InspectToggle on={inspectOn} onToggle={onToggleInspect} disabled={!running} />
        <RunControl
          running={running}
          transitioning={transitioning}
          canBoot={!!selectedUdid}
          onBoot={onBoot}
          onShutdown={onShutdown}
        />
      </div>
    </div>
  );
}

/* ─────────────────────────────────────────────────────────────────────── */

function Spacer(): ReactElement {
  return <div style={{ flex: 1, minWidth: 0 }} />;
}

function MetaTag({ children }: { children: ReactNode }): ReactElement {
  return (
    <span
      style={{
        display: "inline-flex",
        alignItems: "center",
        padding: "2px 9px",
        borderRadius: 999,
        border: `1px solid ${tokens.color.hairline}`,
        color: tokens.color.textMuted,
        background: "transparent",
        whiteSpace: "nowrap",
        fontFamily: tokens.font.mono,
        fontSize: 10.5,
        flex: "0 0 auto",
      }}
    >
      {children}
    </span>
  );
}

function LiveDot({
  color,
  pulsing,
  title,
}: {
  color: string;
  pulsing: boolean;
  title?: string;
}): ReactElement {
  return (
    <span
      role="status"
      aria-label={title}
      title={title}
      style={{
        width: 8,
        height: 8,
        borderRadius: "50%",
        background: color,
        boxShadow: pulsing ? `0 0 10px ${color}` : "none",
        animation: pulsing ? "t3sim-live-pulse 1.8s ease-in-out infinite" : "none",
        flex: "0 0 auto",
      }}
    />
  );
}

/* ─── Device picker (portal + drop-down) ─────────────────────────────── */

function DevicePicker({
  devices,
  selected,
  onPick,
  disabled,
  compact,
  onOpenChange,
}: {
  devices: DeviceInfo[];
  selected: DeviceInfo | null;
  onPick: (udid: string) => void;
  disabled: boolean;
  compact: boolean;
  onOpenChange?: ((open: boolean) => void) | undefined;
}): ReactElement {
  const [open, setOpen] = useState(false);
  const anchorRef = useRef<HTMLButtonElement | null>(null);
  const title = selected?.name ?? "Select a device";

  const setOpenAndNotify = useCallback(
    (next: boolean) => {
      setOpen(next);
      onOpenChange?.(next);
    },
    [onOpenChange],
  );

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === "Escape") {
        e.preventDefault();
        setOpenAndNotify(false);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, setOpenAndNotify]);

  return (
    <div style={{ position: "relative", flex: "0 1 auto", minWidth: 0 }}>
      <button
        ref={anchorRef}
        type="button"
        onClick={() => setOpenAndNotify(!open)}
        disabled={disabled}
        title={title}
        aria-haspopup="listbox"
        aria-expanded={open}
        style={{
          display: "inline-flex",
          alignItems: "center",
          gap: 6,
          maxWidth: "100%",
          padding: "4px 8px 4px 10px",
          border: `1px solid ${open ? tokens.color.hairlineStrong : "transparent"}`,
          borderRadius: 999,
          background: open ? "rgba(255,255,255,0.035)" : "transparent",
          color: tokens.color.text,
          cursor: disabled ? "not-allowed" : "pointer",
          opacity: disabled ? 0.55 : 1,
          fontFamily: tokens.font.mono,
          fontSize: 12.5,
          fontWeight: 500,
          letterSpacing: "-0.01em",
          whiteSpace: "nowrap",
          overflow: "hidden",
          textOverflow: "ellipsis",
          transition: "background 140ms, border-color 140ms",
        }}
      >
        <span
          style={{
            maxWidth: compact ? 120 : 220,
            overflow: "hidden",
            textOverflow: "ellipsis",
            whiteSpace: "nowrap",
          }}
        >
          {title}
        </span>
        <ChevronGlyph open={open} />
      </button>
      {open ? (
        <PortaledDeviceMenu
          anchor={anchorRef.current}
          devices={devices}
          selectedUdid={selected?.udid ?? null}
          onPick={(udid) => {
            onPick(udid);
            setOpenAndNotify(false);
          }}
          onClose={() => setOpenAndNotify(false)}
        />
      ) : null}
    </div>
  );
}

/**
 * Portaled menu — required because the simulator's native `CALayerHost`
 * NSView composites *above* the webContents. HTML z-index cannot beat a
 * native view, so we render to document.body and rely on the parent to
 * temporarily suppress the NSView while the menu is open (via the
 * `onMenuOpenChange` handler).
 */
function PortaledDeviceMenu({
  anchor,
  devices,
  selectedUdid,
  onPick,
  onClose,
}: {
  anchor: HTMLElement | null;
  devices: DeviceInfo[];
  selectedUdid: string | null;
  onPick: (udid: string) => void;
  onClose: () => void;
}): ReactElement | null {
  const [coords, setCoords] = useState<{ left: number; top: number; width: number } | null>(null);

  useLayoutEffect(() => {
    if (!anchor) return;
    const measure = (): void => {
      const r = anchor.getBoundingClientRect();
      const width = Math.max(280, Math.min(360, window.innerWidth - 32));
      setCoords({ left: r.left, top: r.bottom + 8, width });
    };
    measure();
    window.addEventListener("resize", measure);
    window.addEventListener("scroll", measure, true);
    return () => {
      window.removeEventListener("resize", measure);
      window.removeEventListener("scroll", measure, true);
    };
  }, [anchor]);

  if (typeof document === "undefined" || !coords) return null;

  const clampedLeft = Math.max(8, Math.min(coords.left, window.innerWidth - coords.width - 8));

  return createPortal(
    <>
      <div
        onMouseDown={onClose}
        aria-hidden
        style={{
          position: "fixed",
          inset: 0,
          background: "rgba(2,3,5,0.35)",
          backdropFilter: "blur(3px)",
          zIndex: 2147483646,
          animation: "t3sim-fade-in 120ms ease-out",
        }}
      />
      <ul
        role="listbox"
        aria-label="Select a simulator"
        style={{
          position: "fixed",
          top: coords.top,
          left: clampedLeft,
          width: coords.width,
          maxHeight: Math.min(420, window.innerHeight - coords.top - 20),
          overflowY: "auto",
          padding: 6,
          margin: 0,
          background: "linear-gradient(180deg, rgba(18,20,24,0.98), rgba(10,12,16,0.98))",
          border: `1px solid ${tokens.color.hairlineStrong}`,
          borderRadius: 14,
          listStyle: "none",
          zIndex: 2147483647,
          boxShadow:
            "0 32px 64px -24px rgba(0,0,0,0.95), 0 1px 0 rgba(255,255,255,0.04) inset, 0 0 0 0.5px rgba(0,0,0,0.5)",
          backdropFilter: "blur(24px)",
          animation: "t3sim-fade-in 160ms cubic-bezier(0.2, 0.8, 0.2, 1)",
          fontFamily: tokens.font.prose,
        }}
      >
        {devices.length === 0 ? (
          <li
            style={{
              padding: "14px 12px",
              color: tokens.color.textFaint,
              fontFamily: tokens.font.mono,
              fontSize: 12,
              textAlign: "center",
            }}
          >
            No simulators available
          </li>
        ) : (
          devices.map((d) => (
            <DeviceMenuItem
              key={d.udid}
              device={d}
              active={d.udid === selectedUdid}
              onPick={() => onPick(d.udid)}
            />
          ))
        )}
      </ul>
    </>,
    document.body,
  );
}

function DeviceMenuItem({
  device,
  active,
  onPick,
}: {
  device: DeviceInfo;
  active: boolean;
  onPick: () => void;
}): ReactElement {
  const [hover, setHover] = useState(false);
  const stateChip = deviceStateChip(device.state);
  return (
    <li>
      <button
        type="button"
        onClick={onPick}
        onMouseEnter={() => setHover(true)}
        onMouseLeave={() => setHover(false)}
        style={{
          display: "grid",
          gridTemplateColumns: "20px 1fr auto",
          alignItems: "center",
          gap: 10,
          width: "100%",
          padding: "9px 10px",
          border: `1px solid ${active ? "rgba(142,255,154,0.25)" : "transparent"}`,
          borderRadius: 10,
          background: active
            ? "rgba(142,255,154,0.06)"
            : hover
              ? "rgba(255,255,255,0.04)"
              : "transparent",
          color: tokens.color.text,
          textAlign: "left",
          cursor: "pointer",
          fontFamily: tokens.font.prose,
          transition: "background 120ms",
        }}
      >
        <DeviceIconGlyph highlight={active} />
        <div style={{ minWidth: 0, display: "flex", flexDirection: "column", gap: 2 }}>
          <span
            style={{
              fontSize: 13,
              fontWeight: 500,
              letterSpacing: "-0.01em",
              overflow: "hidden",
              textOverflow: "ellipsis",
              whiteSpace: "nowrap",
              color: active ? tokens.color.accentLive : tokens.color.text,
            }}
          >
            {device.name}
          </span>
          <span
            style={{
              fontFamily: tokens.font.mono,
              fontSize: 10.5,
              color: tokens.color.textFaint,
              letterSpacing: "0.02em",
            }}
          >
            iOS {device.runtime}
          </span>
        </div>
        <span
          style={{
            display: "inline-flex",
            alignItems: "center",
            gap: 5,
            padding: "2px 8px",
            borderRadius: 999,
            background: stateChip.bg,
            color: stateChip.fg,
            fontFamily: tokens.font.mono,
            fontSize: 9.5,
            letterSpacing: "0.08em",
            textTransform: "uppercase",
            whiteSpace: "nowrap",
          }}
        >
          <span
            aria-hidden
            style={{
              width: 6,
              height: 6,
              borderRadius: 999,
              background: stateChip.fg,
              boxShadow: stateChip.glow ? `0 0 6px ${stateChip.fg}` : "none",
            }}
          />
          {stateChip.label}
        </span>
      </button>
    </li>
  );
}

interface StateChip {
  label: string;
  fg: string;
  bg: string;
  glow: boolean;
}

function deviceStateChip(state: DeviceState): StateChip {
  switch (state) {
    case "booted":
      return {
        label: "Live",
        fg: tokens.color.accentLive,
        bg: "rgba(142,255,154,0.1)",
        glow: true,
      };
    case "booting":
    case "creating":
      return {
        label: "Boot",
        fg: tokens.color.accentBoot,
        bg: "rgba(255,190,92,0.1)",
        glow: true,
      };
    case "shuttingDown":
      return {
        label: "Stop",
        fg: tokens.color.accentBoot,
        bg: "rgba(255,190,92,0.1)",
        glow: false,
      };
    default:
      return {
        label: "Idle",
        fg: tokens.color.textFaint,
        bg: "rgba(255,255,255,0.03)",
        glow: false,
      };
  }
}

/* ─── Hardware button cluster ────────────────────────────────────────── */

function HardwareCluster({
  enabled,
  onHome,
  onScreenshot,
  onRotate,
}: {
  enabled: boolean;
  onHome: () => void;
  onScreenshot: () => void;
  onRotate: () => void;
}): ReactElement {
  return (
    <div
      role="group"
      aria-label="Simulator hardware"
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: 1,
        padding: 2,
        borderRadius: 999,
        border: `1px solid ${tokens.color.hairline}`,
        background: "rgba(255,255,255,0.02)",
        opacity: enabled ? 1 : 0.45,
        flex: "0 0 auto",
      }}
    >
      <IconButton label="Home" tooltip="Home" onClick={onHome} disabled={!enabled}>
        <HomeGlyph />
      </IconButton>
      <IconButton
        label="Screenshot"
        tooltip="Screenshot"
        onClick={onScreenshot}
        disabled={!enabled}
      >
        <CameraGlyph />
      </IconButton>
      <IconButton label="Rotate" tooltip="Rotate 90°" onClick={onRotate} disabled={!enabled}>
        <RotateGlyph />
      </IconButton>
    </div>
  );
}

function IconButton({
  label,
  tooltip,
  onClick,
  disabled,
  children,
}: {
  label: string;
  tooltip: string;
  onClick: () => void;
  disabled: boolean;
  children: ReactElement;
}): ReactElement {
  const [hover, setHover] = useState(false);
  return (
    <button
      type="button"
      aria-label={label}
      title={tooltip}
      onClick={onClick}
      disabled={disabled}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        width: 26,
        height: 22,
        borderRadius: 999,
        border: "none",
        background: hover && !disabled ? "rgba(255,255,255,0.06)" : "transparent",
        color: disabled
          ? tokens.color.textFaint
          : hover
            ? tokens.color.text
            : tokens.color.textMuted,
        cursor: disabled ? "not-allowed" : "pointer",
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        padding: 0,
        transition: "color 120ms, background 120ms",
      }}
    >
      {children}
    </button>
  );
}

function RunControl({
  running,
  transitioning,
  canBoot,
  onBoot,
  onShutdown,
}: {
  running: boolean;
  transitioning: boolean;
  canBoot: boolean;
  onBoot: () => void;
  onShutdown: () => void;
}): ReactElement {
  if (running) {
    return (
      <button
        type="button"
        onClick={onShutdown}
        title="Shut down the simulator"
        style={{
          ...accentButtonBase,
          borderColor: "rgba(255,122,138,0.35)",
          color: tokens.color.accentError,
          background: "rgba(255,122,138,0.08)",
        }}
      >
        <StopGlyph />
        <span>Stop</span>
      </button>
    );
  }
  const disabled = !canBoot || transitioning;
  return (
    <button
      type="button"
      onClick={onBoot}
      disabled={disabled}
      title={transitioning ? "Booting the simulator…" : "Boot the selected simulator"}
      style={{
        ...accentButtonBase,
        borderColor: transitioning ? "rgba(255,190,92,0.35)" : "rgba(142,255,154,0.35)",
        color: transitioning ? tokens.color.accentBoot : tokens.color.accentLive,
        background: transitioning ? "rgba(255,190,92,0.08)" : "rgba(142,255,154,0.08)",
        opacity: disabled ? 0.45 : 1,
        cursor: disabled ? "not-allowed" : "pointer",
      }}
    >
      {transitioning ? <Spinner /> : <PlayGlyph />}
      <span>{transitioning ? "Booting" : "Boot"}</span>
    </button>
  );
}

const accentButtonBase: CSSProperties = {
  height: 28,
  padding: "0 12px",
  borderRadius: 999,
  border: `1px solid ${tokens.color.hairlineStrong}`,
  background: "transparent",
  color: tokens.color.text,
  fontSize: 11.5,
  fontWeight: 600,
  cursor: "pointer",
  whiteSpace: "nowrap",
  display: "inline-flex",
  alignItems: "center",
  justifyContent: "center",
  gap: 6,
  flex: "0 0 auto",
  fontFamily: tokens.font.mono,
  letterSpacing: "0.02em",
};

function InspectToggle({
  on,
  onToggle,
  disabled,
}: {
  on: boolean;
  onToggle: () => void;
  disabled: boolean;
}): ReactElement {
  return (
    <button
      type="button"
      onClick={onToggle}
      aria-pressed={on}
      disabled={disabled}
      title={on ? "Exit inspect mode" : "Inspect UI elements (tap reveals the view hierarchy)"}
      style={{
        height: 28,
        padding: "0 12px",
        borderRadius: 999,
        border: `1px solid ${on ? "rgba(139,161,255,0.5)" : tokens.color.hairlineStrong}`,
        background: on ? "rgba(139,161,255,0.12)" : "transparent",
        color: disabled
          ? tokens.color.textFaint
          : on
            ? tokens.color.accentInfo
            : tokens.color.textMuted,
        cursor: disabled ? "not-allowed" : "pointer",
        fontFamily: tokens.font.mono,
        fontSize: 11.5,
        letterSpacing: "0.02em",
        display: "inline-flex",
        alignItems: "center",
        gap: 6,
        flex: "0 0 auto",
      }}
    >
      <InspectGlyph />
      <span>{on ? "Inspecting" : "Inspect"}</span>
    </button>
  );
}

/* ─── icons ──────────────────────────────────────────────────────────── */

function PlayGlyph(): ReactElement {
  return (
    <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden>
      <path d="M1 1 L9 5 L1 9 Z" fill="currentColor" />
    </svg>
  );
}

function StopGlyph(): ReactElement {
  return (
    <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden>
      <rect x="1.5" y="1.5" width="7" height="7" rx="1.5" fill="currentColor" />
    </svg>
  );
}

function Spinner(): ReactElement {
  return (
    <svg
      width="12"
      height="12"
      viewBox="0 0 12 12"
      aria-hidden
      style={{ animation: "t3sim-spin 1s linear infinite" }}
    >
      <circle
        cx="6"
        cy="6"
        r="4.5"
        stroke="currentColor"
        strokeWidth="1.5"
        fill="none"
        opacity="0.25"
      />
      <path
        d="M6 1.5 A 4.5 4.5 0 0 1 10.5 6"
        stroke="currentColor"
        strokeWidth="1.5"
        fill="none"
        strokeLinecap="round"
      />
    </svg>
  );
}

function InspectGlyph(): ReactElement {
  return (
    <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden>
      <circle cx="6" cy="6" r="4.5" stroke="currentColor" strokeWidth="1" fill="none" />
      <path
        d="M6 2.5 V5 M6 7 V9.5 M2.5 6 H5 M7 6 H9.5"
        stroke="currentColor"
        strokeWidth="1"
        fill="none"
        strokeLinecap="round"
      />
      <circle cx="6" cy="6" r="1" fill="currentColor" />
    </svg>
  );
}

function ChevronGlyph({ open }: { open: boolean }): ReactElement {
  return (
    <svg
      width="10"
      height="10"
      viewBox="0 0 10 10"
      aria-hidden
      style={{
        transform: open ? "rotate(180deg)" : "rotate(0deg)",
        transition: "transform 160ms cubic-bezier(0.2,0.8,0.2,1)",
        color: tokens.color.textFaint,
      }}
    >
      <path
        d="M2 3.8 L5 6.8 L8 3.8"
        stroke="currentColor"
        strokeWidth="1.1"
        fill="none"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function HomeGlyph(): ReactElement {
  return (
    <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden>
      <path
        d="M2 6 L6 2.2 L10 6 V9.5 H2 Z"
        stroke="currentColor"
        strokeWidth="1.1"
        fill="none"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function CameraGlyph(): ReactElement {
  return (
    <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden>
      <rect
        x="1.5"
        y="3.2"
        width="9"
        height="6.8"
        rx="1.4"
        stroke="currentColor"
        strokeWidth="1.1"
        fill="none"
      />
      <rect
        x="4.5"
        y="1.8"
        width="3"
        height="1.8"
        rx="0.5"
        stroke="currentColor"
        strokeWidth="1.1"
        fill="none"
      />
      <circle cx="6" cy="6.8" r="1.8" stroke="currentColor" strokeWidth="1.1" fill="none" />
    </svg>
  );
}

function RotateGlyph(): ReactElement {
  return (
    <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden>
      <path
        d="M2.2 6 A 3.8 3.8 0 1 1 4 9.4"
        stroke="currentColor"
        strokeWidth="1.1"
        fill="none"
        strokeLinecap="round"
      />
      <path
        d="M2.2 3.2 V6 H5"
        stroke="currentColor"
        strokeWidth="1.1"
        fill="none"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function DeviceIconGlyph({ highlight }: { highlight: boolean }): ReactElement {
  return (
    <svg width="14" height="18" viewBox="0 0 14 18" aria-hidden>
      <rect
        x="1.5"
        y="1.5"
        width="11"
        height="15"
        rx="2.2"
        stroke={highlight ? tokens.color.accentLive : tokens.color.textMuted}
        strokeWidth="1"
        fill="none"
      />
      <rect
        x="5"
        y="2.6"
        width="4"
        height="0.8"
        rx="0.3"
        fill={highlight ? tokens.color.accentLive : tokens.color.textFaint}
      />
    </svg>
  );
}
