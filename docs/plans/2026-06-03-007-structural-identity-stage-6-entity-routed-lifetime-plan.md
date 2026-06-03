# Structural Identity — Stage 6: Entity-Routed Lifetime & State Re-rooting

**Date:** 2026-06-03
**Status:** Plan. Not started. Depends on Stages 3 and 5. **The capstone — the
only stage that intentionally changes observable behavior.**
**Stage:** 6 of the structural-identity migration. This realizes StateTree's
`LSID → NodeID` lesson in SwiftTUI: a persistent `EntityIdentity → ViewNodeID`
routing table that lets runtime lifetime (and therefore `@State`, animation, and
focus) **survive transformations that change the runtime identity**, when entity
identity proves it is the same entity — and die when it does not.
**Entry point:**
[`2026-06-03-001-first-class-structural-identity-proposal.md`](2026-06-03-001-first-class-structural-identity-proposal.md).
**Predecessors:**
[Stage 3 — Entity Identity](2026-06-03-004-structural-identity-stage-3-reconciliation-entity-identity-plan.md),
[Stage 5 — `ViewNodeID`](2026-06-03-006-structural-identity-stage-5-viewnodeid-lifetime-split-plan.md).
**Verified against:** `swift-tui` working tree at commit `a020fa55`.

---

## Executive summary

After Stage 5, `ViewNodeID` is a real runtime-lifetime key — but its lifetime is
still **derived from `Identity`**: a node keeps its `ViewNodeID` exactly as long
as its final `Identity` persists, no longer. So `@State`, animation continuity,
and focus still silently reset whenever a transformation changes the runtime
identity even though it is "the same thing" to the user: a row moving between two
lists, a view gaining or losing a wrapper, an `.id` added or removed.

Stage 6 closes that gap. It adds the one structure recon confirmed SwiftTUI does
**not** have — a persistent `EntityIdentity → ViewNodeID` routing table (zero
`LSID`/`LifetimeID`/`EntityID` matches across the codebase; `Identity` equality
through `CollectionDifference.inferringMoves()` *is* the routing today,
`StructuralDiff.swift:23`). With the table, reconciliation routes a reappearing
entity to the `ViewNodeID` that hosted it last frame, so its state moves with it.

This is the architectural payoff, and it is where the migration stops being
plumbing and starts being a *better framework*. State that survives a refactor
the user considers cosmetic — pulling a row into a different container, wrapping a
view in a conditional — is the difference between a framework that feels solid and
one that feels haunted. SwiftUI gets this subtly wrong in places precisely
because it conflates these axes; SwiftTUI can get it right because Stages 2–5
separated them first.

## What changes (and what must not)

This is the only stage whose oracle is **not** "byte-identical to before" — the
whole point is that some lifetimes now survive where they used to reset. The
oracle is instead *SwiftUI-aligned characterization*: for each transformation
class, the documented, tested behavior of whether lifetime survives.

| Transformation | Pre-Stage-6 | Post-Stage-6 | Rationale |
| --- | --- | --- | --- |
| `ForEach` reorder, stable ids | survives | survives | entity id stable (already worked; now via the table, not string coincidence) |
| `ForEach` element moved to a **different** `ForEach`/container, same id | resets | **survives** | same `EntityIdentity` → routed to same `ViewNodeID` |
| View gains/loses a wrapper (`if`, `Group`, `AnyView`) but keeps `.id` | resets | **survives** | entity id proves same entity |
| `.id` value **changes** | resets | resets (unchanged) | different entity = different lifetime (correct) |
| No entity id, structural slot changes | resets | resets (unchanged) | unkeyed = positional; SwiftUI-aligned |
| Duplicate ids | aliased (bug) | distinct; stable only while collision order is stable, else conservative rebuild | Stage 3 occurrence + Stage 5 distinct `ViewNodeID` (containment, not full routing — see L6.5) |

The hard invariant that must **not** regress: the closure-owner-vs-per-element
`@State` ownership rule. Today `@State` captured by a `ForEach` element closure is
owned by the *enclosing* `viewIdentity` (so it is shared/stable across rows),
while `@State` declared *inside* a per-element view is owned per element
(`State.swift:248-256`, `AuthoringContext.swift:31-51`). Stage 6 re-roots both
onto `ViewNodeID`, but the *which-owner* distinction is preserved exactly:
closure-captured state → the closure owner's `ViewNodeID`; element-view state →
the element's (entity-routed) `ViewNodeID`.

## Current state

Verified at `a020fa55`:

- `@State` keys storage by graph-scoped `viewIdentity` + `StateSlotOrdinals.authored(line, column)`
  (`State.swift:206-209`; ordinal packs `(line << bits) | column`, `:31-37`).
  `StateSlotKey{identity, ordinal}` (`DependencySet.swift:1-9`) flows into
  `stateSlotDependents`, `stateMutationKeys`, and the per-node `DependencySet`.
  `@FocusState`/`@GestureState` use the identical `StateSlotOrdinals.authored`
  path (`FocusState.swift:131`, `GestureState.swift:200`).
- `ViewNode.stateSlots` is keyed by `Int` ordinal; the **owner** is supplied
  implicitly by the owning `ViewNode` (which is `nodesByIdentity`-keyed today,
  `ViewNodeID`-keyed after Stage 5). Recon: "State semantics WANT runtime
  lifetime — survives reuse but must die when the node truly disappears."
- Graph-scope isolation is a **string splice**: `stateStorageIdentity` appends a
  synthetic `__SwiftTUIStateGraph[<scope>]` component to `viewIdentity` and
  `graphScopeID(from:)` / `baseStateStorageIdentity` parse it back
  (`AuthoringContext.swift:83-116`). `baseStateStorageIdentity` assumes `.parent`
  strips exactly that one component — fragile under any path-format change.
- Animation continuity already retains identities **one frame past presence**:
  `AnimationController.previousTransitionsByIdentity` / `removingIdentities`
  (`AnimationController.swift:60-68`) deliberately keep a removed view's
  transition findable after its branch is gone. This is the exact lifetime
  semantics the routing table generalizes.

## Design: the routing table (the LSID-analog)

```swift
package struct EntityRoutingTable: Sendable {
  // Persistent across frames. The link Stage 5 left derived-from-Identity.
  private var nodeIDByEntity: [EntityIdentity: ViewNodeID]
  private var entityByNodeID: [ViewNodeID: EntityIdentity]

  // Reconciliation (Stage 3) consults this BEFORE minting a new ViewNodeID:
  package func route(_ entity: EntityIdentity) -> ViewNodeID?  // same entity last frame?
  package mutating func bind(_ entity: EntityIdentity, to node: ViewNodeID)
  package mutating func release(_ node: ViewNodeID)             // entity truly gone
}
```

The routing rule, layered onto Stage 3's reconciliation and Stage 5's minting:

```text
when resolving a child with EntityIdentity E:
  if table.route(E) yields a ViewNodeID that is still valid → reuse it (lifetime moves with E)
  else                                                       → mint a fresh ViewNodeID, bind E
when an EntityIdentity is absent this frame (and not merely moved):
  release its ViewNodeID → its @State/animation/focus die (correct teardown)
```

The subtlety StateTree teaches: a value that *moves* is not a value that *dies*.
The table distinguishes "E appeared somewhere new" (route, preserve lifetime)
from "E is gone" (release, tear down). Getting that distinction wrong in either
direction is a bug — leaked state on one side, lost state on the other — so the
release decision is made at the reconciliation barrier where the full
old-vs-new entity set is known, not per-subtree.

## Mechanics

### L6.1 — The persistent routing table
Add `EntityRoutingTable` to `ViewGraph`, consulted at the find-or-create choke
point (`ViewGraph.swift:1118-1129`, now `ViewNodeID`-minting after Stage 5).
Reconciliation (Stage 3) provides the per-frame old/new entity sets; the table's
`route`/`release` run at that barrier. Entities without an explicit id (unkeyed
positional nodes) are **not** table-routed — they keep Stage 5's
structural/positional lifetime, which is the SwiftUI-aligned "unkeyed = position"
behavior.

### L6.2 — Re-root `@State` onto `StateSlotIdentity`
Replace `StateSlotKey{identity, ordinal}` with `StateSlotKey{owner: ViewNodeID,
ordinal: StateSlotOrdinal}` (the graph-scope dimension from L6.3 wraps this into
the full `StateSlotIdentity`; see *Naming* below). The **owner** is resolved
through the routing table, so element-view `@State` follows the entity-routed
`ViewNodeID`.

### L6.2a — Specify the owner carrier (the part recon warns a naive split breaks)
The closure-owner-vs-per-element distinction is carried **today** by
`AuthoringContext.viewIdentity` (an `Identity`) plus the active `viewNode`, set
*differently* in the two scopes: element-body `@State` runs under
`makeAuthoringContext(elementContext)` (`viewIdentity` = the element identity,
`viewNode` = the element's graph node), while closure-captured `@State` runs under
`ForEach`'s per-iteration scope (`viewIdentity` = `scope.viewIdentity` = the
closure owner). Demoting `Identity` to a debug projection removes that carrier, so
Stage 6 must **replace it explicitly**, not assume it survives:

- Introduce an **owner `ViewNodeID`** field on `AuthoringContext`, replacing the
  load-bearing `viewIdentity` for *ownership* purposes.
- The element-body authoring context carries the **element's** (entity-routed)
  `ViewNodeID`; `ForEach`'s per-iteration scope carries the **closure owner's**
  `ViewNodeID`. Closure-captured state therefore does **not** route through the
  entity table (the closure owner has no `EntityIdentity`) — it stays on the
  owner's node, exactly as today.

If this carrier migration is skipped, both element-view and closure-captured
`@State` resolve to the same node and the rule collapses (shared state leaks into
per-row, or per-row state is shared). This is the single most behavior-sensitive
edit in the migration; it is gated by the characterization suite (Test #4), not a
byte oracle.

### L6.3 — Replace the graph-scope string splice with a typed dimension
`__SwiftTUIStateGraph[<scope>]` becomes a typed `graphScope` dimension on
`StateSlotIdentity` rather than a component spliced into a path string and parsed
back. Preserve the same-instance `DefaultRenderer` fallback and the
`StateGraphBindingRegistry` / `GestureStateGraphBindingRegistry` isolation that
the string scheme provides today. This removes the last `Identity`-path string
dependency from `@State`.

> **Naming (used consistently across the plan set).** `StateSlotKey =
> {owner: ViewNodeID, ordinal: StateSlotOrdinal}` is the per-owner runtime map key
> (what `stateSlotDependents` and `ViewNode.stateSlots` key on). `StateSlotIdentity
> = (graphScope, StateSlotKey)` is the full graph-scoped identity — the fourth
> axis. L6.2 re-roots the `owner` inside `StateSlotKey`; L6.3 adds the `graphScope`
> wrapper. The entry point's four-axis table uses the `StateSlotIdentity` name for
> the axis.

### L6.4 — Route animation/focus/gesture lifetime through the table
Generalize the "survive moves" win beyond `@State`:
- `AnimationController`'s snapshot/transition maps (already
  `ViewNodeID`-keyed after Stage 5) consult the routing table, so a moved view's
  animation continuity and a removed view's exit transition follow the entity.
- Focus survives a focused element moving (the table keeps its `ViewNodeID`, so
  `currentFocusIdentity`'s node persists).
- `@GestureState` reset bindings and in-flight gesture recognizers
  (`LocalGestureRegistry` active-preservation) follow the routed `ViewNodeID`.

### L6.5 — Duplicate-id endgame (and an honest limit)
With Stage 3's `EntityIdentity.occurrence`, Stage 5's distinct `ViewNodeID`s, and
the routing table, duplicate ids yield **distinct lifetimes that are stable *only
while the collision scope's membership and order are stable.*** They are
contained (distinct lifetimes, diagnostic emitted), never aliased — which is the
real win over today's silent last-writer-wins.

But occurrence is a *containment* mechanism, not a lifetime-routing key for
duplicates, and the limit must be stated plainly. `occurrence` is assigned by
resolved order, so if the collision *count* changes, the survivor mis-aligns:
ids `[A,A,B]` → `A#0,A#1,B#0`; remove the *first* `A` → the survivor (was `A#1`)
becomes `A#0` and routes to a *different* `ViewNodeID`, resetting its state even
though "the same" `A` persisted. Stage 3's conservative fallback (rebuild the
affected scope) keeps this *safe* but means duplicate-id siblings get **no**
cross-reorder lifetime preservation in that case. This is acceptable — duplicate
ids are user error and undefined in SwiftUI too — but the plan must not pretend
otherwise. This is the closure of the thread that started as Stage 1's
"duplicate-identity policy: existence resolved, policy open": **resolved as
contained, not as fully lifetime-preserving.**

## Tests (characterization, not byte-equivalence)

1. **State survives a cross-container move.** A `.id`-keyed view moved between two
   containers keeps its `@State`. (New behavior — the headline.)
2. **State survives a wrapper toggle.** Wrapping/unwrapping a keyed view in
   `if`/`Group`/`AnyView` keeps its `@State`.
3. **State resets on a genuine identity change.** Changing the `.id` value resets
   state (different entity = different lifetime). Removing the entity entirely
   tears down state (no leak).
4. **Closure-owner rule preserved.** `@State` captured by a `ForEach` element
   closure stays shared/stable across rows; `@State` inside the row view is
   per-row and entity-routed. Both correct simultaneously.
5. **Animation/focus follow the entity.** A moving view's animation continuity
   and focus survive the move; a removed view's exit transition still plays.
6. **Duplicate ids get distinct, contained lifetimes.** Two duplicate-id elements
   maintain independent `@State` across reorders **that preserve collision order**;
   on a collision-count change the scope falls back to conservative rebuild (state
   not preserved — the documented limit). The diagnostic fires once either way.
7. **No leak under churn.** A stress test that rapidly inserts/removes/moves keyed
   entities asserts the routing table releases every truly-gone entity (no
   unbounded `nodeIDByEntity` growth) — the leak regression test.
8. **SwiftUI alignment.** Where SwiftTUI claims SwiftUI-shaped behavior, the
   covered transformation classes match SwiftUI's documented identity semantics
   (scoped to what the suite covers; per the repo's "no compatibility claim
   beyond tests" rule).

Suites: a new `EntityRoutingTests` (the transformation matrix above), plus
extensions to `StateTests`, `StateSlotTests`, `FocusStateTests`,
`GestureStateTests`, `AnimationTransitionTests`, and the `ForEach`/collection
suites.

## Execution order and touchpoints

| Step | Lands | Primary files |
| --- | --- | --- |
| L6.1 | `EntityRoutingTable` + reconciliation barrier hookup | `Resolve/ViewGraph.swift:1118-1129`, `Resolve/ViewGraphStructuralReconciliation.swift`, `Resolve/StructuralDiff.swift` |
| L6.2 | `StateSlotKey` re-root onto `ViewNodeID` owner | `SwiftTUICore/Resolve/DependencySet.swift:1-9`, `SwiftTUICore/Resolve/ViewNode.swift:169-244`, `SwiftTUICore/Resolve/ViewGraph.swift:115,247-257`, `SwiftTUIViews/State/State.swift:206-266` |
| L6.2a | owner-`ViewNodeID` carrier on `AuthoringContext` (closure-owner rule) | `SwiftTUIViews/State/AuthoringContext.swift:29-65`, `SwiftTUIViews/Collections/ForEach.swift:36-44` (per-iteration scope), `SwiftTUIViews/Foundation/ViewFoundation.swift` (makeAuthoringContext) |
| L6.3 | typed graph-scope dimension (delete string splice) | `State/AuthoringContext.swift:83-116`, `State/State.swift`, `State/GestureState.swift` |
| L6.4 | entity-routed animation/focus/gesture lifetime | `SwiftTUIRuntime/Lifecycle/AnimationController.swift`, `Semantics/FocusTracker.swift`, `Runtime/LocalGestureRegistry.swift`, `Runtime/LocalGestureStateRegistry.swift` |
| L6.5 | duplicate-id endgame + final policy doc | `Collections/ForEach.swift`, diagnostics |

L6.1 and L6.2 land together (the table is pointless without state re-rooting to
consume it). L6.4–L6.5 follow once the @State case is proven.

## Validation

```bash
swift test --package-path swift-tui --filter EntityRoutingTests
swift test --package-path swift-tui --filter StateTests
swift test --package-path swift-tui --filter StateSlotTests
swift test --package-path swift-tui --filter FocusStateTests
swift test --package-path swift-tui --filter GestureStateTests
swift test --package-path swift-tui --filter AnimationTransitionTests
swift test --package-path swift-tui            # full suite
bazel test //:org_full
```

Perf: the routing table adds a per-entity lookup at reconciliation. Confirm
rows=6/20/40 shows no `resolve_ms` regression, and that the table's memory stays
bounded under the churn stress test (L6.4 test 7).

## Risks and non-goals

- **Do not** route unkeyed positional nodes through the table. Unkeyed lifetime is
  structural/positional (SwiftUI-aligned); only explicit `EntityIdentity` routes.
- **Do not** break the closure-owner-vs-per-element `@State` rule. This is the
  one behavior recon explicitly warns a naive split destroys.
- **Do not** leak. Every truly-gone entity must be released at the reconciliation
  barrier; the churn stress test is mandatory, not optional.
- **Do not** claim SwiftUI compatibility beyond the transformation classes the
  suite covers (repo non-goal).
- **Do not** keep the `__SwiftTUIStateGraph` string splice. The typed graph-scope
  dimension replaces it; leaving the string is leaving the last `Identity`-path
  coupling in `@State`.

## What this stage completes

With Stage 6 landed, the four axes are fully separated and each lives in its
correct home:

- **Runtime lifetime** = `ViewNodeID`, entity-routed.
- **Structure** = `StructuralPath`, prefix-relational.
- **Entity** = `EntityIdentity`, the routing key.
- **State slots** = `(graphScope, owner ViewNodeID, ordinal)`.

`Identity` survives only as the **serialized public/debug projection** (snapshots,
accessibility bridge, fixtures) — it keys no runtime index, scopes no state, and
proves no containment. The overload that started this whole effort is gone, and
the registration-alias layer, the duplicate-id aliasing, and the string-encoded
handler ids that were all symptoms of it are gone with it.

## Open questions

1. Should the routing table be global or per-`graphScope`? Per-scope matches the
   `__SwiftTUIStateGraph` isolation it replaces and bounds churn; leaning
   per-scope.
2. How long should a released entity's `ViewNodeID` be retained before reuse —
   one frame (matching `AnimationController.previous*`'s one-frame grace) or
   zero? Leaning one frame, to align with exit-transition lifetime.
3. Does entity routing subsume `CollectionDifference.inferringMoves()` (Stage 3
   OQ#3), or do they coexist (table for keyed, `inferringMoves` for unkeyed)?
   Leaning coexist: the table handles entity-keyed lifetime; `inferringMoves`
   handles unkeyed positional ordering.
