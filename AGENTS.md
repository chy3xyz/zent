# AGENTS.md — zent

## Project

- Zig port of [ent](https://entgo.io/) (Go ORM). Targets Zig 0.17-dev.
- Remote: `https://github.com/chy3xyz/zent.git`
- Default branch: `main`
- Build is driven by `build.zig`; CI lives at `.github/workflows/ci.yml`.

## Commands

- `zig build` — build the library and the `start` example
- `zig build test` — run unit tests (50 tests, 0 leaks)
- `zig build test-integration` — run SQLite integration tests
- `zig build run-start` — run the `examples/start` smoke test
- `zig fmt --check src examples tests build.zig` — formatting

## Repository conventions

- **Commit and push proactively** after meaningful code changes.
- Match the surrounding code's style and naming. Run `zig fmt` before committing.
- Public API should be fluent/chainable like ent (e.g. `client.User.Create().SetName("foo").Save(ctx)` — currently a partial subset, see `src/codegen/client.zig`).
- Use `comptime` for schema introspection; no external code generation.
- Drivers: SQLite is first-class, PostgreSQL and MySQL are present but less exercised.

## Memory ownership

Entities and queries are explicitly owned by the caller. See the contract:

- `q.All()` etc. returns `[]Entity`; caller MUST call `deinitEntity(infos, info, &entity, alloc)` per item, then `allocator.free(slice)`.
- `OwnedQuery` (from `Builder.takeQuery` / `Selector.takeQuery`) MUST be `deinit`'d.
- `driver.Tx` MUST be `deinit`'d exactly once, regardless of `commit`/`rollback`.
- Use `std.testing.allocator` in tests so `zig build test` reports leaks with non-zero exit.

## Layout (planned in `dev.md` §4)

- `src/core/` — comptime schema definition API
- `src/codegen/` — comptime client/query/mutation generation
- `src/sql/` — SQL builder, driver interface, SQLite/PostgreSQL/MySQL drivers
- `src/runtime/` — hook and error helpers
- `src/privacy/` — privacy policy framework
- `src/graph/` — graph traversal helpers
- `src/entql/` — EntQL expression parser
- `examples/` — example apps (currently `start/`)
- `tests/integration/` — end-to-end tests
