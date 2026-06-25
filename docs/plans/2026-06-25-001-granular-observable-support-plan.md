# Plan — Granular (key-path) Observable Support

- **Date:** 2026-06-25
- **Status:** **Lever A + Lever C SHIPPED** to `swift-tui` main and **enabled by
  default** (`7521ed02`, `=0` opts out) on 2026-06-25; **Lever B is a measured
  null-result** (no code). Note: the §6 phasing recommended default-OFF pending a
  soak — the default-on flip was taken directly at the owner's request, ahead of
  that soak.
  See results: [`docs/reports/2026-06-25-002-granular-observable-levers-results.md`](../reports/2026-06-25-002-granular-observable-levers-results.md).
  Measurement reframed Lever B: the clean cold/rare siblings are already reused,
  so the "structural sibling re-resolution" premise (§3, §7) is disproven — the
  union was the whole `@Bindable` cost and Lever A removes it (76→44 recompute).
  Original proposal text below preserved as the design record.
- **Owner repo:** `swift-tui-org` (coordination root). Forward-looking design
  per `AGENTS.md` → "Public vs coordination contracts." The implementation lands
  in the public child `SwiftTUI/swift-tui` (engine + `Tools/TermUIPerf`); the
  plan lives here.
- **Driving report:** [`docs/reports/2026-06-16-observable-fanout-workload.md`](../reports/2026-06-16-observable-fanout-workload.md)
- **Code baseline:** `swift-tui` @ `2126c6f4`.

> **One-line thesis.** "Granular observable support" is not one feature. The
> verified runtime mechanism splits it into three independent levers, and the
> committed perf workload measures the *wrong one*. This plan establishes that
> split, then ships the genuine observable-granularity fix (Lever A) cheaply and
> reversibly behind a flag, while correctly scoping the workload's actual cost
> (Lever B) and the large-body case as separate efforts.

---

## 1. Why this exists

The report committed a perf workload (`synthetic-observable-fanout`) to quantify
"SwiftUI-style observable key-path fan-out" so the opportunity becomes rankable.
Its framing (report §Purpose, scenario doc comment
`SyntheticObservableFanoutScenario.swift:4-18`):

> SwiftTUI records observable graph dependencies as object tokens, so a mutation
> to one property can expand from the Observation bridge's changed identity to
> every live reader of the same model object.

This plan turns that framing into an implementation plan. In doing so, **source
verification surfaced that the framing is only half-true, and not for the path
the workload exercises.** Getting the plan right required tracing the actual
dirtying mechanism end-to-end (§2). The headline correction (§3) reshapes the
whole effort, so it is stated before any design.

---

## 2. The verified mechanism (ground truth)

Every claim below was read directly from `swift-tui` @ `2126c6f4`. File:line
anchors are load-bearing — start here when implementing.

### 2.1 Two independent dirtying paths exist for observable reads

**Path 1 — per-identity precise firing (always active, all read styles).**
`ResolveContext.trackingObservableAccess` (`ResolveContext.swift:367`) wraps each
view body in `ObservationBridge.track(identity:_:)`
(`Observation.swift:50-70`), which calls the **public**
`withObservationTracking { apply() } onChange: { recordChange(identity:) }`. Swift's
Observation is **key-path precise at registration**: a sibling reading
`model.hot` and a sibling reading `model.cold` register *separate* trackings, and
a `hot` mutation fires **only** the `hot` reader's `onChange`. That `onChange`
carries **no key-path** (it is `@Sendable () -> Void`) and resolves to exactly
one `Identity` → one `ViewNodeID` via `recordChange` →
`ViewGraph.queueDirtyForObservationChange(observedBy:)` (`ViewGraph.swift:819`).

**Path 2 — object-token co-reader union (the fan-out).**
`queueDirtyForObservationChange` calls
`ViewGraphInvalidationPlanner.observationChangeDirtyNodeIDs`
(`ViewGraphInvalidationPlanning.swift:52-64`):

```swift
Set([viewNodeID]).union(
  ViewGraphDependencyIndex.observableDependents(
    triggeredBy: viewNodeID,
    nodesByNodeID: nodesByNodeID,
    observableDependents: observableDependents      // [ObjectIdentifier: Set<ViewNodeID>]
  )
)
```

`observableDependents` (`ViewGraphDependencyIndexing.swift:51-65`) reduces the
firing node's `dependencies.observableReads` over the reverse index and unions in
**every co-reader of the same object token** — *regardless of which property each
co-reader actually read.* This is the over-invalidation the report targets.

### 2.2 Only two seams populate the object-token index

`DependencySet.observableReads: Set<ObjectIdentifier>` (`DependencySet.swift:26`)
is populated by `recordObservableRead`, which is called from **exactly two**
seams (verified by `grep -rn "recordObservableRead(" Sources/`):

| Seam | Site | Key-path available at read? |
| --- | --- | --- |
| `@Bindable` subscript | `ViewBaseTypes.swift:97` | **Yes** — `keyPath: ReferenceWritableKeyPath<Model,Value>` is in scope at `:92` but **discarded**; records `ObjectIdentifier(model)` only. |
| `@Environment` observable | `Environment.swift:193` | **No** — the value is read whole before any property access. |

**A plain body read — `model.hot` written directly in a `body` — records
nothing in `observableReads`.** It is tracked solely by Path 1's
`withObservationTracking`. Therefore a plain-body firing node has an *empty*
`observableReads`, hits the `!dependencies.observableReads.isEmpty` guard
(`ViewGraphDependencyIndexing.swift:57`), and the union returns `[]`. **Plain-body
readers already dirty only themselves.**

> **Corollary (the key result):** Path 2's object-token fan-out can *only ever*
> over-invalidate `@Bindable` and `@Environment` readers. It is structurally
> incapable of touching plain-body readers.

### 2.3 Swift cannot name the changed key-path at mutation time (in our build)

A subagent compiled and ran a probe against the toolchain Observation module:
`@_spi(SwiftUI) ObservationTracking.changed: AnyKeyPath?` (macOS 15+) **exists and
is key-path precise** (registering `m.hot`, a `cold` write does not fire; the
`didSet` callback's `tracking.changed` returns `\M.hot`). **But the entire
`@_spi(SwiftUI)` Observation surface is unreachable in SwiftTUI's normal build:**
the macOS SDK ships `Observation` as *public-interface-only* (no
`.private.swiftinterface`), so `@_spi(SwiftUI) import Observation` resolves to
zero SPI symbols and `ObservationTracking` cannot be named (`error: cannot find
type 'ObservationTracking' in scope`). The `@_spi(MainActorUtilities) import
_Concurrency` precedent does **not** transfer — it is `#if os(Android)`-gated and
compiled out on macOS.

> **Hard constraint:** Any design that names the *changed* key-path at
> mutation/`onChange` time is dead on arrival. Key-path information is only
> obtainable at **read** time, and only where the seam already holds it
> (`@Bindable`; hand-rolled `ObservationRegistrar` models). This eliminates two
> whole design families up front.

### 2.4 Memo-reuse interaction (the "deaf reused node" question)

- A node with **non-empty** `observableReads` fails
  `hasNoMemoUncoveredDependencies` (`ViewNode.swift:678-684`) and is therefore
  **barred from memo-reuse** (`ViewGraph.swift:1631-1638`). So every
  `@Bindable`/`@Environment` reader always re-resolves when dirtied and re-arms
  its own `withObservationTracking`. It cannot go "deaf."
- A **plain-body** reader reports `hasNoMemoUncoveredDependencies == true`
  (empty `observableReads`) but correctness is held by the `!isDirty` co-guard
  the memo gate ANDs alongside it — see the explicit contract at
  `ViewNode.swift:640-646`. An observable mutation dirties the node (Path 1)
  before the next frame, so it is not memo-reused that frame.
- `withObservationTracking`'s `onChange` is **one-shot per mutation, not per
  frame** — it survives reuse until consumed.

> **Corollary:** The co-reader union is **not** load-bearing for correctness. It
> does not protect any node that the precise firing path + `!isDirty` co-guard
> doesn't already protect. Dropping it (for nodes whose genuine reader fires on
> Path 1) cannot introduce a missed invalidation for properties actually read in
> the last tracking pass. (The one residual — conditional/deferred reads of a
> *not-yet-taken* branch — is pre-existing and unchanged; §6.)

### 2.5 The committed workload measures structural cost, not the union

`PerfObservableFanoutCell.body` (`SyntheticObservableFanoutScenario.swift:194-203`)
reads `model.hot`/`.cold`/`.rare` as **plain body reads**. By §2.2, these
populate nothing in `observableReads` and bypass Path 2 entirely. So the report's
`52/72` recomputed cells on a hot click **cannot be object-token fan-out.** It is
**structural re-resolution**: hot cells are interspersed with cold/rare cells in
the same `HStack`/`ForEach` rows (`:160-177`, property = `(row*cols+col) % 3`),
the cells are not `Equatable` so they are ineligible for the `Equatable`-opt-in
memo-reuse path (`ViewFoundation.swift:452`, `MemoReuseConfiguration` default ON),
and re-resolving a row that contains a dirty hot cell re-resolves its clean
cold/rare siblings too.

> **This is the single most important finding for planning.** The flag that fixes
> object-token fan-out (Lever A) will move this benchmark by ≈0%, because this
> benchmark does not exercise object-token fan-out. The plan must not be sold on
> it, and must add a workload that actually bites (§5.2).

---

## 3. Reframing: three levers, not one feature

| Lever | What it fixes | Affects | Cost / risk | Demonstrated by |
| --- | --- | --- | --- | --- |
| **A. Drop the object-token union** | True observable object→property fan-out | `@Bindable` + `@Environment` readers only | Low / low (flag kill-switch) | a new `bindable-fanout` workload (§5.2) |
| **B. Structural sibling re-resolution** | Rows re-resolving clean siblings when one cell dirties | plain-body readers; all mixed-dirty containers | Medium / medium (memo machinery) | the *existing* `fanout` workload |
| **C. Key-path co-reader index** | Finer than A: one object, many `@Bindable` `.hot` readers | `@Bindable` (+ custom-registrar) only | Medium / low (additive) | a same-property `bindable-fanout` variant |
| **(large-body)** | One body reading `hot` *and* building a `cold` payload | sub-body memoization | separate effort | the `large-body` shape |

**Levers A, B, C, and large-body are orthogonal.** This plan **recommends
shipping Lever A now** (it is the genuine "granular observable" fix, and it is
cheap and reversible), **scopes Lever B as the real owner of the documented
benchmark cost** (a separate memo-reuse plan), treats **Lever C as an optional
additive follow-on gated on a measured need**, and confirms **large-body is a
sub-body memo problem** that key-path granularity cannot touch.

---

## 4. Recommended design — Lever A: drop the object-token union (flag-gated)

This is the adversarially-reviewed recommendation: build the trivial correct core
that all three researched designs share, and **do not** build the "durable re-arm
backstop" one design proposed (the critique proved it defends a hazard the union
never covered — §2.4 — and adds a fresh dropped-invalidation surface). The flag
is the only safety mechanism.

### 4.1 The change

Under a new flag, `observationChangeDirtyNodeIDs`
(`ViewGraphInvalidationPlanning.swift:52-64`) returns **`Set([viewNodeID])`**
(the precise firing node only) and **drops** `.union(observableDependents(...))`.
Mirror the existing flag branch in `stateChangeDirtyNodeIDs` (`:37-50`), which
already conditionally inserts a legacy edge under `!ReaderAttributionConfiguration.isEnabled`.

### 4.2 Why it is correct

- The firing node is **always** kept (`Set([viewNodeID])` is unconditional), so a
  genuine reader of the mutated property is never dropped — it fired *because* it
  read that property (Path 1, §2.1).
- The union's *only* effect today is dirtying co-readers of **other** properties
  of the same object (`@Bindable`/`@Environment` only, §2.2). Removing it is the
  intended win, not a regression.
- `@Bindable`/`@Environment` readers cannot be memo-reused (§2.4), so they always
  re-resolve and re-arm; they cannot go deaf.
- No Apple-only SPI is touched (§2.3) — pure planner logic over the public
  `withObservationTracking onChange`, so it is identical across all five hosts.

### 4.3 Code changes

1. **New flag** `Sources/SwiftTUICore/Resolve/PreciseObservationFiringConfiguration.swift`
   — a structural clone of `ReaderAttributionConfiguration.swift:33-59` /
   `MemoReuseConfiguration.swift:24-44`: `@MainActor package enum`,
   `environmentVariableName = "SWIFTTUI_PRECISE_OBSERVATION_FIRING"`,
   `static var isEnabled = environmentDefault()` via the WASI-safe libc `getenv`
   shim (`#if canImport(Darwin)/Glibc/Android/Musl/WASILibc`), test-settable.
   **Default OFF** through Phase 3 (unlike `ReaderAttribution`, which is ON —
   this narrowing is new and the conditional-read residual is unproven).
2. **Gate** `observationChangeDirtyNodeIDs`
   (`ViewGraphInvalidationPlanning.swift:52`): when `isEnabled`, return
   `Set([viewNodeID])`; when not, the verbatim current union. One consult point,
   one branch — instant rollback.
3. **Run-loop seeding**: read `PreciseObservationFiringConfiguration.isEnabled`
   from the environment before the first render, alongside the existing reads of
   `ReaderAttributionConfiguration.isEnabled` (`RunLoop+EventDispatch.swift:93`,
   `RunLoop+PostCommitSupport.swift:95`).
4. **No data-model change.** `DependencySet.observableReads` stays
   `Set<ObjectIdentifier>`. No read site changes. No key-path capture. This is
   deliberately the smallest correct change.

### 4.4 What Lever A does **not** do (honest non-goals)

- Plain-body `model.property` reads: **no change** — they already fire precisely
  (§2.2). Lever A is invisible to them.
- `@Environment` observable reads: stay object-granular *by construction* (no
  key-path at the seam, §2.2). A `@Environment`-injected observable mutation
  still invalidates all environment co-readers of that object. (Lever A removes
  the *cross-property* union among `@Environment` readers only insofar as the
  firing node is precise; the seam itself records no property, so a write the
  bridge attributes to a `@Environment` reader still resolves just that node.)
- The documented `fanout` benchmark: ≈0% movement (§2.5).
- The `large-body` shape: no change (separate effort, §7).

---

## 5. Workload + measurement

### 5.1 Re-anchor the perf claim (mandatory first step)

Do **not** measure Lever A against the existing `fanout` shape. Phase 0 (§6) must
empirically confirm §2.5: instrument which nodes recompute on a hot click and
attribute them to structural re-resolution vs the union. Expected: the union
contributes 0 nodes for the plain-body scenario.

### 5.2 Add a `bindable-fanout` workload variant

Extend `SyntheticObservableFanoutScenario` with a third shape
(`TERMUI_PERF_OBSERVABLE_SHAPE=bindable-fanout`) whose cells read the model via
`@Bindable` projections (`$model.hot.wrappedValue` etc.) instead of plain body
reads, so each cell populates `observableReads` and enters Path 2's union. This
is the workload Lever A actually moves. Keep `hot`/`cold`/`rare` property
assignment identical so it is an apples-to-apples sibling of `fanout`.

### 5.3 A/B protocol

Same-session A/B with `SWIFTTUI_PRECISE_OBSERVATION_FIRING=0` vs `=1`, comparing
per-frame `resolve_ms`, `head_prepare_ms`, `resolved_computed`/`resolved_reused`,
and the recomputed-X/Y diagnostic (per report §Usage). Acceptance for Lever A:

- `bindable-fanout`: hot-click `resolved_computed` and `resolve_ms` **drop**
  (cold/rare `@Bindable` siblings no longer dirtied); settled frames unchanged.
- `fanout` (plain-body): **flat** — documented as the expected no-op, not a
  regression.
- `large-body`: flat.

Use `SWIFTTUI_REUSE_TRACE_FILE` (the productized reuse-trace) to confirm the
dirty cone shrinks from "all co-readers of the object" to "the firing node,"
analogous to the sheet-cone `890→14` narrowing recorded for state reader
attribution.

---

## 6. Phasing (de-risked; mirrors `ReaderAttributionConfiguration` rollout)

- **Phase 0 — Diagnose + instrument (no behavior change).** Empirically attribute
  the existing `fanout` recompute (§5.1). Add the `bindable-fanout` shape (§5.2).
  Capture clean baselines for all three shapes. *Exit:* a written attribution
  showing the union contributes ~0 nodes to `fanout`, and a `bindable-fanout`
  baseline where it does. This phase produces the evidence that re-anchors every
  later claim.
- **Phase 1 — Flag scaffold (inert).** Add `PreciseObservationFiringConfiguration`
  (default OFF) and gate `observationChangeDirtyNodeIDs`. Flag-off path is
  byte-for-byte the current union. Add a test pinning flag-off == current
  behavior. *Exit:* `bun run test` green; zero behavior change.
- **Phase 2 — Drop the union (flag-on behavior).** Under the flag, return
  `Set([viewNodeID])` only — **no backstop.** Add the real-contract tests (§8).
  Run them with `SWIFTTUI_MEMO_REUSE=1` explicitly to prove no reused
  `@Bindable`/`@Environment` reader goes deaf. *Exit:* contract tests green;
  deferred-read hazard test documents the residual.
- **Phase 3 — Measure.** Run §5.3 A/B. Confirm `bindable-fanout` win and
  `fanout`/`large-body` flatness. *Exit:* a measured `resolve_ms`/dirty-count
  drop on `bindable-fanout`, written up as a `docs/reports/` perf note.
- **Phase 4 — Flip default ON.** After a soak with the flag ON across the gallery
  + gif-editor examples on all five hosts with no dropped invalidations, default
  `PreciseObservationFiringConfiguration` to ON, keeping
  `SWIFTTUI_PRECISE_OBSERVATION_FIRING=0` as the documented opt-out (exactly as
  `ReaderAttributionConfiguration` is on-by-default with `=0`). Document the
  observable-granularity contract in the relevant `*.docc`.

WASI caveat: any new file touching libc (the flag's `getenv` shim) must be
WASI-safe per `swift-tui/CLAUDE.md`. Cross-build before tagging:
`swiftly run swift build --swift-sdk swift-6.3.1-RELEASE_wasm --target SwiftTUIRuntime`.

---

## 7. Lever B, Lever C, large-body — scoped follow-ons (not this ship)

- **Lever B — structural sibling re-resolution (separate plan).** The
  documented `fanout` cost (§2.5). Levers to evaluate: widening memo-reuse beyond
  the `Equatable`-opt-in gate (`ViewFoundation.swift:452`) for cheap leaf cells;
  retained-subtree reuse of clean siblings under a re-resolved row; or
  per-child reuse inside `ForEach`/`HStack` when only some children are dirty.
  This is where the `52/72` actually lives and likely the larger real-world win,
  but it is a **memo-reuse** effort, not an observable-granularity one. Owner of
  the existing perf-memo lineage should take it.
- **Lever C — additive key-path co-reader index (optional, gated on measured
  need).** Only if Phase 3 shows Lever A's object-granularity is too coarse —
  i.e. one `@Observable` object read by many `@Bindable` `.hot` readers where
  non-`.hot` `@Bindable` siblings should be spared. Then **add** (never replace)
  `observableKeyPathReads: Set<ObservableKeyPathKey>` to `DependencySet`
  (alongside the object-token `observableReads`), a parallel
  `observableKeyPathDependents` reverse index, capture `(object, keyPath)` at the
  one seam that holds it (`@Bindable`, `ViewBaseTypes.swift:97`), and narrow the
  union **only when every co-reader of the firing object is key-path-attributed**
  (else fall back to the object union — over-invalidate = safe). Behind its own
  flag (`SWIFTTUI_OBSERVABLE_KEYPATH_INVALIDATION`). **Reject the
  full-index-rewrite variant** (changing `observableReads` itself to a
  property-keyed set): it pays a type rewrite + per-read `AnyKeyPath` hashing on
  every observable read for the same narrow `@Bindable`-only win the additive
  shape gets reversibly.
- **large-body — sub-body memoization (separate plan).** One body reads `hot` and
  builds a `cold`-derived payload (`SyntheticObservableFanoutScenario.swift:206-246`).
  Key-path fan-out cannot help: the single identity reading both must re-run.
  This needs sub-body splitting / payload memoization (the
  resolve-stamp-skip / memo family), orthogonal to all of A/B/C.

---

## 8. Test plan

The existing characterization tests (`DependencyModelTests.swift:206-236`,
`:255-273`) pin **read-recording** granularity (`@Bindable` of `.name`/`.age`/
`.firstScore` all collapse to `Set([ObjectIdentifier(model)])`). **Lever A does
not change read recording** — so these tests should **stay green unchanged** and
are *not* the spec for Lever A. (They only flip if Lever C lands.) Verify this
explicitly; if Lever A somehow perturbs them, that is a signal something is
wrong.

New tests pin the **invalidation fan-out** contract (the thing Lever A actually
changes). Add to a graph/invalidation suite (e.g. alongside
`Tests/SwiftTUICoreTests/Graph/ViewGraphTests.swift`):

1. **Headline win:** two `@Bindable` siblings on one model, one reading `.hot`,
   one reading `.cold`. A `.hot` write — *under the flag* — dirties the `.hot`
   reader and **not** the `.cold` reader. *Without* the flag, both are dirtied
   (pins the current union as the baseline).
2. **No under-invalidation:** the `.hot` `@Bindable` reader **is** still dirtied
   under the flag (via its own Path-1 `onChange`, not the union).
3. **Unrelated-object isolation:** a `@Bindable` reader of a *different* model is
   never dirtied by the first model's `.hot` write (both flag states).
4. **Reuse safety:** run (1)–(3) with `MemoReuseConfiguration.isEnabled = true`
   to prove no reused reader goes deaf.
5. **Deferred/conditional-read residual:** a co-reader that reads `.hot` only on
   a branch not taken in the last tracking pass — assert current behavior and
   document it as a known flag-gated hazard (the same class the `ReaderAttribution`
   legacy owner-insert mitigates for `@State`). This is *not* introduced by Lever
   A (the object-token index already lacks an edge for an unread property), but
   the test makes the residual explicit and is the trigger for keeping the flag
   OFF until soak.
6. **Flag-off == legacy:** the Phase-1 pin that flag-off reproduces the union
   verbatim.

Gate command: `bun run test` (repo gate: shared suite + policy checks).

---

## 9. Risks, residuals, and decisions

- **(Risk) Selling the work on the wrong benchmark.** Mitigated by Phase 0
  attribution + the `bindable-fanout` workload (§5). The plan states the `fanout`
  no-op up front.
- **(Residual) Conditional/deferred reads.** Pre-existing; unchanged by Lever A;
  flag-gated until soak proves clean (§8.5).
- **(Risk) `@Environment` observable stays object-granular.** Documented non-goal
  (§4.4); the seam holds no key-path. Only Lever C + a seam change could narrow
  it, and even then only for properties read after projection.
- **(Decision) Default-ON criteria.** Flip only after a clean five-host soak on
  gallery + gif-editor (§6 Phase 4). Until then, OFF.
- **(Decision) Is Lever C wanted?** Defer; gate entry strictly on a measured
  `bindable-fanout` delta showing object-granularity is too coarse (§7).
- **(Constraint) No Apple-only SPI.** `ObservationTracking.changed` is unreachable
  in our build (§2.3); no plan step may name the changed key-path at mutation
  time.

## 10. Provenance

Mechanism and feasibility were established by a multi-agent investigation +
adversarial design critique this session; **every load-bearing claim in §2 was
re-verified directly against `swift-tui` @ `2126c6f4`** by the plan author
(`recordObservableRead` call-site count; the union `isEmpty` guard; the scenario's
plain-body reads; the memo-reuse bar on non-empty `observableReads`; the
`MemoReuseConfiguration`/`ReaderAttributionConfiguration` flag shapes). The
`@_spi(SwiftUI)` unreachability (§2.3) was verified by an agent that compiled and
ran probes against the toolchain Observation module (treated as high-confidence
but agent-sourced; re-confirm with a throwaway compile before relying on it for
any future Lever-C work that might be tempted toward SPI).
