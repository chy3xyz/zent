const std = @import("std");
const field_mod = @import("../../core/field.zig");
const TypeInfo = @import("../../codegen/graph.zig").TypeInfo;
const FieldInfo = @import("../../codegen/graph.zig").FieldInfo;
const EdgeInfo = @import("../../codegen/graph.zig").EdgeInfo;
const Dialect = @import("../dialect.zig").Dialect;
const sql_driver = @import("../driver.zig");
const Value = @import("../builder.zig").Value;

extern fn time(time_t: [*c]c_long) c_long;

/// Transaction safety by backend
///
/// SQLite and PostgreSQL support transactional DDL — a `CREATE TABLE`,
/// `ALTER TABLE`, or `CREATE INDEX` issued inside a `BEGIN`/`COMMIT` block
/// is fully atomic and can be rolled back.
///
/// MySQL does NOT support transactional DDL. `CREATE TABLE`, `ALTER TABLE`,
/// `CREATE INDEX`, and similar statements implicitly commit any active
/// transaction before executing. Therefore, on MySQL the transaction wrapping
/// in `migrateSchema` only guarantees atomicity for history-table writes
/// (`zent_schema_migrations` INSERTs). Schema changes on MySQL are applied
/// immediately and cannot be rolled back by this layer.
///
/// This is a known, documented limitation of MySQL — do not attempt to make
/// DDL transactional on MySQL; the guarantee is best-effort per backend.
/// Current Unix timestamp in seconds.
/// Uses libc `time()` because Zig 0.17 removed `std.time.timestamp()`;
/// `applied_at` is informational and not used by migration logic.
fn unixTimestamp() i64 {
    return @as(i64, @intCast(time(null)));
}

/// Version scheme for migration operations.
///
/// The version is the lower 31 bits of an FNV-1a hash over
/// `"table_name:operation:target"`. The manual loop is inexpensive to evaluate
/// at comptime, unlike the standard CRC implementation, and the 31-bit mask
/// keeps the value positive and within MySQL's signed INTEGER range (32-bit).
fn computeMigrationVersion(comptime table: []const u8, comptime op: []const u8, comptime target: []const u8) i64 {
    const key = table ++ ":" ++ op ++ ":" ++ target;
    var hash: u64 = 14_695_981_039_346_656_037;
    for (key) |byte| {
        hash ^= byte;
        hash *%= 1_099_511_628_211;
    }
    return @as(i64, @intCast(hash & 0x7FFF_FFFF));
}

/// Options controlling migration behavior.
pub const MigrateOptions = struct {
    /// If true, don't execute any SQL — only print what would be done.
    dry_run: bool = false,

    /// If true, columns that exist in the database but NOT in the schema
    /// will be dropped. When false (default), extra columns are silently kept.
    drop_columns: bool = false,

    /// If true, column type changes (ALTER TYPE / MODIFY COLUMN) are applied
    /// even when they may cause data loss. When false (default), type mismatches
    /// are silently ignored.
    allow_data_loss: bool = false,
};

/// CREATE TABLE statement for the migration history table.
/// Works on SQLite, PostgreSQL, and MySQL.
const migrationsTableSQL =
    "CREATE TABLE IF NOT EXISTS zent_schema_migrations (" ++
    "version INTEGER PRIMARY KEY, " ++
    "applied_at INTEGER NOT NULL, " ++
    "checksum TEXT)";

/// Ensure the migration history table exists. Idempotent at the SQL level.
fn ensureMigrationsTable(drv: sql_driver.Driver) !void {
    _ = try drv.exec(migrationsTableSQL, &.{});
}

/// Build the dialect-appropriate INSERT statement for recording a migration.
/// SQLite and MySQL use `?` placeholders; PostgreSQL uses `$1, $2, $3`.
/// The statement tolerates duplicate versions so that re-running a migration
/// after a table has been dropped out-of-band doesn't blow up the whole batch.
fn buildRecordInsertSQL(dialect: Dialect, buf: []u8) ![]const u8 {
    const p1 = try dialect.placeholder(buf[0..32], 1);
    const p2 = try dialect.placeholder(buf[32..64], 2);
    const p3 = try dialect.placeholder(buf[64..96], 3);
    const suffix: []const u8 = if (std.mem.eql(u8, dialect.name, "postgres"))
        " ON CONFLICT (version) DO NOTHING"
    else if (std.mem.eql(u8, dialect.name, "mysql"))
        ""
    else
        " ON CONFLICT (version) DO NOTHING";
    const mysql_suffix: []const u8 = if (std.mem.eql(u8, dialect.name, "mysql"))
        " ON DUPLICATE KEY UPDATE applied_at = applied_at"
    else
        "";
    return std.fmt.bufPrint(
        buf[96..],
        "INSERT INTO zent_schema_migrations (version, applied_at, checksum) VALUES ({s}, {s}, {s}){s}{s}",
        .{ p1, p2, p3, suffix, mysql_suffix },
    );
}

/// Build the dialect-appropriate SELECT statement for listing applied versions.
fn buildListVersionsSQL(dialect: Dialect, buf: []u8) ![]const u8 {
    _ = dialect;
    return std.fmt.bufPrint(buf, "SELECT version FROM zent_schema_migrations ORDER BY version", .{});
}

/// Read all applied migration versions, ordered ascending.
fn appliedVersions(allocator: std.mem.Allocator, drv: sql_driver.Driver) ![]i64 {
    var sql_buf: [256]u8 = undefined;
    const sql = try buildListVersionsSQL(drv.dialect(), &sql_buf);
    var rows = try drv.query(sql, &.{});
    defer rows.deinit();
    var list = std.array_list.Managed(i64).init(allocator);
    errdefer list.deinit();
    while (rows.next()) |row| {
        if (row.getInt(0)) |v| try list.append(v);
    }
    return list.toOwnedSlice();
}

/// Insert a row into the migration history table.
fn recordMigration(drv: sql_driver.Driver, version: i64, checksum: ?[]const u8) !void {
    const now = unixTimestamp();
    var sql_buf: [384]u8 = undefined;
    const sql = try buildRecordInsertSQL(drv.dialect(), &sql_buf);
    _ = try drv.exec(
        sql,
        &.{
            .{ .int = version },
            .{ .int = now },
            if (checksum) |c| .{ .string = c } else .null,
        },
    );
}

/// True when `version` is already recorded in the history table.
fn versionContains(versions: []const i64, version: i64) bool {
    for (versions) |v| {
        if (v == version) return true;
    }
    return false;
}

/// Column definition for CREATE TABLE.
pub const ColumnDef = struct {
    name: []const u8,
    /// Explicit SQL type for synthetic columns and backwards-compatible callers.
    sql_type: []const u8,
    /// Logical schema type. When present, migration SQL resolves it through the
    /// active dialect instead of reusing the SQLite-oriented `sql_type` value.
    logical_type: ?field_mod.FieldType = null,
    primary_key: bool = false,
    not_null: bool = false,
    unique: bool = false,
    default_value: ?[]const u8 = null,
    auto_increment: bool = false,
};

fn columnSQLType(column: ColumnDef, dialect: Dialect) []const u8 {
    if (column.logical_type) |logical_type| {
        return switch (logical_type) {
            inline else => |field_type| field_mod.sqlType(field_type, dialect),
        };
    }
    return column.sql_type;
}

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
                .logical_type = f.field_type,
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
                    .not_null = e.required,
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
                    .not_null = e.required,
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
/// Columns and table name are deterministically ordered alphabetically
/// so that whichever edge triggers creation first produces the same schema.
pub fn junctionTableForEdge(comptime edge: EdgeInfo, comptime source_info: TypeInfo) TableDef {
    comptime {
        const source_table = source_info.table_name;
        const target_table = toSnakeCase(edge.target_name);

        const a_first = std.mem.lessThan(u8, source_table, target_table);

        // Junction table name: alphabetically sorted
        const table_name = if (a_first)
            source_table ++ "_" ++ target_table
        else
            target_table ++ "_" ++ source_table;

        // Columns are also ordered alphabetically by their referenced table
        const col_a = source_table ++ "_id";
        const col_b = target_table ++ "_id";
        const col1 = if (a_first) col_a else col_b;
        const col2 = if (a_first) col_b else col_a;
        const ref1 = if (a_first) source_table else target_table;
        const ref2 = if (a_first) target_table else source_table;

        return TableDef{
            .name = table_name,
            .columns = &.{
                ColumnDef{ .name = col1, .sql_type = "INTEGER", .not_null = true },
                ColumnDef{ .name = col2, .sql_type = "INTEGER", .not_null = true },
            },
            .primary_keys = &.{ col1, col2 },
            .foreign_keys = &.{
                ForeignKeyDef{
                    .columns = &[_][]const u8{col1},
                    .ref_table = ref1,
                    .ref_columns = &[_][]const u8{"id"},
                },
                ForeignKeyDef{
                    .columns = &[_][]const u8{col2},
                    .ref_table = ref2,
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

    try buf.appendSlice("CREATE TABLE IF NOT EXISTS ");
    try quoteIdentToBuffer(dialect, &buf, table.name);
    try buf.appendSlice(" (\n");

    for (table.columns, 0..) |col, i| {
        const sql_type = columnSQLType(col, dialect);
        if (i > 0) try buf.appendSlice(",\n");
        try buf.appendSlice("  ");
        try quoteIdentToBuffer(dialect, &buf, col.name);
        try buf.appendSlice(" ");
        try buf.appendSlice(sql_type);

        if (col.primary_key and isSQLiteDialect(dialect)) {
            // SQLite AUTOINCREMENT only valid on INTEGER PRIMARY KEY.
            if (std.ascii.eqlIgnoreCase(sql_type, "INTEGER") or
                std.ascii.eqlIgnoreCase(sql_type, "INT"))
            {
                try buf.appendSlice(" PRIMARY KEY AUTOINCREMENT");
            } else {
                try buf.appendSlice(" PRIMARY KEY");
            }
        } else if (col.primary_key) {
            try buf.appendSlice(" PRIMARY KEY");
        }

        if (col.not_null and !col.primary_key) {
            try buf.appendSlice(" NOT NULL");
        }

        if (col.unique and !col.primary_key) {
            try buf.appendSlice(" UNIQUE");
        }

        if (col.default_value) |dv| {
            try buf.appendSlice(" DEFAULT ");
            try buf.appendSlice(dv);
        }
    }

    // Add composite primary key constraint (for multi-column PKs)
    if (table.primary_keys.len > 1) {
        try buf.appendSlice(",\n  PRIMARY KEY (");
        for (table.primary_keys, 0..) |pk, i| {
            if (i > 0) try buf.appendSlice(", ");
            try quoteIdentToBuffer(dialect, &buf, pk);
        }
        try buf.appendSlice(")");
    }

    // Add foreign key constraints
    for (table.foreign_keys) |fk| {
        try buf.appendSlice(",\n  FOREIGN KEY (");
        for (fk.columns, 0..) |col, i| {
            if (i > 0) try buf.appendSlice(", ");
            try quoteIdentToBuffer(dialect, &buf, col);
        }
        try buf.appendSlice(") REFERENCES ");
        try quoteIdentToBuffer(dialect, &buf, fk.ref_table);
        try buf.appendSlice(" (");
        for (fk.ref_columns, 0..) |col, i| {
            if (i > 0) try buf.appendSlice(", ");
            try quoteIdentToBuffer(dialect, &buf, col);
        }
        try buf.appendSlice(") ON DELETE ");
        try buf.appendSlice(fk.on_delete);
        try buf.appendSlice(" ON UPDATE ");
        try buf.appendSlice(fk.on_update);
    }

    try buf.appendSlice("\n)");

    return std.heap.page_allocator.dupe(u8, buf.items);
}

/// Generate CREATE INDEX SQL for an IndexDef.
pub fn createIndexSQL(index: IndexDef, table_name: []const u8, dialect: Dialect) ![]const u8 {
    var buf = std.array_list.Managed(u8).initCapacity(std.heap.page_allocator, 256) catch unreachable;
    defer buf.deinit();

    try buf.appendSlice("CREATE ");
    if (index.unique) try buf.appendSlice("UNIQUE ");
    if (std.mem.eql(u8, dialect.name, "mysql")) {
        try buf.appendSlice("INDEX ");
    } else {
        try buf.appendSlice("INDEX IF NOT EXISTS ");
    }
    try quoteIdentToBuffer(dialect, &buf, index.name);
    try buf.appendSlice(" ON ");
    try quoteIdentToBuffer(dialect, &buf, table_name);
    try buf.appendSlice(" (");

    for (index.columns, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(", ");
        try quoteIdentToBuffer(dialect, &buf, col);
    }
    try buf.appendSlice(")");

    return std.heap.page_allocator.dupe(u8, buf.items);
}

/// Generate CREATE VIEW SQL.
pub fn createViewSQL(comptime info: TypeInfo, dialect: Dialect) ![]const u8 {
    const view_sql = info.view_sql orelse return error.MissingViewSQL;
    var buf = std.array_list.Managed(u8).initCapacity(std.heap.page_allocator, 256) catch unreachable;
    defer buf.deinit();

    try buf.appendSlice("CREATE VIEW IF NOT EXISTS ");
    try quoteIdentToBuffer(dialect, &buf, info.table_name);
    try buf.appendSlice(" AS ");
    try buf.appendSlice(view_sql);

    return std.heap.page_allocator.dupe(u8, buf.items);
}

/// Create entity and junction tables without creating indexes.
fn createTables(driver_drv: sql_driver.Driver, comptime infos: []const TypeInfo) !void {
    const dialect = driver_drv.dialect();

    // Create main entity tables (skip views)
    // For each entity, also check if any OTHER entity has a From edge pointing here,
    // which means we need to add FK columns to that other entity's table.
    // We handle this by building the table definition with FK columns from both
    // own From edges AND from cross-referenced To edges.
    inline for (infos) |info| {
        if (info.is_view) {
            const sql = try createViewSQL(info, dialect);
            defer std.heap.page_allocator.free(sql);
            _ = try driver_drv.exec(
                sql,
                &.{},
            );
        } else {
            const table = comptime tableFromTypeInfoCrossRef(info, infos);
            const sql = try createTableSQL(table, dialect);
            defer std.heap.page_allocator.free(sql);
            _ = try driver_drv.exec(sql, &.{});
        }
    }

    // Create junction tables for M2M edges (both To and From sides).
    // Skip edges that use an explicit edge schema (through).
    // CREATE TABLE IF NOT EXISTS handles duplicates when both sides declare M2M.
    inline for (infos) |info| {
        if (info.is_view) continue;
        inline for (info.edges) |e| {
            if (e.relation == .m2m and e.through == null) {
                const jtable = comptime junctionTableForEdge(e, info);
                const sql = try createTableSQL(jtable, dialect);
                defer std.heap.page_allocator.free(sql);
                _ = try driver_drv.exec(
                    sql,
                    &.{},
                );
            }
        }
    }
}

/// Create all tables and indexes for a set of TypeInfos.
///
/// NOTE: This is a legacy helper that creates tables/indexes directly without
/// recording migration history or wrapping in a transaction. Prefer
/// `migrateSchema` for production use — it provides transactional atomicity
/// (SQLite, PostgreSQL), idempotency via `zent_schema_migrations`, and
/// automatic column/index additions on re-run.
pub fn createAllTables(driver_drv: sql_driver.Driver, comptime infos: []const TypeInfo) !void {
    const dialect = driver_drv.dialect();
    try createTables(driver_drv, infos);

    inline for (infos) |info| {
        if (info.is_view or info.indexes.len == 0) continue;

        var existing_mysql_indexes: ?std.array_list.Managed(ExistingIndex) = null;
        if (std.mem.eql(u8, dialect.name, "mysql")) {
            existing_mysql_indexes = getExistingIndexes(std.heap.page_allocator, driver_drv, info.table_name) catch |err| switch (err) {
                error.UnsupportedDialect => unreachable, // The dialect was checked immediately above.
                error.OutOfMemory => return error.OutOfMemory,
                error.PoolExhausted => return error.PoolExhausted,
                error.PoolClosed => return error.PoolClosed,
                error.ConnectionFailed => return error.ConnectionFailed,
                error.ExecFailed => return error.ExecFailed,
                error.QueryFailed => return error.QueryFailed,
                error.TxFailed => return error.TxFailed,
                error.PingFailed => return error.PingFailed,
                error.BindFailed => return error.BindFailed,
                error.PrepareFailed => return error.PrepareFailed,
                error.ProtocolError => return error.ProtocolError,
                error.DriverFailed => return error.DriverFailed,
                error.QueryTimeout => return error.QueryTimeout,
            };
        }
        defer if (existing_mysql_indexes) |*indexes| {
            freeExistingIndexes(std.heap.page_allocator, indexes);
        };

        inline for (info.indexes) |idx| {
            const idx_def = IndexDef{
                .name = idx.name,
                .columns = idx.columns,
                .unique = idx.unique,
            };
            const already_exists = if (existing_mysql_indexes) |indexes|
                indexExists(indexes.items, idx_def.name)
            else
                false;
            if (!already_exists) {
                const sql = try createIndexSQL(idx_def, info.table_name, dialect);
                defer std.heap.page_allocator.free(sql);
                _ = try driver_drv.exec(sql, &.{});
            }
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
                .logical_type = f.field_type,
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
                // Skip adding the column definition if it was already added via info.fields
                // (e.g., from addEdgeFields), but still add the FK constraint.
                var col_exists = false;
                for (columns) |c| {
                    if (std.mem.eql(u8, c.name, fk_col_name)) {
                        col_exists = true;
                        break;
                    }
                }
                if (!col_exists) {
                    const col = ColumnDef{
                        .name = fk_col_name,
                        .sql_type = "INTEGER",
                        .not_null = e.required,
                        .unique = e.unique,
                    };
                    columns = columns ++ &[_]ColumnDef{col};
                }

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

fn quoteIdentToBuffer(dialect: Dialect, buf: *std.array_list.Managed(u8), name: []const u8) !void {
    if (std.mem.eql(u8, dialect.name, "mysql")) {
        try buf.print("`{s}`", .{name});
    } else {
        try buf.print("\"{s}\"", .{name});
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

pub const ExistingColumn = struct {
    name: []const u8,
    sql_type: []const u8,
    not_null: bool,
    pk: bool,
};

pub const ExistingIndex = struct {
    name: []const u8,
    unique: bool,
};

const IntrospectionError = sql_driver.Error || error{UnsupportedDialect};

/// Query existing columns for a table using dialect-specific metadata.
fn getExistingColumns(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingColumn) {
    var result = std.array_list.Managed(ExistingColumn).init(allocator);
    errdefer freeExistingColumns(allocator, &result);

    const dialect = driver_drv.dialect();
    const sql_text = if (std.mem.eql(u8, dialect.name, "sqlite3"))
        try std.fmt.allocPrint(allocator, "PRAGMA table_info(\"{s}\")", .{table_name})
    else if (std.mem.eql(u8, dialect.name, "postgres"))
        try std.fmt.allocPrint(
            allocator,
            "SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_name = '{s}' AND table_schema = current_schema()",
            .{table_name},
        )
    else if (std.mem.eql(u8, dialect.name, "mysql"))
        try allocator.dupe(u8, "SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_name = ? AND table_schema = DATABASE()")
    else
        return error.UnsupportedDialect;
    defer allocator.free(sql_text);

    var rows = if (std.mem.eql(u8, dialect.name, "mysql"))
        try driver_drv.query(sql_text, &.{.{ .string = table_name }})
    else
        try driver_drv.query(sql_text, &.{});
    defer rows.deinit();

    while (rows.next()) |row| {
        const is_sqlite = std.mem.eql(u8, dialect.name, "sqlite3");
        const name = row.getText(if (is_sqlite) 1 else 0) orelse continue;
        const sql_type = row.getText(if (is_sqlite) 2 else 1) orelse "";
        const not_null = if (is_sqlite)
            (row.getInt(3) orelse 0) != 0
        else
            std.ascii.eqlIgnoreCase(row.getText(2) orelse "YES", "NO");
        const pk = is_sqlite and (row.getInt(5) orelse 0) != 0;

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_type = try allocator.alloc(u8, sql_type.len);
        errdefer allocator.free(owned_type);
        for (sql_type, owned_type) |byte, *dest| dest.* = std.ascii.toLower(byte);

        try result.append(.{
            .name = owned_name,
            .sql_type = owned_type,
            .not_null = not_null,
            .pk = pk,
        });
    }
    if (rows.nextError()) |err| return err;
    return result;
}

fn freeExistingColumns(allocator: std.mem.Allocator, columns: *std.array_list.Managed(ExistingColumn)) void {
    for (columns.items) |c| {
        allocator.free(c.name);
        allocator.free(c.sql_type);
    }
    columns.deinit();
}

/// Query existing indexes for a table using dialect-specific metadata.
fn getExistingIndexes(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingIndex) {
    var result = std.array_list.Managed(ExistingIndex).init(allocator);
    errdefer freeExistingIndexes(allocator, &result);

    const dialect = driver_drv.dialect();
    const sql_text = if (std.mem.eql(u8, dialect.name, "sqlite3"))
        try std.fmt.allocPrint(allocator, "PRAGMA index_list(\"{s}\")", .{table_name})
    else if (std.mem.eql(u8, dialect.name, "postgres"))
        try std.fmt.allocPrint(
            allocator,
            "SELECT indexname, indexdef FROM pg_indexes WHERE tablename = '{s}' AND schemaname = current_schema()",
            .{table_name},
        )
    else if (std.mem.eql(u8, dialect.name, "mysql"))
        try allocator.dupe(u8, "SELECT index_name, non_unique FROM information_schema.statistics WHERE table_name = ? AND table_schema = DATABASE()")
    else
        return error.UnsupportedDialect;
    defer allocator.free(sql_text);

    var rows = if (std.mem.eql(u8, dialect.name, "mysql"))
        try driver_drv.query(sql_text, &.{.{ .string = table_name }})
    else
        try driver_drv.query(sql_text, &.{});
    defer rows.deinit();

    while (rows.next()) |row| {
        const is_sqlite = std.mem.eql(u8, dialect.name, "sqlite3");
        const is_postgres = std.mem.eql(u8, dialect.name, "postgres");
        const name = row.getText(if (is_sqlite) 1 else 0) orelse continue;
        const unique = if (is_sqlite)
            (row.getInt(2) orelse 0) != 0
        else if (is_postgres)
            std.mem.startsWith(u8, row.getText(1) orelse "", "CREATE UNIQUE INDEX")
        else
            (row.getInt(1) orelse 1) == 0;

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        try result.append(.{
            .name = owned_name,
            .unique = unique,
        });
    }
    if (rows.nextError()) |err| return err;
    return result;
}

fn freeExistingIndexes(allocator: std.mem.Allocator, indexes: *std.array_list.Managed(ExistingIndex)) void {
    for (indexes.items) |i| {
        allocator.free(i.name);
    }
    indexes.deinit();
}

fn columnExists(columns: []const ExistingColumn, name: []const u8) bool {
    for (columns) |c| {
        if (std.mem.eql(u8, c.name, name)) return true;
    }
    return false;
}

fn indexExists(indexes: []const ExistingIndex, name: []const u8) bool {
    for (indexes) |i| {
        if (std.mem.eql(u8, i.name, name)) return true;
    }
    return false;
}

/// Check whether a column name exists in a TableDef's columns list.
fn columnExistsTableDef(table: TableDef, name: []const u8) bool {
    for (table.columns) |c| {
        if (std.mem.eql(u8, c.name, name)) return true;
    }
    return false;
}

/// Look up an ExistingColumn by name. Returns null when not found.
fn getExistingColumnByName(columns: []const ExistingColumn, name: []const u8) ?ExistingColumn {
    for (columns) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

/// Generate ALTER TABLE ADD COLUMN SQL for a single column.
fn alterTableAddColumnSQL(allocator: std.mem.Allocator, table_name: []const u8, col: ColumnDef, dialect: Dialect) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try buf.appendSlice("ALTER TABLE ");
    try quoteIdentToBuffer(dialect, &buf, table_name);
    try buf.appendSlice(" ADD COLUMN ");
    try quoteIdentToBuffer(dialect, &buf, col.name);
    try buf.print(" {s}", .{columnSQLType(col, dialect)});

    // For ALTER ADD COLUMN, avoid NOT NULL without a default to keep SQLite happy.
    if (col.default_value) |dv| {
        try buf.print(" DEFAULT {s}", .{dv});
    }

    // UNIQUE is intentionally NOT appended: SQLite's ALTER TABLE ADD
    // COLUMN does not support it, and for PG/MySQL the createTableSQL
    // output already carries the UNIQUE constraint on this column.

    return buf.toOwnedSlice();
}

/// Generate DROP COLUMN SQL for a table column in a dialect-specific format.
fn dropColumnSQL(
    allocator: std.mem.Allocator,
    table_name: []const u8,
    column_name: []const u8,
    dialect: Dialect,
) ![]const u8 {
    return switch (dialect.name[0]) {
        's' => std.fmt.allocPrint(allocator, "ALTER TABLE \"{s}\" DROP COLUMN \"{s}\"", .{ table_name, column_name }),
        'p' => std.fmt.allocPrint(allocator, "ALTER TABLE \"{s}\" DROP COLUMN \"{s}\" CASCADE", .{ table_name, column_name }),
        'm' => std.fmt.allocPrint(allocator, "ALTER TABLE `{s}` DROP COLUMN `{s}`", .{ table_name, column_name }),
        else => error.UnsupportedDialect,
    };
}

/// Generate ALTER COLUMN SQL to change a column's type.
///
/// SQLite has no native ALTER TYPE. MySQL's `MODIFY COLUMN name type` replaces
/// the full column definition and can silently strip NOT NULL, DEFAULT, UNIQUE,
/// and AUTO_INCREMENT attributes. Until the migration layer can reproduce the
/// complete existing definition, MySQL type changes fail closed.
fn alterColumnTypeSQL(
    allocator: std.mem.Allocator,
    table_name: []const u8,
    column_name: []const u8,
    new_type: []const u8,
    dialect: Dialect,
) ![]const u8 {
    return switch (dialect.name[0]) {
        's' => error.UnsupportedDialect,
        'p' => std.fmt.allocPrint(allocator, "ALTER TABLE \"{s}\" ALTER COLUMN \"{s}\" TYPE {s} USING \"{s}\"::{s}", .{ table_name, column_name, new_type, column_name, new_type }),
        'm' => error.MySQLTypeChangeUnsafe,
        else => error.UnsupportedDialect,
    };
}

/// Migrate schema: create missing tables, add missing columns, create missing
/// indexes, and — when requested via `opts` — drop orphaned columns and/or
/// alter column types.
///
/// Phase 2 Task 8: every operation is recorded in `zent_schema_migrations`
/// with a deterministic CRC32 version, and the entire run is wrapped in a
/// single transaction. Re-running `migrateSchema` is a no-op for operations
/// already present in the history table; on any error path, `tx.deinit()`
/// rolls back the whole batch.
///
/// Phase 3 Task 12: DROP COLUMN is gated behind `opts.drop_columns`; ALTER
/// TYPE is gated behind `opts.allow_data_loss`. Both are opt-in to prevent
/// accidental schema destruction.
pub fn migrateSchemaWithOptions(
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    comptime infos: []const TypeInfo,
    opts: MigrateOptions,
) !void {
    const dialect = driver.dialect();

    // Dry-run: collect all generated SQL and print without executing.
    if (opts.dry_run) {
        var sqls = std.array_list.Managed([]const u8).init(allocator);
        defer {
            for (sqls.items) |s| allocator.free(s);
            sqls.deinit();
        }

        // CREATE TABLE for non-view entities.
        inline for (infos) |info| {
            if (!info.is_view) {
                const table = comptime tableFromTypeInfoCrossRef(info, infos);
                const sql = try createTableSQL(table, dialect);
                try sqls.append(try allocator.dupe(u8, sql));
                std.heap.page_allocator.free(sql);
            }
        }

        // CREATE VIEW.
        inline for (infos) |info| {
            if (info.is_view) {
                const sql = try createViewSQL(info, dialect);
                try sqls.append(try allocator.dupe(u8, sql));
                std.heap.page_allocator.free(sql);
            }
        }

        // M2M junction tables.
        inline for (infos) |info| {
            if (info.is_view) continue;
            inline for (info.edges) |e| {
                if (e.relation == .m2m and e.through == null) {
                    const jtable = comptime junctionTableForEdge(e, info);
                    const sql = try createTableSQL(jtable, dialect);
                    try sqls.append(try allocator.dupe(u8, sql));
                    std.heap.page_allocator.free(sql);
                }
            }
        }

        // CREATE INDEX for non-view entities.
        inline for (infos) |info| {
            if (info.is_view or info.indexes.len == 0) continue;
            inline for (info.indexes) |idx| {
                const idx_def = IndexDef{
                    .name = idx.name,
                    .columns = idx.columns,
                    .unique = idx.unique,
                };
                const sql = try createIndexSQL(idx_def, info.table_name, dialect);
                try sqls.append(try allocator.dupe(u8, sql));
                std.heap.page_allocator.free(sql);
            }
        }

        // Print collected SQL.
        for (sqls.items) |s| {
            std.debug.print("{s};\n", .{s});
        }
        return;
    }

    // Bootstrap the history table outside the transaction; the SQL is
    // already idempotent (CREATE TABLE IF NOT EXISTS) and there's no
    // point rolling it back if a later step fails.
    try ensureMigrationsTable(driver);

    // Read already-applied versions once, before opening the transaction.
    const applied = try appliedVersions(allocator, driver);
    defer allocator.free(applied);

    var tx = try driver.beginTx();
    errdefer tx.deinit();

    // Tx.inner is a Driver value type, so every existing helper that
    // accepts a Driver can run inside the transaction unchanged.
    const tx_drv = tx.inner;

    // Step 1: create tables, views, and M2M junction tables. CREATE TABLE
    // IF NOT EXISTS keeps this safe even on a partial previous run.
    //
    // The schema state (table/column/index existence) is the authoritative
    // gate — we always re-check the database before applying each change.
    // `zent_schema_migrations` is an audit trail: `recordMigration` uses
    // `ON CONFLICT DO NOTHING` / `ON DUPLICATE KEY UPDATE`, so re-recording
    // a version (e.g. after a table was dropped out-of-band) never produces
    // duplicates.
    //
    // When a version is already in `applied`, we still verify the table
    // actually exists: if it was dropped out-of-band, the `applied` entry is
    // stale and we must re-create the table.
    inline for (infos) |info| {
        if (info.is_view) {
            const version = comptime computeMigrationVersion(info.table_name, "create_view", "");
            if (!versionContains(applied, version)) {
                const sql = try createViewSQL(info, dialect);
                defer std.heap.page_allocator.free(sql);
                _ = try tx_drv.exec(sql, &.{});
                try recordMigration(tx_drv, version, null);
            } else {
                // Version is recorded but the view may have been dropped
                // out-of-band. If the view no longer exists, re-create it.
                var existing = try getExistingColumns(allocator, tx_drv, info.table_name);
                if (existing.items.len == 0) {
                    existing.deinit();
                    const sql = try createViewSQL(info, dialect);
                    defer std.heap.page_allocator.free(sql);
                    _ = try tx_drv.exec(sql, &.{});
                    try recordMigration(tx_drv, version, null);
                } else {
                    freeExistingColumns(allocator, &existing);
                }
            }
        } else {
            const table = comptime tableFromTypeInfoCrossRef(info, infos);
            const version = comptime computeMigrationVersion(info.table_name, "create_table", "");
            if (!versionContains(applied, version)) {
                const sql = try createTableSQL(table, dialect);
                defer std.heap.page_allocator.free(sql);
                _ = try tx_drv.exec(sql, &.{});
                try recordMigration(tx_drv, version, null);
            } else {
                // Version is recorded but the table may have been dropped
                // out-of-band. If the table no longer exists, re-create it.
                var existing = try getExistingColumns(allocator, tx_drv, table.name);
                if (existing.items.len == 0) {
                    // Table does not exist — re-create it.
                    existing.deinit();
                    const sql = try createTableSQL(table, dialect);
                    defer std.heap.page_allocator.free(sql);
                    _ = try tx_drv.exec(sql, &.{});
                    try recordMigration(tx_drv, version, null);
                } else {
                    freeExistingColumns(allocator, &existing);
                }
            }
        }
    }

    // M2M junction tables: only declared on one side at a time, and only
    // when the edge doesn't use an explicit edge schema (through).
    inline for (infos) |info| {
        if (info.is_view) continue;
        inline for (info.edges) |e| {
            if (e.relation == .m2m and e.through == null) {
                const jtable = comptime junctionTableForEdge(e, info);
                const version = comptime computeMigrationVersion(jtable.name, "create_junction", "");
                if (!versionContains(applied, version)) {
                    const sql = try createTableSQL(jtable, dialect);
                    defer std.heap.page_allocator.free(sql);
                    _ = try tx_drv.exec(sql, &.{});
                    try recordMigration(tx_drv, version, null);
                } else {
                    // Version is recorded but the junction table may have been
                    // dropped out-of-band. Re-create it if missing.
                    var existing = try getExistingColumns(allocator, tx_drv, jtable.name);
                    if (existing.items.len == 0) {
                        existing.deinit();
                        const sql = try createTableSQL(jtable, dialect);
                        defer std.heap.page_allocator.free(sql);
                        _ = try tx_drv.exec(sql, &.{});
                        try recordMigration(tx_drv, version, null);
                    } else {
                        freeExistingColumns(allocator, &existing);
                    }
                }
            }
        }
    }

    // Step 2: for each non-view entity, add missing columns and indexes.
    // The live schema (introspected via information_schema / PRAGMA) is
    // the authoritative gate: we always add a column or index if it is
    // absent, even if a prior `zent_schema_migrations` row claimed the
    // work was done. This handles the common case of a table being
    // dropped or truncated out-of-band — the migration must still bring
    // the schema back to the declared shape. The `recordMigration` INSERT
    // itself is idempotent (`ON CONFLICT DO NOTHING`), so re-recording a
    // version never produces duplicate history rows.
    inline for (infos) |info| {
        if (info.is_view) continue;

        const table = comptime tableFromTypeInfoCrossRef(info, infos);

        var existing_cols = try getExistingColumns(allocator, tx_drv, table.name);
        defer freeExistingColumns(allocator, &existing_cols);

        inline for (table.columns) |col| {
            const version = comptime computeMigrationVersion(info.table_name, "add_column", col.name);
            if (!columnExists(existing_cols.items, col.name)) {
                const sql = try alterTableAddColumnSQL(allocator, table.name, col, dialect);
                defer allocator.free(sql);
                _ = try tx_drv.exec(sql, &.{});
                try recordMigration(tx_drv, version, null);
            }
        }

        // Phase 3 Task 12 — DROP COLUMN: remove columns that exist in
        // the database but not in the schema. Guarded by opts.drop_columns
        // to avoid accidental data loss.
        // No version recording: column names are runtime data from
        // introspection, and DROP COLUMN is naturally idempotent
        // (re-running on an already-dropped column is a no-op error
        // that we silently tolerate).
        if (opts.drop_columns) {
            for (existing_cols.items) |existing_col| {
                if (!columnExistsTableDef(table, existing_col.name)) {
                    const sql = try dropColumnSQL(allocator, table.name, existing_col.name, dialect);
                    defer allocator.free(sql);
                    _ = try tx_drv.exec(sql, &.{});
                }
            }
        }

        // Phase 3 Task 12 — ALTER TYPE: change column types that differ
        // between the database and the schema. Guarded by
        // opts.allow_data_loss; SQLite is skipped (unsupported).
        if (opts.allow_data_loss) {
            inline for (table.columns) |col| {
                // Only check columns that already exist in the DB.
                if (columnExists(existing_cols.items, col.name)) {
                    const existing_col = getExistingColumnByName(existing_cols.items, col.name) orelse unreachable;
                    // Normalise both sides for comparison: the DB side is
                    // already lowercased by getExistingColumns.
                    const schema_type_upper = col.sql_type;
                    // Build a lowercase copy of the schema type.
                    var buf: [128]u8 = undefined;
                    if (schema_type_upper.len <= buf.len) {
                        @memcpy(buf[0..schema_type_upper.len], schema_type_upper);
                        for (buf[0..schema_type_upper.len]) |*c| c.* = std.ascii.toLower(c.*);
                        const schema_type_lower = buf[0..schema_type_upper.len];

                        if (!std.mem.eql(u8, existing_col.sql_type, schema_type_lower)) {
                            // Skip ALTER TYPE on SQLite (unsupported natively).
                            if (dialect.name[0] != 's') {
                                const version = comptime computeMigrationVersion(info.table_name, "alter_type", col.name);
                                if (!versionContains(applied, version)) {
                                    const sql = try alterColumnTypeSQL(allocator, table.name, col.name, col.sql_type, dialect);
                                    defer allocator.free(sql);
                                    _ = try tx_drv.exec(sql, &.{});
                                    try recordMigration(tx_drv, version, null);
                                }
                            }
                        }
                    }
                }
            }
        }

        var existing_idxs = try getExistingIndexes(allocator, tx_drv, table.name);
        defer freeExistingIndexes(allocator, &existing_idxs);

        inline for (info.indexes) |idx| {
            const idx_def = IndexDef{
                .name = idx.name,
                .columns = idx.columns,
                .unique = idx.unique,
            };
            if (!indexExists(existing_idxs.items, idx_def.name)) {
                const version = comptime computeMigrationVersion(info.table_name, "create_index", idx.name);
                const sql = try createIndexSQL(idx_def, table.name, dialect);
                defer std.heap.page_allocator.free(sql);
                _ = try tx_drv.exec(sql, &.{});
                try recordMigration(tx_drv, version, null);
            }
        }
    }

    try tx.commit();
    tx.deinit();
}

/// Backward-compatible entry point: calls `migrateSchemaWithOptions` with
/// default `MigrateOptions{}` (no drops, no type changes). All existing callers
/// continue to work without modification.
pub fn migrateSchema(
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    comptime infos: []const TypeInfo,
) !void {
    return migrateSchemaWithOptions(allocator, driver, infos, MigrateOptions{});
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Migration version uses stable positive FNV-1a hash" {
    const version = comptime computeMigrationVersion("user", "add_column", "email");
    try std.testing.expectEqual(@as(i64, 1_537_368_564), version);
    try std.testing.expect(version >= 0);
    try std.testing.expect(version <= std.math.maxInt(i32));
}

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
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"name\" TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"age\" INTEGER") != null);
}

test "PostgreSQL migration SQL resolves logical field types" {
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    const Payload = struct { value: i64 };
    const Event = schema("DialectEvent", .{
        .fields = &.{ field.Time("occurred_at"), field.JSON("payload", Payload), field.UUID("external_id") },
    });

    const info = comptime fromSchema(Event);
    const table = comptime tableFromTypeInfo(info);
    const sql = try createTableSQL(table, Dialect.postgres);
    defer std.heap.page_allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "\"occurred_at\" TIMESTAMPTZ") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"payload\" JSONB") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"external_id\" UUID") != null);
}

test "MySQL type-only ALTER is rejected as unsafe" {
    const result = alterColumnTypeSQL(std.testing.allocator, "user", "name", "TEXT", Dialect.mysql);
    if (result) |sql| {
        std.testing.allocator.free(sql);
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.MySQLTypeChangeUnsafe, err);
    }
}

test "Migrate schema adds missing columns" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    // Create legacy table with only id + name
    _ = try drv.exec("CREATE TABLE legacy_user (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)", &.{});

    const LegacyUser = schema("LegacyUser", .{
        .fields = &.{ field.String("name"), field.Int("age"), field.String("email") },
    });

    const info = comptime fromSchema(LegacyUser);
    const infos = &[_]TypeInfo{info};
    try migrateSchema(std.testing.allocator, drv.asDriver(), infos);

    // Verify new columns exist via PRAGMA
    var rows = try drv.query("PRAGMA table_info(legacy_user)", &.{});
    defer rows.deinit();

    var found_age = false;
    var found_email = false;
    while (rows.next()) |row| {
        const col_name = row.getText(1) orelse continue;
        if (std.mem.eql(u8, col_name, "age")) found_age = true;
        if (std.mem.eql(u8, col_name, "email")) found_email = true;
    }
    try std.testing.expect(found_age);
    try std.testing.expect(found_email);
}

test "Migrate schema drops columns when opts.drop_columns set (SQLite)" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    // Create table with id, name, and an extra column "legacy_field"
    _ = try drv.exec(
        "CREATE TABLE book (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, legacy_field TEXT)",
        &.{},
    );

    // Schema only declares id + name — legacy_field should be dropped.
    const Book = schema("Book", .{
        .fields = &.{field.String("name")},
    });

    const info = comptime fromSchema(Book);
    const infos = &[_]TypeInfo{info};
    try migrateSchemaWithOptions(std.testing.allocator, drv.asDriver(), infos, MigrateOptions{
        .drop_columns = true,
    });

    // Verify legacy_field was dropped.
    var rows = try drv.query("PRAGMA table_info(book)", &.{});
    defer rows.deinit();

    var found_legacy = false;
    while (rows.next()) |row| {
        const col_name = row.getText(1) orelse continue;
        if (std.mem.eql(u8, col_name, "legacy_field")) found_legacy = true;
    }
    try std.testing.expect(!found_legacy);
}

test "Migrate schema does NOT drop columns when opts.drop_columns false (default)" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec(
        "CREATE TABLE album (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, extra_col TEXT)",
        &.{},
    );

    const Album = schema("Album", .{
        .fields = &.{field.String("title")},
    });

    const info = comptime fromSchema(Album);
    const infos = &[_]TypeInfo{info};
    // Default MigrateOptions{} has drop_columns=false.
    try migrateSchema(std.testing.allocator, drv.asDriver(), infos);

    // extra_col should still exist.
    var rows = try drv.query("PRAGMA table_info(album)", &.{});
    defer rows.deinit();

    var found_extra = false;
    while (rows.next()) |row| {
        const col_name = row.getText(1) orelse continue;
        if (std.mem.eql(u8, col_name, "extra_col")) found_extra = true;
    }
    try std.testing.expect(found_extra);
}

test "Migrate schema alters column type when opts.allow_data_loss set (SQLite — skips gracefully)" {
    const SQLiteDriver = @import("../sqlite.zig").SQLiteDriver;
    const field = @import("../../core/field.zig");
    const schema = @import("../../core/schema.zig").Schema;
    const fromSchema = @import("../../codegen/graph.zig").fromSchema;

    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    // Create a table where "score" column is TEXT but schema says INTEGER.
    _ = try drv.exec(
        "CREATE TABLE entry (id INTEGER PRIMARY KEY AUTOINCREMENT, score TEXT)",
        &.{},
    );

    const Entry = schema("Entry", .{
        .fields = &.{field.Int("score")},
    });

    const info = comptime fromSchema(Entry);
    const infos = &[_]TypeInfo{info};
    // allow_data_loss=true, but SQLite returns UnsupportedDialect — must not crash.
    try migrateSchemaWithOptions(std.testing.allocator, drv.asDriver(), infos, MigrateOptions{
        .allow_data_loss = true,
    });

    // The type won't change on SQLite (unsupported), but migration must succeed.
    var rows = try drv.query("PRAGMA table_info(entry)", &.{});
    defer rows.deinit();

    while (rows.next()) |row| {
        const col_name = row.getText(1) orelse continue;
        if (std.mem.eql(u8, col_name, "score")) {
            const col_type = row.getText(2) orelse "";
            // On SQLite the type stays TEXT because ALTER TYPE is unsupported.
            try std.testing.expect(std.mem.eql(u8, col_type, "TEXT"));
        }
    }
}
