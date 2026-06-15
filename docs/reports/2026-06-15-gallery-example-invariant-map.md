# Gallery and Example Invariant Map

- **Date:** 2026-06-15
- **Status:** Focused package coverage added for the uncovered fundamentals.
- **Scope:** `swift-tui-examples` gallery/example tests as evidence; package-owned
  coverage in `swift-tui/Tests`.

## Purpose

Gallery and example tests remain valuable integration smoke, but they should not
be the only proof for reusable SwiftTUI behavior. This report records which
framework-level behaviors the current gallery/example suites expose and where
those behaviors are, or should be, proven in the main `swift-tui` package suite.

The rule is: if a regression is caused by SwiftTUI runtime, layout,
presentation, focus, gesture, animation, state, rendering, or host-contract
behavior, add the smallest synthetic package test first. Keep the example test
only when it protects app wiring, fixture content, command-line routing, or
multi-package integration.

## Main-Suite Additions

Two reusable layout/presentation fundamentals were still only proven indirectly
by example tests:

- `swift-tui/Tests/SwiftTUITests/PresentationContinuityTests.swift` now includes
  `alertActivationPreservesBaseContentPlacement`, a synthetic alert overlay test
  proving that presenting an alert does not move the base content's placed
  bounds.
- `swift-tui/Tests/SwiftTUITests/LayoutAndRenderingPipelineTests.swift` now
  includes `zStackSpacerIsLayoutNeutralWhileGreedyChildrenStretch`, a synthetic
  `ZStack` test proving `Spacer` is layout-neutral in overlay layout while a
  greedy child still stretches.

## Inventory And Mapping

| Evidence suite | Framework behavior exposed | Main-suite disposition | Example-owned remainder |
| --- | --- | --- | --- |
| `gallery/Tests/GalleryDemoViewsTests/GalleryTabSwitchTests.swift` | Literal-tab overflow, pointer/keyboard selection, tab-local state persistence, selected-tab task activation, palette/presentation continuity over animated frames, async stale-frame policy. | Covered by `TabViewSurfaceTests`, `TabViewLifecycleTests`, `TabTaskActivationRuntimeTests`, `PresentationContinuityTests`, `AsyncFrameTailRenderingTests`, `FrameDropEligibilityTests`, and `PipelineContractTests`. Keep using gallery runtime tests as real-path smoke only. | Gallery tab roster, tab labels, seeded gallery harness, real terminal pty smoke. |
| `gallery/.../FullScreenTabGestureTests.swift` | Rect `contentShape` local-coordinate translation, stacked gesture registration, drag capture, animation frame scheduling, toolbar rendering over fullscreen animated content. | Covered by `ContentShapeTests`, `GestureViewModifierTests`, `LocalGestureRegistryTests`, `AnimationTickVisibilityTests`, and `ToolbarTests`. | Toy physics math, ball artwork, Gallery "Full Screen" tab composition. |
| `gallery/.../CommandPaletteTests.swift` and command-palette runtime checks | Palette sheet chrome, palette command absorption, default focus/presentation dismissal. | Covered by `PresentationSurfaceTests.dropdownPresentationsRenderContentWithoutTitleOrCloseChrome`, `PaletteSheetAbsorptionTests`, `FocusTransitionTests`, and palette/key-command package tests. | Gallery command list labels and palette-specific child identity shape. |
| `gallery/.../PopoverTabTests.swift`, `TextInputTabTests.swift`, `ScrollControlTabTests.swift` | Popover attachment/presentation, text-input rendering and reducer behavior, `ScrollViewReader`/scroll proxy surface. | Covered by `PopoverPresentationTests`, `TextInputReducerTests`, `TextInputRuntimeIntegrationTests`, `TextField`/`TextEditor` surface tests, `SwiftUISurfaceTests` scroll suites, and `InteractiveRuntimeTests`. | Demo tab copy, gallery `--tab` key routing, showcase layout. |
| `gallery/.../ImagesTabAnimatedGIFTests.swift` and `gifcat/Tests/GifCatTests/GifCatViewTests.swift` | Animated GIF decode, frame-delay preservation, animated image frame advancement, image attachment placement. | Covered by `SwiftTUIAnimatedImageTests/AnimatedImageTests.swift` and `TerminalGraphicsProtocolTests`. | Example input-path handling, grid planning, missing-file diagnostics, gallery fixture labels. |
| `gifeditor/Tests/GIFEditorUITests/CanvasViewTests.swift` | Canvas pixel-grid rendering, vertical half-block packing, sub-cell pointer precision, content-shape hit regions, RunLoop pointer dispatch. | Covered by `CanvasViewTests`, `ContentShapeTests`, gesture runtime tests, and `InteractiveRuntimeTests`. | GIF editor document model, tool behavior, cursor/selection overlay policy. |
| `gifeditor/.../PresentationRuntimeTests.swift` and `MenuBarViewTests.swift` | Key-command dispatch, modal presentation, menu/dropdown layering above content. | Covered by `KeyCommandTests`, `PresentationEscapeDismissTests`, `PresentationSurfaceTests`, `MenuSurfaceTests`, and `OverlayStackTests`. | Save-sheet content, playback state, editor-specific menu entries. |
| `layouts/Tests/LayoutsTests/**` behavior tests | Primitive layout rules: stack compression/priority, alignment guides, frames, safe area, scrolling, `ViewThatFits`, offset/position, ZStack paint/sizing, custom layout worker eligibility, alert overlay anchoring. | Mostly covered across `LayoutEngineTests`, `LayoutAndRenderingPipelineTests`, `SwiftUISurfaceTests`, `SafeAreaSurfaceTests`, `AsyncFrameTailRenderingTests`, and chart/shape tests. This change adds package coverage for alert anchor stability and ZStack Spacer neutrality. | SwiftUI comparison catalog, source-snippet generation, demo names/blurbs, visual parity examples. |
| `file-previewer/Tests/FilePreviewerAppTests/**` | Large-list viewport scale, column layout, scroll/preview interaction pressure. | Framework fundamentals covered by `SwiftUISurfaceTests` scroll/lazy-stack suites, `DiagnosticsAndCacheTests`, and `InteractiveRuntimeTests`. | Directory cache, previewer registry, Miller-column model, reveal-vs-enter navigation. |
| `gitviz/Tests/GitVizTests/RenderOnceSmokeTests.swift` and adapter tests | Render-once deterministic chart output through public chart views. | Chart rendering covered by chart-specific package tests and `SwiftUISurfaceTests` chart assertions. | Git parsing, graph layout, adapter/domain transformations. |
| `WebHostExample`, `terminal-runner`, `three-hosts-demo`, `WebExample/TerminalApp` tests | Public import convenience, runner selection, `WindowGroup`/scene roster, hosted-session contracts. | Covered by `SwiftTUIConvenienceImportTests`, `EntryPointLaunchTests`, `AppSceneConfigurationTests`, `SceneBuilderBackboneTests`, `SceneManifestTests`, and `HostedSceneSessionTests`. | Example source-policy checks and example-specific scene roster. |

## Future Push-Down Checklist

When a gallery/example failure appears:

1. Identify the primitive behavior: layout, presentation, focus, gesture,
   animation, state/invalidation, rendering, image, scroll, or host contract.
2. Search `swift-tui/Tests` for the matching primitive suite before changing an
   example test.
3. If no package test exists, add a deterministic synthetic view/runtime harness
   there first.
4. Keep the example assertion only if it still proves example-owned wiring or
   end-to-end integration after the package invariant is covered.
