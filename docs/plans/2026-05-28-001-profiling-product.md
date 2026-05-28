# Profiling Product Proposal

Status: proposal.

## Summary

SwiftTUI's profiling and diagnostics machinery is split across two homes today:
in-runtime hooks compiled into `SwiftTUIRuntime` (`FrameDiagnosticsLogger`,
`FrameDiagnosticRecord`, `RunLoopProgressProbe`, and the `@_spi(Runners)`
`SceneSession`/`RunLoop` seams that attach them), and a separate `Tools/TermUIPerf`
executable that owns the consumption layer (TSV sink, summary reducer, CPU
sampler, scripted scenarios, compare command). There is no supported, ergonomic
way for an ordinary app — including the `gallery` example — to turn profiling on
in an arbitrary build, and there is no signal at all for the data structure most
relevant to the leak that motivated this work: long-lived cache/store occupancy.

This proposal extracts all consumer-facing profiling code into a new optional
library product, **`SwiftTUIProfiling`**, that any app can link and activate in
*any* build (debug or release) by adding a single `.profiling()` scene modifier
and setting an environment variable. It adds a **memory/occupancy signal** built
on an extensible `MemoryMetricProvider` registry, alongside the existing frame
and CPU signals — each individually opt-in. `Tools/TermUIPerf` is refactored to
sit on top of the shared library so there is one implementation.

The package is pre-1.0; this proposal deliberately takes breaking API changes
where they produce a cleaner boundary.

## Motivation

1. **Profile real builds, including release.** The diagnostics path is already
   compiled into release (nothing is `#if DEBUG`-gated), but the only way to
   attach a logger is through `@_spi(Runners)` `SceneSession` internals or the
   plain-`public` `RunLoop.diagnosticsLogger` — neither of which the high-level
   `App`/`WindowGroup` surface exposes. An app author cannot profile their own
   app without forking the framework or hand-rolling a runner.
2. **A memory signal that would have caught the leak.** The investigation that
   prompted this found a steady ~1 MB/s growth on the gallery's borders pane.
   The fastest way to confirm and localize such a leak is to watch the
   occupancy of long-lived stores over time. No such signal exists today.
3. **One implementation, not two.** `TermUIPerf` reimplements sinks, a CPU
   sampler, and reducers that should be shared. Consolidating removes drift.
4. **A real product boundary.** Profiling is a distinct concern with a distinct
   audience. It should be a separately linkable product, not code welded into
   the runtime that every consumer pays for in binary size and API surface.

## Goals

- A new `SwiftTUIProfiling` library product, optionally linked, that works in
  debug and release on macOS/Linux (graceful degradation on WASI).
- Three independently opt-in signals: **frames**, **memory/occupancy**, **CPU**.
- One-line, env-gated activation (`.profiling()` + `SWIFTTUI_PROFILE=…`) that is
  zero-cost when not activated.
- An extensible occupancy-reporting mechanism (provider registry) rather than a
  hardcoded list of stores.
- `TermUIPerf` rebased on the shared library.

## Non-goals

- Moving the hot-path *call sites* out of the runtime. They stay; only the
  emit *contract* and all consumer-facing code move.
- Shipping a heap/allocations profiler. External tools (Instruments, heaptrack)
  remain the answer for byte-exact heap analysis. This product reports
  *structured, store-level* occupancy, which complements them.
- Changing what the existing frame diagnostics measure. Field parity is kept.
- Guaranteeing exact byte accounting. Element counts are always reported; byte
  weight is best-effort per provider.

## Current state (what exists, where)

| Concern | Symbol | Location | Access |
| --- | --- | --- | --- |
| Frame log sink | `FrameDiagnosticsLogger` | `Sources/SwiftTUIRuntime/Diagnostics/FrameDiagnosticsLogger.swift` | `public`, `@MainActor` |
| Frame record | `FrameDiagnosticRecord` | `Sources/SwiftTUIRuntime/Diagnostics/FrameDiagnosticRecord.swift` | `public` |
| TSV format | `FrameDiagnosticsTSVFormatting` | `Sources/SwiftTUIRuntime/Diagnostics/FrameDiagnosticsTSVFormatting.swift` | internal |
| Record assembly | `RunLoop+FrameDiagnosticRecordAssembly` | `Sources/SwiftTUIRuntime/RunLoop/` | internal |
| Emit point | `RunLoop+FrameDiagnostics` | `Sources/SwiftTUIRuntime/RunLoop/` | internal |
| Progress/quiescence probe | `RunLoopProgressProbe` | `Sources/SwiftTUIRuntime/RunLoop/RunLoopProgressProbe.swift` | `@_spi(Runners)` |
| Attach seams | `SceneSession.diagnosticsLogger` / `.progressProbe` | `Sources/SwiftTUIRuntime/Scenes/SceneSession.swift` | `@_spi(Runners)` |
| Attach seam | `RunLoop.diagnosticsLogger` | `Sources/SwiftTUIRuntime/RunLoop/RunLoop.swift:74` | `public` |
| CPU sampler | `CPUSampler` | `Tools/TermUIPerf/Sources/TermUIPerf/CPUSampler.swift` | tool-local |
| Consumers | `FrameDiagnosticsSink`, `SummaryReducer`, `PerfTerminalHost`, scenarios, `CompareCommand` | `Tools/TermUIPerf/Sources/TermUIPerf/` | tool-local |

The signal that does **not** exist: occupancy of long-lived stores (caches,
graph maps, retained frames). The inventory of those stores is in the
[Memory signal](#memory-signal-occupancy) section.

## Design overview

```
                         ┌────────────────────────────────────────────┐
                         │  SwiftTUIProfiling  (new, optional product)  │
                         │  • ProfileConfig + SWIFTTUI_PROFILE parser   │
                         │  • .profiling() scene modifier (public)      │
                         │  • FrameDiagnosticRecord + TSV/JSONL/summary  │
                         │  • CPUSampler                                 │
                         │  • MemoryMetricCollector (reads providers)    │
                         │  • Sinks + reports                            │
                         └───────────────▲───────────────▲──────────────┘
       installs sinks into registry ─────┘               │ reads package occupancy
                         ┌───────────────┴───────────────┴──────────────┐
                         │  SwiftTUIRuntime / SwiftTUICore (same package)│
                         │  • FrameDiagnosticSink protocol (package)     │
                         │  • RuntimeFrameSample (raw per-frame value)   │
                         │  • RunLoopProgressObserver protocol (package) │
                         │  • ProfilingRegistry (Mutex-guarded, package) │
                         │  • MemoryMetricProvider registry (package)    │
                         │  • cache/store occupancy accessors (package)  │
                         └──────────────────────────────────────────────┘
```

**Dependency inversion is the core move.** The runtime cannot depend on the
profiling product (that would defeat optionality), so the runtime keeps a
*neutral emit contract* and the product *implements* it. Because the product is
a target in the same SwiftPM package, it reads the runtime's and core's
`package`-level hooks and occupancy accessors directly — `@_spi` is needed only
at the product's *external* boundary (the `.profiling()` modifier the gallery
imports), not for the product to reach internals.

`SwiftTUIProfiling` depends on `SwiftTUIRuntime` and `SwiftTUICore`. Nothing in
the default dependency graph depends on `SwiftTUIProfiling`; it is purely opt-in.

## The runtime↔product contract

The runtime retains the minimum required to *emit*; everything consumed by a
human or tool moves to the product.

### Frame signal

- **Stays (runtime, `package`):**
  - `protocol FrameDiagnosticSink: Sendable { func record(_ sample: RuntimeFrameSample) }`
  - `struct RuntimeFrameSample` — the raw per-frame numbers that
    `RunLoop+FrameDiagnosticRecordAssembly` already computes (phase timings,
    worker enqueue/compute, main-actor blocked/suspended, input events seen
    during suspension, drop-policy state). This is a flat value type with no
    formatting or derived fields.
  - The emit point in `RunLoop+FrameDiagnostics` calls
    `registry.frameSink?.record(sample)`. The existing
    `guard let … else { return }` fast path is preserved, so a frame with no
    sink installed costs one branch.
- **Moves (product):** `FrameDiagnosticRecord` (the rich, derived record),
  `FrameDiagnosticsTSVFormatting`, and the *derivation* logic (sample → record)
  currently in `RunLoop+FrameDiagnosticRecordAssembly`. The
  `FrameDiagnosticsLogger`'s TSV-writing behavior is reincarnated as the
  product's `TSVFileSink`. The runtime keeps only the parts of assembly that
  gather raw inputs.

### Progress probe (split — see [Probe split](#progress-probe-split))

- **Stays (runtime):** the run-loop quiescence/await primitive (`idle()`,
  `waitForFrame`-style synchronization) used by the test suite and
  `SwiftTUITestSupport`. This is test-sync infrastructure, not profiling, and
  must not require linking a profiling product.
- **Moves (product):** the perf *event log* — the append-only
  `recordedEvents` recording and its `Kind`/`RunLoopProgressEvent` shapes — as a
  product-side observer that conforms to a runtime `package`
  `RunLoopProgressObserver` protocol.

### Activation registry

A `package`, `Mutex`-guarded `ProfilingRegistry` in the runtime holds the
currently-installed `frameSink`, `progressObserver`, and a handle the product
uses to pull memory metrics. The runtime consults it when constructing each
`SceneSession`. The product's `.profiling()` modifier installs into it before
the first session is built (see [Activation](#activation--ergonomics)). House
concurrency rules apply: `Synchronization.Mutex`, no `@unchecked Sendable`, no
`nonisolated(unsafe)`.

## Signals

All signals are **off unless explicitly named.** `ProfileConfig` selects which
run and with what cadence.

```swift
public struct ProfileConfig: Sendable {
  public enum Signal: Sendable, Hashable {
    case frames                       // per-frame, event-driven
    case memory(interval: Duration)   // periodic occupancy snapshot
    case cpu(interval: Duration)      // periodic CPU/RSS sample
  }
  public var signals: Set<Signal>
  public var sinks: [ProfileSink]
}
```

- **frames** — event-driven; emits one record per committed frame via the frame
  sink. No cadence.
- **memory(interval:)** — a timer task snapshots every registered
  `MemoryMetricProvider` and emits an occupancy record. Interval is explicit
  (e.g. `1s`).
- **cpu(interval:)** — a timer task samples process CPU and resident size.
  Available on Darwin/Glibc; no-op on WASI.

## Memory signal (occupancy)

### Mechanism: a provider registry, not a fixed list

Hardcoding a list of stores would rot immediately — there are whole families of
registries (`Local*Registry`, `CommandRegistry`, `DropDestinationRegistry`,
focus/pointer/gesture stores) not enumerated here. Instead:

```swift
// package, in SwiftTUICore
public struct MemoryMetricSnapshot: Sendable {
  public var name: String          // e.g. "TextLayoutCache.order"
  public var count: Int            // element count (always cheap)
  public var approxBytes: Int?     // best-effort; nil if not estimable
  public var detail: [String: Int]?// optional sub-counts (hits, misses, …)
}

package protocol MemoryMetricProvider: Sendable {
  func snapshot() -> MemoryMetricSnapshot
}

package enum MemoryMetricRegistry {        // Mutex-guarded
  package static func register(_ provider: any MemoryMetricProvider) -> Token
  package static func snapshotAll() -> [MemoryMetricSnapshot]
}
```

Each store registers a provider near its declaration (one line). The collector
in `SwiftTUIProfiling` calls `snapshotAll()` on the configured interval.

**Lifecycle as a signal.** Process-lived singletons register once at init.
Per-graph instances (`ViewGraph`, `MeasurementCache`, `AnimationController`)
register on creation and *deregister* on teardown via the returned `Token`. A
leaked graph therefore shows up as a provider that never deregisters — the
registry's own population is itself a meta-leak detector, reported as a synthetic
`MemoryMetricRegistry.providerCount` metric.

### Seed set

Counts are always reported; `approxBytes` is provided where a cheap estimate
exists (a `RasterSurface` knows cells × cell size; trees report node count as a
proxy and omit bytes).

**Tier 1 — process-lived / unbounded (highest value):**

| Provider name | Store | Module |
| --- | --- | --- |
| `TextLayoutCache.entries` / `.order` | `TextLayoutCache.shared` (`Content/TextLayoutCache.swift`) | Core |
| `TextFigureSupport.metricsCache` / `.order` | `static metricsCache` (`Content/TextFigureSupport.swift`) | Core |
| `ImageAssetRepository.resolutions` / `.decodedImages` (+bytes) | `sharedImageAssetRepository` (`Terminal/ImageAssetRepository.swift`) | Runtime |
| `TerminalImageRenderer.payloads` (+bytes) | `kitty`/`sixel`/`fallback` stores (`Terminal/TerminalImageRendering.swift`) | Runtime |
| `RunLoop.reportedRuntimeIssues` | `Set<RuntimeIssue>` (`RunLoop/RunLoop.swift`) | Runtime |

**Tier 2 — graph-sized / byte-heavy (count + approx bytes):**

| Provider name | Store | Module |
| --- | --- | --- |
| `ViewGraph.nodesByIdentity` / `.liveIdentities` / dependents | `ViewGraph` maps (`Resolve/ViewGraph.swift`) | Core |
| `MeasurementCache.entriesByIdentity` | per-graph (`Measure/MeasurementCache.swift`) | Core |
| `RetainedFrameIndex.*ByIdentity` (+ retained `RasterSurface` bytes) | `FrameTailRetainedState` (`Rendering/FrameTailRetainedState.swift`), `RunLoop.previousPresentedRasterSurface` | Runtime |
| `AnimationController.*` | `activeAnimations`, `registeredAnimations`, `completionClosures`, `batchRefCounts`, `pendingEmptyBatchCompletions`, retained `previousTreeRoot`/`previousPlacedRoot` | Runtime |

**Tier 3 — bounded, watch-to-confirm (cheap counts):**
`FocusTracker.modalRestorationStack` depth; presentation imperative/declarative
item counts (`PresentationFamilyItemStore`); `TaskRunner.activeTasks`;
`ObservationBridge.observedPasses`; `FrameScheduler` waiters;
`SendableLayoutWorkerProxy.cachedStates`; `StateGraphBindingRegistry.shared` /
`GestureStateGraphBindingRegistry.shared`.

Tiers 1–2 are seeded in the first implementation. Tier 3 and the unenumerated
registry families are added incrementally by registering providers; no plumbing
change is needed to add coverage later.

## Activation & ergonomics

### The modifier

```swift
import SwiftTUIProfiling   // only consumers who want profiling link this

var body: some Scene {
  WindowGroup { GalleryView() }
    .profiling()                 // env-gated; no-op unless activated
    // or: .profiling(ProfileConfig(signals: [.memory(interval: .seconds(1))],
    //                              sinks: [.summary(.standardError)]))
}
```

`.profiling()` is a public modifier. With no argument it reads
`SWIFTTUI_PROFILE`; if unset it is a complete no-op (no timers, no sinks, the
runtime registry stays nil, the hot path stays a single branch). With an
explicit `ProfileConfig` it activates that config regardless of env (env, if
also present, can override sink destinations — see grammar).

The modifier installs sinks/observers/collectors into the runtime
`ProfilingRegistry` during scene setup, before the first `SceneSession` is
constructed. Ordering requirement: installation must precede first session
construction; the modifier performs it synchronously at setup.

### `SWIFTTUI_PROFILE` grammar

```
SWIFTTUI_PROFILE = signal-list [ ";" sink-list ]
signal-list      = signal *( "," signal )
signal           = "frames"
                 | "memory" [ "@" duration ]     ; default 1s
                 | "cpu"    [ "@" duration ]     ; default 250ms
sink-list        = sink *( "," sink )
sink             = "tsv="  path
                 | "jsonl=" path
                 | "summary"                     ; reduced report to stderr at exit
duration         = e.g. 100ms, 1s, 2s500ms
```

Examples:

```bash
# Frames + memory once/sec, written as TSV; works in a release build:
SWIFTTUI_PROFILE="frames,memory@1s;tsv=/tmp/run.tsv" ./gallery-demo

# Just the memory signal, summary to stderr — the borders-pane leak check:
SWIFTTUI_PROFILE="memory@500ms;summary" ./gallery-demo
```

Each signal must be named to run; omitting one leaves it off. Unset variable =
profiling fully disabled.

## Sinks & reports

`ProfileSink` is a `Sendable` protocol with one method per record type (frame,
memory, cpu). Built-in sinks:

- `.tsvFile(path)` — append-only TSV; preserves the existing frame-diagnostics
  column format for `TermUIPerf` compatibility; memory/cpu get their own files
  or columns.
- `.jsonl(path)` — one JSON object per record; convenient for ad-hoc analysis.
- `.summary(.standardError)` — buffers, then prints a reduced report at process
  exit (per-signal: frame timing percentiles; max/last occupancy per provider
  with growth rate; CPU/RSS peak). Reuses `SummaryReducer` logic.
- `.handler(@Sendable (ProfileRecord) -> Void)` — in-process callback, the
  WASI-safe path and the hook tests use.

File sinks no-op on WASI (no POSIX file I/O), matching today's
`FrameDiagnosticsLogger` behavior; the handler and summary(buffer) sinks remain
available there.

## TermUIPerf refactor

`Tools/TermUIPerf` already depends on the framework by local path
(`.package(name: "swift-tui", path: "../..")`, product `SwiftTUI`). It gains a
dependency on the `SwiftTUIProfiling` product and is rebased:

- Delete `CPUSampler`, `FrameDiagnosticsSink`, `SummaryReducer` — replaced by the
  library's `CPUSampler`, sinks, and reducer.
- `PerfTerminalHost` attaches profiling via the same registry path the
  `.profiling()` modifier uses (or a lower-level `package` entry point the tool
  can call directly, since it is in-repo).
- `RunCommand`/`CompareCommand`/scenarios stay; they now consume the library's
  record/report types.

Net effect: one implementation of every sink and the sampler; `TermUIPerf`
becomes the scripted-scenario + compare CLI layered on the shared library.

## Public API & breaking changes

Pre-1.0; breaking changes are accepted. Expect:

- `RunLoop.diagnosticsLogger` (currently plain `public`) — removed or changed.
  Attaching a logger now goes through profiling activation.
- `SceneSession.diagnosticsLogger` / `.progressProbe` (`@_spi(Runners)`) — the
  `diagnosticsLogger` becomes a `package` `FrameDiagnosticSink?`; the perf side
  of `progressProbe` moves to the product while the quiescence primitive stays.
- `FrameDiagnosticRecord`, `FrameDiagnosticsTSVFormatting`, and
  `RunLoopProgressProbe`'s perf surface move out of `SwiftTUIRuntime` into
  `SwiftTUIProfiling`. `FrameDiagnosticsLogger` is removed; its TSV output is
  reincarnated as `TSVFileSink`.

Required follow-through:

- Update the public-API baseline artifacts: `docs/PUBLIC_API_BASELINE.md`,
  `docs/.public-api-baseline.txt`, `docs/public_api_overrides.yml`, and re-run
  the `public-surface-policies` check.
- Audit external runner packages (`Platforms/CLI`, `Platforms/WebHost`, and the
  `swift-tui-examples` runners) for use of the moved symbols.

## Progress-probe split

`RunLoopProgressProbe` is dual-use today: it provides both run-loop
**quiescence/await** (used pervasively by the test suite and
`SwiftTUITestSupport` for poll-free waiting) and a perf **event log**. Per the
agreed split:

- **Quiescence/await stays in the runtime** (and remains usable by test targets
  without linking a profiling product). Likely a renamed, focused type so its
  test-sync purpose is explicit.
- **The event log moves to `SwiftTUIProfiling`** as a `RunLoopProgressObserver`
  conformer. The runtime fires observer callbacks through the
  `ProfilingRegistry`.

Audit targets for the split: `HostedRasterSurface.waitForFrame*`,
`SceneSession.progressProbe`, `SwiftTUITestSupport`, and every test that calls
`idle()`/`events` (`Tests/SwiftTUITests`, runtime tests).

## Platform & performance considerations

- **WASI:** file sinks unavailable (unchanged); handler/summary sinks and the
  memory signal work; CPU sampler is a no-op.
- **Zero-cost when disabled:** with no config and unset env, the registry holds
  no sink/observer/collector, no timers are started, and per-frame emit is a
  single nil check. This must be covered by a regression test asserting no
  per-frame allocation on the disabled path.
- **Hot-path discipline:** `RuntimeFrameSample` is a flat value type; derivation
  into the rich record happens in the product, off the critical guard.

## Migration plan (phased)

1. **Contract in the runtime.** Add `FrameDiagnosticSink`, `RuntimeFrameSample`,
   `RunLoopProgressObserver`, `ProfilingRegistry`, and `MemoryMetricProvider` /
   `MemoryMetricRegistry` (all `package`). Reduce `RunLoop+FrameDiagnostics`/
   assembly to emit `RuntimeFrameSample` to `registry.frameSink`. Keep behavior
   identical with a temporary in-runtime adapter so tests stay green.
2. **New product skeleton.** Add `SwiftTUIProfiling` target + product to
   `Package.swift`. Move `FrameDiagnosticRecord`, TSV formatting, the logger
   (as a sink), and sample→record derivation into it.
3. **Memory collector + seed providers.** Add occupancy accessors and register
   Tier-1/Tier-2 providers; implement `MemoryMetricCollector`.
4. **CPU sampler.** Move `CPUSampler` into the product, platform-gated.
5. **Activation.** Implement `.profiling()`, `ProfileConfig`, the
   `SWIFTTUI_PROFILE` parser, and the sinks (`tsv`/`jsonl`/`summary`/`handler`).
6. **Probe split.** Separate quiescence from event log; move the event log to
   the product; update test-sync call sites.
7. **TermUIPerf refactor.** Rebase the tool on the library; delete duplicates.
8. **API baseline + cleanup.** Update baselines, remove dead seams, run the full
   gate (`bun run test` / `bun run test:all`).

Phases 1–2 land behind the temporary adapter so nothing breaks mid-flight; the
adapter is deleted in phase 8.

## Testing strategy

- **Parser unit tests:** `SWIFTTUI_PROFILE` grammar — signals, intervals, sinks,
  malformed input, empty/unset.
- **Config unit tests:** per-signal opt-in; explicit `ProfileConfig` vs env
  precedence.
- **Sink format tests:** TSV column parity with the existing format; JSONL shape;
  summary reduction.
- **Frame-signal integration:** run a scripted scenario (reuse `TermUIPerf`'s
  gallery-animation scenario) with `.profiling()`; assert one record per
  committed frame and field parity with the pre-refactor record.
- **Memory-signal integration:** run an animated scenario; assert occupancy
  snapshots are emitted and that a provider's count is captured (e.g. drive a
  text-heavy animated view and observe `TextLayoutCache` metrics move).
- **Disabled-path regression:** with profiling unconfigured, assert no profiling
  timers exist and the per-frame path performs no profiling allocation.
- **Probe-split regression:** the existing test suite's poll-free waiting must
  keep working without linking `SwiftTUIProfiling`.

Follow the repo's preference for real `RunLoop` input-path coverage and bounded
condition-based waits over fixed sleeps.

## Risks & open questions

- **Blast radius of the probe split.** Quiescence is load-bearing for the whole
  test suite. The split must be done carefully; phase 6 is the riskiest step and
  should be landed independently with the full gate green.
- **Activation ordering.** `.profiling()` must install before first session
  construction. If a scene defers session creation in a way that races setup,
  the modifier may need an explicit pre-run hook on the `App` entry. To verify
  during phase 5.
- **Byte estimation scope.** Which providers can cheaply estimate bytes vs
  count-only. Default to count-only; add bytes opportunistically.
- **`TextLayoutCache.order` exact bound.** Investigation and a code-inventory
  pass disagreed on whether `order` has a compaction guard. Independent of the
  profiler design (it watches the store either way), but worth resolving when
  the leak fix lands.
- **Naming.** `SwiftTUIProfiling` product/module name; `.profiling()` modifier
  name; `SWIFTTUI_PROFILE` env var name. Proposed; open to bikeshedding.

## New module layout (proposed)

```
Sources/SwiftTUIProfiling/
  Activation/
    ProfilingSceneModifier.swift     // .profiling()
    ProfileConfig.swift
    EnvProfileParser.swift           // SWIFTTUI_PROFILE grammar
  Frames/
    FrameDiagnosticRecord.swift      // moved
    FrameRecordDerivation.swift      // sample -> record (moved from assembly)
    FrameDiagnosticsTSVFormatting.swift  // moved
  Memory/
    MemoryMetricCollector.swift
  CPU/
    CPUSampler.swift                 // moved from TermUIPerf
  Progress/
    RunLoopProgressLog.swift         // moved event-log side of the probe
  Sinks/
    ProfileSink.swift
    TSVFileSink.swift                // subsumes the old FrameDiagnosticsLogger
    JSONLSink.swift
    SummarySink.swift                // SummaryReducer logic
    HandlerSink.swift
  Reports/
    SummaryReducer.swift             // moved from TermUIPerf

Sources/SwiftTUIRuntime/Diagnostics/   (retained, minimized)
  FrameDiagnosticSink.swift          // protocol (package)
  RuntimeFrameSample.swift           // raw value (package)
  ProfilingRegistry.swift            // Mutex-guarded (package)
Sources/SwiftTUICore/Support/
  MemoryMetricProvider.swift         // protocol + registry (package)
```
