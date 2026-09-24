//! `std.testing.checkAllAllocationFailures` over the two assembly paths left
//! uncovered by `allocation_failures.zig`: the entity **read** path — a row
//! scan that duplicates every string field with the caller's allocator — and
//! the neighbour-fragment assembly (`graph/neighbors.zig` writing into an
//! `sql.Builder`, then `takeQuery`).
//!
//! The method is the one `allocation_failures.zig` documents: run the function
//! once to count its allocations, then fail each one in turn and require the run
//! to either finish or fail with `OutOfMemory`, with the allocator's byte ledger
//! balanced. A partially built value dropped on the error path shows up as
//! `error.MemoryLeakDetected` naming the fail index, which is what the scan
//! below is here to catch: the fields a positional scan has already `dupe`d
//! belong to the frame that is unwinding, because the caller received neither
//! the value nor the error.
//!
//! Two deliberate limits on the coverage here, both of them the sweep's own
//! preconditions rather than gaps in the library:
//!
//!  * `sql.Builder.init` is not exercised. It swallows an induced `OutOfMemory`
//!    on purpose (it "cannot fail"; `Builder.initCapacity` is the fallible
//!    shape), and a run that swallows the failure is reported by the sweep as
//!    `error.SwallowedOutOfMemoryError`. The neighbour test therefore starts
//!    from `initCapacity`, exactly as `Selector.init` does.
//!  * The arena half *is* covered, but only since `scanColumn`'s JSON
//!    conversion stopped reporting an `OutOfMemory` raised inside `std.json` as
//!    `TypeMismatch` (v0.77.1). Before that narrowing the sweep failed on any
//!    error that is not `OutOfMemory` before it ever examined the ledger —
//!    measured, not assumed: a `{ theme: []const u8 }` field made this file fail
//!    with `FAIL (TypeMismatch)` at the first fail_index inside the parser. What
//!    the JSON case below then checks is the split ownership the arena design
//!    implies: the duplicated strings belong to the frame (released by
//!    `freeDto`, which walks only `[]u8` fields), the parsed document belongs to
//!    the arena (released by the frame's `arena.deinit()`), and a failure in
//!    either has to leave the other releaseable.

const std = @import("std");
const driver_mod = @import("../sql/driver.zig");
const Row = driver_mod.Row;
const Rows = driver_mod.Rows;
const scan = @import("../sql/scan.zig");
const sql = @import("../sql/builder.zig");
const neighbors = @import("../graph/neighbors.zig");
const Step = @import("../graph/step.zig").Step;

// ------------------------------------------------------------------
// A one-row `Row` fixture, and a `Driver` that yields a fixed list of them
// ------------------------------------------------------------------

/// Column values borrowed from `[]const u8` literals at the call site, so the
/// only allocations the sweep's ledger counts are the ones the code under test
/// makes — the fixture itself never allocates.
const FixtureRow = struct {
    names: []const []const u8,
    ints: []const ?i64,
    texts: []const ?[]const u8,
    nulls: []const bool,

    fn asRow(self: *const FixtureRow) Row {
        return .{ .ptr = @ptrCast(@constCast(self)), .vtable = &row_vtable };
    }

    fn fixture(ptr: *anyopaque) *const FixtureRow {
        return @ptrCast(@alignCast(ptr));
    }

    fn columnCountFn(ptr: *anyopaque) usize {
        return fixture(ptr).names.len;
    }

    fn columnNameFn(ptr: *anyopaque, index: usize) []const u8 {
        return fixture(ptr).names[index];
    }

    fn getIntFn(ptr: *anyopaque, index: usize) ?i64 {
        return fixture(ptr).ints[index];
    }

    fn getTextFn(ptr: *anyopaque, index: usize) ?[]const u8 {
        return fixture(ptr).texts[index];
    }

    fn isNullFn(ptr: *anyopaque, index: usize) bool {
        return fixture(ptr).nulls[index];
    }

    fn nullFloatFn(_: *anyopaque, _: usize) ?f64 {
        return null;
    }

    fn nullBoolFn(_: *anyopaque, _: usize) ?bool {
        return null;
    }

    fn nullBlobFn(_: *anyopaque, _: usize) ?[]const u8 {
        return null;
    }
};

const row_vtable = Row.VTable{
    .columnCount = FixtureRow.columnCountFn,
    .columnName = FixtureRow.columnNameFn,
    .getBool = FixtureRow.nullBoolFn,
    .getInt = FixtureRow.getIntFn,
    .getFloat = FixtureRow.nullFloatFn,
    .getText = FixtureRow.getTextFn,
    .getBlob = FixtureRow.nullBlobFn,
    .isNull = FixtureRow.isNullFn,
};

/// Entity-shaped: three of its four fields are strings the scanner duplicates
/// with the caller's allocator, one of them optional — so a failure on the
/// *n*th string has *n-1* owned strings to release.
const PostEntity = struct {
    id: i64,
    title: []const u8,
    nickname: ?[]const u8,
    body: []const u8,
};

const post_columns = [_][]const u8{ "id", "title", "nickname", "body" };

const first_post = FixtureRow{
    .names = &post_columns,
    .ints = &.{ 11, null, null, null },
    .texts = &.{ null, "a title", "ali", "a body long enough to need its own buffer" },
    .nulls = &.{ false, false, false, false },
};

/// Same shape, with the optional column NULL, so the named scan sees both
/// branches of an optional field.
const second_post = FixtureRow{
    .names = &post_columns,
    .ints = &.{ 12, null, null, null },
    .texts = &.{ null, "another title", null, "second body" },
    .nulls = &.{ false, false, true, false },
};

/// The same row repeated. Twelve rows are enough that the result list
/// reallocates more than once, so a failure on a *later* row's append happens
/// with earlier items already in the list — the case where an `errdefer` scoped
/// to the loop rather than to the iteration would release an item twice.
const post_rows: [12]FixtureRow = @splat(first_post);

/// For the lenient scanner: `amount` is NULL, so the field takes the
/// `ownDefault` branch and its declared literal default has to come back owned.
const lenient_dto_row = FixtureRow{
    .names = &.{ "id", "title", "amount", "note" },
    .ints = &.{ 21, null, null, null },
    .texts = &.{ null, "a title", null, "a note" },
    .nulls = &.{ false, false, true, false },
};

/// A `Driver` whose result set is an in-memory list of rows. `query` hands out
/// a heap cursor allocated with whatever allocator the run was given — so the
/// sweep also sees whether a failure after `query` still releases it.
const FixtureDriver = struct {
    allocator: std.mem.Allocator,
    rows: []const FixtureRow,

    fn asDriver(self: *FixtureDriver) driver_mod.Driver {
        return .{ .ptr = self, .vtable = &driver_vtable };
    }

    const Cursor = struct {
        allocator: std.mem.Allocator,
        rows: []const FixtureRow,
        index: usize = 0,

        fn nextFn(ptr: *anyopaque) ?Row {
            const self_: *Cursor = @ptrCast(@alignCast(ptr));
            if (self_.index >= self_.rows.len) return null;
            defer self_.index += 1;
            return self_.rows[self_.index].asRow();
        }

        fn deinitFn(ptr: *anyopaque) void {
            const self_: *Cursor = @ptrCast(@alignCast(ptr));
            self_.allocator.destroy(self_);
        }
    };

    const cursor_vtable = Rows.VTable{ .next = Cursor.nextFn, .deinit = Cursor.deinitFn };

    fn execFn(_: *anyopaque, _: ?*const driver_mod.ExecutionContext, _: []const u8, _: []const sql.Value) driver_mod.Error!driver_mod.Result {
        return .{ .rows_affected = 0, .last_insert_id = null };
    }

    fn queryFn(ptr: *anyopaque, _: ?*const driver_mod.ExecutionContext, _: []const u8, _: []const sql.Value) driver_mod.Error!Rows {
        const self: *FixtureDriver = @ptrCast(@alignCast(ptr));
        const cursor = try self.allocator.create(Cursor);
        cursor.* = .{ .allocator = self.allocator, .rows = self.rows };
        return Rows{ .ptr = cursor, .vtable = &cursor_vtable };
    }

    fn txFailFn(_: *anyopaque) driver_mod.Error!driver_mod.Tx {
        return error.TxFailed;
    }

    fn savepointFailFn(_: *anyopaque, _: []const u8) driver_mod.Error!driver_mod.Tx {
        return error.TxFailed;
    }

    fn closeFn(_: *anyopaque) void {}

    fn dialectFn(_: *anyopaque) @import("../sql/dialect.zig").Dialect {
        return .sqlite;
    }

    fn pingFn(_: *anyopaque) driver_mod.Error!void {}

    fn inTxFn(_: *anyopaque) bool {
        return false;
    }

    const driver_vtable = driver_mod.Driver.VTable{
        .exec = execFn,
        .query = queryFn,
        .beginTx = txFailFn,
        .close = closeFn,
        .dialect = dialectFn,
        .ping = pingFn,
        .inTransaction = inTxFn,
        .beginSavepoint = savepointFailFn,
    };
};

// ------------------------------------------------------------------
// Read path
// ------------------------------------------------------------------

/// Entity with a JSON struct field: parsed through `std.json` into a caller
/// arena, so the sweep reaches the parser's allocations too — and the arena's
/// own buffer growth, since the arena is the frame's to release.
const Settings = struct {
    theme: []const u8,
    flags: []const bool,
};

const DocEntity = struct {
    id: i64,
    title: []const u8,
    settings: Settings,
};

const doc_columns = [_][]const u8{ "id", "title", "settings" };

const first_doc = FixtureRow{
    .names = &doc_columns,
    .ints = &.{ 21, null, null },
    .texts = &.{ null, "a doc", "{\"theme\":\"dark\",\"flags\":[true,false,true]}" },
    .nulls = &.{ false, false, false },
};

test "scanRowWithArena unwinds cleanly when any single allocation fails" {
    // The codegen entry point for a non-JSON entity (`scanEntity` in
    // `src/codegen/query.zig`): a positional scan whose string fields are each
    // duplicated with the caller's allocator. Every one of those copies made
    // before a later `try` fails has to be released by this frame.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const entity = try scan.scanRowWithArena(PostEntity, allocator, first_post.asRow(), null);
            defer scan.freeDto(PostEntity, allocator, &entity);

            try std.testing.expectEqual(@as(i64, 11), entity.id);
            try std.testing.expectEqualStrings("a title", entity.title);
            try std.testing.expectEqualStrings("ali", entity.nickname.?);
            try std.testing.expectEqualStrings("a body long enough to need its own buffer", entity.body);
        }
    }.run, .{});
}

test "scanRowNamed unwinds cleanly when any single allocation fails" {
    // The name-resolved scanner behind `queryAll`: same duplication, but the
    // column lookup also tolerates a NULL optional field, so this covers the
    // second branch of an optional string.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const entity = try scan.scanRowNamed(PostEntity, allocator, second_post.asRow());
            defer scan.freeDto(PostEntity, allocator, &entity);

            try std.testing.expectEqual(@as(i64, 12), entity.id);
            try std.testing.expectEqualStrings("another title", entity.title);
            try std.testing.expect(entity.nickname == null);
            try std.testing.expectEqualStrings("second body", entity.body);
        }
    }.run, .{});
}

test "scanRowNamedLenient unwinds cleanly when any single allocation fails" {
    // The lenient scanner is where the release-on-error has to tell two owners
    // apart. A field the scan has processed holds memory this frame owns — a
    // duplicated column, or an *owned copy* of a declared default
    // (`ownDefault`). A field it has not reached yet still holds `defaultInit`'s
    // **comptime literal** (`"0.00"` below), which is not this frame's to free;
    // freeing it is an invalid free that `std.testing.allocator` reports as
    // loudly as a leak. `amount` is NULL in this row, so it takes the
    // `ownDefault` branch.
    const Dto = struct {
        id: i64,
        title: []const u8,
        amount: []const u8 = "0.00",
        note: []const u8,
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const dto = try scan.scanRowNamedLenient(Dto, allocator, lenient_dto_row.asRow());
            defer scan.freeDto(Dto, allocator, &dto);

            try std.testing.expectEqual(@as(i64, 21), dto.id);
            try std.testing.expectEqualStrings("a title", dto.title);
            try std.testing.expectEqualStrings("0.00", dto.amount);
            try std.testing.expectEqualStrings("a note", dto.note);
        }
    }.run, .{});
}

test "queryAll unwinds cleanly when any single allocation fails" {
    // The whole read behind `queryAll`: the driver's cursor, one scan per row,
    // the list's growth, and the release of everything already scanned when a
    // later row's scan — or the append of the row just scanned — fails.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var fixture = FixtureDriver{ .allocator = allocator, .rows = &post_rows };
            var posts = try scan.queryAll(PostEntity, allocator, fixture.asDriver(), "SELECT id, title, nickname, body FROM post", &.{});
            defer {
                for (posts.items) |*post| scan.freeDto(PostEntity, allocator, post);
                posts.deinit();
            }

            try std.testing.expectEqual(@as(usize, post_rows.len), posts.items.len);
            try std.testing.expectEqualStrings("a title", posts.items[0].title);
            try std.testing.expectEqualStrings("ali", posts.items[post_rows.len - 1].nickname.?);
            try std.testing.expectEqualStrings("a body long enough to need its own buffer", posts.items[post_rows.len - 1].body);
        }
    }.run, .{});
}

// ------------------------------------------------------------------
// Neighbour-fragment assembly
// ------------------------------------------------------------------

const post_step = Step{
    .from_table = "post",
    .from_column = "id",
    .to_table = "comment",
    .to_column = "id",
    .edge_rel = .o2m,
    .edge_table = "comment",
    .edge_columns = &[_][]const u8{"post_id"},
    .inverse = false,
    .order_by = "created_at",
    .desc = true,
    // A per-parent limit forces the window-function shape, so the assembly
    // writes the derived table, the rank and the outer WHERE.
    .limit = 2,
    .filter = .{ .sql = "\"status\" = ?", .args = &.{.{ .string = "visible" }} },
};

const reply_step = Step{
    .from_table = "comment",
    .from_column = "id",
    .to_table = "comment",
    .to_column = "id",
    .edge_rel = .o2m,
    .edge_table = "comment",
    .edge_columns = &[_][]const u8{"parent_id"},
    .inverse = false,
};

const neighbor_preds = [_]sql.Predicate{
    // Interceptor-shaped: rewritten by `appendQualifiedPred` with the target.
    sql.EQ("app_id", .{ .int = 7 }),
    sql.IsNull("deleted_at"),
    // Written byte-by-byte into the builder's buffer, one `writeByte` per
    // character of the escaped literal.
    sql.ContainsEscaped("body", "50% off"),
    sql.RawArgs("\"score\" > ?", &.{.{ .int = 3 }}),
    // The predicate form of the other entry point: rendering it routes back
    // into `appendHasNeighborsWith`, so the nested EXISTS body is assembled by
    // the same call the second half of this test makes directly.
    .{ .has_neighbors_with = .{ .step = reply_step, .preds = &.{sql.EQ("kind", .{ .string = "reply" })}, .soft_delete = true } },
};

test "an entity with a JSON field unwinds cleanly when any single allocation fails" {
    // Both owners are in this frame: the arena that holds the parsed document
    // and the allocator that holds the duplicated strings. Every failure point
    // in between has to leave both releasable, which is why the two `defer`s
    // are declared before anything is scanned.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            const entity = try scan.scanRowWithArena(DocEntity, allocator, first_doc.asRow(), &arena);
            defer scan.freeDto(DocEntity, allocator, &entity);

            try std.testing.expectEqual(@as(i64, 21), entity.id);
            try std.testing.expectEqualStrings("a doc", entity.title);
            try std.testing.expectEqualStrings("dark", entity.settings.theme);
            try std.testing.expectEqual(@as(usize, 3), entity.settings.flags.len);
            try std.testing.expect(entity.settings.flags[0]);
            try std.testing.expect(!entity.settings.flags[1]);
        }
    }.run, .{});
}

test "neighbour fragment assembly unwinds cleanly when any single allocation fails" {
    // Both entry points at once, assembled into one owned statement: the
    // eager-load fragment (identifiers, predicates, chunked bound args) and the
    // EXISTS body, followed by `takeQuery`, which moves the SQL buffer and the
    // arg slice out of the builder together.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const parent_ids = try allocator.alloc(sql.Value, 24);
            defer allocator.free(parent_ids);
            for (parent_ids, 0..) |*id, i| id.* = .{ .int = @intCast(i + 1) };

            // `Builder.initCapacity`, not `Builder.init`: the latter swallows an
            // induced `OutOfMemory` by design, which the sweep reports as a
            // swallowed failure rather than testing what follows it.
            var b = try sql.Builder.initCapacity(allocator, 128, 4, .sqlite);
            defer b.deinit();

            try neighbors.appendSetNeighborsFiltered(&b, post_step, parent_ids, &neighbor_preds);
            try b.writeString(" UNION ALL SELECT 1 FROM \"comment\" WHERE EXISTS (");
            try neighbors.appendHasNeighborsWith(&b, post_step, &neighbor_preds, true);
            try b.writeByte(')');

            var q = try b.takeQuery();
            defer q.deinit();

            try std.testing.expect(std.mem.indexOf(u8, q.sql, "ROW_NUMBER() OVER (PARTITION BY") != null);
            try std.testing.expect(std.mem.indexOf(u8, q.sql, "EXISTS (SELECT 1 FROM \"comment\"") != null);
            // One arg per parent id, plus the step's own filter arg, plus one
            // for each allocating predicate — `EQ(app_id)`, `RawArgs(score)`
            // and the nested `has_neighbors_with`'s `EQ(kind)` — emitted once
            // in the eager fragment and once more in the EXISTS body.
            try std.testing.expectEqual(parent_ids.len + 1 + 3 + 3, q.args.len);
        }
    }.run, .{});
}
