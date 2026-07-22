# Cascade / EXPLAIN+Pool / Optimistic Lock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement database-level cascade delete/update, integer-version optimistic locking, and EXPLAIN query inspection plus connection-pool lifecycle improvements.

**Architecture:** Minimal extensions to existing codegen and schema layers. Cascade lives in migration SQL generation. Optimistic locking is detected from a new `field.Version()` helper and injected into UPDATE/DELETE WHERE clauses. EXPLAIN wraps the existing SQL builder with a dialect-specific prefix. Pool improvements add options and eviction checks to the existing pool borrow/release path.

**Tech Stack:** Zig 0.17-dev, SQLite/PostgreSQL/MySQL drivers, existing `zent.sql.schema`, `zent.codegen`, `zent.sql.pool`.

## Global Constraints

- Target Zig 0.17-dev; use `std.Io` for file I/O, `std.process.Init` for CLI examples.
- All public APIs keep the existing fluent/chainable style.
- Every allocation must have a matching `defer`/`errdefer` per project conventions.
- Tests must use `std.testing.allocator` and `testing.io` where needed.
- Run `zig fmt --check src examples tests build.zig` before each commit.
- Run `zig build test` and `zig build test-integration` before claiming done.

---

## Phase 1: Database-Level Cascade Delete/Update

### Task 1.1: Verify FK clause generation in `createTableSQL`

**Files:**
- Read: `src/sql/schema/migrate.zig:367-443` (`createTableSQL`)
- Modify: `src/sql/schema/migrate.zig`
- Test: `tests/integration/sqlite.zig`

**Interfaces:**
- Consumes: `ForeignKeyDef.on_delete`, `ForeignKeyDef.on_update`
- Produces: Valid `CREATE TABLE` SQL with `ON DELETE CASCADE` / `ON UPDATE CASCADE`

- [ ] **Step 1: Confirm current output lacks explicit ON DELETE/ON UPDATE**

Add a temporary debug print or read the existing code to confirm the FK clause currently ends after the referenced columns.

- [ ] **Step 2: Modify `createTableSQL` to emit `ON DELETE` and `ON UPDATE`**

In `src/sql/schema/migrate.zig`, locate the loop that emits foreign keys inside `createTableSQL`. After the referenced columns, append:

```zig
try buf.appendSlice(") ON DELETE ");
try buf.appendSlice(fk.on_delete);
try buf.appendSlice(" ON UPDATE ");
try buf.appendSlice(fk.on_update);
```

The existing code should already have:

```zig
try buf.appendSlice(") REFERENCES ");
// ... table and columns ...
```

Change it so the closing `)` and `ON DELETE ... ON UPDATE ...` are appended.

- [ ] **Step 3: Add unit test for FK SQL**

In `src/sql/schema/migrate.zig` test section, add:

```zig
test "CREATE TABLE SQL includes ON DELETE/UPDATE cascade" {
    const table = TableDef{
        .name = "order",
        .columns = &.{
            ColumnDef{ .name = "id", .sql_type = "INTEGER", .primary_key = true },
            ColumnDef{ .name = "user_id", .sql_type = "INTEGER" },
        },
        .primary_keys = &.{"id"},
        .foreign_keys = &.{
            ForeignKeyDef{
                .columns = &.{"user_id"},
                .ref_table = "user",
                .ref_columns = &.{"id"},
                .on_delete = "CASCADE",
                .on_update = "CASCADE",
            },
        },
    };
    const sql = try createTableSQL(table, Dialect.sqlite);
    defer std.heap.page_allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ON DELETE CASCADE") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ON UPDATE CASCADE") != null);
}
```

- [ ] **Step 4: Run unit tests**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Add SQLite integration test for cascade delete**

In `tests/integration/sqlite.zig`, append:

```zig
test "SQLite: database-level cascade delete" {
    const allocator = testing.allocator;
    const io = testing.io;

    const User = schema("User", .{
        .fields = &.{ field.Int("id"), field.String("name") },
    });
    const Order = schema("Order", .{
        .fields = &.{
            field.Int("id"),
            field.Int("user_id"),
        },
        .edges = &.{
            // O2M From edge: order.user -> user
            .{ .name = "user", .target_name = "User", .relation = .m2o, .kind = .from, .required = true },
        },
    });

    const graph = comptime buildGraph(&.{ User, Order });
    const infos = graph.types;

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    try migrate.migrateSchema(allocator, drv.asDriver(), infos);

    _ = try drv.exec("INSERT INTO user (id, name) VALUES (1, 'alice')", &.{});
    _ = try drv.exec("INSERT INTO \"order\" (id, user_id) VALUES (10, 1)", &.{});
    _ = try drv.exec("INSERT INTO \"order\" (id, user_id) VALUES (11, 1)", &.{});

    _ = try drv.exec("DELETE FROM user WHERE id = 1", &.{});

    var rows = try drv.query("SELECT COUNT(*) FROM \"order\"", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 0), row.getInt(0).?);
}
```

- [ ] **Step 6: Run integration tests**

Run: `zig build test-integration`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add src/sql/schema/migrate.zig tests/integration/sqlite.zig
git commit -m "feat(schema): emit ON DELETE/UPDATE CASCADE in CREATE TABLE"
```

---

## Phase 2: Optimistic Locking

### Task 2.1: Add `Version` field helper and `is_version` metadata

**Files:**
- Modify: `src/core/field.zig`
- Modify: `src/core/schema.zig` if `Schema` validates fields
- Modify: `src/codegen/graph.zig`
- Read: existing `FieldInfo` definition

**Interfaces:**
- Consumes: existing `Field` and `FieldInfo`
- Produces: `field.Version("version")`, `FieldInfo.is_version: bool`

- [ ] **Step 1: Add `Version` helper and `is_version` flag**

In `src/core/field.zig`, add:

```zig
pub fn Version(name: []const u8) Field {
    var f = Int(name);
    f.is_version = true;
    return f;
}
```

Ensure `Field` struct has `is_version: bool = false`.

- [ ] **Step 2: Propagate `is_version` to `FieldInfo`**

In `src/codegen/graph.zig`, when building `FieldInfo` from `Field`, set:

```zig
.is_version = f.is_version,
```

- [ ] **Step 3: Add unit test for version field metadata**

In `src/core/field.zig` or `src/codegen/graph.zig` tests:

```zig
test "Version field is marked as is_version" {
    const User = schema("User", .{
        .fields = &.{
            field.Int("id"),
            field.Version("version"),
        },
    });
    const info = comptime fromSchema(User);
    try std.testing.expect(info.fields[1].is_version);
}
```

- [ ] **Step 4: Run unit tests**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/field.zig src/codegen/graph.zig
git commit -m "feat(core): add Version field helper for optimistic locking"
```

---

### Task 2.2: Inject version into UPDATE and DELETE

**Files:**
- Read: `src/codegen/update_delete.zig`
- Modify: `src/codegen/update_delete.zig`
- Modify: `src/sql/driver.zig` (add `OptimisticLockConflict` to `Error`)
- Test: `tests/integration/sqlite.zig`

**Interfaces:**
- Consumes: `FieldInfo.is_version`
- Produces: UPDATE SQL with `version = version + 1 WHERE ... AND version = $old`; DELETE SQL with `AND version = $old`; new error `error.OptimisticLockConflict`

- [ ] **Step 1: Add `OptimisticLockConflict` to driver error set**

In `src/sql/driver.zig`:

```zig
pub const Error = error{
    // ... existing errors ...
    OptimisticLockConflict,
};
```

- [ ] **Step 2: Modify `UpdateBuilder` to read and increment version**

In `src/codegen/update_delete.zig`, locate the `UpdateBuilder` SQL generation. The builder already tracks field values. Detect if the entity has a version field (`info` is available comptime).

Pseudo-code for the generated UPDATE SQL:

```zig
// In Save() or execUpdate():
const has_version = comptime blk: {
    for (info.fields) |f| {
        if (f.is_version) break :blk true;
    }
    break :blk false;
};

if (has_version) {
    // Add "version = version + 1" to SET clause
    // Add "AND version = ?" to WHERE clause using the loaded old value
}
```

The old version value must be loaded when the entity is queried. The generated entity struct already contains the `version` field. The `Save()` method needs access to it.

For the first implementation, require the caller to set the version field like any other field. The builder then appends `version = version + 1` to SET and `AND version = :old_version` to WHERE.

- [ ] **Step 3: Detect conflict by checking rows_affected**

After `drv.exec(update_sql, args)`, check:

```zig
if (result.rows_affected == 0) return error.OptimisticLockConflict;
```

Map this to `driver.Error.OptimisticLockConflict` in the driver vtable wrappers.

- [ ] **Step 4: Modify `DeleteBuilder` hard delete similarly**

In hard delete, if entity has version field, append `AND version = ?` to WHERE. On `rows_affected == 0`, return `error.OptimisticLockConflict`.

- [ ] **Step 5: Add integration test**

In `tests/integration/sqlite.zig`:

```zig
test "SQLite: optimistic lock conflict" {
    const allocator = testing.allocator;
    const User = schema("LockedUser", .{
        .fields = &.{
            field.Int("id"),
            field.String("name"),
            field.Version("version"),
        },
    });

    const graph = comptime buildGraph(&.{User});
    const infos = graph.types;

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    try migrate.migrateSchema(allocator, drv.asDriver(), infos);

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b = try client.locked_user.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    const created = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);
    try testing.expectEqual(@as(i64, 0), created.version);

    // Simulate stale update
    var stale = created;
    stale.name = "bob";
    stale.version = 999;

    var ub = try client.locked_user.UpdateOne(stale);
    defer ub.deinit();
    const result = ub.Save();
    try testing.expectError(error.OptimisticLockConflict, result);
}
```

Note: `UpdateOne` may not exist; use the existing update API. Adjust the test to match actual generated API.

- [ ] **Step 6: Run tests**

Run: `zig build test && zig build test-integration`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add src/sql/driver.zig src/codegen/update_delete.zig tests/integration/sqlite.zig
git commit -m "feat(codegen): optimistic locking with version field"
```

---

## Phase 3: EXPLAIN Query Plans

### Task 3.1: Add EXPLAIN SQL builder

**Files:**
- Create: `src/sql/explain.zig`
- Modify: `src/root.zig` to export it
- Modify: `src/codegen/query.zig` (`QueryBuilder`, `Selector`)

**Interfaces:**
- Consumes: dialect, raw SQL
- Produces: dialect-prefixed EXPLAIN SQL string

- [ ] **Step 1: Create `src/sql/explain.zig`**

```zig
const std = @import("std");
const Dialect = @import("dialect.zig").Dialect;

pub const Format = enum { text, json };

pub const ExplainResult = struct {
    sql: []const u8,

    pub fn deinit(self: *ExplainResult, allocator: std.mem.Allocator) void {
        allocator.free(self.sql);
        self.* = undefined;
    }
};

pub fn explainSql(allocator: std.mem.Allocator, dialect: Dialect, raw_sql: []const u8, format: Format) !ExplainResult {
    const prefix: []const u8 = switch (dialect.name[0]) {
        's' => "EXPLAIN QUERY PLAN ",
        'p' => if (format == .json) "EXPLAIN (FORMAT JSON) " else "EXPLAIN ",
        'm' => "EXPLAIN ",
        else => return error.UnsupportedDialect,
    };
    const sql = try allocator.alloc(u8, prefix.len + raw_sql.len);
    @memcpy(sql[0..prefix.len], prefix);
    @memcpy(sql[prefix.len..], raw_sql);
    return ExplainResult{ .sql = sql };
}
```

- [ ] **Step 2: Export from `src/root.zig`**

```zig
pub const sql_explain = @import("sql/explain.zig");
```

- [ ] **Step 3: Add `.Explain()` to query builders**

In `src/codegen/query.zig`, add to `QueryBuilder`:

```zig
pub fn Explain(self: *Self, allocator: std.mem.Allocator, format: zent.sql_explain.Format) !zent.sql_explain.ExplainResult {
    const q = try self.query();
    defer allocator.free(q.sql);
    // q.args are not needed for EXPLAIN
    return zent.sql_explain.explainSql(allocator, self.dialect, q.sql, format);
}
```

Also add to `Selector` if it has a separate query path.

- [ ] **Step 4: Add unit test**

In `src/sql/explain.zig`:

```zig
test "SQLite EXPLAIN SQL prefix" {
    const allocator = std.testing.allocator;
    const raw = "SELECT 1";
    var plan = try explainSql(allocator, Dialect.sqlite, raw, .text);
    defer plan.deinit(allocator);
    try std.testing.expectEqualStrings("EXPLAIN QUERY PLAN SELECT 1", plan.sql);
}
```

- [ ] **Step 5: Run tests**

Run: `zig build test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/sql/explain.zig src/root.zig src/codegen/query.zig
git commit -m "feat(sql): EXPLAIN query plan helper"
```

---

## Phase 4: Connection Pool Lifecycle Improvements

### Task 4.1: Extend pool options and add eviction

**Files:**
- Read: `src/sql/pool.zig`
- Modify: `src/sql/pool.zig`
- Test: add unit tests in `src/sql/pool.zig` or `tests/integration/pool.zig`

**Interfaces:**
- Consumes: existing `ConnPool`
- Produces: `Options` with lifecycle fields; evict-on-borrow/release behavior

- [ ] **Step 1: Add lifecycle options**

In `src/sql/pool.zig`, update `Options`:

```zig
pub const Options = struct {
    min_connections: usize = 1,
    max_connections: usize = 8,
    health_check_on_borrow: bool = true,
    max_retries: u32 = 3,
    retry_backoff_ms: u32 = 100,
    max_idle_secs: u32 = 300,
    max_lifetime_secs: u32 = 3600,
};
```

- [ ] **Step 2: Record timestamps on entry creation and release**

In `PooledEntry`, add:

```zig
const PooledEntry = struct {
    conn: D,
    created_at: i64,
    idle_since: ?i64,
};
```

Use `std.time.timestamp()` or project helper.

- [ ] **Step 3: Implement eviction in `borrow()`**

Pseudo-code:

```zig
if (entry.idle_since) |idle_since| {
    if (now - idle_since > self.options.max_idle_secs) {
        entry.conn.close();
        continue;
    }
}
if (now - entry.created_at > self.options.max_lifetime_secs) {
    entry.conn.close();
    continue;
}
if (self.options.health_check_on_borrow) {
    conn.ping() catch {
        entry.conn.close();
        continue;
    };
}
```

- [ ] **Step 4: Implement eviction in `release()`**

```zig
if (now - entry.created_at > self.options.max_lifetime_secs) {
    entry.conn.close();
    return;
}
entry.idle_since = now;
self.available.appendAssumeCapacity(entry);
```

- [ ] **Step 5: Add retry/backoff to connection creation**

In `borrow()`, when pool is empty and count < max, create with retries:

```zig
var attempt: u32 = 0;
while (attempt <= self.options.max_retries) : (attempt += 1) {
    const conn = self.options.connect(allocator) catch |err| {
        if (attempt == self.options.max_retries) return error.PoolExhausted;
        std.time.sleep(self.options.retry_backoff_ms * std.time.ns_per_ms * (attempt + 1));
        continue;
    };
    // ... create entry and append ...
    break;
}
```

- [ ] **Step 6: Add unit tests**

Add tests in `src/sql/pool.zig` or `tests/integration/pool.zig`. For example, create a fake driver with a `close()` counter and verify that `release()` closes connections exceeding max lifetime.

If the existing pool tests cover basic behavior, add focused tests for:
- health check failure on borrow closes connection
- max lifetime eviction on release

- [ ] **Step 7: Run tests**

Run: `zig build test && zig build test-integration`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add src/sql/pool.zig tests/integration/pool.zig
git commit -m "feat(pool): health check, idle/lifetime eviction, create retries"
```

---

## Final Verification

- [ ] Run `zig fmt --check src examples tests build.zig`
- [ ] Run `zig build test`
- [ ] Run `zig build test-integration`
- [ ] Run `zig build migrate` and `zig build migrate-rollback` (sanity check from previous feature)
- [ ] Run `zig build run-start` and `zig build run-complex` (sanity check)

## Spec Coverage Check

| Spec Section | Implementing Task |
|---|---|
| Database-level cascade delete/update | Task 1.1 |
| EXPLAIN integration | Task 3.1 |
| Connection pool lifecycle | Task 4.1 |
| Optimistic locking | Task 2.1, 2.2 |

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-22-cascade-explain-pool-optimistic-lock-plan.md`.**

Two execution options:

1. **Subagent-Driven (recommended)** - Dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
