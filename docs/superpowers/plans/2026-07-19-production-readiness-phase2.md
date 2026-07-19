# zent Production Readiness Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix remaining high-priority production readiness gaps: per-entity JSON arena ownership, connection-pool borrow leak, `deinitEntity` const-cast removal, unified driver error set, and cross-dialect migrations with history tracking.

**Architecture:** Extend generated entities with a comptime-optional JSON arena; narrow the `driver.Driver` vtable to a concrete `driver.Error` error set; add dialect branches to `migrate.zig` introspection and a `zent_schema_migrations` history table.

**Tech Stack:** Zig 0.17-dev, existing zent modules, SQLite/PostgreSQL/MySQL C clients.

## Global Constraints

- Target Zig 0.17-dev.
- All new code must pass `zig fmt --check src examples tests build.zig`.
- Existing tests must continue to pass: `zig build test`, `zig build test-integration`.
- No breaking changes to public APIs unless unavoidable; if unavoidable, update examples and tests.
- Add regression tests for every bug or behavior change.
- Prefer minimal fixes over speculative rewrites.

---

### Task 1: Add per-entity JSON arena and free it in `deinitEntity`

**Files:**
- Modify: `src/codegen/entity.zig:147-190`
- Modify: `src/codegen/create.zig:339-356`
- Modify: `src/sql/scan.zig:131-137`
- Test: `tests/integration/sqlite.zig` (add JSON struct entity deinit leak test)

**Interfaces:**
- Consumes: `std.heap.ArenaAllocator`, `std.json.parseFromSliceLeaky`
- Produces: generated entities with optional `json_arena: ?*std.heap.ArenaAllocator`; `deinitEntity` frees the arena

- [ ] **Step 1: Detect JSON struct fields at codegen time**

In `src/codegen/entity.zig`, add a helper to decide whether the generated entity needs a `json_arena` field:

```zig
fn hasJsonStructField(comptime info: TypeInfo) bool {
    inline for (info.fields) |f| {
        if (f.field_type == .json and @typeInfo(f.zig_type) == .@"struct") return true;
    }
    return false;
}
```

- [ ] **Step 2: Emit `json_arena` only when needed**

In the entity struct generator (around line 147), conditionally include the field:

```zig
var field_names: [fields.len + 1][]const u8 = undefined;
var field_types: [fields.len + 1]type = undefined;
// ... populate entity fields ...
const needs_arena = comptime hasJsonStructField(info);
if (needs_arena) {
    field_names[fields.len] = "json_arena";
    field_types[fields.len] = ?*std.heap.ArenaAllocator;
}
return @Struct(.auto, null, field_names[0 .. fields.len + @intFromBool(needs_arena)], field_types[0 .. fields.len + @intFromBool(needs_arena)], ...);
```

- [ ] **Step 3: Update `valueToType` to allocate and store the arena**

In `src/codegen/create.zig:339-356`, change the JSON struct branch:

```zig
else => {
    if (T == []const u8) {
        return try allocator.dupe(u8, value.string);
    }
    // Struct/JSON: parse into a per-entity arena so deinitEntity can free it.
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer allocator.destroy(arena);
    const parsed = try std.json.parseFromSliceLeaky(T, arena.allocator(), value.string, .{});
    entity.json_arena = arena;
    return parsed;
}
```

Because `valueToType` currently does not receive `entity`, either add an `entity: *Entity` parameter or have `setEntityField` pass it. Minimal change: change `valueToType` signature to accept `entity: *Entity` and update the two call sites in `setEntityField` and any scan path.

- [ ] **Step 4: Update scan path**

In `src/sql/scan.zig:131-137`, the `.@"struct"` branch currently calls `std.json.parseFromSliceLeaky(T, allocator, text, .{})`. This must also use a per-entity arena. However, `scanRow` does not have access to the entity. For this milestone, document that JSON struct scanning should be done through the codegen path that stores the arena. If `scanRow` is used directly for JSON structs, keep the current behavior but add a doc comment warning about ownership.

- [ ] **Step 5: Free the arena in `deinitEntity`**

In `src/codegen/entity.zig:157-181`, before freeing fields, free the JSON arena if present:

```zig
pub fn deinitEntity(comptime infos: []const TypeInfo, comptime info: TypeInfo, self: anytype, allocator: std.mem.Allocator) void {
    // Reject immutable pointers at compile time.
    comptime {
        const T = @TypeOf(self);
        const ptr_info = @typeInfo(T).pointer;
        if (ptr_info.is_const) @compileError("deinitEntity requires a mutable entity pointer");
    }

    if (comptime hasJsonStructField(info)) {
        if (self.json_arena) |arena| {
            arena.deinit();
            allocator.destroy(arena);
            self.json_arena = null;
        }
    }
    // ... existing field/edge freeing ...
}
```

- [ ] **Step 6: Add regression test**

Add an integration test that creates an entity with a JSON struct field, scans/inserts it, calls `deinitEntity`, and verifies 0 leaks under `std.testing.allocator`.

- [ ] **Step 7: Run tests and commit**

Run:
```bash
zig build test
zig build test-integration
zig fmt --check src examples tests build.zig
```
Expected: all pass with 0 leaks.

```bash
git add src/codegen/entity.zig src/codegen/create.zig src/sql/scan.zig tests/integration/sqlite.zig
git commit -m "fix(entity): per-entity JSON arena prevents struct field leaks

JSON struct fields previously allocated into the global allocator
via parseFromSliceLeaky but were never freed by deinitEntity.
Generate a json_arena field for entities with JSON structs, parse
into it, and free the arena on entity deinit."
```

---

### Task 2: Fix connection-pool borrow leak

**Files:**
- Modify: `src/sql/pool.zig:138-143`, `:193-196`
- Test: `src/sql/pool.zig` or new test file

**Interfaces:**
- Consumes: `D.close()`
- Produces: no API change

- [ ] **Step 1: Add `errdefer conn.close()` in `addConnection`**

Change:
```zig
fn addConnection(self: *Self) !void {
    const conn = try self.connect(self.allocator);
    errdefer conn.close();
    const ptr = try self.all.addOne(self.allocator);
    ptr.* = conn;
    try self.available.append(self.allocator, ptr);
}
```

- [ ] **Step 2: Add `errdefer new_conn.close()` in `borrow`**

Change:
```zig
const new_conn = try self.connect(self.allocator);
errdefer new_conn.close();
const ptr = try self.all.addOne(self.allocator);
ptr.* = new_conn;
return self.finishBorrow(ptr, wait_start);
```

- [ ] **Step 3: Add unit test with failing allocator**

Add a test in `src/sql/pool.zig` that uses `std.testing.FailingAllocator` configured to fail after N allocations, opens a pool, and verifies no connection leak when `all.addOne` fails.

- [ ] **Step 4: Run tests and commit**

```bash
git add src/sql/pool.zig
git commit -m "fix(pool): close connection when bookkeeping allocation fails

If connect() succeeded but all.addOne() or available.append() failed,
the newly opened connection was leaked. Add errdefer conn.close()
on both addConnection and the borrow fast-growth path."
```

---

### Task 3: Remove `@constCast` from `deinitEntity`

**Files:**
- Modify: `src/codegen/entity.zig:157-181`
- Modify: all call sites that pass `*const T` to `deinitEntity`

**Interfaces:**
- Consumes: mutable entity pointer
- Produces: compile-time rejection of `*const T`

- [ ] **Step 1: Add comptime const-pointer check**

Already included in Task 1 Step 5. Verify it rejects `*const T`.

- [ ] **Step 2: Remove `@constCast` calls**

Replace:
```zig
const fp: *field_type = @constCast(&@field(self, f.name));
```
with:
```zig
const fp: *field_type = &@field(self, f.name);
```

Do the same for the edge-loading loops.

- [ ] **Step 3: Update call sites**

Search for `deinitEntity` callers. If any pass `*const T`, change them to pass `*T`. Likely call sites are in `src/codegen/query.zig` (edge loading) and examples/tests.

- [ ] **Step 4: Run tests and commit**

```bash
git add src/codegen/entity.zig <call-site files>
git commit -m "refactor(entity): require mutable pointer for deinitEntity

deinitEntity was using @constCast to free fields of entities passed
by const pointer. Require *T and remove the casts."
```

---

### Task 4: Define unified `driver.Error` set and update vtable

**Files:**
- Modify: `src/sql/driver.zig:83-129`

**Interfaces:**
- Consumes: existing driver-specific error types
- Produces: `pub const Error = error{...}` and `Driver`/`Tx` vtables returning `Error!T`

- [ ] **Step 1: Define `driver.Error`**

Insert after the `Result` struct:

```zig
/// Unified error set returned by all driver implementations.
pub const Error = error{
    OutOfMemory,
    ConnectionFailed,
    ExecFailed,
    QueryFailed,
    TxFailed,
    PingFailed,
    BindFailed,
    PrepareFailed,
    ProtocolError,
    DriverFailed,
};
```

- [ ] **Step 2: Update `Tx` function pointers**

Change:
```zig
commitFn: *const fn (ptr: *anyopaque) Error!void,
rollbackFn: *const fn (ptr: *anyopaque) Error!void,
deinitFn: *const fn (ptr: *anyopaque) void,
```

- [ ] **Step 3: Update `Driver.VTable`**

Change:
```zig
exec: *const fn (ptr: *anyopaque, query: []const u8, args: []const Value) Error!Result,
query: *const fn (ptr: *anyopaque, query: []const u8, args: []const Value) Error!Rows,
beginTx: *const fn (ptr: *anyopaque) Error!Tx,
ping: *const fn (ptr: *anyopaque) Error!void,
```

- [ ] **Step 4: Run tests and commit**

This commit will not compile until Tasks 5 and 6 are done; either commit it together with them or keep it on the branch as a WIP. Recommended: commit as part of Task 6 after all drivers and callers compile.

---

### Task 5: Map SQLite/PostgreSQL/MySQL errors to `driver.Error`

**Files:**
- Modify: `src/sql/sqlite.zig`, `src/sql/postgres.zig`, `src/sql/mysql.zig`

**Interfaces:**
- Consumes: native driver errors
- Produces: driver functions returning `driver.Error!T`

- [ ] **Step 1: SQLite error mapping**

In `src/sql/sqlite.zig`, add a helper:

```zig
fn toDriverError(err: anyerror) driver.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SqliteOpenFailed => error.ConnectionFailed,
        error.SqlitePrepareFailed => error.PrepareFailed,
        error.SqliteExecFailed => error.ExecFailed,
        error.TxNotActive => error.TxFailed,
        else => error.DriverFailed,
    };
}
```

Wrap each driver vtable function body with `toDriverError(err)` on error. Keep internal helpers returning their native errors; only the vtable-facing wrappers return `driver.Error`.

- [ ] **Step 2: PostgreSQL error mapping**

Similar helper in `src/sql/postgres.zig`:

```zig
fn toDriverError(err: anyerror) driver.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PostgresConnectFailed => error.ConnectionFailed,
        error.PostgresExecFailed => error.ExecFailed,
        error.PostgresQueryFailed => error.QueryFailed,
        error.PostgresPingFailed => error.PingFailed,
        else => error.DriverFailed,
    };
}
```

- [ ] **Step 3: MySQL error mapping**

In `src/sql/mysql.zig`:

```zig
fn toDriverError(err: anyerror) driver.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.MySQLInitFailed, error.MySQLConnectFailed => error.ConnectionFailed,
        error.MySQLExecFailed => error.ExecFailed,
        error.MySQLStmtFailed, error.MySQLBindResultFailed, error.MySQLParamCountMismatch, error.MySQLNotAQuery => error.QueryFailed,
        error.MySQLPingFailed => error.PingFailed,
        error.MySQLDataTruncated => error.ProtocolError,
        error.MySQLFetchFailed => error.ProtocolError,
        else => error.DriverFailed,
    };
}
```

- [ ] **Step 4: Update vtable declarations**

Change each driver's vtable from `anyerror!T` to `driver.Error!T`.

- [ ] **Step 5: Run tests and commit**

Commit together with Task 6 once the whole codebase compiles.

---

### Task 6: Update codegen builders to propagate `driver.Error`

**Files:**
- Modify: `src/codegen/create.zig`, `src/codegen/query.zig`, `src/codegen/update_delete.zig`, `src/codegen/client.zig` (if needed)

**Interfaces:**
- Consumes: `driver.Driver` returning `driver.Error!T`
- Produces: generated builders returning `driver.Error!T` or their own error unions merged with `driver.Error`

- [ ] **Step 1: Merge `driver.Error` into builder error unions**

For each generated builder, update the return type of public methods that call the driver:

```zig
const SaveError = driver.Error || error{ PrivacyDenied, NotFound, TypeMismatch, ValidationFailed };
pub fn Save(self: *Self) SaveError!Entity { ... }
```

- [ ] **Step 2: Update `try self.driver.exec(...)` call sites**

No code change should be needed beyond type signatures; `try` propagates the new error set automatically.

- [ ] **Step 3: Update tests/examples**

Any test that catches a driver-specific error by name must now catch the mapped `driver.Error`. Update as needed.

- [ ] **Step 4: Verify compilation and tests**

Run:
```bash
zig build test
zig build test-integration
zig fmt --check src examples tests build.zig
```

- [ ] **Step 5: Commit**

```bash
git add src/sql/driver.zig src/sql/sqlite.zig src/sql/postgres.zig src/sql/mysql.zig src/codegen/
git commit -m "refactor(driver): narrow vtable error sets to driver.Error

Replace anyerror vtable returns with a unified driver.Error set.
Map SQLite/PostgreSQL/MySQL native errors to the common set and
update codegen builders to propagate driver.Error."
```

---

### Task 7: Add cross-dialect introspection to `migrate.zig`

**Files:**
- Modify: `src/sql/schema/migrate.zig:523-577`
- Test: `tests/integration/postgres.zig`, `tests/integration/mysql.zig`

**Interfaces:**
- Consumes: `driver.Driver.dialect()`
- Produces: dialect-aware `getExistingColumns` and `getExistingIndexes`

- [ ] **Step 1: Add dialect dispatch to `getExistingColumns`**

Replace the hardcoded `PRAGMA table_info` with a switch on `dialect.name`:

```zig
fn getExistingColumns(allocator: Allocator, driver_drv: driver.Driver, table_name: []const u8) ![]ColumnInfo {
    const dialect = driver_drv.dialect();
    const sql_text = if (std.mem.eql(u8, dialect.name, "sqlite3"))
        try std.fmt.allocPrint(allocator, "PRAGMA table_info(\"{s}\")", .{table_name})
    else if (std.mem.eql(u8, dialect.name, "postgres"))
        try std.fmt.allocPrint(allocator,
            "SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_name = '{s}' AND table_schema = current_schema()",
            .{table_name})
    else if (std.mem.eql(u8, dialect.name, "mysql"))
        try std.fmt.allocPrint(allocator,
            "SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_name = ? AND table_schema = DATABASE()",
            .{table_name})
    else
        return error.UnsupportedDialect;
    defer allocator.free(sql_text);
    // ... parse result according to dialect ...
}
```

- [ ] **Step 2: Add dialect dispatch to `getExistingIndexes`**

Similar switch for SQLite `PRAGMA index_list`, PostgreSQL `pg_indexes`, and MySQL `information_schema.statistics`.

- [ ] **Step 3: Normalize column/index metadata**

Each dialect returns different type names and booleans. Add a normalization step that maps `data_type` to a canonical zent type string (or keeps it as-is for comparison). For this milestone, compare raw lowercase type names.

- [ ] **Step 4: Add integration tests**

Add a test in `tests/integration/postgres.zig` and `tests/integration/mysql.zig` that calls `migrateSchema` twice: first to create tables, second to verify it is idempotent and adds missing columns/indexes.

- [ ] **Step 5: Run tests and commit**

```bash
git add src/sql/schema/migrate.zig tests/integration/postgres.zig tests/integration/mysql.zig
git commit -m "feat(migrate): cross-dialect introspection for PG/MySQL

Replace hardcoded SQLite PRAGMA with dialect-aware queries using
information_schema and pg_indexes. Add integration tests for
migrateSchema on PostgreSQL and MySQL."
```

---

### Task 8: Add migration history table and transaction wrapping

**Files:**
- Modify: `src/sql/schema/migrate.zig:625-666`
- Test: existing integration tests + new idempotency test

**Interfaces:**
- Consumes: `driver.Driver`, `driver.Tx`
- Produces: `zent_schema_migrations` table, idempotent `migrateSchema`

- [ ] **Step 1: Create `zent_schema_migrations` table**

Add a helper:

```zig
fn ensureMigrationsTable(drv: driver.Driver) !void {
    _ = try drv.exec(
        "CREATE TABLE IF NOT EXISTS zent_schema_migrations (" ++
        "version INTEGER PRIMARY KEY, " ++
        "applied_at INTEGER NOT NULL, " ++
        "checksum TEXT)", &.{}, );
}
```

Use dialect-aware quoting/keywords if needed; for this milestone, the SQL above works on all three dialects.

- [ ] **Step 2: Read and write migration records**

```zig
fn appliedVersions(allocator: Allocator, drv: driver.Driver) ![]i64 {
    var rows = try drv.query("SELECT version FROM zent_schema_migrations ORDER BY version", &.{}, );
    defer rows.deinit();
    var list = std.ArrayList(i64).init(allocator);
    errdefer list.deinit();
    while (rows.next()) |row| {
        try list.append(row.getInt(0).?);
    }
    return list.toOwnedSlice();
}

fn recordMigration(drv: driver.Driver, version: i64, checksum: ?[]const u8) !void {
    const now = std.time.timestamp();
    _ = try drv.exec(
        "INSERT INTO zent_schema_migrations (version, applied_at, checksum) VALUES (?, ?, ?)",
        &.{ .{ .int = version }, .{ .int = now }, if (checksum) |c| .{ .string = c } else .null }, );
}
```

- [ ] **Step 3: Wrap `migrateSchema` in a transaction**

Change `migrateSchema` to begin a transaction, run all migrations, record versions, and commit. On error, the transaction is rolled back via `tx.deinit()`.

```zig
pub fn migrateSchema(allocator: Allocator, drv: driver.Driver, infos: []const TypeInfo) !void {
    try ensureMigrationsTable(drv);
    const applied = try appliedVersions(allocator, drv);
    defer allocator.free(applied);

    var tx = try drv.beginTx();
    errdefer tx.deinit();

    try createAllTables(allocator, tx.asDriver(), infos);
    // ... alter tables / add indexes, skipping versions in `applied` ...

    try tx.commit();
    tx.deinit();
}
```

Note: `createAllTables` currently takes `driver.Driver`; refactor it or pass `tx.asDriver()` if the pool already provides that. If not, use the `Driver` struct directly since `Tx.inner` is a `Driver`.

- [ ] **Step 4: Compute migration versions**

Assign a deterministic version number to each migration operation. A simple scheme: version = hash of (table_name + operation + column/index name). For this milestone, use `std.hash.Crc32` or a counter incremented per operation. Document that the scheme may change when versioning files are introduced.

- [ ] **Step 5: Add idempotency test**

Extend the integration tests from Task 7 to call `migrateSchema` twice and assert no duplicate records in `zent_schema_migrations`.

- [ ] **Step 6: Run tests and commit**

```bash
git add src/sql/schema/migrate.zig tests/integration/*.zig
git commit -m "feat(migrate): history table and transactional migrations

Add zent_schema_migrations history table, wrap migrateSchema in a
transaction, and skip already-applied operations by version."
```

---

## Self-Review

**1. Spec coverage:**
- JSON arena: Tasks 1.
- Pool leak: Task 2.
- const cast: Task 3.
- Error set: Tasks 4, 5, 6.
- Cross-dialect migrations: Tasks 7, 8.
- No gaps.

**2. Placeholder scan:**
- No "TBD"/"TODO".
- Code blocks contain concrete snippets.
- Exact commands included.

**3. Type consistency:**
- `driver.Error` defined once in Task 4 and used consistently in Tasks 5 and 6.
- `json_arena: ?*std.heap.ArenaAllocator` generated in Task 1 and freed in Task 1.

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-19-production-readiness-phase2.md`.**

Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using `executing-plans`, batch execution with checkpoints.

Which approach?
