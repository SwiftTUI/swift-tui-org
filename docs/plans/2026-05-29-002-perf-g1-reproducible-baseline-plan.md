# Perf Hardening G1 — Reproducible Gallery Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the gallery perf hot-spots reproducible two ways: (1) committed, framework-only **synthetic scenarios** in `TermUIPerf` that reproduce the SHAPES of the hot tabs (off-screen perpetual `PhaseAnimator` → H1; continuous `repeatForever` → H4 borders; timeline-driven shimmer → H4 task-progress), runnable from a clean `swift-tui` checkout; and (2) a documented **overlay recipe** to run the real 18-tab gallery for full fidelity.

**Architecture:** The synthetic scenarios follow the existing `GalleryAnimationClickScenario` template exactly (`@_spi(Runners) import SwiftTUI`, a private probe `View`, `PerfScenarioRunner.runWindow`), add `PerfScenarioName` cases, and register in `PerfScenarioRegistry.all` (which auto-smoke-tests them). The overlay recipe is org-root documentation formalizing the `stash@{0}` recovery + `open_overlay` workflow + the report's kitty commands — no gallery path-dependency ever enters the committed `swift-tui` manifest.

**Tech Stack:** Swift 6.3, Swift Testing, SwiftPM. Package `swift-tui/Tools/TermUIPerf`; docs in `swift-tui-org/docs/perf/`.

---

## Context an engineer needs

- **Build/test:** `cd swift-tui && swiftly run swift build --package-path Tools/TermUIPerf` ; `swiftly run swift test --package-path Tools/TermUIPerf`. Format: `swift format format -i --configuration .swift-format.json <files>`. Style: 2-space indent, 100-col, `private` not `fileprivate`, no block comments.
- **Cross-repo:** synthetic scenarios + enum cases land in `swift-tui` (on a branch); the docs land in `swift-tui-org`. No org-root pin bump in this plan.
- **The scenario template (study it first):** `Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/GalleryAnimationClickScenario.swift`. It is `@_spi(Runners) import SwiftTUI`; a `struct …: PerfScenario` with `name`/`defaultTerminalSize`/`scriptedEvents`/`visualMarkers`/`settlingDescription` and a `run(options:)` that calls `PerfScenarioRunner.runWindow(scenario:options:content:drive:)`; plus a private probe `View` (`PerfAnimationProbeView` — uses `VStack`, `Text`, `Button`, `withAnimation(.linear(duration: .milliseconds(1500)))`, `.foregroundStyle`, `Color`, `.padding(1)`). Mirror this structure.
- **Key signatures (verified):**
  - `PerfScenarioRunner.runWindow<Content: View>(scenario:options:@ViewBuilder content: @escaping @MainActor () -> Content, drive: @escaping @MainActor (PerfScenarioDriver) async throws -> [PerfEventRecord])`.
  - `PerfScenarioName` (in `PerfRunConfig.swift`): `enum PerfScenarioName: String, CaseIterable, Equatable, Sendable` — add a `case` per scenario; the raw value is the `--scenario` name + artifact dir stem.
  - `PerfScenarioRegistry.all` (in `PerfScenario.swift`): array literal `[GalleryAnimationClickScenario(), LayoutScrollBurstScenario()] + additionalScenarios` — add new scenarios to the literal.
  - `PerfScenarioDriver.waitForFrame(containing:afterFrame:timeout:)` (default timeout 2s); `PerfEventRecord(eventID:eventType:dispatchTimeSeconds:expectedVisualMarker:...)`.
  - Framework animation APIs (module `SwiftTUIViews`, via `SwiftTUI`): `PhaseAnimator(_ phases: [Phase], @ViewBuilder content: (Phase) -> Content, animation: (Phase) -> Animation?)` (loop init; `Phase: Equatable & Sendable`, non-empty); `Animation.linear(duration:).repeatForever(autoreverses:)`; `withAnimation(_:_:)`; `TimelineView(_ schedule:@ViewBuilder content: (TimelineViewContext) -> Content)` with `.animation` schedule (~50ms); `Spinner`; `ScrollView(_ axes:showsIndicators:content:)`; `ForEach`.
- **Smoke-test contract:** `ScenarioSmokeTests` iterates `PerfScenarioRegistry.all` and asserts `result.presentedFrameCount > 0`, `result.events.isEmpty == false`, and that `run.json`/`frames.tsv`/`events.tsv`/`cpu.tsv`/`summary.json` exist. So every scenario's `drive` MUST return ≥1 `PerfEventRecord` and produce ≥1 presented frame.

> **Implementation note on the probe views:** the scenario skeletons, `drive` closures, enum cases, and registration below are exact. The probe `View` bodies use framework animation APIs whose precise call shapes you must confirm against the headers (`Sources/SwiftTUIViews/Animation/PhaseAnimator.swift`, `Animation.swift`, `TimelineView.swift`) and by building. Treat the view bodies as concrete starting points and adjust call sites to compile — the acceptance criterion is behavioral (see each task), not literal source match.

---

## Task 1: Off-screen `PhaseAnimator` scenario (reproduces H1)

**Files:**
- Modify: `Tools/TermUIPerf/Sources/TermUIPerf/PerfRunConfig.swift` (add enum case)
- Create: `Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/SyntheticPhaseAnimatorScenario.swift`
- Modify: `Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/PerfScenario.swift` (register in `.all`)

- [ ] **Step 1: Add the scenario name.** In `PerfRunConfig.swift`, the enum is:
```swift
public enum PerfScenarioName: String, CaseIterable, Equatable, Sendable {
  case galleryAnimationClick = "gallery-animation-click"
  case layoutScrollBurst = "layout-scroll-burst"
  ...
}
```
Add as the next case (before the `allNames` computed property):
```swift
  case syntheticOffscreenPhaseAnimator = "synthetic-offscreen-phase-animator"
```

- [ ] **Step 2: Create the scenario.** Create `SyntheticPhaseAnimatorScenario.swift`:
```swift
@_spi(Runners) import SwiftTUI

/// Reproduces H1: a perpetual `PhaseAnimator` parked below the fold of a
/// `ScrollView`, so it advances ~28fps producing zero VISIBLE damage. Idles for
/// the configured window so the frame/memory samplers capture steady state.
struct SyntheticPhaseAnimatorScenario: PerfScenario {
  let name: PerfScenarioName = .syntheticOffscreenPhaseAnimator
  let defaultTerminalSize = PerfTerminalSize(columns: 110, rows: 38)
  let scriptedEvents = ["idle while off-screen phase animator runs"]
  let visualMarkers = ["fold-top"]
  let settlingDescription = "first frame showing the visible fold-top row"

  func run(options: PerfScenarioRunOptions) async throws -> PerfScenarioRunResult {
    try await PerfScenarioRunner.runWindow(scenario: self, options: options) {
      SyntheticPhaseAnimatorProbeView()
    } drive: { driver in
      let frame = try await driver.waitForFrame(containing: "fold-top", timeout: .seconds(2))
      try await Task.sleep(for: .seconds(3))
      return [
        PerfEventRecord(
          eventID: "settled",
          eventType: "idle",
          dispatchTimeSeconds: 0,
          expectedVisualMarker: "fold-top",
          firstMatchingFrame: frame.frameNumber,
          firstMatchingTimeSeconds: frame.timestampSeconds)
      ]
    }
  }
}

private struct SyntheticPhaseAnimatorProbeView: View {
  private enum Pulse: CaseIterable, Equatable, Sendable {
    case red, yellow, green, cyan
    var color: Color {
      switch self {
      case .red: .red
      case .yellow: .yellow
      case .green: .green
      case .cyan: .cyan
      }
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        Text("fold-top")
        ForEach(1..<44) { index in
          Text("filler row \(index)")
        }
        PhaseAnimator(Array(Pulse.allCases)) { pulse in
          Text("offscreen-pulse").foregroundStyle(pulse.color)
        } animation: { _ in
          .easeInOut(duration: .milliseconds(600))
        }
      }
    }
  }
}
```

- [ ] **Step 3: Register** in `PerfScenario.swift` — change the `all` literal to include the new scenario:
```swift
    [
      GalleryAnimationClickScenario(),
      LayoutScrollBurstScenario(),
      SyntheticPhaseAnimatorScenario(),
    ] + additionalScenarios
```

- [ ] **Step 4: Build + smoke.** `cd swift-tui && swiftly run swift build --package-path Tools/TermUIPerf` then `swiftly run swift test --package-path Tools/TermUIPerf --filter TermUIPerfTests.ScenarioSmokeTests`.
Expected: PASS — the new scenario runs, presents frames, writes artifacts. **Behavioral acceptance:** if it fails to compile, fix the `PhaseAnimator`/`Text`/`Color` call sites against the real headers (the loop-mode `PhaseAnimator` init takes `[Phase]` + content + `animation:`). If the smoke test fails on `presentedFrameCount > 0` or `events.isEmpty`, the `waitForFrame("fold-top")` marker must match visible text — confirm "fold-top" renders on the first frame (it's the first VStack row); adjust the marker to a guaranteed-visible string if needed.

- [ ] **Step 5: Verify it reproduces H1 (zero visible damage while animating).** Run it directly and inspect frames:
```bash
cd swift-tui
swiftly run swift run --package-path Tools/TermUIPerf termui-perf \
  run --scenario synthetic-offscreen-phase-animator --modes async --iterations 1 --configuration debug
# inspect the newest run dir's frames.tsv: many committed frames, damage_cells ~ 0
ls -dt .perf/runs/*synthetic-offscreen-phase-animator-async* | head -1
```
Expected: multiple committed frames during the idle window with `damage_cells` 0 (or near-0) — the H1 signature. This is a manual confirmation, not an automated assertion.

- [ ] **Step 6: Format and commit**
```bash
cd swift-tui
swift format format -i --configuration .swift-format.json \
  Tools/TermUIPerf/Sources/TermUIPerf/PerfRunConfig.swift \
  Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/SyntheticPhaseAnimatorScenario.swift \
  Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/PerfScenario.swift
git add Tools/TermUIPerf/Sources/TermUIPerf/PerfRunConfig.swift \
        Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/SyntheticPhaseAnimatorScenario.swift \
        Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/PerfScenario.swift
git commit -m "feat(perf): synthetic off-screen PhaseAnimator scenario (reproduces H1)"
```

---

## Task 2: Continuous `repeatForever` scenario (reproduces H4 borders)

**Files:**
- Modify: `Tools/TermUIPerf/Sources/TermUIPerf/PerfRunConfig.swift`
- Create: `Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/SyntheticRepeatForeverScenario.swift`
- Modify: `Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/PerfScenario.swift`

- [ ] **Step 1: Add the name** in `PerfRunConfig.swift`:
```swift
  case syntheticContinuousAnimation = "synthetic-continuous-animation"
```

- [ ] **Step 2: Create** `SyntheticRepeatForeverScenario.swift`:
```swift
@_spi(Runners) import SwiftTUI

/// Reproduces H4 (borders): a `repeatForever` animation that drives VISIBLE,
/// non-zero damage every tick during idle (unlike H1's off-screen zero-damage).
struct SyntheticRepeatForeverScenario: PerfScenario {
  let name: PerfScenarioName = .syntheticContinuousAnimation
  let defaultTerminalSize = PerfTerminalSize(columns: 110, rows: 38)
  let scriptedEvents = ["idle while continuous animation repaints"]
  let visualMarkers = ["continuous-anim"]
  let settlingDescription = "first frame showing the continuous animation label"

  func run(options: PerfScenarioRunOptions) async throws -> PerfScenarioRunResult {
    try await PerfScenarioRunner.runWindow(scenario: self, options: options) {
      SyntheticContinuousProbeView()
    } drive: { driver in
      let frame = try await driver.waitForFrame(containing: "continuous-anim", timeout: .seconds(2))
      try await Task.sleep(for: .seconds(3))
      return [
        PerfEventRecord(
          eventID: "settled",
          eventType: "idle",
          dispatchTimeSeconds: 0,
          expectedVisualMarker: "continuous-anim",
          firstMatchingFrame: frame.frameNumber,
          firstMatchingTimeSeconds: frame.timestampSeconds)
      ]
    }
  }
}

private struct SyntheticContinuousProbeView: View {
  @State private var phase: Double = 0.0

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("continuous-anim")
      // A continuously interpolated value that re-renders visible output each
      // tick, producing real per-frame damage.
      Text("phase \(phase, format: .number.precision(.fractionLength(2)))")
        .padding(1)
    }
    .onAppear {
      withAnimation(.linear(duration: .milliseconds(2000)).repeatForever(autoreverses: true)) {
        phase = 1.0
      }
    }
  }
}
```

- [ ] **Step 3: Register** `SyntheticRepeatForeverScenario()` in the `PerfScenarioRegistry.all` literal (after the Task 1 scenario).

- [ ] **Step 4: Build + smoke** (same commands as Task 1, filter `ScenarioSmokeTests`). **Behavioral acceptance:** confirm the scenario produces MULTIPLE committed frames with `damage_cells > 0` during idle (continuous repaint). If `Text("phase \(phase, ...)")` does not re-render per tick (i.e. the framework doesn't surface the interpolated `@State` mid-animation as changing text), switch the visible driver to one that demonstrably animates — e.g. animate `.foregroundStyle` across a color set, or use the gallery's chasing-light pattern (`.border` with an animated phase). The acceptance criterion is continuous non-zero damage; adjust the view until the run shows it. The string-interpolation form `\(phase, format:)` may need to be `String(format: "phase %.2f", phase)` — use whichever compiles.

- [ ] **Step 5: Format and commit**
```bash
cd swift-tui
swift format format -i --configuration .swift-format.json \
  Tools/TermUIPerf/Sources/TermUIPerf/PerfRunConfig.swift \
  Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/SyntheticRepeatForeverScenario.swift \
  Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/PerfScenario.swift
git add Tools/TermUIPerf/Sources/TermUIPerf/PerfRunConfig.swift \
        Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/SyntheticRepeatForeverScenario.swift \
        Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/PerfScenario.swift
git commit -m "feat(perf): synthetic continuous repeatForever scenario (reproduces H4 borders)"
```

---

## Task 3: Timeline-driven shimmer scenario (reproduces H4 task-progress / H5 text churn)

**Files:**
- Modify: `Tools/TermUIPerf/Sources/TermUIPerf/PerfRunConfig.swift`
- Create: `Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/SyntheticShimmerScenario.swift`
- Modify: `Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/PerfScenario.swift`

- [ ] **Step 1: Add the name** in `PerfRunConfig.swift`:
```swift
  case syntheticTextShimmer = "synthetic-text-shimmer"
```

- [ ] **Step 2: Create** `SyntheticShimmerScenario.swift`:
```swift
@_spi(Runners) import SwiftTUI

/// Reproduces the Task-Progress shape: a `TimelineView(.animation)`-driven
/// shimmer whose TEXT content changes every tick (~20fps), exercising the
/// per-frame text-layout path (the H5 `TextLayoutCache` churn).
struct SyntheticShimmerScenario: PerfScenario {
  let name: PerfScenarioName = .syntheticTextShimmer
  let defaultTerminalSize = PerfTerminalSize(columns: 110, rows: 38)
  let scriptedEvents = ["idle while text shimmer animates"]
  let visualMarkers = ["shimmer"]
  let settlingDescription = "first frame showing the shimmer label"

  func run(options: PerfScenarioRunOptions) async throws -> PerfScenarioRunResult {
    try await PerfScenarioRunner.runWindow(scenario: self, options: options) {
      SyntheticShimmerProbeView()
    } drive: { driver in
      let frame = try await driver.waitForFrame(containing: "shimmer", timeout: .seconds(2))
      try await Task.sleep(for: .seconds(3))
      return [
        PerfEventRecord(
          eventID: "settled",
          eventType: "idle",
          dispatchTimeSeconds: 0,
          expectedVisualMarker: "shimmer",
          firstMatchingFrame: frame.frameNumber,
          firstMatchingTimeSeconds: frame.timestampSeconds)
      ]
    }
  }
}

private struct SyntheticShimmerProbeView: View {
  var body: some View {
    TimelineView(.animation) { context in
      // Distinct text per tick -> a fresh layout key each frame (H5 churn).
      Text("shimmer \(shimmerColumn(at: context))")
    }
  }

  private func shimmerColumn(at context: TimelineViewContext) -> String {
    // Render a moving block of ~10 columns; the exact instant->phase math should
    // be derived from context.instant (a MonotonicInstant). Produce a string
    // that changes every tick. Adjust to the real TimelineViewContext API.
    String(repeating: "=", count: 1)
  }
}
```

- [ ] **Step 3: Register** `SyntheticShimmerScenario()` in the `PerfScenarioRegistry.all` literal.

- [ ] **Step 4: Build + smoke.** **Behavioral acceptance:** the scenario must produce continuous frames during idle with the shimmer text CHANGING per tick (so each frame mints a fresh text-layout key — the H5 churn). Confirm the `TimelineView(.animation)` + `TimelineViewContext` API against `Sources/SwiftTUIViews/.../TimelineView.swift`: derive a per-tick-varying value from `context.instant` (a `MonotonicInstant`; use its elapsed-duration accessor). If `TimelineView` proves awkward, fall back to the framework `Spinner(.asteriskCycle, stage: .active, interval: .milliseconds(240))` as the animating element — either reproduces an animated-text shape. The criterion: continuous frames with changing text content.

- [ ] **Step 5: Format and commit**
```bash
cd swift-tui
swift format format -i --configuration .swift-format.json \
  Tools/TermUIPerf/Sources/TermUIPerf/PerfRunConfig.swift \
  Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/SyntheticShimmerScenario.swift \
  Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/PerfScenario.swift
git add Tools/TermUIPerf/Sources/TermUIPerf/PerfRunConfig.swift \
        Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/SyntheticShimmerScenario.swift \
        Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/PerfScenario.swift
git commit -m "feat(perf): synthetic text-shimmer scenario (reproduces task-progress/H5 churn)"
```

---

## Task 4: `docs/perf/README.md` + overlay recipe (org-root docs)

**Files:**
- Create: `docs/perf/README.md` (in `swift-tui-org`, NOT the submodule)

This task is documentation only, committed to the `swift-tui-org` root (where the other perf docs live).

- [ ] **Step 1: Write `docs/perf/README.md`** with three tiers:

```markdown
# Performance Scenarios & Baselines

Two ways to reproduce SwiftTUI's perf hot-spots, plus a real-terminal cross-check.

## Tier 1 — Everyday: committed synthetic scenarios (no overlay)

Framework-only scenarios in `swift-tui/Tools/TermUIPerf` that reproduce the SHAPES
of the hot gallery tabs. Reproducible from a clean `swift-tui` checkout:

| Scenario (`--scenario`) | Reproduces | Shape |
| --- | --- | --- |
| `synthetic-offscreen-phase-animator` | H1 | perpetual off-screen `PhaseAnimator` → zero-visible-damage frames |
| `synthetic-continuous-animation` | H4 (borders) | `repeatForever` → continuous non-zero damage |
| `synthetic-text-shimmer` | H4 (task-progress) / H5 | per-tick text churn → `TextLayoutCache` misses |

    cd swift-tui
    swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
      run --scenario synthetic-offscreen-phase-animator --modes async \
      --iterations 20 --configuration release

Each run writes `frames.tsv`, `cpu.tsv`, `memory.tsv`, `memory_growth.tsv`,
`summary.json`, plus per-mode `aggregate-*.json` (run-to-run variance, G2) and the
growth/plateau analysis (G4). Compare two runs with `termui-perf compare`.

## Tier 2 — Full fidelity: the real 18-tab gallery (overlay)

The real `GalleryView` scenarios depend on the `swift-tui-examples/gallery` package,
so they CANNOT be committed to the public `swift-tui` manifest. They live as a
coordination-only overlay. To run them:

1. Recover the coordination scenarios into an overlay working tree (they are held
   in `swift-tui`'s `git stash@{0}` — `GalleryTabScenario`, `CommandPaletteScenario`,
   `GalleryScenarioRegistration`, the `main.swift` hook, and the `Package.swift` +
   `PerfRunConfig.swift` gallery additions):

       cd swift-tui-org
       eval "$(bazel run //:open_overlay -- --print-env examples 2>/dev/null)"
       git -C swift-tui stash show -p stash@{0} | git -C "$SWIFTTUI_CHECKOUT" apply

2. Run a gallery tab from the overlay (the overlay's `Package.swift` carries the
   gallery path-dep; the committed one never does):

       cd "$SWIFTTUI_CHECKOUT"
       swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
         run --scenario gallery-animations --modes async --iterations 1 --configuration release

> The overlay is a throwaway copy; edits there are not carried back. See
> [docs/CROSS-REPO-DEVELOPMENT.md](../CROSS-REPO-DEVELOPMENT.md).

## Tier 3 — Authentic terminal (kitty)

Cross-check presentation cost on a real terminal (opens a GUI window):

    BIN=swift-tui-examples/gallery/.build/arm64-apple-macosx/release/gallery-demo
    SWIFTTUI_PROFILE="frames,cpu,memory@1s;tsv=/tmp/anim.tsv" \
      kitty -o allow_remote_control=yes --listen-on unix:/tmp/k \
      -o initial_window_width=110c -o initial_window_height=38c \
      -e "$PWD/$BIN" --tab animations &
    sleep 15; kitty @ --to unix:/tmp/k close-window

## Baselines

- `2026-05-28-gallery-baseline/` — the original 18-tab data-collection pass.
- Report: [../reports/2026-05-28-gallery-performance-report.md](../reports/2026-05-28-gallery-performance-report.md).
```

- [ ] **Step 2: Verify the overlay-recovery command is accurate.** Before committing, confirm `git -C swift-tui stash list` still shows the gallery scenarios at `stash@{0}` (`git -C swift-tui stash show --stat stash@{0}` should list `GalleryTabScenario.swift` etc.). If the stash index has shifted, update the README's `stash@{N}` reference to the correct entry. If the stash is gone, note that the scenarios must be re-created from the 2026-05-28 report's §8 description and flag it.

- [ ] **Step 3: Commit** (in the org root):
```bash
cd swift-tui-org
git add docs/perf/README.md
git commit -m "docs(perf): reproduction guide — synthetic scenarios + overlay + kitty tiers"
```

---

## Task 5: Final gate

- [ ] **Step 1: Full TermUIPerf suite** — `cd swift-tui && swiftly run swift test --package-path Tools/TermUIPerf` → all suites pass; `ScenarioSmokeTests` now exercises 3 more scenarios.
- [ ] **Step 2: Repo gate** — `cd swift-tui && bun run test` → PASS (the 3 new `PerfScenarioName` cases + scenarios are tool-only; no public framework API).
- [ ] **Step 3: List scenarios** — `swiftly run swift run --package-path Tools/TermUIPerf termui-perf list` → shows the 3 `synthetic-*` names alongside the originals.
- [ ] **Step 4:** Hold the org-root pin bump for user review (per the established workflow).

---

## Self-Review

**Spec coverage (G1 section of the design doc):**
- "Committed synthetic scenarios … off-screen PhaseAnimator, continuous repeatForever border, shimmer" → Tasks 1–3, framework-only, auto-smoke-tested. ✔
- "Overlay path … materialize the real Gallery scenarios via open_overlay … gallery path-dep lives only in the overlay" → Task 4 documents the `stash@{0}` + `open_overlay` recovery; nothing gallery-coupled is committed to `swift-tui`. ✔
- "`docs/perf/README.md`: everyday → synthetic; full-fidelity → overlay" → Task 4. ✔

**Placeholder scan:** Scenario skeletons, `drive` closures, enum cases, registration, and the README are complete. The probe-view *bodies* carry explicit behavioral acceptance criteria + "adjust call sites to compile/animate" notes because the framework animation call shapes must be confirmed against headers by building — this is honest guided-implementation for view code, not a TODO. No "implement later" left.

**Type consistency:** `PerfScenarioName` cases (`syntheticOffscreenPhaseAnimator`/`syntheticContinuousAnimation`/`syntheticTextShimmer`) and their raw values match between the enum, each scenario's `name`, the registry literal, and the README's `--scenario` table.

**Open risks flagged:**
- Probe-view animation behavior (does interpolated `@State` / `TimelineView` surface changing visible output per tick?) is the real uncertainty — each task's Step 4 makes the criterion behavioral and gives a concrete fallback (animate `.foregroundStyle`; use `Spinner`).
- `stash@{0}` index could shift — Task 4 Step 2 verifies before committing the recipe.
- The smoke test requires `events.isEmpty == false` and `presentedFrameCount > 0` — every `drive` returns a "settled" record after waiting for a guaranteed-visible marker.
