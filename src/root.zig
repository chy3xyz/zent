const std = @import("std");

pub const sql = @import("sql/builder.zig");
pub const sql_cache = @import("sql/cache.zig");
pub const sql_dialect = @import("./base/dialect.zig");
/// Per-dialect SQL expression fragments for raw SQL the fluent builders do not
/// cover: `nowSecs` (current epoch seconds), `insertIgnore` (the prefix *and*
/// suffix that spell an ignore-on-conflict insert) and `numericTextAsNumber`
/// (a TEXT column read as a number, which SQLite needs and the others do not).
/// See `sql/dialect_expr.zig` for the mappings, and for what is deliberately
/// left to `sql.InsertOrIgnore`. `zent.sql_dialect_expr`.
pub const sql_dialect_expr = @import("sql/dialect_expr.zig");
pub const sql_driver = @import("sql/driver.zig");
pub const sql_scan = @import("sql/scan.zig");
/// The package version, readable at comptime (`zent.version`). Mirrors
/// `build.zig.zon`; both are gated by `scripts/check-version.sh`. Use it to
/// check a dependency pin without consulting git.
pub const version = @import("version.zig").version;
/// Read-contract fragments for raw SQL: `zent.scope.forTable` /
/// `forClient` render the same soft-delete → privacy → interceptor scope the
/// fluent builders apply, for a statement you write yourself.
pub const scope = @import("codegen/scope.zig");
pub const sql_sqlite = @import("sql/sqlite.zig");
pub const sql_postgres = @import("sql/postgres.zig");
pub const sql_mysql = @import("sql/mysql.zig");
/// Schema migration: introspection, drift, DDL planning and execution. Lives at
/// the top of the tree rather than under `sql/` because it *consumes* the
/// generated type graph (`codegen/graph.zig`) — keeping it below `sql` made the
/// SQL layer depend on the code generation layer, which is the wrong way round.
/// `zent.sql_schema` is the name this had before the move and keeps working.
pub const migrate = @import("migrate.zig");
pub const sql_schema = migrate;
pub const sql_pool = @import("sql/pool.zig");
pub const sql_explain = @import("sql/explain.zig");
/// Validate a raw statement without running it: `checkStatement` prepares it
/// with the driver and discards it. See `sql/statement.zig` for what each
/// dialect can and cannot see at that stage.
pub const sql_statement = @import("sql/statement.zig");
pub const sql_logger = @import("sql/logger.zig");
/// Wall-clock readings: `nowSecs` / `nowMilli` / `nowMicros` / `nowNanos`.
/// Zig 0.17 removed the wall-clock readers from `std.time`, and the library's
/// three private ones (driver REALTIME fallback, `outbox.nowMs`,
/// `pool.unixTimestamp`) now delegate here. **Wall clock**, so it can be
/// stepped or rolled back — measure durations with the monotonic
/// `sql_logger.nowUs()` / `sql_driver.monotonicNs()` instead. `zent.walltime`.
pub const walltime = @import("sql/walltime.zig");
pub const sql_diagnostics = @import("sql/diagnostics.zig");

pub const core = struct {
    pub const field = @import("core/field.zig");
    pub const edge = @import("core/edge.zig");
    pub const index = @import("core/index.zig");
    pub const schema = @import("core/schema.zig");
    pub const mixin = @import("core/mixin.zig");
    pub const id = @import("core/id.zig");
};

pub const codegen = struct {
    pub const graph = @import("codegen/graph.zig");
    pub const entity = @import("codegen/entity.zig").Entity;
    pub const deinitEntity = @import("codegen/entity.zig").deinitEntity;
    pub const ManagedEntity = @import("codegen/entity.zig").ManagedEntity;
    pub const managedEntity = @import("codegen/entity.zig").managedEntity;
    pub const dupeEntityTo = @import("codegen/entity.zig").dupeEntityTo;
    /// The `deinitEntity`-compatible copy of a scanned row: strings and slices
    /// re-homed to `allocator`, JSON to the copy's own arena. The generated
    /// `client.<entity>.ownedCopy(allocator, &row)` wraps it.
    pub const ownedCopy = @import("codegen/entity.zig").ownedCopy;
    pub const toMaskedJson = @import("codegen/entity.zig").toMaskedJson;
    pub const meta = @import("codegen/meta.zig").Meta;
    pub const predicate = @import("codegen/predicate.zig");
    pub const create = @import("codegen/create.zig").CreateBuilder;
    pub const query = @import("codegen/query.zig").QueryBuilder;
    pub const WithEdgeOpts = @import("codegen/query.zig").WithEdgeOpts;
    pub const EdgeJoinKind = @import("codegen/query.zig").EdgeJoinKind;
    pub const EdgeLimitMode = @import("codegen/query.zig").EdgeLimitMode;
    pub const update_delete = @import("codegen/update_delete.zig");
    pub const client = @import("codegen/client.zig");
    pub const beginTx = @import("codegen/client.zig").beginTx;
    pub const beginTxCtx = @import("codegen/client.zig").beginTxCtx;
    pub const beginTxFromDriver = @import("codegen/client.zig").beginTxFromDriver;
    pub const beginTxFromDriverCtx = @import("codegen/client.zig").beginTxFromDriverCtx;
};

/// The application services built on the generated client — the layer a
/// consumer wires up rather than generates. Grouped here (and aliased flat
/// below, so `zent.crud` keeps working) because "is this part of the API I
/// should build on?" is the first question a reader has, and a flat list of 30
/// exports cannot answer it.
pub const services = struct {
    /// Row-at-a-time CRUD over a client, with the ownership contract spelled out.
    pub const crud = @import("services/crud.zig");
    /// Delete/update/query helpers that also exist as `client.<entity>.*`.
    pub const crud_helpers = @import("services/crud_helpers.zig");
    /// Transactional outbox: write-then-publish with a claim/complete cycle.
    pub const outbox = @import("services/outbox.zig");
    /// Shard routing: a router over N clients, and a sharded client set.
    pub const shard = @import("services/shard.zig");
    /// Environment assemblers: single-store, pooled, sharded, test.
    pub const helpers = @import("services/helpers.zig");
};

pub const crud = services.crud;
pub const crud_helpers = services.crud_helpers;
pub const outbox = services.outbox;
pub const shard = services.shard;
pub const helpers = services.helpers;

/// The shared vocabulary below every layer: no module in here imports another
/// package, so it is safe for `core`, `codegen`, `sql` and the services to use
/// it without creating a dependency edge (see `docs/ARCHITECTURE.md`).
pub const base = struct {
    /// SQL parameter values (`Value`) and edge filters (`Filter`).
    pub const value = @import("base/value.zig");
    /// The dialect identity (`sqlite3` / `postgres` / `mysql`), its `kind()`
    /// switch, and the two render helpers (`placeholder`, `quoteIdent`).
    pub const dialect = @import("base/dialect.zig");
    /// Where this library's own diagnostics go.
    pub const log = @import("base/log.zig");
    /// The `comptime` branch budget schema-shaped helpers evaluate under.
    pub const budget = @import("base/budget.zig");
};

pub const runtime = struct {
    pub const hook = @import("runtime/hook.zig");
    pub const intercept = @import("runtime/intercept.zig");
    pub const err = @import("runtime/error.zig");
    pub const privacy = @import("runtime/privacy.zig");
    /// Where this library's own diagnostics go: `std.log` by default, an
    /// installable sink otherwise (`zent.runtime.log.setSink`). Same module as
    /// `zent.base.log`; the path is kept for consumers that already use it.
    pub const log = @import("base/log.zig");
};

pub const graph = struct {
    pub const step = @import("./base/step.zig");
    pub const neighbors = @import("graph/neighbors.zig");
    pub const mermaid = @import("graph/mermaid.zig");
    pub const doc_exporter = @import("graph/doc_exporter.zig");
};

pub const privacy = @import("privacy/policy.zig");
pub const data_scope = @import("privacy/data_scope.zig");

pub const entql = @import("entql/parser.zig");

// Force analysis of sub-file test blocks so `zig build test` reflects real state.
test {
    // sql_postgres / sql_mysql are excluded from automatic collection: their
    // C bindings (pg_c / mysql_c) are only wired when libpq / libmariadb
    // headers are discovered, so force-analyzing them would break
    // `zig build test` on machines without those headers. They are
    // re-collected below when available (and covered by tests/integration).
    const db_drivers = comptime [_][]const u8{ "sql_postgres", "sql_mysql" };
    const info = @typeInfo(@This()).@"struct";
    inline for (info.decl_names) |name| {
        if (comptime std.mem.eql(u8, name, "std")) continue;
        const skipped = comptime blk: {
            for (db_drivers) |d| {
                if (std.mem.eql(u8, d, name)) break :blk true;
            }
            break :blk false;
        };
        if (comptime skipped) continue;
        const nested = @field(@This(), name);
        if (@typeInfo(@TypeOf(nested)) == .@"struct") {
            std.testing.refAllDecls(nested);
        }
    }
    // DB-specific driver tests only when the C bindings are available.
    const build_options = @import("build_options");
    if (comptime build_options.have_pg) _ = @import("sql/postgres.zig");
    if (comptime build_options.have_mysql) _ = @import("sql/mysql.zig");
    // Regression tests for generated query helpers live in a dedicated file
    // because the modules above expose generated types rather than namespaces.
    _ = @import("codegen/query_aggregate_test.zig");
    _ = @import("test/allocation_failures.zig");
    _ = @import("test/allocation_failures_read.zig");
    _ = @import("test/allocation_failures_plan.zig");
    // `refAllDecls` above reaches one level, so a test inside a *nested*
    // namespace (`runtime.log`) is only run when its file is imported here.
    _ = @import("base/log.zig");
}
