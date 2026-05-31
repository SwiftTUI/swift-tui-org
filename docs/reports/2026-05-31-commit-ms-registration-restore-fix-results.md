# Perf — `commit_ms` Registration-Restore Fix Results (Fix 1 + Fix 2)

**Date:** 2026-05-31
**Plan:** [`docs/plans/2026-05-31-001-perf-commit-ms-registration-restore-fix-plan.md`](../plans/2026-05-31-001-perf-commit-ms-registration-restore-fix-plan.md)
**Findings (root cause):** [`docs/reports/2026-05-30-commit-ms-breakdown-findings.md`](2026-05-30-commit-ms-breakdown-findings.md)
**Code:** ✅ landed. **Fix 2** cherry-picked probe-free onto `swift-tui` `main` @ **`49f2be7e`** (the measurement-branch commit was `da3b0adb`, identical diff); org pin bumped to **`543dfc4`**; both pushed; `bazel //:org_fast` 4/4 green. Measured against base `main` @ `1526e21a`. The probe (`528b028e`, `8bab1fb8`) was archived, not landed — [`docs/perf/commit-ms-breakdown-probe/`](../perf/commit-ms-breakdown-probe/).

---

## TL;DR

- **Fix 1 (cache `liveIdentities.sorted()`): implemented, measured INEFFECTIVE, reverted.**
  The sort is only ~1–2% of `graphRegistrations` (≈170 identities: ~1,170 comparisons,
  ~10–50 µs, vs ~2,400 µs for the per-node restore). Measured no change (rows=40
  graphRegistrations 2.41 → 2.50 ms, within noise). The earlier "super-linearity" was
  fixed-cost amortization, not an O(n log n) signature (the 20→40 step was exactly ×2.0).
  Shipping a no-op optimization with added cache-invalidation surface (and a
  checkpoint-totality-contract entry) was not worth it.
- **Fix 2 (scope the restore to the publication mode): the win.** `commitRuntimeRegistrations`
  re-published **every** live node's registrations every committed frame, even though the
  reset was already publication-scoped. Scoping the restore to match — `.subtrees(roots)`
  restores only the changed subtrees (O(subtree) ViewNode walk) — cuts `graphRegistrations`
  **−79…82%** and **total CPU −5.5…14.1%** (the win **grows with tree size**).
- **Soundness: byte-identical, enforced by a TDD test.** Dict/route-keyed registries are
  order-independent (idempotent overwrite); the two global append-ordered focus lists
  observe restore order, so `normalizeScopedRestoreOrder` re-sorts them to canonical
  identity order after a scoped restore. New `RuntimeRegistrationRestoreScopingTests`
  asserts a scoped commit == a full rebuild; **verified RED** without the normalize.
  Full repo gate green.

---

## Fix 2 — what changed

`Sources/SwiftTUICore/Resolve/ViewGraphFrameDraft.swift` `commitRuntimeRegistrations`:

```swift
case .all:
  liveRegistrations.resetAll()
  viewGraph.restoreCurrentFrameRuntimeRegistrations(into: liveRegistrations)   // full
case .subtrees(let roots):
  liveRegistrations.removeSubtrees(rootedAt: roots)
  viewGraph.restoreRuntimeRegistrationSubtrees(rootedAt: roots, into: liveRegistrations) // scoped
  liveRegistrations.normalizeScopedRestoreOrder()                              // canonical focus order
```

- `ViewGraph.restoreRuntimeRegistrationSubtrees(rootedAt:into:)` (new) walks each root's
  ViewNode subtree (`ViewNode.restoreRuntimeRegistrations`) — O(subtree), not O(tree).
- `RuntimeRegistrationSet.normalizeScopedRestoreOrder()` (new) re-sorts only
  `LocalDefaultFocusRegistry` (scopes/candidates) and `LocalFocusBindingRegistry`
  (registrations) — the sole cross-node order-observing registries — by identity (stable).
  This also removes the pre-existing `.subtrees` duplication of unchanged focus candidates.
- `.all` and `.unchanged` keep the full restore (unchanged behavior).

## Results (synthetic-narrow-invalidation, async, 20 iters, release, CV ≤ 3.9%)

Mean ms / committed frame, before (full restore, `528b028e`) → after (Fix 2, `da3b0adb`):

| metric | rows=6 | rows=20 | rows=40 |
| --- | --- | --- | --- |
| `graphRegistrations` before | 0.292 | 1.204 | 2.407 |
| `graphRegistrations` after | **0.062** | **0.213** | **0.455** |
| Δ | −79% | −82% | −81% |
| `txn` before → after | 0.295→0.065 | 1.210→0.219 | 2.417→0.465 |
| `commit_ms` (≈ finalize+txn+plan) before → after | 0.317→0.088 | 1.269→0.278 | 2.529→**0.576** |
| total CPU s before → after | 0.0805→0.0761 | 0.1591→0.1408 | 0.2535→**0.2178** |
| total CPU Δ | −5.5% | −11.5% | **−14.1%** |

Publication tally (rows=40): `all=59 subtrees=300 unchanged=0`, mean roots = 1.0.

**Per-interaction win.** The aggregate `graphRegistrations` still scales because the ~16%
`.all` initial-render frames keep doing a full O(tree) restore. Backing them out (rows=40:
~59 `.all` × ~2.4 ms ≈ 142 ms of the 163 ms total), the **300 `.subtrees` interaction
frames cost ~0.073 ms each vs ~2.4 ms baseline — ~97%, and flat in tree size.** The
scoped restore is O(changed subtree), independent of the static grid. The residual is
inherent initial-render startup, not per-interaction cost.

## Soundness

- **Equivalence test** (`Tests/SwiftTUICoreTests/Graph/RuntimeRegistrationRestoreScopingTests.swift`):
  two focusable sibling subtrees (changed subtree sorts *before* the unchanged one — the
  worst case for append-ordered focus lists); a `.subtrees([A])` scoped commit must produce
  a `defaultFocusRegistry.snapshot()` (Equatable) and focus-binding identity order
  byte-identical to a full rebuild. Passes with the normalize; **fails without it**
  (`[B,A]` vs `[A,B]`), proving the guard is real.
- **Full repo gate green**, incl. Focus (89), Gesture (56), Pointer (31), RegistrationAlias
  (10), SwiftTUICoreTests (415). The known `OffscreenFrameElisionRuntimeTests` load-flake
  is intermittent (proven pre-existing on base `1526e21a` under full-gate load) and passed
  on the landing run.

## Status / next

- ✅ **Done, landed & pushed.** Fix 2 on `swift-tui` `main` @ `49f2be7e` (probe-free
  cherry-pick); org pin `8b0630a` → `543dfc4`; `bazel //:org_fast` 4/4 green. Fix 1
  reverted (ineffective). The probe is archived (not landed) at
  [`docs/perf/commit-ms-breakdown-probe/`](../perf/commit-ms-breakdown-probe/).
- **Known-flake note:** the full gate's only failure on the landing run was
  `OffscreenFrameElisionRuntimeTests` "off-screen deadline tick…" (`:297`/`:331`) — the
  documented intermittent load-flake, proven pre-existing on base `1526e21a` under full-gate
  load and passing 2/2 in isolation on `49f2be7e`. Not a Fix 2 regression.
- **Possible follow-ons (deferred, lower value):**
  - The `.all` initial-render frames still do a full O(tree) restore (startup, not
    per-interaction; Fix-1-style caching won't help — those frames grow `liveIdentities`).
  - `.unchanged` frames retain the pre-existing full re-publish (untouched by Fix 2; 0 in
    the measured scenario). Since nothing was re-evaluated, that path could simply skip the
    restore — a small correctness/efficiency cleanup (it also avoids re-appending unchanged
    focus candidates). Out of scope for this fix.
