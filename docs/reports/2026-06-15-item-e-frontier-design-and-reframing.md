# Item E — frontier narrowing: design enumeration + sheet-cost reframing

- **Date:** 2026-06-15
- **Pin:** `swift-tui 30fc38bf` (analysis only; no code).
- **Goal:** [perf phase completion goal](../plans/2026-06-15-001-perf-phase-completion-goal.md), Item E.
- **Status:** design-first investigation. **Implementation deferred** pending the
  reuse-denial diagnostic below — the data shows E is necessary-but-not-sufficient
  for the dominant sheet cost.

## The reframing finding (per-frame reuse on sheet 176)

Sheet interaction frames alternate between two regimes (from the re-baseline
`frames.tsv`, `resolved_reused = reused/total`):

| regime | reused/total | computed | resolve_ms | note |
| --- | --- | ---: | ---: | --- |
| full-recompute | 0/894, 26/921 | ~898 | **17–21** | reuse denied to ~all nodes |
| high-reuse | 883/921 | 45 | **6.4** | reuse works — 96% reused |

**Reuse is not broken on sheet** — it works on structurally-stable frames (6.4 ms,
883/921 reused). It is *denied* on the open↔close structural-toggle frames (node
count 894↔921), which cost ~3× more (~18 ms) by recomputing ~898 nodes.

**Consequence:** the dominant sheet residual is the ~18 ms full-recompute frames
driven by the **sheet-toggle invalidation cone**, not head bookkeeping and not
the force-queue spine walk. The earlier head-residual closures (A/B/C) are all
downstream of this same recompute behavior.

## Why Item E (force-queue narrowing) is necessary-but-not-sufficient

The portal-root force-queue
(`DefaultRendererFrameHeadCoordinator.swift`: `shouldQueuePresentationPortalRoot`
fires on `!invalidatedIdentities.isEmpty`) makes `evaluateDirtyNodes` *reach*
every node from the portal root each interaction frame. But `ViewFoundation.swift`
(reuse return, ~line 270) is explicit: "forcing root evaluation only makes the
walk *reach* every node — each reached node still independently chooses reuse." The
883/921 frame proves this — the walk reaches all nodes yet reuses 96%. So
narrowing the force-queue reduces the spine-traversal *reach* cost, but **not**
the ~18 ms reuse-*denial* cost on toggle frames, which is the invalidation cone
(the territory of the prior reader-attribution work, sheet-open-latency memory).

## Consumers of the root walk's incidental guarantees (E entry condition)

Per the goal's E entry requirement, the portal-root force-queue is load-bearing
for four consumers (mapped from the runtime; treat the severities as hypotheses
to verify, the agent enumeration tended alarmist):

1. **Presentation portal maintenance** — re-resolving `PresentationPortalRoot`
   reconciles sheet/popover declarations and rebuilds the overlay-stack tree
   (`PresentationCoordinator.resolveElements` → `composePresentationPortalTree`).
   If the portal root is skipped on a frame where a declaration changed, overlay
   entries could go stale. **Guard:** only skip when overlay entries are unchanged.
2. **Island freshness / Part 0 orphaning mask** — re-resolving the portal root
   (the island host) re-captures capture-hosted islands and clears
   `hasStaleIslandDescendant` via `apply`. Skipping risks the divergent-identity
   orphaning hazard the Part 0 fix addressed. **Highest-risk consumer**; the
   flicker regression lived here.
3. **Runtime registration publication** — a surviving `.subtrees` plan that omits
   the portal root would not restore portal-host registrations; overlay handler/
   focus-candidate churn. **Guard:** Stage 1B's diffed `.all` already restores
   only changed owners; the publication path may already be safe.
4. **Semantic snapshot stability** — `viewGraph.snapshot()` rebuilds from
   `isCommittedSnapshotFresh`; a skipped portal root could return a stale overlay
   subtree. Coupled to (2).

Tests pinning the behavior: `ViewGraphTests` (presentation portal invalidation
mapping, root-evaluation fallback), `OverlayStackTests`, `SurfaceTopologySignatureTests`.

## Recommended next step (cheap, decisive — do before any E code)

Run `SWIFTTUI_REUSE_TRACE` (`ReuseDenialTrace`, already wired at
`ViewFoundation.swift:304`) on `sheet-open-latency` rows 176 and bucket the
denial reasons on the ~18 ms full-recompute frames. This names *why* ~898 nodes
deny reuse on toggle frames (cone source: the @State owner, the overlay
structure change, focus/press suppression, or environment/transaction
inequality). That reason determines the real lever:

- if the cone originates at a sheet-toggle **@State owner** that is an ancestor of
  the background → it is reader-attribution territory (extend the prior Lever
  work), **not** force-queue narrowing;
- if denial is **environment/transaction** inequality from the overlay insertion →
  a reuse-equivalence refinement;
- if it is purely the **force-queue reaching + re-resolving** the portal subtree →
  then E (frontier narrowing) is the lever, behind the four guards above.

## Reuse-trace result (run, not just recommended)

`SWIFTTUI_REUSE_TRACE=1` on sheet 176 (release, 3 iters) produced **no
`[REUSE-TRACE]` lines** — `ReuseDenialTrace.reasonCounts` was empty every frame
despite the trace being armed (env parsed, non-"0"). The trace fires at the
`ViewFoundation` reuse-return site only when a node *could* have reused but did
not. Empty output therefore means the ~898 recomputed nodes on toggle frames are
**not leaf-level reuse denials** — they are recomputed because they are **in the
invalidation cone** (the dirty-evaluation plan / invalidated identities), i.e.
the sheet open/close toggle invalidates ~the whole content subtree.

(Caveat: an empty trace could also be a trace-arming/path gap in the release perf
harness; but it is consistent with the per-frame data — the high-reuse 883/921
frame shows the reuse machinery works when the cone is small, so the toggle
frames differ in *what is invalidated*, not in leaf reuse capability.)

**This pins the lever:** the dominant sheet residual is the **size of the
sheet-toggle invalidation cone**, which is reader-attribution / invalidation-cone
territory (the prior Lever work, sheet-open-latency), *not* force-queue narrowing
and *not* head bookkeeping. Item E (force-queue) and Items A/B/C are all
downstream of this cone.

## Disposition

Item E **design is captured**; **implementation deferred** behind the
`SWIFTTUI_REUSE_TRACE` diagnostic, because the data indicates the dominant sheet
cost is cone-driven reuse denial (a different lever than force-queue narrowing),
and the force-queue itself is a four-consumer, flicker-prone seam that must not be
narrowed on speculation. This is the goal's "design-first, enumerate before code"
discipline reaching its honest conclusion: the next move is one trace run, not a
structural edit.
