import { describe, it, expect } from "vitest";
import { refreshPinFrames } from "../src/lib/refreshPinFrames";
import type { AXElement, AXNode } from "../src/protocol";

function el(partial: Partial<AXElement>): AXElement {
  return {
    id: partial.id ?? "el",
    role: partial.role ?? "button",
    label: partial.label ?? null,
    value: partial.value ?? null,
    frame: partial.frame ?? { x: 0, y: 0, width: 10, height: 10 },
    identifier: partial.identifier ?? null,
    enabled: partial.enabled ?? true,
    selected: partial.selected ?? false,
    children: partial.children ?? null,
    appContext: partial.appContext ?? null,
    sourceHints: partial.sourceHints ?? null,
  };
}

function node(partial: Partial<AXNode>): AXNode {
  return {
    id: partial.id ?? "n",
    parentId: partial.parentId ?? null,
    role: partial.role ?? "Inspectable",
    label: partial.label ?? null,
    value: partial.value ?? null,
    identifier: partial.identifier ?? null,
    frame: partial.frame ?? { x: 0, y: 0, width: 10, height: 10 },
    enabled: partial.enabled ?? true,
    selected: partial.selected ?? false,
  };
}

describe("refreshPinFrames", () => {
  it("returns the chain unchanged when no snapshot is available", () => {
    const chain = [el({ identifier: "LibraryView.swift:435" })];
    const result = refreshPinFrames(chain, undefined);
    expect(result).toEqual(chain);
  });

  it("returns an empty array for an empty chain", () => {
    expect(refreshPinFrames([], [node({ identifier: "x" })])).toEqual([]);
  });

  it("updates the frame of an element whose identifier matches a snapshot node", () => {
    const chain = [
      el({
        identifier: "LibraryView.swift:435",
        frame: { x: 20, y: 500, width: 150, height: 218 },
      }),
    ];
    const nodes = [
      node({
        identifier: "LibraryView.swift:435",
        frame: { x: 20, y: 425, width: 150, height: 218 },
      }),
    ];
    const [refreshed] = refreshPinFrames(chain, nodes);
    expect(refreshed?.frame.y).toBe(425);
    expect(refreshed?.frame.x).toBe(20);
    expect(refreshed?.frame.width).toBe(150);
    expect(refreshed?.frame.height).toBe(218);
  });

  it("keeps elements without identifiers untouched", () => {
    const chain = [
      el({
        identifier: null,
        frame: { x: 100, y: 100, width: 48, height: 48 },
      }),
    ];
    const nodes = [node({ identifier: "OtherView.swift:10" })];
    const [refreshed] = refreshPinFrames(chain, nodes);
    expect(refreshed?.frame).toEqual({ x: 100, y: 100, width: 48, height: 48 });
  });

  it("keeps elements whose identifier isn't present in the snapshot", () => {
    const chain = [
      el({
        identifier: "DismissedSheet.swift:12",
        frame: { x: 0, y: 0, width: 50, height: 50 },
      }),
    ];
    const [refreshed] = refreshPinFrames(chain, [node({ identifier: "Other.swift:1" })]);
    expect(refreshed?.frame).toEqual({ x: 0, y: 0, width: 50, height: 50 });
  });

  it("picks the centroid-nearest candidate when multiple nodes share an identifier", () => {
    const chain = [
      el({
        identifier: "LibraryView.swift:435",
        frame: { x: 200, y: 500, width: 100, height: 100 },
      }),
    ];
    // Three book covers from a ForEach, all sharing the same .inspectable()
    // anchor. After a small scroll each moved ~75px up.
    const nodes = [
      node({
        identifier: "LibraryView.swift:435",
        frame: { x: 20, y: 350, width: 100, height: 100 },
      }),
      node({
        identifier: "LibraryView.swift:435",
        frame: { x: 200, y: 425, width: 100, height: 100 },
      }),
      node({
        identifier: "LibraryView.swift:435",
        frame: { x: 380, y: 350, width: 100, height: 100 },
      }),
    ];
    const [refreshed] = refreshPinFrames(chain, nodes);
    expect(refreshed?.frame.x).toBe(200);
    expect(refreshed?.frame.y).toBe(425);
  });

  it("preserves corner radius from the snapshot when present", () => {
    const chain = [
      el({
        identifier: "Button.swift:10",
        frame: { x: 0, y: 0, width: 44, height: 44, cornerRadius: 10 },
      }),
    ];
    const nodes = [
      node({
        identifier: "Button.swift:10",
        frame: { x: 10, y: 10, width: 44, height: 44, cornerRadius: 22 },
      }),
    ];
    const [refreshed] = refreshPinFrames(chain, nodes);
    expect(refreshed?.frame.cornerRadius).toBe(22);
  });

  it("falls back to the stored corner radius when the snapshot lacks one", () => {
    const chain = [
      el({
        identifier: "Card.swift:42",
        frame: { x: 0, y: 0, width: 200, height: 120, cornerRadius: 16 },
      }),
    ];
    const nodes = [
      node({
        identifier: "Card.swift:42",
        frame: { x: 12, y: 100, width: 200, height: 120 },
      }),
    ];
    const [refreshed] = refreshPinFrames(chain, nodes);
    expect(refreshed?.frame.cornerRadius).toBe(16);
  });

  it("does not mutate the input chain", () => {
    const chain = [
      el({
        identifier: "X.swift:1",
        frame: { x: 1, y: 2, width: 3, height: 4 },
      }),
    ];
    const nodes = [
      node({
        identifier: "X.swift:1",
        frame: { x: 10, y: 20, width: 30, height: 40 },
      }),
    ];
    const [refreshed] = refreshPinFrames(chain, nodes);
    expect(refreshed).not.toBe(chain[0]);
    expect(chain[0]?.frame).toEqual({ x: 1, y: 2, width: 3, height: 4 });
  });

  it("uses the provided pin rank to pick the right ForEach instance after a large scroll", () => {
    // User pinned the 2nd book (Y=425 at click time). A subsequent fast
    // scroll shifts every book up by ~200pt. Centroid-nearest to the
    // click-time frame (centroid ≈ (250, 475)) would pick the 3rd book's
    // NEW position (centroid ≈ (250, 200)) over the 2nd book's NEW
    // position (centroid ≈ (250, 75)) — dist 275 vs 400 — and the outline
    // would follow the wrong book. Rank-based lookup into the Y-sorted
    // bucket keeps the 2nd book selected regardless of scroll magnitude.
    const chain = [
      el({
        identifier: "LibraryView.swift:435",
        frame: { x: 200, y: 425, width: 100, height: 100 },
      }),
    ];
    // After scroll, all three books have moved up ~350pt. Y-sorted bucket:
    //   [0] book 1: Y=-275 (was Y=75)
    //   [1] book 2: Y=75   (was Y=425) ← user's pin, rank 1
    //   [2] book 3: Y=425  (was Y=775)
    const nodes = [
      node({
        identifier: "LibraryView.swift:435",
        frame: { x: 20, y: -275, width: 100, height: 100 },
      }),
      node({
        identifier: "LibraryView.swift:435",
        frame: { x: 200, y: 75, width: 100, height: 100 },
      }),
      node({
        identifier: "LibraryView.swift:435",
        frame: { x: 380, y: 425, width: 100, height: 100 },
      }),
    ];
    const pinRanks = [1];
    const [refreshed] = refreshPinFrames(chain, nodes, pinRanks);
    expect(refreshed?.frame.y).toBe(75);
    expect(refreshed?.frame.x).toBe(200);
  });

  it("sorts the bucket Y-then-X so rank is stable across snapshot ordering", () => {
    // Snapshot arrives with nodes in reverse-document order. Rank 0 must
    // still point at the top-left instance (smallest Y, then smallest X).
    const chain = [
      el({
        identifier: "LibraryView.swift:531",
        frame: { x: 20, y: 100, width: 72, height: 102 },
      }),
    ];
    const nodes = [
      node({
        identifier: "LibraryView.swift:531",
        frame: { x: 200, y: 300, width: 72, height: 102 },
      }),
      node({
        identifier: "LibraryView.swift:531",
        frame: { x: 20, y: 300, width: 72, height: 102 },
      }),
      node({
        identifier: "LibraryView.swift:531",
        frame: { x: 20, y: 100, width: 72, height: 102 },
      }),
    ];
    // Y-sorted: [0] Y=100 X=20, [1] Y=300 X=20, [2] Y=300 X=200
    const [refreshed] = refreshPinFrames(chain, nodes, [0]);
    expect(refreshed?.frame).toMatchObject({ x: 20, y: 100 });
  });

  it("falls back to centroid-nearest when pinRanks is null for that entry", () => {
    const chain = [
      el({
        identifier: "LibraryView.swift:435",
        frame: { x: 200, y: 500, width: 100, height: 100 },
      }),
    ];
    const nodes = [
      node({
        identifier: "LibraryView.swift:435",
        frame: { x: 20, y: 350, width: 100, height: 100 },
      }),
      node({
        identifier: "LibraryView.swift:435",
        frame: { x: 200, y: 425, width: 100, height: 100 },
      }),
    ];
    const [refreshed] = refreshPinFrames(chain, nodes, [null]);
    expect(refreshed?.frame.x).toBe(200);
    expect(refreshed?.frame.y).toBe(425);
  });

  it("falls back to centroid-nearest when pinRanks index is out of range", () => {
    // Snapshot shrank (a book was removed, sheet dismissed). Stale rank
    // that no longer indexes into the bucket must not crash or pick
    // undefined; centroid-nearest is the safe fallback.
    const chain = [
      el({
        identifier: "LibraryView.swift:435",
        frame: { x: 200, y: 500, width: 100, height: 100 },
      }),
    ];
    const nodes = [
      node({
        identifier: "LibraryView.swift:435",
        frame: { x: 200, y: 425, width: 100, height: 100 },
      }),
      node({
        identifier: "LibraryView.swift:435",
        frame: { x: 20, y: 350, width: 100, height: 100 },
      }),
    ];
    const [refreshed] = refreshPinFrames(chain, nodes, [5]);
    expect(refreshed?.frame.x).toBe(200);
    expect(refreshed?.frame.y).toBe(425);
  });
});
