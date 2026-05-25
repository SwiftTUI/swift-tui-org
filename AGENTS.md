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
| `swift-tui-web/` | `SwiftTUI/swift-tui-web` | Bun/npm workspace | `swift_tui_web` |
| `swift-tui-examples/` | `SwiftTUI/swift-tui-examples` | Runnable Swift examples | `swift_tui_examples` |
| `swift-tui-site/` | `SwiftTUI/swift-tui-site` | Astro site + DocC | `swift_tui_site` |

Submodules are the checkout/pinning layer; Bazel owns cross-repo contracts. Each
child repo remains the source of truth for its own manifests and release tags.

## Build & test commands

Tooling is pinned via `mise.toml` (Bazelisk + Bun). Run `mise trust && mise
install` once. Then, from an activated mise shell, use Bazel targets directly:

```bash
bazel test //:org_fast      # cheap org contract checks (CI default)
bazel test //:org_full      # full org gate, incl. every native gate
bazel test //:native_gates  # run all child repos' native gates
bazel fetch //:org_full     # refresh Bazel external state after pin bumps
```

Without shell activation, prefix with `mise exec --` (e.g.
`mise exec -- bazel test //:org_full`) or use the `mise run <task>` wrappers
(`org-fast`, `native-gates`, `org-full`, `release-candidate`, `fetch`).

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

## Hard invariants — do not break

- `SwiftTUI/swift-tui` stays SwiftPM-consumable; `Package.swift` stays at its root.
- Web packages stay Bun/npm-consumable; the site stays Astro/Bun-buildable.
- Bazel may *orchestrate* native gates but must not *replace* the public
  package-manager contracts.

## Conventions

- Agent guidance uses `AGENTS.md` as the real file; `CLAUDE.md` is a symlink to
  it. Edit `AGENTS.md`.
- Org-level plans live in [`docs/`](docs/README.md) (they can span child repos).
