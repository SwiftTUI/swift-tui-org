# Image Blend Mode Native Host Replay Plan

**Date:** 2026-06-06
**Status:** Follow-on implementation plan after ordered layer sidecar work.
**Target repos:** `swift-tui` plus `swift-tui-web` if browser runtime changes
are required. Root owns this plan and final pin updates.

## 1. Goal

Let capable native hosts replay blend modes with their own graphics APIs once
SwiftTUI has an ordered layer model.

Target host capabilities:

- WebHost/WASI browser canvas can use `globalCompositeOperation` where it
  matches SwiftTUI `BlendMode`;
- SwiftUI/AppKit/UIKit host can use `CGContext` blend modes where ordering is
  correct;
- terminal hosts can keep using precomposed variants or fallback cells.

This tranche is an optimization/fidelity path, not a replacement for
precomposed variants.

## 2. Preconditions

- Ordered presentation layers exist and preserve authoring order.
- First-tranche precomposition remains available as a compatibility fallback.
- Host output can distinguish layer paint order from final collapsed cells.

## 3. Current Anchors

Relevant files:

- `swift-tui/Sources/SwiftTUIRuntime/Terminal/ImageBlendCompositor.swift`
  - fallback precomposition path.
- `swift-tui/Platforms/WASI/Sources/WASISurfaceBridge/WebSurfaceFrameEncoder.swift`
  - current row/image JSON encoder.
- `swift-tui-web/packages/web/src/WebHostSceneRuntime.ts`
  - current canvas renderer draws text rows before images.
- `swift-tui/Platforms/SwiftUI/Sources/SwiftUIHost/NativeRasterSurfaceRenderer.swift`
  - current native renderer draws cells before images.
- Ordered-layer sidecar from
  `2026-06-06-004-image-blend-mode-ordered-layer-plan.md`.

## 4. Design

### 4.1 Capability-Gated Native Replay

Native replay must be opt-in per host and per blend mode:

- if a host cannot exactly represent a `BlendMode`, use precomposition;
- if layer topology contains unsupported content, use precomposition or the
  existing final-surface path;
- terminal hosts default to precomposition.

### 4.2 WebHost/WASI Protocol

Add a versioned ordered-layer record only if the existing image record shape
cannot express the needed order.

Possible shape:

```json
{
  "version": 3,
  "layers": [
    { "kind": "cells", "bounds": [0,0,10,2], "rows": [...] },
    { "kind": "image", "id": "...", "blendMode": "multiply", "bounds": [...] }
  ]
}
```

Keep the existing v1/v2 row/image format for hosts that do not opt into ordered
layers.

### 4.3 Browser Canvas Mapping

Map SwiftTUI blend modes to canvas operations:

- `normal` -> `source-over`
- `multiply` -> `multiply`
- `screen` -> `screen`
- `overlay` -> `overlay`
- `darken` -> `darken`
- `lighten` -> `lighten`

When the browser cannot support an operation reliably, fall back to
precomposition.

### 4.4 SwiftUI/CoreGraphics Mapping

Map SwiftTUI blend modes to `CGBlendMode` where available. Use ordered layers so
the native blend sees the same backdrop that the authored order expects.

Never apply `CGContext` blend modes to the old final-cells-then-images path; it
would blend against the wrong backdrop.

### 4.5 Pixel Parity Oracle

Add small deterministic fixtures:

- same source/backdrop rendered through precomposition and native replay;
- compare pixels within an agreed tolerance for WebHost and SwiftUI host;
- document differences where native APIs use subtly different color spaces.

## 5. Phased Execution

### Phase 0 - Capability and Parity Tests

- Add mapping tests for SwiftTUI blend modes to canvas/CG blend modes.
- Add small pixel fixtures comparing precomposed output to native replay.
- Add fallback tests for unsupported blend modes or layer content.

### Phase 1 - WebHost Ordered Replay

- Add versioned ordered-layer frame support if needed.
- Update `swift-tui-web` runtime to draw ordered cell/image layers.
- Use canvas native blend only for supported image layers.
- Preserve existing row/image frame support.

Commands:

```bash
cd swift-tui
swiftly run swift test --filter WASISurfaceBridgeTests.WebSurfaceTransportTests

cd ../swift-tui-web
bun test packages/web/src/WebHostSceneRuntime.test.ts
bun test packages/web/src/WebHostSurfaceTransport.test.ts
```

### Phase 2 - SwiftUI Host Ordered Replay

- Teach native host renderer to consume ordered layers.
- Use CoreGraphics blend modes only under ordered replay.
- Fall back to precomposed variants when layer content is unsupported.
- Add host tests that inspect draw path selection and stable pixel fixtures if
  available.

Command:

```bash
cd swift-tui
swiftly run swift test --filter SwiftUIHostTests
```

### Phase 3 - Terminal Compatibility

- Keep terminal precomposition as the default.
- Add tests proving ordered-layer metadata does not regress Kitty/Sixel/fallback
  output.

Command:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUITests.TerminalGraphicsProtocolTests
```

### Phase 4 - Docs and Gates

- Update host-integration docs to explain native replay vs precomposition.
- Update web protocol docs if a new frame version ships.
- Keep public authoring docs focused on `blendMode`; host implementation
  details belong in runtime/host docs.

Verification:

```bash
cd swift-tui
swiftly run swift test --jobs 4
./Scripts/generate_public_api_inventory.sh --check

cd ../swift-tui-web
bun test
bun run build:packages

cd /Users/adamz/Developer/swift-tui-org
mise exec -- bazel test //:org_fast
```

## 6. Non-Goals

- New public blend-mode API.
- Native replay for terminal protocols.
- Removing precomposed variants.
- Implementing a general retained GPU scene graph.

## 7. Completion Criteria

- WebHost and SwiftUI host can use native blend modes only when ordered layer
  replay makes the backdrop correct.
- Unsupported host/layer cases fall back to precomposition.
- Pixel fixtures prove parity or document tolerances.
- Existing terminal output remains unchanged.

