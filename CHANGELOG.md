# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [0.18.0] - 2026-08-03

### Added
- `QueryBuilder.paged(page, page_size) → PagedResult{items,total}` — one
  count + one limit/offset fetch, unified deinit.
- `QueryBuilder.CountBy(col) → GroupCount{key,count}[]` — single GROUP BY
  aggregate helper.
- `sql.ContainsEscaped` + generated `{col}ContainsEscaped` predicate —
  render-time escaping of `%`/`_`/escape char.
- `BulkInsertBuilder.SaveOrUpdate` — bulk upsert (`ON CONFLICT DO UPDATE` /
  `ON DUPLICATE KEY UPDATE`), one id per row via RETURNING or
  last_insert_id.

### Fixed
- Package version synced to release tags (0.12.1 → 0.18.0); release
  toolchain (`scripts/check-version.sh` / `bump-version.sh` / `release.sh`)
  added so tag/version drift can't recur.

## [0.17.0]

### Fixed
- MySQL real upsert (schema + codegen review feedback).

Older releases: see `git tag` history.
