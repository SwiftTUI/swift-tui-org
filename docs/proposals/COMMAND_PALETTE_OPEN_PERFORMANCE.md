# Proposal: Make presentation open/close cheap (command-palette "initial display" lag)

Status: **Draft / investigation complete, fix not yet implemented**
Scope: `SwiftTUICore` resolve/reuse + `SwiftTUIViews` presentation (in the
`swift-tui` submodule)
Author: performance spike, command-palette responsiveness

Source references (paths relative to this coordination root):
- `swift-tui/Tests/SwiftTUITests/ResolveReuseAncestorInvalidationTests.swift`
- `swift-tui/Sources/SwiftTUICore/Resolve/ViewGraph.swift` (`reusableSnapshot`)
- `swift-tui/Sources/SwiftTUIViews/Presentation/PresentationCoordinator.swift`

Related coordination docs (same performance workstream):
- [../reports/2026-05-28-gallery-performance-report.md](../reports/2026-05-28-gallery-performance-report.md)
  — H2 per-interaction `resolve` cost identified as a hot spot.
- [../reports/2026-05-30-h2-resolve-reuse-findings.md](../reports/2026-05-30-h2-resolve-reuse-findings.md)
  — scoped retained reuse (the `debugSignature` fix); this proposal is the next
  layer (reuse under *ancestor* invalidation).
- [../plans/2026-06-02-001-rendering-performance-optimization-proposal.md](../plans/2026-06-02-001-rendering-performance-optimization-proposal.md)
  — the broader rendering-performance wave this fits into.
- [../plans/2026-05-25-001-shared-surface-damage-contract-plan.md](../plans/2026-05-25-001-shared-surface-damage-contract-plan.md)
  — command-palette raster damage (the per-frame *tail*, distinct from the
  *resolve* cost below).

## 1. Summary

Opening the Gallery command palette feels slow on first display, even in
release. The cause is **not** in the palette view code. Presenting the palette
flips a `@State` flag (`showPalette`) that lives on the root `GalleryView`, and
the runtime intentionally **re-resolves every descendant of an invalidated
node**. So a single boolean toggle re-resolves the *entire* gallery subtree
(`TabView` + the selected tab + all 18 `paletteCommand` contributions) before
the overlay can be shown.

This is structural: it reproduces with any presentation modifier
(`.sheet`, `.alert`, `.popover`, `.paletteSheet`) whose `isPresented` binding is
backed by state at or above the presented content, which is the normal case.

This document records the measured evidence, explains why a Gallery-level
refactor cannot fix it, and proposes three framework-level options with their
required work and risk.

A separate, already-shipped change (Gallery `CommandPalette.swift`: compute the
fuzzy-match list once per body evaluation instead of O(visibleRows × commands))
addresses palette *typing* cost as command count grows. It does **not** address
the open cost described here.

## 2. Symptom

- Opening the command palette in the Gallery demo has a perceptible hitch.
- Reported as noticeable "even somewhat in release builds."
- Specifically called out for the palette's **initial display** (the open), not
  only typing.

## 3. How this was measured (reproducible)

Two harnesses were used against the local `swift-tui` submodule at HEAD.

1. **Interactive `RunLoop` probe** — drives a Gallery-shaped fixture
   (`TabView(.literalTabs)` with 18 tabs, `.panel`, `.keyCommand`, 18
   `.paletteCommand`, `.paletteSheet`) through the real run loop with scripted
   keystrokes, paced one keystroke per committed frame, capturing
   `FrameDiagnostics.work` and `FrameDiagnostics.timing.phaseTimings` via a
   `FrameDiagnosticSink`.
2. **Release micro-benchmark** (`-Ounchecked`) — a standalone executable that
   depends on the local package by path and uses the public
   `DefaultRenderer.render(_:context:proposal:)` snapshot API with explicit
   `invalidatedIdentities`, so resolve reuse can be measured deterministically
   and timed with `ContinuousClock` over 200 iterations.

The two key signals are `FrameDiagnosticWork.resolvedNodesComputed` (bodies
re-evaluated this frame) and `resolvedNodesReused` (subtrees reused from the
retained graph).

> Note: the one-shot `render()` path passes `damage: nil`, forcing a full
> rasterize. The live `RunLoop` derives row damage and rasterizes
> incrementally, so the *tail* (measure→…→raster→commit) numbers below
> overstate the live per-frame cost. The **resolve** numbers are faithful to
> both paths.

## 4. Evidence

Synthetic Gallery, 100×40 surface, palette open, release (`-Ounchecked`):

| Scenario | invalidated identity | resolvedComputed | resolvedReused | resolve phase |
| --- | --- | --- | --- | --- |
| **Open palette** | root (`showPalette` toggle) | **256** | **0** | ~5.2 ms |
| **Type in palette** | deep TextField id (`query` state) | 42 | 212 | ~1.8 ms |
| **Open, TabView extracted to child** | root | 256 | 0 | — |
| **Invalidate portal host only** | `__TerminalUIPortalHost/<root>` | 166 | 133 | — |

Total open tree ≈ 240 nodes. Reading the table:

- **Open** recomputes the whole tree (256 nodes, 0 reused). Resolve dominates
  the frame (~5 ms release for a *simple* selected tab; a heavy tab — Life,
  Physics, Animations — costs proportionally more).
- **Typing** is already cheap on resolve when the change is scoped to the deep
  `query` state: 42 recomputed, 212 reused. The per-keystroke pain (if any) is
  the pipeline tail, mitigated in the live loop by incremental raster, plus the
  in-palette `matches` recompute that has been fixed separately.
- **Extracting the `TabView`** into its own child view changes nothing — still
  256/0. This is the proof that the cost is structural, not a Gallery code
  smell.
- **Invalidating only the portal host** (what the imperative presentation path
  does) lets 133 nodes reuse — a partial win, and the basis for Option B.

## 5. Root cause

Three facts combine:

1. **`@State` invalidation is coarse.** Mutating a `@State` value invalidates
   the *owning view's identity*, not the specific reader nodes. `showPalette`
   lives on `GalleryView` (the content root), so toggling it invalidates the
   root identity. (See `StateContainer` → `invalidator.requestInvalidation`.)

2. **Ancestor invalidation blocks descendant reuse — by design.**
   `ViewGraph.reusableSnapshot(...)` refuses to reuse a node whose identity is a
   descendant of any invalidated identity:

   ```swift
   let conflictsWithInvalidation = invalidatedIdentities.contains { invalidatedIdentity in
     invalidatedIdentity == identity
       || invalidatedIdentity.isDescendant(of: identity)
       || identity.isDescendant(of: invalidatedIdentity)   // ← ancestor invalidation
       || ...
   }
   ```

   This is intentional and covered by
   `ResolveReuseAncestorInvalidationTests`: a descendant may read a binding or
   closure captured from the invalidated ancestor (e.g.
   `Text(selection.wrappedValue)`), whose underlying value changed even though
   the descendant's identity did not. Reusing it would render stale data.

3. **Command absorption forces the visibility state above the content.**
   `.paletteSheet` (like `.toolbar`) absorbs `paletteCommand` contributions from
   its subtree, so the modifier — and therefore the `isPresented` state it reads
   — must sit *above* the content it presents over. Visibility state is
   therefore always an ancestor of the heavy content.

Put together: the presented content's visibility flag is necessarily an
ancestor `@State`; flipping it invalidates an ancestor; ancestor invalidation
recomputes the whole subtree. The open re-resolves everything.

## 6. Why a Gallery-level fix cannot work

Every Gallery-side restructuring keeps the visibility state an ancestor of the
content:

- Moving `selection` and `showPalette` to separate views — both still read in a
  body whose node is an ancestor of the `TabView`.
- Extracting the `TabView` into its own `View` struct — measured: still 256/0
  (fact #2 blocks reuse of the extracted child because it is a descendant of the
  invalidated root).
- The command-absorption contract (fact #3) prevents moving `.paletteSheet`
  below the content.

The lever has to be in the framework.

## 7. Options

### Option A — Fine-grained, dependency-aware reuse under ancestor invalidation

Make `reusableSnapshot` able to reuse a descendant subtree under ancestor
invalidation **when that subtree provably does not depend on what changed**.

The infrastructure is partly present: `ViewNode.dependencies` is a
`DependencySet { stateSlotReads, environmentReads, observableReads }`, so the
framework already records which state slots each node reads.

Required work:

1. Carry the *changed state slot* (not just the owning identity) through the
   invalidation signal, so resolve knows it was `GalleryView` slot *N*
   (`showPalette`), not merely "`GalleryView` changed."
2. At a reuse candidate, allow reuse when the subtree's transitive
   `stateSlotReads` / `environmentReads` / `observableReads` do **not** include
   the changed slot — even though an ancestor was invalidated.
3. Guarantee that bindings and closures captured from the ancestor register as
   reads. This is the correctness crux: `Text(selection.wrappedValue)` must
   record a read of `selection`'s slot, or it would be wrongly reused. The
   existing `ResolveReuseAncestorInvalidationTests` cases must keep passing, and
   new cases for captured-binding/closure/environment reads must be added.

Impact: **largest** — fixes the open generally, and benefits any
ancestor-state change (tab switches, theme toggles, etc.), not just
presentation.

Risk: **high.** This is the SwiftUI dependency-graph problem. The failure mode
is silent stale rendering, which is hard to detect. Needs exhaustive
read-tracking coverage before it can be trusted.

### Option B — Presentation-scoped invalidation (route visibility through the portal host)

Toggle presentation visibility through the presentation **coordinator / portal
host** rather than content-root `@State`. The imperative presentation path
(`PresentationCoordinatorRegistry.handle(hostIdentity:invalidator:)` →
`setImperativeInvalidationTarget`) already invalidates `hostIdentity` =
`__TerminalUIPortalHost/<root>`, which is **not** an ancestor of the content
(content resolves at `<root>`; see `presentationPortalIdentity`). Measured:
invalidating only the portal host reuses 133 nodes (166 recomputed vs 256).

Required work:

1. Expose a supported, declarative-friendly way for `.paletteSheet`/`.sheet`/…
   to drive visibility through the coordinator's invalidation target instead of
   the caller's `@State` — so `isPresented = true` does not itself invalidate
   the content root. Options: an imperative presentation handle surfaced to the
   call site, or a binding whose setter routes through the portal host
   invalidator and suppresses the owning-view invalidation.
2. Decide the API story (keep the `isPresented:` binding spelling but change its
   backing, vs a new imperative entry point).

Impact: **partial** (256→166 in the synthetic case; the reused share is the
unchanged content). Smaller and more localized than Option A.

Risk: **medium.** Confined to the presentation subsystem. Main hazard is the
overlay still re-resolving plus any content that legitimately reads presentation
state. Does not help non-presentation ancestor-state changes.

### Option C — Opt-in memoized / `Equatable` view boundary

Add a `View`-level reuse boundary (à la SwiftUI `EquatableView` / `.equatable()`
or an explicit "stable subtree" marker) that lets an author assert a subtree may
be reused across ancestor invalidation when its inputs compare equal. The
Gallery would wrap the `TabView` in it.

Required work: new public primitive + the equality/identity plumbing to gate
reuse on it inside `reusableSnapshot`; documentation of the correctness contract
(the same binding/closure caveat as Option A, pushed onto the author).

Impact: **medium**, opt-in only (helps where adopted).

Risk: **medium-high.** Moves the stale-rendering correctness burden to authors;
easy to misuse. Net-new public surface (note the repo's `AnyView`/public-surface
policy in `swift-tui/docs/PUBLIC-API.md`).

## 8. Recommendation

If/when this is picked up:

1. **Validate against the real Gallery first** via the coordination overlay
   (`bazel run //:open_overlay -- --print-env examples`), opening the palette
   while a *heavy* tab (Life / Physics / Animations) is selected, with
   `SWIFTTUI_PROFILE=frames;summary`. The synthetic fixture here uses light tabs
   and likely understates the real open cost; confirm the magnitude before
   committing to a framework change.
2. **Prefer Option B** as the first increment: it is contained to the
   presentation subsystem, has no new general-purpose reuse semantics, and the
   identity relationship that makes it work is already in place. It gives a
   partial but real win with bounded risk.
3. **Treat Option A as the long-term fix** (it is the only one that also speeds
   tab switches and other ancestor-state changes), gated behind a thorough
   read-tracking test suite, since its failure mode is silent stale rendering.
4. Avoid Option C unless an explicit author-controlled boundary is wanted for
   other reasons; it externalizes the correctness risk.

## 9. Validation plan (whichever option)

- Keep `ResolveReuseAncestorInvalidationTests` green; it encodes the invariant
  any reuse change must not break.
- Add resolve-work assertions (`diagnostics.work.resolvedNodesComputed` /
  `resolvedNodesReused`) for: open palette, close palette, type in palette, tab
  switch — asserting the unchanged subtree is reused and the changed parts are
  not.
- Add fixture coverage for the stale-render hazard: a descendant that reads an
  ancestor binding/closure/environment value must still recompute when that
  value changes under ancestor invalidation.
- Re-run the open/type/close scenarios in release and confirm the resolve phase
  drops for the open.

## Appendix A — Already shipped (separate from this proposal)

`swift-tui-examples/gallery/Sources/GalleryDemoViews/CommandPalette.swift`:
`matches` (the fuzzy filter + sort over all commands) was recomputed ~15× per
body evaluation — once per visible row via `effectiveSelectedIndex`, plus in
`matchKeys` / `visibleRange` / `selectedIndex` — i.e. O(visibleRows × commands)
per keystroke. It now computes once per body evaluation and threads the result
and the selected index through. Correct at the current 18 commands; matters as
command count grows. This is independent of the open cost above.

## Appendix B — Reproduction artifacts

- The interactive `RunLoop` probe and the release micro-benchmark were
  throwaway and are not committed. The benchmark shape: a path dependency on the
  `swift-tui` submodule, the Gallery-shaped fixture from §3, and
  `DefaultRenderer().render(view, context: .init(identity:environmentValues:invalidatedIdentities:), proposal:)`
  with `.diagnostics.work` / `.diagnostics.timing.phaseTimings` read back. It
  can be recreated from this description if needed.
