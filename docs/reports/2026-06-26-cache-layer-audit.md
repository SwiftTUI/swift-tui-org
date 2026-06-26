# SwiftTUI Cache Layer Audit

**Date:** 2026-06-26
**Scope:** `SwiftTUI/swift-tui` runtime/framework caches, host-side presentation
caches in `swift-tui-web` and `swift-tui-android`, and adjacent example/tooling
caches where they affect the user-visible UI-framework story.
**Method:** Read-only source audit of the current checkout. This report compares
the implemented cache stack against the cache layers normally expected in a
retained UI framework. No benchmarks were run for this report.
**Status:** Analysis only; no implementation changes.

---

## 1. Executive summary

SwiftTUI has a broad and deliberate cache stack. It is not a single memo table;
it is a chain of phase-specific retained state:

```text
resolve graph/dependencies
  -> text layout cache
  -> measurement cache
  -> retained layout/placement
  -> retained semantics/draw products
  -> raster damage/reuse
  -> image/resource caches
  -> host presentation caches
```

The strongest property is that most caches are **proof-gated**: entries are
reused only after identity, environment, transaction, structural, proposal, or
surface-compatibility checks. That fits the project's async frame-tail model,
where candidate frames can be cancelled, stale, or dropped.

The main cost is that SwiftTUI often chooses safety over broader reuse:

- production body memoization is `Equatable`-only;
- custom `Layout.Cache` state is short-lived in practice;
- retained frame-tail products come only from the last committed frame;
- raster reuse falls back to full repaint on several topology/metadata barriers;
- some image payload caches are bounded, while terminal protocol payload caches
  are not obviously capped.

This is a sound architecture for correctness. It is not yet as aggressive as the
cache stack of a mature general-purpose UI framework.

---

## 2. Pipeline context

The cache layers map directly to the documented phase model:

```text
resolve -> measure -> place -> semantics -> draw -> raster -> commit
```

`SwiftTUICore` documents the phase products and performance shape in
`swift-tui/Sources/SwiftTUICore/SwiftTUICore.docc/Rendering-Pipeline.md:5-119`.
The runtime documentation maps those products onto interactive scheduling:
`head -> animationInjection -> latePreferenceReconciliation -> fusedFrameTail ->
commit` in
`swift-tui/Sources/SwiftTUIRuntime/SwiftTUIRuntime.docc/Runtime-Render-Pipeline.md:8-18`.

The important design point is that cached products belong to specific phases.
The runtime explicitly distinguishes:

- renderer-private retained state and raster reuse hints;
- committed frame products;
- host-facing damage derived against the last surface that a host actually
  presented.

That separation is why the cache stack is conservative in several places.

---

## 3. Cache inventory

### 3.1 View graph, dependency indexes, and dirty-frontier reuse

The resolve layer is the most important retained cache. `ViewGraph` keeps the
persistent runtime graph, state slots, dependency indexes, dirty state, live
node IDs, resolved-node reuse state, and frame commit metadata. The field groups
are centralized in
`swift-tui/Sources/SwiftTUICore/Resolve/ViewGraphFieldGroups.swift`.

Key implemented layers:

- graph indexes for identity/node/path lookup;
- dependency indexes for state slots, environment reads, observables, and
  observable key paths;
- dirty state split into root invalidation, invalidated nodes, graph-local dirty
  nodes, and state mutation keys;
- live-node pruning and runtime registration fingerprints after commit;
- resolved-node reuse caches for explicit high-value surfaces such as toolbar
  strips.

Dirty-frontier planning avoids root evaluation when possible:
`swift-tui/Sources/SwiftTUICore/Resolve/ViewGraphDirtyEvaluationPlanning.swift`
selects dirty frontier nodes only when invalidated work maps cleanly into the
graph. Invalidation planning is similarly narrow:
`swift-tui/Sources/SwiftTUICore/Resolve/ViewGraphInvalidationPlanning.swift`
uses state read attribution, observable key-path attribution, and environment
dependency indexes.

The most explicit reusable resolved-node cache user is the toolbar strip:
`swift-tui/Sources/SwiftTUIViews/ActionScopes/Toolbar.swift:305-348` checks a
namespace/owner/signature cache, records the reused subtree, restores runtime
registrations, refreshes actions, and restamps structural path.

**Assessment:** this is stronger than a simple virtual-DOM diff cache. It is a
retained graph with dependency-aware invalidation. The expected layer is present.

**Tradeoff:** the graph deliberately avoids at least one possible frame-scoped
cache. `ViewGraph.swift:2081-2091` notes that structural invalidation checks are
`O(invalidated x depth)` per reuse candidate and could be reduced with a
frame-scoped ancestor cache, but that would add checkpointed mutable state on a
reuse-correctness path.

### 3.2 Production body memoization

SwiftTUI has memoized-body reuse, but production is `Equatable`-only.

Relevant source:

- `swift-tui/Sources/SwiftTUICore/Resolve/MemoReuseConfiguration.swift:1-16`
  says memo reuse is on by default but inert unless a view value is `Equatable`
  directly or through `EquatableView`.
- `swift-tui/Sources/SwiftTUICore/Resolve/MemoValueComparator.swift:1-27`
  says the production comparator is `Equatable`-only; the reflective comparator
  is DEBUG-only and must not get a release caller.
- `swift-tui/Sources/SwiftTUICore/Resolve/ViewGraph.swift:1613-1673`
  accepts memo reuse only when the node is fresh enough, not dirty, not
  self-invalidated, dependency coverage is safe, and `compareEquatable(...)`
  returns `.equal`.

**Assessment:** this is a real memoization layer, but narrower than many mature
UI frameworks. Frameworks with private runtime knowledge often memoize more
non-`Equatable` body inputs through structural comparison, POD checks, identity
checks, or internal value tracking. SwiftTUI intentionally declines that path.

**Tradeoff:** this is a soundness/performance trade. It avoids reflective
overhead and avoids trusting ambiguous closure/existential/opaque value
comparisons, but it misses automatic reuse for many pure non-`Equatable` views.

### 3.3 Text layout cache

`TextLayoutCache` is a process-lived shared cache:
`swift-tui/Sources/SwiftTUICore/Content/TextLayoutCache.swift:61-93`.

Key behavior:

- default capacity is 256 entries;
- key includes content string plus `TextLayoutOptions`;
- memory metrics report entries, access-log depth, lookups, hits, misses,
  evictions, and bypassed stores;
- hits update generation;
- misses compute uncached layout;
- when full, first-time keys are bypassed and recorded as admission candidates;
  a second sighting admits them;
- access-log compaction prevents hit-heavy workloads from growing the log
  without bound (`TextLayoutCache.swift:251-260`);
- eviction is generation/LRU-ish (`TextLayoutCache.swift:277-293`).

**Assessment:** this is an expected and well-shaped UI cache. For terminal UI,
text measurement/layout is a hot path, and the admission policy is sensible for
animation or shimmer workloads with one-off text values.

**Tradeoff:** the two-sighting admission policy can under-cache large rotating
sets where a text value repeats only after it has fallen out of the admission
window. That is likely a good trade for terminal output, but it is not a
universal text-cache policy.

### 3.4 Measurement cache

`MeasurementCache` stores measured subtrees by runtime node ID and proposal:
`swift-tui/Sources/SwiftTUICore/Measure/MeasurementCache.swift:4-39`.

Key behavior:

- lookup requires a `viewNodeID`;
- cached measurement must be equivalent for measurement before reuse;
- stale entries are evicted during lookup;
- each node is capped at four proposal variants
  (`MeasurementCache.swift:22`);
- entries are pruned to live `ViewNodeID`s after commit
  (`MeasurementCache.swift:148-156`);
- reset advances generation and clears metrics.

The default renderer wires a `LayoutEngine(cache: MeasurementCache())`, and the
layout work stack tries retained measurement, then the cache, then a fresh
measurement.

**Assessment:** this is the expected layout measurement cache for a retained UI
framework. It is correctly keyed by identity and proposal, and it verifies the
resolved input before reuse.

**Tradeoff:** the four-proposal cap bounds memory but may churn in layouts that
probe many proposals per identity: `ViewThatFits`-style logic, dynamic grids,
custom layouts, or responsive layouts that measure under several constraints.
This should be measured before changing; the cap is probably right for common
terminal layouts.

### 3.5 Retained layout, placement, semantics, draw, and raster state

`FrameTailRetainedState` is the runtime's cross-frame cache for frame-tail
products:
`swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailRetainedState.swift:4-22`.

It stores:

- previous committed retained layout index;
- previous drawn identities;
- previous committed raster surface;
- previous surface topology;
- previous semantic/draw phase products.

It explicitly never stores or previews in-flight candidate frames. Retained input
is built only from previous committed state:
`FrameTailRetainedState.swift:58-75`.

On commit, it indexes the baseline pre-overlay layout tree, stores raster and
topology, and retains semantic/draw products only when the effective and baseline
signatures match:
`FrameTailRetainedState.swift:90-128`.

Retained layout reuse applies additional guards in
`swift-tui/Sources/SwiftTUICore/Measure/LayoutEngine+RetainedLayout.swift`.
Retained phase extraction is guarded by a compact signature in
`swift-tui/Sources/SwiftTUICore/Commit/RetainedPhaseExtraction.swift`; unsafe or
hard-to-prove cases such as canvas, foreign surfaces, and custom layout behavior
are excluded.

**Assessment:** this is a strong retained-mode cache layer. It covers more than
measurement: it can avoid placement, semantics, draw extraction, and raster work
when proofs hold.

**Tradeoff:** the last-committed-only rule is conservative. It prevents
candidate-frame or skipped-frame state from corrupting future reuse, but it also
means speculative completed work cannot warm the cache. Excluding custom,
canvas, and foreign-surface cases is similarly safe but leaves graphics-heavy
and extension-heavy apps with less reuse.

### 3.6 Custom `Layout.Cache`

The public layout protocol exposes a SwiftUI-like cache model:
`swift-tui/Sources/SwiftTUIViews/Layout/CustomLayout.swift` defines
`makeCache`, `updateCache`, `sizeThatFits`, and `placeSubviews`.

The erasure layer has two paths:

- `SendableLayoutWorkerProxy` keeps a mutex-protected map by identity/proposal
  (`CustomLayoutErasure.swift:123-135`) and prepares/stores cache around worker
  measurement/placement (`CustomLayoutErasure.swift:248-269`);
- `LayoutProxyBox` keeps a main-actor dictionary by identity/proposal
  (`CustomLayoutErasure.swift:281-340`).

Both paths discard cached states for an identity after placement:

- worker path: `CustomLayoutErasure.swift:272-278`;
- main-actor path: `CustomLayoutErasure.swift:435-448`.

**Assessment:** the API layer is present, but the implementation treats custom
layout cache mostly as pass/proposal-local state. Cross-frame wins come from
measurement/placement reuse signatures and retained layout, not from a durable
custom `Layout.Cache`.

**Tradeoff:** this avoids long-lived arbitrary user cache state and actor-safety
problems, but it may surprise authors who expect SwiftUI-style custom layout
caches to survive across frames for a stable layout identity.

### 3.7 Raster damage and renderer-private reuse hints

`RasterSurfaceDamageDiff` derives host-facing damage only when surfaces are
compatible:
`swift-tui/Sources/SwiftTUICore/Raster/RasterSurfaceDamageDiff.swift:1-29`.

It falls back to full repaint when:

- no previous surface exists;
- surface size differs;
- attachments differ;
- metadata differs.

When compatible, it diffs cells, image attachments, and presentation-layer
topology (`RasterSurfaceDamageDiff.swift:16-94`).

`FrameTailPresentationDamageResolver` computes renderer-private raster reuse
hints, explicitly not the host-facing damage contract:
`swift-tui/Sources/SwiftTUIRuntime/Rendering/FrameTailPresentationDamage.swift:15-20`.
Topology changes usually force a fresh raster. Additive overlay bounded damage
exists behind `SWIFTTUI_OVERLAY_INCREMENTAL_DAMAGE=1`, with verification through
`SWIFTTUI_RASTER_VERIFY_INCREMENTAL=1`
(`FrameTailPresentationDamage.swift:194-203`).

**Assessment:** the expected damage/repaint cache is present and carefully
separated between renderer and host. That separation is essential for async
presentation correctness.

**Tradeoff:** the default path is more conservative than a layer-tree UI
framework. Presentation overlay/topology changes often become full-surface
reraster/repaint barriers unless the prototype flag is enabled.

### 3.8 Terminal presentation caches

The terminal host keeps presentation-session state:

- previous/last-submitted surface;
- pending writer frame;
- transmitted Kitty image IDs;
- force-full-repaint flags.

The planning layer can emit incremental row/range updates when the previous
surface is compatible and damage is safe. If image attachments differ and the
terminal cannot replay graphics incrementally, it falls back to full repaint.

**Assessment:** this is the expected terminal-specific equivalent of dirty rect
presentation. It is row/range based rather than layer/tree based, which matches
terminal output.

**Tradeoff:** graphics protocol limitations leak into the cache policy. Image
changes can force broad repaint/replay even when the logical UI change is local.

### 3.9 Image and resource caches

Image caching is mixed but mostly bounded.

`ImageAssetRepository` is process-lived and bounded:
`swift-tui/Sources/SwiftTUIRuntime/Terminal/ImageAssetRepository.swift:104-112`.

It has:

- up to 512 image resolutions;
- up to 256 decoded images;
- FIFO eviction, explicitly leaving LRU as a later refinement;
- resolution keys that include source, resource roots, and cell pixel size.

`ImageBlendCompositor` has a stronger bounded policy:
`swift-tui/Sources/SwiftTUIRuntime/Terminal/ImageBlendCompositor.swift:28-48`.

Default caps:

- 256 entries;
- 4 million decoded pixels;
- 16 MiB encoded bytes.

It tracks decoded and encoded hits/misses and updates access generation on hits:
`ImageBlendCompositor.swift:142-175`.

`TerminalImageRenderer` is different:
`swift-tui/Sources/SwiftTUIRuntime/Terminal/TerminalImageRendering.swift:40-45`
stores per-host Kitty payloads, Sixel payloads, and fallback overlays in
dictionaries. It reports occupancy through metrics
(`TerminalImageRendering.swift:69-95`) and caches payloads at
`TerminalImageRendering.swift:347-363`, `:384-395`, and `:422-439`, but there is
no obvious cap or eviction policy in the audited paths.

**Assessment:** decoded image and blend caches are expected and bounded. The
terminal protocol payload cache is the most obvious cache asymmetry in the
runtime.

**Tradeoff:** per-host payload caching avoids expensive re-encoding, but a long
session that cycles through many image variants can grow until the host is
released. Since adjacent image caches are already bounded, this stands out as an
implementation gap rather than a consistent policy.

### 3.10 Web and Android host caches

The web host has a canvas-side decoded image cache:
`swift-tui-web/packages/web/src/CanvasSurfacePainter.ts:55-67`. The painter keeps
only canvas handle, image cache, and redraw callback as durable state, and draws
only dirty regions when damage is available (`CanvasSurfacePainter.ts:82-120`).

**Assessment:** correct shape, but the decoded image `Map` is not obviously
bounded in the audited code.

The Android host keeps stronger presentation caches:
`swift-tui-android/swift-tui-host/src/main/kotlin/sh/swifttui/android/host/SwiftTUIRenderer.kt:20-59`.

It has:

- a retained grid bitmap and canvas;
- an 8 MiB `LruCache` of decoded image attachment bitmaps;
- damaged-row repaint into the retained bitmap;
- full repaint barriers when sequence continuity, size, image attachment, or
  full-repaint flags require it.

The Android damage planner requires sequence continuity before incremental
paint:
`swift-tui-android/swift-tui-host/src/main/kotlin/sh/swifttui/android/host/SwiftTUIDamagePlan.kt:3-12`.

**Assessment:** Android's cache story is good for a host package. It is
careful about skipped frames and bounds image memory.

### 3.11 Example and site caches

The file previewer example has a small directory entry cache:
`swift-tui-examples/file-previewer/Sources/FilePreviewerApp/DirectoryEntryCache.swift:3-54`.
It is a main-actor LRU-ish cache with a default capacity of 32 and explicit
invalidate/retain-only APIs.

The site package uses deployment HTTP cache headers:
`swift-tui-site/Website/public/_headers:17-46`.
HTML revalidates; hashed Astro/DocC/WebExample assets are cached aggressively.

**Assessment:** these are app/deployment caches, not framework runtime caches.
They do not materially change the SwiftTUI cache architecture.

---

## 4. Expected UI-framework cache stack comparison

| Expected cache layer | SwiftTUI status | Assessment |
| --- | --- | --- |
| Persistent identity graph and state retention | Present | Strong retained graph with state slots, dependency indexes, and dirty-frontier planning. |
| Dependency-driven invalidation | Present | Stronger than broad owner invalidation when reader attribution and precise observation are enabled. |
| Body/input memoization | Partial | Production reuse is `Equatable`-only; no release structural/POD/reflection path. |
| Text layout/shaping cache | Present | Good bounded text layout cache. No obvious deeper glyph/font run cache in the audited paths. |
| Measurement cache | Present | Identity/proposal keyed, equivalence-checked, live-node pruned. |
| Placement/layout retention | Present | Retained layout/placement exists with strict invalidation/equivalence guards. |
| Custom layout cache | Partial | API exists, but implementation mostly keeps cache only through measure/place for identity/proposal. |
| Semantics/accessibility cache | Partial | Retained semantic extraction exists when placed-tree proof holds; accessibility announcements are stripped before retention. |
| Display-list/draw cache | Partial | Retained draw products exist under strict signatures; custom/canvas/foreign cases excluded. |
| Raster/backing-store cache | Present | Previous raster surface, damage diffing, row/range terminal updates, host dirty rects. |
| Layer-tree/topology cache | Partial | Presentation topology is tracked, but topology changes are often full-raster barriers by default. |
| Image decode/resource cache | Present | Core decoded image and blend caches are bounded; some host/payload caches are not. |
| Memory-pressure adaptive eviction | Mostly missing | Caches expose metrics and fixed caps, but no broad adaptive policy was found. |
| File/resource freshness invalidation | Partial/missing | Path image cache keys do not obviously include mtime/content freshness; static assets are assumed. |
| Virtualized list cell recycling/prefetch | Partial/not obvious | Lazy/viewport behavior exists elsewhere, but no broad recycler/prefetch cache surfaced in this audit. |

---

## 5. Missing or underdeveloped layers

### 5.1 Broader production body memoization

Expected mature-framework behavior: broad automatic skip of pure body work when
inputs have not changed.

Current SwiftTUI behavior: safe `Equatable` opt-in only.

This is one of the largest intentional performance gaps. The DEBUG reflective
comparator exists as an oracle, but the production path deliberately avoids it.
That is defensible; it also means framework containers and many pure author
views cannot get automatic body skip unless authors opt in.

Recommendation: do not add broad reflection by default without fresh perf and
soundness evidence. If this is pursued, keep it behind a measured gate and start
with narrow high-value container cases rather than a general `Mirror` path.

### 5.2 Persistent custom layout caches

Expected mature-framework behavior: stable custom layout identity can keep
layout-private cache state across frames, invalidated when subviews or relevant
inputs change.

Current SwiftTUI behavior: `Layout.Cache` exists, but the erased proxies discard
identity cache state after placement. Cross-frame wins depend on retained
measurement/placement signatures.

Recommendation: document the current lifetime clearly, or add a persistent
custom-layout cache policy with explicit invalidation and actor-safety rules.
This needs careful design because arbitrary author cache values can become a
memory and concurrency hazard.

### 5.3 Layer/display-list caching

Expected mature-framework behavior: layer trees, backing stores, display lists,
or retained render nodes can survive topology changes where the changed layer is
local.

Current SwiftTUI behavior: draw/semantic products are retained only when the
effective placed tree proves identical; surface topology changes commonly force
full raster by default.

Recommendation: promote the overlay incremental damage prototype only after
verification proves it sound across presentation layers, clipping, images,
effects, and removal animations. The existing `SWIFTTUI_RASTER_VERIFY_INCREMENTAL`
hook is the right shape.

### 5.4 Glyph/font/render primitive caches

Expected mature-framework behavior: text systems often cache glyph runs, font
metrics, shaped lines, color conversions, and render primitives below the layout
cache.

Current SwiftTUI behavior: a text layout cache exists, but this audit did not
find a deeper general glyph/font run cache. Terminal output may not need the same
layer as AppKit/UIKit, but native/web/Android hosts do perform repeated per-cell
text drawing.

Recommendation: measure before adding. If text drawing dominates host-side
profiles, add host-specific glyph/run caches rather than broad core complexity.

### 5.5 Adaptive cache pressure

Expected mature-framework behavior: caches often respond to memory pressure or
global budgets.

Current SwiftTUI behavior: many caches expose memory metrics and fixed caps, but
there is no obvious global pressure coordinator.

Recommendation: first add a cache occupancy report that groups all
`MemoryMetricRegistry` providers by subsystem. Only add adaptive eviction after
there is evidence that fixed caps are insufficient.

### 5.6 Resource freshness invalidation

Expected mature-framework behavior: file-backed resources either assume
immutability by design or include freshness keys such as mtime, inode, size, or
content hash.

Current SwiftTUI behavior: image source resolution and decoded image caches are
bounded, but path-backed image freshness is not obvious in the cache keys.

Recommendation: decide whether image assets are immutable during a process. If
not, include file freshness in `ImageAssetReference` or provide explicit
invalidators for preview/editing tools.

---

## 6. Unexpected tradeoffs

### Tradeoff A - Last committed frame only

Retained frame-tail state never previews candidate frames. This is the right
default for async cancellation and skipped-frame correctness, but it gives up a
possible speculative cache warm path.

Impact: cancelled or dropped frame work cannot seed future retained layout,
draw, or raster products.

Recommendation: keep this invariant. Any speculative cache warmup should be a
separate, clearly invalidatable structure, not folded into the committed retained
state.

### Tradeoff B - `Equatable` opt-in rather than private structural equality

SwiftTUI intentionally refuses to reflect over non-`Equatable` framework
containers in production.

Impact: fewer accidental unsound skips and lower comparator overhead; less
automatic body reuse than a mature private framework can provide.

Recommendation: keep broad reflection out of the release path unless profiling
shows a clear gap and a narrower proof can be built.

### Tradeoff C - Measurement proposal cap of four per node

The cache is bounded at a per-node level, which avoids unbounded memory growth
from probing layouts.

Impact: proposal-heavy layouts may churn even when their inputs are stable.

Recommendation: add a metric or debug counter that reports proposal-variant
evictions by node kind before changing the cap.

### Tradeoff D - Custom layout cache lifetime

`Layout.Cache` exists, but erased cache state is discarded after placement for
the identity.

Impact: author cache values are less durable than the API shape may imply.

Recommendation: either document this as a deliberate pass-local cache or add a
second, explicit persistent layout-cache layer.

### Tradeoff E - Conservative topology damage

Surface topology changes are mostly full-raster barriers by default.

Impact: overlays, menus, transitions, and presentation layers can invalidate more
work than a layer-tree UI framework would.

Recommendation: continue developing bounded overlay damage, but require
byte-for-byte verification before enabling it by default.

### Tradeoff F - Image cache policies are inconsistent

`ImageAssetRepository` and `ImageBlendCompositor` are bounded. Terminal protocol
payload maps are not obviously bounded. Web decoded image cache is also not
obviously bounded.

Impact: long sessions that cycle through many image variants can grow per-host
memory despite bounded lower-level image caches.

Recommendation: add LRU/count/byte caps to terminal payload caches and web image
caches, using the Android host's bounded bitmap cache as the host-side precedent.

### Tradeoff G - Runtime registration reuse is not fully narrowed

Some registry/effect publication paths still need broad restoration or
republishing when reused stable subtrees or island seams can hide changes.

Impact: commit-phase cache narrowing is intentionally incomplete.

Recommendation: treat this as a correctness boundary, not an easy optimization.
Any narrowing should come with a scoped-vs-full registration equivalence oracle.

---

## 7. Prioritized follow-up opportunities

| Priority | Opportunity | Why |
| --- | --- | --- |
| P0 | Bound `TerminalImageRenderer` payload caches | Clear asymmetry: adjacent image caches are bounded, protocol payload caches are not obviously capped. |
| P0 | Decide and document custom `Layout.Cache` lifetime | Current behavior may surprise layout authors; either document pass-local semantics or design persistence. |
| P1 | Add proposal-variant eviction diagnostics | Needed before changing the measurement cache's four-proposal cap. |
| P1 | Add path-image freshness or explicit invalidation | Static assets are fine; live preview/editor workflows need freshness semantics. |
| P1 | Promote overlay incremental damage only with verification | Highest raster-cache upside, but correctness-sensitive. |
| P2 | Explore narrow non-`Equatable` memoization targets | Start with measured container cases, not broad reflection. |
| P2 | Add a cache occupancy report across memory metrics | Low-risk way to see real cache pressure before adaptive eviction. |
| P2 | Consider host-side glyph/text drawing caches | Only if web/native/Android profiles show per-cell text drawing as a dominant cost. |

---

## 8. Verdict

SwiftTUI has the cache foundations expected of a retained UI framework:
persistent graph retention, dependency-indexed invalidation, text and layout
caches, retained frame-tail products, raster damage, image caches, and host
presentation caches.

What is missing is not a single cache. The gaps are mostly **aggressiveness and
policy**:

- fewer automatic body skips than mature private frameworks;
- less persistent custom-layout cache state than the public API shape suggests;
- conservative layer/topology damage;
- incomplete resource freshness semantics;
- inconsistent bounds on image payload caches;
- fixed local caps rather than global memory-pressure policy.

The current design is safety-first and coherent. The next tranche should keep
that character: add bounds and diagnostics first, then broaden reuse only where
verification can prove that the cached result is equivalent to a fresh frame.
