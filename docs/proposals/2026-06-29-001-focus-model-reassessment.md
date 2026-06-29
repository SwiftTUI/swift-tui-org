# Focus Model Reassessment & Redesign Plan

Date: 2026-06-29
Status: Proposal — design + plan. **Phase 1 and Phase 2 implemented** (focus-target
decoupling, then pure active/visible-context activation; see Part 3 / the phase
status sections below). The crash fix (Part 0), Phase 1, and Phase 2 are shipped.
Phase 3 (convergence loop → dependency graph) remains.

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

Remaining for the full redesign (beyond this proposal's Phase 2): replace the
`.view("Panel")` host marker with an explicit focus-role on `ActionScope`; settle
the `.sealed` semantics and the multi-active-context open question (nested
TabViews / modals / split panes); Phase 3 (convergence loop → dependency graph).

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
