# Image Blend Mode Proposal

Status: proposal, re-audited against current `HEAD` on 2026-06-06. The
first-tranche implementation, cache-hardening follow-on, glyph-aware backdrop
follow-on, and ordered presentation-layer follow-on landed in the `swift-tui`
working tree by 2026-06-08; this proposal remains as design context and scope
record.
Implementation plan:
[`docs/plans/2026-06-06-001-image-blend-mode-implementation-plan.md`](../plans/2026-06-06-001-image-blend-mode-implementation-plan.md).
Completed follow-on tranches:
[`cache hardening`](../plans/2026-06-06-002-image-blend-mode-cache-hardening-plan.md),
[`glyph-aware backdrops`](../plans/2026-06-06-003-image-blend-mode-glyph-backdrop-plan.md),
and [`ordered layers`](../plans/2026-06-06-004-image-blend-mode-ordered-layer-plan.md).
Remaining implementation tranches:
[`GIF blending`](../plans/2026-06-06-005-image-blend-mode-gif-blending-plan.md),
and [`native host replay`](../plans/2026-06-06-006-image-blend-mode-native-host-replay-plan.md).

## Summary

Before the first implementation, SwiftTUI treated blend modes as terminal-cell
compositing and treated images as host presentation attachments. The two
systems shared the same resolve -> measure -> place -> draw -> raster pipeline,
but image pixels were not blended by `View.blendMode(_:)`.

This proposal scopes the work required for `Image(...).blendMode(...)` and
`AnimatedImage(...).blendMode(...)` to affect image pixels while preserving the
current image attachment path for unblended images.

## 2026-06-06 Currency Audit

This audit was the pre-implementation check. Its direction is still the shipped
first tranche: unblended images still travel as host image attachments, and
blended images are precomposed as host-specific image variants instead of
introducing a full ordered graphics scene.

At the time of the audit, the stale parts were narrower:

- `ResolvedImageAsset` carried `cellPixelSize`, but
  `RasterImageAttachment` carried only `pixelSize`. The implementation copied
  the resolved `cellPixelSize` onto the attachment and the compositing payload.
- `ImageAssetRepository` already decodes PNG and JPEG into `DecodedImage` with
  RGBA pixels. A compositor can reuse those decoded pixels instead of inventing
  a parallel decoder, but the repository was located in the runtime
  terminal cluster and should not become terminal-protocol-specific.
- WebHost and WASI/browser now share `WebSurfaceFrameEncoder` and the
  TypeScript `swift-tui-web` runtime. Before the first tranche, the encoder read
  attachment bytes directly and tracked `knownImageIDs`; blended images now use
  the shared compositor while unblended images keep direct byte pass-through.
- The web surface transport advertises `png`, `jpeg`, and `gif` byte formats.
  Core/runtime still do not decode GIF through the normal `Image` resolution
  path; GIF pass-through is a web transport behavior, while animated playback
  remains owned by `SwiftTUIAnimatedImage`.
- Damage and graphics replay already depend on image attachment equality and
  visible-bounds dirty-row intersections. Blended image metadata must therefore
  participate in attachment equality and in host replay decisions, not just in
  compositor cache keys.

## Behavior After Completed Tranches

- `View.blendMode(_:)` and `View.compositingGroup()` lower into ordered draw
  effects. The rasterizer applies those effects when writing terminal cells.
- `Image` resolves to an image draw payload. Rasterization records that payload
  as a `RasterImageAttachment` instead of writing pixels into the cell grid.
- Images under an active blend mode carry `RasterImageCompositing` metadata with
  the visible cell-background backdrop. The runtime uses that metadata to
  precompose a blended image variant.
- Terminal, WebHost, WASI/browser, and SwiftUI host presentation still draw
  cells first, then draw unblended image attachments or blended image variants
  on top. WebHost and WASI/browser share the web-surface frame encoder and the
  `swift-tui-web` canvas runtime.
- `SwiftTUIAnimatedImage` feeds each pre-composed frame through `Image(data:)`,
  so it inherits the same attachment behavior.
- Terminal image presentation resolves PNG/JPEG through `ImageAssetRepository`
  and cached render variants. Web-surface encoding still passes through
  unblended image bytes directly, while blended images are emitted as cached PNG
  variants keyed separately from the source asset.
- The blended-image compositor stores decoded and encoded blended variants in a
  bounded LRU cache per compositor instance, keyed by compact source
  fingerprints rather than retained embedded source bytes. Package-scoped policy
  injection, occupancy snapshots, and memory metrics cover entries, decoded
  pixels, encoded bytes, retained metadata bytes, hits, misses, access
  generation, and evictions.
- `RasterSurface` carries a package-scoped ordered presentation-layer sidecar
  that records compact cell fragments and image attachments in raster paint
  order. Existing hosts still consume the collapsed cell grid plus
  `imageAttachments`, but package tests and future host replay work can inspect
  image-over-image and cell/image authoring order without replacing the stable
  host boundary.
- Presentation damage now includes ordered-layer topology changes as dirty row
  signals, while ordinary text/content diffs still use the final collapsed cell
  grid and image attachment equality.

The shipped behavior is deliberate: terminal graphics protocols and browser or
native hosts can display high-fidelity images without forcing every image
through a cell fallback. Blended variants remain deterministic approximations:
they blend image pixels against captured cell backgrounds plus explicit
foreground glyph coverage for block, braille, and ordinary text. Exact terminal
font masks, host-native ordered replay, and GIF pass-through byte blending
remain future work.

## Desired Contract

The target behavior should be SwiftUI-shaped but terminal-honest:

- Applying `.blendMode(mode)` to an `Image` blends the source image pixels with
  the visual backdrop at the image's visible bounds.
- Modifier order remains significant. `.blendMode(.multiply).compositingGroup()`
  blends inside the isolated group, while
  `.compositingGroup().blendMode(.multiply)` blends the flattened group against
  the parent backdrop.
- `AnimatedImage` needs no special public API. Each displayed frame should use
  the same image blending path as `Image(data:)`.
- Unblended images should keep the current native attachment path and should not
  pay a decode/precomposition cost solely because blend support exists.
- SwiftTUI should not claim arbitrary pixel-composition support. The terminal
  backend can approximate glyph-shaped backdrops because the framework does not
  own the user's terminal font rasterization.

## Non-Goals

- A general Skia, Metal, or CoreGraphics scene graph.
- Pixel-precise layout outside an image's own pixels and terminal cell bounds.
- Cross-host raw GIF decoding in the root `SwiftTUI` image surface. GIF
  playback remains owned by `SwiftTUIAnimatedImage`, which already produces PNG
  frame bytes. The web-surface transport may still pass through GIF bytes when
  an attachment can provide them, but that is not the blend-mode contract.
- A public replacement for `Image`, `AnimatedImage`, or `blendMode(_:)`.

## Design Options

### Option 1: Force Blended Images Through Cell Fallback

When an image has an active blend mode, decode it to the existing half-block or
ASCII fallback overlay and run those cells through the current cell writer.

This is small, but it discards the main reason image attachments exist: high
fidelity graphics in Kitty, Sixel, WebHost, WASI/browser, and SwiftUI host
surfaces. It also makes blended images visibly lower quality than unblended
images. This should only be kept as a terminal fallback behavior.

### Option 2: Add an Ordered Graphics Scene Above RasterSurface

Move presentation from "final cell grid plus image attachments" to an ordered
layer list that can replay cells and images in authoring order. Web and SwiftUI
hosts could use native blend modes, and terminal hosts could interleave text and
graphics writes more faithfully.

This is the most complete model, but it is also a new presentation seam. It
would touch `RasterSurface`, terminal presentation planning, WebHost transport,
WASI transport, the shared `WebSurfaceFrameEncoder`, the `swift-tui-web` canvas
runtime, SwiftUI host drawing, snapshots, damage, and public-surface baselines.
It should be reserved for a broader graphics-native rendering tranche, not the
first image-blend implementation.

### Option 3: Precompose Blended Image Variants

Keep `RasterSurface` as the host boundary, but record enough compositing
metadata on image attachments for the runtime or host to create a blended image
variant. The variant is produced by decoding the source image, sampling the
captured backdrop for the image's visible bounds, applying `Color.composited`
with the active `BlendMode`, and presenting the resulting image through the
normal attachment path.

This is the recommended first implementation. It preserves high-fidelity image
presentation, keeps unblended images fast, and confines image decoding to the
runtime/host side rather than pulling image codecs into `SwiftTUICore`.

## Proposed Architecture

### Core Raster Model

Add an image compositing payload, for example:

```swift
public struct RasterImageCompositing: Equatable, Sendable {
  public var blendMode: BlendMode
  public var backdrop: RasterCellBackdrop
  public var cellPixelSize: PixelSize
  public var backdropSignature: UInt64
}
```

The exact type names can change, but the responsibilities should not:

- `BlendMode` records the image's active blend mode at the point the image draw
  command is encountered.
- The backdrop captures the cells under `visibleBounds` before the image is
  appended.
- `cellPixelSize` lets the compositor expand the backdrop into the same pixel
  coordinate space as the scaled image. The implementation copies this value
  from `ResolvedImageAsset` into both the emitted attachment and the compositing
  payload.
- `backdropSignature` or equivalent stable identity participates in attachment
  equality, raster damage, host replay, and compositor cache keys.

`RasterImageAttachment` should gain an optional compositing field with a default
of `nil`. That keeps existing attachments and public initializers source
compatible. Its equality must include the compositing payload so backdrop-only
changes invalidate damage and host image replay.

### Rasterizer Changes

The rasterizer already threads `activeBlendMode` through the draw tree. The
image command branch should stop ignoring it. When `activeBlendMode` is non-nil,
the rasterizer should:

1. Clip the image bounds to `visibleBounds` as it does today.
2. Capture a cell backdrop slice from the current `cells` grid.
3. Derive a stable backdrop signature from that slice.
4. Attach `RasterImageCompositing` to the emitted `RasterImageAttachment`.

Compositing groups need a second pass. Today `paintCompositingGroup` carries
image attachments out of the isolated layer unblended. The new behavior should
either:

- precompose blended images while flattening the group layer, or
- preserve the group-local backdrop and defer precomposition until the runtime
  has the image bytes.

The second path fits the current layering better because `SwiftTUICore` should
remain terminal-IO-free and codec-free.

### Runtime Image Compositor

Add an `ImageBlendCompositor` beside the decoded-image support in
`SwiftTUIRuntime`. It should:

- Reuse `ImageAssetRepository`'s PNG/JPEG `DecodedImage` path where available.
- Expose a narrow provider API so WebHost/WASI encoding can request blended
  bytes without duplicating byte loading, decode, scale, or cache logic.
- Scale and crop pixels using the same rules as the existing terminal and
  web-surface image renderers.
- Expand the captured cell backdrop to RGBA pixels.
- Apply the active `BlendMode` with the existing `Color.composited` math in
  linear sRGB.
- Return a new embedded image reference, decoded image variant, or encoded byte
  payload with a content ID that can flow through existing host transports.

The cache key must include:

- source image reference or embedded bytes identity,
- source crop and output pixel size,
- blend mode,
- cell pixel size,
- backdrop style/content signature,
- scaling mode,
- frame identity for animated images,
- output container/consumer kind when the result needs encoded bytes rather
  than only decoded pixels.

### Host Integration

Terminal graphics:

- Kitty and Sixel should transmit the blended variant when an attachment has
  image compositing metadata.
- Transparent source pixels need a defined rule. For the first tranche, fully
  transparent pixels should leave the captured backdrop unchanged in the
  precomposed output.
- Damage planning must replay graphics when either the source image changes or
  a dirty cell intersects the captured backdrop under a blended image.

Terminal fallback:

- The fallback overlay can keep using cells, but it should be generated from
  the blended variant so graphics and fallback agree.

WebHost and WASI/browser:

- `WebSurfaceFrameEncoder` can send blended image bytes as the normal image
  payload with a normal `id`, `format`, `bounds`, `visibleBounds`,
  `scalingMode`, `pixelSize`, and `dataBase64` record. The image ID must include
  the blended payload identity/backdrop signature so `knownImageIDs` retransmits
  when needed.
- The shared `swift-tui-web` canvas runtime can continue drawing images through
  its existing `drawImage` path. This avoids requiring JavaScript
  `globalCompositeOperation` to reproduce the same order.
- A future ordered-layer transport could switch WebHost to native canvas blend
  modes, but that is not required for this proposal.

SwiftUI host:

- The native host should draw the blended variant when present.
- Host-native `CGContext` blend modes should wait for an ordered-layer model;
  drawing all cells first and then relying on native blend would blend against
  the wrong backdrop when later cells overlap the image bounds.

## Testing Plan

Core tests:

- `RasterizerTests` should assert that image attachments preserve bounds and
  also carry compositing metadata when an active blend mode exists.
- Existing blend-mode and compositing-group order tests should gain image cases
  that prove order is preserved at the metadata/backdrop level.
- Damage tests should prove that backdrop-only changes under a blended image
  change attachment equality and dirty the blended image's visible bounds.

Runtime tests:

- Unit-test the image compositor with tiny RGBA fixtures for every `BlendMode`.
- Verify alpha behavior for transparent and translucent image pixels.
- Verify cache invalidation when only the backdrop color changes.
- Verify scaled-to-fit and scaled-to-fill source cropping.

Host tests:

- Terminal graphics tests should assert that blended attachments transmit a
  distinct image ID or payload from the unblended source.
- Terminal fallback tests should assert that the half-block overlay matches the
  blended colors.
- WASI transport tests should assert that blended image bytes are emitted only
  when needed, have a distinct `id`, and are retransmitted when the backdrop
  signature changes despite `knownImageIDs`.
- WebHost canvas tests should verify that blended images draw through the same
  image path and do not require a new row format.
- SwiftUI host tests should cover source selection for blended variants, with
  visual snapshot testing deferred unless the host test harness already supports
  stable image comparisons.
- `SwiftTUIAnimatedImageTests` should assert that each frame can produce its own
  blended reference and that reduced-motion still renders the first blended
  frame.

## Work Breakdown

1. Define the behavioral contract in docs and tests.
2. Extend the raster model with optional image compositing metadata.
3. Capture backdrop cells when rasterizing image draw commands under an active
   blend mode.
4. Include the compositing payload in attachment equality, raster damage, and
   host graphics replay decisions.
5. Implement the runtime image compositor and cache keys.
6. Route terminal Kitty, Sixel, and fallback renderers through blended variants.
7. Route `WebSurfaceFrameEncoder`, WebHost, and WASI/browser transport through
   blended variants while preserving the existing web image record shape.
8. Route SwiftUI host drawing through blended variants.
9. Add animated-image coverage.
10. Update the current render-pipeline docs (`swift-tui/docs/RENDER-PIPELINE.md`,
    `SwiftTUICore.docc/Rendering-Pipeline.md`, and
    `SwiftTUIRuntime.docc/Runtime-Render-Pipeline.md`), public API inventory,
    and host documentation once behavior ships.
11. Run the affected child native gate plus the web package tests before
    considering the implementation complete.

## Risks

- **Backdrop fidelity.** Terminal hosts cannot know exact glyph antialiasing
  from the user's terminal font. The implementation should document whether
  glyph foregrounds are approximated as solid cell coverage or whether the
  first tranche blends only against cell backgrounds.
- **Damage soundness.** A blended image depends on the cells behind it. Any
  damage inside that backdrop must invalidate the blended variant and replay
  graphics.
- **Cache growth.** Animated images over changing backgrounds can produce many
  blended variants. The runtime needs bounded storage or a frame-generation
  eviction policy.
- **Host divergence.** Native canvas/CoreGraphics blend modes may be tempting,
  but using them without ordered layers would blend against content that was
  painted later in authoring order.
- **Public API drift.** Adding fields to `RasterImageAttachment` is feasible,
  but it still affects the public inventory and must be handled deliberately.

## Recommended First Tranche

Start with the precomposed-variant path for PNG/JPEG-backed images over
cell-background backdrops. That tranche should prove the API behavior for
`Image(...).blendMode(...)`, preserve current unblended rendering, and expose
the damage/cache shape before taking on overlapping image layers, web GIF
pass-through blending, or exact glyph-shaped backdrop blending.
