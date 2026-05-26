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

failures=0

note_failure() {
  title=$1
  matches=$2

  printf '[public_dependency_contracts] forbidden %s:\n' "$title" >&2
  printf '%s\n' "$matches" >&2
  failures=1
}

search_regex() {
  pattern=$1
  shift

  if command -v rg >/dev/null 2>&1; then
    rg -n --no-heading \
      -g '!**/.build/**' \
      -g '!**/.git/**' \
      -g '!**/node_modules/**' \
      "$pattern" "$@" || true
  else
    grep -RInE "$pattern" "$@" 2>/dev/null || true
  fi
}

forbid_regex() {
  title=$1
  pattern=$2
  shift 2

  matches="$(search_regex "$pattern" "$@")"
  if [[ -n "$matches" ]]; then
    note_failure "$title" "$matches"
  fi
}

forbid_regex \
  "SwiftPM sibling swift-tui dependencies in public examples manifests" \
  'path: *"\.\./\.\./swift-tui|path: *"\.\./\.\./\.\./swift-tui' \
  swift-tui-examples

forbid_regex \
  "Xcode sibling swift-tui package references in public examples projects" \
  'relativePath = \.\./\.\./swift-tui' \
  swift-tui-examples

forbid_regex \
  "workspace dependencies for released SwiftTUI web packages" \
  '"@swifttui/(web|build)": *"workspace:\*"' \
  swift-tui-examples

forbid_regex \
  "sibling swift-tui-web workspace paths in public examples package metadata" \
  '\.\./swift-tui-web/' \
  swift-tui-examples/package.json swift-tui-examples/bun.lock

forbid_regex \
  "untagged main references in public site release metadata" \
  'examplesRef: main|ref: main' \
  swift-tui-site/docs swift-tui-site/Website

forbid_regex \
  "examples CI sibling swift-tui checkouts" \
  'repository: SwiftTUI/swift-tui(-web)?' \
  swift-tui-examples/.github/workflows

forbid_regex \
  "site CI sibling WebExample or web-package checkouts" \
  'repository: SwiftTUI/swift-tui-(examples|web)' \
  swift-tui-site/.github/workflows

if [[ "$failures" -ne 0 ]]; then
  printf '[public_dependency_contracts] public child repos still require coordination-only dependency paths\n' >&2
  exit 1
fi

printf '[public_dependency_contracts] ok\n'
