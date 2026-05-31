# SwiftTUI `commit_ms` Sub-Phase Breakdown — Findings (measure-only)

**Date:** 2026-05-30/31
**Plan:** [`docs/plans/2026-05-30-003-perf-commit-ms-instrumentation-plan.md`](../plans/2026-05-30-003-perf-commit-ms-instrumentation-plan.md)
**Predecessor:** [`docs/reports/2026-05-30-h3-retained-subtree-findings.md`](2026-05-30-h3-retained-subtree-findings.md)
**Code:** measurement probe (`528b028e`, `8bab1fb8`) — **archived, not landed** ([`docs/perf/commit-ms-breakdown-probe/`](../perf/commit-ms-breakdown-probe/)). Measured against base `main` @ `1526e21a`.
**Scope:** Measurement only — this located the O(tree) commit cost. **No optimization was implemented here.** The fix shipped separately and is landed: see [`docs/reports/2026-05-31-commit-ms-registration-restore-fix-results.md`](2026-05-31-commit-ms-registration-restore-fix-results.md) (swift-tui `main` @ `49f2be7e`, org pin `543dfc4`).

---

## TL;DR

- **The plan's ranked hypothesis was wrong — measuring first paid off (again).** The plan
  ranked `finalizeFrame`'s `frameOrder` bookkeeping #1 and `commitPlanner.plan` #2, with
  `transaction.commit()` (#3) flagged "unknown cost; instrument it." The instrumentation
  shows the reverse: **`transaction.commit()` is ~95% of `commit_ms`** and is the
  O(tree)-scaling cost. `finalize` is ~4–5% (also O(tree), an order of magnitude smaller);
  `commitPlanner.plan` is **negligible** (~0.4 µs, flat). This is exactly the failure mode
  the plan was written to avoid: the prior reverted attempt pruned the viewport walk inside
  `finalizeFrame` for only −7…9% because it optimized the wrong sub-phase.
- **Drilling one level deeper pinpointed the exact call.** Inside `transaction.commit()`'s
  four sub-commits, **`graphDraft.commitRuntimeRegistrations(from:)` is 99.6% of `txn`**
  (observation / portal / animation are all sub-10 µs and flat). Its dominant work is
  `ViewGraph.restoreCurrentFrameRuntimeRegistrations` →
  `ViewGraphRuntimeRegistrationRestorer.restoreLiveIdentities`, which **re-publishes every
  live node's runtime registrations on every committed frame**.
- **Root cause (source-confirmed):** `restoreLiveIdentities` does
  `for identity in identities.sorted() { … }` over the **entire** live-identity set, and it
  runs **unconditionally** — after the publication-mode `switch`, regardless of
  `.unchanged` / `.all` / `.subtrees`. So the full re-publish happens every committed frame
  and, unlike resolve after H2/H3, **gets no benefit from subtree reuse**. The `.sorted()`
  over the full set (with array-comparing `Identity`) is O(n log n) and explains the slight
  super-linearity below.
- **Numbers (mean ms / committed frame, clean run, CVs ≤ 3.8%):** at rows 6/20/40,
  `graphRegistrations` = **0.292 / 1.204 / 2.407 ms** — **×8.25 over a ×6.67 node increase**
  (exactly **×2.00** across 20→40, i.e. linear in nodes with a sub-linear fixed offset).
  Reconstructed `commit_ms` ≈ **0.33 / 1.34 / 2.53 ms**, corroborating H3's reported
  ~2.45 ms residual at rows=40.

---

## Instrumentation (env-gated, `TERMUI_PERF_COMMIT_BREAKDOWN`)

Route A from the plan (lowest churn — no API/TSV/test/baseline changes), plus the plan's
anticipated **Phase-2 internal split**, redirected from `finalizeFrame` (the plan's guess)
to `transaction.commit()` (the actual hotspot):

- **`Sources/SwiftTUIRuntime/Diagnostics/CommitBreakdownProbe.swift`** (new) — `@_spi(Runners)`
  `@MainActor` accumulator; Foundation-free `getenv` gate (matches
  `RuntimeRenderMode.environmentValue`). Excluded from `docs/.public-api-baseline.txt`
  because the baseline is generated with `dump-symbol-graph --minimum-access-level public`
  (no `--include-spi-symbols`); the public-surface pre-commit guardrail confirmed PASS.
- **`DefaultRenderer+CompletedFrameCandidates.swift`** `commitFrameEffects` — the single
  `measurePhase` is split into three (`finalize` = `finalizeFrame`, `txn` =
  `commitFrameHeadDraftEffects` = `transaction.commit()`, `plan` = `commitPlanner.plan`);
  `commit_ms` is preserved as their sum (modulo the negligible gap between clock reads).
- **`FrameHeadDraftTransaction.swift`** `FrameHeadTransaction.commit()` — lap-times its four
  sub-commits (`graphRegistrations`, `observation`, `portal`, `animation`) on a single code
  path; accumulation gated by the probe.
- **`Tools/TermUIPerf/.../main.swift`** — emits the two `[commit-breakdown]` lines to
  **stderr** at run teardown (one process = one tree-size point = one aggregate).

`measurePhase` returns `.zero` when `draft.clock` is nil, so the split is a no-op on
non-profiled runs; the probe only accumulates when the env var is set.

## Sweep procedure

Scenario `synthetic-narrow-invalidation` (one narrow `@State` mutation in a large static
sibling grid that is **not** reused at this pin, so the whole tree recomputes — and
re-registers — every invalidation frame). `--modes async --iterations 20`, release. Tree
rows swept via `TERMUI_PERF_INVALIDATION_TREE_ROWS ∈ {6,20,40}` (columns fixed at 4).
Machine quiet (1-min load ≤ 2.5 at start); ~358 committed frames aggregated per point.

## Results — `commit_ms` sub-phases (mean ms / committed frame)

| tree rows | finalize | **txn** | plan | reconstructed commit | total CPU s (CV) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 6  | 0.0223 | **0.2947** | 0.0002 | 0.317 | 0.0805 (2.7%) |
| 20 | 0.0586 | **1.2100** | 0.0002 | 1.269 | 0.1591 (2.5%) |
| 40 | 0.1112 | **2.4173** | 0.0003 | 2.529 | 0.2535 (3.8%) |

Scaling 6→40 (rows ×6.67): finalize **×4.99**, **txn ×8.20**, plan flat (noise, sub-µs).
txn share of commit: **89 / 95 / 96%**.

## Results — `transaction.commit()` sub-commits (mean ms / committed frame)

| tree rows | **graphRegistrations** | observation | portal | animation |
| ---: | ---: | ---: | ---: | ---: |
| 6  | **0.2916** | 0.0017 | 0.0001 | 0.0011 |
| 20 | **1.2038** | 0.0044 | 0.0002 | 0.0014 |
| 40 | **2.4068** | 0.0081 | 0.0002 | 0.0019 |

Scaling 6→40: `graphRegistrations` **×8.25** (×2.00 across 20→40 — linear in nodes);
others sub-10 µs and effectively flat. `graphRegistrations` share of txn: **98.9 / 99.5 /
99.6%**; of `commit_ms`: **92 / 95 / 95%**.

**Consistency checks.** The four laps sum to `txn` within rounding at every size (e.g.
rows=40: 2.4068 + 0.0081 + 0.0002 + 0.0019 = 2.4170 vs txn 2.4173). The three commit
sub-phases sum to the reconstructed `commit_ms` ≈ 2.53 ms at rows=40, matching H3's reported
2.45 ms residual (the small excess is the mean including heavier initial-render frames).

A first sweep taken under slightly elevated load (1-min ≈ 2.7) reproduced the same picture
(txn 0.31 / 1.28 / 2.53 ms; graphRegistrations the same share), so the conclusion is robust
to background load — the finalize:txn ratio (~1:12 to 1:21) is nowhere near flip-able by
noise.

## Root cause (source-confirmed)

`commitRuntimeRegistrations` (`Sources/SwiftTUICore/Resolve/ViewGraphFrameDraft.swift:80`):

```swift
switch runtimeRegistrationPublication {
case .unchanged: break
case .all: liveRegistrations.resetAll()
case .subtrees(let roots): liveRegistrations.removeSubtrees(rootedAt: roots)
}
viewGraph.restoreCurrentFrameRuntimeRegistrations(into: liveRegistrations)   // ALWAYS
```

`restoreCurrentFrameRuntimeRegistrations` (`ViewGraph.swift:1003`) →
`ViewGraphRuntimeRegistrationRestorer.restoreLiveIdentities`
(`ViewGraphRuntimeRegistrationRestoration.swift:3`):

```swift
for identity in identities.sorted() {                                  // O(n log n), all live nodes
  nodesByIdentity[identity]?.restoreOwnRuntimeRegistrations(into: registrations)
}
```

Two compounding costs, both paid **every committed frame, unconditionally**:

1. **`identities.sorted()`** sorts the entire live-identity set. `Identity` comparison walks
   path-component arrays, so each comparison is non-trivial → O(n log n) with a heavy
   constant. This is the most likely source of the super-linear 6→20 step.
2. The per-node `restoreOwnRuntimeRegistrations` loop is O(nodes).

The restore is **not gated by `runtimeRegistrationPublication`** — it runs after the switch
in all modes — and does **not** use the existing subtree-scoped variant
`restoreResolvedSubtree` (`…Restoration.swift:13`), which restores only a resolved subtree
(+ registration aliases). So even when only a small subtree changed (or nothing did), every
live node is re-published, and disjoint reused subtrees (the H2/H3 win on the resolve side)
pay full price again on the commit side.

## Why this matters / interpretation

- The `commit_ms` residual H3 flagged as "the largest interaction-frame residual" is, almost
  entirely, **runtime-registration republication that ignores reuse**. The resolve side was
  taught to reuse disjoint subtrees (H2/H3); the commit side's registration restore was not.
- Recall the **double-execution** multiplier: `commitPlanner.plan` + the lifecycle walk run
  ~2× per committed frame (preview + real), but `commitRuntimeRegistrations` runs **once**
  (real commit only). So the commit-side O(tree) cost is concentrated in a single call —
  good news for a fix, since there's no preview-side duplicate to also address.

## Recommended next step (separate fix-plan)

Target `commitRuntimeRegistrations` / `restoreLiveIdentities`. Candidate directions, cheapest
first (each to be hypothesis-tested before building, per the measure-first discipline):

1. **Drop or cheapen `.sorted()`.** Confirm whether restore order must be deterministic at
   all (registries are keyed by `Identity`); if ordering matters only for tie-breaking,
   a cheaper key or no sort could remove the O(n log n) term outright.
2. **Make the restore reuse-aware / publication-scoped.** When the frame only changed a
   subtree (`.subtrees`) or nothing (`.unchanged`), restore only the affected
   identities via the existing `restoreResolvedSubtree`, instead of the full
   `restoreLiveIdentities` walk — mirroring how the preceding reset already scopes to
   `removeSubtrees`. This is the structural fix and should scale the win with tree size,
   like H3. **Soundness caveat:** the live registry must end each frame byte-identical to a
   full republish — verify focus / pointer / key-handler / scroll registries survive a
   scoped restore across reuse, and that the scenario's reuse-defeated case (whole tree
   `.all`) still re-publishes correctly.

Re-run this exact sweep (the probe is still on the branch) to measure any fix; expect
`graphRegistrations` to flatten across tree sizes if a scoped restore lands.

## Status of the instrumentation

**Archived, not landed (final).** The probe was used for the before/after measurement
(see the fix-results report), then deliberately kept off `main` — the fix landed
probe-free via cherry-pick (`swift-tui` `main` @ `49f2be7e`). The probe is preserved as a
re-appliable patch + README at [`docs/perf/commit-ms-breakdown-probe/`](../perf/commit-ms-breakdown-probe/)
(and the local tag `commit-ms-breakdown-probe-2026-05-31` / branch
`perf/commit-ms-breakdown-instrumentation`).
