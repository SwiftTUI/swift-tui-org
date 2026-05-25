# File Previewer Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [x]`) syntax for tracking.

**Goal:** Keep the FilePreviewer demo responsive after browsing large
directories and previewing many files.

**Architecture:** Keep the fix local to the FilePreviewer example. Cache
directory listings outside render, render file rows through viewport-aware lazy
stacks, and centralize preview-process ownership so replacing or clearing a
preview always terminates the previous child process.

**Tech Stack:** Swift 6.3, SwiftTUI, SwiftTUITerminal, Swift Testing,
`DefaultRenderer` diagnostics, macOS command-line process inspection.

---

## Current Evidence

- `ColumnBrowser.body` calls `entries(in:)` while building columns, so directory
  enumeration is part of render work:
  `swift-tui-examples/file-previewer/Sources/FilePreviewerApp/ColumnBrowser.swift:27-40`.
- `ColumnBrowser.moveSelection(by:)` calls `entries(in:)` again for every
  up/down key press:
  `swift-tui-examples/file-previewer/Sources/FilePreviewerApp/ColumnBrowser.swift:115-132`.
- `FileEntry.entries(in:)` synchronously calls `FileManager.contentsOfDirectory`,
  asks for resource values, maps every URL, and sorts the full list:
  `swift-tui-examples/file-previewer/Sources/FilePreviewerApp/FileEntry.swift:24-46`.
- `FileColumn.body` renders every entry in an eager `VStack`:
  `swift-tui-examples/file-previewer/Sources/FilePreviewerApp/ColumnBrowser.swift:195-216`.
- `ColumnBrowser.advanceOrPreview` replaces `previewSession` without terminating
  the old `TerminalProcessSession`:
  `swift-tui-examples/file-previewer/Sources/FilePreviewerApp/ColumnBrowser.swift:145-173`.
- `TerminalProcessSession` already exposes `terminate(signal:)`:
  `swift-tui/Platforms/Embedding/Sources/SwiftTUITerminal/TerminalProcessSession.swift:95-98`.
- The terminal-workspace package has the expected ownership pattern: remove the
  session from storage, then `Task { await session.terminate() }`:
  `swift-tui/Platforms/Embedding/Sources/SwiftTUITerminalWorkspace/TerminalWorkspaceSessionStore.swift:34-40`.
- `LazyVStack` and `LazyHStack` are already implemented. `LazyVStack` can defer
  child realization when its content is a single `ForEach`:
  `swift-tui/Sources/SwiftTUIViews/Stacks/LazyVStack.swift:19-45`.
- Existing diagnostics tests prove that `ScrollView { LazyVStack { ForEach } }`
  lowers off-screen resolution and measurement work:
  `swift-tui/Tests/SwiftTUITests/DiagnosticsAndCacheTests.swift:520-595`.

## Non-Goals

- Do not change SwiftTUI's lazy stack implementation unless the app-level tests
  prove the existing lazy stack behavior is insufficient.
- Do not introduce asynchronous directory loading in the first pass. The main
  regression is repeated synchronous work and unbounded row rendering; caching
  and lazy realization should be landed first.
- Do not change default preview commands except where needed for tests.
- Do not add a general file-browser framework. Keep the example small.

## File Structure To Create Or Modify

- Create `swift-tui-examples/file-previewer/Sources/FilePreviewerApp/DirectoryEntryCache.swift`:
  owns cached directory listings and bounded eviction.
- Create `swift-tui-examples/file-previewer/Sources/FilePreviewerApp/PreviewSessionSlot.swift`:
  owns the current preview session and invokes termination when the session is
  replaced or cleared.
- Create `swift-tui-examples/file-previewer/Sources/FilePreviewerApp/FileColumn.swift`:
  moves the row-rendering view out of `ColumnBrowser.swift` and renders rows via
  `ScrollView` plus a single-`ForEach` `LazyVStack`.
- Modify `swift-tui-examples/file-previewer/Sources/FilePreviewerApp/ColumnBrowser.swift`:
  use the directory cache, use the preview session slot, and delete the nested
  private `FileColumn`.
- Create `swift-tui-examples/file-previewer/Tests/FilePreviewerAppTests/DirectoryEntryCacheTests.swift`:
  prove repeated reads are cached and old directory entries are evicted.
- Create `swift-tui-examples/file-previewer/Tests/FilePreviewerAppTests/PreviewSessionSlotTests.swift`:
  prove session replacement and clearing terminate the previous session exactly
  once.
- Create `swift-tui-examples/file-previewer/Tests/FilePreviewerAppTests/FileColumnRenderingTests.swift`:
  prove a large column realizes only viewport-scale rows.
- Create `swift-tui-examples/file-previewer/Tests/FilePreviewerAppTests/ColumnBrowserCacheTests.swift`:
  prove repeated renders of the browser do not reread the same directory.
- Modify `swift-tui-examples/file-previewer/README.md`:
  update the test list and document the large-directory acceptance check.

## Acceptance Criteria

- Rendering a directory with 1,000 files should keep resolved, measured, placed,
  and drawn node counts near viewport scale, not entry-count scale.
- Rendering the same `ColumnBrowser` instance twice should load the root
  directory once.
- Moving selection within an already-loaded directory should not reread that
  directory.
- Replacing a preview session should terminate the previous child-process
  owner exactly once.
- Clearing a preview because selection is empty, navigation moves to a
  directory, or navigation moves left should terminate the previous preview.
- Running the demo against a large directory should not leave multiple preview
  commands alive after selecting several files.

---

### Task 1: Add A Bounded Directory Entry Cache

**Files:**
- Create: `swift-tui-examples/file-previewer/Sources/FilePreviewerApp/DirectoryEntryCache.swift`
- Create: `swift-tui-examples/file-previewer/Tests/FilePreviewerAppTests/DirectoryEntryCacheTests.swift`

- [x] **Step 1: Write failing cache tests**

  Create `DirectoryEntryCacheTests.swift`:

  ```swift
  @testable import FilePreviewerApp
  import Foundation
  import Testing

  @MainActor
  struct DirectoryEntryCacheTests {
    @Test("cache loads a directory once and returns the cached entries")
    func cacheLoadsDirectoryOnce() {
      let directory = URL(fileURLWithPath: "/tmp/project")
      var loadCount = 0
      let cache = DirectoryEntryCache(capacity: 8) { requested in
        loadCount += 1
        return [
          FileEntry(
            url: requested.appendingPathComponent("README.md"),
            isDirectory: false
          )
        ]
      }

      let first = cache.entries(in: directory)
      let second = cache.entries(in: directory)

      #expect(first == second)
      #expect(loadCount == 1)
    }

    @Test("retainOnly evicts directories that are no longer visible")
    func retainOnlyEvictsHiddenDirectories() {
      let root = URL(fileURLWithPath: "/tmp/root")
      let child = root.appendingPathComponent("child")
      let sibling = root.appendingPathComponent("sibling")
      var loaded: [URL] = []
      let cache = DirectoryEntryCache(capacity: 8) { requested in
        loaded.append(requested)
        return [
          FileEntry(
            url: requested.appendingPathComponent("file.swift"),
            isDirectory: false
          )
        ]
      }

      _ = cache.entries(in: root)
      _ = cache.entries(in: child)
      _ = cache.entries(in: sibling)
      cache.retainOnly([root, child])
      _ = cache.entries(in: root)
      _ = cache.entries(in: child)
      _ = cache.entries(in: sibling)

      #expect(loaded == [root, child, sibling, sibling])
    }

    @Test("capacity evicts the least recently used directory")
    func capacityEvictsLeastRecentlyUsedDirectory() {
      let one = URL(fileURLWithPath: "/tmp/one")
      let two = URL(fileURLWithPath: "/tmp/two")
      let three = URL(fileURLWithPath: "/tmp/three")
      var loaded: [URL] = []
      let cache = DirectoryEntryCache(capacity: 2) { requested in
        loaded.append(requested)
        return [
          FileEntry(
            url: requested.appendingPathComponent("file.swift"),
            isDirectory: false
          )
        ]
      }

      _ = cache.entries(in: one)
      _ = cache.entries(in: two)
      _ = cache.entries(in: one)
      _ = cache.entries(in: three)
      _ = cache.entries(in: two)

      #expect(loaded == [one, two, three, two])
    }
  }
  ```

- [x] **Step 2: Run tests and verify they fail**

  ```bash
  swiftly run swift test \
    --package-path swift-tui-examples/file-previewer \
    --filter DirectoryEntryCacheTests
  ```

  Expected: FAIL because `DirectoryEntryCache` does not exist.

- [x] **Step 3: Implement `DirectoryEntryCache`**

  Create `DirectoryEntryCache.swift`:

  ```swift
  public import Foundation

  @MainActor
  public final class DirectoryEntryCache {
    public typealias Loader = @MainActor (URL) -> [FileEntry]

    private let capacity: Int
    private let loadEntries: Loader
    private var cachedEntries: [URL: [FileEntry]] = [:]
    private var recency: [URL] = []

    public init(
      capacity: Int = 32,
      loadEntries: @escaping Loader = { FileEntry.entries(in: $0) }
    ) {
      self.capacity = max(1, capacity)
      self.loadEntries = loadEntries
    }

    public func entries(in directory: URL) -> [FileEntry] {
      if let entries = cachedEntries[directory] {
        markRecentlyUsed(directory)
        return entries
      }

      let entries = loadEntries(directory)
      cachedEntries[directory] = entries
      markRecentlyUsed(directory)
      trimToCapacity()
      return entries
    }

    public func invalidate(_ directory: URL) {
      cachedEntries[directory] = nil
      recency.removeAll { $0 == directory }
    }

    public func retainOnly(_ directories: Set<URL>) {
      cachedEntries = cachedEntries.filter { directories.contains($0.key) }
      recency.removeAll { !directories.contains($0) }
    }

    private func markRecentlyUsed(_ directory: URL) {
      recency.removeAll { $0 == directory }
      recency.append(directory)
    }

    private func trimToCapacity() {
      while cachedEntries.count > capacity, let evicted = recency.first {
        recency.removeFirst()
        cachedEntries[evicted] = nil
      }
    }
  }
  ```

- [x] **Step 4: Run cache tests and verify they pass**

  ```bash
  swiftly run swift test \
    --package-path swift-tui-examples/file-previewer \
    --filter DirectoryEntryCacheTests
  ```

  Expected: PASS.

- [x] **Step 5: Commit**

  ```bash
  git -C swift-tui-examples add \
    file-previewer/Sources/FilePreviewerApp/DirectoryEntryCache.swift \
    file-previewer/Tests/FilePreviewerAppTests/DirectoryEntryCacheTests.swift
  git -C swift-tui-examples commit -m "fix: add file previewer directory cache"
  ```

---

### Task 2: Wire Directory Caching Into ColumnBrowser

**Files:**
- Modify: `swift-tui-examples/file-previewer/Sources/FilePreviewerApp/ColumnBrowser.swift`
- Create: `swift-tui-examples/file-previewer/Tests/FilePreviewerAppTests/ColumnBrowserCacheTests.swift`

- [x] **Step 1: Write a failing browser cache test**

  Create `ColumnBrowserCacheTests.swift`:

  ```swift
  @testable import FilePreviewerApp
  import Foundation
  import SwiftTUI
  import Testing

  @MainActor
  struct ColumnBrowserCacheTests {
    @Test("browser does not reread the same directory across repeated renders")
    func browserDoesNotRereadDirectoryAcrossRepeatedRenders() {
      let root = URL(fileURLWithPath: "/tmp/root")
      var loadCount = 0
      let cache = DirectoryEntryCache(capacity: 8) { directory in
        loadCount += 1
        return [
          FileEntry(
            url: directory.appendingPathComponent("one.swift"),
            isDirectory: false
          ),
          FileEntry(
            url: directory.appendingPathComponent("two.swift"),
            isDirectory: false
          ),
        ]
      }
      let browser = ColumnBrowser(
        path: [root],
        registry: .defaults,
        entryCache: cache
      )
      let renderer = DefaultRenderer()

      _ = renderer.render(
        browser,
        context: .init(identity: Identity(components: ["Root"])),
        proposal: .init(width: 80, height: 20)
      )
      _ = renderer.render(
        browser,
        context: .init(identity: Identity(components: ["Root"])),
        proposal: .init(width: 80, height: 20)
      )

      #expect(loadCount == 1)
    }
  }
  ```

- [x] **Step 2: Run test and verify it fails**

  ```bash
  swiftly run swift test \
    --package-path swift-tui-examples/file-previewer \
    --filter ColumnBrowserCacheTests
  ```

  Expected: FAIL because `ColumnBrowser` does not accept `entryCache`.

- [x] **Step 3: Add cache ownership to `ColumnBrowser`**

  Modify the stored properties and init in `ColumnBrowser.swift`:

  ```swift
  public struct ColumnBrowser: View {
    @State private var path: [URL]
    @State private var selection: [URL: URL] = [:]
    @State private var activeColumn: Int = 0
    @State private var previewSession: TerminalProcessSession?
    @State private var previewedURL: URL?
    @State private var entryCache: DirectoryEntryCache
    @FocusState private var isFocused: Bool

    private let registry: PreviewerRegistry

    public init(
      path: [URL],
      registry: PreviewerRegistry = .defaults,
      entryCache: DirectoryEntryCache = DirectoryEntryCache()
    ) {
      let normalizedPath =
        path.isEmpty
        ? [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        : path
      _path = State(initialValue: normalizedPath)
      _entryCache = State(initialValue: entryCache)
      self.registry = registry
    }
  ```

  Replace `entries(in:)` with:

  ```swift
  private func entries(in directory: URL) -> [FileEntry] {
    entryCache.entries(in: directory)
  }
  ```

  Update path-trimming helpers so the cache does not grow as the user moves
  across sibling branches:

  ```swift
  private func clearDescendants(after directory: URL) {
    path = pathPrefix(through: directory)
    activeColumn = min(activeColumn, max(0, path.count - 1))
    entryCache.retainOnly(Set(path))
  }
  ```

  After adding a child directory in `advanceOrPreview`, keep the cache scoped to
  the visible Miller path:

  ```swift
  if isDirectory {
    let prefix = pathPrefix(through: directory)
    path = prefix + [selected]
    activeColumn = max(0, path.count - 1)
    entryCache.retainOnly(Set(path))
    previewSession = nil
    previewedURL = nil
  } else {
    clearDescendants(after: directory)
    let command = registry.command(for: selected)
    previewSession = TerminalProcessSession(
      command: command.executable,
      arguments: command.arguments(selected),
      initialSize: CellSize(width: 80, height: 40)
    )
    previewedURL = selected
  }
  ```

- [x] **Step 4: Keep root view source-compatible**

  `FilePreviewerRootView` can keep its public init unchanged. It should continue
  to construct `ColumnBrowser(path:registry:)`; the cache defaults in
  `ColumnBrowser` are sufficient.

- [x] **Step 5: Run browser cache tests**

  ```bash
  swiftly run swift test \
    --package-path swift-tui-examples/file-previewer \
    --filter ColumnBrowserCacheTests
  ```

  Expected: PASS.

- [x] **Step 6: Run the full FilePreviewer test target**

  ```bash
  swiftly run swift test \
    --package-path swift-tui-examples/file-previewer
  ```

  Expected: PASS.

- [x] **Step 7: Commit**

  ```bash
  git -C swift-tui-examples add \
    file-previewer/Sources/FilePreviewerApp/ColumnBrowser.swift \
    file-previewer/Tests/FilePreviewerAppTests/ColumnBrowserCacheTests.swift
  git -C swift-tui-examples commit -m "fix: cache file previewer directory listings"
  ```

---

### Task 3: Terminate Replaced Preview Sessions

**Files:**
- Create: `swift-tui-examples/file-previewer/Sources/FilePreviewerApp/PreviewSessionSlot.swift`
- Create: `swift-tui-examples/file-previewer/Tests/FilePreviewerAppTests/PreviewSessionSlotTests.swift`
- Modify: `swift-tui-examples/file-previewer/Sources/FilePreviewerApp/ColumnBrowser.swift`

- [x] **Step 1: Write failing preview session ownership tests**

  Create `PreviewSessionSlotTests.swift`:

  ```swift
  @testable import FilePreviewerApp
  import Testing

  @MainActor
  struct PreviewSessionSlotTests {
    @Test("replace terminates the previous session")
    func replaceTerminatesPreviousSession() {
      let first = FakePreviewSession()
      let second = FakePreviewSession()
      let slot = PreviewSessionSlot<FakePreviewSession> { session in
        session.terminate()
      }

      slot.replace(with: first)
      slot.replace(with: second)

      #expect(slot.current === second)
      #expect(first.terminationCount == 1)
      #expect(second.terminationCount == 0)
    }

    @Test("replacing with the same session is a no-op")
    func replacingWithSameSessionDoesNotTerminate() {
      let session = FakePreviewSession()
      let slot = PreviewSessionSlot<FakePreviewSession> { session in
        session.terminate()
      }

      slot.replace(with: session)
      slot.replace(with: session)

      #expect(slot.current === session)
      #expect(session.terminationCount == 0)
    }

    @Test("clear terminates the current session once")
    func clearTerminatesCurrentSessionOnce() {
      let session = FakePreviewSession()
      let slot = PreviewSessionSlot<FakePreviewSession> { session in
        session.terminate()
      }

      slot.replace(with: session)
      slot.clear()
      slot.clear()

      #expect(slot.current == nil)
      #expect(session.terminationCount == 1)
    }
  }

  @MainActor
  private final class FakePreviewSession {
    private(set) var terminationCount = 0

    func terminate() {
      terminationCount += 1
    }
  }
  ```

- [x] **Step 2: Run tests and verify they fail**

  ```bash
  swiftly run swift test \
    --package-path swift-tui-examples/file-previewer \
    --filter PreviewSessionSlotTests
  ```

  Expected: FAIL because `PreviewSessionSlot` does not exist.

- [x] **Step 3: Implement `PreviewSessionSlot`**

  Create `PreviewSessionSlot.swift`:

  ```swift
  @MainActor
  public final class PreviewSessionSlot<Session: AnyObject> {
    public typealias Termination = @MainActor (Session) -> Void

    private let terminate: Termination
    public private(set) var current: Session?

    public init(terminate: @escaping Termination) {
      self.terminate = terminate
    }

    public func replace(with next: Session?) {
      guard current !== next else {
        return
      }
      let previous = current
      current = next
      if let previous {
        terminate(previous)
      }
    }

    public func clear() {
      replace(with: nil)
    }
  }
  ```

- [x] **Step 4: Run slot tests and verify they pass**

  ```bash
  swiftly run swift test \
    --package-path swift-tui-examples/file-previewer \
    --filter PreviewSessionSlotTests
  ```

  Expected: PASS.

- [x] **Step 5: Wire the slot into `ColumnBrowser`**

  Replace the preview session state in `ColumnBrowser.swift`:

  ```swift
  @State private var previewSessions: PreviewSessionSlot<TerminalProcessSession>
  @State private var previewedURL: URL?
  ```

  Initialize it in `ColumnBrowser.init`:

  ```swift
  _previewSessions = State(
    initialValue: PreviewSessionSlot<TerminalProcessSession> { session in
      Task {
        await session.terminate()
      }
    }
  )
  ```

  Update `previewPane`:

  ```swift
  @ViewBuilder
  private var previewPane: some View {
    if let previewSession = previewSessions.current {
      TerminalView(session: previewSession)
        .border(.separator)
    } else {
      VStack(alignment: .leading, spacing: 1) {
        Text("Preview")
          .foregroundStyle(.muted)
        Divider()
        Text("(select a file)")
          .foregroundStyle(.separator)
      }
      .padding(1)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .border(.separator)
    }
  }
  ```

  Add helpers:

  ```swift
  private func clearPreview() {
    previewSessions.clear()
    previewedURL = nil
  }

  private func showPreview(for selected: URL) {
    let command = registry.command(for: selected)
    previewSessions.replace(
      with: TerminalProcessSession(
        command: command.executable,
        arguments: command.arguments(selected),
        initialSize: CellSize(width: 80, height: 40)
      )
    )
    previewedURL = selected
  }
  ```

  Replace every `previewSession = nil; previewedURL = nil` pair with
  `clearPreview()`. Replace file-preview construction with
  `showPreview(for: selected)`.

- [x] **Step 6: Run the full FilePreviewer test target**

  ```bash
  swiftly run swift test \
    --package-path swift-tui-examples/file-previewer
  ```

  Expected: PASS.

- [x] **Step 7: Commit**

  ```bash
  git -C swift-tui-examples add \
    file-previewer/Sources/FilePreviewerApp/PreviewSessionSlot.swift \
    file-previewer/Sources/FilePreviewerApp/ColumnBrowser.swift \
    file-previewer/Tests/FilePreviewerAppTests/PreviewSessionSlotTests.swift
  git -C swift-tui-examples commit -m "fix: terminate replaced file preview sessions"
  ```

---

### Task 4: Render File Rows With LazyVStack

**Files:**
- Create: `swift-tui-examples/file-previewer/Sources/FilePreviewerApp/FileColumn.swift`
- Modify: `swift-tui-examples/file-previewer/Sources/FilePreviewerApp/ColumnBrowser.swift`
- Create: `swift-tui-examples/file-previewer/Tests/FilePreviewerAppTests/FileColumnRenderingTests.swift`

- [x] **Step 1: Write a failing large-column rendering test**

  Create `FileColumnRenderingTests.swift`:

  ```swift
  @testable import FilePreviewerApp
  import Foundation
  import SwiftTUI
  import Testing

  @MainActor
  struct FileColumnRenderingTests {
    @Test("large file columns realize viewport-scale row work")
    func largeFileColumnsRealizeViewportScaleRowWork() {
      let directory = URL(fileURLWithPath: "/tmp/large")
      let entries = (0..<1_000).map { index in
        FileEntry(
          url: directory.appendingPathComponent("file-\(index).swift"),
          isDirectory: false
        )
      }
      let renderer = DefaultRenderer()

      let artifacts = renderer.render(
        FileColumn(
          directory: directory,
          entries: entries,
          selection: entries[0].url,
          isActive: true
        ),
        context: .init(identity: Identity(components: ["Column"])),
        proposal: .init(width: 30, height: 8)
      )
      let rendered = artifacts.rasterSurface.lines.joined(separator: "\n")

      #expect(rendered.contains("file-0.swift"))
      #expect(!rendered.contains("file-999.swift"))
      #expect(artifacts.diagnostics.counts.resolvedNodes < 80)
      #expect(artifacts.diagnostics.counts.measuredNodes < 80)
      #expect(artifacts.diagnostics.counts.placedNodes < 80)
    }
  }
  ```

- [x] **Step 2: Run test and verify it fails**

  ```bash
  swiftly run swift test \
    --package-path swift-tui-examples/file-previewer \
    --filter FileColumnRenderingTests
  ```

  Expected: FAIL because `FileColumn` is private and eager, or because node
  counts scale with the 1,000 entries.

- [x] **Step 3: Move `FileColumn` to its own file**

  Delete the nested private `FileColumn` from `ColumnBrowser.swift` and create
  `FileColumn.swift`:

  ```swift
  public import Foundation
  public import SwiftTUI

  struct FileColumn: View {
    var directory: URL
    var entries: [FileEntry]
    var selection: URL?
    var isActive: Bool

    @State private var scrollPosition = ScrollPosition.zero

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        Text(directory.lastPathComponent.isEmpty ? directory.path : directory.lastPathComponent)
          .foregroundStyle(isActive ? .tint : .muted)
          .lineLimit(1)
          .truncationMode(.middle)
        Divider()

        if entries.isEmpty {
          Text("(empty)")
            .foregroundStyle(.separator)
        } else {
          ScrollView(
            .vertical,
            showsIndicators: true,
            position: $scrollPosition
          ) {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(entries, id: \.url) { entry in
                row(for: entry)
              }
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
      }
      .padding(1)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .border(isActive ? .tint : .separator)
      .onChange(of: selection, initial: true) { _, selected in
        keepSelectionVisible(selected)
      }
    }

    private func row(for entry: FileEntry) -> some View {
      HStack(spacing: 1) {
        Text(entry.url == selection ? ">" : " ")
          .foregroundStyle(.tint)
        Text(entry.displayName)
          .foregroundStyle(entry.url == selection ? .foreground : .separator)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }

    private func keepSelectionVisible(_ selected: URL?) {
      guard let selected,
        let index = entries.firstIndex(where: { $0.url == selected })
      else {
        scrollPosition = .zero
        return
      }
      scrollPosition = ScrollPosition(y: max(0, index - 1))
    }
  }
  ```

  Keep the `LazyVStack` content as exactly one `ForEach`. Do not put the header,
  empty-state text, or other static siblings inside the lazy stack; mixed static
  siblings use the stable child path and lose the indexed child-source benefit.

- [x] **Step 4: Run large-column rendering test**

  ```bash
  swiftly run swift test \
    --package-path swift-tui-examples/file-previewer \
    --filter FileColumnRenderingTests
  ```

  Expected: PASS.

- [x] **Step 5: Run existing lazy stack diagnostics tests**

  ```bash
  swiftly run swift test \
    --package-path swift-tui \
    --filter DiagnosticsAndCacheTests
  ```

  Expected: PASS. If these fail, stop and debug the core lazy-stack regression
  before continuing with the FilePreviewer change.

- [x] **Step 6: Run the full FilePreviewer test target**

  ```bash
  swiftly run swift test \
    --package-path swift-tui-examples/file-previewer
  ```

  Expected: PASS.

- [x] **Step 7: Commit**

  ```bash
  git -C swift-tui-examples add \
    file-previewer/Sources/FilePreviewerApp/FileColumn.swift \
    file-previewer/Sources/FilePreviewerApp/ColumnBrowser.swift \
    file-previewer/Tests/FilePreviewerAppTests/FileColumnRenderingTests.swift
  git -C swift-tui-examples commit -m "fix: lazily render file previewer columns"
  ```

---

### Task 5: Add End-To-End Regression Checks And Docs

**Files:**
- Modify: `swift-tui-examples/file-previewer/README.md`

- [x] **Step 1: Run the focused automated test suite**

  ```bash
  swiftly run swift test \
    --package-path swift-tui-examples/file-previewer
  ```

  Expected: PASS, including:

  - `DirectoryEntryCacheTests`
  - `ColumnBrowserCacheTests`
  - `PreviewSessionSlotTests`
  - `FileColumnRenderingTests`
  - existing `MillerLayoutTests`
  - existing `PreviewerRegistryTests`

- [x] **Step 2: Run the lazy-stack contract tests**

  ```bash
  swiftly run swift test \
    --package-path swift-tui \
    --filter LazyVStack
  swiftly run swift test \
    --package-path swift-tui \
    --filter DiagnosticsAndCacheTests
  ```

  Expected: PASS. These tests are not owned by FilePreviewer, but they protect
  the core behavior the example now depends on.

- [x] **Step 3: Build the app**

  ```bash
  swiftly run swift build \
    --package-path swift-tui-examples/file-previewer
  ```

  Expected: PASS.

- [x] **Step 4: Run a large-directory smoke check**

  ```bash
  TMPDIR="$(mktemp -d /tmp/swift-tui-file-previewer-large.XXXXXX)"
  for index in $(seq 1 1200); do
    printf 'print("%04d")\n' "$index" > "$TMPDIR/file-$index.swift"
  done
  cd "$TMPDIR"
  swiftly run swift run \
    --package-path /Users/adamz/Developer/swift-tui-org/swift-tui-examples/file-previewer \
    FilePreviewerApp
  ```

  Expected manual result:

  - Initial paint is prompt on a 1,200-file directory.
  - Holding Down does not produce multi-second render stalls.
  - The selected row remains visible as selection moves.
  - The process RSS does not climb continuously while only moving selection.

- [x] **Step 5: Run a preview-process replacement smoke check**

  ```bash
  TMPBASE="$(mktemp -d /tmp/swift-tui-file-previewer-preview.XXXXXX)"
  mkdir -p "$TMPBASE/bin" "$TMPBASE/files"
  cat > "$TMPBASE/bin/bat" <<'SCRIPT'
  #!/bin/sh
  echo "fake bat started $*"
  sleep 120
  SCRIPT
  chmod +x "$TMPBASE/bin/bat"
  for index in $(seq 1 8); do
    printf 'print("%04d")\n' "$index" > "$TMPBASE/files/file-$index.swift"
  done
  cd "$TMPBASE/files"
  PATH="$TMPBASE/bin:$PATH" swiftly run swift run \
    --package-path /Users/adamz/Developer/swift-tui-org/swift-tui-examples/file-previewer \
    FilePreviewerApp
  ```

  While the app is running, select several `.swift` files. In another terminal:

  ```bash
  pgrep -fl "$TMPBASE/bin/bat|sleep 120"
  ```

  Expected manual result: at most one fake preview command remains alive after
  the UI settles. If more than one remains, the slot is not being used on every
  clear/replace path.

- [x] **Step 6: Update README test documentation**

  Modify the `README.md` test section to say:

  ````markdown
  ## Test

  ```bash
  swiftly run swift test --package-path file-previewer
  ```

  The tests cover preview-command lookup, Miller-column width allocation,
  directory-listing caching, preview-session replacement, and large-column lazy
  rendering.
  ````

- [x] **Step 7: Run final checks**

  ```bash
  git -C swift-tui-examples diff --check
  swiftly run swift test \
    --package-path swift-tui-examples/file-previewer
  swiftly run swift build \
    --package-path swift-tui-examples/file-previewer
  ```

  Expected: PASS.

- [x] **Step 8: Commit**

  ```bash
  git -C swift-tui-examples add \
    file-previewer/README.md
  git -C swift-tui-examples commit -m "docs: document file previewer performance checks"
  ```

---

## Execution Notes

- Keep the existing dirty worktree isolated. At the time this plan was written,
  `swift-tui` had unrelated terminal-workspace fixes and `swift-tui-examples`
  had an existing `file-previewer/Package.resolved` change. Do not
  revert or absorb those changes unless the user explicitly asks.
- If a test command changes `Package.resolved`, inspect the diff before staging.
  Do not commit dependency-resolution churn as part of this fix unless it is
  required and explained.
- Use small commits in the task order above. Each commit should leave
  FilePreviewer tests passing.
- If `FileColumnRenderingTests` cannot reach the expected node-count bounds with
  `LazyVStack`, pause and investigate core lazy stack viewport propagation
  before adding app-side workarounds.
- If the manual preview-process smoke check still shows more than one child
  process, search for all `clearPreview` and `showPreview` call sites before
  changing `TerminalProcessSession`; the existing terminal-workspace store proves
  the session termination API is already available.
