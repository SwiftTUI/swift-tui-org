#!/usr/bin/env bash
set -euo pipefail

script_source="${BASH_SOURCE[0]}"
if command -v realpath >/dev/null 2>&1; then
  script_path="$(realpath "$script_source")"
else
  script_path="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$script_source")"
fi

repo_root="$(git -C "$(dirname "$script_path")" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  repo_root="$(cd "$(dirname "$script_path")/../.." && pwd)"
fi

workflow="$repo_root/.github/workflows/org-gate.yml"

fail() {
  printf '[check_org_ci_workflow] %s\n' "$1" >&2
  exit 1
}

require_file() {
  path=$1
  if [[ ! -f "$path" ]]; then
    fail "missing required file: ${path#$repo_root/}"
  fi
}

require_text() {
  needle=$1
  path=$2
  if ! grep -Fq -- "$needle" "$path"; then
    fail "expected ${path#$repo_root/} to contain: $needle"
  fi
}

require_file "$workflow"
require_text "name: Org Gate" "$workflow"
require_text "name: Org repo gate" "$workflow"
require_text "runs-on: ubuntu-24.04" "$workflow"
require_text "full_gate" "$workflow"
require_text "submodules: recursive" "$workflow"
require_text 'secrets.SWIFTTUI_CI_TOKEN || github.token' "$workflow"
require_text "Run organization contract" "$workflow"
require_text "bazel test //:org_fast" "$workflow"
require_text "name: Full organization gate" "$workflow"
require_text "github.event_name == 'workflow_dispatch' && inputs.full_gate" "$workflow"
require_text 'npm install --prefix "$RUNNER_TEMP/bazelisk" @bazel/bazelisk@1.28.1' "$workflow"
require_text "swift-tui/.swift-version" "$workflow"
require_text "binaryen" "$workflow"
require_text "brotli" "$workflow"
require_text "ripgrep" "$workflow"
require_text "bazel fetch //:org_full" "$workflow"
require_text "bazel test //:org_full" "$workflow"

printf '[check_org_ci_workflow] ok\n'
