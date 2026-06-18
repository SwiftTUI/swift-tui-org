# SwiftTUI Organization Workspace

This repository is the orchestration root for the SwiftTUI GitHub organization.
It is intentionally not the public framework package. Users still consume
SwiftTUI through the native package managers owned by the child repositories.

The root repo provides three things:

1. A pinned source checkout of the organization through Git submodules.
2. A Bazel/Bzlmod contract graph over those checked-out repos.
3. One place to run organization-level validation without replacing SwiftPM,
   Bun, npm, Astro, or DocC as the native tools of record.

## Repository Model

| Path | GitHub repo | Native contract | Bazel module |
| --- | --- | --- | --- |
| `swift-tui/` | `SwiftTUI/swift-tui` | SwiftPM package for framework consumers | `swift_tui` |
| `swift-tui-swiftui/` | `SwiftTUI/swift-tui-swiftui` | SwiftPM package: native SwiftUI host (macOS/iOS) | `swift_tui_swiftui` |
| `swift-tui-web/` | `SwiftTUI/swift-tui-web` | Bun/npm package workspace | `swift_tui_web` |
| `swift-tui-examples/` | `SwiftTUI/swift-tui-examples` | Runnable Swift examples and demo gates | `swift_tui_examples` |
| `swift-tui-site/` | `SwiftTUI/swift-tui-site` | Astro site and DocC composition | `swift_tui_site` |
| `swift-tui-android/` | `SwiftTUI/swift-tui-android` | Gradle/Maven AAR + plugin | `swift_tui_android` |

Submodules are only the checkout and pinning layer. Bazel owns cross-repo
contracts for the pinned organization state. The child repositories remain the
source of truth for their native package-manager manifests and release tags.

## Public Repository Contract

The child repositories are the public products. By default, a fresh clone of a
child repository must build with its native tools and must not require this
coordination repository, Bazel, submodules, or any private checkout layout.

Cross-repository dependencies in public child repositories must point at public,
tagged artifacts:

- Swift packages use HTTPS SwiftPM dependencies on release tags, for example
  `https://github.com/SwiftTUI/swift-tui.git` at an exact tagged version.
- Web packages use npm/Bun-consumable published packages or public HTTPS
  release tarballs from tagged releases.
- Site and documentation builds use public release tags or released artifacts by
  default.

All pre-tag integration state belongs here in the coordination repo. That means
submodule SHAs, known-good untagged combinations, local checkout overrides, and
tests where one repository consumes another repository's untagged commit are
coordination-repo concerns only. Do not commit SHA pin files, generated
pre-release dependency blocks, or sibling-checkout assumptions into public child
repos.

## Current Public Pre-Release State

All child repositories are public and tagged at `0.0.21`. Public child defaults
now resolve through public release artifacts:

- `swift-tui` is consumed through the `0.0.21` HTTPS SwiftPM tag.
- `swift-tui-web` publishes `@swifttui/web` and `@swifttui/build` tarballs on
  the GitHub `0.0.21` release.
- `swift-tui-android` publishes the `sh.swifttui:android-host` AAR and
  `sh.swifttui.android` Gradle plugin at `0.0.21`.
- `swift-tui-examples` uses the `swift-tui` `0.0.21` tag and the web `0.0.21`
  release tarballs by default; AndroidGallery also uses the Android `0.0.21`
  artifacts.
- `swift-tui-site` fetches tagged `swift-tui-examples` input into
  `.build/public-inputs/` and builds DocC from the `swift-tui` `0.0.21` tag.

As of `0.0.21`, `@swifttui/web` and `@swifttui/build` are published to npm and
also attached to the GitHub release as tarballs. In-org consumers
(`swift-tui-examples`, `swift-tui-site`) resolve the web packages through the
release tarball URLs; external consumers can install the npm package names
directly. Android consumers resolve the host AAR and Gradle plugin from the
SwiftTUI GitHub Pages Maven repository.

For cross-repo development before the next tag, the org root materializes a
**coordination overlay** under `.build/coordination/`. The overlay is a
throwaway copy of the pinned children where it is safe to rewrite the manifest
files (`Package.swift`, the `WebExample/package.json`, the SwiftPM workspace
list, etc.) without touching the public child repos. Two source modes are
supported:

- `head` (CI default) — `git archive HEAD` of each submodule. Byte-for-byte
  deterministic, matches what a release tag would see.
- `worktree` (`bazel run //:open_overlay` default) — `rsync` of the live
  working tree, including uncommitted edits. For local iteration.

Common entry points:

```sh
bazel run //:open_overlay -- --print-env examples   # rsync working trees, emit env
eval "$(bazel run //:open_overlay -- --print-env examples 2>/dev/null)"
bun --cwd swift-tui-examples run check               # now uses overlay siblings

bazel test //:examples_worktree_gate                 # full gate on uncommitted tree
bazel test //:site_worktree_gate
bazel test //:worktree_gates                         # both at once

bazel test //:examples_pretag_native_gate            # CI-shape (head mode)
bazel test //:site_pretag_native_gate
```

The `*_worktree_gate` targets are intentionally **not** in `//:org_full` or
`//:release_candidate` — those keep CI-deterministic `head` semantics. The full
workflow (source-mode mechanics, cookbooks, the `SWIFTTUI_CHECKOUT` env-var
override path, troubleshooting) is in
[docs/CROSS-REPO-DEVELOPMENT.md](docs/CROSS-REPO-DEVELOPMENT.md).

## Public-Readiness Notes

The release cutover notes are tracked in
[docs/PUBLIC-REPO-READINESS.md](docs/PUBLIC-REPO-READINESS.md). At this point
the public default paths, `//:org_fast` guard, GitHub release tarballs, and npm
web package publication are in place.

## Planning Documents

All planning, proposal, and design docs live **solely** in this orchestration
root's [docs/](docs/README.md) tree (`docs/plans/`, `docs/proposals/`,
`docs/reports/`). They are forward-looking and can span multiple child
repositories, so they are tracked here rather than in any single package's docs
tree. Do not add or leave planning/proposal docs in a child repo.

Child-repository `docs/` are **hard-limited to documentation that describes the
state of `HEAD`** in that repo — architecture as built, the public-API surface,
the build/test/release process, known flakes, and the in-source DocC catalogs.
The **single exception** is each child's `VISION-GAP.md` (the code-vs-intent gap
register), which may remain in the child repo. Anything else that is aspirational
or not-yet-true belongs in this root's `docs/`.

## Hard Invariants

- `SwiftTUI/swift-tui` must remain consumable via SwiftPM:
  `.package(url: "https://github.com/SwiftTUI/swift-tui", ...)`.
- `Package.swift` stays in the root of `SwiftTUI/swift-tui`.
- Public child repos use only their native tools by default: SwiftPM, Bun/npm,
  Astro, and DocC.
- Public child repos consume other SwiftTUI repos only through public tagged
  HTTPS dependencies or released artifacts.
- Web packages remain Bun/npm-consumable from `SwiftTUI/swift-tui-web`.
- The site remains buildable with its Astro/Bun workflow without this
  coordination checkout.
- Bazel may orchestrate native gates, but it does not replace those public
  package-manager contracts.
- Pre-tag cross-repo testing and pin tracking live only in this coordination
  repository.

## First Checkout

Use recursive submodules so the repo pins materialize immediately:

```sh
git clone --recurse-submodules git@github.com:SwiftTUI/swift-tui-org.git
cd swift-tui-org
```

If you already cloned without submodules:

```sh
git submodule update --init --recursive
```

## Tooling

This repo uses `mise.toml` to pin the local orchestration tools:

- Bazelisk 1.28.1, with Bazel pinned by `.bazelversion`
- Bun 1.3.13

Install mise once, then install the repo tools from the root:

```sh
mise trust
mise install
```

If your shell activates mise, the normal commands are plain `bazel` commands.
The repo-local `tools/bin/bazel` wrapper forwards to Bazelisk, so
`.bazelversion` remains the Bazel version pin:

```sh
bazel version
bazel test //:org_fast
```

Without shell activation, run through mise explicitly:

```sh
mise exec -- bazel test //:org_full
```

Maintainers who prefer Bazelisk outside mise can keep using it directly; the
same `.bazelversion` file controls the Bazel version in both paths.

The child native gates still require their native tools:

- Swift 6.3.x and SwiftPM
- Xcode/macOS toolchain for app/example gates that require it
- Binaryen and Brotli for browser/WASI packaging checks

Swift and Xcode are intentionally not installed by mise because they come from
the local Apple toolchain setup.

Useful mise tasks:

```sh
mise run fetch
mise run submodule-status
mise run org-fast
mise run native-gates
mise run org-full
mise run release-candidate
mise run org
```

## Bazel Commands

After `mise install`, or from an activated mise shell, use the Bazel targets
directly.

Fetch Bazel external dependencies for the full organization target and validate
the module graph:

```sh
bazel fetch //:org_full
```

Run the cheap organization contract checks:

```sh
bazel test //:org_fast
```

`//:org_fast` checks that submodules are initialized, the child registry is
consistent across `.gitmodules`, `MODULE.bazel`, `BUILD.bazel`, and this README,
public child repos no longer contain sibling-checkout dependency defaults, and
the submodule checkouts are clean at the commits pinned by the root repo.

`//:org_fast` should stay cheap and coordination-local. It must not run tests
that require SwiftPM, Bun package installs, network dependency resolution, or
one public child repo consuming another child repo's untagged commit.

Useful individual contract targets:

```sh
bazel test //:submodule_status
bazel test //:repo_registry_contract
bazel test //:pin_cleanliness
bazel test //:public_dependency_contracts
```

`//:public_dependency_contracts` is the cheap guard for public child-repo
standalone rules. It fails if a child repo still has cross-repo sibling paths,
workspace-only SwiftTUI web package dependencies, or untagged `main` release
metadata. It is part of `//:org_fast`.

Run every repository's native gate through Bazel:

```sh
bazel test //:native_gates
```

Run a single repository gate:

```sh
bazel test //:swift_tui_native_gate
bazel test //:swift_tui_web_native_gate
bazel test //:swift_tui_examples_native_gate
bazel test //:swift_tui_site_native_gate
```

`//:org_full` is the full orchestration target:

```sh
bazel test //:org_full
```

`//:org` remains a compatibility alias for `//:org_full`.

`//:org_full` is where coordination-only pre-tag integration checks belong. A
pre-tag check may materialize temporary local overrides so a public repo can be
tested against sibling submodule commits, but those overrides must be generated
under the coordination repo's build/tmp area and must not be committed back into
child repositories.

Explicit coordination-only pre-tag gates:

```sh
bazel test //:examples_pretag_native_gate
bazel test //:site_pretag_native_gate
```

These targets copy the pinned child repos into `.build/coordination/...` and
rewrite dependencies only inside that temporary overlay before running the
native child gates.

Release candidates add a published-pin check:

```sh
bazel test //:release_candidate
```

CI runs `//:org_fast` by default from `.github/workflows/org-gate.yml`. The same
workflow exposes a manual full gate that fetches and runs `//:org_full`. Child
repositories still own their native workflow definitions; the root workflow
checks the pinned submodule combination by running Bazel contract targets over
those child-owned gates.

## What The Native Gates Run

The Bazel targets delegate to thin entrypoint scripts committed in each child
repo:

| Target | Native command |
| --- | --- |
| `//:swift_tui_native_gate` | `bun run test` |
| `//:swift_tui_web_native_gate` | `bun run ci` |
| `//:swift_tui_examples_native_gate` | `Scripts/check_examples.sh --skip-clean` |
| `//:swift_tui_site_native_gate` | `Scripts/check_site.sh` |

The wrapper targets are marked `local` and `no-sandbox` because these first
entrypoints intentionally run the existing repo-native build systems in their
real source checkouts. This keeps SwiftPM/Bun/Astro behavior faithful while the
Bazel graph becomes the organization-level scheduler.

Public child-repo CI should prove public-consumer behavior against tagged
dependencies. Coordination-repo targets may additionally prove the exact
submodule graph before those commits are tagged.

Future migration can replace these package-level wrappers with finer-grained
Bazel Swift, TypeScript, and DocC targets where the payoff is clear.

## Updating Submodule Pins

To move one submodule to the latest remote `main`:

```sh
git submodule update --remote --merge swift-tui
git status
git add swift-tui
git commit -m "chore: update swift-tui pin"
```

To update all submodules to their tracked remote branches:

```sh
git submodule update --remote --merge
git status
git add swift-tui swift-tui-web swift-tui-android swift-tui-examples swift-tui-site
git commit -m "chore: update SwiftTUI org pins"
```

After updating pins, run:

```sh
bazel fetch //:org_full
bazel test //:org_fast
bazel test //:org_full
```

## Bumping the Org Version

The release version (currently `0.0.21`) is denormalized across every child:
`package.json` versions, SwiftPM `exact:`/`upToNextMinor(from:)` pins, the Xcode
`exactVersion`, Android Gradle plugin/AAR coordinates, GitHub release tarball
URLs, `tree`/`blob`/`tag` links, site display strings, and the canonical
`swift-tui-site/docs/releases.yml` manifest.

`tools/coordination/bump_version.sh` rewrites all of those authored sites in one
pass. The current version is read from `releases.yml` (override with `--from`).
It is **dry-run by default** — it prints a unified diff and a release runbook and
changes nothing until you pass `--write`:

```sh
mise run bump -- 0.0.13            # preview the full diff (dry run)
mise run bump -- 0.0.13 --write    # apply, then review `git -C <submodule> diff`
bazel run //:bump_version -- 0.0.13 # same, via Bazel
```

What it deliberately does **not** do — these stay maintainer-owned:

- It never commits, tags, pushes, or publishes npm/GitHub release artifacts.
- It never edits generated lockfiles (`Package.resolved`, `bun.lock`,
  `MODULE.bazel.lock`) — those encode the new tag's git SHA / integrity hashes
  and unrelated registry-module versions, so they are regenerated (the tool
  prints the exact `swift package resolve` / `bun install` / `bazel fetch`
  commands) only **after** the new tags are published.
- It leaves dated history (`docs/plans`, `docs/reports`, `PUBLIC-REPO-READINESS.md`,
  `VISION*.md`) as a record, reporting them as skipped.

Run order is web → swift-tui → android → examples → site → record pins here,
because examples consume the web, framework, and Android artifacts, and the site
then consumes examples. The tool prints this runbook; finish with
`bazel test //:release_candidate`.

## Editing Child Repositories

You can edit a child repository directly from the submodule directory:

```sh
cd swift-tui
git checkout -b my-change
# edit, test, commit, push
```

When the child commit is ready, return to the org root and record the new pin:

```sh
cd ..
git add swift-tui
git commit -m "chore: update swift-tui for my-change"
```

For coordinated work, use the same branch name in the affected child repos, push
those branches, then update the org root to point at the exact commits you want
the integration gate to validate.

## Release Workflow

A release should still be published from the native repos:

1. Validate and tag child repos with their native gates.
2. Update this org root's submodule pins to those exact release commits.
3. Run `bazel test //:release_candidate`.
4. Commit and tag this orchestration repo with the same release name if the
   whole-organization state matters.

The orchestration tag documents a known-good combination. It does not replace
the child repo release tags that SwiftPM, npm, or the site workflow consume.

## Adding A Repository

1. Add a minimal `MODULE.bazel` to the child repo.
2. Add a `BUILD.bazel` target that exposes a public `native_gate`.
3. Add the repo as a submodule:

   ```sh
   git submodule add git@github.com:SwiftTUI/<repo>.git <repo>
   ```

4. Add `bazel_dep(...)` and `local_path_override(...)` to this repo's
   `MODULE.bazel`.
5. Add an alias to `BUILD.bazel` and include it in `//:native_gates`.
6. Update this README.
7. Run `bazel test //:repo_registry_contract` to verify the registry stays
   consistent.

## Troubleshooting

If Bazel reports a local override missing a module file, initialize submodules:

```sh
git submodule update --init --recursive
```

If a native gate cannot find `swift`, `bun`, or Xcode tools, verify the command
works directly in the child repo first. The Bazel targets inherit `PATH`, `HOME`,
`TMPDIR`, and `DEVELOPER_DIR` from the calling environment.

If a submodule is dirty, decide whether the child repo change should be committed
there first. The org root should normally record committed child revisions, not
uncommitted local edits.

If `bazel fetch` has stale external state, force a refresh:

```sh
bazel fetch --force //:org_full
```
