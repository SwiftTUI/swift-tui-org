# Android Host Current State

**Date:** 2026-06-18

This report records the current state of the Android host effort after the
latest parity pass. The execution plan remains
[`docs/plans/2026-06-09-001-android-host-view-gallery-demo-plan.md`](../plans/2026-06-09-001-android-host-view-gallery-demo-plan.md).

## Current State

The repo now has explicit Android host scaffolding in two child repos:

- `swift-tui` has a `SwiftTUIAndroidHost` product and target under
  `Platforms/Android`.
- `swift-tui` has a platform-neutral `HostedSurfaceSizeNegotiator` in
  `SwiftTUIRuntime`, and the SwiftUI host now adapts to that shared negotiator.
- `swift-tui-examples` has an `AndroidGallery` Gradle project with a Compose
  host view, a Kotlin state/frame parser layer, an Android Canvas renderer,
  a transparent Compose semantics overlay, a small `ndk-build` JNI bridge, and
  a Swift package shim that creates `GalleryView()`.
- The Android demo app builds a Swift dynamic library for `arm64-v8a`, copies
  the Swift Android runtime `.so` files into generated `jniLibs`, and packages
  them into the debug APK.
- The Android host now publishes its first `GalleryView()` frame on an attached
  `arm64-v8a` emulator. The Compose startup placeholder is no longer the
  runtime stopping point.
- The Android frame snapshot schema now carries terminal colors, raster cells,
  cell styles, ranged damage metadata, image attachment records and payloads,
  accessibility nodes, accessibility announcements, focus presentation, and
  preferred layout size.
- The Compose renderer now paints styled cells, foreground/background colors,
  underline/strikethrough decorations, and embedded image payloads. The host view
  mounts a transparent semantics overlay and bridges basic touch activation back
  through SwiftTUI input.

## Verified Locally

Swift-side focused tests pass:

```bash
swiftly run swift test --package-path swift-tui --filter HostedSurfaceSizeNegotiatorTests
swiftly run swift test --package-path swift-tui --filter SwiftTUIAndroidHostTests
cd swift-tui && Scripts/generate_public_api_inventory.sh --check
```

Android Swift cross-builds have been refreshed with Swift 6.3.1 and the
installed `swift-6.3.2-RELEASE_android` SDK. The 6.3.2 bundle needs its
`ndk-sysroot` materialized from an Android NDK before the first build:

```bash
ANDROID_NDK_HOME="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3-RELEASE_android.artifactbundle/swift-android/android-ndk-r27d" \
"$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle/swift-android/scripts/setup-android-sdk.sh"
```

The `arm64-v8a` SwiftPM build uses the Android target triple selector; SwiftPM
selects the `swift-6.3.2-RELEASE_android` artifact for that triple:

```bash
DISABLE_EXPLICIT_PLATFORMS=1 \
ANDROID_NDK_HOME="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3-RELEASE_android.artifactbundle/swift-android/android-ndk-r27d" \
swiftly run swift build +6.3.1 \
  --package-path swift-tui \
  --swift-sdk aarch64-unknown-linux-android28 \
  --target SwiftTUIAndroidHost
```

The Android Gallery app assembles with both system Gradle 9.5.1 and the
checked-in wrapper. The Gradle build creates a generated
`app/build/swift-sdks` search path containing only
`swift-6.3.2-RELEASE_android` before invoking SwiftPM, so the app build does
not rely on SwiftPM's multiple-installed-SDK selection. During org-root
development, Gradle also mirrors the public SwiftTUI HTTPS dependency to the
local pinned checkout, keeping the public manifest free of sibling path
dependencies:

```bash
cd swift-tui-examples/AndroidGallery

JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
ANDROID_HOME="$HOME/Library/Android/sdk" \
ANDROID_NDK_HOME="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3-RELEASE_android.artifactbundle/swift-android/android-ndk-r27d" \
SWIFT_ANDROID_SDK_BUNDLE="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle" \
SWIFT_ANDROID_ROOT="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle/swift-android" \
gradle :app:assembleDebug

JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
ANDROID_HOME="$HOME/Library/Android/sdk" \
ANDROID_NDK_HOME="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3-RELEASE_android.artifactbundle/swift-android/android-ndk-r27d" \
SWIFT_ANDROID_SDK_BUNDLE="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle" \
SWIFT_ANDROID_ROOT="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle/swift-android" \
./gradlew :app:assembleDebug
```

The 2026-06-10 parity pass also verified Kotlin compilation directly:

```bash
cd swift-tui-examples/AndroidGallery

JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
ANDROID_HOME="$HOME/Library/Android/sdk" \
ANDROID_NDK_HOME="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3-RELEASE_android.artifactbundle/swift-android/android-ndk-r27d" \
SWIFT_ANDROID_SDK_BUNDLE="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle" \
SWIFT_ANDROID_ROOT="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle/swift-android" \
./gradlew :app:compileDebugKotlin \
  -x buildSwiftAndroid \
  -x copySwiftAndroidLibraries \
  -x externalNativeBuildDebug
```

The resulting debug APK includes `libGalleryAndroidHost.so`,
`libswift_tui_jni.so`, `libc++_shared.so`, and Swift runtime libraries under
`lib/arm64-v8a/`.

Runtime smoke progressed on the named `arm64-v8a` AVD
`SwiftTUI_AndroidGallery_arm64`, backed by
`system-images;android-36.1;google_apis;arm64-v8a`:

```bash
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
"$HOME/Library/Android/sdk/emulator/emulator" -list-avds

JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
"$HOME/Library/Android/sdk/emulator/emulator" \
  -avd SwiftTUI_AndroidGallery_arm64 \
  -no-window \
  -gpu swiftshader_indirect \
  -no-audio \
  -no-boot-anim \
  -no-snapshot-save

"$HOME/Library/Android/sdk/platform-tools/adb" -s emulator-5554 devices -l
"$HOME/Library/Android/sdk/platform-tools/adb" -s emulator-5554 install -r \
  swift-tui-examples/AndroidGallery/app/build/outputs/apk/debug/app-debug.apk
"$HOME/Library/Android/sdk/platform-tools/adb" -s emulator-5554 shell am start -W \
  -n org.swifttui.gallery.android/.MainActivity
"$HOME/Library/Android/sdk/platform-tools/adb" -s emulator-5554 shell pidof \
  org.swifttui.gallery.android
```

Observed result: install succeeds, launch returns `Status: ok`, the app process
stays alive, logcat shows `libswift_tui_jni.so` loading, and the screenshot
shows the hosted SwiftTUI gallery content (`Logo`, `Counter`, `Life`, `Todo`,
and the SwiftTUI logo art) instead of the Compose startup placeholder.

The 2026-06-10 parity retry installed
`system-images;android-35;google_apis;arm64-v8a` and created a smaller
`SwiftTUI_AndroidGallery_api35_medium_arm64` AVD. The important operational
detail is that the emulator must be kept alive as a foreground long-running
process; launching it as a background job under a short-lived shell can let the
shell tear it down just after boot. With the foreground session held open,
`adb` reported `emulator-5554 booted`, install returned `Success`, launch
returned `Status: ok`, the app process stayed alive as pid `3430`, and the
screenshot at `/tmp/swifttui-androidgallery-api35-medium.png` shows the hosted
SwiftTUI gallery with the tab bar and SwiftTUI logo content.

The 2026-06-18 follow-up used the coordination dev overlay for the pre-release
Android experience:

```bash
bazel run //:open_overlay -- --print-env examples
cd .build/coordination/dev-overlay/swift-tui-examples/AndroidGallery

JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
ANDROID_HOME="$HOME/Library/Android/sdk" \
ANDROID_NDK_HOME="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3-RELEASE_android.artifactbundle/swift-android/android-ndk-r27d" \
SWIFT_ANDROID_SDK_BUNDLE="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle" \
SWIFT_ANDROID_ROOT="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle/swift-android" \
swiftly run swift package clean --package-path SwiftPackage

JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
ANDROID_HOME="$HOME/Library/Android/sdk" \
ANDROID_NDK_HOME="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3-RELEASE_android.artifactbundle/swift-android/android-ndk-r27d" \
SWIFT_ANDROID_SDK_BUNDLE="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle" \
SWIFT_ANDROID_ROOT="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle/swift-android" \
./gradlew --no-daemon --console=plain :app:assembleDebug
```

That overlay rewrites `AndroidGallery/SwiftPackage/Package.swift` to consume the
local `swift-tui` checkout as a path dependency while the public child manifest
stays pinned to `0.0.21`. The non-overlay public build still resolves that
released SwiftTUI tag, so pre-release input verification needs the dev overlay
until the next coordinated release bump.

On the `SwiftTUI_AndroidGallery_arm64` AVD, the overlay APK installed and
launched successfully. Physical `adb shell input tap` events switched `Logo` ->
`Counter` -> `Life`, and a tap on Counter's `+` button incremented the displayed
count from `0` to `1`. Screenshots were captured at
`/tmp/swifttui-overlay-00-initial.png`,
`/tmp/swifttui-overlay-01-counter.png`,
`/tmp/swifttui-overlay-02-life.png`, and
`/tmp/swifttui-overlay-04-counter-after-plus.png`.

The same day, a broader dev-overlay sweep ran on the
`SwiftTUI_AndroidGallery_arm64` AVD. It selected and rendered all 19 Gallery tabs
through physical visible-tab or overflow-menu taps, then exercised representative
interactions: Counter `+` taps, Text Input focus and text entry, a physical
scroll on Text Input, Scroll Control's `Down 2` command, Pointer Lab spatial tap,
drag, and long press, and command-palette navigation to Progress. Local artifacts
were captured under `/tmp/swifttui-android-sweep-20260618/`; the durable summary
is [`2026-06-18-android-interaction-sweep.md`](2026-06-18-android-interaction-sweep.md).

## Current Blockers

- Automated accessibility-tree verification is still shallow. `uiautomator dump`
  now sees generic Compose groups/buttons and a few descriptions such as
  `Reset counter` and `^K Palette`, but not full per-node SwiftTUI labels,
  values, and actions.
- Android Back is not routed through the SwiftTUI presentation/menu stack yet;
  pressing Back from the app sent the emulator to the launcher in the
  2026-06-18 sweep.

## Known Gaps

The current Android host is much closer to SwiftUI host parity, but still not
complete platform parity:

- The JSON frame snapshot now carries styled cells, image records, semantic
  nodes, announcements, and focus presentation. It remains JSON rather than a
  binary frame protocol.
- The Compose renderer now paints styled cells and embedded images. It consumes
  damage metadata but does not yet maintain a retained bitmap damage cache.
- Input bridging covers hardware keys/text, basic touch activation, physical
  tab/overflow taps, Counter button taps, Text Input entry, Text Input physical
  scrolling, Scroll Control button commands, Pointer Lab spatial tap/drag/long
  press, and command-palette filtering/selection on the dev-overlay APK. IME
  composition, device-level clipboard verification, link opening, accessibility
  focus feedback, Android Back routing, and Android content URI import remain
  follow-up work.
- Device/emulator behavior is still partial but current. The app opens, stays
  alive, paints the first SwiftTUI gallery frame, renders all 19 tabs, and
  responds to the representative interaction sweep on the API 36.1
  `SwiftTUI_AndroidGallery_arm64` AVD.

## Next Work

1. Promote the useful subset of the 2026-06-18 manual sweep into a repeatable
   Gradle/ADB smoke lane.
2. Extend Android semantics and input from the current proof to accessibility
   labels/actions/values, IME composition, clipboard, links, Android Back
   routing, and content URI import.
3. Decide whether JSON remains acceptable or whether the Android host needs a
   binary frame protocol before broader animation profiling.
4. Add an examples native gate around the wrapper assemble, including explicit
   Swift SDK setup and Android SDK/NDK prerequisites.
