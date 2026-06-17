# Memoized Body Re-evaluation — Design Proposal & Staged Plan

- **Status:** Proposal + staged plan (design-only; no code yet)
- **Date:** 2026-06-17
- **Scope:** `swift-tui/` resolve engine — `ViewNode`, `ViewGraph.reusableSnapshot`,
  `ViewFoundation.resolveView`, the dependency/reader-attribution layer, and the
  per-node checkpoint contract.
- **Verified against:** `swift-tui` at `179ca242`.
- **Decision (committed):** store the **view value comparably — and *structurally*
  comparably — on each `ViewNode`**, and skip a node's body re-evaluation when its
  view value is unchanged **and** its tracked dependencies are unchanged, reusing
  the committed subtree. This is SwiftUI's input-equality / memoized-body model.
  It realizes the VISION-GAP item *"dependency-aware (profile-gated) body
  re-evaluation"* (`swift-tui/docs/VISION-GAP.md:91`), today design-only.

> This is a high-blast-radius engine change. It is staged like the
> [first-class structural identity](2026-06-03-001-first-class-structural-identity-proposal.md)
> migration: **Stage 0 is read-only diagnostics + a shadow oracle**, each later
> stage is independently shippable behind an oracle that *proves*
> behavior-preservation, and the SwiftUI-shaped authoring surface stays stable
> throughout. The destination is committed; the staging exists to land it safely
> and to **kill it early if the measured win does not clear the blast radius.**

---

## 1. The problem

SwiftTUI's reuse gate `ViewNode.canReuse(frameID:environment:transaction:)`
(`Sources/SwiftTUICore/Resolve/ViewNode.swift:611-629`) is purely
**freshness-based**:

```swift
wasPresentAtFrameStart && !wasVisitedThisFrame && !isDirty
  && isCommittedSnapshotFresh && !hasStaleIslandDescendant
  && committed.supportsRetainedReuse
  && committed.environmentSnapshot == environment
  && committed.transactionSnapshot.isReuseEquivalent(to: transaction)
```

It returns false **the moment `isDirty` is set** (`:619`). So retained reuse
(`ViewGraph.reusableSnapshot`, `ViewGraph.swift:1509-1598`) only reuses subtrees
that are **disjoint from the invalidation**. The node that was actually
invalidated — and *every child its body reconstructs* — re-runs unconditionally.
There is **no view-value or output comparison anywhere** in the engine.

**Consequence (the Tier-1 headline cost), measured at the post-narrowing
baseline:** when container `@State` changes, every view that *reads* it is a
genuine reader → dirty → re-runs → recomputes its whole subtree, even when the
subtree's output is unchanged. Selection/collection UIs are the worst case
because the selection is inherently read by every item:

| scenario | resolve p50 | reuse shape on the hot frame |
| --- | ---: | --- |
| `file-browser-selection` | **14.5 ms** | alternating `reused 0/349` full recompute |
| `gallery-tab-switch` | **5.6 ms** | swap frames `reused 0/180` |
| `text-input-editing` | 3.2 ms | every keystroke `reused 0/131` (`root_invalidated`) |
| `synthetic-observable-fanout` | 4.1 ms | one key-path mutation dirties 17 readers |

The `measure` phase tracks `resolve` (it re-measures whatever resolve recomputed),
so the cost is `resolve + measure` and a single fix addresses both. This is gap
**G8** in [the invalidation-gap analysis](../reports/2026-06-13-swifttui-invalidation-gap-analysis.md)
(lines 386-401), which rates automatic memoization "very high" architectural
cost — hence the staging and kill-criteria below.

## 2. The model

SwiftUI re-evaluates a view's `body` only when its **inputs** change, where
*input* = (the view struct's stored fields) ∪ (the dynamic-property values it
read). A child whose input value equals last frame's — and whose read
dependencies are clean — is not re-evaluated; its subtree is reused.

SwiftTUI already has **one of the two halves**:

- **Dependency freshness — LANDED.** Reader attribution
  (`ReaderAttributionConfiguration`, on by default) + `DependencySet`
  (`Sources/SwiftTUICore/Resolve/DependencySet.swift:23`) record each node's
  `@State`/`@Observable`/`@Environment` reads and attribute a state write to the
  genuine reader (`ViewNode.stateChangeInvalidationIdentities`, `ViewNode.swift:316-328`,
  with a never-drop fallback to the owner when no reader was recorded).
- **View-value equality — MISSING.** The concrete `V` is in hand only at the top
  of `resolveView<V: View>` (`ViewFoundation.swift:256`), captured *opaquely*
  inside the per-node evaluator closure
  (`context.viewGraph?.setEvaluator(for:) { _ = resolveView(view, in: context) }`,
  `ViewFoundation.swift:321-323`), and **discarded for storage** — neither
  `ResolvedNode` nor `ViewNode` retains a comparable view value. Each frame the
  parent's body produces a *fresh* `V` for the child and calls `resolveView`
  again unconditionally; nothing asks "is this child's `V` equal to last frame's."

**This proposal supplies the missing half** and gates body re-evaluation on the
AND of both. The decision table for a node the resolve walk *reaches* this frame:

| view value changed? | tracked dep changed? | state | today | with the gate |
| --- | --- | --- | --- | --- |
| — | — | not dirty, disjoint | reuse (Layer A) | reuse (unchanged) |
| **no** | **no** | dirty / frontier | **re-run** | **reuse** ← the win |
| no | yes | dirty | re-run | re-run (dep changed → must) |
| yes | no | dirty | re-run | re-run (value changed → must) |
| no | no | not dirty; parent re-ran, passed equal value | re-run | **reuse** ← secondary win |

The critical correctness row is **(value no, dep yes)** — view value unchanged
but a recorded dependency changed: the gate **must** re-run. View-value equality
is necessary, never sufficient.

## 3. Design stance

- **Comparable view-value storage is the committed destination,** not a
  contingency. The hedge "only if a workload proves it" is answered by Stage 0's
  measurement *gate*, not by refusing to build the mechanism.
- **The authoring surface stays stable.** `View`, `@State`, `ForEach`, controls
  behave identically; `Package.swift` stays SwiftPM-consumable. The change lives
  entirely below the authoring boundary.
- **Every stage lands behind an oracle** that *proves* behavior-preservation —
  the Stage-0 shadow byte-identity assertion, the reuse-invariant suites, the
  registration byte-identity suite (`RuntimeRegistrationRestoreScopingTests`).
  "Behavior-preserving" is proven, not asserted.
- **Kill criteria are first-class.** If Stage 0 shows the *addressable* memo-skip
  rate is near-zero on interaction frames, the project stops — the win does not
  clear the blast radius. This is the explicit
  [perf-phase-completion-goal](2026-06-15-001-perf-phase-completion-goal.md)
  criterion ("promote body re-evaluation only if a fresh baseline shows a
  workload dominated by invalidated body work").
- **Foundation-free and `unsafe`-free.** The recommended comparator uses only
  `Swift.Mirror` (stdlib, already used in the Foundation-free layers —
  `SwiftTUIViews/Animation/AnyTransition.swift:215`, `SwiftTUI/App.swift:64`),
  `as? any Equatable`, and `ObjectIdentifier`. No Foundation, no `unsafe`.

## 4. Where the gate lives — the single most important architectural decision

**The gate is a new *accept branch inside `reusableSnapshot`*, conjoined with
every existing `canReuse` guard, routed through the same post-reuse plumbing
(`recordReusedSubtree(retained:)` + `restoreRuntimeRegistrations(for:)` +
`republishAllEffectRegistrations`). It is NOT a parallel early-return in
`resolveView`.**

This is non-negotiable, and it is exactly the lesson of the Tier-2 regression we
just reverted: a body-skip path that *bypassed* the reuse plumbing
removed-but-didn't-restore capture-hosted islands' registrations, dead-controlling
them. By making memoization a sub-branch of the existing reuse decision, **all of
the following guards apply for free** rather than needing to be re-implemented:

- the `effectiveSuppressesRetainedReuse` focus/press/animation pre-gate
  (`ViewFoundation.swift:275`),
- the `!hasStaleIslandDescendant` island-freshness veto (`ViewNode.swift:621`),
- `supportsRetainedReuse` (viewport barriers / `viewThatFits` / non-reusable
  custom layout — `ResolvedNode.swift:373-389`),
- `environmentSnapshot ==` and `transactionSnapshot.isReuseEquivalent`,
- the `recordReusedSubtree`/`restoreRuntimeRegistrations`/`republishAllEffectRegistrations`
  presence + lifecycle + registration replay.

Today `reusableSnapshot` accepts when `canReuse` holds **and** the subtree is
*disjoint* from the invalidation. The gate adds a **parallel accept condition**:

> accept also when the node passes every `canReuse` conjunct *except* the
> `isDirty`/invalidation-intersection one, **and** its freshly-presented view
> value is structurally equal to the committed view value, **and** the node's own
> recorded dependencies do not intersect this frame's changed set.

i.e. `accept = canReuse-minus-dirty-veto AND (disjoint OR (view-value-equal AND deps-clean))`.
The placement is between the existing `reusableSnapshot` call
(`ViewFoundation.swift:275-299`) and `beginEvaluation` (`:314`) — the single
choke point every node passes through, where the new `V` is already in hand.

**Reject** the looser "sibling early-return between `reusableSnapshot` miss and
`beginEvaluation`" placement (it is the regression's shape). **Do not** generalize
`resolvedNodeReuseCache` (the Toolbar `String`-signature side-cache,
`ViewGraph.swift:453-513`): it keys on a lossy `String(reflecting:)` signature,
sits on the *opposite* side of the `isDirty` veto, and solves the
imperative-strip-without-a-node problem the per-node gate does not have. Reuse its
*idioms* (the erased main-actor comparator, the reuse epilogue), not its container.

## 5. The structural comparator

Layered, computed for two values of the same concrete type `V` (guaranteed by the
resolve seam), **fast path first, conservative fallback last:**

1. **`Equatable` fast path.** `if let l = old as? any Equatable { … }` via the
   existential-opening trampoline already shipping in
   `Sources/SwiftTUICore/Resolve/StateSlot.swift`
   (`makeEquatableComparatorImpl<T: Equatable>`). Sound, cheap, covers value-typed
   leaves (Text/Image/data structs) and any author-`Equatable` view for free.
2. **`EquatableView` / `.equatable()` opt-in** (new). Lets an author certify a
   view — including interactive leaves with closures — and define its equivalence
   explicitly. Sound by construction; the escape valve for the closure ceiling.
3. **`Mirror` field-wise** (non-`Equatable` structs). Walk `Mirror(reflecting:)`
   children pairwise: **skip** dynamic-property-wrapper fields
   (`@State`/`@Binding`/`@Environment`/`@FocusState`/`@GestureState`, detected by a
   marker protocol — their value lives in the node slot / environment, already
   handled by the dependency gate and `environmentSnapshot ==`); compare
   **reference / `@Observable`** fields by `ObjectIdentifier` (mutation is tracked
   via `observableReads`); recurse into nested value structs (Equatable-first);
   **closure fields are *ignored* for equality** (see soundness below);
   `AnyView` / opaque-existential fields force **"changed."** Cache the per-type
   field plan keyed by `ObjectIdentifier(V.self)` so reflection structure is
   computed once per view type, not once per node per frame (`Mirror` allocates;
   uncached it would erase the win on the wide collections this targets).
4. **Fallback: "treat as changed"** → re-run. Always sound; only loses the
   optimization.

**POD/`memcmp` is deliberately omitted:** it needs `unsafe` byte inspection, has
padding-byte false-negatives, is unsound the instant a field is a reference or
closure, and the Equatable path already covers the trivial types worth memoizing.
(Strict memory safety would *permit* it via `unsafe` expressions —
`Scripts/check_concurrency_safety_policies.sh` sanctions scoped `unsafe`, banning
only blanket `@safe`/`@unchecked` — but it is not needed.)

### The load-bearing soundness call: ignoring closures

A view's closures (e.g. `Button.action`, `Sources/SwiftTUIViews/Controls/Button.swift:7`)
get a *fresh context object every frame*, so they can never compare "equal" by
identity, and byte-comparing their captured context is unsound (managed
references) and ABI-fragile. We therefore **ignore closure fields** in the
comparator. This is sound **only because the gate is an AND with the dependency
check**: a closure that captures `@State`/`@Observable` which *changed* will have
dirtied the node through reader attribution regardless of the value compare. The
**residual unsound window** — a closure capturing a value that is *neither* a
compared field *nor* a tracked dependency (a captured non-reactive `let` that
mutated) — is the identical hazard SwiftUI accepts; we accept it as a *documented*
boundary, with `EquatableView` as the author's escape and the **Stage-0 shadow
oracle catching any real occurrence in the corpus before any gating ships.**

## 6. Storage

A comparable view value on `ViewNode` (next to `dependencies`), written at
`finishEvaluation`, read at the gate — shape mirrors `AnyStateSlot` /
`TaskDescriptorIdentitySlot` (`ViewGraphState.swift:176-196`): a boxed
`(value: Any, isEqual: @MainActor (Any) -> Bool)` on the main actor (sidesteps
`Sendable`). Plus a **dependency-*value* snapshot** (not just the identity set):
`observableReads` is object-identity-granular (`Set<ObjectIdentifier>`), so to
recover *property-level* precision on `synthetic-observable-fanout` the gate must
compare the *values read*, not merely the view struct's fields. New stored state
on `ViewNode` requires a `ViewNode.Checkpoint` parity entry
(`ViewNode.swift:1144-1257`) + `recordCheckpointMutation` discipline + a
`ResolvedNodePhaseOwnershipTests` manifest entry + clean-rebuild-everywhere (the
struct-growth guardrail). **Memory cost** (one boxed `Any` + one closure per node)
is real and is itself a Stage-1 measurement against the `reused 0` frames.

## 7. Blast radius — consumers a skipped body must preserve

Because the gate routes through the existing reuse plumbing, most hazards are
**already guarded**; the table records each so the design preserves (never
weakens) them. The unifying principle: *a memoized node takes the identical
post-skip path as today's retained reuse.*

| # | Hazard | Existing guard (preserve) | New requirement |
| --- | --- | --- | --- |
| 1 | runtime-registration republication (action/key/focus/gesture/scroll + effect registries) | `restoreRuntimeRegistrations(for:)` on the reuse branch + `republishAllEffectRegistrations` over persistent `liveNodeIDs` | route through `recordReusedSubtree(retained:)` — **the exact seam the Tier-2 regression bypassed** |
| 2 | capture-hosted islands (AnyView shells, deferred/lazy, `.id` re-root) | `!hasStaleIslandDescendant` veto (`ViewNode.swift:621`) | **AND** the gate with it; view-value equality says nothing about island interiors — never override |
| 3 | `@State` slot allocation / `bodyStateSlotCount` | persistent slots; `max(...)` high-water mark | audit no *new* consumer misreads frame-local `currentBodyStateSlotCount` as 0 for a memoized node |
| 4 | lifecycle (onAppear/onDisappear/task) | `recordReusedSubtree` reconciles presence/task deltas | comparator must include lifecycle-feeding fields (`.task(id:)`) — argues for field-wise, not reference, compare |
| 5 | focus/press reuse-unsafety | `effectiveSuppressesRetainedReuse` pre-gate (`ViewFoundation.swift:275`) | gate sits **behind** it; view-value equality is blind to runtime-injected focus/press |
| 6 | environment propagation | `environmentSnapshot ==` (`ViewNode.swift:623`) | keep the conjunct (orthogonal to value equality) |
| 7 | preference / anchor propagation | carried by value in `ResolvedNode`; effect-republish | none beyond #1 |
| 8 | animation / transition / matched geometry | `transactionSnapshot.isReuseEquivalent` + active-animation suppression scope | keep both; verify matched-geometry pairing tolerates one endpoint reused |
| 9 | scroll / viewport geometry | `supportsRetainedReuse == false` for viewport barriers | keep the conjunct |
| 10 | presentation portals | island veto + identity-prefix restore union | inherit invalidation set faithfully (#11) |
| 11 | **reader attribution is the dependency oracle** | owner-fallback when no reader recorded (`ViewNode.swift:321-327`) | view-value equality must **only deny** reuse the dep-check permits — never *expand* reuse past `conflictsWithInvalidation` + attribution |

## 8. The hardest unknown, and how Stage 0 retires it

**Whether field-wise comparison is BOTH sound AND a net win** — because ignoring
closures (the soundness call) collides with the population that needs memoization
most (interactive leaves), and because the *disjoint* static siblings are
**already** caught by retained reuse, so the *incremental* addressable population
is unproven. Stage 0 converts both into corpus facts before any gating ships:

- an `addressable_memo_skip` count per interaction frame (nodes that *would* skip:
  value-equal + deps-clean + pass all non-dirty `canReuse` guards) — answers
  **payoff**;
- `memo_blocked_{closure,anyview,existential}` counts — quantifies the
  interactive-leaf **ceiling**;
- a **shadow oracle**: for every would-skip node, run the body anyway and assert
  the resolved subtree is byte-identical to the committed snapshot — a single
  mismatch is the closure-capture soundness hazard, caught loudly.

## 9. Staged plan-set

| Stage | Lands | Oracle | Behavior change |
| --- | --- | --- | --- |
| **0 — Diagnostics + shadow oracle** | `#if DEBUG` view-value capture + layered comparator over committed nodes; `addressable_memo_skip` + `memo_blocked_*` TSV columns next to `resolved_computed`/`resolved_reused` (`FrameDiagnosticsTSVFormatting.swift`); shadow byte-identity assertion; `synthetic-memo-closure-capture` adversarial fixture | new characterization suite; shadow byte-identity | **none** — and the **decision gate**: if `addressable_memo_skip` ≈ 0 on interaction frames, **stop here** |
| **1 — Store the value, compare-only** | comparable view-value box + dependency-*value* snapshot on `ViewNode` (Checkpoint parity, wrapper-field exclusion, per-type field-plan cache); still evaluate every node, record "would-skip" | `ViewNode`/`Checkpoint` totality parity; shadow-skip == recompute byte identity in CI | **none** (memory cost measured) |
| **2 — Flip the gate, safe subset, flag-gated** | accept-branch *inside* `reusableSnapshot` ANDed with all guards, routed through `recordReusedSubtree`; fires only for all-comparable-fields nodes (no closures/AnyView/existentials); behind a `ReaderAttributionConfiguration`-style flag, default-off; audit Hazards 3/8 + semantics source | reuse-invariant suites (memo-skip output byte-identical to recompute); `RuntimeRegistrationRestoreScopingTests`; the negative oracle (closure-bearing node must NOT skip, static sibling must) | the win, flag-gated, with before/after `resolve_ms` per scenario |
| **3 — Widen + harden** | recurse into nested view-value fields; `EquatableView`/`.equatable()` opt-in for author-certified interactive leaves; capture-host island + aborted-frame hardening; long-run soak | full gate + Stage-0 adversarial corpus | flag default-on only after soak |

## 10. Smallest first slice (proves the whole path, ~zero blast radius)

**Scenario: `synthetic-narrow-invalidation` (the canary). Comparator: Equatable
only (no `Mirror`).**

1. Use the canary's disjoint static grid (plain `Equatable`-eligible value views —
   no closures, no `AnyView`, no environment dependence: the safe subset by
   construction).
2. Implement only the Equatable trampoline (reuse `StateSlot.swift`'s
   `makeEquatableComparatorImpl<T: Equatable>` verbatim); store the value box on
   `ViewNode` behind the Checkpoint discipline.
3. Add the accept-branch inside `reusableSnapshot`, ANDed with every guard,
   flag-gated default-off, restricted to Equatable-path nodes.
4. Measure on the canary only: `resolved_reused` for the grid should move from ~0
   toward ~100% on the increment frame; `resolve_ms` should flatten across
   `TERMUI_PERF_INVALIDATION_TREE_ROWS` (row-sweep, same-session A/B to beat the
   ±8% canary noise).
5. Oracle: the Stage-0 shadow byte-identity assertion on this one scenario.

This exercises the entire mechanism — comparable storage, the AND-with-deps gate,
the accept-branch-inside-`reusableSnapshot` plumbing, the byte-identity oracle, a
measurable `computed→reused` swing — touching **zero** closure / AnyView / island
/ focus-press / lifecycle-sensitive nodes. If the canary does not move here, the
full `Mirror` version will not pay off either, and the project is spared the
very-high-blast-radius work.

## 11. Validation (per scenario)

| scenario | role | expected effect once Stage 2/3 land |
| --- | --- | --- |
| `synthetic-narrow-invalidation` | first-slice proof + canary | grid subtree `reused 0 → ~100%`; `resolve_ms` flat in rows |
| `file-browser-selection` | headline representative | non-active columns memoize; per-move `reused 0/349 → mostly reused` |
| `gallery-tab-switch` | headline representative | unchanged tab-bar buttons + stable chrome memoize on swap frames |
| `text-input-editing` | representative | the static form memoizes across keystrokes (the field/mirror still re-run) |
| `synthetic-observable-fanout` | precision probe | the dependency-*value* snapshot recovers property-level precision (17 → hot readers) |
| `sheet-44`, `narrow-40` | no-regression canaries | within noise; registration byte-identity holds |

## 12. Open questions / residual audits (carry into Stage 1-2)

- **Dependency-value snapshot shape** (Gap C): exactly which read values to
  snapshot, and the memory/CPU cost of doing so per node.
- **`currentBodyStateSlotCount` consumers** (Hazard 3) and **semantic-extraction
  source** (must read the committed tree incl. reused subtrees, not a
  "visited-this-frame" set).
- **Matched-geometry pairing across a memoized boundary** (Hazard 8) — needs a
  targeted test (only one endpoint dirtied).
- **Long-lived-memoized-subtree eviction** — `liveNodeIDs` is persistent; a
  subtree memoized for many consecutive frames is far more common than today;
  soak/long-run test against `removeSubtree` eviction.
- **Memory budget** of per-node value boxes against the `reused 0` frames this
  targets — measured in Stage 1, watched via `memory_growth.tsv`.

## 13. References

- VISION-GAP "dependency-aware body re-evaluation": `swift-tui/docs/VISION-GAP.md:91`.
- Gap G8 (cost/risk rating): [2026-06-13-swifttui-invalidation-gap-analysis.md](../reports/2026-06-13-swifttui-invalidation-gap-analysis.md):386-401.
- Tier-1 framing + the reverted Tier-2 narrowing (the regression this design must not repeat): [2026-06-17-001-perf-tier2-constant-factor-cleanup-plan.md](2026-06-17-001-perf-tier2-constant-factor-cleanup-plan.md), [2026-06-17-perf-tier2-and-focus-press-narrowing-revert.md](../reports/2026-06-17-perf-tier2-and-focus-press-narrowing-revert.md).
- Staging template: [2026-06-03-001-first-class-structural-identity-proposal.md](2026-06-03-001-first-class-structural-identity-proposal.md).
- Key seams: `ViewNode.swift:611-629` (`canReuse`), `ViewGraph.swift:1509-1598` (`reusableSnapshot`), `ViewFoundation.swift:256,275-299,314,321-323` (resolve seam + evaluator capture), `DependencySet.swift` + reader attribution, `StateSlot.swift` (`makeEquatableComparatorImpl` trampoline to reuse), `ViewGraphState.swift:176-196` (`TaskDescriptorIdentitySlot` erased-comparator idiom), `AnyTransition.swift:215` / `App.swift:64` (Foundation-free `Mirror` precedent).
