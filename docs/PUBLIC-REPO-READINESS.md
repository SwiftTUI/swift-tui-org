# Public Repository Readiness

This is the remaining work before the SwiftTUI child repositories can be treated
as standalone public repos with consumer-default build paths.

Current status checked on 2026-05-26:

- `SwiftTUI/swift-tui`, `SwiftTUI/swift-tui-web`,
  `SwiftTUI/swift-tui-examples`, and `SwiftTUI/swift-tui-site` are all pinned
  beyond their only `v0.1.0` tags in this coordination checkout.
- `npm view @swifttui/web` and `npm view @swifttui/build` return 404.
- `gh release view v0.1.0 --repo SwiftTUI/swift-tui-web` reports no release.
- `//:public_dependency_contracts` exists and correctly reports the remaining
  public-contract violations, but it is not wired into `//:org_fast` yet.

## Required End State

- A fresh clone of each child repo builds with its native tools.
- Public child repos do not require `swift-tui-org`, Bazel, submodules, or a
  sibling checkout layout.
- Cross-repo dependencies in public child repos use public HTTPS tags, npm
  versions, or public release tarballs.
- Pre-tag cross-repo integration remains coordination-only through the overlay
  gates in this repo.

## Aggregated Pre-Release Actions

This aggregate was refreshed on 2026-05-27 from the current public-readiness
checklist and the open plan checkboxes in `docs/plans/`.

Completed on 2026-05-27: the `SwiftTUI.App` command-conformance migration
follow-up is no longer a remaining pre-release action. The layouts raster drift
was fixed in `swift-tui-examples`, the focused examples gate passed, and
`mise exec -- bazel test //:org_fast` passed.

1. Preserve the existing repository history for public pre-release. Do not
   squash, rewrite, or replace history as part of the cutover.
2. Choose and publish the release artifacts that downstream repos will consume:
   - Choose the `swift-tui` tag for examples and WebExample. If current
     downstream code needs post-`v0.1.0` APIs, cut and push a new tag first.
   - Publish `@swifttui/web` and `@swifttui/build` to npm, or attach the packed
     tarballs to a public `swift-tui-web` GitHub release.
   - Record the chosen SwiftTUI tag, web package version, and artifact URLs in
     `swift-tui-site/docs/releases.yml`.
3. Switch public child repositories to standalone public defaults:
   - In `swift-tui-examples`, replace cross-repo `swift-tui` sibling path
     dependencies with exact public HTTPS tags.
   - In `swift-tui-examples/WebExample`, replace `workspace:*` web dependencies
     with npm versions or public release tarball URLs.
   - Keep intra-repo example path dependencies unchanged.
   - Update examples scripts, README, and CI so a default public gate checks out
     only `swift-tui-examples` and runs against public dependency artifacts.
   - In `swift-tui-site`, replace `examplesRef: main` and default sibling
     WebExample/web inputs with public release tags or artifacts.
   - Update site scripts and workflows so test/deploy paths work from a fresh
     clone, while keeping local override env vars for maintainers.
4. Wire and run the public dependency guard after the public manifests resolve:
   - Run `mise exec -- bazel test //:public_dependency_contracts`.
   - Add `:public_dependency_contracts` to `//:org_fast`.
   - Run `mise exec -- bazel test //:org_fast`.
5. Verify the final public and coordination paths:
   - Fresh-clone `swift-tui-examples` and run the documented SwiftPM and
     WebExample build checks against public artifacts.
   - Fresh-clone `swift-tui-site` and run `Scripts/check_site.sh`.
   - Run `mise exec -- bazel test //:org_full` from this coordination checkout
     to keep native gates and pre-tag overlay gates covered.
   - Commit the final coordination root pin update.

## Remaining Work By Repo

### `swift-tui`

- Cut and push the SwiftPM release tag that downstream repos should consume.
- Confirm that tag includes every product used by the examples and WebExample:
  `SwiftTUI`, `SwiftTUIRuntime`, `SwiftTUICharts`, `SwiftTUIAnimatedImage`,
  `SwiftTUIWASI`, `SwiftTUIWebHostCLI`, `SwiftUIHost`, and
  `SwiftTUITestSupport`.
- Keep the README focused on SwiftPM consumers and avoid coordination-repo
  setup requirements.

### `swift-tui-web`

- Publish `@swifttui/web` and `@swifttui/build` to npm, or attach
  `bun pm pack` tarballs to a public GitHub release.
- If using release tarballs first, use stable HTTPS URLs such as:

  ```json
  {
    "@swifttui/web": "https://github.com/SwiftTUI/swift-tui-web/releases/download/v0.1.1/swifttui-web-0.1.1.tgz",
    "@swifttui/build": "https://github.com/SwiftTUI/swift-tui-web/releases/download/v0.1.1/swifttui-build-0.1.1.tgz"
  }
  ```

- Verify consumers can install both packages without the Bun workspace.

### `swift-tui-examples`

- Replace every cross-repo SwiftPM `swift-tui` path dependency with an exact
  public HTTPS tag.
- Replace `WebExample` `workspace:*` dependencies with npm versions or public
  release tarball URLs.
- Remove the root package workspace entries that point at `../swift-tui-web`.
- Update CI so the default public gate checks out only `swift-tui-examples`.
- Keep `SWIFTTUI_EXAMPLES_SWIFTPM_SCRATCH` as an optional sequential build
  optimization, not as a required consumer setting.

### `swift-tui-site`

- Replace `examplesRef: main` with a public examples release tag in
  `docs/releases.yml`.
- Make the default WebExample build path fetch or use a tagged public
  WebExample source/artifact when `WEBEXAMPLE_DIR` is not set.
- Update test/deploy workflows so they do not checkout untagged sibling repos
  by default.
- Keep `WEBEXAMPLE_DIR` and `SWIFTTUI_CHECKOUT` as explicit local overrides for
  maintainers.

## Coordination Cutover

After the child repos are switched to resolving public dependencies:

1. Run `bazel test //:public_dependency_contracts`.
2. Add `:public_dependency_contracts` to `//:org_fast`.
3. Run `bazel test //:org_fast`.
4. Run `bazel test //:org_full` to keep the pre-tag overlay path covered.
5. Commit the coordination root pin update.
