# Open items

What is **still open**, in one place, with the evidence. `CHANGELOG.md` records
each item where it was found and each fix where it landed, which is the right
shape for history — but reading "what is open right now" out of it means diffing
the accumulated notes against every later release. This file is that diff, kept
current instead.

**Not a wish list.** Everything here was observed: a measurement, a reproduction,
or source that says something the docs do not.

- `docs/ISSUES_FROM_ZAPI.md` — consumer-reported items (Z1–Z35), with verdicts.
- `docs/BEST_PRACTICES.md` §5h — what `checkSchema` does **not** compare.
- `CHANGELOG.md` — history, including the negative audit results.

---

_Resolved in v0.70.0: the pool no longer parks when it has room to serve, and
SQLite now enforces foreign keys. Resolved in v0.71.0: the missing-uuid-key
error is `MissingPrimaryKey` on every dialect (decided before the statement
runs), the insert log sites report the rows the server wrote, and the pool
records an `all.append` OOM as itself. Two items were examined and deliberately
kept — now pinned in comments so they are not "fixed" into something worse:
`borrowErrorFor` folding unknown driver errors into `PoolExhausted` (the
bounded set `asDriver` needs; the unmapped name stays in the warn log) and
`driverInTransaction` answering `false` on a failed borrow (the `beginTxCtx`
preflight routes `false` to `beginTx`, whose own borrow surfaces the real
error). This file is pruned as items land; history lives in `CHANGELOG.md`._

## Needs a decision before it can be fixed

| Item | Evidence | Why it needs you |
|---|---|---|
| **A junction table name colliding with a declared entity table is undetected** | `junctionTableForEdge` derives `<a>_<b>`, and `createTableSQLAlloc` emits `CREATE TABLE IF NOT EXISTS`, so the first one created wins silently. An entity whose table is literally that pair's name is enough | Detecting it means either validating names at graph build (a new compile-time error) or reporting it in `checkSchema` (a new drift kind) |
| **`zig build migrate-rollback` does not inherit the caller's DSN** | `build.zig`'s `migrate-rollback` step calls `setEnvironmentVariable`, which materialises the env map into the long-lived build-server process; `migrate` (`build.zig:205`) does not and works. So the rollback step cannot be pointed at a database from the shell | Fixing it means changing how the step passes env — worth doing, but it touches the build's structure |

## Open, with a known shape

| Item | Evidence |
|---|---|
| **`SaveOne` / `ExecOne` lose `rows_affected_known` at the `usize` boundary** | They return `usize`, so a driver that could not count reads as "0 rows" and answers `NotFound`. `UPDATE`/`DELETE` counts are known on all three dialects, so it is unreachable today — it is the one place the v0.63.0 distinction does not reach |
| **`sql.MultiInsert`'s length assertion does not validate what the rows set** | It asserts `values.len == columns.len * row_count`, which holds because the buffer is sized from the column list. The insert layer now checks the rows against each other (v0.69.0), so the assert is no longer the only guard — but it is still about the buffer, not the input |
| **MySQL's prepared `exec` path never drains its result set** | So a parameterised `SELECT` through `exec` reports `rows_affected_known = false` where the unprepared path reports the row count (v0.63.0 documented the difference). Draining would make the two agree at the cost of materialising a result set `exec` is about to discard |
| **`outbox.nowMs` falls back to `0`** | A `gettimeofday` failure would stamp `claimed_at = 0` (immediately stale) and compute a negative cutoff for `requeueStale`. The syscall cannot fail for a valid pointer, so it is unreachable — recorded because it is the same "unknown as a value" shape |
| **`field.String` is `VARCHAR(255)` on MySQL with no length validation** | Since v0.57.0 the API does not express the cap; a longer value that PostgreSQL and SQLite accept errors on MySQL under a strict `sql_mode` and truncates under a permissive one. `BEST_PRACTICES` documents it; nothing enforces it |
| **The MySQL BLOB/TEXT `DEFAULT` guard is stricter than MariaDB requires** | MariaDB ≥ 10.2.1 accepts a `DEFAULT` on `TEXT`; the DDL layer cannot tell the two servers apart without a connection, so it applies MySQL's rule to both (v0.58.0, restated in v0.60.0). A MariaDB user who needs it must hand-write the migration |
| **`examples/migrate`'s DSN dispatch stops at `postgres://`** | A libpq keyword/value conninfo (the shape `PG_DSN` has in CI) is not recognised, so the example cannot be pointed at that deployment. `examples/check_sql` handles it |

## Open in the ledger

| ID | What remains |
|---|---|
| Z14 | The `Contains` rename itself (the `Like` alias and the docs shipped). The rename gets more expensive with every adopter |
| Z16 | Multi-graph stages 2/3: a cross-graph edge fails at *runtime* with a named error (stage 1), not at compile time |
| Z31 | `view_sql` replacement; `UNIQUE` / foreign keys added by `ALTER` on an existing table |
| Z32 | A bare `sql.InSelect` does not scope its inner table; `Has*` targets do. Documented as out of reach for the `sql` layer (it has no graph) |

## Structural gaps

| Gap | Why it matters |
|---|---|
| **MariaDB differences are still found after the tag is pushed** | The new `tests/integration/dialect_matrix.zig` now compares the dialects directly, which covers the semantic half. What it cannot cover is a difference neither harness knows to ask about, and this session's three escapes (`column_default` quoting, functional indexes, `BEGIN` through prepare) were all of that kind. The only root fix is a local MariaDB or a working container runtime |
| **Modules the audit method has not reached** | `codegen/query.zig`'s full branches (2422 lines; entry/scope/cursor read so far), `graph.zig` / `meta.zig`, `update_delete.zig`'s edge-write branches, the drivers' dialect-specific edges, `bench/`, and `examples/` other than `check_sql` and `migrate`. The method's hit rate has stayed high — `catch {}` 20 sites → 1 defect, `catch null`/`catch 0` 10 → 2, the high-level modules → 4 including a privilege escalation, the unaudited modules → an EntQL fail-open — so this is where a defect is most likely to be found rather than reported |
| **Log text is not assertable** | This repository has no `logFn`, so warnings cannot be captured in tests. Several fixes in this series are therefore pinned only at the level below the message (the renderer, or the value a callback receives), and each one says so rather than claiming an end-to-end assertion |
| **`migrations/001_create_users.up.sql` is SQLite-only DDL** | It uses `INTEGER PRIMARY KEY AUTOINCREMENT`, so the `migrate` example's own migrations fail on MySQL and PostgreSQL (`errno=1064` / equivalent). The example is otherwise dialect-aware |
