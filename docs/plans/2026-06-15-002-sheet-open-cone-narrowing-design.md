# Sheet-Open Cone Narrowing — Design and Implementation Status

- **Date:** 2026-06-15
- **Status:** Implemented and measured in two follow-up PRs after this design was
  first written. Keep this file as the design/history entry point; the current
  results live in the mechanism reports linked below.
- **Design pin:** `swift-tui a845dae5` / org `886aa46` (diagnostics landed,
  behavior unchanged).
- **Implementation pins:** `swift-tui 36a1a46b` (mechanism 1),
  `swift-tui a6aaa29e` (mechanism 2); current released pin `swift-tui 8cebb787`
  / `0.0.20`.
- **Builds on:**
  [reuse-trace productization](../reports/2026-06-15-reuse-trace-productization-and-cone-confirmation.md),
  [cone source: portal not focus](../reports/2026-06-15-sheet-open-cone-source-portal-not-focus.md).
- **Gaps:** G4 (coarse runtime invalidation identities) feeding G3 (ancestor
  invalidation blocks descendant reuse).

## Current outcome

The steady-state sheet open/close cone is fixed.

- **Mechanism 1:** the dominant `Layout[0]` cone was a redundant post-action
  follow-up invalidation from the clicked button's owner scope, not the
  scene-level source hypothesized below. The fix skips that owner-scope follow-up
  when the action already requested an invalidation. Same-session sheet-176 A/B:
  `total_cpu_seconds` 1.4409 -> 1.1649 (-19.2%),
  `head_prepare_p50_ms` 27.8 -> 11.0 (-60.6%).
  See [mechanism 1 results](../reports/2026-06-15-sheet-open-cone-followup-fix-results.md).
- **Mechanism 2:** the remaining portal-host cone came from Stage 1A
  translation mapping unmapped overlay-entry identities up to
  `__TerminalUIPortalHost`, the graph root and an ancestor of the background.
  The fix removes the portal-root fallback; unmapped overlay-entry identities
  stay unmapped instead of sweeping the content root. Same-session A/B from the
  mechanism-1 pin: `total_cpu_seconds` 1.1778 -> 0.9700 (-17.6%).
  Cumulative sheet-176 result from the original pin: `total_cpu_seconds`
  1.441 -> 0.970 (-32.7%).
  See [mechanism 2 results](../reports/2026-06-15-sheet-open-cone-mechanism-2-portal-translation-fix.md).

After both fixes, `SWIFTTUI_REUSE_TRACE` reports zero steady-state
`invalidation-conflict` on the sheet cycle. Remaining large recomputes in the
report are one-off cold-start / first-open warmup (`no-node` / `suppressed`), not
the repeated sheet cone this plan targeted.

## Pinned root cause (measured, `SWIFTTUI_INVAL_TRACE`)

The new invalidation-source trace decomposes each frame's invalidation set (raw
scheduler set → portal-translation → force-root decision). On
`sheet-open-latency` rows 176 it split the cone into **two mechanisms**. The
first-pass design diagnosis correctly separated the cone from focus alone and
from ordinary leaf reuse, but later caller-attribution refined the exact injector
for mechanism 1.

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

### Superseded hypothesis: scene-level `[Layout[0]]`

The original design hypothesized that the direct `[Layout[0]]` invalidation came
from scene-level wiring. The **real runtime** does wire scene-level invalidation
sources to the content root: `HostedSceneSession.swift:145-150` constructs
**both**

- the scene `StateContainer` (`SceneSessionState`) with
  `invalidationIdentities: [rootIdentity]`, and
- the `FocusTracker` with `invalidationIdentities: [rootIdentity]`,

where `rootIdentity` is the content root (`…/Layout[0]`). This is **not** a perf-
harness artifact — the harness (`PerfScenario.swift:273-277`) mirrors the real
wiring exactly. So **any scene-level event (a scene-session-state write, or a
focus event that routes to the tracker's fallback identity) invalidates the
content root, sweeping the whole disjoint background into the conflict cone.**

That remains a valid architectural hazard, but it was **not** the measured
injector for the dominant sheet-open cone. The mechanism-1 follow-up added caller
attribution at the post-action sites and pinned the real source to
`flushPostActionInvalidations`: the clicked button registered
`followUpInvalidationIdentity` at the owner `Layout[0]`, and the action's own
state write had already requested the precise invalidation. The fix therefore
targeted the redundant post-action owner invalidation rather than changing
scene-level focus/state wiring.

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

Resolved. The cheap caller-attribution refinement landed with
`SWIFTTUI_INVAL_TRACE` labels and showed:

- dominant `raw={Layout[0]} selective=true` frames came from **post-action**
  follow-up invalidation;
- the residual portal-host cone came from **translation**, not a raw portal-root
  invalidation (`xlated` added the host root; `raw` did not contain it).

The scene-level source ambiguity remains useful background for future focus or
scene-state work, but it no longer blocks the sheet-open cone fix.

## Option disposition

| option | what | value | cost/risk |
| --- | --- | --- | --- |
| **A. Narrow the scene-level source (G4)** | Stop scene-level focus/state events from invalidating `[rootIdentity]` (the content root). | Not needed for the measured sheet cone after caller attribution. Still a possible future focus/scene-state investigation if a fresh trace shows scene-level raw `[rootIdentity]`. | Medium/high — must prove the fallback is not a correctness backstop. |
| **A1. Skip redundant post-action owner follow-up** | If an action already requested invalidation, do not also invalidate the registered owner-scope follow-up identity. | **Landed.** Removed the dominant `Layout[0]` cone while preserving quiet-action backstop behavior. | Lower risk than A because a frame is already scheduled in the skipped case. |
| **A2. Remove portal-root translation fallback** | Do not translate unmapped overlay-entry identities to the portal root; keep them unmapped unless an overlay host exists. | **Landed.** Removed the residual portal-host cone. | Low/medium; publication stays `.all` on those force-root frames and portal root still composes via the existing force-queue. |
| **B. Reuse under ancestor invalidation (G3)** | Let the disjoint background reuse even when the content root is invalidated, via transitive dependency summaries. | Not needed for this sheet cone. Remains the general high-cost answer for future coarse ancestor invalidation. | Very high — silent stale UI is the failure mode. |
| **C. Portal-scoped focus** | Make the portal's detached overlay focus scope invalidate within the portal, not route to the scene-root `[rootIdentity]`. | Not needed for the measured cone. Keep as future focus/force-root work only if a new trace points there. | Medium — portal/focus-scope interaction. |

## Completed sequence

1. Productize durable trace capture:
   `SWIFTTUI_REUSE_TRACE_FILE` and `SWIFTTUI_INVAL_TRACE_FILE`.
2. Use caller-attributed invalidation traces to pin mechanism 1 to post-action
   follow-up invalidation; land the skip-when-action-already-invalidated fix.
3. Re-run traces and pin mechanism 2 to portal translation; remove the
   portal-root fallback.
4. Validate with same-session sheet-176 A/Bs and focused regression tests.

## Remaining work

The steady-state cone is gone. Further sheet wall-clock reduction is now a
separate, lower-EV tranche:

- **Force-root/focus spine walk:** focus-settle frames may still force root
  traversal, but without the repeated background recompute cone. This is G5
  territory and must preserve portal maintenance, island freshness, registration
  publication, and semantic snapshot freshness.
- **Checkpoint-create storage:** still structural; the cheap image-reuse attempt
  measured as a no-op because the O(N) dictionary build remains.
- **Raster / animation walks:** possible residuals, but they need fresh
  `0.0.20` ranking before code.
- **G3 transitive dependency summaries:** not justified by the fixed sheet path;
  keep for a future broad ancestor-invalidation project.

## Guardrails (hot reuse path)

- Must not weaken `ViewGraph.conflictsWithInvalidation` structural-intersection
  guards (the shipped H2/H3 reuse wins) nor H1 elision soundness.
- Must not re-expose the Part 0 divergent-identity orphaning bug (the focus-reuse
  interaction); keep the `InteractiveRuntimeTests` scroll cases green.
- Same-session A/B on the hot pair; clean `Tools/TermUIPerf/.build` on any
  core-struct change.
- Any future force-root/focus narrowing is its own carefully-measured PR. Do not
  treat the landed sheet-cone fixes as proof that the root-walk backstops are
  generally removable.

## Diagnostic infra landed with this design

`SWIFTTUI_INVAL_TRACE` (+ `SWIFTTUI_INVAL_TRACE_FILE`): one `[INVAL-TRACE]` line
per frame decomposing raw → translated → force-root, on the same durable file-sink
infra as the reuse trace (`DiagnosticTraceSink`). Reusable for any future
"who-invalidated-this-ancestor" question.
