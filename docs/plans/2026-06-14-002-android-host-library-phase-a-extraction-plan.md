# Android host library — Phase A internal-extraction plan

- **Date:** 2026-06-14
- **Status:** Proposed. Execution-ready task plan for **Phase A only** of the
  extraction proposal. No new repo, no Maven, no public ABI freeze.
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

## 2. Decisions to pin before writing code

These are the proposal's open questions, resolved here with a recommendation so
execution does not stall. Adjust if you disagree, but pin them first — steps 2–3
depend on all three.

| # | Decision | Recommendation | Why |
| --- | --- | --- | --- |
| D1 | Library Gradle module + package | module `:swift-tui-host`; Kotlin package **`sh.swifttui.android.host`**; library `namespace = "sh.swifttui.android.host"` | Neutral, app-agnostic; matches the proposed `sh.swifttui.android` plugin id family. The package rename is what *forces* D3's binding switch. |
| D2 | Which Swift product `.so` the JNI loads | **Parameterize, don't hardcode.** The consumer names their own Swift product lib; the library never references `libGalleryAndroidHost.so`. | The consumer's Swift entry compiles to a per-app `.so` name. A reusable library cannot bake in the gallery's name (cpp `kGalleryLibrary` today). |
| D3 | Create-symbol binding | Fixed convention `@_cdecl("swift_tui_android_create_host")`, resolved by the library; bind all natives via `JNI_OnLoad`/`RegisterNatives`. Defer the `dlsym` vs link-time choice — `RegisterNatives` makes either safe. | Removes the app-specific `…_create_gallery_host`; `RegisterNatives` also dissolves the package-mangled-symbol problem D1 creates. |

For **D2**, the recommended concrete mechanism: the consumer calls
`System.loadLibrary("<theirSwiftHostLib>")` (they know their own product name),
and the library's JNI resolves the create symbol from the already-loaded image
— either via a lib-name `String` passed through the `createHost` path into the
shim's `dlopen`, or via `dlsym(RTLD_DEFAULT, "swift_tui_android_create_host")`.
Decide the exact form in step 3; both keep the library name-agnostic.

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
| C2 | `dlopen("libGalleryAndroidHost.so")` (`swift_tui_jni.cpp:11,24`) | Parameterize per D2; library holds no app `.so` name |
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
- [ ] Remove the hardcoded `kGalleryLibrary`; parameterize the loaded Swift
  product per D2 (C2).
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
  `unzip -l app-debug.apk | grep 'lib/arm64-v8a/'` before and after; the set of
  packaged `.so`s (host lib, `libswift_tui_jni.so`, `libc++_shared.so`, Swift
  runtime libs) must be identical. Record the diff (expected: empty) in the PR.
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
- **D2 mechanism choice.** `RTLD_DEFAULT` resolution depends on the consumer
  having `System.loadLibrary`-ed their Swift host before host creation;
  the lib-name-parameter form avoids that ordering assumption. Pick one in Step 3
  and document the consumer contract.
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
