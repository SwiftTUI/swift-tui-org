# H2/H3 Resolve-Reuse Correctness (Complete Fix) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `ViewNode` retained reuse fire on every invalidation frame (so resolve cost scales with what changed, not total tree size) *without* breaking focus propagation or active-animation tracking.

**Architecture:** The one-line enabler — `canReuse` comparing transaction *intent* (`isReuseEquivalent`) instead of full `==` — is correct but exposes two pre-existing gaps the always-recompute behavior masked: (1) `focusedIdentity` is not part of the `EnvironmentSnapshot` equality that gates reuse, and (2) the reuse path does not keep the `AnimationController`'s active animations alive for reused subtrees. This plan re-enables reuse, then closes those gaps, using the three tests that fail under reuse as acceptance criteria, with the full repo gate as an audit for any further reuse-sensitive subsystem.

**Tech Stack:** Swift 6.3, Swift Testing (`import Testing`, `@Test`, `#expect`), SwiftPM. Work happens inside the `swift-tui` submodule on branch `perf/h2-resolve-reuse-complete`. Build/test via `swiftly run swift ...`; full gate via `bun run test`.

> **STATUS (2026-05-30, UPDATED) — SCOPED-REUSE FIX DONE & COMMITTED (`da38a946`). Focus regression + caret-scroll fixed; H2 win preserved. The animation/elision "gap" was a phantom (pre-existing load-flaky test). Tasks 2–4 below SUPERSEDED; only Task 5 follow-on remains.**
> - **Task 1 DONE** — `9e655f80` (enabler + scenario). Kept.
> - **`b212ff65` was RESET AWAY** (env-equality focus pollution — wrong layer; violated `EnvironmentRuntimeStateTests` "focus/press don't affect env equality").
> - **CORRECTION to the plan's premise:** `forceRootEvaluation()` does NOT disable retained reuse (proven by runtime instrumentation). It only forces the walk to *reach* every node; each reached node still independently takes the reuse fast path in `resolveView`→`reusableSnapshot` (gated by invalidation-disjointness). A full no-reuse frame needs BOTH forceRootEvaluation AND a new `suppressRetainedReuse` flag.
> - **IMPLEMENTED (`da38a946`):** new frame-scoped `suppressRetainedReuse` flag (`RunLoop → frameState → FrameResolveInputs → ResolveContext.effectiveSuppressesRetainedReuse → resolveView`), set alongside `forceRootEvaluation` on reuse-unsafe frames (focus moved since previous committed frame, or `activeAnimationCount > 0 || lastTickResult.hasPendingWork`), in BOTH sync and async render paths. **Scoped to that gate ONLY** — focus-sync rerenders keep reuse so the caret-scroll two-pass survives (coupling suppress to the rerender condition broke `textEditorRuntimeScrollsToKeepCaretVisible`; decoupled).
> - **MAJOR CORRECTION — animation/elision was a phantom gap.** `OffscreenFrameElisionRuntimeTests` "off-screen deadline tick elides…" is **PRE-EXISTING load-flaky**, NOT a reuse regression: it fails under full-gate parallel load on **main `3aaa8282` (zero reuse) — 3/3 runs**, on enabler-only, and with the fix — same assertions (`:288`/`:315`/`:333`), passing only in isolation. It's a real-time-deadline race. The prior "enabler caused it" attribution was an isolation-vs-load artifact. Treat like the #12 SIGSEGV flake.
> - **Verification:** full `bun run test` GREEN except that one pre-existing flaky test; focus tests + caret-scroll deterministically green; H2 win confirmed (~54/67 reused, resolve_ms ~1.5).
> - **Remaining (Task 5):** disjoint-sibling regression test, release measurement, findings report, then push + PR + org pin bump (needs explicit OK). Optional separate follow-up: harden the flaky elision test (controlled clock).

---

## Context: confirmed root causes (do not re-investigate from scratch)

**The enabler.** `Sources/SwiftTUICore/Resolve/ViewNode.swift` `canReuse` gates retained reuse on `committed.transactionSnapshot == transaction`. The run loop sets `TransactionSnapshot(debugSignature: causeSummary)` (`Sources/SwiftTUIRuntime/RunLoop/RunLoop+ResolveContext.swift:49`), where `causeSummary` is the frame's cause set (`"invalidation"`, `"input+invalidation"`, …) — different almost every frame. So `==` rejects every node → the whole tree re-resolves on every invalidation frame. `TransactionSnapshot.isReuseEquivalent(to:)` already exists (compares `animationRequest` + `animationBatchID`, ignores `debugSignature`) but is unused. Switching `canReuse` to it makes reuse fire (measured on `synthetic-narrow-invalidation`: steady-state `resolved_reused` 0→54, `resolve_ms` ~3.3→~1.8 on a 67-node tree).

**Gap 1 — Focus (2 failing tests in `Tests/SwiftTUITests/AppRuntimeTests.swift`).** `EnvironmentSnapshot` equality compares only `debugSignature`, `values: [String:String]`, and `style` (`Sources/SwiftTUICore/Resolve/Environment.swift:67-77`). `focusedIdentity` is a *bare field* on `EnvironmentValues` (`Sources/SwiftTUIViews/Environment/StyleEnvironment.swift` `_focusedIdentity`), **not** merged into the snapshot's `values` (`EnvironmentValues.applying(to:)`, `Sources/SwiftTUIViews/Environment/Environment.swift:90-123`). So when focus moves, `committed.environmentSnapshot == environment` stays `true`, the focus-display subtree reuses, and `EnvironmentReader(\.focusedIdentity)` (which reads `context.environmentValues[keyPath:]` directly, never re-running on reuse) shows stale focus. On focus move, `FocusTracker.notifyIfFocusChanged` invalidates only the old/new focused *controls*, not the display node (`Sources/SwiftTUICore/Semantics/FocusTracker.swift:538-554`).

**Gap 2 — Animation (1 failing test in `Tests/SwiftTUITests/OffscreenFrameElisionRuntimeTests.swift`: "off-screen deadline tick elides but reschedules").** Animations are registered during resolve via task-local sinks (`AnimationRegistrationStorage`/`TransitionRegistrationStorage`/`AnimationCompletionStorage`, `Sources/SwiftTUICore/Animation/AnimationContextStorage.swift`) into `AnimationController` (`Sources/SwiftTUIRuntime/Lifecycle/AnimationController.swift`). The reuse path (`ViewGraph.recordReusedSubtree` → `ViewNode.restoreRuntimeRegistrations`) replays *handler* registrations (`registeredHandlers: NodeHandlers`) but **not** animation registrations — the view body never runs, so a reused animating subtree's `withAnimation`/`repeatForever` is never re-registered. The controller's per-frame processing (`processResolvedTree`, `:398`) walks the resolved tree and diffs identity sets; identities that "leave the tree" are pruned (`:526`, `previousIdentities = newIdentities` at `:659`). Under reuse the off-screen `repeatForever` ends up with `activeAnimationCount == 0`. **The exact prune-vs-not-replayed mechanism is not yet pinned — Task 3 opens with a spike to settle it before choosing the fix.**

**Do NOT use the naive one-line swap alone** — it ships a focus + animation regression (including the previously-shipped H1 elision behavior). Attribution verified: reverting the swap turns all 3 tests green.

---

## File Structure

- `Sources/SwiftTUICore/Resolve/ViewNode.swift` — `canReuse` (the enabler).
- `Sources/SwiftTUICore/Resolve/Environment.swift` + `Sources/SwiftTUIViews/Environment/Environment.swift` — fold `focusedIdentity` (and other reuse-relevant bare focus fields) into `EnvironmentSnapshot` equality (Gap 1).
- `Sources/SwiftTUICore/Resolve/ViewGraph.swift` (`recordReusedSubtree`) + `Sources/SwiftTUICore/Resolve/ViewNode.swift` (`NodeHandlers`/registration capture) + `Sources/SwiftTUIRuntime/Lifecycle/AnimationController.swift` — preserve/replay active-animation state for reused subtrees (Gap 2; exact seam set by the Task 3 spike).
- `Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/SyntheticNarrowInvalidationScenario.swift` (+ `PerfRunConfig.swift`, `Scenarios/PerfScenario.swift`, `Tests/TermUIPerfTests/PerfRunConfigTests.swift`) — the committed reproduction scenario (already written; commit in Task 1).
- `Tests/SwiftTUITests/ResolveReuseAncestorInvalidationTests.swift` — re-add the disjoint-sibling reuse regression test (Task 5).

---

### Task 1: Establish the RED baseline (enabler + scenario)

**Files:**
- Modify: `Sources/SwiftTUICore/Resolve/ViewNode.swift` (`canReuse`)
- Already-present (untracked): `Tools/TermUIPerf/.../SyntheticNarrowInvalidationScenario.swift` and its wiring

- [ ] **Step 1: Apply the enabler.** In `ViewNode.canReuse`, replace the final clause `&& committed.transactionSnapshot == transaction` with:

```swift
      && committed.environmentSnapshot == environment
      // Compare resolve-time transaction *intent* (animation request + batch),
      // not the full snapshot: the per-frame `debugSignature` (the frame's cause
      // summary) otherwise changes every frame and defeats retained reuse for
      // subtrees disjoint from the invalidation. See `TransactionSnapshot.isReuseEquivalent`.
      && committed.transactionSnapshot.isReuseEquivalent(to: transaction)
```

- [ ] **Step 2: Confirm RED (the 3 known failures).**

Run: `swiftly run swift test --filter "(OffscreenFrameElisionRuntime|runtimeFocusMovementWritesBackIntoRenderedFocusIdentity|arrowKeysUseGeometryAwareTopLevelFocusTraversal)"`
Expected: FAIL — `activeAnimationCount → 0`, focus frames show `"Focus: none"`. These are the acceptance targets for Tasks 2-3.

- [ ] **Step 3: Commit the scenario + enabler.**

```bash
git add Tools/TermUIPerf Sources/SwiftTUICore/Resolve/ViewNode.swift
git commit -m "perf: enable transaction-intent reuse + add narrow-invalidation scenario (RED: focus/animation gaps)"
```

---

### Task 2: Close Gap 1 — focus participates in reuse eligibility

**Files:**
- Modify: `Sources/SwiftTUIViews/Environment/Environment.swift` (`applying(to:)`, ~`:90-123`)
- Test: `Tests/SwiftTUITests/AppRuntimeTests.swift` (existing focus tests are the acceptance criteria)

- [ ] **Step 1: Reproduce the focus failure in isolation.**

Run: `swiftly run swift test --filter "runtimeFocusMovementWritesBackIntoRenderedFocusIdentity"`
Expected: FAIL — `secondFrame` contains `"Focus: none"` instead of `"Focus: SecondFocus"`.

- [ ] **Step 2: Fold focus identity into the snapshot's compared `values`.** In `EnvironmentValues.applying(to:)`, after `var mergedValues = snapshot.values` and the existing merge, write the reuse-relevant bare focus fields into `mergedValues` under reserved keys so `EnvironmentSnapshot.==` (which compares `values`) observes focus changes:

```swift
    var mergedValues = snapshot.values
    if !snapshotValues.isEmpty {
      mergedValues.merge(snapshotValues) { _, new in new }
    }
    // Focus state lives in bare `EnvironmentValues` fields, not `snapshotValues`,
    // so it is invisible to `EnvironmentSnapshot` equality — which gates retained
    // reuse. Fold it into the compared `values` so a focus move correctly defeats
    // reuse of focus-reading subtrees (e.g. `EnvironmentReader(\.focusedIdentity)`).
    mergedValues["__reuse.focusedIdentity"] = focusedIdentity?.description ?? ""
    mergedValues["__reuse.pressedIdentity"] = pressedIdentity?.description ?? ""
```

(Confirm `pressedIdentity` is an `EnvironmentValues` member; if its type lacks `description`, use `map(String.init(describing:))`. Do NOT include `focusedValues` here unless Task 4 shows a failure that requires it — keep the change minimal.)

- [ ] **Step 3: Confirm the 2 focus tests pass.**

Run: `swiftly run swift test --filter "(runtimeFocusMovementWritesBackIntoRenderedFocusIdentity|arrowKeysUseGeometryAwareTopLevelFocusTraversal)"`
Expected: PASS.

- [ ] **Step 4: Confirm reuse still fires (no over-conservatism on non-focus frames).**

Run: `cd /Users/adamz/Developer/swift-tui-org/swift-tui && swiftly run swift run --package-path Tools/TermUIPerf termui-perf run --scenario synthetic-narrow-invalidation --modes sync --iterations 1 --artifacts-root .perf/check --configuration debug` then inspect the latest `.perf/check/*/frames.tsv`.
Expected: steady-state invalidation frames still show `resolved_reused` large (~50+) and `resolved_computed` small — the focus fix only affects focus-change frames.

- [ ] **Step 5: Commit.**

```bash
git add Sources/SwiftTUIViews/Environment/Environment.swift
git commit -m "fix: include focus identity in EnvironmentSnapshot reuse equality"
```

---

### Task 3: Close Gap 2 — reused subtrees keep their active animations

**Files:**
- Modify: `Sources/SwiftTUICore/Resolve/ViewGraph.swift` (`recordReusedSubtree`) and/or `Sources/SwiftTUIRuntime/Lifecycle/AnimationController.swift` (per-frame presence) — exact seam set by Step 1.
- Possibly: `Sources/SwiftTUICore/Resolve/ViewNode.swift` (`NodeHandlers` to capture animation registrations).
- Test: `Tests/SwiftTUITests/OffscreenFrameElisionRuntimeTests.swift` (acceptance) + the broader `AnimationTickVisibilityTests`, `AnimationRepeatForeverGrowthTests`, `AnimationControllerTests`.

- [ ] **Step 1: SPIKE — pin the `activeAnimationCount → 0` mechanism.** Read `AnimationController.processResolvedTree` (`:398`), `processNode` (snapshot accumulation), the removal path (`:526`), and `applyInterpolations` completion pruning (`~:1010-1068`). Determine which of these holds:
  - **(H-prune)** The reused animated identity is absent from `newSnapshots` (so it lands in `removedIdentities` and its animation is pruned). If so, the resolved tree passed to `processResolvedTree` (`DefaultRendererFrameHeadCoordinator.swift:399`) does NOT include reused subtrees under selective evaluation → fix is to ensure reused identities are present in that tree / `newIdentities`.
  - **(H-register)** The identity is present but the `repeatForever` is not re-enqueued/kept because the body's `withAnimation` never re-runs → fix is to capture animation registrations per node and replay them in `recordReusedSubtree` (mirroring `restoreRuntimeRegistrations`).
  Decide H-prune vs H-register with a one-off instrumentation print (budget-capped, `#if DEBUG`, reverted after) in `processResolvedTree` logging whether the off-screen border identity is in `newSnapshots`/`removedIdentities`. Write the conclusion into this task before implementing.

- [ ] **Step 2: Reproduce the animation failure in isolation.**

Run: `swiftly run swift test --filter "offscreenDeadlineTickElidesWithoutFreezingThenOnScreenRenders"`
Expected: FAIL — `internalAnimationController.activeAnimationCount → 0) > 0`.

- [ ] **Step 3: Implement the fix indicated by Step 1.**
  - If **H-prune**: make the reused subtree's identities visible to the controller's presence set so they are not pruned. The likely seam is that selective-evaluation resolve already carries reused subtrees in the committed `resolvedTree`; verify `processResolvedTree` receives the committed tree (not just the re-evaluated frontier) and, if not, pass the committed tree or merge reused identities into `previousIdentities` survival the way `finishTransitionCollection()` (`:375-384`) already preserves transitions for non-re-evaluated subtrees. Mirror that existing pattern.
  - If **H-register**: add `animationRegistrations`/`completionRegistrations` capture to `NodeHandlers` at `withAnimation`/registration time, and replay them in `recordReusedSubtree` (after `node.beginReuse`) via `AnimationRegistrationStorage.effectiveSink?.registerAnimationBox(...)` etc., exactly paralleling `restoreOwnRuntimeRegistrations`.

- [ ] **Step 4: Confirm the animation test passes AND the broader animation suite is unaffected.**

Run: `swiftly run swift test --filter "(OffscreenFrameElisionRuntime|AnimationTickVisibility|AnimationRepeatForeverGrowth|AnimationController)"`
Expected: PASS (all). Pay attention to `AnimationRepeatForeverGrowthTests` — it guards against animation-state leaks, which a replay fix could regress.

- [ ] **Step 5: Commit.**

```bash
git add -A
git commit -m "fix: preserve active animations across retained subtree reuse"
```

---

### Task 4: Audit — full gate as the discovery net for any other reuse-sensitive subsystem

**Files:** none initially — this task finds whether focus + animation were the only gaps.

- [ ] **Step 1: Run the full repo gate.**

Run: `cd /Users/adamz/Developer/swift-tui-org/swift-tui && bun run test 2>&1 | tee /tmp/h2-gate.log; echo "EXIT=${PIPESTATUS[0]}"`
Expected: ideally green. If RED, identify failures: `grep -E "recorded an issue|failed after|Result: FAIL" /tmp/h2-gate.log`.

- [ ] **Step 2: Triage each new failure.** For each, decide: (a) another reuse-correctness gap (some other bare environment field, preference, scroll position, gesture, or lifecycle state not preserved across reuse) → fix it with the same discipline (isolate the test, find the missing state, fold it into reuse eligibility or replay it on reuse, commit); or (b) the known intermittent run-loop `SIGSEGV/SIGBUS` flake (swift-tui#12) → confirm crash signature matches and re-run to confirm it is not deterministic. Do NOT mask a real regression as "the flake" without matching the signature.

- [ ] **Step 3: Loop until the gate is deterministically green** (modulo a confirmed #12 flake), committing each additional fix separately.

> If Step 2 reveals more than ~2 additional independent reuse-correctness gaps, STOP and reassess scope with the human partner (systematic-debugging Phase 4.5): the "complete fix" may warrant being split, or the scoped-reuse alternative (exclude focus/animation/dynamic subtrees from reuse) may be the better risk/reward.

---

### Task 5: Lock in the win — regression test, measurement, docs

**Files:**
- Test: `Tests/SwiftTUITests/ResolveReuseAncestorInvalidationTests.swift`
- Doc: `docs/reports/2026-05-30-h2-resolve-reuse-findings.md` (in `swift-tui-org`)

- [ ] **Step 1: Re-add the disjoint-sibling reuse regression test** (proves the enabler stays wired and reuse fires across a `debugSignature` change). Append to the suite in `ResolveReuseAncestorInvalidationTests.swift`:

```swift
  @Test("disjoint-sibling reuse survives a per-frame transaction debugSignature change")
  func disjointSiblingReuseSurvivesDebugSignatureChange() {
    let renderer = DefaultRenderer(layoutEngine: .init(cache: MeasurementCache()))
    let rootIdentity = testIdentity("DisjointReuse")
    struct TwoSiblings: View {
      var body: some View {
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: 0) { Text("A0"); Text("A1") }
          VStack(alignment: .leading, spacing: 0) { Text("B0"); Text("B1") }
        }
      }
    }
    let first = renderer.render(
      TwoSiblings(),
      context: .init(identity: rootIdentity, transaction: TransactionSnapshot(debugSignature: "frame-1")))
    let invalidatedChild = first.resolvedTree.children.first?.identity
    #expect(invalidatedChild != nil)
    let second = renderer.render(
      TwoSiblings(),
      context: .init(
        identity: rootIdentity,
        transaction: TransactionSnapshot(debugSignature: "frame-2"),
        invalidatedIdentities: invalidatedChild.map { [$0] } ?? []))
    #expect(second.diagnostics.work.resolvedNodesReused > 0)
    let rendered = second.rasterSurface.lines.joined(separator: "\n")
    #expect(rendered.contains("A0"))
    #expect(rendered.contains("B0"))
  }
```

- [ ] **Step 2: Confirm it passes.**

Run: `swiftly run swift test --filter "disjointSiblingReuseSurvivesDebugSignatureChange"`
Expected: PASS.

- [ ] **Step 3: Measure the win (release, before/after, size sweep).** Build release; run `synthetic-narrow-invalidation` with `--modes async --iterations 15` at `TERMUI_PERF_INVALIDATION_TREE_ROWS` ∈ {6, 20, 40} on the fixed branch (candidate) and on `main` (base); compare resolve_ms per invalidation frame and total CPU with `termui-perf compare`. Record median ± stddev and the scaling (resolve_ms should stay ~flat vs tree size after the fix).

- [ ] **Step 4: Write the findings report** `swift-tui-org/docs/reports/2026-05-30-h2-resolve-reuse-findings.md`: root cause (transaction `debugSignature` defeats reuse), the two correctness gaps (focus, animation) and how each was closed, the measured win + scaling, and any audit findings.

- [ ] **Step 5: Full gate + finalize.** `bun run test` green → push the `swift-tui` branch (with the human's OK), open/merge per the child-repo workflow, then bump the `swift-tui-org` submodule pin and run `bazel test //:org_fast`.

---

## Risks

- **Cascading reuse gaps (primary risk).** Focus + animation may not be the only state the always-recompute behavior masked. Task 4's full-gate audit is the net; the stop-condition guards against an unbounded effort.
- **Animation fix touches correctness-sensitive run-loop/controller code.** `AnimationRepeatForeverGrowthTests` is the leak guard; keep it green. The Task 3 spike must settle the mechanism before editing.
- **Focus fix is conservative** (focus-change frames do a full recompute). Acceptable — focus changes are user-paced; the H2 win targets rapid same-focus interaction.
- **Known flake:** swift-tui#12 (`SIGSEGV/SIGBUS` in run-loop suites) can surface during the gate; match the signature before attributing to this change.
