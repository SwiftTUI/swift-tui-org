# `commit_ms` Breakdown Probe (archived instrumentation)

Temporary measurement instrumentation used to locate and verify the `commit_ms`
optimization (see [`../../reports/2026-05-30-commit-ms-breakdown-findings.md`](../../reports/2026-05-30-commit-ms-breakdown-findings.md)
and [`../../reports/2026-05-31-commit-ms-registration-restore-fix-results.md`](../../reports/2026-05-31-commit-ms-registration-restore-fix-results.md)).
It was intentionally **not** landed on `swift-tui` `main` (instrumentation, not a
feature). Archived here so future commit-path measurement can reuse it.

## What it does

Env-gated by `TERMUI_PERF_COMMIT_BREAKDOWN=1` (no-op when unset). Adds a
`CommitBreakdownProbe` (`@_spi(Runners)`, Foundation-free) that, per committed
frame, records:

- `commit_ms` split into `finalize` / `txn` / `plan` (the three `commitFrameEffects`
  sub-phases);
- `transaction.commit()` drilled into its four sub-commits (`graphRegistrations`,
  `observation`, `portal`, `animation`);
- the `runtimeRegistrationPublication` mode tally (`.all` / `.subtrees` / `.unchanged`
  + mean subtree-root count).

`termui-perf` emits a one-line `[commit-breakdown]` summary per process to stderr at
teardown. Excluded from the public-API baseline (`@_spi`).

## How to re-apply

`probe.patch` is a diff against `swift-tui` `main` @ `2b05d0fa` (rebased
2026-06-12 for the sheet transition-frame commit diagnosis). The probe touches files **disjoint** from the fix, so it applies cleanly
on top of `main` + the scoped-restore fix:

```bash
cd swift-tui
git apply ../docs/perf/commit-ms-breakdown-probe/probe.patch
swiftly run swift build -c release --package-path Tools/TermUIPerf --product termui-perf
# sweep:
for ROWS in 6 20 40; do
  TERMUI_PERF_INVALIDATION_TREE_ROWS=$ROWS TERMUI_PERF_COMMIT_BREAKDOWN=1 \
    swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
    run --scenario synthetic-narrow-invalidation --modes async --iterations 20 --configuration release
done
```

Or check out the full instrumented state (probe + fix) directly:

```bash
cd swift-tui && git checkout commit-ms-breakdown-probe-2026-05-31   # annotated tag
# or the branch: perf/commit-ms-breakdown-instrumentation
```

## Also reverted: Fix 1 (sort cache) — do not re-attempt

Caching `liveIdentities.sorted()` was measured **ineffective** (the sort is ~1–2% of
the restore cost; the O(n) per-node restore dominates). It also would have required a
`ViewGraph.Checkpoint` totality-contract entry. Reverted; documented in the
fix-results report. The structural win is scoping the restore (Fix 2), not the sort.
