pub const sql = @import("sql/builder.zig");
pub const sql_dialect = @import("sql/dialect.zig");
pub const sql_driver = @import("sql/driver.zig");
pub const sql_scan = @import("sql/scan.zig");
pub const sql_sqlite = @import("sql/sqlite.zig");
pub const sql_schema = @import("sql/schema/migrate.zig");

pub const core = struct {
    pub const field = @import("core/field.zig");
    pub const edge = @import("core/edge.zig");
    pub const index = @import("core/index.zig");
    pub const schema = @import("core/schema.zig");
};

pub const codegen = struct {
    pub const graph = @import("codegen/graph.zig");
    pub const entity = @import("codegen/entity.zig").Entity;
    pub const meta = @import("codegen/meta.zig").Meta;
    pub const predicate = @import("codegen/predicate.zig");
    pub const create = @import("codegen/create.zig").CreateBuilder;
    pub const query = @import("codegen/query.zig").QueryBuilder;
    pub const update_delete = @import("codegen/update_delete.zig");
    pub const client = @import("codegen/client.zig");
};
