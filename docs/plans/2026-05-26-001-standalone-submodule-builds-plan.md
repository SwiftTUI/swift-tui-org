# Standalone Submodule Builds Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]` / `- [x]`) syntax for tracking.

**Goal:** Make every SwiftTUI submodule (`swift-tui`, `swift-tui-examples`,
`swift-tui-web`, `swift-tui-site`) clone-and-run on its own, without checking
out the org root, while preserving today's "all HEADs together" multi-repo
development loop where editing any submodule is immediately visible to the
others. Concretely: a user clones only `swift-tui-examples`, runs
`swift run --package argparse`, and SwiftPM resolves `swift-tui` from GitHub at
a pinned revision; a contributor clones the org root with `--recurse-submodules`
and the same example resolves to the live sibling `../../swift-tui` working
tree.

**Architecture:** Formalize a three-rung resolution ladder as the org's house
pattern for cross-repo coupling — `swift-tui-site` and `swift-tui-web` already
use it for shell scripts and CLI flags; this plan extends it to
`swift-tui-examples`' `Package.swift` files, where today's hard-coded
`.package(path: "../../swift-tui")` breaks standalone clones.

The ladder:

1. **Env-var override** (`SWIFTTUI_PATH` set) → `.package(path: <override>)`.
2. **Sibling relative path** (`../../swift-tui/Package.swift` exists on disk)
   → `.package(path: "../../swift-tui")`.
3. **Remote URL** at a pinned revision synced from the org submodule SHA →
   `.package(url: "https://github.com/SwiftTUI/swift-tui.git", revision: ...)`.

`Package.swift` is executable Swift, so the ladder is expressed as
`ProcessInfo` + `FileManager` checks at manifest-evaluation time. A single
canonical snippet is generated into every example's manifest between marker
comments by a sync script. The same script writes the pinned SHA into a
top-level `.swift-tui-pin` file (so standalone clones know which revision is
canonical) and stamps it into every Package.swift's `revision:` argument.

The lone `gifeditor` example currently reaches deeper —
`.package(path: "../../swift-tui/Vendor/swift-gif")` — into a private vendor
of swift-tui that has no URL surface. Resolved by wholesale-copying
`swift-tui/Vendor/swift-gif/` (7 Swift files, ~1.4k LOC) into
`gifeditor/Vendor/swift-gif/` as a one-time setup. The example app is allowed
to drift from swift-tui's vendor copy thereafter; no ongoing sync, no
byte-equality contract.

`swift-tui` itself has only internal path deps and is already standalone.
`swift-tui-web` is a TypeScript workspace whose Swift coupling is a CLI flag
(`--package-path`), already parameterized. `swift-tui-site` already uses the
ladder in `Scripts/build_docc_site.sh` and `Scripts/check_site.sh`. Those three
repos need documentation and contract tests but no code changes.

The contract tests follow the existing org-level convention (sh_test wrappers
composed via test_suite), with one deliberate lean-in: the canonical-snippet
check uses `bazel_skylib`'s `diff_test` rule rather than custom shell diffing.
A single rendered canonical block is produced once via `genrule` from the
template plus `.swift-tui-pin`, and one `diff_test` per example compares the
example's extracted block against that canonical. This produces native
unified-diff failure messages, parallelizes across Bazel's executors, and lets
the rendered artifact cache. A small Starlark macro generates the
per-example `diff_test` + standalone-resolve `sh_test` pair so the BUILD file
stays a single declarative list of example names. Per-example contracts live
in the `swift-tui-examples` child module's `BUILD.bazel` (matching the
existing per-child `:native_gate` ownership pattern); the org root composes
them via the existing `test_suite` aggregation and adds the genuinely
cross-repo checks (pin coherence, web's `--package-path` default) at its own
level.

**Tech Stack:** SwiftPM 6.0+, executable `Package.swift` manifests using
`Foundation` (`ProcessInfo`, `FileManager`), Bash scripts for sync,
Bazel/Bzlmod for org-level contract tests, `bazel_skylib` 1.9.0 for `diff_test`
and `write_file`, Starlark macros for per-example test generation, Git
submodules for pin recording.

---

## Current Evidence

- All 13 example `Package.swift` files declare a cross-repo path dep on
  `swift-tui`. Eleven use `../../swift-tui` (the example is directly under
  the examples repo root); two use `../../../swift-tui` because they are
  one directory deeper — `SwiftUIExample/TerminalApp/Package.swift` and
  `WebExample/TerminalApp/Package.swift`. Either form only resolves when
  the example sits inside the org root as a submodule sibling of `swift-tui`.
  A standalone clone of `swift-tui-examples` has no such sibling and
  SwiftPM resolution fails immediately.
- `swift-tui-examples/gifeditor/Package.swift:42` additionally declares
  `.package(path: "../../swift-tui/Vendor/swift-gif")`, reaching into
  swift-tui's private vendor. SwiftPM has no "URL + subpath" mechanism, so this
  reach cannot be expressed via a remote `swift-tui` URL dep.
- Within `swift-tui-examples`, intra-repo relative paths (`../layouts`,
  `../../gallery`) are fine — they stay inside the examples checkout and
  survive a standalone clone. Only cross-repo hops break.
- `swift-tui/Package.swift` has only internal path deps (`Vendor/*`,
  `Sources/*`, `Platforms/*/Sources/*`). Already standalone.
- `swift-tui-web/packages/build/cli.ts:16` reads
  `--package-path` from CLI flags, defaulting to a relative `"../../"`. The web
  *runtime* package is pure TypeScript with no Swift source dependency. Already
  standalone.
- `swift-tui-site/Scripts/build_docc_site.sh:21` implements the three-rung
  ladder for the DocC source checkout: `${SWIFTTUI_CHECKOUT:-${site_root}/../${repo_name}}`,
  and at line 28-31 prefers the local sibling for `git clone` if it exists, else
  clones from `https://github.com/${repository}`. Already implements the
  pattern this plan extends.
- `swift-tui/Vendor/swift-gif` is 7 Swift files, ~1.4k LOC, 72K on disk. Git
  log shows `chore: relicense package and image vendor libs to MIT` — it's a
  hand-vendored fork with no upstream remote, so duplicating it into gifeditor
  does not introduce a new sync obligation that doesn't already exist for the
  swift-tui copy.

## Non-Goals

- Do not introduce SwiftPM semver releases of `swift-tui` as part of this
  change. The URL-fallback dep uses `revision:` pinning, not `from:`.
- Do not move examples or web into the swift-tui repo as monorepo subpackages.
  The org keeps the four-submodule shape.
- Do not replace Bazel orchestration with SwiftPM or vice versa. Bazel
  continues to orchestrate org-level contracts on top of native package gates.
- Do not enforce byte-equality between `gifeditor/Vendor/swift-gif/` and
  `swift-tui/Vendor/swift-gif/`. Example-app drift is allowed by design.
- Do not modify `swift-tui-web` runtime source code or `swift-tui-site` build
  scripts. They already implement the pattern; only documentation and contract
  tests are added.
- Do not introduce a new dependency on a manifest-time HTTP fetch or a manifest
  plugin. The dep-selection logic uses only `ProcessInfo` and `FileManager`,
  both of which SwiftPM already permits inside `Package.swift`.

## File Structure To Create Or Modify

### swift-tui-examples (the bulk of the work)

- Create `swift-tui-examples/Scripts/SwiftTUIDependency.template.swift`:
  canonical text of the dep-selection helper, with a `%REVISION%` placeholder.
- Create `swift-tui-examples/Scripts/sync-swift-tui-dep.sh`: regenerates the
  `swift-tui-dep:begin..end` block in every example's `Package.swift` from the
  template, substituting `%REVISION%` from `.swift-tui-pin`. Idempotent. Asserts
  every example's manifest contains exactly one matching marker pair. Used by
  developers; the Bazel layer does not invoke this script — it independently
  re-renders the canonical block via `genrule` and compares with `diff_test`.
- Create `swift-tui-examples/Scripts/render-dep-block.sh`: small helper that
  takes `(template, pin)` and writes the rendered canonical block to stdout.
  Invoked by both `sync-swift-tui-dep.sh` (for in-place insertion) and the
  Bazel `genrule` (to produce the diff_test reference output). Single rendering
  implementation, no drift.
- Create `swift-tui-examples/Scripts/bump-swift-tui-pin.sh`: takes a SHA (or
  reads it from `${SWIFTTUI_PATH:-../../swift-tui}` via `git rev-parse HEAD`),
  writes it into `.swift-tui-pin`, then invokes `sync-swift-tui-dep.sh`.
- Create `swift-tui-examples/.swift-tui-pin`: one-line file containing the
  current canonical swift-tui SHA. Committed.
- Modify `swift-tui-examples/argparse/Package.swift`: replace the bare
  `.package(name: "swift-tui", path: "../../swift-tui")` line with the
  generated `swift-tui-dep:begin..end` block.
- Modify `swift-tui-examples/file-previewer/Package.swift`: same.
- Modify `swift-tui-examples/gallery/Package.swift`: same.
- Modify `swift-tui-examples/gifcat/Package.swift`: same.
- Modify `swift-tui-examples/gitviz/Package.swift`: same.
- Modify `swift-tui-examples/layouts/Package.swift`: same.
- Modify `swift-tui-examples/LayoutsSwiftUI/Package.swift`: same (intra-repo
  `../layouts` dep is preserved unchanged).
- Modify `swift-tui-examples/minimal/Package.swift`: same.
- Modify `swift-tui-examples/SwiftUIExample/TerminalApp/Package.swift`: same
  (intra-repo `../../gallery` dep is preserved unchanged; this manifest is
  doubly nested so the helper needs to find the sibling at `../../../swift-tui`,
  not `../../swift-tui` — the template handles this by walking up from
  `#filePath` rather than hard-coding the depth).
- Modify `swift-tui-examples/terminal-workspace/Package.swift`: same.
- Modify `swift-tui-examples/WebExample/TerminalApp/Package.swift`: same
  (doubly nested, see SwiftUIExample note; intra-repo `../../gallery` dep is
  preserved unchanged).
- Modify `swift-tui-examples/WebHostExample/Package.swift`: same (single-level
  nesting, like argparse).
- Create `swift-tui-examples/gifeditor/Vendor/swift-gif/`: wholesale copy of
  `swift-tui/Vendor/swift-gif/` at the current pinned SHA (LICENSE, README.md,
  Package.swift, Sources/GIF/*.swift, Sources/GIFTests/*.swift). One-time
  setup, no ongoing sync.
- Modify `swift-tui-examples/gifeditor/Package.swift`: replace the dep block
  with the generated helper; replace
  `.package(path: "../../swift-tui/Vendor/swift-gif")` with
  `.package(path: "Vendor/swift-gif")`.
- Modify `swift-tui-examples/README.md`: document standalone-clone instructions
  (clone, `swift run --package <name>`), document `SWIFTTUI_PATH` override,
  document the `swift package reset` recommendation when switching a working
  copy between org-root and standalone modes.
- Modify `swift-tui-examples/.gitignore`: nothing currently needed, but
  confirm `.build/` and SwiftPM artifact dirs stay ignored after the new
  Scripts/ directory lands.
- Modify `swift-tui-examples/MODULE.bazel`: add
  `bazel_dep(name = "bazel_skylib", version = "1.9.0")`.
- Create `swift-tui-examples/tools/bazel/examples_contracts.bzl`: Starlark
  macro `examples_contracts(name, examples)` that, for each example name,
  generates (a) a `genrule` extracting the `swift-tui-dep:begin..end` block
  from that example's `Package.swift`, (b) a `diff_test` comparing it to the
  shared `:rendered_dep_block` artifact, and (c) an `sh_test` running
  `tools/bazel/standalone_resolve_one.sh` against that example. Also defines
  a `no_cross_repo_path_deps` sh_test (single repo-wide grep, not per-example).
  Aggregates everything into a `test_suite` named after the macro's `name` arg.
- Create `swift-tui-examples/tools/bazel/standalone_resolve_one.sh`: takes an
  example name as `$1`, copies that example to a temp dir, ensures no sibling
  `swift-tui` is reachable, unsets `SWIFTTUI_PATH`, runs
  `swift package resolve --package-path <tempdir>`, asserts success. Returns
  the temp dir path on failure for debugging.
- Create `swift-tui-examples/tools/bazel/no_cross_repo_path_deps.sh`: grep
  asserting that no example `Package.swift` outside the generated
  `swift-tui-dep:begin..end` block declares `.package(path: "../../swift-tui`
  or any path containing `swift-tui/Vendor/`. Cheap, runs in the sandbox.
- Modify `swift-tui-examples/BUILD.bazel`:
  - Load `diff_test` from `@bazel_skylib//rules:diff_test.bzl` and the new
    `examples_contracts` macro.
  - Add `exports_files([".swift-tui-pin", "Scripts/SwiftTUIDependency.template.swift"])`
    so the org root's pin-coherence test can label-address them.
  - Add a `genrule(name = "rendered_dep_block", srcs = [template, pin],
    tools = ["Scripts/render-dep-block.sh"], outs = ["rendered_dep_block.swift"],
    cmd = "$(location ...) ... > $@")`.
  - Invoke `examples_contracts(name = "contracts", examples = [...13 names...])`.
  - The existing `:native_gate` rule stays unchanged.

### Org root

- Modify `AGENTS.md` ("Critical workflow" section): add the sync step to the
  "Bumping pins" workflow — after `git submodule update --remote --merge
  swift-tui`, run `cd swift-tui-examples && Scripts/bump-swift-tui-pin.sh`,
  commit the resulting changes inside the examples submodule, then record the
  new examples submodule pin at the org root.
- Modify `MODULE.bazel`: add
  `bazel_dep(name = "bazel_skylib", version = "1.9.0")`.
- Modify `BUILD.bazel`: add two new org-level sh_test targets (pin coherence
  and web `--package-path` default), then extend `:org_fast` to include both
  *and* `@swift_tui_examples//:contracts` (the test_suite the macro produces
  in the child). The existing four `:org_fast` members stay.
- Create `tools/bazel/check_web_package_path_default.sh`: greps
  `swift-tui-web/packages/build/cli.ts` for the relative `--package-path`
  default and fails if it becomes an absolute path. Genuinely cross-repo
  (lives at the org root because it gates one repo's contract from another's
  perspective). Cheap regression guard.
- Create `tools/bazel/check_pin_coherence.sh`: asserts
  `swift-tui-examples/.swift-tui-pin` matches the org-recorded swift-tui
  submodule SHA from `git submodule status swift-tui`. Genuinely cross-repo
  (compares two pins from different submodules). Catches the "submodule
  bumped but examples pin not synced" failure mode.

Note: the per-example contract scripts (snippet-canonical, standalone-resolve,
no-cross-repo-path-deps) are intentionally NOT placed in the org root's
`tools/bazel/`. They live in `swift-tui-examples/tools/bazel/` because they
gate a single child module's contract; only the genuinely cross-repo gates
(pin coherence, web default) live at the org root. This matches the existing
ownership pattern where each child owns its `native_gate` and the org root
composes.

### swift-tui

- No code changes.
- Optionally update `swift-tui/AGENTS.md` (or `README.md`) to mention that
  `Vendor/swift-gif` is privately vendored and is also duplicated into
  `swift-tui-examples/gifeditor/Vendor/swift-gif`. This is a documentation
  hint for anyone fixing a swift-gif bug, not a process requirement.

### swift-tui-web

- No code changes.
- Modify `swift-tui-web/AGENTS.md`: document the three-rung ladder and that
  the `--package-path` flag's relative default is the rung-2 case for
  in-repo development.

### swift-tui-site

- No code changes.
- Modify `swift-tui-site/AGENTS.md`: document `SWIFTTUI_CHECKOUT`,
  `SWIFTTUI_EXAMPLES_CHECKOUT`, `SWIFTTUI_WEB_CHECKOUT`, and `WEBEXAMPLE_DIR`
  as the canonical env-var names for the rung-1 override on this side.

---

## Implementation Steps

Order matters: the template and sync tool must exist before any example
manifest can be regenerated. Contract tests must land before
the manifest changes are merged, so the tests gate the migration rather than
trail it.

### Phase 1: scaffold the sync mechanism

- [ ] Add `swift-tui-examples/Scripts/SwiftTUIDependency.template.swift`
  containing the canonical dep-selection helper with a `%REVISION%` token.
- [ ] Add `swift-tui-examples/Scripts/sync-swift-tui-dep.sh` that finds every
  `Package.swift` in the examples repo (excluding `.build/` and `node_modules/`),
  asserts each contains either no `swift-tui-dep:` markers (initial migration)
  or a single matched begin/end pair, and replaces (or inserts) the block from
  the template using the pin SHA. Make the script work on macOS bash 3.2.
- [ ] Add `swift-tui-examples/Scripts/bump-swift-tui-pin.sh` that resolves the
  new SHA (positional arg or `git -C ${SWIFTTUI_PATH:-../../swift-tui} rev-parse HEAD`),
  writes it to `.swift-tui-pin`, runs `sync-swift-tui-dep.sh`, prints a summary
  diff.
- [ ] Add `swift-tui-examples/.swift-tui-pin` with the current submodule SHA
  (today: `b9a0298577b8b35c4b61948d43f1633571fece16`).
- [ ] Manually test the scripts against a throwaway `Package.swift` to confirm
  marker handling, multiple-marker rejection, and pin substitution.

### Phase 2: contract tests (gate the migration)

Architectural note: the per-example checks (snippet canonical, standalone
resolve, no-cross-repo-path-deps) are owned by the `swift-tui-examples` child
module's `BUILD.bazel`, matching how `:native_gate` is owned per-child today.
The org root only owns the genuinely cross-repo gates (pin coherence, web
package-path default). The org root composes both via the existing
`:org_fast` test_suite.

**Org root: dependency + cross-repo gates**

- [ ] Add `bazel_dep(name = "bazel_skylib", version = "1.9.0")` to the org root
  `MODULE.bazel`.
- [ ] Add `tools/bazel/check_web_package_path_default.sh` (sh_test) — greps
  `swift-tui-web/packages/build/cli.ts:16` and asserts the relative default.
- [ ] Add `tools/bazel/check_pin_coherence.sh` (sh_test) — diffs the SHA in
  `swift-tui-examples/.swift-tui-pin` against `git submodule status swift-tui`.
- [ ] Wire both into `BUILD.bazel` as `sh_test` rules with the existing
  `local` + `no-sandbox` tags.
- [ ] Extend the `:org_fast` test_suite to include `:web_package_path_default`,
  `:pin_coherence`, and `@swift_tui_examples//:contracts`.

**swift-tui-examples: dependency + Bazel machinery**

- [ ] Add `bazel_dep(name = "bazel_skylib", version = "1.9.0")` to
  `swift-tui-examples/MODULE.bazel`.
- [ ] Add `swift-tui-examples/tools/bazel/standalone_resolve_one.sh` (the
  per-example resolver helper invoked from the macro). Make it work on
  macOS bash 3.2; surface the temp dir in the failure path for debugging.
- [ ] Add `swift-tui-examples/tools/bazel/no_cross_repo_path_deps.sh` (the
  repo-wide grep check).
- [ ] Add `swift-tui-examples/tools/bazel/examples_contracts.bzl` (the
  Starlark macro). Verify the macro handles names containing `/` (e.g.
  `SwiftUIExample/TerminalApp`) by mapping `/` → `_` in target names while
  keeping the actual path for genrule srcs.
- [ ] Modify `swift-tui-examples/BUILD.bazel`:
  - Load `diff_test` and `examples_contracts`.
  - Add `exports_files([".swift-tui-pin",
    "Scripts/SwiftTUIDependency.template.swift"])`.
  - Add the `rendered_dep_block` genrule.
  - Invoke `examples_contracts(name = "contracts", examples = [...13 names])`.

**Gate verification (proves the tests check something before migrating)**

- [ ] Run `bazel test //:org_fast` against the *current, un-migrated* state
  of the examples. Expect:
  - `:web_package_path_default` PASS (web is already in the desired shape).
  - `:pin_coherence` PASS (the pin file doesn't exist yet — Phase 1
    establishes it; this step verifies the gate fires before that, so reorder
    if needed, or accept that this gate isn't useful until Phase 1 lands).
  - `@swift_tui_examples//:contracts` FAILS broadly — every example's
    `diff_test` and `standalone_resolve` should fail because the dep-block
    doesn't exist yet, no `rendered_dep_block` reference exists, and the
    current manifests resolve only via the broken `../../swift-tui` path.
  - This expected-failure step proves the tests have real teeth and the
    migration moves them from red to green rather than from green to green.

### Phase 3: migrate the 12 non-gifeditor examples

- [ ] Run `Scripts/sync-swift-tui-dep.sh` against each example in turn,
  inspecting the diff per example. The script inserts the dep-block once the
  legacy line is removed; the legacy line removal is the per-example edit.
- [ ] For the two doubly-nested examples (`SwiftUIExample/TerminalApp` and
  `WebExample/TerminalApp`), confirm the template-computed sibling path
  resolves correctly. The template helper walks up parent directories from
  `#filePath`'s directory looking for a sibling `swift-tui/Package.swift` —
  so the same template code works for both single-level (`argparse`,
  `WebHostExample`, etc.) and doubly-nested examples without manifest-side
  customization.
- [ ] After each example is migrated, run `swift package resolve` from the
  org root for that example, confirming rung-2 (sibling) resolution still
  produces today's build graph.
- [ ] Verify the three intra-repo path deps (`../layouts`, `../../gallery`)
  survive unchanged.
- [ ] Run `bazel test @swift_tui_examples//:contracts` and confirm each
  migrated example's `snippet_canonical_<name>` diff_test passes and the
  repo-wide `no_cross_repo_path_deps` sh_test passes for the migrated subset.
  (Standalone-resolve tests are addressed in Phase 5; they may still fail
  here because the URL fallback hasn't been exercised yet.)

### Phase 4: migrate gifeditor with wholesale swift-gif copy

- [ ] Copy `swift-tui/Vendor/swift-gif/` to
  `swift-tui-examples/gifeditor/Vendor/swift-gif/` via `cp -R`. Preserve
  LICENSE, README.md, Package.swift, Sources/GIF/*.swift,
  Sources/GIFTests/*.swift.
- [ ] Run `Scripts/sync-swift-tui-dep.sh` against `gifeditor/Package.swift`
  to install the dep-block.
- [ ] Edit `gifeditor/Package.swift` to replace
  `.package(path: "../../swift-tui/Vendor/swift-gif")` with
  `.package(path: "Vendor/swift-gif")`. Other gifeditor target wiring stays
  the same.
- [ ] Run `swift package resolve` and `swift build` from the gifeditor
  directory, confirming both rung-2 (sibling swift-tui via dep-block) and
  the local Vendor/swift-gif resolve cleanly.
- [ ] Run `bazel test @swift_tui_examples//:contracts`; confirm
  `no_cross_repo_path_deps` accepts the new gifeditor state (no
  `swift-tui/Vendor/` reach) and `snippet_canonical_gifeditor` passes.

### Phase 5: standalone-resolution verification

- [ ] Run `bazel test @swift_tui_examples//:contracts` and confirm every
  per-example `standalone_resolve_<name>` test passes. Manually step-debug
  one (`swift-tui-examples/tools/bazel/standalone_resolve_one.sh argparse`)
  for clarity — confirms rung-3 fires when sibling is absent and the URL
  fetch resolves to the pinned SHA.
- [ ] Bash-test the `SWIFTTUI_PATH` override path: `SWIFTTUI_PATH=/tmp/fake
  swift package resolve` should fail with a path-not-found error (proving
  rung-1 is reached); pointing it at a real alt checkout should succeed.

### Phase 6: documentation and workflow updates

- [ ] Update `swift-tui-examples/README.md` with a "Standalone usage" section
  covering: clone, `swift run --package <name>`, the `SWIFTTUI_PATH` override,
  and the `swift package reset` recommendation when switching modes.
- [ ] Update `AGENTS.md` at the org root's "Critical workflow" section with
  the bump-pin step that runs `Scripts/bump-swift-tui-pin.sh` inside the
  examples submodule.
- [ ] Update `swift-tui-web/AGENTS.md` and `swift-tui-site/AGENTS.md` to
  reference the three-rung ladder and name `SWIFTTUI_CHECKOUT` /
  `WEBEXAMPLE_DIR` / `SWIFTTUI_PATH` as the canonical override env vars.
- [ ] Optional: add a one-line mention to `swift-tui/AGENTS.md` that
  `Vendor/swift-gif` is duplicated in `swift-tui-examples/gifeditor`.

### Phase 7: org-level smoke test

- [ ] From the org root: `bazel test //:org_full`. Expect all native gates
  and the new contract tests to pass.
- [ ] From a fresh `git clone --depth=1 git@github.com:SwiftTUI/swift-tui-examples.git`
  (outside the org root), `cd swift-tui-examples/argparse && swift run`.
  Expect SwiftPM to fetch swift-tui at the pinned SHA from GitHub and the
  example to build and run.
- [ ] From the same fresh clone, `cd swift-tui-examples/gifeditor && swift build`.
  Expect success using `Vendor/swift-gif` locally.

---

## Risks and Mitigations

- **SwiftPM resolution cache staleness when switching modes.** A working copy
  that has resolved against rung-2 (sibling) once may keep stale
  `.swiftpm/configuration/` and `Package.resolved` state when the sibling later
  becomes unavailable. Mitigation: document `swift package reset` in the
  standalone README and call it out in the workflow note in `AGENTS.md`.
- **Manifest-time `Foundation` use.** Although SwiftPM permits `Foundation`
  imports in `Package.swift`, future SwiftPM versions could tighten sandboxing.
  Mitigation: keep the helper minimal (`ProcessInfo.processInfo.environment`,
  `FileManager.default.fileExists`), set `// swift-tools-version: 6.0` as the
  floor, and add a CI matrix entry pinning to that toolchain so a regression
  surfaces immediately.
- **Standalone-clone network requirement.** Rung-3 requires internet to fetch
  swift-tui from GitHub. Acceptable cost; documented in README.
- **Two copies of swift-gif drift independently.** Intended. swift-tui's
  `Vendor/swift-gif` is already a hand-maintained fork with no upstream remote,
  and `gifeditor` is example code, not framework code. If a swift-gif bug
  affecting gifeditor lands in swift-tui, a contributor copies the fix across
  ad-hoc.
- **`Package.swift` snippet drift across the 13 examples.** Caught by
  per-example `diff_test` targets in `@swift_tui_examples//:contracts`,
  composed into `:org_fast`. Each failure points to the specific drifted
  example with a native unified-diff message.
- **Forgotten pin bump after submodule update.** If a contributor bumps the
  swift-tui submodule at the org root but skips `bump-swift-tui-pin.sh`, the
  examples' URL fallback drifts behind the org's sibling resolution.
  Mitigation: `tools/bazel/check_pin_coherence.sh` (org-root sh_test in
  `:org_fast`) asserts `.swift-tui-pin` matches the org-recorded swift-tui
  submodule SHA. CI surfaces the mismatch immediately.
- **Examples submodule's history balloons by the swift-gif copy.** ~1.4k LOC
  in one commit. Acceptable; comparable to other vendor-style commits already
  in the org.

