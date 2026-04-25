import type { ReactNode } from "react";
import { SidebarInset, SidebarTrigger } from "./ui/sidebar";
import { isElectron } from "../env";
import { cn } from "~/lib/utils";

export function NoActiveThreadState() {
  return (
    <SidebarInset className="h-dvh min-h-0 overflow-hidden overscroll-y-none bg-background text-foreground">
      <div className="relative flex min-h-0 min-w-0 flex-1 flex-col overflow-x-hidden bg-background">
        <header
          className={cn(
            "relative z-10 border-b border-border/50 px-3 sm:px-5",
            isElectron
              ? "drag-region flex h-[52px] items-center wco:h-[env(titlebar-area-height)]"
              : "py-2 sm:py-3",
          )}
        >
          {isElectron ? (
            <span className="text-xs text-muted-foreground/50 wco:pr-[calc(100vw-env(titlebar-area-width)-env(titlebar-area-x)+1em)]">
              No active thread
            </span>
          ) : (
            <div className="flex items-center gap-2">
              <SidebarTrigger className="size-7 shrink-0 md:hidden" />
              <span className="text-sm font-medium text-foreground md:text-muted-foreground/60">
                No active thread
              </span>
            </div>
          )}
        </header>

        <AmbientGlow />

        <div className="relative z-[1] flex flex-1 flex-col items-center justify-center px-6 py-10">
          <div className="flex w-full max-w-[520px] flex-col items-center text-center">
            <ThreadGlyph />
            <h1 className="mt-9 text-[26px] font-semibold tracking-tight text-foreground sm:text-[30px]">
              Nothing on the wire
            </h1>
            <p className="mt-3 max-w-[380px] text-[13.5px] leading-relaxed text-muted-foreground/80">
              Pick a thread from the sidebar to pick up where you left off, or start a new one to
              hand something fresh to an agent.
            </p>

            <div className="mt-8 flex items-center gap-2 text-[11px] uppercase tracking-[0.22em] text-muted-foreground/55">
              <span className="h-px w-10 bg-border/60" />
              Next step
              <span className="h-px w-10 bg-border/60" />
            </div>

            <div className="mt-5 flex flex-col items-center gap-3 sm:flex-row sm:gap-4">
              <HintChip label="Open an existing thread" glyph={<SidebarHintGlyph />} />
              <HintChip label="New thread" glyph={<PlusGlyph />} emphasis />
            </div>
          </div>
        </div>
      </div>
    </SidebarInset>
  );
}

function AmbientGlow() {
  return (
    <div
      aria-hidden
      className="pointer-events-none absolute inset-0 z-0 overflow-hidden"
      style={{
        background:
          "radial-gradient(60% 40% at 50% 42%, color-mix(in oklab, var(--primary) 14%, transparent) 0%, transparent 70%), " +
          "radial-gradient(90% 50% at 50% 110%, color-mix(in oklab, var(--foreground) 5%, transparent) 0%, transparent 70%)",
      }}
    />
  );
}

function ThreadGlyph() {
  return (
    <div className="relative">
      <div
        aria-hidden
        className="absolute inset-0 -z-10 rounded-full blur-2xl"
        style={{
          background:
            "radial-gradient(closest-side, color-mix(in oklab, var(--primary) 35%, transparent), transparent 70%)",
          opacity: 0.5,
        }}
      />
      <svg
        width="104"
        height="104"
        viewBox="0 0 104 104"
        aria-hidden
        className="text-foreground/75"
      >
        <defs>
          <linearGradient id="thread-stroke" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0%" stopColor="currentColor" stopOpacity="0.95" />
            <stop offset="100%" stopColor="currentColor" stopOpacity="0.35" />
          </linearGradient>
        </defs>
        <circle
          cx="52"
          cy="52"
          r="44"
          stroke="currentColor"
          strokeOpacity="0.12"
          strokeWidth="1"
          fill="none"
        />
        <circle
          cx="52"
          cy="52"
          r="32"
          stroke="currentColor"
          strokeOpacity="0.08"
          strokeWidth="1"
          strokeDasharray="2 5"
          fill="none"
        />
        <path
          d="M24 58 Q40 34 52 52 T80 50"
          stroke="url(#thread-stroke)"
          strokeWidth="1.75"
          strokeLinecap="round"
          fill="none"
        />
        <circle cx="24" cy="58" r="3.2" fill="currentColor" fillOpacity="0.85" />
        <circle cx="80" cy="50" r="3.2" fill="currentColor" fillOpacity="0.35" />
      </svg>
    </div>
  );
}

function HintChip({
  label,
  glyph,
  emphasis,
}: {
  label: string;
  glyph: ReactNode;
  emphasis?: boolean;
}) {
  return (
    <div
      className={cn(
        "inline-flex items-center gap-2 rounded-full border px-3.5 py-2 text-[12px] font-medium tracking-tight",
        emphasis
          ? "border-primary/40 bg-primary/8 text-foreground shadow-[0_0_0_1px_color-mix(in_oklab,var(--primary)_14%,transparent)]"
          : "border-border/60 bg-card/20 text-muted-foreground",
      )}
    >
      <span
        className={cn(
          "flex size-5 items-center justify-center rounded-full",
          emphasis ? "bg-primary/20 text-foreground" : "bg-muted/40 text-muted-foreground",
        )}
      >
        {glyph}
      </span>
      {label}
    </div>
  );
}

function PlusGlyph() {
  return (
    <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden>
      <path
        d="M5 1.5 V8.5 M1.5 5 H8.5"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinecap="round"
      />
    </svg>
  );
}

function SidebarHintGlyph() {
  return (
    <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden>
      <rect
        x="1.5"
        y="2"
        width="9"
        height="8"
        rx="1.6"
        stroke="currentColor"
        strokeWidth="1"
        fill="none"
      />
      <path d="M4.2 2 V10" stroke="currentColor" strokeWidth="1" />
    </svg>
  );
}
