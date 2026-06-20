# Results: PhaseAnimator loop stall behind capture-host seams

Date: 2026-06-20. Fixes the gallery Animations-tab PhaseAnimator (section 7,
"auto-cycles through phases on its own") freezing after a single phase — a
codepath that had silently regressed and un-regressed repeatedly.

## Symptom

In the gallery, the loop-mode `PhaseAnimator` (the `●●●…` marker) appeared stuck.
Historically, scrolling the screen *sometimes* nudged it; latterly even that
stopped. The marker would animate red→yellow once and then freeze at yellow.

## How the loop drives itself

`PhaseAnimator` loop mode (`swift-tui/Sources/SwiftTUIViews/Animation/PhaseAnimator.swift`)
runs a background `.task`:

```
.task { runPhaseLoop() }            ← must survive across frames
   └─ withAnimation { phase = next } completion: { resume }
      └─ await   ← blocks until that phase's animation drains and fires completion
```

So the cycle advances **only** when each `withAnimation` completion fires.

## Root cause (four layers, one fragility)

The single fragility: **`withAnimation` completion firing is coupled to the async
frame-commit pipeline**, and the large gallery tree (lazy `TabView` tab + scroll
viewport — a capture-host seam) makes that pipeline frequently discard, supersede,
or off-screen-elide the very frame that would fire the completion. Diagnosed by
instrumenting the real gallery shell under a bounded run loop (the bug needs the
real seam; minimal trees do not reproduce it).

1. **Completion clobber (the decisive race).** A `withAnimation … completion:`
   invoked by an *async task* (PhaseAnimator's `advance`) registers its completion
   closure — and the animation box — on the **live** `AnimationController`, between
   frames. `AnimationController.publishCommittedState` did a full `restore` from a
   draft snapshotted *before* that registration, so whenever a frame was in flight
   (common in a big tree) the just-registered completion was **clobbered** and
   never fired. Confirmed live: `PUBLISH CLOBBER completions dropped=1`.

2. **Pump idle on skip.** A SKIPPED async frame (cancelled-before-start /
   dropped-completed) abandons its draft without committing and — unlike the
   committed and elided paths — never re-armed the animation deadline. If that
   frame was draining the animation, the live controller kept it active but the
   run loop idled, so the completion never fired until an unrelated event (a
   scroll!) woke the loop. This is precisely the "scrolling nudges it" history.

3. **Off-screen tick routing (investigated, not the fix).** A completion-bearing
   animation can be processed by the pre-frame-head off-screen tick, which fires
   completions out-of-band and sporadically. Gating that path on pending
   completions broke a designed contract (`pre-frame-head offscreen property tick
   fires finite animation completion`), so it was reverted — the off-screen tick
   firing completions is intentional.

4. **PhaseAnimator's hard dependency.** Because the loop *awaits* the completion,
   any single dropped completion deadlocks the whole cycle forever.

## Fix (`swift-tui` @ `e648331d`, branch `fix/phaseanimator-completion-stall`)

- **`AnimationController.publishCommittedState`** now carries forward completion
  closures and animation-box registrations the live controller gained since the
  draft's baseline (the draft never saw them, so it neither references nor fired
  them). Deterministically unit-tested in `AnimationCompletionConcurrencyTests`.
- **`RunLoop.requestNextAnimationFrameIfNeeded`** + a new
  `requestNextAnimationFrameAfterSkippedFrameIfNeeded` (wired into the `.skipped`
  arm) keep the animation pump alive whenever the *live* controller still has
  un-drained animation work, so a discarded sibling frame can't strand it.
- **`PhaseAnimator.advance`** arms a fallback on the animation's own
  `totalDuration` so the loop advances even if a completion is dropped — the
  completion stays the fast path (fires first in the steady state), but the cycle
  can never deadlock waiting on a missed one. This is how `TimelineView`/`Spinner`
  already self-drive.

## Verification

- New deterministic regression: `AnimationCompletionConcurrencyTests` (the clobber
  race) — `swift-tui/Tests/SwiftTUITests/`.
- No regression: 101 animation/elision tests pass, incl. the full
  `OffscreenFrameElisionRuntime` suite. `bun run test` (full repo gate): **PASS**.
- End-to-end: drove the real `GalleryView(initialTab: .animations)` shell under a
  bounded run loop and confirmed the section-7 marker cycles through ≥3 phases
  (red→yellow→green→cyan, detected by the marker's foreground color) — it froze at
  yellow before the fix.

## Test placement note

The faithful end-to-end reproduction mounts the full gallery shell and therefore
needs the *unreleased* `swift-tui` fix, so it cannot live in the public
`swift-tui-examples` repo (which builds against tagged releases only). It was used
for verification and is documented here; the committed regression is the
deterministic clobber test in `swift-tui`. Re-add a gallery-shell auto-cycle test
to `swift-tui-examples/gallery` when the `swift-tui` pin there is bumped to a
release carrying this fix.

## Status

Committed on `swift-tui` branch `fix/phaseanimator-completion-stall` (`e648331d`)
and pinned in the org root. Not yet merged/pushed; merge is the next step.
