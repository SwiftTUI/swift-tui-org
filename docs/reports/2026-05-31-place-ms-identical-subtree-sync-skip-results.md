# Perf — `place_ms` Identical-Subtree Sync-Skip Results

**Date:** 2026-05-31
**Scenario:** `synthetic-narrow-invalidation` (async, 20 iters, release), tree rows 6/20/40.
**Code:** `swift-tui` — adds `ResolvedNode.placementEquivalence(to:)` and skips the
retained-placement metadata sync when a reused subtree is fully identical.
**Probe (archived, not landed):** [`docs/perf/place-sync-skip-probe/`](../perf/place-sync-skip-probe/).

---

## TL;DR

- After the resolve (H2/H3), measure-cache, and `commit_ms` wins, **`place_ms` was the
  largest un-attacked per-interaction residual.** It scaled ~linearly with tree size on
  interaction frames *despite 80–96 % of nodes being reused* — placement retained reuse
  was providing almost no benefit.
- **Root cause:** each reused subtree root pays **three** O(subtree) walks —
  `isEquivalentForPlacement` (the reuse gate) → `synchronizeRetainedPhaseMetadata` (refresh
  the placed node's resolved-metadata mirrors) → `recordPlacedFrames`. The **sync walk**
  unconditionally rebuilt every `PlacedNode` in the reused subtree (reallocating each
  children array) even when nothing changed. Probe attribution: the sync is **25 / 28 / 31 %**
  of `place_ms` (rows 6 / 20 / 40), growing with tree size.
- **Fix:** fold the metadata-equality check **into** the already-required equivalence walk
  (`placementEquivalence` returns `.divergent` / `.geometryReusable` / `.identical`). When a
  reused subtree is fully `.identical`, return the cached placed subtree **untouched** —
  skipping the sync entirely. The metadata check compares fields in place (no per-node
  `PlacedNodeResolvedMetadata` projection), so it adds only a handful of comparisons to a
  walk that already ran.
- **Result (same-sweep A/B, no machine drift):** interaction-frame `place_ms`
  **−23.7 / −29.7 / −28.5 %**; total CPU **−1.2 / −3.9 / −2.8 %**, growing with tree size.
  `resolve` / `measure` / `commit` and the no-reuse initial frame are unchanged within noise —
  the change is cleanly isolated to placement reuse. Byte-identical to the prior behavior and
  sound on `suppressRetainedReuse` (focus/animation) frames (see Soundness).

---

## What changed

`Sources/SwiftTUICore/Resolve/ResolvedNodeEquivalence.swift` — new
`placementEquivalence(to:) -> PlacementEquivalence`:

```swift
enum PlacementEquivalence { case divergent, geometryReusable, identical }
```

It runs the same geometry gate as `isEquivalentForPlacement` and additionally compares the
geometry-stable metadata mirrors (`drawMetadata`, `drawEffects`, `surfaceComposition`,
`semanticMetadata`, `lifecycleMetadata`, `isTransient`, `matchedGeometry`, and the full
`layoutBehavior`; `kind` / `environmentSnapshot` / `layoutMetadata` / `drawPayload` are already
proven equal by the gate, and `semanticRole` derives purely from compared fields). A node is
`.identical` only when its whole subtree is.

`Sources/SwiftTUICore/Measure/LayoutEngine+RetainedLayout.swift` — `retainedPlacement` now
calls `placementEquivalence` once (replacing the `isEquivalentForPlacement` guard) and:

```swift
let skipMetadataSync = equivalence == .identical
func reuse(_ placed) { skipMetadataSync ? placed : synchronizeRetainedPhaseMetadata(placed, from: resolved) }
```

`synchronizeRetainedPhaseMetadata` (the rebuild) is unchanged and still runs on the
`.geometryReusable` path.

## Results (mean ms / committed interaction frame; total CPU s / iteration)

Same-sweep A/B: `baseline` forces the prior always-sync path
(`TERMUI_PERF_PLACE_DISABLE_SYNC_SKIP=1`); `fix` is the shipping path. CV ≤ ~21 %.

| metric | rows=6 | rows=20 | rows=40 |
| --- | --- | --- | --- |
| `place_ms` baseline | 0.194 | 0.526 | 0.933 |
| `place_ms` fix | **0.148** | **0.370** | **0.666** |
| Δ `place_ms` | **−23.7 %** | **−29.7 %** | **−28.5 %** |
| total CPU baseline | 0.0778 | 0.1452 | 0.2161 |
| total CPU fix | 0.0769 | 0.1395 | 0.2101 |
| Δ total CPU | −1.2 % | **−3.9 %** | **−2.8 %** |
| `resolve_ms` (fix vs base) | 0.464 / 0.463 | 0.706 / 0.708 | 1.049 / 1.052 |
| `init_place` (no reuse) | 0.241 / 0.238 | 0.659 / 0.646 | 1.213 / 1.206 |

`resolve` / `measure` / `commit` and `init_place` move only within noise — confirming the win
is isolated to the placement-reuse path. The absolute `place_ms` saving (0.046 / 0.156 / 0.266 ms)
grows with tree size, so the win is larger on bigger trees (e.g. the real 18-tab gallery).

Probe attribution (separate sweep, three O(subtree) walks isolated): the sync walk is
25 / 28 / 31 % of `place_ms`; `recordPlacedFrames` is a further 12–15 %. The fix lands at the
sync-bypass ceiling, so the in-place metadata comparison is nearly free relative to the
avoided rebuild.

## Soundness

- **Byte-identical.** When `placementEquivalence` returns `.identical`, every metadata mirror
  is equal across the subtree, so the cached placed subtree already equals what the sync would
  produce — returning it untouched is a no-op substitution. Pinned by
  `RetainedReuseInvariantTests`: an identical subtree reports `.identical` **and** a sync on it
  is verified a no-op (`==`).
- **No dropped changes.** The check is a direct field comparison, so any changed mirror —
  including one on a *descendant* — yields `.geometryReusable`, forcing the sync. Verified
  RED: forcing `metadataIdentical = true` fails the metadata-only and descendant-change tests.
- **`suppressRetainedReuse` (focus-move / in-flight-animation) frames.** These are the only
  frames where a placement-reused subtree's metadata can actually change (resolve recomputes
  the whole tree while placement still reuses geometry). The fix is sound here *because* it
  compares the recomputed metadata directly — it never assumes "reused ⇒ unchanged". This is
  strictly safer than a cross-phase "resolve-reuse roots" signal, which would need an explicit
  suppress-frame guard.

## What did NOT work (documented so it isn't re-attempted)

**Candidate A — replace the sync with an equality walk that returns the cached subtree when
the *projected* metadata matches — measured INEFFECTIVE, discarded.** It still walked the whole
subtree and **allocated a `PlacedNodeResolvedMetadata` per node** (the `resolvedMetadata`
getter + the projection), trading the sync's children-array reallocation for two struct
projections per node — a wash (rows=40 `place_ms` 0.883 vs baseline 0.877, no change). This is
the same shape as the reverted `commit_ms` "sort cache" (Fix 1): swapping one O(subtree) walk
for another equally expensive one yields nothing. **The win requires *eliminating* a walk, not
swapping one** — which is why the shipping fix fuses metadata detection into the
already-running equivalence walk and returns in O(1) on `.identical`.

## Residual / follow-ons (not done)

- **`recordPlacedFrames` (12–15 % of `place_ms`) is left as-is.** It re-inserts every reused
  node into the per-frame `placedFrameTable`, which is rebuilt empty each frame and **consumed
  the same frame** by GeometryReader / popover anchor resolution for arbitrary in-subtree
  identities. Skipping it loses data needed this frame; a sound version needs a
  carry-forward-and-merge redesign (larger surface, its own miss-resolution risk).
- The fix still pays the `placementEquivalence` walk per reused root (now subsuming the old
  `isEquivalentForPlacement` walk). A true O(1)-per-root skip would require a cross-phase
  "byte-identical carry-forward" signal from resolve; deferred (the in-place comparison already
  captures the sync-bypass ceiling, so the marginal gain is small).
