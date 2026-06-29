# Gallery TODO Deep Dive

Date: 2026-06-29

## Scope

This report investigates the issues listed in the root `TODO.md`:

- Gallery: transitioning off of the Logo Breaker tab takes forever.
- Gallery: Presentation Lab overlays are sometimes unclosable; in that state the background remains interactive.
- Gallery: Focus Context tab can crash after repeated Tab presses, and Tab appears to do nothing before the crash.
- `swift-tui` test coverage does not cover complex gallery issues well enough.
- `gifeditor` drawing performance is unacceptable.

The goal is not to patch the symptoms directly in this report. The goal is to
identify the implementation surfaces, explain likely failure modes, and propose
a fix path that produces small framework regressions plus the needed gallery
integration coverage.

## Executive Summary

The TODO items describe three gallery runtime failures, one test-strategy gap,
and one already-investigated performance problem.

The likely common thread for the gallery failures is that the demo tabs exercise
framework seams that isolated unit tests do not currently stress:

- Lazy `TabView` active-body teardown and `.task` cancellation.
- Presentation portal modal policy, dismiss stack, and focus/base-interaction
  gating inside a real tabbed shell.
- Focused values and `@FocusedBinding` during live focus traversal in a
  `TabView` scene.

The fix approach should therefore start with reproducing each symptom in the
gallery package, then reduce each red test into a smaller `swift-tui` framework
test before patching the framework. The gallery tests remain useful as
end-to-end oracles because earlier synthetic tests have missed capture-host and
lazy-tab behavior.

The `gifeditor` performance issue already has a dedicated report:
`docs/reports/2026-06-24-gifeditor-perf-deepdive.md`. Its fix should be
implemented as a content-keyed composite/thumbnail cache in the example app,
with regression measurement so the same render shape does not return.

Follow-up coverage plan: `docs/reports/2026-06-29-swifttui-gallery-coverage-deep-dive.md`
breaks the Gallery issues into concrete `swift-tui` framework tests and ranks
adjacent Gallery behaviors that should move down into framework coverage.

## Issue 1: Logo Breaker Is Slow While Active And Slow To Leave

### Relevant Surface

The Logo Breaker tab is registered in:

- `swift-tui-examples/gallery/Sources/GalleryDemoViews/GalleryView.swift`
- `swift-tui-examples/gallery/Sources/GalleryDemoViews/LogoTab.swift`

`LogoTab` uses a 25 Hz autonomous `.task` loop:

- `LogoTab.body` installs `.task(id: LogoBreakerGame.BoundsID(size: fieldBounds))`.
- `runGameLoop(...)` sleeps for `LogoBreakerGame.tickNanoseconds`.
- `LogoBreakerGame.tickNanoseconds` is `40_000_000`, or roughly 25 Hz.
- Each tick can update `ball` and `brokenBrickIDs`, which invalidates the view.

An additional observed symptom is that Logo Breaker appears slower than it used
to while it is still the active tab: fewer simulation frames are visibly
rendered. That makes the issue broader than leave-teardown. The investigation
needs to distinguish simulation tick cadence from render/presentation cadence.

`TabView` is intentionally lazy:

- Inactive tab bodies should not be resolved.
- Active tab content is stored as a `LazySubviewPayload`.
- A selected tab switch should remove the old active payload, cancel its
  lifecycle effects, and only run the new active tab body.

Existing framework tests cover "inactive tabs do not start tasks", but they do
not prove that an already-active tab's autonomous task is cancelled when leaving
that tab in the full gallery shell.

The gallery package has a useful nearby regression test:

- `TaskProgressTabTeardownTests` verifies that the Task Progress tab leaves no
  active tasks after switching to another tab.

That test passed during this investigation, which is good evidence that one
known lazy-tab/capture-host path is currently protected. It does not cover the
Logo Breaker tab's geometry-driven `.task(id:)` loop.

### Likely Failure Mode

If Logo Breaker is slow while active, there are two different failure classes:

- The game loop itself is not reaching its intended 25 Hz cadence.
- The game loop is ticking, but fewer committed frames reach the terminal.

Those point to different implementation layers. Slow simulation ticks suggest
task scheduling, actor starvation, or an unexpectedly expensive per-tick update.
Normal ticks with low rendered-frame cadence suggest invalidation coalescing,
frame dropping, retained-reuse/frontier behavior, or an expensive render path
that cannot keep up with the updates.

If leaving Logo Breaker is also slow, task teardown is still a prime suspect. A
surviving 25 Hz task can keep writing state, which keeps requesting frames after
the tab should have left the active body. That can make a tab transition feel
stuck or repeatedly re-enter layout.

There is also a small defensive bug in `runGameLoop`: `Task.sleep` is wrapped in
`try?`. If cancellation arrives during sleep, the loop continues through one more
physics step before the next top-of-loop `Task.isCancelled` check. That should
not cause an indefinitely slow transition by itself, but it is worth tightening
when the main lifecycle issue is fixed.

### Proposed Fix

1. Add a gallery cadence regression test named something like
   `logoBreakerMaintainsSimulationCadence`.
2. While Logo Breaker is active, instrument:
   - simulation tick attempts,
   - state-changing simulation ticks,
   - root invalidation requests,
   - committed frames,
   - presented terminal frames,
   - dropped or coalesced frames, if the runtime exposes that signal.
3. Interpret the result before patching:
   - Low tick count means the game loop or scheduling path is slow.
   - Normal tick count with low committed-frame count means the render pipeline
     is not keeping up with invalidations.
   - Normal committed-frame count with low presented-frame count means the host
     presentation path is losing frames.
4. Add a gallery leave regression test named something like
   `leavingLogoBreakerTabCancelsGameLoop`.
5. Start the app on the Logo Breaker tab or select it through the palette.
6. Render until the Logo Breaker task has started and the ball has moved.
7. Switch to a simple static tab, such as Counter.
8. Assert that the runtime has zero active tasks after the leave frame and a
   short settle render.
9. If the leave test fails, fix the framework lifecycle path first:
   - Confirm the old active lazy payload is absent from the live view graph.
   - Confirm lifecycle/task registrations for the old active subtree are removed.
   - Confirm effect republication does not resurrect task registrations from
     capture-hosted nodes that are no longer live.
   - Confirm `TaskRunner` receives a cancel entry for the old descriptor.
10. Add the app-level defensive guard after sleep:

```swift
try? await Task.sleep(nanoseconds: LogoBreakerGame.tickNanoseconds)
guard !Task.isCancelled else { return }
```

For the leave symptom, the framework regression is the important fix. The
app-level guard only prevents one extra post-cancellation tick. It would not
explain active-tab under-rendering.

## Issue 2: Presentation Lab Overlays Can Become Unclosable

### Relevant Surface

The Presentation Lab tab is registered in:

- `swift-tui-examples/gallery/Sources/GalleryDemoViews/GalleryView.swift`
- `swift-tui-examples/gallery/Sources/GalleryDemoViews/PresentationLabTab.swift`

It exercises these presentation families:

- Alerts.
- Confirmation dialogs.
- Sheets.
- Toasts.
- Boolean popovers.
- Item popovers.
- Tip popovers.
- Command palette sheets.

The framework presentation implementation uses:

- `OverlayStackEntry.modalPolicy`
- `DismissStack`
- `PresentationPortalState`
- builtin coordinators for alert, confirmation, sheet, popover, menu, and toast

Current framework behavior says:

- Alerts, confirmations, sheets, and regular popovers should use
  `.disablesBaseInteraction`.
- Menus and toasts are intentionally non-modal.
- Popover tips are modal only when they have actions; actionless tips are
  intentionally non-modal.
- Escape should dismiss the topmost dismissible overlay.

The observed symptom says some overlay state can get into the worst possible
combination: the overlay remains visible or unclosable while the background is
still interactive.

### Current Coverage Gap

There is existing useful coverage:

- Gallery test coverage verifies a sheet can close and a confirmation dialog can
  still respond after that.
- Framework coverage has a gallery-like presentation tab for sheet and
  confirmation behavior.
- `PresentationLabPopoverTests` verifies the popover showcase renders labels.

That coverage does not exercise the failure matrix:

- Boolean popover close button.
- Item popover Done button.
- Tip popover action.
- Escape dismissal for each modal presentation family.
- Background click suppression while each modal entry is visible.
- Interleaving these overlays inside the real `GalleryView` tab shell.

### Suspicious Detail

`PresentationLabDemoTip` has a "Try tip action" button that sets
`lastPresentationResult`, but the action closure does not explicitly set
`showPopoverDemoTip = false`.

If the framework is intended to auto-dismiss action tips, add a framework test
for that contract and fix the coordinator if needed. If action tips are not
supposed to auto-dismiss, the demo should explicitly clear
`showPopoverDemoTip` in the action.

Either way, the current demo does not make the dismissal contract obvious.

### Proposed Fix

1. Add a gallery integration test that drives every Presentation Lab modal
   family in a single `GalleryView` runtime.
2. For each modal family:
   - Open the overlay.
   - Assert the expected overlay text is visible.
   - Attempt to click a known background control.
   - Assert the background action did not run.
   - Dismiss with the overlay's close/action button or Escape.
   - Assert the overlay is gone and the background control is interactive again.
3. Keep toast/menu expectations separate because they are non-modal by design.
4. Add a smaller framework test for the failing primitive once the gallery test
   identifies the presentation family that breaks.
5. Patch the relevant presentation coordinator or overlay-stack composition:
   - Modal entries must appear in the overlay stack with
     `.disablesBaseInteraction`.
   - Modal entries must participate in the dismiss stack when they accept Escape.
   - Closing an overlay must invalidate the source binding and request a root
     frame.
   - Base hit testing must be disabled before local background handlers see the
     event.
6. Make the tip-popover action dismissal contract explicit in either the
   framework or the demo.

## Issue 3: Focus Context Tab Crash And Tab No-op

### Relevant Surface

The Focus Context tab is registered in:

- `swift-tui-examples/gallery/Sources/GalleryDemoViews/GalleryView.swift`
- `swift-tui-examples/gallery/Sources/GalleryDemoViews/FocusContextTab.swift`

The tab defines:

- A custom `FocusedValueKey`.
- Two `TextField`s that publish
  `.focusedValue(\.galleryFocusedTitle, $firstTitle)` and
  `.focusedValue(\.galleryFocusedTitle, $secondTitle)`.
- An `@FocusedBinding(\.galleryFocusedTitle)` that a button and toolbar command
  mutate.

There is no explicit initial focus target in the tab. If pressing Tab from a
newly selected tab appears to do nothing, that may be a focus traversal/default
focus problem rather than a focused-binding problem by itself.

The crash after repeated Tab presses points at a framework bug in one of these
areas:

- Focus traversal when no field is initially focused.
- Focus registry restoration after a lazy tab body is entered.
- Focused value binding lookup while focus changes.
- Local focused values being removed or normalized while an edit interaction is
  active.

### Current Coverage Gap

Framework tests prove that `@FocusedBinding` can read and write a focused scene
value in a synthetic window. That is necessary but not enough.

Missing coverage:

- Selecting the real Focus Context tab from the gallery shell.
- Pressing Tab and Shift-Tab repeatedly through the live runtime.
- Verifying focus lands on both fields.
- Verifying the `@FocusedBinding` button and toolbar mutate only the focused
  field.
- Verifying focus traversal and focused values survive tab leave/re-enter.

### Proposed Fix

1. Add a gallery integration test that starts on Focus Context or selects it by
   palette.
2. Send repeated Tab key events and assert no crash.
3. Assert that focus visibly lands on each field and the status text reflects
   the focused title.
4. Click "Uppercase focused title" after each focus move and assert only the
   focused field changes.
5. Leave and re-enter the tab, then repeat a smaller Tab traversal.
6. Reduce the failing case into a `swift-tui` framework test with:
   - `TabView`.
   - Two `TextField`s.
   - A custom focused binding.
   - Repeated Tab and Shift-Tab key events.
7. Patch the focus subsystem where the smaller test fails:
   - If Tab from no focus is ignored, define a default focus traversal entry for
     active focus scopes.
   - If focused values are stale after tab entry, fix registration restoration
     for lazy active bodies.
   - If repeated traversal crashes, guard focused binding lookup against removed
     identities and add a focused-registry consistency assertion.

## Issue 4: Gallery Coverage Is Not Sufficient

### Current Pattern

The repo already has the right philosophy in several places:

- Gallery integration tests protect full app behavior.
- Framework tests protect small primitives.
- Earlier reports describe that complex gallery issues should be reduced into
  framework-level checks once the failing primitive is understood.

The gap is that some high-risk gallery seams still lack a red-test path:

- Active lazy tab leaving cancels autonomous tasks.
- Presentation Lab exercises every modal family under the real shell.
- Focus Context exercises live focus traversal and focused values under the real
  shell.
- Gifeditor has measurement for drawing-path performance.

### Proposed Coverage Policy

For each gallery incident:

1. Reproduce in `swift-tui-examples/gallery` against the real `GalleryView`.
2. Add the smallest possible app-level test that fails for the user-visible
   symptom.
3. Reduce the failure into a `swift-tui` framework test when the primitive is
   framework-owned.
4. Fix the framework against the reduced test.
5. Keep the gallery test as the integration guard if the failure depends on the
   real shell, capture host, palette, portal, or tab composition.

This prevents two bad outcomes:

- Gallery regressions that only appear in the composed app.
- Framework fixes that are only protected by a large example test and become
  hard to diagnose later.

## Issue 5: Gifeditor Drawing Performance

### Current Evidence

The dedicated report at
`docs/reports/2026-06-24-gifeditor-perf-deepdive.md` identifies the immediate
performance problem:

- The editor recomposes the full document too often.
- Timeline rendering maps all frames and calls thumbnail/flatten logic every
  render.
- Current-frame rendering repeatedly flattens the layer stack.
- `CanvasSurfaceView.resolvedPixels` can be read more than once for the same
  render path.

### Proposed Fix

Implement the June 24 report's plan:

1. Add an `EditorViewModel` render cache.
2. Cache frame composites and thumbnails by content signature, not by frame id or
   array index alone.
3. Invalidate cache entries only when the frame's layer/image content changes.
4. Gate timeline thumbnail recomputation so pointer movement or unrelated UI
   state does not recomposite every frame.
5. Hoist current-frame resolved pixels so the same render path computes them
   once.
6. Present the save sheet immediately and compute preview/export data
   asynchronously.
7. Add a regression workload that draws repeatedly on a multi-frame,
   multi-layer document and fails if the render path returns to whole-document
   recomposition.

The gifeditor problem is app-owned first. If the cache exposes expensive
framework invalidation behavior, add a smaller framework performance regression
after the example-level workload is measurable.

## Proposed Work Plan

### Phase 0: Reproduce And Instrument

Add focused failing tests or debug counters before changing behavior:

- Gallery Logo Breaker active-cadence and leave-teardown tests.
- Gallery Presentation Lab modal matrix test.
- Gallery Focus Context repeated Tab traversal test.
- Gifeditor drawing workload with recomposition counters.

For the Logo tests, inspect simulation ticks, invalidations, committed frames,
presented frames, and runtime active task counts before and after leaving the
tab. For the presentation test, inspect both overlay visibility and whether
background controls can still handle events. For the focus test, inspect focused
field identity and focused value binding after each key event.

### Phase 1: Framework Fixes

Patch `swift-tui` only after the red tests identify the primitive:

- Lifecycle/task teardown for active lazy `TabView` body removal.
- Presentation overlay stack and dismiss-stack consistency.
- Focus traversal and focused-value registry consistency.

Each framework fix should land with a reduced `swift-tui` test plus the original
gallery regression.

### Phase 2: Example Fixes

Patch app-owned details:

- Add the post-sleep cancellation guard in Logo Breaker.
- Make Presentation Lab tip-popover dismissal explicit if framework semantics do
  not auto-dismiss action tips.
- Add any missing default focus or user-facing affordance in Focus Context only
  after the framework focus behavior is correct.
- Implement gifeditor render caching.

### Phase 3: Validation

Run focused suites first:

```bash
swiftly run swift test --package-path swift-tui-examples/gallery --filter TaskProgressTabTeardownTests
swiftly run swift test --package-path swift-tui-examples/gallery --filter PresentationLabPopoverTests
swiftly run swift test --package-path swift-tui --filter TabViewLifecycleTests
```

Then run the new tests directly, the relevant package gates, and finally the
root coordination gate before bumping pins:

```bash
bazel test //:org_fast
```

If child repos are modified, commit and push the child repo first, then update
the root submodule pin in this orchestration repo.

## Verification Performed For This Report

The following focused checks were run while preparing this report:

```bash
swiftly run swift test --package-path swift-tui-examples/gallery --filter TaskProgressTabTeardownTests
swiftly run swift test --package-path swift-tui-examples/gallery --filter PresentationLabPopoverTests
swiftly run swift test --package-path swift-tui --filter TabViewLifecycleTests
swiftly run swift test --package-path swift-tui --filter TabViewLifecycleTests/inactiveTabsDoNotScheduleTasks
```

Results:

- `TaskProgressTabTeardownTests` passed.
- `PresentationLabPopoverTests` passed.
- Both `TabViewLifecycleTests` invocations built, started the Swift Testing
  process, then `swiftpm-testing-helper` exited with signal 11 before producing a
  test assertion result.

That signal 11 should be treated as a separate test-runner or framework crash to
investigate before relying on the `TabViewLifecycleTests` suite as green
evidence.

No manual interactive reproduction was performed for this report.

## Non-goals

Do not fix these issues by weakening important framework contracts:

- Do not make `TabView` eagerly resolve inactive tabs to paper over lifecycle
  teardown. Lazy inactive bodies are a public behavior constraint already covered
  by tests.
- Do not make all popovers non-modal. Action popovers and modal presentation
  surfaces must continue to disable base interaction.
- Do not leave framework-owned failures protected only by gallery tests.
- Do not key gifeditor render caches only by frame id or index; reordering and
  content mutation would make that stale.

## Recommended First Patch

The highest-leverage first patch is a test-only patch:

1. Add `logoBreakerMaintainsSimulationCadence`.
2. Add `leavingLogoBreakerTabCancelsGameLoop`.
3. Add the Presentation Lab modal matrix test.
4. Add the Focus Context repeated Tab traversal test.

That patch should be allowed to fail locally if it captures the TODO symptoms.
Once those tests fail, the actual framework patches can be narrow and evidence
driven.
