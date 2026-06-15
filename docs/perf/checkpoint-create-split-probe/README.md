# Checkpoint-create split probe (archived)

Splits `ViewGraph.makeCheckpoint()` cost into **node-checkpoint build**
(`ViewGraphNodeCheckpointing.makeNodeCheckpoints`) vs **graph-field copy** (the
~30-field `Checkpoint(...)` init), gated by `SWIFTTUI_CKPT_PROBE=1`, emitting
`CKPT_PROBE count=… node_us_avg=… field_us_avg=…` to stderr every 200 calls.

## How to reapply

1. Drop `CheckpointCreateProbe.swift.archived` into
   `swift-tui/Sources/SwiftTUICore/Resolve/CheckpointCreateProbe.swift`.
2. Apply `viewgraph-instrumentation.patch` (the `makeCheckpoint` split-timer)
   to `swift-tui` from its repo root.
3. **Clean** `Tools/TermUIPerf/.build` before building — adding a source file
   trips the nested-package stale-discovery trap.
4. `SWIFTTUI_CKPT_PROBE=1 <knobs> termui-perf run …` and grep `CKPT_PROBE`.

## Findings (swift-tui 30fc38bf, AC, release)

| scenario | node_us_avg | field_us_avg | node share |
| --- | ---: | ---: | ---: |
| sheet-open-latency, rows 176 | 794.9 | 0.49 | 99.94% |
| synthetic-narrow-invalidation, rows 40 | 297.2 | 0.30 | 99.90% |

**Checkpoint-create cost is essentially all in building the per-node checkpoint
dictionary; the graph-field copy is COW-cheap (negligible).** This is why
reusing unchanged node *images* while still reconstructing an N-entry dictionary
(the reverted Stage 2C.1 attempt) was a no-op — the dictionary build, not the
per-node struct content, is the cost.

See [reports/2026-06-15-stage-2c-checkpoint-create-finding.md](../../reports/2026-06-15-stage-2c-checkpoint-create-finding.md).
