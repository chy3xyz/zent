#!/usr/bin/env bash
# Assert the latest annotated release tag matches the package version in
# build.zig.zon — the release-shape invariant.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/^    \.version = "\([0-9.]*\)",$/\1/p' build.zig.zon | head -1)"
LATEST_TAG="$(git tag | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)"

if [[ "$LATEST_TAG" != "v$VERSION" ]]; then
  echo "FAIL: latest tag $LATEST_TAG != package version $VERSION" >&2
  exit 1
fi
echo "check-release-tag: OK (v$VERSION matches package version)"
