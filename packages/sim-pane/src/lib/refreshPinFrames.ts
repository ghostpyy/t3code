import type { AXElement, AXNode } from "../protocol.ts";
import { compareByYThenX } from "./computePinRanks.ts";

/** Refresh each pinned chain element's `frame` from the latest BFS snapshot
 *  by matching on `.inspectable()` identifier. The pin chain is captured at
 *  click time, but Satira's layout shifts under it — a Library scroll, a
 *  sheet opening, a focus animation — all move the backing view without
 *  producing a fresh `axHitResponse`. Without this step the outline layer
 *  stays glued to the click-time coordinates and drifts off the element.
 *
 *  Matching strategy:
 *  - Elements with no `identifier` (AX-only hits, coordinate stubs) keep
 *    their stored frame. There's no stable handle to re-resolve those.
 *  - Elements whose identifier is absent from the snapshot also keep their
 *    stored frame — the pinned view may be in a sheet that's currently
 *    dismissed or scrolled off. We don't clear the pin; the user drives
 *    clear via mode toggle or clearSelection.
 *  - When the identifier appears once, that's the new frame.
 *  - When the identifier appears multiple times (e.g., a ForEach of book
 *    covers sharing `LibraryView.swift:435`) and `pinRanks[i]` identifies
 *    which instance was pinned, use the Y-sorted `bucket[rank]`. Rank is
 *    scroll-invariant: every instance in a ForEach translates by the same
 *    offset, so the 4th book from the top is still the 4th book after a
 *    200pt scroll. This is the only oracle that survives large shifts —
 *    centroid-distance breaks down when the scroll delta exceeds half the
 *    inter-instance spacing, because the adjacent book's new centroid
 *    becomes closer to the original click point than the pinned book's
 *    own new centroid.
 *  - Without a rank (click landed before any snapshot was polled, or the
 *    snapshot lagged past frame identity), fall back to centroid-nearest.
 *    For small shifts this still preserves the right book; for large
 *    shifts it's still better than nothing.
 */
export function refreshPinFrames(
  chain: readonly AXElement[],
  nodes: readonly AXNode[] | undefined,
  pinRanks?: readonly (number | null)[] | null,
): AXElement[] {
  if (chain.length === 0) return [];
  if (!nodes || nodes.length === 0) return chain.slice();

  const byIdentifier = new Map<string, AXNode[]>();
  for (const node of nodes) {
    if (!node.identifier) continue;
    const bucket = byIdentifier.get(node.identifier);
    if (bucket) bucket.push(node);
    else byIdentifier.set(node.identifier, [node]);
  }
  // Stable Y-then-X sort so a stored rank indexes into the same slot across
  // successive snapshots. `computePinRanks` sorts identically.
  for (const bucket of byIdentifier.values()) {
    bucket.sort(compareByYThenX);
  }

  return chain.map((element, index) => {
    const id = element.identifier;
    if (!id) return element;
    const candidates = byIdentifier.get(id);
    if (!candidates || candidates.length === 0) return element;

    let fresh: AXNode;
    if (candidates.length === 1) {
      fresh = candidates[0]!;
    } else {
      const rank = pinRanks?.[index];
      if (typeof rank === "number" && rank >= 0 && rank < candidates.length) {
        fresh = candidates[rank]!;
      } else {
        fresh = candidates.reduce((best, cur) =>
          centroidDistSq(cur.frame, element.frame) < centroidDistSq(best.frame, element.frame)
            ? cur
            : best,
        );
      }
    }

    return {
      ...element,
      frame: {
        x: fresh.frame.x,
        y: fresh.frame.y,
        width: fresh.frame.width,
        height: fresh.frame.height,
        ...(fresh.frame.cornerRadius != null
          ? { cornerRadius: fresh.frame.cornerRadius }
          : element.frame.cornerRadius != null
            ? { cornerRadius: element.frame.cornerRadius }
            : {}),
      },
    };
  });
}

function centroidDistSq(
  a: { x: number; y: number; width: number; height: number },
  b: { x: number; y: number; width: number; height: number },
): number {
  const ax = a.x + a.width / 2;
  const ay = a.y + a.height / 2;
  const bx = b.x + b.width / 2;
  const by = b.y + b.height / 2;
  const dx = ax - bx;
  const dy = ay - by;
  return dx * dx + dy * dy;
}
