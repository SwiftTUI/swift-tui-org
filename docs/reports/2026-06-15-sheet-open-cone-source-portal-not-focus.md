# Sheet-Open Cone Source: Portal Machinery, **Not** Focus (measured re-diagnosis)

- **Date:** 2026-06-15
- **Status:** Investigation (no code change). Re-diagnoses the **item 4b**
  invalidation-cone for the perf phase.
- **Pin:** `swift-tui a845dae5` (org `886aa46`) — i.e. *after* Lever A+B, Part 0,
  and Part A all landed.
- **Tooling:** the durable reuse-trace artifact from
  [reuse-trace productization](2026-06-15-reuse-trace-productization-and-cone-confirmation.md)
  (`SWIFTTUI_REUSE_TRACE` → `<artifacts-root>/reuse-trace.log`).
- **Corrects:** the *focus residual* diagnosis in
  [lever-b findings](2026-06-09-lever-b-implementation-and-findings.md) (§RESIDUAL)
  and the `[[sheet-open-latency-rootcause]]` memory. Both attributed the residual
  open-frame cone to focus; **a controlled A/B refutes that.**

## What was already known / fixed (ruled out)

- **Toggle attribution (Lever B):** the `isPresented` read is already isolated to
  a zero-size `__presentationTrigger` sibling (`PresentationTriggerLeaf`,
  shipped `c710bbf5`/`e9b9d00e`). Not the cone.
- **`@State` write-side (Lever A completion, `0cbc2930`):** confirmed still intact;
  a fresh trace shows the `@State`-write OPEN frame invalidates
  `{__presentationTrigger, __TerminalUIPortalHost/…}` with `Layout[0]` **absent**
  and ~5 background conflicts. The open `@State` frame already spares the
  background. Not the cone.
- **Focus (the prior deferred residual):** **refuted by measurement — see below.**

## The decisive A/B (release, `sheet-open-latency`, rows 176, async)

Dominant `invalidation-conflict` cones per config (count × `conflict=N | invalidated`):

| config | dominant cone | reading |
| --- | --- | --- |
| **default** (portal + co-located trigger) | `conflict=890 @ Layout[0]` | baseline cone |
| **`TERMUI_PERF_SHEET_TRIGGER=sibling`** (real portal, focus **de-amplified**) | `conflict=892 @ Layout[0]` | **unchanged** |
| **`TERMUI_PERF_SHEET_SPIKE=1`** (no portal, inline overlay, focus still moves) | `conflict=14` | **cone gone** |

Two independent refutations of the focus hypothesis:

1. **The focus de-amplifier does nothing.** Moving the trigger to a sibling so
   settle-frame focus moves keep the grid container off the focus divergent chain
   leaves the cone at 892 ≈ 890. If focus drove the cone, this would shrink it.
2. **The spike still moves focus but has no cone.** The spike's inline overlay
   takes focus on open exactly like the real sheet, yet the background stays
   reused (`conflict=14`). Focus-into-overlay is therefore **not sufficient** to
   produce the cone.

The only structural variable that moves the cone is the **real presentation
portal** (`.paletteSheet`/`.sheet` → `PresentationPortalRoot` + overlay portal
composition). The trace also shows the **portal host itself**
(`__TerminalUIPortalHost/…`, which is the **graph root** and an ancestor of the
background) getting invalidated (`conflict=884`) on adjacent frames.

> Why static analysis missed this: a 5-agent code-reading pass concluded "focus,"
> because the focus path *can* invalidate the root and *correlates* on settle
> frames. The controlled knob A/B isolates the variable and refutes it. Treat the
> portal machinery as the cone source.

## Structural trap

`installPresentationPortalEvaluator` makes the **portal host the graph root**
(`setRootEvaluator(rootIdentity: portalHost)`), and the content root `Layout[0]`
is a descendant of the portal host's `baseNode`; the large background grid is a
descendant of `Layout[0]`. So **any invalidation that lands on the portal host or
the content root sweeps the entire disjoint background into the reuse-conflict
cone** (`ViewGraph.conflictsWithInvalidation`, ancestor leg). The overlay is a
*disjoint sibling* of the background under the portal root, so opening it should
not invalidate the background's ancestors — but something in the portal path does.

## Open question (next step)

> **PINNED 2026-06-15** (see
> [cone narrowing design](../plans/2026-06-15-002-sheet-open-cone-narrowing-design.md)):
> the `SWIFTTUI_INVAL_TRACE` decomposition shows the dominant `Layout[0]` cone is
> a **direct scene-level invalidation of `[rootIdentity]` (the content root)** on
> selective frames. The real runtime wires both the scene `StateContainer`
> (`SceneSessionState`) and `FocusTracker` with
> `invalidationIdentities: [rootIdentity]` (`HostedSceneSession.swift:145-150`),
> so a portal-driven scene-level focus/state event invalidates the content root
> and sweeps the background. G4 (coarse `[rootIdentity]` scope) feeding G3
> (ancestor conflict). See the design doc for the fix options.

The exact injector for the **dominant `Layout[0]` cone (890)** is not yet pinned.
- The secondary **portal-host cone (884)** is plausibly Stage 1A's
  `translatePresentationPortalInvalidations` (`294b2404`): an unmapped
  newly-inserted overlay-entry identity can fall through to `portalRootIdentity`
  (the host, an ancestor of the background) at `ViewGraph.swift:645-648`.
- The dominant `Layout[0]` (content-root) invalidation is **not** explained by
  that translation (which targets the host/overlay, not `Layout[0]`), nor by the
  declaration-preference consume path, the imperative coordinator path, or focus.

**Static analysis is unreliable here (it produced the wrong "focus" answer).** The
reliable next step is the invalidation-**source** trace the lever-b report
prescribed — "log the caller + identity for each `scheduler.requestInvalidation`"
— now buildable durably on the same file-sink infra as the reuse trace
(`SWIFTTUI_INVAL_TRACE`). Run it on the settle frame to pin which call injects
`Layout[0]`/the portal host.

## Fix shape (once the injector is pinned)

The cone is an ancestor-invalidation of a disjoint background under the portal.
Two directions, both structural:

- **Portal-scoped invalidation:** ensure a presentation open/close (overlay
  insert/remove, a disjoint sibling of the content) invalidates only the overlay
  subtree / portal-host *overlay* region, never the content root `Layout[0]` or
  the portal host in a way that conflicts the background. If the injector is the
  Stage 1A translation fallback, retarget it off the background's ancestor chain.
- **Reuse under ancestor invalidation (gap G3):** allow the disjoint background to
  reuse even when an ancestor (portal host / content root) is invalidated, via
  transitive dependency summaries. Higher cost/risk; the gap analysis sequences
  this last.

**Risk:** the fix lands on the hot reuse path; it must not weaken the
`conflictsWithInvalidation` structural-intersection guard (the H2/H3 reuse wins)
nor the H1 elision soundness, and must be A/B'd against the SPIKE oracle (cone 14)
on the real `.paletteSheet` shape. This warrants its own carefully-measured PR.
