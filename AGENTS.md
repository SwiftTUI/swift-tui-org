# AGENTS.md

Guidance for Claude Code and other agentic assistants working in the **SwiftTUI
org root**. Keep this file concise. [`README.md`](README.md) is the full
reference and the source of truth — update it there, not here.

## What this repo is

This is the **orchestration root** for the SwiftTUI GitHub organization. It is
**not** the public framework package — users consume SwiftTUI through the child
repos' native package managers (SwiftPM, Bun/npm, Astro/DocC). The root provides:

1. A pinned checkout of the org via **Git submodules**.
2. A **Bazel/Bzlmod contract graph** over those checkouts.
3. One place to run org-level validation without replacing the native tools.

## Repo model

| Submodule | GitHub repo | Native contract | Bazel module |
| --- | --- | --- | --- |
| `swift-tui/` | `SwiftTUI/swift-tui` | SwiftPM package | `swift_tui` |
| `swift-tui-swiftui/` | `SwiftTUI/swift-tui-swiftui` | SwiftPM package (SwiftUI host) | `swift_tui_swiftui` |
| `swift-tui-web/` | `SwiftTUI/swift-tui-web` | Bun/npm workspace | `swift_tui_web` |
| `swift-tui-examples/` | `SwiftTUI/swift-tui-examples` | Runnable Swift examples | `swift_tui_examples` |
| `swift-tui-site/` | `SwiftTUI/swift-tui-site` | Astro site + DocC | `swift_tui_site` |
| `swift-tui-android/` | `SwiftTUI/swift-tui-android` | Gradle/Maven AAR + plugin | `swift_tui_android` |
| `github/` | `SwiftTUI/.github` | GitHub org profile README (docs only) | — |

Submodules are the checkout/pinning layer; Bazel owns cross-repo contracts. Each
child repo remains the source of truth for its own manifests and release tags.
`github/` (the `SwiftTUI/.github` org-profile repo) is a pinning-only submodule:
docs only, no Bazel module or native gate.

## Public vs coordination contracts

- Public child repos must build from a fresh clone with native tools only.
- Public child repos must consume sibling SwiftTUI repos only through public,
  tagged HTTPS dependencies or released artifacts.
- Pin files, generated pre-tag dependency overrides, and tests where one repo
  consumes another repo's untagged commit belong only in this coordination repo.
- Bazel is coordination tooling. Do not make a public child repo require Bazel
  or this root checkout for its default build.
- **All planning, proposal, and design docs live *solely* in this root repo's
  `docs/`** (`docs/plans/`, `docs/proposals/`, `docs/reports/`). They are
  forward-looking and may span child repos, so the coordination root owns them.
  Do not add or leave planning/proposal docs in a child repo.
- **Child-repo `docs/` are hard-limited to documentation that describes the
  state of `HEAD`** in that repo (architecture as built, public-API surface,
  development/build/release process, known flakes, in-source DocC). The *single*
  exception is each child's `VISION-GAP.md` (the code-vs-intent gap register),
  which is allowed to remain in the child repo. Anything else aspirational or
  not-yet-true belongs in this root's `docs/`.

## Build & test commands

Tooling is pinned via `mise.toml` (Bazelisk + Bun). Run `mise trust && mise
install` once. Then, from an activated mise shell, use Bazel targets directly:

```bash
bazel test //:org_fast                       # cheap org contract checks (CI default)
bazel test //:org_full                       # full org gate, incl. every native gate
bazel test //:native_gates                   # run all child repos' native gates
bazel test //:examples_pretag_native_gate    # head-mode (CI shape)
bazel test //:site_pretag_native_gate
bazel test //:worktree_gates                 # both gates against the live working tree
bazel fetch //:org_full                      # refresh Bazel external state after pin bumps

# Dev tools — materialize the coordination overlay for cross-repo iteration:
bazel run  //:open_overlay -- --print-env examples   # rsync working trees, emit env vars
bazel run  //:open_overlay -- --help                 # full flag list
```

See [docs/CROSS-REPO-DEVELOPMENT.md](docs/CROSS-REPO-DEVELOPMENT.md) for the
overlay workflow (head vs worktree source modes, cookbook recipes).

Without shell activation, prefix with `mise exec --` (e.g.
`mise exec -- bazel test //:org_full`) or use the `mise run <task>` wrappers
(`org-fast`, `native-gates`, `org-full`, `release-candidate`, `fetch`,
`overlay`, `worktree-gates`, `overlay-smoke`). The `overlay` task forwards
trailing args, e.g. `mise run overlay -- --print-env examples`.

Native gates still need their own toolchains: Swift 6.3.x + SwiftPM, the
Xcode/macOS toolchain, and Binaryen/Brotli for browser/WASI packaging. Swift and
Xcode are intentionally **not** installed by mise.

## Critical workflow

- **Editing child code:** make the change *inside the submodule*, commit and push
  it **in that child repo**, then return to the root and record the new pin
  (`git add <submodule> && git commit`). The org root should record committed
  child revisions, not dirty submodule working trees.
- **Bumping pins:** `git submodule update --remote --merge [<name>]`, then
  `bazel fetch //:org_full && bazel test //:org_fast`.
- **First checkout:** clone with `--recurse-submodules` (or
  `git submodule update --init --recursive`).
- **Pre-tag integration:** run it from this root using the pinned submodules and
  coordination-owned temporary overrides. Do not commit those overrides into a
  public child repo.
- **Examples pre-tag gate:** uses an overlay-owned
  `swift-tui-examples/.build/shared-swiftpm` scratch path to reuse SwiftPM
  products sequentially. Do not share that scratch path across parallel gates.

## Hard invariants — do not break

- `SwiftTUI/swift-tui` stays SwiftPM-consumable; `Package.swift` stays at its root.
- Public child repos use tagged HTTPS dependencies or released artifacts for
  sibling SwiftTUI repos.
- Web packages stay Bun/npm-consumable; the site stays Astro/Bun-buildable.
- Bazel may *orchestrate* native gates but must not *replace* the public
  package-manager contracts.

## Conventions

- Agent guidance uses `AGENTS.md` as the real file; `CLAUDE.md` is a symlink to
  it. Edit `AGENTS.md`.
- All planning, proposal, and design docs live solely in this root's
  [`docs/`](docs/README.md); child-repo docs describe `HEAD` only, except each
  child's `VISION-GAP.md`. See **Public vs coordination contracts** above.
