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

- [reports/2026-06-08-0.1.0-public-release-readiness.md](reports/2026-06-08-0.1.0-public-release-readiness.md) -
  first-public-`0.1.0` release-readiness audit across all four child repos: one
  legal blocker (3 repos + npm tarballs have no LICENSE), several
  reality-drift self-contradictions (install pin excludes 0.1.0, npm "being
  finalized" vs live, missing `VISION-GAP.md`, stale `0.0.4` profile badge,
  orphan `v0.1.0` tags, placeholder showcase graphics), and the highest-value
  changes ranked by value-per-effort with a do-now/defer cut line.
- [reports/2026-05-28-gallery-performance-report.md](reports/2026-05-28-gallery-performance-report.md) -
  in-process performance data collection across the Gallery tabs; identifies the
  hot spots (H1 off-screen idle frames, H2 per-interaction `resolve` cost).
- [reports/2026-05-30-h2-resolve-reuse-findings.md](reports/2026-05-30-h2-resolve-reuse-findings.md) -
  H2 outcome: root cause (per-frame transaction `debugSignature` defeats retained
  reuse), the scoped-reuse fix, the measured win + scaling, and two corrections
  (forceRootEvaluation does not disable reuse; the "animation/elision gap" was a
  pre-existing flaky test).

## Planning Documents

### Structural Identity Migration (7-stage plan set)

A staged migration that splits SwiftTUI's overloaded `Identity` into four distinct
axes — runtime `ViewNodeID`, `StructuralPath`, `EntityIdentity`, and
`StateSlotIdentity` — for both rendering performance and architectural rigor.
Breaking changes are pulled forward; each stage lands behind an oracle. Start at
the entry point, which holds the *why* and indexes the per-stage *how*.

- [plans/2026-06-03-001-first-class-structural-identity-proposal.md](plans/2026-06-03-001-first-class-structural-identity-proposal.md) -
  **Entry point + stage index.** The overload problem, the four-axis model, the
  StateTree `NodeID`/`FieldID`/`LSID` role mapping, the design stance (Option C is
  the committed destination, not a contingency), the hard cases, and corrections
  to the prior record (`isAncestor` is component-wise; `.overlay`/`.background`
  are in-tree decorations not portals; `.fullScreenCover` does not exist;
  `IdentityComponent`/`SurfaceCompositionRole` already exist).
- [plans/2026-06-03-002-structural-identity-stage-0-divergence-diagnostics-plan.md](plans/2026-06-03-002-structural-identity-stage-0-divergence-diagnostics-plan.md) -
  **Stage 0.** Read-only, debug-only divergence diagnostics harness; corpus-wide
  report on path-vs-structural-parent disagreement, duplicate-id frequency and
  provenance, alias and portal divergence. Produces the evidence that tunes the
  later policy decisions. No behavior change.
- Stage 1 — [plans/2026-06-02-004-…structural-adjacency-proposal.md](plans/2026-06-02-004-persistent-retained-index-structural-adjacency-proposal.md)
  (the persistent retained-index execution plan, detailed in full below) is
  **Stage 1** of this set: the `StructuralFrameIndex` sidecar and patchable
  retained index — the first consumer and the rendering-performance win.
- [plans/2026-06-03-003-structural-identity-stage-2-resolve-time-structural-identity-plan.md](plans/2026-06-03-003-structural-identity-stage-2-resolve-time-structural-identity-plan.md) -
  **Stage 2.** `StructuralPath` on `ResolveContext`/`ResolvedNode`; structural
  components emitted at the three identity primitives so `.id`/`ForEach` change
  runtime identity without moving structure. (Option B.)
- [plans/2026-06-03-004-structural-identity-stage-3-reconciliation-entity-identity-plan.md](plans/2026-06-03-004-structural-identity-stage-3-reconciliation-entity-identity-plan.md) -
  **Stage 3.** `EntityIdentity` axis; reconciliation keyed on
  `(structural slot + type + entity id)`; deterministic, diagnosed duplicate-id
  handling via an occurrence disambiguator that never touches the runtime string.
- [plans/2026-06-03-005-structural-identity-stage-4-portal-overlay-edge-roles-plan.md](plans/2026-06-03-005-structural-identity-stage-4-portal-overlay-edge-roles-plan.md) -
  **Stage 4.** `StructuralEdgeRole` distinguishing declaration-owner from
  placement-parent; cuts the `Identity.path` string fan-out behind presentation
  ids and surface stableKeys; stages the registration-alias layer for deletion.
- [plans/2026-06-03-006-structural-identity-stage-5-viewnodeid-lifetime-split-plan.md](plans/2026-06-03-006-structural-identity-stage-5-viewnodeid-lifetime-split-plan.md) -
  **Stage 5.** A distinct opaque `ViewNodeID`; re-keys the ~40 runtime-lifetime
  indexes; deletes the alias layer; redesigns string-encoded handler ids.
  Behavior-preserving, behind the byte-equivalence oracle. (Option C, part 1.)
- [plans/2026-06-03-007-structural-identity-stage-6-entity-routed-lifetime-plan.md](plans/2026-06-03-007-structural-identity-stage-6-entity-routed-lifetime-plan.md) -
  **Stage 6.** The `EntityIdentity → ViewNodeID` routing table (StateTree's `LSID`
  lesson); `@State` re-rooted onto `ViewNodeID`; state/animation/focus survive
  identity-changing moves. The one intentional semantic change. (Option C, part 2.)
- [plans/2026-06-03-008-structural-identity-migration-gap-remediation-plan.md](plans/2026-06-03-008-structural-identity-migration-gap-remediation-plan.md) -
  **Audit + gap-remediation plan.** Post-implementation review of stages 0–6 at
  pin `f2cc53fa`: all four axes landed and integrated (package + tests compile,
  57/57 named tests pass), but the rigor obligations are the shortfall — the Stage 5
  cross-version golden oracle was never built, Stage 1's `FrameMetrics` invalidation
  engine was never repointed and its "patchable" index still rebuilds (vacuous
  oracle), Stage 4's typed edge carriers are stored but never consumed, and Stage 0's
  evidence harness never ran over a real corpus. Prioritized G1–G16 remediation,
  recommended `VISION-GAP.md` entries, and corrections the plan docs need.

### Other planning documents

- [plans/2026-06-06-006-image-blend-mode-native-host-replay-plan.md](plans/2026-06-06-006-image-blend-mode-native-host-replay-plan.md) -
  later image blend-mode tranche for native host replay after ordered layers:
  WebHost canvas and SwiftUI/CoreGraphics blend modes behind capability checks,
  with precomposition retained as fallback.
- [plans/2026-06-06-005-image-blend-mode-gif-blending-plan.md](plans/2026-06-06-005-image-blend-mode-gif-blending-plan.md) -
  implemented image blend-mode tranche for GIF behavior: explicit
  `AnimatedImage` PNG-frame blending coverage, reduced-motion first-frame
  coverage, and tested raw GIF pass-through semantics without adding a runtime
  GIF decoder bridge.
- [plans/2026-06-06-004-image-blend-mode-ordered-layer-plan.md](plans/2026-06-06-004-image-blend-mode-ordered-layer-plan.md) -
  implemented image blend-mode tranche for ordered presentation layers: package
  sidecar paint order, overlapping image/cell semantics, topology-aware damage,
  and debug layer descriptions; host-native replay remains deferred.
- [plans/2026-06-06-003-image-blend-mode-glyph-backdrop-plan.md](plans/2026-06-06-003-image-blend-mode-glyph-backdrop-plan.md) -
  later image blend-mode tranche for glyph-aware backdrop fidelity: foreground
  and glyph payload capture, block/braille/text coverage approximations, and
  damage/replay when glyph-only content changes under a blended image.
- [plans/2026-06-06-002-image-blend-mode-cache-hardening-plan.md](plans/2026-06-06-002-image-blend-mode-cache-hardening-plan.md) -
  focused follow-on tranche for image blend-mode cache hardening: bounded
  blended-variant storage, memory metrics, eviction behavior, host regression
  coverage, and animated/background churn tests before taking on broader
  blending fidelity.
- [plans/2026-06-06-001-image-blend-mode-implementation-plan.md](plans/2026-06-06-001-image-blend-mode-implementation-plan.md) -
  phased implementation plan for image blend-mode compositing: core attachment
  metadata, raster backdrop capture, shared runtime precomposition, terminal and
  web host routing, SwiftUI host handling, animated-image coverage, docs, and
  gates.
- [plans/2026-06-02-004-persistent-retained-index-structural-adjacency-proposal.md](plans/2026-06-02-004-persistent-retained-index-structural-adjacency-proposal.md) -
  execution proposal building out Opportunity 1 of the remaining-opportunities
  register: a persistent, patchable `RetainedFrameIndex` backed by stored
  structural adjacency. Sequenced as L1 `StructuralFrameIndex` sidecar maps keyed
  by `StructuralNodeKey` with an `Identity` multimap (correctness), L2 subtree
  signatures + structural equality oracle, L3 structural-fragment patching (the
  perf win), and a deferred L4 arena representation. Includes a 6-tracer /
  4-verifier source trace resolving Open Question #1: the place phase does not
  reparent and portals are hoisted at resolve, so a single canonical adjacency
  relation suffices (per-phase/redirect L3.5 dropped); the residual hazards are
  transient removal-overlay insert/prune churn, the lazy-stack `indexedChildSource`
  viewport-subset barrier, and duplicate-runtime-identity conservative fallback.
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
  proposal and current-head audit for image blend-mode compositing support; see
  [plans/2026-06-06-001-image-blend-mode-implementation-plan.md](plans/2026-06-06-001-image-blend-mode-implementation-plan.md)
  for the phased execution plan.
