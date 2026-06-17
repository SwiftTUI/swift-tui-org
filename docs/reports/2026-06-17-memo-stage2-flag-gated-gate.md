# Memoized Body Re-evaluation — Stage 2: Flag-Gated Gate

- **Date:** 2026-06-17
- **swift-tui:** `b37feadb` (Stage 2 on the Stage-1 baseline `3a1092c7`)
- **Design:** [2026-06-17-002-memoized-body-reevaluation-proposal.md](../plans/2026-06-17-002-memoized-body-reevaluation-proposal.md)
- **Prior:** [Stage 0 kill-gate](2026-06-17-memo-stage0-killgate.md) · Stage 1 (commit `3a1092c7`, reuse-equivalent oracle → `unsound_skip=0`)

## What landed

The memoized-body reuse **gate**, behind `SWIFTTUI_MEMO_REUSE` (default **off**),
modelled on `ReaderAttributionConfiguration`:

- **`MemoReuseConfiguration`** (`SwiftTUICore`) — the `@MainActor` flag enum.
- **`ViewNode.memoViewValue: Any?`** — promoted from the Stage-0 DEBUG-only
  `memoDiagnosticViewValue` to a production field, populated whenever the gate
  (or, in DEBUG, the trace) is armed and `nil` otherwise (zero cost when off).
  **Checkpoint-covered** so an aborted frame cannot leave a stale value that
  would mis-compare next frame — the checkpoint-totality guard enforces this.
- **`ViewNode.canMemoReuse` / `hasNoRecordedDependencies`** — the non-dirty reuse
  guards and the conservative "no attributed reads" subset, ANDed by the gate.
- **`ViewGraph.memoizedReusableSnapshot(…)`** — the accept branch. Fires for a
  node that Layer-A `reusableSnapshot` rejected **only** because it is a
  structural descendant of an invalidated ancestor, when: prior view value
  compares `.equal` (structural comparator), `canMemoReuse` holds, no recorded
  dependencies, not dirty/visited/self-invalidated. Routes through the identical
  `recordReusedSubtree(retained: true)` + `restoreRuntimeRegistrations` path as
  Layer A, so every registration/lifecycle/island invariant is preserved.
- **`resolveView` gate** (`SwiftTUIViews`) — sits *after* the Layer-A miss and
  *behind* the focus/press `effectiveSuppressesRetainedReuse` pre-gate.

Release is untouched when the flag is off. Full targeted suites green in both
modes (332 tests flag-on; 18 comparator/reuse/checkpoint tests flag-off).

## Adversarial review found — and we fixed — a comparator soundness bug

A dedicated adversarial pass against the 11-hazard register found a **CRITICAL**
false-equal in the structural comparator's enum handling, *not* exercised by the
Stage-0/1 scenario corpus (so the shadow oracle had not caught it):

> For a **non-`Equatable`** enum (Equatable enums take the fast path), the
> empty-children branch returned `.equal` for any no-payload case without
> inspecting the other side. `.collapsed` vs `.expanded` both reflect to empty
> children → false `.equal` → stale UI. The field-wise descent also ignored
> child *labels*, so `.loaded(x)` vs `.failed(x)` (same arity, same payload)
> false-equalled too.

**Fix — case-aware enum comparison** (`MemoValueComparator.compareEnumCase`):
`Mirror` reflects a payload case as a single child whose `label` is the case name
and whose `value` is the payload; a no-payload case reflects to zero children.
So we compare arity, then the case-name label, then recurse on the payload. A
**no-payload non-`Equatable`** case has no `Mirror`-recoverable discriminator, so
it is denied conservatively (sound, never stale). `Text.Storage.plain(String)` —
a payload case — compares precisely, preserving the common stable-leaf reuse.
Regression-tested in `MemoValueComparatorTests`. (The reviewer's own proposed
"symmetric empty check" fix was *incomplete* — it still false-equals two distinct
no-payload cases; the case-aware approach is the correct one.)

Re-running the shadow oracle with the corrected comparator across all three
focus scenarios (176 invalidation frames): **`unsound_skip=0` on every frame.**

## A/B — the gate fires, but the comparator constant-factor eats the win

`termui-perf`, 12 iterations/mode, invalidation frames only (the frames the gate
can act on). `computed`/`reused` are mean resolved-node counts; `resolve_ms` is
the wall-clock resolve phase.

| scenario | computed/frame (off→on) | reused/frame (off→on) | resolve_ms median (off→on) |
| --- | --- | --- | --- |
| `text-input-editing` | 161.0 → 74.8 (**−53.5%**) | 0 → 64.9 | 10.25 → 10.40 ms (**+1.4%**) |
| `gallery-tab-switch` | 162.6 → 130.2 (**−19.9%**) | 44.1 → 62.3 (+41.2%) | 17.49 → 19.13 ms (**+9.4%**) |
| `file-browser-selection` | 274.7 → 258.7 (**−5.8%**) | 104.2 → 120.3 (+15.4%) | 54.04 → 56.97 ms (**+5.4%**) |

### Reading

- The gate **fires hard**: recomputed nodes fall sharply (text-editing roughly
  halves) and reused climbs — confirming a large, real addressable population,
  consistent with Stage 0's `addressable_memo_skip` (up to 112/frame).
- **But `resolve_ms` regresses** a few percent across the board. The structural
  comparator's per-instance `Mirror(reflecting:)` allocation and per-field
  `String(describing:)` type probes cost *more* than the body re-evaluation they
  save. Most composite view values (`VStack<TupleView<…>>`, etc.) are
  **not** `Equatable`, so they miss the cheap fast path and pay full reflection.

This is exactly why the flag ships **default-off**: the mechanism is sound and
does provably less structural work, but the constant factor is currently net
negative on wall-clock.

## Decision & hand-off to Stage 3

**Keep the gate flag-gated and default-off.** Flipping it on is blocked on a
cheaper comparison path, which is precisely the Stage-3 work:

1. **`EquatableView` / `.equatable()` opt-in** — an author-supplied `==` skips
   `Mirror` entirely (the fast path), turning the demonstrated recomputation
   savings into a real wall-clock win for the views that opt in. This reframes
   the Stage-3 opt-in from "widen the subset" to **"the mechanism that makes
   memoization pay."**
2. **Per-type field-plan cache** (design §5, deferred) — memoize, keyed by
   `ObjectIdentifier(type)`, the `isAnyView` / `isDynamicPropertyWrapperStorage`
   type probes (pure functions of the type) to kill the repeated `String`
   allocation. Needs a concurrency-safe home under strict-concurrency rules.
3. Widen past the no-recorded-dependencies subset; island/aborted-frame
   hardening; long-run soak.

### Residual risks carried to Stage 3 (from the adversarial pass)

- `hasNoRecordedDependencies` is necessary-not-sufficient: a directly-read
  `@Observable` model records no attributed read and is caught only by the
  `!isDirty` co-guard. Documented on the property; any future memo path must keep
  the `!isDirty` conjunct. (Not a current break.)
- `isDynamicPropertyWrapperStorage` uses a hard-coded wrapper-name prefix list;
  unknown wrappers fall to `ObjectIdentifier` (conservative — never unsound). A
  marker protocol would be more robust.
- No-payload non-`Equatable` enums are conservatively denied reuse — acceptable
  loss; the escape hatch is `Equatable`.
