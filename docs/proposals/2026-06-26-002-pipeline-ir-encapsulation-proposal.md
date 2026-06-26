# Proposal: Pipeline-IR Encapsulation — a public-API boundary for the engine's phase products

| | |
|---|---|
| **Date** | 2026-06-26 |
| **Status** | Proposed (not started) — decision required |
| **Type** | Public-API design change to `swift-tui` (framework) |
| **Supersedes** | The "retag the IR `public → package`" opportunity (#4) in [`2026-06-26-001-architecture-fragility-improvements-proposal.md`](2026-06-26-001-architecture-fragility-improvements-proposal.md), which an implementation attempt re-estimated from *M/mechanical* to *XL/public-API redesign*. |
| **Evidence base** | The [architecture-fragility survey](../reports/2026-06-26-architecture-fragility-survey.md) (modularity lens) + a ~14-build-cycle implementation spike (2026-06-26) summarized in the [Appendix](#appendix-the-implementation-spike). |
| **Affects** | `SwiftTUICore` (the engine IR) and `SwiftTUIViews` (the public authoring surface). No host/Charts impact. |

## Summary

SwiftTUI's seven-phase render pipeline — `resolve → measure → place → semantics → draw → raster → commit` — produces value types (`ResolvedNode`, `MeasuredNode`, `PlacedNode`, `CommitPlan`, the draw tree, …). Roughly **116 of these engine-internal IR types are declared `public`**, and the survey flagged this as the framework freezing its own internal representation as library ABI: every planned god-object decomposition (`ViewGraph`, `AnimationController`, the `Rasterizer`) is a potential source-breaking change for anyone who did `import SwiftTUI`.

The obvious fix — retag the IR `package` — was attempted and **does not work as a mechanical retag**, because the IR is not cleanly internal: it is **woven into the public `SwiftTUIViews` authoring surface** (the View modifiers, gestures, focus, and primitives that users actually call), at **~701 reference sites across 17 files**. Retagging the IR therefore *breaks user code* unless that authoring surface is first redesigned to stop exposing it.

So the real question is not "retag or not" but **"is the pipeline IR part of SwiftTUI's intended public API, or engine internals that leaked into the authoring surface?"** This proposal frames that decision, recommends **encapsulation (treat the IR as internal)**, and specifies the work — explicitly tied to the Wave C god-object refactors it exists to de-risk.

## The core question

> Are `ResolvedNode` / `MeasuredNode` / `PlacedNode` / `CommitPlan` and the rest of the phase IR **public API** (a contract users depend on) or **engine internals** (an implementation detail)?

The analogy is decisive. SwiftUI — the framework SwiftTUI mirrors — does **not** expose its resolved view tree, layout results, or display list. Users compose `View`s and read `GeometryProxy`/environment/layout *proposals*; they never touch the engine's resolved nodes. By that standard, SwiftTUI's IR should be **internal**, and its current `public` status is **accidental** — a consequence of building the authoring surface directly on the IR types rather than on narrower public abstractions.

The implementation spike confirms the accident: the IR leaks to users through exactly the places where the authoring layer reaches into the engine (custom layout, gesture/pointer routing, focus values, lifecycle, semantics/accessibility, primitive lowering), not through a designed "here is our public IR" surface.

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

### Option A — Encapsulate the IR *(recommended)*

Treat the pipeline IR as engine internals. Introduce/round-out the **narrow public abstractions** the authoring surface actually needs (geometry proposals, environment access, semantic *roles*, gesture/pointer value types, namespace tokens — most already exist in `Geometry`/`Styling`/`Content`/`Semantics`), refactor the ~17 View files to express their public API in those terms, then retag the IR `package`.

- **Pro:** Frees the engine to be refactored (Wave C: `ViewGraph`/`AnimationController`/`Rasterizer` decompositions) without breaking users; shrinks the public surface to an intentional contract; matches SwiftUI's encapsulation.
- **Con:** XL, multi-day; consumer-breaking for anyone currently reaching into the IR (mitigated below); requires designing the public authoring abstractions, not just moving keywords.

### Option B — Ratify the IR as public API *(close #4 as won't-fix)*

Accept that the IR is part of the contract (it already is, de facto), document and stabilize it, and **drop the goal of packaging it**.

- **Pro:** Zero work now; honest about today's reality.
- **Con:** Permanently **freezes the IR as ABI** — the exact constraint #4 set out to remove. Every Wave C god-object decomposition that changes `ResolvedNode`/`ViewNode`/`PlacedNode` shape becomes a breaking change. This forecloses the engine's evolvability, so it is **not recommended** unless the team decides the IR is a deliberate power-user surface.

### Option C — Phase 0: package only the deep internals that never reach Views

A cheap, safe down payment: package the engine types that are exposed by *neither* the View surface *nor* the host/consumer set (e.g. dependency-tracking, the layout work-stacks, structural-diff, measurement caches, commit-planner internals). These retag with no Layer-2 cascade.

- **Pro:** Real (if modest) surface reduction, low risk, no API break, lands today.
- **Con:** Leaves the headline products (`ResolvedNode`/`PlacedNode`/…) public — so it does **not** by itself de-risk Wave C. A genuine increment, not a substitute for A.

## Recommendation

**Pursue Option A, but sequence it with Wave C — not before.** The payoff of encapsulation is *latent*: it exists to make the god-object decompositions non-breaking, and those are deferred. Doing a multi-day consumer-API redesign now, ahead of the refactors it protects, is premature. Concretely:

1. **Now (optional):** land **Option C** (deep-internal packaging) as a low-risk surface trim, *if* a clean subset is worth a PR.
2. **When Wave C is scheduled:** do **Option A** as its **first step** — design the public authoring abstractions and de-expose the IR — so the subsequent `ViewGraph`/`AnimationController`/`Rasterizer` decompositions land behind a stable public API.
3. **Explicitly reject Option B** unless the team consciously decides the IR is a supported power-user surface (in which case document and version it).

## If Option A: the plan

**Phasing (each phase builds + gates green independently):**

1. **Define the boundary.** Enumerate, per the Layer-1 table, the keep-public consumer/host set; everything else in `resolve/measure/place/semantics/draw/raster/commit` is a packaging candidate.
2. **Round out the public authoring abstractions.** For each of the 17 View files, identify what its public API *actually* needs to expose and ensure a public, IR-free type carries it (extend `Geometry`/`Styling`/`Semantics`-role types as needed). This is the design core of the work.
3. **Refactor the View surface** file-by-file to use those abstractions (or `@_spi(Engine)` where a power-user hook is genuinely intended) instead of raw IR.
4. **Retag the IR `package`** (the proven `perl` retag, skipping `@_spi`).
5. **Regenerate the public-API baseline**, review the removed-symbols diff, gate.

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
| **Effort** | XL (multi-day) — dominated by Phase 2 (designing the public authoring abstractions) and Phase 3 (17-file refactor), not the mechanical retag. |
| **Risk** | Medium-high *as an API change* (consumer-breaking), but **low as an engineering risk** (compiler-guaranteed, baseline-reviewed). |
| **Blocks** | Nothing today. **Unblocks** non-breaking Wave C decompositions (`#9` `AnimationController`, `#10` `ViewGraph`). |
| **Do it when** | Wave C is scheduled — as its first step. |

## Appendix: the implementation spike

A 2026-06-26 spike attempted the bulk retag against the compiler across ~14 configurations:

- `Resolve` only → 705 errors (the chained component: `Commit` etc. expose `ResolvedNode`).
- All 9 pipeline subdirs → 532; then 246 (5 pure-IR subdirs) and 384 (all-9 minus `Animation`/`@_spi`) while bisecting the keep-public set.
- Converged the **in-Core** cascade to **16** by keeping the Layer-1 consumer/host set public.
- Reverting `Scheduler.swift`/packaging its internals repeatedly produced **1646** errors — the module-emit phantom cascade (root-caused to a handful of real Core errors).
- Final clean-Core build surfaced the **~701-site, 17-file `SwiftTUIViews`** exposure — the decisive finding.

All changes were reverted; **no partial boundary was shipped** (working tree clean, build green).
