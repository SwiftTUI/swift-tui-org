# Focus Model Reassessment & Redesign Plan

Date: 2026-06-29
Status: Proposal — design + plan. **Phases 1, 2, and the full focus-role
redesign are implemented** (focus-target decoupling → pure active/visible-context
activation → explicit command-host role + container abstraction; see Part 3 / the
phase status sections below). The crash fix (Part 0), Phase 1, Phase 2, and the
redesign are shipped. **Phase 3 (convergence loop → dependency graph) is underway:
slice 1 (single-pass convergence behind a flag) and slice 2's precise
focused-value reader attribution are shipped (gate still default off, both proven
at parity); only flipping the default — gated on a by-hand gallery pass — and
retiring the loop + budget remain.**

## Phase 1 status (implemented 2026-06-29)

A transparent (open) `Panel` is now a focus **target only as a fallback** — when
it has no focusable descendant. Implemented in `SemanticExtractor.extract`
(`Semantics.swift`): after the walk, a focus region whose node is an open `Panel`
and whose identity is an ancestor scope of another focusable region (i.e. it has
a focusable descendant) is pruned, so Tab reaches the leaf directly. A bare open
`Panel` (key-command host with no focusable child) and a `.sealed` Panel keep
their region. List rows are unaffected (synthetic payload regions, not `Panel`s).

This fixes bug #3 facet 1 (`FocusContextRuntimeTests` Tab traversal now passes).
Test updates: two `KeyCommandDispatchTests` route tests dropped their
`setFocus`-returns-true assertion (the row is now focused directly, so setFocus is
a no-op) and assert the row is focused instead.

Verified: every focus-touching suite passes (FocusContext, KeyCommandDispatch,
FocusTransition, SwiftUISurface (197), PanelTests, PresentationActionScope,
InteractionGate, AsyncFrameTail, TextInputRuntime, Phase4Observation,
PipelineContract, ImperativeAuthoringContextDispatch, DropDestination, and
InteractiveRuntime focus tests). Because the macOS test bundle hits the
pre-existing `#12` snapshot/run-loop memory-corruption crash on `swift test`,
verification was run under **AddressSanitizer** (which shifts the layout out of
the deterministic-crash phase and is clean on `#12`); the authoritative full
gate is Linux CI (no main-thread `#12`).

NOTE: Phase 1 deviates from the chosen end-state (active/visible-context
activation) in *one* way — it keeps a bare open `Panel` focusable as a fallback
rather than dispatching its commands by visible context. This is behaviorally
identical for every case with focusable content (all real UIs); pure
active-context (Phase 2) removes the fallback. The transparent-container marker
is currently the `.view("Panel")` node kind; Phase 2/full redesign should replace
it with an explicit focus-role on `ActionScope`.

## Phase 2 status (implemented 2026-06-29, swift-tui `335271c0`)

Pure active/visible-context activation. The Phase 1 fallback is removed: an open
`Panel` (Role-A command/chrome host) is **never** a focus target. In
`SemanticExtractor.extract` (`Semantics.swift`) every focus region an open
`Panel` emits is now pruned unconditionally (not just when it has a focusable
descendant), so Tab always passes through to item leaves. A `.sealed` Panel still
keeps its region (the deliberate stop); List rows are unaffected.

Command activation re-bases from the focus chain onto the **active/visible
context** so a bare command-host Panel's key commands still fire without focus:

- `SemanticExtractor` tracks the deepest visible hosting region's scope chain and
  publishes it as `SemanticSnapshot.activeCommandScopePath` (the host's own
  `scopePath`, which already includes its scope identity since a `Panel` is a
  `focusScopeBoundary`).
- `RunLoop.commandDispatchScopePath()` prefers the focused region's `scopePath`
  (a refinement that already extends through every ancestor host when focus
  exists) and falls back to `activeCommandScopePath` when nothing is focused. The
  keyCommand dispatch site uses it; shallowest-wins is preserved over the
  active-context chain. (`topmostNavigationDestinationPopAction` and
  drop-destination dispatch were left on the focus chain — rebasing those is a
  possible follow-up, not required for the bare command-host case.)

Convergence-loop fix (a latent bug Phase 2 exposes): a route change to a host
with no focusable leaf must clear the now-stale focus, but the rerender budget
derived from a zero-candidate tree (`max(1, syncCandidateCount + 1) == 1`)
granted **zero** rerenders and tripped the convergence assertion. The budget now
floors at one settling pass (`max(1, syncCandidateCount) + 1`); it only ever
grants headroom, so no converging loop regresses.

Test updates: `PanelTests` "Panel is focusable" is reinterpreted as "an open
Panel is a focus *scope* but not a focus *target*" (a bare host yields zero focus
regions; a host wrapping a focusable leaf yields exactly one — the leaf). The
bare-Panel `KeyCommandDispatchTests` route test now asserts focus *clears* after
the route change and the command fires via active context
(`activeCommandScopePath` non-empty). The drop-dispatch helper comment was
refreshed (Panels no longer appear in the focus region list).

Verified under **AddressSanitizer** (same `#12`-dodging rationale as Phase 1):
PanelTests, FocusContextRuntime, FocusTransition, KeyCommandDispatch,
DropDestinationDispatch, SwiftUISurface (197), AppRuntime, AsyncFrameTail,
Phase4Observation, PipelineContract, TabViewLifecycle, FocusTracker,
AccessibilityNodeExtraction, RetainedReuseInvariant, and more — all green. The
two ASan crashers (`InteractiveRuntimeTests`, `StackSafetyRegressionTests`) are
pre-existing `#12`/deep-recursion artifacts: `InteractiveRuntimeTests` was
confirmed to crash identically at Phase-1 HEAD with the Phase-2 changes stashed.
`SwiftTUIRuntime` cross-compiles clean for `wasm32-wasi`. The authoritative full
gate is Linux CI (no main-thread `#12`).

## Full focus-role redesign (implemented 2026-06-29, swift-tui `fbf48e7a`)

Completes the items the Phase 2 note had deferred to "the full redesign," and
adopts the correct structural abstraction for a host.

**Explicit command-host role (replaces the node-kind marker).** A new
`SemanticMetadata.isCommandHost` flag marks the Role-A hosting capability,
orthogonal to focus participation. It replaces *both* the Phase-2 `.view("Panel")`
string match *and* the resolve-time `hasFocusableDescendant` heuristic on
`NavigationStack` / `NavigationDestination`. Removing that heuristic also fixes a
latent bug: it counted only explicit `.focusable(true)` descendants and missed
*automatic* leaves (`Button`/`TextField` via `AutomaticFocusPolicy`), so a host
wrapping a `Button` wrongly made itself a focus target.

**Hosts are containers, not controls.** Decided from first principles: a control
is an interactive *leaf* the user operates and a focus/hit target in its own
right; a host is a transparent structural *scope* that groups content and hoists
commands/chrome. So `Panel`, `NavigationStack`, and `NavigationDestination` now
set `isCommandHost` instead of `isFocusable = true`. They no longer participate in
top-level focus, so they emit no focus region (no prune — the Phase-2
emit-then-prune is deleted) and classify in `semanticRole` as
`.generic`/`.container`, never `.control`. The old `.control` classification was
purely an artifact of the focus-coupling this work removes. (`semanticRole` is
descriptive-only — read solely by a debug snapshot — so the relabel carries no
geometry cost; that was the key finding that made the abstraction free to fix.)

**`.sealed` = block descent, not a target (S2).** A sealed `Panel` sets
`isCommandHost` (no region) + `sealsFocusDescendants` (blocks descent), so a
sealed subtree yields zero focus targets — the SwiftUI-pure reading.

**Active/visible context = unambiguous single chain (M2).**
`SemanticExtractor.resolveActiveCommandScopePath` returns the deepest host chain
**iff** every visible host lies on that one nested chain (totally ordered by
nesting); divergent multi-pane hosts are ambiguous and resolve to empty, so a key
command fires nothing without focus and the app sets focus to disambiguate. A
single host — or a straight nested stack — always resolves, so the bare
command-host case keeps working.

**Decisions settled (open questions from Part 4 / "Open questions"):**
- Host scope: `Panel` + `NavigationStack` + `NavigationDestination` are pure
  hosts; modal/presentation surfaces keep their focusable-when-empty fallback (so
  an empty modal still traps focus) — left untouched this pass.
- `.sealed`: blocks descent and is never a target (S2).
- Multi-active-context: SwiftUI-faithful focus-or-nothing (M2) — ambiguous
  multi-pane fires nothing without focus.

Tests: `PanelTests` sealed assertions now expect zero regions; new tests assert a
`Panel` is never `.control` and that active context resolves only for an
unambiguous host chain. Verified under **AddressSanitizer** across the
focus/Panel/Nav/Toolbar/Presentation/FocusTracker suites plus SwiftUISurface
(197), AppRuntime, AsyncFrameTail, Phase4Observation, and the pointer/interaction
suites — all green; `SwiftTUIRuntime` cross-compiles for `wasm32-wasi`. The two
ASan crashers remain the pre-existing `#12` deep-render suites.

**Remaining:** a known narrow follow-up — the codebase overloads the
`focusRegions` list to also answer "what scope is under this pointer?" (spatial
drop dispatch reads `focusRegions`), so a *spatial* drop onto a *bare* host (no
focusable child) loses its hit rect; the correct fix is a separate "scope region"
list.

## Phase 3 status — slice 1 (implemented 2026-06-30, swift-tui `620224d6`)

Single-pass focus-sync convergence, gated by `SWIFTTUI_SINGLE_PASS_FOCUS`, **default
off** (`SinglePassFocusConvergenceConfiguration`; same `FeatureGate` pattern as
`ReaderAttributionConfiguration`). Proven at parity before the default flips.

Mechanism (gate on): `processFocusSyncIteration` stops looping and splits the work
by node kind, with **no budget**:

- **Focus location** (focus moved / a focus request or default focus applied / a
  `@FocusState` flip / scroll-to-reveal / initial auto-adoption) is not a feedback
  edge and cannot oscillate, so it applies **eagerly** with exactly one extra
  render — the committed frame shows correct focus, and `currentFocusedValues`
  (updated before that render) rides along. Capped at one pass; residual lags a
  frame. Initial auto-adoption (nil → a control), which `FocusTracker.updateRegions`
  deliberately does not flag as a change, is treated as a location establishment so
  first-presentation focused values are not stale.
- A **pure focused-value change** (the focused subtree republished without focus
  moving) is the genuine output→input feedback edge: it does not loop, it lags one
  frame via reader invalidation. Focus styling is a commit-time presentation handler
  (no re-resolve); `@FocusState` readers already self-invalidate.

Design fork settled (one-frame-lag had a visible first-presentation focus flash and
stale exit frames): split **focus location (eager, ≤1 render, no budget)** from
**focused values (lag)** rather than lag everything.

Verified under **AddressSanitizer**: 409 tests across 14 focus/runtime suites pass
identically with the gate off (no-op; legacy loop intact) and on (single-pass
parity). No hangs — termination holds without a budget. `SwiftTUIRuntime`
cross-compiles for `wasm32-wasi`.

## Phase 3 status — slice 2 (precise attribution implemented 2026-06-29, swift-tui `190b3a64`)

A pure focused-value change now invalidates **exactly** the
`@FocusedValue`/`@FocusedBinding` readers instead of the coarse whole-tree root
invalidation. `@FocusedValue`/`@FocusedBinding` read the cached
`AuthoringContext.focusedValues` field, so the read was invisible to reader
attribution; the read now records a **synthetic** `FocusedValuesDependencyKey`
env dependency on the reading node (`EnvironmentValues.recordFocusedValuesDependencyRead`).

The key is deliberately **decoupled from the value-carrying `FocusedValuesKey`** —
mirroring how `FocusedIdentityKey` is decoupled from the `_focusedIdentity`
side-field — because `ResolveContext.init` reads `environmentValues.focusedValues`
for *every* node, so attributing through `FocusedValuesKey` would mark every node a
reader (the precision test caught exactly this). Single-pass focus-sync
(`RunLoop.processFocusSyncIteration`) now invalidates
`renderer.focusedValuesDependentIdentities()` (empty ⇒ nothing reads it ⇒ nothing
to do) rather than `[rootIdentity]`.

Reuse-safe by construction: the dependency reverse-index is only rewritten in
`ViewGraph.finishEvaluation` (an actual resolve) and is untouched by reuse, so a
reader reused since its last resolve keeps its index entry and is still found (the
"reused reader records no read → stale" gap the plan flagged is closed by the
persistent index, not by an env-snapshot special-case). The change is also
**value-driven** (`focusSyncEquals`), so it catches a `@FocusedBinding` mutation
whose reflected-string snapshot is stable — no `==`-vs-`focusSyncEquals`
env-comparison special-casing was needed (the route-A refinement the plan
proposed turned out unnecessary).

Verified under **AddressSanitizer**: 412 tests across 15 focus/runtime suites
pass identically gate-off and gate-on, plus a new
`FocusedValueReaderAttributionTests` (SwiftTUIViewsTests) proving the reader is
attributed while a static sibling is spared and a reader-free tree records no
dependents. Dependency-model and reuse suites
(`DependencyModelTests`/`StateInvalidationDependencyTests`/`RetainedSubtreeReuseTests`/…)
stay green. `SwiftTUIRuntime` cross-compiles for `wasm32-wasi`.

**Remaining (Phase 3) — directed by
[`docs/plans/2026-06-30-001-focus-single-pass-slice2-plan.md`](../plans/2026-06-30-001-focus-single-pass-slice2-plan.md):**
flip the default on (`FeatureGate.singlePassFocusConvergence.defaultIsEnabled = true`)
**once gallery-proven** by-hand for real focus interactions (Tab traversal, default
focus, `@FocusedValue` toolbars, focus-dependent content), then retire the loop +
budget (`processFocusSyncIteration`'s `.rerender`/budget path,
`FocusSyncRerenderBudget`, the `RunLoop+Rendering.swift` budget assertion, and the
`FocusSyncConvergenceState` simplification). The gallery pass is the only gate left
on the flip; the precise-attribution prerequisite is done.

---

(Original proposal follows.)

## Why this exists

Investigating gallery bug #3 ("Focus Context tab: Tab does nothing; crash after
repeats") surfaced two focus-subsystem designs worth reassessing on their merits:

1. A per-frame **focus-sync convergence loop** that re-renders until focus state
   stabilises, capped by a rerender budget (Part 2).
2. **`Panel` being an unconditional focus target.** `Panel` is an `ActionScope`
   — *"a focus region that owns a set of commands"* — and is made focusable so
   its commands can activate; that makes Tab stop on containers (Part 3). This is
   the core of the reassessment.

An independent SwiftUI focus-model research pass (sources at the end) frames both
as divergences from how SwiftUI actually works.

## Part 0 — What shipped (bug #3 crash)

Dispatching a `@FocusedBinding` mutation while a `.focusedValue`-publishing field
was focused ran the convergence loop to its budget and trapped. Root cause:
`FocusedValues.==` reported a `Binding` focused value as always-changed
(non-`AnyHashable` → `false`), so the loop never reached a fixed point. Fixed
(swift-tui `61bf4e0d`) by comparing a focused binding by its **current value**
(`MainActorFocusedValueEquatable`) — a binding has no stable cross-render identity.
The loop now converges in ≤2 passes. This is a surgical fix; the loop itself is
reassessed in Part 2.

## Part 1 — What `Panel`/`ActionScope` actually is (confirmed)

`Panel` conforms to `ActionScope`, documented as *"a tree-authored focus region
that owns a set of commands,"* with activation predicate *"this scope's identity
is on the current focus chain"* (present in the focused region's `scopePath`).
The three top-level entrypoint kinds **hoist** to the nearest enclosing
`ActionScope`:

- **Toolbar** — `.toolbarItem` contributions hoist via `ToolbarItemsPreferenceKey`
  to the nearest ancestor `ActionScope` with `.toolbar(style:)`, which absorbs and
  renders a toolbar strip. *(Absorbed at resolve — already visibility-based.)*
- **Command palette** — `.paletteCommand` contributions accumulate via
  `PaletteCommandsPreferenceKey`, absorbed by `.paletteSheet(...)` at the nearest
  `ActionScope`. *(Absorbed at resolve / shown on state — already
  visibility/state-based.)*
- **Key commands** — `CommandRegistry` keys registrations by scope identity
  (`keyCommandsByScope`) and `dispatch(key:along: scopePath)` walks the **focused
  region's `scopePath`** shallowest-first, firing the first claiming scope.
  *(Focus-coupled.)*

So a `Panel` is a **view-controller-shaped responder/host**: it gathers top-level
entrypoints from its subtree and surfaces them at top-level regions. This is a
faithful analogue to SwiftUI/AppKit, where a view controller (or a SwiftUI scene
via `.toolbar`/`.commands`) hosts chrome hoisted into a **system-controlled
region** (navigation bar, window toolbar, menu bar).

### The naive coupling

SwiftUI keeps two concerns **separate** that this framework fused:

1. **Hoisting + activation** of chrome/commands — in SwiftUI driven by the
   responder chain / focused **values** rising from the focused *leaf*, and by
   which scene/navigation context is **active/visible** — never by making the
   hosting container itself focusable.
2. **Focus targeting** — lands only on focusable **leaves**; a container is never
   a Tab stop.

This framework implemented activation as *"scope identity on the focused region's
`scopePath`."* That requires *something on the chain* to carry the scope. With a
focusable descendant, focusing it carries the scope (fine). To make a region with
**no focusable descendant** (e.g. a key-command-only region) still activate, the
design made **the `Panel` itself a focus target** (`isFocusable = true`, "focused
first"). That single decision pollutes **focus traversal** — Tab stops on
containers (bug #3 facet 1) — to solve a **command-activation** problem.

### Why there is no surgical fix

`Panel`/`ActionScope` is **overloaded across two roles**:

- A **hosting region** (the Focus Context tab's `Panel`) that *should* be
  transparent to Tab.
- A **focusable item** — **List rows are also `ActionScope`/Panels** and *should*
  be Tab targets (you focus a row to activate it).

A prototype rule "a `Panel` with a focusable descendant is not a target" fixed the
Focus Context tab but broke `KeyCommandDispatchTests` (it dropped focusable List
rows — verified). The same primitive does two incompatible jobs, so the fix must
be a **design split**, not a heuristic.

## Part 2 — Issue 1: the focus-sync convergence loop

### Today

`RunLoop.renderPendingFrames(Async)` runs a per-frame loop: render →
`processFocusSyncIteration` (compare rendered focus regions / focused values /
scroll state to runtime state) → if changed, **re-render** — until a fixed point
or a `FocusSyncRerenderBudget` is exhausted, then `assertionFailure`. It exists
because focus / `currentFocusedValues` are computed *after* a render while readers
read them at the *start* of a render — a one-render lag the loop reconciles.

### Why it is fragile (research)

SwiftUI does not reconverge focus by re-rendering. Focus, focus location, and each
focused-value key are nodes in one acyclic dependency graph; a change marks
dependents dirty and re-evaluates them **once** per event — terminating with **no
budget**. `FocusedValueKey` requires only `associatedtype Value` (no `Equatable`);
propagation is structural, never gated on payload equality, and a `Binding` is
never compared by identity. A budget is the tell that focus isn't modeled as a
dependency.

### Target

Single-pass dependency-graph invalidation for focus + focused values: focus
location is one node; each focused-value key is a derived node (inputs: focus
location + value published by the focused subtree); readers are out-edges; a
change schedules one update; equality is only a pruning optimization. No loop, no
budget. Large; separate effort. The shipped equality fix holds the line.

## Part 3 — Issue 2 (primary): decouple hosting from focus targeting

### Two roles, made explicit

**Role A — Command/chrome-hosting region** (the view-controller analogue).
- Hoists toolbar / palette / key commands to top-level regions.
- Is **not** a focus target. Tab passes through it to its focusable descendants.
- Activation = the region is part of the **active/visible context** (chosen
  model), independent of focus.

**Role B — Focusable item / target.**
- Leaves (controls, text fields) and intentional items (List rows, selectable
  cells). These are the **only** Tab landing targets, in reading order.
- An item may *also* own commands (a List row can have a context key command),
  but it earns its focusability as an item, not as a host.

### Activation model: active/visible context (chosen)

Replace "scope on the focused region's `scopePath`" with "scope in the
**active/visible context**":

- **Toolbar / palette** already absorb at their scope during resolve, so they are
  effectively visibility-based already; formalize that (a hosting region's chrome
  renders when the region is in the active/visible tree).
- **Key-command dispatch** changes from *"walk the focused region's
  `scopePath`"* to *"walk the active-context scope chain"*:
  - Define the **active-context scope chain** = the path of in-scope hosting
    regions from the root to the deepest visible content (e.g. through the active
    `TabView` tab's body, the visible `Panel`s), derived from the rendered tree —
    not from focus.
  - When focus exists, the focused region's `scopePath` is a **refinement** that
    extends the active-context chain (so a focused control's ancestor scopes still
    win shallowest-first). When focus is absent, dispatch still resolves against
    the active-context chain — so a key-command-only region works **without being
    focusable**.
  - Shallowest-wins semantics are preserved over the active-context chain.

This is the SwiftUI parallel: a scene's toolbar/commands are active because the
scene is the active context, gated further by focused values — never by focusing
a container.

### Focus traversal change

In semantic extraction (`Semantics.swift`), **hosting regions do not emit a focus
region**; **items do**. Concretely:

- A hosting region (Role A) is a focus **scope** (keeps `focusScopeBoundary` so
  commands/focused-values resolve along the chain) but is **not** `isFocusable`.
- An item (Role B) is `isFocusable` (and may also be a scope).
- `FocusTracker` is unchanged — it already traverses the emitted focus regions;
  with hosting regions absent, Tab lands on the first item leaf (fixes facet 1).

### API surface

The crux is letting authors (and the framework's own List/row code) declare which
role a scope plays. Options (to settle during fleshing-out):

- **(Recommended) Make `Panel` a Role-A hosting region by default** (scope +
  hoist, not focusable), and give intentional items a distinct affordance:
  - List rows / selectable cells adopt an internal **focusable-item** role
    (they already are `ActionScope`s; add focus-target-ness there, not on `Panel`).
  - A consumer who wants a focusable container opts in explicitly (a
    `.focusable()`-style modifier), matching SwiftUI.
- Reinterpret `FocusContainment`:
  - `.open` → Role A hosting region (transparent to Tab). *(Default.)*
  - `.sealed` → unchanged in spirit (focus does not enter; the region is the
    boundary) — but it should be a **deliberate** focus target only if it has no
    inner item, otherwise it simply blocks descent.
- `ActionScope` doc updates: activation predicate becomes "in the active/visible
  context," not "on the focus chain."
- `CommandRegistry.dispatch` gains an active-context scope chain input (or the
  `RunLoop` supplies the active-context chain instead of `currentFocusScopePath()`
  when no focus is present).

### What stays the same

- Toolbar/palette hoisting via preference keys (already visibility-based).
- `FocusTracker` traversal mechanics, modal scope handling, sealed suppression.
- The shipped focused-value equality fix.

## Part 4 — Migration & affected tests (the spec)

| Call site / test | Today | After |
| --- | --- | --- |
| Gallery `FocusContextTab` `Panel` | focused first; Tab stops on it | Role A region; Tab → first `TextField` (facet 1 fixed) |
| `FocusContextRuntimeTests.…ReachesFirstEditableField` | `withKnownIssue` (lands on Panel) | passes (lands on field); remove the wrapper |
| List rows (`KeyCommandDispatchTests` route fixtures) | focusable `ActionScope` | Role B item — **stays focusable** (must not regress) |
| `KeyCommandDispatchTests.…BarePanel` (no focusable child) | command fires because the Panel is focused | command fires because the region is in the active/visible context — **focus no longer required**; update the test's focus-set step |
| `KeyCommandDispatchTests.ctrlSOnFocusInsideAPanel…` | fires via focus chain | fires via active-context chain (descendant focused) — unchanged result |
| `PanelTests."Panel is focusable"` | asserts `isFocusable == true` | reinterpret: a Role-A `Panel` is a scope but not a focus target; assert the new contract |
| `DropDestinationDispatchTests` | "Panels appear first in focus order" | focus order changes (no Panel stops); update expectations |
| `ToolbarTests` (scope-path inheritance) | scope path drives toolbar visibility | unchanged (visibility-based already); re-verify |
| `FocusTransitionTests` | Tab/Shift-Tab across controls | re-verify order with containers removed from the target set |

Risk: focus **order** changes wherever Panels nested around controls — broad but
mechanical. The activation re-basing (focus-chain → active-context) is the higher-
risk change; it must preserve shallowest-wins and the disabled-consumes-event
semantics, and define the active-context chain unambiguously for nested tabs,
overlays/modals, and split/multi-region layouts (open question below).

## Part 5 — Phasing

1. **Focus-target decoupling** (Role A regions stop emitting focus regions; items
   keep theirs). Fixes facet 1. Needs the Role A/B distinction (API surface above)
   and the List-row item role. Medium; many test updates.
2. **Activation re-basing** (key-command dispatch: focus chain → active-context
   chain; define the chain). Enables removing Panel focusability for the bare
   command-host case without losing command activation. Medium/high.
3. **Convergence loop → dependency graph** (Part 2). Large; independent.

## Open questions

- The precise definition of "active/visible context" for: nested `TabView`s
  (active tab only), modal overlays (the modal scope), and any future split/
  multi-pane layout (multiple simultaneously-active regions → multiple active
  chains?).
- Whether `.sealed` should remain a focus target or simply block descent.
- The exact item-role affordance (internal-only for List rows + a public
  `.focusable()` opt-in, vs. a richer focus-role API).
- Interaction with `@FocusState`/`@FocusedValue` once focus targets are leaves
  only (should be cleaner — readers attach to the focused leaf's chain).

## Sources

Independent SwiftUI focus research (WWDC + reverse-engineering):
- Demystify SwiftUI (WWDC21 10022); Direct and reflect focus (WWDC21 10023); The
  SwiftUI cookbook for focus (WWDC23 10162).
- Rens Breur, "Untangling the AttributeGraph" (acyclic graph; terminates without a
  budget).
- Apple docs: `FocusedValueKey`/`FocusedValues` require only `associatedtype
  Value` (no `Equatable`).
- "AttributeGraph: cycle detected" — SwiftUI treats focus dependency cycles as
  bugs, not something to iterate over.
