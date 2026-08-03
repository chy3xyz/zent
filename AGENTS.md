# AGENTS.md — zent

## Project

- Zig port of [ent](https://entgo.io/) (Go ORM). Targets Zig 0.17-dev.
- Remote: `https://github.com/chy3xyz/zent.git`
- Default branch: `main`
- Build is driven by `build.zig`; CI lives at `.github/workflows/ci.yml`.
- Version: **v0.18.0** (package version synced to tags — see `docs/RELEASING.md`).

## Commands

- `zig build` — build the library and example executables
- `zig build test` — run unit tests (143 tests, 0 leaks; leaks fail the run)
- `zig build test-integration` — run SQLite integration tests
- `zig build benchmark` — run performance benchmarks (builder/scan/pool)
- `zig build run-start` — run the `examples/start` smoke test
- `zig build run-complex` — run the `examples/complex` e-commerce demo
- `zig build run-pool` — run the `examples/pool` connection-pool demo
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
- Public API should be fluent/chainable like ent (e.g. `client.User.Create().SetName("foo").Save(ctx)` — currently a partial subset, see `src/codegen/client.zig`).
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
| arena-borrowed rows | `QueryResult.deinit(allocator)` once; never `freeScanned` + `deinit` (double free) |

## Memory ownership

Entities and queries are explicitly owned by the caller. See the contract:

- `q.All()` etc. returns `[]Entity`; caller MUST call `deinitEntity(infos, info, &entity, alloc)` per item, then `allocator.free(slice)`.
- `OwnedQuery` (from `Builder.takeQuery` / `Selector.takeQuery`) MUST be `deinit`'d.
- `driver.Tx` MUST be `deinit`'d exactly once, regardless of `commit`/`rollback`.
- `QueryResult(T)` from `queryRows` is arena-backed: `deinit(allocator)` once,
  never per-item `freeScanned` (double free).
- Use `std.testing.allocator` in tests so `zig build test` reports leaks with non-zero exit.

## Layout (planned in `dev.md` §4)

- `src/core/` — comptime schema definition API
- `src/codegen/` — comptime client/query/mutation generation
- `src/sql/` — SQL builder, driver interface, SQLite/PostgreSQL/MySQL drivers
- `src/runtime/` — hook and error helpers
- `src/privacy/` — privacy policy framework
- `src/graph/` — graph traversal helpers
- `src/entql/` — EntQL expression parser
- `examples/start/` — schema introspection + CRUD smoke test
- `examples/complex/` — e-commerce demo with advanced SQL operations
- `examples/pool/` — connection-pool usage demo
- `tests/integration/` — end-to-end tests
