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

# 3. Every SwiftTUI-org sibling consumer pin must match the canonical framework
#    version. The org ships its public packages in lockstep, so a consumer that
#    still pins an older framework is a partial-bump skew — exactly the version
#    class this gate exists to catch. Without this, a bump that updates
#    releases.yml + the web package.json but misses a child SwiftPM/Xcode pin
#    passes every gate: the pretag overlay rewrites `exact:"X"` to a local path
#    regardless of `X`, and release_artifact_contract only checks the tag exists.
#    Third-party pins (swift-syntax, Splash, …) are ignored by matching the
#    SwiftTUI org URL. swift-tui-swiftui is checked against the same canonical
#    version because it ships in lockstep with swift-tui.
pin_failures=0
checked_pins=0

check_consumer_pin() {
  # $1 file, $2 version, $3 kind
  checked_pins=$((checked_pins + 1))
  if [[ "$2" != "$canonical_swifttui" ]]; then
    printf '[version_coherence] MISMATCH %s: %s pins SwiftTUI %s (expected %s)\n' \
      "$1" "$3" "$2" "$canonical_swifttui" >&2
    pin_failures=1
  fi
}

# SwiftPM: `.package(url: ".../SwiftTUI/swift-tui*.git", exact: "X")`, handling
# both single-line and multi-line `.package(...)` declarations. A `url:` line
# that is not a SwiftTUI org URL resets the match so a following third-party
# `exact:` is never attributed to SwiftTUI.
mapfile -t package_manifests < <(
  find swift-tui-examples swift-tui-swiftui swift-tui-web \
    -name Package.swift -not -path '*/.build/*' 2>/dev/null | sort
)
if [[ "${#package_manifests[@]}" -gt 0 ]]; then
  while IFS=$'\t' read -r file version; do
    [[ -n "$file" ]] || continue
    check_consumer_pin "$file" "$version" SwiftPM
  done < <(
    awk '
      FNR == 1 { swifttui = 0 }
      /url:/ { swifttui = ($0 ~ /SwiftTUI\/swift-tui/) ? 1 : 0 }
      swifttui && /exact:[[:space:]]*"[^"]+"/ {
        v = $0
        sub(/.*exact:[[:space:]]*"/, "", v)
        sub(/".*/, "", v)
        print FILENAME "\t" v
        swifttui = 0
      }
    ' "${package_manifests[@]}"
  )
fi

# Xcode: an `XCRemoteSwiftPackageReference` for a SwiftTUI org URL pinned with
# `kind = exactVersion; version = X;`.
mapfile -t pbxproj_files < <(
  find swift-tui-examples swift-tui-swiftui \
    -name project.pbxproj -not -path '*/.build/*' 2>/dev/null | sort
)
if [[ "${#pbxproj_files[@]}" -gt 0 ]]; then
  while IFS=$'\t' read -r file version; do
    [[ -n "$file" ]] || continue
    check_consumer_pin "$file" "$version" Xcode
  done < <(
    awk '
      /repositoryURL/ { swifttui = ($0 ~ /SwiftTUI\/swift-tui/) ? 1 : 0; next }
      swifttui && /^[[:space:]]*version[[:space:]]*=/ {
        v = $0
        sub(/.*version[[:space:]]*=[[:space:]]*/, "", v)
        sub(/;.*/, "", v)
        gsub(/[" ]/, "", v)
        print FILENAME "\t" v
        swifttui = 0
      }
    ' "${pbxproj_files[@]}"
  )
fi

[[ "$pin_failures" -eq 0 ]] \
  || fail "one or more consumer pins diverge from canonical SwiftTUI $canonical_swifttui"

printf '[version_coherence] %s SwiftTUI consumer pins coherent at %s\n' \
  "$checked_pins" "$canonical_swifttui"
printf '[version_coherence] all lockstep versions coherent at %s\n' "$canonical_swifttui"
