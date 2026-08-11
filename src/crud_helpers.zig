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
const client_mod = @import("codegen/client.zig");
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
/// `mapRow(allocator, row)` returns one `T` per result row and MAY return an
/// error union (`!T`). Contract: every string field of the returned `T` must
/// be allocated with the passed `allocator` (dupe borrowed row text) so
/// `Rows(T).deinit()` can free it exactly once. Example:
/// ```zig
/// const r = try zent.crud_helpers.queryRows(ProductRow, driver, sql, args, alloc,
///     struct { fn f(a: std.mem.Allocator, row: sql_driver.Row) !ProductRow {
///         return .{ .id = row.getInt(0) orelse 0, .name = try a.dupe(u8, row.getText(1) orelse "") };
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
    errdefer {
        // Free owned strings of any rows appended before the failure, then the
        // backing buffer — Managed.deinit alone would leak the duped strings.
        freeStrings(T, list.items, allocator);
        list.deinit();
    }
    while (rows.next()) |row| {
        try list.append(try mapRow(allocator, row));
    }
    // toOwnedSlice detaches the backing; errdefer is skipped on success, so the
    // caller owns every string + the slice via Rows(T).deinit().
    return .{ .items = try list.toOwnedSlice(), .allocator = allocator };
}

/// Delete (or soft-delete) rows matching `predicates`. Returns rows affected.
pub fn delete(accessor: anytype, predicates: anytype) !usize {
    var del = accessor.Delete();
    defer del.deinit();
    _ = try del.Where(predicates);
    return try del.Exec();
}

/// Check if any row matches the specified `predicates`.
/// Returns `true` if at least 1 record exists, `false` otherwise.
pub fn exists(accessor: anytype, predicates: anytype) !bool {
    return (try count(accessor, predicates)) > 0;
}

/// Finds the first matching entity. If none matches, creates and returns a new entity with `create_values`.
/// Returns owned Entity — free with `deinitEntity`.
pub fn findOrStore(accessor: anytype, create_values: anytype, predicates: anytype) !@typeInfo(CreateResult(@TypeOf(accessor))).error_union.payload {
    const existing = try first(accessor, predicates);
    if (existing) |e| {
        return e;
    }
    return try create(accessor, create_values);
}

/// Pagination result struct containing total row count, page details, and row items.
pub fn PageResult(comptime Accessor: type) type {
    const ItemsList = @typeInfo(AllResult(Accessor)).error_union.payload;
    return struct {
        const Self = @This();
        items: ItemsList,
        total: i64,
        page: usize,
        page_size: usize,
        total_pages: usize,

        pub fn deinit(self: *Self, comptime infos: []const graph_mod.TypeInfo, comptime info: graph_mod.TypeInfo, allocator: std.mem.Allocator) void {
            deinitRows(infos, info, self.items, allocator);
        }
    };
}

/// Paginated list query on an entity accessor:
/// Queries total count and limit/offset slice of items for the requested page.
pub fn paginated(
    accessor: anytype,
    predicates: anytype,
    page: usize,
    page_size: usize,
) !PageResult(@TypeOf(accessor)) {
    const total_rows = try count(accessor, predicates);
    const safe_page = if (page == 0) 1 else page;
    const safe_size = if (page_size == 0) 10 else page_size;
    const offset = (safe_page - 1) * safe_size;

    var q = accessor.Query();
    defer q.deinit();
    _ = try q.Where(predicates);
    _ = q.Limit(safe_size);
    _ = q.Offset(offset);

    const items = try q.All();
    const total_pages = if (total_rows == 0) 0 else @as(usize, @intCast(@divFloor(total_rows + @as(i64, @intCast(safe_size)) - 1, @as(i64, @intCast(safe_size)))));

    return .{
        .items = items,
        .total = total_rows,
        .page = safe_page,
        .page_size = safe_size,
        .total_pages = total_pages,
    };
}

/// Options for sorting paginated or list queries.
pub const SortOptions = struct {
    sort_col: ?[]const u8 = null,
    desc: bool = false,
};

/// Check if `field_name` is a valid field defined on entity schema `info`.
pub fn isValidField(comptime info: graph_mod.TypeInfo, field_name: []const u8) bool {
    inline for (info.fields) |f| {
        if (std.mem.eql(u8, f.name, field_name)) return true;
    }
    return false;
}

fn parseSortOptions(opts: anytype) !SortOptions {
    const T = @TypeOf(opts);
    if (T == SortOptions) return opts;
    if (T == []const u8 or T == [:0]const u8) return .{ .sort_col = opts, .desc = false };
    if (@typeInfo(T) == .null) return .{};
    if (@typeInfo(T) == .@"struct") {
        var res = SortOptions{};
        if (@hasField(T, "sort_col")) {
            const val = @field(opts, "sort_col");
            if (@typeInfo(@TypeOf(val)) == .optional) {
                res.sort_col = val;
            } else {
                res.sort_col = val;
            }
        }
        if (@hasField(T, "desc")) {
            res.desc = @field(opts, "desc");
        }
        return res;
    }
    return error.InvalidSortOptions;
}

/// Paginated list query on an entity accessor with sorting options.
/// Validates `options.sort_col` against entity schema fields to prevent SQL injection.
pub fn paginatedWithOptions(
    accessor: anytype,
    predicates: anytype,
    options: anytype,
    page: usize,
    page_size: usize,
) !PageResult(@TypeOf(accessor)) {
    const opts = try parseSortOptions(options);
    const total_rows = try count(accessor, predicates);
    const safe_page = if (page == 0) 1 else page;
    const safe_size = if (page_size == 0) 10 else page_size;
    const offset = (safe_page - 1) * safe_size;

    var q = accessor.Query();
    defer q.deinit();
    _ = try q.Where(predicates);

    if (opts.sort_col) |col| {
        if (!isValidField(@TypeOf(accessor).entity_info, col)) {
            return error.InvalidSortColumn;
        }
        const sql_builder = @import("sql/builder.zig");
        if (opts.desc) {
            _ = try q.OrderBy(&.{sql_builder.OrderDesc(col)});
        } else {
            _ = try q.OrderBy(&.{sql_builder.OrderAsc(col)});
        }
    }

    _ = q.Limit(safe_size);
    _ = q.Offset(offset);

    const items = try q.All();
    const total_pages = if (total_rows == 0) 0 else @as(usize, @intCast(@divFloor(total_rows + @as(i64, @intCast(safe_size)) - 1, @as(i64, @intCast(safe_size)))));

    return .{
        .items = items,
        .total = total_rows,
        .page = safe_page,
        .page_size = safe_size,
        .total_pages = total_pages,
    };
}

fn LatestResult(comptime Accessor: type) type {
    const FR = FirstResult(Accessor);
    return (error{InvalidSortColumn} || @typeInfo(FR).error_union.error_set)!@typeInfo(FR).error_union.payload;
}

/// Query the single latest entity matching `predicates` ordered by `sort_col` DESC.
/// Whitelist-checks `sort_col` against entity schema fields.
/// Returns owned entity or `null` — caller frees non-null result with `deinitEntity`.
pub fn latest(
    accessor: anytype,
    predicates: anytype,
    sort_col: []const u8,
) LatestResult(@TypeOf(accessor)) {
    if (!isValidField(@TypeOf(accessor).entity_info, sort_col)) {
        return error.InvalidSortColumn;
    }
    const sql_builder = @import("sql/builder.zig");
    var q = accessor.Query();
    defer q.deinit();
    _ = try q.Where(predicates);
    _ = try q.OrderBy(&.{sql_builder.OrderDesc(sort_col)});
    return try q.First();
}

fn getInfos(comptime T: type) []const graph_mod.TypeInfo {
    if (@hasDecl(T, "entity_infos")) return T.entity_infos;
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |_, FieldT| {
        if (@hasDecl(FieldT, "entity_infos")) {
            return FieldT.entity_infos;
        }
    }
    @compileError("Cannot resolve entity_infos from type " ++ @typeName(T));
}

fn RootClientType(comptime T: type) type {
    if (@typeInfo(T) == .pointer) {
        const Child = @typeInfo(T).pointer.child;
        if (@hasField(Child, "client")) {
            return @TypeOf(@as(Child, undefined).client);
        }
    }
    if (@hasField(T, "client")) {
        return @TypeOf(@as(T, undefined).client);
    }
    if (!@hasDecl(T, "entity_info") and @hasField(T, "driver") and @hasField(T, "allocator")) {
        return T;
    }
    if (@hasDecl(T, "entity_info")) {
        return client_mod.Client(T.entity_infos);
    }
    @compileError("Cannot resolve Root Client from type " ++ @typeName(T));
}

fn getRootClient(client_or_accessor: anytype) RootClientType(@TypeOf(client_or_accessor)) {
    const T = @TypeOf(client_or_accessor);
    if (@typeInfo(T) == .pointer) {
        const Child = @typeInfo(T).pointer.child;
        if (@hasField(Child, "client")) {
            return client_or_accessor.client;
        }
    }
    if (@hasField(T, "client")) {
        return client_or_accessor.client;
    }
    if (!@hasDecl(T, "entity_info") and @hasField(T, "driver") and @hasField(T, "allocator")) {
        return client_or_accessor;
    }
    if (@hasDecl(T, "entity_info") and @hasField(T, "driver") and @hasField(T, "allocator")) {
        const infos = getInfos(T);
        return client_mod.makeClient(infos, client_or_accessor.allocator, client_or_accessor.driver);
    }
    @compileError("Cannot resolve Root Client from type " ++ @typeName(T));
}

fn execTxCallback(tx_fn: anytype, tx_ptr: anytype) !void {
    const F = @TypeOf(tx_fn);
    const info = @typeInfo(F);
    if (info == .@"fn" or (info == .pointer and @typeInfo(info.pointer.child) == .@"fn")) {
        return try tx_fn(tx_ptr);
    } else if (info == .@"struct" and @hasDecl(F, "exec")) {
        return try tx_fn.exec(tx_ptr);
    } else if (info == .@"struct" and @hasDecl(F, "run")) {
        return try tx_fn.run(tx_ptr);
    } else {
        @compileError("Unsupported callback type for withTx: " ++ @typeName(F));
    }
}

/// Execute a transaction callback within an automatically managed transaction lifecycle.
/// Resolves root client/driver from `client_or_accessor`.
/// Automatically commits on success and rolls back on error. `tx.deinit()` is always called.
pub fn withTx(
    client_or_accessor: anytype,
    tx_fn: anytype,
) anyerror!void {
    const infos = comptime getInfos(@TypeOf(client_or_accessor));
    const root_client = getRootClient(client_or_accessor);

    var tx = try client_mod.beginTx(infos, root_client);
    defer tx.deinit();

    execTxCallback(tx_fn, &tx) catch |err| {
        _ = tx.rollback() catch {};
        return err;
    };
    try tx.commit();
}

/// Atomically increment (or decrement if delta < 0) a numeric field for rows matching `predicates`.
/// Returns rows affected.
pub fn increment(
    accessor: anytype,
    comptime field_name: []const u8,
    delta: i64,
    predicates: anytype,
) !usize {
    var upd = accessor.Update();
    defer upd.deinit();
    const expr = comptime field_name ++ " + ?";
    _ = try upd.setExprArgs(field_name, expr, &.{.{ .int = delta }});
    _ = try upd.Where(predicates);
    return try upd.Save();
}

fn ScopedAllResult(comptime Accessor: type) type {
    const AR = AllResult(Accessor);
    return (error{ InvalidTenantColumn, EmptyInValues } || @typeInfo(AR).error_union.error_set)!@typeInfo(AR).error_union.payload;
}

fn ScopedFirstResult(comptime Accessor: type) type {
    const FR = FirstResult(Accessor);
    return (error{ InvalidTenantColumn, EmptyInValues } || @typeInfo(FR).error_union.error_set)!@typeInfo(FR).error_union.payload;
}

/// Query all entities matching `predicates` scoped to a tenant ID on `tenant_col`.
/// Validates `tenant_col` against entity schema fields.
pub fn scopedBy(
    accessor: anytype,
    comptime tenant_col: []const u8,
    tenant_id: i64,
    predicates: anytype,
) ScopedAllResult(@TypeOf(accessor)) {
    if (!isValidField(@TypeOf(accessor).entity_info, tenant_col)) {
        return error.InvalidTenantColumn;
    }
    var q = accessor.Query();
    defer q.deinit();
    _ = try q.Where(predicates);

    const val_buf = try q.allocator.alloc(Value, 1);
    defer q.allocator.free(val_buf);
    val_buf[0] = .{ .int = tenant_id };
    _ = try q.WhereIn(tenant_col, val_buf);

    return try q.All();
}

/// Query all entities matching `predicates` scoped to `tenant_id` on default column "tenant_id".
pub fn scoped(
    accessor: anytype,
    tenant_id: i64,
    predicates: anytype,
) ScopedAllResult(@TypeOf(accessor)) {
    return scopedBy(accessor, "tenant_id", tenant_id, predicates);
}

/// Query the first entity matching `predicates` scoped to a tenant ID on `tenant_col`.
pub fn scopedFirstBy(
    accessor: anytype,
    comptime tenant_col: []const u8,
    tenant_id: i64,
    predicates: anytype,
) ScopedFirstResult(@TypeOf(accessor)) {
    if (!isValidField(@TypeOf(accessor).entity_info, tenant_col)) {
        return error.InvalidTenantColumn;
    }
    var q = accessor.Query();
    defer q.deinit();
    _ = try q.Where(predicates);

    const val_buf = try q.allocator.alloc(Value, 1);
    defer q.allocator.free(val_buf);
    val_buf[0] = .{ .int = tenant_id };
    _ = try q.WhereIn(tenant_col, val_buf);

    return try q.First();
}

/// Query the first entity matching `predicates` scoped to `tenant_id` on default column "tenant_id".
pub fn scopedFirst(
    accessor: anytype,
    tenant_id: i64,
    predicates: anytype,
) ScopedFirstResult(@TypeOf(accessor)) {
    return scopedFirstBy(accessor, "tenant_id", tenant_id, predicates);
}

/// Batch create entities from a slice of struct values (`items`).
/// Returns an owned Managed list of created Entities. Caller frees with `deinitRows`.
pub fn batchCreate(
    accessor: anytype,
    allocator: std.mem.Allocator,
    items: anytype,
) !@typeInfo(AllResult(@TypeOf(accessor))).error_union.payload {
    const Entity = @typeInfo(CreateResult(@TypeOf(accessor))).error_union.payload;
    // The accessor's client allocator owns created entities' strings; the list
    // backing uses the passed allocator. Free both on any mid-loop failure.
    const client_alloc = accessor.allocator;
    const client_infos = @TypeOf(accessor).entity_infos;
    const client_info = @TypeOf(accessor).entity_info;
    var list = std.array_list.Managed(Entity).init(allocator);
    errdefer {
        for (list.items) |*e| deinitEntity(client_infos, client_info, e, client_alloc);
        list.deinit();
    }

    for (items) |item| {
        const entity = try create(accessor, item);
        try list.append(entity);
    }
    return list;
}

/// Query a single entity by its primary key integer ID.
/// Returns owned Entity or null — free non-null result with `deinitEntity`.
pub fn get(accessor: anytype, id_val: i64) !@typeInfo(FirstResult(@TypeOf(accessor))).error_union.payload {
    var q = accessor.Query();
    defer q.deinit();
    const val_buf = try q.allocator.alloc(Value, 1);
    defer q.allocator.free(val_buf);
    val_buf[0] = .{ .int = id_val };
    _ = try q.WhereIn(@TypeOf(accessor).meta.FieldID, val_buf);
    return try q.First();
}

/// Query entities matching a list of integer IDs.
/// Returns owned Managed list of entities — caller frees with `deinitRows`.
pub fn findByIds(accessor: anytype, allocator: std.mem.Allocator, ids: []const i64) !@typeInfo(AllResult(@TypeOf(accessor))).error_union.payload {
    const val_buf = try allocator.alloc(Value, ids.len);
    defer allocator.free(val_buf);
    for (ids, 0..) |id, i| {
        val_buf[i] = .{ .int = id };
    }
    var q = accessor.Query();
    defer q.deinit();
    _ = try q.WhereIn(@TypeOf(accessor).meta.FieldID, val_buf);
    return try q.All();
}

/// Result enum returned by `saveOrUpdate`.
pub fn SaveOrUpdateResult(comptime Accessor: type) type {
    const Entity = @typeInfo(CreateResult(Accessor)).error_union.payload;
    return union(enum) {
        created: Entity,
        updated: usize,
    };
}

/// Save or update helper:
/// Checks if records matching `predicates` exist.
/// If matched, performs `update(accessor, values, predicates)` returning `.updated = rows_affected`.
/// If no match, performs `create(accessor, values)` returning `.created = entity`.
pub fn saveOrUpdate(accessor: anytype, values: anytype, predicates: anytype) !SaveOrUpdateResult(@TypeOf(accessor)) {
    if (try exists(accessor, predicates)) {
        const n = try update(accessor, values, predicates);
        return .{ .updated = n };
    } else {
        const ent = try create(accessor, values);
        return .{ .created = ent };
    }
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
        fn map(a: std.mem.Allocator, row: sql_driver.Row) !RowT {
            return .{ .item_id = row.getInt(0) orelse 0, .name = try a.dupe(u8, row.getText(1) orelse "") };
        }
    };

    var result = try queryRows(RowT, driver, "SELECT item_id, name FROM zigshop_item ORDER BY item_id", &.{}, allocator, Mapper.map);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqual(@as(i64, 1), result.items[0].item_id);
    try std.testing.expectEqualStrings("a", result.items[0].name);
    try std.testing.expectEqualStrings("b", result.items[1].name);
}

test "crud_helpers: queryRows error mid-collection leaks no strings" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");

    const Item = Schema("Item", .{
        .table_name = "zigshop_item",
        .pk = "item_id",
        .fields = &.{ field.Int("item_id"), field.String("name") },
    });
    const info = comptime fromSchema(Item);
    const infos = &[_]graph_mod.TypeInfo{info};

    var drv = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    const driver = drv.asDriver();
    try migrate.migrateSchema(allocator, driver, infos);
    _ = try driver.exec("INSERT INTO zigshop_item (item_id, name) VALUES (1, 'a'), (2, 'b'), (3, 'c')", &.{});

    const RowT = struct { item_id: i64, name: []const u8 };
    const FailingMapper = struct {
        fn map(a: std.mem.Allocator, row: sql_driver.Row) !RowT {
            if ((row.getInt(0) orelse 0) == 2) return error.Stop;
            return .{ .item_id = row.getInt(0) orelse 0, .name = try a.dupe(u8, row.getText(1) orelse "") };
        }
    };

    // First row's string is duped, then row 2 errors -> the partial row's
    // string must be freed by the errdefer (std.testing.allocator detects leaks).
    try std.testing.expectError(error.Stop, queryRows(RowT, driver, "SELECT item_id, name FROM zigshop_item ORDER BY item_id", &.{}, allocator, FailingMapper.map));
}

test "crud_helpers: first with no match returns null (not error)" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");
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

test "crud_helpers: batchCreate error path frees created entities (no leak)" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");

    const Category = Schema("Category", .{
        .table_name = "zigshop_category",
        .pk = "category_id",
        .fields = &.{ field.Int("category_id"), field.String("name").Unique(), field.Int("status").Default(1) },
    });
    const info = comptime fromSchema(Category);
    const infos = &[_]graph_mod.TypeInfo{info};

    var drv = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    const driver = drv.asDriver();
    try migrate.migrateSchema(allocator, driver, infos);
    const client = client_mod.makeClient(infos, allocator, driver);

    // Second item repeats the first's unique name -> create fails mid-loop;
    // the first entity's owned strings must be freed by the errdefer.
    const items = [_]struct { name: []const u8, status: i64 }{
        .{ .name = "dup", .status = 1 },
        .{ .name = "dup", .status = 1 },
    };
    try std.testing.expectError(error.UniqueViolation, batchCreate(client.category, allocator, items));
}

test "crud_helpers: exists, findOrStore, paginated, and batchCreate" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");

    const Category = Schema("Category", .{
        .table_name = "zigshop_category",
        .pk = "category_id",
        .fields = &.{
            field.Int("category_id"),
            field.String("name").Unique(),
            field.Int("status").Default(1),
        },
    });
    const info = comptime fromSchema(Category);
    const infos = &[_]graph_mod.TypeInfo{info};

    var drv = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    const driver = drv.asDriver();
    try migrate.migrateSchema(allocator, driver, infos);
    const client = client_mod.makeClient(infos, allocator, driver);
    const preds = client.category.predicates;

    // 1. exists before insertion
    try std.testing.expect(!(try exists(client.category, .{preds.nameEQ(.{ .string = "electronics" })})));

    // 2. findOrStore (stores missing entity)
    var stored = try findOrStore(client.category, .{ .name = "electronics", .status = 1 }, .{preds.nameEQ(.{ .string = "electronics" })});
    defer deinitEntity(infos, info, &stored, allocator);
    try std.testing.expectEqualStrings("electronics", stored.name);

    // 3. exists after insertion
    try std.testing.expect(try exists(client.category, .{preds.nameEQ(.{ .string = "electronics" })}));

    // 4. findOrStore (finds existing entity)
    var fetched = try findOrStore(client.category, .{ .name = "electronics", .status = 99 }, .{preds.nameEQ(.{ .string = "electronics" })});
    defer deinitEntity(infos, info, &fetched, allocator);
    try std.testing.expectEqual(stored.category_id, fetched.category_id);
    try std.testing.expectEqual(@as(i64, 1), fetched.status); // original status preserved

    // 5. batchCreate
    const batch_items = &[_]struct { name: []const u8, status: i64 }{
        .{ .name = "books", .status = 1 },
        .{ .name = "clothing", .status = 1 },
        .{ .name = "sports", .status = 1 },
    };
    const created_list = try batchCreate(client.category, allocator, batch_items);
    defer deinitRows(infos, info, created_list, allocator);
    try std.testing.expectEqual(@as(usize, 3), created_list.items.len);

    // 6. paginated (total = 4, page 1, size 2)
    var p1 = try paginated(client.category, .{preds.statusEQ(.{ .int = 1 })}, 1, 2);
    defer p1.deinit(infos, info, allocator);
    try std.testing.expectEqual(@as(i64, 4), p1.total);
    try std.testing.expectEqual(@as(usize, 2), p1.items.items.len);
    try std.testing.expectEqual(@as(usize, 2), p1.total_pages);
}

test "crud_helpers: get, findByIds, and saveOrUpdate" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");

    const Account = Schema("Account", .{
        .table_name = "zigshop_account",
        .pk = "account_id",
        .fields = &.{
            field.Int("account_id"),
            field.String("username").Unique(),
            field.Int("balance"),
        },
    });
    const info = comptime fromSchema(Account);
    const infos = &[_]graph_mod.TypeInfo{info};

    var drv = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    const driver = drv.asDriver();
    try migrate.migrateSchema(allocator, driver, infos);
    const client = client_mod.makeClient(infos, allocator, driver);
    const preds = client.account.predicates;

    // 1. saveOrUpdate -> created
    var res1 = try saveOrUpdate(client.account, .{ .username = "alice", .balance = 100 }, .{preds.usernameEQ(.{ .string = "alice" })});
    switch (res1) {
        .created => |*ent| {
            defer deinitEntity(infos, info, ent, allocator);
            try std.testing.expect(ent.account_id > 0);
            try std.testing.expectEqualStrings("alice", ent.username);

            // 2. get by ID
            var got = try get(client.account, ent.account_id);
            defer if (got) |*e| deinitEntity(infos, info, e, allocator);
            try std.testing.expect(got != null);
            try std.testing.expectEqual(ent.account_id, got.?.account_id);
        },
        .updated => @panic("expected created"),
    }

    // 3. saveOrUpdate -> updated
    const res2 = try saveOrUpdate(client.account, .{ .balance = 200 }, .{preds.usernameEQ(.{ .string = "alice" })});
    switch (res2) {
        .updated => |affected| try std.testing.expectEqual(@as(usize, 1), affected),
        .created => @panic("expected updated"),
    }

    // 4. findByIds
    const batch_res = try batchCreate(client.account, allocator, &[_]struct { username: []const u8, balance: i64 }{
        .{ .username = "bob", .balance = 50 },
        .{ .username = "charlie", .balance = 75 },
    });
    defer deinitRows(infos, info, batch_res, allocator);

    const ids = &[_]i64{ batch_res.items[0].account_id, batch_res.items[1].account_id };
    const found_list = try findByIds(client.account, allocator, ids);
    defer deinitRows(infos, info, found_list, allocator);
    try std.testing.expectEqual(@as(usize, 2), found_list.items.len);
}

test "crud_helpers: paginatedWithOptions, latest, and withTx" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");

    const Article = Schema("Article", .{
        .table_name = "zigshop_article",
        .pk = "article_id",
        .fields = &.{
            field.Int("article_id"),
            field.String("title"),
            field.Int("created_at"),
        },
    });
    const info = comptime fromSchema(Article);
    const infos = &[_]graph_mod.TypeInfo{info};

    var drv = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    const driver = drv.asDriver();
    try migrate.migrateSchema(allocator, driver, infos);
    const client = client_mod.makeClient(infos, allocator, driver);

    // Seed articles with different timestamps
    var a1 = try create(client.article, .{ .title = "first", .created_at = 100 });
    deinitEntity(infos, info, &a1, allocator);
    var a2 = try create(client.article, .{ .title = "second", .created_at = 200 });
    deinitEntity(infos, info, &a2, allocator);
    var a3 = try create(client.article, .{ .title = "third", .created_at = 300 });
    deinitEntity(infos, info, &a3, allocator);

    // 1. paginatedWithOptions desc
    var p_desc = try paginatedWithOptions(client.article, .{}, .{ .sort_col = "created_at", .desc = true }, 1, 2);
    defer p_desc.deinit(infos, info, allocator);
    try std.testing.expectEqual(@as(i64, 3), p_desc.total);
    try std.testing.expectEqual(@as(usize, 2), p_desc.items.items.len);
    try std.testing.expectEqualStrings("third", p_desc.items.items[0].title);
    try std.testing.expectEqualStrings("second", p_desc.items.items[1].title);

    // 2. paginatedWithOptions invalid column error
    try std.testing.expectError(error.InvalidSortColumn, paginatedWithOptions(client.article, .{}, .{ .sort_col = "non_existent" }, 1, 2));

    // 3. latest helper
    var lat = try latest(client.article, .{}, "created_at");
    defer if (lat) |*e| deinitEntity(infos, info, e, allocator);
    try std.testing.expect(lat != null);
    try std.testing.expectEqualStrings("third", lat.?.title);

    // 4. latest invalid column error
    try std.testing.expectError(error.InvalidSortColumn, latest(client.article, .{}, "malicious_injection; DROP TABLE--"));

    // 5. withTx commit path
    try withTx(client, struct {
        fn run(tx: anytype) !void {
            var created = try create(tx.client.article, .{ .title = "tx_fourth", .created_at = 400 });
            deinitEntity(infos, info, &created, allocator);
        }
    }.run);

    var lat2 = try latest(client.article, .{}, "created_at");
    defer if (lat2) |*e| deinitEntity(infos, info, e, allocator);
    try std.testing.expect(lat2 != null);
    try std.testing.expectEqualStrings("tx_fourth", lat2.?.title);

    // 6. withTx rollback path
    const RollbackError = error{IntentionalFailure};
    const res = withTx(client, struct {
        fn run(tx: anytype) !void {
            var created = try create(tx.client.article, .{ .title = "tx_fifth_failed", .created_at = 500 });
            deinitEntity(infos, info, &created, allocator);
            return RollbackError.IntentionalFailure;
        }
    }.run);
    try std.testing.expectError(RollbackError.IntentionalFailure, res);

    var lat3 = try latest(client.article, .{}, "created_at");
    defer if (lat3) |*e| deinitEntity(infos, info, e, allocator);
    try std.testing.expect(lat3 != null);
    try std.testing.expectEqualStrings("tx_fourth", lat3.?.title); // 500 was rolled back
}

test "crud_helpers: increment and scoped tenant queries" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");

    const Inventory = Schema("Inventory", .{
        .table_name = "zigshop_inventory",
        .pk = "inventory_id",
        .fields = &.{
            field.Int("inventory_id"),
            field.Int("tenant_id"),
            field.String("item_code"),
            field.Int("stock"),
        },
    });
    const info = comptime fromSchema(Inventory);
    const infos = &[_]graph_mod.TypeInfo{info};

    var drv = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    const driver = drv.asDriver();
    try migrate.migrateSchema(allocator, driver, infos);
    const client = client_mod.makeClient(infos, allocator, driver);
    const preds = client.inventory.predicates;

    // Seed data for tenant 1 and tenant 2
    var inv1 = try create(client.inventory, .{ .tenant_id = 1, .item_code = "ITEM_A", .stock = 100 });
    deinitEntity(infos, info, &inv1, allocator);
    var inv2 = try create(client.inventory, .{ .tenant_id = 1, .item_code = "ITEM_B", .stock = 50 });
    deinitEntity(infos, info, &inv2, allocator);
    var inv3 = try create(client.inventory, .{ .tenant_id = 2, .item_code = "ITEM_C", .stock = 200 });
    deinitEntity(infos, info, &inv3, allocator);

    // 1. increment (+10 stock for ITEM_A)
    const affected1 = try increment(client.inventory, "stock", 10, .{preds.item_codeEQ(.{ .string = "ITEM_A" })});
    try std.testing.expectEqual(@as(usize, 1), affected1);

    var item_a = try first(client.inventory, .{preds.item_codeEQ(.{ .string = "ITEM_A" })});
    defer if (item_a) |*e| deinitEntity(infos, info, e, allocator);
    try std.testing.expect(item_a != null);
    try std.testing.expectEqual(@as(i64, 110), item_a.?.stock);

    // 2. decrement (-20 stock for ITEM_A)
    const affected2 = try increment(client.inventory, "stock", -20, .{preds.item_codeEQ(.{ .string = "ITEM_A" })});
    try std.testing.expectEqual(@as(usize, 1), affected2);

    var item_a2 = try first(client.inventory, .{preds.item_codeEQ(.{ .string = "ITEM_A" })});
    defer if (item_a2) |*e| deinitEntity(infos, info, e, allocator);
    try std.testing.expect(item_a2 != null);
    try std.testing.expectEqual(@as(i64, 90), item_a2.?.stock);

    // 3. scoped queries for tenant 1
    const t1_list = try scoped(client.inventory, 1, .{});
    defer deinitRows(infos, info, t1_list, allocator);
    try std.testing.expectEqual(@as(usize, 2), t1_list.items.len);

    // 4. scopedFirst for tenant 2
    var t2_first = try scopedFirst(client.inventory, 2, .{});
    defer if (t2_first) |*e| deinitEntity(infos, info, e, allocator);
    try std.testing.expect(t2_first != null);
    try std.testing.expectEqualStrings("ITEM_C", t2_first.?.item_code);

    // 5. invalid tenant column error
    try std.testing.expectError(error.InvalidTenantColumn, scopedBy(client.inventory, "non_existent_tenant_col", 1, .{}));
}
