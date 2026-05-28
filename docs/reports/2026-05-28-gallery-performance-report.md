# SwiftTUI Gallery Performance Data-Collection Report

**Date:** 2026-05-28
**Plan:** [`docs/plans/2026-05-28-002-gallery-performance-data-collection-plan.md`](../plans/2026-05-28-002-gallery-performance-data-collection-plan.md)
**Scope:** In-process pass (Route A). Authentic-terminal (kitty) cross-check deferred.

---

## TL;DR

- The in-process harness now hosts the **real** `GalleryView` across all 18 tabs
  + the command palette, and emits per-frame diagnostics through the framework's
  own `SwiftTUIProfiling` data layer.
- **Biggest surprise (HIGH):** the **Animations** tab commits **274 frames over a
  10 s idle window with zero measured damage on every frame** (`damage_cells = 0`,
  `invalidated = 0`), burning **5.58 CPU-seconds (~56 % of one core)** — the
  highest CPU of any tab — to produce frames that change nothing on screen.
- **Interactive cost (MEDIUM):** a single **Calculator** button click costs
  ~22 ms of pipeline, **13.9 ms of it in `resolve`**, for a 2-cell visual change.
  Per-frame cost is largely *fixed* and does not scale down with the size of the
  change.
- **Good news:** every "static" tab produces **0 frames while idle** (purely
  event-driven); **Physics** correctly **stops rendering when the ball settles**;
  the command palette causes **no focus-sync storm**.
- **Memory:** the occupancy signal is now wired in. The historical "borders pane
  ~1 MB/s" leak is **refuted at this SHA** (borders stores are flat). An earlier
  draft of this report flagged a Task Progress `TextLayoutCache` leak; that was a
  **false alarm** — the cache is LRU-bounded at 256 and the 20 s sample was too
  short to see the plateau. **No memory leak found.** (See H5, corrected.)
- **Authentic-terminal cross-check (kitty) done:** presentation is **100 %
  incremental** on a real terminal, real `present_cells` **equals** the
  in-process `damage_cells` (the stub's `4180` was pure artifact), and
  terminal-write cost is **negligible** (≤0.08 ms/frame). The bottleneck is the
  **frame pipeline (CPU)**, not terminal I/O. See §6.

---

## 1. Methodology & environment

### Harness

Per-tab scenarios were added to `swift-tui/Tools/TermUIPerf` that host the real
`GalleryView(initialTab:)` via the existing `PerfScenarioRunner.runWindow`
machinery (in-memory `PerfTerminalHost`, scripted `PerfScriptedInputReader`,
per-frame `TSVFileSink`, periodic `CPUSampler`). A `CommandPaletteScenario`
drives Ctrl+K → fuzzy-filter → Return. Three input-driven tabs (Counter,
Calculator, ScrollControl) also run scripted clicks; the rest are measured over
a **5 s idle window** (10 s in the original frame matrix, then **20 s** for the
memory re-run of the three animation-heavy tabs: Animations, Borders & Shapes,
Task Progress).

The harness also samples occupancy: an `@_spi(Runners)` accessor
(`ProfiledMemory.snapshot()`) added to `SwiftTUIProfiling` exposes the
`package` `MemoryMetricCollector`, and `PerfMemorySampler` polls it every 500 ms
during the run, writing a per-run `memory.tsv` (long form: `elapsed_s`,
`provider`, `count`, `approx_bytes`). This is on-demand polling, deliberately
not the activation-layer timer (a process-wide singleton awkward to drive
per-run).

The cross-repo graph resolves via SwiftPM's local-path override: `TermUIPerf`'s
`path:"../.."` dependency on `swift-tui` (which carries `SwiftTUIProfiling`)
overrides the gallery's `exact:"0.0.5"` pin, collapsing both to one local
checkout. No dev overlay was required.

### Environment

| Field | Value |
| --- | --- |
| org pin | `0dcbdc2` |
| `swift-tui` | `843da06e` (working tree dirty: coordination-only harness edits, uncommitted) |
| `swift-tui-examples` | `c27d2f5` |
| Swift | 6.3.1 (release), `arm64-apple-macosx26.0` |
| OS | macOS 26.5 (25F71) |
| Hardware | Mac17,7, 18 cores |
| Terminal | 110 × 38 cells |
| Build config | `release` |
| Render modes | `async` (primary) + `sync` |
| Iterations | 1 run per (scenario, mode) — single sample |

### What the numbers mean — and what they DON'T

This pass measures the **frame-production pipeline** and **CPU**, not terminal
output. Validity was verified by reading `PerfTerminalHost`:

- **VALID (runtime-computed, host-independent):** per-phase timings
  (`resolve/measure/place/semantics/draw/raster/commit_ms`), `pipeline_ms`,
  `committed_frame_count`, `frame_interval_ms`, `damage_*` (rows/cells/spans),
  `focus_syncs`, `invalidated`, node computed/reused, CPU
  (`total_cpu_seconds`), `animation_controller_active_animations`.
- **ARTIFACT (excluded):** `present_strategy` (always `fullRepaint`),
  `present_cells` (always `4180` = 110×38), `present_bytes` (always `0`),
  `present_ms` (always `0`). `PerfTerminalHost.present(...)` is a stub that
  reports fixed full-repaint metrics and performs no write. **Therefore
  incremental-vs-full presentation, bytes written, and terminal-write latency
  were not measured.** Use `damage_cells` as the real "what changed" signal.

### Known gaps (carried to follow-up)

1. ~~No real-terminal data.~~ **Resolved** by the kitty cross-check (§6):
   terminal-write cost is negligible and `present_cells == damage_cells`, so the
   in-process pipeline timings are representative and `damage_cells` is an
   accurate proxy for real write size. The only in-process artifact was
   `present_*` (stub host).
2. **n = 1 per cell.** Single sample; treat magnitudes as indicative, rankings as
   robust (effects are large).
3. **`cpu_per_frame_ms` for 1-frame (static) tabs is a cold-start artifact** —
   one cold first frame ÷ 1.
4. **Memory = element counts**, sampled at 500 ms; byte weight is best-effort and
   absent for most providers. Only the three animation-heavy tabs were re-run at
   the 20 s window; other tabs have `memory.tsv` at their shorter windows.

---

## 2. Predictions vs. results

Predictions P1–P7 were frozen before the run (plan §Phase 4).

| # | Prediction | Verdict | Evidence |
| --- | --- | --- | --- |
| P1 | Life = highest steady CPU & raster | **Refuted** | Life is mid-pack (1.07 CPU-s); Animations is the CPU leader (5.58 s). Life `raster_ms` is low (0.78); its cost is in `resolve` (9.1 ms). |
| P2 | Physics = small damage, settles | **Confirmed** | `damage_cells` 15–21 (the ball); 31 % of frames zero-damage as it comes to rest, then stops. Well-behaved. |
| P3 | Task Progress = worst idle tab | **Partial** | High (239 frames) but second to Animations (274). Damage is tiny+real (4 cells). |
| P4 | Borders = continuous repaint + leak | **Repaint confirmed; leak refuted** | Continuous repaint **confirmed** (258 frames, 70 real cells/frame). Leak **refuted**: borders occupancy is flat over 20 s (`ViewGraph` 307→307, `TextLayoutCache` 145→145). No leak anywhere — Task Progress was a false alarm (see H5, corrected). |
| P5 | Animations = transient spikes | **Refuted → Surprise** | Not transient: 274 continuous **zero-damage** frames, highest CPU. See H1. |
| P6 | Static tabs idle-quiet | **Confirmed** | Forms, Todo, Navigation, Text Input, Popovers, Presentation Lab, Focus Context, File Drop, Pointer Lab → **1 frame each** (no idle frames). |
| P7 | Palette = focus-sync storm | **Refuted** | `focus_syncs_sum` = 1–2; palette open = one ~180-cell overlay draw. No storm. |

---

## 3. Per-tab metrics (async mode, ranked by CPU)

Source: [`docs/perf/2026-05-28-gallery-baseline/aggregate.csv`](../perf/2026-05-28-gallery-baseline/aggregate.csv)
(regenerate with `aggregate.py`). Cold first frame excluded from medians.

| Scenario | Frames | CPU-s | CPU/frame ms | damage_cells med | % zero-dmg | resolve ms | commit ms | pipeline med ms | anim active |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **animations** | 274 | **5.58** | 20.4 | **0** | **100** | 0.0 | 3.49 | 13.95 | 2 |
| task-progress | 239 | 3.66 | 15.3 | 4 | 6 | 3.82 | 2.18 | 8.23 | 0 |
| borders-and-shapes | 258 | 3.58 | 13.9 | 70 | 0 | 0.0 | 3.00 | 6.24 | 1 |
| command-palette | 56 | 1.14 | 20.3 | 15 | 29 | 2.47 | 2.52 | 8.87 | 0 |
| images | 60 | 1.10 | 18.3 | 266 | 0 | 4.99 | 2.10 | 10.47 | 0 |
| life | 45 | 1.07 | 23.9 | 25 | 0 | 9.07 | 2.57 | 16.27 | 0 |
| physics | 52 | 0.69 | 13.3 | 15 | 31 | 2.46 | 0.97 | 6.85 | 0 |
| scroll-control | 16 | 0.47 | 29.3 | 13 | 33 | 11.30 | 2.30 | 18.34 | 0 |
| counter | 22 | 0.44 | 20.1 | 60 | 0 | 7.85 | 1.42 | 14.68 | 1 |
| calculator | 13 | 0.44 | 33.6 | 1 | 42 | **13.94** | 3.44 | 21.77 | 0 |
| *9 static tabs* | 1 | ~0.03 | (cold) | 0 | – | – | – | – | 0 |

---

## 4. Ranked hot spots

### H1 — Animations tab: 274 zero-damage frames, highest CPU **(HIGH)**

**Evidence.** Over a 10 s idle window with no input, `gallery-animations`
committed **274 frames**, and *every* frame (after the cold first) reported
`damage_cells = 0`, `damage_rows = 0`, `invalidated = 0`, while still spending
~14 ms of pipeline (median) — dominated by `commit` (3.49 ms) and `place`
(2.15 ms) — for a total **5.58 CPU-seconds (~56 % of one core)**, the highest of
any tab. `animation_controller_active_animations` = 2 throughout.

**Interpretation.** Two animations stay *perpetually active* during idle and
request a frame every animation tick (~28 fps). Each tick runs the full
resolve→commit pipeline but the rasterized surface is byte-identical to the
previous frame (zero damage). This is wasted work along two independent axes:

1. **Content:** something in `AnimationsTab` keeps the animation controller
   active at idle (a `repeatForever` / `PhaseAnimator` whose on-screen delta is
   nil between phase boundaries — yet even boundaries showed zero damage here).
2. **Runtime:** the run loop **commits frames that have neither invalidation nor
   damage** rather than short-circuiting them.

**Files / hypotheses.**
- `swift-tui-examples/gallery/Sources/GalleryDemoViews/AnimationsTab.swift` —
  audit which animations remain active at idle (PhaseAnimator auto-cycle
  sections); confirm whether their visual output actually changes.
- Runtime: investigate a **"skip commit when `invalidated == 0 && damage == 0`"**
  fast path in the frame tail / commit (`SwiftTUIRuntime/RunLoop/` +
  `CommitPlanner`). Hedge: confirm no animation-completion bookkeeping depends on
  those frames before changing behavior.

**Why it matters most.** A zero-damage frame is the purest form of wasted CPU.
The kitty cross-check (§6) **resolves the open question**: on a real terminal
these frames are `incremental` with `present_cells = 0`, `present_bytes = 0`,
`present_ms ≈ 0.01` — i.e. **no-op writes**, not full repaints. So the terminal
pays nothing, but the runtime still spends ~5 ms/frame (raster + commit) building
them. The fix is therefore purely CPU-side: **skip the pipeline for frames with
no invalidation and no damage**, not anything presentation-related.

### H2 — Per-interaction `resolve` cost **(MEDIUM)**

**Evidence.** A single Calculator button click costs **`resolve` 13.9 ms**
(pipeline 21.8 ms, `cpu_per_frame` 33.6 ms) for a **1–2 cell** display change.
ScrollControl is similar (`resolve` 11.3 ms). Life's per-tick `resolve` is
9.1 ms.

**Interpretation.** Each interaction re-resolves a large slice of the view tree
even when the resulting visual change is tiny. `resolve` dominates the cost of
invalidation-driven frames.

**Files / hypotheses.**
- `swift-tui-examples/gallery/Sources/GalleryDemoViews/CalculatorTab.swift`,
  `ScrollControlTab.swift` — check whether a single `@State` change invalidates
  the whole grid/list (over-broad invalidation scope).
- Runtime resolve path (`SwiftTUIRuntime` resolve/`ViewGraph`) — measure node
  computed-vs-reused ratio per interaction (columns exist:
  `resolved_computed`/`resolved_reused`).

### H3 — Per-frame pipeline cost is largely fixed **(MEDIUM, architectural)**

**Evidence.** `pipeline_ms` does not scale down with damage: Calculator pays
21.8 ms for 1-cell damage; Animations pays 14 ms for 0-cell damage; Borders pays
6.2 ms for 70-cell damage. Invalidation frames are `resolve`-bound; animation
frames are `commit`+`place`-bound.

**Interpretation.** There is a high fixed cost to producing *any* frame. This
compounds H1 (many cheap-to-skip frames are not cheap to produce) and H2 (small
changes pay a big pipeline). The two dominant fixed costs are `resolve` (for
invalidation frames) and `commit`+`place` (for animation frames).

**Recommendation.** Profile the `resolve` and `commit` hot paths directly
(Instruments) on the Calculator-click and Animations-idle scenarios; this is the
highest-leverage *framework* target because it benefits every tab.

### H4 — Continuous animators: Borders & Task Progress **(INFO / LOW)**

**Evidence.** Borders (258 frames, 70 real cells/frame, 3.58 CPU-s) and Task
Progress (239 frames, 4 cells/frame, 3.66 CPU-s) animate continuously at ~28 fps
during idle, each consuming ~36 % of a core. Unlike Animations (H1), their
damage is **real and non-zero** — they are doing visible work.

**Interpretation.** This is legitimate continuous animation (the chasing-light
border perimeter; the shimmer/spinner), not waste. The question is product, not
correctness: is ~28 fps necessary for these effects, or would a lower cadence be
visually indistinguishable?

**Files.** `BordersAndShapesTab.swift` (3 s `repeatForever` chasing light),
`TaskProgressTab.swift` (50 ms shimmer + 240 ms spinner). Optional: throttle the
animation clock for these effects.

### Good citizens (no action)

- **Physics** settles: 31 % of frames are zero-damage *because the ball comes to
  rest and rendering stops* — the correct behavior H1 lacks.
- **Static tabs** (9 of them) produce **0 frames while idle** — fully
  event-driven.
- **Command palette** open/filter/select causes **no focus-sync storm**
  (`focus_syncs` ≤ 2).

---

## 5. Memory / occupancy

The harness now samples every registered occupancy provider every 500 ms and
writes a per-run `memory.tsv` (see §1). The three animation-heavy tabs were
re-run with a **20 s** idle window (`async`). Eight providers report:
`ViewGraph.nodesByIdentity`, `MeasurementCache.entriesByIdentity`,
`RetainedFrameIndex.placedByIdentity`, `AnimationController.activeAnimations`,
`TextLayoutCache.entries`, `TextFigureSupport.metricsCache`,
`ImageAssetRepository.decodedImages`, and the synthetic
`MemoryMetricRegistry.providerCount`.

### H5 — Task Progress `TextLayoutCache` growth **(NOT a leak — corrected 2026-05-28)**

**Original (incorrect) observation.** Over a 20 s idle window,
`TextLayoutCache.entries` climbed **monotonically 104 → 162** (≈ 2.9 entries/sec,
no plateau) while every other store stayed flat. An earlier draft concluded this
was an unbounded leak.

**Correction.** This was a **false alarm caused by too short an observation
window.** `TextLayoutCache` is an **LRU cache bounded at capacity 256**
(`TextLayoutCache.swift:84`, `evictIfNeeded` at `:211`, access-log compaction at
`:195`). The shimmer/spinner mints a new layout key every frame (~28 fps cache
misses), so entries fill *toward* 256 at ~2.9/sec — reaching the cap at ~52 s,
well past the 20 s sample. Beyond 256 the cache LRU-evicts and entries plateau.

**Verification.** Code inspection plus tests:
`Tests/SwiftTUITests/TextLayoutCacheTests.swift` —
`evictionKeepsMostRecentlyUsedEntry` proves the cap, and a new
`uniqueKeyChurnStaysBoundedAtCapacity` reproduces this exact scenario (5000
unique-key "frames" at capacity 16 → entries plateau at 16, evictions = 4984,
access log bounded). The borders-pane access-log leak this cache once had was
already fixed (commit `e4d96c1`; see the `warmCacheHitsKeepAccessLogBounded`
test).

**Residual note (minor, not actionable).** Animated-*text* content (Task
Progress) gets ~0 cache benefit — every frame misses, stores, and evicts — so it
pays the full `uncachedTextLayout` cost each frame plus eviction bookkeeping.
Animated-*color* content (Animations) holds the cache flat (same layout keys).
Memory is bounded either way; this is a CPU footnote subsumed by H1, not a leak.

### Borders & Animations: no leak (P4 refuted)

| Tab | window | ViewGraph | TextLayoutCache | MeasurementCache | providerCount |
| --- | --- | --- | --- | --- | --- |
| animations | 20 s / 345 frames | 428 → 428 | 163 → 163 | ~660 (flat) | 7 → 7 |
| borders-and-shapes | 20 s / 554 frames | 307 → 307 | 145 → 145 | 628 → 636 (noise) | 6 → 6 |
| task-progress | 20 s / 460 frames | 203 → 204 | **104 → 162** | 310 → 315 | 6 → 6 |

Borders runs hot (554 frames) but **does not leak** — its stores are flat. This
refutes the historical borders-pane leak at SHA `843da06e`, consistent with the
recent `e4d96c1 "fix for observed memory leak"`. `AnimationController.activeAnimations`
reflects active animations (animations: 2, borders: 1) and returns to baseline —
not a leak.

> Method note: this is element *count* growth (always reported); byte weight is
> best-effort and absent for most providers. A monotonic count slope with no
> plateau is the leak signal.

---

## 6. Authentic-terminal cross-check (kitty — Route B)

The real `gallery-demo` binary was built with `.profiling()` enabled (against the
local `swift-tui`, since tag `0.0.5` lacks `SwiftTUIProfiling`) and run inside
**kitty 0.46.2** at 110×38 with `SWIFTTUI_PROFILE="frames,cpu,memory@1s;tsv=…"`,
idling ~12 s per tab. This exercises the *real* terminal presentation path that
the in-memory `PerfTerminalHost` stubs out.

| Tab | frames | strategy | `damage_cells` med | `present_cells` med | `present_bytes` med | `present_ms` p95 |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| animations | 390 | 100 % incremental | 0 | **0** | **0** | 0.01 ms |
| borders-and-shapes | 321 | 100 % incremental | 70 | 70 | 1822 | 0.08 ms |
| physics | 52 | 98 % incremental* | 15 | 15 | 232 | 0.03 ms |
| task-progress | 307 | 100 % incremental | 4 | 4 | 109 | 0.02 ms |

*physics: only the initial paint is `full`; the rest incremental.

**Findings:**

1. **Presentation is fully incremental.** The stub's "every frame is a 4180-cell
   full repaint" was 100 % artifact. The real terminal repaints only the damaged
   region.
2. **`present_cells` == `damage_cells`.** The real terminal writes exactly the
   damaged cells, so the in-process `damage_cells` column was an accurate proxy
   for real write size all along — the in-process methodology holds for
   everything except the (stubbed) `present_*` columns.
3. **Terminal-write cost is negligible.** Even borders' 1822 bytes/frame
   (~49 KB/s of escape sequences) presents in 0.08 ms. Versus 6–14 ms of pipeline
   per frame, terminal I/O is <1 % of frame cost. **The Phase-4 prediction that
   in-process under-counts real cost is refuted** — the escape-sequence cost is
   immaterial; in-process pipeline timings are representative.
4. **Animations writes 0 bytes for 390 frames** — confirming H1 is pure CPU
   waste with zero terminal benefit (see H1).

`present_bytes` per damaged cell varies with content (~26 B/cell for borders'
gradients, ~15 B/cell for physics) but never approaches a bottleneck.

## 7. Recommendations (by impact ÷ effort)

1. **Investigate skipping zero-damage / zero-invalidation frames (H1).**
   Highest impact: directly eliminates Animations' 274 wasted frames and ~5.6
   CPU-s/10 s, and helps any perpetually-active animation. Start by confirming the
   AnimationsTab idle animations should be active at all; then assess a runtime
   commit short-circuit. *Effort: medium (runtime change needs care).*
2. **Profile the `resolve` hot path on a Calculator click (H2/H3).**
   13.9 ms resolve for a 2-cell change is the clearest single-interaction
   inefficiency and exercises the fixed cost that affects every tab. Check
   invalidation scope first (cheap), then the resolve path. *Effort: low to start.*
3. ~~Bound `TextLayoutCache` / fix the Task Progress leak (H5).~~ **Withdrawn —
   not a leak (H5, corrected).** The cache is already LRU-bounded at 256; no
   action needed. (Optional CPU micro-opt: skip the cache store for content that
   changes every frame, but this is subsumed by H1.)
4. **✅ Done — kitty cross-check (§6).** Verdict: terminal-write cost is
   negligible and presentation is fully incremental, so all optimization effort
   belongs in the **frame pipeline (CPU)**, not presentation. No presentation
   work is warranted.
5. **(Product) Consider throttling Borders/Task-Progress animation cadence (H4).**
   Only if a lower fps is visually acceptable. *Effort: low; impact moderate but
   it is legitimate work, not waste.*

---

## 8. Artifacts & reproduction

- Aggregated table: `docs/perf/2026-05-28-gallery-baseline/aggregate.csv`
- Aggregator (stdlib, header-indexed): `docs/perf/2026-05-28-gallery-baseline/aggregate.py`
- Occupancy traces (20 s idle): `docs/perf/2026-05-28-gallery-baseline/memory/*.tsv`
- Real-terminal (kitty) frame traces: `docs/perf/2026-05-28-gallery-baseline/kitty/*-kitty-frames.tsv`
- Raw per-run output: `swift-tui/.perf/runs/*` (gitignored). Each dir has
  `frames.tsv`, `cpu.tsv`, `memory.tsv`, `events.tsv`, `run.json`,
  `summary.json`. The 20 s memory re-runs of animations / borders-and-shapes /
  task-progress are the latest dirs for those scenarios.
- Reproduce one run:
  ```bash
  cd swift-tui
  swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
    run --scenario gallery-animations --modes async --iterations 1 --configuration release
  python3 ../docs/perf/2026-05-28-gallery-baseline/aggregate.py
  ```
- Reproduce a kitty run (real terminal; opens a GUI window):
  ```bash
  BIN=swift-tui-examples/gallery/.build/arm64-apple-macosx/release/gallery-demo
  SWIFTTUI_PROFILE="frames,cpu,memory@1s;tsv=/tmp/anim.tsv" \
    kitty -o allow_remote_control=yes --listen-on unix:/tmp/k \
    -o initial_window_width=110c -o initial_window_height=38c \
    -e "$PWD/$BIN" --tab animations &
  sleep 15; kitty @ --to unix:/tmp/k close-window
  ```

**Committed reusable tooling** (`swift-tui` local `main`, commit `589464de`,
not pushed):
- `Sources/SwiftTUIProfiling/Memory/ProfiledMemoryAccess.swift` — `@_spi(Runners)`
  occupancy accessor (SPI is excluded from the public-API baseline, so the gate
  stays green).
- `Tools/TermUIPerf/Sources/TermUIPerf/PerfMemorySampler.swift` + the `runWindow`
  memory-sampling wiring and `PerfScenarioRegistry.additionalScenarios` hook in
  `Scenarios/PerfScenario.swift`.

**Coordination-only edits (uncommitted; must NOT land in the public child
manifests):**
- `swift-tui`: `Tools/TermUIPerf/Package.swift` (+gallery path dep),
  `…/PerfRunConfig.swift` (+scenario names), `…/Scenarios/GalleryTabScenario.swift`,
  `…/Scenarios/CommandPaletteScenario.swift`, `…/Scenarios/GalleryScenarioRegistration.swift`,
  `…/main.swift` (registration hook).
- `swift-tui-examples`: `gallery/Package.swift` (local `swift-tui` path dep +
  `SwiftTUIProfiling`), `gallery/Sources/GalleryDemo/GalleryDemoApp.swift`
  (`.profiling()`) — needed only to build a profiling-enabled gallery binary for
  the kitty run.
