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

fail() {
  printf '[repo_registry_contract] %s\n' "$1" >&2
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

require_regex() {
  pattern=$1
  path=$2
  if ! grep -Eq -- "$pattern" "$path"; then
    fail "expected ${path#$repo_root/} to match: $pattern"
  fi
}

repos=(
  "swift-tui"
  "swift-tui-web"
  "swift-tui-examples"
  "swift-tui-site"
)

modules=(
  "swift_tui"
  "swift_tui_web"
  "swift_tui_examples"
  "swift_tui_site"
)

urls=(
  "git@github.com:SwiftTUI/swift-tui.git"
  "git@github.com:SwiftTUI/swift-tui-web.git"
  "git@github.com:SwiftTUI/swift-tui-examples.git"
  "git@github.com:SwiftTUI/swift-tui-site.git"
)

root_module="$repo_root/MODULE.bazel"
root_build="$repo_root/BUILD.bazel"
readme="$repo_root/README.md"
gitmodules="$repo_root/.gitmodules"

require_file "$root_module"
require_file "$root_build"
require_file "$readme"
require_file "$gitmodules"

require_text 'name = "org_fast"' "$root_build"
require_text 'name = "org_full"' "$root_build"
require_text 'name = "release_candidate"' "$root_build"
require_text 'name = "org"' "$root_build"
require_text '//:org_fast' "$readme"
require_text '//:org_full' "$readme"
require_text '//:release_candidate' "$readme"

for i in "${!repos[@]}"; do
  repo=${repos[$i]}
  module=${modules[$i]}
  url=${urls[$i]}

  require_text "[submodule \"$repo\"]" "$gitmodules"
  require_text "path = $repo" "$gitmodules"
  require_text "url = $url" "$gitmodules"

  require_text "bazel_dep(name = \"$module\"" "$root_module"
  require_text "module_name = \"$module\"" "$root_module"
  require_text "path = \"$repo\"" "$root_module"

  require_text "name = \"${module}_native_gate\"" "$root_build"
  require_text "@${module}//:native_gate" "$root_build"

  require_regex "\\| \`$repo/\` \\|.*\\| \`$module\` \\|" "$readme"

  require_file "$repo_root/$repo/MODULE.bazel"
  require_file "$repo_root/$repo/BUILD.bazel"
  require_text "name = \"$module\"" "$repo_root/$repo/MODULE.bazel"
  require_text 'name = "native_gate"' "$repo_root/$repo/BUILD.bazel"
done

printf '[repo_registry_contract] ok\n'
