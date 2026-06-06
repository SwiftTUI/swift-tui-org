# Image Blend Mode Cache Hardening Plan

**Date:** 2026-06-06
**Status:** Implemented in the `swift-tui` working tree on 2026-06-06 after the
first-tranche image blend-mode precomposition work.
**Target repos:** implementation lives in the `swift-tui` submodule. The
coordination root owns this plan and any final submodule pin update.

## Implementation Result

Implemented in `swift-tui`:

- package-scoped `ImageBlendCompositorCachePolicy` defaults and test injection;
- one unified blended-variant cache entry map shared by decoded and encoded
  callers, keyed by compact source fingerprints instead of retaining embedded
  source bytes;
- deterministic LRU eviction bounded by entry count, decoded-pixel count, and
  encoded PNG plus retained metadata bytes, while retaining the current
  request's oversize entry;
- encoded-only callers no longer retain decoded blended pixels solely to emit
  PNG payload bytes;
- package-scoped cache occupancy snapshots plus per-compositor
  `ImageBlendCompositor.variants` memory metrics, including retained metadata
  bytes and access generation that advances on hits and insertions;
- focused compositor coverage for cache hits, eviction, encoded/decoded entry
  sharing, embedded-source compaction, oversize entries, memory metrics, and
  frame-like source/backdrop churn;
- host eviction coverage for terminal Kitty replay under an injected tiny
  compositor policy and WASI/WebHost encoding under the default process-level
  policy, plus SwiftUI host and animated-image regression suites.

## 1. Goal

Harden the first image blend-mode implementation so blended image variants are
safe for long-running and animated sessions:

- bound process-lived blended image caches;
- expose cache occupancy through existing lightweight memory metrics;
- keep terminal, WASI/WebHost, and SwiftUI host behavior identical while
  reducing duplicate storage;
- add stress coverage for changing backdrops and animated frames.

This tranche deliberately does not expand image-blend fidelity. Exact
glyph-shaped backdrop blending, overlapping image-layer semantics,
cross-host GIF blending, and host-native canvas/CoreGraphics blend modes remain
separate future work.

## 2. Why This Is Next

The first tranche proved the user-visible contract:

- direct `Image(...).blendMode(...)` metadata is captured in the rasterizer;
- post-`compositingGroup()` ordering is represented with source and destination
  backdrops;
- terminal graphics, web transport, and SwiftUI host paths all draw blended
  variants through their normal image routes;
- backdrop-only changes dirty and replay affected image rows.

The remaining risk with the highest shipping leverage is cache growth. The
current compositor stores decoded and encoded blended variants in process-lived
dictionaries. That is acceptable for narrow static cases, but animated images
over changing backgrounds can generate many unique keys. Before adding more
blend fidelity, the compositor should have clear memory behavior and tests that
prove variant churn is bounded.

## 3. Current Anchors

Relevant files in `swift-tui`:

- `Sources/SwiftTUIRuntime/Terminal/ImageBlendCompositor.swift`
  - owns `decodedVariants` and `encodedPayloads` dictionaries;
  - keys variants by source, bounds, visible bounds, output size, scaling mode,
    blend mode, cell pixel size, backdrop signature, and host fallback
    background;
  - currently has no occupancy metrics, byte accounting, or eviction.
- `Sources/SwiftTUIRuntime/Terminal/TerminalImageRendering.swift`
  - keeps an `ImageBlendCompositor` per `TerminalImageRenderer`.
- `Platforms/WASI/Sources/WASISurfaceBridge/WebSurfaceImageEncoder.swift`
  - uses a process-level compositor for web-surface blended PNG payloads.
- `Platforms/SwiftUI/Sources/SwiftUIHost/NativeRasterSurfaceRenderer.swift`
  - uses a static compositor for native host blended PNG payloads.
- `Sources/SwiftTUIProfiling/Memory/ProfiledMemoryAccess.swift` and existing
  cache metric registrations provide the local pattern for memory reporting.
- `Tests/SwiftTUITests/ImageBlendCompositorTests.swift` is the right home for
  compositor cache behavior tests.
- `Tests/SwiftTUIAnimatedImageTests/AnimatedImageTests.swift` should cover
  animated-frame churn after the compositor cache has a bounded policy.

## 4. Design

### 4.1 Cache Policy

Add an internal or package-scoped cache policy type. Keep it out of the public
authoring API.

Recommended shape:

```swift
package struct ImageBlendCompositorCachePolicy: Sendable, Equatable {
  package var maxEntries: Int
  package var maxDecodedPixels: Int
  package var maxEncodedBytes: Int
}
```

Default values should be conservative and host-independent. The exact numbers
should come from small calculations, but the defaults should cover normal
terminal images while preventing runaway animated/background churn. Tests can
inject a tiny policy.

### 4.2 Unified Cache Entry

Replace the two independent dictionaries with one entry map keyed by
`ImageBlendCacheKey`.

Each entry should store:

- stable blended ID;
- pixel size;
- encoded PNG bytes;
- decoded pixels when a terminal path requested them;
- approximate decoded-pixel byte cost;
- encoded byte cost;
- last-access generation.

The current `encodedPayloads` cache duplicates data that already exists inside
`DecodedImage.encodedBytes` when a decoded variant was requested first. A unified
entry lets the compositor serve both terminal and encoded payload paths without
double-retaining the same PNG bytes.

### 4.3 Eviction

Use deterministic least-recently-used eviction inside the existing lock:

1. Increment an access generation for every cache hit or insertion.
2. Update the entry's last-access generation.
3. After insertion, evict oldest entries until all policy limits are satisfied.
4. Treat one entry as non-evictable only during the current request; if a single
   entry exceeds the byte limit, keep that entry and evict all others.

Eviction must be per-compositor instance. Do not introduce global shared mutable
state between terminal, web, and SwiftUI host paths.

### 4.4 Metrics

Register a memory metric provider for each compositor instance. The metric
payload should include:

- entry count;
- decoded-pixel bytes;
- encoded bytes;
- total approximate bytes;
- access generation;
- eviction count;
- hit and miss counts for decoded and encoded requests.

The metric provider should not expose source image bytes, paths, or image IDs.
It should be safe for diagnostics output.

### 4.5 Host Integration

Terminal:

- Preserve the current per-renderer compositor.
- No change to Kitty/Sixel/fallback image output.
- Add tests proving a small policy evicts old blended variants while still
  retransmitting the right ID when a backdrop changes.

WASI/WebHost:

- Preserve the process-level compositor if it has a bounded policy and metrics.
- Verify `knownImageIDs` behavior still works when the compositor evicts a
  variant: if the web image ID is already known, the encoder may omit
  `dataBase64`; if the ID changes because the backdrop changes, it must send the
  new data.

SwiftUI host:

- Preserve the static compositor.
- Verify native host rendering still obtains a fresh payload after eviction.

### 4.6 Animated Images

Add coverage for the risk case: an animated image over changing backgrounds.
The expected contract is:

- each displayed frame can still produce a distinct blended variant when source
  bytes or backdrop signatures differ;
- cache occupancy remains bounded under an injected tiny policy;
- reduced-motion first-frame behavior still uses the same compositing path.

Do not add public `AnimatedImage` API.

## 5. Phased Execution

### Phase 0 - Baseline and Failing Tests

- Add compositor cache tests with an injectable tiny policy:
  - repeated identical request hits the cache;
  - more unique backdrop signatures than `maxEntries` evict old entries;
  - encoded and decoded requests for the same key share one cache entry;
  - oversize single entry is retained while older entries are evicted.
- Add a metrics test that observes non-zero occupancy and eviction count through
  the same metric path used by other runtime caches.
- Add an animated-image stress test that intentionally fails until cache bounds
  exist.

Focused commands:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUITests.ImageBlendCompositorTests
swiftly run swift test --filter SwiftTUIAnimatedImageTests.AnimatedImageTests
```

### Phase 1 - Policy and Unified Storage

- Add `ImageBlendCompositorCachePolicy` with default and test-only tiny
  policies.
- Replace separate decoded/encoded dictionaries with a unified entry map.
- Keep the current public/package methods:
  - `decodedVariant(for:outputSize:fallbackBackground:)`
  - `encodedPNGPayload(for:fallbackBackground:)`
- Ensure encoded-only callers do not force decoded-pixel retention when it is not
  needed after PNG generation.

Focused command:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUITests.ImageBlendCompositorTests
```

### Phase 2 - LRU Eviction and Accounting

- Add byte accounting for encoded PNG bytes and decoded RGBA pixels.
- Add access-generation updates on hit and insertion.
- Evict under lock after each insertion.
- Track eviction counters separately for entry, decoded-byte, and encoded-byte
  pressure if that remains simple; otherwise one total eviction counter is
  enough for this tranche.

Focused command:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUITests.ImageBlendCompositorTests
```

### Phase 3 - Metrics

- Register a `MemoryMetricProvider` for each compositor instance.
- Keep metric names stable and scoped to the compositor.
- Add tests that read metrics without depending on exact production defaults.
- Confirm metric collection does not retain the compositor after host teardown.

Focused commands:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUITests.ImageBlendCompositorTests
swiftly run swift test --filter SwiftTUITests.MemoryMetricCollectorTests
```

### Phase 4 - Host Regression Coverage

- Terminal: add/extend a `TerminalGraphicsProtocolTests` case where variants
  churn under a small policy and replay still uses the correct blended ID.
- WASI/WebHost: extend `WebSurfaceTransportTests` so eviction does not break
  `knownImageIDs` or changed-backdrop retransmission.
- SwiftUI host: add a narrow native host test, if the existing harness can
  inspect the compositor decision without unstable pixel snapshots.

Focused commands:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUITests.TerminalGraphicsProtocolTests
swiftly run swift test --filter WASISurfaceBridgeTests.WebSurfaceTransportTests
swiftly run swift test --filter SwiftUIHostTests
```

### Phase 5 - Animated Churn Coverage

- Add an animated blended-frame test with distinct frame bytes and changing
  backdrops.
- Add reduced-motion coverage if the current test harness can force the policy
  branch deterministically.
- Assert bounded cache occupancy through metrics or a package-only snapshot
  accessor, not by timing or memory RSS.

Focused command:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUIAnimatedImageTests.AnimatedImageTests
```

### Phase 6 - Docs and Gates

- Update current DocC render-pipeline docs only if API behavior or diagnostics
  surface changes.
- Do not update the public API baseline unless the implementation accidentally
  exposes new public symbols; this tranche should remain package/internal.

Final verification:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUITests.ImageBlendCompositorTests --jobs 4
swiftly run swift test --filter SwiftTUITests.TerminalGraphicsProtocolTests --jobs 4
swiftly run swift test --filter WASISurfaceBridgeTests.WebSurfaceTransportTests --jobs 4
swiftly run swift test --filter SwiftUIHostTests --jobs 4
swiftly run swift test --filter SwiftTUIAnimatedImageTests.AnimatedImageTests --jobs 4
swiftly run swift test --jobs 4
./Scripts/check_concurrency_safety_policies.sh
./Scripts/check_public_surface_policies.sh
./Scripts/generate_public_api_inventory.sh --check

cd /Users/adamz/Developer/swift-tui-org
mise exec -- bazel test //:org_fast
```

## 6. Non-Goals

- Glyph-shaped or antialiased text backdrop blending.
- Ordered image-over-image or arbitrary layer compositing.
- Cross-host raw GIF decode or blended GIF pass-through.
- Native canvas/CoreGraphics blend-mode replay.
- Public authoring API changes.
- Root-level Bazel replacement for child native tests.

## 7. Completion Criteria

- Blended image cache entry count and approximate bytes are bounded by policy.
- Repeated identical requests hit one cache entry for decoded and encoded
  callers.
- Eviction does not break terminal replay IDs, web `knownImageIDs`, or SwiftUI
  payload generation.
- Animated-frame and changing-backdrop churn stays bounded in tests.
- Memory metrics expose occupancy and eviction without leaking image-sensitive
  data.
- Public API baseline remains clean, or any intentional public drift is
  classified and regenerated.
- `swift-tui` is committed first, then the coordination root records the new
  submodule pin with `//:org_fast` green.
