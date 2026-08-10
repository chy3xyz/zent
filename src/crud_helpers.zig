//! Ergonomic CRUD sugar over the typed entity accessors.
//!
//! These helpers exist so consumers can write terse, correct persistence
//! code without hand-rolling the Query/Create/Update/Delete lifecycle every
//! time. They are schema-agnostic: they derive everything from the accessor's
//! type (`client.order` / `client.user` / ...) and the `values` / `predicates`
//! structs passed in.
//!
//! Examples:
//! ```zig
//! // one row by id (returns !?Order)
//! var e = try zent.crud_helpers.first(client.order, .{ client.order.predicates.order_idEQ(.{ .int = id }) });
//! if (e) |*ent| { defer zent.codegen.deinitEntity(infos, ORDER_INFO, ent, alloc); ... }
//!
//! // insert from a field-value struct
//! var created = try zent.crud_helpers.create(client.coupon, .{ .name = n, .status = 20 });
//!
//! // partial update (rows affected)
//! const n = try zent.crud_helpers.update(client.coupon, .{ .status = 20 }, .{ preds.coupon_idEQ(...) });
//!
//! // delete / soft-delete (rows affected)
//! const m = try zent.crud_helpers.delete(client.coupon, .{ preds.coupon_idEQ(...) });
//! ```
//!
//! Memory contract: `first` returns an owned entity (free with
//! `zent.codegen.deinitEntity(infos, info, &e, alloc)`); `create` returns an
//! owned entity (free the same way); `update`/`delete` return rows affected.

const std = @import("std");
const graph_mod = @import("codegen/graph.zig");
const sql_driver = @import("sql/driver.zig");
const Value = @import("sql/builder.zig").Value;
const deinitEntity = @import("codegen/entity.zig").deinitEntity;

/// Resolve the `QueryError!?Entity` result type of an entity accessor's
/// `Query()` builder via its `First()` method signature.
fn FirstResult(comptime Accessor: type) type {
    const QB = @TypeOf(@as(Accessor, undefined).Query());
    return @TypeOf(@as(*QB, undefined).First());
}

/// Resolve the `QueryError![]Entity` result type of an entity accessor's
/// `All()` builder.
fn AllResult(comptime Accessor: type) type {
    const QB = @TypeOf(@as(Accessor, undefined).Query());
    return @TypeOf(@as(*QB, undefined).All());
}

/// One-row query on an entity accessor: adds `predicates`, runs `First()`,
/// and hands back the owned entity or `null`. The query lifecycle is handled
/// here; the caller frees the entity with `deinitEntity` and maps it (capture
/// with `|*entity|` to avoid a copy).
pub fn first(accessor: anytype, predicates: anytype) FirstResult(@TypeOf(accessor)) {
    var q = accessor.Query();
    defer q.deinit();
    _ = try q.Where(predicates);
    return try q.First();
}

/// List query on an entity accessor: adds `predicates`, runs `All()`, hands
/// back the owned row list. The query lifecycle is handled here; the caller
/// frees with `deinitRows(infos, info, rows, alloc)`.
pub fn all(accessor: anytype, predicates: anytype) AllResult(@TypeOf(accessor)) {
    var q = accessor.Query();
    defer q.deinit();
    _ = try q.Where(predicates);
    return try q.All();
}

/// Row-count query on an entity accessor: adds `predicates`, runs `Count()`.
pub fn count(accessor: anytype, predicates: anytype) CountResult(@TypeOf(accessor)) {
    var q = accessor.Query();
    defer q.deinit();
    _ = try q.Where(predicates);
    return try q.Count();
}

/// Resolve the `QueryError!i64` result type of an entity accessor's `Count()`.
fn CountResult(comptime Accessor: type) type {
    const QB = @TypeOf(@as(Accessor, undefined).Query());
    return @TypeOf(@as(*QB, undefined).Count());
}

/// Resolve the `SaveError!Entity` result type of an entity accessor's
/// `Create()` builder.
fn CreateResult(comptime Accessor: type) type {
    const CB = @typeInfo(@TypeOf(@as(Accessor, undefined).Create())).error_union.payload;
    return @TypeOf(@as(*CB, undefined).Save());
}

/// Create an entity from a struct of field values (`values`), e.g.
/// `create(client.bargain_task_help, .{ .task_id = t, .user_id = u })`.
/// Runs Create + setFieldValue for each field + Save. Returns the owned
/// entity — free it with `deinitEntity`.
pub fn create(accessor: anytype, values: anytype) CreateResult(@TypeOf(accessor)) {
    var cb = try accessor.Create();
    defer cb.deinit();
    inline for (@typeInfo(@TypeOf(values)).@"struct".field_names) |name| {
        _ = try cb.setFieldValue(name, @field(values, name));
    }
    return try cb.Save();
}

/// Update rows matching `predicates` from a struct of field values.
/// Returns rows affected. Example:
/// `update(client.coupon, .{ .status = 20 }, .{ preds.coupon_idEQ(...) })`.
pub fn update(accessor: anytype, values: anytype, predicates: anytype) !usize {
    var upd = accessor.Update();
    defer upd.deinit();
    inline for (@typeInfo(@TypeOf(values)).@"struct".field_names) |name| {
        _ = try upd.setFieldValue(name, @field(values, name));
    }
    _ = try upd.Where(predicates);
    return try upd.Save();
}

/// Owned row slice returned by raw-driver query helpers. Caller frees with
/// `deinit()` — frees every `[]const u8` / `?[]const u8` field on each item
/// (comptime reflection), then the slice itself.
pub fn Rows(comptime T: type) type {
    return struct {
        const Self = @This();
        items: []T,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Self) void {
            freeStrings(T, self.items, self.allocator);
            self.allocator.free(self.items);
        }
    };
}

fn freeStrings(comptime T: type, items: []T, allocator: std.mem.Allocator) void {
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, ft| {
        if (ft == []const u8) {
            for (items) |*it| allocator.free(@field(it, name));
        } else if (ft == ?[]const u8) {
            for (items) |*it| if (@field(it, name)) |s| allocator.free(s);
        }
    }
}

/// Run a raw driver query and collect the rows into an owned `Rows(T)` slice.
/// `mapRow(allocator, row)` returns one `T` per result row (dupe strings with
/// the passed allocator). Example:
/// ```zig
/// const r = try zent.crud_helpers.queryRows(ProductRow, driver, sql, args, alloc,
///     struct { fn f(a: std.mem.Allocator, row: sql_driver.Row) ProductRow {
///         return .{ .id = row.getInt(0) orelse 0, .name = a.dupe(u8, row.getText(1) orelse "") catch "" };
///     } }.f);
/// defer r.deinit();
/// ```
pub fn queryRows(
    comptime T: type,
    driver: anytype,
    sql: []const u8,
    args: []const Value,
    allocator: std.mem.Allocator,
    comptime mapRow: anytype,
) !Rows(T) {
    var rows = try driver.query(sql, args);
    defer rows.deinit();
    var list = std.array_list.Managed(T).init(allocator);
    errdefer list.deinit();
    while (rows.next()) |row| {
        try list.append(mapRow(allocator, row));
    }
    return .{ .items = try list.toOwnedSlice(), .allocator = allocator };
}

/// Delete (or soft-delete) rows matching `predicates`. Returns rows affected.
pub fn delete(accessor: anytype, predicates: anytype) !usize {
    var del = accessor.Delete();
    defer del.deinit();
    _ = try del.Where(predicates);
    return try del.Exec();
}

/// Free every row of an `All()` result plus the list itself. Centralizes the
/// memory contract so persistence code is terse: map each `rows.items[i]`,
/// then `deinitRows(infos, info, rows, alloc)` in one call.
pub fn deinitRows(
    comptime infos: []const graph_mod.TypeInfo,
    comptime info: graph_mod.TypeInfo,
    rows: anytype,
    allocator: std.mem.Allocator,
) void {
    for (rows.items) |*e| deinitEntity(infos, info, e, allocator);
    rows.deinit();
}

// ── Tests ────────────────────────────────────────────────────

test "crud_helpers: first/create/update/delete round-trip on sqlite" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");
    const client_mod = @import("codegen/client.zig");
    const Product = Schema("Product", .{
        .table_name = "zigshop_product",
        .pk = "product_id",
        .fields = &.{
            field.Int("product_id"),
            field.String("name"),
            field.Int("stock"),
            field.Int("is_delete").Default(0),
        },
    });

    const info = comptime fromSchema(Product);
    const infos = &[_]graph_mod.TypeInfo{info};
    const PRODUCT_INFO = infos[0];

    var drv = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    const driver = drv.asDriver();
    try migrate.migrateSchema(allocator, driver, infos);

    var client = client_mod.makeClient(infos, allocator, driver);

    // create
    var created = try create(client.product, .{ .name = "coffee", .stock = 10 });
    defer deinitEntity(infos, PRODUCT_INFO, &created, allocator);
    try std.testing.expect(created.product_id > 0);
    try std.testing.expectEqualStrings("coffee", created.name);

    // first by id
    var fetched = try first(client.product, .{client.product.predicates.product_idEQ(.{ .int = created.product_id })});
    defer if (fetched) |*e| deinitEntity(infos, PRODUCT_INFO, e, allocator);
    try std.testing.expect(fetched != null);
    try std.testing.expectEqual(created.product_id, fetched.?.product_id);
    try std.testing.expectEqual(@as(i64, 10), fetched.?.stock);

    // update
    const affected = try update(client.product, .{ .stock = 5 }, .{client.product.predicates.product_idEQ(.{ .int = created.product_id })});
    try std.testing.expectEqual(@as(usize, 1), affected);

    var after = try first(client.product, .{client.product.predicates.product_idEQ(.{ .int = created.product_id })});
    defer if (after) |*e| deinitEntity(infos, PRODUCT_INFO, e, allocator);
    try std.testing.expectEqual(@as(i64, 5), after.?.stock);

    // delete
    const deleted = try delete(client.product, .{client.product.predicates.product_idEQ(.{ .int = created.product_id })});
    try std.testing.expectEqual(@as(usize, 1), deleted);

    // deinitRows over an All() result frees items + list
    var all_q = client.product.Query();
    defer all_q.deinit();
    const all_rows = try all_q.All();
    defer deinitRows(infos, PRODUCT_INFO, all_rows, allocator);
    _ = all_rows.items.len;

    var gone = try first(client.product, .{client.product.predicates.product_idEQ(.{ .int = created.product_id })});
    defer if (gone) |*e| deinitEntity(infos, PRODUCT_INFO, e, allocator);
    try std.testing.expect(gone == null);
}

test "crud_helpers: queryRows collects mapped rows into owned Rows(T)" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");

    const Item = Schema("Item", .{
        .table_name = "zigshop_item",
        .pk = "item_id",
        .fields = &.{
            field.Int("item_id"),
            field.String("name"),
        },
    });

    const info = comptime fromSchema(Item);
    const infos = &[_]graph_mod.TypeInfo{info};

    var drv = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    const driver = drv.asDriver();
    try migrate.migrateSchema(allocator, driver, infos);
    _ = try driver.exec("INSERT INTO zigshop_item (item_id, name) VALUES (1, 'a'), (2, 'b')", &.{});

    const RowT = struct { item_id: i64, name: []const u8 };
    const Mapper = struct {
        fn map(a: std.mem.Allocator, row: sql_driver.Row) RowT {
            return .{ .item_id = row.getInt(0) orelse 0, .name = a.dupe(u8, row.getText(1) orelse "") catch "" };
        }
    };

    var result = try queryRows(RowT, driver, "SELECT item_id, name FROM zigshop_item ORDER BY item_id", &.{}, allocator, Mapper.map);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqual(@as(i64, 1), result.items[0].item_id);
    try std.testing.expectEqualStrings("a", result.items[0].name);
    try std.testing.expectEqualStrings("b", result.items[1].name);
}

test "crud_helpers: first with no match returns null (not error)" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");
    const client_mod = @import("codegen/client.zig");
    const Tag = Schema("Tag", .{
        .table_name = "zigshop_tag",
        .pk = "tag_id",
        .fields = &.{
            field.Int("tag_id"),
            field.String("name"),
        },
    });

    const info = comptime fromSchema(Tag);
    const infos = &[_]graph_mod.TypeInfo{info};

    var drv = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    const driver = drv.asDriver();
    try migrate.migrateSchema(allocator, driver, infos);

    var client = client_mod.makeClient(infos, allocator, driver);

    var missing = try first(client.tag, .{client.tag.predicates.tag_idEQ(.{ .int = 999 })});
    defer if (missing) |*e| deinitEntity(infos, infos[0], e, allocator);
    try std.testing.expect(missing == null);
}

test "crud_helpers: all + count over predicates" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");
    const client_mod = @import("codegen/client.zig");

    const Tag = Schema("Tag", .{
        .table_name = "zigshop_tag",
        .pk = "tag_id",
        .fields = &.{ field.Int("tag_id"), field.String("name"), field.Int("is_delete").Default(0) },
    });
    const info = comptime fromSchema(Tag);
    const infos = &[_]graph_mod.TypeInfo{info};

    var drv = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    const driver = drv.asDriver();
    try migrate.migrateSchema(allocator, driver, infos);
    var client = client_mod.makeClient(infos, allocator, driver);

    var c1 = try create(client.tag, .{ .name = "a" });
    defer deinitEntity(infos, info, &c1, allocator);
    var c2 = try create(client.tag, .{ .name = "b" });
    defer deinitEntity(infos, info, &c2, allocator);
    var c3 = try create(client.tag, .{ .name = "c" });
    defer deinitEntity(infos, info, &c3, allocator);
    const total = try count(client.tag, .{client.tag.predicates.is_deleteEQ(.{ .int = 0 })});
    try std.testing.expectEqual(@as(i64, 3), total);

    const preds = client.tag.predicates;
    const rows = try all(client.tag, .{preds.is_deleteEQ(.{ .int = 0 })});
    defer deinitRows(infos, info, rows, allocator);
    try std.testing.expectEqual(@as(usize, 3), rows.items.len);
}
