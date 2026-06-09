# Sheet / Command-Palette Open Latency — Investigation & Prototypes

**Date:** 2026-06-09
**Status:** Investigation complete; one landable measurement tool + one gated raster
prototype checked in; the principal optimization identified but **not landed** (see
"Why nothing structural landed").
**Repos touched:** `SwiftTUI/swift-tui` (code, branch
`perf/sheet-open-latency-investigation`).

## Problem

Opening a `.sheet` / command palette feels slow. Initial hypothesis (from a static
read of the code): opening a presentation forces a full re-raster of the now-background
tree because inserting the `OverlayStack` changes the surface-topology signature.

## What the measurements actually show

A new TermUIPerf scenario (`sheet-open-latency`, see below) drives an open/close cycle
over a parametric static background and captures per-phase `FrameDiagnostics` timings.

**Release, async, palette open (~17.5 ms frame):**

| phase | ms | share |
| --- | --- | --- |
| resolve | 8.55 | **49%** |
| measure | 3.71 | **21%** |
| place | 0.85 | 5% |
| semantics | 0.51 | 3% |
| draw | 0.18 | 1% |
| raster | 1.60 | 9% |
| commit | 2.12 | 12% |

So the open cost is dominated by **resolve + measure (~70%)**, not raster. The original
"re-raster the background" hypothesis is only ~9% of the frame, and the host-facing
terminal damage is already bounded (`RasterSurfaceDamageDiff` runs after the fresh
raster). Debug numbers inflate `resolve` most; the *proportions* are the signal.

## Root cause of the resolve/measure cost

Instrumenting `ViewNode.canReuse` (temporary trace, since removed) pinned two distinct
reasons retained-subtree reuse does not fire on open:

1. **Dominant — content is a descendant of the re-resolving `isPresented` owner.**
   `reusableSnapshot` reuses disjoint **siblings** of a dirty node (the canonical
   `synthetic-narrow-invalidation` probe already reuses 54/67 nodes, `resolve`
   ~16 ms → ~2 ms — its "0 reused" doc comment is stale), but it does **not** reuse
   **descendants** of a dirty node. `.sheet(isPresented:)` attaches the state above its
   content, so toggling it dirties an ancestor of the content and the whole content
   subtree re-resolves. Measured: sheet open reuses **~0 / 246** nodes regardless of #2.

2. **Secondary — `isFocused` is baked into the reuse snapshot.**
   `ResolveContext.contextualEnvironmentValues` sets `isFocused` true for the focused
   node *plus all ancestors and all descendants*, written into every node's
   `EnvironmentSnapshot` via the `IsFocusedKey` subscript. Moving focus (which opening a
   sheet does) flips `isFocused` across whole subtrees, so `canReuse`'s
   `environmentSnapshot ==` check fails for otherwise-disjoint subtrees.
   (`focusedIdentity` / `pressedIdentity` are stored as direct fields, *not* in the
   snapshot, so only `isFocused` does this.)

## Why nothing structural landed

A prototype fix for #2 was built and reverted:

- Marked `IsFocusedKey` a new `RuntimeDerivedEnvironmentKey`, excluded such keys from the
  reuse snapshot, and made `\.isFocused` reads register a `FocusedIdentityKey`
  dependency so readers stay correct via the existing
  `runtimeFocusStateDependentIdentities` / `invalidateEnvironmentReaders` path.
- It passed all 117 focus tests, **but** (a) it did **not** help sheet open — the
  descendant blocker (#1) dominates, still ~0 reused — and (b) it **deterministically
  regressed** `InteractiveRuntimeTests` "pointer scroll updates the visible surface for
  a WindowGroup-hosted scroll pane" (a `TabView`-captured external-binding `ScrollView`
  stopped repainting on scroll).
- A core reuse change with that blast radius and no confirmed benefit for the target was
  not worth landing. Reverted.

## What is checked in (gate green, `bun run test` passes)

In `SwiftTUI/swift-tui` on branch `perf/sheet-open-latency-investigation`:

- **`Tools/TermUIPerf/.../Scenarios/SheetOpenLatencyScenario.swift`** (+ registration in
  `PerfScenario.swift` / `PerfRunConfig.swift`, + a `PerfRunConfigTests` fixture bump for
  the new scenario name). Parametric open/close benchmark; env knobs
  `TERMUI_PERF_SHEET_OVERLAY=palette|popover` and `TERMUI_PERF_SHEET_TREE_ROWS`. This is
  the durable measurement tool behind every number here.
- **Raster prototype** in `Sources/SwiftTUIRuntime/Rendering/FrameTailPresentationDamage.swift`,
  gated behind `SWIFTTUI_OVERLAY_INCREMENTAL_DAMAGE=1` (**default off**). When a topology
  change is purely an additive overlay over an unchanged background, it emits bounded
  raster-reuse damage (overlay leaf rows ∪ invalidated-trigger rows) instead of forcing a
  full fresh re-raster. Proven sound (0 mismatches under `SWIFTTUI_RASTER_VERIFY_INCREMENTAL=1`
  for both palette and popover), but it targets only the ~9% raster slice and barely moves
  `raster_ms` because raster is dominated by fixed full-surface allocation/copy, not painted
  rows. Kept as a gated, validated proof of concept.

## Recommended next step (larger, dedicated effort)

The real lever is **teaching the resolver to consult `reusableSnapshot` for disjoint
*descendants* of a dirty re-resolving node** (the sheet/palette content under the
`isPresented` owner). Combined with the `isFocused` snapshot exclusion *once the
scroll-capture interaction is resolved*, that attacks the ~70% resolve+measure open cost.
It is a higher-risk change to the resolve hot path with broad blast radius — the scroll
regression from the smaller `isFocused` change is a clear signal that this needs its own
focused, fully-validated effort rather than a rushed change.

The reverted `isFocused` prototype is preserved at `/tmp/Environment.swift.fix` and
`/tmp/StyleEnvironment.swift.fix` for reference.
