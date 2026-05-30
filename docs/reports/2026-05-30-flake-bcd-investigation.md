# Flake-surface B/C/D investigation + remediation

**Date:** 2026-05-30
**Scope:** `SwiftTUI/swift-tui` test determinism. Parallel investigation
(B = run-loop SIGSEGV #12 repro design, C = latent-flake hunt, D = determinism
infrastructure audit), synthesized and partially implemented.
**Method:** 26-agent read-only analysis workflow → adversarial completeness
critic → ground-truth verification → deliberate implementation.
**Predecessor:** flake #2 (`OffscreenFrameElisionRuntimeTests` deadline race)
fixed 2026-05-30 (`swift-tui@3f671ea3`, injectable `RunLoop.frameReadinessClock`).

---

## Executive summary

- **The deterministic apparatus is fundamentally sound.** No gate auto-retries;
  `tee`-proof exit-code capture (`test_all.sh:319-375`); real hang-detection with
  process-tree kill; two live policy ratchets wired single-path (local == CI). The
  latent-flake hunt confirmed **only one** real (P2, not-firing) finding across the
  whole test surface; every shared-sink / cross-isolation candidate was refuted as
  deterministic-by-construction. The exposure is in infra *coverage*, not in
  currently-firing tests.
- **One active flake remains: #12 (SIGSEGV/SIGBUS memory corruption).** It is
  invisible to ASan *and* TSan and not reproducible on demand. The investigation
  converged on a faithful, production-safe repro **instrument** (a worker-parking
  seam) and a sharpened hypothesis about the corruptor.
- **Landed this session (all green):** 3 deterministic quick wins, the production
  repro seam + its regression guard, and an opt-in serialized-run gate lever.
- **Sharpened SEGV hypothesis (see §B):** the original "Boxed COW race" is, on
  closer reading, likely *safe* under value semantics; the **stronger corruptor
  candidate** is the genuinely unsynchronized `assumeIsolated` dictionary writes.
  The next experiment should target that.

---

## B — Run-loop SIGSEGV #12

### Mechanism candidates (sharpened)

The off-main frame-tail worker (`FrameTailWorkerExecutor`, Dispatch queues
`swift-tui.frame-tail-{layout,renderer}`) runs measure/place/raster over node
trees while the main actor concurrently retains and reads the same trees (the
render-suspension hooks release main to drain input + apply live `@State` during
the running tail). Two candidate writers were identified:

1. **`Boxed` COW on `DrawMetadata.heavyFields`** (`Boxed.swift:36-43`). The worker's
   `applyOpacityCascadingPlaced` (`PlacedAnimationOverlay.swift:141-148`) drives
   `Boxed._modify` on a tree aliased (via cheap value-copies sharing `_BoxStorage`)
   with `AnimationController.previousPlacedRoot`.
   **Caveat (this review):** `PlacedNode`/`Boxed` are *value* types. Worker and main
   hold separate `Boxed` copies that share the `_BoxStorage` *object* (whose `state`
   is `Mutex`-guarded and refcount atomic). The worker's `_modify` sees refcount ≥ 2
   → **copies-on-write to its own fresh box**, never mutating the storage main reads.
   For the torn-pointer race to exist both threads must touch the *same `_storage`
   field memory*, which value copies do not share. **This path is therefore likely
   safe**, contrary to the first-pass hypothesis. (The original synthesis also made
   a factual error here — see §process-notes.)

2. **Unsynchronized `assumeIsolated` dictionary writes (STRONGER candidate).**
   `ForEachIndexedChildSource.cache: [Int: ResolvedNode]`
   (`IndexedChildSources.swift:22,88`) and `LayoutProxyBox.cachedStates:
   [CacheKey: Any]` (`CustomLayoutErasure.swift:289`) are plain mutable
   `Dictionary`s on `@MainActor` classes, written inside nonisolated bodies via
   `MainActor.assumeIsolated`. Under `.defaultIsolation(.none)` + optimized build the
   executor check can be elided rather than trapping, turning a should-be-fatalError
   into a silent **off-main dictionary mutation**. A concurrent `Dictionary` insert
   that triggers a buffer realloc is a classic torn-read SEGV whose bytes are the
   stored nodes (rendered text) — a *better* fit for #12's signature than the COW
   path. Reachability depends on the layout-offload eligibility scan
   (`FrameTailLayoutOffloadEligibility.swift`) missing a live source/handle (e.g. a
   retained prior-frame node, or a nested unconverted source).

### Repro instrument (landed) + experiment (next step)

**Landed — `FrameTailRenderHooks.beforeOverlayApply`** (`FrameTailModels.swift`):
a production-default-`nil` `@Sendable` hook that fires on the worker immediately
before `applyPlacedAnimationOverlaySnapshot`, threaded through `renderRaster` /
`renderRasterAsync` → `renderInlineRasterTail`. Mirrors the existing
`beforeLayout`/`beforeRaster` seams. The pre-existing `beforeRaster` fires *after*
the overlay write, so it cannot bracket the box mutation — hence one new seam.
Guarded by `Tests/SwiftTUITests/FrameTailOverlayApplyHookTests.swift` (fires
before raster; nil default is a no-op).

**Next experiment (deferred, deliberate):** park the worker at the seam while the
main actor concurrently reads the aliased `previousPlacedRoot`; PASS = survival,
repro = SIGSEGV; release mode, serialized (`STUI_SWIFT_TEST_SERIALIZED=1`), under
`Scripts/repeat_async_flake_registry.sh`. Given the §B caveat, **target the
dictionary path first** (a `ForEach`/`AnyLayout` tree forced down the worker layout
path + a layout-stage parking seam + concurrent `source.child(at:)`/`cachedStates`
read) — the overlay seam exercises the likely-safe path and would most plausibly
*survive* (still informative: it narrows to the dictionary path).

---

## C — Latent-flake hunt (multi-modal, adversarially verified)

**One confirmed finding (P2, not firing):**

| file:loc | modality | why | fix |
|---|---|---|---|
| `InteractiveRuntimeTests.swift:529` (`count < 20`, driven by `usleep(50)`) | wall-clock coalescing window | sole assertion riding the real 1 ms input-flush timer (no injectable seam); a producer-deschedule pathology could make it fail | **FIXED** — drop the `usleep`, assert load-independent invariants (`count <= 20` no-over-production + delta conservation `sum == 20`) |

**Zero confirmed** in every other modality (shared-sink, unstructured-task,
sleep-poll). All high-suspicion shared-sink / cross-test-isolation candidates
(`AnimationSinkStorageTests`, `RunLoopProgressLogTests`, `ProfileActivationTests`,
…) were refuted: each is `@MainActor` + synchronous, serialized on the main-actor
executor by construction. **Do not add `.serialized` to those suites** — it would
be redundant and imply a race that does not exist.

---

## D — Determinism-infrastructure gaps

| # | Pri/Effort | Gap | Status |
|---|---|---|---|
| D3 | P1/S | sync-ratchet missed `usleep`/`nanosleep`/`Thread.sleep` | **FIXED** — 3 regexes added; baseline 6→10 (6 `DispatchSemaphore` + 4 sleeps). Header documents composition + the 4 pending-conversion sleeps |
| D11 | P2/S | concurrency-safety scan omitted `Tools/` | **FIXED** — `Tools` added to scan roots (verified clean) |
| D10 | P1/M | gate pinned no worker count → #12 interleave not bisectable | **FIXED** — opt-in `STUI_SWIFT_TEST_SERIALIZED=1` → `--num-workers 1`, composes with the skip-regex seam, default unchanged |
| D5 | P1/S | no detached-task join helper (leak footgun) | **DEFERRED** — land with the sleep-conversion follow-up (avoid dead code) |
| D6 | P1/S | no scoped sink-restore fixture | **DEFERRED** — D8-blocked + land with sink-conversion callers |
| D8 | P1/M | `SwiftTUITestSupport` has empty deps → can't host runtime-backed helpers | **DEFERRED** — not required for the repro (it lives in `Tests/SwiftTUITests`, already runtime-linked); decide if/when D1/D2/D7 are built |
| D1/D7 | P1/M | no reusable frozen-frame-clock / frame-pump primitive | **DEFERRED** — generalization; the repro uses existing Support signals |
| D2 | P1/M | `StageClock` has no runtime adapter | DEFERRED (blocked on D8) |
| D4/D9/D12/D13/D14 | P2 | `Task{}` ratchet; orphan repeat-harness; wall-clock-read ratchet; blocking-rendezvous primitive; CRASH-vs-FAIL gate classification | DEFERRED — hardening, none on the #12 critical path |

---

## Already good — do not regress

- No gate auto-retries; `tee`-proof exit capture surfaces a SIGSEGV (status >128)
  as FAIL, never PASS. Hang-detection is real and bounded (its 0.2 s watchdog poll
  is the watchdog's own loop, **not** a test predicate poll).
- High-contention async suites are isolated into standalone steps and
  `.serialized` (`AsyncFrameTailRenderingTests`). Keep this.
- `Tests/Support` poll-free primitives (`AsyncEvent`, `ConditionSignal`,
  `MainActorConditionSignal`) are cancellation-correct (re-check predicate at
  registration, unregister+resume on cancel). Extend, don't replace.
- `RunLoop.frameReadinessClock` (prod default = real monotonic accessor) is the
  exemplar seam — any future frozen-clock helper must *wrap* it, not alter its
  default.

---

## Process notes (verify before acting)

- The first-pass synthesis claimed the sync-ratchet "matches only `Task.sleep`" with
  baseline-6 being sleeps. **False** — the completeness critic caught it and
  ground-truth confirmed: the ratchet already catches `DispatchSemaphore` /
  `waitUntil(` / `valueWithTimeout(`, and all 6 baseline hits are `DispatchSemaphore`
  (zero sleeps). The re-baseline math was recomputed empirically (→ 10).
- Untouched/partially-swept surfaces flagged by the critic, for completeness:
  `Tools/TermUIPerf/Tests` (perf-threshold modality), and a dedicated
  blocking-rendezvous sweep of `Platforms/Embedding/Tests` terminal/PTY suites.
- A second `drawMetadata` writer (`ViewMetadataModifiers.swift:289`) exists but is
  resolve-path (main-actor), not the off-main corruptor.

---

## Git state

flake-#2 fix (`swift-tui@3f671ea3`) + org pin (`c89e3e2`) are committed but
**unpushed** (held by decision 2026-05-30). This session's swift-tui changes stack
on top, unpushed, pending review.

> **Superseded — see Closure below. The whole batch is now pushed.**

---

## Closure (2026-05-30, post-investigation)

This investigation is **concluded**. The following supersedes the open items above.

- **Retained-reuse SEGV vector — CLOSED.** A 6-agent adversarial re-trace (workflow
  `w1u1xkuj0`) confirmed both AND-conditions hold — the one-shot/sync commit retains a
  live `@MainActor` `ForEachIndexedChildSource` (the snapshot conversion is gated
  `mode == .abortable`, which one-shot skips: `injectAnimations` → reconcile →
  `commitOneShotFrame` → `storeCommittedFrame` → `RetainedFrameIndex`), **and** a later
  off-main worker reads it in `RetainedInvalidationSummary.init` (`source.identityRoot`)
  on the `swift-tui.frame-tail-renderer` queue — **but the vector cannot produce #12's
  corruption.** Every reachable off-main accessor reads immutable `let` storage
  (`identityRoot`/`measurementSignature` under `assumeIsolated`); the sole mutator
  (`cache[index] = …` in `child(at:)`) fires only on the *current* node's value-type
  snapshot, never the retained live source. `computeSupportsRetainedReuse` also returns
  `false` for any source-bearing node, so `isEquivalentFor*` never runs on a source
  subtree. `LayoutProxyBox.cachedStates` is likewise unreachable (reuse returns cached
  values; never calls `measureContainer`). The crash-repro build was **cancelled**, not
  built — the dead-end was identified before any harness was written.
- **#12 is now mechanism-unidentified.** With the current-frame offload, retained-reuse,
  and `Boxed` COW paths all closed, static analysis has exhausted the named corruptor
  candidates. The honest next step (if/when #12 is re-prioritized — currently
  user-deferred) is **dynamic** instrumentation: reproduce the SEGV under load with TSan
  + annotated `assumeIsolated`/eligibility sites. Not another static harness.
- **Residual sweeps — CLEAN.** The two surfaces flagged "partially swept" above
  (`Tools/TermUIPerf/Tests` perf-threshold modality, and `Platforms/Embedding/Tests`
  terminal/PTY) were fully swept: **zero P1/P2**. TermUIPerf threshold tests run in-gate
  but assert only on hardcoded synthetic inputs (no measured wall-clock). The
  latent-flake hunt is comprehensively done — **1 P2 total** across the whole surface
  (the already-fixed C-P2).
- **Benign byproduct.** The one-shot commit path stores a live source into retained
  state with no conversion — harmless today (off-main reuse only reads immutable
  storage), latent only if reuse ever begins calling `child(at:)` off-main. Optional
  defense-in-depth: snapshot-convert before `storeCommittedFrame` (weigh against
  full-tree recursion cost per one-shot commit).
- **Git state — PUSHED.** The whole batch is public: `swift-tui@93e9ea3d`, org pin
  `52f3838` (both in sync with origin; `bazel //:org_fast` 4/4 green). The canonical,
  living flake status is `swift-tui/docs/KNOWN-TEST-FLAKES.md`; this report is the
  point-in-time investigation record.
