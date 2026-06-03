# Structural Identity — Stage 0: Divergence Diagnostics

**Date:** 2026-06-03
**Status:** Plan. Not started.
**Stage:** 0 of the structural-identity migration. Read-only, debug-only, no
behavior change. The evidence-gathering precursor that tunes Stages 3 and 5.
**Entry point:**
[`2026-06-03-001-first-class-structural-identity-proposal.md`](2026-06-03-001-first-class-structural-identity-proposal.md)
— the plan-set index and the *why*.
**Verified against:** `swift-tui` working tree at commit `a020fa55`.

---

## Why this stage exists

Every later stage makes a policy decision that is currently being made *by
guesswork*: how common are duplicate runtime identities really? Does
`Identity.parent` ever disagree with structural containment in the real fixture
corpus, or only in contrived hard cases? Which views actually produce
registration aliases? A migration that commits to an end-state architecture
should commit on *evidence*, not on a plausible story.

Stage 0 builds a read-only diagnostic harness over already-committed frames and
emits a corpus-wide divergence report. It changes no rendering behavior, ships
behind a debug/test flag, and exists to convert four open questions into
measured facts before any production index, reconciler, or node store is touched.

This is the cheapest, safest stage and it has the highest leverage: it is the
difference between "we believe duplicate ids are rare" and "duplicate ids appear
in N of M corpus fixtures, all from `.id(_:)` reuse, never from framework
composition." The first is mediocrity; the second is engineering.

## What it measures

The harness walks committed `ResolvedNode` trees (the same trees
`RetainedFrameIndex.init(frame:)` consumes at
`RetainedFrameQueries.swift:36-130`) and, for each frame, records the four
divergences the whole migration is predicated on:

1. **Path-parent vs structural-parent disagreement.** For every node, compare
   the `Identity.parent` (`GeometryTypes.swift:604-609`) against the node's
   *actual* structural parent (the node whose `children` array contains it).
   Record every mismatch with both identities and the responsible view kind.

   > Correction the harness must encode honestly: the current relation is **not**
   > a raw string-prefix. `Identity.isAncestor(of:)`
   > (`GeometryTypes.swift:629-635`) is a length-guarded *component-wise* prefix
   > check (`zip(components, other.components).allSatisfy(==)`), which already
   > avoids the classic `"/foo"`-prefixes-`"/foobar"` bug. The divergence the
   > migration targets is genuine structural divergence (`.id`, `ForEach`,
   > portals, duplicates), not naive string aliasing. The report must
   > distinguish the two so we do not overstate the problem.

2. **Duplicate runtime identities within a frame.** Count nodes that share a
   byte-identical `Identity`. This is *confirmed reachable* — `ForEach` derives
   each element's identity via `context.identity.explicitID(element[keyPath: id])`
   with no occurrence ordinal (`ForEach.swift:26-28`), and `explicitID`
   stringifies `String(reflecting:)` with no disambiguator
   (`GeometryTypes.swift:625-627`) — so any non-unique id keypath collides. The
   harness measures *how often it actually happens* in the corpus and *which
   construct* produced each collision (bad `ForEach` id vs reused `.id(_:)` vs
   anything framework-internal, which would be a real bug).

3. **Registration-alias divergence.** Record every node whose committed identity
   differs from its registration identity (`ViewNode.swift:22-26`,
   `recordRegistrationAlias` at `ViewGraph.swift:347-382`). Recon shows `.id(_:)`
   / `IDView` is the *only* common producer
   (`RegistrationAliasFindingsTests.swift:155-182`); standard composition
   primitives produce zero non-trivial aliases. Confirm that holds across the
   whole corpus, and flag any *unexpected* alias producer.

4. **Portal / presentation placement vs declaration divergence.** For presented
   content, record the declaration-owner identity
   (`PresentationCoordinatorDeclaration.sourceIdentity`,
   `PortalEntryID.sourceIdentity` at `PortalTypes.swift:2-17`) alongside the
   synthetic placement-parent identity
   (`PortalHost/overlays/entry/body`, composed at resolve by
   `OverlayStack.swift:49-52`). Confirm the Stage-1 trace finding — that placed
   parent equals resolved parent for hoisted content — and quantify how many
   frames carry an active portal at all.

## What it does NOT do

- It does **not** build the production `StructuralFrameIndex` sidecar. That is
  Stage 1 (doc 004), inside `RetainedFrameIndex`. Stage 0 is a *separate*,
  throwaway-grade walker whose only output is a report. Keeping them separate is
  deliberate: Stage 0 must be free to over-collect (every divergence, every
  frame) without any concern for commit-path cost, because it never runs in
  release.
- It does **not** change `Identity`, `ResolvedNode`, `ViewGraph`, or any index.
- It does **not** gate or alter any reuse, invalidation, or lifecycle decision.

## Representation

A debug-only snapshot type and a divergence report, both `#if DEBUG`-gated and
reachable only from tests and an opt-in environment variable:

```swift
#if DEBUG
package struct StructuralDivergenceSnapshot: Sendable {
  package struct NodeRecord: Sendable {
    package let runtimeIdentity: Identity
    package let structuralParent: Identity?      // actual children-array parent
    package let pathParent: Identity?            // Identity.parent
    package let kind: NodeKind
    package let typeDiscriminator: String
    package let explicitIDComponent: String?     // parsed ID[...] suffix, if any
    package let isTransient: Bool                 // ResolvedNode.swift:134
    package let surfaceRole: SurfaceCompositionRole?  // SurfaceCompositionMetadata.swift:95-125
  }
  package let records: [NodeRecord]
}

package struct StructuralDivergenceReport: Sendable {
  package let pathVsStructuralParentMismatches: [(node: Identity, pathParent: Identity?, structuralParent: Identity?, kind: NodeKind)]
  package let duplicateRuntimeIdentities: [(identity: Identity, occurrences: Int, producers: [NodeKind])]
  package let registrationAliasDivergences: [(committed: Identity, registration: Identity, producer: NodeKind)]
  package let portalDeclarationVsPlacement: [(declarationOwner: Identity, placementParent: Identity)]
  package let frameCount: Int
}
#endif
```

The snapshot builder reuses the existing recursive walk shape from
`RetainedFrameQueries.swift:86-130` (it walks `node.children` unconditionally,
transient nodes included — which is exactly what we want for an evidence pass).
It does not need to be fast and must not be wired into the commit path.

## Mechanics

1. **Snapshot builder.** A `static func snapshot(of: FrameArtifacts) ->
   StructuralDivergenceSnapshot` that walks the resolved tree once, recording one
   `NodeRecord` per node. Structural parent is known trivially during the walk
   (the recursion already holds the parent). `explicitIDComponent` is parsed the
   same way `ChildDescriptor` parses it today — string-prefix matching `ID[` on
   the last component (`ChildDescriptor.swift:67-77`) — so the report speaks the
   same language as the reconciler.

2. **Report fold.** A `static func report(from: [StructuralDivergenceSnapshot])
   -> StructuralDivergenceReport` that aggregates across frames. Duplicate
   detection is a group-by on `Identity`; alias divergence reads the existing
   `RegistrationAliasDiagnostics` surface rather than recomputing it; portal
   divergence reads `SurfaceCompositionRole` plus the presentation coordinator's
   `sourceIdentity`.

3. **Opt-in emission.** Behind an environment variable (mirroring the existing
   release-trusts / debug-verifies pattern used for raster damage), emit the
   report to the perf TSV / diagnostics stream so a corpus run produces a single
   machine-readable divergence summary. Default off.

4. **Corpus driver.** A test that runs the existing fixture corpus (the same
   scenarios the retained-reuse suites exercise) through the harness and asserts
   the *invariants we expect to hold*, turning the report into regression
   protection (see Tests).

## Tests

The point of the tests is twofold: prove the harness is correct, and pin the
*expected* divergence profile so a future regression (e.g. a framework primitive
that starts producing duplicate identities) is caught loudly.

1. **Ordinary views have path/structure agreement.** For a corpus of plain
   `VStack`/`HStack`/`Group`/`TupleView`/conditional trees, assert
   `pathVsStructuralParentMismatches` is empty — the path convention and real
   structure agree where nothing intentionally diverges.
2. **Known hard cases are *detected*, not hidden.** `.id(_:)` under a parent,
   `ForEach` with duplicate ids, an active `.sheet`, and a lazy stack each
   produce the expected, enumerated divergence record. These are characterization
   assertions: they document the divergence, they do not "fix" it.
3. **Duplicate-id frequency and provenance.** Assert that every duplicate
   runtime identity in the corpus traces to user-supplied ids (`ForEach` /
   `.id(_:)`), and that **no framework composition primitive** produces one. This
   is the single most decision-relevant assertion: it is the empirical basis for
   Stage 3's "duplicate ids are user error, contain don't model" stance and
   Stage 5's collision-resistant `ViewNodeID` allocation.
4. **Alias producers — measure the *unknown*, not the known.** That `.id(_:)`/
   `IDView` is the only *common* producer is already proven by
   `RegistrationAliasFindingsTests`; re-confirming it is busywork. The genuinely
   open question — the one that actually gates Stage 5's alias-layer deletion — is
   whether **custom `ResolvableView` identity rewrites** produce aliases the
   structural axis does not anticipate (the `RegistrationAliasDiagnostics`
   doc-comment hypothesizes a producer that recon left unexercised). Stage 0 adds
   a custom-`ResolvableView` rewrite fixture to the corpus and characterizes its
   alias behavior. This is the alias evidence Stage 5 actually needs.

Suites this naturally extends / sits beside: `StructuralDiffTests`,
`RegistrationAliasFindingsTests`, `RegistrationAliasDiagnosticsTests`,
`RetainedSubtreeReuseTests`.

## Execution order and touchpoints

| Step | Lands | Primary files |
| --- | --- | --- |
| 0.1 | `StructuralDivergenceSnapshot` + builder (debug-only) | new file under `Sources/SwiftTUICore/Commit/` (e.g. `StructuralDivergenceDiagnostics.swift`) |
| 0.2 | `StructuralDivergenceReport` fold + env-gated emission | same file; perf/diagnostics emission seam |
| 0.3 | Corpus driver + characterization tests | `Tests/SwiftTUICoreTests/Graph/` |

All three steps are `#if DEBUG` and carry zero release behavior change.

## Validation

```bash
swift test --package-path swift-tui --filter StructuralDivergence
swift test --package-path swift-tui --filter StructuralDiffTests
swift test --package-path swift-tui --filter RegistrationAliasFindingsTests
bazel test //:org_fast
```

There is no performance claim and no performance gate for Stage 0. The
deliverable is the report and the characterization tests.

## Risks and non-goals

- **Do not** let the diagnostic walk leak into the commit path or release builds.
  It is intentionally allowed to be O(tree) and allocation-happy because it never
  runs in release.
- **Do not** "fix" any divergence in Stage 0. Detection only. Fixes are Stages
  1–6.
- **Do not** treat the absence of a divergence in the current corpus as proof it
  cannot occur — record the corpus coverage so Stage 3/5 policy notes its scope.

## What this stage hands downstream

- **Stage 3** gets the measured duplicate-id frequency and provenance, which
  decides whether the duplicate-identity policy needs a hard precondition or a
  conservative-fallback-only stance.
- **Stage 4** gets the portal-frame frequency and the declaration-vs-placement
  pairs, which size the edge-role work.
- **Stage 5** gets the custom-`ResolvableView` alias characterization (not a
  re-confirmation of the already-tested `.id`/`IDView` producer), which is the
  evidence that decides whether the registration-alias layer can be deleted
  outright once `ViewNodeID` exists.
- **Stage 1 (004)** gets independent corroboration of its trace finding (placed
  parent == resolved parent for hoisted content) across the whole corpus rather
  than from a single trace.

## Open questions

1. Should the report emission format be the existing perf TSV, a dedicated JSON
   sidecar, or both? (Leaning TSV column-extension for corpus runs, JSON for
   single-fixture debugging.)
2. Should the corpus driver run inside the normal test gate (debug only) or as a
   separate opt-in target to keep gate time down? (Leaning opt-in target plus a
   small in-gate smoke set.)
