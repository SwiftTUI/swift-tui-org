# Performance Phase — Completion Goal

- **Date:** 2026-06-15
- **Status:** Closed for the original ranked tranche; current as of
  `swift-tui 8cebb787` / `0.0.20`. The original phase dispositions were
  recorded on 2026-06-15, then the identified sheet invalidation cone was
  diagnosed and fixed in two follow-up PRs. The current-pin re-baseline is now
  recorded in
  [2026-06-16-perf-phase-rebaseline-0-0-20.md](../reports/2026-06-16-perf-phase-rebaseline-0-0-20.md);
  use that report for new perf work, not the `30fc38bf` numbers below.
  Umbrella goal for the remaining work in the
  [2026-06-12 next-phase proposal](2026-06-12-001-perf-next-phase-proposal.md)
  and the [2026-06-14 frontier/publication narrowing plan](2026-06-14-003-frontier-publication-narrowing-plan.md).
- **Original measurement pin:** `swift-tui 30fc38bf` (Stage 0 -> 1A -> 1A.2 ->
  1B publication narrowing + Stage 2A/2B delta checkpoint restore all landed and
  pushed).
- **Current pin:** `swift-tui 8cebb787` (`0.0.20`), org root `main` in sync with
  `origin/main`.
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

## Phase status — current as of `0.0.20`

The cheap/safe head-residual levers were exhausted first; those investigations
converged on one dominant lever: the sheet open/close invalidation cone. That
cone was then fixed in two scoped follow-ups after this umbrella doc was first
written. The current state is therefore stronger than the original status table:
the original A-F items have evidence-based dispositions, and item 4b has landed
with measured wins.

| item | disposition | evidence |
| --- | --- | --- |
| 0 re-baseline | ✅ done | [report](../reports/2026-06-15-perf-phase-rebaseline.md); reconciled a phantom 3× (row-count + battery) |
| A checkpoint create | ⏸️ deferred | cheap reuse = no-op; cost is the O(N) dict build; structural ([finding](../reports/2026-06-15-stage-2c-checkpoint-create-finding.md)) |
| B restore-walk | ✅ closed | median-0 reuse on sheet → walk absent on hot path; narrow-only ([sizing](../reports/2026-06-15-items-b-c-sizing-and-pivot-to-e.md)) |
| C processResolvedTree | ⏸️ deferred | only skippable on unchanged frames; root-eval-bounded; high blast radius |
| D raster | ⏸️ deferred | `raster_ms` 0.74–1.44 ms (2–5.5% frame); worker compute overlapped |
| E frontier narrowing | ✅ design captured | reuse *works* on stable frames; the cost is the toggle cone, not the force-queue ([design](../reports/2026-06-15-item-e-frontier-design-and-reframing.md)) |
| F infra decisions | ✅ recorded / partial infra shipped | reuse trace and invalidation-source trace now have durable file sinks; create-split + `SWIFTTUI_PROFILE` sub-phase tracing remain future infra |
| 4b sheet invalidation cone | ✅ landed | mechanism 1 removed redundant post-action follow-up invalidation ([report](../reports/2026-06-15-sheet-open-cone-followup-fix-results.md)); mechanism 2 stopped overlay-entry invalidation from mapping to the portal root ([report](../reports/2026-06-15-sheet-open-cone-mechanism-2-portal-translation-fix.md)) |

**Current headline:** the ~18 ms full-recompute sheet frames were driven by the
**sheet open/close invalidation cone** (~890 identities), not checkpoint
bookkeeping and not ordinary leaf reuse failure. The first follow-up removed the
content-root post-action cone (`total_cpu_seconds` 1.4409 -> 1.1649, -19.2%).
The second removed the portal-root translation cone (`total_cpu_seconds` 1.1778
-> 0.9700, -17.6% from mechanism 1; -32.7% cumulative from the original pin).
The steady-state `invalidation-conflict` cone is now eliminated for the
`sheet-open-latency` cycle; remaining work is lower-EV residuals and requires a
fresh current-pin ranking.

## Scope — the remaining residuals

Historical per-interaction-frame costs at `30fc38bf`, re-baselined on AC
2026-06-15
([report](../reports/2026-06-15-perf-phase-rebaseline.md)). **Row count matters:**
sheet costs scale ~linearly (~0.025 ms/row of `ckpt_create`), so numbers are
only comparable at identical `TERMUI_PERF_SHEET_TREE_ROWS`. Sheet shown at 44
(default; the Stage 2B / `~1.2ms` reference) and 176 (amplified signal).
Do not use this table as the current ranking; use the
[0.0.20 re-baseline](../reports/2026-06-16-perf-phase-rebaseline-0-0-20.md).

| residual | sheet 44 | sheet 176 | narrow 40 | owning item |
| --- | ---: | ---: | ---: | --- |
| checkpoint **create** p50 (×2/frame) | 1.18 ms | 4.33 ms | 1.06 ms | A (Stage 2C) |
| `restoreRuntimeRegistrations` reuse walk | (in resolve) | (in resolve) | ~0.2–0.5 ms | B (Stage 3) |
| `processResolvedTree` (unconditional) | 0.47 ms | 1.74 ms | 0.58 ms | C |
| raster | (per-frame TSV) | (per-frame TSV) | ~0.75–0.78 ms | D (parallel) |
| root force-queue (upstream cause) | structural | structural | structural | E (design-first) |

Checkpoint **restore** is already Stage-2B-low (0.86 ms @44 / 3.20 ms @176 sheet;
0.54 ms narrow-40) and the `.all` publication restore-node totals (Stage 1B:
−88.8% sheet / −64.6% narrow) are **done** — both serve as no-regression
canaries. The narrow path (narrow-40 total_cpu 0.2412 ≈ documented 0.250) is the
primary canary that must not move.

### A. Stage 2C — checkpoint creation + graph-field copy — DEFERRED

**Status: parked behind structural work and a new baseline.** A create-split
probe localized the cost to ~99.9% in the per-node checkpoint dictionary build
(graph-field copy is COW-cheap), and the cheap node-image-reuse lever
(Stage 2C.1) measured as a no-op because it still reconstructs the N-entry
dictionary. The only create wins that remove that O(N) build are structural — a
persistent copy-on-mutation node-checkpoint store (the design doc's deferred
high-blast-radius slice) or the persistent graph/state split. Now that the sheet
cone is fixed, this should be re-ranked from a fresh `0.0.20` re-baseline before
taking on that blast radius. Parked here; full write-up:
[reports/2026-06-15-stage-2c-checkpoint-create-finding.md](../reports/2026-06-15-stage-2c-checkpoint-create-finding.md).
Probe archived at [docs/perf/checkpoint-create-split-probe/](../perf/checkpoint-create-split-probe/README.md).

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

**Status: closed for this phase.** The rank-2 resolve residual is a
per-reuse-hit recursive walk (structuralPath-keyed lookup + Set ops + sort) over
every retained-reuse subtree, grown in `8732c8d3`.
Sizing from the re-baseline showed the walk is absent on the sheet hot path
(median reuse 0 at the time) and only material on the narrow/high-reuse path
(~0.2-0.5 ms/frame). A cross-frame registration-fragment cache is not justified
without a new current-pin measurement that makes this narrow-only cost material.

### C. `processResolvedTree` scoping (item 4)

**Status: deferred.** Unconditional full-tree per-identity dictionary build every
frame in `AnimationController.swift`, regardless of whether anything animates.
It is only safely skippable when the resolved tree is unchanged; sheet
interaction frames change the tree, and animation/transition correctness is a
high-blast-radius area. Revisit only after a fresh baseline shows it dominates a
current workload.

### D. Raster residuals (item 6 — parallel track)

**Status: deferred as low-EV for this phase.** The #2 phase at small trees
(~0.75–0.78 ms narrow, flat in rows) is decoupled from the resolve/commit chain,
but the measured sheet cost was much more affected by the cone. Future raster
work should be a separate renderer-output-equivalence effort, not a continuation
of the sheet-cone tranche.

### E. Frontier narrowing (item 5 — design-first)

**Status: design captured; implementation deferred.** The every-frame force-queue of the portal root
(`DefaultRendererFrameHeadCoordinator.swift`) makes every interaction frame a
full top-down spine re-resolve, but the decisive trace showed the dominant sheet
cost was not the force-queue itself; it was the invalidation cone. The cone fixes
therefore removed the recompute source without weakening the root-walk
correctness backstops. Any future force-root/focus narrowing must still preserve
the enumerated consumers: presentation portal maintenance, island freshness /
Part 0 orphaning protection, runtime registration publication, and semantic
snapshot stability.

### 4b. Sheet invalidation-cone narrowing — LANDED

The measured cone split into two mechanisms:

1. **Content-root post-action follow-up.** Button dispatch recorded a
   `followUpInvalidationIdentity` at the owner `Layout[0]`, then
   `flushPostActionInvalidations` invalidated that content-root ancestor after
   the action's own `@State` write had already scheduled a precise invalidation.
   The fix skips the owner-scope follow-up when the action already invalidated,
   leaving the follow-up as a quiet-action backstop.
2. **Portal-root translation fallback.** Newly inserted overlay-entry identities
   were translated to `__TerminalUIPortalHost` when the overlay host was not yet
   materialized. That portal host is the graph root and an ancestor of the
   background, so it swept the background into `invalidation-conflict`. The fix
   removes the portal-root fallback; an unmapped overlay-entry identity stays
   unmapped rather than mapping to an ancestor.

After both fixes, `SWIFTTUI_REUSE_TRACE` reports zero steady-state
`invalidation-conflict` on the sheet cycle. Large recomputes left in that report
are one-off cold-start / first-open warmup (`no-node` / `suppressed`) rather than
the repeated cone this phase was targeting.

### F. §4 infrastructure decisions — RECORDED 2026-06-15

- **Productize the breakdown probes — DECISION: productize, in a dedicated infra
  PR (not inline with a perf win).** This session added a 6th archived probe
  (create-split) and proved its value within the hour (it disproved the Item A
  premise). **UPDATE 2026-06-15 — reuse-trace and invalidation-source trace steps DONE**
  ([report](../reports/2026-06-15-reuse-trace-productization-and-cone-confirmation.md)):
  the reuse-trace (`SWIFTTUI_REUSE_TRACE`) was **not** broken — the "empty output
  on sheet" was a capture artifact (it writes stderr-only, which is not collected
  with `frames.tsv`). It now has a durable file sink (`SWIFTTUI_REUSE_TRACE_FILE`)
  auto-captured by the harness as `<artifacts-root>/reuse-trace.log`, plus a test.
  The follow-up `SWIFTTUI_INVAL_TRACE` / `SWIFTTUI_INVAL_TRACE_FILE` decomposes
  raw -> translated -> force-root invalidation sets and pinned both sheet-cone
  mechanisms. Remaining productization (create-split + a `SWIFTTUI_PROFILE`
  sub-phase trace) is still future infra. Owner condition: before the next
  checkpoint/resolve optimization that needs sub-phase attribution.
- **Memory occupancy budget — DECISION: not now; watch `memory_growth.tsv`.** No
  retained-state growth landed this session (Item A's per-node checkpoint store
  was *not* built). Revisit when the persistent copy-on-mutation store or the
  graph/state split is taken up (both grow retained state materially).
- **Real-terminal validation — DECISION: still deferred (kitty Route B).** No
  shipped win this session needs real-terminal confirmation (all closures were
  analysis/no-op). Re-affirm when a measured win actually lands.
- **Body re-evaluation cost — DECISION: keep VISION-GAP design-only.** The sheet
  cone previously re-ran ~898 bodies; that repeated cone is now gone for the
  measured sheet cycle. Promote body re-evaluation cost only if a fresh current
  baseline shows another workload dominated by invalidated body work rather than
  checkpoint/raster/animation bookkeeping.

## Definition of done (phase exit)

1. **A–C landed** with same-session A/B wins on the hot pair and green focused
   suites + `bazel test //:org_fast`; or each explicitly closed with a recorded
   "no-op disproven" / "deferred (named condition)".
2. **D** landed or deferred on the parallel track.
3. **E** has a written design enumerating the root-walk consumers, with code
   landed only if the design clears them; otherwise recorded as design-complete,
   implementation-deferred.
4. **F** decisions recorded.
5. **4b sheet cone** either landed or explicitly deferred with a measured reason.
6. **No regression:** Stage 1B `.all` restore-node totals and Stage 2B restore
   p50 hold within noise; narrow path (already ~97% scoped) stays flat as the
   canary; full gate green under load.
7. Each landed slice has a completion report under `docs/reports/` and a pin
   bump recorded in this root.

As of `0.0.20`, this definition is satisfied for the original tranche: A/C/D are
deferred with named reasons, B/E/F are closed or recorded, and 4b landed with
reports and root pin bumps. Further perf work should be opened as a new tranche
after re-baselining.

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

0. **Re-baseline ritual** — ✅ done 2026-06-15
   ([report](../reports/2026-06-15-perf-phase-rebaseline.md)).
1. **A (Stage 2C create)** — ⏸️ DEFERRED: cheap lever no-op; structural (section A).
2. **B (restore-walk)** — ✅ CLOSED 2026-06-15, not justified: median-0 reuse on
   sheet (walk absent on hot path), narrow-only ~0.3 ms
   ([sizing](../reports/2026-06-15-items-b-c-sizing-and-pivot-to-e.md)).
3. **C (`processResolvedTree`)** — ⏸️ DEFERRED: only skippable on unchanged-tree
   frames; hot-path walk needed and root-evaluation-bounded; high blast radius.
4. **E (frontier narrowing)** — ✅ DESIGN CAPTURED, implementation deferred
   ([design + reframing](../reports/2026-06-15-item-e-frontier-design-and-reframing.md)).
   Key finding: per-frame data + reuse-trace show the dominant sheet residual is
   the **~18 ms full-recompute frames driven by the sheet-toggle invalidation
   cone** (reuse *works* on stable frames: 883/921 at 6.4 ms). The force-queue
   only governs walk *reach*, not the cone — so E is necessary-but-not-sufficient,
   and the real lever was **item 4b**.
4b. **Invalidation-cone narrowing (the actual sheet lever)** — ✅ LANDED in two
   follow-ups. Mechanism 1 removed the redundant post-action owner invalidation;
   mechanism 2 removed the portal-root translation fallback. Steady-state sheet
   `invalidation-conflict` is now eliminated.
5. **D (raster)** — ⏸️ DEFERRED 2026-06-15 (low-EV): main-thread `raster_ms` is
   0.74 ms narrow / 1.44 ms sheet (2–5.5% of frame), and `worker_raster_compute_ms`
   (5.29 ms) runs on an overlapped worker thread (enqueue 0, off critical path).
   Small win in a deep subsystem; now below the landed cone lever.
6. **F** decisions recorded as items land. Reuse/invalidation traces are
   productized enough for this tranche; create-split and profile sub-phase traces
   remain future infra.
7. **Current-pin re-baseline** — ✅ DONE 2026-06-16
   ([report](../reports/2026-06-16-perf-phase-rebaseline-0-0-20.md)). The next
   tranche should start with a focused diagnostics pass on co-located vs sibling
   sheet-176 before choosing checkpoint storage, force-root/focus narrowing,
   `processResolvedTree`, raster residuals, or broader body re-evaluation work.

## References

- Phase proposal: [2026-06-12-001](2026-06-12-001-perf-next-phase-proposal.md)
- Active tranche: [2026-06-14-003](2026-06-14-003-frontier-publication-narrowing-plan.md)
- Stage 2B (restore done): [reports/2026-06-15-stage-2b-guarded-delta-checkpoint-restore.md](../reports/2026-06-15-stage-2b-guarded-delta-checkpoint-restore.md)
- Stage 1B (publication done): [reports/2026-06-15-stage-1b-all-publication-diffing.md](../reports/2026-06-15-stage-1b-all-publication-diffing.md)
- Sheet cone mechanism 1: [reports/2026-06-15-sheet-open-cone-followup-fix-results.md](../reports/2026-06-15-sheet-open-cone-followup-fix-results.md)
- Sheet cone mechanism 2: [reports/2026-06-15-sheet-open-cone-mechanism-2-portal-translation-fix.md](../reports/2026-06-15-sheet-open-cone-mechanism-2-portal-translation-fix.md)
- Current-pin re-baseline: [reports/2026-06-16-perf-phase-rebaseline-0-0-20.md](../reports/2026-06-16-perf-phase-rebaseline-0-0-20.md)
