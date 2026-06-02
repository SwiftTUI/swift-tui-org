# Perf - Persistent Retained Index via Structural Adjacency

**Date:** 2026-06-02
**Status:** Proposed. Execution plan, not yet started. Open Question #1 (portal
reparenting) resolved 2026-06-02 by a 6-tracer / 4-verifier source trace — see
*Trace Findings*; L3.5 dropped as a result.
**Scope:** `swift-tui` retained frame-tail index construction
(`RetainedFrameIndex`), the structural-identity model it depends on, and the
`FrameTailRetainedState` lifecycle that rebuilds it each committed frame.
**Parent:**
[`2026-06-02-003-rendering-performance-remaining-opportunities-proposal.md`](2026-06-02-003-rendering-performance-remaining-opportunities-proposal.md)
— Opportunity 1 (Persistent Retained Indexes).
**Predecessor wave:**
[`2026-06-02-002-rendering-performance-next-wave-proposal.md`](2026-06-02-002-rendering-performance-next-wave-proposal.md).

---

## Executive Summary

`RetainedFrameIndex` is rebuilt from scratch on every committed frame. Even on a
narrow-invalidation frame where almost nothing changed, the rebuild does a full
recursive walk of the resolved, measured, placed, and draw trees to repopulate
flat `[Identity: Node]` maps. As more frame-tail products become reusable, that
unconditional O(tree) rebuild becomes the next place layout/commit cost hides.

The blocker to patching the index incrementally is not the rebuild loop itself —
it is that the runtime has no *sound structural containment relation*. The only
"parent"/"ancestor" relation available today is `Identity.parent`, a pure
string-path convention that diverges from real structural containment around
`.id`, duplicate identities, presentation portals, root identity paths, and
overlay-owned subtrees. You cannot safely *patch* (replace/prune) subtrees of a
memo table keyed by a relation that can lie about containment.

This proposal builds the approach out in four sequenced layers, ordered so that
**correctness lands before any performance claim**:

1. **L1 — Structural adjacency (correctness, no perf claim).** Record the real
   parent/child edges during the walk that already happens, and replace the
   `Identity.parent` string-walk in invalidation classification with a
   structural walk.
2. **L2 — Subtree signatures + debug equality oracle.** Add a fold-up subtree
   signature next to the existing `subtreeNodeCount`, and a debug mode that
   builds both a patched and a fully-rebuilt index and asserts byte-equivalence.
   Still rebuilding; now provably patchable.
3. **L3 — Patchable index (the perf win).** Diff against the previous index by
   signature; reuse unchanged fragments, re-index only changed roots, prune
   removed roots. Treat indexed-child-source (lazy-stack viewport) roots as
   opaque barriers in v1, and handle transient removal-overlay identities as
   ordinary insert/prune. (Portals need no barrier — see *Trace Findings*.)
4. **L4 — (Deferred) arena / structure-of-arrays.** Only if L3's fragment churn
   shows up in measurement. This is the "breaking internal representation"
   change the parent register parks for last.

L1+L2 are safe to land independently and carry no behavioral risk. L3 is the
first step that changes what work the commit path does and is gated on the L2
oracle staying green.

## Current State

Verified in the pinned `swift-tui` working tree (`0.0.7-18-ga020fa55`):

- The index is rebuilt every commit. `FrameTailRetainedState.storeCommittedFrame`
  does `state.previousFrameIndex = .init(frame: indexable)`
  (`Sources/SwiftTUIRuntime/Rendering/FrameTailRetainedState.swift:103`), and a
  sibling `drawIndex` walk rebuilds the draw map
  (`FrameTailRetainedState.swift:118,126`).
- `RetainedFrameIndex.init(frame:)` recursively flattens the resolved, measured,
  and placed trees into `[Identity: Node]` maps plus a placed-frame entry table
  keyed by contiguous `Range<Int>` slices per identity
  (`Sources/SwiftTUICore/Commit/RetainedFrameQueries.swift:36-130`).
- The only containment relation is path-based. `Identity.parent` drops the last
  path component and `isAncestor`/`isDescendant` are string-prefix checks
  (`Sources/SwiftTUICore/Geometry/GeometryTypes.swift:604-639`).
- `RetainedInvalidationSummary` already leans on that convention: it walks
  `identity.parent` chains string-wise to classify synthetic invalidated
  ancestors (`RetainedFrameQueries.swift:167-177`), and it already special-cases
  `indexedChildSource` roots because indexed children do not follow the naive
  parent-path assumption (`RetainedFrameQueries.swift:180-191`).
- The nodes already maintain fold-up derived aggregates incrementally through
  their `children` setters: `ResolvedNode` recomputes `subtreeNodeCount`,
  `preferenceValues`, `customLayoutFallbackSummary`, and `supportsRetainedReuse`
  (`Sources/SwiftTUICore/Resolve/ResolvedNode.swift:36-45,228-310`);
  `MeasuredNode` and `PlacedNode` maintain `subtreeNodeCount` the same way.
- `ResolvedNode` has a shape-preserving fast-path setter,
  `setChildrenPreservingDerivedState(_:)`, used by animation tick frames that
  replace interpolated children without changing subtree shape
  (`ResolvedNode.swift:57-59`).
- `computeSupportsRetainedReuse` already returns `false` whenever
  `indexedChildSource != nil` or `layoutDependentContent != nil`
  (`ResolvedNode.swift:287-310`).
- A signature idiom already exists: `RetainedPhaseExtractionSignature.make(from:)`
  is used by `storeCommittedFrame` (`FrameTailRetainedState.swift:96-101`), and
  custom layout carries `measurementReuseSignature` / `placementReuseSignature`.

## Problem in One Picture

The trees handed to `RetainedFrameIndex` already encode structural adjacency in
their `children` / `childMeasurements` arrays. The index throws those edges away
when it flattens to `[Identity: Node]`, keeping only the string-path convention
(`Identity.parent`) as a proxy for "where did this node sit." Two consequences:

1. **It cannot patch.** With no retained edge set and no cheap subtree-equality
   signal, the only safe option each frame is a full rebuild.
2. **The proxy can lie.** Path-prefix containment is not structural containment
   under `.id`, portals, overlays, and duplicate identities, so even the
   *classification* it feeds is only conservatively correct, not exact.

L1 fixes (2). L2 makes (1) provably safe to fix. L3 fixes (1).

## Trace Findings (2026-06-02): Open Question #1 Resolved

A 6-tracer / 4-adversarial-verifier sweep of the pinned working tree resolved
Open Question #1 with high confidence. **The place phase performs no
reparenting**, and **no node that reaches the retained index has a placed parent
that differs from its parent in the same indexed tree.** L3 therefore needs a
**single canonical adjacency relation**; per-phase adjacency and a portal
redirect map are out of scope. (Two verifiers initially reported "divergence":
on review they were comparing the indexed tree against the *original authored*
tree, i.e. observing transient insert/prune churn, not placed≠resolved
reparenting — see constraint 1 below.)

What the trace established:

- **No place-phase reparenting.** `LayoutEngine` builds `PlacementRequest`s by
  indexing `resolved.children` in order across every layout behavior, and
  `PlacedNode.identity` is copied verbatim from `resolved.identity`. `Place/` has
  zero portal/hoist/reparent logic
  (`SwiftTUICore/Place/LayoutEngine+PlacementRequests.swift:21-51`,
  `LayoutEngine+Placement.swift:16`, `PlacedNode.swift:242`).
- **Portals are hoisted at *resolve*, not reparented at *place*.** Presented
  content (`.sheet`/`.popover`/`.alert`/`.fullScreenCover`/`.overlay`/
  `.background`) is composed into an `OverlayStack` branch during resolve by
  `composeOverlayStackTree` (`SwiftTUIViews/Presentation/OverlayStack.swift:32-84`)
  / `composePresentationPortalTree`
  (`SwiftTUIViews/Presentation/PresentationCoordinator.swift:287-321`). Overlay
  entries resolve under a `PortalHost/overlays` identity that *descends from* the
  `OverlayStack` root, so the presented content's resolved parent and its placed
  parent are the same node.
- **Correction to this proposal's prior assumption: presentation portals DO
  reach the index.** `renderPipelineTree` strips the wrapper *only* when the
  graph root is the no-overlay `PresentationPortalRoot` single-child shape
  (`SwiftTUIRuntime/Rendering/DefaultRendererRuntimeSubsystems.swift:5-15`). When
  overlays are present the root kind is `OverlayStack`, the strip is skipped, and
  the whole stack (base + presented content) flows through place into the
  baseline index — congruently, because the hoist already happened at resolve.
  Do **not** assume portals are excluded from the index.
- **Resolved-level removal overlays also reach the index — but at their own
  authored parent.** When no placed snapshot exists, `injectResolvedRemovals`
  re-inserts each exiting subtree at its **own former `parentIdentity` /
  `childIndex`** before the fused tail
  (`SwiftTUIRuntime/Lifecycle/AnimationTransitionOverlay.swift:46-65`,
  `SwiftTUIRuntime/Rendering/DefaultRendererFrameHeadCoordinator.swift:120-154`).
  That is re-insertion at the node's authored position, **not** reparenting to a
  different parent, so placed-parent still equals resolved-parent within the
  indexed tree.
- **Only placed-level overlays are excluded by baseline capture.** Placed-level
  animation overlays (`applyPlacedAnimationOverlaySnapshot`) and matched-geometry
  / offset placed injection are applied to a local copy *after* `baselinePlaced`
  is captured (`SwiftTUIRuntime/Rendering/FrameTailRenderer+InlineStages.swift:23-58`),
  so they never reach the index.

Two real constraints replace the (non-existent) portal-reparent hazard:

1. **The index is not transient-filtered.** `RetainedFrameIndex.init(frame:)`
   walks and indexes every child unconditionally, including `isTransient` removal
   nodes (`RetainedFrameQueries.swift:86-130`). Resolved-level removal-overlay
   frames therefore legitimately *insert and prune* transient identities
   frame-to-frame, at their authored parent. L3's signature diff must treat these
   as ordinary insert/prune, not anomalies. The `OverlayStack` root's
   `invalidationScope: .fullSurfaceDiff` / `role: .stackingContext` is a natural
   fragment-reuse boundary.
2. **The genuine placed-vs-resolved cardinality divergence is
   `indexedChildSource` (lazy-stack viewport)**, where placed children can be a
   viewport-clipped *subset* of resolved children — already tracked by
   `affectedIndexedChildSourceRoots` (`RetainedFrameQueries.swift:180-191`). That
   barrier stays; it, not portals, is the real divergence.

## Layer 1 - Structural Adjacency (correctness)

**Goal:** store the real edges so containment queries follow structure, not
string paths. No performance claim.

**Representation.** Extend `RetainedFrameIndex` with sidecar maps populated in
the existing recursive walk (zero extra traversal — every parent→child edge is
already visited at `RetainedFrameQueries.swift:86-130`):

```swift
package struct RetainedFrameIndex: Sendable {
  // existing flat maps unchanged …
  // new — structural, derived from real `children` edges:
  package let structuralParent:   [Identity: Identity]
  package let structuralChildren: [Identity: [Identity]]   // preserves sibling order
}
```

**Use it.** Replace the `identity.parent` string-walk in
`RetainedInvalidationSummary` (`RetainedFrameQueries.swift:167-177`) with a walk
over `structuralParent`. This is the parent register's requirement #2 ("track
subtree identity sets from structural adjacency, not only from identity path
conventions"). The synthetic-ancestor classification stops being a path-prefix
guess and becomes exact across `.id`, portals, and overlays.

**Duplicate-identity decision (must be made here).** A `[Identity: Node]` map is
already last-writer-wins on duplicate identities — a latent collision in the
current index. `structuralParent` keyed by `Identity` inherits it. L1 must pick
one stance and document it:

- **(a) Forbid + diagnose:** assert uniqueness while indexing, emit a duplicate
  diagnostic, and dedupe upstream. Keeps `Identity` as the index key.
- **(b) Slot key:** key adjacency by a per-frame structural slot id and demote
  `Identity` to a non-unique attribute.

Recommendation for L1: **(a)**, because the index is *already* effectively
assuming uniqueness; making that assumption explicit and instrumented is lower
risk than introducing a parallel slot-id space before it is needed. Revisit (b)
only if real content legitimately commits duplicate identities. Capture the
chosen stance next to the new fields.

**Scope barriers carried forward unchanged:** `indexedChildSource` roots keep
their existing special-case (`RetainedFrameQueries.swift:180-191`). Note (per the
trace above) that "pre-overlay baseline" excludes only **placed-level** animation
overlays; presentation portals (hoisted at resolve) and **resolved-level** removal
overlays (re-inserted at their authored parent) *are* present in the baseline
tree `storeCommittedFrame` indexes (`FrameTailRetainedState.swift:89-103`). They
are congruent structure, so L1 adjacency handles them without a special case.

## Layer 2 - Subtree Signatures and the Equality Oracle

**Goal:** make "is this subtree identical to last frame's?" an O(1) gate, and
prove a patched index would equal a rebuilt one — without yet changing release
behavior.

**Signature as a fold-up aggregate.** Add `subtreeSignature` to the node types,
maintained exactly like `subtreeNodeCount` is today:

- `ResolvedNode`: fold into `recomputeSubtreeNodeCount`'s sibling path
  (`ResolvedNode.swift:232-234`); the existing `children`/`layoutBehavior`
  setters already gate recomputes, and `setChildrenPreservingDerivedState`
  (`ResolvedNode.swift:57-59`) must be audited — animation tick frames that
  change numeric content but not shape *do* change the signature, so the
  fast-path setter either recomputes the signature or explicitly documents that
  signatures are only consulted on shape-stable frames.
- `MeasuredNode` / `PlacedNode`: fold alongside their `subtreeNodeCount`
  recomputes.

The signature must cover whatever the index's correctness depends on
(identity + child identities + the per-phase payload fields the retained reader
actually consumes). Reuse the existing signature family rather than inventing a
new hashing convention — extend the `RetainedPhaseExtractionSignature` /
custom-layout-signature approach already in use.

**Debug equality oracle.** This is the parent register's required debug
comparison. Gate it on a debug build (mirroring the release-trusts /
debug-verifies split already used for raster damage in the predecessor wave):

```swift
#if DEBUG
let patched = RetainedFrameIndex(patching: previous, with: indexable)
let rebuilt = RetainedFrameIndex(frame: indexable)
assert(patched.isByteEquivalent(to: rebuilt), "persistent index diverged from rebuild")
#endif
```

The nodes are all `Equatable`, so the oracle has a correctness reference for
free. L2 can ship the oracle while still using `rebuilt` in release, so it adds
verification with no behavior change.

## Layer 3 - Patchable Index (the performance win)

**Goal:** stop rebuilding. Diff the new frame against the retained index by
signature; reuse unchanged fragments, re-index only changed roots, prune removed
roots. Parent register requirement #4.

**Storage shift: ranges → fragments.** The current placed-frame table keys
contiguous `Range<Int>` slices per identity
(`RetainedFrameQueries.swift:29-30,77-84,112-129`). Ranges are read-friendly but
patch-hostile: inserting one entry shifts every later range. L3 moves to
**per-root fragment storage** (a dict of small arrays / sub-indexes), optionally
materializing the contiguous flat form lazily only when a downstream reader needs
it. Each retained fragment records the identity set it covers and its
`subtreeSignature`.

**API shift: construct-fresh → derive-next.** `FrameTailRetainedState` changes
from `previousFrameIndex = .init(frame: indexable)`
(`FrameTailRetainedState.swift:103`) to deriving the next index from the previous
one plus the new frame:

```swift
state.previousFrameIndex =
  RetainedFrameIndex(patching: state.previousFrameIndex, with: indexable)
```

The patch, per root identity:

- signature matches previous → reuse that fragment untouched (no re-walk),
- changed / newly present → re-index just that subtree, replace its fragment,
- absent this frame → prune its fragment and covered identity set (no stale
  leaks).

Still behind the same `Mutex`, still `Sendable`, still keyed off the baseline
placed tree. The L2 oracle wraps the patch call in debug.

**Hazards, and how L3 contains each:**

- **Indexed child sources (lazy stacks) — the real divergence.** This, not
  portals, is where placed children can be a viewport-clipped *subset* of
  resolved children. `supportsRetainedReuse` already returns `false` when
  `indexedChildSource != nil` (`ResolvedNode.swift:293`), and the existing
  `affectedIndexedChildSourceRoots` logic already tracks it
  (`RetainedFrameQueries.swift:180-191`). Treat such a root as an **opaque
  barrier leaf** in v1: index it, never claim its interior is reusable. This
  sidesteps `workerResolvedChildren` adjacency (`ResolvedNode.swift:276-280`)
  entirely for the first cut.
- **Transient removal overlays — insert/prune churn, not reparenting.** The
  index is not transient-filtered (`RetainedFrameQueries.swift:86-130`), so
  resolved-level removal-overlay frames add and prune `isTransient` identities
  frame-to-frame at their authored parent. The signature diff must handle these
  as ordinary insert/prune. The `OverlayStack` root carries
  `invalidationScope: .fullSurfaceDiff` / `role: .stackingContext`, a natural
  fragment-reuse boundary the diff can lean on.
- **Portal roots — no barrier needed.** Resolved by the trace above: portals are
  hoisted into an `OverlayStack` branch at *resolve*, so by place time their
  resolved-parent equals their placed-parent. They reach the index but as
  congruent structure. **No per-phase adjacency, no redirect map, and no L3
  portal barrier are required.** (L3.5 is dropped — see the execution table.)
- **Root identity paths / `.id`.** Handled structurally once L1 lands; the patch
  follows `structuralParent`/`structuralChildren`, not `Identity.parent`.

## Layer 4 - Arena / Structure-of-Arrays (deferred)

Only if L3's per-fragment allocation churn shows up in measurement. Flatten the
committed frame into one `[Node]` with integer slots, each storing `parent: Int?`
and `childRange: Range<Int>` (or first-child/next-sibling links), with
`Identity → slot` on the side. Structural diff and prune become index
arithmetic, and it is the most cache-friendly patchable form — but it is the
"breaking internal representation change" the parent register places last
(its step 5). Not in scope to implement here; recorded so L3's fragment design
does not foreclose it.

## Execution Order and Touchpoints

| Step | Lands | Primary files |
| --- | --- | --- |
| L1 | Structural adjacency maps; structural invalidation walk; duplicate-identity stance | `Commit/RetainedFrameQueries.swift` |
| L2 | `subtreeSignature` fold-up; debug equality oracle | `Resolve/ResolvedNode.swift`, `Measure/MeasuredNode.swift`, `Place/PlacedNode.swift`, `Commit/RetainedFrameQueries.swift`, `Rendering/FrameTailRetainedState.swift` |
| L3 | Fragment storage; `init(patching:with:)`; transient insert/prune handling; indexed-source barrier | `Commit/RetainedFrameQueries.swift`, `Rendering/FrameTailRetainedState.swift` |
| L4 | (Deferred) arena representation | TBD |

(L3.5 — per-phase / portal-redirect adjacency — is **dropped**. The 2026-06-02
trace proved portals do not reparent into a divergent placed position, so a
single canonical adjacency relation suffices. See *Trace Findings* above.)

L1 and L2 are independently shippable and carry no behavioral change in release.
L3 is the first step that alters commit-path work and must keep the L2 oracle
green in debug and the full retained-reuse test matrix green in release.

## Validation Required

Correctness (must hold from L1 onward):

- Insertion, deletion, reorder, focus move, active animation overlay, portal, and
  scroll cases all produce a patched index byte-equivalent to a full rebuild
  (L2 oracle, asserted in debug across the existing fixture corpus).
- Tests where path identity and structural containment intentionally diverge
  (`.id` boundaries, duplicate-identity diagnostics under the chosen stance,
  portal reparents, root identity paths) — assert structural adjacency, not path
  adjacency, drives classification.
- Indexed-child-source and portal roots are treated as barriers in L3 (assert no
  interior reuse is claimed across those seams).

Performance (gates the L3 perf claim — do not claim a win without it):

- `synthetic-narrow-invalidation` rows=6/20/40 sweeps, 20 iterations each (the
  parent register's preferred fidelity for final claims, not the 3-iteration
  smoke runs), showing repeated frames stop rebuilding full indexes and that
  index-construction cost drops without inflating `measure_ms` / `place_ms` /
  `semantics_ms` elsewhere.
- A visible-animation scenario to catch regressions in high-frequency repaint
  paths and to confirm the `setChildrenPreservingDerivedState` signature audit
  did not regress tick-frame cost.

Gate hygiene (per parent register Opportunity 5):

- Run focused runtime/core/raster/layout/pipeline/TermUIPerf suites; the full
  `swift test` `swiftpm-testing-helper` signal-11 crash is a known separate
  triage item and must not be read as a runtime assertion failure.

## Risks and Non-Goals

- **Do not** re-introduce a portal barrier or per-phase adjacency. The
  2026-06-02 trace established a single canonical adjacency relation is correct;
  the residual risk moved to transient insert/prune churn and the lazy-stack
  `indexedChildSource` subset, both handled explicitly above.
- **Do not** introduce a slot-id key space (duplicate-identity stance (b)) unless
  real content commits duplicate identities; prefer the explicit
  forbid-and-diagnose stance first.
- **Do not** claim a performance win from L1/L2 — they are correctness and
  verification only.
- **Do not** start L4 (arena) until L3 fragment churn is measured to matter; it
  is recorded only so L3 does not foreclose it.
- **Do not** alter the baseline-vs-overlay indexing contract: the index continues
  to key the pre-overlay baseline placed tree, with overlays re-injected from
  animation state each frame.

## Open Questions

1. ~~**Portal reparenting:**~~ **RESOLVED (2026-06-02 trace).** The place phase
   does not reparent; portals are hoisted at resolve and reach the index as
   congruent structure. A single canonical adjacency relation suffices. See
   *Trace Findings* above. **Residual sub-question:** matched-geometry placement
   (`ResolvedNode.matchedGeometry`) was strongly indicated to be placed-only /
   post-baseline like other animation overlays, but was not exhaustively traced
   to where it influences placement. Confirm it never produces a baseline-tree
   placed edge that disagrees with the resolved edge before closing this fully.
2. **Signature scope:** which payload fields must the subtree signature cover so
   that "signature equal" is sufficient for *all* retained readers
   (measurement, placement, placed-frame fragments, draw), not just one?
3. **`setChildrenPreservingDerivedState`:** keep it signature-aware, or formally
   restrict signature consultation to shape-stable frames and document that tick
   frames never trigger a fragment-reuse decision?
4. **Duplicate-identity reality:** is there any current content (diagnostics,
   foreign surfaces) that legitimately commits duplicate identities today? If so,
   stance (a) needs a defined diagnostic-vs-error policy before L1.
