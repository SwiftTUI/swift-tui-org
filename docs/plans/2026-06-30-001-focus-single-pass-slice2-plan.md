# Phase 3 slice 2 — precise focused-value reader attribution, then flip the default

Date: 2026-06-30
Status: **Both slice-2 tasks shipped.** Task 1 (precise focused-value reader
attribution, swift-tui `190b3a64`) and task 2's **default flip** (swift-tui
`683c63e0`: single-pass is now the default, gallery-verified, `SWIFTTUI_SINGLE_PASS_FOCUS=0`
opts out) are landed and proven at parity. **The only Phase 3 work left is retiring
the now-dormant loop + budget** (a separate cleanup; see "Flip the default" → step 2
below and the proposal's "Phase 3 status — default flipped on").

## What shipped (task 1, 2026-06-29)

The recommended route A (env-read attribution) was implemented with one
simplification proven during the work: a **dedicated synthetic
`FocusedValuesDependencyKey`** token records the reader (decoupled from the
value-carrying `FocusedValuesKey`, which `ResolveContext.init` reads per node —
the precision test caught that attributing through it marks every node a reader),
and **no `==`-vs-`focusSyncEquals` env-comparison special-case was needed**: the
pure-value invalidation is precise via the persistent reverse-index +
`focusSyncEquals`-driven change detection, and the single-pass branch invalidates
`renderer.focusedValuesDependentIdentities()` (empty ⇒ no-op) instead of
`[rootIdentity]`. Reuse-safety comes from the dependency index persisting across
reuse (only rewritten in `ViewGraph.finishEvaluation`), not from an env-snapshot
special-case. New test: `FocusedValueReaderAttributionTests` (SwiftTUIViewsTests).

---

(Original plan follows. Task 1 sections are retained for context; only "Flip the
default" remains to do.)

## Original status

Phase 3 **slice 1 is shipped** (single-pass focus-sync
convergence behind a flag, default off, proven at parity). This directs the
remaining Phase 3 work.

Parent design: [`docs/proposals/2026-06-29-001-focus-model-reassessment.md`](../proposals/2026-06-29-001-focus-model-reassessment.md)
(see "Part 2" and "Phase 3 status — slice 1").

---

## Pickup prompt (read this first)

You are continuing the focus-model redesign (Phase 3) in `swift-tui`. Slice 1
replaced the render-until-fixpoint focus-sync loop with a single-pass,
one-frame-lag dependency model, gated by `SWIFTTUI_SINGLE_PASS_FOCUS` (default
**off**), proven at parity (409 tests across 14 focus/runtime suites pass
identically gate-off and gate-on under AddressSanitizer). Two tasks remain:

1. **Make pure focused-value propagation precise** (replace the coarse root
   invalidation with per-reader invalidation that is reuse-safe).
2. **Flip the default on** once precise + gallery-proven, then retire the loop +
   budget.

Work inside the `swift-tui` submodule; commit and push there, then re-pin the org
root and run `bazel test //:org_fast`. Commits carry **no AI attribution**
(`no-ai-coauthors` prek hook). `SwiftTUICore`/`SwiftTUIViews`/`SwiftTUI` are
Foundation-free. **macOS `swift test` hits the pre-existing #12 snapshot/run-loop
SIGSEGV; verify under `swift test --sanitize=address`** (it shifts the layout out
of the deterministic-crash phase). Exclude `InteractiveRuntimeTests` and
`StackSafetyRegressionTests` from ASan runs — they are pre-existing #12 /
deep-recursion crashers, unrelated.

## Where slice 1 left it

- Gate: `SinglePassFocusConvergenceConfiguration.isEnabled`
  (`Sources/SwiftTUICore/Resolve/SinglePassFocusConvergenceConfiguration.swift`),
  fed by `FeatureGate.singlePassFocusConvergence` (`SWIFTTUI_SINGLE_PASS_FOCUS`,
  `defaultIsEnabled = false`) in `Sources/SwiftTUICore/Support/FeatureFlags.swift`.
- Single-pass branch: `RunLoop.processFocusSyncIteration`
  (`Sources/SwiftTUIRuntime/RunLoop/RunLoop+FocusSync.swift`). When the gate is on
  it splits the work by node kind, **no budget**:
  - **Focus location** (focus moved / request applied / default focus / `@FocusState`
    flip / scroll-to-reveal / initial auto-adoption via `focusJustEstablished`):
    applied **eagerly** with one extra render (`didEagerFocusLocationRerender`
    caps it at one pass; `convergence.rerenderedForFocusSync = true; return .rerender`).
    `currentFocusedValues` updates before that render, so focused values ride along.
  - **Pure focused-value change** (focused subtree republished without focus
    moving): the genuine output→input feedback edge. Currently nudged with a
    **coarse** `scheduler.requestInvalidation(of: [rootIdentity])` → whole-tree
    re-render next frame. **This is what slice 2 makes precise.**
- The coarse path is **correct and reuse-safe** (whole-tree re-render bypasses
  reuse). It is only imprecise: it re-resolves the whole tree for a change that
  only a few `@FocusedValue` readers care about.

## The problem slice 2 must solve

`@FocusedValue`/`@FocusedBinding` read a **cached** `focusedValues` field
(`AuthoringContext.focusedValues`, surfaced in
`Sources/SwiftTUIViews/State/FocusedValue.swift` via `currentAuthoringContext()?.focusedValues[keyPath:]`).
That read is invisible to **both**:

- the **reader-attribution** system (so focus-sync cannot find the readers to
  invalidate them precisely), and
- the **reuse** system (so a reader subtree can be reused while the focused value
  changed → stale output).

Naive "record reader identities and invalidate only those" is **not reuse-safe**:
a reader that was reused last frame records no read this frame, so it would be
left stale. The coarse whole-tree re-render sidesteps this; precise invalidation
must not.

## Recommended approach (route A): environment-read attribution + value-equality

Make `@FocusedValue` read go through the **environment-read attribution** path
that the real `EnvironmentValues` subscript already uses
(`Sources/SwiftTUIViews/Environment/Environment.swift` — `ViewNodeContext.current?.recordEnvironmentRead(identifier)`;
hook is `ViewNode.recordEnvironmentRead(_:)` in `Sources/SwiftTUICore/Resolve/ViewNode.swift`).
This solves **both** problems at once: an attributed env read denies reuse on
change *and* yields the reader identity for invalidation.

The catch: `FocusedValues == ` is broken for `Binding` payloads (always unequal —
the same reason slice 1's crash fix added `focusSyncEquals`). If the
environment-change / reuse-denial comparison for the `focusedValues` key uses
`==`, every `@FocusedValue` reader re-resolves every frame (churn). So:

1. Route `@FocusedValue.wrappedValue` / `@FocusedBinding.currentBinding` through
   the attributed environment read (read the `focusedValues` `EnvironmentKey` via
   the subscript, not the cached field) so the read is recorded.
2. **Special-case the `focusedValues` environment-change check to use
   `focusSyncEquals`** (value-based `Binding` comparison) instead of `==`. Find
   the env-change/reuse-denial comparison site (start from `recordEnvironmentRead`
   consumers and the environment snapshot equality used for reuse denial — note
   `recordEnvironmentSnapshotDiff` in `ViewNode.swift` is only a *trace*, not the
   live mechanism; find the real reuse-denial env comparison). `focusSyncEquals`
   lives on `FocusedValues` in `Sources/SwiftTUICore/Semantics/FocusedValues.swift`.
3. In `processFocusSyncIteration`'s single-pass branch, the pure-focused-value
   change no longer needs the coarse root invalidation — the attributed readers
   are invalidated by the ordinary env-change path. Remove the
   `scheduler.requestInvalidation(of: [rootIdentity])` for the value case (keep it
   only as a fallback if attribution is somehow unavailable).

### Alternative (route B): dedicated reuse-integrated reader registry

If route A's env-change special-casing proves too invasive, build a focused-value
**reader** registry mirroring the publisher `LocalFocusedValuesRegistry`
(`Sources/SwiftTUICore/Runtime/LocalFocusedValuesRegistry.swift`), recording
reader identities during resolve (reader reachable via `ViewNodeContext.current?.identity`),
and invalidate them in focus-sync on a `focusSyncEquals` change. **But** this must
also deny reuse for recorded readers (else the reuse-staleness bug), so it ends up
re-implementing what route A gets from env attribution. Prefer route A.

## Verification (gate the work on this)

- Parity: run with the gate **off** and **on**, both must pass:
  ```
  SUITES="AppRuntimeTests|FocusContextRuntimeTests|KeyCommandDispatchTests|FocusTransitionTests|SwiftUISurfaceTests|AsyncFrameTail|Phase4Observation|PanelTests|DropDestinationDispatchTests|NavigationDestinationTests|TabViewLifecycleTests|PresentationActionScope|ToolbarTests|FocusTrackerTests"
  swiftly run swift test --sanitize=address --filter "$SUITES"
  SWIFTTUI_SINGLE_PASS_FOCUS=1 swiftly run swift test --sanitize=address --filter "$SUITES"
  ```
  Baseline at slice 1: **409 tests, 14 suites, pass both ways.**
- The focused-value cases that catch lag/staleness live in `AppRuntimeTests`
  ("FocusedValue reads the value published by the currently focused control",
  "FocusedValue includes ancestor publishers for a focused descendant", the
  default-focus and disappearing-focus tests). Keep them green gate-on.
- Add a test that proves **precision**: a pure focused-value change (focus stays
  put, a published value mutates) invalidates only the `@FocusedValue` reader(s),
  not the whole tree (e.g. assert a sibling subtree's body did not re-evaluate —
  use the existing re-eval probes / reader-attribution test patterns).
- `SwiftTUIRuntime` must cross-compile for `wasm32-wasi`:
  `swiftly run swift build --swift-sdk swift-6.3.1-RELEASE_wasm --target SwiftTUIRuntime`.

## Flip the default (final step, separate commit)

1. Set `FeatureGate.singlePassFocusConvergence.defaultIsEnabled = true` in
   `FeatureFlags.swift`. Run the full ASan parity suite (now both default-on and
   `=0` opt-out). Exercise the gallery (`swift-tui-examples`) by hand / via its
   gate for real focus interactions (Tab traversal, default focus, `@FocusedValue`
   toolbars, focus-dependent content).
2. Once stable on the default, **retire the loop + budget**: remove the
   `.rerender`/budget path in `processFocusSyncIteration`, delete
   `FocusSyncRerenderBudget` and its `RunLoop+Rendering.swift:125` assertion, and
   simplify `FocusSyncConvergenceState`. Keep the gate only if a fallback is still
   wanted; otherwise remove it too. This is the "no loop, no budget" end state the
   proposal's Part 2 targets.

## Watch-outs

- **Termination**: single-pass relies on `focusSyncEquals` for change detection
  (no budget). A genuine non-convergence would now manifest as repeated follow-up
  frames (a busy render) rather than the old budget `assertionFailure`. If a test
  hangs/times out, that is the tell — fix the equality/stability, do not re-add a
  budget.
- **Both render paths**: `processFocusSyncIteration` is shared by the sync
  (`renderPendingFrames`) and async (`renderPendingFramesAsync`,
  `convergenceLoop`) drivers in `RunLoop+Rendering.swift`; the single change covers
  both. Re-verify async-path focus tests.
- **Initial auto-adoption**: `FocusTracker.updateRegions` returns `false` for the
  nil→control transition by design; slice 1 handles it via `focusJustEstablished`.
  Don't regress that when reworking the value path.
