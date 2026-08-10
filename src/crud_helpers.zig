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

/// Resolve the `QueryError!?Entity` result type of an entity accessor's
/// `Query()` builder via its `First()` method signature.
fn FirstResult(comptime Accessor: type) type {
    const QB = @TypeOf(@as(Accessor, undefined).Query());
    return @TypeOf(@as(*QB, undefined).First());
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

/// Delete (or soft-delete) rows matching `predicates`. Returns rows affected.
pub fn delete(accessor: anytype, predicates: anytype) !usize {
    var del = accessor.Delete();
    defer del.deinit();
    _ = try del.Where(predicates);
    return try del.Exec();
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
    const deinitEntity = @import("codegen/entity.zig").deinitEntity;

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

    var gone = try first(client.product, .{client.product.predicates.product_idEQ(.{ .int = created.product_id })});
    defer if (gone) |*e| deinitEntity(infos, PRODUCT_INFO, e, allocator);
    try std.testing.expect(gone == null);
}

test "crud_helpers: first with no match returns null (not error)" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");
    const client_mod = @import("codegen/client.zig");
    const deinitEntity = @import("codegen/entity.zig").deinitEntity;

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
