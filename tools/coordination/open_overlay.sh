#!/usr/bin/env bash
set -euo pipefail

script_source="${BASH_SOURCE[0]}"
if command -v realpath >/dev/null 2>&1; then
  script_path="$(realpath "$script_source")"
else
  script_path="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$script_source")"
fi
script_dir="$(cd "$(dirname "$script_path")" && pwd)"

# Resolution order: $BUILD_WORKSPACE_DIRECTORY (set by `bazel run`), then
# `git rev-parse` from the script's directory, then a structural fallback for
# Bazel test runfiles trees.
if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
  repo_root="$BUILD_WORKSPACE_DIRECTORY"
else
  repo_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$repo_root" ]]; then
    repo_root="$(cd "$script_dir/../.." && pwd)"
  fi
fi

scope=all
output=""
print_env=0
source_mode="${SWIFTTUI_ORG_OVERLAY_SOURCE_MODE:-worktree}"

usage() {
  cat <<'EOF'
Usage: tools/coordination/open_overlay.sh [options] [all|examples|site]

Materialize the coordination overlay for local cross-repo iteration WITHOUT
running the full //:examples_pretag_native_gate or //:site_pretag_native_gate
target. Prints the overlay path on stdout.

Options:
  --output DIR         Place the overlay at DIR (default:
                       .build/coordination/dev-overlay).
  --source-mode MODE   worktree (default) — copies the live working tree of
                                  each submodule, including uncommitted and
                                  untracked edits. Re-run this script after
                                  edits to refresh the overlay.
                       head       — copies HEAD via `git archive`. Matches
                                  what CI gates use. Useful to reproduce a
                                  pretag failure locally.
  --print-env          Emit shell `export` lines on stdout so child gate
                       scripts (Scripts/check_examples.sh,
                       Scripts/build_docc_site.sh, ...) pick up the overlay:
                           eval "$(tools/coordination/open_overlay.sh --print-env)"
                       The overlay path is logged to stderr in this mode.
  -h, --help           Show this help.

Scopes:
  all (default)   Copy swift-tui, swift-tui-web, swift-tui-examples, and
                  swift-tui-site.
  examples        Copy swift-tui, swift-tui-web, and swift-tui-examples.
  site            Same set as `all` (the site gate also needs examples + web).

The overlay is a throwaway copy under .build/coordination/. Edits made inside
the overlay are NOT carried back to the public child repos.
EOF
}

fail() {
  printf '[open_overlay] %s\n' "$1" >&2
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
    --print-env)
      print_env=1
      shift
      ;;
    -h|--help)
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

if [[ -z "$output" ]]; then
  output="$repo_root/.build/coordination/dev-overlay"
fi

overlay_dir="$("$script_dir/materialize_pretag_overlay.sh" --source-mode "$source_mode" --output "$output" "$scope")"

if [[ "$print_env" -eq 1 ]]; then
  printf '[open_overlay] overlay materialized at %s\n' "$overlay_dir" >&2
  printf 'export SWIFTTUI_CHECKOUT=%q\n' "$overlay_dir/swift-tui"
  printf 'export SWIFTTUI_WEB_CHECKOUT=%q\n' "$overlay_dir/swift-tui-web"
  printf 'export SWIFTTUI_EXAMPLES_CHECKOUT=%q\n' "$overlay_dir/swift-tui-examples"
  if [[ "$scope" != "examples" ]]; then
    printf 'export WEBEXAMPLE_DIR=%q\n' "$overlay_dir/swift-tui-examples/WebExample"
  fi
else
  printf '%s\n' "$overlay_dir"
fi
