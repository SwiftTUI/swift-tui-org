# Proposal: split deferred context into explicit realization contracts

**Date:** 2026-06-25 - **Status:** Proposed - **Scope:** `swift-tui`
runtime and `SwiftTUIViews` lowering architecture.

**Verified against:** `swift-tui` HEAD `3cdb891c` (2026-06-25). The concrete type,
file, and behavior claims below were checked against that revision; the proposed
contract names (`CapturedSubviewScope`, `CapturedSubviewPayload`,
`LazySubviewPayload`, `PortalAttachmentPayload`, `LayoutRealizedContentBoundary`)
are coined here and do not yet exist in the tree.

## TL;DR

SwiftTUI currently uses the "deferred context" family for several different
jobs:

- preserving authored state/environment ownership across delayed lowering;
- transporting authored child views into styles and stored modifiers;
- lazily lowering active-only content such as tab bodies and navigation
  destinations;
- hosting detached presentation content in the portal overlay stack;
- realizing geometry-dependent content during layout.

Those jobs have different runtime contracts. Keeping one broad abstraction makes
state ownership, lifecycle registration, invalidation routing, and performance
work harder than necessary. The correct direction is not to remove delayed
lowering everywhere, but to split the abstraction into named contracts that
match the reason lowering is delayed.

Proposed contracts:

| Contract | Use when | Replaces / narrows |
| --- | --- | --- |
| `CapturedSubviewScope` | A stored, eagerly-built in-tree child only needs the caller's authored owner | the `AuthoringContext?` token captured by `makeDeferredAuthoringContext()` at inline child sites (`ScrollView`, `.overlay`/`.background`, `.safeAreaInset`) |
| `CapturedSubviewPayload` | A style/decoration owns placement of a caller-authored child | style-label use of `DeferredViewPayload` |
| `LazySubviewPayload` | A container chooses which authored child is active | `DeferredViewPayload` for `TabView`; `PortalContentPayload` for navigation destinations |
| `PortalAttachmentPayload` | Content is declared at one source but placed in a detached overlay portal | presentation-specific use of `PortalContentPayload` |
| `LayoutRealizedContentBoundary` | Content needs final layout geometry before it can be authored | `LayoutDependentContentBoundary`, retained for true geometry readers |

> **These five contracts carve up two existing types, not five.** Today only two
> payload structs exist — `DeferredViewPayload`
> (`Foundation/ViewCompositionHelpers.swift`) and `PortalContentPayload`
> (`Presentation/Portal.swift`) — plus the bare `AuthoringContext?` token returned
> by `makeDeferredAuthoringContext()`. `DeferredViewPayload` alone backs style
> labels (→ `CapturedSubviewPayload`), `TabView` active bodies (→
> `LazySubviewPayload`), **and** ViewBuilder structural-children enumeration
> (`TupleView`/`VariadicView`/`Group`/`ForEach`/`ConditionalContentView`).
> `PortalContentPayload` backs both detached presentations (→
> `PortalAttachmentPayload`) and in-stack navigation destinations (→
> `LazySubviewPayload`). So the split peels several contracts out of each shared
> type rather than renaming one type per contract — see "Shared-type hazard"
> under the conversion plan.

## Problem

"Deferred context" is currently an implementation bucket rather than a semantic
boundary. The same naming covers lightweight style labels, inline modifier
children, active-only tab bodies, portal-hosted presentations, and
layout-realized geometry content.

That broadness has had real costs:

- **State ownership is implicit.** Captured content often needs the original
  authoring owner, while resolved payload nodes need a live graph node at their
  destination. The system has had to recover live owners from captured IDs.
- **Graph topology is surprising.** Capture-hosted content can form island seams
  that are not reachable through ordinary `ViewNode.parent` walks.
- **Lifecycle and runtime registration publication need special recovery.**
  Scoped registration restore cannot rely only on live child traversal when
  payloads are inserted through capture-host seams.
- **Performance work overfits symptoms.** Presentation open latency has needed
  trigger-leaf reader attribution, portal invalidation translation, and
  publication narrowing. Those are useful fixes, but they work around overloaded
  content boundaries rather than making the boundary explicit.

The goal is to make each delayed-lowering use case declare what it needs from
the runtime.

## Current implementation map

### Authoring snapshot

`swift-tui/Sources/SwiftTUIViews/State/AuthoringContext.swift` defines
`DeferredAuthoringContextSnapshot`, which preserves:

- `viewIdentity`;
- `structuralIdentity` and `structuralPath`;
- focused values;
- `ownerNodeID`;
- `stateGraphScope`.

That snapshot intentionally does not retain the live `ViewNode`. It is a
captured identity/scope token, not a rendered-tree node.

Two further facts matter for any rename. First, the snapshot drops *two* fields
from the full `AuthoringContext`, not one: besides the live `ViewNode`, the
round-trip resets `ordinalTracker` to a fresh, **frozen** `AuthoringOrdinalTracker`.
That frozen tracker is load-bearing for slot stability across delayed lowering, so
a narrowed contract must preserve it — the relationship is a lossy projection
pair, not a wrapper. Second, a parallel and even narrower Sendable snapshot
already exists: `ImperativeAuthoringContextSnapshot` (four fields — `viewIdentity`,
`focusedValues`, `ownerNodeID`, `stateGraphScope`), used for imperative callbacks.
It is the closest existing analog to "a value that cannot accidentally carry a
live `ViewNode`" (Open question 1). The rename should reconcile these two snapshot
types rather than introduce a third.

### Generic authored payloads

`swift-tui/Sources/SwiftTUIViews/Foundation/ViewCompositionHelpers.swift`
defines `DeferredViewPayload`. It eagerly builds the authored view *value* at init
time and defers only its *resolution* into `ResolvedNode`s, running that
resolution under a saved authoring-context **snapshot**
(`DeferredAuthoringContextSnapshot`: no live `ViewNode`, frozen ordinal tracker).

`swift-tui/Sources/SwiftTUIViews/Presentation/Portal.swift` defines
`PortalContentPayload`. It likewise builds the view eagerly at the declaration
site and defers only resolution at the portal destination, but it carries the
passed `AuthoringContext` through **verbatim** (via `withAuthoringContext`),
without snapshotting.

These payloads are mechanically similar — both are `@MainActor Sendable` structs
storing a single deferred resolve closure, both default to
`currentAuthoringContext()`, and both even share the ViewBuilder
structural-children plumbing (`DeclaredChildrenView` exposes parallel
`appendDeferredDeclaredChildren` and `appendPortalDeclaredChildren` paths that the
same five structural views implement). So the cleavage is **not** "authored child
vs declaration-to-placement" — both are deferred-resolution transports. The axis
that actually differs, and that any rename must preserve, is
**authoring-context treatment**: `DeferredViewPayload` snapshots and isolates the
context (drops the live node, freezes the ordinal tracker), while
`PortalContentPayload` preserves the caller's live context unchanged.

Both types are themselves overloaded buckets. `DeferredViewPayload` serves three
distinct jobs — style-config labels, `TabView` active bodies, and ViewBuilder
structural-children enumeration. `PortalContentPayload` serves two — detached
presentations (sheets/alerts/dialogs/popovers/menus/toasts) **and** in-stack
navigation destinations, which are not detached overlays at all. The narrower
contracts proposed below are a response to that overload; the "two clean buckets"
intuition is the thing being corrected, not a premise to build on.

### Layout-dependent content

`swift-tui/Sources/SwiftTUICore/Resolve/LayoutDependentContent.swift` defines
`LayoutDependentContentBoundary`, `LayoutRealizationContext`, and
`LayoutDependentContentRealizer`. This is not merely delayed authoring. It asks
the layout engine to realize children after proposal, bounds, safe area, cell
metrics, pointer capabilities, and placed-frame data are known.

### Portal overlays

`PresentationPortalRoot` (a real type) plus the free function
`composeOverlayStackTree(baseNode:entries:)` over `[OverlayStackEntry]` already
implement a **framework-owned** overlay tree. (There is no type named
`OverlayStack`; it is only a `ResolvedNode` kind label and a file name. This
proposal uses "OverlayStack" as shorthand for that function-plus-entry family.)
The portal system composes a base node plus detached entries, sets focus-scope
and modal interaction semantics, and uses a full-surface composition boundary
(`invalidationScope: .fullSurfaceDiff`) for overlay damage.

This means the presentation question is not "portal versus ZStack" in the
abstract. The portal is already a framework-owned overlay stack. The question is
whether each presentation needs detached placement semantics, and most of them
do.

## Use-case assessment

### `GeometryReader`: keep layout-time realization

`GeometryReader` is the strongest legitimate use of
`LayoutDependentContentBoundary`.

It cannot author correct content until layout has:

- the layout proposal and final bounds;
- safe area insets;
- cell pixel metrics;
- pointer capabilities;
- the placed-frame table (named coordinate spaces and per-identity anchor frames).

Keep this as `LayoutRealizedContentBoundary`. Do not replace it with a conditional
overlay or generic lazy payload.

### `ScrollView`, `.overlay`, `.background`, `.safeAreaInset`: keep captured in-tree children

These sites store authored children and resolve them inline as ordinary child
nodes.

Examples:

- `ScrollView` stores `contentAuthoringScope`, then resolves the content as a
  direct child.
- `.overlay` and `.background` resolve the stored modifier view into in-tree
  decoration children.
- `.safeAreaInset` resolves the inset child next to the base child.

These should not be modeled as portal content or layout-dependent content. They
should use a smaller `CapturedSubviewScope` naming layer because their only
special need is preserving the caller's authoring owner.

### Style labels: keep lightweight captured payloads

`ButtonStyleConfiguration.Label`, `TextFieldStyleConfiguration.Label`, and
`PickerStyleConfiguration.Label` are correct in shape. A style receives a
caller-authored label and decides where to place it.

The current mechanism is `DeferredViewPayload` (the same type `TabView` bodies
use), and it is useful — but the name should communicate that the style owns
placement while the caller owns state. This fits `CapturedSubviewPayload` or a
style-specific wrapper over it. Note the shared-type hazard: peeling style labels
onto `CapturedSubviewPayload` touches the same `DeferredViewPayload` that the
`TabView` step retypes to `LazySubviewPayload`.

### `TabView`: split metadata peeking from active body realization

`TabView` has two separate needs:

1. It must inspect declared child metadata cheaply so inactive tabs do not fire
   lifecycle handlers or tasks.
2. It must render exactly one active body through the selected tab style.

The first need is sound and should stay: metadata-first enumeration is the right
SwiftUI-like behavior for tabs.

The second need should stop using a generic deferred payload. The selected tab
body should be a typed `LazySubviewPayload` owned by `TabView`, with explicit
rules for:

- active/inactive lifecycle;
- state owner recovery;
- runtime registration restoration;
- invalidation from a tab body back to the tab container;
- style-owned placement of the active body.

This would make tab bodies first-class lazy children instead of opaque
capture-host islands.

### Sheets, alerts, confirmation dialogs, palette sheets, and toasts: keep portal placement, type the payload

These are detached presentations. They need framework-owned behavior that a
local conditional `ZStack` does not provide consistently:

- presentation ordering;
- focus scope creation;
- base interaction disabling for modal surfaces;
- escape dismissal;
- full-surface damage and composition boundaries;
- declaration at one source with placement under a portal host.

Caveat: **toasts are not modal.** `ToastPresentationCoordinator` is `.nonModal`,
sets `allowsHitTesting(false)`, and exposes no Escape dismiss action through the
overlay dismiss stack, so the "base interaction disabling" and "escape
dismissal" bullets apply to sheets/alerts/dialogs/palette sheets but **not**
toasts. Toasts still have coordinator/programmatic dismissal; they share the
portal payload, presentation ordering, and full-surface composition path, not the
modal-surface semantics.

Keep the portal overlay architecture. Replace generic payload naming with a
`PortalAttachmentPayload` or presentation-specific wrapper that explicitly
records:

- source identity and structural path;
- source owner edge;
- activation identity;
- modal policy;
- lifecycle ownership;
- registration restore scope;
- invalidation translation rules.

Much of this already exists and need not be invented. `PortalEntryID` and
`DeclarationOwnerEdge` (`SwiftTUICore/Runtime/PortalTypes.swift`) record source
identity, source structural path, source entity identity, placement root, and
token, and the edge is already stamped onto `ResolvedNode.declarationOwnerEdge`
for portal entries. The presentation layer then adds role-specific metadata:
`PopoverPresentationItem` carries `sourceIdentity`, `attachmentAnchor`,
`arrowEdge`, and `modalPolicy`; `PromptPresentationDescriptor` carries
`createsFocusScope`; coordinators and overlay entries carry modal policy and
dismiss-stack behavior. So `PortalAttachmentPayload` is largely a
*surfacing/renaming* of existing portal-side edge data. The genuinely new fields
are the lifecycle-active-while-hidden flag and an equivalent declarative edge on
the *deferred* side (tab bodies and style labels carry only the authoring
snapshot today).

The trigger-leaf optimization should stay separate. It is about reader
attribution for activation state, not about how presented content is captured.
(`PresentationTriggerLeaf` is real and is wired by `resolvePresentationModifier`
for sheet/alert/confirmationDialog/palette-sheet; toasts merge their declaration
directly and do not use it. The element shared across *all* presentations is
`PortalContentPayload` plus the coordinator registry, not the trigger leaf.)

### Popovers: keep portal plus geometry placement

A SwiftUI-like popover is not just "conditionally render a view above another
view." It needs source-frame anchoring, viewport clamping, focus/modal policy,
and detached overlay placement. The existing implementation uses `GeometryReader`
inside the hosted popover to read the source frame from the placed-frame table.

Keep this as portal-hosted content with a placement/layout pass. The payload
should be typed as a popover attachment rather than generic portal content.

Note this is largely already done. Popovers have a dedicated modifier
(`BuiltinItemPopoverPresentationModifier`, recently broken out), a typed item
(`PopoverPresentationItem`, carrying `sourceIdentity`/`attachmentAnchor`/
`arrowEdge`/`modalPolicy`), a dedicated `registry.popover` coordinator, and full
source-anchoring + viewport-clamping placement (`HostedPopoverPresentation` +
`PopoverPlacementLayout`). The only still-generic layer is the inner
`contentPayloads: [PortalContentPayload]`, so scope the "type the payload" work to
that layer, not the whole attachment.

### `Menu`: move away from sheet-shaped implementation

`Menu` currently routes its expanded content through the sheet presentation
modifier using menu chrome. That works, but it is semantically wrong:

- menus are compact source-attached transient overlays;
- menu placement wants source anchoring;
- menu modality differs from sheet modality;
- menu content should not be described as sheet content.

Move `Menu` to a menu-specific portal/popover attachment payload. This can reuse
the presentation portal and chrome primitives, but it should not be built as a
sheet specialization long term.

Precisely: the only sheet specialization is that `Menu` reuses
`BuiltinSheetPresentationModifier` as its modifier *shell* (`Menu.swift` passes
the menu content as `sheetContent:`). It does **not** route through
`SheetPresentationCoordinator` or the sheet token — a dedicated
`MenuPresentationCoordinator`, a `registry.menu` slot, and a
`menuPromptPresentationSpec` (own `"menu"` token, `.menu` chrome) already exist.
The residual work is therefore narrow: give `Menu` its own modifier that anchors
at the source frame (as popover already does) instead of reusing the sheet
modifier, whose own comment notes it currently anchors at the host top-leading
"until source frames are plumbed through the presentation system."

### Navigation destinations: use lazy replacement payloads, not portal payloads

`NavigationStack.navigationDestination` is not detached overlay content. It is
active destination replacement inside the stack's visible surface.

The lazy lowering is correct, especially for item and Boolean activation. The
payload should be a `NavigationDestinationPayload` or generalized
`LazySubviewPayload`, not `PortalContentPayload`.

This is the proposal's best-supported conversion: navigation destinations
genuinely store `PortalContentPayload` today
(`NavigationStack.swift`; `NavigationDestinationInstance.payload`) yet are placed
as an in-tree `.replacingIdentity` replacement child, never through
`composeOverlayStackTree`. The mismatch is naming/typing, not a placement bug, so
this is a clarity refactor with no behavioral change. Two cautions:
`PortalContentPayload` and `DeferredViewPayload` are distinct structs with their
own resolve plumbing (not a one-line `typealias` swap), and navigation already
carries its own declaration/activation state model (source/declaration identity,
activation ordinals, dismiss closures with authoring-context restoration) that a
shared `LazySubviewPayload` must not drop — its needs differ from `TabView`'s
despite the shared "lazy" label. Pick one target name (`LazySubviewPayload`,
optionally aliased `NavigationDestinationPayload`) and use it consistently in the
conversion order below.

### `AnyView` and modifier content: preserve scoped storage, but they are asymmetric

`AnyView` and `ModifiedContent` both store authored content with a preserved scope
and resolve it inline as ordinary in-tree children — neither is active-only or
detached, and neither uses `DeferredViewPayload` or `PortalContentPayload`. But
they are **not** equivalent with respect to the deferred-context family:

- `AnyView` is genuinely a type-erasure boundary. It preserves scope only when
  built via `scopedAnyView(...)`/`AnyView(scoped:)`, and even then carries the
  **live** `AuthoringContext` (no snapshot). The plain `AnyView(_:)` init stores a
  `nil` scope. It can be treated as outside the deferred family.
- `ModifiedContent` is the opposite: its init **unconditionally** calls
  `makeDeferredAuthoringContext()`, so it is in fact one of the most pervasive
  consumers of the deferred-snapshot machinery this proposal is splitting. It
  cannot be excluded from the family without addressing that call site.

So "treat them as scoped storage, not deferred machinery" is correct for `AnyView`
but wrong for `ModifiedContent`. An implementer who leaves `ModifiedContent`'s
`makeDeferredAuthoringContext()` call untouched has not removed the deferred
dependency from "modifier content."

## Proposed design

### 1. Rename the primitive concepts before changing behavior

Introduce type aliases or wrapper types first, with no behavior change:

- `CapturedSubviewScope` — the authoring-owner token (today `AuthoringContext?`
  from `makeDeferredAuthoringContext()`) stored by inline child sites
  (`ScrollView`, `.overlay`/`.background`, `.safeAreaInset`), which keep the child
  *value* eagerly and only need the owner preserved;
- `CapturedSubviewPayload` — the closure transport for style labels (today
  `DeferredViewPayload`), where a style owns placement of a caller-authored child;
- `LazySubviewPayload` for active-only children (`TabView` bodies, navigation
  destinations);
- `PortalAttachmentPayload` for detached portal content;
- `LayoutRealizedContentBoundary` as a rename/narrowing of
  `LayoutDependentContentBoundary`.

This gives future patches a vocabulary that matches behavior before moving runtime
logic. A pure alias step is genuinely behavior-preserving here: every rename
target (`DeferredViewPayload`, `PortalContentPayload`,
`LayoutDependentContentBoundary`, `DeferredAuthoringContextSnapshot`) is
`package`-level and absent from `swift-tui/docs/.public-api-baseline.txt`, so the
public-API gate is untouched and no compatibility alias is required (this
resolves Open question 4). The new edge metadata (section 2) and the `Menu` move
(step 5) are
*not* part of the no-behavior-change boundary; keep them in their later steps and
do not describe step 1 as if it includes them.

### 2. Add explicit edge metadata for lazy and portal payloads

Lazy and portal payloads should surface the edge between declaration owner and
placement owner. At minimum:

- declaration owner identity;
- declaration structural path;
- placement root identity;
- activation identity, where applicable;
- whether lifecycle is active while hidden;
- whether runtime registrations restore via live child traversal, identity
  prefix, or explicit declaration owner edge.

For portal payloads this is largely a *surfacing* job, not new invention:
`DeclarationOwnerEdge` (`PortalTypes.swift`, stamped onto
`ResolvedNode.declarationOwnerEdge`) already records declaration owner identity,
declaration structural path, declaration entity identity, placement root, and
token for portal entries. The new surface is (a) an equivalent declarative edge
on the *deferred* side, where tab bodies and style labels carry only the
authoring snapshot today, and (b) the lifecycle-active-while-hidden flag. The
runtime already has compatibility code for island seams; this proposal makes the
deferred-side seams as declarative as the portal-side edge already is.

### 3. Keep reader-attributed activation leaves

The presentation trigger leaf is a separate performance tool. It should remain
the owner of hot activation reads so sheet/popover toggles can spare the
background subtree.

This optimization should not force all presentation content to remain generic
deferred payloads. Activation read attribution and content placement are
orthogonal.

### 4. Convert highest-risk use cases first

Recommended order:

1. Rename/document the contracts with type aliases and comments.
2. Convert `TabView` active bodies to `LazySubviewPayload`.
3. Convert navigation destinations to `LazySubviewPayload`.
4. Convert presentation payloads to `PortalAttachmentPayload`.
5. Convert `Menu` off sheet-shaped presentation and onto a menu attachment.
6. Leave `GeometryReader` for last, mostly as a rename to
   `LayoutRealizedContentBoundary`.

This order attacks capture-host island complexity before touching the
geometry-dependent path that is already semantically correct.

**Shared-type hazard.** Steps 2–4 do not map one type to one contract.
`DeferredViewPayload` is co-used by style labels, `TabView` bodies, *and*
ViewBuilder structural-children enumeration, so step 2 must carve the tab-body use
out of a type that also carries style labels (`CapturedSubviewPayload`) and the
tuple/conditional/`ForEach` plumbing — it cannot simply rename the type. Likewise
`PortalContentPayload` is co-used by detached presentations (step 4) and
navigation (step 3), and both `DeclaredChildrenView` append paths
(`appendDeferredDeclaredChildren`/`appendPortalDeclaredChildren`) must move
together. Plan each step as "introduce the narrow contract, migrate one use site,
leave the shared type intact for the others," not "rename the type."

## Non-goals

- Do not replace sheets/popovers with arbitrary app-authored `ZStack`
  conditionals.
- Do not make inactive tabs eager.
- Do not make presented content part of the base layout tree when it needs modal
  focus or detached overlay semantics.
- Do not change public SwiftUI-shaped APIs in this tranche.
- Do not remove reader attribution or the presentation trigger leaf.
- Do not change `GeometryReader` sizing behavior.

## Validation plan

### Unit and surface tests

- Existing `TabViewSurfaceTests`, `TabViewLifecycleTests`, and
  `TabTaskActivationRuntimeTests` must stay green.
- Add focused tests that active tab body state updates invalidate the visible
  surface without requiring a follow-up root frame.
- Add tests that inactive tab bodies do not start `.task` or `.onAppear`.
- Add navigation destination tests for state persistence across activation,
  dismissal, and item identity changes.
- Add presentation tests that sheet/popover/menu content action handlers mutate
  the original authoring owner after payload typing.

### Runtime registration tests

Add or extend tests that prove runtime registrations behind lazy/portal edges are
restored after scoped publication. The test should exercise:

- action handlers inside selected tab body content;
- task/lifecycle handlers inside selected tab body content;
- action handlers inside portal-hosted sheet/popover/menu content.

### Performance checks

Use existing focused scenarios before and after each conversion:

- `sheet-open-latency`, default and a tall-terminal override (e.g. `rows=176`;
  the scenario default is `rows:60`, so 176 is a CLI size override, not a
  separately registered variant);
- `example-app-shell-workflow`;
- `synthetic-narrow-invalidation`;
- tab switch and overflow surface tests.

The expected first-order result is not necessarily immediate lower CPU in every
scenario. The acceptance criterion for the refactor is that equivalent behavior
is preserved while island handling becomes explicit enough to remove
compatibility shims in later patches.

## Acceptance criteria

- Every delayed-lowering site is classified as captured inline child, lazy
  active-only child, portal attachment, or layout-realized content — recorded as a
  checked-in inventory that names each call site (e.g. `ScrollView.swift`,
  `TabView.swift`, `NavigationStack.swift`, `PresentationItems.swift`,
  `LayoutDependentContent.swift`) and its assigned contract, so completeness is
  verifiable rather than asserted.
- `TabView` and navigation no longer use generic presentation/portal terminology
  for non-portal payloads.
- Presentation payloads explicitly model declaration owner versus placement
  owner.
- `Menu` no longer routes through a sheet-specific modifier path.
- No regression in state-owner recovery, lifecycle activation, runtime
  registration restoration, or presentation open performance.

## Open questions

1. Should `CapturedSubviewScope` be the existing `AuthoringContext?` token, or a
   distinct value that *structurally* cannot carry a live `ViewNode`? Today the
   storage type is `AuthoringContext?`, but `makeDeferredAuthoringContext()`
   already guarantees `viewNode == nil` — the guarantee is by convention (the
   factory), not by type. `ImperativeAuthoringContextSnapshot` is an existing,
   narrower Sendable template to reconcile with rather than inventing a third type.
2. Should lazy payloads own lifecycle activation directly, or should they only
   expose edge metadata to the existing lifecycle publication pass?
3. How much of the portal-attachment edge metadata should live in `ResolvedNode`
   versus presentation item models? (Partly settled today: source structural path
   and source entity identity live in `PortalEntryID`/`DeclarationOwnerEdge`;
   `sourceIdentity`/`modalPolicy`/`attachmentAnchor` live on popover item models;
   `createsFocusScope` lives on prompt descriptors; and `DeclarationOwnerEdge`
   lives on `ResolvedNode`; the open part is which precedent the *deferred* side
   should follow.)
4. **Resolved.** `LayoutDependentContentBoundary` (and its siblings
   `LayoutRealizationContext`/`LayoutDependentContentRealizer`) are `package`-level
   and absent from `swift-tui/docs/.public-api-baseline.txt`; there is no `@_spi`
   baseline. The rename is purely internal (callers: `GeometryReader` plus a
   handful of `SwiftTUICore` files) and needs no compatibility alias.
