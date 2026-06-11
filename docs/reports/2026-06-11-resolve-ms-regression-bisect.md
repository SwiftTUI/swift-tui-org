# Resolve_ms Regression Bisect

- **Date:** 2026-06-11
- **Status:** Bisect complete; retained-root mitigation landed in
  `swift-tui@a93112b3`.
- **Scope:** `synthetic-narrow-invalidation`, release `TermUIPerf`, interaction
  frames only (`frame > 1`).

## Finding

The first durable `resolve_ms` jump in the 0.0.19 window is
`swift-tui@8732c8d3` (`Split runtime identity to view node IDs`). The last low
boundary before it is `f47c08af`.

The jump did not change reuse rates. The row-40 confirmation run kept
`resolved_computed` / `resolved_reused` at `19.4 / 357.6`, while `resolve_ms`
rose from `1.178` to `1.970`. That points to bookkeeping cost on retained or
reused nodes, not a fallback to recomputation.

## Boundary Evidence

20 iterations per row count, same session:

| commit | rows | resolve_ms | measure_ms | place_ms | draw_ms | total_ms | computed | reused | note |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `f47c08af` | 20 | 0.783 | 0.519 | 0.392 | 0.133 | 3.117 | 18.2 | 178.8 | last low |
| `f47c08af` | 40 | 1.178 | 0.931 | 0.704 | 0.260 | 4.937 | 19.4 | 357.6 | last low |
| `8732c8d3` | 20 | 1.207 | 0.531 | 0.411 | 0.140 | 3.554 | 18.2 | 178.8 | first durable high |
| `8732c8d3` | 40 | 1.970 | 0.960 | 0.745 | 0.267 | 5.747 | 19.4 | 357.6 | first durable high |

Several commits between the two boundaries needed a temporary compile shim for
current Swift because `SemanticSnapshot.ScrollRoute` had a historical
self-assignment initializer bug. The shim was used only in the `/tmp` bisect
worktree and was not committed.

## Mechanism

`8732c8d3` introduced runtime `ViewNodeID` stamping into `ResolvedNode`
snapshots. The retained-subtree path still called the general apply helper:

1. `ViewGraph.recordReusedSubtree(... retained: true)` accepted a disjoint
   retained snapshot.
2. It called `applyResolvedNode(node, resolved: subtree, children: node.children)`.
3. `ViewNode.apply` called `resolvedWithRuntimeNodeIDs` before its
   same-children fast path.
4. `resolvedWithRuntimeNodeIDs` recursively stamped every descendant.

That defeated the H3 retained-subtree recursion skip for the retained root.

## Shipped Mitigation

`swift-tui@a93112b3` adds `ViewNode.applyRetainedSnapshot(_:)` and routes only
the retained branch through it. The method stamps the retained root's
`viewNodeID`, commits the snapshot, marks it fresh, and invalidates ancestor
cached snapshots without descending into the retained children.

Current-head same-session A/B:

| rows | before resolve_ms | after resolve_ms | delta | computed/reused |
| ---: | ---: | ---: | ---: | --- |
| 20 | 1.351 | 1.173 | -13.2% | 18.2 / 178.8 |
| 40 | 2.252 | 1.895 | -15.9% | 19.4 / 357.6 |

The fixed run artifacts are under
`/tmp/swift-tui-resolve-runs-head-final`. The baseline artifacts are under
`/tmp/swift-tui-resolve-runs-head-before`.

## Rejected Broader Change

Moving the same-children fast path ahead of runtime-ID stamping inside the
general `ViewNode.apply` was not safe. Freshly evaluated parents can see the
same child node objects before those child nodes hold the new resolved child
payload; substituting `child.snapshot()` there caused the scenario to stop
advancing after three frames and time out waiting for marker `count 1`.

The remaining `resolve_ms` slope is therefore not an open bisect item. It is a
design task: create a safe runtime-ID stamping fast path for freshly evaluated
parents, with explicit ordering proof, or size a different resolve residual.

## Verification

- `swift format format -i --configuration .swift-format.json
  Sources/SwiftTUICore/Resolve/ViewNode.swift
  Sources/SwiftTUICore/Resolve/ViewGraph.swift`
- `swiftly run swift test --filter RetainedSubtreeReuseTests`
- `swiftly run swift test --filter RetainedReuseInvariantTests`
- `swiftly run swift test --filter Phase1BenchmarkScenariosTests`
- `swiftly run swift test --filter TimingDiagnosticsTests`
- `swiftly run swift test --filter TSVFileSinkTests`
- `swiftly run swift test --filter ProfileActivationTests`
- `bun run test`
