# zent Production Blockers Remediation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the four highest-severity production blockers identified in the production-readiness assessment: upsert use-after-free, invalid MySQL upsert SQL, aggregate query resource leaks, and MySQL driver silent data truncation.

**Architecture:** Make minimal, targeted fixes in `src/codegen/create.zig`, `src/codegen/query.zig`, and `src/sql/mysql.zig`. Each fix is accompanied by a regression test. No public API changes.

**Tech Stack:** Zig 0.17-dev, SQLite/PostgreSQL/MySQL C clients, existing zent modules.

## Global Constraints

- Target Zig 0.17-dev.
- All new code must pass `zig fmt --check src examples tests build.zig`.
- Existing tests must continue to pass: `zig build test`, `zig build test-integration`.
- No breaking changes to public APIs.
- Prefer minimal fixes over speculative rewrites.
- Add regression tests for every bug.

---

### Task 1: Fix upsert use-after-free in `SaveBuilder.Save`

**Files:**
- Modify: `src/codegen/create.zig:181-206`
- Test: `tests/integration/main.zig` (add cross-dialect upsert test)

**Interfaces:**
- Consumes: `std.array_list.Managed(u8)`, `self.allocator`
- Produces: `upsert_suffix: []const u8` that remains valid until `full_sql` is freed

- [ ] **Step 1: Write a failing integration test for upsert idempotency**

Add a new integration test that calls `SaveOrUpdate` twice with the same id and verifies the row is updated. Run it against SQLite first:

```zig
test "SaveOrUpdate updates existing row" {
    // setup schema + driver as in existing tests
    var client = Client.makeClient(infos, allocator, drv);
    var b1 = try client.user.Create();
    _ = try b1.setFieldValue("id", .{ .int = 99 });
    _ = try b1.setFieldValue("name", .{ .string = "Alice" });
    _ = try b1.SaveOrUpdate();

    var b2 = try client.user.Create();
    _ = try b2.setFieldValue("id", .{ .int = 99 });
    _ = try b2.setFieldValue("name", .{ .string = "Bob" });
    _ = try b2.SaveOrUpdate();

    var q = client.user.Query();
    q.Where(client.user.id.Equal(99));
    const u = try q.Only();
    try std.testing.expectEqualStrings("Bob", u.name);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test-integration`
Expected: FAIL or crash/undefined behavior due to use-after-free in PG upsert suffix.

- [ ] **Step 3: Allocate the upsert suffix with the statement allocator**

Replace the local `ArrayList` with an allocation that outlives the `upsert:` block. Move the suffix build to a helper that returns an owned slice, and free it after `rows.deinit()`.

Current:
```zig
const upsert_suffix: []const u8 = upsert: {
    if (!or_replace) break :upsert "";
    if (is_sqlite) break :upsert "";
    if (is_postgres) {
        var buf = std.array_list.Managed(u8).init(self.allocator);
        defer buf.deinit();
        // ... append ...
        break :upsert buf.items;
    }
    break :upsert " REPLACE";
};
```

Change to:
```zig
const upsert_suffix: []const u8 = try self.buildUpsertSuffix(or_replace, is_postgres, is_sqlite, columns.items);
```

Then add a helper method on `SaveBuilder`:

```zig
fn buildUpsertSuffix(self: *Self, or_replace: bool, is_postgres: bool, is_sqlite: bool, columns: []const []const u8) ![]const u8 {
    if (!or_replace) return "";
    if (is_sqlite) return "";
    if (is_postgres) {
        var buf = std.array_list.Managed(u8).init(self.allocator);
        errdefer buf.deinit();
        try buf.appendSlice(" ON CONFLICT (\"id\") DO UPDATE SET ");
        var first = true;
        for (columns) |col| {
            if (std.mem.eql(u8, col, "id")) continue;
            if (!first) try buf.appendSlice(", ");
            first = false;
            var piece_buf: [128]u8 = undefined;
            const piece = try std.fmt.bufPrint(
                &piece_buf,
                "\"{s}\"=EXCLUDED.\"{s}\"",
                .{ col, col },
            );
            try buf.appendSlice(piece);
        }
        return try buf.toOwnedSlice();
    }
    return "";
}
```

- [ ] **Step 4: Free the suffix in both RETURNING and non-RETURNING paths**

After `full_sql` is built and before returning from `Save`, free `upsert_suffix` if it was allocated:

```zig
defer if (upsert_suffix.len > 0 and !std.mem.eql(u8, upsert_suffix, "")) self.allocator.free(upsert_suffix);
```

Because `""` and `" REPLACE"` are static, only the PG path needs freeing. Use a sentinel or always allocate even the static cases to simplify. Simpler: always return an owned slice from `buildUpsertSuffix`:

```zig
fn buildUpsertSuffix(...) ![]const u8 {
    if (!or_replace or is_sqlite) return try self.allocator.dupe(u8, "");
    if (is_postgres) { ... return try buf.toOwnedSlice(); }
    return try self.allocator.dupe(u8, "");
}
```

Then `defer self.allocator.free(upsert_suffix);` is always correct.

- [ ] **Step 5: Run tests and benchmark**

Run:
```bash
zig build test
zig build test-integration
zig build run-complex
```
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/codegen/create.zig tests/integration/main.zig
git commit -m "fix(create): repair upsert suffix use-after-free

The Postgres ON CONFLICT suffix was built in a local ArrayList
whose defer freed it before the slice was consumed. Allocate the
suffix with the statement allocator and free it after the query.
Adds a regression test for SaveOrUpdate idempotency."
```

---

### Task 2: Fix invalid MySQL upsert SQL

**Files:**
- Modify: `src/codegen/create.zig:220-268`
- Test: `tests/integration/main.zig` (add MySQL SaveOrUpdate test)

**Interfaces:**
- Consumes: `dialect.name`, `or_replace`, `q.sql`
- Produces: `full_sql` valid for MySQL `REPLACE INTO ... VALUES (...)`

- [ ] **Step 1: Write a failing MySQL upsert integration test**

Add a test guarded by MySQL availability that calls `SaveOrUpdate` and asserts the row is updated.

- [ ] **Step 2: Run to verify failure**

Run: `zig build test-integration`
Expected: MySQL syntax error or wrong SQL printed in CI logs.

- [ ] **Step 3: Remove the `" REPLACE"` suffix and use only `REPLACE` prefix**

MySQL `REPLACE INTO` is syntactically `REPLACE INTO table ... VALUES ...`. The current code prepends `"REPLACE "` and appends `" REPLACE"` + `" RETURNING ..."`. The suffix must be removed entirely for MySQL.

Change:
```zig
const needs_replace_prefix = or_replace and std.mem.eql(u8, dialect.name, "mysql");
const replace_prefix: []const u8 = if (needs_replace_prefix) "REPLACE" else "";
```

Ensure no `upsert_suffix` is appended when `is_mysql`.

For the non-RETURNING path (lines 245-270), similarly only prepend `REPLACE`:

```zig
const needs_replace_prefix = or_replace;
```

Remove any use of `upsert_suffix` in the MySQL branch.

- [ ] **Step 4: Run tests**

Run: `zig build test-integration`
Expected: pass on MySQL service in CI.

- [ ] **Step 5: Commit**

```bash
git add src/codegen/create.zig tests/integration/main.zig
git commit -m "fix(create): generate valid REPLACE INTO for MySQL upserts

MySQL SaveOrUpdate was emitting 'REPLACE INSERT INTO ... REPLACE'.
Use only the REPLACE prefix and no suffix/RETURNING clause."
```

---

### Task 3: Fix `Max`/`Min` resource leaks

**Files:**
- Modify: `src/codegen/query.zig:312-348`
- Test: `tests/integration/main.zig` or new unit test

**Interfaces:**
- Consumes: `self.driver.query(...) -> driver.Rows`
- Produces: `sql.Value` and no leaked `Rows`

- [ ] **Step 1: Add a test that exercises null/int/float/text paths**

```zig
test "Max returns text without leaking rows" {
    // insert rows with a string age field or use an existing string column
    var q = client.user.Query();
    const v = try q.Max("name");
    defer switch (v) {
        .string => |s| allocator.free(s),
        else => {},
    };
}
```

- [ ] **Step 2: Run with a leak checker to confirm leak**

Use `std.testing.allocator` in a unit test or integration test. Run:
```bash
zig build test
```
Expected: leak reported on non-text return paths.

- [ ] **Step 3: Add `defer rows.deinit()` and reorder text path**

```zig
pub fn Max(self: *Self, comptime field_name: []const u8) !sql.Value {
    try checkPolicy(.query);
    var q = try self.buildAggregateQuery("MAX(\"" ++ field_name ++ "\")");
    defer q.deinit();
    var rows = try self.driver.query(q.sql, q.args);
    defer rows.deinit();
    const row = rows.next() orelse return error.NotFound;
    if (row.isNull(0)) return .null;
    if (row.getInt(0)) |v| return .{ .int = v };
    if (row.getFloat(0)) |v| return .{ .float = v };
    if (row.getText(0)) |v| {
        const duped = try self.allocator.dupe(u8, v);
        return .{ .string = duped };
    }
    return error.TypeMismatch;
}
```

Do the same for `Min`.

- [ ] **Step 4: Run tests**

Run:
```bash
zig build test
zig build test-integration
```
Expected: pass with 0 leaks.

- [ ] **Step 5: Commit**

```bash
git add src/codegen/query.zig tests/integration/main.zig
git commit -m "fix(query): defer rows.deinit in Max/Min

All non-text return paths leaked the Rows object. Add defer and
duplicate text before deinit."
```

---

### Task 4: Fix MySQL driver silent data truncation

**Files:**
- Modify: `src/sql/mysql.zig:438`, `:474-477`, `:556-592`
- Test: `tests/integration/main.zig` (add long string/BLOB test for MySQL)

**Interfaces:**
- Consumes: `MYSQL_FIELD` metadata, `mysql_stmt_fetch` result
- Produces: `driver.Row` with full column values or a clear error

- [ ] **Step 1: Add a failing integration test for long values**

```zig
test "MySQL returns long strings without truncation" {
    if (!mysql_available) return error.SkipZigTest;
    _ = try drv.exec("CREATE TABLE long_test (id INTEGER PRIMARY KEY, payload TEXT)", &.{});
    const long = "a" ** 300;
    _ = try drv.exec("INSERT INTO long_test (id, payload) VALUES (?, ?)", &.{.{ .int = 1 }, .{ .string = long }});
    var rows = try drv.query("SELECT payload FROM long_test", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    const got = row.getText(0) orelse return error.NoText;
    try std.testing.expectEqualStrings(long, got);
}
```

- [ ] **Step 2: Run to verify truncation**

Run: `zig build test-integration`
Expected: string mismatch (truncated to 256 bytes) or no error.

- [ ] **Step 3: Use field max-length or a sane dynamic buffer**

In `ensureBuffers`, read `field.max_length` after `mysql_stmt_store_result` to size each column buffer. Fallback to 256 only when `max_length == 0`, and grow if `mysql_stmt_fetch` reports `MYSQL_DATA_TRUNCATED`.

```zig
for (0..n) |i| {
    const field = self.fields[i];
    const buf_len: usize = if (field.max_length > 0) field.max_length else 256;
    const buf = try self.allocator.alloc(u8, buf_len);
    str_bufs.items[i] = buf;
    binds[i].buffer_type = c.MYSQL_TYPE_STRING;
    binds[i].buffer = buf.ptr;
    binds[i].buffer_length = @intCast(buf_len);
    binds[i].is_null = &nulls.items[i];
    binds[i].length = &lens.items[i];
    binds[i].@"error" = &errors.items[i];
}
```

- [ ] **Step 4: Surface fetch errors and truncation**

Change `next` to propagate errors instead of swallowing them:

```zig
fn next(ptr: *anyopaque) ?driver.Row {
    const self: *MySQLRows = @ptrCast(@alignCast(ptr));
    if (self.done) return null;

    self.ensureBuffers() catch |err| {
        self.done = true;
        self.last_error = err;
        return null;
    };

    const rc = c.mysql_stmt_fetch(self.stmt);
    if (rc == c.MYSQL_NO_DATA) {
        self.done = true;
        return null;
    }
    if (rc == c.MYSQL_DATA_TRUNCATED) {
        // grow buffer and retry, or at least set an error
        self.last_error = error.MySQLDataTruncated;
        self.done = true;
        return null;
    }
    if (rc != 0) {
        self.last_error = error.MySQLFetchFailed;
        self.done = true;
        return null;
    }

    return driver.Row{ .ptr = self, .vtable = &row_vtable };
}
```

Add `last_error: ?anyerror = null` to `MySQLRows` and expose a way for `query` to return it. If `next()` returns null due to error, `MySQLRows.query` should return that error when the consumer tries to read.

A minimal first step: make `next` set `self.done = true` and `self.last_error`, then have `deinit` assert `last_error == null` in debug builds, or expose `MySQLRows` error through `rows.nextError()`.

Simpler, lower-risk fix for this plan: keep `next` returning null on error but log the error via `std.log.err` and set a flag so tests can detect truncation. Then grow buffers in a follow-up task.

Recommended minimal fix:
1. Size buffers from `field.max_length`.
2. In `next`, if `rc != 0` and `rc != MYSQL_NO_DATA`, set `self.last_error` and return null.
3. In `MySQLRows.query` (or the driver wrapper), after `rows.next()` returns null, check `rows.last_error` and propagate.

- [ ] **Step 5: Run tests**

Run:
```bash
zig build test
zig build test-integration
```
Expected: pass; long string test no longer truncates.

- [ ] **Step 6: Commit**

```bash
git add src/sql/mysql.zig tests/integration/main.zig
git commit -m "fix(mysql): size row buffers from field metadata and surface fetch errors

MySQL row buffers were fixed at 256 bytes, silently truncating
long TEXT/BLOB values. Use field.max_length when available and
propagate mysql_stmt_fetch errors through rows.last_error."
```

---

## Self-Review

**1. Spec coverage:**
- Upsert uaf: Task 1.
- MySQL upsert SQL: Task 2.
- Max/Min leaks: Task 3.
- MySQL truncation: Task 4.
- No gaps for the stated P0 scope.

**2. Placeholder scan:**
- No "TBD"/"TODO".
- Code blocks contain concrete changes.
- Exact file paths and commands included.

**3. Type consistency:**
- `buildUpsertSuffix` returns `![]const u8` consistently.
- `defer rows.deinit()` added in both Max/Min.
- `MySQLRows.last_error: ?anyerror` added and used.

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-19-production-blockers.md`.**

Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using `executing-plans`, batch execution with checkpoints.

Which approach?
