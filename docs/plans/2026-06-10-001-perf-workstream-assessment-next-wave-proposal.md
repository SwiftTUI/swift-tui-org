# Performance Workstream Assessment & Next-Wave Proposal

- **Date:** 2026-06-10
- **Status:** Proposal (assessment complete; next steps ranked and verified)
- **Measured at:** `swift-tui` local `main@bc63495a` (0.0.19 + merged
  `perf/sheet-open-reader-attribution`, `SWIFTTUI_READER_ATTRIBUTION` default-ON)
- **Method:** multi-agent assessment — four documentation/code surveys, one
  live `TermUIPerf` measurement run, a first-principles cost model, exhaustive
  candidate enumeration (24), adversarial code-level verification of the top 8
  (8/8 premises confirmed), and a completeness critique.

## 1. Where the workstream stands

The measure → biggest-residual → fix ratchet (G-series hardening, H1 offscreen
elision, H2 scoped resolve reuse, H3 retained-subtree bookkeeping skip,
commit_ms registration-restore scoping, place_ms identical-subtree sync skip,
sheet-open reader attribution) has compounded as designed. Verified live at
`bc63495a`:

- **All landed wins are holding.** place_ms and commit_ms sit within ~10% of
  their 2026-05-31 post-fix values (≈ machine drift; this run was on battery).
  Recompute is flat in tree size exactly as H2/H3 designed:
  `resolved_computed` ≈ 19 nodes regardless of rows, vs ~358 reused at
  rows=40.
- **Reader attribution reproduces same-session.** Flag-on vs flag-off at
  rows=40: resolve −9.7%, total CPU −9.4%, input p95 −10.2% — the published
  ~−9% win, growing with tree size. The sheet background is reused on **both**
  open and close transition frames (open computes 227/921, close 194/894 at
  rows=176).
- **Idle is at the theoretical floor** (zero CPU: loop suspends on the event
  pump, `nextWakeInstant == nil` schedules no timer —
  `RunLoop.swift:864-941`, `Scheduler.swift:169-184`). Off-screen animation is
  near floor (elided tick p50 0.01 ms); the only residual is the per-tick
  wakeup itself (coalescing remains deliberately deferred).
- **Unpublished:** at assessment time the merged work was local-only
  (swift-tui main 7 ahead, org root 8 ahead of origin). The coordinated push is
  step 0 below.

## 2. Live measurement results

Conditions: `termui-perf run --mode async`, release (`swift run -c release`),
M5 Max **on battery** (cross-session absolute comparisons carry drift caveats;
all A/B claims are same-session). `Tools/TermUIPerf/.build` was cleaned first
(stale-struct-skew pitfall). Artifacts:
`swift-tui/.perf/runs/{live-r20,live-r40,live-r20-flagoff,live-r40-flagoff,live-sheet176,live-sheet704}`
(ephemeral, not committed).

### 2.1 `synthetic-narrow-invalidation` interaction frames (20 iters)

| phase | rows=20 ms (% of 3.722) | rows=40 ms (% of 5.993) |
| --- | --- | --- |
| resolve | 1.224 (32.9%) | 2.003 (33.4%) |
| measure | 0.518 (13.9%) | 0.935 (15.6%) |
| place | 0.407 (10.9%) | 0.735 (12.3%) |
| semantics | 0.376 (10.1%) | 0.731 (12.2%) |
| draw | 0.137 (3.7%) | 0.256 (4.3%) |
| raster | 0.723 (19.4%) | 0.723 (12.1%) |
| commit | 0.307 (8.2%) | 0.580 (9.7%) |

Total CPU 0.1640 ± 0.0048 / 0.2517 ± 0.0079 s/iter (CV ~3%).

### 2.2 `sheet-open-latency`

- rows=176: transition frames 65.6 ms pipeline — resolve 29.83 (45.5%),
  measure 17.10 (26.1%), commit 9.87 (15.0%), place 4.38. Settle frames
  35.5 ms — resolve 21.49 (60.6%), with **898 computed / 0–26 reused**.
- rows=704: transition 262.3 ms — resolve 119.93 (45.7%), measure 70.28
  (26.8%), commit 41.84 (16.0%). Settle 144.5 ms — resolve 90.87 (62.9%),
  894 computed. Initial frame 283.7 ms.

## 3. Key findings

### 3.1 `resolve_ms` regressed +73/+91% since 2026-05-31 (untriaged)

Narrow-invalidation interaction resolve is 1.224/2.003 ms (rows 20/40) vs the
0.706/1.049 recorded in the 2026-05-31 place-ms report. place/commit moved only
~+10% (≈ uniform machine drift), so the bulk of the resolve delta is **real
code evolution in the 0.0.19 window** (Canvas redesign etc.). It is **not**
reader attribution: same-session flag-off is *worse* (1.238/2.218). The
2026-06-04 corpus report already showed resolve ≈ 1.8 ms / "resolve dominates
37–53%", so the regression predates the sheet work. The scenario file is
unchanged since the 05-31 runs, so the comparison is apples-to-apples.

### 3.2 Resolve is now the dominant residual in every workload class

~33% of narrow-invalidation pipeline, ~46% of sheet transition frames, ~61–63%
of settle frames, ~44–53% of animation-scenario frames (06-04 corpus).

### 3.3 The G3a/G11 deferral premise is false on transition frames

"Commit/index is off the critical path (<1% of frame)" was measured on narrow
interaction frames. On sheet **transition** frames commit is 15–16% of pipeline
and ~4× the settle-frame commit (9.9/41.8 ms at rows 176/704), and is
unattacked. Deferral decisions inherit the workload they were measured on; the
transition-frame commit needs its own diagnosis before the deferral is
re-affirmed or reversed.

### 3.4 Settle frames are the single worst first-principles violation

A focus move after a sheet transition should repaint ~2 leaves; instead the
full tree re-resolves (898 computed, resolve 21.5/90.9 ms). This is the
documented deferred residual with a documented path: Part 0 (orphaning fix) →
Part A (drop `IsFocusedKey` from the reuse snapshot). See
[reports/2026-06-09-lever-b-implementation-and-findings.md](../reports/2026-06-09-lever-b-implementation-and-findings.md)
§RESOLUTION.

### 3.5 Measurement accounting traps (verified in code)

- `resolve_ms` wraps **only** `viewGraph.evaluateDirtyNodes`
  (`DefaultRendererFrameHeadCoordinator.swift:277-284`). The ×2 full-graph
  checkpoints per abortable frame (`ViewGraphCheckpointing.swift`) and
  `AnimationController.processResolvedTree` (`AnimationController.swift:520` —
  an unconditional full-tree walk building 6 per-identity dictionaries every
  frame) are **not** inside it; committed frames have *no* metric that
  attributes the animation walk (elided frames log
  `elided_animation_tick_ms` only). Any resolve probe must instrument inside
  `evaluateDirtyNodes` *and* separately time the head-phase walks.
- The archived commit-breakdown probe
  (`docs/perf/commit-ms-breakdown-probe/probe.patch`) **no longer applies** at
  HEAD (`git apply --check` fails); it needs a rebase over the 06-02/03
  retained-reuse + diagnostics batch before reuse.

### 3.6 First-principles violations, ranked

For a localized interaction frame the floor is O(changed subtree) — flat in
tree size. Recompute is at that floor, yet every phase except raster/draw
still ~doubles from rows 20→40. The slope is pure bookkeeping: ≥8 distinct
full-tree walks per frame remain —

1. **O(tree) per-frame bookkeeping despite flat recompute** (largest aggregate
   excess, ~10–15× above floor): graph checkpoints ×2
   (`ViewGraphCheckpointing.swift:3-11`), `processResolvedTree`
   (`AnimationController.swift:520-557`), 3+ phase/topology signatures per tail
   (`FrameTailModels.swift:30`, `FrameTailRetainedState.swift:97-122`,
   `FrameTailPresentationDamage.swift:28,65-66`), `RetainedFrameIndex` full
   rebuild ×3 trees (`RetainedFrameQueries.swift:79-107`), deep equivalence
   walks over *reused* subtrees (`ResolvedNodeEquivalence.swift`), semantics
   full walk, `observationBridge.prune` O(graph)
   (`RunLoop+Rendering.swift:170-172`).
2. **Sheet settle frames** — O(tree) for an O(2-leaf) focus move (§3.4).
3. **Transition-frame measure + commit** — measure 26–27% is O(tree)
   equivalence validation of a reused background; commit 4× settle (§3.3).
4. **Semantics ignores its own subtree proof** — full-tree extraction whenever
   anything changed (`Semantics.swift:173-176`); 10–12% of narrow pipeline.
   Draw consumes the same `subtreesIdentical` proof and costs only ~4%.
5. **Animation frames degrade to frame-wide `suppressRetainedReuse`** O(tree)
   (`RunLoop+Rendering.swift:416-419`) — floor is O(animated nodes).

Non-violations to leave alone: idle, off-screen elision, terminal emission
(≤0.08 ms/frame, 100% incremental per the 05-28 kitty check), commit's scoped
restore, draw-proof reuse. Raster (0.723 ms, flat) is the **#2 phase at small
trees** — part floor (visible-cell diff), part reducible.

## 4. Ranked next steps

Each verified against code at `bc63495a` (not already done; premise holds;
blockers listed).

1. **Publish the merged work** — push `swift-tui` main **first**, then the org
   root (the root pins `bc63495a`, which exists on no remote branch; reverse
   order publishes a root referencing an unfetchable child commit; all other
   submodule pins are already on their origins). Then make the 0.0.20 release
   decision separately. The Linux Repo Gate still carries the swift-tui#12
   run-loop SEGV flake — do not mistake a crash there for a regression.
2. **Resolve diagnosis: in-frame breakdown probe + 0.0.19 regression triage.**
   Bisect/A-B the 0.0.19 window for the +73/+91% regression and land (or
   archive) a resolve-phase probe honoring §3.5. *Gates* candidates 8–10
   below — the workstream's history (commit_ms hypothesis wrong; Fix 1 and
   Candidate A no-ops) shows unsized attempts here have a ~50% no-op rate.
3. **Part 0 — fix the latent divergent-identity orphaning bug.** A
   capture-hosted scene root whose `resolvedIdentity` diverges from its
   structural identity can be wrongly retained-reused on scroll frames, today
   rescued only incidentally by the `isFocused` cone-bake. Fix directions: A0
   — extend `scrollPointerInvalidationIdentities`
   (`RunLoop+PointerHandling.swift:308-324`) with the resolved-identity
   ancestor chain; B0 — a reuse-host guard in `reusableSnapshot`
   (`ViewGraph.swift:1102-1160`). Hot reuse path: own perf-validated PR;
   guards = the three `InteractiveRuntimeTests` scroll cases passing *with*
   `IsFocusedKey` still in the snapshot, H2/H3 perf suites, full gate under
   load. Note the in-code warning at `ViewGraph.swift:1131-1142` recording the
   794fbf3e/7044ce13 revert — the identity-axis conflict scan is not
   redundant.
4. **Cheap calibration: de-amplified sheet scenario variant.** The perf
   scenario co-locates the toggle Button in the background container, which
   amplifies the settle residual; a variant with the toggle outside calibrates
   Part A's real-world payoff before paying its validation cost. (The existing
   `TERMUI_PERF_SHEET_SPIKE` is *not* this — it bypasses `.sheet` entirely.)
5. **Part A — exclude `IsFocusedKey` from the reuse snapshot** + map
   `\.isFocused` → `FocusedIdentityKey` in `runtimeFocusStateDependencyKey`
   (`StyleEnvironment.swift:99-109`). Targets §3.4. **Hard-gated on Part 0**
   (mandatory sequencing per the 2026-06-10 decision). Part B (edit
   FocusTracker) stays retired; Lever #3 stays a non-starter.
6. **Transition-frame commit_ms diagnosis** — rebase the archived probe
   (§3.5) and run it on the sheet scenario. If a registration-style pathology
   dominates, a Fix-2-class win (−80%+) may exist on the 15–16% transition
   commit share; this is also the *only* sanctioned revisit-condition for the
   G3a/G11 index-patcher deferral.
7. **Popover presentation-trigger split (complete Lever B).** All three
   popover modifiers still read `isPresented`/`item` at the background
   identity (`PopoverPresentation.swift:80/131/193`). Mechanical application
   of the sheet pattern + a popover perf scenario + write-side
   ReaderAttributionTests cases. Caution: unlike the sheet split (landed dark,
   flag-off byte-identical), this lands directly on the flag-ON default path.

**Sized-by-probe (do not start before step 2/6 sizing):** scope
`processResolvedTree` to changed subtrees; reduce checkpoint cost (×2 O(tree)
per abortable frame — sheet runs show 7–8 cancelled frames per 18 committed,
so the abort path is hot); O2 ordered semantic fragments (template:
`normalizeScopedRestoreOrder` byte-identity pattern); phase-proof signature
consolidation; O4 retained layout validation (measure_ms); raster residuals
(O3 — best parallel-track candidate, dominant at small trees); animation
identity-scoped suppression (needs the animation-teleport `ViewNodeID` re-key
first — the unlanded Stage-4 G5 half, `AnimationController.swift:1240`).

**Leave deferred (re-affirmed):** G3a/G11 index patcher (unless step 6
reverses it), H1 wakeup coalescing (0 elided frames in the entire live corpus;
the affected state is not exercised), resolve win (ii)
`structuralInvalidationIntersects` reduction, O6 elision residuals.

## 5. Gaps register (deliberate decisions wanted, not silence)

- **Profiling product** ([plans/2026-05-28-001-profiling-product.md](2026-05-28-001-profiling-product.md))
  was never built; the workstream keeps re-applying archived probe patches
  instead of owning a productized seam. Mid-rank infra candidate.
- **Memory has no occupancy budget** while H2/H3 retained reuse, presence
  carry-forward, and the retained index all *grow* retained state. At minimum
  an explicit "not now".
- **No real-terminal validation**: every win including reader-attribution's
  −9% p95 is headless-harness-measured; the kitty Route B remains deferred.
- **Body re-evaluation cost** is attacked by nothing on the list (reader
  attribution narrows *which* nodes invalidate; invalidated nodes still re-run
  full bodies). VISION-GAP carries it as design-only.
- **Command-palette open proposal** is likely superseded by reader-attribution
  (same mechanism: root `@State` toggle) — verify and mark, don't re-solve.
- Doc nit: `PresentationTriggerLeaf.swift:53` still labels the flag-off path
  "(default)".

## 6. References

- Reports: [2026-06-09-sheet-open-latency-investigation.md](../reports/2026-06-09-sheet-open-latency-investigation.md),
  [2026-06-09-lever-b-implementation-and-findings.md](../reports/2026-06-09-lever-b-implementation-and-findings.md),
  [2026-05-31-place-ms-identical-subtree-sync-skip-results.md](../reports/2026-05-31-place-ms-identical-subtree-sync-skip-results.md),
  [2026-05-31-commit-ms-registration-restore-fix-results.md](../reports/2026-05-31-commit-ms-registration-restore-fix-results.md),
  [2026-06-04-resolve-ms-win-ii-and-g3a-deferral-measurement.md](../reports/2026-06-04-resolve-ms-win-ii-and-g3a-deferral-measurement.md),
  [2026-05-28-gallery-performance-report.md](../reports/2026-05-28-gallery-performance-report.md)
- Proposal stack: [2026-06-02-002-rendering-performance-next-wave-proposal.md](2026-06-02-002-rendering-performance-next-wave-proposal.md),
  [2026-06-02-003-rendering-performance-remaining-opportunities-proposal.md](2026-06-02-003-rendering-performance-remaining-opportunities-proposal.md),
  structural-identity set ([2026-06-03-001](2026-06-03-001-first-class-structural-identity-proposal.md) ff.)
- Sheet plan: [2026-06-09-001-sheet-open-reader-attribution-plan.md](2026-06-09-001-sheet-open-reader-attribution-plan.md)
