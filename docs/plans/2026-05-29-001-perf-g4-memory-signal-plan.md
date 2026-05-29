# Perf Hardening G4 — Memory-Signal Completeness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `TermUIPerf` memory signal trustworthy: a standardized (configurable, non-magic) sample interval + post-drive idle window, and an automatic per-provider growth-slope + plateau-detection analysis so the leak signal (monotonic count, no plateau) is computed, not eyeballed.

**Architecture:** Two pieces, both in `swift-tui/Tools/TermUIPerf` (the memory occupancy types in `SwiftTUICore`/runtime already report `count` and, for byte-heavy stores, `approxBytes`, so no runtime change is needed). **G4b:** add `memorySampleInterval` + `memoryIdleWindow` to `PerfScenarioRunOptions` with named defaults, and have `runWindow` sample for the configured interval and keep sampling through a post-drive idle window. **G4c:** add a pure `MemoryGrowthAnalyzer` over the sampler's time-series that computes a least-squares slope and a plateau flag per provider, written as a `memory_growth.tsv` artifact. New logic is pure and TDD'd like G2's `AggregateReducer`.

**Tech Stack:** Swift 6.3 (Swift 6 language mode), Swift Testing (`import Testing`, `@Test`, `#expect`), SwiftPM. Package `Tools/TermUIPerf` (product `TermUIPerf`, test target `TermUIPerfTests`).

---

## Context an engineer needs before starting

- **Where this runs.** All changes are in `swift-tui/Tools/TermUIPerf`. Build/test:
  ```bash
  cd swift-tui
  swiftly run swift build --package-path Tools/TermUIPerf
  swiftly run swift test  --package-path Tools/TermUIPerf
  swiftly run swift test  --package-path Tools/TermUIPerf --filter TermUIPerfTests.MemoryGrowthAnalyzerTests
  ```
- **Formatting (pre-commit enforces):** 2-space indent, 100-col, `private` not `fileprivate`, no block comments. `swift format format -i --configuration .swift-format.json <files>`.
- **Cross-repo workflow.** Commit inside `swift-tui` on a feature branch. The org-root pin bump happens later, outside this plan.
- **Key existing types (do not redefine):**
  - `PerfMemorySampler` (`Tools/TermUIPerf/Sources/TermUIPerf/PerfMemorySampler.swift`): `@MainActor final class`. Has `struct Sample { let elapsedSeconds: Double; let snapshots: [ProfiledMemorySnapshot] }`, `private(set) var samples: [Sample]`, `func startSampling(interval: Duration) -> Task<Void, Never>`, `func tsv() -> String`.
  - `ProfiledMemorySnapshot` (`@_spi(Runners) public`, from `SwiftTUIProfiling`): fields `name: String`, `count: Int`, `approxBytes: Int?`. The sampler file already does `@_spi(Runners) import SwiftTUIProfiling`.
  - `PerfScenarioRunOptions` (`Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/PerfScenario.swift:78`): `public struct`, fields `renderMode`, `iterations`, `artifactRoot`, `configuration`, `terminalSize`, `cpuSampleInterval: Duration` (default `.milliseconds(50)`). Add the two memory fields here.
  - `PerfScenarioRunner.runWindow` (`PerfScenario.swift:230`): starts the sampler at `:285` (`memorySampler.startSampling(interval: .milliseconds(500))`) after the first presented frame, runs the scenario's `drive` closure (`:286`), then `memoryTask?.cancel()` (`:291`), and writes `memory.tsv` at `:339`.

---

## File structure

- **Modify** `Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/PerfScenario.swift`
  — add `memorySampleInterval` + `memoryIdleWindow` to `PerfScenarioRunOptions`; use them in `runWindow`; write `memory_growth.tsv`.
- **Create** `Tools/TermUIPerf/Sources/TermUIPerf/MemoryGrowthAnalysis.swift`
  — `MemoryGrowthRow`, `MemoryGrowthAnalysis`, `MemoryGrowthAnalyzer.analyze(...)` + `.tsv(...)`.
- **Create** `Tools/TermUIPerf/Tests/TermUIPerfTests/MemoryGrowthAnalyzerTests.swift`
- **Modify** `Tools/TermUIPerf/Tests/TermUIPerfTests/ScenarioSmokeTests.swift`
  — assert `memory_growth.tsv` is written and the interval option is honored.

> **Deferred (not in this plan):** `RetainedFrameIndex.placedByIdentity` reports
> `approxBytes` as `width × height` (cell count, not bytes — off by
> `MemoryLayout<RasterCell>.stride`). This is a minor precision nit on a
> best-effort field; the three byte-heavy providers the G4 spec targeted already
> report bytes. Tracked as a follow-up, intentionally out of scope here.

---

## Task 1: `MemoryGrowthRow` + slope (least-squares) per provider

**Files:**
- Create: `Tools/TermUIPerf/Sources/TermUIPerf/MemoryGrowthAnalysis.swift`
- Test: `Tools/TermUIPerf/Tests/TermUIPerfTests/MemoryGrowthAnalyzerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tools/TermUIPerf/Tests/TermUIPerfTests/MemoryGrowthAnalyzerTests.swift`:

```swift
import Foundation
import Testing

@testable import TermUIPerf

struct MemoryGrowthAnalyzerTests {
  @Test("linear growth yields a positive count/second slope")
  func linearGrowthYieldsPositiveSlope() {
    // provider "g" grows 0,2,4,6,8 over t=0,1,2,3,4 -> slope 2.0/s
    let analysis = MemoryGrowthAnalyzer.analyze(
      samples(provider: "g", counts: [0, 2, 4, 6, 8], step: 1.0))

    let row = analysis.rows.first { $0.provider == "g" }!
    #expect(row.sampleCount == 5)
    #expect(row.firstCount == 0)
    #expect(row.lastCount == 8)
    #expect(approx(row.slopePerSecond, 2.0))
  }

  @Test("a single sample yields zero slope and no leak")
  func singleSampleYieldsZeroSlope() {
    let analysis = MemoryGrowthAnalyzer.analyze(samples(provider: "g", counts: [5], step: 1.0))
    let row = analysis.rows.first { $0.provider == "g" }!
    #expect(approx(row.slopePerSecond, 0.0))
    #expect(row.leakSuspected == false)
  }

  // Builds N samples, each containing one provider snapshot with the given count.
  func samples(provider: String, counts: [Int], step: Double) -> [PerfMemorySampler.Sample] {
    counts.enumerated().map { index, count in
      PerfMemorySampler.Sample(
        elapsedSeconds: Double(index) * step,
        snapshots: [ProfiledMemorySnapshot(name: provider, count: count, approxBytes: nil)])
    }
  }

  func approx(_ actual: Double, _ expected: Double) -> Bool {
    abs(actual - expected) < 0.000_001
  }
}
```

> Note: `PerfMemorySampler.Sample` and `ProfiledMemorySnapshot` are constructed
> directly. `ProfiledMemorySnapshot(name:count:approxBytes:)` is its `@_spi(Runners)`
> memberwise init — the test target already imports it transitively via
> `@testable import TermUIPerf`; if the initializer is not visible, add
> `@_spi(Runners) import SwiftTUIProfiling` to the test file (the sampler source
> already uses that import).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf --filter TermUIPerfTests.MemoryGrowthAnalyzerTests`
Expected: FAIL — `cannot find 'MemoryGrowthAnalyzer' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Tools/TermUIPerf/Sources/TermUIPerf/MemoryGrowthAnalysis.swift`:

```swift
import Foundation

/// Per-provider growth summary over a run's memory time-series.
public struct MemoryGrowthRow: Codable, Equatable, Sendable {
  public var provider: String
  public var sampleCount: Int
  public var firstCount: Int
  public var lastCount: Int
  public var slopePerSecond: Double
  public var plateaued: Bool
  public var leakSuspected: Bool

  public init(
    provider: String,
    sampleCount: Int,
    firstCount: Int,
    lastCount: Int,
    slopePerSecond: Double,
    plateaued: Bool,
    leakSuspected: Bool
  ) {
    self.provider = provider
    self.sampleCount = sampleCount
    self.firstCount = firstCount
    self.lastCount = lastCount
    self.slopePerSecond = slopePerSecond
    self.plateaued = plateaued
    self.leakSuspected = leakSuspected
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case sampleCount = "sample_count"
    case firstCount = "first_count"
    case lastCount = "last_count"
    case slopePerSecond = "slope_per_second"
    case plateaued
    case leakSuspected = "leak_suspected"
  }
}

public struct MemoryGrowthAnalysis: Codable, Equatable, Sendable {
  public var rows: [MemoryGrowthRow]

  public init(rows: [MemoryGrowthRow]) {
    self.rows = rows
  }
}

public enum MemoryGrowthAnalyzer {
  /// A provider growing faster than this (count/second) AND not plateaued is a
  /// leak suspect. Default chosen so a bounded cache filling toward its cap is
  /// caught by the plateau check, not this threshold.
  public static let defaultSlopeThresholdPerSecond = 0.5
  /// The last `plateauTailFraction` of samples count as the "tail" for the
  /// plateau check.
  public static let defaultPlateauTailFraction = 0.5
  /// Tail counts within this fraction of the tail's max are "flat".
  public static let defaultPlateauTolerance = 0.05

  public static func analyze(
    _ samples: [PerfMemorySampler.Sample],
    slopeThresholdPerSecond: Double = defaultSlopeThresholdPerSecond,
    plateauTailFraction: Double = defaultPlateauTailFraction,
    plateauTolerance: Double = defaultPlateauTolerance
  ) -> MemoryGrowthAnalysis {
    // Group (elapsedSeconds, count) by provider name, preserving sample order.
    var series: [String: [(t: Double, count: Int)]] = [:]
    var order: [String] = []
    for sample in samples {
      for snapshot in sample.snapshots {
        if series[snapshot.name] == nil {
          order.append(snapshot.name)
        }
        series[snapshot.name, default: []].append((sample.elapsedSeconds, snapshot.count))
      }
    }
    let rows = order.map { name -> MemoryGrowthRow in
      let points = series[name] ?? []
      let slope = leastSquaresSlope(points)
      let plateaued = isPlateaued(
        points, tailFraction: plateauTailFraction, tolerance: plateauTolerance)
      let leak = slope > slopeThresholdPerSecond && !plateaued
      return MemoryGrowthRow(
        provider: name,
        sampleCount: points.count,
        firstCount: points.first?.count ?? 0,
        lastCount: points.last?.count ?? 0,
        slopePerSecond: slope,
        plateaued: plateaued,
        leakSuspected: leak)
    }
    return MemoryGrowthAnalysis(rows: rows)
  }

  /// Least-squares slope of count over time. Returns 0 for < 2 points or when
  /// all timestamps are equal (zero variance in t).
  private static func leastSquaresSlope(_ points: [(t: Double, count: Int)]) -> Double {
    let n = Double(points.count)
    guard points.count > 1 else {
      return 0
    }
    let sumT = points.reduce(0.0) { $0 + $1.t }
    let sumY = points.reduce(0.0) { $0 + Double($1.count) }
    let sumTT = points.reduce(0.0) { $0 + $1.t * $1.t }
    let sumTY = points.reduce(0.0) { $0 + $1.t * Double($1.count) }
    let denominator = n * sumTT - sumT * sumT
    guard abs(denominator) > 0.000_000_1 else {
      return 0
    }
    return (n * sumTY - sumT * sumY) / denominator
  }

  /// True when the tail of the series is flat: the tail's (max - min) is within
  /// `tolerance` of its max magnitude (or the tail is entirely zero).
  private static func isPlateaued(
    _ points: [(t: Double, count: Int)],
    tailFraction: Double,
    tolerance: Double
  ) -> Bool {
    guard points.count >= 4 else {
      return false
    }
    let tailStart = Int(Double(points.count) * (1 - tailFraction))
    let tail = points[tailStart...].map { $0.count }
    guard let maxCount = tail.max(), let minCount = tail.min() else {
      return false
    }
    if maxCount == 0 {
      return true
    }
    return Double(maxCount - minCount) <= tolerance * Double(maxCount)
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf --filter TermUIPerfTests.MemoryGrowthAnalyzerTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Format and commit**

```bash
cd swift-tui
swift format format -i --configuration .swift-format.json \
  Tools/TermUIPerf/Sources/TermUIPerf/MemoryGrowthAnalysis.swift \
  Tools/TermUIPerf/Tests/TermUIPerfTests/MemoryGrowthAnalyzerTests.swift
git add Tools/TermUIPerf/Sources/TermUIPerf/MemoryGrowthAnalysis.swift \
        Tools/TermUIPerf/Tests/TermUIPerfTests/MemoryGrowthAnalyzerTests.swift
git commit -m "feat(perf): per-provider memory growth slope analysis"
```

---

## Task 2: Plateau detection + leak-suspect classification

**Files:**
- Modify: `Tools/TermUIPerf/Tests/TermUIPerfTests/MemoryGrowthAnalyzerTests.swift:1` (add tests)

The implementation from Task 1 already includes `isPlateaued` and the `leakSuspected` rule. This task adds the tests that pin that behavior (the discriminating cases — unbounded growth vs. a bounded cache filling toward a cap, the exact H5 `TextLayoutCache` scenario).

- [ ] **Step 1: Write the failing tests**

Add inside `struct MemoryGrowthAnalyzerTests` (before the `samples`/`approx` helpers):

```swift
  @Test("steady unbounded growth is a leak suspect")
  func steadyUnboundedGrowthIsLeakSuspect() {
    let analysis = MemoryGrowthAnalyzer.analyze(
      samples(provider: "leak", counts: [0, 10, 20, 30, 40, 50, 60, 70], step: 1.0))
    let row = analysis.rows.first { $0.provider == "leak" }!
    #expect(row.slopePerSecond > 0.5)
    #expect(row.plateaued == false)
    #expect(row.leakSuspected == true)
  }

  @Test("rises then plateaus is NOT a leak suspect (bounded cache)")
  func risesThenPlateausIsNotLeak() {
    // Mirrors H5: TextLayoutCache fills toward an LRU cap, then holds flat.
    let analysis = MemoryGrowthAnalyzer.analyze(
      samples(
        provider: "cache",
        counts: [0, 64, 128, 192, 256, 256, 256, 256, 256, 256],
        step: 1.0))
    let row = analysis.rows.first { $0.provider == "cache" }!
    #expect(row.plateaued == true)
    #expect(row.leakSuspected == false)
  }

  @Test("flat series is not a leak suspect")
  func flatSeriesIsNotLeak() {
    let analysis = MemoryGrowthAnalyzer.analyze(
      samples(provider: "flat", counts: [42, 42, 42, 42, 42], step: 1.0))
    let row = analysis.rows.first { $0.provider == "flat" }!
    #expect(approx(row.slopePerSecond, 0.0))
    #expect(row.leakSuspected == false)
  }
```

- [ ] **Step 2: Run tests to verify behavior**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf --filter TermUIPerfTests.MemoryGrowthAnalyzerTests`
Expected: PASS (now 5 tests). These exercise code already written in Task 1; they should pass immediately. If `risesThenPlateausIsNotLeak` fails, inspect `isPlateaued`: for the 10-point series the tail is the last 5 (`[256,256,256,256,256]`), max==min==256, so `(max-min)=0 <= 0.05*256` → plateaued true. If it fails, the tail slicing or tolerance is off — fix the implementation, not the test.

- [ ] **Step 3: Format and commit**

```bash
cd swift-tui
swift format format -i --configuration .swift-format.json \
  Tools/TermUIPerf/Tests/TermUIPerfTests/MemoryGrowthAnalyzerTests.swift
git add Tools/TermUIPerf/Tests/TermUIPerfTests/MemoryGrowthAnalyzerTests.swift
git commit -m "test(perf): plateau vs unbounded-growth leak classification"
```

---

## Task 3: `MemoryGrowthAnalyzer.tsv` (artifact formatting)

**Files:**
- Modify: `Tools/TermUIPerf/Sources/TermUIPerf/MemoryGrowthAnalysis.swift`
- Test: `Tools/TermUIPerf/Tests/TermUIPerfTests/MemoryGrowthAnalyzerTests.swift:1` (add test)

- [ ] **Step 1: Write the failing test**

Add inside `struct MemoryGrowthAnalyzerTests`:

```swift
  @Test("tsv emits a header and one row per provider")
  func tsvEmitsHeaderAndRows() {
    let analysis = MemoryGrowthAnalyzer.analyze(
      samples(provider: "leak", counts: [0, 10, 20, 30, 40, 50, 60, 70], step: 1.0))
    let tsv = MemoryGrowthAnalyzer.tsv(analysis)

    #expect(tsv.hasPrefix("provider\tsamples\tfirst_count\tlast_count\tslope_per_s\tplateaued\tleak_suspected\n"))
    #expect(tsv.contains("leak\t8\t0\t70\t"))
    #expect(tsv.contains("\ttrue"))  // leak_suspected column
  }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf --filter TermUIPerfTests.MemoryGrowthAnalyzerTests`
Expected: FAIL — `type 'MemoryGrowthAnalyzer' has no member 'tsv'`.

- [ ] **Step 3: Write minimal implementation**

Append to `enum MemoryGrowthAnalyzer` in `MemoryGrowthAnalysis.swift` (inside the enum, after `analyze`):

```swift
  public static func tsv(_ analysis: MemoryGrowthAnalysis) -> String {
    var lines = ["provider\tsamples\tfirst_count\tlast_count\tslope_per_s\tplateaued\tleak_suspected"]
    for row in analysis.rows {
      let slope = String(format: "%.4f", row.slopePerSecond)
      lines.append(
        "\(row.provider)\t\(row.sampleCount)\t\(row.firstCount)\t\(row.lastCount)\t"
          + "\(slope)\t\(row.plateaued)\t\(row.leakSuspected)")
    }
    return lines.joined(separator: "\n") + "\n"
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf --filter TermUIPerfTests.MemoryGrowthAnalyzerTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Format and commit**

```bash
cd swift-tui
swift format format -i --configuration .swift-format.json \
  Tools/TermUIPerf/Sources/TermUIPerf/MemoryGrowthAnalysis.swift \
  Tools/TermUIPerf/Tests/TermUIPerfTests/MemoryGrowthAnalyzerTests.swift
git add Tools/TermUIPerf/Sources/TermUIPerf/MemoryGrowthAnalysis.swift \
        Tools/TermUIPerf/Tests/TermUIPerfTests/MemoryGrowthAnalyzerTests.swift
git commit -m "feat(perf): memory growth analysis tsv formatting"
```

---

## Task 4: Standardize the memory sample interval + idle window, write `memory_growth.tsv`

**Files:**
- Modify: `Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/PerfScenario.swift` (`PerfScenarioRunOptions` + `runWindow`)

- [ ] **Step 1: Add the two options to `PerfScenarioRunOptions`**

In `PerfScenario.swift`, the struct currently is (around line 78):

```swift
public struct PerfScenarioRunOptions: Equatable, Sendable {
  public var renderMode: RuntimeRenderMode
  public var iterations: Int
  public var artifactRoot: URL
  public var configuration: String
  public var terminalSize: PerfTerminalSize?
  public var cpuSampleInterval: Duration

  public init(
    renderMode: RuntimeRenderMode = .async,
    iterations: Int = PerfRunConfig.defaultIterations,
    artifactRoot: URL = URL(fileURLWithPath: PerfRunConfig.defaultArtifactsRoot, isDirectory: true),
    configuration: String = PerfRunConfig.defaultConfiguration,
    terminalSize: PerfTerminalSize? = nil,
    cpuSampleInterval: Duration = .milliseconds(50)
  ) {
    self.renderMode = renderMode
    self.iterations = iterations
    self.artifactRoot = artifactRoot
    self.configuration = configuration
    self.terminalSize = terminalSize
    self.cpuSampleInterval = cpuSampleInterval
  }
}
```

Add `memorySampleInterval` and `memoryIdleWindow` as stored properties and init parameters with defaults. Replace the struct with:

```swift
public struct PerfScenarioRunOptions: Equatable, Sendable {
  /// Default cadence for the occupancy/memory sampler (was a magic literal).
  public static let defaultMemorySampleInterval = Duration.milliseconds(500)
  /// Default post-drive idle window during which memory keeps sampling, so a
  /// bounded cache has time to reach its plateau and a leak has time to show.
  public static let defaultMemoryIdleWindow = Duration.seconds(2)

  public var renderMode: RuntimeRenderMode
  public var iterations: Int
  public var artifactRoot: URL
  public var configuration: String
  public var terminalSize: PerfTerminalSize?
  public var cpuSampleInterval: Duration
  public var memorySampleInterval: Duration
  public var memoryIdleWindow: Duration

  public init(
    renderMode: RuntimeRenderMode = .async,
    iterations: Int = PerfRunConfig.defaultIterations,
    artifactRoot: URL = URL(fileURLWithPath: PerfRunConfig.defaultArtifactsRoot, isDirectory: true),
    configuration: String = PerfRunConfig.defaultConfiguration,
    terminalSize: PerfTerminalSize? = nil,
    cpuSampleInterval: Duration = .milliseconds(50),
    memorySampleInterval: Duration = defaultMemorySampleInterval,
    memoryIdleWindow: Duration = defaultMemoryIdleWindow
  ) {
    self.renderMode = renderMode
    self.iterations = iterations
    self.artifactRoot = artifactRoot
    self.configuration = configuration
    self.terminalSize = terminalSize
    self.cpuSampleInterval = cpuSampleInterval
    self.memorySampleInterval = memorySampleInterval
    self.memoryIdleWindow = memoryIdleWindow
  }
}
```

- [ ] **Step 2: Use the options in `runWindow`**

In `PerfScenario.swift`, find the sampler start (currently `:285`):

```swift
          memoryTask = memorySampler.startSampling(interval: .milliseconds(500))
```

Replace the literal with the option:

```swift
          memoryTask = memorySampler.startSampling(interval: options.memorySampleInterval)
```

Then find the lines immediately after the `drive(...)` call returns and before `memoryTask?.cancel()` (around `:286`–`:291`):

```swift
          events = try await drive(
            PerfScenarioDriver(
              inputReader: inputReader,
              terminalHost: terminalHost
            ))
          memoryTask?.cancel()
```

Insert an idle sleep between `drive` returning and cancelling the sampler:

```swift
          events = try await drive(
            PerfScenarioDriver(
              inputReader: inputReader,
              terminalHost: terminalHost
            ))
          if options.memoryIdleWindow > .zero {
            try? await Task.sleep(for: options.memoryIdleWindow)
          }
          memoryTask?.cancel()
```

- [ ] **Step 3: Write `memory_growth.tsv` next to `memory.tsv`**

In `PerfScenario.swift`, find the `memory.tsv` write (currently `:338`–`:341`):

```swift
    try writeString(
      memorySampler.tsv(),
      to: runDirectory.appendingPathComponent("memory.tsv")
    )
```

Add a sibling write for the growth analysis immediately after it:

```swift
    try writeString(
      memorySampler.tsv(),
      to: runDirectory.appendingPathComponent("memory.tsv")
    )
    try writeString(
      MemoryGrowthAnalyzer.tsv(MemoryGrowthAnalyzer.analyze(memorySampler.samples)),
      to: runDirectory.appendingPathComponent("memory_growth.tsv")
    )
```

- [ ] **Step 4: Build + run the full package suite**

Run: `cd swift-tui && swiftly run swift build --package-path Tools/TermUIPerf`
Expected: success.
Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf`
Expected: PASS — all suites, including the existing `ScenarioSmokeTests` (it constructs `PerfScenarioRunOptions` with defaults, which now include the two new fields; defaulted, so source-compatible). The smoke test's run now also takes ~`memoryIdleWindow` longer; that is expected.

- [ ] **Step 5: Format and commit**

```bash
cd swift-tui
swift format format -i --configuration .swift-format.json \
  Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/PerfScenario.swift
git add Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/PerfScenario.swift
git commit -m "feat(perf): configurable memory sample interval + idle window, emit memory_growth.tsv"
```

---

## Task 5: Integration test — interval honored + growth artifact written

**Files:**
- Modify: `Tools/TermUIPerf/Tests/TermUIPerfTests/ScenarioSmokeTests.swift:1` (add test)

- [ ] **Step 1: Write the failing test**

Add inside `struct ScenarioSmokeTests` (after the existing tests, before the private helper):

```swift
  @Test("run writes memory_growth.tsv and honors the memory sample interval")
  @MainActor
  func runWritesMemoryGrowthArtifact() async throws {
    let artifactRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("termui-perf-memgrowth-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: artifactRoot) }

    let result = try await GalleryAnimationClickScenario().run(
      options: PerfScenarioRunOptions(
        renderMode: .sync,
        iterations: 1,
        artifactRoot: artifactRoot,
        configuration: "debug",
        cpuSampleInterval: .milliseconds(5),
        memorySampleInterval: .milliseconds(20),
        memoryIdleWindow: .milliseconds(200)))

    let growthURL = result.runDirectory.appendingPathComponent("memory_growth.tsv")
    #expect(FileManager.default.fileExists(atPath: growthURL.path))
    let growth = try String(contentsOf: growthURL, encoding: .utf8)
    #expect(growth.hasPrefix("provider\tsamples\t"))

    // With a 20ms interval over a >=200ms idle window, the sampler should have
    // collected multiple samples (a single magic-500ms sample would not).
    let memory = try String(
      contentsOf: result.runDirectory.appendingPathComponent("memory.tsv"), encoding: .utf8)
    let distinctElapsed = Set(
      memory.split(separator: "\n").dropFirst().compactMap { $0.split(separator: "\t").first })
    #expect(distinctElapsed.count >= 2)
  }
```

> If `GalleryAnimationClickScenario` is not the right ctor or its run is too
> brief for >=2 samples even at 20ms, confirm the scenario name via
> `PerfScenarioRegistry.all` and, if needed, raise `memoryIdleWindow` in the test
> to `.milliseconds(300)`. Do not weaken the artifact-existence assertion.

- [ ] **Step 2: Run the test**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf --filter TermUIPerfTests.ScenarioSmokeTests`
Expected: PASS (all smoke tests, including the new one).

- [ ] **Step 3: Format and commit**

```bash
cd swift-tui
swift format format -i --configuration .swift-format.json \
  Tools/TermUIPerf/Tests/TermUIPerfTests/ScenarioSmokeTests.swift
git add Tools/TermUIPerf/Tests/TermUIPerfTests/ScenarioSmokeTests.swift
git commit -m "test(perf): memory_growth.tsv written and sample interval honored"
```

---

## Task 6: Final gate

**Files:** none (verification only)

- [ ] **Step 1: Full TermUIPerf suite**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf`
Expected: PASS — `MemoryGrowthAnalyzerTests`, `ScenarioSmokeTests`, `AggregateReducerTests`, `AggregateComparisonTests`, `SummaryReducerTests`, `CompareCommandTests`, `PerfRunConfigTests`.

- [ ] **Step 2: Repo gate**

Run: `cd swift-tui && bun run test`
Expected: PASS (no public-surface/formatting violations; the memory occupancy types are `package`, and the new tool types add no public framework API).

- [ ] **Step 3: Smoke a real run and eyeball the growth artifact**

Run:
```bash
cd swift-tui
swiftly run swift run --package-path Tools/TermUIPerf termui-perf \
  run --scenario gallery-animation-click --modes sync --iterations 1 --configuration debug
cat .perf/runs/*/memory_growth.tsv | tail -12
```
Expected: a `memory_growth.tsv` with a header and one row per occupancy provider; `leak_suspected` should be `false` for the bounded caches over a short idle window.

- [ ] **Step 4: Record the org-root pin bump (outside this package)** — hold for user review per the established workflow; do not push or bump without confirmation.

---

## Self-Review

**Spec coverage (against the G4 section of the design doc):**
- "Add best-effort `approxBytes` to byte-heavy providers" → the three byte-heavy
  providers already report bytes; the spec said count-only is fine for trees/text
  caches. The only residual (raster cells-vs-bytes precision) is explicitly
  deferred with rationale. ✔ (scope-reduced, documented)
- "Make the idle-window duration + sample interval explicit harness config" →
  Task 4 (`memorySampleInterval` + `memoryIdleWindow` with named defaults,
  replacing the `500ms` literal). ✔
- "Add a derived growth-slope + plateau-detection metric" → Tasks 1–3
  (`MemoryGrowthAnalyzer`: least-squares slope + plateau + leak classification),
  Task 4 emits `memory_growth.tsv`. ✔
- "the leak signature (monotonic count, no plateau) is reported automatically" →
  `leakSuspected = slope > threshold && !plateaued`; Task 2 pins the H5
  bounded-cache case as NOT a leak. ✔

**Placeholder scan:** No TBD/TODO; every code step has complete code; every test
step has full assertions. The two "if X, adjust" notes (snapshot init visibility;
scenario sample count) are implementer verifications with concrete fallbacks, not
placeholders.

**Type consistency:** `MemoryGrowthRow`, `MemoryGrowthAnalysis`,
`MemoryGrowthAnalyzer.analyze`/`.tsv`, `PerfMemorySampler.Sample`,
`ProfiledMemorySnapshot`, `PerfScenarioRunOptions.memorySampleInterval`/
`.memoryIdleWindow` are referenced consistently across tasks. The `analyze`
default-parameter names match between definition (Task 1) and usage (Task 4).

**Open risks flagged:**
- `ProfiledMemorySnapshot`'s `@_spi(Runners)` init visibility in the test — Task 1
  note gives the `@_spi` import fallback.
- The smoke test's >=2-samples assertion depends on the scenario running longer
  than one interval within the idle window — Task 5 note gives a fallback.
- `bun run test` is the authority on policy/formatting; run before any pin bump.
