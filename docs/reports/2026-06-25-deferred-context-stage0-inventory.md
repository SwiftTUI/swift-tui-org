# Deferred Context Stage 0 Inventory

- **Date:** 2026-06-25
- **Scope:** `swift-tui` HEAD `3cdb891c`
- **Plan:** [../plans/2026-06-25-002-deferred-context-abstraction-refactor-plan.md](../plans/2026-06-25-002-deferred-context-abstraction-refactor-plan.md)

This report is the Stage 0 baseline for the deferred-context abstraction split.
It was generated from:

```bash
rg -n "makeDeferredAuthoringContext|DeferredViewPayload|PortalContentPayload|LayoutDependentContentBoundary|DeferredAuthoringContextSnapshot|scopedAnyView|AnyView\(scoped|AnyView\.scoped" swift-tui/Sources -S
```

## Contract Buckets

| Bucket | Meaning |
| --- | --- |
| Captured inline child scope | A stored in-tree child keeps the caller's authored owner but is resolved inline. |
| Captured subview payload | A style or decoration owns placement of caller-authored closure content. |
| Lazy active-only child | A container keeps inactive authored content unresolved until it is active. |
| Portal attachment | Content is declared at a source node but hosted under the presentation portal. |
| Layout-realized content | Content is authored only after final layout geometry exists. |
| Scoped erased storage / outside split | Scoped erasure participates in owner preservation but is not a deferred payload migration target. |

## Inventory

### Captured Inline Child Scope

These sites currently store `AuthoringContext?` values returned by
`makeDeferredAuthoringContext()` and resolve ordinary in-tree children later.
They should move to `CapturedSubviewScope`, not `CapturedSubviewPayload`.

| Site | Current use | Target |
| --- | --- | --- |
| `SwiftTUIViews/Foundation/ViewModifier.swift` | `ModifiedContent.authoringContext` captures a deferred authoring context unconditionally. | Captured inline child scope |
| `SwiftTUIViews/Modifiers/ViewLayoutModifiers.swift` | `.safeAreaInset` stores `insetAuthoringContext`. | Captured inline child scope |
| `SwiftTUIViews/Modifiers/ViewLayoutModifiers.swift` | `.overlay` stores `overlayAuthoringContext`. | Captured inline child scope |
| `SwiftTUIViews/Modifiers/ViewLayoutModifiers.swift` | `.background` stores `backgroundAuthoringContext`. | Captured inline child scope |
| `SwiftTUIViews/ScrollView/ScrollView.swift` | `ScrollView.contentAuthoringScope` is captured in both initializers. | Captured inline child scope |

### Captured Subview Payload

These sites use `DeferredViewPayload` as a closure transport where the style owns
placement and the caller owns state.

| Site | Current use | Target |
| --- | --- | --- |
| `SwiftTUIViews/Controls/ButtonStyles.swift` | `ButtonStyleConfiguration.Label.payload` stores `DeferredViewPayload`. | Captured subview payload |
| `SwiftTUIViews/Controls/TextFieldStyles.swift` | `TextFieldStyleConfiguration.Label.payload` stores `DeferredViewPayload`. | Captured subview payload |
| `SwiftTUIViews/Controls/PickerStyles.swift` | `PickerStyleConfiguration.Label.payload` stores `DeferredViewPayload`. | Captured subview payload |

Shared plumbing:

- `SwiftTUIViews/Foundation/ViewCompositionHelpers.swift` defines
  `DeferredViewPayload`, `DeferredPayloadView`, and `DeferredPayloadGroupView`.
- `SwiftTUIViews/Foundation/ViewFoundation.swift` defines
  `appendDeferredDeclaredBuilderChildren` and
  `deferredDeclaredBuilderChildren`.
- `SwiftTUIViews/Foundation/ViewProtocols.swift` declares
  `DeclaredChildrenView.appendDeferredDeclaredChildren`.
- `TupleView`, `VariadicView`, `Group`, `ForEach`, and
  `ConditionalContentView` implement the deferred declared-child traversal.

This shared plumbing also serves `TabView`; it cannot be renamed wholesale in a
single step.

### Lazy Active-Only Child

These sites use a generic deferred or portal payload today, but semantically
represent active-only replacement content.

| Site | Current use | Target |
| --- | --- | --- |
| `SwiftTUIViews/TabViews/TabView.swift` | `TabOption.contentPayload` and local `contentPayloads` store `DeferredViewPayload?`. | `LazySubviewPayload` with `tabBody` origin |
| `SwiftTUIViews/TabViews/TabViewStyles.swift` | `TabViewStyleBodyConfiguration.Content.payload` stores `DeferredViewPayload?`. | `LazySubviewPayload` with `tabBody` origin |
| `SwiftTUIViews/NavigationViews/NavigationStack.swift` | destination modifiers capture destination and dismiss contexts, then build `PortalContentPayload` for active destinations. | `NavigationDestinationPayload` / `LazySubviewPayload` with navigation origin |
| `SwiftTUIViews/NavigationViews/NavigationDestinationPreferences.swift` | `NavigationDestinationInstance.payload` stores `PortalContentPayload`. | `NavigationDestinationPayload` / `LazySubviewPayload` with navigation origin |

Navigation is intentionally listed with a separate origin: it carries
declaration identity, activation ordinal, dismiss closure, and authoring-context
restoration that `TabView` does not.

### Portal Attachment

These sites are genuinely detached presentation content. They should move from
generic `PortalContentPayload` naming to `PortalAttachmentPayload` while reusing
the existing portal edge data.

| Site | Current use | Target |
| --- | --- | --- |
| `SwiftTUIViews/Presentation/Portal.swift` | Defines `PortalContentPayload`, `PortalPayloadView`, `PortalPayloadGroupView`, and portal declared-child helpers. | Portal attachment payload core |
| `SwiftTUIViews/Presentation/PresentationItems.swift` | Prompt and toast item payload arrays store `[PortalContentPayload]`; popovers wrap prompt items. | Portal attachment payload arrays |
| `SwiftTUIViews/Presentation/OverlayStack.swift` | `OverlayStackEntry.payload` stores `PortalContentPayload`; `PortalEntryID` derives `DeclarationOwnerEdge`. | Portal attachment payload plus existing edge |
| `SwiftTUIViews/Presentation/PresentationCoordinatorRegistry.swift` | Coordinator boxes build overlay entries from presentation item payloads. | Portal attachment payload |
| `SwiftTUIViews/Presentation/PromptPresentationEntrypoints.swift` | Alert, confirmation dialog, sheet, and palette-sheet entry points capture action/message/content/dismiss contexts. | Portal attachment payload |
| `SwiftTUIViews/Presentation/PresentationModifiers.swift` | Sheet-style modifier captures sheet content and dismiss contexts. | Portal attachment payload |
| `SwiftTUIViews/Presentation/PopoverPresentation.swift` | Popover modifiers capture popover/action/dismiss contexts. | Portal attachment payload |
| `SwiftTUIViews/Presentation/BuiltinItemPopoverPresentationModifier.swift` | Builds typed popover items with generic content payload arrays. | Portal attachment payload |
| `SwiftTUIViews/Presentation/ToastPresentation.swift` | Toast captures dismiss context and builds generic portal content payloads. | Portal attachment payload, non-modal/no Escape dismiss entry |
| `SwiftTUIViews/Controls/Menu.swift` | Menu uses `BuiltinSheetPresentationModifier` shell with menu spec and captures sheet/dismiss contexts. | Menu-specific portal modifier shell |

Existing edge data:

- `PortalEntryID` carries source identity, source structural path, source entity
  identity, and token.
- `DeclarationOwnerEdge` carries source identity, source structural path, source
  entity identity, placement root, and token.
- Popover item models, prompt descriptors, coordinators, and overlay entries
  carry role-specific fields such as attachment anchor, focus-scope creation,
  modal policy, ordering, and dismiss-stack behavior.

### Layout-Realized Content

These sites are true layout-time realization and should keep their semantics.

| Site | Current use | Target |
| --- | --- | --- |
| `SwiftTUIViews/GeometryReading/GeometryReader.swift` | Captures authoring context and creates `LayoutDependentContentBoundary`. | `LayoutRealizedContentBoundary` |
| `SwiftTUICore/Resolve/LayoutDependentContent.swift` | Defines `LayoutRealizationContext`, `LayoutDependentContentRealizer`, and `LayoutDependentContentBoundary`. | Layout-realized names |
| `SwiftTUICore/Place/LayoutEngine+SpecialPlacementRequests.swift` | Realizes layout-dependent boundaries during placement. | Layout-realized names |
| `SwiftTUICore/Resolve/ResolvedNode.swift` | Stores `layoutDependentContent`. | Layout-realized names |
| `SwiftTUICore/Resolve/ViewNodeCommittedAccessors.swift` | Exposes committed layout-dependent content. | Layout-realized names |
| `SwiftTUICore/Commit/LayoutPassContext.swift` | Passes layout realization context. | Layout-realized names |

### Scoped Erased Storage / Outside Split

These sites should stay visible in follow-up audits but are not primary payload
rename targets.

| Site | Current use | Target |
| --- | --- | --- |
| `SwiftTUIViews/Foundation/ViewFoundation.swift` | `scopedAnyView(authoringContext:_:)` builds `AnyView(scoped:authoringContext:)`. | Scoped erased storage |
| `SwiftTUIViews/ViewBuilder/ViewBuilder.swift` | Uses `scopedAnyView` for builder erasure. | Scoped erased storage |
| `SwiftTUIViews/Foundation/AnyView.swift` | Plain `AnyView(_:)` stores no authoring context; scoped init preserves context. | Outside split unless scoped storage changes |

## Coverage Anchors

The current test suite already has focused coverage for the Stage 0 behavior
surface. Later migration commits should keep these suites green and add narrower
tests where a stage changes a contract.

| Risk | Existing coverage anchor |
| --- | --- |
| Style/captured state owner and focus stability | `SwiftTUITests/ButtonFocusStabilityTests.swift` |
| Scoped erased storage owner preservation | `SwiftTUITests/AnyViewResilienceTests.swift` |
| Active tab task publication after selection | `SwiftTUITests/TabTaskActivationRuntimeTests.swift` |
| Navigation destination binding/dismiss ownership | `SwiftTUITests/NavigationDestinationTests.swift` |
| Presentation focus/action scope and source ownership | `SwiftTUITests/PresentationActionScopeTests.swift`, `SwiftTUITests/PresentationSurfaceTests.swift` |
| Presentation trigger-leaf reuse | `SwiftTUITests/PresentationTriggerSplitTests.swift` |
| Portal ordering and declaration-owner edge data | `SwiftTUITests/OverlayStackTests.swift` |
| GeometryReader state, layout realization, and autonomous task frames | `SwiftTUITests/GeometryReaderSurfaceTests.swift` |
| Anchor/placed-frame realization | `SwiftTUITests/AnchorPreferenceSurfaceTests.swift` |

## Stage 0 Conclusion

No production behavior changes are part of Stage 0. The next stage can introduce
compatibility vocabulary while preserving the implementation behind each current
call site.
