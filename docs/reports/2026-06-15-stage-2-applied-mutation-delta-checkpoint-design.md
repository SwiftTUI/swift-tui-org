# Stage 2 Applied-Mutation Delta Checkpoint Design

- **Date:** 2026-06-15
- **Status:** Stage 2A shadow tracker complete; next implementation slice is
  guarded node-delta restore with the full checkpoint retained as oracle and
  fallback
- **Plan:** [`2026-06-14-003-frontier-publication-narrowing-plan.md`](../plans/2026-06-14-003-frontier-publication-narrowing-plan.md)
- **Baseline report:** [`2026-06-15-stage-2-checkpoint-scope-probe.md`](2026-06-15-stage-2-checkpoint-scope-probe.md)
- **Stage 2A report:** [`2026-06-15-stage-2a-shadow-delta-checkpoint-tracker.md`](2026-06-15-stage-2a-shadow-delta-checkpoint-tracker.md)
- **Reference code:** `swift-tui` `3348cae5` (`Instrument checkpoint scope candidates`)

## Decision

Implement Stage 2 as an applied-mutation delta checkpoint, not as a
dirty-frontier subtree checkpoint.

The first behavior-capable design should be a per-node mutation-generation
tracker owned by `ViewGraphFrameDraft`, with the existing full
`ViewGraph.Checkpoint` kept as the correctness oracle and runtime fallback. The
delta path must track the actual graph and node state mutated during frame-head
evaluation. It must not infer safety from dirty-frontier roots.

The implementation should land in slices:

1. **Stage 2A - shadow tracker:** record touched nodes, graph mutation epochs,
   and before/after node checkpoints next to the full checkpoint. Full
   checkpoints still drive behavior.
2. **Stage 2B - guarded node-delta restore:** allow prepared/baseline restore to
   use touched-node checkpoints only when the tracker proves complete coverage;
   fall back to full checkpoints on any ambiguity.
3. **Stage 2C - graph-field deltas:** split or delta graph maps/counters only
   after node-delta behavior is proven and diagnostics show graph field copying
   still matters.

## Why This Design

The Stage 2 scope probe showed that dirty-frontier subtree checkpointing does
not buy enough and is not safe for `.all` frames. On selective frames, the dirty
subtree candidate was already 94.3% of full prepared nodes for
`sheet-open-latency` and 98.5% for `synthetic-narrow-invalidation`; on `.all`
frames there is no safe dirty frontier at all.

The current rollback contract is total-state restore:

- `ViewGraph.makeCheckpoint()` captures graph fields plus all node checkpoints:
  `swift-tui/Sources/SwiftTUICore/Resolve/ViewGraph.swift`.
- `ViewGraph.restoreCheckpoint(_:)` restores graph maps, lifecycle/event state,
  invalidation state, dependency indexes, reuse cache, registration
  fingerprint, then every recorded node checkpoint.
- `ViewGraphCheckpointTotalityTests` intentionally makes this difficult to
  weaken.

Prepared graph state is also materialized more than once. It can be restored for
preview, commit, indexed-child source snapshotting, and late-preference
reconciliation, then suspended back to baseline. A partial restore that leaves
untracked mutated `ViewNode` fields behind would mix baseline and prepared graph
eras.

## Current Lifecycle Constraints

Abortable frame heads capture a baseline full graph checkpoint before dirty
evaluation, then record a prepared checkpoint after resolve:

- baseline capture:
  `swift-tui/Sources/SwiftTUIRuntime/Rendering/DefaultRendererFrameHeadCoordinator.swift`
- prepared capture:
  `swift-tui/Sources/SwiftTUICore/Resolve/ViewGraphFrameDraft.swift`
- materialize/suspend/discard:
  `swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameHeadDraftTransaction.swift`

The delta design must preserve these behaviors:

- `materializePreparedState()` restores prepared graph, frame state, and input
  state for preview/commit and layout-dependent work.
- `suspendPreparedState()` restores baseline graph, frame state, and input
  state while an async tail is running.
- `discard()` restores baseline and discards registration, portal,
  observation, and animation drafts.
- indexed-child snapshotting materializes the prepared graph, replaces
  main-actor-only sources with snapshots, records a newer prepared checkpoint,
  then suspends again.
- late-preference reconciliation can materialize prepared state during async
  layout, replace resolved tail input, record a newer prepared checkpoint, and
  suspend again.

The existing `stateMutationOverlay` remains mandatory. Live `@State` writes can
happen while a prepared async tail is suspended back to baseline. Those writes
must remain outside the frame-head delta and be reapplied through the overlay,
as they are today.

## Mutation Surface

A complete tracker must cover checkpointed graph fields and checkpointed node
fields.

Graph-level mutation categories:

- frame bookkeeping: current frame ID, frame order, lifecycle/task queues,
  latest lifecycle events, pending entity-routed removals;
- dirty and invalidation state: root-evaluation flag, invalidated nodes,
  graph-local dirty nodes, state-mutation keys and key-to-node indexes;
- graph identity and storage: root, node maps, identity maps, structural-path
  indexes, node-ID counter, entity-routing table;
- evaluators: root evaluator, evaluation-root identity, per-node evaluator
  slots;
- lifecycle owner and task maps;
- dependency indexes for state slots, environment, and observable reads;
- resolved-node reuse cache;
- commit-side publication state when a future slice includes finalize effects.

Node-level mutation categories:

- `prepareForFrame`, `beginEvaluation`, `finishEvaluation`;
- reuse and resolved-node application, including retained snapshots and
  resolved metadata refresh;
- state slot reads/writes, silent restores/resets, dependency tracker changes,
  and dirty flags;
- lifecycle state, pending change handlers, modifier ordinals, registered
  handlers, registration capture depth, registration mutation generation, and
  task descriptor state;
- lazy `snapshot()` paths that look read-like but can refresh committed state.

Known bypass risks:

- direct writes to fields such as `ownerGraph` and `parent`;
- value-type internal mutation in `EntityRoutingTable`;
- in-flight `DependencyTracker` mutation during reads before dependencies are
  copied onto the node;
- lazy snapshotting that mutates freshness/committed fields.

## Proposed Shape

Keep the public checkpoint behavior intact and add an internal storage choice
under the frame draft:

```swift
enum StoredGraphCheckpoint {
  case full(ViewGraph.Checkpoint)
  case delta(ViewGraphDeltaCheckpoint, fallback: ViewGraph.Checkpoint)
}
```

The exact type can change during implementation, but the semantics should be:

- baseline capture starts a mutation-tracking session and stores the full
  fallback checkpoint;
- the first mutation of a node records its baseline `ViewNode.Checkpoint`, adds
  the node ID to `touchedNodeIDs`, and bumps a checkpoint mutation generation;
- prepared capture stores prepared node checkpoints only for touched nodes;
- created and removed nodes are represented explicitly so baseline restore can
  remove new nodes and prepared restore can restore inserted nodes;
- graph fields initially remain full graph-field snapshots, while node
  checkpoints become delta-scoped;
- a graph mutation epoch detects untracked graph mutation or overlapping draft
  interference;
- restore baseline applies baseline graph fields and touched-node before images;
- restore prepared applies prepared graph fields and touched-node after images;
- full fallback is used whenever the tracker cannot prove total coverage.

Fallback conditions should include:

- mutation without an active before image;
- checkpoint mutation generation mismatch;
- graph mutation epoch mismatch;
- untracked graph-field touch;
- touched-node ratio above a configured budget;
- created/removed-node accounting mismatch;
- debug total-state mismatch in test/debug builds;
- any public render overlap or reentrancy that changes the graph outside the
  active draft's ownership.

## Deferred Alternatives

### Transaction-Local Mutation Log

A transaction log could record inverse operations for every graph and node
mutation, then replay inverses for baseline restore and forward operations for
prepared materialization. It has the best theoretical checkpoint-create cost,
but the operation-ordering risk is high around subtree removal, dependency
indexes, lifecycle queues, entity routing, and repeated materialize/suspend
cycles.

Use this only if generation-stamped before/after images prove too scattered to
maintain.

### Persistent Graph/State Split

The long-term endpoint is a split between immutable or copy-on-write graph
structure and mutable frame/app state, making checkpoints version handles rather
than object snapshots. That is the strongest architecture, but it is a larger
refactor than the next Stage 2 slice.

Treat it as a later graph-storage project, not the immediate implementation.

## Verification Plan

Keep the full checkpoint tests as-is. Add delta-specific guards rather than
weakening totality.

Focused graph tests:

- `deltaRestoreMatchesFullCheckpointAfterMixedGraphAndNodeMutations`
- `deltaPreparedRestoreMatchesFullCheckpointAfterMaterializeSuspendCycles`
- `untrackedDeltaMutationFallsBackToFullViewGraphCheckpoint`
- `appliedMutationTrackerCoversEveryCheckpointedMutableField`
- `untrackedCheckpointFieldForcesFullFallback`

Async/runtime tests:

- `preparedDeltaFrameHeadAbortRestoresTotalGraphState`
- `deltaFrameHeadMaterializeSuspendPreservesLiveStateMutations`
- `deltaPreparedVisualOnlyDropRestoresBaselineWithoutPublishing`
- coverage for indexed-child snapshot materialize/record/suspend
- coverage for late-preference prepared re-recording

State, dependency, lifecycle, and registration tests:

- `stateMutationOverlaySurvivesDeltaBaselineRestoreAfterSuspension`
- `deltaRollbackRevertsDependencyIndexRewrites`
- `deltaRollbackRevertsLifecycleQueuesAndRuntimeRegistrations`
- registry-family equivalence against full rebuild for the same families
  protected by Stage 1B.

Diagnostics should add TSV columns along these lines:

```text
runtime_graph_checkpoint_strategy
runtime_graph_delta_checkpoint_nodes
runtime_graph_delta_checkpoint_graph_fields
runtime_graph_checkpoint_fallback_reason
runtime_graph_checkpoint_fallback_count
```

Measure at least:

- `sheet-open-latency`;
- `synthetic-narrow-invalidation` with row sweeps;
- `layout-scroll-burst`;
- offscreen animation and continuous animation scenarios.

The win condition is lower graph checkpoint create/restore time and lower CPU
per diagnostic frame with unchanged frame counts, drop/cancel behavior,
publication diagnostics, and runtime correctness.

## Exit Criteria

Stage 2A is complete when the tracker can shadow the current full checkpoint
without behavior changes and tests prove the shadow state is equivalent to full
checkpoint restore across mixed graph/node mutation, materialize/suspend cycles,
and fallback paths.

Stage 2B is complete when guarded delta restore is enabled for proven frames,
falls back to full restore for every unproven case, and improves the hot
checkpoint columns without changing publication or async-frame semantics.
