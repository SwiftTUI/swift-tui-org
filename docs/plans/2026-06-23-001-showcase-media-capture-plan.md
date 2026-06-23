# Plan — Showcase Media Capture (screenshots + video) for every host

- **Date:** 2026-06-23
- **Status:** PAGE EXTENDED (the showcase now renders the cross-host band +
  live web pane — see §2). Media capture NOT yet run. iOS / macOS / web /
  terminal ship **real** imagery today (reused marketing PNGs); **Android** ships
  a labelled `preview` placeholder pending a real device capture. This plan
  defines how to capture/refresh every visual.
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
media gap: we need a repeatable way to capture each host's render, because
(a) Android has no still yet, (b) the reused stills should eventually be
re-captured to one standard, and (c) the four example-app cards still use
placeholders.

This plan is the capture playbook + asset standard + task list to close that gap.

## 2. What the page renders now (capture targets)

The page (`swift-tui-site/Website/src/pages/showcase.astro`) has three blocks:

**`/01` Every host** — a device band proving *the same gallery* runs on each
host, plus the live web pane:

| Slot | Host product | Source app | Visual today | Target |
| --- | --- | --- | --- | --- |
| `host-macos.png` | `SwiftUIHost` | `swift-tui-examples/SwiftUIExample` (macOS) | **real** (reused) | re-capture to standard |
| `host-ios.png` | `SwiftUIHost` | `swift-tui-examples/SwiftUIExample` (iOS) | **real** (reused) | re-capture to standard |
| `host-android.svg` | `SwiftTUIAndroidHost` | `swift-tui-examples/AndroidGallery` | **placeholder** (`preview` ribbon) | capture `host-android.png` |
| `host-terminal.png` | `SwiftTUICLI` | `swift-tui-examples/gallery` | **real** (reused) | re-capture to standard |
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

### 4.3 iOS — `SwiftUIExample` in the Simulator (SwiftUIHost)

```bash
xcrun simctl boot "iPhone 16 Pro"
# build+run the iOS scheme from Xcode, or `xcrun simctl launch` the installed app
xcrun simctl io booted screenshot /tmp/shots/ios-raw.png
xcrun simctl io booted recordVideo --codec h264 /tmp/shots/ios.mp4   # ^C to stop
```

The Simulator already renders the device bezel/status bar, so the raw screenshot
is close to the composite tier; a light gradient backdrop matches the band.
Pick a photogenic tab (reused iOS still = Calculator).

### 4.4 Android — `AndroidGallery` (SwiftTUIAndroidHost) — **the open gap**

Heaviest prerequisites (full Swift-Android toolchain): Android SDK 36.1, NDK
r27d+, `swiftly` 6.3.x, the `swift-6.3.2-RELEASE_android` SDK bundle. See
`AndroidGallery/README.md` for the one-time `setup-android-sdk.sh` step and the
exact env block.

```bash
# build + install (env per AndroidGallery/README.md)
./gradlew :app:assembleDebug :app:installDebug

# still (emulator or device)
adb shell screencap -p /sdcard/host-android.png && adb pull /sdcard/host-android.png /tmp/shots/

# video
adb shell screenrecord --size 1080x2400 --bit-rate 8m /sdcard/android.mp4   # ^C to stop
adb pull /sdcard/android.mp4 /tmp/shots/
```

Composite into the square frame (the placeholder `host-android.svg` defines the
target composition — green Android accent, gallery on a phone). **This is the
one capture that needs hardware/emulator + the Android toolchain**, which is why
it ships as a `preview` placeholder until run.

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
3. **Composite step:** a small tool (script + the corner-crop frame templates in
   `art/frames/`) that wraps a raw crop into the square device composite, so the
   band stays visually uniform regardless of who captured it.
4. **Promotion:** copy the optimized `host-*.png` / `<slug>.png` into
   `swift-tui-site/Website/public/showcase/`, flip the example-card `<img>`
   extensions from `.svg`→`.png`, and (for Android) swap `host-android.svg`→
   `host-android.png` + drop the `preview: true` flag in `showcase.astro`.
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
- [ ] `SwiftUIExample` macOS window capture → `host-macos.png` (distinct tab).
- [ ] `SwiftUIExample` iOS Simulator screenshot/video → `host-ios.png`.
- [ ] Composite both into the square frame; promote.

**Phase C — Android (needs emulator/device + Swift-Android toolchain)**
- [ ] Build + install `AndroidGallery`; `adb screencap`/`screenrecord`.
- [ ] Composite → `host-android.png`; swap out the SVG placeholder and remove
      the `preview` ribbon in `showcase.astro`.

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
