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

When filing GitHub issues, title prefix `[zapi]` and link this file + the consumer path cited above.
