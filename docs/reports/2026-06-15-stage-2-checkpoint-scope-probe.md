# Stage 2 Checkpoint Scope Probe

- **Date:** 2026-06-15
- **Status:** Stage 2 probe complete; do not implement dirty-frontier subtree
  checkpointing as the behavior slice
- **Plan:** [`2026-06-14-003-frontier-publication-narrowing-plan.md`](../plans/2026-06-14-003-frontier-publication-narrowing-plan.md)
- **Measured code:** `swift-tui` `3348cae5` (`Instrument checkpoint scope candidates`)
- **Artifact root:** `/tmp/swifttui-stage2-scope-probe-2026-06-15-1058-c03edf38`
- **Diagnostics gate:** `SWIFTTUI_PUBLICATION_DIAGNOSTICS=1`

## What Changed

This is a diagnostic-only Stage 2 probe. It keeps the existing full
`ViewGraph.Checkpoint` create/restore behavior unchanged, then records one new
TSV column:

```text
runtime_graph_checkpoint_dirty_subtree_candidate_nodes
```

The column reports how many nodes are under the accepted dirty-frontier
subtrees when the frame has a formed selective plan. It is `-` for `.all`
fallback frames and `0` for unchanged frames. This sizes the simplest possible
Stage 2 behavior slice: checkpoint only dirty-frontier subtrees.

## Commands

From `swift-tui`:

```bash
swift test --filter 'ViewGraphCheckpointTotalityTests|RuntimeRegistrationRestoreScopingTests|ViewGraphTests|FrameResolveStateTests|TSVFileSinkTests' --jobs 1

./Scripts/check_concurrency_safety_policies.sh
./Scripts/generate_public_api_inventory.sh --check

swift build -c release --package-path Tools/TermUIPerf --product termui-perf

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 \
  Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario sheet-open-latency \
  --modes async \
  --iterations 8 \
  --artifacts-root /tmp/swifttui-stage2-scope-probe-2026-06-15-1058-c03edf38

TERMUI_PERF_INVALIDATION_TREE_ROWS=40 \
SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 \
  Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario synthetic-narrow-invalidation \
  --modes async \
  --iterations 20 \
  --artifacts-root /tmp/swifttui-stage2-scope-probe-2026-06-15-1058-c03edf38
```

## Scope Sizing

| scenario | mode | frames | full prepared nodes | dirty-subtree candidate nodes | candidate/full |
| --- | --- | ---: | ---: | ---: | ---: |
| `sheet-open-latency` | `.all` | 80 | 19,939 | n/a | n/a |
| `sheet-open-latency` | `.subtrees` | 64 | 16,219 | 15,296 | 94.3% |
| `synthetic-narrow-invalidation` | `.all` | 54 | 20,176 | n/a | n/a |
| `synthetic-narrow-invalidation` | `.subtrees` | 300 | 112,060 | 110,400 | 98.5% |

Across all checkpointed frames, the candidate column is 42.3% of full prepared
nodes for `sheet-open-latency` and 83.5% for `synthetic-narrow-invalidation`,
but that aggregate is misleading: the apparent sheet reduction comes from
`.all` frames where the dirty frontier is unknown and the candidate is not a
safe checkpoint scope.

## Aggregate Timings

| scenario | total CPU s | CPU s/frame | input p95 ms | head prepare p50 ms | checkpoint create p50 ms | checkpoint restore p50 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `sheet-open-latency` | 0.5153 | 0.02863 | 459.91 | 7.37 | 0.47 | 1.05 |
| `synthetic-narrow-invalidation` | 0.2836 | 0.01589 | 224.91 | 2.84 | 0.72 | 1.50 |

## Decision

Do not implement a partial `ViewGraph.Checkpoint` that merely omits
`nodeCheckpoints` outside the dirty-frontier subtrees.

Reasons:

- The current `ViewGraph.Checkpoint` is a total-state rollback contract, and
  `ViewGraphCheckpointTotalityTests` intentionally enforce that every mutable
  graph and node field is covered.
- Prepared graph state can be materialized after suspension for preview,
  commit, indexed-child snapshotting, and late-preference reconciliation. A
  partial prepared restore could mix older graph maps with newer uncheckpointed
  `ViewNode` fields unless the runtime can prove those fields were not mutated.
- On frames where the dirty frontier is known, the candidate subtree is already
  nearly the full graph in both hot scenarios, so the simplest scope would not
  buy enough to justify the rollback risk.
- On the remaining `.all` frames, the dirty frontier is unavailable by
  definition, so dirty-subtree scoping cannot address the checkpoint cost that
  remains visible after Stage 1B.

The next Stage 2 behavior slice should keep the total checkpoint as the
fallback and introduce a distinct delta checkpoint representation only after it
can prove the applied mutation set. Plausible directions are:

- per-node checkpoint mutation generations that increment from every
  checkpoint-covered `ViewNode` mutator;
- a transaction-local graph mutation log for changed node IDs plus changed
  graph maps/counters;
- splitting identity-stable graph structure from mutable per-frame node state
  so unmodified ranges are immutable/shared rather than mutable objects left
  behind by a partial restore.

Until one of those proofs exists, full graph checkpoints remain the correct
behavior for abortable frame heads.

## Validation

- `swift test --filter 'ViewGraphCheckpointTotalityTests|RuntimeRegistrationRestoreScopingTests|ViewGraphTests|FrameResolveStateTests|TSVFileSinkTests' --jobs 1`
- `./Scripts/check_concurrency_safety_policies.sh`
- `./Scripts/generate_public_api_inventory.sh --check`
- `swift build -c release --package-path Tools/TermUIPerf --product termui-perf`
- perf probe commands listed above
