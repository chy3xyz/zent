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

/// A row of the stub catalog: `text[i]` for the string columns a `PRAGMA`
/// answers and `int[i]` for the integer ones. Six columns is what the two
/// catalog reads the planner makes need — `table_info` (name, type, notnull,
/// pk at 1/2/3/5) and `index_list` (name, unique at 1/2/4).
const StubRow = struct {
    text: [6]?[]const u8 = @splat(null),
    int: [6]?i64 = @splat(null),
};

fn stubRowOf(ptr: *anyopaque) *const StubRow {
    return @ptrCast(@alignCast(ptr));
}

fn stubColumnCount(_: *anyopaque) usize {
    return 6;
}

fn stubColumnName(_: *anyopaque, _: usize) []const u8 {
    return "";
}

fn stubGetBool(ptr: *anyopaque, i: usize) ?bool {
    if (i >= 6) return null;
    return if (stubRowOf(ptr).int[i]) |n| n != 0 else null;
}

fn stubGetInt(ptr: *anyopaque, i: usize) ?i64 {
    if (i >= 6) return null;
    return stubRowOf(ptr).int[i];
}

fn stubGetFloat(_: *anyopaque, _: usize) ?f64 {
    return null;
}

fn stubGetText(ptr: *anyopaque, i: usize) ?[]const u8 {
    if (i >= 6) return null;
    return stubRowOf(ptr).text[i];
}

fn stubGetBlob(_: *anyopaque, _: usize) ?[]const u8 {
    return null;
}

fn stubIsNull(ptr: *anyopaque, i: usize) bool {
    if (i >= 6) return true;
    const row = stubRowOf(ptr);
    return row.text[i] == null and row.int[i] == null;
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

fn stubQuery(ptr: *anyopaque, _: ?*const driver.ExecutionContext, query_sql: []const u8, _: []const sql.Value) driver.Error!driver.Rows {
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

fn stubDialect(_: *anyopaque) dialect.Dialect {
    return .sqlite;
}

fn stubPing(_: *anyopaque) driver.Error!void {}

fn stubInTransaction(_: *anyopaque) bool {
    return false;
}

fn stubBeginSavepoint(_: *anyopaque, _: []const u8) driver.Error!driver.Tx {
    return error.TxFailed;
}

const stub_vtable = driver.Driver.VTable{
    .exec = stubExec,
    .query = stubQuery,
    .beginTx = stubBeginTx,
    .close = stubClose,
    .dialect = stubDialect,
    .ping = stubPing,
    .inTransaction = stubInTransaction,
    .beginSavepoint = stubBeginSavepoint,
};

/// The columns `alloc_plan_doc` has once it exists: its id and the two declared
/// fields, nothing else — so the ADD COLUMN branch stays out of the way and the
/// plan is about the table that is there.
const alloc_plan_doc_columns = [_]StubRow{
    .{ .text = .{ null, "id", "INTEGER", null, null, null }, .int = .{ null, null, null, 1, null, 1 } },
    .{ .text = .{ null, "tenant_id", "INTEGER", null, null, null }, .int = .{ null, null, null, 1, null, 0 } },
    .{ .text = .{ null, "title", "TEXT", null, null, null }, .int = .{ null, null, null, 1, null, 0 } },
    .{ .text = .{ null, "slug", "TEXT", null, null, null }, .int = .{ null, null, null, 1, null, 0 } },
};

/// One unique index the catalog already has, over `tenant_id` — a column the
/// schema does not declare UNIQUE, so this index satisfies nothing and the
/// planner still has to plan `uq_alloc_plan_doc_slug`. It is readable (its key
/// list comes back below), which is what keeps the column-level UNIQUE branch
/// *live*: an unreadable unique index would make the planner stay silent.
/// `PRAGMA index_list` shape: name at 1, unique at 2, `partial` at 4.
const catalog_unique_index = [_]StubRow{
    .{ .text = .{ null, "uq_stub_alloc_plan_doc_tenant", null, null, null, null }, .int = .{ null, null, 1, null, 0, null } },
};

/// Its single key — `PRAGMA index_info` shape: `cid` at 1, column name at 2.
const catalog_unique_index_keys = [_]StubRow{
    .{ .text = .{ null, null, "tenant_id", null, null, null }, .int = .{ null, 0, null, null, null, null } },
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
