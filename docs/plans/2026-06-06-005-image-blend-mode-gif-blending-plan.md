# Image Blend Mode GIF Blending Plan

**Date:** 2026-06-06
**Status:** Implemented in `swift-tui` on 2026-06-08 for explicit
`AnimatedImage` frame blending and raw-GIF pass-through semantics. Direct raw
GIF frame decoding remains intentionally unsupported because the current package
graph keeps `SwiftTUIRuntime` below `SwiftTUIAnimatedImage`.
**Target repos:** implementation lives mostly in `swift-tui`; `swift-tui-web`
changes are needed only if the web protocol changes. Root owns this plan and
final pin updates.

Implementation summary:

- `Tests/SwiftTUIAnimatedImageTests/AnimatedImageTests.swift` now asserts that
  `AnimatedImage(...).blendMode(...)` attaches compositing metadata to the
  current PNG-backed frame, advances distinct GIF-decoded frames with blend
  metadata, and still renders the first blended frame under reduced motion
  without registering a playback task.
- `Platforms/WASI/Tests/WASISurfaceBridgeTests/WebSurfaceTransportTests.swift`
  now locks raw GIF byte behavior: unblended GIF records still pass through as
  `format: "gif"`, and a GIF attachment carrying blend metadata still passes
  through unchanged when no runtime GIF frame decoder exists.
- `SwiftTUIAnimatedImage` and `SwiftTUIViews` DocC now distinguish animated GIF
  frame blending from direct raw-GIF container pass-through.
- No `swift-tui-web` protocol change was needed.

## 1. Goal

Support blended animated GIF content consistently across terminal, WASI/WebHost,
and SwiftUI host paths without changing the public `Image` or `AnimatedImage`
authoring API.

This tranche should make the behavior clear for two cases:

- `AnimatedImage` GIF playback, which already produces per-frame PNG data and
  should continue to inherit `Image(data:)` blending;
- direct GIF byte pass-through on web surfaces, which currently remains
  unblended unless converted into frames.

## 2. Preconditions

- Cache hardening is complete so animated frame churn is bounded.
- The first-tranche PNG/JPEG precomposition path remains stable.
- The team agrees whether direct `Image(data: gifBytes).blendMode(...)` should
  decode frames or fall back to documented unsupported/pass-through behavior.

## 3. Current Anchors

Relevant `swift-tui` files:

- `Sources/SwiftTUIAnimatedImage/AnimatedImage.swift`
  - feeds displayed frames through `Image(data:)`.
- `Sources/SwiftTUIAnimatedImage/AnimatedGIF.swift`
  - owns GIF decode for the animated-image product.
- `Platforms/WASI/Sources/WASISurfaceBridge/WebSurfaceImageEncoder.swift`
  - passes through GIF bytes for web image records.
- `Sources/SwiftTUIRuntime/Terminal/ImageAssetRepository.swift`
  - decodes PNG/JPEG for runtime image presentation, not GIF.
- `Sources/SwiftTUIRuntime/Terminal/ImageBlendCompositor.swift`
  - can precompose decoded `DecodedImage` pixels once a frame exists.
- Tests:
  - `Tests/SwiftTUIAnimatedImageTests/AnimatedImageTests.swift`
  - `Platforms/WASI/Tests/WASISurfaceBridgeTests/WebSurfaceTransportTests.swift`
  - `Tests/SwiftTUITests/ImageBlendCompositorTests.swift`

## 4. Design

### 4.1 Separate Frame Playback From Byte Pass-Through

Keep two contracts:

- `AnimatedImage` playback blends each rendered frame through the normal
  `Image(data:)` path.
- Raw GIF byte pass-through is only blendable if the runtime has decoded the
  selected frame into pixels.

Do not try to apply a single static blend to a GIF container byte stream.

### 4.2 Shared Frame Decode Provider

Introduce a narrow frame provider that can return decoded frames without making
`ImageAssetRepository` responsible for all animation timing:

```swift
package protocol AnimatedImageFrameDecoding {
  func decodedFrames(for reference: ImageAssetReference) -> [DecodedImage]?
}
```

The exact shape can change. The key constraint is layering: `SwiftTUIRuntime`
should not grow a hard dependency on the public animated-image product unless
the package graph already allows it. If the graph does not allow this cleanly,
keep direct raw GIF blending out of scope and focus this tranche on
`AnimatedImage` coverage and docs.

### 4.3 Web Surface Behavior

For web transport:

- unblended GIF pass-through can continue as today;
- blended GIF should either:
  - emit precomposed per-frame PNG records driven by runtime animation, or
  - explicitly decline to blend direct GIF bytes and document the behavior.

Avoid adding JavaScript `globalCompositeOperation` for GIF containers; it would
not match terminal or SwiftUI host semantics.

### 4.4 Cache Keys

Frame identity must be part of the blended variant key:

- `AnimatedImage` already embeds frame PNG bytes, so source identity changes per
  frame;
- direct GIF frame decode needs frame index plus source identity plus frame
  delay/disposal generation where relevant.

## 5. Phased Execution

### Phase 0 - Contract Decision and Tests

Status: complete.

- Add tests documenting current `AnimatedImage(...).blendMode(...)` behavior.
- Add explicit tests for raw GIF byte pass-through under blend mode.
- Decided to document direct raw GIF frame decode as unsupported for direct
  `Image(data:)`. Implementing it in this tranche would require moving or
  sharing GIF decode across package layers that are intentionally separate.

Focused commands:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUIAnimatedImageTests.AnimatedImageTests
swiftly run swift test --filter WASISurfaceBridgeTests.WebSurfaceTransportTests
```

### Phase 1 - AnimatedImage Frame Coverage

Status: complete.

- Add blended multi-frame tests with distinct frame bytes.
- Add reduced-motion tests proving the first frame carries compositing metadata
  and produces a blended variant.
- Assert cache occupancy remains bounded if the cache-hardening tranche exposed
  metrics. Existing cache-hardening tests cover bounded compositor storage; this
  tranche adds frame-identity coverage through distinct embedded PNG frame
  references.

### Phase 2 - Optional Raw GIF Decode Bridge

Status: closed as intentionally unsupported in this tranche.

Only do this if the package graph supports it cleanly:

- expose a narrow GIF frame decode provider to the runtime compositor;
- decode the active GIF frame into `DecodedImage`;
- preserve disposal and transparency semantics;
- emit precomposed PNG variants for blended frames.

If the graph does not support it, write the explicit non-support docs and stop
after Phase 1.

### Phase 3 - Web Transport Semantics

Status: complete for the documented non-support path.

- For implemented raw GIF blending, make `WebSurfaceFrameEncoder` emit blended
  PNG frame payloads instead of GIF bytes.
- For documented non-support, assert blended direct GIF pass-through stays
  unmodified and logs or diagnostics do not claim it is blended.
- Preserve unblended GIF pass-through and `knownImageIDs` behavior.

### Phase 4 - Host Regression Tests

Status: complete for this tranche's chosen contract.

- Terminal graphics/fallback and SwiftUI host still consume animated frames as
  ordinary PNG-backed `Image(data:)` attachments, so they inherit the existing
  blended image variant path and terminal graphics tests.
- WASI/WebHost tests now prove unblended GIF remains pass-through and direct
  raw GIF with blend metadata does not emit a misleading blended PNG.

### Phase 5 - Docs and Gates

Status: complete after the verification listed below.

- Update authoring docs to distinguish `AnimatedImage` frame blending from raw
  GIF pass-through.
- Update proposal docs if raw GIF blending remains intentionally unsupported.

Verification:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUIAnimatedImageTests.AnimatedImageTests --jobs 4
swiftly run swift test --filter WASISurfaceBridgeTests.WebSurfaceTransportTests --jobs 4
swiftly run swift test --filter SwiftTUITests.TerminalGraphicsProtocolTests --jobs 4
swiftly run swift test --jobs 4

cd /Users/adamz/Developer/swift-tui-org
mise exec -- bazel test //:org_fast
```

## 6. Non-Goals

- JavaScript-only GIF blending through canvas composite operations.
- A new public `AnimatedImage` API.
- Replacing the existing `SwiftTUIAnimatedImage` decoder unless the package
  graph requires a narrow shared extraction.
- Ordered image-over-image semantics.

## 7. Completion Criteria

- `AnimatedImage(...).blendMode(...)` has explicit multi-frame and
  reduced-motion tests.
- Raw GIF byte behavior under blend mode is either implemented via frame decode
  or documented as unsupported with tests locking that contract.
- Unblended GIF pass-through behavior remains unchanged.
- Animated variant churn remains bounded by the cache policy.
