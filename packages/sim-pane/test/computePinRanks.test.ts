import { describe, it, expect } from "vitest";
import { computePinRanks } from "../src/lib/computePinRanks";
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

describe("computePinRanks", () => {
  it("returns an empty array for an empty chain", () => {
    expect(computePinRanks([], undefined)).toEqual([]);
    expect(computePinRanks([], [])).toEqual([]);
  });

  it("returns all nulls when no snapshot is available", () => {
    const chain = [el({ identifier: "A.swift:1" }), el({ identifier: "A.swift:1" })];
    expect(computePinRanks(chain, undefined)).toEqual([null, null]);
    expect(computePinRanks(chain, [])).toEqual([null, null]);
  });

  it("returns null for elements without identifiers", () => {
    const chain = [el({ identifier: null })];
    const nodes = [node({ identifier: "A.swift:1" })];
    expect(computePinRanks(chain, nodes)).toEqual([null]);
  });

  it("returns null when the identifier is absent from the snapshot", () => {
    const chain = [el({ identifier: "Dismissed.swift:1" })];
    const nodes = [node({ identifier: "Other.swift:2" })];
    expect(computePinRanks(chain, nodes)).toEqual([null]);
  });

  it("returns null when the identifier has a single candidate (nothing to rank)", () => {
    const chain = [
      el({
        identifier: "Settings.swift:10",
        frame: { x: 0, y: 0, width: 200, height: 50 },
      }),
    ];
    const nodes = [
      node({
        identifier: "Settings.swift:10",
        frame: { x: 0, y: 0, width: 200, height: 50 },
      }),
    ];
    expect(computePinRanks(chain, nodes)).toEqual([null]);
  });

  it("returns the Y-sorted rank of the exact-matching bucket entry", () => {
    const chain = [
      el({
        identifier: "LibraryView.swift:435",
        // User pinned the middle book.
        frame: { x: 200, y: 425, width: 150, height: 218 },
      }),
    ];
    const nodes = [
      node({
        identifier: "LibraryView.swift:435",
        frame: { x: 20, y: 750, width: 150, height: 218 },
      }),
      node({
        identifier: "LibraryView.swift:435",
        frame: { x: 380, y: 100, width: 150, height: 218 },
      }),
      node({
        identifier: "LibraryView.swift:435",
        frame: { x: 200, y: 425, width: 150, height: 218 },
      }),
    ];
    // Y-sorted:
    //   [0] Y=100 X=380
    //   [1] Y=425 X=200 ← match
    //   [2] Y=750 X=20
    expect(computePinRanks(chain, nodes)).toEqual([1]);
  });

  it("tiebreaks on X when two bucket entries share a Y", () => {
    const chain = [
      el({
        identifier: "Row.swift:20",
        frame: { x: 200, y: 100, width: 50, height: 50 },
      }),
    ];
    const nodes = [
      node({
        identifier: "Row.swift:20",
        frame: { x: 380, y: 100, width: 50, height: 50 },
      }),
      node({
        identifier: "Row.swift:20",
        frame: { x: 20, y: 100, width: 50, height: 50 },
      }),
      node({
        identifier: "Row.swift:20",
        frame: { x: 200, y: 100, width: 50, height: 50 },
      }),
    ];
    // Y all equal → X-sort: [0] X=20, [1] X=200, [2] X=380
    expect(computePinRanks(chain, nodes)).toEqual([1]);
  });

  it("returns null when no bucket entry frame-matches the chain entry", () => {
    // Click happened during a fast scroll; by the time the snapshot was
    // polled, the pinned book had moved off its click-time Y and no
    // bucket entry is within epsilon.
    const chain = [
      el({
        identifier: "LibraryView.swift:531",
        frame: { x: 20, y: 619, width: 72, height: 102 },
      }),
    ];
    const nodes = [
      node({
        identifier: "LibraryView.swift:531",
        frame: { x: 20, y: 200, width: 72, height: 102 },
      }),
      node({
        identifier: "LibraryView.swift:531",
        frame: { x: 112, y: 200, width: 72, height: 102 },
      }),
    ];
    expect(computePinRanks(chain, nodes)).toEqual([null]);
  });

  it("tolerates sub-point frame drift between hit and snapshot", () => {
    const chain = [
      el({
        identifier: "Row.swift:1",
        frame: { x: 20, y: 100, width: 72, height: 102 },
      }),
      el({
        identifier: "Row.swift:1",
        frame: { x: 112, y: 100, width: 72, height: 102 },
      }),
    ];
    const nodes = [
      node({
        identifier: "Row.swift:1",
        // +0.3 drift on each axis — still within epsilon.
        frame: { x: 20.3, y: 100.2, width: 72, height: 102 },
      }),
      node({
        identifier: "Row.swift:1",
        frame: { x: 112.1, y: 100.4, width: 72, height: 102 },
      }),
    ];
    expect(computePinRanks(chain, nodes)).toEqual([0, 1]);
  });

  it("computes ranks independently for each chain entry", () => {
    const chain = [
      el({
        identifier: "LibraryView.swift:435",
        frame: { x: 20, y: 100, width: 150, height: 218 },
      }),
      el({
        identifier: "BookCover.swift:9",
        frame: { x: 30, y: 120, width: 72, height: 102 },
      }),
      el({
        identifier: "NotInSnapshot.swift:1",
        frame: { x: 0, y: 0, width: 10, height: 10 },
      }),
    ];
    const nodes = [
      node({
        identifier: "LibraryView.swift:435",
        frame: { x: 20, y: 100, width: 150, height: 218 },
      }),
      node({
        identifier: "LibraryView.swift:435",
        frame: { x: 200, y: 100, width: 150, height: 218 },
      }),
      node({
        identifier: "BookCover.swift:9",
        frame: { x: 30, y: 120, width: 72, height: 102 },
      }),
      node({
        identifier: "BookCover.swift:9",
        frame: { x: 30, y: 300, width: 72, height: 102 },
      }),
    ];
    expect(computePinRanks(chain, nodes)).toEqual([0, 0, null]);
  });
});
