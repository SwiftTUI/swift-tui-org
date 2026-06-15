# Sheet-Open Cone Mechanism 2 — Portal-Translation Root Fallback (results)

- **Date:** 2026-06-15
- **Status:** Implemented + measured. With this + the mechanism-1 fix, the
  steady-state sheet open/close invalidation cone is **eliminated**.
- **Builds on:**
  [mechanism-1 fix](2026-06-15-sheet-open-cone-followup-fix-results.md),
  [cone source: portal not focus](2026-06-15-sheet-open-cone-source-portal-not-focus.md).
- **Gap:** G4 (coarse runtime invalidation identity / Stage-1A translation).

## Pinned cause (measured)

After the mechanism-1 fix, a residual ~884 `invalidation-conflict` cone remained
on the focus-settle force-root frames, conflicting against the portal host
`__TerminalUIPortalHost/App/sheet-open-latency` (the **graph root**, an ancestor
of the background). The `SWIFTTUI_INVAL_TRACE` decomposition pinned it precisely:

- **8 frames** where `xlated` *adds* the portal-host root; **0 frames** where
  `raw` contained it. The portal-host root enters **only via the Stage-1A
  translation**.
- Example: `raw={…trigger, …/overlays/entry:<X>}` →
  `XLATED={…trigger, __TerminalUIPortalHost/App/sheet-open-latency}`.

`ViewGraph.presentationPortalInvalidationTarget` mapped an unmapped deep
overlay-entry identity (the *sheet content*, a disjoint sibling of the
background) up to `portalRootIdentity` (the graph root) when the overlay host
node was not yet materialized. Because the portal host is an ancestor of the
content, that swept the entire background into the reuse-conflict cone.

## The fix

Remove the `portalRootIdentity` fallback from
`presentationPortalInvalidationTarget`. An unmapped overlay-entry identity now
maps to the overlay host (a disjoint sibling, when it exists) or **stays
unmapped** — never to the portal root. Staying unmapped keeps it disjoint from
the background; the publication falls to `.all`, which is already the case on
these force-root frames. The portal root still re-resolves to compose the
overlay because `installPresentationPortalEvaluator` force-queues it whenever the
invalidation set is non-empty — so this translation was redundant for
composition and harmful only for background reuse.

The Stage-1A characterization test that pinned the old fallback
(`presentationEntryUnderLivePortalRoot…`) is updated to a **regression guard**
for the new behavior (stays unmapped, does not sweep the content root). All 27
`ViewGraphTests` pass (the overlay-host mapping path is unchanged).

## Measured A/B (release, sheet-176, async, same-session, 8 iters each)

Baseline = the mechanism-1-fixed pin; fixed = + this change:

| metric | baseline (m1) | + m2 | delta |
| --- | ---: | ---: | ---: |
| `total_cpu_seconds` | 1.1778 | 0.9700 | **−17.6%** |
| `cpu_seconds_per_committed_frame` | 0.0694 | 0.0574 | **−17.2%** |
| `frame_interval_p50_ms` | 28.2 | 27.4 | −2.6% |
| `head_prepare_p50_ms` | 11.1 | 10.9 | −1.8% |

The win is resolve-CPU efficiency (the background now reuses on the force-root
settle frames); the wall-clock `frame_interval` is gated by non-resolve costs
(raster, force-root spine walk).

**Cumulative (mechanism 1 + 2 vs the original pin):** total_cpu **1.441 → 0.970
= −32.7%**.

## Cone fully collapsed (steady state)

The `SWIFTTUI_REUSE_TRACE` after both fixes shows **zero `invalidation-conflict`**
on steady-state cycle frames. The only large recompute counts remaining are
one-off: `no-node≈893` (frame-1 cold start) and `suppressed≈895` (first-open
warmup). Every steady-state open/close cycle frame has `suppressed ≤ 42` (the
genuinely-changed nodes: trigger, overlay, focus leaves). The disjoint background
reuses across the whole cycle.

## Remaining

The steady-state cone is gone. Further sheet-open wall-clock reduction would come
from non-resolve phases (raster on the surface-topology change; the force-root
spine walk on focus-settle frames — the `focus_changed`/`frame_state_force_root`
gate, which is the higher-risk G5 focus-narrowing territory). Those are separate,
lower-EV efforts; the dominant recompute cone — the perf phase's headline sheet
residual — is resolved.
