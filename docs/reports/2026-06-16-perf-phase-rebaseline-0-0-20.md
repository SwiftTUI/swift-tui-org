# Perf Phase Re-baseline at 0.0.20

- **Date:** 2026-06-16
- **Measured code:** `swift-tui 8cebb787` (`0.0.20`)
- **Org root:** `b5f2154` plus local doc-only planning updates
- **Goal:** current-pin opener from
  [2026-06-15 performance phase completion goal](../plans/2026-06-15-001-perf-phase-completion-goal.md)
- **Environment:** release `TermUIPerf`, async mode, AC power, same session.
- **Artifacts:** `/tmp/swifttui-rebaseline-2026-06-16/8cebb787-ac/`

## Method

The release perf tool was rebuilt after resetting the TermUIPerf package cache:

```bash
swiftly run swift package reset --package-path swift-tui/Tools/TermUIPerf
swiftly run swift build -c release --package-path swift-tui/Tools/TermUIPerf --product termui-perf
```

Runs were written to separate artifact directories so same-scenario aggregate
files would not overwrite each other:

- `narrow-20`: `TERMUI_PERF_INVALIDATION_TREE_ROWS=20`, 18 iterations.
- `narrow-40`: `TERMUI_PERF_INVALIDATION_TREE_ROWS=40`, 18 iterations.
- `sheet-44`: default `sheet-open-latency`, 15 iterations.
- `sheet-176-colocated`: `TERMUI_PERF_SHEET_TREE_ROWS=176`, 15 iterations.
- `sheet-176-sibling`: `TERMUI_PERF_SHEET_TREE_ROWS=176`
  `TERMUI_PERF_SHEET_TRIGGER=sibling`, 15 iterations.
- `sheet-176-popover`: `TERMUI_PERF_SHEET_TREE_ROWS=176`
  `TERMUI_PERF_SHEET_OVERLAY=popover`, 15 iterations.
- `scroll-burst`: `layout-scroll-burst`, 18 iterations.

`SWIFTTUI_PUBLICATION_DIAGNOSTICS` was not enabled for this baseline, so the
runtime publication/restore strategy TSV columns are intentionally not populated.
Use a follow-up diagnostics pass if the next decision needs strategy splits.

Build warnings were the existing unused-import warnings in
`PresentationTriggerLeaf.swift` and `ProfiledMemoryAccess.swift`.

## Current Baseline

Median per aggregate. Head columns are p50 per-frame timings in milliseconds.

| config | iters | cpu/frame s | total_cpu s | input p95 ms | frame p50 ms | prepare p50 | ckpt create | ckpt restore | proc tree | cmt/cxl |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| narrow 20 | 18 | 0.0092 | 0.1555 | 128.1 | 8.23 | 1.66 | 0.55 | 0.32 | 0.35 | 17/0 |
| narrow 40 | 18 | 0.0139 | 0.2318 | 189.8 | 12.34 | 2.83 | 1.06 | 0.55 | 0.60 | 16.5/0 |
| sheet 44 | 15 | 0.0222 | 0.3697 | 334.4 | 12.88 | 3.64 | 0.745 | 0.52 | 0.47 | 17/8 |
| sheet 176 co-located | 15 | 0.0582 | 0.9856 | 885.4 | 28.19 | 11.16 | 2.84 | 1.81 | 1.78 | 17/8 |
| sheet 176 sibling | 15 | 0.0516 | 0.8717 | 770.5 | 28.07 | 5.80 | 2.44 | 0.645 | 1.87 | 17/8 |
| sheet 176 popover | 15 | 0.0576 | 0.9764 | 879.5 | 45.88 | 9.74 | 2.83 | 1.98 | 1.79 | 17/4 |
| scroll-burst | 18 | 0.0074 | 0.0148 | 4.07 | 4.44 | 1.64 | 0.155 | 0.115 | 0.06 | 2/0 |

Per-frame TSV medians over completed non-cold frames (`frame > 1`) for the
pipeline phases not present in the aggregate JSON:

| config | resolve | measure | place | semantics | draw | raster | commit | pipeline | total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| narrow 40 | 1.30 | 1.36 | 0.74 | 0.77 | 0.27 | 0.77 | 0.41 | 5.63 | 5.76 |
| sheet 44 | 1.97 | 1.12 | 0.63 | 0.54 | 0.19 | 1.68 | 0.38 | 5.94 | 6.15 |
| sheet 176 co-located | 5.88 | 4.74 | 1.83 | 1.87 | 0.68 | 2.01 | 1.35 | 17.89 | 18.11 |
| sheet 176 sibling | 1.88 | 3.89 | 1.42 | 1.88 | 0.68 | 2.03 | 1.38 | 11.79 | 12.01 |
| sheet 176 popover | 5.44 | 3.04 | 1.99 | 1.87 | 0.67 | 1.45 | 1.27 | 15.53 | 15.75 |
| scroll-burst | 0.94 | 0.08 | 0.39 | 0.08 | 0.03 | 0.23 | 0.22 | 2.00 | 2.11 |

## Comparison to `30fc38bf`

Compared with
[2026-06-15-perf-phase-rebaseline.md](2026-06-15-perf-phase-rebaseline.md).

| config | old total_cpu | new total_cpu | delta | old prepare | new prepare | delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| narrow 20 | 0.1621 | 0.1555 | -4.1% | 1.68 | 1.66 | -1.2% |
| narrow 40 | 0.2412 | 0.2318 | -3.9% | 2.84 | 2.83 | -0.5% |
| sheet 44 | 0.4700 | 0.3697 | -21.3% | 7.34 | 3.64 | -50.4% |
| sheet 176 co-located | 1.3484 | 0.9856 | -26.9% | 26.1 | 11.16 | -57.2% |
| sheet 176 sibling | 1.2884 | 0.8717 | -32.3% | 26.5 | 5.80 | -78.1% |
| sheet 176 popover | 1.3966 | 0.9764 | -30.1% | 28.0 | 9.74 | -65.2% |
| scroll-burst | 0.0146 | 0.0148 | +1.5% | 1.69 | 1.64 | -2.8% |

The narrow canary is flat-to-slightly-better. The sheet rows show the expected
large head-prepare and total-CPU drop from the two sheet-cone fixes.

## Reuse Shape

Completed non-cold frame medians show the background is now reused on the sheet
cycle:

| config | computed median | reused median |
| --- | ---: | ---: |
| sheet 44 | 28 | 221 |
| sheet 176 co-located | 28 | 883 |
| sheet 176 sibling | 28 | 884 |
| sheet 176 popover | 23 | 884 |

This is consistent with the mechanism-2 report's conclusion that the repeated
steady-state `invalidation-conflict` cone is gone. This run did not arm
`SWIFTTUI_REUSE_TRACE`; it uses the normal frame diagnostics.

## Current Ranking

1. **Checkpoint create/restore remains the largest concrete head residual on the
   176-row sheet path.** Co-located sheet p50 is `2.84 ms` create + `1.81 ms`
   restore; popover is `2.83 ms` + `1.98 ms`. The cheap create-image reuse lever
   was already disproven, so a real create win means the persistent
   copy-on-mutation checkpoint store or a graph/state split. That is structural
   and should not be started without a focused design.
2. **Co-located vs sibling still has a head-prep gap.** At rows 176, co-located
   prepare p50 is `11.16 ms`; sibling is `5.80 ms`. The repeated cone is gone,
   so this looks like remaining portal/trigger-shape bookkeeping rather than the
   old `Layout[0]` recompute cone. Before code, run a small diagnostic pass with
   `SWIFTTUI_INVAL_TRACE` and `SWIFTTUI_PUBLICATION_DIAGNOSTICS` on co-located vs
   sibling to attribute the gap.
3. **`processResolvedTree` is stable but secondary.** It is about `1.78-1.87 ms`
   on sheet-176 and `0.60 ms` on narrow-40. That is real, but still a high-risk
   animation/transition seam.
4. **Raster is a parallel but lower-EV candidate.** Sheet-176 raster medians are
   `1.45-2.03 ms`; narrow-40 is `0.77 ms`. Any raster work should be a separate
   renderer-output-equivalence effort, not part of the sheet-cone tranche.
5. **No evidence yet for a `restoreRuntimeRegistrations` cache.** The normal
   aggregate/TSV pass does not show a regression on the narrow canary. If the
   cache is reconsidered, size it with diagnostics first.

## Next Step

Run a focused diagnostics pass, not a broad optimization:

```bash
SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 SWIFTTUI_INVAL_TRACE=1 \
  TERMUI_PERF_SHEET_TREE_ROWS=176 \
  swift-tui/Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario sheet-open-latency \
  --modes async \
  --iterations 3 \
  --artifacts-root /tmp/swifttui-rebaseline-2026-06-16/8cebb787-ac/diagnostics-sheet-176-colocated

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 SWIFTTUI_INVAL_TRACE=1 \
  TERMUI_PERF_SHEET_TREE_ROWS=176 TERMUI_PERF_SHEET_TRIGGER=sibling \
  swift-tui/Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario sheet-open-latency \
  --modes async \
  --iterations 3 \
  --artifacts-root /tmp/swifttui-rebaseline-2026-06-16/8cebb787-ac/diagnostics-sheet-176-sibling
```

That should decide whether the next tranche is checkpoint storage design,
force-root/focus narrowing, or no immediate perf code.
