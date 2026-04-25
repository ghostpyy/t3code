import { describe, it, expect } from "vitest";
import { getDeviceDescriptor } from "../src/lib/deviceDescriptors";

describe("deviceDescriptors", () => {
  it("resolves iPhone 16 Pro chrome family", () => {
    const d = getDeviceDescriptor("iPhone17,1");
    expect(d.family).toBe("dynamic-island");
    expect(d.buttons).toContain("side");
    expect(d.buttons).not.toContain("home-button");
  });

  it("resolves iPhone SE chrome family", () => {
    const d = getDeviceDescriptor("iPhone14,6");
    expect(d.family).toBe("home-button");
    expect(d.buttons).toContain("home-button");
  });

  it("resolves iPad Pro as ipad family", () => {
    const d = getDeviceDescriptor("iPad14,3");
    expect(d.family).toBe("ipad");
    expect(d.buttons).toContain("lock");
  });

  it("falls back to generic chrome for unknown model", () => {
    const d = getDeviceDescriptor("totally-unknown");
    expect(d.family).toBe("generic");
    expect(d.buttons).toEqual(["side", "volume-up", "volume-down"]);
  });

  it("exposes non-zero corner radius and bezel for every entry", () => {
    for (const model of ["iPhone17,1", "iPhone15,4", "iPhone14,6", "iPad14,3"]) {
      const d = getDeviceDescriptor(model);
      expect(d.cornerRadius).toBeGreaterThan(0);
      expect(d.bezelThickness).toBeGreaterThan(0);
    }
  });
});
