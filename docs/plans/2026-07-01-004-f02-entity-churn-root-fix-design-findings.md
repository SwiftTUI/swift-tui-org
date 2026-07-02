# F02 identity-churn root fix — design findings from the first implementation attempt

**Date:** 2026-07-01
**Status:** Findings. The mechanical "extend entity routing to `ExactIdentityModifier`,
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
