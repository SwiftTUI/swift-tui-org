// Coordination-owned pre-tag dev override for the SwiftTUI Android host.
//
// The public AndroidGallery example consumes sh.swifttui:android-host:0.1.0 (from
// GitHub Pages) and the sh.swifttui.android Gradle plugin (from the Plugin Portal).
// Before swift-tui-android publishes those artifacts, this init script lets the
// example resolve them from mavenLocal — populate it first with:
//
//   (cd swift-tui-android && ./gradlew publishToMavenLocal)
//
// then build the example with:
//
//   ./gradlew --init-script tools/coordination/swift-tui-android-dev.init.gradle.kts ...
//
// This belongs ONLY to the coordination root. It must never be committed into the
// public swift-tui-examples repo, whose manifest ships the public coordinates.
settingsEvaluated {
  pluginManagement.repositories {
    mavenLocal()
  }
  dependencyResolutionManagement.repositories {
    mavenLocal()
  }
}
