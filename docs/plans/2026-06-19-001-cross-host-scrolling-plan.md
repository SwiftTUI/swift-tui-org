# Plan: Cross-host scrolling — pannable areas + page scroll fall-through

Status: **Implemented (2026-06-19)**. Spans repos (hence it lives in the
coordination root). Author: cross-host scrolling work (2026-06-19).

## 1. Problem

Scrolling did not work fully across host surfaces because *scroll-view
existence/extent* was not forwarded to every host, and because the only way to
move a `ScrollView` was a wheel (`.scrolled`) event:

- **Web:** the embedded canvas trapped the wheel (legacy `"capture"` default),
  so the surrounding page could not scroll when the pointer was over the
  embed — even over non-scrollable content.
- **iOS / Android:** a one-finger drag forwarded as `.dragged`, but the
  `ScrollView` *body* ignored `.dragged` (only the indicator thumb consumed it),
  so touch-drag did nothing — there was no pannable scroll area.
- **Surface contract:** per-region scroll-extent metadata (`scrollRegions`) was
  serialized only by the web (WASI) encoder; the Android (JNI) and native
  (SwiftUI) frame paths dropped it.

## 2. Design (unified)

One core capability — **publish per-region scroll extents on every
`SemanticHostFrame`** — plus **drag-to-pan in the core `ScrollView`** so all
touch hosts get panning from a single implementation.

### 2.1 Core: `ScrollView` body-pan (`swift-tui`)

`ScrollView`'s root-route pointer handler now also handles
`.down/.dragged/.up(.primary)` as a **direct-manipulation pan**
(`Sources/SwiftTUIViews/ScrollView/ScrollView.swift`):

- `.down`: claim the press **only when content overflows** an active axis
  (otherwise return `false` so the drag bubbles to a parent). Record a
  `ScrollPanAnchor { startCell, startOffset }` in `@State`.
- `.dragged`: recompute the offset from the anchor
  (`startOffset - (currentCell - startCell)`, so content follows the finger),
  clamped via the event's `scrollContext`.
- `.up`: clear the anchor.

The body region opts into `captureOnPress: true`
(`scrollViewMetadata`, `Sources/SwiftTUIViews/Modifiers/ViewMetadataModifiers.swift`)
so the runtime routes the whole drag stream to it. Gesture arbitration is free:
the runtime hit-test delivers `.down` to the deepest interaction region, so a
drag that starts on an inner control goes to that control, and only a drag on
plain scroll content reaches the scroll view. Anchoring (not delta-accumulation)
keeps panning correct across the re-resolve each scroll mutation triggers and
re-clamps cleanly at the edges.

This makes panning work on **iOS, Android, terminal mouse-drag, and macOS
mouse-drag** at once — every host already forwards touch/mouse drags as
`.down/.dragged/.up`. macOS trackpad/wheel still uses `.scrolled`.

### 2.2 Core: scroll extents on every host frame (`swift-tui`)

`RunLoop+Presentation.semanticSnapshotWithScrollOffsets` enriches each
`ScrollRoute.contentOffset` from the live `LocalScrollPositionRegistry`. It runs
on the `SemanticHostFrame` presentation path, which serves **all** retained
hosts (web, Android, native SwiftUI) — not just web. (The previous doc comment
implied web-only; corrected.)

### 2.3 Web host: default to `"chain"` (`swift-tui-web`)

`WebHostSceneRuntime`'s default `wheelMode` flips from `"capture"` to
`"chain"`: the inner view captures the wheel only while a scrollable region
under the pointer can still scroll in that direction; otherwise the wheel falls
through and the page (or parent iframe) scrolls. A scene with no `ScrollView`
never traps the wheel. Legacy `captureWheelInput` still maps `true → "capture"`,
`false → "passive"`. The standalone full-screen `WebExample` opts back into
`"capture"` explicitly (no page to scroll past); the marketing embed stays
`"chain"`.

### 2.4 Android: serialize + decode `scrollRegions`

`AndroidHostFrameEncoder` now emits `scrollRegions [{id, rect, offset, content}]`
(omitted when empty), and the Kotlin `SwiftTUIFrame` parser decodes them with
`canScrollUp/Down/Left/Right` headroom helpers and a `scrollRegionAt(col,row)`
hit-test. Basic touch panning already works via §2.1; this metadata is for
future native nested-scroll chaining (let an outer Android scroll view take over
at the inner region's edge).

### 2.5 Native SwiftUI: nothing to serialize

`HostedRasterSurface` (the SPI the SwiftUI host renders through) already delivers
the full enriched `SemanticHostFrame` to its `onFrame` callback, so the native
host receives `scrollRegions` in-process. iOS panning rides on §2.1 (the host
already forwards `touchesBegan/Moved/Ended` as `.down/.dragged/.up`).

## 3. Behavior matrix

| Host | Gesture | Result |
| --- | --- | --- |
| Web | wheel over scrollable region w/ room | inner scrolls (captured) |
| Web | wheel at region edge / non-scroll / no `ScrollView` | page scrolls (chains) |
| iOS / Android | touch-drag on scroll content | content pans (follows finger) |
| iOS / Android | touch-drag on an inner control | control's gesture wins |
| macOS / terminal | trackpad/wheel | `.scrolled` (unchanged) |
| macOS / terminal | mouse click-drag on scroll content | content pans (new, additive) |

## 4. Tests

- `swift-tui` `InteractiveRuntimeTests`: body drag pans the content; tap without
  movement does not scroll (real RunLoop, internal `@State`).
- `swift-tui` `HostedSceneSessionTests`: hosted (native/Android) surface receives
  live scroll offsets in its semantic frames.
- `swift-tui` `AndroidHostFrameEncoderTests`: `scrollRegions` serialize; omitted
  when empty.
- `swift-tui-web` `WebHostSceneRuntime.test.ts`: default mode is `"chain"`
  (captures with headroom, chains without); legacy flag mapping.
- `swift-tui-android` `SwiftTUIFrameTest`: parses `scrollRegions`, computes
  headroom, `scrollRegionAt` hit-test; absent → empty list.

## 5. Follow-ups

### 5.1 Done (2026-06-19, second pass)

- **Pan that starts on a control (drag-threshold takeover).** A drag that begins
  on an *armed* control (button/tap) and crosses a 2-cell threshold along a
  scrollable ancestor's dominant axis cancels the control and hands a captured
  pan to the scroll view — matching SwiftUI. Captured controls (sliders, scroll
  indicators, the scroll body) keep their gesture.
  `swift-tui/Sources/SwiftTUIRuntime/RunLoop/RunLoop+ScrollGestureTakeover.swift`
  (+ `dragStartLocation` tracking in `RunLoop` / `RunLoop+PointerHandling`).
  Because the run loop coalesces drag bursts, the takeover anchors the pan at the
  press origin and replays the drag, so a fast (coalesced) drag pans its whole
  delta instead of losing it to a deadzone — this also improves fast body-pans.
- **Sub-cell pan smoothing.** `ScrollPanAnchor` now anchors on the continuous
  (sub-cell) pointer location and rounds the fractional delta, so panning crosses
  a cell at the half-cell point on sub-cell hosts (iOS/native) instead of only at
  whole-cell boundaries. Cell-only hosts (cell-center fallback) are unchanged.
- **Native nested-scroll — Phase 1 (accessors).** Android exposes
  `state.frame.scrollRegions`, `frame.scrollRegionAt(col,row)`, and
  `region.canScroll{Up,Down,Left,Right}`. An integration breadcrumb at the
  Android gesture site documents how a consumer gates `change.consume()` for
  chaining.

### 5.2 Deferred (with rationale)

- **Momentum / fling — RESOLVED (2026-06-20).** Picked up and solved at the root;
  the synthetic-`.scrolled` path below was the corner, not the fix. See
  [`docs/proposals/2026-06-20-001-scroll-momentum-fling-architecture.md`](../proposals/2026-06-20-001-scroll-momentum-fling-architecture.md):
  a run-loop-owned `ScrollMomentumController` (physics integrator) ticked by the
  existing 33 ms animation deadline cadence pushes sub-cell-accumulated integer
  deltas through `LocalScrollPositionRegistry.scrollBy` — no synthetic events, no
  animation-system change, no `ScrollView` `body`. The original rationale is kept
  below for the record. Three compounding
  reasons it is not a clean drop-in: (1) the animation controller interpolates
  *render-time* animatable slots (opacity, `.offset`/`.position` layout, shape
  styles) by diffing placed trees — it does **not** re-run layout with
  interpolated inputs, and the scroll offset is a `ScrollViewLayout` input, so
  `withAnimation { scrollPosition = … }` will not glide. (2) `ScrollView` is a
  `PrimitiveView` with no `body`, so there is no natural place to attach a
  per-frame decay driver (`.task`/`TimelineView`); a driver would have to be
  injected into the resolved child tree or run from the run loop. (3) The run
  loop coalesces drag bursts, so reliable *release* velocity is hard to measure
  from the event stream. Recommended path when prioritized: drive fling from the
  run loop after a captured scroll-route `.up` — estimate velocity from the last
  drag delta over a frame interval, then post a decaying series of synthetic
  `.scrolled` events via `scheduler.requestDeadline`, stopping at the content
  edge or when a new touch arrives. Needs a deterministic clock hook for tests.
- **Native nested-scroll — Phase 2 (gesture delegation).** Deferred until a
  consumer embeds the host in a native scrollable. Correct chaining needs
  Compose `NestedScrollConnection` (Android) / a `UIPanGestureRecognizer`
  delegate deferring to an enclosing `UIScrollView` (iOS), validated against a
  real embedding — approximate raw-consume gating is untestable without one. The
  Phase 1 accessors above are the substrate it will build on.
- **iOS scroll-region exposure.** The native `HostedRasterSurface.onFrame`
  already delivers `scrollRoutes`; surfacing them to the `NativeTerminalSurfaceView`
  UIView (for Phase 2) is only worth wiring alongside a consumer.

## 6. Source references (relative to the coordination root)

- `swift-tui/Sources/SwiftTUIViews/ScrollView/ScrollView.swift` (body-pan)
- `swift-tui/Sources/SwiftTUIViews/ScrollView/ScrollViewSupport.swift` (`ScrollPanAnchor`, clamp)
- `swift-tui/Sources/SwiftTUIViews/Modifiers/ViewMetadataModifiers.swift` (`captureOnPress`)
- `swift-tui/Sources/SwiftTUIRuntime/RunLoop/RunLoop+Presentation.swift` (offset enrichment)
- `swift-tui/Platforms/Android/Sources/SwiftTUIAndroidHost/AndroidHostFrameEncoder.swift` (`scrollRegions`)
- `swift-tui-android/.../SwiftTUIFrame.kt` (`SwiftTUIScrollRegion`, `scrollRegionAt`)
- `swift-tui-web/packages/web/src/WebHostSceneRuntime.ts` (`"chain"` default)
- `swift-tui-examples/WebExample/src/frontend.ts` (standalone `"capture"`)
- `docs/proposals/EMBEDDED_WEB_SCROLL_CHAINING.md` (web scroll-chaining predecessor)
