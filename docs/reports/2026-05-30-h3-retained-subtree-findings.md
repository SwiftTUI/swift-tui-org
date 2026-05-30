# SwiftTUI H3 — Retained-Subtree Bookkeeping Findings

**Date:** 2026-05-30
**Plan:** [`docs/plans/2026-05-30-002-perf-h3-retained-subtree-bookkeeping-plan.md`](../plans/2026-05-30-002-perf-h3-retained-subtree-bookkeeping-plan.md)
**Predecessor:** [`docs/reports/2026-05-30-h2-resolve-reuse-findings.md`](2026-05-30-h2-resolve-reuse-findings.md)
**Code:** `swift-tui` branch `perf/h3-retained-subtree-bookkeeping` — `cdd68e9b` (dedup), `72981c7a` (node.apply fast path), `1526e21a` (retained-subtree skip + guards). Base `main` @ `93e9ea3d`.

---

## TL;DR

- **Measurement-first paid off twice.** Profiling the two deferred follow-ons on the
  now-stable harness picked **H3** over H1-Approach2 (scaling residual on the common
  path vs. a flat, off-screen-only, high-risk win). Then reading the code before
  building overturned the investigation's own central claim — the "redundant double
  `recordReusedSubtree`" was a guarded **O(1) no-op**, not an O(tree) walk — so the
  dedup shipped honestly as perf-neutral cleanup, not a fake win.
- **The real residual.** With H2 reuse firing (recompute flat at **17 nodes** across
  all tree sizes), the per-interaction frame still scaled O(tree): `resolve_ms`
  0.60/1.03/1.73 ms at tree rows 6/20/40. The cost was `frameOrder` being repopulated
  with every reused node, driving `recordReusedSubtree`'s recursion and `finalizeFrame`'s
  sweep (both counted in `resolve_ms`).
- **The fix (H3).** When a reused subtree is fully disjoint from the frame's
  invalidation, record only its root and **skip the descendant recursion** — the
  descendants' committed state, presence, and liveness all carry forward across
  `beginFrame` (`liveIdentities` is never rebuilt; the per-frame GC is not on this path).
- **Result.** `resolve_ms` **−22 / −41 / −49%** (growing with tree size), the slope
  flattened **2.87× → 1.87×**, total CPU **−4…6%** (scaling), recompute still flat at 17.
- **Honest residuals.** `commit_ms` (frame-tail commit) and `place_ms` (layout) are
  **separate** O(tree) costs that H3 does not touch — and after H3, `commit_ms` (2.45 ms
  at rows=40) is now the *largest* interaction-frame residual. Tracked as follow-ons.

---

## Why H3, not H1-Approach2

Both deferred follow-ons (from [[perf-h1-offscreen-elision-status]] and
[[perf-h2-resolve-reuse-status]]) were profiled at `93e9ea3d`:

| | H3 — retained-subtree bookkeeping | H1-Approach2 — wakeup coalescing |
| --- | --- | --- |
| Residual | scaling O(tree) reuse bookkeeping | flat off-screen idle floor (~0.037 CPU-s/iter synthetic) |
| Path | **every** narrow interaction in a non-trivial tree | only fully off-screen animated content |
| Risk | medium — narrows an *existing* guarded fast path | **high** — re-introduces a wake gate removed twice (the restart trap, `RunLoop+Rendering.swift`, `60665914`→`7ef12233`) + completion-deadline hang exposure |

H3 wins on impact ÷ effort: a scaling residual on the common path, lower risk, and the
win grows with real app depth. H1-Approach2 is deferred until a workload is shown to
spend material time fully off-screen.

## Root cause / mechanism (source-confirmed)

`ViewGraph.frameOrder` accumulates every node touched in a frame. On a reuse frame it is
O(total live nodes), and `recordReusedSubtree` (`ViewGraph.swift:695`) unconditionally
recurses over every reused node (`:712`), appending each to `frameOrder` and running
per-node bookkeeping (`prepareForFrame`, `beginReuse`, `applyStructuralChildDiff`,
`node.apply` — which re-parents children and walks ancestors via
`invalidateAncestorCachedSnapshots`, O(depth) per node). `finalizeFrame` (`:894`) then
iterates the whole `frameOrder` again. For an *unchanged* retained subtree, all of this
re-establishes state that is already correct from the prior frame.

**Two investigation corrections (both caught by reading the code before building):**

1. **The "double `recordReusedSubtree`" is a guarded no-op.** `resolveView`'s second call
   (`ViewFoundation.swift:270`) hit the `wasVisitedThisFrame` guard at
   `recordReusedSubtree:702` and returned at the root — O(1), not a second O(tree) walk.
   Removing it (`cdd68e9b`) is correct cleanup but **perf-neutral** (confirmed: a
   before/after sweep moved nothing beyond ±stddev).
2. **The presence/GC model already carries forward, so H3 is simpler than the plan
   feared.** `pruneDetachedIdentitySubtree` (the GC) has **zero callers** — not on the
   interaction-frame path. `liveIdentities` is only `formUnion`'d / explicitly removed,
   never rebuilt, and `beginFrame` does not reset it or `hasCommittedPresence`. So a
   descendant skipped this frame **stays present, alive, and live by default** — no new
   presence registry or GC exemption was needed.

## The fix

`recordReusedSubtree(_:invalidator:retained:)` gains a `retained` flag. When set (passed
from both of `reusableSnapshot`'s fully-disjoint reuse sites — the no-identity-intersection
and the no-conflict paths), it records the root (`beginReuse` + `frameOrder.append` +
`node.apply` via the same-children fast path) and **returns without recursing into
descendants**. The structural diff is skipped with the recursion (the disjointness check
already proved no structural change).

A small precursor (`72981c7a`) gave `ViewNode.apply` a same-children fast path that skips
the identity `Set` + no-op detach/re-parent loops when the recorded children are exactly
the attached nodes; measured marginal (~2–5% `resolve_ms`) but kept as it also helps
partially-intersecting reuse and the retained root's own re-apply.

## Measurement

Scenario `synthetic-narrow-invalidation`, release, `--modes async --iterations 20`, swept
over `TERMUI_PERF_INVALIDATION_TREE_ROWS ∈ {6,20,40}`. Steady-state = invalidation frames
≥ 4. Machine quiet (1-min load ≤ 2.5), all CVs ≤ 4.2%.

| Tree rows | total nodes | `resolved_computed` | `resolve_ms` base → H3 | `commit_ms` base → H3 | `place_ms` | total CPU-s/20 base → H3 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 6  | 67  | **17** | 0.603 → **0.471** (−22%) | 0.325 → 0.311 | 0.18 (flat) | 0.0818 → 0.0787 |
| 20 | 193 | **17** | 1.028 → **0.608** (−41%) | 1.311 → 1.269 | 0.42 (flat) | 0.1620 → 0.1537 |
| 40 | 373 | **17** | 1.729 → **0.881** (−49%) | 2.578 → 2.450 | 0.79 (flat) | 0.2582 → 0.2435 (−5.7%) |

- **`resolve_ms` slope flattened 2.87× → 1.87×** across the sweep; the win *grows* with
  tree size, exactly the H3 thesis. The residual 1.87× is the O(width) cost of the
  per-sibling `canReuse`/disjointness checks (40 rows = 40 reuse points), closer to inherent.
- **`finalizeFrame` is counted in `resolve_ms`**, which is why skipping the `frameOrder`
  walk shows up there (and is larger than the recursion skip alone would give).
- **`commit_ms` and `place_ms` are separate O(tree) residuals** — the frame-tail commit
  and the layout walk — untouched by H3. After H3, `commit_ms` (2.45 ms at rows=40) is
  the largest remaining interaction-frame cost.

## Verification

- New `RetainedSubtreeReuseTests` (3): a disjoint sibling stays reused and renders its exact
  content across 6 repeated invalidation frames; a deeply nested disjoint subtree survives
  reuse intact; a retained subtree recomputes correctly after later being invalidated.
- Existing guards green: `disjointSiblingReuseSurvivesDebugSignatureChange`, the focus
  write-back / geometry-traversal tests, the TextEditor caret-scroll test.
- **Full `bun run test` gate green** (all targets + every policy check). The runtime
  suite's `OffscreenFrameElisionRuntimeTests` is load-flaky under the full parallel gate
  (it asserts before any reuse, so H3 cannot affect it; confirmed 1378/1378 serialized and
  11/11 in isolation) — see [[swift-tui-runloop-segv-known-flake]] and the
  [flake register](../../swift-tui/docs/KNOWN-TEST-FLAKES.md).

## Remaining / follow-ons

- **`commit_ms` (frame-tail commit) is now the largest interaction-frame residual** and is
  O(tree) for a different reason than resolve. The highest-leverage next perf target.
- **`place_ms` (layout walk)** is a separate O(tree) reuse-bookkeeping cost.
- **The off-screen floor A/B** (0.7475 vs the published 0.4751 CPU-s/20) is unresolved — a
  same-machine A/B at `3aaa8282` vs HEAD would settle whether H2's per-resolve bookkeeping
  measurably regressed animation-frame resolve. Not blocking.
- **H1-Approach2** remains deferred (high risk, off-screen-only).
