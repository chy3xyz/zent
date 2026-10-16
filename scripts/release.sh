#!/usr/bin/env bash
# Release: bump the package version everywhere, promote CHANGELOG, run the
# quality gates, then commit + annotated tag (+ push and publish a GitHub
# Release with --push).
#
# This is the **rare** lane. Releases are meant to be batched — roughly one a
# week — because a release is what a consumer reads: a version, a changelog
# section, a published artifact. For "I need to pin this exact commit now" use
# the cheap lane instead, which bumps nothing:
#
#     scripts/tag.sh [--push]        # snapshot tag, many of them
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

# Cadence: releases are the rare lane. Say how long it has been, and where the
# cheap lane is, without blocking a release that needs to happen now.
LAST_RELEASE="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1 || true)"
if [ -n "$LAST_RELEASE" ]; then
    LAST_EPOCH="$(git log -1 --format=%ct "$LAST_RELEASE" 2>/dev/null || echo 0)"
    NOW_EPOCH="$(date +%s)"
    DAYS=$(( (NOW_EPOCH - LAST_EPOCH) / 86400 ))
    echo "last release: $LAST_RELEASE (${DAYS} day(s) ago)"
    if [ "$DAYS" -lt 7 ]; then
        echo "note: the release cadence is roughly one a week — a snapshot tag"
        echo "      (scripts/tag.sh) is the cheap way to pin a commit in between"
    fi
else
    echo "last release: none"
fi

# 1. Bump version in every reference.
sed -i '' "s/\.version = \"$OLD\"/.version = \"$VERSION\"/" build.zig.zon
# Also the comptime mirror consumers read (`zent.version`), so
# scripts/check-version.sh finds them equal.
sed -i '' "s/^pub const version = \"$OLD\";$/pub const version = \"$VERSION\";/" src/version.zig
for f in README.md README_CN.md; do
    if [[ -f "$f" ]]; then sed -i '' "s/$OLD/$VERSION/g" "$f"; fi
done
# AGENTS.md carries the version too, and scripts/check-version.sh checks it —
# it drifted for four releases (v0.74.0 → v0.75.0) while nothing looked at it.
sed -i '' "s/^- Version: \*\*v$OLD\*\*/- Version: **v$VERSION**/" AGENTS.md

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

    # 6. Publish the GitHub Release — what makes "release" different from "tag"
    #    for anyone reading the repository rather than the dependency graph.
    #    The notes are the CHANGELOG section this release just promoted, so the
    #    two can never disagree. A missing or unauthenticated `gh` is a warning,
    #    not a failure: the tag is already pushed and the release can be created
    #    from the web UI.
    # `index(...) == 1` rather than a regex: `awk -v` rewrites escapes in the
    # value, so `\[` would arrive as `[` and turn the heading into a character
    # class (which silently matches nothing).
    notes="$(mktemp)"
    awk -v head="## [$VERSION]" '
        !copying && index($0, head) == 1 { copying = 1; next }
        copying && /^## \[/ { exit }
        copying { print }
    ' CHANGELOG.md > "$notes"
    if [ -s "$notes" ] && command -v gh >/dev/null 2>&1; then
        if gh release create "v$VERSION" --title "v$VERSION" --notes-file "$notes" >/dev/null 2>&1; then
            echo "published GitHub Release v$VERSION"
        else
            echo "note: could not publish a GitHub Release (gh failed or is not authenticated);"
            echo "      the tag is pushed — create it from the web UI with the CHANGELOG section"
        fi
    else
        echo "note: skipping the GitHub Release (no gh, or an empty CHANGELOG section)"
    fi
    rm -f "$notes"
fi
