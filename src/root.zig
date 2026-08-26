const std = @import("std");

pub const sql = @import("sql/builder.zig");
pub const sql_cache = @import("sql/cache.zig");
pub const sql_dialect = @import("sql/dialect.zig");
pub const sql_driver = @import("sql/driver.zig");
pub const sql_scan = @import("sql/scan.zig");
pub const sql_sqlite = @import("sql/sqlite.zig");
pub const sql_postgres = @import("sql/postgres.zig");
pub const sql_mysql = @import("sql/mysql.zig");
pub const sql_schema = @import("sql/schema/migrate.zig");
pub const sql_pool = @import("sql/pool.zig");
pub const sql_explain = @import("sql/explain.zig");
pub const sql_logger = @import("sql/logger.zig");
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
    pub const toMaskedJson = @import("codegen/entity.zig").toMaskedJson;
    pub const meta = @import("codegen/meta.zig").Meta;
    pub const predicate = @import("codegen/predicate.zig");
    pub const create = @import("codegen/create.zig").CreateBuilder;
    pub const query = @import("codegen/query.zig").QueryBuilder;
    pub const update_delete = @import("codegen/update_delete.zig");
    pub const client = @import("codegen/client.zig");
    pub const beginTx = @import("codegen/client.zig").beginTx;
    pub const beginTxFromDriver = @import("codegen/client.zig").beginTxFromDriver;
};

pub const crud = @import("crud.zig");
pub const crud_helpers = @import("crud_helpers.zig");
pub const outbox = @import("outbox.zig");
pub const shard = @import("shard.zig");
pub const helpers = @import("helpers.zig");

pub const runtime = struct {
    pub const hook = @import("runtime/hook.zig");
    pub const err = @import("runtime/error.zig");
    pub const privacy = @import("runtime/privacy.zig");
};

pub const graph = struct {
    pub const step = @import("graph/step.zig");
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
}
