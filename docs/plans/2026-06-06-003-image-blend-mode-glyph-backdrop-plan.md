# Image Blend Mode Glyph Backdrop Plan

**Date:** 2026-06-06
**Status:** Follow-on implementation plan after cache hardening.
**Target repos:** implementation lives in the `swift-tui` submodule. Root owns
this plan and any final submodule pin update.

## 1. Goal

Move blended image precomposition beyond background-only cells by making the
captured backdrop aware of text foregrounds and glyph occupancy.

This tranche should improve cases like:

- a blended image over colored text with no cell background;
- a blended image over borders, charts, block elements, or fallback graphics;
- a blended image over styled text where the first tranche currently sees only
  the host fallback background.

The target is a deterministic glyph-aware approximation that is honest about
terminal limits. Exact antialiased font masks are host-specific and remain a
later host-native tranche.

## 2. Preconditions

- The first-tranche precomposed image path is implemented and pinned.
- The cache-hardening tranche is complete or in flight, so glyph-aware variants
  do not introduce unbounded cache growth.
- Public docs already state that tranche 1 blends against cell backgrounds only.

## 3. Current Anchors

Relevant `swift-tui` files:

- `Sources/SwiftTUICore/Content/ImageTypes.swift`
  - `RasterImageBackdropCell` currently stores only `backgroundColor`.
- `Sources/SwiftTUICore/Raster/Rasterizer+Paint.swift`
  - `captureImageBackdrop` slices `RasterCell.style?.backgroundColor`.
- `Sources/SwiftTUIRuntime/Terminal/ImageBlendCompositor.swift`
  - `backdropColor` expands one backdrop cell into a flat pixel color.
- `Sources/SwiftTUICore/Raster/RasterCell.swift`
  - contains the glyph and style data needed to represent text foreground.
- `Sources/SwiftTUICore/Raster/Rasterizer+Sampling.swift`
  - contains the existing sub-cell sampling vocabulary for block/braille/canvas
    work.
- Tests to extend:
  - `Tests/SwiftTUICoreTests/RasterizerTests.swift`
  - `Tests/SwiftTUITests/ImageBlendCompositorTests.swift`
  - `Tests/SwiftTUITests/TerminalGraphicsProtocolTests.swift`
  - `Platforms/WASI/Tests/WASISurfaceBridgeTests/WebSurfaceTransportTests.swift`

## 4. Design

### 4.1 Backdrop Cell Payload

Extend the internal/public core backdrop payload conservatively:

```swift
public struct RasterImageBackdropCell: Equatable, Sendable {
  public var backgroundColor: Color?
  public var foregroundColor: Color?
  public var glyph: Character?
  public var spanWidth: Int
}
```

Exact names can change. The important point is that the compositor can
distinguish:

- empty cell over background;
- ordinary glyph foreground over background;
- full-cell block glyphs;
- partial block/braille glyphs where SwiftTUI already knows sub-cell coverage;
- wide glyph leading and continuation cells.

Keep initializer defaults source-compatible.

### 4.2 Coverage Model

Add a small internal coverage model:

```swift
package enum RasterBackdropCoverage: Sendable, Equatable {
  case none
  case full
  case halfBlockTop
  case halfBlockBottom
  case quadrant(mask: UInt8)
  case braille(mask: UInt8)
  case textApproximation
}
```

Coverage rules:

- space-like glyph with no foreground: background only;
- full block: foreground fills the whole cell;
- half/quarter/block drawing glyphs: use known geometric coverage;
- braille: use the existing 2x4 dot grid approximation;
- ordinary text: use a documented solid-center approximation, not an exact font
  mask.

The compositor should expand the coverage into the image pixel grid using the
same `cellPixelSize` already stored in `RasterImageCompositing`.

### 4.3 Backdrop Pixel Expansion

Replace the current single-color `backdropColor(...)` lookup with
`backdropPixelColor(...)`:

- compute the cell for the output pixel;
- compute the sub-cell pixel location;
- start with background or host fallback background;
- if coverage contains that sub-cell pixel, composite foreground over
  background using normal source-over semantics;
- return that pixel color as the backdrop color for image blending.

This keeps all decoding and pixel generation in runtime, not core.

### 4.4 Signatures and Damage

The deterministic backdrop signature must include all new payload fields:

- background color;
- foreground color;
- glyph identity;
- span width;
- coverage classification.

This ensures changing a glyph under a blended image dirties and replays the
image even when the cell background is unchanged.

### 4.5 Host Behavior

Terminal, WebHost/WASI, and SwiftUI host should all consume the same
precomposed blended variants. Do not add native canvas/CoreGraphics blend modes
in this tranche.

## 5. Phased Execution

### Phase 0 - Failing Tests

- Add a rasterizer test proving a foreground-only glyph under a blended image
  changes the backdrop signature.
- Add compositor tests for:
  - full-block glyph over fallback background;
  - half-block glyph;
  - ordinary text approximation;
  - wide glyph continuation behavior.
- Add a damage-diff test where only glyph foreground changes under the image.

Focused commands:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUICoreTests.RasterizerTests
swiftly run swift test --filter SwiftTUICoreTests.RasterSurfaceDamageDiffTests
swiftly run swift test --filter SwiftTUITests.ImageBlendCompositorTests
```

### Phase 1 - Backdrop Payload Extension

- Extend `RasterImageBackdropCell` with foreground/glyph/span fields and
  source-compatible defaults.
- Update `captureImageBackdrop` to store the visible `RasterCell` foreground and
  glyph data.
- Update snapshot/tree descriptions only with compact indicators; never dump
  full backdrop arrays.
- Regenerate public API baseline if new public fields are exposed.

### Phase 2 - Coverage Classification

- Add the coverage classifier in core or runtime depending on existing glyph
  helpers.
- Prefer existing block/braille helpers over new ad hoc Unicode tables.
- Add direct unit tests for coverage classification.

### Phase 3 - Runtime Expansion

- Expand captured foreground/background coverage into pixel backdrops.
- Preserve the first-tranche background-only behavior for empty cells.
- Include foreground/glyph data in the compositor cache key through the stable
  backdrop signature.

Focused command:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUITests.ImageBlendCompositorTests
```

### Phase 4 - Host Regression Coverage

- Terminal graphics: assert backdrop glyph-only changes replay the blended image
  while text damage remains incremental.
- WASI/WebHost: assert changed glyph backdrop produces a new blended image ID.
- SwiftUI host: add coverage only if the current harness can observe variant
  choice without unstable image snapshots.

### Phase 5 - Docs and Gates

- Update public authoring/render-pipeline docs to say blended images use
  glyph-aware approximations for known terminal block/braille glyphs and
  ordinary text remains approximate.
- Run public API inventory if the public payload changed.

Final verification:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUITests.ImageBlendCompositorTests --jobs 4
swiftly run swift test --filter SwiftTUITests.TerminalGraphicsProtocolTests --jobs 4
swiftly run swift test --filter WASISurfaceBridgeTests.WebSurfaceTransportTests --jobs 4
swiftly run swift test --jobs 4
./Scripts/generate_public_api_inventory.sh --check

cd /Users/adamz/Developer/swift-tui-org
mise exec -- bazel test //:org_fast
```

## 6. Non-Goals

- Exact antialiased font-mask reproduction in terminal hosts.
- Ordered image-over-image semantics.
- Native canvas/CoreGraphics blend mode replay.
- GIF decode or GIF blending.

## 7. Completion Criteria

- Foreground-only backdrop changes under a blended image alter the compositing
  signature and replay/damage behavior.
- Full-block, partial-block, braille, and ordinary-text approximations are
  covered by tests.
- Empty-cell/background-only behavior remains compatible with tranche 1.
- Public docs describe the approximation honestly.

