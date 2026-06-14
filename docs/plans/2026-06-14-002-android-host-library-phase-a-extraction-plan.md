# Android host library — Phase A internal-extraction plan

- **Date:** 2026-06-14
- **Status:** **Phase A landed 2026-06-14** in `swift-tui-examples`
  (`7b96daa`); the three §2 decisions are ratified. Verified end-to-end: 28 JVM
  unit tests pass, library AAR + JNI shim build under `-Werror`, full
  `:app:assembleDebug`, APK payload carries the renamed host `.so` + the shim
  merged from the AAR, and the gallery launches/paints on the arm64 emulator.
  No new repo, no Maven, no public ABI freeze. Phase B remains gated.
- **Promotes:** [proposals/2026-06-14-001-android-host-library-extraction-proposal.md](../proposals/2026-06-14-001-android-host-library-extraction-proposal.md)
  (Phase A), with the decoupling gap and sequencing corrections found on review.
- **Depends on / follows:**
  [plans/2026-06-09-001-android-host-view-gallery-demo-plan.md](2026-06-09-001-android-host-view-gallery-demo-plan.md),
  [reports/2026-06-09-android-host-current-state.md](../reports/2026-06-09-android-host-current-state.md)
- **Scope:** entirely inside `swift-tui-examples/AndroidGallery`. Touches no other
  child repo. Does **not** populate the (intentionally empty) `swift-tui-android`
  submodule — that is Phase B.

## 1. Purpose

Turn the proposal's Phase A bullet list into an ordered, verifiable
implementation checklist, and close the three things the proposal underspecified:

1. The host-creation coupling is **three** app-name bindings, not one. The
   proposal's Design §3 addresses only the Swift `@_cdecl` symbol.
2. The package rename and the `RegisterNatives` switch are **mutually dependent**
   and must land as one atomic change (implicit `Java_…` mangling guarantees it).
3. "Verify the same APK payload" needs a falsifiable check, or it is unprovable.

The goal of Phase A is to **prove the consumer boundary with zero copy-paste**
while keeping everything internal to `swift-tui-examples` and reversible. After
Phase A, an external consumer is a copy of `:app` (`MainActivity` + a one-line
Swift entry + their root `View`), never a copy of the host internals.

## 2. Decisions — ratified 2026-06-14

The proposal's three open questions, now decided. Steps 2–3 depend on all three.

| # | Decision | Ratified choice | Why |
| --- | --- | --- | --- |
| D1 | Library module + namespace | module `:swift-tui-host`; Kotlin package + library `namespace = "sh.swifttui.android.host"` (example app keeps `applicationId = "org.swifttui.gallery.android"`) | Matches the `swifttui.sh` domain, the `sh.swifttui.android` plugin id, and the eventual Maven group `sh.swifttui`. The package rename is what *forces* D3's binding switch. |
| D2 | How the JNI finds the consumer's Swift `.so` | **Canonical name, plugin-renamed.** The convention plugin standardizes the built Swift `.so` to `libswift_tui_app_host.so` in `jniLibs`; the library `dlopen`s that constant (overridable via a plugin property). The library never references `libGalleryAndroidHost.so`. | Zero consumer config — best serves "0 artifacts copied or configured." The plugin already owns `.so` placement (`copySwiftAndroidLibraries`), so it owns the name. Safe: the host `.so` is `dlopen`'d by path, never `DT_NEEDED`'d, so its soname is irrelevant after the rename. |
| D3 | Create-symbol binding | Fixed `@_cdecl("swift_tui_android_create_host")`; all natives bound via `JNI_OnLoad`/`RegisterNatives`; symbols resolved by **`dlsym`** (not link-time). | Removes app-specific `…_create_gallery_host`; `RegisterNatives` dissolves the package-mangled-symbol fallout from D1. `dlsym` is **forced, not preferred**: a Phase-B AAR ships the shim *prebuilt*, but the consumer's Swift `.so` is built later/per-app, so a prebuilt shim can only resolve those symbols at runtime — choosing `dlsym` now keeps the binding model identical across Phase A→B. |

Only the **create** symbol and the **`.so` name** were app-coupled; D2 and D3
remove both. The 7 handle ABI symbols (`swift_tui_android_start`, `…_stop`,
`…_destroy`, `…_resize`, `…_copy_latest_frame`, `…_copy_clipboard_text`,
`…_send_input`) are framework-owned — they come from `SwiftTUIAndroidHost` in
`swift-tui` and stay hardcoded in the shim, resolved from the same cached
`dlopen` handle as today.

## 3. Corrected coupling analysis (measured against `HEAD`)

The Kotlin layer is **already partly decoupled**, which the proposal does not
note: `SwiftTUIHostState(createHost: () -> Long, clipboard)` takes the host
factory as an injected lambda
(`AndroidGallery/app/src/main/kotlin/.../SwiftTUIHostState.kt:23`). The only
gallery-specific Kotlin is the convenience composable
`rememberSwiftTUIHostState()` (`…:165`), which hardwires
`createHost = { SwiftTUIJni.createGalleryHost() }` (`…:169`).

So the real app-name couplings are confined to the JNI/C++ layer and one Kotlin
convenience function:

| # | Coupling (file:evidence) | Phase A fix |
| --- | --- | --- |
| C1 | C symbols `Java_org_swifttui_gallery_android_SwiftTUIJni_*` (8 fns, `swift_tui_jni.cpp:66,80,92,104,116,138,173,208`) bake in the gallery package | Switch to `JNI_OnLoad`/`RegisterNatives`; symbol names stop mattering (atomic with D1 rename) |
| C2 | `dlopen("libGalleryAndroidHost.so")` (`swift_tui_jni.cpp:11,24`) | Canonical `libswift_tui_app_host.so` per D2; plugin renames on copy, library holds no app `.so` name |
| C3 | `dlsym("swift_tui_android_create_gallery_host")` (`swift_tui_jni.cpp:71`) + `SwiftTUIJni.createGalleryHost()` external + `GalleryAndroidHost.swift:13` `@_cdecl` | Rename Swift `@_cdecl` to `swift_tui_android_create_host`; library resolves the fixed name per D3 |
| C4 | `rememberSwiftTUIHostState()` hardwires the gallery binding (`SwiftTUIHostState.kt:165–172`) | Move this convenience composable to `:app`, or parameterize it to accept `createHost`; the decoupled `SwiftTUIHostState` class stays in the library |

`SwiftTUIHostState`, the 10 other `SwiftTUI*.kt`, and the JNI shim are otherwise
app-agnostic and move unchanged except for the package line.

## 4. Implementation checklist (ordered)

### Step 0 — Pin decisions
- [ ] Record D1/D2/D3 choices (table §2) at the top of the implementation PR.

### Step 1 — Create the library module
- [ ] Add `:swift-tui-host` to `AndroidGallery/settings.gradle.kts` (today only
  `include(":app")`).
- [ ] New `swift-tui-host/build.gradle.kts`: `com.android.library` +
  `org.jetbrains.kotlin.plugin.compose` (AGP 9.2.1 / Kotlin compose plugin
  2.2.10, matching the app); `namespace`, `minSdk = 28`, `ndkVersion =
  "27.3.13750724"` per D1 and the existing app pins.

### Step 2 — Move the reusable host (atomic with Step 3)
- [ ] Move the 11 `SwiftTUI*.kt` files + `src/main/jni/{swift_tui_jni.cpp,
  Android.mk,Application.mk}` into `:swift-tui-host`.
- [ ] Rename the Kotlin package to D1's package across the moved files.
- [ ] Resolve C4: relocate or parameterize `rememberSwiftTUIHostState()` so the
  library exposes the decoupled `SwiftTUIHostState`/`SwiftTUIHostView` seam and
  the gallery binding lives in `:app`.

### Step 3 — Harden + decouple the JNI (atomic with Step 2)
- [ ] Implement `JNI_OnLoad` + `RegisterNatives` for all 8 natives (C1). This
  must land in the same change as the package rename — implicit `Java_…` binding
  breaks the instant the package moves.
- [ ] Replace the hardcoded `kGalleryLibrary` with the canonical
  `libswift_tui_app_host.so` constant per D2 (C2); the plugin's `.so` copy step
  (Step 4) renames the built Swift product to that name.
- [ ] Rename the Swift `@_cdecl` to `swift_tui_android_create_host` in
  `GalleryAndroidHost.swift`; library resolves the fixed name per D3 (C3).
- [ ] Add `consumer-rules.pro` to `:swift-tui-host` keeping `SwiftTUIJni` and its
  `external` members so a consumer's R8 pass cannot strip/rename JNI-bound
  methods (silent breakage otherwise).

### Step 4 — Extract the build logic into a convention plugin
- [ ] Add a `build-logic` included build with a convention plugin (proposed id
  `sh.swifttui.android`).
- [ ] Move `buildSwiftAndroid`, `copySwiftAndroidLibraries`,
  `prepareSwiftSdkSearchPath` (`app/build.gradle.kts:184,236,65`) into it.
- [ ] In the moved `copySwiftAndroidLibraries`, rename the built Swift product
  `.so` to the canonical `libswift_tui_app_host.so` as it lands in `jniLibs`
  (D2); expose the target name as a plugin property for override.
- [ ] Keep `configureSwiftPackageMirrors` and `abiFilters += "arm64-v8a"` as
  plugin **defaults / overlay-only** wiring (coordination-only; not a public
  consumer requirement).
- [ ] Both `:app` and `:swift-tui-host` apply the plugin.

### Step 5 — Make `:app` a thin consumer
- [ ] `:app` depends on `:swift-tui-host`; retains only `MainActivity`, the
  (now `…_create_host`) Swift entry, `GalleryView()`, and the gallery binding
  from C4.
- [ ] Confirm no `SwiftTUI*.kt`, no JNI source, and none of the three Swift
  build tasks remain inline in `app/`.

### Step 6 — Verify (see §5)

## 5. Verification & completion criteria

Toolchain note: per the Android architecture memory, `./gradlew
testDebugUnitTest` is NDK-free and runs the JVM unit tests standalone, but
`assembleDebug` + the emulator smoke require the full Android + swift-android
cross toolchain and the arm64 AVD installed. State this as an execution
prerequisite; it is not a planning gap.

- [ ] **JVM unit tests pass** unchanged after the move:
  `SwiftTUIBoxDrawingTest`, `SwiftTUIDamagePlanTest`, `SwiftTUIFrameTest`,
  `SwiftTUIImeTest`, `SwiftTUIInputTest` (now under `:swift-tui-host`).
- [ ] **Same-APK-payload check (falsifiable).** Capture
  `unzip -l app-debug.apk | grep 'lib/arm64-v8a/'` before and after. The packaged
  `.so` set must differ by **exactly one expected delta** from the D2 rename —
  `libGalleryAndroidHost.so` → `libswift_tui_app_host.so` — with
  `libswift_tui_jni.so`, `libc++_shared.so`, and the Swift runtime libs
  unchanged. Any other difference fails the check. Record the diff in the PR.
- [ ] **arm64 emulator smoke** on `SwiftTUI_AndroidGallery_api35_medium_arm64`
  (manual foreground process per the current-state report): install, launch
  returns `Status: ok`, process stays alive, first `GalleryView()` frame paints.
  Manual is acceptable for Phase A; automation is Phase B.
- [ ] **Completion:** `:app` contains no reusable host code — only `MainActivity`
  + the Swift entry + `GalleryView()` + the create binding; the host lives in
  `:swift-tui-host` + the convention plugin it consumes; the three checks above
  are green.

## 6. Risks

- **Atomicity of Steps 2–3.** Doing the package rename without `RegisterNatives`
  in the same change yields link-time-clean but runtime-unresolved natives. Land
  them together; the same-APK-payload check will not catch this (it is a load
  check, not a payload check) — the emulator smoke is the guard.
- **R8 in the consumer.** Without `consumer-rules.pro`, a consumer's release
  build can strip JNI-bound members silently. Ship it in Step 3, not Phase B.
- **Canonical `.so` rename.** The plugin must rename the built Swift product to
  `libswift_tui_app_host.so` as it copies into `jniLibs`; the same-APK-payload
  check (§5) must therefore expect the new name, not `libGalleryAndroidHost.so`.
  The rename is `dlopen`-safe (resolved by path; soname is unused for a
  non-`DT_NEEDED` library).
- **No scope creep into Phase B.** No Maven, no `swift-tui-android` population,
  no toolchain-compat manifest, no Prefab, no x86_64 — all explicitly deferred.

## 7. Out of scope (Phase B — gated, not in this plan)

Per the proposal, Phase B is gated on the frame-protocol decision (JSON vs
binary), a green automated Android gate, and ABI stability. Promotion of
`:swift-tui-host` into the empty `swift-tui-android` submodule, AAR/plugin
publication, `.so` bundling + toolchain-compat assertion, Prefab, and x86_64 all
belong to Phase B and are intentionally excluded here.

## 8. Source links

- Proposal (Phase A source): [proposals/2026-06-14-001-android-host-library-extraction-proposal.md](../proposals/2026-06-14-001-android-host-library-extraction-proposal.md)
- Current state: [reports/2026-06-09-android-host-current-state.md](../reports/2026-06-09-android-host-current-state.md)
- Host plan: [plans/2026-06-09-001-android-host-view-gallery-demo-plan.md](2026-06-09-001-android-host-view-gallery-demo-plan.md)
- Android NDK — JNI registration / native packaging: <https://developer.android.com/ndk/guides>
- Android AAR / `maven-publish` (Phase B): <https://developer.android.com/build/publish-library>
