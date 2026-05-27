# SwiftTUI App Command Conformance Implementation Plan

> **For agentic workers:** REQUIRED SKILL: use `executing-plans` or
> `subagent-driven-development` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make apps that use the batteries-included `import SwiftTUI` surface
conform to `SwiftTUICommand` through the `App` protocol, while preserving the
plain `struct DemoApp: App` authoring shape and the narrower runtime products.

**Architecture:** Add a `SwiftTUI.App` overlay protocol in the convenience
target that refines `SwiftTUIRuntime.App` and `SwiftTUICommand`. Keep
`SwiftTUIRuntime.App` platform-neutral and command-free so `SwiftTUIRuntime`,
`SwiftTUIWASI`, `SwiftUIHost`, and other custom hosts do not inherit
ArgumentParser. Route `SwiftTUI.App.main()` through command parsing only when a
concrete app declares the stored `@OptionGroup var swiftTUIOptions`; otherwise
preserve the existing WebHost CLI default path that parses only framework
runtime options.

**Tech Stack:** Swift 6.3, SwiftPM products and targets, Swift Argument Parser
`AsyncParsableCommand` and `@OptionGroup`, SwiftTUI runtime scenes,
SwiftTUIWebHostCLI launch routing, Swift Testing, DocC, and the
`swift-tui-org` Bazel native-gate orchestration.

---

## Viability

This is viable if the migration uses a `SwiftTUI` convenience-module overlay.
It is not viable as a direct edit to make `SwiftTUIRuntime.App` inherit
`SwiftTUICommand` in place, because `App` is declared in
`SwiftTUIRuntime` while `SwiftTUICommand` is declared in `SwiftTUIArguments`,
and `SwiftTUIArguments` already depends on `SwiftTUIRuntime`.

Current layering evidence:

- `SwiftTUIRuntime.App` is declared in
  `swift-tui/Sources/SwiftTUIRuntime/Scenes/App.swift`.
- `SwiftTUICommand` lives in
  `swift-tui/Platforms/Arguments/Sources/SwiftTUIArguments/SwiftTUICommand.swift`
  and imports `SwiftTUIRuntime`.
- `SwiftTUIRuntime` currently has no dependency on `SwiftTUIArguments`, while
  `SwiftTUIArguments`, `SwiftTUICLI`, and `SwiftTUIWebHostCLI` sit above it in
  `Package.swift`.
- A protocol defined in the `SwiftTUI` target can shadow the re-exported
  runtime `App` name for clients that write `import SwiftTUI`, while still
  refining `SwiftTUIRuntime.App`. A local compiler spike verified that a module
  can define `Overlay.App` while re-exporting `Runtime.App`, and clients can
  write `struct Demo: App` with the overlay protocol.

The migration should therefore make this authoring change:

```swift
import SwiftTUI

@main
struct DemoApp: App {
  var body: some Scene {
    WindowGroup {
      Text("Hello")
    }
  }
}
```

Under `import SwiftTUI`, that `App` should be `SwiftTUI.App`, which conforms to
both `SwiftTUIRuntime.App` and `SwiftTUICommand`. Under `import
SwiftTUIRuntime`, `App` should remain the lower-level runtime protocol and
should not conform to `SwiftTUICommand`.

## Non-Goals

- Do not make `SwiftTUIRuntime` depend on `SwiftTUIArguments` or
  ArgumentParser.
- Do not make `SwiftTUIRuntime.App` itself conform to `SwiftTUICommand`.
- Do not require every plain `SwiftTUI` app to declare
  `@OptionGroup var swiftTUIOptions`.
- Do not remove `SwiftTUICommand` as a public protocol. Existing code that
  imports `SwiftTUIArguments`, `SwiftTUICLI`, or `SwiftTUIWebHostCLI` directly
  may still spell `App, SwiftTUICommand`.
- Do not try to synthesize a stored `@OptionGroup` from a protocol extension.
  Swift Argument Parser discovers property-wrapper-backed arguments from stored
  properties on the concrete command type; a computed protocol-extension
  default can satisfy Swift's type checker, but it cannot provide a parsed
  `@OptionGroup` to ArgumentParser.

## Desired Behavior

### Plain batteries-included app

```swift
import SwiftTUI

@main
struct PlainApp: App {
  var body: some Scene {
    WindowGroup {
      Text("Plain")
    }
  }
}
```

- Compiles unchanged.
- `PlainApp` conforms to `SwiftTUICommand` at the type level.
- `PlainApp.main()` preserves today's `SwiftTUI` behavior:
  `--web`, `--port`, `--bind`, `--open`, color, accessibility, and diagnostic
  flags are parsed by `SwiftTUIOptions`.
- `PlainApp --help` shows framework runtime options.

### Batteries-included app with command options

```swift
import SwiftTUI

@main
struct OptionsApp: App {
  @OptionGroup(title: "SwiftTUI Options")
  var swiftTUIOptions: SwiftTUIOptions

  @Option(name: .shortAndLong, help: "How many widgets to show.")
  var widgets: Int = 5

  var body: some Scene {
    WindowGroup {
      Text("widgets: \(widgets)")
    }
  }
}
```

- Compiles without spelling `SwiftTUICommand`.
- `OptionsApp.parse(["--web", "--widgets", "8"])` succeeds.
- `OptionsApp --help` shows both the app-specific options and the grouped
  SwiftTUI options.
- Existing apps that already have the stored `swiftTUIOptions` option group
  only remove `, SwiftTUICommand` from the conformance list.

### Narrow runtime app

```swift
import SwiftTUIRuntime

struct HostedApp: App {
  var body: some Scene {
    WindowGroup {
      Text("Hosted")
    }
  }
}
```

- Remains command-free.
- Does not see `SwiftTUICommand` unless the importing target also imports a
  command product.
- Keeps host-managed runtime surfaces independent from CLI parsing.

## File Structure To Create Or Modify

### `swift-tui`

- Modify `Package.swift`: add direct `SwiftTUIArguments` and
  `SwiftTUIRuntime` target dependencies to the `SwiftTUI` target so the
  overlay protocol does not rely on transitive re-exports.
- Create `Sources/SwiftTUI/App.swift`: define the overlay `SwiftTUI.App`
  protocol, its source-compatible default `swiftTUIOptions`, and the
  batteries-included `main()` routing.
- Modify `Sources/SwiftTUI/SwiftTUI.swift`: keep the convenience re-exports,
  and add a short comment that the `SwiftTUI` target owns the overlay `App`
  protocol.
- Modify `Tests/SwiftTUITests/SwiftTUIConvenienceImportTests.swift`: prove
  that `import SwiftTUI` resolves `App` to the overlay protocol, that command
  parsing works without explicit `SwiftTUICommand`, and that plain apps still
  compile without a stored option group.
- Modify `Sources/SwiftTUI/SwiftTUI.docc/SwiftTUI.md`: document that
  `SwiftTUI.App` is the batteries-included app protocol and conforms to
  `SwiftTUICommand`.
- Modify
  `Sources/SwiftTUI/SwiftTUI.docc/Choosing-Modules-And-Platforms.md`: clarify
  that `SwiftTUIRuntime.App` is the host/runtime protocol and `SwiftTUI.App` is
  the command-enabled convenience overlay.

### `swift-tui-examples`

- Modify `argparse/Sources/ArgParseDemo/ArgParseDemoApp.swift`: remove
  `SwiftTUICommand` from the conformance list, leaving the stored
  `swiftTUIOptions` option group and custom flags.
- Modify `gifcat/Sources/GifCatApp/GifCatApp.swift`: remove
  `SwiftTUICommand` from the conformance list, leaving the stored
  `swiftTUIOptions` option group and `paths` argument.
- Modify `layouts/Sources/LayoutsApp/LayoutsApp.swift`: remove
  `SwiftTUICommand` from the conformance list, leaving the stored
  `swiftTUIOptions` option group.
- Search the rest of `swift-tui-examples` for `App, SwiftTUICommand`; remove
  the redundant conformance only from apps that import `SwiftTUI`.
- Modify `argparse/README.md`,
  `docs/EXAMPLE-COVERAGE.md`, and the root `README.md`: update wording from
  "App plus SwiftTUICommand" to "SwiftTUI.App command conformance" where the
  example is specifically using `import SwiftTUI`.

### `swift-tui-org`

- Modify `docs/README.md`: index this migration plan.
- After child repo implementation is committed, update the `swift-tui` and
  `swift-tui-examples` submodule pins in this org root.

## Implementation Steps

### Task 1: Add failing convenience-import tests

**Files:**

- Modify: `swift-tui/Tests/SwiftTUITests/SwiftTUIConvenienceImportTests.swift`

- [x] **Step 1: Update the command smoke fixture to remove explicit conformance**

Replace the existing fixture:

```swift
private struct ImportSmokeCommand: App, SwiftTUICommand {
  @OptionGroup(title: "SwiftTUI Options") public var swiftTUIOptions: SwiftTUIOptions

  init() {}

  var body: some Scene {
    WindowGroup {
      Text("Smoke")
    }
  }
}
```

with:

```swift
private struct ImportSmokeCommand: App {
  @OptionGroup(title: "SwiftTUI Options") public var swiftTUIOptions: SwiftTUIOptions

  @Option(name: .shortAndLong) var widgets: Int = 5

  init() {}

  var body: some Scene {
    WindowGroup {
      Text("Smoke \(widgets)")
    }
  }
}
```

- [x] **Step 2: Strengthen the command-conformance test**

Replace the body of
`swiftTUIImportExposesCommandConformanceSurface()` with:

```swift
let commandType: any SwiftTUICommand.Type = ImportSmokeCommand.self
#expect(commandType.configuration.subcommands.count == 1)

let app = try ImportSmokeCommand.parse(["--web", "--widgets", "8"])
let configuration = app.runtimeConfiguration(environment: [:], isStdoutTTY: true)

#expect(app.widgets == 8)
#expect(configuration.web != nil)
#expect(ImportSmokeCommand.configuration.subcommands.count == 1)
```

- [x] **Step 3: Add a plain-app compile smoke test**

Add this test method to `SwiftTUIConvenienceImportTests`:

```swift
@MainActor
@Test("SwiftTUI App remains source-compatible without stored option group")
func swiftTUIAppRemainsSourceCompatibleWithoutStoredOptionGroup() {
  let commandType: any SwiftTUICommand.Type = PlainImportSmokeApp.self
  #expect(commandType.configuration.subcommands.count == 1)

  let app = PlainImportSmokeApp()
  #expect(String(describing: type(of: app.body)).contains("WindowGroup"))
}
```

Add this fixture after `ImportSmokeCommand`:

```swift
private struct PlainImportSmokeApp: App {
  init() {}

  var body: some Scene {
    WindowGroup {
      Text("Plain")
    }
  }
}
```

- [x] **Step 4: Run the focused test and verify it fails**

Run:

```bash
swiftly run swift test --package-path swift-tui --filter SwiftTUIConvenienceImportTests
```

Expected: compile failure because `ImportSmokeCommand` and
`PlainImportSmokeApp` conform to `App` but do not yet satisfy
`SwiftTUICommand`.

### Task 2: Add the `SwiftTUI.App` overlay protocol

**Files:**

- Modify: `swift-tui/Package.swift`
- Create: `swift-tui/Sources/SwiftTUI/App.swift`
- Modify: `swift-tui/Sources/SwiftTUI/SwiftTUI.swift`

- [x] **Step 1: Add direct dependencies to the `SwiftTUI` target**

In `swift-tui/Package.swift`, change the `SwiftTUI` target dependency list to:

```swift
.target(
  name: "SwiftTUI",
  dependencies: [
    "SwiftTUIAnimatedImage",
    "SwiftTUIArguments",
    "SwiftTUIRuntime",
    "SwiftTUIWebHostCLI",
  ],
  path: "Sources/SwiftTUI",
  swiftSettings: swiftSettings()
),
```

- [x] **Step 2: Create the overlay protocol**

Create `swift-tui/Sources/SwiftTUI/App.swift`:

```swift
import Foundation
public import SwiftTUIArguments
public import SwiftTUIRuntime
public import SwiftTUIWebHostCLI

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// The batteries-included SwiftTUI app protocol.
///
/// `SwiftTUI.App` refines the platform-neutral `SwiftTUIRuntime.App` with the
/// command surface that the convenience product already exports. Import
/// `SwiftTUIRuntime` directly when a host-managed app should stay independent
/// from command-line parsing.
@MainActor
public protocol App: SwiftTUIRuntime.App, SwiftTUICommand {}

extension App {
  /// Source-compatible default for plain apps that do not declare command
  /// options. Apps with app-specific `@Option`, `@Flag`, or `@Argument`
  /// properties should declare a stored `@OptionGroup var swiftTUIOptions`.
  public var swiftTUIOptions: SwiftTUIOptions {
    SwiftTUIOptions()
  }

  /// Default entry point for batteries-included apps.
  public static func main() async {
    do {
      if usesStoredSwiftTUIOptions {
        try await runParsedCommand()
      } else {
        try await WebHostCLIRunner.run(Self.self)
      }
    } catch {
      exitLaunch(withError: error)
    }
  }

  private nonisolated static var usesStoredSwiftTUIOptions: Bool {
    Mirror(reflecting: Self.init()).children.contains { child in
      child.label == "_swiftTUIOptions" || child.label == "swiftTUIOptions"
    }
  }

  @MainActor
  private static func runParsedCommand() async throws {
    var command = try parseSwiftTUIRootCommand()
    if let script = completionScript(forParsedCommand: command) {
      FileHandle.standardOutput.write(Data(script.utf8))
      return
    }
    if let installedURL = try installCompletionScript(forParsedCommand: command) {
      let message = "Installed completion script at \(installedURL.path)\n"
      FileHandle.standardOutput.write(Data(message.utf8))
      return
    }
    if let appCommand = command as? Self {
      try await WebHostCLIRunner.run(
        appCommand,
        configuration: appCommand.runtimeConfiguration()
      )
      return
    }
    try command.run()
  }
}

private func exitLaunch(withError error: any Error) -> Never {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  #if canImport(Darwin)
    Darwin.exit(1)
  #elseif canImport(Glibc)
    Glibc.exit(1)
  #else
    fatalError(String(describing: error))
  #endif
}
```

- [x] **Step 3: Comment the existing re-export file**

Change `swift-tui/Sources/SwiftTUI/SwiftTUI.swift` to:

```swift
// The SwiftTUI target also defines `SwiftTUI.App`, the command-enabled
// convenience overlay for apps that use `import SwiftTUI`.
@_exported import SwiftTUIAnimatedImage
@_exported import SwiftTUIWebHostCLI
```

- [x] **Step 4: Run the focused test and verify it passes**

Run:

```bash
swiftly run swift test --package-path swift-tui --filter SwiftTUIConvenienceImportTests
```

Expected: pass.

### Task 3: Add launcher behavior tests

**Files:**

- Modify: `swift-tui/Tests/SwiftTUITests/SwiftTUIConvenienceImportTests.swift`

- [x] **Step 1: Add a stored-option detection test**

Add this test method:

```swift
@MainActor
@Test("SwiftTUI App command parsing uses stored SwiftTUI options when present")
func swiftTUIAppCommandParsingUsesStoredOptionsWhenPresent() throws {
  let app = try ImportSmokeCommand.parse(["--web", "--port", "4567", "--widgets", "9"])
  let configuration = app.runtimeConfiguration(environment: [:], isStdoutTTY: true)

  #expect(app.widgets == 9)
  #expect(configuration.web?.port == 4567)
}
```

- [x] **Step 2: Add a plain option parse test through the existing runner helper**

Add this test method:

```swift
@Test("Plain SwiftTUI App runtime options still parse through WebHost CLI")
func plainSwiftTUIAppRuntimeOptionsStillParseThroughWebHostCLI() throws {
  let configuration = try WebHostCLIRunner.runtimeConfiguration(
    arguments: ["--web", "--port", "2468", "--bind", "127.0.0.1"],
    environment: [:],
    isStdoutTTY: true
  )

  #expect(configuration.web?.port == 2468)
  #expect(configuration.web?.bind == "127.0.0.1")
}
```

- [x] **Step 3: Run the focused tests**

Run:

```bash
swiftly run swift test --package-path swift-tui --filter SwiftTUIConvenienceImportTests
```

Expected: pass.

### Task 4: Update examples to use the new conformance

**Files:**

- Modify: `swift-tui-examples/argparse/Sources/ArgParseDemo/ArgParseDemoApp.swift`
- Modify: `swift-tui-examples/gifcat/Sources/GifCatApp/GifCatApp.swift`
- Modify: `swift-tui-examples/layouts/Sources/LayoutsApp/LayoutsApp.swift`
- Inspect: all remaining `swift-tui-examples/**` matches for
  `App, SwiftTUICommand`

- [x] **Step 1: Update argparse demo**

Change:

```swift
struct ArgParseDemoApp: App, SwiftTUICommand {
```

to:

```swift
struct ArgParseDemoApp: App {
```

Keep the existing `@OptionGroup`, custom options, and command configuration.

- [x] **Step 2: Update gifcat**

Change:

```swift
struct GifCatApp: App, SwiftTUICommand {
```

to:

```swift
struct GifCatApp: App {
```

Keep the existing `@OptionGroup`, `@Argument`, and command configuration.

- [x] **Step 3: Update layouts**

Change:

```swift
struct LayoutsApp: App, SwiftTUICommand {
```

to:

```swift
struct LayoutsApp: App {
```

Keep the existing `@OptionGroup`.

- [x] **Step 4: Sweep for remaining redundant conformances**

Run:

```bash
rg -n "App, SwiftTUICommand|SwiftTUICommand, App" swift-tui-examples
```

Expected: no matches in apps that import `SwiftTUI`. If a match imports a
narrower product such as `SwiftTUIRuntime` plus `SwiftTUIArguments`, leave it
alone or convert it only after checking that the target intentionally wants the
convenience product.

### Task 5: Update docs

**Files:**

- Modify: `swift-tui/Sources/SwiftTUI/SwiftTUI.docc/SwiftTUI.md`
- Modify:
  `swift-tui/Sources/SwiftTUI/SwiftTUI.docc/Choosing-Modules-And-Platforms.md`
- Modify: `swift-tui-examples/argparse/README.md`
- Modify: `swift-tui-examples/docs/EXAMPLE-COVERAGE.md`
- Modify: `swift-tui-examples/README.md`

- [x] **Step 1: Update the SwiftTUI module overview**

In `SwiftTUI.md`, replace the current overview paragraph with:

```markdown
`SwiftTUI` is the release-facing convenience module. It re-exports the
platform-neutral runtime, standard argument parsing, the combined
terminal/WebHost runner, and animated GIF/image support. Its `App` protocol is
the batteries-included overlay: it conforms to `SwiftTUICommand` while still
building on `SwiftTUIRuntime.App`.
```

- [x] **Step 2: Add command-options guidance to the module overview**

After the first `DemoApp` code block in `SwiftTUI.md`, add:

````markdown
Apps that define their own command-line options keep those options on the app
type and add the standard option group:

```swift
@main
struct DemoApp: App {
  @OptionGroup(title: "SwiftTUI Options")
  var swiftTUIOptions: SwiftTUIOptions

  @Option var widgets: Int = 5

  var body: some Scene {
    WindowGroup {
      Text("widgets: \(widgets)")
    }
  }
}
```

Import `SwiftTUIRuntime` directly for host-managed app declarations that should
not conform to `SwiftTUICommand`.
````

- [x] **Step 3: Update the module selection guide**

In `Choosing-Modules-And-Platforms.md`, update the batteries-included row to:

```markdown
| Batteries-included executable: terminal by default, `--web` when requested, animated GIF/images available, and `App` conforms to `SwiftTUICommand` | `SwiftTUI` | `import SwiftTUI` |
```

In the Host-Managed App section, add:

```markdown
This `App` is `SwiftTUIRuntime.App`, not the command-enabled `SwiftTUI.App`
overlay.
```

- [x] **Step 4: Update examples wording**

In `swift-tui-examples/argparse/README.md`, replace:

```markdown
- `App` plus `SwiftTUICommand` in the same type.
```

with:

```markdown
- `SwiftTUI.App` command conformance through `import SwiftTUI`.
```

In `swift-tui-examples/README.md` and
`swift-tui-examples/docs/EXAMPLE-COVERAGE.md`, replace references to
"`SwiftTUICommand`, consumer flags" with
"`SwiftTUI.App` command conformance, consumer flags" for the argparse row.

### Task 6: Verify package and examples behavior

**Files:**

- No source edits unless a verification failure identifies a defect in touched
  files.

- [x] **Step 1: Run focused package tests**

Run:

```bash
swiftly run swift test --package-path swift-tui --filter SwiftTUIConvenienceImportTests
```

Expected: pass.

- [x] **Step 2: Run the SwiftTUI package gate**

Run:

```bash
swiftly run swift test --package-path swift-tui
```

Expected: pass. If unrelated long-running or platform-specific failures appear,
capture the exact failing suite and then run the touched tests again before
continuing.

- [x] **Step 3: Verify example command help**

Run:

```bash
swiftly run swift run --package-path swift-tui-examples/argparse argparse-demo --help
swiftly run swift run --package-path swift-tui-examples/gifcat gifcat --help
swiftly run swift run --package-path swift-tui-examples/layouts layouts-demo --help
```

Expected:

- argparse help includes `--widgets`, `--show-ids`, and SwiftTUI options.
- gifcat help includes the paths argument and SwiftTUI options.
- layouts help includes SwiftTUI options.

- [ ] **Step 4: Run the relevant examples gate**

Run:

```bash
cd swift-tui-examples
bun run check:focused
```

Expected: pass.

Status on 2026-05-27: ran `bun run check:focused` from
`swift-tui-examples`; it failed only in the pre-existing layouts raster
expectation
`CircleInNonSquareFrameBehaviourTests.inscribed disc leaves empty cells at the
wide frame's left/right corners`, not in the migrated app entry points.

- [ ] **Step 5: Run org-level cheap validation**

From the org root, run:

```bash
mise exec -- bazel test //:org_fast
```

Expected: pass.

Status on 2026-05-27: ran `mise exec -- bazel test //:org_fast`; the
non-pin targets passed, but `//:pin_cleanliness` failed because this working
tree intentionally has uncommitted child-submodule edits.

### Task 7: Commit child repos and record org pins

**Files:**

- Modify: `swift-tui` submodule git state
- Modify: `swift-tui-examples` submodule git state
- Modify: root `docs/README.md` if this plan has not already been indexed
- Modify: root submodule pins after child commits

- [ ] **Step 1: Commit `swift-tui` changes inside the child repo**

Run:

```bash
git -C swift-tui status --short
git -C swift-tui add Package.swift Sources/SwiftTUI Tests/SwiftTUITests/SwiftTUIConvenienceImportTests.swift
git -C swift-tui commit -m "Add SwiftTUI App command overlay"
```

Expected: commit succeeds and `git -C swift-tui status --short` is clean.

- [ ] **Step 2: Commit `swift-tui-examples` changes inside the child repo**

Run:

```bash
git -C swift-tui-examples status --short
git -C swift-tui-examples add argparse gifcat layouts README.md docs/EXAMPLE-COVERAGE.md
git -C swift-tui-examples commit -m "Use SwiftTUI App command conformance"
```

Expected: commit succeeds and `git -C swift-tui-examples status --short` is
clean.

- [ ] **Step 3: Record submodule pins in the org root**

Run:

```bash
git status --short
git add swift-tui swift-tui-examples docs/README.md docs/plans/2026-05-27-001-swifttui-app-command-conformance-plan.md
git commit -m "Plan SwiftTUI App command conformance migration"
```

Expected: root commit records only the plan/index updates and the new child
submodule SHAs.

## Risks And Checks

- **Name shadowing:** `SwiftTUI.App` intentionally shadows the re-exported
  `SwiftTUIRuntime.App` for `import SwiftTUI` clients. Focused tests must prove
  that unqualified `App` resolves to the overlay when only `SwiftTUI` is
  imported.
- **Direct parser APIs on plain apps:** A plain app gets a computed
  `swiftTUIOptions` default for source compatibility. Direct
  `PlainApp.parse(["--web"])` should not be documented as the launch path unless
  a later implementation proves that ArgumentParser sees framework options
  without a stored option group. `PlainApp.main()` remains the supported path.
- **Stored option detection:** The proposed `Mirror` check is deliberately
  narrow: it detects `_swiftTUIOptions` so existing command-aware apps route
  through ArgumentParser, while plain apps keep the current WebHost CLI parser.
  If Swift Argument Parser changes wrapper storage labels, the focused
  convenience-import tests should catch the regression.
- **Narrow products:** Apps importing `SwiftTUIRuntime`, `SwiftTUICLI`,
  `SwiftTUIWebHostCLI`, or `SwiftTUIWASI` should keep their current semantics.
  Do not migrate those imports to `SwiftTUI` just to remove a conformance.
- **Child repo ownership:** Source and example changes must be committed inside
  their child repos before the org root records new submodule pins.
