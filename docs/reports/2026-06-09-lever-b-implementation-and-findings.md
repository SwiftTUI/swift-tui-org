# Sheet-Open Latency — Lever B Implemented; Root-Cause **Corrected**; **OPEN Resolved (2026-06-10)**

**Date:** 2026-06-09 (resolution appended 2026-06-10)
**Status:** **RESOLVED for the OPEN transition.** The dominant ~63%
`invalidation-conflict` blocker was the `@State` **write-side** invalidating the
slot *owner* identity — the half of owner-attribution that Lever A never fixed.
Completing it (write-side reader attribution, `0cbc2930`) makes the open reuse
the background; the flag is now **flipped ON by default** (`72e0ddf4`). See the
**RESOLUTION** section below; the original-day findings follow for the record.
**Code:** `SwiftTUI/swift-tui` branch `perf/sheet-open-reader-attribution`
(head `72e0ddf4`). Nothing pushed; org pin not yet bumped.

---

## ✅ RESOLUTION (2026-06-10) — the ~63% was the @State WRITE-side, not `rootIdentity`

The "DEFINITIVE 3-WAY DIAGNOSIS" below **mis-attributed** the dominant blocker.
A temporary `[STATE-WRITE]` + `[INVAL-SRC]` trace (built on `ReuseDenialTrace`,
since removed) showed the open click does **NOT** invalidate `rootIdentity` from
input dispatch — those `[rootIdentity]` sites are key/paste-guarded, and the
mouse path uses *scoped* `postActionInvalidationIdentities` /
`scrollPointerInvalidationIdentities`. The `…/Layout[0]` invalidation was the
**`@State` write**: `ViewNode.setStateSlot` always did
`requestInvalidation(of: [invalidationIdentity ?? identity])`, and
`State.setValue` passes `invalidationIdentity = context.viewIdentity` = the slot
**owner**. Because `conflictsWithInvalidation` is symmetric, invalidating the
owner blocks the whole background as an ancestor. **Flag-independent because
Lever A only fixed the read/dirty side** (`stateChangeDirtyNodeIDs` drops
`∪{owner}`), never the write-side invalidation.

**Fix (Lever A completion, `0cbc2930`):** flag-on, `setStateSlot` invalidates the
genuine recorded readers (`ViewGraph.stateDependentIdentities(for: key)`),
falling back to the owner only when no readers were recorded. Flag-off
byte-identical. A cross-checking workflow (dispatch + machinery agents)
independently confirmed the mechanism; they assumed it required a topology
change, but the reader set Lever A already populates makes it a **localized write
re-target** — no ownership move. New write-side `ReaderAttributionTests` prove
flag-on→reader, flag-off→owner.

**Measured (release, async, 8 iters):** open `invalidation-conflict` **888 → 5**;
all 8 `@State` writes (open + close) invalidate `{__presentationTrigger}`;
background reused on open; **CPU/frame −9.0%/−8.1%**, **p95 latency −9.9%/−8.3%**
at rows 176/704. Win does not *scale* with tree size because only ~1 of ~3
expensive frames per cycle (the open's `@State` frame) is fixed.

**Flag flipped ON by default (`72e0ddf4`):** gate green with the new default
(rendered-text fixture matrix unchanged — the trigger leaf is layout-inert).
`SWIFTTUI_READER_ATTRIBUTION=0` is the opt-out.

**RESIDUAL (in progress) = FOCUS, not @State.** The close + open-focus-move
`conflict=890` frames re-resolve the background because focus lands on the
background's *container* `VStack[0]` (an ancestor of the grid): `FocusTracker`
invalidating the focus **identity** drives the conflict, and `contextualEnvironmentValues`
propagating `isFocused` to that container's whole descendant cone drives the
`IsFocusedKey` env-mismatch. The coupled next fix: (1) derive `\.isFocused` via
the `FocusedIdentityKey` runtime-focus dependency + exclude `IsFocusedKey` from
the reuse snapshot (Report 3's *safe* path — the naïve snapshot-exclusion
regressed `InteractiveRuntimeTests` before), then (2) narrow `FocusTracker` to
invalidate `isFocused` readers, not the focus container. **Lever #3 (suppression
cone) is retired** as a non-starter (recovers ~0; ancestor leg can't be deleted —
reintroduces the `fcb1a531` stale-focus regression; `suppressed` is logged before
`invalidation-conflict`, so double-counted, not independently recoverable).

---

### Original 2026-06-09 findings (for the record — partially superseded above)

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

## CONFIRMED: the open-time re-resolve has THREE overlapping causes

Added an env-gated reuse-denial trace (`SWIFTTUI_REUSE_TRACE`, swift-tui
`2e36a922`) that records, per recomputed node, *why* retained reuse was denied,
plus the offending environment keys and invalidated identity paths. Ran the
standard `.paletteSheet` open flag-on (8 rows, async). Aggregate denial reasons:

| reason | count | share | meaning |
| --- | --- | --- | --- |
| `invalidation-conflict` | 4978 | **~63%** | node is an ancestor/descendant of an invalidated identity |
| `env-mismatch` | 1374 | ~17% | `committed.environmentSnapshot != environment` |
| `suppressed` | 1365 | ~17% | `effectiveSuppressesRetainedReuse` (focus/press cone) |
| no-node / visited / dirty / stale / not-present | small | — | cold-start + normal churn |

- **`invalidation-conflict` (the #1 blocker).** The invalidated identity the
  background conflicts with is **`App/sheet-open-latency/Layout[0]`** — the
  app-content root (the renderer's `rootIdentity`), an **ancestor of the entire
  background**. So the whole background (every descendant) is blocked on open.
  (The `…/PortalHost/overlays/entry:SheetPresentation:…` invalidations are the
  overlay itself — a separate subtree that does *not* block the background.)
  **This root invalidation is flag-INDEPENDENT**: running the trace flag-off
  shows `…/Layout[0]` invalidated on exactly the same open frames (only the
  background's own path differs — `…/Layout[0]/false/content/…` flag-off vs
  `…/Layout[0]/false/base/content/…` flag-on, the Lever B `base` wrapper). So
  this is **not** the `@State`-owner attribution Lever A+B fixes — it is a
  separate, root-level invalidation on the open/close action (candidates: the
  runtime's input-dispatch root invalidation — `RunLoop+EventDispatch`/
  pointer-activation requests `requestInvalidation(of: [rootIdentity])` on
  handled input — and/or presentation reconciliation). **Plan §6 "Portal is NOT a
  blocker" is contradicted, and the plan's whole "owner-anchored `@State`" thesis
  is shown non-binding here.** (Flag-on recompute counts are even slightly
  *higher* than flag-off — the Lever B wrapper adds nodes — consistent with the
  measured flag-on ≈ flag-off.)
- **`env-mismatch` is dominated by `IsFocusedKey`** (1283 of 1374 env-diffs;
  `ForegroundStyleKey`/`style` are minor). Opening moves focus → `isFocused`
  flips across the focused node's ancestor/descendant cone → the env snapshot
  differs → reuse denied. **This is the §8 `isFocused`-snapshot blocker, and it
  DOES bite palette** (the earlier `focus_syncs = 0` reading was misleading — the
  snapshot still changes even when the focus-sync counter is 0).
- **`suppressed`** is the focus/press runtime-reader suppression cone
  (`retainedReuseSuppressionScopeForFrameSafety`), whose `suppresses(identity:)`
  covers the entire ancestor+descendant cone of each focus/press identity.

## Recommended fix path (prioritized by measured weight)

Sheet-open latency needs **all three** addressed; in weight order:

1. **(~63%) Stop the root-level `…/Layout[0]` (`rootIdentity`) invalidation from
   blocking the background.** Confirmed flag-independent, so this is the highest
   lever and is *not* what Lever A+B addresses. Immediate next step: add an
   **invalidation-source trace** (mirror `ReuseDenialTrace`: log the caller +
   identity for each `scheduler.requestInvalidation`) to pin which call
   invalidates `rootIdentity` on the open `sendClick`. Prime suspects, in order:
   (a) the runtime's input-dispatch root invalidation —
   `RunLoop+EventDispatch.swift:56/82/108/139` and the pointer-activation path
   both do `requestInvalidation(of: [rootIdentity])` after a handled event; (b)
   presentation reconciliation / `PresentationCoordinatorStorage.swift:301`. If
   it is (a), the fix is to scope the post-input invalidation to the handler's
   subtree instead of the whole root (big, general win beyond presentations). If
   (b), narrow the presentation invalidation to the overlay subtree.
2. **(~17%) Exclude `IsFocusedKey` from the reuse environment snapshot** — the
   previously-prototyped `RuntimeDerivedEnvironmentKey` exclusion (route
   `\.isFocused` reads via `FocusedIdentityKey` deps). It regressed a
   WindowGroup/TabView external-binding ScrollView before
   (`InteractiveRuntimeTests`), so re-derive carefully and gate on the full
   scroll suite.
3. **(~17%) Narrow the focus/press suppression cone** so it does not suppress an
   entire disjoint background when focus moves into an overlay.

Re-validate against the **real** `.paletteSheet` with `SWIFTTUI_REUSE_TRACE=1`
(watch the three buckets shrink), not the inline spike. Only once the background
actually reuses on open does Lever B's sparing become binding — then flipping
`SWIFTTUI_READER_ATTRIBUTION` on (and re-baselining presentation fixtures, plan
§7.3) is justified.

## State / reversibility

- swift-tui `c710bbf5` on `perf/sheet-open-reader-attribution`, **unpushed**.
  Flag-off = byte-identical; repo gate green flag-off.
- TermUIPerf spike harness retained (`2db5b6d8`) but reinterpreted: it measures
  an inline-sibling proxy, not the portal path.
- Org pin NOT bumped; flag NOT flipped.
