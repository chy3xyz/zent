//! `std.testing.checkAllAllocationFailures` over the two owned-assembly paths
//! the sibling sweep (`allocation_failures.zig`) does not reach:
//!
//!   - the CRUD copy path: `CrudService.getOwned` hands a scanned row to
//!     `crud.ownedCopy`, which duplicates one string field at a time and has to
//!     release the copies it already made when a later dupe fails — the
//!     partial-teardown shape where a leak is one `errdefer` away;
//!   - the migration planner: `migrate.planMigrateStatements` builds an ordered
//!     list of statements, each of them its own buffer, out of the same kind of
//!     `allocPrint`/`dupe` chain.
//!
//! The method is the sibling file's: `checkAllAllocationFailures` runs the
//! function once to count the allocations, then fails each one in turn and
//! asserts the run either completes or fails with `OutOfMemory` — with the
//! allocator's byte ledger balanced, so a leak at any single point fails the
//! test by index with the byte report.
//!
//! The planner is driven through a stub driver whose catalog is entirely under
//! the test's control: `planMigrateStatements` only introspects (it never
//! execs), so a fixed set of `PRAGMA` answers is the whole surface it needs,
//! and each existence gate — "this table is there", "nothing is there", "this
//! index exists and its keys are readable" — can be exercised on demand.
//!
//! The index introspection itself is per dialect, and all three implementations
//! share one teardown shape: the index name — and every key column — is
//! duplicated *before* the `append` that would hand it to a list, so an
//! `append` that fails has to release the copy (the `errdefer` is declared
//! inside the loop body, which is what scopes it to the iteration). The SQLite
//! stub above covers `getSQLiteIndexes`; the MySQL and PostgreSQL stubs at the
//! bottom cover the other two helpers, each serving the catalog queries its
//! dialect issues, so those sites are verified by the sweep rather than fixed
//! by inspection.

const std = @import("std");
const driver = @import("../sql/driver.zig");
const sql = @import("../sql/builder.zig");
const dialect = @import("../sql/dialect.zig");
const migrate = @import("../sql/schema/migrate.zig");
const graph_mod = @import("../codegen/graph.zig");
const codegen = @import("../codegen/client.zig");
const crud = @import("../crud.zig");
const field = @import("../core/field.zig");
const edge = @import("../core/edge.zig");
const index = @import("../core/index.zig");
const Schema = @import("../core/schema.zig").Schema;
const TypeInfo = graph_mod.TypeInfo;

// ------------------------------------------------------------------
// (a) the CRUD copy path
// ------------------------------------------------------------------

/// Three plain strings and one optional string that is present, so a copy is
/// exactly four `dupe` calls and the sweep can fail each of them.
const CaafNote = Schema("CaafNote", .{
    .table_name = "caaf_note",
    .fields = &.{
        field.Int("tenant_id"),
        field.String("title"),
        field.String("body"),
        field.String("slug"),
        field.String("note").Optional(),
    },
});

const caaf_note_info = graph_mod.fromSchema(CaafNote);
const caaf_note_infos: []const TypeInfo = &.{caaf_note_info};
const CaafNoteService = crud.CrudService(caaf_note_infos, caaf_note_info, "tenant_id");

test "an owned copy through the CRUD path unwinds cleanly when any single allocation fails" {
    const allocator = std.testing.allocator;
    const sqlite_driver = @import("../sql/sqlite.zig");
    const deinitEntity = @import("../codegen/entity.zig").deinitEntity;

    // The entity comes out of the real path — `CrudService.getOwned` over a
    // `:memory:` SQLite database — rather than a hand-built struct, and the
    // database and the client live *outside* the sweep: `getOwned` scans with
    // the client's allocator and copies into the one it is handed, so the swept
    // allocator owns exactly the copy's buffers and nothing else. No driver
    // allocation is in the ledger, so the sweep stays about `ownedCopy`.
    var db = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer db.close();
    try migrate.migrateSchema(allocator, db.asDriver(), caaf_note_infos);

    const Client = codegen.EntityClient(caaf_note_infos, caaf_note_info);
    const client = Client.init(allocator, db.asDriver());
    var svc = CaafNoteService.init(allocator, client);

    const id = try svc.create(.{
        .id = 0,
        .tenant_id = 0,
        .title = "title-alpha",
        .body = "body-bravo",
        .slug = "slug-charlie",
        .note = "note-delta",
    }, 7);

    const Copy = struct {
        fn run(child: std.mem.Allocator, service: *CaafNoteService, note_id: i64) !void {
            var got = (try service.getOwned(child, 7, note_id)) orelse return error.TestUnexpectedResult;
            // The copy's strings belong to `child`: releasing them there is what
            // makes the sweep's ledger the measure of an `ownedCopy` that leaks.
            defer deinitEntity(caaf_note_infos, caaf_note_info, &got, child);
            try std.testing.expectEqualStrings("body-bravo", got.body);
            try std.testing.expectEqualStrings("note-delta", got.note.?);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Copy.run, .{ &svc, id });
}

// ------------------------------------------------------------------
// (b) migration planning
// ------------------------------------------------------------------

const PlanDocBase = Schema("AllocPlanDoc", .{
    .fields = &.{
        field.Int("tenant_id"),
        field.String("title"),
        // A column-level UNIQUE: inline in CREATE TABLE, and invisible to the
        // named-index comparison, which is why the planner has a branch of its
        // own that has to plan the index on a table that already exists.
        field.String("slug").Unique(),
    },
    .indexes = &.{index.Named("idx_alloc_plan_doc_title", &.{"title"})},
});

const PlanTagBase = Schema("AllocPlanTag", .{
    .fields = &.{field.String("label")},
});

// The m2m pair, written out by hand: `Schema(…)` cannot reference a target that
// does not exist yet, and the junction table an m2m edge needs is created out of
// the same step of the plan as the entities' own tables.
const PlanDoc = struct {
    pub const schema_name = PlanDocBase.schema_name;
    pub const table_name = PlanDocBase.table_name;
    pub const pk = PlanDocBase.pk;
    pub const fields = PlanDocBase.fields;
    pub const edges = &.{edge.To("tags", PlanTagBase)};
    pub const indexes = PlanDocBase.indexes;
    pub const policy = PlanDocBase.policy;
    pub const is_view = PlanDocBase.is_view;
    pub const view_sql = PlanDocBase.view_sql;
    pub const soft_delete = PlanDocBase.soft_delete;
};

const PlanTag = struct {
    pub const schema_name = PlanTagBase.schema_name;
    pub const table_name = PlanTagBase.table_name;
    pub const pk = PlanTagBase.pk;
    pub const fields = PlanTagBase.fields;
    pub const edges = &.{edge.To("docs", PlanDocBase)};
    pub const indexes = PlanTagBase.indexes;
    pub const policy = PlanTagBase.policy;
    pub const is_view = PlanTagBase.is_view;
    pub const view_sql = PlanTagBase.view_sql;
    pub const soft_delete = PlanTagBase.soft_delete;
};

const plan_infos = graph_mod.buildGraph(&.{ PlanDoc, PlanTag }).types;

/// A row of a stub catalog: `text[i]` for the string columns a catalog answers
/// and `int[i]` for the integer ones. Both are **slices**, so a row spells out
/// only the columns its dialect's read touches and every position past the end
/// answers NULL — which is also how a driver reports a column the accessor
/// asked for and the result set does not have.
///
/// The positions each dialect reads: SQLite's `table_info` (name, type,
/// notnull, pk at 1/2/3/5) and `index_list` (name, unique at 1/2/4); MySQL's
/// `information_schema.columns` (name, type, `is_nullable` at 0/1/2) and
/// `statistics` (name, `non_unique`, column, `sub_part` at 0..3); PostgreSQL's
/// `information_schema.columns` (same three) and its `pg_index` join, which is
/// the widest at eight columns — `attname` last, at 7.
const StubRow = struct {
    text: []const ?[]const u8 = &.{},
    int: []const ?i64 = &.{},
};

fn stubRowOf(ptr: *anyopaque) *const StubRow {
    return @ptrCast(@alignCast(ptr));
}

/// The fixture's width, which is what a driver reports for a result set: the
/// longer of the two column lists. SQLite's `index_list` read only asks whether
/// there is a column past 4 (the `partial` flag), so a row with the six columns
/// that read uses still answers.
fn stubColumnCount(ptr: *anyopaque) usize {
    const row = stubRowOf(ptr);
    return @max(row.text.len, row.int.len);
}

fn stubColumnName(_: *anyopaque, _: usize) []const u8 {
    return "";
}

fn stubGetBool(ptr: *anyopaque, i: usize) ?bool {
    const row = stubRowOf(ptr);
    if (i >= row.int.len) return null;
    return if (row.int[i]) |n| n != 0 else null;
}

fn stubGetInt(ptr: *anyopaque, i: usize) ?i64 {
    const row = stubRowOf(ptr);
    if (i >= row.int.len) return null;
    return row.int[i];
}

fn stubGetFloat(_: *anyopaque, _: usize) ?f64 {
    return null;
}

fn stubGetText(ptr: *anyopaque, i: usize) ?[]const u8 {
    const row = stubRowOf(ptr);
    if (i >= row.text.len) return null;
    return row.text[i];
}

fn stubGetBlob(_: *anyopaque, _: usize) ?[]const u8 {
    return null;
}

fn stubIsNull(ptr: *anyopaque, i: usize) bool {
    const row = stubRowOf(ptr);
    return (i >= row.text.len or row.text[i] == null) and (i >= row.int.len or row.int[i] == null);
}

const stub_row_vtable = driver.Row.VTable{
    .columnCount = stubColumnCount,
    .columnName = stubColumnName,
    .getBool = stubGetBool,
    .getInt = stubGetInt,
    .getFloat = stubGetFloat,
    .getText = stubGetText,
    .getBlob = stubGetBlob,
    .isNull = stubIsNull,
};

/// The cursor a stub answer is read through. Rows are borrowed from the
/// comptime catalog, so the cursor owns nothing.
const Cursor = struct {
    rows: []const StubRow,
    pos: usize = 0,
};

fn cursorNext(ptr: *anyopaque) ?driver.Row {
    const cursor: *Cursor = @ptrCast(@alignCast(ptr));
    if (cursor.pos >= cursor.rows.len) return null;
    const row: *StubRow = @constCast(&cursor.rows[cursor.pos]);
    cursor.pos += 1;
    return .{ .ptr = row, .vtable = &stub_row_vtable };
}

fn cursorDeinit(_: *anyopaque) void {}

const cursor_vtable = driver.Rows.VTable{ .next = cursorNext, .deinit = cursorDeinit };

/// True when `query_sql` is a `PRAGMA` naming exactly `name`: the quoted
/// identifier is compared whole, so `alloc_plan_doc` does not match the
/// `alloc_plan_doc_alloc_plan_tag` junction table.
fn pragmaNames(query_sql: []const u8, name: []const u8) bool {
    const open = std.mem.indexOfScalar(u8, query_sql, '"') orelse return false;
    const close = std.mem.indexOfScalarPos(u8, query_sql, open + 1, '"') orelse return false;
    return std.mem.eql(u8, query_sql[open + 1 .. close], name);
}

/// A driver with a fixed, comptime catalog. Every answer is a statement the
/// sqlite introspection helpers issue; `unmatched` counts the statements no
/// branch claimed, so a new introspection query cannot be answered "nothing
/// exists" without the sweep failing.
const CatalogStub = struct {
    /// The one table the catalog has columns for. Empty means "nothing exists".
    existing_table: []const u8 = "",
    existing_columns: []const StubRow = &.{},
    /// What `PRAGMA index_list` reports, for any table.
    index_list_rows: []const StubRow = &.{},
    /// What `PRAGMA index_info` reports, for any index.
    index_key_rows: []const StubRow = &.{},
    unmatched: usize = 0,
    queries: usize = 0,
    cursor: Cursor = .{ .rows = &.{} },

    fn asDriver(self: *CatalogStub) driver.Driver {
        return .{ .ptr = self, .vtable = &stub_vtable };
    }

    fn answering(self: *CatalogStub, rows: []const StubRow) driver.Rows {
        self.cursor = .{ .rows = rows };
        return .{ .ptr = &self.cursor, .vtable = &cursor_vtable };
    }
};

fn stubExec(_: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const sql.Value) driver.Error!driver.Result {
    // `planMigrateStatements` is read-only by contract; reaching exec means the
    // contract changed and the stub must stop being trusted.
    return error.ExecFailed;
}

fn sqliteStubQuery(ptr: *anyopaque, _: ?*const driver.ExecutionContext, query_sql: []const u8, _: []const sql.Value) driver.Error!driver.Rows {
    const self: *CatalogStub = @ptrCast(@alignCast(ptr));
    self.queries += 1;
    if (std.mem.indexOf(u8, query_sql, "table_info") != null) {
        if (self.existing_table.len > 0 and pragmaNames(query_sql, self.existing_table)) {
            return self.answering(self.existing_columns);
        }
        return self.answering(&.{});
    }
    if (std.mem.indexOf(u8, query_sql, "index_list") != null) return self.answering(self.index_list_rows);
    if (std.mem.indexOf(u8, query_sql, "index_info") != null) return self.answering(self.index_key_rows);
    self.unmatched += 1;
    return self.answering(&.{});
}

fn stubBeginTx(_: *anyopaque) driver.Error!driver.Tx {
    return error.TxFailed;
}

fn stubClose(_: *anyopaque) void {}

fn sqliteStubDialect(_: *anyopaque) dialect.Dialect {
    return .sqlite;
}

fn stubPing(_: *anyopaque) driver.Error!void {}

fn stubInTransaction(_: *anyopaque) bool {
    return false;
}

fn stubBeginSavepoint(_: *anyopaque, _: []const u8) driver.Error!driver.Tx {
    return error.TxFailed;
}

/// The vtable every stub shares, with the two fields a dialect stub answers
/// differently — the statement shapes it recognises and the dialect it reports
/// — supplied by the caller. The parameters carry `Driver.VTable`'s own field
/// types, so a stub cannot be wired up with the wrong signature.
fn stubVTable(
    comptime query_fn: *const fn (ptr: *anyopaque, ctx: ?*const driver.ExecutionContext, query: []const u8, args: []const sql.Value) driver.Error!driver.Rows,
    comptime dialect_fn: *const fn (ptr: *anyopaque) dialect.Dialect,
) driver.Driver.VTable {
    return .{
        .exec = stubExec,
        .query = query_fn,
        .beginTx = stubBeginTx,
        .close = stubClose,
        .dialect = dialect_fn,
        .ping = stubPing,
        .inTransaction = stubInTransaction,
        .beginSavepoint = stubBeginSavepoint,
    };
}

const stub_vtable = stubVTable(sqliteStubQuery, sqliteStubDialect);

/// The columns `alloc_plan_doc` has once it exists: its id and the two declared
/// fields, nothing else — so the ADD COLUMN branch stays out of the way and the
/// plan is about the table that is there.
const alloc_plan_doc_columns = [_]StubRow{
    .{ .text = &.{ null, "id", "INTEGER", null, null, null }, .int = &.{ null, null, null, 1, null, 1 } },
    .{ .text = &.{ null, "tenant_id", "INTEGER", null, null, null }, .int = &.{ null, null, null, 1, null, 0 } },
    .{ .text = &.{ null, "title", "TEXT", null, null, null }, .int = &.{ null, null, null, 1, null, 0 } },
    .{ .text = &.{ null, "slug", "TEXT", null, null, null }, .int = &.{ null, null, null, 1, null, 0 } },
};

/// One unique index the catalog already has, over `tenant_id` — a column the
/// schema does not declare UNIQUE, so this index satisfies nothing and the
/// planner still has to plan `uq_alloc_plan_doc_slug`. It is readable (its key
/// list comes back below), which is what keeps the column-level UNIQUE branch
/// *live*: an unreadable unique index would make the planner stay silent.
/// `PRAGMA index_list` shape: name at 1, unique at 2, `partial` at 4.
const catalog_unique_index = [_]StubRow{
    .{ .text = &.{ null, "uq_stub_alloc_plan_doc_tenant", null, null, null, null }, .int = &.{ null, null, 1, null, 0, null } },
};

/// Its single key — `PRAGMA index_info` shape: `cid` at 1, column name at 2.
const catalog_unique_index_keys = [_]StubRow{
    .{ .text = &.{ null, null, "tenant_id", null, null, null }, .int = &.{ null, 0, null, null, null, null } },
};

test "planning a migration unwinds cleanly when any single allocation fails" {
    // One catalog, both sides of the planner's existence gates: `alloc_plan_doc`
    // is already there (so `created[i]` is false and the per-column planning —
    // including the index the column-level UNIQUE needs — runs against real
    // introspection), while the tag table and the m2m junction are not (so the
    // CREATE paths run too). The index catalog answers with a readable index
    // whose key list has to be re-read through `PRAGMA index_info`.
    var stub = CatalogStub{
        .existing_table = "alloc_plan_doc",
        .existing_columns = &alloc_plan_doc_columns,
        .index_list_rows = &catalog_unique_index,
        .index_key_rows = &catalog_unique_index_keys,
    };
    const Plan = struct {
        fn run(child: std.mem.Allocator, s: *CatalogStub) !void {
            var plan = try migrate.planMigrateStatements(child, s.asDriver(), plan_infos, .{}, &.{});
            defer migrate.freePlannedStatements(child, &plan);
            // The stub was actually consulted — an unconsulted catalog would
            // make these existence gates vacuous — and every statement the
            // planner asked was one the stub knows the shape of.
            try std.testing.expect(s.queries > 0);
            try std.testing.expectEqual(@as(usize, 0), s.unmatched);

            var declared_index = false;
            var unique_index = false;
            for (plan.items) |statement| {
                // Every column of the existing table is present, so nothing is
                // altered: the plan is the two CREATEs the missing relations
                // need, the junction, and the two indexes.
                try std.testing.expect(std.mem.indexOf(u8, statement.sql, "ALTER TABLE") == null);
                if (std.mem.indexOf(u8, statement.sql, "idx_alloc_plan_doc_title") != null) declared_index = true;
                if (std.mem.indexOf(u8, statement.sql, "uq_alloc_plan_doc_slug") != null) unique_index = true;
            }
            try std.testing.expect(declared_index);
            // The v0.73.0 column-level UNIQUE planning: the catalog's unique
            // index is over `tenant_id`, so the constraint on `slug` is still
            // unkept and gets its own index.
            try std.testing.expect(unique_index);
            // Two entity tables that are missing, the junction (both sides of
            // the symmetric m2m edge reach the junction step and plan the same
            // `CREATE TABLE IF NOT EXISTS` — the second is the no-op the real
            // path executes too), and the two indexes.
            try std.testing.expectEqual(@as(usize, 6), plan.items.len);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Plan.run, .{&stub});
}

// ------------------------------------------------------------------
// (c) the MySQL and PostgreSQL index catalogs
// ------------------------------------------------------------------
//
// `getSQLiteIndexes` is reached through the SQLite stub above, which pins its
// two copy-then-append sites. `getMySQLIndexes` and `getPostgresIndexes` have
// the same two sites, and had no mechanical coverage at all: the sweep's catalog
// answered `table_info`/`index_list`/`index_info` and nothing else. Each stub
// below serves the statements its dialect's helper actually issues — the shapes
// are read off the call sites — so the planner reaches that helper with a
// multi-key index to read and the failing allocator lands inside the copy
// window. `unmatched` is the guard on the other side: a statement neither stub
// recognises is counted, and the case fails rather than letting a new
// introspection query be answered "nothing exists".

/// True when a catalog read is about `table`. Both MySQL and PostgreSQL bind
/// the name (`?` / `$1`) rather than interpolating it, so the stub reads it
/// back out of the argument list: a read about any other table gets the "no
/// such table" answer — the same gate `CatalogStub.existing_table` applies to
/// a SQLite `PRAGMA`, and the reason a second table in a schema under test
/// cannot be told it exists when the catalog has no rows for it.
fn bindsTable(args: []const sql.Value, table: []const u8) bool {
    if (args.len == 0) return false;
    const bound = switch (args[0]) {
        .string => |s| s,
        else => return false,
    };
    return std.mem.eql(u8, bound, table);
}

/// MySQL's catalog: the two statement shapes the planner issues on this
/// dialect, in the order it issues them — the `information_schema.columns`
/// existence/diff read (step 1, then step 2) and the
/// `information_schema.statistics` read `getMySQLIndexes` makes.
const MysqlCatalogStub = struct {
    /// The one table the catalog has rows for.
    existing_table: []const u8 = "",
    columns_rows: []const StubRow = &.{},
    index_rows: []const StubRow = &.{},
    unmatched: usize = 0,
    queries: usize = 0,
    cursor: Cursor = .{ .rows = &.{} },

    fn asDriver(self: *MysqlCatalogStub) driver.Driver {
        return .{ .ptr = self, .vtable = &mysql_stub_vtable };
    }

    fn answering(self: *MysqlCatalogStub, rows: []const StubRow) driver.Rows {
        self.cursor = .{ .rows = rows };
        return .{ .ptr = &self.cursor, .vtable = &cursor_vtable };
    }
};

fn mysqlStubQuery(ptr: *anyopaque, _: ?*const driver.ExecutionContext, query_sql: []const u8, args: []const sql.Value) driver.Error!driver.Rows {
    const self: *MysqlCatalogStub = @ptrCast(@alignCast(ptr));
    self.queries += 1;
    if (std.mem.indexOf(u8, query_sql, "information_schema.columns") != null) {
        return self.answering(if (bindsTable(args, self.existing_table)) self.columns_rows else &.{});
    }
    if (std.mem.indexOf(u8, query_sql, "information_schema.statistics") != null) {
        return self.answering(if (bindsTable(args, self.existing_table)) self.index_rows else &.{});
    }
    self.unmatched += 1;
    return self.answering(&.{});
}

fn mysqlStubDialect(_: *anyopaque) dialect.Dialect {
    return .mysql;
}

const mysql_stub_vtable = stubVTable(mysqlStubQuery, mysqlStubDialect);

/// PostgreSQL's catalog, the same two reads: `information_schema.columns` and
/// the `pg_index`/`pg_class`/`pg_attribute` join whose rows are the widest the
/// stubs serve (eight columns, `attname` last).
const PostgresCatalogStub = struct {
    /// The one table the catalog has rows for.
    existing_table: []const u8 = "",
    columns_rows: []const StubRow = &.{},
    index_rows: []const StubRow = &.{},
    unmatched: usize = 0,
    queries: usize = 0,
    cursor: Cursor = .{ .rows = &.{} },

    fn asDriver(self: *PostgresCatalogStub) driver.Driver {
        return .{ .ptr = self, .vtable = &postgres_stub_vtable };
    }

    fn answering(self: *PostgresCatalogStub, rows: []const StubRow) driver.Rows {
        self.cursor = .{ .rows = rows };
        return .{ .ptr = &self.cursor, .vtable = &cursor_vtable };
    }
};

fn postgresStubQuery(ptr: *anyopaque, _: ?*const driver.ExecutionContext, query_sql: []const u8, args: []const sql.Value) driver.Error!driver.Rows {
    const self: *PostgresCatalogStub = @ptrCast(@alignCast(ptr));
    self.queries += 1;
    if (std.mem.indexOf(u8, query_sql, "information_schema.columns") != null) {
        return self.answering(if (bindsTable(args, self.existing_table)) self.columns_rows else &.{});
    }
    if (std.mem.indexOf(u8, query_sql, "pg_index") != null) {
        return self.answering(if (bindsTable(args, self.existing_table)) self.index_rows else &.{});
    }
    self.unmatched += 1;
    return self.answering(&.{});
}

fn postgresStubDialect(_: *anyopaque) dialect.Dialect {
    return .postgres;
}

const postgres_stub_vtable = stubVTable(postgresStubQuery, postgresStubDialect);

/// The table the MySQL case plans against: it is already in the stub catalog
/// (`created[i]` stays false) with the two-key index the schema declares, so
/// step 2 reaches `getMySQLIndexes` and finds the index it wants.
const MysqlPlanDoc = Schema("AllocMysqlPlanDoc", .{
    .table_name = "alloc_mysql_plan_doc",
    .fields = &.{
        field.Int("tenant_id"),
        field.String("title"),
    },
    .indexes = &.{index.Named("idx_alloc_mysql_plan_doc_pair", &.{ "tenant_id", "title" })},
});

const mysql_plan_infos = graph_mod.buildGraph(&.{MysqlPlanDoc}).types;

/// `information_schema.columns` rows — `column_name`, `data_type`,
/// `is_nullable` at 0/1/2 — covering every column the schema declares, so the
/// plan carries no ALTER.
const mysql_plan_doc_columns = [_]StubRow{
    .{ .text = &.{ "id", "bigint", "NO" } },
    .{ .text = &.{ "tenant_id", "bigint", "NO" } },
    .{ .text = &.{ "title", "varchar", "NO" } },
};

/// `information_schema.statistics` rows — `index_name`, `non_unique`,
/// `column_name`, `sub_part` at 0/1/2/3 — as the query's `ORDER BY index_name,
/// seq_in_index` delivers them. The first is the declared index, in key order;
/// the second is one the schema does not declare, which gives the name loop a
/// second iteration and the key accumulator a second lifecycle. A NULL
/// `sub_part` on every row keeps both key lists comparable, which is what makes
/// the helper read the columns at all.
const mysql_plan_doc_indexes = [_]StubRow{
    .{ .text = &.{ "idx_alloc_mysql_plan_doc_pair", null, "tenant_id", null }, .int = &.{ null, 1 } },
    .{ .text = &.{ "idx_alloc_mysql_plan_doc_pair", null, "title", null } },
    .{ .text = &.{ "idx_stub_mysql_single_key", null, "title", null }, .int = &.{ null, 1 } },
};

/// The PostgreSQL case's table, with the same two-key index — read through the
/// `pg_index` join instead of `information_schema.statistics`.
const PostgresPlanDoc = Schema("AllocPostgresPlanDoc", .{
    .table_name = "alloc_postgres_plan_doc",
    .fields = &.{
        field.Int("tenant_id"),
        field.String("title"),
    },
    .indexes = &.{index.Named("idx_alloc_postgres_plan_doc_pair", &.{ "tenant_id", "title" })},
});

const postgres_plan_infos = graph_mod.buildGraph(&.{PostgresPlanDoc}).types;

/// The same three columns, PostgreSQL-flavoured.
const postgres_plan_doc_columns = [_]StubRow{
    .{ .text = &.{ "id", "bigint", "NO" } },
    .{ .text = &.{ "tenant_id", "bigint", "NO" } },
    .{ .text = &.{ "title", "text", "NO" } },
};

/// `pg_index`-join rows: `relname`, `indisunique`, `indisvalid`, `indpred`,
/// `indnatts <> indnkeyatts`, `indnkeyatts`, `amname`, `attname` at 0..7, in
/// key order. `indnkeyatts` counts both rows of the two-key index, which is
/// what the helper's `seen_keys == expected_keys` check needs — a key list that
/// does not add up is reported as not comparable, and then no key column is
/// read at all.
const postgres_plan_doc_indexes = [_]StubRow{
    .{ .text = &.{ "idx_alloc_postgres_plan_doc_pair", null, null, null, null, null, "btree", "tenant_id" }, .int = &.{ null, 0, 1, 0, 0, 2 } },
    .{ .text = &.{ "idx_alloc_postgres_plan_doc_pair", null, null, null, null, null, "btree", "title" }, .int = &.{ null, 0, 1, 0, 0, 2 } },
    .{ .text = &.{ "idx_stub_postgres_single_key", null, null, null, null, null, "btree", "title" }, .int = &.{ null, 0, 1, 0, 0, 1 } },
};

test "a MySQL index introspection unwinds cleanly when any single allocation fails" {
    var stub = MysqlCatalogStub{
        .existing_table = "alloc_mysql_plan_doc",
        .columns_rows = &mysql_plan_doc_columns,
        .index_rows = &mysql_plan_doc_indexes,
    };
    const Plan = struct {
        fn run(child: std.mem.Allocator, s: *MysqlCatalogStub) !void {
            var plan = try migrate.planMigrateStatements(child, s.asDriver(), mysql_plan_infos, .{}, &.{});
            defer migrate.freePlannedStatements(child, &plan);
            try std.testing.expect(s.queries > 0);
            try std.testing.expectEqual(@as(usize, 0), s.unmatched);

            // The table is there with every column the schema declares, so the
            // only statement is the CREATE TABLE the missing migration version
            // makes the planner emit.
            try std.testing.expectEqual(@as(usize, 1), plan.items.len);
            try std.testing.expect(std.mem.indexOf(u8, plan.items[0].sql, "CREATE TABLE IF NOT EXISTS") != null);
            // The declared index is *in* the catalog, so it is not created
            // again. This is also the assertion that `getMySQLIndexes` was read
            // rather than answered "nothing exists": an empty answer would plan
            // exactly the CREATE INDEX checked for here.
            try std.testing.expect(std.mem.indexOf(u8, plan.items[0].sql, "idx_alloc_mysql_plan_doc_pair") == null);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Plan.run, .{&stub});
}

test "a PostgreSQL index introspection unwinds cleanly when any single allocation fails" {
    var stub = PostgresCatalogStub{
        .existing_table = "alloc_postgres_plan_doc",
        .columns_rows = &postgres_plan_doc_columns,
        .index_rows = &postgres_plan_doc_indexes,
    };
    const Plan = struct {
        fn run(child: std.mem.Allocator, s: *PostgresCatalogStub) !void {
            var plan = try migrate.planMigrateStatements(child, s.asDriver(), postgres_plan_infos, .{}, &.{});
            defer migrate.freePlannedStatements(child, &plan);
            try std.testing.expect(s.queries > 0);
            try std.testing.expectEqual(@as(usize, 0), s.unmatched);

            try std.testing.expectEqual(@as(usize, 1), plan.items.len);
            try std.testing.expect(std.mem.indexOf(u8, plan.items[0].sql, "CREATE TABLE IF NOT EXISTS") != null);
            try std.testing.expect(std.mem.indexOf(u8, plan.items[0].sql, "idx_alloc_postgres_plan_doc_pair") == null);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Plan.run, .{&stub});
}
