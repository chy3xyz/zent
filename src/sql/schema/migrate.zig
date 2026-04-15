const std = @import("std");
const TypeInfo = @import("../../codegen/graph.zig").TypeInfo;
const FieldInfo = @import("../../codegen/graph.zig").FieldInfo;
const EdgeInfo = @import("../../codegen/graph.zig").EdgeInfo;
const Dialect = @import("../dialect.zig").Dialect;
const sql_driver = @import("../driver.zig");

/// Column definition for CREATE TABLE.
pub const ColumnDef = struct {
    name: []const u8,
    sql_type: []const u8,
    primary_key: bool = false,
    not_null: bool = false,
    unique: bool = false,
    default_value: ?[]const u8 = null,
    auto_increment: bool = false,
};

/// Foreign key definition.
pub const ForeignKeyDef = struct {
    columns: []const []const u8,
    ref_table: []const u8,
    ref_columns: []const []const u8,
    on_delete: []const u8 = "CASCADE",
    on_update: []const u8 = "CASCADE",
};

/// Index definition.
pub const IndexDef = struct {
    name: []const u8,
    columns: []const []const u8,
    unique: bool = false,
};

/// Table definition for CREATE TABLE.
pub const TableDef = struct {
    name: []const u8,
    columns: []const ColumnDef,
    primary_keys: []const []const u8,
    foreign_keys: []const ForeignKeyDef = &.{},
    indexes: []const IndexDef = &.{},
};

/// Generate a TableDef from a TypeInfo at comptime.
pub fn tableFromTypeInfo(comptime info: TypeInfo) TableDef {
    comptime {
        var columns: []const ColumnDef = &.{};

        // Generate columns from fields
        for (info.fields) |f| {
            const col = ColumnDef{
                .name = f.name,
                .sql_type = f.sql_type,
                .primary_key = f.is_id,
                .not_null = !f.optional and !f.nillable,
                .unique = f.unique,
                .default_value = defaultValueStr(f),
                .auto_increment = f.is_id,
            };
            columns = columns ++ &[_]ColumnDef{col};
        }

        // Generate foreign keys from O2O and O2M edges (stored in target table)
        // For O2M edges where this entity is the "one" side, the foreign key
        // is in the target table, so we don't add it here.
        // For O2O edges and From edges, we might add a column.
        // For M2M edges, we need a junction table.
        var foreign_keys: []const ForeignKeyDef = &.{};

        for (info.edges) |e| {
            if (e.kind == .from and (e.relation == .o2m or e.relation == .m2o)) {
                // O2M/M2O From edge: this entity has a foreign key column
                // e.g., Car.owner -> User (owner_id column in car table)
                // Column name is edge_name + "_id"
                const fk_col_name = e.name ++ "_id";
                const col = ColumnDef{
                    .name = fk_col_name,
                    .sql_type = "INTEGER",
                    .not_null = !e.required,
                    .unique = e.unique,
                };
                columns = columns ++ &[_]ColumnDef{col};

                const fk = ForeignKeyDef{
                    .columns = &[_][]const u8{fk_col_name},
                    .ref_table = toSnakeCase(e.target_name),
                    .ref_columns = &[_][]const u8{"id"},
                };
                foreign_keys = foreign_keys ++ &[_]ForeignKeyDef{fk};
            } else if (e.kind == .from and e.relation == .o2o) {
                // O2O From edge: foreign key column
                const fk_col_name = e.name ++ "_id";
                const col = ColumnDef{
                    .name = fk_col_name,
                    .sql_type = "INTEGER",
                    .not_null = !e.required,
                    .unique = true, // O2O FK is always unique
                };
                columns = columns ++ &[_]ColumnDef{col};

                const fk = ForeignKeyDef{
                    .columns = &[_][]const u8{fk_col_name},
                    .ref_table = toSnakeCase(e.target_name),
                    .ref_columns = &[_][]const u8{"id"},
                };
                foreign_keys = foreign_keys ++ &[_]ForeignKeyDef{fk};
            }
        }

        // Primary keys
        var pks: []const []const u8 = &.{};
        for (info.fields) |f| {
            if (f.is_id) {
                pks = pks ++ &[_][]const u8{f.name};
            }
        }

        return TableDef{
            .name = info.table_name,
            .columns = columns,
            .primary_keys = pks,
            .foreign_keys = foreign_keys,
        };
    }
}

/// Generate a junction table definition for M2M edges.
pub fn junctionTableForEdge(comptime edge: EdgeInfo, comptime source_info: TypeInfo) TableDef {
    comptime {
        const source_table = source_info.table_name;
        const target_table = toSnakeCase(edge.target_name);

        // Junction table name: alphabetically sorted
        const table_name = if (std.mem.lessThan(u8, source_table, target_table))
            source_table ++ "_" ++ target_table
        else
            target_table ++ "_" ++ source_table;

        const source_col = source_table ++ "_id";
        const target_col = target_table ++ "_id";

        return TableDef{
            .name = table_name,
            .columns = &.{
                ColumnDef{ .name = source_col, .sql_type = "INTEGER", .not_null = true },
                ColumnDef{ .name = target_col, .sql_type = "INTEGER", .not_null = true },
            },
            .primary_keys = &.{ source_col, target_col },
            .foreign_keys = &.{
                ForeignKeyDef{
                    .columns = &[_][]const u8{source_col},
                    .ref_table = source_table,
                    .ref_columns = &[_][]const u8{"id"},
                },
                ForeignKeyDef{
                    .columns = &[_][]const u8{target_col},
                    .ref_table = target_table,
                    .ref_columns = &[_][]const u8{"id"},
                },
            },
        };
    }
}

/// Generate CREATE TABLE SQL for a TableDef.
pub fn createTableSQL(table: TableDef, dialect: Dialect) ![]const u8 {
    var buf = std.array_list.Managed(u8).initCapacity(std.heap.page_allocator, 256) catch unreachable;
    defer buf.deinit();

    const writer = buf.writer();

    try writer.writeAll("CREATE TABLE IF NOT EXISTS ");
    try quoteIdent(dialect, writer, table.name);
    try writer.writeAll(" (\n");

    for (table.columns, 0..) |col, i| {
        if (i > 0) try writer.writeAll(",\n");
        try writer.writeAll("  ");
        try quoteIdent(dialect, writer, col.name);
        try writer.writeAll(" ");
        try writer.writeAll(col.sql_type);

        if (col.primary_key and isSQLiteDialect(dialect)) {
            try writer.writeAll(" PRIMARY KEY AUTOINCREMENT");
        } else if (col.primary_key) {
            try writer.writeAll(" PRIMARY KEY");
        }

        if (col.not_null and !col.primary_key) {
            try writer.writeAll(" NOT NULL");
        }

        if (col.unique and !col.primary_key) {
            try writer.writeAll(" UNIQUE");
        }

        if (col.default_value) |dv| {
            try writer.writeAll(" DEFAULT ");
            try writer.writeAll(dv);
        }
    }

    // Add composite primary key constraint (for multi-column PKs)
    if (table.primary_keys.len > 1) {
        try writer.writeAll(",\n  PRIMARY KEY (");
        for (table.primary_keys, 0..) |pk, i| {
            if (i > 0) try writer.writeAll(", ");
            try quoteIdent(dialect, writer, pk);
        }
        try writer.writeAll(")");
    }

    // Add foreign key constraints
    for (table.foreign_keys) |fk| {
        try writer.writeAll(",\n  FOREIGN KEY (");
        for (fk.columns, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try quoteIdent(dialect, writer, col);
        }
        try writer.writeAll(") REFERENCES ");
        try quoteIdent(dialect, writer, fk.ref_table);
        try writer.writeAll(" (");
        for (fk.ref_columns, 0..) |col, i| {
            if (i > 0) try writer.writeAll(", ");
            try quoteIdent(dialect, writer, col);
        }
        try writer.writeAll(") ON DELETE ");
        try writer.writeAll(fk.on_delete);
        try writer.writeAll(" ON UPDATE ");
        try writer.writeAll(fk.on_update);
    }

    try writer.writeAll("\n)");

    return std.heap.page_allocator.dupe(u8, buf.items);
}

/// Generate CREATE INDEX SQL for an IndexDef.
pub fn createIndexSQL(index: IndexDef, table_name: []const u8, dialect: Dialect) ![]const u8 {
    var buf = std.array_list.Managed(u8).initCapacity(std.heap.page_allocator, 256) catch unreachable;
    defer buf.deinit();

    const writer = buf.writer();

    try writer.writeAll("CREATE ");
    if (index.unique) try writer.writeAll("UNIQUE ");
    try writer.writeAll("INDEX ");
    try quoteIdent(dialect, writer, index.name);
    try writer.writeAll(" ON ");
    try quoteIdent(dialect, writer, table_name);
    try writer.writeAll(" (");

    for (index.columns, 0..) |col, i| {
        if (i > 0) try writer.writeAll(", ");
        try quoteIdent(dialect, writer, col);
    }
    try writer.writeAll(")");

    return std.heap.page_allocator.dupe(u8, buf.items);
}

/// Create all tables for a set of TypeInfos (create-only migration).
/// This creates tables in dependency order and also creates junction tables for M2M edges.
/// For O2M/M2O To edges, it adds the FK column to the source entity's table.
pub fn createAllTables(driver: sql_driver.Driver, comptime infos: []const TypeInfo) !void {
    const dialect = driver.dialect();

    // Create main entity tables
    // For each entity, also check if any OTHER entity has a From edge pointing here,
    // which means we need to add FK columns to that other entity's table.
    // We handle this by building the table definition with FK columns from both
    // own From edges AND from cross-referenced To edges.
    inline for (infos) |info| {
        const table = comptime tableFromTypeInfoCrossRef(info, infos);
        const sql = try createTableSQL(table, dialect);
        defer std.heap.page_allocator.free(sql);
        _ = try driver.exec(sql, &.{});
    }

    // Create junction tables for M2M edges (both To and From sides).
    // CREATE TABLE IF NOT EXISTS handles duplicates when both sides declare M2M.
    inline for (infos) |info| {
        inline for (info.edges) |e| {
            if (e.relation == .m2m) {
                const jtable = comptime junctionTableForEdge(e, info);
                const sql = try createTableSQL(jtable, dialect);
                defer std.heap.page_allocator.free(sql);
                _ = try driver.exec(sql, &.{});
            }
        }
    }

    // Create indexes
    inline for (infos) |info| {
        inline for (info.indexes) |idx| {
            const idx_def = IndexDef{
                .name = idx.name,
                .columns = idx.columns,
                .unique = idx.unique,
            };
            const sql = try createIndexSQL(idx_def, info.table_name, dialect);
            defer std.heap.page_allocator.free(sql);
            _ = try driver.exec(sql, &.{});
        }
    }
}

/// Like tableFromTypeInfo, but also adds FK columns from cross-referenced To edges.
/// For example, if User has a To("cars", Car) O2M edge, this adds a "user_id" FK column
/// to the Car table pointing back to User.
fn tableFromTypeInfoCrossRef(comptime info: TypeInfo, comptime all_infos: []const TypeInfo) TableDef {
    comptime {
        var columns: []const ColumnDef = &.{};
        var foreign_keys: []const ForeignKeyDef = &.{};

        // Generate columns from fields
        for (info.fields) |f| {
            const col = ColumnDef{
                .name = f.name,
                .sql_type = f.sql_type,
                .primary_key = f.is_id,
                .not_null = !f.optional and !f.nillable,
                .unique = f.unique,
                .default_value = defaultValueStr(f),
                .auto_increment = f.is_id,
            };
            columns = columns ++ &[_]ColumnDef{col};
        }

        // Own From edges generate FK columns in this table
        for (info.edges) |e| {
            if (e.kind == .from and (e.relation == .m2o or e.relation == .o2o)) {
                const fk_col_name = e.name ++ "_id";
                const col = ColumnDef{
                    .name = fk_col_name,
                    .sql_type = "INTEGER",
                    .not_null = !e.required,
                    .unique = e.unique,
                };
                columns = columns ++ &[_]ColumnDef{col};

                const fk = ForeignKeyDef{
                    .columns = &[_][]const u8{fk_col_name},
                    .ref_table = toSnakeCase(e.target_name),
                    .ref_columns = &[_][]const u8{"id"},
                };
                foreign_keys = foreign_keys ++ &[_]ForeignKeyDef{fk};
            }
        }

        // Cross-referenced To edges: if another entity has a To edge pointing here
        // with O2M relation, add the FK column to THIS table.
        // For example: User has To("cars", Car) → Car gets "user_id" FK column.
        // If this entity already has a corresponding From edge, the FK is handled
        // by that From edge (e.g., Car.From("owner", User).Ref("cars")) and we
        // skip adding a duplicate column.
        for (all_infos) |other_info| {
            for (other_info.edges) |e| {
                // Find To edges from other entities pointing to this entity
                if (e.kind == .to and std.mem.eql(u8, e.target_name, info.name)) {
                    // Check if this entity already has a corresponding From edge.
                    var has_from_inverse = false;
                    for (info.edges) |my_edge| {
                        if (my_edge.kind == .from and
                            std.mem.eql(u8, my_edge.target_name, other_info.name) and
                            my_edge.ref != null and
                            std.mem.eql(u8, my_edge.ref.?, e.name))
                        {
                            has_from_inverse = true;
                            break;
                        }
                    }
                    if (has_from_inverse) continue;

                    if (e.relation == .o2m) {
                        // O2M: "one User has many Cars" → Car table gets FK column
                        const fk_col_name = toSnakeCase(other_info.name) ++ "_id";
                        // Check if this column already exists
                        var exists = false;
                        for (columns) |c| {
                            if (std.mem.eql(u8, c.name, fk_col_name)) {
                                exists = true;
                                break;
                            }
                        }
                        if (!exists) {
                            const col = ColumnDef{
                                .name = fk_col_name,
                                .sql_type = "INTEGER",
                                .not_null = true,
                                .unique = false,
                            };
                            columns = columns ++ &[_]ColumnDef{col};

                            const fk = ForeignKeyDef{
                                .columns = &[_][]const u8{fk_col_name},
                                .ref_table = other_info.table_name,
                                .ref_columns = &[_][]const u8{"id"},
                            };
                            foreign_keys = foreign_keys ++ &[_]ForeignKeyDef{fk};
                        }
                    }
                }
            }
        }

        // Primary keys
        var pks: []const []const u8 = &.{};
        for (info.fields) |f| {
            if (f.is_id) {
                pks = pks ++ &[_][]const u8{f.name};
            }
        }

        return TableDef{
            .name = info.table_name,
            .columns = columns,
            .primary_keys = pks,
            .foreign_keys = foreign_keys,
        };
    }
}

fn quoteIdent(dialect: Dialect, writer: anytype, name: []const u8) !void {
    if (std.mem.eql(u8, dialect.name, "mysql")) {
        try writer.print("`{s}`", .{name});
    } else {
        try writer.print("\"{s}\"", .{name});
    }
}

fn isSQLiteDialect(dialect: Dialect) bool {
    return std.mem.eql(u8, dialect.name, "sqlite3");
}

fn defaultValueStr(comptime f: FieldInfo) ?[]const u8 {
    return switch (f.default) {
        .none => null,
        .bool => |v| if (v) "TRUE" else "FALSE",
        .int => |v| comptime std.fmt.comptimePrint("{d}", .{v}),
        .float => |v| comptime std.fmt.comptimePrint("{d}", .{v}),
        .string => |v| comptime std.fmt.comptimePrint("'{s}'", .{v}),
    };
}

fn toSnakeCase(name: []const u8) []const u8 {
    comptime {
        var result: []const u8 = "";
        for (name, 0..) |c, i| {
            if (std.ascii.isUpper(c) and i > 0) {
                result = result ++ "_";
            }
            result = result ++ &[_]u8{std.ascii.toLower(c)};
        }
        return result;
    }
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "TableDef from TypeInfo" {
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const table = comptime tableFromTypeInfo(info);

    try std.testing.expectEqualStrings("user", table.name);
    try std.testing.expectEqual(@as(usize, 3), table.columns.len); // id + name + age
    try std.testing.expectEqualStrings("id", table.columns[0].name);
    try std.testing.expect(table.columns[0].primary_key);
    try std.testing.expectEqualStrings("name", table.columns[1].name);
    try std.testing.expectEqualStrings("TEXT", table.columns[1].sql_type);
    try std.testing.expectEqualStrings("age", table.columns[2].name);
    try std.testing.expectEqualStrings("INTEGER", table.columns[2].sql_type);
}

test "Create table SQL" {
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const table = comptime tableFromTypeInfo(info);
    const sql = try createTableSQL(table, Dialect.sqlite);
    defer std.heap.page_allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "CREATE TABLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "PRIMARY KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "AUTOINCREMENT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "name TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "age INTEGER") != null);
}
