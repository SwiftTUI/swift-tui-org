# Perf — `commit_ms` Sub-Phase Instrumentation Plan (measure first, no fix)

**Date:** 2026-05-30
**Status:** ✅ COMPLETE (2026-05-31). Executed: the probe located the O(tree) commit
cost (`commitRuntimeRegistrations`); see the findings report below. The optimization
shipped separately — see [`docs/plans/2026-05-31-001-...`](2026-05-31-001-perf-commit-ms-registration-restore-fix-plan.md)
and [`docs/reports/2026-05-31-commit-ms-registration-restore-fix-results.md`](../reports/2026-05-31-commit-ms-registration-restore-fix-results.md).
The probe itself was **not** landed — it is archived at
[`docs/perf/commit-ms-breakdown-probe/`](../perf/commit-ms-breakdown-probe/). Original
hand-off note (historical): handed off from a session whose tool output became
intermittently unreliable mid-investigation; the commit-path map below was
cross-verified by clean `Read` + matching `grep` line numbers before hand-off.
**Predecessors:** [`docs/reports/2026-05-30-h3-retained-subtree-findings.md`](../reports/2026-05-30-h3-retained-subtree-findings.md),
[`docs/plans/2026-05-30-002-perf-h3-retained-subtree-bookkeeping-plan.md`](2026-05-30-002-perf-h3-retained-subtree-bookkeeping-plan.md)
**Code base:** `swift-tui` `main` @ `1526e21a` (= current org pin `8b0630a`).

---

## Goal

After H3, `commit_ms` (the frame-tail commit phase) is the **largest
interaction-frame residual** — `2.45 ms` at 40 tree rows, scaling ~8× across the
6/20/40-row sweep. This plan **instruments `commit_ms` sub-phases and runs the
tree-size sweep to LOCATE the O(tree) cost. It implements NO optimization.**

This is the explicit lesson from the **reverted** commit_ms attempt (see H3 status
memory + findings): a prior session *hypothesized* the cost was the viewport
lifecycle walk (`collectViewportLifecycleEvents`), implemented a prune, and
**measured only −7…9%** — the premise was wrong. It also tripped a deterministic
SEGV that turned out to be a **SwiftPM cross-module ABI-skew build artifact** (a
layout change to a core `SwiftTUICore` type followed by an incremental *debug*
rebuild after a *release* sweep build), **not** a real bug. Measure the
sub-phases *before* writing any fix.

---

## Verified commit-path map (re-confirm line numbers before editing)

`commit_ms` for a **committed** frame = duration of the `measurePhase` block in
`commitFrameEffects`:

- **`swift-tui/Sources/SwiftTUIRuntime/Rendering/DefaultRenderer+CompletedFrameCandidates.swift`**
  - `commitFrameEffects(...)` ~`122–154`; timed `measurePhase(clock:)` block ~`130–144`, containing **in order**:
    1. `viewGraph.finalizeFrame(rootIdentity:resolved:placed:)` — `:131`
    2. `commitFrameHeadDraftEffects(draft)` = `draft.transaction.commit()` — call `:136`, body `:177–182` (`transaction.commit()` at `:181`)
    3. `commitPlanner.plan(resolved:placed:semantics:transaction:lifecycleEvents:)` — `:137`
  - **Outside** the timed block (NOT in `commit_ms`): `applyWorkerCustomLayoutCacheUpdates` `:145`, `frameTailRenderer.pruneMeasurementCache` `:146`.
  - `measurePhase` helper: `:249–260` (`ContinuousClock?`; returns `(value, Duration)`; `.zero` if clock nil).

- **`finalizeFrame` body — `swift-tui/Sources/SwiftTUICore/Resolve/ViewGraph.swift:913–944`** contains **THREE O(nodes) costs**:
  1. `for identity in frameOrder { … setCommittedPresence(true); … setLifecycleState(.alive) }` — `:920–929`
  2. `frameLifecycleEventPlan(resolved:placed:)` — `:931` → `ViewGraphLifecycleEventCollector.frameLifecycleEventPlan` (`Sources/SwiftTUICore/Resolve/ViewGraphLifecycleEventCollection.swift:73`). **This is the viewport walk the prior attempt pruned for only −7…9%.**
  3. `liveIdentities.formUnion(frameOrder)` — `:939`
  - then cheap `removeAll(keepingCapacity:)` on invalidated/dirty/state-mutation sets `:940–942`.
  - (`previewLifecycleEvents` `:903–911` calls the same plan; private `frameLifecycleEventPlan` wrapper `:1268–1285`.)

### The double-execution multiplier (confirm on the scenario)

On every **committed** frame the pipeline runs the preview commit **and then** the
real commit:
- `makeCompletedFrameCandidate` (`…CompletedFrameCandidates.swift:5–54`) calls
  `previewCompletedFrameCommit` (`:204–229` — contains `previewLifecycleEvents` +
  `commitPlanner.plan`) at `:20`, to compute drop eligibility.
- If not dropped, `commitCompletedFrameCandidate` (`:90–119`) runs
  `commitFrameEffects` at `:96`.

So `commitPlanner.plan` and the lifecycle walk each run **~2×/committed frame**,
but the TSV `commit_ms` only times the second (`commitFrameEffects`). Total CPU
pays for both — relevant when interpreting `total_cpu_seconds` vs `commit_ms`.

---

## Sharpened hypothesis (ranked)

1. **`frameOrder` bookkeeping in `finalizeFrame` — the loop (`:920–929`) + `liveIdentities.formUnion` (`:939`).** Most likely the dominant O(tree) cost, because the viewport walk (the other O(tree) item in the same function) was already shown to be only ~7–9%.
2. **`commitPlanner.plan`** — O(lifecycleEvents + interactionRegions); secondary, but confirm.
3. **`transaction.commit()`** — unknown cost; instrument it.

---

## Instrumentation — two routes; start with Route A

### Route A (recommended first): env-gated MainActor accumulator (lowest churn, no API/TSV/test/baseline changes)

`commitFrameEffects` is `@MainActor`, so a `@MainActor` static accumulator is
concurrency-safe (no escape hatch needed).

1. In `commitFrameEffects`, split the single `measurePhase` into **three**
   `measurePhase` calls — `finalizeFrame`, `commitFrameHeadDraftEffects`,
   `commitPlanner.plan` — and set `commitDuration = finalize + txn + plan` (keep
   the existing `commit_ms` continuous).
2. Accumulate per-sub-step total `Duration` + a frame counter into a
   `@MainActor enum CommitBreakdownProbe { static var finalize/txn/plan/frames }`,
   gated by `ProcessInfo.processInfo.environment["TERMUI_PERF_COMMIT_BREAKDOWN"] != nil`.
   (SwiftTUIRuntime is **not** a Foundation-free layer, so `ProcessInfo`/`FileHandle` are allowed there.)
3. Emit a one-line summary at run end (mean per frame for finalize/txn/plan, +
   frame count) to **stderr** via `FileHandle.standardError` — `PerfTerminalHost`
   is in-memory so stderr is free. Easiest emit point: scenario/harness teardown
   in `Tools/TermUIPerf` reading the static, or a `defer` in the run path.
   (Do **not** use `print()` — flagged by the Swift hooks rule.)
4. Each sweep point (`TERMUI_PERF_INVALIDATION_TREE_ROWS ∈ {6,20,40}`) is its own
   process running 20 iterations, so a per-process aggregate is exactly the
   signal needed: compare finalize/txn/plan means across tree sizes → the one
   that scales O(tree) is the culprit.

**Touches one runtime file (+ a few lines in the harness).** Trivial to revert.

### Route B (if per-frame / aggregator data is wanted): add TSV columns

Established precedent = the `elided` column (a `public var` on
`FrameDiagnosticRecord:85`, threaded via `FrameRecordDerivation`).

1. `FrameTimings.swift` — add `commitFinalize`, `commitTxn`, `commitPlan`
   (`Duration`, defaulted to `.zero`) to **`FramePhaseTimings`** (public struct
   `:1–37`). `total` stays = resolve+…+commit (the three are informational,
   sum ≈ commit).
2. `CompletedFrameCandidateTypes.swift:16` — add the three `Duration` fields to
   `CommittedFrameEffects`.
3. `DefaultRenderer+CompletedFrameCandidates.swift` `commitFrameEffects` —
   measure each sub-step; populate the three on `CommittedFrameEffects`.
4. `CommittedFrameArtifactBuilder.swift` `makeCompletedFrameArtifacts` (`:58–90`)
   + `CommittedFrameDiagnosticsBuilder.swift` `phaseTimings(...)` (`:68–82`) —
   thread the three sub-durations onto `FramePhaseTimings`. (Other caller
   `makeOneShotArtifacts` `:26–56` can pass `.zero`.)
5. `FrameDiagnosticsTSVFormatting.swift` — add three columns to `headerFields`
   right after `"commit_ms"` (index 16, line `:21`): e.g.
   `"commit_finalize_ms"`, `"commit_txn_ms"`, `"commit_plan_ms"`; and three
   matching `formatMs(...)` values in the `fields(for:)` return array right after
   `commitMs` (`:106` extract, `:149` row). **Keep header↔row order identical.**
6. Golden test `Tests/SwiftTUIProfilingTests/TSVFileSinkTests.swift`
   auto-validates header.count == row.count — no edit, just rerun.
7. `docs/perf/2026-05-28-gallery-baseline/aggregate.py` is **name-indexed**
   (robust to new columns); add `fcol("commit_finalize_ms")` etc. for medians.
8. **Public-API baseline:** adding public fields changes the surface. Regenerate
   `docs/.public-api-baseline.txt` (`Scripts/generate_public_api_inventory.sh`).
   Since this is temporary instrumentation, the regen reverts with the change.

> To split `finalizeFrame` *internally* (frameOrder-loop vs walk vs formUnion),
> add temporary sub-timers inside `ViewGraph.finalizeFrame` (Core). Do this only
> as **Phase 2**, after the coarse split points at `finalizeFrame` — and CLEAN
> REBUILD (see cautions) because it changes a Core type's codegen.

---

## Sweep procedure (proven in H3)

```bash
cd swift-tui
for ROWS in 6 20 40; do
  TERMUI_PERF_INVALIDATION_TREE_ROWS=$ROWS TERMUI_PERF_COMMIT_BREAKDOWN=1 \
    swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
    run --scenario synthetic-narrow-invalidation --modes async \
        --iterations 20 --configuration release
done
```

- Steady-state = invalidation frames ≥ 4. Machine quiet (1-min load ≤ 2.5).
- Report CVs (H3 kept CVs ≤ 4.2%). Confirm exact flag names against
  `Tools/TermUIPerf` `PerfRunConfig` first (H3 used this scenario + flags).
- Compare `finalize`/`txn`/`plan` across rows 6/20/40 → which scales O(tree).

---

## Critical cautions

- **CLEAN rebuild after any change to a core `SwiftTUICore` type** before trusting
  a crash. The prior SEGV was incremental cross-module ABI-skew (release build →
  incremental debug `swift test`), not a bug. `swiftly run swift package clean`
  (or remove `.build`) when switching release/debug after touching Core layouts.
- **This is measurement instrumentation — plan to REVERT it** (or land it
  deliberately if broadly useful) once the cost is located. Don't ship
  half-instrumentation.
- Work on a **branch in the `swift-tui` submodule** (base `main` @ `1526e21a`).
  Do not bump the org pin until done + pushed (org records pushed commits only).
- Run everything via **`swiftly run swift …`** (pinned toolchain), not bare
  `swift`. `bun run test` must be green before "done"; the
  `OffscreenFrameElisionRuntimeTests` is a known load-flake (see
  `swift-tui/docs/KNOWN-TEST-FLAKES.md`) — not your regression.

## Files to touch (verified paths; re-confirm line numbers)

- `swift-tui/Sources/SwiftTUIRuntime/Rendering/DefaultRenderer+CompletedFrameCandidates.swift`
- `swift-tui/Sources/SwiftTUIRuntime/Rendering/CompletedFrameCandidateTypes.swift` *(Route B)*
- `swift-tui/Sources/SwiftTUICore/Commit/FrameTimings.swift` *(Route B; Core + baseline)*
- `swift-tui/Sources/SwiftTUIRuntime/Rendering/CommittedFrameArtifactBuilder.swift` *(Route B)*
- `swift-tui/Sources/SwiftTUIRuntime/Rendering/CommittedFrameDiagnosticsBuilder.swift` *(Route B)*
- `swift-tui/Sources/SwiftTUIRuntime/Diagnostics/FrameDiagnosticsTSVFormatting.swift` *(Route B)*
- `swift-tui/Tools/TermUIPerf/...` *(Route A emit point + confirm scenario flags)*
- `swift-tui-org/docs/perf/2026-05-28-gallery-baseline/aggregate.py` *(Route B, optional)*

## Output

When the culprit is located, write
`docs/reports/2026-05-30-commit-ms-breakdown-findings.md` with the per-sub-phase
medians across tree sizes and the identified O(tree) cost, then decide the fix in
a separate plan.
