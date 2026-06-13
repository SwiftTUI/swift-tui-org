#!/usr/bin/env bash
set -euo pipefail

script_source="${BASH_SOURCE[0]}"
if command -v realpath >/dev/null 2>&1; then
  script_path="$(realpath "$script_source")"
else
  script_path="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$script_source")"
fi

script_dir="$(cd "$(dirname "$script_path")" && pwd)"
if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
  repo_root="$BUILD_WORKSPACE_DIRECTORY"
else
  repo_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$repo_root" ]]; then
    repo_root="$(cd "$script_dir/../.." && pwd)"
  fi
fi

source_mode="${SWIFTTUI_ORG_OVERLAY_SOURCE_MODE:-head}"
case "$source_mode" in
  head)     default_overlay="$repo_root/.build/coordination/site-pretag" ;;
  worktree) default_overlay="$repo_root/.build/coordination/site-worktree" ;;
  *) printf '[run_site_pretag_gate] unknown SWIFTTUI_ORG_OVERLAY_SOURCE_MODE: %s\n' "$source_mode" >&2; exit 1 ;;
esac

overlay_dir="${SWIFTTUI_ORG_SITE_PRETAG_DIR:-$default_overlay}"
overlay_dir="$("$script_dir/materialize_pretag_overlay.sh" --source-mode "$source_mode" --output "$overlay_dir" site)"

site_dir="$overlay_dir/swift-tui-site"
web_dir="$overlay_dir/swift-tui-web"

cd "$web_dir"
bun install
bun run build:packages

SWIFTTUI_CHECKOUT="$repo_root/swift-tui" \
SWIFTTUI_EXAMPLES_CHECKOUT="$overlay_dir/swift-tui-examples" \
SWIFTTUI_WEB_CHECKOUT="$overlay_dir/swift-tui-web" \
WEBEXAMPLE_DIR="$overlay_dir/swift-tui-examples/WebExample" \
  "$site_dir/Scripts/check_site.sh"
