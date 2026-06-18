# Android Interaction Sweep

**Date:** 2026-06-18

## Scope

This sweep used the coordination dev overlay, not the public
`AndroidGallery/SwiftPackage` manifest. The public child manifest still resolves
the released SwiftTUI `0.0.21` tag; the overlay rewrites the demo package to use
the local `swift-tui` checkout so pre-release input work is tested against the
current framework source.

Tested artifact:

```bash
.build/coordination/dev-overlay/swift-tui-examples/AndroidGallery/app/build/outputs/apk/debug/app-debug.apk
```

Runtime target:

```text
AVD: SwiftTUI_AndroidGallery_arm64
System image: system-images;android-36.1;google_apis;arm64-v8a
Screen: 1080x2400
Package: org.swifttui.gallery.android
```

Local screenshots, XML, and logcat capture were written under:

```bash
/tmp/swifttui-android-sweep-20260618/
```

## Summary

The overlay APK installs, launches, stays alive, renders every Gallery tab, and
now has device proof for physical taps, text entry, scrollable content, pointer
tap/drag/long-press gestures, and command-palette navigation.

This closes the previous "full tab-by-tab and broader interaction sweep has not
run" blocker. It does not close Android accessibility parity, IME composition,
clipboard, link-opening, content-URI import, or Android Back/presentation
routing.

## Full Tab Smoke

All 19 Gallery tabs rendered after physical tab-strip or overflow-menu taps:

1. Logo
2. Counter
3. Life
4. Todo
5. Forms & Containers
6. Text Input
7. Scroll Control
8. Calculator
9. Borders & Shapes
10. Presentation Lab
11. Navigation & Collections
12. Images
13. Animations
14. File Drop
15. Popovers
16. Pointer Lab
17. Focus Context
18. Physics
19. Progress

The overflow menu displayed all hidden tab entries. One operational detail from
the sweep: after selecting an overflow tab, the dropdown tap target sits closer
to the arrow center than the left edge of the selected tab frame. Tapping around
`x=900 y=205` opened it reliably on the 1080x2400 emulator; `x=885 y=205`
worked from Logo but missed after Popovers was selected.

## Interaction Results

| Area | Result | Evidence |
| --- | --- | --- |
| Counter button | Physical `+` taps update SwiftTUI state after the screen is settled. The recheck moved the displayed count from `1` to `2`. | `interactions/13-counter-recheck-before.png` through `15-counter-recheck-after-second-plus.png` |
| Text input | Tapping the Owner field focused it, opened the Android keyboard, and `adb shell input text Sweep42` updated the SwiftTUI field. | `interactions/03-text-input-before-type.png` and `04-text-input-after-type.png` |
| Scrollable content | A physical vertical swipe on Text Input moved the scrollable viewport and kept the entered text visible. | `interactions/05-text-input-after-swipe.png` |
| Scroll Control commands | Physical taps on Scroll Control's `Down 2` button moved the model from `offset x:0 y:0` to `offset x:0 y:2` with `last down two rows`. | `interactions/06-scroll-control-before.png` and `07-scroll-control-after-down2.png` |
| Pointer spatial tap | Tapping Pointer Lab's named target updated `Spatial tap` to a coordinate value. | `interactions/10-pointer-after-tap.png` |
| Pointer drag | A physical drag across the Pointer Lab target updated the `Drag` coordinate/delta readout. | `interactions/11-pointer-after-drag.png` |
| Pointer long press | A stationary long press on the Pointer Lab target incremented `Long presses` from `0` to `1`. | `interactions/12-pointer-after-long-press.png` |
| Command palette | Tapping `^K Palette`, entering `progress`, and pressing Enter navigated to the Progress tab. | `interactions/16-command-palette-open.png` through `18-command-palette-enter.png` |

## Accessibility And Logs

`uiautomator dump` produced a Compose hierarchy instead of only an inert root
view, but the tree is still too shallow for SwiftUI parity. It exposes generic
groups/buttons plus a few descriptions such as `Reset counter` and `^K Palette`;
it does not surface the full visible SwiftTUI text and control labels as
Android-accessible nodes.

`logcat` for the run showed `libswift_tui_jni.so` loading successfully and did
not show an app `FATAL EXCEPTION`, `SIGSEGV`, or Swift/JNI crash. The error lines
that did appear were emulator/system-service noise and `uiautomator` startup
messages, not Gallery process failures.

## Remaining Gaps

- Android accessibility semantics need proper label/action/value propagation
  instead of generic `group`/`button` descriptions.
- Android Back is not yet routed through SwiftTUI presentation/menu dismissal.
  In this sweep, pressing Back from the app sent the emulator to the launcher.
- IME composition remains unverified. Plain hardware text injection works, but
  composed text, selection, delete ranges, and candidate handling still need a
  focused pass.
- Device clipboard, link opening, and Android content URI import remain
  unswept.
- These are manual emulator sweeps. The useful subset should become an
  automated Gradle/ADB smoke lane once the Android host test harness is stable.
