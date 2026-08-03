# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- `helpers` module — official environment assemblers lifted from the ZigModu
  example into the framework: `StoreEnv` (single store + `driver()` accessor),
  `PooledEnv` (thread-safe `sql_pool`-backed client), `ShardedEnv`
  (per-shard driver/client + `ShardSet` routing), `TestEnv` (isolated
  in-memory store with `reset()`).
- `sql_pool.ConnPool`: `connect` is now optional and a `connectCtx` factory
  pair was added, so pools can open connections with runtime configuration
  (e.g. a file path) without globals.
- `shard.ShardRouter.moveTenant` / `ShardSet.rebalance` — idempotent tenant
  rebalance (no-op when already routed to the target shard).

## [0.19.0] - 2026-08-03

### Added
- `crud.CrudService(infos, info, tenant_col)` — generic list/get/create/
  update/delete over the generated client with tenant scoping and a
  `CrudEvent{created,updated,deleted}` listener (schema-as-code answer to
  zmsaas' sqlx CrudService).
- `privacy.data_scope` — DataScopeFilter + Policy mapping the
  all/self_/dept_only/dept_and_child/dept_custom scopes onto zent policies;
  the scope predicate is injected at the SQL layer per query.
- `outbox.Outbox(infos, outbox_info)` — transactional outbox: enqueue inside
  `tx.client` (atomic with the business write), dispatch with
  at-least-once semantics, requeue-with-attempts until max_attempts.
- `shard.ShardSet(infos)` + `ShardRouter` — tenant → shard routing with an
  explicit map and stable hash fallback over one generated Client per shard.

### Fixed
- `CrudService.get` freed scan rows with the caller's allocator instead of
  the client allocator (mismatched-free UB + per-call leak when the caller
  passes a request arena); regression test added.
- Dormant `graph/neighbors` tests revived; predicate rendering now splits
  dotted columns (`group.name` → `"group"."name"` instead of `"group.name"`).

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
