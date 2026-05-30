# SwiftTUI H2 — Resolve-Reuse Findings

**Date:** 2026-05-30
**Plan:** [`docs/plans/2026-05-30-001-perf-h2-resolve-reuse-complete-plan.md`](../plans/2026-05-30-001-perf-h2-resolve-reuse-complete-plan.md)
**Motivating report:** [`docs/reports/2026-05-28-gallery-performance-report.md`](2026-05-28-gallery-performance-report.md) (§ H2 — per-interaction `resolve` cost)
**Code:** `swift-tui` commits `9e655f80` (enabler + scenario), `da38a946` (scoped-reuse fix), `21afc0dc` (flake register).

---

## TL;DR

- **Symptom (from the gallery report).** A single Calculator button click cost
  `resolve` **13.9 ms** — the runtime re-resolved a large slice of the view tree
  for a tiny visual change. H2's thesis: resolve cost should scale with *what
  changed*, not with *total tree size*.
- **Root cause.** `ViewNode.canReuse` gated retained reuse on full equality of
  the resolve-time `TransactionSnapshot`, including its per-frame
  `debugSignature` (the frame's cause summary, e.g. `"invalidation"`,
  `"input+invalidation"`). That string changes almost every frame, so reuse
  **never fired** on interaction frames and the whole tree re-resolved each time.
- **Fix.** Compare transaction *intent* (`isReuseEquivalent`, ignoring
  `debugSignature`) instead of full equality (the enabler), then **scope reuse
  off only on frames that are unsafe to reuse** — a focus move or an in-flight
  property animation — via a new `suppressRetainedReuse` flag.
- **Result.** Resolve work per interaction frame is now ~flat in tree size
  (`resolved_computed` ≈ 17–20 nodes regardless of tree size, vs. 68→356 before),
  cutting steady-state `resolve_ms` by **41–62%** and total CPU by **12–23%**,
  with the win *growing* as the tree grows.
- **Two corrections to the prior plan** are documented below: (1)
  `forceRootEvaluation()` does **not** disable retained reuse; (2) the
  "animation/elision gap" was a **phantom** — a pre-existing load-flaky test, now
  in the [flake register](../../swift-tui/docs/KNOWN-TEST-FLAKES.md).

---

## Root cause

`Sources/SwiftTUICore/Resolve/ViewNode.swift` `canReuse` ended with
`&& committed.transactionSnapshot == transaction`. The run loop builds each
frame's `TransactionSnapshot` with `debugSignature: causeSummary`
(`RunLoop+ResolveContext.swift`), where `causeSummary` is the sorted set of the
frame's wake causes. Because that signature differs frame-to-frame, the `==`
rejected every candidate node, so **no subtree was ever reused on an
invalidation frame** — the whole tree re-resolved regardless of how little
actually changed.

The framework already shipped the intended comparator,
`TransactionSnapshot.isReuseEquivalent(to:)` (compares `animationRequest` +
`animationBatchID`, ignores `debugSignature`), but it was unused. Switching
`canReuse` to it is the one-line **enabler**.

## The fix: scoped reuse

The enabler alone is unsafe — the prior always-recompute behavior masked two
reuse-path gaps:

1. **Focus.** `focusedIdentity` is deliberately excluded from
   `EnvironmentSnapshot` equality (tested invariant: runtime focus/press state
   must not affect environment equality). So a focus move does not defeat reuse
   of a focus-reading subtree (`EnvironmentReader(\.focusedIdentity)`), which
   then renders stale focus.
2. **Animation.** A reused subtree's body never re-runs, so an off-screen
   `repeatForever` is never re-registered and `activeAnimationCount` decays.

The fix keeps reuse correct by **refusing to reuse on reuse-unsafe frames**
rather than trying to make reuse correct under focus/animation. A frame-scoped
`suppressRetainedReuse` flag is threaded
`RunLoop → frameState → FrameResolveInputs → ResolveContext → resolveView` and set
(alongside `forceRootEvaluation`) when:

- focus changed since the previous committed frame (`previousFrameFocusIdentity`), or
- `activeAnimationCount > 0 || lastTickResult.hasPendingWork`.

Reuse therefore fires only on **inert** interaction frames — rapid same-focus,
no-animation interaction (the H2 target: Calculator clicks, typing in a static
form). Focus-change frames (user-paced) and animation frames (already a full
render) pay a full recompute.

### Correction 1 — `forceRootEvaluation()` does not disable reuse

The plan assumed extending the existing `forceRootEvaluation()` gate would
produce a no-reuse frame. Runtime instrumentation disproved this: the gate fired
yet a disjoint subtree was still reused. `forceRootEvaluation` only forces the
walk to **reach** every node (root evaluation vs. selective frontier); each
reached node *independently* takes the reuse fast path in `resolveView` →
`reusableSnapshot`, gated solely by invalidation-disjointness. A full no-reuse
frame needs **both**: `forceRootEvaluation` (reach) **and** `suppressRetainedReuse`
(recompute). Suppression is scoped to the safety gate only — focus-sync
*rerenders* must keep reuse, or the TextEditor caret-scroll two-pass mechanism
loses its first-pass measurement state.

### Correction 2 — the "animation/elision gap" was a phantom

`OffscreenFrameElisionRuntimeTests` "off-screen deadline tick elides…" was
believed to be a reuse-induced animation regression. It is in fact a
**pre-existing, load-sensitive flaky test**: it fails under heavy parallel gate
load on **`main` with zero retained reuse** (3/3 runs), on the enabler-only
commit, and with the fix — all at the same assertions — and **passes in
isolation** on all three. It is a real-time-`.now()` deadline race, not a reuse
bug. The earlier "enabler caused it" attribution was an isolation-vs-load
artifact. It is now recorded in the
[known-test-flakes register](../../swift-tui/docs/KNOWN-TEST-FLAKES.md).

## Measurement

Scenario `synthetic-narrow-invalidation` (a narrow per-frame invalidation into a
disjoint-sibling tree), release build, `--modes async --iterations 15`, swept
over `TERMUI_PERF_INVALIDATION_TREE_ROWS ∈ {6, 20, 40}`. "Base" = enabler
toggled off (no reuse, scenario present); "Candidate" = enabler + scoped fix.
Means over steady-state invalidation frames.

### Resolve work per frame — now flat in tree size

| Tree rows | `resolved_computed` base | `resolved_computed` candidate | `resolved_reused` candidate |
| ---: | ---: | ---: | ---: |
| 6  | 68  | **17** | 54  |
| 20 | 186 | **18** | 179 |
| 40 | 356 | **20** | 358 |

This is the core win: without reuse, recomputed-node count scales linearly with
the tree (68 → 356); with reuse it is **~constant (≈18)** — only the invalidated
subtree recomputes, everything disjoint is reused.

### `resolve_ms` per frame and total CPU

| Tree rows | `resolve_ms` base | `resolve_ms` candidate | Δ resolve | total CPU-s base | total CPU-s candidate | Δ CPU |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 6  | 1.035 | 0.615 | **−41%** | 0.0978 | 0.0859 | −12% |
| 20 | 3.456 | 1.762 | **−49%** | 0.2152 | 0.1720 | −20% |
| 40 | 5.208 | 2.002 | **−62%** | 0.3662 | 0.2804 | −23% |

The reduction **grows with tree size** — the larger the tree, the more is reused
— confirming H2's "scale with what changed" thesis.

### Honest caveat

`resolve_ms` does not go fully flat (0.6 → 1.8 → 2.0 ms) even though
`resolved_computed` is flat: the reuse path still *visits* every node to assemble
the committed snapshot (bookkeeping is O(tree)), while only the changed subtree
is *recomputed* (O(changed)). The remaining tree-proportional cost is snapshot
assembly, not resolution — a candidate for a later optimization (e.g. retained
snapshot subtrees), tracked as a follow-on, not part of H2.

## Verification

- Focus reuse-correctness tests (`runtimeFocusMovementWritesBackIntoRenderedFocusIdentity`,
  `arrowKeysUseGeometryAwareTopLevelFocusTraversal`) and the TextEditor
  caret-scroll test pass deterministically.
- New regression test `disjointSiblingReuseSurvivesDebugSignatureChange`
  (`ResolveReuseAncestorInvalidationTests`) guards the enabler: a disjoint
  sibling must reuse across a `debugSignature` change.
- Full `bun run test` is green except the pre-existing load-flaky elision test
  (see flake register); that test fails identically on `main`.

## Remaining / follow-ons

- **Persistent-animation apps get no reuse win on interaction frames** (the gate
  suppresses reuse whenever any property animation is live). Acceptable v1; a
  later refinement could exclude only the animating subtree rather than the whole
  frame.
- **Snapshot-assembly cost** is still O(tree) (the caveat above).
- **Harden the flaky elision test** to be load-deterministic (controlled clock,
  or assert on frame causes rather than elision count) — separate from H2.
