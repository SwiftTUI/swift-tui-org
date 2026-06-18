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
  // Make mavenLocal AUTHORITATIVE for the org's own artifacts so a freshly
  // `publishToMavenLocal`-ed pre-tag build always wins over the released copy on
  // GitHub Pages (which otherwise shadows mavenLocal because it is declared
  // first and serves the same release version). `exclusiveContent` both routes
  // `sh.swifttui*` to mavenLocal and stops mavenLocal from being consulted for
  // anything else.
  pluginManagement.repositories {
    exclusiveContent {
      forRepository { mavenLocal() }
      filter { includeGroupByRegex("sh\\.swifttui.*") }
    }
  }
  dependencyResolutionManagement.repositories {
    exclusiveContent {
      forRepository { mavenLocal() }
      filter { includeGroupByRegex("sh\\.swifttui.*") }
    }
  }
}
