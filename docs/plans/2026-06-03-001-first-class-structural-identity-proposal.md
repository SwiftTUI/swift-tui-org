# First-Class Structural Identity — Plan-Set Entry Point

Status: proposal + plan-set index
Date: 2026-06-03 (entry point rewritten to index the staged migration)
Scope: `swift-tui/` runtime, resolve graph, retained frame indexes, state,
lifecycle, presentation, and invalidation planning
Verified against: `swift-tui` working tree at commit `a020fa55`

> **This document is the entry point to a seven-stage migration.** It holds the
> *why* — the problem, the model, the design stance — and indexes the per-stage
> execution plans that hold the *how*. Read this first, then the stage that
> concerns you.

---

## The plan set

The migration splits SwiftTUI's overloaded `Identity` into four distinct identity
axes and lands them in seven sequenced, independently-shippable stages. Each
stage carries its own execution plan, validation, and oracle.

| Stage | Plan | Lands | Breaking |
| --- | --- | --- | --- |
| **0** | [Divergence Diagnostics](2026-06-03-002-structural-identity-stage-0-divergence-diagnostics-plan.md) | Read-only, debug-only harness; corpus-wide divergence report (path-vs-structural parent, duplicate-id frequency/provenance, alias & portal divergence). Evidence that tunes Stages 3 & 5. | No |
| **1** | [Persistent Retained Index](2026-06-02-004-persistent-retained-index-structural-adjacency-proposal.md) | `StructuralFrameIndex` sidecar + patchable retained index (L1–L4). Structural adjacency replaces `Identity.parent` in retained invalidation. The first consumer; the rendering-performance win. | Internal |
| **2** | [Resolve-Time Structural Identity](2026-06-03-003-structural-identity-stage-2-resolve-time-structural-identity-plan.md) | `StructuralPath` on `ResolveContext` + `ResolvedNode`; structural component emitted at every child-building site; structure becomes an authored fact, not a projection of the identity string. | Internal + fixtures |
| **3** | [Reconciliation & Entity Identity](2026-06-03-004-structural-identity-stage-3-reconciliation-entity-identity-plan.md) | `EntityIdentity` axis; reconciliation key `(structural slot + type + entity id)`; deterministic, diagnosed duplicate-id handling. | Internal + fixtures |
| **4** | [Portal/Overlay/Alias Edge Roles](2026-06-03-005-structural-identity-stage-4-portal-overlay-edge-roles-plan.md) | `StructuralEdgeRole` (declaration-owner vs placement-parent); cut the `Identity.path` string fan-out; stage the registration-alias layer for deletion. | Internal |
| **5** | [`ViewNodeID` Lifetime Split](2026-06-03-006-structural-identity-stage-5-viewnodeid-lifetime-split-plan.md) | A distinct opaque `ViewNodeID`; re-key the ~40 runtime-lifetime indexes; delete the alias layer; redesign string-encoded handler ids. **Behavior-preserving.** | **Yes — internal-wide** |
| **6** | [Entity-Routed Lifetime](2026-06-03-007-structural-identity-stage-6-entity-routed-lifetime-plan.md) | The `EntityIdentity → ViewNodeID` routing table (StateTree's `LSID` lesson); `@State` re-rooted onto `ViewNodeID`; state/animation/focus survive identity-changing moves. **The only semantic change.** | **Yes — semantic** |

Stages 0 and 1 are already safe to land and carry no release behavior change.
Stage 1's execution plan (doc 004) predates this entry-point rewrite and remains
the canonical L1–L4 spec; this document subsumes its strategic framing.

## Design stance

The earlier draft of this proposal hedged: "implement Option A first; only pursue
a `ViewNodeID` split if later phases still leave real bugs." **That hedge is
withdrawn.** The directive for this plan set is explicit, and it is the right
call:

- **The overload is the bug.** `Identity` currently means four things at once. A
  type that means four things can be wrong four ways — and it is: the
  registration-alias layer, the duplicate-id aliasing, and the string-encoded
  handler ids are all scar tissue from refusing to name the four roles. The
  end-state (`ViewNodeID` distinct from structure, entity, and state-slot) is the
  **committed destination**, not a contingency. The staging exists to land it
  *safely*, not to avoid it.
- **Breaking changes now, not later.** Internal representation, internal test
  fixtures, and the debug/snapshot identity projection are all fair game and
  should break *now*, while the cost is bounded, rather than accreting permanent
  compatibility bridges we will tear out anyway. No string-literal `Identity`
  shims; no parallel legacy keying kept alive "just in case."
- **Two boundaries hold regardless.** (1) The SwiftUI-shaped *authoring surface*
  stays stable — `View`, `@State`, `ForEach`, controls behave as they do, and
  `Package.swift` stays SwiftPM-consumable; the breaking changes live *below* it.
  (2) Each stage lands behind an **oracle** — Stage 1's byte-equivalence index
  comparison, the existing scoped-restore-equals-full-rebuild test, the checkpoint
  totality contract — so "behavior-preserving" is *proven*, not asserted.
- **Rigor over mediocrity.** Every claim in these plans is cited to `file:line`
  at `a020fa55`. The reconnaissance that grounds them corrected three errors in
  the prior record (below). A migration of this size earns trust one verified
  fact at a time.

## The problem: `Identity` is overloaded

SwiftTUI currently treats `Identity` (`GeometryTypes.swift:585-658`) as too many
things at once:

1. The final runtime lookup key for `ViewNode` (`nodesByIdentity`,
   `ViewGraph.swift:86`).
2. The path used to derive parent/child containment (`Identity.parent` /
   `isAncestor` / `isDescendant`, `:604-639`).
3. The lookup key for retained resolved/measured/placed products
   (`RetainedFrameQueries.swift:26-30`).
4. The key component that scopes state slots, handlers, dependencies, lifecycle,
   animation, focus, gestures, and tasks — roughly **40 distinct indexes**, each
   enumerated in the Stage 5 plan.

That works while `Identity.path` mirrors actual structural containment. It becomes
fragile exactly where identity and structure intentionally diverge: `.id`,
`ForEach`, duplicate explicit ids, presentation portals, registration aliases,
and lazy/indexed child sources.

## The four-axis model (the spine)

The whole migration is one idea: **give each of `Identity`'s four jobs its own
key, in its correct home.** Every one of the ~40 identity-keyed indexes belongs
to exactly one axis.

```text
Runtime lifetime   = ViewNodeID          (opaque; a live node's lifetime)
Structure          = StructuralPath      (ordered position; component-wise prefix relation)
Entity             = EntityIdentity      (explicit user/data id; the routing key)
State slot         = (graphScope, owner ViewNodeID, ordinal)
```

| Axis | Means | Representative indexes (today, all `Identity`) |
| --- | --- | --- |
| Runtime | survives reuse, dies on true removal | `nodesByIdentity`, `liveIdentities`, every `Local*` registry, `NodeHandlers`, `AnimationController.*`, `TaskRunner.activeTasks`, `MeasurementCache`, `AnchorTypes`, draw/frame-tail state |
| Structural | "is X under Y?", ordering, subtree intersection | `isAncestor`/`isDescendant` callers, `FrameMetrics` walks, `ChildDescriptor`, `indexedChildSource.identityRoot`, focus/command/drop/scroll `scopePath`s |
| Entity | explicit identity that routes lifetime across moves | `declarativeItemsBySource`, `seenSources`, `ForEach` element key, presentation source |
| State-slot (`StateSlotIdentity`) | stored dynamic-property slots | `StateSlotKey`, `ViewNode.stateSlots`, `stateSlotDependents` |

> Naming: `StateSlotKey = {owner: ViewNodeID, ordinal}` is the per-owner runtime
> map key; `StateSlotIdentity = (graphScope, StateSlotKey)` is the full axis.
> Stage 6 defines the relationship.

The discipline each stage applies, index by index: *which axis is this, really?*
An index keyed on the wrong axis is a latent bug.

## Terminology

- **RuntimeIdentity / `ViewNodeID`**: the key to a live `ViewNode`. Today
  `Identity`; after Stage 5 a distinct opaque handle.
- **StructuralIdentity / `StructuralPath`**: the authored/rendered ordered
  position and its parent/child containment. Built from `IdentityComponent`
  (which already exists — `.named`/`.indexed`, `GeometryTypes.swift:560-583`).
- **EntityIdentity**: explicit user/data identity — `.id(...)`, a `ForEach`
  element id, a routed presentation source.
- **StateSlotIdentity**: the identity of a stored dynamic-property slot —
  `(graphScope, owner, ordinal)`.

This proposal is primarily about **builder-slot structural identity** (children
produced by a `ViewBuilder`, stack child list, conditional branch, modifier role,
or `ForEach` collection slot) and structural adjacency. Stored-member identity
(`@State` source-location ordinals) is preserved until Stage 6 deliberately
re-roots it.

## The StateTree lesson

StateTree (`adam-zethraeus/StateTree`, main `9a56e848…`) separates the same roles
and is the model for the end-state — not to copy the implementation, but the role
split:

- `NodeID`: runtime lifetime → our `ViewNodeID` (Stage 5).
- `FieldID`: stored-field structure → our `StateSlotIdentity` (Stage 6).
- `LSID`: lifetime-stable entity identity for routed/list values → our
  `EntityIdentity` (Stage 3) plus the `EntityIdentity → ViewNodeID` routing table
  (Stage 6).
- The `LSID → NodeID` table that preserves lifetime only when identity proves the
  same entity → our `EntityRoutingTable` (Stage 6). Recon confirmed SwiftTUI has
  **no such table today** — `Identity` equality through
  `CollectionDifference.inferringMoves()` *is* the routing.

## How the conceptual options map to the stages

The prior proposal framed three options as alternatives. They are not alternatives
— they are conceptual layers, and the plan set lands all three:

- **Option A — Structural sidecar.** A structural index beside committed frame
  products. → **Stage 1** (the retained index), with **Stage 0** as its
  evidence precursor.
- **Option B — Resolve-time structural identity.** Thread structural identity
  through resolve and reconciliation. → **Stages 2–4**.
- **Option C — Split runtime lifetime from identity.** A distinct `ViewNodeID`. →
  **Stages 5–6**.

## What is already built (the migration is not greenfield)

Reconnaissance found SwiftTUI half-built for this, which de-risks the work and is
why the stages are tractable:

- **`IdentityComponent`** (`.named`/`.indexed(kind:index:)`,
  `GeometryTypes.swift:560-583`) is the structural-component vocabulary Stage 2
  would otherwise invent.
- **`AuthoringContext`** already carries the conceptual split — `viewIdentity`
  (owner) vs `structuralIdentity` (position), `AuthoringContext.swift:29-65` —
  with only **two** readers of `structuralIdentity` (`.panel()`,
  `Panel.swift:101`; implicit `NavigationStack`, `NavigationStack.swift:71`). A
  small, enumerable seam.
- **`SurfaceCompositionRole`** already enumerates six cases — `.normal`, four
  placement-side edge kinds
  (`stackingContext`/`detachedOverlayRoot`/`detachedOverlayHost`/`detachedOverlayEntry`),
  and `.isolatedCompositingGroup` (`SurfaceCompositionMetadata.swift:95-125`);
  Stage 4 unifies these and adds one more (a distinct role for the post-resolve
  animation removal-overlay teleport).
- **`PortalEntryID{sourceIdentity, token}`** (`PortalTypes.swift:2-17`) and
  `PortalContentPayload` (`Portal.swift:8-22`) already model declaration-owner
  ownership — "build at the declaration site so captured bindings keep pointing at
  their original owner; resolve later at the portal destination."
- **Oracles already exist**: `RuntimeRegistrationRestoreScopingTests` asserts a
  scoped restore is byte-identical to a full rebuild; `ViewGraphCheckpointTotalityTests`
  enforces the checkpoint totality contract; the reuse-invariant suites compare
  reused vs recomputed. Stages extend these rather than invent oracles.

## Hard cases (with corrections to the prior record)

### `.id(...)`
Structural parent remains the authored child/modifier slot; entity identity
becomes the id; runtime identity keeps its `Identity.explicitID(id)` form for
compatibility. (Stages 2–3.) `.id` is the *only* common producer of registration
aliases (`RegistrationAliasFindingsTests.swift:155-182`).

### `ForEach`
The conceptual split already exists: closure/state ownership stays with the outer
`viewIdentity`; each element diverges `structuralIdentity`
(`ForEach.swift:36-44`). The migration formalizes it into three axes (structural
slot for `.panel()`, owner for `@State`, entity for lifetime) instead of one
overloaded string. (Stage 3.)

### Duplicate explicit ids
**Confirmed reachable, not hypothetical.** `ForEach` derives identity via
`explicitID(element[keyPath: id])` with no occurrence ordinal
(`ForEach.swift:26-28`); `explicitID` stringifies `String(reflecting:)` with no
disambiguator (`GeometryTypes.swift:625-627`). Today duplicates silently
last-writer-win and alias **every** identity-keyed map. Policy: contain, don't
model — Stage 3 disambiguates on the entity axis (occurrence) without touching the
runtime string; Stage 5 gives each a distinct `ViewNodeID`; Stage 6 routes each
independently. Stage 0 measures the real frequency and proves provenance is
user-supplied ids only.

### Portals and presentation — **corrected**
A source sweep corrected three claims the prior portal discussion carried:
1. **`.overlay`/`.background` are NOT portals** — they resolve as in-place
   decoration siblings (`layoutBehavior .decoration(...)`,
   `ViewLayoutModifierTypes.swift:348-371/410-433`), not via `OverlayStack`.
2. **`.fullScreenCover` does not exist** here. The coordinator-backed modals are
   exactly `.sheet`/`.popover`/`.alert`/`.confirmationDialog`/`.toast`/`.menu`.
3. **Two distinct teleport mechanisms** exist and must not be conflated:
   resolve-time portal hoist (modals, into an `OverlayStack` branch) and
   post-resolve animation removal-overlay injection
   (`AnimationTransitionOverlay.swift:46-65`). Both keep placed-parent ==
   resolved-parent, by different means. (Stage 4 gives each its own edge role.)
The core finding stands: presented content is hoisted at *resolve*, so a single
canonical placement-adjacency relation suffices for the retained index (Stage 1).
The *ownership* edge (declaration owner) is separate and gets a first-class role
in Stage 4.

### Registration aliases
`registrationAliasesByIdentity`/`Targets` (`ViewGraph.swift:101-102`) exist solely
to reconcile structural identity with resolved runtime identity. Once both are
first-class (Stages 2 + 5), the alias layer is redundant and is **deleted** in
Stage 5 (after confirming the custom-`ResolvableView` caveat in Stage 4).

### Lazy/indexed children
`indexedChildSource` roots are where placed children are a viewport-clipped subset
of source children (`supportsRetainedReuse == false`, `ResolvedNode.swift:287-295`).
Structural identity exists for all source children; runtime nodes are allocated
lazily for the placed subset (Stages 4 + 5). Must not force all rows to resolve.

## A correction to the containment relation itself

The prior proposal (and Stage 1's draft) described `Identity.isAncestor`/
`isDescendant` as "string-prefix checks." That is imprecise and *understates* the
current code: they are length-guarded **component-wise** prefix checks
(`zip(components, other.components).allSatisfy(==)`, `GeometryTypes.swift:629-639`),
which already avoid the classic `"/foo"`-prefixes-`"/foobar"` bug. (`Comparable`'s
`<` does compare `path` lexically, `:641-643`, but ancestry does not.) The
divergence the migration targets is *genuine structural* divergence (`.id`,
`ForEach`, portals, duplicates), not naive string aliasing. The plans state this
honestly so we do not over-claim the problem.

## Cross-cutting invariants

1. Structural adjacency (`StructuralPath`) is authoritative for subtree
   membership wherever it is available; `Identity.parent` is not proof of
   containment.
2. A runtime lifetime (`ViewNodeID`) is preserved only when reconciliation proves
   the same structural slot, compatible type, and compatible entity identity —
   and, from Stage 6, when the entity routing table proves the same entity across
   a move.
3. `.id` changes entity identity under a structural slot; it is never the only
   representation of structural parentage.
4. Duplicate explicit ids are contained (distinct lifetimes + diagnostic), never
   aliased.
5. Portal/presentation content models both declaration owner and placement
   parent, as distinct typed edges.
6. State-slot ownership stays stable for the supported surface: the migration must
   never accidentally move closure-owned `@State` into each `ForEach` element.
7. Debug mode can compare a retained/structural update against a full rebuild
   while the migration is in progress (the oracle, per stage).

## Non-goals

- Do **not** change the public SwiftUI-shaped authoring API.
- Do **not** make child repos depend on the org root or Bazel.
- Do **not** require all lazy rows to resolve to build a structural index.
- Do **not** claim SwiftUI compatibility beyond the behavior covered by tests.
- Do **not** keep permanent compatibility bridges (string-literal `Identity`
  shims, parallel legacy keying). Break internal representation now.

## Cross-cutting open questions

Per-stage open questions live in the stage plans. The questions that span stages:

1. **Compact key vs path.** `ResolvedNode` carries the full `StructuralPath`
   (the cross-frame anchor) and derives a compact frame-local `StructuralNodeKey`
   in Stage 1's indexer. (Stage 2 OQ#1.)
2. **Does `Identity` survive?** Yes — as the serialized public/debug projection
   only (snapshots, accessibility bridge, fixtures). No runtime index keys on it
   after Stage 5; `@State` stops after Stage 6. (Stage 5 OQ#2.)
3. **Routing vs `inferringMoves`.** Entity routing handles keyed lifetime;
   `inferringMoves` handles unkeyed positional ordering. They coexist. (Stage 6
   OQ#3.)
4. **`ViewNodeID` scope.** Graph-scoped `(scope, counter)` composes with
   `__SwiftTUIStateGraph` isolation. (Stage 5 OQ#1.)

## Recommendation

Land the stages in order: **0 → 1 → 2 → 3 → 4 → 5 → 6.** Stages 0–1 are safe
today. Stages 2–4 build the structural and entity axes. Stage 5 splits runtime
lifetime (behavior-preserving, behind the byte-equivalence oracle). Stage 6 routes
entity lifetime (the one semantic change, behind characterization tests).

The critical shift, stated once:

```text
Today:
  one Identity string implies structure, lifetime, entity, and state scope

Destination:
  StructuralPath proves containment
  EntityIdentity routes lifetime across moves
  ViewNodeID is the runtime lifetime
  StateSlotIdentity scopes stored state
  Identity is a public/debug projection, and nothing more
```

That model matches the useful part of StateTree's design while respecting
SwiftTUI's value-view, result-builder architecture — and it retires the overload
that every current identity bug traces back to.
