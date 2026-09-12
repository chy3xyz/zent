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

**Money: use `field.Decimal`, never `field.Float` (Z11, v0.31.0).** Decimal
fields map to PG `NUMERIC`, MySQL `DECIMAL(38,10)`, SQLite `TEXT`, and scan
into an owned `[]const u8` — the exact wire text, no f64 rounding, no silent
truncation. MySQL pads to the declared scale (`19.99` reads back as
`19.9900000000`); parse to cents/fixed-point in application code before
arithmetic.

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

**Eager edges: `WithEdgeOptions` (Z10, v0.31.0).** Default `WithEdge("posts")`
is a LEFT join — parents without posts survive with `edges.posts == null`.
For "only parents that HAVE targets", pass `.join = .inner`:

```zig
_ = try q.WithEdgeOptions("posts", .{ .join = .inner });
```

This adds a schema-aware `EXISTS` filter in SQL (not a post-load filter), so
`Limit(n)` returns exactly n qualifying parents — no limit skew. Nested dot
paths (`"posts.comments"`) filter on the head edge only. Edges must live in
the same graph as the parent (see §8a); cross-graph eager loading is a
compile error by design.

### Field names vs column names (`StorageKey`)

A field has a **Zig name** (the struct field, used by every user-facing API)
and a **column name** (the SQL identifier). They are equal by default; use
`StorageKey` when the field name and the physical column differ (mapping an
existing table):

```zig
const User = schema("User", .{
    .table_name = "users",
    .fields = &.{
        field.String("userName").StorageKey("user_name"),
        field.String("emailAddr").StorageKey("email_address"),
    },
});

// APIs take the field name; SQL is generated with the column name.
_ = try b.setFieldValue("userName", "alice");
_ = try q.Where(.{client.user.predicates.userNameEQ(.{ .string = "alice" })});
_ = try q.OrderBy(&.{zent.sql.OrderAsc("userName")});
```

Only one name is exposed per layer:

- **Field names** (what you pass): `setFieldValue` / `setValue`, the typed
  `predicates.<field>…`, `Select`, `OrderBy` (plain `.column` terms),
  `GroupBy`, `Cursor`/`CursorAfter`, `WhereIn`, interceptor `whereEq`,
  `SaveOrUpdateOn`, and the `crud_helpers` wrappers (`increment`,
  `updateWithVersion`, `batchSaveOrUpdate`, `scopedBy`, `paginatedWithOptions`,
  `latest`, `cursorPage`). Unknown names fall back to the string you passed,
  so raw column names still work.
- **Column names** (what zent emits): DDL and migration columns, index
  columns/names, `INSERT` column lists, `UPDATE … SET`, `WHERE`/`ORDER BY`/
  `GROUP BY`, and the projection used by `Select` (rows are matched by column
  and written back to the struct by field name).

Raw escape hatches stay SQL-level: `sql.EQ`/`sql.OrderAsc` handed to the
low-level `Selector`/`Update` builders, `SelectExpr`, `UpsertSetExpr.column`
and its `{t:col}`/`{x:col}` tokens, edge `.OrderBy("col")`, and EntQL
expression identifiers all take the **physical column name**. With
`StorageKey` that means writing `user_name`, not `userName`.

## 3a. Predicate catalogue

Every field gets these (`client.<entity>.predicates.<field><Suffix>`):

| Suffix | Signature | Renders |
|---|---|---|
| `EQ` `NE` `GT` `GTE` `LT` `LTE` | `(sql.Value)` | `col = ?` / `<> ?` / `> ?` / `>= ?` / `< ?` / `<= ?` |
| `In` `NotIn` | `([]const sql.Value)` | `col IN (?, ?)` / `col NOT IN (?, ?)` |
| `IsNull` `NotNil` | `()` | `col IS NULL` / `col IS NOT NULL` |

`string`/`text` fields additionally get:

| Suffix | Renders |
|---|---|
| `Contains` | `col LIKE ?` — `v` is bound **verbatim**, so **you supply the wildcards**: `xContains("%foo%")` matches a substring, `xContains("foo")` is an exact match. Parameterised, so it is the MySQL-safe one. |
| `ContainsEscaped` | `col LIKE '%v%' ESCAPE …` — `%` is added for you and any `%`/`_` in `v` is escaped, so `v` is a **literal substring** |
| `HasPrefix` `HasSuffix` | `col LIKE 'v%'` / `col LIKE '%v'`, escaped like `ContainsEscaped` |
| `ContainsFold` | `LOWER(col) LIKE LOWER('%v%')` — non-sargable |
| `EQFold` | `LOWER(col) = LOWER(?)` |

`Contains` is the odd one out: it does **not** wrap the value, because it
binds it as a parameter (which is what makes it safe on MySQL — see
`ISSUES_FROM_ZAPI.md` Z1). `ContainsEscaped`, `HasPrefix`, `HasSuffix` and
`ContainsFold` all add the wildcards themselves and escape the user input, so
they take a literal substring. Passing an unescaped `%foo%` to
`ContainsEscaped` would therefore search for a literal `%`.

Edges get `Has<Edge>()`, `NotHas<Edge>()`, and `Has<Edge>With(preds)`. The
`With` form takes the **target entity's own typed predicates**, so a
traversal filter never needs hand-written SQL:

```zig
_ = try q.Where(.{client.user.predicates.HasCarsWith(&.{
    client.car.predicates.modelEQ(.{ .string = "Tesla" }),
    client.car.predicates.yearGTE(.{ .int = 2020 }),
})});
```

Prefer these over `sql.Raw`/`sql.Like` + hand-written column names: the typed
forms validate the column against the schema and pick the right quoting and
placeholder style per dialect.

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

## 5c. Complex UPDATE expressions (Z12)

Single-table column expressions are fluent — no raw SQL needed. Use
`setExprArgs(field, "expr with ? placeholders", args)` on the update builder,
e.g. a clamped atomic stock decrement with `GREATEST`:

```zig
var u = client.stock.Update();
defer u.deinit();
_ = try u.setExprArgs("num", "GREATEST(num - ?, 0)", &.{.{ .int = delta }});
_ = try u.Where(.{preds.sku_idEQ(.{ .int = sku_id })});
const affected = try u.Save();
```

- The expression is emitted verbatim inside `SET col = <expr>`; placeholders
  bind through `args` in order (they come before any WHERE args).
- Works for `LEAST`, `COALESCE`, string functions — any single-column
  expression on the updated table.
- **Still raw** (by design): multi-table UPDATE (`UPDATE a JOIN b ...`),
  updating from a subquery, and dialect-specific `UPDATE ... FROM`. Keep those
  in `driver.exec` and log them in your escape ledger.

## 5d. Interceptors (runtime query rewriting)

Interceptors observe and transparently rewrite a query *before* it runs —
the ent `Intercept` counterpart. Register once on the root client; every
`Query`/`Update`/`Delete`/`Create` (and `Bulk*` variant) from any entity
client runs the chain. The canonical use is multi-tenant row scoping:

```zig
var client = Client.makeClient(infos, allocator, drv.asDriver());
defer Client.DeinitClient(infos, &client); // frees the owned chain

var tenant: i64 = currentTenantId();
try Client.UseInterceptor(infos, &client, .{
    .ctx = &tenant,
    .intercept = struct {
        fn f(ctx: ?*anyopaque, view: *zent.runtime.intercept.QueryView) anyerror!void {
            const id: *i64 = @ptrCast(@alignCast(ctx.?));
            // Query/Update/Delete: WHERE tenant_id = ?.
            // Create: set tenant_id when the caller omitted it.
            try view.whereEq("tenant_id", .{ .int = id.* });
        }
    }.f,
});
```

- Division of labor: **privacy** answers allow/deny plus *static* row
  filters tied to a policy (`withContext`); **interceptors** rewrite or
  observe queries at runtime (tenant injection, soft-scope enforcement,
  query counters) and are registered once per client.
- `view.whereEq` validates the field against the entity schema —
  `error.UnknownField` surfaces as `error.InterceptFailed` on the query.
- Interceptor errors abort the operation: the first error wins, and all
  errors collapse to `error.InterceptFailed` at the builder boundary
  (execution methods keep explicit error sets).
- Create / BulkInsert are intercepted: `whereEq` fills an omitted column
  (if-missing). An explicit value on the builder is kept. Tables without
  the field still return `UnknownField` (swallow it in the interceptor
  when the column is optional across the graph).
- `beginTx` copies the chain pointer into the TxClient, so registered
  interceptors also apply inside transactions. Register before `beginTx`.
- Per-entity registration (without a root client): borrow a caller-owned
  chain via `entity_client.withInterceptors(&chain)`.

## 5e. Edge writes (associations)

Associations are maintained on the `Update` builder; the statements are
scoped to the rows the update's own `Where` matches.

```zig
var u = client.user.Update();
defer u.deinit();
_ = try u.Where(.{client.user.predicates.idEQ(.{ .int = uid })});

_ = try u.AddEdgeIDs("groups", &.{ g1, g2 });   // idempotent
_ = try u.RemoveEdgeIDs("groups", &.{g1});
_ = try u.ClearEdge("groups");                   // every matched source
_ = try u.Save();
```

Semantics per edge kind:

| Edge | `Add` | `Remove` | `Set` | `Clear` |
|---|---|---|---|---|
| M2M | insert junction rows | delete junction rows | — | delete all junctions |
| `To` o2m/o2o (FK in target) | — | — | detach old owner, attach `ids` | NULL the FK |
| `From` (FK on this row) | not supported — use `setFieldValue` | | | |

- Wrong edge kind for the method is a **compile error** with the reason.
- `SetEdgeIDs` is replace-semantics and empty `ids` behaves like `ClearEdge`.
  It requires the `Where` to match **exactly one** source row (the attach
  resolves the source id with a scalar subquery, so a multi-row match is
  rejected by the database instead of silently picking one).
- Detaching requires a nullable FK; a `NOT NULL` FK is rejected at comptime.
- These run after the UPDATE body. Wrap in `beginTx` when you need the row
  change and the association change to be atomic.
- Prefer them over raw junction SQL: table and column names come from the
  schema, so quoting and placeholders follow the dialect.

### `rows_affected` is not portable

MySQL reports **changed** rows; SQLite and PostgreSQL report **matched** rows.
A no-op `UPDATE` (all values already equal) therefore returns `0` on MySQL and
`1` on the others. Never write `if (affected == 0) return error.NotFound` —
use an explicit `SELECT`/`Count()` or check a genuinely changing column.

## 5f. Connection pool

`ConnPool(D)` wraps any driver implementing `asDriver()` + `close()` and
exposes the same `driver.Driver`, so pooled and direct drivers are
interchangeable.

```zig
var pool = try ConnPool(SQLiteDriver).init(allocator, .{
    .connect = openFn,
    .min_connections = 4,
    .max_connections = 16,
    .max_wait_ms = 2_000,          // queue instead of failing instantly
    .max_idle_secs = 300,
    .max_lifetime_secs = 3_600,
    .health_check_on_borrow = true,
    .slow_query_threshold_ms = 200,
    .metrics = metrics,
});
defer pool.deinit();
const drv = pool.asDriver();
```

- **`max_wait_ms`** is the total budget for one `borrow` when every connection
  is checked out: the caller parks on the pool condition and is woken by a
  `release`, then falls back to the retry/backoff path on expiry. `0` (the
  default) keeps the non-blocking behaviour — immediate `error.PoolExhausted`.
  Fairness is best-effort: later arrivals defer to older tickets, but there is
  no wake-up forwarding, so do not rely on strict FIFO.
- **`health_check_on_borrow` runs inside the pool mutex**, so it serialises
  concurrent borrows. With a fast local server the ping is usually cheaper than
  the tail latency it adds; measure before enabling it on a remote database.
- **Metrics callbacks run outside the mutex** and may re-enter the pool.
- **`deinit` requires quiescence**: no thread may be inside
  `borrow`/`release`/`asDriver`, *including threads parked waiting for a
  connection*. `deinit` destroys the mutex and the pool's `Io` immediately
  after dropping the mutex, so interrupting a parked borrower is undefined.
  Drain your workload first (or stop accepting requests) before you deinit.
- The pool does not run a background reaper: call `reapIdleConnections` /
  `pingIdleConnections` from your own timer if you need them, and note that
  `min_connections` is only warmed up at `init` — it is not maintained.
- Each connection gets only the driver's fixed session setup
  (`client_encoding` on PostgreSQL, `utf8mb4` on MySQL). There is no per
  connection init hook, so session variables such as `SET app.tenant_id` for
  row-level security have to be issued by the caller on a borrowed connection.

## 5g. Eager loading (`WithEdge`)

```zig
var q = client.owner.Query();
defer q.deinit();
_ = try q.WithEdge("items.notes");
const owners = try q.All();
```

- **One query per level**, not per parent. `items.notes` costs three
  statements (owners, items, notes) regardless of how many owners match;
  nested levels are gathered into a single batch rather than recursed per
  parent.
- **Parents over the parameter limit are chunked**: an eager load spanning more
  than 500 parent rows splits its `IN` list into several statements.
- **The target's read contract is applied inside the neighbour `WHERE`** —
  soft-delete filtering, privacy policy/row filters and the interceptor chain —
  before any per-parent `LIMIT` ranking, so a filtered row cannot consume a
  per-parent limit slot. `WithTrashed()` includes soft-deleted targets too.
- `QueryEdge` / `queryTargets(ById)` apply **the same contract**: they route
  through `codegen.query.appendTargetScopePreds`, the one implementation the
  eager loader uses, so an edge read is scoped identically whether you take it
  inside a builder or outside one. `QueryEdge` forwards the client's own
  `privacy_ctx`/`interceptors` and needs no extra arguments; a target carrying
  a policy denies the traversal (`error.PrivacyDenied`) unless the client has a
  context.
- `queryTargetsUnscoped` / `queryTargetsByValueUnscoped` are the deliberate
  escape hatch: soft-delete only, no policy, no interceptor. They return a
  foreign tenant's row if you hand them that tenant's parent id, so treat a
  call site as an audited decision that the ids were scoped elsewhere.

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
- Relative updates (`SET balance = balance + $1`) are fluent on a single
  table: `u.setExprArgs("balance", "balance + ?", &.{.{ .int = delta }})`
  (§5c). Only multi-table `UPDATE ... JOIN` and `UPDATE ... FROM` stay raw.

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

**Driver-first transactions (Z9, v0.31.0):** when several graphs share one
`pool.asDriver()`, open a typed transaction for any graph without building
a root `Client`:

```zig
var tx = try zent.codegen.beginTxFromDriver(order_infos, pool.asDriver(), alloc);
defer tx.deinit(); // exactly once, regardless of commit/rollback
var b = try tx.client.order.Create();
...
try tx.commit();
```

Re-entrant calls inside an active transaction degrade to a savepoint,
same as `beginTx`.

We plan first-class typed subgraphs with bridge edges (Z3). Until then,
prefer a single graph — measured limits (UPGRADING §7a) cover ~300+ tables.

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
| 2 | `UPDATE stock SET num = GREATEST(num - ?, 0)` | no fluent GREATEST | v0.29.8 | v0.31.0 (Z12: `setExprArgs`) | #124 |
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
