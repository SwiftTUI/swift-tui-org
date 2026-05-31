# Perf — `commit_ms` Registration-Restore Fix Plan (Fix 1 + Fix 2)

**Date:** 2026-05-31
**Status:** ✅ COMPLETE & LANDED. **Fix 2** (scope the restore) shipped — `swift-tui` `main` @ `49f2be7e`, org pin `543dfc4` (both pushed). **Fix 1** (sort cache) was implemented, measured ineffective, and reverted. Results: [`docs/reports/2026-05-31-commit-ms-registration-restore-fix-results.md`](../reports/2026-05-31-commit-ms-registration-restore-fix-results.md).
**Predecessor (findings):** [`docs/reports/2026-05-30-commit-ms-breakdown-findings.md`](../reports/2026-05-30-commit-ms-breakdown-findings.md)
**Code base (at planning time):** branch `perf/commit-ms-breakdown-instrumentation` @ `528b028e` (carried the measurement probe). Base `main` @ `1526e21a` (= org pin `8b0630a`).

---

## What we're fixing

After H3, the largest interaction-frame residual is `commit_ms`, ~95% of which is
`transaction.commit()` → `graphDraft.commitRuntimeRegistrations` →
`ViewGraphRuntimeRegistrationRestorer.restoreLiveIdentities`:

```swift
for identity in identities.sorted() {                       // O(n log n) over ALL live nodes
  nodesByIdentity[identity]?.restoreOwnRuntimeRegistrations(into: registrations)
}
```

This runs **every committed frame, full-tree, unconditionally** (after the
publication-mode switch in `commitRuntimeRegistrations`, in all modes) and gets
**no benefit from H2/H3 subtree reuse**.

## Measured facts driving the design (from the probe)

- `graphRegistrations` mean/frame: **0.30 / 1.20 / 2.41 ms** at rows 6/20/40 → scales ×8.
- **Publication mode is `~85% .subtrees` with a single root** (the narrow `@State`
  invalidation), `~15% .all` (initial renders), `0 .unchanged`. **Yet the restore
  re-publishes the entire grid every `.subtrees` frame** — that is the waste.

## Soundness constraints (source-confirmed — see findings + Explore map)

- `liveIdentities` **accumulates** (formUnion each frame; removed only on subtree
  removal) and may hold identities absent from `nodesByIdentity` → the `?` guard in
  the loop is load-bearing. Mutation sites: `ViewGraph.swift:68,162,939,1190`.
- **Restoration order is observable** for the global append-ordered registries:
  `LocalDefaultFocusRegistry` (`scopes`/`candidates`, "first match wins") and
  `LocalFocusBindingRegistry` (`registrations`), plus the pointer/gesture filter in
  `RuntimeRegistrationSet+Operations.swift:79` that reads live gesture state. **No
  test pins this order**, so a regression would be silent.
- Dict-keyed registries (action/key/pointer/gesture/task/lifecycle/scroll/…) are
  order-independent (keyed by `Identity`/`RouteID`, idempotent overwrite).
- The full restore is `resetAll()` (`.all`) / `removeSubtrees(roots)` (`.subtrees`)
  then a full re-publish. In `.subtrees` mode the full re-publish currently
  **re-appends unchanged focus candidates** (latent duplication for focusable
  unchanged subtrees) — so today's `.subtrees` path is already non-canonical;
  canonical focus order is only re-established on `.all` frames.

**Soundness bar:** after `commitRuntimeRegistrations`, the live registry must equal
what a full rebuild (`resetAll` + restore all live nodes in canonical sorted order)
would produce — enforced by a new equivalence test (below), since closures aren't
`Equatable` but `snapshot()`s/keys/counts are.

---

## Fix 1 — cache the sorted live-identity order (cheapest; exact-order-preserving)

The sort runs every full-restore frame, but `liveIdentities` is **stable across the
interaction frames** (the tree doesn't change; only `@State` does). Cache the sorted
array; invalidate only on actual membership change.

- `ViewGraph`: add `private var sortedLiveIdentitiesCache: [Identity]?`.
- Invalidate **precisely** (not via `didSet`, which would fire on every frame's
  no-op `formUnion` and defeat the cache):
  - `:939` `formUnion`: compare `count` before/after; nil the cache only if it grew.
  - `:1190` `remove`: nil the cache only if `remove(...) != nil`.
  - `:68` checkpoint-restore and `:162` init: always nil the cache.
- `restoreCurrentFrameRuntimeRegistrations`: use the cache (compute+store on miss),
  pass the pre-sorted `[Identity]` to `restoreLiveIdentities` (signature changes
  `Set<Identity>` → `[Identity]`).

**Soundness:** byte-identical — same sorted order, computed once. Verified by the
full gate + the equivalence test.
**Expected:** removes the O(n log n) component (the super-linear part) from every
full-restore frame where the tree is stable.

## Fix 2 — scope the restore to the publication mode (structural; the big win)

Make the restore honor the same scope the reset already uses:

- `.all`: `resetAll()` + full restore (unchanged — canonical full rebuild).
- `.subtrees(roots)`: `removeSubtrees(roots)` + restore **only** the nodes under
  `roots` (walk those subtrees), not the full live set.
- `.unchanged`: nothing.

Mechanism: `commitRuntimeRegistrations` already has the publication mode; thread it
into the restore so `restoreCurrentFrameRuntimeRegistrations` can restore a scoped
node set. Reuse the existing `restoreResolvedSubtree`/per-node walk for the roots.

**Soundness — the focus-order risk and how it's handled:** scoping leaves unchanged
focus candidates in place and re-appends only `roots`' candidates → order may differ
from a canonical full rebuild. Plan:
1. Land the **equivalence test first** (TDD): build a tree with focus bindings,
   default-focus candidates, key/pointer/gesture handlers in **both** the changed
   and unchanged subtrees; run a narrow invalidation; assert each registry's
   `snapshot()` (and identity-key set) equals a full rebuild's.
2. If the focus ordered-lists diverge: keep them canonical cheaply — the
   order-sensitive registries hold **few** entries, so re-publish *those* registries
   in canonical order while scoping the bulk dict-keyed registries to `roots`. (Only
   adopt this split if the test shows divergence; the grid scenario has no focus
   candidates, so the bulk path is what pays.)

**Expected:** `graphRegistrations` flattens across tree sizes on `.subtrees` frames
(the 85% case) — the H3-style scaling win, this time on the commit side.

---

## Execution order & verification (each fix independently)

1. **Equivalence test** (`Tests/SwiftTUICoreTests/...RegistrationRestore...`) — RED
   first against a deliberately-scoped restore, then GREEN.
2. **Fix 1** → `bun run test` green (modulo the known OffscreenFrameElision
   load-flake, proven pre-existing) → sweep 6/20/40 with the probe → record.
3. **Fix 2** → equivalence test green → `bun run test` → sweep → record.
4. Each fix is its own commit on the branch. The probe stays until both land, then
   revert the probe (or land deliberately). Org pin not bumped until pushed.

## Output

Append before/after sweep medians + the soundness-test description to
`docs/reports/2026-05-30-commit-ms-breakdown-findings.md` (or a new
`2026-05-31-...-fix-results.md`).
