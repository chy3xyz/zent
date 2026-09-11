# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- **BulkInsert chunks rows around the bound-parameter limit.** `BulkInsert.Save`
  emitted a single multi-row INSERT, so a batch large enough to exceed the
  driver's parameter budget (SQLite's `SQLITE_MAX_VARIABLE_NUMBER` is 999 on
  builds older than 3.32) failed outright. Rows are now inserted in chunks
  sized from the dialect limit, and each chunk's ids are accumulated so the
  caller still receives one id per row. `chunkRows(n)` overrides the derived
  budget when a caller wants to bound statement size (e.g. MySQL
  `max_allowed_packet`) or to pin chunk boundaries.
- **`queryTargetsByValue` for UUID/textual primary keys.** `QueryEdge`'s
  traversal helper only accepted `[]const i64` parents, so entities keyed by
  a `field.UUID("id")` string PK could not traverse edges at all. The new
  `codegen.client.queryTargetsByValue(infos, source, edge, parent_ids:
  []const sql.Value, …)` takes any PK type (`.int` or `.string`), and
  `queryTargets` keeps its signature as an integer-only wrapper that
  delegates to it. Same semantics — empty-list short-circuit, dialect
  placeholders, target soft-delete scope, caller-owned result.
- **`StorageKey`: map a Zig field onto a differently-named SQL column.**
  `field.String("userName").StorageKey("user_name")` decouples the field name
  used by the fluent API (`setFieldValue("userName", …)`, typed predicates,
  `Select`/`OrderBy`/`GroupBy`, interceptor `whereEq`) from the physical
  column emitted in DDL, `INSERT`/`UPDATE`/`SET`, `WHERE`/`ORDER BY`/
  `GROUP BY`, indexes, and cursor pagination — the mapping needed to adopt
  zent on an existing schema. `FieldInfo` now carries `column_name` alongside
  `name`, and `codegen.graph.columnName(info, field)` resolves a field name
  to its column. Schemas that never call `StorageKey` are unchanged
  (column name == field name).
- **Outbox stale-claim recovery.** The claim-based dispatcher added in 0.35.0
  could strand a row in `processing` forever if a dispatcher died after
  claiming it. `OutboxMessage` now has a nullable `claimed_at` column (epoch
  ms) that `claim` writes in the same statement that flips the row to
  `processing`, and the new `OutboxOps.requeueStale(allocator, client,
  older_than_secs)` returns `processing` rows whose claim is older than the
  threshold — a NULL `claimed_at` counts as stale, and `older_than_secs <= 0`
  reclaims every `processing` row — to `pending` with `claimed_at` cleared.
  `markPublished` / `markFailed` / `requeue` also clear `claimed_at`. Call
  `requeueStale` from a periodic sweeper (a threshold several times the
  longest publish). **This adds a column, so existing deployments need one
  schema migration** (`migrateSchema` adds it automatically; downgrades must
  drop it manually).
- **Migration locking and checksum verification.** `MigrateOptions.lock_timeout_ms`
  (default 10 s, `0` disables) takes an advisory lock for the whole migration:
  `pg_advisory_lock` on PostgreSQL and `GET_LOCK`/`RELEASE_LOCK` on MySQL, so
  several instances starting at once no longer race on the existence/absence
  checks. A lock that cannot be taken and a timeout both surface as
  `error.MigrationLockTimeout`; if the lock statement is unsupported or
  denied, the migration warns and continues rather than failing. SQLite relies
  on its single-writer transaction instead. Already-applied file migrations
  now have their recorded checksum compared against the file on disk
  (`error.MigrationChecksumMismatch`), so an edited migration is caught
  instead of silently skipped. The history table's `checksum` column may be
  NULL (schema-diff migrations and rows predating verification), which is
  treated as "not recorded" rather than a mismatch.
- **MySQL TLS material (CA, client certificate/key, cipher).** The MySQL
  driver previously called `mysql_ssl_set` with every argument NULL, so
  `verify_ca` enabled certificate verification with no CA to verify against
  and mutual TLS was impossible. `MySQLDriver.SslConfig` (`mode` plus `ca`,
  `capath`, `cert`, `key`, `cipher` PEM paths) is now threaded through the new
  `connectOptsSsl` / `connectOptsSslSocket` entry points; the existing
  `connect` / `connectOpts` / `connectOptsSocket` keep their signatures and
  delegate with `SslConfig{ .mode = ... }`. `verify_ca` only verifies when a
  `ca` (or `capath`) is supplied, and `REQUIRE X509` needs both `cert` and
  `key`. Integration coverage (skipped unless `MYSQL_SSL_CA` is set, with
  `MYSQL_SSL_CERT` / `MYSQL_SSL_KEY` for mTLS) asserts an actual TLS session
  via `Ssl_cipher`, that a wrong CA is rejected, and that a client
  certificate satisfies `REQUIRE X509` while its absence does not.

### Fixed
- **A UUID primary key is no longer rewritten to an integer.** `TableDef`
  marked *every* id column as auto-increment, so PostgreSQL replaced the
  declared type with `SERIAL` — a `field.UUID("id")` primary key silently came
  out as `integer` — and MySQL appended `AUTO_INCREMENT` to a `TEXT` column,
  failing `CREATE TABLE` with errno 1170. Auto-increment now applies only to
  integer ids, and MySQL maps `uuid` to `CHAR(36)` instead of `TEXT`, which
  cannot be indexed without a key length. Covered by a per-dialect test that
  runs the library's own `createAllTables` (asserting the emitted column type
  on PostgreSQL and MySQL) and round-trips a UUID-keyed row.
- **Interceptor chains survive a `Client` move.** `Client` held its interceptor
  chain **by value** while every entity sub-client stored a pointer into that
  field, so any move of the `Client` value — `makeClient`'s return, the
  helpers storing it, `withContext`, a tx client — left those pointers
  dangling and the next query touched freed memory. The chain is now lazily
  heap-allocated on first `UseInterceptor`, so a move relocates a pointer, not
  the chain. `Client.owns_interceptors` distinguishes an owned chain from one
  borrowed via `withInterceptors`, and `DeinitClient` frees only the former;
  call it once, on the value that registered. `StoreEnv`/`PooledEnv`/
  `ShardedEnv` deinit the client they created, which previously leaked any
  registered chain.
- **Global hook registry can be released.** `registerGlobal` took a
  caller-owned pointer with no way to unregister, so a chain that went out of
  scope left the registry dangling into freed memory. `unregisterGlobal(chain)`
  clears it only when that chain is the registered one.

## [0.35.0] - 2026-09-11

### Added
- **Typed predicates for IN / NULL / prefix / suffix / case-insensitive.**
  Every field gains `In`, `NotIn`, `IsNull`, `NotNil`; `string`/`text` fields
  gain `HasPrefix`, `HasSuffix`, `ContainsFold`, `EQFold`; every edge gains
  `NotHas<Edge>`. The LIKE variants reuse the escaped-literal renderer, so
  user input stays literal (wildcards escaped) with no injection surface and
  no pre-escaped allocation. `Has<Edge>With` already accepted the target
  entity's typed predicates; that is now covered by a test. Catalogue in
  `BEST_PRACTICES` §3a.
- **Edge writes on `UpdateBuilder`.** Association maintenance no longer needs
  hand-written junction SQL: `AddEdgeIDs(edge, ids)` (idempotent),
  `RemoveEdgeIDs(edge, ids)`, `SetEdgeIDs(edge, ids)` (replace, detaching the
  previous owner first) and `ClearEdge(edge)`. M2M edges write the junction
  table; `To` o2m/o2o edges move the FK in the target table. Wrong edge kinds
  fail at compile time with an actionable message, and non-nullable FKs are
  rejected for detach operations. The statements are scoped by a subquery over
  the same predicate set as the parent UPDATE, so they inherit its privacy /
  interceptor scoping — wrap the update in `beginTx` for atomicity.
- **Outbox claim-based dispatch.** New `Outbox.claim(allocator, client, limit)`
  atomically moves a batch of rows from `pending` to the new `processing`
  status and returns them, and `dispatch` now goes through it. PostgreSQL and
  SQLite claim in a single `UPDATE … RETURNING` (PostgreSQL adds
  `FOR UPDATE SKIP LOCKED`); MySQL runs `SELECT … FOR UPDATE SKIP LOCKED` plus
  the `UPDATE` inside one transaction. Because the rows are reserved before
  publishing, concurrent dispatchers no longer fetch and publish the same
  rows. `processing` is a plain string value, so no migration/DDL change is
  needed. Rows left in `processing` by a crash are **not** reaped
  automatically (no recovery API is provided); requeue stale rows out of band.
  `pending` remains as a non-claiming read path.

### Fixed
- **Eager loading generated invalid SQL past the parameter limit.**
  `writeInClauseChunked` emitted `col IN (a, b) OR (c, d)` — a bare row value
  as an OR operand, which PostgreSQL rejects and SQLite reports as
  "row value misused". Any `WithEdge` load over 500 parents failed. Each chunk
  now repeats `col IN (...)`.
- **Eager-loaded targets bypassed the read contract of a normal query.** They
  were fetched with no soft-delete filter, no privacy policy/row filters and
  no interceptor chain — a cross-tenant leak wherever interceptors inject the
  tenant, plus soft-deleted children appearing in results. The target contract
  (soft-delete → privacy → interceptors) is now applied inside the neighbour
  `WHERE`, before any per-parent window ranking, so a filtered row cannot
  consume a per-parent `LIMIT` slot.
- **`QueryEdge` traversal emitted dialect-invalid SQL.** `queryTargets`
  hand-concatenated `?` placeholders, double-quoted identifiers and literal
  `"id"` / `{table}_id` key and junction columns — wrong on PostgreSQL and
  MySQL, and wrong on SQLite whenever the primary key or junction column was
  named differently. It now renders through the same generator as eager
  loading (`buildEdgeStep` + `appendSetNeighborsFiltered`) and applies the
  target's soft-delete scope. The helper still takes no
  privacy_ctx/interceptors — documented on the function; use `WithEdge` when
  you need tenant scoping.
- **PostgreSQL and MySQL issued an extra `SET` per statement.** Both drivers
  ran the timeout reset unconditionally in a `defer`, even when the statement
  carried no deadline (MySQL performed no SET at all in that case, so the
  reset was pure overhead). They now track the timeout in effect per
  connection and only send `SET` when the desired value differs:
  deadline-free statements cost zero extra round-trips, and statements with a
  deadline lose the trailing reset.
- **Concurrency failures could not be told apart.** PostgreSQL 40001/40P01,
  MySQL 1205/1213 and SQLite BUSY/LOCKED all collapsed into generic failure
  errors, so callers could not know what was worth retrying. They now map to
  `SerializationFailure` / `DeadlockDetected` / `LockTimeout`,
  `driver.isRetryable` classifies transient errors, and `driver.retryTx`
  replays a whole transaction with exponential backoff (`Tx.deinit` exactly
  once per attempt).
- **MySQL no-arg `exec` left its result set pending.** A `SELECT` issued
  through exec made the NEXT command fail with errno 2014 "Commands out of
  sync". The result set is now consumed and freed (a no-op for
  INSERT/UPDATE/DDL).
- **Quoted identifiers did not escape their own quote character.** A name
  containing `"` (or a backtick on MySQL) closed the identifier early —
  reachable from request input via ORDER BY column names. `Builder.ident`,
  `Dialect.quoteIdent` and `quoteIdentToBuffer` now double embedded quotes per
  the SQL standard.
- **Migrations hardcoded `std.heap.page_allocator`.** `createTables`,
  `createAllTables` and `Client.createAllTables` now take an allocator and
  thread it through the `*Alloc` SQL builders, so allocate/free always pair on
  the same allocator and those paths are leak-checked under
  `std.testing.allocator`.
- **Connection-pool release wrote to a freed entry on the OOM path.**
  `release` closed the entry in a `catch` and then still assigned
  `entry.idle_since`; closing destroys the entry, so that was a
  use-after-free write.
- **Connection-pool metrics callbacks run outside the mutex.** `borrow` and
  `release` now invoke `Metrics.onBorrow` / `Metrics.onRelease` after
  unlocking, so a callback that re-enters the pool (reads pool state, borrows
  a connection, logs through the pool) no longer self-deadlocks. The borrow
  path's health check still runs inside the mutex, so
  `health_check_on_borrow` serializes concurrent borrows — a known limitation,
  now documented on `Options.Metrics`.
- **Privacy policies fail closed past their filter capacity.** A policy whose
  rules produced more than the inline limit (8) row-level filters hit a
  `std.debug.assert` — a process abort under ReleaseSafe, and a silently
  dropped filter (widened result set for a security policy) in builds without
  assertions. The overflow now denies the operation and logs why.
- **`monotonicNs` no longer traps.** A failing `clock_gettime(CLOCK_MONOTONIC)`
  hit `unreachable`, which is undefined behaviour in ReleaseFast and an abort
  under ReleaseSafe. It now degrades to the wall clock with a warning and
  reports 0 only if both clocks fail.

### Docs
- Documented the predicate catalogue (`BEST_PRACTICES` §3a) and the new edge
  writes (§5e), including a cross-dialect note that MySQL's
  `rows_affected` counts *changed* rows while SQLite/PostgreSQL count
  *matched* rows.

## [0.34.0] - 2026-09-07

### Added
- **Parameterized raw predicates.** `sql.RawArgs(sql_text, args)` renders a
  raw SQL fragment whose `?` markers are rebound to dialect placeholders in
  order (`$N` on PostgreSQL), composing with typed predicates via
  `sql.And`/`sql.Or`. A marker/argument count mismatch fails with
  `error.RawArgCountMismatch` instead of emitting malformed SQL. Covers
  fragments typed predicates cannot express (`BETWEEN`, `IN (…)`, function
  calls) without string-concatenating values.
- **Aggregate query helpers** on `QueryBuilder`:
  - `SumOrZero("col")` — `COALESCE(SUM("col"), 0)`, returns `0` on empty
    sets instead of `NULL`.
  - `AggregateOne("COUNT(DISTINCT name)")` — single-value aggregates as a
    typed `sql.Value` (`null`/`int`/`float`/owned `string`).
  - `AggregateText("SUM(\"amount\")")` — aggregate read back as exact
    decimal text (`?[]u8`, caller frees) for money columns where `f64`
    rounding is unacceptable.
  - `AggregateBy("SUM(\"amount\")", "status")` — raw aggregate grouped by a
    schema field, honoring `Where` predicates, soft-delete filtering and
    `Having`; returns `Managed(GroupMetric)` released with
    `freeGroupMetrics`. Appends to an existing `GroupBy` column list.
- **Upsert custom update expressions.** `SaveOrUpdateOnWith(conflict_cols, exprs)`
  takes per-column `UpsertSetExpr{ .column, .expr }` templates rendered on the
  duplicate-key path, e.g. `{t:receive_num} + 1` for counter increments
  (`{t:col}` = table-qualified column, `{x:col}` = `EXCLUDED."col"` on
  PostgreSQL/SQLite, `VALUES(\`col\`)` on MySQL). Placeholder columns are
  validated to `[A-Za-z0-9_]`; other columns keep the default
  `EXCLUDED`/`VALUES()` assignment. On SQLite, supplying expressions switches
  from `INSERT OR REPLACE` (delete+insert, breaks FK/ROWID invariants) to
  `INSERT … ON CONFLICT … DO UPDATE`.
- **Raw-query DTO scanning.** `sql_scan.queryAll(T, allocator, driver, sql, args)`
  / `sql_scan.queryOne(...)` run a raw driver query and scan rows into any
  DTO struct by column name (`scanRowNamed` semantics — unselected fields
  keep zero values); `sql_scan.freeDto(T, allocator, &item)` releases the
  string fields duplicated at scan time. Failed mid-scan calls free the
  already-collected items (errdefer), keeping `zig build test` leak-clean.
  This replaces hand-written `rows.next()` + per-column `getInt`/`getText`
  loops in consumer persistence code.
- **Row-lock variants.** `Selector.forUpdateWith` / `QueryBuilder.ForUpdateWith`
  accept `LockOpts{ .of, .skip_locked, .nowait }`: `FOR UPDATE OF "table"`
  scopes the lock to one table on PostgreSQL; `SKIP LOCKED` / `NOWAIT`
  (PostgreSQL 9.5+, MySQL 8+) skip or fail on locked rows instead of
  blocking — the queue-drain pattern for worker pools. Unsupported clauses
  degrade per dialect: `OF` is PostgreSQL-only, lock modifiers are omitted on
  SQLite (no row locks).

## [0.33.0] - 2026-09-03

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
