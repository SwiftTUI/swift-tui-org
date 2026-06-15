# Android host library — Phase B publication plan

- **Date:** 2026-06-14
- **Status:** **B2a shipped 2026-06-15.** Decided (during execution) to release
  credential-free at the org's coordinated version **`0.0.19`** via a GitHub
  Pages static Maven repo for **both** the AAR and the plugin (Plugin Portal /
  Maven Central deferred to a later graduation). Done: `swift-tui-android` seeded
  + tagged `0.0.19` + `gh-pages` live; AndroidGallery consumes the published
  artifacts (verified resolving from the public URL with no override); org wired
  (5th submodule + Bazel module + `//:native_gates` gate); docs. The only thing
  not done is the optional emulator CI lane (manual smoke stands).
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
| P3 | Distribution | **Static Maven repo on GitHub Pages** (AAR) + **Gradle Plugin Portal** (plugin); **Maven Central is a later graduation**. Rule out GitHub Packages (public reads still need auth). | No GPG/Sonatype now: Pages serves unsigned static artifacts I build locally (NDK present, so none of JitPack's build-the-`.so`-on-their-servers problem). Consumer adds one `maven { url }` line for the AAR; the plugin resolves from the default `gradlePluginPortal()`. |
| P4 | Version | **0.1.0**, AAR + plugin versioned together. | Coupled; `0.x` signals instability. |
| P5 | Gate | Org-root Bazel **JVM-test gate** now; emulator smoke stays the manual lane. | No GitHub Actions infra exists in the org yet; full emulator CI is a fast-follow, not a `0.1.0` blocker. |

**Deferred (post-0.1.0):** the ergonomic Swift macro `#SwiftTUIAndroidHost(MyRootView())`
(Design §3), the x86_64 ABI, and Prefab (Design §1) — none block `0.1.0`.

## 2. The credentials split — what's blocked on whom

The publish **machinery** is fully buildable and verifiable locally; the **public
publish** needs accounts only the maintainer controls. The plan is split so all
non-credential work lands and is proven via `publishToMavenLocal` first.

- **B2a — buildable now (no credentials):** seed the repo, build config, publish
  config, example cutover with a coordination-owned pre-tag override, org wiring,
  the gate, docs. **Verified by `publishToMavenLocal` + the example building
  against the local artifact + the arm64 emulator smoke.**
- **B2b — gated on a single maintainer credential.** GitHub Pages serves the AAR
  as unsigned static files I build locally, so there is **no Sonatype namespace
  and no GPG key** for `0.1.0` — only a **Gradle Plugin Portal API key** (for the
  plugin), plus **enabling Pages** on `swift-tui-android` (repo push, which the
  maintainer already has). The maintainer supplies the Portal key and runs (or CI
  runs) `publishPlugins` + pushes the AAR to the Pages branch + the `v0.1.0` tag.

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
- [ ] AAR: `maven-publish`, coordinates `sh.swifttui:android-host:0.1.0`; complete
  POM (name, description, license, scm = `swift-tui-android`, developers,
  url = `https://swifttui.sh`). **No `signing` block for `0.1.0`** — Pages serves
  unsigned artifacts (signing is added only at the Maven Central graduation), but
  keep the POM Central-ready so graduation is just a publish-target change.
- [ ] Serve the AAR as a **static Maven repo layout** from GitHub Pages:
  `maven-publish` writes to a local repo dir, which a publish step pushes to the
  `gh-pages` branch of `swift-tui-android` (a `git worktree`, or the
  `org.ajoberstar.git-publish` plugin), **appending** to prior versions, not
  clobbering. Public URL: `https://swifttui.github.io/swift-tui-android`.
- [ ] Plugin: `com.gradle.plugin-publish` for `sh.swifttui.android` `0.1.0`
  (Plugin Portal), with plugin metadata (display name, description, tags, vcsUrl);
  the Portal API key is read from env/`gradle.properties` (never committed).
- [ ] **Verify:** `publishToMavenLocal` produces the AAR (confirm payload =
  shim + Kotlin + `consumer-rules.pro`, **no** Swift runtime); a dry-run publish
  populates the local static-repo dir with the expected layout.

### Step 3 — Cut the example over (B2a)
- [ ] Delete the in-tree `:swift-tui-host` + `build-logic` from `AndroidGallery`
  (single source of truth now in `swift-tui-android`).
- [ ] Example consumes the **published artifacts** in its committed manifest: add
  the Pages repo `maven { url = uri("https://swifttui.github.io/swift-tui-android") }`
  to `dependencyResolutionManagement` + `implementation("sh.swifttui:android-host:0.1.0")`;
  apply `id("sh.swifttui.android") version "0.1.0"` (resolves from the default
  `gradlePluginPortal()`). (Public child repos consume siblings only via published
  artifacts — invariant.)
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
- [ ] Maintainer one-time: enable **GitHub Pages** on `swift-tui-android` (serve
  the `gh-pages` branch) and create a **Gradle Plugin Portal API key**; load the
  Portal key as a secret. (No Sonatype, no GPG for `0.1.0`.)
- [ ] Publish: push the built AAR's static-repo layout to the `gh-pages` branch;
  run `publishPlugins`; push the `v0.1.0` tag in `swift-tui-android`.
- [ ] Remove the overlay pre-tag override; confirm the example resolves `0.1.0`
  from the **public** Pages repo + Plugin Portal (fresh clone, empty caches, no
  override).

## 4. Verification & completion criteria

- [ ] **B2a:** `swift-tui-android` builds standalone; 5 JVM tests pass; the AAR
  (mavenLocal) carries only shim + Kotlin + R8 rules (no runtime); the example,
  via the overlay override, assembles and paints on the arm64 emulator.
- [ ] **Org gate:** `//:android_host_native_gate` green; `//:org_full` green.
- [ ] **B2b (release):** a fresh external Android app embeds a SwiftTUI view by
  adding the Pages Maven repo + one dependency + applying one Gradle plugin +
  writing one Swift entry, with **no files copied** out of any SwiftTUI repo,
  resolving everything from the public GitHub Pages repo + Plugin Portal.

## 5. Risks

- **`0.x` ABI freeze (accepted).** The frame protocol is still JSON and couples
  the AAR's Kotlin parser to a `swift-tui` version. `0.x` semver communicates
  instability; document the AAR↔`swift-tui` version expectation in the consumer
  guide. A later binary-protocol switch is a breaking `0.x` bump.
- **Pre-tag override leakage.** The dev-time local substitution must live only in
  the coordination root/overlay; the public example manifest must ship tagged
  coords. A committed `mavenLocal()`/`includeBuild` in the example would break a
  fresh public clone — guard against it.
- **Static-repo distribution trade-offs.** Pages serves unsigned artifacts and
  makes consumers add one `maven { url }` line (vs Central's zero-config
  `mavenCentral()`); the `gh-pages` branch must accumulate the Maven layout across
  releases (append, never clobber prior versions). The only B2b credential is the
  Plugin Portal key, so the path to release is short.
- **Maven Central graduation (later).** When the ABI stabilizes, re-publish the
  same coordinates to Central (adds the Sonatype namespace + GPG signing); consumers
  then drop the Pages repo line. Keeping the POM/coordinates Central-ready now makes
  graduation only a publish-target change.
- **AAR↔plugin version skew.** Always release the AAR and plugin together at the
  same version; a consumer mixing versions could hit a frame-format mismatch.

## 6. Source links

- Proposal (Phase B source): [proposals/2026-06-14-001-android-host-library-extraction-proposal.md](../proposals/2026-06-14-001-android-host-library-extraction-proposal.md)
- Phase A plan (landed): [plans/2026-06-14-002-android-host-library-phase-a-extraction-plan.md](2026-06-14-002-android-host-library-phase-a-extraction-plan.md)
- GitHub Pages static Maven repo (git-publish): <https://github.com/ajoberstar/gradle-git-publish>
- Gradle Plugin Portal publishing: <https://plugins.gradle.org/docs/publish-plugin>
- Maven Central (later graduation): <https://central.sonatype.org/publish/publish-portal-gradle/>
