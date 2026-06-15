# Perf Phase Re-baseline (step 0)

- **Date:** 2026-06-15
- **Pin:** `swift-tui 30fc38bf`, org root `main`.
- **Goal:** [`2026-06-15-001-perf-phase-completion-goal.md`](../plans/2026-06-15-001-perf-phase-completion-goal.md) step 0.
- **Environment:** release `TermUIPerf`, async mode, **AC power**, same session.
  Artifacts: `/tmp/swifttui-rebaseline-2026-06-15/30fc38bf-ac/`.

## Baseline (median per aggregate; p50 = per-frame head columns, ms)

| config | iters | cpu/frame s | total_cpu s | input p95 ms | prepare p50 | ckpt create p50 | ckpt restore p50 | proc_tree p50 | cmt/cxl |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| narrow 20 | 18 | 0.0090 | 0.1621 | 127.3 | 1.68 | 0.55 | 0.32 | 0.34 | 18/0 |
| narrow 40 | 18 | 0.0134 | 0.2412 | 189.0 | 2.84 | 1.06 | 0.54 | 0.58 | 18/0 |
| **sheet 44** (default) | 15 | 0.0261 | 0.4700 | 419.6 | 7.34 | **1.18** | **0.86** | 0.47 | 18/8 |
| sheet 176 co-located | 15 | 0.0749 | 1.3484 | 1204.5 | 26.1 | 4.33 | 3.20 | 1.74 | 18/8 |
| sheet 176 sibling | 15 | 0.0716 | 1.2884 | 1141.1 | 26.5 | 4.27 | 3.17 | 1.80 | 18/8 |
| sheet 176 popover | 15 | 0.0776 | 1.3966 | 1247.9 | 28.0 | 4.58 | 3.49 | 1.79 | 18/4 |
| scroll-burst | 18 | 0.0073 | 0.0146 | 3.86 | 1.69 | 0.16 | 0.12 | 0.06 | 2/0 |

## The "rows=176" reconciliation (important)

The first run showed sheet costs ~3× the Stage 2B report (create 4.3 vs 1.2 ms).
It was **not** a regression. Two findings:

1. **Battery throttling** accounted for ~7–17% (the first run was on battery;
   sustained sheet iterations get clamped, short narrow bursts do not). Re-run
   on AC.
2. The remaining ~3× was a **row-count mismatch in the prior reports.** The
   Stage 2B report's `create 1.20 / restore 0.89 / cpu 0.0273 / prepare 7.68`
   were measured at the scenario **default 44 rows**, despite the
   proposal-lineage header saying "rows=176". Proof: 30fc38bf at default 44 rows
   reproduces those exactly (`1.18 / 0.86 / 0.0261 / 7.34`). Costs scale linearly
   with node count at ~0.025 ms/row of `ckpt_create`, **consistent across both
   narrow and sheet** — so there is no per-node regression; sheet at 176 rows is
   simply 4× the nodes of sheet at 44.

**Consequence for the phase:** absolute numbers are only comparable at identical
`TERMUI_PERF_SHEET_TREE_ROWS`. Going forward, sheet is measured at **both** 44
(comparability with the Stage 2B/goal `~1.2ms` reference) and 176 (amplified
signal). Same-session A/B remains mandatory.

## Confirmed targets (the goal's residual map, corrected)

- **Item A (checkpoint create)** is the #1 head residual and confirmed worth
  doing: `ckpt_create_p50` 1.18 ms @44 / 4.33 ms @176 — and it is **two** full
  `viewGraph.makeCheckpoint()` calls per abortable frame (baseline + prepared),
  both timed under `graph_checkpoint_create`. Restore is already Stage-2B-low
  (0.86 @44 / 3.20 @176) and serves as the no-regression canary.
- **Item C (`processResolvedTree`)** 0.47 ms @44 / 1.74 ms @176 sheet, 0.34–0.58
  narrow — an unconditional full-tree walk; real but secondary to create.
- Narrow path matches documented history (narrow-40 total_cpu 0.2412 ≈ 0.250)
  and is the canary that must not move.

## Method notes (carry forward)

- The runner script `pipefail`+`tail` combo SIGPIPEs (exit 141) on the trailing
  `ls | head` even when all configs succeed; use `set -eu` (no pipefail).
- Do not start a build (or any heavy CPU) concurrently with a perf run — it
  contends for cores and contaminates the measurement.
