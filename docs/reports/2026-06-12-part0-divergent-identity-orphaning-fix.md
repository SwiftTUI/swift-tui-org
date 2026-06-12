# Part 0 — Divergent-Identity Orphaning Fix Results

- **Date:** 2026-06-12
- **Status:** Landed in `swift-tui@f748be26` (main, pushed). Part A is now
  unblocked.
- **Scope:** open ranked item 2 of the
  [2026-06-10 assessment](../plans/2026-06-10-001-perf-workstream-assessment-next-wave-proposal.md):
  the latent divergent-identity orphaning bug that gated Part A
  (per [2026-06-09 lever-B report](2026-06-09-lever-b-implementation-and-findings.md)
  §focus-residual design conclusion).

## Headline correction: the bug was live, not latent

A two-scroll probe (settle between scrolls) **freezes a WindowGroup-hosted
TabView scroll pane on `main@0b041764` today**, with `IsFocusedKey` still in
the reuse snapshot. The isFocused "mask" is a one-shot committed-vs-probe
asymmetry — frames 0/1 commit focus-nil snapshots, default focus lands at
post-render focus sync, the *first* interaction rides the resulting
tree-wide env-mismatch recompute and commits the flipped snapshots — so the
*second* scroll meets the bare reuse gates and freezes. Verified with
`SWIFTTUI_REUSE_TRACE`: first-scroll frame shows
`env-mismatch=20 (all IsFocusedKey) + invalidation-conflict=30 +
stale-snapshot=2`; the freeze frame shows `dirty=1` only (the force-queued
portal root) — the scene root retained-reuses via the G1-both-miss + G2
fast path and descent stops. G3 (`conflictsWithInvalidation`) never runs.

## Mechanism (multi-agent investigation, adversarially arbitrated)

Two corrections to the planning docs' model:

1. **The wrongly-reused node is not divergent.** The WindowGroup scene root
   has `committed.identity == identity`; the divergent (alias-carrying) node
   is the `FrameModifier` `.named("content")` host whose committed root is
   the `.id(...)`-re-rooted ScrollView (`resolveOwned` creates no graph node,
   so `committed.identity` becomes the explicit identity). The scroll's
   invalidation set lives entirely on that re-rooted axis
   (`{SceneHostedScroll…/Scroll, SceneHostedScroll…}`), which string-prefix
   gate math on the structural spine can never intersect. A0-as-written
   (adding the resolved-identity ancestor chain of the scroll target) is a
   **literal no-op** — those identities were already in the freezing frame's
   set.
2. **The would-be rescue was dead, not the gates.** Marking the divergent
   host dirty (the alias does map it) runs `invalidateCachedSnapshotUpward`,
   which should stale the whole spine and fail `canReuse` on `stale-snapshot`
   before any gate runs — but both freshness walks follow `ViewNode.parent`
   links, which **dead-end ~2 hops above the dirty node at the capture
   seam** (trace: `stale-snapshot=2`). The break is structural (it survives
   full-tree recomputes) — capture-hosted content is reachable from its host
   only through body resolution, never through `children`/`parent` links.

## The fix

`ViewNode` gains a weak `evaluationHost` — the node whose body resolution
evaluated this one, captured at outermost `beginEvaluation` from
`ViewNodeContext.current` (which still holds the *enclosing* node there,
since `resolveView` wraps body resolution after `beginEvaluation`).
Both upward freshness walks follow `parent ?? evaluationHost`.

Why this is sufficient and safe:

- **Staleness is the right invariant**: a stale host is denied retained
  reuse and re-resolves its body, and the body re-resolve is exactly what
  re-reaches the island content *by value* — closing the skip-then-launder
  hazard the design review flagged.
- **Keep-if-nil**: frontier evaluators run outside any enclosing resolution
  (`ViewNodeContext.current == nil`); the host captured at the original
  nested evaluation is retained, never clobbered.
- **No `parent`-link or GC changes**: `pruneDetachedResolvedRootIfNeeded`
  keys on `parent == nil`; the fix deliberately leaves parenting untouched
  (the strongest argument against seam *repair* in the design review).
- **All invalidation producers covered**: scroll, focus, press, gesture,
  state writes all funnel through `markDirty` → the fixed walk — unlike the
  A0' scroll-site mitigation the review considered.
- Checkpoint totality preserved (`evaluationHost` mirrors `parent` in
  `ViewNode.Checkpoint`).

## Verification

- TDD: the two-scroll guard
  (`secondPointerScrollAfterSettleUpdatesWindowGroupHostedScrollPane`)
  verified RED on `0b041764`, GREEN with the fix.
- The three pre-existing scroll cases (TabView-hosted, WindowGroup-hosted,
  internal-@State single-scroll) pass **with `IsFocusedKey` still in the
  snapshot** — the plan's acceptance criterion.
- ViewGraphCheckpointTotalityTests, RetainedSubtreeReuseTests,
  RetainedReuseInvariantTests, ReaderAttributionTests, ViewGraphTests,
  RuntimeNodeIDStampingTests: all green. Full repo gate: PASS.
- **Perf (hot reuse path, same-session release A/B):**
  `synthetic-narrow-invalidation` rows=20 total CPU 0.1788 → 0.1794 (+0.3%,
  noise; all phases within 1–2%; computed/reused byte-identical at
  18.2/178.8). rows=40's same-session baseline was itself load-noisy
  (CV 12.7%) and *higher* than the after-run — no regression in either
  direction. `layout-scroll-burst` flat (0.0149 → 0.0150; counts identical).
  Artifacts: `/tmp/part0-ab/` (ephemeral).

## New finding (CORRECTED 2026-06-12): semantic scroll routes flicker on/off across frames — scrolls silently dropped (OPEN)

While building coverage, a two-scroll variant of the **internal-@State**
gallery shape (the 2505 fixture: `@State` scroll position + PhaseAnimator
content, `@State` TabView selection) appeared to "freeze". Instrumented
diagnosis showed the freeze framing was wrong — and the real bug is worse:

- **The scrolls never reached the ScrollView at all.** `handleMouseScroll`
  logged `scrollTarget = nil` for every scroll because
  `latestSemanticSnapshot.scrollRoutes` was **empty** at dispatch time. No
  position write, no invalidation — the events were silently dropped. (The
  probe's "first scroll worked" gate was itself an artifact:
  `DamageRecordingTerminalHost.visibleFrames` records damage regions, and a
  PhaseAnimator damage frame doesn't contain the row marker.)
- **The route flickers in and out of the published snapshot per frame.**
  Per-frame logging of `latestSemanticSnapshot` assignment shows the pane's
  single scroll route (`…/TabContentPayload[1]/content`, the indexed-source
  boundary identity) present on some commits and absent on others, in
  batches loosely tracking the PhaseAnimator's
  `suppressed`/`transaction` frame storms — but not cleanly one class:
  frame 1 (a full re-resolve) also published a routeless snapshot, and
  routes returned mid-storm. Input hit-testing therefore **races the frame
  cadence**: any pane whose app commits frames with route-less snapshots
  (looping animations make this continuous) randomly drops scroll events —
  here >50% of the time, deterministically reproducible.
- The external-binding fixture never flickers (no animation → the
  pre-scroll snapshot is a full commit with routes), which is why the
  committed Part 0 guard is unaffected. The 2550 gallery-animating burst
  test masks the flicker probabilistically (12 ticks, retrying waits).
- Co-occurring observation to check during diagnosis: executor-stage
  off-screen elision fired repeatedly (`causes=[deadline]`) while the
  PhaseAnimator's text was plausibly on-screen — if confirmed, that is an
  H1 soundness violation (redraw-vs-drawn identity sets diverging at the
  capture/indexed-source seam) feeding the same root cause.

This is **not** the Part 0 orphaning class (no wrong reuse is involved) and
the `evaluationHost` fix is neither implicated nor sufficient. Next effort:
find which commit classes extract/publish semantics without the
indexed-source interior (measure-phase realization vs semantics extraction
vs retained-fragment reuse), fix the snapshot stability, and reintroduce a
two-scroll internal-@State guard with artifact-proof gating (full-surface
frames, not damage regions). Registered in the assessment plan.

## Sequencing consequence

Part A (exclude `IsFocusedKey` from the reuse snapshot + map `\.isFocused`
→ `FocusedIdentityKey`) is now unblocked per the 2026-06-10 decision. Note
Part A removes the one-shot mask that today hides the *first*-interaction
variant of any residual freeze class — the internal-@State follow-up above
should be diagnosed first or in the same effort.
