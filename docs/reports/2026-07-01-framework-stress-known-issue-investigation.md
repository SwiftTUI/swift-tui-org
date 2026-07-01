# Framework stress known-issue investigation

- **Date:** 2026-07-01
- **Scope:** `SwiftTUI/swift-tui` — `Tests/SwiftTUITests/FrameworkStressTests.swift`
- **Status:** Investigation + one root cause fully characterized. **Three
  independent fixes landed** (disabled key-press leakage, hover first-frame
  render, count-two tap) → **78 known issues to 66**, suite green, repo gate
  green. The candidate reuse fix for the dominant cluster was written, measured
  to be insufficient, and reverted (§5). The cluster-A architectural fix is
  dispatched to a background agent (see
  [../plans/2026-07-01-003-cluster-a-reuse-rerooting-fix.md](../plans/2026-07-01-003-cluster-a-reuse-rerooting-fix.md)).

## 1. What prompted this

`FrameworkStressTests.swift` is a new, large (~4,100-line) stress suite that
drives the **composed runtime path** (`SwiftTUIRuntime.RunLoop` + real input
dispatch + real render) through a battery of *identity-churn* scenarios. Many
assertions are wrapped in `withKnownIssue(...)`, i.e. the author has encoded
"this currently reproduces a bug" as a passing-but-flagged expectation.

Baseline (before any change):

```
Suite "SwiftTUI framework stress behavior" passed … with 78 known issues.
  └ "directed stress expansion case" (50 cases) … 76 known issues
  └ + 2 explicit known issues (pointer-hover, stable Button label)
```

The task: investigate the flagged issues and fix the ones we can.

## 2. How the suite is built (so future readers can navigate it)

Every case shares one shape:

- A **fixture** holds `@State generation` (plus `total`, `flag`, `intValue`,
  `textValue`, `selection`).
- A **"Rebuild"** button does `generation += 1`, which **churns an owner's
  identity** via `.id(testIdentity("…owner", "\(generation)"))`.
- Inside that owner is a **control with a *stable* explicit id**
  `.id(testIdentity("…control"))`.
- The harness clicks/keys/pastes/drags the control, then clicks Rebuild, and
  asserts on the fixture's rendered `total …` line and on registry counts
  (`actionRegistrationCount`, `keyPressHandlerCount`, `pointerHoverHandlerCount`,
  `focusRegionCount`, `preferenceObservationRegistrationCount`, …).

Two important, non-obvious facts about the harness:

1. **`testIdentity(...)` returns a `SwiftTUICore.Identity`.** So
   `.id(testIdentity(...))` binds the **`package func id(_ identity: Identity)`**
   overload → **`ExactIdentityModifier`**, which *replaces* the node identity
   with a root-level identity (e.g. `FrameworkStressExpansion/control`). It does
   **not** use the public `IDModifier` (the `Hashable` overload that mints an
   `EntityIdentity`). This distinction is the crux of §4.
2. Registry counts are read straight off the live `RunLoop` local registries,
   so the assertions are about *runtime* state, not just rendered text.

## 3. Taxonomy of the 78 known issues

| Cluster | Representative cases | Symptom | Root nature |
|--------|----------------------|---------|-------------|
| **A. Stale content under wrapper + owner churn** | `anyView*Rebinds` (Button/Toggle/Disclosure/TextField/SecureField/TextEditor/Stepper/Slider/Picker), `panelButtonActionRebinds`, `panelToggleRebinds`, `panelTextFieldKeyRebinds`, `tapGestureAnyViewRebinds`, `preferenceObserverRebinds` (frame), `onChangeHandlerRebinds` | After owner `.id` churn, the control keeps the **first generation's** closure / binding / observed value. `total` never advances. | **Reuse-containment vs. identity re-rooting mismatch** (see §4). Dominant cluster (~55 of 78). |
| **B. Stacked key-press** | `stackedKeyPressTextRebinds` | Two stacked `.onKeyPress` only dispatch **one** live handler through the churn loop. | Likely same reuse seam as A, at the key-handler registry. |
| **C. Count-two tap** | `tapGestureCountTwoRebinds` | `.onTapGesture(count: 2)` never fires in the run-loop churn path (fails even at generation 0). | Independent: multi-tap detection over the scripted `.down/.up` input path. |
| **D. onChange no-fire** | `onChangeHandlerRebinds` | `.onChange(of:)` doesn't fire through the expansion churn path (the *standalone* onChange test passes). | Same reuse seam as A — the `onChange` node reuses stale. |
| **E. Registration accumulation / disabled leakage** | `disabledAncestorKeyPressSkipsHandlers`, `hoverWithTapGestureKeepsBothBounded`, `anyViewTextEditorPasteRebinds` (max-reg), `preferenceObserverRebinds` (max-reg) | Disabled `.onKeyPress` still registers; hover+tap duplicates hover regs; focus regions / preference observers accumulate across churn. | Mixed: one clean independent bug (disabled key-press), plus churn-driven accumulation tied to A. |
| **F. Hover first-frame render** | `pointerHoverHandlersStayLiveAndBoundedUnderOwnerChurn` (gen 0) | The first `.entered` hover state mutation does not schedule a rendered frame. | Independent: hover-phase invalidation/scheduling. |
| **G. Stable label stale** | `stableButtonActionRebinds` (label, line 1591) | Right after owner churn the Button label stays `"Probe Button 0"`. | Same reuse seam as A, observed via label text instead of closure. |

## 4. Deep dive: the dominant root cause (cluster A / D / G)

### 4.1 Method

Rather than reason top-down through the reuse machinery, a minimal reproducer
(`ScratchProbeTests`, since deleted) drove one owner-churn against both a
direct-`.id` control and an `AnyView`-wrapped control, with temporary
`print`-based instrumentation at the three resolve outcomes in
`resolveView(_:in:authoringContextOverride:)`
(`reusableSnapshot` → retained reuse, `memoizedReusableSnapshot` → memo reuse,
`beginEvaluation` → recompute). A **behavioral probe** (a control with *both* a
generation-dependent label and closure) distinguished "whole subtree reused"
from "closure-only" from "render-only".

### 4.2 The chain of evidence

1. **`.id(Identity)` re-roots.** The control resolves at a root-level identity
   `ProbeControl/…` (from `ExactIdentityModifier` calling
   `context.replacingIdentity(with:)`), while the owner/payload resolve at
   `ProbeOwner/0/…`. So the control's identity **does not descend from** the
   fixture identity.

2. **Retained reuse decides safety by *containment*.** On the churn frame,
   `reusableSnapshot(for: ProbeControl/…, invalidatedIdentities:[fixture, …])`
   found the node *not* intersecting invalidation and reused its **stale**
   snapshot. All three containment checks miss it:
   - `InvalidationSummary.intersectsSubtree(at: identity)` walks the **identity**
     ancestry (`StructuralPath(identity:)`), which for a re-rooted node is
     `ProbeControl/…` and never reaches the invalidated fixture.
   - `structuralInvalidationIntersects(node, …)` walks live `ViewNode.parent`
     links — but at check time the re-rooted node's **`parent == nil`**
     (confirmed by instrumentation), so `isDescendant(of:)` returns false
     immediately.
   - The committed `structuralPath` was *also* re-rooted to `ProbeControl/…`.

   The one signal that *is* correct at the decision point is the live resolve
   **`context.structuralPath`**, which reads
   `ProbeAnyViewRoot/content/VStack[2]/…/ButtonBody/false/base` — the true
   positional ancestry, under the invalidated fixture.

3. **The staleness is layered.** Denying retained reuse using
   `context.structuralPath` (the fix in §5) made the `ButtonBody` sub-nodes
   recompute, but the rendered label stayed `Probe Label 0`. Instrumenting
   deeper showed the owner's `body` **did** re-run with `generation = 1`
   (`AnyView(Button("Probe Label 1"))`), and `Button.resolvedNode` **did** run
   with the fresh gen-1 label value — yet `resolveOwned`'s resolved subtree still
   contained `Probe Label 0`. The label flows through
   `ButtonStyleConfiguration.Label` → `CapturedSubviewView` /
   `ScopedContentPayload`, whose `makeCapturedAuthoringContext` **re-roots the
   structural path again**, so the label's `Text` node escapes containment a
   *second* time and reuses stale.

### 4.3 The generalization

The framework aggressively **re-roots identity and/or structural path** in
several independent places:

- `ExactIdentityModifier` (`.id(Identity)`) and portals — replace identity.
- `AnyView` payloads — keyed by erased *type*.
- Captured-subview scopes (`CapturedSubviewView`, control labels, styles) —
  re-root the authoring/structural scope.

Reuse (both retained and memo) decides "safe to skip re-resolve" by **invalidation
containment** — "is this node inside an invalidated subtree?" Every re-rooting
layer breaks containment, so when an ancestor churns via `.id`, a re-rooted
descendant is judged unchanged and served stale. A guard at one layer doesn't
help because the next layer re-roots again. This is why the direct-`.id` case
*recovers* on the next interaction (its parent chain is intact on a non-churn
frame) while the `AnyView`/`Panel`/captured-label cases stay stale.

This is the same hazard class already tracked by
`Tests/SwiftTUITests/ResolveReuseAncestorInvalidationTests.swift`
("ancestor invalidation recomputes binding-driven descendants"). The new stress
cases extend that hazard to **re-rooted** descendants, which the existing
machinery does not cover.

## 5. The candidate fix, and why it was reverted

**Idea:** consult the *live* `context.structuralPath` (which carries true
positional ancestry) in the reuse decision, so a re-rooted node under an
invalidated ancestor is denied reuse.

**Implemented:**
- `InvalidationSummary.hasInvalidatedAncestor(ofStructuralPath:)` — walk the
  positional structural-path ancestry against `directlyInvalidated`.
- Threaded `context.structuralPath` into `reusableSnapshot` and
  `memoizedReusableSnapshot` and denied reuse when an invalidated ancestor was
  found on the positional path.

**Result:** it *did* deny the wrongful retained/memo reuse at the `ButtonBody`
layer (verified via instrumentation), but **it did not change a single test
outcome** — the suite still reported exactly 78 known issues — because:

1. The label re-roots a second time through the captured-subview scope, escaping
   the positional-path guard too.
2. For non-re-rooted nodes the new walk is **redundant** with the existing
   `hasInvalidatedAncestor(of: identity)` inside `intersectsSubtree`, so it
   roughly **doubles the ancestor-walk cost on the retained-reuse hot path** —
   the exact path the H2/H3 perf work optimized — for zero benefit.

Given "insufficient + measurable hot-path cost," the change was reverted. The
repo is back to a clean tree; `bazel`/`swift` build is green.

## 6. What a real fix probably needs

Ranked by leverage vs. risk:

1. **Invalidate the structural subtree on identity churn (highest leverage).**
   When a node's resolved identity changes frame-over-frame (an `.id` churn),
   add its committed structural subtree to the invalidation set so *all*
   positional descendants — re-rooted or not — re-resolve. Detected in
   `finishEvaluation`/`applyResolvedNode` where previous vs. new resolved
   identity is already compared (`didChangeResolvedIdentity`). Risk: correctness
   of the churn-detection and blast radius; must not re-introduce the perf cost
   the reuse work removed. This is the most principled fix and most likely to
   clear clusters A/D/G in one move.

2. **Make re-rooting layers preserve positional structural-path for reuse
   purposes.** Keep the semantic identity replaced, but thread the true
   positional `structuralPath` through `ExactIdentityModifier`, captured-subview
   scopes, and `AnyView` payloads, and make reuse containment key on
   *structural* path, not identity. Larger, touches many layers; structural path
   is load-bearing elsewhere.

3. **Belt-and-suspenders at each reuse gate** (the reverted approach), but only
   *after* (2) makes the positional path reliable end-to-end, and gated so it
   is a no-op for non-re-rooted nodes (avoid the double-walk).

Any of these must be validated against
`ResolveReuseAncestorInvalidationTests`, `RetainedSubtreeReuseTests`,
`ResolveReuseIndexingTests`, and the perf residual map (`resolve_ms` reuse-rate),
not just the stress suite.

## 7. Tractable, independent fixes (recommended next)

These do **not** depend on the cluster-A reuse work:

- **Cluster E — disabled key-press leakage (DONE, 2026-07-01).**
  `KeyPressModifier.resolve` (`Sources/SwiftTUIViews/Input/KeyPressModifier.swift`)
  registered unconditionally; `Button.resolvedNode` correctly guards on
  `context.environmentValues.isEnabled`. Added the same guard so a
  `.disabled(true)` ancestor skips key-press handler registration, and removed
  the two `disabledAncestorKeyPressSkipsHandlers` `withKnownIssue` descriptions.
  Verified: 78 → 72 known issues, suite still green. The remaining cluster-E
  accumulation cases (`hoverWithTapGestureKeepsBothBounded`,
  `anyViewTextEditorPasteRebinds` focus regions, `preferenceObserverRebinds`
  registrations) are churn-driven and tied to the cluster-A seam.

- **Cluster F — hover first-frame render (DONE, 2026-07-01).**
  `PointerHoverModifier` registered its handler **raw**, unlike `Button`/
  `onKeyPress` which wrap dispatch in `withImperativeAuthoringContext(...)`.
  Without the imperative scope a `@State` mutation inside the hover handler was
  not attributed to an owner node and never scheduled a frame. Fixed by
  capturing the imperative authoring snapshot at `.onPointerHover` and restoring
  it around dispatch (`Sources/SwiftTUIViews/Gestures/PointerHover.swift`), and
  removed the `withKnownIssue` at `FrameworkStressTests.swift:~360`.

- **Cluster C — count-two tap (DONE, 2026-07-01).** `TapGestureRecognizer`
  (and `SpatialTapGestureRecognizer`) reported `isActive == pressStart != nil
  && !phase.isTerminal`. After the first tap's `.up`, `pressStart` is nil-ed and
  `completedTaps == 1` but `phase` is still `.possible`, so `isActive` went
  false — and `LocalGestureRegistry.register` only preserves an *active*
  recognizer across re-resolves. A re-resolve between the two taps therefore
  tore down the partial double-tap and reset the count. Fixed by keeping
  `isActive` true while `completedTaps > 0`
  (`Sources/SwiftTUIViews/Gestures/TapGesture.swift`,
  `SpatialTapGesture.swift`); removed the `tapGestureCountTwoRebinds`
  `withKnownIssue`.

Clusters **B** (stacked key-press) and **D** (onChange) and **G** (stable label)
share the cluster-A reuse seam and are best deferred until §6 lands.

## 8. Reproduction / verification notes

- Baseline: `swiftly run swift test --filter 'SwiftTUITests.FrameworkStressTests'`
  → passes with 78 known issues.
- The composed runtime path is required to reproduce (per the repo's own
  guidance) — the harness uses the real `RunLoop`, not an isolated view.
- Instrumenting reuse decisions: temporary `print`s in the three outcomes of
  `resolveView` (retained/memo/recompute) plus `reusableSnapshot`'s
  `identityIntersectsInvalidation` / `structurallyIntersectsInvalidation`
  booleans and `node.parent`, filtered by identity substring, were sufficient to
  localize the seam without a debugger. `print` is stdlib-only and safe in the
  Foundation-free layers.

## 9. One-line takeaway

The dominant stress-test failures are **not** many separate bugs; they are one
architectural mismatch — **reuse safety is decided by identity/structural
*containment*, but the framework re-roots identity/structural-path in several
layers, and an ancestor `.id` churn lets those re-rooted descendants dodge
invalidation and serve stale content.** Fix the churn→subtree invalidation once
and most of cluster A/D/G should fall together.
