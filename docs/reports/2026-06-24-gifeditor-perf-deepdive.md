# GIF editor performance deep-dive — drawing lag + quit-popover "freeze"

**Date:** 2026-06-24
**Scope:** `swift-tui-examples/gifeditor` (+ a secondary `swift-tui` core finding)
**Method:** 6 parallel subsystem tracers → adversarial verification (2 skeptics/claim) →
synthesis + completeness critic (62 agents). Every claim below carries a `file:line`
citation read from source; regression dates are from `git blame`/`git show`.

---

## TL;DR

| # | Symptom | Root cause | Where | Regressed? |
|---|---------|-----------|-------|-----------|
| 1 | Drawing lags | **The whole document is re-composited on every render frame** — the timeline rebuilds a thumbnail for *every* frame, unmemoized | `EditorView.swift:74-80,293-308` → `Document.swift:98-118` | No — day-one `O(N_frames)` design cost (`ba4bbbd`, 2026-05-23). Bites harder as docs grow. |
| 2 | Quit popover "freezes" | **`SaveGIFPreview.make` runs a full encode+decode+re-flatten synchronously on the main actor before the sheet paints**, and then **every keystroke in the path field re-runs the symptom-1 flatten storm** | `EditorView.swift:70`, `SaveGIFSheetView.swift:14-37`; `EditorView.swift:74-80` | Mixed — the encode-on-present is from `4596920` (2026-06-08); a core root-invalidation that amplifies typing is from `aae4f797` (2026-04-25). |

Both symptoms share one underlying cause: **nothing in the editor memoizes layer
compositing.** Fix the compositing memoization and both improve dramatically.

---

## Symptom 1 — drawing lags

### How a stroke actually flows (verified)

`InteractiveCanvasView` drag `onChanged` → `model.updateCanvasDrag(...)` → `refresh()`
(`CanvasView.swift:295-298`). `refresh()` bumps `@State revision` (`EditorView.swift:66`),
which `EditorView.body` reads at `:64`, so the **entire `EditorView.body` re-evaluates**.

Pointer moves are **coalesced** before they reach the body (input reader merges drags in a
1 ms window; `EventPumpBuffer` merges consecutive drags; the scheduler unions invalidations
into one `ScheduledFrame`). So the body re-eval fires **once per rendered frame (~30 fps
ceiling), not once per raw pointer sample.** The earlier "per-pointer-move" framing was
overstated and is rejected. Lag scales with **frame-count × canvas-area × frames-rendered-
during-the-stroke**.

### RC-1 (primary) — timeline re-composites *every* frame, every render

`EditorView.body` unconditionally builds `timelineFrames` by mapping over all frames and
calling `thumbnail(for:)` (`EditorView.swift:75-80`), which calls
`model.document.flattenedColors(frameIndex:)` for **every** frame (`:294`).
`flattenedColors` → `flatten` (`Document.swift:98-118`) allocates a fresh `PixelBuffer`,
`stamp()`s every visible layer over the whole area (`PixelBuffer.swift:90-106`), then
palette-maps every pixel. **No memoization anywhere.**

- **Cost:** `O((N_frames + 1) × layers × area)` per rendered frame.
- **Amplifier:** computed even when the timeline is collapsed — `showsTimeline`
  (`:159`) gates only the `TimelineView` *render*, not the `:75-80` *compute*.
- **Not a recent regression:** `git blame` attributes every hot line to `ba4bbbd`
  ("create examples workspace", 2026-05-23). It's an `O(N)` design cost the user feels now
  that documents have more frames — exactly "regressed, not necessarily recently."

### RC-2 — current-frame composite re-flattened full-stack every render

`frameColors = document.flattenedColors(frameIndex: currentFrameIndex)`
(`EditorView.swift:74`). The current frame *is* genuinely dirty mid-stroke, so a recompute
is needed — but it re-stamps every visible layer over the whole area rather than the dirty
region. `O(layers × area)` per render. This is the floor cost left after RC-1 is fixed
(and it is `N×` smaller than RC-1 on a multi-frame doc).

### RC-3 — `resolvedPixels` rebuilt twice per canvas render

`CanvasSurfaceView.resolvedPixels` (`CanvasView.swift:72-81`) allocates a fresh `[Color?]`
of `size.area` and is read **twice** in `body` — once for `Canvas.pixelGrid` (`:51`) and
once for the overlay (`:59`). `CanvasSurfaceView` isn't `Equatable`, so the body can't be
skipped. A constant-factor 2× on the canvas color slice — real but secondary.

### Minor contributor — per-move buffer COW copy

`mutateCurrentLayer` (`EditorViewModel.swift:661`) does `var layer = currentLayer`, and
`ToolOps.line` does `var copy = buffer` (`Tools.swift:190`), forcing an `O(area)` COW deep
copy of the layer's `[PaletteIndex?]` **per stroke segment (per move)**. Dwarfed by
RC-1/RC-2 (`O(area)` vs `O(N×layers×area)`). Low priority.

### Rejected for symptom 1 (don't chase)

- *"N composites per raw pointer sample."* Overstated — coalesced to once per render frame.
- *"Make the canvas `Equatable` so the reconciler skips it."* Wrong lever — the dominant
  cost runs in `EditorView.body` itself, which self-invalidates by reading `revision`
  (`ViewGraph.swift:1626,1630` disqualify a self-invalidated node before any `Equatable`
  check). Memoize the composites, not the view.
- *The `2b62650` god-object split and the `c80a4aa` Canvas-API adoption* — both verified
  behavior-preserving; neither introduced the cost.

---

## Symptom 2 — the quit popover "basically (but not actually) freezes"

### What the popover actually is (corrected)

The quit key is **`Ctrl+Q`**, set explicitly at `GIFEditorApp.swift:24`
(`.exitOnKeys([Ctrl+Q])`). `Ctrl+D` (byte `0x04`) parses as `KeyPress(.character("d"),
.ctrl)` (`TerminalInputParser.swift:71-76`) → the **Duplicate-frame** command
(`EditorKeyBindings.swift:80`); it does **not** open the popover and is not EOF. The popover
is the **Save-before-quit sheet**: `Ctrl+Q` on a dirty doc → `.userExit`
(`RunLoop+EventDispatch.swift:65`) → `onTerminationRequest` presents the sheet and returns
`.cancel` (`EditorKeyBindings.swift:234-243`). *(If you really do see it on Ctrl+D, that's a
separate binding question — flag it and we'll dig in.)*

**It is not a hang/livelock.** After `.cancel` the run loop issues one invalidation and
blocks on stdin (`RunLoop.swift:418-422`). The process is alive and idle. The "frozen" feel
is real latency, from two places:

### RC-A (sustained) — every keystroke in the path field re-runs the full editor body

The sheet's `TextField` is bound to EditorView-owned `@State savePathText`
(`EditorView.swift:44,211`; `SaveGIFSheetView.swift:94`), and `.onChange(of: pathText)`
writes EditorView's `@State overwriteSaveConfirmed`. Each keystroke invalidates the
**owner node (EditorView)** → re-runs `EditorView.body` → the RC-1/RC-2 flatten storm,
**under the sheet, per keystroke.** A second path piles on: for a handled key with a local
handler, the runtime calls `requestInvalidation(of: [rootIdentity])` unconditionally
(`RunLoop+EventDispatch.swift:82`), which forces a full-tree eval
(`FrameResolveState.swift:216,230-233`). That line is a **datable core regression**
(`aae4f797`, "layout demo scroll position", 2026-04-25 — previously there was no root
invalidation on the handled-key path).

### RC-B (the one-shot stall, most likely what you feel on a real GIF)

`presentSaveSheet` calls `SaveGIFPreview.make(from:)` **synchronously on the main actor**
at `EditorView.swift:70`, *before* flipping `isSaveSheetPresented`. `make`
(`SaveGIFSheetView.swift:14-37`) does a full `GIFEncoder.encode` (LZW over all frames) **+**
`GIFLoader.load` decode round-trip **+** `flattenedColors` for every decoded frame —
`O(frames × layers × area)` twice. For the default 32×32, 1-frame doc this is sub-ms; for a
real multi-frame imported GIF it's a visible main-thread stall **right as the popover
appears** → "popover displays, app freezes, then recovers." Introduced whole in `4596920`
(2026-06-08), not a `ba4bbbd` original.

### Rejected for symptom 2 (don't chase)

- *Run-loop spin/livelock* — disproven; one invalidation then blocks on input.
- *The preview ticker storms the editor* — false. `runPreview` early-exits unless
  `frames.count > 1` (`SaveGIFSheetView.swift:187`), and `previewFrameIndex` is sheet-local
  `@State` that re-renders only the ≤32×32 sheet node, not `EditorView`.
- *Per-keystroke encode re-runs the full round-trip* — false on this path; `make` is
  one-shot at present, `savePreview` is non-nil after, so the `:210` `??` fallback
  short-circuits.
- *Ctrl+D Duplicate shadows the exit key* — no collision; distinct documented bindings.

---

## Fix plan (ranked, with the correctness traps the verifiers surfaced)

### Fix 1 — memoize per-frame composites + thumbnails on `EditorViewModel` (fixes RC-1, RC-2, and the RC-A typing lag)

Cache `flattenedColors`/thumbnails keyed on **frame content** (layer pixels + visibility) +
`document.size` + palette identity. Invalidate only the edited frame on mutation; rebuild
others from cache. Drops per-render timeline cost from `O(N×layers×area)` to
`O(layers×area) + O(N)` cache reads. `TimelineFrame`/`Thumbnail` are `Equatable`, so output
is byte-identical.

**Traps (do not):**
- ❌ Key on `frame.id` alone — `EditorFrame.id` is a stable `let UUID` (`Document.swift:28`),
  so the frame being drawn returns a stale thumbnail. Key on **content**.
- ❌ Use an index-keyed cache — `resizeCanvas` (`:575`), `setAllFrameDelays` (`:407`),
  undo/redo `restore` (`:648`), insert/dup/delete/select (`:355,371,383`), and palette edits
  all break the index→frame mapping. The key must be content-based with a wide invalidation
  surface.
- For RC-2's incremental path: ❌ re-stamp only the *active* layer's dirty rect.
  Compositing is bottom-to-top with transparency (`Document.swift:101-105`) and the active
  layer isn't necessarily the top one; eraser writes `nil` which must let lower layers show
  through. Re-run **all visible layers within the dirty rect**. Do the
  document-version memoization first (skip the flatten entirely on non-mutating refreshes:
  cursor moves, hover, menu toggles), then layer in dirty-rect incrementalization.

**Cheap complementary step:** gate the timeline compute, not just its render —
`let timelineFrames = showsTimeline ? (...).map { ... } : []` at `EditorView.swift:75-80`.

### Fix 2 — present the save sheet immediately, compute the preview in the background (fixes RC-B)

Present with `savePreview == nil` + a "preparing preview…" state; run `make` in a
`Task`/`.task(id:)` (both `GIFDocument` and `SaveGIFPreview` are `Sendable`); assign on
completion. **Traps:** keep `SaveGIFSheetView.preview` optional (a nil render must not
re-trigger the sync encode); gate `canSave`/Save behind an `isPreparing` flag; key the async
result on a document hash so a stale in-flight preview is discarded. `model.save` re-encodes
independently, so saving stays correct.

### Fix 3 — `resolvedPixels` single-eval (fixes RC-3 + hover cost)

Hoist `let resolved = resolvedPixels` to the top of `CanvasSurfaceView.body` and pass to
both call sites (`CanvasView.swift:51,58`). Pure local refactor; add an explicit
`return ZStack(...)` once the body has a leading `let`. Byte-identical.

### Fix 4 (optional, low priority) — narrow the history deep-compare

`EditorHistory.commit` does `document != before.document` (`:152`) — a full structural `==`
over all frames/layers/pixels, **once per stroke commit** (not per move; `==` short-circuits
at the first diff, so the full walk only happens on a true no-op stroke). Compare only the
touched frame + a cheap top-level check. **Trap:** do **not** replace it with an
unconditional dirty flag in `mutateCurrentLayer` — that would push spurious undo entries and
falsely set `isDirty`, which gates the Ctrl+Q quit-confirm sheet (a behavior regression
touching symptom 2). Keep `EditorViewModelTests` undo/dirty cases green.

### Fix 5 (optional, core; secondary to Fix 1) — narrow the per-keystroke root invalidation

`RunLoop+EventDispatch.swift:82` forces `requestInvalidation(of: [rootIdentity])` on every
handled key. **Traps:** don't just guard it behind `if handled` (TextField edits return
`handled`); don't narrow the `.cancel`-path invalidation (`RunLoop.swift:419`) to the portal
identity (contradicts the anti-pattern note at `ViewGraph.swift:637-645`). Fix 1 makes this
moot for gifeditor because the body reuses cached composites regardless. Ship Fix 1 first and
independently. Note: a related core commit `36a1a46b` ships `SWIFTTUI_INVAL_TRACE` for
attributing these invalidations.

---

## Verification plan

**Drawing lag:** run gifeditor, resize to 64×64, add 8-10 frames; drag a continuous stroke;
confirm lag scales ~linearly with frame count (10 frames ≈ 10× the 1-frame per-render
composite). Instrument `EditorView.swift:74-80` with `SWIFTTUI_FRAME_TRACE` (env-gated sink
already exists); confirm one body re-eval per *rendered* frame and `O(N)` flatten calls.
After Fix 1: flatten calls per re-eval drop to 1 + N cache reads; diff `TimelineFrame`
Equatable values to prove byte-identical output.

**Quit popover:** confirm bindings first — `Ctrl+D` Duplicates, `Ctrl+Q` (dirty) opens the
sheet. Open the sheet over a large multi-frame GIF; time `SaveGIFPreview.make` before/after
Fix 2 (present-time stall gone, `canSave` gated during "preparing"). Type in the path field;
after Fix 1, per-keystroke latency drops to cache-read cost. Use `SWIFTTUI_INVAL_TRACE`
(`36a1a46b`) to confirm whether the per-keystroke invalidation is `force-root` vs
reader-attributed.

**Tests to add:** thumbnail-cache correctness across every mutation path (stroke, resize,
delays, layer add/del/toggle, frame insert/dup/del, undo/redo, palette edit) asserting the
cached set equals a fresh full recompute; current-frame dirty-rect patch == full
`flattenedColors` across multi-layer/eraser/below-opaque cases. Keep `EditorViewModelTests`
undo/dirty invariants green.

**Gate before commit:** `bazel test //:examples_pretag_native_gate` (or the example's
`check_examples.sh`); full org gate `bazel test //:org_full`. From an activated mise shell
or `mise exec --`.

---

## Open empirical check (single highest-value)

Run gifeditor on a dirty multi-frame doc and, with `SWIFTTUI_INVAL_TRACE` +
`SWIFTTUI_FRAME_TRACE` on: (a) confirm `Ctrl+D`=Duplicate vs `Ctrl+Q`=sheet; (b) confirm an
idle open sheet doesn't re-eval `EditorView` (ticker is sheet-local); (c) confirm typing the
path re-evals `EditorView` (RC-A). This validates the symptom-2 premise before any code
lands. Not yet performed (no interactive run in this environment).

---

## Implementation outcome (2026-06-25) — shipped fixes committed & pinned; deferred items preserved

> **Status update (2026-06-25, re-verified against HEAD):** when first written, this section read
> "all changes UNCOMMITTED." That snapshot is superseded. The shipped fixes below are now committed
> and recorded as org submodule pins (`swift-tui` `2126c6f4`, `swift-tui-examples` `8bfa8c3`), and
> the deferred multi-`.task` work has been recovered out of the (since-cleared) stash into a durable
> home. See
> [2026-06-25-swifttui-framework-limitations-task-lifecycle.md](2026-06-25-swifttui-framework-limitations-task-lifecycle.md)
> for the full preservation detail.

**Shipped (implemented, tested green):**

| Fix | Where | Validation |
|---|---|---|
| **Fix 1** — composite memoization | `EditorViewModel.compositedFrames()` (content-keyed cache) + `Document.flatten(_:)`/`flattenedColors(for:)` + `EditorView` wiring + `showsTimeline`-gated thumbnails | gifeditor 58/11 pass; adversarial review = SHIP |
| **Fix 3** — `resolvedPixels` single-eval | `CanvasView.CanvasSurfaceView.body` | same |
| **Fix 4** — history compare short-circuit | `EditorHistory.documentChanged(from:to:)` | same; undo/dirty tests green |
| **Fix 5** — per-keystroke root-invalidation narrowing | `swift-tui` `RunLoop+EventDispatch.swift` (mirrors `recordFollowUpInvalidation`; byte-identical w/ reader-attribution off) | core 2510/322 pass; review = SHIP |

Net: **drawing lag (symptom 1) fixed**; the *sustained* typing-lag part of symptom 2 (RC-A) is
fixed by Fix 1 + Fix 5.

**Deferred:**

- **RC-B (freeze-on-quit, large GIFs):** moving `SaveGIFPreview.make` off the main actor was
  attempted twice (a `.task(id:)` modifier and an unstructured `Task`). **Both deterministically
  hang the headless `PresentationRuntimeTests` Ctrl+S test** (`EXIT=124`) — the gate's
  `awaitCondition` waits for an async-driven frame that the scripted-input test RunLoop does not
  surface. Reverted to the original synchronous compute. The blocker is headless async-render
  observability, *not* anything gifeditor-specific. Freeze persists only for large multi-frame GIFs.

- **Framework "multiple `.task` per view node":** requested to make stacked `.task` modifiers
  coexist (the one-task-per-node assumption runs through ~8 layers incl. the public
  `LifecycleMetadata.task`). Fully implemented (metadata→`tasks: [...]`, per-task lifecycle diff,
  `LocalTaskRegistry`/`NodeHandlers`→`[Identity: [Registration]]`, `TaskRunner`→`(viewNodeID,
  descriptorID)` key, per-node task-modifier ordinal). New unit tests pass (two `.task(id:)` on one
  node → distinct descriptors, both run). **But it introduces a deterministic hang** in
  `animationFramesKeepTabHostedPaneSurfaceStable` (tab-hosted `PhaseAnimator`), not isolated after
  three bisect probes; reverting it restores the test. **It also would not unblock RC-B** (separate
  issue above). Reverted; the full implementation is **preserved durably** — recovered from the
  (since-cleared) stash into the pushed `swift-tui` branch `stash-recovery-multi-task-modifiers`
  (`1163d13e`) plus a committed forward patch
  ([2026-06-25-multi-task-per-node.patch](2026-06-25-multi-task-per-node.patch)) — for a future,
  dedicated effort with deeper lifecycle investigation.

**Update (2026-06-25):** all shipped fixes are now committed and recorded as org pins (`swift-tui`
`2126c6f4`, `swift-tui-examples` `8bfa8c3`); the working branch `integration/code-quality-refactors`
has since been deleted. The deferred multi-`.task` work lives on the pushed `swift-tui` branch
`stash-recovery-multi-task-modifiers` (`1163d13e`) plus the committed forward patch; RC-B has nothing
to recover (reverted to the synchronous `SaveGIFPreview.make`).
