#!/usr/bin/env bash
# version_coherence.sh — assert the lockstep release version is coherent across
# the org.
#
# The coordination root exists to prevent the version-skew class (the 0.0.8
# breakage), yet nothing in the gate graph asserted that the lockstep repos
# actually agree on a version — `release_pin_contract` only checks that each
# pin is reachable from a published line, so version-skewed-but-reachable HEADs
# passed every gate and the only real defense was a maintainer walking the
# release runbook by hand. This converts that manual check into an automated
# attestation: the canonical `releases.yml` lockstep entries must agree, and the
# denormalized web `package.json` versions must match them.
#
# Wired into `//:release_candidate` (NOT `//:org_fast`), because pre-release
# drift between the canonical manifest and a not-yet-bumped child is expected
# during normal development and only matters when cutting a release.
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
  printf '[version_coherence] %s\n' "$1" >&2
  exit 1
}

releases_manifest="swift-tui-site/docs/releases.yml"
[[ -f "$releases_manifest" ]] \
  || fail "missing $releases_manifest (run with submodules checked out)"

# Read a key from the top-level `current:` block of releases.yml.
read_current() {
  awk -v key="$1" '
    /^current:/ { in_current = 1; next }
    in_current && /^[^[:space:]#]/ { in_current = 0 }
    in_current && $1 == key ":" { print $2; exit }
  ' "$releases_manifest"
}

# Read the "version" field from a package.json.
pkg_version() {
  grep -m1 '"version"' "$1" \
    | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

canonical_swifttui="$(read_current swiftTUI)"
canonical_web="$(read_current web)"
canonical_examples="$(read_current examplesRef)"

[[ -n "$canonical_swifttui" ]] || fail "could not read current.swiftTUI from $releases_manifest"
[[ -n "$canonical_web" ]] || fail "could not read current.web from $releases_manifest"
[[ -n "$canonical_examples" ]] || fail "could not read current.examplesRef from $releases_manifest"

# 1. The lockstep set must agree in the canonical manifest itself.
if [[ "$canonical_swifttui" != "$canonical_web" || "$canonical_swifttui" != "$canonical_examples" ]]; then
  fail "lockstep versions diverge in $releases_manifest: swiftTUI=$canonical_swifttui web=$canonical_web examplesRef=$canonical_examples"
fi
printf '[version_coherence] canonical lockstep version: %s\n' "$canonical_swifttui"

# 2. Every web workspace package.json must match the canonical web version.
shopt -s nullglob
web_packages=(swift-tui-web/package.json swift-tui-web/packages/*/package.json)
[[ "${#web_packages[@]}" -gt 0 ]] || fail "found no web workspace package.json files"

failures=0
for manifest in "${web_packages[@]}"; do
  version="$(pkg_version "$manifest")"
  if [[ -z "$version" ]]; then
    printf '[version_coherence] %s has no "version" field — skipping\n' "$manifest"
    continue
  fi
  if [[ "$version" != "$canonical_web" ]]; then
    printf '[version_coherence] MISMATCH %s: %s (expected %s)\n' "$manifest" "$version" "$canonical_web" >&2
    failures=1
  else
    printf '[version_coherence] ok %s = %s\n' "$manifest" "$version"
  fi
done

[[ "$failures" -eq 0 ]] \
  || fail "one or more web package versions diverge from canonical $canonical_web"

printf '[version_coherence] all lockstep versions coherent at %s\n' "$canonical_swifttui"
