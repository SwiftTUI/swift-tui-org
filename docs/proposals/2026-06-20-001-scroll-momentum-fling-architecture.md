# Proposal: Scroll momentum / fling — the root fix

Status: **Accepted, implementing (2026-06-20).** Supersedes the deferral in
[`docs/plans/2026-06-19-001-cross-host-scrolling-plan.md`](../plans/2026-06-19-001-cross-host-scrolling-plan.md)
§5.2 ("Momentum / fling — blocked, needs infrastructure"). Spans the runtime and
the public scroll surface, so it lives in the coordination root. Author:
momentum root-cause work (2026-06-20).

## 1. The corner we are in

The 2026-06-19 cross-host scrolling work shipped drag-to-pan (`.down/.dragged/.up`
follows the finger) but **deferred momentum / fling** with a three-part rationale:

1. The animation controller interpolates *render-time* animatable slots (opacity,
   `.offset`/`.position`, shape styles) by **diffing placed trees** — it does not
   re-run layout with interpolated inputs, and the scroll offset is a
   `ScrollViewLayout` input. So `withAnimation { scrollPosition = … }` cannot
   glide.
2. `ScrollView` is a `PrimitiveView` with **no `body`**, so there is no natural
   place to attach a per-frame decay driver (`.task` / `TimelineView`).
3. The run loop **coalesces drag bursts**, so reliable *release velocity* is hard
   to measure from the event stream.

The deferral's recommended path was *"post a decaying series of synthetic
`.scrolled` events from the run loop."* That is the corner: it treats a
`ScrollView` as something that can only be moved by **input events**, so the only
imagined way to animate it was to **fake more input**. Synthesizing wheel events
re-enters hit-testing, re-enters the very coalescer that made velocity hard to
measure, carries only integer deltas (no sub-cell precision), and conflates
"the user scrolled" with "physics is settling."

## 2. The reframe

Each "blocker" is not an obstacle — it is telling us the **shape** of the correct
solution. Read the other way:

| Stated blocker | What it actually tells us |
| --- | --- |
| Animation interpolates render slots, not layout inputs | Momentum must **not** go through the animation system. Momentum is a *physics integrator*, not a fixed-duration tween. (SwiftUI agrees: `UIScrollView` owns deceleration; the SwiftUI animation engine does not.) |
| `ScrollView` has no `body` for a driver | The driver must **not** live in the view. It belongs in the **run loop**, which *already* runs a deadline-driven per-frame driver for animations. |
| Coalescing undermines release velocity | Velocity is still measurable: every surviving event keeps a real `timestamp`, `.up` is **never** coalesced, and the codebase already does windowed velocity in `DragGestureRecognizer`. Measure it in the run loop, from the captured pan stream. |

The unifying realisation: **`LocalScrollPositionRegistry` is already the
non-event, imperative scroll-mutation API.** Keyboard scrolling, `ScrollViewReader`
`scrollTo`, and focus-reveal all move a `ScrollView` through the registry —
*without* synthesizing input events. Momentum is just **one more registry
client**, ticked by the same deadline cadence animations use. There is no need
for a new frame-driving mechanism, a `body`, or synthetic events.

## 3. Architecture

A first-class **scroll-momentum driver owned by the run loop**:

```
 captured pan  ──sample(location,timestamp)──▶  PointerVelocitySampler  (run loop)
      │ .up
      ▼
 release velocity  ──begin(identity, offsetVelocity)──▶  ScrollMomentumController
                                                          (pure physics, per-route)
                                                                 │
 each 33 ms deadline frame (scheduler.requestDeadline):          │ step(to: now) → Δcells
      run loop ──advanceScrollMomentumIfNeeded──▶ registry.scrollBy(Δx,Δy, scopeIdentity)
                                                                 │
                                            @State write → invalidate → resolve → ScrollViewLayout
```

### 3.1 Velocity measurement — `PointerVelocitySampler` (`SwiftTUIRuntime`)

A small ring of `(location: Point, time: MonotonicInstant)` samples, mirroring
`DragGestureRecognizer.samples` (`DragGesture.swift:96-312`). The run loop feeds
it on the **captured** pan stream — exactly where coalescing has already happened,
so it is the correct altitude (sampling earlier would see the same merged data):

- seed on `.down` capture and on the drag-threshold takeover
  (`RunLoop+PointerHandling.swift:63`, `RunLoop+ScrollGestureTakeover.swift`);
- append on each captured `.dragged`
  (`RunLoop+PointerHandling.swift:249`);
- at captured `.up` (`RunLoop+PointerHandling.swift:134`) compute velocity over a
  trailing **100 ms** window: `v = (last.location − first.location) / Δt`, in
  continuous **cells/second** (use `PointerLocation.location`, the sub-cell
  `Point`, never `.cell`).

Coalescing is lossy-but-timestamp-preserving (`MouseEvent.merged` keeps the
*latest* location **and** timestamp; `TerminalInputEvents.swift`). `.down`/`.up`
are non-coalescible, so the release sample is always real. Guard `Δt ≥ 1 ms`
against the takeover's zero-`Δt` synthetic `.down`+`.dragged` pair. **Blocker #3
dissolved.**

The pan maps `offset = startOffset − (location − startLocation)`
(`ScrollView.swift:204`), so **offset velocity = −pointer velocity**. Axes the
view cannot scroll (`content ≤ viewport`) are zeroed at fling start, matching the
pan handler's `canPanX/canPanY` gate.

### 3.2 Physics — `ScrollMomentumController` (`SwiftTUIRuntime/Lifecycle`)

Pure, per-route, run-loop-independent (unit-testable with no `RunLoop`). Keyed by
the scroll route `Identity`. Per route it holds `velocity: Vector` (offset
cells/s), `residual: Vector` (sub-cell accumulator), `lastTick: MonotonicInstant`.

`step(to now:) -> [Tick]` advances every active route:

```
Δt        = lastTick.duration(to: now)               // seconds
residual += velocity * Δt                             // forward Euler displacement
velocity *= powDouble(decelerationRetentionPerSecond, Δt)   // exponential decay
Δcells    = trunc(residual); residual -= Δcells       // integer feed, sub-cell carried
lastTick  = now
alive     = hypot(velocity) ≥ minimumVelocity
```

Integer offsets (`ScrollPosition` is `Int`) demand the sub-cell accumulator —
otherwise sub-1-cell velocity rounds to 0 and the fling dies a frame early.
`powDouble` (`SwiftTUICore/Support/PlatformMath.swift`) avoids needing `exp`.
Defaults: retention/s `0.082` (time-constant τ ≈ 0.4 s, total glide ≈ `v₀·τ`),
`minimumVelocity` 2 cells/s, `maximumVelocity` 80 cells/s. All in a
`Configuration` struct so tests pin exact numbers.

The controller is **extensible** to programmatic animated scroll
(`withAnimation { proxy.scrollTo(id) }`) as a future `.curve(to:)` mode reusing
`SpringSolver`; out of scope here, but the API is shaped for it.

### 3.3 Run-loop integration — `RunLoop+ScrollMomentum.swift`

- **Tick site:** `advanceScrollMomentumIfNeeded(for:)` is called beside
  `drainGestureDeadlinesIfNeeded(for:)` (both sync and async drivers,
  `RunLoop+Rendering.swift`) — the existing **pre-render, deadline-driven
  mutation** precedent. It gates on `scheduledFrame.causes.contains(.deadline)`,
  takes `now = scheduledFrame.triggeredDeadline ?? frameReadinessClock()`, calls
  `registry.scrollBy(Δx, Δy, scopeIdentity:)` for each tick, then re-arms
  `scheduler.requestDeadline(now + 33 ms)` while any route is alive. Because the
  advance writes `@State` *before* the frame resolves, the **same** frame renders
  the new offset (no extra latency).
- **Cadence is deadline-gated, not invalidation-gated.** The `scrollBy` `@State`
  write queues a scheduler invalidation, which produces one cheap follow-up frame
  per tick that renders the identical offset (no damage / elided) and does **not**
  re-advance momentum (not a `.deadline` frame). This matches the existing wheel
  `.scrolled` double-invalidation and the gesture-deadline pattern; the deadline,
  not the invalidation, paces the 33 ms cadence (avoids a busy-loop).
- **Clock / determinism:** reuse the existing `frameReadinessClock` seam
  (`RunLoop.swift:89`) + `triggeredDeadline`. No new global clock. Tests freeze
  the clock and step `renderPendingFrames` (the `OffscreenFrameElisionRuntimeTests`
  pattern), reading the settled `ScrollPosition` — **no sleeps** (respects the
  sleep-regex ratchet).
- **Edge / stop:** `scrollBy` returns `false` when clamped to no movement (edge)
  or the route's registration is gone (tab switch, content removal) → cancel that
  route. Plus velocity `< minimumVelocity` → done.
- **Cancellation:** a fresh `.down` on a scrolling route (touch-to-stop), a wheel
  `.scrolled` on that route, the threshold takeover beginning, and reduce-motion
  (`runtimeConfiguration.motion != .normal`) all cancel/skip — mirroring the
  animation gate.

### 3.4 What does *not* change

`ScrollView` (`SwiftTUIViews`) is **untouched**. The gallery-freeze fix — the
`.down` claim guard `event.targetRect == ctx.viewportRect` (`ScrollView.swift:171`)
— and inner-control `.up` activation are on the view/armed path the momentum
driver never enters. Momentum lives entirely in `SwiftTUIRuntime` + the
`SwiftTUICore` registry it already drives. No `AnyView`, no new public surface on
the view side.

## 4. Invariants & risks

- **One clamp of truth.** Momentum moves only through `registry.scrollBy`, whose
  `clampedOffset` is the same `min(max(0,req), max(0, content−viewport))` used by
  `ScrollViewLayout` and `clampedScrollOffset`. Momentum must never compute its
  own clamp.
- **Nested scroll views.** Always pass the captured `scrollRoute.identity` as
  `scopeIdentity` (`scrollContext(for:)` walks ancestors to find it). A `nil`
  scope grabs the *first* route — wrong.
- **Write outside any animation context.** Each tick takes the plain invalidator
  path (request `.inherit`, no batch) so momentum positions are not folded into an
  animation batch.
- **Geometry is one frame stale** (registry clamps against last committed
  `scrollRoutes`); safe for steady content, lags a frame on mid-fling resize.
- **Determinism under load.** A self-rescheduling deadline driver is load-flaky if
  it reads wall-clock `now` (see `docs/KNOWN-TEST-FLAKES.md`); routing `now`
  through `frameReadinessClock`/`triggeredDeadline` is mandatory.

## 5. File plan (`swift-tui`)

- **new** `Sources/SwiftTUIRuntime/Lifecycle/ScrollMomentumController.swift`
- **new** `Sources/SwiftTUIRuntime/Lifecycle/PointerVelocitySampler.swift`
- **new** `Sources/SwiftTUIRuntime/RunLoop/RunLoop+ScrollMomentum.swift`
- `Sources/SwiftTUIRuntime/RunLoop/RunLoop.swift` — two stored fields.
- `Sources/SwiftTUIRuntime/RunLoop/RunLoop+PointerHandling.swift` — sample on
  capture/drag, begin fling at captured `.up`, cancel on `.down`/`.scrolled`.
- `Sources/SwiftTUIRuntime/RunLoop/RunLoop+ScrollGestureTakeover.swift` — seed the
  sampler on takeover.
- `Sources/SwiftTUIRuntime/RunLoop/RunLoop+Rendering.swift` — call the tick beside
  `drainGestureDeadlinesIfNeeded` in both drivers.
- **new tests** `Tests/SwiftTUICoreTests/…` (controller physics, pure) +
  `Tests/SwiftTUITests/…` (RunLoop integration, frozen clock) + keep
  `ScrollHostedControlActivationTests` green.

## 6. Tests

1. **Controller physics (pure, no RunLoop):** begin with a known velocity, step
   with explicit instants, assert integer deltas decay monotonically, sub-cell
   accumulation crosses cells correctly, the fling settles below `minimumVelocity`,
   the max-velocity cap holds, and a non-scrollable axis is zeroed.
2. **Velocity sampler:** trailing-window estimate, robustness to a single coalesced
   `.dragged`, `Δt`-guard against the zero-interval takeover pair.
3. **RunLoop integration (frozen clock):** render → inject `.down/.dragged…/.up`
   with stamped timestamps → step `frameReadinessClock` + `renderPendingFrames` →
   the `ScrollPosition` box advances past the release point and **settles**;
   stops at the content edge; a `.down` mid-fling halts it; reduce-motion releases
   without a glide.
4. **No regression:** `ScrollHostedControlActivationTests` (scene-host inner-button
   activation) and the sub-cell pan rounding test stay green.
