# Gallery physics-tab triage: selection-driven `.task` start is unreliable

**Date:** 2026-06-12 ·
**Status:** triage complete, fixes pending ·
**Companion:** [2026-06-12-gallery-tab-crash-stamp-skip-regression.md](2026-06-12-gallery-tab-crash-stamp-skip-regression.md)

## Symptoms triaged

1. User-visible: selecting the gallery Physics tab shows a frozen ball.
2. Gated test "selecting the overflowed gallery physics tab starts its gravity
   loop" fails deterministically (step-6 wait, 30 s wall-clock backstop,
   "stage clock stalled").

## Findings (instrumented overlay runs; all instrumentation reverted)

**Bug A — framework, the root cause of both symptoms.** The PhysicsTab's
autonomous `.task(id:)` **never starts** when the tab content is activated by
a selection change in the composed runtime:

- overflow-menu route: always (the failing gated test);
- direct tab-click route: in a **cold process** — the sibling "direct" test
  passes inside the full gated suite (warm process state from earlier tests)
  but fails solo at the same backstop. This masking is why only the overflow
  variant shows red in suite runs.
- live-app command-palette route: works (verified: task-start fires, sim
  writes every 40 ms tick, body re-resolves with fresh positions, frames
  present at ~25 fps with 14 distinct ball surfaces).
- **Ships in the released 0.0.19**: both gravity-loop tests fail against the
  gallery's tagged public dependency, so this is not a recent regression.

The backstop label is decisive about idleness: `StageClock.swift`'s 30 s
wall-clock ceiling only fires when the stage clock (advanced on every present
and input yield) stalls outright — the runtime goes fully idle because the
task that would drive invalidations never ran.

Prime suspect: the lifecycle task-start registration is lost at the
`TabContentPayload` capture-host/island seam — plausibly the same
duplicate-live-node pathology proven in the stamp-skip crash (the toolbar
reconcile's nested resolve creates a shadow node chain for the same
identities; `nodeIDByIdentity` reindexing races; a task registered under the
losing node never gets its start event). Needs a focused lifecycle-routing
investigation; do not patch blind.

**Bug B — framework.** The toolbar late-preference reconcile is
**non-convergent**: its input node carries the freshly re-bubbled
`ToolbarItemsPreferenceKey` items every frame while its output clears them at
the scope boundary, so `reconciled != node` (differing field:
`preferenceValues`) on **every frame in which any toolbar item exists** —
verified 63/63 frames. Each reconcile also re-resolves captured content
through the live graph (the shadow-node factory above). Perpetual per-frame
work for every toolbar'd app; this is the register's "reuse-host guard" item.
A convergence fix should compare like-for-like (post-absorption vs
post-absorption) and stop re-resolving capture-host content into the live
graph on unchanged frames.

**Bug C — gallery.** The physics toy never settles: `reflected()`'s
`max(1, …)` magnitude floor creates a sub-cell micro-bounce limit cycle, so
when the loop *does* run the app renders full-rate frames forever. Gallery
-side fix: allow the bounce to damp to zero (drop the floor or widen the
settle window).

**Bug D — untriaged.** The quarantined palette test ("gallery command palette
omits the redundant cancel button", focus regions 3 vs 2) remains open;
unrelated to A–C per its quarantine note.

## Instrumentation traps (for the next probe session)

- `expect` captures truncate ~32 KB (`match_max`); PTY byte-counting beyond
  that is garbage. Probe inside the runtime (surface hashes at present time).
- SwiftTUICore is Foundation-free → trace with Darwin `fputs`; DrawExtractor
  runs off-main → nonisolated tracer; `RunLoop` is generic → no static stored
  properties in extensions.
- Useful probe points, validated this session: `ViewNode.setStateSlot`
  (write→invalidator), `FrameScheduler.requestInvalidation` (wake source),
  frame-acquisition outcome switch in `RunLoop+Rendering`
  (skipped/elided/rendered + drop decision), `presentationDamage`
  (true cell diff + surface fingerprint), `reconcileToolbarHostSubtree`
  (field-level diff of reconcile output).
