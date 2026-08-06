# Releasing zent

Release discipline is scripted so the package version, docs and git tag can
never drift apart (v0.12.1-vs-v0.17.0-tags was exactly that class of bug).

## One-shot release

```bash
scripts/release.sh 0.19.0 --push
```

It: verifies a clean tree on `main` → bumps `build.zig.zon` + README/README_CN
→ promotes `CHANGELOG.md` `[Unreleased]` to the new version → runs
`zig fmt --check` + `zig build test` → commits + annotated tag → asserts the
tag matches the package version (`scripts/check-release-tag.sh`) → pushes.

Manual equivalent:

```bash
scripts/bump-version.sh 0.19.0   # bumps + tags locally
bash scripts/check-version.sh    # CI gate, verifies docs + tag/version order
git push origin main --tags
```

## Rules

- `build.zig.zon` `.version` is the single source of truth; `.fingerprint`
  is the permanent package identity and **must never change**.
- `check-version.sh` runs in CI: README/README_CN must reference the current
  version, and the package version must be ≥ the latest tag.
- CHANGELOG keeps a `[Unreleased]` section at the top (Keep a Changelog flow).

## Consumer impact (hash sync)

Zig package consumers lock onto `name + version + file hash` in their
`build.zig.zon` (e.g. `zent-0.12.1-<hash>`). After every release, consumers
must refresh the dependency — otherwise Zig rejects the stale hash:

```bash
# in the consumer project
zig fetch --save git+https://github.com/chy3xyz/zent.git#v0.18.0
```

or update the `.zent` URL/hash in `build.zig.zon` manually and run
`zig build` to let Zig report the expected hash.
