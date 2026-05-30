# SwiftTUI H3 — Retained-Subtree Bookkeeping (design + plan)

**Date:** 2026-05-30
**Status:** SHIPPED (child branch, unpushed). Phases 0/2/3/4 done, full gate green. See
[`docs/reports/2026-05-30-h3-retained-subtree-findings.md`](../reports/2026-05-30-h3-retained-subtree-findings.md)
for results. Phase 5 (publish) pending user OK to push the child branch + bump the org pin.
**Motivating report:** [`docs/reports/2026-05-28-gallery-performance-report.md`](../reports/2026-05-28-gallery-performance-report.md) (§ H2/H3 — per-interaction `resolve`; § H3 — fixed per-frame pipeline cost)
**Predecessor:** [`docs/reports/2026-05-30-h2-resolve-reuse-findings.md`](../reports/2026-05-30-h2-resolve-reuse-findings.md) (H2 made *recompute* O(changed); flagged snapshot-assembly as an O(tree) follow-on)
**Measurement pin:** `swift-tui` @ `93e9ea3d` (org pin `93e9ea3d`), release, `Tools/TermUIPerf`.

---

## TL;DR

- **Measured residual (clean, CV 1.7–2.3%).** With H2 reuse firing (recompute flat at
  **17 nodes** across all tree sizes), the per-interaction frame cost still scales O(tree):
  across `synthetic-narrow-invalidation` at `TREE_ROWS ∈ {6,20,40}` (67 / 193 / 373 nodes),
  steady-state `resolve_ms` = 0.54 / 1.04 / 1.73, `place_ms` = 0.17 / 0.42 / 0.80,
  `commit_ms` = 0.32 / 1.30 / 2.53. A **1-cell change in a 373-node tree pays ~7 ms
  pipeline, ~5.4 ms of which is pure tree-size bookkeeping** — none of it real work
  (recompute is flat at 17 nodes).
- **Reframing vs. the H2 report.** The H2 findings attributed the residual to "snapshot
  assembly in `resolve`." The measurement shows it is broader and `commit_ms` is the
  **largest** scaling component (Δ over the rows=6 floor at rows=40: resolve +1.19 ms,
  place +0.63 ms, commit **+2.21 ms**).
- **Root mechanism (source-confirmed).** All three scaling costs are driven by
  `ViewGraph.frameOrder` being repopulated with **every reused node** each frame:
  (1) `recordReusedSubtree`'s recursion (resolve side), (2) `finalizeFrame`'s
  `setCommittedPresence` + `liveIdentities.formUnion` sweep (commit side), and
  (3) `pruneDetachedIdentitySubtree`'s full scan (GC). For an **unchanged** retained
  subtree, all of this re-establishes already-correct prior-frame state.
- **The lever.** A *retained-subtree* fast path: when a reused subtree root is provably
  unchanged and disjoint from this frame's invalidation, record the **root once** and
  carry its descendants' presence/liveness forward instead of re-walking and
  re-recording every descendant — making the reuse-frame bookkeeping O(changed),
  matching what H2 already did for recompute.
- **Expected win.** `resolve_ms` **and** `commit_ms` decouple from tree size, flattening
  toward the rows=6 floor; the win **grows with tree depth** (real views are deeper
  than 40 rows) and lands on the **common** interaction path. Upper bound from the
  data: ~5.4 ms → ~1 ms per interaction frame at rows=40.
- **Risk: medium.** It narrows an *existing* guarded fast path (not the H1 restart-trap
  re-introduction), but it touches the presence / liveness / GC model, where a mistake
  produces phantom teardown (disappear/task-cancel) of a still-present subtree. Guards
  already exist; the plan is phased and measurement-gated.

---

## 1. Evidence

`synthetic-narrow-invalidation`, release, `--modes async --iterations 20`, swept over
`TERMUI_PERF_INVALIDATION_TREE_ROWS`. Steady-state = invalidation frames ≥ 4 (excludes
the cold first-paint + warm-up). All CVs ≤ 4.2%; machine 1-min load ≤ 2.4 throughout.

| Tree rows | total nodes | `resolved_computed` | `resolve_ms` | `place_ms` | `commit_ms` | `pipeline_ms` | total CPU-s/20 |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 6  | 67  | **17** | 0.54 | 0.17 | 0.32 | 1.6 | 0.0808 |
| 20 | 193 | **17** | 1.04 | 0.42 | 1.30 | 4.1 | 0.1635 |
| 40 | 373 | **17** | 1.73 | 0.80 | 2.53 | 7.0 | 0.2599 |

- **Recompute is flat at 17** — H2's win is intact and firing at HEAD (this settles a
  reader contradiction surfaced during investigation: reuse *is* firing; `resolved_reused`
  scales 54 → 180 → 360).
- **The residual scales ~linearly with tree size and is pure bookkeeping** — recompute is
  flat, so the rising resolve/place/commit is re-establishing already-correct state.
- **Total CPU scales ~3.2× across a 5.6× tree** — confirming the O(tree) (not O(changed))
  shape of the reuse-frame cost.

The redundant double `recordReusedSubtree` call (`ViewFoundation.swift:270`) was removed
first as cleanup; a controlled before/after sweep confirmed it **perf-neutral** (within
±stddev at all three sizes) because the second call hit the `wasVisitedThisFrame` guard
(`ViewGraph.swift:702`) and returned at the root — an O(1) no-op, not the O(tree) walk the
investigation initially assumed. The real residual is the recursion *inside*
`reusableSnapshot`'s record call, plus `finalizeFrame` and the GC scan.

---

## 2. Mechanism (source-confirmed)

`ViewGraph.frameOrder: [Identity]` accumulates every node touched this frame. On a reuse
frame it is O(total live nodes), and three per-frame consumers ride on it:

### 2a. `recordReusedSubtree` recursion — resolve side
`ViewGraph.swift:695-770`. Entered once per disjoint reused subtree (from
`reusableSnapshot` at `:815` / `:836`). Unconditionally recurses over every node
(`:711` `subtree.children.map { recordReusedSubtree(child, …) }`). Per node:
- `prepareForFrame` (`ViewNode.swift:103`) — resets per-frame state incl.
  `previousChildrenIdentities = children.map(\.identity)` (O(children)).
- `beginReuse` (`ViewNode.swift:139`) — marks `wasVisitedThisFrame = true`,
  `visitedFrameID = currentFrameID`.
- `frameOrder.append` (`:705`).
- `applyStructuralChildDiff` (`:718` → `:1088`) — diffs child descriptors.
- `node.apply(resolved:children:)` (`ViewNode.swift:318-338`) — re-parents children
  (O(children)) and walks ancestors via `invalidateAncestorCachedSnapshots()` (O(depth)).
- lifecycle task-diff + `setLifecycleState`.

For an **unchanged** node, every one of these reproduces last frame's result: `committed`
is already the snapshot, `isCommittedSnapshotFresh` is already true, children are already
parented.

### 2b. `finalizeFrame` sweep — commit side
`ViewGraph.swift:894-925` (called once per committed frame from `:854/:867/:877`). Iterates
the entire `frameOrder` (`:901`) calling `setCommittedPresence(true)` per node, then
`liveIdentities.formUnion(frameOrder)` (`:920`), then re-walks the resolved tree in
`frameLifecycleEventPlan` (`:912`). All O(tree).

### 2c. `pruneDetachedIdentitySubtree` — GC, the safety constraint
`ViewGraph.swift:670-693`. Scans `nodesByIdentity.values` (O(total nodes)) and removes any
node that is `wasPresentAtFrameStart && !visitedThisFrame(currentFrameID)`
(`:677-678`) — i.e. present last frame but not recorded this frame. **This is why
descendants cannot simply be skipped:** an unrecorded retained descendant looks detached
and gets torn down, firing phantom `.disappear` / `.task-cancel` events.

`visitedThisFrame(frameID)` (`ViewNode.swift:710`) returns `visitedFrameID == frameID`,
set only by `beginReuse` / `beginEvaluation`.

---

## 3. Opportunity and core invariant

For a subtree whose root passes `canReuse` (`wasPresentAtFrameStart`, `!isDirty`,
`isCommittedSnapshotFresh`, `committed.supportsRetainedReuse`) **and** is disjoint from
this frame's invalidation (`!identityIntersectsInvalidation && !structuralInvalidationIntersects`,
already computed at `ViewGraph.swift:803-813`) **and** has no structural change since last
frame, the following hold from the *prior* committed frame and remain valid:

> Every descendant's `committed` snapshot is correct, `isCommittedSnapshotFresh` is true,
> lifecycle state is `.alive`, and `hasCommittedPresence` is true.

**Invariant for H3:** *recording the retained root is sufficient to keep the whole subtree
present, alive, and live for this frame.* The descendant walk only re-derives state that is
already correct — so it can be skipped if (and only if) presence/liveness/GC are taught to
treat the retained root as covering its descendants.

---

## 4. Soundness constraints (must not break)

1. **GC exemption (highest risk).** `pruneDetachedIdentitySubtree` must not reap descendants
   of a retained root. Either mark the subtree present via a retained-range registry, or
   exempt descendants-of-a-retained-root from the `!visitedThisFrame` reap.
2. **Presence/liveness coverage.** `finalizeFrame`'s `setCommittedPresence(true)` and
   `liveIdentities.formUnion` must still cover retained descendants (they were already
   present; carry forward rather than re-add per node).
3. **No phantom lifecycle events.** An unchanged retained subtree must emit **zero**
   appear/disappear/task events. (Test asserts event count == 0 on a pure narrow-invalidation
   frame.)
4. **H1 `drawnIdentities` invariant.** The retained subtree must still surface its full
   `_storedChildren` to draw/semantics/focus/hit-test (it does — the returned `ResolvedNode`
   is whole) and must never be conflated with a clipped/off-screen identity.
   (See [[perf-h1-offscreen-elision-status]]: clipped identities are never recorded in
   `drawnIdentities`.)
5. **`suppressRetainedReuse` inheritance.** Focus-move and in-flight-animation frames already
   bypass the whole reuse fast path (`ResolveContext.effectiveSuppressesRetainedReuse`,
   `FrameResolveState.swift`); the retained path must inherit that — never elide bookkeeping
   on a suppress-reuse frame.
6. **Structural-change refusal.** Any subtree whose child-descriptor list could differ from
   last frame must keep the full `applyStructuralChildDiff` + recursion. Eligibility requires
   *no structural change* in addition to invalidation-disjointness.
7. **Preserve existing guards.** `structuralInvalidationIntersects` (`:1057`),
   `conflictsWithInvalidation` (`:822`), `canReuse` — all stay; H3 adds a narrower
   *also-skip-descendants* condition on top.

---

## 5. Approach options

**Option A — retained-root marker + carry-forward (recommended).** Add a fast path to
`recordReusedSubtree`: when the root is retained-eligible (per §3) and structurally
unchanged, `beginReuse` + `frameOrder.append` the root only, register the root in a
per-frame `retainedSubtreeRoots: Set<Identity>` (or identity-range), and **return without
recursing**. Teach `finalizeFrame` to treat descendants-under-a-retained-root as present
(carry forward `hasCommittedPresence`/`.alive` from last frame; union the retained roots'
prior subtree identities into `liveIdentities` in O(retained-roots), e.g. via a cached
per-root subtree-identity set or a "covered" predicate). Teach `pruneDetachedIdentitySubtree`
to skip any node whose nearest retained ancestor is in `retainedSubtreeRoots`.
*Effort: medium. Win: full (flattens resolve + commit). Risk: the GC/presence change.*

**Option B — per-node redundancy elision (incremental, partial).** Keep the recursion but
make per-node work cheap when unchanged: skip `node.apply` re-parenting +
`invalidateAncestorCachedSnapshots`, `applyStructuralChildDiff`, and the
`previousChildrenIdentities` rebuild when the node's children identities are byte-identical
to last frame. Leaves the O(tree) recursion + `frameOrder` + `finalizeFrame` sweep, so it
flattens the *per-node constant* but not the *O(tree) shape*. *Effort: low. Win: partial
(shaves the constant, not the slope). Risk: low.* Useful as a measured stepping stone and
a fallback if Option A's GC change proves too risky.

**Decision:** pursue **Option A**, but land **Option B's `node.apply` short-circuit first**
as a low-risk increment (measure it), then layer the carry-forward. Each step is gated on the
sweep showing the expected movement.

---

## 6. Phased implementation plan

All Sources changes in `swift-tui`; each phase is a separate commit, measured before the
next. The redundant-call dedup (`ViewFoundation.swift`) is already done as Phase 0.

- **Phase 0 — dedup (DONE).** Removed the redundant `recordReusedSubtree` at
  `ViewFoundation.swift:270`; confirmed perf-neutral. Cleanup only.
- **Phase 1 — instrument.** Add a diagnostic counter for `frameOrder.count` and a
  `retained_eligible_subtree_nodes` tally (nodes that *would* be skipped) to the frame
  diagnostics / TSV, so Phase 2/3's effect is directly visible and the residual hypothesis
  is double-checked from the instrument, not just inferred. Gate-safe (diagnostic column).
- **Phase 2 — Option B short-circuit.** In `node.apply` / `recordReusedSubtree`, detect an
  unchanged node (same child identities, committed-fresh, disjoint) and skip the redundant
  re-parent + `applyStructuralChildDiff` + ancestor-invalidation. Measure the sweep; expect
  the per-node constant to drop (modest flattening).
- **Phase 3 — Option A carry-forward.** Add `retainedSubtreeRoots` + the
  `finalizeFrame` / `pruneDetachedIdentitySubtree` exemptions; skip the descendant recursion
  for retained roots. Measure the sweep; expect `resolve_ms` **and** `commit_ms` to decouple
  from tree size.
- **Phase 4 — soundness hardening + regression tests** (see §8).
- **Phase 5 — findings report + publish** (child push → org pin bump → `bazel test //:org_fast`),
  per the [child-repo workflow](../../CLAUDE.md). Update [[perf-h2-resolve-reuse-status]]
  follow-on tracking.

---

## 7. Success criteria (measurement-gated)

Using the same `synthetic-narrow-invalidation` sweep (rows 6/20/40, 20 iters, async, CV < 0.10):

- **Primary:** `resolve_ms` **and** `commit_ms` decouple from tree size — the rows=40 values
  collapse toward the rows=6 floor (target: resolve_ms(40) within ~1.5× resolve_ms(6),
  similarly for commit_ms), while `resolved_computed` stays flat at ~17 and `resolved_reused`
  stays large.
- **Total CPU** slope across the sweep flattens materially (target: total-CPU(40)/total-CPU(6)
  drops from ~3.2× toward ~1.5×).
- **No regression (hard gate):** `draw_nodes`, `focus_regions`, `interactions`, and
  per-frame lifecycle-event counts unchanged vs. baseline — any change signals a dropped or
  mis-tracked retained subtree.

---

## 8. Risks, mitigations, and test strategy

| Risk | Likelihood | Mitigation / test |
|---|---|---|
| Phantom teardown — GC reaps a retained descendant (disappear/task-cancel) | medium | New test: a pure narrow-invalidation frame asserts **zero** lifecycle events for the static subtree across N frames; assert `liveIdentities` superset is stable. |
| Stale presence — a retained subtree that *should* have changed is skipped | low | Eligibility requires committed-fresh **+** disjoint-from-invalidation **+** no structural change; reuse `structuralInvalidationIntersects` / `conflictsWithInvalidation` unchanged. |
| Focus / caret-scroll breakage (the H2 coupling) | low | Keep `suppressRetainedReuse` inheritance; re-run `runtimeFocusMovementWritesBackIntoRenderedFocusIdentity`, `arrowKeysUseGeometryAwareTopLevelFocusTraversal`, `textEditorRuntimeScrollsToKeepCaretVisible`. |
| Drawn/semantics divergence | low | Existing `disjointSiblingReuseSurvivesDebugSignatureChange` guard + a snapshot-equality assertion that the retained `ResolvedNode` is byte-identical to the per-node-recursed result. |

**New tests (`Tests/SwiftTUICoreTests` resolve layer):**
1. `retainedSubtreeEmitsNoLifecycleEventsOnDisjointInvalidation` — the core GC-soundness guard.
2. `retainedSubtreeProducesIdenticalResolvedNodeAsFullRecursion` — equivalence oracle:
   resolve with the fast path vs. forced full recursion (a test seam) must yield identical
   `ResolvedNode` + `liveIdentities`.
3. Extend the sweep scenario assertion if a deterministic unit form is feasible.

---

## 9. Secondary investigation — off-screen floor A/B (not blocking H3)

The off-screen animator floor read **0.7475 CPU-s/20** here vs **0.4751** in the published
H1 report. That spans different SHAs (H2 + flake work landed since), sessions, and machine
load (≤2.4 vs ~0), so it is **not** a confirmed regression. But H2 added per-resolve
bookkeeping (`suppressRetainedReuse` threading, `isReuseEquivalent`) that runs even when
reuse is suppressed — and the off-screen animator *always* suppresses reuse (active
animation). A controlled same-machine A/B (`synthetic-offscreen-phase-animator` at H1's base
SHA `3aaa8282` vs HEAD) would settle whether H2 measurably regressed animation-frame resolve.
Fold into Phase 1 instrumentation if cheap; otherwise track as a standalone follow-on.

---

## 10. Why H3 over H1-Approach2 (recorded for the file)

Both deferred follow-ons were profiled (this session). H1-Approach2 (off-screen wakeup
coalescing) captures a **flat, off-screen-only** residual (~0.037 CPU-s/iter synthetic;
~1.8 CPU-s/10 s in the real gallery Animations tab) and carries **high** risk — it
re-introduces a wake gate removed *twice* historically (the restart trap,
`RunLoop+Rendering.swift:156-163`, commits `60665914` → `7ef12233`) plus completion-deadline
hang exposure. H3 captures a **scaling** residual on the **common** interaction path, narrows
an **existing** guarded fast path, and its win **grows with real app depth**. Decision: H3
first; revisit H1-Approach2 only if a real workload is shown to spend material time fully
off-screen.
