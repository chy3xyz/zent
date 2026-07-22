# Query Timeout / Cancel Design

## Goal

Add query-level and pool-default execution timeouts to zent so that long-running database operations fail predictably with `error.QueryTimeout` instead of blocking indefinitely. This is the second of four production blockers.

## Scope

### In scope

1. **Builder-level timeout API**
   - `.withTimeout(ms: u32)` on `QueryBuilder`, `CreateBuilder`, `BulkCreateBuilder`, `UpdateBuilder`, `DeleteBuilder`, `BulkUpdateBuilder`, `BulkDeleteBuilder`.
   - Stored as `timeout_ms: ?u32 = null` inside each builder.

2. **Pool default timeout**
   - `ConnPool.Options.query_timeout_ms: ?u32 = null`.
   - Applied when a builder does not set its own timeout.

3. **Deadline propagation**
   - New `driver.ExecutionContext` struct: `{ deadline_ns: ?i64 }` (absolute monotonic deadline).
   - Driver vtable `exec` and `query` gain an optional `ctx: ?*const ExecutionContext` parameter.
   - Builders compute deadline from `timeout_ms` and pass it to the driver.

4. **Per-driver timeout implementation**
   - **SQLite**: set `sqlite3_busy_timeout` to remaining ms before query; install a `sqlite3_progress_handler` that returns non-zero when the deadline is exceeded.
   - **PostgreSQL**: prepend `SET LOCAL statement_timeout = 'Xms'` to the SQL, or use the per-connection `statement_timeout` GUC when a deadline is present.
   - **MySQL**: execute `SET SESSION MAX_EXECUTION_TIME=X` before the query (where supported) and fall back to `MYSQL_OPT_READ_TIMEOUT` / `MYSQL_OPT_WRITE_TIMEOUT` socket deadlines.

5. **Error handling**
   - Re-use / formalize `driver.Error.QueryTimeout`.
   - Map native timeout signals (`SQLITE_INTERRUPT`, `57014`/`canceling statement`, `ER_QUERY_TIMEOUT`) to `error.QueryTimeout`.

### Out of scope

- True asynchronous cancellation tokens (e.g., `CancelToken` signaled from another thread). SQLite interrupt is included because it is cheap; PG `PQcancel` and MySQL `mysql_kill` are deferred to a future phase.
- Per-row timeout checks inside drivers (only whole-query deadlines).
- Network-layer TCP keepalive configuration.

## Architecture

```
┌─────────────────────────────────────┐
│  Builder API                        │  .withTimeout(ms)
│  src/codegen/{query,create,...}.zig │
├─────────────────────────────────────┤
│  ExecutionContext                   │  deadline_ns
│  src/sql/driver.zig                 │
├─────────────────────────────────────┤
│  Driver vtable                      │  exec(ctx, sql, args)
│  src/sql/driver.zig                 │  query(ctx, sql, args)
├─────────────────────────────────────┤
│  Per-driver deadline enforcement    │
│  sqlite / postgres / mysql          │
├─────────────────────────────────────┤
│  Pool default                       │
│  src/sql/pool.zig                   │  Options.query_timeout_ms
└─────────────────────────────────────┘
```

## Interfaces

### Builder API

```zig
// Query
var q = client.User.Query().withTimeout(5_000);
const users = try q.All(allocator);

// Create
var c = client.User.Create().withTimeout(2_000);
const user = try c.SetName("A").Save(allocator);

// Update / Delete — same pattern
```

### ExecutionContext

```zig
// src/sql/driver.zig
pub const ExecutionContext = struct {
    /// Absolute monotonic deadline in nanoseconds. Null means no deadline.
    deadline_ns: ?i64 = null,

    /// Convenience helper for drivers.
    pub fn remainingMs(self: ExecutionContext) ?u32 {
        const d = self.deadline_ns orelse return null;
        const now = std.time.nanoTimestamp();
        if (now >= d) return 0;
        const remaining = @as(u64, @intCast(d - now)) / std.time.ns_per_ms;
        return if (remaining > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(remaining);
    }
};
```

### Driver vtable change

```zig
pub const VTable = struct {
    exec: *const fn (ptr: *anyopaque, ctx: ?*const ExecutionContext, query: []const u8, args: []const Value) Error!Result,
    query: *const fn (ptr: *anyopaque, ctx: ?*const ExecutionContext, query: []const u8, args: []const Value) Error!Rows,
    // ... other methods unchanged
};
```

### Pool default

```zig
pub const Options = struct {
    // existing fields ...
    query_timeout_ms: ?u32 = null,
};
```

## Driver behavior

### SQLite

1. If `ctx` has a deadline, compute remaining ms `R`.
2. Save current `busy_timeout`, then `sqlite3_busy_timeout(db, R)`.
3. Install `sqlite3_progress_handler(db, N, progressCallback, ctx)` where the callback checks the deadline.
4. Run the query.
5. Restore previous `busy_timeout` and remove progress handler (or set to null).

### PostgreSQL

1. If `ctx` has a deadline, compute remaining ms `R`.
2. Prepend `SET LOCAL statement_timeout = 'Rms';` to the SQL or execute it as a separate synchronous command before the real query.
3. Run the query.
4. Reset `statement_timeout` to default (`SET LOCAL statement_timeout = DEFAULT`) after the query.

### MySQL

1. If `ctx` has a deadline, compute remaining ms `R`.
2. Execute `SET SESSION MAX_EXECUTION_TIME=R` before the query (MySQL 5.7.8+/MariaDB 10.1.6+).
3. Also set `MYSQL_OPT_READ_TIMEOUT` and `MYSQL_OPT_WRITE_TIMEOUT` to `R` seconds (ceiling) on the connection for the duration of the query.
4. Restore previous socket timeouts after the query.

## Error handling

- `driver.Error.QueryTimeout` is returned when a deadline is exceeded.
- Native errors are mapped:
  - SQLite: `SQLITE_INTERRUPT` → `QueryTimeout`
  - PostgreSQL: SQLSTATE `57014` → `QueryTimeout`
  - MySQL: errno `ER_QUERY_TIMEOUT` / `3024` → `QueryTimeout`
- If the native error cannot be definitely identified as a timeout, it falls back to `QueryFailed`.

## Testing

1. **Unit tests**
   - `ExecutionContext.remainingMs` correctness around deadlines.
   - Builder stores and returns timeout value.
   - Pool applies default timeout when builder has none.

2. **Integration tests**
   - SQLite: `SELECT 1` with a 1 s timeout succeeds.
   - PostgreSQL: `SELECT pg_sleep(2)` with a 100 ms timeout returns `QueryTimeout`.
   - MySQL: `SELECT SLEEP(2)` with a 100 ms timeout returns `QueryTimeout`.
   - Verify that subsequent queries after a timeout still work (driver is left in a usable state).

## Success Criteria

- `zig build test` and `zig build test-integration` pass with 0 leaks.
- `zig fmt --check src examples tests build.zig` passes.
- All three drivers return `error.QueryTimeout` for intentionally slow queries.
- Public API remains backward-compatible: existing code without `.withTimeout()` continues to work.

## Future Work

- True cancellation tokens (`CancelToken`) for cross-thread query abort.
- PG `PQcancel` and MySQL `mysql_kill` integration.
- Per-row streaming timeout checks for very large result sets.
