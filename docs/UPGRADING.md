# Upgrading zent

This guide covers the API changes you are likely to hit when upgrading a
consumer from older releases (v0.12 era) to v0.28. It focuses on source
compatibility; the full change history lives in `CHANGELOG.md`.

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
- `Rule.on_op` applies a decision only for a matching operation.

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

- CI pins zig `0.17.0-dev.813+2153f8143`; the library also builds on newer
  dev builds (quota and std API probes keep both working).
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
