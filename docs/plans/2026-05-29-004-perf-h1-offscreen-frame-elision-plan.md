# H1 Off-screen Frame Elision — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Skip the rendering pipeline (place→raster→commit) for animation-deadline frames whose redraw set can't reach the visible surface, while still firing completion callbacks on real-time schedule and advancing animation state — recovering the ~5.6 CPU-s H1 hot spot.

**Architecture:** Insert a gate immediately after the `animationInjection` stage in `RuntimeRenderPipeline`. When the frame is animation-deadline-only and the tick's `redrawIdentities` are disjoint from the previously-drawn surface, route to a **reduced commit** that commits only the draft transaction (fires deferred completions + publishes advanced animation state via `AnimationFrameDraft.commit()`) and skips `latePreferenceReconciliation`/`fusedFrameTail`/artifact-presentation. The run loop still schedules the next deadline (no restart trap) and increments an `elided_frames` diagnostic.

**Tech Stack:** Swift 6.3.1 (Swift 6 mode), Swift Testing (`import Testing`), SwiftPM via `swiftly run swift ...`, `swift-tui` submodule (`SwiftTUIRuntime`, `SwiftTUICore`). Perf proof via `Tools/TermUIPerf` (`termui-perf compare`).

**Spec:** [`2026-05-29-003-perf-h1-offscreen-frame-elision-design.md`](2026-05-29-003-perf-h1-offscreen-frame-elision-design.md)
**Code baseline:** `swift-tui` `main` @ `375dbbb5`

---

## Working environment

All code changes are in the **`swift-tui` submodule**. Per the org workflow, make changes inside `swift-tui/`, commit there, then record the pin in the org root separately (out of scope for this plan). Recommended: create an isolated worktree of `swift-tui` for execution (superpowers:using-git-worktrees).

Build/test commands (run inside `swift-tui/`):
- One suite: `swiftly run swift test --filter SwiftTUITests.<SuiteName>`
- One test: `swiftly run swift test --filter SwiftTUITests.<SuiteName>/<testName>`
- Build: `swiftly run swift build`
- Format (required before commit): `swift format format -i --configuration .swift-format.json Sources/ Tests/`
- Repo gate (after shared-code changes): `bun run test`

Conventions: 2-space indent, 100-col, `private` not `fileprivate`, no block comments. Commit message type `perf:` or `feat:`/`test:`/`refactor:` as appropriate; **no attribution trailer** (disabled globally).

---

## File Structure

**Create:**
- `Sources/SwiftTUICore/Pipeline/OffscreenFrameElision.swift` — the pure gate predicate (`OffscreenFrameElision.shouldElide(...)`), no runtime dependencies. Lives in Core so it's unit-testable without the runtime.
- `Tests/SwiftTUICoreTests/OffscreenFrameElisionTests.swift` — predicate truth-table unit tests.
- `Tests/SwiftTUITests/OffscreenFrameElisionRuntimeTests.swift` — runtime integration tests (completion timing, reveal, oracle soundness, all executors).

**Modify:**
- `Sources/SwiftTUIRuntime/Rendering/FrameHeadDraftTransaction.swift` — add `commitElided()` (Task 1 decides its exact body).
- `Sources/SwiftTUIRuntime/Rendering/DefaultRenderer+CompletedFrameCandidates.swift` — add `commitElidedFrame(draft:)` (Task 5).
- `Sources/SwiftTUIRuntime/Rendering/RuntimeRenderPipeline.swift` — add the post-injection gate + new handler field, in all three executors (Task 6).
- `Sources/SwiftTUIRuntime/Rendering/FrameTailRenderer.swift` + `FrameTailRetainedState.swift` — expose `previousDrawnIdentities` accessor (Task 3).
- `Sources/SwiftTUIRuntime/SwiftTUI.swift` — supply the new handler when constructing stage handlers (Task 6), and pass `previousDrawnIdentities` + `scheduledFrame.causes`.
- `Sources/SwiftTUIRuntime/RunLoop/RunLoop+FrameAcquisitionOutcome.swift` — add `.elided` outcome handling (Task 7).
- `Sources/SwiftTUIRuntime/Diagnostics/` (relevant frame-record file) — add `elided_frames` / per-frame `elided` column (Task 4).

---

## Task 1: SPIKE — establish the reduced-commit seam

**Why a spike:** `FrameHeadTransaction.commit()` (`FrameHeadDraftTransaction.swift:75-83`) atomically commits four sub-drafts (graph registrations, observation, presentation portal, animation) and is invoked from inside `commitFrameEffects`→`finalizeFrame` (`DefaultRenderer+CompletedFrameCandidates.swift:96-182`). The elision path needs to fire animation completions + publish animation state **without** running `finalizeFrame`/`commitPlanner.plan`/`publishCommittedFrame`/present. Neither existing disposition fits: `commit()` runs the full heavy path's prerequisites; `discard()` requires checkpoints (one-shot heads have none → `preconditionFailure`) and does **not** fire animation completions. So a new disposition is required, and its exact safe contents must be determined against the code, not guessed.

**Files to read:**
- `Sources/SwiftTUIRuntime/Rendering/FrameHeadDraftTransaction.swift` (commit/discard/materialize/suspend)
- `Sources/SwiftTUIRuntime/Lifecycle/AnimationController.swift:1267-1302` (`AnimationFrameDraft.commit/discard`)
- The bodies of `graphDraft.commitRuntimeRegistrations(from:)`, `observationDraft.commit()`, `presentationPortalDraft.commit()` (find via grep) — to determine whether each is safe to run on a frame that produced no `placed`/raster output.

- [ ] **Step 1: Answer the four seam questions in writing.**
  1. On an animation-deadline-only, zero-on-screen-redraw frame, are there ever *new* graph runtime registrations that must commit? (The head resolve ran before injection; check whether `commitRuntimeRegistrations` can be a no-op or must run.)
  2. Can `observationDraft.commit()` and `presentationPortalDraft.commit()` run safely without a committed placed tree / `publishCommittedFrame`? Or must they be discarded?
  3. Does `animationDraft.commit()` depend on anything `finalizeFrame` produces? (Expected: no — it only needs the draft controller state advanced during injection.)
  4. Is a new `FrameAcquisitionOutcome` case needed, or can `.skipped` be reused after the reduced commit? (Loop liveness + diagnostics differ from cancel/drop, so a distinct `.elided` is likely.)

- [ ] **Step 2: Decide and record the `commitElided()` contract.**
  Append a short "Reduced-commit seam decision" section to the design doc (`2026-05-29-003-...md`) stating: which sub-drafts `commitElided()` commits vs discards, why each is safe, and the exact signature:
  ```swift
  // FrameHeadTransaction
  package func commitElided() -> RuntimeRegistrationDiagnostics
  ```
  (Most likely body: commit graph registrations + observation + portal + animation — i.e. the same four as `commit()` — but with a precondition note that no `finalizeFrame`/present runs afterward, OR a reduced subset if Step 1 finds graph/portal commits require placed output.)

- [ ] **Step 3: Commit the decision note.**
  ```bash
  git -C ../.. add docs/plans/2026-05-29-003-perf-h1-offscreen-frame-elision-design.md
  git -C ../.. commit -m "docs: H1 reduced-commit seam decision (spike outcome)"
  ```
  (Path note: design doc is in the org root, not the submodule.)

**Deliverable:** the `commitElided()` contract + a yes/no on a new `.elided` outcome case. Tasks 5 and 7 consume these.

---

## Task 2: Gate predicate (pure, unit-tested)

**Files:**
- Create: `Sources/SwiftTUICore/Pipeline/OffscreenFrameElision.swift`
- Test: `Tests/SwiftTUICoreTests/OffscreenFrameElisionTests.swift`

- [ ] **Step 1: Write the failing test.**

```swift
import Testing
@testable import SwiftTUICore

@Suite("OffscreenFrameElision")
struct OffscreenFrameElisionTests {
  private func id(_ n: Int) -> Identity { Identity.forTesting(n) }

  @Test("Elides a deadline-only frame whose redraw is fully off-screen")
  func elidesOffscreenDeadlineFrame() {
    #expect(
      OffscreenFrameElision.shouldElide(
        causes: [.deadline],
        animationRequest: .inherit,
        redrawIdentities: [id(1), id(2)],
        drawnIdentities: [id(3), id(4)]
      ) == true)
  }

  @Test("Does not elide when redraw overlaps the drawn surface")
  func rendersWhenRedrawOverlapsDrawn() {
    #expect(
      OffscreenFrameElision.shouldElide(
        causes: [.deadline],
        animationRequest: .inherit,
        redrawIdentities: [id(1), id(3)],
        drawnIdentities: [id(3), id(4)]
      ) == false)
  }

  @Test("Does not elide when any non-deadline cause is present", arguments: [
    WakeCause.input, .invalidation, .signal, .external,
  ])
  func rendersWhenNonDeadlineCause(extra: WakeCause) {
    #expect(
      OffscreenFrameElision.shouldElide(
        causes: [.deadline, extra],
        animationRequest: .inherit,
        redrawIdentities: [id(1)],
        drawnIdentities: [id(3)]
      ) == false)
  }

  @Test("Does not elide when an explicit animation transaction is requested")
  func rendersWhenAnimationRequested() {
    #expect(
      OffscreenFrameElision.shouldElide(
        causes: [.deadline],
        animationRequest: .start(.default),
        redrawIdentities: [id(1)],
        drawnIdentities: [id(3)]
      ) == false)
  }

  @Test("Elides the empty-redraw drain case (nothing to render)")
  func elidesEmptyRedrawDrain() {
    #expect(
      OffscreenFrameElision.shouldElide(
        causes: [.deadline],
        animationRequest: .inherit,
        redrawIdentities: [],
        drawnIdentities: [id(3)]
      ) == true)
  }
}
```

Note: confirm the `Identity.forTesting(_:)` helper exists in `SwiftTUICoreTests`; if not, use the existing test-identity constructor (grep `Identity(` in `Tests/SwiftTUICoreTests`). Confirm `AnimationRequest` case spelling (`.inherit`, `.start(...)`) via `grep -rn "enum AnimationRequest" Sources/`.

- [ ] **Step 2: Run the test to verify it fails.**
  Run: `swiftly run swift test --filter SwiftTUICoreTests.OffscreenFrameElision`
  Expected: FAIL — `OffscreenFrameElision` undefined.

- [ ] **Step 3: Implement the predicate.**

```swift
/// Decides whether a frame produced solely by an animation deadline can skip
/// the rendering pipeline because its redraw can't reach the visible surface.
///
/// The visible-surface oracle is the same `redrawIdentities` set the
/// incremental-presentation diff already trusts; elision is exactly as sound
/// as that set's cross-subtree tracking (an off-screen animation that shifts an
/// on-screen sibling must surface that sibling in `redrawIdentities`).
public enum OffscreenFrameElision {
  public static func shouldElide(
    causes: Set<WakeCause>,
    animationRequest: AnimationRequest,
    redrawIdentities: Set<Identity>,
    drawnIdentities: Set<Identity>
  ) -> Bool {
    guard causes == [.deadline] else { return false }
    guard animationRequest == .inherit else { return false }
    return redrawIdentities.isDisjoint(with: drawnIdentities)
  }
}
```

If `AnimationRequest` is not `Equatable`, replace `== .inherit` with a pattern match (`if case .inherit = animationRequest`) and adjust the parameter; verify with grep before writing.

- [ ] **Step 4: Run the test to verify it passes.**
  Run: `swiftly run swift test --filter SwiftTUICoreTests.OffscreenFrameElision`
  Expected: PASS (all cases).

- [ ] **Step 5: Format and commit.**
```bash
swift format format -i --configuration .swift-format.json Sources/SwiftTUICore/Pipeline/OffscreenFrameElision.swift Tests/SwiftTUICoreTests/OffscreenFrameElisionTests.swift
git add Sources/SwiftTUICore/Pipeline/OffscreenFrameElision.swift Tests/SwiftTUICoreTests/OffscreenFrameElisionTests.swift
git commit -m "feat: OffscreenFrameElision gate predicate"
```

---

## Task 3: Expose previous-frame `drawnIdentities`

**Files:**
- Modify: `Sources/SwiftTUIRuntime/Rendering/FrameTailRetainedState.swift`
- Modify: `Sources/SwiftTUIRuntime/Rendering/FrameTailRenderer.swift`

- [ ] **Step 1: Write the failing test** in `Tests/SwiftTUITests/OffscreenFrameElisionRuntimeTests.swift`:

```swift
import Testing
@testable import SwiftTUIRuntime

@Suite("OffscreenFrameElisionRuntime")
@MainActor
struct OffscreenFrameElisionRuntimeTests {
  @Test("previousDrawnIdentities is empty before any frame commits")
  func previousDrawnIdentitiesEmptyInitially() {
    let renderer = DefaultRenderer.forTesting()  // use existing test factory
    #expect(renderer.frameTailRenderer.previousDrawnIdentities.isEmpty)
  }
}
```
Confirm the existing `DefaultRenderer` test factory name via grep in `Tests/SwiftTUITests` (e.g. `DefaultRenderer(` construction). If none, construct via the existing harness used by `AsyncFrameTailRenderingTests`.

- [ ] **Step 2: Run to verify it fails.**
  Run: `swiftly run swift test --filter SwiftTUITests.OffscreenFrameElisionRuntime/previousDrawnIdentitiesEmptyInitially`
  Expected: FAIL — `previousDrawnIdentities` undefined.

- [ ] **Step 3: Add the accessor.**
  In `FrameTailRetainedState.swift`, add (reading under the existing `state.withLock`):
```swift
  var previousDrawnIdentities: Set<Identity> {
    state.withLock { $0.previousFrameIndex?.frame.drawnIdentities ?? [] }
  }
```
  Confirm `previousFrameIndex?.frame.drawnIdentities` is reachable (the indexed frame retains `FrameArtifacts`; `drawnIdentities` is on it via `CommittedFrameArtifactBuilder.swift:168`). In `FrameTailRenderer.swift`, expose a forwarding accessor:
```swift
  var previousDrawnIdentities: Set<Identity> {
    retainedState.previousDrawnIdentities
  }
```

- [ ] **Step 4: Run to verify it passes.**
  Run: `swiftly run swift test --filter SwiftTUITests.OffscreenFrameElisionRuntime/previousDrawnIdentitiesEmptyInitially`
  Expected: PASS.

- [ ] **Step 5: Format and commit.**
```bash
swift format format -i --configuration .swift-format.json Sources/SwiftTUIRuntime/Rendering/FrameTailRetainedState.swift Sources/SwiftTUIRuntime/Rendering/FrameTailRenderer.swift Tests/SwiftTUITests/OffscreenFrameElisionRuntimeTests.swift
git add -A && git commit -m "feat: expose previous-frame drawnIdentities for elision oracle"
```

---

## Task 4: `elided_frames` diagnostic

**Files:**
- Modify: the per-frame diagnostics record (find via `grep -rn "drop_blockers\|committed_frame_count" Sources/SwiftTUIRuntime/Diagnostics Sources/SwiftTUIProfiling`).

- [ ] **Step 1: Write the failing test** (extend the runtime suite):
```swift
  @Test("elidedFrameCount starts at zero")
  func elidedFrameCountStartsZero() {
    let renderer = DefaultRenderer.forTesting()
    #expect(renderer.elidedFrameCount == 0)
  }
```

- [ ] **Step 2: Run to verify it fails.**
  Run: `swiftly run swift test --filter SwiftTUITests.OffscreenFrameElisionRuntime/elidedFrameCountStartsZero`
  Expected: FAIL — `elidedFrameCount` undefined.

- [ ] **Step 3: Add a counter** on `DefaultRenderer` (or `RunLoop`, matching where `renderedFrames` lives):
```swift
  private(set) var elidedFrameCount = 0
  func recordElidedFrame() { elidedFrameCount += 1 }
```
  Add an `elided` boolean column to the per-frame TSV record and an `elided_frames` total to the run summary, alongside the existing frame columns (mirror how `committed_frame_count` is emitted). This makes elision provable in `termui-perf` output (Task 9).

- [ ] **Step 4: Run to verify it passes.**
  Run: `swiftly run swift test --filter SwiftTUITests.OffscreenFrameElisionRuntime/elidedFrameCountStartsZero`
  Expected: PASS.

- [ ] **Step 5: Format and commit.**
```bash
swift format format -i --configuration .swift-format.json Sources/ Tests/
git add -A && git commit -m "feat: elided_frames diagnostic counter + TSV column"
```

---

## Task 5: `commitElidedFrame` on DefaultRenderer (consumes Task 1 seam)

**Files:**
- Modify: `Sources/SwiftTUIRuntime/Rendering/FrameHeadDraftTransaction.swift` (add `commitElided()` per Task 1 decision)
- Modify: `Sources/SwiftTUIRuntime/Rendering/DefaultRenderer+CompletedFrameCandidates.swift`

- [ ] **Step 1: Write the failing test** (runtime suite) — pins the load-bearing invariant:
```swift
  @Test("commitElidedFrame fires deferred completions and advances the live clock")
  func elidedCommitFiresCompletionsAndAdvancesClock() async throws {
    // Drive a frame with an off-screen withAnimation completion via the real
    // RunLoop input path (see AnimationRepeatForeverGrowthTests for harness).
    // Arrange a draft whose injection deferred a completion; call the elided
    // path; assert (a) the completion closure ran, and (b) the live controller's
    // animation state advanced (lastTickResult published).
  }
```
  Flesh out the body using the same `RunLoop`/controller harness as `AnimationRepeatForeverGrowthTests`; assert the completion side-effect fired and `renderer.internalAnimationController.lastTickResult` reflects the post-injection tick.

- [ ] **Step 2: Run to verify it fails.**
  Run: `swiftly run swift test --filter SwiftTUITests.OffscreenFrameElisionRuntime/elidedCommitFiresCompletionsAndAdvancesClock`
  Expected: FAIL — `commitElidedFrame` undefined.

- [ ] **Step 3: Implement, per the Task 1 seam decision.**
  In `FrameHeadDraftTransaction.swift`, add `commitElided()` with the decided body (default expectation — commit the four sub-drafts, matching `commit()` minus nothing, since the four commits are independent of `finalizeFrame`):
```swift
  package func commitElided() -> RuntimeRegistrationDiagnostics {
    precondition(!didCommit && !didDiscard)
    let diagnostics = graphDraft.commitRuntimeRegistrations(from: viewGraph)
    observationDraft?.commit()
    presentationPortalDraft.commit()
    animationDraft.commit()
    didCommit = true
    return diagnostics
  }
```
  (If Task 1 found any sub-draft unsafe without placed output, substitute its decided disposition here and update the design-doc note.)
  In `DefaultRenderer+CompletedFrameCandidates.swift`, add:
```swift
  @MainActor
  func commitElidedFrame(draft: FrameHeadDraft) {
    draft.transaction.materializePreparedState()
    _ = draft.transaction.commitElided()
    recordElidedFrame()
  }
```

- [ ] **Step 4: Run to verify it passes.**
  Run: `swiftly run swift test --filter SwiftTUITests.OffscreenFrameElisionRuntime/elidedCommitFiresCompletionsAndAdvancesClock`
  Expected: PASS.

- [ ] **Step 5: Format and commit.**
```bash
swift format format -i --configuration .swift-format.json Sources/ Tests/
git add -A && git commit -m "feat: reduced-commit path for elided frames (fires completions, advances clock)"
```

---

## Task 6: Wire the gate into the three executors

**Files:**
- Modify: `Sources/SwiftTUIRuntime/Rendering/RuntimeRenderPipeline.swift`
- Modify: `Sources/SwiftTUIRuntime/SwiftTUI.swift` (handler construction at the three `injectAnimations` call sites: ~`:222`, `:322`, `:403`)

- [ ] **Step 1: Write the failing test** — a structural test that the executor short-circuits after injection when the gate fires:
```swift
  @Test("renderAsync skips tail+commit when the elision gate fires")
  func asyncExecutorElidesAfterInjection() async {
    // Build handlers whose fusedFrameTail sets a flag if called; supply an
    // elide handler returning true. Assert: fusedFrameTail flag stays false,
    // commit flag stays false, and the elide handler's commit ran.
  }
```

- [ ] **Step 2: Run to verify it fails.**
  Run: `swiftly run swift test --filter SwiftTUITests.OffscreenFrameElisionRuntime/asyncExecutorElidesAfterInjection`
  Expected: FAIL — no elide handler / not short-circuiting.

- [ ] **Step 3: Add an `elide` handler to each stage-handler struct and gate after `animationInjection`.**
  Add to `OneShotRenderStageHandlers`, `AsyncRenderStageHandlers`, `CancellableRenderStageHandlers`:
```swift
  var elideIfOffscreen: (FrameHeadDraft) -> Bool
```
  In each executor loop, right after the `.animationInjection` case assigns `currentDraft`, insert:
```swift
        if handlers.elideIfOffscreen(currentDraft) {
          // Reduced commit already ran inside the handler; skip remaining stages.
          // Return the executor's "elided" sentinel (see Task 7 for the outcome type).
          return <elided sentinel>
        }
```
  For `renderOneShot`/`renderAsync` (return `FrameArtifacts`): change the return type to an enum `RenderExecutionResult { case rendered(FrameArtifacts); case elided }` (or reuse the cancellable outcome pattern) — Task 1 decided whether a new case is needed. The `elideIfOffscreen` closure (supplied in `SwiftTUI.swift`) computes the predicate and, when true, calls `commitElidedFrame(draft:)` then returns `true`:
```swift
  elideIfOffscreen: { draft in
    let tick = draft.animationDraft.controller.lastTickResult
    guard OffscreenFrameElision.shouldElide(
      causes: scheduledFrame.causes,
      animationRequest: scheduledFrame.animationRequest,
      redrawIdentities: tick.redrawIdentities,
      drawnIdentities: renderer.frameTailRenderer.previousDrawnIdentities
    ) else { return false }
    renderer.commitElidedFrame(draft: draft)
    return true
  }
```
  Thread `scheduledFrame` into the handler-construction scope (it is already available where the render path is invoked).

- [ ] **Step 4: Run to verify it passes.**
  Run: `swiftly run swift test --filter SwiftTUITests.OffscreenFrameElisionRuntime/asyncExecutorElidesAfterInjection`
  Expected: PASS.

- [ ] **Step 5: Build all + format + commit.**
```bash
swiftly run swift build
swift format format -i --configuration .swift-format.json Sources/ Tests/
git add -A && git commit -m "feat: post-injection elision gate in all three render executors"
```

---

## Task 7: Run-loop outcome handling + keep loop alive

**Files:**
- Modify: `Sources/SwiftTUIRuntime/RunLoop/RunLoop+FrameAcquisitionOutcome.swift` (and the acquisition entry that maps executor result → `FrameAcquisitionOutcome`)
- Modify: `Sources/SwiftTUIRuntime/RunLoop/RunLoop+Rendering.swift` (ensure `requestNextAnimationFrameIfNeeded` still runs on the elided path)

- [ ] **Step 1: Write the failing test** — the no-restart-trap invariant:
```swift
  @Test("An elided frame still schedules the next animation deadline")
  func elidedFrameKeepsLoopAlive() async {
    // Drive an off-screen perpetual animation through the RunLoop; after an
    // elided frame, assert the scheduler has a pending deadline (loop not frozen)
    // and that a subsequent on-screen invalidation renders normally.
  }
```

- [ ] **Step 2: Run to verify it fails.**
  Run: `swiftly run swift test --filter SwiftTUITests.OffscreenFrameElisionRuntime/elidedFrameKeepsLoopAlive`
  Expected: FAIL.

- [ ] **Step 3: Handle the elided outcome.**
  Add `case elided` to `FrameAcquisitionOutcome` (if Task 1 decided so). In the acquisition mapping, when the executor returns the elided sentinel, return `.elided`. In the per-frame driver, on `.elided`:
  - skip `presentCommittedFrameWithDiagnosticsTiming` / `publishCommittedFrame` / `recordPresentedRasterSurface`,
  - still call `requestNextAnimationFrameIfNeeded(renderer.internalAnimationController.lastTickResult)`,
  - emit the per-frame diagnostic with `elided = true` (Task 4),
  - do **not** increment `renderedFrames` (it produced no rendered frame), but do record progress as an elided frame.

- [ ] **Step 4: Run to verify it passes.**
  Run: `swiftly run swift test --filter SwiftTUITests.OffscreenFrameElisionRuntime/elidedFrameKeepsLoopAlive`
  Expected: PASS.

- [ ] **Step 5: Format and commit.**
```bash
swift format format -i --configuration .swift-format.json Sources/ Tests/
git add -A && git commit -m "feat: route elided frames through run loop without present, keep deadline alive"
```

---

## Task 8: Integration correctness tests

**Files:**
- Modify: `Tests/SwiftTUITests/OffscreenFrameElisionRuntimeTests.swift`

- [ ] **Step 1: Write the tests** (each is its own `@Test`; use the real `RunLoop` input-path harness from `AnimationRepeatForeverGrowthTests`):
  - **Completion timing:** off-screen `withAnimation { … } completion:` fires on real-time schedule across a run of elided frames.
  - **Reveal correctness:** after N elided frames, an invalidation that brings content on-screen renders the *current* animation state (state advanced each tick).
  - **Oracle soundness:** an off-screen animation that shifts an on-screen sibling's layout produces a redraw set overlapping `drawnIdentities` → frame is **not** elided (renders).
  - **Matched-geometry / removal:** a removal/matched-geometry animation interleaved with off-screen ticks commits correctly (no corruption from skipped `capturePlacedTree`).
  - **Sync parity:** the same off-screen scenario elides under `renderOneShot` (sync mode) as under `renderAsync`.

- [ ] **Step 2: Run the suite.**
  Run: `swiftly run swift test --filter SwiftTUITests.OffscreenFrameElisionRuntime`
  Expected: all PASS. Fix implementation (not tests) for any failure.

- [ ] **Step 3: Run the adjacent regression suites.**
  Run: `swiftly run swift test --filter SwiftTUITests.AnimationRepeatForeverGrowthTests` and `--filter SwiftTUITests.AnimationTickVisibilityTests` and `--filter SwiftTUICoreTests.FrameDropEligibilityTests`
  Expected: all PASS (no regressions).

- [ ] **Step 4: Full gate.**
  Run: `bun run test`
  Expected: PASS.

- [ ] **Step 5: Format and commit.**
```bash
swift format format -i --configuration .swift-format.json Tests/
git add -A && git commit -m "test: H1 elision correctness — completions, reveal, oracle, matched-geometry, sync parity"
```

---

## Task 9: Perf proof (the success gate)

**Files:** none (measurement only). Run inside `swift-tui/`.

- [ ] **Step 1: Capture the BEFORE baseline** (on the pre-H1 commit or by stashing — record the SHA):
```bash
git stash  # or checkout the parent commit
swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
  run --scenario synthetic-offscreen-phase-animator --modes async \
  --iterations 20 --configuration release
# note the run dir under .perf/runs/
git stash pop
```

- [ ] **Step 2: Capture the AFTER run** (with H1 built):
```bash
swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
  run --scenario synthetic-offscreen-phase-animator --modes async \
  --iterations 20 --configuration release
```

- [ ] **Step 3: Compare with the G2 significance verdict.**
```bash
swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
  compare <before-run-dir> <after-run-dir>
```
  Expected: a statistically-significant drop in `total_cpu_seconds` and a non-zero `elided_frames` in the AFTER run. Record the numbers in the design doc.

- [ ] **Step 4: Update the report + design doc** with the measured result (before/after CPU, elided-frame count, compare verdict). Commit:
```bash
git -C ../.. add docs/
git -C ../.. commit -m "docs: H1 perf result — synthetic-offscreen-phase-animator CPU drop"
```

---

## Self-Review

**Spec coverage:**
- §2 success criteria → Task 9 (CPU drop + `elided_frames` via Task 4).
- §4 architecture (post-injection gate) → Tasks 2, 6.
- §4.2 reduced commit → Tasks 1, 5.
- §5 gate conditions (deadline-only, disjoint, oracle soundness) → Task 2 predicate + Task 8 oracle test.
- §5 completion-timing invariant → Task 5 + Task 8.
- §6 reveal → Task 8.
- §7 testing (all executors, matched-geometry, regression suites) → Tasks 6, 8.
- §8 risks (deferred completions, placed-tree skip, oracle, transition coherence, refactor safety) → Task 1 spike + Task 8 tests + Task 8 full gate.
- §9 scope (runtime-only, no example edits) → respected; no gallery files touched.

**Placeholder scan:** Task 1 is a spike (legitimate — produces a decision artifact + signature, not deferred work). Tasks 5/6/7 reference the spike's decision for the seam body and outcome-case question; their contracts, tests, and wiring are concrete. Test bodies in Tasks 5–8 reference the existing `AnimationRepeatForeverGrowthTests` harness rather than reproducing it (the harness is real and inspectable). No "add error handling"/"TBD" steps.

**Type consistency:** `OffscreenFrameElision.shouldElide(causes:animationRequest:redrawIdentities:drawnIdentities:)` used identically in Task 2 and Task 6. `commitElided()` (Task 1/5) → `commitElidedFrame(draft:)` (Task 5) → `elideIfOffscreen` handler (Task 6) → `.elided` outcome (Task 7) form one consistent chain. `previousDrawnIdentities` named identically in Tasks 3 and 6.

**Pre-execution verifications flagged inline:** `Identity` test constructor, `AnimationRequest` Equatable/case spelling, `DefaultRenderer` test factory, diagnostics record file — each task says to grep-confirm before writing.

---

## Notes carried forward
- **Approach 2 (wakeup coalescing)** remains a flagged follow-on, gated on Task 9 showing residual wakeup overhead is material. Not in this plan.
- After Task 9, the org-root pin bump to the new `swift-tui` commit is a separate coordination step (org workflow), not part of this submodule plan.
