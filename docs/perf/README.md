# Performance Scenarios & Baselines

Two ways to reproduce SwiftTUI's performance hot-spots, plus a real-terminal
cross-check. The hot-spots themselves are documented in
[`../reports/2026-05-28-gallery-performance-report.md`](../reports/2026-05-28-gallery-performance-report.md).

## Tier 1 — Everyday: committed synthetic scenarios (no overlay)

Framework-only scenarios in `swift-tui/Tools/TermUIPerf` that reproduce the
*shapes* of the hot gallery tabs. They depend on nothing but `SwiftTUI`, so they
run from a clean `swift-tui` checkout with no coordination overlay:

| Scenario (`--scenario`) | Reproduces | Shape (verified) |
| --- | --- | --- |
| `synthetic-offscreen-phase-animator` | H1 | perpetual off-screen `PhaseAnimator` → many committed frames at `damage_cells = 0` |
| `synthetic-continuous-animation` | H4 (borders) | continuous `Spinner` repaint → committed frames at `damage_cells = 1` every tick |
| `synthetic-text-shimmer` | H4 (task-progress) / H5 | `TimelineView(.animation)` changing text → fresh `TextLayoutCache` key per tick |

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

## Tier 2 — Full fidelity: the real 18-tab gallery (overlay)

The real `GalleryView` scenarios depend on the `swift-tui-examples/gallery`
package, so they **cannot** be committed to the public `swift-tui` manifest (that
would couple a public child to a sibling repo). They live as coordination-only
edits held in `swift-tui`'s **`git stash@{0}`** — `GalleryTabScenario`,
`CommandPaletteScenario`, `GalleryScenarioRegistration`, the `main.swift`
registration hook, and the `Package.swift` (+gallery path-dep) /
`PerfRunConfig.swift` (+19 gallery scenario names) additions.

To run the real gallery for full-fidelity numbers:

```bash
cd swift-tui-org
# Materialize a throwaway overlay of the working trees + env vars:
eval "$(bazel run //:open_overlay -- --print-env examples 2>/dev/null)"
# Apply the coordination-only gallery scenarios INTO the overlay copy only:
git -C swift-tui stash show -p stash@{0} | git -C "$SWIFTTUI_CHECKOUT" apply
# Run a gallery tab from the overlay (its Package.swift carries the gallery
# path-dep; the committed swift-tui one never does):
cd "$SWIFTTUI_CHECKOUT"
swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
  run --scenario gallery-animations --modes async --iterations 1 --configuration release
```

Notes:
- The overlay is a throwaway copy; edits inside it are not carried back to the
  child repos. Re-run `open_overlay` to refresh. See
  [`../CROSS-REPO-DEVELOPMENT.md`](../CROSS-REPO-DEVELOPMENT.md).
- Verify the stash before relying on it: `git -C swift-tui stash show --stat stash@{0}`
  should list `GalleryTabScenario.swift` et al. If the stash index has shifted,
  adjust `stash@{0}` accordingly; if it is gone, the scenarios can be
  reconstructed from §8 of the baseline report.
- **Never commit the gallery `Package.swift`/`PerfRunConfig.swift` additions into
  the public `swift-tui` repo** — they are coordination-only.

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

- [`2026-05-28-gallery-baseline/`](2026-05-28-gallery-baseline/) — the original
  18-tab data-collection pass (in-process + kitty cross-check).
- Report: [`../reports/2026-05-28-gallery-performance-report.md`](../reports/2026-05-28-gallery-performance-report.md).
