# Proposal: split deferred context into explicit realization contracts

**Date:** 2026-06-25 - **Status:** Proposed - **Scope:** `swift-tui`
runtime and `SwiftTUIViews` lowering architecture.

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
| `CapturedSubviewScope` | Stored in-tree children need the caller's authored owner | generic `makeDeferredAuthoringContext()` at inline child sites |
| `LazySubviewPayload` | A container chooses which authored child is active | `DeferredViewPayload` for `TabView` and navigation-like surfaces |
| `PortalAttachmentPayload` | Content is declared at one source but placed in a detached overlay portal | presentation-specific use of `PortalContentPayload` |
| `LayoutRealizedContent` | Content needs final layout geometry before it can be authored | `LayoutDependentContentBoundary`, retained for true geometry readers |

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

### Generic authored payloads

`swift-tui/Sources/SwiftTUIViews/Foundation/ViewCompositionHelpers.swift`
defines `DeferredViewPayload`, which resolves a captured closure later under the
saved authoring context.

`swift-tui/Sources/SwiftTUIViews/Presentation/Portal.swift` defines
`PortalContentPayload`, which builds the view at the declaration site and
resolves it later at the portal destination.

These payloads are mechanically similar, but they represent different runtime
relationships. `DeferredViewPayload` is mostly an authored child transport.
`PortalContentPayload` is a declaration-to-placement transport.

### Layout-dependent content

`swift-tui/Sources/SwiftTUICore/Resolve/LayoutDependentContent.swift` defines
`LayoutDependentContentBoundary`, `LayoutRealizationContext`, and
`LayoutDependentContentRealizer`. This is not merely delayed authoring. It asks
the layout engine to realize children after proposal, bounds, safe area, cell
metrics, pointer capabilities, and placed-frame data are known.

### Portal overlays

`PresentationPortalRoot` and `OverlayStack` already implement a user-space
overlay tree. The portal system composes a base node plus detached entries,
sets focus-scope and modal interaction semantics, and uses a full-surface
composition boundary for overlay damage.

This means the presentation question is not "portal versus ZStack" in the
abstract. The portal is already a framework-owned overlay stack. The question is
whether each presentation needs detached placement semantics, and most of them
do.

## Use-case assessment

### `GeometryReader`: keep layout-time realization

`GeometryReader` is the strongest legitimate use of
`LayoutDependentContentBoundary`.

It cannot author correct content until layout has:

- final bounds;
- safe area insets;
- cell pixel metrics;
- pointer capabilities;
- named coordinate-space and anchor frame data.

Keep this as `LayoutRealizedContent`. Do not replace it with a conditional
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

The current payload mechanism is useful, but the name should communicate that
the style owns placement while the caller owns state. This fits
`CapturedSubviewScope` or a style-specific wrapper over it.

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

The trigger-leaf optimization should stay separate. It is about reader
attribution for activation state, not about how presented content is captured.

### Popovers: keep portal plus geometry placement

A SwiftUI-like popover is not just "conditionally render a view above another
view." It needs source-frame anchoring, viewport clamping, focus/modal policy,
and detached overlay placement. The existing implementation uses `GeometryReader`
inside the hosted popover to read the source frame from the placed-frame table.

Keep this as portal-hosted content with a placement/layout pass. The payload
should be typed as a popover attachment rather than generic portal content.

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

### Navigation destinations: use lazy replacement payloads, not portal payloads

`NavigationStack.navigationDestination` is not detached overlay content. It is
active destination replacement inside the stack's visible surface.

The lazy lowering is correct, especially for item and Boolean activation. The
payload should be a `NavigationDestinationPayload` or generalized
`LazySubviewPayload`, not `PortalContentPayload`.

### `AnyView` and modifier content: preserve scoped storage, avoid broad "deferred" language

`AnyView` and `ModifiedContent` also store authored content with a preserved
scope. They are not necessarily active-only or detached. Treat them as scoped
storage/type-erasure boundaries, not deferred presentation machinery.

## Proposed design

### 1. Rename the primitive concepts before changing behavior

Introduce type aliases or wrapper types first, with no behavior change:

- `CapturedSubviewScope` wrapping the current deferred authoring snapshot;
- `CapturedSubviewPayload` for style labels and inline stored children;
- `LazySubviewPayload` for active-only children;
- `PortalAttachmentPayload` for detached portal content;
- `LayoutRealizedContentBoundary` as a rename/narrowing of
  `LayoutDependentContentBoundary`.

This gives future patches a vocabulary that matches behavior before moving
runtime logic.

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

The runtime already has compatibility code for island seams. This proposal
makes those seams declarative.

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

- `sheet-open-latency`, default and rows=176;
- `example-app-shell-workflow`;
- `synthetic-narrow-invalidation`;
- tab switch and overflow surface tests.

The expected first-order result is not necessarily immediate lower CPU in every
scenario. The acceptance criterion for the refactor is that equivalent behavior
is preserved while island handling becomes explicit enough to remove
compatibility shims in later patches.

## Acceptance criteria

- Every delayed-lowering site is classified as captured inline child, lazy
  active-only child, portal attachment, or layout-realized content.
- `TabView` and navigation no longer use generic presentation/portal terminology
  for non-portal payloads.
- Presentation payloads explicitly model declaration owner versus placement
  owner.
- `Menu` no longer routes through a sheet-specific modifier path.
- No regression in state-owner recovery, lifecycle activation, runtime
  registration restoration, or presentation open performance.

## Open questions

1. Should `CapturedSubviewScope` remain an `AuthoringContext?`, or should it be
   a distinct value that cannot accidentally carry a live `ViewNode`?
2. Should lazy payloads own lifecycle activation directly, or should they only
   expose edge metadata to the existing lifecycle publication pass?
3. How much of the portal attachment edge metadata should live in
   `ResolvedNode` versus presentation item models?
4. Can `LayoutDependentContentBoundary` be renamed without touching public SPI
   baselines, or does it need a compatibility alias first?
