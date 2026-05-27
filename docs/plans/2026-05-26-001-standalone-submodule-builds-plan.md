# Public Dependency Contracts And Coordination Overlay Implementation Plan

> **For agentic workers:** REQUIRED SKILL: use `executing-plans` or
> `subagent-driven-development` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every public SwiftTUI child repository build from a fresh clone
with native tools and public tagged dependencies, while the private
coordination repo remains the only place that records pre-tag pins or runs
pre-tag cross-repo integration tests.

**Architecture:** Public repositories carry release-facing dependency
contracts: SwiftPM HTTPS tag requirements, npm/Bun package versions or public
release tarballs, and site inputs from public tags. The coordination repository
records exact submodule SHAs for known-good untagged states and materializes
temporary local overrides only inside coordination-owned build directories when
testing those states before release.

**Tech Stack:** Git submodules for coordination pins, Bazel/Bzlmod for
coordination orchestration, SwiftPM for Swift packages, Bun/npm for web
packages, Astro/DocC for the site, and shell scripts for coordination-only
overlay materialization.

**Implementation status (2026-05-27):** the public pre-release cutover is
implemented for `0.0.1`. The child repos are public, each child repo has a
pushed `0.0.1` tag, `swift-tui-web` has public GitHub release tarballs for
`@swifttui/web` and `@swifttui/build`, examples/site defaults resolve public
tagged inputs, and `//:public_dependency_contracts` is wired into
`//:org_fast`. Npm publication remains a follow-up because the local npm session
is not authenticated.

---

## Governing Rules

- Public child repositories must not require this coordination repository,
  Bazel, submodules, or a sibling checkout layout for their default build.
- Public child repositories may depend on another SwiftTUI repository only
  through public tagged HTTPS dependencies or released artifacts.
- Public child repositories must not contain `.swift-tui-pin`, generated
  pre-tag dependency blocks, or any other artifact whose purpose is to record an
  untagged commit from another repository.
- Only this coordination repository may run tests where one repository consumes
  another repository's untagged commit.
- Coordination-only pre-tag tests must use temporary overrides generated under
  this repo's build/tmp area and must leave child worktrees clean.

## Original Evidence Before The `0.0.1` Cutover

- `swift-tui-examples` Swift packages depended on `swift-tui` through
  sibling paths such as `.package(name: "swift-tui", path: "../../swift-tui")`
  and `.package(name: "swift-tui", path: "../../../swift-tui")`. A standalone
  clone could not resolve these paths.
- `swift-tui-examples/WebExample/package.json` depended on
  `@swifttui/web` and `@swifttui/build` through `workspace:*`, which only works
  when the web packages are available in the same workspace.
- `swift-tui-site/docs/docc-repos.yml` built DocC from the public
  `SwiftTUI/swift-tui` repository at `v0.1.0`, but
  `swift-tui-site/docs/releases.yml` named `examplesRef: main`, and
  the site build defaulted to sibling `swift-tui-examples` / `swift-tui-web`
  checkouts for the WebExample demo path.
- `swift-tui-examples/gifeditor` already owns a local
  `gifeditor/Vendor/swift-gif` copy and no longer needs to reach into
  `swift-tui/Vendor/swift-gif`.
- The org root already pins exact child commits via submodules and has Bazel
  lanes for cheap coordination contracts (`//:org_fast`) and full native gates
  (`//:org_full`).

## Desired End State

### Public `swift-tui`

- Remains a normal SwiftPM package at repository root.
- Publishes release tags such as `0.0.1` and later.
- Provides the products consumed by examples and WebExample at those tags.

### Public `swift-tui-web`

- Remains a Bun/npm workspace.
- Produces public package artifacts for `@swifttui/web` and `@swifttui/build`
  from tagged releases.
- The first implementation may use GitHub release tarballs if npm publishing is
  not ready yet. Example dependency strings should be HTTPS tarball URLs tied to
  the web release tag, for example:

  ```json
  {
    "dependencies": {
      "@swifttui/web": "https://github.com/SwiftTUI/swift-tui-web/releases/download/0.0.1/swifttui-web-0.0.1.tgz",
      "@swifttui/build": "https://github.com/SwiftTUI/swift-tui-web/releases/download/0.0.1/swifttui-build-0.0.1.tgz"
    }
  }
  ```

### Public `swift-tui-examples`

- Every Swift package that consumes `swift-tui` uses a public HTTPS dependency
  on a release tag, not a sibling path. For the first tag-aligned release:

  ```swift
  .package(
    url: "https://github.com/SwiftTUI/swift-tui.git",
    exact: "0.1.1"
  )
  ```

- Intra-repo dependencies such as `../layouts` and `../../gallery` remain local
  path dependencies because they stay inside the examples repository.
- `WebExample` consumes `@swifttui/web` and `@swifttui/build` through public
  tagged package artifacts, not `workspace:*`.
- The examples repo gate uses its native SwiftPM/Bun/Xcode commands only. It
  does not require Bazel or this coordination repo.

### Public `swift-tui-site`

- Builds from a fresh clone using Astro/Bun/DocC scripts.
- Defaults to public release tags and public package artifacts for SwiftTUI,
  web packages, and the WebExample input.
- Local env vars such as `SWIFTTUI_CHECKOUT`, `SWIFTTUI_EXAMPLES_CHECKOUT`,
  `SWIFTTUI_WEB_CHECKOUT`, and `WEBEXAMPLE_DIR` remain useful for manual local
  development, but they are overrides, not required defaults.

### Coordination Repo

- Continues to pin the exact child SHAs as git submodules.
- Owns all pre-tag integration tests.
- Owns any script that temporarily rewrites dependencies to sibling checkouts.
- Keeps `//:org_fast` cheap: registry checks, submodule cleanliness, workflow
  checks, and public dependency contract checks only.
- Runs pre-tag native integration only in `//:org_full` or explicit
  coordination targets.

## Non-Goals

- Do not add `.swift-tui-pin` or any SHA pin file to a public child repo.
- Do not add dynamic `Package.swift` ladders that choose between sibling paths
  and URL revisions in public manifests.
- Do not require Bazel in public child repo CI.
- Do not make public child repos depend on untagged `main` or arbitrary commit
  SHAs from sibling repos.
- Do not publish child-repo release tags from the coordination repo. Tags and
  package artifacts are still owned by the native child repositories.

## File Structure To Create Or Modify

### Coordination root

- Modify `README.md`: document the public-repo contract and coordination-only
  pre-tag testing rule.
- Modify `AGENTS.md`: give agents the same boundary in concise form.
- Modify `docs/README.md`: index this plan.
- Modify `BUILD.bazel`: add cheap public dependency contract checks to
  `//:org_fast`; add explicit pre-tag integration targets to `//:org_full`.
- Create `tools/bazel/check_public_dependency_contracts.sh`: fails if public
  child manifests contain sibling cross-repo paths, `workspace:*` dependencies
  for released SwiftTUI packages, or untagged `main` dependencies.
- Create `tools/coordination/materialize_pretag_overlay.sh`: copies selected
  public child repos into a temp directory and rewrites dependency references in
  the temp copy only so they point at the pinned sibling submodules.
- Create `tools/coordination/run_examples_pretag_gate.sh`: uses the overlay
  script, then runs the examples native gate against the overlay.
- Create `tools/coordination/run_site_pretag_gate.sh`: uses the overlay script,
  then runs the site native gate against the overlay.

### `swift-tui`

- No source changes in this plan.
- Release prerequisite: tag a release that contains every product used by the
  examples and WebExample before public repos switch to that tag.

### `swift-tui-web`

- Add or update release packaging documentation for `@swifttui/web` and
  `@swifttui/build`.
- Ensure `bun run pack:web` and `bun run pack:build` produce tarballs suitable
  for public HTTPS release-asset dependencies.
- If npm publishing is ready, publish package versions instead of release
  tarball URLs; the public dependency still must resolve from a tagged release.

### `swift-tui-examples`

- Replace cross-repo SwiftPM sibling dependencies on `swift-tui` with exact
  public HTTPS tag requirements.
- Replace `WebExample` `workspace:*` dependencies on `@swifttui/web` and
  `@swifttui/build` with public tagged package artifacts.
- Keep intra-repo SwiftPM path dependencies unchanged.
- Update `Scripts/check_examples.sh` so the public default path does not require
  sibling `swift-tui` or `swift-tui-web` checkouts. It may keep
  `SWIFTTUI_CHECKOUT` and `SWIFTTUI_WEB_CHECKOUT` as optional local override
  inputs, but the script must pass without them.
- Update `.github/workflows/test.yml` to stop checking out sibling repos for the
  public default gate. The workflow should install native tools and run the
  examples gate against tagged public dependencies.
- Update README/AGENTS to describe standalone public usage and make clear that
  pre-tag sibling testing happens from `swift-tui-org`.
- Keep `gifeditor/Vendor/swift-gif` local; only verify it is not copied from
  `swift-tui` during this work.

### `swift-tui-site`

- Update `docs/releases.yml` so every consumed repo/artifact is a release tag
  or version, not `main`.
- Update the WebExample build path so a fresh site clone can fetch/build the
  tagged public WebExample by default.
- Keep env-var overrides for local work, but document them as overrides.

## Implementation Steps

### Phase 1: Lock the policy into coordination docs

- [x] Update the org root `README.md` with the public repository contract.
- [x] Update root `AGENTS.md` with agent-facing public-vs-coordination rules.
- [x] Index this plan from `docs/README.md`.
- [x] Run:

  ```bash
  git diff --check README.md AGENTS.md docs/README.md docs/plans/2026-05-26-001-standalone-submodule-builds-plan.md
  ```

  Expected: PASS.

### Phase 2: Add cheap coordination contract checks

- [x] Create `tools/bazel/check_public_dependency_contracts.sh`.

  The script should check:

  ```bash
  rg -n '\.package\(name: "swift-tui", path: "\.\./\.\./swift-tui|\.\.\/\.\.\/\.\.\/swift-tui' swift-tui-examples
  rg -n '"@swifttui/(web|build)": "workspace:\*"' swift-tui-examples
  rg -n 'examplesRef: main|ref: main' swift-tui-site/docs swift-tui-site/Website
  ```

  Each command should fail the script if it finds a match. Allow intra-repo
  paths such as `../layouts` and `../../gallery`.

- [x] Add a root `sh_test(name = "public_dependency_contracts", ...)` in
  `BUILD.bazel`, tagged `local` and `no-sandbox`.
- [x] Add `:public_dependency_contracts` to `//:org_fast`.

  Status: done after Phase 4/5 pointed at resolving public `0.0.1` artifacts.
- [x] Run:

  ```bash
  tools/bin/bazel test //:public_dependency_contracts
  ```

  Result: PASS. The `mise exec -- bazel ...` wrapper hung before invoking Bazel
  in this run, so the repo-local Bazelisk wrapper was used instead.

### Phase 3: Prepare public release artifacts

- [x] In `swift-tui`, choose the dependency tag that public examples will use
  first. The public cutover uses `0.0.1`.
- [x] In `swift-tui-web`, verify package tarballs:

  ```bash
  bun run pack:web
  bun run pack:build
  ```

  Expected: both commands produce installable tarballs for `@swifttui/web` and
  `@swifttui/build`. Verified locally with Bun 1.3.13 for the `0.0.1` release;
  `bun pm pack` produced `swifttui-web-0.0.1.tgz` and
  `swifttui-build-0.0.1.tgz`, and the packed `@swifttui/build` manifest uses
  `@swifttui/web` version `0.0.1`.

- [x] Attach those tarballs to the matching `swift-tui-web` GitHub release, or
  publish them to the intended npm registry.

  Status: attached to the `swift-tui-web` GitHub `0.0.1` pre-release. Npm
  publish remains pending because `npm whoami` reports `ENEEDAUTH`.
- [x] Record the chosen SwiftTUI tag, web package version, and package artifact
  URLs in `swift-tui-site/docs/releases.yml`.

### Phase 4: Make `swift-tui-examples` standalone by default

- [x] Replace every cross-repo `swift-tui` path dependency in
  `swift-tui-examples/**/Package.swift` with the chosen public HTTPS exact tag
  requirement.
- [x] Preserve intra-repo path dependencies:

  ```swift
  .package(path: "../layouts")
  .package(path: "../../gallery")
  ```

- [x] Replace `swift-tui-examples/WebExample/package.json` dependencies:

  ```json
  {
    "@swifttui/web": "<public tagged artifact>",
    "@swifttui/build": "<public tagged artifact>"
  }
  ```

- [x] Update `swift-tui-examples/README.md` with a standalone section:

  ```bash
  git clone https://github.com/SwiftTUI/swift-tui-examples.git
  cd swift-tui-examples
  swiftly run swift run --package-path argparse argparse-demo --help
  bun install --cwd WebExample --frozen-lockfile
  bun --cwd WebExample run build
  ```

- [x] Update `swift-tui-examples/Scripts/check_examples.sh`:

  - Remove unconditional `require_checkout "$framework_root" "swift-tui"`.
  - Remove unconditional `require_checkout "$web_root" "swift-tui-web"`.
  - Run Swift package build/test commands against public manifest dependencies
    by default.
  - When `SWIFTTUI_CHECKOUT` or `SWIFTTUI_WEB_CHECKOUT` is set, validate the
    path and use it only for explicit local override flows.

- [x] Update `swift-tui-examples/.github/workflows/test.yml`:

  - Keep checkout of `swift-tui-examples`.
  - Remove the default sibling checkouts of `SwiftTUI/swift-tui` and
    `SwiftTUI/swift-tui-web`.
  - Keep native tool installation: Swift, Bun, Xcode/macOS, Binaryen for
    WebExample.
  - Run `Scripts/check_examples.sh --skip-clean`.

- [ ] Run the native examples gate from a clean examples checkout:

  ```bash
  cd swift-tui-examples
  Scripts/check_examples.sh --skip-clean
  ```

  Expected: PASS without requiring the coordination repo.

### Phase 5: Make `swift-tui-site` standalone by default

- [x] Change `swift-tui-site/docs/releases.yml` so examples and web references
  are tags or package versions, not `main`.
- [x] Update `swift-tui-site/.github/workflows/test.yml` so the public default
  site gate does not check out untagged sibling `swift-tui-examples` or
  `swift-tui-web` repositories.
- [x] Update `swift-tui-site/.github/workflows/cloudflare-pages.yml` so deploys
  build/copy WebExample from a tagged public source or published artifact, not
  a default sibling checkout.
- [x] Update `swift-tui-site/Scripts/check_site_ci_workflow.sh` so it enforces
  the standalone workflow shape instead of requiring sibling checkouts.
- [x] Update site scripts so `bun run --cwd Website build:full` can fetch the
  tagged WebExample input into a site-owned build directory when `WEBEXAMPLE_DIR`
  is not set.
- [x] Keep `WEBEXAMPLE_DIR` and `SWIFTTUI_CHECKOUT` as explicit local override
  env vars. The examples/web sibling checkout overrides are no longer needed by
  the default site path.
- [x] Run from the site checkout:

  ```bash
  cd swift-tui-site
  Scripts/check_site.sh
  ```

  Expected: PASS without requiring the coordination repo.

### Phase 6: Add coordination-only pre-tag overlays

- [x] Create `tools/coordination/materialize_pretag_overlay.sh`.

  Required behavior:

  - Input: repo name (`swift-tui-examples` or `swift-tui-site`) and output dir.
  - Copy the requested public child repo into the output dir.
  - Rewrite only the temp copy's dependency declarations so they point at this
    coordination checkout's submodules.
  - Leave every child submodule worktree clean.

- [x] Create `tools/coordination/run_examples_pretag_gate.sh`.

  Required behavior:

  - Materialize an examples overlay.
  - Rewrite SwiftPM `swift-tui` dependencies in the overlay to a local path
    pointing at `${ORG_ROOT}/swift-tui`.
  - Rewrite `WebExample` web dependencies in the overlay to the local
    `swift-tui-web` packages.
  - Run the examples native gate in the overlay.

- [x] Create `tools/coordination/run_site_pretag_gate.sh`.

  Required behavior:

  - Materialize a site overlay.
  - Point site override env vars at the pinned submodule checkouts or generated
    examples overlay.
  - Run the site native gate in the overlay.

- [x] Add Bazel targets:

  ```python
  sh_test(name = "examples_pretag_native_gate", ...)
  sh_test(name = "site_pretag_native_gate", ...)
  ```

- [x] Add those targets to `//:org_full`, not `//:org_fast`.

### Phase 7: Verify both public and coordination paths

- [ ] Public examples verification:

  ```bash
  tmpdir="$(mktemp -d)"
  git clone https://github.com/SwiftTUI/swift-tui-examples.git "$tmpdir/swift-tui-examples"
  cd "$tmpdir/swift-tui-examples"
  swiftly run swift run --package-path argparse argparse-demo --help
  bun install --cwd WebExample --frozen-lockfile
  bun --cwd WebExample run build
  ```

  Expected: PASS using public tagged dependencies.

- [ ] Public site verification:

  ```bash
  tmpdir="$(mktemp -d)"
  git clone https://github.com/SwiftTUI/swift-tui-site.git "$tmpdir/swift-tui-site"
  cd "$tmpdir/swift-tui-site"
  Scripts/check_site.sh
  ```

  Expected: PASS using public tagged dependencies and released artifacts.

- [ ] Coordination verification:

  ```bash
  tools/bin/bazel test //:org_fast
  mise exec -- bazel test //:org_full
  ```

  Result so far: `tools/bin/bazel test //:org_fast` passed with
  `:public_dependency_contracts` included. `//:org_full` remains the longer
  native/pre-tag overlay sweep.

## Risks And Mitigations

- **Public repos may currently need APIs newer than their latest dependency
  tags.** Mitigation: cut dependency repo tags first, then update downstream
  public repos to those tags.
- **Web packages are not yet published to npm.** Mitigation: use GitHub release
  tarball URLs for the first public dependency path, then migrate to npm package
  versions when publishing is ready.
- **Coordination overlays can accidentally dirty child repos.** Mitigation:
  materialize overlays under a temp directory and add a final `git status`
  cleanliness check for every submodule.
- **Bazel `org_fast` can become slow if native tools creep into it.**
  Mitigation: keep pre-tag native checks only in `//:org_full` or explicit
  coordination targets.
- **Tagged public dependencies can lag active local development.** Mitigation:
  use this coordination repo's submodule pins and pre-tag overlay gates for
  known-good untagged states until the next public tag is cut.
