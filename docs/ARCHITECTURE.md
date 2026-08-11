# zent architecture

zent is a comptime-only entity framework: schemas are Zig types, and every
client/query/mutation surface is generated at compile time — no external
codegen step. This document maps the layers and the memory contract.

## Layer map

```
schema (src/core)
   │  comptime introspection
   ▼
graph (src/codegen/graph.zig)  ── TypeInfo / EdgeInfo (compile-time IR)
   │
   ├── entity.zig     Entity type + deinitEntity (caller-owned rows)
   ├── client.zig     EntityClient / TxClient / Client + query entry points
   ├── create.zig     CreateBuilder / BulkInsertBuilder (Save / SaveOrUpdate)
   ├── query.zig      QueryBuilder: Where/OrderBy/Limit/paged/CountBy…
   ├── update_delete.zig  Update/Delete/BulkUpdate/BulkDelete builders
   ├── predicate.zig  typed per-field predicates (Eq/Contains/ContainsEscaped…)
   └── meta.zig       Meta helpers
   │
   ▼
sql (src/sql)         Dialect-aware SQL builder + driver interface
   ├── builder.zig    Insert/Select/Update/Delete/MultiInsert/InsertOrReplace
   ├── dialect.zig    sqlite3 / postgres / mysql placeholder+quoting
   ├── driver.zig     Driver VTable (exec/query/beginTx/…)
   ├── sqlite.zig / postgres.zig / mysql.zig
   ├── scan.zig       row → struct (column-name mapping, arena or owned)
   ├── schema/        migrate (create tables/views, Flyway-style)
   ├── pool.zig       ConnPool
   └── logger/cache/explain

cross-cutting:
   graph/    edge traversal steps (neighbors/step)
   entql/    EntQL expression parser → SQL
   privacy/  policy filter/deny rules
   runtime/  hook chain, errors, privacy context
```

## Compile-time flow

1. User defines a schema: `Schema("User", .{ .fields = …, .edges = … })`
   (`src/core/`). Field/edge/index/mixin descriptors carry Zig types,
   validators, SQL types and enum values.
2. `fromSchema` (`src/codegen/graph.zig`) lowers the schema into a comptime
   `TypeInfo`/`EdgeInfo` IR.
3. `codegen/client.zig` (`Client(infos)`, `EntityClient`) instantiates
   fluent, fully-typed builders bound to that IR (`makeClient`).
4. SQL is emitted per-dialect at runtime through `sql_driver.Driver`
   (placeholder `?` vs `$n`, quoting, `RETURNING` vs `last_insert_id`).

## Memory ownership contract

- **Rows** — `q.All()` returns `std.array_list.Managed(Entity)`; each
  item's strings are owned by the caller: `deinitEntity(infos, info,
  &entity, alloc)` per item, then `users.deinit()`.
- **QueryResult / OwnedQuery** — `sql.QueryResult` (`{ sql, args }`)
  borrows from the builder; `OwnedQuery` (from `Builder.takeQuery()`)
  transfers ownership and MUST be `deinit`'d.
- **OwnedQuery** — `Builder.takeQuery()` results MUST be `deinit`'d.
- **Tx** — `driver.Tx` MUST be `deinit`'d exactly once regardless of
  `commit`/`rollback`.
- **Bulk builders** — `BulkInsertBuilder.Save/SaveOrUpdate` return
  `Managed(i64)` ids; caller deinits the collection.
- Tests use `std.testing.allocator` so leaks fail `zig build test`.

## Driver abstraction

`src/sql/dialect.zig` captures the three dialects; `driver.zig` defines the
`Driver` vtable. Backends differ in: placeholders, identifier quoting,
`RETURNING` support (SQLite/PostgreSQL yes, MySQL no → `last_insert_id`
chaining), and upsert syntax (`ON CONFLICT DO UPDATE` / `ON DUPLICATE KEY
UPDATE` / `INSERT OR REPLACE`). The library never forces C linkage — a
consumer links its own sqlite/libpq/mariadb (see README "Consumer wiring").

## Extension points

- **New field types**: extend `src/core/field.zig` descriptors + the scan
  mapping in `src/codegen/create.zig` (`valueToType`) and the row scanners
  in `src/sql/scan.zig` (`scanRow` / `scanRowNamed` / `scanRowOffset` /
  `scanRowNoAlloc`).
- **New predicates**: add to `src/codegen/predicate.zig` + the generated
  `makePredicates`; keep the SQL renderer in `src/sql/builder.zig`.
- **New dialect**: implement the driver vtable + dialect quirks
  (`dialect.zig`, a `src/sql/<name>.zig`), then wire discovery in
  `build.zig` (see PG/MySQL helpers).
- **Hooks / privacy**: `src/runtime/hook.zig` (before/after chains) and
  `src/privacy/policy.zig` (deny/filter/on_op) apply across create/update/
  delete/query paths. The codegen layer sets `PrivacyContext.op` per
  operation, so `OnCreate`/`OnUpdate`/`OnDelete`/`OnQuery` deny only their
  own operation (other ops pass through).

## Docs

- `BEST_PRACTICES.md` — **how to write persistence code**: API decision table,
  memory contract, raw-driver Postgres dialect rules, transactions,
  anti-patterns, testing, and the promotion checklist for moving patterns
  into zent.
- `RELEASING.md` — release flow + consumer hash-sync
- `docs/superpowers/specs/` — design specs
- `CHANGELOG.md` — release history
