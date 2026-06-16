# Perf Signal Representativeness Pass

- **Date:** 2026-06-16
- **Current checkout:** `swift-tui 78fb9f4c`
- **Last measured baseline:** `swift-tui 8cebb787` / `0.0.20`
- **Purpose:** sanity-check the current `TermUIPerf` signals against real usage
  in the example apps before starting the next performance tranche.

## Summary

The committed performance suite is representative of the framework hot paths
that have recently produced regressions, but it is not a substitute for real
example-app interaction coverage.

That split is intentional. `swift-tui/Tools/TermUIPerf` lives in the public
framework repo and cannot depend on `swift-tui-examples`, so its committed
scenarios are small framework-only reconstructions of example-app shapes. The
suite is good for high-signal same-session A/Bs, row sweeps, canaries, and a
new committed app-shell workflow that covers chrome, scrolling, popover, sheet,
side-panel, and panel-boundary composition. It is still weaker for app-owned
flows such as gallery tab switching, text-input editing, multi-column file
browsing, GIF-editor canvas edits, and host-specific presentation.

The next tranche should therefore start with diagnostics, not a broad
optimization. In particular, the `sheet-open-latency` 176-row run is an
amplified signal for presentation bookkeeping, not a typical app workload. The
co-located vs sibling comparison is the right first diagnostic because real
apps often put triggers in chrome or sibling panels rather than inside the heavy
content pane.

## Example-App Surface Checked

Representative usage in `swift-tui-examples` currently includes:

- **Gallery:** 19 tabs spanning state/buttons, text input and focus, scrolling,
  list/table/navigation collections, sheets, popovers, palette sheets,
  animations, `PhaseAnimator`, images/GIFs, pointer gestures, focus context,
  physics-style gestures, and task-progress timeline updates.
- **Layouts:** 56 catalog entries across stacks, frames, padding, borders and
  overlays, offset/position, custom layout, scrolling, geometry, collections,
  presentation layouts, and matched geometry.
- **File previewer:** multi-column browser state, selection movement, scroll
  position retention, directory-cache invalidation, and embedded terminal
  preview panes.
- **GIF editor:** large stateful reference-model UI with menu dropdowns,
  scrollable canvas, layers/palette panels, sheets, playback tasks, timeline
  updates, and canvas/palette editing.
- **Host examples:** SwiftUI, Web, Android, and terminal host surfaces exercise
  embedding and presentation boundaries that are not directly measured by the
  committed framework-only perf suite.

## Scenario Map

| `TermUIPerf` signal | Example-app coverage | Representativeness | Notes |
| --- | --- | --- | --- |
| `example-app-shell-workflow` | Gallery command palette/chrome, GIF-editor shell and menu/save flows, file-previewer pane chrome, Layouts app-shell composition | High for app-shell composition; medium for exact app behavior | New committed calibration signal. It combines scrollable main content, a side inspector, a dropdown/popover, a sheet, and a panel boundary without depending on `swift-tui-examples`. It is still not a substitute for real gallery or GIF-editor overlay runs. |
| `sheet-open-latency` | Gallery command palette, Presentation Lab, Popovers tab, GIF editor save/resize sheets, menu overlays | High for presentation mechanics; amplified for size | Default rows are smoke-friendly. Rows=176 is a stress lens for root/frontier, publication, checkpoint, raster, and portal bookkeeping. Treat it as diagnostic, not average UI latency. |
| `synthetic-narrow-invalidation` | Counter-like leaf controls, layout toggles, file-preview selection, small GIF-editor toolbar/palette actions | High as a retained-reuse canary; medium as a user flow | It isolates one local `@State` change beside a large static sibling tree. It intentionally omits focus, text input, observable models, and app-level command routing. |
| `layout-scroll-burst` | Gallery Scroll Control, Layouts scrolling examples, file previewer columns, GIF-editor canvas/body scroll areas | Medium | It measures a simple vertical scroll burst. It does not cover multi-column keep-selection-visible behavior, terminal preview churn, or nested scroll/pane composition. |
| `gallery-animation-click` | Gallery Animations tab first `withAnimation` curve buttons | Medium | It is an exact shape for a single simple animation click, but it does not cover transitions, matched geometry, PhaseAnimator sections, or animation completion behavior. |
| `synthetic-offscreen-phase-animator` | Gallery Animations offscreen/scrolling cases, Borders & Shapes animated tile | Medium as an idle-frame canary | Good for "offscreen animation should not keep painting" policy. Less representative of visible animation quality. |
| `synthetic-continuous-animation` | Gallery task-progress/spinner-like indicators, visible animation surfaces | Medium | Good for continuous visible repaint and raster/presentation pressure. It is intentionally tiny and does not cover complex animated layouts. |
| `synthetic-text-shimmer` | Gallery Task Progress, status/progress text churn, GIF-editor playback/status readouts | Medium-low | Good for text-layout cache churn and timeline-driven text. It is synthetic and narrow. |

## Missing or Weak Signals

These gaps matter when interpreting the current ranking:

- **Real gallery palette/tab-switch path.** The command palette and tab switch
  flow is app-owned and currently only available as overlay or example tests,
  because the public framework package cannot depend on the gallery package.
- **Text editing and focus.** Text fields, editors, focus scopes, and paste paths
  are heavily used in Gallery and GIF editor but are not a committed perf
  scenario.
- **Collections and navigation.** List/table selection, navigation destination
  changes, and file-browser column updates are covered by correctness tests but
  not timed as perf scenarios.
- **Pointer and drag gestures.** Pointer Lab, Physics, and GIF-editor canvas drag
  behavior are not represented by the current click/scroll-only perf input
  scripts.
- **Image/GIF and canvas-heavy rendering.** The suite has raster signals but not a
  realistic animated-image, pixel-canvas, or image-blend workload.
- **Host-specific surfaces.** SwiftUIHost, WebHost, and Android host behavior
  need separate host smoke/perf validation because the committed scenarios run in
  the terminal host.

## Interpretation for the New Tranche

The 0.0.20 rebaseline remains a valid opener. The current `swift-tui` checkout
adds only import-visibility cleanup plus the `TermUIPerf` app-shell calibration
scenario; it does not change runtime framework behavior. The representative
conclusion does not change the next step, but it narrows how to read it:

1. **Run focused diagnostics first.** Use `SWIFTTUI_PUBLICATION_DIAGNOSTICS=1`
   and `SWIFTTUI_INVAL_TRACE=1` on `sheet-open-latency` at rows=176 for
   co-located and sibling triggers.
2. **Add calibration before code.** Include a default rows=44 pass if time allows
   and the committed `example-app-shell-workflow` so the next decision is not
   based only on the amplified 176-row case.
3. **Treat checkpoint storage as design work.** The cheap checkpoint-create lever
   was already disproven; a real create win implies a persistent checkpoint store
   or graph/state split.
4. **Do not start a general SwiftUI-style dependency engine yet.** Observable
   key-path fan-out, no-reader `@State` elision, and ancestor-invalidation reuse
   are still architecture projects. They should follow a workload that proves
   they beat the current portal/checkpoint/process-tree residuals.

## New-Tranche Opener

The tranche should begin with this diagnostic set from the org root after
rebuilding `termui-perf`:

```bash
swiftly run swift package reset --package-path swift-tui/Tools/TermUIPerf
swiftly run swift build -c release --package-path swift-tui/Tools/TermUIPerf --product termui-perf

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 SWIFTTUI_INVAL_TRACE=1 \
  TERMUI_PERF_SHEET_TREE_ROWS=176 \
  swift-tui/Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario sheet-open-latency \
  --modes async \
  --iterations 3 \
  --artifacts-root /tmp/swifttui-tranche-2026-06-16/diagnostics-sheet-176-colocated

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 SWIFTTUI_INVAL_TRACE=1 \
  TERMUI_PERF_SHEET_TREE_ROWS=176 TERMUI_PERF_SHEET_TRIGGER=sibling \
  swift-tui/Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario sheet-open-latency \
  --modes async \
  --iterations 3 \
  --artifacts-root /tmp/swifttui-tranche-2026-06-16/diagnostics-sheet-176-sibling

SWIFTTUI_PUBLICATION_DIAGNOSTICS=1 SWIFTTUI_INVAL_TRACE=1 \
  swift-tui/Tools/TermUIPerf/.build/release/termui-perf run \
  --scenario example-app-shell-workflow \
  --modes async \
  --iterations 3 \
  --artifacts-root /tmp/swifttui-tranche-2026-06-16/diagnostics-example-app-shell
```

Decision rule: if the co-located/sibling gap attributes to remaining portal or
focus/root-gate bookkeeping, continue with a scoped force-root/focus narrowing
design. If it attributes mostly to checkpoint create/restore with no meaningful
publication/invalidation difference, start a checkpoint-storage design. If the
gap collapses at default rows, keep the 176-row path as a stress canary and do
not optimize solely for it.
