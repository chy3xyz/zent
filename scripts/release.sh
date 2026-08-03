#!/usr/bin/env bash
# One-shot release: bump the package version everywhere, run quality gates,
# then commit + tag (+ push with --push).
#
# Note: .fingerprint is the package's permanent identity — it never changes.
#
# Usage: scripts/release.sh <x.y.z> [--push]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
PUSH=0
if [ "${2:-}" = "--push" ]; then PUSH=1; fi

case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *)
        echo "usage: scripts/release.sh <x.y.z> [--push]"
        exit 2
        ;;
esac

if ! git diff --quiet; then
    echo "FAIL: working tree has uncommitted changes:"
    git status --short | head -10
    exit 1
fi

BR=$(git symbolic-ref --short HEAD 2>/dev/null || true)
if [ "$BR" != "main" ]; then
    echo "FAIL: releases must be cut from main (on $BR)"
    exit 1
fi

OLD=$(sed -n 's/^    \.version = "\([0-9.]*\)",$/\1/p' build.zig.zon | head -1)
if [ -z "$OLD" ]; then
    echo "FAIL: cannot parse current version from build.zig.zon"
    exit 1
fi
if [ "$OLD" = "$VERSION" ]; then
    echo "FAIL: version already $VERSION"
    exit 1
fi
echo "release: $OLD -> $VERSION"

# 1. Bump version in every reference.
sed -i '' "s/\.version = \"$OLD\"/.version = \"$VERSION\"/" build.zig.zon
for f in README.md README_CN.md; do
    if [[ -f "$f" ]]; then sed -i '' "s/$OLD/$VERSION/g" "$f"; fi
done

# 2. CHANGELOG: promote Unreleased to the new version.
if ! grep -q "^## \[Unreleased\]" CHANGELOG.md; then
    echo "FAIL: CHANGELOG.md has no [Unreleased] section"
    exit 1
fi
sed -i '' "s/^## \[Unreleased\]$/## [$VERSION] - $(date +%F)/" CHANGELOG.md
first_section="$(grep -n '^## \[' CHANGELOG.md | head -1 | cut -d: -f1)"
tmp="$(mktemp)"
head -n "$((first_section - 1))" CHANGELOG.md > "$tmp"
{
    printf '## [Unreleased]\n\n'
    tail -n "+$first_section" CHANGELOG.md
} >> "$tmp"
mv "$tmp" CHANGELOG.md

# 3. Quality gates.
echo "-- gates --"
zig fmt --check src examples tests build.zig
zig build test --summary all

# 4. Commit + tag.
git add -A
git commit -m "chore(release): v$VERSION"
git tag -a "v$VERSION" -m "v$VERSION"

# 5. Final assertion: tag must match the package version.
bash scripts/check-release-tag.sh
echo "release v$VERSION ready"

if [ "$PUSH" = "1" ]; then
    git push origin main
    git push origin "v$VERSION"
    echo "pushed main + v$VERSION"
fi
