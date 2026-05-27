# WASI Rendering Pipeline Performance Implementation Plan

> For agentic workers: execute this plan task by task. Keep each task in its
> owning child repo, commit child repo changes first, then update the
> `swift-tui-org` submodule pins in a final root commit.

**Goal:** Reduce WASI web-demo generation skips by removing Life demo copy-on-write
pressure, shrinking surface transport payloads with delta encoding, and adding a
browser-visible WASI frame diagnostics channel.

**Architecture:** Keep the runtime's latency-oriented latest-wins scheduling
policy. Make individual frames cheaper to produce and transport, then use WASI
diagnostics to prove whether remaining skips come from simulation, render, encode,
transport, browser decode, or presentation. Delta frames are opt-in through a web
host capability environment variable so older browser runtimes keep receiving full
surface frames.

**Tech Stack:** Swift 6.3, SwiftPM, SwiftTUI runtime, WASI surface bridge, Bun,
TypeScript, `@swifttui/web`, Playwright/Bun browser integration tests.

---

## Current Findings

- `swift-tui-examples/gallery/Sources/GalleryDemoViews/LifeTab.swift` copies
  `grid` into `next`, mutates `next`, then assigns back in the auto-tick loop,
  buttons, resize, seed, and drag paths.
- `LifeGrid` stores two fixed-capacity `[Bool]` buffers of
  `LifeGrid.maxWidth * LifeGrid.maxHeight`, currently `320 * 160` each. Mutating a
  copied grid forces array copy-on-write of large buffers.
- `swift-tui/Platforms/WASI/Sources/WASISurfaceBridge/WebSurfaceFrameEncoder.swift`
  emits every row and cell for every surface frame. The damage metadata is present
  but only helps browser drawing, not Swift-side JSON construction or transport.
- `swift-tui-web/packages/web/src/WebHostSceneRuntime.ts` already draws only dirty
  rects when damage is valid, so the first transport win is to avoid sending rows
  that the browser will not draw.
- `FrameDiagnosticsLogger` is currently file-backed and returns `nil` for WASI, so
  the browser build cannot emit the existing per-frame diagnostics.
- The WebExample demo may include additional scene tabs and content by the time
  this plan is executed. That does not change the implementation scope: the
  cadence regression and the copy-on-write smell are still measured through the
  Gallery Life tab, while diagnostics and delta decoding should remain generic for
  every WebExample tab.

## Non-Goals

- Do not change the default scheduler policy from latest-wins to show-every-frame.
- Do not make the public child repos require the org root checkout.
- Do not enable diagnostic frame emission by default.
- Do not require delta support from older `@swifttui/web` runtimes.
- Do not optimize LifeGrid's sparse `Set`/array allocation path until diagnostics
  show it remains a bottleneck after the copy-on-write fix.

## File Structure

### `swift-tui-examples`

- Modify `gallery/Sources/GalleryDemoViews/LifeTab.swift`
  - Remove explicit `var next = grid` mutation patterns.
  - Mutate the `@State` grid value directly.
- Use existing `gallery/Tests/GalleryDemoViewsTests/LifeGridTests.swift`
  - Keep behavior coverage for Life rules, resize, renderer snapshots, and drawing
    equality.

### `swift-tui`

- Modify `Sources/SwiftTUIRuntime/Diagnostics/FrameDiagnosticsLogger.swift`
  - Add an in-memory record-handler destination alongside the existing file
    destination.
- Modify `Sources/SwiftTUIRuntime/Diagnostics/FrameDiagnosticsTSVFormatting.swift`
  - Widen `headerFields` and `fields(for:)` to package access so the WASI bridge
    can serialize the same diagnostic schema.
- Modify `Platforms/WASI/Sources/WASISurfaceBridge/WebSurfaceFrameEncoder.swift`
  - Add frame diagnostic record encoding.
  - Add full/delta surface encoding entrypoints.
- Create `Platforms/WASI/Sources/WASISurfaceBridge/WebSurfaceFrameEncodingState.swift`
  - Own persistent image IDs, style table, previous-frame baseline, and feature
    flags for delta emission.
- Modify `Platforms/WASI/Sources/WASISurfaceBridge/WebSurfaceTransport.swift`
  - Store `WebSurfaceFrameEncodingState`.
  - Enable or disable delta encoding from initializer configuration.
  - Add `notifyFrameDiagnostic(_:)`.
- Modify `Platforms/WASI/Sources/SwiftTUIWASI/WASIRunner.swift`
  - Enable delta encoding when the browser advertises it.
  - Attach the diagnostics logger when the WASI diagnostics environment is enabled.
- Modify `Platforms/WebHost/Sources/SwiftTUIWebHost/WebSocketSurfaceTransport.swift`
  - Keep full-frame behavior initially, but compile against the new encoder state
    type if the encoder API changes.
- Modify `Platforms/WASI/Tests/WASISurfaceBridgeTests/WebSurfaceTransportTests.swift`
  - Add tests for diagnostics records, full fallback behavior, and delta emission.

### `swift-tui-web`

- Modify `packages/web/src/WebHostSurfaceTransport.ts`
  - Add raw delta-frame types, materialization in `WebHostOutputDecoder`, and
    `frameDiagnostic` output records.
- Modify `packages/web/src/WebHostSurfaceTransport.test.ts`
  - Add decoder tests for diagnostics records and delta materialization.
- Modify `packages/web/src/WebSocketSceneBridge.ts`
  - Deliver `frameDiagnostic` records to the sink.
- Modify `packages/web/src/wasi/BrowserWASIBridge.ts`
  - Advertise `TUIGUI_SURFACE_DELTA=1`.
  - Deliver `runtimeIssue` and `frameDiagnostic` records to the sink.
- Modify `packages/web/src/WebHostSceneRuntime.ts`
  - Accept an optional diagnostics callback and dispatch diagnostic records without
    rendering them as terminal text.
- Modify `swift-tui-examples/WebExample/src/frontend.ts`
  - Add an opt-in query parameter or environment hook for diagnostics, for example
    `?frameDiagnostics=1` setting `TUIGUI_FRAME_DIAGNOSTICS=1`.

## Execution Model

- Work inside child repos:
  - `swift-tui-examples` for Life demo changes.
  - `swift-tui` for Swift runtime and bridge changes.
  - `swift-tui-web` for TypeScript runtime changes.
- Commit each child repo independently.
- Return to `swift-tui-org`, update the submodule pins, and run the org gate.

---

## Task 1: Capture Baseline Before Editing

**Files:** none

- [ ] Run the current focused Swift tests that must stay green:

```bash
swift test --package-path swift-tui-examples/gallery --filter LifeGridTests
swift test --package-path swift-tui --filter WASISurfaceBridgeTests
bun --cwd swift-tui-web test packages/web/src/WebHostSurfaceTransport.test.ts
```

- [ ] Record a browser baseline against the existing WASI build:

```bash
bun --cwd swift-tui-examples/WebExample test src/browser-integration.browser.ts
```

- [ ] When recording the browser baseline, note the WebExample scene and tab used
  for the measurement. If additional tabs have been added since this plan was
  written, navigate explicitly to the Gallery Life tab and do not compare cadence
  numbers collected from another tab.

- [ ] Capture an ad hoc generation-gap sample with the existing browser harness or
  a one-off Playwright script. Record:
  - decoded surface frame count
  - first and last `gen N`
  - max generation delta between decoded frames
  - average surface payload bytes
  - average dirty row count from `damage.textRows`

Expected baseline shape for the current issue: decoded generations occasionally
advance by more than one generation in the WASI build while the local `--web`
path does not show the same cadence problem.

## Task 2: Remove LifeTab Explicit Copy-On-Write

**Files:**

- Modify `swift-tui-examples/gallery/Sources/GalleryDemoViews/LifeTab.swift`

- [ ] Replace seed-on-appear copy/update with direct state mutation.

Current pattern:

```swift
var resized = grid
resized.resize(width: dims.width, height: dims.height)
resized.seedDefault()
grid = resized
```

Replacement:

```swift
grid.resize(width: dims.width, height: dims.height)
grid.seedDefault()
```

- [ ] Replace resize copy/update with direct state mutation.

Current pattern:

```swift
var resized = grid
resized.resize(width: dims.width, height: dims.height)
grid = resized
```

Replacement:

```swift
grid.resize(width: dims.width, height: dims.height)
```

- [ ] Replace button copy/update handlers.

Use these bodies:

```swift
Button("Step") {
  grid.step()
}
.disabled(isRunning)

Button("Random") {
  grid.randomize()
}

Button("Clear") {
  grid.clear()
}
```

- [ ] Replace drag-paint copy/update with direct mutation.

Current pattern:

```swift
if let mode = paintMode {
  var next = grid
  next.set(cell.x, cell.y, mode)
  grid = next
}
```

Replacement:

```swift
if let mode = paintMode {
  grid.set(cell.x, cell.y, mode)
}
```

- [ ] Replace auto-tick copy/update with direct mutation.

Current pattern:

```swift
var next = grid
next.step()
grid = next
```

Replacement:

```swift
grid.step()
```

- [ ] Verify the source no longer has the explicit LifeGrid copy pattern:

```bash
rg -n "var (next|resized) = grid" swift-tui-examples/gallery/Sources/GalleryDemoViews/LifeTab.swift
```

Expected: no matches.

- [ ] Run focused tests:

```bash
swift test --package-path swift-tui-examples/gallery --filter LifeGridTests
swift test --package-path swift-tui-examples/gallery --filter LifeRendererTests
```

- [ ] Commit inside `swift-tui-examples`:

```bash
git -C swift-tui-examples add gallery/Sources/GalleryDemoViews/LifeTab.swift
git -C swift-tui-examples commit -m "perf: avoid copying Life grid on mutation"
```

## Task 3: Add Browser Record Types for Diagnostics and Delta Frames

**Files:**

- Modify `swift-tui-web/packages/web/src/WebHostSurfaceTransport.ts`
- Modify `swift-tui-web/packages/web/src/WebHostSurfaceTransport.test.ts`

- [ ] Add a diagnostic output type:

```ts
export interface WebHostFrameDiagnosticRecord {
  format: "swift-tui-frame-diagnostics-v1";
  header: string[];
  fields: string[];
}
```

Extend `WebHostOutputRecord`:

```ts
| { type: "frameDiagnostic"; diagnostic: WebHostFrameDiagnosticRecord }
```

Extend `WebHostOutputSink`:

```ts
recordFrameDiagnostic?(diagnostic: WebHostFrameDiagnosticRecord): void;
```

- [ ] Decode `\u001EframeDiagnostic:` records before the `surface:` branch.

Acceptance behavior:

```ts
const records = decoder.feed(encoder.encode(
  '\u001EframeDiagnostic:{"format":"swift-tui-frame-diagnostics-v1",'
    + '"header":["frame","total_ms"],"fields":["7","14.20"]}\n'
));
expect(records).toEqual([
  {
    type: "frameDiagnostic",
    diagnostic: {
      format: "swift-tui-frame-diagnostics-v1",
      header: ["frame", "total_ms"],
      fields: ["7", "14.20"],
    },
  },
]);
```

- [ ] Add raw delta surface types:

```ts
export type WebHostSurfaceDeltaRow = [
  row: number,
  cells: WebHostSurfaceCell[],
];

export interface WebHostSurfaceDeltaFrame {
  version: 3;
  encoding: "delta";
  sequence?: number;
  width: number;
  height: number;
  styles: Array<WebHostSurfaceStyle | null>;
  deltaRows: WebHostSurfaceDeltaRow[];
  images?: WebHostSurfaceImage[];
  damage?: WebHostSurfaceDamage;
  accessibilityTree?: WebHostAccessibilityNode[];
  accessibilityAnnouncements?: WebHostAccessibilityAnnouncement[];
}
```

- [ ] Add decoder materialization state:

```ts
private lastSurfaceFrame?: WebHostSurfaceFrame;
```

When decoding a full `surface` frame with `rows`, store it as
`lastSurfaceFrame` and return it. When decoding a delta frame, require an
existing baseline with the same width and height, clone the previous `rows`
outer array, replace each changed row, and return a normal materialized
`WebHostSurfaceFrame`.

- [ ] Add delta decoder tests:

```ts
const decoder = new WebHostOutputDecoder();
const records = decoder.feed(encoder.encode(
  '\u001Esurface:{"version":2,"width":2,"height":2,"styles":[null],'
    + '"rows":[[[0,"A",1,0]],[[0,"B",1,0]]],"images":[]}\n'
    + '\u001Esurface:{"version":3,"encoding":"delta","width":2,"height":2,'
    + '"styles":[null],"deltaRows":[[1,[[0,"C",1,0]]]],"images":[],'
    + '"damage":{"textRows":[[1,[[0,1]]]],'
    + '"requiresFullTextRepaint":false,"requiresFullGraphicsReplay":false}}\n'
));

expect(records.map((record) => record.type)).toEqual(["surface", "surface"]);
expect(surfaceFrame(records[1]).rows).toEqual([
  [[0, "A", 1, 0]],
  [[0, "C", 1, 0]],
]);
```

- [ ] Add rejection tests:
  - delta before any full baseline becomes diagnostic text
  - delta with a changed width or height becomes diagnostic text
  - delta row index outside `0..<height` becomes diagnostic text

- [ ] Run:

```bash
bun --cwd swift-tui-web test packages/web/src/WebHostSurfaceTransport.test.ts
```

## Task 4: Deliver New Browser Records Through Both Bridges

**Files:**

- Modify `swift-tui-web/packages/web/src/WebSocketSceneBridge.ts`
- Modify `swift-tui-web/packages/web/src/wasi/BrowserWASIBridge.ts`
- Modify `swift-tui-web/packages/web/src/WebHostSceneRuntime.ts`

- [ ] Add `frameDiagnostic` delivery in `WebSocketSceneBridge.deliver`:

```ts
case "frameDiagnostic":
  sink.recordFrameDiagnostic?.(record.diagnostic);
  break;
```

- [ ] Add missing `runtimeIssue` delivery and new `frameDiagnostic` delivery in
  `BrowserWASIBridge.bindOutput`:

```ts
case "runtimeIssue":
  sink.notifyRuntimeIssue?.(record.issue);
  break;
case "frameDiagnostic":
  sink.recordFrameDiagnostic?.(record.diagnostic);
  break;
```

- [ ] Advertise delta support from the WASI browser bridge:

```ts
this.environment = {
  TUIGUI_MODE: "browser",
  TUIGUI_TRANSPORT: "surface",
  TUIGUI_SURFACE_DELTA: "1",
  TUIGUI_SCENE: options.sceneId,
  TUIGUI_COLUMNS: String(Math.max(1, options.columns)),
  TUIGUI_ROWS: String(Math.max(1, options.rows)),
  ...options.environment,
  ...
};
```

Because `options.environment` remains after the default, callers can force
`TUIGUI_SURFACE_DELTA=0` for compatibility debugging.

- [ ] Add an optional runtime callback:

```ts
export interface WebHostSceneRuntimeOptions {
  ...
  onFrameDiagnostic?: (diagnostic: WebHostFrameDiagnosticRecord) => void;
}
```

Bind it:

```ts
recordFrameDiagnostic: (diagnostic) => this.recordFrameDiagnostic(diagnostic),
```

Implement it as:

```ts
private recordFrameDiagnostic(
  diagnostic: WebHostFrameDiagnosticRecord
): void {
  this.onFrameDiagnostic?.(diagnostic);
}
```

- [ ] Run:

```bash
bun --cwd swift-tui-web test packages/web
```

## Task 5: Add Swift Diagnostics Emission for WASI

**Files:**

- Modify `swift-tui/Sources/SwiftTUIRuntime/Diagnostics/FrameDiagnosticsLogger.swift`
- Modify `swift-tui/Sources/SwiftTUIRuntime/Diagnostics/FrameDiagnosticsTSVFormatting.swift`
- Modify `swift-tui/Platforms/WASI/Sources/WASISurfaceBridge/WebSurfaceFrameEncoder.swift`
- Modify `swift-tui/Platforms/WASI/Sources/WASISurfaceBridge/WebSurfaceTransport.swift`
- Modify `swift-tui/Platforms/WASI/Sources/SwiftTUIWASI/WASIRunner.swift`
- Modify `swift-tui/Platforms/WASI/Tests/WASISurfaceBridgeTests/WebSurfaceTransportTests.swift`

- [ ] Add a record-handler destination to `FrameDiagnosticsLogger`:

```swift
@MainActor
public final class FrameDiagnosticsLogger {
  private enum Destination {
    case fileDescriptor(Int32, ownsDescriptor: Bool)
    case recordHandler(@MainActor (FrameDiagnosticRecord) -> Void)
  }

  private let destination: Destination
  private var headerWritten = false

  public init(recordHandler: @escaping @MainActor (FrameDiagnosticRecord) -> Void) {
    self.destination = .recordHandler(recordHandler)
  }
}
```

Update `log(_:)`:

```swift
public func log(_ record: FrameDiagnosticRecord) {
  switch destination {
  case .recordHandler(let handler):
    handler(record)
  case .fileDescriptor:
    if !headerWritten {
      writeHeader()
      headerWritten = true
    }
    writeLine(FrameDiagnosticsTSVFormatting.fields(for: record).joined(separator: "\t"))
  }
}
```

Keep the existing file initializer behavior unchanged for Darwin and Glibc.

- [ ] Change `FrameDiagnosticsTSVFormatting` access:

```swift
package enum FrameDiagnosticsTSVFormatting {
  package static let headerFields = [...]
  package static func fields(for record: FrameDiagnosticRecord) -> [String] { ... }
}
```

- [ ] Add an encoder:

```swift
package static func encodeFrameDiagnostic(
  _ record: FrameDiagnosticRecord
) -> String {
  let header = FrameDiagnosticsTSVFormatting.headerFields
    .map(jsonString)
    .joined(separator: ",")
  let fields = FrameDiagnosticsTSVFormatting.fields(for: record)
    .map(jsonString)
    .joined(separator: ",")
  return "\u{001E}frameDiagnostic:{"
    + "\"format\":\"swift-tui-frame-diagnostics-v1\","
    + "\"header\":[\(header)],"
    + "\"fields\":[\(fields)]"
    + "}\n"
}
```

- [ ] Add transport emission:

```swift
package func notifyFrameDiagnostic(_ record: FrameDiagnosticRecord) throws {
  try writeBytes(Array(WebSurfaceFrameEncoder.encodeFrameDiagnostic(record).utf8))
}
```

- [ ] Enable the logger in `WASIRunner.webSurfaceSceneResources()` only when
  requested:

```swift
let diagnosticsLogger: FrameDiagnosticsLogger? =
  if wasiFrameDiagnosticsEnabled() {
    FrameDiagnosticsLogger { record in
      try? host.notifyFrameDiagnostic(record)
    }
  } else {
    nil
  }
```

Pass it into `SceneSessionResources`.

- [ ] Add the environment parser:

```swift
private static func wasiFrameDiagnosticsEnabled() -> Bool {
  guard let value = environmentValue(named: "TUIGUI_FRAME_DIAGNOSTICS")
    ?? environmentValue(named: "TERMUI_DIAGNOSTICS")
  else {
    return false
  }
  switch value.lowercased() {
  case "", "0", "false", "off", "none":
    return false
  default:
    return true
  }
}
```

- [ ] Add Swift tests:
  - `encodeFrameDiagnostic` emits the typed prefix
  - JSON includes `format`, `header`, and `fields`
  - `WebSurfaceTransport.notifyFrameDiagnostic` writes one complete typed record

- [ ] Run:

```bash
swift test --package-path swift-tui --filter WASISurfaceBridgeTests
swift test --package-path swift-tui --filter FrameDiagnostics
```

## Task 6: Implement Delta Surface Encoding State in Swift

**Files:**

- Create `swift-tui/Platforms/WASI/Sources/WASISurfaceBridge/WebSurfaceFrameEncodingState.swift`
- Modify `swift-tui/Platforms/WASI/Sources/WASISurfaceBridge/WebSurfaceFrameEncoder.swift`
- Modify `swift-tui/Platforms/WASI/Sources/WASISurfaceBridge/WebSurfaceTransport.swift`
- Modify `swift-tui/Platforms/WASI/Tests/WASISurfaceBridgeTests/WebSurfaceTransportTests.swift`

- [ ] Add the state type:

```swift
package struct WebSurfaceFrameEncodingState: Sendable {
  package var deltaEnabled: Bool
  package var knownImageIDs: Set<String> = []
  package var styles: [ResolvedTextStyle?] = [nil]
  package var hasBaseline = false
  package var baselineSize: CellSize?

  package init(deltaEnabled: Bool = false) {
    self.deltaEnabled = deltaEnabled
  }
}
```

- [ ] Change row encoding to use the persistent style table:

```swift
private static func encodeRow(
  _ row: [RasterCell],
  y _: Int,
  styles: inout [ResolvedTextStyle?]
) -> String
```

Keep the existing signature, but pass `&state.styles` instead of a fresh local
array from the new stateful encoding path. Full frames and delta frames both emit
the full current `styles` table. Since the table only appends, previous row style
indices remain valid after materializing a delta frame.

- [ ] Add full fallback rules:
  - delta disabled
  - no previous baseline
  - `damage == nil`
  - `damage.requiresFullTextRepaint == true`
  - `damage.requiresFullGraphicsReplay == true`
  - surface size changed

- [ ] Add delta row selection:

```swift
private static func damagedRowIndexes(
  from damage: PresentationDamage,
  height: Int
) -> [Int] {
  Array(
    Set(damage.textRows.map(\.row).filter { $0 >= 0 && $0 < height })
  ).sorted()
}
```

Encode whole rows for those row indexes in the first implementation. Keep exact
damage ranges in the `damage` field so browser painting stays range-aware.

- [ ] Add delta JSON shape:

```json
{
  "version": 3,
  "encoding": "delta",
  "sequence": 42,
  "width": 128,
  "height": 39,
  "styles": [null],
  "deltaRows": [[12, [[0, "x", 1, 0]]]],
  "images": [],
  "damage": {
    "textRows": [[12, [[0, 1]]]],
    "requiresFullTextRepaint": false,
    "requiresFullGraphicsReplay": false
  }
}
```

- [ ] Keep existing full-frame JSON unchanged for compatibility. Do not add
  `encoding: "full"` to existing full frames unless a test proves the browser
  decoder needs it.

- [ ] Update `WebSurfaceTransport.State`:

```swift
var encodingState: WebSurfaceFrameEncodingState
```

Initialize with:

```swift
encodingState: WebSurfaceFrameEncodingState(deltaEnabled: deltaEnabled)
```

Replace `transmittedImageIDs` with `encodingState.knownImageIDs`.

- [ ] Add an initializer parameter:

```swift
package init(
  surfaceSize: CellSize,
  outputFileDescriptor: Int32 = webSurfaceStandardOutputFileDescriptor,
  renderStyle: TerminalRenderStyle,
  deltaEncodingEnabled: Bool = false
)
```

- [ ] Add Swift tests:
  - first frame is full even when delta is enabled
  - second semantic frame with non-full damage emits `version: 3`,
    `encoding: "delta"`, and `deltaRows`
  - delta JSON omits `rows`
  - full repaint damage emits a full frame
  - size change emits a full frame
  - delta bytes are fewer than the equivalent full frame for a fixture with one
    dirty row

- [ ] Run:

```bash
swift test --package-path swift-tui --filter WASISurfaceBridgeTests
```

## Task 7: Enable Delta Encoding for WASI Only

**Files:**

- Modify `swift-tui/Platforms/WASI/Sources/SwiftTUIWASI/WASIRunner.swift`
- Modify `swift-tui-web/packages/web/src/wasi/BrowserWASIBridge.ts`
- Modify `swift-tui-web/packages/web/src/wasi/BrowserWASIBridge.test.ts`

- [ ] Add a Swift parser:

```swift
private static func wasiSurfaceDeltaEnabled() -> Bool {
  switch environmentValue(named: "TUIGUI_SURFACE_DELTA")?.lowercased() {
  case "1", "true", "yes", "on":
    return true
  default:
    return false
  }
}
```

- [ ] Pass it into `WebSurfaceTransport`:

```swift
let host = WebSurfaceTransport(
  surfaceSize: wasiSurfaceSize(),
  renderStyle: wasiRenderStyle() ?? .init(appearance: .fallback),
  deltaEncodingEnabled: wasiSurfaceDeltaEnabled()
)
```

- [ ] Add a browser bridge test:

```ts
expect(bridge.environment.TUIGUI_SURFACE_DELTA).toBe("1");
```

- [ ] Add an override test:

```ts
const bridge = new BrowserWASIBridge({
  sceneId: "main",
  columns: 80,
  rows: 24,
  environment: { TUIGUI_SURFACE_DELTA: "0" },
});
expect(bridge.environment.TUIGUI_SURFACE_DELTA).toBe("0");
```

- [ ] Run:

```bash
swift test --package-path swift-tui --filter SwiftTUIWASITests
bun --cwd swift-tui-web test packages/web/src/wasi/BrowserWASIBridge.test.ts
```

## Task 8: Add WebExample Diagnostics Hook

**Files:**

- Modify `swift-tui-examples/WebExample/src/frontend.ts`
- Modify or add a focused browser integration test if the existing harness covers
  query-parameter runtime setup.

- [ ] Add a helper:

```ts
function frameDiagnosticsEnabled(): boolean {
  const params = new URLSearchParams(globalThis.location?.search ?? "");
  return params.get("frameDiagnostics") === "1"
    || params.get("diagnostics") === "1"
    || globalThis.localStorage?.getItem("swiftTUIFrameDiagnostics") === "1";
}
```

- [ ] When constructing the WASI scene runtime environment, add:

```ts
environment: {
  TUIGUI_APP_NAME: "WebExample",
  ...(frameDiagnosticsEnabled() ? { TUIGUI_FRAME_DIAGNOSTICS: "1" } : {}),
}
```

- [ ] Wire `onFrameDiagnostic` to a non-visual collector. For the demo, prefer a
  console table-friendly object so diagnostics do not alter terminal layout:

```ts
onFrameDiagnostic: (diagnostic) => {
  const row = Object.fromEntries(
    diagnostic.header.map((key, index) => [key, diagnostic.fields[index] ?? ""])
  );
  console.debug("SwiftTUI frame", row);
}
```

- [ ] Add a browser test that launches with `?frameDiagnostics=1`, patches
  `console.debug`, and asserts at least one `"SwiftTUI frame"` entry arrives after
  the scene has mounted.

- [ ] Keep this hook scene-agnostic. The WebExample may expose more tabs than the
  original Life repro, and the diagnostics channel should report whichever tab is
  currently producing frames without adding tab-specific UI.

- [ ] Run:

```bash
bun --cwd swift-tui-examples/WebExample test src/browser-integration.browser.ts
```

## Task 9: Measure and Compare

**Files:** none, unless the measurement harness is committed as a reusable test

- [ ] Rebuild the WASI demo using the repo's existing WebExample build command.
  Use the command already documented in that child repo. If running from the org
  root, prefer:

```bash
bun --cwd swift-tui-examples/WebExample run build
```

- [ ] Run the generation-gap measurement with default settings:
  - `TUIGUI_SURFACE_DELTA=1`
  - diagnostics disabled
  - normal Life tick interval
  - Gallery Life tab selected, even if WebExample now contains additional tabs

- [ ] Run the diagnostics measurement:
  - `?frameDiagnostics=1`
  - collect at least 10 seconds of frames

- [ ] Compare against the Task 1 baseline:
  - decoded generation gaps
  - `present_bytes`
  - `present_ms`
  - `total_ms`
  - `coalesced_intent_requests`
  - `tail_job_state`
  - `drop_decision`
  - dirty row counts

Target outcome:

- Life demo does not show routine `+2` generation gaps at the default viewport and
  110 ms tick interval on the development machine.
- Delta frames reduce steady-state surface bytes by at least 50 percent when fewer
  than one third of rows are dirty.
- If skips remain, diagnostics identify whether time is spent in Life stepping,
  Swift render/layout/raster, encode/write, scheduler cancellation/drop, or browser
  presentation.

## Task 10: Integration Gates and Pin Updates

**Files:**

- Update submodule pins in `swift-tui-org` after child commits.

- [ ] Run child gates:

```bash
swift test --package-path swift-tui-examples/gallery --filter LifeGridTests
swift test --package-path swift-tui --filter WASISurfaceBridgeTests
swift test --package-path swift-tui --filter SwiftTUIWASITests
bun --cwd swift-tui-web test
bun --cwd swift-tui-examples/WebExample test
```

- [ ] Commit each child repo:

```bash
git -C swift-tui status --short
git -C swift-tui add <changed-files>
git -C swift-tui commit -m "perf: add WASI surface delta diagnostics"

git -C swift-tui-web status --short
git -C swift-tui-web add <changed-files>
git -C swift-tui-web commit -m "perf: decode WASI delta frames and diagnostics"

git -C swift-tui-examples status --short
git -C swift-tui-examples add <changed-files>
git -C swift-tui-examples commit -m "perf: reduce WASI Life demo frame cost"
```

- [ ] Update root pins:

```bash
git add swift-tui swift-tui-web swift-tui-examples
git commit -m "chore: update WASI rendering performance pins"
```

- [ ] Run the org-level fast gate:

```bash
bazel test //:org_fast
```

## Risk Notes

- Delta frames require browser state. The decoder must reset or reject deltas when
  no full baseline exists, dimensions change, or a malformed row arrives.
- Persistent style tables must preserve old style indices. The first
  implementation should only append styles and emit the whole table on every delta
  frame.
- Delta encoding should be opt-in from the browser environment. Without
  `TUIGUI_SURFACE_DELTA=1`, Swift must continue sending existing full surface
  records.
- Diagnostics records add transport work. Keep them disabled unless explicitly
  requested through environment or query parameter.
- If direct `@State` mutation does not compile in `LifeTab`, replace `LifeGrid`
  storage with a reference-backed buffer while preserving value semantics with
  `isKnownUniquelyReferenced` before mutation. Add a copy-isolation test before
  making that larger model change.
