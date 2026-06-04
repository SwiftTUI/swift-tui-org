# Measurement: `resolve_ms` win (ii) and G11+G3a — both stay deferred (evidence-backed)

**Date:** 2026-06-04 · **Pin:** `swift-tui@d900f0d7` (org root pinned to it) ·
**Author:** perf tail of plan
[`2026-06-03-008`](../plans/2026-06-03-008-structural-identity-migration-gap-remediation-plan.md).

## TL;DR

Two performance optimizations were deferred by the structural-identity
remediation pending a trustworthy measurement: (1) the `resolve_ms` **win (ii)** —
reducing `ViewGraph.structuralInvalidationIntersects`; and (2) **G11 + G3a** — the
maintained fold-up signature plus the incremental `RetainedFrameIndex` patcher.
Both were measured on a quiet machine with the variance-aware `TermUIPerf compare
--gate`. **Neither can produce a `.real` favorable verdict on the realistic
workload corpus.** Both remain deferred; `swift-tui/docs/VISION-GAP.md` now carries
the measured numbers. No framework code changed.

The gate — not reasoning — is the arbiter, and the gate's bar was established
empirically (below). The decisive upstream fact is that the work each candidate
targets sits **below that bar**, so building either optimization to run the gate
would only watch it return `.withinNoise`.

## Method

- **In-process pipeline ⇒ release build is mandatory.** `PerfScenarioRunner`
  runs the SwiftTUI pipeline in the `termui-perf` process; `--configuration` is
  recorded as metadata only and does **not** spawn an optimized build. So
  `SwiftTUICore` is optimized iff the tool is. All runs used
  `swiftly run swift run -c release termui-perf …`.
- **Machine:** 18 physical cores, load ≈ 2.5 (~14%/core), no concurrent builds or
  agents. Local ~2 AM, quiet.
- **Gate math** (`AggregateComparison`): `delta = candidate.median − base.median`;
  `noiseBand = 2 · max(base.stddev, candidate.stddev)`; verdict `.real` iff
  `|delta| > noiseBand`. Lower-is-better. `CPU seconds/frame` is the resolve-cost
  proxy (no dedicated `resolve_ms` aggregate metric exists).

### Empirical noise band (base-vs-base, identical code, 20+20 iters)

Running the **same** binary twice and gating with
`--require-improvement "CPU seconds/frame"` validates the harness and measures the
bar a real win must clear:

| Scenario | `CPU seconds/frame` median | noise band | as % of median | gate |
| --- | --- | --- | --- | --- |
| narrow-invalidation r6  | 0.0048 | 0.0003 | **≈ 6.3 %** | FAIL (declined: `within noise`) |
| narrow-invalidation r40 | 0.0147 | 0.0003 | **≈ 2.0 %** | FAIL (declined: `within noise`) |

Quoted gate output (r6):

```
CPU seconds/frame: 0.0048 -> 0.0048 (-0.0000, band 0.0003) [within noise]
gate: FAIL
  - CPU seconds/frame: required a real improvement, got within noise delta -0.0000
```

The gate correctly refuses to certify a non-change. **A real win must move
`CPU seconds/frame` by more than ~2–6.3 % on this machine.**

## Corpus profile (per-frame diagnostics, release)

`invalidated` = `|invalidatedIdentities|` (Candidate 1's multiplier);
`commit/total` bounds Candidate 2's target; `resolve/total` is the dominant phase.

| Scenario | frames | max `inv` | mean `inv` | reuse (steady) | resolve/total | commit/total |
| --- | --- | --- | --- | --- | --- | --- |
| narrow-invalidation r6  | 18  | **2** | 1.44 | 54/67   | ~40 % | ~4 % |
| narrow-invalidation r40 | 18  | **2** | 1.44 | 360/373 | ~37 % | ~7 % |
| gallery-animation-click | 44  | **2** | 0.11 | 0/13    | ~50 % | ~4 % |
| layout-scroll-burst     | 2   | **5** | 3.00 | 0/38    | ~36 % | ~8 % |
| phase-animator          | 135 | **1** | 0.07 | 0       | ~44 % | ~3 % |
| continuous-animation    | 75  | **1** | 1.00 | 1       | ~53 % | ~3 % |
| text-shimmer            | 116 | **1** | 1.00 | 0       | ~50 % | ~3 % |

The **maximum `|invalidatedIdentities|` anywhere in the corpus is 5** (a single
scroll-burst frame); it is 1–2 in every resolve-heavy scenario. Reuse fires
correctly post-remediation (e.g. 360/373 retained at r40) — the
`synthetic-narrow-invalidation` doc comment claiming reuse is "defeated" is stale.

## Candidate 1 — `resolve_ms` win (ii): `structuralInvalidationIntersects`

`ViewGraph.swift:1373`. Today `O(invalidated × depth)` per reuse candidate; the
deferred reduction precomputes the invalidated-node set + ancestor union once per
frame to reach `O(depth)` per candidate.

**Verdict: not landed (no `.real` win attainable).** The benefit scales with
`|invalidatedIdentities|`. At the measured `inv ≤ 2` (≤ 5 corpus-wide), the
precompute is asymptotically **equal** to the current loop and adds a per-frame
cache cost — at `inv = 1` the two are identical. Even at the busiest point
(narrow r40: ~360 reuse candidates/frame) the function's whole cost is bounded by
`candidates × inv × depth` — a few µs against `resolve_ms ≈ 1.8 ms`, i.e. well
under the ~2 % band at r40. Reducing it cannot clear the gate.

Landing it would add frame-scoped **mutable state to the `ViewGraph`
checkpoint-totality contract** plus a **stale-cache hazard on a
correctness-critical reuse path** — the exact class of change that produced the
reverted win-(i) reuse-rate regression — for zero measurable gain. **Kept
deferred.**

Why no scenario helps: a single localized click / scroll / animation-tick
*inherently* invalidates a narrow region. Wide simultaneous invalidation is not a
realistic terminal-UI interaction, so this is a structural property of the
workload, not a corpus gap.

### Open lead (reasoned, **not** empirically measured this session)

The one untested wide-background workload is the **gallery command-palette
presentation** over the full 18-tab `TabView` (`GalleryView.paletteSheet`).
Mechanically it should still be narrow: presenting toggles a single `@State`
(`showPalette`), and `.fullSurfaceDiff` (the scope presentation uses) is a
**surface-composition** metadata scope in `SwiftTUICore/Commit/`, orthogonal to
resolve's `invalidatedIdentities`. This was reasoned, not run — measuring it needs
a gallery-backed `PerfScenarioRegistry.additionalScenarios` scenario built against
the local pin (the gallery's own manifest pins `swift-tui` at tagged `0.0.14`, so
it must be overlaid, not used as-is). If Candidate 1 is ever revisited, this is
the first thing to measure; until then, no evidence contradicts the deferral.

## Candidate 2 — G11 + G3a: fold-up signature + incremental retained-index patch

`RetainedFrameQueries.swift:90` (`init(patching:with:)`, a full rebuild today) and
`StructuralFrameIndex.swift:16` (`subtreeSignatureByNode`, the L2 hook, no live
consumer). G11 is only useful as the patcher's input, so they land together or
not at all.

**Verdict: not landed (target is off the critical path, below the band).**
`commit_ms` is **~4 % (r6) / ~7 % (r40)** of total frame time, ≤ 3 % in the
animation scenarios. The `RetainedFrameIndex` rebuild is only a *portion* of
`commit_ms` (which also covers runtime registrations, draw indexing, the topology
signature, and the raster store), so the patcher's actual target is **sub-1 %** —
consistent with the prior session's `commit_ms`-breakdown finding. An incremental
patcher could shave only part of that and still must walk to locate fragments. It
cannot clear the ~2–6.3 % band. `resolve_ms` dominates at ~37–53 %; the bottleneck
is resolve, not commit. Building G3a (incremental fragment patcher + fold-up on
three node types + fragment lifetime + tree-walk-bug risk) is **not justified.**
**Kept deferred.**

## Decision

| Candidate | Gate-attainable `.real` win? | Decision |
| --- | --- | --- |
| 1 — `structuralInvalidationIntersects` reduction | No (`inv ≤ 5`, target ≪ band) | **Deferred**, evidence-backed |
| 2 — G11 + G3a patcher/fold-up | No (commit 4–8 %, index a fraction of it, ≪ band) | **Deferred**, evidence-backed |

No framework code changed. `swift-tui/docs/VISION-GAP.md` updated with these
numbers so each deferral is evidence-backed, not a guess. The `TermUIPerf` gate
remains the arbiter for any future attempt: optimize by measurement, not by eye.
