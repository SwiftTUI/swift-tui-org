# Perf - Rendering Infrastructure Optimization Proposal

**Date:** 2026-06-02
**Status:** PROPOSED. Measurement-summary hardening has been implemented in the
working tree; runtime optimizations below are proposed follow-up work.
**Scope:** `swift-tui` rendering pipeline, TermUIPerf measurement infrastructure,
and host presentation paths.
**Predecessors:**
[`2026-05-28-gallery-performance-report.md`](../reports/2026-05-28-gallery-performance-report.md),
[`2026-05-30-h2-resolve-reuse-findings.md`](../reports/2026-05-30-h2-resolve-reuse-findings.md),
[`2026-05-30-h3-retained-subtree-findings.md`](../reports/2026-05-30-h3-retained-subtree-findings.md),
[`2026-05-31-commit-ms-registration-restore-fix-results.md`](../reports/2026-05-31-commit-ms-registration-restore-fix-results.md),
[`2026-05-31-place-ms-identical-subtree-sync-skip-results.md`](../reports/2026-05-31-place-ms-identical-subtree-sync-skip-results.md).

---

## Executive summary

The recent performance work has already landed the highest-confidence first
wave:

- off-screen animation frame elision;
- retained resolve reuse with frame-safety suppression;
- retained subtree bookkeeping fast paths;
- scoped runtime-registration restore;
- retained-placement metadata sync skip for identical subtrees;
- TermUIPerf scenarios, memory sampling, compare tooling, and frame diagnostics.

The next best work is not another broad rewrite. The strongest remaining
opportunities are smaller structural wins in the places that still perform
O(subtree) or O(surface * damage) work after a frame has already proven most of
the tree is retained.

Recommended order:

1. Finish measurement semantics so all future comparisons are trustworthy.
2. Carry forward placed-frame table entries for retained placement.
3. Narrow retained-reuse suppression to affected subtrees.
4. Add retained/incremental semantics and draw extraction.
5. Make host damage metrics and browser dirty-rect handling first-class.
6. Treat visible continuous animation and text churn as policy/admission work.

## Current model

The core frame product order remains:

```text
resolve -> measure -> place -> semantics -> draw -> raster -> commit
```

Interactive runtime scheduling maps those products onto:

```text
head -> animationInjection -> latePreferenceReconciliation -> fusedFrameTail -> commit
```

The runtime docs make the important distinction explicit: the fused tail is a
performance node over typed phase products, and host-facing damage is derived
after frame acquisition because async candidates can be cancelled, skipped,
dropped, or elided before any host sees them.

## Measurement hardening already added

TermUIPerf previously wrote full frame diagnostics to `frames.tsv`, but
`summary.json` reduced over `PerfTerminalHost.frameRecords`, which contained only
presented frames and stub presentation data. That meant summaries lost skipped,
elided, worker, drop, cancellation, blocked-main-actor, and suspended-main-actor
fields.

The working tree now adds:

- `swift-tui/Tools/TermUIPerf/Sources/TermUIPerf/FrameDiagnosticsTSVReader.swift`
  to parse `frames.tsv` into `PerfFrameRecord` values;
- `PerfScenarioRunner` summary reduction from the parsed diagnostics instead of
  the presented-frame stub;
- `SummaryReducer` presentation-duration reduction over committed frames only,
  so elided and dropped diagnostic rows do not become zero-duration
  presentation samples;
- regression tests for TSV parsing, skipped-frame summaries, missing columns,
  and presentation-duration filtering.

Validation already run:

```bash
swiftly run swift test --package-path Tools/TermUIPerf
bun run test
git -C swift-tui diff --check
```

Release probe:

```bash
swiftly run swift run --package-path Tools/TermUIPerf -c release termui-perf run \
  --scenario synthetic-offscreen-phase-animator \
  --modes async \
  --iterations 1 \
  --configuration release
```

Observed shape: 10 committed frames, 121 skipped/elided diagnostic rows, total
CPU 0.6283s, and presentation duration reduced over 10 committed frames only.

## Ranked opportunities

### P0 - Finish measurement semantics

**Why now:** The next runtime changes should be driven by comparisons that expose
the right denominator. The new parser makes `summary.json` more complete, but the
schema still merges several frame dispositions into `skipped_frame_count`, and
idle observation scenarios still emit negative input latency.

**Evidence:**

- Idle scenarios wait for a marker frame, then record `dispatchTimeSeconds`, then
  report the already-seen marker frame as the first matching frame. Examples:
  `SyntheticPhaseAnimatorScenario`, `SyntheticRepeatForeverScenario`, and
  `SyntheticShimmerScenario`.
- `frames.tsv` has an explicit `elided` column and drop/cancel fields, but
  TermUIPerf summaries do not yet expose distinct elided, dropped, and cancelled
  counts.

**Proposal:**

- Add explicit summary fields:
  - `elided_frame_count`;
  - `cancelled_frame_count`;
  - `completed_drop_count` (already present, keep it distinct);
  - `committed_frame_count`;
  - `diagnostic_frame_count`.
- Add `cpu_seconds_per_diagnostic_frame` and keep
  `cpu_seconds_per_committed_frame`.
- Treat idle observation scenarios as observation windows, not input-latency
  events:
  - either omit `input_to_present_latency_ms` for `eventType == "idle"`;
  - or record dispatch time before waiting for the first marker if a latency
    number is intended.
- Update `termui-perf compare` to print elision/drop/cancel deltas.

**Risk:** Low. This is schema/reporting work, but it may require updating tests
and any consumers that assert exact JSON keys.

**Acceptance:**

- `synthetic-offscreen-phase-animator` reports non-zero `elided_frame_count`.
- Idle scenarios no longer print negative input latency.
- Compare output makes elision and dropped-frame changes visible.

### P1 - Carry forward placed-frame table entries for retained placement

**Why now:** Placement is the best remaining code-level target after the
identical-subtree metadata sync skip. A reused placed subtree still walks every
descendant to rebuild the placed-frame table.

**Evidence:**

- `LayoutEngine+PlacementWorkStack.swift` calls
  `passContext?.recordPlacedFrames(in: retained)` for reused placement.
- `LayoutPassContext.recordPlacedFrames(in:)` walks the whole retained
  `PlacedNode` subtree and re-records each identity, bounds, and named
  coordinate-space value.
- The previous place-sync-skip report measured `recordPlacedFrames` as a further
  12-15% of `place_ms` after the metadata-sync work was isolated.

**Proposal:**

Introduce retained placed-frame table carry-forward:

- Store a per-subtree placed-frame table fragment alongside retained layout
  state, or make the table itself support copying an unchanged subtree fragment
  into the current frame.
- For geometry-identical retained placement, reuse the previous fragment without
  walking descendants.
- For geometry-reusable but metadata-changing placement, only refresh entries
  that can affect the table:
  - identity;
  - bounds;
  - named coordinate-space name.
- Keep full rebuild behavior for divergent placement, lazy stack viewport
  changes, direct invalidation, and synthetic invalidated ancestors.

**Soundness constraints:**

- Named coordinate spaces and focus/scroll routing must see the same table that
  a full placement walk would produce.
- Removed subtrees must not leave stale table entries.
- Viewport translation must update bounds correctly without rewalking unchanged
  metadata.

**Acceptance:**

- Add tests comparing full placement table rebuild vs retained carry-forward on:
  - identical retained subtree;
  - named coordinate-space metadata change;
  - viewport translation;
  - removed subtree;
  - lazy stack retained-layout exclusion.
- Re-run `synthetic-narrow-invalidation` rows 6/20/40 and record `place_ms`.

### P2 - Narrow retained-reuse suppression to affected subtrees

**Why now:** H2 made retained resolve reuse safe by suppressing reuse on
focus-move and active-animation frames. That is correct, but it is frame-wide.
Persistent visible animation can therefore force unrelated inert subtrees to
recompute.

**Evidence:**

- `RunLoop+Rendering.swift` calls `renderer.suppressRetainedReuseForNextFrame()`
  when `shouldSuppressRetainedReuseForFrameSafety()` is true.
- `ViewFoundation.resolveView` skips `reusableSnapshot` whenever
  `ResolveContext.effectiveSuppressesRetainedReuse` is true.

**Proposal:**

Replace the boolean frame-wide suppression with an affected-subtree model:

- Build a per-frame `ReuseSuppressionScope`:
  - focus old/new identity ancestors;
  - active animation identities and ancestors needed for animation
    registration;
  - any structural/lifecycle roots that cannot reuse safely.
- Thread the scope through `FrameResolveInputs`.
- Let `resolveView` suppress retained reuse only when the current identity
  intersects the suppression scope.
- Keep a conservative fallback to full suppression for unknown animation or
  focus cases.

**Risk:** Medium-high. The prior work found that animation registration and focus
convergence can be subtle. This should be done with TDD and with the existing
animation/focus runtime tests in the loop.

**Acceptance:**

- Existing focus/caret-scroll tests still pass.
- Existing animation repeat/deadline/elision tests still pass.
- A new scenario with one persistent visible animation plus a large unrelated
  subtree shows resolve reuse for the inert subtree.

### P3 - Incremental semantics and draw extraction for retained subtrees

**Why now:** After resolve/measure/place reuse, semantics and draw still perform
whole-tree extraction for committed frames. These are the next likely O(tree)
costs once placement table rebuild is reduced.

**Evidence:**

- `SemanticExtractor.extract(from:)` walks the effective placed tree and rebuilds
  interaction, focus, scroll, selection, and coordinate-space snapshots.
- `DrawExtractor.extract(from:)` reserves `root.subtreeNodeCount` and lowers the
  placed tree into draw nodes every committed frame.

**Proposal:**

Add retained phase products for semantics and draw:

- Give `PlacedNode` or retained frame-tail state enough identity/version metadata
  to identify unchanged subtrees.
- Cache semantic fragments and draw fragments by identity plus the fields that
  affect each projection.
- Merge cached fragments with recomputed changed roots.
- Keep hit-test ordering, focus candidate ordering, and overlay/background
  ordering canonical.

**Risk:** Medium. Ordering is observable. The work should start with semantic
snapshot equivalence tests before optimizing the extractor.

**Acceptance:**

- Full semantic snapshot and draw tree are byte-equivalent to the current full
  extraction for mixed changed/unchanged trees.
- `synthetic-narrow-invalidation` shows lower semantics/draw/raster-tail CPU once
  P1 is complete.

### P4 - Make host damage metrics and web dirty-rect consumption first-class

**Why now:** The runtime has host-facing damage, but the in-process perf host
does not consume it, and the browser host has an avoidable dirty-rect scanning
shape.

**Evidence:**

- Runtime presentation routes `DamageAwarePresentationSurface` separately from a
  plain raster surface.
- `PerfTerminalHost.present(_:)` always reports a full repaint strategy and full
  surface cell count.
- `WebHostSceneRuntime.drawRows` checks every cell against
  `dirtyRects.some(rectsIntersect)`, and image drawing does the same for every
  image. Dirty rects are built from row/range damage but then consumed as an
  unindexed array.

**Proposal:**

Split this into two low-risk tasks:

1. Add a test/perf-host route that receives host-facing damage:
   - expose an SPI wrapper for damage-aware metrics; or
   - run TermUIPerf through a semantic host surface that receives raster damage.
2. Change browser dirty-rect consumption to row/range indexing:
   - keep damage in cell-space row ranges;
   - iterate only dirty rows/ranges for text;
   - use an interval or row prefilter before image intersection checks.

**Acceptance:**

- TermUIPerf presentation metrics for incremental frames report incremental
  strategy and changed-cell counts consistent with damage.
- Web host canvas draw work no longer scales with `all cells * dirty rects` for
  narrow invalidations.

### P5 - Add cadence/admission policy for visible continuous animation and text churn

**Why now:** Off-screen animation elision handles invisible deadline work.
Visible continuous animation is different: it produces real damage, so the
framework should not silently drop frames unless a policy says that is acceptable.

**Evidence:**

- `synthetic-continuous-animation` and `synthetic-text-shimmer` intentionally
  represent visible repeated damage.
- Text-layout cache growth was previously shown to be bounded, but unique
  TimelineView strings can still create cache churn and per-frame text-layout
  misses.

**Proposal:**

- Add an explicit low-priority animation cadence policy for decorative or
  non-interactive animation.
- Add a text-layout cache admission/bypass rule for rapidly changing one-shot
  strings, measured against normal static/reused text.

**Risk:** Product-level tradeoff. The implementation should require an explicit
policy or view modifier rather than silently degrading authored animation.

**Acceptance:**

- Decorative visible animation can be capped without affecting input latency or
  essential progress indicators.
- Text churn scenarios show lower cache work without hurting normal text reuse.

## Execution plan

1. Land P0 measurement semantics.
   - Keep the existing diagnostics TSV parser.
   - Add explicit counts and idle-event latency handling.
   - Run TermUIPerf tests and a one-iteration release sanity probe.
2. Implement P1 placed-frame table carry-forward.
   - Start with equivalence tests.
   - Add a probe or additional phase metric if attribution is unclear.
   - Run rows 6/20/40 `synthetic-narrow-invalidation` A/B.
3. Spike P2 scoped suppression behind a feature flag.
   - Prove animation/focus soundness first.
   - Only keep it if it materially improves mixed animation + interaction
     scenarios.
4. Implement P3 only after P1/P2 results show semantics/draw are still material.
5. Do P4 host/web work in parallel with runtime work if presentation metrics or
   browser profile evidence becomes the bottleneck.
6. Treat P5 as policy work and schedule separately from pipeline correctness.

## Validation matrix

Minimum gates for any runtime optimization:

```bash
swiftly run swift test --package-path swift-tui/Tools/TermUIPerf
(cd swift-tui && bun run test)
```

Minimum perf sweeps:

```bash
swiftly run swift run --package-path swift-tui/Tools/TermUIPerf -c release termui-perf run \
  --scenario synthetic-narrow-invalidation \
  --modes async \
  --iterations 20 \
  --configuration release

swiftly run swift run --package-path swift-tui/Tools/TermUIPerf -c release termui-perf run \
  --scenario synthetic-offscreen-phase-animator \
  --modes async \
  --iterations 20 \
  --configuration release
```

Additional targeted scenarios:

- mixed persistent visible animation plus unrelated large inert subtree;
- Gallery animation click;
- layout scroll burst;
- browser host narrow damage with many dirty row ranges;
- real terminal cross-check for presentation metrics when terminal IO is in
  scope.

## Non-goals

- Replacing the explicit phase-product model.
- Making public child repos depend on the org-root Bazel tooling.
- Optimizing terminal byte output before pipeline CPU is proven no longer
  dominant.
- Silently reducing visible animation cadence without an explicit product
  policy.

