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

- [reports/2026-06-16-perf-signal-representativeness.md](reports/2026-06-16-perf-signal-representativeness.md) -
  representativeness pass over the committed `TermUIPerf` scenarios against
  Gallery, Layouts, File Previewer, GIF editor, and host-example usage; classifies
  `sheet-open-latency` rows=176 as an amplified diagnostic, records the added
  `example-app-shell-workflow` calibration signal, identifies remaining missing
  app-flow signals, and confirms the next tranche should start with focused
  publication/invalidation diagnostics before code.
- [reports/2026-06-16-perf-phase-rebaseline-0-0-20.md](reports/2026-06-16-perf-phase-rebaseline-0-0-20.md) -
  current `swift-tui 0.0.20` perf re-baseline on AC power: confirms the sheet
  cone fixes hold, narrow canary is flat-to-slightly-better, sheet total CPU is
  down 21-32% versus `30fc38bf`, and ranks the next work as diagnostics before
  any checkpoint or force-root/focus implementation.
- [reports/2026-06-15-gallery-example-invariant-map.md](reports/2026-06-15-gallery-example-invariant-map.md) -
  inventory and push-down map for framework-level invariants previously proven
  indirectly by gallery/example tests; adds focused package coverage for alert
  base-placement stability and `ZStack` Spacer neutrality while leaving
  app/demo-owned assertions in the example suites.
- [reports/2026-06-15-sheet-open-cone-mechanism-2-portal-translation-fix.md](reports/2026-06-15-sheet-open-cone-mechanism-2-portal-translation-fix.md) -
  second sheet-cone follow-up: stops unmapped overlay-entry invalidations from
  translating to the portal root, eliminates steady-state sheet
  `invalidation-conflict`, and records the cumulative sheet-176 `total_cpu`
  drop from `1.441` to `0.970`.
- [reports/2026-06-15-sheet-open-cone-followup-fix-results.md](reports/2026-06-15-sheet-open-cone-followup-fix-results.md) -
  first sheet-cone follow-up: pins the dominant `Layout[0]` cone to redundant
  post-action owner invalidation, skips that follow-up when the action already
  invalidated, and records the same-session sheet-176 CPU/head-prep wins.
- [reports/2026-06-15-stage-1b-all-publication-diffing.md](reports/2026-06-15-stage-1b-all-publication-diffing.md) -
  Stage 1B outcome for frontier/publication narrowing: committed
  graph-level runtime-registration fingerprints keep unavoidable root frames
  reported as `.all` while restoring only changed non-root registration subtrees,
  cutting `.all` restored-node totals 88.8% on `sheet-open-latency` and 64.6% on
  `synthetic-narrow-invalidation`; broader registry-family equivalence remains a
  follow-up before deeper specialization.
- [reports/2026-06-15-stage-1a2-selective-gate-attribution.md](reports/2026-06-15-stage-1a2-selective-gate-attribution.md) -
  Stage 1A.2 outcome for frontier/publication narrowing: published
  `swift-tui` gate-attribution diagnostics, ranked the remaining
  `nil_selective_evaluation_disabled` `.all` frames, and recommends Stage 1B
  because the dominant causes are explicit root-evaluation guards rather than
  remaining portal identity translation misses.
- [reports/2026-06-15-stage-1a-frontier-publication-narrowing.md](reports/2026-06-15-stage-1a-frontier-publication-narrowing.md) -
  Stage 1A outcome for frontier/publication narrowing: safe portal invalidation
  translation landed in `swift-tui`, portal-hosted unmapped samples are gone,
  remaining `.all` frames are attributed to disabled selective evaluation, and
  Stage 1A.2 should identify the exact disabling gates before Stage 1B.
- [reports/2026-06-09-android-host-current-state.md](reports/2026-06-09-android-host-current-state.md) -
  current state of the Android host effort after the parity pass: implemented
  `SwiftTUIAndroidHost`/Compose Gallery scaffolding, styled-cell/image/semantics
  frame snapshots, local Swift and Gradle verification with
  `swift-6.3.2-RELEASE_android`, API 35 arm64 emulator install/launch screenshot
  smoke, known input/runtime gaps, and next work.
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

- [plans/2026-06-15-001-perf-phase-completion-goal.md](plans/2026-06-15-001-perf-phase-completion-goal.md) -
  current perf-phase status at `swift-tui 0.0.20`: original A-F residuals are
  either landed, closed, or deferred with evidence; the later sheet-cone work
  landed in two measured fixes; any new optimization tranche should begin with a
  fresh current-pin re-baseline.
- [plans/2026-06-15-002-sheet-open-cone-narrowing-design.md](plans/2026-06-15-002-sheet-open-cone-narrowing-design.md) -
  design/history entry point for the sheet-open invalidation cone: records the
  diagnostic path, superseded scene-level hypothesis, landed post-action and
  portal-translation fixes, and lower-EV follow-up areas after the steady-state
  cone was eliminated.
- [plans/2026-06-14-004-android-host-library-phase-b-publication-plan.md](plans/2026-06-14-004-android-host-library-phase-b-publication-plan.md) -
  Phase B of the Android host-library extraction: populate the empty
  `swift-tui-android` submodule and publish the host AAR
  (`sh.swifttui:android-host`) + the `sh.swifttui.android` Gradle plugin at
  `0.1.0`. Ratified decisions: full public release now; plugin-copied Swift
  runtime (tiny AAR); **static Maven repo on GitHub Pages for the AAR + Gradle
  Plugin Portal for the plugin, Maven Central as a later graduation** (no
  GPG/Sonatype for `0.1.0`). Split into B2a (all machinery, verifiable via
  `publishToMavenLocal` + the emulator smoke) and B2b (push the AAR to Pages +
  `publishPlugins` + tag, gated only on a Plugin Portal key).
- [plans/2026-06-14-002-android-host-library-phase-a-extraction-plan.md](plans/2026-06-14-002-android-host-library-phase-a-extraction-plan.md) -
  execution-ready task plan for **Phase A** of the Android host-library
  extraction proposal: extract the 11 Kotlin host files + JNI shim into an
  internal `:swift-tui-host` module and the three Swift-build tasks into a
  `build-logic` convention plugin, leaving `:app` a thin consumer. Closes the
  proposal's gaps — the three app-name JNI couplings (not one), the atomic
  package-rename + `RegisterNatives` switch, and a falsifiable same-APK-payload
  check. Stays inside `swift-tui-examples`; no Maven, no `swift-tui-android`
  population, no ABI freeze (all Phase B).
- [plans/2026-06-14-001-invalidation-gap-test-plan.md](plans/2026-06-14-001-invalidation-gap-test-plan.md) -
  test-first plan for the invalidation gap analysis: package-owned
  `swift-tui` coverage for state reader/no-reader behavior, binding plumbing,
  observable object-token fan-out, observable environment values,
  Observation draft/discard safety, dirty-frontier gates, retained reuse under
  ancestor invalidation, and transaction/scheduler guards. Explicitly treats
  `swift-tui-examples` tests as optional smoke only, not acceptance coverage.
- [plans/2026-06-10-001-perf-workstream-assessment-next-wave-proposal.md](plans/2026-06-10-001-perf-workstream-assessment-next-wave-proposal.md) -
  full perf-workstream assessment at `bc63495a` (live-measured): all landed
  wins holding and reader-attribution reproducing, but `resolve_ms` regressed
  +73/+91% in the 0.0.19 window (untriaged) and is now the dominant residual
  in every workload class; transition-frame commit falsifies the G3a/G11
  deferral premise; ranked next wave (push → resolve diagnosis → Part 0 →
  scenario calibration → Part A → transition-commit probe → popover split)
  plus measurement accounting traps and a gaps register.
- [plans/2026-06-09-001-android-host-view-gallery-demo-plan.md](plans/2026-06-09-001-android-host-view-gallery-demo-plan.md) -
  Android host view and gallery demo plan/status: completed local Swift
  Android cross-build fixes, shared size negotiation, `SwiftTUIAndroidHost`,
  Compose/JNI Android Gallery scaffold, styled-cell/image/semantics frame
  snapshot work, current assemble verification, API 35 install/first-frame
  verification, and remaining tab-by-tab/input/accessibility smoke work.
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

- [proposals/2026-06-14-001-android-host-library-extraction-proposal.md](proposals/2026-06-14-001-android-host-library-extraction-proposal.md) -
  the reusable Android host layer (11 Kotlin files + JNI shim + Gradle Swift-build
  logic) is trapped in the `AndroidGallery` example, forcing library users to
  copy-paste; proposes a phased extraction into an Android host library (AAR) +
  Gradle convention plugin, with the create-symbol decoupling, JNI/R8 hardening,
  Swift-toolchain compatibility contract, and a `swift-tui-android` repo-placement
  recommendation. Phase A (internal module, now) vs Phase B (published AAR, after
  ABI stabilizes).
- [proposals/COMMAND_PALETTE_OPEN_PERFORMANCE.md](proposals/COMMAND_PALETTE_OPEN_PERFORMANCE.md) -
  why presenting an overlay (e.g. the command palette) re-resolves the whole
  host subtree on `isPresented` toggle, the measured evidence, and three
  framework-level options (dependency-aware reuse, portal-host-scoped
  invalidation, opt-in memoized view boundary) to make open/close cheap.
- [proposals/IMAGE_BLEND_MODE.md](proposals/IMAGE_BLEND_MODE.md) -
  proposal and current-head audit for image blend-mode compositing support; see
  [plans/2026-06-06-001-image-blend-mode-implementation-plan.md](plans/2026-06-06-001-image-blend-mode-implementation-plan.md)
  for the phased execution plan.
