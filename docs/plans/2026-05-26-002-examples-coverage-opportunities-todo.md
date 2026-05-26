# SwiftTUI Examples Coverage Opportunities Todo

**Goal:** Align `swift-tui-examples` with its purpose: showcase framework
features and build configurations with near-comprehensive coverage of how
SwiftTUI can be used.

**Status:** Complete for the current pass. The example matrix, gate contract,
focused-test lane, gallery coverage, shared host scenes, and documentation
cleanup items have repo changes and focused verification.

**Verification note:** the focused lane now passes after the `file-previewer`
targets opted into strict memory safety; the earlier
`ColumnBrowserNavigationTests` signal 11 no longer reproduces.

---

## Priority 0: Inventory And Contract

- [x] Add an examples coverage matrix that maps each example to product,
  feature surface, host/build mode, test status, and intended audience.
- [x] Classify every example as one of: copyable tutorial, focused product
  sample, advanced app, stress/regression sample, or host/build configuration
  sample.
- [x] Reconcile the README roster, package manifests, CI scripts, and Bazel
  native gate so every listed example is either built/tested or explicitly
  marked manual-only.
- [x] Add a "new example checklist" covering README entry, build gate entry,
  focused tests if applicable, and product/feature matrix row.

## Priority 1: Gate Coverage

- [x] Decide whether `minimal` should be in the native gate or explicitly
  documented as a documentation-only snapshot example.
- [x] Decide whether `LayoutsSwiftUI` should be built in the native gate or
  moved into a macOS-only host lane.
- [x] Split build-only coverage from focused test coverage in
  `Scripts/check_examples.sh` output.
- [x] Add a slower focused-test lane or script for examples with meaningful test
  targets: `gallery`, `layouts`, `gifeditor`, `gitviz`, `file-previewer`,
  `terminal-runner`, `gifcat`, `terminal-workspace`, `WebHostExample`, and
  `WebExample`.
- [x] Keep root Bazel and pre-tag overlay gates aligned after the example matrix
  and scripts change.

## Consolidation Opportunities

- [x] Extract a small shared host-scenes package used by `SwiftUIExample`,
  `WebExample`, and optionally `WebHostExample`.
- [x] Make `SwiftUIExample` and `WebExample` either share the same app
  declaration or explicitly document why their scene sets differ.
- [x] Refactor `GalleryView` around a tab descriptor registry that owns tab
  title, enum/id value, aliases, palette labels, and coverage tags. Tab content
  stays statically declared so per-tab state keeps stable runtime identities.
- [x] Use the gallery tab registry to keep README coverage and test fixtures from
  drifting as tabs are added or removed.
- [x] Consider moving small host/build configuration examples into a shared
  package shape with thin launchers instead of independent scene definitions.

## Removal Or Demotion Candidates

- [x] Decide whether `gifcat` remains as the tiny direct
  `SwiftTUIAnimatedImage` reference or is folded into gallery/GIF editor
  coverage.
- [x] Rename or generalize the gallery "Claude" tab into a neutral working
  status/task-progress sample.
- [x] Reclassify `gifeditor` as an advanced application/stress sample, not
  tutorial code.
- [x] Move or delete `gifeditor/REDESIGN.md` if it is stale implementation
  history rather than current example documentation.
- [x] Remove redundant or unused package dependencies, such as host examples
  declaring products their scene code no longer imports.

## Slimming Opportunities

- [x] Replace repeated gallery metadata and palette label strings with
  descriptor-backed registration.
- [x] Shorten dated milestone/history comments in `AnimationsTab` and
  `BordersAndShapesTab`.
- [x] Refresh stale `LayoutCatalog` comments that still describe a mid-plan
  implementation state.
- [x] Keep `layouts` focused on layout behavior and move non-layout component
  demonstrations into gallery.
- [x] Keep `gifeditor` README focused on copyable architecture boundaries and
  move exhaustive keybinding/reference material behind a secondary section.

## Missing Or Under-Showcased Features

- [x] Add a "Forms & Containers" gallery tab for `GroupBox`, `ControlGroup`,
  `DisclosureGroup`, `Link`, picker styles, button styles, text-field styles,
  validation, disabled state, and form-like composition.
- [x] Add a "Presentation Lab" gallery tab for `alert`, `confirmationDialog`,
  `sheet`, `toast`, `popover`, `popoverTip`, and `paletteSheet` in one coherent
  workflow.
- [x] Add a "Navigation & Collections" gallery tab or focused example for
  `NavigationStack`, `navigationDestination`, `OutlineGroup`, outline styles,
  `LazyVStack`, `LazyHStack`, list selection, and table selection.
- [x] Add a "Pointer Lab" gallery tab for `SpatialTapGesture`, long press,
  pointer hover, `contentShape`, named coordinate spaces, and pointer precision
  or cell-metric display.
- [x] Add a focused-context sample where a focused child publishes
  `FocusedValue` or `FocusedBinding` and a toolbar/status panel consumes it.
- [x] Add a terminal-only `SwiftTUICLI` example that deliberately rejects `--web`
  and demonstrates explicit terminal runner control.
- [x] Add a small accessibility/environment sample if the matrix shows
  accessibility labels, hints, live regions, open-link actions, or clipboard
  actions are not visible in current examples.

## Tutorial Quality Fixes

- [x] Reconcile `WebExample` README text with the actual scene package
  implementation.
- [x] Correct `gifeditor` README target/dependency descriptions so they match
  `Package.swift`.
- [x] Add "what to copy" sections to advanced examples so readers can separate
  framework usage from application-specific code.
- [x] Prefer neutral, framework-oriented sample names over product-specific
  demos unless the product-specific behavior is the point.
- [x] Ensure every small example has one obvious canonical pattern and avoids
  incidental complexity that belongs in advanced samples.

## Suggested Execution Order

- [x] Land the coverage matrix and gate contract first.
- [x] Fix gate drift and stale documentation second.
- [x] Consolidate shared host scenes and gallery registration third.
- [x] Demote or slim redundant examples fourth.
- [x] Add missing feature tabs and the terminal-only build configuration example
  last, once the matrix can prove the remaining gaps.
