# Stage 2B Guarded Delta Checkpoint Restore

- **Date:** 2026-06-15
- **Status:** Stage 2B complete; next decision slice is Stage 2C graph-field
  deltas after perf measurement
- **Plan:** [`2026-06-14-003-frontier-publication-narrowing-plan.md`](../plans/2026-06-14-003-frontier-publication-narrowing-plan.md)
- **Design:** [`2026-06-15-stage-2-applied-mutation-delta-checkpoint-design.md`](2026-06-15-stage-2-applied-mutation-delta-checkpoint-design.md)
- **Stage 2A report:** [`2026-06-15-stage-2a-shadow-delta-checkpoint-tracker.md`](2026-06-15-stage-2a-shadow-delta-checkpoint-tracker.md)
- **Implemented code:** `swift-tui` `6b971435` (`Guard delta checkpoint restores`)

## What Changed

Stage 2B turns the Stage 2A shadow tracker into a guarded behavior path for
node checkpoint replay. The full `ViewGraph.Checkpoint` remains the source of
truth for graph fields and the fallback restore path.

The child implementation adds:

- a guarded `ViewGraph.restoreCheckpoint(_:nodeCheckpoints:)` path that restores
  graph fields from the target checkpoint, then replays only proven touched node
  checkpoints;
- `ViewGraph.checkpointMutationStateMatches(_:)`, which validates source graph
  epoch, node ID set, and per-node checkpoint mutation generations before a
  delta restore is allowed;
- touched before/after node checkpoint payloads in
  `ViewGraphDeltaCheckpointShadow`;
- full fallback reasons for missing prepared checkpoints, source checkpoint
  mismatch, incomplete touched checkpoint payloads, and debug-oracle mismatch;
- restore diagnostics on the runtime publication record and TSV output:
  `runtime_graph_checkpoint_restore_strategy`,
  `runtime_graph_checkpoint_restore_fallback_reason`,
  `runtime_graph_checkpoint_delta_restore_count`, and
  `runtime_graph_checkpoint_fallback_restore_count`;
- `hasStaleIslandDescendant` coverage in the debug total-state node snapshot so
  the delta-vs-full oracle covers that checkpointed node field.

## Boundary

Stage 2B does not delta graph maps, counters, indexes, lifecycle queues, or
dependency indexes. Those fields are still assigned from the target full graph
checkpoint on every restore. The optimization is limited to replaying touched
node checkpoint payloads when the current graph exactly matches the expected
source checkpoint.

Created and removed nodes are represented through the target graph checkpoint's
node map plus touched before/after payloads:

- baseline restore replays common mutated nodes and nodes removed from the
  prepared graph;
- prepared restore replays common mutated nodes and nodes created in the
  prepared graph;
- nodes that do not exist in the target graph checkpoint are not replayed.

In `DEBUG` builds, the delta path captures a total-state snapshot after the
delta restore, then performs a full restore to the same target and compares the
snapshots. A mismatch records `debug_oracle_mismatch` and leaves the graph
full-restored. In release builds, a proven delta restore remains the final graph
state.

The existing `stateMutationOverlay` behavior is preserved around both delta and
full restores, so live state writes that occur while an async frame tail is
suspended remain outside the frame-head checkpoint and are reapplied afterward.

## Validation

From `swift-tui`:

```bash
swift test --filter 'ViewGraphDeltaCheckpointShadowTests|ViewGraphCheckpointTotalityTests|RuntimeRegistrationRestoreScopingTests|ViewGraphTests|FrameResolveStateTests|TSVFileSinkTests' --jobs 1

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 \
  swift test --filter 'AsyncFrameTailRenderingTests' --jobs 1

swift test --filter 'AsyncFrameTailRenderingTests' --jobs 1

./Scripts/check_concurrency_safety_policies.sh
./Scripts/generate_public_api_inventory.sh --check

swift build -c release --package-path Tools/TermUIPerf --product termui-perf
```

Results:

- focused graph/diagnostics suite: 55 tests passed;
- diagnostics-enabled async suite: 54 tests passed;
- diagnostics-disabled async suite: 54 tests passed;
- concurrency policy check: passed;
- public API inventory: baseline current, 739 top-level public symbols;
- `termui-perf` release build: passed.

Notes:

- An earlier incremental async shard hit a `swiftpm-testing-helper` signal 11
  in `swift_release` while destroying frame artifacts. A clean package rebuild
  made the same single async test pass before the final Stage 2B validation, and
  both full async shards passed afterward.
- The release perf build emitted existing unused-import warnings in
  `PresentationTriggerLeaf.swift` and `ProfiledMemoryAccess.swift`.

## Next

Stage 2C should be a measurement decision, not an automatic implementation
step. The Stage 2B runtime columns can now separate delta node restores from
full fallbacks. Use them to decide whether full graph-field assignment remains
hot enough to justify graph-field deltas.
