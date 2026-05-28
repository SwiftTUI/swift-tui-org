# Perf Hardening G2 — Run-to-Run Variance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `TermUIPerf` harness actually run N iterations of a scenario and report cross-iteration variance (median ± stddev, CV), plus a significance verdict in `CompareCommand`, so a perf delta can be judged signal vs. noise.

**Architecture:** Reuse `PerfScenarioRunner.runWindow` **unchanged** as the single-iteration primitive. Add a thin loop in `RunCommand` that invokes it N times per render mode and collects the N `PerfSummary`s. A new pure `AggregateReducer` turns `[PerfSummary]` into a `PerfAggregateSummary` of per-metric `PerfStat`s. `CompareCommand` gains a pure aggregate comparison that flags each metric `real` only when the median delta exceeds a noise band derived from the samples' stddev. New logic is overwhelmingly pure functions, TDD'd exactly like the existing `SummaryReducerTests`/`CompareCommandTests`.

**Tech Stack:** Swift 6.3 (Swift 6 language mode), Swift Testing (`import Testing`, `@Test`, `#expect`), SwiftPM. Package under `swift-tui/Tools/TermUIPerf` (separate package; product `TermUIPerf`, test target `TermUIPerfTests`).

---

## Context an engineer needs before starting

- **Where this runs.** All changes are in the `swift-tui` child repo, package
  `Tools/TermUIPerf`. Build/test that package with the pinned toolchain:
  ```bash
  cd swift-tui
  swiftly run swift build --package-path Tools/TermUIPerf
  swiftly run swift test  --package-path Tools/TermUIPerf
  swiftly run swift test  --package-path Tools/TermUIPerf --filter TermUIPerfTests.AggregateReducerTests
  ```
- **Formatting (pre-commit will enforce):** 2-space indent, 100-col lines,
  `private` (not `fileprivate`). Format with
  `swift format format -i --configuration .swift-format.json Tools/TermUIPerf/Sources Tools/TermUIPerf/Tests`.
- **Cross-repo workflow.** Commit each change **inside `swift-tui`** (this plan's
  `git` commands run there). The org-root pin bump (`git add swift-tui && git
  commit`) happens once at the end, outside this plan.
- **Key existing types (do not redefine):**
  - `PerfSummary` (in `SummaryReducer.swift`): has `scenario: String`,
    `renderMode: String`, `iterationCount: Int`, `committedFrameCount: Int`,
    `totalCPUSeconds: Double`, `cpuSecondsPerCommittedFrame: Double?`,
    `inputToPresentLatencyMs: PerfDistribution`, `frameIntervalMs:
    PerfDistribution`, and more. `PerfDistribution` has `count: Int`, `p50/p95/p99:
    Double?`.
  - `PerfScenarioRunResult` (in `Scenarios/PerfScenario.swift`): has
    `runDirectory: URL`, `metadata: PerfRunMetadata`, `summary: PerfSummary`, etc.
  - `RunCommand.run(_ config: PerfRunConfig) async throws -> [PerfScenarioRunResult]`
    (in `RunCommand.swift`): currently loops `config.modes`, calls
    `scenario.run(options:)` **once** per mode. `--iterations` is unused.
  - `PerfScenarioRunOptions(renderMode:iterations:artifactRoot:configuration:terminalSize:cpuSampleInterval:)`
    — each `scenario.run` writes its own unique timestamped run directory.
  - `main.swift` `.run` case consumes `[PerfScenarioRunResult]` and prints each
    `runDirectory.path`.
- **Stat conventions for this plan:** population sample uses **sample stddev**
  (Bessel's correction, `/(n-1)`) for `n > 1`, and `0` for `n <= 1`. Median is the
  middle value (odd `n`) or mean of the two middle values (even `n`). Coefficient
  of variation is `stddev / mean`, and `0` when `mean == 0`.

---

## File structure

- **Create** `Tools/TermUIPerf/Sources/TermUIPerf/AggregateSummary.swift`
  — `PerfStat`, `PerfAggregateSummary`, `AggregateReducer` (reduce + format).
- **Create** `Tools/TermUIPerf/Sources/TermUIPerf/AggregateComparison.swift`
  — `SignificanceVerdict`, `AggregateMetricComparison`, `AggregateComparison`,
  and `CompareCommand.compareAggregates(...)` + `format(_:)` (in an extension).
- **Modify** `Tools/TermUIPerf/Sources/TermUIPerf/RunCommand.swift`
  — loop N iterations per mode; return a new `PerfRunOutcome`; write `aggregate-*.json`.
- **Modify** `Tools/TermUIPerf/Sources/TermUIPerf/main.swift`
  — update the `.run` case for the new return type; print aggregate summaries.
- **Create** `Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateReducerTests.swift`
- **Create** `Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateComparisonTests.swift`
- **Modify** `Tools/TermUIPerf/Tests/TermUIPerfTests/ScenarioSmokeTests.swift`
  — add an N-iteration `RunCommand` test.

---

## Task 1: `PerfStat` value type

**Files:**
- Create: `Tools/TermUIPerf/Sources/TermUIPerf/AggregateSummary.swift`
- Test: `Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateReducerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateReducerTests.swift`:

```swift
import Foundation
import Testing

@testable import TermUIPerf

struct AggregateReducerTests {
  @Test("PerfStat computes median, mean, sample stddev, min/max, CV")
  func perfStatComputesSummaryStatistics() {
    let stat = PerfStat(values: [2, 4, 4, 4, 5, 5, 7, 9])

    #expect(stat.sampleCount == 8)
    #expect(approx(stat.mean, 5.0))
    #expect(approx(stat.median, 4.5))
    #expect(approx(stat.stddev, 2.138_089_935))  // sample stddev (n-1)
    #expect(approx(stat.min, 2.0))
    #expect(approx(stat.max, 9.0))
    #expect(approx(stat.coefficientOfVariation, 0.427_617_987))
  }

  @Test("PerfStat with one value has zero stddev and zero CV")
  func perfStatSingleValueIsZeroSpread() {
    let stat = PerfStat(values: [3.5])

    #expect(stat.sampleCount == 1)
    #expect(approx(stat.median, 3.5))
    #expect(approx(stat.mean, 3.5))
    #expect(approx(stat.stddev, 0.0))
    #expect(approx(stat.coefficientOfVariation, 0.0))
  }

  @Test("PerfStat with zero mean reports zero CV, not NaN")
  func perfStatZeroMeanReportsZeroCV() {
    let stat = PerfStat(values: [0, 0, 0])

    #expect(approx(stat.mean, 0.0))
    #expect(approx(stat.stddev, 0.0))
    #expect(approx(stat.coefficientOfVariation, 0.0))
  }

  private func approx(_ actual: Double, _ expected: Double) -> Bool {
    abs(actual - expected) < 0.000_001
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf --filter TermUIPerfTests.AggregateReducerTests`
Expected: FAIL — `cannot find 'PerfStat' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Tools/TermUIPerf/Sources/TermUIPerf/AggregateSummary.swift`:

```swift
import Foundation

/// Cross-iteration summary statistics for a single scalar metric.
public struct PerfStat: Codable, Equatable, Sendable {
  public var sampleCount: Int
  public var median: Double
  public var mean: Double
  public var stddev: Double
  public var min: Double
  public var max: Double
  public var coefficientOfVariation: Double

  public init(
    sampleCount: Int,
    median: Double,
    mean: Double,
    stddev: Double,
    min: Double,
    max: Double,
    coefficientOfVariation: Double
  ) {
    self.sampleCount = sampleCount
    self.median = median
    self.mean = mean
    self.stddev = stddev
    self.min = min
    self.max = max
    self.coefficientOfVariation = coefficientOfVariation
  }

  /// Builds a stat from raw samples. Sample stddev (Bessel's correction) for
  /// `count > 1`, else `0`. CV is `0` when the mean is `0`.
  public init(values: [Double]) {
    let count = values.count
    guard count > 0 else {
      self.init(
        sampleCount: 0, median: 0, mean: 0, stddev: 0, min: 0, max: 0,
        coefficientOfVariation: 0)
      return
    }
    let sorted = values.sorted()
    let mean = values.reduce(0, +) / Double(count)
    let median: Double
    if count % 2 == 1 {
      median = sorted[count / 2]
    } else {
      median = (sorted[count / 2 - 1] + sorted[count / 2]) / 2
    }
    let stddev: Double
    if count > 1 {
      let sumSquares = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
      stddev = (sumSquares / Double(count - 1)).squareRoot()
    } else {
      stddev = 0
    }
    let cv = mean == 0 ? 0 : stddev / mean
    self.init(
      sampleCount: count,
      median: median,
      mean: mean,
      stddev: stddev,
      min: sorted.first ?? 0,
      max: sorted.last ?? 0,
      coefficientOfVariation: cv)
  }

  private enum CodingKeys: String, CodingKey {
    case sampleCount = "sample_count"
    case median
    case mean
    case stddev
    case min
    case max
    case coefficientOfVariation = "coefficient_of_variation"
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf --filter TermUIPerfTests.AggregateReducerTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Format and commit**

```bash
cd swift-tui
swift format format -i --configuration .swift-format.json \
  Tools/TermUIPerf/Sources/TermUIPerf/AggregateSummary.swift \
  Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateReducerTests.swift
git add Tools/TermUIPerf/Sources/TermUIPerf/AggregateSummary.swift \
        Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateReducerTests.swift
git commit -m "feat(perf): add PerfStat cross-iteration statistics"
```

---

## Task 2: `PerfAggregateSummary` + `AggregateReducer.reduce`

**Files:**
- Modify: `Tools/TermUIPerf/Sources/TermUIPerf/AggregateSummary.swift`
- Test: `Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateReducerTests.swift:1` (add tests)

- [ ] **Step 1: Write the failing test**

Add these tests inside `struct AggregateReducerTests` (before the private helpers):

```swift
  @Test("AggregateReducer reduces per-iteration summaries into per-metric stats")
  func aggregateReducerReducesSummaries() {
    let aggregate = AggregateReducer.reduce([
      summary(cpuSeconds: 5.0, committed: 270, latencyP95: 22.0, intervalP50: 36.0),
      summary(cpuSeconds: 5.4, committed: 274, latencyP95: 24.0, intervalP50: 36.0),
      summary(cpuSeconds: 5.8, committed: 278, latencyP95: 26.0, intervalP50: 36.0),
    ])

    #expect(aggregate.scenario == "gallery-animation-click")
    #expect(aggregate.renderMode == "async")
    #expect(aggregate.iterationCount == 3)
    #expect(approx(aggregate.totalCPUSeconds.median, 5.4))
    #expect(approx(aggregate.totalCPUSeconds.mean, 5.4))
    #expect(aggregate.committedFrameCount.sampleCount == 3)
    #expect(approx(aggregate.committedFrameCount.median, 274))
    #expect(approx(aggregate.inputToPresentLatencyP95Ms.median, 24.0))
    #expect(approx(aggregate.frameIntervalP50Ms.stddev, 0.0))
  }

  @Test("AggregateReducer drops nil optional metrics before aggregating")
  func aggregateReducerSkipsNilMetrics() {
    let aggregate = AggregateReducer.reduce([
      summary(cpuSeconds: 5.0, committed: 270, latencyP95: nil, intervalP50: 36.0),
      summary(cpuSeconds: 5.4, committed: 274, latencyP95: 24.0, intervalP50: 36.0),
    ])

    // Only one summary had a non-nil latency p95, so the stat has one sample.
    #expect(aggregate.inputToPresentLatencyP95Ms.sampleCount == 1)
    #expect(approx(aggregate.inputToPresentLatencyP95Ms.median, 24.0))
    #expect(aggregate.totalCPUSeconds.sampleCount == 2)
  }
```

Add this private helper alongside the others:

```swift
  private func summary(
    cpuSeconds: Double,
    committed: Int,
    latencyP95: Double?,
    intervalP50: Double?
  ) -> PerfSummary {
    PerfSummary(
      scenario: "gallery-animation-click",
      renderMode: "async",
      iterationCount: 1,
      committedFrameCount: committed,
      skippedFrameCount: 0,
      inputToPresentLatencyMs: PerfDistribution(count: 1, p50: nil, p95: latencyP95, p99: nil),
      inputToSettledLatencyMs: PerfDistribution(count: 0, p50: nil, p95: nil, p99: nil),
      frameIntervalMs: PerfDistribution(count: 1, p50: intervalP50, p95: nil, p99: nil),
      totalCPUSeconds: cpuSeconds,
      cpuSecondsPerCommittedFrame: cpuSeconds / Double(committed),
      cpuSecondsPerInputEvent: nil,
      mainActorBlockedRatio: nil,
      mainActorSuspendedRatio: nil,
      workerLayoutEnqueueMs: PerfDistribution(count: 0, p50: nil, p95: nil, p99: nil),
      workerLayoutComputeMs: PerfDistribution(count: 0, p50: nil, p95: nil, p99: nil),
      workerRasterEnqueueMs: PerfDistribution(count: 0, p50: nil, p95: nil, p99: nil),
      workerRasterComputeMs: PerfDistribution(count: 0, p50: nil, p95: nil, p99: nil),
      presentationDurationMs: PerfDistribution(count: 0, p50: nil, p95: nil, p99: nil),
      cancellationCount: 0,
      completedDropCount: 0,
      customLayoutFallbackCount: 0,
      layoutDependentMainActorFallbackCount: 0)
  }
```

> Note: `PerfSummary` is a memberwise-`init` struct (no custom init); the call
> above lists every stored property in declaration order. If a property is added
> to `PerfSummary` later, this helper must be updated.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf --filter TermUIPerfTests.AggregateReducerTests`
Expected: FAIL — `cannot find 'AggregateReducer' in scope`.

- [ ] **Step 3: Write minimal implementation**

Append to `Tools/TermUIPerf/Sources/TermUIPerf/AggregateSummary.swift`:

```swift
/// Cross-iteration aggregate over the headline metrics of N `PerfSummary`s.
public struct PerfAggregateSummary: Codable, Equatable, Sendable {
  public var scenario: String
  public var renderMode: String
  public var iterationCount: Int
  public var totalCPUSeconds: PerfStat
  public var committedFrameCount: PerfStat
  public var cpuSecondsPerCommittedFrame: PerfStat
  public var inputToPresentLatencyP95Ms: PerfStat
  public var frameIntervalP50Ms: PerfStat

  public init(
    scenario: String,
    renderMode: String,
    iterationCount: Int,
    totalCPUSeconds: PerfStat,
    committedFrameCount: PerfStat,
    cpuSecondsPerCommittedFrame: PerfStat,
    inputToPresentLatencyP95Ms: PerfStat,
    frameIntervalP50Ms: PerfStat
  ) {
    self.scenario = scenario
    self.renderMode = renderMode
    self.iterationCount = iterationCount
    self.totalCPUSeconds = totalCPUSeconds
    self.committedFrameCount = committedFrameCount
    self.cpuSecondsPerCommittedFrame = cpuSecondsPerCommittedFrame
    self.inputToPresentLatencyP95Ms = inputToPresentLatencyP95Ms
    self.frameIntervalP50Ms = frameIntervalP50Ms
  }

  private enum CodingKeys: String, CodingKey {
    case scenario
    case renderMode = "render_mode"
    case iterationCount = "iteration_count"
    case totalCPUSeconds = "total_cpu_seconds"
    case committedFrameCount = "committed_frame_count"
    case cpuSecondsPerCommittedFrame = "cpu_seconds_per_committed_frame"
    case inputToPresentLatencyP95Ms = "input_to_present_latency_p95_ms"
    case frameIntervalP50Ms = "frame_interval_p50_ms"
  }
}

public enum AggregateReducer {
  /// Reduces per-iteration summaries into one aggregate. The `summaries` array
  /// must be non-empty; scenario/renderMode are taken from the first element.
  public static func reduce(_ summaries: [PerfSummary]) -> PerfAggregateSummary {
    precondition(!summaries.isEmpty, "AggregateReducer.reduce requires >= 1 summary")
    let first = summaries[0]
    return PerfAggregateSummary(
      scenario: first.scenario,
      renderMode: first.renderMode,
      iterationCount: summaries.count,
      totalCPUSeconds: PerfStat(values: summaries.map(\.totalCPUSeconds)),
      committedFrameCount: PerfStat(values: summaries.map { Double($0.committedFrameCount) }),
      cpuSecondsPerCommittedFrame: PerfStat(
        values: summaries.compactMap(\.cpuSecondsPerCommittedFrame)),
      inputToPresentLatencyP95Ms: PerfStat(
        values: summaries.compactMap(\.inputToPresentLatencyMs.p95)),
      frameIntervalP50Ms: PerfStat(values: summaries.compactMap(\.frameIntervalMs.p50)))
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf --filter TermUIPerfTests.AggregateReducerTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Format and commit**

```bash
cd swift-tui
swift format format -i --configuration .swift-format.json \
  Tools/TermUIPerf/Sources/TermUIPerf/AggregateSummary.swift \
  Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateReducerTests.swift
git add Tools/TermUIPerf/Sources/TermUIPerf/AggregateSummary.swift \
        Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateReducerTests.swift
git commit -m "feat(perf): aggregate per-iteration summaries into PerfAggregateSummary"
```

---

## Task 3: `AggregateReducer.format` (human-readable `median ± stddev (CV%)`)

**Files:**
- Modify: `Tools/TermUIPerf/Sources/TermUIPerf/AggregateSummary.swift`
- Test: `Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateReducerTests.swift:1` (add test)

- [ ] **Step 1: Write the failing test**

Add inside `struct AggregateReducerTests`:

```swift
  @Test("AggregateReducer.format renders median +/- stddev and CV percent")
  func aggregateReducerFormatsHumanReadableSummary() {
    let aggregate = AggregateReducer.reduce([
      summary(cpuSeconds: 5.0, committed: 270, latencyP95: 22.0, intervalP50: 36.0),
      summary(cpuSeconds: 5.4, committed: 274, latencyP95: 24.0, intervalP50: 36.0),
      summary(cpuSeconds: 5.8, committed: 278, latencyP95: 26.0, intervalP50: 36.0),
    ])

    let output = AggregateReducer.format(aggregate)

    #expect(output.contains("scenario: gallery-animation-click (async, n=3)"))
    #expect(output.contains("total CPU seconds: 5.4000 +/- 0.4000"))
    #expect(output.contains("CV 7.4%"))
    #expect(output.contains("committed frames:"))
  }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf --filter TermUIPerfTests.AggregateReducerTests`
Expected: FAIL — `type 'AggregateReducer' has no member 'format'`.

- [ ] **Step 3: Write minimal implementation**

Append to `AggregateReducer` in `Tools/TermUIPerf/Sources/TermUIPerf/AggregateSummary.swift`:

```swift
extension AggregateReducer {
  public static func format(_ aggregate: PerfAggregateSummary) -> String {
    var lines = [
      "scenario: \(aggregate.scenario) (\(aggregate.renderMode), n=\(aggregate.iterationCount))"
    ]
    lines.append(line("total CPU seconds", aggregate.totalCPUSeconds))
    lines.append(line("committed frames", aggregate.committedFrameCount))
    lines.append(line("CPU seconds/frame", aggregate.cpuSecondsPerCommittedFrame))
    lines.append(line("input latency p95 ms", aggregate.inputToPresentLatencyP95Ms))
    lines.append(line("frame interval p50 ms", aggregate.frameIntervalP50Ms))
    return lines.joined(separator: "\n")
  }

  private static func line(_ label: String, _ stat: PerfStat) -> String {
    let median = String(format: "%.4f", stat.median)
    let stddev = String(format: "%.4f", stat.stddev)
    let cv = String(format: "%.1f", stat.coefficientOfVariation * 100)
    return "\(label): \(median) +/- \(stddev) (CV \(cv)%)"
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf --filter TermUIPerfTests.AggregateReducerTests`
Expected: PASS (6 tests).

> If the CV assertion is off by rounding, confirm: stddev of `[5.0,5.4,5.8]` is
> `0.4`, mean `5.4`, CV `0.074074… → 7.4%`. The assertion matches.

- [ ] **Step 5: Format and commit**

```bash
cd swift-tui
swift format format -i --configuration .swift-format.json \
  Tools/TermUIPerf/Sources/TermUIPerf/AggregateSummary.swift \
  Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateReducerTests.swift
git add Tools/TermUIPerf/Sources/TermUIPerf/AggregateSummary.swift \
        Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateReducerTests.swift
git commit -m "feat(perf): human-readable aggregate summary formatting"
```

---

## Task 4: Run N iterations in `RunCommand` and surface aggregates

**Files:**
- Modify: `Tools/TermUIPerf/Sources/TermUIPerf/RunCommand.swift` (entire file)
- Modify: `Tools/TermUIPerf/Sources/TermUIPerf/main.swift:28-32`

This task changes `RunCommand.run`'s return type, so `main.swift` updates in lockstep. No unit test here (it drives real scenarios); Task 5 adds the integration test.

- [ ] **Step 1: Replace `RunCommand.run` with the iterating version**

Replace the entire body of `Tools/TermUIPerf/Sources/TermUIPerf/RunCommand.swift` with:

```swift
import Foundation

/// Result of a perf run: every per-iteration result, plus one aggregate per mode.
public struct PerfRunOutcome: Sendable {
  public var perIteration: [PerfScenarioRunResult]
  public var aggregates: [PerfAggregateSummary]

  public init(perIteration: [PerfScenarioRunResult], aggregates: [PerfAggregateSummary]) {
    self.perIteration = perIteration
    self.aggregates = aggregates
  }
}

public enum RunCommand {
  @MainActor
  public static func run(_ config: PerfRunConfig) async throws -> PerfRunOutcome {
    guard let scenario = PerfScenarioRegistry.scenario(named: config.scenario) else {
      throw PerfParseError.unknownScenario(config.scenario.rawValue)
    }

    let artifactRoot = URL(fileURLWithPath: config.artifactsRoot, isDirectory: true)
    var perIteration: [PerfScenarioRunResult] = []
    var aggregates: [PerfAggregateSummary] = []

    for mode in config.modes {
      var modeSummaries: [PerfSummary] = []
      for _ in 0..<config.iterations {
        let result = try await scenario.run(
          options: PerfScenarioRunOptions(
            renderMode: mode,
            iterations: 1,
            artifactRoot: artifactRoot,
            configuration: config.configuration
          ))
        modeSummaries.append(result.summary)
        perIteration.append(result)
      }
      let aggregate = AggregateReducer.reduce(modeSummaries)
      aggregates.append(aggregate)
      try writeAggregate(aggregate, to: artifactRoot)
    }

    return PerfRunOutcome(perIteration: perIteration, aggregates: aggregates)
  }

  /// Writes `aggregate-<scenario>-<mode>.json` at the artifact root so
  /// `CompareCommand.compareAggregates` can load it later.
  private static func writeAggregate(
    _ aggregate: PerfAggregateSummary,
    to artifactRoot: URL
  ) throws {
    try FileManager.default.createDirectory(
      at: artifactRoot, withIntermediateDirectories: true)
    let name = "aggregate-\(aggregate.scenario)-\(aggregate.renderMode).json"
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(aggregate)
    try data.write(to: artifactRoot.appendingPathComponent(name))
  }
}
```

> `config.iterations` defaults to 20 (`PerfRunConfig.defaultIterations`). Each
> per-iteration `scenario.run` honestly stamps `iteration_count = 1` in its own
> `run.json`; the aggregate records the true N. `runWindow` is untouched.

- [ ] **Step 2: Update `main.swift` for the new return type**

In `Tools/TermUIPerf/Sources/TermUIPerf/main.swift`, replace the `.run` case (currently lines 28-32):

```swift
  case .run(let config):
    let outcome = try await RunCommand.run(config)
    for result in outcome.perIteration {
      print(result.runDirectory.path)
    }
    for aggregate in outcome.aggregates {
      print(AggregateReducer.format(aggregate))
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `cd swift-tui && swiftly run swift build --package-path Tools/TermUIPerf`
Expected: Build succeeds. (If `main.swift` still references `results`, fix it to `outcome.perIteration`.)

- [ ] **Step 4: Run the full package test suite to verify nothing regressed**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf`
Expected: PASS — existing `SummaryReducerTests`, `CompareCommandTests`,
`PerfRunConfigTests`, `ScenarioSmokeTests` all still green (the smoke test calls
`scenario.run` directly, unaffected).

- [ ] **Step 5: Format and commit**

```bash
cd swift-tui
swift format format -i --configuration .swift-format.json \
  Tools/TermUIPerf/Sources/TermUIPerf/RunCommand.swift \
  Tools/TermUIPerf/Sources/TermUIPerf/main.swift
git add Tools/TermUIPerf/Sources/TermUIPerf/RunCommand.swift \
        Tools/TermUIPerf/Sources/TermUIPerf/main.swift
git commit -m "feat(perf): run N iterations and emit per-mode aggregates"
```

---

## Task 5: Integration test — N iterations produce N run dirs + an aggregate file

**Files:**
- Modify: `Tools/TermUIPerf/Tests/TermUIPerfTests/ScenarioSmokeTests.swift:1` (add test)

- [ ] **Step 1: Write the failing test**

Add this test inside `struct ScenarioSmokeTests` (after the existing test):

```swift
  @Test("RunCommand runs N iterations and writes one aggregate per mode")
  @MainActor
  func runCommandRunsIterationsAndWritesAggregate() async throws {
    let artifactRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("termui-perf-iterate-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: artifactRoot) }

    let config = PerfRunConfig(
      scenario: .galleryAnimationClick,
      modes: [.sync],
      iterations: 2,
      artifactsRoot: artifactRoot.path,
      configuration: "debug")

    let outcome = try await RunCommand.run(config)

    #expect(outcome.perIteration.count == 2)
    #expect(outcome.aggregates.count == 1)
    #expect(outcome.aggregates[0].iterationCount == 2)
    #expect(outcome.aggregates[0].totalCPUSeconds.sampleCount == 2)

    let aggregateFile = artifactRoot
      .appendingPathComponent("aggregate-gallery-animation-click-sync.json")
    #expect(FileManager.default.fileExists(atPath: aggregateFile.path))
  }
```

> Verify the `PerfRunConfig(...)` argument labels against
> `PerfRunConfig.swift` before running; the memberwise initializer there takes
> `scenario`, `modes`, `iterations`, `artifactsRoot`, `configuration` (and
> optional fields). The scenario name `.galleryAnimationClick` and aggregate
> filename stem `gallery-animation-click` come from
> `PerfScenarioName`/`GalleryAnimationClickScenario`.

- [ ] **Step 2: Run test to verify it fails (or passes)**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf --filter TermUIPerfTests.ScenarioSmokeTests`
Expected: PASS if Task 4 is complete. If the aggregate filename stem differs
(check the scenario's `name.rawValue`), adjust the expected filename to match
`aggregate-<name.rawValue>-sync.json` and re-run.

- [ ] **Step 3: (If the test failed on the filename) reconcile the stem**

If the filename assertion failed, print the real name once to confirm the stem,
then fix the assertion:

Run: `cd swift-tui && swiftly run swift run --package-path Tools/TermUIPerf termui-perf list`
Expected: prints scenario names; use the printed `gallery-animation-click`
spelling in the test's expected filename.

- [ ] **Step 4: Format and commit**

```bash
cd swift-tui
swift format format -i --configuration .swift-format.json \
  Tools/TermUIPerf/Tests/TermUIPerfTests/ScenarioSmokeTests.swift
git add Tools/TermUIPerf/Tests/TermUIPerfTests/ScenarioSmokeTests.swift
git commit -m "test(perf): N-iteration run writes aggregate artifact"
```

---

## Task 6: Significance verdict — `compareAggregates`

**Files:**
- Create: `Tools/TermUIPerf/Sources/TermUIPerf/AggregateComparison.swift`
- Test: `Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateComparisonTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateComparisonTests.swift`:

```swift
import Foundation
import Testing

@testable import TermUIPerf

struct AggregateComparisonTests {
  @Test("delta beyond the noise band is flagged real")
  func deltaBeyondNoiseBandIsReal() {
    // base CPU ~5.4 +/- 0.4; candidate ~3.0 +/- 0.4. 2-sigma band = 0.8.
    let comparison = CompareCommand.compareAggregates(
      base: aggregate(cpuValues: [5.0, 5.4, 5.8]),
      candidate: aggregate(cpuValues: [2.6, 3.0, 3.4]))

    let cpu = try! #require(metric(comparison, "total CPU seconds"))
    #expect(cpu.verdict == .real)
    #expect(approx(cpu.delta, -2.4))
  }

  @Test("delta within the noise band is flagged within noise")
  func deltaWithinNoiseBandIsWithinNoise() {
    // base ~5.4 +/- 0.4; candidate ~5.5 +/- 0.4. 2-sigma band = 0.8 > |0.1|.
    let comparison = CompareCommand.compareAggregates(
      base: aggregate(cpuValues: [5.0, 5.4, 5.8]),
      candidate: aggregate(cpuValues: [5.1, 5.5, 5.9]))

    let cpu = try! #require(metric(comparison, "total CPU seconds"))
    #expect(cpu.verdict == .withinNoise)
  }

  @Test("single-sample inputs are inconclusive (no noise estimate)")
  func singleSampleIsInconclusive() {
    let comparison = CompareCommand.compareAggregates(
      base: aggregate(cpuValues: [5.0]),
      candidate: aggregate(cpuValues: [3.0]))

    let cpu = try! #require(metric(comparison, "total CPU seconds"))
    #expect(cpu.verdict == .inconclusive)
  }

  private func metric(
    _ comparison: AggregateComparison,
    _ name: String
  ) -> AggregateMetricComparison? {
    comparison.metrics.first { $0.metric == name }
  }

  private func aggregate(cpuValues: [Double]) -> PerfAggregateSummary {
    PerfAggregateSummary(
      scenario: "gallery-animation-click",
      renderMode: "async",
      iterationCount: cpuValues.count,
      totalCPUSeconds: PerfStat(values: cpuValues),
      committedFrameCount: PerfStat(values: cpuValues.map { _ in 274 }),
      cpuSecondsPerCommittedFrame: PerfStat(values: cpuValues.map { $0 / 274 }),
      inputToPresentLatencyP95Ms: PerfStat(values: cpuValues.map { _ in 22 }),
      frameIntervalP50Ms: PerfStat(values: cpuValues.map { _ in 36 }))
  }

  private func approx(_ actual: Double, _ expected: Double) -> Bool {
    abs(actual - expected) < 0.000_001
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf --filter TermUIPerfTests.AggregateComparisonTests`
Expected: FAIL — `type 'CompareCommand' has no member 'compareAggregates'`.

- [ ] **Step 3: Write minimal implementation**

Create `Tools/TermUIPerf/Sources/TermUIPerf/AggregateComparison.swift`:

```swift
import Foundation

public enum SignificanceVerdict: String, Codable, Equatable, Sendable {
  case real = "real"
  case withinNoise = "within noise"
  case inconclusive = "inconclusive"
}

public struct AggregateMetricComparison: Codable, Equatable, Sendable {
  public var metric: String
  public var baseMedian: Double
  public var candidateMedian: Double
  public var delta: Double
  public var noiseBand: Double
  public var verdict: SignificanceVerdict

  public init(
    metric: String,
    baseMedian: Double,
    candidateMedian: Double,
    delta: Double,
    noiseBand: Double,
    verdict: SignificanceVerdict
  ) {
    self.metric = metric
    self.baseMedian = baseMedian
    self.candidateMedian = candidateMedian
    self.delta = delta
    self.noiseBand = noiseBand
    self.verdict = verdict
  }
}

public struct AggregateComparison: Codable, Equatable, Sendable {
  public var scenario: String
  public var metrics: [AggregateMetricComparison]

  public init(scenario: String, metrics: [AggregateMetricComparison]) {
    self.scenario = scenario
    self.metrics = metrics
  }
}

extension CompareCommand {
  /// Number of standard deviations the median delta must exceed to be "real".
  public static let defaultNoiseSigma = 2.0

  public static func compareAggregates(
    base: PerfAggregateSummary,
    candidate: PerfAggregateSummary,
    sigma: Double = defaultNoiseSigma
  ) -> AggregateComparison {
    let metrics = [
      metricComparison(
        "total CPU seconds", base.totalCPUSeconds, candidate.totalCPUSeconds, sigma),
      metricComparison(
        "committed frames", base.committedFrameCount, candidate.committedFrameCount, sigma),
      metricComparison(
        "CPU seconds/frame", base.cpuSecondsPerCommittedFrame,
        candidate.cpuSecondsPerCommittedFrame, sigma),
      metricComparison(
        "input latency p95 ms", base.inputToPresentLatencyP95Ms,
        candidate.inputToPresentLatencyP95Ms, sigma),
      metricComparison(
        "frame interval p50 ms", base.frameIntervalP50Ms, candidate.frameIntervalP50Ms, sigma),
    ]
    return AggregateComparison(scenario: base.scenario, metrics: metrics)
  }

  private static func metricComparison(
    _ name: String,
    _ base: PerfStat,
    _ candidate: PerfStat,
    _ sigma: Double
  ) -> AggregateMetricComparison {
    let delta = candidate.median - base.median
    let noiseBand = sigma * Swift.max(base.stddev, candidate.stddev)
    let verdict: SignificanceVerdict
    if base.sampleCount < 2 || candidate.sampleCount < 2 {
      verdict = .inconclusive
    } else if abs(delta) > noiseBand {
      verdict = .real
    } else {
      verdict = .withinNoise
    }
    return AggregateMetricComparison(
      metric: name,
      baseMedian: base.median,
      candidateMedian: candidate.median,
      delta: delta,
      noiseBand: noiseBand,
      verdict: verdict)
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf --filter TermUIPerfTests.AggregateComparisonTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Format and commit**

```bash
cd swift-tui
swift format format -i --configuration .swift-format.json \
  Tools/TermUIPerf/Sources/TermUIPerf/AggregateComparison.swift \
  Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateComparisonTests.swift
git add Tools/TermUIPerf/Sources/TermUIPerf/AggregateComparison.swift \
        Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateComparisonTests.swift
git commit -m "feat(perf): significance verdict for aggregate comparisons"
```

---

## Task 7: Format `AggregateComparison` for terminal output

**Files:**
- Modify: `Tools/TermUIPerf/Sources/TermUIPerf/AggregateComparison.swift`
- Test: `Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateComparisonTests.swift:1` (add test)

- [ ] **Step 1: Write the failing test**

Add inside `struct AggregateComparisonTests`:

```swift
  @Test("format renders per-metric verdict lines")
  func formatRendersVerdictLines() {
    let comparison = CompareCommand.compareAggregates(
      base: aggregate(cpuValues: [5.0, 5.4, 5.8]),
      candidate: aggregate(cpuValues: [2.6, 3.0, 3.4]))

    let output = CompareCommand.format(comparison)

    #expect(output.contains("scenario: gallery-animation-click"))
    #expect(output.contains("total CPU seconds: 5.4000 -> 3.0000"))
    #expect(output.contains("[real]"))
  }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf --filter TermUIPerfTests.AggregateComparisonTests`
Expected: FAIL — ambiguous/no `format` overload for `AggregateComparison`.

- [ ] **Step 3: Write minimal implementation**

Append to the `extension CompareCommand` in
`Tools/TermUIPerf/Sources/TermUIPerf/AggregateComparison.swift`:

```swift
extension CompareCommand {
  public static func format(_ comparison: AggregateComparison) -> String {
    var lines = ["scenario: \(comparison.scenario)"]
    for metric in comparison.metrics {
      let base = String(format: "%.4f", metric.baseMedian)
      let candidate = String(format: "%.4f", metric.candidateMedian)
      let delta = String(format: "%+.4f", metric.delta)
      let band = String(format: "%.4f", metric.noiseBand)
      lines.append(
        "\(metric.metric): \(base) -> \(candidate) (\(delta), band \(band)) "
          + "[\(metric.verdict.rawValue)]")
    }
    return lines.joined(separator: "\n")
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf --filter TermUIPerfTests.AggregateComparisonTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Format and commit**

```bash
cd swift-tui
swift format format -i --configuration .swift-format.json \
  Tools/TermUIPerf/Sources/TermUIPerf/AggregateComparison.swift \
  Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateComparisonTests.swift
git add Tools/TermUIPerf/Sources/TermUIPerf/AggregateComparison.swift \
        Tools/TermUIPerf/Tests/TermUIPerfTests/AggregateComparisonTests.swift
git commit -m "feat(perf): format aggregate comparison with verdicts"
```

---

## Task 8: Final gate

**Files:** none (verification only)

- [ ] **Step 1: Run the full TermUIPerf test suite**

Run: `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf`
Expected: PASS — all suites
(`AggregateReducerTests`, `AggregateComparisonTests`, `SummaryReducerTests`,
`CompareCommandTests`, `PerfRunConfigTests`, `ScenarioSmokeTests`).

- [ ] **Step 2: Run the repo gate**

Run: `cd swift-tui && bun run test`
Expected: PASS (shared suite + policy checks; confirms no formatting or
public-surface violations from the new files).

- [ ] **Step 3: Smoke a real 2-iteration run end to end**

Run:
```bash
cd swift-tui
swiftly run swift run --package-path Tools/TermUIPerf termui-perf \
  run --scenario gallery-animation-click --modes sync --iterations 2 --configuration debug
```
Expected: prints 2 run-directory paths followed by an aggregate block
(`total CPU seconds: … +/- … (CV …%)`), and an
`aggregate-gallery-animation-click-sync.json` exists under `.perf/runs` (or the
configured artifacts root).

- [ ] **Step 4: Record the org-root pin bump (outside this package)**

```bash
cd ..                      # org root: swift-tui-org
git add swift-tui
git commit -m "chore: bump swift-tui pin — perf G2 run-to-run variance"
```

> Note: commit the `swift-tui` child changes (Tasks 1-7) and push them in the
> child repo before recording this pin, per the org workflow in the root
> `AGENTS.md`.

---

## Self-Review

**Spec coverage (against the G2 section of the design doc):**
- "Execute N iterations" → Task 4 (RunCommand loop) + Task 5 (integration test). ✔
- "New pure `AggregateReducer.reduce → PerfAggregateSummary`" with median/mean/
  stddev/min/max/CV → Tasks 1-2. ✔
- Headline metrics (`total_cpu_seconds`, `committed_frame_count`,
  `cpu_seconds_per_committed_frame`, latency p95, frame interval p50) → Task 2
  (`PerfAggregateSummary` fields). ✔
- "`summary.json` gains an aggregate block; stderr prints `median ± stddev (CV%)`"
  → realized as a separate `aggregate-*.json` file (Task 4) + `AggregateReducer.format`
  printed by `main.swift` (Tasks 3-4). *Deviation from spec wording:* a dedicated
  aggregate file is cleaner than mutating the per-iteration `summary.json`, and
  each iteration keeps its own honest `summary.json`. Functionally equivalent.
- "`CompareCommand` significance verdict … CI non-overlap or |Δ| > k·stddev" →
  Task 6 implements the `|Δmedian| > sigma·max(stddev)` form with
  `defaultNoiseSigma = 2.0`. ✔
- Within-run percentiles remain per-iteration (untouched `runWindow`/`SummaryReducer`). ✔

**Placeholder scan:** No TBD/TODO; every code step has complete code; every test
step has full assertions. ✔

**Type consistency:** `PerfStat`, `PerfAggregateSummary`, `AggregateReducer`,
`PerfRunOutcome`, `SignificanceVerdict`, `AggregateMetricComparison`,
`AggregateComparison`, `CompareCommand.compareAggregates`,
`CompareCommand.format(_: AggregateComparison)` are referenced consistently
across tasks. `PerfStat(values:)`, `PerfDistribution(count:p50:p95:p99:)`, and the
`PerfSummary` memberwise init match the real existing signatures verified in
`SummaryReducer.swift`/`PerfArtifacts.swift`.

**Open risks flagged for the implementer:**
- The `PerfSummary` test helper (Task 2) hard-codes the memberwise init; if a
  field is added to `PerfSummary`, update the helper.
- The aggregate filename stem depends on `PerfScenarioName.rawValue`; Task 5
  Step 3 reconciles it if the guess is wrong.
- `bun run test` (Task 8) is the authority on formatting/public-surface policy;
  run it before the pin bump.
