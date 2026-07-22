# MySQL Real Upsert Semantics Design

## Goal
Change `CreateBuilder.SaveOrUpdate` for MySQL from `REPLACE INTO` to `INSERT ... ON DUPLICATE KEY UPDATE`, preserving existing rows (including auto-increment values and foreign-key relationships) instead of deleting and re-inserting them.

## Background
The current MySQL path in `src/codegen/create.zig` replaces the leading `INSERT` keyword with `REPLACE` for `SaveOrUpdate`. `REPLACE INTO` is MySQL-specific syntax that deletes the existing row before inserting a new one. This has unintended side effects:
- Triggers `DELETE` and `INSERT` triggers instead of just `UPDATE`.
- Resets auto-increment sequences.
- Breaks foreign-key `ON DELETE CASCADE` expectations.

The PostgreSQL path already uses the correct `ON CONFLICT ... DO UPDATE` semantics. SQLite uses `INSERT OR REPLACE`, which has the same delete/insert behavior as MySQL `REPLACE INTO` but is acceptable for SQLite's typical usage and is explicitly documented in SQLite.

## Design

### 1. Extend `buildUpsertSuffix` to support MySQL

In `src/codegen/create.zig`, modify `buildUpsertSuffix` so that when the dialect is MySQL and `or_replace` is true it returns a string like:

```sql
 ON DUPLICATE KEY UPDATE `name`=VALUES(`name`), `age`=VALUES(`age`)
```

Rules:
- Skip the `"id"` column (the conflict target is implicit in MySQL via the primary/unique key).
- Quote column names using the MySQL identifier quote character `` ` ``.
- The generated suffix references the insert row values via MySQL's `VALUES(col)` function, so no extra bound parameters are needed.

### 2. Change the MySQL execution path

In the MySQL-only branch of `saveInternal` (the `else` block where `supports_returning` is false):
- Remove the `REPLACE` keyword replacement.
- Keep the normal `INSERT INTO ... VALUES (...)` query.
- Append the MySQL upsert suffix returned by `buildUpsertSuffix`.
- Execute the resulting SQL with the same args.

### 3. Preserve PostgreSQL and SQLite behavior

- PostgreSQL keeps its existing `ON CONFLICT ("id") DO UPDATE SET ...` suffix.
- SQLite keeps its existing `INSERT OR REPLACE INTO ...` behavior via the `sql.InsertOrReplace` builder.

### 4. Testing

Add an integration test that:
- Creates a MySQL table with an auto-increment primary key and a foreign-key child table.
- Inserts a parent row with `SaveOrUpdate`, noting its auto-increment id.
- Calls `SaveOrUpdate` again with the same unique key.
- Asserts that the parent row's `id` did **not** change (proving it was not deleted/re-inserted).
- Asserts that child rows referencing the parent still exist (proving `ON DELETE CASCADE` did not fire).

If MySQL is not available locally, the test follows the existing pattern of being compiled but skipped at runtime when the MySQL server is unreachable.

## Files

- `src/codegen/create.zig` — modify `buildUpsertSuffix` and the MySQL execution path.
- `tests/integration/mysql.zig` — add upsert semantics test.

## Acceptance Criteria

- `zig build test` passes.
- `zig build test-integration` passes (MySQL test runs when server is available; otherwise skipped cleanly).
- Generated MySQL `SaveOrUpdate` SQL contains `ON DUPLICATE KEY UPDATE` and no `REPLACE`.
- PostgreSQL and SQLite `SaveOrUpdate` behavior is unchanged.
