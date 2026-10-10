# Upgrading zent

This guide covers the changes you are likely to hit when upgrading a consumer
to the current release. It focuses on the two kinds of change that need action
from you — a call-site edit, or a database migration — rather than listing every
release; the full change history lives in `CHANGELOG.md`, and the version this
guide is written against is the one in `build.zig.zon` / `src/version.zig`.

The sections are cumulative. §1–§9 are the standing API notes —
`std.array_list`, `std.json`, time, JSON ownership, edges, privacy, queries,
the comptime budget, the build, and the outbox/helpers — and a consumer coming
from the v0.12 era needs all of them. §10 onwards are the per-release breaking
changes and required migrations, so a consumer already on a recent version can
start there.

## 1. std.array_list / Managed API

zig 0.17 moved away from the old `std.ArrayList(T).init(alloc)` /
`.append(x)` shape used by early zent versions.

| Old (v0.12 era) | New |
|---|---|
| `std.ArrayList(T).init(alloc)` | `std.array_list.Managed(T).init(alloc)` (or `.empty`) |
| `list.append(x)` | `list.append(alloc, x)` |
| `list.items[i]` | unchanged |
| `list.deinit()` | `list.deinit()` (allocator stored internally) |

Entity collections returned by queries are `Managed(Entity)`:

```zig
var users = try q.All();
defer {
    for (users.items) |*u| zent.codegen.deinitEntity(infos, infos[0], u, allocator);
    users.deinit();
}
```

## 2. std.json / Stringify

- `std.json.stringify` was replaced by `std.json.Stringify.valueAlloc(...)`.
- `std.json.parseFromSliceLeaky(T, allocator, text, .{})` is the standard
  parsing entry point (see §4 for JSON ownership).

## 3. Time / timestamps

- `std.time.milliTimestamp()` / `nanoTimestamp()` no longer exist; use
  `std.time.Instant` or zent's `zent.sql_logger.nowUs()`.
- `field.Time` columns are **BIGINT epoch seconds on every dialect**
  (PostgreSQL included): the application layer reads/writes `i64` epochs and
  the audit default is `EXTRACT(EPOCH FROM now())::bigint` /
  `UNIX_TIMESTAMP()` / `unixepoch()`. Do not expect a `TIMESTAMPTZ` /
  `DATETIME` column — earlier releases mapped `.time` to those types, which
  disagreed with the bigint default and broke CREATE TABLE on Postgres.
- Time predicates take `.int` epoch values:
  `q.Where(.{client.e.timestampGTE(.{ .int = epoch })})`.

## 4. JSON field ownership

Both the Create path and the query/scan path parse JSON into a per-entity
arena (`json_arena`), released by `deinitEntity`. You never free JSON
fields manually — call `deinitEntity` once per entity. Typed JSON fields
use `field.JSON(name, T)`; untyped documents use `field.JSONValue(name)`
(`std.json.Value`).

## 5. Edges / addEdgeFields

- `edge.To(name, Target)` / `edge.From(name, Target).Ref(inverse)` — see
  `examples/start/schema.zig` for the O2M / M2M conventions.
- Cross-referenced O2M edges generate an FK column on the target table
  named `toSnakeCase(source_name) ++ "_id"` (e.g. `user_eager_id`), unless
  the target declares the matching `From` edge.
- `deinitEntity` frees eager-loaded edge arrays (and their JSON arenas)
  recursively; call it on the parent only.

## 6. Privacy

- `PrivacyContext.op` is set by the codegen layer per operation
  (create/update/delete/query).
- `OnCreate` / `OnUpdate` / `OnDelete` / `OnQuery` deny only their own
  operation; other operations pass through. Use `Policy{ .rules = &.{
  OnCreate.rules[0], OnQuery.rules[0] } }` to combine.
- `Rule.on_op` applies a decision only for a matching operation. `.allow` is
  not an allow-list: `allow` is the default decision and only `.deny`
  restricts, so an `on_op` carrying `.allow` restricts nothing. Name the
  operations you mean to deny, or deny the rest explicitly.

## 7. Queries

- `q.paged(page, size)` returns `PagedResult{ items: Managed(Entity), total }`
  — note `items` is a `Managed` list, so iterate `page.items.items` (not
  `page.items`); `All()` returns the `Managed` list directly. Both require
  `deinitEntity` per entity + `deinit()`.
- `q.WhereEntQL("has(cars)")` / `not_has(...)` / `has(cars, price > 5)`
  parse EntQL into EXISTS subqueries (schema-aware).
- `q.All()` returns `Managed(Entity)`; `deinitEntity` per item then
  `users.deinit()`.

## 7a. Comptime budget (large schemas)

- Build cost is dominated by driver-header translation, not by the comptime
  budget below — see README "Build cost, and how to cut it on a small machine"
  (`-Dsqlite=false` / `-Dpg=false` / `-Dmysql=false`, the global cache, `-j`).
- Codegen runs under `@setEvalBranchQuota(1_000_000)` in
  `src/codegen/graph.zig` and `src/codegen/predicate.zig`.
- **Measured limits** (enforced by the "Graph stress" tests in
  `graph.zig`): a single `buildGraph` compiles with 400 minimal
  (2-field) tables, 400 realistic 8-field tables with an index each,
  and 300 hub-and-spoke tables with one edge each. So a ~100–300 table
  application **fits in one graph**; splitting is unnecessary at that
  scale and costs you cross-graph edges.
- If a still-larger graph hits a quota error, raise the value in the
  relevant `src/codegen/*.zig` file rather than splitting the graph —
  the graph is meant to span all tables of an application (edges
  resolve across it).
- **Consumer note:** multi-tenant commerce ports (~100+ tables) split
  graphs against older guidance. On current zent a single graph at that
  size compiles; if you must split, keep each graph self-contained (no
  cross-graph edges) and pass the matching `infos` to every
  client/tx/helper. Tracked as **Z3** in
  [`ISSUES_FROM_ZAPI.md`](ISSUES_FROM_ZAPI.md).

## 8. Build & toolchain

- The toolchain is pinned to `0.17.0` (stable): CI installs exactly
  that release and `build.zig.zon`'s `minimum_zig_version` names it, so an older
  build fails immediately with "zig version … does not satisfy" rather than
  somewhere inside the build. A newer toolchain is accepted, but it is not what
  CI verifies — bump the pin in one commit (CI, `minimum_zig_version`, README,
  `AGENTS.md`) after a green local run.
- `zig build test` compiles without libpq/libmariadb headers; PG/MySQL
  integration tests are optional (`SKIP_PG` / `SKIP_MYSQL` to skip at
  runtime).
- Consumer projects depend via `build.zig.zon`; run
  `bash scripts/check-version.sh` after bumping the version to keep
  README/README_CN/tag in sync.

## 9. Outbox / helpers

- `zent.outbox.Outbox(infos, zent.outbox.info)` — enqueue inside a
  transaction via `tx.client` (use `zent.codegen.beginTx(infos, client)`),
  dispatch with a `zent.outbox.Publisher`.
- `examples/advanced/` demonstrates composite unique indexes, paged
  listing, sensitive-field masking (`toMaskedJson`) and the outbox
  (`zig build run-advanced`).

## 10. v0.36 API changes and required migrations

Adopting v0.36 on an existing database or codebase needs these four steps.

**Schema migration (outbox).** `OutboxMessage` gained a nullable `claimed_at`
column, written when a row is claimed. Existing deployments must run a
migration to add it; `migrateSchema` adds missing columns automatically, and
downgrading requires dropping the column by hand. Without it, claiming still
works but `requeueStale` cannot tell how long a row has been processing.

**Allocator argument (table creation).** `Client.createAllTables` and
`migrate.createAllTables`/`createTables` now take an allocator as the first
argument:

```zig
// before
try Client.createAllTables(infos, drv.asDriver());
// after
try Client.createAllTables(allocator, infos, drv.asDriver());
```

The migration module no longer reaches for `std.heap.page_allocator`
internally, so allocate/free pair on the allocator you pass.

**Migrations now lock by default.** `MigrateOptions.lock_timeout_ms` defaults
to 10 s and takes an advisory lock for the duration (`pg_advisory_lock` on
PostgreSQL, `GET_LOCK` on MySQL; SQLite relies on its single-writer
transaction). Concurrent instances therefore serialise instead of racing, and
contention returns `error.MigrationLockTimeout`. Pass `lock_timeout_ms = 0` to
restore the old unlocked behaviour, or if your database role cannot take
advisory locks — an unsupported or denied lock statement degrades to a warning
and the migration proceeds.

**Pool waiting is opt-in but changes `max_wait_ms` meaning.** It used to be
dead configuration; it is now the total budget for one `borrow`, after which
the caller parks on the pool condition instead of failing immediately. The
default is `0`, which keeps the previous non-blocking behaviour exactly, so
nothing changes until you set it — but if you were passing it expecting no
effect, you now get queueing.

Two smaller notes: `FieldInfo` gained `column_name` alongside `name` (only
relevant if you construct `TypeInfo` values yourself — `fromSchema` fills it),
and `queryTargetsByValue` accepts `.string` primary keys for UUID-keyed
entities, with `queryTargets` unchanged as the integer-only wrapper.

## 11. `queryTargets*` is now fail-closed

`queryTargets` and `queryTargetsByValue` used to apply only the target's
soft-delete scope, while the eager loader (`WithEdge`) additionally ran the
target's privacy policy and the client's interceptor chain. That made the two
bulk neighbour readers disagree on tenant isolation: the same edge read
fail-closed through `WithEdge` and fail-open through `QueryEdge`.

The scoped contract is now the default and is implemented once, in
`codegen.query.appendTargetScopePreds`, for both readers.

```zig
// before — 6 arguments, soft-delete only
try client_mod.queryTargets(infos, "User", "cars", ids, alloc, driver);
// after — 8 arguments; pass the client's own context and chain
try client_mod.queryTargets(infos, "User", "cars", ids, alloc, driver, privacy_ctx, interceptors);
```

`EntityClient.QueryEdge` needs no call-site change: it now forwards the
client's `privacy_ctx`/`interceptors`, so it scopes exactly like
`Query()...WithEdge()`. Two consequences to check on upgrade:

- An entity that carries a privacy policy makes `QueryEdge` return
  `error.PrivacyDenied` unless the client has a context. That is the intended
  fail-closed behaviour; previously the policy was silently skipped on this
  path.
- Callers that deliberately want the old soft-delete-only traversal use the
  renamed `queryTargetsUnscoped` / `queryTargetsByValueUnscoped`, which keep
  the original six-argument signature. The explicit name is the point: it is
  now visible at the call site that the ids were scoped elsewhere.

## 12. MySQL string columns are now `VARCHAR(255)`

`field.String` and `field.Enum` map to `VARCHAR(255)` on MySQL instead of
`TEXT`. PostgreSQL and SQLite are unchanged (still `TEXT`).

**Why.** MySQL refuses all three things a string column is normally asked to do
when that column is `TEXT`:

| Declaration | Emitted DDL | MySQL |
|---|---|---|
| `field.String("email").Unique()` | `` `email` TEXT NOT NULL UNIQUE `` | `ERROR 1170` — no key length |
| `field.String("status").Default("new")` | `` `status` TEXT DEFAULT 'new' `` | `ERROR 1101` — no DEFAULT on TEXT |
| an index over a `String` column | `` CREATE INDEX … (`status`) `` | `ERROR 1170` — no key length |

Each is a hard failure of table creation, so such a schema could not be built at
all. `VARCHAR(255)` has none of the restrictions. The key-length prefix
(`email(255)`) was **not** used to keep `TEXT`: for `UNIQUE` it constrains only
the first 255 characters, which is not the constraint the schema declares.

`field.Text` still maps to `TEXT` on MySQL, and keeps all three limitations —
that is the type to reach for when the content is genuinely unbounded.

**What to do.** An existing MySQL table holds `TEXT` where the schema now says
`VARCHAR(255)`. Nothing changes unbidden: `migrateSchema` without
`.allow_data_loss` performs no type change, and drift is reported rather than
applied. To converge, convert each column by hand, restating every attribute —
MySQL's `MODIFY COLUMN` replaces the whole definition, which is why
`migrateSchemaWithOptions(.{ .allow_data_loss = true })` fails closed with
`error.MySQLTypeChangeUnsafe` here:

```sql
ALTER TABLE t MODIFY col VARCHAR(255) NOT NULL DEFAULT 'new';
```

**Measure before you convert.**

```sql
SELECT MAX(CHAR_LENGTH(col)) FROM t;
```

255 is 255 *characters* under `utf8mb4`. On a strict `sql_mode` (the default in
MySQL 8) a longer value errors; on a permissive one it is silently truncated. If
the column really does hold longer values, keep it `TEXT` by declaring the field
`field.Text` and accept that MySQL will not let it be unique, indexed without a
key length, or defaulted.

After converting, `sql_schema.checkSchema` stops reporting those columns. It
compares normalized types (`varchar(255)` → `varchar`, `text` → `text`), so
before the conversion each such column appears as `type_mismatch`.

## 13. v0.83 → v0.91: the changes a consumer has to act on

Ten releases' worth of behaviour, DDL and ownership changes accumulated while
`CHANGELOG.md` recorded them one release at a time. This section is the
consumer-side view: **what can break when you upgrade, what needs a database
rebuild, and what is worth adopting.** Anything not listed here was additive or
purely internal.

### 13.1 Toolchain

The pin moved from a `0.17.0-dev` snapshot to **Zig 0.17.0 stable** (v0.82.0)
and `build.zig.zon`'s `minimum_zig_version` is `"0.17.0"`. A pre-release sorts
below the release, so **an older dev snapshot is now refused** with
"zig version … does not satisfy" — move the toolchain at the same time as the
dependency. `std.builtin.*` spellings throughout the library were migrated to
`std.lang.*` (v0.83.1); that is invisible to consumers.

### 13.2 Behaviour changes that can break a running consumer

| Change | What to do |
|---|---|
| **MySQL: a `Save` on a table without `AUTO_INCREMENT` now fails** (v0.84.0). `mysql_insert_id()` answers `0` when no auto-increment value was set; the driver now maps that to "no id", so the row's id is no longer silently written as `0` — the call answers `error.MissingLastInsertId` instead. `SaveIgnore` that did not insert keeps the cross-dialect `id = 0` convention, and `SaveOrUpdate` is unaffected (ODKU's update branch reports the updated row's id) | If you relied on the old behaviour, your table is missing its auto-increment (or the schema declares a key your DDL never created). Fix the schema; if the row genuinely has no generated key, read it back explicitly |
| **EntQL addresses field names first** (v0.84.0). A `WhereEntQL` ident that matches a field's API name is rewritten to that field's physical column (`StorageKey`-aware, and inside `has(...)` against the edge target); a physical column spelling still works; neither answers `error.UnknownField`. If a field's API name equals another field's column name, the **field name wins** | Audit `WhereEntQL` strings that name a `StorageKey` column directly — they still work, but one that happens to spell a *field* name now filters that field |
| **MySQL: a `SELECT` through the prepared `exec` path reports its row count** (v0.86.0). The prepared path used to answer `rows_affected_known = false` where the unprepared one answered a count (a divergence documented since v0.63.0) | Nothing, unless you branched on `rows_affected_known` for a SELECT sent to `exec` — prefer `query()` for reads |
| **`ShardSet` borrows its `ShardRouter`** (v0.85.0). `ShardSet.deinit` no longer releases the router, and the old module-header example double-freed. A router **copied by value** into the set must not be mutated afterwards (the tenant map is shared; growing through one copy strands the other) | Callers must `deinit` the router they created. In-repo `helpers.ShardedEnv` already does |
| **OOM propagates on four assembly paths** (v0.89.0): `scope.forTable`, `client.queryTargetsImpl`, the eager `loadEdgePath` and `BulkDeleteBuilder.init`. They used to build through `Builder.init`, which swallows a failed preallocation and degrades silently | Nothing, unless a caller assumed those calls cannot return `error.OutOfMemory` (it was already in their error sets) |
| **`error.JoinWithGroupBy`** (v0.88.0) — raised by whichever of `joinEdge`/`GroupBy` comes second; **`error.MissingLastInsertId`** is now reachable (v0.84.0) | A `switch` over `QueryError`/`SaveError` needs its `else =>` arm, as always |
| **`sql.MultiInsert`'s length assertion was removed** (v0.90.0) — it asserted the flat buffer's total size, the one thing a row-shape mistake leaves intact | Nothing; the row-shape check (`error.InconsistentRowFields`) is unchanged |

### 13.3 DDL changes that need a rebuild on an existing database

These change what the migration *derives*, so a table created by an older
release stays as it was — `migrateSchema` will not repair it for you (the one
exception is opt-in, below).

| Change | Symptom on an existing database | What to do |
|---|---|---|
| **Z40: an edge FK's referenced column** (v0.84.0). `REFERENCES <table> (<col>)` now takes the target's `.pk` override / `StorageKey`-renamed column instead of a literal `"id"` | The child's INSERT fails with SQLite's `foreign key mismatch` (or the FK dangles on PG/MySQL) although reads work | Drop and recreate the constraint — SQLite: rebuild the table. `PRAGMA foreign_key_list(<child>)` shows what it points at today. The Z40 write-up in `ISSUES_FROM_ZAPI.md` has a discriminator query |
| **Implicit-M2M junctions** (v0.87.0): the junction's table name and both columns now use the ends' declared `table_name`/`.pk` | An existing junction under the old short name is no longer the one the relation query reads (`no such table` on the first m2m write) | Rename/rebuild the junction table, or keep the old name by declaring the ends without overrides |
| **A `Through` schema's declared `table_name`** (v0.88.0) now names the junction | Same shape: the through table exists under the declared name, the relation looks for the short one | Rebuild or rename |
| **MySQL `bool`/`float` columns** (v0.85.0): the false `type_mismatch` is gone (`BOOLEAN` ≡ `tinyint`, `REAL` ≡ `double`) | A migration that used to **fail** while planning (`MySQLTypeChangeUnsafe`, including dry runs) now succeeds and reports no drift | Nothing — this one only removes a false alarm |
| **MariaDB: `TEXT`/`BLOB` may carry a `DEFAULT`** (v0.90.0). The migration detects MariaDB and keeps MySQL's errno-1101 refusal for MySQL only | On MariaDB, a schema with a text default used to fail table creation; now the DDL is emitted | Nothing; MySQL behaviour is unchanged |

### 13.4 Worth adopting

| API | Since | Why |
|---|---|---|
| `field.String("x").VarChar(n)` | v0.86.0 | Expresses the MySQL `VARCHAR(255)` cap (DDL `VARCHAR(n)` on MySQL, `TEXT` elsewhere) **and** enforces it on the write path on every dialect (`error.ValidationFailed`) |
| `client.<entity>.AllOwned(allocator)` | v0.86.0 | The one-call page release for a consumer holding a client without a live builder (same `OwnedRows` as the builder's `AllOwned`) |
| `QueryBuilder.joinEdge(edge, .inner\|.left, .{ where, select, alias })` | v0.88.0 | A controlled single-round-trip JOIN for m2o lookups, with the target's full read contract and its columns projected into the eager edge field. Requires the entity to *declare* the edge — see §13.5 |
| `InsertBuilder`/`UpdateBuilder`/`DeleteBuilder`/`BulkUpdateBuilder`'s `initCapacity` | v0.90.0 | Fallible twins of the constructors whose `init` swallows an allocation failure |
| `SQLiteDriver.openWithOptions(…, .{ .strict_numeric_text = true })` | v0.90.0 | SQLite parses text numerics instead of coercing, so an integer field over a `Decimal`(TEXT) column fails loudly as it already did on PG/MySQL. Off by default |
| `MigrateOptions.add_missing_foreign_keys` | v0.91.0 | Adds declared-but-absent foreign keys to **existing** tables (MySQL one statement; PostgreSQL `NOT VALID` + `VALIDATE`). Off by default; a violating row fails the migration loudly. SQLite is a documented no-op (it has no `ADD CONSTRAINT`) |

### 13.5 If you are chasing raw SQL: declare the edges first

A measured example, from a consumer with ~180 schemas and ~543 raw-SQL call
sites (153 of them JOIN-shaped): **62% of its JOINs are single-hop m2o lookups
and another 15% are several independent m2o lookups in one statement** — both
of which `joinEdge` already expresses, including several `joinEdge` calls on
one query. What blocked them was not the library: **their schemas declared no
edges at all**, and every edge-based API (`joinEdge`, `WithEdge`,
`WithEdgeOptions`) needs one. Declaring the m2o edges is the highest-yield step
for that codebase, ahead of any new feature.

Groups worth *not* chasing into the builder: report aggregation (`JOIN` +
`GROUP BY` + `SUM`/`COUNT` over joined columns), self-joins with several
aliases, and `UPDATE … FROM`. Their shapes are unbounded, the three dialects
disagree, and they are precisely what `joinEdge` v1 refuses (`JoinWithGroupBy`)
rather than approximates — keep them raw and scope them with `zent.scope`.
