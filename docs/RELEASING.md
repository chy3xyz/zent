# Releasing zent

Two lanes, deliberately. The distinction is what a **consumer** reads: a tag
says "this commit is what it looks like", a release says "this is a version you
can depend on, with a changelog section and a published artifact".

| | snapshot tag | release |
|---|---|---|
| command | `scripts/tag.sh [--push]` | `scripts/release.sh <x.y.z> [--push]` |
| how often | as often as you like | roughly **weekly**, batched |
| name | `snap-YYYY-MM-DD[-n]` | `vX.Y.Z` |
| package version | **unchanged** | bumped (`build.zig.zon`, `src/version.zig`, READMEs, AGENTS.md) |
| CHANGELOG | untouched (entries stay under `[Unreleased]`) | `[Unreleased]` promoted to the version |
| gates | fmt + unit tests | fmt + unit tests, plus the CI gates below |
| GitHub Release | no | yes (from the promoted CHANGELOG section) |
| what it pins | that commit | the version, its changelog and its notes |

Why tags can be cheap: a Zig consumer pins `#<ref>` **plus a content hash**, so
any tag is a usable pin — including one that names a commit the library never
"released". The package version stays put, `check-version.sh` is unaffected,
and nothing has to be written up.

## Snapshot tags (the cheap lane)

```bash
scripts/tag.sh --push              # snap-2026-10-16, or -2, -3 if the day has one
scripts/tag.sh before-pool-rewrite --push   # an explicit name
```

It refuses a semver-shaped name on purpose: `vX.Y.Z` means "release", and
release tags are what `scripts/check-version.sh` and
`scripts/check-release-tag.sh` compare the package version against — a snapshot
that borrowed the shape would break both gates and mislead a consumer.

The tag is annotated with the commits since the previous tag, so
`git show snap-2026-10-16` explains itself without a changelog entry.

Use it for: handing a consumer (or a colleague, or a bisect) the exact tree you
just verified; marking a known-good point before a risky change; publishing a
fix that a downstream project needs today while the release waits for the
weekly batch. Do **not** use it as a release: no changelog entry is written, so
nobody reading the repository learns anything from it.

## Releases (the rare lane)

```bash
scripts/release.sh 0.95.0 --push
```

It: verifies a clean tree on `main` → prints how long ago the last release was
(a release within a week is allowed, but says out loud that the snapshot lane
exists) → bumps `build.zig.zon` + `src/version.zig` + README/README_CN +
AGENTS.md → promotes `CHANGELOG.md`'s `[Unreleased]` to the new version → runs
`zig fmt --check` + `zig build test` → commits + annotated tag → asserts the tag
matches the package version (`scripts/check-release-tag.sh`) → pushes `main` and
the tag → publishes a **GitHub Release** whose notes are the CHANGELOG section
that was just promoted (so the two cannot disagree; a missing or
unauthenticated `gh` is a warning, since the tag is already pushed).

Manual equivalent:

```bash
scripts/bump-version.sh 0.95.0   # bumps + tags locally
bash scripts/check-version.sh    # CI gate, verifies docs + tag/version order
ZMODU=<zmodu> bash scripts/check-deadcode.sh   # CI gate: no new dead declarations
zig build test-integration       # CI gate: the integration suites (SQLite + PG/MySQL)
git push origin main --tags
```

The extra gates are here because a tag has shipped red for exactly these
reasons: `zig build test` does not compile `tests/integration/` (a rename in the
library left that suite unbuildable, v0.73.0), and it says nothing about dead
code (an unused import in a new test file, v0.76.1). Both were green locally and
red in CI. Run the gates the way CI runs them.

## Rules

- `build.zig.zon` `.version` is the single source of truth; `.fingerprint` is
  the permanent package identity and **must never change**.
- `src/version.zig` mirrors it for consumers (`zent.version`) so a pin can be
  checked without consulting git; `check-version.sh` gates the two, and both
  bump scripts update both.
- **Never hand-write the release section in `CHANGELOG.md`.** `release.sh` /
  `bump-version.sh` promote `[Unreleased]` to the new version themselves, so a
  section you add first survives as a second, empty heading with the same
  version — the real entries then sit under the duplicate. v0.39.1 shipped that
  way. Write future entries under `[Unreleased]` and let the script move them;
  `check-version.sh` now fails on a duplicated version heading.
- `check-version.sh` runs in CI: README/README_CN must reference the current
  version, `src/version.zig` must match, the first CHANGELOG version section
  must be the package version, and the package version must be ≥ the latest
  **release** tag (snapshot tags are ignored by construction — the gate globs
  `v[0-9]*.[0-9]*.[0-9]*`).
- CHANGELOG keeps an `[Unreleased]` section at the top (Keep a Changelog flow).
  Between releases, that section is where the work accumulates — the weekly
  batch is the unit a consumer reads, so write entries for it, not per commit.

## Zig version pin

zent targets **Zig 0.17.0** (the stable release; `minimum_zig_version` in
`build.zig.zon` names it), and CI installs exactly that version. `0.17.0-dev.*`
snapshots sort below the release and are refused. When moving the pin:

1. Update the `version:` field of every `setup-zig` step in
   `.github/workflows/ci.yml` (the test, integration and dead-code jobs).
2. Update `minimum_zig_version` in `build.zig.zon`, the prerequisites in
   `README.md` / `README_CN.md` / `CONTRIBUTING.md`, `AGENTS.md` and
   `docs/UPGRADING.md` §8 — together, in one commit (they are one fact).
3. Re-run `zig build test` and `zig build test-integration` locally with the
   new toolchain before committing.

## Consumer impact (hash sync)

Zig package consumers lock onto `name + version + file hash` in their
`build.zig.zon` (e.g. `zent-0.94.0-<hash>`). After every release, consumers
must refresh the dependency — otherwise Zig rejects the stale hash:

```bash
# in the consumer project
zig fetch --save git+https://github.com/chy3xyz/zent.git#v0.94.0
```

or update the `.zent` URL/hash in `build.zig.zon` manually and run
`zig build` to let Zig report the expected hash. A snapshot tag works the same
way (`#snap-2026-10-16`), which is the point of the cheap lane.
