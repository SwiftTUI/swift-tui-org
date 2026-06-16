# Performance Scenarios & Baselines

Two ways to reproduce SwiftTUI's performance hot-spots, plus a real-terminal
cross-check. The hot-spots themselves are documented in
[`../reports/2026-05-28-gallery-performance-report.md`](../reports/2026-05-28-gallery-performance-report.md).

## Tier 1 — Everyday: committed scenarios (no overlay)

Framework-only scenarios in `swift-tui/Tools/TermUIPerf` that reproduce the
*shapes* of the hot gallery tabs. They depend on nothing but `SwiftTUI`, so they
run from a clean `swift-tui` checkout with no coordination overlay:

| Scenario (`--scenario`) | Reproduces | Shape (verified) |
| --- | --- | --- |
| `example-app-shell-workflow` | app chrome/pane/presentation composition | scrollable main pane plus side inspector, dropdown/popover, sheet, and panel boundary |
| `gallery-animation-click` | H1/H4 representative gallery interaction | framework-only approximation of clicking into an animated gallery surface |
| `layout-scroll-burst` | layout invalidation under bursty input | short scroll/input burst that exercises coalescing and retained layout |
| `synthetic-offscreen-phase-animator` | H1 | perpetual off-screen `PhaseAnimator` → many committed frames at `damage_cells = 0` |
| `synthetic-narrow-invalidation` | H2/H3 | one small state change in a retained tree; resolve reuse should stay flat while tail work exposes scaling |
| `synthetic-continuous-animation` | H4 (borders) | continuous `Spinner` repaint → committed frames at `damage_cells = 1` every tick |
| `synthetic-text-shimmer` | H4 (task-progress) / H5 | `TimelineView(.animation)` changing text → fresh `TextLayoutCache` key per tick |
| `synthetic-observable-fanout` | observable key-path fan-out / sub-body memo | mutates one `@Observable` key path while same-object peers read other key paths; opt-in `large-body` shape measures one body rebuilding a large cold payload |

```bash
cd swift-tui
swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
  run --scenario synthetic-offscreen-phase-animator --modes async \
  --iterations 20 --configuration release
```

Each run writes per-iteration `frames.tsv`, `cpu.tsv`, `memory.tsv`,
`memory_growth.tsv`, `summary.json`, plus a per-mode `aggregate-<scenario>-<mode>.json`
(run-to-run median ± stddev / CV — G2) and the growth/plateau leak analysis
(`memory_growth.tsv` — G4). Compare two runs with `termui-perf compare`.

These scenarios are auto-covered by `ScenarioSmokeTests` (it iterates
`PerfScenarioRegistry.all`), so they cannot silently rot.

### Observable fan-out workload

Use `synthetic-observable-fanout` before taking on SwiftUI-style observable
key-path indexing or sub-body memoization. The default `fanout` shape measures
current object-token expansion: mutating `hot` should only require hot readers,
but the current graph dirties all readers of the same observable object. The
`large-body` shape measures a different cost: one view body reads `hot` and
builds a large payload derived from `cold`, so key-path fan-out alone is not
enough.

```bash
cd swift-tui
swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
  run --scenario synthetic-observable-fanout --modes async \
  --iterations 20 --configuration release

TERMUI_PERF_OBSERVABLE_ROWS=80 TERMUI_PERF_OBSERVABLE_COLUMNS=4 \
  swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
  run --scenario synthetic-observable-fanout --modes async \
  --iterations 20 --configuration release

TERMUI_PERF_OBSERVABLE_SHAPE=large-body TERMUI_PERF_OBSERVABLE_ROWS=80 \
  swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
  run --scenario synthetic-observable-fanout --modes async \
  --iterations 20 --configuration release
```

## Tier 2 — Full fidelity: the real 18-tab gallery (overlay)

The real `GalleryView` scenarios depend on the `swift-tui-examples/gallery`
package, so they **cannot** be committed to the public `swift-tui` manifest. A
fixed local stash index is not a durable source of truth for these scenarios;
current stashes may point to unrelated work.

The durable artifacts are:

- [`2026-05-28-gallery-baseline/`](2026-05-28-gallery-baseline/) — the captured
  full-gallery baseline data.
- [`../reports/2026-05-28-gallery-performance-report.md`](../reports/2026-05-28-gallery-performance-report.md) —
  the scenario design, cross-repo dependency shape, and reconstruction notes.
- [`../CROSS-REPO-DEVELOPMENT.md`](../CROSS-REPO-DEVELOPMENT.md) — how to
  materialize a throwaway coordination overlay.

To take new full-fidelity gallery measurements, first materialize an overlay and
reconstruct the coordination-only `TermUIPerf` gallery scenario files inside
that overlay from the report. The overlay copy may add a temporary
`swift-tui-examples/gallery` path dependency to `Tools/TermUIPerf/Package.swift`;
the public `swift-tui` checkout must not.

```bash
cd swift-tui-org
eval "$(bazel run //:open_overlay -- --print-env examples 2>/dev/null)"
cd "$SWIFTTUI_CHECKOUT"
# Reconstruct/apply the GalleryTabScenario and registration changes here.
swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
  run --scenario gallery-animations --modes async --iterations 1 --configuration release
```

The overlay is a throwaway copy; edits inside it are not carried back to the
child repos. Re-run `open_overlay` to refresh. **Never commit the gallery
`Package.swift` / `PerfRunConfig.swift` additions into the public `swift-tui`
repo**; they are coordination-only.

## Tier 3 — Authentic terminal (kitty)

Cross-check presentation cost on a real terminal (opens a GUI window). Confirms
the in-process pipeline numbers against real escape-sequence output:

```bash
BIN=swift-tui-examples/gallery/.build/arm64-apple-macosx/release/gallery-demo
SWIFTTUI_PROFILE="frames,cpu,memory@1s;tsv=/tmp/anim.tsv" \
  kitty -o allow_remote_control=yes --listen-on unix:/tmp/k \
  -o initial_window_width=110c -o initial_window_height=38c \
  -e "$PWD/$BIN" --tab animations &
sleep 15; kitty @ --to unix:/tmp/k close-window
```

(Requires a `.profiling()`-enabled `gallery-demo` build — see the report's §6.)

## Baselines

- [`../reports/2026-06-16-perf-signal-representativeness.md`](../reports/2026-06-16-perf-signal-representativeness.md) —
  maps the committed framework-only scenarios, including
  `example-app-shell-workflow`, to real example-app usage and marks which signals
  are representative, amplified diagnostics, or missing app-flow coverage.
- [`2026-05-28-gallery-baseline/`](2026-05-28-gallery-baseline/) — the original
  18-tab data-collection pass (in-process + kitty cross-check).
- Report: [`../reports/2026-05-28-gallery-performance-report.md`](../reports/2026-05-28-gallery-performance-report.md).
