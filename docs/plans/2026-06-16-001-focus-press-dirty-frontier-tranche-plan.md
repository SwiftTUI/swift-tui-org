# Focus/Press Dirty-Frontier Tranche Plan

- **Date:** 2026-06-16
- **Starting root:** `defde46`
- **Starting `swift-tui`:** `78fb9f4c`
- **Entry report:** `docs/reports/2026-06-16-perf-tranche-diagnostics-start.md`

## Goal

Reduce the remaining `sheet-open-latency` head-prep gap by removing the
unnecessary root-evaluation hammer from finite focus/press reuse-safety frames.
The runtime must still recompute every node that reads focus/press environment
state, plus the previous/current focused or pressed controls, but it should let
dirty-frontier planning choose those roots instead of forcing the whole root
tree.

## Current Evidence

The tranche-start diagnostics show:

- rows=176 sheet co-located remains slower than sibling primarily in
  `head_prepare_p50_ms` and checkpoint restore, not checkpoint creation alone.
- both sheet variants report selective evaluation disabled by
  `frame_state_force_root`, `focus_changed`, and `pressed_changed`.
- the new `example-app-shell-workflow` signal is stable and restore-heavy, but
  its checkpoint fallback is a second-order follow-up after the focus/press root
  gate is narrowed.

## Implementation Scope

1. Keep hard root blockers unchanged:
   - explicit frame/context root evaluation
   - proposal changes
   - root invalidation
   - identity-agnostic retained-reuse suppression (`.all`)
2. For finite focus/press safety scopes:
   - do not call `forceRootEvaluation()` solely to make those identities
     reachable.
   - still pass the suppression scope into resolve so affected nodes skip
     retained reuse once reached.
   - queue the finite safety identities as graph-local dirty work alongside the
     normal invalidation set.
3. Preserve focus-sync rerender behavior. Convergence rerenders may continue to
   force root until separately proven safe.

## Tests

Add targeted correctness coverage in `swift-tui`:

- `FrameResolveState` should allow selective evaluation when the only extra
  safety input is finite retained-reuse suppression.
- runtime rendering should recompute focus/press environment readers and the
  previous/current focused or pressed identities without forcing root
  evaluation.
- existing retained-reuse suppression behavior should continue to recompute the
  suppressed identity while allowing unaffected siblings to reuse.

## Measurement

After the child commit, rerun the same release diagnostics from the tranche
start report and write a follow-up report:

- `sheet-open-latency`, rows=176, co-located trigger
- `sheet-open-latency`, rows=176, sibling trigger
- `example-app-shell-workflow`

Decision rule: if sheet frames stop reporting `frame_state_force_root` for
ordinary focus/press safety and head-prep narrows without correctness
regressions, continue this line. If checkpoint restore remains dominant,
split a later checkpoint-policy tranche validated by `example-app-shell-workflow`.
