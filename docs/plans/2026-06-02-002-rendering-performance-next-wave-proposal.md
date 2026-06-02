# Perf - Rendering Performance Next-Wave Proposal

**Date:** 2026-06-02
**Status:** Implemented for P0, P1, the draw-reuse slice of P2, and the
metric-flush slice of P4. P3 and semantic fragment reuse remain deferred.
**Scope:** `swift-tui` frame-head elision, frame-tail retained reuse,
incremental rasterization, retained indexes, and TermUIPerf infrastructure.
**Baseline:** org root on `main`, child repos pinned to `0.0.10`.
**Original proposal artifacts:** local, uncommitted measurements under
`/tmp/swifttui-perf-0.0.10`.
**Post-implementation artifacts:** local, uncommitted measurements under
`/tmp/swifttui-perf-candidate-final`.
**Predecessor:**
[`2026-06-02-001-rendering-performance-optimization-proposal.md`](2026-06-02-001-rendering-performance-optimization-proposal.md).

---

## Executive Summary

The first rendering-infrastructure wave has landed at `0.0.10`: resolve reuse is
working, commit-side runtime-registration restore has been scoped, retained
placement has placed-frame table carry-forward, whole-tree retained semantics
and draw reuse exists, TermUIPerf summaries expose elided frames, and host damage
metrics are more honest.

The next highest-impact work is therefore not another broad pass over
`resolve`. Fresh data shows two remaining classes of cost:

1. **Hidden elided-frame CPU.** Off-screen animation now elides most deadline
   ticks, but the elided path still consumes significant CPU and lacks phase
   attribution.
2. **Frame-tail full-product validation.** Narrow input frames reuse the static
   tree during resolve, but still pay size-scaling work in measure, place,
   semantics, draw, raster, worker compute, and main-actor suspension.

Recommended order:

1. Add micro-spans for elided/abortable frame-head cost.
2. Make incremental rasterization trust sound damage in production.
3. Make retained semantics and draw extraction subtree-granular.
4. Persist retained indexes with subtree replacement instead of full rebuilds.
5. Reduce retained layout validation and `LayoutPassContext` overhead.
6. Treat visible animation cadence and text churn as lower-priority product
   policy, not the next runtime hotspot.

## Current State After Implementation

The working tree now reflects the accepted parts of this proposal:

- **P0 landed.** Elided diagnostic rows now carry named micro-spans in
  `frames.tsv` and TermUIPerf summaries, including graph checkpoint
  create/restore, resolve checkpoint restore, animation tick/commit, runtime
  registration commit, and elided commit timings. The main optimization is a
  pre-frame-head fast path for off-screen property-animation deadline ticks:
  when the animation controller can prove all redraw identities are off-screen
  and there is no active frame-head transaction, transition/removal work, or
  pending empty-batch completion, it advances live animation state and finite
  completions without preparing a full abortable frame head.
- **P1 landed.** `Rasterizer` now chooses an
  `IncrementalRasterVerificationPolicy`: debug builds verify sound incremental
  damage, release builds trust it by default, and
  `SWIFTTUI_RASTER_VERIFY_INCREMENTAL` /
  `SWIFTTUI_RASTER_TRUST_SOUND_DAMAGE` can force either behavior. The frame
  tail now consumes the rasterizer's presentation damage directly when present,
  avoiding a final full-surface diff in the trusted/verified incremental path.
- **P2 partially landed.** `RetainedPhaseExtractionProof` supports
  `.subtreesIdentical(Set<Identity>)`, retained frame-tail state indexes draw
  nodes by identity, and draw extraction can reuse previous clean draw subtrees
  when inherited background/border context does not make reuse unsound. Semantic
  fragment reuse did not land because semantic append order is observable for
  focus traversal, pointer hit testing, accessibility ordering, and live-region
  behavior.
- **P3 did not land.** A retained-index incremental constructor spike exposed
  structural identity hazards around `.id`, duplicate identities, presentation
  portals, and root identity paths. `RetainedFrameIndex` still rebuilds full
  maps after commit.
- **P4 partially landed.** Measurement and placement work-stack metrics now
  accumulate in local `LayoutWorkMetrics` and flush once into
  `LayoutPassContext`, reducing mutex churn. Retained layout validation, layout
  hashing, and proposal-specific measurement caching remain open.

Updated short-run measurements under `/tmp/swifttui-perf-candidate-final` show:

| Scenario | Iterations | Total CPU median | Frames | Main signal |
| --- | ---: | ---: | ---: | --- |
| `synthetic-offscreen-phase-animator` async | 3 | 0.275s | 9 committed / 136 diagnostic / 127 elided median | P0 removed most hidden elided-head CPU; elided animation tick p50 is 0.01 ms. |
| `synthetic-narrow-invalidation`, rows=40 async | 3 | 0.206s | 18 committed / 18 diagnostic median | CPU/frame is 11.44 ms; frame-tail phase slopes are still the main remaining cost. |

Rows=40 repeated input frames still show median phase/work numbers of roughly
`measure=1.09ms`, `place=0.55ms`, `semantics=0.73ms`, `draw=0.25ms`,
`raster=0.63ms`, `pipeline=4.29ms`, `worker_layout_compute=1.61ms`, and
`worker_raster_compute=2.26ms`. Those are only modestly better than the baseline
below, so the remaining opportunities are mostly deeper retained-product,
structural-index, raster, and layout-validation work rather than another
off-screen elision pass.

Validation completed for the implementation:

```bash
swiftly run swift test --package-path swift-tui --filter AsyncFrameTailRenderingTests
swiftly run swift test --package-path swift-tui --filter OffscreenFrameElisionRuntimeTests
swiftly run swift test --package-path swift-tui --filter RetainedPhaseExtractionTests
swiftly run swift test --package-path swift-tui --filter RasterizerTests
swiftly run swift test --package-path swift-tui --filter LayoutEngineTests
swiftly run swift test --package-path swift-tui --filter SurfaceDamageContractTests
swiftly run swift test --package-path swift-tui --filter PipelineContractTests
swiftly run swift test --package-path swift-tui/Tools/TermUIPerf
swiftly run swift package --package-path swift-tui/Tools/TermUIPerf \
  show-dependencies --disable-automatic-resolution
git -C swift-tui diff --check
```

Validation caveat: full-package `swiftly run swift test --package-path swift-tui`
and a `--no-parallel` rerun both crashed `swiftpm-testing-helper` with signal 11
before reporting a failing assertion. Treat that as a separate validation gap,
not as proof of a runtime assertion failure in this performance patch.

## Infrastructure Check

The root checkout was clean, and all submodules described exactly to `0.0.10`:

```text
swift-tui          0.0.10-0-g96ee6ab9
swift-tui-examples 0.0.10-0-g8727272
swift-tui-site     0.0.10-0-g83e9ad6
swift-tui-web      0.0.10-0-g1490947
```

TermUIPerf is the best committed measurement path today. The available scenarios
are:

```text
gallery-animation-click
layout-scroll-burst
synthetic-continuous-animation
synthetic-narrow-invalidation
synthetic-offscreen-phase-animator
synthetic-text-shimmer
```

Verification:

```bash
swiftly run swift test --package-path swift-tui/Tools/TermUIPerf
```

Result: **50 tests passed**.

Infrastructure issues found:

- `swift-tui/Tools/TermUIPerf/.build` contained a SwiftPM module cache from a
  different checkout path. `swift package clean` fixed the harness.
- Running two SwiftPM commands against the same `.build` caused lock contention.
  Perf runs should stay sequential or use separate build paths.
- Initial SwiftPM resolution updated `Tools/TermUIPerf/Package.resolved`; it was
  restored, and subsequent commands used `--disable-automatic-resolution`.
- The historical real-gallery overlay path was not durable when it depended on a
  fixed local `git stash@{0}`. `docs/perf/README.md` now treats full-gallery
  measurement as an overlay reconstruction path from the baseline report, and
  keeps the committed framework-only scenarios as the everyday path.

Effective dependency graph after restore:

```text
swift-collections       1.4.1
swift-async-algorithms  1.1.3
swift-argument-parser   1.7.1
SwiftTerm               1.13.0
FlyingFox               0.26.2
```

## Data Collection

Primary command shape:

```bash
swiftly run swift run --disable-automatic-resolution \
  --package-path swift-tui/Tools/TermUIPerf \
  -c release termui-perf run \
  --scenario synthetic-narrow-invalidation \
  --modes async \
  --iterations 20 \
  --configuration release \
  --artifacts-root /tmp/swifttui-perf-0.0.10/narrow-r40
```

Tree-size sweep:

```bash
TERMUI_PERF_INVALIDATION_TREE_ROWS=6  ... --artifacts-root /tmp/swifttui-perf-0.0.10/narrow-r6
TERMUI_PERF_INVALIDATION_TREE_ROWS=20 ... --artifacts-root /tmp/swifttui-perf-0.0.10/narrow-r20
TERMUI_PERF_INVALIDATION_TREE_ROWS=40 ... --artifacts-root /tmp/swifttui-perf-0.0.10/narrow-r40
```

Additional scenarios:

```bash
swiftly run swift run --disable-automatic-resolution \
  --package-path swift-tui/Tools/TermUIPerf \
  -c release termui-perf run \
  --scenario synthetic-offscreen-phase-animator \
  --modes async --iterations 5 --configuration release \
  --artifacts-root /tmp/swifttui-perf-0.0.10/offscreen-phase

swiftly run swift run --disable-automatic-resolution \
  --package-path swift-tui/Tools/TermUIPerf \
  -c release termui-perf run \
  --scenario synthetic-continuous-animation \
  --modes async --iterations 5 --configuration release \
  --artifacts-root /tmp/swifttui-perf-0.0.10/continuous-animation

swiftly run swift run --disable-automatic-resolution \
  --package-path swift-tui/Tools/TermUIPerf \
  -c release termui-perf run \
  --scenario synthetic-text-shimmer \
  --modes async --iterations 5 --configuration release \
  --artifacts-root /tmp/swifttui-perf-0.0.10/text-shimmer

swiftly run swift run --disable-automatic-resolution \
  --package-path swift-tui/Tools/TermUIPerf \
  -c release termui-perf run \
  --scenario gallery-animation-click \
  --modes async --iterations 10 --configuration release \
  --artifacts-root /tmp/swifttui-perf-0.0.10/gallery-animation-click

swiftly run swift run --disable-automatic-resolution \
  --package-path swift-tui/Tools/TermUIPerf \
  -c release termui-perf run \
  --scenario layout-scroll-burst \
  --modes async --iterations 10 --configuration release \
  --artifacts-root /tmp/swifttui-perf-0.0.10/layout-scroll-burst
```

## Fresh Measurements

### Narrow Invalidation Scaling

The table below excludes cold/full frame 1 and uses only repeated
`input+invalidation` frames.

| Rows | Nodes | `resolved_computed` | `resolved_reused` | `measure_ms` | `place_ms` | `semantics_ms` | `draw_ms` | `raster_ms` | `pipeline_ms` | CPU/frame |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 6 | 67 | 17 | 54 | 0.23 | 0.13 | 0.14 | 0.04 | 0.36 | 1.45 | 4.33 ms |
| 20 | 193 | 17 | 180 | 0.82 | 0.38 | 0.46 | 0.16 | 0.73 | 3.48 | 8.55 ms |
| 40 | 373 | 17 | 360 | 1.18 | 0.57 | 0.73 | 0.26 | 0.67 | 4.58 | 11.67 ms |

Interpretation:

- Resolve reuse is working: recomputed nodes stay flat at 17.
- The residual is frame-tail work that still scales with retained tree size.
- On rows=40 async input frames, median worker timings were:
  - layout compute: 1.76 ms;
  - raster compute: 2.33 ms;
  - main actor blocked: 1.13 ms;
  - main actor suspended: 4.31 ms.

### Sync vs Async Check

Rows=40, repeated input frames:

| Mode | CPU/frame | `pipeline_ms` | `commit_ms` | main actor blocked | p95 input latency |
| --- | ---: | ---: | ---: | ---: | ---: |
| async | 11.67 ms | 4.58 | 0.17 | 1.13 | 164 ms |
| sync | 10.50 ms | 7.20 | 2.64 | 7.20 | 223 ms |

Interpretation:

- Sync has slightly lower CPU/frame but much worse latency and more committed
  frames.
- The answer is not to revert to inline rendering.
- The target is reducing async tail work, worker compute, and suspension cost.

### Animation and Text Scenarios

| Scenario | Committed frames | Diagnostic frames | Elided frames | Total CPU | CPU/frame |
| --- | ---: | ---: | ---: | ---: | ---: |
| `synthetic-offscreen-phase-animator` | 10 | 137 | 127 | 0.636s | 64.7 ms committed / 4.68 ms diagnostic |
| `synthetic-continuous-animation` | 75 | 75 | 0 | 0.339s | 4.46 ms |
| `synthetic-text-shimmer` | 102 | 102 | 0 | 0.396s | 3.88 ms |
| `gallery-animation-click` | 44 | 44 | 0 | 0.230s | 5.16 ms |
| `layout-scroll-burst` | 2 | 2 | 0 | 0.0137s | 6.83 ms |

Interpretation:

- Off-screen animation elision fixed the historical committed zero-damage frame
  storm, but the elided path still burns meaningful CPU.
- Visible continuous animation and text shimmer are bounded and lower-priority
  than the hidden elided-path cost.
- Layout scroll burst is not a hotspot in the current committed synthetic
  harness.

### Memory

No memory provider was flagged as a leak suspect.

Important details:

- `synthetic-text-shimmer` drives `TextLayoutCache.entries` to 256, then
  plateaus.
- `synthetic-offscreen-phase-animator` keeps `ViewGraph.nodesByIdentity`,
  `MeasurementCache.entriesByIdentity`, `TextLayoutCache.entries`, and
  `RetainedFrameIndex.placedByIdentity` flat.

## Source Investigation

### Elided Frames Lack Attribution

The off-screen run produced many rows like:

```text
elided=1 causes=deadline drop_blockers=- drop_decision=- tail=-
```

These rows carry no phase timings, but process CPU is high. The source shows why
this path can still do meaningful work before the tail is skipped:

- abortable heads create graph checkpoints in
  `DefaultRendererFrameHeadCoordinator.computeFrameHead`;
- checkpointing walks every graph node in
  `ViewGraphNodeCheckpointing.makeNodeCheckpoints`;
- elided frames still materialize prepared state and commit draft effects.

Relevant files:

- `swift-tui/Sources/SwiftTUIRuntime/Rendering/DefaultRendererFrameHeadCoordinator.swift`
- `swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameHeadDraftTransaction.swift`
- `swift-tui/Sources/SwiftTUICore/Resolve/ViewGraphCheckpointing.swift`

### Raster Reuse Still Performs Full Validation

`Rasterizer.rasterizeIncrementallyCollectingVisibleIdentities` currently:

1. copies `previousSurface.cells`;
2. clears and repaints dirty rows;
3. fresh-rasterizes the whole draw tree to verify the incremental output;
4. returns refined damage.

Then `FrameTailInlineStageRenderer.rasterizeDrawTree` computes
`RasterSurfaceDamageDiff.diff(previous:current:)`, a full previous/current
surface diff.

Relevant files:

- `swift-tui/Sources/SwiftTUICore/Raster/Rasterizer.swift`
- `swift-tui/Sources/SwiftTUICore/Raster/RasterSurfaceDamageDiff.swift`
- `swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailRenderer+InlineStages.swift`

### Retained Semantics/Draw Reuse Is Whole-Tree Only

`FrameTailRetainedInput.phaseExtractionProof` returns `.wholeTreeIdentical` only
when the current placed-tree signature equals the previous full-tree signature.
Any small changed subtree causes semantics and draw extraction to walk the whole
placed tree.

Relevant files:

- `swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailModels.swift`
- `swift-tui/Sources/SwiftTUICore/Commit/RetainedPhaseExtraction.swift`
- `swift-tui/Sources/SwiftTUICore/Semantics/Semantics.swift`
- `swift-tui/Sources/SwiftTUICore/Draw/DrawExtractor.swift`

### Retained Indexes Are Rebuilt As Full Maps

`RetainedFrameIndex.init(frame:)` rebuilds resolved, measured, and placed maps
for every committed frame. That is acceptable today, but it becomes a structural
ceiling after subtree-granular reuse starts carrying more frame-tail products
forward.

Relevant file:

- `swift-tui/Sources/SwiftTUICore/Commit/RetainedFrameQueries.swift`

## Ranked Proposals

### P0 - Instrument and Reduce Elided-Frame Head Cost

**Why first:** This is the highest fresh CPU surprise. Off-screen animation now
elides 127 of 137 diagnostic rows, but the run still uses 0.636 CPU-s over the
short observation window. Existing phase timings do not explain it.

**Proposal:**

- Add micro-spans for:
  - graph checkpoint creation;
  - graph checkpoint restore/materialize;
  - `FrameResolveState` and `FrameResolveInputBox` checkpoint restore;
  - animation draft tick and commit;
  - `commitElidedFrame`;
  - `ViewGraphFrameDraft.commitRuntimeRegistrations` on elided frames.
- Add TermUIPerf summary fields for elided-frame CPU attribution once spans
  exist.
- After measurement, consider a breaking internal redesign:
  - represent animation-deadline advancement as a small transaction that can
    commit animation state and completion callbacks without preparing a full
    abortable frame head when visibility proof says no tail can be needed.

**Risks:**

- Animation completion callbacks and transition bookkeeping are correctness
  sensitive.
- The existing elision path deliberately commits draft effects; bypassing that
  needs tests for completions, observation, portal state, and runtime
  registrations.

**Acceptance:**

- `synthetic-offscreen-phase-animator` explains at least 90% of its CPU through
  named spans.
- A candidate fix lowers total CPU by at least 30% for the scenario without
  changing committed/elided counts or completion behavior.

### P1 - Trust Sound Incremental Raster Damage in Production

**Why now:** Narrow invalidation changes one visible cell, but rows=40 still pays
0.67 ms median `raster_ms`, 2.33 ms worker raster compute, and the source shows
both a fresh verification raster and a final full diff.

**Proposal:**

- Add an env-gated probe that:
  - skips `freshRasterizationIfIncrementalMismatch` when damage is proven by
    `FrameTailPresentationDamageResolver`;
  - returns the refined or resolver damage directly when safe, skipping
    `RasterSurfaceDamageDiff.diff`;
  - keeps full verification in debug/profile/sampled modes.
- If the probe is clean, make verification opt-in rather than unconditional for
  production release builds.

**Risks:**

- Incomplete damage proofs produce stale cells.
- Image attachments and graphics replay are already handled as barriers; tests
  must prove they remain barriers.

**Acceptance:**

- Add A/B tests where forced bad damage still falls back under debug
  verification.
- On `synthetic-narrow-invalidation` rows=40, reduce `raster_ms` and worker
  raster compute materially while keeping `damage_cells` and host output
  byte-identical.

### P2 - Add Subtree-Granular Retained Semantics and Draw Extraction

**Why now:** Rows=40 input frames reuse 360 resolved nodes but still pay
0.73 ms semantics and 0.26 ms draw. The current retained extraction proof is
whole-tree only, so one small state change invalidates semantic/draw reuse for
hundreds of stable siblings.

**Proposal:**

- Replace `RetainedPhaseExtractionProof.wholeTreeIdentical` with subtree
  fragments keyed by identity plus projection signatures.
- Cache semantic fragments and draw fragments for retained subtrees.
- Merge fragments with recomputed dirty roots, preserving:
  - hit-test order;
  - focus candidate order;
  - accessibility node order;
  - background/overlay draw ordering;
  - transient animation overlay behavior.

**Breaking option:**

- Move semantic and draw products toward persistent identity-keyed structures
  instead of rebuilding append-ordered arrays and trees every frame.

**Risks:**

- Ordering is observable for focus traversal, pointer hit testing, and draw
  stacking.
- Canvas/custom layout/foreign surface exclusions must remain conservative.

**Acceptance:**

- A full-extract vs fragment-merge equivalence suite for mixed changed/unchanged
  trees.
- Rows=40 narrow invalidation shows lower `semantics_ms`, `draw_ms`, and worker
  raster input cost.

### P3 - Persist Retained Indexes With Changed-Subtree Replacement

**Why now:** `RetainedFrameIndex` rebuilds full identity maps each committed
frame. This is not the largest current number by itself, but subtree-granular
retained phases will need persistent indexes to avoid moving O(tree) work from
extractors into index construction.

**Proposal:**

- Store persistent resolved/measured/placed/phase indexes.
- Replace only changed roots after commit.
- Carry forward placed-frame fragments and phase fragments together.
- Add debug assertions comparing persistent indexes to full rebuilt indexes.

**Risks:**

- Removed subtrees must be pruned exactly.
- Identity aliasing and presentation portal roots need explicit coverage.

**Acceptance:**

- Persistent index snapshots compare equal to full rebuilds under insertion,
  deletion, reorder, focus move, animation overlay, portal, and scroll cases.
- Rows=40 startup may remain O(tree), but repeated input frames should not
  rebuild whole indexes.

### P4 - Reduce Retained Layout Validation and Pass-Context Overhead

**Why now:** Measurement and placement still scale with rows despite reuse:
rows=6 to rows=40 input frames moved `measure_ms` 0.23 -> 1.18 and `place_ms`
0.13 -> 0.57.

**Proposal:**

- Add structural/layout hashes to `ResolvedNode`/`MeasuredNode` equivalents so
  retained-measurement and retained-placement gates can avoid deep validation
  walks for unchanged subtrees.
- Replace lock-heavy `LayoutPassContext` paths with worker-local mutation for
  off-main passes, merging only the final metrics/cache updates.
- Add stack-specific proposal classification to avoid predictable repeat
  measurements for fixed proposals.

**Risks:**

- Hash invalidation bugs are subtle and can produce wrong layout reuse.
- Custom layout compatibility and layout-dependent content must stay
  conservative.

**Acceptance:**

- Rows=40 narrow invalidation reduces `measure_ms`, `place_ms`, and layout
  worker compute without changing layout snapshots.
- Hash/debug mode can assert hash-equivalent reuse equals deep-equivalence reuse.

### P5 - Keep Visible Animation Cadence and Text Churn Lower Priority

**Why not now:** Fresh runs do not show these as the largest remaining runtime
costs. Text shimmer plateaus at the cache cap, and visible animation CPU/frame is
lower than the hidden off-screen elision path.

**Proposal:**

- Do not silently reduce visible animation cadence in the runtime.
- Keep the existing text cache admission behavior.
- Revisit explicit authored cadence policy only if product requirements call for
  decorative/low-priority animation throttling.

## Execution Plan

1. Land P0 instrumentation only.
   - Keep it env-gated or diagnostics-only.
   - Re-run `synthetic-offscreen-phase-animator`.
   - Decide whether the elided CPU is checkpoint, graph, animation, commit, or
     diagnostics overhead.
2. Spike P1 behind an env gate.
   - Run rows=6/20/40 `synthetic-narrow-invalidation`.
   - Add forced-bad-damage tests before considering a production behavior change.
3. Design P2 with equivalence tests first.
   - Do semantics and draw fragments together only if ordering proofs are shared;
     otherwise split semantics first.
4. Add persistent retained indexes only after P2 proves fragment reuse needs
   index carry-forward.
5. Attack P4 layout validation once raster and semantic/draw residuals are
   lower or instrumentation proves layout is the dominant remaining slope.

## Validation Matrix

Minimum infrastructure checks:

```bash
swiftly run swift package --package-path swift-tui/Tools/TermUIPerf \
  show-dependencies --disable-automatic-resolution

swiftly run swift test --package-path swift-tui/Tools/TermUIPerf

git -C swift-tui diff --check
```

Minimum perf sweeps:

```bash
for rows in 6 20 40; do
  TERMUI_PERF_INVALIDATION_TREE_ROWS=$rows \
  swiftly run swift run --disable-automatic-resolution \
    --package-path swift-tui/Tools/TermUIPerf \
    -c release termui-perf run \
    --scenario synthetic-narrow-invalidation \
    --modes async \
    --iterations 20 \
    --configuration release \
    --artifacts-root "/tmp/swifttui-perf-candidate/narrow-r$rows"
done

swiftly run swift run --disable-automatic-resolution \
  --package-path swift-tui/Tools/TermUIPerf \
  -c release termui-perf run \
  --scenario synthetic-offscreen-phase-animator \
  --modes async \
  --iterations 5 \
  --configuration release \
  --artifacts-root /tmp/swifttui-perf-candidate/offscreen-phase
```

Focused correctness suites should include:

- focus traversal and focus-state writeback;
- pointer/gesture routing;
- scroll geometry and named coordinate spaces;
- animation completion and transition tests;
- raster damage and dirty-row tests;
- WASI/WebHost damage tests if raster behavior changes.

## Non-Goals

- Reverting async rendering to sync rendering.
- Optimizing visible animation cadence without explicit authored policy.
- Treating a fixed local real-gallery stash reference as current measurement
  infrastructure.
- Replacing the phase-product model wholesale before measuring the smaller
  retained-product and raster-trust changes.
