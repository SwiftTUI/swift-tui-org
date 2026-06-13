# Bug B: toolbar strip re-resolve — implementation proposal

**Date:** 2026-06-13 · **Status:** designed, measurement-first implementation pending ·
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
   `action` is a closure — excluded; it does not affect the rendered strip and is
   re-captured each frame regardless.

2. **Cache** keyed by toolbar-host `Identity` → `(ToolbarStripSignature,
   ResolvedNode)`. Store on the `ViewGraph` (survives frames; pruned with the
   host identity) — *not* on the per-frame-rebuilt host node.

3. **In `reconciledToolbarHost`**, before building the strip: if
   `cache[hostIdentity].signature == currentSignature`, reuse the cached strip
   `ResolvedNode` via `viewGraph.recordReusedSubtree(cachedStrip, invalidator:,
   retained: true)` and use it as `stripNode`; else resolve fresh and update the
   cache. This must run at the **resolve-time** site (well-timed: during resolve,
   before `finalizeFrame`). The **late-reconcile** site needs separate timing
   verification (it runs in the frame tail before commit; confirm `frameOrder`
   is still open then).

## Open implementation question

`ToolbarItemConfig.icon` is an `Image` (a `PrimitiveView`; equatability not
guaranteed). The signature must be **sound** — when it cannot prove items are
unchanged it must fall back to a fresh resolve, never reuse stale. Either make
the icon comparable via a stable descriptor, or omit reuse when any item carries
an icon (conservative first cut).

## Required validation (do not skip — crash-class hot path)

- **Byte-equivalence.** The committed tree AND the runtime-registration restore
  order must be identical with the cache on vs off (cf. `normalizeScopedRestoreOrder`
  discipline from the commit_ms fix). Add an equivalence test, verified RED.
- **Perf A/B.** Before/after on a late-bubbled-toolbar scenario (the gallery, or
  a layout-dependent-toolbar harness) with the standard metrics.
- **Full gate** (`bun run test`) + **gallery suite** (must stay green; the
  stamp-skip crash class lives here).
- **Stale-`.build` trap.** This area has hit SIGBUS on struct growth ×3 — clean
  `.build` if structs change (cf. memory).

## Measurement harness already in place

`Tests/SwiftTUITests/TabTaskActivationRuntimeTests.swift` (toolbar-wrapped)
reproduces the re-resolve; a `Swift.print("STRIPPROBE…")` in
`ToolbarItemsStrip.resolveElements` counts it (8 baseline). A
late-bubbled-toolbar variant (toolbar items contributed by layout-dependent /
deferred content) is needed to exercise the late-reconcile site.

## Recommendation

**GO** — the cost is confirmed real. Implement as a **focused pass** (own PR):
design is complete, the measurement harness exists, and the only open piece is
the icon-signature soundness above. It is deliberately *not* bundled with Bug A
because the change is in the byte-equivalence-sensitive retained-reuse hot path
that every prior perf PR (H2/H3/place_ms/commit_ms) treated with A/B +
equivalence proofs, and Bug A already removed the user-visible symptom — so the
landing should get fresh context and the full equivalence/A-B gauntlet rather
than a rushed same-session attempt.
