import type { AXFrame, AXNode } from "../protocol.ts";

/** A measured gap between the selected element and a visible neighbor.
 *  Coordinates are in the same device-space as the input frames; the
 *  renderer scales them. `rect` is the thin strip between the two edges
 *  so the overlay can paint it as a Figma-style redline. */
export interface GapMeasurement {
  direction: "top" | "right" | "bottom" | "left";
  distance: number;
  rect: AXFrame;
  neighborId: string;
}

export interface GapSet {
  top: GapMeasurement | null;
  right: GapMeasurement | null;
  bottom: GapMeasurement | null;
  left: GapMeasurement | null;
}

const EMPTY_GAPS: GapSet = { top: null, right: null, bottom: null, left: null };

/** For the selected frame, find the nearest visible neighbor on each side
 *  and measure the gap between their facing edges. A neighbor qualifies
 *  only when its bounding box overlaps the selected frame on the
 *  orthogonal axis (otherwise the redline would hop across empty space).
 *  The selected node itself + any descendants of it are ignored. */
export function computeGaps(
  selected: AXNode,
  nodes: ReadonlyArray<AXNode>,
  descendantIds: ReadonlySet<string>,
  minSide = 4,
): GapSet {
  if (selected.frame.width < minSide || selected.frame.height < minSide) {
    return EMPTY_GAPS;
  }
  const sel = selected.frame;
  const selMaxX = sel.x + sel.width;
  const selMaxY = sel.y + sel.height;

  let top: GapMeasurement | null = null;
  let right: GapMeasurement | null = null;
  let bottom: GapMeasurement | null = null;
  let left: GapMeasurement | null = null;

  for (const node of nodes) {
    if (node.id === selected.id || descendantIds.has(node.id)) continue;
    const f = node.frame;
    if (f.width < minSide || f.height < minSide) continue;
    const fMaxX = f.x + f.width;
    const fMaxY = f.y + f.height;

    const horizontallyOverlaps = fMaxX > sel.x && f.x < selMaxX;
    const verticallyOverlaps = fMaxY > sel.y && f.y < selMaxY;

    if (horizontallyOverlaps) {
      if (fMaxY <= sel.y) {
        const distance = sel.y - fMaxY;
        if (!top || distance < top.distance) {
          const overlapX = Math.max(sel.x, f.x);
          const overlapW = Math.min(selMaxX, fMaxX) - overlapX;
          top = {
            direction: "top",
            distance,
            rect: { x: overlapX, y: fMaxY, width: overlapW, height: distance },
            neighborId: node.id,
          };
        }
      } else if (f.y >= selMaxY) {
        const distance = f.y - selMaxY;
        if (!bottom || distance < bottom.distance) {
          const overlapX = Math.max(sel.x, f.x);
          const overlapW = Math.min(selMaxX, fMaxX) - overlapX;
          bottom = {
            direction: "bottom",
            distance,
            rect: { x: overlapX, y: selMaxY, width: overlapW, height: distance },
            neighborId: node.id,
          };
        }
      }
    }
    if (verticallyOverlaps) {
      if (fMaxX <= sel.x) {
        const distance = sel.x - fMaxX;
        if (!left || distance < left.distance) {
          const overlapY = Math.max(sel.y, f.y);
          const overlapH = Math.min(selMaxY, fMaxY) - overlapY;
          left = {
            direction: "left",
            distance,
            rect: { x: fMaxX, y: overlapY, width: distance, height: overlapH },
            neighborId: node.id,
          };
        }
      } else if (f.x >= selMaxX) {
        const distance = f.x - selMaxX;
        if (!right || distance < right.distance) {
          const overlapY = Math.max(sel.y, f.y);
          const overlapH = Math.min(selMaxY, fMaxY) - overlapY;
          right = {
            direction: "right",
            distance,
            rect: { x: selMaxX, y: overlapY, width: distance, height: overlapH },
            neighborId: node.id,
          };
        }
      }
    }
  }

  return { top, right, bottom, left };
}

/** Walk the `parentId` graph and collect every descendant of the given
 *  node so the gap solver can exclude children from neighbor candidates. */
export function collectDescendantIds(rootId: string, nodes: ReadonlyArray<AXNode>): Set<string> {
  const childrenByParent = new Map<string, AXNode[]>();
  for (const node of nodes) {
    if (!node.parentId) continue;
    const list = childrenByParent.get(node.parentId);
    if (list) list.push(node);
    else childrenByParent.set(node.parentId, [node]);
  }
  const ids = new Set<string>();
  const queue: string[] = [rootId];
  while (queue.length > 0) {
    const next = queue.shift();
    if (next === undefined) break;
    const children = childrenByParent.get(next) ?? [];
    for (const child of children) {
      if (ids.has(child.id)) continue;
      ids.add(child.id);
      queue.push(child.id);
    }
  }
  return ids;
}
