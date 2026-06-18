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

cd "$repo_root"

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

# 1) The registry is single-sourced in tools/registry/repos.json. The duplicated
#    copies that used to drift by hand -- the root MODULE.bazel deps, the root
#    BUILD.bazel native_gate suites, the README table, and the bash arrays the
#    other contract scripts read -- are GENERATED from it. Assert they are current.
#    This converts the old "config matches config" tautology into a real staleness
#    gate: if anyone hand-edits a generated region (or forgets to regenerate after
#    editing repos.json), this fails with the exact diff.
if ! python3 tools/registry/generate.py --check; then
  fail "generated registry regions are stale -- run: python3 tools/registry/generate.py --write"
fi

# 2) Load the manifest-derived lists and assert each declared repo actually
#    satisfies the on-disk contract that the generator cannot see (the CHILD
#    repos' own files, and the root's hand-written aggregate targets).
# shellcheck source=tools/registry/repos.generated.sh
source "$repo_root/tools/registry/repos.generated.sh"

root_module="$repo_root/MODULE.bazel"
root_build="$repo_root/BUILD.bazel"
readme="$repo_root/README.md"
gitmodules="$repo_root/.gitmodules"

require_file "$root_module"
require_file "$root_build"
require_file "$readme"
require_file "$gitmodules"

# Hand-written aggregate targets (not generated) must keep existing.
require_text 'name = "org_fast"' "$root_build"
require_text 'name = "org_full"' "$root_build"
require_text 'name = "release_candidate"' "$root_build"
require_text 'name = "org"' "$root_build"
require_text '//:org_fast' "$readme"
require_text '//:org_full' "$readme"
require_text '//:release_candidate' "$readme"

# Every Bazel-module repo must be a declared submodule and expose its native gate
# in its own (child-owned) BUILD.bazel / MODULE.bazel.
for i in "${!BAZEL_MODULE_REPOS[@]}"; do
  repo=${BAZEL_MODULE_REPOS[$i]}
  module=${BAZEL_MODULE_NAMES[$i]}
  url=${BAZEL_MODULE_URLS[$i]}

  require_text "[submodule \"$repo\"]" "$gitmodules"
  require_text "path = $repo" "$gitmodules"
  require_text "url = $url" "$gitmodules"

  require_file "$repo_root/$repo/MODULE.bazel"
  require_file "$repo_root/$repo/BUILD.bazel"
  require_text "name = \"$module\"" "$repo_root/$repo/MODULE.bazel"
  require_text 'name = "native_gate"' "$repo_root/$repo/BUILD.bazel"
done

# Every declared submodule -- including non-Bazel, pinning-only repos such as the
# org-profile `github` -- must be registered in .gitmodules.
for i in "${!ALL_SUBMODULE_REPOS[@]}"; do
  repo=${ALL_SUBMODULE_REPOS[$i]}
  url=${ALL_SUBMODULE_URLS[$i]}

  require_text "[submodule \"$repo\"]" "$gitmodules"
  require_text "url = $url" "$gitmodules"
done

printf '[repo_registry_contract] ok\n'
