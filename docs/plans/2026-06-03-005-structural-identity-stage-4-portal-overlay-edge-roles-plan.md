# Structural Identity — Stage 4: Portal, Overlay & Alias Edge Roles

**Date:** 2026-06-03
**Status:** Plan. Not started. Depends on Stages 2–3.
**Stage:** 4 of the structural-identity migration. This is 001's **Hard Cases**
(portals/presentation, registration aliases, lazy children) made first-class:
model declaration-owner vs placement-parent as explicit structural edge roles,
and stage the registration-alias layer for deletion.
**Entry point:**
[`2026-06-03-001-first-class-structural-identity-proposal.md`](2026-06-03-001-first-class-structural-identity-proposal.md).
**Predecessors:**
[Stage 2 — Resolve-Time Structural Identity](2026-06-03-003-structural-identity-stage-2-resolve-time-structural-identity-plan.md),
[Stage 3 — Reconciliation & Entity Identity](2026-06-03-004-structural-identity-stage-3-reconciliation-entity-identity-plan.md).
**Verified against:** `swift-tui` working tree at commit `a020fa55`.

---

## Executive summary

A presented view has *two* parents: the **declaration owner** (where its closures
and bindings were captured) and the **placement parent** (where it renders in the
terminal). SwiftTUI already keeps these separate — but informally, joined through
a string. Stage 4 makes the separation a first-class structural fact so that
state/callback ownership and placement adjacency stop being reconciled by
`Identity.path` substring coupling, and so the registration-alias layer that
exists only to paper over the structural-vs-runtime divergence can be deleted in
Stage 5.

The reconnaissance materially reframed this stage: **most of the model already
exists.**

- `SurfaceCompositionRole` (`SurfaceCompositionMetadata.swift:95-125`) already
  enumerates **six** cases: `.normal`, the four placement-side edge kinds
  `.stackingContext` / `.detachedOverlayRoot` / `.detachedOverlayHost` /
  `.detachedOverlayEntry`, **and** `.isolatedCompositingGroup` (`:101`). Stage 4's
  unification must account for all six (it adds one more — the transient-removal
  edge — for a total of seven), not silently drop `.isolatedCompositingGroup`.
- Declaration-owner ownership already exists as `PortalEntryID{sourceIdentity,
  token}` (`PortalTypes.swift:2-17`) and
  `PresentationCoordinatorDeclaration.sourceIdentity`. `PortalContentPayload`
  (`Portal.swift:8-22`) states the intent verbatim: "Build the view value at the
  declaration site so captured bindings keep pointing at their original owner.
  Resolve it later at the portal destination."

What is *missing* is a resolved-tree representation of the declaration-owner edge.
Today the owner subtree and the placed subtree are different nodes joined **only**
through the `presentationAttachmentID` string (`sourceIdentity.path#token`,
`PresentationItems.swift:178-183`). That string then becomes `OverlayStackEntry.id`,
the `PortalOrdering.stableTieBreaker`, and the surface `stableKey`s that drive
retained-raster reuse (`OverlayStack.swift:78-138`). So a single `.path`
serialization couples *entity identity (owner)*, *structural identity (portal
root)*, and *the raster-reuse topology key* all at once. Stage 4's job is to cut
that fused string into typed edges before Stage 5 re-keys runtime identity and
would otherwise break entry dedup, z-ordering, and raster reuse simultaneously.

## Corrections to the prior portal narrative (recorded for rigor)

A source sweep at `a020fa55` corrected three claims that appear in the earlier
proposals' portal discussions. The migration must not inherit them:

1. **`.overlay`/`.background` are NOT portals.** They resolve their content as an
   *in-place decoration sibling* with `layoutBehavior .decoration(...)`
   (`ViewLayoutModifierTypes.swift:348-371` / `410-433`) — no `OverlayStack`, no
   `composeOverlayStackTree`, no detached-overlay role. They satisfy
   "resolved parent == placed parent" trivially, by being in-tree.
2. **`.fullScreenCover` does not exist** in this codebase. The coordinator-backed
   presentations are exactly: `.sheet`, `.popover`, `.alert`,
   `.confirmationDialog`, `.toast`, `.menu`
   (`PromptPresentationEntrypoints.swift:159-266`, `PopoverPresentation.swift:8`).
3. **There are two distinct teleport mechanisms, and they must not be
   conflated.** (a) *Resolve-time portal hoist* for the modals above, composed
   into an `OverlayStack` branch by `composePresentationPortalTree`
   (`PresentationCoordinator.swift:265-272`, `OverlayStack.swift:49-52`) —
   verified by `PresentationSurfaceTests.swift:146-182` (content escapes a
   `.clipped()` ancestor). (b) *Post-resolve animation removal-overlay injection*
   (`AnimationTransitionOverlay.swift:46-65`), which splices `isTransient` clones
   back at their previous parent identity. Both keep placed-parent == resolved-
   parent within the indexed tree, but by different mechanisms; Stage 4 gives
   each its own edge role so Stage 5 keys them correctly.

## Current state

Verified at `a020fa55`:

- Modals merge a `PresentationCoordinatorDeclaration` into preferences
  (`PresentationModifiers.swift:105-118`) and are composed into an `OverlayStack`
  branch at resolve (`PresentationCoordinator.swift:265-272`). Entry content
  resolves under a synthetic `PortalHost/overlays/entry/body` identity
  (`OverlayStack.swift:49-52`), so resolved parent == placed parent.
- The declaration-owner store is `declarativeItemsBySource: [Identity: [Item.ID:
  TrackedPresentationItem]]` keyed by the modifier-bearing node's identity
  (`PresentationCoordinatorStorage.swift:21`), with `seenSources: Set<Identity>`
  as the liveness frontier (`:23`). Stale-source GC is by set-difference each
  resolve.
- Placement-side z-order/dedup/raster keys all derive from `Identity.path`:
  `presentationAttachmentID` embeds `sourceIdentity.path` + token
  (`PresentationItems.swift:178-183`); those become `OverlayStackEntry.id` and
  the `overlay-stack:<path>` / `overlay-host:<path>` / `entry.id` stableKeys
  (`OverlayStack.swift:78-138`) feeding the `SurfaceTopologySignature`.
- Lazy stacks: `indexedChildSource` roots have `supportsRetainedReuse == false`
  (`ResolvedNode.swift:287-295`); `stackChildren` materializes the full
  `0..<source.count` for measure (`StackLazyAllocation.swift:2-14`) while
  `indexedLazyStackPlacementRequests` emits placement only for the overscanned
  `visibleRange` (`LayoutEngine+StackPlacementRequests.swift:90-102`,
  `StackLazyAllocation.swift:63-122`) — placed children are a strict subset of
  source children.
- Registration aliases (`registrationAliasesByIdentity` /
  `registrationAliasTargets`, `ViewGraph.swift:101-102`) map an indexed-child
  *structural* identity to the resolved *runtime* identity, recorded by
  `recordRegistrationAlias` (`ViewFoundation.swift:62-66`). Recon + the existing
  diagnostics doc agree this layer exists **solely** to reconcile those two
  identities, and `.id(_:)`/`IDView` is the only common producer
  (`RegistrationAliasFindingsTests.swift:155-182`).

## Design: one structural graph, typed edge roles

Promote `SurfaceCompositionRole` into the migration's `StructuralEdgeRole`, and
add the one role that has no resolved-tree representation today — the
declaration-owner back-edge:

```swift
package enum StructuralEdgeRole: Sendable {
  case normal                       // ordinary child slot
  case stackingContext              // OverlayStack root (existing)
  case detachedOverlayRoot          // PresentationPortalRoot wrapper (existing)
  case detachedOverlayHost          // OverlayStack host (existing)
  case detachedOverlayEntry         // presented content root (existing)
  case isolatedCompositingGroup     // existing SurfaceCompositionRole case — carried over
  case transientRemovalOverlay      // animation removal injection (distinct teleport)
}

// The declaration-owner edge, now a typed back-edge instead of a string join:
package struct DeclarationOwnerEdge: Sendable {
  package let owner: EntityIdentity        // where bindings/closures were captured
  package let placementRoot: StructuralPath // where the content renders
  package let token: PortalToken            // existing PortalEntryID token
}
```

The principle (001's portal hard case): **retained layout cares about placement
structure; state and callback ownership care about the declaration owner. Keeping
them as separate typed edges prevents portal fixes from becoming `Identity.path`
special cases.**

## Mechanics

### L4.1 — Unify the edge-role vocabulary
Fold `SurfaceCompositionRole` and the migration's `StructuralEdgeRole` into one
type carried on the structural edge (Stage 2's `structuralPath` gains a role per
edge, or the node carries its inbound edge role). All six existing
`SurfaceCompositionRole` cases (`.normal` plus the four placement roles plus
`.isolatedCompositingGroup`) map across 1:1; add `transientRemovalOverlay` for the
animation path so it is never confused with a portal edge.

### L4.2 — Give the declaration-owner edge a resolved representation
Attach a `DeclarationOwnerEdge` to the placed entry node (the
`.detachedOverlayEntry` root), sourced from the existing
`PresentationCoordinatorDeclaration.sourceIdentity` / `PortalEntryID`. This makes
"who owns this presented content's state and callbacks" a typed query on the
resolved tree rather than a string parse of `presentationAttachmentID`. The
owner is an `EntityIdentity` (Stage 3); the placement root is a `StructuralPath`
(Stage 2).

### L4.3 — Lazy/indexed source roots as explicit viewport barriers
Mark `indexedChildSource` roots with a structural edge role that states the
contract directly: *placed children are a viewport subset of source children.*
Structural identity (Stage 2 `structuralPath`) exists for **all** source children
(needed for stable scroll/anchor behavior); runtime nodes are allocated lazily
for only the placed subset — which is exactly the seam Stage 5 needs for lazy
`ViewNodeID` allocation. `supportsRetainedReuse == false` stays; this stage makes
the *reason* a first-class fact rather than a special-case in
`RetainedFrameQueries`.

### L4.4 — Cut the `.path` string fan-out
Re-source the placement-side keys from typed carriers:
- `presentationAttachmentID` / `OverlayStackEntry.id` derive from the
  `DeclarationOwnerEdge.owner` (entity) + token, not from `sourceIdentity.path`.
- The surface `stableKey`s (`overlay-stack:`/`overlay-host:`/`entry:`) derive
  from the portal root's `StructuralPath`, not its `Identity.path`.
This decouples the three roles the single string currently fuses, so Stage 5's
runtime re-key cannot break entry dedup, z-order tie-breaking, and raster reuse
all at once. The `SurfaceTopologySignature` continues to gate raster reuse, now
on a structural key that is stable under a runtime re-key.

### L4.5 — Keep the animation teleport distinct
`AnimationTransitionOverlay`'s `injectionsByParent` must key on the **structural**
parent identity (stable across the resolved-child swap), and the injected
transient clones carry the `transientRemovalOverlay` edge role. Stage 5 then
allocates them a runtime id distinct from any live structural node, so a removed
view's disappear animation cannot collide with a live node's lifetime.

### L4.6 — Stage the registration-alias layer for deletion
Document, from Stage 0 evidence, that the only common alias producer is
`.id(_:)`/`IDView`, and that the alias bridge exists purely to reconcile
structural identity (`childContext.identity`) with resolved runtime identity
(`resolvedNode.identity`). Once Stage 2 makes structural identity first-class and
Stage 5 makes runtime identity (`ViewNodeID`) first-class, the alias maps
(`registrationAliasesByIdentity` / `registrationAliasTargets`) become redundant.
Stage 4 does not delete them — it records the deletion plan and the alias-fanout
behaviors (`removeResolvedSubtree`, `ViewGraph.swift:1239-1264`; and
`restoreResolvedSubtree`, `ViewGraphRuntimeRegistrationRestoration.swift:13`,
called from `ViewGraph.swift:1003`) that Stage 5 must subsume, plus the one open
caveat: custom `ResolvableView` identity rewrites (mentioned in the
`RegistrationAliasDiagnostics` doc-comment) were not exercised by recon and must
be confirmed alias-deletable before Stage 5 removes the layer (Stage 4 OQ#2).

## Tests

1. **Presented content has two typed parents.** A `.sheet`'s content node exposes
   its placement parent (the `OverlayStack` host, structural) and its declaration
   owner (the presenting view, entity) as distinct typed edges — not a parsed
   string.
2. **Invalidating the owner cannot leave stale placed content.** Invalidate the
   declaration owner; assert the placed content is rebuilt/removed via the
   declaration-owner edge, with no stale `OverlayStackEntry`.
3. **Owner-vs-placement under `.clipped()`.** Reassert
   `PresentationSurfaceTests`-style escape: content hoists above a `.clipped()`
   ancestor (placement) while bindings still target the owner (declaration).
4. **Raster reuse survives a runtime re-key.** With L4.4, changing only the
   runtime identity of a portal root (simulating Stage 5) leaves the surface
   `stableKey`s and z-order tie-breakers unchanged → no forced full-surface diff.
5. **Animation removal vs portal are different edges.** A removing view's
   transient injection carries `transientRemovalOverlay`, not a detached-overlay
   role, and re-attaches at its structural parent.
6. **Lazy viewport barrier.** A lazy stack exposes structural ids for all source
   rows while only the visible subset has placed/runtime nodes.

Suites: `PresentationSurfaceTests`, `PresentationContinuityTests`,
`OverlayStackTests`, `RegistrationAliasFindingsTests`,
`RegistrationAliasDiagnosticsTests`, `StackSafetyRegressionTests`, the
command-palette/overlay raster suites.

## Execution order and touchpoints

| Step | Lands | Primary files |
| --- | --- | --- |
| L4.1 | unified `StructuralEdgeRole` | `Commit/SurfaceCompositionMetadata.swift:95-125`, structural-path edge carrier |
| L4.2 | `DeclarationOwnerEdge` on placed entry | `Presentation/PresentationCoordinator.swift:189-272`, `Presentation/OverlayStack.swift:49-138`, `Runtime/PortalTypes.swift:2-17`, `Presentation/Portal.swift:8-22` |
| L4.3 | lazy viewport-barrier role | `Resolve/ResolvedIndexedChildSupport.swift`, `Resolve/ResolvedNode.swift:287-310`, `Place/LayoutEngine+StackPlacementRequests.swift` |
| L4.4 | typed placement keys (cut `.path` fan-out) | `Presentation/PresentationItems.swift:178-183`, `Presentation/OverlayStack.swift:78-138`, `Presentation/PresentationCoordinatorRegistry.swift` |
| L4.5 | distinct animation teleport role | `Runtime/AnimationTransitionOverlay.swift:46-65` |
| L4.6 | alias-deletion plan (no deletion yet) | `Resolve/RegistrationAliasDiagnostics.swift`, `Resolve/ViewGraph.swift:347-382,1239-1264`, `Resolve/ViewGraphRuntimeRegistrationRestoration.swift:13` |

## Validation

```bash
swift test --package-path swift-tui --filter PresentationSurfaceTests
swift test --package-path swift-tui --filter PresentationContinuityTests
swift test --package-path swift-tui --filter OverlayStackTests
swift test --package-path swift-tui --filter RegistrationAliasFindingsTests
swift test --package-path swift-tui --filter StackSafetyRegressionTests
bazel test //:org_fast
```

Perf: the command-palette open/close and overlay raster scenarios
(`docs/proposals/COMMAND_PALETTE_OPEN_PERFORMANCE.md`) are the relevant gate —
L4.4 must not regress overlay raster reuse, and should *improve* robustness of
the reuse key under future re-keying.

## Risks and non-goals

- **Do not** re-list `.overlay`/`.background` as portals, and do not add a
  `.fullScreenCover` edge role — neither exists as a teleport here.
- **Do not** delete the registration-alias layer in this stage. Stage 4 stages
  it; Stage 5 removes it once `ViewNodeID` subsumes the reconciliation, and only
  after the custom-`ResolvableView` caveat is confirmed.
- **Do not** conflate the two teleport mechanisms. The portal hoist is
  resolve-time and structural; the removal overlay is post-resolve and transient.
- **Do not** key placement-side dedup/z-order/raster on a runtime identity. They
  must follow the structural/entity carriers so Stage 5 cannot break them.

## Open questions

1. Should the declaration-owner edge live on the **owner** node (forward edge to
   its placed content) or on the **placed entry** node (back-edge to its owner)?
   Leaning back-edge on the placed entry (that is where ownership is consumed for
   invalidation), with an owner-side index only if a forward query is needed.
2. Can the registration-alias layer be deleted entirely, or do custom
   `ResolvableView` identity rewrites still require it? Resolve before Stage 5 by
   exercising the custom-rewrite path the diagnostics doc mentions.
3. Is the synthetic portal placement-parent identity
   (`<portal>/PortalHost/overlays/entry/body`) a `StructuralPath` or a
   runtime-allocated node? It is structurally derived yet exists only when an
   overlay is active. Leaning: structural path that is conditionally present —
   present when the overlay is, absent otherwise — which Stage 2's carrier models
   naturally.
