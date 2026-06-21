import AppKit
import Foundation
import Layouts
@_spi(Raster) import SwiftUIHost
import SwiftTUIRuntime

/// SwiftTUI host app that renders one layout-catalog entry full-screen — the
/// SwiftTUI counterpart to the SwiftUI `entry.makeView()` pane. Mirrors the
/// (internal) `TUILayoutComparisonApp` in LayoutsSwiftUI so this coordination
/// tool stays decoupled from the example app.
struct ComparisonEntryApp: SwiftTUIRuntime.App {
  let entryID: String

  nonisolated init() { entryID = LayoutCatalog.all.first?.id ?? "" }
  nonisolated init(entryID: String) { self.entryID = entryID }

  var body: some Scene {
    WindowGroup("SwiftTUI", id: "comparison") {
      if let entry = LayoutCatalog.entry(id: entryID) {
        entry.makeView()
      } else {
        Text("Missing layout: \(entryID)").padding(1)
      }
    }
    .exitOnKeys([])
  }
}

@main
enum Export {
  static let cols = 60
  static let rows = 30
  static let scale: CGFloat = 2
  static let outDir = "/tmp/layout-probe/swifttui-png"

  static func main() async {
    await run()
  }

  @MainActor
  static func run() async {
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let style = SwiftUIHostTerminalStyle(fontSize: 12, cursorBlink: false)

    var ok = 0
    var failures: [String] = []
    let entries = LayoutCatalog.all
    for entry in entries {
      guard let image = await capture(entryID: entry.id, style: style) else {
        failures.append(entry.id)
        continue
      }
      if writePNG(image, to: "\(outDir)/\(entry.id).swifttui.png") {
        ok += 1
      } else {
        failures.append(entry.id)
      }
    }

    print("swifttui-raster-export: \(ok)/\(entries.count) PNGs -> \(outDir)")
    if !failures.isEmpty {
      print("FAILED: \(failures.joined(separator: ", "))")
    }
  }

  /// Drive a headless host for one entry, settle on a stable frame, and capture.
  @MainActor
  static func capture(entryID: String, style: SwiftUIHostTerminalStyle) async -> CGImage? {
    guard let state = try? SwiftUIHostAppState(app: ComparisonEntryApp(entryID: entryID), style: style)
    else { return nil }
    defer { state.stop() }

    state.start()
    state.resizeSelectedScene(to: CellSize(width: cols, height: rows))

    // Poll-free-ish settle: capture once the committed frame sequence stops
    // advancing (static layouts settle in a few frames). ~3s cap.
    var lastSequence: UInt64?
    var stableTicks = 0
    for _ in 0..<120 {
      try? await Task.sleep(for: .milliseconds(25))
      let sequence = state.selectedSceneFrameSequence
      if let sequence, sequence == lastSequence {
        stableTicks += 1
      } else {
        stableTicks = 0
      }
      lastSequence = sequence
      if stableTicks >= 4, lastSequence != nil { break }
    }

    return state.renderSelectedSceneToCGImage(scale: scale)
  }

  static func writePNG(_ image: CGImage, to path: String) -> Bool {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? data.write(to: URL(fileURLWithPath: path))) != nil
  }
}
