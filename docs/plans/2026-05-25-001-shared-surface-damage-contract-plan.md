# Shared Surface Damage Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [x]`) syntax for tracking.

**Goal:** Make every rendering frontend consume a host-independent raster damage
contract that is derived from actual committed raster surfaces, so command
palette, sheet, menu, popover, transition, and compositing topology changes
cannot leave stale pixels or cells behind.

**Architecture:** Split the current damage concept into three boundaries. A
private pre-raster reuse plan may still help the rasterizer repaint fewer rows.
`FrameArtifacts.presentationDamage` records the artifact-level raster diff
against renderer-committed history after rasterization. `RunLoop` derives the
frontend-facing damage contract from the previous `RasterSurface` actually
presented to that frontend and publishes it through `SemanticHostFrame` or
`DamageAwarePresentationSurface`. First-class surface-composition metadata flows
through the core resolved and placed trees, so presentation and compositing
topology changes are encoded in the shared language rather than detected with
terminal-specific or renderer-name heuristics.

**Tech Stack:** SwiftTUICore, SwiftTUIRuntime, SwiftTUIViews,
SwiftTUIExamples gallery, swift-tui-web, Swift Testing, Bun test, Swift 6.3.x
via `swiftly`.

---

## Current Evidence

- `Ctrl+K` in the gallery command palette changes state immediately, but the
  default async renderer can cancel the input frame before the tail starts.
  The replayed invalidation frame then commits a tiny retained-layout damage
  hint that covers only the trigger/close region rather than the detached
  presentation overlay.
- `TERMUI_RENDER_MODE=sync` and `TERMUI_RENDER_MODE=async-no-cancel` hide the
  symptom because focus-sync presentation falls back to a broad repaint, not
  because the artifact-level damage is proven correct.
- Once the bad damage is consumed, the host's retained previous surface advances
  past what was physically drawn. Later tab switches clear whichever stale
  palette cells overlap their own dirty rows.
- The default async gallery regression exposed a second boundary: a renderer can
  commit or retain intermediate artifacts that the run loop never presents, so
  frontend damage must be derived from the last surface actually handed to that
  frontend, not only from renderer-retained artifact history.
- TerminalHost is only one consumer. The web canvas runtime already treats
  `frame.damage` as the shared dirty-rectangle contract, and hosted raster
  surfaces carry the same `SemanticHostFrame.rasterDamage` value.

## Non-Goals

- Do not add TerminalHost-specific repair logic.
- Do not disable async frame-tail cancellation.
- Do not scan node kind names such as `"SheetPresentation"` or
  `"OverlayStack"` inside the damage resolver.
- Do not expose pre-raster retained-layout damage as frontend damage unless a
  shared verifier proves that it covers the actual raster diff.

## File Structure To Create Or Modify

- Create `swift-tui/Sources/SwiftTUICore/Commit/SurfaceCompositionMetadata.swift`:
  shared surface-composition roles, invalidation scopes, topology signatures,
  and damage coverage helpers.
- Modify `swift-tui/Sources/SwiftTUICore/Resolve/ResolvedNode.swift`: carry
  `surfaceComposition` beside the existing resolved metadata.
- Modify `swift-tui/Sources/SwiftTUICore/Place/PlacedNode.swift`: mirror
  `surfaceComposition` into `PlacedNodeResolvedMetadata` and `PlacedNode`.
- Modify `swift-tui/Sources/SwiftTUICore/Commit/FrameArtifacts.swift`: document
  that `presentationDamage` is artifact-level actual raster damage.
- Modify `swift-tui/Sources/SwiftTUIViews/Presentation/PresentationCoordinator.swift`:
  mark the portal root as a detached overlay root at construction time.
- Modify `swift-tui/Sources/SwiftTUIViews/Presentation/OverlayStack.swift`:
  mark overlay stack, overlay host, and overlay entries with explicit
  surface-composition metadata.
- Modify `swift-tui/Sources/SwiftTUIViews/Modifiers/ViewMetadataModifiers.swift`:
  mark `.compositingGroup()` as an isolated compositing boundary.
- Modify `swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailModels.swift`:
  carry the previous committed `SurfaceTopologySignature` into frame-tail work.
- Modify `swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailRetainedState.swift`:
  retain the previous committed visual topology signature beside the previous
  raster surface.
- Modify `swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailPresentationDamage.swift`:
  turn the retained-layout damage resolver into a private raster reuse planner
  that can refuse reuse when the shared topology signature changes.
- Modify `swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailRenderer+InlineStages.swift`:
  derive artifact-level damage from actual previous/current raster surfaces
  after rasterization.
- Modify `swift-tui/Sources/SwiftTUIRuntime/RunLoop/RunLoop.swift` and
  `swift-tui/Sources/SwiftTUIRuntime/RunLoop/RunLoop+PostCommitSupport.swift`:
  track the previous actually presented raster surface and derive frontend
  damage at the presentation boundary.
- Create `swift-tui/Tests/SwiftTUITests/SurfaceDamageContractTests.swift`:
  shared contract tests for palette/sheet open and dismiss, ordinary text
  updates, and explicit coverage of actual raster diffs.
- Modify `swift-tui/Tests/SwiftTUITests/PipelineContractTests.swift`: keep the
  existing broad update test and add an equality check against
  `RasterSurfaceDamageDiff`.
- Modify `swift-tui-examples/gallery/Tests/GalleryDemoViewsTests/GalleryTabSwitchTests.swift`:
  add a damage-aware gallery host that validates command palette open/dismiss
  frames under default async rendering.
- Modify `swift-tui-web/packages/web/src/WebHostSceneRuntime.test.ts`: add a
  browser dirty-rect regression that proves stale overlay cells are cleared
  when a damage-bearing frame removes an overlay.
- Modify `swift-tui/docs/RENDER-PIPELINE.md`: document the split between
  private raster reuse and public raster damage.
- Modify `swift-tui/docs/HOSTS-AND-PLATFORMS.md`: document that all frontends
  consume the same actual-raster-damage contract.

---

### Task 1: Add Shared Surface Composition And Damage Coverage Types

**Files:**
- Create: `swift-tui/Sources/SwiftTUICore/Commit/SurfaceCompositionMetadata.swift`
- Modify: `swift-tui/Sources/SwiftTUICore/Resolve/ResolvedNode.swift`
- Modify: `swift-tui/Sources/SwiftTUICore/Place/PlacedNode.swift`

- [x] **Step 1: Create the shared surface-composition metadata type**

  Create `swift-tui/Sources/SwiftTUICore/Commit/SurfaceCompositionMetadata.swift`:

  ```swift
  /// Describes how a node participates in final surface composition.
  ///
  /// This is not a terminal concept. It is shared metadata used by the render
  /// pipeline to decide whether retained-layout raster reuse is compatible with
  /// the previous committed frame.
  package struct SurfaceCompositionMetadata: Equatable, Sendable {
    package var role: SurfaceCompositionRole
    package var stableKey: String?
    package var invalidationScope: SurfaceInvalidationScope

    package init(
      role: SurfaceCompositionRole = .normal,
      stableKey: String? = nil,
      invalidationScope: SurfaceInvalidationScope = .localBounds
    ) {
      self.role = role
      self.stableKey = stableKey
      self.invalidationScope = invalidationScope
    }

    package static let normal = Self()

    package var participatesInTopologySignature: Bool {
      role != .normal || invalidationScope != .localBounds
    }
  }

  package enum SurfaceCompositionRole: Equatable, Sendable {
    case normal
    case stackingContext
    case detachedOverlayRoot
    case detachedOverlayHost
    case detachedOverlayEntry
    case isolatedCompositingGroup
  }

  package enum SurfaceInvalidationScope: Equatable, Sendable {
    case localBounds
    case compositedBounds
    case fullSurfaceDiff
  }

  package struct SurfaceTopologySignature: Equatable, Sendable {
    package var entries: [SurfaceTopologyEntry]

    package init(entries: [SurfaceTopologyEntry] = []) {
      self.entries = entries.sorted()
    }

    package init(placedRoot: PlacedNode) {
      var entries: [SurfaceTopologyEntry] = []
      Self.collect(from: placedRoot, into: &entries)
      self.init(entries: entries)
    }

    package func differs(from previous: Self?) -> Bool {
      guard let previous else {
        return false
      }
      return self != previous
    }

    private static func collect(
      from node: PlacedNode,
      into entries: inout [SurfaceTopologyEntry]
    ) {
      if node.surfaceComposition.participatesInTopologySignature {
        entries.append(
          SurfaceTopologyEntry(
            identity: node.identity,
            role: node.surfaceComposition.role,
            stableKey: node.surfaceComposition.stableKey,
            invalidationScope: node.surfaceComposition.invalidationScope,
            bounds: node.bounds,
            zIndex: node.zIndex
          )
        )
      }
      for child in node.children {
        collect(from: child, into: &entries)
      }
    }
  }

  package struct SurfaceTopologyEntry: Equatable, Sendable, Comparable {
    package var identity: Identity
    package var role: SurfaceCompositionRole
    package var stableKey: String?
    package var invalidationScope: SurfaceInvalidationScope
    package var bounds: CellRect
    package var zIndex: Double

    package static func < (lhs: Self, rhs: Self) -> Bool {
      let lhsKey = [
        lhs.identity.path,
        String(describing: lhs.role),
        lhs.stableKey ?? "",
        String(describing: lhs.invalidationScope),
        "\(lhs.bounds.origin.x),\(lhs.bounds.origin.y)",
        "\(lhs.bounds.size.width),\(lhs.bounds.size.height)",
        "\(lhs.zIndex)",
      ]
      let rhsKey = [
        rhs.identity.path,
        String(describing: rhs.role),
        rhs.stableKey ?? "",
        String(describing: rhs.invalidationScope),
        "\(rhs.bounds.origin.x),\(rhs.bounds.origin.y)",
        "\(rhs.bounds.size.width),\(rhs.bounds.size.height)",
        "\(rhs.zIndex)",
      ]
      return lhsKey.lexicographicallyPrecedes(rhsKey)
    }
  }
  ```

- [x] **Step 2: Add metadata to resolved nodes**

  Modify `swift-tui/Sources/SwiftTUICore/Resolve/ResolvedNode.swift`:

  ```swift
  package var surfaceComposition: SurfaceCompositionMetadata
  ```

  Add `surfaceComposition: SurfaceCompositionMetadata = .normal` to both
  package initializers, assign it in each initializer, and include it in
  `Equatable` through the existing synthesized node equality path.

- [x] **Step 3: Mirror metadata through placed nodes**

  Modify `PlacedNodeResolvedMetadata` in
  `swift-tui/Sources/SwiftTUICore/Place/PlacedNode.swift`:

  ```swift
  package var surfaceComposition: SurfaceCompositionMetadata
  ```

  Add the same defaulted initializer parameter and copy
  `resolved.surfaceComposition` in `init(resolved:semanticRole:)`.

  Modify `PlacedNode` in the same file:

  ```swift
  package var surfaceComposition: SurfaceCompositionMetadata
  ```

  Initialize it from `PlacedNodeResolvedMetadata`, include it in
  `resolvedMetadata`, and update `applyResolvedMetadata(_:)` so retained
  placement reuse refreshes this metadata every frame.

- [x] **Step 4: Run the package build**

  ```bash
  swiftly run swift test --package-path swift-tui --filter SwiftTUITests.PipelineContractTests
  ```

  Expected: compile succeeds or fails only on call sites that need a new
  defaulted `surfaceComposition` parameter propagated. Fix those compile errors
  by passing `.normal` or using the initializer default.

- [x] **Step 5: Commit**

  ```bash
  git -C swift-tui add Sources/SwiftTUICore/Commit/SurfaceCompositionMetadata.swift \
    Sources/SwiftTUICore/Resolve/ResolvedNode.swift \
    Sources/SwiftTUICore/Place/PlacedNode.swift
  git -C swift-tui commit -m "feat: add shared surface composition metadata"
  ```

---

### Task 2: Mark Composition Producers At Their Source

**Files:**
- Modify: `swift-tui/Sources/SwiftTUIViews/Presentation/PresentationCoordinator.swift`
- Modify: `swift-tui/Sources/SwiftTUIViews/Presentation/OverlayStack.swift`
- Modify: `swift-tui/Sources/SwiftTUIViews/Modifiers/ViewMetadataModifiers.swift`

- [x] **Step 1: Mark the portal root**

  In `composePresentationPortalTree(...)`, construct the no-overlay portal
  root with explicit metadata:

  ```swift
  surfaceComposition: .init(
    role: .detachedOverlayRoot,
    stableKey: context.identity.path,
    invalidationScope: .fullSurfaceDiff
  )
  ```

  The no-overlay case still matters because open and dismiss compare the same
  portal root across the transition.

- [x] **Step 2: Mark the overlay stack and overlay host**

  In `composeOverlayStackTree(...)`, pass this metadata to the returned
  `ResolvedNode`:

  ```swift
  surfaceComposition: .init(
    role: .stackingContext,
    stableKey: "overlay-stack:\(context.identity.path)",
    invalidationScope: .fullSurfaceDiff
  )
  ```

  In `OverlayStackOverlayHost.resolveElements(in:)`, pass this metadata to the
  `OverlayStackOverlays` node:

  ```swift
  surfaceComposition: .init(
    role: .detachedOverlayHost,
    stableKey: "overlay-host:\(context.identity.path)",
    invalidationScope: .fullSurfaceDiff
  )
  ```

- [x] **Step 3: Mark each overlay entry without inspecting kind names later**

  In `OverlayStackEntryHost.resolveElements(in:)`, pass this metadata to the
  `ResolvedNode` that uses `entry.kindName`:

  ```swift
  surfaceComposition: .init(
    role: .detachedOverlayEntry,
    stableKey: entry.id,
    invalidationScope: .fullSurfaceDiff
  )
  ```

  This is where presentation-specific knowledge belongs. The damage resolver
  will only see shared metadata.

- [x] **Step 4: Mark compositing groups**

  In `DrawEffectModifier.resolve(content:in:)`, after appending the effect,
  mark compositing groups:

  ```swift
  if effect == .compositingGroup {
    node.surfaceComposition = .init(
      role: .isolatedCompositingGroup,
      stableKey: node.identity.path,
      invalidationScope: .compositedBounds
    )
  }
  ```

  Leave `.blendMode` as draw metadata only in this task. Blend-mode changes are
  covered by post-raster actual damage; a later optimization can add a stricter
  blend-specific scope if needed.

- [x] **Step 5: Add a metadata-focused presentation test**

  Add this test to `swift-tui/Tests/SwiftTUITests/PresentationSurfaceTests.swift`:

  ```swift
  @Test("presentation overlays carry explicit surface composition metadata")
  func presentationOverlaysCarrySurfaceCompositionMetadata() throws {
    let artifacts = DefaultRenderer().render(
      Text("Workspace")
        .sheet("Command palette", isPresented: .constant(true)) {
          Text("Filter commands")
        },
      context: .init(identity: testIdentity("SurfaceCompositionRoot")),
      proposal: .init(width: 40, height: 10)
    )

    let entries = SurfaceTopologySignature(placedRoot: artifacts.placedTree).entries
    #expect(entries.contains { $0.role == .detachedOverlayRoot })
    #expect(entries.contains { $0.role == .stackingContext })
    #expect(entries.contains { $0.role == .detachedOverlayEntry })
    #expect(entries.contains { $0.stableKey?.contains("SheetPresentation") == true })
  }
  ```

  If `entry.id` does not include the family name in current code, assert the
  role only and add a second assertion that `stableKey` is non-empty:

  ```swift
  #expect(entries.contains { $0.role == .detachedOverlayEntry && $0.stableKey?.isEmpty == false })
  ```

- [x] **Step 6: Run the focused presentation tests**

  ```bash
  swiftly run swift test --package-path swift-tui --filter SwiftTUITests.PresentationSurfaceTests
  ```

  Expected: PASS.

- [x] **Step 7: Commit**

  ```bash
  git -C swift-tui add Sources/SwiftTUIViews/Presentation/PresentationCoordinator.swift \
    Sources/SwiftTUIViews/Presentation/OverlayStack.swift \
    Sources/SwiftTUIViews/Modifiers/ViewMetadataModifiers.swift \
    Tests/SwiftTUITests/PresentationSurfaceTests.swift
  git -C swift-tui commit -m "feat: mark shared surface composition boundaries"
  ```

---

### Task 3: Split Raster Reuse Hints From Host-Facing Raster Damage

**Files:**
- Modify: `swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailModels.swift`
- Modify: `swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailRetainedState.swift`
- Modify: `swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailPresentationDamage.swift`
- Modify: `swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailRenderer+InlineStages.swift`
- Modify: `swift-tui/Sources/SwiftTUICore/Commit/FrameArtifacts.swift`

- [x] **Step 1: Carry previous topology into frame-tail input**

  In `FrameTailRetainedInput`, add:

  ```swift
  var previousSurfaceTopology: SurfaceTopologySignature?
  ```

  In `FrameTailRetainedState.State`, add:

  ```swift
  var previousSurfaceTopology: SurfaceTopologySignature?
  ```

  In `FrameTailRetainedState.input(invalidatedIdentities:)`, populate the new
  field from state.

  In `FrameTailRetainedState.storeCommittedFrame(_:baselinePlacedTree:)`, store
  the topology from the effective visual placed tree:

  ```swift
  state.previousSurfaceTopology = SurfaceTopologySignature(
    placedRoot: artifacts.placedTree
  )
  ```

  Keep `previousFrameIndex` based on `baselinePlacedTree`; retained layout still
  needs the canonical layout baseline.

- [x] **Step 2: Rename the resolver role in code comments and model**

  Keep the file name for a small diff, but change the internal comments in
  `FrameTailPresentationDamage.swift` to say that the resolver computes a
  private raster reuse hint, not the host-facing presentation damage contract.

  Add this model near the resolver:

  ```swift
  struct FrameTailRasterReusePlan: Sendable {
    var damage: PresentationDamage?
    var barriers: Set<FrameTailRasterReuseBarrier>
  }

  enum FrameTailRasterReuseBarrier: Hashable, Sendable {
    case missingRetainedFrame
    case rootInvalidated
    case emptyInvalidation
    case unresolvedInvalidatedIdentity
    case unstableCleanSiblingBounds
    case surfaceTopologyChanged
  }
  ```

- [x] **Step 3: Make topology changes block pre-raster reuse**

  Change the resolver signature to:

  ```swift
  static func resolve(
    rootIdentity: Identity,
    placed: PlacedNode,
    retainedLayout: RetainedLayoutSession?,
    previousSurfaceTopology: SurfaceTopologySignature?
  ) -> FrameTailRasterReusePlan
  ```

  At the top of the resolver, compute current topology and reject reuse when it
  changed:

  ```swift
  let currentSurfaceTopology = SurfaceTopologySignature(placedRoot: placed)
  if currentSurfaceTopology.differs(from: previousSurfaceTopology) {
    return .init(damage: nil, barriers: [.surfaceTopologyChanged])
  }
  ```

  Convert each existing `return nil` into a plan with the matching barrier. The
  existing successful case returns:

  ```swift
  return .init(
    damage: PresentationDamage(
      textRows: textRowRanges.keys.sorted().map { row in
        .init(row: row, columnRanges: textRowRanges[row] ?? [])
      }
    ),
    barriers: []
  )
  ```

- [x] **Step 4: Derive artifact damage only after rasterization**

  In `FrameTailRenderer+InlineStages.swift`, replace:

  ```swift
  let presentationDamage = FrameTailPresentationDamageResolver.resolve(...)
  ```

  with:

  ```swift
  let rasterReusePlan = FrameTailPresentationDamageResolver.resolve(
    rootIdentity: input.rootIdentity,
    placed: placed,
    retainedLayout: input.retained.retainedLayout,
    previousSurfaceTopology: input.retained.previousSurfaceTopology
  )
  ```

  Pass `rasterReusePlan.damage` into `rasterizeDrawTree(...)`.

  In `rasterizeDrawTree(...)`, ignore `rasterized.presentationDamage` for the
  artifact-level damage and always compute it from the actual renderer surfaces:

  ```swift
  let finalPresentationDamage = RasterSurfaceDamageDiff.diff(
    previous: previousSurface,
    current: rasterized.surface
  )
  ```

  The rasterizer may still use `rasterReusePlan.damage` internally to avoid
  repainting rows. It does not get to define the artifact or frontend damage
  contracts.

- [x] **Step 5: Update artifact documentation**

  In `FrameArtifacts.swift`, replace the `presentationDamage` doc with:

  ```swift
  /// Optional artifact-level raster damage for this renderer commit.
  ///
  /// A non-`nil` value must describe the actual changed raster rows/ranges
  /// between the previous renderer-committed `RasterSurface` and this frame's
  /// `rasterSurface`. A `nil` value means the previous renderer surface is
  /// incompatible or unavailable. Runtime presentation code re-derives
  /// host-facing damage from the previous actually presented surface so skipped
  /// async artifacts cannot leak retained renderer history to frontends.
  /// Private retained-layout reuse hints must not be exposed through this field
  /// unless they have been proven to cover the actual renderer-surface diff.
  public var presentationDamage: PresentationDamage?
  ```

- [x] **Step 6: Run the focused pipeline tests**

  ```bash
  swiftly run swift test --package-path swift-tui --filter SwiftTUITests.PipelineContractTests
  swiftly run swift test --package-path swift-tui --filter SwiftTUICoreTests.RasterSurfaceDamageDiffTests
  ```

  Expected: PASS. If `RasterSurfaceDamageDiffTests` is not part of the current
  target name, run the exact target that owns
  `swift-tui/Tests/SwiftTUICoreTests/RasterSurfaceDamageDiffTests.swift`.

- [x] **Step 7: Commit**

  ```bash
  git -C swift-tui add Sources/SwiftTUIRuntime/Rendering/FrameTailModels.swift \
    Sources/SwiftTUIRuntime/Rendering/FrameTailRetainedState.swift \
    Sources/SwiftTUIRuntime/Rendering/FrameTailPresentationDamage.swift \
    Sources/SwiftTUIRuntime/Rendering/FrameTailRenderer+InlineStages.swift \
    Sources/SwiftTUICore/Commit/FrameArtifacts.swift
  git -C swift-tui commit -m "fix: derive host damage from actual raster surfaces"
  ```

---

### Task 4: Add Contract Tests For Overlay Open And Dismiss

**Files:**
- Create: `swift-tui/Tests/SwiftTUITests/SurfaceDamageContractTests.swift`
- Modify: `swift-tui/Tests/SwiftTUITests/PipelineContractTests.swift`

- [x] **Step 1: Create a coverage helper**

  Create `SurfaceDamageContractTests.swift` with this helper:

  ```swift
  import Testing

  @testable import SwiftTUICore
  @testable import SwiftTUIRuntime
  @testable import SwiftTUIViews

  @MainActor
  @Suite
  struct SurfaceDamageContractTests {
    @Test("sheet open and dismiss damage covers actual raster diffs")
    func sheetOpenAndDismissDamageCoversActualRasterDiffs() throws {
      let renderer = DefaultRenderer()
      let rootIdentity = testIdentity("SurfaceDamageSheetRoot")
      let proposal = ProposedSize(width: 48, height: 12)

      let closed = renderer.render(
        SurfaceDamageSheetFixture(isPresented: false, count: 1),
        context: .init(identity: rootIdentity),
        proposal: proposal
      )
      let opened = renderer.render(
        SurfaceDamageSheetFixture(isPresented: true, count: 1),
        context: .init(identity: rootIdentity),
        proposal: proposal
      )
      let dismissed = renderer.render(
        SurfaceDamageSheetFixture(isPresented: false, count: 1),
        context: .init(identity: rootIdentity),
        proposal: proposal
      )

      #expect(opened.rasterSurface.lines.joined(separator: "\n").contains("Command palette"))
      #expect(!dismissed.rasterSurface.lines.joined(separator: "\n").contains("Command palette"))

      assertDamageEqualsActualDiff(
        previous: closed.rasterSurface,
        current: opened.rasterSurface,
        damage: opened.presentationDamage
      )
      assertDamageEqualsActualDiff(
        previous: opened.rasterSurface,
        current: dismissed.rasterSurface,
        damage: dismissed.presentationDamage
      )
    }

    @Test("ordinary text update keeps narrow actual damage")
    func ordinaryTextUpdateKeepsNarrowActualDamage() {
      let renderer = DefaultRenderer()
      let rootIdentity = testIdentity("SurfaceDamageTextRoot")
      let proposal = ProposedSize(width: 32, height: 4)

      let first = renderer.render(
        SurfaceDamageTextFixture(count: 1),
        context: .init(identity: rootIdentity),
        proposal: proposal
      )
      let second = renderer.render(
        SurfaceDamageTextFixture(count: 2),
        context: .init(identity: rootIdentity),
        proposal: proposal
      )

      assertDamageEqualsActualDiff(
        previous: first.rasterSurface,
        current: second.rasterSurface,
        damage: second.presentationDamage
      )
      let diagnostics = second.presentationDamage.map {
        PresentationDamageDiagnostics(
          damage: $0,
          surfaceWidth: second.rasterSurface.size.width
        )
      }
      #expect((diagnostics?.textCellCount ?? Int.max) < 10)
    }
  }

  private struct SurfaceDamageSheetFixture: View {
    var isPresented: Bool
    var count: Int

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        Text("Base \(count)")
        Text("Content behind overlay")
      }
      .sheet("Command palette", isPresented: .constant(isPresented)) {
        VStack(alignment: .leading, spacing: 0) {
          Text("Command palette")
          Text("Filter commands")
          Text("Counter")
          Text("Life")
        }
      }
    }
  }

  private struct SurfaceDamageTextFixture: View {
    var count: Int

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        Text("Count \(count)")
        Text("Stable")
      }
    }
  }

  private func assertDamageEqualsActualDiff(
    previous: RasterSurface,
    current: RasterSurface,
    damage: PresentationDamage?,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let expected = RasterSurfaceDamageDiff.diff(previous: previous, current: current)
    #expect(
      damage == expected,
      "expected host damage to equal actual raster diff",
      sourceLocation: sourceLocation
    )
  }
  ```

- [x] **Step 2: Verify the test fails before Task 3 and passes after Task 3**

  ```bash
  swiftly run swift test --package-path swift-tui --filter SwiftTUITests.SurfaceDamageContractTests
  ```

  Expected before Task 3: FAIL if retained-layout damage escapes as artifact
  damage. Expected after Task 3: PASS.

- [x] **Step 3: Strengthen the existing broad update contract**

  In `PipelineContractTests.rendererDerivesRasterDamageForBroadStateUpdates`,
  capture the first frame and assert equality with the actual diff:

  ```swift
  let initial = renderer.render(
    PipelineContractCommandView(value: 1),
    context: .init(identity: rootIdentity),
    proposal: proposal
  )
  let updated = renderer.render(
    PipelineContractCommandView(value: 2),
    context: .init(identity: rootIdentity),
    proposal: proposal
  )

  #expect(
    updated.presentationDamage
      == RasterSurfaceDamageDiff.diff(
        previous: initial.rasterSurface,
        current: updated.rasterSurface
      )
  )
  ```

- [x] **Step 4: Run focused tests**

  ```bash
  swiftly run swift test --package-path swift-tui --filter SwiftTUITests.SurfaceDamageContractTests
  swiftly run swift test --package-path swift-tui --filter SwiftTUITests.PipelineContractTests
  ```

  Expected: PASS.

- [x] **Step 5: Commit**

  ```bash
  git -C swift-tui add Tests/SwiftTUITests/SurfaceDamageContractTests.swift \
    Tests/SwiftTUITests/PipelineContractTests.swift
  git -C swift-tui commit -m "test: lock host-facing surface damage contract"
  ```

---

### Task 5: Add Default Async Gallery Regression Coverage

**Files:**
- Modify: `swift-tui-examples/gallery/Tests/GalleryDemoViewsTests/GalleryTabSwitchTests.swift`

- [x] **Step 1: Add a damage-aware gallery host**

  Add this host near `GalleryTabSwitchRecordingHost`:

  ```swift
  private final class GalleryDamageValidatingHost: PresentationSurface, DamageAwarePresentationSurface {
    let surfaceSize: CellSize
    let capabilityProfile: TerminalCapabilityProfile = .previewUnicode
    let appearance: TerminalAppearance = .fallback
    let stageClock = ManualStageClock()
    private(set) var surfaces: [RasterSurface] = []
    private(set) var damages: [PresentationDamage?] = []
    private(set) var lastPresentedSurface: RasterSurface?
    private var previousSurface: RasterSurface?
    let frameSignal = MainActorConditionSignal()

    init(size: CellSize) {
      surfaceSize = size
    }

    func enableRawMode() throws {}
    func disableRawMode() throws {}
    func write(_: String) throws {}
    func clearScreen() throws {}
    func moveCursor(to _: CellPoint) throws {}

    @discardableResult
    func present(_ surface: RasterSurface) throws -> TerminalPresentationMetrics {
      try present(surface, damage: nil)
    }

    @discardableResult
    func present(
      _ surface: RasterSurface,
      damage: PresentationDamage?
    ) throws -> TerminalPresentationMetrics {
      if let previousSurface {
        let expected = RasterSurfaceDamageDiff.diff(
          previous: previousSurface,
          current: surface
        )
        if damage != expected {
          Issue.record(
            "host-facing damage did not equal actual raster diff; expected \(String(describing: expected)), got \(String(describing: damage))"
          )
        }
      }

      previousSurface = surface
      surfaces.append(surface)
      damages.append(damage)
      lastPresentedSurface = surface
      stageClock.advance()
      let frameSignal = self.frameSignal
      MainActor.assumeIsolated {
        frameSignal.notify()
      }
      return TerminalPresentationMetrics.rasterHostMetrics(
        for: surface,
        damage: damage
      )
    }
  }
  ```

- [x] **Step 2: Add the default async palette open/dismiss test**

  Add this test to `GalleryTabSwitchTests`:

  ```swift
  @Test("default async palette open and dismiss publish valid shared raster damage")
  func defaultAsyncPaletteOpenAndDismissPublishValidSharedRasterDamage() async throws {
    let terminalSize = CellSize(width: 80, height: 24)
    let rootIdentity = Identity(components: [.named("GalleryPaletteDamageContract")])
    let view = GallerySelectionSeedHarness(initialSelection: .counter)
    let host = GalleryDamageValidatingHost(size: terminalSize)

    let result = try await Self.runHarness(
      presentationSurface: host,
      terminalInputReader: GalleryTabSwitchAwaitedInputReader(
        frameSignal: host.frameSignal,
        stageClock: host.stageClock,
        steps: [
          .awaitCondition {
            host.lastPresentedSurface?.lines.joined(separator: "\n").contains("Counter") == true
          },
          .event(.key(KeyPress(.character("k"), modifiers: .ctrl))),
          .awaitCondition {
            host.lastPresentedSurface?.lines.joined(separator: "\n").contains("Command palette")
              == true
          },
          .event(.key(KeyPress(.escape, modifiers: []))),
          .awaitCondition {
            guard let text = host.lastPresentedSurface?.lines.joined(separator: "\n") else {
              return false
            }
            return !text.contains("Command palette") && !text.contains("Filter commands")
          },
          .event(.key(KeyPress(.character("d"), modifiers: .ctrl))),
        ]),
      terminalSize: terminalSize,
      rootIdentity: rootIdentity,
      viewBuilder: { view }
    )

    #expect(result.exitReason == .userExit(KeyPress(.character("d"), modifiers: .ctrl)))
    #expect(host.surfaces.contains { $0.lines.joined(separator: "\n").contains("Command palette") })
    #expect(host.surfaces.last?.lines.joined(separator: "\n").contains("Command palette") == false)
    #expect(host.damages.contains { damage in
      guard let damage else {
        return true
      }
      return damage.textRows.count > 1
    })
  }
  ```

  This test intentionally validates the shared damage value through
  `DamageAwarePresentationSurface`; it does not inspect terminal escape output.

  If this test fails while lower-level artifact tests pass, check whether the
  run loop is forwarding renderer artifact damage that is relative to an
  intermediate renderer-committed surface the host never received. The
  host-facing value must be re-derived at the presentation boundary from the
  previous actually presented raster surface.

- [x] **Step 3: Run the gallery focused test**

  ```bash
  swiftly run swift test --package-path swift-tui-examples/gallery --filter GalleryDemoViewsTests.GalleryTabSwitchTests/defaultAsyncPaletteOpenAndDismissPublishValidSharedRasterDamage
  ```

  Expected: PASS after Task 3. Before Task 3, this should record a damage
  mismatch or show a one-row/three-cell damage frame for palette open.

- [x] **Step 4: Commit**

  ```bash
  git -C swift-tui-examples add gallery/Tests/GalleryDemoViewsTests/GalleryTabSwitchTests.swift
  git -C swift-tui-examples commit -m "test: validate gallery palette raster damage contract"
  ```

---

### Task 6: Keep Web Canvas And Hosted Surfaces On The Same Contract

**Files:**
- Modify: `swift-tui-web/packages/web/src/WebHostSceneRuntime.test.ts`
- Modify: `swift-tui/Tests/SwiftTUITests/HostedSceneSessionTests.swift`

- [x] **Step 1: Add a web dirty-rect removal regression**

  In `WebHostSceneRuntime.test.ts`, add a test that sends:

  1. a base frame with `rows` containing `"Base content"`;
  2. an overlay frame with `"Command palette"` and a damage rectangle covering
     the overlay rows;
  3. a dismissed frame without `"Command palette"` and a damage rectangle
     covering the old overlay rows.

  Use the existing `surfaceRecord(...)` helper in that file and assert that the
  canvas text samples no longer include the overlay text after frame 3.

  The test body should follow the existing `"runtime redraws only damaged cells
  when a compatible frame includes damage"` pattern and use this final
  assertion:

  ```ts
  expect(readCanvasTextLikePixels(canvas)).not.toContain("Command palette");
  ```

  If the file does not already expose a text-like canvas sampling helper, add a
  small test-local helper that checks painted cell positions for the characters
  used by the fixture rows. Do not add production web runtime logic.

- [x] **Step 2: Add a hosted surface damage equality regression**

  In `HostedSceneSessionTests.swift`, add a test that waits for two hosted
  frames from a small state-changing view and asserts:

  ```swift
  #expect(
    second.rasterDamage
      == RasterSurfaceDamageDiff.diff(
        previous: first.raster,
        current: second.raster
      )
  )
  ```

  Use the existing `HostedRasterSurface.waitForFrames(matching:)` helper so the
  test observes `SemanticHostFrame.rasterDamage`, not just `RasterSurface`.

- [x] **Step 3: Run focused consumer tests**

  ```bash
  bun --cwd swift-tui-web test packages/web/src/WebHostSceneRuntime.test.ts
  swiftly run swift test --package-path swift-tui --filter SwiftTUITests.HostedSceneSessionTests
  ```

  Expected: PASS.

- [x] **Step 4: Commit**

  ```bash
  git -C swift-tui-web add packages/web/src/WebHostSceneRuntime.test.ts
  git -C swift-tui-web commit -m "test: keep web dirty rects aligned with shared damage"

  git -C swift-tui add Tests/SwiftTUITests/HostedSceneSessionTests.swift
  git -C swift-tui commit -m "test: validate hosted raster damage frames"
  ```

---

### Task 7: Update Docs And Run The Gate

**Files:**
- Modify: `swift-tui/docs/RENDER-PIPELINE.md`
- Modify: `swift-tui/docs/HOSTS-AND-PLATFORMS.md`

- [x] **Step 1: Document the damage split**

  In `swift-tui/docs/RENDER-PIPELINE.md`, add a section named
  `Host-Facing Raster Damage`:

  ```markdown
  ## Host-Facing Raster Damage

  The renderer has two damage boundaries:

  - **Raster reuse hints** are private frame-tail inputs. They may let the
    rasterizer reuse rows from the previous renderer-committed `RasterSurface`
    while repainting a subset of rows. They are not frontend damage.
  - **Host-facing raster damage** is the public presentation contract. It is
    derived from the previous `RasterSurface` actually presented to that
    frontend and the current committed `RasterSurface` after rasterization.

  Renderer artifacts may also carry `FrameArtifacts.presentationDamage`. That
  value is relative to renderer-committed raster history, so `RunLoop`
  re-derives host-facing damage before presentation. Skipped or cancelled async
  artifacts therefore cannot leak stale retained renderer history to terminal,
  web, or host-managed frontends.

  Damage-aware presentation surfaces, web-surface/WebHost canvas rendering, and
  hosted raster surfaces consume host-facing raster damage. JSON frame output
  uses `JSONFrameRenderer` and does not carry `PresentationDamage`. A non-`nil`
  damage value must cover every changed cell between the two committed raster
  surfaces. `nil` means the previous surface is unavailable or incompatible and
  consumers must repaint the full surface.

  Detached overlays, presentation portals, and isolated compositing groups mark
  shared `SurfaceCompositionMetadata`. When their topology changes, retained
  raster reuse is suppressed and host-facing damage is still derived from the
  actual raster diff.
  ```

- [x] **Step 2: Document frontend consumption**

  In `swift-tui/docs/HOSTS-AND-PLATFORMS.md`, add:

  ```markdown
  ### Shared Raster Damage Contract

  All raster frontends consume the same damage contract:
  `RasterSurface` plus optional `PresentationDamage`.

  - `nil` damage means full repaint.
  - non-`nil` empty damage means no visible raster cells changed.
  - non-`nil` row/range damage is relative to the previous `RasterSurface`
    actually presented by the same runtime/frontend pair.

  `RunLoop` derives this host-facing value from the frontend's presented raster
  history instead of forwarding private retained-layout invalidation or stale
  renderer artifact damage. Terminal, WASI/browser, localhost WebHost, and
  host-managed SwiftUI paths must not reinterpret retained-layout invalidation as
  frontend damage. If stale cells appear after this contract is satisfied, the
  bug belongs to that frontend's damage consumer.
  ```

- [x] **Step 3: Run focused checks**

  ```bash
  swiftly run swift test --package-path swift-tui --filter SwiftTUITests.SurfaceDamageContractTests
  swiftly run swift test --package-path swift-tui --filter SwiftTUITests.PipelineContractTests
  swiftly run swift test --package-path swift-tui --filter SwiftTUITests.PresentationSurfaceTests
  swiftly run swift test --package-path swift-tui-examples/gallery --filter GalleryDemoViewsTests.GalleryTabSwitchTests/defaultAsyncPaletteOpenAndDismissPublishValidSharedRasterDamage
  bun --cwd swift-tui-web test packages/web/src/WebHostSceneRuntime.test.ts
  ```

  Expected: PASS.

- [x] **Step 4: Run the org-level fast gate**

  From the org root:

  ```bash
  mise exec -- bazel test //:org_fast
  ```

  Expected: PASS. If this fails because a child submodule has unrelated dirty
  or stale build state, record the failing target and run the focused command
  above for the touched child repo before changing more code.

- [x] **Step 5: Commit docs and submodule pins**

  ```bash
  git -C swift-tui add docs/RENDER-PIPELINE.md docs/HOSTS-AND-PLATFORMS.md
  git -C swift-tui commit -m "docs: define shared raster damage contract"

  git add swift-tui swift-tui-examples swift-tui-web
  git commit -m "chore: pin shared surface damage contract fix"
  ```

---

## Acceptance Criteria

- The gallery command palette renders immediately on `Ctrl+K` under the default
  async render mode.
- The palette dismisses immediately on `Escape` under the default async render
  mode.
- Dismissing the palette does not leave stale cells or pixels in any raster
  frontend.
- Renderer artifact damage equals `RasterSurfaceDamageDiff.diff` against
  renderer-committed raster history whenever previous/current surfaces are
  compatible.
- Frontend-facing damage equals `RasterSurfaceDamageDiff.diff` against the
  previous raster surface actually presented to that frontend whenever
  previous/current surfaces are compatible.
- Presentation, menu, popover, toast, sheet, alert, transition, and
  compositing-group topology changes are represented through shared core
  metadata, not damage resolver string matching.
- TerminalHost has no product-code changes for this fix.
- Web canvas and hosted raster tests validate the same shared damage contract.
