# SwiftTUI Org — Code-Quality Audit (2026-06-24)

> Methodology: a multi-agent audit (Opus, batched) fanned **19 subsystem auditors**
> across all seven repos, then **adversarially verified** every correctness / risk /
> architecture finding with an independent skeptic before it was admitted. Raw:
> **228 findings, 18 rejected by verification, 210 actionable** (144 in `swift-tui`).
> Severity: 8 high / 81 medium / 121 low. riskOfChange: 142 low / 68 medium / 0 high.
> This report is the synthesized, prioritized plan. Group A is being implemented
> directly; Group B is staged with per-item gate verification.

# SwiftTUI Org — Code-Quality Audit: Prioritized Action Plan

## 1. Executive Summary

Overall the SwiftTUI org is in **strong health**: across ~18 subsystems the recurring verdict is "clean, value-typed, well-commented, conventions respected." No critical memory-safety or WASI-correctness defects surfaced. The findings skew toward *readability/architecture debt* and a thin layer of *latent correctness bugs* rather than systemic rot.

**Strongest areas**
- `swift-tui/core-geometry-layout`, `core-pipeline`, `views-input-gestures`, `runtime-lifecycle` value types — exemplary doc comments, explicit invariants, disciplined value semantics.
- `swift-tui-android` pure encoder/parser layers and `swift-tui-web` hot paths (wheel chaining, WASI poll) — well-tested, well-guarded against untrusted input.
- `examples` reference apps (ArcadePhysics, LifeGrid, WASI hosts) — high-quality, copy-worthy.

**Weakest areas (concentrated debt)**
- **`swift-tui/runtime-lifecycle` — `AnimationController.swift`** (1595 lines, 25-field hand-maintained checkpoint/restore/reset triplet): the single largest latent state-leak risk in the org.
- **`swift-tui/core-resolve` — `ViewGraph.swift`** (35-field god object with four hand-synchronized field lists; a verbatim-duplicated checkpoint-restore block).
- **`swift-tui-web` — `WebHostSceneRuntime.ts`** (~1100-line god class, five responsibilities).
- **Hand-rolled god-functions**: `Rasterizer+Paint.paint(commands:)` (430 lines), `ScrollView.resolveElements` (~300), `RunLoop.swift` (15 convenience inits), `EditorViewModel` (886), `GalleryView` tab roster (×4).
- **WebHost/CLI security seams** (non-constant-time token compare, predictable `/tmp` socket, raw token-into-HTML splice) and the **coordination release path** (history-protection asymmetry, site gate reads live submodule, `release_pin_contract` absent from `org_full`).

---

## 2. Cross-Cutting Themes

1. **Hand-maintained parallel field lists that drift silently.** The dominant systemic risk. Appears in `ViewGraph` (4 lists), `AnimationController` (25-field triplet), `ResolveContext.child()/replacingIdentity()` (~18 registries), `TerminalAppearance` palette (subscript get/set/indexedColors). **Systemic fix:** group related fields into small value-typed sub-structs so Swift's memberwise semantics carry the totality contract instead of a reviewer.

2. **Duplicated helpers across files, each re-importing libc / re-deriving math.** `getenv`-based env helper (×3 WASI-unsafe surfaces), `animationSurfaceSize` (×2), Duration-to-seconds (×3), `oppositeEdge` (×2), accessibility sanitizer (verbatim ×2), output-record dispatch (×3 web bridges). **Systemic fix:** one owning helper per concern; shrink the WASI-sensitive surface.

3. **`Dictionary(uniqueKeysWithValues:)` trap on untrusted/duplicate keys.** Recurs in `LiveRegionAnnouncer`, `LinearAccessibilityRenderer`, `HostedAccessibilityAnnouncer`. **Systemic fix:** `uniquingKeysWith: { _, last in last }` everywhere keys come from snapshot identities.

4. **God-functions / god-files mixing 4-5 responsibilities.** Paint switch, DrawExtractor, ScrollView, RunLoop, AnimationController, Toolbar, WebHostSceneRuntime, EditorViewModel. **Systemic fix:** extract focused helpers/files; the repos already follow "many small files" elsewhere.

5. **Dead code advertised as live API.** `canDrop` (always false, public), `nodesByIdentity`, `hasNoRecordedDependencies`, `idealTextSize`, Spinner `Pair`/`Progression`, builtin-stack Layout methods (~180 lines), `SceneInfo: Codable`, GalleryTabDescriptor `content`, `.pasteClipboard` reducer arm.

6. **Silent-failure swallowing.** Malformed color hex (Android), GIF decode (`try?`), JSON unknown-key truncation (CLI), orphaned animation completions, schema-version drift. **Systemic fix:** surface through existing error/diagnostic channels.

7. **Magic numbers without provenance.** 33ms poll, VMIN/VTIME indices 16/17, East-Asian-width ranges, contrast thresholds, GeometryReader 10×10, nav depth 32.

---

## 3. Top Correctness & Risk Issues (must-fix, by severity)

### HIGH
1. **`swift-tui-swiftui` / `NativeTerminalPlatformAdapters.swift` (75-88)** — macOS `terminalColor` builds NSColor in calibrated RGB *after* sRGB conversion, corrupting the raster-comparison that is this host's entire purpose. **Fix:** use `NSColor(srgbRed:green:blue:alpha:)`; add a round-trip regression test. *(safe)*
2. **`swift-tui` / `TerminalInputParser.swift` (66-76)** — Backspace (Ctrl+H / 0x08) swallowed by the Ctrl-letter range, never reported as `.backspace`. **Fix:** exclude 0x08 from the range so `case 0x08, 0x7F: .backspace` handles it; add `[0x08]→.backspace` test. *(safe)*
3. **`swift-tui` / `Spinner.swift` (35-61)** — index-out-of-bounds on set change; a safe accessor exists but is unused. **Fix:** `set.body[safe: iteration] ?? set.body.first ?? set.head`; replace `body.first!`. *(safe)*

### MEDIUM (correctness)
4. **`swift-tui` / `Rasterizer+Paint.swift` (867-876)** — foreign-surface no-blend path bit-copies continuation cells with stale lead-X across coordinate spaces. **Fix:** translate via `write(...)` in destination space, or rewrite `continuationLeadX`. *(needs care)*
5. **`swift-tui` / `WebHostServer.swift` (112-139)** — `WebHostSceneChannel.attach` orphans the prior connection's output stream (hangs). **Fix:** `outputContinuation?.finish()` before installing new one; test two clients. *(safe)*
6. **`swift-tui` / `ImageBlendCompositor.swift` (260-292)** — O(n²) cache eviction re-snapshots every iteration. **Fix:** maintain running totals incrementally. *(needs care)*
7. **`swift-tui` / `LiveRegionAnnouncer.swift` (26-28)** + `LinearAccessibilityRenderer` (27) — `Dictionary(uniqueKeysWithValues:)` traps on duplicate keys. **Fix:** `uniquingKeysWith: { _, last in last }`. *(safe)*
8. **`swift-tui` / `LinkOpening.swift` (19-41)** — unvalidated `LinkDestination` passed to `open`/`xdg-open`. **Fix:** scheme allow-list (http/https/mailto), reject leading `-`. *(needs care)*
9. **`swift-tui-web` / `SharedInputQueue.ts` (68-135)** — ring-buffer indices overflow Int32 in long sessions. **Fix:** keep indices bounded mod `2*length`; test past 2³¹ bytes. *(needs care)*
10. **`swift-tui-android` / `SwiftTUIRenderer.kt` (20-56,111-168)** — singleton holds one shared mutable bitmap cache; two host views corrupt each other. **Fix:** instance per host (`remember { SwiftTUIRenderer() }`). *(safe-rated)*
11. **`swift-tui-examples` / `gifeditor/Tools.swift` (101-172)** — fill/gradient write unchecked with a selection rect never clamped to the buffer. **Fix:** `.intersected(with: fullRect)`, early-return on nil. *(safe)*
12. **`swift-tui-org` / `bump_version.sh` (171-181)** — `is_history()` protects root `docs/README.md`/`RELEASE.md` but rewrites child copies. **Fix:** add `*/`-prefixed siblings. *(safe)*
13. **`swift-tui-org` / `run_site_pretag_gate.sh` (38-42)** — site gate reads swift-tui from the LIVE submodule, not the overlay it built. **Fix:** `SWIFTTUI_CHECKOUT="$overlay_dir/swift-tui"`. *(safe, verify both pretag gates)*
14. **`swift-tui-org` / `pixel_compare.py` (35-37,74-85)** — ImageMagick exits unchecked; a failed montage yields a "success" report. **Fix:** raise on non-zero returncode + preflight `which`. *(safe)*

### LOW but real (correctness)
15. `swift-tui` / `RunLoop+PointerHandling.swift` (324-335) — scroll hit-test fallback fabricates `.now()`; add `timestamp: timestamp`. *(safe)*
16. `swift-tui` / `TabView.swift` (191-202) — focused TabView always swallows arrowUp; return `moveStoredOverflowMenuFocus(... delta:-1)`.
17. `swift-tui` / `FocusedValues.swift` (26-42) — non-Hashable focused values always compare equal, swallowing updates; fallback to `false`.
18. `swift-tui-swiftui` / `HostedAccessibilityAnnouncer.swift` (22-24) + `NativeClipboard.swift` (1-22, Catalyst guard) — dup-key trap and `canImport(AppKit)` selecting NSPasteboard on Catalyst. *(both safe)*
19. `swift-tui` / `TerminalRunner.swift` (436-449) — hand-rolled JSON parser truncates on unknown keys; implement `skipValue()`. *(safe)*

---

## 4. Prioritized Implementation Plan

### (A) SAFE QUICK WINS — low risk, high readability/correctness value
Ordered by value-to-risk. All are `safeToApply: true` or trivial readability with `riskOfChange: low`.

| # | repo | file | concrete change |
|---|------|------|-----------------|
| 1 | swift-tui | `Sources/SwiftTUIRuntime/Input/TerminalInputParser.swift` (66-76) | Exclude `0x08` from the Ctrl-letter range so `case 0x08, 0x7F: .backspace` fires; update the comment; add `[0x08]→.backspace` test. |
| 2 | swift-tui-swiftui | `Sources/SwiftUIHost/NativeTerminalPlatformAdapters.swift` (75-88) | Replace calibrated-RGB NSColor with `NSColor(srgbRed:green:blue:alpha:)`; add a known-fill round-trip raster test. |
| 3 | swift-tui | `Sources/SwiftTUIViews/Controls/Spinner.swift` (35-61,166-174) | `Text(set.body[safe: iteration] ?? set.body.first ?? set.head)`; replace `body.first!` with `body.first ?? head`. |
| 4 | swift-tui | `Sources/SwiftTUIRuntime/RunLoop/RunLoop+PointerHandling.swift` (324-335) | Add `timestamp: timestamp` to the fallback `LocalPointerEvent.init`. |
| 5 | swift-tui | `Sources/SwiftTUIRuntime/Accessibility/LiveRegionAnnouncer.swift` (26-28) + `LinearAccessibilityRenderer.swift` (27) | Switch to `Dictionary(_, uniquingKeysWith: { _, last in last })`. |
| 6 | swift-tui-swiftui | `Sources/SwiftUIHost/HostedAccessibilityAnnouncer.swift` (22-24) | Same dup-key fix: `uniquingKeysWith: { _, latest in latest }`. |
| 7 | swift-tui-swiftui | `Sources/SwiftUIHost/NativeClipboard.swift` (1-22) | Change both `#if canImport(AppKit)` to `#if canImport(AppKit) && !targetEnvironment(macCatalyst)`. |
| 8 | swift-tui | `Sources/SwiftTUICore/Resolve/ViewGraph.swift` (47-92) | Make `restoreCheckpoint(_:)` delegate to `restoreCheckpointGraphFields(checkpoint)`, leaving one authoritative field list. |
| 9 | swift-tui | `Sources/SwiftTUICore/Resolve/ViewGraph.swift` (225-234) | Delete dead `nodesByIdentity` computed property. |
| 10 | swift-tui | `Sources/SwiftTUICore/Support/PlatformMath.swift` (1-26) | Add `#elseif canImport(ucrt) import ucrt` + `ucrt.pow(...)` branch to match sibling shims. |
| 11 | swift-tui | `Sources/SwiftTUICore/Geometry/CellPixelMetrics.swift` (22-26) | Guard `aspectRatio` divisor: `guard width > 0 else { return .estimated.aspectRatio }`. |
| 12 | swift-tui | `Sources/SwiftTUIViews/TabViews/TabMetadataPeeking.swift` (30-37) | Make first-wins explicit: `if self.label == nil { self.label = other.label }` (drop no-op inequality guards). |
| 13 | swift-tui | `Sources/SwiftTUIViews/TabViews/TabView.swift` (660-661) | Add `tabFocusedIndex`/`tabOverflowMenuExpanded`/`navigationDestinationActivation` bases to `StateSlotOrdinals`. |
| 14 | swift-tui | `Sources/SwiftTUIRuntime/Input/TerminalInputStreamReading.swift` (68-88) | Replace zero-filled buffer with `[UInt8](unsafeUninitializedCapacity:initializingWith:)`. |
| 15 | swift-tui | `Platforms/CLI/.../TerminalRunner.swift` (436-449) | Add a `skipValue()` to the JSON parser's `default` arm so unknown keys are tolerated. |
| 16 | swift-tui | `Platforms/WebHost/.../WebHostFlyingFoxServer.swift` (157-178) | Add a constant-time byte-compare helper; route all token checks through it. |
| 17 | swift-tui-examples | `gifeditor/Sources/GIFEditorCore/Tools.swift` (101-172) | Clamp selection rect: `(selection?.rect ?? fullRect).intersected(with: fullRect)`, early-return on nil. |
| 18 | swift-tui-examples | `gallery/.../GalleryView.swift` (320-322) | Replace `descriptor(for:)` `!` with `preconditionFailure("missing descriptor for \(tab)")`. |
| 19 | swift-tui-web | `packages/build/src/build/buildAppWasm.ts` (74-89) | Track `lastGood` bytes; on strip failure restore the validated optimize, not `sourceBytes`. |
| 20 | swift-tui-site | `Website/scripts/prepare-webexample.test.ts` (78-86) | Delete the `rev-parse --git-dir` mock arm production no longer calls. |
| 21 | swift-tui-org | `tools/coordination/bump_version.sh` (171-181) | Add `*/docs/README.md`, `*/RELEASE.md`, `*/docs/PUBLIC-REPO-READINESS.md` to `is_history()`. |
| 22 | swift-tui-org | `tools/coordination/run_site_pretag_gate.sh` (38) | `SWIFTTUI_CHECKOUT="$overlay_dir/swift-tui"`. |
| 23 | swift-tui-org | `tools/layout-diff/pixel_compare.py` (35-37) + `diff.py` (154-156) | `magick()` raises on non-zero rc + preflight; compute report Date at runtime. |
| 24 | swift-tui | misc dead code | Delete `idealTextSize` (ViewPrimitives 270-272); change three `fileprivate`→`private` (Table 251/263, NavigationStack 420); delete `SceneInfo: Codable` (SocketServer 20-27). |

### (B) CHANGES NEEDING CARE — architectural/behavior-touching
Ordered by value-to-risk. Each names the gate/test to verify.

| # | repo \| file | change | verify with |
|---|--------------|--------|-------------|
| 1 | swift-tui \| `Rasterizer+Paint.swift` (867-876) | Translate foreign continuation cells into destination space instead of bit-copying stale lead-X. | Raster snapshot/diff tests for foreign-surface composite; `bazel test //:native_gates`. |
| 2 | swift-tui \| `WebHostServer.swift` (112-139) | `outputContinuation?.finish()` before reattach; send `.close` to displaced client. | New two-client WebHost test; WebHost target tests. |
| 3 | swift-tui \| `ImageBlendCompositor.swift` (260-292) | Incremental running totals so `violates()` is O(1). | Terminal image-cache eviction tests under `native_gates`. |
| 4 | swift-tui \| `LinkOpening.swift` (19-41) | Scheme allow-list + reject leading `-`; centralize for all five hosts. | Add link-opening policy unit tests; runtime tests. |
| 5 | swift-tui-android \| `SwiftTUIRenderer.kt` (20-56,111-168) | Convert singleton to per-host class via `remember { SwiftTUIRenderer() }`; keep pure helpers as object fns. | Kotlin host unit tests + two-host instrumentation; Gradle build. |
| 6 | swift-tui-web \| `SharedInputQueue.ts` (68-135) | Bound ring indices mod `2*length`; preserve used/free math. | New test writing/reading past 2³¹ bytes; web package tests. |
| 7 | swift-tui-org \| `BUILD.bazel` (205-221) | Move `release_pin_contract` into `org_full` (or document `release_candidate` as the mandatory pre-pin gate and repoint the runbook). | `bazel test //:org_full` and `//:release_candidate`. |
| 8 | swift-tui-org \| `release_pin_contract.sh` (40-60) | Restrict reachability to `origin/main`/explicit release branches, not any `origin/*`. | `//:release_candidate` against a known-good and a deliberately-unpublished pin. |
| 9 | swift-tui \| `Environment.swift` (47-148) | Replace `String(reflecting:)` equality key with typed `isEqual(to:)` on `EnvironmentValueBox`. | Env reuse/equality tests; full resolve gate (`native_gates`). |
| 10 | swift-tui \| `FocusedValues.swift` (26-42) | Non-Hashable fallback returns `false` (force update); document. | Focused-value invalidation tests. |
| 11 | swift-tui \| `ResolveContext.swift` (134-218) | Group propagated registries into one `PropagatedRegistries` struct copied once by `child`/`replacingIdentity`. | Resolve/reuse suite; `native_gates`. |
| 12 | swift-tui \| `RunLoop.swift` (166-794) | Extract 15 convenience inits to `RunLoop+Initializers.swift`; collapse surface/reader axes to one canonical init each. | Runtime tests; ensure all call sites compile (`native_gates`). |
| 13 | swift-tui \| `ScrollView.swift` (41-336) | Extract `makeScrollBodyPointerHandler`/`makeIndicatorPointerHandler`; slim `resolveElements`. | Scroll/gesture tests; gallery scroll reproducers in `check_examples.sh`. |
| 14 | swift-tui \| `AnimationController.swift` (4-1595) | Extract `PreviousFrameState` + `TransitionRegistry` value sub-structs so checkpoint/restore/reset become a few assignments; add orphaned-completion counter (496-523). | Animation/tab-switch regression suite (the documented elision/completion reproducers); `native_gates`. |
| 15 | swift-tui \| `ViewGraph.swift` (179-223) | Group the 35 fields into `LifecycleEventBuffers`/`LifecycleEvaluationOwnership`/`DirtyState` sub-structs; extend the totality test. | Checkpoint-totality test + resolve suite. |
| 16 | swift-tui \| `Semantics.swift` (36-164,198-330) | Bundle the 9 positional visitor args into one labeled `VisitContext`. | Semantics/accessibility walk tests. |
| 17 | swift-tui \| `RuntimeRenderPipeline.swift` (121-273) + `FrameTailPresentationDamage.swift` (346-366) | Unify the three render-executor loops; introduce one `RuntimeEnvironment.value(named:)` owning libc/`unsafe` (replaces ×3 getenv surfaces). | Render-pipeline tests; WASI compile path (`examples_pretag_native_gate`) — recall the WASI-doesn't-compile-on-Linux gap. |
| 18 | swift-tui-web \| `WebHostSceneRuntime.ts` (108-137) | Split into `CanvasSurfacePainter` + `InputEventEncoder`, keep runtime as coordinator. | Web unit tests for extracted dirty-region/wheel modules; site build. |
| 19 | swift-tui-web \| `AccessibilityTree.ts` (44-69) | Diff-and-reuse keyed by `node.id` instead of `replaceChildren()`; preserve focus. | ARIA mount tests; manual focus-retention check. |
| 20 | swift-tui-swiftui \| `NativeTerminalSurfaceView.swift` | Extract shared `HostedSurfacePresenter` from the ~150 duplicated AppKit/UIKit lines. | SwiftUIHost raster/grid-negotiation tests on macOS + iOS. |
| 21 | swift-tui-examples \| `EditorViewModel.swift` (11-873) + `GalleryView.swift` (13-99) | Extract `EditorHistory`/`CanvasDragController`/`GIFDocumentIO`; drive Gallery tabs from a single `tabDescriptors` via `ForEach`. | `check_examples.sh`; examples pretag gate. |

**Suggested sequencing:** land all of Group A in a single sweep per repo (each is independent and behavior-preserving), gated by `bazel test //:org_fast` then `//:native_gates`. Then take Group B by repo in the order above — the org-coordination items (B7, B8) and the two HIGH-severity host bugs already covered in A (#1, #2) should precede any release. Bump pins only after `//:org_full` is green.
