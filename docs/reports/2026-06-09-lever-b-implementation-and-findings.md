# Sheet-Open Latency — Lever B Implemented; Root-Cause **Corrected**

**Date:** 2026-06-09
**Status:** Lever B (presentation-trigger split) **implemented and
mechanism-proven**, behind the existing `SWIFTTUI_READER_ATTRIBUTION` flag
(default off). **The sheet-open win does NOT materialize**, and end-to-end
measurement **corrects the root-cause diagnosis** in
[`docs/plans/2026-06-09-001-sheet-open-reader-attribution-plan.md`](../plans/2026-06-09-001-sheet-open-reader-attribution-plan.md).
**Nothing pushed. Flag NOT flipped. Pins NOT bumped.**
**Code:** `SwiftTUI/swift-tui` branch `perf/sheet-open-reader-attribution`
(`c710bbf5`).

---

## TL;DR

- Lever B is built correctly and proven at the graph level: the `isPresented`
  read now attributes to a zero-size **sibling trigger leaf**, and invalidating
  only that leaf **does** spare the background (reuse). Flag-off is byte-identical
  to before; the full repo gate is green flag-off.
- **But it buys nothing for sheet-open.** Measured `resolve_ms` for the standard
  `.paletteSheet` is **flag-on ≈ flag-off** at every tree size (linear in
  background size). The flag makes no measurable difference.
- **Corrected root cause:** the **OPEN transition itself re-resolves the entire
  background**, independent of (a) the reader-attribution flag and (b) where the
  toggle button lives. The `@State`-owner attribution that Lever A+B fixes is
  **real but not the binding constraint** for open latency.
- **The spike was misleading.** It renders the overlay *inline as a sibling* and
  never exercises the real presentation portal/overlay machinery, so it never
  pays the open-time background re-resolve. Its flat `resolve_ms` does not
  generalize to the real `.sheet`/`.paletteSheet` API.

## What landed (swift-tui `c710bbf5`, flag-gated, default off)

- `Sources/SwiftTUIViews/Presentation/PresentationTriggerLeaf.swift` — a
  zero-size `PrimitiveView` leaf that is the sole reader of `isPresented` and
  carries the presentation-coordinator declaration as a preference, plus a shared
  `resolvePresentationModifier(...)` helper that branches on
  `ReaderAttributionConfiguration.isEnabled`.
- `PresentationModifiers.swift` — prompt / sheet / paletteSheet route through the
  helper. Flag-off path is unchanged (no wrapper, no trigger). Flag-on path
  resolves the background at `context.child(.named("base"))`, resolves the
  trigger at `context.child(.named("__presentationTrigger"))`, and returns a
  wrapper at `context.identity` parenting `[background, trigger]` as disjoint
  siblings.
- Tests:
  - `PresentationTriggerAttributionTests` (SwiftTUIViewsTests) — flag-on, the
    `isPresented` dependency lands **only** on the trigger leaf; flag-off, on the
    owner subtree.
  - `PresentationTriggerSplitTests` (SwiftTUITests) — trigger is a disjoint
    sibling; background identity is stable across open/close (consistent
    path-shift); **invalidating only the trigger spares the background**
    (`resolvedNodesReused > 0`) while invalidating the owner does not
    (`== 0`); flag-off introduces no trigger leaf.

Popover and toast were intentionally **not** split (popover's focus move is the
deferred `isFocused`-snapshot blocker). Given the finding below, that scope was
the right call — extending Lever B further would not help either.

## Evidence (measured, release, `sheet-open-latency`, async, 8 iterations)

### `resolve_ms` on transition frames — standard `.paletteSheet`

| rows | flag OFF (mean / max) | flag ON (mean / max) |
| --- | --- | --- |
| 44  | 7.5 / 11.2  | 8.1 / 11.7  |
| 176 | 29.0 / 43.3 | 29.7 / 43.6 |
| 704 | 128.0 / 197 | 123.5 / 177 |

Flag-on tracks flag-off within noise and stays **linear** in background size.
(Compare the spike: ~flat ≈ 6→5→21 ms — but see below for why that is not
comparable.)

### Reuse decode (`draw_nodes` distinguishes overlay-open from -closed)

`draw_nodes ≈ 894/895` = overlay **closed**; `≈ 921/922` = overlay **open**.

- **Standard, flag-on:** every frame `resolved_reused ≈ 0` — open *and* closed.
  The whole background recomputes each frame. `focus_syncs = 0`, `invalidated =
  1–4` (small) — so the small invalidation set is correct, yet the tree fully
  recomputes anyway.
- **Toggle button moved to a sibling (pure-static background), flag-on:** the
  **closed/idle** frames warm up (`computed ≈ 19`, `reused ≈ 880`), but the
  **open** frames (`draw_nodes = 922`) stay **cold** (`reused ≈ 0`). Flag-on and
  flag-off are nearly identical in this configuration too.
- **Spike (inline overlay, no portal), flag-off and flag-on:** every frame after
  the cold start is warm (`computed ≈ 17–26`, `reused ≈ 880`), opens included —
  because the overlay is a plain inline sibling and the background is never
  touched by any portal/overlay composition.

### Controlled unit test (deterministic, `renderer.render` with explicit invalidation)

Resolve closed → resolve open with `invalidatedIdentities = [triggerIdentity]`:
the background **is reused** (`resolvedNodesReused > 0`). With
`invalidatedIdentities = [ownerIdentity]`: it is **not**. So Lever B's mechanism
is sound *when the invalidation is actually isolated to the trigger* — which it
is at the graph level. The live open nonetheless re-resolves the background, so
**something at open time broadens the effective re-resolution beyond the isolated
trigger.**

## Interpretation

1. Lever A + Lever B do exactly what they were designed to do (verified at the
   graph and reuse level).
2. They do not move sheet-open latency because the **open transition
   re-resolves the background through the real presentation machinery**,
   independent of the `@State` dependency's attribution and independent of the
   toggle button's placement.
3. The plan's spike validated the *wrong proxy*: an inline sibling overlay that
   bypasses the portal. The plan's §6 claim "Portal is NOT a blocker" is
   **contradicted by direct measurement** — opens are cold even with Lever A+B
   active and the button outside the background.

## Leading hypothesis for the open-time re-resolve (NOT yet confirmed)

The controlled render reuses the background when invalidation is isolated, but
the live open does not — so the live open must either (a) flip an
**environment-snapshot value propagated across the whole background** when the
overlay opens (`ViewNode.canReuse` requires `committed.environmentSnapshot ==
environment`, so any background-wide env change fails reuse for every node), or
(b) drive **runtime-reader reuse-suppression** broadly (`effectiveSuppresses-
RetainedReuse`). `focus_syncs = 0` rules out the focus-snapshot path for palette
specifically, so a non-focus env value (interaction gate / "presentation active")
or the suppression path are the prime suspects.

## Recommended next step (for the human to scope)

Instrument **one live open frame** to capture what re-resolves the background
beyond the isolated trigger:

1. Log, per node on the open frame, why `canReuse` returns false — split into
   `environmentSnapshot !=` vs `invalidated/conflict` vs
   `effectiveSuppressesRetainedReuse`.
2. If it is an env-snapshot change: identify which environment value flips across
   the background on open (interaction gate, presentation-active, etc.) and make
   it runtime-derived / excluded from the reuse snapshot (mirroring the
   previously-considered `RuntimeDerivedEnvironmentKey` exclusion for
   `IsFocusedKey`, but for the palette's actual value), then re-measure.
3. Re-validate against the **real** `.paletteSheet` (not the inline spike). A
   replacement spike should toggle a real `.paletteSheet`, not an inline overlay.

Only once the open-time re-resolve is removed does Lever B's
background-sparing become the *binding* improvement — at which point flipping
`SWIFTTUI_READER_ATTRIBUTION` on (and re-baselining the presentation fixtures,
per the plan §7.3) is justified.

## State / reversibility

- swift-tui `c710bbf5` on `perf/sheet-open-reader-attribution`, **unpushed**.
  Flag-off = byte-identical; repo gate green flag-off.
- TermUIPerf spike harness retained (`2db5b6d8`) but reinterpreted: it measures
  an inline-sibling proxy, not the portal path.
- Org pin NOT bumped; flag NOT flipped.
