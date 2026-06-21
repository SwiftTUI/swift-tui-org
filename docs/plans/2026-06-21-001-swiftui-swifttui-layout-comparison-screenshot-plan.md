# Plan — SwiftUI vs SwiftTUI Layout-Comparison Screenshot + Discrepancy Analysis

- **Date:** 2026-06-21
- **Status:** Phase 0/1 BUILT & RUN (headless content-extent tier complete);
  geometry-primary GATE FAILED (see §8); raster-pixel tier deferred (needs the
  D2 cross-repo seam). Decisions D1/D2 locked; D3–D7 open.
- **Owner repo:** `swift-tui-org` (coordination root) — tooling, goldens, and reports
  live here; native-only exporter targets land in the public
  `swift-tui-examples` child.
- **Scope:** Capture a paired image of every SwiftUI-vs-SwiftTUI comparison in
  the layout gallery and analyze each for likely layout discrepancies.

> Forward-looking design doc per the org contract (`AGENTS.md` →
> "Public vs coordination contracts"). It may span child repos, so it lives in
> this root's `docs/plans/`, not in a child.

---

## 1. What is being compared

The "SwiftUI gallery" is the **`layouts-swiftui-demo`** app
(`swift-tui-examples/LayoutsSwiftUI/`). It renders **56 layout scenarios** across
**16 categories**, each authored *twice* against the same stable `id`:

| Package | Product | Engine | Catalog |
| --- | --- | --- | --- |
| `swift-tui-examples/layouts/` | `layouts-demo` | **SwiftTUI** (`import SwiftTUIRuntime`) | `Layouts.LayoutCatalog` |
| `swift-tui-examples/LayoutsSwiftUI/` | `layouts-swiftui-demo` | **native SwiftUI** (`import SwiftUI`) | `SwiftUILayouts.LayoutCatalog` |

Both catalogs are intentional mirrors: identical per-entry file names, identical
`id` set, differing only in the framework import. The two catalogs share all 56
ids — the load-bearing fact that makes id-keyed pairing reliable.

The comparison UI (`LayoutsSwiftUI/Sources/LayoutsApp/LayoutsApp.swift`) is one
native SwiftUI `WindowGroup`: a sidebar plus a two-pane detail
(`LayoutComparisonDetail`):

- **left pane** = native `entry.makeView()` (`.border(.red, width: 4)`)
- **right pane** = `EmbeddedTUILayoutSurface(entryID:)` — the **live SwiftTUI
  runtime** hosted in SwiftUI via `SwiftUIHostAppState<TUILayoutComparisonApp>` +
  `SwiftUIHostAppView` (`.border(.red, width: 4)`, `fontSize: 12`)

The single-entry render seam is `TUILayoutComparisonApp(entryID:)`; entry
selection in the app is interactive only (sidebar click / arrow keys), with no
CLI/env selector.

### Entry inventory (56)

By category: Stacks 5 · Frames & Sizing 8 · Padding & Safe Area 4 · Borders &
Overlays 6 · Offset·Position·Clip 4 · ZStack 3 · Spacers & Dividers 3 ·
Scrolling 3 · GeometryReader 3 · ViewThatFits 3 · Custom Layout 3 · Alignment
Guides 2 · Collections 3 · Shapes & Canvas 3 · Presentation × Layout 2 ·
Matched Geometry 1.

Tiers: 51 `behaviour`, 5 `smoke`. **3 interactive/animated** entries need special
handling: `matched.badge-move` (animated swap), `presentation.sheet-over-scroll`
(sheet), `presentation.alert-anchor-stable` (alert).

---

## 2. The four capture seams

Discrepancy detection does **not** have to be a fuzzy pixel score. There are four
seams; the cheapest are also the most rigorous.

| Seam | Mechanism | Output | Determinism |
| --- | --- | --- | --- |
| **SwiftTUI geometry** | `DefaultRenderer().render(view, context:, proposal:) → FrameArtifacts`; walk `PlacedNode.bounds: CellRect` + `SemanticSnapshot` rects | integer-cell rects (JSON) | zero-flake, headless, no TTY (already powers 50+ `layouts` behaviour tests via `RenderSupport.swift`) |
| **SwiftUI geometry** | `ImageRenderer` pass + `GeometryReader`/`AnchorPreference` measuring overlay keyed by `marker` + structural ordinal; ÷10 → cells | per-element rects (JSON) | headless; **highest-uncertainty piece** (see §6) |
| **SwiftTUI pixels** | `NativeRasterSurfaceRenderer.draw(…)` into an offscreen **flipped** `CGContext` (the exact on-screen rasterizer) | PNG | headless; needs `@_spi(Raster)` seam (D2) |
| **SwiftUI pixels** | `ImageRenderer` at 10pt/cell → PNG (`LayoutScale.cell == n*10`) | PNG | headless, no window server |

Supporting facts:
- `ImageRenderer` is available (package targets macOS 15; `ImageRenderer` is
  macOS 13+). The dead `LayoutDetailHost.swift` already gestures at it
  (`@State var imgRenderer: ImageRenderer?`, `makeView().frame(width:500,height:500)`).
- The SwiftTUIHost raster pipeline is fully decoupled from on-screen
  presentation: `NativeRasterSurfaceRenderer.draw` takes an arbitrary
  `CGContext`; `HostedSceneSession` + `HostedRasterSurface` run a SwiftTUI app
  with **no terminal** and expose `@_spi(Runners) waitForSurface/waitForFrames`
  for poll-free frame settling (template: `swift-tui/Tests/.../HostedSceneSessionTests.swift`).
- Bundled font (`AnonymiceProNFP`, registered process-scoped via `Bundle.module`)
  gives machine-independent glyph metrics — *provided the tool runs inside the
  SwiftUIHost SwiftPM resource bundle context*, else it silently falls back to
  `monospacedSystemFont` and breaks reproducibility.
- ImageMagick 7.1.2 (`/opt/homebrew/bin/{compare,magick}`) is installed with
  `DSSIM`/`SSIM`/`AE`/`PHASH`. **No golden images exist anywhere in the org** —
  this effort establishes the first visual baselines.

---

## 3. Recommended system (decisions locked)

**D1 — Tiered build (locked).** Ship the faithful raster artifact first, then add
the rigorous geometry analyzer gated on a de-risk spike.

**D2 — `@_spi(Raster)` seam (locked).** Add a small `@_spi(Raster)`
`renderLatestSurfaceToCGImage(scale:)` to `swift-tui-swiftui` that builds
`NativeTerminalMetrics(style:)`, makes a flipped offscreen `CGContext`, and calls
the existing `NativeRasterSurfaceRenderer.draw(…)` full-repaint. This reuses the
*exact* on-screen rasterizer, so the captured SwiftTUI bitmap equals the embedded
right pane pixel-for-pixel. Consumed via the normal tagged dependency;
`@_spi`-gated so it is not stable public API.

The system is three layers:

| Layer | Mechanism | Role |
| --- | --- | --- |
| **Tier 1 — Evidence (ship first)** | `ImageRenderer` PNG (SwiftUI) + `@_spi(Raster)` offscreen PNG (SwiftTUI) → ImageMagick `DSSIM`/`AE` heatmap + `montage` contact sheet, ranked by DSSIM; optional LLM vision pass | "Here are all 56 paired screenshots + where they drift" |
| **Tier 2 — Primary signal (spike-gated)** | SwiftTUI `PlacedNode` CellRects vs SwiftUI measured frames, paired by `(marker, ordinal)` → per-element `(dx,dy,dw,dh)` cell deltas, PASS/WARN/FAIL | precise, named, machine-diffable discrepancy tables |
| **Tier 3 — Fallback (manual)** | clone `Scripts/screenshot_gallery.sh` → drive the real `layouts-swiftui-demo` window, down-arrow ×56, `screencapture` the window | exercises the real composed embedding; hand-drives the 3 interactive entries |

Why this order: Tier 1 literally answers "capture screenshots of each comparison"
and produces the review surface in days. Tier 2 is where "analyze for likely
layout discrepancies" becomes quantitative — but it carries the only real
build risk, so it is gated on Phase 0.

---

## 4. Phased plan

### Phase 0 — De-risk spike + parity guard (0.5–1d)
Prove the one uncertain mechanism before building the full sweep.
- Assert `LayoutCatalog.all.count == 56` on **both** packages (count via `.count`,
  not grep — the `id:` grep yields 57 because of the `LayoutEntry.id` property /
  `entry(id:)` lookup).
- Pin the canonical scale: render SwiftUI at **10pt isotropic per cell**
  (matching `LayoutScale.cell(_:)`, the helper the catalog authored frames with).
  Record the separate `cellWidth ×8` / `cellHeight ×10` extensions as a **known
  systematic horizontal anisotropy** to subtract/flag — not a per-entry delta.
- Spike the SwiftUI measuring overlay on 5 hard entries:
  `stacks.hstack-alignment-triad` (repeated/positioned `Text`),
  `frames.min-ideal-max-frame-clamp` (sizing),
  `shapes.circle-in-non-square-frame` (no `Text` marker → role/path pairing),
  `borders.nested-border-ordering` (overlay regions),
  `spacers.three-sharing` (gap arithmetic). Build `_LayoutMeasuringHost`
  installing `.coordinateSpace(.named("root"))` and collecting leaf frames via
  `AnchorPreference`/`onGeometryChange` keyed by `entry.marker` + ordinal; verify
  whether a two-phase measure-then-snapshot is needed inside one `ImageRenderer`
  pass.
- **Gate:** reliable on ≥4/5 → proceed to geometry-primary (Tier 2). Fragile
  (esp. shape-only) → keep Tier 1 raster as primary for those entries and treat
  geometry as "where available."
- **Deliverable:** go/no-go spike note in `docs/reports/`, the pinned
  scale/anisotropy decision, the id-parity test.

### Phase 1 — Tier 1 raster MVP (ship-first; ~2d after Phase 0 scale decision)
- **`@_spi(Raster)` seam** on `SwiftUIHostSceneHost` in `swift-tui-swiftui`
  (flipped sRGB premultiplied offscreen context; explicit pinned `scale`, **not**
  `NSScreen` — headless has no screen; `setShouldSmoothFonts(false)`;
  `BundledFonts.registerIfNeeded()`). Drive via
  `SwiftUIHostAppState(app: TUILayoutComparisonApp(entryID: id))` → `start()` →
  `await waitForSurface { … }` (poll-free, 2 stable frames).
- **SwiftUI PNG** via `ImageRenderer` inside
  `.frame(width: cols*10, height: rows*10, alignment: .topLeading)
  .environment(\.colorScheme, .dark)`, `scale=2`, `isOpaque=true`,
  rendered **without** the `.border(.red)` affordance, flattened onto the dark
  theme bg (`#1E222A`).
- **Differ/report (`swift-tui-org/tools/layout-diff/`):** normalize both PNGs to
  a common canvas (NorthWest/top-left anchored), run
  `magick compare -metric DSSIM` + `-metric AE -fuzz 8%`, emit AE heatmaps and a
  `magick montage` contact sheet (`swiftui | swifttui | heatmap` triples,
  captioned id + DSSIM), ranked DSSIM-descending → `results.csv` +
  `docs/reports/<date>-layout-comparison-sweep.md`.
- **Optional LLM pass (D7):** feed each triple + the three metrics +
  `entry.title`/category to an LLM prompted to name the likely layout-rule
  divergence.
- **Deliverable:** 56 paired PNGs + ranked contact sheet + committed report.

### Phase 2 — Tier 2 geometry exporters (spike-gated; 0.5d + 2–3d)
- **SwiftTUI geometry exporter (0.5d):** new `LayoutGeometryProbe` target in the
  public `layouts` package, reusing `RenderSupport.render()` verbatim. Flatten
  `PlacedNode` tree → `[{identity, kind, semanticRole, bounds, contentBounds}]` +
  `SemanticSnapshot.{interactionRegions, focusRegions, accessibilityNodes}`. Emit
  56 `<id>.swifttui.json`.
- **SwiftUI geometry exporter (2–3d, the bulk):** `SwiftUILayoutMeasure` target in
  the public `LayoutsSwiftUI` package, wrapping the Phase-0 overlay to emit
  `<id>.swiftui.json` = `[{marker, path, rect}]`, ÷10 → cells.

### Phase 3 — Cross-engine differ + tables (1.5d)
- In `tools/layout-diff/`: pair by `(marker, ordinal)`, fall back to role/kind +
  structural path for non-text elements; subtract the recorded 8-vs-10 horizontal
  anisotropy on x/width.
- Per entry: table `element | swiftUIRect | swiftTUIRect | deltaCells | class`,
  classify **PASS ≤1 cell / WARN 2 / FAIL ≥3 or structural mismatch**
  (`MISSING_IN_SWIFTTUI`/`MISSING_IN_SWIFTUI`); derive inter-element gaps for
  spacing entries. Use DSSIM as a secondary triage sort and cross-check.
- Emit deterministic JSON + Markdown report ranked by max-abs-delta.

### Phase 4 — Wiring + baseline ratification (0.5–1d)
- Non-blocking `mise run layout-diff` + `sh_binary` in root `BUILD.bazel`. **Not**
  in `org_fast`/`org_full`/`native_gates`.
- All ephemeral output → gitignored `.build/coordination/` in the root, **never**
  inside a submodule working tree (`tools/bazel/pin_cleanliness.sh` hard-fails
  `org_fast` on uncommitted/untracked submodule files).
- Clone `Scripts/screenshot_gallery.sh` → `tools/layout-screenshot-sweep.sh` as
  the **manual** Tier-3 fallback (launch the GUI app directly, force window
  geometry via osascript AX, walk 56 via down-arrow, `screencapture -R`).
- Manual review pass to ratify intended-engine-difference vs real-bug; commit
  accepted baselines under `tools/layout-diff/baselines/` (root, not child).

---

## 5. Discrepancy taxonomy

**Flagged:** position/alignment drift (`|dx|`/`|dy|` > 1 cell) · size/measurement
divergence (`|dw|`/`|dh|` > tol) · spacing/distribution mismatch (inter-element
gap) · structural/presence (missing/extra element) · clipping/overflow crop ·
paint/stacking order.

**Absorbed, not flagged:** off-by-one cell rounding (1-cell tolerance) · the
LayoutScale `×8` width vs `×10` height anisotropy (systematic factor subtracted) ·
resampling/AA raster noise (perceptual thresholds, never byte-exact) ·
animation/state-frame nondeterminism (3 interactive entries, WARN-excluded) ·
blank/elided frames (distinguished via `SWIFTTUI_FRAME_TRACE` ZEROART rows, not
treated as drift).

---

## 6. Key risks

1. **SwiftUI per-element frame collector** — the 56 native views have no
   `accessibilityIdentifier`; attribution rests on `marker` text + structural
   ordinal, may need two-phase measure-then-snapshot, and shape-only entries
   (circle/capsule/radial/canvas) fall back to fuzzier role/path pairing.
   **Phase 0 gates this.**
2. **Cross-engine commensurability is imperfect by construction** — isotropic
   `cell() ×10` authoring vs anisotropic terminal cells, and 10pt-square vs taller
   monospace cells in the raster tier. Normalization injects systematic +
   resampling error; **never assert exact parity.**
3. **Raster determinism** is OS/font/AA-sensitive — pin scale explicitly (no
   `NSScreen`), disable font smoothing, pin the macOS SDK; the SwiftTUI font path
   depends on `Bundle.module` resolving.
4. **Placement landmine** — any capture output inside a submodule working tree
   hard-fails `org_fast`. Ephemeral → `.build/coordination/`; tooling/goldens/
   reports → root tree only.
5. **macOS + AppKit + main-thread only** — no Linux CI lane; stays non-blocking,
   never a gate.
6. **First-ever baselines** — a manual ratification pass is mandatory before any
   regression mode is trustworthy; initial output is a triage report, not a gate.
7. **Catalog drift** — two duplicated catalogs, no compile-time parity link;
   assert `.count == 56` both sides up front.

---

## 7. Open decisions

- **D1 — Build shape:** ✅ **Tiered** (raster MVP → spike-gated geometry).
- **D2 — SwiftTUI raster capture:** ✅ **`@_spi(Raster)` seam** in `swift-tui-swiftui`.
- **D3 — Regression gate vs. report-only?** Recommendation: report-only/on-demand
  (the analysis report strongly warns against gating perceptual image diffs).
  Decides whether Phase 4 ratifies committed baselines.
- **D4 — Canonical capture geometry:** single fixed `cols×rows` for all 56, vs.
  per-entry sizes from authored frames, vs. auto-size to
  `SemanticHostFrame.preferredLayoutSize`.
- **D5 — Interactive entries:** initial-frame + WARN-exclude (default), vs. drive
  headlessly to a settle state, vs. hand-drive only in the Tier-3 fallback.
- **D6 — Tolerance policy:** PASS ≤1 / WARN 2 / FAIL ≥3 cells global, vs.
  per-category tolerances (shape/border-heavy entries inherently diverge —
  terminals can't draw sub-cell curves — and should be down-weighted).
- **D7 — LLM vision pass in v1?** vs. ship deterministic geometry tables +
  contact sheet first and add the LLM layer later as a decoupled step.

---

## 8. Execution status (2026-06-21)

Phase 0 + a reliable slice of Phases 1–3 were built and run this session,
**entirely headless with no cross-repo change** (`swift-tui` and
`swift-tui-swiftui` untouched).

**Done & verified:**
- **Parity guard (Phase 0):** `swift-tui-examples/LayoutsSwiftUI/Tests/LayoutsSwiftUITests/CatalogParityTests.swift`
  — 4 tests pass: both catalogs hold exactly 56 entries, identical id set,
  identical order, identical per-id markers. The pairing premise is now
  machine-verified.
- **De-risk spike (Phase 0):** `.../MeasuringOverlaySpike.swift` — proved
  `ImageRenderer` PNG capture + pixel-bbox content extent work headlessly.
- **SwiftTUI exporter (Phase 1):** `swift-tui-examples/layouts/Tests/LayoutsTests/LayoutComparisonExport.swift`
  (env `LAYOUT_EXPORT=1`) — 56 cell-bbox + cell-grid JSONs.
- **SwiftUI exporter (Phase 2, reduced):** the spike file with `LAYOUT_EXPORT_ALL=1`
  — 56 PNGs + pixel-bbox JSONs.
- **Differ + report (Phase 3, content-extent tier):** `tools/layout-diff/`
  (`run.sh`, `diff.py`, `README.md`) → `docs/reports/2026-06-21-layout-comparison-sweep.md`.
  IoU-ranked; PASS 13 · WARN 26 · REVIEW 16 · MISSING 1. Top finds:
  `padding.ignores-safe-area-bleed` (SwiftUI blank), `zstack.sized-by-largest`
  (SwiftTUI collapsed to 1 row vs 11), `offset.position-ignores-layout`
  (SwiftTUI 23 cells shorter).

**GATE RESULT — geometry-primary is NO-GO (the Phase-0 decision gate):**
Per-element SwiftUI geometry is **not headlessly automatable**. Pure
`AnchorPreference` composition can't observe un-instrumented descendants, and the
only composition-free route — SwiftUI's AppKit accessibility subtree via
`NSHostingView` — does **not** materialize in an offscreen test process (tried
borderless and off-screen key window + run-loop spin + `unignoredChildren`; both
yield only the host element, 0 markers). So Tier 2's per-element SwiftUI collector
(the ~2–3 day high-risk piece) is dropped. The system pivots to the plan's
fallback: **content-extent (bbox) IoU delta** as the reliable automatic signal,
SwiftTUI per-element CellRects available on the SwiftTUI side, and the contact
sheet for per-element human/LLM judgment. This vindicates the tiered choice (D1).

**Honest limits of the shipped tier:** content-extent IoU is a *triage ranking,
not a gate* — SwiftUI measures antialiased ink, SwiftTUI measures whole cells, so
small width/height deltas are noise; and the black-background pixel bbox can read
dark-on-dark SwiftUI content as MISSING. Both are resolved by the deferred
true-pixel tier.

**Deferred (the wise-stop boundary — cross-repo):** the D2 `@_spi(Raster)`
`renderLatestSurfaceToCGImage` seam in `swift-tui-swiftui` → true SwiftTUI pixel
PNGs → ImageMagick DSSIM/AE heatmap contact sheets, consumed pre-tag via the
coordination overlay. Plus the optional Tier-3 window-screenshot sweep (drives
the GUI app; needs Screen Recording perms).

**Repo state:** `swift-tui-examples` submodule is dirty (new native-only test
targets + a `Package.swift` test-target addition) — uncommitted, so `org_fast`'s
`pin_cleanliness.sh` will fail until these are committed **in the child repo**
then the pin recorded here. `swift-tui` / `swift-tui-swiftui` are clean. All
ephemeral capture output is under `/tmp/layout-probe/`, never in a submodule tree.

## 9. Provenance

Produced from a 9-agent exploration+design workflow over the org tree: 5 parallel
subsystem maps (comparison harness, native SwiftUI render, SwiftTUIHost raster,
headless capture infra, CI/placement constraints), a 3-approach design panel
(geometry-first / raster-diff / window-sweep), and a synthesis judge
(geometry-first 7.8 > raster-diff 7.0 > window-sweep 6.2 → hybrid). Precedent for
screenshots-as-report-artifacts: `docs/reports/2026-06-18-android-interaction-sweep.md`.
