# Android Host Current State

**Date:** 2026-06-09

This report records the current state of the Android host effort after the
first implementation pass. The execution plan remains
[`docs/plans/2026-06-09-001-android-host-view-gallery-demo-plan.md`](../plans/2026-06-09-001-android-host-view-gallery-demo-plan.md).

## Current State

The repo now has explicit Android host scaffolding in two child repos:

- `swift-tui` has a `SwiftTUIAndroidHost` product and target under
  `Platforms/Android`.
- `swift-tui` has a platform-neutral `HostedSurfaceSizeNegotiator` in
  `SwiftTUIRuntime`, and the SwiftUI host now adapts to that shared negotiator.
- `swift-tui-examples` has an `AndroidGallery` Gradle project with a Compose
  host view, a Kotlin state/frame parser layer, an Android Canvas text renderer,
  a small `ndk-build` JNI bridge, and a Swift package shim that creates
  `GalleryView()`.
- The Android demo app builds a Swift dynamic library for `arm64-v8a`, copies
  the Swift Android runtime `.so` files into generated `jniLibs`, and packages
  them into the debug APK.

## Verified Locally

Swift-side focused tests pass:

```bash
swiftly run swift test --package-path swift-tui --filter HostedSurfaceSizeNegotiatorTests
swiftly run swift test --package-path swift-tui --filter SwiftTUIAndroidHostTests
```

Android Swift cross-builds have been verified with Swift 6.3.0 and the
`swift-6.3-RELEASE_android` SDK:

```bash
DISABLE_EXPLICIT_PLATFORMS=1 \
ANDROID_NDK_HOME="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3-RELEASE_android.artifactbundle/swift-android/android-ndk-r27d" \
swiftly run swift build +6.3.0 \
  --package-path swift-tui \
  --swift-sdk aarch64-unknown-linux-android28 \
  --target SwiftTUIAndroidHost
```

The Android Gallery app assembles with system Gradle 9.5.1:

```bash
cd swift-tui-examples/AndroidGallery

JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
ANDROID_HOME="$HOME/Library/Android/sdk" \
ANDROID_NDK_HOME="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3-RELEASE_android.artifactbundle/swift-android/android-ndk-r27d" \
gradle :app:assembleDebug
```

The resulting debug APK includes `libGalleryAndroidHost.so`,
`libswift_tui_jni.so`, and Swift runtime libraries under `lib/arm64-v8a/`.

## Current Blockers

- `./gradlew :app:assembleDebug` is blocked before Gradle configuration by
  repeated `services.gradle.org` distribution download timeouts. The wrapper is
  checked in and configured with a 60 second timeout and retries; the same
  project builds with installed Gradle 9.5.1.
- Runtime verification is blocked because `adb devices -l` returns no attached
  Android devices and `emulator -list-avds` returns no configured AVDs.

## Known Gaps

The current Android host is a buildable scaffold, not complete platform parity:

- The JSON frame snapshot currently carries text rows, grid size, preferred
  grid size, damage flags, and focus identity. It does not yet carry style runs,
  image attachments, semantic nodes, accessibility announcements, or focus
  presentation details.
- The Compose renderer currently paints text rows. It does not yet render cell
  foreground/background style, image attachments, animated images, retained
  damage caches, or accessibility overlays.
- Input bridging currently covers basic hardware keys/text through Compose key
  events. Pointer/touch, IME composition, clipboard, link opening, accessibility
  focus, and Android content URI import remain follow-up work.
- Device/emulator behavior is not yet verified. The next runtime smoke test
  must prove the gallery opens, paints nonblank content, and survives tab
  switching.

## Next Work

1. Attach an `arm64-v8a` device or configure an AVD and run an install/launch
   smoke test.
2. Resolve the Gradle wrapper distribution download issue or pre-provision the
   wrapper distribution in the local/CI environment.
3. Extend the frame snapshot from text rows to styled cells, image attachments,
   semantics, and focus presentation.
4. Extend Compose rendering and input to cover the gallery's tabs rather than
   only the text-row proof.
5. Add an examples native gate once `:app:assembleDebug` is deterministic
   through the wrapper or a pinned local Gradle path.

