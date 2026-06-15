# Performance Phase — Completion Goal

- **Date:** 2026-06-15
- **Status:** Active. Umbrella goal for the remaining work in the
  [2026-06-12 next-phase proposal](2026-06-12-001-perf-next-phase-proposal.md)
  and the [2026-06-14 frontier/publication narrowing plan](2026-06-14-003-frontier-publication-narrowing-plan.md).
- **Baseline pin:** `swift-tui 30fc38bf` (Stage 0 → 1A → 1A.2 → 1B publication
  narrowing + Stage 2A/2B delta checkpoint restore all landed and pushed), org
  root `main` in sync with `origin/main`.
- **Measurement contract:** release `TermUIPerf`, interaction frames
  (`frame > 1`), same-session A/Bs, `sheet-open-latency` (rows 176) +
  `synthetic-narrow-invalidation` (rows 20/40) as the standing hot pair.

## Goal

Drive the post–Part-A sheet interaction frame from its current ~22 ms/frame
pipeline + ~8 ms/frame of head bookkeeping down toward an **O(changed-subtree)
floor** by closing every remaining ranked residual in the perf workstream —
checkpoint creation, the registration restore-walk, the unconditional animation
and raster walks, and (design-first) the every-frame root force-queue that
causes several of them — **without regressing any of the eight–plus landed wins
or weakening the correctness backstops** (the `.all` publication fallback, the
full-checkpoint oracle, scoped-restore guards, and the island-freshness seam).

The phase is **done** when each item below has either landed with a measured
win and green guards, or been explicitly closed with a recorded reason ("no-op
disproven", "deferred with named owner condition"), and the §4 infrastructure
decisions are recorded rather than left silent.

## Scope — the remaining residuals

Freshest per-interaction-frame costs at `30fc38bf` (Stage 2B final
measurement); these are the numbers each item must move:

| residual | sheet (rows 176) | narrow (rows 40) | owning item |
| --- | ---: | ---: | --- |
| checkpoint **create** p50 | ~1.20 ms | ~1.12 ms | A (Stage 2C) |
| `restoreRuntimeRegistrations` reuse walk | (sheet settle) | ~0.2–0.5 ms | B (Stage 3) |
| `processResolvedTree` (unconditional) | ~1.30 ms | ~0.35–0.65 ms | C |
| raster | ~1.29 ms (flat in rows) | ~0.75–0.78 ms | D (parallel) |
| root force-queue (upstream cause) | structural | structural | E (design-first) |

Checkpoint **restore** (the Stage 2B win: sheet 1.50→0.89 ms, narrow
1.21→0.56 ms) and the `.all` publication restore-node totals (Stage 1B:
−88.8% sheet / −64.6% narrow) are **done** and serve as the no-regression
canaries.

### A. Stage 2C — checkpoint creation + graph-field copy

The remaining half of the abortable-frame checkpoint cost. Stage 2B scoped
*restore* to proven touched nodes; *create* still snapshots the full graph
(maps, counters, indexes, lifecycle/dependency queues, every node payload)
each abortable frame.
- **Target:** reduce `head_graph_checkpoint_create_p50_ms` (~1.1–1.2 ms both
  scenarios) without regressing the Stage 2B restore win or near-full frames.
- **Constraint:** preserve the `ViewGraphCheckpointTotalityTests` set-equality
  contract and `FrameHeadDraftTransaction` counter-rewind atomicity; keep the
  full checkpoint as oracle/fallback (release: proven delta is final state;
  DEBUG: delta-vs-full oracle).
- **Exit:** create p50 drops on both hot scenarios; abort-rollback equivalence
  tests stay green; budget guard keeps near-full frames on the cheap path.

### B. Stage 3 — `restoreRuntimeRegistrations` reuse-hit walk

The rank-2 resolve residual: a per-reuse-hit recursive walk
(structuralPath-keyed lookup + Set ops + sort) over every retained-reuse
subtree, grown in `8732c8d3`.
- **Sizing first** (cheap, mandatory): a ReuseDenialTrace-style counter on
  walk node-visits/frame before any cache design.
- **Target:** ~0.2–0.5 ms/frame at rows 40 narrow, more on sheet settle, by
  caching the unchanged subtree's registration fragment at its root and
  splicing instead of re-walking (invalidate alongside
  `hasStaleIslandDescendant` / the apply path).
- **Exit:** measured restore-traversal drop on narrow without breaking
  byte-equivalence; promote to its own plan if it needs new totality invariants.

### C. `processResolvedTree` scoping (item 4)

Unconditional full-tree per-identity dictionary build every frame in
`AnimationController.swift`, regardless of whether anything animates.
- **Target:** skip or scope by the frame's dirty/animated identity set
  (~1.30 ms sheet, ~0.35–0.65 ms narrow).
- **Constraint:** the animation-teleport `ViewNodeID` re-key is a prerequisite
  only for identity-scoped *suppression*, not for scoping this walk; H1/H2 +
  animation runtime tests are the guards.

### D. Raster residuals (item 6 — parallel track)

The #2 phase at small trees (~0.75–0.78 ms narrow, flat in rows), fully
decoupled from the resolve/commit chain — the safe parallel-track candidate.
- **Exit:** measured raster reduction at small trees with renderer-output
  equivalence, or explicit deferral.

### E. Frontier narrowing (item 5 — design-first, gates A/C)

The every-frame force-queue of the portal root
(`DefaultRendererFrameHeadCoordinator.swift`) makes every interaction frame a
full top-down spine re-resolve and is the upstream *cause* of A, C, and parts
of the publication cost — it also currently masks the island freshness-cache
hazard.
- **Required before any code:** enumerate every consumer of the root walk's
  incidental guarantees (island staleness masking, registration publication,
  semantic snapshot stability, presentation portal maintenance).
- **Exit:** a written design that names how each guarantee is preserved under a
  narrowed frontier; only then a perf-validated PR. Potentially subsumes parts
  of A and the Stage 1 publication work. Treat animation-tick frames as a
  distinct, under-tested frame class throughout.

### F. §4 infrastructure decisions (recorded, not silent)

Each needs an explicit decision in the first implementation update, not a
default-to-silence:
- **Productize the breakdown probes** — land env-gated sub-phase timers behind
  `SWIFTTUI_PROFILE` permanently (4 archived-probe re-applications and counting),
  or re-defer with a named owner condition.
- **Memory occupancy budget** — H2/H3 reuse, presence carry-forward, the
  retained index, and now per-node checkpoint sets all grow retained state; at
  minimum an explicit "not now" with a number to watch (`memory_growth.tsv`).
- **Real-terminal validation** — every win across the last waves is
  headless-measured; re-affirm or schedule kitty Route B.
- **Body re-evaluation cost** — keep in VISION-GAP as design-only unless the
  re-baseline shows body time dominating a scenario.

## Definition of done (phase exit)

1. **A–C landed** with same-session A/B wins on the hot pair and green focused
   suites + `bazel test //:org_fast`; or each explicitly closed with a recorded
   "no-op disproven" / "deferred (named condition)".
2. **D** landed or deferred on the parallel track.
3. **E** has a written design enumerating the root-walk consumers, with code
   landed only if the design clears them; otherwise recorded as design-complete,
   implementation-deferred.
4. **F** decisions recorded.
5. **No regression:** Stage 1B `.all` restore-node totals and Stage 2B restore
   p50 hold within noise; narrow path (already ~97% scoped) stays flat as the
   canary; full gate green under load.
6. Each landed slice has a completion report under `docs/reports/` and a pin
   bump recorded in this root.

## Standing guardrails (carry into every item)

- **Same-session A/B only**; clean `Tools/TermUIPerf/.build` on any core-struct
  change (stale baselines produced phantom ±10% twice).
- **Struct growth ⇒ clean rebuild everywhere** — a new stored field on
  `ViewGraph`/`ViewNode`/`ResolvedNode`/`EnvironmentValues` SIGBUSes stale
  debug/test objects in destroy paths (hit repeatedly this phase). New
  `ResolvedNode` fields need a `ResolvedNodePhaseOwnershipTests` manifest entry;
  new `ViewNode` fields need `Checkpoint` parity.
- **One flag, one consumer** — staleness signals must not serve both
  reuse-denial and rebuild semantics (the island-split lesson).
- **Animation-tick frames are a distinct frame class** — graph-local dirt, no
  spine re-resolve, no force-root; every reuse/commit/checkpoint change needs a
  guard there (`animationFramesKeepTabHostedPaneSurfaceStable` is the template).
- **`resolve_ms` ≠ resolve cost** — it wraps only `evaluateDirtyNodes`;
  `snapshot()` and the checkpoint pair live in `head_*` columns. Validate on
  total CPU + head columns.
- **Coordination-only probes/overlays never land in a public child repo.**

## Sequencing

0. **Re-baseline ritual** (mandatory opener) — re-run the residual map at
   `30fc38bf` (narrow 20/40, sheet 176 co-located + sibling + popover overlay,
   layout-scroll-burst, 15–20 iterations, one session) before starting A. Every
   target above inherits these numbers.
1. **A (Stage 2C)** — largest measured remaining head cost, mechanism already
   scoped by Stage 2B's boundary.
2. **B sizing probe** (cheap) in parallel with A; commit B's cache only if the
   probe justifies it.
3. **C** opportunistically after A.
4. **D** on a parallel track throughout.
5. **E** only as a designed successor once A–C quantify what the root walk still
   costs.
6. **F** decisions recorded in the first implementation update.

## References

- Phase proposal: [2026-06-12-001](2026-06-12-001-perf-next-phase-proposal.md)
- Active tranche: [2026-06-14-003](2026-06-14-003-frontier-publication-narrowing-plan.md)
- Stage 2B (restore done): [reports/2026-06-15-stage-2b-guarded-delta-checkpoint-restore.md](../reports/2026-06-15-stage-2b-guarded-delta-checkpoint-restore.md)
- Stage 1B (publication done): [reports/2026-06-15-stage-1b-all-publication-diffing.md](../reports/2026-06-15-stage-1b-all-publication-diffing.md)
