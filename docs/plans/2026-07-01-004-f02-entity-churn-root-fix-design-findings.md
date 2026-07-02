# F02 identity-churn root fix — design findings from the first implementation attempt

**Date:** 2026-07-01
**Update 2026-07-02 (third session — orphan-class closure):** the sweep-oracle
census dropped **294 → 172** by closing residual class 1 at the root (swift-tui
commit following `fe1345ba`). What landed:

1. **Ghost-node reclaim (class 1 closed, −122).** A cold resolve of
   `composite → conditional-branch → composite` mints an inner node whose
   output the enclosing chain level absorbs (`normalizeResolvedElements`
   count==1); the inner node is never wired as a child, its identity index
   entry is overwritten by the absorber's reindex, and *no* teardown path can
   reach it — a permanent leak in the baseline framework, churn or not (every
   `TextField` mount leaked one node). Fix: `reindexIdentity` records index
   shadowings into `LifecycleEventBuffers.absorbedShadowedNodeIDs`;
   `pruneAbsorbedShadowedNodes()` at the finalize barrier (and preview, for
   plan equality) reclaims candidates that end the frame parentless,
   same-frame-minted, and not an entity's routed home. The output value does
   NOT carry the ghost's `viewNodeID` (the absorber's transform stamps its
   own), so a value-based reclaim at `finishEvaluation` is impossible — the
   index shadowing is the only observable trace.
2. **`removeSubtree` keep-guard refined to reachability.** The
   visited+parent-detached keep-guard now also requires the node to own one of
   its identity index entries or be an entity's routed home. A live re-rooted
   node always satisfies one of these; a ghost satisfies none. Without this,
   the reclaim was defeated (ghosts are visited on their mint frame).
3. **Rebind-churn continuity guard.** On a collapsed two-EIM chain
   (`.id(stable)` inside `.id(owner-gen)`), the slot node's `resolvedIdentity`
   is the *inner* EIM's identity, so the outer EIM's rebind predicate re-fired
   **every frame** of the steady state — recording a false departure and
   suppressing reuse permanently. Fix: no churn when the arriving EIM's entity
   already routes to the slot node (`entityRouteIsBound`).
4. **Teardown live-children coverage.** After the committed-snapshot value
   descent, `removeSubtree` now also descends still-parented live children:
   a chain collapse can absorb an interior node's output so the value tree
   names its identity with the absorber's stamp — the value walk re-enters
   the absorber and the interior node is reachable only as a live child.
5. **`liveNodeIDs` hygiene.** `finalizeFrame` no longer unions dead IDs back
   into `liveNodeIDs` (mid-resolve eviction of an already-visited occupant,
   same-frame ghost reclaim).

**Remaining 172 orphans (classes 2–3, sweep still required):**
NavigationSource 108, Expansion 30, ScrollFocusReveal 24, Additional 10. Root
cause identified but NOT yet fixed: **value-tree / node-graph divergence under
warm-frame re-shapes.** Traced end-to-end on the scroll fixture: the committed
value tree flip-flops between the mount shape (`Frame → ScrollView →
ScrollContent` node values) and a warm shape where the ScrollContent value
(20 children) pairs positionally with the *slot* node in an enclosing apply
(`resolvedWithRuntimeNodeIDs` count-guard-unmet, 15×/generation) — the
ScrollContent node ends up in **nobody's** children array (detached by
re-parenting applies), index-shadowed, un-routed, and unreachable by any walk;
only the identity-prefix sweep (an identity-space GC) finds it after its
generation departs. Probes proved the SC-shaped value is NOT produced by
`resolveView` returns, Layer-A/B reuse serves, either `applyResolvedNode` call
site, or `apply`/`applyRetainedSnapshot` (all clean) — pointing at the
**layout-realized-children machinery** (`resolvedPreservingLayoutRealizedChildren`
/ scroll viewport realization) splicing interior values into committed trees.
Next session: trace the layout-realization splice, stabilize the committed
shape (or record detach events as reclaim candidates), then re-run the oracle.
The sweep deletion remains blocked until the census reads zero.

**Status:** SUPERSEDED IN PART — the second dedicated session (same day) landed
the extension as swift-tui `fe1345ba` using the "Recommended shape" below
(§Recommended): `entityHosting` scoped to *host-escaping* routes, an
outermost-claim ownership rule for forwarded claims (the piece this doc's
Config A/B analysis was missing — interior wrapper levels re-fire the forwarded
claim and must not steal the enclosing mid-evaluation node, in either
direction), resolved-identity index sparing, a graph-side displacement mark,
and entity-routed descent deferral to the pending-removals barrier. The
sweep-as-oracle step then **failed the deletion gate** (294 orphans still only
caught by the sweep: conditional-variant chrome flips inside stable-entity
controls, churned-generation interiors beyond entity release, old-generation
conditional content) — so the compensator stack REMAINS, per §Compensator-stack
status. Deletion now requires closing those three coverage classes.
Original findings text follows unchanged.

**Original status:** Findings. The mechanical "extend entity routing to `ExactIdentityModifier`,
then delete the compensator stack" plan from the 2026-07-01 survey (F02) was
implemented in three configurations and **does not land as an extension** — the
remaining ~22% of Stage 6 is a design problem, not plumbing. This document
records what was landed instead, the exact failure mechanics of each
configuration, and the load-bearing physics the next attempt must design around.
**Companion survey:** [2026-07-01-001 §F02](../reports/2026-07-01-001-architecture-safety-performance-survey.md).
**Verified against:** `swift-tui` at `ff018143` + this session's hardening commit.

---

## What landed this session (all validated, full gate green)

1. **F28 (the named prerequisite): `TaskLifecycleDiff`.** The ~24-line task
   start/cancel policy that was character-identical in `ViewGraph.finishEvaluation`
   and `ViewGraph.recordReusedSubtree`, and degenerate in the viewport lifecycle
   planner, is now one pure `package struct TaskLifecycleDiff` (SwiftTUICore/Resolve)
   consumed by all three sites, with the churn-suppression special case
   (`identityChanged` + cancels re-keyed to the current identity when all tasks
   vanish) unit-tested for the first time (`TaskLifecycleDiffTests`, 6 tests).

2. **Removal-cascade re-entrancy guard.** `removeSubtree`/`removeResolvedSubtree`
   thread a per-cascade `SubtreeRemovalWalk` entered-set. Teardown descends
   committed snapshots via identity/structural-path lookups that can alias a node
   already being removed higher in the same cascade; re-entry re-ran the whole
   body with no progress (observed: SIGSEGV stack overflow). Node-local teardown
   now runs once per cascade; a re-entry still descends its own snapshot's
   children, because an aliased snapshot can cover departed descendants the first
   entry's snapshot does not — that re-entrant descent is **load-bearing for
   teardown coverage** (removing it leaked scroll-anchor registrations, 25×).

3. **`ViewNode.snapshot()` cycle guard.** `apply` deliberately tolerates a node
   re-appearing inside its own `children` (the parent pointer is never wired for
   it), but the snapshot rebuild recursed through children unconditionally — an
   unfresh self-alias recursed forever. The rebuild now tracks entered nodes and
   returns the committed value on re-entry.

4. **Entity-adoption index hygiene.** When `nodeForIdentity` re-routes a
   reappearing `EntityIdentity` to its prior node, it now clears the *old*
   identity's `nodeIDByIdentity` entry. Before, anything resolving at the old
   (aliased) identity in the same frame adopted the moved node and wired it as a
   child inside its own subtree — one of the two observed cycle creation vectors.

5. **Stamp-claim withdrawal on cross-identity adoption.** An adopted node's
   committed value carries positional runtime-ID stamps verified against its old
   children; after adoption the pairing is unverified, and the stamping fast-path
   asserts on divergence. Adoption across identities now withdraws the claim
   (slow restamp), the same remedy the count-guard-unmet branch already uses.

Items 2–5 are reachable **today** via the public `.id(Hashable)`/`IDModifier`
path (cross-container moves, wrapper toggles, fixed-slot `.id` churn) — they are
not specific to the abandoned extension.

## Why the mechanical extension fails — three configurations

The survey's premise: `ExactIdentityModifier` (package `.id(Identity)`) attaches
no `EntityIdentity`, so `.id` churn stays positionally `.matched` in
`ChildDescriptor.==` and the displaced generation is swept by the compensator
stack; attach the entity, let the diff see the churn, delete the sweep.

### Config A — full `IDModifier` mirror (entity + route + `prepareEntityRoutedOwner` + `EntityRouteProvidingModifier` forwarding)

- **Mid-resolve eviction recursion (SIGSEGV).** The wrapper slot's
  `beginEvaluation` claims the new generation's entity (via ModifiedContent
  forwarding); `nodeForIdentity`'s different-entity branch then ran
  `removeSubtree(existing)` **mid-resolve**, whose snapshot descent aliased the
  evaluation stack → unbounded `removeSubtree ↔ removeResolvedSubtree`
  recursion. (Now bounded by hardening #2 regardless.)
- **Fresh-node churn detection breaks.** Parking the displaced occupant and
  minting fresh makes `wasPresentAtFrameStart == false` on the slot node, so the
  modifier's churn predicate never fires → reuse suppression
  (`withinChurnedSubtree`) lost → arriving re-adopted controls served stale and
  left unvisited → the sweep (visited-sparing) removed **live** subtrees.
  A graph-side signal (`hasEntityDisplacedOccupant`) repairs this specific hole.
- **Non-transparent wrapper collapse (the killer).** `AnyView`'s payload resolves
  through its own node (`…/AnyViewPayload<T>/Content`). With the chain forwarding
  its entity, the Content wrapper claims E at `beginEvaluation`; the entity then
  routes back to that same node from an interior position → the node becomes a
  child inside its own subtree (children-graph cycle), or — after index hygiene —
  reuse-stamped values recreate the alias. Endgame failure: the DEBUG
  stamp-coherence oracle traps at generation 0 (`value stamp 15 diverges from
  live node 14 at …/Content`) because conditional-path components flip identity
  variants under the exercise and adoption ping-pongs the single entity node
  between them while ancestors' reuse-served values hold the other variant's
  stamps. This meshes with two *known* pre-existing seams: synthetic
  `normalizeResolvedElements` Group roots thrash `ViewNodeID`s (ButtonBody
  multi-node seam), and the capture-host orphaning bug (survey F69).

### Config B — A + "never route-adopt a mid-evaluation node"

Prevents the wrapper cycle but **also forbids the transparent-chain collapse**
that is the baseline (and correct) behavior: for plain modifier chains the slot
node and entity node are ONE node (the leaf's resolved output is returned
directly — `normalizeResolvedElements` count==1 wraps nothing). Splitting them
regressed 48 stress assertions (two-node transients everywhere).

### Config C — no wrapper-side claims (entity attached to the resolved node + positional route only)

Cleanest conceptually — but the moment `recordChurnedSubtreeDeparture` is
deleted, 89 assertions fail: for **stable-entity structural churn** (AnyView
payload type churn, panel re-hosting around a stable `.id`), the descriptor
entity is *unchanged*, the slot stays `.matched`, and nothing tears down the
displaced generation. That is precisely the coverage the identity-prefix sweep
provides. Entity-visible diffing only covers the churn where the entity itself
changes.

## The load-bearing physics (what the survey's model missed)

1. **One entity node ≡ the transparent chain node.** `resolveView` +
   `normalizeResolvedElements(count==1)` collapse a modifier chain and its leaf
   into ONE ViewNode whose `identity` is the slot's structural identity and whose
   `resolvedIdentity` is the entity-rooted identity. "Slot node reused with
   identity rebinding" IS the entity node. Any design that gives the wrapper and
   the entity content distinct nodes must handle every registry keyed off either.
2. **Non-transparent hosts exist inside chains.** AnyView payload Content nodes
   (and capture hosts) sit between a slot and its `.id`, resolve through their
   own `beginEvaluation`, and must never be entity-collapsed with their children.
   Today nothing distinguishes "transparent chain wrapper" from "hosting wrapper"
   at claim time — that distinction is the missing first-class concept.
3. **The mid-resolve eviction is load-bearing for same-frame convergence.** The
   different-entity branch's `removeSubtree(existing)` is what makes a fixed-slot
   public-`.id` churn converge in one render (registration counts read `== 1`
   immediately after the click). Deferring it to `finalizeFrame` fails: the
   displaced node was already *visited* by outer wrappers (the two-node
   transient), the pruner's visited guard skips it, and `beginFrame` clears the
   pending set → permanent leak.
4. **Teardown coverage is broader than the structural diff.** The sweep's
   identity-prefix matching catches ghost placeholders and re-rooted descendants
   that live outside any parent's child list and outside committed snapshots.
   Entity-release (`releaseInactiveEntityRoutes` + `pendingEntityRoutedRemovals`)
   and structural `.removed` handling do not reach them.
5. **Stamps and indexes assume identity-stable nodes.** Runtime-ID stamp pairing,
   `nodeIDByIdentity`, and reuse-served committed values all break silently when
   adoption moves nodes across identity variants (conditional-path flips).
   Hardening #4/#5 patch the observed vectors; a full design needs adoption to be
   a first-class index transaction.

## Recommended shape for the dedicated session

1. **Make the wrapper/entity distinction explicit** — e.g. an
   `entityHosting` bit on `ResolveContext`/`beginEvaluation` set by
   non-transparent hosts (AnyView payload, capture hosts), which suppresses
   entity claims and adoption at that node. This unblocks config A's forwarding
   without the collapse hazard.
2. **Keep the same-frame eviction but make it safe** — the walk guard (landed)
   already bounds it; add an explicit convergence contract test (registration
   count == 1 immediately post-churn-click).
3. **Only then re-attach entities on `ExactIdentityModifier`** and delete the
   sweep in two steps: first prove coverage equivalence with the sweep running
   in assert-only mode (it should find zero orphans once the diff + entity
   release cover everything — an oracle, then a deletion), keeping
   `withinChurnedSubtree` as the reuse gate (it compensates identity-keyed reuse,
   not teardown — F27's altitude).
4. **Sequence F69's `beginReuse` evaluationHost refresh and the ButtonBody
   synthetic-root fix first or alongside** — config A's terminal trap sits on
   those seams; they are S-effort per the survey and shrink the blast radius.
5. The stress-suite scroll-offset expectation change (entity lifetime surviving
   owner churn) is the *intended* Stage 6 behavior table — when the extension
   lands, `scrollViewHandlersStayBounded`-style fixtures legitimately change
   expectations. This session's attempt validated that the semantics arrive as
   designed; the reverted test edit is in this doc's history for reuse.

## Compensator-stack status after this session

Unchanged and still required: `recordChurnedSubtreeDeparture`,
`pruneChurnedSubtreeOrphans`, `withinChurnedSubtree`, `sparingVisitedNodes`,
`churnedSubtreeDepartedIdentities`, and the route-side patches (ownerAgnostic
RouteID, hover eviction, per-owner key/paste buckets, TaskRunner sweep). Note
the route-side patches compensate **re-minting**, which `.id`-value churn
retains *by design* (different entity ⇒ different node), so F03's "dissolve
under F02" applies only to same-entity re-adoption cases — several of these
patches likely survive a completed F02.
