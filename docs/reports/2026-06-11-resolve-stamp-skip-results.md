# Resolve Runtime-ID Stamp-Skip Results

- **Date:** 2026-06-11
- **Status:** Landed in `swift-tui@0b041764` (main, pushed).
- **Scope:** the residual-resolve design item from the
  [2026-06-10 assessment](../plans/2026-06-10-001-perf-workstream-assessment-next-wave-proposal.md)
  — a safe runtime-ID stamping fast path for freshly evaluated parents, the
  follow-on to the `8732c8d3` bisect and the `a93112b3` retained-root
  mitigation ([bisect report](2026-06-11-resolve-ms-regression-bisect.md)).

## Mechanism

On every interaction frame the head force-queues the presentation-portal root
dirty whenever `invalidatedIdentities` is non-empty
(`DefaultRendererFrameHeadCoordinator.swift:261-266`), so the whole tree
re-resolves top-down. Every freshly evaluated ancestor's
`ViewNode.apply` ran `resolvedWithRuntimeNodeIDs`, which recursively re-stamped
`viewNodeID` into **every descendant** of its resolved payload — a full
`ResolvedNode` struct copy plus child-array rebuild per node — including the
large reused regions handed back by value from `node.snapshot()`. With ~18
computed spine nodes over ~179/358 reused nodes, that is O(fresh-depth × tree)
pure bookkeeping per frame, the dominant share of the post-mitigation
`resolve_ms` slope.

## Design

`ResolvedNode` gains a derived cache Bool, `subtreeRuntimeNodeIDsStamped`:
true when the node and every descendant in `_storedChildren` carry a non-nil
`viewNodeID`. Maintained by both inits, the public `children` setter (riding
the existing 4-recompute discipline), and one shared
`recomputeSubtreeRuntimeNodeIDsStamped()` helper called at the three stamping
sites (`resolvedWithRuntimeNodeIDs` tail — **unconditionally**, so
Group-splice/count-mismatch parents still flip true; `applyRetainedSnapshot`;
the nested-depth root stamp in `resolveView`). The stamping walk early-returns
on fully stamped subtree values whose root stamp matches the live node.

Key properties, adversarially verified before implementation (3-agent panel,
all verdicts sound-with-fixes; all fixes incorporated):

- **Payloads are never substituted** — unlike the rejected `child.snapshot()`
  fast path (which severed the `refreshChildResolvedMetadata` →
  `committed.entityIdentity` → `prepareEntityRoutedOwner` sync loop and could
  wipe `@State` via `resetStateSlots()`), the skip leaves payload values
  byte-identical and only avoids redundant ID writes.
- **The flag tracks completeness by construction**, not by the walk's ability
  to verify it: root-stamp equality alone is provably insufficient
  (nested-depth returns stamp only the root; the count-mismatch guard skips
  whole levels), and an inline AnyView shell flips true via the recompute even
  where the pairing recursion cannot descend.
- **`==` exclusion costs zero code**: `ResolvedNode.==` is custom (forced by
  the existential `indexedChildSource`) and already excludes `viewNodeID`;
  every equivalence walk and test oracle is stamp-blind. Consequently the new
  tests compare stamps **explicitly** via a dedicated tree walker.
- **Checkpoints/drafts are safe**: the flag lives inside committed values,
  which checkpoint/restore atomically with the node-ID counter.
- **One real divergence seam survives**: the known divergent-resolvedIdentity
  capture-host orphaning bug (the planned **Part 0** fix). A stale interior
  under a matching root that today's walk incidentally repairs would be frozen
  by the skip — i.e. the skip widens an existing bug's blast radius on an
  already-broken seam rather than breaking a healthy path. Mitigation: a
  **debug-build stamp-coherence assertion** fires whenever a skip's subtree
  diverges from what the full walk would have written. The full repo gate ran
  green with the assertion active across the entire fixture corpus.
- The non-retained `recordReusedSubtree` branch (test-only reachability via
  `applySnapshot`) and the transition-overlay wrapper invariant violation
  (overlay trees never re-enter graph applies) are documented in-code.

## Measurements

Release `TermUIPerf`, same session, M5 Max; interaction frames (`frame > 1`),
20 iterations (narrow) / 10 iterations (sheet). Baseline `a93112b3`, after
`0b041764`.

### `synthetic-narrow-invalidation`

| rows | metric | before | after | delta |
| ---: | --- | ---: | ---: | ---: |
| 20 | resolve_ms | 1.198 | 1.017 | **−15.1%** |
| 20 | pipeline_ms | 3.816 | 3.601 | −5.6% |
| 20 | total CPU s/iter | 0.1717 ± 0.0039 | 0.1657 ± 0.0046 | **−3.5%** (t≈4.4) |
| 40 | resolve_ms | 1.973 | 1.574 | **−20.2%** |
| 40 | pipeline_ms | 6.149 | 5.700 | −7.3% |
| 40 | total CPU s/iter | 0.2606 ± 0.0074 | 0.2500 ± 0.0068 | **−4.1%** (t≈4.7) |

`resolved_computed`/`resolved_reused` identical before/after (18.2/178.8 and
19.4/357.6) — reuse semantics unchanged. Other phases flat (measure, place,
semantics, draw, raster, commit all within noise) — the win is genuine
elimination, not deferral into the unmeasured `viewGraph.snapshot()` (the
accounting trap from §3.5 of the assessment was checked via total CPU and the
head_* columns: head prepare 1.64→flat, 2.83→flat).

The win **grows with tree size** (−15→−20% resolve, −3.5→−4.1% CPU from rows
20→40), as predicted: the skipped work is O(reused subtree) per spine node.

### `sheet-open-latency` rows=176

Flat: resolve 17.284→16.673 ms (−3.5%), total CPU 1.8539→1.8399 (−0.8%,
t≈1.2, within noise), input p95 1698→1689 ms. Expected — sheet
transition/settle frames are dominated by genuine recompute (≈397 computed vs
230 reused per frame), which is exactly the §3.4 settle-frame violation that
Part 0 → Part A targets, not this change.

## Residual

After this change the remaining `resolve_ms` (1.017/1.574 ms at rows 20/40)
still scales with tree size at flat recompute. Per the understand-phase cost
ranking the next largest O(reused-subtree) terms inside `evaluateDirtyNodes`
are `restoreRuntimeRegistrations` (per-reuse-hit recursive walk with
structuralPath-keyed lookups, grown in `8732c8d3`) and the per-candidate
`reusableSnapshot` gates. A competing structural fix — narrowing the
force-queued portal-root frontier (`DefaultRendererFrameHeadCoordinator.swift:
261-266`) so interaction frames stop re-resolving the spine at all — was
identified but must be co-designed with the island freshness-cache hazard the
every-frame root walk currently masks; it is recorded in the assessment plan,
not attempted here.

## Verification

- TDD: 9-test `RuntimeNodeIDStampingTests` suite (flag maintenance at both
  inits and both child setters, full-tree stamping after graph applies,
  stamp-identity on re-apply of a stamped tree exercising the skip, the
  count-mismatch/Group-splice unconditional-recompute guard) — verified RED
  (missing member) before implementation, GREEN after.
- `ResolvedNodePhaseOwnershipTests` manifest extended
  (`subtreeRuntimeNodeIDsStamped` → `.derivedCache`).
- Targeted suites: RetainedSubtreeReuseTests, RetainedReuseInvariantTests,
  ViewGraphTests, ViewGraphCheckpointTotalityTests, ReaderAttributionTests,
  StructuralEquivalenceLockTests, RuntimeRegistrationRestoreScopingTests.
- Full repo gate (`bun run test`): PASS, with the debug stamp-coherence
  assertion live across the whole corpus.
- A/B artifacts: `/tmp/stamp-fastpath-ab/{before,after}/{rows-20,rows-40,sheet-176}`
  (ephemeral, not committed).
