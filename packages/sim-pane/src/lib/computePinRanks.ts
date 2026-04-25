import type { AXElement, AXNode } from "../protocol.ts";

/** Tolerance for matching a chain frame against a snapshot bucket entry.
 *  Hit and snapshot both read from the same inspectable registry, so frames
 *  are byte-identical when the snapshot was captured inside the same layout
 *  pass as the hit. This epsilon absorbs the sub-point drift that can occur
 *  when the snapshot lagged the hit by a few tens of ms. */
const FRAME_EPS = 0.5;

/** For each element in the pinned chain, determine which instance of its
 *  shared `.inspectable()` identifier the user actually selected. Rank is
 *  an index into the Y-sorted (X-tiebreak) bucket for that identifier in
 *  `nodes` — `refreshPinFrames` applies the same sort, so `bucket[rank]`
 *  returns the stably-identified instance across layout shifts (scroll,
 *  animation). Rank is scroll-invariant because every instance in a
 *  ForEach moves together: the 4th book from the top is still the 4th
 *  book after the list shifts by 200pt.
 *
 *  Rank is `null` when:
 *    - the element has no identifier (coordinate-only hit).
 *    - the identifier is absent from the snapshot.
 *    - the bucket has only one candidate (nothing to rank — the single
 *      match wins in `refreshPinFrames` without consulting rank).
 *    - no bucket frame matches the chain frame within `FRAME_EPS` (the
 *      snapshot lagged the click past the point of frame identity — the
 *      refresh will fall back to centroid-nearest with the wrong answer
 *      on large shifts, but that's the existing behavior and is rare in
 *      practice since the poll runs continuously while inspect is on). */
export function computePinRanks(
  chain: readonly AXElement[],
  nodes: readonly AXNode[] | undefined,
): (number | null)[] {
  if (chain.length === 0) return [];
  if (!nodes || nodes.length === 0) return chain.map(() => null);

  const byIdentifier = new Map<string, AXNode[]>();
  for (const node of nodes) {
    if (!node.identifier) continue;
    const bucket = byIdentifier.get(node.identifier);
    if (bucket) bucket.push(node);
    else byIdentifier.set(node.identifier, [node]);
  }
  for (const bucket of byIdentifier.values()) {
    bucket.sort(compareByYThenX);
  }

  return chain.map((element) => {
    const id = element.identifier;
    if (!id) return null;
    const bucket = byIdentifier.get(id);
    if (!bucket || bucket.length <= 1) return null;
    const rank = bucket.findIndex((node) => framesMatch(node.frame, element.frame));
    return rank === -1 ? null : rank;
  });
}

export function compareByYThenX(
  a: { frame: { x: number; y: number } },
  b: { frame: { x: number; y: number } },
): number {
  if (a.frame.y !== b.frame.y) return a.frame.y - b.frame.y;
  return a.frame.x - b.frame.x;
}

function framesMatch(
  a: { x: number; y: number; width: number; height: number },
  b: { x: number; y: number; width: number; height: number },
): boolean {
  return (
    Math.abs(a.x - b.x) <= FRAME_EPS &&
    Math.abs(a.y - b.y) <= FRAME_EPS &&
    Math.abs(a.width - b.width) <= FRAME_EPS &&
    Math.abs(a.height - b.height) <= FRAME_EPS
  );
}
