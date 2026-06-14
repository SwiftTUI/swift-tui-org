# Android host: extract a reusable library from the example — proposal

**Date:** 2026-06-14 · **Status:** Proposed — repo placement **decided**
(new dedicated `swift-tui-android` repo, 2026-06-14); Phase A extraction deferred
(docs-only for now), no code yet ·
**Depends on / follows:** [plans/2026-06-09-001-android-host-view-gallery-demo-plan.md](../plans/2026-06-09-001-android-host-view-gallery-demo-plan.md),
[reports/2026-06-09-android-host-current-state.md](../reports/2026-06-09-android-host-current-state.md) ·
**Incorporates:** the 2026-06-14 finding that the `swift-png` x86_64 build blocker
is resolved (all products cross-compile for `x86_64-unknown-linux-android28`).

## TL;DR

A library user who wants to embed SwiftTUI in their own Android/Compose app
currently has to **copy ~11 Kotlin files, a JNI C++ shim, and a block of Gradle
build logic out of the `AndroidGallery` example**. That reusable host
infrastructure has no module boundary — it lives in the example app. Only ~23
lines of Swift (`GalleryAndroidHost.swift`) and the Android `MainActivity` are
genuinely app-specific.

This proposes extracting the reusable layer into (1) an **Android host library
(eventually an AAR)**, (2) a **Gradle convention plugin** for the Swift→`.so`
cross-build, leaving the example a thin consumer. It is phased so the *consumer
boundary* lands now (Phase A, internal module) without freezing a public ABI
before it is ready (Phase B, published AAR) — honoring the existing non-goal
"No public AAR publication before the demo app and ABI stabilize."

## Problem: reusable host code is trapped in the example

The Swift side is already factored correctly: the framework owns
`SwiftTUIAndroidHost` (the C ABI, scene host, frame encoder) under
`swift-tui/Platforms/Android/`. The **Kotlin/JNI/Gradle host layer is not** — it
is wholly inside `swift-tui-examples/AndroidGallery/app/`, with the only module
being `:app` (`AndroidGallery/settings.gradle.kts:18` — `include(":app")`). There
is no library module and no `build-logic` convention plugin.

### The reuse boundary (measured against `HEAD`)

| Bucket | Concrete files | Belongs in |
| --- | --- | --- |
| **Genuinely app-specific** | `SwiftPackage/Sources/GalleryAndroidHost/GalleryAndroidHost.swift` (~23 lines: wraps `GalleryView()` in an `App`, calls `AndroidHostSceneHost(app:)`, exposes one `@_cdecl`); `app/src/main/kotlin/.../MainActivity.kt`; `applicationId`, manifest, app theme | Each consumer's own app |
| **Reusable Kotlin host** | `app/src/main/kotlin/.../` — `SwiftTUIHostView`, `SwiftTUIRenderer`, `SwiftTUIFrame`, `SwiftTUIHostState`, `SwiftTUIInput`, `SwiftTUIIme`, `SwiftTUIClipboard`, `SwiftTUIAccessibilityOverlay`, `SwiftTUIBoxDrawing`, `SwiftTUIDamagePlan`, `SwiftTUIJni` (11 files) | Host **library / AAR** |
| **Reusable JNI shim** | `app/src/main/jni/swift_tui_jni.cpp`, `Android.mk`, `Application.mk` | Host **library / AAR** |
| **Reusable build logic** | `app/build.gradle.kts` tasks: `buildSwiftAndroid`, `copySwiftAndroidLibraries`, `prepareSwiftSdkSearchPath` | Gradle **convention plugin** |
| **Dev/coordination only** | `configureSwiftPackageMirrors` (mirrors the public dep to a local checkout); `abiFilters += "arm64-v8a"` (now documented) | Plugin *defaults* + overlay |

A consumer must today copy everything in rows 2–4. That is the trap.

### The specific coupling that blocks reuse

The generic Kotlin/JNI layer is bound to an **app-specific symbol name**. The
native lib is loaded as `swift_tui_jni` (`SwiftTUIJni.kt:5` —
`System.loadLibrary("swift_tui_jni")`) and host creation routes through the
example-owned `@_cdecl("swift_tui_android_create_gallery_host")`
(`GalleryAndroidHost.swift:13`). A reusable library cannot hardcode
`…_create_gallery_host`. This must be decoupled (see Design §3) before the layer
can be shared.

## Target architecture (3 artifacts a consumer uses; 0 they copy)

```
swift-tui (SwiftPM)                 swift-tui-android (Gradle/Maven)        consumer app
┌───────────────────────┐          ┌───────────────────────────┐         ┌──────────────────┐
│ SwiftTUIAndroidHost    │  HTTPS   │ AAR: Compose SwiftTUIHostView│  dep   │ apply plugin     │
│  - C ABI (start/stop/  │ ───────▶ │   + renderer/parser/input/  │ ─────▶ │ implementation(  │
│    resize/send_input/  │  tagged  │   IME/clipboard/a11y        │  AAR   │  "…:android-host")│
│    copy_frame/clipboard│          │ + JNI shim (RegisterNatives)│        │ + ~1-line Swift  │
│  - AndroidHostSceneHost│          │ + bundled host/runtime .so  │        │   entry + MyView │
│ already factored ✓     │          │ Gradle convention plugin    │        └──────────────────┘
└───────────────────────┘          └───────────────────────────┘
```

1. **`SwiftTUIAndroidHost` (Swift, SwiftPM)** — already in `swift-tui`. No change
   to ownership; consumer's Swift shim depends on the tagged product.
2. **Android host library → AAR** — the 11 Kotlin files + JNI shim, published to
   Maven. Bundles the prebuilt SwiftTUI host `.so` + Swift runtime `.so`s +
   `libc++_shared.so` under the AAR's `jni/<abi>/`. Consumer adds one dependency
   and gets `SwiftTUIHostView()` as a composable.
3. **Gradle convention plugin** (`id("sh.swifttui.android")`) — wires the
   per-app Swift→`.so` cross-build + jniLibs merge + Swift-SDK search path, so
   the build orchestration is `apply`-ed, not pasted.

The consumer app becomes: apply the plugin, add the AAR dependency, write the
~1-line Swift entry (Design §3) over their root `View`, plus their
`MainActivity`. Nothing is copied.

## Design details (Android best practice)

### 1. Native `.so` distribution — two tiers

- **Default — bundle in the AAR's `jniLibs`** and load at runtime via
  `System.loadLibrary`. Idiomatic, simplest, covers every consumer who just
  embeds a SwiftTUI view. AARs are natively multi-ABI, so this is also where the
  x86_64 ABI is added when a CI emulator lane needs it (the `swift-png` blocker
  is gone; this is now purely a packaging choice).
- **Prefab — only with a "very good reason"** (the legitimate exception to "no
  copy-paste"): Prefab is the official AAR mechanism for shipping native libs
  **plus C headers** to a *consumer's own native build*. Adopt it only if a
  consumer writes their own JNI/C++ that must **link** the host C ABI at build
  time. Then export the ABI header via Prefab so they link instead of copy. Do
  not adopt preemptively.

### 2. Harden the JNI binding

Register native methods explicitly via `JNI_OnLoad` / `RegisterNatives` rather
than relying on implicit `Java_…`-name-mangled symbol binding. This validates
symbols at load (fail fast on a runtime mismatch) and anchors the class loader
correctly — important for a library consumed under R8. Ship a
`consumer-rules.pro` that keeps `SwiftTUIJni` and its `external` methods so a
consumer's R8 pass does not strip or rename JNI-bound members (silent breakage
otherwise).

### 3. Decouple the host-creation entry point

Replace the app-specific `swift_tui_android_create_gallery_host` with a **stable
conventional contract** the library can depend on:

- **Symbol contract (minimum):** every consumer implements a fixed
  `@_cdecl("swift_tui_android_create_host")`; the library resolves it (declared
  `external`, or `dlsym` at runtime for late binding). The library's JNI no
  longer references any app-specific name.
- **Ergonomic layer (recommended):** a Swift macro in `SwiftTUIAndroidHost`, e.g.
  `#SwiftTUIAndroidHost(MyRootView())`, that expands to the `App`/`Scene` wrap +
  `AndroidHostSceneHost(app:)` + the `@_cdecl` — reducing the one unavoidable
  per-app Swift artifact from 23 lines to one. Keep `AndroidHostSceneHost(app:)`
  as the public seam for users who want manual control.

### 4. Swift-toolchain compatibility contract (non-obvious failure mode)

The bundled Swift runtime `.so`s are tied to the exact Swift compiler version
they were built with. A consumer's own app `.so` **must** be built with a
compatible toolchain or symbols mismatch at runtime. Mitigations:

- Publish the Swift version in the AAR's metadata (a manifest resource).
- Have the Gradle plugin **assert** the local `swiftly`-selected toolchain
  matches that version and fail the build with a clear message otherwise.

This mirrors the existing local pin (`ndkVersion = "27.3.13750724"` /
`minSdk = 28`) but for the Swift side.

## Repository placement — mirror the established precedent

The project already splits hosts by package-manager ecosystem:

- `SwiftUIHost` (Apple parity reference) lives **in the framework**
  (`swift-tui/Platforms/SwiftUI/`) because it is SwiftPM-consumable.
- The **web** host has its **own repo** (`swift-tui-web`, Bun/npm) because it has
  a non-SwiftPM package-manager contract.

Android has a **Gradle/Maven** contract, so by the same logic it wants a
**dedicated `swift-tui-android` repo** (Gradle-rooted, Maven-published) that
consumes the tagged `SwiftTUIAndroidHost` SwiftPM product over public HTTPS. The
Swift host stays in `swift-tui`. This keeps the "public child repos consume
siblings only through tagged HTTPS dependencies" invariant intact and adds a
fifth submodule + Bazel module to the coordination root.

**Decision (2026-06-14): a new dedicated `swift-tui-android` repo for Phase B.**
This is the cleanest mirror of the `swift-tui-web` precedent and keeps the
Gradle/Maven contract out of the SwiftPM `swift-tui` repo, preserving the "do not
make a public child repo require Gradle for its default build" invariant. It adds
a fifth submodule + Bazel module to the coordination root and a sixth row to the
repo-model table in the root `AGENTS.md`/`CLAUDE.md`. The rejected alternative —
a Gradle subtree inside `swift-tui/Platforms/Android/` — saves a repo but mixes
package-manager contracts and risks that invariant. Phase A needs neither the new
repo nor publication (see below).

## Phased plan

### Phase A — internal extraction (now; low-risk; resolves the concern)

> **Execution plan:** promoted to an ordered, verifiable task plan in
> [plans/2026-06-14-002-android-host-library-phase-a-extraction-plan.md](../plans/2026-06-14-002-android-host-library-phase-a-extraction-plan.md),
> which corrects this section: the create-symbol coupling is **three** app-name
> JNI bindings (not one), the package rename and `RegisterNatives` switch must
> land atomically, and "same APK payload" gets a falsifiable check. The Kotlin
> `SwiftTUIHostState` is also already factored over an injected `createHost`
> lambda, so only the JNI layer + the `rememberSwiftTUIHostState()` convenience
> need decoupling.

Establish and *prove* the consumer boundary with zero copy-paste and **without
publishing or freezing a public ABI**:

- [ ] Add an Android **library module** (`:swift-tui-host`) to
  `AndroidGallery/settings.gradle.kts`; move the 11 `SwiftTUI*.kt` files + the
  JNI shim into it; give it a `consumer-rules.pro`.
- [ ] Extract `buildSwiftAndroid` / `copySwiftAndroidLibraries` /
  `prepareSwiftSdkSearchPath` into a **`build-logic` included build** convention
  plugin; `:app` and the library apply it.
- [ ] Decouple the create symbol (Design §3, symbol contract); switch the JNI to
  `RegisterNatives` (Design §2).
- [ ] Make `:app` a **thin consumer**: depend on `:swift-tui-host`, keep only
  `MainActivity` + the (now macro-able) Swift entry + `GalleryView()`.
- [ ] Verify the existing JVM unit tests still pass and `:app:assembleDebug`
  still produces the same APK payload; re-run the arm64 emulator smoke.

Phase A is fully inside `swift-tui-examples`; no new repo, no Maven, no public
ABI commitment. A future external consumer is then a copy of `:app`, not a copy
of the host internals.

### Phase B — publication (later; after the ABI/frame protocol stabilize)

Gate on: the frame protocol decision (JSON vs binary), a green automated Android
gate, and ABI stability.

- [ ] Promote the library module to the new `swift-tui-android` repo (decided
  2026-06-14); wire it as a fifth submodule + Bazel module in the coordination
  root; publish the AAR + the Gradle plugin to Maven.
- [ ] Bundle the host/runtime `.so`s in the AAR; add the toolchain-compat
  manifest + plugin assertion (Design §4).
- [ ] Add x86_64 to the AAR's ABI set if a CI emulator lane wants it.
- [ ] Add Prefab export only if a native-linking consumer materializes
  (Design §1).
- [ ] Retire the non-goal "No public AAR publication before the demo app and ABI
  stabilize"; update `swift-tui/docs/HOSTS-AND-PLATFORMS.md` and the examples
  README.

## Risks and open questions

- **Premature ABI freeze.** The frame protocol is still JSON and the C ABI is
  young. Phase A explicitly avoids publishing to dodge this; Phase B is gated.
- **Repo placement** resolved 2026-06-14 (new `swift-tui-android` repo); the
  remaining org plumbing (submodule + Bazel module + repo-model table row) is
  Phase B work.
- **AAR size.** Bundling all Swift runtime `.so`s per ABI is large. Tighten to
  the actual `DT_NEEDED` closure before publication (already flagged as a risk in
  the host plan).
- **`dlsym` vs link-time** for the create symbol: late binding (`dlsym`) is more
  flexible for a published library but loses link-time validation; the macro
  approach makes either safe. Decide during Phase A.
- **Toolchain coupling** (Design §4) is the most likely field failure; the plugin
  assertion is not optional for a published artifact.

## Non-goals

- No public AAR publication in Phase A (only an internal module boundary).
- No Compose rewrite of SwiftTUI controls; the library hosts, it does not
  reimplement.
- No change to the Swift `SwiftTUIAndroidHost` ownership — it stays in
  `swift-tui`.
- No requirement that SwiftPM-only consumers install Gradle.

## Completion criteria

- **Phase A:** the example app contains no reusable host code — only
  `MainActivity`, the Swift entry, and `GalleryView()`; the host lives in a
  library module + convention plugin it consumes; JVM tests and arm64 smoke pass.
- **Phase B:** an external Android app can embed a SwiftTUI view by adding one
  Maven dependency + applying one Gradle plugin + writing one Swift entry line,
  with no files copied out of this repository.

## Source links

- Host plan: [plans/2026-06-09-001-android-host-view-gallery-demo-plan.md](../plans/2026-06-09-001-android-host-view-gallery-demo-plan.md)
- Current state: [reports/2026-06-09-android-host-current-state.md](../reports/2026-06-09-android-host-current-state.md)
- Framework gap register: `swift-tui/docs/VISION-GAP.md` (Android host section)
- Android NDK — JNI registration / native-lib packaging: <https://developer.android.com/ndk/guides>
- Prefab (native AAR interchange): <https://google.github.io/prefab/>
- Android AAR / `maven-publish`: <https://developer.android.com/build/publish-library>
