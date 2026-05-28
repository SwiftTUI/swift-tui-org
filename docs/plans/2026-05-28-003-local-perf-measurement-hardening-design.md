# Local Performance-Measurement Hardening — Design

**Status:** design (approved; awaiting spec review before an implementation plan).
**Date:** 2026-05-28
**Related:**
- Baseline that motivated this: [`docs/reports/2026-05-28-gallery-performance-report.md`](../reports/2026-05-28-gallery-performance-report.md)
- Measurement substrate: [`docs/plans/2026-05-28-001-profiling-product.md`](2026-05-28-001-profiling-product.md) (the `SwiftTUIProfiling` product, now shipped)
- Workload source: [`docs/plans/2026-05-28-002-gallery-performance-data-collection-plan.md`](2026-05-28-002-gallery-performance-data-collection-plan.md)

---

## Summary

The 2026-05-28 gallery performance report is a strong baseline, but it carries
measurement caveats that block the *next* step — proving an optimization
actually helped. The numbers are **n = 1**, the summary reducer reports no
**run-to-run variance**, the profiler **perturbs the frame-drop decision it
measures**, and the exact 18-tab workload that produced the report **is not
reproducible from a clean checkout**.

This effort hardens the **local** measurement setup (no CI gate, by decision) so
that a before/after comparison on a real change is trustworthy. It is four
phases, sequenced so each is validated by the one before it:

1. **G2 — run-to-run variance** (harness only)
2. **G3 — de-perturb frame counts** (runtime; zero behavior change)
3. **G1 — reproducible gallery baseline** (committed synthetic scenarios + overlay path)
4. **G4 — memory-signal completeness** (occupancy providers + harness)

## Goals

- A local run reports **variance**, so a delta can be judged signal vs. noise.
- `CompareCommand` emits a **significance verdict**, not just a raw delta.
- Frame counts can be read as a **shipping-build** count, free of the profiler's
  own inflation.
- The gallery hot-spots are **reproducible**: a fast committed path for everyday
  runs and a faithful overlay path for the full 18-tab baseline.
- The **memory signal** is as trustworthy as the frame/CPU signals (byte weight
  where cheap, comparable windows, automatic leak-slope detection).

## Non-goals

- **No CI/regression gate** this phase (explicit steering). The work is for
  interactive local runs; a gate can be layered later on top of G2's variance.
- **No optimization work.** This hardens the ability to *measure* H1/H2/H3; it
  does not fix them.
- **No change to what the frame diagnostics measure** beyond the one additive
  G3 field. Field parity with the current record is preserved.
- **No gallery path-dependency in any public child manifest** (see Cross-repo
  discipline).

## Background — what exists, and the four trust gaps

What already exists (and is reused, not rebuilt):

- **`SwiftTUIProfiling`** is a shipped, optional product: `.profiling()`
  modifier, `SWIFTTUI_PROFILE` env parser, TSV/file/handler/summary sinks, CPU
  sampler, memory collector (`MemoryMetricProvider`/`MemoryMetricRegistry`),
  progress log.
- **`Tools/TermUIPerf`** supports `--iterations` (default **20**), per-frame
  percentile distributions (`PerfDistribution`: p50/p95/p99), CPU seconds, drop
  counts, and a `CompareCommand` that computes baseline-vs-candidate p95 deltas.
- **`PerfMemorySampler`** polls `ProfiledMemory.snapshot()` every 500 ms.

The gaps this design closes:

- **G1 — workload not reproducible.** The scenarios that hosted the real 18-tab
  `GalleryView` (`GalleryTabScenario`, `CommandPaletteScenario`) are *not*
  committed; they carry a path-dep on the gallery package that cannot land in
  the public `swift-tui` manifest. Only `GalleryAnimationClickScenario` and
  `LayoutScrollBurstScenario` are committed.
- **G2 — no run-to-run variance, and iterations don't even run.** `runWindow`
  executes each scenario **exactly once**; `--iterations` (default 20) is stamped
  into `PerfRunMetadata.iterationCount` as a label but drives **no repetition**
  (verified: `RunCommand` calls `scenario.run` once per mode; the scenario calls
  `runWindow` once; there is no loop). `SummaryReducer.reduce` pools the *frames
  within that single run* into one `PerfDistribution` (robust percentile tails),
  but there is no run-to-run sample at all — so a summary metric like
  `total_cpu_seconds` has no variance and a delta cannot be judged against noise.
  The report's "n = 1" was therefore not a sampling choice; the harness cannot
  yet do n > 1.
- **G3 — profiler perturbation.** `diagnosticsRequireFullRecord` →
  `.diagnosticsFullRecord` is inserted into the blocker set in
  `RunLoop+FrameDropBlockerDerivation.swift:40-42`, forcing a commit. Profiling
  therefore inflates the committed-frame count vs. a shipping build. It is
  *additive* on top of the genuine animation blockers, so it does not explain
  the whole H1 count — only the profiler's own contribution.
- **G4 — memory signal thinner than frame/CPU.** Byte weight is best-effort and
  absent for most providers; the idle-window/sample interval was ad-hoc (5/10/20
  s across runs); the leak signal (monotonic count with no plateau) was
  eyeballed, not computed.

## Phase sequencing & rationale

`G2 → G3 → G1 → G4`. Each phase is validated by the prior one:

- **G2 first** because it is pure harness work with zero runtime risk and is the
  foundation: until "this delta exceeds the noise band" is answerable, no later
  phase can be *validated*.
- **G3 second** because, with variance in hand, the de-perturbed counts can be
  shown stable across runs before anyone trusts them.
- **G1 third** because the harness hardening (G2/G3) can be developed and tested
  against the already-committed synthetic scenarios; G1 is what lets the hardened
  tooling re-run the *real* 18-tab workload.
- **G4 last** because it is largely independent and benefits from G2's
  variance machinery for its slope/plateau reporting.

---

## Phase G2 — run-to-run variance (harness only)

**Execute N iterations, then aggregate per-iteration summaries.** (`runWindow`
currently runs once and `--iterations` is unused — see Background. So G2 must
*implement* multi-iteration execution, not merely re-aggregate.)

- Add a thin orchestration layer above the scenario that invokes the existing
  single-run primitive (`runWindow`, via `scenario.run(options:)`) **N times**,
  collecting N `PerfScenarioRunResult`s — each already writes its own run
  directory and `PerfSummary`. `runWindow` is reused **unchanged** as the
  one-iteration primitive; no surgery inside it.
- New pure `AggregateReducer.reduce(summaries:) -> PerfAggregateSummary` produces
  the cross-iteration stats below. The per-iteration within-run percentile
  distributions remain available unchanged.
- New `PerfAggregateSummary` over the N per-iteration summaries computes, for the
  headline metrics — `total_cpu_seconds`, `committed_frame_count`,
  `cpu_seconds_per_committed_frame`, `input_to_present_latency_ms` p95,
  `frame_interval_ms` p50 — the set: **median, mean, stddev, min, max,
  coefficient of variation (CV)**.
- `CompareCommand` gains a **significance verdict**: a metric's delta is flagged
  `real` only when it exceeds the combined noise band (e.g. 95% CI non-overlap,
  or `|Δ| > k · pooled_stddev`); output includes the effect size and the band
  used. Raw deltas are still shown.
- Output: `summary.json` gains an `aggregate` block; the stderr summary prints
  `metric: median ± stddev (CV%)`.

**Why this shape.** Pooling N runs measures the *tail of per-frame timings*, not
the *stability of the run*. A scenario can have a steady p95 while
`total_cpu_seconds` swings ±20% — and CPU-seconds is exactly how the report ranks
tabs. The aggregate-over-iterations view is what makes A/B trustworthy.

**Tests.**
- Synthetic per-iteration inputs → assert median/mean/stddev/CV math.
- Compare verdict flips correctly around the threshold (just-inside vs.
  just-outside the band).
- Determinism: identical inputs across iterations → CV = 0, verdict `not real`.

---

## Phase G3 — de-perturb frame counts (runtime; zero behavior change)

**Record a derived shipping-build count; do not alter the real drop decision.**

- In the run-loop drop derivation, compute the eligibility a second time with
  `.diagnosticsFullRecord` excluded from the blocker set, and record a per-frame
  `wouldCommitWithoutDiagnostics` flag. The actual commit/drop decision is
  untouched.
- Implementation hook: `frameDropEligibilityBlockers(...)` already receives
  `diagnosticsRequireFullRecord`. Derive the reduced blocker set (same inputs,
  that flag forced `false`), run `FrameDropEligibility.classify`, and surface
  whether the reduced decision is `.mustCommit` vs `.canDropVisualOnly`.
- Plumb the flag: `RuntimeFrameSample` → `FrameDiagnosticRecord` → TSV/JSONL
  columns. `SummaryReducer` reports both `committed_frame_count` and
  `committed_excluding_diagnostics`.
- Documented honestly as a **predicted** shipping count — exact precisely because
  `.diagnosticsFullRecord` is the *only* excluded blocker; any frame with another
  blocker still counts as committed.

**Why derived (not a non-blocking mode).** Chosen for lowest risk: no behavior
change, one additive computed field. The higher-fidelity "non-blocking
measurement mode" (assemble/emit the record on the drop path so the shipping
drop path is *actually* exercised) is explicitly deferred.

**Tests.**
- Diagnostics-sole-blocker scenario (zero-damage, no animation/focus blockers) →
  `committed_excluding_diagnostics < committed_frame_count`.
- Animation-blocker scenario (active transition/completion) → the two counts are
  **equal**, proving G3 strips only the profiler's own contribution and leaves
  genuine animation commits intact.
- Disabled-path regression: with profiling off, no new per-frame cost.

---

## Phase G1 — reproducible gallery baseline (synthetic + overlay)

**Two reproduction paths, by purpose.**

1. **Committed synthetic scenarios** (`Tools/TermUIPerf`, framework-only views,
   no gallery dep) that reproduce the *shapes* of the hot tabs, runnable from a
   clean `swift-tui` checkout:
   - **Off-screen perpetual `PhaseAnimator`** below the fold → reproduces H1
     (perpetually-active animation, zero visible damage).
   - **Continuous `repeatForever` border** → reproduces H4 borders (real,
     non-zero continuous damage).
   - **Shimmer + spinner** (≈50 ms / 240 ms cadence) → reproduces the
     task-progress profile (animated *text*, per-frame cache churn).
2. **Overlay path** (`swift-tui-org`): a documented one-command recipe that
   materializes the real `GalleryTabScenario`/`CommandPaletteScenario` into an
   overlay'd `TermUIPerf` via `open_overlay`, so the gallery path-dep lives only
   in the overlay and never in the committed `swift-tui` manifest. Includes a
   recipe to regenerate the baseline report inputs.

- `docs/perf/README.md` documents both: *everyday → synthetic; full-fidelity →
  overlay recipe.*

**Why both.** Synthetic scenarios give fast, public-contract-clean, every-commit
repeatability but are a *model* of the gallery. The overlay path gives the
*actual* 18-tab fidelity when it's needed, without leaking a cross-repo
dependency into a public child.

**Tests.**
- Synthetic scenarios run green through the existing harness test path and emit
  the expected signal (e.g. the off-screen PhaseAnimator scenario shows
  zero-damage committed frames).
- Overlay recipe validated by a smoke run (short window) in the coordination repo.

---

## Phase G4 — memory-signal completeness (providers + harness)

- Add best-effort `approxBytes` to the byte-heavy providers where the estimate is
  cheap: retained `RasterSurface` (cells × cell size), `ImageAssetRepository`
  decoded images, `TerminalImageRenderer` payloads. Count-only remains correct
  for trees and text caches.
- Make the **idle-window duration and sample interval explicit harness config**
  with a documented default (**20 s @ 500 ms**), so memory runs are comparable
  (the report used ad-hoc windows).
- Add a derived **growth-slope + plateau-detection** metric (entries/sec; flag
  monotonic-with-no-plateau as the leak signature) so the leak signal is reported
  automatically rather than eyeballed. Reuses G2's per-series stats where useful.

**Tests.**
- Provider byte estimates are non-negative and stable across snapshots of an
  unchanged store.
- Slope/plateau math on synthetic series: monotonic-no-plateau → flagged;
  rises-then-plateaus (the bounded-LRU case from H5) → not flagged.

---

## Cross-repo discipline

Per the org root workflow (commit child changes first, then record pins):

| Work | Repo / location |
| --- | --- |
| G2 (variance), G4 harness config/slope, G1 synthetic scenarios | `swift-tui` `Tools/TermUIPerf` |
| G3 (derived count), G4 provider byte weights | `swift-tui` runtime/core |
| G1 overlay recipe + `docs/perf/README.md` | `swift-tui-org` (this repo) |

**Hard invariant:** no gallery path-dependency enters a public child manifest;
the real-gallery scenarios stay overlay-only.

## Testing strategy (summary)

Follow repo conventions: real `RunLoop` input-path coverage and bounded
condition-based waits over fixed sleeps. Per-phase tests are listed above; the
load-bearing assertions are G2's stats math + verdict threshold, and G3's
"equal counts under animation blockers" (which proves de-perturbation is
correctly scoped).

## Risks & open questions

- **G2 — variance threshold choice.** The `k`/CI band for the significance
  verdict is a judgment call; pick a conservative default and make it
  configurable. Calibrate against a few real repeated runs.
- **G3 — predicted vs. measured.** The derived count is a prediction; if a future
  question needs the *actually-exercised* shipping drop path, the deferred
  non-blocking mode becomes the follow-up.
- **G3 — surface area.** Adding a field across `RuntimeFrameSample` →
  `FrameDiagnosticRecord` → sinks touches the profiling product's public-ish
  surface; check the public-API baseline.
- **G1 — overlay ergonomics.** The one-command recipe must survive a fresh
  checkout; verify it doesn't silently depend on prior overlay state.
- **G4 — byte-estimate honesty.** Keep `approxBytes` optional and never present a
  guess as exact; count remains the always-reported signal.
- **Iteration cost.** Per-iteration summaries over 20 iterations × the gallery
  scenarios is expensive; the synthetic scenarios (G1) keep the default-iteration
  path cheap, with the full gallery reserved for the overlay path.
