// swift-tools-version: 6.3
import PackageDescription

// Coordination-only tool (org root): renders each SwiftTUI layout-catalog entry
// to a PNG via the swift-tui-swiftui @_spi(Raster) offscreen seam. It path-deps
// the LOCAL swift-tui-swiftui (which carries the pre-tag seam) and the LOCAL
// `layouts` catalog, while taking swift-tui from the same tagged release both of
// those already pin — so there is no dependency-override conflict and the public
// child repos are untouched. See docs/plans/2026-06-21-001-...
let package = Package(
  name: "swifttui-raster",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(url: "https://github.com/SwiftTUI/swift-tui.git", exact: "0.1.0"),
    .package(name: "swift-tui-swiftui", path: "../../../swift-tui-swiftui"),
    .package(name: "layouts-demo", path: "../../../swift-tui-examples/layouts"),
  ],
  targets: [
    .executableTarget(
      name: "swifttui-raster-export",
      dependencies: [
        .product(name: "SwiftTUIRuntime", package: "swift-tui"),
        .product(name: "SwiftUIHost", package: "swift-tui-swiftui"),
        .product(name: "Layouts", package: "layouts-demo"),
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    )
  ]
)
