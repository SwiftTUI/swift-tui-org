# SwiftTUI framework limitations: async-driven renders & one-task-per-node

**Date:** 2026-06-25
**Context:** Surfaced while fixing GIF-editor performance
([2026-06-24-gifeditor-perf-deepdive.md](2026-06-24-gifeditor-perf-deepdive.md)).
Two attempted improvements — moving the save-sheet GIF encode off the main actor,
and the requested "allow multiple `.task` modifiers on one view node" — each hit a
**framework** wall, not an app one. Both are documented here so a future, dedicated
effort starts from the evidence rather than rediscovering it.

The GIF-editor perf fixes that *did* land (composite memoization, `resolvedPixels`
hoist, history-compare short-circuit, and the core per-keystroke invalidation
narrowing) are committed and green. The two items below are **deferred**.

---

## Limitation 1 — a `.task`/`Task`-driven `refresh()` does not surface a frame in the headless test RunLoop

### What we wanted

The GIF editor's quit-while-dirty "Save GIF" sheet runs `SaveGIFPreview.make`
(a full `GIFEncoder.encode` + `GIFLoader.load` round-trip + re-flatten of every
frame) **synchronously on the main actor** before the sheet paints. For a large
multi-frame GIF this is a visible stall right as the popover opens (symptom "RC-B").
The natural fix: present the sheet immediately and compute the preview off the main
actor, filling it in when ready.

### What happens

**Every async deferral hangs the gate test deterministically.** We tried two
independent mechanisms:

1. A view `.task(id: isSaveSheetPresented)` on `EditorView` that awaits a
   `Task.detached { SaveGIFPreview.make(...) }` and then assigns `@State` + `refresh()`.
2. A plain unstructured `Task { @MainActor in … ; refresh() }` spawned from the
   present action (no view-lifecycle task involved at all).

Both make `PresentationRuntimeTests.ctrlSOpensUnifiedSaveSheetWithEncodedPreview`
hang (isolated `gtimeout` → `EXIT=124`, reproduced 100%). The test sends Ctrl+S
then `awaitCondition { latestFrame contains "Encoded preview" }`; the deferred
preview only appears on a *second* frame, and that frame never arrives.

### Why (as far as traced)

- The test harness (`GIFEditorPresentationInputReader`) drives input from a
  scripted `Task`; `.awaitCondition` does `await frameSignal.wait(until:)`, i.e. it
  suspends the input script until a *frame is presented* whose predicate holds.
- The deferred preview's `refresh()` calls `scheduler.requestInvalidation(of:)`,
  which **does** fire the event-pump wake handler
  (`Scheduler.swift` `requestInvalidation` → `wakeHandlerLock…?()`;
  `RunLoop+EventPump.swift:114` `setWakeHandler { continuation.yield() }`), and the
  run loop's empty-event path *does* render on a bare invalidation
  (`RunLoop+EventPump.swift` `processPendingEventsSynchronously`:
  `guard !pendingEvents.isEmpty else { renderPendingFrames(); return nil }`).
- So structurally a second frame *should* be produced. Empirically, under the
  scripted-input harness with no further input events, the frame driven purely by
  an async continuation's `refresh()` is **not observed** by the awaiting input
  script. The exact race — between the wake `continuation.yield()` and the input
  script's suspension/re-check — was not pinned down.

Note: this is **not** the `.task`-collision of Limitation 2. The unstructured-`Task`
variant has no view-lifecycle task at all and still hangs, so the blocker is the
async-render/observation path, independent of how the work is scheduled.

### Impact

- Any feature that wants to do work off the main actor and reflect the result in a
  later frame cannot be validated by the scripted-input RunLoop test harness — the
  test hangs rather than fails. This is a **testability** ceiling as much as a
  runtime one.
- It blocks RC-B (the GIF editor freeze-on-quit for large GIFs). Reverted to the
  synchronous compute; the stall persists only for large multi-frame imports.

### What a fix would need

- A first-principles trace of `MainActorConditionSignal.wait(until:)` vs the event
  pump's wake delivery: does a wake that originates from an async continuation
  (rather than an input event) reliably reach a *parked* `iterator.next()` and
  produce a `present()` the awaiting predicate sees? Reproduce with a minimal core
  test: a view with a single `.task` that, after a sleep, mutates `@State`, and an
  `awaitCondition` on the mutated render. (No such test exists today — the passing
  `.task`/animation tests all satisfy their conditions via *synchronous* keypress
  effects, so async-render observability is currently unproven in the harness.)
- Decide whether this is a harness gap (then provide a supported way to await an
  async-driven frame in tests) or a runtime gap (then fix the wake/observe race).

---

## Limitation 2 — the one-task-per-node assumption is baked through ~8 lifecycle layers

### What we wanted

Allow more than one `.task` / `.task(id:)` modifier on a single view node (today
the second silently replaces the first). `onAppear`/`onChange` already accumulate
into arrays; `.task` does not.

### Where the assumption lives

A single `.task` per node is assumed at **every** layer of the lifecycle pipeline:

1. **Descriptor identity** — `ViewGraph.taskDescriptorNodeSlots[viewNodeID]`: one
   `.task(id:)` comparison slot per *node* (`ViewGraph.swift` ~927).
2. **Resolved metadata** — `LifecycleMetadata.task: TaskDescriptor?` is **singular**
   and `merging` does `other.task ?? task` (last-wins), unlike the array-valued
   appear/disappear handler IDs (`ResolvedLifecycleMetadata.swift`). This type is
   **public**.
3. **Lifecycle diff** — `ViewGraph` (two blocks) and `ViewGraphLifecyclePlanning`
   diff a single `previousTask`/`currentTask` per node to emit `taskStart`/`taskCancel`.
4. **Registries** — `LocalTaskRegistry.registrations` and
   `NodeHandlers.taskRegistrations` are `[Identity: TaskRegistration]` (one/node,
   overwrites on the second register).
5. **Coordinator** — `LifecycleCoordinator` looks up the registration by
   `entry.identity`, not by descriptor.
6. **Runner** — `TaskRunner.activeTasks` is `[ViewNodeID: ActiveTask]` (one/node),
   and `start()` cancels any existing task on the node before starting — plus the
   stale-`viewNodeID` orphan-cancellation comment that explicitly assumes
   "one task per viewNodeID."

### What we implemented (and where it is now)

A complete change across all layers:

- `LifecycleMetadata.task` → `tasks: [TaskDescriptor]` (concat in `merging`).
- Per-task set-diff in both the structural and viewport lifecycle planners
  (cancel removed, start added; identical to the old single-task compare for one task).
- `LocalTaskRegistry` / `NodeHandlers.taskRegistrations` → `[Identity: [TaskRegistration]]`
  with append/replace-by-descriptor-id; `LifecycleCoordinator` looks up by descriptor.
- `TaskRunner` keyed by `(viewNodeID, descriptorID)`.
- A per-node **task-modifier ordinal** on `ViewNode` (mirroring
  `claimChangeModifierOrdinal`, incl. the checkpoint/restore plumbing), feeding a
  composite `TaskDescriptorSlotKey(node, ordinal)`; descriptor ids keep the historical
  format for the first task on a node (ordinal 0) and add an ordinal suffix only for
  the 2nd+, so single-`.task` nodes are byte-identical.

New unit tests pass: two `.task(id:)` on one node produce **distinct descriptors**,
**both register**, and **both start in the runner** (`activeTaskCount == 2`);
a single `.task` keeps its historical `…#task` id.

### Why it is deferred

The change introduces a **deterministic hang** (5/5, isolated) in
`InteractiveRuntimeTests.animationFramesKeepTabHostedPaneSurfaceStable` — a
tab-hosted `PhaseAnimator` whose `.task`-driven animation must produce 6 frames.
Reverting the change makes the test pass again; the basic multi-task unit tests are
unaffected. Three bisect probes did not isolate the layer: reverting only the
`TaskRunner` keying did **not** fix the hang, so the cause is in the
descriptor-identity/ordinal layer (1) or the metadata/diff layer (2–3) — most
likely a descriptor id or `taskStart`/`taskCancel` that subtly flaps frame-to-frame
for a `PhaseAnimator` under tab/viewNodeID churn, restarting its loop so it never
advances. This is exactly the fragile task/animation lifecycle that has produced
several prior hard bugs (see the org's `docs/reports` on gallery task-start triage
and PhaseAnimator completion stalls).

Crucially, **this change would not have unblocked Limitation 1 / RC-B** — the GIF
editor's deferred preview hangs the gate via the async-render path regardless of the
task collision (proven with the unstructured-`Task` variant, which has no `.task`
modifier).

### Where the work is preserved

`swift-tui` `git stash@{0}` on `integration/code-quality-refactors`:
`"framework: multiple .task per view node (deferred — animation-lifecycle hang, see report)"`
(includes the new `Tests/SwiftTUITests/MultipleTaskModifiersTests.swift`).

### What a fix would need

- Reproduce the hang with a minimal `PhaseAnimator`-in-`TabView` core test under the
  multi-task change, then instrument the per-frame `taskStart`/`taskCancel` stream
  (and the descriptor id) for that node to find what flaps. `SWIFTTUI_INVAL_TRACE`
  (commit `36a1a46b`) and `SWIFTTUI_FRAME_TRACE` are the levers.
- Verify the per-node task-modifier ordinal is stable across the speculative /
  checkpoint-restore re-resolves a `TabView` triggers (the change-modifier ordinal
  survives because its consumers are idempotent; a task restart is not).
- Treat `LifecycleMetadata` becoming plural as a public-surface change; sweep all
  consumers and the reuse/checkpoint paths, and add multi-task coverage for the
  viewport (lazy/tab) diff specifically, not just the structural diff.

---

## Summary

| Limitation | Blocks | Status | Recoverable from |
|---|---|---|---|
| Async-driven `refresh()` not observed by the scripted-input test RunLoop | RC-B (off-main-actor work reflected in a later frame) | open | n/a (revert to synchronous) |
| One-task-per-node baked through ~8 lifecycle layers; multi-task impl hangs a `PhaseAnimator` | multiple `.task` per node | open | `swift-tui` `git stash@{0}` |

Both are framework-level and worth a focused investigation with the traces above
before another attempt. Neither blocks the shipped GIF-editor perf fixes.
