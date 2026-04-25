import { SmartphoneIcon } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import {
  SIM_PANE_TOGGLE_EVENT,
  type SimPaneToggleEventDetail,
  dispatchSimPaneToggle,
} from "../lib/simPaneEvents";

import { Toggle } from "./ui/toggle";
import { Tooltip, TooltipPopup, TooltipTrigger } from "./ui/tooltip";

const SIM_PANE_VISIBLE_STORAGE_KEY = "sim_pane_rail_visible";

export function SimPaneToggle(): React.ReactElement {
  const [pressed, setPressed] = useState<boolean>(() => {
    if (typeof window === "undefined") return true;
    const raw = window.localStorage.getItem(SIM_PANE_VISIBLE_STORAGE_KEY);
    return raw === null ? true : raw === "1";
  });

  useEffect(() => {
    const onToggle = (event: Event) => {
      const detail = (event as CustomEvent<SimPaneToggleEventDetail>).detail;
      if (typeof detail?.visible === "boolean") {
        setPressed(detail.visible);
      } else if (typeof window !== "undefined") {
        const raw = window.localStorage.getItem(SIM_PANE_VISIBLE_STORAGE_KEY);
        setPressed(raw === null ? true : raw === "1");
      }
    };
    window.addEventListener(SIM_PANE_TOGGLE_EVENT, onToggle);
    return () => window.removeEventListener(SIM_PANE_TOGGLE_EVENT, onToggle);
  }, []);

  const onPressedChange = useCallback((next: boolean) => {
    dispatchSimPaneToggle(next);
  }, []);

  return (
    <Tooltip>
      <TooltipTrigger
        render={
          <Toggle
            className="shrink-0"
            pressed={pressed}
            onPressedChange={onPressedChange}
            aria-label="Toggle iOS Simulator pane"
            variant="outline"
            size="xs"
          >
            <SmartphoneIcon className="size-3" />
          </Toggle>
        }
      />
      <TooltipPopup side="bottom">Toggle iOS Simulator pane</TooltipPopup>
    </Tooltip>
  );
}
