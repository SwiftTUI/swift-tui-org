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
  printf '[release_artifact_contract] %s\n' "$1" >&2
  exit 1
}

note() {
  printf '[release_artifact_contract] %s\n' "$1"
}

releases_manifest="swift-tui-site/docs/releases.yml"
[[ -f "$releases_manifest" ]] \
  || fail "missing $releases_manifest (run with submodules checked out)"

read_current() {
  awk -v key="$1" '
    /^current:/ { in_current = 1; next }
    in_current && /^[^[:space:]#]/ { in_current = 0 }
    in_current && $1 == key ":" { print $2; exit }
  ' "$releases_manifest"
}

version="${SWIFTTUI_RELEASE_ARTIFACT_VERSION:-$(read_current swiftTUI)}"
web_version="$(read_current web)"
examples_version="$(read_current examplesRef)"

[[ -n "$version" ]] || fail "could not read current.swiftTUI from $releases_manifest"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$ ]] \
  || fail "release version '$version' is not semver-like"

if [[ -z "${SWIFTTUI_RELEASE_ARTIFACT_VERSION:-}" ]]; then
  [[ "$version" == "$web_version" && "$version" == "$examples_version" ]] \
    || fail "lockstep versions diverge in $releases_manifest: swiftTUI=$version web=$web_version examplesRef=$examples_version"
fi

web_release_base="${SWIFTTUI_RELEASE_WEB_BASE_URL:-https://github.com/SwiftTUI/swift-tui-web/releases/download}"
android_maven_base="${SWIFTTUI_RELEASE_ANDROID_MAVEN_BASE_URL:-https://swifttui.github.io/swift-tui-android}"

tmpdir="${TEST_TMPDIR:-$(mktemp -d -t swifttui-release-artifacts.XXXXXX)}"
cleanup_tmp=0
if [[ -z "${TEST_TMPDIR:-}" ]]; then
  cleanup_tmp=1
fi
if [[ "$cleanup_tmp" -eq 1 ]]; then
  trap 'rm -rf "$tmpdir"' EXIT
fi
mkdir -p "$tmpdir"

url_join() {
  local base=${1%/}
  local suffix=${2#/}
  printf '%s/%s' "$base" "$suffix"
}

fetch_url() {
  local url=$1
  local output=$2
  if ! curl -fsSL --retry 2 --retry-delay 1 -o "$output" "$url"; then
    fail "could not fetch $url"
  fi
}

require_tag() {
  local repo=$1
  [[ -d "$repo/.git" || -f "$repo/.git" ]] || fail "missing submodule checkout: $repo"
  if ! git -C "$repo" rev-parse --verify --quiet "refs/tags/$version^{commit}" >/dev/null; then
    fail "$repo is missing release tag $version (fetch tags or publish the child release first)"
  fi
  note "$repo tag $version exists"
}

if [[ "${SWIFTTUI_RELEASE_ARTIFACT_SKIP_TAGS:-0}" != "1" ]]; then
  for repo in swift-tui-web swift-tui swift-tui-swiftui swift-tui-android swift-tui-examples swift-tui-site; do
    require_tag "$repo"
  done
else
  note "tag checks skipped by SWIFTTUI_RELEASE_ARTIFACT_SKIP_TAGS=1"
fi

check_package_tarball() {
  local tarball=$1
  local expected_name=$2
  local expected_version=$3
  local expected_web_dependency=${4:-}

  python3 - "$tarball" "$expected_name" "$expected_version" "$expected_web_dependency" <<'PY'
import json
import subprocess
import sys

tarball, expected_name, expected_version, expected_web_dependency = sys.argv[1:]
try:
    raw = subprocess.check_output(["tar", "-xOzf", tarball, "package/package.json"])
except subprocess.CalledProcessError as exc:
    raise SystemExit(f"could not read package/package.json from {tarball}: {exc}") from exc

package = json.loads(raw)
actual_name = package.get("name")
actual_version = package.get("version")
if actual_name != expected_name:
    raise SystemExit(f"{tarball}: package name {actual_name!r} != {expected_name!r}")
if actual_version != expected_version:
    raise SystemExit(f"{tarball}: version {actual_version!r} != {expected_version!r}")

if expected_web_dependency:
    dependencies = package.get("dependencies") or {}
    actual_dependency = dependencies.get("@swifttui/web")
    if actual_dependency != expected_web_dependency:
        raise SystemExit(
            f"{tarball}: @swifttui/web dependency {actual_dependency!r} != {expected_web_dependency!r}"
        )
PY
}

web_tarball="swifttui-web-$version.tgz"
build_tarball="swifttui-build-$version.tgz"
web_url="$(url_join "$web_release_base" "$version/$web_tarball")"
build_url="$(url_join "$web_release_base" "$version/$build_tarball")"
web_tarball_path="$tmpdir/$web_tarball"
build_tarball_path="$tmpdir/$build_tarball"

fetch_url "$web_url" "$web_tarball_path"
fetch_url "$build_url" "$build_tarball_path"
check_package_tarball "$web_tarball_path" "@swifttui/web" "$version"
check_package_tarball "$build_tarball_path" "@swifttui/build" "$version" "$version"
note "swift-tui-web GitHub release tarballs are reachable and version-consistent"

check_npm_version() {
  local package=$1
  local output actual
  if ! output="$(npm view "$package@$version" version --json 2>&1)"; then
    fail "npm view $package@$version failed: $output"
  fi

  actual="$(python3 -c 'import json, sys
text = sys.stdin.read().strip()
try:
    value = json.loads(text)
except json.JSONDecodeError:
    value = text.strip("\"")
if isinstance(value, list):
    value = value[-1] if value else ""
print(value)
' <<<"$output")"

  [[ "$actual" == "$version" ]] \
    || fail "npm package $package@$version resolved version '$actual'"
  note "npm package $package@$version is published"
}

check_npm_version "@swifttui/web"
check_npm_version "@swifttui/build"

check_maven_file() {
  local path=$1
  local output=$2
  local url
  url="$(url_join "$android_maven_base" "$path")"
  fetch_url "$url" "$output"
}

check_metadata_contains_version() {
  local path=$1
  local output="$tmpdir/$(basename "$path").metadata.xml"
  check_maven_file "$path" "$output"
  grep -Fq "<version>$version</version>" "$output" \
    || fail "$path does not list version $version"
}

check_maven_file \
  "sh/swifttui/android-host/$version/android-host-$version.aar" \
  "$tmpdir/android-host-$version.aar"
check_metadata_contains_version "sh/swifttui/android-host/maven-metadata.xml"

plugin_marker_path="sh/swifttui/android/sh.swifttui.android.gradle.plugin/$version/sh.swifttui.android.gradle.plugin-$version.pom"
plugin_marker_pom="$tmpdir/sh.swifttui.android.gradle.plugin-$version.pom"
check_maven_file "$plugin_marker_path" "$plugin_marker_pom"
grep -Fq "<version>$version</version>" "$plugin_marker_pom" \
  || fail "$plugin_marker_path does not point at version $version"
check_metadata_contains_version "sh/swifttui/android/sh.swifttui.android.gradle.plugin/maven-metadata.xml"
check_maven_file \
  "sh/swifttui/android-plugin/$version/android-plugin-$version.jar" \
  "$tmpdir/android-plugin-$version.jar"
check_metadata_contains_version "sh/swifttui/android-plugin/maven-metadata.xml"
note "swift-tui-android Maven artifacts are reachable and version-consistent"

if [[ "${SWIFTTUI_RELEASE_ARTIFACT_SKIP_DOWNSTREAM_INSTALL:-0}" != "1" ]]; then
  command -v bun >/dev/null 2>&1 || fail "bun is required for downstream tarball resolution"
  downstream_dir="$tmpdir/downstream-bun"
  mkdir -p "$downstream_dir"
  cat >"$downstream_dir/package.json" <<EOF
{
  "name": "swifttui-release-artifact-contract",
  "private": true,
  "dependencies": {
    "@swifttui/web": "$web_url",
    "@swifttui/build": "$build_url"
  }
}
EOF
  if ! (cd "$downstream_dir" && bun install --dry-run --no-save >/dev/null); then
    fail "bun could not resolve the published web tarball URLs from a clean downstream package"
  fi
  note "downstream Bun dry-run resolves the published web tarball URLs"
else
  note "downstream Bun dry-run skipped by SWIFTTUI_RELEASE_ARTIFACT_SKIP_DOWNSTREAM_INSTALL=1"
fi

note "ok"
