# Sheet-Open Cone Narrowing — Pinned Root Cause + Fix Design

- **Date:** 2026-06-15
- **Status:** Design (no behavior change yet). The diagnostic infra it relies on
  (`SWIFTTUI_INVAL_TRACE`) is implemented; the fix is the next, separately-scoped
  PR.
- **Pin:** `swift-tui` (post item 1 + this trace).
- **Builds on:**
  [reuse-trace productization](../reports/2026-06-15-reuse-trace-productization-and-cone-confirmation.md),
  [cone source: portal not focus](../reports/2026-06-15-sheet-open-cone-source-portal-not-focus.md).
- **Gaps:** G4 (coarse runtime invalidation identities) feeding G3 (ancestor
  invalidation blocks descendant reuse).

## Pinned root cause (measured, `SWIFTTUI_INVAL_TRACE`)

The new invalidation-source trace decomposes each frame's invalidation set (raw
scheduler set → portal-translation → force-root decision). On
`sheet-open-latency` rows 176 it splits the cone into **two mechanisms**:

1. **Dominant — direct content-root invalidation (the ~890 cone).**
   `raw={App/sheet-open-latency/Layout[0]} selective=true` — a plain
   `requestInvalidation` of **exactly the content root `Layout[0]`** on an
   otherwise-selective frame. Not portal-translation, not force-root, not a focus
   change. Because `Layout[0]` is the ancestor of the entire background grid,
   every background node conflicts (`ViewGraph.conflictsWithInvalidation`, ancestor
   leg).
2. **Secondary — focus-settle force-root (`~880`/frame).**
   `force-root-reasons=[focus_changed, frame_state_force_root]`; the newly-inserted
   overlay-entry identities (`raw`) are translated to `{__presentationTrigger,
   __TerminalUIPortalHost}` and a focus change forces a full root re-eval.

### Where the `[Layout[0]]` invalidation comes from

The **real runtime** wires the scene-level invalidation sources to the content
root: `HostedSceneSession.swift:145-150` constructs **both**

- the scene `StateContainer` (`SceneSessionState`) with
  `invalidationIdentities: [rootIdentity]`, and
- the `FocusTracker` with `invalidationIdentities: [rootIdentity]`,

where `rootIdentity` is the content root (`…/Layout[0]`). This is **not** a perf-
harness artifact — the harness (`PerfScenario.swift:273-277`) mirrors the real
wiring exactly. So **any scene-level event (a scene-session-state write, or a
focus event that routes to the tracker's fallback identity) invalidates the
content root, sweeping the whole disjoint background into the conflict cone.**

### Why it is portal-specific (reconciles the earlier A/B)

- `TRIGGER=sibling` (real portal, focus de-amplified): cone **unchanged** — the
  portal still churns scene-level focus/state.
- `SPIKE=1` (no portal, inline overlay): cone **gone (14)** — an inline overlay
  does *within-tree, scoped* focus moves and never triggers the scene-root
  `[rootIdentity]` fallback.

So the presentation **portal** (detached overlay focus scope + presentation
state) is what *triggers* the coarse scene-level `[rootIdentity]` invalidation;
the `[rootIdentity]` scope is what *amplifies* it into the background.

> Method note: a 5-agent static pass concluded "focus"; the knob A/B refuted
> "focus alone"; the `SWIFTTUI_INVAL_TRACE` decomposition pinned it to the
> scene-level `[rootIdentity]` source. Measurement was the arbiter at each step.

## Open question (cheap, do first)

Disambiguate **which** scene-level source fires on the dominant `raw={Layout[0]}
selective=true` frames: the `SceneSessionState` `StateContainer` (a presentation-
driven scene-state write) or `FocusTracker`'s `[rootIdentity]` fallback (a focus
event that did not change the focused identity, hence no `focus_changed`). The
cheapest confirmation is a one-step caller-attribution refinement to
`SWIFTTUI_INVAL_TRACE` (label the `requestInvalidation` source at the
`FocusTracker` and scene-`StateContainer` sites), or a targeted read of what
mutates `SceneSessionState` on a `.paletteSheet` open/close.

## Fix options

| option | what | value | cost/risk |
| --- | --- | --- | --- |
| **A. Narrow the scene-level source (G4)** | Stop scene-level focus/state events from invalidating `[rootIdentity]` (the content root). For `FocusTracker`, rely on the scoped `{prev,current}` focus-identity invalidation it already computes and drop/condition the `[rootIdentity]` fallback. For `SceneSessionState`, reader-attribute the scene-state write so only actual readers invalidate. | High — directly removes the dominant cone | Medium/high — must prove the `[rootIdentity]` fallback is not a focus-geometry/scene correctness backstop; interacts with the Part 0 orphaning fix |
| **B. Reuse under ancestor invalidation (G3)** | Let the disjoint background reuse even when the content root is invalidated, via transitive dependency summaries (the background reads neither focus nor scene-session-state). | Highest — fixes the whole class (any coarse ancestor invalidation) | Very high — the gap analysis sequences this last; silent stale UI is the failure mode |
| **C. Portal-scoped focus** | Make the portal's detached overlay focus scope invalidate within the portal, not route to the scene-root `[rootIdentity]`. | Medium — fixes the portal trigger specifically | Medium — portal/focus-scope interaction |

## Recommended sequence

1. **Disambiguate the injector** (the open question above) — one trace refinement
   or targeted read. Decides whether the bounded fix is A-focus or A-scene-state.
2. **Bounded narrowing (A).** Scope the confirmed scene-level source off the
   content root. A/B against the **SPIKE oracle (cone 890→14)** on the real
   `.paletteSheet`; the win is real only when the background reuses on the
   dominant frame.
3. **Only if narrowing proves unsafe**, escalate to **G3** (transitive dependency
   summaries) as the general fix.

## Guardrails (hot reuse path)

- Must not weaken `ViewGraph.conflictsWithInvalidation` structural-intersection
  guards (the shipped H2/H3 reuse wins) nor H1 elision soundness.
- Must not re-expose the Part 0 divergent-identity orphaning bug (the focus-reuse
  interaction); keep the `InteractiveRuntimeTests` scroll cases green.
- Same-session A/B on the hot pair; clean `Tools/TermUIPerf/.build` on any
  core-struct change.
- This is its own carefully-measured PR; the secondary force-root/focus mechanism
  (mechanism 2) is a separate, smaller follow-on.

## Diagnostic infra landed with this design

`SWIFTTUI_INVAL_TRACE` (+ `SWIFTTUI_INVAL_TRACE_FILE`): one `[INVAL-TRACE]` line
per frame decomposing raw → translated → force-root, on the same durable file-sink
infra as the reuse trace (`DiagnosticTraceSink`). Reusable for any future
"who-invalidated-this-ancestor" question.
