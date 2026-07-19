# zent Production Readiness Phase 2 Design

## Goal

Fix the remaining high-priority production readiness gaps identified in the production assessment: memory ownership for JSON fields and the connection pool, narrow driver error sets, and cross-dialect schema migrations with history tracking.

## Scope

### In scope
1. **Memory ownership**
   - Per-entity JSON arena: entities with JSON struct fields carry an internal arena that owns the parsed JSON data. `deinitEntity` frees the arena.
   - Pool borrow leak: close newly opened connections if pool bookkeeping allocation fails.
   - Remove `@constCast` from `deinitEntity` by requiring mutable entity pointers.

2. **Error set narrowing**
   - Define a unified `driver.Error` error set in `src/sql/driver.zig`.
   - Update the `Driver` and `Tx` vtables to return `Error!T`.
   - Map each backend's concrete errors into the unified set.

3. **Cross-dialect migrations**
   - Add dialect-aware introspection for SQLite (`PRAGMA`), PostgreSQL (`information_schema` + `pg_indexes`), and MySQL (`information_schema`).
   - Introduce a `schema_migrations` history table to track applied migrations.
   - Wrap `migrateSchema` in a transaction.

### Out of scope
- Down migrations / rollbacks.
- Column drops or type changes.
- Foreign-key additions on existing tables.
- Concurrent index creation safety beyond transaction wrapping.
- Prepared-statement caching.

## Architecture

### Memory ownership

The codegen entity generator (`src/codegen/entity.zig`) already emits per-field deinit logic. For JSON struct fields it currently does nothing because `isOwningField` only recognizes slices. We extend the generated entity type with a comptime-optional `json_arena: ?*std.heap.ArenaAllocator` field when any field is a JSON struct.

- `valueToType` (create/scan path) creates the arena on first JSON struct parse and stores it in the entity.
- `deinitEntity` checks the arena field and, if present, frees the arena and all parsed JSON structs within it.
- `deinitEntity` signature remains `pub fn deinitEntity(entity: anytype, allocator: Allocator) void`, but callers must pass `*T`. A comptime assertion rejects `*const T`.

### Error set narrowing

A new `driver.Error` error set combines common domain errors with a generic fallback:

```zig
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

- Driver vtable methods return `Error!T`.
- Each driver maps its native errors:
  - SQLite: `SqliteOpenFailed` → `ConnectionFailed`, `SqlitePrepareFailed` → `PrepareFailed`, etc.
  - PostgreSQL: `PostgresConnectFailed` → `ConnectionFailed`, `PostgresExecFailed` → `ExecFailed`, etc.
  - MySQL: `MySQLConnectFailed` → `ConnectionFailed`, `MySQLExecFailed` → `ExecFailed`, `MySQLDataTruncated` → `ProtocolError`, etc.
- Codegen builders continue to propagate `!T`; internal `try drv.exec(...)` calls now produce `Error` instead of `anyerror`.

### Cross-dialect migrations

`src/sql/schema/migrate.zig` gains a dialect switch in introspection functions:

| Dialect | Columns | Indexes |
|---|---|---|
| SQLite | `PRAGMA table_info` | `PRAGMA index_list` + `PRAGMA index_info` |
| PostgreSQL | `information_schema.columns` | `pg_indexes` + `pg_index` |
| MySQL | `information_schema.columns` | `information_schema.statistics` |

The migration history table `zent_schema_migrations` stores:
- `version`: integer migration version
- `applied_at`: timestamp
- `checksum`: optional hex checksum of the migration inputs

`migrateSchema` executes inside a transaction when the driver supports it. Each table/column/index change is recorded in `zent_schema_migrations` before commit.

## Interfaces

### Entity JSON arena

```zig
// Generated into entities that contain JSON struct fields
pub json_arena: ?*std.heap.ArenaAllocator = null;
```

`deinitEntity` behavior:
- If `json_arena` is non-null, call `arena.deinit()` and `allocator.destroy(arena)`.
- Then free owning string/slice fields as today.

### Driver error set

```zig
// src/sql/driver.zig
pub const Error = error{ ... };

pub const VTable = struct {
    exec: *const fn (ptr: *anyopaque, query: []const u8, args: []const Value) Error!Result,
    query: *const fn (ptr: *anyopaque, query: []const u8, args: []const Value) Error!Rows,
    beginTx: *const fn (ptr: *anyopaque) Error!Tx,
    close: *const fn (ptr: *anyopaque) void,
    dialect: *const fn (ptr: *anyopaque) Dialect,
    ping: *const fn (ptr: *anyopaque) Error!void,
    inTransaction: *const fn (ptr: *anyopaque) bool,
};
```

### Migration history

```zig
const MigrationRecord = struct {
    version: i64,
    applied_at: i64, // seconds since epoch
    checksum: ?[]const u8,
};

fn ensureMigrationsTable(driver: driver.Driver) Error!void;
fn appliedVersions(driver: driver.Driver, allocator: Allocator) Error![]i64;
fn recordMigration(driver: driver.Driver, record: MigrationRecord) Error!void;
```

## Error Handling

- JSON arena allocation failures propagate as `error.OutOfMemory`.
- Driver vtable errors propagate as `driver.Error`.
- Migration failures abort the transaction and roll back partial changes.
- `deinitEntity` is infallible (`void`) but logs via `std.log.err` if a JSON arena pointer is stale.

## Testing

- Unit test: `deinitEntity` frees a JSON struct field and its arena with 0 leaks.
- Unit test: `ConnPool` does not leak a connection when `all.addOne` fails (can be simulated with a failing allocator).
- Unit test: driver error mapping for each backend produces the expected `driver.Error`.
- Integration test: `migrateSchema` runs successfully on SQLite, PostgreSQL, and MySQL against an existing schema.
- Integration test: re-running `migrateSchema` is idempotent thanks to the history table.

## Success Criteria

- `zig build test` and `zig build test-integration` pass with 0 leaks.
- `zig fmt --check src examples tests build.zig` passes.
- Public API for entity deinit and driver calls remains source-compatible for typical usage.
- Migrations work on SQLite, PostgreSQL, and MySQL.

## Future Work

- Down migrations and schema versioning files.
- Column drops and type changes.
- Foreign-key management on existing tables.
- Prepared-statement caching.
