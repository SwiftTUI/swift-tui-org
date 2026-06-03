# Structural Identity — Stage 2: Resolve-Time Structural Identity

**Date:** 2026-06-03
**Status:** Plan. Not started. Depends on Stage 1 (doc 004) types.
**Stage:** 2 of the structural-identity migration. This is the first half of
001's **Option B** — make structural identity first-class *during resolve*, not
just a post-commit sidecar.
**Entry point:**
[`2026-06-03-001-first-class-structural-identity-proposal.md`](2026-06-03-001-first-class-structural-identity-proposal.md).
**Predecessors:**
[Stage 1 — Persistent Retained Index](2026-06-02-004-persistent-retained-index-structural-adjacency-proposal.md),
[Stage 0 — Divergence Diagnostics](2026-06-03-002-structural-identity-stage-0-divergence-diagnostics-plan.md).
**Verified against:** `swift-tui` working tree at commit `a020fa55`.

---

## Executive summary

Stage 1 reconstructs structural adjacency *after* commit, by walking the
committed tree. That is correct but late: every consumer that wants to reason
about "where does this node sit" has to wait for the retained index, and the
retained index has to re-derive structure the resolve pass already knew. Stage 2
moves the structural axis to its source — it makes **builder-slot structural
identity** a first-class property of `ResolveContext` and `ResolvedNode`, emitted
at the moment a child is authored.

The crucial realization from reconnaissance: SwiftTUI is *already half-built for
this*.

- `IdentityComponent` (`GeometryTypes.swift:560-583`) is exactly the
  structural-component vocabulary — `.named(StaticString)` and
  `.indexed(kind:index:)` — we would otherwise invent.
- `AuthoringContext` (`AuthoringContext.swift:29-65`) already carries the
  conceptual split: `viewIdentity` (owner) vs `structuralIdentity` (position).
  Only **two** sites read `structuralIdentity` — `.panel()` (`Panel.swift:101`)
  and implicit-id `NavigationStack()` (`NavigationStack.swift:71`) — so the
  consumer surface is small and enumerable.
- There are exactly **three** identity-deriving primitives on `ResolveContext`:
  `child(component:)` (`ResolveContext.swift:133`),
  `indexedChild(kind:index:)` (`:171`), and `replacingIdentity(with:)` (`:179`).
  Every structural-path append in the framework flows through the first two; the
  third is the *entity* hook (`.id`, `ForEach`) and must be handled differently.

Stage 2 exploits those three choke points. It does **not** yet split entity
identity from structural position for repeated elements — that is Stage 3. Stage
2's job is narrower and load-bearing: make positional/builder structure explicit,
authoritative, and carried on the node, so Stage 1's retained index consumes a
resolve-time structural path instead of reconstructing one, and so every
downstream stage has a real structural carrier to attach to.

## Scope boundary (read this before arguing about ForEach)

001's terminology section draws the line this stage honors:

- **Builder-slot structural identity** — a child produced by a `ViewBuilder`
  expansion, stack child list, conditional branch, modifier role, or the
  *collection source slot* of a `ForEach`. **This is Stage 2.**
- **Entity identity** — the explicit `.id` / `ForEach` element id that should
  route runtime lifetime across reorders. **This is Stage 3** (the axis) and
  **Stage 6** (the routing table).

So in Stage 2, a `ForEach` records its **collection source slot** as a real
structural parent **and emits a per-element positional ordinal** so each element
has a distinct structural slot (`ForEach[0]`, `ForEach[1]`, …). What is deferred
to Stage 3 is the **entity id** — the stable-across-reorder routing key — *not*
the positional ordinal. The two are different axes and Stage 2 must not conflate
them: the ordinal is positional (it shifts when a sibling is inserted), the entity
id is stable (it follows the element across a reorder).

> **Why the ordinal is not free (the subtle part).** Today `ForEach` calls
> `indexedChild(kind: "ForEach", index:)` **once for the whole collection**
> (`ForEach.swift:77-82`), then derives each element via
> `replacingIdentity(with: …explicitID(…))` (`:25-28`). The per-element
> divergence flows through `replacingIdentity`, which — by this stage's invariant
> — does **not** advance `structuralPath`. So without an explicit fix, every
> element collapses to the *same* `ForEach[0]` path. Stage 2 therefore adds a
> per-element *structural* ordinal advance (an `indexedChild`-style append,
> distinct from the collection's single container slot) **before** the entity
> `replacingIdentity`. This is a real new emission, not a rename — and it is
> exactly what lets `.panel()` read a distinct-per-element structural id without
> depending on the entity string (`PanelTests` asserts 3 elements → 3 distinct,
> stable ids; a positional ordinal satisfies both, order permitting). The lazy
> path (`IndexedChildSources.child(at:)`) needs the identical per-element ordinal.

## Current state

Verified at `a020fa55`:

- **`ResolveContext.identity`** (`ResolveContext.swift:27`) is the authored
  identity threaded through resolution. `indexedChild(kind:index:)` appends a
  `"<kind>[<index>]"` component (`:171-177`); `appendDeclaredChildNodes` calls it
  with the view's kind name (`ViewFoundation.swift:54-57`), e.g. `VStack` passes
  `kindName: "VStack"` (`VStack.swift:22-24`) producing `.../VStack[0]`.
  Conditionals append a branch component
  (`context.child(component: .init(rawValue: "true"))` /`"false"`,
  `ConditionalContentView.swift:37,49`). Roughly 15+ modifier content slots use
  `.named(...)` (`ViewLayoutModifierTypes.swift`).
- **`ResolvedNode` carries no structural field.** Its fields
  (`ResolvedNode.swift:11-134`) are `identity, kind, typeDiscriminator,
  _storedChildren, …` — adjacency is *only* the `_storedChildren` array plus the
  `Identity` `[String]` path. A grep for `structuralParent`/`childKey` over
  `ResolvedNode.swift` returns nothing. The only structural-key abstraction,
  `ChildDescriptor`, *synthesizes* its key from `identity + explicitID + kind`
  (`ChildDescriptor.swift:26-39`), re-parsing `explicitID` out of the identity's
  last component by matching `ID[` (`:67-77`).
- **The children setter folds up aggregates on every write**
  (`ResolvedNode.swift:36-45`): `recomputePreferenceValues`,
  `recomputeSubtreeNodeCount`, `recomputeCustomLayoutFallbackSummary`,
  `recomputeSupportsRetainedReuse`. The shape-preserving fast path
  `setChildrenPreservingDerivedState` (`:57-59`) skips these and is used by
  animation tick frames.
- **All three equivalence walks gate on `identity ==` first**
  (`ResolvedNodeEquivalence.swift`): `isEquivalentForMeasurement`,
  `isEquivalentForPlacement`/`placementEquivalence`, and `==`.
- **The hard case is `replacingIdentity`.** `.id(_:)`
  (`ViewMetadataModifiers.swift:187-212`) and `ForEach`
  (`ForEach.swift:26-28`) substitute a *content-derived* identity that has no
  structural-positional meaning. This is precisely where structural and runtime
  identity genuinely diverge and must be tracked independently.

## Design: the structural carrier

Add a `StructuralPath` — an ordered list of structural components — alongside
`identity` on `ResolveContext`, and a derived `StructuralNodeKey` plus the path on
`ResolvedNode`. Reuse `IdentityComponent` rather than invent a parallel
vocabulary:

```swift
package struct StructuralPath: Hashable, Sendable {
  package let components: [IdentityComponent]   // reuse existing .named/.indexed
  package func appending(_ c: IdentityComponent) -> StructuralPath
  package var parent: StructuralPath? { ... }   // structural ancestry, by construction
  package func isAncestor(of: StructuralPath) -> Bool  // component-wise prefix
}
```

The invariant that makes this worth the migration:

> **`StructuralPath` advances only through `child`/`indexedChild`. It does NOT
> advance through `replacingIdentity`.** When `.id`/`ForEach` mint a
> content-derived runtime `Identity`, the structural path of the affected view
> stays at its authored builder slot. Structure stops being a projection of the
> runtime identity string and becomes an independently authored fact.

This is the mechanical heart of 001's `.id` hard case ("structural parent
remains the authored child/modifier slot; entity identity becomes id"). It falls
out almost for free because the work concentrates in the three primitives:

| Primitive | Today (identity) | Stage 2 (adds) |
| --- | --- | --- |
| `child(component:)` `:133` | append to `identity` | **also** append to `structuralPath` |
| `indexedChild(kind:index:)` `:171` | append `kind[index]` to `identity` | **also** append `.indexed(kind:index:)` to `structuralPath` |
| `replacingIdentity(with:)` `:179` | replace `identity` wholesale | **keep `structuralPath` unchanged** |

Because every container, conditional, tuple, variadic, and `.named` modifier slot
routes through `child`/`indexedChild`, threading the path through those two
functions covers the entire positional surface in one place. The per-view edits
are minimal; the primitives do the work.

**The one exception — repeated elements.** `ForEach` and the lazy/indexed sources
do their per-element divergence through `replacingIdentity`, not `indexedChild`
(see the Scope-boundary note above), so the two primitives do **not** cover them.
Stage 2 adds an explicit per-element positional-ordinal advance at the `ForEach`/
lazy element sites so each element carries a distinct `ForEach[i]` structural
slot. This is the only positional emission outside the two primitives, and it is
what `.panel()` reads.

### Relationship to Stage 1's `StructuralNodeKey`

Stage 1 assigns a per-frame `StructuralNodeKey` (UInt64) during indexing and
notes that cross-frame correspondence is re-established "by structural position —
the stable structural locator/path plus sibling ordinal." Stage 2 **is** that
stable structural locator: `ResolvedNode.structuralPath` is the cross-frame
anchor Stage 1 described abstractly. After Stage 2, Stage 1's retained index
derives its `StructuralNodeKey` from the resolve-time `structuralPath` directly,
instead of reconstructing adjacency from the children walk. The two stages
converge here: Stage 1's "structural position" anchor and Stage 2's
"resolve-time structural path" are the same object.

## Mechanics

### L2.1 — Type the `AuthoringContext` seam

Promote `AuthoringContext`'s two `Identity` fields toward typed roles. Keep
`viewIdentity: Identity` (owner) as-is, and introduce the structural carrier so
that `structuralIdentity`'s two readers (`.panel()`, implicit `NavigationStack`)
read a `StructuralPath`-derived stable id rather than a raw `Identity`. Preserve
the default-equal contract for non-iterating sites (`AuthoringContext.swift:60`):
where `structuralPath` is not explicitly diverged, it mirrors the authored
position. This is the seam recon recommends formalizing first.

### L2.2 — Attach structure to `ResolvedNode`

Add `structuralPath: StructuralPath` (and a frame-local `structuralKey:
StructuralNodeKey` populated by Stage 1's indexer) to `ResolvedNode`. This
touches:

- the struct fields and both inits (`ResolvedNode.swift:11-134`);
- the children setter — decide whether `structuralPath` participates in any
  fold-up aggregate. It should **not** change `subtreeNodeCount` semantics, but
  it must be covered by the subtree signature (Stage 1 L2). Critically,
  `setChildrenPreservingDerivedState` (`:57-59`) assumes shape-stable children:
  `structuralPath` is invariant under that fast path (animation ticks change
  numeric content, not authored position), so the no-recompute assumption holds —
  document this explicitly;
- the three equivalence walks (`ResolvedNodeEquivalence.swift`). Each currently
  gates on `identity ==`. Stage 2 decides, per walk, whether structural-path
  equality is the right gate. Measurement/placement equivalence should prefer
  `structuralPath` (position) over runtime `identity` so a `.id` change that does
  not move a node does not defeat layout reuse — but this is a *behavior-relevant*
  choice and must be guarded by the Stage 1 L2 byte-equivalence oracle.

### L2.3 — Emit structural components at the primitives (plus the repeated-element ordinal)

Thread `structuralPath` through `child`/`indexedChild`, leave it unchanged in
`replacingIdentity`, and confirm via the divergence harness (Stage 0) that the
positional surface is fully covered: containers (`ViewFoundation.swift:54`),
conditionals (`ConditionalContentView.swift:37,49`), tuple/variadic children, and
the `.named` modifier slots (`ViewLayoutModifierTypes.swift`). **Then add the
per-element positional ordinal** at the two repeated-element sites that diverge
through `replacingIdentity` rather than `indexedChild`: eager `ForEach`
(`ForEach.swift:25-28,77-82`) and the lazy path. Lazy/indexed
containers materialize element identities inside
`makeIndexedChildSource` / `IndexedChildSource.child(at:)`
(`IndexedChildSources.swift`) — the structural component for a data-backed lazy
row is the collection source slot plus the element ordinal, emitted at
`child(at:)`; this is the one site outside the two primitives that needs explicit
handling.

### L2.4 — Re-source `ChildDescriptor`'s structural component

`ChildDescriptor` currently re-parses `explicitID` from the identity string and
fuses `identity + explicitID + typeIdentity + typeDiscriminator` for diff
equality (`ChildDescriptor.swift:41-77`). Stage 2 makes the descriptor read the
node's explicit `structuralPath` for its positional component instead of parsing
it out of a string. The full reconciliation-key redesign (separating entity
identity) is **Stage 3**; Stage 2 only stops the string-parse and points the
descriptor at the authoritative carrier. The `ID[...]` suffix continues to be
preserved on the runtime `Identity` so explicit-id stability is unaffected this
stage.

### L2.5 — Debug snapshots and the test re-projection helper

Add `structuralPath` to debug snapshots (`ViewGraphDebugSnapshots.swift`,
`ViewNodeDebugSnapshots.swift`). Then route the path-string assertions that Stage
2 will break through a single re-projection helper. Recon identified the dominant
cost: `SwiftUISurfaceTests` has ~44 assertions of literal projected paths (e.g.
`testIdentity("Root","true","VStack[1]")`, handler-ids like
`"Root/true/Group[0]#appear[0]"`), and three duplicate `testIdentity(_:)`
helpers (`TestIdentitySupport.swift` in three test targets) funnel
`Identity(components:)`. Introduce a structural-aware constructor in those three
helpers so most suites recompile with one edit each, and re-project the literal
path assertions from the new `structuralPath` rather than hand-editing 44 call
sites.

## Tests

1. **Positional structure is authoritative.** For container/conditional/tuple
   trees, assert `structuralPath.parent` equals the real children-array parent's
   path for every node (the Stage 0 harness, now reading the resolve-time field).
2. **`.id` does not move structure.** A `.id(_:)` on a `VStack`'s third child
   keeps that child's `structuralPath` at `VStack[2]` while its runtime
   `Identity` gains the `ID[...]` suffix. Parent invalidation rebuilds the child
   structurally.
3. **`replacingIdentity` leaves structure put.** Assert that every site calling
   `replacingIdentity` (`.id`, `ForEach` element, navigation, pointer-route) does
   not advance `structuralPath`.
4. **Layout reuse survives a pure `.id` change.** With L2.2's equivalence choice,
   a frame that only changes a node's `.id` (not its position) must still reuse
   measurement/placement — guarded by the Stage 1 L2 oracle (patched == rebuilt).
5. **`.panel()` / `NavigationStack` id stability preserved — via the per-element
   ordinal.** `PanelTests` asserts 3 `ForEach` elements yield 3 distinct, stable
   panel ids. With `.panel()` reading the per-element `ForEach[i]` *structural
   ordinal* (not the entity string), the distinctness comes from the ordinal and
   stability from stable resolved order. This test is the proof that Stage 2's
   per-element ordinal emission actually lands; without it the ids collapse to one.
   The implicit-`NavigationStack` id behavior stays green for the same reason.
6. **Lazy container structure.** A lazy stack's source slot has a stable
   `structuralPath`; materialized rows carry collection-slot + ordinal paths
   without forcing all rows to resolve.

Suites that will need updates (per Stage-mapped recon): `SwiftUISurfaceTests`
(re-projection, ~44 assertions), `ResolveReuseIndexingTests`,
`StackSafetyRegressionTests`, `AnyViewResilienceTests` (path-substring
predicates), `ChildDescriptorTests`. Robust suites (outcome-count based):
`StructuralDiffTests`, `PanelTests`, `RegistrationAliasFindingsTests`.

## Execution order and touchpoints

| Step | Lands | Primary files |
| --- | --- | --- |
| L2.1 | `StructuralPath`; typed `AuthoringContext` seam | `Geometry/GeometryTypes.swift` (new `StructuralPath`), `State/AuthoringContext.swift`, `ActionScopes/Panel.swift`, `NavigationViews/NavigationStack.swift` |
| L2.2 | `structuralPath`/`structuralKey` on `ResolvedNode`; equivalence-gate choice | `Resolve/ResolvedNode.swift`, `Resolve/ResolvedNodeEquivalence.swift` |
| L2.3 | structural emission via the two primitives + lazy source | `Environment/ResolveContext.swift:133,171,179`, `Foundation/ViewFoundation.swift:54`, `ViewBuilder/ConditionalContentView.swift:37,49`, `Collections/IndexedChildSources.swift` |
| L2.4 | `ChildDescriptor` reads the carrier, stops string-parsing | `Resolve/ChildDescriptor.swift:26-77`, `Resolve/StructuralDiff.swift` |
| L2.5 | debug snapshots + test re-projection helper | `Resolve/ViewGraphDebugSnapshots.swift`, three `Tests/**/TestIdentitySupport.swift`, `Tests/SwiftTUITests/SwiftUISurfaceTests.swift` |

L2.1–L2.4 should land together (the carrier is useless half-threaded); L2.5 is
the test-migration tail. The Stage 1 L2 oracle must stay green throughout — any
equivalence-gate change in L2.2 is exactly what it exists to catch.

## Validation

```bash
swift test --package-path swift-tui --filter StructuralDiffTests
swift test --package-path swift-tui --filter ChildDescriptorTests
swift test --package-path swift-tui --filter ResolveReuseIndexingTests
swift test --package-path swift-tui --filter SwiftUISurfaceTests
swift test --package-path swift-tui --filter PanelTests
swift test --package-path swift-tui --filter RetainedReuseInvariantTests
bazel test //:org_fast
```

Performance: Stage 2 is structural plumbing; its perf claim is indirect (it lets
Stage 1 stop reconstructing adjacency and lets L2.2 reuse layout across pure
`.id` changes). Run the `synthetic-narrow-invalidation` rows=6/20/40 sweep to
confirm no `resolve_ms` regression from carrying the extra field, and to capture
any reuse win from the equivalence-gate change.

## Risks and non-goals

- **Do not** separate entity identity from structural position for `ForEach`
  elements in this stage. That is Stage 3. Stage 2 records the collection source
  slot only and leaves the element divergence intact.
- **Do not** change the `ID[...]` runtime-identity suffix or `explicitID`'s
  string form. Recon shows `ChildDescriptor` and many fixtures depend on it;
  changing it churns every Codable identity fixture. Stage 2 reads structure from
  the new carrier, it does not rewrite the runtime identity.
- **Do not** reintroduce a string-path `Identity` initializer or
  `ExpressibleByStringLiteral` — `IdentityGuardTests` (`:14-17`) forbids it. The
  structural carrier is `[IdentityComponent]`, constructed structurally.
- **Do not** let `setChildrenPreservingDerivedState`'s no-recompute fast path go
  stale: `structuralPath` must be invariant under shape-stable child replacement.
- **Do not** key the structural axis on anything that loses the component-wise
  prefix relation — subtree intersection, focus descendants, and invalidation
  routing all depend on it (`ResolveContext.swift:308-319`,
  `GeometryTypes.swift:629-639`).

## Open questions (some resolved by Stage 0 evidence)

1. Should `ResolvedNode` carry the full `StructuralPath` (diagnostics-friendly,
   bigger) or only a compact frame-local `StructuralNodeKey` plus a parent link
   (cache-friendly, opaque)? 001 OQ#2. Leaning: carry the path (it is the
   cross-frame anchor) and derive the compact key in Stage 1's indexer.
2. Which equivalence walks should gate on `structuralPath` vs runtime `identity`?
   (L2.2.) The oracle decides correctness; the question is which choice maximizes
   reuse without changing snapshots.
3. How much of `AuthoringContext.structuralIdentity` becomes the new
   `StructuralPath` versus a compatibility shim for the two readers? 001 OQ#3.
   Leaning: both readers move to `StructuralPath`; no shim survives past Stage 2.
