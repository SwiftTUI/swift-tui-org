#!/usr/bin/env bash
set -euo pipefail

script_source="${BASH_SOURCE[0]}"
if command -v realpath >/dev/null 2>&1; then
  script_path="$(realpath "$script_source")"
else
  script_path="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$script_source")"
fi

script_dir="$(cd "$(dirname "$script_path")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  repo_root="$(cd "$script_dir/../.." && pwd)"
fi

overlay_dir="${SWIFTTUI_ORG_SITE_PRETAG_DIR:-$repo_root/.build/coordination/site-pretag}"
overlay_dir="$("$script_dir/materialize_pretag_overlay.sh" --output "$overlay_dir" site)"

site_dir="$overlay_dir/swift-tui-site"

SWIFTTUI_CHECKOUT="$repo_root/swift-tui" \
SWIFTTUI_EXAMPLES_CHECKOUT="$overlay_dir/swift-tui-examples" \
SWIFTTUI_WEB_CHECKOUT="$overlay_dir/swift-tui-web" \
WEBEXAMPLE_DIR="$overlay_dir/swift-tui-examples/WebExample" \
  "$site_dir/Scripts/check_site.sh"
