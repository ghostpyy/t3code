import { useCallback, useEffect, useRef, useState } from "react";
import {
  SimPane,
  type SimPaneBounds,
  type SimPaneMode,
  type SimPaneOutlineRect,
} from "@t3tools/sim-pane";

import { readLocalApi } from "../localApi";
import { openInPreferredEditor } from "../editorPreferences";
import { Sidebar, SidebarProvider, SidebarRail } from "./ui/sidebar";
import {
  SIM_PANE_TOGGLE_EVENT,
  dispatchSimPaneSourceReference,
  type SimPaneToggleEventDetail,
} from "~/lib/simPaneEvents";

// Width keys are versioned so users with a stale localStorage value from the
// overly-narrow previous default get the new sensible default automatically.
const RAIL_STORAGE_KEY = "sim_pane_rail_width_v3";
const RAIL_VISIBLE_STORAGE_KEY = "sim_pane_rail_visible";
const RAIL_MIN_WIDTH = 18 * 16; // 288 px
const RAIL_MAX_WIDTH = 56 * 16; // 896 px — wide enough to inspect comfortably
const RAIL_DEFAULT_WIDTH = 28 * 16; // 448 px — fits full toolbar + device chrome

export function SimPaneRail() {
  const [visible, setVisible] = useState(() => readVisible());
  const railRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    const onToggle = (event: Event): void => {
      const detail = (event as CustomEvent<SimPaneToggleEventDetail>).detail;
      const next = typeof detail?.visible === "boolean" ? detail.visible : !readVisible();
      window.localStorage.setItem(RAIL_VISIBLE_STORAGE_KEY, next ? "1" : "0");
      setVisible(next);
    };
    window.addEventListener(SIM_PANE_TOGGLE_EVENT, onToggle);
    return () => window.removeEventListener(SIM_PANE_TOGGLE_EVENT, onToggle);
  }, []);

  // Publish the rail's occupied width to `--sim-rail-gap` on the document
  // root so overlays pinned to the viewport (toasts, dropdowns) can inset
  // their right edge around the native CALayerHost NSView mounted inside
  // this rail. The NSView sits above all HTML via NSWindowAbove — any
  // element landing in the rail's column is invisible without this gap.
  useEffect(() => {
    const root = typeof document !== "undefined" ? document.documentElement : null;
    if (!root) return;
    if (!visible) {
      root.style.setProperty("--sim-rail-gap", "0px");
      return () => root.style.removeProperty("--sim-rail-gap");
    }
    const node = railRef.current;
    if (!node) return;
    const publish = (): void => {
      const width = Math.round(node.getBoundingClientRect().width);
      root.style.setProperty("--sim-rail-gap", `${width}px`);
    };
    publish();
    const ro = typeof ResizeObserver !== "undefined" ? new ResizeObserver(publish) : null;
    ro?.observe(node);
    window.addEventListener("resize", publish);
    return () => {
      ro?.disconnect();
      window.removeEventListener("resize", publish);
      root.style.removeProperty("--sim-rail-gap");
    };
  }, [visible]);

  const publishBounds = useCallback((rect: SimPaneBounds) => {
    void window.desktopBridge?.simulator?.setBounds?.(rect);
  }, []);

  const publishMode = useCallback((mode: SimPaneMode) => {
    void window.desktopBridge?.simulator?.setMode?.(mode);
  }, []);

  const publishOutlines = useCallback((rects: readonly SimPaneOutlineRect[], selectedIndex = 0) => {
    void window.desktopBridge?.simulator?.setOutlines?.(rects, selectedIndex);
  }, []);

  const insertChatMention = useCallback(
    (markdown: string, options?: { replaceExisting?: boolean; focusComposer?: boolean }) => {
      dispatchSimPaneSourceReference(markdown, options);
    },
    [],
  );

  const openSource = useCallback((absolutePath: string, line: number) => {
    const api = readLocalApi();
    if (!api) return;
    void openInPreferredEditor(api, `${absolutePath}:${line}`);
  }, []);

  const copyToClipboard = useCallback((markdown: string) => {
    if (typeof navigator !== "undefined" && navigator.clipboard?.writeText) {
      void navigator.clipboard.writeText(markdown);
    }
  }, []);

  if (!visible) return null;

  return (
    // Wrapper div exists solely so we can measure the rail's actual occupied
    // width for `--sim-rail-gap`. `display: contents` has no bounding box, so
    // we use a plain flex wrapper that doesn't grow or shrink.
    <div ref={railRef} className="flex flex-none" style={{ flex: "0 0 auto" }}>
      {/* Own SidebarProvider so `--sidebar-width` does not collide with the
          main left sidebar (which lives in a separate provider one layer up).
          Dragging here resizes ONLY this rail; the chat column keeps its width. */}
      <SidebarProvider
        defaultOpen
        className="w-auto min-h-0 flex-none bg-transparent"
        style={{ ["--sidebar-width" as string]: `${RAIL_DEFAULT_WIDTH}px` }}
      >
        <Sidebar
          side="right"
          collapsible="offcanvas"
          className="border-l border-border bg-card text-foreground"
          resizable={{
            minWidth: RAIL_MIN_WIDTH,
            maxWidth: RAIL_MAX_WIDTH,
            storageKey: RAIL_STORAGE_KEY,
          }}
        >
          <div className="flex h-full min-h-0 w-full flex-col overflow-hidden">
            <SimPane
              publishBounds={publishBounds}
              publishMode={publishMode}
              publishOutlines={publishOutlines}
              insertChatMention={insertChatMention}
              copyToClipboard={copyToClipboard}
              openSource={openSource}
            />
          </div>
          <SidebarRail />
        </Sidebar>
      </SidebarProvider>
    </div>
  );
}

function readVisible(): boolean {
  if (typeof window === "undefined") return true;
  const raw = window.localStorage.getItem(RAIL_VISIBLE_STORAGE_KEY);
  if (raw === null) return true;
  return raw === "1";
}
