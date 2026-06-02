# SwiftTUI Organization Docs

This directory holds organization-level documents for the `swift-tui-org`
orchestration repository. Child repositories keep their package-specific
documentation in their own `docs/` trees.

## Public Pre-Release Readiness

- [PUBLIC-REPO-READINESS.md](PUBLIC-REPO-READINESS.md) - current checklist for
  the child-repo public pre-release state, public dependency defaults, verification
  notes, and npm follow-up.

## Cross-Repo Development

- [CROSS-REPO-DEVELOPMENT.md](CROSS-REPO-DEVELOPMENT.md) - the coordination
  overlay (head vs worktree source modes), Bazel target reference for
  `bazel run //:open_overlay` and the `*_pretag_native_gate` /
  `*_worktree_gate` family, cookbook recipes for the common iteration loops,
  and troubleshooting.

## Reports

- [reports/2026-05-28-gallery-performance-report.md](reports/2026-05-28-gallery-performance-report.md) -
  in-process performance data collection across the Gallery tabs; identifies the
  hot spots (H1 off-screen idle frames, H2 per-interaction `resolve` cost).
- [reports/2026-05-30-h2-resolve-reuse-findings.md](reports/2026-05-30-h2-resolve-reuse-findings.md) -
  H2 outcome: root cause (per-frame transaction `debugSignature` defeats retained
  reuse), the scoped-reuse fix, the measured win + scaling, and two corrections
  (forceRootEvaluation does not disable reuse; the "animation/elision gap" was a
  pre-existing flaky test).

## Planning Documents

- [plans/2026-06-02-004-persistent-retained-index-structural-adjacency-proposal.md](plans/2026-06-02-004-persistent-retained-index-structural-adjacency-proposal.md) -
  execution proposal building out Opportunity 1 of the remaining-opportunities
  register: a persistent, patchable `RetainedFrameIndex` backed by stored
  structural adjacency. Sequenced as L1 structural-adjacency maps (correctness),
  L2 subtree signatures + debug equality oracle, L3 fragment-based patchable
  index (the perf win), and a deferred L4 arena representation. Includes a
  6-tracer/4-verifier source trace resolving Open Question #1: the place phase
  does not reparent and portals are hoisted at resolve, so a single canonical
  adjacency relation suffices (per-phase/redirect L3.5 dropped); the residual
  hazards are transient removal-overlay insert/prune churn and the lazy-stack
  `indexedChildSource` viewport-subset barrier, plus duplicate-identity stance.
- [plans/2026-06-02-003-rendering-performance-remaining-opportunities-proposal.md](plans/2026-06-02-003-rendering-performance-remaining-opportunities-proposal.md) -
  post-implementation opportunity register for the remaining rendering
  performance work: retained indexes, ordered semantic fragments, raster
  residuals, retained layout validation, measurement reliability, blockers, and
  rough requirements to unblock each area.
- [plans/2026-06-02-002-rendering-performance-next-wave-proposal.md](plans/2026-06-02-002-rendering-performance-next-wave-proposal.md) -
  implemented/partial next-wave rendering performance proposal: elided-frame
  micro-spans and pre-frame-head off-screen animation elision, raster damage
  trust, subtree draw reuse, local layout metric flushing, retained frame-tail
  residuals, and validation caveats.
- [plans/2026-06-02-001-rendering-performance-optimization-proposal.md](plans/2026-06-02-001-rendering-performance-optimization-proposal.md) -
  proposal for the next rendering-infrastructure performance wave: measurement
  semantics, retained placement table carry-forward, scoped reuse suppression,
  incremental semantics/draw extraction, host damage metrics, and visible
  animation/text-churn policy.
- [plans/2026-05-30-001-perf-h2-resolve-reuse-complete-plan.md](plans/2026-05-30-001-perf-h2-resolve-reuse-complete-plan.md) -
  implementation plan for the H2 resolve-reuse correctness fix (scoped reuse).
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

## Proposals

Investigated design proposals (not yet implemented).

- [proposals/COMMAND_PALETTE_OPEN_PERFORMANCE.md](proposals/COMMAND_PALETTE_OPEN_PERFORMANCE.md) -
  why presenting an overlay (e.g. the command palette) re-resolves the whole
  host subtree on `isPresented` toggle, the measured evidence, and three
  framework-level options (dependency-aware reuse, portal-host-scoped
  invalidation, opt-in memoized view boundary) to make open/close cheap.
- [proposals/IMAGE_BLEND_MODE.md](proposals/IMAGE_BLEND_MODE.md) -
  proposal for image blend-mode compositing support.
