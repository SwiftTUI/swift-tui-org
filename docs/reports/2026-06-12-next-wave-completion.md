# Next-Wave Completion: Sheet Calibration, Part A, Commit Diagnosis, Popover Split

- **Date:** 2026-06-12
- **Status:** All remaining ranked items of the
  [2026-06-10 assessment](../plans/2026-06-10-001-perf-workstream-assessment-next-wave-proposal.md)
  are closed. `swift-tui` commits: `2b05d0fa` (calibration + Part A),
  `e9b9d00e` (popover split). Probe archive refreshed at the org root.
- **Conditions:** release `TermUIPerf`, same-session A/B per item, M5 Max.
  Full repo gate green after each landing.

## Item 3 — De-amplified sheet calibration variant

`TERMUI_PERF_SHEET_TRIGGER=sibling` keeps the real `.paletteSheet`
presentation but hosts the open-sheet trigger in a container that is a
sibling of the grid (real apps keep triggers in chrome). rows=176, pre-Part-A:

| metric | co-located | sibling | amplification share |
| --- | ---: | ---: | --- |
| resolve_ms | 17.79 | 10.28 | −42% |
| measure_ms | 7.04 | 3.45 | −51% |
| pipeline_ms | 35.30 | 23.49 | −33% |

**Calibration verdict:** ~⅓ of the measured settle residual was scenario
amplification, but the de-amplified shape still computed ~336 nodes/frame —
far above the O(2-leaf) floor — so Part A's real-world payoff remained large
and worth its validation cost.

## Item 4 — Part A: `isFocused` out of the reuse snapshot

`isFocused` becomes a stored side-field mirroring `_focusedIdentity`
(invisible to the `EnvironmentSnapshot` compare), and
`runtimeFocusStateDependencyKey` maps `\.isFocused` → `FocusedIdentityKey`,
so `EnvironmentReader(\.isFocused)` readers are invalidated through the
runtime focus dependency instead of tree-wide env-mismatch. `IsFocusedKey`
removed. Safe **only** post-Part-0: the orphaning fix is the real rescuer
the one-shot cone-bake mask was incidentally providing — the three
`InteractiveRuntimeTests` scroll guards now pass unmasked.

Results (rows=176 sheet, same session vs item 3's runs):

| metric | co-located | sibling |
| --- | ---: | ---: |
| resolve_ms | 17.79 → 9.77 (**−45%**) | 10.28 → 7.97 (−23%) |
| measure_ms | 7.04 → 2.53 (**−64%**) | 3.45 → 2.20 (−36%) |
| total CPU | 1.932 → 1.369 (**−29%**) | 1.463 → 1.322 (−10%) |

Bonus: `synthetic-narrow-invalidation` rows=40 improved too — total CPU
0.2788 → 0.2496 (−10%), resolve −26%, computed 19.4 → 17.0 — the cone bake
had been silently costing reuse on ordinary interaction frames.

**Pitfall hit twice:** `EnvironmentValues` grew a stored field; stale
`.build` object files (main package debug tests AND `Tools/TermUIPerf`'s own
build dir) crash with SIGBUS/SIGSEGV in `outlined destroy of ResolveContext`
until cleaned. Same class as the documented TermUIPerf stale-skew trap.

## Item 5 — Transition-frame `commit_ms` diagnosis

Probe rebased onto `2b05d0fa` (archive refreshed:
[docs/perf/commit-ms-breakdown-probe](../perf/commit-ms-breakdown-probe/probe.patch));
run on `sheet-open-latency` rows=176:

```
commit_ms = finalize 0.99 + txn 5.86 + plan 0.0008 (ms, mean/frame)
txn       = graphRegistrations 5.79 + observation 0.07 + portal ~0 + animation ~0
publication mode: all=149 of 258 frames (58%), subtrees=109, unchanged=0
```

**Finding: the registration pathology is confirmed — the G3a/G11 deferral's
sanctioned revisit condition is MET.** The 2026-05-31 registration-restore
scoping (Fix 2, ~97% scoped on narrow frames) does not engage on sheet
frames: their invalidation sets contain unmapped (presentation) identities →
`selectiveDirtyEvaluationPlan()` returns nil (root-evaluation fallback) →
`ViewGraphFrameDraft.recordDirtyEvaluationPlan(nil)` → publication `.all` →
full-tree `commitRuntimeRegistrations` at ~5.8 ms/frame. With Part A landed,
commit is now ~20% of the sheet pipeline and the single largest unattacked
share. **Next-wave candidate:** scope registration publication on
root-evaluation frames (diff-based or G3a/G11 index-patcher territory) — its
own design + perf-validated PR.

## Item 6 — Popover presentation-trigger split (Lever B complete)

`resolvePresentationModifier` generalized with an `isActive` closure (read
inside the trigger leaf's `ViewNodeContext`); all three popover modifiers
routed through it. The tip popover moves only the hot `isPresented` read —
its one-shot dismissal `@State` stays at the background (moving a `@State`
read across contexts would rebind its slot; dismissal is rare). Landed
directly on the flag-ON path with four new trigger-split test cases.

rows=176, `TERMUI_PERF_SHEET_OVERLAY=popover`, same session:

| metric | before | after |
| --- | ---: | ---: |
| resolve_ms | 18.70 | 11.53 (**−38%**) |
| pipeline_ms | 33.95 | 25.65 (**−24%**) |
| computed / reused | 692 / 46 | **356 / 378** |

The background now reuses across popover toggles — the lever-B reuse shift,
verbatim.

## Plan state

All six open ranked items of the 2026-06-10 assessment are closed (1-2 on
06-10/11; Part 0 + corrections, 3, 4, 5-diagnosis, 6 on 06-12). Remaining
recorded work is the sized-by-probe bucket — now led by the item-5 finding
(root-evaluation registration scoping) and the previously recorded
resolve residuals (`restoreRuntimeRegistrations` walk, `reusableSnapshot`
gates, frontier narrowing co-designed with island freshness) — and the
§5 gaps register (profiling product, memory budget, real-terminal
validation, body re-evaluation cost).
