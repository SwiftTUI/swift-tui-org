# Android `.task` / animation freeze — root cause and fix

**Date:** 2026-06-18

## Symptom

On the `AndroidGallery` host, the app rendered and responded to input, but
autonomous `.task` loops and animation never advanced: Conway's `Life` stayed at
`gen 0`, the `Animations`/`Physics`/`Progress` demos were frozen. An earlier
investigation concluded this was likely "no working Swift main-executor /
`Looper` integration for `@MainActor` task continuations on Android" and that the
runtime drain entry points are blocking main loops, not embeddable pumps.

## Root cause

Swift 6.2 reified the main actor's executor as a `RunLoopExecutor` that the
**program must explicitly drive**. On Darwin the OS run loop (CFRunLoop) drains
it continuously, so `@MainActor` continuations keep flowing. The Android host is
a bare JNI embedding: the Android `Looper` drains the *Java* main queue, not
Swift's main-actor job queue, and nothing drives the Swift main executor.

- The stock Android `MainActor.executor` is a `DispatchMainExecutor` whose jobs
  sit on libdispatch's **main queue**. Nothing pumps that queue in this
  embedding (`run()` calls `dispatch_main()` and never returns; `runUntil` is the
  trapping default extension). So every main-actor resumption is stranded.
- `Task.sleep` *timers* still fire — they run on the libdispatch **global** pool's
  worker threads — so `.task` bodies and the renderer's `DeadlineWakeState`
  advance their sleeps. But the moment they hop **back to `@MainActor`** (every
  `.task` body is `@MainActor`; the run loop's `await iterator.next()` is
  `@MainActor`; the animation re-arm yields to the main-actor consumer), the
  continuation enqueues on the undrained main executor and never runs.
- Input still worked because the run loop special-cases it: on Android with
  `renderMode == .sync` a synchronous `directWake` closure processes input
  events under `MainActor.assumeIsolated` on the JNI thread, bypassing the
  executor entirely. That is exactly why "input works but nothing time-driven
  does" — input is the one path that does not need the executor.

This was confirmed against the installed `swift-6.3.2-RELEASE_android`
`_Concurrency` private `.swiftinterface` plus the open-source `swiftlang/swift`
`stdlib/public/Concurrency` sources (`PlatformExecutorLinux.swift`,
`DispatchExecutor.swift`, `Executor.swift`, `CooperativeExecutor.swift`).

## Fix

Install a **host-driven main-actor executor** and drain it from the Android
render poll loop.

- `HostMainExecutor` (`Platforms/Android/.../AndroidMainExecutorPump.swift`,
  `#if os(Android)`) is a minimal `MainExecutor`: a mutex-guarded `[UnownedJob]`
  queue. `enqueue` (called cross-thread when a task hops back to the main actor)
  appends; `drainReadyJobs()` snapshots the queue and runs each job via
  `runSynchronously(on: asUnownedSerialExecutor())` on the host main thread, then
  returns. `checkIsolated()` / `isIsolatingCurrentContext()` compare against the
  `pthread_self()` captured at install so `MainActor.assumeIsolated` stays
  correct.
- It is installed via the experimental `_createExecutors(factory:)` SPI, swapping
  **only** the main executor and **keeping** `PlatformExecutorFactory.defaultExecutor`
  (the self-driving libdispatch global pool). That is the key to a tiny executor:
  `Task.sleep` timers keep firing on background worker threads; only the
  main-actor hop needed draining.
- Installation happens in the JNI bridge's `createHost`
  (`swift_tui_android_install_executor`), **before any main-actor work** —
  installing a custom main executor after the platform default materializes is a
  fatal error. Doing it in the shared JNI shim means every Android host app gets
  it automatically; consumers' `create_host` stays unchanged.
- A new `swift_tui_android_tick` ABI calls `drainReadyJobs()`; the Kotlin
  `SwiftTUIHostState.pollFrames()` loop calls it once per ~33 ms frame poll on the
  Android main thread, alongside the existing frame pull. The drain is bounded
  (a tick processes the ready backlog; jobs enqueued *during* the drain run next
  tick) and never blocks the UI thread waiting on a not-yet-due timer.

`directWake` is retained for synchronous input latency; the tick covers
everything time-driven. The two compose: input is serviced synchronously, async
work drains at ~30 Hz.

### Why not the alternatives

- **Drive the stock executor via `runUntil` from the tick** — non-starter:
  `DispatchMainExecutor` does not implement `runUntil` (it inherits the trapping
  default), so the first tick would crash. Even a `CooperativeExecutor`-style
  `runUntil` blocks the calling thread (`_sleep`) until the next timed job is due
  — an ANR on the UI thread.
- **Route SwiftTUI onto a custom `@globalActor`** (the PADL/AndroidLooper
  pattern) — does not apply: SwiftTUI's run loop, `.task`, and views are
  hardwired to the real `@MainActor`; there is no seam to redirect them.

## On-device verification (dev overlay)

Built with the coordination dev overlay (local `swift-tui` source +
`publishToMavenLocal` host AAR), installed on AVD
`SwiftTUI_AndroidGallery_arm64` (`android-36.1;google_apis;arm64-v8a`).

- **Before:** `Life` two screenshots 3 s apart were byte-identical (`gen 0`,
  frozen).
- **After:** `Life` advanced `gen 0 → 28 → 44` and the board evolved; `Progress`
  produced three distinct consecutive frames (continuous animation); Counter
  `+`, tab switching, and the overflow menu still respond (input unaffected).
- **Diagnostics** (`SwiftTUIJNI` logcat): `installed=1` from tick #0 (executor
  installed before `create_host`), `enqueued ≈ drained` climbing (4 → 49 → 138 →
  1824) with `pending ≈ 0` (the drain keeps up; no backlog, and zero jobs while
  idle on a static tab — demand-driven, not a busy-spin). 2000+ ticks, no crash.

## Coordination tooling note

The dev init script `tools/coordination/swift-tui-android-dev.init.gradle.kts`
now makes mavenLocal **authoritative** for `sh.swifttui*` artifacts
(`exclusiveContent`). Previously it only appended mavenLocal, so the released
`0.0.21` AAR on GitHub Pages shadowed a freshly `publishToMavenLocal`-ed pre-tag
build, silently testing stale bits.

## Follow-ups

- Behavioral regression home: promote the manual Gallery sweep into a Gradle/ADB
  smoke lane (already listed as Android-host Next Work). The added
  `SwiftTUIAndroidHostTests` case only pins the tick/diag ABI surface — the
  custom executor is `#if os(Android)` and cannot be exercised by the
  macOS/Linux gate.
- Latency: enqueue currently waits for the next ~33 ms tick. An `eventfd` +
  `ALooper_addFd` wake (the PADL/AndroidLooper mechanism) would resume the host
  loop immediately on enqueue; the 33 ms poll is a sufficient first cut at 30 Hz.
- The custom-executor SPI (`@_spi(ExperimentalCustomExecutors)`) is experimental;
  re-verify on Swift toolchain bumps.
