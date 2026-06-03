# Structural Identity — Migration Audit & Gap-Remediation Plan

**Date:** 2026-06-03
**Status:** Audit complete + remediation **paused at a clean checkpoint** on branch
`structural-identity-completion` (10 commits; tree clean; scope this session:
*purity + redirect perf*).
**Stage:** Post-implementation gap register for the seven-stage structural-identity
migration (stages 0–6).

> **Implementation progress (live).** Landed + verified on the branch:
> - **G9 / G14 / oracle annotation** (`c892a9be`) — reuse-lock test, checkpoint-totality
>   negative test, L3-deferral annotation, VISION-GAP entries.
> - **G5** (`e0757269`) — surface topology signature keyed on structural `stableKey`,
>   not runtime `Identity` (re-key no longer forces a full-surface diff). *Caught and
>   avoided a `PlacedNode` stack-overflow regression: the struct is stack-size-sensitive,
>   so the signature carries no positional field — it keys on the existing structural
>   `stableKey`.*
> - **G1** (`92aa4679`) — commit-path invalidation engine (`FrameMetrics.InvalidationSummary`
>   + retained synthetic-ancestor / `placedPath` walks) reasons over `StructuralPath`,
>   not `Identity.parent`. Behavior-preserving.
> - **G6 (partial)** (`e9d381df`) — `computeSupportsRetainedReuse` gates on
>   `structuralEdgeRole == .viewportBarrier` instead of re-deriving from
>   `indexedChildSource`, making the Stage-4 edge role a *live consumer*.
>   Behavior-neutral. The `declarationOwnerEdge → presentation-GC` consumer is the
>   remaining G6 half.
> - **resolve_ms (first win)** (`8f1fb97a`) — the per-node resolve reuse decision
>   short-circuits its redundant O(invalidated × path) identity-conflict scan when
>   the live-graph structural check has already rejected reuse. Behavior-identical.
>   Deeper resolve wins need TermUIPerf profiling + a perf gate (not runnable in this
>   loop) to size and prove, so further blind optimization of the reuse-correctness
>   path is deferred. A second, larger win is *identified and documented in code*
>   (`5e383a49`): `conflictsWithInvalidation` recomputes the same predicate as
>   `identityIntersectsInvalidation` via a linear `isDescendant` sweep instead of the
>   O(1) precomputed summary — safely removable once the "summary built from this
>   identity set" invariant is enforced; left as a profiling-gated next step rather
>   than coupling reuse correctness to an unenforced invariant.
> - **G13 — CONFIRMED GAP, not just a missing test** (`0cb63d27`, `f4b30d87`, `8d02f9f4`). A probe
>   (`ForEach([7, 7])` via `DefaultRenderer`) shows same-collection duplicate ids
>   **alias to one `ViewNode`/`@State` slot**, contradicting the Stages 5–6 "distinct
>   `ViewNodeID`, never aliased" claim. Root cause: `ViewGraph.nodeForIdentity` keys
>   find-or-create on `Identity` (`nodeIDByIdentity` is 1:1); the second duplicate
>   finds the first's node at the shared `Identity`, sees a different
>   `EntityIdentity.occurrence`, and (when the entity is not yet bound) **reuses** it
>   — so the siblings cannot coexist. Stage 3's occurrence disambiguation never reaches
>   the node-allocation key. **Recorded in `swift-tui/docs/VISION-GAP.md` and pinned as
>   an executable, self-removing `withKnownIssue` test** (`8d02f9f4`,
>   `EntityRoutingTests.duplicateIDsShouldResolveToDistinctViewNodeIDs`): it asserts the
>   correct end-state (two distinct `ViewNodeID`s), passes today (recording the bug),
>   and fails loudly the moment `nodeForIdentity` is made occurrence-aware — prompting
>   removal of the wrapper. The fix itself (occurrence-aware allocation / 1:many
>   identity map) is a core Stage-5/6 node-store change with a real orphan-leak risk
>   in the naive form, so it was **not attempted blind**; see *Next steps* for the
>   investigated approach.
> - **G15 / G4a** — **resolved as deliberate deferral** (`ce9ac36c`, recorded in
>   `swift-tui/docs/VISION-GAP.md`): repointing per-frame registry/scope-path containment
>   checks to `StructuralPath` the cheap way *adds a hot-path allocation per check* — a net
>   perf regression against the redirect-to-perf goal — for zero behavioral change; the
>   full element-type re-key is parked until it earns its cost. G1 was the correct
>   (off-hot-path) place to apply the projection.
>
> Still pending: **G3a** (incremental patcher) + **G11** (fold-up signature),
> **G6 (GC half)** (declaration-owner → presentation GC), **G10a** (animation/focus
> entity-routing + teleport), **resolve_ms** perf, verification **G7 / G12 / G13**,
> and the submodule re-pin. The full 2302-test suite is the regression net; the full `swift test` run is
> subject to a known load-sensitive `swiftpm-testing-helper` SIGBUS/SIGSEGV flake
> (`swift-tui#12`), so per-suite runs are used to validate.
**Entry point:**
[`2026-06-03-001-first-class-structural-identity-proposal.md`](2026-06-03-001-first-class-structural-identity-proposal.md)
— the plan-set index and the *why*.
**Audited against:** `swift-tui` working tree at **`f2cc53fa` (0.0.13)** — the
current org-root pin. Plans were authored against `a020fa55` (pre-migration).

> This document is the *eighth* in the structural-identity plan set. The first
> seven (001–007) said what to build. This one records **what actually landed**,
> measured stage-by-stage against those plans, and sequences the work to close
> the gaps. It does **not** restate the design — read 001 for that.

---

## Next steps (resume here)

Ordered by value. The branch is clean; resume with `git checkout structural-identity-completion`.

1. **G13 — fix the duplicate-id node-store aliasing (highest value; now a concrete,
   mechanism-known bug with an executable marker).** `ViewGraph.nodeForIdentity`
   (`Resolve/ViewGraph.swift:1379-1427`) collapses same-id siblings because
   `nodeIDByIdentity` is `[Identity: ViewNodeID]` (1:1). The investigated minimal
   patch — "when `entityIdentity.occurrence > 0` and the identity-existing node has no
   bound entity, mint a fresh node instead of reusing it" — makes the two siblings
   distinct **but** the occurrence-1 node then can't live in the 1:1
   `nodeIDByIdentity` (occurrence-0 owns the key), so it is reachable only via the
   `EntityRoutingTable`. That risks an **orphan leak** on teardown if any teardown
   path finds the node by `Identity` rather than entity. So the correct fix is one of:
   (a) make `nodeIDByIdentity` 1:many (`[Identity: [ViewNodeID]]`) and update the ~40
   lookup/teardown sites to disambiguate by entity/structural slot; or (b) route all
   *keyed*-entity node allocation through the `EntityRoutingTable` and make teardown
   entity-based for those nodes. Either is a real Stage-5/6 change — do it behind the
   full suite **+** the `withKnownIssue` marker (flips to failing when fixed) **+** the
   `routingTableReleasesGoneEntities` churn/leak test (must stay green). Verify no
   orphaned registrations after a `ForEach([7,7]) → ForEach([7]) → ForEach([])` churn.
2. **resolve_ms (deeper, performance).** Two identified wins: (i) remove
   `conflictsWithInvalidation` once the summary-built-from-this-identity-set invariant
   is enforced (`5e383a49` documents it in code); (ii) reduce the
   `O(nodes × invalidated × depth)` `structuralInvalidationIntersects` work. Both need
   the **TermUIPerf** harness + a perf gate to size and prove — start there.
3. **G10a (architectural behavior win).** Re-key `AnimationController` property-value
   interpolation maps onto `ViewNodeID` so property animations follow an entity across
   a move; add the `EntityRoutingTests` Test #5 (focused/animating `.id`-keyed view
   moved between containers keeps focus + animation continuity).
4. **G6 (GC half).** Route presentation GC/invalidation through
   `declarationOwnerEdge.owner` instead of the `sourceIdentity` preference set-difference.
5. **G3a + G11 (patcher).** The incremental `RetainedFrameIndex` patcher + fold-up
   signature. Lowest priority by the measurement (commit/index is <1% of frame).
6. **Verification G7 / G12.** Custom-`ResolvableView` alias-deletion byte-identity test;
   wire the duplicate-id diagnostic into the index/commit path.
7. **Close-out.** `bazel test //:org_full`, then commit+push the child branch and record
   the new submodule pin in the org root.

## How this audit was run

- **Empirical baseline.** `swift build --build-tests` is green (38s, 0 warnings):
  the entire package *and* all test targets compile against HEAD. A targeted run
  of the plans' named suites — `EntityRoutingTests`, `RetainedFrameStructuralIndexTests`,
  `ChildDescriptorTests`, `StructuralDiffTests`, `PanelTests`,
  `ViewGraphCheckpointTotalityTests`, `RuntimeRegistrationRestoreScopingTests`,
  `IdentityGuardTests` — passes **57/57 tests across 9 suites**.
- **Provenance.** Each stage landed as one commit on top of `a020fa55`:
  Stage 0 `65dd5447`, Stage 1 `378d4137`, Stage 2 `8ac275da`, Stage 3 `a441e281`,
  Stage 4 `f47c08af`, Stage 5 `8732c8d3`, Stage 6 `63b1daba`, then a gate-policy
  fix `891ceb44` and release commits.
- **Fidelity review.** Every plan deliverable (each `L<n>.<m>` mechanic, each
  named test, each invariant, each "Do not …" non-goal, each oracle) was checked
  against the live HEAD source with `file:line` evidence, plus two cross-cutting
  passes (end-state axis-separation invariants; oracle/test coverage).

## The headline

**The migration reached its architectural destination and is fully integrated —
but several of the engineering-rigor obligations the plans treated as the *point*
of each stage did not land.** Specifically:

- ✅ **All four axes exist as distinct types in their correct homes** —
  `ViewNodeID` (opaque `UInt64`, no tree semantics), `StructuralPath`
  (component-wise prefix), `EntityIdentity{value, occurrence}`, and
  `StateSlotKey{owner: ViewNodeID, ordinal}` / `StateGraphScopeID`.
- ✅ **The scar tissue is genuinely gone.** `registrationAliasesByIdentity` /
  `registrationAliasTargets` and their fan-out are deleted; the
  `__SwiftTUIStateGraph` path string-splice is replaced by a typed
  `StateGraphScopeID`; `Identity(path:)`/`ExpressibleByStringLiteral` remain
  forbidden (`IdentityGuardTests` still passes); `nodesByIdentity` survives only
  as a *computed projection* over `nodesByNodeID` + `nodeIDByIdentity`.
- ✅ **The capstone behaviors work and are tested.** `@State` survives a
  cross-container move, survives a wrapper toggle, resets on a real `.id` change,
  the closure-owner-vs-per-element rule holds simultaneously, and the routing
  table releases gone entities (no leak) — all asserted in `EntityRoutingTests`.
- ⚠️ **The proof obligations and two rewirings are the shortfall.** The Stage 5
  cross-version golden oracle was never built; Stage 1's invalidation engine was
  never repointed and its "patchable" index still rebuilds every frame; Stage 4's
  typed edge carriers are stored but never *consumed*; Stage 0's evidence harness
  never ran over a real corpus (and one of its four axes was later deleted).

So: **how far along** — structurally and behaviorally, ~100% of the user-visible
end-state is present and exercised. **How well applied** — by plan-fidelity,
roughly **two-thirds**, with the missing third concentrated in oracles, evidence,
and "the data model exists but nothing reads it yet."

## Scorecard

| Stage | Status | Fidelity | The one-line verdict |
| --- | --- | --- | --- |
| **0** Divergence diagnostics | partial | ~45% | Debug-only harness is real and inert, but it never runs over a real corpus, two of four divergence axes are absent (alias axis was *deleted* by Stage 5), and the two highest-leverage evidence tests were never written. |
| **1** Persistent retained index | partial | ~42% | L1 sidecar is well-built, but the **real invalidation engine (`FrameMetrics.swift`) was never repointed**, the L2 signature isn't a node fold-up, and **L3 "patching" is a full rebuild** — the perf win is absent and the oracle is vacuous. |
| **2** Resolve-time structural identity | mostly-landed | ~82% | Production substance ~95% (path carrier, the invariant, the per-element ordinal, the equivalence-gate flip all landed). Gaps are test/diagnostic coverage — notably *no* lock on the headline pure-`.id` reuse win. |
| **3** Reconciliation & entity identity | mostly-landed | ~90% | Solid and correct. Occurrence stays off the runtime string; `ID[` re-parse deleted; three axes decoupled. Only optional policy items (debug precondition, churn fallback) deferred. |
| **4** Portal/overlay/alias edge roles | partial | ~62% | The typed data model landed and unit-tests, but it is **dead data**: nothing consumes `structuralEdgeRole`/`DeclarationOwnerEdge`; raster `SurfaceTopologyEntry` still sorts on `identity.path`; animation teleport still keys on runtime `Identity`. |
| **5** `ViewNodeID` lifetime split | partial | ~62% | The hard core re-key is done well (opaque ID, choke-point mint, planners in lockstep, alias layer deleted, totality solid), but the **cross-version golden oracle is missing**, the alias deletion shipped without its gate test, and the `Local*` registries kept `Identity` as the primary key (dual-key deviation). |
| **6** Entity-routed lifetime | mostly-landed | ~78% | `EntityRoutingTable` + `@State` re-rooting + the owner carrier + the string-splice removal all landed and are tested. L6.4 (animation/focus/gesture routing) was never wired in the runtime and has no Test #5; L6.5's honest-limit doc/test is missing. |

---

## Remediation work, by priority

Each item cites the originating plan section and the live `file:line`. "Oracle"
notes what proves the fix. Paths are relative to `swift-tui/`.

### Tier 1 — Critical (correctness & proof; do these first)

**G1. Repoint the real invalidation engine onto structural adjacency.**
*(Stage 1 / doc 004, Layer 1, the emphasized "two files move together" requirement.)*
The structural walk landed only in the `RetainedInvalidationSummary` *wrapper*;
the actual ancestor/descendant engine — `InvalidationSummary` in
`Sources/SwiftTUICore/Commit/FrameMetrics.swift:44-88` (init ancestor-walk,
`hasInvalidatedAncestor`, `intersectsSubtree`) — **still string-walks
`identity.parent`**, and `RetainedFrameQueries.swift:273-280` retains a residual
string-walk too. The central correctness goal of Stage 1 ("replace the lying
path-prefix proxy with sound structural containment") is therefore not met in the
primary engine.
*Fix:* thread the frame's `StructuralFrameIndex` into `InvalidationSummary` and
replace the three `identity.parent` walks with `parentByNode`/`postorder`
traversal, with a documented conservative fallback only for identities absent from
the structural frame; then delete the residual `RetainedFrameQueries.swift:273-280`
string-walk. *Oracle:* extend the divergence tests so a `.id`/portal case proves
classification follows structure, not path.

**G2. Build the Stage 5 cross-version behavior-preservation golden oracle.**
*(Stage 5 / doc 006, L5.8 — named "the primary oracle" and "what certifies
behavior-preserving".)* The plan is explicit that the surviving
`RuntimeRegistrationRestoreScopingTests` is "necessary but **not** sufficient"
because Stage 5 re-keys both the scoped and full-rebuild paths to `ViewNodeID`
*together*, so it is blind to a uniform behavior shift. A grep for
`golden`/`cross-version`/`dualKeying`/`preStage` returns nothing — **the largest
breaking change in the migration landed with only a self-consistency proof.**
*Fix:* serialize the `Identity` public/debug projection of observable outputs
(resolved/placed/draw surfaces + focus/scroll/command scope ordering) across the
existing fixture corpus at the pre-Stage-5 commit, check the goldens in, and assert
HEAD reproduces them byte-for-byte. Run it as a required gate. Mitigating context:
the Stage 5/6 commits did *not* churn the `SwiftUISurfaceTests` fixtures, so a gross
behavior shift would likely have surfaced there — but those fixtures were never
*frozen at the pre-Stage-5 commit* as the plan specified, so the proof is
incidental, not designed.

**G3. Make Stage 1's L3 honest: implement the real patcher, or mark it deferred
and de-vacuum the oracle.**
*(Stage 1 / doc 004, Layer 3.)* `RetainedFrameIndex.init(patching:with:)`
(`RetainedFrameQueries.swift:77-92`) is `self.init(frame:)` — a full O(tree)
rebuild — and `FrameTailRetainedState.storeCommittedFrame` still rebuilds every
committed frame. The name "patching" and the in-tree `#if DEBUG` oracle imply an
incremental capability that does not exist; the oracle compares two identical
rebuilds, so `patchingInitializerMatchesFullRebuild` is tautological.
*Fix (choose one, record the choice):*
(a) implement real per-structural-root fragment storage + signature diff + prune
(gated on first closing the matched-geometry residual — doc 004 OQ#1); **or**
(b) defer explicitly: rename the initializer so it does not read as incremental,
delete or `XCTSkip`-equivalent the vacuous oracle with an L3 reference, and record
the deferral in `swift-tui/docs/VISION-GAP.md` so a future reader does not mistake
green coverage for a landed perf win. **G3 depends on G1+the G11 fold-up signature**
(a sound patch needs a real fold-up signature).

> **Measurement (2026-06-03, the data that decides the fork).** The
> `synthetic-narrow-invalidation` corpus checked in at HEAD
> (`swift-tui/.perf/stage6-narrow-r{6,20,40}`, ~358 frames/scenario) shows
> `commit_ms` is a **small, off-critical-path slice**: mean **0.137 / 0.457 /
> 1.017 ms** at rows 6/20/40, i.e. **5.4% / 8.4% / 9.5%** of total frame time. The
> dominant phase is `resolve_ms` (1.07 / 2.04 / 4.08 ms, ~40% of pipeline), then
> measure/raster/semantics; commit sits near the bottom. And the
> `RetainedFrameIndex` rebuild is only a *portion* of `commit_ms` (which also
> covers runtime registrations, draw indexing, topology signature, raster store).
> So the L3 patcher would optimize **<~1% of frame time, not on the critical
> path.** On pure ROI this is **G3b** (defer honestly; the bottleneck is resolve).
> The countervailing input is the directive to finish *all planned performance
> work*, under which G3a is in scope regardless of ROI — see Phase 0 decision D1.

### Tier 2 — High (incomplete rewiring & decision-gating evidence)

**G4. Resolve the Stage 5 `Local*` registry axis: finish the re-key, or formally
accept the dual-key design.**
*(Stage 5 / doc 006, L5.3 + cross-cutting invariant #2.)* The plan's destination
is "no runtime index keys on `Identity` after Stage 5," via per-entry
`ViewNodeID` (ownership) + `StructuralPath` (teardown). As built, the primary
dicts stay `[Identity: …]` (`NodeHandlers.swift:3-27`, `LocalTerminationRegistry.swift:26`,
`CommandRegistry`, `DropDestinationRegistry`, `LocalScrollPositionRegistry.swift:34`),
with a `RuntimeRegistrationOwnerKey{viewNodeID?, identity, structuralPath}` sidecar
(`RuntimeRegistrationOwnerKey.swift`) where `viewNodeID` is *optional* and
`removeSubtrees` still matches `identity.isDescendant`. This is behavior-equivalent
*today* only because the duplicate-id collision is now contained one layer up — but
the axis is not separated at these indexes, so the "wrong-axis = latent bug" risk
persists for any future case where two live nodes share a final `Identity`.
*Fix (choose one):* (a) finish L5.3 — make `ViewNodeID` (or `RouteID = ViewNodeID +
kind`) the primary key, demote `Identity` to a debug field, match teardown on a
non-optional `StructuralPath`; **or** (b) accept the dual-key shape as final, make
`viewNodeID` non-optional (or document why unowned entries are safe), and amend the
invariant text in doc 001 (`:259-267`, `:292-293`) and doc 006 so the *destination
contract matches the code*. Either way the contradiction between docs and code must
end.

**G5. Complete Stage 4's two load-bearing rewirings.**
*(Stage 4 / doc 005, L4.4 + L4.5.)* Two specific couplings the stage set out to cut
survive:
- **Raster signature still keys on runtime identity.** `SurfaceTopologyEntry`
  carries `identity: node.identity` and its `Comparable` tuple leads with
  `entry.identity.path` (`SurfaceCompositionMetadata.swift:196,222`). A Stage-5
  runtime re-key of a portal root therefore changes the `SurfaceTopologySignature`
  and forces a full-surface diff — exactly the Test-4 failure mode L4.4 meant to
  prevent. `presentationAttachmentID` / `PromptPresentationItem.id` also still derive
  from `sourceIdentity.path` (`PresentationItems.swift:203-208`, `PortalTypes.swift:20-22`).
  *Fix:* re-source `SurfaceTopologyEntry.identity` and `PromptPresentationItem.id`
  from `StructuralPath`/`ownerStableKey`; *Oracle:* a test asserting
  `SurfaceTopologySignature` is unchanged when only a portal root's runtime identity
  changes (the current `OverlayStackTests` only checks `stableKey`, giving false
  confidence).
- **Animation teleport still keys on runtime `Identity`.** `injectionsByParent`
  keys `[Identity: …]` on `entry.parentIdentity` (`AnimationController.swift:924,1216,1274`),
  but L4.5 requires keying on the *structural* parent path "stable across the
  resolved-child swap." *Fix:* key/match removal injection on `StructuralPath`;
  *Oracle:* re-key the live parent's runtime identity and assert the transient
  re-attaches at the structural parent.

**G6. Make Stage 4's edge carriers actually drive behavior (or they are dead data).**
*(Stage 4 / doc 005, L4.1 + L4.2; "a type that exists but is never consumed".)*
`structuralEdgeRole` is stored as a *second* field beside `surfaceComposition.role`
and is never read; `DeclarationOwnerEdge` is attached and equality-tracked but never
consumed (owner GC/invalidation still runs off the `sourceIdentity` preference
set-difference). *Fix:* give each carrier one real consumer — route presentation
GC/invalidation through `declarationOwnerEdge.owner` (entity) and branch
`computeSupportsRetainedReuse`/`RetainedFrameQueries` on
`structuralEdgeRole == .viewportBarrier` instead of the raw `indexedChildSource !=
nil` check — and make `structuralEdgeRole` a single source of truth (computed from,
or replacing, `surfaceComposition.role`) so the two cannot diverge.

**G7. Supply the alias-deletion gate evidence Stage 5 shipped without.**
*(Stage 0 TEST-4 + Stage 5 / doc 006, L5.6 / Test 4 — the explicit deletion
precondition.)* Stage 5 deleted the registration-alias layer (a real
structural→`ViewNodeID` restore lookup replaces it), but the gate test the plan made
mandatory — proving the structural lookup reproduces the old alias resolution for
the `.id`, nested-`AnyView`, **and custom-`ResolvableView`** cases — was *deleted*,
not satisfied (`RegistrationAliasFindingsTests`/`RegistrationAliasDiagnosticsTests`
are gone). The custom-`ResolvableView` path (doc 005 OQ#2, "the alias evidence Stage
5 actually needs") was never characterized. *Fix:* add a custom-`ResolvableView`
identity-rewrite fixture and a behavior-neutrality test asserting a scoped
invalidate+restore yields a registration set byte-identical to a full rebuild;
**or**, if the layer is irreversibly gone and the corpus shows no non-trivial custom
rewrite, document the bypass and its bounded corpus scope in `VISION-GAP.md`.

**G8. Give Stage 0 a real corpus driver + the duplicate-id provenance assertion.**
*(Stage 0 / doc 002, L0.3 + TEST-3, "the single most decision-relevant assertion".)*
All five Stage-0 tests feed the harness *hand-built synthetic `ResolvedNode` trees*;
the report has **never run over a real resolved frame** (no `.sheet`/`ForEach`/lazy
fixtures), defeating the "measured facts, not a plausible story" premise. And
`DuplicateRuntimeIdentity.producers` is a raw `[NodeKind]` with no
user-vs-framework classification, so the assertion that *every* duplicate traces to
user ids (and no framework primitive collides) — the basis for Stage 3's policy and
Stage 5's collision-resistant allocation — does not exist. *Fix:* add a debug-only
corpus driver beside `RetainedSubtreeReuseTests` that resolves the existing fixture
scenarios and runs the harness, classify producer origin in the duplicate fold, and
assert the user-origin-only profile over the corpus.

### Tier 3 — Medium (test coverage & data-model hygiene)

- **G9. Lock Stage 2's headline reuse win.** *(doc 003, Test #4.)* The equivalence
  gate now keys on `structuralPath` and demotes runtime identity to a mirror
  (`ResolvedNodeEquivalence.swift:95`) — the whole point of Stage 2 — but no test
  builds two `ResolvedNode`s with equal `structuralPath` + different `identity` to
  assert `.geometryReusable`. A regression re-coupling the gate to identity would
  pass the current suite. *Fix:* add that test (plus the converse: same identity,
  different path ⇒ non-equivalent).
- **G10. Decide and verify Stage 6's L6.4.** *(doc 007, L6.4 + Test #5.)*
  Animation/focus/gesture routing was never wired in the runtime layer; transition
  continuity follows the preserved `ViewNodeID` "for free," but per-property
  interpolation maps are still `Identity`-keyed (`AnimationController.swift:1132`,
  `AnimationPropertyValueApplication.swift:20`), so a property animation on a moved
  view would reset. *Fix:* re-key the property-value maps onto `ViewNodeID`, **or**
  record the limit in `VISION-GAP.md`. Either way add Test #5 (a focused, mid-animation
  `.id`-keyed view moved between containers; assert focus + animation continuity
  survive and a removed view's exit transition still plays).
- **G11. Stage 1 L2 signature as a real fold-up.** *(doc 004, Layer 2 + OQ#2/#3.)*
  `subtreeSignature` lives only inside the index walk over resolved fields; the plan
  required a maintained fold-up on `ResolvedNode`/`MeasuredNode`/`PlacedNode`
  covering each retained reader's payload, with `setChildrenPreservingDerivedState`
  audited. Prerequisite for a sound G3(a).
- **G12. Wire Stage 1's duplicate diagnostic + multimap fallback into the index.**
  *(doc 004, Layer 1 duplicate policy.)* The diagnostic exists only in the standalone
  DEBUG tool; the flat product maps (`resolved/measured/placedStructuralIndex`)
  remain last-writer-wins. *Fix:* emit a deterministic diagnostic when
  `nodeByRuntimeIdentity[id].count > 1` and route ambiguous lookups through the
  multimap with conservative fallback.
- **G13. Document Stage 6's duplicate-id honest limit + Test #6.** *(doc 007, L6.5.)*
  The collision-count-change → conservative-rebuild limit is undocumented in
  `VISION-GAP.md` and untested for live `@State`. *Fix:* add the limit note and a
  test pair (order-preserving reorder ⇒ state preserved; collision-count change ⇒
  reset + diagnostic fires once).
- **G14. Checkpoint-totality negative test.** *(doc 006, Test #5.)* The suite proves
  the positive set-equality but not that a deliberately-omitted map *fails* the guard.
  *Fix:* factor the comparison into a helper a negative test can feed an incomplete
  field set.

### Tier 4 — Low (housekeeping; mostly axis-purity that is behavior-neutral today)

- **G15. Repoint scope-path consumers to `StructuralPath`.** *(doc 006, L5.5.)*
  `CommandRegistry`/`DropDestinationRegistry`/`FocusTracker`/`SemanticSnapshot`/
  `SemanticPayloadRouting` still use `scopePath: [Identity]` and scroll-reveal still
  uses `Identity.isAncestor`. Behavior-neutral today because `Identity` and
  `StructuralPath` are lossless mutual projections — but it leaves `Identity` doing
  structural duty and creates churn for any future full demotion. Repoint to
  `StructuralPath`, or note the reliance on the equivalence in the plan.
- **G16.** Stage 0 portal axis (DIV-4) pairing; Stage 2 Test #1 (tree-walk) + Test #6
  (lazy laziness) + the `setChildrenPreservingDerivedState` doc-comment; Stage 3
  optional policies 3 (debug precondition) & 4 (churn fallback); Stage 2 debug-snapshot
  enrichment of the two named files; Stage 5 L5.3 removal-overlay-at-authored-parent
  test (currently only incidental). All flagged low / optional-by-plan.

## `VISION-GAP.md` entries `swift-tui` should carry

Per the org docs policy, accepted *deviations and limits* belong in the child's
`swift-tui/docs/VISION-GAP.md` (the code-vs-intent register). Recommended entries,
whichever way G3/G4/G10 are decided:

1. **Stage 1 L3 deferred** — the retained index rebuilds every committed frame;
   `init(patching:)` is currently a rebuild; the incremental-fragment perf win and
   its oracle are future work (matched-geometry residual still open).
2. **Stage 1 engine** — `FrameMetrics.InvalidationSummary` still classifies via the
   `Identity.parent` path-prefix proxy (until G1).
3. **`Local*` registry keying** (if G4 path b) — runtime registries are
   `Identity`-primary with `ViewNodeID`/`StructuralPath` as a teardown sidecar, by
   design, not the doc-001 "no runtime index keys on `Identity`" end-state.
4. **Animation property maps** — per-property interpolation remains `Identity`-keyed;
   property animations do **not** follow an entity across an identity-changing move
   (until G10a). The doc-007 "Identity keys no runtime index" completion claim is, at
   HEAD, slightly overstated.
5. **Duplicate-id limit** — distinct lifetimes are stable only while collision order
   is stable; a collision-count change falls back to conservative rebuild (state not
   preserved). User error; SwiftUI-aligned.
6. **Stage 0 evidence** — the divergence corpus run and the custom-`ResolvableView`
   alias characterization were not gathered; the alias-layer deletion rests on the
   `.id`/nested-`AnyView` cases only.

## Corrections the existing plan docs need

So the plan set stops over-claiming:

- **001 "What this stage completes"** and **007** — soften "`Identity` keys no
  runtime index" to reflect the `Local*` registries (G4) and animation property maps
  (G10) that still key on `Identity`.
- **004 (Stage 1)** — mark L2 oracle/L3 patcher as *not yet landed* (currently the
  doc reads as if L1+L2 shipped complete); record the `FrameMetrics` engine repoint
  as outstanding.
- **002 (Stage 0)** — record that DIV-3 (alias divergence) was removed downstream and
  the corpus driver / TEST-3 / TEST-4 were not built.

## Phase 0 — resolve forks & build the safety net (before sequencing)

The severity tiers above answer *what matters*. They do **not** answer *what must
be true before each item can start* — and three things were written as "steps" that
are really gates. Resolve these first (≈ half a day of judgment + the harness), and
the rest sequences unambiguously.

**Decisions (forks that resize everything downstream):**
- **D1 — G3 (Stage 1 patcher): build vs. defer.** Evidence (above) says the win is
  <~1% of frame time → ROI favors **G3b**. Directive ("finish all planned
  performance work") favors **G3a**. *Resolution under the finish-everything goal:
  build G3a, but only after G1+G11, and treat `resolve_ms` reduction as the real
  perf headline since that is where the time is.*
- **D2 — G4 (registry axis): finish re-key vs. accept dual-key.** "Finish all
  architectural work" ⇒ **G4a** (make `ViewNodeID`/`RouteID` the primary key, demote
  `Identity` to a debug field, match teardown on a non-optional `StructuralPath`).
- **D3 — G10 (Stage 6 animation/focus): re-key property maps vs. document limit.**
  "Finish all architectural work" ⇒ **G10a** (re-key the property-value interpolation
  maps onto `ViewNodeID` so animation follows the entity across a move).

**Oracle design (the one genuinely under-designed item):**
- **G2's scope.** A behavior-preservation golden cannot be a naive
  *pre-Stage-5-vs-HEAD* diff, because **HEAD already contains Stage 6, which
  intentionally changes behavior** (state survives moves). The golden must freeze the
  behavior classes Stage 5 claimed to *preserve* and explicitly exclude the Stage-6
  semantic deltas. Decide capture point (pre-Stage-5 `8ac275da` vs. freeze-HEAD-and-
  guard-forward) and the serialized surface (resolved/placed/draw + focus/scroll/
  command ordering, via the `Identity` debug projection).

**Shared substrate (build once, four gaps consume it):**
- **A scenario-corpus + serialization harness.** G2 (golden), G8 (Stage 0 corpus
  run), G7 (alias-deletion byte-identity), and G1's verification all need the same
  thing: drive the existing fixture scenarios through resolve and capture/compare
  outputs. doc 008 wrongly scoped this as Stage-0-only. Build it as Phase-0
  infrastructure; it is the highest-leverage single artifact in the remediation.

## Sequencing & gates (post-Phase-0)

```text
Phase 0  : D1/D2/D3 decisions · G2 oracle scope · shared corpus+serialization harness
           │
Tier 1   : G1 (FrameMetrics structural repoint) ─┐
           G11 (fold-up signature on 3 node types)├─► G3a (real patcher) behind a
           G2  (Stage 5 golden — its own track; highest single risk-reducer)  NON-vacuous oracle
           │
Tier 2   : G4a (registry ViewNodeID-primary re-key) ── unblocks honest doc-001 invariant
           G5/G6 (Stage 4: raster sig off identity.path; animation teleport on
                  StructuralPath; consume the edge carriers) ── behind sig-stability oracle
           G7 (custom-ResolvableView alias evidence) · G8 (Stage 0 corpus run)
           │
Tier 3/4 : G9 (Stage 2 reuse lock) · G10a (animation/focus property re-key + Test #5)
           G12 (S1 dup diagnostic) · G13 (S6 dup limit doc+test) · G14 (checkpoint
           negative) · G15 (scope paths → StructuralPath) · G16 (misc)
```

**Dependency graph (what blocks what):**
- `harness → {G2, G7, G8, G1-verify}` — nothing in the evidence/oracle column starts
  before the harness exists.
- `G1 → G11 → G3a` — the patcher needs sound structural adjacency *and* a real
  fold-up signature; do not build the patcher before both.
- `G2 ⟂ G1` — G2 freezes Stage-5 behavior; G1 *changes* invalidation classification
  (exact structure vs. conservative path-proxy), so decide per-case whether G1's
  reclassification is "preserve" (golden matches) or "correctness fix" (golden
  updates). Capture the golden to *include* the `.id`/ForEach/portal/duplicate cases.
- `G4a → doc-001 invariant text` — only after the re-key can "no runtime index keys
  on Identity" be made literally true.
- `G5/G6` independent of G1–G4 (Stage 4 surface), parallelizable.

Every behavior-touching fix lands behind an oracle: G1/G3 behind
structural-classification + non-vacuous byte-equivalence tests; G2 is itself the
oracle; G5 behind the signature-stability test; G10a behind the move
characterization test. Build green + focused suites after each commit;
`bazel test //:org_fast` per change, `//:org_full` before re-pinning the submodule.

## Non-goals (unchanged from the plan set)

- Do not change the public SwiftUI-shaped authoring API.
- Do not make child repos depend on the org root or Bazel.
- Do not reintroduce string-literal `Identity` or compatibility bridges.
- Do not claim SwiftUI compatibility beyond what tests cover.
