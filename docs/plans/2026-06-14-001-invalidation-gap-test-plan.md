# SwiftTUI Invalidation Gap Test Plan

- **Date:** 2026-06-14
- **Status:** Proposed. Test-first plan; no behavior change is included here.
- **Input report:** [../reports/2026-06-13-swifttui-invalidation-gap-analysis.md](../reports/2026-06-13-swifttui-invalidation-gap-analysis.md)
- **Scope:** `swift-tui` package tests, plus org-root gates that exercise the
  pinned `swift-tui` checkout.

## 1. Purpose

The invalidation gap analysis recommends: "Add focused gap tests before behavior
changes." This plan turns that sentence into an implementation checklist.

The goal is not to make SwiftTUI more SwiftUI-like yet. The goal is to make the
current behavior explicit enough that later changes to state reader elision,
observable fan-out, frontier narrowing, retained reuse, or transaction semantics
cannot silently trade correctness for performance.

This plan should land as tests before any implementation PR that changes:

- `@State` reader attribution or no-reader fallback,
- `@Binding` projection/read attribution,
- `@Bindable` or observable environment dependency recording,
- `ObservationBridge` draft/commit/discard behavior,
- dirty-frontier planning or root-evaluation fallbacks,
- retained subtree reuse under ancestor/root invalidation,
- transaction snapshots or scheduler coalescing semantics.

## 2. Hard coverage rule

Tests in `swift-tui-examples` are **not acceptance coverage** for this work.

Example apps are useful smoke targets after framework behavior changes, but this
plan's gates must live in `swift-tui` itself:

- `swift-tui/Tests/SwiftTUIViewsTests`
- `swift-tui/Tests/SwiftTUICoreTests`
- `swift-tui/Tests/SwiftTUITests`
- `swift-tui/Tests/SwiftTUIProfilingTests`, only when the gap is explicitly about
  retained occupancy or profiling support

Root Bazel gates may orchestrate those child tests, but no requirement in this
plan is satisfied by adding or updating only `swift-tui-examples` tests.

## 3. Current evidence

The current implementation already has meaningful coverage:

- `ReaderAttributionTests` proves projection-only owners are spared in
  reader-attributed mode and that writes invalidate the genuine reader rather
  than the projecting owner.
- `DependencyTrackingTests` proves state, environment, and observable-backed
  reads populate graph dependencies.
- `ViewGraphTests` prove dependency reindexing and object-token observation
  fan-out behavior.
- runtime and phase tests cover focus, presentation, frame dropping, retained
  reuse, animation, and environment behavior in scattered suites.

The missing piece is an adversarial matrix that says which behaviors are
intentional current limits, which are safety invariants, and which are expected
to flip only after a deliberate behavior-change plan.

## 4. Test taxonomy

Use three labels in test names or comments:

- **Invariant:** behavior that should remain true across all future designs.
- **Characterization:** current behavior that documents a gap and may be changed
  later only by updating the test and the associated plan/report.
- **Regression guard:** a previously fixed behavior that must not regress while
  adjacent gaps are addressed.

Do not commit permanently failing tests. If a future behavior needs a red test,
keep it on the implementation branch or use Swift Testing known-issue support
only if the project already accepts known-issue tests in normal gates.

## 5. Work package A: `@State` no-reader and conditional-reader coverage

**Owner suite:** `swift-tui/Tests/SwiftTUIViewsTests/ReaderAttributionTests.swift`

**Why:** The report's G2 says SwiftTUI still falls back to owner invalidation when
a state slot has no recorded readers. That is a defensive current behavior. Any
future no-reader elision needs tests that distinguish "truly unread" from
"reader not established yet."

### A1. Characterize no-reader fallback

Add a probe that owns `@State`, never reads `wrappedValue`, and does not project a
binding to a reader. Resolve the view, locate the slot owner, write the slot, and
assert the current invalidation request includes the owner identity.

Expected now: owner invalidates.

This is a characterization test, not the future target. It should be renamed or
updated when a later design introduces an explicit unknown/no-reader state.

### A2. Preserve projection-only owner elision

Extend the existing projection tests with an additional shape where the projected
binding is passed through at least one wrapper layer before the final reader.

Expected now and future: the owner that only projects `$state` is not recorded as
a state-slot dependent when reader attribution is enabled; the final reader is.

This protects the most valuable already-shipped reader-attribution behavior.

### A3. Conditional reader appears after first pass

Add a probe:

- parent owns `@State var value`,
- parent owns `@State var showReader`,
- body only reads `value` inside `if showReader`,
- first resolve has `showReader == false`,
- mutate `showReader` so the reader branch appears,
- resolve again,
- assert the value slot now has a recorded dependent for the conditional reader.

Expected now and future: once a branch reads the value, future writes to that
slot target the reader, not the original no-reader fallback path.

This is the first guard against an unsafe "drop writes when no readers were seen"
implementation.

### A4. Hidden conditional reader remains protected

Using the same shape as A3, write the unread `value` while `showReader == false`.

Expected now: owner invalidates.

Future no-reader elision must decide whether this remains the behavior or whether
the system has enough proof to elide. Until that design exists, the test should
pin the current conservative fallback.

### A5. Binding reader after deferred builder

Add a deferred-content probe that passes `$state` through a builder or closure
before a descendant reads it. The exact fixture should use existing production
deferred-content primitives, not an example app.

Expected now and future: the read is attributed to the descendant evaluation
context, not to the projecting owner or the builder capture site.

This is important because prior state-owner recovery work showed deferred content
can lose the live owner if authoring and graph contexts drift.

## 6. Work package B: `@Binding` plumbing coverage

**Owner suite:** `swift-tui/Tests/SwiftTUIViewsTests/ReaderAttributionTests.swift`
or a new `BindingDependencyTests.swift` in `SwiftTUIViewsTests`.

**Why:** The report says SwiftTUI is strong here, but future wrapper work can
accidentally turn binding projection into a subscription-like invalidation owner.

### B1. Projection does not read

Add a direct test for the dependency set:

- owner creates `$state`,
- owner passes it to a child that stores or forwards the binding but does not
  read `wrappedValue`,
- no state-slot dependent should be recorded for that child.

Expected now and future: no dependency until the getter reaches tracked storage.

### B2. Manual closure binding has no magic tracking

Add a manually constructed `Binding(get:set:)` whose getter reads an untracked
local variable or a test box outside SwiftTUI state.

Expected now and future: resolving a view that reads the binding does not create
a `StateSlotKey` dependency unless the getter itself reaches tracked state.

This preserves the "binding is access plumbing" rule and prevents later tests
from assuming closure bindings have framework-managed precision.

### B3. Dynamic-member binding tracks the underlying source

Use `$model.someProperty` or `$state.someField` where supported by the current
API.

Expected now and future: dynamic-member binding composition does not create a new
dependency class; the dependency still belongs to the underlying state or
observable source.

## 7. Work package C: observable object-token fan-out coverage

**Owner suites:**

- `swift-tui/Tests/SwiftTUIViewsTests/DependencyTrackingTests.swift`
- `swift-tui/Tests/SwiftTUICoreTests/Graph/ViewGraphTests.swift`
- possibly a new `ObservationDependencyTests.swift` in `SwiftTUIViewsTests`

**Why:** The report's G1 is the main mismatch with SwiftUI's property-level
Observation target. SwiftTUI currently records observable graph dependencies as
`ObjectIdentifier`, not `(object, keyPath)`. Tests should make this explicit
before any attempt to narrow it.

### C1. Characterize object-token dependency keys

Extend `DependencyObservableModel` to have two properties, for example `name` and
`age`. Add two probes that read different properties through `@Bindable`.

Expected now: both dependency sets contain the same `ObjectIdentifier(model)` and
no key-path-specific graph key exists.

This documents the current graph shape.

### C2. Characterize same-object peer fan-out

Extend the existing `ViewGraphTests.observationInvalidationUsesDependencyIndices`
shape or add a sibling test:

- sibling A records a read of `model.name`,
- sibling B records a read of `model.age`,
- the graph sees both as the same object token,
- queue an observation change for A,
- assert A and B re-evaluate while an unrelated object peer does not.

Expected now: same-object peers fan out.

Future property-level graph work should update this test to the new policy, but
only after adding replacement key-path-specific tests.

### C3. Preserve unrelated-object isolation

Keep or strengthen the existing unrelated-object assertion.

Expected now and future: an observation change for object A must not dirty nodes
that only read object B.

This is an invariant, not a gap.

### C4. Computed property reads

Add a view-level test around an `@Observable` model where a computed property
reads an observed stored property.

Expected now: SwiftTUI's graph dependency still records the object token, and the
Observation bridge should fire when the backing stored property changes.

This is a compatibility guard for any key-path indexing prototype: computed
properties must be explained rather than accidentally dropped.

### C5. Collection element mutation

Add a characterization test for an observable model with a collection property
and two views reading different elements or derived values.

Expected now: object-level dependency behavior. Do not claim element-level
precision until a design can prove it.

## 8. Work package D: observable environment coverage

**Owner suite:** `swift-tui/Tests/SwiftTUIViewsTests/DependencyTrackingTests.swift`
or a new `ObservableEnvironmentDependencyTests.swift`.

**Why:** Environment-injected observable objects use the same object-token gap as
`@Bindable`, but they enter through a different API path. A key-path experiment
that only tests `@Bindable` can leave environment observables coarse.

### D1. Environment observable reads record object token

Define a test `EnvironmentKey` whose value is an `Observable & AnyObject` model.
Resolve two readers that access different properties.

Expected now: both dependency sets record `ObjectIdentifier(model)`.

### D2. Same-object environment peer fan-out

At the graph level, seed two nodes with the same environment observable token and
one with an unrelated token.

Expected now: same-object peers re-evaluate; unrelated object does not.

### D3. Environment key and observable token remain separate axes

Resolve a view that reads both the environment key itself and a property on the
observable value.

Expected now and future: the dependency set captures the environment key read
and the observable object read. Later key-path work must not collapse those two
causes into one ambiguous dependency.

## 9. Work package E: Observation draft, discard, and re-arm coverage

**Owner suites:**

- `swift-tui/Tests/SwiftTUITests/Phase4ObservationAndEnvironmentTests.swift`
- the narrowest possible `SwiftTUITests` or `SwiftTUICoreTests` suite if the
  existing phase test is not the right owner.

**Why:** `withObservationTracking` is one-shot, and SwiftTUI wraps it in a
draft/commit/discard bridge. Any change to property-level fan-out, frontier
planning, or frame cancellation must not publish stale observation callbacks.

### E1. Discarded draft callbacks do not dirty live graph

Create a test that starts an observation pass, mutates the observed model before
the pass is committed, discards the draft, and asserts the discarded callback
does not request live invalidation.

Expected now and future: stale draft callbacks are ignored.

### E2. Committed pass re-arms after change

Resolve a view that reads an observable property, commit the pass, mutate the
property, let invalidation schedule, resolve again, and mutate once more.

Expected now and future: both committed passes can observe changes. The
one-shot public Observation behavior must be hidden by SwiftTUI's per-pass
tracking.

### E3. Aborted frame restores observation registrations

Use the existing frame abort/checkpoint machinery if available in tests. The
shape should prove:

- committed observation state starts at pass N,
- pass N+1 observes a different set but is aborted,
- pass N+2 starts from the committed N registrations, not the discarded N+1 set.

Expected now and future: abort does not publish or retain discarded observation
dependencies.

This is a required guard before making observation graph keys more precise.

## 10. Work package F: dirty-frontier and root-fallback coverage

**Owner suites:**

- `swift-tui/Tests/SwiftTUICoreTests/Graph/ViewGraphTests.swift`
- a focused `FrameResolveState` or runtime frame-head test if one already exists

**Why:** The report's G4 and G5 say precision is often lost before the graph can
use its precise dependencies. Tests should separate "dirty graph can evaluate a
frontier" from "runtime frame context forces root."

### F1. Unknown invalidation identity falls back to root

If not already covered, add a graph-level test:

- seed root and known child nodes,
- invalidate an identity that is not mapped to a node,
- evaluate dirty nodes,
- assert the root evaluator is used.

Expected now: root fallback. This is a characterization of the safety backstop.

### F2. Root identity invalidation disables frontier

Seed a graph with root and disjoint children, invalidate root, and assert dirty
frontier evaluation is not used.

Expected now: root path. Future frontier work must replace this with an explicit
proof that root-level invalidation can be decomposed safely.

### F3. All-known local dirty identities use frontier

Strengthen existing tests that state/environment/observation changes use dirty
frontier when every invalidated identity is graph-local and dirty.

Expected now and future: root evaluator is not called.

This is the positive control for F1/F2.

### F4. Runtime gate matrix

Add a small runtime or `FrameResolveState` test matrix for:

- forced root evaluation,
- focus/press/proposal change,
- root identity invalidation,
- normal graph-local invalidation.

Expected now: only the normal graph-local invalidation can use selective
evaluation.

This makes future narrowing work explicit about which gate it is relaxing.

## 11. Work package G: retained reuse under ancestor invalidation

**Owner suites:**

- `swift-tui/Tests/SwiftTUICoreTests/Graph/ViewGraphTests.swift`
- retained-frame or resolve-reuse tests in `SwiftTUITests` if they already own
  `reusableSnapshot` scenarios

**Why:** G3 is the hardest parity project. Before allowing descendant reuse under
an invalidated ancestor, tests must prove current conservative behavior and the
stale-rendering hazards it prevents.

### G1. Characterize descendant reuse denial

Build a retained subtree where a descendant would otherwise be reusable. Invalidate
an ancestor identity and assert `reusableSnapshot` denies reuse for the descendant.

Expected now: reuse denied.

### G2. Disjoint sibling reuse remains allowed

In the same fixture, invalidate one branch and assert a structurally disjoint
sibling can still reuse when its environment/transaction inputs match.

Expected now and future: disjoint reuse allowed.

### G3. Captured binding hazard

Create a parent that passes a binding or closure-derived value into a descendant.
Invalidate the parent and prove reusing the descendant without re-evaluation would
be stale. This can be a regression guard that asserts the descendant is evaluated
or that reuse is denied.

Expected now and future until transitive dependency summaries exist: no reuse
that can hide changed captured values.

### G4. Transitive dependency summary placeholder

Do not implement summaries in this plan. Add comments or test helper names that
make the future proof obligation visible: reuse under ancestor invalidation can
only be allowed when the candidate subtree's transitive state, environment, and
observable dependencies are disjoint from the changed dependency keys.

## 12. Work package H: wrapper and transaction guard coverage

**Owner suites:**

- `swift-tui/Tests/SwiftTUIViewsTests`
- `swift-tui/Tests/SwiftTUICoreTests`
- runtime animation/transaction tests in `SwiftTUITests`

**Why:** G6 and G9 are not the hottest performance gaps, but they are easy places
to accidentally broaden invalidation while adding new features.

### H1. Wrapper dependency manifest

Add or update a small test manifest listing dependency-bearing wrappers and the
dependency axes they are expected to record:

- `@State` -> `StateSlotKey`
- `@Binding` -> no direct key; underlying source only
- `@Environment` -> environment key
- `EnvironmentReader` -> environment key
- `@Bindable` -> observable object token currently
- `@GestureState` -> document current axis after inspection
- `FocusState` and focus environment -> document current axis after inspection

Expected now: the manifest matches shipped behavior. New wrappers must update it.

### H2. Transaction reuse equivalence

Add a focused test around `TransactionSnapshot.isReuseEquivalent` if coverage is
not already sufficient:

- debug signature differences do not defeat reuse,
- animation request differences do defeat reuse,
- animation batch ID differences do defeat reuse.

Expected now and future until transaction semantics expand: this is the reuse
equivalence contract.

### H3. Scheduler coalescing identity set

Add a scheduler-level test that multiple invalidation requests before frame
consumption union identities into one scheduled frame and preserve animation
request/batch metadata according to current policy.

Expected now and future: frame coalescing remains deterministic while later
transaction work evolves.

## 13. Suggested implementation order

1. **Land characterization tests for current gaps.**
   - A1 no-reader owner fallback.
   - C1/C2 object-token observable dependency/fan-out.
   - D1/D2 observable environment object-token dependency/fan-out.
   - F1/F2 root fallback and root invalidation.
   - G1 ancestor invalidation denies descendant reuse.
2. **Land positive invariants that must survive all future designs.**
   - A2/A3 projection and conditional reader attribution.
   - B1/B2/B3 binding plumbing.
   - C3 unrelated-object isolation.
   - F3 all-known local dirty frontier.
   - G2 disjoint sibling reuse.
   - H2/H3 transaction and scheduler behavior.
3. **Land stale-state safety tests.**
   - A4 hidden conditional reader.
   - A5 deferred builder binding reader.
   - E1/E2/E3 observation draft/discard/re-arm.
   - G3 captured binding hazard.
4. **Only after those pass, start behavior-change plans.**
   - no-reader state elision,
   - observable key-path graph keys,
   - frontier/root narrowing,
   - ancestor reuse under dependency summaries.

## 14. Acceptance commands

Run focused package tests from the child repo or with `--package-path` from the
root. These commands intentionally do not enter `swift-tui-examples`.

```bash
swiftly run swift test --package-path swift-tui --filter ReaderAttributionTests
swiftly run swift test --package-path swift-tui --filter DependencyTrackingTests
swiftly run swift test --package-path swift-tui --filter ViewGraphTests
swiftly run swift test --package-path swift-tui --filter Observation
swiftly run swift test --package-path swift-tui --filter Transaction
swiftly run swift test --package-path swift-tui --filter Scheduler
```

Then run the org-level fast gate:

```bash
mise exec -- bazel test //:org_fast
```

If a change touches runtime frame abort, retained reuse, or scheduler behavior,
also run the relevant native gate from the root after the focused suites:

```bash
mise exec -- bazel test //:native_gates
```

`swift-tui-examples` smoke can be added after behavior changes, but it is never a
substitute for the package tests above.

## 15. Done criteria

The test-first tranche is complete when:

- all characterization tests are checked in and named as characterization tests,
- all invariants above have package-owned coverage,
- no acceptance item depends on `swift-tui-examples`,
- focused `swift-tui` test filters pass,
- `mise exec -- bazel test //:org_fast` passes,
- any behavior-changing follow-up plan can point to the exact tests it intends to
  preserve, flip, or replace.

## 16. Follow-up behavior plans unlocked by this tranche

Once this test tranche lands, it is reasonable to write separate implementation
plans for:

- no-reader `@State` elision with an explicit unknown-reader state,
- observable key-path dependency indexing or an intentional object-token policy,
- narrower root/frontier fallback behavior,
- transitive dependency summaries for ancestor-invalidation reuse,
- broader transaction semantics.

Do not combine those behavior changes with the initial gap-test tranche. The
value of this plan is that it creates a stable factual baseline before the
architecture starts moving.
