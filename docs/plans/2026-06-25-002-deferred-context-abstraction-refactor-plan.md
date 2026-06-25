# Deferred context abstraction split - technical implementation plan

- **Date:** 2026-06-25
- **Status:** Proposed implementation plan
- **Input proposal:** [../proposals/2026-06-25-001-deferred-context-abstraction-refactor.md](../proposals/2026-06-25-001-deferred-context-abstraction-refactor.md)
- **Scope:** `swift-tui` internals: `SwiftTUIViews`, `SwiftTUICore`, and
  `SwiftTUIRuntime`.

## 1. Purpose

This plan turns the deferred-context proposal into staged implementation work.
The goal is to split one overloaded implementation family into four explicit
runtime contracts:

| Contract | Primary owner | First consumers |
| --- | --- | --- |
| `CapturedSubviewScope` / `CapturedSubviewPayload` | `SwiftTUIViews/Foundation` and `State` | style labels, stored modifier children, `ScrollView`, `AnyView`, `ModifiedContent` |
| `LazySubviewPayload` | `SwiftTUIViews/Foundation` | `TabView`, `NavigationStack` |
| `PortalAttachmentPayload` | `SwiftTUIViews/Presentation` | sheet, alert, confirmation dialog, palette sheet, popover, toast, menu |
| `LayoutRealizedContentBoundary` | `SwiftTUICore/Resolve` | `GeometryReader` |

The first implementation passes should be behavior-preserving. Semantic changes,
if any, must be deliberate follow-ups with separate tests and reports.

## 2. Hard constraints

- Do not change public SwiftUI-shaped APIs.
- Do not make inactive `TabView` children eager.
- Do not replace detached presentations with app-authored conditional `ZStack`
  content.
- Do not remove reader-attributed presentation trigger leaves.
- Do not change `GeometryReader` sizing or realization semantics.
- Do not make example-app tests the only acceptance coverage. Package-owned
  `swift-tui` tests are required.
- Keep old type names behind aliases or compatibility wrappers until all call
  sites and public/SPI baselines are checked.

## 3. Current code surfaces

### Authoring and scoped storage

- `swift-tui/Sources/SwiftTUIViews/State/AuthoringContext.swift`
  - `DeferredAuthoringContextSnapshot`
  - `makeDeferredAuthoringContext(from:)`
  - `withAuthoringContext(_:_:)`
- `swift-tui/Sources/SwiftTUIViews/Foundation/ViewModifier.swift`
  - `ModifiedContent.authoringContext`
  - `ModifierContentInputs`
- `swift-tui/Sources/SwiftTUIViews/Foundation/AnyView.swift`
  - scoped erased storage.

### Generic payloads

- `swift-tui/Sources/SwiftTUIViews/Foundation/ViewCompositionHelpers.swift`
  - `DeferredViewPayload`
  - `DeferredPayloadView`
  - `DeferredPayloadGroupView`
- `swift-tui/Sources/SwiftTUIViews/Foundation/ViewFoundation.swift`
  - `appendDeferredDeclaredBuilderChildren`
  - `deferredDeclaredBuilderChildren`
- `swift-tui/Sources/SwiftTUIViews/Foundation/ViewProtocols.swift`
  - `DeclaredChildrenView.appendDeferredDeclaredChildren`.

### Portal payloads

- `swift-tui/Sources/SwiftTUIViews/Presentation/Portal.swift`
  - `PortalContentPayload`
  - `PortalPayloadView`
  - `PortalPayloadGroupView`
  - `portalDeclaredBuilderChildren`
- `swift-tui/Sources/SwiftTUIViews/Presentation/PresentationItems.swift`
  - presentation item payload arrays.
- `swift-tui/Sources/SwiftTUIViews/Presentation/OverlayStack.swift`
  - detached overlay entry payload resolution.
- `swift-tui/Sources/SwiftTUIViews/Presentation/PresentationCoordinator.swift`
  - portal root composition and coordinator declarations.

### Active-only surfaces

- `swift-tui/Sources/SwiftTUIViews/TabViews/TabView.swift`
  - declared metadata peeking and selected body payload transport.
- `swift-tui/Sources/SwiftTUIViews/TabViews/TabViewStyles.swift`
  - active tab content configuration.
- `swift-tui/Sources/SwiftTUIViews/NavigationViews/NavigationStack.swift`
  - active destination chain resolution.
- `swift-tui/Sources/SwiftTUIViews/NavigationViews/NavigationDestinationPreferences.swift`
  - destination instance payload storage.

### Layout-realized content

- `swift-tui/Sources/SwiftTUICore/Resolve/LayoutDependentContent.swift`
  - layout-time boundary and realization context.
- `swift-tui/Sources/SwiftTUICore/Measure/*`
  - special measurement for layout-dependent content.
- `swift-tui/Sources/SwiftTUICore/Place/*`
  - realization during placement.
- `swift-tui/Sources/SwiftTUIViews/GeometryReading/GeometryReader.swift`
  - only production layout-dependent realizer.

## 4. Stage 0 - inventory and characterization tests

Stage 0 creates a locked baseline before renames or behavior moves.

### 0.1 Add a call-site inventory script or report

Create a short checked-in report under `docs/reports/` or a test fixture note
that classifies every current use of:

- `makeDeferredAuthoringContext`;
- `DeferredViewPayload`;
- `PortalContentPayload`;
- `LayoutDependentContentBoundary`.

The report should use the four target buckets:

- captured inline child;
- lazy active-only child;
- portal attachment;
- layout-realized content.

Do not rely on prose memory. Generate the inventory from `rg` output and then
classify it.

### 0.2 Add state-owner regression coverage

Owner suites:

- `swift-tui/Tests/SwiftTUITests/ButtonFocusStabilityTests.swift`
- `swift-tui/Tests/SwiftTUITests/StatePersistenceTests.swift`
- `swift-tui/Tests/SwiftTUIViewsTests/StateInvalidationDependencyTests.swift`

Required coverage:

- selected tab body button action mutates the original content `@State`;
- deferred/captured builder binding reads land on the actual descendant reader;
- hidden/inactive content does not accidentally claim a state dependency until
  realized.

These tests protect the previous live-owner recovery fix while payload types are
renamed.

### 0.3 Add active-only lifecycle coverage

Owner suites:

- `swift-tui/Tests/SwiftTUITests/TabLifecycleTests.swift`
- `swift-tui/Tests/SwiftTUITests/TabTaskActivationRuntimeTests.swift`

Required coverage:

- inactive tab bodies do not start `.task`;
- switching to a tab starts its body lifecycle exactly once;
- switching away from a tab stops or deactivates body lifecycle according to
  current behavior;
- scoped publication restores action and task registrations for selected tab
  body nodes behind the lazy edge.

If existing tests already cover a row, add comments linking the coverage instead
of adding duplicates.

### 0.4 Add portal owner coverage

Owner suites:

- `swift-tui/Tests/SwiftTUITests/PresentationSurfaceTests.swift`
- `swift-tui/Tests/SwiftTUITests/PresentationTriggerSplitTests.swift`
- `swift-tui/Tests/SwiftTUITests/PresentationContinuityTests.swift`
- `swift-tui/Tests/SwiftTUITests/OverlayStackTests.swift`

Required coverage:

- sheet content button mutates the source owner;
- popover content button mutates the source owner;
- menu item action mutates the menu source owner;
- presentation dismissal mutates the source owner and requests only the intended
  follow-up invalidation;
- trigger-leaf split still spares the background when reader attribution is on.

### 0.5 Add layout-realized coverage marker

Owner suites:

- `swift-tui/Tests/SwiftTUITests/GeometryReaderSurfaceTests.swift`
- `swift-tui/Tests/SwiftTUITests/AnchorPreferenceSurfaceTests.swift`

Required coverage:

- `GeometryReader` receives placed-frame table data for named coordinate-space
  and anchor resolution;
- autonomous state updates inside geometry-realized content rerender without a
  follow-up input event.

## 5. Stage 1 - introduce vocabulary with compatibility wrappers

Stage 1 should be mostly mechanical and behavior-preserving.

### 1.1 Add captured-subview scope names

Add a small compatibility layer, likely in
`swift-tui/Sources/SwiftTUIViews/State/AuthoringContext.swift` or a sibling file:

```swift
package typealias CapturedSubviewScope = DeferredAuthoringContextSnapshot

@MainActor
package func makeCapturedSubviewScope(
  from context: AuthoringContext? = currentAuthoringContext()
) -> AuthoringContext? {
  makeDeferredAuthoringContext(from: context)
}
```

If a typealias makes call sites too ambiguous, use a wrapper struct with one
`authoringContext` computed property. The first pass should not change the
stored fields.

### 1.2 Add captured-subview payload names

Add `CapturedSubviewPayload`, `CapturedSubviewView`, and
`CapturedSubviewGroupView` as wrappers or aliases over `DeferredViewPayload`.

Do not remove `DeferredViewPayload` yet. Call sites will be converted in later
stages.

### 1.3 Add lazy-subview payload shell

Add a new `LazySubviewPayload` type in `SwiftTUIViews/Foundation`.

Initial implementation may wrap `DeferredViewPayload`, but it must carry
metadata fields that make the active-only contract explicit:

```swift
package struct LazySubviewPayload: Sendable {
  package var debugName: String
  package var declarationIdentity: Identity?
  package var declarationStructuralPath: StructuralPath?
  package var lifecyclePolicy: LazySubviewLifecyclePolicy
  private var payload: CapturedSubviewPayload
}
```

Initial lifecycle policy can be descriptive only:

```swift
package enum LazySubviewLifecyclePolicy: Sendable, Equatable {
  case activeOnly
}
```

### 1.4 Add portal attachment shell

Add `PortalAttachmentPayload` and `PortalAttachmentEdge` in
`SwiftTUIViews/Presentation`.

Initial implementation may wrap `PortalContentPayload`, but it must make the
declaration/placement edge explicit:

```swift
package struct PortalAttachmentEdge: Sendable, Equatable {
  package var portalEntryID: PortalEntryID
  package var sourceIdentity: Identity
  package var sourceStructuralPath: StructuralPath
  package var modalPolicy: PortalModalPolicy
}
```

Add only fields that can be populated correctly in Stage 1. Do not invent
metadata that would be stale or guessed.

### 1.5 Add layout-realized aliases

Add aliases in `SwiftTUICore/Resolve/LayoutDependentContent.swift`:

```swift
package typealias LayoutRealizedContentBoundary = LayoutDependentContentBoundary
package typealias LayoutRealizationGeometry = LayoutRealizationContext
```

Keep the existing names until all baseline checks pass and downstream package
visibility is understood.

## 6. Stage 2 - convert captured inline children

Stage 2 changes names at call sites that are in-tree and always resolved as
ordinary children.

### 2.1 Style labels

Convert style configuration label wrappers:

- `ButtonStyleConfiguration.Label`
- `TextFieldStyleConfiguration.Label`
- `PickerStyleConfiguration.Label`

Target:

- store `CapturedSubviewPayload`;
- render through `CapturedSubviewView`;
- keep all behavior identical.

Focused tests:

- `swift test --filter Button`
- `swift test --filter TextField`
- `swift test --filter Picker`
- `swift test --filter FocusTransitionTests`

### 2.2 Stored modifier children

Convert:

- `.overlay`
- `.background`
- `.safeAreaInset`
- `ModifiedContent`

Target:

- replace `makeDeferredAuthoringContext()` with `makeCapturedSubviewScope()`;
- keep inline child topology unchanged;
- keep `layoutBehavior: .decoration` and `.safeAreaInset` unchanged.

Focused tests:

- `swift test --filter Overlay`
- `swift test --filter SafeArea`
- `swift test --filter PresentationSurfaceTests`
- `swift test --filter AnchorPreferenceSurfaceTests`

### 2.3 Scroll and erased storage

Convert:

- `ScrollView.contentAuthoringScope`
- `AnyView.scoped`
- `scopedAnyView`

Target:

- preserve state owner and ordinal behavior;
- do not change scroll layout or input registration.

Focused tests:

- `swift test --filter InteractiveRuntimeTests`
- `swift test --filter Scroll`
- `swift test --filter AnyView`

## 7. Stage 3 - convert active-only lazy children

Stage 3 moves `TabView` and navigation off generic deferred/portal terminology.

### 3.1 Add lazy declared-child helpers

Add helpers next to the current deferred helpers:

```swift
package func appendLazyDeclaredBuilderChildren<V: View>(
  from view: V,
  debugName: String,
  lifecyclePolicy: LazySubviewLifecyclePolicy,
  into children: inout [LazySubviewPayload]
)

package func lazyDeclaredBuilderChildren<V: View>(
  from view: V,
  debugName: String,
  lifecyclePolicy: LazySubviewLifecyclePolicy
) -> [LazySubviewPayload]
```

Implementation can delegate to the existing declared-children traversal at
first. Do not require every `DeclaredChildrenView` implementation to add a new
method in the first patch unless that is simpler than adapter helpers.

### 3.2 Convert `TabView`

Files:

- `SwiftTUIViews/TabViews/TabView.swift`
- `SwiftTUIViews/TabViews/TabViewStyles.swift`
- built-in tab style files that render active content.

Changes:

- `TabOption.contentPayload` becomes `LazySubviewPayload?`;
- `TabViewStyleBodyConfiguration.Content.payload` becomes
  `LazySubviewPayload?`;
- selected content resolves through `LazySubviewPayload`;
- inactive content remains unresolved;
- metadata peeking remains separate from active body resolution.

Runtime contract:

- active tab body is lazy active-only content;
- state writes inside selected body route to the visible body;
- selected body runtime registrations restore after scoped publication;
- inactive body tasks are not registered.

Focused tests:

- `swift test --filter TabViewSurfaceTests`
- `swift test --filter TabViewStyleParityTests`
- `swift test --filter TabLifecycleTests`
- `swift test --filter TabTaskActivationRuntimeTests`
- `swift test --filter ButtonFocusStabilityTests`
- `swift test --filter InteractiveRuntimeTests/scrollOnTabViewHostedInternalStateScrollViewUpdatesRenderedSurface`

### 3.3 Convert navigation destinations

Files:

- `SwiftTUIViews/NavigationViews/NavigationStack.swift`
- `SwiftTUIViews/NavigationViews/NavigationDestinationPreferences.swift`

Changes:

- `NavigationDestinationInstance.payload` becomes `LazySubviewPayload`;
- destination activation records explicit lazy payload metadata;
- `NavigationDestinationSurface` resolves a lazy payload, not a portal payload.

Focused tests:

- `swift test --filter Navigation`
- add a test where a destination-local button mutates destination state after
  activation and after a parent rerender;
- add a test where item destination identity changes and old state/lifecycle is
  not incorrectly reused.

## 8. Stage 4 - convert portal attachments

Stage 4 makes detached presentation content use portal-specific names and edge
metadata.

### 4.1 Convert portal core

Files:

- `Presentation/Portal.swift`
- `Presentation/PresentationItems.swift`
- `Presentation/OverlayStack.swift`
- `Presentation/PresentationCoordinatorRegistry.swift`
- `Presentation/PresentationCoordinator.swift`

Changes:

- introduce `PortalAttachmentPayload.resolve(in:)`;
- convert presentation item payload arrays from `[PortalContentPayload]` to
  `[PortalAttachmentPayload]`;
- keep compatibility aliases for tests and any internal callers not yet moved;
- ensure each payload carries a real `PortalAttachmentEdge` when declared by a
  source node.

Edge metadata should be derived from existing `presentationAttachment(for:token:)`
and `PortalEntryID`. Do not derive source identity from string parsing.

### 4.2 Convert built-in prompt presentations

Files:

- `Presentation/PromptPresentationEntrypoints.swift`
- `Presentation/PresentationModifiers.swift`
- `Presentation/PromptPresentationSurface.swift`
- `Presentation/ToastPresentation.swift`

Changes:

- use portal attachment builder helpers;
- keep trigger-leaf reader attribution unchanged;
- keep `PromptPresentationItem` rendering behavior unchanged.

Focused tests:

- `swift test --filter PresentationSurfaceTests`
- `swift test --filter PresentationTriggerSplitTests`
- `swift test --filter PresentationContinuityTests`
- `swift test --filter OverlayStackTests`

### 4.3 Convert popovers

Files:

- `Presentation/PopoverPresentation.swift`
- `Presentation/BuiltinItemPopoverPresentationModifier.swift`
- `Presentation/PopoverAttachmentAnchor.swift`

Changes:

- popover content payloads become portal attachments;
- source-frame lookup stays in hosted popover placement;
- modal policy remains explicit on the popover item.

Focused tests:

- `swift test --filter Popover`
- `swift test --filter PresentationTriggerSplitTests/popover`

## 9. Stage 5 - split menu from sheet-shaped presentation

Stage 5 should happen after portal attachments are explicit.

### 5.1 Introduce a menu presentation modifier

Files:

- `Controls/Menu.swift`
- new or existing presentation support file under `Presentation/`
- `PromptPresentationEntrypoints.swift`, if the menu spec stays there.

Add a `BuiltinMenuPresentationModifier` or similarly named primitive. It may
reuse:

- `menuPromptPresentationSpec()`;
- `PromptPresentationSurface`;
- portal attachment payloads;
- overlay stack entries.

It should not instantiate `BuiltinSheetPresentationModifier`.

### 5.2 Preserve first, improve anchoring second

First patch:

- preserve current visual placement and behavior;
- only split menu from sheet terminology;
- update tests to assert the sheet modifier path is not used, if practical via
  source-level test or render shape.

Second patch:

- add source-frame anchoring if desired;
- reuse popover placement utilities or introduce a shared source-attached
  placement helper.

Focused tests:

- `swift test --filter Menu`
- `swift test --filter PresentationSurfaceTests`
- `swift test --filter TabViewSurfaceTests` because overflow/menu chrome has
  regressed there before.

## 10. Stage 6 - narrow layout-realized names

Stage 6 should be the lowest-risk semantic pass because `GeometryReader` is
already the correct layout-time user.

Files:

- `SwiftTUICore/Resolve/LayoutDependentContent.swift`
- `SwiftTUICore/Measure/*`
- `SwiftTUICore/Place/*`
- `SwiftTUIViews/GeometryReading/GeometryReader.swift`

Changes:

- migrate production code to `LayoutRealizedContentBoundary` naming;
- keep typealiases for old names through at least one release or until package
  visibility checks confirm no public/SPI break;
- update comments to describe "layout-realized" rather than generic deferred
  content.

Focused tests:

- `swift test --filter GeometryReaderSurfaceTests`
- `swift test --filter AnchorPreferenceSurfaceTests`
- `swift test --filter StackSafetyRegressionTests`

Baseline checks:

- `Scripts/generate_public_api_inventory.sh --check`
- if the baseline changes only because package-visible names changed, regenerate
  the baseline in the same change with a note in the commit message.

## 11. Stage 7 - remove old generic names where possible

Only after Stages 2-6 pass:

- `rg "makeDeferredAuthoringContext|DeferredViewPayload|PortalContentPayload|LayoutDependentContentBoundary" swift-tui/Sources`
- classify remaining hits as compatibility aliases, tests, docs, or real
  missed production call sites;
- remove or deprecate old helpers where no production call site needs them;
- update DocC and internal comments.

Do not remove old names if they appear in public/SPI inventory without an
explicit compatibility decision.

## 12. Runtime follow-up after the split

The split does not immediately delete island-seam compatibility logic. It makes
the seams explicit enough for later cleanup.

After the payload migrations, run a focused audit of:

- `ViewNode.evaluationHost`;
- `ViewNode.hasStaleIslandDescendant`;
- identity-prefix runtime registration restore;
- all-effect registration republish;
- portal invalidation translation.

For each mechanism, decide whether it is still required for:

- `AnyView` or `.id` re-rooted content;
- lazy tab/navigation payloads;
- portal attachments;
- layout-realized content.

Do not remove a compatibility mechanism until a package-owned regression proves
the relevant edge type no longer needs it.

## 13. Verification matrix

Run focused suites after each stage, then broader gates after each group of
stages.

### Focused stage gates

Use package-local filters from `swift-tui`:

```bash
swift test --package-path swift-tui --filter StateInvalidationDependencyTests
swift test --package-path swift-tui --filter ButtonFocusStabilityTests
swift test --package-path swift-tui --filter TabViewSurfaceTests
swift test --package-path swift-tui --filter TabTaskActivationRuntimeTests
swift test --package-path swift-tui --filter PresentationTriggerSplitTests
swift test --package-path swift-tui --filter PresentationSurfaceTests
swift test --package-path swift-tui --filter OverlayStackTests
swift test --package-path swift-tui --filter GeometryReaderSurfaceTests
swift test --package-path swift-tui --filter AnchorPreferenceSurfaceTests
```

Use `swiftly run` if that is required in the active shell/toolchain setup.

### Perf smoke

For stages that touch `TabView`, presentation, portal, runtime registration, or
publication:

```bash
swift run --package-path swift-tui/Tools/TermUIPerf termui-perf run \
  --scenario sheet-open-latency \
  --modes async \
  --iterations 8

swift run --package-path swift-tui/Tools/TermUIPerf termui-perf run \
  --scenario example-app-shell-workflow \
  --modes async \
  --iterations 8
```

Use a release build and separate artifact roots for final A/B evidence.

### Org gates

From the coordination root:

```bash
mise exec -- bazel test //:org_fast
```

Run `//:org_full` before merging a stage group that touches runtime publication,
presentation, navigation, or public/SPI names.

## 14. Definition of done

The refactor is complete when:

- every delayed-lowering production call site is classified into one of the four
  contracts;
- inline captured children use captured-subview names;
- `TabView` and navigation use lazy-subview payloads;
- presentations use portal-attachment payloads with explicit source edges;
- `Menu` no longer routes through a sheet-specific modifier;
- `GeometryReader` uses layout-realized naming or has a compatibility alias with
  a documented removal path;
- focused state-owner, lifecycle, registration, presentation, and geometry tests
  are green;
- `mise exec -- bazel test //:org_fast` is green;
- perf smoke shows no material regression in `sheet-open-latency` or
  `example-app-shell-workflow`.

## 15. Rollback strategy

Each stage should be revertible on its own.

- Stages 1 and 2 are naming/wrapper changes; rollback is mechanical.
- Stage 3 is isolated to lazy tab/navigation payloads; keep old helper aliases
  until the stage is validated.
- Stage 4 is isolated to portal payloads; keep `PortalContentPayload` as an
  adapter until all presentations are moved.
- Stage 5 has a parity-first substage so menu can fall back to the current sheet
  path if source anchoring work regresses.
- Stage 6 keeps layout-dependent aliases until baseline checks are settled.

Do not combine Stage 3 or Stage 4 with broad runtime cleanup. The compatibility
logic audit belongs after the new contracts are stable.
