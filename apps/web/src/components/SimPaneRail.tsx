import { useEffect, useState } from "react";
import {
  OPEN_SOURCE_EVENT,
  SimPane,
  sourceRefLabel,
  type OpenSourceEventDetail,
  type SourceRef,
} from "@t3tools/sim-pane";

import { Sidebar, SidebarRail } from "./ui/sidebar";

const RAIL_STORAGE_KEY = "sim_pane_rail_width";
const RAIL_VISIBLE_STORAGE_KEY = "sim_pane_rail_visible";
const RAIL_MIN_WIDTH = 18 * 16;
const RAIL_MAIN_MIN_WIDTH = 32 * 16;

export function SimPaneRail() {
  const [visible, setVisible] = useState(() => readVisible());
  const [lastRef, setLastRef] = useState<SourceRef | null>(null);

  useEffect(() => {
    const onToggle = (event: Event): void => {
      const detail = (event as CustomEvent<{ visible?: boolean }>).detail;
      const next = typeof detail?.visible === "boolean" ? detail.visible : !readVisible();
      window.localStorage.setItem(RAIL_VISIBLE_STORAGE_KEY, next ? "1" : "0");
      setVisible(next);
    };
    window.addEventListener("simpane:toggle", onToggle);
    return () => window.removeEventListener("simpane:toggle", onToggle);
  }, []);

  useEffect(() => {
    const onOpenSource = (event: Event): void => {
      const detail = (event as CustomEvent<OpenSourceEventDetail>).detail;
      if (!detail?.url) return;
      window.location.href = detail.url;
    };
    window.addEventListener(OPEN_SOURCE_EVENT, onOpenSource);
    return () => window.removeEventListener(OPEN_SOURCE_EVENT, onOpenSource);
  }, []);

  if (!visible) return null;

  return (
    <Sidebar
      side="right"
      collapsible="offcanvas"
      className="border-l border-border bg-card text-foreground"
      resizable={{
        minWidth: RAIL_MIN_WIDTH,
        shouldAcceptWidth: ({ nextWidth, wrapper }) =>
          wrapper.clientWidth - nextWidth >= RAIL_MAIN_MIN_WIDTH,
        storageKey: RAIL_STORAGE_KEY,
      }}
    >
      <div className="flex h-full w-full flex-col">
        <SimPane onSourceReference={(ref) => setLastRef(ref)} />
        {lastRef ? (
          <div className="shrink-0 border-t border-border bg-background/80 px-3 py-1.5 text-[10px] text-muted-foreground">
            <span className="font-medium text-foreground">@here:</span>{" "}
            <code className="rounded bg-muted/60 px-1 py-0.5 tracking-tight">
              {sourceRefLabel(lastRef)}
            </code>
          </div>
        ) : null}
      </div>
      <SidebarRail />
    </Sidebar>
  );
}

function readVisible(): boolean {
  if (typeof window === "undefined") return true;
  const raw = window.localStorage.getItem(RAIL_VISIBLE_STORAGE_KEY);
  if (raw === null) return true;
  return raw === "1";
}
