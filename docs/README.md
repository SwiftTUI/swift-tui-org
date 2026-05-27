# SwiftTUI Organization Docs

This directory holds organization-level documents for the `swift-tui-org`
orchestration repository. Child repositories keep their package-specific
documentation in their own `docs/` trees.

## Public Pre-Release Readiness

- [PUBLIC-REPO-READINESS.md](PUBLIC-REPO-READINESS.md) - current checklist for
  the `0.0.1` child-repo cutover, public dependency defaults, verification
  notes, and npm follow-up.

## Cross-Repo Development

- [CROSS-REPO-DEVELOPMENT.md](CROSS-REPO-DEVELOPMENT.md) - the coordination
  overlay (head vs worktree source modes), Bazel target reference for
  `bazel run //:open_overlay` and the `*_pretag_native_gate` /
  `*_worktree_gate` family, cookbook recipes for the common iteration loops,
  and troubleshooting.

## Planning Documents

- [plans/2026-05-22-001-github-organization-split-plan.md](plans/2026-05-22-001-github-organization-split-plan.md) -
  execution plan for splitting SwiftTUI across GitHub organization repositories
  while preserving the one-package terminal/WebHost consumer path and coherent
  DocC generation.
- [plans/2026-05-24-001-wasi-worker-scheduler-plan.md](plans/2026-05-24-001-wasi-worker-scheduler-plan.md) -
  execution plan for fixing static WASI browser worker scheduling so authored
  timer cadences are preserved.
- [plans/2026-05-24-002-raster-damage-support-plan.md](plans/2026-05-24-002-raster-damage-support-plan.md) -
  execution plan for producing and consuming raster damage across terminal,
  WASI/browser, localhost WebHost, and host-managed SwiftUI paths.
- [plans/2026-05-24-003-file-previewer-performance-plan.md](plans/2026-05-24-003-file-previewer-performance-plan.md) -
  execution plan for improving FilePreviewer responsiveness with cached
  directory listings, lazy file-row rendering, and explicit preview-process
  cleanup.
- [plans/2026-05-25-001-shared-surface-damage-contract-plan.md](plans/2026-05-25-001-shared-surface-damage-contract-plan.md) -
  execution plan for fixing command-palette raster damage regressions by
  splitting private raster reuse hints from shared host-facing raster damage and
  encoding presentation/compositing topology in core metadata.
- [plans/2026-05-26-001-standalone-submodule-builds-plan.md](plans/2026-05-26-001-standalone-submodule-builds-plan.md) -
  execution plan for making public child repositories standalone with native
  tooling and public tagged dependencies, while keeping all pre-tag integration
  pins and tests in this coordination repository.
- [plans/2026-05-26-002-examples-coverage-opportunities-todo.md](plans/2026-05-26-002-examples-coverage-opportunities-todo.md) -
  todo list for consolidating, slimming, removing, and extending examples so the
  examples repo covers framework features and build configurations more
  comprehensively.
- [plans/2026-05-27-001-swifttui-app-command-conformance-plan.md](plans/2026-05-27-001-swifttui-app-command-conformance-plan.md) -
  migration plan for making the batteries-included `SwiftTUI.App` protocol
  conform to `SwiftTUICommand` while keeping `SwiftTUIRuntime.App` independent
  from command-line parsing.
