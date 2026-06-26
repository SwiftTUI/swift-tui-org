# SwiftTUI MainActor synchronization and off-main work audit

**Date:** 2026-06-26
**Scope:** `swift-tui` runtime/core/view synchronization, frame pipeline offload
boundaries, and representative example-app main-thread work.
**Method:** Read-only source audit of MainActor boundaries, worker handoffs,
locks, scheduler state, observation invalidation, diagnostics, and example-app
work placement.
**Status:** Findings and leverage map only; no code changed.

---

## TL;DR

SwiftTUI's MainActor design is mostly intentional and internally coherent. The
largest near-term payoff is probably **not** making `View.body`, `State`, or the
retained `ViewGraph` non-main actor. Those are public and architectural
contracts today. The better levers are:

1. **Do less frame-head work on MainActor**: improve invalidation precision,
   retained reuse, and fan-out control.
2. **Widen the existing frame-tail layout offload path**: remove or snapshot
   the blockers that force layout back onto MainActor.
3. **Use the existing async cancellation/drop/elision modes aggressively** on
   interactive workloads where input/animation outpaces rendering.
4. **Fix the observation invalidation escape hatch** before treating off-main
   model mutation as a supported design point.
5. **Move app-level IO and derived-data work out of `body` / MainActor view
   models**, publishing compact snapshots back to the UI.

The current design already has the important split: **frame head is MainActor;
frame tail can suspend MainActor and run layout/raster work on workers.** The
question is therefore where MainActor is still paying too much, and which
offload blockers can be removed safely.

---

## Current MainActor contract

The authoring surface is explicitly MainActor-bound:

- `View` and `View.body` are `@MainActor`
  (`swift-tui/Sources/SwiftTUIViews/Foundation/ViewProtocols.swift:21-26`).
- `DefaultRenderer.render` and `renderAsync` are `@MainActor`
  (`swift-tui/Sources/SwiftTUIRuntime/SwiftTUI.swift:176-205`).
- `RunLoop` is a MainActor runtime object
  (`swift-tui/Sources/SwiftTUIRuntime/RunLoop/RunLoop.swift:4`).
- The public-surface policy script keeps this from drifting, including
  `View.body`, `Scene.body`, `DefaultRenderer.render`, `Binding` access, and
  `.task` actor inheritance
  (`swift-tui/Scripts/check_public_surface_policies.sh:48-98`).

That contract is doing real work. It lets view authors write SwiftUI-like code
without making every `body`, `@State`, `@Binding`, environment read, lifecycle
mutation, and graph update independently sendable/thread-safe.

**Implication:** Making body evaluation generally off-main is an XL
architecture change, not a tuning pass. It would require new isolation rules for
state ownership, observation, environment access, task lifecycle, graph
mutation, and custom view code. It is not the first lever to pull.

---

## Pipeline design assessment

The pipeline already separates the non-sendable head from the sendable tail:

- `RuntimeRenderPipeline` runs frame-head, animation injection, preference
  reconciliation, fused frame tail, and commit stages
  (`swift-tui/Sources/SwiftTUIRuntime/Rendering/RuntimeRenderPipeline.swift:10-18`).
- `DefaultRendererFrameHeadCoordinator` is the MainActor side that evaluates the
  dirty graph and prepares tail input
  (`swift-tui/Sources/SwiftTUIRuntime/Rendering/DefaultRendererFrameHeadCoordinator.swift:12`,
  `:396`).
- `FrameTailRenderer` is `Sendable` and owns the retained tail state, worker
  hooks, layout engine, semantic extractor, draw extractor, and rasterizer
  (`swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailRenderer.swift:5-13`).
- Async layout and raster suspend MainActor while worker jobs run
  (`FrameTailRenderer.swift:73-110`, `:142-168`).
- `FrameTailWorkerExecutor` uses a serial frame-tail queue plus a separate layout
  worker path
  (`swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailWorkerExecutor.swift:5-10`,
  `:78-137`).

This is the right shape. The important follow-up is not "add more threads" by
default. It is to understand whether a workload is:

| Dominant cost | Likely lever |
| --- | --- |
| MainActor frame head | invalidation narrowing, retained reuse, less `body` work |
| layout fallback on MainActor | widen `canOffloadLayout` eligibility |
| worker layout/raster compute | tail algorithm/caching/damage improvements |
| queued stale frames | cancellation/drop/offscreen elision |
| app IO/derived data | app-level actors/tasks and snapshots |

---

## Findings

### 1. Highest-payoff framework lever: reduce frame-head churn

Frame head has to stay MainActor under today's contract. That makes
**invalidation precision and reuse** the primary lever for workloads whose
diagnostics show high `main_actor_blocked_ms` or high resolved-node recompute
counts.

Existing diagnostics already expose the right signals:

- `resolvedNodesComputed` / `resolvedNodesReused`
  (`swift-tui/Sources/SwiftTUIRuntime/Diagnostics/FrameDiagnosticRecord.swift:10-11`).
- `main_actor_blocked_ms`, worker layout/raster timing, and fallback columns in
  TSV output
  (`swift-tui/Sources/SwiftTUIRuntime/Diagnostics/FrameDiagnosticsTSVFormatting.swift:42-49`,
  `:205-249`).
- TermUIPerf summary includes `mainActorBlockedRatio`
  (`swift-tui/Tools/TermUIPerf/Sources/TermUIPerf/SummaryReducer.swift:160`,
  `:471`).

This is where reader attribution, precise observation firing, key-path
observable invalidation, focus/press reuse suppression scope, and retained
subtree reuse matter. If frame head dominates, moving raster or layout further
off-main will not move the bottleneck enough.

### 2. Best concrete off-main lever: widen layout offload eligibility

Layout offload is real, but gated by three disqualifiers:

```swift
!containsMainActorOnlyCustomLayout(input.resolved)
  && !containsMainActorOnlyIndexedChildSource(input.resolved)
  && !containsLayoutRealizedContent(input.resolved)
```

Source: `swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailLayoutOffloadEligibility.swift:20-26`.

The comments identify the blockers directly: custom layouts that cannot run on
workers, indexed child sources that cannot run on workers, and layout-realized
content that needs a prepared graph mid-layout
(`FrameTailLayoutOffloadEligibility.swift:10-14`).

This is the most promising pure off-main area because it preserves the public
MainActor authoring contract while moving more deterministic IR work into the
tail. The concrete levers are:

- Add or improve worker-safe snapshots for indexed child sources.
- Convert selected custom layout handles to `canRunOnWorker == true` once their
  cache/state access is actually thread-safe.
- Reduce `layoutRealizedContent` usage or pre-realize enough information before
  the worker layout stage.
- Track `layoutDependentMainActorFallbacks` and custom-layout fallback counts as
  first-class perf outcomes, not incidental diagnostics.

### 3. Async cancellation/drop/elision is already a useful latency lever

The run loop can use async, async-no-cancel, and async-no-drop modes:
`swift-tui/Sources/SwiftTUIRuntime/RunLoop/RuntimeRenderMode.swift:14-20`.
The cancellable acquisition path passes generation, completed-frame policy,
drop blockers, and queued-cancellation signals into the renderer
(`swift-tui/Sources/SwiftTUIRuntime/RunLoop/RunLoop+FrameAcquisition.swift:116-146`).

This is not throughput optimization; it is responsiveness optimization. It pays
when the system is producing work faster than it can present useful frames. The
right experiment is to compare:

- default `async`
- `async-no-cancel`
- `async-no-drop`
- sync, as a baseline

Then inspect cancelled renders, dropped visual-only frames, coalesced intent
requests, worker queue timings, and input latency. If cancellation/drop improves
interactive latency without visible artifacts, extending that path is cheaper
than introducing more parallel execution.

### 4. Main synchronization concern: observation invalidation assumes main-actor mutation

`ObservationBridge` is `@MainActor`, but its `withObservationTracking` callback
uses `MainActor.assumeIsolated`:

```swift
return withObservationTracking {
  apply()
} onChange: {
  MainActor.assumeIsolated {
    self.recordChange(identity: identity, pass: pass)
  }
}
```

Source: `swift-tui/Sources/SwiftTUIViews/Environment/Observation.swift:63-69`.

`recordChange` then queues dirty observation state and requests invalidation
(`Observation.swift:105-114`). This is safe only if observed mutations that
trigger `onChange` are MainActor-confined. If off-main model mutation is a goal,
this is the first design bottleneck.

Options:

- **Enforce the current contract**: document that observed models used by views
  must mutate on MainActor, and add debug checks where possible.
- **Support off-main mutation**: change the callback to hop/coalesce back to
  MainActor before touching `ObservationBridge` / `ViewGraph`, e.g. via
  `Task { @MainActor in ... }` or a small locked mailbox drained on the next
  frame.

The second option may add one-hop latency and needs coalescing semantics, but it
is the correct direction if background model work becomes first-class.

### 5. `FrameScheduler` is main-actor-confined by convention, not by type

`FrameScheduler` has unlocked mutable scheduling state:
`pendingCauses`, `invalidatedIdentities`, `signalNames`, `externalReasons`,
`nextDeadline`, and animation request fields
(`swift-tui/Sources/SwiftTUICore/Pipeline/Scheduler.swift:105-116`).

Only the wake handler and pending-frame waiters are lock-protected
(`Scheduler.swift:117-124`). Request methods mutate the core sets directly
(`Scheduler.swift:137-174`).

Given the surrounding runtime, this appears intended to be MainActor-confined.
But the type and protocols do not encode that confinement strongly. If future
off-main model work, external wakeups, or background observation callbacks call
into the scheduler directly, this becomes a race.

Recommended design cleanup:

- Make the scheduler-facing mutation protocol explicitly MainActor-isolated, or
- split cross-thread wake submission into a small locked/sendable mailbox whose
  drain runs on MainActor.

Do this before increasing the number of off-main producers.

### 6. The lock strategy is mostly conservative and appropriate

The codebase generally uses `Synchronization.Mutex` or the local
`OSAllocatedUnfairLock` compatibility wrapper rather than unchecked sendability.
Examples include frame-tail retained state, render hooks, terminal host state,
input readers, layout pass context, measurement caches, and text caches.

This is a good baseline. The caveat is that many of these locks look sized for
the current design: one serial tail queue plus a separate layout worker path.
If the next step is parallel subtree layout/raster, expect lock contention and
cache design to become a real issue. Do not jump from one serial worker to many
parallel workers without measuring whether the serial worker is saturated.

### 7. Example apps still contain avoidable MainActor work

The file previewer performs directory loading through a MainActor cache:

- `DirectoryEntryCache` is `@MainActor`, and its loader type is also
  `@MainActor`
  (`swift-tui-examples/file-previewer/Sources/FilePreviewerApp/DirectoryEntryCache.swift:3-15`).
- `ColumnBrowser.body` asks for entries while building columns
  (`swift-tui-examples/file-previewer/Sources/FilePreviewerApp/ColumnBrowser.swift:37-47`).
- `FileEntry.entries` uses synchronous `FileManager.contentsOfDirectory`
  (`swift-tui-examples/file-previewer/Sources/FilePreviewerApp/FileEntry.swift:24-46`).

That is exactly the kind of work that should move behind an actor/task and
publish a `[FileEntry]` snapshot back to the UI.

The GIF editor has already moved save-preview generation into a detached task:
`swift-tui-examples/gifeditor/Sources/GIFEditorUI/SaveGIFSheetView.swift:68-75`.
That pattern should be generalized for IO, decoding, compositing, indexing, and
other derived data.

---

## Recommended sequencing

### Wave 1: Measure before moving boundaries

Use existing profiling and TermUIPerf modes to classify workloads:

```bash
SWIFTTUI_PROFILE="frames;tsv=/tmp/swifttui-frames.tsv" <scenario command>
TERMUI_RENDER_MODE=async <scenario command>
TERMUI_RENDER_MODE=async-no-cancel <scenario command>
TERMUI_RENDER_MODE=async-no-drop <scenario command>
```

Look first at:

- `main_actor_blocked_ms`
- `main_actor_suspended_ms`
- `resolved_computed` / `resolved_reused`
- `worker_layout_enqueue_ms` / `worker_layout_compute_ms`
- `worker_raster_enqueue_ms` / `worker_raster_compute_ms`
- `layout_dependent_main_actor_fallbacks`
- cancelled/dropped frame counts and drop reasons

### Wave 2: Chase the dominant bucket

If `main_actor_blocked_ms` is high and resolved recompute is high, prioritize
invalidation/reuse. If layout fallbacks are high, widen layout offload. If
worker compute dominates while MainActor is suspended, optimize tail algorithms,
damage, caches, and retained tail state. If many queued frames are cancelled or
dropped usefully, improve cancellation/drop policy before adding workers.

### Wave 3: Harden cross-thread invalidation

Before treating off-main model mutation as supported, fix or explicitly fence:

- `ObservationBridge`'s `MainActor.assumeIsolated` callback.
- `FrameScheduler`'s type-level confinement story.

The goal is not to make all UI state thread-safe. The goal is to make background
producers submit invalidations through one safe, coalesced route.

### Wave 4: Offload app work

Move example/app work that is not UI authoring into model actors or detached
tasks:

- filesystem reads
- git/process output parsing
- image/GIF decoding and encoding
- compositing and thumbnails
- search/indexing/filtering
- expensive diff/summary generation

Publish immutable/sendable snapshots to the MainActor view layer.

---

## What not to do first

- Do not make `View.body` generally non-main actor as a perf experiment. That
  cuts across public API, state, environment, observation, task lifecycle, and
  graph mutation.
- Do not add broad parallel subtree rendering until the serial tail worker is
  proven saturated and lock/cache contention is measured.
- Do not let off-main producers call `FrameScheduler` or `ObservationBridge`
  directly through convention. Add an explicit mailbox/hop boundary.
- Do not chase raster/layout offload if diagnostics show the MainActor frame
  head is the limiting factor.

---

## Bottom line

The best payoff order is:

1. **Profile and bucket the cost.**
2. **Reduce MainActor frame-head work through invalidation/reuse.**
3. **Widen layout offload eligibility where diagnostics show fallback.**
4. **Harden observation/scheduler boundaries for background producers.**
5. **Move app-level IO and derived data to background tasks/actors.**

SwiftTUI already has the right architectural seam for off-main frame-tail work.
The next gains should come from feeding that seam more worker-safe input and
avoiding unnecessary MainActor frame-head churn.
