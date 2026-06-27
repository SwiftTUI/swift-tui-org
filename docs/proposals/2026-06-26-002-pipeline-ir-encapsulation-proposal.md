# Proposal: Pipeline-IR Encapsulation — a public-API boundary for the engine's phase products

| | |
|---|---|
| **Date** | 2026-06-26 |
| **Status** | **Landed (2026-06-27).** #4 is no longer shelved: the public renderer now returns `RenderSnapshot`, raw phase products are `package`, public-surface policy guards prevent re-leaks, and the org root pins the pushed framework/examples commits. See [Implementation update](#implementation-update-2026-06-27). |
| **Type** | Public-API design change to `swift-tui` (framework) |
| **Supersedes** | The "retag the IR `public -> package`" opportunity (#4) in [`2026-06-26-001-architecture-fragility-improvements-proposal.md`](2026-06-26-001-architecture-fragility-improvements-proposal.md). |
| **Evidence base** | The [architecture-fragility survey](../reports/2026-06-26-architecture-fragility-survey.md), the ~14-build-cycle 2026-06-26 spike summarized in the [Appendix](#appendix-the-implementation-spike), and the final 2026-06-27 implementation/validation bundle. |
| **Affects** | `SwiftTUICore` phase products/engines, `SwiftTUIRuntime.DefaultRenderer`, public API baseline/policy, and example tests that previously reached into raw frame artifacts. |

## Implementation update (2026-06-27)

**#4 is landed.** The final design accepted the source-breaking risk of removing accidental phase-IR API and implemented a narrower, reviewable Option A rather than ratifying the raw engine IR:

- `DefaultRenderer.render` and `renderAsync` now return `RenderSnapshot`, a curated public value carrying `rasterSurface`, `semanticSnapshot`, `presentationDamage`, and `diagnostics`.
- `RenderSnapshot` keeps the raw `FrameArtifacts` behind a `package` initializer/property so runtime internals and package tests can still use the phase products without exposing them to consumers.
- Phase engines and phase products are now `package`: `Resolver`, `LayoutEngine`, `SemanticExtractor`, `DrawExtractor`, `Rasterizer`, `CommitPlanner`, `FrameArtifacts`, `CommitPlan`, `ResolvedNode`, `MeasuredNode`, `PlacedNode`, `DrawNode`, layout/cache/proxy helpers, and related lifecycle/commit internals.
- The intentional public boundary stays public: authored `View` APIs, geometry/style/animation value types, `RasterSurface`, `SemanticSnapshot`, `SemanticHostFrame`, `FrameDiagnostics`, and the new public `FrameDropBlocker`.
- `Scripts/check_public_surface_policies.sh`, `docs/public_api_overrides.yml`, `docs/PUBLIC_API_BASELINE.md`, and `docs/.public-api-baseline.txt` now encode the boundary so raw IR does not drift back into public API.
- `swift-tui-examples` tests now consume public snapshots/raster/semantic surfaces instead of `FrameArtifacts` or phase trees.

Pushed implementation commits:

- `swift-tui` `315fd53c` — `refactor: encapsulate render phase IR`
- `swift-tui-examples` `3d70f26` — `test: use public render snapshots`
- `swift-tui-org` `73586ee` — `chore: pin public render snapshot work`

Validation:

- `swiftly run swift test` in `swift-tui` — 2,589 tests passed.
- `Scripts/check_public_surface_policies.sh`
- `Scripts/generate_public_api_inventory.sh --check` — baseline current, 713 top-level public symbols.
- Worktree-overlay example tests: `gallery`, `layouts`, `gifcat`, `gifeditor`.
- `mise exec -- bazel test //:org_fast`

## Historical decision (2026-06-26, superseded)

The first spike re-scoped #4 from a mechanical retag to a source-breaking public-API boundary change, and the near-term hardening program did not require it. The temporary call was therefore to shelve the work. That decision was superseded on 2026-06-27 after the source-breaking risk was accepted and the smaller `RenderSnapshot` facade made the boundary tractable.

## Summary

SwiftTUI's seven-phase render pipeline — `resolve → measure → place → semantics → draw → raster → commit` — produces value types (`ResolvedNode`, `MeasuredNode`, `PlacedNode`, `CommitPlan`, the draw tree, …). At survey time, roughly **116 of these engine-internal IR types were declared `public`**, and the survey flagged this as the framework freezing its own internal representation as library ABI: every planned god-object decomposition (`ViewGraph`, `AnimationController`, the `Rasterizer`) was a potential source-breaking change for anyone who did `import SwiftTUI`.

The obvious fix — retag the IR `package` — was attempted and **does not work as a blind mechanical retag**, because the IR had leaked through parts of the public `SwiftTUIViews` authoring surface (the View modifiers, gestures, focus, and primitives that users actually call), at **~701 reference sites across 17 files** in the original spike. Retagging the IR therefore had to be treated as a public API boundary change, not a keyword sweep.

The 2026-06-27 implementation answered the core design question: **the raw pipeline IR is engine-internal, while rendered output is public.** `RenderSnapshot` is the public runtime facade; package-only accessors preserve internal testing and runtime composition; direct consumers of raw `ResolvedNode`/`PlacedNode`/`FrameArtifacts` were intentionally broken while SwiftTUI is still pre-1.0.

## The core question

> Are `ResolvedNode` / `MeasuredNode` / `PlacedNode` / `CommitPlan` and the rest of the phase IR **public API** (a contract users depend on) or **engine internals** (an implementation detail)?

The analogy is decisive. SwiftUI — the framework SwiftTUI mirrors — does **not** expose its resolved view tree, layout results, or display list. Users compose `View`s and read `GeometryProxy`/environment/layout *proposals*; they never touch the engine's resolved nodes. By that standard, SwiftTUI's IR should be **internal**, and its current `public` status is **accidental** — a consequence of building the authoring surface directly on the IR types rather than on narrower public abstractions.

The implementation spike confirmed the accident: the IR leaked to users through exactly the places where the authoring layer reaches into the engine (custom layout, gesture/pointer routing, focus values, lifecycle, semantics/accessibility, primitive lowering), not through a designed "here is our public IR" surface.

## Evidence: two exposure layers

The spike retagged the pipeline-internal `SwiftTUICore` subdirs `public → package` and drove the compiler to a fixpoint. Two distinct layers of exposure emerged.

**Layer 1 — within `SwiftTUICore` (tractable; converged 705 → 16 errors).** The seven phases are a *chained connected component*: each phase's extractor consumes the previous phase's product (`DrawExtractor.extract(_: PlacedNode)`, the rasterizer over the draw tree, etc.), so the products must be packaged together. Mixed in are types that are *legitimately* public and must stay so:

| Stays public | Why |
|---|---|
| `Animation` `Animatable*` family (`AnimatablePair`, `AnimatableArray`, …) | Users conform their values to `Animatable`. |
| `Draw` `TextStyle`, text modes, shape/list/table/canvas payloads | Reachable from the `@_spi(Testing) DrawPayload` and the public text/shape API. |
| `Raster` `RasterSurface` | Host-facing (web/Android serialize it); consumed by Charts/Platforms. |
| `Pipeline` `FrameScheduler` / `FrameScheduling` / `Invalidating` / `WakeCause` | `RunLoop`'s public construction API. |
| `Resolve` `EnvironmentSnapshot` | Shared environment representation. |
| `@_spi(Runners)` / `@_spi(Testing)` declarations | Intentional host/test exposure. |

With those kept public and the rest packaged, the **in-Core** cascade converged to 16 residual errors — i.e. Core is *internally* separable with a well-defined boundary.

**Layer 2 — across to `SwiftTUIViews` (the blocker).** Once `SwiftTUICore` emits cleanly, the build reveals **~701 errors across 17 files of the public View authoring surface**:

| File | sites | File | sites |
|---|--:|---|--:|
| `Primitives/ViewPrimitives.swift` | 231 | `Gestures/GestureModifiers.swift` | 28 |
| `Modifiers/ViewLifecycleModifiers.swift` | 52 | `Gestures/Gesture.swift` | 21 |
| `State/FocusedValue.swift` | 42 | `AccessibilityAnnouncer.swift` | 16 |
| `Modifiers/ViewMetadataModifiers.swift` | 41 | `Modifiers/ViewLayoutModifiers.swift` | 14 |
| `Environment/ResolveContext.swift` | 34 | `State/Namespace.swift` | 7 |
| `TabViews/TabViewStyles.swift` | 28 | (+ Tap/SpatialTap/LongPress/Exclusive gestures) | 7 each |

These are the **APIs users call**. Their public signatures reference pipeline IR types directly. *(A methodological note: an earlier read concluded the cascade was "contained to Core." That was an artifact — when `SwiftTUICore` fails to emit its module, every downstream module fails with phantom errors, masking Layer 2. The 701 sites only appear once Core emits cleanly.)*

## Options

These options record the pre-implementation decision space. The landed outcome is [Option A](#option-a--encapsulate-the-ir-recommended) in the narrower `RenderSnapshot` form described above.

### Option A — Encapsulate the IR *(recommended)*

Treat the pipeline IR as engine internals. Introduce/round-out the **narrow public abstractions** the authoring surface actually needs (geometry proposals, environment access, semantic *roles*, gesture/pointer value types, namespace tokens — most already exist in `Geometry`/`Styling`/`Content`/`Semantics`), refactor the ~17 View files to express their public API in those terms, then retag the IR `package`.

- **Pro:** Frees the engine to be refactored (Wave C: `ViewGraph`/`AnimationController`/`Rasterizer` decompositions) without breaking users; shrinks the public surface to an intentional contract; matches SwiftUI's encapsulation.
- **Con:** XL, multi-day; consumer-breaking for anyone currently reaching into the IR (mitigated below); requires designing the public authoring abstractions, not just moving keywords.

### Option B — Ratify the IR as public API *(rejected)*

Accept that the IR is part of the contract, document and stabilize it, and **drop the goal of packaging it**.

- **Pro:** Zero work now; honest about today's reality.
- **Con:** Permanently **freezes the IR as ABI** — the exact constraint #4 set out to remove. Every Wave C god-object decomposition that changes `ResolvedNode`/`ViewNode`/`PlacedNode` shape becomes a breaking change. This forecloses the engine's evolvability, so it is **not recommended** unless the team decides the IR is a deliberate power-user surface.

### Option C — Phase 0: package only the deep internals that never reach Views

> **⚠️ Verified non-existent at HEAD (2026-06-26).** A source-grounded audit found Option C **maps to no implementable scope**: the genuinely deep-internal types this option names (`DependencyTracker`, `DependencySet`, `StructuralDiff`, the layout work-stacks, measurement caches, commit-planner internals) are **already `package`**, not public. Every one of the ~63 *remaining* public pipeline types is transitively exposed as a public member of a Runtime-facing type — e.g. `LifecycleCommitOperation` via `CommitPlan`, `RouteKind` via `RouteID` (15 Runtime refs), `SemanticRole` via `PlacedNode` (57 refs), `CustomLayoutProxy` via `CustomLayout` (22 refs), the `FrameDiagnostic*` family via `FrameDiagnostics`. Packaging any of them either fails to compile (a `public` member cannot expose a `package` type) or is a no-op (already `package`). **There is no isolable "deep-internal subset" to trim without first redesigning the View/Runtime surfaces — which is Option A.** Option C is therefore struck: it is busywork disguised as a down-payment, not a real third choice. The text below is retained for the record.

~~A cheap, safe down payment: package the engine types that are exposed by *neither* the View surface *nor* the host/consumer set (e.g. dependency-tracking, the layout work-stacks, structural-diff, measurement caches, commit-planner internals). These retag with no Layer-2 cascade.~~

- ~~**Pro:** Real (if modest) surface reduction, low risk, no API break, lands today.~~
- ~~**Con:** Leaves the headline products (`ResolvedNode`/`PlacedNode`/…) public — so it does **not** by itself de-risk Wave C. A genuine increment, not a substitute for A.~~

## Recommendation

**Resolved: landed.** Option A was implemented in its narrowest useful form: keep user-facing authoring/render-output types public, introduce `RenderSnapshot` for rendered frame results, and move the raw phase IR to `package`. Option B (ratify the raw IR as public API) is rejected; Option C remains non-existent at HEAD.

The earlier gating correction still matters historically: #9, #10, #11, and #12 did not *need* #4 to proceed. #4 nevertheless improves public API cleanliness and future refactor freedom by ensuring runtime consumers depend on rendered output, not the engine's phase products.

## If Option A: the plan

**Phasing (implemented 2026-06-27; each phase built + gated green):**

1. **Define the boundary.** Kept authored `View` APIs, geometry/style/animation values, host-facing raster/semantic values, and diagnostics public; marked phase engines/products as packaging candidates.
2. **Add the public render facade.** Introduced `RenderSnapshot` and changed public `DefaultRenderer.render` / `renderAsync` to return it; retained package-only `renderArtifacts` paths for internals.
3. **Retag the raw IR `package`.** Moved the phase products/engines and package-only renderer plumbing behind the module boundary.
4. **Update consumers.** Migrated framework tests that need internals to package artifact paths and migrated example tests to public snapshot/raster/semantic checks.
5. **Regenerate and enforce the public API baseline.** Updated overrides, baselines, docs, and policy checks to make the boundary executable.

**Why it is safe to do (despite being consumer-breaking):**

- **Correct by construction.** The compiler *forbids* a `public` declaration from exposing a `package` type, so a clean build guarantees no consumer-reachable type was accidentally hidden. You cannot "half-hide" a type that users still need.
- **The baseline diff is the review artifact.** `docs/.public-api-baseline.txt` removes exactly the de-exposed symbols; that list is reviewed before merge to confirm each removal is intended.
- **Breaks are compile-time and enumerable**, never silent runtime drift.

**Risks / gotchas (from the spike):**

- A `SwiftTUICore` module-emit failure cascades **phantom** errors to every downstream module (observed: a single bad decl → ~1646 errors). When converging, filter to `grep Sources/SwiftTUICore` to find the *real* root, and treat large downstream counts as masked-until-Core-is-clean.
- The boundary runs *through* some files (e.g. `Pipeline/Scheduler.swift`: public `FrameScheduling`/`FrameScheduler` + `package` internal members). These need per-member, not per-file, treatment.
- `@_spi`-marked declarations must be skipped by any bulk retag (they are intentional exposure; retagging breaks `@_spi`).

## Effort, risk, sequencing

| | |
|---|---|
| **Effort** | L/XL boundary pass — smaller than the original 17-file redesign because the final public facade is `RenderSnapshot`, but still a source-breaking API change plus example/test migration. |
| **Risk** | Medium-high *as an API change* (direct raw-IR consumers break), but low as an engineering risk (compiler-guaranteed and baseline-reviewed). |
| **Blocks** | Nothing today. Landed for API cleanliness and future refactor freedom. |
| **Do it when** | Done 2026-06-27. |

## Appendix: the implementation spike

A 2026-06-26 spike attempted the bulk retag against the compiler across ~14 configurations:

- `Resolve` only → 705 errors (the chained component: `Commit` etc. expose `ResolvedNode`).
- All 9 pipeline subdirs → 532; then 246 (5 pure-IR subdirs) and 384 (all-9 minus `Animation`/`@_spi`) while bisecting the keep-public set.
- Converged the **in-Core** cascade to **16** by keeping the Layer-1 consumer/host set public.
- Reverting `Scheduler.swift`/packaging its internals repeatedly produced **1646** errors — the module-emit phantom cascade (root-caused to a handful of real Core errors).
- Final clean-Core build surfaced the **~701-site, 17-file `SwiftTUIViews`** exposure — the decisive finding.

Those spike changes were reverted; **no partial boundary shipped on 2026-06-26**. The follow-up 2026-06-27 implementation is the shipped boundary recorded above.
