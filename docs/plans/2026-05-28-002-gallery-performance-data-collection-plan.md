# Gallery Performance Data-Collection Pass — Implementation Plan

> **For agentic workers:** Execute this plan phase by phase. It is an
> **investigation/measurement** plan, not a feature build — the deliverable is
> *evidence and a report*, not shipped behavior. This pass spans two child repos
> (`swift-tui`, `swift-tui-examples`) and is therefore **coordination-only work**:
> run it from the `swift-tui-org` root against the **dev overlay**, and do **not**
> commit profiling-enablement or harness edits into the public child manifests
> (see [Boundary constraints](#boundary-constraints)). Steps use checkbox
> (`- [ ]`) syntax for tracking.

**Goal:** Find high-value, evidence-backed SwiftTUI performance improvement
opportunities by turning on the framework's own profiling product across the
example gallery, measuring every tab and the command palette in an authentic
terminal, and reporting ranked, root-caused hot spots — especially surprising
ones.

**Architecture:** Reuse what already exists. The framework ships a complete
profiling **data layer** (`SwiftTUIProfiling`: per-frame `FrameDiagnosticRecord`,
CPU sampler, memory/occupancy provider registry, TSV/JSONL/summary sinks) and a
deterministic in-process **harness shape** (`Tools/TermUIPerf`'s
`PerfScenarioRunner.runWindow` + `PerfTerminalHost` + `PerfScriptedInputReader`).
Neither currently drives the **real** `GalleryView`. We (1) enable profiling in
the gallery, (2) extend the existing harness to host the real gallery per tab,
(3) add a kitty-based authentic-terminal cross-check, (4) record falsifiable
predictions, (5) collect per-tab data, (6) analyze for hot spots and surprises,
(7) write a report.

**Tech Stack:** Swift 6.3.1, SwiftPM, `SwiftTUIProfiling`, `SwiftTUIRuntime`
(`@_spi(Runners)` seams), `Tools/TermUIPerf`, the `gallery-demo` example, kitty
remote control, Bazel/Bzlmod overlay tooling (`//:open_overlay`), `swiftly`.

---

## Current findings (evidence gathered before planning)

All paths below were read directly; line numbers are from the working tree at
plan-authoring time (org pin `da00d4c`).

### Profiling data layer — exists and is rich

- `SwiftTUIProfiling` is a real product/target:
  `swift-tui/Package.swift:100` (product), `:184-190` (target),
  sources under `swift-tui/Sources/SwiftTUIProfiling/`.
- **Activation is opt-in via a scene modifier, not the env var alone.**
  `Scene.profiling(_:)` →
  `swift-tui/Sources/SwiftTUIProfiling/Activation/ProfilingSceneModifier.swift:31`.
  Its `body` calls `ProfileActivation.shared.activateIfNeeded(config:)`
  (`ProfilingSceneModifier.swift:20`). `activateIfNeeded`
  (`Activation/ProfileActivation.swift:29-39`) parses `SWIFTTUI_PROFILE`
  **only when reached through `.profiling()`**. With no `.profiling()` in the
  scene tree, setting `SWIFTTUI_PROFILE` does nothing.
- `SWIFTTUI_PROFILE` grammar (verified in
  `Activation/EnvProfileParser.swift:1-10`):
  ```
  SWIFTTUI_PROFILE = signal-list [ ";" sink-list ]
  signal           = "frames" | "memory" [ "@" duration ] | "cpu" [ "@" duration ]
  sink             = "tsv=" path | "jsonl=" path | "summary"
  duration         = e.g. 100ms, 1s, 2s500ms
  ```
  Malformed input → `nil` → profiling stays fully off. Defaults: memory `1s`,
  cpu `250ms` (`EnvProfileParser.swift:67-71`, `ProfileConfig`).
- Sinks: with no sink named, activation falls back to a stderr `SummarySink`
  (`ProfileActivation.swift:131-147`). `summary` buffers and only flushes on
  `ProfileActivation.shared.finish()` (`ProfileActivation.swift:88-96`); `tsv`/
  `jsonl` (`FileProfileSink`) write incrementally and do **not** require
  `finish()`.
- Per-frame record `FrameDiagnosticRecord`
  (`swift-tui/Sources/SwiftTUIRuntime/Diagnostics/FrameDiagnosticRecord.swift`)
  carries ~82 fields: per-phase timings (resolve/measure/place/semantics/draw/
  raster/commit), node computed-vs-reused counts at each phase,
  `presentationStrategy` (full/incremental), `presentationBytesWritten`,
  `presentationCellsChanged`, damage stats, `focusSyncRerenders`, drop decisions,
  animation/pointer/gesture counts, worker and main-actor timings.
- Memory signal: `MemoryMetricCollector` reads a `MemoryMetricRegistry` of
  per-store providers; per-graph stores register on create and deregister on
  teardown, so a leaked graph shows as a never-deregistering provider —
  surfaced as synthetic `MemoryMetricRegistry.providerCount`. CPU via
  `CPUSampler` (user/system seconds, `estimatedCPUPercent`, `maxResidentBytes`).
- **Historical signal:** the profiling-product proposal
  (`docs/plans/2026-05-28-001-profiling-product.md:36-39`) records that the
  motivating investigation found **~1 MB/s growth on the gallery's borders
  pane**. Treat borders/animations as prior-art leak suspects.

### Existing harness — right shape, wrong subject

- `Tools/TermUIPerf` (`termui-perf`) already provides everything a harness needs
  *except* the real gallery:
  - `PerfScenarioRunner.runWindow(...)`
    (`Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/PerfScenario.swift:222-336`)
    hosts a `WindowGroup { content() }`, wires an in-memory `PerfTerminalHost`
    (`PresentationSurface`), a `PerfScriptedInputReader` (`TerminalInputReading`),
    an `InProcessSignalReader`, and a `TSVFileSink` for frames, then runs the
    real `SceneSession`/`RunLoop`, collects CPU via `CPUSampler.collect`, and
    writes `run.json`, `events.tsv`, `cpu.tsv`, `summary.json` per run.
  - `PerfScenarioDriver` (`PerfScenario.swift:138-180`) exposes
    `waitForFrame(containing:)`, `cell(containing:)`, `sendClick(at:)`,
    `sendScroll(deltaY:at:)`.
  - Render-mode sweep + baseline compare exist:
    `Scripts/run_perf_smoke.sh` runs `--modes sync,async --iterations 1
    --configuration release` and then `termui-perf compare`.
- **The gap:** the two shipped scenarios host *stub* views, not the gallery.
  `GalleryAnimationClickScenario`
  (`Scenarios/GalleryAnimationClickScenario.swift:45-63`) renders a 3-element
  `PerfAnimationProbeView`, **not** `GalleryView`. `LayoutScrollBurstScenario`
  is likewise synthetic. So the existing tool measures the *runtime in
  isolation* against an *in-memory* surface — it does not measure real gallery
  content, and it never touches a real terminal write path.

### The gallery — launch contract and content

- Executable product `gallery-demo`; entry
  `swift-tui-examples/gallery/Sources/GalleryDemo/GalleryDemoApp.swift`.
  Scene is `WindowGroup { GalleryView(initialTab: tab) }` (`:17-21`). It accepts
  `--tab <key>` (`@Option var tab: GalleryView.GalleryTab?`, `:14-15`).
  **It does not import `SwiftTUIProfiling` and does not call `.profiling()`.**
- `GalleryDemo` target deps:
  `swift-tui-examples/gallery/Package.swift` — depends on `swift-tui` at
  **`exact: "0.0.5"`** (tagged HTTPS), products `SwiftTUI`, `SwiftTUIRuntime`,
  `SwiftTUIAnimatedImage`, `SwiftTUICharts`, and (test target only)
  `SwiftTUITestSupport`. `SwiftTUIProfiling` is **not** referenced.
- 18 tabs, each launchable directly via `--tab <key>`. Verified `key` strings
  (`gallery/Sources/GalleryDemoViews/GalleryView.swift:197-320`):

  | Tab (case) | `--tab` key | Render cost tier (predicted) |
  | --- | --- | --- |
  | counter | `counter` | 3 (event-driven; hue animation on tick) |
  | life | `life` | 1 (Canvas + ~110 ms auto-tick) |
  | todo | `todo` | 3 |
  | formsAndContainers | `forms-and-containers` | 3 (scroll) |
  | textInput | `text-input` | 3 |
  | scrollControl | `scroll-control` | 2 (scroll bursts) |
  | calculator | `calculator` | 3 |
  | bordersAndShapes | `borders-and-shapes` | 1 (3 s chasing-light + Canvas sparkline; **leak suspect**) |
  | presentationLab | `presentation-lab` | 2 (modals/overlays) |
  | navigationCollections | `navigation-collections` | 2 (OutlineGroup/Table) |
  | images | `images` | 2 (PNG/JPEG/animated GIF) |
  | animations | `animations` | 1 (multi-curve; **leak suspect**) |
  | fileDrop | `file-drop` | 3 |
  | popovers | `popovers` | 2 |
  | pointerLab | `pointer-lab` | 2 (gestures) |
  | focusContext | `focus-context` | 3 (focus publish/consume) |
  | physics | `physics` | 1 (Canvas + 40 ms tick) |
  | taskProgress | `task-progress` | 1 (50 ms shimmer + 240 ms spinner + 1 s script) |

- Command palette: opened with **Ctrl+K**
  (`GalleryView.swift:76-81`, `key: .character("k"), modifiers: .ctrl`);
  implemented in `gallery/Sources/GalleryDemoViews/CommandPalette.swift`. Inside:
  type to fuzzy-filter, Arrow-Up/Down or Tab/Shift-Tab to move selection, Return
  to execute, Escape to dismiss.

### Authentic-terminal tooling — none yet

- No `kitty`/`tmux`/`expect`/`pty` automation exists in the org. The framework
  *does* have a low-level `ScenePty`
  (`swift-tui/Platforms/CLI/Sources/SwiftTUICLI/ScenePty.swift`), but there is no
  scripted real-terminal runner. kitty remote control is the lightest authentic
  option and is what this plan uses for the cross-check.

### Boundary constraints (org `AGENTS.md`)

- Public child repos (`swift-tui`, `swift-tui-examples`) must build from a fresh
  clone with native tools and consume siblings only via **tagged HTTPS deps**.
- Untagged/cross-repo consumption (e.g. the gallery using the *org-pinned*
  `swift-tui` that has `SwiftTUIProfiling`, or `TermUIPerf` depending on the
  gallery sources) is **coordination-only** and belongs in `swift-tui-org` via
  the overlay — **never committed** to a public child's default manifest.
- The overlay is purpose-built for exactly this: `bazel run //:open_overlay`
  materializes working trees and prints env (`docs/CROSS-REPO-DEVELOPMENT.md`).

---

## Non-goals

- Do **not** make any performance *fix* in this pass. This is data collection +
  reporting only. Fixes are follow-up plans informed by the report.
- Do **not** commit `.profiling()` enablement or the gallery-hosting harness into
  the public child default manifests. Keep them on the overlay / a throwaway
  worktree, or behind a clearly coordination-only target.
- Do **not** replace `TermUIPerf`'s synthetic scenarios; **add** alongside them.
- Do **not** change the runtime scheduler, render pipeline, or any tab's
  behavior to make numbers look better.
- Do **not** chase byte-exact heap accounting; occupancy counts + slopes are the
  signal here (Instruments/heaptrack remain the answer for exact heap work).

---

## File structure

Files created or modified, by repo. Everything here is **coordination/overlay
scope** unless explicitly noted as a candidate permanent change.

### `swift-tui-examples` (gallery) — profiling enablement (overlay scope)

- Modify `gallery/Package.swift`
  - Add `SwiftTUIProfiling` to the `GalleryDemo` target's dependencies.
- Modify `gallery/Sources/GalleryDemo/GalleryDemoApp.swift`
  - `import SwiftTUIProfiling`; wrap the `WindowGroup` body with `.profiling()`;
    arrange a shutdown call to `ProfileActivation.shared.finish()` so the
    `summary` sink flushes (not required for `tsv`/`jsonl`).

### `swift-tui` — gallery-hosting harness (overlay scope)

- Create
  `Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/GalleryTabScenario.swift`
  - A `PerfScenario` family that hosts the **real** `GalleryView(initialTab:)`
    via `PerfScenarioRunner.runWindow`, parameterized by tab key + a scripted
    interaction closure.
- Create
  `Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/CommandPaletteScenario.swift`
  - Hosts `GalleryView()` and drives Ctrl+K open → filter → select.
- Modify `Tools/TermUIPerf/Package.swift`
  - Add a path dependency on the gallery's `GalleryDemoViews` library product so
    scenarios can import the real views. **Coordination-only** — must not be
    committed to the public `swift-tui` manifest; keep on the overlay/worktree.
- Modify `Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/PerfScenario.swift`
  - Register the new scenarios in `PerfScenarioRegistry.all` and add their
    `PerfScenarioName` cases.

### `swift-tui` — authentic-terminal driver (script, overlay scope)

- Create `Tools/perf-gallery/run_gallery_kitty.sh`
  - Launches `gallery-demo --tab <key>` in kitty with remote control enabled and
    `SWIFTTUI_PROFILE` set, drives scripted input via `kitty @`, collects the
    TSV, and quits. (Lives under the coordination workflow; not a public gate.)

### `swift-tui-org` — outputs (committed)

- Create `docs/perf/2026-05-28-gallery-baseline/` (artifact landing dir:
  per-tab run dirs, aggregated CSV, the kitty cross-check).
- Create `docs/reports/2026-05-28-gallery-performance-report.md` (the
  step-7 deliverable).

---

## Phase 0 — Confirm seams, boundary, and overlay (spike)

> **RESULTS (2026-05-28, executed):**
> - `SwiftTUIProfiling` is **not** in tag `0.0.5` (the gallery's pinned
>   dependency). It exists only on the current `swift-tui` submodule HEAD
>   (latest tag `v0.1.0`). The gallery binary therefore cannot link profiling
>   against its tagged dependency.
> - `GalleryView` / `GalleryView.GalleryTab` are `public` with
>   `public init(initialTab:)` — importable from a harness target.
> - `SwiftTUITestSupport` (`Tests/Support`) exposes **only synchronization
>   primitives** (`ConditionSignal`, `MainActorConditionSignal`, `StageClock`,
>   `AsyncEvent`), all `@_spi(Testing)`. It has **no** scene runner, in-memory
>   surface, or scripted input reader. The reusable run harness
>   (`PerfScenarioRunner.runWindow`, `PerfTerminalHost`, `PerfScriptedInputReader`)
>   lives inside the `termui-perf` executable target only.
> - **Decision — Route A, harness hosted in `TermUIPerf`.** Add gallery-hosting
>   scenarios inside `Tools/TermUIPerf` with a local **path** dependency on the
>   gallery (`GalleryDemoViews`). `TermUIPerf` already depends on `swift-tui` via
>   `path: "../.."` (HEAD, has `SwiftTUIProfiling`); SwiftPM's local-path
>   override resolves the gallery's `exact: 0.0.5` to that same local checkout,
>   so the **dev overlay is not required for the in-process route** (to be
>   confirmed by the Phase 3A build). Harness edits stay uncommitted in the
>   `swift-tui` submodule working tree (`.perf/` is gitignored).
> - **Route B (authentic terminal via kitty) is DEFERRED to a future phase** at
>   the user's direction. Phase 1B, Phase 3B, and the kitty parts of Phase 5 are
>   out of scope for this pass.

Resolve the two real unknowns before writing harness code.

- [ ] **Step 0.1 — Confirm `SwiftTUIProfiling` availability for the gallery.**
  The gallery pins `swift-tui` at `exact: "0.0.5"`. Confirm whether that tag
  exposes the `SwiftTUIProfiling` product.

  Run:
  ```bash
  cd /Users/adamz/Developer/swift-tui-org
  git -C swift-tui tag --contains $(git -C swift-tui rev-parse HEAD) | grep -x 0.0.5 || echo "HEAD not in 0.0.5"
  git -C swift-tui show 0.0.5:Package.swift | grep -n "SwiftTUIProfiling" || echo "SwiftTUIProfiling NOT in tag 0.0.5"
  ```
  Expected: most likely `SwiftTUIProfiling NOT in tag 0.0.5` (the product is on
  the org pin, ahead of the tag). If so, the pass **must** run against the local
  `swift-tui` checkout via the overlay (Step 0.3), not the tagged dependency.

- [ ] **Step 0.2 — Confirm the gallery views are importable from a harness
  target.** Verify `GalleryDemoViews` is a library product (it is, per
  `gallery/Package.swift` `products`) and that `GalleryView` and
  `GalleryView.GalleryTab` are `public` (they are:
  `GalleryView.swift:111`, the type is `public enum`). This confirms the
  `TermUIPerf → GalleryDemoViews` path-dependency route is viable.

  Run:
  ```bash
  grep -n "public struct GalleryView\|public enum GalleryTab\|public init" \
    swift-tui-examples/gallery/Sources/GalleryDemoViews/GalleryView.swift
  ```
  Expected: `public` declarations for the view, the tab enum, and an init that
  accepts `initialTab:`.

- [ ] **Step 0.3 — Materialize the overlay and capture env.**
  ```bash
  mise trust && mise install
  mise exec -- bazel run //:open_overlay -- --print-env examples > /tmp/overlay-env.sh
  cat /tmp/overlay-env.sh        # inspect the exported overlay paths
  . /tmp/overlay-env.sh          # bring overlay paths into the shell
  ```
  Expected: rsync'd working trees under `.build/coordination/dev-overlay/` and
  `export` lines pointing the gallery at the local `swift-tui`. This is where
  all enablement/harness edits live for the pass.

- [ ] **Step 0.4 — Decide enablement route and record it.** Two acceptable
  routes; pick one and note it in the report's methodology:
  - **Route A (recommended): in-process harness via `TermUIPerf`** hosting the
    real `GalleryView`. No need to ship `.profiling()` in the gallery binary —
    the harness installs sinks the same way `runWindow` already does (it passes
    a `TSVFileSink` as `frameSink` directly). This is the lowest-friction path
    and reuses 100% of existing infra.
  - **Route B: authentic binary** — add `.profiling()` to `GalleryDemoApp`
    (overlay scope) and run the real `gallery-demo` under kitty. Required for the
    terminal-write-path cross-check (Phase 3B), optional otherwise.

  Default: do **both** — Route A for the bulk per-tab matrix (deterministic,
  cheap, comparable), Route B for the authenticity cross-check on Tier-1 tabs.

---

## Phase 1 — Enable the profiling tooling in the gallery

Two enablement surfaces matching the two routes.

### 1A — In-process (Route A): no gallery edit needed

- [ ] **Step 1A.1 — Confirm `runWindow` already activates the frame sink.**
  Read `PerfScenario.swift:238-259`: it constructs `TSVFileSink(path:)` and
  passes it as `SceneSessionResources(frameSink:)`. This is the same install
  point `.profiling()` uses (`ProfilingRegistry.frameSink`). No gallery code
  change is required for in-process frame capture.
  Expected: confirmation that frame TSV is produced without `.profiling()`.

- [ ] **Step 1A.2 — Decide CPU/memory capture for in-process runs.** `runWindow`
  already collects CPU via `CPUSampler.collect`. For the **memory/occupancy**
  signal, the harness must additionally drive `ProfileActivation` memory
  snapshots (or call `MemoryMetricCollector().collect()` on a timer). Note in
  the scenario design (Phase 2) that memory snapshots are emitted on a `1s`
  cadence using `MemoryMetricCollector`.

### 1B — Authentic binary (Route B): enable `.profiling()` (overlay scope)

- [ ] **Step 1B.1 — Add the dependency (overlay copy of the gallery).**
  In the overlay's `gallery/Package.swift`, add `SwiftTUIProfiling` to the
  `GalleryDemo` target:
  ```swift
  .executableTarget(
    name: "GalleryDemo",
    dependencies: [
      "GalleryDemoViews",
      .product(name: "SwiftTUI", package: "swift-tui"),
      .product(name: "SwiftTUIProfiling", package: "swift-tui"),
    ]
  ),
  ```

- [ ] **Step 1B.2 — Add `.profiling()` and a shutdown flush.**
  In the overlay's `gallery/Sources/GalleryDemo/GalleryDemoApp.swift`:
  ```swift
  import GalleryDemoViews
  import SwiftTUI
  import SwiftTUIProfiling

  @main
  struct GalleryDemoApp: App {
    nonisolated static let configuration = CommandConfiguration(
      commandName: "gallery-demo",
      abstract: "Explore SwiftTUI controls and runtime behavior."
    )

    @OptionGroup(title: "SwiftTUI Options")
    var swiftTUIOptions: SwiftTUIOptions

    @Option(help: "Open the gallery on a specific tab.")
    var tab: GalleryView.GalleryTab?

    var body: some Scene {
      WindowGroup {
        GalleryView(initialTab: tab)
      }
      .profiling()
    }
  }
  ```
  For the `summary` sink to flush, `ProfileActivation.shared.finish()` must run
  at shutdown. For this pass prefer the `tsv` sink (writes incrementally, no
  flush needed); if `summary` is wanted, confirm the app's termination path
  (signal handler / scene teardown) reaches `finish()`, and note it as a small
  follow-up if the App surface has no exit hook.

- [ ] **Step 1B.3 — Build the enabled binary in the overlay.**
  ```bash
  . /tmp/overlay-env.sh
  swiftly run swift build -c release \
    --package-path "$SWIFT_TUI_EXAMPLES_GALLERY"   # overlay-exported path
  ```
  Expected: a `gallery-demo` release binary that links `SwiftTUIProfiling`.

- [ ] **Step 1B.4 — Smoke-test activation.**
  ```bash
  SWIFTTUI_PROFILE="frames;tsv=/tmp/smoke-frames.tsv" \
    "$GALLERY_DEMO_BIN" --tab counter &
  sleep 2; kill %1
  wc -l /tmp/smoke-frames.tsv     # expect > 0 rows once any frame committed
  ```
  Expected: non-empty TSV proves `.profiling()` + env activation works. An empty
  file means `.profiling()` was not reached — re-check Step 1B.2.

---

## Phase 2 — Determine if existing tooling is sufficient

This phase produces a written sufficiency verdict (folded into the report) and
the harness requirements that follow from it.

- [ ] **Step 2.1 — Audit the data layer against the questions we must answer.**
  Map each target metric to a `FrameDiagnosticRecord` / CPU / memory field:
  - Frame latency & phase attribution → per-phase `Duration`s + `totalFrameDuration`.
  - Repaint efficiency → `presentationStrategy`, `presentationBytesWritten`,
    `presentationCellsChanged`, damage stats.
  - Reconciliation churn → `*NodesComputed` vs `*NodesReused`,
    `invalidatedIdentityCount`, `focusSyncRerenders`.
  - Idle cost → frame count over an idle window (rows in TSV with no input).
  - CPU/steady-state → `CPUSample.estimatedCPUPercent`.
  - Leaks → memory provider counts + `MemoryMetricRegistry.providerCount` slope.

  Verdict expectation: **the data layer is sufficient**; no new metric fields are
  needed.

- [ ] **Step 2.2 — Audit harness coverage against requirements.** Record the two
  concrete gaps already identified:
  1. No scenario hosts the **real** `GalleryView` / 18 tabs / palette
     (`GalleryAnimationClickScenario` uses a stub).
  2. All runs use the **in-memory** `PerfTerminalHost`; the **real terminal
     write path** (escape-sequence emission, PTY throughput) is never measured.

  Verdict expectation: **the harness is insufficient as-is** → Phase 3 builds the
  two missing pieces (gallery-hosting scenarios; kitty authentic cross-check).

---

## Phase 3 — Build the harness

Two harnesses. A (in-process) is the workhorse; B (kitty) is the authenticity
check.

### 3A — In-process gallery-hosting scenarios (reuse `TermUIPerf`)

- [ ] **Step 3A.1 — Add the gallery dependency to `TermUIPerf` (overlay).**
  In the overlay's `Tools/TermUIPerf/Package.swift`, add a path dependency on the
  gallery and link `GalleryDemoViews` into the `termui-perf` target:
  ```swift
  // dependencies:
  .package(name: "gallery-demo", path: "../../../swift-tui-examples/gallery"),
  // target deps:
  .product(name: "GalleryDemoViews", package: "gallery-demo"),
  ```
  **Coordination-only.** Do not commit this to the public `swift-tui` manifest.

- [ ] **Step 3A.2 — Add `PerfScenarioName` cases.** In `PerfScenario.swift`
  (the enum currently includes `.galleryAnimationClick`, `.layoutScrollBurst`),
  add one case per gallery tab (e.g. `.galleryTabLife`, `.galleryTabPhysics`, …)
  plus `.galleryCommandPalette`. Keep `rawValue`s equal to the `--tab` keys
  (e.g. `"life"`, `"physics"`, `"command-palette"`) so run-dir names are legible.

- [ ] **Step 3A.3 — Write `GalleryTabScenario`.** Create
  `Tools/TermUIPerf/Sources/TermUIPerf/Scenarios/GalleryTabScenario.swift`:
  ```swift
  import GalleryDemoViews
  @_spi(Runners) import SwiftTUI

  public struct GalleryTabScenario: PerfScenario {
    public let name: PerfScenarioName
    public let defaultTerminalSize = PerfTerminalSize(columns: 110, rows: 38)
    public let scriptedEvents: [String]
    public let visualMarkers: [String]
    public let settlingDescription: String

    private let tab: GalleryView.GalleryTab
    private let idleSeconds: Double
    private let drive: @MainActor (PerfScenarioDriver) async throws -> [PerfEventRecord]

    public init(
      name: PerfScenarioName,
      tab: GalleryView.GalleryTab,
      scriptedEvents: [String],
      visualMarkers: [String],
      settlingDescription: String,
      idleSeconds: Double = 5,
      drive: @escaping @MainActor (PerfScenarioDriver) async throws -> [PerfEventRecord]
    ) {
      self.name = name
      self.tab = tab
      self.scriptedEvents = scriptedEvents
      self.visualMarkers = visualMarkers
      self.settlingDescription = settlingDescription
      self.idleSeconds = idleSeconds
      self.drive = drive
    }

    @MainActor
    public func run(options: PerfScenarioRunOptions) async throws -> PerfScenarioRunResult {
      let tab = self.tab
      let idleSeconds = self.idleSeconds
      let drive = self.drive
      return try await PerfScenarioRunner.runWindow(scenario: self, options: options) {
        GalleryView(initialTab: tab)
      } drive: { driver in
        // 1) settle on first frame for this tab
        _ = try await driver.waitForFrame(containing: "", timeout: .seconds(3))
        // 2) idle window: let timers/animations run with no input
        try await Task.sleep(for: .seconds(idleSeconds))
        // 3) tab-specific scripted interaction
        return try await drive(driver)
      }
    }
  }
  ```
  Notes: the closure captures locals (not `self`) to satisfy `@MainActor`
  isolation; the idle `Task.sleep` is what captures background/animation cost in
  the frame TSV.

- [ ] **Step 3A.4 — Write `CommandPaletteScenario`.** Hosts `GalleryView()` and
  drives the palette. Because `runWindow`'s `PerfScriptedInputReader` sends
  `InputEvent`s, send a Ctrl+K key event, then character events to filter, then
  Return. Use the keyboard `InputEvent` constructors (mirror how
  `PerfScenarioDriver.sendClick` builds mouse events). Settle markers: a string
  the palette overlay renders (grep `CommandPalette.swift` for a stable label,
  e.g. the palette title or a command row).

- [ ] **Step 3A.5 — Register scenarios.** Extend `PerfScenarioRegistry.all`
  (`PerfScenario.swift:123-136`) to include one `GalleryTabScenario` per tab
  (constructed with the per-tab scripts from Phase 5) and the
  `CommandPaletteScenario`.

- [ ] **Step 3A.6 — Build and dry-run one tab.**
  ```bash
  . /tmp/overlay-env.sh
  swiftly run swift run --package-path "$SWIFT_TUI/Tools/TermUIPerf" -c release \
    termui-perf list-scenarios
  swiftly run swift run --package-path "$SWIFT_TUI/Tools/TermUIPerf" -c release \
    termui-perf run --scenario life --modes async --iterations 1 --configuration release
  ```
  Expected: a run dir under `.perf/runs/...-life-async-...` with non-empty
  `frames.tsv`, `cpu.tsv`, `summary.json`, and `run.json` whose `scenario` is
  `life`. Confirms the real `LifeTab` rendered (cross-check by grepping a
  Life-specific string in a captured frame if `PerfTerminalHost` retains text).

### 3B — Authentic terminal via kitty (cross-check)

- [ ] **Step 3B.1 — Write `run_gallery_kitty.sh`.** Create
  `Tools/perf-gallery/run_gallery_kitty.sh` (coordination-only). Behavior:
  ```sh
  #!/bin/sh
  set -eu
  TAB="$1"; OUT="$2"           # e.g. life  /path/to/out
  SOCK="unix:/tmp/kitty-perf-$$"
  TSV="$OUT/$TAB-frames.tsv"
  mkdir -p "$OUT"
  # Launch the profiling-enabled gallery binary in a real kitty window.
  SWIFTTUI_PROFILE="frames,cpu,memory@1s;tsv=$TSV" \
  kitty -o allow_remote_control=yes --listen-on "$SOCK" --hold \
    "$GALLERY_DEMO_BIN" --tab "$TAB" &
  KPID=$!
  sleep 2                                   # let the first frame settle
  # Idle window is implicit (we just wait); then scripted interaction:
  #   open palette, type filter, select — or tab-specific keys/clicks.
  kitty @ --to "$SOCK" send-text $'\x0b'    # Ctrl+K (0x0b) opens palette
  sleep 1
  kitty @ --to "$SOCK" send-text "physics"  # filter text (example)
  kitty @ --to "$SOCK" send-key enter
  sleep 3                                    # collect post-interaction frames
  kitty @ --to "$SOCK" send-text q           # or app's quit binding
  sleep 1; kill "$KPID" 2>/dev/null || true
  echo "wrote $TSV"
  ```
  Notes: `$GALLERY_DEMO_BIN` is the Phase-1B release binary;
  the exact quit key and Ctrl+K byte should be confirmed against the gallery's
  key handling. Run on macOS where kitty is installed; this is a manual/host
  step, not a CI gate.

- [ ] **Step 3B.2 — Validate one kitty run end-to-end.**
  ```bash
  GALLERY_DEMO_BIN="$GALLERY_DEMO_BIN" \
    sh swift-tui/Tools/perf-gallery/run_gallery_kitty.sh physics /tmp/kitty-out
  wc -l /tmp/kitty-out/physics-frames.tsv
  ```
  Expected: a non-empty TSV produced by the **real terminal** path, comparable in
  schema to the in-process TSV (same `FrameDiagnosticRecord` columns), so A-vs-B
  comparison in Phase 6 is apples-to-apples on the shared fields.

---

## Phase 4 — Reasoned performance predictions (before any analysis)

Write these down **before** running the matrix and freeze them in the report.
Each is falsifiable; Phase 6 marks each Confirmed / Refuted / Surprise.

- [ ] **Step 4.1 — Per-tab cost predictions.** Record:
  - **P1 (Life):** highest steady CPU and per-frame raster/draw time of any tab;
    `LifeRenderer.snapshot()` + Canvas dominate `raster`+`draw`; large
    `presentationCellsChanged` on each ~110 ms tick. Predict `incremental`
    strategy but with high cell counts.
  - **P2 (Physics):** ~25 fps steady frames (40 ms tick) even with no input;
    sub-cell Canvas ellipse → meaningful `raster` time; small damage region per
    frame (ball only) → `incremental` with low `presentationCellsChanged`. If we
    instead see **full** repaints, that's a surprise/hot spot.
  - **P3 (TaskProgress):** continuous frames while "idle" from 50 ms shimmer +
    240 ms spinner; small per-frame damage. Predict it is the worst *idle* tab
    (most frames per idle second with the screen visually near-static).
  - **P4 (Borders & Shapes):** 3 s chasing-light `repeatForever` drives constant
    perimeter repaint; predict gradient recompute each frame and a **memory
    growth slope** (prior art: ~1 MB/s on this pane). Leak suspect #1.
  - **P5 (Animations):** transient spikes when a curve is triggered; predict
    `AnimationController` active-animation count and occupancy rise during a
    burst and fall after — if occupancy does **not** fall back, that's a leak.
    Leak suspect #2.
  - **P6 (static tabs: Counter idle, Forms, TextInput idle, Todo):** ~0 frames
    during the idle window (event-driven). Any nonzero idle frame count here is a
    surprise worth chasing.
  - **P7 (Command palette):** open = one large-damage repaint (overlay); each
    filter keystroke re-renders the candidate list → predict per-keystroke frame
    cost scales with command count (only 18, so should be cheap). If a single
    keystroke triggers multiple `focusSyncRerenders`, that's a hot spot.

- [ ] **Step 4.2 — Phase-attribution prediction.** Predict that across Tier-1
  tabs, `raster` + `commit` (surface diff + write) dominate `totalFrameDuration`,
  not `resolve`/`measure` — i.e. the cost is in *presenting* pixels, not building
  the view tree. The frame head/tail split means `resolve/measure/place` run on
  the main actor; if those dominate instead, contention is the story.

- [ ] **Step 4.3 — A-vs-B prediction.** Predict the in-process harness
  *under-counts* real cost on Tier-1 tabs because `PerfTerminalHost` does not pay
  escape-sequence emission/PTY write latency; the kitty run should show higher
  `presentationDuration` for the same `presentationBytesWritten`. The *ratio* is
  the authenticity correction factor.

---

## Phase 5 — Collect data on every tab + the palette

Define per-tab interaction scripts, then run the full matrix.

- [ ] **Step 5.1 — Define per-tab interaction scripts.** For each tab, specify
  the concrete events the scenario's `drive` closure sends after the idle window.
  Use real controls (from the tab files). Examples (extend to all 18):
  - `counter`: click `+` button ×5, click step slider, click `−` ×2.
  - `life`: click Play, idle 3 s (auto-tick), click Random, drag-paint a few
    cells, click Pause.
  - `scroll-control`: click each scroll button (edge/identity/offset/relative).
  - `calculator`: click `7 + 8 =` then `AC`.
  - `borders-and-shapes`: pure idle (chasing-light runs itself); extend idle to
    10 s for the leak slope.
  - `animations`: trigger spring, then bouncy, then PhaseAnimator tap; idle 5 s
    between to watch occupancy fall.
  - `physics`: drag the ball and release (impart velocity); idle 5 s.
  - `task-progress`: pure idle 10 s (shimmer/spinner/script self-drive).
  - `presentation-lab` / `popovers`: open each modal/popover, dismiss.
  - `navigation-collections`: expand OutlineGroup, select Table rows, push a
    detail and pop.
  - `images`: cycle the four render modes; let the GIF animate during idle.
  - `text-input` / `focus-context`: type into fields; move focus.
  - `command-palette` (its own scenario): Ctrl+K, type `phy`, Return.

- [ ] **Step 5.2 — Run the full in-process matrix (Route A).**
  ```bash
  . /tmp/overlay-env.sh
  OUT="$PWD/docs/perf/2026-05-28-gallery-baseline"
  mkdir -p "$OUT"
  for TAB in counter life todo forms-and-containers text-input scroll-control \
             calculator borders-and-shapes presentation-lab navigation-collections \
             images animations file-drop popovers pointer-lab focus-context \
             physics task-progress command-palette; do
    swiftly run swift run --package-path "$SWIFT_TUI/Tools/TermUIPerf" -c release \
      termui-perf run --scenario "$TAB" --modes sync,async --iterations 3 \
      --configuration release
  done
  cp -R "$SWIFT_TUI/.perf/runs" "$OUT/in-process-runs"
  ```
  Expected: 19 scenarios × {sync,async} × 3 iterations of run dirs, each with
  `frames.tsv`/`cpu.tsv`/`summary.json`/`run.json`. `iterations 3` lets Phase 6
  report medians and spread.

- [ ] **Step 5.3 — Run the kitty cross-check (Route B) on Tier-1 tabs.**
  ```bash
  for TAB in life physics task-progress borders-and-shapes animations; do
    GALLERY_DEMO_BIN="$GALLERY_DEMO_BIN" \
      sh "$SWIFT_TUI/Tools/perf-gallery/run_gallery_kitty.sh" "$TAB" \
      "$OUT/kitty-runs"
  done
  ```
  Expected: 5 authentic-terminal TSVs for A-vs-B comparison.

- [ ] **Step 5.4 — Snapshot the environment.** Record git SHAs (both child
  repos + org pin), Swift version, macOS version, hardware model, terminal size,
  and render modes into `"$OUT/environment.json"`. (`run.json` already captures
  most of this per run via `PerfRunMetadata`; aggregate it.)

---

## Phase 6 — Analyze for hot spots and surprises

- [ ] **Step 6.1 — Aggregate TSVs into one table.** Write a small analysis script
  (`Tools/perf-gallery/aggregate.py` or a `swift`/`awk` one-liner set) that reads
  every `frames.tsv` and emits per-(tab, mode) rows with:
  - `frameCount`, `idleFrameCount` (frames during the no-input window),
  - `totalFrameDuration` p50/p95/max,
  - per-phase median (resolve/measure/place/semantics/draw/raster/commit),
  - `% full` vs `% incremental` (`presentationStrategy`),
  - median & max `presentationBytesWritten`, `presentationCellsChanged`,
  - median `focusSyncRerenders`, max `invalidatedIdentityCount`,
  - reuse ratios (`reused / (computed + reused)`) for resolve/measure/place,
  - steady `estimatedCPUPercent` (from `cpu.tsv`), peak `maxResidentBytes`.
  Write the table to `"$OUT/aggregate.csv"`.

- [ ] **Step 6.2 — Rank hot spots.** Sort the table by, in order: max
  `totalFrameDuration`, then steady CPU%, then idle frame count, then median
  `presentationBytesWritten`. Identify the top offenders and which **phase**
  dominates each (this localizes the fix).

- [ ] **Step 6.3 — Leak/occupancy analysis.** From the memory snapshots, compute
  the slope of each provider's `count` over the run for `borders-and-shapes`,
  `animations`, and `task-progress`. Flag any monotonically rising provider and
  any rising `MemoryMetricRegistry.providerCount` (never-deregistering graphs).
  Cross-reference the prior ~1 MB/s borders observation.

- [ ] **Step 6.4 — A-vs-B authenticity correction.** For each Tier-1 tab,
  compare in-process vs kitty `presentationDuration` at equal
  `presentationBytesWritten`. Compute the correction ratio; note whether
  in-process under-counting changes any ranking.

- [ ] **Step 6.5 — Mark predictions and surface surprises.** Go through P1–P7
  from Phase 4 and label each Confirmed / Refuted / Surprise. Give surprises top
  billing in the report — e.g. a "static" tab repainting while idle, a Tier-1 tab
  doing full repaints where incremental was expected, a single palette keystroke
  causing multiple focus-sync rerenders, or occupancy that never falls after an
  animation completes.

---

## Phase 7 — Evidence-based report

- [ ] **Step 7.1 — Write the report** to
  `docs/reports/2026-05-28-gallery-performance-report.md` with sections:
  1. **Methodology & environment** — routes used, SHAs, hardware, terminal size,
     render modes, idle/interaction protocol, the A-vs-B correction factor.
  2. **Predictions vs results** — the P1–P7 table with Confirmed/Refuted/Surprise.
  3. **Per-tab metrics** — the `aggregate.csv` rendered as a table.
  4. **Ranked hot spots** — for each, the dominating phase, the implicated source
     (e.g. `LifeTab`/`LifeRenderer.snapshot`, the borders chasing-light animation
     in `BordersAndShapesTab.swift`, `PhysicsTab` Canvas, `TaskProgressTab`
     shimmer cadence), the evidence (specific numbers), and a confidence level.
  5. **Leaks/occupancy** — providers with positive slope; the borders finding.
  6. **Recommendations** — concrete, each tied to evidence: e.g. damage-scope the
     chasing border so it repaints only the perimeter, throttle/coalesce the
     shimmer cadence, cache gradient computation, investigate the borders
     occupancy growth, reduce palette focus-sync rerenders. Order by
     (impact ÷ effort). Each recommendation names the file(s) a follow-up plan
     would touch.
  7. **Artifacts** — paths under `docs/perf/2026-05-28-gallery-baseline/`.

- [ ] **Step 7.2 — Link artifacts and commit the outputs.** Commit only the
  coordination-repo outputs (`docs/perf/...`, `docs/reports/...`). Do **not**
  commit the overlay-scope enablement/harness edits into the public child repos
  (per [Boundary constraints](#boundary-constraints)). If any harness piece is
  deemed worth keeping, propose it as its own follow-up that respects the public
  package contracts (e.g. ship a profileable gallery flag upstream, or land a
  gallery-hosting scenario behind a coordination-only build).

---

## Risks & open questions

- **`SwiftTUIProfiling` not in tag `0.0.5`.** Most likely true (Step 0.1). The
  entire pass then depends on the overlay pointing the gallery at the local
  `swift-tui`. If the overlay route fails, fall back to Route A only (the
  in-process harness lives in `swift-tui` and uses the local framework directly),
  losing the authentic-terminal cross-check but keeping the full per-tab matrix.
- **Cross-repo path dep in `TermUIPerf`.** Adding `GalleryDemoViews` as a path
  dependency is a public-boundary violation if committed to `swift-tui`. Keep it
  overlay-only; if a permanent gallery-hosting scenario is wanted, it must be
  designed as coordination-only tooling, not part of the public `swift-tui`
  manifest.
- **`PerfTerminalHost` text retention.** Phase 3A.6's "grep a tab-specific
  string" cross-check assumes the host retains rendered text per frame
  (`presentedFrames[].text`, used by `waitForFrame(containing:)`). Confirmed by
  `PerfScenario.waitForFrame` (`PerfScenario.swift:348-350`).
- **Palette `InputEvent` construction.** The driver only ships `sendClick`/
  `sendScroll`; sending Ctrl+K + characters + Return needs keyboard `InputEvent`s.
  Confirm the keyboard `InputEvent` API in `SwiftTUIRuntime/Input` before
  finalizing `CommandPaletteScenario` (Step 3A.4).
- **kitty determinism.** `send-text`/`send-key` timing is wall-clock and less
  deterministic than the in-process driver; treat kitty results as an
  authenticity *cross-check*, not the primary ranked dataset.
- **`summary` sink flush.** Needs `ProfileActivation.shared.finish()` at exit;
  the high-level `App` surface may lack an exit hook. Prefer `tsv` to sidestep
  this; flag the missing hook as a tiny follow-up if `summary` output matters.
- **Measurement perturbation.** Profiling adds per-frame derivation work
  (`FrameRecordDerivation`). It is the same overhead across tabs, so *relative*
  rankings hold; treat absolute numbers as profiled-build numbers, not
  clean-build numbers.

---

## Self-review (coverage of the seven requested steps)

1. **Enable the repo's performance tooling in the gallery** → Phase 1
   (1A no-op for in-process; 1B `.profiling()` + dependency for the binary).
2. **Determine if existing tooling is sufficient** → Phase 2 (data layer
   sufficient; harness insufficient — two named gaps).
3. **Build a harness to run the gallery authentically; reuse test tooling /
   kitty** → Phase 3 (3A extends `TermUIPerf`/`runWindow` with the real
   `GalleryView`; 3B kitty authentic terminal).
4. **Reasoned predictions before running** → Phase 4 (P1–P7, falsifiable).
5. **Collect data on each tab + interactions + command palette** → Phase 5
   (per-tab scripts, full matrix, palette scenario, kitty cross-check).
6. **Analyze for hot spots, especially surprising ones** → Phase 6
   (aggregate, rank, leak slope, A-vs-B, predictions vs results → surprises).
7. **Detailed evidence-based report with explanations + recommendations** →
   Phase 7 (report structure with per-finding evidence and file-targeted
   recommendations).
