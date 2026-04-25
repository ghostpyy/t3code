export interface SimViewEvent {
  kind: "down" | "move" | "up" | "ax-hit" | "ax-hover" | "key-down" | "key-up";
  x?: number;
  y?: number;
  usage?: number;
  modifiers?: number;
  chars?: string;
}

export class SimView {
  constructor(contextId: number);
  attach(windowHandle: Buffer): void;
  setBounds(rect: {
    x: number;
    y: number;
    width: number;
    height: number;
    refWidth?: number;
    refHeight?: number;
    cornerRadius?: number;
  }): void;
  setSourcePixelSize(size: { width: number; height: number }): void;
  setMode(mode: "input" | "inspect"): void;
  /** Paint the selected outline atop the simulator pixels. `chainRects` uses
   *  display points; `scale` converts points to source pixels. Pass an empty
   *  array to clear. */
  setOutlines(
    chainRects: ReadonlyArray<{ x: number; y: number; width: number; height: number }>,
    scale: number,
  ): void;
  on(cb: (jsonPayload: string) => void): void;
  destroy(): void;
}
