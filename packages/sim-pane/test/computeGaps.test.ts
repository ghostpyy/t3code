import { describe, it, expect } from "vitest";
import type { AXNode } from "../src/protocol";
import { collectDescendantIds, computeGaps } from "../src/lib/computeGaps";

function node(
  id: string,
  parentId: string | null,
  x: number,
  y: number,
  width: number,
  height: number,
): AXNode {
  return {
    id,
    parentId,
    role: "Element",
    label: null,
    value: null,
    identifier: null,
    frame: { x, y, width, height },
    enabled: true,
    selected: false,
  };
}

describe("computeGaps", () => {
  it("measures the shortest gap on each cardinal side", () => {
    const sel = node("target", null, 100, 200, 80, 40);
    const above = node("above", null, 80, 140, 150, 30);
    const below = node("below", null, 60, 260, 160, 30);
    const leftN = node("leftN", null, 20, 210, 60, 20);
    const rightN = node("rightN", null, 200, 210, 40, 20);

    const gaps = computeGaps(sel, [sel, above, below, leftN, rightN], new Set());

    expect(gaps.top?.distance).toBe(30);
    expect(gaps.top?.neighborId).toBe("above");
    expect(gaps.bottom?.distance).toBe(20);
    expect(gaps.bottom?.neighborId).toBe("below");
    expect(gaps.left?.distance).toBe(20);
    expect(gaps.right?.distance).toBe(20);
  });

  it("ignores self and descendants", () => {
    const sel = node("target", null, 100, 100, 100, 100);
    const child = node("child", "target", 110, 110, 80, 80);
    const descendantIds = collectDescendantIds("target", [sel, child]);
    const gaps = computeGaps(sel, [sel, child], descendantIds);
    expect(gaps.top).toBeNull();
    expect(gaps.right).toBeNull();
    expect(gaps.bottom).toBeNull();
    expect(gaps.left).toBeNull();
  });

  it("skips neighbors that do not overlap the orthogonal axis", () => {
    const sel = node("target", null, 100, 200, 80, 40);
    const diagonal = node("diagonal", null, 220, 320, 40, 40);
    const gaps = computeGaps(sel, [sel, diagonal], new Set());
    expect(gaps.right).toBeNull();
    expect(gaps.bottom).toBeNull();
  });

  it("returns the overlap-aligned strip as the redline rect", () => {
    const sel = node("target", null, 100, 200, 80, 40);
    const right = node("right", null, 200, 210, 40, 20);
    const gaps = computeGaps(sel, [sel, right], new Set());
    expect(gaps.right?.rect).toEqual({ x: 180, y: 210, width: 20, height: 20 });
  });
});

describe("collectDescendantIds", () => {
  it("walks the parentId tree", () => {
    const a = node("a", null, 0, 0, 10, 10);
    const b = node("b", "a", 0, 0, 5, 5);
    const c = node("c", "b", 0, 0, 5, 5);
    const d = node("d", null, 20, 20, 5, 5);
    const ids = collectDescendantIds("a", [a, b, c, d]);
    expect(ids.has("b")).toBe(true);
    expect(ids.has("c")).toBe(true);
    expect(ids.has("d")).toBe(false);
  });
});
