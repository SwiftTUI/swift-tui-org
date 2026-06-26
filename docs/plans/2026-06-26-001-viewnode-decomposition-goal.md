# Goal: ViewNode field decomposition

| | |
|---|---|
| **Date** | 2026-06-26 |
| **Status** | **Done (2026-06-26)** — four cohesive sub-structs landed across five gate-green commits (`018c8f3b`→`8b59f095` on `swift-tui` `main`). See [Outcome](#outcome-2026-06-26). |
| **Scope** | `SwiftTUICore/Resolve/ViewNode.swift` (the persistent reconciliation node) |
| **Tracks** | [`#10` in the architecture-fragility proposal](../proposals/2026-06-26-001-architecture-fragility-improvements-proposal.md) · [survey](../reports/2026-06-26-architecture-fragility-survey.md) |
| **Gating** | **None.** `ViewNode` is `package final class`; decomposing it changes no public signature, so it is *not* gated on #4 (now [shelved](../proposals/2026-06-26-002-pipeline-ir-encapsulation-proposal.md#decision-2026-06-26)). |

## Outcome (2026-06-26)

**Done.** `ViewNode`'s mutable state now lives in **four cohesive value-typed sub-structs** (`ViewNodeFieldGroups.swift`), grouped by lifecycle and moved by whole-struct copy across checkpoint/restore — 25 of the engine's hand-mirrored fields collapsed out of the four-way mirror:

| Group | Fields | Lifecycle |
|---|--:|---|
| `FrameState` | 11 | per-frame working set (reset by `prepareForFrame`/`beginEvaluation`) |
| `EvaluationState` | 6 | cross-frame registration/evaluation/lifecycle bookkeeping |
| `ReuseState` | 3 | reuse/freshness gating for the skip fast-paths |
| `PersistentState` | 5 | retained per-node state (`@State` slots, deps, lifecycle, handlers, pending IDs) |

Each landed as its own gate-green commit. **Identity/wiring** (`viewNodeID`/`identity`/the weak links/`dependencyTracker`), the **already-consolidated `committed`** (Item 6 folded ~14 render mirrors into it), and the **structural `children`** stay top-level by design ("grouping is a means, not a quota").

All five done-criteria met: grouped state ✓; whole-struct rollback (`makeCheckpoint`/`restoreCheckpoint` copy the four sub-structs as units) ✓; **strengthened + generalized totality guard** (`ViewGraphCheckpointTotalityTests` asserts ViewNode-stored == Checkpoint-stored *and* every group member is mirrored in the flat debug snapshot — now 25 members) ✓; behavior byte-for-byte unchanged (full `bun run test` gate green, incl. the #1 sampled oracles, the #2 generative `skip==recompute` harness, the checkpoint round-trip, and TermUIPerf) ✓; empty public-API-baseline diff (`package`-internal) ✓.

**The decomposition paid off immediately:** grouping the modifier ordinals into `FrameState` surfaced a *pre-existing* hand-mirror gap — `nextTaskModifierOrdinal` was checkpointed but omitted from the debug snapshot — which the strengthened guard then forced closed. That is exactly the silent mirror-drift this work exists to eliminate.

**Notes for future grouping passes:** the `PersistentState` collections (`stateSlots`, `registeredHandlers`, `pendingChangeHandlerIDs`) are mutated in place on the resolve hot path, so plain get/set forwarders force a copy-on-write per mutation; this matched the proven `ViewGraph` field-group pattern and stayed perf-neutral *because the per-node collections are small* (TermUIPerf green). A future grouping of a *large* in-place-mutated collection should prefer a `_modify` (in-place yield) accessor instead. `PersistentState` is `@MainActor`-isolated because `NodeHandlers` carries main-actor closures; the other three groups are nonisolated.

## North star

> **Make `ViewNode`'s persistent state a small set of cohesive value sub-structs, so that checkpoint / restore / reset / debug-snapshot become whole-struct copies and the "field added to one list, forgotten in another" class of reconciliation bugs becomes structurally impossible — without changing a single observable behavior.**

The win is *structural correctness of the engine's most central type*, not new capability and not performance. Success is measured by **what can no longer silently go wrong**, not by lines moved.

## Why this, why now

The survey scored the resolution/reconciliation engine **the lowest of all subsystems (58/100)** — risk is concentrated exactly where change is hardest and blast radius is largest. `ViewNode` (≈1,440 LOC, ~36 stored fields) sits at the centre of it, and its dominant structural tax is **parallel hand-maintained field lists with no compiler enforcement**: the same field set is written out by hand in four places —

1. the stored-property declarations,
2. `ViewNode.Checkpoint`,
3. `makeCheckpoint()`,
4. `restoreCheckpoint()`

— plus a fifth mirror in `debugTotalStateSnapshot`. A field added to one list and forgotten in another silently corrupts rollback, reuse, or the totality oracle. This is the same defect family behind the project's history of stamp-skip / dropped-handler / stale-reuse bugs, and — until #1's sampled-release probe — it shipped where the `#if DEBUG` guards were compiled out. Grouping the fields into value sub-structs converts each of those four hand-lists into a **single whole-struct assignment**, so the compiler (not vigilance) keeps them in lockstep.

This is also the **prerequisite that unblocks the rest of #10** (and Wave C generally): once the node's state is grouped, the `ViewGraph` method-cluster extractions and any future engine evolution operate on named aggregates instead of 36 loose fields.

**Precedent exists and works.** The same transformation has already shipped green twice in this engine: `ViewGraphFieldGroups.swift` (nine value-typed groups on `ViewGraph`, with a source-level totality guard) and `AnimationController` (`c69c080f`, 24 fields → four sub-structs). `ViewNode` itself already did a related consolidation — Item 6 folded ~14 scattered render-mirror fields into the single `committed: ResolvedNode`. This goal continues that arc; it does not invent a new pattern.

## Definition of done

The work is complete when **all** of the following hold:

1. **Grouped state.** `ViewNode`'s mutable persistent fields live in a small number of cohesive, value-typed sub-structs (candidate clusters: a frame-local group cleared each frame; a reuse/freshness group; a per-node-persistent group of slots/dependencies/lifecycle/handlers; a registration/evaluation-internals group). Stable identity/wiring (`viewNodeID`, `identity`, the `weak` links, `dependencyTracker`) may stay top-level — grouping is a means, not a quota.
2. **Whole-struct rollback.** `makeCheckpoint()` / `restoreCheckpoint()` (and `reset`-style paths) copy sub-structs as units rather than re-listing fields; `ViewNode.Checkpoint` holds the sub-structs, not a flat re-declaration.
3. **Enforced totality.** `ViewGraphCheckpointTotalityTests` (the source-level guard covering `ViewNode`/`Checkpoint`) is updated to assert against the grouped shape and **still fails** if a new field is added to one mirror and not the others. The guard's protection must be *stronger or equal* after the change, never weaker.
4. **Behaviour byte-for-byte unchanged.** The full `bun run test` repo gate is green, including the reconciliation suites, and the **#2 generative skip==recompute harness** and **#1 sampled-release oracles** pass — these are the evidence that checkpoint/restore semantics are identical, not just that the code compiles.
5. **No surface change.** No public/`@_spi` signature changes; the existing computed-property forwarders that external readers use keep their API. Diff to `docs/.public-api-baseline.txt` is empty.

## Guiding principles (the guardrails)

- **Behaviour-preserving refactor, full stop.** This is not the place to fix a reconciliation bug, change reuse policy, or optimize. If a latent bug is discovered mid-refactor, file it separately and keep the decomposition a no-op.
- **Phase strictly — one cohesive sub-struct per PR, each green on its own.** Land the safest, most isolated cluster first (the frame-local group — it is reset each frame and touches no committed/dependency/handler state), then proceed inward toward the sensitive core (committed / dependencies / handlers) last, when the pattern is proven on this type. Every phase builds and passes the gate before the next begins.
- **Keep the totality guard live throughout.** Leave `debugTotalStateSnapshot` flat until the final phase so the source-level guard keeps cross-checking the mirror *during* the migration, not only at the end.
- **Group by lifecycle, not by type.** Fields belong together when they are written and cleared together (e.g. everything `prepareForFrame` resets), not because they share a Swift type. Cohesion is what makes the whole-struct copy correct.
- **Don't over-hoist.** Identity and wiring that never participate in checkpoint/restore should not be forced into a group for symmetry. A sub-struct that is copied but never rolled back adds ceremony without removing a mirror.
- **Respect the hot path.** `ViewNode` is on the per-frame reconciliation path. Prefer value sub-structs with stored properties and direct access; do not introduce indirection, allocation, or computed-property chains that change the cost of a checkpoint or a field read. Whole-struct copy must stay as cheap as the field-by-field copy it replaces.
- **Supervised, not autonomous.** Because this is the dominant *shipping* bug class on the engine's most central file, each phase is reviewed and characterized — not bulk-applied. A subtle seam regression here can reach release.

## Non-goals

- Extracting `ViewGraph`'s method clusters (`GraphCheckpointStore`, `InvalidationPlanner`, …) — a *separate* #10 strand, sequenced after this.
- Any public-API or IR change (that is #4, shelved).
- Performance work, reuse-policy changes, or new reconciliation behaviour.
- Decomposing `RunLoop` or other god objects (their own opportunities).

## Risks and how the approach retires them

| Risk | Mitigation |
|---|---|
| A field silently dropped from a mirror during the move | The source-level `ViewGraphCheckpointTotalityTests` mechanically catches a field present in one mirror and absent in another — that is precisely the failure mode, and it stays live every phase. |
| Checkpoint/restore semantics subtly change (e.g. value vs reference, copy timing) | The #2 generative harness asserts `scoped-restore == full-rebuild` across randomized frame sequences, and the #1 oracles run the stamp/delta/raster soundness checks; both must pass per phase. |
| Blast radius too large to review | Strict one-sub-struct-per-PR phasing keeps each diff small and characterized; the sensitive core lands last, after the pattern is proven on low-risk clusters. |
| Hidden coupling between "frame-local" and "persistent" fields | Start with the genuinely frame-local cluster (reset by `prepareForFrame`); validate the grouping boundary against `prepareForFrame`/`apply`/`snapshot` before grouping anything that crosses commit boundaries. |

## First step

Extract the **frame-local group** — the fields reset at frame start (`wasPresentAtFrameStart`, `wasVisitedThisFrame`, `previousChildrenIdentities`, `previousLifecycleMetadata`, `bodyStateSlotCount`, `currentBodyStateSlotCount`, `preparedFrameID`, `visitedFrameID`) — into a single value sub-struct, replace the four hand-mirror entries for those fields with one whole-struct assignment, extend `ViewGraphCheckpointTotalityTests` to the grouped shape, and confirm the full gate (plus the #1/#2 soundness machinery) is green before grouping the next cluster. This is the smallest slice that proves the transformation on `ViewNode` and de-risks every cluster after it.
