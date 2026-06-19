# Proposal: Scroll-chaining for embedded SwiftTUI web views

Status: **Implemented (2026-06-03)** — predictive scroll-chaining via per-region
scroll-extent metadata. Swift produces offsets at the web-host present boundary
(`ScrollRoute.contentOffset`), serializes `scrollRegions` in the surface frame;
the TS host decodes them and `handleWheel` captures-or-chains in `"chain"` mode.
The WebExample marketing embed uses `wheelMode: "chain"`. Verified: the
WebExample's Animations/Images tabs use `ScrollView` (chaining is observable
there); the Game-of-life hero has none, so it stays fully passive (no scroll
trap). Unit tests on both sides green.

> **Update (2026-06-19):** `"chain"` is now the **library default** wheel mode
> (was `"capture"`), so any embed lets the page scroll past non-scrollable
> content without opting in; the standalone full-screen WebExample opts back into
> `"capture"`. The per-region scroll-extent metadata is now forwarded to **all**
> hosts (Android JNI + native SwiftUI), not just web, and the core `ScrollView`
> gained touch/pointer **drag-to-pan** for iOS/Android. See
> [`docs/plans/2026-06-19-001-cross-host-scrolling-plan.md`](../plans/2026-06-19-001-cross-host-scrolling-plan.md).
Scope (spans repos — hence this lives in the coordination root):
- `swift-tui` — `SwiftTUICore` semantics + `Platforms/WASI` surface encoder
- `swift-tui-web` — `@swifttui/web` host runtime + surface transport
- `swift-tui-examples` — `WebExample/src/frontend.ts` (reference embedding)
- `swift-tui-site` — `Website/src/components/DemoTerminal.astro` (iframe embed)
Author: scroll-capture investigation (2026-06-03)

Source references (paths relative to this coordination root):
- `swift-tui-web/packages/web/src/WebHostSceneRuntime.ts` (`handleWheel`, `cellLocation`)
- `swift-tui-web/packages/web/src/WebHostSurfaceTransport.ts` (frame schema + decoder)
- `swift-tui-examples/WebExample/src/frontend.ts` (`passiveEmbedOptions`)
- `swift-tui/Sources/SwiftTUICore/Semantics/SemanticSnapshot.swift` (`ScrollRoute`)
- `swift-tui/Sources/SwiftTUICore/Semantics/Semantics.swift` (scroll-route emission)
- `swift-tui/Sources/SwiftTUICore/Runtime/LocalScrollPositionRegistry.swift` (offset source)
- `swift-tui/Sources/SwiftTUICore/Place/LayoutEngine+Placement.swift:124` (contentBounds anchoring)
- `swift-tui/Platforms/WASI/Sources/WASISurfaceBridge/WebSurfaceFrameEncoder.swift` (frame serializer)
- `swift-tui/Sources/SwiftTUIRuntime/RunLoop/RunLoop+PointerHitTesting.swift` (`scrollTarget`)

---

## 1. Summary

When a visitor hovers the embedded SwiftTUI web demo and scrolls, the **outer
page** scrolls — the inner view never captures the wheel. Unlike an iframe with
its own scrollable document, the embedded canvas does not behave like a nested
scroll region.

This is **not a missing capability**. The `@swifttui/web` runtime already has
full wheel capture (`WebHostSceneRuntime.handleWheel`), and the standalone
`/webexample/` page uses it. The marketing embed **deliberately disables it**
via `captureWheelInput: false` in `passiveEmbedOptions`
(`frontend.ts:334`), with a test locking that in
(`WebHostSceneRuntime.test.ts:1148`, *"runtime can run as a passive embed
without stealing focus or wheel scroll"*).

The disable exists to avoid the **scroll-trap**: a full-bleed interactive widget
that always eats the wheel traps a visitor who is merely scrolling *past* it on
the landing page. Today we trade that away for "page always scrolls."

This proposal adds the in-between behavior the user asked for: **true
scroll-chaining**. The inner view captures the wheel *only while it can actually
scroll in that direction*; at its scroll boundary (or where there is no
scrollable region under the pointer), the wheel falls through to the page.
This is exactly how a well-behaved nested scroller / iframe behaves.

## 2. The hard constraint

Browser `wheel` handlers must decide `event.preventDefault()` **synchronously**,
in the same tick the event fires. But the SwiftTUI app runs in a **WASI worker**
behind a SharedArrayBuffer/stdin transport and emits surface frames
**asynchronously**. So the naive "forward the scroll, wait for the app to report
`consumed: true/false`, then decide whether to `preventDefault`" **cannot
work** — by the time any answer returns, the browser has already performed (or
not performed) its default scroll.

**Consequence:** chaining must be **predictive**, not reactive. The host must
already know, at wheel time, whether the region under the pointer can scroll in
the wheel's direction. That means the app must **publish its scroll extent** as
part of each surface frame, and the host decides capture-vs-chain from the
last-known extent. The price is one frame of staleness (≈16 ms), which is
imperceptible for scroll and self-corrects on the next frame.

This reframes the work: it is **not** "add a `consumed` backchannel" (which the
constraint forbids). It is "**publish per-region scroll extent in the surface
protocol, and teach the host to hit-test it synchronously.**"

## 3. What already exists vs. what's missing

Good news: most of the machinery is present.

**Already present (Swift):**
- `SemanticSnapshot.scrollRoutes: [ScrollRoute]` — one `ScrollRoute { identity,
  viewportRect, contentBounds }` per scrollable region
  (`SemanticSnapshot.swift:76`), emitted during snapshot construction
  (`Semantics.swift:101`).
- The runtime already hit-tests scroll the same way we'd need to: topmost route
  whose `viewportRect.contains(cell)` and whose content overflows in the delta
  direction (`RunLoop+PointerHitTesting.swift:42`, `scrollTarget`).
- Current scroll offset per region lives in
  `LocalScrollPositionRegistry.registrations[identity].currentOffset()` — a
  MainActor closure returning `ScrollOffset { x, y }`
  (`LocalScrollPositionRegistry.swift:16`), and the same registry holds
  `latestScrollRoutes` geometry (`:35`). The two are joinable on the MainActor.

**Already present (TS host):**
- `handleWheel` translates wheel → `scrolled` mouse input + `preventDefault`,
  gated by `captureWheelInput` (`WebHostSceneRuntime.ts:392`).
- `cellLocation` maps a pointer to a cell coordinate (`:807`).

**Missing — the gap to close:**
1. **`ScrollRoute.contentBounds` does not encode the current offset.** It is
   anchored at the viewport origin:
   `contentBounds = CellRect(origin: bounds.origin, size: contentSize)`
   (`LayoutEngine+Placement.swift:124`). So it tells us *total* content size vs
   viewport (⇒ "scrollable at all?") but **not** "how far am I scrolled?" ⇒
   directional chaining (down chains only at the bottom) needs the offset too.
2. **`scrollRoutes` are not serialized into the web-surface frame.** The encoder
   emits `rows/styles/images/damage/accessibilityTree/accessibilityAnnouncements`
   but no scroll metadata (`WebSurfaceFrameEncoder.swift`).
3. **The TS frame types carry no scroll metadata**, and `handleWheel` is
   all-or-nothing (`captureWheelInput` boolean) with no chaining decision.

## 4. Design

### 4.1 Surface-protocol extension

Add an optional, per-region scroll-extent array to the surface frame. Emit it
only when a frame has scrollable regions (so older decoders and
no-scroll-region scenes are unaffected; unknown fields are already ignored by
both decoders).

Wire shape (one entry per scrollable region currently on screen):

```jsonc
"scrollRegions": [
  {
    "id": "root/list",        // identity path (same key space as accessibilityTree ids)
    "rect": [x, y, w, h],     // viewport rect in cells — host hit-tests the pointer against this
    "up": true,               // can scroll further up    (offsetY > 0)
    "down": false,            // can scroll further down   (offsetY < maxY)
    "left": false,            // can scroll further left   (offsetX > 0)
    "right": true             // can scroll further right  (offsetX < maxX)
  }
]
```

**Decision (2026-06-03): ship raw offset + sizes**, host recomputes edges.
Each region carries `{ id, rect:[x,y,w,h], offset:[ox,oy], content:[cw,ch] }`.
The host derives `maxX = max(0, cw - w)`, `maxY = max(0, ch - h)` and the four
edge predicates — which **must match Swift's clamp exactly**
(`LocalScrollPositionRegistry`/`ScrollViewLayout`: `min(max(0, requested),
max(0, content - viewport))`). This keeps the wire shape flexible (host can do
partial-scroll/threshold math later) at the cost of a clamp formula duplicated
across the boundary — covered by a parity test on both sides. (Booleans were
the considered alternative; see §8.)

Revised wire shape:

```jsonc
"scrollRegions": [
  {
    "id": "root/list",        // identity path (same key space as accessibilityTree ids)
    "rect": [x, y, w, h],     // viewport rect in cells — host hit-tests the pointer against this
    "offset": [ox, oy],       // current clamped scroll offset
    "content": [cw, ch]       // total content size
  }
]
```

### 4.2 Host decision logic (`handleWheel`)

Replace the boolean gate with a small predictive hit-test:

```
on wheel(event):
  if mode == passive: return            // current marketing behavior, still available
  cell = cellLocation(event)            // pointer → cell
  region = topmost scrollRegion whose rect contains cell
           AND that can scroll in the wheel's direction
             (deltaY>0 ⇒ region.down; deltaY<0 ⇒ region.up;
              deltaX>0 ⇒ region.right; deltaX<0 ⇒ region.left;
              diagonal ⇒ either axis qualifies)
  if region exists:
     forward `scrolled` to app
     event.preventDefault()             // capture: inner view scrolls
  else:
     return WITHOUT preventDefault       // chain: page (or parent iframe) scrolls
```

Two host bugs to fix in the same pass:
- **Edge leak:** today `handleWheel` early-returns *without* `preventDefault`
  when `cellLocation` is `undefined` (pointer over sub-cell margin)
  (`WebHostSceneRuntime.ts:397`). Under "capture" mode that silently leaks
  scroll. Under "chain" mode the new logic makes this intentional, but we should
  make it explicit, not incidental.
- **`overscroll-behavior`:** add `overscroll-behavior: contain` to the canvas /
  mount as a backstop so a captured scroll never rubber-bands the page.

### 4.3 Host API surface

Generalize `captureWheelInput: boolean` into a mode while keeping the old flag
working (back-compat — it is part of `WebHostSceneRuntimeOptions`):

```ts
type WheelMode = "capture" | "chain" | "passive";
// captureWheelInput: true  → "capture"  (legacy, always eats wheel when over a cell)
// captureWheelInput: false → "passive"  (legacy, never eats wheel)
// new default for embeds    → "chain"   (eat only while the region can scroll)
```

`"capture"` stays the default for the standalone page (unchanged behavior);
the marketing embed opts into `"chain"`.

### 4.4 Swift-side production

At frame-build time on the MainActor (where `LocalScrollPositionRegistry` is
live), join each `ScrollRoute` with its current offset to compute the four
booleans, and carry them to the encoder. Concretely:

- Add a `ScrollExtent { identity, viewportRect, canUp/Down/Left/Right }` (name
  TBD) produced by the registry, which already owns both
  `latestScrollRoutes` and the per-identity `currentOffset()` closures
  (`LocalScrollPositionRegistry.swift:35,18`). Booleans:
  - `canUp = offset.y > 0`, `canDown = offset.y < max(0, content.h - viewport.h)`
  - `canLeft = offset.x > 0`, `canRight = offset.x < max(0, content.w - viewport.w)`
- Thread the extents onto the frame the encoder sees (either as a new field on
  `SemanticSnapshot`, mirroring `scrollRoutes`, or alongside `SemanticHostFrame`).
- Serialize in `WebSurfaceFrameEncoder` following the `accessibilityTree`
  pattern: append a `"scrollRegions":[…]` field only when non-empty. Keep the
  existing v1/v2 version gating; this is an additive optional field.

### 4.5 Example + site

- `frontend.ts`: in `passiveEmbedOptions`, swap `captureWheelInput: false` for
  the new `"chain"` mode for `?embed=marketing`. Keep
  `synchronizeAccessibilityFocus: false` (we still don't want the embed stealing
  keyboard focus on load).
- `DemoTerminal.astro`: the demo is an `<iframe>`. For chaining to reach the
  *landing page*, the wheel must fall through the iframe document. When the host
  declines `preventDefault`, the event acts on the iframe document; if that
  document is not itself scrollable, browsers chain to the parent. Verify the
  webexample body has no own scroll and set `overscroll-behavior` so the
  fall-through reaches the parent cleanly. (This is the one spot where the
  iframe boundary needs an explicit check — document a manual test.)

## 5. Behavior matrix (why this is the right UX)

| Pointer is over… | wheel direction has room? | Result |
|---|---|---|
| a scrollable region | yes | inner view scrolls (captured) |
| a scrollable region | no (at that edge) | page scrolls (chains) |
| non-scrollable content | — | page scrolls (chains) |
| the Conway demo (no ScrollView) | — | page scrolls — *identical to today* |

The marketing scene (Conway's Game of Life) has no `ScrollView`, so
`scrollRegions` is empty and the demo stays fully passive — **zero regression**
for the current hero. Chaining only ever "captures" over a genuinely scrollable
region with remaining travel. That is the iframe-like behavior the user wants,
without the scroll-trap.

## 6. Staged implementation plan

Each stage is independently testable; the protocol is additive so stages can
land incrementally.

1. **Swift extent model + production.** Add the extent type; have
   `LocalScrollPositionRegistry` compute the four booleans by joining routes +
   offsets; thread onto the frame. Unit-test the boolean math (at-top, at-bottom,
   mid, single-axis, content-fits-viewport ⇒ all false).
2. **Swift serialization.** Emit `"scrollRegions"` in `WebSurfaceFrameEncoder`
   (additive, version-gated). Golden-encode test; assert absent when empty.
3. **TS transport decode.** Add `scrollRegions?` to the v1/v2/v3 frame
   interfaces + decoder in `WebHostSurfaceTransport.ts`. Round-trip test.
4. **TS host decision.** `WheelMode` + predictive `handleWheel` + the edge-leak
   and `overscroll-behavior` fixes in `WebHostSceneRuntime.ts`. Tests: capture
   when region has room; chain (no preventDefault) at edge and over empty space;
   `passive`/`capture` legacy modes unchanged. **Update** the existing passive-
   embed test (1148) and add chaining cases.
5. **Example + site.** `frontend.ts` → `"chain"`; `DemoTerminal.astro`
   fall-through verification + `overscroll-behavior`. Manual cross-browser check
   that landing-page scroll resumes at the demo's scroll boundary.
6. **Gate.** `swift-tui` `bun run test`; `swift-tui-web` `bun run ci`;
   `swift-tui-examples` `bun run check` / `test:browser`; org `bazel test
   //:org_fast`. Bump pins per the org workflow.

## 7. Edge cases & risks

- **Staleness window.** Host decides from the previous frame's extents. Worst
  case: one wheel tick is mis-routed right at a boundary, corrected next frame.
  Acceptable for scroll; note it, don't over-engineer.
- **Nested scroll regions.** Mirror the Swift `scrollTarget` preference
  (topmost; explicit `ScrollView` over incidental scrollables) in the host
  hit-test so both sides agree on the target.
- **High-frequency frames.** `scrollRegions` is tiny (a few ints + 4 bools per
  region) and emitted only when regions exist; negligible on the per-frame path.
  Confirm it does not defeat delta-frame (v3) reuse — extents change only when
  geometry/offset changes.
- **Identity churn.** Region `id`s use the same identity-path space as
  `accessibilityTree`; reuse that encoder.
- **Touch / trackpad momentum.** This proposal addresses `wheel`. `touchmove`
  momentum on mobile is out of scope (the demo is desktop-oriented); flag as a
  follow-up if needed.
- **Worker vs main-thread transport.** Extents must be produced wherever the
  frame is, which is already the MainActor RunLoop owning the registry — no new
  cross-isolation hop.

## 8. Alternatives considered (and rejected)

- **Reactive `consumed` backchannel.** Rejected — violates the synchronous-
  `preventDefault` constraint (§2).
- **Just flip `captureWheelInput: true` for the embed.** Rejected — reintroduces
  the scroll-trap the passive mode was added to prevent.
- **Click/focus-to-activate gating.** A good, cheaper option (capture only after
  the user clicks in), but it is a *different* UX than the requested iframe-like
  chaining and was not the selected approach. Could layer on top later
  (activate-then-chain).
- **Recompute extents host-side from raw offset+size.** Rejected — duplicates
  clamp/edge math across the language boundary; ship the booleans.

## 9. Open questions for confirmation

1. Emit **booleans** (recommended) vs raw `offset + contentSize + viewport`?
2. Carry extents on `SemanticSnapshot` (mirrors `scrollRoutes`) vs a sibling
   field on `SemanticHostFrame`? (Encoder access differs slightly.)
3. Default mode for the **standalone** `/webexample/`: keep `"capture"`, or also
   move it to `"chain"` for consistency?
4. Is mobile `touchmove` chaining in scope now, or a follow-up?
