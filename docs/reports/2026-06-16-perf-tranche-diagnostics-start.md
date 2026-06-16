# Perf Tranche Diagnostics Start

- **Date:** 2026-06-16
- **Root commit:** `7ca4b74`
- **SwiftTUI commit:** `78fb9f4c`
- **Purpose:** start the post-0.0.20 performance tranche with focused
  diagnostics before changing runtime behavior.

## Runs

Artifacts were written under `/tmp/swifttui-tranche-2026-06-16`:

| Run | Scenario | Input p95 ms | CPU s | CPU/frame | Frames | Head prepare p50 ms | Checkpoint create p50 ms | Checkpoint restore p50 ms | Process tree p50 ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `diagnostics-sheet-176-colocated` | `sheet-open-latency`, rows=176 | 881.86 | 0.9817 | 0.0577 | 17 committed / 25 diagnostic / 8 cancelled | 11.28 | 2.83 | 1.76 | 1.80 |
| `diagnostics-sheet-176-sibling` | `sheet-open-latency`, rows=176, sibling trigger | 769.29 | 0.8718 | 0.0526 | 17 committed / 25 diagnostic / 8 cancelled | 6.03 | 2.44 | 0.63 | 1.90 |
| `diagnostics-example-app-shell` | `example-app-shell-workflow` | 856.81 | 0.9432 | 0.0786 | 12 committed / 15 diagnostic / 3 cancelled | 5.02 | 2.16 | 3.24 | 0.16 |

Commands:

```bash
swiftly run swift package reset --package-path swift-tui/Tools/TermUIPerf
swiftly run swift build -c release --package-path swift-tui/Tools/TermUIPerf --product termui-perf

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 SWIFTTUI_INVAL_TRACE=1 \
  TERMUI_PERF_SHEET_TREE_ROWS=176 \
  swift-tui/Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario sheet-open-latency --modes async --iterations 3 \
  --artifacts-root /tmp/swifttui-tranche-2026-06-16/diagnostics-sheet-176-colocated

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 SWIFTTUI_INVAL_TRACE=1 \
  TERMUI_PERF_SHEET_TREE_ROWS=176 TERMUI_PERF_SHEET_TRIGGER=sibling \
  swift-tui/Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario sheet-open-latency --modes async --iterations 3 \
  --artifacts-root /tmp/swifttui-tranche-2026-06-16/diagnostics-sheet-176-sibling

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 SWIFTTUI_INVAL_TRACE=1 \
  swift-tui/Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario example-app-shell-workflow --modes async --iterations 3 \
  --artifacts-root /tmp/swifttui-tranche-2026-06-16/diagnostics-example-app-shell
```

## Interpretation

The first tranche should not begin with a general checkpoint-storage rewrite.
The sheet co-located/sibling comparison shows the largest difference in
`head_prepare_p50_ms` and checkpoint restore, not checkpoint creation alone.
Both runs are still mostly blocked from selective evaluation by
`frame_state_force_root`, `focus_changed`, and `pressed_changed`.

The app-shell calibration adds a second signal: it is stable, representative of
example-app chrome composition, and restore-heavy. Many of its frames fall back
to full graph checkpoint restore because the delta touched-node ratio exceeds
the current 70% budget. That points to a later checkpoint-policy tranche, but it
does not explain the co-located sheet gap by itself.

## Next Implementation Slice

Start with focus/press dirty-frontier narrowing:

1. Stop using root evaluation as the only way to make focus/press
   reuse-suppression identities reachable when the suppression scope is finite.
2. Queue finite focus/press safety identities as graph-local dirty work and let
   selective dirty-frontier planning form the target roots.
3. Keep hard root blockers unchanged: explicit frame/context force-root,
   proposal changes, root invalidation, and suppression scope `.all`.
4. Add correctness tests around focus/press environment readers, current and
   previous focused/pressed identities, and the existing retained-reuse
   suppression behavior.
5. Re-run the same three diagnostics and compare against this report before
   moving to checkpoint restore policy.

Decision threshold: if the sheet co-located path no longer reports
`frame_state_force_root` for ordinary focus/press safety frames and the head
prepare gap narrows without correctness regressions, continue this tranche
through remaining focus/root gates. If the app-shell restore fallback remains
the dominant residual after that, split a checkpoint-policy tranche that is
validated by `example-app-shell-workflow` rather than by the amplified sheet
stress path alone.
