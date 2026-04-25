import { describe, it, expect } from "vitest";
import { DeviceChrome } from "../src/components/DeviceChrome";
import { computeChromeGeometry } from "../src/lib/chromeSvg";
import { getDeviceDescriptor } from "../src/lib/deviceDescriptors";

// Pure-logic tests — the package ships without a DOM renderer, so we validate
// the geometry helper (what the component consumes) and the component import itself.

describe("DeviceChrome module", () => {
  it("exports a function component", () => {
    expect(typeof DeviceChrome).toBe("function");
  });
});

describe("chrome geometry for common families", () => {
  it("produces an island path for dynamic-island devices", () => {
    const d = getDeviceDescriptor("iPhone17,1");
    const g = computeChromeGeometry(d, 390, 844);
    expect(g.outerWidth).toBe(390 + 2 * d.bezelThickness);
    expect(g.outerHeight).toBe(844 + 2 * d.bezelThickness);
    expect(g.screenX).toBe(d.bezelThickness);
    expect(g.screenY).toBe(d.bezelThickness);
    expect(g.cornerRadius).toBe(d.cornerRadius);
    expect(typeof g.islandPath).toBe("string");
    expect(g.islandPath).toMatch(/^M /);
  });

  it("produces a notch path for notch devices", () => {
    const d = getDeviceDescriptor("iPhone15,4");
    const g = computeChromeGeometry(d, 390, 844);
    expect(d.family).toBe("notch");
    expect(typeof g.islandPath).toBe("string");
    expect(g.islandPath).toMatch(/^M /);
  });

  it("omits the island path for home-button devices", () => {
    const d = getDeviceDescriptor("iPhone14,6");
    const g = computeChromeGeometry(d, 320, 568);
    expect(g.islandPath).toBeNull();
  });

  it("omits the island path for ipad", () => {
    const d = getDeviceDescriptor("iPad14,3");
    const g = computeChromeGeometry(d, 820, 1180);
    expect(g.islandPath).toBeNull();
  });

  it("omits the island path for the generic fallback", () => {
    const d = getDeviceDescriptor("unknown");
    const g = computeChromeGeometry(d, 390, 844);
    expect(d.family).toBe("generic");
    expect(g.islandPath).toBeNull();
  });
});
