# Perf - Rendering Performance Remaining Opportunities

**Date:** 2026-06-02
**Status:** Opportunity register. This is not an execution proposal.
**Scope:** `swift-tui` retained frame-tail products, retained indexes, raster
residuals, layout validation, and performance measurement infrastructure.
**Predecessor:**
[`2026-06-02-002-rendering-performance-next-wave-proposal.md`](2026-06-02-002-rendering-performance-next-wave-proposal.md).

---

## Purpose

This document captures the performance opportunities left after the next-wave
rendering work. It does not recommend landing all of them. Several require
architectural changes, new proof models, or breaking internal representation
changes before implementation would be safe.

The main shift since the predecessor is that hidden off-screen elided-frame CPU
is no longer the highest-confidence hotspot. The remaining performance slope is
mostly in frame-tail products and the infrastructure needed to reuse them
without breaking observable ordering.

## Current State

Implemented in the current `swift-tui` working tree:

- Elided-frame diagnostics now expose micro-spans in `frames.tsv` and
  TermUIPerf summaries.
- Off-screen property-animation deadline ticks can advance before frame-head
  preparation when the runtime proves the redraw identities are off-screen.
- Release rasterization trusts sound incremental damage by default, while debug
  keeps verification and environment variables can force either mode.
- Retained draw extraction can reuse clean previous draw subtrees.
- Semantic subtree reuse remains unimplemented.
- Retained indexes still rebuild full maps after commit.
- Measurement and placement work stacks now flush local work metrics once, but
  retained layout validation still performs scaling work.

Validation status:

- Focused runtime, core, raster, layout, pipeline, and TermUIPerf suites passed.
- `git -C swift-tui diff --check` passed.
- Full `swiftly run swift test --package-path swift-tui` and a `--no-parallel`
  rerun both crashed `swiftpm-testing-helper` with signal 11 before reporting a
  failing assertion. That is a validation gap to triage separately.

## Latest Measurement Signals

Short release runs under `/tmp/swifttui-perf-candidate-final`:

| Scenario | Iterations | Median total CPU | Median frame counts | Interpretation |
| --- | ---: | ---: | --- | --- |
| `synthetic-offscreen-phase-animator` async | 3 | 0.275s | 9 committed, 136 diagnostic, 127 elided | The P0 fast path produced the largest win; elided animation tick p50 is 0.01 ms. |
| `synthetic-narrow-invalidation`, rows=40 async | 3 | 0.206s | 18 committed, 18 diagnostic | CPU/frame is still 11.44 ms; repeated retained-tree frames remain the best place to look. |

Rows=40 repeated input frames still show median work of roughly:

| Field | Median |
| --- | ---: |
| `measure_ms` | 1.09 ms |
| `place_ms` | 0.55 ms |
| `semantics_ms` | 0.73 ms |
| `draw_ms` | 0.25 ms |
| `raster_ms` | 0.63 ms |
| `pipeline_ms` | 4.29 ms |
| `worker_layout_compute_ms` | 1.61 ms |
| `worker_raster_compute_ms` | 2.26 ms |
| `main_actor_suspended_ms` | 4.06 ms |

These numbers are modestly better than the predecessor baseline, not materially
flat. The remaining opportunities should therefore be treated as structural
follow-ups, not small constant-factor cleanups.

## Opportunity 1 - Persistent Retained Indexes

**What it could improve:** `RetainedFrameIndex` still rebuilds full identity maps
after each committed frame. As more frame-tail products become reusable, full
index rebuilds become the next place O(tree) work can hide.

**Current blocker:** the runtime does not yet have a strong enough structural
identity model for safe subtree replacement. A prior spike exposed hazards where
`Identity.parent` and actual structural containment diverge, especially around
`.id`, duplicate identities, presentation portal roots, root identity paths, and
overlay-owned subtrees.

**Rough requirements to unblock:**

- Store explicit parent/child structural adjacency for the committed resolved,
  measured, and placed products.
- Track subtree identity sets from structural adjacency, not only from identity
  path conventions.
- Define how duplicate identity diagnostics, portal roots, and overlay roots are
  represented before they enter retained indexes.
- Build a per-frame structural diff that can replace changed roots and prune
  removed roots without leaking stale entries.
- Add debug comparison that constructs both the persistent index and a full
  rebuilt index, then asserts byte-equivalence.

**Validation that would be required:**

- Insertion, deletion, reorder, focus move, active animation overlay, portal, and
  scroll cases.
- Tests where path identity and structural containment intentionally diverge.
- A rows=6/20/40 `synthetic-narrow-invalidation` sweep to prove repeated frames
  stop rebuilding full indexes.

## Opportunity 2 - Ordered Semantic Fragment Reuse

**What it could improve:** semantic extraction still walks the tree for narrow
input frames. Rows=40 repeated frames still spend about 0.73 ms in semantics even
when most resolved nodes are reused.

**Current blocker:** semantic output is not just a bag of identity-keyed records.
Append order is observable for focus traversal, pointer hit testing,
accessibility order, and live-region behavior. Reusing arbitrary semantic
subtrees by identity would risk changing those observable orders.

**Rough requirements to unblock:**

- Replace append-only semantic snapshots with an ordered persistent semantic
  tree or fragment structure.
- Define fragment boundaries that preserve sibling order, overlays,
  presentation portals, focus candidate ordering, hit-test ordering, and
  accessibility traversal.
- Store projection signatures for semantic fragments so a clean structural
  subtree can be reused only when inherited semantic context is also equivalent.
- Keep conservative barriers for custom layout, foreign surfaces, presentation
  overlays, and any scope where semantic ordering cannot be proven.

**Validation that would be required:**

- Full-extract vs fragment-merge equivalence tests for mixed dirty and clean
  trees.
- Focus traversal, pointer routing, accessibility snapshot ordering, and
  live-region tests.
- Performance proof that `semantics_ms` drops without moving the same cost into
  fragment merge or index construction.

## Opportunity 3 - Raster Residuals Beyond Damage Trust

**What it could improve:** release builds now trust sound incremental damage,
but rows=40 repeated frames still spend about 0.63 ms in `raster_ms` and 2.26 ms
in worker raster compute. The remaining cost is likely row repaint, draw-tree
traversal, worker scheduling, or command generation rather than just final
damage verification.

**Current blocker:** the current diagnostics do not break raster work into
enough phases to identify the next safe target. Skipping verification alone does
not prove whether the residual is previous-surface copying, dirty-row clearing,
draw traversal, row compositing, visible-identity collection, or worker overhead.

**Rough requirements to unblock:**

- Add raster micro-spans for previous-surface copy, dirty-row clearing, draw-tree
  traversal, row compositing, visible-identity collection, damage refinement,
  and worker handoff.
- Decide whether draw-node dirty-subtree rasterization is sufficient or whether
  the runtime needs a row-command cache keyed by draw-subtree signature.
- Keep image attachments, graphics replay, wide glyphs, and full-text/full-
  graphics barriers conservative.
- Preserve the existing debug damage verification path as the correctness oracle
  while changing release behavior.

**Validation that would be required:**

- Byte-identical raster output against full rasterization for text, wide glyph,
  style, graphics, and image cases.
- Forced-bad-damage tests that continue to fail under verification mode.
- Rows=6/20/40 sweeps plus a visible animation scenario to catch regressions in
  high-frequency repaint paths.

## Opportunity 4 - Retained Layout Validation and Proposal Caching

**What it could improve:** retained measurement and placement still scale with
tree size. The metric-flush change reduces mutex churn, but it does not avoid
deep validation or repeated measurement work.

**Current blocker:** the layout engine lacks cheap structural/layout equivalence
proofs for retained products. Without those proofs, skipping validation risks
wrong sizes, stale placement, or incorrect geometry/named-coordinate-space
metadata.

**Rough requirements to unblock:**

- Add structural and layout signatures to resolved and measured products.
- Define which layout inputs invalidate those signatures: proposal, environment,
  layout-dependent content, viewport, named coordinate spaces, custom layout,
  animation geometry, and scroll state.
- Add stack-specific proposal classification so fixed or repeated proposals can
  reuse known measurements without deep subtree checks.
- Move more `LayoutPassContext` state into worker-local fragments, merging only
  final metrics, cache writes, and placed-frame table updates.

**Validation that would be required:**

- Hash-equivalence debug mode that compares signature-based reuse to deep
  equivalence.
- Layout snapshot equality for fixed, flexible, stack, lazy stack, viewport, and
  named-coordinate-space cases.
- Rows=6/20/40 proof that `measure_ms`, `place_ms`, and
  `worker_layout_compute_ms` drop without changing layout snapshots.

## Opportunity 5 - Measurement and Gate Reliability

**What it could improve:** performance decisions need repeatable full-suite and
perf-harness evidence. The current focused validation is useful, but the full
SwiftPM test helper crash and non-durable real-gallery overlay path leave gaps.

**Current blocker:** there is no current durable full-fidelity gallery scenario
bundle, and the full package test runner crashes before producing an actionable
failure. The short candidate runs used 3 iterations, which is useful for smoke
signal but not enough for final performance claims.

**Rough requirements to unblock:**

- Triage the `swiftpm-testing-helper` signal 11 crash separately from runtime
  correctness.
- Rebuild a durable full-gallery overlay recipe from the 2026-05-28 report, or
  explicitly retire it in favor of committed framework-only scenarios.
- Prefer 20-iteration rows=6/20/40 sweeps for final performance claims.
- Keep TermUIPerf summaries focused on diagnostic frames, committed frames,
  elided frames, drops, cancellations, worker compute, and presentation metrics.

**Validation that would be required:**

- A reproducible command for the full-suite crash, with crash logs or a minimal
  isolated test-runner failure.
- Clean TermUIPerf package tests and dependency resolution with
  `--disable-automatic-resolution`.
- Compare reports that show variance and classify deltas as signal or noise.

## Opportunity 6 - Off-Screen Elision Residuals

**What it could improve:** P0 already moved the off-screen scenario from the
largest surprise to a lower-priority residual. There may still be small CPU in
diagnostics emission, timer cadence, run-loop scheduling, or animation state
bookkeeping.

**Current blocker:** after the pre-frame-head fast path, the visible p50 elided
animation tick cost is tiny. The remaining CPU is spread across the run-loop and
diagnostic observation window rather than a clearly named heavy phase.

**Rough requirements to unblock:**

- Add separate spans for diagnostics/TSV emission and run-loop wake scheduling if
  off-screen elision becomes important again.
- Compare against a no-diagnostics run to quantify profiling overhead.
- Keep finite completion behavior and animation-state advancement tests in the
  loop before changing anything here.

**Validation that would be required:**

- `synthetic-offscreen-phase-animator` with diagnostics on/off.
- Tests for finite completions, reveal-after-elision, transition barriers,
  portal state, and runtime registrations.

## Lower-Priority or Explicit Non-Goals

- Do not silently reduce visible animation cadence without explicit product
  policy.
- Do not treat a local `git stash@{N}` as a durable gallery measurement source.
- Do not replace the phase-product model wholesale before the narrower retained
  product, structural-index, raster, and layout-proof gaps are understood.
- Do not interpret the full-suite signal 11 crash as a runtime assertion failure
  until it is reproduced with actionable failure output.

## If This Becomes An Execution Plan

The safest order would be:

1. Fix measurement reliability first: full-suite crash triage, durable real-
   gallery stance, and 20-iteration sweeps.
2. Add raster and retained-index instrumentation before optimizing those paths.
3. Design the structural identity model before any persistent index work.
4. Design ordered semantic fragments before semantic subtree reuse.
5. Only then consider breaking internal representation changes for retained
   frame-tail products.
