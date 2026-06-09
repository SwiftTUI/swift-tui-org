# Android Host View And Gallery Demo Plan

**Date:** 2026-06-09
**Status:** Implementation underway. Phases 0-2 are complete locally, the
Android Gallery Gradle/Compose app assembles with system Gradle, and runtime
device verification is blocked on no attached Android device and no configured
AVD.
**Target repos:** `swift-tui`, `swift-tui-examples`, and this coordination
root for gates, pins, and plan tracking. Root owns this plan and final pin
updates.

## 1. Goal

Add explicit Android support that is real enough to consume from a native
Android app, not only a command-line cross-compile smoke test.

The target user experience is an Android view that works like the current
SwiftUI embedding view:

- a host app can embed a SwiftTUI app inside native UI;
- the SwiftTUI runtime remains the source of truth for layout, state, focus,
  input, accessibility semantics, raster output, and preferred content size;
- the Android host view participates in Compose measurement instead of always
  filling the available space;
- the Android host can publish resize information back into SwiftTUI so
  authored layouts can adapt to host constraints;
- the examples repo includes a runnable Android gallery demo equivalent in
  purpose to the SwiftUI example gallery host.

## 2. Current Evidence

### 2.1 Existing host-managed embedding model

`swift-tui/Platforms/SwiftUI/Sources/SwiftUIHost` is the closest precedent.
The core split is:

- `SwiftUIHostAppView` - public SwiftUI entry point that starts/stops the
  hosted app and forwards SwiftUI measurement into the native surface.
- `SwiftUIHostAppState` - owns `SceneManifest` discovery and one
  `SwiftUIHostSceneHost` per scene.
- `SwiftUIHostSceneHost` - owns a `HostedSceneSession`, receives
  `SemanticHostFrame` values, stores the latest raster, preferred layout size,
  semantic snapshot, focused identity, damage, and keyboard/focus state.
- `NativeSceneBridge` - sends resize and input back to the hosted session and
  updates `HostedRasterSurface` capabilities.
- `NativeTerminalSurfaceView` - AppKit/UIKit view that draws the raster,
  translates native input, and negotiates size with SwiftUI.
- `HostedAccessibilityOverlay` and related files - map the semantic snapshot
  into native accessibility nodes instead of exposing the raster as one opaque
  image.

The Android implementation should reuse the same runtime concepts, but it
cannot reuse the Apple renderer or native view code because those depend on
SwiftUI, UIKit/AppKit, CoreGraphics, and platform font APIs.

### 2.2 Host-frame contract

`SemanticHostFrame` is already the right cross-host contract. It carries:

- monotonic `sequence`;
- committed `RasterSurface`;
- `SemanticSnapshot`;
- `focusedIdentity`;
- `PresentationDamage`;
- `preferredLayoutSize`, described in code as the measured window content size
  before the host raster minimum is applied.

`HostedRasterSurface` already accepts the full semantic frame and reports
native-host capabilities including cell pixel size and pointer input
capabilities. Android should integrate at this layer rather than reaching into
the renderer.

### 2.3 Size negotiation precedent

`NativeTerminalSurfaceSizeNegotiator` currently lives inside the SwiftUI host.
It combines:

- measured cell size in pixels;
- preferred grid size from `SemanticHostFrame.preferredLayoutSize`;
- latest rendered grid size;
- fallback grid size of `80x24`;
- confirmed slack when a preferred layout is smaller than the rendered capacity;
- proposed host dimensions from `sizeThatFits`.

That algorithm is platform-neutral except for `CGSize`/`CGFloat`. It should be
extracted into `SwiftTUIRuntime` so SwiftUI and Android use the same tested
rules.

### 2.4 Current Android surface

The framework already contains many Android-specific imports and POSIX shims:
`canImport(Android)` branches exist in `SwiftTUICore`, `SwiftTUIRuntime`,
`SwiftTUIProfiling`, CLI support, terminal I/O, and vendored `UnixSignals`.

`swift-tui/docs/HOSTS-AND-PLATFORMS.md` already says `aarch64` Android
cross-compilation works and that `x86_64` is blocked by vendored `swift-png`
SIMD. That document points at a missing `swift-tui/VISION-GAP.md`, so explicit
Android support needs a doc cleanup in the child repo once the real build
results are known.

### 2.5 Current local toolchain state

Initial local probing showed:

- host Swift: `swiftly run swift --version` reports Swift 6.3.1;
- installed Android SDK bundle: `swift-6.3-RELEASE_android`;
- targeted Android build currently fails before repo code because the Android
  SDK Swift module was compiled with Swift 6.3 and the active compiler is
  Swift 6.3.1;
- `java` is not installed on the shell `PATH`;
- Android Studio's bundled JBR is available at
  `/Applications/Android Studio.app/Contents/jbr/Contents/Home`;
- Android SDK tools are available under `~/Library/Android/sdk`;
- the Swift Android artifact bundle includes NDK r27d under
  `~/Library/org.swift.swiftpm/swift-sdks/swift-6.3-RELEASE_android.artifactbundle/swift-android/android-ndk-r27d`;
- `ANDROID_HOME`, `ANDROID_SDK_ROOT`, and `ANDROID_NDK_HOME` are not exported by
  the shell.

The first implementation step must align the Swift toolchain and Android SDK
versions before drawing conclusions about SwiftTUI compile failures.

Validation update on 2026-06-09:

- Installed Swift 6.3.0 with `swiftly install 6.3.0 --assume-yes` without
  making it the default toolchain.
- Verified `swiftly run swift --version +6.3.0` selects
  `Apple Swift version 6.3 (swift-6.3-RELEASE)`.
- Verified Android Studio JBR, Gradle, adb, and the bundled NDK clang are
  callable through explicit paths/env.
- Ran:

  ```bash
  DISABLE_EXPLICIT_PLATFORMS=1 \
  ANDROID_NDK_HOME="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3-RELEASE_android.artifactbundle/swift-android/android-ndk-r27d" \
    swiftly run swift build +6.3.0 \
      --package-path swift-tui \
      --swift-sdk aarch64-unknown-linux-android28 \
      --target SwiftTUIRuntime
  ```

- Result: the build reaches repo code and fails in
  `swift-tui/Vendor/swift-figlet/Sources/SwiftFiglet/SwiftFiglet.swift`
  because the file imports Darwin/Glibc but not Android, so POSIX symbols such
  as `access`, `F_OK`, `opendir`, `closedir`, `readdir`, `fopen`, `fclose`,
  `fseek`, `SEEK_END`, `ftell`, `rewind`, `fread`, and `getenv` are missing.

Implementation update on 2026-06-09:

- Fixed the trivial Android compile blockers in vendored `SwiftFiglet`, core
  math/color/raster imports, spring solver imports, debug stderr gates, and
  Android-incompatible `LinkOpening` process spawning.
- Extracted the SwiftUI host size negotiator into `SwiftTUIRuntime` as
  `HostedSurfaceSizeNegotiator`, with runtime tests and SwiftUI host adapter
  coverage.
- Added `SwiftTUIAndroidHost` with an opaque-handle C ABI, Android scene host,
  frame encoder, resize bridge, byte input bridge, and tests.
- Verified `SwiftTUIRuntime`, `SwiftTUIAndroidHost`, `GalleryDemoViews`, and
  the gallery shim cross-compile for `aarch64-unknown-linux-android28`.
- Added `swift-tui-examples/AndroidGallery`, including a Swift gallery shim,
  Gradle wrapper, Compose host view, Kotlin frame parser/state wrapper, Android
  Canvas text renderer, and `ndk-build` JNI bridge.
- Verified `gradle :app:assembleDebug` with explicit local `JAVA_HOME`,
  `ANDROID_HOME`, and `ANDROID_NDK_HOME`. The APK includes
  `libGalleryAndroidHost.so`, `libswift_tui_jni.so`, and the required Swift
  runtime `.so` files under `lib/arm64-v8a/`.
- `./gradlew :app:assembleDebug` is currently blocked by repeated
  `services.gradle.org` Gradle distribution download timeouts before Gradle
  starts. The wrapper files are present with a 60 second timeout and retries.
- Runtime smoke testing is blocked because `adb devices -l` returns no attached
  devices and `emulator -list-avds` returns no configured AVDs.

### 2.6 Gallery anchor

`swift-tui-examples/gallery` already exposes `GalleryDemoViews` as a library.
That target depends on `SwiftTUIRuntime`, `SwiftTUIAnimatedImage`, and
`SwiftTUICharts`, not the terminal/WebHost convenience product.

The full `GalleryView` covers the right Android host surface area:

- state and tab selection;
- buttons and forms;
- text input and keyboard focus;
- scroll views;
- pointer-heavy tabs;
- presentations/popovers/palette sheet;
- static PNG/JPEG data;
- animated GIF decoding through `SwiftTUIAnimatedImage`;
- accessibility-relevant semantic structure.

`FileDropTab` can remain visible in the Android demo, but actual platform file
drop should be a later Android-specific capability unless the initial host can
provide Android content URI routing cleanly.

## 3. Design Constraints

- Keep planning/proposal/design docs in this root repo only.
- Keep public child repos consumable through their native package managers.
- Do not make `swift-tui` require Android Studio, Gradle, or Bazel for default
  SwiftPM builds.
- Do not make Android consumers import the `SwiftTUI` convenience product for
  the first host. Start from host-compatible products.
- Start with `arm64-v8a` / `aarch64-unknown-linux-android28`. Treat `x86_64`
  emulator support as a follow-up until the `swift-png` SIMD gap is resolved.
- Prefer a narrow manually-owned JNI/C ABI for the first production path.
  `swift-java` can become a code-generation helper later, but the host should
  not require generated bindings before the lifecycle, frame, and measurement
  contracts are proven.
- The Compose view must be a raster/semantic host for SwiftTUI, not a native
  reimplementation of every SwiftTUI control as Compose widgets.

## 4. Desired End State

### 4.1 Android public API shape

Initial Kotlin API in the Android gallery app:

```kotlin
@Composable
fun SwiftTUIHostView(
    state: SwiftTUIHostState,
    modifier: Modifier = Modifier,
    style: SwiftTUIAndroidStyle = SwiftTUIAndroidStyle.Default
)
```

Gallery app usage:

```kotlin
@Composable
fun GalleryScreen() {
    val state = rememberSwiftTUIHostState {
        GalleryAndroidHost.create()
    }

    SwiftTUIHostView(
        state = state,
        modifier = Modifier.fillMaxSize()
    )
}
```

The first implementation can keep `GalleryAndroidHost.create()` app-specific.
After the JNI lifecycle is stable, add a reusable API for apps that provide
their own generated or handwritten Swift host factory.

### 4.2 Swift public API shape

New `swift-tui` product:

```swift
.library(name: "SwiftTUIAndroidHost", targets: ["SwiftTUIAndroidHost"])
```

Initial Swift-side responsibilities:

- create and own hosted scene sessions;
- expose lifecycle, resize, style, input, clipboard, and frame polling/callback
  through a stable C/JNI ABI;
- encode `SemanticHostFrame` into a host-frame DTO that Kotlin can render;
- expose app-specific factories for the gallery demo through a small shim
  target in `swift-tui-examples`.

### 4.3 Repository placement

`swift-tui`:

- `Platforms/Android/Sources/SwiftTUIAndroidHost/`
- `Platforms/Android/Tests/SwiftTUIAndroidHostTests/`

`swift-tui-examples`:

- `AndroidGallery/` Gradle project;
- `AndroidGallery/SwiftPackage/` or `AndroidGallery/Swift/` package shim that
  depends on `GalleryDemoViews` and `SwiftTUIAndroidHost`;
- `AndroidGallery/app/src/main/java/...` or `.../kotlin/...` for Compose host
  UI;
- `AndroidGallery/app/src/main/jniLibs/arm64-v8a/` generated by Gradle, not
  committed.

Coordination root:

- Bazel/native gate target that invokes the examples Android gate only when
  the Android toolchain is available;
- root pin updates after child commits land.

Do not create a new `swift-tui-android` child repo in the first tranche. A
separate AAR/repo can be introduced after the host API and packaging story stop
moving.

## 5. Architecture

### 5.1 Shared size negotiation

Extract the SwiftUI host negotiator into a runtime-owned, platform-neutral
type, for example:

```swift
public struct HostedSurfaceSizeNegotiator {
  public var cellSize: PixelLengthSize
  public var preferredGridSize: CellSize?
  public var renderedGridSize: CellSize?
  public var fallbackGridSize: CellSize
  public var confirmedSlack: HostedSurfaceConfirmedSlack

  public func negotiate(
    proposedWidth: Double?,
    proposedHeight: Double?
  ) -> HostedSurfaceSizeNegotiation
}
```

Then keep thin platform adapters:

- SwiftUI converts `ProposedViewSize` and `CGSize`;
- Android converts Compose `Constraints` and density-scaled cell metrics.

This keeps the most fragile behavior, preferred-size negotiation under host
constraints, under shared Swift tests.

### 5.2 Android scene host

Add `AndroidHostSceneHost` in `SwiftTUIAndroidHost` with the same conceptual
state as `SwiftUIHostSceneHost`:

- descriptor / scene id;
- running state and last error;
- latest frame sequence;
- latest encoded frame;
- latest preferred layout size;
- latest focus presentation;
- latest surface size and cell pixel size;
- one `NativeSceneBridge` equivalent for Android.

The Android bridge should be platform-neutral Swift where possible:

- `HostedSceneSession` owns the SwiftTUI runtime;
- `HostedRasterSurface` receives `SemanticHostFrame`;
- resize updates the hosted surface size and pointer capabilities;
- input events are sent back as `InputEvent`;
- clipboard writes call a Kotlin-provided callback through JNI.

### 5.3 JNI boundary

Use a small versioned C ABI exposed with `@_cdecl` functions and wrapped by
Kotlin. Initial functions:

```swift
@_cdecl("swift_tui_android_create_gallery_host")
func swift_tui_android_create_gallery_host() -> Int64

@_cdecl("swift_tui_android_start")
func swift_tui_android_start(_ handle: Int64)

@_cdecl("swift_tui_android_stop")
func swift_tui_android_stop(_ handle: Int64)

@_cdecl("swift_tui_android_destroy")
func swift_tui_android_destroy(_ handle: Int64)

@_cdecl("swift_tui_android_resize")
func swift_tui_android_resize(
  _ handle: Int64,
  _ columns: Int32,
  _ rows: Int32,
  _ cellPixelWidth: Double,
  _ cellPixelHeight: Double
)

@_cdecl("swift_tui_android_send_input")
func swift_tui_android_send_input(
  _ handle: Int64,
  _ bytes: UnsafePointer<UInt8>,
  _ count: Int32
)

@_cdecl("swift_tui_android_copy_latest_frame")
func swift_tui_android_copy_latest_frame(
  _ handle: Int64,
  _ outBuffer: UnsafeMutablePointer<UInt8>?,
  _ capacity: Int32
) -> Int32
```

Kotlin owns:

- loading the `.so`;
- handle lifetime;
- polling or callback dispatch into Compose state;
- mapping Android events into the input DTO;
- freeing copied native buffers if the final ABI uses native allocation.

Prefer copying frame bytes into a Kotlin `ByteArray` first. It is simple,
debuggable, and avoids holding Swift memory across JNI boundaries. Optimize
only after the gallery animation tabs identify frame-copy overhead as a real
problem.

### 5.4 Frame snapshot protocol

Define a versioned Android host-frame DTO in Swift and Kotlin. Start with a
binary `ByteArray` schema, or JSON if speed of implementation is more important
than animation performance for the first milestone. Either way, the schema must
be versioned from day one.

Required fields:

- schema version;
- frame sequence;
- grid width and height;
- preferred grid width and height;
- raster rows/cells;
- style runs with foreground/background colors and text attributes;
- image attachment records with stable ids, bounds, pixel size, and image bytes
  only when the image is first seen or changed;
- presentation damage;
- accessibility nodes with identity, label/value/hint/traits, and cell bounds;
- focused identity;
- accessibility announcements;
- focus presentation, including whether text input should be shown.

Kotlin should cache decoded bitmaps by attachment id. Swift should keep the
attachment id stable across frames when the same image asset is reused.

### 5.5 Compose measurement and resize

`SwiftTUIHostView` should use a custom `Layout` or a composable with explicit
measure policy:

1. Measure current cell metrics from the configured monospaced font and density.
2. Convert Compose `Constraints` to proposed pixel width/height. Unbounded
   constraints become `nil`.
3. Invoke the shared size negotiation logic, either:
   - in Kotlin using a port kept parity-tested against Swift, or
   - through the Swift host via JNI.
4. Return the negotiated pixel size to Compose.
5. Publish the resulting grid and cell pixel size back to SwiftTUI.
6. On the first constrained measure before any frame exists, publish the probe
   grid so SwiftTUI can render under the actual host constraints instead of
   waiting for a second pass.

Acceptance cases:

- `Modifier.fillMaxSize()` fills the parent and resizes SwiftTUI to the
  available cell capacity.
- `Modifier.wrapContentSize()` uses `preferredLayoutSize` once known and `80x24`
  before the first frame.
- Finite width with unbounded height clamps columns and keeps preferred height
  where possible.
- Recomposition does not resize the SwiftTUI runtime unless grid size or cell
  metrics changed.

### 5.6 Android renderer

Implement rendering in Kotlin/Compose using Android Canvas APIs:

- draw cell backgrounds;
- draw text glyphs with the same embedded monospaced font family where
  possible;
- draw underline/strikethrough/bold/italic from cell style flags;
- draw box/braille/block characters as text first, then add custom paths only
  if Android font coverage creates visible defects;
- draw image attachments from cached `Bitmap` values;
- consume damage in the Kotlin state/cache layer, even if Compose redraws the
  whole canvas on each `onDraw`;
- keep a renderer snapshot test corpus that can run as JVM/Robolectric tests
  where practical.

The first renderer should optimize for correctness and simple debug output.
After the gallery is usable, profile animation tabs and decide whether a
retained bitmap backing store is needed.

### 5.7 Input, focus, and keyboard

Map Android input to SwiftTUI `InputEvent`:

- pointer down/up/move/drag with cell and sub-cell coordinates;
- scroll wheel / touchpad scroll where Android exposes it;
- hardware key events to key input;
- IME committed text to text input or paste input;
- modifier keys from Android key events;
- focus gained/lost into host focus state.

The soft keyboard policy should mirror the SwiftUI host:

- show keyboard when `FocusPresentation.prefersTextInput` is true;
- allow a manual keyboard toggle when focus exists but does not require text
  input;
- hide keyboard when focus presentation becomes `.none`.

### 5.8 Accessibility

Do not expose the SwiftTUI host as a single canvas-only node. Add a transparent
Compose semantics overlay that maps `SemanticSnapshot` nodes to Android
accessibility semantics:

- label/value/hint/role/traits;
- cell bounds converted to Compose pixel bounds;
- focus identity routed to Android accessibility focus when practical;
- announcements routed through Android accessibility APIs;
- hidden/decorative nodes omitted.

Initial instrumentation should assert that a known gallery tab produces
multiple semantics nodes with expected labels and bounds.

### 5.9 Clipboard, links, and file input

Initial support:

- read/write clipboard through Android `ClipboardManager`;
- link opening through Android intents from Kotlin;
- no terminal PTY/process embedding;
- no drag-and-drop file paths in the first tranche.

Follow-up support:

- Android content URI import for `FileDropTab`;
- share sheet/export routing;
- Android permissions strategy if any future feature needs it.

### 5.10 Android gallery app

The demo app should be a real Android project in `swift-tui-examples`, not a
loose script:

- Gradle wrapper committed;
- one Compose `app` module;
- app-specific Swift package/shim that creates `GalleryView()`;
- Gradle task builds the Swift `.so` for `arm64-v8a`;
- Gradle copies the `.so` and required native runtime libraries into
  `app/src/main/jniLibs/arm64-v8a/`;
- first screen is the live gallery host, not a landing page;
- optional native top bar can expose host diagnostics only in debug builds.

## 6. Files To Create Or Modify

### `swift-tui`

- Modify `Package.swift`
  - add `SwiftTUIAndroidHost` product and target;
  - ensure Android-compatible products can build without the Apple
    `SwiftUIHost` target;
  - consider replacing host-OS-only `includeSwiftUIHost` with an explicit
    environment gate if SwiftPM manifest evaluation continues to include Apple
    targets during Android cross-compilation from macOS.
- Add `Sources/SwiftTUIRuntime/Scenes/HostedSurfaceSizeNegotiator.swift`
  - extracted platform-neutral size negotiator.
- Modify `Platforms/SwiftUI/Sources/SwiftUIHost/NativeTerminalSurfaceView.swift`
  - replace local negotiator with runtime negotiator adapter.
- Add `Platforms/Android/Sources/SwiftTUIAndroidHost/AndroidHostSceneHost.swift`
  - hosted scene lifecycle and latest-frame state.
- Add `Platforms/Android/Sources/SwiftTUIAndroidHost/AndroidSceneBridge.swift`
  - resize/input/session bridge.
- Add `Platforms/Android/Sources/SwiftTUIAndroidHost/AndroidHostFrameEncoder.swift`
  - versioned DTO encoding.
- Add `Platforms/Android/Sources/SwiftTUIAndroidHost/AndroidHostABI.swift`
  - narrow C/JNI ABI.
- Add `Platforms/Android/Tests/SwiftTUIAndroidHostTests/`
  - host lifecycle, frame encoding, size negotiation, and input DTO tests.
- Update `docs/HOSTS-AND-PLATFORMS.md`
  - describe Android as explicit host support once implemented.
- Add or restore `VISION-GAP.md` if Android limitations remain documented
  there from child docs.

### `swift-tui-examples`

- Add `AndroidGallery/settings.gradle.kts`.
- Add `AndroidGallery/build.gradle.kts`.
- Add `AndroidGallery/gradle/wrapper/*`.
- Add `AndroidGallery/app/build.gradle.kts`.
- Add `AndroidGallery/app/src/main/AndroidManifest.xml`.
- Add `AndroidGallery/app/src/main/kotlin/.../MainActivity.kt`.
- Add `AndroidGallery/app/src/main/kotlin/.../SwiftTUIHostView.kt`.
- Add `AndroidGallery/app/src/main/kotlin/.../SwiftTUIHostState.kt`.
- Add `AndroidGallery/app/src/main/kotlin/.../SwiftTUIRenderer.kt`.
- Add `AndroidGallery/app/src/main/kotlin/.../SwiftTUIAccessibilityOverlay.kt`.
- Add `AndroidGallery/SwiftPackage/Package.swift` or equivalent Swift shim.
- Add `AndroidGallery/Scripts/build_swift_android.sh`.
- Update `Scripts/check_examples.sh`
  - add `--android-only`;
  - run Android gallery build only when requested or when the Android toolchain
    is available.
- Update `.github/workflows/test.yml`
  - add opt-in or matrix-controlled Android gallery build after local gates are
    stable.
- Update README/AGENTS only after the Android app is actually runnable.

### Coordination root

- Update `docs/README.md` to index this plan.
- After child implementation commits land, update submodule pins in this root.
- Add a root Bazel target for the Android examples gate only after the native
  gate is stable enough for CI.

## 7. Phased Execution

### Phase 0 - Toolchain Alignment And Baseline Proof

Unblocked when Android Studio/JDK/NDK/Swift SDK downloads finish.

- [x] Install/use a Swift toolchain that exactly matches the Android SDK.
  Local validation uses Swift 6.3.0 via `swiftly run ... +6.3.0` to match the
  installed `swift-6.3-RELEASE_android` SDK while leaving the default host
  toolchain unchanged.
- [x] Set or verify Android environment variables:
  `ANDROID_HOME` or `ANDROID_SDK_ROOT`, and `ANDROID_NDK_HOME`.
- [x] Verify Java and Gradle access through Android Studio or the Gradle
  wrapper.
- [ ] Run a minimal Swift Android hello-world build outside this repo.
- [x] Run targeted SwiftTUI Android cross-compiles before adding host code.

Commands:

```bash
java -version
swiftly run swift --version
swiftly run swift sdk list
env | sort | rg 'ANDROID_(HOME|SDK_ROOT|NDK_HOME)'

DISABLE_EXPLICIT_PLATFORMS=1 \
  swiftly run swift build \
  --package-path swift-tui \
  --swift-sdk aarch64-unknown-linux-android28 \
  --target SwiftTUIRuntime

DISABLE_EXPLICIT_PLATFORMS=1 \
  swiftly run swift build \
  --package-path swift-tui-examples/gallery \
  --swift-sdk aarch64-unknown-linux-android28 \
  --target GalleryDemoViews
```

Expected outcome:

- If these fail only because of repo code, record exact compiler errors before
  implementing host code.
- If these fail because of toolchain mismatch, fix the toolchain first.

### Phase 1 - Shared Size Negotiator

- [x] Move `NativeTerminalSurfaceConfirmedSlack`,
  `NativeTerminalSurfaceSizeNegotiation`, and
  `NativeTerminalSurfaceSizeNegotiator` into `SwiftTUIRuntime` under neutral
  names.
- [x] Replace CoreGraphics types with scalar `Double` or small runtime structs.
- [x] Keep SwiftUI adapter behavior byte-for-byte equivalent.
- [x] Add runtime tests for constrained, unconstrained, preferred, rendered,
  fallback, and confirmed-slack cases.
- [x] Run existing SwiftUI host resize tests.

Commands:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUIRuntimeTests
swiftly run swift test --filter SwiftUIHostTests.ResizeBridgeTests
swiftly run swift test --filter SwiftUIHostTests.HostedSurfaceRegressionTests
```

### Phase 2 - Android Host Swift Product

- [x] Add `SwiftTUIAndroidHost` product and target.
- [x] Implement Android host scene lifecycle around `HostedSceneSession` and
  `HostedRasterSurface`.
- [x] Implement style, resize, focus, and input bridge methods.
- [x] Add a minimal C/JNI ABI with opaque handles.
- [x] Add an app-specific gallery host factory in the Android gallery Swift
  shim package.
- [x] Cross-compile the new target for `aarch64-unknown-linux-android28`.

Commands:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUIAndroidHostTests

cd ..
DISABLE_EXPLICIT_PLATFORMS=1 \
  swiftly run swift build \
  --package-path swift-tui \
  --swift-sdk aarch64-unknown-linux-android28 \
  --target SwiftTUIAndroidHost
```

### Phase 3 - Frame Snapshot Encoding

- [x] Define `AndroidHostFrameSnapshot` schema version 1.
- [ ] Encode raster cells, style runs, damage, image records, semantics, focus,
  announcements, and preferred layout size.
- [ ] Add stable image attachment ids and Kotlin-side cache invalidation rules.
- [ ] Add golden tests for representative gallery frames:
  text-only, images, animated images, scroll, focus, and presentation overlay.
- [ ] Add stale sequence tests.

Commands:

```bash
cd swift-tui
swiftly run swift test --filter SwiftTUIAndroidHostTests.AndroidHostFrameEncoderTests
swiftly run swift test --filter SwiftUIHostTests
```

### Phase 4 - Compose Host View

- [x] Create the Android Gallery Gradle project with Compose.
- [x] Add `SwiftTUIHostState` Kotlin wrapper around native handles.
- [x] Load the Swift `.so` and start/stop sessions from the Activity lifecycle.
- [x] Implement Compose measurement and publish resize back to Swift.
- [ ] Implement Canvas renderer for cells, style, text, images, and damage
  metadata.
- [ ] Implement pointer, keyboard, IME, focus, and clipboard bridging.
- [ ] Implement transparent accessibility semantics overlay.
- [ ] Add JVM/Robolectric or instrumentation tests for measure, frame parsing,
  input mapping, and accessibility node projection.

Current implementation note: the renderer paints text rows from the JSON frame
snapshot and the key bridge handles basic hardware keys/text. Style runs, image
attachments, pointer/touch input, IME composition, clipboard, and accessibility
projection remain in the next tranche.

Commands:

```bash
cd swift-tui-examples/AndroidGallery
./gradlew :app:testDebugUnitTest
./gradlew :app:assembleDebug
```

### Phase 5 - Gallery Demo App

- [x] Wire the Swift gallery shim to instantiate `GalleryView()`.
- [x] Make the first screen the hosted gallery surface.
- [ ] Verify all gallery tabs render without crashing.
- [ ] Verify core interactions:
  buttons, tab selection, text input, scrolling, pointer lab, popovers, palette,
  animations, and image tabs.
- [ ] Document intentionally unsupported Android interactions, especially file
  drop/content URI import if deferred.
- [ ] Add screenshots or an emulator smoke test artifact if CI supports it.

Current blocker: no Android device is attached and no AVD is configured, so
install/launch and tab-by-tab runtime verification have not run.

Commands:

```bash
cd swift-tui-examples/AndroidGallery
./gradlew :app:assembleDebug
./gradlew :app:connectedDebugAndroidTest
```

`connectedDebugAndroidTest` may remain local-only until CI has an emulator lane.

### Phase 6 - Native Gates And CI

- [ ] Add `--android-only` to `swift-tui-examples/Scripts/check_examples.sh`.
- [ ] Add `Scripts/check_android_gallery.sh` or equivalent if keeping the
  Android gate separate is cleaner.
- [ ] Add examples CI Android job once local builds are deterministic.
- [ ] Add a root Bazel target, for example `//:android_gallery_native_gate`,
  after the examples native gate is stable.
- [ ] Keep `//:org_fast` cheap unless Android setup time is low and reliable.
  Prefer `//:org_full` or an explicit target for the Android gate initially.

Commands:

```bash
cd swift-tui-examples
Scripts/check_examples.sh --android-only

cd /Users/adamz/Developer/SwiftTUI
mise exec -- bazel test //:org_fast
mise exec -- bazel test //:android_gallery_native_gate
```

### Phase 7 - Docs, Public Surface, And Release Readiness

- [ ] Update `swift-tui/docs/HOSTS-AND-PLATFORMS.md` after implementation.
- [ ] Add or restore `swift-tui/VISION-GAP.md` for remaining Android gaps
  referenced by child docs.
- [ ] Update `swift-tui` README platform badge only after Android host builds
  in CI or the explicit Android gate is documented.
- [ ] Update `swift-tui-examples` README with Android Gallery instructions only
  after `./gradlew :app:assembleDebug` works from a fresh clone.
- [ ] Update root `docs/PUBLIC-REPO-READINESS.md` if Android support affects
  public release readiness.
- [ ] Commit child repos first, then update root submodule pins.

## 8. Verification Matrix

| Layer | Required verification |
| --- | --- |
| Toolchain | Swift toolchain version equals Swift Android SDK version; Android NDK LTS r27d or later is discoverable. |
| Swift runtime | `SwiftTUIRuntime`, `SwiftTUIAnimatedImage`, `SwiftTUICharts`, and `GalleryDemoViews` cross-compile for `aarch64-unknown-linux-android28`. |
| Swift host | `SwiftTUIAndroidHostTests` pass and the target cross-compiles for Android. |
| SwiftUI parity | Existing `SwiftUIHostTests` pass after shared size-negotiator extraction. |
| Compose host | Unit tests pass for frame parsing, measurement, input mapping, and semantics mapping. |
| Demo app | `./gradlew :app:assembleDebug` produces an APK with the Swift `.so` under `arm64-v8a`. |
| Device/emulator | The gallery opens, paints nonblank content, responds to input, and survives tab switching. |
| Root coordination | `mise exec -- bazel test //:org_fast` passes after docs/pin changes. |

## 9. Risks And Open Questions

- **Swift/Android SDK version matching:** the local build is aligned by using
  Swift 6.3.0 explicitly with the installed `swift-6.3-RELEASE_android` SDK.
  Future Android SDK bumps must be paired with the matching Swift toolchain
  before treating compiler errors as framework issues.
- **Manifest gating:** `Package.swift` includes `SwiftUIHost` based on host OS,
  not target OS. Android targeted builds from macOS may need an explicit host
  exclusion gate for full package builds.
- **Frame DTO performance:** JSON is easier to inspect, but animations may need
  binary encoding quickly.
- **Renderer fidelity:** Android text measurement and glyph coverage may not
  match AppKit/UIKit exactly. Start with the embedded monospaced font and add
  pixel fixtures around problematic glyph classes.
- **Animated images:** the Swift side can decode GIF frames, but the Android
  renderer must cache and schedule updated attachment frames without forcing
  unnecessary Swift layout work.
- **Accessibility focus:** Android accessibility focus routing may not map
  one-to-one with SwiftTUI focused identity. Implement node projection first,
  then focus synchronization.
- **x86_64 emulator:** current docs identify an x86_64 gap. Keep `arm64-v8a`
  as the supported first target unless this is resolved.
- **Packaging Swift libraries:** the current Gradle task copies the gallery
  `.so` plus all Swift Android runtime `.so` files into generated `jniLibs`.
  This is simple and verified at APK-build time, but should be tightened to the
  actual `DT_NEEDED` closure before public packaging.

## 10. Non-Goals

- No native Compose rewrite of SwiftTUI controls.
- No Android terminal/PTY embedding in the first Android host.
- No `x86_64` Android support in the first accepted tranche.
- No public AAR publication before the demo app and ABI stabilize.
- No planning docs in child repos.
- No requirement that normal SwiftPM consumers install Android Studio or Gradle.

## 11. Completion Criteria

- `SwiftTUIAndroidHost` exists as an explicit product and builds for
  `aarch64-unknown-linux-android28`.
- Android Gallery app opens the full `GalleryView()` in a Compose host view.
- The Compose host negotiates size from host constraints and
  `preferredLayoutSize`, including constrained and wrap-content cases.
- Resize, pointer, keyboard/text input, focus, clipboard write, and scroll input
  reach SwiftTUI.
- Static images and animated image content render in the Android host.
- Accessibility exposes semantic nodes, not only an opaque canvas.
- The Android gallery build is reachable through an examples native gate.
- Root `docs/README.md` indexes this plan, and root submodule pins are updated
  after child implementation commits.

## 12. Source Links

- Swift Android getting started:
  <https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html>
- Swift Android DocC:
  <https://docs.swift.org/android/documentation/android/gettingstarted/>
- Swift Android examples:
  <https://github.com/swiftlang/swift-android-examples>
- Swift Java interop:
  <https://github.com/swiftlang/swift-java>
- Android Studio:
  <https://developer.android.com/studio>
- Android NDK downloads:
  <https://developer.android.com/ndk/downloads>
- Compose layout basics:
  <https://developer.android.com/develop/ui/compose/layouts/basics>
