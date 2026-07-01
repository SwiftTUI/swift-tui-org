# Plan: fix the reuse-vs-re-rooting stale-content seam (stress cluster A)

- **Date:** 2026-07-01
- **Owner:** background agent (dispatched from the 2026-07-01 stress investigation)
- **Companion report:** [reports/2026-07-01-framework-stress-known-issue-investigation.md](../reports/2026-07-01-framework-stress-known-issue-investigation.md)
- **Target repo:** `SwiftTUI/swift-tui` (the `swift-tui` submodule)

This plan is the agent brief. The report is the source of truth for the evidence
chain; read it in full before touching code.

## Goal

Eliminate the dominant `FrameworkStressTests` `withKnownIssue` cluster (~55 of
the current 72 flags): after an owner's `.id` churn, a re-rooted descendant
(control under `AnyView`/`Panel`/captured-subview label) keeps its **first
generation's** closure / binding / observed value / label instead of
re-resolving with the fresh view value.

## The bug (root-caused — verify, then fix; do not re-derive from scratch)

Reuse (`ViewGraph.reusableSnapshot` retained, and `memoizedReusableSnapshot`
memo) decides "safe to skip re-resolve" by invalidation **containment** — is
this node inside an invalidated subtree? But the framework **re-roots** identity
and/or structural-path in several layers:

- `ExactIdentityModifier` (`.id(Identity)`; note `testIdentity(...)` returns
  `Identity`, so the stress tests bind this overload, **not** the public
  `IDModifier`/`EntityIdentity` one).
- `AnyView` payloads (keyed by erased type).
- Captured-subview scopes (control labels/styles via `ScopedContentPayload` /
  `CapturedSubviewView` / `makeCapturedAuthoringContext`).

When an owner's `.id` churns (fixture `generation += 1`), the fixture
invalidates and re-resolves, but each re-rooted descendant escapes containment
and is served its **stale** snapshot. Confirmed at the retained-reuse decision
for a re-rooted node: identity ancestry misses the invalidated fixture,
`node.parent == nil`, committed `structuralPath` is re-rooted — while the live
`context.structuralPath` **does** carry the true positional ancestry. This is
the same hazard class as `ResolveReuseAncestorInvalidationTests`, extended to
re-rooted descendants that suite does not cover.

## Reproduce

```
cd swift-tui
swiftly run swift test --filter 'SwiftTUITests.FrameworkStressTests'
```

Expect: passes with **72 known issues** (a prior pass already fixed the disabled
key-press leak, dropping 78→72; do not undo that). Cluster A = the
`anyView*Rebinds` / `panel*Rebinds` / `tapGestureAnyViewRebinds` /
`preferenceObserverRebinds` / `onChangeHandlerRebinds` frame assertions
(`FrameworkStressTests.swift` ~line 2458, via
`expectedFrameKnownIssueDescription`), the `stableButtonActionRebinds` label
(~line 1591), and `stackedKeyPressTextRebinds`.

Instrument with temporary `print`s (stdlib-only; safe in Foundation-free
layers). Minimal repro: churn one `AnyView(Button(...).id(...))` owner and log
the three resolveView outcomes (retained / memo / recompute) plus the two
booleans in `reusableSnapshot`. `SWIFTTUI_REUSE_TRACE`(+`_FILE`) records reuse
denials.

## Key files

- `Sources/SwiftTUICore/Resolve/ViewGraph.swift` — `reusableSnapshot` (~1496),
  `memoizedReusableSnapshot` (~1614), `structuralInvalidationIntersects`
  (~2066), `finishEvaluation` (~1135; **`didChangeResolvedIdentity` ~1172** is
  the frame-over-frame identity-change signal), `applyResolvedNode` /
  `reindexIdentity` (~293/316).
- `Sources/SwiftTUICore/Commit/FrameMetrics.swift` — `InvalidationSummary`
  (`intersectsSubtree`, `hasInvalidatedAncestor` ~89).
- `Sources/SwiftTUIViews/Foundation/ViewFoundation.swift` — resolveView reuse
  gate (~296-471).
- `Sources/SwiftTUIViews/Modifiers/ViewMetadataModifiers.swift` — `IDModifier`
  (~192), `ExactIdentityModifier` (~231).
- `Sources/SwiftTUIViews/Foundation/ViewModifier.swift` — `resolveOwned` (~69;
  calls `resolveViewElements` directly, bypassing the reuse gate for the owned
  node).
- `Sources/SwiftTUIViews/Foundation/ViewCompositionHelpers.swift` —
  `ScopedContentPayload` / `CapturedSubviewView` (the second re-rooting layer
  that defeated the naive fix).
- `Sources/SwiftTUIViews/Environment/ResolveContext.swift` — `replacingIdentity`
  (~227, preserves structuralPath), `child` (~198), `structuralPath`.

## Already tried and REVERTED — do not repeat as-is

Threading `context.structuralPath` into `reusableSnapshot` /
`memoizedReusableSnapshot` and denying reuse when the positional path had an
invalidated ancestor. It correctly denied reuse at the `ButtonBody` layer but
changed **zero** test outcomes (the label re-roots **again** via the
captured-subview scope) and double-walks the ancestry on the reuse hot path
(perf regression for normal nodes). A per-layer guard is the wrong shape.

## Recommended approach (validate before committing)

**Invalidate the structural subtree on identity churn.** When a node's resolved
identity changes frame-over-frame (`didChangeResolvedIdentity` — an `.id`
churn), add that node's committed structural subtree to the invalidation set so
**all** positional descendants — re-rooted or not — re-resolve this frame.
Should clear clusters A/D/G in one move. Watch ordering: descendants are
resolved *before* the owner's `finishEvaluation`, so the churn signal may need to
be seeded early enough that the same-frame walk sees it. Fallback (report §6.2):
make re-rooting layers preserve the positional structural-path and key reuse
containment on structural path, not identity.

## Hard constraints

- **No reuse-hot-path perf regression.** Reuse rate (`resolve_ms`) was tuned by
  the H2/H3 work; make the new check a no-op for non-re-rooted nodes and avoid
  redundant ancestor walks. Verify reuse denials with `SWIFTTUI_REUSE_TRACE`.
- **Distinguish stale-closure (bug) from state-that-must-survive (feature).** An
  owner `.id` churn should refresh closures/bindings/labels, but the framework
  deliberately persists some `@State`/focus/lifecycle across seams. See
  `swift-tui/AGENTS.md` "runtime state bugs" guidance; do not replace
  graph-scoped imperative state with a last-bound global fallback.
- **Must not break:** `ResolveReuseAncestorInvalidationTests`,
  `RetainedSubtreeReuseTests`, `ResolveReuseIndexingTests`, `ResolvePurityTests`,
  `RetainedPhaseProductGateTests`, and the broader suite. There is a known
  intermittent run-loop SIGSEGV flake (swift-tui#12) — a crash in the run-loop
  suites under load is not necessarily your regression; re-run / use
  `--sanitize=address` to disambiguate.
- **One signal, one job:** a past lesson — a single staleness flag used for both
  reuse-denial and rebuild caused regressions. Keep the churn-invalidation
  signal distinct.

## Definition of done

1. Cluster-A frame assertions pass **without** `withKnownIssue`: remove the
   relevant entries from `expectedFrameKnownIssueDescription`
   (`anyView*`/`panel*`/`tapGestureAnyView`/`preferenceObserver`/`onChange`/
   `stackedKeyPress`) and the discovery `stableButtonActionRebinds` label
   `withKnownIssue` (~line 1591). Revisit `maxRegistrationKnownIssueDescription`
   for `preferenceObserverRebinds` / `anyViewTextEditorPasteRebinds` (may clear).
   Remove **exactly** the flags you fixed — a `withKnownIssue` wrapping a
   now-fixed bug produces an "unexpected pass" failure.
2. `swiftly run swift test --filter 'SwiftTUITests.FrameworkStressTests'` passes
   with a materially lower known-issue count and no unexpected failures.
3. `bun run test` (repo gate) passes.
4. No reuse-hot-path perf regression (spot-check `SWIFTTUI_REUSE_TRACE` on a
   churn scenario; new denials only for genuinely-churned re-rooted subtrees).
5. If some cluster-A sub-cases remain genuinely display-only after the fix,
   document which and why and leave those `withKnownIssue` with an updated
   comment rather than forcing a fragile fix.

Work iteratively: reproduce → minimal fix at the churn site → re-run the stress
filter → widen. Commit in the `swift-tui` child repo; do not commit debug prints.
Report back the final known-issue count, which flags were cleared, and any
residual display-only cases.
