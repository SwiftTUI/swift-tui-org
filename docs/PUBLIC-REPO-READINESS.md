# Public Repository Readiness

This tracks the public pre-release cutover for the SwiftTUI child
repositories.

Current status checked on 2026-05-31:

- `SwiftTUI/swift-tui`, `SwiftTUI/swift-tui-web`,
  `SwiftTUI/swift-tui-examples`, and `SwiftTUI/swift-tui-site` are public.
- Each child repo has a pushed `0.0.7` tag.
- `swift-tui-web` has a public GitHub `0.0.7` release with
  `swifttui-web-0.0.7.tgz` and `swifttui-build-0.0.7.tgz` assets.
- `@swifttui/web` and `@swifttui/build` are published to npm (public) at
  `0.0.7`.
- `swift-tui-examples` resolves `swift-tui` through the `0.0.7` HTTPS SwiftPM
  tag and resolves web packages through the `swift-tui-web` `0.0.7` release
  tarballs.
- `swift-tui-site` resolves DocC from the `swift-tui` `0.0.7` tag and fetches
  tagged WebExample input into `.build/public-inputs/` by default.
- `//:public_dependency_contracts` is wired into `//:org_fast`.

## Required End State

- A fresh clone of each child repo builds with its native tools.
- Public child repos do not require `swift-tui-org`, Bazel, submodules, or a
  sibling checkout layout.
- Cross-repo dependencies in public child repos use public HTTPS tags, npm
  versions, or public release tarballs.
- Pre-tag cross-repo integration remains coordination-only through the overlay
  gates in this repo.

The current `0.0.18` state satisfies the public dependency shape with both
published npm packages (`@swifttui/web`, `@swifttui/build`) and GitHub release
tarballs for the web packages. Consumers may migrate from the tarball URLs to
the npm package versions when that becomes the preferred public install path.

## Updated On 2026-06-07 For 0.0.18

This release reconciled a version skew: `swift-tui` carried a solo `0.0.17` tag
(Shape API + breaking `refactor!` Canvas/CanvasContext redesign) that the rest
of the org never followed, and was 12 commits past it; web/examples/site/root
were still at `0.0.16`. The lockstep target `0.0.18` is one above the highest
existing tag (`swift-tui` `0.0.17`). The `bump_version.sh` tool was therefore
run in two passes (`--from 0.0.16` for the bulk, `--from 0.0.17` for the
`swift-tui` self-declarations and the already-`0.0.17` `gallery`/`gifeditor`
example pins).

1. Tagged and pushed all five repos at `0.0.18` (web `733dfb9`, swift-tui
   `97b599ca`, examples `b80e770`, site `7f892d5`, root `e49c781`).
2. Published the `swift-tui-web` GitHub `0.0.18` release assets for
   `@swifttui/web` and `@swifttui/build`, and published both packages to npm
   (public) at `0.0.18`.
3. Updated `swift-tui-examples` SwiftPM manifests, every `Package.resolved`, the
   shared Xcode package reference, README copy, Bun metadata, and WebExample
   tarball dependencies to `0.0.18`.
4. Updated `swift-tui-site` release metadata, DocC inputs, package metadata, and
   visible public links to `0.0.18`.
5. Bumped each module's declared version (`MODULE.bazel`, `package.json`) to
   `0.0.18`.
6. Updated this org root's Bzlmod dependency graph and submodule pins to the
   `0.0.18` child commits.

## 0.0.18 Verification Recorded

- `swift-tui-web`: `bun run ci` (83 pass, frozen-lockfile install after the
  `bun.lock` workspace-version sync); `bun pm pack` for both packages
  (verified the `build` tarball resolved `@swifttui/web` to the concrete
  `0.0.18`, not `workspace:*`); `npm publish` of `@swifttui/web@0.0.18` and
  `@swifttui/build@0.0.18`; GitHub `0.0.18` release asset upload of both
  tarballs (both download URLs return HTTP 200).
- `swift-tui-examples`: `swift package resolve` regenerated every
  `Package.resolved` against the `swift-tui` `0.0.18` tag (revision
  `97b599ca`); the shared Xcode `Package.resolved` was hand-bumped to the same
  revision/version; `bun install` refreshed `bun.lock` against the `0.0.18` web
  release tarballs (`--frozen-lockfile` passed); the `bun run check` native
  build gate was run over all examples.
- `swift-tui-site`: Website `bun install --frozen-lockfile` passed; `bun run
  prepare:webexample` printed `prepared swift-tui-examples 0.0.18` with no 404
  (cloning the examples `0.0.18` tag and fetching the `0.0.18` web tarballs).
- `swift-tui-org`: `bazel fetch //:org_full`; `bazel test //:org_fast
  --nocache_test_results` passed 4/4 (`pin_cleanliness`,
  `public_dependency_contracts`, `repo_registry_contract`, `submodule_status`).
- Cross-check: `npm view` confirms `@swifttui/web` and `@swifttui/build` at
  `0.0.18`; `git ls-remote` confirms the `0.0.18` tag on all five repos at the
  commits above.

## Updated On 2026-05-31 For 0.0.7

1. Tagged and pushed all child repos at `0.0.7`.
2. Published the `swift-tui-web` GitHub `0.0.7` release assets for
   `@swifttui/web` and `@swifttui/build`, and published both packages to npm
   (public) at `0.0.7`.
3. Updated `swift-tui-examples` SwiftPM manifests, Package.resolved files, Xcode
   package reference, README copy, Bun metadata, and WebExample tarball
   dependencies to `0.0.7`. Also declared the previously-missing
   `ThreeHostsDemoCoreTests` test target so the existing `three-hosts-demo`
   test suite is discovered by the examples gate (latent gap present since
   `0.0.6`).
4. Updated `swift-tui-site` release metadata, DocC inputs, package metadata, and
   visible public links to `0.0.7`.
5. Bumped each module's declared version (`MODULE.bazel`, `package.json`) to
   `0.0.7`.
6. Updated this org root's Bzlmod dependency graph and submodule pins to the
   `0.0.7` child commits.

## 0.0.7 Verification Recorded

- Baseline: `bazel test //:org_full` on the pre-release `0.0.6` pins passed
  10/11; the only failure was the latent `three-hosts-demo` "no tests found"
  gap (test file present since `0.0.6`, test target never declared), fixed in
  the `0.0.7` examples cutover.
- `swift-tui-web`: `bun run ci` (75 pass); `bun pm pack` for both packages;
  `npm publish` of `@swifttui/web@0.0.7` and `@swifttui/build@0.0.7`; GitHub
  `0.0.7` release asset upload of both tarballs.
- `swift-tui-examples`: `swift package resolve` regenerated every
  `Package.resolved` against the `swift-tui` `0.0.7` tag (revision
  `933d255f`); `xcodebuild -resolvePackageDependencies` updated the shared
  Xcode pin; `bun install` refreshed `bun.lock` against the `0.0.7` web release
  tarballs (`--frozen-lockfile` passed); the `three-hosts-demo` test suite
  passes; `minimal` build smoke-checked.
- `swift-tui-site`: Website `bun test` (4 pass, incl. the `0.0.7` WebExample
  clone-ref assertion) and `bun run check` (0 errors) passed.
- `swift-tui-org`: `bazel fetch //:org_full`; full `bazel test //:org_full`
  re-run against the recorded `0.0.7` submodule pins.

## Updated On 2026-05-31 For 0.0.6

1. Tagged and pushed all child repos at `0.0.6`.
2. Published the `swift-tui-web` GitHub `0.0.6` pre-release assets for
   `@swifttui/web` and `@swifttui/build`, and published both packages to npm
   (public) at `0.0.6`.
3. Updated `swift-tui-examples` SwiftPM manifests, Package.resolved files, Xcode
   package reference, README copy, Bun metadata, and WebExample tarball
   dependencies to `0.0.6`.
4. Updated `swift-tui-site` release metadata, DocC inputs, package metadata, and
   visible public links to `0.0.6`.
5. Bumped each module's declared version (`MODULE.bazel`, `package.json`) to
   `0.0.6`, realigning the Bzlmod/npm version declarations that had drifted
   behind the `0.0.4`/`0.0.5` child tags.
6. Updated this org root's Bzlmod dependency graph and submodule pins to the
   `0.0.6` child commits.

## 0.0.6 Verification Recorded

- `swift-tui-web`: `bun run test` (75 pass); `bun pm pack` for both packages;
  `npm publish --access public` of `@swifttui/web` and `@swifttui/build`;
  GitHub `0.0.6` release asset upload.
- `swift-tui-examples`: deterministic SwiftPM pin update (`Package.swift`
  `exact:`, `Package.resolved` revision/version, Xcode pin) against the
  `swift-tui` `0.0.6` tag; `bun install` refreshed `bun.lock` against the
  `0.0.6` web release tarballs; `bun install --frozen-lockfile` passed.
- `swift-tui-org`: `bazel fetch //:org_full`; `bazel test //:org_fast`
  (`--nocache_test_results`) passed after recording the `0.0.6` submodule pins.

## Updated On 2026-05-27 For 0.0.3

1. Tagged and pushed all child repos at `0.0.3`.
2. Published the `swift-tui-web` GitHub `0.0.3` pre-release assets for
   `@swifttui/web` and `@swifttui/build`.
3. Updated `swift-tui-examples` SwiftPM manifests, Package.resolved files, Xcode
   package reference, README copy, Bun metadata, and WebExample tarball
   dependencies to `0.0.3`.
4. Updated `swift-tui-site` release metadata, DocC inputs, package metadata, and
   visible public links to `0.0.3`.
5. Updated this org root's Bzlmod dependency graph and submodule pins to the
   `0.0.3` child commits.

## 0.0.3 Verification Recorded

- `swift-tui`: `bun run test` initially failed only on a stale public API
  baseline; `Scripts/generate_public_api_inventory.sh` regenerated it and
  `Scripts/generate_public_api_inventory.sh --check` passed.
- `swift-tui-web`: `bun run ci`; clean `bun pm pack` outputs; GitHub
  pre-release asset upload.
- `swift-tui-examples`: SwiftPM package resolution across examples; Xcode
  package resolution; `bun install --frozen-lockfile`; `bun run check`;
  `git diff --check`.
- `swift-tui-site`: `bun install --cwd Website --frozen-lockfile`;
  `bun run --cwd Website check`; `Scripts/check_site.sh` against overlay input;
  `env -u WEBEXAMPLE_DIR Scripts/check_site.sh` against public `0.0.3` inputs;
  `git diff --check`.

## 0.0.1 Cutover Completed On 2026-05-27

1. Preserved existing repository history; no squash, rewrite, or replacement
   history was used for the public pre-release.
2. Tagged and pushed child repos at `0.0.1`.
3. Packed `@swifttui/web` and `@swifttui/build`, verified tarball install
   behavior, and attached both tarballs to the public `swift-tui-web` GitHub
   `0.0.1` pre-release.
4. Updated `swift-tui-examples` public defaults, README, scripts, CI workflow,
   SwiftPM manifests, Xcode package reference, lockfiles, and WebExample
   package metadata to use public `0.0.1` dependencies.
5. Updated `swift-tui-site` public defaults, release metadata, README/agent
   instructions, workflows, and build scripts so the default site build fetches
   public tagged inputs instead of requiring sibling checkouts.
6. Added `:public_dependency_contracts` to `//:org_fast`.

## 0.0.1 Verification Recorded

- `swift-tui`: `bun run test`; public API baseline regenerated and
  `Scripts/generate_public_api_inventory.sh --check`; `git diff --check`.
- `swift-tui-web`: `bun run ci`; clean `bun pm pack` outputs; local `npm
  install` from both tarballs; GitHub release asset upload.
- `swift-tui-examples`: SwiftPM package resolution; Xcode package resolution;
  `Scripts/check_examples_ci_workflow.sh`;
  `Scripts/check_examples_scratch_path_test.sh`; `bun install
  --frozen-lockfile`; `bun run check:focused`; `Scripts/check_examples_web.sh
  --skip-clean`; `git diff --check`.
- `swift-tui-site`: `Scripts/check_site_ci_workflow.sh`; `Scripts/check_site.sh`
  against public `0.0.1` inputs; `git diff --check`.
- `swift-tui-org`: `tools/bin/bazel test //:public_dependency_contracts` passed.
  The `mise exec -- bazel ...` wrapper hung before invoking Bazel in this run,
  so the repo-local Bazelisk wrapper was used.
- `swift-tui-org`: `tools/bin/bazel test //:org_fast` passed with
  `:public_dependency_contracts` included.

## Remaining Follow-Ups

- `@swifttui/web` and `@swifttui/build` are now published to npm (public) at
  `0.0.7`. Optionally replace the GitHub release tarball URLs in consumers
  (`swift-tui-examples` WebExample + workspace override) with npm package
  versions if that becomes the preferred public install path.
- Run `mise exec -- bazel test //:org_full` when the longer native/pre-tag
  integration sweep is desired for the final coordination snapshot.
