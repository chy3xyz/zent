# AGENTS.md — zent

## Project

- Zig port of [ent](https://entgo.io/) (Go ORM). Targets Zig 0.17-dev.
- Remote: `https://github.com/chy3xyz/zent.git`
- Default branch: `main`
- Build is driven by `build.zig`; CI lives at `.github/workflows/ci.yml`.
- Version: **v0.60.0** (package version synced to tags — see `docs/RELEASING.md`).

## Commands

- `zig build` — build the library and example executables
- `zig build test` — run unit tests (378 tests, 0 leaks; leaks fail the run; count grows when libpq/libmariadb headers are present)
- `zig build test-integration` — run integration tests (SQLite always; PostgreSQL/MySQL too when their headers were found, otherwise those files are not compiled in. `SKIP_PG`/`SKIP_MYSQL` skip them at runtime; the 3 MySQL TLS cases need `MYSQL_SSL_CA`/`MYSQL_SSL_CERT`/`MYSQL_SSL_KEY` or they skip)
- `zig build benchmark` — run performance benchmarks (builder/scan/pool/cache/eager/upsert)
- `zig build run-start` — run the `examples/start` smoke test
- `zig build run-complex` — run the `examples/complex` e-commerce demo
- `zig build run-pool` — run the `examples/pool` connection-pool demo
- `zig build run-interceptor` — run the `examples/interceptor` multi-tenant demo
- `zig fmt --check src examples tests build.zig` — formatting
- `bash scripts/check-version.sh` — release-consistency gate (CI)
- `bash scripts/check-deadcode.sh` — dead-code baseline gate (CI; needs
  `ZMODU=<path>` pointing at the zmodu CLI built from zigmodu)
- `bash scripts/release.sh <x.y.z> [--push]` — one-shot release flow

## CI gates

fmt → build → unit tests → version consistency → integration tests
(SQLite/PostgreSQL/MySQL) + a standalone dead-code baseline job.

### Two servers, one file: MySQL tests run on MariaDB in CI

**CI's `mysql` service is MariaDB 10.11; a development machine usually has
MySQL 8/9.** They share the wire protocol and the errno numbering, so the same
driver passes on both, but they are *not* behaviour-compatible — and a test that
asserts one server's behaviour passes locally and fails in CI. This has shipped
a red tag **three times**:

| Pinned MySQL, broke on MariaDB | What actually differs |
|---|---|
| `column_default == "kept"` | MySQL 8+ strips the quoting; MariaDB returns the literal expression text (`'kept'`) |
| `CREATE INDEX … ((lower(c)))` | MySQL 8.0.13+ only; MariaDB rejects the syntax (errno 1064) |
| `BEGIN` through `mysql_stmt_prepare` | MySQL errno 1295; MariaDB prepares it fine |

So: for every new MySQL assertion, ask **"does this hold on MariaDB too?"**
before pushing. When the two genuinely differ, branch on
`isMariaDB(&drv)` (in `tests/integration/mysql.zig`, `SELECT VERSION()`) and
keep a meaningful assertion on *both* branches — do not weaken it into
something both happen to satisfy, and do not delete the case. If a case cannot
be set up at all on one server, create it only there and say why in a comment.

`baseline` counts move with this: unit 378, integration 197 passed + 3 skipped
(the 3 are MySQL TLS cases needing `MYSQL_SSL_CA`/`CERT`/`KEY`).

## Repository conventions

- **Commit and push proactively** after meaningful code changes.
- Match the surrounding code's style and naming. Run `zig fmt` before committing.
- Public API is fluent/chainable like ent (e.g. `client.user.Create()` → `setFieldValue("name", "foo")` → `Save()`; builder methods return `!*Self`, so chain each step with `try`).
- Use `comptime` for schema introspection; no external code generation.
- **An `anytype` parameter is an API contract, and its accepted shapes are part
  of it.** State them in the doc comment and pin every shape in a test, because
  a body that happens to work for value/pointer/tuple/slice variants is easy to
  narrow by accident and only a test notices. v0.40.0 did exactly that to
  `crud_helpers.deinitRows` and broke every consumer passing `&rows`. The
  worked examples: `sql.appendPredicates` (seven shapes, one implementation,
  one table, one test), `codegen.entity.deinitEntityList`'s callers, and
  `setFieldValue`'s value-shape table.
- Drivers: SQLite is first-class, PostgreSQL and MySQL are present but less
  exercised; the library never forces C linkage — consumers link their own
  sqlite/pg/mysql (see README "Consumer wiring").

## Docs map

- `docs/RELEASING.md` — release flow + consumer hash-sync
- `docs/ARCHITECTURE.md` — layer map + memory ownership contract
- `docs/superpowers/specs/` — design specs (benchmark, …)
- `CHANGELOG.md` — Keep a Changelog (release discipline)

## Zig 0.17 gotchas (learned — avoid regressions)

| Pattern | Do this |
|---|---|
| `std.ArrayList(T).init(alloc)` / `.append(x)` | `.empty` + explicit allocator arg |
| `std.mem.trimRight/trimLeft` | `std.mem.trimEnd/trimStart` |
| `@typeInfo(T).fields` | `.field_names` / `.field_types` / `.field_attrs` + `attrs.defaultValue(ft)` |
| `std.meta.hasDecl` | builtin `@hasDecl` |
| `_ = <error union>` | `try` / `catch` (bare statement OK, `_ =` is not) |
| unused fn params | `_`-prefix them (0.17 errors otherwise) |
| query rows | `All()` returns `std.array_list.Managed(Entity)`: `deinitEntity` per item, then `users.deinit()` (never pair a per-item free with a slice free) |

## Memory ownership

Entities and queries are explicitly owned by the caller. See the contract:

- `q.All()` etc. returns `std.array_list.Managed(Entity)`. Free a page with `q.deinitRows(&rows)` or `client.<entity>.deinitRows(&rows)` (page + list, one call, list comes back empty so a second call is a no-op), a single with `client.<entity>.deinitRow(&e)`, and a `QueryEdge` page with `client.<source>.deinitEdgeRows("edge", &rows)`. The explicit `deinitEntity(infos, info, &entity, alloc)` per item + `users.deinit()` remains valid for generic code that already holds the graph; all of the shortcuts funnel into `codegen.entity.deinitEntityList`.
- `OwnedQuery` (from `Builder.takeQuery` / `Selector.takeQuery`) MUST be `deinit`'d.
- **Arena pages are one-way.** `AllIn` / `FirstIn` / `SaveIn` / `queryRowsIn` take `*std.heap.ArenaAllocator` and return a plain slice owned by that arena. The release is `arena.deinit()` and **nothing else** — never call `deinitEntity` / `deinitRow` / `deinitRows` / `freeOwnedStrings` on such a page (double free). Do not mix the two shapes on one page.
- `driver.Tx` MUST be `deinit`'d exactly once, regardless of `commit`/`rollback`.
- `sql.QueryResult` (`{ sql, args }`) borrows from the builder; `OwnedQuery` (from `Builder.takeQuery` / `Selector.takeQuery`) transfers ownership and MUST be `deinit`'d.
- The root `Client` lazily heap-allocates its `InterceptorChain` on first `client_mod.UseInterceptor(infos, &client, i)`; release it with `client_mod.DeinitClient(infos, &client)` **once, on the value that registered**. Value copies (helpers, `withContext`, tx clients) borrow the same chain and must not be deinit'd; `withInterceptors(chain)` borrows a caller-owned chain, which `DeinitClient` leaves alone. `StoreEnv`/`PooledEnv`/`ShardedEnv` release the clients they created on `deinit` (each shard client individually). Register before `beginTx` — the tx client borrows the same chain.
- Use `std.testing.allocator` in tests so `zig build test` reports leaks with non-zero exit.

## Security invariants (do not regress)

- **Interceptor `whereEq` dedupes on the (column, value) pair, never the
  column.** Column-only dedupe lets a caller predicate suppress the
  interceptor's own value = a tenant bypass. All eight `add_eq_fn` sinks go
  through `sql.appendEqUnlessPresent`; the two create-path sinks are a
  *filler* (an explicitly set field wins), so a write constraint the caller
  must not override belongs in a privacy policy, not an interceptor.
- **Both bulk neighbour readers share the target read contract.** `WithEdge`
  and `client.queryTargets*`/`QueryEdge` all funnel through
  `codegen.query.appendTargetScopePreds` (soft-delete → privacy →
  interceptors). Never re-implement that chain at a second call site — the
  previous hand-rolled copy is what left `QueryEdge` fail-open while eager
  loading was fail-closed.
- **Neighbour queries qualify injected predicates with the target table.**
  m2o joins the source and m2m joins the junction, so a bare column is
  ambiguous whenever both sides own it. Qualification lives in one helper
  (`sql.appendQualifiedPred`) shared with `zent.scope`; never re-inline it.
- **Raw SQL is unscoped unless it goes through `zent.scope`.** The builders are
  where privacy and interceptors run, so a hand-written statement has to ask
  for the fragment (`forClient` + `withClause`). Any new raw-SQL helper must
  route through `appendTargetScopePreds`, not re-implement the chain — or, if it
  cannot (a statement may join several tables), say loudly that it is a
  pass-through and document the `zent.scope` composition. `crud_helpers.queryRows`
  is that case; `BEST_PRACTICES` §5 has the full path table.
- **Positional row scans are column-count guarded.** `scanRow*` rejects a
  result set narrower than the struct with `error.ColumnCountMismatch`; the
  drivers do not all bounds-check. Keep that check when adding a scanner.
- **MySQL `String`/`Enum` are `VARCHAR(255)`, not `TEXT`.** MySQL will not make
  a `TEXT` column `UNIQUE` (errno 1170), give it a `DEFAULT` (errno 1101), or
  index it without a key length — so a schema declaring
  `field.String(…).Unique()`, `.Default(…)` or an index over such a field fails
  `CREATE TABLE` outright. Do not "simplify" the mapping back to `TEXT` for
  parity with PostgreSQL/SQLite, and do not switch to a key-length prefix
  (`col(255)`): that makes `UNIQUE` constrain only the first 255 characters.
  `field.Text` keeps `TEXT` deliberately — it is the unbounded type, and MySQL
  restrictions on it are reported, not worked around.
- **The DDL guards for those restrictions must stay generation-time and
  fail-closed.** `createTableSQLAlloc` and `createIndexSQLForTableAlloc` call
  `findMySqlTextRestriction` (pure, no allocation, MySQL-only) before emitting
  anything, and return `MySQLTextColumnCannotHaveDefault` /
  `MySQLTextColumnCannotBeIndexed`. Never let this degrade into a raw server
  error, and never "fix" it with a key-length prefix.
- **Index drift is reported only when it can be read reliably.** A false
  `index_columns` drift blocks a deploy; a missed one is a warning nobody reads,
  so the comparison errs towards silence: expression keys, partial indexes,
  non-btree access methods, invalid indexes and `INCLUDE` columns all set
  `columns_comparable = false` and are skipped. `breaksReads()` is **false** for
  `index_columns`, so `read_breaking_only` never fails on it — keep it that way.
  On PostgreSQL read the key columns from `pg_index` + `pg_attribute`, never by
  parsing `indexdef` text.
- **`checkStatement` must never execute.** It prepares and discards, on all
  three dialects (`sqlite3_prepare_v2`, `PQprepare`, `mysql_stmt_prepare`) — no
  `step`/`execute`/`Bind+Execute`, no "run then roll back". A driver that cannot
  prepare answers `not_checkable` rather than erroring, so a bulk audit does not
  stop halfway; that is a normal result, not a failure.
- **SQLite binding is fail-loud.** `bindArgs` compares the argument list with
  `sqlite3_bind_parameter_count` and checks every `sqlite3_bind_*` return code.
  Do not go back to ignoring the return codes: a missing argument then binds as
  NULL and the statement **answers a different question** instead of erroring
  (an empty page where the caller expected rows). Unifying PostgreSQL onto
  `error.ParamCountMismatch` is deliberately not done — it surfaces its own bind
  error as `DriverFailed`; that is recorded, not papered over.
- **Every MySQL BLOB/TEXT guard covers the ALTER path too.** `CREATE TABLE`,
  `CREATE INDEX` **and** `ALTER TABLE … ADD COLUMN` all go through
  `findMySqlTextRestriction`; the ALTER path is the one reached when the table
  already exists, so it is where a later `field.Text(…).Default(…)` lands. The
  check is handed only what the statement emits (`unique`/`primary_key` cleared
  for ALTER), so it never refuses SQL the server accepts.
- **Index uniqueness and index columns are separate drift kinds.**
  `index_uniqueness` comes from a plain boolean every catalog has and is always
  reported; `index_columns` is reported only when the key list is reliably
  readable. Do not fold one into the other — the result would either silence
  uniqueness drift for expression/prefix/partial indexes or emit a key-list
  verdict that was never established. `breaksReads()` is `false` for both.
- **`unique_constraint` skips a table whose *unique* index is unreadable.**
  `lower(email)` and `email(10)` both do force `email` to be unique, so a table
  carrying such a unique index has no decidable answer and must stay silent — a
  false drift blocks a deploy. A **non-unique** unreadable index suppresses
  nothing (it cannot be the constraint either way), so keep the rule keyed on
  `unique and !columns_comparable`, not on `!columns_comparable`.
- **Foreign keys are compared by shape, never by name.** PostgreSQL and MySQL
  generate a constraint name and SQLite keeps none, so a name comparison would
  report every FK in every database. `breaksReads()` is `false`: a missing write
  constraint does not break a read. A constraint the database has and the schema
  does not is deliberately **not** reported.

## Layout

- `src/core/` — comptime schema definition API
- `src/codegen/` — comptime client/query/mutation generation
- `src/sql/` — SQL builder, driver interface, SQLite/PostgreSQL/MySQL drivers
  (`builder/dialect/driver/scan/sqlite/postgres/mysql/schema`, plus
  `pool.zig`, `cache.zig`, `explain.zig`, `logger.zig`, `value.zig`)
- `src/runtime/` — hook, interceptor (runtime query rewriting), and error helpers
- `src/privacy/` — privacy policy framework
- `src/graph/` — graph traversal helpers
- `src/entql/` — EntQL expression parser
- `src/crud.zig` / `src/outbox.zig` / `src/shard.zig` / `src/helpers.zig` — higher-level services
- `examples/start/` — schema introspection + CRUD smoke test
- `examples/complex/` — e-commerce demo with advanced SQL operations
- `examples/pool/` — connection-pool usage demo
- `examples/migrate/` — migration-file runner demo
- `examples/interceptor/` — multi-tenant query-rewriting demo (`UseInterceptor`)
- `tests/integration/` — end-to-end tests
