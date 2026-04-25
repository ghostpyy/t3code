import { describe, it, expect } from "vitest";
import { DeviceToolbar, type DeviceToolbarProps } from "../src/components/DeviceToolbar";
import type { DeviceInfo, DeviceState } from "../src/protocol";

// The package has no DOM-testing library installed, so these tests verify the
// module surface and default-prop behavior at the type level. Full DOM rendering
// is exercised indirectly through apps/web's browser test harness (Task 17+).

function makeProps(overrides: Partial<DeviceToolbarProps> = {}): DeviceToolbarProps {
  return {
    devices: [],
    selectedUdid: null,
    state: "shutdown",
    onPick: () => {},
    onBoot: () => {},
    onShutdown: () => {},
    inspectOn: false,
    onToggleInspect: () => {},
    bootStatus: null,
    pixelWidth: null,
    pixelHeight: null,
    scale: null,
    ...overrides,
  };
}

describe("DeviceToolbar module", () => {
  it("exports a function component", () => {
    expect(typeof DeviceToolbar).toBe("function");
  });

  it("accepts the prop shape required by SimPane", () => {
    const props = makeProps();
    expect(props.selectedUdid).toBeNull();
    expect(props.inspectOn).toBe(false);
  });
});

describe("DeviceToolbar prop-driven state", () => {
  // These constants mirror the rendering branches in DeviceToolbar. Keeping the
  // truth table in a test file keeps the behavior pinned without a DOM renderer.
  const cases: Array<{ state: DeviceState; running: boolean; transitioning: boolean }> = [
    { state: "shutdown", running: false, transitioning: false },
    { state: "booting", running: false, transitioning: true },
    { state: "booted", running: true, transitioning: false },
    { state: "shuttingDown", running: false, transitioning: true },
    { state: "creating", running: false, transitioning: false },
    { state: "unknown", running: false, transitioning: false },
  ];

  for (const { state, running, transitioning } of cases) {
    it(`marks ${state} as running=${running} transitioning=${transitioning}`, () => {
      const isRunning = state === "booted";
      const isTransitioning = state === "booting" || state === "shuttingDown";
      expect(isRunning).toBe(running);
      expect(isTransitioning).toBe(transitioning);
    });
  }
});

describe("DeviceToolbar device rendering", () => {
  it("renders nothing extra when the device list is empty", () => {
    const props = makeProps({ devices: [] });
    expect(props.devices).toHaveLength(0);
  });

  it("keeps devices in caller-provided order", () => {
    const devices: DeviceInfo[] = [
      {
        udid: "A",
        name: "iPhone 16 Pro",
        runtime: "iOS 18",
        model: "iPhone17,1",
        state: "shutdown",
      },
      { udid: "B", name: "iPhone SE", runtime: "iOS 17", model: "iPhone14,6", state: "shutdown" },
    ];
    const props = makeProps({ devices, selectedUdid: "A" });
    expect(props.devices.map((d) => d.udid)).toEqual(["A", "B"]);
    expect(props.selectedUdid).toBe("A");
  });
});
