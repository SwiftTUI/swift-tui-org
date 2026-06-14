# Stage 0 Frontier/Publication Inventory

- **Date:** 2026-06-14
- **Status:** Stage 0 complete; Stage 1A recommended next
- **Plan:** [`2026-06-14-003-frontier-publication-narrowing-plan.md`](../plans/2026-06-14-003-frontier-publication-narrowing-plan.md)
- **Measured code:** `swift-tui` `153edd93` (`Add publication diagnostics
  inventory hooks`)
- **Artifact root:** `/tmp/swifttui-stage0-publication-2026-06-14-220400`
- **Diagnostics gate:** `SWIFTTUI_PUBLICATION_DIAGNOSTICS=1`

## What Stage 0 Added

The landed probe is disabled by default and does not add public API. When the
environment gate is enabled, committed frame diagnostics now include:

- runtime-registration publication mode (`all`, `subtrees`, `unchanged`);
- dirty-plan result;
- invalidated identity counts and unmapped samples;
- scoped publication root count and restored node count;
- whether the presentation portal root was queued;
- graph checkpoint baseline/prepared node counts for abortable frame heads.

The TSV sink writes these fields as `runtime_publication_*` and
`runtime_graph_checkpoint_*` columns. With the gate off, the new columns stay
empty/defaulted and the existing diagnostic surface is unchanged.

## Commands

```bash
swiftly run swift build -c release --package-path Tools/TermUIPerf \
  --product termui-perf

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 \
Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario sheet-open-latency \
  --modes async \
  --iterations 8 \
  --artifacts-root /tmp/swifttui-stage0-publication-2026-06-14-220400

TERMUI_PERF_INVALIDATION_TREE_ROWS=40 \
SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 \
Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario synthetic-narrow-invalidation \
  --modes async \
  --iterations 20 \
  --artifacts-root /tmp/swifttui-stage0-publication-2026-06-14-220400
```

## Aggregate Metrics

Persisted aggregate JSON values:

| scenario | n | total CPU s | CPU s/committed frame | committed frames | diagnostic frames | cancelled frames | head prepare p50 ms | graph checkpoint create p50 ms | graph checkpoint restore p50 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| sheet-open-latency | 8 | 0.4603 | 0.0259 | 17.8 | 25.8 | 8.0 | 6.27 | 0.40 | 0.90 |
| synthetic-narrow-invalidation | 20 | 0.2581 | 0.0145 | 17.8 | 17.8 | 0.0 | 2.56 | 0.64 | 1.35 |

## Publication Breakdown

| scenario | TSV rows | completed rows | `.all` | `.subtrees` | no publication row | portal root queued | avg baseline graph nodes | avg prepared graph nodes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| sheet-open-latency | 206 | 142 | 78 | 64 | 64 | 142 | 238.0 | 251.4 |
| synthetic-narrow-invalidation | 356 | 356 | 56 | 300 | 0 | 356 | 352.5 | 373.6 |

No observed hot frame used `unchanged` publication in these scenarios.

## Ranked `.all` Causes

| scenario | dirty-plan result | frames | avg commit ms | avg restored nodes | est. commit ms |
| --- | --- | ---: | ---: | ---: | ---: |
| sheet-open-latency | `nil_unmapped_invalidated_identity` | 40 | 2.753 | 240.8 | 110.1 |
| sheet-open-latency | `nil_invalidated_nodes_not_graph_local_dirty` | 38 | 2.224 | 257.2 | 84.5 |
| synthetic-narrow-invalidation | `nil_invalidated_nodes_not_graph_local_dirty` | 36 | 2.938 | 373.0 | 105.8 |
| synthetic-narrow-invalidation | `nil_unmapped_invalidated_identity` | 20 | 3.037 | 373.0 | 60.7 |

Combined by cause:

| dirty-plan result | frames | est. commit ms |
| --- | ---: | ---: |
| `nil_invalidated_nodes_not_graph_local_dirty` | 74 | 190.3 |
| `nil_unmapped_invalidated_identity` | 60 | 170.9 |

For comparison, formed `.subtrees` frames were much cheaper:

| scenario | `.subtrees` frames | avg commit ms | avg restored nodes |
| --- | ---: | ---: | ---: |
| sheet-open-latency | 64 | 0.390 | 239.0 |
| synthetic-narrow-invalidation | 300 | 0.434 | 368.0 |

The scoped path still restores large subtrees in these workloads, but it avoids
the full live-registration reset/restore path and remains roughly 5-7x cheaper
than `.all` publication on the same node counts.

## Unmapped Samples

The capped samples identify presentation/portal-shaped identities, not random
application leaves:

| scenario | sample family | frames |
| --- | --- | ---: |
| sheet-open-latency | `App/sheet-open-latency` | 8 |
| sheet-open-latency | portal-hosted sheet body paths under `__TerminalUIPortalHost/...` | 32 |
| synthetic-narrow-invalidation | `App/synthetic-narrow-invalidation` | 20 |

Every completed row in both scenarios also had
`runtime_publication_portal_root_queued=1`, so portal/presentation queueing is
present across both observed `.all` buckets.

## Interpretation

Stage 0 did not show root-evaluation-required frames as the hot cause. The
dominant `.all` buckets are dirty-plan formation failures:

1. identities that map to graph nodes but are not graph-local dirty; and
2. presentation/portal identities that do not map back to a graph node.

Those are Stage 1A-shaped problems. The next behavior PR should narrow the
presentation/portal invalidation bridge so safe identities become graph-local
dirty frontier inputs instead of poisoning the selective plan. Keep the `.all`
fallback for genuinely unknown roots, and re-run this exact inventory before
moving to checkpoint narrowing.

Stage 1B (making unavoidable `.all` publication cheaper) is not the first move:
this run did not prove that the high-volume `.all` frames are legitimate root
publication frames. It remains a fallback if Stage 1A leaves a stable
root-required bucket.

## Validation

From `swift-tui`:

```bash
swiftly run swift test --filter 'ViewGraphTests|TSVFileSinkTests' --jobs 4

swiftly run swift test --filter RuntimeRegistrationRestoreScopingTests --jobs 1
swiftly run swift test --filter FrameResolveStateTests --jobs 1
swiftly run swift test --filter StateInvalidationDependencyTests --jobs 1
swiftly run swift test --filter BindingDependencyModelTests --jobs 1
swiftly run swift test --filter DependencyModelTests --jobs 1
swiftly run swift test --filter ResolveReuseAncestorInvalidationTests --jobs 1
swiftly run swift test --filter FrameSchedulerIntentCoalescingTests --jobs 1
swiftly run swift test --filter TransactionSnapshotTests --jobs 1
swiftly run swift test --filter AsyncFrameTailRenderingTests --jobs 1
swiftly run swift test --filter PipelineContractTests --jobs 1
swiftly run swift test --filter TabTaskActivationRuntimeTests --jobs 1
swiftly run swift test --filter AnimationRepeatForeverGrowthTests --jobs 1

./Scripts/generate_public_api_inventory.sh --check
./Scripts/check_concurrency_safety_policies.sh
```

All listed checks passed. A combined multi-suite Swift Testing filter crashed
`swiftpm-testing-helper` with signal 11 before any assertion; the same suites
passed when run serially by suite.
