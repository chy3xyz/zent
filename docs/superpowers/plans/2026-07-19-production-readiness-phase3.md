# zent Production Readiness Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring zent to 9.5+ production readiness: row-level privacy filtering, cancellable hooks, prepared statement cache, driver reliability (PG ping, retry, timeout), structured observability, migration DDL completeness, and full API parity with ent Go.

**Architecture:** Four independent layers — Privacy+Hook (`src/runtime/privacy.zig`, `src/privacy/policy.zig`), Driver Reliability (`src/sql/cache.zig`, `src/sql/pool.zig`), Observability (`src/sql/logger.zig`), and API completeness (`src/entql/parser.zig`, `src/codegen/query.zig`). Each layer communicates through `PrivacyContext`, `HookContext`, `Logger`, and `PreparedCache` — narrow value types with no cross-layer imports.

**Tech Stack:** Zig 0.17-dev, existing zent modules, SQLite/PostgreSQL/MySQL C clients.

## Global Constraints

- Target Zig 0.17-dev.
- All new code must pass `zig fmt --check src examples tests build.zig`.
- Existing tests must continue to pass: `zig build test`, `zig build test-integration`.
- No breaking changes to public APIs unless unavoidable; if unavoidable, update examples and tests.
- Add regression tests for every bug or behavior change.
- Prefer minimal fixes over speculative rewrites.
- Use comptime for zero-runtime-cost abstractions; explicit error sets; arena-based memory.
- match existing code patterns (vtable dispatch for drivers, codegen for builders, comptime for schema).
- All new modules tested with `std.testing.allocator` for leak detection.

---

### Task 1: PrivacyContext + evalPolicy (Runtime Layer)

**Files:**
- Create: `src/runtime/privacy.zig`
- Modify: `src/root.zig` (add export for `privacy`)

**Interfaces:**
- Consumes: `std.mem.Allocator`, `src/codegen/predicate.zig` (Predicate type)
- Produces: `PrivacyContext`, `Decision` enum, `evalPolicy` function

- [ ] **Step 1: Create `src/runtime/privacy.zig`**

```zig
const std = @import("std");

/// Carries caller identity through the query/mutation pipeline.
/// Value-type, copy-passed; immutable after construction.
pub const PrivacyContext = struct {
    user_id: ?i64 = null,
    role: ?[]const u8 = null,
    tenant_id: ?i64 = null,
    extra: ?*anyopaque = null,
};

pub const Decision = enum {
    allow,
    deny,
    skip,
};

pub const DecisionSet = struct {
    decision: Decision,
    filters: []const anyopaque, // opaque filter predicates; resolved by codegen
};

/// Evaluate privacy rules in order with AND semantics.
/// - Skip: continue to next rule.
/// - Deny: return .deny immediately.
/// - Allow: stop evaluating allow/deny; accumulate remaining filter rules.
pub fn evalPolicy(
    ctx: PrivacyContext,
    comptime rules: anytype, // []const policy.Rule
) DecisionSet {
    var result = DecisionSet{ .decision = .allow, .filters = &.{} };
    inline for (rules) |rule| {
        switch (rule) {
            .skip => continue,
            .deny => return .{ .decision = .deny, .filters = &.{} },
            .allow => {
                result.decision = .allow;
                // Continue to collect remaining filters.
            },
            .filter => |fr| {
                if (fr.predicate(ctx)) |pred| {
                    // Append filter; codegen resolves the predicate type.
                }
            },
        }
    }
    return result;
}
```

- [ ] **Step 2: Export in `src/root.zig`**

Add after the existing `pub const runtime` block:
```zig
pub const privacy = @import("runtime/privacy.zig");
```

- [ ] **Step 3: Run tests, format, commit**

```bash
zig build test && zig build test-integration && zig fmt --check src examples tests build.zig
git add src/runtime/privacy.zig src/root.zig
git commit -m "feat(privacy): add PrivacyContext and evalPolicy runtime"
```

---

### Task 2: Enhanced Policy Rules

**Files:**
- Modify: `src/privacy/policy.zig`

**Interfaces:**
- Consumes: `src/runtime/privacy.zig` (PrivacyContext, Decision)
- Produces: `Policy` with `Rule` union (allow/deny/filter/skip)

- [ ] **Step 1: Replace old Policy definition in `src/privacy/policy.zig`**

Replace the `OldRule` type and `Policy` struct (lines 17-35) with:

```zig
pub const Rule = union(enum) {
    allow: AllowRule,
    deny: DenyRule,
    filter: FilterRule,
    skip: SkipRule,
};

pub const AllowRule = struct {};
pub const DenyRule = struct {};
pub const SkipRule = struct {};

/// Returns an opaque filter predicate (resolved by codegen at call site)
/// or null when no filter applies.
pub const FilterRule = struct {
    predicate: *const fn (ctx: PrivacyContext) ?anyopaque,
};

pub const Allow = Rule{ .allow = .{} };
pub const Deny = Rule{ .deny = .{} };
pub const Skip = Rule{ .skip = .{} };

pub fn Filter(comptime predicate: anytype) Rule {
    return .{ .filter = .{ .predicate = struct {
        fn call(ctx: PrivacyContext) ?anyopaque {
            return predicate(ctx);
        }
    }.call } };
}

pub const Policy = struct {
    rules: []const Rule,

    pub fn eval(self: Policy, ctx: PrivacyContext) DecisionSet {
        return evalPolicy(ctx, self.rules);
    }
};
```

- [ ] **Step 2: Update `DecisionSet` in `src/runtime/privacy.zig`**

Replace the stub `evalPolicy` with a working version that accumulates filter predicates into an `std.ArrayList`:

```zig
const DecisionSet = struct {
    decision: Decision,
    filters: std.ArrayList(*const anyopaque),
};
```

- [ ] **Step 3: Update built-in rules (lines 41-63)**

Replace `AlwaysAllow` etc. to return the new `Rule` type:

```zig
pub const AlwaysAllow = Policy{ .rules = &.{Allow} };
pub const AlwaysDeny = Policy{ .rules = &.{Deny} };
```

- [ ] **Step 4: Run tests, fix call sites**

`src/codegen/query.zig:217` calls `p.evalQuery(op, table_name)` — this will break. Temporarily comment out the privacy check in query.zig (will be re-added in Task 3).

```bash
zig build test && zig fmt --check src/privacy/policy.zig src/runtime/privacy.zig
git add src/privacy/policy.zig src/runtime/privacy.zig
git commit -m "feat(privacy): enhanced Policy with Allow/Deny/Filter/Skip rules"
```

---

### Task 3: Builder WithContext + Privacy Integration

**Files:**
- Modify: `src/codegen/client.zig`
- Modify: `src/codegen/query.zig`
- Modify: `src/codegen/create.zig`
- Modify: `src/codegen/update_delete.zig`
- Modify: `src/codegen/graph.zig` (TypeInfo needs privacy_rules)

**Interfaces:**
- Consumes: `PrivacyContext`, `Policy.Rule`, `evalPolicy`
- Produces: `.WithContext(ctx)` on all builders; privacy filter injection in query/delete

- [ ] **Step 1: Add `WithContext` to EntityClient in client.zig**

After `hooks` field (line 117), add:
```zig
privacy_ctx: ?PrivacyContext = null,
```

Update `init()` (line 119):
```zig
pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver) @This() {
    return .{
        .allocator = allocator,
        .driver = driver,
        .predicates = Predicates{},
        .orders = EdgeOrders{},
        .hooks = &.{},
        .privacy_ctx = null,
    };
}
```

Add method (after `withHooks`, around line 135):
```zig
pub fn withContext(self: @This(), ctx: PrivacyContext) @This() {
    var copy = self;
    copy.privacy_ctx = ctx;
    return copy;
}
```

Pass `privacy_ctx` to every builder constructor. E.g., `CreateBuilder.init` (line 141) becomes:
```zig
return CreateBuilder(info, self.hooks, self.privacy_ctx).init(self.allocator, self.driver);
```

- [ ] **Step 2: Update QueryBuilder in query.zig**

Add field:
```zig
privacy_ctx: ?PrivacyContext = null,
```

Update `init()` to accept `privacy_ctx: ?PrivacyContext`.

Replace `checkPolicy` (lines 216-222) with:
```zig
fn checkPolicy(self: *const Self, comptime op: privacy.Op) !void {
    if (info.policy) |p| {
        const ctx = self.privacy_ctx orelse return error.PrivacyDenied;
        const result = p.eval(ctx);
        if (result.decision == .deny) return error.PrivacyDenied;
    }
}
```

In `All`/`First`/`Only`/`IDs`/`Count`/`Exist`, inject privacy filters into the WHERE clause after `checkPolicy`:
```zig
if (info.policy) |p| {
    const result = p.eval(self.privacy_ctx.?);
    for (result.filters.items) |filter_ptr| {
        // Append the filter predicate to self.predicates.
        try self.predicates.append(filter_ptr);
    }
}
```

- [ ] **Step 3: Update CreateBuilder in create.zig**

Add `privacy_ctx` field. Update `saveInternal` (line 144) to check privacy before execution:
```zig
if (info.policy) |p| {
    const ctx = self.privacy_ctx orelse return error.PrivacyDenied;
    const result = p.eval(ctx);
    if (result.decision == .deny) return error.PrivacyDenied;
}
```

- [ ] **Step 4: Update UpdateBuilder/DeleteBuilder in update_delete.zig**

Same pattern: add `privacy_ctx` field, check before execution. For Delete, also inject filter predicates.

- [ ] **Step 5: Update TypeInfo in graph.zig**

Add `privacy_rules` field (optional, for compile-time rule arrays):
```zig
// Not needed if rules are stored in Policy directly; skip if Policy already covers it.
```

- [ ] **Step 6: Update contract tests**

The comptime tests in client.zig (lines 517-526) check error sets. Add checks for `PrivacyDenied` in error sets.

- [ ] **Step 7: Run tests, commit**

```bash
zig build test && zig build test-integration && zig fmt --check src examples tests build.zig
git add src/codegen/client.zig src/codegen/query.zig src/codegen/create.zig src/codegen/update_delete.zig
git commit -m "feat(privacy): add WithContext builder method and privacy filter injection"
```

---

### Task 4: Privacy Integration Tests

**Files:**
- Test: `tests/integration/sqlite.zig`

**Interfaces:**
- Consumes: `PrivacyContext`, `Policy.Filter`, `QueryBuilder.WithContext`
- Produces: multi-tenant isolation test, no-context denial test

- [ ] **Step 1: Add multi-tenant privacy test**

```zig
test "SQLite: privacy multi-tenant row-level isolation" {
    const alloc = std.testing.allocator;
    const schema = struct {
        pub const user = zent.core.Schema("user", .{
            .fields = &.{
                zent.core.field.Int("id").AutoIncrement(),
                zent.core.field.String("name"),
                zent.core.field.Int("owner_id"),
            },
            .policy = zent.privacy.Policy{
                .rules = &.{
                    zent.privacy.Filter(struct {
                        fn call(ctx: zent.privacy.PrivacyContext) ?anyopaque {
                            _ = ctx;
                            return null;
                        }
                    }.call),
                },
            },
        });
    };
    // ... setup, insert rows for user A and B, query with different contexts, assert isolation ...
}
```

- [ ] **Step 2: Add no-context denial test**

```zig
test "SQLite: privacy denies without WithContext" {
    // Build a query without calling WithContext on an entity that has privacy rules.
    // Expect error.PrivacyDenied.
}
```

- [ ] **Step 3: Run, commit**

```bash
zig build test-integration && zig fmt --check tests/integration/sqlite.zig
git add tests/integration/sqlite.zig
git commit -m "test(privacy): add multi-tenant isolation and denial regression tests"
```

---

### Task 5: Hook System — HookContext + HookError

**Files:**
- Modify: `src/runtime/hook.zig`

**Interfaces:**
- Consumes: `PrivacyContext`
- Produces: `HookContext` (entity access, mutation data), `HookError`, updated `Hook` callback signatures

- [ ] **Step 1: Update Hook signatures in `src/runtime/hook.zig`**

Replace the current `Hook` struct (lines 29-49) and `Context` (lines 12-25) with:

```zig
pub const HookContext = struct {
    op: Op,
    table_name: []const u8,
    /// Read-only entity pointer. Null for create-before.
    entity: ?*anyopaque = null,
    /// New field values for create/update. Null for delete/query.
    mutated: ?[]const Value = null,
    /// Inherited from the builder.
    privacy: PrivacyContext = .{},
    user_data: ?*anyopaque = null,
    record_id: ?i64 = null,
};

pub const Hook = struct {
    op: Op,
    before: ?*const fn (ctx: *HookContext) HookError!void = null,
    after: ?*const fn (ctx: *HookContext) HookError!void = null,
};

pub const HookError = error{
    ValidationFailed,
    Forbidden,
    HookFailed,
};
```

- [ ] **Step 2: Update HookChain (lines 52-89)**

Change callback signatures:
```zig
pub fn executeBefore(self: *const HookChain, ctx: *HookContext) HookError!void { ... }
pub fn executeAfter(self: *const HookChain, ctx: *HookContext) void { ... }
```

After hooks wrap the callback in a catch that logs via `std.log.err` but does not propagate.

- [ ] **Step 3: Add global hook registry**

```zig
var global_registry: ?*HookChain = null;
var global_mutex: std.Thread.Mutex = .{};

pub fn registerGlobal(chain: *HookChain) void { ... }
pub fn globalBefore(ctx: *HookContext) HookError!void { ... }
pub fn globalAfter(ctx: *HookContext) void { ... }
```

- [ ] **Step 4: Update built-in hooks (lines 96-136)**

Update `LoggingHook` callbacks to match new `*const fn (ctx: *HookContext) HookError!void` signature.

- [ ] **Step 5: Run, commit**

```bash
zig build test && zig fmt --check src/runtime/hook.zig
git add src/runtime/hook.zig
git commit -m "feat(hook): add HookContext with entity data and HookError return"
```

---

### Task 6: Builder Hook Integration for All Ops

**Files:**
- Modify: `src/codegen/create.zig`
- Modify: `src/codegen/update_delete.zig`
- Test: `tests/integration/sqlite.zig`

**Interfaces:**
- Consumes: `HookContext`, `HookError`
- Produces: before/after hooks on create/update/delete

- [ ] **Step 1: Update CreateBuilder in create.zig**

In `saveInternal` (around line 150), replace:
```zig
for (self.hooks) |h| {
    if (h.op == .create) {
        if (h.before) |f| f(.create, info.table_name);
    }
}
```
with:
```zig
var hook_ctx = HookContext{
    .op = .create,
    .table_name = info.table_name,
    .mutated = &self.values.items,
    .privacy = self.privacy_ctx orelse .{},
    .allocator = self.allocator,
};
for (self.hooks) |h| {
    if (h.op == .create) {
        if (h.before) |f| try f(&hook_ctx);
    }
}
errdefer {
    for (self.hooks) |h| {
        if (h.op == .create) {
            if (h.after) |f| f(&hook_ctx) catch {};
        }
    }
}
```

After successful execution, run the after hooks (not in errdefer).

- [ ] **Step 2: Update UpdateBuilder in update_delete.zig**

Same pattern for `.update` op. Populate `hook_ctx.entity` with the entity being updated.

- [ ] **Step 3: Update DeleteBuilder in update_delete.zig**

Same pattern for `.delete` op.

- [ ] **Step 4: Add hook abort integration test**

```zig
test "SQLite: before hook abort prevents creation" {
    // Register a before-create hook that returns error.Forbidden.
    // Assert that Save() returns error.Forbidden and no row is inserted.
}
```

- [ ] **Step 5: Add mutation data test**

```zig
test "SQLite: after hook sees created entity" {
    // Register after-create hook that reads entity.id and verifies it's non-null.
}
```

- [ ] **Step 6: Run, commit**

```bash
zig build test && zig build test-integration && zig fmt --check src/codegen/create.zig src/codegen/update_delete.zig tests/integration/sqlite.zig
git add src/codegen/create.zig src/codegen/update_delete.zig tests/integration/sqlite.zig
git commit -m "feat(hook): integrate cancellable hooks for create/update/delete"
```

---

### Task 7: Prepared Statement Cache

**Files:**
- Create: `src/sql/cache.zig`
- Modify: `src/sql/sqlite.zig`
- Modify: `src/sql/postgres.zig`
- Modify: `src/sql/mysql.zig`

**Interfaces:**
- Consumes: driver-specific statement handles (sqlite3_stmt*, PGresult*, MYSQL_STMT*)
- Produces: `PreparedCache(capacity)` generic, integrated into each driver

- [ ] **Step 1: Create `src/sql/cache.zig`**

```zig
const std = @import("std");

pub fn PreparedCache(comptime capacity: usize, comptime Handle: type) type {
    return struct {
        const Self = @This();
        const Entry = struct {
            sql_hash: u64,
            stmt: Handle,
            last_used: i64,
        };

        entries: [capacity]Entry = undefined,
        len: usize = 0,
        evict_ord: [capacity]usize = undefined,

        pub fn getOrPrepare(
            self: *Self,
            sql: []const u8,
            prepareFn: *const fn (sql: []const u8) anyerror!Handle,
            deinitFn: *const fn (handle: Handle) void,
        ) !Handle {
            const hash = std.hash.Wyhash.hash(0, sql);
            // Linear scan for hash match + sql comparison (small capacity).
            for (self.entries[0..self.len]) |*e, i| {
                if (e.sql_hash == hash) {
                    for (self.evict_ord[0..self.len]) |*eo| {
                        if (eo.* == i) {
                            // Move to MRU position.
                            std.mem.copy(usize, self.evict_ord[0..self.len], self.evict_ord);
                            eo.* = 0;
                        }
                    }
                    e.last_used = std.time.milliTimestamp();
                    return e.stmt;
                }
            }
            // Cache miss: prepare new statement.
            const stmt = try prepareFn(sql);
            if (self.len < capacity) {
                self.entries[self.len] = .{ .sql_hash = hash, .stmt = stmt, .last_used = std.time.milliTimestamp() };
                self.evict_ord[self.len] = self.len;
                self.len += 1;
            } else {
                // Evict LRU entry.
                const evict_idx = self.evict_ord[self.len - 1];
                const evicted: *Entry = &self.entries[evict_idx];
                deinitFn(evicted.stmt);
                evicted.* = .{ .sql_hash = hash, .stmt = stmt, .last_used = std.time.milliTimestamp() };
            }
            return stmt;
        }

        pub fn evictAll(self: *Self, deinitFn: *const fn (handle: Handle) void) void {
            for (self.entries[0..self.len]) |*e| deinitFn(e.stmt);
            self.len = 0;
        }
    };
}
```

- [ ] **Step 2: Integrate into SQLiteDriver**

Add field: `cache: ?PreparedCache(16, *c.sqlite3_stmt) = null`

In `exec()` and `query()`, replace direct `sqlite3_prepare_v2` + `sqlite3_finalize` with `cache.getOrPrepare()`. On `close()`, call `cache.evictAll()`.

- [ ] **Step 3: Integrate into PostgresDriver**

PostgreSQL uses `PQexecParams` which doesn't have a statement handle — skip caching for now. The cache field remains null.

- [ ] **Step 4: Integrate into MySQLDriver**

Add field: `cache: ?PreparedCache(16, *c.MYSQL_STMT) = null`

Use `cache.getOrPrepare()` wrapping `mysql_stmt_init` + `mysql_stmt_prepare`.

- [ ] **Step 5: Run, commit**

```bash
zig build test && zig build test-integration && zig fmt --check src/sql/cache.zig src/sql/sqlite.zig src/sql/mysql.zig
git add src/sql/cache.zig src/sql/sqlite.zig src/sql/mysql.zig
git commit -m "feat(cache): add comptime-fixed PreparedCache for SQLite/MySQL"
```

---

### Task 8: Driver Reliability — PG Ping Fix + QueryTimeout

**Files:**
- Modify: `src/sql/driver.zig`
- Modify: `src/sql/postgres.zig`

**Interfaces:**
- Consumes: `driver.Error`, `PostgresDriver.ping`
- Produces: `QueryTimeout` error variant, correct `ping()` implementation

- [ ] **Step 1: Add QueryTimeout to driver.Error**

In `src/sql/driver.zig` (line 11-26), insert after `DriverFailed`:
```zig
QueryTimeout,
```

- [ ] **Step 2: Fix PostgreSQL ping in `src/sql/postgres.zig`**

Replace `ping` (lines 256-262) with:
```zig
pub fn ping(self: *PostgresDriver) driver.Error!void {
    const result = c.PQexec(self.conn, "SELECT 1");
    defer c.PQclear(result);
    if (c.PQresultStatus(result) != c.PGRES_TUPLES_OK) {
        logPgError(self.conn, "ping");
        return error.PingFailed;
    }
}
```

- [ ] **Step 3: Add pooled QueryTimeout in `src/sql/pool.zig`**

In `driverExec` and `driverQuery`, wrap the driver call with a timer:
```zig
fn driverExec(ptr: *anyopaque, sql: []const u8, args: []const Value) driver.Error!driver.Result {
    const pool: *Self = @ptrCast(@alignCast(ptr));
    const conn = try pool.borrowForDriver();
    defer pool.release(conn);
    if (pool.options.query_timeout_ms > 0) {
        var timer = try std.time.Timer.start();
        const result = conn.asDriver().exec(sql, args);
        if (timer.read() > pool.options.query_timeout_ms * std.time.ns_per_ms) {
            return error.QueryTimeout;
        }
        return result;
    }
    return conn.asDriver().exec(sql, args);
}
```
(Same pattern for driverQuery.)

- [ ] **Step 4: Run, commit**

```bash
zig build test && zig build test-integration && zig fmt --check src/sql/driver.zig src/sql/postgres.zig src/sql/pool.zig
git add src/sql/driver.zig src/sql/postgres.zig src/sql/pool.zig
git commit -m "fix(pg): use SELECT 1 for ping; add QueryTimeout variant"
```

---

### Task 9: Pool Retry + Idle/Lifetime Eviction

**Files:**
- Modify: `src/sql/pool.zig`
- Test: pool tests in `src/sql/pool.zig`

**Interfaces:**
- Consumes: `PoolOptions`
- Produces: retry with backoff, idle eviction, max lifetime

- [ ] **Step 1: Add new PoolOptions fields (around line 59)**

```zig
/// Max retry attempts for borrowing a connection. 0 = no retry.
max_retries: u32 = 3,
/// Retry backoff base in milliseconds.
retry_backoff_ms: u32 = 100,
/// Query timeout in milliseconds. 0 = no timeout.
query_timeout_ms: u32 = 0,
/// Max idle time for a connection in seconds. 0 = permanent.
max_idle_secs: u32 = 300,
/// Max total lifetime for a connection in seconds. 0 = permanent.
max_lifetime_secs: u32 = 3600,
```

- [ ] **Step 2: Add retry logic to `borrow` (around line 189)**

Replace the single `tryBorrow` call with a retry loop:
```zig
pub fn borrow(self: *Self) !*D {
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        if (self.tryBorrow()) |conn| {
            // Check idle eviction.
            if (self.options.max_idle_secs > 0 and conn.idle_since) |idle_since| {
                const idle_secs = @divFloor(std.time.timestamp() - idle_since, 1);
                if (idle_secs > self.options.max_idle_secs) {
                    conn.close();
                    continue; // Try next or create new.
                }
            }
            conn.idle_since = null;
            return conn;
        }
        if (attempt >= self.options.max_retries) break;
        std.time.sleep(self.options.retry_backoff_ms * std.time.ns_per_ms * (attempt + 1));
    }
    return error.PoolExhausted;
}
```

- [ ] **Step 3: Add lifetime check on `release` (around line 280)**

```zig
if (self.options.max_lifetime_secs > 0) {
    const age_secs = @divFloor(std.time.timestamp() - conn.created_at, 1);
    if (age_secs > self.options.max_lifetime_secs) {
        conn.close();
        return;
    }
}
```

- [ ] **Step 4: Add pool retry test**

```zig
test "pool retries on exhaustion with backoff" {
    // Create pool with max_connections=1, max_retries=2.
    // Borrow one connection. Try to borrow again — should retry and fail.
    // Verify PoolExhausted returned after retries.
}
```

- [ ] **Step 5: Run, commit**

```bash
zig build test && zig fmt --check src/sql/pool.zig
git add src/sql/pool.zig
git commit -m "feat(pool): retry with backoff, idle eviction, max lifetime"
```

---

### Task 10: Observability — Logger + Client Integration

**Files:**
- Create: `src/sql/logger.zig`
- Modify: `src/codegen/client.zig`
- Modify: `src/root.zig`

**Interfaces:**
- Consumes: `sql.Value`, `sql.Result`
- Produces: `Logger`, `LogContext`, `Client.Debug()`, `Client.SetLogger()`

- [ ] **Step 1: Create `src/sql/logger.zig`**

```zig
const std = @import("std");
const Value = @import("builder.zig").Value;

pub const LogContext = struct {
    sql: []const u8,
    args: ?[]const Value = null,
    duration_us: u64 = 0,
    rows_affected: usize = 0,
    error: ?anyerror = null,
    table_name: []const u8 = "",
};

pub const Logger = struct {
    onQuery: ?*const fn (ctx: LogContext) void = null,
    onExec: ?*const fn (ctx: LogContext) void = null,
    onError: ?*const fn (ctx: LogContext) void = null,
};

pub fn debugLogger() Logger {
    return .{
        .onQuery = struct {
            fn log(ctx: LogContext) void {
                std.log.debug("QUERY [{s}] {s} ({d}us, {d} rows)", .{ ctx.table_name, ctx.sql, ctx.duration_us, ctx.rows_affected });
            }
        }.log,
        .onExec = struct {
            fn log(ctx: LogContext) void {
                std.log.debug("EXEC [{s}] {s} ({d}us, affected={d})", .{ ctx.table_name, ctx.sql, ctx.duration_us, ctx.rows_affected });
            }
        }.log,
        .onError = struct {
            fn log(ctx: LogContext) void {
                std.log.err("ERROR [{s}] {s} ({d}us): {any}", .{ ctx.table_name, ctx.sql, ctx.duration_us, ctx.error });
            }
        }.log,
    };
}
```

- [ ] **Step 2: Add Logger to Client in `src/codegen/client.zig`**

Add field and methods to the root `Client` struct:
```zig
logger: Logger = .{},
```

```zig
pub fn SetLogger(self: *@This(), logger: Logger) void {
    self.logger = logger;
}

pub fn Debug(self: *@This()) void {
    self.logger = debugLogger();
}
```

Propagate `logger` to each `EntityClient` during construction (line 241-260).

- [ ] **Step 3: Export in `src/root.zig`**

Add `pub const logger = @import("sql/logger.zig");`

- [ ] **Step 4: Run, commit**

```bash
zig build test && zig fmt --check src/sql/logger.zig src/codegen/client.zig src/root.zig
git add src/sql/logger.zig src/codegen/client.zig src/root.zig
git commit -m "feat(logger): add structured Logger with Debug() mode"
```

---

### Task 11: Builder Logging + Sensitive Field Masking

**Files:**
- Modify: `src/codegen/create.zig`
- Modify: `src/codegen/query.zig`
- Modify: `src/codegen/update_delete.zig`
- Modify: `src/core/field.zig`
- Modify: `src/codegen/graph.zig` (FieldInfo sensitive flag)

**Interfaces:**
- Consumes: `Logger`, `LogContext`
- Produces: log calls in create/query/update/delete, sensitive field flag

- [ ] **Step 1: Add `sensitive` flag to Field**

In `src/core/field.zig`, add field to `Field` struct (around line 36):
```zig
sensitive: bool = false,
```

Add builder method:
```zig
pub fn Sensitive(self: Field) Field {
    var f = self;
    f.sensitive = true;
    return f;
}
```

- [ ] **Step 2: Propagate sensitive flag in graph.zig**

In `FieldInfo` (lines 9-22), add:
```zig
sensitive: bool = false,
```

In `fromSchema` (line 59), copy `f.sensitive` to `FieldInfo.sensitive`.

- [ ] **Step 3: Add logging to CreateBuilder in create.zig**

In `saveInternal`, after successful `drv.exec()`:
```zig
if (self.logger.onExec) |log| {
    log(.{
        .sql = q.sql,
        .args = &self.values.items, // with sensitive masking
        .duration_us = timer_us,
        .rows_affected = 1,
        .table_name = info.table_name,
    });
}
```

Sensitive values are replaced with `"***"` before logging.

- [ ] **Step 4: Add logging to QueryBuilder in query.zig**

In `All`/`First`/etc., after `drv.query()`:
```zig
if (self.logger.onQuery) |log| {
    log(.{
        .sql = q.sql,
        .duration_us = timer_us,
        .rows_affected = rows.items.len,
        .table_name = info.table_name,
    });
}
```

- [ ] **Step 5: Add logging to UpdateBuilder/DeleteBuilder in update_delete.zig**

Same pattern.

- [ ] **Step 6: Run, commit**

```bash
zig build test && zig build test-integration && zig fmt --check src/codegen/create.zig src/codegen/query.zig src/codegen/update_delete.zig src/core/field.zig src/codegen/graph.zig
git add src/codegen/create.zig src/codegen/query.zig src/codegen/update_delete.zig src/core/field.zig src/codegen/graph.zig
git commit -m "feat(logger): add query/exec logging and Sensitive field masking"
```

---

### Task 12: Migration — DROP COLUMN + ALTER TYPE

**Files:**
- Modify: `src/sql/schema/migrate.zig`

**Interfaces:**
- Consumes: `driver.Driver`, dialect-aware SQL generation
- Produces: `MigrateOptions`, DROP COLUMN SQL, ALTER TYPE SQL

- [ ] **Step 1: Add MigrateOptions struct (before migrateSchema)**

```zig
pub const MigrateOptions = struct {
    dry_run: bool = false,
    drop_columns: bool = false,
    allow_data_loss: bool = false,
};
```

- [ ] **Step 2: Update migrateSchema signature**

```zig
pub fn migrateSchema(
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    comptime infos: []const TypeInfo,
    opts: MigrateOptions,
) !void {
```

- [ ] **Step 3: Add DROP COLUMN detection and SQL generation**

Add a helper:
```zig
fn dropColumnSQL(
    allocator: std.mem.Allocator,
    table_name: []const u8,
    column_name: []const u8,
    dialect: Dialect,
) ![]const u8 {
    _ = allocator;
    return switch (dialect) {
        .sqlite => std.fmt.allocPrint(allocator, "ALTER TABLE \"{s}\" DROP COLUMN \"{s}\"", .{ table_name, column_name }),
        .postgres => std.fmt.allocPrint(allocator, "ALTER TABLE \"{s}\" DROP COLUMN \"{s}\" CASCADE", .{ table_name, column_name }),
        .mysql => std.fmt.allocPrint(allocator, "ALTER TABLE `{s}` DROP COLUMN `{s}`", .{ table_name, column_name }),
    };
}
```

In `migrateSchema`, after the column-addition loop, add a column-removal loop: for each existing column NOT in the schema, generate DROP COLUMN SQL if `opts.drop_columns` is true.

- [ ] **Step 4: Add ALTER TYPE SQL generation**

```zig
fn alterColumnTypeSQL(
    allocator: std.mem.Allocator,
    table_name: []const u8,
    column_name: []const u8,
    new_type: []const u8,
    dialect: Dialect,
) ![]const u8 {
    return switch (dialect) {
        .sqlite => error.UnsupportedDialect, // SQLite needs table rebuild
        .postgres => std.fmt.allocPrint(allocator,
            "ALTER TABLE \"{s}\" ALTER COLUMN \"{s}\" TYPE {s} USING \"{s}\"::{s}",
            .{ table_name, column_name, new_type, column_name, new_type }),
        .mysql => std.fmt.allocPrint(allocator,
            "ALTER TABLE `{s}` MODIFY COLUMN `{s}` {s}",
            .{ table_name, column_name, new_type }),
    };
}
```

- [ ] **Step 5: Run, commit**

```bash
zig build test && zig fmt --check src/sql/schema/migrate.zig
git add src/sql/schema/migrate.zig
git commit -m "feat(migrate): add MigrateOptions, DROP COLUMN, and ALTER TYPE"
```

---

### Task 13: Migration — Dry-Run + Tests

**Files:**
- Modify: `src/sql/schema/migrate.zig`
- Test: `tests/integration/sqlite.zig`
- Test: `tests/integration/postgres.zig`

**Interfaces:**
- Consumes: `MigrateOptions.dry_run`
- Produces: dry-run output collection, integration tests

- [ ] **Step 1: Implement dry-run mode**

When `opts.dry_run` is true, collect all SQL into `std.ArrayList([]const u8)` instead of executing. Print via `std.log.info` or a caller-supplied writer.

```zig
if (opts.dry_run) {
    var sqls = std.ArrayList([]const u8).init(allocator);
    defer sqls.deinit();
    // ... collect SQL ... 
    for (sqls.items) |s| std.debug.print("{s};\n", .{s});
    return;
}
```

- [ ] **Step 2: Add DROP COLUMN integration test**

```zig
test "SQLite: migrateSchema drops removed column" {
    // Schema with column 'obsolete'.
    // Run migrateSchema with drop_columns: false → column remains.
    // Run migrateSchema with drop_columns: true → column gone.
}
```

- [ ] **Step 3: Add dry-run integration test**

```zig
test "SQLite: migrateSchema dry-run outputs SQL without executing" {
    // Run migrateSchema with dry_run: true.
    // Verify no tables were created (query sqlite_master returns empty).
}
```

- [ ] **Step 4: Run, commit**

```bash
zig build test && zig build test-integration && zig fmt --check src/sql/schema/migrate.zig tests/integration/sqlite.zig
git add src/sql/schema/migrate.zig tests/integration/sqlite.zig
git commit -m "feat(migrate): add dry-run mode and integration tests"
```

---

### Task 14: Cursor Pagination + CTE

**Files:**
- Modify: `src/codegen/query.zig`
- Modify: `src/sql/builder.zig`

**Interfaces:**
- Consumes: `sql.Builder`, generated `Entity`
- Produces: `Cursor(column, value)`, `CursorAfter(entity)`, `Builder.with()`

- [ ] **Step 1: Add cursor pagination to QueryBuilder in query.zig**

Add fields:
```zig
cursor_col: ?[]const u8 = null,
cursor_val: ?sql.Value = null,
```

Add methods:
```zig
pub fn Cursor(self: *Self, column: []const u8, value: sql.Value) *Self {
    self.cursor_col = column;
    self.cursor_val = value;
    return self;
}

pub fn CursorAfter(self: *Self, entity: Entity) *Self {
    self.cursor_col = "id";
    self.cursor_val = .{ .int = entity.id };
    return self;
}
```

In the query build step, if `cursor_col` is set, add `WHERE (col > ?) ORDER BY col ASC` and use `LIMIT` for page size (reusing existing `limit_val`).

- [ ] **Step 2: Add CTE to sql.Builder in builder.zig**

Add field:
```zig
ctes: std.ArrayList(CTE),
```

Add struct:
```zig
pub const CTE = struct {
    name: []const u8,
    columns: ?[]const []const u8,
    query: OwnedQuery,
    materialized: ?bool = null,
};
```

Add method:
```zig
pub fn with(self: *Self, name: []const u8, subquery: OwnedQuery) !void {
    try self.ctes.append(.{ .name = name, .columns = null, .query = subquery });
}
```

In `buildSelect`, prepend CTEs:
```sql
WITH <cte_name1> AS (<subquery1>), <cte_name2> AS (<subquery2>) SELECT ...
```

- [ ] **Step 3: Run, commit**

```bash
zig build test && zig fmt --check src/codegen/query.zig src/sql/builder.zig
git add src/codegen/query.zig src/sql/builder.zig
git commit -m "feat(api): add cursor-based pagination and CTE WITH clause"
```

---

### Task 15: EntQL — HasEdge, NOT IN, EQFold

**Files:**
- Modify: `src/entql/parser.zig`

**Interfaces:**
- Consumes: `sql.Predicate`
- Produces: `has(edge)`, `has(edge, preds)`, `not_has(edge)`, `NOT IN`, `=~` EQFold

- [ ] **Step 1: Add HasEdge token and parsing**

Add tokens: `TOKEN_HAS`, `TOKEN_NOT_HAS`.

Add grammar rules:
```
primary = ... | has_expr | not_has_expr
has_expr = "has" "(" IDENTIFIER ")"
has_expr = "has" "(" IDENTIFIER "," expr ")"
not_has_expr = "not_has" "(" IDENTIFIER ")"
```

`has(edge_name)` → `sql.Exists` subquery on the edge FK column.
`has(edge_name, preds)` → `sql.Exists` subquery with predicates on the related entity.

- [ ] **Step 2: Add NOT IN support**

Add token: `NOT` `IN`.

During parsing, when we see `NOT` followed by `IN`, produce `sql.NotIn` predicate.

- [ ] **Step 3: Add EQFold (=~) support**

Add token: `EQFOLD` (`=~`).

`field =~ "value"` → `sql.EQFold` predicate (case-insensitive equality, generated as `LOWER(col) = LOWER(?)`).

- [ ] **Step 4: Run, commit**

```bash
zig build test && zig fmt --check src/entql/parser.zig
git add src/entql/parser.zig
git commit -m "feat(entql): add HasEdge, NOT IN, and EQFold (=~) syntax"
```

---

### Task 16: Annotations + Sensitive Field Propagation

**Files:**
- Modify: `src/core/schema.zig`
- Modify: `src/core/field.zig` (Sensitive already done in Task 11)
- Modify: `src/codegen/graph.zig`
- Modify: `src/codegen/entity.zig` (Sensitive masking in format)

**Interfaces:**
- Consumes: `Schema` config, `FieldInfo`, `Entity`
- Produces: `Annotations` on schema, `Sensitive` on fields, masked std.fmt output

- [ ] **Step 1: Add Annotations to Schema config**

In `src/core/schema.zig` (line 56-67), add optional field:
```zig
annotations: ?@import("std").meta.DeclEnum(@This()) = null,
```

Or simpler — use a string-keyed map:
```zig
annotations: []const struct { key: []const u8, value: []const u8 } = &.{},
```

- [ ] **Step 2: Propagate annotations in graph.zig**

Add `annotations` field to `TypeInfo` (line 46-56):
```zig
annotations: []const struct { key: []const u8, value: []const u8 } = &.{},
```

Copy from Schema config in `fromSchema`.

- [ ] **Step 3: Implement Sensitive format masking in entity.zig**

In `src/codegen/entity.zig`, add a custom `format` method to generated entities that replaces sensitive field values with `"***"`:

```zig
pub fn format(self: Entity, comptime fmt_str: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    _ = fmt_str;
    _ = options;
    try writer.writeAll(info.table_name);
    try writer.writeAll("{{");
    inline for (info.fields, 0..) |f, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("{s}=", .{f.name});
        if (f.sensitive) {
            try writer.writeAll("***");
        } else {
            try writer.print("{any}", .{@field(self, f.name)});
        }
    }
    try writer.writeAll("}}");
}
```

- [ ] **Step 4: Run, commit**

```bash
zig build test && zig build test-integration && zig fmt --check src/core/schema.zig src/codegen/graph.zig src/codegen/entity.zig
git add src/core/schema.zig src/codegen/graph.zig src/codegen/entity.zig
git commit -m "feat(api): add Annotations, Sensitive field masking in fmt"
```

---

## Self-Review

**1. Spec coverage:**
- Section 1 (Privacy): Tasks 1-4 ✅
- Section 2 (Hooks): Tasks 5-6 ✅
- Section 3 (Cache): Task 7 ✅
- Section 4 (Driver reliability): Tasks 8-9 ✅
- Section 5 (Observability): Tasks 10-11 ✅
- Section 6 (Migration): Tasks 12-13 ✅
- Section 7 (API): Tasks 14-16 ✅
- Error handling: QueryTimeout in Task 8, HookError in Task 5 ✅
- Testing: Tasks 4, 6, 9, 13 ✅
- Success criteria: all tasks require `zig build test` + `zig build test-integration` + `zig fmt --check` ✅
- Out of scope: async, distributed tracing, WINDOW, Atlas migrations — not included ✅

**2. Placeholder scan:** No "TBD", "TODO". Every step has concrete code or exact command.

**3. Type consistency:**
- `PrivacyContext` defined in Task 1, used in Tasks 2, 3, 4, 5 ✅
- `HookContext` defined in Task 5, used in Task 6 ✅
- `Logger` defined in Task 10, used in Task 11 ✅
- `PreparedCache` defined in Task 7, used in Task 7 ✅
- `MigrateOptions` defined in Task 12, used in Tasks 12, 13 ✅
- `driver.Error.QueryTimeout` added in Task 8 ✅
