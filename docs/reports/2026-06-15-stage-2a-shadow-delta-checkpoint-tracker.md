# Stage 2A Shadow Delta Checkpoint Tracker

- **Date:** 2026-06-15
- **Status:** Stage 2A complete; next behavior slice is Stage 2B guarded
  node-delta restore
- **Plan:** [`2026-06-14-003-frontier-publication-narrowing-plan.md`](../plans/2026-06-14-003-frontier-publication-narrowing-plan.md)
- **Design:** [`2026-06-15-stage-2-applied-mutation-delta-checkpoint-design.md`](2026-06-15-stage-2-applied-mutation-delta-checkpoint-design.md)
- **Implemented code:** `swift-tui` `bc9d11a6` (`Instrument shadow delta checkpoints`)
- **Perf smoke artifact root:**
  `/tmp/swifttui-stage2a-shadow-2026-06-15-1242-bc9d11a6`

## What Changed

Stage 2A keeps the existing full `ViewGraph.Checkpoint` as the only behavior
path, then adds an opt-in shadow tracker behind publication diagnostics.

The child implementation adds:

- `ViewGraph.checkpointMutationEpoch`, checkpointed and debug-snapshotted with
  graph state;
- `ViewNode.checkpointMutationGeneration`, checkpointed and debug-snapshotted
  with node state;
- mutation-generation bumps on checkpoint-covered graph and node mutation
  seams;
- `ViewGraphDeltaCheckpointShadow`, which compares baseline and prepared
  checkpoint generations to report touched, created, and removed node IDs;
- TSV diagnostics columns:
  `runtime_graph_checkpoint_strategy`,
  `runtime_graph_delta_checkpoint_nodes`,
  `runtime_graph_delta_checkpoint_created_nodes`,
  `runtime_graph_delta_checkpoint_removed_nodes`, and
  `runtime_graph_delta_checkpoint_epoch_delta`.

The shadow is diagnostics-gated. Normal runtime frames do not allocate the
shadow tracker unless `SWIFTTUI_PUBLICATION_DIAGNOSTICS=1` is enabled or tests
opt in through `ViewGraphFrameDraft(publicationDiagnosticsEnabled: true)`.

## Boundary

This is intentionally not a behavior change. Baseline and prepared materialize,
suspend, discard, and commit still restore from full checkpoints. The shadow
only sizes the future delta restore candidate and keeps the full checkpoint as
oracle/fallback for Stage 2B.

Stage 2A does not retain touched before/after checkpoint payloads in the shadow.
It reports IDs and counts only; the existing full baseline/prepared checkpoints
remain the authoritative before/after images. This avoids adding extra retained
graph payloads to default async frames while still exposing the applied mutation
set needed for Stage 2B design.

## Validation

From `swift-tui`:

```bash
swift package clean && swift test --filter 'AsyncFrameTailRenderingTests' --jobs 1

swift test --filter 'ViewGraphDeltaCheckpointShadowTests|ViewGraphCheckpointTotalityTests|RuntimeRegistrationRestoreScopingTests|ViewGraphTests|FrameResolveStateTests|TSVFileSinkTests' --jobs 1

./Scripts/check_concurrency_safety_policies.sh
./Scripts/generate_public_api_inventory.sh --check

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 \
  swift test --filter 'AsyncFrameTailRenderingTests' --jobs 1

swift package --package-path Tools/TermUIPerf clean
swift build -c release --package-path Tools/TermUIPerf --product termui-perf

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 \
  Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario synthetic-narrow-invalidation \
  --modes async \
  --iterations 2 \
  --artifacts-root /tmp/swifttui-stage2a-shadow-2026-06-15-1242-bc9d11a6
```

Notes:

- The first incremental async shard hit a `swiftpm-testing-helper` signal 11
  while destroying `FrameArtifacts`; a clean package rebuild made the same
  diagnostics-enabled and diagnostics-disabled async shards pass. Treat this as
  stale incremental build state after package-internal layout/source-list
  changes, not a runtime regression.
- The nested `Tools/TermUIPerf` package needed its own `swift package clean`
  before it saw the newly added source file from the path dependency.
- The perf smoke is not a Stage 2 performance decision run. It only verifies
  that real runtime artifacts now include the new Stage 2A columns.

## Next

Stage 2B should use the Stage 2A mutation summaries to implement guarded
touched-node restore, with full checkpoint fallback on any unproven frame. Keep
the existing totality tests, add delta-vs-full equivalence tests, and only then
rerun the broader perf scenarios from the Stage 2 design report.
