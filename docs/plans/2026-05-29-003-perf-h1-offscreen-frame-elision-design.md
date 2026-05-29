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
