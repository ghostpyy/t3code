import { describe, expect, it } from "vitest";

import { mapEventToProtocol } from "./simView.ts";

const PORTRAIT_DISPLAY = { pixelWidth: 1170, pixelHeight: 2532, scale: 3 };

describe("mapEventToProtocol pointer rotation", () => {
  it("portrait passes ratios straight through to native pixels", () => {
    const result = mapEventToProtocol(
      { kind: "down", x: 100, y: 200 },
      {
        bounds: { x: 0, y: 0, width: 390, height: 844, orientation: 1 },
        display: PORTRAIT_DISPLAY,
      },
    );
    expect(result).toEqual({
      type: "inputTap",
      x: (100 / 390) * 1170,
      y: (200 / 844) * 2532,
      phase: "down",
    });
  });

  it("upside-down inverts both axes", () => {
    const result = mapEventToProtocol(
      { kind: "down", x: 100, y: 200 },
      {
        bounds: { x: 0, y: 0, width: 390, height: 844, orientation: 2 },
        display: PORTRAIT_DISPLAY,
      },
    );
    expect(result).toEqual({
      type: "inputTap",
      x: (1 - 100 / 390) * 1170,
      y: (1 - 200 / 844) * 2532,
      phase: "down",
    });
  });

  it("landscapeLeft (orientation 4, CSS +90° = CW) inverts the renderer's rotation", () => {
    // Landscape AABB after CSS rotate(+90°): width = portraitH, height = portraitW.
    // CW visual rotation moves the portrait *bottom-left* corner to the
    // landscape top-left, so a click at landscape (0, 0) lands at portrait
    // (0, 2532) (bottom-left in portrait pixel space).
    const tlResult = mapEventToProtocol(
      { kind: "down", x: 0, y: 0 },
      {
        bounds: { x: 0, y: 0, width: 844, height: 390, orientation: 4 },
        display: PORTRAIT_DISPLAY,
      },
    );
    expect(tlResult).toEqual({ type: "inputTap", x: 0, y: 2532, phase: "down" });

    // Landscape top-RIGHT was portrait top-LEFT before rotation (the
    // Dynamic Island corner is on the right edge in landscapeLeft).
    const trResult = mapEventToProtocol(
      { kind: "down", x: 844, y: 0 },
      {
        bounds: { x: 0, y: 0, width: 844, height: 390, orientation: 4 },
        display: PORTRAIT_DISPLAY,
      },
    );
    expect(trResult).toEqual({ type: "inputTap", x: 0, y: 0, phase: "down" });
  });

  it("landscapeRight (orientation 3, CSS -90° = CCW) inverts the renderer's rotation", () => {
    // CSS rotate(-90°): portrait *top-right* ends up at landscape top-left
    // (the Dynamic Island corner is on the left edge in landscapeRight).
    const tlResult = mapEventToProtocol(
      { kind: "down", x: 0, y: 0 },
      {
        bounds: { x: 0, y: 0, width: 844, height: 390, orientation: 3 },
        display: PORTRAIT_DISPLAY,
      },
    );
    expect(tlResult).toEqual({ type: "inputTap", x: 1170, y: 0, phase: "down" });

    // Landscape bottom-RIGHT corner = portrait bottom-LEFT before rotation.
    const brResult = mapEventToProtocol(
      { kind: "down", x: 844, y: 390 },
      {
        bounds: { x: 0, y: 0, width: 844, height: 390, orientation: 3 },
        display: PORTRAIT_DISPLAY,
      },
    );
    expect(brResult).toEqual({ type: "inputTap", x: 0, y: 2532, phase: "down" });
  });

  it("ax-hit projects in display points (uses scale)", () => {
    const result = mapEventToProtocol(
      { kind: "ax-hit", x: 0, y: 0 },
      {
        bounds: { x: 0, y: 0, width: 844, height: 390, orientation: 4 },
        display: PORTRAIT_DISPLAY,
      },
    );
    expect(result).toEqual({
      type: "axHit",
      x: 0,
      y: 2532 / 3,
      mode: "select",
    });
  });

  it("falls back to portrait when orientation field is absent", () => {
    const result = mapEventToProtocol(
      { kind: "down", x: 100, y: 200 },
      {
        bounds: { x: 0, y: 0, width: 390, height: 844 },
        display: PORTRAIT_DISPLAY,
      },
    );
    expect(result).toEqual({
      type: "inputTap",
      x: (100 / 390) * 1170,
      y: (200 / 844) * 2532,
      phase: "down",
    });
  });
});
