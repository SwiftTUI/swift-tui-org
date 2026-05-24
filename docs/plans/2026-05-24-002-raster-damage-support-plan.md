# Raster Damage Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce accurate raster damage for committed frames and consume it in
each presentation path: terminal-native, WASI/browser, localhost WebHost, and
host-managed SwiftUI.

**Architecture:** Keep the existing retained-layout damage resolver as an
optional pre-raster optimization for incremental rasterization. Add a
post-raster `RasterSurface` diff that derives host-facing damage from the
previous committed raster surface and the current raster surface, so root state
changes and task-driven updates still produce row/range damage even when
identity-level invalidation is too broad.

**Tech Stack:** SwiftTUICore, SwiftTUIRuntime, SwiftTUIWASI, SwiftTUIWebHost,
SwiftUIHost, Swift Testing, TypeScript, Bun test, Playwright.

---

## Current Evidence

- `PresentationDamage`, `SemanticHostFrame.rasterDamage`, web-surface encoding,
  WebHost decoding, browser dirty rect drawing, terminal planning, and SwiftUI
  dirty rect invalidation already exist.
- The missing piece is that real Game of Life frames often reach presentation
  with `rasterDamage == nil`; the browser then clears and redraws the full
  canvas. The native WebHost path tolerates this better because the producer
  cadence is faster, but the static WASI path exposes the cost.
- A sound post-raster diff can reduce host presentation work without relying on
  retained layout proofs. It does not need to reduce Swift rasterization work in
  the first pass.

## File Structure To Create Or Modify

- Create `swift-tui/Sources/SwiftTUICore/Raster/RasterSurfaceDamageDiff.swift`:
  diff previous/current raster surfaces into `PresentationDamage`.
- Create `swift-tui/Tests/SwiftTUICoreTests/RasterSurfaceDamageDiffTests.swift`:
  unit coverage for text, styles, wide glyphs, no-op frames, size changes, and
  image attachment bounds.
- Modify `swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailRenderer+InlineStages.swift`:
  derive final host-facing damage after rasterization.
- Modify `swift-tui/Tests/SwiftTUITests/PipelineContractTests.swift`: prove real
  renderer frames carry damage for broad/root state updates.
- Modify `swift-tui/Platforms/WASI/Tests/WASISurfaceBridgeTests/WebSurfaceTransportTests.swift`:
  prove WASI semantic host-frame presentation emits real damage and incremental
  metrics.
- Modify `swift-tui/Platforms/WebHost/Tests/SwiftTUIWebHostTests/WebSocketSurfaceTransportTests.swift`:
  keep localhost WebHost damage coverage aligned with WASI.
- Modify `swift-tui-web/packages/web/src/WebHostSceneRuntime.test.ts`: cover
  empty damage and image-removal dirty rows in the browser canvas renderer.
- Create `swift-tui-examples/Examples/WebExample/src/raster-damage.browser.ts`:
  browser integration proof that real WebExample frames carry damage.
- Modify `swift-tui-examples/Examples/WebExample/package.json`: include the new
  browser damage test in `test:browser`.
- Modify `swift-tui/Platforms/SwiftUI/Tests/SwiftUIHostTests/HostedSurfaceRegressionTests.swift`:
  prove host-managed SwiftUI receives non-nil damage through
  `HostedRasterSurface`.
- Modify `swift-tui/docs/RENDER-PIPELINE.md`: record post-raster damage as the
  host-facing fallback when retained-layout damage is unavailable.
- Modify `swift-tui/docs/HOSTS-AND-PLATFORMS.md`: record how the four raster
  hosts consume damage.

---

### Task 1: Add A Core Raster Surface Damage Diff

**Files:**
- Create: `swift-tui/Sources/SwiftTUICore/Raster/RasterSurfaceDamageDiff.swift`
- Create: `swift-tui/Tests/SwiftTUICoreTests/RasterSurfaceDamageDiffTests.swift`

- [ ] **Step 1: Write failing core diff tests**

  Create `RasterSurfaceDamageDiffTests.swift`:

  ```swift
  import Testing

  @testable import SwiftTUICore

  @Suite
  struct RasterSurfaceDamageDiffTests {
    @Test("diff returns nil when there is no previous surface")
    func diffReturnsNilWithoutPreviousSurface() {
      let current = RasterSurface(size: .init(width: 4, height: 1), lines: ["ABCD"])

      #expect(RasterSurfaceDamageDiff.diff(previous: nil, current: current) == nil)
    }

    @Test("diff returns empty damage when compatible surfaces are visually equal")
    func diffReturnsEmptyDamageForEqualSurfaces() {
      let surface = RasterSurface(size: .init(width: 4, height: 1), lines: ["ABCD"])

      #expect(
        RasterSurfaceDamageDiff.diff(previous: surface, current: surface)
          == PresentationDamage(textRows: [])
      )
    }

    @Test("diff coalesces adjacent changed cells into row ranges")
    func diffCoalescesAdjacentChangedCells() {
      let previous = RasterSurface(size: .init(width: 6, height: 2), lines: ["ABCDEF", "stable"])
      let current = RasterSurface(size: .init(width: 6, height: 2), lines: ["ABxyEF", "stable"])

      #expect(
        RasterSurfaceDamageDiff.diff(previous: previous, current: current)
          == PresentationDamage(textRows: [
            .init(row: 0, columnRanges: [2..<4])
          ])
      )
    }

    @Test("diff expands wide glyph changes to the full occupied cell range")
    func diffExpandsWideGlyphChanges() {
      let previous = RasterSurface(size: .init(width: 4, height: 1), lines: ["A界B"])
      let current = RasterSurface(size: .init(width: 4, height: 1), lines: ["A語B"])

      #expect(
        RasterSurfaceDamageDiff.diff(previous: previous, current: current)
          == PresentationDamage(textRows: [
            .init(row: 0, columnRanges: [1..<3])
          ])
      )
    }

    @Test("diff falls back to full repaint when size or metadata changes")
    func diffFallsBackForIncompatibleSurfaces() {
      let previous = RasterSurface(size: .init(width: 4, height: 1), lines: ["ABCD"])
      let resized = RasterSurface(size: .init(width: 5, height: 1), lines: ["ABCDE"])
      let metadataChanged = RasterSurface(
        size: .init(width: 4, height: 1),
        lines: ["ABCD"],
        metadata: ["mode": "alternate"]
      )

      #expect(RasterSurfaceDamageDiff.diff(previous: previous, current: resized) == nil)
      #expect(RasterSurfaceDamageDiff.diff(previous: previous, current: metadataChanged) == nil)
    }

    @Test("diff marks previous and current image rows dirty")
    func diffMarksImageRowsDirty() {
      let identity = Identity(components: ["image"])
      let previous = RasterSurface(
        size: .init(width: 8, height: 4),
        lines: ["", "", "", ""],
        imageAttachments: [
          RasterImageAttachment(
            identity: identity,
            bounds: .init(origin: .init(x: 1, y: 1), size: .init(width: 2, height: 2)),
            source: .path("old.png")
          )
        ]
      )
      let current = RasterSurface(
        size: .init(width: 8, height: 4),
        lines: ["", "", "", ""],
        imageAttachments: [
          RasterImageAttachment(
            identity: identity,
            bounds: .init(origin: .init(x: 4, y: 2), size: .init(width: 2, height: 1)),
            source: .path("new.png")
          )
        ]
      )

      #expect(
        RasterSurfaceDamageDiff.diff(previous: previous, current: current)
          == PresentationDamage(textRows: [
            .init(row: 1, columnRanges: [1..<3]),
            .init(row: 2, columnRanges: [1..<3, 4..<6])
          ])
      )
    }
  }
  ```

- [ ] **Step 2: Run tests and verify they fail**

  ```bash
  swiftly run swift test --filter SwiftTUICoreTests.RasterSurfaceDamageDiffTests
  ```

  Expected: FAIL because `RasterSurfaceDamageDiff` does not exist.

- [ ] **Step 3: Implement `RasterSurfaceDamageDiff`**

  Create `RasterSurfaceDamageDiff.swift`:

  ```swift
  package enum RasterSurfaceDamageDiff {
    package static func diff(
      previous: RasterSurface?,
      current: RasterSurface
    ) -> PresentationDamage? {
      guard let previous else {
        return nil
      }
      guard previous.size == current.size,
        previous.attachments == current.attachments,
        previous.metadata == current.metadata
      else {
        return nil
      }

      var rowRanges: [Int: [Range<Int>]] = [:]
      appendCellDiffs(previous: previous, current: current, to: &rowRanges)
      appendImageDiffs(previous: previous, current: current, to: &rowRanges)

      return PresentationDamage(
        textRows: rowRanges.keys.sorted().map { row in
          PresentationDamage.TextRow(
            row: row,
            columnRanges: rowRanges[row] ?? []
          )
        }
      )
    }

    private static func appendCellDiffs(
      previous: RasterSurface,
      current: RasterSurface,
      to rowRanges: inout [Int: [Range<Int>]]
    ) {
      for row in 0..<current.size.height {
        let previousRow = row < previous.cells.count ? previous.cells[row] : []
        let currentRow = row < current.cells.count ? current.cells[row] : []
        let width = max(previous.size.width, current.size.width, previousRow.count, currentRow.count)
        var ranges: [Range<Int>] = []

        for column in 0..<width {
          let previousCell = cell(in: previousRow, at: column)
          let currentCell = cell(in: currentRow, at: column)
          guard previousCell != currentCell else {
            continue
          }
          ranges.append(occupiedRange(in: previousRow, at: column, surfaceWidth: width))
          ranges.append(occupiedRange(in: currentRow, at: column, surfaceWidth: width))
        }

        if !ranges.isEmpty {
          rowRanges[row, default: []].append(contentsOf: ranges)
        }
      }
    }

    private static func appendImageDiffs(
      previous: RasterSurface,
      current: RasterSurface,
      to rowRanges: inout [Int: [Range<Int>]]
    ) {
      guard previous.imageAttachments != current.imageAttachments else {
        return
      }
      for attachment in previous.imageAttachments + current.imageAttachments {
        append(rect: attachment.visibleBounds, to: &rowRanges)
      }
    }

    private static func append(
      rect: CellRect,
      to rowRanges: inout [Int: [Range<Int>]]
    ) {
      guard rect.size.width > 0, rect.size.height > 0 else {
        return
      }
      let lowerRow = max(0, rect.origin.y)
      let upperRow = max(lowerRow, rect.origin.y + rect.size.height)
      let lowerColumn = max(0, rect.origin.x)
      let upperColumn = max(lowerColumn, rect.origin.x + rect.size.width)
      guard lowerColumn < upperColumn else {
        return
      }
      for row in lowerRow..<upperRow {
        rowRanges[row, default: []].append(lowerColumn..<upperColumn)
      }
    }

    private static func cell(
      in row: [RasterCell],
      at column: Int
    ) -> RasterCell {
      guard column >= 0, column < row.count else {
        return .empty
      }
      return row[column]
    }

    private static func occupiedRange(
      in row: [RasterCell],
      at column: Int,
      surfaceWidth: Int
    ) -> Range<Int> {
      guard column >= 0, column < row.count else {
        return column..<min(surfaceWidth, column + 1)
      }
      let cell = row[column]
      let lead = cell.continuationLeadX ?? column
      let span = max(1, cell(in: row, at: lead).spanWidth)
      return max(0, lead)..<min(surfaceWidth, lead + span)
    }
  }
  ```

- [ ] **Step 4: Verify core diff tests pass**

  ```bash
  swiftly run swift test --filter SwiftTUICoreTests.RasterSurfaceDamageDiffTests
  ```

  Expected: PASS.

- [ ] **Step 5: Commit the core diff**

  ```bash
  git add Sources/SwiftTUICore/Raster/RasterSurfaceDamageDiff.swift Tests/SwiftTUICoreTests/RasterSurfaceDamageDiffTests.swift
  git commit -m "feat: diff raster surfaces for presentation damage"
  ```

### Task 2: Feed Post-Raster Damage Into Frame Artifacts

**Files:**
- Modify: `swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailRenderer+InlineStages.swift`
- Modify: `swift-tui/Tests/SwiftTUITests/PipelineContractTests.swift`

- [ ] **Step 1: Add a failing renderer contract test**

  Add this test to `PipelineContractTests`:

  ```swift
  @Test("renderer derives raster damage for broad state updates")
  func rendererDerivesRasterDamageForBroadStateUpdates() {
    let renderer = DefaultRenderer()
    let rootIdentity = testIdentity("PipelineContractRasterDamageRoot")
    let proposal = ProposedSize(width: 24, height: 3)

    _ = renderer.render(
      PipelineContractCommandView(value: 1),
      context: .init(identity: rootIdentity),
      proposal: proposal
    )
    let updated = renderer.render(
      PipelineContractCommandView(value: 2),
      context: .init(identity: rootIdentity),
      proposal: proposal
    )

    let damage = updated.presentationDamage
    #expect(damage != nil)
    #expect(damage?.requiresFullTextRepaint == false)
    #expect(damage?.requiresFullGraphicsReplay == false)
    #expect(damage?.textRows.isEmpty == false)

    let diagnostics = damage.map {
      PresentationDamageDiagnostics(
        damage: $0,
        surfaceWidth: updated.rasterSurface.size.width
      )
    }
    #expect((diagnostics?.textCellCount ?? 0) < updated.rasterSurface.size.width * updated.rasterSurface.size.height)
  }
  ```

- [ ] **Step 2: Run the renderer contract test and verify it fails**

  ```bash
  swiftly run swift test --filter SwiftTUITests.PipelineContractTests/rendererDerivesRasterDamageForBroadStateUpdates
  ```

  Expected: FAIL because broad state updates can still produce `nil`
  presentation damage.

- [ ] **Step 3: Compute final damage after rasterization**

  In `FrameTailRenderer+InlineStages.swift`, update `rasterizeDrawTree(...)` so
  the rasterizer can still use retained-layout damage for incremental
  rasterization, but the final host-facing damage falls back to the raster diff:

  ```swift
  let previousSurface = input.retained.previousRasterSurface
  let (rasterized, duration) = measurePhase(clock: clock) {
    rasterizer.rasterizeCollectingVisibleIdentities(
      draw,
      minimumSize: minimumRasterSurfaceSize(for: input.proposal),
      previousSurface: previousSurface,
      damage: presentationDamage
    )
  }
  let finalPresentationDamage =
    rasterized.presentationDamage
    ?? RasterSurfaceDamageDiff.diff(
      previous: previousSurface,
      current: rasterized.surface
    )
  return .init(
    surface: rasterized.surface,
    drawnIdentities: rasterized.visibleIdentities,
    presentationDamage: finalPresentationDamage,
    duration: duration
  )
  ```

- [ ] **Step 4: Verify focused Swift tests pass**

  ```bash
  swiftly run swift test --filter SwiftTUICoreTests.RasterSurfaceDamageDiffTests
  swiftly run swift test --filter SwiftTUITests.PipelineContractTests
  ```

  Expected: PASS.

- [ ] **Step 5: Commit runtime wiring**

  ```bash
  git add Sources/SwiftTUIRuntime/Rendering/FrameTailRenderer+InlineStages.swift Tests/SwiftTUITests/PipelineContractTests.swift
  git commit -m "feat: attach raster diff damage to frames"
  ```

### Task 3: Verify Swift Presentation Paths Consume Real Damage

**Files:**
- Modify: `swift-tui/Platforms/WASI/Tests/WASISurfaceBridgeTests/WebSurfaceTransportTests.swift`
- Modify: `swift-tui/Platforms/WebHost/Tests/SwiftTUIWebHostTests/WebSocketSurfaceTransportTests.swift`
- Modify: `swift-tui/Platforms/SwiftUI/Tests/SwiftUIHostTests/HostedSurfaceRegressionTests.swift`
- Modify: `swift-tui/Tests/SwiftTUITests/TerminalPresentationTests.swift`

- [ ] **Step 1: Add WASI semantic frame damage coverage**

  Add a test mirroring the WebHost transport damage test:

  ```swift
  @Test("host semantic present writes damage and incremental metrics")
  func hostSemanticPresentWritesDamageAndIncrementalMetrics() throws {
    let pipe = Pipe()
    let host = WebSurfaceTransport(
      surfaceSize: .init(width: 2, height: 2),
      outputFileDescriptor: pipe.fileHandleForWriting.fileDescriptor,
      renderStyle: .init(appearance: .fallback)
    )
    let damage = PresentationDamage(
      textRows: [.init(row: 1, columnRanges: [0..<1])]
    )

    let metrics = try host.present(
      SemanticHostFrame(
        sequence: 31,
        raster: Self.basicSurface(),
        semantics: .init(),
        focusedIdentity: nil,
        rasterDamage: damage
      )
    )

    pipe.fileHandleForWriting.closeFile()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    pipe.fileHandleForReading.closeFile()
    let frame = try Self.decodedSurfaceFrame(output)
    let decodedDamage = try #require(frame["damage"] as? [String: Any])

    #expect(decodedDamage["requiresFullTextRepaint"] as? Bool == false)
    #expect(metrics.linesTouched == 1)
    #expect(metrics.cellsChanged == 1)
    #expect(metrics.strategy == .incremental)
  }
  ```

- [ ] **Step 2: Add host-managed SwiftUI frame damage coverage**

  In `HostedSurfaceRegressionTests.swift`, add a test that presents two
  compatible frames through `HostedRasterSurface` and waits for the second frame:

  ```swift
  @MainActor
  @Test("hosted raster surface retains semantic frame damage")
  func hostedRasterSurfaceRetainsSemanticFrameDamage() async throws {
    let surface = hostedSurface()
    let damage = PresentationDamage(textRows: [.init(row: 0, columnRanges: [1..<2])])

    try surface.present(
      SemanticHostFrame(
        sequence: 3,
        raster: RasterSurface(size: .init(width: 3, height: 1), lines: ["ABC"]),
        semantics: .init(),
        focusedIdentity: nil,
        rasterDamage: damage
      )
    )

    let frame = await surface.waitForFrame { $0.sequence == 3 }
    #expect(frame.rasterDamage == damage)
  }
  ```

- [ ] **Step 3: Add a terminal planner smoke test for diff-derived empty damage**

  In `TerminalPresentationTests.swift`, add:

  ```swift
  @Test("presentation planner treats empty damage as incremental no-op")
  func presentationPlannerTreatsEmptyDamageAsIncrementalNoOp() {
    let planner = TerminalPresentationPlanner(capabilityProfile: .previewUnicode)
    let surface = RasterSurface(size: .init(width: 4, height: 1), lines: ["same"])

    let plan = planner.plan(
      previousSurface: surface,
      currentSurface: surface,
      damage: PresentationDamage(textRows: [])
    )

    #expect(plan.strategy == .incremental)
    #expect(plan.rowBatches.isEmpty)
    #expect(plan.cellsChanged == 0)
  }
  ```

- [ ] **Step 4: Run focused presentation tests**

  ```bash
  swiftly run swift test --filter WASISurfaceBridgeTests.WebSurfaceTransportTests
  swiftly run swift test --filter SwiftTUIWebHostTests.WebSocketSurfaceTransportTests
  swiftly run swift test --filter SwiftUIHostTests.HostedSurfaceRegressionTests
  swiftly run swift test --filter SwiftTUITests.TerminalPresentationTests
  ```

  Expected: PASS.

- [ ] **Step 5: Commit path coverage**

  ```bash
  git add Platforms/WASI/Tests/WASISurfaceBridgeTests/WebSurfaceTransportTests.swift Platforms/WebHost/Tests/SwiftTUIWebHostTests/WebSocketSurfaceTransportTests.swift Platforms/SwiftUI/Tests/SwiftUIHostTests/HostedSurfaceRegressionTests.swift Tests/SwiftTUITests/TerminalPresentationTests.swift
  git commit -m "test: verify raster damage across presentation hosts"
  ```

### Task 4: Tighten Browser Canvas Damage Behavior

**Files:**
- Modify: `swift-tui-web/packages/web/src/WebHostSceneRuntime.test.ts`

- [ ] **Step 1: Add empty-damage canvas coverage**

  Add a test after the existing damaged-cells test:

  ```ts
  test("runtime skips canvas drawing for compatible empty damage", async () => {
    const dom = installFakeDOM();
    try {
      const bridge = new BrowserWASIBridge({ sceneId: "main", columns: 4, rows: 2 });
      const mount = new FakeElement("div");
      const runtime = new WebHostSceneRuntime({
        mount: mount as unknown as HTMLElement,
        descriptor: { id: "main", title: "Main", isDefault: true },
        style: { fontSize: 20, fontFamily: "Test Mono" },
        bridge,
        onInput: () => {},
      });

      await runtime.mount();
      bridge.stdout.write(encoder.encode(surfaceRecord({
        version: 1,
        width: 4,
        height: 2,
        styles: [null],
        rows: [[[0, "A", 1, 0]], []],
        images: [],
      })));

      const context = dom.canvases[0]!.context;
      context.operations = [];
      bridge.stdout.write(encoder.encode(surfaceRecord({
        version: 1,
        width: 4,
        height: 2,
        styles: [null],
        rows: [[[0, "A", 1, 0]], []],
        images: [],
        damage: {
          textRows: [],
          requiresFullTextRepaint: false,
          requiresFullGraphicsReplay: false,
        },
      })));

      expect(context.operations).toEqual([]);
    } finally {
      dom.restore();
    }
  });
  ```

- [ ] **Step 2: Add image-removal dirty-row coverage**

  Add this test after the empty-damage test:

  ```ts
  test("runtime clears dirty rows when an image disappears", async () => {
    const dom = installFakeDOM({
      createImageBitmap: async () => ({ imageId: "decoded-image" }),
    });
    try {
      const bridge = new BrowserWASIBridge({ sceneId: "main", columns: 4, rows: 2 });
      const mount = new FakeElement("div");
      const runtime = new WebHostSceneRuntime({
        mount: mount as unknown as HTMLElement,
        descriptor: { id: "main", title: "Main", isDefault: true },
        style: { fontSize: 20, fontFamily: "Test Mono" },
        bridge,
        onInput: () => {},
      });

      await runtime.mount();
      bridge.stdout.write(encoder.encode(surfaceRecord({
        version: 1,
        width: 4,
        height: 2,
        styles: [null],
        rows: [
          [[0, "A", 1, 0]],
          [[0, "B", 1, 0]],
        ],
        images: [
          {
            id: "png:test",
            format: "png",
            bounds: [1, 1, 2, 1],
            visibleBounds: [1, 1, 2, 1],
            scalingMode: "stretch",
            dataBase64: "iVBORw==",
          },
        ],
      })));
      await flushPromises();

      const context = dom.canvases[0]!.context;
      context.operations = [];
      bridge.stdout.write(encoder.encode(surfaceRecord({
        version: 1,
        width: 4,
        height: 2,
        styles: [null],
        rows: [
          [[0, "A", 1, 0]],
          [[0, "B", 1, 0]],
        ],
        images: [],
        damage: {
          textRows: [[1, [[1, 3]]]],
          requiresFullTextRepaint: false,
          requiresFullGraphicsReplay: false,
        },
      })));

      expect(context.operations).toContainEqual({
        type: "clearRect",
        x: 10,
        y: 27,
        width: 20,
        height: 27,
      });
      expect(drawImageOperations(context)).toEqual([]);
      expect(fillTextOperations(context, "A")).toEqual([]);
    } finally {
      dom.restore();
    }
  });
  ```

- [ ] **Step 3: Run browser runtime tests**

  ```bash
  bun --cwd swift-tui-web/packages/web test src/WebHostSceneRuntime.test.ts
  ```

  Expected: PASS.

- [ ] **Step 4: Commit browser damage tests**

  ```bash
  git -C swift-tui-web add packages/web/src/WebHostSceneRuntime.test.ts
  git -C swift-tui-web commit -m "test: cover browser raster damage no-op paths"
  ```

### Task 5: Prove The WebExample Sends Damage In The Real Path

**Files:**
- Create: `swift-tui-examples/Examples/WebExample/src/raster-damage.browser.ts`
- Modify: `swift-tui-examples/Examples/WebExample/package.json`

- [ ] **Step 1: Write the real-path damage browser test**

  Create `src/raster-damage.browser.ts`:

  ```ts
  import { expect, test } from "bun:test";
  import { chromium } from "playwright";

  import { serveBuiltWebExample } from "./built-app-server.ts";

  interface FrameSample {
    timestamp: number;
    hasDamage: boolean;
    dirtyRows: number;
  }

  declare global {
    interface Window {
      __swiftTUIDamageSamples?: FrameSample[];
    }
  }

  test("WebExample Game of Life emits raster damage on steady frames", async () => {
    const server = serveBuiltWebExample();
    const browser = await chromium.launch();
    const page = await browser.newPage({
      viewport: {
        width: 1280,
        height: 900,
      },
    });

    await page.addInitScript(() => {
      const originalParse = JSON.parse;
      const samples: FrameSample[] = [];
      Object.defineProperty(window, "__swiftTUIDamageSamples", {
        configurable: true,
        value: samples,
      });
      JSON.parse = function patchedJSONParse(
        text: string,
        reviver?: Parameters<typeof JSON.parse>[1]
      ) {
        const value = originalParse.call(this, text, reviver);
        if (isSurfaceFrame(value)) {
          const damage = (value as { damage?: { textRows?: unknown[] } }).damage;
          samples.push({
            timestamp: performance.now(),
            hasDamage: Boolean(damage),
            dirtyRows: Array.isArray(damage?.textRows) ? damage.textRows.length : 0,
          });
        }
        return value;
      };

      function isSurfaceFrame(value: unknown): boolean {
        if (!value || typeof value !== "object") {
          return false;
        }
        const frame = value as {
          width?: unknown;
          height?: unknown;
          rows?: unknown;
        };
        return typeof frame.width === "number"
          && typeof frame.height === "number"
          && Array.isArray(frame.rows);
      }
    });

    try {
      await page.goto(server.url.href, { waitUntil: "domcontentloaded" });
      await page.waitForFunction(() => globalThis.crossOriginIsolated === true, undefined, {
        timeout: 10_000,
      });
      await page.waitForSelector(".webhost-scene__surface", {
        state: "attached",
        timeout: 30_000,
      });
      await page.waitForFunction(
        () => (window.__swiftTUIDamageSamples?.length ?? 0) >= 40,
        undefined,
        { polling: 100, timeout: 30_000 }
      );

      const samples = await page.evaluate(() => window.__swiftTUIDamageSamples ?? []);
      const steadySamples = samples.slice(8);
      const damagedFrames = steadySamples.filter((sample) => sample.hasDamage);

      expect(steadySamples.length).toBeGreaterThanOrEqual(24);
      expect(damagedFrames.length).toBeGreaterThanOrEqual(Math.floor(steadySamples.length * 0.8));
      expect(damagedFrames.some((sample) => sample.dirtyRows > 0)).toBe(true);
    } finally {
      await page.close();
      await browser.close();
      server.stop(true);
    }
  }, 120_000);
  ```

- [ ] **Step 2: Include the damage test in the browser script**

  In `package.json`, change `test:browser` to run all browser integration files:

  ```json
  "test:browser": "playwright install chromium && bun run build && bun test ./src/*.browser.ts --timeout 120000"
  ```

- [ ] **Step 3: Run the real browser integration**

  ```bash
  bun --cwd swift-tui-examples/Examples/WebExample run test:browser
  ```

  Expected: PASS with the cadence and damage assertions both satisfied.

- [ ] **Step 4: Commit real-path damage proof**

  ```bash
  git -C swift-tui-examples add Examples/WebExample/src/raster-damage.browser.ts Examples/WebExample/package.json
  git -C swift-tui-examples commit -m "test: verify WebExample emits raster damage"
  ```

### Task 6: Update Render And Host Documentation

**Files:**
- Modify: `swift-tui/docs/RENDER-PIPELINE.md`
- Modify: `swift-tui/docs/HOSTS-AND-PLATFORMS.md`

- [ ] **Step 1: Document retained-layout damage versus raster diff damage**

  In `RENDER-PIPELINE.md`, add this paragraph after the raster phase
  description:

  ```markdown
  Presentation damage has two sources. Retained-layout damage is computed before
  rasterization and may let the rasterizer reuse unchanged rows. When that proof
  is unavailable, the frame tail compares the previous committed
  `RasterSurface` with the current `RasterSurface` after rasterization and emits
  host-facing row/range damage. The post-raster diff is the browser and native
  host fallback for broad state invalidations such as task-driven root updates.
  ```

- [ ] **Step 2: Document per-host damage consumption**

  In `HOSTS-AND-PLATFORMS.md`, add this table below `## The host-frame
  contract`:

  ```markdown
  | Host | Damage consumption |
  | --- | --- |
  | Terminal-native | `TerminalHost` uses damage to limit row/span diffing and terminal byte emission. |
  | WASI / browser | `WebSurfaceTransport` serializes damage into the web-surface frame; the browser canvas clears and redraws dirty rects only. |
  | Localhost WebHost | `WebSocketSurfaceTransport` serializes the same web-surface damage over WebSocket. |
  | Host-managed SwiftUI | `HostedRasterSurface` carries damage through `SemanticHostFrame`; `NativeTerminalSurfaceView` invalidates only dirty native rects. |
  ```

- [ ] **Step 3: Run docs and focused tests**

  ```bash
  git -C swift-tui diff --check
  swiftly run swift test --filter SwiftTUICoreTests.RasterSurfaceDamageDiffTests
  swiftly run swift test --filter SwiftTUITests.PipelineContractTests
  bun --cwd swift-tui-web/packages/web test src/WebHostSceneRuntime.test.ts
  ```

  Expected: PASS.

- [ ] **Step 4: Run the repo gate**

  ```bash
  bun --cwd swift-tui run test
  ```

  Expected: PASS.

- [ ] **Step 5: Commit documentation**

  ```bash
  git -C swift-tui add docs/RENDER-PIPELINE.md docs/HOSTS-AND-PLATFORMS.md
  git -C swift-tui commit -m "docs: explain raster damage sources and hosts"
  ```
