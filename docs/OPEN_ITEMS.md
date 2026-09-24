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
error). Resolved in v0.75.0: a junction name that is also a declared entity's table is
reported as its own `junction_name_collision` drift (both surfaces named, and
classified read-breaking, so a deploy gate stops on it) instead of surfacing as
the shape symptoms, and `migrateSchema` warns at the moment it plans the
junction's `CREATE TABLE IF NOT EXISTS`. Resolved in v0.73.0: `CrudService.getOwned` names the row's allocator and
`deinitRowWith` is the release that matches it, a column-level `UNIQUE` is
enforced on an existing table (the migration adds the unique index), and
`Sum`/`Avg` answer `error.EmptyAggregate` for an empty set instead of the
`error.TypeMismatch` a non-numeric value produces. Resolved in v0.72.0:
`Restore` is scoped by the policy's filters and the
interceptor chain, `queryTargets*`/`QueryEdge` report a mid-read failure instead
of a short page, `IDs()` projects the primary key, the EntQL `has()`/`not_has()`
lowerings and the `WithEdgeOptions` inner join carry the target's soft-delete
scope, and an m2m existence predicate is qualified to the target table. This
file is pruned as items land; history lives in `CHANGELOG.md`._

**Negative results from the v0.72.0 audit** (recorded so the ground is known to
be covered): `update_delete.zig`'s edge-write branches — `SetEdgeIDs`,
`ClearEdge`, `AddEdgeIDs`, `RemoveEdgeIDs` — are idempotent by construction
(`INSERT OR IGNORE` / `DELETE` / `SET fk = NULL`), scope themselves with the
same predicate set as the main UPDATE (policy filters and interceptor
predicates included), and their partial-write-on-error shape is documented;
`bench/` holds nothing beyond a benchmark-only instance of the `nextError()`
shape (there is no production path in it); `codegen/graph.zig`, `meta.zig`,
`graph/step.zig`, `mermaid.zig` and `doc_exporter.zig` are comptime or pure data
with no runtime failure shapes to audit.

## Needs a decision before it can be fixed

| Item | Evidence | Why it needs you |
|---|---|---|
| **`zig build migrate-rollback` does not inherit the caller's DSN** | `build.zig`'s `migrate-rollback` step calls `setEnvironmentVariable`, which materialises the env map into the long-lived build-server process; `migrate` (`build.zig:205`) does not and works. So the rollback step cannot be pointed at a database from the shell | Fixing it means changing how the step passes env — worth doing, but it touches the build's structure |
| **`Count` / `Sum` / `Avg` / `Max` / `Min` read one row of a grouped query** | With `GroupBy` set, these read the first row only — the first group's aggregate is presented as *the* answer — and zero groups makes `Count()` answer `NotFound` where 0 is the expected count (`query.zig:1130-1145` via `buildCountQuery:1600-1620`, and `buildAggregateQuery:1622-1653`). Either reject group/order/limit on these methods (a compile-time or runtime error) or wrap the grouped select in a subquery | Rejecting breaks callers that pass a GroupBy today; the subquery wrap changes the emitted SQL on all three dialects |
| **EntQL speaks physical column names, not field names** | `parseComparison` (`entql/parser.zig:433-440`) never maps an ident through `columnName`, so on a schema using `.StorageKey`, `WhereEntQL("name = …")` addresses the literal column `name`. v0.74.0 closed the dangerous half — an ident the entity in scope does not have is now `error.UnknownField` before any SQL is built, including inside `has(...)`, and **either** spelling of a field is accepted — so what is left is the naming question: map idents to `columnName` at lowering, or state in the EntQL docs that this expression language addresses physical columns. Decide | Mapping needs the whole parse tree lowered with the schema in hand (the codegen layer has it); documenting is a docs-only change but leaves the ambiguity for a schema that declares both columns |

## Open, with a known shape

| Item | Evidence |
|---|---|
| **`SaveOne` / `ExecOne` answer `NotFound` from a count the driver may not have obtained** | `update_delete.zig:858` / `:992` compare a `usize` that came from `Save()`/`Exec()`, which fold `rows_affected_known` away: a driver that could not count reads as `0` and the caller is told "no row matched". Unreachable today (all three dialects count `UPDATE`/`DELETE`), so closing it means either changing those return types — breaking for every caller — or adding `*Outcome` twins for a branch no in-tree driver produces. Cost is in the API surface, not the fix; a decision is needed on which |
| **`paged()` and `All()` hand back the same entity list under two release contracts** | `PagedResult.deinit()` frees rows and list; `All()` needs `q.deinitRows(&rows)` (or a per-row `deinitEntity` plus `deinit`). Both have a correct one-call exit and both are documented, but a mechanical migration between them is easy to get wrong — their consumer reports `paged` being the single "touch nothing" special case in 177 migrated call sites. Making it unrepresentable means an owning wrapper type for `All()`'s result, which changes every call site |

| Item | Evidence |
|---|---|
| **A comparison predicate on a junction-only column can still bind to the junction** | `sql.appendQualifiedPred` (`builder.zig:613`) rewrites only the shapes whose column is a plain name (`eq`, `is_null`, `is_not_null`) and appends the rest verbatim, because rewriting arbitrary SQL text is not safe. The m2m existence body now qualifies through it (v0.72.0), so `has(groups, user_id = …)` fails at prepare time — but a non-eq EntQL comparison naming a column the target lacks, where the junction has a `<x>_id` of that name, still binds there. The tracked fix is validating EntQL field names against the target schema at lowering (`error.UnknownField`), the same shape as `QueryView.whereEq`'s sink |
| **`SaveOne` / `ExecOne` lose `rows_affected_known` at the `usize` boundary** | They return `usize`, so a driver that could not count reads as "0 rows" and answers `NotFound`. `UPDATE`/`DELETE` counts are known on all three dialects, so it is unreachable today — it is the one place the v0.63.0 distinction does not reach |
| **`sql.MultiInsert`'s length assertion does not validate what the rows set** | It asserts `values.len == columns.len * row_count`, which holds because the buffer is sized from the column list. The insert layer now checks the rows against each other (v0.69.0), so the assert is no longer the only guard — but it is still about the buffer, not the input |
| **MySQL's prepared `exec` path never drains its result set** | So a parameterised `SELECT` through `exec` reports `rows_affected_known = false` where the unprepared path reports the row count (v0.63.0 documented the difference). Draining would make the two agree at the cost of materialising a result set `exec` is about to discard |
| **`outbox.nowMs` falls back to `0`** | A `gettimeofday` failure would stamp `claimed_at = 0` (immediately stale) and compute a negative cutoff for `requeueStale`. The syscall cannot fail for a valid pointer, so it is unreachable — recorded because it is the same "unknown as a value" shape |
| **`field.String` is `VARCHAR(255)` on MySQL with no length validation** | Since v0.57.0 the API does not express the cap; a longer value that PostgreSQL and SQLite accept errors on MySQL under a strict `sql_mode` and truncates under a permissive one. `BEST_PRACTICES` documents it; nothing enforces it |
| **The MySQL BLOB/TEXT `DEFAULT` guard is stricter than MariaDB requires** | MariaDB ≥ 10.2.1 accepts a `DEFAULT` on `TEXT`; the DDL layer cannot tell the two servers apart without a connection, so it applies MySQL's rule to both (v0.58.0, restated in v0.60.0). A MariaDB user who needs it must hand-write the migration |

## Open in the ledger

| ID | What remains |
|---|---|
| Z14 | The `Contains` rename itself (the `Like` alias and the docs shipped). The rename gets more expensive with every adopter |
| Z16 | Multi-graph stages 2/3: a cross-graph edge fails at *runtime* with a named error (stage 1), not at compile time |
| Z31 | `view_sql` replacement; foreign keys added by `ALTER` on an existing table (the **column-level `UNIQUE`** half landed in v0.73.0 — the migration adds a unique index) |
| Z32 | A bare `sql.InSelect` does not scope its inner table; `Has*` targets do. Documented as out of reach for the `sql` layer (it has no graph) |

## Structural gaps

| Gap | Why it matters |
|---|---|
| **The allocation-failure sweep still has known gaps** | `src/test/allocation_failures*.zig` use `std.testing.checkAllAllocationFailures` (Zig 0.17) to fail every allocation in turn and hold the byte ledger; they have found fifteen leak sites so far (three in `sql/builder.zig` at v0.76.1; at v0.77.0 five in the `sql/scan.zig` scanners and `queryAll`, three in `sql/schema/migrate.zig`'s planning and SQLite introspection, and four in the MySQL/PostgreSQL introspection, those last by inspection). They also found a *contract* defect: JSON parsing reported an out-of-memory as `TypeMismatch`, which the lenient scanners turned into the field's default (fixed v0.77.1). Covered today: fragment rendering, an assembled SELECT, the row scanners including the JSON/arena half (v0.77.1), `queryAll`, `planMigrateStatements`, `CrudService.getOwned`, and the neighbour fragments (clean). Uncovered, in the order they are most likely to hide something: (**a**) `getMySQLIndexes` / `getPostgresIndexes`, whose leaks were fixed by inspection because the stub's catalog is SQLite-only — they need a per-dialect stub; (**b**) `Builder.init`, which *swallows* an induced OOM by design, so the sweep reports `SwallowedOutOfMemoryError` and skips it (`initCapacity` is swept instead); (**c**) the higher-level services that assemble several of these pieces (`outbox.zig`, `crud_helpers.zig`, `shard.zig`), none of which is swept yet |
| **MariaDB differences are still found after the tag is pushed** | The new `tests/integration/dialect_matrix.zig` now compares the dialects directly, which covers the semantic half. What it cannot cover is a difference neither harness knows to ask about, and this session's three escapes (`column_default` quoting, functional indexes, `BEGIN` through prepare) were all of that kind. The only root fix is a local MariaDB or a working container runtime |
| **Modules the audit method has not reached** | `codegen/query.zig`'s full branches, `codegen/graph.zig` / `meta.zig`, `graph/step.zig`, `update_delete.zig`'s edge-write branches and `bench/` were audited in the v0.72.0 pass (5 defects, all fixed; the negative results are recorded above). Still unread: the drivers' dialect-specific edges (`sql/sqlite.zig`, `mysql.zig`, `postgres.zig` beyond the result-decoding paths), `crud.zig` / `helpers.zig` / `shard.zig`, `privacy/`'s rule evaluation, and `examples/` other than `check_sql` and `migrate`. The method's hit rate has stayed high — `catch {}` 20 sites → 1 defect, `catch null`/`catch 0` 10 → 2, the high-level modules → 4 including a privilege escalation, the unaudited modules → an EntQL fail-open, the v0.72.0 sweep → 5 (two of them scope bypasses) — so this is where a defect is most likely to be found rather than reported |
| **Log text is not assertable** | This repository has no `logFn`, so warnings cannot be captured in tests. Several fixes in this series are therefore pinned only at the level below the message (the renderer, or the value a callback receives), and each one says so rather than claiming an end-to-end assertion |
