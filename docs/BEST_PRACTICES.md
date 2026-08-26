# zent best practices

Companion to `ARCHITECTURE.md`. This is the "how to write persistence code
with zent" guide — decision tables, memory contracts, and the pitfalls that
surface in real projects. Codified from the zmshop migration (42 modules,
700+ call sites converted sqlx → zent).

## 1. Choosing the right API

Pick the tool by the shape of the query — do **not** reach for the raw driver
when a typed builder exists, and do **not** fight a builder when the SQL is
exotic.

| Need | Use | Example |
|------|-----|---------|
| One row by predicates | `crud_helpers.first` | `first(client.order, .{preds.order_idEQ(...)})` |
| List by predicates | `crud_helpers.all` | `all(client.tag, .{preds.is_deleteEQ(...)})` |
| Row count | `crud_helpers.count` | `count(client.user, .{preds.app_idEQ(...)})` |
| Insert from a struct | `crud_helpers.create` | `create(client.coupon, .{ .name = n })` |
| Partial update | `crud_helpers.update` | `update(client.coupon, .{ .status = 20 }, .{preds})` |
| Delete / soft-delete | `crud_helpers.delete` | `delete(client.ad, .{preds.ad_idEQ(...)})` |
| Filter + sort + limit | `client.X.Query()` | see §3 |
| Aggregate (COUNT/SUM) | `q.Count()` / `q.Sum("col")` | §4 |
| JOIN / GROUP BY / DISTINCT / dynamic SET | `driver.query/exec` raw | §5 |
| Transaction | `beginTx()` (codegen) | §6 |

### `crud_helpers` vs `CrudService`

zent ships two "CRUD sugar" layers — they do **not** overlap; pick by whether
you need side effects:

| | `crud_helpers` (`src/crud_helpers.zig`) | `CrudService` (`src/crud.zig`) |
|---|---|---|
| Shape | Stateless free functions | Stateful `CrudService(infos, info, tenant_col)` |
| Derives from | the typed accessor (`client.order`) | `(infos, info)` + an explicit `tenant_col` |
| Tenant isolation | opt-in via `scoped`/`scopedBy` | enforced on every op (bound at construction) |
| Events | none | publishes `CrudEvent{created,updated,deleted}` to a listener (the after-hook surface) |
| Use when | plain CRUD, or when you already filter manually | you need an audit trail / outbox trigger / a uniform tenant boundary |

Rule of thumb: default to `crud_helpers` for terse reads/writes; reach for
`CrudService` when several entities share the same tenant column and you want
created/updated/deleted events emitted consistently (e.g. to feed the outbox).

**Rule of thumb**: typed builders cover single-table + aggregates. Anything
that references two tables, computes a `CASE`, or needs a correlated subquery
goes to the raw driver. Don't force `Query()` to express a JOIN you could
write in one raw line.

## 2. Memory contract (the one thing to get right)

zent results are **owned**; the caller frees exactly once. Three ownership
shapes:

| Result | Owner | Free with |
|--------|-------|-----------|
| `first` → `?Entity` | caller | `deinitEntity(infos, info, &e, alloc)` |
| `create` → `Entity` | caller | `deinitEntity(infos, info, &created, alloc)` |
| `q.All()` → `Managed(Entity)` | caller | `crud_helpers.deinitRows(infos, info, rows, alloc)` |
| raw `driver.query` → `Rows` | caller | `rows.deinit()` (iterator) |
| `crud_helpers.Rows(T)` | caller | `rows.deinit()` (frees strings + slice) |

**Rules that prevent the classic bugs:**

1. **`var`, never `const`, for `first` results.** The entity is captured by
   mutable pointer so `deinitEntity` can free it:
   ```zig
   var maybe = try first(client.product, .{preds.product_idEQ(.{ .int = id })});
   if (maybe) |*e| { defer deinitEntity(infos, PRODUCT_INFO, e, alloc); ... }
   ```
   `const maybe` makes `|*e|` a `*const` → `deinitEntity` comptime-rejects it.

2. **`create` returns a value; free with `&created`** (mutable pointer):
   ```zig
   var created = try create(client.order_address, .{ .user_id = u, ... });
   defer deinitEntity(infos, ORDER_ADDRESS_INFO, &created, alloc);
   ```

3. **Never free a string literal.** Owned-slice fields must be `allocator.dupe`'d
   from borrowed row text. `catch ""` in a mapper returns a literal that
   `Rows(T).deinit()` will try to `free` → crash. Return `!T` from mappers and
   `try a.dupe(...)`.

4. **`Managed.deinit()` frees the backing, not the strings.** If you collect
   rows that own duped strings, an error path must free both:
   ```zig
   var list = std.array_list.Managed(T).init(alloc);
   errdefer { freeStrings(T, list.items, alloc); list.deinit(); }  // crud_helpers.queryRows does this
   ```

5. **HTTP handlers: prefer the request arena over the client allocator.**
   Two helpers remove the wrong-allocator footgun (Z8):
   ```zig
   // (a) bind the allocator to the entity once:
   var m = zent.codegen.managedEntity(infos, USER_INFO, user, client_alloc);
   defer m.deinit();                       // always frees with client_alloc
   use(m.get().name);

   // (b) or deep-copy everything into the request arena and never deinit:
   const copy = try zent.codegen.dupeEntityTo(infos, USER_INFO, &user, req_arena);
   // copy borrows from req_arena — do NOT call deinitEntity on it.
   ```
   `dupeEntityTo` copies strings, typed JSON structs and up to two levels of
   eager edges. Untyped `std.json.Value` fields are copied shallowly (their
   payloads stay in the source's `json_arena`) — dupe those by hand if the
   source must die first.

## 3. Typed query builder

```zig
var q = client.order.Query();
defer q.deinit();
_ = try q.Where(.{
    client.order.predicates.app_idEQ(.{ .int = app_id }),
    client.order.predicates.pay_statusEQ(.{ .int = 20 }),
});
_ = try q.OrderBy(&.{zent.sql.Order{ .column = .{ .name = "create_time", .desc = true } }});
_ = q.Limit(page_size);
_ = q.Offset(offset);
const rows = try q.All();
defer crud_helpers.deinitRows(ORDER_INFO_accessor_infos, ORDER_INFO, rows, alloc);
for (rows.items) |*e| { /* dupe strings with alloc */ }
```

**Predicates go in a tuple `.{ ... }`**, not `&.{ ... }`. Both forms are
accepted by `Where` on query, update, and delete builders; the tuple form is
preferred for consistency. The builders normalize pointer-to-tuple,
pointer-to-predicate, arrays, and slices at comptime, so pick one style and
stick with it across the codebase.

**`Limit`/`Offset` return `*Self`, not an error union** — don't `try` them.

## 4. Aggregates

```zig
// COUNT
var q = client.user.Query();
defer q.deinit();
_ = try q.Where(.{client.user.predicates.app_idEQ(.{ .int = app_id })});
const total = try q.Count();

// SUM — returns f64; PG SUM over zero rows surfaces as error.TypeMismatch
const amount = q.Sum("pay_price") catch |err| switch (err) {
    error.NotFound, error.TypeMismatch => 0,
    else => return err,
};
```

`COUNT(DISTINCT ...)` has no builder form — use the raw driver (§5).

## 5. Raw driver (JOIN / GROUP BY / exotic SQL)

```zig
var rows = try client.driver.query(
    "SELECT o.order_id, o.order_no, u.nick_name, COALESCE(s.stock_num, 0) " ++
        "FROM zigshop_order o JOIN zigshop_user u ON o.user_id = u.user_id " ++
        "LEFT JOIN zigshop_product_sku s ON o.product_id = s.product_id " ++
        "WHERE o.app_id = $1 AND o.is_delete = 0 ORDER BY o.create_time DESC LIMIT $2",
    &[_]zent.sql.Value{ .{ .int = app_id }, .{ .int = limit } },
);
defer rows.deinit();
while (rows.next()) |row| {
    const id: i64 = row.getInt(0) orelse 0;
    const f: f64 = row.getFloat(2) orelse 0;
    const s: []const u8 = row.getText(1) orelse ""; // borrowed — dupe if kept
    _ = try alloc.dupe(u8, s);
}
```

**Postgres dialect rules:**
- Placeholders are `$1, $2, ...` — never `?` (MySQL/SQLite style).
- `?` placeholders inside dynamic clauses (built with `where_parts`) must be
  renumbered as the arg list grows. Compute the next index from
  `args.len + 1`.
- `key`, `order`, `values`, `user` are reserved words — quote as `"key"`.
- `ON DUPLICATE KEY UPDATE` → `ON CONFLICT (cols) DO UPDATE SET
  x = EXCLUDED.x` — requires a UNIQUE constraint on `(cols)`.
- `DATE()`/`CURDATE()`/`FROM_UNIXTIME()`/`DATE_FORMAT()` →
  `to_timestamp(x)`, `to_timestamp(x)::date`, `to_char(to_timestamp(x),'YYYY-MM')`,
  `EXTRACT(EPOCH FROM date_trunc('day', now()))::bigint`.
- **Qualify `is_delete` (and any same-named column) when a JOIN is present**:
  `p.is_delete = 0`, or Postgres errors "column reference is ambiguous".
- `LIMIT ? OFFSET ?` → `LIMIT $N OFFSET $N+1` with correct numbering.

**Collect rows generically** with `crud_helpers.queryRows(T, driver, sql, args,
alloc, mapRow)` — it returns an owned `Rows(T)` that frees strings + slice in
one `deinit()`.

## 5a. Upserts (INSERT ... ON CONFLICT / ODKU)

zent supports three upsert modes on `CreateBuilder`:

| Mode | MySQL | PostgreSQL | SQLite |
|------|-------|------------|--------|
| `Save()` | `INSERT INTO` | `INSERT INTO ... RETURNING` | `INSERT INTO ... RETURNING` |
| `SaveOrUpdate()` | `INSERT ... ON DUPLICATE KEY UPDATE` | `INSERT ... ON CONFLICT (pk) DO UPDATE SET ...` | `INSERT OR REPLACE` |
| `SaveIgnore()` | `INSERT IGNORE INTO` | `INSERT ... ON CONFLICT DO NOTHING` | `INSERT OR IGNORE` |

**Business-key upsert** (e.g. `(key, app_id)` settings table):

```zig
var b = try client.setting.Create();
defer b.deinit();
_ = try b.setFieldValue("key", .{ .string = "site_name" });
_ = try b.setFieldValue("app_id", .{ .int = app_id });
_ = try b.setFieldValue("value", .{ .string = "zent" });
_ = try b.SaveOrUpdate();
```

`SaveOrUpdate` targets the primary key by default. For a business-key
conflict target (e.g. a `@unique` index on `(key, app_id)`), ensure the
schema marks the columns unique and the builder generates the correct
`ON CONFLICT ("key", "app_id")` clause (see Z2).

## 5b. SELECT / ORDER BY expressions (Z5)

`FROM_UNIXTIME`, Haversine distance, `CONCAT`, `UNIX_TIMESTAMP()` and friends
no longer require hand-written SQL strings. Build the SELECT list with
`sql.SelectExpr(expr, alias)` and order with `sql.OrderExprSql(expr, desc)`,
then execute through `driver.queryOwned`:

```zig
var s = try zent.sql.Select(alloc, dialect, &.{
    .{ .table = null, .name = "id" },
    zent.sql.SelectExpr("UNIX_TIMESTAMP(created_at)", "created_ts"),
});
defer s.deinit();
_ = s.from(zent.sql.Table("orders"));
_ = try s.where(zent.sql.EQ("app_id", .{ .int = app_id }));
_ = try s.orderBy(zent.sql.OrderExprSql("UNIX_TIMESTAMP(created_at)", true));
_ = s.limit(50);

const q = try s.takeQuery();
defer q.deinit();
var rows = try client.driver.queryOwned(q);
defer rows.deinit();
while (rows.next()) |row| {
    const ts_idx = row.columnIndex("created_ts") orelse continue;
    const created_ts = row.getInt(ts_idx) orelse 0;
    _ = created_ts;
}
```

- The expression is emitted **verbatim** — never interpolate user input.
  Bind values with `?` / `$N` placeholders via `where`, never string concat.
- The alias is quoted as an identifier (`AS "created_ts"`) on all dialects.
- `Row.columnIndex(name)` maps an alias to its index for DTO mapping; combine
  with `tryGetInt`/`tryGetText` (error on NULL) or `getInt`/`getText`
  (`null` on NULL).
- For one-value queries (scalar aggregates) keep using `Count()` /
  `CountBy(...)` when they fit; reach for `SelectExpr` when the projection
  itself is an expression.

## 6. Transactions

```zig
var tx = try beginTx(infos, client.*);   // or zent_layer.beginTx() in the app
defer tx.deinit();                        // frees the Tx struct
errdefer tx.rollback() catch {};

_ = try tx.client.driver.exec("UPDATE ... SET money = money + $1 WHERE ...", args);
var created = try create(tx.client.supplier_capital, .{ ... });
try tx.commit();
```

- `rollback()` + `deinit()` are **both** required; `deinit` frees the Tx
  struct (PG auto-rolls-back an active tx on close).
- Nested `beginTx` degrades to savepoints — safe to nest in service
  orchestration.
- Relative updates (`SET balance = balance + $1`) have no typed form — raw
  `tx.client.driver.exec`.

## 7. Anti-patterns (each cost a debugging session)

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| `const e = first(...)` then `\|*e\|` | "deinitEntity requires a mutable entity pointer" | `var e` |
| `create(...)` freed as value, not `&created` | same compile error | `deinitEntity(..., &created, ...)` |
| Predicates as `&.{ ... }` to update/delete | historical comptime failure; now normalized | tuple `.{ ... }` for consistency |
| `comptime_int` for a Float field in `create` values | "Type mismatch for field 'x': expected f64, got comptime_int" | `@floatFromInt` / `0.0` |
| Unqualified `is_delete` in a JOIN | runtime "column reference is ambiguous" | `p.is_delete = 0` |
| `{d:0>4}` on a signed int (Zig 0.17) | dates render `+2026-+8-+10` | cast to `usize`/`u32` before formatting |
| SQLite-only SQL on PG (`?`, `DATE()`, backticks, `ON DUPLICATE KEY`) | runtime error | see §5 dialect rules |
| Owning string fields set to literals | crash in `free()` on deinit | always `allocator.dupe` borrowed text |
| `q.Limit(...)` wrapped in `try` | "expected error union, found *Self" | drop the `try` |

## 8. Testing

- **Logic** (no DB): pure functions only — test pricing, state machines,
  commission math directly.
- **Typed surface**: sqlite in-memory (`SQLiteDriver.open(allocator, ":memory:")`
  + `migrateSchema`) — fast, hermetic. See `crud_helpers` tests.
- **Real PG, rolled back**: `beginTx` + `defer rollback` — writes never
  persist; probe connectivity first and `return error.SkipZigTest` when the
  DB is down. Use unique fixture IDs (e.g. `9_999_xxx`) to avoid colliding
  with seeded data.
- **Verify rollback leaves no trace**: after the tx test, `SELECT` outside the
  tx and assert 0 rows.

## 8a. Multi-graph strategy

zent assumes one graph spans all tables of an application; edges resolve
across it at comptime. When the schema grows beyond ~80 tables and comptime
evaluation becomes a bottleneck, you have two options:

**Option A: Raise quotas (recommended)**
- `@setEvalBranchQuota` is already set to 1M in `src/codegen/graph.zig` and
  `src/codegen/predicate.zig`.
- If compilation still fails, raise the quota locally and report the measured
  limit so we can tune the default.

**Option B: Split graphs (not yet first-class)**
- Consumer apps (zapi, ~114 tables) have split into three graphs.
- **Limitation:** cross-graph edges do not resolve; `Client` types are not
  interchangeable; transactions across graphs need Driver-first APIs (Z9).
- If you must split, keep each graph self-contained and use raw `Driver`
  calls for cross-graph queries.

We plan first-class typed subgraphs with bridge edges (Z3). Until then,
prefer a single graph with raised quotas.

## 9. Promotion checklist (moving a pattern INTO zent)

Before shipping an app-side pattern up to the library, it must be:
1. **Generic** — no dependency on app globals (schema_infos / a global client /
   a specific allocator). `first/create/update/delete/deinitRows/Rows/queryRows`
   qualify; `getClient()/beginTx()` (app-wired globals) do not.
2. **Tested** — an sqlite round-trip + a negative case (no-match / error path
   with a leak check via `std.testing.allocator`).
3. **Documented** — memory contract stated on the doc comment so the consumer
   knows who frees what.
4. **Consumed** — at least one real caller switched to it, then the app-side
   copy is deleted (the app re-exports via its `zent_layer`).

Consumer-driven open items from the zapi port:
[`ISSUES_FROM_ZAPI.md`](ISSUES_FROM_ZAPI.md).

### Escape ledger template

When your app must bypass the typed API with raw SQL, log it in a
`DATA_ESCAPES.md` (or equivalent) so the library can absorb the pattern
later. Use this template:

```markdown
| # | Pattern | Why raw | zent version | min zent version | GitHub issue |
|---|---------|---------|--------------|------------------|--------------|
| 1 | `INSERT IGNORE INTO t ...` | idempotent relation insert | v0.29.8 | v0.30.0 (Z4) | #123 |
| 2 | `UPDATE stock SET num = GREATEST(num - ?, 0)` | no fluent GREATEST | v0.29.8 | v0.30.0 (Z12) | #124 |
```

- `zent version`: the version you first wrote the escape against.
- `min zent version`: the release that makes the escape unnecessary.
- Keep the table sorted by escape count / criticality so the most painful
  gaps float to the top.

## 10. Style

- Dupe strings with the **method's** allocator param (not a global) so the
  result's lifetime matches the caller's expectation.
- Free zent results with `deinitEntity`/`deinitRows`/`Rows.deinit()` — never
  `allocator.free` a raw entity.
- `errdefer` for rollback/cleanup; `defer` for forward-only cleanup.
- Preserve query constants (`pay_status = 20`, `apply_status = 10`, ...)
  verbatim across migrations — do not "fix" a number you don't understand.
