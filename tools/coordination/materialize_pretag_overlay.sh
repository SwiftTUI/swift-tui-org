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
  web_dir="$output/swift-tui-web"

  [[ -d "$examples_dir" ]] || return 0

  while IFS= read -r -d '' manifest; do
    manifest_dir="$(cd "$(dirname "$manifest")" && pwd)"
    swift_tui_rel="$(relative_path "$swift_tui_dir" "$manifest_dir")"
    perl -0pi -e \
      's#\.package\(\s*url:\s*"https://github\.com/SwiftTUI/swift-tui(?:\.git)?",\s*exact:\s*"[^"]+"\s*\)#.package(name: "swift-tui", path: "'"$swift_tui_rel"'")#sg;
       s#\.package\(name:\s*"swift-tui",\s*path:\s*"[^"]*swift-tui"\s*\)#.package(name: "swift-tui", path: "'"$swift_tui_rel"'")#g' \
      "$manifest"
  done < <(find "$examples_dir" -name Package.swift -print0)

  pbxproj="$examples_dir/SwiftUIExample/SwiftUIExample.xcodeproj/project.pbxproj"
  if [[ -f "$pbxproj" ]]; then
    perl -0pi -e 's#relativePath = [^;]*swift-tui;#relativePath = ../../swift-tui;#g' "$pbxproj"
  fi

  webexample_package="$examples_dir/WebExample/package.json"
  if [[ -f "$webexample_package" && -d "$web_dir" ]]; then
    perl -0pi -e \
      's#("\@swifttui/build":\s*")[^"]+(")#$1file:../../swift-tui-web/packages/build$2#;
       s#("\@swifttui/web":\s*")[^"]+(")#$1file:../../swift-tui-web/packages/web$2#' \
      "$webexample_package"
  fi

  examples_package="$examples_dir/package.json"
  if [[ -f "$examples_package" && -d "$web_dir" ]]; then
    perl -0pi -e \
      's#"workspaces"\s*:\s*\[[^\]]*\]#"workspaces": [
    "WebExample",
    "../swift-tui-web/packages/web",
    "../swift-tui-web/packages/build"
  ]#s;
       s#("\@swifttui/web":\s*")[^"]+(")#$1workspace:*$2#g' \
      "$examples_package"
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

rm -rf "$output"
mkdir -p "$output"

case "$scope" in
  examples)
    copy_repo swift-tui
    copy_repo swift-tui-web
    copy_repo swift-tui-examples
    ;;
  site|all)
    copy_repo swift-tui
    copy_repo swift-tui-web
    copy_repo swift-tui-examples
    copy_repo swift-tui-site
    ;;
esac

rewrite_examples_overlay
rewrite_site_overlay

printf '%s\n' "$output"
