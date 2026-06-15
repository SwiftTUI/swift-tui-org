# Sheet-Open Cone Fix — Redundant Post-Action Follow-Up (results)

- **Date:** 2026-06-15
- **Status:** Implemented + measured. The dominant sheet-open cone mechanism is
  fixed; a second (smaller) mechanism remains as a follow-on.
- **Builds on:**
  [cone source: portal not focus](2026-06-15-sheet-open-cone-source-portal-not-focus.md),
  [cone narrowing design](../plans/2026-06-15-002-sheet-open-cone-narrowing-design.md).
- **Gap:** G4 (coarse runtime invalidation identity) — resolved for this path.

## Pinned cause (corrects the design's scene-level hypothesis)

The design doc hypothesized a scene-level `[rootIdentity]` source
(`FocusTracker` / `SceneSessionState`). The `SWIFTTUI_INVAL_TRACE` decomposition
plus caller attribution (`[INVAL-SRC]` labels at the `@State` write and
post-action sites) **refuted that** and pinned the real injector:

- `FocusTracker` is ruled out (it invalidates the scoped `{prev,current}` focus
  identities, only on a focus change → would set `focus_changed`; the dominant
  frames are `selective=true` with no `focus_changed`).
- `SceneSessionState` is ruled out (the struct is empty and never mutated).
- **The injector is the clicked button's post-action follow-up.** The trace shows
  `[INVAL-SRC] post-action={…/Layout[0]}` immediately preceding each dominant
  `raw={…/Layout[0]} selective=true` frame. `Button` registers
  `followUpInvalidationIdentity: dynamicPropertyScope?.viewIdentity`
  (`Button.swift:126`) — the enclosing `@State`-owning view. For the co-located
  trigger that is `PerfSheetLatencyProbeView` = `Layout[0]` (the content root,
  ancestor of the whole background). After the click,
  `flushPostActionInvalidations` invalidates it, sweeping the background.

This is the **owner-invalidation anti-pattern reader attribution removed from the
`@State` write side (Lever A)**, still present on the post-action side. It is
redundant: the action's `@State` write already invalidates the precise readers
(or the owner, via the no-reader fallback). The SPIKE A/B confirms the mechanism
end-to-end: in the spike the button lives in a *sibling* `@State` view, so its
follow-up targets the sibling (not an ancestor) → no cone.

## The fix

`RunLoop.recordFollowUpInvalidation` (used by both the mouse `handleMouseUp` and
keyboard `handleKeyPress` action paths): **skip the owner-scope follow-up when
the dispatched action already requested an invalidation**, keeping it as a
backstop only when the action requested nothing (untracked side effects). The
"did the action invalidate" signal is the scheduler's coalesced invalidation set,
snapshotted around `localActionRegistry.dispatch`
(`FrameScheduler.pendingInvalidatedIdentities`, read via the sole concrete
conformer). Gated on `ReaderAttributionConfiguration.isEnabled`, so
reader-attribution-off is byte-identical (the follow-up always inserts).

**Correctness is by construction:** the follow-up is skipped *only* when the
dispatch already invalidated, so a frame is already scheduled and the action's
own (reader-attributed) invalidation covers the change. The follow-up cannot be
the sole re-render trigger in the skipped case.

## Measured A/B (release, `sheet-open-latency` rows 176, async, same-session, 8 iters each)

Isolated to the fix (baseline = the prior pin with reader attribution on; the
diagnostic is inert when off):

| metric | baseline | fixed | delta |
| --- | ---: | ---: | ---: |
| `total_cpu_seconds` (median) | 1.4409 | 1.1649 | **−19.2%** |
| `cpu_seconds_per_committed_frame` | 0.0800 | 0.0690 | **−13.8%** |
| `frame_interval_p50_ms` | 55.3 | 27.8 | **−49.7%** |
| `head_prepare_p50_ms` | 27.8 | 11.0 | **−60.6%** |

CV ~1–2%; the delta is far beyond noise and matches the structural change: the
`SWIFTTUI_INVAL_TRACE` shows `post-action={Layout[0]}` now fires **0 times** and
the dominant `raw={Layout[0]} selective` frame is **gone** (the 14
full-background-recompute frames per run now reuse).

## Remaining (mechanism 2 — next follow-on)

The cone is not fully collapsed to the spike floor (14). A second, smaller
mechanism remains on the focus-settle frames:
`force-root-reasons=[focus_changed, frame_state_force_root]` with the
newly-inserted overlay-entry identities translated to the portal host
(`__TerminalUIPortalHost`, an ancestor of the background). Max residual
`invalidation-conflict` ≈ 884 on those frames. That is a separate fix (focus-
change force-root narrowing + the Stage-1A overlay→portal-host translation
landing on an ancestor) for its own PR.

## Guardrails

- **Focused test** `InteractiveRuntimeTests.postActionFollowUpSkippedWhenActionAlreadyInvalidated`:
  skip-when-invalidated, backstop-when-quiet, byte-identical-when-flag-off.
- **Full repo gate** green — the interactive-demo tests drive button actions
  through the changed `handleKeyPress`/`handleMouseUp` path (e.g. the accent-
  preview toggle), so button→re-render is behaviorally guarded.
- The fix touches only the post-action follow-up — **not** `conflictsWithInvalidation`
  (H2/H3 reuse) nor H1 elision nor the Part 0 orphaning seam.
- New diagnostic `SWIFTTUI_INVAL_TRACE` (+ caller-attribution `[INVAL-SRC]`
  labels) lands as durable infra on the shared `DiagnosticTraceSink`.
