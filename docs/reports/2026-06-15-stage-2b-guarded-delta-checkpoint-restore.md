# Stage 2B Guarded Delta Checkpoint Restore

- **Date:** 2026-06-15
- **Status:** Stage 2B budgeted delta restore complete; next decision slice is
  Stage 2C graph-field/checkpoint-create deltas
- **Plan:** [`2026-06-14-003-frontier-publication-narrowing-plan.md`](../plans/2026-06-14-003-frontier-publication-narrowing-plan.md)
- **Design:** [`2026-06-15-stage-2-applied-mutation-delta-checkpoint-design.md`](2026-06-15-stage-2-applied-mutation-delta-checkpoint-design.md)
- **Stage 2A report:** [`2026-06-15-stage-2a-shadow-delta-checkpoint-tracker.md`](2026-06-15-stage-2a-shadow-delta-checkpoint-tracker.md)
- **Implemented code:** `swift-tui` `6b971435` (`Guard delta checkpoint
  restores`) plus budgeted-delta/no-op-overlay follow-up in the current working
  tree

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
- a draft-owned current-source mutation state so repeated materialize/suspend
  cycles that preserve live `@State` mutation overlays can keep using the
  guarded delta path instead of falling back after the first overlay restore;
- touched before/after node checkpoint payloads in
  `ViewGraphDeltaCheckpointShadow`;
- full fallback reasons for missing prepared checkpoints, source checkpoint
  mismatch, incomplete touched checkpoint payloads, near-full delta budget
  exhaustion, and debug-oracle mismatch;
- no-op state-mutation overlays are skipped instead of recording an empty graph
  mutation during restore, preserving abort purity and avoiding useless
  checkpoint-generation churn;
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

The existing non-empty `stateMutationOverlay` behavior is preserved around both
delta and full restores, so live state writes that occur while an async frame
tail is suspended remain outside the frame-head checkpoint and are reapplied
afterward.

The final follow-up also adds a touched-node budget: for non-trivial graphs, the
delta path is skipped when it would replay more than 70% of the full checkpoint's
node payloads. This keeps near-full restore frames on the full path, where a
single full checkpoint replay is cheaper than proving and replaying a large
delta.

## Final Budgeted-Delta Measurement

- **Baseline artifact root:**
  `/tmp/swifttui-stage2b-measure-2026-06-15-132146-6b971435`
- **Final artifact root:**
  `/tmp/swifttui-stage2b-budgeted-delta-noop-overlay-2026-06-15-140523-6b971435-wt`
- **Code measured:** `swift-tui` `6b971435` plus the budgeted-delta/no-op-overlay
  working-tree follow-up

The first measurement showed the Stage 2B path was present but not effective in
release perf: every measured restore fell back with
`current_checkpoint_mismatch`. The follow-up records the draft's current
mutation-state source after each restore plus preserved state overlay, then uses
that state for the next guarded proof.

Final restore-strategy split:

| scenario | strategy | fallback reason | frames |
| --- | --- | --- | ---: |
| `sheet-open-latency` | - | - | 63 |
| `sheet-open-latency` | `delta_node` | - | 31 |
| `sheet-open-latency` | `full_fallback` | `delta_node_budget_exceeded` | 112 |
| `synthetic-narrow-invalidation` | `delta_node` | - | 337 |
| `synthetic-narrow-invalidation` | `full_fallback` | `delta_node_budget_exceeded` | 20 |

Aggregate median comparison:

| scenario | stage | total CPU s | CPU s/frame | input p95 ms | head prepare p50 ms | checkpoint create p50 ms | checkpoint restore p50 ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `sheet-open-latency` | prior Stage 2B | 0.5016 | 0.02822 | 448.21 | 7.89 | 1.13 | 1.50 |
| `sheet-open-latency` | budgeted delta | 0.4877 | 0.02729 | 434.16 | 7.68 | 1.20 | 0.89 |
| `synthetic-narrow-invalidation` | prior Stage 2B | 0.2569 | 0.01432 | 201.80 | 2.95 | 0.97 | 1.21 |
| `synthetic-narrow-invalidation` | budgeted delta | 0.2503 | 0.01402 | 195.11 | 2.95 | 1.12 | 0.56 |

The safe conclusion is that budgeted delta restore captures the node-restore
win without regressing near-full restore frames. Checkpoint creation is now the
larger remaining Stage 2 target in both measured scenarios.

## Validation

From `swift-tui`:

```bash
swiftly run swift test --filter 'ViewGraphDeltaCheckpointShadowTests|ViewGraphCheckpointTotalityTests|RuntimeRegistrationRestoreScopingTests|ViewGraphTests|FrameResolveStateTests|TSVFileSinkTests|ResolvePurityTests' --jobs 1

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 \
  swiftly run swift test --filter 'AsyncFrameTailRenderingTests' --jobs 1

swiftly run swift test --filter 'AsyncFrameTailRenderingTests' --jobs 1

./Scripts/check_concurrency_safety_policies.sh
./Scripts/generate_public_api_inventory.sh --check

swiftly run swift build -c release --package-path Tools/TermUIPerf --product termui-perf
```

Results:

- focused graph/diagnostics/purity suite: 58 tests passed;
- diagnostics-enabled async suite: 54 tests passed;
- diagnostics-disabled async suite: 54 tests passed;
- concurrency policy check: passed;
- public API inventory: baseline current, 739 top-level public symbols;
- `termui-perf` release build: passed.
- `bun run test` was attempted after the child changes. It still fails in the
  SwiftTUI runtime shard on
  `PreferenceSurfaceTests/resolveReuseReplaysStablePreferenceObserversForReusedSubtrees`;
  that focused test also fails on a clean `swift-tui` `6b971435` worktree, so it
  is not a regression from this follow-up.

Notes:

- The release perf build emitted existing unused-import warnings in
  `PresentationTriggerLeaf.swift` and `ProfiledMemoryAccess.swift`.

## Next

Stage 2C should focus on checkpoint creation and graph-field copying, not more
node restore specialization. The final Stage 2B data shows restore cost dropped
materially, while `head_graph_checkpoint_create_p50_ms` is still about 1.1-1.2
ms in both hot scenarios.
