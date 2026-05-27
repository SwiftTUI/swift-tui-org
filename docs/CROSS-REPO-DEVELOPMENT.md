# Cross-Repo Development

How to iterate on more than one SwiftTUI submodule at a time, and how the
coordination overlay supports that loop without breaking the public-contract
invariant that child repositories must build standalone from tagged HTTPS
dependencies.

## Why the overlay exists

Each public child repo's checked-in manifests (`Package.swift`,
`package.json`, `WebExample/package.json`, `SwiftUIExample.xcodeproj`) point
at sibling SwiftTUI repos through public, tagged HTTPS dependencies — for
example `https://github.com/SwiftTUI/swift-tui.git` at an exact version. That
keeps a fresh clone of any child repo buildable with only its native tools.

The cost: a child repo's manifest cannot natively consume an *untagged*
sibling source checkout. SwiftPM and Bun resolve the tagged URL, not your
local edits.

The org root solves this with two cooperating layers:

1. **Bazel resolution overlay** — `MODULE.bazel` declares each sibling as a
   `bazel_dep` and pins it with `local_path_override` to the submodule path,
   so any Bazel target resolves `@swift_tui//…`, `@swift_tui_web//…`, etc. to
   the local submodule trees rather than to a registry archive.

2. **File-system overlay** — `tools/coordination/materialize_pretag_overlay.sh`
   copies each pinned child into `.build/coordination/<scope>-<mode>/` and
   rewrites the manifests inside that temporary copy: the SwiftPM URL becomes
   a relative `path:` dep; the examples Bun workspace list grows the web
   packages; the `pbxproj` gets its `relativePath` fixed up; etc. Native
   tools (`swift`, `bun`, `xcodebuild`) then run against the overlay.

Bazel orchestrates the file-system overlay through dedicated gate targets. It
does not replace SwiftPM, Bun, npm, Astro, or DocC as the public package
manager of record.

## Source modes

Both the materializer and the dev wrapper accept `--source-mode {head,worktree}`
(or `SWIFTTUI_ORG_OVERLAY_SOURCE_MODE` in the environment):

| Mode | What it copies | Default for | Use when |
| --- | --- | --- | --- |
| `head` | `git archive HEAD` of each submodule (tracked files only, ignored cruft skipped) | `materialize_pretag_overlay.sh`, `//:examples_pretag_native_gate`, `//:site_pretag_native_gate` | Matching CI byte-for-byte; reproducing a pretag failure locally; verifying a pin bump. |
| `worktree` | Live working tree via `rsync -a` (excludes `.git`, `.build`, `node_modules`, `bazel-*`, `.DS_Store`) | `bazel run //:open_overlay`, `//:examples_worktree_gate`, `//:site_worktree_gate` | Iterating against uncommitted edits across more than one submodule; running the gate before committing a child SHA. |

The two modes write to *different* output directories
(`.build/coordination/{examples,site}-{pretag,worktree}/` and
`.build/coordination/dev-overlay/`), so a worktree-mode run never clobbers a
concurrent CI-shape pretag run.

## Bazel target reference

| Target | What it runs |
| --- | --- |
| `bazel run //:open_overlay` | Materialize the dev overlay at `.build/coordination/dev-overlay/`. Defaults to worktree mode. Prints the overlay path on stdout; with `-- --print-env` emits shell-eval-able `export` lines on stdout and logs status to stderr. |
| `bazel run //:materialize_pretag_overlay` | Lower-level materializer. Defaults to head mode and `.build/coordination/pretag-overlay/`. Useful when you want to invoke `--output` against a custom path. |
| `bazel test //:examples_pretag_native_gate` | CI-shape gate: head mode, runs `check_examples.sh` against the materialized overlay. |
| `bazel test //:site_pretag_native_gate` | CI-shape gate: head mode, runs `check_site.sh` (DocC compose + Astro build) against the overlay. |
| `bazel test //:examples_worktree_gate` | Same script as `examples_pretag_native_gate`, but with `SWIFTTUI_ORG_OVERLAY_SOURCE_MODE=worktree`. Validates uncommitted edits. |
| `bazel test //:site_worktree_gate` | Worktree variant of the site gate. |
| `bazel test //:worktree_gates` | Both worktree gates. |
| `bazel test //:open_overlay_smoke` | ~10 second script-level smoke test for the overlay tooling itself. Exercises both source modes, the `--print-env` scope conditional, and the bad-mode error path *without* invoking SwiftPM or Bun. Run this when changing `materialize_pretag_overlay.sh` or `open_overlay.sh`. |
| `bazel test //:org_fast` | Cheap registry / pin / contract checks (no overlay materialization). |
| `bazel test //:org_full` | All native gates plus both pretag overlay gates. Head mode only. |

The smoke test is *not* in `//:org_fast`: the pretag gates already exercise the
overlay machinery end-to-end, and the smoke test places a temporary marker
file in `swift-tui/` to demonstrate the worktree-mode copy path. That marker
would race `//:pin_cleanliness` if both ran in parallel, so the smoke test is
tagged `exclusive` and intentionally kept out of the fast contract suite.

`bazel run //:open_overlay -- --help` and
`bazel run //:materialize_pretag_overlay -- --help` print the full flag list.

### mise task wrappers

For devs who have the mise shell activated, the most common entry points have
short aliases (defined in `mise.toml`):

| `mise` task | Wraps |
| --- | --- |
| `mise run overlay -- <args>` | `bazel run //:open_overlay -- <args>` |
| `mise run worktree-gates` | `bazel test //:worktree_gates` |
| `mise run overlay-smoke` | `bazel test //:open_overlay_smoke` |

The `overlay` task forwards anything after `--` to `open_overlay`, so
`mise run overlay -- --print-env examples` works exactly like the direct
`bazel run` form.

## Cookbooks

### 1. Iterate on `swift-tui` and test against `swift-tui-examples`

If only `swift-tui` is changing, you can skip the overlay entirely. The
examples repo's `check_examples.sh` already accepts a `SWIFTTUI_CHECKOUT` env
var and does its own runtime SwiftPM manifest swizzling at a scratch path:

```sh
SWIFTTUI_CHECKOUT="$PWD/swift-tui" \
  swift-tui-examples/Scripts/check_examples.sh
```

Uncommitted edits in `swift-tui` are visible immediately. No overlay needed.

### 2. Test uncommitted `swift-tui-web` changes against `swift-tui-examples`

When the change touches `swift-tui-web`, the env-var override alone is not
enough — the examples Bun workspace list must include the web packages.
Materialize the overlay and source the env exports:

```sh
eval "$(bazel run //:open_overlay -- --print-env examples 2>/dev/null)"
bun --cwd swift-tui-examples run check
```

`--print-env` emits exports for `SWIFTTUI_CHECKOUT`, `SWIFTTUI_WEB_CHECKOUT`,
and `SWIFTTUI_EXAMPLES_CHECKOUT` (and `WEBEXAMPLE_DIR` for the `all` scope) on
stdout while routing the overlay-path log to stderr.

Re-run `bazel run //:open_overlay` after each edit — the overlay is a one-shot
copy, not a live mirror.

### 3. Run the full CI gate against the uncommitted tree

```sh
bazel test //:examples_worktree_gate
bazel test //:site_worktree_gate
# or both:
bazel test //:worktree_gates
```

This runs the same script as the pretag gate, but with rsync of the live
working tree. If the worktree gate passes, the pretag gate will pass once you
commit (modulo gitignored generated files).

### 4. Reproduce a CI pretag failure locally

Make sure submodule pins match CI, then:

```sh
bazel test //:examples_pretag_native_gate --test_output=streamed
```

Same script, head mode (the CI default). Streamed output makes the SwiftPM
and Bun phases visible.

### 5. Make the overlay accessible from your shell for ad-hoc commands

```sh
overlay="$(bazel run //:open_overlay -- examples 2>/dev/null | tail -1)"
cd "$overlay/swift-tui-examples"
swiftly run swift run --package-path argparse argparse
```

The overlay is a normal directory tree — once materialized you can run any
native tooling against it. Edits made inside the overlay are throwaway; they
do not propagate back to the public child repos.

## Troubleshooting

**"My uncommitted edits don't show up in the overlay."**
Check the source mode. `bazel run //:open_overlay` uses worktree mode by
default, but `materialize_pretag_overlay.sh` and the pretag gates use head
mode by default. Pass `--source-mode worktree` or set
`SWIFTTUI_ORG_OVERLAY_SOURCE_MODE=worktree`.

**"I edited a `Package.swift` in `swift-tui-examples` but the rewritten
overlay still has the old URL."**
The overlay rewrites are regex-based, defined in `rewrite_examples_overlay`
in `materialize_pretag_overlay.sh`. If you added a new dependency form, the
regex may not match. Either adjust the regex or use the SwiftPM URL form that
the existing patterns recognize.

**"The worktree gate fails but the pretag gate passes."**
Most often: uncommitted-but-untracked files in a child repo (build cruft, an
ignored config file, an in-progress new file) that head mode skips and
worktree mode includes. Run `git -C swift-tui status` (and friends) to inspect.

**"`bazel run //:open_overlay` works but the materializer can't find the
repo root when I invoke the script directly."**
The scripts prefer `$BUILD_WORKSPACE_DIRECTORY` (set by `bazel run`) and fall
back to `git rev-parse --show-toplevel`. Direct shell invocation needs to
happen from inside the repo working tree (or with the script's absolute path)
so the `git rev-parse` fallback resolves correctly.

**"The overlay output disk usage is growing."**
Each scope/mode gets its own dir under `.build/coordination/`. The Bazel
gates and `open_overlay.sh` recreate their target dir on every run, so a
single mode does not accumulate. To clean everything:
`rm -rf .build/coordination/`.
