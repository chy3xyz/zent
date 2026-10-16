#!/usr/bin/env bash
# Snapshot tag: a pinnable point on main **without** a release.
#
# Two lanes, deliberately (see docs/RELEASING.md):
#
#   scripts/tag.sh            many, cheap — tags a commit, bumps nothing
#   scripts/release.sh x.y.z  few, heavy — bumps the package version,
#                             promotes CHANGELOG, publishes a GitHub Release
#
# Zig consumers pin `#<ref>` plus a content hash, so a snapshot tag is a usable
# pin while the package version stays put. That is the point of this lane: it
# lets a consumer (or a bisect) name the exact tree it built without pretending
# the library had a release.
#
# A semver-shaped name is refused on purpose: `vX.Y.Z` means "release", and
# those are the tags scripts/check-version.sh and scripts/check-release-tag.sh
# compare the package version against.
#
# Usage: scripts/tag.sh [name] [--push]
set -euo pipefail
cd "$(dirname "$0")/.."

PUSH=0
NAME=""
for arg in "$@"; do
    case "$arg" in
        --push) PUSH=1 ;;
        -*)
            echo "usage: scripts/tag.sh [name] [--push]"
            exit 2
            ;;
        *) NAME="$arg" ;;
    esac
done

# Default name: snap-YYYY-MM-DD, suffixed when the day already has one.
if [ -z "$NAME" ]; then
    NAME="snap-$(date +%F)"
    n=2
    while git rev-parse -q --verify "refs/tags/$NAME" >/dev/null; do
        NAME="snap-$(date +%F)-$n"
        n=$((n + 1))
    done
fi

case "$NAME" in
    v[0-9]*.[0-9]*.[0-9]*)
        echo "FAIL: '$NAME' is shaped like a release tag."
        echo "      A release bumps build.zig.zon + CHANGELOG and publishes a GitHub Release:"
        echo "        scripts/release.sh $NAME --push"
        exit 1
        ;;
esac

if git rev-parse -q --verify "refs/tags/$NAME" >/dev/null; then
    echo "FAIL: tag $NAME already exists"
    exit 1
fi

if ! git diff --quiet; then
    echo "FAIL: working tree has uncommitted changes:"
    git status --short | head -10
    exit 1
fi

BR=$(git symbolic-ref --short HEAD 2>/dev/null || true)
if [ "$BR" != "main" ]; then
    echo "FAIL: snapshot tags are cut from main (on $BR)"
    exit 1
fi

# The fast gates only. A snapshot tag is not a release: it claims "this commit
# is what it looks like", not "the integration suites pass" — that is CI's job
# on every push, and release.sh's on the rare lane. If you do want the full
# gates before tagging, run them yourself (see docs/RELEASING.md).
echo "-- fast gates --"
zig fmt --check src examples tests build.zig
zig build test --summary all

# The tag carries its own context: what landed since the previous tag, so a
# consumer reading `git show <tag>` sees what it pins without a changelog entry
# having been written for it.
PREV="$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
if [ -n "$PREV" ]; then
    BODY="$(git log --oneline "$PREV..HEAD" | head -40)"
    [ -z "$BODY" ] && BODY="(no commits since $PREV)"
else
    BODY="$(git log --oneline -40)"
fi
{
    printf '%s\n\n' "$NAME"
    printf 'Snapshot tag — not a release. Package version stays at %s.\n\n' \
        "$(sed -n 's/^    \.version = "\([0-9.]*\)",$/\1/p' build.zig.zon | head -1)"
    printf 'Since %s:\n%s\n' "${PREV:-the beginning}" "$BODY"
} > /tmp/zent-tag-body.$$
git tag -a "$NAME" -F /tmp/zent-tag-body.$$
rm -f /tmp/zent-tag-body.$$

echo "tagged $NAME -> $(git rev-parse --short HEAD)"

if [ "$PUSH" = "1" ]; then
    git push origin "$NAME"
    echo "pushed $NAME"
else
    echo "not pushed (pass --push)"
fi
