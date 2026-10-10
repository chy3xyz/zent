//! `std.testing.checkAllAllocationFailures` over the owned-assembly paths
//! the sibling sweep (`allocation_failures.zig`) does not reach:
//!
//!   - the CRUD copy path: `CrudService.getOwned` hands a scanned row to
//!     `crud.ownedCopy`, which duplicates one string field at a time and has to
//!     release the copies it already made when a later dupe fails — the
//!     partial-teardown shape where a leak is one `errdefer` away. A JSON
//!     column adds `entity.dupeJsonInto`'s own arena to the same sweep: its
//!     `create`, its buffers and the payload strings are each failable;
//!   - the migration planner: `migrate.planMigrateStatements` builds an ordered
//!     list of statements, each of them its own buffer, out of the same kind of
//!     `Allocator.print`/`dupe` chain;
//!   - the outbox paths: `Outbox.pending` and `Outbox.claim` build an owned
//!     `[]Entry` out of driver rows — one `alloc` plus three string dupes per
//!     row — and `claim`'s MySQL shape wraps the same row reader in a
//!     transaction whose rollback/deinit bookkeeping has to unwind with it;
//!   - the codegen neighbour assembly paths (section (e)): `loadEdgePath`
//!     (the eager loader behind `WithEdge`) and `client.queryTargets*` both
//!     assemble a target read the same way, and `loadEdgePath` parks a scanned
//!     target in a per-parent map before it copies the map into the parents'
//!     edge slices. A failure in between — a missing `__fk` column, the map's
//!     own growth, the append — used to strand that target's duplicated
//!     strings and its JSON arena; both the in-flight guard and the map
//!     teardown are held to the byte ledger here.
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

/// The same copy path with a JSON column: the payload is re-duped by
/// `entity.dupeJsonInto` into a fresh arena (whose `create`, buffers and
/// payload strings are all allocations of the swept allocator), so this sweep
/// fails each of those too and holds the partial-teardown `errdefer`s — the
/// arena's and `ownedCopy`'s string loop — to the byte ledger.
const CaafJsonSettings = struct { theme: []const u8 };

const CaafJsonNote = Schema("CaafJsonNote", .{
    .table_name = "caaf_json_note",
    .fields = &.{
        field.Int("tenant_id"),
        field.String("title"),
        field.JSON("settings", CaafJsonSettings),
    },
});

const caaf_json_note_info = graph_mod.fromSchema(CaafJsonNote);
const caaf_json_note_infos: []const TypeInfo = &.{caaf_json_note_info};
const CaafJsonNoteService = crud.CrudService(caaf_json_note_infos, caaf_json_note_info, "tenant_id");

test "an owned copy with a JSON column unwinds cleanly when any single allocation fails" {
    const allocator = std.testing.allocator;
    const sqlite_driver = @import("../sql/sqlite.zig");
    const deinitEntity = @import("../codegen/entity.zig").deinitEntity;

    var db = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer db.close();
    try migrate.migrateSchema(allocator, db.asDriver(), caaf_json_note_infos);

    const Client = codegen.EntityClient(caaf_json_note_infos, caaf_json_note_info);
    const client = Client.init(allocator, db.asDriver());
    var svc = CaafJsonNoteService.init(allocator, client);

    const id = try svc.create(.{
        .id = 0,
        .tenant_id = 0,
        .title = "title-alpha",
        .settings = .{ .theme = "theme-delta" },
        .json_arena = null,
    }, 7);

    const Copy = struct {
        fn run(child: std.mem.Allocator, service: *CaafJsonNoteService, note_id: i64) !void {
            var got = (try service.getOwned(child, 7, note_id)) orelse return error.TestUnexpectedResult;
            // String field owned by `child`, JSON payload by the arena
            // `dupeJsonInto` created with `child`: one `deinitEntity` frees both.
            defer deinitEntity(caaf_json_note_infos, caaf_json_note_info, &got, child);
            try std.testing.expectEqualStrings("title-alpha", got.title);
            try std.testing.expectEqualStrings("theme-delta", got.settings.theme);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Copy.run, .{ &svc, id });
}

/// The same copy path with an **untyped** `field.JSONValue` document: the
/// payload is a tree of arena-owned nodes whose keys, strings, array backing
/// and object backing are re-duped node-by-node by `entity.dupeJsonDeep`, so
/// this sweep fails each of those allocations too — the recursive copy path the
/// typed-struct sweep above cannot reach.
const CaafJsonValueNote = Schema("CaafJsonValueNote", .{
    .table_name = "caaf_json_value_note",
    .fields = &.{
        field.Int("tenant_id"),
        field.String("title"),
        field.JSONValue("payload"),
    },
});

const caaf_json_value_note_info = graph_mod.fromSchema(CaafJsonValueNote);
const caaf_json_value_note_infos: []const TypeInfo = &.{caaf_json_value_note_info};
const CaafJsonValueNoteService = crud.CrudService(caaf_json_value_note_infos, caaf_json_value_note_info, "tenant_id");

test "an owned copy with an untyped JSONValue document unwinds cleanly when any single allocation fails" {
    const allocator = std.testing.allocator;
    const sqlite_driver = @import("../sql/sqlite.zig");
    const deinitEntity = @import("../codegen/entity.zig").deinitEntity;

    var db = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer db.close();
    try migrate.migrateSchema(allocator, db.asDriver(), caaf_json_value_note_infos);

    const Client = codegen.EntityClient(caaf_json_value_note_infos, caaf_json_value_note_info);
    const client = Client.init(allocator, db.asDriver());
    var svc = CaafJsonValueNoteService.init(allocator, client);

    // A nested object + array, so the copied document is more than one node.
    var payload_arena = std.heap.ArenaAllocator.init(allocator);
    defer payload_arena.deinit();
    const payload = try std.json.parseFromSliceLeaky(
        std.json.Value,
        payload_arena.allocator(),
        "{\"theme\":\"theme-delta\",\"tags\":[\"alpha\",\"bravo\"]}",
        .{},
    );
    const id = try svc.create(.{
        .id = 0,
        .tenant_id = 0,
        .title = "title-alpha",
        .payload = payload,
        .json_arena = null,
    }, 7);

    const Copy = struct {
        fn run(child: std.mem.Allocator, service: *CaafJsonValueNoteService, note_id: i64) !void {
            var got = (try service.getOwned(child, 7, note_id)) orelse return error.TestUnexpectedResult;
            defer deinitEntity(caaf_json_value_note_infos, caaf_json_value_note_info, &got, child);
            try std.testing.expectEqualStrings("title-alpha", got.title);
            try std.testing.expectEqualStrings("theme-delta", got.payload.object.get("theme").?.string);
            try std.testing.expectEqual(@as(usize, 2), got.payload.object.get("tags").?.array.items.len);
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
/// `names` is the column-name list, for the readers that address a column by
/// name rather than by position (`scan.findColumnIndex(row, "__fk")` in the
/// eager loader). It is empty for the catalog fixtures, whose reads are all
/// positional.
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
    names: []const []const u8 = &.{},
};

fn stubRowOf(ptr: *anyopaque) *const StubRow {
    return @ptrCast(@alignCast(ptr));
}

/// The fixture's width, which is what a driver reports for a result set: the
/// longest of the three column lists (the neighbours' rows name a trailing
/// `__fk` column the value lists do not carry). SQLite's `index_list` read only
/// asks whether there is a column past 4 (the `partial` flag), so a row with
/// the six columns that read uses still answers.
fn stubColumnCount(ptr: *anyopaque) usize {
    const row = stubRowOf(ptr);
    return @max(@max(row.text.len, row.int.len), row.names.len);
}

fn stubColumnName(ptr: *anyopaque, i: usize) []const u8 {
    const row = stubRowOf(ptr);
    if (i >= row.names.len) return "";
    return row.names[i];
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

// ------------------------------------------------------------------
// (d) the outbox pending/claim paths
// ------------------------------------------------------------------
//
// `Outbox.pending` and `Outbox.claim` assemble an owned `[]Entry` out of
// driver rows: one `alloc` for the slice plus three string dupes per row.
// `pending` runs behind the real query builder (the client's allocator scans
// the fixture rows, so the swept ledger holds only `pending`'s own copy
// loop — and its first allocation is a plain `alloc`, fail-loud, unlike
// `Builder.init`), `claim` reads the RETURNING/SELECT rows through
// `collectRows`, and the MySQL shape wraps the same reader in a transaction
// whose `errdefer freeEntries` / `errdefer rollback` / `defer tx.deinit`
// have to interleave around it. The stub below serves fixed rows to all
// three and records which transaction lifecycle hooks ran, so the sweep
// can hold that interleaving to the byte ledger.

const outbox_mod = @import("../outbox.zig");

const outbox_infos = graph_mod.buildGraph(&.{outbox_mod.OutboxMessage}).types;
const OutboxOps = outbox_mod.Outbox(outbox_infos, outbox_mod.info);
const OutboxRootClient = codegen.Client(outbox_infos);

/// The minimal `anytype` client `claim` accepts (the shape outbox.zig's own
/// step-failure test pins): just the driver.
const OutboxDriverClient = struct { driver: driver.Driver };

/// Outbox rows in the 7-column shape `claim` reads back: id, aggregate_type,
/// aggregate_id, event_type, payload, attempts, created_at — integers at
/// 0/2/5/6, text at 1/3/4.
const outbox_claim_rows = [_]StubRow{
    .{
        .text = &.{ null, "product", null, "product.created", "{\"id\":1}", null, null },
        .int = &.{ 1, null, 1, null, null, 0, 1000 },
    },
    .{
        .text = &.{ null, "product", null, "product.updated", "{\"id\":2}", null, null },
        .int = &.{ 2, null, 2, null, null, 0, 2000 },
    },
};

/// The same rows in the 10-column shape the generated SELECT for
/// `outbox_message` projects: id, aggregate_type, aggregate_id, event_type,
/// payload, status, attempts, created_at, published_at, claimed_at (NULL —
/// both text and int are absent, so `isNull` holds).
const outbox_pending_rows = [_]StubRow{
    .{
        .text = &.{ null, "product", null, "product.created", "{\"id\":1}", "pending", null, null, null, null },
        .int = &.{ 1, null, 1, null, null, null, 0, 1000, 0, null },
    },
    .{
        .text = &.{ null, "product", null, "product.updated", "{\"id\":2}", "pending", null, null, null, null },
        .int = &.{ 2, null, 2, null, null, null, 0, 2000, 0, null },
    },
};

/// A driver serving fixed outbox rows. `claim`'s SQLite shape reads them
/// through `driver.query`, the MySQL shape through `tx.query` (the handle
/// borrows this same driver), and `pending` through the real query builder
/// over `makeClient`. The rows are borrowed from the comptime catalog like
/// the planner fixtures, so the stub itself never allocates and the swept
/// ledger holds only the outbox code's own allocations.
const OutboxStub = struct {
    rows: []const StubRow = &.{},
    driver_dialect: dialect.Dialect = .sqlite,
    /// What `exec` answers. Defaults are the "one row written, no key to
    /// report" shape the read paths assume; the write paths below raise
    /// `exec_last_insert_id` for the MySQL create branch, which reads the key
    /// from the driver's report rather than from a RETURNING row.
    exec_rows_affected: usize = 1,
    exec_last_insert_id: ?i64 = null,
    cursor: Cursor = .{ .rows = &.{} },
    tx_begun: bool = false,
    tx_committed: bool = false,
    tx_rolled_back: bool = false,
    tx_deinit_count: usize = 0,

    fn asDriver(self: *OutboxStub) driver.Driver {
        return .{ .ptr = self, .vtable = &outbox_stub_vtable };
    }

    fn answering(self: *OutboxStub, rows: []const StubRow) driver.Rows {
        self.cursor = .{ .rows = rows };
        return .{ .ptr = &self.cursor, .vtable = &cursor_vtable };
    }

    /// The transaction handle `claim`'s MySQL shape works through: query and
    /// exec delegate to this same stub driver, and the lifecycle fns only
    /// record what ran — an all-pass transaction, so the failure the sweep
    /// injects is always an allocation inside the outbox code itself.
    fn txHandle(self: *OutboxStub) driver.Tx {
        self.tx_begun = true;
        return .{
            .inner = self.asDriver(),
            .commitFn = txCommit,
            .rollbackFn = txRollback,
            .deinitFn = txDeinit,
            .ptr = self,
        };
    }

    fn txCommit(ptr: *anyopaque) driver.Error!void {
        const self: *OutboxStub = @ptrCast(@alignCast(ptr));
        self.tx_committed = true;
    }

    fn txRollback(ptr: *anyopaque) driver.Error!void {
        const self: *OutboxStub = @ptrCast(@alignCast(ptr));
        self.tx_rolled_back = true;
    }

    fn txDeinit(ptr: *anyopaque) void {
        const self: *OutboxStub = @ptrCast(@alignCast(ptr));
        self.tx_deinit_count += 1;
    }

    fn resetLifecycle(self: *OutboxStub) void {
        self.tx_begun = false;
        self.tx_committed = false;
        self.tx_rolled_back = false;
        self.tx_deinit_count = 0;
    }
};

fn outboxStubExec(ptr: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const sql.Value) driver.Error!driver.Result {
    const self: *OutboxStub = @ptrCast(@alignCast(ptr));
    return .{ .rows_affected = self.exec_rows_affected, .last_insert_id = self.exec_last_insert_id };
}

fn outboxStubQuery(ptr: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const sql.Value) driver.Error!driver.Rows {
    const self: *OutboxStub = @ptrCast(@alignCast(ptr));
    return self.answering(self.rows);
}

fn outboxStubBeginTx(ptr: *anyopaque) driver.Error!driver.Tx {
    const self: *OutboxStub = @ptrCast(@alignCast(ptr));
    return self.txHandle();
}

fn outboxStubDialect(ptr: *anyopaque) dialect.Dialect {
    const self: *OutboxStub = @ptrCast(@alignCast(ptr));
    return self.driver_dialect;
}

const outbox_stub_vtable = driver.Driver.VTable{
    .exec = outboxStubExec,
    .query = outboxStubQuery,
    .beginTx = outboxStubBeginTx,
    .close = stubClose,
    .dialect = outboxStubDialect,
    .ping = stubPing,
    .inTransaction = stubInTransaction,
    .beginSavepoint = stubBeginSavepoint,
};

test "outbox.pending unwinds cleanly when any single allocation fails" {
    const allocator = std.testing.allocator;

    // The failing dupe of a later row must release the strings of every row
    // before it — the leak the sweep exists for (the pre-fix `pending` freed
    // only the slice and lost the copies already made).
    var stub = OutboxStub{ .rows = &outbox_pending_rows };
    const root = codegen.makeClient(outbox_infos, allocator, stub.asDriver());

    const Pending = struct {
        fn run(child: std.mem.Allocator, client: OutboxRootClient) !void {
            const entries = try OutboxOps.pending(child, client, 10);
            defer OutboxOps.freeEntries(child, entries);
            try std.testing.expectEqual(@as(usize, 2), entries.len);
            try std.testing.expectEqualStrings("product.created", entries[0].event_type);
            try std.testing.expectEqual(@as(i64, 2000), entries[1].created_at);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Pending.run, .{root});
}

test "outbox.claim (SQLite shape) unwinds cleanly when any single allocation fails" {
    const allocator = std.testing.allocator;

    // One statement, no transaction: `claim` reads the RETURNING rows through
    // `collectRows`, whose per-iteration `errdefer`s release the three dupes
    // of the row that failed and whose outer `errdefer` releases every
    // completed row before the slice itself.
    var stub = OutboxStub{ .rows = &outbox_claim_rows, .driver_dialect = .sqlite };

    const Claim = struct {
        fn run(child: std.mem.Allocator, client: OutboxDriverClient) !void {
            const entries = try OutboxOps.claim(child, client, 10);
            defer OutboxOps.freeEntries(child, entries);
            try std.testing.expectEqual(@as(usize, 2), entries.len);
            try std.testing.expectEqual(@as(i64, 1), entries[0].id);
            try std.testing.expectEqual(@as(i64, 2), entries[1].id);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Claim.run, .{OutboxDriverClient{ .driver = stub.asDriver() }});
}

test "outbox.claim (MySQL transaction shape) unwinds cleanly when any single allocation fails" {
    const allocator = std.testing.allocator;

    // No UPDATE ... RETURNING on this dialect: `claim` reserves the rows
    // inside a transaction — `beginTx`, `tx.query` (the same fixture rows),
    // one `tx.exec` per row, `tx.commit` — so a failure anywhere in the
    // reader has to unwind through `errdefer tx.rollback` and
    // `defer tx.deinit` around `collectRows`' own teardown, each exactly
    // once, with no commit recorded and no entry left behind.
    var stub = OutboxStub{ .rows = &outbox_claim_rows, .driver_dialect = .mysql };

    const ClaimTx = struct {
        fn run(child: std.mem.Allocator, client: OutboxDriverClient, s: *OutboxStub) !void {
            s.resetLifecycle();
            const entries = try OutboxOps.claim(child, client, 10);
            defer OutboxOps.freeEntries(child, entries);
            try std.testing.expectEqual(@as(usize, 2), entries.len);
            // A completing run reserved and committed the batch, and the
            // handle was deinit'd exactly once without a rollback.
            try std.testing.expect(s.tx_begun);
            try std.testing.expect(s.tx_committed);
            try std.testing.expect(!s.tx_rolled_back);
            try std.testing.expectEqual(@as(usize, 1), s.tx_deinit_count);
        }
    };
    try std.testing.checkAllAllocationFailures(
        allocator,
        ClaimTx.run,
        .{ OutboxDriverClient{ .driver = stub.asDriver() }, &stub },
    );
}

// ------------------------------------------------------------------
// (f) the outbox write paths
// ------------------------------------------------------------------
//
// `enqueue`, `markPublished` / `markFailed` / `requeue`, `requeueStale` and
// `dispatch` are the write half of the outbox. Unlike the read paths above,
// every allocation they make goes through the *generated builder's* allocator
// — `CreateBuilder.saveInternal`'s `InsertBuilder.initCapacity`
// (`codegen/create.zig:396`, `:497`), the entity `UpdateBuilder`'s
// `sql.UpdateBuilder.initCapacity` (`codegen/update_delete.zig:748`) and
// `requeueStale`'s own `UpdateBuilder.initCapacity` (`src/outbox.zig:276`) —
// which is the client's allocator, not the `allocator` argument the outbox
// entry points carry (three of them ignore that argument entirely). So the
// client has to be built *inside* the swept run, on the failing allocator;
// building it outside would leave the ledger empty and the sweep vacuous.
//
// Until `initCapacity` existed those call sites went through the
// OOM-swallowing `InsertBuilder.init` / `UpdateBuilder.init` factories, whose
// empty fallback lists re-raised the failure on the next append — which is
// why the swallow was invisible in these sweeps and why the preallocation
// itself could not be failed. With the fallible constructors the two
// preallocations (`Builder.initCapacity`'s SQL buffer and args array) are
// counted points, and a failure there unwinds through the builder's own
// `errdefer`.
//
// No hooks and no interceptors are registered: an interceptor collapses a
// failing chain into `error.InterceptFailed` (`runInterceptors`' documented
// contract), and a failing *after*-hook is swallowed with a warn, so either
// would turn an injected `OutOfMemory` into a different, non-OOM outcome and
// the sweep would report it as a defect rather than covering one.
//
// The `enqueue` case found a real leak on its first run: `saveInternal` built
// `entity` and filled it field by field after the statement, but the caller
// only receives it through `return entity`, so a failure in the field-copy
// loop (or the junction inserts after it) stranded every string already duped
// into the row plus its JSON arena. The sweep failed at `fail_index 17/20`
// with 7 bytes outstanding — the first field's `product` — and the fix is the
// `errdefer deinitEntity(…)` now sitting at `codegen/create.zig:375`.

/// Sweep `run` over every allocation point, after proving it has one.
///
/// `checkAllAllocationFailures` fails silently on a run that makes *no*
/// allocation: it counts zero points, loops zero times and passes. The write
/// paths above are exactly where that trap sits — a case that built its client
/// on the backing allocator would cover nothing while looking green. The probe
/// run below trips that before the sweep starts.
fn sweepRun(comptime run: anytype, args: anytype) !void {
    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try @call(.auto, run, .{probe.allocator()} ++ args);
    try std.testing.expect(probe.alloc_index > 0);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, run, args);
}

/// The row the `RETURNING "id"` path of `CreateBuilder.saveInternal` reads
/// back: one integer column, the inserted primary key. `enqueue` returns it.
const outbox_returning_row = [_]StubRow{
    .{ .int = &.{42} },
};

/// Two `RETURNING "id"` rows, the wide shape `BulkInsertBuilder.saveInternal`
/// reads when a chunk inserted two rows.
const outbox_bulk_returning_rows = [_]StubRow{
    .{ .int = &.{1} },
    .{ .int = &.{2} },
};

test "outbox.enqueue (RETURNING shape) unwinds cleanly when any single allocation fails" {
    // The RETURNING branch of `saveInternal`: the generated `Create`,
    // `setFieldValue`'s value list, the INSERT's own columns/rows, `takeQuery`
    // and the `RETURNING` suffix buffer, then the entity's field copies. A
    // failure anywhere has to release the builder and leave `deinitEntity` the
    // only remaining owner of the row.
    var stub = OutboxStub{ .rows = &outbox_returning_row, .driver_dialect = .sqlite };

    const Enqueue = struct {
        fn run(child: std.mem.Allocator, s: *OutboxStub) !void {
            var no_remap = NoRemap{ .inner = child };
            const swept = no_remap.asAllocator();
            const client = codegen.makeClient(outbox_infos, swept, s.asDriver());
            const id = try OutboxOps.enqueue(client, 1000, .{
                .aggregate_type = "product",
                .aggregate_id = 1,
                .event_type = "product.created",
                .payload = "{\"id\":1}",
            });
            try std.testing.expectEqual(@as(i64, 42), id);
        }
    };
    try sweepRun(Enqueue.run, .{&stub});
}

test "outbox.enqueue (MySQL key shape) unwinds cleanly when any single allocation fails" {
    // MySQL has no `RETURNING`, so `saveInternal` takes its other branch: the
    // same builder assembly, then `driver.exec` and the key read out of the
    // driver's `last_insert_id` report. The pre-check, the statement and the
    // entity assembly are the same; what differs is the tail the sweep now
    // covers on both sides.
    var stub = OutboxStub{ .driver_dialect = .mysql, .exec_last_insert_id = 42 };

    const Enqueue = struct {
        fn run(child: std.mem.Allocator, s: *OutboxStub) !void {
            var no_remap = NoRemap{ .inner = child };
            const swept = no_remap.asAllocator();
            const client = codegen.makeClient(outbox_infos, swept, s.asDriver());
            const id = try OutboxOps.enqueue(client, 1000, .{
                .aggregate_type = "product",
                .aggregate_id = 1,
                .event_type = "product.created",
                .payload = "{\"id\":1}",
            });
            try std.testing.expectEqual(@as(i64, 42), id);
        }
    };
    try sweepRun(Enqueue.run, .{&stub});
}

test "outbox bulk insert (RETURNING shape) unwinds cleanly when any single allocation fails" {
    // `BulkInsertBuilder.saveInternal`'s assembly: the batch's own list of
    // rows, the per-row `Value` lists, the shared `columns` list, the flattened
    // `chunk_values` buffer and the `MultiInsert` statement with its RETURNING
    // tail, then the id list. One chunk, two rows, so the sweep walks the
    // multi-row path rather than the single-row one.
    var stub = OutboxStub{ .rows = &outbox_bulk_returning_rows, .driver_dialect = .sqlite };

    const Bulk = struct {
        /// `init` already parks one empty row, so the first row is filled
        /// without a `Next()`; `Next()` starts the second.
        fn setRow(b: anytype) !void {
            _ = try b.setFieldValue("aggregate_type", "product");
            _ = try b.setFieldValue("aggregate_id", 1);
            _ = try b.setFieldValue("event_type", "product.created");
            _ = try b.setFieldValue("payload", "{\"id\":1}");
            _ = try b.setFieldValue("status", "pending");
            _ = try b.setFieldValue("attempts", 0);
            _ = try b.setFieldValue("created_at", 1000);
            _ = try b.setFieldValue("published_at", 0);
        }

        fn run(child: std.mem.Allocator, s: *OutboxStub) !void {
            var no_remap = NoRemap{ .inner = child };
            const swept = no_remap.asAllocator();
            const client = codegen.makeClient(outbox_infos, swept, s.asDriver());
            var b = try client.outbox_message.BulkInsert();
            defer b.deinit();
            try setRow(&b);
            _ = try b.Next();
            try setRow(&b);
            var ids = try b.Save();
            defer ids.deinit();
            try std.testing.expectEqual(@as(usize, 2), ids.items.len);
            try std.testing.expectEqual(@as(i64, 1), ids.items[0]);
            try std.testing.expectEqual(@as(i64, 2), ids.items[1]);
        }
    };
    try sweepRun(Bulk.run, .{&stub});
}

test "outbox bulk insert (MySQL per-row shape) unwinds cleanly when any single allocation fails" {
    // MySQL's bulk path sends one single-row `MultiInsert` per row and reads
    // each id from that statement's `last_insert_id` — the branch that refuses
    // the `base + i` fabrication. The stub answers the same key for every row
    // (it has one fixed `exec` result), which is enough for the ledger: what
    // the sweep covers is the per-row builder/statement/append teardown.
    var stub = OutboxStub{ .driver_dialect = .mysql, .exec_last_insert_id = 42 };

    const Bulk = struct {
        fn setRow(b: anytype) !void {
            _ = try b.setFieldValue("aggregate_type", "product");
            _ = try b.setFieldValue("aggregate_id", 1);
            _ = try b.setFieldValue("event_type", "product.created");
            _ = try b.setFieldValue("payload", "{\"id\":1}");
            _ = try b.setFieldValue("status", "pending");
            _ = try b.setFieldValue("attempts", 0);
            _ = try b.setFieldValue("created_at", 1000);
            _ = try b.setFieldValue("published_at", 0);
        }

        fn run(child: std.mem.Allocator, s: *OutboxStub) !void {
            var no_remap = NoRemap{ .inner = child };
            const swept = no_remap.asAllocator();
            const client = codegen.makeClient(outbox_infos, swept, s.asDriver());
            var b = try client.outbox_message.BulkInsert();
            defer b.deinit();
            try setRow(&b);
            _ = try b.Next();
            try setRow(&b);
            var ids = try b.Save();
            defer ids.deinit();
            try std.testing.expectEqual(@as(usize, 2), ids.items.len);
            try std.testing.expectEqual(@as(i64, 42), ids.items[0]);
            try std.testing.expectEqual(@as(i64, 42), ids.items[1]);
        }
    };
    try sweepRun(Bulk.run, .{&stub});
}

test "outbox.markPublished unwinds cleanly when any single allocation fails" {
    // The entity `Update` path (`update_delete.zig:748`): three SET values, one
    // WHERE predicate, the `UpdateBuilder.initCapacity` preallocation and the
    // rendered statement. `claimed_at` is set to NULL, so an optional field's
    // value travels through the same list as the two strings.
    var stub = OutboxStub{};

    const Mark = struct {
        fn run(child: std.mem.Allocator, s: *OutboxStub) !void {
            var no_remap = NoRemap{ .inner = child };
            const swept = no_remap.asAllocator();
            const client = codegen.makeClient(outbox_infos, swept, s.asDriver());
            try OutboxOps.markPublished(swept, client, 7, 2000);
        }
    };
    try sweepRun(Mark.run, .{&stub});
}

test "outbox.markFailed unwinds cleanly when any single allocation fails" {
    // Same entity UPDATE as `markPublished` with a different SET list
    // (`status`, the integer `attempts`, `claimed_at`), so the value shapes and
    // the arg list it renders are a second, independent pass.
    var stub = OutboxStub{};

    const Mark = struct {
        fn run(child: std.mem.Allocator, s: *OutboxStub) !void {
            var no_remap = NoRemap{ .inner = child };
            const swept = no_remap.asAllocator();
            const client = codegen.makeClient(outbox_infos, swept, s.asDriver());
            try OutboxOps.markFailed(swept, client, 7, 4);
        }
    };
    try sweepRun(Mark.run, .{&stub});
}

test "outbox.requeue unwinds cleanly when any single allocation fails" {
    var stub = OutboxStub{};

    const Mark = struct {
        fn run(child: std.mem.Allocator, s: *OutboxStub) !void {
            var no_remap = NoRemap{ .inner = child };
            const swept = no_remap.asAllocator();
            const client = codegen.makeClient(outbox_infos, swept, s.asDriver());
            try OutboxOps.requeue(swept, client, 7, 4);
        }
    };
    try sweepRun(Mark.run, .{&stub});
}

test "outbox.requeueStale unwinds cleanly when any single allocation fails" {
    // `requeueStale` owns its `UpdateBuilder` outright (`src/outbox.zig:276`):
    // two SET values, the `status` predicate, and — below `older_than_secs >
    // 0` — the OR of `claimed_at IS NULL` and `claimed_at < cutoff`, whose two
    // borrowed predicate leaves have to stay alive until the statement is
    // rendered. The age branch is live here (`300`), which is the shape the
    // sweeper actually runs.
    var stub = OutboxStub{};

    const RequeueStale = struct {
        fn run(child: std.mem.Allocator, s: *OutboxStub) !void {
            var no_remap = NoRemap{ .inner = child };
            const swept = no_remap.asAllocator();
            const client = codegen.makeClient(outbox_infos, swept, s.asDriver());
            const n = try OutboxOps.requeueStale(swept, client, 300);
            try std.testing.expectEqual(@as(usize, 1), n);
        }
    };
    try sweepRun(RequeueStale.run, .{&stub});
}

test "outbox.dispatch (success path) unwinds cleanly when any single allocation fails" {
    // The whole at-least-once loop over a claimed batch: `claim`'s row reader
    // (the fixture rows through `collectRows`), then one `markPublished` per
    // entry — the entity UPDATE again, now driven from a loop whose frame also
    // owns the claimed slice. The publisher succeeds, so the tail under test is
    // the publish-and-mark half.
    var stub = OutboxStub{ .rows = &outbox_claim_rows, .driver_dialect = .sqlite };

    const Dispatch = struct {
        fn publish(_: ?*anyopaque, _: outbox_mod.Entry) anyerror!void {}

        fn run(child: std.mem.Allocator, s: *OutboxStub) !void {
            var no_remap = NoRemap{ .inner = child };
            const swept = no_remap.asAllocator();
            const client = codegen.makeClient(outbox_infos, swept, s.asDriver());
            const n = try OutboxOps.dispatch(swept, client, 3000, .{ .call = publish }, 10, 3);
            try std.testing.expectEqual(@as(usize, 2), n);
        }
    };
    try sweepRun(Dispatch.run, .{&stub});
}

test "outbox.dispatch (retry path) unwinds cleanly when any single allocation fails" {
    // The failure half of the same loop: every publish fails, so each entry is
    // requeued with an incremented attempt count and the per-row error never
    // leaves the loop. `dispatched` stays 0 and the claimed slice is freed on
    // every unwind of the requeue that follows it.
    var stub = OutboxStub{ .rows = &outbox_claim_rows, .driver_dialect = .sqlite };

    const Dispatch = struct {
        fn publish(_: ?*anyopaque, _: outbox_mod.Entry) anyerror!void {
            return error.PublisherDown;
        }

        fn run(child: std.mem.Allocator, s: *OutboxStub) !void {
            var no_remap = NoRemap{ .inner = child };
            const swept = no_remap.asAllocator();
            const client = codegen.makeClient(outbox_infos, swept, s.asDriver());
            const n = try OutboxOps.dispatch(swept, client, 3000, .{ .call = publish }, 10, 3);
            try std.testing.expectEqual(@as(usize, 0), n);
        }
    };
    try sweepRun(Dispatch.run, .{&stub});
}

// ------------------------------------------------------------------
// (e) the codegen neighbour assembly paths
// ------------------------------------------------------------------
//
// `loadEdgePath` — the eager loader behind `QueryBuilder.WithEdge`, which
// `All`/`First` run once the parent rows are scanned — and
// `client.queryTargets*` — the reader behind `EntityClient.QueryEdge` — share
// one assembly: a target read contract, a `sql.Builder`, a
// `graph_neighbors.appendSetNeighborsFiltered` call, then a positional scan of
// every returned row into an owned entity. Both used `sql.Builder.init`, the
// *swallowing* shape that absorbs an `OutOfMemory` and falls back to empty
// lists; the convergence to `initCapacity` (`codegen/query.zig:302`,
// `codegen/client.zig:751`) replaced it with a failure the caller propagates.
//
// What these cases pin is the assembly's **ownership**, not the swallow: with
// `init` the sweep passes too (measured), because the very next write into the
// fallback's empty buffer re-raises the `OutOfMemory` that `init` absorbed, so
// the same fail index is covered either way. The eager loader's per-parent map
// is where the bytes actually went missing — a target scanned but not yet
// appended, or a whole map list left behind on a failure — and the sweep below
// is what found it; `graph_neighbors.appendSetNeighborsFiltered`'s own output
// is a separate case in the sibling read sweep.
//
// The stub serves the statements a traversal issues — the parent SELECT and
// the neighbour SELECT — out of borrowed rows (`StubRow`), so it allocates
// nothing and the swept ledger holds only the codegen path's own allocations.
// `NoRemap` is the same `remap`-declining adapter the joined-build sweep
// carries (kept as a local copy here; a test-only file is not imported into
// another test root at the top level): a list growth that remaps in place
// counts no allocation, which is what makes the sweep red on Linux and green
// on macOS, so every growth is forced through `alignedAlloc` + copy.

const entity_mod = @import("../codegen/entity.zig");

/// A pass-through allocator whose `remap` always declines; see the section
/// comment above and `codegen/query.zig`'s joined-build sweep for the same
/// adapter.
const NoRemap = struct {
    inner: std.mem.Allocator,

    fn asAllocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.inner.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, alignment, ra);
    }
};

/// A parent/child pair with an o2m `To` edge, so the neighbour SQL keeps the
/// FK on the target (`parent_id IN (…)`) — the shape
/// `appendSetNeighborsFiltered` emits for a first eager level, and the one
/// `queryTargets` reads.
const CaafEdgeChild = Schema("CaafEdgeChild", .{
    .table_name = "caaf_edge_child",
    .fields = &.{ field.Int("parent_id"), field.String("body") },
});

const CaafEdgeParent = Schema("CaafEdgeParent", .{
    .table_name = "caaf_edge_parent",
    .fields = &.{field.String("name")},
    .edges = &.{edge.To("children", CaafEdgeChild).Field("parent_id")},
});

const caaf_edge_infos: []const TypeInfo = graph_mod.buildGraph(&.{ CaafEdgeParent, CaafEdgeChild }).types;
const caaf_edge_parent_info = graph_mod.fromSchema(CaafEdgeParent);
const caaf_edge_child_info = graph_mod.fromSchema(CaafEdgeChild);

/// Two parent rows in the order the generated SELECT projects the parent's own
/// columns: `id`, `name`. Two, not one, so the transfer loop below runs its
/// `dupe` a second time *after* the first parent's list was emptied — the
/// failure that would double free the first parent's edge slice if the emptied
/// list were still walked by the map teardown.
const caaf_edge_parent_rows = [_]StubRow{
    .{ .names = &.{ "id", "name" }, .text = &.{ null, "parent-one" }, .int = &.{ 1, null } },
    .{ .names = &.{ "id", "name" }, .text = &.{ null, "parent-two" }, .int = &.{ 2, null } },
};

/// Three child rows, in the neighbour projection's order: the target's columns
/// in field order (`id`, `parent_id`, `body`) followed by the computed `__fk` —
/// for an o2m edge that is the FK value, i.e. the parent id, which is what
/// tells the eager loader which parent each row belongs to. Two rows land on
/// parent 1 and one on parent 2, so the per-parent map holds two lists with
/// different lengths. The trailing name is load-bearing: `loadEdgePath` finds
/// the column with `findColumnIndex(row, "__fk")`, so a fixture without `names`
/// would fail the lookup rather than the sweep.
const caaf_edge_child_rows = [_]StubRow{
    .{ .names = &.{ "id", "parent_id", "body", "__fk" }, .text = &.{ null, null, "first", null }, .int = &.{ 10, 1, null, 1 } },
    .{ .names = &.{ "id", "parent_id", "body", "__fk" }, .text = &.{ null, null, "second", null }, .int = &.{ 11, 1, null, 1 } },
    .{ .names = &.{ "id", "parent_id", "body", "__fk" }, .text = &.{ null, null, "only", null }, .int = &.{ 12, 2, null, 2 } },
};

/// A driver serving both statements of a neighbour traversal: the one naming
/// `target_table` gets the neighbour rows, the one naming `parent_table` the
/// parent rows. `unmatched` counts a statement neither name claims, so a
/// changed projection cannot silently be answered "no rows" and pass.
const NeighborStub = struct {
    parent_table: []const u8,
    target_table: []const u8,
    parent_rows: []const StubRow = &.{},
    target_rows: []const StubRow = &.{},
    unmatched: usize = 0,
    cursor: Cursor = .{ .rows = &.{} },

    fn asDriver(self: *NeighborStub) driver.Driver {
        return .{ .ptr = self, .vtable = &neighbor_stub_vtable };
    }

    fn answering(self: *NeighborStub, rows: []const StubRow) driver.Rows {
        self.cursor = .{ .rows = rows };
        return .{ .ptr = &self.cursor, .vtable = &cursor_vtable };
    }
};

fn neighborStubQuery(ptr: *anyopaque, _: ?*const driver.ExecutionContext, query_sql: []const u8, _: []const sql.Value) driver.Error!driver.Rows {
    const self: *NeighborStub = @ptrCast(@alignCast(ptr));
    // The target match comes first: its statement names only the target, but a
    // junction-shaped edge would name both tables, and the narrower match is
    // the one the traversal is asking about.
    if (self.target_table.len > 0 and std.mem.indexOf(u8, query_sql, self.target_table) != null) {
        return self.answering(self.target_rows);
    }
    if (self.parent_table.len > 0 and std.mem.indexOf(u8, query_sql, self.parent_table) != null) {
        return self.answering(self.parent_rows);
    }
    self.unmatched += 1;
    return self.answering(&.{});
}

fn neighborStubDialect(_: *anyopaque) dialect.Dialect {
    return .sqlite;
}

const neighbor_stub_vtable = stubVTable(neighborStubQuery, neighborStubDialect);

test "loadEdgePath unwinds cleanly when any single allocation fails" {
    // The whole eager read, from the parent SELECT to the edge slices written
    // back into the scanned parents. The sweep's target is the neighbour
    // assembly (`loadEdgePath`): the parent id array, the neighbour builder's
    // two buffers, the per-parent `__fk` map, each scanned target's duplicated
    // strings and its JSON arena, and the edge slice. A failure anywhere has to
    // leave the frame releasable — the map's still-parked targets and value
    // lists, the target in flight, the id array and the builder's buffers —
    // which is what the byte ledger checks. It caught exactly that: a failure
    // between scanning a target and copying it into a parent's slice used to
    // strand the target's arena and strings (see `loadEdgePath`'s map teardown).
    const allocator = std.testing.allocator;
    const ParentClient = codegen.EntityClient(caaf_edge_infos, caaf_edge_parent_info);

    var stub = NeighborStub{
        .parent_table = "\"caaf_edge_parent\"",
        .target_table = "\"caaf_edge_child\"",
        .parent_rows = &caaf_edge_parent_rows,
        .target_rows = &caaf_edge_child_rows,
    };

    const Load = struct {
        fn run(child: std.mem.Allocator, s: *NeighborStub) !void {
            var no_remap = NoRemap{ .inner = child };
            const swept = no_remap.asAllocator();

            var client = ParentClient.init(swept, s.asDriver());
            var q = client.Query();
            defer q.deinit();
            _ = try q.WithEdge("children");

            var parents = try q.All();
            defer {
                for (parents.items) |*p| entity_mod.deinitEntity(caaf_edge_infos, caaf_edge_parent_info, p, swept);
                parents.deinit();
            }

            try std.testing.expectEqual(@as(usize, 0), s.unmatched);
            try std.testing.expectEqual(@as(usize, 2), parents.items.len);
            const first = parents.items[0].edges.children.?;
            try std.testing.expectEqual(@as(usize, 2), first.len);
            try std.testing.expectEqual(@as(i64, 10), first[0].id);
            try std.testing.expectEqualStrings("second", first[1].body);
            const second = parents.items[1].edges.children.?;
            try std.testing.expectEqual(@as(usize, 1), second.len);
            try std.testing.expectEqualStrings("only", second[0].body);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Load.run, .{&stub});
}

test "client.queryTargets unwinds cleanly when any single allocation fails" {
    // The neighbour reader behind `EntityClient.QueryEdge`, in its scoped
    // shape: the parent-id `Value` array, the target read contract's predicate
    // list, the neighbour builder (`Builder.initCapacity` at
    // `codegen/client.zig:751`), the scanned targets and the result list. The
    // errdefer that releases every entity already scanned before the slice
    // itself is what the ledger holds to account on the failure path.
    const allocator = std.testing.allocator;

    var stub = NeighborStub{
        .parent_table = "\"caaf_edge_parent\"",
        .target_table = "\"caaf_edge_child\"",
        .target_rows = &caaf_edge_child_rows,
    };

    const Read = struct {
        fn run(child: std.mem.Allocator, s: *NeighborStub) !void {
            var no_remap = NoRemap{ .inner = child };
            const swept = no_remap.asAllocator();

            var got = try codegen.queryTargets(
                caaf_edge_infos,
                "CaafEdgeParent",
                "children",
                &.{ 1, 2 },
                swept,
                s.asDriver(),
                null,
                null,
            );
            defer {
                for (got.items) |*e| entity_mod.deinitEntity(caaf_edge_infos, caaf_edge_child_info, e, swept);
                got.deinit();
            }

            try std.testing.expectEqual(@as(usize, 0), s.unmatched);
            try std.testing.expectEqual(@as(usize, 3), got.items.len);
            try std.testing.expectEqual(@as(i64, 10), got.items[0].id);
            try std.testing.expectEqualStrings("second", got.items[1].body);
            try std.testing.expectEqualStrings("only", got.items[2].body);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Read.run, .{&stub});
}
