# AGENTS.md — zent

## Project

- Zig port of [ent](https://entgo.io/) (Go ORM). Targets Zig 0.17-dev.
- Remote: `https://github.com/chy3xyz/zent.git`
- Default branch: `main`
- Build is driven by `build.zig`; CI lives at `.github/workflows/ci.yml`.
- Version: **v0.39.0** (package version synced to tags — see `docs/RELEASING.md`).

## Commands

- `zig build` — build the library and example executables
- `zig build test` — run unit tests (322 tests, 0 leaks; leaks fail the run; count grows when libpq/libmariadb headers are present)
- `zig build test-integration` — run integration tests (SQLite always; PostgreSQL/MySQL too when their headers were found, otherwise those files are not compiled in. `SKIP_PG`/`SKIP_MYSQL` skip them at runtime; the 3 MySQL TLS cases need `MYSQL_SSL_CA`/`MYSQL_SSL_CERT`/`MYSQL_SSL_KEY` or they skip)
- `zig build benchmark` — run performance benchmarks (builder/scan/pool/cache/eager/upsert)
- `zig build run-start` — run the `examples/start` smoke test
- `zig build run-complex` — run the `examples/complex` e-commerce demo
- `zig build run-pool` — run the `examples/pool` connection-pool demo
- `zig build run-interceptor` — run the `examples/interceptor` multi-tenant demo
- `zig fmt --check src examples tests build.zig` — formatting
- `bash scripts/check-version.sh` — release-consistency gate (CI)
- `bash scripts/check-deadcode.sh` — dead-code baseline gate (CI; needs
  `ZMODU=<path>` pointing at the zmodu CLI built from zigmodu)
- `bash scripts/release.sh <x.y.z> [--push]` — one-shot release flow

## CI gates

fmt → build → unit tests → version consistency → integration tests
(SQLite/PostgreSQL/MySQL) + a standalone dead-code baseline job.

## Repository conventions

- **Commit and push proactively** after meaningful code changes.
- Match the surrounding code's style and naming. Run `zig fmt` before committing.
- Public API is fluent/chainable like ent (e.g. `client.user.Create()` → `setFieldValue("name", "foo")` → `Save()`; builder methods return `!*Self`, so chain each step with `try`).
- Use `comptime` for schema introspection; no external code generation.
- Drivers: SQLite is first-class, PostgreSQL and MySQL are present but less
  exercised; the library never forces C linkage — consumers link their own
  sqlite/pg/mysql (see README "Consumer wiring").

## Docs map

- `docs/RELEASING.md` — release flow + consumer hash-sync
- `docs/ARCHITECTURE.md` — layer map + memory ownership contract
- `docs/superpowers/specs/` — design specs (benchmark, …)
- `CHANGELOG.md` — Keep a Changelog (release discipline)

## Zig 0.17 gotchas (learned — avoid regressions)

| Pattern | Do this |
|---|---|
| `std.ArrayList(T).init(alloc)` / `.append(x)` | `.empty` + explicit allocator arg |
| `std.mem.trimRight/trimLeft` | `std.mem.trimEnd/trimStart` |
| `@typeInfo(T).fields` | `.field_names` / `.field_types` / `.field_attrs` + `attrs.defaultValue(ft)` |
| `std.meta.hasDecl` | builtin `@hasDecl` |
| `_ = <error union>` | `try` / `catch` (bare statement OK, `_ =` is not) |
| unused fn params | `_`-prefix them (0.17 errors otherwise) |
| query rows | `All()` returns `std.array_list.Managed(Entity)`: `deinitEntity` per item, then `users.deinit()` (never pair a per-item free with a slice free) |

## Memory ownership

Entities and queries are explicitly owned by the caller. See the contract:

- `q.All()` etc. returns `std.array_list.Managed(Entity)`; caller MUST call `deinitEntity(infos, info, &entity, alloc)` per item, then `users.deinit()`.
- `OwnedQuery` (from `Builder.takeQuery` / `Selector.takeQuery`) MUST be `deinit`'d.
- `driver.Tx` MUST be `deinit`'d exactly once, regardless of `commit`/`rollback`.
- `sql.QueryResult` (`{ sql, args }`) borrows from the builder; `OwnedQuery` (from `Builder.takeQuery` / `Selector.takeQuery`) transfers ownership and MUST be `deinit`'d.
- The root `Client` lazily heap-allocates its `InterceptorChain` on first `client_mod.UseInterceptor(infos, &client, i)`; release it with `client_mod.DeinitClient(infos, &client)` **once, on the value that registered**. Value copies (helpers, `withContext`, tx clients) borrow the same chain and must not be deinit'd; `withInterceptors(chain)` borrows a caller-owned chain, which `DeinitClient` leaves alone. `StoreEnv`/`PooledEnv`/`ShardedEnv` release the clients they created on `deinit` (each shard client individually). Register before `beginTx` — the tx client borrows the same chain.
- Use `std.testing.allocator` in tests so `zig build test` reports leaks with non-zero exit.

## Security invariants (do not regress)

- **Interceptor `whereEq` dedupes on the (column, value) pair, never the
  column.** Column-only dedupe lets a caller predicate suppress the
  interceptor's own value = a tenant bypass. All eight `add_eq_fn` sinks go
  through `sql.appendEqUnlessPresent`; the two create-path sinks are a
  *filler* (an explicitly set field wins), so a write constraint the caller
  must not override belongs in a privacy policy, not an interceptor.
- **Both bulk neighbour readers share the target read contract.** `WithEdge`
  and `client.queryTargets*`/`QueryEdge` all funnel through
  `codegen.query.appendTargetScopePreds` (soft-delete → privacy →
  interceptors). Never re-implement that chain at a second call site — the
  previous hand-rolled copy is what left `QueryEdge` fail-open while eager
  loading was fail-closed.
- **Neighbour queries qualify injected predicates with the target table.**
  m2o joins the source and m2m joins the junction, so a bare column is
  ambiguous whenever both sides own it. Qualification lives in one helper
  (`sql.appendQualifiedPred`) shared with `zent.scope`; never re-inline it.
- **Raw SQL is unscoped unless it goes through `zent.scope`.** The builders are
  where privacy and interceptors run, so a hand-written statement has to ask
  for the fragment (`forClient` + `withClause`). Any new raw-SQL helper must
  route through `appendTargetScopePreds`, not re-implement the chain.
- **Positional row scans are column-count guarded.** `scanRow*` rejects a
  result set narrower than the struct with `error.ColumnCountMismatch`; the
  drivers do not all bounds-check. Keep that check when adding a scanner.

## Layout

- `src/core/` — comptime schema definition API
- `src/codegen/` — comptime client/query/mutation generation
- `src/sql/` — SQL builder, driver interface, SQLite/PostgreSQL/MySQL drivers
  (`builder/dialect/driver/scan/sqlite/postgres/mysql/schema`, plus
  `pool.zig`, `cache.zig`, `explain.zig`, `logger.zig`, `value.zig`)
- `src/runtime/` — hook, interceptor (runtime query rewriting), and error helpers
- `src/privacy/` — privacy policy framework
- `src/graph/` — graph traversal helpers
- `src/entql/` — EntQL expression parser
- `src/crud.zig` / `src/outbox.zig` / `src/shard.zig` / `src/helpers.zig` — higher-level services
- `examples/start/` — schema introspection + CRUD smoke test
- `examples/complex/` — e-commerce demo with advanced SQL operations
- `examples/pool/` — connection-pool usage demo
- `examples/migrate/` — migration-file runner demo
- `examples/interceptor/` — multi-tenant query-rewriting demo (`UseInterceptor`)
- `tests/integration/` — end-to-end tests
