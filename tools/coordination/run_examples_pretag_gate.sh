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

overlay_dir="${SWIFTTUI_ORG_EXAMPLES_PRETAG_DIR:-$repo_root/.build/coordination/examples-pretag}"
overlay_dir="$("$script_dir/materialize_pretag_overlay.sh" --output "$overlay_dir" examples)"

examples_dir="$overlay_dir/swift-tui-examples"

cd "$examples_dir"
bun install

SWIFTTUI_CHECKOUT="$overlay_dir/swift-tui" \
SWIFTTUI_WEB_CHECKOUT="$overlay_dir/swift-tui-web" \
SWIFTTUI_EXAMPLES_SWIFTPM_SCRATCH="$examples_dir/.build/shared-swiftpm" \
  Scripts/check_examples.sh --skip-clean --skip-bun-install
