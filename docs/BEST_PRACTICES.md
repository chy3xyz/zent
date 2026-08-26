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

**Predicates go in a tuple `.{ ... }`**, not `&.{ ... }`. The pointer form
is accepted by `Where`, but the tuple form is what `update`/`delete`
(`update_delete.zig`) resolve at comptime without tripping "unable to resolve
comptime value". Be consistent: always `.{ ... }`.

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
| Predicates as `&.{ ... }` to update/delete | "unable to resolve comptime value" (update_delete.zig) | tuple `.{ ... }` |
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

## 10. Style

- Dupe strings with the **method's** allocator param (not a global) so the
  result's lifetime matches the caller's expectation.
- Free zent results with `deinitEntity`/`deinitRows`/`Rows.deinit()` — never
  `allocator.free` a raw entity.
- `errdefer` for rollback/cleanup; `defer` for forward-only cleanup.
- Preserve query constants (`pay_status = 20`, `apply_status = 10`, ...)
  verbatim across migrations — do not "fix" a number you don't understand.
