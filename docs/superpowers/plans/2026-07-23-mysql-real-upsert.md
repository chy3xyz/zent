# MySQL Real Upsert Semantics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change MySQL `SaveOrUpdate` from `REPLACE INTO` to `INSERT ... ON DUPLICATE KEY UPDATE` so existing rows are updated in place rather than deleted and re-inserted.

**Architecture:** Extend `buildUpsertSuffix` in `src/codegen/create.zig` to generate a MySQL-specific `ON DUPLICATE KEY UPDATE` suffix. Update the MySQL execution path to append this suffix to a normal `INSERT` statement instead of replacing the keyword with `REPLACE`. Keep PostgreSQL and SQLite behavior unchanged. Add a MySQL integration test that proves the auto-increment id is preserved and child rows are not cascaded-deleted.

**Tech Stack:** Zig 0.17-dev, existing `zent.codegen.create`, `zent.sql.builder`, MySQL/MariaDB driver.

## Global Constraints

- Target Zig 0.17-dev.
- All public APIs keep the existing fluent/chainable style.
- Every allocation must have a matching `defer`/`errdefer` per project conventions.
- Tests must use `std.testing.allocator`.
- Run `zig fmt --check src examples tests build.zig` before each commit.
- Run `zig build test` and `zig build test-integration` before claiming done.

---

## Task 1: Generate MySQL Upsert Suffix

**Files:**
- Modify: `src/codegen/create.zig:404-417`

**Interfaces:**
- Consumes: `or_replace: bool`, `is_postgres: bool`, `is_sqlite: bool`, `columns: []const []const u8`
- Produces: `upsert_suffix: []const u8` containing ` ON DUPLICATE KEY UPDATE ...` for MySQL when `or_replace` is true

- [ ] **Step 1: Update `buildUpsertSuffix` to detect MySQL**

In `src/codegen/create.zig`, change the function signature to accept `is_mysql: bool`:

```zig
fn buildUpsertSuffix(self: *Self, or_replace: bool, is_postgres: bool, is_sqlite: bool, is_mysql: bool, columns: []const []const u8) ![]const u8 {
```

- [ ] **Step 2: Add MySQL suffix generation**

Inside `buildUpsertSuffix`, replace the early return:

```zig
if (!or_replace or is_sqlite) return "";
```

with:

```zig
if (!or_replace or is_sqlite) return "";
if (is_mysql) {
    var buf = std.array_list.Managed(u8).init(self.allocator);
    errdefer buf.deinit();
    try buf.appendSlice(" ON DUPLICATE KEY UPDATE ");
    var first = true;
    for (columns) |col| {
        if (std.mem.eql(u8, col, "id")) continue;
        if (!first) try buf.appendSlice(", ");
        first = false;
        try buf.print("`{s}`=VALUES(`{s}`)", .{ col, col });
    }
    return try buf.toOwnedSlice();
}
```

- [ ] **Step 3: Update call sites**

Find the call to `buildUpsertSuffix` around line 217 and add the `is_mysql` flag:

```zig
const is_mysql = std.mem.eql(u8, dialect.name, "mysql");
const upsert_suffix: []const u8 = try self.buildUpsertSuffix(or_replace, is_postgres, is_sqlite, is_mysql, columns.items);
```

- [ ] **Step 4: Run unit tests**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/codegen/create.zig
git commit -m "feat(codegen): generate ON DUPLICATE KEY UPDATE suffix for MySQL"
```

---

## Task 2: Use Normal INSERT + Suffix in MySQL SaveOrUpdate

**Files:**
- Modify: `src/codegen/create.zig:279-326`

**Interfaces:**
- Consumes: `upsert_suffix`, normal `sql.Insert` query
- Produces: MySQL `SaveOrUpdate` SQL using `INSERT INTO ... ON DUPLICATE KEY UPDATE ...`

- [ ] **Step 1: Remove REPLACE prefix logic**

In the MySQL path of `saveInternal` (the `else` block starting around line 279), delete:

```zig
const needs_replace_prefix = or_replace;
const insert_keyword = "INSERT";
const replace_keyword = "REPLACE";
```

and:

```zig
const full_sql_len = q.sql.len + if (needs_replace_prefix) @as(usize, replace_keyword.len - insert_keyword.len) else 0;
const full_sql = try self.allocator.alloc(u8, full_sql_len);
defer self.allocator.free(full_sql);
if (needs_replace_prefix) {
    @memcpy(full_sql[0..replace_keyword.len], replace_keyword);
    @memcpy(full_sql[replace_keyword.len..], q.sql[insert_keyword.len..]);
} else {
    @memcpy(full_sql[0..q.sql.len], q.sql);
}
```

- [ ] **Step 2: Build INSERT + suffix SQL**

Replace the deleted block with:

```zig
const full_sql_len = q.sql.len + upsert_suffix.len;
const full_sql = try self.allocator.alloc(u8, full_sql_len);
defer self.allocator.free(full_sql);
@memcpy(full_sql[0..q.sql.len], q.sql);
@memcpy(full_sql[q.sql.len..], upsert_suffix);
```

- [ ] **Step 3: Verify the RETURNING path also appends suffix for MySQL**

Around line 232, the `supports_returning` branch already appends `upsert_suffix` after `q.sql`. However, MySQL does not support `RETURNING`, so this branch is not taken for MySQL. Confirm the `supports_returning = !std.mem.eql(u8, dialect.name, "mysql")` guard is still in place.

- [ ] **Step 4: Run unit tests**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/codegen/create.zig
git commit -m "feat(codegen): MySQL SaveOrUpdate uses INSERT ... ON DUPLICATE KEY UPDATE"
```

---

## Task 3: MySQL Upsert Semantics Integration Test

**Files:**
- Modify: `tests/integration/mysql.zig`

**Interfaces:**
- Consumes: `MySQLDriver`, `Client`, `schema`, `buildGraph`, `field`
- Produces: new integration test proving auto-increment id preservation and no FK cascade

- [ ] **Step 1: Add the integration test**

Append to `tests/integration/mysql.zig`:

```zig
test "MySQL: SaveOrUpdate preserves auto-increment id and child rows" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const MyUpsertParent = schema("MyUpsertParent", .{
        .fields = &.{
            field.String("name"),
        },
    });
    const MyUpsertChild = schema("MyUpsertChild", .{
        .fields = &.{
            field.Int("parent_id"),
            field.String("label"),
        },
        .edges = &.{
            .{ .name = "parent", .target_name = "MyUpsertParent", .relation = .m2o, .kind = .from, .required = true },
        },
    });

    const graph = comptime buildGraph(&.{ MyUpsertParent, MyUpsertChild });
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS my_upsert_child", &.{}) catch {};
    defer _ = drv.exec("DROP TABLE IF EXISTS my_upsert_parent", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // First SaveOrUpdate: creates the parent row.
    var b1 = try client.my_upsert_parent.Create();
    defer b1.deinit();
    _ = try b1.setFieldValue("id", @as(i64, 1));
    _ = try b1.setFieldValue("name", "alice");
    const parent1 = try b1.SaveOrUpdate();
    defer zent.codegen.deinitEntity(infos, infos[0], &parent1, allocator);
    const original_id = parent1.id;
    try testing.expect(original_id != 0);

    // Insert a child referencing the parent.
    var cb = try client.my_upsert_child.Create();
    defer cb.deinit();
    _ = try cb.setFieldValue("parent_id", original_id);
    _ = try cb.setFieldValue("label", "child-of-alice");
    _ = try cb.Save();

    // Second SaveOrUpdate with the same unique key: should UPDATE in place.
    var b2 = try client.my_upsert_parent.Create();
    defer b2.deinit();
    _ = try b2.setFieldValue("id", @as(i64, 1));
    _ = try b2.setFieldValue("name", "alice-updated");
    const parent2 = try b2.SaveOrUpdate();
    defer zent.codegen.deinitEntity(infos, infos[0], &parent2, allocator);

    // The id must be preserved (REPLACE INTO would delete and re-insert).
    try testing.expectEqual(original_id, parent2.id);

    // The child row must still exist.
    var rows = try drv.query("SELECT COUNT(*) FROM my_upsert_child WHERE parent_id = ?", &.{.{ .int = original_id }});
    defer rows.deinit();
    const r = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 1), r.getInt(0).?);

    // The parent name must reflect the update.
    var parent_rows = try drv.query("SELECT name FROM my_upsert_parent WHERE id = ?", &.{.{ .int = original_id }});
    defer parent_rows.deinit();
    const pr = parent_rows.next() orelse return error.NoRow;
    try testing.expectEqualStrings("alice-updated", pr.getText(0).?);
}
```

- [ ] **Step 2: Run integration tests**

Run: `zig build test-integration`
Expected: PASS (MySQL tests run if local server is available; otherwise they are skipped)

- [ ] **Step 3: Commit**

```bash
git add tests/integration/mysql.zig
git commit -m "test(integration): MySQL SaveOrUpdate preserves id and child rows"
```

---

## Task 4: Final Verification

- [ ] **Step 1: Run formatting check**

Run: `zig fmt --check src examples tests build.zig`
Expected: PASS

- [ ] **Step 2: Run unit tests**

Run: `zig build test`
Expected: PASS

- [ ] **Step 3: Run integration tests**

Run: `zig build test-integration`
Expected: PASS

- [ ] **Step 4: Run example sanity checks**

Run: `zig build run-start` and `zig build run-complex`
Expected: both PASS

- [ ] **Step 5: Optional commit if any fixes were needed**

If any of the above required changes, commit them. Otherwise no commit is needed.

---

## Spec Coverage Check

| Spec Section | Implementing Task |
|---|---|
| Extend `buildUpsertSuffix` for MySQL | Task 1 |
| Use normal INSERT + suffix in MySQL path | Task 2 |
| Add semantics-preserving integration test | Task 3 |

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-23-mysql-real-upsert.md`.**

Two execution options:

1. **Subagent-Driven (recommended)** - Dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
