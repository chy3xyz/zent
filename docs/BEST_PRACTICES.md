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
| Tenant isolation | opt-in via `scoped`/`scopedBy` | `tenant_id` is a **parameter** on every op, including `create` |
| Events | none | publishes `CrudEvent{created,updated,deleted}` to a listener (the after-hook surface) |
| Use when | plain CRUD, or when you already filter manually | you need an audit trail / outbox trigger / a uniform tenant boundary |

`CrudService.create(entity, tenant_id)` takes the tenant as an argument rather
than reading it from `entity`: the write loop used to copy every field, tenant
column included, and the interceptor that scopes creates only fills a column it
finds *missing* — so a freshly built entity (whose tenant field is the zero
value) wrote `0` while the service was bound to a real tenant.

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

**`field.String` vs `field.Text` on MySQL — pick by whether you need to index
it.** `String`/`Enum` map to `VARCHAR(255)` on MySQL (and `TEXT` on PostgreSQL
and SQLite); `Text`/`JSON`/`Other` map to `TEXT` everywhere. The reason is that
MySQL will not let a `TEXT` column be `UNIQUE` (errno 1170), carry a `DEFAULT`
(errno 1101), or take an index without a key length — so a `field.Text` field
declared `.Unique()`, `.Default(x)`, or with an index over it fails `CREATE
TABLE` outright, while the same declarations on `field.String` work.

The catch runs the other way: `VARCHAR(255)` is a 255-**character** cap that
`String` does not express in its API, so a longer value that PostgreSQL and
SQLite accept errors on MySQL under a strict `sql_mode` (the default) and is
truncated silently under a permissive one. Choose `String` for anything
indexed, unique or defaulted (emails, slugs, statuses, names), and `Text` for
genuinely unbounded content — accepting that MySQL will then refuse to make it
unique or defaulted. Existing MySQL tables created before v0.57.0 hold `TEXT`
where the schema now says `VARCHAR(255)`; see `UPGRADING.md` §12 for the
conversion and the length check to run first.

## 2. Memory contract (the one thing to get right)

zent results are **owned**; the caller frees exactly once. Three ownership
shapes:

| Result | Owner | Free with |
|--------|-------|-----------|
| `first` → `?Entity` | caller | `client.<entity>.deinitRow(&e)` |
| `create` → `Entity` | caller | `client.<entity>.deinitRow(&created)` |
| `q.All()` → `Managed(Entity)` | caller | `q.deinitRows(&rows)` (or `client.<entity>.deinitRows(&rows)`) |
| `QueryEdge` → `Managed(Target)` | caller | `client.<source>.deinitEdgeRows("edge", &rows)` |
| `q.AllIn(arena)` → `[]Entity` | **arena** | `arena.deinit()` — and nothing else |
| raw `driver.query` → `Rows` | caller | `rows.deinit()` (iterator) |
| `crud_helpers.Rows(T)` | caller | `rows.deinit()` (frees strings + slice) |

The `client.<entity>.deinit*` / `q.deinitRows` forms are the ones to reach for:
they carry the graph, so the call site names neither `infos` nor the allocator,
and `deinitRows` frees the page **and** the list in one line (the list comes
back empty and reusable, so calling it twice is a no-op). `deinitEntity` /
`codegen.deinitEntityList` / `crud_helpers.deinitRows` remain as the explicit
forms for generic code that already holds the graph.

**One page, one release mechanism.** A page from `AllIn` / `FirstIn` / `SaveIn` /
`queryRowsIn` belongs to the arena that was passed in, and `arena.deinit()` is the
**only** thing that frees it. Do not call `deinitEntity`, `deinitRow`,
`deinitRows` or `freeOwnedStrings` on such rows — the arena already owns them and
those calls free the same memory twice. The `*In` calls return a plain slice for
exactly this reason: a slice has no `deinit` to be reached for out of habit. If
you need per-row release instead, use the non-arena form (`All()` + `deinitRows`);
never mix the two on one page.

```zig
// (a) arena: one release for the whole page
var arena = std.heap.ArenaAllocator.init(alloc);
defer arena.deinit();
const users = try client.user.Query().Where(...).AllIn(&arena);
// no deinitRows, no deinitEntity — arena.deinit() at scope exit is all of it

// (b) explicit: per-item, then the list
var users = try client.user.Query().Where(...).All();
defer client.user.deinitRows(&users);
```

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
| `Like` | `col LIKE ?` — `v` is bound **verbatim**, so **you supply the wildcards**: `xLike("%foo%")` matches a substring, `xLike("foo")` is an exact match. Parameterised, so it is the MySQL-safe one. |
| `Contains` | Identical to `Like` (an alias kept for compatibility). **The name is misleading** — it does not wrap the value, so `xContains("foo")` is an exact match. Prefer `Like` in new code. |
| `ContainsEscaped` | `col LIKE '%v%' ESCAPE …` — `%` is added for you and any `%`/`_` in `v` is escaped, so `v` is a **literal substring** |
| `HasPrefix` `HasSuffix` | `col LIKE 'v%'` / `col LIKE '%v'`, escaped like `ContainsEscaped` |
| `ContainsFold` | `LOWER(col) LIKE LOWER('%v%')` — non-sargable |
| `EQFold` | `LOWER(col) = LOWER(?)` |

`Like` (and its alias `Contains`) is the odd one out: it does **not** wrap the
value, because it binds it as a parameter (which is what makes it safe on
MySQL — see `ISSUES_FROM_ZAPI.md` Z1). `ContainsEscaped`, `HasPrefix`,
`HasSuffix` and `ContainsFold` all add the wildcards themselves and escape the
user input, so they take a literal substring. Passing an unescaped `%foo%` to
`ContainsEscaped` would therefore search for a literal `%`.

Historical note: the predicate was called `Contains` only, and both the name
and the docs read as "substring search". `Like` was added as the honest name —
it is the same predicate, so nothing breaks; a rename of `Contains` is still
open (Z14).

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

**What a subquery predicate carries, and what it cannot.** `Has<Edge>()`,
`NotHas<Edge>()` and `Has<Edge>With(…)` are `EXISTS` subqueries over the target
table, and they apply the target's **soft-delete** scope — a trashed row does
not satisfy them (ent behaves the same way). They do **not** apply the target's
privacy filters or the interceptor chain: a bare predicate is a value with no
runtime context, so there is nothing to consult. A tenant-scoped existence check
passes its tenant predicate through the `With` form:

```zig
_ = try q.Where(.{client.user.predicates.HasCarsWith(&.{
    client.car.predicates.app_idEQ(.{ .int = tenant }),
})});
```

The same boundary applies to the raw subquery predicates — `sql.InSelect`,
`sql.InSubquery`, `sql.ExistsSubquery` render exactly what they are given, and
the `sql` layer has no graph to widen that. Add the inner table's scope
yourself, or express the traversal through an edge so the schema-aware path
builds it for you.

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
one `deinit()`. It runs the statement **as written**, so pair it with
`zent.scope` (below) exactly like a bare `driver.query` call.

### Which raw paths need scoping

Every path here executes SQL that you wrote; none of them can apply the read
contract on your behalf. The scope fragment comes from `zent.scope`, and you
splice it in.

| Path | Scoped by default? | What to do |
|---|---|---|
| `driver.query` / `driver.exec` | no | `zent.scope` + `withClause` |
| `crud_helpers.queryRows` | no | same (it is a mapper over `driver.query`) |
| `driver.queryCtx` / `execCtx` | no | same — the context carries a deadline only |
| `sql.Explain` (`explainSql`) | n/a | diagnostic only: it wraps the statement in `EXPLAIN` and never executes it |
| `sql_statement.checkStatement` | n/a | diagnostic only: it prepares the statement with the driver and discards it — no `step`/`execute`, and it takes the args, so it catches what `EXPLAIN` cannot |
| `QueryBuilder` / `QueryEdge` / `WithEdge` | **yes** | nothing to do |
| `crud_helpers` entity helpers (`first`/`all`/…) | **yes** | they go through a builder |
| `entql` (`Parse`) | **yes** | it lowers to builder predicates |
| `PreparedCache` | n/a | keyed on the final SQL text, byte-compared — two tenants produce two entries, never a shared statement |

### Validating a raw statement before you run it (`checkStatement`)

Raw SQL is written by hand, and until v0.58.0 there was no way to ask "will this
even run?" other than running it:

```zig
var d = try zent.sql_statement.checkStatement(alloc, drv, sql, args);
defer zent.sql_statement.freeStatementDiagnosis(alloc, &d);

switch (d.problem) {
    .none => {},                                  // prepared cleanly
    .syntax => return error.BadSql,
    .missing_relation, .missing_column => return error.SchemaDrift,
    .parameter_mismatch => return error.WrongArgs,
    .not_checkable => {},                         // this driver/statement cannot say
    else => std.log.warn("{s}", .{d.message orelse "?"}),
}
```

It **prepares and discards** — `sqlite3_prepare_v2`, `PQprepare`,
`mysql_stmt_prepare`, with no `step`/`execute` — so a checked `INSERT`,
`UPDATE` or `DELETE` changes nothing. `d.message` is the driver's own text
(plus `native_code`, and PostgreSQL's `sqlstate`), which is the part you cannot
get from an errno.

Three things it deliberately does not do:

- **It does not flatten the dialects.** SQLite reports every prepare failure as
  `SQLITE_ERROR`, so its label is read from the message and flagged
  `problem_heuristic = true`; MySQL and PostgreSQL have structured codes. A
  constraint violation is invisible to all three — that happens at execution.
- **`not_checkable` is not a failure.** PostgreSQL's `25P02`/`0A000` and MySQL's
  errno `1295` (`BEGIN`, `LOCK TABLES`, `PREPARE` — the prepared protocol does
  not take them) mean *this channel cannot judge the statement*, not that the
  statement is broken. A driver with no prepare channel answers the same way, so
  a bulk audit runs to the end instead of stopping at the first unsupported
  statement.
- **It does not execute to find out.** There is no "run it inside a rolled-back
  transaction" path; the only thing it touches is the parse/bind phase.

Use `explainSql` instead when you want the *plan*; it accepts no parameters, so
it cannot answer the bound-parameter question this exists for.

### Scoping raw SQL (`zent.scope`)

Raw SQL bypasses the builders, and the builders are where privacy and the
interceptor chain live — so a hand-written statement is **unscoped by
default**. `zent.scope` renders the same contract (`appendTargetScopePreds`:
soft-delete → privacy → interceptors) into a fragment you splice in, so the
two paths cannot disagree:

```zig
// The head binds one argument of its own, so the fragment must start at $2.
// (SQLite/MySQL heads use `?`, where `arg_index` has no effect.)
var scope = try zent.scope.forClient(infos, "order", &client.order, .{
    .alias = "o",
    .arg_index = 2, // = head_arg_count + 1
});
defer scope.deinit(); // owns the fragment + its bound args

const stmt = try zent.scope.withClause(
    scope,
    alloc,
    "SELECT o.id FROM order o WHERE o.amount > $1",
    true, // this head already has a WHERE → the fragment ANDs into it
);
defer alloc.free(stmt);

// Your own arguments first, then the fragment's.
var rows = try client.driver.query(stmt, &.{ .{ .float = amount }, .{ .int = tenant } });
```

Placeholders are the dialect's, so a head written for PostgreSQL must use `$N`
(§5) — a `?` head is not translated by the driver. If you would rather renumber
the statement yourself, `.marker = .question` renders the fragment with `?`
placeholders regardless of dialect, and then nothing can collide.

- `forClient(infos, table, &entity_client, opts)` takes the allocator, driver,
  `privacy_ctx` and interceptor chain from the entity client — pass the client
  whose entity the statement is about. `forTable(...)` is the same thing with
  the four inputs spelled out.
- `table` is a **comptime** string, resolved against the graph at compile time
  — a typo is a compile error, not an unscoped query. Either the physical
  table name (`"order"`) or the entity name (`"Order"`) works.
- `.alias = "o"` renders every injected predicate qualified
  (`"o"."app_id" = ?`). **Set it whenever the statement joins anything**: a
  bare column is rejected as ambiguous the moment a second table owns the same
  column, which is a fail-loud description of the bug this prevents.
- `.with_trashed = true` drops the soft-delete half; `.op = .update` / `.delete`
  is what the privacy policy and interceptors see for a statement that writes.
- `.arg_index` (default `1`) is where the fragment's first placeholder number
  starts — the head's `$1` and the fragment's `$1` are the same parameter, so a
  head that binds anything needs `head_arg_count + 1`. `.marker = .question`
  forces `?` placeholders for a caller that renumbers the statement itself.
- The fragment is empty (`scope.sql.len == 0`) when the table contributes no
  scope at all, and `withClause` / `writeClause` then append nothing — so it is
  safe to call unconditionally for every statement on that table.
- Fail-closed: a table with a privacy policy and no `privacy_ctx` returns
  `error.PrivacyDenied` rather than an unscoped fragment.
- Predicate shapes that cannot be rewritten safely (a policy filter carrying
  its own SQL, raw fragments, subqueries) are appended verbatim. `eq`,
  `is_null` and `is_not_null` are the ones that get qualified.

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
- `whereEq` is **deduped on the (column, value) pair**, never on the column
  alone: a query that already says `tenant_id = 1` does not get a second
  placeholder, while a caller predicate carrying a *different* value is kept.
  That asymmetry is deliberate — deduping by column would let a caller
  suppress the interceptor's own value, turning "add a predicate" into a
  tenant-scope bypass.
- Create / BulkInsert are intercepted differently, and the difference matters:
  `whereEq` **fills an omitted column** (if-missing). An explicit value on the
  builder wins. That makes create-time injection a *default filler*, not an
  enforcement point — a caller who sets `tenant_id` explicitly still writes
  that value. Use a privacy policy (`Deny`) for a write constraint the caller
  cannot override, and treat the interceptor's fill as convenience. Tables
  without the field still return `UnknownField` (swallow it in the interceptor
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
| `From` m2o/o2o (FK on this row) | — | — | write the FK column (at most one id) | NULL the FK |

- Wrong edge kind for the method is a **compile error** with the reason.
- `SetEdgeIDs` is replace-semantics and empty `ids` behaves like `ClearEdge`.
  For a `To` edge it requires the `Where` to match **exactly one** source row
  (the attach resolves the source id with a scalar subquery, so a multi-row
  match is rejected by the database instead of silently picking one).
- **A `From` edge is written differently, on purpose**: its FK is a column of
  the row you are updating, so `SetEdgeIDs`/`ClearEdge` put it in the UPDATE's
  own `SET` clause instead of emitting a second statement against the target
  table. One statement, one predicate, one transaction, and the
  interceptor/privacy scope covers it like any other column. It also means an
  association change needs no companion `setFieldValue` — the write *is* a SET
  field. At most one id is meaningful (`error.TooManyEdgeTargets` from the call
  otherwise); clearing needs a nullable FK, rejected at comptime by `ClearEdge`
  and at runtime by `SetEdgeIDs(…, &.{})` (`error.EdgeNotDetachable`).
- Detaching a `To` edge requires a nullable FK on the target; a `NOT NULL` FK is
  rejected at comptime.
- `To`/M2M edge writes run **after** the UPDATE body, so wrap both in
  `beginTx` when they must be atomic. A `From` edge write is part of the UPDATE
  itself and needs no such care.
- An edge-only update needs **no** companion field: with nothing to `SET`, the
  statement touches the matched rows with a primary-key self-assignment, so the
  hooks fire and `rows_affected` keeps meaning "rows the predicate matched".
  (Before v0.45 this emitted `UPDATE … WHERE …` and failed to prepare — which is
  why older code, and the tests, pair every edge call with a `setFieldValue`.)
- An update with neither a field nor an edge action is
  `error.NoFieldsToUpdate` rather than a driver syntax error.
- Prefer them over raw junction SQL: table and column names come from the
  schema, so quoting and placeholders follow the dialect.

### Connection health in the pool

Drivers expose a `dead` flag (`PostgresDriver` and `MySQLDriver` both), which the
pool consults when a connection is released: a connection that failed with
`ConnectionFailed` — a server restart, a `pg_terminate_backend`, an idle-timeout
kill — is closed instead of going back into `available`. PostgreSQL marks it
lazily from `PQstatus`, so the *failing* call sets it and the next borrower fails
fast; at most one request pays for a break.

**From an error to a status code.** `driver.classify(err)` answers the question
a handler actually has, so no handler has to enumerate the three error sets:

| Class | Errors | Answer |
|---|---|---|
| `.capacity` | `ConnectionFailed`, `PingFailed`, `PoolExhausted`, `PoolClosed`, `OutOfMemory`, `QueryTimeout` | 503, back off |
| `.transient` | `DeadlockDetected`, `SerializationFailure`, `LockTimeout`, `TxFailed`, `OptimisticLockConflict` | retry the same work |
| `.client` | `UniqueViolation`, `NotNullViolation`, `ForeignKeyViolation`, `ExecFailed`, `QueryFailed`, `NotFound` | 4xx |
| `.bug` | `PrepareFailed`, `BindFailed`, `ProtocolError`, `DriverFailed`, and anything from outside this library | 500 |

`driver.isRetryable(err)` is the narrower "would retrying help?" — the transient
and connection/pool classes, **not** `OutOfMemory`/`QueryTimeout`, where a retry
usually makes things worse.

**Seeing inside the pool.** `pool.stats()` takes the mutex and returns
`total` / `in_use` / `available` / `waiters` / `exhausted_total` / `closed` —
enough for a gauge plus a counter that says "the pool is too small, or the
database is gone". Size the pool against the server:
*instances × max_connections + reserved roles ≤ the server's `max_connections`.*

**Draining vs overloading vs a spent budget.** `error.PoolExhausted` means the
pool reached `max_connections` with everything lent out — a capacity signal, and
the one worth mapping to 503. A connection that could not be *opened* surfaces as
the driver's own error (`ConnectionFailed`, `PingFailed`), i.e. a configuration
or connectivity fault, which `driver.isRetryable` also classifies for you.
`error.PoolWaitTimeout` is the third case: the budget ran out while parking, so
the pool may well have capacity moments later — it is retryable, where
`PoolExhausted` with `max_wait_ms = 0` is not. `driver.classify` maps all three
for you. The give-up path logs a `warn` naming the reason, and `Metrics.onError`
gets the real error rather than a constant.

Whether that health check runs on *borrow* is a separate knob:
`health_check_on_borrow` pings the selected connection **outside** the pool mutex
— a borrow picks a candidate under the lock and pings it after unlocking, taking
the lock again only to close a connection that failed. Concurrent borrows
therefore do not queue behind each other's round trips. It remains off by
default; the `dead` flag is what makes turning it off safe.

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

- **`max_wait_ms`** is a **hard ceiling** on how long one `borrow` may wait when
  every connection is checked out: the caller parks on the pool condition and is
  woken by a `release`. `0` (the default) keeps the non-blocking behaviour —
  immediate `error.PoolExhausted`. Expiry reports `error.PoolWaitTimeout`.
  Fairness is best-effort: later arrivals defer to older tickets, but there is
  no wake-up forwarding, so do not rely on strict FIFO.
- **A request deadline can shorten the wait, never lengthen it.** Use
  `borrowWithTimeout(ms)`, `borrowCtx(&ctx)` or `borrowWithBudget(ms, &ctx)`
  when the caller has its own budget: the effective wait is
  `min(requested, max_wait_ms)`, so the pool's ceiling still applies. A statement
  or transaction deadline covers the wait for a connection as well as the run —
  `execCtx`/`queryCtx` merge the context before borrowing, and `beginTxCtx` does
  the same for transactions (drivers without that hook fall back to `beginTx`).
- **`health_check_on_borrow` pings outside the pool mutex** — a borrow selects a
  candidate under the lock and pings it after unlocking, re-taking the lock only
  to close a connection that failed. Concurrent borrows do not serialise behind
  each other's round trips. Still off by default: with a fast local server the
  ping is usually cheaper than the tail latency it adds, so measure before
  enabling it on a remote database.
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

## 5h. Nullability: schema vs database

zent's DDL says `NOT NULL` unless a field is `Optional()`/`Nillable()`, and the
scanners fail a non-optional field on NULL with `error.TypeMismatch`. A database
that predates the schema — a ported PHP app, a hand-managed DDL — can disagree,
and the disagreement is silent until a read hits a NULL.

`migrateSchema` reports it (one summary line at `warn`, per-column detail at
`debug`), because that is the moment the two are known to meet. The full list is
one call:

```zig
const drifts = try zent.sql_schema.checkNullability(allocator, client.driver, infos);
defer zent.sql_schema.freeNullabilityDrift(allocator, drifts);
for (drifts) |d| {
    if (d.breaksReads()) // database allows NULL, schema does not
        std.log.err("{s}.{s}", .{ d.table, d.column });
}
```

`d.breaksReads()` is the direction that hurts: the database allows NULL where
the schema declares a non-optional field, so rows already in the table fail to
scan. The other direction (schema optional, database NOT NULL) rejects a NULL
insert instead.

When a scan does fail, the message names the table and the column — the
diagnosis runs on the failure path only, so a successful read pays nothing:

```
zent: table 'xdaofood_order' column 'remark' is NULL, but field 'remark'
      ([]const u8) is not optional — the database allows NULL where the schema
      does not; make the field Optional()/Nillable(), or fix the column
```

### What `migrateSchema` does **not** do

It converges the database towards the schema, and it stops short of anything
that needs a data decision. Knowing the list is the difference between "the
migration ran, so the shape is right" and being surprised later:

| Not done | Consequence | What to do |
|---|---|---|
| An added column is **`NOT NULL` only with `allow_nullability_change`** (the default emits the type and any `DEFAULT`, and the code comment says why: SQLite rejects `NOT NULL` without a default) | by default `migrateSchema` **creates** the drift `checkNullability` then reports — an "optional" column where the schema says otherwise | turn on `allow_nullability_change` (below), or backfill and `ALTER COLUMN … SET NOT NULL` yourself, or make the field `Optional()` |
| An existing column's nullability is changed **only with `allow_nullability_change`** (and only on PostgreSQL) | the database keeps whatever it had, silently | see `checkSchema`/`assertSchema` above |
| **Unique** on an added column is not emitted (SQLite cannot, and the `CREATE TABLE` path carries it for PG/MySQL) | an old table gains the column without the constraint | add the constraint in a real migration |
| **Foreign keys** exist only in `CREATE TABLE`; `ALTER` never adds one | old tables stay unconstrained | same |
| A **changed `view_sql` never takes effect** — views are `CREATE VIEW IF NOT EXISTS` | the definition you upgraded to is not the one in the database | `DROP VIEW` then re-run, or version the view name |
| A **changed index definition is reported but not repaired** — `ExistingIndex.columns` now carries the key list, but `migrateSchema` still only asks whether the name exists | a declared index the database holds under the same name with different columns stays as it is | drop and recreate it by hand; `checkSchema` names the difference |

Everything in that table is also what `checkSchema` reports, which is the point:
the migration path is not a substitute for the check.

#### Index drift: reported only when it can be read reliably

`ExistingIndex.columns` carries the ordered key columns from all three dialects
(MySQL `information_schema.statistics`, PostgreSQL `pg_index` + `pg_attribute`,
SQLite `PRAGMA index_info`), so a declared index that the database holds under
the same name with a different key list is reported as
`SchemaDrift.Kind.index_columns` with a detail like
`schema wants (a, b), database has (a)`.

The comparison **errs towards silence**, on purpose. A false drift blocks a
deploy; a missed one is a warning nobody reads. So it is skipped rather than
guessed whenever the database's key list cannot be read reliably:

| Skipped | Why |
|---|---|
| expression keys (`lower(email)`, PG attnum 0) | the key is not a column, so "the columns differ" is not a statement about this index |
| prefix keys (`KEY (c(10))`, MySQL `sub_part`) | the key covers part of the column — its name reads as a match for a full-column index, so this is the case where a naive column comparison lies |
| partial indexes (`WHERE …`) | same key list, different coverage — not comparable by name+columns |
| non-btree access methods (`USING gin`/`hash`/…) | column order and meaning do not map onto the schema's list |
| `indisvalid = false` | a half-built index is not a definition to compare against |
| `INCLUDE` columns, key-count mismatch, empty key list | the introspection would be comparing different things |

Two consequences worth knowing:

- **`breaksReads()` is `false` for `index_columns`.** An index cannot break a
  read, only slow it down, so `DriftStrictness.read_breaking_only` — the mode
  that gates a deploy — never fails on it. Only `.any` does.
- **`migrateSchema` does not repair it.** Non-destructiveness is deliberate: it
  creates missing indexes and leaves differing ones alone. The report is the
  deliverable; the `DROP INDEX` + `CREATE INDEX` is yours.

#### Converging nullability (`allow_nullability_change`)

The first two rows of that table are the drift a long-lived deployment can never
get out of on its own. `MigrateOptions.allow_nullability_change` (default
`false`) adds both halves of the fix:

```zig
try zent.sql_schema.migrateSchemaWithOptions(alloc, drv.asDriver(), infos, .{
    .allow_nullability_change = true,   // opt-in: SET NOT NULL may hit live data
    .check_nullability = true,          // report whatever is still left
});
```

- An **added** column the schema declares `NOT NULL` is emitted
  `NOT NULL DEFAULT …`, using the field's own default or the audit-timestamp
  one. A non-optional field with **neither** fails the migration with
  `error.NotNullNeedsDefault` — the value that backfills the rows already in the
  table is your decision, not this layer's, and guessing it silently is how you
  end up with a column full of zeros. The whole batch rolls back.
- An **existing** column whose nullability differs is altered: `SET NOT NULL` /
  `DROP NOT NULL` on **PostgreSQL**.

Dialect differences are not smoothed over, because each one is a real
constraint rather than an implementation gap:

| Dialect | Added `NOT NULL` column | Existing column nullability |
|---|---|---|
| PostgreSQL | yes, with the backfill `DEFAULT` | `SET`/`DROP NOT NULL` |
| SQLite | yes, with the backfill `DEFAULT` | **not possible** — no `ALTER COLUMN`; `check_nullability` reports it |
| MySQL | yes, with the backfill `DEFAULT` | **fails closed** with `error.MySQLNullabilityChangeUnsafe` |

The MySQL refusal is deliberate. `MODIFY COLUMN` replaces the entire column
definition, and this layer does not introspect enough to reproduce one: it reads
`column_default` (then drops it — `ExistingColumn` keeps only name, type and
nullability) and nothing at all of `EXTRA` (`AUTO_INCREMENT`,
`ON UPDATE CURRENT_TIMESTAMP`), charset, collation, comment, or generated-column
expressions. A rewrite would silently drop every one of those, which is the same
reason `MySQLTypeChangeUnsafe` already fails closed for type changes. Widening
it means introspecting those attributes first.

For the same reason, and covering everything a schema can drift on rather than
just NULL:

```zig
const drifts = try zent.sql_schema.checkSchema(alloc, drv.asDriver(), infos);
defer zent.sql_schema.freeSchemaDrift(alloc, drifts);
for (drifts) |d| if (d.breaksReads()) std.log.err("{s}.{s}: {s}", .{ d.table, d.column, @tagName(d.kind) });
// or, as a gate:
try zent.sql_schema.assertSchema(alloc, drv.asDriver(), infos, .read_breaking_only);
```

`breaksReads()` is true for a missing table or column and for a column the
database made nullable under a non-optional field — the drifts that fail reads.
Type differences and extra columns are reported but do not fail a gate.

If your DDL is a set of `.sql` files and you never call `migrateSchema`, the
automatic report never runs. Call the check yourself, as a gate:

```zig
// Fails with error.NullabilityDrift; the detail goes to the log as well.
try zent.sql_schema.assertNullability(alloc, drv.asDriver(), infos, .read_breaking_only);
```

`.read_breaking_only` refuses only the direction that breaks reads;
`.any` refuses every difference (a schema-optional column that the database
declares NOT NULL fails a NULL *insert* loudly, so it is usually not worth
blocking a deploy over).

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
