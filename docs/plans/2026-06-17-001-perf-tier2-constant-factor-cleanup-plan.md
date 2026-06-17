# Performance Tier 2 — Constant-Factor Cleanup (representative focus flows)

- **Date:** 2026-06-17
- **Status:** Proposed.
- **Measurement base (this plan A/Bs against):** `swift-tui c320a243` (`0.0.20`
  + focus/press dirty-frontier narrowing `e25b1d06`/`d9065efe` + the four
  committed focus-flow / observable scenarios), org root `a93d686`.
- **Predecessor context:** the
  [post-narrowing re-audit](../reports/2026-06-16-focus-press-dirty-frontier-results.md)
  and the new committed scenarios (`gallery-tab-switch`,
  `file-browser-selection`, `text-input-editing`, `synthetic-observable-fanout`).
- **Scope boundary:** this is the **cheap, low-risk, representative**
  constant-factor tranche. The **headline** representative cost — resolve+measure
  *reuse denial* on selection/collection frames (`canReuse` has no
  output-equality path; container `@State` fans out to every item) — is a
  separate **Tier 1 architecture design** and is explicitly **out of scope** here.
  Do not attempt output-equality / sub-body memoization in this tranche.

## 1. Why this tranche, and what it is *not*

The focus/press narrowing already restored selective evaluation on the
click-driven representative flows (they now run `subtrees` publication, zero
`selective_evaluation_disabled_reasons`). The dominant residual on those flows is
the `reused 0` full-recompute frames — a Tier 1 design problem. What remains that
is **cheap and safe** is a cluster of per-frame *constant-factor* costs that ride
on every interaction frame regardless of reuse: an unconditional animation walk,
redundant semantic sub-walks, duplicated registration-fingerprint builds, and an
empty-handler restore walk.

**Honest sizing:** each item below is sub-millisecond-to-~1ms per frame on the
representative scenarios. The tranche is worth doing because the items are
low-risk, additive, and pay down noise that masks the Tier 1 signal — **not**
because any single one is a headline win. We will not oversell: every item must
show a measured, same-session A/B improvement on a representative scenario or be
closed with a recorded "no-op disproven".

## 2. Measured baseline (release, interaction frames `frame > 1`, p50 ms)

Captured 2026-06-16 at the measurement base (`/tmp/reaudit-2026-06-16`,
10 iters/scenario, `--modes async`, diagnostics armed).

| scenario | resolve | measure | place | semantics | raster | commit | pipeline | head_prep | proc_tree |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| gallery-tab-switch | 5.15 | 4.62 | 1.27 | 0.39 | 1.60 | 1.13 | 14.45 | 6.52 | 0.33 |
| file-browser-selection | 14.46 | 6.62 | 1.35 | 0.88 | 1.00 | 1.44 | 26.83 | 17.20 | 0.81 |
| text-input-editing | 3.16 | 0.96 | 0.52 | 0.30 | 1.47 | 0.13 | 6.71 | 4.13 | 0.21 |
| synthetic-observable-fanout | 3.84 | 1.45 | 0.34 | 0.15 | 0.49 | 0.47 | 6.83 | 4.03 | 0.13 |
| narrow-40 (canary) | 1.45 | 1.35 | 0.73 | 0.76 | 0.77 | 2.89 | 8.18 | 3.01 | 0.59 |

Reuse shape confirms the Tier 1 (out-of-scope) headline: alternate interaction
frames recompute ~all nodes (`reused 0/349` file-browser, `0/180` tab-switch);
`text-input-editing` is `reused 0/131` **every** keystroke (`root_invalidated`,
`@State text` on the root). Tier 2 does not touch those.

## 3. Measurement contract

- **Representative A/B set:** `gallery-tab-switch`, `file-browser-selection`,
  `text-input-editing` (the focus flows this tranche targets).
- **Canaries (must not regress):** `narrow-40`, `sheet-44`, and
  `synthetic-observable-fanout`.
- **Method:** same-session A/B, release `TermUIPerf`, `--modes async`,
  ≥10 iterations, `swift package reset` + clean rebuild between A and B on any
  core-struct change. Compare with `termui-perf compare` plus per-frame TSV
  medians.
- Phase attribution is read from per-frame `frames.tsv` (`resolve_ms`,
  `measure_ms`, `semantics_ms`, … are already emitted there) until **Item 0**
  surfaces them in the aggregate.

## 4. Item 0 — Measurement infrastructure (prerequisite, do first)

Several Tier 2 items are sized by tail-phase columns that the **aggregate** does
not surface today, and warmup noise inflates first-frame-sensitive items.

- **0a. Surface tail-phase aggregate columns.** The framework already computes
  `FramePhaseTimings { resolve, measure, place, semantics, draw, raster, commit }`
  (`Sources/SwiftTUICore/Commit/FrameTimings.swift`) and writes them per-frame to
  `frames.tsv`, but `Tools/TermUIPerf/Sources/TermUIPerf/SummaryReducer.swift`
  (and `AggregateSummary.swift`) only expose head sub-phases + worker raster. Add
  the seven tail-phase medians to the aggregate so each item below is A/B-gatable
  via `termui-perf compare` rather than ad-hoc TSV parsing.
- **0b. First-frame / steady-state split (optional but cheap).**
  `RunCommand.swift` runs `for _ in 0..<iterations` with no warmup discard, and
  the cold first committed frame pays full O(N) checkpoint create, full
  registration publication, and `TextLayoutCache` cold misses. Report
  first-frame separately (or discard one warmup iteration) so steady-state
  medians are clean. This also creates the only honest place to ever measure
  time-to-first-paint, which no current signal captures.
- **Risk:** none (pure reporting). **Exit:** aggregate JSON carries the seven
  tail-phase columns; `ScenarioSmokeTests` / reducer tests updated.

## 5. Item 1 — `processResolvedTree` idle/unchanged-tree skip gate

**Mechanism (verified).**
`AnimationController.processResolvedTree`
(`Sources/SwiftTUIRuntime/Lifecycle/AnimationController.swift:520`) runs an
unconditional full-tree walk (`processNode`) building six per-identity
dictionaries every committed frame, invoked from
`DefaultRendererFrameHeadCoordinator` (AnimationInjectionStage) with **no**
animation-active guard. A correct safe-skip predicate already exists:
`frameDropEligibilityBlockers` (`AnimationController.swift:457`) flags
`.animationCompletion` / `.animationTransition` exactly when the walk's output is
load-bearing.

**The change (safe variant).** Skip the walk when **both** hold:
1. `frameDropEligibilityBlockers.isEmpty` **and** `registeredAnimations`,
   `activeAnimations`, `removingNodes`, `transitionsByNodeID` are all empty
   (nothing can animate this frame), **and**
2. the resolved tree is unchanged versus `previousTreeRoot` (cheap identity /
   committed-freshness check) — so the `previous*` maps already match and need no
   refresh.

**Why the unchanged-tree clause is mandatory (the subtle correctness point).**
The walk's real job when nothing animates is maintaining `previousSnapshots`
(the animation *from*-state), `previousIdentities`, and `previousTreeRoot`.
Skipping on a frame where the tree **changed** would leave those stale, so the
*next* `withAnimation` would interpolate from the wrong state (a visual jump) and
insert/remove diffing would mis-fire. The unchanged-tree clause guarantees the
maps are already correct.

**Honest sizing.** This fires on idle / no-op convergence frames, **not** on the
representative interaction frames (which change the tree). Measured `proc_tree`
is 0.2–0.8 ms/frame, so the win is the idle-frame and convergence-loop tail, not
the hot interaction frame. Keep expectations low; land it because it is safe and
removes dead work.

**Deferred follow-on (NOT this tranche).** An aggressive variant that skips the
*expensive* per-node `AnimatableSnapshot.extract` while still cheaply refreshing
the identity/tree maps on changed-tree no-animation frames would help interaction
frames — but it needs a designed "first-animation-after-idle re-captures
from-state" guard. Record as design-deferred; do not build here.

**Guards/tests.** `animationFramesKeepTabHostedPaneSurfaceStable` template; H1/H4
animation suites; add a test that a `withAnimation` immediately following a run
of skipped idle frames still animates from the correct prior state.
**Exit:** `head_animation_process_resolved_tree` drops on idle frames; all
animation suites green; no canary regression.

## 6. Item 2 — Semantics extraction trimming (re-scoped from "gate a11y")

**Mechanism (verified).** `SemanticExtractor.extract`
(`Sources/SwiftTUICore/Semantics/Semantics.swift:20`) performs several full-tree
traversals per frame (routing `walk`, `scrollTargets`, `accessibilityNodes`,
`accessibilityWarnings`, cursor anchors); the `retained` overload short-circuits
**only** on `proof == .wholeTreeIdentical`, so focus/press frames
(`.subtreesIdentical`) fall through to the full walk.

**Correction to the audit (do not blanket-gate accessibility).**
`accessibilityNodes` is **load-bearing beyond AT consumers**: the focus-sync
convergence loop feeds it into scroll-position retention
(`RunLoop+FocusSync.swift:116`, `localScrollPositionRegistry.sync(... accessibilityNodes:)`)
and presentation uses it (`RunLoop+Presentation.swift:120`). `file-browser-selection`
exercises exactly that scroll/selection retention. **Gating `accessibilityNodes`
behind an "AT attached" flag would break scroll retention.** So:

**The change (verify-first, narrow).**
- **2a. Audit each semantic sub-walk's consumers** and gate only the
  provably-unconsumed-without-AT passes. Candidates that appear to feed *only*
  the AT renderer / announcer: `accessibilityWarnings`
  (`LinearAccessibilityRenderer`, `SemanticAccessibilityExtraction.swift:77`) and
  possibly cursor-anchor extraction. **Do not** touch `accessibilityNodes`,
  `scrollTargets`, `scrollRoutes`, or `focusRegions`. Confirm with a grep of each
  field's readers before changing anything.
- **2b. Extend the retained short-circuit to `.subtreesIdentical`.** Where the
  draw phase already reuses per-subtree via the same extraction proof
  (`DrawExtractor` honors `.subtreesIdentical(roots)`), let semantics reuse the
  unchanged subtrees instead of re-walking the whole tree. This is the larger,
  trickier half; treat as design-first and only land if subtree-level semantic
  reuse can be proven equivalent to a full re-extract.

**Honest sizing.** Semantics is 0.3–0.88 ms on the representative scenarios
(bigger, ~1.87 ms, only on the amplified sheet). 2a is a small, safe trim on the
common no-AT path; 2b is the real (but harder) win and may slip to its own slice.
**Risk:** 2a low *after* the consumer audit; 2b medium (correctness of subtree
semantic reuse). **Guards:** `AccessibilityRuntimePolicyTests`,
`LiveRegionAnnouncer` tests, focus-sync + scroll-retention tests, semantic
snapshot fixtures. **Exit:** `semantics_ms` drops with byte-identical semantic
snapshots on the consumed fields; a11y suites green.

## 7. Item 3 — Registration commit constant-factor guards

**Mechanism (verified).** In `ViewGraphFrameDraft.commitRuntimeRegistrations`
(`Sources/SwiftTUICore/Resolve/ViewGraphFrameDraft.swift:149`):
- `republishAllEffectRegistrations(into:)` (`ViewGraph.swift:1928`, an
  unconditional O(liveNodeIDs) walk) is called on **all** branches incl.
  `.unchanged` (line 164) — dead O(N) work on no-op frames.
- `recordCommittedRuntimeRegistrationFingerprint()` (line 217) calls
  `currentRuntimeRegistrationFingerprint()` (`ViewGraph.swift:1821`, a full
  Dictionary build) on **every** committed frame, and on `.all` frames the same
  fingerprint is built a **second** time inside
  `runtimeRegistrationPublicationDeltaForCurrentFrame()` (line 166 → `:1798`).

**The change.**
- **3a. De-duplicate the `.all`-frame fingerprint build.** Cache the fingerprint
  computed during the delta check and reuse it for `recordCommitted…`, or build
  it once per frame. Removes one full O(N) Dictionary allocation per `.all`
  frame.
- **3b. Guard `republishAllEffectRegistrations` on a generation signal.** Only
  re-run the effect republish when an effect/lifecycle/task/preference
  registration actually changed since the last commit (a per-graph generation
  bump, mirroring the existing `checkpointMutationGeneration` /
  registration-mutation generation pattern). Skip it entirely on `.unchanged`
  frames whose effect registries are provably current.

**Honest sizing.** Commit is 0.13–1.44 ms on representative frames; these guards
recover a fraction (the redundant build + the no-op republish). Real but modest.
**Risk:** medium — effect/lifecycle/task registries back live `onAppear`/task/
preference handlers; a missed republish silently drops an effect. Must verify a
sound generation signal exists or is cheaply maintainable; if not, descope to 3a
only (pure de-dup, zero behavior change). **Guards:** the registration-restore
byte-identity equivalence tests, `ReaderAttributionTests`, lifecycle/task
effect tests, the scoped-publication island fixtures. **Exit:** `commit_ms`
drops; registration equivalence tests byte-identical; no dropped-effect
regressions under the full gate.

## 8. Item 4 — `restoreRuntimeRegistrations` empty-restore guard

**Mechanism (verified, re-opened).** On each retained-reuse hit,
`ViewFoundation` calls
`ViewGraph.restoreRuntimeRegistrations` →
`ViewGraphRuntimeRegistrationRestoration` walks the reused subtree, and even
handler-less layout/text nodes pay a per-node restore that allocates a Set and
touches the registries. This was **closed** when reuse rarely fired on
focus/press frames; the landed narrowing + the new high-reuse scenarios
(`file-browser-selection`, `gallery-tab-switch` reuse hundreds of nodes per
interaction frame) change its standing.

**The change.** Guard the per-node restore on an existing "has any runtime
registration" property so handler-less nodes skip the Set allocation + registry
touch entirely — a behavior-preserving no-op for nodes that register nothing
(restoring nothing). Confirm the exact property/seam in
`ViewGraphRuntimeRegistrationRestoration.swift` before editing.

**Honest sizing.** Pure allocation/CPU; small but it now fires on hundreds of
reused nodes per representative frame. **Risk:** low (skipping a restore that
would restore nothing). **Guards:** registration-restore equivalence tests.
**Exit:** allocations/restore-walk node-visits drop on the high-reuse scenarios;
equivalence tests byte-identical.

## 9. Standing guardrails (carry into every item)

- **Same-session A/B only**; clean `Tools/TermUIPerf/.build` on any core-struct
  change (stale baselines have produced phantom ±10%).
- **Animation-tick frames are a distinct frame class** — every reuse/commit/
  animation change needs a guard there (Item 1 especially).
- **One flag, one consumer** — a new generation/staleness signal (Items 1, 3)
  must not be overloaded for two semantics.
- **Struct growth ⇒ clean rebuild everywhere**; new stored fields need their
  checkpoint/phase-ownership parity entries.
- **Coordination-only probes/overlays never land in a public child repo.**
- Land each item as its **own swift-tui PR** with its A/B; do not batch.

## 10. Sequencing

1. **Item 0** (measurement infra) — unblocks A/B sizing for the rest.
2. **Item 4** (empty-restore guard) — smallest, lowest-risk, fastest to verify.
3. **Item 1** (processResolvedTree idle skip) — safe variant only.
4. **Item 3a** (fingerprint de-dup) — zero-behavior; then **3b** only if a sound
   generation signal is confirmed.
5. **Item 2a** (semantics no-AT trim) after the consumer audit; **Item 2b**
   (`.subtreesIdentical` semantic reuse) split to its own slice if it does not
   clear the equivalence bar cheaply.

## 11. Definition of done

1. Item 0 landed (aggregate tail-phase columns; first-frame split or warmup
   discard).
2. Items 1, 3, 4 each landed with a same-session representative A/B win and green
   guards, **or** explicitly closed with a recorded "no-op disproven".
3. Item 2a landed or closed; Item 2b landed only if proven equivalent, else
   recorded design-deferred.
4. **No canary regression:** `narrow-40`, `sheet-44`,
   `synthetic-observable-fanout` within noise; registration equivalence
   byte-identical; full gate green under load.
5. Each landed slice has a completion report under `docs/reports/` and a
   `swift-tui` pin bump recorded in this root.
6. The Tier 1 headline (resolve/measure reuse-denial via output-equality /
   collection-`@State` granularity) is recorded as the next design item — it is
   not addressed here.

## 12. References

- Post-narrowing re-audit results: [2026-06-16-focus-press-dirty-frontier-results.md](../reports/2026-06-16-focus-press-dirty-frontier-results.md)
- Signal representativeness: [2026-06-16-perf-signal-representativeness.md](../reports/2026-06-16-perf-signal-representativeness.md)
- Perf phase completion goal (prior tranche dispositions): [2026-06-15-001-perf-phase-completion-goal.md](2026-06-15-001-perf-phase-completion-goal.md)
- New scenario catalog: [docs/perf/README.md](../perf/README.md) Tier 1 table.
- Measured baseline artifacts: `/tmp/reaudit-2026-06-16/` (transient; medians transcribed in §2).
