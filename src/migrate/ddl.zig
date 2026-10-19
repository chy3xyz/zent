//! DDL generation: the table/junction/index/view shapes turned into statements,
//! and the rules each dialect imposes on them.
//!
//! Everything here is a pure function of a `TableDef` and a `Dialect` — no
//! driver, no catalog, no I/O — so the planner and the introspection code can
//! both call it, and it can be tested by comparing strings. It sits on top of
//! `migrate/types.zig` and below `migrate.zig`'s plan/execute half.

const std = @import("std");

const budget = @import("../base/budget.zig");
const Dialect = @import("../base/dialect.zig").Dialect;
const zent_log = @import("../base/log.zig");
const sql_driver = @import("../sql/driver.zig");
const TypeInfo = @import("../codegen/graph.zig").TypeInfo;
const FieldInfo = @import("../codegen/graph.zig").FieldInfo;
const EdgeInfo = @import("../codegen/graph.zig").EdgeInfo;
const IndexInfo = @import("../codegen/graph.zig").IndexInfo;
const pkColumn = @import("../codegen/graph.zig").pkColumn;
const toSnakeCase = @import("../codegen/graph.zig").toSnakeCase;
const types = @import("types.zig");
const field_mod = @import("../core/field.zig");

const ColumnDef = types.ColumnDef;
const ForeignKeyDef = types.ForeignKeyDef;
const IndexDef = types.IndexDef;
const TableDef = types.TableDef;
const MySqlServer = types.MySqlServer;
const MySqlTextRestriction = types.MySqlTextRestriction;
const MySqlTextError = types.MySqlTextError;
const isSQLiteDialect = types.isSQLiteDialect;
const columnSQLType = types.columnSQLType;
const declaredTypeRewrite = types.declaredTypeRewrite;
const dialectDisplayName = types.dialectDisplayName;
const auditTimestampDefault = types.auditTimestampDefault;
const isMySqlAutoIncrementType = types.isMySqlAutoIncrementType;
const isMySqlBlobTextJsonType = types.isMySqlBlobTextJsonType;
const nameInList = types.nameInList;
const columnDefByName = types.columnDefByName;

/// Scan the DDL a caller is *about to emit* — the column definitions of
/// `table`, plus `indexes` — for the first restriction MySQL puts on a
/// BLOB/TEXT/JSON column, or null when there is none.
///
/// Pure: no allocation, no connection, no database. Returns null for every
/// dialect but MySQL, whose restriction this is.
///
/// The rules applied are **MySQL's**, the stricter of the two server families:
/// a caller that knows it is talking to MariaDB (and only such a caller can
/// know, see `detectMySqlServer`) uses `findMySqlTextRestrictionWithServer`,
/// which drops the `DEFAULT` restriction on MariaDB >= 10.2.1. This spelling
/// stays the default so an unidentified server is never given the relaxed rule.
///
/// Each caller passes exactly what its statement contains:
/// `createTableSQLAlloc` passes the table's columns and no indexes (a table
/// statement never emits `table.indexes`, and rejecting a table that already
/// exists because of an index it will not create would turn a no-op into a
/// failed deploy), and `createIndexSQLForTableAlloc` passes the one index it
/// is about to emit. That keeps the check honest about the SQL it precedes.
pub fn findMySqlTextRestriction(table: TableDef, indexes: []const IndexDef, dialect: Dialect) ?MySqlTextRestriction {
    return findMySqlTextRestrictionWithServer(table, indexes, dialect, .mysql);
}

/// `findMySqlTextRestriction`, told which server the statement is for.
///
/// `server` is consulted for exactly one kind: `.default_value`. MariaDB has
/// accepted a `DEFAULT` on a BLOB/TEXT/JSON column since 10.2.1, so on
/// `.mariadb` that column is not a restriction and the scan moves on — a
/// column that is *also* UNIQUE (or a PRIMARY KEY, or a key of an index) is
/// still reported, because the key-length rule is shared. On `.mysql` this is
/// byte-for-byte `findMySqlTextRestriction`'s answer.
pub fn findMySqlTextRestrictionWithServer(
    table: TableDef,
    indexes: []const IndexDef,
    dialect: Dialect,
    server: MySqlServer,
) ?MySqlTextRestriction {
    if (dialect.kind() != .mysql) return null;

    for (table.columns) |col| {
        const sql_type = columnSQLType(col, dialect);
        if (!isMySqlBlobTextJsonType(sql_type)) continue;
        const kind: MySqlTextRestriction.Kind = if (col.default_value != null and server == .mysql)
            .default_value
        else if (col.unique and !col.primary_key)
            .unique
        else if (col.primary_key or nameInList(table.primary_keys, col.name))
            .primary_key
        else
            continue;
        return .{ .table = table.name, .column = col.name, .sql_type = sql_type, .kind = kind };
    }

    for (indexes) |idx| {
        for (idx.columns) |index_column| {
            const col = columnDefByName(table, index_column) orelse continue;
            const sql_type = columnSQLType(col, dialect);
            if (isMySqlBlobTextJsonType(sql_type)) {
                return .{
                    .table = table.name,
                    .column = index_column,
                    .sql_type = sql_type,
                    .kind = .index,
                    .index_name = idx.name,
                };
            }
        }
    }
    return null;
}

/// Identify the server behind a `.mysql`-kind connection from
/// `SELECT VERSION()`, or answer `.mysql` when it cannot be identified.
///
/// This is the one probe that lets the DDL layer tell MySQL and MariaDB apart
/// (they share the errno numbering but not every rule — see `MySqlServer`), and
/// it runs once per migration, on the same connection the introspection uses.
///
/// **Failures are conservative and never propagate.** A server that refuses the
/// query — no privilege, a connection mid-failure, a proxy that answers
/// something else — is treated as MySQL, so an unidentified server keeps every
/// restriction and never has one relaxed for it. Each failure logs a `warn`
/// naming the reason, so an operator sees why a MariaDB deploy still writes
/// MySQL-shaped DDL. The function has no error return on purpose: this probe is
/// not a step a migration can fail on. It is also read-only (`query`, never
/// `exec`), so the dry run can call the same code path.
pub fn detectMySqlServer(drv: sql_driver.Driver) MySqlServer {
    var rows = drv.query("SELECT VERSION()", &.{}) catch |err| {
        zent_log.warn(
            "zent: could not identify the MySQL/MariaDB server ({s}); applying MySQL's stricter BLOB/TEXT rules",
            .{@errorName(err)},
        );
        return .mysql;
    };
    defer rows.deinit();
    const row = rows.next() orelse {
        const reason = if (rows.nextError()) |err| @errorName(err) else "no rows";
        zent_log.warn(
            "zent: could not identify the MySQL/MariaDB server ({s}); applying MySQL's stricter BLOB/TEXT rules",
            .{reason},
        );
        return .mysql;
    };
    const version = row.getText(0) orelse {
        zent_log.warn(
            "zent: could not identify the MySQL/MariaDB server (SELECT VERSION() answered no text); applying MySQL's stricter BLOB/TEXT rules",
            .{},
        );
        return .mysql;
    };
    return classifyMySqlServer(version);
}

/// The classification half of `detectMySqlServer`, split out so the spelling
/// MariaDB is recognised by is pinned without a server: MariaDB's version
/// strings read `10.11.6-MariaDB-1~deb12u1` and MySQL's `9.7.0`. The substring
/// is the same one `tests/integration/mysql.zig`'s `isMariaDB` looks for.
pub fn classifyMySqlServer(version: []const u8) MySqlServer {
    return if (std.mem.indexOf(u8, version, "MariaDB") != null) .mariadb else .mysql;
}

/// Whether any table this plan can emit a `DEFAULT` for declares a
/// BLOB/TEXT/JSON column on MySQL — the one shape where MySQL and MariaDB
/// disagree, and therefore the only shape for which identifying the server can
/// change the SQL.
///
/// Pure and comptime: a schema whose text columns carry no `DEFAULT` produces
/// the same statements on both servers, so it is not worth a catalog round trip
/// to ask which one is there. The probe is then skipped and the MySQL rules are
/// used, which is exactly what the generators do with `.mysql` anyway. (The
/// statement-modelling stub tests in `src/test/allocation_failures_plan.zig`
/// depend on this: an unannounced `SELECT VERSION()` would be a statement they
/// never claimed.)
pub fn graphHasMySqlTextDefault(comptime infos: []const TypeInfo) bool {
    inline for (infos) |info| {
        if (info.is_view) continue;
        const table = comptime tableFromTypeInfoCrossRef(info, infos);
        inline for (table.columns) |col| {
            if (col.default_value == null) continue;
            if (isMySqlBlobTextJsonType(columnSQLType(col, Dialect.mysql))) return true;
        }
    }
    return false;
}

/// Say out loud that a declared column type has no column type on this dialect
/// and was emitted as something else.
///
/// The mirror image of the index-method/opclass warnings (`indexMethodFor`,
/// `indexOpClassFor`), and deliberately the same shape — declared here, dropped
/// with a line that names what was dropped. The *column* is the one that
/// matters: an index on a vector column that is stored as `TEXT` still indexes
/// the text, while the column itself is the whole loss (pgvector's operators
/// and its `vector` type are gone, and the value is a `[1,2,3]` string).
///
/// Once per (table, column) per migration is structural, not tracked: both
/// migration entry points call this once per entity, next to
/// `warnOutOfGraphEdgeRefs`, and a table's column list names a column once — so
/// the two DDL statements the planner can produce for one column (a `CREATE
/// TABLE` and, when the table already existed, an `ALTER TABLE ADD COLUMN`)
/// still produce one line.
pub fn warnDegradedColumnTypes(table: TableDef, dialect: Dialect) void {
    for (table.columns) |col| {
        const rewrite = declaredTypeRewrite(col, dialect) orelse continue;
        zent_log.warn(
            "zent: {s}.{s} declares the {s} type, which {s} has no column type for, so the column is emitted as {s}; it is stored and read as text and none of {s}'s operators or indexes for {s} apply — migrate this schema on PostgreSQL, or declare a type {s} can create",
            .{
                table.name,
                col.name,
                rewrite.declared,
                dialectDisplayName(dialect.kind()),
                rewrite.emitted,
                dialectDisplayName(dialect.kind()),
                rewrite.declared,
                dialectDisplayName(dialect.kind()),
            },
        );
    }
}

/// `IndexInfo` → `IndexDef`: the one construction both migration paths use, so
/// a declaration cannot reach `migrateSchema` and not `planMigrateStatements`
/// (the dry run and the run it previews must agree), and so the test that pins
/// a schema's `method`/`opclass` reaching the DDL does not restate the mapping
/// it is testing.
pub fn indexDefFromInfo(idx: IndexInfo) IndexDef {
    return .{
        .name = idx.name,
        .columns = idx.columns,
        .unique = idx.unique,
        .method = idx.method,
        .opclass = idx.opclass,
    };
}

/// Generate a TableDef from a TypeInfo at comptime.
pub fn tableFromTypeInfo(comptime info: TypeInfo) TableDef {
    comptime {
        // 字段/外键循环在 `inline for (infos)` 的迁移入口下按表×字段展开，
        // 15+ 表的应用 schema 就会击穿默认 5000 分支限额(如 zenaipa);与
        // defaultValueStr 同量级提升配额，避免 "exceeded backwards branches"。
        @setEvalBranchQuota(budget.flat);
        var columns: []const ColumnDef = &.{};

        // Generate columns from fields. DDL uses the physical column name
        // (`StorageKey`), not the Zig field name.
        for (info.fields) |f| {
            const col = ColumnDef{
                .name = f.column_name,
                .sql_type = f.sql_type,
                .logical_type = f.field_type,
                .varchar_sql = if (f.max_length) |n| field_mod.varCharSQL(n) else null,
                .vector_sql = if (f.vector_dims) |n| field_mod.vectorSQL(n) else null,
                .sql_type_override = f.sql_type_override,
                .primary_key = f.is_id,
                .not_null = !f.optional and !f.nillable,
                .unique = f.unique,
                .default_value = defaultValueStr(f),
                // Only an integer primary key auto-increments. Marking every id as
                // auto-increment made PostgreSQL rewrite a UUID PK to SERIAL and
                // MySQL reject a TEXT PK, silently generating the wrong column type.
                .auto_increment = f.is_id and f.field_type == .int,
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
                // e.g., Car.owner -> User (owner_id column in car table), named
                // by the edge (`Field("owner_id")`) when it says so and
                // `<edge>_id` otherwise — `graph.getEdgeFKColumn`'s choice, so
                // this DDL and the queries name the same column.
                const fk_col_name = e.field_name orelse (e.name ++ "_id");
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
                    // TODO: the referenced column is hardcoded to "id", so a
                    // target declaring `.pk` or a StorageKey-renamed `id` gets
                    // an FK to a column it does not have. Resolving it needs
                    // the target's TypeInfo, which this pub signature does not
                    // carry. The migration paths are not affected: they go
                    // through `tableFromTypeInfoCrossRef`, which references
                    // `graph.pkColumn` — and so does `junctionTableForEdge`,
                    // leaving this pub export the last of that family.
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
                    // TODO: the referenced column is hardcoded to "id", so a
                    // target declaring `.pk` or a StorageKey-renamed `id` gets
                    // an FK to a column it does not have. Resolving it needs
                    // the target's TypeInfo, which this pub signature does not
                    // carry. The migration paths are not affected: they go
                    // through `tableFromTypeInfoCrossRef`, which references
                    // `graph.pkColumn` — and so does `junctionTableForEdge`,
                    // leaving this pub export the last of that family.
                    .ref_columns = &[_][]const u8{"id"},
                };
                foreign_keys = foreign_keys ++ &[_]ForeignKeyDef{fk};
            }
        }

        // Primary keys
        var pks: []const []const u8 = &.{};
        for (info.fields) |f| {
            if (f.is_id) {
                pks = pks ++ &[_][]const u8{f.column_name};
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
///
/// Both ends resolve the way every other edge reference in this file does
/// (`edgeRefTarget` + `graph.pkColumn`): the source end from `source_info`
/// itself, the target end by looking the edge's target up in `all_infos` —
/// a declared `table_name` and a declared `.pk` (or a `StorageKey`-renamed
/// `id`) on either end are honoured, so the junction `migrateSchema` creates
/// and the one `buildEdgeStep`/`getJunctionTable` read derive the same name,
/// columns and referenced keys. A target outside the graph has no TypeInfo
/// to ask and keeps the historical shape — `toSnakeCase(target_name)`
/// referencing `"id"` — the same fallback `tableFromTypeInfoCrossRef` keeps,
/// because the reference dangles either way.
pub fn junctionTableForEdge(comptime edge: EdgeInfo, comptime source_info: TypeInfo, comptime all_infos: []const TypeInfo) TableDef {
    comptime {
        // Two ends × per-end name/column concatenations, per junction edge
        // inside the `inline for (infos)` migration loops, each end resolved by
        // a scan of `all_infos`: scaled with the graph like its siblings
        // (see `base/budget.zig`).
        @setEvalBranchQuota(budget.graph(all_infos.len));
        const ref = edgeRefTarget(edge, all_infos);
        const source_table = source_info.table_name;
        const target_table = ref.table;

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

        // Each reference names that end's primary-key column — `graph.pkColumn`
        // of the end's TypeInfo, the same resolver the relation query uses.
        const source_ref = pkColumn(source_info);
        const source_fk = ForeignKeyDef{
            .columns = if (a_first) &[_][]const u8{col1} else &[_][]const u8{col2},
            .ref_table = source_table,
            .ref_columns = &[_][]const u8{source_ref},
        };
        // A cross-graph end contributes its column and its half of the primary
        // key, and **no constraint**: the table name would have to be derived
        // from the entity name, and a wrong derivation is a rejected
        // `CREATE TABLE` rather than a dangling reference (see
        // `tableFromTypeInfoCrossRef`). Emitted in column order, so an in-graph
        // pair renders exactly as before.
        const target_fk = ForeignKeyDef{
            .columns = if (a_first) &[_][]const u8{col2} else &[_][]const u8{col1},
            .ref_table = target_table,
            .ref_columns = if (ref.info) |target|
                &[_][]const u8{pkColumn(target)}
            else
                &[_][]const u8{"id"},
        };
        const fk_for_col1 = if (a_first) source_fk else target_fk;
        const fk_for_col2 = if (a_first) target_fk else source_fk;
        const foreign_keys: []const ForeignKeyDef = if (ref.info == null)
            (if (a_first) &[_]ForeignKeyDef{fk_for_col1} else &[_]ForeignKeyDef{fk_for_col2})
        else
            &[_]ForeignKeyDef{ fk_for_col1, fk_for_col2 };

        return TableDef{
            .name = table_name,
            .columns = &.{
                ColumnDef{ .name = col1, .sql_type = "INTEGER", .not_null = true },
                ColumnDef{ .name = col2, .sql_type = "INTEGER", .not_null = true },
            },
            .primary_keys = &.{ col1, col2 },
            .foreign_keys = foreign_keys,
        };
    }
}

/// Generate CREATE TABLE SQL for a TableDef using specified allocator.
///
/// Fail-closed on MySQL: a BLOB/TEXT/JSON column the table would declare with
/// `DEFAULT`, `UNIQUE`, or as a `PRIMARY KEY` cannot be created at all, so the
/// statement is refused with a named error and a logged detail instead of
/// being emitted for the server to reject with errno 1101/1170 (see
/// `findMySqlTextRestriction`). Indexes are not `CREATE TABLE`'s business —
/// `table.indexes` is never emitted here — so they are checked by
/// `createIndexSQLForTableAlloc`.
///
/// This applies MySQL's rules; a caller that identified its server as MariaDB
/// (see `detectMySqlServer`) uses `createTableSQLAllocWithServer`, which emits
/// the `DEFAULT` MariaDB >= 10.2.1 accepts.
pub fn createTableSQLAlloc(allocator: std.mem.Allocator, table: TableDef, dialect: Dialect) ![]const u8 {
    return createTableSQLAllocWithServer(allocator, table, dialect, .mysql);
}

/// `createTableSQLAlloc`, told which server the statement is for.
///
/// The only difference is which text-column restrictions are enforced before
/// the SQL is built: on `.mariadb` a BLOB/TEXT `DEFAULT` is allowed through (and
/// then emitted below like any other column's), while UNIQUE and PRIMARY KEY
/// stay refused. On `.mysql` the output is identical to
/// `createTableSQLAlloc`.
pub fn createTableSQLAllocWithServer(
    allocator: std.mem.Allocator,
    table: TableDef,
    dialect: Dialect,
    server: MySqlServer,
) ![]const u8 {
    if (findMySqlTextRestrictionWithServer(table, &.{}, dialect, server)) |restriction| {
        return reportMySqlTextRestriction(restriction);
    }

    var buf = try std.array_list.Managed(u8).initCapacity(allocator, 256);
    defer buf.deinit();

    try buf.appendSlice("CREATE TABLE IF NOT EXISTS ");
    try quoteIdentToBuffer(dialect, &buf, table.name);
    try buf.appendSlice(" (\n");

    for (table.columns, 0..) |col, i| {
        var sql_type = columnSQLType(col, dialect);
        // PostgreSQL: a bare `INTEGER PRIMARY KEY` has no default, so an
        // INSERT without an explicit id fails NOT NULL on RETURNING. Map
        // auto-increment ids to SERIAL/BIGSERIAL (which own a sequence).
        if (col.auto_increment and dialect.kind() == .postgres) {
            sql_type = if (std.ascii.eqlIgnoreCase(sql_type, "BIGINT")) "BIGSERIAL" else "SERIAL";
        }
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
            if (col.auto_increment and
                dialect.kind() == .mysql and
                isMySqlAutoIncrementType(sql_type))
            {
                try buf.appendSlice(" AUTO_INCREMENT");
            }
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
        } else if (auditTimestampDefault(col, dialect)) |dv2| {
            try buf.appendSlice(" DEFAULT ");
            try buf.appendSlice(dv2);
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

    return allocator.dupe(u8, buf.items);
}

/// Generate CREATE TABLE SQL for a TableDef.
pub fn createTableSQL(table: TableDef, dialect: Dialect) ![]const u8 {
    return createTableSQLAlloc(std.heap.page_allocator, table, dialect);
}

/// Generate CREATE INDEX SQL for an IndexDef using specified allocator.
///
/// Unchecked: without the table's column types this cannot tell whether the
/// dialect will accept the key list. `createIndexSQLForTableAlloc` is the
/// entry point that can, and is what the migration paths use.
///
/// The access method and operator class are the one part of an index
/// declaration the dialects genuinely disagree about, so each gets one spot:
///
/// | Dialect | `method` | `opclass` |
/// |---|---|---|
/// | PostgreSQL | `ON t USING <method> (…)`, verbatim | `<col> <opclass>` |
/// | MySQL | `INDEX i USING BTREE\|HASH ON t (…)`; any other method is omitted with a warning | omitted with a warning |
/// | SQLite (and an unknown dialect) | omitted with a warning | omitted with a warning |
///
/// Undeclared (the default) emits nothing new on any of them: the statement is
/// byte-for-byte the one this function produced before either slot existed.
/// Both values are validated against a bare-identifier shape before they are
/// emitted (they are the only parts of this statement that are neither quoted
/// nor a schema column), and a method/opclass pair the dialect cannot express is
/// *reported*, never silently rewritten into one that means something else.
pub fn createIndexSQLAlloc(allocator: std.mem.Allocator, index: IndexDef, table_name: []const u8, dialect: Dialect) ![]const u8 {
    var buf = try std.array_list.Managed(u8).initCapacity(allocator, 256);
    defer buf.deinit();

    const kind = dialect.kind();
    // Resolved before anything is written: both helpers can report, and a
    // statement half-emitted into `buf` would be discarded anyway.
    const method = try indexMethodFor(index, kind, table_name);
    const opclass = try indexOpClassFor(index, kind, table_name);

    try buf.appendSlice("CREATE ");
    if (index.unique) try buf.appendSlice("UNIQUE ");
    if (kind == .mysql) {
        // MySQL's grammar puts the index type between the name and `ON`;
        // PostgreSQL's puts `USING` after the table. Both were checked against
        // a running server.
        try buf.appendSlice("INDEX ");
        try quoteIdentToBuffer(dialect, &buf, index.name);
        if (method) |m| {
            try buf.appendSlice(" USING ");
            try buf.appendSlice(m);
        }
        try buf.appendSlice(" ON ");
        try quoteIdentToBuffer(dialect, &buf, table_name);
    } else {
        // `INDEX IF NOT EXISTS` is not accepted by MySQL at all, which is why
        // the two dialects need separate prefixes (the `CREATE INDEX` above is
        // not idempotent on MySQL — the migration layer's existence check in
        // front of it is what keeps a re-run from failing).
        try buf.appendSlice("INDEX IF NOT EXISTS ");
        try quoteIdentToBuffer(dialect, &buf, index.name);
        try buf.appendSlice(" ON ");
        try quoteIdentToBuffer(dialect, &buf, table_name);
        if (method) |m| {
            try buf.appendSlice(" USING ");
            try buf.appendSlice(m);
        }
    }
    try buf.appendSlice(" (");

    for (index.columns, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(", ");
        try quoteIdentToBuffer(dialect, &buf, col);
        // `opclass` is non-null on PostgreSQL only (see `indexOpClassFor`),
        // and only for a single-column key, so this is the one column it can
        // belong to.
        if (opclass) |o| {
            if (i == 0) {
                try buf.appendSlice(" ");
                try buf.appendSlice(o);
            }
        }
    }
    try buf.appendSlice(")");

    return allocator.dupe(u8, buf.items);
}

/// Is `name` a bare SQL identifier, or a dotted chain of them
/// (`[A-Za-z_][A-Za-z0-9_$]*`, joined by `.`)?
///
/// An access method and an operator class are the only two things this file
/// emits *unquoted* and from outside the schema, and neither can be quoted
/// instead: MySQL rejects a quoted `index_type` outright (errno 1064), and on
/// PostgreSQL the unquoted spelling is what folds `HNSW` to `hnsw` the way every
/// other identifier does. So the value goes out verbatim and this is what keeps
/// "verbatim" from being an injection surface.
pub fn isBareIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    var part_start = true;
    for (name) |c| {
        if (c == '.') {
            // An empty part means a leading, trailing or doubled dot.
            if (part_start) return false;
            part_start = true;
            continue;
        }
        if (part_start) {
            if (!std.ascii.isAlphabetic(c) and c != '_') return false;
            part_start = false;
        } else if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') {
            return false;
        }
    }
    return !part_start;
}

/// The access method as `kind` can express it, or `null` when it has to be
/// omitted. See the table on `createIndexSQLAlloc`.
pub fn indexMethodFor(index: IndexDef, kind: Dialect.Kind, table_name: []const u8) !?[]const u8 {
    const declared = index.method orelse return null;
    return switch (kind) {
        .postgres => blk: {
            if (!isBareIdentifier(declared)) return error.InvalidIndexMethod;
            break :blk declared;
        },
        .mysql => blk: {
            // MySQL's *grammar* has two values, so a third can only be a
            // schema written for another database. Refusing the whole
            // migration would make a shared schema unmigratable here for a
            // performance-only declaration, so the index is created without
            // one and the omission is said out loud.
            if (std.ascii.eqlIgnoreCase(declared, "btree")) break :blk "BTREE";
            if (std.ascii.eqlIgnoreCase(declared, "hash")) break :blk "HASH";
            zent_log.warn(
                "zent: MySQL has no `{s}` index access method (only BTREE and HASH), so {s} on {s} was created without one",
                .{ declared, index.name, table_name },
            );
            break :blk null;
        },
        .sqlite, .unknown => blk: {
            zent_log.warn(
                "zent: this dialect has no index access methods, so `{s}` on {s} ({s}) was ignored",
                .{ declared, index.name, table_name },
            );
            break :blk null;
        },
    };
}

/// The key column's operator class, or `null` when the dialect has none. See
/// the table on `createIndexSQLAlloc`.
pub fn indexOpClassFor(index: IndexDef, kind: Dialect.Kind, table_name: []const u8) !?[]const u8 {
    const declared = index.opclass orelse return null;
    return switch (kind) {
        .postgres => blk: {
            // An operator class belongs to exactly one key column. Attaching it
            // to the first of several would build an index the schema did not
            // ask for, and silently dropping it would build one that cannot
            // answer the query it was declared for — so the declaration is
            // refused instead.
            if (index.columns.len != 1) return error.OpClassNeedsSingleColumn;
            if (!isBareIdentifier(declared)) return error.InvalidIndexOpClass;
            break :blk declared;
        },
        .mysql, .sqlite, .unknown => blk: {
            zent_log.warn(
                "zent: `{s}` is a PostgreSQL operator class and this dialect has none, so it was ignored on {s} ({s})",
                .{ declared, index.name, table_name },
            );
            break :blk null;
        },
    };
}

/// Generate CREATE INDEX SQL for an IndexDef.
pub fn createIndexSQL(index: IndexDef, table_name: []const u8, dialect: Dialect) ![]const u8 {
    return createIndexSQLAlloc(std.heap.page_allocator, index, table_name, dialect);
}

/// `createIndexSQLAlloc` for an index *declared on* `table`, with MySQL's
/// key-length restrictions enforced before any SQL is produced.
///
/// The column types are the whole point: a bare `CREATE INDEX ... (body)`
/// looks identical whether `body` is `VARCHAR(255)` (fine) or `TEXT` (errno
/// 1170, and no DDL MySQL will accept short of a key-length prefix that
/// changes the meaning of a UNIQUE index). Refusing here turns that into
/// `error.MySQLTextColumnCannotBeIndexed` with a logged table/column/reason,
/// and every caller that goes through this function inherits it — including
/// the dry run, which prints the SQL it would have executed.
///
/// This applies MySQL's rules; `createIndexSQLForTableAllocWithServer` is the
/// spelling for a caller that identified its server, and it differs only for a
/// table carrying a text `DEFAULT` the index is not the one to refuse.
pub fn createIndexSQLForTableAlloc(allocator: std.mem.Allocator, index: IndexDef, table: TableDef, dialect: Dialect) ![]const u8 {
    return createIndexSQLForTableAllocWithServer(allocator, index, table, dialect, .mysql);
}

/// `createIndexSQLForTableAlloc`, told which server the statement is for.
///
/// The index itself is refused on both families — a key column that is
/// BLOB/TEXT/JSON is errno 1170 on MariaDB too. `server` matters because the
/// scan walks the table's columns first: a text column carrying a `DEFAULT`
/// used to report `.default_value` here even though this statement does not
/// write that default, which on MariaDB would refuse the index for a reason
/// the server does not have.
pub fn createIndexSQLForTableAllocWithServer(
    allocator: std.mem.Allocator,
    index: IndexDef,
    table: TableDef,
    dialect: Dialect,
    server: MySqlServer,
) ![]const u8 {
    if (findMySqlTextRestrictionWithServer(table, &.{index}, dialect, server)) |restriction| {
        return reportMySqlTextRestriction(restriction);
    }
    return createIndexSQLAlloc(allocator, index, table.name, dialect);
}

/// Generate CREATE VIEW SQL using specified allocator.
///
/// The clause is dialect-dependent, and getting it wrong is not cosmetic:
/// **PostgreSQL has no `CREATE VIEW IF NOT EXISTS`** — it rejects the statement
/// with a syntax error (42601, `syntax error at or near "NOT"`), so on
/// PostgreSQL a schema declaring a view could not be migrated at all. SQLite is
/// the mirror image: it accepts `IF NOT EXISTS` and rejects `OR REPLACE`
/// (`near "OR": syntax error`). So:
///
///   - PostgreSQL and MySQL/MariaDB: `CREATE OR REPLACE VIEW`, which is
///     idempotent and replaces the stored definition — a changed `view_sql`
///     therefore **does** take effect on those two, as long as the new shape is
///     compatible (PostgreSQL allows columns to be added at the end, not
///     reordered or retyped).
///   - SQLite: `CREATE VIEW IF NOT EXISTS`, which creates a missing view and
///     leaves an existing one alone. It has no way to replace a view in place,
///     so on SQLite a changed `view_sql` still does not take effect — the
///     original behaviour, and the only one SQLite offers.
pub fn createViewSQLAlloc(allocator: std.mem.Allocator, comptime info: TypeInfo, dialect: Dialect) ![]const u8 {
    const view_sql = info.view_sql orelse return error.MissingViewSQL;
    var buf = try std.array_list.Managed(u8).initCapacity(allocator, 256);
    defer buf.deinit();

    // PostgreSQL has no `CREATE VIEW IF NOT EXISTS` (42601) and SQLite no
    // `CREATE OR REPLACE VIEW` (near `OR`), so SQLite alone takes IF NOT
    // EXISTS; an unnamed dialect keeps the OR REPLACE it has always taken.
    if (dialect.kind() == .sqlite) {
        try buf.appendSlice("CREATE VIEW IF NOT EXISTS ");
    } else {
        try buf.appendSlice("CREATE OR REPLACE VIEW ");
    }
    try quoteIdentToBuffer(dialect, &buf, info.table_name);
    try buf.appendSlice(" AS ");
    try buf.appendSlice(view_sql);

    return allocator.dupe(u8, buf.items);
}

/// Generate CREATE VIEW SQL.
pub fn createViewSQL(comptime info: TypeInfo, dialect: Dialect) ![]const u8 {
    return createViewSQLAlloc(std.heap.page_allocator, info, dialect);
}

/// The table — and, when the edge's target is in this graph, the entity —
/// an edge's foreign key must reference. The target's declared `table_name`
/// wins when the target is in this graph, and the snake_case derivation of
/// its schema name is the fallback when it is not (the historical spelling,
/// kept for a caller that migrates a table whose target it did not pass — a
/// foreign key to an entity outside the graph is dangling either way).
///
/// The derivation is *not* the same thing: an entity that declares
/// `table_name = "xdaofood_upload_file"` is stored in that table, and an FK that
/// names `upload_file` instead points at nothing. On SQLite, where foreign keys
/// are enforced since v0.70, the child's first INSERT then fails with
/// `no such table: main.upload_file` — the symptom a consumer reported as a
/// "short name" defect. `tableFromTypeInfoCrossRef`'s To-edge half has always
/// resolved this through `other_info.table_name`; the From-edge half derived the
/// name instead, which is the inconsistency this closes.
pub const EdgeRefTarget = struct {
    table: []const u8,
    /// The target entity when it is in this graph — the referenced column is
    /// `graph.pkColumn` of it. `null` means the target is outside the graph
    /// and there is no TypeInfo to ask.
    info: ?TypeInfo,
};

pub fn edgeRefTarget(comptime e: EdgeInfo, comptime all_infos: []const TypeInfo) EdgeRefTarget {
    comptime {
        for (all_infos) |ti| {
            if (std.mem.eql(u8, ti.name, e.target_name))
                return .{ .table = ti.table_name, .info = ti };
        }
        return .{ .table = toSnakeCase(e.target_name), .info = null };
    }
}

/// The edges whose foreign key goes through `edgeRefTarget`: a From m2o/o2o
/// edge gets the FK column in this table, and an M2M edge without a `Through`
/// gets one in the junction `junctionTableForEdge` derives. All other edges
/// reference an in-graph entity by construction.
pub fn edgeFKUsesRefTarget(comptime e: EdgeInfo) bool {
    return (e.kind == .from and (e.relation == .m2o or e.relation == .o2o)) or
        (e.relation == .m2m and e.through == null);
}

/// Say out loud which edge crosses this graph, so the foreign key it cannot
/// name is left out of the DDL instead of guessed.
///
/// Every surface that resolves an edge for a *query* refuses this at compile
/// time (`codegen/graph.edgeTargetInfo`, Z16), but a migration-only consumer —
/// the multi-database deployment that migrates each graph on its own, or one
/// that migrates a large schema in chunks — never builds a Client, and
/// `migrateSchema` / `createAllTables` build the table from the `infos` alone.
/// A target that is not in `infos` has **no table name this graph can know**:
/// `toSnakeCase(target_name)` is a guess that ignores the target's declared
/// `table_name`, and a wrong guess is not a dangling reference but a
/// `CREATE TABLE` the server rejects (`relation "…" does not exist`, measured on
/// PostgreSQL), which made a chunked migration fail on every retry. So the
/// column stays and the constraint is left out — that is the *silent* half; this
/// function is the other half, because the database error never named the edge
/// that caused it.
///
/// Warning once per (source entity, edge) is structural, not tracked state:
/// `inline for` visits each edge of `info` once, and each migration entry point
/// calls this once per entity. `planMigrateStatements` is the shared planner of
/// both the dry run and the real run, so neither rebuild of the table
/// definition warns twice; `createTables` is the legacy path and never runs in
/// the same migration.
pub fn warnOutOfGraphEdgeRefs(comptime info: TypeInfo, comptime all_infos: []const TypeInfo) void {
    // `comptime` on the operand: this function is reached from a runtime frame,
    // where a plain call would be a runtime value the builtin refuses.
    @setEvalBranchQuota(comptime budget.graph(all_infos.len));
    inline for (info.edges) |e| {
        const crosses: bool = comptime edgeFKUsesRefTarget(e) and edgeRefTarget(e, all_infos).info == null;
        if (crosses) {
            zent_log.warn(
                "zent: the edge '{s}' on entity {s} targets {s}, which is not in this graph's infos, so the foreign key is left out of the CREATE TABLE (its column stays): the referenced table's name cannot be resolved from this graph — migrate each graph separately in a multi-database deployment, or add {s} to this graph (cross-graph edges are Z16)",
                .{ e.name, info.name, e.target_name, e.target_name },
            );
        }
    }
}

/// Like tableFromTypeInfo, but also adds FK columns from cross-referenced To edges.
/// For example, if User has a To("cars", Car) O2M edge, this adds a "user_id" FK column
/// to the Car table pointing back to User.
pub fn tableFromTypeInfoCrossRef(comptime info: TypeInfo, comptime all_infos: []const TypeInfo) TableDef {
    comptime {
        // 字段/外键/交叉引用循环在 `inline for (infos)` 的迁移入口下按
        // 表×字段×表展开，15+ 表的应用 schema 就会击穿默认 5000 分支限额
        // (如 zenaipa)；固定常数在 154 表的消费者上同样会溢出，所以配额随
        // 图规模缩放（见 `base/budget.zig`）。
        @setEvalBranchQuota(budget.graph(all_infos.len));
        var columns: []const ColumnDef = &.{};
        var foreign_keys: []const ForeignKeyDef = &.{};

        // Generate columns from fields. DDL uses the physical column name
        // (`StorageKey`), not the Zig field name.
        for (info.fields) |f| {
            const col = ColumnDef{
                .name = f.column_name,
                .sql_type = f.sql_type,
                .logical_type = f.field_type,
                .varchar_sql = if (f.max_length) |n| field_mod.varCharSQL(n) else null,
                .vector_sql = if (f.vector_dims) |n| field_mod.vectorSQL(n) else null,
                .sql_type_override = f.sql_type_override,
                .primary_key = f.is_id,
                .not_null = !f.optional and !f.nillable,
                .unique = f.unique,
                .default_value = defaultValueStr(f),
                // Only an integer primary key auto-increments. Marking every id as
                // auto-increment made PostgreSQL rewrite a UUID PK to SERIAL and
                // MySQL reject a TEXT PK, silently generating the wrong column type.
                .auto_increment = f.is_id and f.field_type == .int,
            };
            columns = columns ++ &[_]ColumnDef{col};
        }

        // Own From edges generate FK columns in this table
        for (info.edges) |e| {
            if (e.kind == .from and (e.relation == .m2o or e.relation == .o2o)) {
                // The column the edge names (`Field("image_id")`) or `<edge>_id`
                // without one — the same choice `graph.getEdgeFKColumn` makes for
                // the query side. Deriving `<edge>_id` unconditionally put the FK
                // on a column nothing reads, while the column the queries use held
                // the reference with no constraint on it.
                const fk_col_name = e.field_name orelse (e.name ++ "_id");
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

                // The constraint only when the target is resolvable. Its
                // reference names the target's primary-key column
                // (`graph.pkColumn`): the query side has always resolved it that
                // way, while a literal "id" gave a target that declares `.pk`
                // (or stores `id` under a StorageKey) an FK to a column it does
                // not have — on SQLite the child's first INSERT then failed with
                // `foreign key mismatch`.
                //
                // **A target outside this graph has no table name to name.** The
                // historical fallback (`toSnakeCase(target_name)`) is a guess,
                // and a wrong guess is not a dangling reference — it is a
                // `CREATE TABLE` the server rejects (`relation "…" does not
                // exist`, measured on PostgreSQL for a graph whose entities
                // carry an explicit `table_name`), which made a chunked
                // migration fail on every retry. The column stays: the data
                // shape has to match what the query side reads. The constraint
                // is left out, and `warnOutOfGraphEdgeRefs` names the edge.
                const ref = edgeRefTarget(e, all_infos);
                if (ref.info) |target| {
                    const fk = ForeignKeyDef{
                        .columns = &[_][]const u8{fk_col_name},
                        .ref_table = ref.table,
                        .ref_columns = &[_][]const u8{pkColumn(target)},
                    };
                    foreign_keys = foreign_keys ++ &[_]ForeignKeyDef{fk};
                }
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
                        const fk_col_name = e.field_name orelse toSnakeCase(other_info.name) ++ "_id";
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
                                // Same rule as the From-edge half: reference
                                // the target's primary-key column
                                // (`graph.pkColumn`), not a literal "id".
                                .ref_columns = &[_][]const u8{pkColumn(other_info)},
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
                pks = pks ++ &[_][]const u8{f.column_name};
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

pub fn defaultValueStr(comptime f: FieldInfo) ?[]const u8 {
    // comptimePrint 的泛型格式化在 `inline for (infos)` 下按表×字段展开,
    // 15+ 表的应用 schema 就会击穿默认 5000 分支限额(如 zenaipa);在此
    // 提升当前 comptime 子树的配额,避免 "exceeded backwards branches"。
    @setEvalBranchQuota(budget.flat);
    return switch (f.default) {
        .none => null,
        .bool => |v| if (v) "TRUE" else "FALSE",
        .int => |v| comptime std.fmt.comptimePrint("{d}", .{v}),
        .float => |v| comptime std.fmt.comptimePrint("{d}", .{v}),
        .string => |v| comptime std.fmt.comptimePrint("'{s}'", .{v}),
    };
}

/// Log what the error name cannot carry — which table, which column, which
/// type, and why MySQL refuses — and return the matching named error.
///
/// `warn` and not `err`, so a consumer whose log handling treats `err` as
/// fatal does not die on a diagnostic the caller is about to see as a returned
/// error anyway.
pub fn reportMySqlTextRestriction(restriction: MySqlTextRestriction) MySqlTextError {
    switch (restriction.kind) {
        .default_value => zent_log.warn(
            "zent: MySQL rejects a DEFAULT on {s}.{s} ({s}, errno 1101: BLOB/TEXT/JSON cannot have a default value); use field.String (VARCHAR(255) on MySQL) or drop the default",
            .{ restriction.table, restriction.column, restriction.sql_type },
        ),
        .unique => zent_log.warn(
            "zent: MySQL cannot index {s}.{s} ({s}, errno 1170: BLOB/TEXT/JSON key specification without a key length), so its UNIQUE constraint has no DDL; use field.String (VARCHAR(255) on MySQL) or drop the uniqueness",
            .{ restriction.table, restriction.column, restriction.sql_type },
        ),
        .primary_key => zent_log.warn(
            "zent: MySQL cannot index {s}.{s} ({s}, errno 1170: BLOB/TEXT/JSON key specification without a key length), so it cannot be a PRIMARY KEY; use field.String or a narrower type",
            .{ restriction.table, restriction.column, restriction.sql_type },
        ),
        .index => zent_log.warn(
            "zent: MySQL cannot index {s}.{s} ({s}, errno 1170: BLOB/TEXT/JSON key specification without a key length), so index {s} cannot be created; use field.String (VARCHAR(255) on MySQL) or drop the column from the index",
            .{ restriction.table, restriction.column, restriction.sql_type, restriction.index_name },
        ),
    }
    return switch (restriction.kind) {
        .default_value => error.MySQLTextColumnCannotHaveDefault,
        .unique, .primary_key, .index => error.MySQLTextColumnCannotBeIndexed,
    };
}

pub fn quoteIdentToBuffer(dialect: Dialect, buf: *std.array_list.Managed(u8), name: []const u8) !void {
    const quote: u8 = if (dialect.kind() == .mysql) '`' else '"';
    try buf.append(quote);
    for (name) |c| {
        try buf.append(c);
        // SQL-92 escapes an embedded quote by doubling it, so the identifier
        // cannot be terminated early by a quote inside the name.
        if (c == quote) try buf.append(c);
    }
    try buf.append(quote);
}
