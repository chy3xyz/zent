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
FORCE=0
NAME=""
for arg in "$@"; do
    case "$arg" in
        --push) PUSH=1 ;;
        --force) FORCE=1 ;;
        -*)
            echo "usage: scripts/tag.sh [name] [--push] [--force]"
            exit 2
            ;;
        *) NAME="$arg" ;;
    esac
done

# Default name: snap-YYYY-MM-DD, suffixed when the day already has one. A
# commit that already carries today's snapshot tag is left alone — re-tagging it
# under a new suffix would add a second name for the same tree (the automated
# daily job applies the same rule).
if [ -z "$NAME" ]; then
    DATE="$(date +%F)"
    for t in $(git tag -l "snap-$DATE*"); do
        if [ "$(git rev-parse "refs/tags/$t^{commit}")" = "$(git rev-parse HEAD)" ]; then
            echo "already tagged today: $t points at $(git rev-parse --short HEAD)"
            echo "pass an explicit name to add another"
            exit 0
        fi
    done
    NAME="snap-$DATE"
    n=2
    while git rev-parse -q --verify "refs/tags/$NAME" >/dev/null; do
        NAME="snap-$DATE-$n"
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

# The commit must be pushed, and CI must have passed on it. A tag that points
# at a commit nobody else can fetch is useless to a consumer, and the fast gates
# below say nothing about the integration suites — so the cheap lane borrows
# CI's verdict rather than re-running it. `--force` is for the case CI is slow
# or flaky and someone is waiting on the pin.
echo "-- what is being tagged --"
git fetch --quiet origin main || true
LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_HEAD="$(git rev-parse origin/main 2>/dev/null || true)"
if [ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]; then
    echo "FAIL: HEAD ($(git rev-parse --short HEAD)) is not origin/main (${REMOTE_HEAD:0:7})."
    echo "      Push first — a tag on an unpushed commit is useless to a consumer."
    exit 1
fi

HAVE_GH=0
command -v gh >/dev/null 2>&1 && HAVE_GH=1
CI_STATE=""
if [ "$HAVE_GH" = "1" ]; then
    CI_STATE="$(gh run list --commit "$LOCAL_HEAD" --limit 1 --json status,conclusion \
        -q '.[0] | [.status, (.conclusion // "")] | map(select(. != "")) | join(" ")' 2>/dev/null || true)"
fi
case "$CI_STATE" in
    "completed success")
        echo "ci: green on $(git rev-parse --short HEAD)"
        ;;
    "")
        # Two very different cases, and only one of them is fine. Without gh we
        # cannot check, so say so and continue (that is the documented
        # limitation of this lane). With gh available but no run, the commit is
        # brand new — tagging it now ships a ref whose suites nobody has run
        # (this is how snap-2026-10-16-2 got cut seconds after its push).
        if [ "$HAVE_GH" = "1" ]; then
            if [ "$FORCE" != "1" ]; then
                echo "FAIL: no CI run for $(git rev-parse --short HEAD) yet."
                echo "      Wait for CI to start and finish, or pass --force if you ran the"
                echo "      suites locally (zig build test + zig build test-integration +"
                echo "      scripts/check-deadcode.sh)."
                exit 1
            fi
            echo "WARNING: tagging a commit with no CI run because --force was given"
        else
            echo "note: gh is not installed, so CI status cannot be checked — the fast"
            echo "      gates below are all this tag has"
        fi
        ;;
    *)
        if [ "$FORCE" != "1" ]; then
            echo "FAIL: CI on $(git rev-parse --short HEAD) is '$CI_STATE', not 'completed success'."
            echo "      Wait for it, or pass --force if you have run the suites yourself"
            echo "      (zig build test + zig build test-integration + scripts/check-deadcode.sh)."
            exit 1
        fi
        echo "WARNING: tagging with CI '$CI_STATE' because --force was given"
        ;;
esac

# The fast gates only, on top of CI: they are cheap and they catch a dirty
# working tree's effect on the build before the tag exists.
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
