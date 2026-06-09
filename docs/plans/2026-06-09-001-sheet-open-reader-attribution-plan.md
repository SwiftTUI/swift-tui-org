# Sheet / Command-Palette Open Latency — Reader-Attribution Re-architecture

> **⚠️ SUPERSEDED IN PART (2026-06-09).** Lever B was implemented and is
> mechanism-proven, but **the win does not materialize** and this plan's
> root-cause diagnosis is **corrected** by
> [`docs/reports/2026-06-09-lever-b-implementation-and-findings.md`](../reports/2026-06-09-lever-b-implementation-and-findings.md).
> In short: the **OPEN transition re-resolves the background regardless of the
> flag**, so `@State`-owner attribution (Levers A+B) is real-but-not-binding;
> the spike (§4) measured an *inline-overlay proxy* that bypasses the portal and
> does **not** generalize to the real `.sheet`/`.paletteSheet`. Read the report
> first. Levers A+B remain landed and flag-gated-off as a proven foundation; the
> flag is NOT flipped and pins are NOT bumped.

**Date:** 2026-06-09
**Status:** Foundation (Lever A) landed behind a default-off flag; Lever B
(presentation-trigger split) + validation/fixture work remain. This is the
**authoritative pickup doc** — it supersedes the "recommended next step" in
[`docs/reports/2026-06-09-sheet-open-latency-investigation.md`](../reports/2026-06-09-sheet-open-latency-investigation.md)
(which proposed descendant reuse — now a proven dead end, see §3).
**Code:** `SwiftTUI/swift-tui` branch `perf/sheet-open-reader-attribution`
(`2db5b6d8`; foundation commit `ab4141f9`). **Not pushed.** Root pin NOT bumped.

---

## 1. The goal

Opening a `.sheet` / command palette is slow and the cost scales with the size
of the **background** (the now-behind app), even though the background's content
does not change when the overlay opens. Target: make sheet/palette open cost
**O(overlay)**, independent of background size.

## 2. Root cause (definitive)

It is **not** a re-raster problem, **not** a measure-drift problem, **not** a
`forceRootEvaluation` problem, and **not** a missing-reuse problem. Measured on
the `sheet-open-latency` TermUIPerf scenario (release, transition frames):
`invalidated` = 1–4 identities, `focus_syncs` = 0, yet `resolved_computed` =
237–270 with `resolved_reused` ≈ 0. A *tiny* invalidation forces a *full*
background re-resolve.

The cause is structural to SwiftTUI's **owner-anchored `@State` invalidation**:

- A `@State` write dirties `stateSlotDependents[key] ∪ {owner}`
  (`ViewGraphInvalidationPlanning.stateChangeDirtyNodeIDs`).
- State reads are attributed to the **slot owner**, not the reader:
  `ViewNode.stateSlot` records `recordStateRead` on the owner's tracker
  (`ViewNode.swift:189`), and `State.activeLocation` *eagerly* calls
  `getValue()` (`State.swift:264`) so even **projecting** `$flag` records a read
  on the owner.
- The standard `.sheet(isPresented: $flag)` API declares `@State` in the
  presenting view, which is an **ancestor of the entire background**. So
  toggling re-resolves the owning view's whole subtree = the background, because
  the descendant-blocker in `ViewGraph.reusableSnapshot`
  (`identity.isDescendant(of: invalidatedIdentity)`, `ViewGraph.swift:1099` +
  the structural mirror `:1383`) refuses to reuse anything under a dirty node.

So the invalidation is already minimal; the problem is **where the dirty nodes
sit** (ancestors of the background).

## 3. Dead ends — ruled out with evidence (do not re-attempt)

1. **Leaf-level descendant value-reuse** (a per-node `ReuseToken` that relaxes
   the descendant-blocker when the re-produced child value is byte-equal).
   Implemented, sound, and it *fires* (reused jumps from ~0 to 537/780 on the
   704-row scenario) — but **≈0 latency win**: `resolve_ms` is unchanged because
   reaching the cheap `Text` leaves still pays the full per-node descent through
   the opaque containers, and `measure` already reuses independently. It fights
   the symptom. **Stashed** at `git stash` `stash@{0}` ("leaf-reuse-token") on
   the branch; recoverable from this session's transcript if ever wanted. The
   gated raster prototype (`SWIFTTUI_OVERLAY_INCREMENTAL_DAMAGE`) is similarly a
   ~9%-slice dead end.
2. **Lever A literal — dropping the unconditional `∪{owner}` only.** A **no-op**:
   `State.activeLocation` eagerly reads on projection, so the owner is *already*
   a genuine entry in `stateSlotDependents[key]`. Dropping the union term changes
   nothing; and the term is a real safety net for deferred/conditional reads.
3. **Lever B alone** (presentation split without reader-attribution).
   Insufficient: the owner is still dirtied by `∪{owner}` + its eager projection
   read, so the background (its descendant) still re-resolves.
4. **EquatableView opt-in / bottom-up container tokens / invalidation-narrowing
   of the owner only** — each either requires author annotation, hits the
   closure-comparison wall, or doesn't move the owner. Considered, not chosen.

## 4. The spike proof (why the chosen direction is right)

A throwaway spike (`TERMUI_PERF_SHEET_SPIKE=1`, committed `2db5b6d8`,
inert by default) restructures the scenario so the toggle `@State` is owned by a
**sibling** of the background instead of an ancestor. Result (release, palette,
transition frames):

| tree size | base `resolve_ms` | spike `resolve_ms` | base reused | spike reused |
| --- | --- | --- | --- | --- |
| 44 rows | 7.7 | 6.2 | ~6 | 128 |
| 176 rows | 28.4 | 5.3 | ~6 | 832 |
| 704 rows | **119.9** | **20.6** | ~4 | 3325 |

`resolve_ms` slope: **base 8→28→120 ms (linear)** vs **spike 6→5→21 ms (~flat)**
— ~83% at 704 rows and widening. `measure_ms` cascades down for free (40→10 ms at
704). So: **own the toggle off the background's ancestor chain → the existing
reuse machinery spares the background → O(background) becomes O(overlay).**

## 5. What is LANDED — Lever A foundation (commit `ab4141f9`)

Behind `SWIFTTUI_READER_ATTRIBUTION` (env, default off; `@MainActor` test-settable
`ReaderAttributionConfiguration.isEnabled`). Three coupled changes, active only
when the flag is on:

1. **Reader-attribution** — `ViewNode.stateSlot` records the read on
   `ViewNodeContext.current` (the evaluating reader) via the new
   `ViewNode.recordStateReadDependency(_:)`, instead of `self` (the owner).
   `StateSlotKey(owner, ordinal)` still identifies the slot; only the *dependent*
   changes.
2. **Lazy projection** — `State.activeLocation` skips the eager
   `_ = location.getValue()` (`State.swift:264`), so projecting `$flag` records
   no read. A genuine `wrappedValue` read still records (via `wrappedValue.get`'s
   explicit `getValue()`), attributed to its reader.
3. **Drop `∪{owner}`** — `ViewGraphInvalidationPlanner.stateChangeDirtyNodeIDs`
   no longer unconditionally inserts `key.owner`; a projection-only owner is
   spared.

**New files:** `Sources/SwiftTUICore/Resolve/ReaderAttributionConfiguration.swift`,
`Tests/SwiftTUIViewsTests/ReaderAttributionTests.swift`.

**Validation:** `bun run test` green **flag-off** (zero behavior change) **and
flag-on** (zero regressions across all 41 suites, incl. every runtime
`@State`-mutation suite). `ReaderAttributionTests` positively proves a
projection-only owner is spared and the dependency moves to the genuine reader
(not lost). No run-loop wiring needed — the static reads the env on first access.

**Why this alone does NOT yet move the standard sheet API:** measured — standard
`.paletteSheet` at 176 rows is unchanged flag-on (resolve 27.8→27.6 ms). The
presentation modifier reads `isPresented` *at the background root*, and a
single-child body **collapses onto the owner's identity** (the probe debug saw
only `"Root"`). So owner == background-root == reader; no attribution change can
separate them. **Lever B must introduce a distinct sibling node.**

## 6. What REMAINS — Lever B (the presentation-trigger split)

Restructure the builtin presentation modifiers so `isPresented` is read by a
tiny **declarative sibling trigger leaf** that emits the overlay preference,
while the background stays pinned at `context.identity`.

- **Files:** `Sources/SwiftTUIViews/Presentation/PresentationModifiers.swift`
  (sheet / prompt / palette), `PopoverPresentation.swift`, `ToastPresentation.swift`;
  new `PresentationTriggerLeaf` view. The preference auto-combines from children
  (`ResolvedNode.preferenceValues`), and `PreferenceOverlayValueModifier`
  (`Preference.swift:215-236`) is a proven "resolve base + emit sibling" shape to
  mirror.
- **HARD invariant (biggest risk):** the background root must stay at
  `context.identity` and `sourceIdentity` must remain keyed on it. Do NOT resolve
  the background at `context.child(.named("base"))` or re-parent it under the
  trigger — that path-shifts every descendant identity (breaks
  `PresentationContinuityTests`' Base-probe assertion, popover source-frame lookup
  at `PopoverPresentation.swift:303`, overlay focus-scope identity at
  `OverlayStack.swift:79-81`) AND re-makes the background a descendant of a dirty
  node, defeating the whole point. The trigger leaf must be a **sibling**, layout-
  inert (zero-size / non-participating), and the **sole reader** of `isPresented`.
- **Palette absorption:** `BuiltinPaletteSheetPresentationModifier` reads/clears
  `PaletteCommandsPreferenceKey` off the resolved background
  (`PresentationModifiers.swift:152`). Thread that snapshot into the trigger as a
  plain VALUE, or it re-introduces a background-keyed read dependency.
- **Portal is NOT a blocker (verified):** `composeOverlayStackTree` carries the
  base by reference (`OverlayStack.swift:67`); the always-dirty portal root
  re-runs but lets disjoint descendants reuse. The background re-resolves only
  because its `@State`-owning ancestor is dirty — which Lever A+B removes.

## 7. How to finish (sequence)

1. Implement Lever B (TDD first: a test asserting the trigger-leaf identity is
   neither ancestor nor descendant of the background root).
2. Enable the flag and validate end-to-end via the spike harness: the **standard**
   `.paletteSheet` (no `TERMUI_PERF_SHEET_SPIKE`) should now match the spike —
   `resolve_ms` flat across `TERMUI_PERF_SHEET_TREE_ROWS`, `resolved_reused` ≈
   background node count, `resolved_computed` flat.
3. Re-baseline the broad-but-mechanical presentation fixtures (a
   `__presentationTrigger` node enters the resolved tree under every active
   presentation): `PresentationContinuityTests`, `OverlayStackTests`,
   `PaletteSheetAbsorptionTests`, `SurfaceDamageContractTests`, `PresentationSurfaceTests`,
   NavigationDestination tests.
4. Decide the flag's fate: flip default-on then remove the flag (the end state is
   transparent), OR keep the flag for one release. `bazel //:org_full`
   (`--nocache_test_results`) before any pin bump.

## 8. Watch-outs

- **isFocused-snapshot blocker (popover).** Opening a popover moves focus
  (`modalPolicy .disablesBaseInteraction`, `PopoverPresentation.swift:94`).
  `isFocused` is baked into `EnvironmentSnapshot`, so a focus move flips it across
  the focused node's ancestor/descendant *cone* and can fail `canReuse`'s
  `environmentSnapshot ==` along that cone. The palette case shows `focus_syncs=0`
  so it likely does not bite there; for popover it may. If so, the previously-
  reverted `RuntimeDerivedEnvironmentKey` exclusion (mark `IsFocusedKey`
  runtime-derived, exclude from the snapshot, route readers via
  `FocusedIdentityKey` deps) is the fix — but it **regressed a WindowGroup/TabView
  external-binding ScrollView** before (`InteractiveRuntimeTests` "pointer scroll
  updates the visible surface for a WindowGroup-hosted scroll pane"), so re-derive
  it carefully and gate on the full scroll suite. Consider landing sheet+palette
  first and deferring popover.
- **Deferred/conditional read soundness** under reader-attribution: covered in
  principle (the genuine reader is attributed when it resolves), but add
  adversarial tests (lazy tab content, conditional-branch reads, binding chains,
  `@GestureState`/`FocusState` — note Focus/Gesture use separate registries).

## 9. Reproduce / measure

```bash
cd swift-tui
# Spike A/B (proves the direction): base vs sibling-owned-toggle
for ROWS in 44 176 704; do for M in "" "TERMUI_PERF_SHEET_SPIKE=1"; do
  env $M TERMUI_PERF_SHEET_OVERLAY=palette TERMUI_PERF_SHEET_TREE_ROWS=$ROWS \
    swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
    run --scenario sheet-open-latency --modes async --iterations 8 --artifacts-root .perf/x; done; done
# Lever B validation (after it lands): standard .paletteSheet should match spike
SWIFTTUI_READER_ATTRIBUTION=1 TERMUI_PERF_SHEET_TREE_ROWS=704 swiftly run swift run -c release \
  --package-path Tools/TermUIPerf termui-perf run --scenario sheet-open-latency --modes async --iterations 8
```

Per-phase ms + reuse counts are ONLY in `frames.tsv` (cols: `resolved_computed`=5,
`resolved_reused`=6 as `"reused/total"`, `resolve_ms`=11, `measure_ms`=12,
`focus_syncs`=3, `invalidated`=4). Transition frames are `resolve_ms >= ~2`.

## 10. Key references

- Foundation commit `ab4141f9`; spike `2db5b6d8`; branch
  `perf/sheet-open-reader-attribution` (`SwiftTUI/swift-tui`, unpushed).
- Prior investigation: [`docs/reports/2026-06-09-sheet-open-latency-investigation.md`](../reports/2026-06-09-sheet-open-latency-investigation.md).
- Root-cause memory: `sheet-open-latency-rootcause`.
