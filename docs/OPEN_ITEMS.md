# Open items

What is **still open**, in one place, with the evidence. `CHANGELOG.md` records
each item where it was found and each fix where it landed, which is the right
shape for history — but reading "what is open right now" out of it means diffing
the accumulated notes against every later release. This file is that diff, kept
current instead.

**Not a wish list.** Everything here was observed: a measurement, a reproduction,
or source that says something the docs do not.

- `docs/ISSUES_FROM_ZAPI.md` — consumer-reported items (Z1–Z39), with verdicts.
- `docs/BEST_PRACTICES.md` §5h — what `checkSchema` does **not** compare.
- `CHANGELOG.md` — history, including the negative audit results.

---

_This file is pruned as items land; `CHANGELOG.md` is the history._

**Recently resolved** (newest first; earlier releases are in the CHANGELOG):

| Release | What left this file |
|---|---|
| v0.81.1 | driver discovery is target-aware — host probing is gated on `isHostTarget`, the target's paths come from `XCOMPILE_ROOT` or the per-driver overrides, and `build.zig` exports `linkDrivers` so a consumer's build script stops mirroring it (a cross build no longer hands the host's `-I`/`-L` to a foreign link) |
| v0.81.0 | the audit lanes' defects, thirteen in all: a cached PostgreSQL statement is `DEALLOCATE`d when evicted (42P05, and 0A000 after a DDL), `bindParams` keeps its parameter lists paired, MySQL reports a lost connection as `ConnectionFailed` and keeps `in_tx` honest, `getOwned`'s copy owns its JSON arena, a `field.JSONValue` document is deep-copied instead of shared, the batch writes take `tenant_id`, two `append`-failure leaks, a nullable integer cursor column is refused by name, the edge-target sink dedupes, and libpq gets each argument as one intact value |
| v0.80.1 | keyword tables became comptime maps (`StaticStringMapWithEql(…, eqlAsciiIgnoreCase)`) instead of comparison chains |
| v0.80.0 | the toolchain is pinned to `0.17.0-dev.2151+2ec5523d5` in CI, `minimum_zig_version` and the docs |
| v0.79.1 | `@FieldType` for type probes; `toSnakeCase` has one definition (its fourth copy was dead code) |
| v0.79.0 | `Dialect.Kind`; dispatch on `kind()`, not on strings — the misspelt `"sqlite"` branch had SQLite sized for the 65535-parameter cap instead of 999 |
| v0.78.1 | a `From` edge's foreign key names the target's declared `table_name` and the edge's own column (Z39) |
| v0.78.0 | grouped `Count()` answers the group count; the seven single-value aggregates refuse `GroupBy`; `RowsAffectedUnknown`; `AllOwned()` |

**Examined and deliberately kept** — pinned in comments so they are not "fixed"
into something worse: `borrowErrorFor` folding unknown driver errors into
`PoolExhausted` (the bounded set `asDriver` needs; the unmapped name stays in the
warn log); `driverInTransaction` answering `false` on a failed borrow (the
`beginTxCtx` preflight routes `false` to `beginTx`, whose own borrow surfaces the
real error); `privacy.Filter`'s predicate returning `?*const anyopaque` (typing
it as `*const sql.Predicate` would break every policy writer — the repository
alone has six, `tests/integration/postgres.zig` among them — to catch a misuse
that requires deliberately returning a pointer to something else, and the cast
site is one function in `runtime/privacy.zig`); and `Rule.on_op` carrying
`.allow` restricting nothing (`allow` is already the default and only `.deny`
restricts, so reading it as an allow-list would make a policy wider than it is
written — the comment in `runtime/privacy.zig`, `UPGRADING` §6 and two tests in
`runtime/privacy.zig` now state that instead of leaving it to be inferred).

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

**Negative results from the v0.81.0 audit**, for the same reason: `src/shard.zig`
and `src/helpers.zig` came back clean (`ShardRouter.init` refuses zero shards,
the `@bitCast` avoids a negative-shift panic, and every `openWith` is a `try`
with an `errdefer` and correct per-partition teardown), and `src/privacy/`,
`src/runtime/` and `src/graph/` came back with **zero defects** — the first large
negative result of the method, which is the reason the two decisions above are
decisions rather than fixes.

## Needs a decision before it can be fixed

| Item | Evidence | Why it needs you |
|---|---|---|
| **`zig build migrate-rollback` does not inherit the caller's DSN** | `build.zig`'s `migrate-rollback` step calls `setEnvironmentVariable`, which materialises the env map into the long-lived build-server process; `migrate` (`build.zig:205`) does not and works. So the rollback step cannot be pointed at a database from the shell | Fixing it means changing how the step passes env — worth doing, but it touches the build's structure |
| **SQLite's strict scan coerces TEXT numerics silently** | `sqlite3_column_int64` over the TEXT value `"12.34"` answers `12` with no error — in strict *and* lenient scans. PG/MySQL parse the text instead and answer `null`, which the scan layer turns into `TypeMismatch` (strict) or the field's default (lenient). `field.Decimal` maps to TEXT on every dialect, so an i64 DTO field over a Decimal column silently truncates on SQLite only. Pinned by `sql.sqlite`'s coercion test; matrix in `BEST_PRACTICES` §raw | Making SQLite precise (getText + parse) would turn currently succeeding reads into errors across consumers — a behaviour change to decide, not a fix to slip in |

## Open, with a known shape

| Item | Evidence |
|---|---|
| **`sql.MultiInsert`'s length assertion does not validate what the rows set** | It asserts `values.len == columns.len * row_count`, which holds because the buffer is sized from the column list. The insert layer now checks the rows against each other (v0.69.0), so the assert is no longer the only guard — but it is still about the buffer, not the input |
| **`outbox.nowMs` falls back to `0`** | A `gettimeofday` failure would stamp `claimed_at = 0` (immediately stale) and compute a negative cutoff for `requeueStale`. The syscall cannot fail for a valid pointer, so it is unreachable — recorded because it is the same "unknown as a value" shape |
| **`field.String`'s default `VARCHAR(255)` cap** — **plan landed in v0.86.0** as the additive `field.VarChar(n)`: MySQL DDL `VARCHAR(n)`, a declared-ceiling `ValidationFailed` on the write path (all dialects, UPDATE included), PG/SQLite DDL unchanged, default behaviour untouched. What remains open is only the migration angle: an *existing* `VARCHAR(255)` column under a `VarChar(120)` schema is not a drift (lengths never compare) — resizing takes the `UPGRADING.md` §12 recipe |
| **The MySQL BLOB/TEXT `DEFAULT` guard is stricter than MariaDB requires** | MariaDB ≥ 10.2.1 accepts a `DEFAULT` on `TEXT`; the DDL layer cannot tell the two servers apart without a connection, so it applies MySQL's rule to both (v0.58.0, restated in v0.60.0). A MariaDB user who needs it must hand-write the migration |
| **`tableFromTypeInfo` (the `pub` single-TypeInfo export) still derives the referenced side by short name and hardcodes `"id"`** | Its signature takes only one TypeInfo and cannot resolve the target. `junctionTableForEdge`, the other half of this row, is **fixed in v0.87.0** — and the v0.84.0 claim that no public API reaches it turned out wrong: `resolveGraphEdges` sets `.m2m` directly for two mutual `To` edges without a `Through` (it does not go through `resolveRelation`), so the implicit-junction path was always live and is now covered by a unit test plus a SQLite end-to-end (declared `table_name`/`.pk` on both ends, foreign keys enforced) |
| **Cross-graph edges reach the database through the DDL face** | Queries/CRUD fail at compile time (`edgeTargetInfo`), but a graph that is only *migrated* never calls it: a cross-graph From-edge FK uses the documented out-of-graph fallback (short name + `"id"`, dangling by construction), a cross-graph implicit-M2M junction does the same via `junctionTableForEdge`'s fallback, and a cross-graph `Through` schema has no guard at all. **v0.89.0 makes that visible without changing behaviour**: the migration warns once per (source entity, edge) — naming the edge, the source, the target type and the derived table it will reference — from both migration entry points (`createTables` and the shared planner, so dry run and real run warn once together), asserted through `zent_log.setSink`. What remains open: the fail-loud options (a migrate-side check that every edge target is in `infos`, or the Z16 registry) which would break existing multi-database deployments, so they wait on a consumer asking |
| **Controlled JOIN v1 is deliberately narrow** | v0.88.0 shipped `QueryBuilder.joinEdge` (m2o/o2o-From edges, inner/left, target projected into the eager field, scope qualified to the alias) — see `docs/superpowers/specs/2026-10-09-controlled-join-design.md`. Out of v1 scope, each with its reason recorded there: `right`/`full` joins (not portable across the three dialects), o2m/m2m projection joins (fan-out would move LIMIT semantics, and aggregates need a dialect-triplet abstraction), `GroupBy` + join (refused with `error.JoinWithGroupBy`), aggregates over joined columns, and cross-graph joins (still Z16). The v2 candidates (a `JoinRow{source, target}` tuple family, public `.alias`, chained m2o joins, secondary `WithEdge` off a joined row) wait on a consumer asking |

## Open in the ledger

| ID | What remains |
|---|---|
| Z14 | The `Contains` rename — **decided: won't fix** (v0.84.0). `Contains` and `Like` render the same predicate (`col LIKE ?`, value bound verbatim); the alias shipped in v0.39.0 and the docs steer new code to `Like`. Renaming would break zapi, whose MySQL compatibility keeps the whole project on `Contains`, and Zig has no deprecation annotation to soften it. Revisit only if zapi migrates |
| Z16 | Multi-graph stages 2/3. **Correction (v0.87.0): the "fails at runtime" half was wrong** — every query/CRUD path resolves edge targets through `edgeTargetInfo`, whose miss is a `@compileError` naming the edge, the source and the target type (18 call sites, one definition), so a cross-graph edge already fails at compile time, earlier still than stage 1 claimed. What v0.87.0 adds is the cross-graph diagnosis in that message; what remains of stage 2 is the opt-in comptime graph registry (so the error can name *which other* graph owns the target) and the `edge.InGraph` plumbing for cross-graph edges proper — deferred with the ROI note (its four trigger conditions are still unmet). What genuinely fails at *runtime* is the DDL face: a cross-graph From-edge FK dangles by the documented out-of-graph fallback, and a cross-graph `Through` schema is unguarded (see the known-shape row on `through_name`) |
| Z31 | SQLite `view_sql` replacement (PG/MySQL `CREATE OR REPLACE VIEW` already converge a changed definition; SQLite's `IF NOT EXISTS` leaves a stale one, and `checkSchema` deliberately compares no definitions) and foreign keys added by `ALTER` on an existing table (the **column-level `UNIQUE`** half landed in v0.73.0 — the migration adds a unique index) |
| Z32 | A bare `sql.InSelect` does not scope its inner table; `Has*` targets do. Documented as out of reach for the `sql` layer (it has no graph) |
| Z40 | *Closed* — a `From`/`To` edge's FK always referenced `id`, ignoring the target's `.pk`/`StorageKey` override (the query side honoured it). See the Z40 section for the full shape and the fix |

## Structural gaps

| Gap | Why it matters |
|---|---|
| **The allocation-failure sweep still has known gaps** | `src/test/allocation_failures*.zig` use `std.testing.checkAllAllocationFailures` (Zig 0.17) to fail every allocation in turn and hold the byte ledger; they have found fifteen leak sites so far (three in `sql/builder.zig` at v0.76.1; at v0.77.0 five in the `sql/scan.zig` scanners and `queryAll`, three in `sql/schema/migrate.zig`'s planning and SQLite introspection, and four in the MySQL/PostgreSQL introspection, those last by inspection). They also found a *contract* defect: JSON parsing reported an out-of-memory as `TypeMismatch`, which the lenient scanners turned into the field's default (fixed v0.77.1). Covered today: fragment rendering, an assembled SELECT, the row scanners including the JSON/arena half (v0.77.1), `queryAll`, `planMigrateStatements`, `CrudService.getOwned` (including its JSON path, v0.81.0), the neighbour fragments (clean), and `crud_helpers.batchCreate` / `queryRows` (v0.81.0). Uncovered, in the order they are most likely to hide something: (**a**) the four *infallible* builder wrappers — `InsertBuilder.init`, `UpdateBuilder.init`, `DeleteBuilder.init`, `BulkUpdateBuilder.init` (and `Builder.init` itself behind them) still swallow an induced OOM by design, so a sweep reports `SwallowedOutOfMemoryError` and skips it; v0.89.0 narrowed this to those four by moving every *fallible* production site onto `try Builder.initCapacity(…, 256, 8, …)`; (**b**) the `outbox` entries that route through those wrappers — `enqueue`, `markPublished`/`markFailed`/`requeue`, `requeueStale`, `dispatch` — are unswept for exactly that reason, and unblocking them needs the wrappers' signatures to become `!Self`, a breaking public-API change; (**c**) `entity.zig`'s `deinitEntity` / `deinitEntityList`, which are release paths rather than assembly paths — a leak there needs a different instrument (a counter, not the ledger). **One harness caveat learned on Linux CI (v0.88.2):** `checkAllAllocationFailures` counts *allocations*, and `ArrayList` growth asks `allocator.remap` first — when a remap succeeds (Linux `mremap`, address-dependent) the growth costs zero counted allocations, so the same run allocates a different number of times than the baseline pass and the sweep answers `NondeterministicMemoryUsage` (macOS, which cannot grow in place, stayed green). A sweep whose path grows lists needs the allocator wrapped so `remap` always declines — see the `NoRemap` adapter in `codegen/query.zig`'s joined-build case. Swept since v0.85.0: `outbox.pending` (which caught a real per-row dupe leak on arrival), `outbox.claim` in both its driver shapes (including the transactional one), `ShardRouter` map growth and `ShardSet.init`'s client copy. Swept since v0.89.0 (once `Builder.initCapacity` replaced the swallowing constructor on those paths): `scope.forTable` (both its plain and numbered-dialect renderings), `BulkDeleteBuilder.init`, the eager `loadEdgePath` — which caught a real error-path leak (a scanned target dropped before it entered the map, and the map's teardown releasing only list buffers, so targets parked in it kept their arena and strings) — and `client.queryTargetsImpl`. Two negative results worth keeping: those sweeps pin *ownership on the assembly path*, not the swallow itself (with the swallowing constructor restored, the eager case still passes — the swallowed failure re-fires on the very next allocation at the same fail_index, so the ledger stays consistent); and the `NoRemap` wrapper is required for any swept path that grows lists, or Linux answers `NondeterministicMemoryUsage`. The per-dialect catalog stubs landed in v0.77.2, so the index introspection is no longer on this list |
| **MariaDB differences are still found after the tag is pushed** | The new `tests/integration/dialect_matrix.zig` now compares the dialects directly, which covers the semantic half. What it cannot cover is a difference neither harness knows to ask about, and this session's three escapes (`column_default` quoting, functional indexes, `BEGIN` through prepare) were all of that kind. The only root fix is a local MariaDB or a working container runtime |
| **Modules the audit method has not reached** | `codegen/query.zig`'s full branches, `codegen/graph.zig` / `meta.zig`, `graph/step.zig`, `update_delete.zig`'s edge-write branches and `bench/` were audited in the v0.72.0 pass (5 defects, all fixed; the negative results are recorded above). The v0.81.0 pass read the three module groups this row then named — the drivers' dialect-specific edges, the high-level services, and `privacy/` + `runtime/` + `graph/` — and produced **ten** of the release's thirteen findings: a PostgreSQL statement cache that leaked server-side statements (42P05 after the first DDL), `bindParams`/`freeParams` indexing past a list, MySQL collapsing a lost connection into `ExecFailed`, two paths that did not mark the connection dead, a transaction flag cleared before its rollback, an owned copy aliasing a released JSON arena, batch writes trusting the entity's own tenant value, two `append`-failure leaks and a nullable cursor column that restarted a caller at page one. `shard.zig` and `helpers.zig` were clean; `privacy/` + `runtime/` + `graph/` yielded zero defects (both negative results recorded above). Still unread: `examples/` other than `check_sql` and `migrate`, and the PostgreSQL/MySQL introspection paths beyond those the v0.77.0 sweep inspected. ~~Still unread~~ — the v0.85.0 pass read both: the introspection deep paths (5 findings, see the CHANGELOG: the MySQL `bool`/`float` server-canonical gap, nine copy-then-append leaks in the FK readers, `checkSchema`'s error-path drift leak, the plan path's missing heap fallback) and the five examples (three structurally wrong, all fixed). Still unread after v0.85.0: `migrate.zig`'s DDL-writing half (`auditTimestampDefault` and the DDL-side functions) and `bench/` beyond v0.72.0. The method's hit rate is unchanged — `catch {}` 20 sites → 1 defect, `catch null`/`catch 0` 10 → 2, the high-level modules → 4 including a privilege escalation, the unaudited modules → an EntQL fail-open, the v0.72.0 sweep → 5 (two of them scope bypasses), the v0.81.0 sweep → 10 (two of them memory-safety), the v0.85.0 introspection pass → 5 (one breaking MySQL migrations) — so this is where a defect is most likely to be found rather than reported |
