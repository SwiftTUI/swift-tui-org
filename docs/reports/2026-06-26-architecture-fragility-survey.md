# SwiftTUI — Architecture & Fragility Survey

**Date:** 2026-06-26
**Scope:** The whole `SwiftTUI/swift-tui` framework (~110k LOC source, ~90k LOC tests) plus this org-coordination root.
**Method:** Multi-agent survey — 14 parallel subsystem readers → 14 adversarial fragility validators + 4 cross-cutting lenses → ranked synthesis (33 agents, ~3.5M tokens). Headline claims independently spot-verified against source by the author (see *Verification* below).
**Status:** Read-only assessment (the survey itself changed no code). **Implementation has begun** — 10 of the 15 ranked opportunities have landed; see the [proposal's Progress section](../proposals/2026-06-26-001-architecture-fragility-improvements-proposal.md#progress-2026-06-26) for the live status.

---

## 1. Verdict

SwiftTUI is a **genuinely well-engineered framework with a sound macro-architecture and one dominant, recurring fragility.**

What is strong is structural and hard to fake: a clean 3-tier module DAG (`SwiftTUICore → SwiftTUIViews → SwiftTUIRuntime`) with **no cycles**; aggressive, correct use of Swift `package` access control (~4,000 `package` declarations; the engine classes `ViewGraph`/`ViewNode` are `package`, not `public`); an unusually disciplined Swift 6 concurrency posture (**zero** `@unchecked Sendable`, **zero** `nonisolated(unsafe)` — enforced by a commit hook — with ~940 *checked* `Sendable` conformances and `Mutex`/`OSAllocatedUnfairLock` for shared state); and a team that demonstrably understands its own failure modes (invariant comments, shadow oracles, checkpoint-totality tests, a curated flake register).

The dominant weakness is **singular**: the frame pipeline layers **seven independent reconciliation fast-paths** whose correctness rests on *completeness* / *identity* assumptions that orthogonal features (ForEach/portal splices, lazy-tab/capture-host islands, async completions) routinely violate — and **the soundness oracles that catch this class are almost all `#if DEBUG`, so the bug class ships in release where the guards are compiled out.** Nearly every documented behavioral bug in this project's history (handler strands, stale capture-host reuse, foreign-stamp stamp-skip, orphaned animation completions, lazy-tab `.task` drops, `@State`-write-invalidates-owner) is *one* bug recurring at six seams.

The second structural weakness is **god-object concentration** in the most central files, where invariants live as prose and **parallel hand-maintained field lists** rather than as types.

> **The leverage is therefore not scattered cleanups.** It is (a) move the existing oracles to where release bugs live, (b) close the one concurrency escape hatch behind the only CRITICAL finding, and (c) retag over-exposed engine IR so the inevitable god-object decompositions become non-breaking — surrounded by a handful of near-zero-risk CI/test/config wins.

### Subsystem health scores (0–100)

| Score | Subsystem |
|------:|-----------|
| 58 | **Resolution & reconciliation engine (ViewGraph)** — most central, most bug-prone |
| 61 | Org coordination root (Bazel graph, submodule pinning, lockstep release) |
| 62 | Runtime registries, semantics & pointer routing (the publication seam) |
| 63 | Animation system & lifecycle |
| 63 | Run loop & terminal input |
| 63 | View library — state/focus/gestures/presentation/navigation/tabs |
| 68 | Diagnostics, configuration, accessibility, entrypoint & profiling |
| 69 | View library — layout/controls/collections/scroll/primitives |
| 70 | Multi-host platform layer (CLI / WASI / WebHost / Android / PTY) |
| 72 | Terminal host & render output |
| 73 | Layout engine (measure & place) |
| 73 | Rasterization, drawing & styling |
| 73 | Test architecture & determinism |
| 76 | Commit planning & frame pipeline |

The shape is telling: the **engine core scores lowest**, the **leaf/output stages score highest**. Risk is concentrated exactly where change is hardest and blast radius is largest.

---

## 2. Architecture at a glance

```
Authoring          SwiftTUIViews   (View, controls, layout, @State/@Environment, focus, gestures, tabs)
   │
Engine             SwiftTUICore    (the 7-phase pipeline IR + the persistent runtime graph)
   │                 resolve → measure → place → semantics → draw → raster → commit
Runtime            SwiftTUIRuntime (RunLoop, DefaultRenderer, AnimationController, TerminalHost)
   │
Hosts              Platforms/{CLI, WASI, WebHost, Android, Embedding}  via  @_spi(Runners)
```

The engine is a **retained-mode reconciler** (like SwiftUI's, not like a React VDOM): a persistent `ViewNode` graph survives across frames carrying `@State`, lifecycle, dependencies and registrations, and each frame diffs a freshly *resolved* tree against it. The layout engine is a **hand-rolled iterative work-stack VM** (not recursion). Output rasterizes to terminal cells, with image protocols (sixel/kitty/iTerm) and a web/Android host that serialize a `SemanticHostFrame` instead.

---

## 3. The fragility map — seven themes

### Theme 1 — Reconciliation-seam fragility *(the dominant bug class)*
Seven independent SKIP fast-paths — retained-subtree reuse, memoized-body reuse, runtime-ID stamp-skip, scoped registration restore, off-screen frame elision, placement `.identical` skip, retained-layout reuse — each assume a subtree is *complete* and *identity-stable*. The framework's own orthogonal features splice/portal nodes into the tree in ways that violate exactly those assumptions. **The class is structurally invited, not incidental.**

Why it keeps escaping to production:
- **Oracles live where bugs can't reproduce.** `assertResolvedStampsCoherent` (`ViewNode.swift:618`), the delta-checkpoint oracle (`ViewGraphFrameDraft.swift:361`), the memo shadow oracle (`ViewFoundation.swift:467`), and raster `verifySoundDamage` are all `#if DEBUG`/env-only. Release defaults to *trust*.
- **Completeness contracts are prose across module boundaries.** The off-screen-elision disjointness invariant is a comment in the *producer* (`Rasterizer+Paint.swift:138-153`, "must NEVER be recorded here") and another in the *consumer* (`OffscreenFrameElision.swift:13-37`) with **no assertion bridging the seam**.
- **The scoped-vs-full registration oracle covers only 2 of 15 registries** (`RuntimeRegistrationRestoreScopingTests` checks `defaultFocus` + `focusBinding` only) — precisely the gap where handler strands hid.
- **No generative test** exercises the splice/portal/lazy product space; each seam bug was caught by hand in a gallery interaction and back-filled with one targeted test.

### Theme 2 — God-object concentration with invariants-as-comments
The most central files are 2–6× the project's own 800-line ceiling: `ViewGraph` (2,501 / 111 methods), `AnimationController` (1,627), `ViewNode` (1,412), `Rasterizer` (~4,900 across 11 files), `RunLoop` (68 stored properties / ~30 files). The recurring tax is **hand-mirrored parallel field lists with no compiler enforcement**: `ViewNode`'s 4 lists (struct / `Checkpoint` / `restoreCheckpoint` / `debugTotalStateSnapshot`), `PlacedNode`'s 4 placement mirrors, the 15-registry fan-out across ~8 sites, `ResolveContext`'s hand-picked partial `==`. A field added to one list and forgotten in another silently corrupts rollback, reuse, or publication.

### Theme 3 — Concurrency is sound where the compiler enforces it, fragile at the escape hatches
The type-level discipline is excellent — which *concentrates* all real risk in the 18 `MainActor.assumeIsolated` sites. The dominant one is the **only CRITICAL finding** (Theme 7 / §4). `FrameScheduler` (`Scheduler.swift:105`) is a second-tier example: neither `@MainActor` nor `Sendable`, it locks only its wake/waiter surface and leaves the core coalescing Sets unlocked "safe by convention."

### Theme 4 — Config-flag debt: perf work shipped as permanent default-on flags
**34 distinct `SWIFTTUI_*` flags**, ~11 copy-pasted `getenv` helpers (each with its own 11-line libc `#if` block), none routed through the testable `EnvironmentResolver`. Four default-on perf gates each carry an **untested dormant legacy off-path**; three observation flags combine into a **4-way fork** whose off-combinations are essentially never tested (only 8 `isEnabled = false` assignments exist in the entire suite). Concrete decay: `PreciseObservationFiringConfiguration`'s doc says "stays off by default" while the code defaults it `true`; `StructuralDivergenceDiagnostics` (295 LOC) has zero production callers. The pattern is *easy-to-add, never-required-to-remove*, so the surface grows monotonically.

### Theme 5 — Cross-host & cross-repo duplication with no single source of truth
The same `SemanticHostFrame` is serialized by **two unrelated ~570-line encoders** (WASI hand-rolled JSON vs Android `Codable`) — a forgotten field silently drops data on one host with no compile error. At the org level: the version string is denormalized across six repos, the lockstep set is hardcoded outside `repos.json`, **there is no version-coherence gate**, and the coordination root has **zero remote CI** — org integrity rests on operator discipline.

### Theme 6 — Over-exposed engine IR freezes internal representation as library ABI
Access-control discipline is applied to the engine *classes* but not to the ~124 `public` value-type IR *products* (`ResolvedNode`, `MeasuredNode`, `PlacedNode`, `CommitPlan`, `RasterSurface`). The only extension point that would need them public (custom `PrimitiveView`s) is itself `package`, so **nothing actually needs them public.** This makes every planned god-object refactor a potential source-breaking change.

### Theme 7 — The test harness structurally cannot exercise the highest-risk paths
- The single-host gate **never compiles** `wasm32-wasi`/Android (green-ship breaks shipped at 0.0.19 and 0.0.26).
- The scripted-input `RunLoop` terminates with the input stream (`RunLoop.swift:340` `while await iterator.next() != nil`), so **autonomous `.task`/`refresh()` wake-ups** — the class behind PhaseAnimator stalls and dropped-`.task` regressions — are unobserved.
- The off-main offload path uses the immediate on-main worker in tests, so the corruption path (§4) **never runs.** The most dangerous code is the least covered.

---

## 4. Critical findings (2)

**C1 — Off-main layout offload races MainActor state through `assumeIsolated` over an unsynchronized cache.** *(verified)*
`LayoutProxyBox` (`CustomLayoutErasure.swift:289`) holds `private var cachedStates: [CacheKey: Any]` — a plain, unsynchronized dictionary — and mutates it from `nonisolated` methods inside `MainActor.assumeIsolated { … }` (e.g. `:343`). The layout pass can be dispatched off-main by `DispatchFrameTailLayoutWorker` (`FrameTailLayoutWorker.swift:78`). The *only* thing keeping this sound is `canOffloadLayout` (`FrameTailLayoutOffloadEligibility.swift`), a hand-maintained tree walk **duplicated ~5×** that must classify every MainActor-only construct. A single missed child-edge → `assumeIsolated` UB + an unsynchronized dictionary write racing the main actor → torn pointers. This is the **plausible structural mechanism for the unidentified, TSan-invisible SIGSEGV flake #1** (the boundary hides the race from the detector's happens-before model).

**C2 — Flake #1 itself is a standing misattribution hazard.** Because its mechanism is officially "unidentified," real regressions get waved off as "the known flake." Fixing C1 (make the cache genuinely `Mutex`-guarded like its sibling `SendableLayoutWorkerProxy`) converts *potential memory corruption* into *at-worst wrong cache reuse*, and adding a deterministic off-main `fatalError` gives the flake a reproducible signature.

---

## 5. Ranked opportunities

Ranked by leverage = (impact × fragility removed) ÷ (effort × risk). Effort: S < 1d · M ~days · L ~1–2wk · XL > 2wk.

| # | Opportunity | Impact | Effort | Risk |
|--:|-------------|:------:|:------:|:----:|
| 1 | **Promote reconciliation oracles to run where release bugs ship** (sampled-release + always-on-in-test) | transformational | L | low |
| 2 | **Generative property-based reconciliation harness** — assert `skip == recompute` across all 15 registries | transformational | L | low |
| 3 | **Close the off-main layout-offload escape hatch** (C1 — `Mutex`-guard `cachedStates`, deterministic off-main trap) | high | M | med |
| 4 | **Retag the 7-phase pipeline IR `public → package`** *before* any god-object refactor | high | M | low |
| 5 | **Add a root org-gate CI workflow + a WASI/Android cross-compile gate** | high | S | low |
| 6 | **One `FeatureFlags` registry** to kill the `getenv` sprawl and make flags injectable/enumerable | medium | M | low |
| 7 | **Generalize the checkpoint-totality test** to the other parallel-field-mirror families (`PlacedNode`, registries, `ResolveContext`) | medium | M | low |
| 8 | **Fix the VT220 CSI parser bug** (Delete/PageUp emit spurious Escape + literal `~`) | medium | S | low |
| 9 | **Decompose `AnimationController`**, extract a `CompletionLedger` + reusable carry-forward primitive | high | L | med |
| 10 | **Decompose `ViewGraph`** along existing method-cluster seams; group `ViewNode` fields into aggregates | high | XL | med |
| 11 | **Unify cross-host frame serialization** behind one `HostFrameProjection` DTO | medium | L | med |
| 12 | **Extract a `PointerInteractionState` machine** out of the `RunLoop` god class | medium | M | med |
| 13 | **Executable cross-repo version-coherence gate** in `release_candidate` | medium | M | low |
| 14 | **Bound the unbounded image caches**; fix the per-host metric-registration leak | medium | M | low |
| 15 | **Autonomous-wake test harness**; extract the shared input harness to `Tests/Support` | medium | L | low |

### Suggested sequencing

**Wave A — make the bug class visible & stop the corruption (do first; mostly low-risk).**
`#3` (close C1 — the one critical), then `#1` + `#2` together (the oracles need the generator's inputs to hit the seams), plus `#5` and `#8` as cheap parallel wins. After Wave A, the dominant bug class is *caught at the seam in CI* instead of *found by humans in the gallery*, and the only memory-corruption path is closed.

**Wave B — pay down debt that de-risks the big refactors (low-risk, mechanical).**
`#4` (retag IR — a prerequisite that makes everything in Wave C non-breaking), `#6`, `#7`, `#13`, `#14`, `#15`.

**Wave C — the structural bets (larger, gated on Wave B).**
`#9` (`AnimationController`), `#10` (`ViewGraph`/`ViewNode` — the foundation), `#11`, `#12`. Do `#4` before any of these.

---

## 6. Verification

The author independently confirmed the headline claims against source (not relayed on trust):

- **34 distinct `SWIFTTUI_*` flags** — `grep` over `Sources/` + `Platforms/`. ✓
- **0 `@unchecked Sendable` / 0 `nonisolated(unsafe)`** — confirmed, and confirmed *why*: the `structured-concurrency-escape-hatches` prek hook blocks them (which is exactly why risk concentrates at the **18** `assumeIsolated` sites the hook can't see). ✓
- **C1 (off-main layout race)** — read `CustomLayoutErasure.swift:288-347`: unsynchronized `cachedStates` mutated inside `nonisolated` + `assumeIsolated`. ✓
- **VT220 parser bug (`#8`)** — read `TerminalInputParser.swift:146-171`: the CSI switch handles only single-letter terminators and consumes exactly 3 bytes; `ESC [ 3 ~` (Delete) falls to `default` → emits `.escape`, leaving `~` to be inserted as a literal. ✓
- **WASI green-ship gap (`#5`)** — corroborated by the framework's own `swift-tui/CLAUDE.md` ("the Linux Repo Gate does not compile wasm32-wasi … hit at 0.0.19, again at 0.0.26"). ✓

The adversarial validators **refuted 42 survey signals** as false alarms or acceptable trade-offs (e.g., one over-claimed that `TerminalImageRenderer` "has cache policies" — it does not; only the wrapped `ImageBlendCompositor` does), so the 127 confirmed issues are a filtered set.

**Tally:** 127 confirmed (2 critical · 35 high · 63 medium · 27 low) across 14 subsystems + 4 lenses.
