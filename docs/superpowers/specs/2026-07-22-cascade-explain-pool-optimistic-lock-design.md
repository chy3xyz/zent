# Design: Cascade Delete/Update, EXPLAIN/Pool, Optimistic Locking

## 1. Cascade Delete/Update

### Goal
When a parent entity is deleted or updated, ensure related child entities are handled according to the edge definition.

### Approach
Use database-level foreign key cascading as the primary mechanism. The schema already defines `on_delete` and `on_update` on `ForeignKeyDef`; the migration layer must emit these clauses in `CREATE TABLE`.

- Hard deletes rely on `ON DELETE CASCADE` / `ON UPDATE CASCADE`.
- Soft-delete propagation is out of scope for this phase.

### Changes
- `src/sql/schema/migrate.zig`: ensure `createTableSQL` emits `ON DELETE {action}` and `ON UPDATE {action}` for every foreign key.
- `src/codegen/update_delete.zig`: `DeleteBuilder` hard delete path stays unchanged; DB cascade handles children.
- Tests: SQLite integration test that creates a parent/child schema, deletes the parent, and asserts children are removed.

### Error Handling
- If the database does not support cascade (rare), the existing FK constraint will raise a constraint error, propagated as `ExecFailed`.

## 2. EXPLAIN Integration

### Goal
Allow users to inspect the execution plan of a generated query without leaving the fluent API.

### API

```zig
const plan = try client.user.Query().Where(...).Explain(allocator, .text);
defer plan.deinit(allocator);
std.debug.print("{s}\n", .{plan.sql});
```

### Changes
- `src/codegen/query.zig`: add `Explain(allocator, format)` to `QueryBuilder` and `Selector`.
- `src/sql/builder.zig` or new `src/sql/explain.zig`: dialect-specific EXPLAIN SQL generation.
  - SQLite: `EXPLAIN QUERY PLAN <sql>`
  - PostgreSQL: `EXPLAIN (FORMAT TEXT|JSON) <sql>`
  - MySQL: `EXPLAIN <sql>`
- `src/sql/driver.zig`: expose query result as text rows.
- Return type `ExplainResult` containing the raw plan text.

### Error Handling
- Unsupported dialect/format returns `error.UnsupportedDialect`.
- Driver errors propagate normally.

## 3. Connection Pool Enhancement

### Goal
Make pooled connections production-ready with health checks and lifecycle management.

### Changes
- `src/sql/pool.zig`:
  - Add `Options`: `max_idle_time_secs`, `max_lifetime_secs`, `health_check_on_borrow`, `max_create_retries`, `retry_backoff_ms`.
  - `borrow()`: ping the connection before returning; if ping fails, close and retry up to `max_create_retries`.
  - `release()`: check `max_lifetime_secs`; close if expired.
  - Evict idle connections older than `max_idle_time_secs` on borrow.
- Tests: unit tests for eviction and retry behavior using a fake clock if possible.

### Error Handling
- `error.PoolExhausted` after all retries are exhausted.

## 4. Optimistic Locking

### Goal
Prevent lost updates in concurrent write scenarios using a version number field.

### Approach
Introduce a convention-based version field. The code generator detects a field named `version` of type `Int` with `optimistic_lock: true` (or a new `field.Version("version")` helper) and injects it into UPDATE and DELETE WHERE clauses.

### API

```zig
const User = schema("User", .{
    .fields = &.{
        field.Int("id"),
        field.String("name"),
        field.Version("version"),
    },
});
```

### Changes
- `src/core/field.zig`: add `Version(name)` helper and `is_version` flag on `FieldInfo`.
- `src/codegen/graph.zig`: propagate `is_version` in `TypeInfo`.
- `src/codegen/update_delete.zig`:
  - `UpdateBuilder.Save()`: append `AND version = $old` to WHERE, then `SET version = version + 1`.
  - `DeleteBuilder.Save()`: append `AND version = $old` to WHERE for hard delete.
  - If affected rows == 0, return `error.OptimisticLockConflict`.
- `src/codegen/create.zig`: version field gets `DEFAULT 0` and `NOT NULL`.
- Tests: integration test that simulates a stale update and asserts `OptimisticLockConflict`.

### Error Handling
- New error `error.OptimisticLockConflict`.
- Missing version field on an entity is silently ignored (no lock).

## Implementation Order

1. Cascade delete/update (smallest change, high impact).
2. Optimistic locking (touches code generation, well-bounded).
3. EXPLAIN + pool enhancement (relatively independent, can be parallelized).

## Testing

- Unit tests for new codegen behavior.
- SQLite integration tests for cascade and optimistic lock.
- Pool unit tests with mocked time if available; otherwise manual tests.
- `zig build test` and `zig build test-integration` must pass.
- `zig fmt --check src examples tests build.zig` must pass.
