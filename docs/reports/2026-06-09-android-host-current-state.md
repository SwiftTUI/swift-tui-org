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
not rely on SwiftPM's multiple-installed-SDK selection:

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

The resulting debug APK includes `libGalleryAndroidHost.so`,
`libswift_tui_jni.so`, `libc++_shared.so`, and Swift runtime libraries under
`lib/arm64-v8a/`.

Runtime smoke progressed on an attached `arm64-v8a` emulator:

```bash
adb devices -l
adb install -r swift-tui-examples/AndroidGallery/app/build/outputs/apk/debug/app-debug.apk
adb shell am start -W -n org.swifttui.gallery.android/.MainActivity
adb shell pidof org.swifttui.gallery.android
```

Observed result: install succeeds, launch returns `Status: ok`, the app process
stays alive, and logcat shows `libswift_tui_jni.so` loading. A screenshot after
launch is nonblank but remains on the Compose startup placeholder,
`Starting SwiftTUI gallery...`; no SwiftTUI gallery frame is visible yet.

## Current Blockers

- Runtime verification is now blocked at first-frame publication: the app
  installs and launches on the attached emulator, but the Compose host remains
  on `Starting SwiftTUI gallery...` instead of painting the first SwiftTUI
  frame. There is no fatal exception in the checked logcat slice.
- `emulator -list-avds` still returns no configured AVDs, so repeatable local or
  CI smoke testing still needs a named AVD or an explicitly provisioned device.

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
- Device/emulator behavior is only partially verified. The app opens and stays
  alive on an attached `arm64-v8a` emulator, but it has not yet painted a
  SwiftTUI gallery frame or survived tab switching.

## Next Work

1. Diagnose why the Android Compose host remains on the startup placeholder
   after launch instead of receiving and painting the first SwiftTUI frame.
2. Configure a named AVD or CI device lane so the install/launch smoke is
   repeatable outside the currently attached emulator.
3. Extend the frame snapshot from text rows to styled cells, image attachments,
   semantics, and focus presentation.
4. Extend Compose rendering and input to cover the gallery's tabs rather than
   only the text-row proof.
5. Add an examples native gate around the wrapper assemble, including explicit
   Swift SDK setup and Android SDK/NDK prerequisites.
