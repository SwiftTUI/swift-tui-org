# Image Blend Mode Ordered Layer Plan

**Date:** 2026-06-06
**Status:** Follow-on implementation plan after cache hardening and glyph-aware
backdrops.
**Target repos:** implementation primarily in `swift-tui`, with
`swift-tui-web` changes only if the web transport protocol changes. Root owns
this plan and final pin updates.

## 1. Goal

Introduce an ordered presentation model for raster output so image blend modes
can account for overlapping image layers and authoring order rather than only
cell backdrops captured before an image.

This is the tranche that unlocks:

- image-over-image blending semantics;
- cells that are authored after an image no longer being treated as if they were
  behind the image;
- future native canvas/CoreGraphics blend-mode replay on hosts that can support
  ordered layers.

The goal is a narrow ordered layer model, not a general Skia/Metal scene graph.

## 2. Preconditions

- Cache hardening is complete.
- Glyph-aware backdrop work is complete or deliberately deferred.
- First-tranche precomposed variants remain the fallback path for terminal
  hosts and simple host transports.

## 3. Current Anchors

Relevant `swift-tui` files:

- `Sources/SwiftTUICore/Raster/RasterSurface.swift`
  - current host boundary is final cells plus image attachments.
- `Sources/SwiftTUICore/Raster/Rasterizer+Paint.swift`
  - writes cells immediately and appends image attachments.
- `Sources/SwiftTUICore/Raster/RasterSurfaceDamageDiff.swift`
  - computes host-facing dirty rows against final cells and image attachments.
- `Sources/SwiftTUIRuntime/Terminal/TerminalHost+PresentationEmission.swift`
  - currently emits text cells and graphics as separate presentation steps.
- `Platforms/WASI/Sources/WASISurfaceBridge/WebSurfaceFrameEncoder.swift`
  - serializes final rows plus image records.
- `swift-tui-web/packages/web/src/WebHostSceneRuntime.ts`
  - draws text rows and then image records.
- `Platforms/SwiftUI/Sources/SwiftUIHost/NativeRasterSurfaceRenderer.swift`
  - draws final cells and then image attachments.

## 4. Design

### 4.1 Ordered Presentation Layers

Add a package/core model that records ordered paint layers after rasterization:

```swift
public struct RasterPresentationLayer: Equatable, Sendable {
  public var order: Int
  public var bounds: CellRect
  public var content: RasterPresentationLayerContent
  public var effects: [DrawEffect]
}

public enum RasterPresentationLayerContent: Equatable, Sendable {
  case cells(RasterSurfaceFragment)
  case image(RasterImageAttachment)
}
```

Exact public/private shape is open. If possible, keep this package/internal in
the first ordered-layer tranche. Only expose public API if host integration
requires it.

### 4.2 Compatibility Boundary

Keep `RasterSurface.cells` and `RasterSurface.imageAttachments` intact as the
compatibility surface. Add ordered layers as an optional sidecar:

- existing terminal/WebHost/SwiftUI paths can keep consuming final cells/images;
- new tests and experimental host paths can consume ordered layers;
- first-tranche blended variants continue to work when ordered layers are absent.

### 4.3 Rasterizer Changes

Instead of appending all image attachments into one final list, record paint
events in order:

- cell runs/fragments written by fills, text, borders, canvas, and fallback
  graphics;
- image attachments with their draw-order position;
- group boundaries/effects needed for later native replay.

The final cell grid remains the collapsed result for compatibility.

### 4.4 Damage Model

Add a topology signature for ordered layers:

- layer count;
- layer content kind;
- bounds;
- effect signatures;
- image compositing signature.

Damage should still expose row/range damage for existing hosts, but ordered-layer
consumers need enough signal to repaint layers when order/topology changes even
if final cell text is stable.

### 4.5 Host Strategy

This tranche should first prove the ordered layer model without switching every
host to native blending.

Recommended sequence:

1. Add sidecar layers and snapshot/debug inspection.
2. Keep terminal and web output unchanged.
3. Add one experimental renderer path behind package/test hooks.
4. Only after correctness tests pass, let later host-specific tranches consume
   the ordered layers.

## 5. Phased Execution

### Phase 0 - Characterization Tests

- Add current-behavior tests for overlapping cells/images that document the
  first-tranche limitation.
- Add snapshot/tree-description expectations for paint order.
- Add damage tests for layer topology changes that currently collapse to the
  same final cells.

Focused commands:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUICoreTests.RasterizerTests
swiftly run swift test --filter SwiftTUICoreTests.RasterSurfaceDamageDiffTests
```

### Phase 1 - Layer Sidecar Model

- Add ordered layer types.
- Add `RasterSurface.presentationLayers` or equivalent sidecar with a default
  empty/compatibility value.
- Keep existing initializers source-compatible.
- Update public API baseline only if the sidecar is public.

### Phase 2 - Rasterizer Recording

- Record ordered cell fragments and image attachments during paint.
- Preserve final collapsed cells and existing image attachments.
- Include compositing group boundaries/effects only to the extent needed for
  image-blend semantics; avoid modeling unrelated scene-graph concepts.

### Phase 3 - Snapshot and Damage Semantics

- Add compact ordered-layer descriptions for debugging.
- Add topology signatures to damage comparison.
- Ensure final-cell-only hosts still receive valid dirty rows.

### Phase 4 - Experimental Consumer

- Add a package/test-only ordered replay consumer that can compare ordered layer
  replay against final collapsed surfaces for non-overlap cases.
- Use this as the oracle before changing production host renderers.

### Phase 5 - Docs and Gates

- Update render-pipeline DocC to describe the sidecar and compatibility model.
- Keep public authoring docs conservative until host-native replay ships.

Verification:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUICoreTests.RasterizerTests --jobs 4
swiftly run swift test --filter SwiftTUICoreTests.RasterSurfaceDamageDiffTests --jobs 4
swiftly run swift test --filter SwiftTUITests.TerminalGraphicsProtocolTests --jobs 4
swiftly run swift test --jobs 4
./Scripts/generate_public_api_inventory.sh --check

cd /Users/adamz/Developer/swift-tui-org
mise exec -- bazel test //:org_fast
```

## 6. Non-Goals

- Switching WebHost/SwiftUI to native blend modes in this tranche.
- Pixel-perfect text glyph masks.
- GIF decode or GIF blending.
- Replacing `RasterSurface` as the stable host boundary in one step.

## 7. Completion Criteria

- Ordered paint events are available as a sidecar without breaking existing
  hosts.
- Image/cell/image overlap cases have explicit order tests.
- Layer topology changes participate in damage or replay decisions.
- Existing final-surface output remains behaviorally compatible.

