# H1 Design — Off-screen / zero-damage animation frame elision

**Date:** 2026-05-29
**Status:** Design (awaiting review → implementation plan)
**Origin:** [`docs/reports/2026-05-28-gallery-performance-report.md`](../reports/2026-05-28-gallery-performance-report.md) §4 H1 / §7 rec. 1
**Proof rig (already shipped):** `swift-tui/Tools/TermUIPerf` scenario `synthetic-offscreen-phase-animator` (G1) + `termui-perf compare` significance verdict (G2)
**Code baseline:** `swift-tui` `main` @ `375dbbb5` (clean working tree at design time)
**Implementation locus:** `swift-tui` submodule only — `SwiftTUIRuntime`. No public-API or child-manifest changes.

---

## 1. Problem

The gallery **Animations** tab commits ~274 frames over a 10 s idle window with
**`damage_cells = 0` on every frame**, burning **~5.58 CPU-seconds (~56 % of one
core)** — the highest CPU of any tab — to produce frames that change nothing on
screen. Root cause (confirmed by the report's spike): an **off-screen**
`PhaseAnimator` keeps the animation controller perpetually active, so the run
loop wakes on the animation deadline (~28 fps), runs the **full
resolve→commit pipeline**, and produces a byte-identical raster surface.

The kitty cross-check proved these frames present `0` bytes — terminal I/O is not
the cost. The cost is **CPU spent in the frame pipeline producing frames whose
output never reaches the visible surface**.

## 2. Goal & success criteria

Skip the expensive rendering work for animation-deadline frames whose redraw set
cannot reach the visible surface, **without** changing observable program
behavior (completion-callback timing) or on-reveal visual correctness.

**Success =** under `termui-perf compare` (G2 significance verdict, ≥20
iterations) on `synthetic-offscreen-phase-animator`:

- a large, statistically-significant drop in `total_cpu_seconds` (target:
  approach the cost of a purely idle run), and
- a non-zero new `elided_frames` diagnostic proving elision actually fired
  (not merely inferred from CPU), with
- **zero regressions** in: completion-callback delivery timing, on-reveal
  rendered state, matched-geometry / transition correctness, and the existing
  animation test suite.

## 3. Decided constraints (from brainstorming)

| Decision | Choice | Consequence |
| --- | --- | --- |
| Which cost to recover | The upstream **rendering pipeline** (~5 ms/frame), not `present` | Drop-eligibility narrowing is the wrong layer (present is already a 0-byte no-op) — **out of scope** |
| Off-screen visual fidelity | **Resync-on-reveal acceptable** | Permits aggressive elision; in practice this design does *better* (see §6) |
| Completion-callback timing | **Real-time schedule** — coalesce pixels, not logic | The elision path **must still fire completions on schedule** (§5) |
| Approach | **Pre-resolve render gate, keep ticking** (not wakeup coalescing) | No restart trap; wakeup-coalescing (bigger but riskier) deferred — see §9 |

## 4. Architecture — a post-injection reduced-commit gate

### 4.1 Where the gate sits

`RuntimeRenderPipeline`
([`Sources/SwiftTUIRuntime/Rendering/RuntimeRenderPipeline.swift`](../../swift-tui/Sources/SwiftTUIRuntime/Rendering/RuntimeRenderPipeline.swift))
runs stages in one ordered loop:

```
head → animationInjection → latePreferenceReconciliation → fusedFrameTail → commit
```

The **animation tick happens at `animationInjection`** (`injectAnimations` →
`AnimationInjectionStage.apply` → `applyInterpolations` on the *draft*
controller), which produces `redrawIdentities` and drains completion batches —
**before** the expensive `latePreferenceReconciliation` / `fusedFrameTail`
(resolve→measure→place→semantics→draw→raster).

The gate is evaluated **immediately after `animationInjection`**. The executor
already supports early-out (`renderCancellable` breaks the stage loop on
`outcome != nil`, `RuntimeRenderPipeline.swift:190`); this adds a second,
principled early-out applied consistently across all three executors
(`renderOneShot`, `renderAsync`, `renderCancellable`).

### 4.2 The reduced-commit path (CRITICAL — see §5)

The elision path is **not** "break out of the loop." Completions and animation
state are published by `AnimationFrameDraft.commit()`
(`AnimationController.swift:1288-1295`), invoked from
`FrameHeadDraftTransaction.commit()` → `draft.transaction.commit()` at
`DefaultRenderer+CompletedFrameCandidates.swift:181` — i.e. **inside the
pipeline's `commit` stage**. A naive early-out would drop completions and fail
to advance the live clock.

Therefore the gate routes to a **reduced commit** that:

1. **Commits the draft transaction** (`draft.transaction.commit()`):
   fires deferred completions on real-time schedule **and** publishes the
   advanced animation-controller state draft→live (`publishCommittedState`).
2. **Skips** `latePreferenceReconciliation`, `fusedFrameTail`, and all
   pixel-producing / presentation work (artifact build,
   `presentCommittedFrameWithDiagnosticsTiming`, `recordPresentedRasterSurface`).
3. **Still schedules the next deadline** (`requestNextAnimationFrameIfNeeded`
   with the published tick result) → the loop never stops → **no restart trap**.
4. **Increments an `elided_frames` diagnostic** for the perf harness.

The core implementation task is **factoring the cheap transaction-commit
(completions + state publication) out of the artifact-building / presentation
code** so it can run on the elision path without producing or presenting a frame.

## 5. Gate condition (must satisfy ALL)

1. **Animation-deadline-only frame:** `scheduledFrame.causes ⊆ {deadline}`.
   Any input / lifecycle / focus / preference / scroll / gesture cause
   disqualifies — those carry real or potential visible work.
2. **Redraw cannot reach the surface:**
   `tickResult.redrawIdentities.isDisjoint(with: previousDrawnIdentities)`,
   where `tickResult` is read from the draft controller post-injection
   (`draft.animationDraft.controller.lastTickResult`) and `previousDrawnIdentities`
   is the last committed frame's `drawnIdentities` (retained on the run loop /
   renderer). The empty-redraw drain case is naturally disjoint — correct, since
   a pure completion-drain frame has nothing to render but **must** still commit
   the transaction to fire its completion (item 1 of §4.2).
3. **Soundness of the oracle:** elision trusts that `redrawIdentities` includes
   *every* identity whose visible cells could change — including on-screen
   siblings whose layout an off-screen animation shifts. This is the same
   contract the existing incremental-presentation diff already relies on; if
   redraw-tracking under-reports cross-subtree effects, elision inherits that
   bug. Pinned by a dedicated test (§7).

## 6. Why reveal is correct (and better than required)

Because the reduced commit **publishes the advanced animation state every tick**,
the live controller's clock keeps advancing even while rendering is skipped. When
content scrolls on-screen, that scroll/input invalidation has causes ⊄ {deadline}
→ the gate does not fire → a full frame renders the *current* animation state.
The user accepted resync-on-reveal; this design yields near-frame-accurate
reveal at no extra cost.

## 7. Testing strategy

**Perf (proof):**
- `synthetic-offscreen-phase-animator`, `--iterations 20 --modes async`, before
  vs after, via `termui-perf compare` → significant `total_cpu_seconds` drop +
  non-zero `elided_frames`.

**Correctness (Swift Testing, `Tests/SwiftTUITests` / `Tests/SwiftTUICoreTests`):**
- **Gate predicate truth table:** deadline-only + disjoint → elide; any non-deadline
  cause → render; overlapping redraw → render; empty-redraw drain → elide *but
  transaction still commits*.
- **Completion timing (defends §5):** an off-screen `withAnimation { … } completion:`
  fires on its real-time schedule despite elision. Build on the patterns in
  `AnimationRepeatForeverGrowthTests`.
- **Clock / reveal:** after a run of elided frames, scrolling content into view
  renders the correct current animation state (state was published each tick).
- **Oracle soundness (§5.3):** an off-screen animation that shifts an on-screen
  sibling's layout produces a non-disjoint redraw set → frame is **not** elided.
- **Matched-geometry / removal:** verify skipping `capturePlacedTree` across
  elided frames does not corrupt next-frame removal or matched-geometry
  detection (see §8 risk).
- **All three executors:** gate behaves identically on `renderOneShot`,
  `renderAsync`, `renderCancellable` (gallery uses `async`; sync path must match).
- Regression guard near `AnimationTickVisibilityTests` (documents the
  redraw/viewport invariant) and `FrameDropEligibilityTests`.

## 8. Risks & open verification items

| Risk | Mitigation / verification |
| --- | --- |
| **Dropped completions / frozen clock** (the §5 mechanism) | Reduced commit MUST run `draft.transaction.commit()`; completion-timing + reveal tests are the gate. Verified mechanism at `AnimationController.swift:1288-1295`, `DefaultRenderer+CompletedFrameCandidates.swift:181`. |
| **Skipped `capturePlacedTree`** (no `place` runs on elided frames) | Confirm the previous placed tree remaining current is safe across elision for matched-geometry/removal; add test. Likely safe (off-screen, no visible structural change) but unverified. |
| **Oracle under-reports cross-subtree layout effects** | Trust = existing incremental-diff contract; pin with the on-screen-sibling test (§7). |
| **Transition bookkeeping coherence** (`beginTransitionCollection`/`finishTransitionCollection`, `DefaultRendererFrameHeadCoordinator.swift:253/270` run in the tail) | Verify elision leaves transition state coherent for the next real frame; test. |
| **Factoring `transaction.commit()` out of artifact build** introduces a regression on the normal (non-elided) path | The refactor must be behavior-preserving for the render path; full suite + gallery overlay re-run. |

## 9. Scope

**In scope:** `SwiftTUIRuntime` — the gate predicate, the reduced-commit
factoring, the `elided_frames` diagnostic, and tests. Framework-runtime-only.

**Out of scope:**
- **Drop-eligibility narrowing** (zero-damage `.canDropVisualOnly`, narrowing the
  over-broad `.animationTransition` blocker): wrong layer — only saves the
  already-free `present`. Explicitly rejected.
- **Gallery / example edits:** `AnimationsTab` is the symptom; the fix is in the
  runtime.
- **On-screen zero-delta elision** (e.g. a color animation whose quantized cells
  are identical): H1 is dominated by the off-screen case; on-screen zero-delta
  needs a different oracle and is not addressed here.

**Flagged follow-on (own plan, gated on profiling):** *Approach 2 — wakeup
coalescing.* Stop scheduling the 28 fps deadline while fully off-screen and
resume from reveal invalidation, recovering even the per-tick wakeup overhead.
Deferred because (a) it re-enters the exact layer that previously trapped
(`RunLoop+Rendering.swift:135-143`), and (b) the code map indicates the wakeup
itself is cheap relative to the pipeline this design already eliminates. Pursue
only if post-H1 profiling shows residual wakeup overhead is material.

## 10. Key code references (baseline `375dbbb5`)

- Stage executor + early-out precedent: `RuntimeRenderPipeline.swift` (stages
  `:10-22`; `renderCancellable` break `:190`).
- Injection stage body: `DefaultRendererFrameHeadCoordinator.swift:108-141`.
- Tick result type (visibility signal): `AnimationRuntimeState.swift:51-87`.
- Completion defer/fire: `AnimationController.swift:966-971` (defer),
  `:103-122` (finish), `:1288-1296` (`AnimationFrameDraft.commit`).
- Transaction commit/discard wiring: `FrameHeadDraftTransaction.swift:78-80`
  (commit), `:129-136` (discard); invoked at
  `DefaultRenderer+CompletedFrameCandidates.swift:181`.
- Post-commit deadline scheduling (loop liveness):
  `RunLoop+PostCommitSupport.swift:67-85`; commit path & removed-gate note:
  `RunLoop+Rendering.swift:90-145`.
- `drawnIdentities` source: `FrameTailRenderer+InlineStages.swift:100,156`;
  carried via `CommittedFrameArtifactBuilder.swift:168`.

---

## Reduced-commit seam decision (Task 1 spike outcome)

Spike performed against `swift-tui` `main` @ `375dbbb5`. Goal: determine
whether the four `FrameHeadTransaction` sub-drafts can commit on an
animation-deadline-only, zero-on-screen-redraw frame that runs **no**
`finalizeFrame` and produces **no** `placed`/raster output, and to fix the
`commitElided()` contract plus the run-loop outcome plumbing for later tasks.

### The four questions

**Q1 — Are there ever NEW graph runtime registrations that must commit on an
elided frame, and is `graphDraft.commitRuntimeRegistrations` safe to run when no
finalizeFrame/place happens?**

`commitRuntimeRegistrations` (`ViewGraphFrameDraft.swift:80-96`) does NOT depend
on `placed` or on `finalizeFrame` having run. Its work is:

1. apply the registration publication plan to the live set
   (`.unchanged` → no-op; `.all` → `resetAll()`; `.subtrees` →
   `removeSubtrees`), then
2. `viewGraph.restoreCurrentFrameRuntimeRegistrations(into: liveRegistrations)`
   (`ViewGraph.swift:984-992`), which republishes from `liveIdentities` /
   `nodesByIdentity` — graph head state established at *resolve*, before
   injection.

The publication plan is set by `recordDirtyEvaluationPlan`
(`ViewGraphFrameDraft.swift:31-38`) during the head resolve, which ran **before**
injection. So whether there are "new" registrations is already decided pre-gate:
a deadline-only redraw frame that touched no identities resolves with an empty /
`.unchanged` plan and `restoreCurrentFrameRuntimeRegistrations` republishes the
already-live set (idempotent). **Decision: COMMIT it.** It is safe (no
finalize/place dependency) and committing keeps the live registration set
authoritative and the draft's `didCommit`/`didDiscard` precondition machine
consistent with the rest of the transaction. Skipping it would diverge the
elided path from `commit()` for no benefit and risk a stale live set if a future
non-empty plan ever reaches the gate. **Caveat for later tasks:** the gate
condition (§5.1, deadline-only causes) is what *guarantees* the plan is benign;
`commitRuntimeRegistrations` does not itself verify that. The gate predicate is
load-bearing for this safety.

**Q2 — Can `observationDraft.commit()` and `presentationPortalDraft.commit()`
run safely WITHOUT a committed placed tree / `publishCommittedFrame`?**

Both are pure draft→live publications with no `placed`/raster dependency.

- `ObservationBridgeDraft.commit()` (`Observation.swift:147-151`) calls
  `bridge.publish(self)` (`Observation.swift:108-117`), which advances
  `currentPass`, merges `observedPasses`, and reattaches the `viewGraph` weak
  ref. All of these were populated during head resolve via `recordObserved`
  (`Observation.swift:139-145`). No placed/semantic/raster input. **COMMIT it.**
- `PresentationPortalDraft.commit()` (`PresentationPortalState.swift:106-110`)
  calls `liveState.publish(self)` (`:28-32`), a single registry pointer swap.
  The draft's registry was populated by `reconcile`/`injectHandles` during head
  resolve (`:89-94`, `:76-87`). No placed/raster input. **COMMIT it.**

Note: `publishCommittedFrame` (`DefaultRenderer+CompletedFrameCandidates.swift:156-175`)
is a *separate* step that stores the artifact and committed presentation-portal
*scroll geometry / overlay snapshot for present* — it is NOT what
`presentationPortalDraft.commit()` does. The portal *draft* commit only swaps the
coordinator registry; the present-side `storeCommittedPresentationPortalState()`
inside `publishCommittedFrame` is correctly skipped on the elided path (no
present). **Decision: COMMIT both.** Discarding them would lose observation-pass
bookkeeping and portal reconciliation that the resolve already performed, and
would desync the bridge's `currentPass` from the next frame's tracking.

**Q3 — Does `animationDraft.commit()` depend on anything finalizeFrame / the
tail produces?**

No. `AnimationFrameDraft.commit()` (`AnimationController.swift:1288-1296`):
`controller.finishFrameHeadTransaction(...)` (drains deferred completions),
`liveController.publishCommittedState(from: controller)`, then fires the drained
completion closures. `publishCommittedState` (`:182-186`) is
`restore(draftController.makeCheckpoint())` — a full controller-state copy
(`:158-180`) including `lastTickResult` (`:176`). All of that state was advanced
during `animationInjection` (the draft tick), strictly before the tail.
**Confirmed: no tail/finalize/placed dependency. COMMIT it.** This is the whole
point of the elision path (§4.2 item 1).

**Important exception — `capturePlacedTree` is NOT part of the transaction
commit.** `AnimationController.capturePlacedTree(_:)`
(`AnimationController.swift:197-202`) seeds `previousPlacedRoot` /
matched-geometry bookkeeping and is called by the pipeline *after `place` runs*,
NOT from `animationDraft.commit()`. On an elided frame `place` never runs, so the
live controller's `previousPlacedRoot` stays at the last fully-rendered frame's
tree. For the off-screen / zero-on-screen-redraw case this is benign (nothing
visible changed, so prior bounds remain correct) and is in fact the desired
resync-on-reveal behavior — but it is a real, transaction-independent gap that
the §8 "skipped `capturePlacedTree`" risk must own. The reduced commit does NOT,
and should not, try to call `capturePlacedTree` (it has no placed tree to pass).

**Q4 — New `.elided` `FrameAcquisitionOutcome` case, or reuse `.skipped`?**

**ADD `.elided`. Do NOT reuse `.skipped`.** Evidence: `.skipped`
(`RunLoop+FrameAcquisitionOutcome.swift:9-12`) means cancelled-before-start or
dropped-completed; its handler in `renderPendingFramesAsync`
(`RunLoop+Rendering.swift:249-253`) does `continue frameLoop` — it **abandons the
frame** and bypasses `applyAcquiredFrame`. But `applyAcquiredFrame`
(`RunLoop+Rendering.swift:85-182`) is exactly where the loop calls
`requestNextAnimationFrameIfNeeded(renderer.internalAnimationController.lastTickResult)`
(`:144-145`) off the **live** controller — i.e. the loop-liveness reschedule
(§4.2 item 3). If elision reused `.skipped`, the deadline would never be
rescheduled and the animation loop would stall (the very restart trap §4.2/§9
warn about).

So elision needs a path that (a) does NOT abandon the frame, (b) does NOT run
present/`recordPresentedRasterSurface`/lifecycle-apply (the bulk of
`applyAcquiredFrame`), but (c) STILL reaches `requestNextAnimationFrameIfNeeded`
off the now-published live controller and (d) emits the `elided_frames`
diagnostic and increments `renderedFrames`. None of `.skipped`'s handler shape
fits. The `.elided` case carries no `FrameArtifacts` (there are none), so it
cannot flow through the `.rendered` branch either. Later tasks should add a
dedicated `.elided` branch in the `frameLoop` switch that runs the reduced commit
result + reschedule + diagnostic, then `continue frameLoop`. Note: the
`requestNextAnimationFrameIfNeeded` call must run **after** `commitElided()` has
published the advanced state to the live controller, because it reads
`renderer.internalAnimationController.lastTickResult` (the live one), which
`publishCommittedState` updates via the checkpoint restore (`:176`).

### Decided `commitElided()` contract

Commit ALL FOUR sub-drafts — identical disposition to `commit()` — because each
is independent of `finalizeFrame` / `place` / raster / present (Q1–Q3). The only
difference from `commit()` is the **precondition that no `finalizeFrame`,
`commitPlanner.plan`, `publishCommittedFrame`, or present runs afterward**; the
caller (run loop `.elided` branch) is responsible for honoring that and for
calling `requestNextAnimationFrameIfNeeded` after this returns.

Note one asymmetry vs `commit()`: the normal commit path calls
`draft.transaction.materializePreparedState()` *before* `commitFrameEffects`
(`DefaultRenderer+CompletedFrameCandidates.swift:95`), because the tail and
`finalizeFrame` need the prepared graph state live. The elided path runs none of
that tail work, so `materializePreparedState()` is **not required for the four
sub-draft commits** themselves — `commitRuntimeRegistrations` reads
`liveIdentities`/`nodesByIdentity` and the other three publish draft-local state,
none gated on the prepared-checkpoint having been re-materialized. Later tasks
should VERIFY this on the abortable executor (where prepared state may have been
suspended by `injectAnimations`' worker-snapshot branch,
`DefaultRendererFrameHeadCoordinator.swift:126-134`); if any downstream
consumer of the committed live graph expects prepared state materialized,
`commitElided()` (or its caller) must `materializePreparedState()` first to
match `commit()`. Conservative default: have the caller materialize prepared
state before `commitElided()` exactly as the normal path does, since it is cheap
relative to the tail it replaces and removes a subtle divergence.

Proposed signature and body (lives on `FrameHeadTransaction`, mirrors `commit()`):

```swift
/// Reduced commit for an elided (off-screen / zero-on-screen-redraw,
/// animation-deadline-only) frame. Publishes the same four sub-drafts as
/// `commit()` — they are each independent of `finalizeFrame`/`place`/raster —
/// so deferred animation completions fire on real-time schedule and the
/// advanced animation-controller state reaches the live controller, WITHOUT
/// running `finalizeFrame`, `commitPlanner.plan`, `publishCommittedFrame`, or
/// any present work.
///
/// Precondition for the caller: no tail/finalize/present runs after this. The
/// caller MUST still reschedule the animation deadline
/// (`requestNextAnimationFrameIfNeeded`) off the now-published live controller,
/// and `capturePlacedTree` is intentionally NOT run (no placed tree exists;
/// the prior frame's captured tree remains current — see §8).
package func commitElided() -> RuntimeRegistrationDiagnostics {
  precondition(!didCommit && !didDiscard)
  let diagnostics = graphDraft.commitRuntimeRegistrations(from: viewGraph)
  observationDraft?.commit()
  presentationPortalDraft.commit()
  animationDraft.commit()
  didCommit = true
  return diagnostics
}
```

This body is byte-for-byte identical to `commit()` (`FrameHeadDraftTransaction.swift:75-83`)
today. It is given a distinct name (rather than reusing `commit()`) so the
elision intent is explicit at the call site, so the "no finalize/present after"
precondition has a home in documentation, and so a future divergence (e.g. an
elision-specific diagnostic or a decision to skip `commitRuntimeRegistrations`
when the plan is provably `.unchanged`) has a seam to land on without perturbing
the hot render path. Behavior-wise the two are interchangeable at the spike's
verified scope; the separation is for clarity and future-proofing, not because
any sub-draft needs different handling.

### Risks surfaced for later tasks

1. **`requestNextAnimationFrameIfNeeded` reads the LIVE controller's
   `lastTickResult`** (`RunLoop+Rendering.swift:144`). The `.elided` branch MUST
   call `commitElided()` (→ `publishCommittedState`) *before* rescheduling, or the
   reschedule reads stale tick state and the loop can stall. Ordering is
   load-bearing.
2. **`capturePlacedTree` gap** (confirmed independent of the transaction). The
   live controller's `previousPlacedRoot` / matched-geometry bookkeeping is
   frozen across a run of elided frames. Benign for the off-screen case but
   exactly the §8 risk; the matched-geometry / removal test (§7) must exercise an
   elide→reveal sequence, not just a single elided frame.
3. **Prepared-state materialization asymmetry** vs the normal commit path
   (see contract note above) — verify on the abortable executor; safest to have
   the caller materialize prepared state before `commitElided()`.
4. **Gate predicate is the safety boundary for Q1.** `commitRuntimeRegistrations`
   will faithfully publish whatever plan the head recorded; it does not itself
   prove the plan is empty. The deadline-only-causes gate (§5.1) is what makes the
   committed plan benign. Do not weaken the gate without revisiting Q1.
5. **`discard()` remains unavailable for one-shot heads** (`preconditionFailure`,
   `FrameHeadDraftTransaction.swift:124-127`). `commitElided()` does not touch
   checkpoints and so works for both one-shot and abortable heads, matching
   `commit()`. The `renderOneShot` executor must therefore route elision through
   `commitElided()` (not `discard()`), consistent with §7's all-three-executors
   requirement.

---

## Perf result (Task 9)

**Measurement date:** 2026-05-29
**Scenario:** `synthetic-offscreen-phase-animator`
**Mode:** async
**Iterations:** 20 per build
**Method:** manual JSON extraction from per-run `summary.json` files (BEFORE schema lacks `elided_frames`; `termui-perf compare` confirmed working on single-run pairs)

| | BEFORE (`375dbbb5`, no elision) | AFTER (`60b8c681`, with elision) |
| --- | --- | --- |
| Median `total_cpu_seconds` | 1.4455 s | 0.4751 s |
| Stdev | ± 0.0457 s | ± 0.0114 s |
| CV | 3.2 % | 2.4 % |
| Range | [1.3543, 1.5078] | [0.4505, 0.4929] |

**Absolute reduction:** 0.9704 s (67.1 % faster)

**Significance:** pooled σ = 0.0471 s; Z-score = 20.6 (the gap is 20.6 σ above noise — massively significant, far beyond the 2 σ threshold)

**Elision confirmed firing:** `elided` column present in AFTER `frames.tsv` (absent in BEFORE). Total elided frames across 20 AFTER runs: **2,674 / 2,857 total frames (93.6 %)**, averaging ~134 elided frames per run. BEFORE has 0 elided frames.

**Environment:** Apple Silicon (arm64-apple-macosx), Swift 6.3.x (swiftly-managed), release build (`-c release`)

**Verdict:** PASS — H1 off-screen frame elision delivers a large, highly significant CPU reduction (67 %) with confirmed elision firing (93.6 % of frames elided). Meets all success criteria from §2.
