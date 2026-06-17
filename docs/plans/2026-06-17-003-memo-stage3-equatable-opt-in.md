# Memoized Body Re-evaluation — Stage 3: Equatable Opt-In (design + findings)

- **Date:** 2026-06-17
- **Status:** **landed** in swift-tui `e085569f` (on the Stage-2 baseline
  `b37feadb`) — gate flipped **default-on**, `EquatableView` / `.equatable()`
  added. Full repo gate green with the gate default-on. A 3-lens adversarial
  review (soundness / isolation / API-parity) returned **GO, no CRITICAL**; its
  two MEDIUM findings were fixed before commit (see §6c). The `compareEquatable`
  (`Equatable`-only) approach is flagged for a follow-up review (task #16); see §7.
- **Prior:** [Stage 2 report](../reports/2026-06-17-memo-stage2-flag-gated-gate.md) ·
  [design doc 002](2026-06-17-002-memoized-body-reevaluation-proposal.md)

## 1. The Stage-2 problem, root-caused

Stage 2 landed the memo gate (flag `SWIFTTUI_MEMO_REUSE`, default off). It *fired*
(recomputed-node counts dropped 20–54%) but `resolve_ms` **regressed** a few
percent. Stage 3 found why:

- The gate's conservative `hasNoRecordedDependencies` guard required a node to
  have recorded **zero** reads. **Every layout container** (`VStack`/`HStack`/…)
  reads layout values from the environment during resolution, recording an
  *environment* dependency. So containers were excluded, and the gate could only
  ever reuse **leaves** (e.g. `Text`) — never short-circuiting a subtree.
- Reusing leaves does not pay: the walk still descends through every (recomputed)
  container to reach each leaf, and the per-node comparison cost is added on top.
  Net: a wash, slightly negative — exactly the Stage-2 regression.

Confirmed with a `[MEMO-DENY]` probe: a read-free `Equatable` boundary wrapping a
grid was denied with `reason=has-deps(state=0 obs=0 env=6)` — environment-only.

## 2. Fix A — widen to environment-only dependencies (sound)

`canMemoReuse` **already** requires `committed.environmentSnapshot == environment`
— the same whole-environment equality oracle Layer-A retained reuse trusts. So a
node whose only recorded reads are environment reads is *already* verified: if the
environment is unchanged, every environment read returns the same value.

New guard `ViewNode.hasNoMemoUncoveredDependencies` = no `@State` slot reads and
no `@Observable` reads (environment reads allowed). `@State`/`@Observable` stay
excluded (not covered by the env snapshot; `!isDirty` catches observable
mutations, but state-value equality is a later widening).

Soundness re-confirmed: the DEBUG shadow oracle (recompute-and-compare) reports
**`unsound_skip=0`** across all scenarios with the widened population in scope
(`addressable_memo_skip` up to ~146/frame).

**Effect:** with a clean author-struct boundary, the gate now short-circuits the
whole subtree via one comparison. On a purpose-built scenario
(`memo-equatable-boundary`, a large read-free grid behind a boundary):
`resolve_ms` median **−86%**.

## 3. The hard finding — reflection regresses framework-heavy trees

Widening helped boundaries but made the realistic focus scenarios regress *more*
(median: gallery +15%, file-browser +13%, vs Stage-2 +9%/+5%). The reflective
comparator (`Mirror`) is invoked on **every** reached node; the env-dep widening
only added more such comparisons. Framework-container trees with no high author
boundary to short-circuit pay the reflection cost without recovering it. One
realistic scenario (`text-input-editing`, whose static form is a non-`Equatable`
author struct with simple fields) *won* (−20%) — so the outcome is purely a
function of whether the tree has coherent, cheaply-comparable reuse boundaries.

**Conclusion:** automatic per-node memoization via reflection does not pay for
SwiftTUI's default framework-container trees. Memoization pays only at
**author-defined boundaries**.

## 4. Fix B — make the gate `Equatable`-only (true opt-in)

This is SwiftUI's model. The production gate now compares **only** `Equatable`
view values (`MemoValueComparator.compareEquatable` → `nil` for non-`Equatable`,
signalling skip). Framework containers (none `Equatable`) are never reflected
over. The full reflective `compare(_:_:)` remains for the DEBUG oracle.

The opt-in is: **conform a read-free boundary view to `Equatable`** (its body
must read no `@State`/`@Observable`; environment reads are fine). The view's
`==` then drives a single cheap comparison that reuses its whole subtree —
including any `ForEach`/`Button` closures inside, which are descendants of the
reused boundary and never compared.

## 5. Fix C — gate the value *capture* on `Equatable`

Equatable-only still left a residual ~+6–8% on non-`Equatable` trees: the gate
was *invoked* for every descendant and ran its guard sequence before skipping.
`shouldCaptureMemoViewValue` now stashes `memoViewValue` **only for `Equatable`
values** in production (still captures everything when the DEBUG oracle is armed),
so a non-`Equatable` node leaves `memoViewValue` nil and the gate bails at its
first guard — near-free on trees that do not opt in.

## 6. A/B results

`termui-perf`, invalidation frames only, median `resolve_ms`. (n=10 boundary,
n=12 focus.)

**Opt-in (does it win?)** — `memo-equatable-boundary`, gate off→on:

| boundary | median off→on | verdict |
| --- | --- | --- |
| `EquatableGrid` (Equatable, opt-in) | 24.46 → 3.35 ms (**−86.3%**) | wholesale subtree reuse via one `==` |
| `PlainGrid` (non-Equatable, control) | 24.21 → 24.64 ms (**+1.8%**) | not opted in → not reused (correct) |

**Non-opt-in (does it regress?)** — realistic focus scenarios, gate off→on, median:

| scenario | reflective widening | Equatable-only | **+ capture-gating (final)** |
| --- | --- | --- | --- |
| gallery-tab-switch | +15.3% | +7.8% | **+1.3%** |
| file-browser-selection | +13.4% | +5.8% | **+3.1%** |
| text-input-editing | −19.9% | +9.9% | **−4.6%** |

The final design is **near-free when not opted in** (±1–3%, noise band) and a
**large win when opted in** (−86%). That makes the gate a default-on candidate:
inert without `Equatable`, a big win with it. (The text-input −20% under
reflective widening was the auto-memoize of a non-`Equatable` author struct —
deliberately given up for the predictability of explicit opt-in; see §7.1.)

## 6b. Fix D — comparator `@MainActor` + isolated `EquatableView`

Adding `EquatableView<Content>` exposed a final wrinkle: `Content` is always a
`View` value, hence main-actor-isolated, so `EquatableView`'s `==` must read
`content` on the main actor — a nonisolated `==` cannot. Resolution:

- `MemoValueComparator` is now `@MainActor` (it only ever runs during resolve,
  which is already main-actor; both production call sites — the gate and the
  DEBUG oracle — were already `@MainActor`).
- `EquatableView`'s `Equatable` conformance is `@MainActor`-isolated
  (`extension EquatableView: @MainActor Equatable`); the `@MainActor` comparator
  opens and calls it via the existential trampoline. Verified to compile and
  evaluate correctly (including the `as? any Equatable` open).

This also means plain author `struct Foo: View, Equatable` with **Sendable**
stored fields works with a synthesized nonisolated `==` (no wrapper needed); the
wrapper is for non-`Equatable` composites and SwiftUI source parity.

## 6c. Adversarial review fixes (pre-commit)

The review confirmed every widened guard is backstopped in the live RunLoop path
(env widening still ANDs `environmentSnapshot ==`; `!isDirty`,
`!invalidatedIdentities.contains`, island and focus/press-suppression guards all
intact; isolation sound). Two MEDIUM findings were fixed before commit:

- **Focus/press readers must stay memo-ineligible on every render path.** The env
  widening newly admitted views reading `@Environment(\.isFocused)` /
  `focusedIdentity` — but focus/press keys are deliberately excluded from
  `environmentSnapshot` equality (they change every focus move), so the snapshot
  conjunct does not verify them. In the live RunLoop the suppression scope denies
  them; the one-shot `DefaultRenderer` does not compute that scope. Fix:
  `hasNoMemoUncoveredDependencies(uncoveredEnvironmentKeys:)` now rejects any node
  whose `environmentReads` intersect `runtimeFocusStateDependencyKeys`
  (`{FocusedIdentityKey, PressedIdentityKey}`), passed from the Views layer into
  the Core gate. Regression-tested (`focusReadingEquatableBoundaryIsNotMemoReused`).
- **Default-on + the new API were undocumented.** Added a CHANGELOG entry, an
  `ARCHITECTURE.md` note, and the `SWIFTTUI_MEMO_REUSE=0` kill switch to the
  `EquatableView` DocC.

LOW findings (documented contract for a lossy `==` over read-bearing descendants;
the `String(reflecting:)` env oracle inherited from Layer-A reuse; `EquatableView`
being a real graph node not a transparent one; the isolation note on the
existential trampoline) are addressed in docs / carried to task #16.

## 7. Decisions taken (compareEquatable still flagged for review — task #16)

1. **`Equatable`-only — KEPT.** Safe, predictable, SwiftUI-shaped. Accepted
   trade-off: the automatic win for non-`Equatable` author structs (text-input
   −20% under reflective widening) is given up for opt-in predictability and
   zero framework-container cost. The reflective `compare`/field-plan-cache
   alternative is left as the task #16 review question.
2. **Flag default — flipped ON.** Fix C drove non-opt-in overhead into the noise
   band (§6), so the gate is enabled by default: inert without `Equatable`, a
   win with it. `SWIFTTUI_MEMO_REUSE=0` disables it.
3. **`EquatableView` / `.equatable()` — ADDED** (SwiftUI parity), with the
   `@MainActor`-isolated conformance of §6b so it works for any `Content`,
   Sendable-field or not.
4. **Test rework — DONE.** The Stage-2 gate-aware tests in
   `ResolveReuseAncestorInvalidationTests` were repurposed to the opt-in
   semantics (a bare non-`Equatable` subtree is *not* a memo candidate, gate on
   or off; soundness invariant holds). `EquatableBoundaryReuseTests` covers the
   opt-in win (plain `Equatable` conformance and the `.equatable()` wrapper).

## 8. Residual hazards (unchanged from Stage 2)

`!isDirty` co-guard mandatory (observable deps); closure-capture `==` is a
correctness contract; focus/press suppression + island guards preserved.
