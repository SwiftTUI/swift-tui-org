# layout-diff — SwiftUI vs SwiftTUI layout-comparison sweep

Coordination tooling (org root only — never a public child) that captures and
analyzes the 56 layout-gallery comparisons for likely layout discrepancies.
See the plan: [`docs/plans/2026-06-21-001-...`](../../docs/plans/2026-06-21-001-swiftui-swifttui-layout-comparison-screenshot-plan.md).

## What it does (current: headless content-extent tier)

For each of the 56 mirrored catalog entries (paired by stable `id`):

1. **SwiftTUI exporter** (`swift-tui-examples/layouts`, env `LAYOUT_EXPORT=1`):
   renders headlessly via `DefaultRenderer` and emits the non-blank **cell
   bounding box** + the plain-text cell grid → `/tmp/layout-probe/swifttui/<id>.json`.
2. **SwiftUI exporter** (`swift-tui-examples/LayoutsSwiftUI`, env
   `LAYOUT_EXPORT_ALL=1`): renders `entry.makeView()` headlessly via
   `ImageRenderer` and emits a PNG + the **pixel-ink bounding box** (÷ scale ÷ 10
   → cells) → `/tmp/layout-probe/{png,geometry}/<id>...`.
3. **Differ** (`diff.py`): joins by `id`, clips the SwiftTUI bbox to the canvas,
   computes the content-extent **IoU** + componentwise delta, classifies
   PASS/WARN/REVIEW/MISSING, and writes a ranked Markdown report with the SwiftUI
   PNG + SwiftTUI ASCII grid as paired evidence.
4. **SwiftTUI pixel exporter** (`swifttui-raster/`, a coordination-only SwiftPM
   tool): renders each entry to a true PNG via the swift-tui-swiftui
   `@_spi(Raster)` offscreen seam (`SwiftUIHostAppState.renderSelectedSceneToCGImage`)
   → `/tmp/layout-probe/swifttui-png/<id>.swifttui.png`.
5. **Pixel visual tier** (`pixel_compare.py`): assembles a **SwiftUI | SwiftTUI**
   side-by-side contact sheet ranked by the geometry IoU.

Canvas: 60×30 cells at 10 pt/cell (`LayoutScale.cell`).

## Run

```sh
mise run layout-diff       # all five steps (preferred)
tools/layout-diff/run.sh   # same thing, without mise

# needs swiftly + the pinned Swift 6.3.x toolchain, macOS/AppKit, and ImageMagick
```

## Signal & honest limits

- **IoU of content extent** is the ranking signal — robust to the systematic
  SwiftUI-ink-vs-SwiftTUI-cell width narrowing, sensitive to true structural
  mismatches (one engine fills the canvas, the other collapses).
- It is a **triage ranking, not a gate**. Width/height deltas of a few cells are
  expected measurement noise (proportional ink vs monospace cells).
- **MISSING** can be a dark-on-dark capture limit of the black-background pixel
  bbox, not necessarily a real discrepancy — confirm visually.
- **Per-element SwiftUI geometry is not headlessly automatable** (Phase-0
  accessibility spike: SwiftUI's a11y subtree does not materialize in an
  offscreen test process), so this compares content extent, not per-element rects.

## True-pixel tier (implemented)

The SwiftTUI pixel renders come from the `@_spi(Raster)` seam in
`swift-tui-swiftui` (`SwiftUIHostRasterCapture` + `SwiftUIHostAppState`
.renderSelectedSceneToCGImage / .resizeSelectedScene / .selectedSceneFrameSequence),
which reuses the on-screen `NativeRasterSurfaceRenderer` into an offscreen flipped
`CGContext`. The `swifttui-raster/` tool path-deps the LOCAL swift-tui-swiftui
(seam) + LOCAL `layouts` catalog while taking swift-tui from the same tagged
release both already pin — so there is **no dependency-override conflict and the
public child repos are untouched**.

**DSSIM/AE pixel diff was tried and dropped:** the two engines render text
differently (SwiftUI proportional ink at square cells vs SwiftTUI monospace
glyphs at tall cells), so a force-resized pair is ~maximally different for every
entry and the metric saturates (heatmap ~all-red). The side-by-side visual +
the geometry IoU are the real signals. Note also that the SwiftTUI content-bbox
(`diff.py`) measures non-space *glyphs*, so it undercounts background-color fills
(rectangles drawn as colored spaces) — the pixel pair compensates; upgrading the
bbox to count styled cells via `rasterSurface.cells` is a worthwhile follow-up.

## Placement / hygiene

- Tooling + report live in the **org root** (here + `docs/reports/`).
- Exporter targets are native-only and live in the public `swift-tui-examples`
  child (they describe HEAD; no coordination pins).
- All ephemeral output goes to `/tmp/layout-probe/` — **never** inside a
  submodule working tree (`tools/bazel/pin_cleanliness.sh` hard-fails `org_fast`
  on uncommitted/untracked submodule files).
