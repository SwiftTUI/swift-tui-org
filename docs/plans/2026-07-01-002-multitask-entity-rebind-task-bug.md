# Agent task: fix the entity-route rebind-timing `.task` bug (multi-task under `.id` churn)

You are working in the SwiftTUI framework package at
`SwiftTUI/swift-tui` (checked out at `swift-tui/` inside the coordination root).
Your job is to fix ONE specific framework bug and remove its `withKnownIssue`
marker. This is a hard, deep bug in the entity-routing + task-lifecycle seam; a
prior session investigated it exhaustively but did not land a safe fix. Use the
findings below so you do not have to re-discover them — but verify them yourself
with instrumentation before committing to a fix.

## Mission

Make this test pass with the `withKnownIssue` wrapper REMOVED (converted back to
direct per-iteration `#expect`s):

`Tests/SwiftTUITests/FrameworkStressTests.swift` →
`multipleTaskModifiersStayPairedAndBoundedUnderIdentityChurn`

Success criteria:
- `harness.activeTaskCount == 2` and `harness.activeTaskDescriptorCount == 2`
  after EVERY "Cycle Multi Tasks" click (36 iterations), and `== 0` after
  `shutdown()`.
- The `withKnownIssue(...) { ... }` wrapper is deleted and replaced with direct
  assertions in the loop (see the sibling `focusedBinding...`/`scroll...` tests
  in the same file for the un-wrapped shape to mirror).
- Full `FrameworkStressTests` suite stays green, `SwiftTUICoreTests` stays green,
  and the repo gate `bun run test` is green.
- No regression in the single-task churn tests (`collectionIdentityChurn...`,
  `taskIDStaysBoundedAcrossLazyTabSelection...`) or in `MultipleTaskModifiersTests`,
  `TabTaskActivationRuntimeTests`, `TabAutonomousTaskRuntimeTests`,
  `AsyncTaskDrivenFrameRuntimeTests`, `LifecycleSelectiveEvaluationTests`.

Do NOT touch the two already-landed fixes in the working tree (scroll
reveal-anchor pruning in `LocalScrollPositionRegistry.swift`; focused-value
`pruneToTreeIdentities` in `LocalFocusedValuesRegistry.swift` +
`RunLoop+FocusSync.swift`). They are unrelated and correct.

## The fixture (what triggers the bug)

`MultipleTaskModifierStressFixture` (~line 1880 in FrameworkStressTests.swift):

```swift
Text("multi-task generation \(generation)")
  .id("multi-task-\(generation % 7)")                              // IDModifier → entity routing
  .task(id: MultipleTaskModifierStressID(slot: "first", generation: generation)) { … }
  .task(id: MultipleTaskModifierStressID(slot: "second", generation: generation)) { … }
```

A `Text` at a FIXED structural slot, wrapped by `.id(String)` (which resolves via
`IDModifier` → entity routing), with TWO `.task(id:)` modifiers applied OUTSIDE
the `.id`. Each "Cycle Multi Tasks" click does `generation += 1`, so the entity
id churns ("multi-task-0" → "multi-task-1" → …). By SwiftUI semantics an `.id`
change is a new identity, so both tasks SHOULD cancel and restart — staying at
count 2. The bug makes the restart land one committed frame late.

## Confirmed root cause (verified with instrumentation)

It is NOT a leak and NOT a permanently-missing start. It is a **one-commit-late
START**: task cancel and restart split across two committed frames.

Per click (harness `click()` does down-render then up-render; the button action
fires and `generation` increments, then the churn render commits):
- **Churn render:** the departing entity node (e.g. `viewNodeID 12`, entity
  "multi-task-0") is torn down and its 2 descriptors CANCELLED → count 0. A NEW
  entity node (e.g. `viewNodeID 16`, "multi-task-1") commits in `finishEvaluation`
  with `wasPresentAtFrameStart == false` **but `node.lifecycleMetadata.tasks.count == 0`**
  — so its appear-branch starts nothing.
- **Next render (next click's first commit):** the same new node now has
  `lifecycleMetadata.tasks.count == 2` and finally STARTs → count 2, one render
  too late.

Because the scripted test observes immediately after the up-render (a CANCEL
commit), it always sees 0.

Two crucial sub-findings:
1. In the churn render there are TWO nodes at the same structural slot
   `.../VStack[1]`: the departing node (present=true, relabeled
   multi-task-0→multi-task-1, `curTasks=2`) AND the new node (present=false,
   `curTasks=0`). The `.task` descriptors are on the DEPARTING node, not the new
   one. Understand why two nodes exist and whether they should collapse to one.
2. The descriptor id/token is assigned per `(viewNodeID, ordinal, value)` via
   `ViewGraph.taskDescriptorIdentityLabel(for:ordinal:value:)` (called from
   `TaskLifecycleDescriptorIdentity` in `ViewLifecycleModifiers.swift`). Because
   the departing and new nodes have different `viewNodeID`s, they get DIFFERENT
   tokens for the same logical `.task` (e.g. `#task[id:3]` on node 12 vs
   `#task[id:5]` on node 16). The task registry ends up holding the new node's
   tokens while the departing node's `finishEvaluation` sees the departing
   node's tokens → they don't match.

Why single-task churn cases already work: `ForEach` elements and `TabView` panes
produce WHOLE-NODE replacement (a brand-new `viewNodeID` appears WITH its tasks
in one render), not a fixed-slot entity rebind. The bug is specific to an
`.id(_:)` entity rebind at a fixed structural slot with `.task` attached outside
the `.id`. Worth confirming: does a SINGLE `.task` on this same fixed-slot `.id`
fixture also fail? If so the bug is not multi-specific (the "multiple" framing is
incidental) and the minimal repro is simpler.

## Failed fix attempts (do not just repeat these)

1. **Un-gating the task start/cancel in `finishEvaluation` / `recordReusedSubtree`.**
   Removing the `!didChangeResolvedIdentity` guard and emitting cancel(prev)+start(cur)
   keyed to `node.resolvedIdentity` on the present branch. Result: the start was
   SKIPPED with `hasReg=false` — the present (departing) node's descriptors
   (id:3/4) are not what the registry holds (id:5/6, the new node's). Reverted.
2. **Forwarding `resolved.entityIdentity` in `nodeForResolvedNode`** →
   `nodeForIdentity(for:entityIdentity:)`. Ineffective: `resolved.viewNodeID` is
   already stamped by the time `nodeForResolvedNode` runs, so the entity-routing
   branch is never reached. No regressions, but no effect. Reverted.

## Code map (start here)

- `Sources/SwiftTUIViews/Modifiers/ViewMetadataModifiers.swift`
  - `IDModifier.resolve` (~199): `prepareEntityRoutedOwner(entityIdentity, for: ViewNodeContext.current)`,
    then `content.resolveOwned(in: routedContext)` inside `withResolveEntityRoute(route)`,
    then `resolved.attachingEntityIdentity(entityIdentity, at:)`.
  - `ExactIdentityModifier` (contrast: no entity routing).
- `Sources/SwiftTUIViews/Modifiers/ViewLifecycleModifiers.swift`
  - `TaskLifecycleModifier.resolve` (~250): `lifecycleIdentity = node.identity`,
    `claimTaskModifierOrdinal()`, descriptor id build, `taskRegistry.register(...)`,
    `node.lifecycleMetadata = node.lifecycleMetadata.merging(.init(tasks:[descriptor]))`.
  - `TaskLifecycleDescriptorIdentity` (~201) → `viewGraph.taskDescriptorIdentityLabel(for:ordinal:value:)`.
- `Sources/SwiftTUICore/Resolve/ViewGraph.swift`
  - `finishEvaluation` (~1134) — present vs appear branch task cancel/start; note
    the `didChangeResolvedIdentity` gate and `pruneDetachedResolvedRootIfNeeded` (~1296).
  - `recordReusedSubtree` (~1345) — duplicate of the same task gate for the reuse path.
  - `prepareEntityRoutedOwner` (~1114), `nodeForIdentity(for:entityIdentity:)` (~2107),
    `nodeForResolvedNode` (~258).
  - `applyStructuralChildDiff` (~2245), `removeSubtree` (~2281),
    `shouldDeferEntityRoutedRemoval` (~2221), `prunePendingEntityRoutedRemovals` (~2230),
    `releaseInactiveEntityRoutes` (~2213), `pendingEntityRoutedRemovalNodeIDs`.
  - `taskDescriptorIdentityLabel` — grep for it; token slot state is in
    `ViewGraphState.swift`/`ViewGraphFieldGroups.swift` (`TaskDescriptorSlotKey`,
    `nextTaskDescriptorIdentityToken`).
- `Sources/SwiftTUICore/Resolve/ChildDescriptor.swift` — `==` matches by
  `reconciliationStructuralPath` + `entityIdentity` + `typeIdentity`, deliberately
  NOT `identity`. **Do NOT add `identity` to `==`** — the test
  `ChildDescriptorTests.structuralPathIsThePositionalDescriptor` enforces that a
  same-slot identity rewrite keeps the same descriptor (positional reuse). A prior
  attempt to change this broke that test.
- `Sources/SwiftTUIViews/Foundation/ViewFoundation.swift` — `resolveView` (~296):
  `routeIdentity = entityRouteIdentity(for: view, in: context)` then
  `beginEvaluation(identity:entityIdentity:...)`.
- `Sources/SwiftTUIViews/Foundation/ResolveEntityRoute.swift` —
  `currentEntityRouteIdentity` returns the route id only when
  `route.structuralPath == context.structuralPath`. Check whether the `.task`
  modifiers between `.id` and the node shift the structural path so the route
  fails to match at the node's `beginEvaluation` (a plausible cause of the
  two-node transient / late attach).
- `Sources/SwiftTUIRuntime/Lifecycle/TaskRunner.swift` — active tasks keyed by
  `(viewNodeID, descriptorID)`; `start` cancels matching descriptor + sweeps
  stale `viewNodeID`s for the same identity+descriptor.
- `Sources/SwiftTUIRuntime/Lifecycle/LifecycleCoordinator.swift` — `apply`:
  `.taskStart` needs both `currentTaskRegistry.registration(for: entry.identity, descriptor:)`
  AND `entry.viewNodeID`; `.taskCancel` needs `entry.viewNodeID`.
- `Sources/SwiftTUICore/Resolve/ViewGraphLifecyclePlanning.swift` — the commit
  plan orders ALL cancels before ALL starts; viewport lifecycle planning only
  covers indexed-child-source (lazy) containers, NOT self-owned nodes, so it does
  not help this fixed-slot node.

## Build / test commands (use the pinned toolchain)

- One test: `swiftly run swift test --filter 'FrameworkStressTests/multipleTaskModifiersStayPairedAndBoundedUnderIdentityChurn'`
- Stress suite: `swiftly run swift test --filter 'FrameworkStressTests'`
- Core suite (reconciliation regressions): `swiftly run swift test --filter 'SwiftTUICoreTests'`
- Repo gate (must be green to finish): `bun run test`
  - It runs `swift package dump-symbol-graph` (slow, minutes, silent) and emits an
    IGNORED synthetic-package-test symbol-graph error — that is expected, not a failure.
- Format before finishing: `swift format format -i --configuration .swift-format.json <changed files>`
- Do NOT use bare `swift`/`xcrun swift`; always `swiftly run swift ...`.

## Instrumentation recipe (this is how the bug was pinned; reproduce it)

Temporary `print(...)` (Swift stdlib print works in these tests; the recording
host does not use real stdout). REMOVE all of it before finishing (the repo flags
`print` in library code).
- In `ViewGraph.finishEvaluation`, gated on
  `node.resolvedIdentity.path.contains("multi-task")`, print: identity,
  resolvedIdentity, previousResolvedIdentity, `wasPresentAtFrameStart`,
  `emitsOwnLifecycleEvents`, `didChangeResolvedIdentity`,
  `previousLifecycleMetadata.tasks.count`, `lifecycleMetadata.tasks.count`.
- In `LifecycleCoordinator.apply`, for `.taskStart`/`.taskCancel` gated on
  `entry.identity.path.contains("multi-task")`, print identity, descriptor.id,
  viewNodeID, and a `START-SKIP hasReg=...` branch when the registration/viewNodeID
  guard fails.
- In `LifecycleCoordinator.applyCommittedFrame`, print commit-begin/commit-end
  with `taskRunner.activeTaskCount` when the plan touches "multi-task".
- In the test loop, print a per-click marker plus the observed `activeTaskCount`.

## Constraints / invariants

- `.id` change = new lifetime ⇒ `.task` SHOULD restart. The fix must make
  cancel+restart CONVERGE in ONE committed frame (no one-render gap), not prevent
  the restart.
- Do NOT change `ChildDescriptor.==` to compare `identity` (breaks positional-reuse).
- Foundation-free layers: `SwiftTUICore`, `SwiftTUIViews`, `SwiftTUI` must not
  import Foundation. Strict Swift 6 concurrency + strict memory safety. 2-space
  indent, 100-col, `private` (not `fileprivate`), no block comments.
- Prefer a minimal, well-scoped ROOT fix. This seam is high-blast-radius — after
  ANY change, run the full stress + core suites AND `bun run test`, and diff the
  behavior of the single-task churn tests specifically.

## Candidate directions (hypotheses — validate, don't assume)

1. **Collapse the two transient nodes into one.** The strongest lead: in the
   churn render both a relabeled departing node (with tasks) and a fresh new node
   (task-less) claim the new entity id at the same slot. If the entity rebind
   reused the SURVIVING node for the new entity id (relabel in place) instead of
   minting a second node, tasks would stay on one node with a stable token and
   cancel+start would converge. Investigate `applyStructuralChildDiff` +
   entity-route resolution during rebind to see why two nodes appear.
2. **Stabilize the descriptor token across the rebind.** Key
   `taskDescriptorIdentityLabel` by structural slot + ordinal + value (not
   `viewNodeID`), so the cancel and start descriptors match regardless of which
   node they land on. Check this doesn't collide across genuinely-distinct nodes.
3. **Fix the entity-route match at the node.** If the `.task` modifiers shift the
   structural path so `currentEntityRouteIdentity` fails to match at the Text's
   `beginEvaluation`, the content resolves under the stale route (departing node)
   for one render. Making the route match in the churn render would attach tasks
   to the correct node immediately.
4. **Single in-frame convergence pass** (last resort): when a committed frame
   produces task cancels for a slot whose replacement has not started its tasks,
   trigger ONE additional render pass (like the focus-sync single eager
   re-render) to converge — must be strictly single-pass and must not regress
   frame counts or other lifecycle timing.

Start by reproducing with the instrumentation, then confirm whether the
single-`.task` variant of the fixture also fails (narrows the repro), then pursue
direction 1 or 3 (the two-node transient is the most likely true root). Land the
smallest change that makes cancel+start converge in one frame, delete the
`withKnownIssue` wrapper, remove all debug, format, and prove green on the stress
suite, core suite, and `bun run test`.
