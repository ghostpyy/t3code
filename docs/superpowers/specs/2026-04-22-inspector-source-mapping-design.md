# Inspector ⇆ Source Mapping — Design

**Status:** approved for implementation
**Owners:** t3code inspector + satira build tooling
**Target:** ship an iOS Simulator inspector that beats Xcode's View Debugger on (1) pixel → exact Swift `file:line`, (2) all-visible-element outline, (3) Figma-style gap redlines, (4) chat attach of source context.

## Goals

1. **Deterministic source mapping.** Every SwiftUI view a user can tap resolves to an exact `Module/File.swift:LINE` — no fuzzy "matched visible text" guesses.
2. **Zero manual stamping of satira.** Stamping is automatic at build time; satira source tree gains one `preBuildScripts` entry plus one 10-line shim. All heavy lifting ships in t3code.
3. **Inspector UI parity with Figma dev mode.** Outline all visible elements simultaneously; render gap redlines (padding + sibling spacing) with crisp labels; clean information hierarchy (no "Anonymous element / AXUIElement" placeholder clutter).
4. **Chat attach is load-bearing.** Tapping → selected element's exact source file + line + ancestor chain + N disambiguation candidates render as a markdown block in the chat composer, scoped by `SIM_SOURCE_MARKER_*` delimiters.

## Non-goals

- Live edit / hot-reload (Reveal/InjectionIII territory — out of scope).
- Time-travel scrubbing.
- Constraint overlays beyond outline + gap.

## Architecture

```
┌─────────────────────────────────────── satira repo (minimal footprint) ─┐
│ project.yml  preBuildScripts: [scripts/stamp-ax.sh]                      │
│ scripts/stamp-ax.sh  → shells to t3code/tools/ax-stamp (if present)      │
│ Sources/Satira/Theme/Inspectable.swift  (unchanged; stamp grammar lock) │
└──────────────────────────────────────────────────────────────────────────┘
                               ↓ (stamps committed as .inspectable() call
                                on every top-level view-body expression)
┌─────────────────────────────── t3code repo ─────────────────────────────┐
│ tools/ax-stamp/                       SwiftPM CLI (swift-syntax 600.x)  │
│   Sources/AXStamp/                    SyntaxRewriter + check mode       │
│   Package.swift                                                          │
│                                                                          │
│ apps/sim-bridge/Sources/SimBridge/                                       │
│   Simulator/SourceIndex.swift         persistent in-memory + FSEvents   │
│   Simulator/SourceResolver.swift      multi-signal ranker, replaces AXSI │
│   Simulator/AXFullSnapshot.swift      flat-rect tree snapshot producer  │
│   Protocol.swift                      + axSnapshot, axSnapshotResponse  │
│   Coordinator.swift                   route new messages                 │
│                                                                          │
│ packages/sim-pane/src/                                                   │
│   protocol.ts                         + AXSnapshot, AXNode                │
│   components/InspectPanel.tsx         redesigned, distinct file          │
│   components/SpacingOverlay.tsx       NEW — RBush + SVG redlines         │
│   components/OutlineLayer.tsx         NEW — all-visible-element stroke  │
│   components/CandidateList.tsx        NEW — ranked source candidates    │
│   lib/computeGaps.ts                  NEW — sweep + rbush adjacency     │
│   lib/buildSourceMention.ts           NEW — SIM_SOURCE_MARKER_* payload │
│   lib/mentions.ts                     + SIM_SOURCE_MARKER_START/END    │
│   useSimBridge.ts                     + snapshot state + fetchSnapshot │
│   SimPane.tsx                         wire new components; kill cruft  │
└──────────────────────────────────────────────────────────────────────────┘
```

## Component Design

### 1. ax-stamp CLI — `t3code/tools/ax-stamp/`

**Stack:** Swift 6.1, swift-syntax 600.0.1, ArgumentParser, `Parser.parse` + `SyntaxRewriter`.

**Behavior:** given `--project <path>` walks `*.swift` under `Sources/`, for each `VariableDeclSyntax` where the binding is `body` and the type is `some View`, rewrite every terminal expression (§ SwiftSyntax research §2 — direct expr, `ReturnStmtSyntax.expression`, `IfExprSyntax` per-branch, `SwitchExprSyntax` per-case, `@ViewBuilder` multi-statement bodies stamp each top-level expr) by appending `.inspectable()`. Idempotent: if the outermost call is already `inspectable` / `accessibilityIdentifier` / `id`, skip. Trivia-preserving (leading/trailing trivia transplant to outer wrapper).

**Stamp grammar (locked):** the modifier call is bare `.inspectable()` — satira's existing helper `extension View.inspectable(_ name: String? = nil, file: String = #fileID, line: Int = #line)` captures `#fileID:#line` at call site, producing identifiers `Satira/Views/Foo.swift:42` — matching the existing `parseInspectable` TS/Swift grammar already wired through the stack. **No new grammar to teach to the parsers.**

**Modes:**

- Default: rewrite in place; skip files whose output == input (no mtime churn).
- `--check`: exit 1 if any file would change (CI gate).
- `--verbose`: print per-file counts.

**Performance target:** full pass over satira's ~13 View files + ~3k LOC in < 150 ms warm.

**Release binary gating:** stamps themselves are compile-time-constant strings; no `#if DEBUG` needed on the CLI side. `#fileID` returns `Module/File.swift` (never absolute path — verified via AX research §5). If the user wants to strip stamps from App Store builds we add a `--release` mode later; out of scope for v1.

### 2. Satira integration — **9 lines total**

`satira/scripts/stamp-ax.sh`:

```bash
#!/usr/bin/env bash
set -e
BIN="${T3CODE_ROOT:-$HOME/coding/t3code}/tools/ax-stamp/.build/release/ax-stamp"
if [[ -x "$BIN" ]]; then
  exec "$BIN" --project "${SRCROOT:-$PWD}/Sources/Satira"
else
  echo "note: ax-stamp unavailable; skipping" >&2
fi
```

`satira/project.yml` — one entry on the `Satira` target:

```yaml
preBuildScripts:
  - path: scripts/stamp-ax.sh
    name: Stamp accessibility identifiers
    runOnlyWhenInstalling: false
    outputFiles: []
    basedOnDependencyAnalysis: false
```

With `ENABLE_USER_SCRIPT_SANDBOXING: NO` scoped to this phase via `settings` override if Xcode flags violations — in practice the stamper writes only under `$SRCROOT/Sources/**` which is implicitly allowed on stock new projects; sandboxing refuses only when writes land outside declared outputs. v1 ships without sandbox disable; if CI flags it we add per-phase override.

Satira adds no new swift code, no dependency to `Package.swift`, no modification to `Inspectable.swift`.

### 3. SourceIndex + SourceResolver — `apps/sim-bridge/Sources/SimBridge/Simulator/`

**Replaces:** `AXSourceInference.swift` (delete — its 8-second TTL cache + weak text heuristic are obsolete once `.inspectable()` is universal).

**`SourceIndex`:**

- On bridge start, walk each `projectRoot` once; parse every `*.swift` into a sorted line array.
- Subscribe via `FSEventStream` (CoreServices) to each project root. On change, rebuild just the touched file. Debounce 150 ms.
- Keyed by canonical absolute path; exposes `line(at:file:) -> String?` and `search(token:) -> [(file, line, context)]`.

**`SourceResolver`:**

- `resolve(chain: [AXElement], appContext: SimAppInfo) -> ResolvedSource`
- Pipeline:
  1. **Direct hit**: scan `chain` leaf→root for an `identifier` parsed by `parseInspectableModule` (already exists). First parseable → `confidence = 0.98`, return immediately.
  2. **Ancestor hit**: nearest ancestor with parseable identifier → `confidence = 0.82`, also returns the leaf's own semantic text for display.
  3. **Semantic fallback**: kept for legacy (old satira views not yet rebuilt). Previous `AXSourceInference.match` logic but reranked on top of the persistent index. `confidence ≤ 0.55`.
- Returns `ResolvedSource { primary: Anchor, candidates: [Anchor], signals: [String] }` — top 3 candidates always surfaced to the UI (never silently dropped).

**Full snapshot producer — `AXFullSnapshot`:**

- New method on Coordinator: `captureSnapshot()` — walks the frontmost app's AX tree via the existing `AXInspector`, emits a flat list of `AXNode { id, role, frame, parentId, identifier? }` for all visible elements.
- Triggered by a new `axSnapshot` PaneToBridge message.

### 4. Protocol additions

Swift `Protocol.swift` + TS `protocol.ts`:

```
PaneToBridge:
  + axSnapshot        // "give me every visible element's frame"

BridgeToPane:
  + axSnapshotResponse(nodes: [AXNode], appContext: SimAppInfo | null)
```

`AXNode`:

```
{ id: string, role: string, label: string | null, identifier: string | null,
  frame: AXFrame, parentId: string | null, depth: number }
```

Existing `axHitResponse.chain` already carries `sourceHints`; we extend `AXSourceHint` with:

```
+ source: "direct" | "ancestor" | "semantic"
```

so the UI can badge candidates.

### 5. Inspector UI — `packages/sim-pane/src/components/`

**Extraction:** the monolithic `InspectPanel` inside `SimPane.tsx` (L565-831) is lifted to its own file. Companion sub-components are extracted as peers. This clears the 1119-LOC file by ~40%.

#### `InspectPanel.tsx`

Clean two-pane layout:

- **Header row**: role chip + frame badge. No "Anonymous element" — when `role === "AXUIElement"`, the title falls through to the nearest ancestor's `.inspectable()` alias, or to the semantic text of the first child with one. If still empty, render role in muted italic (no placeholder text).
- **Source row**: file name + line + "Open" button. Confidence dot (green ≥0.9, amber 0.7-0.9, red <0.7). Click → dispatches `openSource(abs, line)`.
- **Candidate list**: `CandidateList` component, collapsed by default when there's only a direct hit; expands when confidence <1.0 or there are >1 matches.
- **Breadcrumb**: ancestor chain, clickable to walk up the tree; `Shift+ArrowUp/Down` keyboard nav unchanged.
- **Chat attach**: one button `Attach to chat` + `⌘↵` shortcut. Renders via `SIM_SOURCE_MARKER_*` (see §6).

#### `OutlineLayer.tsx`

Always-on-when-inspect-on overlay: strokes every visible element from the `AXSnapshot`. Selected element: 2pt `tokens.color.accentLive`; hover: 1.5pt `accentSoft`; rest: 0.75pt `rgba(100,120,255,0.35)`. `React.memo` per-rect, keyed by stable AXNode id — 200 rects reconcile in < 2 ms on selection change.

#### `SpacingOverlay.tsx`

Figma-style redlines:

- Adjacency via `rbush` (O(N log N) for sibling pairs).
- Parent/child inset detected from `parentId` graph → 4-sided padding measures.
- Tick-capped dimension lines (no arrow markers — crisper), label placement per overlay research §4 (inline for ≥24 pt gaps, outside for 8-24, hover-only for <8).
- `pointerEvents="stroke"` on invisible 8pt hit lines → hover reveals tooltip; clicks pass through to the live simulator framebuffer.
- Toggle lives in the inspect toolbar (shortcut `⌘⇧G`).

#### `CandidateList.tsx`

Virtualized list of `ResolvedSource.candidates`. Each row: filename, line, signal badge (`direct` / `ancestor` / `semantic`), confidence bar, open button. Selecting a row retargets the primary anchor (and updates the chat attach payload if pinned).

### 6. Chat attach — `packages/sim-pane/src/lib/`

New `buildSourceMention.ts`:

- Emits a markdown block delimited by new marker pair:
  ```
  <!-- @here:sim-source:start -->
  ...
  <!-- @here:sim-source:end -->
  ```
  **Distinct from `SIM_INSPECT_MARKER_*`** (which is the existing element-dump payload). The two can coexist; chat composer's `replaceLatestSimInspectBlock` gains a sibling `replaceLatestSimSourceBlock`.
- Body shape:
  ```
  ### Simulator source · <role> <frame>
  - ★ **Anchor**: `Module/File.swift:42` — `.inspectable()` direct hit (0.98)
  - **App**: `com.satira.app` · pid 42123
  - **Path**: Root ← VStack ← Button
  #### Other candidates
  - [Module/File.swift:58](Module/File.swift:58) — ancestor (0.82)
  - [Module/Other.swift:13](Module/Other.swift:13) — semantic (0.55)
  ```
- The existing `mentions.ts` `renderMentionMarkdown` is not touched; new helper emits the simpler source-only payload (the element-dump payload already ships as "inspect" block when the user wants full detail).

### 7. SimPane.tsx surgical edits

- Remove `InspectPanel` inline (moved to own file); slot in `<InspectPanel {...ctx} />`.
- Add `<OutlineLayer />` and `<SpacingOverlay toggled={showGaps} />` inside the device-chrome cutout, under the InspectOverlay existing at L441.
- Strip the "Anonymous element / AXUIElement" dead strings at L985, L996-1000 once `InspectPanel` owns fallback logic.
- Add toolbar toggle button for spacing redlines.

## Data flow

1. User enables Inspect mode. `SimPane` sends `axSnapshot` once, subsequent on-demand when AX tree dirty.
2. `axSnapshotResponse` seeds `OutlineLayer` + `SpacingOverlay`.
3. User taps a pixel. `axHit` (mode=`select`) → bridge enriches chain with `SourceResolver.resolve()` → `axHitResponse.chain[].sourceHints` now carries `source`-tagged entries.
4. `InspectPanel` renders the primary anchor + candidate list; offers chat attach.
5. Chat attach: `SpellUBuild…` → dispatches custom DOM event → `ChatComposer` inserts marker-delimited block.

## Error handling / edge cases

- **Stamper unavailable** (satira built without t3code checkout): stamps stay stale from last commit. `SourceResolver` still works via semantic fallback with degraded confidence. UI surfaces "last stamped: commit abc123" in a small tooltip.
- **Non-Inspectable view** (e.g., views in `AuthNudgeView` which builds extra structs): falls through to ancestor hit, then semantic. Never "no source found" — at worst a best-guess candidate with confidence 0.4.
- **AX tree delayed**: snapshot response can lag 100-300 ms on first paint. UI shows skeleton outline until seeded.
- **XIP projects / Pods**: `SourceIndex` skips paths under `.build`, `DerivedData`, `Pods`, `xcuserdata` (carried over from existing `shouldSkip`).

## Testing

- **ax-stamp**: golden-file tests under `tools/ax-stamp/Tests/` — one input/output pair per SwiftSyntax view shape (single expr, return, if/else, switch, @ViewBuilder multi-statement, extension member, generic View). Second-run byte-equality assertion (idempotence).
- **SourceResolver**: unit tests with fabricated AX chains + fixture swift files. Verify direct > ancestor > semantic precedence.
- **computeGaps**: unit tests with grid of rects, assert expected padding + sibling gaps, assert no spaghetti when overlaps <25%.
- **End-to-end**: manual — boot simulator via t3code, tap known element in satira, verify `Module/File.swift:LINE` matches `git grep -n 'Views/<File>\\.swift'`.

## Phased implementation

| Phase                    | Scope                                                                                                                                                    | Files touched | Verify                                                       |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- | ------------------------------------------------------------ |
| **P1** Scaffold          | Create `tools/ax-stamp/` SwiftPM package skeleton; add satira `scripts/stamp-ax.sh` + `project.yml` preBuildScripts entry (commit to satira separately). | ~8            | `swift build` in tools/ax-stamp                              |
| **P2** Stamper           | Implement the SyntaxRewriter; golden tests; `--check` mode.                                                                                              | ~6            | `swift test` green; run against satira → 8 stamps emitted    |
| **P3** Bridge-side       | New `SourceIndex`, `SourceResolver`, `AXFullSnapshot`; delete `AXSourceInference.swift`; wire into `Coordinator`. Protocol add `axSnapshot*`.            | ~7            | `swift build` green; smoke-test.mjs still passes             |
| **P4** TS protocol       | `protocol.ts` `AXNode`, `AXSnapshot*`; update `useSimBridge` state; `SIM_SOURCE_MARKER_*` in `mentions.ts`.                                              | ~4            | `tsc --noEmit` in packages/sim-pane + apps/web               |
| **P5** UI components     | Extract `InspectPanel`, new `OutlineLayer`, `SpacingOverlay`, `CandidateList`, `computeGaps`, `buildSourceMention`. Wire into `SimPane`.                 | ~9            | `tsc --noEmit` + `eslint`; visual QA in packaged app         |
| **P6** Chat attach       | `buildSourceMention.ts`; `ChatComposer.tsx` handler for new marker; `simPaneEvents.ts` pass-through.                                                     | ~3            | attach in live app; verify marker block replaces on next tap |
| **P7** End-to-end verify | Build desktop artifact; boot satira in simulator; tap known views; confirm source open, gap overlay, chat attach. Rebuild sim-bridge.                    | manual        | screenshots + grep proofs                                    |

Phases P3 and P4 can parallelize against each other; P5 depends on P4.

## Out of scope (this spec)

- Constraint visualizations beyond outline + gap.
- Live edit.
- Hot-reload.
- UI test recording.
- Accessibility audit (contrast / VoiceOver order overlay).

These are good future work; not part of v1.
