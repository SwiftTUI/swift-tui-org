# GeometryReader does not pump autonomous (non-input) animation frames

**Date:** 2026-06-06
**Scope:** `SwiftTUI/swift-tui` runtime — `GeometryReader` render/invalidation.
Real product bug: any animation driven by autonomous `@State` changes (e.g. a
`.task` loop) inside a `GeometryReader` never advances on screen.
**Severity:** High (silent — affected views render their first frame and then
freeze until the next input/layout event).
**Status:** Root-caused, not fixed. No clean consumer-level workaround found.
**Discovered while:** making `swift test` for the gallery example terminate
(the gated runtime/animation suites). Gating shipped at
`swift-tui-examples@67f24a1`; these tests run under `GALLERY_RUNTIME_TESTS=1`.

---

## Symptom

A view whose content lives inside a `GeometryReader` and is animated by an
autonomous (non-input) `@State` mutation — the canonical pattern being a
`.task { while … { try? await Task.sleep(…); state = next } }` loop — renders
its initial frame and then **produces no further frames**. The run loop only
re-presents on a terminal input event or a layout/resize trigger; the autonomous
`@State` invalidations originating under the `GeometryReader` do not cause a
`present()`.

In the gallery this manifests as **`PhysicsTab`'s gravity ball never animating**:
`PhysicsTab` reads `proxy.size` from a `GeometryReader` to compute the physics
field bounds, and drives the simulation from a `.task(id: BoundsID(fieldBounds))`
loop on the `Canvas` *inside* that `GeometryReader`. The ball draws once (spawn)
and then sits still. The same freeze would hit any real app using
GeometryReader-hosted animation, not just the test harness.

## Reproduction (isolation chain)

All four variants were driven through the real `RunLoop.run()` with a scripted
"awaited-input" reader whose first step waits for `≥ 3` distinct presents and
whose final step sends `⌃D` to quit. "Pumps" = the wait is satisfied; "stalls" =
the wait never progresses (observed via the `withStageBudget` wall-clock
backstop firing with `stage clock stalled`).

| Variant | Result |
| --- | --- |
| `Text("c=\(count)").task { loop: sleep 40ms; count += 1 }` | **pumps ✓** |
| `Text("c=\(count)").task(id: stableID) { … }` | **pumps ✓** |
| `GeometryReader { _ in Text("c=\(count)") }.task(id:) { … }` | **stalls ✗** |
| `GeometryReader { _ in Text("c=\(count)") }` with `.task` hoisted onto the outer view | **stalls ✗** |

Minimal stalling view:

```swift
struct Probe: View {
  @State private var count = 0
  var body: some View {
    GeometryReader { proxy in
      Text("count=\(count) w=\(proxy.size.width)")
        .task(id: BoundsID(width: proxy.size.width, height: proxy.size.height)) {
          while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 40_000_000)
            count += 1            // autonomous @State mutation — never re-presents
          }
        }
    }
  }
}
```

## Root cause

The first two rows prove the runtime *does* pump autonomous, non-input frames in
general: a plain `.task`/`@State` animation re-presents fine. The bug is specific
to **content hosted by a `GeometryReader`** — its presence prevents autonomous
content invalidations from producing a present. Frames for GeometryReader content
appear to be gated on a measure/layout (or input) trigger rather than on a plain
content-state invalidation.

The exact sub-mechanism was not fully isolated and is one of:

1. The `GeometryReader` content's render is deferred to a measure/layout pass
   that only runs on input/resize, so a content-only `@State` invalidation never
   schedules a frame; or
2. The `.task` attached under a `GeometryReader` is not driven the same way as on
   a plain view (lifecycle not started / continuously cancelled by re-evaluation).

Both manifest identically as "first frame then frozen."

## Workarounds attempted (and why they failed)

- **Hoisting the `.task` out of the `GeometryReader` content closure** onto the
  outer view: still stalls. So it is not about where the `.task` is attached —
  the `GeometryReader`'s presence is the trigger.
- A `ZStack { GeometryReader { … }; <animated sibling> }` structure (animated
  content as a sibling, not nested) was attempted but the probe hit unrelated
  SwiftTUI API constraints (`.background` requires `ShapeStyle`; `GeometryReader`
  content typing) before it could be validated. This is the most promising next
  consumer-side experiment if a framework fix is deferred.

There is no confirmed consumer-level fix: `PhysicsTab` fundamentally needs the
`GeometryReader`-provided size for its field bounds, and hoisting did not help.

## Suspected fix surface

- `GeometryReader` implementation (`Sources/SwiftTUIViews/…`) and the frame
  pipeline's handling of `GeometryReader`-measured subtrees: ensure a plain
  content `@State` invalidation under a `GeometryReader` schedules a frame
  (routes to the scheduler / event-pump wake) the same way it does outside one.
- Cross-check the `.task` lifecycle for views inside a `GeometryReader` content
  closure (started once, not cancelled on every content re-evaluation when its
  `id` is stable).

## Suggested regression test (framework)

Add a `SwiftTUITests` runtime test that drives a `.task`-animated `@State`
counter **inside a `GeometryReader`** through `RunLoop.run()` and asserts `≥ 3`
distinct presents with **no input** (bounded by a stage budget + the wall-clock
backstop so a regression fails fast instead of hanging). Mirror the four-variant
table above so the GeometryReader-specific case is pinned.

## Related

- Gallery gating + the `withStageBudget` wall-clock backstop that made this
  diagnosable: `swift-tui-examples@67f24a1`, `swift-tui` `withStageBudget`
  (`Tests/Support/StageClock.swift`).
- Sibling report: `2026-06-06-hstack-trailing-control-hit-region-bug.md`.
