# SwiftTUI Gallery Coverage Deep Dive

Date: 2026-06-29

## Scope

This report follows the root `TODO.md` finding that `swift-tui` coverage does
not sufficiently represent complex Gallery issues. It focuses on what should be
tested in the framework package before changing runtime behavior.

The pass used four parallel read-only investigations:

- Logo Breaker active cadence and tab-leave lifecycle.
- Presentation Lab modal dismissal and base-interaction routing.
- Focus Context Tab traversal, `TextField`, and `@FocusedBinding`.
- Adjacent Gallery behaviors that should be mirrored into `swift-tui` tests.

## Thesis

The highest-leverage next patch should be test-only in `swift-tui`.

The Gallery TODO failures are not best represented by copying Gallery into the
framework tests. They are best represented by small runtime fixtures that encode
the primitive invariants Gallery is stressing:

- Active-only lazy tab content must cancel tasks when it leaves.
- Task-driven state changes must commit and present frames while the tab remains
  active.
- Modal overlays must remove base pointer routes, not just base focus.
- `TabView` focus traversal, `TextField`, focused values, and
  `@FocusedBinding` must work together in one live runtime path.

After those framework tests exist, Gallery should keep one real-path smoke per
feature to verify tab descriptors, command aliases, executable wiring, and the
actual demo composition.

## First Patch

Add these failing or characterization tests first:

1. `swift-tui/Tests/SwiftTUITests/TabAutonomousTaskRuntimeTests.swift`
   - `logoLikeTaskTicksCommitAndPresentOneFramePerDrivenStateChange`
   - `leavingLogoLikeTabCancelsAutonomousGeometryTask`
2. `swift-tui/Tests/SwiftTUITests/PresentationModalRoutingTests.swift`
   - `modalPresentationsRemoveBasePointerRoutes`
   - `modalPresentationsIgnoreBaseClicksUntilDismissed`
   - `escapeDismissesRuntimePopoverPaletteAndTip`
   - `nonModalPresentationsKeepBaseRouting`
3. `swift-tui/Tests/SwiftTUITests/FocusContextRuntimeTests.swift`
   - `focusContextTabTraversalPublishesFocusedBinding`
   - `repeatedTabCyclesAcrossFocusContextRemainConverged`
   - `focusedBindingActionMutatesCurrentlyFocusedTextFieldBinding`
4. `swift-tui/Tests/SwiftTUITests/TextInputRuntimeIntegrationTests.swift`
   - `textFieldTabMovesFocusInsteadOfInsertingTab`
5. `swift-tui/Tests/SwiftTUITests/TabViewLifecycleTests.swift`
   - `switchingAwayFromActiveOnlyTabSchedulesTaskCancel`

The tests above are more valuable than a broad Gallery test because they should
fail at the framework seam that needs repair.

## Logo Breaker Coverage

### Existing Coverage

Relevant app/example coverage:

- `swift-tui-examples/gallery/Sources/GalleryDemoViews/LogoTab.swift`
  contains the real 25 Hz geometry-driven `.task(id:)` loop.
- `swift-tui-examples/gallery/Tests/GalleryDemoViewsTests/FullScreenTabGestureTests.swift`
  covers Logo Breaker physics, collision, drag, and runtime gravity scheduling.
- `swift-tui-examples/gallery/Tests/GalleryDemoViewsTests/GalleryTabSwitchTests.swift`
  covers selecting Logo Breaker and starting the gravity loop.
- `swift-tui-examples/gallery/Tests/GalleryDemoViewsTests/TaskProgressTabTeardownTests.swift`
  proves a different autonomous task tab returns `activeTaskCount` to zero after
  leaving.

Relevant framework coverage:

- `TabViewLifecycleTests` verifies inactive tabs do not schedule tasks.
- `TabTaskActivationRuntimeTests` verifies selection-driven activation starts a
  lazy tab task.
- `AsyncFrameTailRenderingTests` covers stale-frame cancellation/drop
  diagnostics.

Coverage gap:

- No `swift-tui` test switches away from an already-active autonomous tab whose
  content is behind `TabView`, `GeometryReader`, and `.task(id:)`.
- No test distinguishes "the task ticked" from "a committed frame was
  presented."

### New Tests

#### `switchingAwayFromActiveOnlyTabSchedulesTaskCancel`

Target: `swift-tui/Tests/SwiftTUITests/TabViewLifecycleTests.swift`

Fixture:

- Persistent `DefaultRenderer`.
- `TabView(selection:)` with two tabs.
- First tab uses `GeometryReader` and a `.task(id: BoundsID(size: proxy.size))`.
- Second tab is static text.

Assertions:

- First render produces one `taskStart` for the active tab.
- Switching selection to the static tab produces a `taskCancel` for the first
  tab descriptor.
- The switch render does not produce a new first-tab `taskStart`.

Why this matters:

- It proves the lifecycle diff sees active-only tab body removal. If this fails,
  Logo-like tasks can survive tab leave.

#### `leavingLogoLikeTabCancelsAutonomousGeometryTask`

Target: new `swift-tui/Tests/SwiftTUITests/TabAutonomousTaskRuntimeTests.swift`

Fixture:

- Real `RunLoop` with `Panel`, `.literalTabs`, and `TabView(selection:)`.
- Active tab uses `GeometryReader`.
- The tab owns an async task driven by a test gate rather than `Task.sleep`.
- A `TaskLifecycleProbe` records `startCount`, `cancelCount`, `tickAttempts`,
  `changedTicks`, and `postCancelTicks`.

Assertions:

- After the active tab starts, `lifecycleCoordinator.activeTaskCount > 0`.
- After switching to a static tab and draining frames,
  `lifecycleCoordinator.activeTaskCount == 0`.
- `cancelCount == startCount`.
- Releasing another tick after leave does not change visible text and does not
  schedule another frame.

Why this matters:

- It directly represents the slow-leave symptom without importing Gallery.

#### `logoLikeTaskTicksCommitAndPresentOneFramePerDrivenStateChange`

Target: `TabAutonomousTaskRuntimeTests.swift`

Fixture:

- Same Logo-like active tab.
- Controlled tick gate releases one state-changing tick at a time.
- `RecordingPresentationSurface` records presented surfaces.
- An in-memory diagnostic sink records committed frame samples.

Assertions:

- For `N` released ticks, presented surfaces contain `tick 1` through `tick N`.
- Each driven state change produces a committed frame with invalidation
  diagnostics.
- The test avoids asserting wall-clock 25 Hz timing.

Why this matters:

- The new user observation says Logo Breaker appears to render fewer simulation
  frames while active. This test distinguishes slow simulation ticks from lost
  commit/presentation frames.

#### `switchingAwayFromAutonomousTabDoesNotRearmSkippedFrameCascade`

Target: `TabAutonomousTaskRuntimeTests.swift` or `AsyncFrameTailRenderingTests`.

Fixture:

- Async render mode.
- Block a Logo-like frame tail while the autonomous tab is active.
- Switch to the static tab while the old frame is pending.

Assertions:

- The next committed/presented frame is the static tab.
- Diagnostics may record one cancelled or skipped stale frame.
- Diagnostics must not show a repeated `cancel_pending_before_start` or
  `drop_completed_visual_only` cascade after the static tab commits.
- `activeTaskCount == 0`.

Why this matters:

- It catches the "leaving this tab takes forever" failure class when it is caused
  by stale async tail churn rather than only task cancellation.

#### `tabSwitchFrameWithTaskCancelIsNotDroppedAsVisualOnly`

Target: `TabAutonomousTaskRuntimeTests.swift`.

Fixture:

- Active autonomous tab, switch to static tab under async tail pressure.
- Diagnostic sink captures drop decisions and lifecycle blockers.

Assertions:

- The tab-switch frame includes lifecycle impact for `taskCancel`.
- The switch frame is committed, not dropped as visual-only.

Why this matters:

- A task cancellation is semantically observable. A frame carrying that
  cancellation must not be treated as disposable visual churn.

### Hooks Needed

Use existing hooks where possible:

- `RecordingPresentationSurface` and `MainActorConditionSignal` from
  `SwiftTUITestSupport`.
- `RunLoop.lifecycleCoordinator.activeTaskCount`.
- `FrameDiagnosticSink` with an in-memory test double.

Add test-only helpers:

- `TaskLifecycleProbe`.
- A manual async tick gate.
- A small helper to count committed frame samples and presented surfaces.

Avoid:

- Importing Gallery into `swift-tui`.
- Asserting real 25 Hz timing.
- Using `Task.sleep` as the test oracle.
- Making inactive `TabView` bodies eager.

## Presentation Lab Coverage

### Existing Coverage

Relevant framework coverage:

- `AppRuntimeTests.galleryLikePresentationTabSheetAndConfirmationActionsStayClickable`
  drives sheet and confirmation actions in a gallery-like tab.
- `PresentationActionScopeTests` covers modal focus trap/restoration.
- `PopoverPresentationTests` covers popover focus gating and distinguishes
  read-only tips from action tips.
- `PresentationSurfaceTests` covers alert base-focus suppression and dropdown
  chrome.
- `InteractionGateTests` proves disabled gates remove focus and interaction
  routes.

Coverage gap:

- Current tests mostly prove focus gating and overlay rendering. They do not
  prove that modal overlays remove base pointer routes and prevent base actions
  from firing while an overlay is visible.

### New Tests

Target: new `swift-tui/Tests/SwiftTUITests/PresentationModalRoutingTests.swift`

#### `modalPresentationsRemoveBasePointerRoutes`

Fixture:

- Enum-backed `PresentationRoutingFixture(kind:)`.
- Base view has `Button("Base Action").id(baseID)`.
- The selected presentation starts open or is opened by a trigger.
- Kinds: sheet, alert, confirmation dialog, palette sheet, boolean popover,
  item popover, action popover tip.

Assertions:

- While the modal is open, `latestSemanticSnapshot.focusRegions` does not
  contain `baseID`.
- While the modal is open, `latestSemanticSnapshot.interactionRegions` does not
  contain `baseID`.
- The overlay's action/close region exists.

Why this matters:

- The TODO symptom is "overlay unclosable while background remains
  interactive." Focus-only coverage does not catch that.

#### `modalPresentationsIgnoreBaseClicksUntilDismissed`

Fixture:

- Same fixture, but run through a real `RunLoop`.
- Record the base button point while closed.
- Open overlay.
- Click the previously recorded base point.

Assertions:

- Base count remains `0`.
- Overlay remains visible after the base click.
- Clicking overlay `Close`, `OK`, `Reset`, `Done`, or `Got it` dismisses.
- After dismissal, the base button increments normally.

Why this matters:

- It proves runtime pointer dispatch respects modal gating, not just semantic
  snapshots.

#### `escapeDismissesRuntimePopoverPaletteAndTip`

Fixture:

- Boolean popover, item popover, action popover tip, and palette sheet.

Assertions:

- Open overlay.
- Press Escape.
- Overlay disappears.
- A subsequent base click works.

Why this matters:

- Coordinator-level dismiss-stack tests do not prove these presentation families
  are wired through the runtime event path.

#### `nonModalPresentationsKeepBaseRouting`

Fixture:

- Read-only popover tip.
- `Menu`.

Assertions:

- Base interaction regions remain visible.
- Base click increments while non-modal presentation is visible.

Why this matters:

- It prevents the fix from overcorrecting by making intentionally non-modal
  surfaces modal.

### Fixture Notes

Do not copy Presentation Lab. Use a tiny enum fixture:

- Boolean popover: `@State var showPopover`, popover body with `Button("Close")`.
- Item popover: local `RoutingTool: Identifiable`, body with `Button("Done")`.
- Action tip: local `RoutingTip: PopoverTip` with one `PopoverTipAction`.
- Palette sheet: `Panel(id:)` plus `.paletteCommand` and `.paletteSheet`.
- Sheet, alert, confirmation: one trigger and one dismiss/action control.

Use local helpers:

- `render()`
- `clickText(_:)`
- `click(_:)`
- `assertNoBaseInteraction(baseID:)`
- `assertBaseInteractionPresent(baseID:)`

## Focus Context Coverage

### Existing Coverage

Relevant framework coverage:

- `FocusTransitionTests` covers `TabView` to `Picker` Tab/Shift-Tab traversal.
- `AppRuntimeTests.focusedValueTracksFocusedControl` covers live
  `@FocusedValue` traversal.
- `AppRuntimeTests.focusedBindingTracksFocusedSceneValue` covers
  `@FocusedBinding` in a static two-pass render.
- `TextInputRuntimeIntegrationTests` covers `TextField` editing and paste.
- `DiagnosticsAndCacheTests` covers focused-value publisher reuse/merge.
- `InputParserModifierTests` covers Tab and Shift-Tab parsing.

Coverage gap:

- No test combines `TabView`, two `TextField`s, focused value publishers,
  `@FocusedBinding`, and live Tab traversal.
- No test stress-cycles that combined path enough to catch the reported crash.

### New Tests

Target: new `swift-tui/Tests/SwiftTUITests/FocusContextRuntimeTests.swift`

#### `focusContextTabTraversalPublishesFocusedBinding`

Fixture:

- Local `FocusedValueKey` whose value is `Binding<String>`.
- `TabView(selection:)` with an active "Focus Context" tab.
- `.literalTabs`.
- A small `Panel(id:)` wrapper to keep the Gallery-like composition seam.
- Two `TextField`s with explicit identities.
- Each `TextField` publishes `.focusedValue`.
- A status `Text` reads `@FocusedBinding`.

Assertions:

- Initial focus is on the tab strip.
- After bounded Tab presses, focus reaches the first text field and the status
  shows that field's value.
- Next Tab reaches the second text field and the status shows the second value.
- Shift-Tab returns to the first field.

Why this matters:

- It covers the exact cross-product the Gallery Focus Context tab uses.

#### `repeatedTabCyclesAcrossFocusContextRemainConverged`

Fixture:

- Same as above.

Assertions:

- Run 30-50 direct Tab/Shift-Tab steps.
- Drain frames after each step.
- Focus identity is always one of the known fixture regions.
- Rendering never throws.
- When focus is either text field, the status text matches that field's binding.

Why this matters:

- It targets the reported "crash after time/repeats" without relying on
  wall-clock timing.

#### `focusedBindingActionMutatesCurrentlyFocusedTextFieldBinding`

Fixture:

- Same as above.
- Add `Button("Mark focused reviewed")` or a key command that mutates
  `$focusedTitle`.

Assertions:

- Focus first field, dispatch action, render.
- First title mutates and second title does not.
- Focus second field, dispatch action, render.
- Second title mutates and first title does not.

Why this matters:

- It proves `@FocusedBinding.projectedValue` remains a live binding across
  action dispatch.

#### `textFieldTabMovesFocusInsteadOfInsertingTab`

Target: `TextInputRuntimeIntegrationTests`.

Fixture:

- Two `TextField`s with explicit identities and mutable boxes.
- Real `RunLoop`.
- Set focus to the first field.

Assertions:

- `handleKeyPress(KeyPress(.tab))` moves focus to the second field.
- The first box does not contain `\t`.
- Shift-Tab returns focus to the first field.

Why this matters:

- It pins the TextField contract that Tab falls through to runtime focus
  traversal.

### Determinism

Use direct synchronous dispatch:

```swift
_ = runLoop.handleKeyPress(KeyPress(.tab))
try runLoop.renderPendingFrames(renderedFrames: &renderedFrames)
```

Avoid:

- PTY tests.
- `runLoop.run()` for the core focus tests.
- Sleeps or timeout polling.

Keep one Gallery smoke test for the actual Focus Context tab after the
framework tests exist.

## Additional Gallery Behaviors To Push Down

These are not the first patch, but they are good follow-up framework coverage.

### 1. Capture-host scoped publication keeps action handlers alive

Existing evidence:

- `swift-tui-examples/gallery/Tests/GalleryDemoViewsTests/CounterShellClickRegressionTests.swift`

Target:

- Adjacent to `TabTaskActivationRuntimeTests`.
- Runtime registration restore/scoping tests.

Invariant:

- After a mapped/scoped invalidation behind `Panel`, toolbar, and lazy tab
  composition, button pointer/action registrations remain live across repeated
  clicks.

### 2. Active tab selection survives child collection mutation

Existing evidence:

- `GalleryTabSwitchTests` tab-selection state tests.

Target:

- `TabViewLifecycleTests`, `StatePersistenceTests`, or new
  `TabViewRuntimeSelectionTests`.

Invariant:

- Mutating/removing rows inside selected tab content must not reset parent
  `TabView` selection or resurrect the default tab on later frames.

### 3. Async overlay open/dismiss publishes conservative raster damage

Existing evidence:

- Gallery overlay continuity checks.

Target:

- `SurfaceDamageContractTests`
- `AsyncFrameTailRenderingTests`

Invariant:

- Detached overlay presentation changes produce nil/broad-enough damage or exact
  damage relative to the last actually presented surface.

### 4. Command palette focus and local selection

Existing evidence:

- Gallery command palette runtime checks.

Target:

- `GalleryStyleDispatchTests`
- `FocusTransitionTests`
- Palette runtime tests

Invariant:

- Opening a palette seeds focus to the filter.
- Arrow/Tab navigation mutates local selection without losing global focus.
- Return/click dispatches the selected command.

### 5. Animation intent survives input-frame cancellation/replay

Existing evidence:

- `AnimationRegressionTests`

Target:

- `AnimationCompletionConcurrencyTests`
- `AsyncFrameTailRenderingTests`
- `TimingDiagnosticsTests`

Invariant:

- A click-driven state change carrying animation intent commits the final
  animated placement even if prior tail work is cancelled.
- Diagnostics preserve cancellation reason and animation request.

### 6. Terminal drag release preserves velocity across encodings

Existing evidence:

- Gallery real terminal drag release tests.

Target:

- `DragGestureTests`
- `PointerEventTimestampTests`
- `GestureRunLoopDispatchTests`

Invariant:

- SGR down/drag/up parsed in terminal cell or pixel mode yields nonzero release
  velocity and schedules post-release frames.

### 7. Visible lifecycle/repeat animations keep presenting frames

Existing evidence:

- `BordersAndShapesTabTests`

Target:

- `AnimationTickVisibilityTests`
- A runtime autonomous wake test

Invariant:

- A visible repeat animation started from view lifecycle produces subsequent
  terminal presents without extra input.

### 8. Fullscreen toolbar/overlay chrome persists during animation

Existing evidence:

- `FullScreenTabGestureTests`

Target:

- `ToolbarTests`
- `OverlayStackTests`
- `AsyncFrameTailRenderingTests`

Invariant:

- Every animated frame from a fullscreen content root still includes toolbar
  overlay cells and active toolbar semantics.

### 9. Literal-tab overflow remains stable during animated frames

Existing evidence:

- `GalleryTabSwitchTests.expandedOverflowMenuStaysVisibleAcrossAnimatedGalleryFrames`

Target:

- `TabViewSurfaceTests`
- `FrameDropEligibilityTests`

Invariant:

- Once expanded, overflow menu content remains present on every following visual
  frame until dismissed.
- Visual-only frame dropping must not drop required overlay/menu state.

## What Should Remain Gallery-only

Keep these in Gallery/example tests rather than pushing them into `swift-tui`:

- Tab roster/order and `--tab` aliases.
- Command labels and demo copy.
- Demo assets and visual artwork.
- Logo Breaker game math and collision/art details.
- Life rules.
- Calculator semantics.
- Task Progress tab formatting.
- Border style choices specific to the showcase.
- Gallery executable/WebHost composition.
- Real end-to-end PTY smoke after a smaller framework primitive test exists.

## Implementation Order

1. Add Focus Context runtime tests first.
   - They are deterministic, narrow, and likely to expose the repeated-Tab crash.
2. Add Presentation modal routing tests.
   - The interaction-region gap directly matches the background-interactive
     overlay symptom.
3. Add Logo-like autonomous task lifecycle/cadence tests.
   - They need slightly more harness work but are the right guard for both
     active under-rendering and slow leave.
4. Add the adjacent push-down tests opportunistically when touching those
   subsystems.

## Verification Status

This was a read-only planning pass. No tests were added or run for this report.

The previous TODO deep dive already recorded one current caveat:

- `swiftly run swift test --package-path swift-tui --filter TabViewLifecycleTests`
  exited via `swiftpm-testing-helper` signal 11 before producing a test assertion
  result.

Investigate that before treating `TabViewLifecycleTests` as a reliable green
signal.

## Implementation & Re-evaluation Update (2026-06-29, later same day)

The "First Patch" tests were committed (swift-tui `ede676de`, org pin
`ffb4888`) and then evaluated for whether they actually enable a TDD drilldown.
They did **not**, and they were reworked. Findings and the resulting state:

### The signal-11 caveat is a deterministic snapshot-render crash, not just a flake

The TODO deep dive's `TabViewLifecycleTests` signal 11 was run down. It is a
**deterministic** `SIGSEGV` (`swift_release` during `outlined destroy of
RenderSnapshot` inside `DefaultRenderer.render`) on the **synchronous snapshot
`DefaultRenderer().render()` path for TabView / presentation trees** — not the
non-deterministic load flake. Evidence:

- `TabViewLifecycleTests/firstTimeActivationFiresOnAppear` (pre-existing) crashes
  3/3 in isolation at the current pin, but passes 3/3 at `573fc2af` and
  `e552ad98`. The only delta between those and the current pin is **test-only**
  commits — i.e. the corruption is latent in the framework and the added test
  code tips the binary layout into manifesting it (the `SwiftTUI/swift-tui#12`
  family). The full `SwiftTUITests` bundle is red on macOS as a result; the
  Linux repo gate (a different platform for this main-thread corruption) is
  unaffected, which is how the pin was bumped.
- `PresentationActionScopeTests` and the committed
  `PresentationRouteSuppressionTests` snapshot cases crash the same way.
- The **synchronous run-loop path is stable** for these exact view shapes
  (`FocusContextRuntimeTests`, `AppRuntimeTests.galleryLikePresentationTab…`).

Consequence: a crashing test yields no assertion and takes its siblings down —
the opposite of a drilldown. Snapshot-based gallery tests are the wrong vehicle.

### Why the committed tests did not drill down, and what replaced them

- **Logo Breaker / bug #1** had no test at all (the report's
  `TabAutonomousTaskRuntimeTests` was not added). Replaced with a new
  `Tests/SwiftTUITests/TabAutonomousTaskRuntimeTests.swift` that drives a real
  `RunLoop` and asserts `lifecycleCoordinator.activeTaskCount` returns to zero
  when the active geometry-backed tab leaves (the observable runtime symptom).
- **Presentation routing / bug #2**: the committed snapshot tests asserted the
  static `interactionRegions` set, which proves route gating but not that
  runtime pointer dispatch refuses the click (the actual "background remains
  interactive" symptom) — and they crashed. `PresentationRouteSuppressionTests`
  was rewritten onto the run-loop path: it records the base control's point,
  opens each modal family (sheet / confirmation / boolean popover), clicks the
  recorded base point and asserts the base action does **not** fire, then
  dismisses (control + Escape) and asserts the base is live again.
- **`TabViewLifecycleTests.switchingAwayFromActiveOnlyTabSchedulesTaskCancel`**
  used a two-shot `DefaultRenderer().render()` and asserted a `.taskCancel`
  *plan entry*. The snapshot renderer never starts or cancels real tasks, so it
  cannot observe the symptom; removed in favour of the runtime test above.
- **Focus Context / bug #3**: `focusContextTabTraversalReachesFirstEditableField`
  is kept ENABLED and is a genuine **red** — one Tab lands focus on the
  `TabContentPayload` container, not the first field. The
  `focusedBindingActionMutates…` test is a faithful repro of the reported "crash
  after repeats": dispatching the `@FocusedBinding` mutation while a
  `focusedValue` field is focused traps at `RunLoop+Rendering.swift:125` ("Focus
  synchronization did not converge after 13 rerenders", a `fatalError`). It is
  held `.disabled` with that precise reason because a `fatalError` aborts the
  whole test process rather than recording a catchable issue.

### Honest limitation: only bug #3 reds at the framework level

The minimal run-loop fixtures for bugs #1 and #2 pass (the framework primitives
are sound in isolation) — the failures are seam-specific to the gallery's
capture-host / portal / overflow composition, exactly as Phase 0 anticipated. So
the genuine red oracles for #1/#2 are gallery **integration** tests in
`swift-tui-examples` (added separately), with these run-loop tests as fast
guards. The latent `#12` snapshot corruption is now deterministically
reproducible at this pin and is left for a dedicated investigation.
