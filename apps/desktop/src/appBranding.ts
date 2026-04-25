import type { DesktopAppBranding, DesktopAppStageLabel } from "@t3tools/contracts";

import { isNightlyDesktopVersion } from "./updateChannels.ts";

const APP_BASE_NAME = "T3 Code";
const FORK_EDITION = "Ernn Edition";

export function resolveDesktopAppStageLabel(input: {
  readonly isDevelopment: boolean;
  readonly appVersion: string;
}): DesktopAppStageLabel {
  if (input.isDevelopment) {
    return "Dev";
  }

  return isNightlyDesktopVersion(input.appVersion) ? "Nightly" : "Alpha";
}

export function resolveDesktopAppBranding(input: {
  readonly isDevelopment: boolean;
  readonly appVersion: string;
}): DesktopAppBranding {
  const stageLabel = resolveDesktopAppStageLabel(input);
  const baseName = `${APP_BASE_NAME} ${FORK_EDITION}`;
  const displayName =
    stageLabel === "Alpha" ? baseName : `${baseName} (${stageLabel})`;
  return { baseName, stageLabel, displayName };
}
