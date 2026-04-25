import { describe, it, expect } from "vitest";
import { __reduceForTest as reduce, type SimBridgeState } from "../src/useSimBridge";
import type { BridgeToPane } from "../src/protocol";

const INIT: SimBridgeState = {
  status: "ready",
  devices: [],
  selectedUdid: null,
  selectedState: "unknown",
  bootStatus: null,
  displayPixel: null,
  displayScale: null,
  displayOrientation: 1,
  error: null,
  hoveredHit: null,
  selectedHit: null,
  selectEventSeq: 0,
  lastTree: null,
  lastSnapshot: null,
};

const SAMPLE_CHAIN = [
  {
    id: "el-1",
    role: "button",
    label: "Play",
    value: null,
    frame: { x: 1, y: 2, width: 10, height: 10 },
    identifier: null,
    enabled: true,
    selected: false,
    children: null,
    appContext: null,
  },
];

describe("useSimBridge reducer", () => {
  it("records the device list", () => {
    const msg: BridgeToPane = {
      type: "deviceListResponse",
      devices: [
        { udid: "A", name: "iPhone 16", runtime: "iOS 18", model: "iPhone17,3", state: "shutdown" },
      ],
    };
    const next = reduce(INIT, msg);
    expect(next.devices).toHaveLength(1);
    expect(next.devices[0]?.udid).toBe("A");
  });

  it("syncs the selected state from the device list", () => {
    const next = reduce(
      {
        ...INIT,
        selectedUdid: "A",
        selectedState: "booting",
        bootStatus: "Starting",
      },
      {
        type: "deviceListResponse",
        devices: [
          { udid: "A", name: "iPhone 16", runtime: "iOS 18", model: "iPhone17,3", state: "booted" },
        ],
      },
    );
    expect(next.selectedState).toBe("booted");
    expect(next.bootStatus).toBe("Booted");
  });

  it("updates the selected device on deviceState", () => {
    const msg: BridgeToPane = {
      type: "deviceState",
      udid: "A",
      state: "booting",
      bootStatus: "Waiting on backboard",
    };
    const next = reduce(INIT, msg);
    expect(next.selectedUdid).toBe("A");
    expect(next.selectedState).toBe("booting");
    expect(next.bootStatus).toBe("Waiting on backboard");
  });

  it("stores display dimensions on displayReady", () => {
    const msg: BridgeToPane = {
      type: "displayReady",
      contextId: 5,
      pixelWidth: 1179,
      pixelHeight: 2556,
      scale: 3,
      orientation: 4,
    };
    const next = reduce(INIT, msg);
    expect(next.displayPixel).toEqual({ width: 1179, height: 2556 });
    expect(next.displayScale).toBe(3);
    expect(next.displayOrientation).toBe(4);
  });

  it("replaces dimensions on displaySurfaceChanged", () => {
    const base = reduce(INIT, {
      type: "displayReady",
      contextId: 5,
      pixelWidth: 1179,
      pixelHeight: 2556,
      scale: 3,
    });
    const next = reduce(base, {
      type: "displaySurfaceChanged",
      pixelWidth: 2556,
      pixelHeight: 1179,
    });
    expect(next.displayPixel).toEqual({ width: 2556, height: 1179 });
    expect(next.displayScale).toBe(3); // scale is preserved
  });

  it("clears pinned selection on displaySurfaceChanged (rotation invalidates frames)", () => {
    const withSelection = reduce(INIT, {
      type: "axHitResponse",
      mode: "select",
      hitIndex: 0,
      chain: SAMPLE_CHAIN,
    });
    expect(withSelection.selectedHit).not.toBeNull();
    const next = reduce(withSelection, {
      type: "displaySurfaceChanged",
      pixelWidth: 2556,
      pixelHeight: 1179,
    });
    expect(next.selectedHit).toBeNull();
    expect(next.hoveredHit).toBeNull();
  });

  it("clears pinned selection on displayReady (fresh surface)", () => {
    const withSelection = reduce(INIT, {
      type: "axHitResponse",
      mode: "select",
      hitIndex: 0,
      chain: SAMPLE_CHAIN,
    });
    const next = reduce(withSelection, {
      type: "displayReady",
      contextId: 9,
      pixelWidth: 1179,
      pixelHeight: 2556,
      scale: 3,
    });
    expect(next.selectedHit).toBeNull();
  });

  it("clears pinned selection when the device transitions out of booted", () => {
    const booted = reduce(INIT, {
      type: "deviceState",
      udid: "A",
      state: "booted",
      bootStatus: "Booted",
    });
    const withSelection = reduce(booted, {
      type: "axHitResponse",
      mode: "select",
      hitIndex: 0,
      chain: SAMPLE_CHAIN,
    });
    const shuttingDown = reduce(withSelection, {
      type: "deviceState",
      udid: "A",
      state: "shuttingDown",
      bootStatus: null,
    });
    expect(shuttingDown.selectedHit).toBeNull();
  });

  it("clears pinned selection when the active device changes", () => {
    const withDevice = reduce(
      { ...INIT, selectedUdid: "A" },
      {
        type: "axHitResponse",
        mode: "select",
        hitIndex: 0,
        chain: SAMPLE_CHAIN,
      },
    );
    expect(withDevice.selectedHit).not.toBeNull();
    const swapped = reduce(withDevice, {
      type: "deviceState",
      udid: "B",
      state: "booted",
      bootStatus: "Booted",
    });
    expect(swapped.selectedHit).toBeNull();
  });

  it("normalizes nested frame shape from axHitResponse", () => {
    // Simulate Swift-encoded CGRect nested {origin,size}.
    const msg = {
      type: "axHitResponse",
      mode: "select",
      hitIndex: 0,
      chain: [
        {
          id: "el-1",
          role: "button",
          label: "OK",
          value: null,
          frame: { origin: { x: 12, y: 24 }, size: { width: 100, height: 44 } },
          identifier: null,
          enabled: true,
          selected: false,
          children: null,
          appContext: null,
        },
      ],
    } as unknown as BridgeToPane;
    const next = reduce(INIT, msg);
    expect(next.selectedHit?.chain[0]?.frame).toEqual({ x: 12, y: 24, width: 100, height: 44 });
    expect(next.hoveredHit?.chain[0]?.frame).toEqual({ x: 12, y: 24, width: 100, height: 44 });
  });

  it("accepts already-flat frame shape", () => {
    const msg: BridgeToPane = {
      type: "axHitResponse",
      mode: "select",
      hitIndex: 0,
      chain: [
        {
          id: "el-1",
          role: "button",
          label: "OK",
          value: null,
          frame: { x: 5, y: 6, width: 30, height: 20 },
          identifier: null,
          enabled: true,
          selected: false,
          children: null,
          appContext: null,
        },
      ],
    };
    const next = reduce(INIT, msg);
    expect(next.selectedHit?.chain[0]?.frame).toEqual({ x: 5, y: 6, width: 30, height: 20 });
  });

  it("bumps selectEventSeq only on select-mode axHitResponse", () => {
    const afterHover = reduce(INIT, {
      type: "axHitResponse",
      mode: "hover",
      hitIndex: 0,
      chain: SAMPLE_CHAIN,
    });
    expect(afterHover.selectEventSeq).toBe(0);
    const afterSelect = reduce(afterHover, {
      type: "axHitResponse",
      mode: "select",
      hitIndex: 0,
      chain: SAMPLE_CHAIN,
    });
    expect(afterSelect.selectEventSeq).toBe(1);
    const afterSelect2 = reduce(afterSelect, {
      type: "axHitResponse",
      mode: "select",
      hitIndex: 0,
      chain: [],
    });
    expect(afterSelect2.selectEventSeq).toBe(2);
  });

  it("keeps the pinned selection when hover updates arrive", () => {
    const selected = reduce(INIT, {
      type: "axHitResponse",
      mode: "select",
      hitIndex: 0,
      chain: [
        {
          id: "selected",
          role: "button",
          label: "Selected",
          value: null,
          frame: { x: 5, y: 6, width: 30, height: 20 },
          identifier: null,
          enabled: true,
          selected: false,
          children: null,
          appContext: null,
        },
      ],
    });
    const hovered = reduce(selected, {
      type: "axHitResponse",
      mode: "hover",
      hitIndex: 0,
      chain: [
        {
          id: "hovered",
          role: "text",
          label: "Hovered",
          value: null,
          frame: { x: 50, y: 60, width: 80, height: 24 },
          identifier: null,
          enabled: true,
          selected: false,
          children: null,
          appContext: null,
        },
      ],
    });
    expect(hovered.selectedHit?.chain[0]?.id).toBe("selected");
    expect(hovered.hoveredHit?.chain[0]?.id).toBe("hovered");
  });

  it("captures errors", () => {
    const next = reduce(INIT, { type: "error", code: "boot", message: "x" });
    expect(next.error?.code).toBe("boot");
    expect(next.error?.message).toBe("x");
  });

  it("stores the normalized tree on axTreeResponse", () => {
    const msg = {
      type: "axTreeResponse",
      root: {
        id: "root",
        role: "application",
        label: "Springboard",
        value: null,
        frame: { origin: { x: 0, y: 0 }, size: { width: 390, height: 844 } },
        identifier: null,
        enabled: true,
        selected: false,
        children: [],
      },
    } as unknown as BridgeToPane;
    const next = reduce(INIT, msg);
    expect(next.lastTree?.id).toBe("root");
    expect(next.lastTree?.frame).toEqual({ x: 0, y: 0, width: 390, height: 844 });
    expect(next.lastTree?.children).toEqual([]);
  });

  it("stamps pinRanks at click time from the freshest available snapshot", () => {
    // Seed a snapshot so the reducer has a bucket to rank against.
    const snapshot: BridgeToPane = {
      type: "axSnapshotResponse",
      nodes: [
        {
          id: "book-1",
          parentId: null,
          role: "Inspectable",
          label: null,
          value: null,
          identifier: "LibraryView.swift:531",
          frame: { x: 20, y: 200, width: 72, height: 102 },
          enabled: true,
          selected: false,
        },
        {
          id: "book-2",
          parentId: null,
          role: "Inspectable",
          label: null,
          value: null,
          identifier: "LibraryView.swift:531",
          frame: { x: 20, y: 619, width: 72, height: 102 },
          enabled: true,
          selected: false,
        },
        {
          id: "book-3",
          parentId: null,
          role: "Inspectable",
          label: null,
          value: null,
          identifier: "LibraryView.swift:531",
          frame: { x: 20, y: 747, width: 72, height: 102 },
          enabled: true,
          selected: false,
        },
      ],
      appContext: null,
    };
    const withSnapshot = reduce(INIT, snapshot);
    // User clicks book 2 (Y=619 — rank 1 in Y-sorted bucket).
    const clicked = reduce(withSnapshot, {
      type: "axHitResponse",
      mode: "select",
      hitIndex: 0,
      chain: [
        {
          id: "el-1",
          role: "Inspectable",
          label: null,
          value: null,
          frame: { x: 20, y: 619, width: 72, height: 102 },
          identifier: "LibraryView.swift:531",
          enabled: true,
          selected: false,
          children: null,
          appContext: null,
        },
      ],
    });
    expect(clicked.selectedHit?.pinRanks).toEqual([1]);
  });

  it("leaves pinRanks all-null when the click lands before any snapshot has arrived", () => {
    const clicked = reduce(INIT, {
      type: "axHitResponse",
      mode: "select",
      hitIndex: 0,
      chain: [
        {
          id: "el-1",
          role: "Inspectable",
          label: null,
          value: null,
          frame: { x: 20, y: 619, width: 72, height: 102 },
          identifier: "LibraryView.swift:531",
          enabled: true,
          selected: false,
          children: null,
          appContext: null,
        },
      ],
    });
    expect(clicked.selectedHit?.pinRanks).toEqual([null]);
  });

  it("resolves null pinRanks on the next axSnapshotResponse when click-time frames are still present", () => {
    // Click arrives first (no snapshot yet) → pinRanks = [null].
    const clicked = reduce(INIT, {
      type: "axHitResponse",
      mode: "select",
      hitIndex: 0,
      chain: [
        {
          id: "el-1",
          role: "Inspectable",
          label: null,
          value: null,
          frame: { x: 20, y: 619, width: 72, height: 102 },
          identifier: "LibraryView.swift:531",
          enabled: true,
          selected: false,
          children: null,
          appContext: null,
        },
      ],
    });
    expect(clicked.selectedHit?.pinRanks).toEqual([null]);
    // First snapshot arrives 250ms later; click-time Y=619 still present.
    const resolved = reduce(clicked, {
      type: "axSnapshotResponse",
      nodes: [
        {
          id: "a",
          parentId: null,
          role: "Inspectable",
          label: null,
          value: null,
          identifier: "LibraryView.swift:531",
          frame: { x: 20, y: 200, width: 72, height: 102 },
          enabled: true,
          selected: false,
        },
        {
          id: "b",
          parentId: null,
          role: "Inspectable",
          label: null,
          value: null,
          identifier: "LibraryView.swift:531",
          frame: { x: 20, y: 619, width: 72, height: 102 },
          enabled: true,
          selected: false,
        },
      ],
      appContext: null,
    });
    expect(resolved.selectedHit?.pinRanks).toEqual([1]);
  });

  it("does not overwrite a non-null pinRank with a stale snapshot rank", () => {
    // Seed snapshot + click → rank stamped.
    const seeded = reduce(INIT, {
      type: "axSnapshotResponse",
      nodes: [
        {
          id: "a",
          parentId: null,
          role: "Inspectable",
          label: null,
          value: null,
          identifier: "LibraryView.swift:531",
          frame: { x: 20, y: 200, width: 72, height: 102 },
          enabled: true,
          selected: false,
        },
        {
          id: "b",
          parentId: null,
          role: "Inspectable",
          label: null,
          value: null,
          identifier: "LibraryView.swift:531",
          frame: { x: 20, y: 619, width: 72, height: 102 },
          enabled: true,
          selected: false,
        },
      ],
      appContext: null,
    });
    const clicked = reduce(seeded, {
      type: "axHitResponse",
      mode: "select",
      hitIndex: 0,
      chain: [
        {
          id: "el-1",
          role: "Inspectable",
          label: null,
          value: null,
          frame: { x: 20, y: 619, width: 72, height: 102 },
          identifier: "LibraryView.swift:531",
          enabled: true,
          selected: false,
          children: null,
          appContext: null,
        },
      ],
    });
    expect(clicked.selectedHit?.pinRanks).toEqual([1]);
    // A scroll happens; the new snapshot no longer contains the click-time
    // frame. The already-stamped rank must not regress.
    const scrolled = reduce(clicked, {
      type: "axSnapshotResponse",
      nodes: [
        {
          id: "a",
          parentId: null,
          role: "Inspectable",
          label: null,
          value: null,
          identifier: "LibraryView.swift:531",
          frame: { x: 20, y: 50, width: 72, height: 102 },
          enabled: true,
          selected: false,
        },
        {
          id: "b",
          parentId: null,
          role: "Inspectable",
          label: null,
          value: null,
          identifier: "LibraryView.swift:531",
          frame: { x: 20, y: 469, width: 72, height: 102 },
          enabled: true,
          selected: false,
        },
      ],
      appContext: null,
    });
    expect(scrolled.selectedHit?.pinRanks).toEqual([1]);
  });

  it("stores the flat snapshot on axSnapshotResponse", () => {
    const msg: BridgeToPane = {
      type: "axSnapshotResponse",
      nodes: [
        {
          id: "a",
          parentId: null,
          role: "Application",
          label: null,
          value: null,
          identifier: null,
          frame: { x: 0, y: 0, width: 390, height: 844 },
          enabled: true,
          selected: false,
        },
        {
          id: "b",
          parentId: "a",
          role: "Button",
          label: "Buy",
          value: null,
          identifier: "Satira/Views/Home.swift:42|Satira",
          frame: { x: 20, y: 100, width: 120, height: 44 },
          enabled: true,
          selected: false,
        },
      ],
      appContext: {
        bundleId: "com.satira.app",
        name: "Satira",
        pid: 1234,
        bundlePath: null,
        dataContainer: null,
        executablePath: null,
        projectPath: "/Users/ern/coding/satira",
      },
    };
    const next = reduce(INIT, msg);
    expect(next.lastSnapshot?.nodes).toHaveLength(2);
    expect(next.lastSnapshot?.nodes[1]?.parentId).toBe("a");
    expect(next.lastSnapshot?.appContext?.bundleId).toBe("com.satira.app");
    expect(next.lastSnapshot?.receivedAt).toBeGreaterThan(0);
  });
});
