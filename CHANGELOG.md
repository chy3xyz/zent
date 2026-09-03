# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- **Create / BulkInsert interceptors.** `UseInterceptor` now runs on
  `Create` and `BulkInsert` as well as Query/Update/Delete. `whereEq` on
  create fills an omitted column (if-missing); an explicit value is kept.
  Tables without the field still return `UnknownField`. Hooks still fire
  after injection so they see the filled values.

## [0.32.2] - 2026-08-31

### Fixed
- **Connection pool use-after-free.** `ConnPool` stored entries by value in
  `all` and kept raw pointers into that array in `available`; `closeConnection`
  used `swapRemove`, which moved the tail entry into the removed slot. A
  still-borrowed entry at the tail could then be aliased when a later
  `addOne` reused that slot, so a borrowed `*D` could point at a recycled or
  freed connection and a health-check `ping()` would dereference poisoned
  memory (segfault after idle eviction). Entries are now individually
  heap-allocated (`*PooledEntry`) with stable addresses; removal is by pointer
  identity from both lists. Regression test added.
- **MySQL upsert for non-integer primary keys.** `LAST_INSERT_ID(pk)` coerces
  a string/varchar PK to an integer, raising MySQL errno 1292 on the
  duplicate-key UPDATE path. Integer PKs keep the id-preserving
  `LAST_INSERT_ID` form; string/UUID PKs now fall back to `VALUES(pk)`.

### Tests
- Multi-threaded pool tests use a thread-safe allocator
  (`std.heap.page_allocator`); sharing the single-threaded
  `std.testing.allocator` across spawned threads was UB and the source of
  intermittent `failed command` crashes in CI.
- Benchmark regression canary compares against `HEAD~1` instead of
  `github.event.before`, which can point at a dangling SHA after a
  force-push/amend.

## [0.32.1] - 2026-08-27

### Added
- `examples/interceptor` — multi-tenant query-rewriting demo: a runtime tenant
  id in the interceptor `ctx` transparently scopes `Query`/`Update`/`Delete`
  via `view.whereEq("tenant_id", …)`; wired as `zig build run-interceptor`.
- Eager-loading and upsert benchmarks (`bench/eager.zig`, `bench/upsert.zig`):
  `eager/with_edge_o2m`, `upsert/save_or_update`, `upsert/save_or_update_on`,
  each against in-memory SQLite with a one-shot correctness check.

### Fixed
- CI is green again on every push. Four independent failures (all pre-existing
  at v0.32.0) are fixed: (1) connect-failure logs are `warn` instead of `err`
  so the skip path no longer fails Zig's test runner; (2) the `integration-db`
  job connects to MariaDB over TCP (`127.0.0.1`) instead of the unix socket;
  (3) the dead-code job pins zigmodu v0.15.32, which builds under the pinned
  Zig on Linux; (4) the benchmark canary is now a same-runner A/B against the
  parent commit instead of a machine-relative absolute baseline.
- Remove an unused `Value` import in `src/sql/diagnostics.zig` that the newer
  zmodu dead-code pass flags; shrink the dead-code baseline.

## [0.32.0] - 2026-08-27

### Added
- **Interceptor framework** (`src/runtime/intercept.zig`) — ent-style runtime
  query interception. `UseInterceptor(infos, &client, i)` registers an
  `Interceptor` on the client; every query/update/delete runs the chain after
  privacy checks and before execution, and each interceptor receives a
  type-erased `QueryView` whose `whereEq(field, value)` ANDs an equality
  predicate into the statement (multi-tenant `tenant_id` injection, audit
  filters). Chain pointer propagates to all five builders and `TxClient`;
  release with `DeinitClient`. Errors converge to `error.InterceptFailed`.
  Docs: `BEST_PRACTICES.md` §5d.
- PreparedCache benchmarks (`bench/cache.zig`): hot hit, cold-tail hit,
  take+return, evict churn — the byte-compare lookup path costs ~27ns hot /
  ~160ns cold tail.

### Fixed
- PreparedCache no longer keys statements by `(Wyhash, length)` alone — a
  hash collision could have handed back a statement prepared for different
  SQL. Entries store the SQL text inline (byte-compared on lookup; SQL
  longer than 2048 bytes bypasses the cache), and take/return is now
  slot-based: a taken (in-use) statement is invisible to lookups and
  eviction, and a slot invalidated by DDL `evictAll` releases the handle on
  return instead of re-caching stale SQL. Also fixes LRU order drift in the
  old `returnStmtByHash` evict branch.

### Tests
- Three-dialect integration alignment: optimistic locking (4), migrateSchema
  drop-column + dry-run, WhereIn chunking, privacy owner_id filter,
  BulkInsert id derivation (RETURNING on PG, `last_insert_id` fallback on
  MySQL), file-based migrations, cascade delete, stream iterator, and
  beginTx hook/privacy propagation now run on PostgreSQL and MySQL too
  (PG 18→31, MySQL 19→32 tests; suite total 116).

### Docs
- ISSUES_FROM_ZAPI body statuses synced (Z2/Z4/Z6/Z7 were fixed in v0.30.0);
  README comparison tables updated: migration is diff-based, PG/MySQL
  drivers are no longer "basic/placeholder".

## [0.31.0] - 2026-08-26

### Added
- `WithEdgeOptions(path, .{ .join = .inner, ... })` — eager edge loading with
  a schema-aware EXISTS inner-join filter in SQL, so `Limit` applies after
  the edge filter (no limit skew). `WithEdgeOpts` / `EdgeJoinKind` /
  `EdgeLimitMode` exported via `zent.codegen` (Z10).
- `field.Decimal(name)` — exact money columns: PG `NUMERIC`, MySQL
  `DECIMAL(38,10)` (explicit precision), SQLite `TEXT`; scans to owned
  `[]const u8`, never silently truncated to f64 (Z11).
- Fluent SELECT/ORDER BY expressions: `sql.SelectExpr(expr, alias)` with
  quoted aliases on all dialects, `sql.OrderExprSql(expr, desc)`,
  `Selector.addColumn`, `Driver.queryOwned`, and `Row.columnIndex(name)`
  for alias-based DTO mapping (Z5).
- `codegen.ManagedEntity` / `managedEntity` bind the owning allocator to an
  entity so teardown can't pick the wrong allocator; `codegen.dupeEntityTo`
  deep-copies fields, typed JSON structs and two edge levels into a caller
  arena for request-scoped HTTP handlers (Z8).
- `codegen.beginTxFromDriver(infos, driver, alloc)` — open a typed `TxClient`
  straight from a shared `Driver`/`pool.asDriver()` without a root `Client`;
  re-entrant calls degrade to a savepoint (Z9).
- Comptime graph stress tests: a single `buildGraph` compiles 400 minimal,
  400 realistic 8-field, and 300 hub-and-spoke edged schemas under the
  default 1M eval-branch quota (Z3).

### Documentation
- `UPGRADING.md` §7a: measured large-schema limits + safe-split guidance (Z3).
- `BEST_PRACTICES.md`: §5b SELECT expressions, §5c fluent complex UPDATE
  expressions (`setExprArgs` with `GREATEST`-style clamps; multi-table UPDATE
  stays raw), §2 rule 5 allocator-safe teardown helpers, §8a Driver-first
  transactions (Z5/Z8/Z9/Z12).

## [0.30.0] - 2026-08-26

### Added
- `SaveOrUpdateOn(conflict_columns)` on `CreateBuilder`/`BulkInsertBuilder` —
  business-key upserts with explicit conflict targets (PG/SQLite
  `ON CONFLICT (cols) DO UPDATE`, MySQL ODKU) (Z2).
- `SaveIgnore()` — conflict-do-nothing inserts: MySQL `INSERT IGNORE`,
  PG `ON CONFLICT DO NOTHING`, SQLite `INSERT OR IGNORE` (Z4).
- `Row.tryGetBool/tryGetInt/tryGetFloat/tryGetText/tryGetBlob` —
  error-union getters returning `error.NullColumn` on NULL (Z6).
- `crud_helpers.freeOwnedStrings` helper (zapi escape-ledger support).

### Fixed
- MySQL `ContainsEscaped` now uses `!` as the ESCAPE character (`\` is
  MySQL's string escape and corrupts LIKE patterns) (Z1).

### Documentation
- `BEST_PRACTICES.md`: upsert section (§5a), multi-graph strategy (§8a),
  escape-ledger template with "min zent version" column (Z7/Z13).
- `docs/ISSUES_FROM_ZAPI.md`: consumer issue tracker from the zapi port.

## [0.29.8] - 2026-08-13

### Internal
- CI: add a `benchmark-regression` canary job (`scripts/bench-compare.sh` +
  `scripts/benchmark-baseline.txt`) that fails on >100% `ns/op` regressions;
  loosen the threshold locally with `BENCH_REGRESSION_THRESHOLD_PCT`.
- Docs: add `SECURITY.md`, `CODE_OF_CONDUCT.md`, and issue/PR templates; sync
  `README_CN` consumer wiring to the git dependency and fix stale
  `AGENTS.md`/`CONTRIBUTING.md` references (version, repo URL, dev.md).
- Tests: cover outbox `max_attempts` exhaustion + oldest-first ordering,
  shard negative-tenant routing + shard-count mismatch, and MySQL
  `errnoToError`/`toDriverError` mapping.

## [0.29.7] - 2026-08-11

### Added
- Zent Builders (`QueryBuilder`, `UpdateBuilder`, `DeleteBuilder`) `Where` method now natively accepts dynamic predicate slices (`[]sql.Predicate` / `[]const sql.Predicate`), single `sql.Predicate` values, and pointers to tuples `&.{ ... }`. This enables `crud_helpers` (like `paginatedWithOptions`, `all`, `first`, `scoped`, etc.) to handle optional/dynamic query filters seamlessly.

## [0.29.6] - 2026-08-11

### Added
- `zent.crud_helpers`: Enhanced business query and mutation helpers:
  - `paginatedWithOptions`: Sorting (`ASC`/`DESC`) with automatic column whitelist validation against entity schema fields (`error.InvalidSortColumn`).
  - `latest`: Fetch newest single entity matching predicates with column whitelist validation.
  - `withTx`: Transaction callback wrapper with automatic commit on success, rollback on error, and guaranteed single `deinit()` cleanup.
  - `increment`: Atomic field increment / decrement helper.
  - `scoped` / `scopedBy` / `scopedFirst` / `scopedFirstBy`: Multi-tenant query scope helpers enforcing tenant ID isolation (`error.InvalidTenantColumn`).
  - `cursorPage`: Keyset cursor-based pagination helper (`CursorResult`) supporting `after`/`before` and `has_more` without `OFFSET` overhead.
  - `updateWithVersion`: Optimistic concurrency locking update helper returning `error.OptimisticLockConflict` on version mismatches.
  - `batchSaveOrUpdate`: Batch upsert helper matching on business key fields (`error.InvalidMatchColumn`).

## [0.29.5] - 2026-08-11

### Added
- `createTableSQLAlloc`, `createIndexSQLAlloc`, and `createViewSQLAlloc` in `sql/schema/migrate.zig` allowing explicit allocator propagation without OOM crash assumptions.
- `zent.graph.mermaid.toMermaid`: Generate Mermaid.js `erDiagram` markdown strings directly from `comptime` Schema definitions.
- `zent.sql_diagnostics.SqlDiagnostic`: Rich diagnostic context struct for formatting detailed database execution errors (SQL, bound args, table name, DB native error codes).
- `zent.graph.doc_exporter.toMarkdownDoc`: Export complete Markdown Data Dictionaries (fields, types, constraints, and edge relations) from `comptime` Schema definitions.
- `zent.entql.parseOrder`: Parse `ORDER BY` clause strings into typed `sql.Order` terms.
- `zent.sql_scan`: Added native `.enum` type scan support (supporting both integer tag values and string tag names across drivers).
- `zent.sql_pool`: Added proactive idle connection reaping (`reapIdleConnections`) and active health pinging (`pingIdleConnections`) to `ConnPool`.
- `zent.crud_helpers`: High-level business CRUD sugar functions including `get` (by ID), `findByIds`, `exists`, `findOrStore`, `saveOrUpdate` (with `SaveOrUpdateResult`), `paginated` (with `PageResult`), and `batchCreate`.

### Fixed
- `Meta(info).FieldID` in `codegen/meta.zig` now uses `info.pk_field` instead of hardcoding `"id"`, enabling correct primary-key field metadata queries on schemas with custom PKs.

## [0.29.4] - 2026-08-10

### Added
- `Schema` accepts a `table_name` override to map onto pre-existing
  physical tables (defaults to `toSnakeCase(name)`), and a `pk` override
  for tables whose primary key is not `"id"` (the schema must declare a
  field with that name). The custom `pk_field` propagates through graph
  resolution, CREATE (RETURNING/upsert/keyset cursor), and edge lookups.
- `@setEvalBranchQuota` raised to 1M so large schema graphs (174 tables)
  compile.

### Fixed
- `addEdgeFields` no longer injects a duplicate FK column when the From
  edge's `field_name` is already declared in the schema, and now honors
  `edge.field_name` (upstream issue #2). `buildEdgeStep` uses the real
  primary key instead of hardcoded `"id"`, fixing edge eager-load on
  tables with custom PKs (e.g. `upload_file.file_id`).
- Connection pool: rows now hold their borrowed connection until
  `deinit()`, fixing a concurrent use-after-free where another thread
  could reuse the connection (evicting prepared statements) while a
  caller was still iterating rows. Dead connections are closed and
  discarded instead of returning to the pool.

### Changed
- `Query.Sum` now returns `f64` (instead of `i64`) so numeric SUM works
  for both int and float columns, parsed via the text representation.
  Callers that typed the result as `i64` must switch to `f64`.

## [0.29.3] - 2026-08-07

### Fixed
- `QueryBuilder.WhereIn` now compiles on Zig 0.17: it appended to
  `std.array_list.Managed` with an explicit allocator argument, but 0.17's
  `Managed.append` takes only the item (only `ArrayListUnmanaged.append`
  takes an allocator). The function had no callers, so lazy compilation
  hid the breakage; new integration coverage exercises single/multi/>500
  chunk (OR-joined) and empty-value paths.
- Boolean columns scan correctly on Postgres/MySQL: `scanColumn(.bool)`
  decoded via `getInt` (base-10 parse), but Postgres `BOOLEAN` comes back
  as `"t"`/`"f"` over the wire, so every query touching a bool column
  failed with `error.TypeMismatch` (MySQL only worked because its TINYINT
  renders as `"0"`/`"1"`). Scanning now routes through the drivers'
  `getBool`; Postgres + MySQL integration tests cover real bool
  round-trips.

### Docs
- `All()` / `paged()` doc comments spell out their different return
  shapes and ownership (`std.array_list.Managed(Entity)` vs
  `PagedResult` with nested `.items.items`).

## [0.29.2] - 2026-08-07

### Fixed
- Migration version hashing (`computeMigrationVersion`) now runs at runtime
  instead of comptime. The migrate loop is `inline for (infos)`, so the old
  comptime version instantiated a hash loop for every table × operation and
  could blow the eval branch quota as schema table counts grew; the version
  numbers themselves are unchanged (FNV-1a is deterministic), so applied
  migration records remain valid.

## [0.29.1] - 2026-08-06

### Fixed
- `applyServerTimeout`'s expected `max_execution_time` probe failure on
  MariaDB (errno 1193) is no longer logged as an error — previously every
  MariaDB integration test logged an error and `zig build test-integration`
  exited non-zero even though all tests passed.

### CI
- Zig toolchain pinned to `0.17.0-dev.1567+f0354179a` (matches the local
  dev toolchain).
- Dead-code baseline builds zigmodu v0.15.10 (v0.15.5 failed to build on
  the current zig); baseline re-generated (still 24 declarations).
- Consumer dependency examples use `git+https` refs instead of tarballs.

## [0.29.0] - 2026-08-06

### Added
- Constraint error taxonomy: `UniqueViolation` / `NotNullViolation` /
  `ForeignKeyViolation` across all three drivers — duplicate keys and NOT
  NULL violations no longer surface as `error.NotFound` (SQLite INSERT...
  RETURNING previously swallowed the step error).
- `field.JSONValue(name)`: untyped JSON document fields backed by
  `std.json.Value` (specs, config blobs), with full create/scan/arena
  ownership support.
- `QueryBuilder.WhereEntQL` supports `has(edge)` / `not_has(edge)` /
  `has(edge, expr)` lowered to schema-aware EXISTS subqueries.
- Privacy `OnCreate` / `OnUpdate` / `OnDelete` / `OnQuery` are now
  operation-scoped (the codegen layer sets `PrivacyContext.op` per op).
- `examples/advanced`: composite UNIQUE index, paged listing with total,
  sensitive-field masking and the transactional outbox (`run-advanced`).
- `docs/UPGRADING.md`: v0.12 → v0.28+ migration guide.
- 30-table codegen stress test; benchmark assertions; cross-driver
  (Postgres/MySQL) JSONValue + WhereEntQL integration tests.

### Changed
- `field.Time` maps to **BIGINT epoch seconds on every dialect** (was
  TIMESTAMPTZ on Postgres) so the column type agrees with the bigint audit
  default — this fixes CREATE TABLE failing on Postgres for TimeMixin
  schemas, and is a breaking change for existing PG tables.
- addEdgeFields uses a precomputed incoming-edge table (comptime cost drops
  from O(n²·e·(e+f)) to O(n²·e + T·(e+f))).
- `SKIP_PG` centralized in `connect()` (mirrors `SKIP_MYSQL`).
- `shard.route()` uses `@bitCast` for negative tenant ids (no panic/UB);
  the global hook registry is an atomic pointer.

### Fixed
- Silent error drops logged: 14 after-hook sites, audit-column OOM,
  Tx/Savepoint rollback, mysql_options failures (SSL enforcement now
  hard-fails instead of silently downgrading).
- JSON ownership unified across create/scan/eager-load paths (per-entity
  arena); `toMaskedJson` skips the injected json_arena defensively.
- `withTimeout` on Postgres actually interrupts queries (defer was scoped to
  an if block); PG auto-increment ids emit SERIAL/BIGSERIAL.
- MySQL preferred SSL falls back to plaintext; statement timeouts apply to
  SELECTs.
- README/README_CN/RELEASING dependency examples use `git+https` refs
  (tarball hashes are unstable on 0.17-dev).
- Examples build on current dev zig (`.edges` recursion, `hash.crc`,
  `QueryIterator.select_cols`).

## [0.28.0] - 2026-08-06

### Added
- EntQL `has(edge)` / `not_has(edge)` / `has(edge, expr)` — the parser now
  accepts them and `QueryBuilder.WhereEntQL()` lowers them to schema-aware
  EXISTS subqueries (previously a compile error).
- Privacy operation-level policies are real: `OnCreate` / `OnUpdate` /
  `OnDelete` / `OnQuery` deny only their own operation (the codegen layer
  sets `PrivacyContext.op` per operation).
- Codegen scale regression protection: a 30-table x 8-field stress test
  (edges/indexes/JSON) compiles and runs a CRUD smoke.
- Benchmarks now assert result correctness (generated SQL, scanned values,
  borrowed connection) and fail loudly instead of print-and-continue.

### Changed
- JSON field ownership unified across create and scan paths: query results
  (including eager-loaded edges) parse JSON into a per-entity arena that
  `deinitEntity` releases — no more caller-owned JSON on the scan path.
- `@setEvalBranchQuota` raised for codegen generation (predicates,
  migrations, graph lowering) so 20+ table schemas compile.

### Fixed
- `zig build` was red on both CI and current dev zig: eager-load recursion
  into the terminal PlainFields type, `std.hash.crc` API drift, and
  `QueryIterator` losing `select_cols` (column projection) are fixed.
- PostgreSQL `withTimeout` actually interrupts queries — a `defer` scoped to
  an `if` block reset `statement_timeout` before the query ran; PG
  `createAllTables` also emits `SERIAL`/`BIGSERIAL` ids now.
- MySQL preferred SSL mode falls back to plaintext instead of enforcing TLS;
  server-side statement timeouts apply to SELECTs; 14 silent `catch {}`
  error drops (after-hooks, audit fields, Tx/Savepoint rollback,
  mysql_options) now log.
- CI/test infra: PG/MySQL integration tests are optional (compile without
  libpq/libmariadb headers), `SKIP_MYSQL` matches `SKIP_PG`, and
  check-version scripts work on macOS (`git tag --sort=-v:refname`).
- README (en/zh) example compiles and runs; AGENTS.md / ARCHITECTURE.md
  synced with the actual API.

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
