# Structural Identity — Stage 5: `ViewNodeID` — Splitting Runtime Lifetime from Identity

**Date:** 2026-06-03
**Status:** Plan. Not started. Depends on Stages 2–4. **The largest breaking
change in the migration — internal-wide, behavior-preserving.**
**Stage:** 5 of the structural-identity migration. This is the first half of
001's **Option C**, reframed per the directive: it is the committed destination,
not a contingency. `Identity` is demoted from "the key for everything" to a
semantic/debug/public identity; runtime lifetime gets its own opaque key.
**Entry point:**
[`2026-06-03-001-first-class-structural-identity-proposal.md`](2026-06-03-001-first-class-structural-identity-proposal.md).
**Predecessors:**
[Stage 2 — Resolve-Time Structural Identity](2026-06-03-003-structural-identity-stage-2-resolve-time-structural-identity-plan.md),
[Stage 3 — Reconciliation & Entity Identity](2026-06-03-004-structural-identity-stage-3-reconciliation-entity-identity-plan.md),
[Stage 4 — Portal/Overlay/Alias Edge Roles](2026-06-03-005-structural-identity-stage-4-portal-overlay-edge-roles-plan.md).
**Successor:**
[Stage 6 — Entity-Routed Lifetime & State Re-rooting](2026-06-03-007-structural-identity-stage-6-entity-routed-lifetime-plan.md).
**Verified against:** `swift-tui` working tree at commit `a020fa55`.

---

## Executive summary

Today a `ViewNode`'s runtime lifetime is **1:1 with its final `Identity`**:
`ViewGraph.nodesByIdentity: [Identity: ViewNode]` (`ViewGraph.swift:86`),
find-or-create keyed on identity (`:1118-1129`), children materialized by
`resolved.children.map { nodeForIdentity(for: child.identity) }` (`:537-539`).
That one decision forces `Identity` to be simultaneously the runtime key, the
structural-containment proxy, the entity id, and the state-slot scope — and it
forces ~40 separate indexes across Resolve, Runtime registries, Animation,
Tasks, Presentation, and Commit to all key on the same string. Reconnaissance
enumerated every one of them (see *The blast radius* below).

Stage 5 introduces a distinct **`ViewNodeID`** (an opaque `UInt64` runtime
handle) and re-keys the *runtime-lifetime* indexes onto it, while leaving the
*structural*, *entity*, and *state-slot-owner* axes on their Stage-2/3 carriers.
Crucially, Stage 5 is a **behavior-preserving re-key**: `ViewNodeID` is assigned
1:1 with the lifetime today's `Identity` already implies, so no node lives longer
or dies sooner than before. The semantic change — runtime lifetime *surviving* an
identity-changing transformation — is deliberately quarantined in Stage 6.

This is the stage where the migration stops hedging. The earlier proposals say
"only pursue `ViewNodeID` if the earlier work still leaves bugs." The directive
overrides that: the overload *is* the bug. A type that means four things is a type that
can be wrong four ways, and the registration-alias layer, the string-encoded
handler ids, and the duplicate-id aliasing are all scar tissue from refusing to
name the four roles. Stage 5 names them.

## The four-axis model (the spine of the migration)

Every one of the ~40 identity-keyed indexes belongs to exactly one axis. Stage 5
sorts them:

| Axis | Key after Stage 5 | Means | Example indexes |
| --- | --- | --- | --- |
| **Runtime** | `ViewNodeID` (new, opaque) | a live node's lifetime | `nodesByIdentity`→`nodesByNodeID`, `liveIdentities`, `invalidatedIdentities`, `graphLocalDirtyIdentities`, all `Local*` registries + `NodeHandlers`, `AnimationController.*`, `TaskRunner.activeTasks`, `MeasurementCache`, `AnchorTypes`, `Observation`, `drawByIdentity`, `viewportLifecycle*`, `taskDescriptorIdentitySlots`, `LiveRegionAnnouncer` |
| **Structural** | `StructuralPath` (Stage 2) | ordered tree position; prefix relation | `isAncestor`/`isDescendant` callers, `FrameMetrics` walks, `ChildDescriptor` diff key, `indexedChildSource.identityRoot`, scope-path dispatch (focus/command/drop/scroll), structural invalidation intersection |
| **Entity** | `EntityIdentity` (Stage 3) | explicit user/data id | `declarativeItemsBySource`, `seenSources`, ForEach element key, presentation source |
| **State-slot** | `StateSlotKey` (owner + ordinal) | stored dynamic-property slot | `ViewNode.stateSlots`, `stateSlotDependents` keys, `DependencySet.stateSlotReads` — **owner stays identity-derived in Stage 5; re-rooted to `ViewNodeID` in Stage 6** |

The discipline: an index keyed on the wrong axis is a latent bug. `liveIdentities`
is pure runtime lifetime → `ViewNodeID`. A focus scope path is pure structure →
`StructuralPath`. `declarativeItemsBySource` is pure entity (the declaring view's
id, which must survive its own re-resolve) → `EntityIdentity`. Stage 5's review
is, index by index, "which axis is this, really?"

## The hard constraint: `ViewNodeID` is opaque, but tree relations must survive

A naive `ViewNodeID` that is "just a counter" breaks a large class of consumers
that today lean on `Identity`'s structure:

- focus traversal, sections, and `scopePath: [Identity]`
  (`FocusTracker.swift:9-27`);
- scroll-to-reveal via `isAncestor`/`isDescendant`
  (`LocalScrollPositionRegistry.swift:34`);
- keyboard-shortcut and drop-destination scope routing that walks `scopePath`
  shallowest/leafmost-first (`CommandRegistry.swift:65`,
  `DropDestinationRegistry.swift:46`);
- termination-handler dispatch ordered by identity tree-depth
  (`LocalTerminationRegistry.swift:26`);
- subtree teardown (`removeSubtrees` filters on `isAncestor`/`isDescendant` and a
  `Set<Identity> liveIdentities`).

The resolution is the four-axis model itself: **these consumers read the
structural axis, not the runtime key.** `ViewNodeID` stays opaque (no tree
semantics); every "is X under Y?" query is answered by `StructuralPath` (Stage
2), which retains the component-wise prefix relation. This is why Stages 2–4 are
prerequisites: without a first-class structural axis, `ViewNodeID` would have to
smuggle the path back in, and we would have changed nothing.

> **This is a dual-keying redesign, not a clean re-key — say so honestly.** Every
> `Local*` registry tears down via `entry.identity.isDescendant(of: root)`
> (`removeSubtrees(rootedAt:)`), and the same `isDescendant` drives ViewGraph's
> own invalidation walks (`ViewGraph.swift:850-854,1109-1110`). An *opaque*
> `ViewNodeID` cannot answer "descendant of root" over the registry's own
> membership. So each runtime registry entry must carry **both** keys — a
> `ViewNodeID` (ownership/lifetime) **and** its `StructuralPath` (or a side index
> `ViewNodeID → StructuralPath`) — and `removeSubtrees`/`prune` match on the
> `StructuralPath` while the ownership key stays `ViewNodeID`. That is a
> per-registry teardown-data-structure change replicated ~15 times. It does not
> change the *algorithm* (so it remains perf-neutral in the steady state), but it
> is materially larger than "swap the key type," and L5.3 must treat it as its
> own sub-workstream with a teardown-by-structure test per registry.

## The blast radius (enumerated, from reconnaissance)

The runtime-axis indexes Stage 5 re-keys to `ViewNodeID`, by file:

- **Core graph:** `ViewGraph.nodesByIdentity` (`:86`),
  `viewportLifecycleNodesByIdentity`/`order` (`:89-90`),
  `invalidatedIdentities`/`graphLocalDirtyIdentities`/`liveIdentities`
  (`:97-98,119`), `taskDescriptorIdentitySlots` (`:106`),
  `lifecycleEvaluation*ByIdentity`/`ByOwner` (`:103-105`),
  `nodeCheckpoints` (`ViewGraphState.swift:39`). Teardown choke point:
  `removeSubtree` (`ViewGraph.swift:1155`; its index-unwind tail is `:1214-1236`).
- **Runtime registries:** `NodeHandlers` (`:1-19`), `LocalActionRegistry`
  (`:17`), `LocalKeyHandlerRegistry` (`:54-56`), `LocalTerminationRegistry`
  (`:26`), `LocalPointerHandlerRegistry` (`RouteID`, `:79-80`),
  `LocalGestureRegistry` (`:6`), `LocalGestureStateRegistry` (`:37`),
  `LocalTaskRegistry` (`:21`), `LocalScrollPositionRegistry` (`:34`),
  `LocalFocusBindingRegistry` (`:260`), `LocalFocusedValuesRegistry` (`:19`),
  `LocalPreferenceObservationRegistry` (`:69`), `CommandRegistry` (`:65`),
  `DropDestinationRegistry` (`:46`), `LocalDefaultFocusRegistry` (`:47-49`).
- **Runtime engines:** `AnimationController` (~9 maps, `:11,29-33,60-68`),
  `TaskRunner.activeTasks` (`:11`), `LiveRegionAnnouncer.previousLabelsByIdentity`
  (`:18`).
- **Commit / frame-tail:** `RetainedFrameQueries` lookup maps (`:26-30`) —
  *lookup* re-keys to runtime, but the *structural walks* in
  `FrameMetrics.swift:33-89` and the `indexedChildSource.identityRoot` barrier
  stay structural; `FrameTailRetainedState` draw/`previousDrawnIdentities`
  (`:25,118`); `MeasurementCache` (`MeasurementCache.swift:25`),
  `AnchorTypes` (`:162-168`), `Observation` (`Observation.swift:7`).

The indexes that **stay** on the structural/entity axes: `ChildDescriptor`,
`FrameMetrics` ancestor walks, `indexedChildSource.identityRoot`,
`declarativeItemsBySource`/`seenSources`, focus/scroll/command/drop `scopePath`s.

## Three sub-workstreams that need their own care

### A. The single teardown choke point is a gift — use it

`removeSubtree` (`ViewGraph.swift:1214-1236`) already unwinds nearly every
identity-keyed index in one place (`liveIdentities.remove`,
`removeDependencyEdges`, `taskDescriptorIdentitySlots.removeValue`,
`nodesByIdentity.removeValue`), and `RuntimeRegistrationSet+Operations.swift:44-87`
fans `removeSubtrees`/`prune(keeping:)` to every `Local*` registry. Re-key these
together at this choke point. The risk is the dirty/invalidation *planners*
(`ViewGraphInvalidationPlanning`, `ViewGraphDirtyEvaluationPlanning`) that key by
identity independently of the choke point — those must migrate in lockstep.

### B. String-encoded identity keys must be redesigned, not re-pointed

Several keys embed `Identity.path` as a **string** and re-parse it for teardown:

- lifecycle handler ids (`LocalLifecycleRegistry.swift:165-175`,
  `lifecycleHandlerIdentity`, `"<path>#…"`);
- preference handler ids (`LocalPreferenceObservationRegistry.swift:69`,
  `"<identity>#preference[Key][ordinal]"`);
- `@FocusState` `bindingID` (`"<path>#FocusState[ordinal]"`).

A `ViewNodeID` re-key that changes how a node renders to `.path` would *silently*
break the re-parse-based teardown. Stage 5 replaces these string encodings with
structured keys (`ViewNodeID` + typed suffix), so teardown matches on the typed
key, not a parsed substring. This is the nastiest part of the stage and gets its
own test: forced teardown of a string-keyed handler under a re-key must not leak.

### C. Delete the registration-alias layer (staged by Stage 4)

`registrationAliasesByIdentity` / `registrationAliasTargets` (`:101-102`) exist
**solely** to reconcile structural identity (`childContext.identity`) with
resolved runtime identity (`resolvedNode.identity`). Once `ViewNodeID` is the
runtime key and `StructuralPath` is first-class, that reconciliation is
structural — the alias bridge is redundant. Stage 5 deletes it and the
alias-fanout in `removeResolvedSubtree` (`ViewGraph.swift:1239-1264`) and
`restoreResolvedSubtree` (`ViewGraphRuntimeRegistrationRestoration.swift:13`,
called from `ViewGraph.swift:1003`) — **after** confirming the
custom-`ResolvableView` caveat Stage 4 flagged. Deletion is "behavior-neutral"
**only if** the structural→`ViewNodeID` lookup reproduces the exact
alias-resolution those two functions perform today; gate the deletion on a test
proving that for the `.id`, nested-`AnyView`, **and** custom-`ResolvableView`
cases. This is the clearest "delete scar tissue" win in the migration — but it is
a proven win, not an assumed one.

## Mechanics

### L5.1 — Mint `ViewNodeID` at the find-or-create choke point
Introduce `ViewNodeID(rawValue: UInt64)`. Mint exactly one per `ViewNode` at
`nodeForIdentity` (`ViewGraph.swift:1118-1129`). Maintain a bidirectional
`identityByNodeID` / `nodeIDByIdentity` so the migration can proceed index by
index. **Assignment is behavior-preserving:** a node that today is keyed by
identity `I` gets a stable `ViewNodeID` for as long as that identity persists;
when reconciliation (Stage 3) says "same node," it inherits the same
`ViewNodeID`. No new survival semantics this stage.

### L5.2 — Re-key the core node store
`nodesByIdentity → nodesByNodeID`. `nodeForIdentity` becomes the mint/lookup. The
~40 direct subscript sites move to `nodesByNodeID[node.viewNodeID]`, going
through the bidirectional map where a caller only has an `Identity`. Children
materialization (`:537-539`) uses the child's `ViewNodeID`.

### L5.3 — Re-key the runtime-lifetime indexes
Migrate the runtime-axis indexes (table + blast-radius list above) to
`ViewNodeID`, at the `removeSubtree`/`RuntimeRegistrationSet` choke point where
possible. `RouteID` becomes `ViewNodeID + RouteKind`. Dependent *value* sets
(`stateSlotDependents`, `environmentDependents`, `observableDependents` values;
`FocusedValues descendantIdentities`) become `Set<ViewNodeID>` (they point at
dependent runtime nodes). `AnimationController`'s maps need a **split
classification, not a blanket re-key** — applying the four-axis discipline to
itself: `previousTransitionsByIdentity` / `removingIdentities` (`:60-68`) are
genuine runtime-lifetime (they keep a removed view *alive one frame past
presence*) → `ViewNodeID`; but `previousParentByIdentity` /
`previousChildIndexByIdentity` (`:31-33`) are **structural-positional** — their
values are a parent and a child ordinal, the exact signal removal-overlay
re-injection at the authored parent (Stage 1 / Stage 4) depends on. Their *values*
must stay on the structural axis (`StructuralPath` / structural parent key), or
"did this node's structural parent/index change?" detection breaks. A test for
removal-overlay re-injection at the authored parent after the re-key is mandatory.

### L5.4 — Redesign string-encoded keys (sub-workstream B)
Replace `Identity.path`-embedded handler/binding ids with structured
`ViewNodeID`-based keys. Teardown matches the typed key.

### L5.5 — Keep tree-relation consumers on the structural axis
Repoint focus/scroll/command/drop/termination/focusedValues *ordering and
containment* queries at `StructuralPath` (Stage 2); their *ownership/lifetime*
keys become `ViewNodeID`. This is the split that lets `ViewNodeID` stay opaque.

### L5.6 — Delete the alias layer (sub-workstream C)
Remove `registrationAliasesByIdentity`/`Targets` and their fanout, after the
custom-`ResolvableView` confirmation.

### L5.7 — Checkpoint totality + debug snapshots, in lockstep
`ViewGraphCheckpointTotalityTests` (`:33-48`) source-parses `ViewNode`/`ViewGraph`
stored-field names and asserts set-equality, explicitly filtering out
`ViewNode.identity` (`:38`). Adding `viewNodeID` and re-keying the checkpoint maps
forces coordinated edits to `ViewNode.Checkpoint`, `DebugTotalStateSnapshot`, and
that test's filter. Treat the totality contract as a feature: it guarantees no
re-keyed map is quietly missed.

### L5.8 — The behavior-preservation oracle (and what the existing test can and cannot prove)
**The existing scoped-restore test is necessary but not sufficient.**
`RuntimeRegistrationRestoreScopingTests` (`:15-71`) asserts a scoped restore is
byte-identical to a full rebuild **of the same graph in the same code version** —
an *internal-consistency* oracle. It is **blind to a uniform behavior shift**:
Stage 5 re-keys both the scoped path and the full-rebuild path to `ViewNodeID`
together, so the two sides stay equal even if the `ViewNodeID` scheme uniformly
changes observable behavior. Keep this test (it proves the re-key is
self-consistent), but do **not** mistake it for the behavior-preservation proof.

The actual proof requires a **cross-version oracle**, one of:
1. **Recorded golden.** Serialize observable outputs across the corpus at the
   pre-Stage-5 commit — using the `Identity` public/debug projection the plan
   keeps precisely for this — and assert the Stage-5 build reproduces those
   goldens byte-for-byte. This is the primary oracle.
2. **Parallel dual-keying diff.** Behind a debug flag, run the `Identity`-keyed
   and `ViewNodeID`-keyed indexes side by side within Stage 5 and diff per frame.
   Useful during development; the golden is the gate.

Extend the reuse-invariant suites alongside, but the golden is what certifies
"behavior-preserving."

## Tests

1. **Behavior-preserving re-key.** Across the corpus, every appear/disappear,
   reorder, focus move, scroll, animation, and presentation produces identical
   observable behavior to pre-Stage-5 (the extended byte-equivalence oracle).
2. **Opaque `ViewNodeID`, structural queries intact.** Focus traversal, scroll
   reveal, shortcut/drop scope routing, and termination ordering are unchanged —
   they read `StructuralPath`, proving `ViewNodeID` opacity is harmless.
3. **String-key teardown does not leak.** Force-teardown of lifecycle/preference/
   focus-binding handlers under a re-key; assert no stale registration (the
   sub-workstream B regression test).
4. **Alias layer deletion is behavior-neutral.** `.id(_:)`/`IDView` cases
   (`RegistrationAliasFindingsTests`) behave identically with the alias maps
   removed; the custom-`ResolvableView` path is exercised and confirmed.
5. **Checkpoint totality holds.** `ViewGraphCheckpointTotalityTests` passes with
   the new field set; a deliberately-missed map fails it (negative test).
6. **Duplicate-id isolation.** Two duplicate-id `ForEach` elements (Stage 3
   occurrence-disambiguated) now get **distinct `ViewNodeID`s** and no longer
   alias each other's `@State`/handlers/animation — the latent collision is gone.

## Execution order and touchpoints

| Step | Lands | Primary files |
| --- | --- | --- |
| L5.1 | `ViewNodeID` + mint + bidirectional map | `Resolve/ViewGraph.swift:1118-1129`, `Resolve/ViewNode.swift` |
| L5.2 | core node store re-key | `Resolve/ViewGraph.swift:86,537-539` + ~40 subscript sites |
| L5.3 | runtime-index re-key (dual-key registries) at teardown choke point | `SwiftTUICore/Resolve/ViewGraph.swift:1155`, `SwiftTUICore/Runtime/Local*.swift`, `SwiftTUICore/Runtime/RuntimeRegistrationSet+Operations.swift`, `SwiftTUICore/Resolve/NodeHandlers.swift`, `SwiftTUIRuntime/Lifecycle/AnimationController.swift`, `SwiftTUIRuntime/Lifecycle/TaskRunner.swift`, `SwiftTUICore/Commit/RetainedFrameQueries.swift`, `SwiftTUIRuntime/Rendering/FrameTail*.swift`, `SwiftTUICore/Measure/MeasurementCache.swift`, `SwiftTUICore/Geometry/AnchorTypes.swift` |
| L5.4 | structured handler/binding keys | `Runtime/LocalLifecycleRegistry.swift:165`, `Runtime/LocalPreferenceObservationRegistry.swift:69`, `State/FocusState.swift` |
| L5.5 | tree-relation consumers on `StructuralPath` | `Semantics/FocusTracker.swift`, `Runtime/LocalScrollPositionRegistry.swift`, `CommandRegistry.swift`, `DropDestinationRegistry.swift`, `LocalTerminationRegistry.swift`, `LocalFocusedValuesRegistry.swift` |
| L5.6 | delete alias layer (gated on the structural→`ViewNodeID` lookup test) | `SwiftTUICore/Resolve/ViewGraph.swift:101-102,347-382,1239-1264`, `SwiftTUICore/Resolve/ViewGraphRuntimeRegistrationRestoration.swift:13`, `SwiftTUICore/Resolve/RegistrationAliasDiagnostics.swift`, `SwiftTUIViews/Foundation/ViewFoundation.swift:60-66` |
| L5.7 | checkpoint totality + debug snapshots | `Resolve/ViewGraphState.swift`, `ViewGraphCheckpointing.swift`, `ViewGraphDebugSnapshots.swift`, `Tests/.../ViewGraphCheckpointTotalityTests.swift` |
| L5.8 | extend the equality oracle | `Tests/SwiftTUICoreTests/Graph/RuntimeRegistrationRestoreScopingTests.swift`, reuse-invariant suites |

This stage cannot be half-landed: a mix of `ViewNodeID`-keyed and `Identity`-keyed
runtime indexes is a lifetime-bug factory. Sequence it as one coordinated change
behind the byte-equivalence oracle, ideally on a worktree branch, with the oracle
green at every commit.

## Validation

```bash
swift test --package-path swift-tui --filter ViewGraphCheckpointTotalityTests
swift test --package-path swift-tui --filter ViewGraphTests
swift test --package-path swift-tui --filter RuntimeRegistrationRestoreScopingTests
swift test --package-path swift-tui --filter RegistrationAliasFindingsTests
swift test --package-path swift-tui --filter PanelTests
swift test --package-path swift-tui --filter AnyViewResilienceTests
swift test --package-path swift-tui --filter PresentationContinuityTests
swift test --package-path swift-tui            # full suite (mind the known signal-11 triage item)
bazel test //:org_full
```

Perf: Stage 5 keeps the same algorithms (re-key, not re-algorithm), so it should
be perf-neutral in the steady state — with the caveat that the registry
dual-keying (sub-workstream A) adds a `StructuralPath` per registry entry, a small
storage cost, not a per-frame compute cost. Run the rows=6/20/40 sweep to confirm
no regression, and confirm the deleted alias layer does not show up as a *win*
that masks a behavior change (it should be neutral; the golden oracle guards
correctness).

## Risks and non-goals

- **Do not** give `ViewNodeID` tree semantics. It is opaque; structure lives on
  `StructuralPath`. The moment `ViewNodeID` grows an `isAncestor`, the migration
  has failed and re-merged the axes.
- **Do not** change survival semantics in this stage. `ViewNodeID` tracks exactly
  the lifetime `Identity` tracks today. State surviving identity-changing moves is
  Stage 6.
- **Do not** re-point string-encoded keys; redesign them. A re-point inherits the
  silent-teardown-break hazard.
- **Do not** delete the alias layer before the custom-`ResolvableView` path is
  confirmed (Stage 4 OQ#2).
- **Do not** reintroduce `Identity(path:`/`ExpressibleByStringLiteral`
  (`IdentityGuardTests`); `ViewNodeID` is minted, not string-built.
- **Do not** land partially. One coordinated change behind the oracle.

## Open questions

1. Should `ViewNodeID` be a global monotonic counter or graph-scoped? Graph-scoped
   composes better with `__SwiftTUIStateGraph` isolation (Stage 6) but needs a
   scope dimension. Leaning graph-scoped `(scope, counter)`.
2. Does `Identity` survive at all post-Stage-5, or only as a debug/public
   projection of `StructuralPath` + `EntityIdentity`? Leaning: keep `Identity` as
   the *serialized public/debug* projection (snapshots, accessibility bridge,
   fixtures) so the public surface is unchanged, while no *runtime* index keys on
   it. Stage 6 finishes demoting it from `@State`.
3. Can the dirty/invalidation planners re-key cleanly at the teardown choke
   point, or do they need their own pass? Audit `ViewGraphInvalidationPlanning` /
   `ViewGraphDirtyEvaluationPlanning` before sequencing.
