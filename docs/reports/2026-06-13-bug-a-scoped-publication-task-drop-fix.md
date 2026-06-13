# Bug A fix: autonomous `.task` dropped on scoped-publication frames

**Date:** 2026-06-13 · **Status:** fixed, gate-green ·
**swift-tui commit:** `f451f619` ·
**Companion triage:** [2026-06-12-gallery-physics-task-start-triage.md](2026-06-12-gallery-physics-task-start-triage.md)

## Symptom

Selecting the gallery Physics tab shows a frozen ball: the tab's autonomous
`.task(id:)` never starts. The gated test "selecting the overflowed gallery
physics tab starts its gravity loop" fails deterministically at the step-6 wait
(30 s wall-clock backstop, "stage clock stalled" — the runtime goes fully idle
because the loop-driving task never ran).

## Root cause

The frame that first resolves a newly-activated tab body publishes its runtime
registrations with a **frontier-scoped (`.subtrees`) plan** (a *mapped*
invalidation from the selection `@State` write, not a full `.all` rebuild). The
two publication paths differ in how they restore registrations:

- `.all` → `restoreLiveIdentities(liveNodeIDs)` — a **flat walk over every live
  node ID**, which *does* reach capture-hosted island nodes.
- `.subtrees(roots)` → `restoreRuntimeRegistrationSubtrees` — walks each
  frontier root's **ViewNode `children`**, which **cannot cross a capture-host
  island seam** (deferred tab bodies, presentation portals, an overflow-menu
  portal, or a toolbar reconcile's re-hosted content).

So on a scoped frame, a `.task` registered on a node behind such a seam was
recorded on the node but never republished into the **live** task registry. The
lifecycle coordinator then received the emitted `taskStart` event, found no
matching live registration, and silently dropped it — the task never ran.

(Confirmed in the gallery under instrumentation: `regFound=false` at the
coordinator; two distinct registry instances; forcing `.all` made the task run.)

## Fix (`swift-tui` `f451f619`, +45 lines / 4 files)

On the `.subtrees` commit path, after the scoped restore, republish the task
registry from **every** live node:

- `RuntimeRegistrationSet.restoreTasks(from:)` — task-only restore.
- `ViewNode.restoreOwnTaskRegistrations(into:)`.
- `ViewGraph.republishAllTaskRegistrations(into:)` — resets the task registry
  and restores it from all `liveNodeIDs` (the same flat walk `.all` uses, but
  for tasks only).
- `ViewGraphFrameDraft.commitRuntimeRegistrations` — calls it in the `.subtrees`
  branch.

Tasks are infrequent and the per-node check is a dictionary-emptiness test, so
the full walk is cheap. The `.all` and `.unchanged` paths are untouched, and the
scoped restore (the O(changed) commit win for the other registries) is
preserved.

## Validation

- `swift-tui` repo gate (`bun run test`): **PASS** (all suites + policy checks).
- Gallery suite under the dev overlay: 82 tests / 18 suites pass; both
  gravity-loop tests (the Bug A reproducers) pass with the fix.

## Why the existing test suite did not catch it

This is the load-bearing finding. Two conditions must coincide:

1. a **frontier-scoped (`.subtrees`) publication** — needs a *mapped*
   invalidation across frames in a **persistent live ViewGraph**; and
2. the task-bearing node sitting **behind a capture-host island seam** the
   scoped children-walk cannot reach.

The existing `TabViewLifecycleTests` use `DefaultRenderer().render()` with
`.constant(tag)` selection and a **fresh ViewGraph per render** — they never
exercise a selection change across a persistent graph, so they never produce a
`.subtrees` plan, let alone across a seam.

Attempts to build a *minimal* swift-tui unit reproducer all failed (each passes
with the fix reverted), because the minimal shapes keep the tab body
**children-reachable**:

| Shape tried | Publication on activation | Reproduces? |
| --- | --- | --- |
| root-owned `@State` selection | `.all` (root invalidation) | no — flat walk reaches body |
| intermediate-owned `@State` | `.subtrees` | no — body still children-reachable |
| + `.toolbar` scope wrapper | `.subtrees` | no — synchronous toolbar items host at resolve time; no late seam |

The seam in the gallery is created by its **overflow-menu portal** hosting tab
bodies and/or the **toolbar late-preference reconcile re-resolving deferred
content into the live graph** (Bug B — see below). Reproducing it faithfully
requires that structure, so the **fix-isolating regression home is the gallery
gravity-loop tests** (examples repo), which now pass. Wiring those into a gate
is a deferred follow-up.

The added `swift-tui` test
(`TabTaskActivationRuntimeTests`) is therefore framed honestly as a **live-
runtime activation smoke test** (it fails if tab activation or autonomous-task
execution regresses outright), not as a fix-isolating regression.

## Relationship to Bug B

The capture-host seam that drops the task is, in the gallery, created by the
toolbar late-preference reconcile re-resolving deferred content into the live
graph every frame (Bug B, the register's "reuse-host guard" item). Bug A's fix
is a **general safety net** — tasks always reach the live registry regardless of
seam source — so it **neutralizes Bug B's user-visible symptom** (the frozen
tab) independently of whether the seam is eliminated. What remains of Bug B is
per-frame re-resolve cost plus a dead `changed` flag; see the next-phase
proposal for the scoped perf treatment.
