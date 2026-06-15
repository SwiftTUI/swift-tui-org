# Stage 1A Frontier/Publication Narrowing

- **Date:** 2026-06-15
- **Status:** Stage 1A identity bridge landed; selective-gate attribution next
- **Plan:** [`2026-06-14-003-frontier-publication-narrowing-plan.md`](../plans/2026-06-14-003-frontier-publication-narrowing-plan.md)
- **Measured code:** `swift-tui` `294b2404` (`perf: translate portal invalidations before dirty planning`)
- **Artifact root:** `/tmp/swifttui-stage1a-publication-2026-06-15-0544`
- **Diagnostics gate:** `SWIFTTUI_PUBLICATION_DIAGNOSTICS=1`

## What Changed

`DefaultRendererFrameHeadCoordinator` now translates presentation-portal
invalidations before storing frame resolve inputs. The translation is deliberately
narrow:

- already graph-owned identities are preserved;
- stale active overlay-entry descendants map to the nearest graph-owned overlay
  subtree, entry, overlay host, or portal root;
- slash-flattened entry paths are normalized through active presentation entries;
- unknown presentation-like identities remain unmapped.

The same patch also fixes diagnostics for frames where `FrameResolveState`
already disabled selective evaluation. Those frames now report
`nil_selective_evaluation_disabled` instead of falling through to the misleading
`nil_invalidated_nodes_not_graph_local_dirty` bucket.

## Commands

From `swift-tui`:

```bash
swift test --filter ViewGraphTests

swift test --filter RuntimeRegistrationRestoreScopingTests --jobs 1
swift test --filter FrameResolveStateTests --jobs 1
swift test --filter StateInvalidationDependencyTests --jobs 1
swift test --filter BindingDependencyModelTests --jobs 1
swift test --filter DependencyModelTests --jobs 1
swift test --filter ResolveReuseAncestorInvalidationTests --jobs 1
swift test --filter FrameSchedulerIntentCoalescingTests --jobs 1
swift test --filter TransactionSnapshotTests --jobs 1
swift test --filter AsyncFrameTailRenderingTests --jobs 1
swift test --filter PipelineContractTests --jobs 1
swift test --filter TabTaskActivationRuntimeTests --jobs 1
swift test --filter AnimationRepeatForeverGrowthTests --jobs 1

./Scripts/generate_public_api_inventory.sh --check
./Scripts/check_concurrency_safety_policies.sh
```

Performance inventory:

```bash
swift build -c release --package-path Tools/TermUIPerf --product termui-perf

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 \
Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario sheet-open-latency \
  --modes async \
  --iterations 8 \
  --artifacts-root /tmp/swifttui-stage1a-publication-2026-06-15-0544

TERMUI_PERF_INVALIDATION_TREE_ROWS=40 \
SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 \
Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario synthetic-narrow-invalidation \
  --modes async \
  --iterations 20 \
  --artifacts-root /tmp/swifttui-stage1a-publication-2026-06-15-0544
```

## Aggregate Metrics

| scenario | n | total CPU s | CPU s/committed frame | committed frames | diagnostic frames | cancelled frames | head prepare p50 ms | graph checkpoint create p50 ms | graph checkpoint restore p50 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| sheet-open-latency | 8 | 0.5060 | 0.0282 | 18.0 | 26.0 | 8.0 | 6.78 | 0.41 | 0.90 |
| synthetic-narrow-invalidation | 20 | 0.2604 | 0.0145 | 18.0 | 18.0 | 0.0 | 2.50 | 0.63 | 1.31 |

## Publication Breakdown

| scenario | TSV rows | publication rows | `.all` | `.subtrees` | no publication row | portal root queued |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| sheet-open-latency | 206 | 142 | 78 | 64 | 64 | 142 |
| synthetic-narrow-invalidation | 352 | 352 | 52 | 300 | 0 | 352 |

## Ranked `.all` Causes

| scenario | dirty-plan result | frames | avg commit ms | avg restored nodes |
| --- | --- | ---: | ---: | ---: |
| sheet-open-latency | `nil_selective_evaluation_disabled` | 78 | 2.470 | 248.8 |
| synthetic-narrow-invalidation | `nil_selective_evaluation_disabled` | 52 | 2.933 | 373.0 |

For comparison, formed `.subtrees` frames stayed in the established cheaper
path:

| scenario | `.subtrees` frames | avg commit ms | avg restored nodes |
| --- | ---: | ---: | ---: |
| sheet-open-latency | 64 | 0.395 | 239.0 |
| synthetic-narrow-invalidation | 300 | 0.426 | 368.0 |

## Interpretation

Stage 1A removed the portal-hosted unmapped-identity bucket from the sheet-open
inventory. The Stage 0 report saw 32 sheet frames with unmapped samples under
`__TerminalUIPortalHost/...`; this run has none. The only remaining unmapped
samples are application-root shaped:

| scenario | sample | frames |
| --- | --- | ---: |
| sheet-open-latency | `App/sheet-open-latency` | 8 |
| synthetic-narrow-invalidation | `App/synthetic-narrow-invalidation` | 20 |

The behavior PR therefore lands the safe identity-translation half of Stage 1A,
but it does **not** reduce `.all` frame share. The remaining `.all` frames are
now explicitly caused by `FrameResolveState` disabling selective evaluation
before the graph planner runs. Forcing those frames into
`invalidateAndQueueDirty` would bypass the root-evaluation guards for focus,
pressed, proposal, root-invalidation, and explicit force-root frames, so that is
not part of this safe identity bridge.

## Next Slice

Do a small Stage 1A.2 attribution pass before choosing Stage 1B:

1. Record which `FrameResolveState` gate disabled selective evaluation on each
   `nil_selective_evaluation_disabled` frame.
2. If the dominant gate is presentation-specific and can prove a graph-owned
   frontier, narrow that gate and re-run this inventory.
3. If the dominant gate is legitimate root evaluation, switch to Stage 1B and
   make unavoidable `.all` publication cheaper instead of pretending it is
   frontier-scoped.

## Validation

All listed package suites passed. The public API baseline check passed with 739
top-level public symbols. The concurrency-safety policy check passed.
