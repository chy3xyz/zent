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
| **Status** | Open |

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
| **Status** | Open |

### Z5 — Fluent SELECT / ORDER BY expressions

| | |
|--|--|
| **Problem** | `FROM_UNIXTIME`, Haversine, `CONCAT`, `UNIX_TIMESTAMP()` force raw queries across list/export paths. |
| **Proposal** | `SelectExpr("…", "alias")`, `OrderByExpr`, optional `ScalarExpr` for one-value queries; map into DTO / `sql.Value`. |
| **Status** | Open |

### Z6 — Clarify or harden raw `Row.getInt` / `getText`

| | |
|--|--|
| **Problem** | Returns `?T`, not error union; authors repeatedly write `try row.getInt`. |
| **Proposal** | Prefer `mustGetInt` / `tryGetInt` naming, or breaking `getInt → error{NullColumn}!i64`; examples forbid `try getInt`. |
| **Status** | Open |

### Z7 — `Where` accepts `&.{}` or clear `@compileError`

| | |
|--|--|
| **Problem** | `&.{ P.xEQ }` vs `.{}` causes opaque comptime failures (`BEST_PRACTICES` anti-pattern). |
| **Proposal** | Normalize pointer-to-tuple, or emit actionable compile error. |
| **Status** | Open |

### Z8 — `deinitEntity` ergonomics

| | |
|--|--|
| **Problem** | Must use `var` + `client.<e>.allocator` (not request arena); footgun under HTTP. |
| **Proposal** | `Entity.deinit(*T)` bound to client allocator; debug assert on wrong allocator; optional `ManagedEntity` / `dupeTo(arena)` helper. |
| **Status** | Open |

### Z9 — `beginTxFromDriver` + Driver-first loaders

| | |
|--|--|
| **Problem** | Multi-graph apps share `pool.asDriver()` but Client types don’t mix; payment/refund loaders need Driver-first APIs. |
| **Proposal** | `beginTxFromDriver(infos, drv, alloc)`; document Driver-first config loader pattern; optional `beginTx(infos, *Client)`. |
| **Status** | Open |

### Z10 — `WithEdge` options (join kind + limit mode)

| | |
|--|--|
| **Problem** | LIMIT applied before edge load skews result sets; INNER vs LEFT requires manual filtering; edges must live in one graph. |
| **Proposal** | `WithEdgeOpts{ .join = .left|.inner, .limit_mode = .after_edges }`; document cross-graph edge rules. |
| **Status** | Open |

---

## P2

### Z11 — `field.Decimal` / money types

Schema `Int` vs MySQL `DECIMAL` forces text reads (`DATA_ESCAPES` money rows). Scan to owned string or fixed-point; never silent truncate.

### Z12 — Controlled multi-table / GREATEST update expressions

Stock `GREATEST` and dual-table decrements remain raw. Document fluent limits; optional allowlisted `execExpr`.

### Z13 — Docs: multi-graph playbook + escape ledger hygiene

Align official docs with ODKU reality; add “Multi-graph” section; escape template column “min zent version”.

---

## Tracking

| ID | Title | P | Status |
|----|-------|---|--------|
| Z1 | ContainsEscaped MySQL | P0 | **Fixed** v0.30.0 |
| Z2 | Business-key upsert | P0 | **Fixed** v0.30.0 |
| Z3 | Large-schema / multi-graph | P0 | **Documented** v0.31.0 |
| Z4 | INSERT IGNORE | P1 | **Fixed** v0.30.0 |
| Z5 | SELECT expressions | P1 | Open |
| Z6 | Row getInt semantics | P1 | **Fixed** v0.30.0 |
| Z7 | Where `&.{}` | P1 | **Fixed** v0.30.0 |
| Z8 | deinitEntity ergonomics | P1 | Open |
| Z9 | beginTxFromDriver | P1 | Open |
| Z10 | WithEdge options | P1 | Open |
| Z11 | Decimal field | P2 | Open |
| Z12 | Complex UPDATE expr | P2 | Open |
| Z13 | Docs alignment | P2 | **Fixed** v0.30.0 |

When filing GitHub issues, title prefix `[zapi]` and link this file + the consumer path cited above.
