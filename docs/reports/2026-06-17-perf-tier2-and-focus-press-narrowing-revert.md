# Tier 2 Perf Cleanup + Focus/Press Narrowing Revert

- **Date:** 2026-06-17
- **swift-tui:** `c320a243` → `179ca242` (org root pin bumped accordingly)
- **Plan:** [2026-06-17-001-perf-tier2-constant-factor-cleanup-plan.md](../plans/2026-06-17-001-perf-tier2-constant-factor-cleanup-plan.md)

## Summary

Executing the Tier 2 cleanup surfaced a pre-existing **red gate at `c320a243`**:
two framework tests failed independent of the Tier 2 work. A bisect traced both
to **`e25b1d06` "Narrow focus press dirty-frontier evaluation"** (the focus/press
dirty-frontier lever). Given that commit had **two correctness regressions** and
its own A/B was **mixed-to-negative** (it made the sheet path worse on input p95
/ CPU), it was **reverted** (`e25b1d06` + its follow-up `d9065efe`). Three Tier 2
constant-factor wins landed on the clean baseline. Items 1, 3b, and 0a were
deferred/closed with recorded reasons.

## The revert (regression investigation)

**Bisect:** `78fb9f4c` (parent of `e25b1d06`) — both suites green. `e25b1d06` —
both red (3 issues). `d9065efe` did not fix them; they persisted through
`c320a243`.

**Failures:**
- `AnyViewResilienceTests` "focusable descendant inside AnyView remains
  reachable" — a focusable button's action registration was not republished into
  a fresh registry on re-render (`dispatch` returned false).
- `InteractiveRuntimeTests` "state-aware builder exposes scroll indicators and
  text input cursor" — a **captured framework runtime issue** on the single
  render path (no `#expect`/`#require` failure line anywhere in the gate log).

**Root cause:** `e25b1d06` removed `guard !invalidatedNodeIDs.isEmpty` from
`selectiveDirtyEvaluationPlan` (`ViewGraph.swift`) and
`ViewGraphDirtyEvaluationPlanner.targetPlan` so finite focus/press scopes queued
as graph-local dirty could form a selective plan. That guard was **load-bearing
beyond its stated purpose**: it forced graph-local-dirty-only frames onto `.all`
publication. Without it those frames took scoped `.subtrees` publication, which
**cannot reach capture-hosted islands** (AnyView shells, deferred/lazy content) —
so their high-volume action/focus/scroll registrations were dropped. The
existing `republishAllEffectRegistrations` patches the island gap only for the
low-volume effect registries.

**Decision — revert, not fix-forward.** A scoped option-2 fix (force `.all`
publication on graph-local-dirty-only frames) resolved the AnyView regression and
kept registration byte-identity green, but the InteractiveRuntime regression was
a second, distinct single-render runtime-issue not covered by it. With two
regressions in the highest-blast-radius seam and no proven perf win, reverting
`e25b1d06` + `d9065efe` was the correct call. Post-revert the **full gate is
green**.

**If the narrowing is revisited:** it must ship with capture-host island
coverage in scoped publication (the option-1/2 fix) **and** a fix for the
single-render runtime issue, plus the two regression tests above as guards —
before landing. The prior audit already judged the lever necessary-but-not-
sufficient and mixed on perf, so this is a design item, not a quick reland.

## Tier 2 wins landed (`179ca242` and parents)

| commit | item | what | verification |
| --- | --- | --- | --- |
| `a82b7d46` | 4 | skip `restoreOwnRuntimeRegistrations` for handler-less nodes (guard on `hasRuntimeRegistrations`) | byte-identity `RuntimeRegistrationRestoreScopingTests` + `TabTaskActivationRuntimeTests` |
| `71864661` | 3a | build the `.all`-frame registration fingerprint once (reuse the delta-check result for the commit record) | byte-identity registration equivalence suite |
| `179ca242` | 2a | skip the `accessibilityWarnings` full-tree walk in `.tui` output (gated `SemanticExtractor`); never gates `accessibilityNodes`/`scrollTargets`/`focusRegions` | new `AccessibilityNodeExtractionTests` no-op test + `LinearAccessibilityRendererTests` |

**A/B (same-session, stash baseline vs candidate, release):** sub-ms changes are
noise-dominated (canary `narrow-40` swung ±8%); the one clean, mechanistically
attributable signal was **`commit_ms` −34% on sheet-44 / −14% on
text-input-editing** — the `.all`-publication frames Item 3a targets. Correctness
rests on the byte-identity suites, which is the right evidence for constant-factor
work. The full repo gate is green.

## Deferred / closed

- **Item 1 (`processResolvedTree` idle skip) — DEFERRED.** The only "tree
  unchanged" check available is O(N) deep `ResolvedNode` equality; the
  representative scenarios never animate, so the gate would add an O(N) compare
  before a walk that still runs on every changed interaction frame —
  net-negative. Needs an O(1) no-dirty-work signal plumbed from the head
  coordinator first.
- **Item 3b (guard `republishAllEffectRegistrations`) — NO-GO.** The
  effect-registry sink is reset externally between commits (the public
  `DefaultRenderer` path), so a graph-side generation guard fails open and would
  silently drop `onAppear`/task/preference handlers. Only 3a (the safe de-dup)
  landed.
- **Item 0a (aggregate tail-phase columns) — NOT DONE.** Measurement infra only;
  the A/B used per-frame `frames.tsv` parsing instead. Cheap follow-up if future
  A/Bs want aggregate-gated tail-phase metrics.

## Forward note

The dominant *representative* cost identified by the audit — resolve+measure
reuse-denial on selection/collection frames (`canReuse` has no output-equality
path; container `@State` fans out to every item) — remains the **Tier 1**
architecture design item and is untouched here.
