# Performance Workstream — Next Phase Proposal

- **Date:** 2026-06-12
- **Status:** Proposed. Successor to the completed
  [2026-06-10 assessment](2026-06-10-001-perf-workstream-assessment-next-wave-proposal.md)
  (all six ranked items closed; see
  [reports/2026-06-12-next-wave-completion.md](../reports/2026-06-12-next-wave-completion.md)).
- **Baseline:** `swift-tui main@e9b9d00e` (stamp-skip + Part 0 + island
  split + Part A + popover split all landed), org pin `dd9e51f`.

## 1. Where the pipeline stands

Measured 2026-06-12 at `e9b9d00e` unless noted; release `TermUIPerf`,
interaction frames (`frame > 1`), same-session A/Bs throughout.

### `sheet-open-latency` rows=176, co-located (per interaction frame, ms)

| cost | value | share of 22.15 pipeline | note |
| --- | ---: | ---: | --- |
| resolve | 9.77 | 44% | was 17.79 pre-Part-A |
| commit | 4.55 | 21% | ~99% = `graphRegistrations` (probe-verified) |
| checkpoints (create + restore) | 1.13 + 2.60 | ~17%* | head columns, outside pipeline_ms |
| measure | 2.53 | 11% | was 7.04 pre-Part-A |
| place | 2.17 | 10% | |
| semantics / `processResolvedTree` / raster | 1.34 / 1.30 / 1.29 | ~6% each | |

\* checkpoint cost is measured by the `head_*` columns and is **not** inside
`pipeline_ms` — the share is illustrative against the same denominator.

### `synthetic-narrow-invalidation` (rows 20/40, per interaction frame)

resolve 1.02/1.33 ms, total CPU 0.166–0.169 / 0.250 s/iter, computed flat at
17–18 nodes, reused 179/358. The narrow path has absorbed six optimization
waves; its remaining slope is the rank-2/3 walks below.

### What changed since the last assessment's §3

The 2026-06-10 "key findings" are stale in three ways: (a) resolve is no
longer 60%+ of settle frames (Part A removed the focus-cone recompute);
(b) commit is now the **#2 sheet cost with a confirmed mechanism**, not an
unattributed share; (c) the checkpoint pair is now visible per-frame via the
head-timing columns and is the **#3 sheet cost**. Rankings below use the
fresh numbers.

## 2. Phase goal

Attack the post-Part-A sheet residual (commit + checkpoints ≈ 8.3 ms/frame of
bookkeeping against an O(changed-subtree) floor) and the remaining
O(reused-subtree) resolve walks, without regressing the six landed wins.
Secondary: pay down the measurement-infrastructure debt that has now cost
three probe re-applications.

## 3. Ranked work

### 0. Re-baseline ritual (mandatory opener, ~zero design risk)

Re-run the residual map at the current pin before starting any item:
narrow rows 20/40, sheet rows 176 (co-located + sibling + popover overlay),
layout-scroll-burst, 15–20 iterations, one session. Every ranking below
inherits these numbers; the completed plan showed twice that stale baselines
produce phantom regressions (a 3.5-hour-old baseline once showed a uniform
+10%). Archive under `/tmp` is fine; record aggregates in the eventual
reports.

### 1. Root-evaluation registration publication scoping (the item-5 finding)

**Evidence:** commit ≈ 4.55 ms/frame on sheet interaction frames; the
rebased breakdown probe attributes ~99% of the transaction to
`graphDraft.commitRuntimeRegistrations`, with publication mode `.all` on 58%
of frames. Mechanism (code-verified): sheet frames carry unmapped
presentation identities → `nodeIDsForInvalidation` flips
`requiresRootEvaluation` → `selectiveDirtyEvaluationPlan()` returns nil →
`ViewGraphFrameDraft.recordDirtyEvaluationPlan(nil)` → `.all`.

**Directions (either or both):**
- **1a — map the identities.** Presentation/portal identities that today
  miss `nodeIDByIdentity` could be registered (or translated at the
  invalidation choke point) so the selective plan survives and publication
  stays `.subtrees`. Attacks the *trigger*. Risk: the root-evaluation
  fallback is also a correctness backstop ("unmapped invalidation falls back
  to root evaluation" is test-pinned from `8732c8d3`); narrowing it needs the
  same care as frontier narrowing (item 5 below) — start with an inventory
  of WHICH identities are unmapped on sheet frames (one trace run).
- **1b — make `.all` publication cheap.** Diff-based republication: publish
  only registrations that actually changed versus live (the G3a/G11
  index-patcher revisit, whose sanctioned condition is now met). Attacks the
  *cost*. The 2026-05-31 scoped-restore work (`normalizeScopedRestoreOrder`,
  byte-identity equivalence tests) is the template.

**Size:** up to ~4.5 ms/frame on sheet frames (~20% of pipeline); narrow
frames are already ~97% scoped, so expect no narrow-path movement (use it as
the no-regression canary).
**Guards:** registration-restore equivalence tests (byte-identity),
RuntimeRegistrationRestoreScopingTests, ReaderAttributionTests, full gate,
sheet + narrow + popover A/B.

### 2. Abortable-frame checkpoint cost

**Evidence:** `head_graph_checkpoint_create` 1.13 + `restore` 2.60 ms per
sheet interaction frame (rows=176) — the ×2 full-graph copy per abortable
frame the 2026-06-10 assessment flagged, now measured per-frame. Sheet runs
historically show 7–8 cancelled per 18 committed frames, so the abort path
is hot and restores are frequent.

**Direction:** incremental checkpoints — capture per-node checkpoints only
for nodes the frame actually touches (the dirty frontier + applied set),
falling back to full capture on root-evaluation frames until item 1a lands
(the two items compound: a surviving selective plan bounds the checkpoint
set for free). The checkpoint totality contract
(`ViewGraphCheckpointTotalityTests` set-equality) and the draft-discard
machinery (`FrameHeadDraftTransaction`, counter rewind atomicity — see the
stamp-skip review's checkpoint findings) are the invariants to preserve.
**Size:** up to ~3.7 ms/frame on sheet frames; narrow frames pay ~0.8–1.8 ms
(create+restore at rows 20/40) — wins scale with tree size.
**Risk:** high blast radius (checkpoint/restore underpins frame aborts and
the run-loop's convergence machinery). Own PR, full gate under load, and the
ViewGraphCheckpointTotalityTests "guard has teeth" pattern extended to the
incremental capture set.

### 3. `restoreRuntimeRegistrations` reuse-hit walk

**Evidence:** the stamp-skip survey's rank-2 resolve residual — a recursive
walk over every retained-reuse hit's subtree
(`ViewGraphRuntimeRegistrationRestoration.swift`: per node, a
structuralPath-keyed dictionary lookup + Set ops + a sort), executed per
`reusableSnapshot` hit (`ViewFoundation.swift` reuse return). Grew in
`8732c8d3` (structuralPath-keyed map replaced a single identity-keyed
lookup). At rows=40, ~358 reused nodes × the per-node constant lands this as
the largest un-attacked O(reused-subtree) term inside `evaluateDirtyNodes`.

**Direction:** the registration set for an unchanged retained subtree is
itself unchanged — cache the subtree's registration fragment at its root
(invalidate alongside `hasStaleIslandDescendant` / the apply path) and
splice it instead of re-walking. Sizing first: a one-line counter
(ReuseDenialTrace-style) on walk node-visits per frame, then decide.
**Size:** plausibly 0.2–0.5 ms/frame at rows=40 narrow; more on sheet
settle frames. Sizing probe before committing to the cache design.

### 4. `processResolvedTree` scoping

**Evidence:** `head_animation_process_resolved_tree` 1.30 ms per sheet
interaction frame (0.35–0.65 ms narrow) — an unconditional full-tree walk
building per-identity dictionaries every frame
(`AnimationController.swift`), regardless of whether anything animates.

**Direction:** skip or scope by the frame's dirty/animated identity set; the
H1/H2 suites plus the animation runtime tests are the guards. Note the
animation-teleport `ViewNodeID` re-key (the unlanded Stage-4 G5 half) remains
a prerequisite only for identity-scoped *suppression*, not for scoping this
walk.

### 5. Frontier narrowing (structural; co-design required)

The every-frame force-queue of the portal root
(`DefaultRendererFrameHeadCoordinator.swift:261-266`) makes every
interaction frame a full top-down spine re-resolve and is the upstream
*cause* of several costs above (it is also what currently masks the island
freshness-cache hazard). The Part 0 / island-split machinery
(`evaluationHost`, `hasStaleIslandDescendant`) now provides the
invalidation bridge a narrowed frontier needs — but the flicker regression
showed exactly how sharp this seam is (animation-tick frames are a distinct,
under-tested frame class). Treat as a design-first item: enumerate every
consumer of the root walk's incidental guarantees (island staleness masking,
registration publication, semantic snapshot stability, presentation portal
maintenance) before any code. Potentially subsumes parts of items 1a and 2.

### 6. Raster residuals (O3)

Unchanged from the prior assessment: raster is the #2 phase at small trees
(0.75–0.78 ms narrow, flat in rows). Best parallel-track candidate — fully
decoupled from the resolve/commit items above.

## 4. Infrastructure debt (decision wanted, not silence)

- **Productize the breakdown probes.** Three archived-probe re-applications
  (commit ×2, place ×1) and a fresh rebase this phase. The
  [2026-05-28 profiling product plan](2026-05-28-001-profiling-product.md)
  exists; minimum viable: land `CommitBreakdownProbe`-style env-gated
  sub-phase timers permanently behind `SWIFTTUI_PROFILE` (the grammar
  already exists) instead of archiving patches. Decide: build the minimum,
  or explicitly re-defer with a named owner condition.
- **Memory occupancy budget:** H2/H3 retained reuse, presence carry-forward,
  the retained index, and now per-node checkpoint sets (item 2) all grow
  retained state. At minimum an explicit "not now" with a number to watch
  (`memory_growth.tsv` plateaus exist per run already).
- **Real-terminal validation:** every win in two waves is headless-measured;
  kitty Route B remains deferred. Re-affirm or schedule.
- **Body re-evaluation cost:** still attacked by nothing (reader attribution
  narrows *which* nodes invalidate; invalidated bodies still re-run fully).
  VISION-GAP carries it as design-only; keep it there unless item 0's
  re-baseline shows body time dominating a scenario.

## 5. Standing traps (carry into every item)

- **Same-session A/B only**; stale baselines have produced phantom ±10%
  twice. Clean `Tools/TermUIPerf/.build` on any core-struct change.
- **Struct growth ⇒ clean rebuild everywhere**: adding a stored field to a
  core struct (`EnvironmentValues`, `ResolvedNode`) makes stale debug/test
  objects crash with SIGBUS in destroy paths (hit twice this phase).
- **One flag, one consumer**: staleness signals must not serve both
  reuse-denial and rebuild semantics (the island-split lesson).
- **Animation-tick frames are a distinct frame class** — graph-local dirt,
  no spine re-resolve, no force-root. Every reuse/commit change needs a
  guard in that class (`animationFramesKeepTabHostedPaneSurfaceStable` is
  the template).
- **`@State` reads are slot-bound to their ViewNodeContext** — moving a read
  into a trigger leaf rebinds the slot (the tip-popover carve-out).
- **resolve_ms ≠ resolve cost**: it wraps only `evaluateDirtyNodes`;
  `viewGraph.snapshot()` and the checkpoint pair live in `head_*` columns.
  Validate on total CPU + head columns.
- New `ResolvedNode` stored fields need a
  `ResolvedNodePhaseOwnershipTests` manifest entry; new `ViewNode` stored
  fields need `Checkpoint` parity.

## 6. Suggested sequencing

1. Item 0 (re-baseline) → pick between 1a and 1b with the unmapped-identity
   inventory in hand.
2. Item 1 (registration scoping) — largest measured, clearest mechanism.
3. Item 3 sizing probe (cheap) in parallel with item 2 design.
4. Item 2 (checkpoints) after item 1 lands (they interact via the selective
   plan).
5. Item 4 opportunistically; item 6 as a parallel track; item 5 only as a
   designed successor once 1–2 quantify what the root walk still costs.
6. §4 decisions recorded in this doc's first implementation update.

## 7. References

- Completion report:
  [2026-06-12-next-wave-completion.md](../reports/2026-06-12-next-wave-completion.md)
- Part 0 + island split:
  [2026-06-12-part0-divergent-identity-orphaning-fix.md](../reports/2026-06-12-part0-divergent-identity-orphaning-fix.md)
- Stamp-skip (cost ranking + accounting traps):
  [2026-06-11-resolve-stamp-skip-results.md](../reports/2026-06-11-resolve-stamp-skip-results.md)
- Commit probe archive:
  [docs/perf/commit-ms-breakdown-probe](../perf/commit-ms-breakdown-probe/README.md)
  (rebased against `2b05d0fa`)
- Registration-restore scoping template:
  [2026-05-31-commit-ms-registration-restore-fix-results.md](../reports/2026-05-31-commit-ms-registration-restore-fix-results.md)
- Profiling product plan:
  [2026-05-28-001-profiling-product.md](2026-05-28-001-profiling-product.md)
