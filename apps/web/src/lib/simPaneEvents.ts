// Local event constants previously hosted in @t3tools/sim-pane.
// The v3 sim-pane no longer owns these; the app keeps them as internal UI wiring.

export const SIM_PANE_TOGGLE_EVENT = "simpane:toggle";
export interface SimPaneToggleEventDetail {
  visible: boolean;
}

export const SIM_PANE_SOURCE_REFERENCE_EVENT = "simpane:source-reference";
export interface SimPaneSourceReferenceEventDetail {
  /** Ready-to-insert @here markdown from renderMentionMarkdown. */
  markdown: string;
  /** Replace the previous simulator inspect block when present. */
  replaceExisting?: boolean;
  /** Focus the composer after insertion. Defaults to true. */
  focusComposer?: boolean;
}

export function dispatchSimPaneToggle(visible: boolean): void {
  window.dispatchEvent(
    new CustomEvent<SimPaneToggleEventDetail>(SIM_PANE_TOGGLE_EVENT, {
      detail: { visible },
    }),
  );
}

export function dispatchSimPaneSourceReference(
  markdown: string,
  options: Pick<SimPaneSourceReferenceEventDetail, "replaceExisting" | "focusComposer"> = {},
): void {
  window.dispatchEvent(
    new CustomEvent<SimPaneSourceReferenceEventDetail>(SIM_PANE_SOURCE_REFERENCE_EVENT, {
      detail: { markdown, ...options },
    }),
  );
}
