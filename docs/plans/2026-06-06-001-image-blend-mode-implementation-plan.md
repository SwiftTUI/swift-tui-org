# Image Blend Mode Implementation Plan

**Date:** 2026-06-06
**Status:** Draft implementation plan from
[`docs/proposals/IMAGE_BLEND_MODE.md`](../proposals/IMAGE_BLEND_MODE.md).
**Target repos:** implementation lives primarily in the `swift-tui` submodule,
with web runtime/transport follow-up in `swift-tui-web`. The coordination root
owns this plan and the final submodule pin update.

## 1. Goal

Implement the proposal's first tranche:

- `Image(...).blendMode(mode)` blends PNG/JPEG image pixels against the visible
  cell-background backdrop under the image.
- `AnimatedImage(...).blendMode(mode)` inherits the same behavior because every
  displayed frame renders through `Image(data:)`.
- Unblended images keep the current attachment path and do not pay decode or
  precomposition cost because blend support exists.
- Host transports continue to receive normal image attachments or normal web
  image records; no ordered graphics scene is introduced.

The first tranche deliberately stays cell-background-only. Exact glyph-shaped
backdrop blending, overlapping image-layer semantics, web GIF pass-through
blending, and native canvas/CoreGraphics blend-mode replay remain follow-on
work.

## 2. Current Anchors

Core raster and metadata:

- `swift-tui/Sources/SwiftTUICore/Content/ImageTypes.swift` defines
  `ImagePayload`, `ResolvedImageAsset`, and `RasterImageAttachment`.
- `ResolvedImageAsset` already carries `cellPixelSize`; `RasterImageAttachment`
  does not.
- `swift-tui/Sources/SwiftTUICore/Raster/Rasterizer+Paint.swift` threads
  `activeBlendMode` through cells, but its `.image` branch appends
  `RasterImageAttachment` without blend metadata.
- `paintCompositingGroup` and `compositeLayer` flatten cells but append layer
  image attachments unchanged.
- `swift-tui/Sources/SwiftTUICore/Raster/RasterSurfaceDamageDiff.swift` dirties
  image rows only when attachment equality changes.

Runtime and hosts:

- `swift-tui/Sources/SwiftTUIRuntime/Terminal/ImageAssetRepository.swift`
  resolves and decodes PNG/JPEG into `DecodedImage`.
- `swift-tui/Sources/SwiftTUIRuntime/Terminal/TerminalImageSampling.swift`
  already provides nearest-neighbor `scaledPixels`.
- `TerminalImageRendering.swift`, `TerminalImageKittyRendering.swift`,
  `TerminalImageSixelRendering.swift`, and
  `TerminalImageFallbackRendering.swift` own terminal graphics and fallback
  variants.
- `swift-tui/Platforms/WASI/Sources/WASISurfaceBridge/WebSurfaceImageEncoder.swift`
  reads attachment bytes directly and uses `knownImageIDs`.
- `swift-tui-web/packages/web/src/WebHostSceneRuntime.ts` draws images through
  `drawImage` after cells.
- `swift-tui/Platforms/SwiftUI/Sources/SwiftUIHost/NativeRasterSurfaceRenderer.swift`
  draws attachments from `attachment.source`.

Existing tests to extend:

- Core raster/blend: `swift-tui/Tests/SwiftTUICoreTests/RasterizerTests.swift`
- Damage: `swift-tui/Tests/SwiftTUICoreTests/RasterSurfaceDamageDiffTests.swift`
- Image resolution: `swift-tui/Tests/SwiftTUITests/ImageSurfaceTests.swift`
- Terminal graphics: `swift-tui/Tests/SwiftTUITests/TerminalGraphicsProtocolTests.swift`
- WASI/web frame encoding:
  `swift-tui/Platforms/WASI/Tests/WASISurfaceBridgeTests/WebSurfaceTransportTests.swift`
- Web runtime: `swift-tui-web/packages/web/src/WebHostSceneRuntime.test.ts`
- Animated image:
  `swift-tui/Tests/SwiftTUIAnimatedImageTests/AnimatedImageTests.swift`

## 3. Architecture Decisions

### 3.1 Raster metadata

Add optional compositing metadata to `RasterImageAttachment`, defaulting to
`nil`. Keep existing initializers source-compatible by adding defaulted
arguments.

Recommended shape:

```swift
public struct RasterImageCompositing: Equatable, Sendable {
  public var blendMode: BlendMode
  public var destinationBackdrop: RasterImageBackdrop
  public var sourceBackdrop: RasterImageBackdrop?
  public var cellPixelSize: PixelSize
  public var backdropSignature: UInt64
}

public struct RasterImageBackdrop: Equatable, Sendable {
  public var bounds: CellRect
  public var cells: [RasterImageBackdropCell]
}

public struct RasterImageBackdropCell: Equatable, Sendable {
  public var backgroundColor: Color?
}
```

Names can change. Responsibilities should not:

- `destinationBackdrop` is the parent/current surface behind the image at the
  point the blend operation applies.
- `sourceBackdrop` is optional group-local cell background that must be
  composited under the image before a post-group blend. It is `nil` for direct
  image blend.
- `cellPixelSize` comes from `payload.resolvedAsset?.cellPixelSize`.
- `backdropSignature` is stable across processes and participates in
  attachment equality, raster damage, terminal graphics replay, and compositor
  cache keys.

For tranche 1, backdrop cells store background color only. A nil background is
resolved by the runtime/host compositor using the host's current default
background. The host default background must be part of the compositor cache
key, or the cache must be cleared on render-style changes.

### 3.2 Rasterizer behavior

When rasterizing an image with an active blend mode:

1. Clip to `visibleBounds` as today.
2. Capture `destinationBackdrop` from the current `cells` grid under
   `visibleBounds`.
3. Compute `backdropSignature`.
4. Emit the attachment with `compositing`.

For compositing groups:

- `.blendMode(...).compositingGroup()` keeps image blend inside the isolated
  layer. Capture the layer-local destination backdrop while painting the image
  into the layer.
- `.compositingGroup().blendMode(...)` treats the image as part of the flattened
  group source. When carrying layer image attachments into the destination,
  attach post-group compositing metadata using the parent destination backdrop
  and the layer-local `sourceBackdrop` under the image.
- Do not route group images through host-native blend modes. The group rules are
  represented in metadata and resolved into precomposed variants.

This keeps `SwiftTUICore` IO-free and codec-free.

### 3.3 Runtime image compositor

Add an `ImageBlendCompositor` in `SwiftTUIRuntime` near the decoded-image
support, not inside terminal-protocol-specific code. It should:

- Reuse `ImageAssetRepository` for PNG/JPEG decode.
- Move or expose `TerminalImageSampling.scaledPixels` as runtime image sampling
  shared by terminal and web encoders.
- Expand `RasterImageBackdrop` to RGBA pixels using `cellPixelSize` and the host
  fallback background.
- For direct image blend, blend source pixels over `destinationBackdrop` using
  `Color.composited(over:mode:workingSpace: .linearSRGB)`.
- For post-group blend, first composite image pixels normally over
  `sourceBackdrop`, then blend that flattened source over
  `destinationBackdrop`.
- Preserve fully transparent source pixels as backdrop pixels in the
  precomposed output.
- Return either a `DecodedImage` variant for terminal renderers or encoded PNG
  bytes plus a stable image ID for web-surface encoders.

Cache key fields:

- source reference or embedded bytes identity,
- source crop and output pixel size,
- scaling mode,
- blend mode,
- cell pixel size,
- destination backdrop signature,
- source backdrop signature if present,
- host default background color,
- output consumer kind (`kitty`, `sixel`, fallback mode, `webSurface`,
  `swiftUIHost`),
- animated frame identity, which is naturally part of `.embeddedImage(frameData)`
  for `AnimatedImage`.

### 3.4 Host integration

Terminal:

- `TerminalImageRenderer` asks the compositor for a blended variant when
  `attachment.compositing != nil`.
- Kitty image IDs include the blended variant identity; unblended IDs remain
  source-reference based.
- Sixel and fallback variant keys include the compositing cache identity.
- `TerminalPresentationPlanning` must replay graphics when compositing metadata
  changes even if attachment bounds/source are stable.

WebHost/WASI:

- `WebSurfaceFrameEncoder` should request blended bytes for composited
  attachments and otherwise keep reading the original attachment bytes.
- The emitted image record stays the same shape: `id`, `format`, `bounds`,
  `visibleBounds`, `scalingMode`, `pixelSize`, optional `dataBase64`.
- The blended image ID includes the compositing signature so `knownImageIDs`
  retransmits when only the backdrop changes.
- `swift-tui-web` should not need a protocol change; tests only prove the
  existing `drawImage` path remains sufficient.

SwiftUI host:

- `NativeRasterSurfaceRenderer` should select a blended variant when available.
- Do not use `CGContext` blend modes in this tranche; cells are already drawn
  before images, so native blend modes would use the wrong backdrop ordering in
  later-overlap cases.

## 4. Phased Execution

### Phase 0 - Lock the contract with failing tests

- Add direct image blend metadata tests in `RasterizerTests`.
- Add order tests for image attachments under:
  - `.blendMode(.multiply)` without a group,
  - `.blendMode(.multiply).compositingGroup()`,
  - `.compositingGroup().blendMode(.multiply)`.
- Add damage tests in `RasterSurfaceDamageDiffTests` proving a backdrop-only
  compositing signature change dirties the image visible bounds.
- Add image-surface tests proving unblended image attachments still have
  `compositing == nil`.

Verify focused failure shape:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUICoreTests.RasterizerTests
swiftly run swift test --filter SwiftTUICoreTests.RasterSurfaceDamageDiffTests
swiftly run swift test --filter SwiftTUITests.ImageSurfaceTests
```

### Phase 1 - Add core metadata

- Add `RasterImageCompositing`, `RasterImageBackdrop`, and backdrop-cell types in
  `SwiftTUICore/Content/ImageTypes.swift` or a sibling core content file.
- Extend `RasterImageAttachment` with `compositing: RasterImageCompositing?`.
- Include compositing metadata in `Equatable` by normal stored-property
  equality.
- Update snapshot descriptions in
  `SnapshotRenderer+TreeDescriptions.swift` so debug output exposes whether an
  attachment is blended without dumping full backdrop arrays.
- Update test helpers such as `makeRasterImageAttachment` to keep default
  unblended attachments terse.

Verify:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUICoreTests.RasterizerTests
swiftly run swift test --filter SwiftTUICoreTests.RasterSurfaceDamageDiffTests
```

### Phase 2 - Capture direct-image backdrops in the rasterizer

- In `Rasterizer+Paint.swift`, add a helper that slices visible cell
  backgrounds from `cells` under a `CellRect`.
- Use deterministic hashing for the backdrop signature; do not use Swift's
  randomized `Hasher` for protocol/cache identity.
- In the `.image` command branch, when `blendMode != nil` and
  `payload.resolvedAsset?.cellPixelSize` is available, emit compositing metadata.
- Keep unresolved images and unblended images on the existing nil-compositing
  path.

Verify:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUICoreTests.RasterizerTests
swiftly run swift test --filter SwiftTUITests.ImageSurfaceTests
```

### Phase 3 - Preserve modifier order through compositing groups

- Teach `RasterLayer` or layer image attachment handling to remember the
  layer-local backdrop under image attachments.
- In `compositeLayer`, when effects after the group include a blend mode, attach
  post-group compositing metadata to carried image attachments using the parent
  destination backdrop and the layer-local source backdrop.
- Add guardrail tests where the same image and same parent backdrop produce
  different metadata for blend-before-group vs group-before-blend.
- Keep full overlapping-image support out of scope; add explicit tests that the
  supported cases are image-over-cell-background, not image-over-image.

Verify:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUICoreTests.RasterizerTests
```

### Phase 4 - Wire damage and replay semantics

- Confirm `RasterSurfaceDamageDiff` dirties previous/current visible image bounds
  when compositing metadata changes.
- Update terminal graphics replay planning if equality alone is not enough for
  targeted replay under unchanged bounds.
- Add or extend `TerminalGraphicsProtocolTests` for backdrop-only changes:
  text planning remains incremental, but the blended image attachment replays.

Verify:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUICoreTests.RasterSurfaceDamageDiffTests
swiftly run swift test --filter SwiftTUITests.TerminalGraphicsProtocolTests
```

### Phase 5 - Build the shared runtime compositor

- Refactor decoded-image support so `ImageBlendCompositor` can use
  `ImageAssetRepository` without becoming terminal-protocol-specific.
- Move or widen `scaledPixels` from `TerminalImageSampling.swift` for shared
  runtime use.
- Implement backdrop expansion from cell backgrounds to RGBA pixels.
- Implement direct blend and post-group source-backdrop blend.
- Add tiny RGBA tests for all current `BlendMode` cases:
  `normal`, `multiply`, `screen`, `overlay`, `darken`, `lighten`.
- Add alpha tests for transparent and translucent pixels.
- Add scaled-to-fit/scaled-to-fill crop/scale tests with small PNG fixtures.

Recommended new test file:
`swift-tui/Tests/SwiftTUITests/ImageBlendCompositorTests.swift`.

Verify:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUITests.ImageBlendCompositorTests
swiftly run swift test --filter SwiftTUITests.ImageSurfaceTests
```

### Phase 6 - Route terminal Kitty, Sixel, and fallback

- In `TerminalImageRenderer`, resolve a composited variant before calling Kitty,
  Sixel, or fallback renderers.
- Add compositing identity to `TerminalImageVariantKey`.
- For Kitty, transmit PNG variants as `f=100` when the compositor can encode PNG;
  otherwise use RGBA `f=32` with explicit pixel-size keys.
- For Sixel and fallback, use the composited `DecodedImage` variant before
  quantization or half-block conversion.
- Preserve all existing unblended tests and add one blended test per protocol
  path where practical.

Verify:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUITests.TerminalGraphicsProtocolTests
```

### Phase 7 - Route WebHost and WASI/browser transport

- Extend `WebSurfaceFrameEncoder.encodeImages` to accept or reach a compositing
  provider for blended bytes.
- Preserve direct byte reading for unblended attachments and GIF pass-through.
- For blended attachments, emit PNG or another explicit supported byte format
  with an ID derived from blended content/backdrop identity.
- Add `WebSurfaceTransportTests` proving:
  - unblended image IDs/data behavior is unchanged,
  - blended image data has a distinct ID from the source,
  - `knownImageIDs` retransmits when only backdrop signature changes.
- Add or update `WebHostSceneRuntime.test.ts` to prove no new row format or
  canvas blend mode is required.

Verify:

```bash
cd swift-tui
swiftly run swift test --filter WASISurfaceBridgeTests.WebSurfaceTransportTests

cd ../swift-tui-web
bun test packages/web/src/WebHostSceneRuntime.test.ts
bun test packages/web/src/WebHostSurfaceTransport.test.ts
```

### Phase 8 - Route SwiftUI host

- Add a narrow blended-variant resolver for
  `NativeRasterSurfaceRenderer.drawImageAttachment`.
- Keep fallback behavior for unblended images unchanged.
- Add `SwiftUIHostTests` coverage for choosing a blended variant when
  compositing metadata exists. Avoid visual pixel snapshots unless the current
  harness can make them stable.

Verify on macOS:

```bash
cd swift-tui
swiftly run swift test --filter SwiftUIHostTests.HostedSurfaceRegressionTests
```

### Phase 9 - Animated image coverage

- Extend `AnimatedImageTests` with a blended frame case:
  - each displayed frame yields a compositing-aware attachment/variant,
  - reduced motion still renders the first frame with compositing metadata.
- Do not add public `AnimatedImage` API; the behavior flows through
  `Image(data:)`.

Verify:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUIAnimatedImageTests.AnimatedImageTests
```

### Phase 10 - Documentation, public API, and gates

- Update current render-pipeline docs:
  - `swift-tui/docs/RENDER-PIPELINE.md`
  - `swift-tui/Sources/SwiftTUICore/SwiftTUICore.docc/Rendering-Pipeline.md`
  - `swift-tui/Sources/SwiftTUIRuntime/SwiftTUIRuntime.docc/Runtime-Render-Pipeline.md`
- Update authoring docs where blend modes are described:
  `swift-tui/Sources/SwiftTUIViews/SwiftTUIViews.docc/Authoring-Views.md`.
- Update host docs for terminal, WebHost/WASI, and SwiftUI host behavior where
  image rendering is documented.
- Regenerate and classify public API changes:
  `swift-tui/Scripts/generate_public_api_inventory.sh` and
  `swift-tui/docs/public_api_overrides.yml`.
- Run policy scripts touched by public core/runtime additions.

Focused verification:

```bash
cd swift-tui
./Scripts/check_foundation_free_layers.sh
./Scripts/check_concurrency_safety_policies.sh
./Scripts/check_public_surface_policies.sh
./Scripts/generate_public_api_inventory.sh --check
```

Final child gates:

```bash
cd swift-tui
sh ./Scripts/test_gate.sh

cd ../swift-tui-web
bun run test
bun run build:packages
```

After child commits are pushed, return to the coordination root, update the
submodule pins, then run:

```bash
cd /Users/adamz/Developer/swift-tui-org
mise exec -- bazel fetch //:org_full
mise exec -- bazel test //:org_fast
```

## 5. Risk Register

- **Backdrop fidelity:** tranche 1 blends against cell backgrounds only.
  Document this clearly and avoid tests that imply glyph antialiasing support.
- **Modifier-order correctness:** group-before-blend requires source and
  destination backdrops. Do not collapse it to direct-image blend.
- **Damage soundness:** compositing metadata must affect attachment equality and
  replay identity, or stale blended variants will survive backdrop changes.
- **Cache growth:** animated images over changing backgrounds can generate many
  variants. Add occupancy metrics or bounded cache eviction before shipping if
  compositor caches are process-lived.
- **Host default background drift:** nil cell backgrounds depend on host render
  style. Include the host default background in keys or clear caches on style
  changes.
- **Web GIF confusion:** unblended GIF byte pass-through can remain, but blended
  GIF pass-through is out of scope unless the compositor gains real GIF decode.
- **Public API drift:** `RasterImageAttachment` is public. Keep new initializer
  fields defaulted, document new public symbols, and update the public API
  baseline deliberately.

## 6. Completion Criteria

- Unblended image attachments and existing image tests remain behaviorally
  unchanged.
- Blended PNG/JPEG `Image` attachments produce compositing metadata, blended
  variants, and damage/replay invalidation when their backdrop changes.
- Terminal Kitty/Sixel/fallback, WebHost/WASI, SwiftUI host, and
  `AnimatedImage` have focused coverage.
- Public docs state the first-tranche cell-background limitation and do not
  claim full ordered pixel compositing.
- `swift-tui` and `swift-tui-web` child gates pass, and the coordination root
  records clean child pins with `//:org_fast` green.
