# P1–P3 before/after perf measurement (retained reuse + raster)

Quantifies the three perf fixes from the
[2026-06-28 architecture audit](2026-06-28-independent-architecture-bottleneck-fragility-deepdive.md):

- **P1** — retained phase-product whole-tree gate (a `.canvas`/custom-layout node
  discarded the whole frame's retained draw/semantic products; the fix retains
  them with a nil whole-tree signature so the per-subtree partial path reuses the
  supported subtrees). `swift-tui` `573fc2af`.
- **P2** — duplicate retained-signature build in `storeCommittedFrame` replaced by
  a tree-compare overlay-empty proxy. `swift-tui` `573fc2af`.
- **P3** — dropped the dead per-glyph presentation-layer cell copy in
  `RasterPresentationLayerRecorder.appendCellFragment`. `swift-tui` `bd2c4491`.

## Method

- **before** = `e552ad98` (the commit just before P1–P3); **after** = `bbd67cd5`
  (P1–P3 plus the new scenario). Measured via a detached `swift-tui` worktree at
  `e552ad98` with the `canvas-partial-reuse` scenario copied in, so identical
  scenario code runs against each framework revision.
- `TermUIPerf`, `--modes async --iterations 20 --configuration release`, scenario
  run-to-run CV 2–5%.
- Scenarios: `canvas-partial-reuse` (new, P1; `TERMUI_PERF_CANVAS_REUSE_TREE_ROWS=30`),
  `synthetic-narrow-invalidation` (P2), `gallery-tab-switch` (P3).
- Per-phase numbers are medians of the `frames.tsv` columns across all committed
  frames of all 20 iterations (~330 frames/side).

## Results — per-phase median ms

| Scenario | `draw_ms` (P1) | `raster_ms` (P3) | `commit_ms` (P2) |
| --- | --- | --- | --- |
| `canvas-partial-reuse` (grid 30) | **0.210 → 0.020  (−90%)** | 0.690 → 0.600  (−13%) | 0.280 → 0.280  (flat) |
| `synthetic-narrow-invalidation` | 0.040 → 0.010  (noise floor) | 0.380 → 0.340  (−10%) | flat |
| `gallery-tab-switch` | flat | 1.460 → 1.290  (−12%) | flat |

`canvas-partial-reuse` `draw_ms` distribution (n≈330/side): before mean/median/p90
= 0.210/0.210/0.230; after = 0.034/0.020/0.030 — a tight ~85% mean reduction (the
lone after-max of 0.26 is the initial full-render frame, which still extracts
everything).

Aggregate `cpu_seconds_per_committed_frame` and `total_cpu_seconds` are **within
noise** for all three scenarios.

## Interpretation

- **P1 is clearly measured.** In the only scenario containing a `Canvas`, draw
  extraction drops ~85–90% — the disjoint static grid's draw nodes are reused
  instead of re-extracted every frame. The other scenarios have no canvas (so
  their grids already reused), which is why `draw_ms` there sits at the noise
  floor / is flat.
- **P3 is clearly measured and broad.** `raster_ms` falls a consistent ~10–13%
  in *every* scenario, because rasterization runs on every frame and the
  per-glyph cell-slice copy is now gone.
- **P2 is below the timing signal.** Avoiding one `RetainedPhaseExtractionSignature`
  build per frame did not move the `commit_ms` median; it is a small allocation
  reduction, not a timing win at terminal scale.
- **Aggregate CPU/frame is within noise** because `draw_ms`+`raster_ms` are a
  small fraction of total frame cost, which is dominated by `resolve_ms`/`measure_ms`
  (e.g. gallery `resolve_ms` ≈ 6 ms vs `raster_ms` ≈ 1.3 ms). This matches the
  audit's framing of P1–P3 as real-but-bounded (Medium): the optimizations
  measurably improve their target phases, but those phases are not the dominant
  cost at terminal tree sizes.

## Caveats

- Measured on one machine (Apple silicon, in-process pipeline, async mode); these
  are relative deltas, not absolute throughput claims.
- `canvas-partial-reuse` amplifies P1 with a large static grid (`ROWS=30`); the
  effect scales with the reusable subtree size, so smaller real screens see a
  proportionally smaller absolute saving.
- Phase timers quantize near ~0.01 ms; sub-0.05 ms moves (e.g. narrow-invalidation
  `draw_ms`) are at the noise floor and not claimed as wins.
