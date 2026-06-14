# Android host library — Phase B publication plan

- **Date:** 2026-06-14
- **Status:** Proposed; decisions ratified 2026-06-14. Phase B of the Android
  host-library extraction. Follows the landed Phase A
  (`swift-tui-examples@7b96daa`).
- **Promotes:** [proposals/2026-06-14-001-android-host-library-extraction-proposal.md](../proposals/2026-06-14-001-android-host-library-extraction-proposal.md)
  (Phase B), [plans/2026-06-14-002-android-host-library-phase-a-extraction-plan.md](2026-06-14-002-android-host-library-phase-a-extraction-plan.md)
- **Scope:** populate the (empty) `swift-tui-android` submodule; publish the AAR
  + Gradle plugin publicly; cut the example over; wire the org. Consciously
  freezes a `0.x` ABI.

## 1. Decisions — ratified 2026-06-14

| # | Decision | Choice | Notes |
| --- | --- | --- | --- |
| P1 | How far now | **B2 — full public release.** Move + wire + publish a tagged `0.1.0`. | Accepts `0.x` ABI churn (the frame protocol is still JSON; the C ABI is young). |
| P2 | AAR contents | **Plugin-copied runtime.** AAR = JNI shim + Kotlin + `consumer-rules.pro` only (~hundreds of KB); the convention plugin copies the Swift runtime from the consumer's own SDK. | Refines the proposal's Design §1 default. Runtime always matches the consumer's toolchain → the Design §4 mismatch risk ~dissolves. AAR is tiny. |
| P3 | Distribution | **Maven Central** (AAR) + **Gradle Plugin Portal** (plugin). Rule out GitHub Packages (public reads still need auth). | Frictionless consumer: one dependency + one plugin line, no extra repo. |
| P4 | Version | **0.1.0**, AAR + plugin versioned together. | Coupled; `0.x` signals instability. |
| P5 | Gate | Org-root Bazel **JVM-test gate** now; emulator smoke stays the manual lane. | No GitHub Actions infra exists in the org yet; full emulator CI is a fast-follow, not a `0.1.0` blocker. |

**Deferred (post-0.1.0):** the ergonomic Swift macro `#SwiftTUIAndroidHost(MyRootView())`
(Design §3), the x86_64 ABI, and Prefab (Design §1) — none block `0.1.0`.

## 2. The credentials split — what's blocked on whom

The publish **machinery** is fully buildable and verifiable locally; the **public
publish** needs accounts only the maintainer controls. The plan is split so all
non-credential work lands and is proven via `publishToMavenLocal` first.

- **B2a — buildable now (no credentials):** seed the repo, build config, publish
  config (reading secrets from env), example cutover with a coordination-owned
  pre-tag override, org wiring, the gate, docs. **Verified by `publishToMavenLocal`
  + the example building against the local artifact + the arm64 emulator smoke.**
- **B2b — gated on maintainer credentials:** Sonatype Central namespace
  `sh.swifttui` (verified via the `swifttui.sh` domain), a GPG signing key, and a
  Gradle Plugin Portal API key. The maintainer supplies these (env/CI secrets)
  and runs (or CI runs) the signed `publish` + pushes the `v0.1.0` tag.

## 3. Plan

### Step 1 — Seed `swift-tui-android` (B2a)
- [ ] Move `:swift-tui-host` + `build-logic` from `swift-tui-examples/AndroidGallery`
  into the `swift-tui-android` repo as a standalone Gradle build (root
  `settings.gradle.kts`, `build.gradle.kts`, `gradle.properties`, wrapper,
  `.gitignore`, README).
- [ ] Module `:swift-tui-host` (Maven artifactId **`android-host`**); the
  convention plugin id stays **`sh.swifttui.android`**.
- [ ] Add `MODULE.bazel` (`module(name = "swift_tui_android", …)`) so it is a
  Bazel module like every sibling.
- [ ] `bazel`/Gradle build green standalone; the existing 5 JVM tests pass.

### Step 2 — Publish config (B2a)
- [ ] AAR: `maven-publish` + `signing` (GPG), coordinates
  `sh.swifttui:android-host:0.1.0`; complete POM (name, description, license,
  scm = `swift-tui-android`, developers, url = `https://swifttui.sh`).
- [ ] Plugin: `com.gradle.plugin-publish` for `sh.swifttui.android` `0.1.0`
  (Plugin Portal), with plugin metadata (display name, description, tags, vcsUrl).
- [ ] Sign + credentials read from env/`gradle.properties` secrets (never
  committed); document the required keys.
- [ ] **Verify:** `publishToMavenLocal` produces the AAR (confirm payload =
  shim + Kotlin + `consumer-rules.pro`, **no** Swift runtime) and the plugin
  marker in `~/.m2`.

### Step 3 — Cut the example over (B2a)
- [ ] Delete the in-tree `:swift-tui-host` + `build-logic` from `AndroidGallery`
  (single source of truth now in `swift-tui-android`).
- [ ] Example consumes the **tagged Maven coordinates** in its committed
  manifest: `implementation("sh.swifttui:android-host:0.1.0")` +
  `plugins { id("sh.swifttui.android") version "0.1.0" }`. (Public child repos
  consume siblings only via tagged artifacts — invariant.)
- [ ] **Pre-tag dev resolution is coordination-owned, not committed to the
  example.** The overlay injects a Gradle init script / `pluginManagement` +
  `dependencyResolutionManagement` override that substitutes the local
  `swift-tui-android` build (composite `includeBuild`, or `mavenLocal()`) for the
  not-yet-tagged `0.1.0`. This is the Maven analog of Phase A's
  `configureSwiftPackageMirrors`. Lives in the root overlay only.
- [ ] **Verify:** with the override active, `:app:assembleDebug` + the arm64
  emulator smoke pass exactly as in Phase A (gallery paints).

### Step 4 — Org wiring (B2a)
- [ ] Bump the `swift-tui-android` submodule pin to the seeded commit.
- [ ] `MODULE.bazel`: add `bazel_dep(name = "swift_tui_android", version = …)` +
  `local_path_override(module_name = "swift_tui_android", path = "swift-tui-android")`.
- [ ] Add the 5th repo-model row to `AGENTS.md`
  (`swift-tui-android` | `SwiftTUI/swift-tui-android` | Gradle/Maven AAR | `swift_tui_android`).
- [ ] Add a Bazel native-gate target (e.g. `//:android_host_native_gate`)
  running the JVM tests; wire it into `//:native_gates` / `//:org_full`.

### Step 5 — Docs (B2a)
- [ ] Retire the non-goal "No public AAR publication before the demo app and ABI
  stabilize."
- [ ] Update `swift-tui/docs/HOSTS-AND-PLATFORMS.md` + the examples README to
  point at the published artifact.
- [ ] Write a consumer guide: "Embed SwiftTUI in your Android/Compose app" —
  apply the plugin, add the dependency, write the ~10-line Swift entry over your
  root `View`, `SwiftTUIHostView()`.

### Step 6 — Public publish (B2b — maintainer-gated)
- [ ] Maintainer: register the `sh.swifttui` Sonatype Central namespace (verify
  `swifttui.sh`), generate the GPG key, create the Plugin Portal API key; load
  them as secrets.
- [ ] Run the signed `publishAllPublicationsToMavenCentral` + `publishPlugins`;
  push the `v0.1.0` tag in `swift-tui-android`.
- [ ] Remove the overlay pre-tag override; confirm the example resolves `0.1.0`
  from the **public** Maven Central + Plugin Portal (fresh `~/.m2`, no override).

## 4. Verification & completion criteria

- [ ] **B2a:** `swift-tui-android` builds standalone; 5 JVM tests pass; the AAR
  (mavenLocal) carries only shim + Kotlin + R8 rules (no runtime); the example,
  via the overlay override, assembles and paints on the arm64 emulator.
- [ ] **Org gate:** `//:android_host_native_gate` green; `//:org_full` green.
- [ ] **B2b (release):** a fresh external Android app embeds a SwiftTUI view by
  adding one Maven dependency + applying one Gradle plugin + writing one Swift
  entry, with **no files copied** out of any SwiftTUI repo, resolving everything
  from public Maven Central + Plugin Portal.

## 5. Risks

- **`0.x` ABI freeze (accepted).** The frame protocol is still JSON and couples
  the AAR's Kotlin parser to a `swift-tui` version. `0.x` semver communicates
  instability; document the AAR↔`swift-tui` version expectation in the consumer
  guide. A later binary-protocol switch is a breaking `0.x` bump.
- **Pre-tag override leakage.** The dev-time local substitution must live only in
  the coordination root/overlay; the public example manifest must ship tagged
  coords. A committed `mavenLocal()`/`includeBuild` in the example would break a
  fresh public clone — guard against it.
- **Credential setup is the critical path to B2b** and is entirely maintainer-side;
  B2a should be fully green first so the only remaining variable is signing/publishing.
- **AAR↔plugin version skew.** Always release the AAR and plugin together at the
  same version; a consumer mixing versions could hit a frame-format mismatch.

## 6. Source links

- Proposal (Phase B source): [proposals/2026-06-14-001-android-host-library-extraction-proposal.md](../proposals/2026-06-14-001-android-host-library-extraction-proposal.md)
- Phase A plan (landed): [plans/2026-06-14-002-android-host-library-phase-a-extraction-plan.md](2026-06-14-002-android-host-library-phase-a-extraction-plan.md)
- Maven Central publishing: <https://central.sonatype.org/publish/publish-portal-gradle/>
- Gradle Plugin Portal publishing: <https://plugins.gradle.org/docs/publish-plugin>
