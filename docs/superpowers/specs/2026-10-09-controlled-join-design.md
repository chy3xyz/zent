# Controlled JOIN (v1) — design

Status: **proposed** (awaiting go-ahead). Source of the constraints and all
line references: the v0.87.0 read of `query.zig` / `builder.zig` /
`neighbors.zig` / `scope.zig`. Consumers waiting on this: the downstream
report counted ~157 of its 159 raw-SQL escape hatches as JOIN-shaped.

## 0. Facts this design stands on

- `QueryBuilder` assembles from `sql.Selector` (`query.zig:1621`), so
  `Selector.join` (`builder.zig:1064`, `Join{kind, table, on}` at
  `builder.zig:927`) is already reachable; the COLUMNS→FROM→JOINS→WHERE
  ordering is correct.
- `ColumnRef` supports `table` qualification and `AS alias`
  (`builder.zig:222-243`); `TableBuilder` has no `alias` field yet.
- Scope predicates are built **unqualified** and qualified at render time —
  three existing precedents: `neighbors.zig:218`, `scope.zig:130`,
  `neighbors.zig:367` (`appendQualifiedPred` + alias).
- `WithEdgeOptions` `EdgeJoinKind` (`query.zig:406-434`): only inner/left;
  `.inner` degrades to an EXISTS filter (`query.zig:723-728`);
  `limit_mode.after_edges` is meaningful only there.
- Target projections must be explicit column lists (Z35;
  `Step.to_columns`, `neighbors.zig:54-75`).
- `deinitRows` → `deinitEntityEdges` (`entity.zig:296-331`) recursively frees
  eager edge slices, target owning fields and the JSON arena — anything a
  JOIN materialises into eager fields is released by the existing path.

## 1. API — by edge name, not table name

```zig
pub const JoinEdgeKind = enum { inner, left };   // right/full not representable

pub const JoinEdgeOpts = struct {
    where: ?[]const sql.Predicate = null,      // target-schema-validated
    select: ?[]const []const u8 = null,        // target field names; null = all
    alias: ?[]const u8 = null,                 // default: the edge name
};

pub fn joinEdge(self: *Self, comptime edge_name: []const u8, kind: JoinEdgeKind,
    opts: JoinEdgeOpts) !*Self;
```

Rationale: the target table/columns resolve from graph metadata (declared
`table_name` respected — the Z39 lesson), the scope chain gets its anchor
(the target `TypeInfo`), `where` validates against the target schema the same
way `Has{Edge}With` does, and `select` is a comptime whitelist. Generated
shape (m2o):

```sql
SELECT "order"."id", …, "customer"."id" AS "customer__id",
       "customer"."name" AS "customer__name", …
FROM "order"
INNER JOIN "customer" ON "customer"."id" = "order"."customer_id"
WHERE "order"."deleted_at" IS NULL
  AND "customer"."deleted_at" IS NULL   -- target scope, qualified at render
  AND "customer"."app_id" = ?
```

Alias defaults to the edge name, which also disambiguates self-joins. With a
join present, outer projections become source-qualified (R4).

## 2. Fan-out: m2o/o2o-From only; o2m/m2m rejected at comptime

Admission: the same predicate `addEdgeFields` uses for FK injection
(`graph.zig:548`) — the FK lives in the outer table, so a join matches at
most one row per outer row and `Limit/Offset/Page/Cursor*` semantics do not
move. o2m/m2m would multiply rows under LIMIT (the exact problem
`WithEdgeOptions.limit_mode` exists for) and aggregation is not "controlled"
(GROUP BY outer-wide vs `json_agg`/`group_concat`/`string_agg` dialect
triplets). Their filter need is already served by
`WithEdgeOptions(…, .{ .join = .inner })`; their read need by `WithEdge`.
Rejection message names the edge, the relation and the two alternatives.

## 3. Projection: fill the eager field (option i)

The target lands in the entity's existing `?[]Target` eager edge field (one
element for m2o): zero new types, release cascades for free, one round trip,
and `row.edges.customer.?[0].name` reads like the `WithEdge` shape. Target
columns scan by their `edge__field` aliases (`Row.columnIndex`, Z5) into a
`LightEntity` with the same JSON-arena contract as `loadEdgePath`
(`query.zig:337-351`). Known compromises, stated: one small allocation per
row; no second-level edges off a joined row (LightEntity depth); option (ii)
(a `JoinRow{source, target}` tuple family) stays a v2 candidate; option (iii)
(filter-only) is rejected as an EXISTS re-spelling.

## 4. Scope chain: no new entry point needed

`appendTargetScopePreds` already emits bare-column predicates; qualification
happens at render time. `joinEdge` is the fourth consumer of that pattern:
build the target's scope preds, then `sql.appendQualifiedPred(b, pred,
join_alias)` each into the statement. **One deliberate deviation from the
three precedents: on a LEFT JOIN the target scope predicates go into the ON
clause, not WHERE** — in WHERE they would turn the left join into an inner
one (R2; dedicated test). Interceptor `.eq` predicates are always rewritten
(the tenant-isolation case); self-contained policy fragments pass through
verbatim — failure modes unchanged and loud (ambiguous column error, or a
stricter outer-side filter), never a silent widening (R3).

## 5. Boundary with WithEdge / EdgeJoinKind

`joinEdge(edge, .inner, .{})` and `WithEdgeOptions(edge, .{ .join = .inner })`
produce the same row set for m2o; the former is one round trip and
materialises inline. Guard against double-loading: `loadEdgePath` skips a
head edge already served by `joinEdge`. Docs: a "joinEdge vs WithEdge"
decision block in §5g, a row in the §5 scoping table (it is a controlled
builder path — scoping applies by default), and a sentence in
`EdgeJoinKind`'s doc comment keeping the two from being folded.

## 6. Work breakdown and risks

v1 minimal set (~600–900 lines incl. tests, one focused week):
`sql.ColumnEQ` for the ON (R1); `TableBuilder.alias`; `JoinEdgeKind`/
`JoinEdgeOpts`/`joinEdge` with comptime admission + validation; assembly +
qualified projection + render-time scope loop (LEFT → ON); loader with
alias-scan into the eager field and the skip-in-`loadEdgePath` guard;
`ForUpdate` handling (R5: PG automatically gains `FOR UPDATE OF <source
alias>`); tests — three-dialect SQL text pins (LEFT scope-in-ON, self-join
alias, policy/interceptor injection, o2m/m2m compile-time rejection,
`nextError()` contract), a SQLite round trip, one allocation-failure case;
docs (§5g, §5 table, `UPGRADING`).

Risks: R1 `ColumnEQ` (identifiers come from TypeInfo — no injection surface);
R2 left-join scope placement (test-pinned); R3 verbatim policy fragments in
join statements (documented failure modes); R4 outer projection qualification;
R5 PG row-lock breadth; R6 MySQL alias case folding (quoted aliases, per
`scope.zig:60-64`); R7 wide×wide projection nearing MySQL's 4096-column
ceiling (recorded boundary); R8 `GroupBy`+join rejected (`error.JoinWithGroupBy`)
in v1.

Explicitly out (v1): right/full joins; o2m/m2m projection joins; cross-graph
joins (Z16); aggregates over joined columns.
