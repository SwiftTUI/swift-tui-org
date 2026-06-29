<!--
Provenance: Independent multi-agent deep-dive (Claude Code "ultracode" workflow), 2026-06-28.
Method: 12 subsystem architecture maps -> per-subsystem finders -> 2-lens adversarial
verification (lens A = mechanism correctness, lens B = real-world trigger/blast-radius)
-> ranked synthesis. Subsystems mapped: 12/12. Findings verified: 53;
survived: 46; refuted: 7.
CAVEAT: the centralized prior-art digest agent returned a stub, so the "vs prior in-repo
reports" framing was NOT reliably cross-checked against the 2026-06-26 audits and should
be re-validated by hand before acting on novelty claims. The code-grounded findings
themselves (file:line, mechanism, verdicts) are the trustworthy core.
-->

# SwiftTUI Independent Deep-Dive: Architectural Bottlenecks & Fragility

*Synthesized from adversarially-verified findings (lens A = mechanism correctness, lens B = real-world trigger/blast-radius). Severities reflect the conservative reconciliation of both lenses; contested items are flagged. 7 findings were dropped as refuted (see Appendix).*

---

## 1. Executive summary

The codebase is a sophisticated, heavily-optimized reactive render pipeline whose **correctness invariants are largely enforced by convention and by sampled/DEBUG-only oracles rather than by the type system or by inline checks**. After verification, the picture is:

1. **One genuinely serious concurrency hazard.** Off-main `@Observable` mutation is laundered through a *bare* `MainActor.assumeIsolated` that the code's own author deliberately left unchecked, racing the lock-free `FrameScheduler` and the `@MainActor` `ViewGraph` (`Observation.swift:71` → `Scheduler.swift:143` / `ViewGraph.swift:808`). This is the single highest-impact item and the framework's *own* `CheckedMainActorAccess.swift` documents this exact class as a past SIGSEGV.

2. **A trivially-triggered input-parser crash.** Unbounded numeric CSI/SGR parameters overflow `Int` and trap, killing the process (`TerminalInputParser.swift:asciiInteger`). One-line fix; reachable remotely via the WebHost input path.

3. **Identity aliasing is a cross-cutting root cause.** Duplicate/aliased `resolvedIdentity` (duplicate `.id`, `ForEach` without stable ids) collapses last-writer-wins across *many* `[Identity: …]`-keyed structures — invalidation maps, the environment-reader reverse scan, and runtime handler registries. Most instances are gated behind "undefined user input" warnings, but the environment-reader case is a silent, nondeterministic under-invalidation.

4. **Selective evaluation is partially undone downstream.** Resolve builds a minimal dirty frontier, but Measure/Place/Commit/Animation re-walk whole subtrees or the whole tree per frame (signature rebuilds, animation snapshot extraction, per-glyph presentation layers). Individually these are bounded by small terminal trees (hence mostly *low* after verification), but collectively they are the steady-state CPU/allocation tax during animation.

5. **The "drop" optimizations are fragile but not catastrophic.** A single `Canvas`/custom-`Layout` node disables *all* retained draw/semantic reuse tree-wide; one orphaned animation completion permanently forces every frame to commit. Both degrade performance silently without affecting correctness.

Overall confidence: **high** on mechanisms (the verifiers traced code end-to-end); **moderate** on blast radius, because nearly every "high" candidate was deflated once terminal-scale tree sizes and narrow trigger conjunctions were accounted for.

---

## 2. Systemic cross-cutting risks

These are the root causes worth fixing structurally, because each surfaces in multiple subsystems.

### S1. MainActor confinement by convention, not by type (concurrency) — **High**
**Shared mechanism:** `FrameScheduler`'s load-bearing coalescing state (`pendingCauses`, `invalidatedIdentities`, `nextDeadline`, intent counters) is mutated lock-free; the two `OSAllocatedUnfairLock`s guard only the wake-handler ref and continuation waiters (`Scheduler.swift:117,123,143-149`). `ViewGraph` is `@MainActor` (`ViewGraph.swift:72`). Safety depends on every caller being on the main actor.

- **`offmain-observation-races-scheduler-and-viewgraph`** (*Critical per lens A / High per lens B → reconciled **High**, contested*): `ObservationBridge.track` installs an `@Sendable` `withObservationTracking` onChange whose body is a *bare* `MainActor.assumeIsolated` (`Observation.swift:63-75`), with an in-code comment explicitly declining the project's own `withCheckedMainActorAccess` so off-main mutations are not trapped. In release, `recordChange` then mutates the lock-free scheduler Sets and the `@MainActor` ViewGraph dirty sets concurrently with the run loop → unsynchronized `Set`/`Dictionary` mutation = UB / heap corruption. Lens B's deflation: `Task.detached` tends to produce a *deterministic* executor-check trap in debug; the silent-release-corruption path needs a non-task off-main context (DispatchQueue/IO callback) writing an observed model. Either outcome (debug crash on a usage the comment blesses, or release corruption) is severe.
- **`frameschedule-public-contract-vs-mainonly-impl`** (*lens A refuted / lens B medium → **Low**, contested*): The `public`/nonisolated `Invalidating`/`FrameScheduling` surface advertises a thread-agnostic entry point. Lens A's refutation is strong: the protocols and `FrameScheduler` are **non-`Sendable`**, so Swift 6 strict-concurrency *would* reject a future off-main caller at compile time — the type system is not as silent as the candidate claims. Residual real concern: the public nonisolated shape is an API-stability trap (adding `@MainActor` later is source-breaking) and the partial locking reads as false thread-safety.

**Fix direction:** make `FrameScheduler` an `actor` or `@MainActor` (accepting the API break now while pre-1.0), or route the Observation bridge through a main-actor hop (`MainActor.assumeIsolated` replaced with an enqueue-to-main). Adopt `withCheckedMainActorAccess` at the Observation seam as the codebase already does elsewhere.

### S2. Identity aliasing collapses Identity-keyed structures (coupling/fragility) — **Medium**
**Shared mechanism:** when two live nodes share a `resolvedIdentity` (duplicate explicit `.id`, `ForEach([7,7])`, entity-routed nodes), every `[Identity: …]` map is last-writer-wins. Documented for the placement caches in prior art; this audit confirms it propagates further:

- **`env-readers-identity-roundtrip`** (**Medium**): `environmentDependents` discards the precise reader `ViewNodeID`s, round-trips through `Identity`, and recovers IDs via a nondeterministic `identityByNodeID.first(where:)` O(n) reverse scan (`ViewGraphDependencyIndexing.swift:128-152`). Under aliasing the genuine `@Environment` reader can be replaced by an aliased sibling and dropped → silent stale environment until a full re-resolve. A correct O(1) reverse map (`nodeIDByIdentity`) exists and is bypassed. *This is the most concerning aliasing instance — silent, nondeterministic, no warning.*
- **`duplicate-id-invalidation-aliasing`** (*lens A refuted / lens B low → **Low**, contested*): the structural-intersection reuse gate reads the aliased `nodeIDByIdentity` (`ViewGraph.swift:structuralInvalidationIntersects`), but lens A showed the identity-axis checks (`identityIntersectsInvalidation`, `conflictsWithInvalidation`) reject reuse first for the plain duplicate-id case; the precise scan compares `Identity` *values*, not nodes. Real but subsumed and gated behind the `identity.duplicateEntity` RuntimeIssue.
- **`identity-keyed-registry-collision`** (*lens A refuted / lens B low → **Low**, contested*): handler registries (`LocalActionRegistry.swift` et al.) collapse duplicate-identity siblings' handlers last-writer-wins. Lens A's correct point: `Identity` is the *universal* dispatch key, so two siblings sharing it are inherently non-addressable by any subsystem; the resolve pass emits a dedicated `identity.duplicateEntity` warning (`ChildDescriptor.swift:90-126`). Working-as-designed degeneracy for declared-undefined input, not a coupling defect.

**Fix direction:** thread `nodeIDByIdentity` (O(1), deterministic) into `environmentDependents` and stop round-tripping through `Identity`; this alone closes the one silent case. The registry/intersection cases are acceptable given the duplicate-id warning contract.

### S3. Whole-tree / whole-subtree walks uncoupled from the dirty frontier (bottleneck) — **Medium aggregate**
**Shared mechanism:** Resolve produces a minimal dirty frontier, but later phases re-walk far more than the change. Individually most verify to **Low** (bounded by terminal-scale node counts), but the pattern is the dominant steady-state cost during animation. See §3 for the ranked specifics: `signature-rebuild-storm`, `full-tree-walk-every-frame-head`, `per-glyph-presentation-layer-recording`, `allocated-pass-redundant-remeasure`, `cache-hit-verification-quadratic`, `reuse-path-quadratic-invalidation-scan`, `eager-viewport-translation-walk`, `invalidation-summary-double-ancestor-scan`, `full-tree-sizing-walk-and-verify`.

### S4. Memo reuse soundness is structurally unverifiable + DEBUG oracles are costly (fragility/bottleneck) — **Low**
**Shared mechanism:** memo reuse trusts author `==`; the only soundness oracle runs on the *recompute* path, which reuse skips.

- **`memo-oracle-structurally-blind-to-real-reuse`** (**Low**): `memoizedReusableSnapshot` reuses on `compareEquatable==.equal` (`ViewGraph.swift:1641`); `finishMemoObservation`'s `memoReuseEquivalent` only runs when the node is recomputed (`ViewFoundation.swift:557-572`). So no production signal can ever catch a shipped stale reuse. Verified as inherent to all Equatable memoization (SwiftUI `EquatableView` parity) and bounded by `hasNoMemoUncoveredDependencies` excluding reactive reads — a documented contract, not a defect.
- **`debug-reflective-comparator-every-node-every-frame`** / **`debug-byte-equivalence-quadratic`** / **`full-tree-sizing-walk-and-verify`** (all **Low**): default-on DEBUG/test oracles run reflective `Mirror` comparisons (`MemoSkipTrace.swift`), an O(N·depth) recursive structural index compare (`RetainedFrameQueries.swift:isByteEquivalent`), and an extra full re-raster + surface compare (`Rasterizer.swift:264-324`) **every frame**. Release-safe, but they inflate CI wall-clock and *distort any profiling taken from DEBUG builds*. Worth gating to sampled frames.
- **`memoview-value-mutated-outside-stamping-protocol`** (*contested → **Low***): the only live writer of the checkpointed `memoViewValue` is cross-module (`ViewFoundation.swift:469`) and skips `recordCheckpointMutation`; lens A showed it is safe-by-construction because the write is only reachable via `beginEvaluation`, which bumps the generation. Latent coupling/documentation nit.

---

## 3. Performance bottlenecks (ranked)

| # | Finding | Severity | Location |
|---|---------|----------|----------|
| P1 | Phase-products whole-tree gate | Medium | `FrameTailRetainedState.swift:storeCommittedFrame` / `RetainedPhaseExtraction.swift:make` |
| P2 | Retained signature rebuild storm | Medium | `FrameTailRetainedState.swift:97-101`, `FrameTailModels.swift:30-73` |
| P3 | Per-glyph presentation-layer recording | Medium | `Rasterizer+Sampling.swift:264`, `RasterPresentationLayerRecorder.swift:35` |
| P4 | Animation full-tree walk every frame head | Low *(contested: A=Medium)* | `AnimationController.swift:processNode`, `AnimationTreeQueries.swift:collectMatchedGeometry` |
| P5 | Stack allocated-pass redundant re-measure | Low *(contested: A=Medium)* | `LayoutEngine+StackMeasurementScheduling.swift:83-90` |
| P6 | Invalidation-summary double ancestor scan | Low *(contested: A=Medium)* | `RetainedFrameQueries.swift:RetainedInvalidationSummary.init` |
| P7 | Cache-hit verification recursion | Low | `MeasurementCache.swift:87`, `ResolvedNodeEquivalence.swift:isEquivalentForMeasurement` |
| P8 | Reuse-path invalidation scan | Low | `ViewGraph.swift:structuralInvalidationIntersects:2070-2086` |
| P9 | Eager viewport-translation walk | Low | `LayoutEngine+RetainedLayout.swift:retainedPlacement:64-65` |
| P10 | keyPath-narrowed full dict scan | Low | `ViewGraphDependencyIndexing.swift:84-126` |
| P11 | Compositing-group full-grid allocation | Low | `Rasterizer+Paint.swift:emptyCells:441-449` |
| P12 | Reconciliation payload array CoW | Low | `LayoutEngine+MeasurementWorkStack.swift:finishStackReconciliation:265-287` |

**P1 — Phase-products whole-tree gate.** *Mechanism:* `storeCommittedFrame` retains `previousPhaseProducts` only when `RetainedPhaseExtractionSignature.make(from: placedTree)` is non-nil; `make` returns nil on the *first* `.canvas`/`.foreignSurface`/`.custom`-layout node anywhere (`RetainedPhaseExtraction.swift:156-181`). The subtree-granular `.subtreesIdentical` partial path then can never engage (it requires the whole-tree signature). *Trigger:* any tree containing one Canvas/chart/custom-Layout node — common in real TUIs. *Impact:* draw + semantic phases re-extract from scratch every frame, tree-wide. *Mitigated:* retained **layout** reuse (the heavier path) is stored unconditionally, so only the two linear lowering walks are lost. *Remediation:* gate phase-product retention per-subtree (the partial path already exists); let the unsupported subtree fall back while reusing the rest.

**P2 — Signature rebuild storm.** *Mechanism:* `RetainedPhaseExtractionSignature.make` allocates one `NodeSignature` per node; `storeCommittedFrame` builds **two** full signatures (`effective` + `baseline`) on value-identical trees in the no-overlay case, then compares them element-wise only to find equality; `phaseExtractionProof` builds a third next frame (`FrameTailModels.swift:30`). *Trigger:* every retained frame. *Impact:* 3 full O(N) heavy-array walks/frame; mostly refcount bumps (COW `Boxed` fields) but a redundant deep `Equatable` compare. *Remediation:* skip the second build+compare via the overlay-empty flag the code already has (`baselinePlaced == placed` when no overlays).

**P3 — Per-glyph presentation-layer recording.** *Mechanism:* `write(...)` unconditionally calls `presentationRecorder?.appendCellFragment` with no `presentationEffects.isEmpty` guard; each call slices `Array(row[lower..<upper])` (heap copy) and appends a layer (`RasterPresentationLayerRecorder.swift:35`). The copied cell payload is never consumed by the terminal renderer — only bounds/order/effects feed `RasterSurfaceDamageDiff`. *Trigger:* every painted glyph on fresh/full rasters (~1900/frame at 80×24); incremental frames are bounded to dirty rows. *Remediation:* drop the cell-slice copy (diagnostics-only); keep the lightweight bounds/order/effects layer for the topology diff.

**P4–P12** are confirmed mechanisms whose blast radius is bounded by terminal-scale trees (hundreds of nodes, not DOM-scale) and were deflated to **Low** on that basis. The recurring fix is the same: **couple these walks to the dirty frontier / cache the prior result instead of re-walking**. P4 (animation injection runs unconditionally even with zero animations — add a `hasActiveAnimations/hasMatchedGeometrySources` fast-path), P5 (skip re-measuring rigid children whose allocated==ideal — the `stackChildRemeasurementIsNoop` helper already exists for the cross pass), and P6 (index-back the invalidated-id ancestor scan) are the three with the clearest wins.

---

## 4. Fragility & correctness risks (ranked)

| # | Finding | Severity | Class |
|---|---------|----------|-------|
| F1 | Off-main observation race | High *(contested: A=Critical)* | **Concurrency/MainActor** |
| F2 | Unbounded CSI param Int overflow trap | High *(contested: B=Medium)* | Input robustness / DoS |
| F3 | Dirty-row cull drops offset/position descendants | Medium *(contested: A=High)* | **Raster damage soundness** |
| F4 | Single deadline slot loses gesture timer | Medium | Run-loop coordination |
| F5 | Orphaned completion permanently poisons frame-drop | Medium | Animation lifecycle |
| F6 | Graphics-probe stdin race | Medium | **Concurrency** (two readers, one fd) |
| F7 | Removed-untransitioned animation keeps pump alive | Medium | Animation lifecycle |
| F8 | Island-seam `evaluationHost` not refreshed on reuse | Medium | **Reuse/invalidation soundness** |
| F9 | Env-reader identity round-trip drops reader | Medium | Invalidation soundness (see S2) |
| F10 | LazyStack zero-minimum collapse | Low | Layout soundness |
| F11 | Non-Equatable @State clears whole spine freshness | Low | Reuse/invalidation |
| F12 | Frontier keys on persistent `isDirty` shadow | Low *(contested)* | Invalidation soundness |
| F13 | nil-discriminator weakens 4 equivalence oracles | Low *(contested)* | Cache soundness |
| F14 | disableRawMode teardown order | Low | Terminal restore |
| F15 | latestSemanticSnapshot dual-role drop baseline | Low | Run-loop routing |
| F16 | focus-sync budget grows with graph | Low | Run-loop bound |
| F17 | updateInputCapabilities no-op on live stream | Low | Input config (latent) |

**F1 — Off-main observation race.** See **S1**. The single most important correctness item. *Remediation:* main-actor hop at the Observation seam or actor-ize the scheduler.

**F2 — Unbounded numeric parameter Int overflow trap.** *Mechanism:* `asciiInteger` accumulates with checked `value = (value * 10) + …` — no `&*`/`&+`, no digit cap, no buffer cap (`TerminalInputParser.swift:441-456`). ~19+ digits overflow `Int64` and trap (SIGILL); ~10 digits on wasm32. Reachable via SGR mouse, VT220 tilde, and CSI-modifier paths. *Trigger:* malformed/adversarial stdin. *Blast radius:* deterministic process kill; lens A flags the WebHost forwards client input into this same parser (remote one-shot kill), which is why I rank it **High** over lens B's local-TTY-bounded Medium. Bracketed paste mitigates the paste vector but not piped/remote input. *Remediation:* one-line fix — overflow-safe accumulation or a digit-count cap with graceful sequence-drop. **Cheapest high-value fix in this report.**

**F3 — Dirty-row cull drops offset/position descendants.** *Mechanism:* the incremental paint walk `continue`s (skips the whole subtree) when a node's own `visibility.bounds` rows fall outside `dirtyRowRange` (`Rasterizer+Paint.swift:155-165`). But children are bounded by the *clip* chain, not the parent's bounds; an `.offset(x,y)` wrapper keeps its slot bounds while its child paints far away (`PlacementRequests.swift:229-235`). When only the offset child animates, `dirtyRowRange` clusters at the child's rows, the wrapper is culled before the child is reached, and the cleared rows stay blank/stale. The in-code soundness comment (`Paint.swift:130-136`) is unsound for layout-neutral ancestors. *Trigger:* isolated content update under a large `.offset` (lens A traced this end-to-end as release-shipping visual corruption under `.trustSoundDamage`); lens B narrows it to *large* offsets and notes `.position` mostly self-mitigates (it fills its proposed space). Reconciled **Medium**, but I flag lens A's **High** because this is a *silent, persistent, release-only visual corruption* — the most severe non-concurrency correctness item. *Remediation:* the cull must test the union of descendant painted rows (or treat offset/matched-geometry ancestors as non-cullable).

**F4 — Single deadline slot loses gesture timer.** *Mechanism:* `FrameScheduler` coalesces all timers into one `nextDeadline = min(...)` (`Scheduler.swift:166-175`); a 500ms long-press target is discarded when a 33ms animation/fling deadline min-wins. Long-press arms once on `.down` and is never re-armed; `drainGestureDeadlinesIfNeeded` only recovers on `.deadline`-caused frames, not input frames. *Trigger:* long-press overlapping a transient animation that ends before the threshold. *Mitigated:* `.up` honors the timestamp, so the gesture still resolves on release (the "fire-while-held" contract is delayed, not permanently lost). *Remediation:* a multi-slot deadline heap, or re-arm pending gesture deadlines each frame.

**F5 — Orphaned completion poisons frame-drop.** *Mechanism:* `completionClosures` is removed at only four sites; a completion registered for a batch that never becomes a resolve transaction's `animationBatchID` is never pruned (`AnimationController.swift:registerCompletion` / `scheduleStrandedBatchDrains`). `frameDropEligibilityBlockers` gates on `!completionClosures.isEmpty`, so one stranded completion forces *every* subsequent frame to commit for the renderer's lifetime. The in-code comment claims a "resolve-time prune" that does not exist. *Trigger (verified narrow):* `withAnimation { }` with a completion and a net-no-op body — lens B refuted the broader PhaseAnimator/cancellation triggers (those route the batch through the drain). *Impact:* permanent loss of the visual-only frame-drop optimization + small closure leak; no correctness/CPU-peg (the loop still quiesces). *Remediation:* add the missing resolve-time prune of completions whose batch never materialized.

**F6 — Graphics-probe stdin race.** *Mechanism:* the lazy graphics-capability probe (first image-bearing frame) synchronously `poll()`+`read()`s the input fd for up to ~530ms on `@MainActor` (`TerminalHostCapabilities.swift:performGraphicsQuery`), while the `InputReader`'s `DispatchSource` is already draining the *same* fd (`InputReader.swift:184`). Two readers split the byte stream: probe-response bytes decoded by the InputReader become spurious keystrokes (an injected `Escape` can dismiss a modal); real keystrokes can be swallowed by the probe. *Trigger:* once-per-session, first deferred image render, worst on slow/ssh terminals. *Mitigated:* the appearance probe avoids this by running before the input stream exists — the graphics probe should too. *Remediation:* probe before resuming the input source, or route the probe through the live InputReader.

**F7 — Removed-untransitioned animation keeps pump alive.** *Mechanism:* in `processResolvedTree`'s removal loop, a removed node with no transition `continue`s before the supersede-and-release filter (`AnimationController.swift:807-809`), so an in-flight `.property` animation keyed by the now-absent identity is never released; `applyInterpolations` keeps ticking it, inserting a dead identity into `redrawIdentities` and keeping the 33ms pump armed. *Trigger:* a property animation on a subtree removed by a plain `if` (no `.transition()`). *Impact:* bounded waste for finite curves; the genuinely bad case is `.repeatForever` (never returns nil → pump spins forever painting nothing). *Remediation:* release `activeAnimations` for removed identities on the no-transition path too.

**F8 — Island-seam `evaluationHost` stale on reuse.** *Mechanism:* `evaluationHost` (the cross-seam staleness link) is written only in `beginEvaluation`; `beginReuse` never refreshes it (`ViewNode.swift:262-289`). A reused capture-hosted island keeps its last-captured host pointer; if the host churns to a new `ViewNode` while the interior is reused-not-re-evaluated, the live host is never marked stale → silent stale render. *Trigger (verified narrow & self-healing):* host identity churn + decoupled island identity + a later disjoint interior mutation; bounded to the next host-touching frame. Documented as a known residual. *Remediation:* refresh `evaluationHost` in `beginReuse`.

**F10–F17** are confirmed-but-low. Notable: **F10** lazy indexed stacks store empty `childMeasurements`, so `derivedMinimumMainSize` zips N children against zero pairs and derives a ~zero minimum, letting a compressing parent collapse a `LazyVStack` (`RetainedLayout.swift:187-196`, `StackMinimums.swift`) — real but narrow (lazy stacks are normally free-sizing scroll content). **F11** non-Equatable `@State` installs an always-false comparator so every write (even no-op) clears the ancestor spine's snapshot freshness (`StateSlot.swift:42`), defeating reuse along the spine — bounded to the spine, not tree-wide. **F12** the dirty frontier tests persistent `node.isDirty` rather than current-frame membership (`ViewGraphDirtyEvaluationPlanning.swift:86`); verified defused by universal per-node evaluator installation — a latent smell, not a live bug.

---

## 5. Coordination-layer risks (Bazel / submodule / pinning / gates)

| # | Finding | Severity | Location |
|---|---------|----------|----------|
| C1 | SwiftPM/Xcode consumer pins unverified; overlay masks them | Medium | `version_coherence.sh`, `materialize_pretag_overlay.sh:103`, `release_artifact_contract.sh:79-86` |
| C2 | bump_version corrupts coincidental third-party version tokens | Medium | `bump_version.sh:207-261` |
| C3 | Pin ≠ released tag; untagged-ahead pin passes release_candidate | Low | `release_pin_contract.sh`, `release_artifact_contract.sh:82`, `pin_cleanliness.sh` |
| C4 | Head-mode overlay copies HEAD, not pin; determinism conditional | Low | `materialize_pretag_overlay.sh:131` vs `pin_cleanliness.sh:39` |
| C5 | Smoke test writes into live submodule; SIGKILL wedges pin_cleanliness | Low | `open_overlay_smoke_test.sh`, `pin_cleanliness.sh:50-54` |

**C1 (Medium).** `version_coherence.sh` — the only automated lockstep-skew defense — reads only `releases.yml current:` and web `package.json`, never a child `Package.swift` or `pbxproj`. The pretag overlay's `req_re` is value-agnostic and rewrites `exact:"X"` to a local path regardless of `X`, masking a stale pin. `release_artifact_contract` only checks the *tag exists*. So a partial bump (releases.yml + web bumped, a child SwiftPM/Xcode pin missed) passes `org_fast`, `org_full`, **and** `release_candidate`. *Deflated to Medium because the happy-path `bump_version.sh` rewrites all pins atomically and downstream child CI/`swift package resolve` would catch a non-existent tag.* This is the exact version-skew class the root was built to prevent, left uncovered on the primary SwiftPM consumer edge. *Remediation:* add a gate parsing consumer `exact:`/`version =` pins against `releases.yml`.

**C2 (Medium, single-verdict).** `bump_version.sh` gathers candidates via file-wide `git grep -F "$old_version"` filtered only by lockfile/doc allowlists, then does a global boundary-matched `s///g`. A third-party dependency (or a test fixture like `v0.1.0`) at the same semver as the org version is silently rewritten. A concrete in-tree mis-fire exists: `gitviz/Tests/.../GitParsersTests.swift:47` git-tag fixtures. *Deflated to Medium because the tool defaults to dry-run with a per-file diff and never commits/tags.* *Remediation:* restrict substitution to known org-version keys, or extend the exclusion list to authored manifests/test fixtures.

**C3–C5 (Low).** Gates verify weaker properties than they appear to (S5): pin-ancestor-of-origin/main ≠ pin-equals-released-tag (C3); head-mode overlay archives submodule HEAD not the recorded pin, and `pin_cleanliness` is an unsequenced separate test so an isolated pretag-gate run can be untrustworthy (C4); the smoke test writes a marker into the live submodule guarded only by a non-SIGKILL trap (C5). All bounded — the aggregate suites still catch C3/C4, and C5 is recoverable with one `rm` and self-identifying (the filename names its origin).

---

## 6. Prioritized remediation list

| Rank | Item | Severity | Effort | Why now |
|------|------|----------|--------|---------|
| 1 | F1 Off-main observation race — main-actor hop / actor-ize scheduler | High *(↑Critical)* | M | Memory-unsafe, default config, common pattern; framework's own docs cite this SIGFAULT class |
| 2 | F2 CSI param overflow trap — bound digit accumulation | High | **S** | Deterministic process kill; remote-reachable via WebHost; one-line fix |
| 3 | F3 Dirty-row cull drops offset descendants — union descendant rows | Medium *(↑High)* | M | Silent persistent release-only visual corruption of a common offset-animation pattern |
| 4 | S2/F9 Env-reader reverse-scan — use `nodeIDByIdentity` | Medium | S | Closes the one silent, nondeterministic under-invalidation; correct map already exists |
| 5 | F4 Multi-deadline scheduler slots | Medium | M | Broken fire-while-held gesture contract |
| 6 | F5 Orphaned-completion prune at resolve time | Medium | S | Permanent silent loss of frame-drop optimization |
| 7 | F6 Graphics probe before resuming InputReader | Medium | S | One-time input corruption + sub-second freeze on image apps |
| 8 | F7 Release removed-untransitioned property animations | Medium | S | `repeatForever` → permanent pump spin |
| 9 | P1/P2 Per-subtree phase-product gate + skip duplicate signature build | Medium | M | Restores draw/semantic reuse on any Canvas-bearing screen |
| 10 | C1 Gate consumer SwiftPM/Xcode pins vs releases.yml | Medium | M | Closes the named version-skew edge the root exists to prevent |
| 11 | F8 Refresh `evaluationHost` in `beginReuse` | Medium | S | Narrow but silent stale-render island case |
| 12 | S4 Gate DEBUG oracles to sampled frames | Low | S | Unblocks trustworthy DEBUG profiling; reduces CI wall-clock |
| 13 | C2 Scope `bump_version` substitution to org-version keys | Medium | S | Prevents silent third-party pin corruption at release |

---

## 7. Appendix: contested & refuted

### Refuted and dropped (7) — both lenses found the causal chain does not hold
- **queueDirtyForObservationChange silent no-op** — the supposed divergence from other invalidation entry points was not borne out.
- **Measurement-cache nil-discriminator serves wrong view type** — superseded by the deeper analysis (F13 below) and not reachable as stated.
- **LayoutPassContext.placedFrameTable getter O(table) CoW copy** — getter does not force the claimed copies.
- **Scroll-momentum forward-Euler teleport on coalesced timestep** — timestep handling refuted.
- **Process-exit reset leaves kitty graphics residue** — not substantiated.
- **taskCancel/taskStart no-op on nil viewNodeID leaks/drops .task** — refuted.
- **Frame-head sync accessors share serial queue with async raster** — re-coupling claim refuted.

### Contested (kept, lenses disagreed) — disagreement summary
- **F1 offmain-observation** — A=Critical (memory corruption, framework's own SIGSEGV precedent), B=High (debug builds tend to trap deterministically; silent-release path needs non-task off-main context). Reconciled **High**, ranked #1.
- **F2 ascii-overflow** — A=High (deterministic crash, WebHost remote vector), B=Medium (local TTY = user's own bytes). I sided with A's blast-radius (remote input path) → **High**.
- **F3 dirty-row-cull** — A=High (traced release-shipping corruption end-to-end), B=Medium (narrow to large static offsets; `.position` self-mitigates). Reconciled **Medium**, flagged High.
- **F12 frontier-isDirty**, **F13 nil-discriminator**, **`duplicate-id`**, **`identity-keyed-registry`**, **`frameschedule-public-contract`**, **`memoview-value`** — in each, lens A refuted the *harmful outcome* (defused by an invariant: universal per-node evaluators, kind-name faithfulness for primitives, identity-axis reuse rejection, non-`Sendable` compile-time enforcement, evaluation-entry stamping) while lens B kept it as a real-but-low latent smell. All reconciled **Low**.
- **Bottlenecks P4/P5/P6, `scoped-publication`, `full-tree-walk`** — A argued Medium (genuine uncoupled O(N)/O(subtree) work), B argued Low (bounded by terminal-scale trees; reactive scheduling means idle trees pay nothing). Reconciled **Low**, noting the Medium mechanism.

**Honest note on divergence from prior in-repo reports:** this audit *sharpens* prior art in three places the in-repo digests under-stated — (1) the off-main observation race is a *composition* of two separately-listed "latent" gaps into one live hazard; (2) identity aliasing extends past the placement caches into the environment-reader reverse scan (silent) and the registries (warned); (3) the env-reader reverse lookup is a *correctness* hazard, not merely the perf bottleneck prior art recorded. Conversely, this audit *downgrades* many candidates the source findings rated High: once terminal-scale node counts, default-on feature gates, reactive scheduling, and the duplicate-id "undefined input" warning contract are accounted for, most "high-severity bottlenecks/fragilities" are bounded, gated, or self-healing **Low/Medium** items rather than shipping defects.