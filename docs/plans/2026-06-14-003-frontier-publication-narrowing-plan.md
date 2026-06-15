# Frontier and Publication Narrowing Plan

- **Date:** 2026-06-14
- **Status:** Stage 1A.2 attribution complete; Stage 1B recommended next
- **Owner repo:** this coordination root
- **Implementation repo:** `swift-tui`
- **Starting pin:** `swift-tui` `2479cac9` via org root `1378b00`
- **Depends on:** package-owned invalidation gap baseline in
  [`2026-06-14-001-invalidation-gap-test-plan.md`](2026-06-14-001-invalidation-gap-test-plan.md)

## Goal

Reduce frames that fall back to full runtime-registration publication and full
graph checkpoint cost while preserving the already-proven scoped publication
semantics.

This is the next behavior-changing tranche after the invalidation gap tests. It
does **not** attempt the broader observable key-path index, no-reader `@State`
elision, or ancestor-invalidation reuse work. Those remain separate plans. This
tranche is narrower: explain why a frame lost its selective dirty plan, then
convert the highest-volume safe cases from `.all` publication to scoped or cheap
publication.

## Current mechanism

The relevant runtime path is:

1. `DefaultRendererFrameHeadCoordinator.beginGraphEvaluation` chooses selective
   evaluation only when `FrameResolveState` permits it.
2. `installPresentationPortalEvaluator` can queue the presentation portal root
   when presentation state changes or invalidated identities are not empty.
3. `ViewGraph.selectiveDirtyEvaluationPlan()` returns a plan only when the dirty
   identities map to known graph nodes and frontier roots can be formed.
4. `ViewGraphFrameDraft.recordDirtyEvaluationPlan(nil)` records publication
   `.all`; a non-nil plan records `.subtrees(frontierIdentities)`.
5. `ViewGraphFrameDraft.commitRuntimeRegistrations` implements:
   - `.unchanged`: publish nothing.
   - `.subtrees`: remove those roots, restore the resolved subtrees, normalize
     order, then republish all task registrations so capture-hosted task islands
     stay live.
   - `.all`: reset and restore all current-frame runtime registrations.
6. Abortable async frame-head work also prepares `ViewGraph` and input-state
   checkpoints, so full-frame fallback affects both publication and abort cost.

The scoped path is already load-bearing. It protects focus ordering, custom
`ResolvableView` identity rewrites, active gestures, and capture-hosted `.task`
publication. This plan must preserve those guards.

## Baseline facts to refresh

The last detailed probe was on an older pin and is only a starting hypothesis.
It found `sheet-open-latency` transition frames spending most of `commit_ms` in
registration publication:

```text
commit_ms = finalize 0.99 + txn 5.86 + plan 0.0008 ms/frame
txn       = graphRegistrations 5.79 + observation 0.07 + portal ~0 + animation ~0
publication mode: all=149 of 258 frames, subtrees=109, unchanged=0
```

The suspected path was:

```text
unmapped presentation identity
-> nil selectiveDirtyEvaluationPlan()
-> recordDirtyEvaluationPlan(nil)
-> publication .all
-> reset/restore all runtime registrations
```

Because the current pin has the invalidation baseline and task-republication
fixes, the first milestone must remeasure before changing behavior.

## Non-goals

- Do not change observable object invalidation granularity in this tranche.
- Do not add no-reader `@State` elision.
- Do not expand transaction semantics.
- Do not attempt general descendant reuse after ancestor invalidation.
- Do not remove the full `.all` fallback. Unknown or ambiguous dirty roots must
  still choose correctness over speed.
- Do not commit coordination-only performance overlays or temporary probes to a
  public child repo.

## Stage 0 - Current-pin inventory

Add env-gated diagnostics, then run the same-session perf inventory against the
current pin.

### Instrumentation

Add a small SPI or profiling-only probe that records, per committed frame:

- publication mode: `.unchanged`, `.subtrees`, or `.all`;
- `.subtrees` root count;
- dirty plan result: formed, nil because no dirty identities, nil because an
  identity was unmapped, nil because a frontier root could not be formed, or nil
  because selective evaluation was disabled;
- invalidated identity count and a capped sample of unmapped identities;
- whether `installPresentationPortalEvaluator` queued the portal root;
- restored node count for `.all` and `.subtrees`;
- checkpoint node/input-state counts for abortable frame heads.

Keep the probe no-op unless an env var is set. Do not add public API. If the
probe is general enough, land it as disabled diagnostics; otherwise archive it
under `docs/perf/` the same way the commit breakdown probe was archived.

### Measurements

From `swift-tui`:

```bash
swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
  run --scenario sheet-open-latency --modes async --iterations 8 --configuration release

TERMUI_PERF_INVALIDATION_TREE_ROWS=40 \
swiftly run swift run -c release --package-path Tools/TermUIPerf termui-perf \
  run --scenario synthetic-narrow-invalidation --modes async --iterations 20 \
  --configuration release
```

Record the artifact roots and the exact `swift-tui` commit in a follow-up report.

### Exit criteria

- Publication-mode and nil-plan reasons are available for the hot frames.
- The top `.all` causes are ranked by frame count and commit cost.
- A root cause is chosen for Stage 1A or 1B. Do not implement both in one PR
  unless Stage 0 proves they are inseparable.

## Stage 1A - Preserve selective plans for mapped presentation identities

Use this if Stage 0 shows `.all` is primarily caused by presentation or portal
identities that can be safely translated to graph-owned identities.

### Approach

- Add an explicit translation step before `selectiveDirtyEvaluationPlan()` gives
  up on dirty identities.
- Only translate identities that are proven to belong to the active presentation
  portal graph, trigger host, or resolved presentation subtree.
- Preserve unmapped fallback for unknown identities.
- Keep the frontier identities that drive `.subtrees` publication in canonical
  graph identity space.
- Keep task republication after scoped restores.

### Tests

Add package tests that prove:

- a mapped presentation identity forms a non-nil dirty plan;
- the commit publishes `.subtrees`, not `.all`;
- the resolved presentation subtree's actions, focus, lifecycle, and tasks are
  present after the scoped commit;
- an unknown presentation-like identity still falls back to `.all`;
- aborting a prepared async frame restores the same live registrations as a full
  rebuild.

Prefer tests near the existing graph and runtime seams:

- `FrameResolveStateTests`
- `ViewGraphTests`
- `RuntimeRegistrationRestoreScopingTests`
- `AsyncFrameTailRenderingTests`
- `TabTaskActivationRuntimeTests`

### Exit criteria

- Hot presentation frames move from nil-plan `.all` to `.subtrees` where Stage 0
  identified a safe mapping.
- Existing scoped-restore guards stay green.
- `sheet-open-latency` shows a material reduction in `commit_ms` or confirmed
  reduction in `.all` frame share. If commit time does not improve, stop and
  diagnose before expanding the mapping.

### Stage 1A result

The safe identity bridge landed in `swift-tui` `294b2404` and is documented in
[`2026-06-15-stage-1a-frontier-publication-narrowing.md`](../reports/2026-06-15-stage-1a-frontier-publication-narrowing.md).
It removes the portal-hosted unmapped-identity bucket, but it does not reduce
`.all` frame share: the remaining `.all` frames are now attributed to
`nil_selective_evaluation_disabled`. Continue with a small Stage 1A.2
attribution pass before choosing a behavior change or moving to Stage 1B.

### Stage 1A.2 result

Selective-gate attribution landed in `swift-tui` `bb2a047f` and is documented in
[`2026-06-15-stage-1a2-selective-gate-attribution.md`](../reports/2026-06-15-stage-1a2-selective-gate-attribution.md).
The dominant `.all` causes are explicit root-evaluation guards:
`frame_state_force_root`, focus/pressed changes, startup/root invalidation, and
context/proposal force-root frames. These are not remaining safe portal identity
translation misses, so the next implementation stage should be Stage 1B:
reduce the cost of unavoidable `.all` publication without weakening those
selective-evaluation gates.

## Stage 1B - Make unavoidable `.all` publication cheaper

Use this if Stage 0 shows the `.all` frames are legitimate root evaluations or
identity mapping is too ambiguous to be the first behavior change.

### Approach

Keep `.all` semantics, but avoid rebuilding unchanged registration registries:

- snapshot or hash registry ownership by identity at graph-finalize time;
- diff current-frame registration owners against the last committed publication;
- reset and restore only registries or identity ranges whose owner sets changed;
- preserve the existing pointer and gesture active-identity rules;
- preserve global focus ordering exactly;
- retain a slow-path full reset for any registry that cannot prove equivalence.

This is a cost reducer, not a frontier semantic change. It should make root
fallback less expensive without pretending a root frame is narrow.

### Tests

Add byte-equivalence tests against a full rebuild for:

- focus order;
- key, action, pointer, gesture, lifecycle, task, preference, command, drop, and
  scroll registrations;
- active gesture preservation;
- identity/path component collisions;
- custom `ResolvableView` identity rewrites;
- task islands that are not reachable through a simple children walk.

### Exit criteria

- `.all` frames remain `.all` in diagnostics, but restored node or registry work
  drops for unchanged sections.
- Full-rebuild equivalence tests cover every registry family touched by the
  optimization.
- No public API changes.

## Stage 2 - Checkpoint scoping

Start only after Stage 1 changes make publication behavior explainable. The
checkpoint work should not hide publication regressions.

### Approach

- Measure prepared checkpoint size and restore cost on abortable frame heads.
- Split graph checkpoint content into identity-stable state that can be shared
  and mutable per-frame state that must copy.
- If the graph can prove a frame has a dirty frontier, checkpoint only the
  affected graph ranges plus the global counters needed for rollback.
- Keep a full checkpoint when the frame is `.all`, when dirty roots are unknown,
  or when presentation portal state cannot provide a stable owner.

### Exit criteria

- Async frame abort tests prove rollback equivalence.
- Checkpoint create/restore timing drops on the hot scenarios without changing
  commit/publication correctness.

## Stage 3 - Restore-walk sizing and retained-registration index

Start only if Stage 0 or Stage 1 still shows `restoreResolvedSubtree` walking
large reused subtrees.

### Approach

- Extend diagnostics with restored node counts and reused-node counts per scoped
  root.
- Size whether the cost is sorting, structural-path lookup, or recursive child
  traversal.
- If traversal dominates, prototype a retained registration index keyed by
  structural path or view node id, but keep it derived from committed graph
  state and validate it against full rebuilds.

### Exit criteria

- A small vertical slice proves less restore traversal on
  `synthetic-narrow-invalidation` without changing byte-equivalence.
- If the slice needs new graph-totality invariants, promote it to its own plan
  before landing broadly.

## Verification matrix

Run focused package tests from `swift-tui` after each behavior PR:

```bash
swiftly run swift test --filter \
'FrameResolveStateTests|ViewGraphTests|RuntimeRegistrationRestoreScopingTests|TabTaskActivationRuntimeTests|AsyncFrameTailRenderingTests|PipelineContractTests|AnimationRepeatForeverGrowthTests|StateInvalidationDependencyTests|BindingDependencyModelTests|DependencyModelTests|ResolveReuseAncestorInvalidationTests|FrameSchedulerIntentCoalescingTests|TransactionSnapshotTests' \
--jobs 4
```

Run the org gate from this root before pinning:

```bash
mise exec -- bazel test //:org_fast
```

For PRs that touch checkpointing, async frame tail commit, task publication, or
public package manifests, also run the relevant native or child gate before
pinning.

## Handoff order

1. Land Stage 0 instrumentation or archived probe.
2. Publish the current-pin inventory report.
3. Choose Stage 1A if the dominant `.all` cause is safe identity translation;
   choose Stage 1B if root publication is legitimate but expensive.
4. Land one behavior PR in `swift-tui`, then pin it in this root.
5. Re-run the same perf inventory and write a completion report before Stage 2.
