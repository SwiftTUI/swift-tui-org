# Results: Scroll momentum / fling — root fix shipped

Date: 2026-06-20. Implements
[`docs/proposals/2026-06-20-001-scroll-momentum-fling-architecture.md`](../proposals/2026-06-20-001-scroll-momentum-fling-architecture.md)
and closes the deferral in
[`docs/plans/2026-06-19-001-cross-host-scrolling-plan.md`](../plans/2026-06-19-001-cross-host-scrolling-plan.md)
§5.2.

## What shipped (`swift-tui` @ `46f534a1`, branch `feat/scroll-momentum-fling`)

A run-loop-owned scroll-momentum driver. A body-pan release with velocity now
glides and decelerates, instead of stopping dead at the finger-up point — on
every host that forwards drags (iOS, Android, terminal mouse-drag, macOS), with
**zero** change to `ScrollView` and **no** synthetic input events.

- **`Sources/SwiftTUIRuntime/Lifecycle/ScrollMomentumController.swift`** — pure,
  per-route, clock-agnostic exponential-decay integrator. `step(to:)` returns the
  integer cell deltas to apply; a sub-cell `residual` accumulator carries
  fractional motion so the fling does not die a frame early on integer
  `ScrollPosition`. Defaults: retention `0.082`/s (τ ≈ 0.4 s, glide ≈ `v₀·τ`),
  min 2 cells/s, max 80 cells/s.
- **`Sources/SwiftTUIRuntime/Lifecycle/PointerVelocitySampler.swift`** — trailing
  100 ms (location, timestamp) window mirroring `DragGestureRecognizer`; robust to
  the run loop's drag coalescing because each surviving event keeps a real
  timestamp and `.up` is never coalesced.
- **`Sources/SwiftTUIRuntime/RunLoop/RunLoop+ScrollMomentum.swift`** + small hooks
  in `RunLoop.swift` (two fields), `RunLoop+PointerHandling.swift` (sample on
  captured drag, fling at captured `.up`, cancel on press / wheel),
  `RunLoop+ScrollGestureTakeover.swift` (seed on takeover), `RunLoop+Rendering.swift`
  (tick beside `drainGestureDeadlinesIfNeeded`). Momentum writes offsets through
  `LocalScrollPositionRegistry.scrollBy`; a `false` return (edge / route gone)
  stops the route. Ticked on the animation 33 ms deadline cadence; cadence is
  paced by the scheduler deadline, never the per-tick `@State`-write invalidation.

## Why this is the root fix, not the deferral's band-aid

The deferral proposed posting decaying synthetic `.scrolled` events. That routes
physics back through the input system it was fighting. The three "blockers" were
re-read as the *shape* of the answer:

| Blocker | Resolution |
| --- | --- |
| Animation interpolates render slots, not layout inputs | Momentum bypasses the animation system; it is a physics driver writing to the registry. |
| `ScrollView` has no `body` for a driver | The driver lives in the run loop; the registry is the runtime→view-state bridge (same path keyboard scroll / `ScrollViewReader` / focus-reveal already use). |
| Coalescing undermines release velocity | Windowed velocity over real timestamps; `.up` is never coalesced. |

## Verification

- New: 11 pure unit tests (`ScrollMomentumTests` — decay, the `v₀·τ` projection
  identity, sub-cell accumulation, cap, cancellation, sampler window/guards) and
  3 frozen-clock RunLoop integration tests (`InteractiveRuntimeTests` —
  glide+settle, reduced-motion, touch-to-stop). No sleeps; the test-sync ratchet
  is unmoved.
- No regression: `ScrollHostedControlActivationTests` (the gallery-freeze `.down`
  guard / inner-button activation), drag-threshold takeover, body-pan, tap, and
  sub-cell-rounding tests stay green.
- `bun run test` (full repo gate, all policy checks + every layer's tests): **PASS**.

## Deferred follow-ons (designed-for, not built)

The controller is shaped to also host programmatic animated scroll
(`withAnimation { proxy.scrollTo(id) }`) as a future `.curve(to:)` mode reusing
`SpringSolver`. One cheap no-op follow-up frame per tick (the `@State`-write
invalidation that renders the identical offset, then elides) matches the existing
wheel `.scrolled` pattern; collapsing it is a possible later optimization.

## Status

Committed locally in `swift-tui` (`46f534a1`) and pinned in the org root.
**Not yet pushed**; push + PR is the outstanding step.
