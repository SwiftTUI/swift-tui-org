# Proposal: Architecture & Fragility Improvements

| | |
|---|---|
| **Date** | 2026-06-26 |
| **Status** | In progress — **12 / 15 landed + #9 started**. Wave A + Wave B (#1/#2/#3/#5/#6/#7/#8/#13/#14/#15), Wave C **#12** (PointerInteractionState) and **#11** (`HostFrameProjection`), plus the **#9** first step (`ConcurrentRegistrationCarry` + carry-forward totality), are all merged to `swift-tui` `main`, pinned, and pushed (each step build + full `bun run test` repo gate green). **#4 (IR encapsulation) is formally shelved (2026-06-26)** — see [proposal 002](2026-06-26-002-pipeline-ir-encapsulation-proposal.md#decision-2026-06-26); it gates nothing. Remaining active: Wave C #9-rest (`CompletionLedger`), #10 (ViewNode grouping + ViewGraph method clusters). See [Progress](#progress-2026-06-26). |
| **Type** | Cross-repo structural + behavioral improvement program |
| **Evidence base** | [`docs/reports/2026-06-26-architecture-fragility-survey.md`](../reports/2026-06-26-architecture-fragility-survey.md) — 33-agent survey, 127 confirmed issues (2 critical / 35 high / 63 med / 27 low) |
| **Affects** | `swift-tui` (framework) + this org-coordination root |

## Context

A multi-agent architecture + fragility survey (see the linked report) found SwiftTUI's macro-architecture **sound** — clean 3-tier module DAG with no cycles, ~4,000 correct `package`-access declarations, zero unsafe-`Sendable` escape hatches (hook-enforced) — with the risk concentrated in **one dominant, recurring bug class** and a cluster of paydown-ready debt. This proposal turns that finding into a **ranked, sequenced program of work.**

The single most important insight driving the ranking: the framework already *has* the soundness oracles that would catch its dominant bug class (reconciliation-seam violations), **but they are almost all `#if DEBUG`, so the class ships in release where the guards are compiled out.** The highest-leverage moves are therefore not the obvious god-object decompositions — they are the low-risk test/oracle changes that reuse existing machinery to convert a whole bug class from "found by a human in the gallery" into "caught at the seam in CI."

Opportunities are ranked by **leverage = (impact × fragility removed) ÷ (effort × risk)**.

## Progress (2026-06-26)

**13 of 15 opportunities landed + #4 shelved**, each built + tested + committed; the full `bun run test` repo gate is green at every boundary. Wave A + Wave B, Wave C **#12**/**#11**/**#9** (the `CompletionLedger` async-writable set, `029324e8`), and **#10's `ViewNode` field decomposition** (four value sub-structs, `8b59f095`) are all **merged to `swift-tui` `main`, pinned, and pushed**. **#4** is [formally shelved](2026-06-26-002-pipeline-ir-encapsulation-proposal.md#decision-2026-06-26). **#10 is substantially done** — fields grouped, methods in ~13 extension files, and the cleanly-extractable pure-read operators (`GraphCheckpointStore` `75e5fd17`, `GraphNodeIndexQuery` `2c5bc1de`) lifted off the god class; the mutation-tracker deferral was investigated and declined (entangled, no payoff — see #10's row). **The original 15-item program is now effectively complete** (13 done + #4 shelved + #9 + #10 substantially done); remaining ViewGraph polish is mutation-heavy logic correctly kept as extension methods.

- **Wave A — complete (5/5):** #1 sampled-release soundness probe, #2 generative 15-registry harness, #3 off-main layout trap (closes the C1/SIGSEGV path), #5 org-gate + WASI CI, #8 VT220 parser fix.
- **Wave B — 5/6:** #6 `FeatureFlags` registry, #7 totality guards, #13 version-coherence gate, #14 bounded image caches, #15 autonomous-wake test **+ the `Tests/Support` harness extraction**. **Deferred: #4** — *attempted and re-estimated* (see the #4 note below); it is **XL**, not the M the survey rated, and its payoff is latent (it de-risks the *cleanliness* of #10/#11, see the gating correction), so it is held for a dedicated boundary-design session.
- **Wave C — #12 + #11 done, #9 first step done, #10 `ViewNode` field-grouping done; remaining: #9-rest + #10 `ViewGraph` methods:** **#12 `PointerInteractionState`** extracted RunLoop's four pointer-*routing* fields (`armedRouteID`, `armedRouteUsesPointerHandler`, `capturedRouteID`, `dragStartLocation`) into a `package struct` with `private(set)` fields mutated only through five intent-named transitions (`beginPress`/`arm`/`capture`/`clearRouting`/`reset`). This makes the dominant "missed reset → stale route mis-routes the next gesture" bug class a **compile error** (a handler can no longer set one field and forget the coupled ones) without changing any behavior — the existing gesture/scroll/drag suites stay green and a new unit suite locks each transition's exact field tuple.
  - **#9 first step landed:** the carry-forward primitive (`ConcurrentRegistrationCarry`). `AnimationController.publishCommittedState` open-coded — twice — the rule that keeps an async-registered `withAnimation` completion alive across the full `restore` that publishes an in-flight frame's draft (live-minus-baseline delta, then re-apply without clobbering the draft's own entries). That hand-mirrored bookkeeping is what orphans a completion the day a third async-writable map is added. It is now one named, unit-tested helper both maps route through; the `AnimationCompletionConcurrencyTests` PhaseAnimator-stall net stays green. The carry-forward set was then **audited verified-total** from the sink call sites — the two carried collections are exactly what the async `withAnimation` path (`AnimationCompletionSink`/`AnimationRegistrationSink`) writes between frames, while transitions are resolve-driven and so already live in the draft; the invariant is now documented in `publishCommittedState`, and the previously-untested animation-box carry-forward got its own regression test. **Framing correction:** the survey's "#9 first step = move the four maps into a `CoreAnimationState` substruct to close the checkpoint-totality gap" was slightly off against HEAD — the three remaining flat maps (`activeAnimations`/`registeredAnimations`/`removingNodes`) are *already* uniformly checkpointed, and `AnimationController` is *already* clustered into four sub-structs (`PreviousFrameState`/`TransitionRegistry`/`BatchCompletionState`/`FrameHeadTransactionState`). The real fragility is the *carry-forward* (which spans `batchCompletion.completionClosures` + the flat `registeredAnimations`), not the checkpoint mirror. **#9 done (`029324e8`):** the `CompletionLedger` value type now *is* the async-writable registration set. It owns both maps (`completionClosures` + `registeredAnimations`), checkpoints them as a whole struct, and carries them across an in-flight publish via its own `concurrentRegistrations(since:)` / `reapply(_:)` — so the "what must survive a publish" rule is a method the compiler walks rather than a doc comment, and a third async-writable map added to the ledger is carried automatically. The anticipated cohesion tension (pulling `completionClosures` out of `batchCompletion`) dissolved in practice: the two already reset at the same point, and computed forwarders keep the per-tick logic reading the original names, so the extraction was behavior-preserving (the `AnimationCompletionConcurrencyTests` PhaseAnimator-stall net + full gate green). The remaining Wave C item is held for a dedicated session:
  - **#10 (`ViewGraph`/`ViewNode`): field-grouping done; `ViewGraph` *method*-cluster extraction remains.** `ViewGraph`'s fields were already nine value-typed groups (`ViewGraphFieldGroups.swift`); **`ViewNode`'s fields are now grouped too** — four cohesive sub-structs in `ViewNodeFieldGroups.swift` (`FrameState` 11 / `EvaluationState` 6 / `ReuseState` 3 / `PersistentState` 5 = 25 fields), moved by whole-struct checkpoint/restore, with identity/wiring + the already-consolidated `committed` + structural `children` deliberately top-level (`8b59f095`; see [the goal/outcome doc](../plans/2026-06-26-001-viewnode-decomposition-goal.md)). The source-level totality guard was strengthened (whole-struct copy → compiler-complete) and generalized (every group member mirrored in the flat debug snapshot, 25 members); it even surfaced and closed a pre-existing mirror gap (`nextTaskModifierOrdinal`). **Remaining #10:** extracting `ViewGraph`'s *method* clusters (`GraphCheckpointStore`/`InvalidationPlanner`/…) — a supervised pass, since `recordCheckpointGraphMutation` is a ~27-site cross-cut (the clean first slice carves the snapshot/restore path and defers the mutation tracker).
  - **#11 (`HostFrameProjection` DTO): ✅ done.** The earlier "genuinely #4-gated" classification was *wrong for the fragility fix*, and implementation confirmed it: a `package struct HostFrameProjection` (`Sources/SwiftTUIRuntime/Terminal/HostFrameProjection.swift`) is now the **single seam** both host encoders read a `SemanticHostFrame` through. It surfaces the host-serialized surface explicitly — the three `SemanticSnapshot` fields hosts emit (`accessibilityNodes`/`accessibilityAnnouncements`/`scrollRoutes`) as named accessors plus a once-derived `focusPresentation` — and carries the full `semantics` snapshot so the snapshot-threaded WASI delta-encoder passes it through unchanged. Both `AndroidHostFrameEncoder` and `WebSurfaceFrameEncoder` build from the projection rather than reaching into the frame independently; serialization is untouched, so the wire bytes stay **byte-identical** (`AndroidHostFrameEncoderTests` + `WebSurfacePackageTests`/`WebSurfaceTransportTests` green, plus a new `HostFrameProjectionContractTests` locking the seam's faithfulness). It needed **neither #4 nor cross-repo coordination** — both encoders are targets in the one root package, so `package` access spans them. The `@_spi(Runners)` / #4 gate applies **only** to the *optional later* step of exposing the DTO publicly.

### Gating correction (2026-06-26)

The original sequencing claimed **"#4 must precede all of Wave C."** An access-control audit (33-agent assess + adversarial refutation, both high-confidence) found this **wrong for three of the four** — the decisive test is the access level of the *split target itself*, not of the IR it transitively touches:

| # | Split target | Access | Gated on #4? | Why |
|--:|--------------|:------:|:------------:|-----|
| 9 | `AnimationController` | `package final class` | **No** | A `package` type can't appear in any `public`/`@_spi` signature; the split is module-internal. |
| 10 | `ViewGraph` / `ViewNode` | `package final class` | **No** | They *hold* the public IR (`ResolvedNode`/`PlacedNode`) but don't redefine it — those are #4's own targets, not the holders being split. Decomposing the holders changes no public signature. |
| 11 | WASI + Android frame encoders | `package` (WASI) / `public` (Android) | **No** (fix) · behind #4 only for *optional public exposure* | **Corrected post-verification (2026-06-26):** a `package` `HostFrameProjection` DTO serialized by both encoders keeps the wire JSON byte-identical, so the fragility fix needs neither #4 nor web/Android lockstep (the existing encoder test suites guard it). The original "defer behind #4" conflated the fix with the *optional later* step of exposing the DTO publicly on the `@_spi(Runners)` boundary — only that step is #4-adjacent. |
| 12 | RunLoop pointer fields | `public` class, all fields `package` | **No (done)** | Adversarial refutation *failed*: no public exposure path exists. |

Net: **#9, #10, #12 — and #11's fragility fix — can all land before #4.** (The original "#11 is genuinely gated" was found wrong on post-implementation verification: the `package`-DTO fix preserves the wire bytes, so only the *optional* public exposure of the DTO is #4-adjacent.) #4 remains worth doing as #10/#11's *public-surface* first step for *cleanliness*, but it is a hard blocker for **none** of #9/#10/#11-fix/#12.

Four implementation notes worth recording:
- **#3 changed approach under the type system.** The proposal's first-choice fix (Mutex the cache) is *infeasible*: `LayoutProxyBox`'s `Any` caches are MainActor-isolated non-Sendable values, so a `Mutex` would require a `nonisolated(unsafe)`/`@unchecked Sendable` that the repo's own `structured-concurrency-escape-hatches` hook bans. Shipped the *second* first-step instead — a deterministic `MainActor.preconditionIsolated` trap — which keeps the cache correctly isolated and converts a silent corruption into an attributable crash.
- **#2 earned its keep immediately.** The generative harness surfaced a latent two-sibling assumption hardcoded in the shared comparator that every fixed-shape test had masked; generalized and fixed in the same commit.
- **#15 was not a framework wall.** The survey inherited the gap register's framing that autonomous `.task`/`refresh()` wakes are structurally unobservable. Reading HEAD showed the wake path is fully wired and already green on the keyboard (`InputReading`) path; the only real limit is that the loop exits when the input stream finishes — which a keep-open reader defeats. The new test proves the same capability on the terminal-input path and **passes** (it is *not* a `withKnownIssue`). The test-sync ratchet also corrected an over-engineered watchdog: per-test sleeps are banned in favor of the direct `MainActorConditionSignal`, so the final test matches the proven idiom. The harness was then **extracted to `SwiftTUITestSupport`** as a `package`-scoped, dual-path (`InputReading` + `TerminalInputReading`) shared type — the feared API change turned out to be a single internal→`package` promotion (`TerminalPresentationMetrics.fullRepaint`), not the `@_spi`-public surface expansion the deferral anticipated, because `package import` keeps the runtime types out of the public test-support API while still permitting the public-protocol conformances. It now backs both the keyboard and terminal autonomous-wake tests, deleting ~95 lines of duplicated doubles.
- **#4 was attempted twice and re-estimated M → XL — it is a public-API redesign, not a retag.** A bulk `public → package` retag of the pipeline-internal `SwiftTUICore` subdirs was driven against the compiler across **~14 build configurations**, converging the in-`SwiftTUICore` cascade from 705 → 16 errors by classifying the genuinely consumer/host-facing types and keeping them public (the `Animation` `Animatable*` family, `Draw`'s `TextStyle`/payloads exposed by the `@_spi` `DrawPayload`, `Raster`'s `RasterSurface`, `Pipeline`'s `FrameScheduler`/`Invalidating` that `RunLoop` requires, `EnvironmentSnapshot`, and the `@_spi` host surface). **The decisive finding:** once `SwiftTUICore` itself emits cleanly, the build reveals **~701 errors across 17 files of the *public Views authoring surface*** — `ViewPrimitives`, the lifecycle/metadata/layout **modifiers**, **gestures**, **focus** (`FocusedValue`), `ResolveContext`, `TabViewStyles`. So the survey's "no external consumer needs the IR" and "M / mechanical" were both wrong: the pipeline IR is woven into the *consumer-facing View API* that users call, and reducing it would **break user code**. (The earlier "cascade contained to Core" reading was an artifact of Core's emit-failure masking this downstream cascade.) Doing #4 correctly is a deliberate **public-API design pass** over the View authoring surface — multi-day, consumer-breaking, and only de-risks the deferred Wave C — so it is held, not rushed. **Reverted clean (build green); no partial boundary shipped.** The decision and the redesign are scoped as their own proposal: [`2026-06-26-002-pipeline-ir-encapsulation`](2026-06-26-002-pipeline-ir-encapsulation-proposal.md). **Resolved 2026-06-26: #4 is formally shelved** — Option A is deferred indefinitely (the IR stays public ABI, an accepted pre-1.0 trade-off), to be revisited only if a curated public IR surface becomes a product goal. It blocks none of the remaining Wave C work (#9/#10 split `package` targets; #11 shipped wire-preserving).

## The two CRITICAL findings (motivating #3)

- **C1 — Off-main layout offload races MainActor state.** `LayoutProxyBox.cachedStates` (`CustomLayoutErasure.swift:289`) is an unsynchronized dictionary mutated from `nonisolated` methods inside `MainActor.assumeIsolated { … }`; the layout pass can run off-main, guarded only by a hand-maintained, ~5×-duplicated `canOffloadLayout` walk. A single missed edge → `assumeIsolated` UB + a torn write — the plausible mechanism for the unidentified, TSan-invisible SIGSEGV flake #1.
- **C2 — Flake #1 is a standing misattribution hazard.** Because its mechanism is "unidentified," real regressions get waved off as "the known flake." Fixing C1 converts potential memory corruption into at-worst wrong cache reuse and gives the flake a reproducible signature.

## Ranked opportunities

| # | Opportunity | Impact | Effort | Risk | Status |
|--:|-------------|:------:|:------:|:----:|--------|
| 1 | Promote reconciliation oracles to run where release bugs ship: sampled-release + always-on-in-test | 🟣 transformational | L | low | ✅ done · `ecac539b` |
| 2 | Build a generative property-based reconciliation harness asserting skip == recompute across all 15 registries | 🟣 transformational | L | low | ✅ done · `4edc96b9` |
| 3 | Close the off-main layout-offload escape hatch behind the SIGSEGV flake #1 | 🔴 high | M | medium | ✅ done · `78417f02` |
| 4 | Retag the seven-phase pipeline IR from public to package before any god-object refactor | 🔴 high | ~~M~~ **XL** | ~~low~~ **med** | 🗄️ **shelved (2026-06-26)** — re-estimated XL public-API redesign; gates nothing (see [proposal 002](2026-06-26-002-pipeline-ir-encapsulation-proposal.md#decision-2026-06-26)) |
| 5 | Add a root org-gate CI workflow plus a WASI/Android cross-compile gate | 🔴 high | S | low | ✅ done · `68a7d2c` (org) |
| 6 | Introduce a single FeatureFlags registry to kill the env-flag getenv sprawl | 🟡 medium | M | low | ✅ done · `e494595c` |
| 7 | Generalize the checkpoint-totality test pattern to the other parallel-field-mirror families | 🟡 medium | M | low | ✅ done · `6ec5be68` |
| 8 | Fix the VT220 CSI parser bug that both dismisses modals and corrupts text on Delete/PageUp | 🟡 medium | S | low | ✅ done · `52653c5f` |
| 9 | Decompose AnimationController and extract a CompletionLedger with a reusable carry-forward primitive | 🔴 high | L | medium | ✅ done · `ConcurrentRegistrationCarry.swift` + `CompletionLedger` (`029324e8`) |
| 10 | Decompose ViewGraph along its existing method-cluster seams and group ViewNode fields into aggregates | 🔴 high | XL | medium | ✅ substantially done — fields grouped (`ViewGraph` 9 + `ViewNode` 4, `8b59f095`); methods already clustered across ~13 extension files; pure-read operators extracted: **`GraphCheckpointStore`** (`75e5fd17`) + **`GraphNodeIndexQuery`** (`2c5bc1de`). The named deferral (the `recordCheckpointGraphMutation` mutation-tracker) was investigated and **declined as not-worth-doing**: the epoch lives in `frameCommit`, is read off the `Checkpoint` by the delta-shadow, and resets on restore, so relocating it is behavior-affecting with no structural payoff (a 2-line bump + 40 call sites stay either way). Remaining mutation-heavy clusters are correctly left as extension methods (the private-state/write coupling makes stateless extraction net-negative). |
| 11 | Unify cross-host frame serialization behind a single HostFrameProjection DTO | 🟡 medium | L | medium | ✅ done · `HostFrameProjection.swift` (swift-tui) |
| 12 | Extract a PointerInteractionState machine out of the RunLoop god class | 🟡 medium | M | medium | ✅ done · `PointerInteractionState.swift` (swift-tui) |
| 13 | Add an executable cross-repo version-coherence gate to release_candidate | 🟡 medium | M | low | ✅ done · `7987f7d` (org) |
| 14 | Bound the unbounded image caches and fix the per-host metric-registration leak | 🟡 medium | M | low | ✅ done · `883223a2` |
| 15 | Add an autonomous-wake test harness and extract the shared input harness to Tests/Support | 🟡 medium | L | low | ✅ done · `5daf33bc`+`e2f3b8ed`+`97efe443` |

**Effort:** S < 1 day · M ~ days · L ~ 1–2 weeks · XL > 2 weeks. **Status:** commits are on branch `wave-a-hardening` (`(org)` = org root; the rest are in the `swift-tui` submodule), all local/unpushed.

## Sequencing

### Wave A — Make the bug class visible & stop the corruption

- **#3 Close the off-main layout-offload escape hatch behind the SIGSEGV flake #1** — 🔴 high · M · risk medium
- **#1 Promote reconciliation oracles to run where release bugs ship: sampled-release + always-on-in-test** — 🟣 transformational · L · risk low
- **#2 Build a generative property-based reconciliation harness asserting skip == recompute across all 15 registries** — 🟣 transformational · L · risk low
- **#5 Add a root org-gate CI workflow plus a WASI/Android cross-compile gate** — 🔴 high · S · risk low
- **#8 Fix the VT220 CSI parser bug that both dismisses modals and corrupts text on Delete/PageUp** — 🟡 medium · S · risk low

### Wave B — Pay down debt that de-risks the big refactors

- **#4 Retag the seven-phase pipeline IR from public to package before any god-object refactor** — 🔴 high · M · risk low
- **#6 Introduce a single FeatureFlags registry to kill the env-flag getenv sprawl** — 🟡 medium · M · risk low
- **#7 Generalize the checkpoint-totality test pattern to the other parallel-field-mirror families** — 🟡 medium · M · risk low
- **#13 Add an executable cross-repo version-coherence gate to release_candidate** — 🟡 medium · M · risk low
- **#14 Bound the unbounded image caches and fix the per-host metric-registration leak** — 🟡 medium · M · risk low
- **#15 Add an autonomous-wake test harness and extract the shared input harness to Tests/Support** — 🟡 medium · L · risk low

### Wave C — The structural bets (their fixes are *not* gated on #4 — see the gating correction)

- **#9 Decompose AnimationController and extract a CompletionLedger with a reusable carry-forward primitive** — 🔴 high · L · risk medium
- **#10 Decompose ViewGraph along its existing method-cluster seams and group ViewNode fields into aggregates** — 🔴 high · XL · risk medium
- **#11 Unify cross-host frame serialization behind a single HostFrameProjection DTO** — 🟡 medium · L · risk medium
- **#12 Extract a PointerInteractionState machine out of the RunLoop god class** — 🟡 medium · M · risk medium

Rationale for the order: Wave A closes the only memory-corruption path (#3) and makes the dominant bug class CI-visible (#1+#2 are paired — the oracles need the generator's inputs to actually hit the seams), with two cheap parallel wins (#5, #8). Wave B is low-risk, mechanical debt paydown. The original claim that **#4 must precede all of Wave C** turned out to be wrong (see the [gating correction](#gating-correction-2026-06-26)): #9/#10/#12 split `package` targets and are non-breaking regardless of #4, and **#11's fragility fix is likewise non-breaking** — a `package` `HostFrameProjection` DTO keeps the wire bytes identical, so only the *optional* public exposure of that DTO is #4-adjacent. #12 landed first as the best-scoped, highest-incidence, behavior-preserving entry; #4 is still worth doing as #10/#11's *public-surface* first step for a clean public surface.

## Opportunity detail

### #1 — Promote reconciliation oracles to run where release bugs ship: sampled-release + always-on-in-test

**Impact:** 🟣 transformational · **Effort:** L · **Risk:** low

**Why.** This is the single highest-leverage move because it converts the dominant bug class from 'caught by humans in the gallery, back-filled one test at a time' into 'caught at the seam by an executable contract.' The oracles already exist (assertResolvedStampsCoherent, verifySoundDamage, the memo shadow oracle, the delta-checkpoint oracle) but are #if DEBUG/env-only, so they are absent in exactly the release configuration where stamp-skip crashes, handler strands, and elision storms actually manifest. Reusing existing machinery means low implementation risk for outsized fragility removal across the entire reconciliation engine.

**First step.** Add a single env-gated ReconciliationSoundnessProbe type that invokes the four existing oracles on a sampled fraction of frames (default-off in release, enabled in a CI soak lane) and unsampled/always-on under tests; wire the stamp-coherence and delta-checkpoint checks through it first since they are already written.

**Affected areas.** SwiftTUICore/Resolve (ViewNode, ViewGraph, ViewGraphFrameDraft); SwiftTUICore/Raster (Rasterizer verifySoundDamage); SwiftTUIViews/Foundation (memo shadow oracle); SwiftTUICore/Pipeline (OffscreenFrameElision)

### #2 — Build a generative property-based reconciliation harness asserting skip == recompute across all 15 registries

**Impact:** 🟣 transformational · **Effort:** L · **Risk:** low

**Why.** The example-based tests cannot enumerate the splice/portal/lazy-tab/sheet product space that violates fast-path completeness, and the byte-identity scoped-vs-full oracle covers only 2 of 15 registries — precisely the gap where strands hid. A generator that randomly composes seam-inducing constructs and asserts four universal properties (scoped restore == full rebuild across all registries; stamp coherence; elided frame == zero visible delta; retained/memo skip == fresh recompute) turns whole-class coverage from points into space. Pairs directly with opportunity 1 to give those oracles inputs that actually hit the seams.

**First step.** Write a view-tree generator emitting random compositions of ForEach/Group splices, toolbars, portals, lazy TabView bodies, and sheets; start by extending RuntimeRegistrationRestoreScopingTests to compare full-rebuild vs scoped restore across all 15 registry snapshots instead of just defaultFocus+focusBinding.

**Affected areas.** SwiftTUICore tests; SwiftTUICore/Runtime (15 Local*Registry); SwiftTUICore/Resolve reconciliation; SwiftTUIViews seam constructs (TabView, portals, sheets)

### #3 — Close the off-main layout-offload escape hatch behind the SIGSEGV flake #1

**Impact:** 🔴 high · **Effort:** M · **Risk:** medium

**Why.** Flake #1 is the only CRITICAL finding: a sanitizer-invisible memory-corruption crash whose mechanism is officially unidentified, with a standing misattribution hazard (real regressions waved off as 'the known flake'). The corpus identifies the plausible structural mechanism: off-main layout offload bridges to LayoutProxyBox's unsynchronized cachedStates dictionary via MainActor.assumeIsolated, sound only if a hand-maintained, 5x-duplicated tree walk perfectly classifies what may run off-main. Making the cache genuinely Sendable (Mutex, matching the sibling SendableLayoutWorkerProxy) makes even an erroneous offload memory-safe — converting potential corruption into at-worst wrong cache reuse. High impact, contained change, removes a critical risk.

**First step.** Move LayoutProxyBox.cachedStates behind the same Mutex pattern already used by SendableLayoutWorkerProxy so a mis-offloaded run cannot corrupt memory; then replace the worker-reachable MainActor.assumeIsolated calls with an explicit executor check that deterministically fatalErrors off-main to give the flake a reproducible signature.

**Affected areas.** SwiftTUIViews/Layout (CustomLayoutErasure LayoutProxyBox); SwiftTUIRuntime/Rendering (FrameTailLayoutWorker, FrameTailLayoutOffloadEligibility); docs/KNOWN-TEST-FLAKES.md #1

### #4 — Retag the seven-phase pipeline IR from public to package before any god-object refactor

**Impact:** 🔴 high · **Effort:** M · **Risk:** low

**Why.** ~124 public engine-internal IR types (ResolvedNode, MeasuredNode, PlacedNode, CommitPlan, RasterSurface) freeze the engine's internal representation as the library's stable ABI, even though the only extension point that would need them public (custom PrimitiveViews) is itself package and no host references them. This is a quick, mechanical, high-confidence change that is a prerequisite for safely performing every other structural refactor (ViewGraph, AnimationController, Rasterizer) — doing it first makes those decompositions non-breaking. Pure leverage: small effort unlocks large later moves.

**First step.** Run the public-surface policy check to confirm no external consumer references the IR, then retag the pipeline-internal subdirs from public to package, keeping public only for genuine authoring/consumer surface (Styling/Color, Geometry, Content/fonts); expose any host-needed product through @_spi(Runners).

**Affected areas.** SwiftTUICore/{Resolve,Measure,Place,Commit,Raster,Draw,Semantics,Pipeline,Animation}; public API surface / library ABI; host SPI seam

### #5 — Add a root org-gate CI workflow plus a WASI/Android cross-compile gate

**Impact:** 🔴 high · **Effort:** S · **Risk:** low

**Why.** Two cheap structural blind spots compound: the coordination root has zero remote CI (org integrity rests on an operator remembering to run Bazel locally), and the single-host gate never compiles wasm32-wasi/Android, so WASI-only breaks ship green and only surface post-tag (documented at 0.0.19 and 0.0.26). org_fast is toolchain-free and runs nowhere automatically; a compile-only cross gate catches the entire recurring green-ship-WASI-break class. Both are near-zero-cost, high-confidence wins that close repeating production failures.

**First step.** Add .github/workflows/org-gate.yml running `mise run org-fast` on push/PR to root main, and a separate CI step that runs `swift build --swift-sdk ...wasm32-unknown-wasi` (and the Android target build) so the WASILibc/Android branches are type-checked before any tag.

**Affected areas.** org coordination root (.github/workflows); Platforms/WASI, Platforms/Android; release pipeline / native gates

### #6 — Introduce a single FeatureFlags registry to kill the env-flag getenv sprawl

**Impact:** 🟡 medium · **Effort:** M · **Risk:** low

**Why.** 34 SWIFTTUI_* flags with environmentValue/environmentDefault boilerplate copy-pasted across ~11 files, none routed through the testable EnvironmentResolver — so flag state is untestable except by mutating globals and a parsing fix must be applied 11 times. One injected registry collapses the duplication, makes flags injectable in tests, centralizes the WASI compile-out (the same seam that broke twice), and yields the first enumerable list of every flag, which becomes the forcing function for flag retirement. Quick high-leverage win that also de-risks opportunity 5.

**First step.** Create one FeatureFlags struct populated once from EnvironmentResolver's already-parsed [String:String], replace the 11 duplicated environmentValue/environmentDefault helpers with stored Bools injected at RunLoop init, and migrate the four default-on perf gates first.

**Affected areas.** SwiftTUICore/Resolve perf-gate configs; SwiftTUICore trace sinks; SwiftTUIRuntime/Configuration (EnvironmentResolver); WASI compile-out boundary

### #7 — Generalize the checkpoint-totality test pattern to the other parallel-field-mirror families

**Impact:** 🟡 medium · **Effort:** M · **Risk:** low

**Why.** The ViewNode Checkpoint already has a source-level totality guard (ViewGraphCheckpointTotalityTests), but the other hand-mirrored families have none: PlacedNode's 4 placement mirrors, the 15-registry fan-out across ~8 sites, ResolveContext's hand-picked ==. These silent-drift landmines are the direct downstream tax of the god objects and produce stale-reuse/dropped-handler bugs invisible to the compiler. Cloning an existing proven reflection-based guard to each family is low-effort, low-risk, and converts a recurring silent class into build/test failures.

**First step.** Add a totality test that fails when PlacedNode.==, placementEquivalence, PlacedNodeResolvedMetadata, and translatedPlacement field sets diverge; then add one asserting every RuntimeRegistrationSet member appears in resetAll/removeSubtrees/restore/frameDropEligibilityBlockers.

**Affected areas.** SwiftTUICore/Place (PlacedNode equivalence/translatedPlacement); SwiftTUICore/Runtime (RuntimeRegistrationSet fan-out); SwiftTUIViews/Environment (ResolveContext ==); test suite

### #8 — Fix the VT220 CSI parser bug that both dismisses modals and corrupts text on Delete/PageUp

**Impact:** 🟡 medium · **Effort:** S · **Risk:** low

**Why.** This is the rare active correctness bug rather than a structural risk: parseEscapeSequence assumes every unrecognized ESC[ sequence is 3 bytes, so 4-byte tilde-terminated VT220 keys (Delete, PageUp/Down, Insert, Home/End) emit a spurious Escape (which can close the user's modal or pop navigation) AND leave a literal '~' that gets inserted into a focused TextField. A single keypress both closes a sheet and corrupts text. Small, well-localized, high-confidence fix with direct user-facing impact.

**First step.** Before the single-letter CSI switch, scan from index 2 for a 0x7E terminator, consume the whole ESC[...~ envelope, and map the numeric parameter to the missing KeyEvent cases (or at minimum drop the sequence rather than emitting a modal-dismissing Escape plus a stray tilde).

**Affected areas.** SwiftTUIRuntime/Input (TerminalInputParser); SwiftTUIRuntime/RunLoop event dispatch; KeyEvent surface

### #9 — Decompose AnimationController and extract a CompletionLedger with a reusable carry-forward primitive

**Impact:** 🔴 high · **Effort:** L · **Risk:** medium

**Why.** AnimationController is the documented epicenter of orphaned-completion/elision-storm bugs: 1627 LOC, two ~250-290 line monolith methods, a process-global weak-singleton sink fallback the project's own CLAUDE.md warns against, and a hand-written publishCommittedState diff that carries forward only 2 of its mutable maps across the frame boundary (any new concurrently-written field silently orphans a completion and stalls the loop). Extracting a CompletionLedger with a reusable 'concurrent mutations survive checkpoint restore' primitive converts a per-bug bespoke fix into a structural guarantee, and the three divergent keepalive predicates collapse into one AnimationWorkSummary.

**First step.** Move the four top-level mutable maps into a fifth CoreAnimationState substruct so checkpoint/restore/reset become whole-struct copies (closing the totality gap), then extract a carry-forward helper (live-minus-baseline delta, restore, re-apply) and route every concurrently-writable map through it with a test that registers a completion mid-flight and asserts it survives publish.

**Affected areas.** SwiftTUIRuntime/Lifecycle (AnimationController, AnimationContextStorage); SwiftTUIRuntime/RunLoop (PostCommit keepalive); async withAnimation/PhaseAnimator completion path

### #10 — Decompose ViewGraph along its existing method-cluster seams and group ViewNode fields into aggregates

**Impact:** 🔴 high · **Effort:** XL · **Risk:** medium

**Why.** ViewGraph (2501 LOC / 111 funcs) and ViewNode (1412 LOC, ~40 fields mirrored 4x) are the most central and most bug-prone files; every reconciliation invariant lives in shared mutable state with maximal blast radius. Decomposition has already started (field groups + 15 extension files) but stalled at the core. Splitting into ViewGraphIndex / InvalidationPlanner / ReusePolicy / GraphCheckpointStore / RegistrationRestorer makes each invariant independently testable, and grouping ViewNode fields into sub-structs collapses three of the four hand-mirror lists structurally. This is a larger structural bet — gated on opportunity 4 to be non-breaking — but it is the foundation the whole engine's maintainability rests on.

**First step.** After the IR retag (opp 4), extract GraphCheckpointStore (makeCheckpoint/restore + debugTotalStateSnapshot) and group ViewNode's ~40 fields into a handful of value-typed sub-structs (IdentityState, ReuseFlags, DependencyEdges, SlotStore) so checkpoint becomes whole-struct copies, eliminating the per-field mirroring.

**Affected areas.** SwiftTUICore/Resolve (ViewGraph, ViewNode, ViewGraphFrameDraft); reconciliation invariants (checkpoint totality, stamp coherence, reuse); frame pipeline

### #11 — Unify cross-host frame serialization behind a single HostFrameProjection DTO

**Impact:** 🟡 medium · **Effort:** L · **Risk:** medium

**Why.** The same SemanticHostFrame is serialized by two unrelated ~570-line encoders (WASI hand-rolled JSON vs Android Codable) — ~1150 lines of parallel logic where any new cell attribute, a11y field, or image kind must be implemented twice and a forgotten field silently drops data on one host with no compile error. This is the single largest maintenance liability in the platform layer and is baked into the over-flat @_spi(Runners) boundary. A shared DTO makes the struct definitions the totality check; adding a field forces both serializers to handle it.

**First step.** Define one host-agnostic HostFrameProjection (cells, styles, a11y tree, scroll regions, image attachments, focus presentation) built once from SemanticHostFrame, then reduce each encoder to a thin serializer (hand-rolled JSON for WASI, Codable for Android) over the same struct graph; keep WASI delta-encoding as a wrapper over the shared DTO diff.

**Affected areas.** Platforms/WASI (WebSurfaceFrameEncoder); Platforms/Android (AndroidHostFrameEncoder); SwiftTUIRuntime host SPI (SemanticHostFrame)

### #12 — Extract a PointerInteractionState machine out of the RunLoop god class

**Impact:** 🟡 medium · **Effort:** M · **Risk:** medium

**Why.** RunLoop is a 68-field god class shattered across 30 files where any extension can mutate any field — the file split gives no encapsulation. The pointer interaction state (7 loosely-coupled fields reset ad-hoc across six handlers) is the exact shape of the recurring gallery drag/scroll regressions: a missed reset on any path leaves a stale armed/captured route that mis-routes the next gesture. Extracting a value type that owns the seven fields and exposes intent-named transitions converts implicit shared-mutable coupling into an enforced state machine — a bounded first step into the larger RunLoop decomposition that targets the highest-incident area.

**First step.** Create a PointerInteractionState struct owning armedPointerRouteID, capturedPointerRouteID, hoveredPointerRouteID, pressedIdentity, transientPressedIdentity, dragStartLocation, and armedPointerRouteUsesPointerHandler, with methods (pressBegan, armed, captured, released, regionVanished) that reset the full tuple coherently; have RunLoop hold one and call transitions instead of mutating fields directly.

**Affected areas.** SwiftTUIRuntime/RunLoop (PointerHandling, FocusSync, ScrollGestureTakeover); input/gesture routing; focus-sync state

### #13 — Add an executable cross-repo version-coherence gate to release_candidate

**Impact:** 🟡 medium · **Effort:** M · **Risk:** low

**Why.** The org's entire reason to exist is preventing the version-skew class (the 0.0.8 breakage), yet nothing in the gate graph asserts the six lockstep repos agree on a version — release_pin_contract only checks origin/main reachability, so version-skewed drifted HEADs pass every gate. The only defense is a human walking the 7-step runbook. A version_coherence.sh contract reading the canonical version and asserting each repo resolves to it converts the manual checklist into an automated attestation. Modest effort, removes a whole silent-failure class from releases.

**First step.** Write version_coherence.sh that reads current.swiftTUI from swift-tui-site/docs/releases.yml as canonical, asserts each lockstep repo's authored version site equals it (reusing bump_version.sh's authored-string set), and wire it into //:release_candidate (not org_fast, since pre-release drift is expected).

**Affected areas.** org coordination root (tools/bazel, release_candidate); release pipeline; tools/registry/repos.json

### #14 — Bound the unbounded image caches and fix the per-host metric-registration leak

**Impact:** 🟡 medium · **Effort:** M · **Risk:** low

**Why.** Two process/session-lived image caches grow without limit (ImageAssetRepository.decodedImages and TerminalImageRenderer's kitty/sixel/fallback payloads), unlike their sibling ImageBlendCompositor which already implements LRU+budget eviction — a long session viewing many images grows unbounded and leaks across tests sharing the singleton. Separately, TerminalImageRenderer registers a permanent (never-removable) metric per instance, so providerCount (the documented leak signal) climbs per host and poisons the metric meant to detect leaks. Both are mechanical fixes reusing an eviction/token pattern that already exists in the same module.

**First step.** Apply ImageBlendCompositor.Storage.evictIfNeeded's LRU+budget shape to ImageAssetRepository.Storage.decodedImages and TerminalImageRenderer.Storage, and switch TerminalImageRenderer from registerPermanent to the token-based register, storing the Token so deinit deregisters.

**Affected areas.** SwiftTUIRuntime/Terminal (ImageAssetRepository, TerminalImageRendering); memory metric registry; long-session / test memory

### #15 — Add an autonomous-wake test harness and extract the shared input harness to Tests/Support

**Impact:** 🟡 medium · **Effort:** L · **Risk:** low

**Why.** The scripted-input RunLoop terminates with the input stream, so autonomous .task/refresh() wake-ups — the class behind PhaseAnimator stalls, TimelineView busy-spin, and dropped .task regressions — are structurally unobservable by the dominant harness; tests pass while autonomous wakes are broken. The shared harness and 8 input-reader doubles are also trapped inside the 6382-line InteractiveRuntimeTests, forcing copy-paste. Extracting the harness to Tests/Support unblocks the autonomous-wake variant and removes a god-test-file drift source, directly closing a coverage gap on a repeatedly-bug-prone area.

**First step.** Move runTerminalInputHarness and the ScriptedTerminalInputReader family into Tests/Support as @_spi(Testing) infrastructure, then add a harness variant whose input stream stays open (closed only by an app-driven quit signal, bounded by StageClock) so an autonomous refresh() produces an observable extra frame.

**Affected areas.** Tests/SwiftTUITests (InteractiveRuntimeTests harness); Tests/Support; SwiftTUIRuntime/RunLoop autonomous .task path

## Notes

- This is a **proposal**, not a commitment; nothing here is implemented. Each Wave-A/B item is small enough to land as its own PR with a test.
- The ranking is leverage-based, not severity-based: e.g. decomposing `ViewGraph` (#10) is high-impact but XL-effort/medium-risk and removes no shipped bug *by itself*, so it sits below the low-risk oracle/test changes that change the slope of the curve.
- Full per-subsystem evidence, the 4 cross-cutting lens assessments, and the verification log are in the [survey report](../reports/2026-06-26-architecture-fragility-survey.md).
