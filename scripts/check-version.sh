#!/usr/bin/env bash
# Release-consistency gate:
#   1. build.zig.zon version must be referenced by README.md / README_CN.md
#   2. package version must never be older than the latest git tag
#      (guards the tag/version drift that hit v0.12.1 vs v0.17.0 tags)
# Run in CI so a manual bump can never leave the repo inconsistent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n 's/^    \.version = "\([0-9.]*\)",$/\1/p' build.zig.zon | head -1)"
if [[ -z "$VERSION" ]]; then
  echo "check-version: cannot read version from build.zig.zon" >&2
  exit 1
fi

fail=0
for f in README.md README_CN.md; do
  if ! grep -q "$VERSION" "$f"; then
    echo "check-version: $f does not reference version $VERSION" >&2
    fail=1
  fi
done

# Drift guard: latest tag (e.g. v0.18.0) must not be newer than the package.
LATEST_TAG="$(git tag | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)"
if [[ -n "$LATEST_TAG" ]]; then
  TAG_VER="${LATEST_TAG#v}"
  older() { # $1 < $2 as semver
    IFS=. read -r a b c <<<"$1"
    IFS=. read -r x y z <<<"$2"
    (( a < x )) || { (( a == x && b < y )) || { (( a == x && b == y && c < z )); }; }
  }
  if older "$VERSION" "$TAG_VER"; then
    echo "check-version: package version $VERSION is older than latest tag $LATEST_TAG" >&2
    echo "check-version: run scripts/bump-version.sh <x.y.z> then tag accordingly" >&2
    fail=1
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  echo "check-version: run scripts/bump-version.sh to sync all files" >&2
  exit 1
fi
echo "check-version: OK ($VERSION consistent, >= latest tag ${LATEST_TAG:-none})"
