# Observable Fan-Out Perf Workload

- **Date:** 2026-06-16
- **Status:** workload added; runtime behavior unchanged.
- **Surface:** `swift-tui/Tools/TermUIPerf`
- **Scenario:** `synthetic-observable-fanout`

## Purpose

The previous perf suite did not quantify SwiftUI-style observable key-path
fan-out or sub-body memoization. That made the opportunity real but
unrankable: SwiftTUI records observable graph dependencies as object tokens, so
a mutation to one property can expand from the Observation bridge's changed
identity to every live reader of the same model object.

`synthetic-observable-fanout` is the committed workload for that gap. It does
not change runtime behavior. It creates a framework-only `@Observable` model
with `hot`, `cold`, and `rare` properties, mutates `hot`, and records the
resulting frame diagnostics.

## Shapes

Default shape:

- `TERMUI_PERF_OBSERVABLE_SHAPE=fanout` or unset.
- Many sibling cells read different properties on the same observable object.
- A `hot` mutation should ideally dirty only hot readers; current object-token
  expansion dirties same-object peer readers too.

Large-body shape:

- `TERMUI_PERF_OBSERVABLE_SHAPE=large-body`.
- One body reads `hot` and builds a large payload derived from `cold`.
- Key-path fan-out alone cannot avoid the body work; this is the sub-body memo
  calibration shape.

Sizing knobs:

- `TERMUI_PERF_OBSERVABLE_ROWS` (default `12`)
- `TERMUI_PERF_OBSERVABLE_COLUMNS` (default `4`)

## Sanity Check

These are single-iteration release smoke measurements from the implementation
session, not baselines. Artifacts were written under
`/tmp/swifttui-observable-fanout-check/`.

| config | total CPU | frames | aggregate head prepare p50 | diagnostic shape |
| --- | ---: | ---: | ---: | --- |
| default fanout, rows 12 x 4 | 0.1206 s | 13 | 4.91 ms | hot-click frames recomputed `52/72`; settled frames `23/72` |
| large-body, rows 12 x 4 | 0.0890 s | 11 | 1.92 ms | hot-click frames recomputed large body payload |
| amplified fanout, rows 80 x 4 | 1.0201 s | 13 | 23.04 ms | hot-click frames recomputed `211/412`; settled frames `23/412` |

The amplified fanout pass showed the intended scaling signal. Click frames at
rows 80 had `resolve_ms` around `91-92 ms` and `head_prepare_ms` around
`99-100 ms`, while interleaved settled frames stayed around `0.8-0.9 ms`
`resolve_ms`.

## Usage

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

Use same-session A/Bs and compare the per-frame `resolve_ms`,
`head_prepare_ms`, `resolved_computed`, and `resolved_reused` columns before
claiming any key-path fan-out or sub-body memo win.
