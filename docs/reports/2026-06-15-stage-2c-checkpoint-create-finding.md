# Stage 2C / Item A — Checkpoint-Create Finding (deferred)

- **Date:** 2026-06-15
- **Pin investigated:** `swift-tui 30fc38bf` (no code landed; probe reverted).
- **Goal item:** [A — Stage 2C checkpoint create](../plans/2026-06-15-001-perf-phase-completion-goal.md)
- **Outcome:** the cheap node-image-reuse lever is a **measured no-op**; the deep
  create optimization is **deferred** to the structural items (E / persistent
  graph-state split), per the [Stage 2 design doc's](2026-06-15-stage-2-applied-mutation-delta-checkpoint-design.md)
  own sequencing.

## What was confirmed

The re-baseline ([report](2026-06-15-perf-phase-rebaseline.md)) put
`head_graph_checkpoint_create_p50_ms` at 1.18 ms @44 rows / 4.33 ms @176 — two
full `viewGraph.makeCheckpoint()` calls per abortable frame (baseline at frame
start + prepared after resolve). The
[create-split probe](../perf/checkpoint-create-split-probe/README.md) localized
that cost:

| scenario | node-checkpoint build | graph-field copy |
| --- | ---: | ---: |
| sheet 176 | 794.9 µs/call | 0.49 µs/call (0.06%) |
| narrow 40 | 297.2 µs/call | 0.30 µs/call (0.10%) |

**The entire create cost is building the per-node checkpoint dictionary.** The
~30 graph-field copies are COW retains and effectively free — so any
"graph-field delta" work would optimize the wrong half.

## What was tried and reverted (Stage 2C.1, no-op)

Reuse the baseline checkpoint's per-node image for every node whose
`checkpointMutationGeneration` is unchanged, rebuilding only touched/created
nodes — symmetric to Stage 2B's restore scoping, riding the same generation
invariant. Implemented, unit-proven byte-equivalent (extended
`ViewGraphDeltaCheckpointShadowTests`; all 47 graph tests green), then measured:

| config (drift control = restore p50) | ckpt_create | restore (ctl) |
| --- | ---: | ---: |
| narrow 40 (control flat, +0.0%) | **−2.1%** (noise) | +0.0% |
| sheet 44 (control +2.9%) | +1.3% (≈flat) | +2.9% |
| sheet 176 (control +12.7% — drift) | +9.6% (untrustworthy) | +12.7% |

On the one drift-free config (narrow 40), create moved within noise. **No-op.**

### Why it was a no-op

`makeNodeCheckpoints` reconstructs an N-entry `Dictionary` every call. The probe
shows the cost is that O(N) dictionary build, not the per-node `ViewNode.Checkpoint`
struct content (its members are COW). Reusing unchanged *images* while still
inserting N entries into a fresh dictionary leaves the dominant cost in place.
On sheet root-evaluation frames the within-frame reuse rate is additionally low
(most nodes are re-touched), so even a perfect image-reuse saves little there.

## Why deferred, not pursued further

The only create optimizations that actually remove the O(N) dictionary build are
structural, and both are explicitly out of scope for a quick slice:

1. **Persistent copy-on-mutation node-checkpoint store** — keep a live
   node-checkpoint dictionary on `ViewGraph`, mutate only changed entries in
   place (COW), hand out an O(1) copy as the checkpoint. This is the Stage 2
   design doc's "applied-mutation delta checkpoint" carried to the *create*
   side: high blast radius (all 30 `recordCheckpointMutation` seams must also
   patch the store; created/removed-node and baseline/prepared bookkeeping),
   exactly the doc's deferred slice.
2. **Persistent graph/state split** — checkpoints become version handles rather
   than object snapshots. The design doc names this "a later graph-storage
   project, not the immediate implementation."

Both also compound with **Item E (frontier narrowing)**: fewer touched nodes per
frame both shrinks the delta a copy-on-mutation store must capture and raises
reuse rates. Per the goal's sequencing ("Item E only as a designed successor once
A–C quantify what the root walk still costs"), the right order is to bank the
cheaper Item C win first, then weigh the persistent-store work against Item E.

Create remains the #1 head *bookkeeping* residual, but at ~16% of `head_prepare`
its ceiling is modest, and the cheap lever is exhausted. **Item A is parked**
behind the structural work; the probe is archived for when that work begins.

## Artifacts

- Probe: [docs/perf/checkpoint-create-split-probe/](../perf/checkpoint-create-split-probe/README.md)
- A/B + probe runs: `/tmp/swifttui-rebaseline-2026-06-15/` (ab/, probe-*).
