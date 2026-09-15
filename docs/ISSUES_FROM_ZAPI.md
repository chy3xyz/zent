# Issues from zapi — zent backlog

> Sourced from the **zmcanyin / zapi** multi-tenant commerce port
> (`zigmodu_ws/zmcanyin_zent/zapi`): ~114 tables, MySQL, three Client graphs,
> ThinkPHP-compatible API.  
> Consumer docs that motivate these items:
> `zapi/docs/{ZENT_BEST_PRACTICES,PORTING_RECIPE,DATA_ESCAPES,WAVE4_GUIDE}.md`.  
> Status: **Open** unless marked. Prefer GitHub issues linked from the `#` column.

Suggested landing order: **Z1 → Z2 → Z3 → Z4…**.

---

## P0

### Z1 — MySQL-safe `ContainsEscaped`

| | |
|--|--|
| **Problem** | Predicate `ContainsEscaped` renders `LIKE '…' ESCAPE '\'`, which is illegal on MySQL. zapi bans it project-wide and only uses `Contains`. |
| **Evidence** | `sql/builder.zig` (ESCAPE render); consumer: `PORTING_RECIPE.md`, `WAVE4_GUIDE.md` |
| **Proposal** | Dialect branch: MySQL → parameterised `LIKE ?` with bind-side escape, or `ESCAPE '\\\\'`; add MySQL integration test; drop “never use ContainsEscaped” from consumer guides once green. |
| **Acceptance** | Fuzzy match with literal `%`/`_` works on MySQL/SQLite/PG; CI covers MySQL. |
| **Status** | **Fixed** in v0.30.0 |

### Z2 — Business-key upsert (usable ODKU / ON CONFLICT)

| | |
|--|--|
| **Problem** | Library has `SaveOrUpdate` / MySQL ODKU pieces, but zapi still raw-SQL upserts dozens of setting/config tables (“no upsert” in `DATA_ESCAPES`). Conflict target + column subset don’t match multi-tenant `(key, app_id)` writes. |
| **Evidence** | `DATA_ESCAPES.md` #36–38, #76, #87–95, …; `CHANGELOG` upsert notes vs consumer escape ledger |
| **Proposal** | `SaveOrUpdateOn(&.{"key", "app_id"})` or schema `@unique` → generate ODKU / `ON CONFLICT`; partial column update; docs + example for setting-table pattern; refresh escape guidance (“prefer fluent upsert before escape”). |
| **Acceptance** | One zapi-style setting upsert ports without raw SQL; docs no longer claim “zent has no upsert”. |
| **Status** | **Fixed** in v0.30.0 (`SaveOrUpdateOn`) |

### Z3 — Large-schema / multi-graph strategy

| | |
|--|--|
| **Problem** | `UPGRADING.md` says raise `@setEvalBranchQuota`, don’t split graphs. zapi hit ~114 tables and **split into three graphs** → lost cross-graph edges, wrong Client/infos in tx, “table not in graph” escapes. |
| **Evidence** | `UPGRADING.md` §7a; `zapi` `ZENT_BEST_PRACTICES.md` §2; `MIGRATION_PLAN.md` |
| **Proposal** | (a) Higher default quotas + measured limits, and/or (b) **first-class subgraphs** with explicit bridge edges and compile error on unresolved cross-graph edges; document when split is allowed. |
| **Acceptance** | Documented path for >80-table apps; either single-graph compiles or multi-graph is typed-safe. |
| **Status** | **Documented** (v0.31.0): stress tests in `graph.zig` prove a single graph compiles at 400 realistic / 300 edged tables under the default 1M quota; `UPGRADING.md` §7a updated with measured limits and safe-split guidance. First-class subgraphs (option b) deferred. |

---

## P1

### Z4 — `INSERT IGNORE` / conflict-do-nothing insert

| | |
|--|--|
| **Problem** | Idempotent relation inserts use raw `INSERT IGNORE` (`DATA_ESCAPES` #4). |
| **Proposal** | `Create().IgnoreConflict().Save()` / bulk variant → MySQL `INSERT IGNORE`, PG `ON CONFLICT DO NOTHING`, SQLite `INSERT OR IGNORE`. |
| **Status** | **Fixed** in v0.30.0 (`SaveIgnore`) |

### Z5 — Fluent SELECT / ORDER BY expressions

| | |
|--|--|
| **Problem** | `FROM_UNIXTIME`, Haversine, `CONCAT`, `UNIX_TIMESTAMP()` force raw queries across list/export paths. |
| **Proposal** | `SelectExpr("…", "alias")`, `OrderByExpr`, optional `ScalarExpr` for one-value queries; map into DTO / `sql.Value`. |
| **Status** | **Fixed** (v0.31.0): `sql.SelectExpr(expr, alias)` + `ColumnRef.alias`, `sql.OrderExprSql(expr, desc)`, `Selector.addColumn`, `Driver.queryOwned`, `Row.columnIndex(name)`; docs in `BEST_PRACTICES.md` §5b. |

### Z6 — Clarify or harden raw `Row.getInt` / `getText`

| | |
|--|--|
| **Problem** | Returns `?T`, not error union; authors repeatedly write `try row.getInt`. |
| **Proposal** | Prefer `mustGetInt` / `tryGetInt` naming, or breaking `getInt → error{NullColumn}!i64`; examples forbid `try getInt`. |
| **Status** | **Fixed** in v0.30.0 (`tryGet*` error-union variants added alongside `get*`) |

### Z7 — `Where` accepts `&.{}` or clear `@compileError`

| | |
|--|--|
| **Problem** | `&.{ P.xEQ }` vs `.{}` causes opaque comptime failures (`BEST_PRACTICES` anti-pattern). |
| **Proposal** | Normalize pointer-to-tuple, or emit actionable compile error. |
| **Status** | **Fixed** in v0.30.0 |

### Z8 — `deinitEntity` ergonomics

| | |
|--|--|
| **Problem** | Must use `var` + `client.<e>.allocator` (not request arena); footgun under HTTP. |
| **Proposal** | `Entity.deinit(*T)` bound to client allocator; debug assert on wrong allocator; optional `ManagedEntity` / `dupeTo(arena)` helper. |
| **Status** | **Fixed** (v0.31.0): `codegen.ManagedEntity` / `managedEntity` bind the allocator to the entity; `codegen.dupeEntityTo(arena)` deep-copies fields + JSON + 2 edge levels into a request arena. Runtime wrong-allocator assert is not feasible in Zig — the two helpers remove the footgun instead. Docs: `BEST_PRACTICES.md` §2 rule 5. |

### Z9 — `beginTxFromDriver` + Driver-first loaders

| | |
|--|--|
| **Problem** | Multi-graph apps share `pool.asDriver()` but Client types don’t mix; payment/refund loaders need Driver-first APIs. |
| **Proposal** | `beginTxFromDriver(infos, drv, alloc)`; document Driver-first config loader pattern; optional `beginTx(infos, *Client)`. |
| **Status** | **Fixed** (v0.31.0): `codegen.beginTxFromDriver(infos, drv, alloc)` opens a typed `TxClient` straight from a shared `Driver` (savepoint on re-entry); Driver-first pattern documented in `BEST_PRACTICES.md` §8a. |

### Z10 — `WithEdge` options (join kind + limit mode)

| | |
|--|--|
| **Problem** | LIMIT applied before edge load skews result sets; INNER vs LEFT requires manual filtering; edges must live in one graph. |
| **Proposal** | `WithEdgeOpts{ .join = .left|.inner, .limit_mode = .after_edges }`; document cross-graph edge rules. |
| **Status** | **Fixed** (v0.31.0): `WithEdgeOptions(path, .{ .join = .inner, .limit_mode = .after_edges })` — inner join lowers to a schema-aware EXISTS filter in SQL, so LIMIT applies after the edge filter (no skew); cross-graph edge rules documented in `BEST_PRACTICES.md` §3/§8a. |

---

## P2

### Z11 — `field.Decimal` / money types

Schema `Int` vs MySQL `DECIMAL` forces text reads (`DATA_ESCAPES` money rows). Scan to owned string or fixed-point; never silent truncate.

**Status — Fixed (v0.31.0):** `field.Decimal("amount")` → PG `NUMERIC`, MySQL `DECIMAL(38,10)` (explicit precision so the `(10,0)` default can't truncate), SQLite `TEXT` (NUMERIC affinity would rewrite `1.10` to REAL `1.1`). Zig type is owned `[]const u8` — exact wire text, never f64. Round-trip integration tests on all three dialects; docs in `BEST_PRACTICES.md` §1.

### Z12 — Controlled multi-table / GREATEST update expressions

Stock `GREATEST` and dual-table decrements remain raw. Document fluent limits; optional allowlisted `execExpr`.

**Status — Fixed (v0.31.0):** single-table expression updates were already fluent via `setExprArgs(field, expr, args)`; added a clamping-expression test (`MAX(stock - ?, 0)`, the SQLite spelling of `GREATEST`) and documented the fluent limits + what stays raw (multi-table UPDATE, UPDATE ... FROM) in `BEST_PRACTICES.md` §5c.

### Z13 — Docs: multi-graph playbook + escape ledger hygiene

Align official docs with ODKU reality; add “Multi-graph” section; escape template column “min zent version”.

---

### Z14 — `Contains` semantics vs its name (and a doc mismatch)

| | |
|--|--|
| **Problem** | Two related things. (a) `BEST_PRACTICES.md` §3a documented `xContains(v)` as `col LIKE '%v%'`, but the implementation binds `v` verbatim (`col LIKE ?`), so following the doc produces an exact match instead of a substring search. (b) The name itself invites that mistake: `Contains` is the only one of the five LIKE predicates that does **not** add the wildcards — `ContainsEscaped`, `HasPrefix`, `HasSuffix` and `ContainsFold` all do, and all escape the input. |
| **Evidence** | `src/codegen/predicate.zig` (`Contains` → `sql.Like(col, v)`; the others → the escaped family); §3a now carries a corrected table; the new test `Predicates: Contains binds the pattern, ContainsEscaped wraps it` pins both renderings. |
| **Impact** | Silently wrong results rather than an error: `xContains("foo")` matches only `foo`, and `%`/`_` in the argument stay live wildcards. zapi avoided this because it passes `%v%` explicitly (Z1 drove it to `Contains` for MySQL safety), so the consumer semantics are correct — but a new caller reading the docs would not be. |
| **Proposal** | (a) **Done**: docs corrected and the behaviour pinned by a test. (b) **Half done**: `<col>Like` was added as the honest name for the same predicate, so new code has a name that cannot mislead while `Contains` keeps working (nothing breaks; a test asserts both render `LIKE ?`). The remaining question is whether to *rename* `Contains` — left open on purpose, since that is the breaking half and the alias already removes the trap. |
| **Acceptance** | Docs and tests agree with the implementation (done), and new code has a non-misleading name (done: `Like`). |
| **Status** | **Substantially fixed** — `Like` alias + docs + tests; only the `Contains` rename itself is **Open**. |

---

### Z15 — Edge writes are unavailable on `From` edges

| | |
|--|--|
| **Problem** | `UpdateBuilder.SetEdgeIDs` and `ClearEdge` reject `From` edges at compile time. An entity that owns the FK (`edge.From("owner", User)`) can only be re-pointed through `setFieldValue`, even though the two operations are the same write from the caller's point of view. |
| **Evidence** | `src/codegen/update_delete.zig:536` (`SetEdgeIDs requires a To edge whose FK lives in the target table`), `:555` (`… a 'from' edge stores its FK on this row — use setFieldValue to detach it`). |
| **Impact** | Not a correctness gap — `setFieldValue("owner_id", id)` works and is what the `@compileError` tells you to write. It is an API-shape inconsistency: the same intent needs a different spelling depending on which side of the edge holds the column, and the compile error is the only place that is explained. |
| **Proposal** | **Done** (v0.44.0) — the single-row shape, folded into the main UPDATE rather than emitted as a second statement: a `From` edge's FK is a column of the row being updated, so `SetEdgeIDs`/`ClearEdge` write it in the UPDATE's own `SET` clause. One statement, one predicate, one transaction, and the interceptor/privacy scope covers it like any other column. It also removes a footgun: an association change on a `From` edge needs no companion `setFieldValue`, because the write *is* a SET field. `error.TooManyEdgeTargets` (from the call, not `Save`) for more than one id; clearing requires a nullable FK — compile error via `ClearEdge`, `error.EdgeNotDetachable` via `SetEdgeIDs(…, &.{})`. |
| **Acceptance** | Met: covered on SQLite, PostgreSQL and MySQL in the existing edge-write tests, including re-point, clear and the multi-id rejection. Falsified by making the branch a no-op, which fails those assertions. |
| **Status** | **Fixed** v0.44.0. |

---

### Z16 — Multi-graph is documented, not first-class

| | |
|--|--|
| **Problem** | Z3 shipped the playbook (one graph per database, `WithEdge` cannot cross graphs) but the deferred "option b" is still open: an edge whose target lives in another graph is not resolved, so a consumer that splits graphs must keep every edge inside one graph. |
| **Evidence** | Z3 in this file (option b marked deferred); `docs/BEST_PRACTICES.md` §8a is the discipline that carries the guarantee today. **Corrected measurement (probe, 2026-09-12):** a cross-graph edge fails at **comptime, not at runtime** — and not at query time either. Generating the client alone is enough: `EntityClient(infos, info)` → `entity.zig:212` → `EdgesType` → `entity.zig:9` `error: TypeInfo not found: <Target>`, identically for `edge.From` and `edge.To`. So the failure is loud and early, and the acceptance criterion below is already half met. 14 call sites resolve a target through the *current* graph: `create.zig:472`, `predicate.zig:245,311,338`, `entity.zig:73,134,288,481`, `client.zig:81,547,573`, `query.zig:197,532`. **Build-cost measurement (cold `zig build test`, fresh cache, this machine, Debug):** baseline suite 20.6–24.8 s; the same suite plus `EntityClient` instantiation for 400 tables 28.4–30.1 s — i.e. **~8 s / 400 entities (~20 ms each)**, well outside the run-to-run spread, while the three stress tests' 1100 `buildGraph` schemas cost a few seconds at most (inside the spread). So the *schema-count* limit Z3 measured is not what makes a big single graph expensive; **client instantiation is**. |
| **Impact** | Not a silent-wrong-results risk (the compile error prevents that), but a wall: a legitimately split application cannot express a bridge edge at all, and the error text does not say *why* (`TypeInfo not found: Payment`) or what to do. Correctness today rests on §8a discipline. |
| **ROI** | Asked and answered on 2026-09-12: **stage 1 yes, stage 2/3 no — for now.** The demand is narrower than the entry implied. (a) The only known splitter is zapi at ~114 tables; at the measured ~20 ms/entity that is ~2.5 s of comptime, which is not build pain — for them the cheap fix is to merge the graphs back. (b) Splitting only buys build time when the graphs land in **separate compile units**; within one binary every graph's clients are instantiated anyway, so the saving evaporates. (c) When graphs are split across services or databases — the common real reason — a cross-graph edge is not merely unimplemented but **unimplementable** at the SQL level, so the feature delivers nothing. (d) Stage 2 does not even close the gap it targets: mutually-cross-referencing graphs stay unsupported, so discipline remains. The permanent costs (a `TypeInfo` handle in `core/`, the DAG declaration-order rule, re-measuring the comptime budget, extra API and test surface) are paid by every future consumer for a narrow case. |
| **Revisit when** | A consumer shows all four: one process, one physical database, >400 tables, and edges crossing the split — plus a merged single graph whose build time is unacceptable. Then stage 2 is ~1–2 days of plumbing against a proven mechanism, and the case is real. |
| **Proposal** | **Open, and smaller than it first looked.** A probe proved the resolution mechanism already works when the target's `TypeInfo` comes from its own graph: `buildEdgeStep` across graphs emits `SELECT "probe_b".*, "s"."id" AS __fk FROM "probe_b" INNER JOIN "probe_a" s ON "probe_b"."id" = s."b_id" WHERE s."id" IN (?)`, and `Entity(b_graph.types, b_info)` resolves the target's *nested* edges against `b_graph.types` automatically. `EdgeInfo` already carries `target: type` (graph.zig:45). So the work is plumbing, in stages: **(1)** turn `findTypeInfo`'s miss into an actionable error naming the edge, the source and the target type (zero risk, satisfies half the acceptance criterion); **(2)** add an explicit graph handle (`edge.InGraph(target_graph)`, additive/defaulted) and redirect the 14 sites; **(3)** `Client` generic over a graph set — mostly *not* needed, since Z9's `beginTxFromDriver` covers the transaction half and the shared graph's client types are identical by construction once the handle is the graph's `types`. Three real constraints for stage 2: graphs must be declared in dependency order (mutually-cross-referencing graphs need a two-phase declaration, the one genuinely hard part), a cross-graph `To` edge cannot auto-inject its FK into the target's table so the target must declare that column explicitly, and the comptime budget (§7a) needs re-measuring. Layering note: a `[]const TypeInfo` handle makes `core/edge.zig` depend on codegen's IR — either accept that or move `TypeInfo` to a neutral module. |
| **Acceptance** | A cross-graph edge either works, or fails to compile with a message naming the edge, the source graph and the target type. |
| **Status** | **Stage 1 done** (v0.39.0): all 16 edge-target resolutions go through `graph.edgeTargetInfo`, which fails with *"edge 'payment' on 'Order' targets 'Payment', which is not in this graph … add the target schema to the graph you pass to buildGraph, or read it through the raw driver with zent.scope"* — verified by probing a cross-graph edge. Stages 2/3 stay **Open** per the ROI row above. |

---

### Z17 — Entity release is a 4-argument call nobody wraps

| | |
|--|--|
| **Problem** | Releasing a scanned entity takes `deinitEntity(infos, info, &entity, allocator)` — four arguments, one of which (`infos`) the caller has no other reason to hold. The ergonomic helper `managedEntity` (`row.deinit()`, one call, no arguments) exists and is unused. |
| **Evidence** | Consumer count: `deinitEntity(...)` appears **607** times in zapi; `managedEntity`/`dupeEntityTo` appear **0** times. `ManagedEntity` already provides exactly the shape needed (`src/codegen/entity.zig:406`, `deinit(self)`), so the gap is not capability but **reachability**: nothing returns one. |
| **Impact** | Not correctness — the explicit call is safe, just verbose enough that it is written by hand everywhere and cannot be reviewed for ownership at a glance. |
| **Proposal** | **Done** (v0.40.0) — the `deinitRows` shape, chosen by the consumer over `AllManaged()`: `q.deinitRows(&rows)` and `client.<entity>.deinitRows(&rows)` free the page and the list in one line, `client.<entity>.deinitRow(&e)` covers singles, and `client.<source>.deinitEdgeRows("edge", &rows)` covers `QueryEdge` results (whose type is the *target* entity, which is why it needs the edge name to resolve the right `TypeInfo`). All four delegate to one implementation, `codegen.entity.deinitEntityList`; the list is left empty and reusable, so a second call is a no-op. `crud_helpers.deinitRows(infos, info, rows, alloc)` stays as the explicit form and now goes through the same helper. |
| **Acceptance** | Met: a consumer can free a page in one call without naming the graph or the allocator, and the four-argument `deinitEntity` form is no longer the only reachable option. |
| **Status** | **Fixed** v0.40.0. Per-call-site adoption is the consumer's step; the API no longer requires the four-argument form. |

---

### Z18 — `setFieldValue`'s accepted set is written in three places and they disagree

| | |
|--|--|
| **Problem** | The set of Zig values a field accepts is expressed by `canSetField` (the type check), `toSqlValue` (the conversion), and now the doc table. Two of them do not agree: `canSetField` accepts a `[N]u8` **array value** for a string-ish field, but `toSqlValue` cannot turn one into a slice (`array literal requires address-of operator (&) to coerce to slice type '[]const u8'`), so that argument type is a compile error *after* passing the check — with a message that names neither the field nor the function. The same shape of drift produced the dead enum-tag validation removed in the same release: it compared the runtime `value` inside a `comptime` block, so it could never fire, and it turned a `[N]u8` argument into `unable to resolve comptime value`. |
| **Evidence** | `src/codegen/create.zig` (`canSetField` — the `switch (@typeInfo(Actual))` with an `.array` branch; `toSqlValue` — the matching `.array` branch that cannot compile), duplicated in `src/codegen/update_delete.zig`. Reproduce with `setFieldValue("name", "abcd".*)`. |
| **Impact** | Low blast radius, high confusion: the accepted set is documented from three directions, so a caller who reads any one of them may be wrong. This is the same disease as the five `Where` copies (fixed in v0.42.0) and the eight interceptor sinks. |
| **Proposal** | **Done** (v0.43.0): `src/codegen/field_value.zig` is the single home — `accepts(Expected, Actual)` decides, `toSqlValue` converts, and its tests check **both directions** (the accepted shapes *and* the rejected ones, which is what a doc table cannot do). The copies — two `canSetField`, two `toSqlValue`, and `isStringLike` — are gone; the four `setFieldValue` docs now point at the one contract. The `[N]u8` array shape is **removed** rather than supported: converting it would hand back a pointer into the callee's own by-value parameter, so it could never be correct; an array argument now fails at the type check with a message naming the field and both types, and `toSqlValue` has an explicit branch telling the caller to pass a slice or a literal. |
| **Acceptance** | Met: one place decides, the doc and the compiler cannot disagree, and a `[N]u8` argument is rejected by name. |
| **Status** | **Fixed** v0.43.0. |

---

### Z19 — A `SET`-less UPDATE is invalid SQL, and edge writes can produce one

| | |
|--|--|
| **Problem** | `UpdateBuilder.Save()` always emits `UPDATE t SET … WHERE …`. With no `setFieldValue` and only edge actions registered, the SET list is empty and the statement is `UPDATE t WHERE …` — a syntax error from the database (`near "WHERE": syntax error`), not a useful message. |
| **Evidence** | Hit while writing the Z15 tests: `client.user.Update().Where(…).SetEdgeIDs("cars", …).Save()` fails to prepare. Every existing edge-write test works around it by pairing the edge call with an unrelated `setFieldValue("name", …)` — the habit is in the tests, the reason is nowhere. |
| **Impact** | Narrow but real: the caller's intent ("just change the association") is expressible, and the resulting error says nothing about the cause. `From` edges stopped hitting it in v0.44.0 because they contribute a SET field; `To`/M2M edges still do. |
| **Proposal** | **Done** (v0.45.0), taking the "works and documents its return value" branch: with no SET fields and edge actions registered, the statement touches the matched rows with a primary-key self-assignment (`SET "id" = id`). That keeps **one** statement, keeps the before/after hooks meaningful, and keeps `rows_affected` meaning "rows the predicate matched" — the reading every edge-write test in the repo already assumes (`expectEqual(1, try u.Save())`). MySQL still reports *changed* rows for such a self-assignment, which is the pre-existing, documented caveat for any no-op update rather than a new one. With neither a field nor an edge action the update has no meaning, so it is `error.NoFieldsToUpdate` instead of invalid SQL. The check sits after `fillAuditUser` and the `updated_at`/version maintenance, so an entity that contributes a column there is not mistaken for empty. |
| **Acceptance** | Met: `Update().Where(…).SetEdgeIDs(…)` works with no companion `setFieldValue` and returns the matched-row count; `Update().Where(…)` alone returns `error.NoFieldsToUpdate`. Falsified by dropping the self-assignment: the test fails with the original `near "WHERE": syntax error`. |
| **Status** | **Fixed** v0.45.0. |

---

### Z20 — Four reports about Optional, NULL and nullability

| | |
|--|--|
| **Problem** | Four claims from a consumer: (1) `field.Text(...).Optional()` does not resolve NULL; (2) `Default(x).Optional()` cancels the `Optional`; (3) `error.TypeMismatch` should name the table and the column; (4) zent should self-check schema-vs-DDL nullability. |
| **Verification** | (1) and (2) **did not reproduce** as stated: `field.Text("body").Optional()` yields `?[]const u8` and a nullable column, `Default(5).Optional()` still yields `?i64` and a nullable column (`Default` touches `f.default`, `Optional` touches `f.optional`; nothing cancels anything), and NULL round-trips through create and read. Both are now pinned by `nullable fields: Optional survives Default, and NULL round-trips`, which checks the entity types, `PRAGMA table_info`'s `notnull`, and a real NULL round-trip. The **actual** defect behind the report is narrower and was real: a bare `null` literal in `setFieldValue` was rejected at compile time — `expected ?[]const u8, got @TypeOf(null)` — so the natural spelling `setFieldValue("body", null)` failed with a message that reads as "null is not supported". Fixed in `field_value.accepts`/`toSqlValue`. (3) and (4) reproduced; details below. |
| **Fix for (3)** | An entity scan that fails with `TypeMismatch` now walks the struct against the row and logs *which* column: `zent: table 'x' column 'y' is NULL, but field 'y' ([]const u8) is not optional …`, or "no NULL found, so a value does not fit its field's type" when that is the case. Emitted at `warn` — the error itself is already returned; this is the context it lacks — and only on the failure path, so a successful read pays nothing. A logged `err` would be a test failure in Zig, hence `warn`. |
| **Fix for (4)** | `sql_schema.checkNullability(allocator, driver, infos)` returns every column whose nullability differs (`NullabilityDrift.breaksReads()` marks the dangerous direction). `migrateSchema` runs it at the end and reports one summary line at `warn` with the per-column detail at `debug` — a legacy database can disagree about hundreds of columns, and a wall of warnings is read by nobody. `MigrateOptions.check_nullability` (default `true`) turns it off. The introspection already existed and carried `not_null`; it had simply never been compared. |
| **Acceptance** | All four resolved: two by pinning the behaviour and fixing the bare-`null` spelling, one by naming the column in the diagnosis, one by shipping the check. |
| **Status** | **Fixed** v0.46.0. |

---

### Z21–Z26 — The zmshop_zent report (13 items, v0.46.0 baseline)

A multi-tenant e-commerce backend that has moved all persistence onto zent
reported thirteen items, four of them line-verified by its author. Two were
written up as ready-to-execute work orders; both shipped in v0.47.0.

| # | Item | Verdict |
|---|---|---|
| 1 | `Nillable()` produces a nullable column with a non-optional field | **Confirmed and fixed** (Z21). `Nillable()` set only `f.nillable`; `entity.zig` and `field_value.zig` read `f.optional` alone, so a NULL failed to scan and `setFieldValue(…, null)` did not compile — while `BEST_PRACTICES` and the scan diagnostic both recommend `Nillable()`. Zero call sites, so the one-line fix (set both flags, as ent does) could not break anyone. |
| 2 | `zent.scope` fragments always number from `$1` | **Confirmed and fixed** (Z22). On PostgreSQL a head binding `$1` plus a fragment binding `$1` share one parameter: the tenant value is bound to the head's argument and foreign rows come back with no error. `arg_index`/`marker` + `Builder.arg_base`; the PG test asserts rows, not text, and dropping the offset renders `$1`. |
| 3 | `PoolExhausted` flattens every failure; no request-level borrow budget | **Confirmed; the taxonomy half is fixed** (Z24). The pool now returns the cause (`ConnectionFailed`, `PingFailed`, …) instead of the constant, `Metrics.onError` sees it, and the give-up path logs a `warn` where the pool previously had no log statement at all. **Both halves are fixed now** (Z24, v0.56.0). `borrowWithTimeout(ms)` / `borrowCtx(&ctx)` / `borrowWithBudget(ms, &ctx)` take the waiting time as an argument, the effective budget is `min(requested, max_wait_ms)`, and `max_wait_ms` is a hard ceiling — it no longer falls back to `max_retries × retry_backoff_ms`, which is the measurement below. A statement or transaction deadline covers **waiting for a connection** too: `execCtx`/`queryCtx` merge the context before borrowing, and `beginTxCtx` was added to both the vtable and `Driver` (drivers without the hook fall back to `beginTx`). Falsified six ways with timing evidence — removing the ceiling makes `expect(elapsed_ms < 500)` fail at 1001 ms. Their measurement stands as the description of the old behaviour: `openConnection() catch return null` discarded the driver's own error (bad credentials, `too many clients`), `pool.zig` contained no `std.log` at all, and `max_wait_ms` was not an upper bound. Their 120-concurrent measurement (114/120 hard 500 at pool=10, then 24×200 + 96×503 at 32) shows the failure moving rather than disappearing. |
| 4 | PostgreSQL has no `dead` flag, and the only health check runs under the pool mutex | **Confirmed and fixed** (Z23) — the flag half. Verified against a real server. `postgres.zig` had no `dead` field (the `grep` hits are `deadline`), while `mysql.zig` has one with a documented fail-fast guard, and `pool.zig` evicts on `@hasField(D, "dead")` — so on PG a connection that returned `ConnectionFailed` went straight back into `available`, and one server restart kept handing the same corpse to successive requests. The borrow-path ping under the mutex is **fixed too** (Z23, v0.56.0), which closes the item. A borrow now selects a candidate under the lock and pings it **after unlocking**, re-taking the lock only to close a connection that failed, so concurrent borrows no longer queue behind each other's round trips. Their own note (ping-under-mutex deadlocks against a fiber IO runtime) is why the check is still off by default; the `dead` flag remains what makes turning it off safe. |
| 7 | `checkNullability` unreachable for a query-only consumer | **Confirmed and fixed** (Z26). Their DDL is a set of `.sql` files, so the hook inside `migrateSchema` never ran for them, while they had 70 drifted columns in hand. `assertNullability(alloc, drv, infos, .read_breaking_only \| .any)` now fails rather than logs; the distinction between the two directions is pinned by a test, because a gate that can block a deploy needs its boundary stated. |
| 11 | A raw predicate's `OR` escapes the injected scope predicate | **Confirmed and fixed** (Z25). `WHERE a = 1 OR b = 2 AND app_id = ?` binds the injected `AND` to the second operand, so rows satisfying `a = 1` came back regardless of tenant. `.raw`/`.raw_args` are parenthesised now; proven with rows (a foreign tenant's row that satisfies the `OR`), and removing the parentheses makes the test fail with `expected 1, found 2`. Their note that the change is byte-identical with the existing `RawArgs` expectation was **not** accurate — that fragment carries its own parentheses, so it gains a redundant pair. |
| 10 | Sub-query predicates do not scope the inner table | (Z32) **Confirmed; fixed where it can be, documented where it cannot.** Their example was `sql.InSelect`/`in_subquery`, which render exactly what they are given — the `sql` layer has no graph, so nothing there can widen it, and `BEST_PRACTICES` §3a now says so. The *codegen* layer's own edge predicates (`Has*`) had the same hole and **could** be fixed: they now apply the target's soft-delete scope (proven with a trashed-only parent, falsified by removing the emission). Privacy filters and the interceptor chain remain out of reach for a bare predicate — pass the tenant predicate through `Has<Edge>With(…)`, which the consumer's own workaround already does by hand. |
| 6 | raw SQL / identifiers have no validation entry point; introspection is private | **Half fixed** (Z28). The introspection (`getExistingColumns`/`getExistingIndexes`, all three dialects) is exported, and the comparison they wrote three audit scripts to perform is now `checkSchema`/`assertSchema` — including the missing-column case behind their "endpoint returned empty for months" incident. **`checkStatement` shipped in v0.58.0** (`zent.sql_statement`, prepare-and-discard on all three dialects), which takes their own caveat seriously: the entry is prepare-only — it takes the args, binds nothing, executes nothing — because `explainSql` accepts no parameters and could not have answered the question the entry exists for. The three dialects' reach differs and the diagnosis says so instead of pretending otherwise (SQLite classifies from the message and flags that; PG's `25P02` and MySQL's `1295` are `not_checkable`, not broken). **The CLI entry shipped in v0.65.0 as a standalone `check_sql` binary** rather than a `ZENT_MIGRATE_CMD=check` mode of the migrate example: a checker has to take files and `--sql` text, split the statements itself and answer with a CI exit code, none of which belongs to the migration command (whose DSN handling also stops at `postgres://`). **Still open**: validating raw *identifiers* rather than whole statements. |
| 12, 13 | error classification invisible; pool has no stats and no capacity guidance | **Fixed** (Z29). `driver.classify` gives the four classes a handler needs; `isRetryable` gained the pool errors (their own complaint: the one error you most need this for was reported as not retryable); `ConnPool.stats()` is a mutex-held snapshot, replacing an example that read the internals unlocked. The capacity formula is in `BEST_PRACTICES`. |
| 9 | `CrudService.create` fills the tenant column from the caller's entity, bypassing the interceptor's if-missing | **Confirmed and fixed** (Z30). Their note said their consumer does not use `CrudService`; the defect is real regardless, and it contradicted the documented claim that the service enforces tenant isolation on every operation. `create` takes `tenant_id` now, like every other method. Falsified by not writing it: three tests fail, including the tenant-isolation one. |
| 8 | `migrateSchema` creates the drift it later warns about | **Partly fixed** (Z31, v0.56.0: the nullability half; the rest documented). `MigrateOptions.allow_nullability_change` (default `false`) makes an **added** `NOT NULL` column arrive `NOT NULL DEFAULT …` — with `error.NotNullNeedsDefault` rather than a guess when the field has no default to backfill from — and converges an **existing** column's nullability on PostgreSQL. SQLite has no `ALTER COLUMN` so only the added-column half applies there; MySQL **fails closed** (`error.MySQLNullabilityChangeUnsafe`) because `MODIFY COLUMN` rewrites the whole definition and this layer introspects neither `EXTRA` nor charset/collation/comment. **`ExistingIndex.columns` shipped in v0.58.0**, with `SchemaDrift.Kind.index_columns` reporting a declared index the database holds under the same name with a different ordered key list. Deliberately narrow: expression keys, partial indexes, non-btree access methods, invalid indexes and `INCLUDE` columns are skipped rather than guessed, and `breaksReads()` is false for the kind, because a false drift blocks a deploy while a missed one is a warning nobody reads. The same release closed the MySQL half of the added-column case: `field.Text` with `Unique()`/`Default()`, or used as an index column, now fails with a named error instead of a raw errno. **Still open**: `view_sql` replacement, `UNIQUE`/FK added by `ALTER`. Their original verification stands: All of it confirmed against the source: `ALTER ADD COLUMN` omits `NOT NULL` (SQLite cannot take it without a default — the reason is in a code comment), existing nullability is never modified, `UNIQUE`/foreign keys never arrive by `ALTER`, a changed `view_sql` never takes effect (`CREATE VIEW IF NOT EXISTS`), and index comparison is by name only. `BEST_PRACTICES` §5h now lists all six with their consequences and manual remedies. The fixes change migration semantics — `ALTER … SET NOT NULL` against live data, view replacement (PG cannot `OR REPLACE` a reshaped view; MySQL DDL is not transactional), columns on `ExistingIndex` — so they belong to a pass that can test against real databases rather than to this one. |
| 5 | Arena scanning, public introspection, migration self-drift, `CrudService` tenant column, sub-query scope, error classification, pool observability | **Every topic in this row now has an ID and a verdict: Z27, Z28, Z31, Z30, Z32, Z29.** Item 5 itself — "no way to scan into the caller's arena", called the largest engineering tax in the list — is **fixed** (Z27, v0.56.0). The consumer's own numbers justify the shape: `deinitEntity(infos, XInfo, &e, client.x.allocator)` appears **607 times** in their tree, while the ergonomic `managedEntity`/`dupeEntityTo` shipped in v0.31.0 appear **zero** times — the four-argument teardown won on ergonomics, so the fix was to remove the teardown rather than to document it better. |

**What this report got right that matters:** it is the second time a consumer
found a defect in something this project had just shipped or documented (v0.46.0
had just documented `Nillable()` as the fix for nullability). Two of the four
claims I was handed in Z20 did not reproduce; these did. Both of the ones fixed
here were reachable only through documentation this project wrote.

---

### Z33–Z34 — the "two readings" report (2 items, v0.65.0 baseline)

A consumer sent a file of items that are **not** "somewhere is wrong" but "the
same thing has two readings and the code picked one for the caller", asking zent
to decide the semantics. Both were verified line by line here before acting; the
IDs are assigned as they proposed.

| # | Item | Verdict |
|---|---|---|
| A | **Z33** — an empty `dept_ids` list on a `.dept_custom` / `.dept_and_child` data scope widened instead of denying | **Confirmed and fixed** (v0.66.0). `ensurePred` returned early for `dept_ids.len == 0`, leaving `pred` null — and `null` is how this module spells "no restriction" (`deny_pred`'s own doc says a scope that cannot be built "must never come out looking like `.all`"). The adjacent branch, over `max_dept_ids` and differing only in **length**, materialized the deny. Fixed by treating the empty list as a "cannot be built" too: `1 = 0` plus a `warn`, with `.all` untouched as the way to say "unrestricted". Their evidence was exact, including the amplification they did not have: **`.dept_and_child` is a synonym for `.dept_custom`** (same switch arm; only `.dept_only` reads `self_dept_id`), so a caller using it with `self_dept_id` alone *always* passed an empty list — the very path that became a full-table read. Falsified five ways; their exposure was 0, so this was found by reading, not by being bitten. |
| B | **Z34** — `BulkDelete().Exec()` with no predicate: a silent `0` on a soft-deleting entity, a **full-table `DELETE`** on a hard-deleting one | **Confirmed and fixed** (v0.66.0). `BulkDeleteBuilder.init` always appends a group, so the two `groups.items.len == 0` guards in `codegen` were **unreachable** — the code looked guarded and was not; the soft path's loop then skipped the empty group and returned 0 without executing anything, and the hard path emitted `DELETE FROM t` with no `WHERE`. Fixed in the shape v0.45.0 used for a `SET`-less `UPDATE`: `error.NoPredicate`, named rather than resolved. The two duplicated implementations (`query` / `takeQuery`) were merged so the rule has one home. Their `Next()`-before-`Where` observation is a separate fix: that shape used to render `WHERE  OR …`. Verifying it also turned up two more defects their file could not see: the bulk soft-delete path **dropped the policy's row filters** (a privacy gap — fixed in v0.66.0 with its own test and falsification), and both soft-delete paths **re-trashed a row already in the trash**, rewriting its `deleted_at` and counting it again where the hard path answers 0 (fixed in v0.67.0; the single-row path is a behaviour change — a repeat delete answers 0 and `ExecOne` raises `NotFound` — checked against every test, example and bench first). |

Both items were judged worth acting on despite a **zero** exposure for the
reporting consumer, because the shape they share is the one this ledger keeps
recording: a value that carries two meanings, resolved silently in one direction.

## Tracking

| ID | Title | P | Status |
|----|-------|---|--------|
| Z1 | ContainsEscaped MySQL | P0 | **Fixed** v0.30.0 |
| Z2 | Business-key upsert | P0 | **Fixed** v0.30.0 |
| Z3 | Large-schema / multi-graph | P0 | **Documented** v0.31.0 |
| Z4 | INSERT IGNORE | P1 | **Fixed** v0.30.0 |
| Z5 | SELECT expressions | P1 | **Fixed** v0.31.0 |
| Z6 | Row getInt semantics | P1 | **Fixed** v0.30.0 |
| Z7 | Where `&.{}` | P1 | **Fixed** v0.30.0 |
| Z8 | deinitEntity ergonomics | P1 | **Fixed** v0.31.0 |
| Z9 | beginTxFromDriver | P1 | **Fixed** v0.31.0 |
| Z10 | WithEdge options | P1 | **Fixed** v0.31.0 |
| Z11 | Decimal field | P2 | **Fixed** v0.31.0 |
| Z12 | Complex UPDATE expr | P2 | **Fixed** v0.31.0 |
| Z13 | Docs alignment | P2 | **Fixed** v0.30.0 |
| Z14 | `Contains` semantics vs name | P2 | **Partially fixed** — docs+test done, naming **Open** |
| Z15 | Edge writes on `From` edges | P2 | **Fixed** v0.44.0 — FK written in the UPDATE's SET |
| Z16 | Multi-graph first-class | P2 | **Stage 1 done** v0.39.0 (actionable error); stages 2/3 **Open** per ROI |
| Z17 | Entity release shape | P2 | **Fixed** v0.40.0 — `deinitRow`/`deinitRows`/`deinitEdgeRows` |
| Z18 | `setFieldValue` accepted set drifts | P2 | **Fixed** v0.43.0 — one `field_value` module, tested both ways |
| Z19 | A `SET`-less UPDATE is invalid SQL | P1 | **Fixed** v0.45.0 — edge-only update; empty update names the reason |
| Z20 | Four reports about Optional / NULL / nullability | P1 | **Fixed** v0.46.0 — two did not reproduce; bare `null`, the column-named diagnosis and `checkNullability` shipped |
| Z21 | `Nillable()` gives a nullable column with a non-optional field | P1 | **Fixed** v0.47.0 — sets both flags |
| Z22 | `zent.scope` fragments always number from `$1` | P1 | **Fixed** v0.47.0 — `arg_index` / `Builder.arg_base` |
| Z23 | PG has no `dead` flag; the only health check runs under the pool mutex | P1 | **Fixed** v0.55.0 (flag) + v0.56.0 (ping moved out of the lock) |
| Z24 | `PoolExhausted` flattens every failure; no request-level borrow budget | P0 | **Fixed** v0.51.0 (taxonomy) + v0.56.0 (budget, `PoolWaitTimeout`) + v0.58.0 (`codegen.beginTxCtx`, so the budget is reachable from the fluent layer) |
| Z25 | A raw predicate's `OR` escapes the injected scope predicate | P1 | **Fixed** v0.52.0 — `.raw` / `.raw_args` parenthesised |
| Z26 | `checkNullability` unreachable for a query-only consumer | P1 | **Fixed** v0.52.0 — `assertNullability` as a gate |
| Z27 | No way to scan into the caller's arena | P2 | **Fixed** v0.56.0 — `AllIn` / `FirstIn` / `SaveIn` / `queryRowsIn` |
| Z28 | raw identifiers have no validation entry point; introspection is private | P2 | **Fixed (API + CLI)**: v0.53.0 introspection + `checkSchema`; v0.58.0 `checkStatement` (prepare-and-discard); v0.65.0 the `check_sql` CLI (`examples/check_sql`, `zig build run-check-sql`, exit 1 on a failed statement / 0 when only `not_checkable`). Still open: validating raw *identifiers* rather than whole statements |
| Z29 | Error classification invisible; pool has no stats or capacity guidance | P2 | **Fixed** v0.53.0 — `driver.classify`, `ConnPool.stats()`, capacity formula |
| Z30 | `CrudService.create` filled the tenant column from the caller's entity | P2 | **Fixed** v0.54.0 — `create(entity, tenant_id)` |
| Z31 | `migrateSchema` creates the drift it later warns about | P2 | **Reporting complete; repair still opt-in or absent** — v0.56.0 nullability behind `allow_nullability_change`; v0.58.0 `ExistingIndex.columns` + `index_columns` drift and MySQL BLOB/TEXT DDL diagnosis; v0.59.0 `index_uniqueness` drift, the ALTER ADD COLUMN half of the diagnosis, bound/validated introspection names; v0.60.0 `unique_constraint` (field-level `UNIQUE`) and `missing_foreign_key` (by shape); v0.61.0 `missing_view` (`breaksReads` **true**) plus `getExistingViews`, and **PostgreSQL can create a view at all now** (`CREATE VIEW IF NOT EXISTS` is not PostgreSQL syntax — 42601 — so a schema with a view entity could not be migrated on PG since views were added). v0.62.0 adds `missing_junction_table` (**M2M junction tables were the last declared surface nothing checked** — found this round by enumerating what the schema declares against what `checkSchema` compares) and fixes two driver failures that were being read as a default (SQLite step failures read as end-of-rows, PostgreSQL's `rows_affected` count). v0.65.0 adds the junction **shape** comparison (`missing_column` / `junction_pair_uniqueness` / `missing_foreign_key` for a present junction) and the EntQL end-of-input requirement. Still open: `migrateSchema` does not add `UNIQUE`/FK with `ALTER`; view *definitions* are deliberately not compared; a junction name colliding with an entity table is unchecked |
| Z33 | Empty `dept_ids` widens a data scope instead of denying | P1 | **Fixed** v0.66.0 — an empty list is a "cannot be built": `1 = 0` + warn; `.all` is the way to say "unrestricted" |
| Z34 | No-predicate `BulkDelete` is a silent `0` or a full-table delete | P1 | **Fixed** v0.66.0 — `error.NoPredicate`, the shape v0.45.0 chose for a `SET`-less UPDATE; the duplicated bodies were merged. Its verification also found the bulk soft-delete path dropping the policy's row filters (fixed v0.66.0) and both soft-delete paths re-trashing an already-trashed row (fixed v0.67.0) |
| Z32 | Sub-query predicates do not scope the inner table | P2 | **Partly fixed** v0.52.0 — `Has*` targets scoped; bare `sql.InSelect` documented as out of reach |

**On IDs.** `Z<n>` numbers are allocated once and never reused; before v0.56.0 the
running table stopped at Z18 while the prose above referenced Z23–Z31, so those
references did not resolve anywhere. Two collisions were found and fixed in the
same pass, both verifiable in git:

- **Z24 vs Z27 for the same work.** Commit `94bab23` ("…(Z24)") added the
  `PoolExhausted` taxonomy and labelled it `(Z24)` in both its subject and the
  table above, but `(Z27)` in the CHANGELOG entry it wrote. Two of three said
  Z24, so the CHANGELOG line was a typo and is now Z24.
- **Z27 was therefore never allocated**, and is item 5 (arena scanning) from
  v0.56.0 on. Item 10 carried no ID at all and is now Z32.

When filing GitHub issues, title prefix `[zapi]` and link this file + the consumer path cited above.
