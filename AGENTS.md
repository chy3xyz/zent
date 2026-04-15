# AGENTS.md — zent

## Start here
- Read `dev.md` first. It is the architecture doc and phase-by-phase replication plan for porting [ent](https://entgo.io/) to Zig.
- Reference code lives in `_ref/ent/` (the original Go implementation). Treat it as **read-only**; do not modify it.

## Git workflow
- Remote: `https://github.com/knot3bot/zent.git`
- Default branch: `main`
- **Commit and push proactively** after completing meaningful code changes.
- Do **not** commit `_ref/` or `red.md`; they are gitignored by design.

## Repo state
- This is a very early-stage Zig project. There is **no `build.zig` yet** and no CI/test harness.
- The planned module layout is in `dev.md` §4; follow it when adding new files.
- Priority order for implementation: `dev.md` §5 (Phase 0 → Phase 1 → ...).

## Commands (when available)
- Once `build.zig` exists, expected commands will be:
  - `zig build` — build the library and examples
  - `zig build test` — run tests
- Until then, verify Zig source with `zig fmt` and `zig ast-check src/**/*.zig`.

## Constraints
- Keep the public API fluent/chainable like ent (e.g., `client.User.Create().SetName("foo").Save(ctx)`).
- Leverage `comptime` for schema introspection and type generation instead of external codegen tools.
- SQLite is the first supported driver; PostgreSQL/MySQL come later.
