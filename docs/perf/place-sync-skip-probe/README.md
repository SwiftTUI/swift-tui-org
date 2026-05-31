# `place_ms` Sync-Skip Probe (archived instrumentation)

Temporary measurement instrumentation used to attribute and A/B the `place_ms`
identical-subtree sync-skip optimization (see
[`../../reports/2026-05-31-place-ms-identical-subtree-sync-skip-results.md`](../../reports/2026-05-31-place-ms-identical-subtree-sync-skip-results.md)).
Intentionally **not** landed on `swift-tui` `main` (instrumentation, not a feature).
Archived here so future placement-path measurement can reuse it.

## What it does

Adds a Foundation-free, env-gated `PlacePerfProbe` (in `SwiftTUICore`, reads
`getenv` once and caches):

- `TERMUI_PERF_PLACE_DISABLE_SYNC_SKIP=1` — force the *prior* behavior where a
  fully `.identical` reused subtree is still re-synced
  (`synchronizeRetainedPhaseMetadata`) instead of returned untouched. Sound (it
  is the old behavior); lets you A/B the shipping sync-skip against the baseline
  in a single sweep with no machine drift.

The probe gates exactly one expression in `retainedPlacement`
(`Sources/SwiftTUICore/Measure/LayoutEngine+RetainedLayout.swift`):
`skipMetadataSync = equivalence == .identical` becomes
`equivalence == .identical && !PlacePerfProbe.disableSyncSkip`.

## How to re-apply

`probe.patch` is a diff against the landed fix on `swift-tui` `main`. Apply, then
A/B-sweep:

```bash
cd swift-tui
git apply ../docs/perf/place-sync-skip-probe/probe.patch
swiftly run swift build -c release --package-path Tools/TermUIPerf --product termui-perf
for ROWS in 6 20 40; do
  # baseline (old always-sync):
  TERMUI_PERF_INVALIDATION_TREE_ROWS=$ROWS TERMUI_PERF_PLACE_DISABLE_SYNC_SKIP=1 \
    swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
    run --scenario synthetic-narrow-invalidation --modes async --iterations 20 --configuration release
  # fix (sync-skip):
  TERMUI_PERF_INVALIDATION_TREE_ROWS=$ROWS \
    swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
    run --scenario synthetic-narrow-invalidation --modes async --iterations 20 --configuration release
done
```

Parse `place_ms` (column) from each run's `.perf/runs/<ts>/frames.tsv`, separating
the initial frame (frame 1, no reuse) from interaction frames (frame ≥ 2).

## Also discarded: Candidate A (per-node equality walk) — do not re-attempt

Replacing the sync with an equality walk that re-projects a
`PlacedNodeResolvedMetadata` per node was measured **ineffective** (it traded the
sync's children-array reallocation for two struct projections per node — a wash,
rows=40 `place_ms` unchanged). The win comes from *eliminating* the walk via the
fused `placementEquivalence` check, not from swapping one O(subtree) walk for
another. See the results report.
