# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [0.27.0] - 2026-08-04

### Added
- Public root export of `codegen.toMaskedJson` — the sensitive-field JSON
  masking helper is now reachable as `zent.codegen.toMaskedJson(...)` so
  consumers no longer need to reach into internal file paths.

### Fixed
- Optional fields (`field.*.Optional()`) now work across create / get /
  update / bulk paths: `setFieldValue` accepts bare values for optional
  fields, SQL binding handles null, validators skip null, and `ownedCopy`
  duplicates `?[]const u8` correctly (no dangling strings on read).

## [0.26.0] - 2026-08-04

### Added
- Column projection: `QueryBuilder.Select(cols)` restricts the query to a
  column subset (skips large text/blob fields); rows scan by name
  (`scanRowNamed`) and unselected fields keep zero values (read-only).
- Bulk soft delete: `BulkDelete` on `soft_delete` entities updates
  `deleted_at` per WHERE group (OR semantics) instead of compile-erroring.
- `field.Custom(pattern)` validator lands as wildcard matching (`*` any
  sequence, `?` one char).

### Fixed
- Dangling-pointer bug in pointer-based `And`/`Or` predicate trees
  (`WhereIn` stored pointers to expired stack locals). New value-semantics
  `or_in` predicate (`col IN (…) OR col IN (…)`) with chunks owned by the
  query builder.

## [0.25.0] - 2026-08-04

### Added
- `AuditMixin` (`created_by` / `updated_by`): Create/Update auto-fill from
  `PrivacyContext.user_id` unless set explicitly — audit trail for who
  created/changed a row.
- Built-in validators: `NotEmpty`, `Length(min, max)`, `Email`, `Phone`
  (lightweight checks in `validateSqlValue`, run automatically on
  Create/Update).
- Soft-delete restore: `DeleteBuilder.Restore(id)` clears `deleted_at`
  (compile error on non-soft-delete entities).

## [0.24.0] - 2026-08-04

### Added
- Nested transactions via savepoints: `Driver.beginSavepoint` (SQLite /
  Postgres / MySQL, pool-forwarded) and `codegen.beginTx` degrading to
  `SAVEPOINT` when already inside a transaction — re-entrant service
  orchestration with inner rollback/commit semantics.
- After-commit hook: `TxClient.afterCommit(ctx, fn)` fires once after a
  successful commit (cache invalidation, indexing, notifications).
- Distributed ids: `core.id.uuidv4() / uuidv7(now_ms) / format()` with a
  statically-held CSPRNG; uuid primary keys support Create/Save, query by
  id, CursorAfter, and eager edge loading (compile-time map selection).
- Sensitive-field JSON masking: `codegen.entity.toMaskedJson` emits
  sensitive fields as `"***"` (APIs must use it instead of serializing raw
  entities — @Struct has no decls slot for jsonStringify).
- Transaction-scoped event collection: `TxClient.enqueueEvent` /
  `takePendingEvents` (typically from the after-commit hook) for
  outbox/audit/notifications.
- Update-path sensitive log masking (create already masked; update/query
  were leaking secrets into exec logs).
- Chunked `IN` clauses: `sql.InChunked`, `QueryBuilder.WhereIn`, and
  chunked eager-load parent ids (SQLite ~999 parameter cap).
- `CrudService.insertMany` / `upsertMany` batch writes.

## [0.23.0] - 2026-08-03

### Added
- Composite keyset pagination: `CursorKeyset(col, value, id, desc)` generates
  `WHERE (col > ?) OR (col = ? AND id > ?) ORDER BY col, id` — ties on the
  cursor column (e.g. duplicate feed timestamps) no longer drop rows between
  pages.
- Eager-loaded edge filtering: `Edge.WhereRaw(fragment, args)` filters which
  neighbors load (e.g. only visible comments); filters apply before
  order/limit so limits rank filtered rows.

### Changed
- `sql.Value` moved to `src/sql/value.zig` (re-exported by the builder) so
  `core/edge` and `graph/step` can reference it without a builder↔step import
  cycle.

## [0.22.0] - 2026-08-03

### Added
- Audit timestamps auto-maintained: `created_at` / `updated_at` (`.time`)
  columns get a dialect-aware epoch `DEFAULT` (`(unixepoch())` /
  `EXTRACT(EPOCH FROM now())::bigint` / `UNIX_TIMESTAMP()`) — matching zent's
  i64 Time storage; `UpdateBuilder` auto-refreshes `updated_at` unless the
  caller sets it explicitly.
- Eager-loaded edge lists can be ordered and capped:
  `edge.To(...).OrderBy("created_at").Desc().Limit(10)` — per-parent `LIMIT`
  uses `ROW_NUMBER() OVER (PARTITION BY fk …)` for O2M/O2O (other relations
  reject limits with `UnsupportedEdgeLimit`).

### Fixed
- `Edge.Field(fk)` was ignored for `To` edges — FK column names were
  hardcoded to `source_table_id` in both `graph.addEdgeFields` and
  `tableFromTypeInfoCrossRef`, so explicit FK bindings never took effect.

## [0.21.0] - 2026-08-03

### Added
- Atomic expression parameters: `sql.UpdateBuilder.setExprArgs` and the
  generated `UpdateBuilder.setExprArgs(field, expr, args)` — `?` placeholders
  in SET expressions are rewritten dialect-aware and bound in SQL order
  (SET args precede WHERE args). Enables oversell-safe stock decrement:
  `SET stock = stock - ? WHERE id = ? AND stock >= ?`, with
  `rows_affected == 0` meaning insufficient stock.
- Two-level nested eager loading: `QueryBuilder.WithEdge("posts.comments")`
  preloads two levels (one IN neighbor query per level). `LightEntity` now
  carries one shallow edges level (terminal targets are plain fields; deeper
  paths are compile errors), and `deinitEntity` recursively frees nested edge
  slices.

### Fixed
- Global-hook registry test left a dangling chain pointer that crashed later
  Create/Save tests.

## [0.20.0] - 2026-08-03

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
