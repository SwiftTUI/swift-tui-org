# Public Repository Readiness

This tracks the public pre-release cutover for the SwiftTUI child
repositories.

Current status checked on 2026-05-27:

- `SwiftTUI/swift-tui`, `SwiftTUI/swift-tui-web`,
  `SwiftTUI/swift-tui-examples`, and `SwiftTUI/swift-tui-site` are public.
- Each child repo has a pushed `0.0.3` tag.
- `swift-tui-web` has a public GitHub `0.0.3` pre-release with
  `swifttui-web-0.0.3.tgz` and `swifttui-build-0.0.3.tgz` assets.
- `swift-tui-examples` resolves `swift-tui` through the `0.0.3` HTTPS SwiftPM
  tag and resolves web packages through the `swift-tui-web` `0.0.3` release
  tarballs.
- `swift-tui-site` resolves DocC from the `swift-tui` `0.0.3` tag and fetches
  tagged WebExample input into `.build/public-inputs/` by default.
- `//:public_dependency_contracts` is wired into `//:org_fast`.
- Npm publication is still pending because the local npm session is not
  authenticated; `npm whoami` reports `ENEEDAUTH`.

## Required End State

- A fresh clone of each child repo builds with its native tools.
- Public child repos do not require `swift-tui-org`, Bazel, submodules, or a
  sibling checkout layout.
- Cross-repo dependencies in public child repos use public HTTPS tags, npm
  versions, or public release tarballs.
- Pre-tag cross-repo integration remains coordination-only through the overlay
  gates in this repo.

The current `0.0.3` state satisfies the public dependency shape using GitHub
release tarballs for the web packages. Migrating those two web dependencies from
release tarball URLs to npm package versions is a follow-up once npm credentials
are available.

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

- Publish `@swifttui/web` and `@swifttui/build` to npm when an authenticated npm
  session or token is available.
- After npm publish, replace GitHub release tarball URLs in consumers with npm
  package versions if that becomes the preferred public install path.
- Run `mise exec -- bazel test //:org_full` when the longer native/pre-tag
  integration sweep is desired for the final coordination snapshot.
