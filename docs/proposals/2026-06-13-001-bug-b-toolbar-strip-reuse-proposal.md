# Bug B: toolbar strip re-resolve — implementation proposal

**Date:** 2026-06-13 · **Status:** implementation pass 1 committed; full gate green; broader perf A/B green ·
**Depends on / follows:** [2026-06-13-bug-a-scoped-publication-task-drop-fix.md](../reports/2026-06-13-bug-a-scoped-publication-task-drop-fix.md) ·
**Register item:** "reuse-host guard" (perf)

## TL;DR

The toolbar late-preference machinery re-resolves the toolbar **strip**
(`ToolbarItemsStrip`) into the live graph repeatedly — measured **8 resolves of
the same `.../toolbar-strip` identity** across a ~4-frame run (~2×/frame:
resolve-time + relayout pass) in `TabTaskActivationRuntimeTests`. This is the
"reuse-host guard" item and the capture-host seam behind Bug A's task drop.

Bug A's fix already neutralized the **user-visible** symptom (frozen tab), so
Bug B is now **perf-only**. The sound fix is to let the strip be retain-reused
across frames via an items-signature cache. The change lives in the most
byte-equivalence-sensitive hot path in the codebase (the retained-reuse /
invalidation-cone machinery — the H2/H3/place_ms/commit_ms PR surface), so it
must be implemented with byte-equivalence + perf A/B.

## Cost: CONFIRMED REAL (measured 2026-06-13)

A reuse-vs-recompute probe in `resolveView` (`ViewFoundation.swift`) over the
`TabTaskActivationRuntimeTests` toolbar run: **toolbar-subtree REUSE = 0,
RECOMPUTE = 128** — i.e. the *entire* strip subtree (strip root, `base`,
`background`, the `Layout`, every `ButtonBody`/`HStack`/`overlay`/`content`
node) recomputes **100% every frame, with zero retained reuse** (~16 nodes/frame
for a 1-item toolbar; scales with item count). Each recompute also re-registers
its identity (the shadow-node churn / Bug A seam). So the optimization is
justified: the target is ~16→~0 strip recomputes/frame.

## What was established (this session)

1. **The dead flag.** `reconcileToolbarHostSubtree`'s `changed`
   (`reconciled != node`; `ResolvedNode.==` includes `preferenceValues`) is
   spuriously true every toolbar frame — but `changed` is **never consumed** by
   the runtime stage (`LatePreferenceReconciliation.swift` uses only
   `requiresRelayout`, via `isEquivalentForPlacement`, which *excludes*
   `preferenceValues`, and `resolved`). So the "non-convergence" has no runtime
   effect; the relayout loop terminates in ≤2 passes. A "compare like-for-like"
   fix is therefore a **no-op** — do not ship it alone.

2. **The real residual.** `ToolbarItemsStrip.resolveElements` runs ~2×/frame
   (measured). The strip is built imperatively inside
   `ToolbarModifier.resolve` → `reconciledToolbarHost` →
   `ToolbarItemsStrip(...).resolve(in: context.child(.named("toolbar-strip")))`,
   and again from the descriptor on the late-reconcile path for late-bubbled
   items. Because it is resolved imperatively inside the toolbar host's
   invalidation cone, the normal reuse fast path
   (`resolveView` → `reusableSnapshot(for: identity)` in
   `ViewFoundation.swift:276`) is **denied** for the strip identity, so the
   strip root re-resolves every frame.

3. **Why a naive cache is unsound.** Liveness is `liveNodeIDs.formUnion(frameOrder)`
   at `finalizeFrame` (`ViewGraph.swift:1246`), and `frameOrder` holds only nodes
   *touched this frame's resolve*. Reusing a cached `ResolvedNode` value without
   re-resolving would leave the strip's `ViewNode`s out of `frameOrder` → GC'd →
   the cache would dangle next frame.

4. **The sound mechanism already exists.** `ViewGraph.recordReusedSubtree(_:
   invalidator:retained:)` (`ViewGraph.swift:925`) appends a reused subtree to
   `frameOrder` and re-establishes its bookkeeping **without re-resolving**;
   `reusableSnapshot` (`:1076`) is its disjointness-gated front door. This is the
   H3 retained-subtree path.

## Proposed fix

Gate the strip resolve with an items-signature cache and reuse via the existing
retained-reuse mechanism:

1. **`ToolbarStripSignature`** (Equatable, Sendable): derived from
   `[ToolbarItemConfig]` (`title`, an `Image` descriptor for `icon`, `isEnabled`,
   `systemHint`, `position`) + the style's placement/itemLayout discriminator.
   `action` is a closure and does not affect the rendered strip, but it **does**
   affect runtime registrations: `Button.resolve` registers the action handler
   during resolve, and retained reuse restores the captured handler from the
   previous `ViewNode`. Therefore the cache may exclude `action` only if the
   reuse path separately refreshes toolbar button action registrations from the
   current item configs. Without that refresh, a visually unchanged toolbar item
   whose action closure changed would replay the stale cached handler.

2. **Cache** keyed by scoped toolbar-strip owner `Identity` →
   `(ToolbarStripSignature, ResolvedNode)`. Store on the `ViewGraph` (survives
   frames; pruned with removed graph subtrees) — *not* on the per-frame-rebuilt
   host node.

3. **In `reconciledToolbarHost`**, before building the strip: if
   `cache[stripIdentity].signature == currentSignature`, reuse the cached strip
   `ResolvedNode` via `viewGraph.recordReusedSubtree(cachedStrip, invalidator:,
   retained: true)`, refresh any current-item runtime registrations that are not
   represented by the visual signature, and use the result as `stripNode`; else
   resolve fresh and update the cache. This must run at the **resolve-time** site
   (well-timed: during resolve, before `finalizeFrame`). The **late-reconcile**
   site needs separate timing verification (it runs in the frame tail before
   commit; confirm `frameOrder` is still open then).

## Implementation pass 1 status (2026-06-13)

Implemented and committed in `swift-tui`:

- `ViewGraph` now owns a scoped resolved-node reuse cache that is checkpointed,
  debug-snapshotted, and pruned with removed graph subtrees.
- `reconciledToolbarHost` resolves the strip through a visual signature gate and
  reuses the cached strip through `recordReusedSubtree(..., retained: true)`.
- The cache honors retained-reuse suppression for the strip identity.
- Cache hits restore cached runtime registrations, then refresh current toolbar
  button action registrations from the latest `ToolbarItemConfig` values.
- The item signature includes `title`, `position`, `isEnabled`, `systemHint`, and
  an icon descriptor (`Image.source`, `isResizable`, `scalingMode`). It enables
  cache use for built-in item layouts and layouts with explicit reuse
  signatures (`SendableLayout` or package reuse-providing layouts); otherwise it
  falls back to a fresh resolve.

Focused validation completed:

- `swift test --filter ToolbarTests`
- `swift test --filter ToolbarTests/toolbarStripReuseIsFrameProductEquivalent`
- `swift test --filter ToolbarTests/toolbarStripReuseRefreshesCurrentActionHandlers`
- `swift test --filter Phase1BenchmarkScenariosTests/toolbarStripRerenderScenario`
- `swift test --filter DiagnosticsAndCacheTests/resolveReuseReplaysLocalHandlers`
- `swift test --filter ViewGraphCheckpointTotalityTests`
- `swift test --filter TabTaskActivationRuntimeTests`
- `mise exec -- bazel test //:org_fast`
- `swift package clean`, then:
  - `swift test --filter ToolbarTests`
  - `swift test --filter Phase1BenchmarkScenariosTests`

`mise exec -- bazel test //:org_full` was attempted after the implementation
and validation commits. The toolbar/native path passed, including
`@swift_tui//:native_gate`, `@swift_tui_examples//:native_gate`,
`@swift_tui_site//:native_gate_script`, and `@swift_tui_web//:native_gate`.
The first run remained red on the two pre-tag WebExample web gates:

- `//:site_pretag_native_gate`: `bun run build:wasm` failed because
  `WebExample/src/build-terminal.ts` could not resolve `@swifttui/build`.
- `//:examples_pretag_native_gate`: the WebExample web build failed on the same
  missing `@swifttui/build` module, then the follow-on local host build failed
  because `tsdown` was not on `PATH`.

Root follow-up fixed the pre-tag runners so they install and build the local
`swift-tui-web` packages in the materialized overlay before WebExample imports
`@swifttui/build`/`@swifttui/web`. Targeted gate reruns then passed:

- `mise exec -- bazel test //:site_pretag_native_gate`
- `mise exec -- bazel test //:examples_pretag_native_gate`

The clean-tree full rerun then passed:

- `mise exec -- bazel test //:org_full`

Broader perf A/B was added to
`Tests/SwiftTUITests/Phase1BenchmarkScenariosTests.swift` as
`lateBubbledToolbarPerfABScenario`. The scenario uses a `GeometryReader` to
contribute late-bubbled bottom toolbar items, then compares the same second
frame with normal strip reuse vs the same strip identity under retained-reuse
suppression. Both sides produce identical incremental zero-damage terminal
output. Measured on 2026-06-13:

| Scenario | `resolvedNodesComputed` | `resolvedNodesReused` | Presentation |
| --- | ---: | ---: | --- |
| Optimized strip reuse | 15 | 40 | 0 bytes / 0 lines / 0 cells |
| Strip reuse suppressed | 67 | 0 | 0 bytes / 0 lines / 0 cells |

## Required validation before landing (do not skip — crash-class hot path)

- [x] **Byte-equivalence.** The committed tree and action-registration summary
  must be identical with the cache on vs off. Covered by
  `toolbarStripReuseIsFrameProductEquivalent`, which compares fresh vs cached
  frame products and sorted action-registration summaries.
- [x] **Action freshness.** Add a regression where the toolbar item's visual
  signature is unchanged but its action closure changes across frames; activating
  the reused item must run the current action, not the cached one.
- [x] **Focused perf guard.** `toolbarStripRerenderScenario` asserts the rerender
  reuses resolved strip work and produces no presentation output delta.
- [x] **Broader perf A/B.** Before/after on a late-bubbled-toolbar scenario (the
  gallery, or a layout-dependent-toolbar harness) with the standard metrics.
  Covered by `lateBubbledToolbarPerfABScenario`: optimized second frame
  computed 15 / reused 40 resolved nodes; strip-reuse-suppressed second frame
  computed 67 / reused 0, with identical zero-damage presentation output.
- [x] **Full gate** (`mise exec -- bazel test //:org_full`) + **gallery suite**
  (must stay green; the stamp-skip crash class lives here). Passed clean-tree
  rerun on 2026-06-13 after fixing overlay web package builds.
- [x] **Stale-`.build` trap.** This area has hit SIGBUS on struct growth ×3 — clean
  `.build` if structs change (cf. memory). Covered on 2026-06-13 by
  `swift package clean`, then `swift test --filter ToolbarTests` and
  `swift test --filter Phase1BenchmarkScenariosTests`.

## Measurement harness already in place

`Tests/SwiftTUITests/TabTaskActivationRuntimeTests.swift` (toolbar-wrapped)
reproduces the re-resolve; a `Swift.print("STRIPPROBE…")` in
`ToolbarItemsStrip.resolveElements` counts it (8 baseline). A
late-bubbled-toolbar variant (toolbar items contributed by layout-dependent /
deferred content) is needed to exercise the late-reconcile site.

## Recommendation

**GO for final implementation review.** Implementation pass 1 resolves the
action-registration freshness and icon-signature soundness questions, the
byte-equivalence and focused perf guards are in place, `org_full` is green, and
the broader late-bubbled-toolbar A/B now confirms the intended resolved-work
drop without terminal output changes.
