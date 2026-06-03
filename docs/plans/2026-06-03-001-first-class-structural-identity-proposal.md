# First-Class Structural Identity Proposal

Status: proposal
Date: 2026-06-03
Scope: `swift-tui/` runtime, resolve graph, retained frame indexes, invalidation planning

## Summary

SwiftTUI currently treats `Identity` as too many things at once:

1. The final runtime lookup key for `ViewNode`.
2. The path used to derive parent/child containment.
3. The lookup key for retained resolved/measured/placed products.
4. The public-ish debug identity seen in frame snapshots and tests.
5. The key component that scopes state slots, handlers, dependencies, and lifecycle.

That works while `Identity.path` mirrors actual structural containment. It becomes
fragile when identity and structure intentionally diverge: `.id`, `ForEach`,
duplicate explicit ids, presentation portals, overlay-owned trees, registration
aliases, and lazy/indexed child sources.

The recommended direction is a phased structural-identity model:

1. Add a structural frame sidecar first and make retained indexes/invalidation
   consume actual structural adjacency instead of `Identity.parent`.
2. Then thread structural ids through resolve products so child diffing,
   retained reuse, and diagnostics can reason about structure directly.
3. Only after those phases, decide whether SwiftTUI needs a deeper split between
   public identity and runtime `ViewNode` lifetime.

Do not start by replacing all `Identity` call sites. The current identity type is
deeply wired into state, lifecycle, dependency indexes, semantic handlers, debug
snapshots, and tests. A sidecar-first migration gets the rendering-performance
win while preserving current semantics.

## Source Context

Current SwiftTUI source areas involved:

- `swift-tui/Sources/SwiftTUICore/Geometry/GeometryTypes.swift`
  defines `Identity` as a path of string components, including `.parent`,
  `.child(...)`, and `.explicitID(...)`.
- `swift-tui/Sources/SwiftTUICore/Resolve/ViewGraph.swift`
  stores runtime nodes in `nodesByIdentity`, creates `ViewNode` instances by
  final identity, records registration aliases, and applies child diffs.
- `swift-tui/Sources/SwiftTUICore/Resolve/StructuralDiff.swift` and
  `ViewGraphStructuralReconciliation.swift` diff ordered children by final
  identity plus type information, then eagerly tear down removed children.
- `swift-tui/Sources/SwiftTUIViews/Foundation/ViewFoundation.swift`,
  `TupleView.swift`, `ConditionalContentView.swift`, `VariadicView.swift`, and
  stack views assign child path components such as `VStack[0]`.
- `swift-tui/Sources/SwiftTUIViews/State/AuthoringContext.swift` already
  distinguishes `viewIdentity` from `structuralIdentity`.
- `swift-tui/Sources/SwiftTUIViews/State/State.swift` keys state by
  `viewIdentity` plus a source-location ordinal.
- `swift-tui/Sources/SwiftTUIViews/Collections/ForEach.swift` keeps
  `viewIdentity` owned by the enclosing authoring view while setting
  `structuralIdentity` to the element identity.
- `swift-tui/Sources/SwiftTUICore/Commit/RetainedFrameQueries.swift`,
  `RetainedPhaseExtraction.swift`, `FrameTailRetainedState.swift`, and
  `swift-tui/Sources/SwiftTUICore/Measure/LayoutEngine+RetainedLayout.swift`
  use identity-keyed retained products and path-derived subtree tests.
- `swift-tui/Sources/SwiftTUIViews/Presentation/Portal.swift` and
  `swift-tui/Sources/SwiftTUICore/Runtime/PortalTypes.swift` intentionally
  separate declaration-site ownership from portal placement.

I also checked StateTree at `adam-zethraeus/StateTree` main commit
`9a56e848081e3e30edd5f214b255147ef69ca6d0`. The useful lesson is not to copy
the implementation directly, but to copy the separation of roles:

- `NodeID`: runtime lifetime.
- `FieldID`: stored field structure, keyed by owner node plus field offset/type.
- `LSID`: lifetime-stable entity identity for routed/list values.
- List routing keeps an `LSID -> NodeID` table so values can move or change
  while preserving lifetime only when identity proves it is the same entity.

SwiftTUI needs the same separation, adapted to a value-tree/result-builder
renderer rather than a stored-object tree.

## Terminology

This proposal uses four names intentionally:

- `RuntimeIdentity`: the key used to retrieve a live `ViewNode`. Today this is
  `Identity`.
- `StructuralIdentity`: the authored/rendered structural position of a node and
  its structural parent/children.
- `EntityIdentity`: explicit user/data identity, such as `.id(...)` or a
  `ForEach` element id.
- `StateSlotIdentity`: the identity of stored dynamic-property slots inside a
  runtime owner, currently `viewIdentity + StateSlotOrdinal`.

In SwiftUI discussions, "structural identity" can describe two related but
different things:

1. Stored-member identity: a member/property slot inside a parent value or node.
   StateTree's `FieldID` is this form. SwiftTUI already has a version of this
   for `@State`: source-location ordinals under `AuthoringContext.viewIdentity`.
2. Builder-slot identity: a child produced by a `ViewBuilder` expansion, stack
   child list, conditional branch, modifier role, or `ForEach` element. This is
   the missing first-class part in SwiftTUI. Today these slots mostly become
   string path components on final `Identity`.

The proposal is primarily about builder-slot structural identity and structural
adjacency. It should preserve the current stored-member behavior unless a later
phase explicitly chooses to split `ViewNode` lifetime from `Identity`.

## Current Setup

### Resolve-Time Identity

During resolve, `ResolveContext.identity` is the dominant identity. Views append
path components for declared children:

- A stack child becomes something like `.../VStack[0]`.
- A conditional branch appends a branch component.
- `ForEach` and `.id` append explicit-id components.
- Portal/presentation code can resolve content under a synthetic portal root.

`ResolvedNode.identity` carries the resulting final identity. `ViewGraph` then
uses that identity to find or create a `ViewNode`.

### Authoring Context

`AuthoringContext` already has an important split:

- `viewIdentity` is the owner for state, invalidation, callbacks, and dynamic
  property resolution.
- `structuralIdentity` is the current authoring position for identity-deriving
  modifiers.

Most code sets both to the same value. `ForEach` deliberately diverges them:
the element body keeps the outer `viewIdentity` as owner, while
`structuralIdentity` is set to the element's explicit identity. This is why
identity-deriving modifiers such as `.panel()` can see distinct positions inside
a repeated element without accidentally moving every closure-owned state slot to
each element.

This is a useful partial model, but it is not a structural graph:

- It is not attached to every `ResolvedNode`.
- It is not used by retained frame indexes.
- It does not define authoritative parent/child containment.
- It does not survive portals and aliases as a separate adjacency model.

### Retained Frame Reuse

Retained frame state currently builds flat dictionaries by final identity:

- `resolvedByIdentity`
- `measuredByIdentity`
- `placedByIdentity`

Invalidation and reuse queries infer ancestry with `Identity.parent` and
descendant path-prefix checks. That means the retained layer assumes string path
containment is equivalent to structural containment.

The performance plan in
`docs/plans/2026-06-02-003-rendering-performance-remaining-opportunities-proposal.md`
already identifies this as the blocker for persistent retained indexes:
structural containment must be explicit before old indexes can be incrementally
patched safely.

## Requirements

A first-class structural identity model should satisfy these invariants:

1. Structural adjacency is authoritative for subtree membership. `Identity.parent`
   is no longer used as proof of containment when a structural index is present.
2. A runtime lifetime is preserved only when reconciliation proves the same
   structural slot, compatible type, and compatible entity identity.
3. `.id(...)` changes entity identity under a structural slot. It must not be the
   only representation of structural parentage.
4. `ForEach` reorder should preserve entity lifetime while changing ordered
   structural edges.
5. Static insertion/removal should preserve SwiftUI-like structural behavior:
   unkeyed sibling slots after an insertion are different structural slots unless
   the renderer has a more specific key.
6. Duplicate explicit ids need a defined policy: diagnose, preserve occurrence
   identity, or intentionally fall back to conservative rebuild.
7. Portal and presentation content must model both declaration owner and
   placement parent, or explicitly classify the edge as teleported.
8. Lazy/indexed children must be represented without forcing all rows to resolve.
9. State slot ownership must remain stable for the current supported surface.
   This proposal should not accidentally move closure-owned `@State` into each
   `ForEach` element.
10. Debug mode must be able to compare a retained structural update against full
    rebuild results while the migration is in progress.

## Design Options

### Option A: Structural Frame Sidecar

Add a structural index beside committed frame products while leaving `Identity`
as the runtime `ViewNode` key.

The new sidecar would record actual graph edges observed during commit:

```swift
struct StructuralNodeKey: Hashable, Sendable {
    let rawValue: UInt64
}

struct StructuralEdge: Hashable, Sendable {
    let parent: StructuralNodeKey?
    let child: StructuralNodeKey
    let runtimeIdentity: Identity
    let role: StructuralRole
    let typeIdentity: String
    let explicitID: String?
}

struct StructuralFrameIndex {
    var parentByNode: [StructuralNodeKey: StructuralNodeKey]
    var childrenByNode: [StructuralNodeKey: [StructuralNodeKey]]
    var identityByNode: [StructuralNodeKey: Identity]
    var nodesByIdentity: [Identity: [StructuralNodeKey]]
    var subtreeRanges: [StructuralNodeKey: Range<Int>]
}
```

The first implementation can assign structural keys deterministically during
frame indexing from actual `ResolvedNode.children` traversal. It does not need
to expose structural keys to authoring code yet.

Use it first in:

- `RetainedFrameIndex`, to retain products by structural adjacency.
- `RetainedInvalidationSummary`, to compute ancestors and descendants from the
  previous structural index instead of path prefixes.
- Persistent retained-index experiments, where insert/remove/patch operations
  need exact old subtree sets.

Pros:

- Lowest blast radius.
- Directly unblocks the "persistent retained indexes" opportunity.
- Preserves state, lifecycle, dependency, and handler semantics.
- Can be introduced behind debug assertions and feature flags.

Cons:

- It is first-class only after resolve, not during authoring.
- It does not fix all identity overloading.
- Duplicate final identities still need multimap handling.
- `.id` still changes the final runtime key before reconciliation.

This is the recommended first phase.

### Option B: Resolve-Time Structural Identity

Thread an explicit structural context through resolve:

```swift
struct ResolveContext {
    var identity: Identity              // current runtime/public identity
    var structuralPath: StructuralPath  // current authored slot path
    ...
}

struct ResolvedNode {
    var identity: Identity
    var structuralID: StructuralNodeKey
    var structuralPath: StructuralPath
    ...
}
```

Child-building APIs would advance `structuralPath` separately from `identity`:

- `TupleView` children get tuple/member slot components.
- Stack children get container-child slot components.
- Conditionals get branch components.
- `ForEach` gets collection-root plus element entity components.
- `.id(...)` changes `EntityIdentity` and final runtime identity, but the
  structural parent remains the same builder/modifier slot.
- Presentation portals get explicit declaration and placement roles.

`ChildDescriptor` can then compare:

- structural slot
- type identity
- type discriminator
- entity identity
- final runtime identity, only where relevant

Pros:

- Makes structural identity available throughout resolve, diffing, and retained
  products.
- More closely matches the StateTree split between field structure and entity
  identity.
- Gives better diagnostics for aliases, portals, and duplicate ids.
- Gives future lazy rendering a stable vocabulary for source roots versus
  materialized rows.

Cons:

- Higher migration cost.
- Many tests currently assert final identity paths.
- Needs a compatibility bridge for registration aliases.
- Still leaves the deeper question of whether `ViewNode` lifetime should remain
  keyed by final `Identity`.

This is the recommended second phase.

### Option C: Split Runtime ViewNode Lifetime From Identity

Introduce a new internal `ViewNodeID` and use reconciliation to map structural
slots and entity ids to runtime lifetimes:

```swift
struct ViewNodeID: Hashable, Sendable {
    let rawValue: UInt64
}

struct RuntimeReconciliationKey: Hashable, Sendable {
    let structuralID: StructuralNodeKey
    let typeIdentity: String
    let entityID: EntityIdentity?
}
```

`Identity` would become a semantic/debug/public identity, while `ViewGraph`
storage would move toward:

- `nodesByNodeID`
- `nodeIDByRuntimeIdentity`
- `runtimeIdentitiesByNodeID`
- dependency/state/lifecycle indexes keyed by `ViewNodeID` where appropriate

`@State` would eventually become `ViewNodeID + StateSlotOrdinal` instead of
`Identity + StateSlotOrdinal`.

Pros:

- Closest to SwiftUI's likely internal model and StateTree's `NodeID`.
- Best long-term answer for duplicates, aliases, moves, and portals.
- Lets public identity and runtime lifetime evolve independently.

Cons:

- Largest blast radius.
- Touches state, dynamic properties, observation, lifecycle, gestures,
  environment dependency maps, semantic handlers, debug snapshots, and tests.
- Easy to introduce subtle lifetime bugs.
- Not required to unblock retained-frame performance work.

This should not be the initial implementation. It should be treated as a later
decision after Options A and B expose real remaining pressure.

## Recommended Architecture

Adopt a layered model:

```text
State slot identity     = runtime owner + authored member/source ordinal
Runtime identity        = current ViewNode lookup key, initially Identity
Entity identity         = explicit .id / ForEach id / routed semantic key
Structural identity     = explicit ordered graph position and containment
```

The immediate new production type should be a structural frame index:

```swift
struct StructuralFrameIndex {
    let root: StructuralNodeKey?
    let parentByNode: [StructuralNodeKey: StructuralNodeKey]
    let childrenByNode: [StructuralNodeKey: [StructuralNodeKey]]
    let nodeByRuntimeIdentity: [Identity: [StructuralNodeKey]]
    let runtimeIdentityByNode: [StructuralNodeKey: Identity]
    let subtreeRangeByNode: [StructuralNodeKey: Range<Int>]
    let postorder: [StructuralNodeKey]
}
```

Important detail: `nodeByRuntimeIdentity` must be a multimap, not a dictionary.
Even if duplicate final identities are invalid or discouraged, the structural
layer must not silently overwrite them. It should either:

- report a deterministic diagnostic and rebuild conservatively, or
- carry occurrence identities so the rest of the frame can still be reasoned
  about.

The structural index should be part of committed frame artifacts, not just
`ViewGraph`, because retained layout compares previous committed products
against the current frame draft.

## Mechanics

### Phase 0: Diagnostics Without Behavior Change

Add a debug-only structural snapshot builder that walks committed
`ResolvedNode.children` and records:

- actual parent/child edges
- final identities
- child order
- kind/type discriminator
- explicit id, where parsable
- transient/portal/overlay roles

Then add diagnostics that compare:

- path-derived parent from `Identity.parent`
- structural parent from the snapshot
- duplicate identities in a frame
- identities whose registration alias differs from the committed identity
- portal/presentation roots whose path containment differs from placement

This phase should not affect rendering. It exists to produce evidence and to
protect later migrations.

### Phase 1: Structural Invalidation And Retained Queries

Teach retained frame code to answer subtree questions through
`StructuralFrameIndex`:

- `containsDescendant(of:)`
- `ancestors(of:)`
- `subtreeNodes(of:)`
- `intersectsSubtree(at:)`
- `subtreeProductSet(at:)`

When a previous structural index is available, retained invalidation should use
that index. When it is absent, fall back to the current path-based logic.

This directly replaces the weakest assumption in retained reuse:

```text
old assumption:
  identity path prefix == subtree membership

new assumption:
  previous committed structural adjacency == subtree membership
```

Expected code areas:

- `RetainedFrameQueries.swift`
- `RetainedPhaseExtraction.swift`
- `FrameTailRetainedState.swift`
- `LayoutEngine+RetainedLayout.swift`
- frame metrics invalidation summaries

This is also where persistent retained indexes become viable: a changed subtree
can be removed by structural range, and new products can be inserted from the
new frame without rebuilding every flat dictionary.

### Phase 2: Resolve-Time Structural IDs

After the sidecar is stable, move structural capture earlier:

- Add `StructuralPath` or `StructuralNodeKey` to `ResolveContext`.
- Assign structural components in `indexedChild(kind:index:)` and related child
  APIs.
- Attach `structuralID` or `structuralPath` to `ResolvedNode`.
- Include structural identity in debug snapshots and `ChildDescriptor`.

Suggested structural components:

```swift
enum StructuralComponent: Hashable, Sendable {
    case root
    case tupleChild(Int)
    case containerChild(kind: String, index: Int)
    case conditionalBranch(String)
    case modifier(role: String, ordinal: Int)
    case variadicChild(Int)
    case collectionElement(source: String, entity: EntityIdentity)
    case lazyMaterializedChild(index: Int)
    case portalHost(String)
    case portalEntry(String)
    case portalBody
}
```

This enum is illustrative, not final API. The important constraint is that
components represent structure and roles, not merely display strings.

### Phase 3: Reconciliation Keys

Once `ResolvedNode` carries structural identity, reconciliation can use a richer
key:

```text
same lifetime if:
  same compatible structural slot
  same compatible view type/discriminator
  same explicit entity identity, when present
```

This does not require `ViewNodeID` yet. It can still return final `Identity` as
the lookup key in phase 3. The important shift is that diffing no longer has to
infer everything from final identity strings.

`ForEach` reorder semantics should become explicit:

- The collection root stays structurally under the same parent.
- Each element has an entity key.
- Order changes update sibling edge order.
- The element runtime lifetime is preserved because entity identity matches.

Static sibling insertion semantics should remain structural:

- If unkeyed child slots are ordinal, inserting before a sibling changes that
  sibling's slot.
- This is expected for static builder output unless a keying construct says
  otherwise.

### Phase 4: Optional ViewNodeID Split

Only pursue a separate `ViewNodeID` if phase 3 still leaves real bugs or
unacceptable constraints.

Signals that justify this phase:

- final `Identity` duplicates are legitimate and common
- aliases keep forcing special cases
- portal placement cannot be modeled safely with final identity keys
- state/lifecycle needs to survive transformations that change final identity
  but preserve runtime lifetime

If that happens, introduce `ViewNodeID` behind adapter APIs and migrate one
index at a time.

## Hard Cases

### `.id(...)`

Current behavior replaces the context identity with
`context.identity.explicitID(id)`. In the new model:

- structural parent remains the authored child/modifier slot
- entity identity becomes `id`
- final runtime identity can remain `Identity.explicitID(id)` for compatibility

This lets invalidation still say "this node is structurally under its parent"
even when the runtime identity path contains an explicit id suffix.

### `ForEach`

Current `ForEach` already contains the right conceptual split:

- closure/state ownership remains with the outer `viewIdentity`
- each element gets a distinct `structuralIdentity`
- explicit element identity drives child identity

The structural model should formalize this rather than undo it.

A `ForEach` element should be represented as:

```text
structural parent: collection source slot
entity identity:   element id
runtime identity:  compatibility Identity, initially explicitID(element id)
owner identity:    current AuthoringContext.viewIdentity unless explicitly changed
```

Lazy/indexed `ForEach` should record a source root plus materialized element
edges. It must not need every element resolved to know the source exists.

### Duplicate Explicit IDs

The structural index should never use `[Identity: Node]` as the only map.
Duplicate explicit ids should produce one of these deterministic outcomes:

1. Debug diagnostic plus conservative rebuild for the affected parent subtree.
2. Occurrence-based internal keys while preserving a diagnostic.
3. Hard precondition failure in internal-only debug configurations.

The first option is safest for production behavior.

### Portals And Presentation

Portals need two relationships:

- declaration owner: where closures, bindings, and dynamic-property authoring
  were captured
- placement parent: where the content is rendered in the terminal/presentation
  tree

A structural model should not pretend there is only one parent unless the edge
role is explicit. Suggested representation:

```swift
enum StructuralEdgeRole {
    case normal
    case overlayEntry
    case portalDeclaration
    case portalPlacement
    case presentationContentRoot
}
```

Retained layout usually cares about placement structure. State and callback
ownership usually care about declaration owner. Keeping those separate prevents
portal fixes from becoming identity-path special cases.

### Registration Aliases

`ViewGraph` already allows `ViewNode.committed.identity` to differ from the
node's registration identity. The structural model should make this visible in
diagnostics and indexes:

```text
registration identity -> runtime node
committed identity     -> resolved product
structural node        -> actual frame position
```

Phase 1 can keep existing alias behavior and simply record it. Phase 2 can use
structural ids to reduce reliance on alias repair.

## Tests

Add focused tests before enabling structural indexes for behavior:

1. Static child insertion/removal
   - unkeyed slots after an insertion reset as expected
   - structural subtree ranges match committed children
2. `.id` under a parent
   - structural parent remains the parent slot
   - runtime identity changes with `.id`
   - parent invalidation removes or rebuilds the child structurally
3. `ForEach` reorder
   - element lifetimes are preserved by entity id
   - sibling order changes are recorded as structural edge order changes
4. Duplicate explicit ids
   - no dictionary overwrite
   - deterministic diagnostic or conservative rebuild
5. `AnyView` and `Group`
   - transparent wrappers keep expected structural behavior
   - type-discriminator tests still pass
6. Presentation/portal content
   - declaration owner and placement parent are both represented
   - invalidating the declaration owner cannot leave stale placed content
7. Lazy indexed children
   - source root exists without resolving all rows
   - materialized child identity is stable across viewport shifts where expected
8. Retained-frame equivalence
   - structural retained update matches full rebuild products in debug mode

Existing focused suites likely to extend:

- `StructuralDiffTests`
- `ChildDescriptorTests`
- `RegistrationAliasFindingsTests`
- `PanelTests`
- `SwiftUISurfaceTests`
- `AnyViewResilienceTests`
- `RetainedSubtreeReuseTests`
- `RetainedPhaseExtractionTests`
- `RetainedReuseInvariantTests`
- `PresentationContinuityTests`

## Validation

Recommended validation commands from the org root or child package:

```bash
swift test --package-path swift-tui --filter StructuralDiffTests
swift test --package-path swift-tui --filter ChildDescriptorTests
swift test --package-path swift-tui --filter RegistrationAliasFindingsTests
swift test --package-path swift-tui --filter PanelTests
swift test --package-path swift-tui --filter SwiftUISurfaceTests
swift test --package-path swift-tui --filter AnyViewResilienceTests
swift test --package-path swift-tui --filter RetainedSubtreeReuseTests
swift test --package-path swift-tui --filter RetainedPhaseExtractionTests
swift test --package-path swift-tui --filter RetainedReuseInvariantTests
swift test --package-path swift-tui --filter PresentationContinuityTests
bazel test //:org_fast
```

For performance validation, use the retained-rendering scenarios from
`docs/perf/README.md`, especially narrow invalidation cases at multiple row
counts. The expected result of Phase 1 is not necessarily lower frame time by
itself; the expected result is that persistent retained indexes can be
implemented without unsafe path-containment assumptions.

## Rollout Plan

### Step 1: Structural Snapshot Diagnostics

- Add `StructuralFrameSnapshot` behind debug/test-only APIs.
- Build it from committed `ResolvedNode.children`.
- Record duplicate identities, alias differences, portal roles, and path-parent
  mismatches.
- Add tests proving current ordinary views have path/structure agreement.
- Add tests proving known hard cases are detected rather than hidden.

### Step 2: StructuralFrameIndex In Committed Frame State

- Store `StructuralFrameIndex` with retained frame state.
- Keep existing identity dictionaries for product lookup.
- Add structural subtree query APIs.
- Keep path-based retained invalidation as fallback.

### Step 3: Retained Invalidation Uses Structural Queries

- Replace path-prefix subtree queries in retained invalidation summaries with
  structural queries when a previous structural index exists.
- Add debug comparison against full rebuild.
- Add production fallback for duplicate/ambiguous structural maps.

### Step 4: Persistent Retained Indexes

- Implement incremental retained-index patching from structural subtree ranges.
- Keep a debug mode that periodically rebuilds full indexes and compares.
- Measure narrow invalidation scenarios.

### Step 5: Resolve-Time Structural Context

- Add `StructuralPath` to `ResolveContext`.
- Attach structural identity to `ResolvedNode`.
- Thread it through builder, stack, conditional, `ForEach`, `.id`, lazy, and
  portal paths.
- Update `ChildDescriptor` and structural reconciliation to use the new fields.

### Step 6: Decide On ViewNodeID

- Audit remaining identity alias and duplicate-id pressure.
- If needed, propose a separate `ViewNodeID` migration.
- If not needed, keep `Identity` as runtime key and document the boundary.

## Non-Goals

- Do not change public SwiftTUI API as part of Phase 1.
- Do not change `@State` ownership semantics in the sidecar phase.
- Do not make child repos depend on the org root or Bazel.
- Do not require all lazy rows to resolve just to build a structural index.
- Do not claim SwiftUI compatibility beyond the behavior covered by tests.

## Open Questions

1. Should duplicate explicit ids be a debug diagnostic with conservative rebuild
   or a hard failure in internal test configurations?
2. Should structural keys be deterministic paths, compact integer ids, or both?
   A compact id is faster for indexes, while a path is better for diagnostics.
3. How much of `AuthoringContext.structuralIdentity` should be replaced by the
   new structural path versus kept as a compatibility surface for modifiers?
4. Should portal declaration and placement edges live in one structural graph
   with edge roles, or two separate graphs linked by portal ids?
5. Once structural ids exist on `ResolvedNode`, should retained products be
   keyed primarily by structural id, runtime identity, or a composite key?

## Recommendation

Implement Option A first, with types named and shaped so Option B can reuse
them. This gives SwiftTUI the missing first-class structural adjacency model
needed by retained rendering without destabilizing state and lifecycle.

The critical shift is conceptual and mechanical:

```text
Today:
  final Identity path implies structure, lifetime, and retained containment

Proposed:
  structural graph proves containment
  entity identity influences reuse
  runtime identity keeps current ViewNode compatibility
  state slots remain owned by authoring/runtime identity
```

That model matches the useful part of StateTree's design while respecting
SwiftTUI's existing value-view and result-builder architecture.
