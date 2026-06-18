#!/usr/bin/env bash
set -euo pipefail

script_source="${BASH_SOURCE[0]}"
if command -v realpath >/dev/null 2>&1; then
  script_path="$(realpath "$script_source")"
else
  script_path="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$script_source")"
fi

# Resolution order: $BUILD_WORKSPACE_DIRECTORY (set by `bazel run`), then
# `git rev-parse` from the script's directory, then a structural fallback for
# Bazel test runfiles trees.
if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
  repo_root="$BUILD_WORKSPACE_DIRECTORY"
else
  repo_root="$(git -C "$(dirname "$script_path")" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$repo_root" ]]; then
    repo_root="$(cd "$(dirname "$script_path")/../.." && pwd)"
  fi
fi

scope=all
output="${SWIFTTUI_ORG_PRETAG_OVERLAY_DIR:-$repo_root/.build/coordination/pretag-overlay}"
source_mode="${SWIFTTUI_ORG_OVERLAY_SOURCE_MODE:-head}"

usage() {
  cat <<'EOF'
Usage: tools/coordination/materialize_pretag_overlay.sh [options] [all|examples|site]

Copies pinned child-repo state into a temporary coordination-owned overlay and
rewrites dependencies in that overlay only, so pre-tag integration gates can
test the root-pinned sibling sources before public release tags exist.

Every registered Bazel-module repo (from tools/registry/repos.json) is
materialized, so the overlay always reflects the full org. The positional
[all|examples|site] argument is accepted for the gate/open_overlay calling
convention but no longer narrows which repos are copied (the per-scope rewrites
self-guard on directory presence).

Options:
  --output DIR         Place the overlay at DIR (default:
                       .build/coordination/pretag-overlay).
  --source-mode MODE   Choose what to copy out of each child submodule:
                         head      git archive HEAD (default; CI-deterministic,
                                   matches what a release tag would see).
                         worktree  rsync the live working tree, including
                                   uncommitted and untracked edits. Excludes
                                   .git, .build, node_modules, bazel-*, and
                                   .DS_Store.
                       Can also be set via SWIFTTUI_ORG_OVERLAY_SOURCE_MODE.
EOF
}

fail() {
  printf '[materialize_pretag_overlay] %s\n' "$1" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output)
      if [[ "$#" -lt 2 ]]; then
        fail "--output requires a directory"
      fi
      output=$2
      shift 2
      ;;
    --source-mode)
      if [[ "$#" -lt 2 ]]; then
        fail "--source-mode requires a value"
      fi
      source_mode=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    all|examples|site)
      scope=$1
      shift
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

case "$source_mode" in
  head|worktree) ;;
  *) fail "unknown --source-mode: $source_mode (expected: head, worktree)" ;;
esac

if [[ "$source_mode" == "worktree" ]] && ! command -v rsync >/dev/null 2>&1; then
  fail "--source-mode worktree requires rsync, which was not found on PATH"
fi

# The SwiftPM version-requirement forms a public sibling manifest may use. The
# overlay localizes the dependency regardless of which form it is in; if a child
# adopts a form not listed here, verify_overlay_rewrites() below fails loud rather
# than letting the overlay silently keep an un-localized (stale/未tagged) pin.
req_re='(?:exact:\s*"[^"]+"|from:\s*"[^"]+"|\.upToNext(?:Minor|Major)\(from:\s*"[^"]+"\))'

mkdir -p "$(dirname "$output")"
output_parent="$(cd "$(dirname "$output")" && pwd)"
output="$output_parent/$(basename "$output")"

case "$output" in
  /|"$repo_root")
    fail "refusing to remove unsafe overlay directory: $output"
    ;;
esac

if [[ "$output" == "$repo_root/"* && "$output" != "$repo_root/.build/"* ]]; then
  fail "overlay directories inside the repo must live under .build/: $output"
fi

copy_repo() {
  repo=$1
  src="$repo_root/$repo"
  dst="$output/$repo"

  if [[ ! -d "$src" ]]; then
    fail "missing child repository: $repo"
  fi

  mkdir -p "$dst"
  case "$source_mode" in
    head)
      git -C "$src" archive --format=tar HEAD | tar -x -C "$dst"
      ;;
    worktree)
      rsync -a \
        --exclude='.git' \
        --exclude='.build' \
        --exclude='node_modules' \
        --exclude='bazel-*' \
        --exclude='.DS_Store' \
        "$src/" "$dst/"
      ;;
  esac
}

relative_path() {
  target=$1
  base=$2
  perl -MFile::Spec -e 'print File::Spec->abs2rel($ARGV[0], $ARGV[1])' "$target" "$base"
}

rewrite_examples_overlay() {
  examples_dir="$output/swift-tui-examples"
  swift_tui_dir="$output/swift-tui"
  swiftui_dir="$output/swift-tui-swiftui"
  web_dir="$output/swift-tui-web"

  [[ -d "$examples_dir" ]] || return 0

  while IFS= read -r -d '' manifest; do
    manifest_dir="$(cd "$(dirname "$manifest")" && pwd)"
    swift_tui_rel="$(relative_path "$swift_tui_dir" "$manifest_dir")"
    swiftui_rel="$(relative_path "$swiftui_dir" "$manifest_dir")"
    # Rewrite the swift-tui-swiftui pin first. Its URL ends in
    # `swift-tui-swiftui`; the `swift-tui` patterns below are anchored on
    # `swift-tui(.git)?"` and therefore never match it.
    perl -0pi -e \
      's#\.package\(\s*url:\s*"https://github\.com/SwiftTUI/swift-tui-swiftui(?:\.git)?",\s*'"$req_re"'\s*\)#.package(name: "swift-tui-swiftui", path: "'"$swiftui_rel"'")#sg' \
      "$manifest"
    perl -0pi -e \
      's#\.package\(\s*url:\s*"https://github\.com/SwiftTUI/swift-tui(?:\.git)?",\s*'"$req_re"'\s*\)#.package(name: "swift-tui", path: "'"$swift_tui_rel"'")#sg;
       s#\.package\(name:\s*"swift-tui",\s*path:\s*"[^"]*swift-tui"\s*\)#.package(name: "swift-tui", path: "'"$swift_tui_rel"'")#g' \
      "$manifest"
  done < <(find "$examples_dir" -name Package.swift -print0)

  pbxproj="$examples_dir/SwiftUIExample/SwiftUIExample.xcodeproj/project.pbxproj"
  if [[ -f "$pbxproj" ]]; then
    perl -0pi -e 's#relativePath = [^;]*swift-tui;#relativePath = ../../swift-tui;#g' "$pbxproj"
  fi

  # Localize the released @swifttui web packages to the overlay's local web build
  # by editing only the examples ROOT package.json: add the two local web packages
  # as Bun workspace members and redirect @swifttui/{web,build} to them via an
  # `overrides: workspace:*` block. Unlike a Swift Package.swift (code, only
  # editable by regex), package.json is data, so this is applied with a real JSON
  # parser -- a manifest reflow or a changed dependency form cannot silently no-op
  # it. Workspace members are symlinked (not file:-copied), which avoids a link
  # collision when @swifttui/build itself depends on @swifttui/web. This leaves
  # WebExample/package.json untouched (the root override reaches the workspace), so
  # we no longer rewrite a child file the root does not own.
  examples_package="$examples_dir/package.json"
  if [[ -f "$examples_package" && -d "$web_dir" ]]; then
    python3 - "$examples_package" <<'PY'
import collections, json, sys

path = sys.argv[1]
with open(path) as handle:
    data = json.load(handle, object_pairs_hook=collections.OrderedDict)

workspaces = data.setdefault("workspaces", [])
for member in ("../swift-tui-web/packages/web", "../swift-tui-web/packages/build"):
    if member not in workspaces:
        workspaces.append(member)

overrides = data.setdefault("overrides", collections.OrderedDict())
overrides["@swifttui/web"] = "workspace:*"
overrides["@swifttui/build"] = "workspace:*"

with open(path, "w") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
  fi

  examples_script="$examples_dir/Scripts/check_examples.sh"
  if [[ -f "$examples_script" ]]; then
    perl -0pi -e 's#bun install --frozen-lockfile#bun install#g' "$examples_script"
  fi
}

rewrite_site_overlay() {
  site_dir="$output/swift-tui-site"
  [[ -d "$site_dir" ]] || return 0

  site_script="$site_dir/Scripts/check_site.sh"
  if [[ -f "$site_script" ]]; then
    perl -0pi -e 's#bun install --cwd "\$examples_checkout" --frozen-lockfile#bun install --cwd "\$examples_checkout"#g' "$site_script"
  fi
}

# swift-tui-swiftui (the native SwiftUI host) consumes swift-tui through a tagged
# HTTPS dependency. Rewrite it to the overlay's local swift-tui so the host —
# and the examples that depend on it — build against pinned sibling sources
# before release tags exist.
rewrite_swiftui_overlay() {
  swiftui_dir="$output/swift-tui-swiftui"
  swift_tui_dir="$output/swift-tui"
  [[ -d "$swiftui_dir" ]] || return 0

  manifest="$swiftui_dir/Package.swift"
  if [[ -f "$manifest" ]]; then
    swift_tui_rel="$(relative_path "$swift_tui_dir" "$swiftui_dir")"
    perl -0pi -e \
      's#\.package\(\s*url:\s*"https://github\.com/SwiftTUI/swift-tui(?:\.git)?",\s*'"$req_re"'\s*\)#.package(name: "swift-tui", path: "'"$swift_tui_rel"'")#sg' \
      "$manifest"
  fi
}

# Fail loud if any sibling dependency was NOT localized. The rewrites above match
# specific manifest forms; if a child changes its manifest (a new requirement
# form, a reflow, a renamed file) a rewrite silently no-ops and the overlay would
# then build against a stale or not-yet-existent public tag, defeating the entire
# pre-tag gate. This inverts that failure mode: a missed rewrite is an immediate,
# explanatory error instead of a green build of the wrong sources.
verify_overlay_rewrites() {
  problems=()

  # After localization, NO overlay Package.swift may still pin a SwiftTUI sibling
  # (swift-tui / swift-tui-swiftui) through a public HTTPS URL.
  while IFS= read -r -d '' manifest; do
    if grep -Eq 'url:[[:space:]]*"https://github\.com/SwiftTUI/swift-tui(-swiftui)?(\.git)?"' "$manifest"; then
      problems+=("un-localized SwiftPM sibling pin in ${manifest#$output/}")
    fi
  done < <(find "$output" -name Package.swift -print0 2>/dev/null)

  # The examples root package.json must localize the web packages: @swifttui/web
  # and @swifttui/build redirected to workspace:* AND the two local web packages
  # present as workspace members. The WebExample workspace keeps its released
  # tarball deps verbatim; the root override is what localizes them, so we assert on
  # the override + workspace membership, not on WebExample's untouched deps.
  examples_package="$output/swift-tui-examples/package.json"
  if [[ -f "$examples_package" ]] && [[ -d "$output/swift-tui-web" ]] && \
     ! python3 - "$examples_package" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
overrides = data.get("overrides", {})
workspaces = data.get("workspaces", [])
redirected = all(overrides.get(k) == "workspace:*" for k in ("@swifttui/web", "@swifttui/build"))
members = all(m in workspaces for m in ("../swift-tui-web/packages/web", "../swift-tui-web/packages/build"))
sys.exit(0 if redirected and members else 1)
PY
  then
    problems+=("examples package.json did not localize @swifttui/{web,build} to local workspace members")
  fi

  if [[ "${#problems[@]}" -gt 0 ]]; then
    printf '[materialize_pretag_overlay] overlay rewrite verification FAILED:\n' >&2
    printf '  - %s\n' "${problems[@]}" >&2
    fail "a sibling dependency was not localized; update the rewrite patterns in this script for the new manifest form"
  fi
}

rm -rf "$output"
mkdir -p "$output"

# Materialize every registered Bazel-module child repo, single-sourced from
# tools/registry/repos.json via the generated array, so the overlay always
# reflects the full org -- including swift-tui-android (which the AndroidGallery
# example's Gradle build consumes) and any repo added to the registry later. The
# per-gate rewrite functions below self-guard on directory presence, so copying
# the full set is safe regardless of `scope` (now retained only for the
# open_overlay/--print-env calling convention, not to gate the copy). github
# (docs-only, bazel_module:false) carries no build contract and is not copied.
registry="$repo_root/tools/registry/repos.generated.sh"
[[ -f "$registry" ]] || fail "missing generated registry: ${registry#$repo_root/} (run: python3 tools/registry/generate.py --write)"
# shellcheck source=../registry/repos.generated.sh
source "$registry"

for repo in "${BAZEL_MODULE_REPOS[@]}"; do
  copy_repo "$repo"
done

rewrite_swiftui_overlay
rewrite_examples_overlay
rewrite_site_overlay
verify_overlay_rewrites

printf '%s\n' "$output"
