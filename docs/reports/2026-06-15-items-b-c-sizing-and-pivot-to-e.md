# Items B/C sizing + strategic pivot to Item E

- **Date:** 2026-06-15
- **Pin:** `swift-tui 30fc38bf` (no code landed; sizing from existing TSV).
- **Goal:** [perf phase completion goal](../plans/2026-06-15-001-perf-phase-completion-goal.md)

## Item B — `restoreRuntimeRegistrations` reuse-walk (CLOSED, not justified)

The hot instance is the per-reuse-hit recursive subtree walk at
`ViewFoundation.swift:289` (`restoreRuntimeRegistrations(for: reused)` →
`ViewGraphRuntimeRegistrationRestorer.restoreResolvedSubtree`: per node a
`structuralPath` lookup + Set build + sort + `restoreOwnRuntimeRegistrations`).
Sized from the re-baseline `frames.tsv` (`resolved_reused` = `reused/total`):

| config | reused nodes/frame (median) | max | resolve_ms (median) |
| --- | ---: | ---: | ---: |
| narrow 40 | 360 | 361 | 1.30 |
| sheet 44 | **0** | 223 | 4.96 |
| sheet 176 | **0** | 883 | 17.97 |

**On the sheet hot path the walk does not run** — median reuse is 0 because
sheet interaction frames are root-evaluation (recompute everything, no reuse
hits). The walk is only material on the narrow/high-reuse path (~360
nodes/frame ≈ 0.2–0.5 ms of a 1.3 ms resolve). Per the goal's criterion
("commit B's cache only if the probe justifies it"), a narrow-only ~0.3 ms win
behind a cross-frame cache (with its own invalidation risk) is **not justified**.
Closed.

## Item C — `processResolvedTree` (bounded on the hot path; deferred)

The unconditional full-tree animation-snapshot walk (0.47 ms @44 / 1.74 ms @176)
is only safely *skippable* when the resolved tree is unchanged (it builds the
full identity set for insert/remove detection, so scoping to a subtree breaks
removal detection). On sheet interaction frames the tree changes, so the walk is
needed; the skippable frames are the unchanged ones (often already elided). High
blast radius (animation/transition correctness in an under-tested frame class)
for a hot-path win that root-evaluation also bounds. Deferred behind Item E.

## Strategic convergence: the sheet hot path is gated on Item E

Three independent investigations converge on one cause:

- **A (checkpoint create):** node-image reuse is a no-op because root-evaluation
  re-touches most nodes (low within-frame reuse) and the O(N) dict build remains.
- **B (restore-walk):** absent on sheet because reuse is 0 (root-evaluation).
- **C (`processResolvedTree`):** walks the whole tree because the whole tree
  changes under root-evaluation.

The common upstream cause is the **every-frame force-queue of the portal root**
(`DefaultRendererFrameHeadCoordinator.swift`), which makes every sheet
interaction frame a full top-down re-resolve (reuse ≈ 0, all nodes touched). This
is exactly **Item E (frontier narrowing)**. The goal sequenced E as a designed
successor "only once A–C quantify what the root walk still costs" — that
precondition is now met with data: the root walk is what bounds A, B, and C.

**Next:** Item E, design-first — enumerate every consumer of the root walk's
incidental guarantees before any code (the goal's E entry condition). The
cheaper head-residual levers are exhausted on the hot path; E is the lever that
unlocks them.
