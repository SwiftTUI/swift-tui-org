# Focus/Press Dirty-Frontier Results

- **Date:** 2026-06-16
- **Root measurement base:** `5f40fed` plus `swift-tui` at `d9065efe`
- **SwiftTUI stages:**
  - `e25b1d06` - narrow focus/press dirty-frontier evaluation.
  - `d9065efe` - keep animation safety root-forced after the first measurement
    showed the finite-scope exemption was too broad.
- **Entry report:**
  [`2026-06-16-perf-tranche-diagnostics-start.md`](2026-06-16-perf-tranche-diagnostics-start.md)
- **Artifacts root:** `/tmp/swifttui-tranche-2026-06-16`

## Summary

The implementation landed the intended correctness behavior for finite
focus/press retained-reuse safety: those scopes can enter dirty-frontier
planning as graph-local dirty work instead of always forcing root evaluation.
Animation-related retained-reuse safety remains root-forced.

The performance result is mixed and does not clear the tranche decision rule.
The sheet scenarios show slightly lower head/checkpoint phase medians, but worse
input p95 and total CPU. The example-app shell calibration improves modestly.
The v2 traces still contain `frame_state_force_root` disabled selective
evaluation frames, so the next tranche should instrument and attribute those
root-forced frames before any checkpoint policy change.

## Final Measurement

Baseline values are from the entry report at root `7ca4b74`, `swift-tui`
`78fb9f4c`. Final values are from `swift-tui` `d9065efe`.

| Run | Input p95 ms | CPU s | CPU/frame | Frames | Head prepare p50 ms | Checkpoint create p50 ms | Checkpoint restore p50 ms | Process tree p50 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Baseline sheet-176 co-located | 881.86 | 0.9817 | 0.0577 | 17 committed / 25 diagnostic / 8 cancelled | 11.28 | 2.83 | 1.76 | 1.80 |
| Final sheet-176 co-located | 1000.26 | 1.0976 | 0.0683 | 16 committed / 24 diagnostic / 8 cancelled | 10.83 | 2.78 | 1.76 | 1.75 |
| Delta | +13.4% | +11.8% | +18.4% | - | -4.0% | -1.9% | +0.0% | -2.8% |
| Baseline sheet-176 sibling | 769.29 | 0.8718 | 0.0526 | 17 committed / 25 diagnostic / 8 cancelled | 6.03 | 2.44 | 0.63 | 1.90 |
| Final sheet-176 sibling | 889.32 | 0.9981 | 0.0617 | 16 committed / 24 diagnostic / 8 cancelled | 5.82 | 2.35 | 0.63 | 1.86 |
| Delta | +15.6% | +14.5% | +17.2% | - | -3.5% | -3.7% | -0.8% | -2.4% |
| Baseline example-app shell | 856.81 | 0.9432 | 0.0786 | 12 committed / 15 diagnostic / 3 cancelled | 5.02 | 2.16 | 3.24 | 0.16 |
| Final example-app shell | 813.16 | 0.8958 | 0.0747 | 12 committed / 15 diagnostic / 3 cancelled | 5.13 | 1.96 | 3.07 | 0.16 |
| Delta | -5.1% | -5.0% | -5.0% | - | +2.2% | -9.5% | -5.2% | +0.0% |

Commands:

```bash
swiftly run swift package reset --package-path swift-tui/Tools/TermUIPerf
swiftly run swift build -c release --package-path swift-tui/Tools/TermUIPerf --product termui-perf

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 SWIFTTUI_INVAL_TRACE=1 \
  TERMUI_PERF_SHEET_TREE_ROWS=176 \
  swift-tui/Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario sheet-open-latency --modes async --iterations 3 \
  --artifacts-root /tmp/swifttui-tranche-2026-06-16/focus-press-v2-sheet-176-colocated

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 SWIFTTUI_INVAL_TRACE=1 \
  TERMUI_PERF_SHEET_TREE_ROWS=176 TERMUI_PERF_SHEET_TRIGGER=sibling \
  swift-tui/Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario sheet-open-latency --modes async --iterations 3 \
  --artifacts-root /tmp/swifttui-tranche-2026-06-16/focus-press-v2-sheet-176-sibling

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 SWIFTTUI_INVAL_TRACE=1 \
  swift-tui/Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario example-app-shell-workflow --modes async --iterations 3 \
  --artifacts-root /tmp/swifttui-tranche-2026-06-16/focus-press-v2-example-app-shell
```

## Course Correction

The first child stage (`e25b1d06`) allowed every finite retained-reuse safety
scope to avoid root forcing. That was too broad because finite animation safety
is not proven equivalent to focus/press safety.

| Run after `e25b1d06` | Input p95 ms | CPU s | CPU/frame | Head prepare p50 ms | Checkpoint create p50 ms | Checkpoint restore p50 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| sheet-176 co-located | 1031.48 | 1.1290 | 0.0665 | 10.85 | 2.80 | 1.75 |
| sheet-176 sibling | 935.01 | 1.0354 | 0.0609 | 5.71 | 2.42 | 0.65 |
| example-app shell | 811.71 | 0.8980 | 0.0748 | 5.25 | 1.97 | 3.13 |

`d9065efe` narrowed the policy to focus/press-only finite safety and keeps
animation safety root-forced. That improved the sheet regression versus the
first stage but did not make the sheet path better than baseline.

## Gate Attribution

The final v2 traces still report selective evaluation disabled by
`frame_state_force_root`:

| Scenario | Disabled frames per iteration |
| --- | ---: |
| sheet-176 co-located | 8 |
| sheet-176 sibling | 8 |
| example-app shell | 3 |

The example-app shell also has one `focus_changed` disabled frame per iteration.
No final v2 trace reported `pressed_changed` as the disabled reason.

## Verification

SwiftTUI tests:

```bash
swiftly run swift test --package-path swift-tui --filter FrameResolveStateTests --jobs 1
swiftly run swift test --package-path swift-tui --filter ViewGraphTests --jobs 1
swiftly run swift test --package-path swift-tui --filter ResolveReuseAncestorInvalidationTests --jobs 1
swiftly run swift test --package-path swift-tui/Tools/TermUIPerf --filter TermUIPerfTests --jobs 1
```

All passed after the final child stage.

## Next Tranche

Do not continue directly to checkpoint restore policy from this result. The next
tranche should add narrow diagnostics for root-forced dirty-frontier frames:

1. Add per-frame attribution for `forceRootEvaluation()` sources, including
   explicit frame/context force-root, focus sync, retained-reuse scope kind,
   proposal/root invalidation, and animation work.
2. Report dirty frontier shape: queued graph-local identities, candidate root
   count, resolved computed/reused nodes, and publication subtree roots.
3. Split retained-reuse safety counters by focus, press, and animation sources.
4. Rerun the same three scenarios and decide whether another root-gate narrowing
   is safe. Only move to checkpoint restore policy if root-force attribution is
   no longer the primary explanation.
