# SwiftTUI Organization Workspace

This repository is the orchestration root for the SwiftTUI GitHub organization.
It is intentionally not the public framework package. Users still consume
SwiftTUI through the native package managers owned by the child repositories.

The root repo provides three things:

1. A pinned source checkout of the organization through Git submodules.
2. A Bazel/Bzlmod module graph over those checked-out repos.
3. One place to run organization-level validation without replacing SwiftPM,
   Bun, npm, Astro, or DocC as the native tools of record.

## Repository Model

| Path | GitHub repo | Native contract | Bazel module |
| --- | --- | --- | --- |
| `swift-tui/` | `SwiftTUI/swift-tui` | SwiftPM package for framework consumers | `swift_tui` |
| `swift-tui-web/` | `SwiftTUI/swift-tui-web` | Bun/npm package workspace | `swift_tui_web` |
| `swift-tui-examples/` | `SwiftTUI/swift-tui-examples` | Runnable Swift examples and demo gates | `swift_tui_examples` |
| `swift-tui-site/` | `SwiftTUI/swift-tui-site` | Astro site and DocC composition | `swift_tui_site` |

Submodules are only the checkout and pinning layer. Bazel is the orchestration
layer. The child repositories remain the source of truth for their native
package-manager manifests and release tags.

## Planning Documents

Organization-level plans live in [docs/README.md](docs/README.md). These plans
can span multiple child repositories, so they are tracked in the orchestration
root rather than in a single package's docs tree.

## Hard Invariants

- `SwiftTUI/swift-tui` must remain consumable via SwiftPM:
  `.package(url: "https://github.com/SwiftTUI/swift-tui", ...)`.
- `Package.swift` stays in the root of `SwiftTUI/swift-tui`.
- Web packages remain Bun/npm-consumable from `SwiftTUI/swift-tui-web`.
- The site remains buildable with its Astro/Bun workflow.
- Bazel may orchestrate native gates, but it does not replace those public
  package-manager contracts.

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
bazel test //:org
```

Without shell activation, run through mise explicitly:

```sh
mise exec -- bazel test //:org
```

Maintainers who prefer Bazelisk outside mise can keep using it directly; the
same `.bazelversion` file controls the Bazel version in both paths.

The child native gates still require their native tools:

- Swift 6.3.x and SwiftPM
- Xcode/macOS toolchain for app/example gates that require it

Swift and Xcode are intentionally not installed by mise because they come from
the local Apple toolchain setup.

Useful mise tasks:

```sh
mise run fetch
mise run submodule-status
mise run native-gates
mise run org
```

## Bazel Commands

After `mise install`, or from an activated mise shell, use the Bazel targets
directly.

Fetch Bazel external dependencies for the organization targets and validate the
module graph:

```sh
bazel fetch //:org
```

Check that submodules are initialized and have Bazel metadata:

```sh
bazel test //:submodule_status
```

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

`//:org` is the full orchestration target:

```sh
bazel test //:org
```

## What The Native Gates Run

The Bazel targets delegate to thin entrypoint scripts committed in each child
repo:

| Target | Native command |
| --- | --- |
| `//:swift_tui_native_gate` | `bun run test` |
| `//:swift_tui_web_native_gate` | `bun run ci` |
| `//:swift_tui_examples_native_gate` | `Scripts/check_examples.sh --skip-clean` |
| `//:swift_tui_site_native_gate` | `bun install --cwd Website --frozen-lockfile`, `bun run --cwd Website check`, `bun run --cwd Website build`, `Scripts/build_docc_site.sh` |

The wrapper targets are marked `local` and `no-sandbox` because these first
entrypoints intentionally run the existing repo-native build systems in their
real source checkouts. This keeps SwiftPM/Bun/Astro behavior faithful while the
Bazel graph becomes the organization-level scheduler.

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
git add swift-tui swift-tui-web swift-tui-examples swift-tui-site
git commit -m "chore: update SwiftTUI org pins"
```

After updating pins, run:

```sh
bazel fetch //:org
bazel test //:org
```

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
3. Run `bazel test //:org`.
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
bazel fetch --force //:org
```
