# SwiftTUI Invalidation Gap Analysis Against SwiftUI

**Date:** 2026-06-13
**Status:** Investigation report. No implementation in this commit.
**Comparison input:** [2026-06-13-swiftui-observation-invalidation-mechanics.md](2026-06-13-swiftui-observation-invalidation-mechanics.md)
**Primary code surface inspected:** `swift-tui` submodule at the current root checkout.

## Executive assessment

SwiftTUI now matches the broad shape of SwiftUI's invalidation model much more
closely than older reports in this repository imply. The current shipped runtime
has a real dependency graph, records state-slot readers, wires Swift Observation
into view evaluation, coalesces invalidations into scheduled frames, selectively
re-evaluates dirty graph frontiers, and then lets later layout, semantic, draw,
raster, and presentation phases make independent reuse and damage decisions.

The best short version is:

- `@Binding`: strong match. SwiftTUI's `Binding` is get/set plumbing; it has no
  independent invalidation source, and reads are tracked only when the getter
  reaches tracked storage.
- `@State`: good partial match. SwiftTUI has slot-level read dependencies keyed
  by `StateSlotKey(owner: ViewNodeID, ordinal)`, reader attribution is on by
  default, projection-only owners are spared, and equal `Equatable` writes are
  suppressed. The main gap is that no-reader state writes still fall back to the
  owner identity rather than being confidently elided.
- `@Observable`: mixed match. SwiftTUI wraps body-like scopes in
  `withObservationTracking`, so Swift Observation itself only calls back for
  properties read by that scope. But SwiftTUI's own graph dependency index records
  observable object identity (`ObjectIdentifier`), not key paths, so same-object
  peer fan-out is coarser than SwiftUI's property-level target.
- Dirty scheduling and rendering phases: strong match at the architecture level.
  SwiftTUI separates mutation, dirty marking, frame scheduling, body/resolve work,
  retained reuse, layout, semantic extraction, drawing, rasterization, commit, and
  presentation damage. Some subsystems still enter this pipeline with coarse root
  invalidations or root-evaluation fallbacks.

The highest-value future work is not "add invalidation" in the abstract. The
high-value work is to remove the remaining coarse edges that still make narrow
changes pay tree-wide bookkeeping: observable key-path fan-out, conservative
state no-reader fallback, root/frontier fallbacks, registration publication,
checkpoint copying, retained-registration walks, and any future attempt to reuse
descendants under an invalidated ancestor.

## The SwiftUI target

The staged SwiftUI report describes SwiftUI as two overlapping invalidation
systems: legacy property-wrapper/publisher invalidation and the newer
Observation framework. Its central claims are:

- Observation collects reads inside a scope and calls back only when participating
  properties change.
- `@Observable` is property-level: a view that read `model.name` should not be
  invalidated by a change to `model.age`.
- `@Binding` is access plumbing over source storage, not a separate invalidation
  system.
- SwiftUI separates dirty marking, `body` re-evaluation, reconciliation, and
  renderer updates.
- Public evidence for unread `@State` elision is less direct than for
  Observation, but OpenSwiftUI shows a plausible `wasRead`-style model where
  merely projecting a binding does not mark the owner as a reader.

Those points are the comparison target here: reader-scoped invalidation plus a
later reconciliation pipeline, not a promise that every mutation avoids all work
or that every invalidated view produces pixels.

## Current SwiftTUI mechanics

### State reads and writes

SwiftTUI state storage is graph-backed. `@State` builds a dynamic location that
reads and writes a `ViewNode` state slot when a live graph node exists
(`swift-tui/Sources/SwiftTUIViews/State/State.swift:287`). The slot key is
`StateSlotKey(owner: ViewNodeID, ordinal)` (`swift-tui/Sources/SwiftTUICore/Resolve/DependencySet.swift:1`).

On read, `ViewNode.stateSlot` initializes the slot and records a state read for
that key. With reader attribution enabled, the read is recorded on
`ViewNodeContext.current`, the evaluating reader, rather than blindly on the slot
owner (`swift-tui/Sources/SwiftTUICore/Resolve/ViewNode.swift:208`). The
configuration is default-on and can be opted out with
`SWIFTTUI_READER_ATTRIBUTION=0`
(`swift-tui/Sources/SwiftTUICore/Resolve/ReaderAttributionConfiguration.swift:13`).

On write, `AnyStateSlot.set` returns `didChange`, using a runtime `Equatable`
comparator when possible, so equal writes do not proceed to invalidation
(`swift-tui/Sources/SwiftTUICore/Resolve/StateSlot.swift:97`). Changed writes
queue graph-local dirty work for the slot key and request invalidation for the
recorded readers when reader attribution is enabled
(`swift-tui/Sources/SwiftTUICore/Resolve/ViewNode.swift:250`). If no readers were
recorded, SwiftTUI falls back to the owner identity
(`swift-tui/Sources/SwiftTUICore/Resolve/ViewNode.swift:296`).

There is also a runtime `StateContainer` path for non-wrapper state. It is
`Equatable`-gated in the same broad spirit: `replace` and `mutate` return without
invalidating when the candidate value equals storage, and changed writes carry
current animation request and batch metadata when the invalidator supports it
(`swift-tui/Sources/SwiftTUICore/Runtime/StateContainer.swift:22`). This path is
identity-configured rather than dependency-indexed, so its precision depends on
the caller choosing the right invalidation identities.

Dedicated tests lock the projection behavior: in reader-attributed mode, a view
that only projects `$flag` is not a state-slot dependent, while the genuine
downstream reader is (`swift-tui/Tests/SwiftTUIViewsTests/ReaderAttributionTests.swift:76`).
The same suite checks write-side invalidation retargeting away from the projecting
owner (`swift-tui/Tests/SwiftTUIViewsTests/ReaderAttributionTests.swift:110`).

### Binding

SwiftTUI's `Binding` is exactly the expected get/set facade:
`wrappedValue.get` calls the getter and `wrappedValue.set` calls the setter
(`swift-tui/Sources/SwiftTUIViews/Foundation/ViewBaseTypes.swift:13`). Dynamic
member bindings compose those same closures (`ViewBaseTypes.swift:56`).

That means a binding read tracks only through the underlying storage. A
`State`-derived binding reaches `ViewNode.stateSlot` through the `State` location,
while a constant or manually-created closure binding has no dependency mechanism
unless its getter does tracked work.

### Observation and `@Bindable`

SwiftTUI has a real Observation bridge. `ObservationBridge.track` wraps a scope in
`withObservationTracking` and records a pass for the current `Identity`; on change
it queues observation dirty work and requests invalidation of the observed
identity (`swift-tui/Sources/SwiftTUIViews/Environment/Observation.swift:50`).
`ResolveContext.trackingObservableAccess` is the common entry point
(`swift-tui/Sources/SwiftTUIViews/Environment/ResolveContext.swift:338`), and
`View.resolveBody` wraps body construction in that tracking call
(`swift-tui/Sources/SwiftTUIViews/State/State.swift:366`).

The repo-owned `@Bindable` records the model object and then reads the key path,
which both populates SwiftTUI's object-level dependency index and lets Swift
Observation capture the concrete property access
(`swift-tui/Sources/SwiftTUIViews/Foundation/ViewBaseTypes.swift:69`). Environment
values that are `Observable & AnyObject` similarly record the object identity
when read (`swift-tui/Sources/SwiftTUIViews/Environment/Environment.swift:137`).

The gap is the shape of SwiftTUI's own dependency key. `DependencySet` stores
`observableReads: Set<ObjectIdentifier>` rather than per-property key paths
(`swift-tui/Sources/SwiftTUICore/Resolve/DependencySet.swift:23`). The graph test
for observation fan-out explicitly expects a triggering node and a peer that both
record the same observable object token to re-evaluate, while an unrelated object
does not (`swift-tui/Tests/SwiftTUICoreTests/Graph/ViewGraphTests.swift:382`).
That is object-level precision at the graph layer, not SwiftUI's target
property-level precision.

### Dependency indexing

Each `ViewNode` owns a `DependencyTracker`. `beginEvaluation` resets it, reads
populate it during the body/resolve pass, and `finishEvaluation` installs the
current `DependencySet` on the node
(`swift-tui/Sources/SwiftTUICore/Resolve/ViewNode.swift:157` and
`swift-tui/Sources/SwiftTUICore/Resolve/ViewNode.swift:189`).

`ViewGraphDependencyIndex.reindex` removes old edges and inserts new ones into
reverse indexes for state slots, environment keys, and observable object tokens
(`swift-tui/Sources/SwiftTUICore/Resolve/ViewGraphDependencyIndexing.swift:1`).
Tests verify dependency replacement and index removal when nodes are re-evaluated
or pruned (`swift-tui/Tests/SwiftTUICoreTests/Graph/ViewGraphTests.swift:250`).

### Scheduling and dirty evaluation

The runtime coalesces frame intents. `FrameScheduler.requestInvalidation` unions
invalidated identities and records an invalidation wake cause; `consumeReadyFrame`
produces one `ScheduledFrame` and clears the pending sets
(`swift-tui/Sources/SwiftTUICore/Pipeline/Scheduler.swift:104`). Animation-aware
invalidations coalesce animation request and batch metadata on the same scheduler
(`Scheduler.swift:336`).

`RunLoop.resolveContext(for:)` turns a `ScheduledFrame` into a `ResolveContext`
with invalidated identities, environment values, transaction metadata, the
invalidation proxy, and the observation bridge
(`swift-tui/Sources/SwiftTUIRuntime/RunLoop/RunLoop+ResolveContext.swift:7`).
That transaction metadata is narrower than SwiftUI's full transaction concept:
`TransactionSnapshot` currently carries resolve-time animation request, animation
batch ID, and a debug signature (`swift-tui/Sources/SwiftTUICore/Resolve/TransactionSnapshot.swift:1`).

`FrameResolveState.prepareInputs` decides whether selective evaluation can be used.
It disables selective evaluation when root evaluation is forced, focus/press/proposal
changed, or the root identity itself is invalidated
(`swift-tui/Sources/SwiftTUIViews/Environment/FrameResolveState.swift:185`).

When selective evaluation is available, the frame head calls
`viewGraph.invalidateAndQueueDirty`; otherwise it calls `viewGraph.invalidate`
(`swift-tui/Sources/SwiftTUIRuntime/Rendering/DefaultRendererFrameHeadCoordinator.swift:222`).
The distinction matters: `ViewGraphDirtyEvaluationPlanner.targetPlan` only returns
a frontier plan when every graph-known invalidated node is also graph-local dirty
(`swift-tui/Sources/SwiftTUICore/Resolve/ViewGraphDirtyEvaluationPlanning.swift:15`).
Otherwise `ViewGraph.evaluateDirtyNodes` falls back to the root evaluator
(`swift-tui/Sources/SwiftTUICore/Resolve/ViewGraph.swift:734`).

### Retained reuse and later phases

`resolveView` checks `viewGraph.reusableSnapshot` before recomputing a node
(`swift-tui/Sources/SwiftTUIViews/Foundation/ViewFoundation.swift:275`).
Reuse is denied if the node cannot reuse under current environment/transaction or
if the candidate intersects the invalidation set structurally or identity-wise
(`swift-tui/Sources/SwiftTUICore/Resolve/ViewGraph.swift:1175`). A disjoint retained
subtree can be reused and recorded through `recordReusedSubtree(..., retained:
true)` (`ViewGraph.swift:1217`).

After the frame head, the tail has separate retained state. `FrameTailRetainedState`
keeps the previous committed retained frame index, raster surface/topology, drawn
identity set, and retained semantic/draw phase products
(`swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailRetainedState.swift:4`).
The inline tail measures and places the resolved tree, derives presentation damage,
reuses retained semantics/draw when the proof allows it, and rasterizes against the
previous surface and damage hints
(`swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailRenderer+InlineStages.swift:10`).
Deadline-only offscreen redraws can also skip the rendering pipeline when the
pending redraw identities are disjoint from identities that have appeared on the
visible surface (`swift-tui/Sources/SwiftTUICore/Pipeline/OffscreenFrameElision.swift:1`).

This is a strong match to the staged SwiftUI report's distinction between
invalidating a dependency, re-evaluating a body, and redrawing pixels. SwiftTUI can
over-evaluate a body and still reuse layout, draw, raster, or presentation work.

## Match matrix

| Area | Match to SwiftUI target | Evidence | Main caveat |
| --- | --- | --- | --- |
| Binding as plumbing | Strong | `Binding` is closure-backed get/set; reader-attributed `@State` makes projection-only owners cheap | Opaque manual bindings remain only as precise as their closures |
| Local `@State` read tracking | Strong for actual readers | `StateSlotKey` reverse index, default-on reader attribution, write-side retargeting tests | No-reader writes fall back to owner |
| Equal state-write suppression | Strong for `Equatable` runtime values | `AnyStateSlot.set` comparator suppresses unchanged writes | Non-Equatable values conservatively change on every write |
| `@Observable` property tracking | Partial | `withObservationTracking` wraps body-like scopes and callbacks are pass-scoped | SwiftTUI's graph index stores object token, not key path |
| Environment reads | Partial/strong | `EnvironmentValues` records key reads and observable environment object reads | Some runtime-derived values, especially focus, require special handling |
| Dirty scheduling | Strong | `FrameScheduler`, `ScheduledFrame`, `FrameResolveState`, `ViewGraphDirtyEvaluationPlanner` | Many non-state runtime paths still request root or broad identities |
| Reconciliation/reuse | Strong but conservative | retained snapshots, structural checks, frame-tail retained state | Ancestor invalidation blocks descendant reuse unless the invalidation source is narrowed |
| Redraw separation | Strong | layout, semantics, draw, raster, damage, commit are separate phases | Current top costs are often bookkeeping outside pure body evaluation |
| Transaction semantics | Partial | animation request and batch metadata are captured and coalesced | SwiftUI's transaction surface is broader than SwiftTUI's current snapshot |

## Gaps

### G1. Observable graph dependencies are object-level, not key-path-level

SwiftUI's Observation story is property-level: a change to an unread property
should not invalidate the view scope. SwiftTUI delegates the first hop to
`withObservationTracking`, so a single tracked scope has Swift's property-level
callback behavior. But after that callback fires, SwiftTUI's cross-node fan-out
uses `ObjectIdentifier(model)`. Any node that recorded the same object token can
be dirtied, even if it read a different property.

**Value of filling:** medium to high. It matters when one observable model backs
many independent UI regions, e.g. a dashboard model with counters, filters, and
status flags read by disjoint terminal panes. Property-level graph fan-out would
move SwiftTUI closer to SwiftUI and reduce avoidable peer re-evaluation.

**Architectural cost:** high. The public Observation API notifies a tracked scope
when one of its accessed properties changes; it does not give SwiftTUI the access
list as a public dependency artifact. To index key paths at the graph layer,
SwiftTUI likely needs one of:

- a repo-owned observable/bindable macro seam that records `(object, keyPath)` in
  `DependencySet`,
- use of Observation SPI, if acceptable and stable enough for this project,
- a narrower policy: do not fan out same-object peers and rely only on each
  `withObservationTracking` callback, accepting possible duplicate callbacks
  rather than object-level graph fan-out.

All options need adversarial tests for `@Bindable`, environment-injected models,
computed properties, collection elements, cancellation drafts, and pruned
subtrees.

### G2. No-reader `@State` writes still invalidate the owner

Reader attribution means projection-only owners are no longer treated as readers.
However, when a state slot has no recorded readers, `stateChangeInvalidationIdentities`
falls back to the owner identity. That is deliberately defensive: conditional or
deferred readers may not have been recorded on the last committed pass.

**Value of filling:** low to medium. It can remove unnecessary frames for truly
unread state, but most user-visible state has at least one real reader. The
highest-value owner-attribution case, presentation triggers, has already been
addressed by reader attribution and trigger splitting.

**Architectural cost:** medium with correctness risk. A safe design needs an
"unknown/read-not-yet-established" state rather than simply dropping no-reader
writes. It should distinguish first install, hidden conditional branches, lazy
tabs, deferred builder payloads, `@GestureState`, `FocusState`, lifecycle work,
and graph restoration after aborted frames. The failure mode is silent stale UI.

### G3. Ancestor invalidation still blocks descendant reuse

`ViewGraph.reusableSnapshot` intentionally refuses reuse when the candidate is
the invalidated identity, an ancestor, or a descendant on either structural or
runtime identity axes. This is sound: a descendant may read a binding, closure, or
environment value captured from the ancestor. Reusing it blindly can render stale
data.

Reader attribution solves many practical cases by moving the invalidation away
from the ancestor. It does not provide a general proof that unchanged descendants
under an invalidated ancestor can be reused.

**Value of filling:** high in broad app interactions. It would help root-owned
theme/config changes, model updates in high-level container views, legacy or
external invalidation paths, and any remaining presentation/frontier cases where
the invalidation source cannot be moved off the heavy subtree.

**Architectural cost:** very high. This is the hardest SwiftUI-like dependency
graph problem. The runtime would need to carry "changed dependency keys" through
the invalidation signal and retain transitive dependency summaries for each
candidate subtree. Reuse under ancestor invalidation would be allowed only when
the subtree's transitive `stateSlotReads`, `environmentReads`, and observable
reads do not intersect the changed keys. Closure and binding read coverage must
be complete before this is safe.

This also interacts with structural identity, portal placement, capture-hosted
islands, retained registration restore, and runtime task/lifecycle publication.
The right cost estimate is a multi-PR architecture project, not a local patch.

### G4. Several runtime subsystems still use coarse invalidation identities

State and Observation have precise paths, but the broader runtime still has
coarse invalidation calls. Examples include input fallback paths that request the
root identity, accessibility announcements that invalidate the root, focus/press
gates, pointer and hover paths, and presentation portal maintenance. Some are
correctness backstops; others are older broad wakeups.

**Value of filling:** medium to high. The existing performance history shows that
moving hot presentation reads into a trigger leaf and moving focus-derived
environment out of the reuse snapshot produced large wins. Similar scoping work
on remaining hot subsystems could reduce the need for root evaluation and make
selective evaluation more frequent.

**Architectural cost:** medium to high. Each subsystem needs its own causal
model. The cost is not writing `requestInvalidation(of:)`; it is proving the
smaller identity set still updates semantic routes, task/lifecycle state, focus
presentation, gesture state, and host damage.

### G5. Selective evaluation has conservative gates

`FrameResolveState.prepareInputs` turns off selective evaluation for forced root
evaluation, focus/press/proposal changes, and root identity invalidation. In the
frame head, non-selective frames call `viewGraph.invalidate` instead of
`invalidateAndQueueDirty`, so the graph cannot form a dirty frontier. This is
sound but broad.

**Value of filling:** high for interaction-heavy terminal apps. Current next-phase
docs identify root-evaluation registration publication, checkpoint copies, and
portal-root force-queueing as important residuals. These are not "state wrapper"
problems, but they decide how often the precise graph can actually act precisely.

**Architectural cost:** high. Narrowing the frontier means auditing every
incidental guarantee currently provided by the root walk: island staleness
propagation, registration publication, semantic snapshot stability, presentation
portal maintenance, animation tick behavior, focus sync, and checkpoint rollback.

### G6. Dependency-bearing wrappers are bespoke, not DynamicProperty-boxed

SwiftUI has a generalized dynamic-property update model. SwiftTUI has focused
wrappers (`State`, `GestureState`, `FocusState`, environment, `Bindable`) wired
through authoring context, `ViewNodeContext`, graph scope, and wrapper-specific
locations. This is understandable for a terminal-first renderer, but it makes
each new dependency-bearing wrapper a custom integration.

**Value of filling:** medium. A general dynamic-property box/update protocol
could make new wrappers safer and make first-read/update semantics more explicit.
It would also give a better home for unknown/no-reader state and wrapper-level
transaction behavior.

**Architectural cost:** medium to high. It touches public wrapper semantics,
authoring context, state slot ordinals, graph scoping, preview/default renderer
behavior, and test harness expectations.

### G7. Structural identity is mostly in place but not yet a full incremental engine

SwiftTUI now has `ViewNodeID`, `StructuralPath`, `EntityIdentity`, and
`StateSlotKey`. `ViewGraph.nodeForIdentity` routes entity identities through
`EntityRoutingTable`, handles duplicate explicit IDs with distinct `ViewNodeID`
lifetimes, and indexes structural paths. `StructuralFrameIndex` indexes the
resolved tree and can classify structural ancestor/descendant relationships.

The retained frame index still rebuilds in `init(patching:with:)`; the incremental
fragment patcher is explicitly deferred (`swift-tui/Sources/SwiftTUICore/Commit/RetainedFrameQueries.swift:79`).

**Value of filling:** medium for invalidation correctness, potentially high for
bookkeeping cost. Structural identity already helps avoid conflating runtime
identity with containment. The remaining value is in using it to avoid full
retained-index rebuilds, make invalidation summaries less conservative, and reduce
root/frontier fallback costs.

**Architectural cost:** high. The previous plans already identify the hard
oracle: a patched retained index must be byte-equivalent to a full rebuild while
being meaningfully different in implementation. It also interacts with duplicate
IDs, portals, capture hosts, and phase-specific retained products.

### G8. Body re-evaluation remains all-or-nothing per invalidated node

SwiftTUI can avoid evaluating disjoint nodes. Once a node is selected for
evaluation, its body/resolve scope runs normally. There is no finer-grained
partial body interpreter, memoized local expression graph, or automatic
EquatableView-style boundary for arbitrary subexpressions.

**Value of filling:** workload-dependent. It matters if body construction itself
dominates after graph/frontier work is already narrow. Current reports do not
show this as the top residual compared with registration, checkpoints, and
retained walks.

**Architectural cost:** very high for automatic behavior; medium for explicit
author opt-ins. A general solution trends toward SwiftUI's private graph/attribute
machinery. An explicit reusable/memoized boundary would be cheaper but changes
the authoring model and carries stale-rendering risk.

### G9. Transactions are narrower than SwiftUI's transaction model

SwiftTUI coalesces frame causes and carries animation request plus animation
batch metadata through `TransactionSnapshot`. That matches the most visible
terminal-renderer need: ensuring state writes inside `withAnimation` reach the
frame that samples animation values. SwiftUI transactions cover a wider semantic
surface, including richer animation/disabling behavior and framework-private
end-of-update coordination.

**Value of filling:** medium. Wider transaction semantics could make future
animation, transition, and dependency-coalescing behavior more SwiftUI-like. It
is less likely to be the next raw performance win than frontier/root scoping.

**Architectural cost:** medium to high. It would touch scheduler coalescing,
resolve context, retained-reuse equivalence, animation registration, observation
draft/commit behavior, and any future dynamic-property update pass.

## Potential value of filling the gaps

The repo history shows the value is real when the gap is on a hot path:

- H2 made narrow interaction recompute roughly flat in tree size and cut
  `resolve_ms` by 41-62 percent on the synthetic narrow-invalidation sweep
  (`docs/reports/2026-05-30-h2-resolve-reuse-findings.md:10`).
- H3 removed retained-subtree bookkeeping over reused descendants and cut
  `resolve_ms` by 22/41/49 percent across the same sweep
  (`docs/reports/2026-05-30-h3-retained-subtree-findings.md:10`).
- Reader attribution plus write-side retargeting dropped sheet-open
  invalidation conflict from 888 to 5 and improved CPU/frame and p95 latency by
  about 9 percent on the measured rows=176/704 scenarios
  (`docs/reports/2026-06-09-lever-b-implementation-and-findings.md:23`).
- Moving `isFocused` out of reuse-compared environment snapshots cut sheet
  `resolve_ms` 45 percent and total CPU 29 percent in the co-located rows=176
  scenario (`docs/reports/2026-06-12-next-wave-completion.md:28`).
- Popover trigger splitting improved popover `resolve_ms` 38 percent and
  `pipeline_ms` 24 percent (`docs/reports/2026-06-12-next-wave-completion.md:80`).

The remaining value is probably uneven:

- **High value:** reducing root/frontier fallback, registration publication,
  checkpoint copies, retained-registration restoration walks, and same-object
  observable peer fan-out in apps with large shared models.
- **Medium value:** no-reader state elision and wrapper abstraction, mostly for
  correctness clarity and avoiding rare unnecessary frames.
- **Speculative value:** automatic reuse under ancestor invalidation and partial
  body evaluation. The upside is large, but current measurement points elsewhere
  for the next practical wins.

The current 2026-06-12 next-phase proposal is consistent with this: after the
latest reader-attribution and focus wins, the measured sheet residual is led by
commit/registration publication, checkpoint create/restore, and retained
registration/process-resolved-tree walks rather than the basic state wrapper
(`docs/plans/2026-06-12-001-perf-next-phase-proposal.md:11`).

## Architectural cost summary

| Work | Value | Cost | Risk | Notes |
| --- | --- | --- | --- | --- |
| Keep current state reader attribution and add more adversarial tests | Medium | Low/medium | Low | Protects an already valuable default-on behavior |
| No-reader state elision | Low/medium | Medium | Medium/high | Needs unknown-reader state and deferred/conditional coverage |
| Observable key-path dependency keys | Medium/high | High | Medium/high | Public Observation does not expose access lists as graph data |
| Scope coarse runtime invalidations subsystem by subsystem | Medium/high | Medium/high | Medium/high | Best incremental path; repeat the trigger/focus style of work |
| Preserve selective frontier through more frames | High | High | High | Touches portal, focus, animation, lifecycle, checkpoints |
| Transitive dependency summaries for ancestor reuse | High | Very high | Very high | Silent stale UI is the main failure mode |
| Incremental retained-index patching | Medium/high | High | High | Needs byte-equivalence oracle with real patch path |
| DynamicProperty-like wrapper framework | Medium | Medium/high | Medium | Helps future wrappers more than immediate perf |
| Automatic partial body evaluation | Unknown/high | Very high | Very high | Not supported by current evidence as next best move |
| Broader transaction semantics | Medium | Medium/high | Medium/high | Needed for closer SwiftUI parity, not the hottest measured residual |

## Recommended sequence

1. **Do not re-litigate old owner-anchored `@State` as current truth.** The current
   implementation has default-on reader attribution and write-side retargeting.
   Any new report or plan should treat older owner-attribution sections as
   historical unless explicitly marked superseded.
2. **Add focused gap tests before behavior changes.** In particular:
   no-reader state writes, same-object/different-property observable peers,
   conditional/deferred binding readers, environment-injected observables,
   lazy tab/viewport content, and aborted-frame Observation drafts.
3. **Take the pragmatic next-phase perf path first.** Registration publication
   scoping, checkpoint cost, and retained-registration walks are measured current
   residuals. These are adjacent to invalidation precision and likely pay sooner
   than a general SwiftUI-style dependency engine.
4. **Prototype observable key-path indexing as a small vertical slice.** Use one
   `@Bindable` model with two properties and two peer subtrees. Prove whether
   SwiftTUI can get key-path-level graph keys without unstable SPI. If not,
   document object-level fan-out as an intentional limit.
5. **Only then consider reuse under ancestor invalidation.** That project needs
   changed-dependency propagation, transitive subtree dependency summaries, and
   strong stale-rendering oracles. It is the conceptual SwiftUI parity move, but
   it should not precede the measured residual work.

## Bottom line

SwiftTUI is no longer a coarse "state owner invalidates the whole subtree" system
on its main state path. It has a credible SwiftUI-like invalidation core for
state and bindings, a real Observation bridge, and a layered retained rendering
pipeline. The remaining mismatch with SwiftUI is concentrated in the precision of
observable graph keys, defensive no-reader fallback, conservative root/frontier
gates, and the lack of a general proof system for reusing descendants under an
invalidated ancestor.

Filling those gaps is valuable, but the work is architectural. The safe path is
incremental: keep dependency evidence explicit, make each subsystem's invalidation
cause smaller, preserve oracles for stale rendering, and let the measured
residuals choose the next tranche.
