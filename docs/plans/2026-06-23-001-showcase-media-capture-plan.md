# Plan — Showcase Media Capture (screenshots + video) for every host

- **Date:** 2026-06-23
- **Status:** PAGE EXTENDED + **iOS / Android CAPTURED** (2026-06-23). The
  showcase renders the cross-host band + live web pane (§2). iOS and Android are
  now **real, fresh, reproducible captures** taken from the local iOS Simulator
  and Android emulator (§4.3, §4.4) and composited into the band via
  `swift-tui-examples/Scripts/showcase-frame.sh`. macOS / terminal / web keep
  their reused marketing composites (re-capture is optional polish). Getting the
  iOS build to compile required a real **dependency-hygiene fix — a host target
  must not depend on the `SwiftTUI` umbrella product** (it pulls the web host);
  see §4.3.0. Remaining: the four `/02` example-app cards still use placeholders.
- **Owner repo:** `swift-tui-org` (coordination root). The forward-looking plan
  lives here per the org contract; the capture *scripts* and *outputs* land in
  the public children (`swift-tui-examples/Scripts`, `swift-tui-site/Website/public`).
- **Scope:** Produce a consistent, on-brand still (and optional short video) for
  each visual on `https://swifttui.sh/showcase/` — the five host renders of the
  component gallery, plus the four maintained example-app cards.

> Forward-looking design doc per `AGENTS.md` → "Public vs coordination
> contracts." It spans child repos (site / examples / android), so it lives in
> this root's `docs/plans/`, not in a child.

---

## 1. Why this exists

The showcase page was, until now, four hand-authored SVG placeholders annotated
*"replace with PNG capture."* The page has been extended (this session) to also
tell the framework's strongest story — **one component gallery, rendered by
every host** — using device-framed captures. That extension surfaced a concrete
media gap and we have now closed most of it: iOS and Android are captured fresh
from the local simulators (§4.3–§4.4), proving a repeatable per-host pipeline.
What remains is (a) optionally re-capturing the reused macOS/terminal/web stills
to one standard, and (b) the four `/02` example-app cards, still on placeholders.

This plan is the capture playbook + asset standard + task list to close that gap.

## 2. What the page renders now (capture targets)

The page (`swift-tui-site/Website/src/pages/showcase.astro`) has three blocks:

**`/01` Every host** — a device band proving *the same gallery* runs on each
host, plus the live web pane:

| Slot | Host product | Source app | Visual today | Target |
| --- | --- | --- | --- | --- |
| `host-macos.png` | `SwiftUIHost` | `swift-tui-examples/SwiftUIExample` (macOS) | **real** (reused composite) | re-capture to standard (optional) |
| `host-ios.png` | `SwiftUIHost` | `swift-tui-examples/SwiftUIExample` (iOS) | **real** (fresh Simulator capture, 2026-06-23) | ✅ done |
| `host-android.png` | `SwiftTUIAndroidHost` | `swift-tui-examples/AndroidGallery` | **real** (fresh emulator capture, 2026-06-23) | ✅ done |
| `host-terminal.png` | `SwiftTUICLI` | `swift-tui-examples/gallery` | **real** (reused composite) | re-capture to standard (optional) |
| web pane (live `<iframe>`) | `SwiftTUIWASI` | `swift-tui-examples/WebExample` → `swifttui.sh/webexample/` | **live**; `host-web.png` is the load poster | refresh poster; optional OG/social still |

**`/02` Example apps** — the four maintained terminal apps, still on placeholders:

| Slot | Source app | Visual today | Target |
| --- | --- | --- | --- |
| `gifeditor.svg` | `swift-tui-examples/gifeditor` | placeholder | `gifeditor.png` (+ optional GIF/MP4) |
| `terminal-workspace.svg` | `swift-tui-examples/terminal-workspace` | placeholder | `terminal-workspace.png` |
| `layouts-swiftui.svg` | `swift-tui-examples/LayoutsSwiftUI` | placeholder | `layouts-swiftui.png` |
| `gitviz.svg` | `swift-tui-examples/gitviz` | placeholder | `gitviz.png` |

All slots resolve from `swift-tui-site/Website/public/showcase/`. The page reads
`host-*.{png,svg}` for the band and `<slug>.svg` for the example cards; dropping
in a same-named `.png` (and flipping the `<img src>` extension for the example
cards) is the only site edit a capture requires.

> **Provenance of today's reused stills.** `host-{ios,macos,terminal,web}.png`
> are copies of `swift-tui-examples/WebExample/src/assets/{iPhone,macOS,terminal,Web}.png`
> — existing device-framed marketing composites of the *same* gallery. They are
> the bar for "good": a device in a warm-gradient corner crop, square aspect,
> the gallery visibly running. Re-captures should match that language.

## 3. Asset standard (the bar every capture must hit)

- **Framing — two tiers.**
  - *Device composites* (band): the host's window/device sits in a corner of a
    1:1 frame over a warm gradient, bleeding off-edge — matching the reused
    stills. This is the "marketing" tier and is what the band displays.
  - *Raw window crops* (example cards): tight crop of just the app surface, no
    device chrome, **1200×750** (16:10) to match the existing `.shot` aspect.
- **Dimensions.** Band stills: **1000×1000** (square, `object-fit: cover`).
  Example-card stills: **1200×750**. Export at **2×** for retina, then keep file
  size reasonable (see budget).
- **Content.** Land on a tab that photographs well and tells the story. The
  gallery accepts `--tab <key>` (e.g. `counter`, `calculator`, `images`,
  `logo`, `animations`) — pick per host so the band reads as variety of the
  *same* app, not five identical screens. Reused stills already vary
  (macOS=Counter, iOS=Calculator, terminal=Counter+files, web=Deploy Dashboard).
- **Theme.** Dark surface (the site default and the framework's native look).
- **Naming.** `host-<platform>.png` (band), `<example-slug>.png` (cards). Square
  band art keeps the `.svg` placeholder only for Android until captured.
- **Format.** PNG for stills. For motion: prefer **MP4 (H.264)** + a poster
  still; fall back to animated GIF only where MP4 is impractical. Keep the
  source-of-truth captures in the example repo under `art/` (proposed) so they
  are reproducible; the site only carries the optimized web copies.
- **Size budget.** Per still ≤ ~350 KB (the reused PNGs are 135–347 KB). Per
  video ≤ ~2.5 MB; lazy-load and never autoplay with audio.

## 4. Per-host capture playbooks

All Swift example commands use `swiftly run swift …` (pinned 6.3.x). Run from
`swift-tui-examples/`.

### 4.1 Terminal — `gallery` (and the four example cards)

Tooling already exists: **`swift-tui-examples/Scripts/screenshot_gallery.sh`**
(kitty + macOS `screencapture`, supports `--tab`). Prereqs: Homebrew `kitty`,
Screen-Recording + Accessibility permissions for the driving terminal.

```bash
# build once
swiftly run swift build --package-path gallery --product gallery-demo

# still per tab (raw window crop)
SCREENSHOT_DELAY=2 Scripts/screenshot_gallery.sh /tmp/shots/host-terminal.png counter
Scripts/screenshot_gallery.sh /tmp/shots/gallery-images.png images
```

For the example-app cards, generalize the script to take any built binary
(it currently hard-codes `gallery-demo`). Each of `gifeditor`,
`terminal-workspace`, `gitviz` builds a binary that runs in kitty the same way;
`gitviz` is non-interactive (`gitviz dashboard --path .`) and can also be piped
to an SVG/text capture.

- **Video:** `asciinema rec` → `agg` (asciinema-gif) or record the kitty window
  with `screencapture -v` / QuickTime. The repo already ships a
  `threehosts.asciinema` recording as a format precedent.
- **Device-composite tier:** drop the raw crop into the corner-crop template
  (the reused `terminal.png` is the reference; a reusable SVG/figma frame should
  live in `swift-tui-examples/art/frames/`).

### 4.2 macOS — `SwiftUIExample` (SwiftUIHost)

```bash
open SwiftUIExample/SwiftUIExample.xcodeproj   # Run the macOS scheme (Xcode 26 / Swift 6.3.1)
# capture the app window:
screencapture -l$(/usr/bin/osascript -e 'tell app "System Events" to id of window 1 of (first process whose frontmost is true)') /tmp/shots/macos-raw.png
# or interactive window grab:
screencapture -iW /tmp/shots/macos-raw.png
```

Then composite into the square device frame. Choose a tab distinct from iOS
(reused macOS still = Counter).

### 4.3 iOS — `SwiftUIExample` in the Simulator (SwiftUIHost) — **verified 2026-06-23**

Verified on this machine: Xcode 26.5, iPhone 17 Pro simulator (iOS 26.5), Swift
6.3.1 via swiftly.

#### 4.3.0 Prerequisite (REQUIRED): a host must not depend on the `SwiftTUI` umbrella

The iOS build **fails to link** until this is fixed. `SwiftUIExample` embeds
scenes from `ExampleScenes` (`SwiftUIExample/TerminalApp`), which did
`import SwiftTUI` — the **umbrella** product. The umbrella bundles
`SwiftTUIWebHostCLI → SwiftTUIWebHost`, whose `launchBrowserCommand` calls
`Foundation.Process`, which **does not exist on iOS** → `error: cannot find
'Process' in scope` while compiling `SwiftTUIWebHost`.

A SwiftUI-hosted app embeds a `SwiftTUIRuntime` app and must never pull the web
host. Fix (applied in `swift-tui-examples`, two lines):

- `SwiftUIExample/TerminalApp/Package.swift` — `ExampleScenes` dep
  `.product(name: "SwiftTUI", …)` → `.product(name: "SwiftTUIRuntime", …)`.
- `…/Sources/ExampleScenes/ExampleApp.swift` — `import SwiftTUI` → `import SwiftTUIRuntime`.

`App` / `Scene` / `WindowGroup` / `WindowIdentifier` all live in
`SwiftTUIRuntime`; the umbrella's `App` only *refines* it with `SwiftTUICommand`
(the CLI launch path), which an embedded host does not use, and `SwiftUIHostAppState`
expects a `SwiftTUIRuntime.App` anyway. The Android host (`gallery-android-host`)
and the `SwiftUIHost` library already depend only on `SwiftTUIRuntime` — they are
clean (verified). **Deeper framework follow-up:** guard WebHost's `Process` use
behind `#if !os(iOS) && !os(watchOS) && !os(tvOS)` so `SwiftTUIWebHost` at least
compiles as a no-op on iOS/Android — then `import SwiftTUI` (umbrella) is
import-safe everywhere, not just on desktop.

#### 4.3.1 A buildable scheme

The project ships **no shared scheme** for the `SwiftUIExample` *app* target (the
schemes `xcodebuild -list` reports are SwiftPM package products), so
`xcodebuild -scheme SwiftUIExample` fails until one exists. Either open the
project in Xcode once (auto-creates a per-user scheme) or add a shared scheme
under `…/xcshareddata/xcschemes/`. The scheme's `BlueprintIdentifier` is the
`SwiftUIExample` `PBXNativeTarget` (`F7FC7A792F7B19A400737CB1`), `BuildableName`
`SwiftUIExample.app`; build with implicit deps so WebHost is not built. (For this
capture a gitignored `xcuserdata` scheme was used; CI should add a *shared* one.)

#### 4.3.2 Build, install, capture (exact commands used)

```bash
cd swift-tui-examples/SwiftUIExample
DD=/tmp/ios-dd
xcodebuild -project SwiftUIExample.xcodeproj -scheme SwiftUIExample \
  -sdk iphonesimulator -configuration Debug -arch arm64 \
  -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build

xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true   # or reuse an already-booted sim
APP="$DD/Build/Products/Debug-iphonesimulator/SwiftUIExample.app"
xcrun simctl install booted "$APP"
xcrun simctl launch booted llc.goodhats.SwiftUIExample
# let the scene paint (~3s), then:
xcrun simctl io booted screenshot /tmp/shots/host-ios-raw.png
xcrun simctl io booted recordVideo --codec h264 /tmp/shots/ios.mp4   # ^C to stop

# composite into the band tile (warm-magenta gradient):
Scripts/showcase-frame.sh /tmp/shots/host-ios-raw.png \
  ../swift-tui-site/Website/public/showcase/host-ios.png 880 44 '#6a2f5a' '#c2542f'
```

The simctl screenshot is the bare screen (status bar + app, square corners);
`showcase-frame.sh` adds the bezel + gradient. **Tab selection:** the Simulator
has no CLI tap, so the embedded gallery lands on its default tab (Logo Breaker).
To choose a tab, tap it in the Simulator UI before capturing, or add an
initial-tab launch hook to the example. (Android *can* script taps — §4.4.)

### 4.4 Android — `AndroidGallery` (SwiftTUIAndroidHost) — **verified 2026-06-23**

Verified on this machine: AVD `SwiftTUI_AndroidGallery_arm64` (android-36.1,
`abi.type=arm64-v8a`, google_apis), NDK r27d (`27.3.13750724`), Swift Android SDK
`swift-6.3.2-RELEASE_android` (`ndk-sysroot` already materialized), Swift 6.3.1
host via swiftly. **The arm64-v8a AVD is load-bearing:** the APK is arm64-v8a
only, and an Apple-Silicon emulator runs arm64 images natively — an x86_64
emulator could not install it. The Android host package (`gallery-android-host`)
already depends only on `SwiftTUIRuntime` + `SwiftTUIAndroidHost` +
`GalleryDemoViews` — it does **not** pull the umbrella/web host, so no dependency
fix was needed there (the user's "neither should android" is already satisfied).

```bash
# 0. env (verified; see AndroidGallery/README.md for first-time ndk-sysroot setup)
export ANDROID_HOME="$HOME/Library/Android/sdk" ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_NDK_HOME="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3-RELEASE_android.artifactbundle/swift-android/android-ndk-r27d"
export SWIFT_ANDROID_SDK_BUNDLE="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle"
export SWIFT_ANDROID_ROOT="$SWIFT_ANDROID_SDK_BUNDLE/swift-android"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$HOME/.swiftly/bin:$PATH"

# 1. boot the emulator, wait for boot_completed
emulator @SwiftTUI_AndroidGallery_arm64 -no-snapshot -no-boot-anim -gpu auto &
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ]; do sleep 1; done

# 2. cross-compile Swift→aarch64-linux-android, build + install the debug APK
cd swift-tui-examples/AndroidGallery
./gradlew :app:assembleDebug :app:installDebug --console=plain   # first build ~minutes

# 3. launch, optionally switch tab (adb CAN tap), capture
adb shell am start -n org.swifttui.gallery.android/.MainActivity
# adb shell input tap 732 205        # e.g. the 'Life' tab (coords from a prior screencap)
adb exec-out screencap -p > /tmp/shots/host-android-raw.png
adb shell screenrecord --size 1080x2400 --bit-rate 8m /sdcard/a.mp4   # ^C to stop
adb pull /sdcard/a.mp4 /tmp/shots/

# 4. composite into the band tile, then shut the emulator down
cd ..    # swift-tui-examples
Scripts/showcase-frame.sh /tmp/shots/host-android-raw.png \
  ../swift-tui-site/Website/public/showcase/host-android.png 860 46 '#5a2f63' '#c2562f'
adb emu kill
```

The raw screenshot is 1080×2400 (no device chrome); `showcase-frame.sh` produces
the square framed tile. The first gradle build cross-compiles Swift and takes a
few minutes; subsequent builds are incremental.

### 4.5 Web — `WebExample` (SwiftTUIWASI)

The showcase web pane is a **live iframe**, so no still is strictly required for
the page to work — but we want (a) a fresh load **poster** (`host-web.png`) and
(b) a social/OG still. Playwright is already a `WebExample` dev dependency.

```bash
# against the live demo (or a local `bun run build:wasm:dev` mount)
node -e 'import("playwright").then(async ({chromium})=>{
  const b=await chromium.launch();
  const p=await b.newPage({viewport:{width:1280,height:800},deviceScaleFactor:2});
  await p.goto("https://swifttui.sh/webexample/?embed=marketing",{waitUntil:"networkidle"});
  await p.waitForTimeout(2500);
  await p.screenshot({path:"/tmp/shots/host-web.png"});
  await b.close();
})'
```

`WebExample/src/browser-integration.browser.ts` already drives Chromium + waits
for cross-origin isolation; extend it to emit the poster as a test artifact.
Video: Playwright `recordVideo` (webm) or a screen recording of the live demo.

## 5. Screenshots vs video — recommendation

- **Ship stills first.** Stills are the lowest-risk, smallest-payload path and
  satisfy every slot. They are the deliverable that unblocks the page.
- **Add motion selectively, later.** The two visuals that *gain* most from
  motion are `gifeditor` (timeline scrubbing) and the `logo`/`animations`
  gallery tabs (physics, runtime invalidation). For those, upgrade the tile
  `<img>` to a `<video muted loop playsinline preload="none" poster=…>`; the
  page already lazy-loads tile media. The web pane is *already* motion (live
  iframe), so it needs no video.
- **Never** autoplay heavy video above the fold; keep the band as stills so the
  page stays light (the live wasm iframe is the one heavy element, and it
  `loading="lazy"`s).

## 6. Automation

1. **Generalize `screenshot_gallery.sh`** to accept an arbitrary built binary +
   args, so all terminal apps (gallery, gifeditor, terminal-workspace, gitviz)
   capture through one script.
2. **Add `Scripts/capture-showcase.sh`** (in `swift-tui-examples`) orchestrating
   the macOS-runnable captures (terminal + web via Playwright; macOS/iOS via
   `simctl`) into `/tmp/shots`, then an `optimize` step (`pngquant`/`oxipng`) to
   meet the size budget. Android stays a documented manual step (toolchain/hw).
3. **Composite step (built):** `swift-tui-examples/Scripts/showcase-frame.sh`
   wraps a raw screenshot into the square 1000×1000 device composite (rounded +
   bezel + drop shadow on a warm gradient, bleeding off the bottom) so the band
   stays uniform regardless of who captured it. Used for the iOS + Android tiles;
   needs ImageMagick 7 (`magick`).
4. **Promotion:** copy the optimized `host-*.png` / `<slug>.png` into
   `swift-tui-site/Website/public/showcase/`. For the example cards (still
   pending) flip the `<img>` extension `.svg`→`.png`. The Android swap is done:
   `host-android.svg` was removed and `showcase.astro` points at
   `host-android.png` (the `preview` ribbon affordance stays in the markup,
   unused, for any future placeholder host).
5. **Optional CI:** the terminal/web captures are scriptable on a macOS runner;
   wire a manual (`workflow_dispatch`) job that regenerates stills on demand.
   Android and the device composites stay manual for now.

## 7. Task checklist

**Phase A — terminal + web (fully scriptable on this Mac, no extra hardware)**
- [ ] Generalize `screenshot_gallery.sh`; capture `host-terminal.png` + the 4
      example-card stills (`gifeditor/terminal-workspace/layouts-swiftui/gitviz`).
- [ ] Playwright poster for `host-web.png` from the live demo; refresh OG still.
- [ ] Optimize + promote into `public/showcase/`; flip example cards `.svg`→`.png`.

**Phase B — Apple hosts (needs Xcode 26 / macOS 15+)**
- [x] `SwiftUIExample` iOS Simulator screenshot → composite `host-ios.png`
      (done 2026-06-23; required the §4.3.0 umbrella→runtime fix + a buildable
      scheme). iOS video (`recordVideo`) still optional.
- [ ] `SwiftUIExample` macOS window capture → `host-macos.png` (optional refresh;
      the reused composite is live and good).

**Phase C — Android (needs emulator/device + Swift-Android toolchain)**
- [x] Build + install `AndroidGallery` on `SwiftTUI_AndroidGallery_arm64`;
      `adb screencap` → composite `host-android.png`; SVG placeholder removed and
      `showcase.astro` updated (done 2026-06-23). Android video optional.

**Phase D — motion (optional polish)**
- [ ] Capture `gifeditor` + gallery `logo`/`animations` clips (MP4 + poster).
- [ ] Upgrade those tiles to `<video>`; verify size budget + lazy-load.

## 8. Open decisions

1. **Re-capture vs keep the reused stills?** The reused macOS/iOS/terminal/web
    PNGs are good and ship today. Re-capturing buys *consistency* (same tabs,
    same frame template, same date) but costs time. Recommendation: ship as-is;
    re-capture opportunistically in Phase B alongside Android so the whole band
    lands as one matched set.
2. **Where do source captures live?** Proposed `swift-tui-examples/art/` (raw
    crops + frame templates + composites), with only optimized copies in the
    site. Keeps captures reproducible and reviewable in the public example repo.
3. **Video scope.** Stills-only is sufficient. Confirm whether motion is wanted
    before investing in Phase D.
4. **Android emulator vs device.** On-device (the host was verified on-device
    2026-06-18) gives the truest result; an emulator is more automatable. Pick
    per available hardware.
