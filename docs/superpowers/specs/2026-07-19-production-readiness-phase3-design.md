# zent Production Readiness Phase 3 Design

## Goal

Bring zent to 9.5+ production readiness by completing parity with ent Go's core features: row-level privacy filtering, cancellable hooks, prepared statement caching, connection reliability, structured observability, migration DDL completeness, and full API surface.

## Architecture

Four independent layers, each testable in isolation:

```
┌─────────────────────────────────────────┐
│  API Layer    │ cursor · CTE             │
│  (codegen)    │ EntQL HasEdge · Sensitive│
├─────────────────────────────────────────┤
│  Privacy +    │ PrivacyContext · Filter  │
│  Hook Layer   │ HookContext · error ret  │
│  (privacy/    │ Decision: Allow/Deny/    │
│   runtime/)   │ Filter / Skip           │
├─────────────────────────────────────────┤
│  Driver       │ PrepStmtCache · Retry    │
│  Reliability  │ Timeout · PG ping fix   │
│  (sql/)       │ Idle eviction · Logger   │
├─────────────────────────────────────────┤
│  Migration    │ DROP COLUMN · ALTER TYPE │
│  Enhancements │ dry-run · FK management  │
│  (schema/)    │                          │
└─────────────────────────────────────────┘
```

**Principles:**
- Layers communicate through narrow, well-defined interfaces; no cross-layer imports.
- Each layer can be merged to main independently.
- All new code targets Zig 0.17-dev, uses comptime for zero-runtime-cost abstractions, explicit error sets, arena-based memory management, and no external dependencies.
- Prefer minimal, focused changes over speculative rewrites.

---

## 1. Privacy Layer

### 1.1 PrivacyContext

```zig
/// Carries caller identity through the query/mutation pipeline.
/// Value-type, copy-passed; immutable after construction.
pub const PrivacyContext = struct {
    user_id: ?i64 = null,
    role: ?[]const u8 = null,
    tenant_id: ?i64 = null,
    extra: ?*anyopaque = null,
};
```

### 1.2 Enhanced Policy

Replace the current binary `OldRule` with a rule-based system:

```zig
pub const Policy = struct {
    rules: []const Rule,

    pub const Rule = union(enum) {
        allow: AllowRule,
        deny: DenyRule,
        filter: FilterRule,
        skip: SkipRule,
    };

    pub const AllowRule = struct {};
    pub const DenyRule = struct {};
    pub const SkipRule = struct {};

    /// Returns null when no filter applies; returns a predicate
    /// to be AND-injected into the SQL WHERE clause.
    pub const FilterRule = struct {
        predicate: *const fn (ctx: PrivacyContext) ?Predicate,
    };
};

pub const Decision = enum {
    allow,
    deny,
    skip,
};
```

### 1.3 Rule Evaluation

Rules are evaluated in order with AND semantics:
- Skip → continue to next rule.
- Deny → immediate `error.PrivacyDenied`.
- Allow → stop evaluating allow/deny; accumulate remaining filter rules only.
- All filter predicates are AND-combined and injected into the SQL WHERE clause.

```
evalPolicy(ctx, rules) → DecisionSet
  ├── decision: .allow | .deny
  ├── filters: []Predicate  // all active filter predicates
  └── if decision == .deny → error.PrivacyDenied
```

### 1.4 Builder Integration

Every generated builder gains `.WithContext(ctx: PrivacyContext)`:

```zig
// Query
var q = client.User.Query();
q.WithContext(privacyCtx);
const users = try q.All(ctx.allocator);

// Create
var c = client.User.Create();
c.WithContext(privacyCtx);
const user = try c.SetName("Alice").Save(ctx.allocator);

// Update, Delete — same pattern.
```

**Safety:** If an entity has privacy rules AND the builder is used without `.WithContext()`, the operation returns `error.PrivacyDenied`. Entities without any privacy rules are unaffected and work as before. This is enforced at runtime (not comptime) because privacy rules may be conditional.

### 1.5 Filter Injection

`QueryBuilder.All/First/Only/IDs/Count/Exist` and `DeleteBuilder.Exec/ExecOne` inject accumulated filter predicates:

```zig
// User code:
q.WithContext(ctx);
q.Where(...user predicates...);

// Generated code appends privacy filters:
// SELECT * FROM users WHERE (<user predicates>) AND (<privacy filters>)
```

Update operations check the filter but do not inject (the privacy check is done before the mutation). Create operations check allow/deny only (no filter injection — the new entity has no rows to filter).

### 1.6 Files

| File | Change |
|------|--------|
| `src/runtime/privacy.zig` (new) | PrivacyContext, Decision, evalPolicy |
| `src/privacy/policy.zig` | Replace OldRule with Rule union, add FilterRule |
| `src/codegen/client.zig` | Add `.WithContext()` to generated builders |
| `src/codegen/query.zig` | Inject privacy filters in query execution |
| `src/codegen/create.zig` | Check privacy allow/deny before insert |
| `src/codegen/update_delete.zig` | Check privacy allow/deny and inject filters for delete |
| `tests/integration/sqlite.zig` | Multi-tenant privacy tests |

---

## 2. Hook System

### 2.1 HookContext and Hook

```zig
pub const HookContext = struct {
    op: Op,
    table_name: []const u8,
    /// Read-only pointer to the entity. Null for create-before.
    entity: ?*anyopaque,
    /// New field values for create/update. Null for delete/query.
    mutated: ?[]const FieldValue,
    /// Inherited from the builder.
    privacy: PrivacyContext,
    allocator: std.mem.Allocator,
};

pub const Hook = struct {
    op: Op,
    before: ?*const fn (ctx: *HookContext) HookError!void = null,
    after:  ?*const fn (ctx: *HookContext) HookError!void = null,
};

pub const HookError = error{
    ValidationFailed,
    Forbidden,
    HookFailed,
};
```

### 2.2 Execution Order

```
before hooks (ordered, first failure aborts)
  → privacy eval
    → SQL execute
      → after hooks (always run, even on SQL failure; failures logged, not propagated)
```

After hooks are fire-and-forget on error: their failures are logged via `std.log.err` but do not affect the operation result.

### 2.3 Registration

Builder-level: `client.User.Create().WithHooks(&my_hooks)`.
Client-level: existing pattern using entity-scoped hooks.
Global hooks: added to `src/runtime/hook.zig` as a shared registry for cross-cutting hooks (e.g., audit logging).

### 2.4 Files

| File | Change |
|------|--------|
| `src/runtime/hook.zig` | Add HookContext, HookError, global registry |
| `src/codegen/create.zig` | Call before/after hooks |
| `src/codegen/query.zig` | Call before/after hooks |
| `src/codegen/update_delete.zig` | Call before/after hooks |
| `tests/integration/sqlite.zig` | Hook abort test, mutation data test |

---

## 3. Prepared Statement Cache

### 3.1 Design

Per-connection, comptime-fixed-capacity LRU cache. No runtime allocation.

```zig
pub fn PreparedCache(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Entry = struct {
            sql_hash: u64,
            stmt: StmtHandle,   // driver-specific opaque handle
            last_used: i64,
        };

        entries: [capacity]Entry = undefined,
        len: usize = 0,

        pub fn getOrPrepare(
            self: *Self,
            sql: []const u8,
            prepareFn: anytype,
        ) !StmtHandle { ... }

        pub fn evictAll(self: *Self) void {
            for (self.entries[0..self.len]) |*e| e.stmt.deinit();
            self.len = 0;
        }

        pub fn deinit(self: *Self) void {
            self.evictAll();
        }
    };
}
```

**Cache key:** `std.hash.Wyhash.hash(0, sql)` — zero string duplication.
**DDL detection:** `exec()` checks if sql starts with `CREATE`, `ALTER`, or `DROP` (case-insensitive); if so, calls `cache.evictAll()` before executing.
**Default capacity:** 16 entries per connection. Overridable via driver init options.

### 3.2 Integration

Each driver (`SQLiteDriver`, `PostgresDriver`, `MySQLDriver`) gains an optional `cache: ?PreparedCache(16)` field. When non-null, `exec` and `query` use `cache.getOrPrepare` instead of preparing a new statement each time. When null (default for backward compatibility), behavior is unchanged.

### 3.3 Files

| File | Change |
|------|--------|
| `src/sql/cache.zig` (new) | PreparedCache generic |
| `src/sql/sqlite.zig` | Integrate cache in exec/query |
| `src/sql/postgres.zig` | Integrate cache in exec/query |
| `src/sql/mysql.zig` | Integrate cache in exec/query |

---

## 4. Driver Reliability

### 4.1 PostgreSQL ping() Fix

`src/sql/postgres.zig:256-261` currently only checks `PQstatus()` which returns stale status. Replace with an actual query:

```zig
fn pingFn(ptr: *anyopaque) driver.Error!void {
    const self: *PostgresDriver = @ptrCast(@alignCast(ptr));
    const result = c.PQexec(self.conn, "SELECT 1");
    defer c.PQclear(result);
    if (c.PQresultStatus(result) != c.PGRES_TUPLES_OK) {
        return toDriverError(error.PostgresPingFailed);
    }
}
```

### 4.2 Connection Retry

`pool.zig` gains retry logic in `borrow`:

```zig
fn borrow(self: *Self) PoolError!*D {
    var attempt: u32 = 0;
    while (true) {
        if (self.tryBorrow()) |conn| return conn;
        attempt += 1;
        if (attempt >= self.options.max_retries) break;
        std.time.sleep(self.options.retry_backoff_ms * std.time.ns_per_ms * attempt);
    }
    return error.PoolExhausted;
}
```

### 4.3 Query Timeout

- New `driver.Error.QueryTimeout` variant.
- `PoolOptions.query_timeout_ms` (default 0 = no timeout).
- `pooledExec`/`pooledQuery` start a `std.time.Timer` before calling the driver, check elapsed time after the driver call returns, and return `error.QueryTimeout` if exceeded.
- No async runtime required — timeout is cooperative (checked between driver calls, not preemptive).

### 4.4 Idle Connection Eviction

- `PoolOptions.max_idle_secs` (default 300 = 5 min).
- `PoolOptions.max_lifetime_secs` (default 3600 = 1 hour).
- Checked on `borrow`: if an idle connection exceeds `max_idle_secs`, close it and create a fresh one.
- Checked on `release`: if total connection age exceeds `max_lifetime_secs`, close it instead of returning to pool.

### 4.5 Files

| File | Change |
|------|--------|
| `src/sql/driver.zig` | Add `QueryTimeout` to Error |
| `src/sql/postgres.zig` | Fix ping() |
| `src/sql/pool.zig` | Retry, timeout, idle/lifetime eviction |
| `src/sql/pool.zig` tests | New unit tests |

---

## 5. Observability

### 5.1 Logger Interface

```zig
pub const Logger = struct {
    onQuery: ?*const fn (ctx: LogContext) void = null,
    onExec:  ?*const fn (ctx: LogContext) void = null,
    onError: ?*const fn (ctx: LogContext) void = null,
};

pub const LogContext = struct {
    sql: []const u8,
    args: ?[]const sql.Value = null,
    duration_us: u64,
    rows_affected: usize = 0,
    error: ?anyerror = null,
    table_name: []const u8 = "",
};
```

### 5.2 Client Integration

```zig
// Zero-cost when Logger fields are null (optimized away by LLVM).
client.SetLogger(my_logger);

// Convenience: write all queries to stderr.
client.Debug(); // sets built-in std.log.debug logger
```

### 5.3 Sensitive Field Masking

- `Field.Sensitive()` marks a field as sensitive.
- Logger callbacks receive masked values (`"***"`) for sensitive fields.
- `std.fmt.format` on a sensitive entity uses masking.
- No performance impact on non-logged paths.

### 5.4 Files

| File | Change |
|------|--------|
| `src/sql/logger.zig` (new) | Logger, LogContext, built-in debug logger |
| `src/codegen/client.zig` | SetLogger, Debug |
| `src/codegen/create.zig` | Log query/exec/error via logger |
| `src/codegen/query.zig` | Log query/exec/error via logger |
| `src/codegen/update_delete.zig` | Log query/exec/error via logger |
| `src/core/field.zig` | Add sensitive flag |
| `src/codegen/entity.zig` | Sensitive field format masking |

---

## 6. Migration Enhancements

### 6.1 New Operations

```zig
const MigrationOp = enum {
    create_table,
    drop_table,
    add_column,
    drop_column,
    alter_column_type,
    create_index,
    drop_index,
    add_foreign_key,
};
```

### 6.2 MigrateOptions

```zig
pub const MigrateOptions = struct {
    dry_run: bool = false,
    drop_columns: bool = false,
    allow_data_loss: bool = false,
};
```

**Defaults are safe:** `drop_columns` and `allow_data_loss` must be explicitly enabled.

### 6.3 DROP COLUMN

Generated SQL per dialect:
- SQLite: `ALTER TABLE t DROP COLUMN col` (supported since 3.35)
- PostgreSQL: `ALTER TABLE t DROP COLUMN col CASCADE`
- MySQL: `ALTER TABLE t DROP COLUMN col`

### 6.4 ALTER COLUMN TYPE

- PostgreSQL: `ALTER TABLE t ALTER COLUMN col TYPE new_type USING col::new_type`
- SQLite: Not natively supported. Document that ALTER TYPE requires `allow_data_loss: true` and uses the table-rebuild pattern (create new table, copy data, drop old, rename).
- MySQL: `ALTER TABLE t MODIFY COLUMN col new_type`

### 6.5 Dry Run

When `dry_run: true`, `migrateSchema` collects all generated SQL into an `ArrayList` and prints it (via caller-supplied writer) without executing. No transaction is opened.

### 6.6 Files

| File | Change |
|------|--------|
| `src/sql/schema/migrate.zig` | MigrateOptions, DROP COLUMN, ALTER TYPE, dry-run |
| `tests/integration/sqlite.zig` | DROP COLUMN test, dry-run test |
| `tests/integration/postgres.zig` | ALTER TYPE test |
| `tests/integration/mysql.zig` | DROP COLUMN test |

---

## 7. API Completeness

### 7.1 Cursor-Based Pagination

```zig
// codegen query.zig
pub fn Cursor(self: *Self, column: []const u8, value: sql.Value) *Self;
pub fn CursorAfter(self: *Self, entity: Entity) *Self;
```

Generated SQL: `WHERE (col > ?) ORDER BY col ASC LIMIT ?`. Uses O(1) key lookup vs O(n) offset scan.

### 7.2 CTE (Common Table Expressions)

`src/sql/builder.zig`:

```zig
pub fn with(self: *Builder, name: []const u8, subquery: *const Builder) !void;
```

Generated SQL: `WITH <name> AS (<subquery>) SELECT ...`. Supports chaining for multiple CTEs.

### 7.3 EntQL: HasEdge Syntax

`src/entql/parser.zig`:

```zig
// Parse: has(edge_name)       → edge existence check
// Parse: has(edge_name, ...)  → edge existence with nested predicates
// Parse: not_has(edge_name)   → edge non-existence
```

### 7.4 EntQL: NOT IN, EQFold

```zig
// Parse: field NOT IN (a, b, c)
// Parse: field =~ value      → EQFold (case-insensitive equality)
```

### 7.5 Schema Annotations

`src/core/schema.zig`:

```zig
pub fn Annotations(comptime anns: anytype) Schema { ... }
```

Stored as comptime metadata; accessible via `TypeInfo.annotations`. Used by codegen for documentation generation and by migration layer for table/column comments.

### 7.6 Files

| File | Change |
|------|--------|
| `src/codegen/query.zig` | Cursor, CursorAfter |
| `src/sql/builder.zig` | CTE WITH clause |
| `src/entql/parser.zig` | has(), has() with preds, not_has(), NOT IN, EQFold |
| `src/core/schema.zig` | Annotations |
| `src/core/field.zig` | Sensitive flag (Section 5) |

---

## Error Handling

- `driver.Error` gains `QueryTimeout`.
- `HookError` is separate from `driver.Error`; builders merge them into public error unions.
- Privacy evaluation failures return `error.PrivacyDenied` (already exists in codegen error sets).
- All new allocations use `std.testing.allocator` in tests for leak detection.

## Testing

- **Unit tests:** All new modules have inline tests with `std.testing.allocator`.
- **Integration tests:** Privacy multi-tenant scenario (two users, row-level isolation), hook abort (before hook returns error → no DB mutation), dry-run output verification, DROP COLUMN → idempotent re-run.
- **Existing tests:** Must continue to pass unchanged.
- **Bench:** Add prepared-cache hit-rate benchmark.

## Success Criteria

- `zig build test` and `zig build test-integration` pass with 0 leaks.
- `zig fmt --check src examples tests build.zig` passes.
- Privacy: multi-tenant isolation verified by integration test.
- Hooks: abort test prevents mutation; mutation data accessible in after hook.
- Prepared cache: benchmark shows ≥90% hit rate for repeated queries.
- Migrations: DROP COLUMN + ALTER TYPE work on all three dialects.
- No breaking changes to existing public APIs.

## Out of Scope

- Async/event-loop integration.
- Distributed tracing (OpenTelemetry).
- WINDOW functions (can be done as raw SQL).
- Atlas-style migration file format (version files deferred).
- Connection pooling across multiple hosts (single-host pool only).
