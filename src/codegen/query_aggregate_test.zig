const std = @import("std");
const sql = @import("../sql/builder.zig");
const sql_driver = @import("../sql/driver.zig");
const Dialect = @import("../sql/dialect.zig").Dialect;
const TypeInfo = @import("graph.zig").TypeInfo;
const fromSchema = @import("graph.zig").fromSchema;
const EntityGen = @import("entity.zig").Entity;
const deinitEntity = @import("entity.zig").deinitEntity;
const QueryBuilder = @import("query.zig").QueryBuilder;
const BulkInsertBuilder = @import("create.zig").BulkInsertBuilder;
const CreateBuilder = @import("create.zig").CreateBuilder;
const UpsertSetExpr = @import("create.zig").UpsertSetExpr;
const field = @import("../core/field.zig");
const schema = @import("../core/schema.zig").Schema;

const MockRows = struct {
    value: sql.Value,
    returned: bool,

    const vtable = sql_driver.Rows.VTable{
        .next = next,
        .deinit = deinit,
        .nextError = null,
    };

    const row_vtable = sql_driver.Row.VTable{
        .columnCount = columnCount,
        .columnName = columnName,
        .getBool = getBool,
        .getInt = getInt,
        .getFloat = getFloat,
        .getText = getText,
        .getBlob = getBlob,
        .isNull = isNull,
    };

    fn next(ptr: *anyopaque) ?sql_driver.Row {
        const self: *MockRows = @ptrCast(@alignCast(ptr));
        if (self.returned) return null;
        self.returned = true;
        return sql_driver.Row{ .ptr = self, .vtable = &row_vtable };
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *MockRows = @ptrCast(@alignCast(ptr));
        std.testing.allocator.destroy(self);
    }

    fn columnCount(_: *anyopaque) usize {
        return 1;
    }

    fn columnName(_: *anyopaque, _: usize) []const u8 {
        return "agg";
    }

    fn getBool(ptr: *anyopaque, _: usize) ?bool {
        const self: *MockRows = @ptrCast(@alignCast(ptr));
        return if (self.value == .bool) self.value.bool else null;
    }

    fn getInt(ptr: *anyopaque, _: usize) ?i64 {
        const self: *MockRows = @ptrCast(@alignCast(ptr));
        return if (self.value == .int) self.value.int else null;
    }

    fn getFloat(ptr: *anyopaque, _: usize) ?f64 {
        const self: *MockRows = @ptrCast(@alignCast(ptr));
        return if (self.value == .float) self.value.float else null;
    }

    fn getText(ptr: *anyopaque, _: usize) ?[]const u8 {
        const self: *MockRows = @ptrCast(@alignCast(ptr));
        return if (self.value == .string) self.value.string else null;
    }

    fn getBlob(_: *anyopaque, _: usize) ?[]const u8 {
        return null;
    }

    fn isNull(ptr: *anyopaque, _: usize) bool {
        const self: *MockRows = @ptrCast(@alignCast(ptr));
        return self.value == .null;
    }
};

const MockDriver = struct {
    value: sql.Value,
    no_rows: bool = false,
    capture_sql: bool = false,
    last_sql: ?[]const u8 = null,
    last_sql_owned: ?[]u8 = null,
    dialect_override: ?Dialect = null,

    const vtable = sql_driver.Driver.VTable{
        .exec = exec,
        .query = query,
        .beginTx = beginTx,
        .close = close,
        .dialect = dialect,
        .ping = ping,
        .inTransaction = inTransaction,
        .beginSavepoint = beginSavepoint,
    };

    fn asDriver(self: *MockDriver) sql_driver.Driver {
        return sql_driver.Driver{ .ptr = self, .vtable = &vtable };
    }

    fn exec(ptr: *anyopaque, _: ?*const sql_driver.ExecutionContext, sql_text: []const u8, _: []const sql.Value) sql_driver.Error!sql_driver.Result {
        const self: *MockDriver = @ptrCast(@alignCast(ptr));
        if (self.capture_sql) {
            self.last_sql_owned = std.testing.allocator.dupe(u8, sql_text) catch null;
            self.last_sql = self.last_sql_owned;
        }
        return .{ .rows_affected = 0, .last_insert_id = null };
    }

    fn query(ptr: *anyopaque, _: ?*const sql_driver.ExecutionContext, sql_text: []const u8, _: []const sql.Value) sql_driver.Error!sql_driver.Rows {
        const self: *MockDriver = @ptrCast(@alignCast(ptr));
        if (self.capture_sql) {
            self.last_sql_owned = std.testing.allocator.dupe(u8, sql_text) catch null;
            self.last_sql = self.last_sql_owned;
        }
        const rows = try std.testing.allocator.create(MockRows);
        rows.* = .{ .value = self.value, .returned = self.no_rows };
        return sql_driver.Rows{ .ptr = rows, .vtable = &MockRows.vtable };
    }

    fn beginTx(_: *anyopaque) sql_driver.Error!sql_driver.Tx {
        return error.TxFailed;
    }

    fn beginSavepoint(_: *anyopaque, _: []const u8) sql_driver.Error!sql_driver.Tx {
        return error.TxFailed;
    }

    fn close(_: *anyopaque) void {}

    fn dialect(ptr: *anyopaque) Dialect {
        const self: *MockDriver = @ptrCast(@alignCast(ptr));
        return self.dialect_override orelse .sqlite;
    }

    fn ping(_: *anyopaque) sql_driver.Error!void {}

    fn inTransaction(_: *anyopaque) bool {
        return false;
    }
};

fn expectValueEqual(expected: sql.Value, actual: sql.Value) !void {
    switch (expected) {
        .null => try std.testing.expect(actual == .null),
        .int => |ev| switch (actual) {
            .int => |av| try std.testing.expectEqual(ev, av),
            else => return error.TypeMismatch,
        },
        .float => |ev| switch (actual) {
            .float => |av| try std.testing.expectApproxEqAbs(ev, av, 0.0001),
            else => return error.TypeMismatch,
        },
        .string => |ev| switch (actual) {
            .string => |av| try std.testing.expectEqualStrings(ev, av),
            else => return error.TypeMismatch,
        },
        else => unreachable,
    }
}

test "Bulk upsert emits ON CONFLICT on postgres/sqlite and ON DUPLICATE on mysql" {
    const allocator = std.testing.allocator;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const BulkBuilder = BulkInsertBuilder(infos, info, UserEntity);

    // PostgreSQL: RETURNING path + ON CONFLICT DO UPDATE SET.
    var mock_pg = MockDriver{ .value = .{ .int = 1 }, .capture_sql = true, .dialect_override = .postgres };
    var b_pg = try BulkBuilder.init(allocator, mock_pg.asDriver(), &.{}, null);
    defer b_pg.deinit();
    _ = try b_pg.setFieldValue("name", "alice");
    _ = try b_pg.setFieldValue("age", 30);
    _ = try b_pg.Next();
    _ = try b_pg.setFieldValue("name", "bob");
    _ = try b_pg.setFieldValue("age", 25);
    var ids_pg = try b_pg.SaveOrUpdate();
    defer ids_pg.deinit();
    const pg_sql = mock_pg.last_sql_owned orelse return error.MissingCapture;
    defer allocator.free(pg_sql);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "INSERT") != null);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "ON CONFLICT (\"id\") DO UPDATE SET") != null);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "\"name\"=EXCLUDED.\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "\"age\"=EXCLUDED.\"age\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "RETURNING \"id\"") != null);
    // SQLite bulk upsert must ALSO emit ON CONFLICT (single-row SaveOrUpdate
    // uses INSERT OR REPLACE, but the bulk path uses ON CONFLICT).
    var mock_sq = MockDriver{ .value = .{ .int = 1 }, .capture_sql = true, .dialect_override = .sqlite };
    var b_sq = try BulkBuilder.init(allocator, mock_sq.asDriver(), &.{}, null);
    defer b_sq.deinit();
    _ = try b_sq.setFieldValue("name", "alice");
    _ = try b_sq.setFieldValue("age", 30);
    var ids_sq = try b_sq.SaveOrUpdate();
    defer ids_sq.deinit();
    const sq_sql = mock_sq.last_sql_owned orelse return error.MissingCapture;
    defer allocator.free(sq_sql);
    try std.testing.expect(std.mem.indexOf(u8, sq_sql, "ON CONFLICT (\"id\") DO UPDATE SET") != null);
    try std.testing.expect(std.mem.indexOf(u8, sq_sql, "RETURNING \"id\"") != null);
    // Plain Save must NOT emit a conflict clause.
    var mock_plain = MockDriver{ .value = .{ .int = 1 }, .capture_sql = true, .dialect_override = .postgres };
    var b_plain = try BulkBuilder.init(allocator, mock_plain.asDriver(), &.{}, null);
    defer b_plain.deinit();
    _ = try b_plain.setFieldValue("name", "carol");
    _ = try b_plain.setFieldValue("age", 40);
    var ids_plain = try b_plain.Save();
    defer ids_plain.deinit();
    const plain_sql = mock_plain.last_sql_owned orelse return error.MissingCapture;
    defer allocator.free(plain_sql);
    try std.testing.expect(std.mem.indexOf(u8, plain_sql, "ON CONFLICT") == null);

    // MySQL: exec path + ON DUPLICATE KEY UPDATE.
    var mock_my = MockDriver{ .value = .null, .capture_sql = true, .dialect_override = .mysql };
    var b_my = try BulkBuilder.init(allocator, mock_my.asDriver(), &.{}, null);
    defer b_my.deinit();
    _ = try b_my.setFieldValue("name", "dave");
    _ = try b_my.setFieldValue("age", 35);
    var ids_my = try b_my.SaveOrUpdate();
    defer ids_my.deinit();
    const my_sql = mock_my.last_sql_owned orelse return error.MissingCapture;
    defer allocator.free(my_sql);
    try std.testing.expect(std.mem.indexOf(u8, my_sql, "ON DUPLICATE KEY UPDATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, my_sql, "`name`=VALUES(`name`)") != null);
    try std.testing.expect(std.mem.indexOf(u8, my_sql, "RETURNING") == null);
}

test "Max and Min do not leak Rows on null/int/float/text paths" {
    const allocator = std.testing.allocator;

    const User = schema("User", .{
        .fields = &.{
            field.String("name"),
            field.Int("age"),
            field.Float("score"),
        },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const UserQuery = QueryBuilder(infos, info, UserEntity);

    const cases = &[_]sql.Value{
        .null,
        .{ .int = 42 },
        .{ .float = 3.14 },
        .{ .string = "charlie" },
    };

    for (cases) |value| {
        var mock_max = MockDriver{ .value = value };
        var q_max = UserQuery.init(allocator, mock_max.asDriver(), null);
        defer q_max.deinit();
        const max = try q_max.Max("name");
        defer if (max == .string) allocator.free(max.string);
        try expectValueEqual(value, max);

        var mock_min = MockDriver{ .value = value };
        var q_min = UserQuery.init(allocator, mock_min.asDriver(), null);
        defer q_min.deinit();
        const min = try q_min.Min("name");
        defer if (min == .string) allocator.free(min.string);
        try expectValueEqual(value, min);
    }
}

test "CountBy issues one grouped query with predicates" {
    const allocator = std.testing.allocator;

    const Order = schema("Order", .{
        .fields = &.{
            field.Int("tenant_id"),
            field.String("status"),
            field.Int("amount"),
        },
    });
    const info = comptime fromSchema(Order);
    const infos = &[_]TypeInfo{info};
    const OrderEntity = comptime EntityGen(infos, info);
    const OrderQuery = QueryBuilder(infos, info, OrderEntity);

    var mock = MockDriver{ .value = .null, .no_rows = true, .capture_sql = true };
    var q = OrderQuery.init(allocator, mock.asDriver(), null);
    defer q.deinit();
    _ = try q.Where(&.{sql.EQ("tenant_id", .{ .int = 1 })});
    var counts = try q.CountBy("status");
    defer counts.deinit();
    try std.testing.expectEqual(@as(usize, 0), counts.items.len);

    const s = mock.last_sql orelse return error.NoSqlCaptured;
    defer if (mock.last_sql_owned) |o| allocator.free(o);
    try std.testing.expect(std.mem.indexOf(u8, s, "COUNT(*)") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "GROUP BY \"status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "tenant_id") != null);
}

test "paged rejects zero page size and short-circuits empty tables" {
    const allocator = std.testing.allocator;

    const User = schema("User", .{
        .fields = &.{
            field.String("name"),
            field.Int("age"),
        },
    });
    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const UserQuery = QueryBuilder(infos, info, UserEntity);

    var mock_invalid = MockDriver{ .value = .null, .no_rows = true };
    var q_invalid = UserQuery.init(allocator, mock_invalid.asDriver(), null);
    defer q_invalid.deinit();
    try std.testing.expectError(error.InvalidPageSize, q_invalid.paged(1, 0));

    // Count returns 0 → paged returns an empty result without fetching items.
    var mock_empty = MockDriver{ .value = .{ .int = 0 } };
    var q_empty = UserQuery.init(allocator, mock_empty.asDriver(), null);
    defer q_empty.deinit();
    var page = try q_empty.paged(1, 20);
    defer page.deinit();
    try std.testing.expectEqual(@as(i64, 0), page.total);
    try std.testing.expectEqual(@as(usize, 0), page.items.items.len);
}

test "SumOrZero wraps SUM with COALESCE and returns the value" {
    const allocator = std.testing.allocator;

    const Order = schema("Order", .{
        .fields = &.{
            field.Int("tenant_id"),
            field.Float("amount"),
        },
    });
    const info = comptime fromSchema(Order);
    const infos = &[_]TypeInfo{info};
    const OrderEntity = comptime EntityGen(infos, info);
    const OrderQuery = QueryBuilder(infos, info, OrderEntity);

    var mock = MockDriver{ .value = .{ .float = 0 }, .capture_sql = true };
    var q = OrderQuery.init(allocator, mock.asDriver(), null);
    defer q.deinit();
    _ = try q.Where(&.{sql.EQ("tenant_id", .{ .int = 7 })});
    const total = try q.SumOrZero("amount");
    try std.testing.expectEqual(@as(f64, 0), total);

    const s = mock.last_sql orelse return error.NoSqlCaptured;
    defer if (mock.last_sql_owned) |o| allocator.free(o);
    try std.testing.expect(std.mem.indexOf(u8, s, "COALESCE(SUM(\"amount\"), 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "tenant_id") != null);
}

test "AggregateOne returns typed values across null/int/float/text" {
    const allocator = std.testing.allocator;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });
    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const UserQuery = QueryBuilder(infos, info, UserEntity);

    const cases = &[_]sql.Value{
        .null,
        .{ .int = 42 },
        .{ .float = 3.14 },
        .{ .string = "99.95" },
    };
    for (cases) |value| {
        var mock = MockDriver{ .value = value };
        var q = UserQuery.init(allocator, mock.asDriver(), null);
        defer q.deinit();
        const v = try q.AggregateOne("COUNT(DISTINCT name)");
        defer if (v == .string) allocator.free(v.string);
        try expectValueEqual(value, v);
    }
}

test "AggregateText returns exact decimal text and null" {
    const allocator = std.testing.allocator;

    const Order = schema("Order", .{
        .fields = &.{field.String("amount")},
    });
    const info = comptime fromSchema(Order);
    const infos = &[_]TypeInfo{info};
    const OrderEntity = comptime EntityGen(infos, info);
    const OrderQuery = QueryBuilder(infos, info, OrderEntity);

    var mock = MockDriver{ .value = .{ .string = "123.45" } };
    var q = OrderQuery.init(allocator, mock.asDriver(), null);
    defer q.deinit();
    const text = (try q.AggregateText("SUM(\"amount\")")) orelse return error.ExpectedValue;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("123.45", text);

    var mock_null = MockDriver{ .value = .null };
    var q_null = OrderQuery.init(allocator, mock_null.asDriver(), null);
    defer q_null.deinit();
    try std.testing.expect((try q_null.AggregateText("SUM(\"amount\")")) == null);
}

test "AggregateBy groups with raw aggregate expr and frees cleanly" {
    const allocator = std.testing.allocator;

    const Order = schema("Order", .{
        .fields = &.{
            field.Int("tenant_id"),
            field.String("status"),
            field.Int("amount"),
        },
    });
    const info = comptime fromSchema(Order);
    const infos = &[_]TypeInfo{info};
    const OrderEntity = comptime EntityGen(infos, info);
    const OrderQuery = QueryBuilder(infos, info, OrderEntity);

    var mock = MockDriver{ .value = .{ .int = 7 }, .capture_sql = true };
    var q = OrderQuery.init(allocator, mock.asDriver(), null);
    defer q.deinit();
    _ = try q.Where(&.{sql.EQ("tenant_id", .{ .int = 1 })});
    var metrics = try q.AggregateBy("SUM(\"amount\")", "status");
    defer OrderQuery.freeGroupMetrics(&metrics);
    try std.testing.expectEqual(@as(usize, 1), metrics.items.len);
    try expectValueEqual(.{ .int = 7 }, metrics.items[0].key);
    try expectValueEqual(.{ .int = 7 }, metrics.items[0].value);

    const s = mock.last_sql orelse return error.NoSqlCaptured;
    defer if (mock.last_sql_owned) |o| allocator.free(o);
    try std.testing.expect(std.mem.indexOf(u8, s, "SUM(\"amount\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "GROUP BY \"status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "tenant_id") != null);
}

test "SaveOrUpdateOnWith emits custom DO UPDATE expressions per dialect" {
    const allocator = std.testing.allocator;

    const Coupon = schema("Coupon", .{
        .table_name = "zigshop_coupon",
        .pk = "coupon_id",
        .fields = &.{
            field.Int("coupon_id"),
            field.Int("receive_num"),
            field.String("title"),
        },
    });
    const info = comptime fromSchema(Coupon);
    const infos = &[_]TypeInfo{info};
    const CouponEntity = comptime EntityGen(infos, info);
    const Create = CreateBuilder(infos, info, CouponEntity);

    const exprs = &[_]UpsertSetExpr{
        .{ .column = "receive_num", .expr = "{t:receive_num} + 1" },
    };

    // PostgreSQL: custom expr for receive_num, EXCLUDED for the rest.
    var mock_pg = MockDriver{ .value = .{ .int = 1 }, .capture_sql = true, .dialect_override = .postgres };
    var b_pg = Create.init(allocator, mock_pg.asDriver(), &.{}, null);
    defer b_pg.deinit();
    _ = try b_pg.setFieldValue("coupon_id", 9);
    _ = try b_pg.setFieldValue("receive_num", 1);
    _ = try b_pg.setFieldValue("title", "t");
    var e_pg = try b_pg.SaveOrUpdateOnWith(&.{"coupon_id"}, exprs);
    deinitEntity(infos, info, &e_pg, allocator);
    const pg_sql = mock_pg.last_sql_owned orelse return error.MissingCapture;
    defer allocator.free(pg_sql);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "ON CONFLICT (\"coupon_id\") DO UPDATE SET") != null);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "\"receive_num\"=\"zigshop_coupon\".\"receive_num\" + 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "\"title\"=EXCLUDED.\"title\"") != null);

    // MySQL: backtick idents, {t:col} → `table`.`col`, default VALUES().
    var mock_my = MockDriver{ .value = .{ .int = 1 }, .capture_sql = true, .dialect_override = .mysql };
    var b_my = Create.init(allocator, mock_my.asDriver(), &.{}, null);
    defer b_my.deinit();
    _ = try b_my.setFieldValue("coupon_id", 9);
    _ = try b_my.setFieldValue("receive_num", 1);
    _ = try b_my.setFieldValue("title", "t");
    var e_my = try b_my.SaveOrUpdateOnWith(&.{"coupon_id"}, exprs);
    deinitEntity(infos, info, &e_my, allocator);
    const my_sql = mock_my.last_sql_owned orelse return error.MissingCapture;
    defer allocator.free(my_sql);
    try std.testing.expect(std.mem.indexOf(u8, my_sql, "ON DUPLICATE KEY UPDATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, my_sql, "`receive_num`=`zigshop_coupon`.`receive_num` + 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, my_sql, "`title`=VALUES(`title`)") != null);

    // SQLite with custom exprs: ON CONFLICT form (not INSERT OR REPLACE).
    var mock_sq = MockDriver{ .value = .{ .int = 1 }, .capture_sql = true, .dialect_override = .sqlite };
    var b_sq = Create.init(allocator, mock_sq.asDriver(), &.{}, null);
    defer b_sq.deinit();
    _ = try b_sq.setFieldValue("coupon_id", 9);
    _ = try b_sq.setFieldValue("receive_num", 1);
    var e_sq = try b_sq.SaveOrUpdateOnWith(&.{"coupon_id"}, exprs);
    deinitEntity(infos, info, &e_sq, allocator);
    const sq_sql = mock_sq.last_sql_owned orelse return error.MissingCapture;
    defer allocator.free(sq_sql);
    try std.testing.expect(std.mem.indexOf(u8, sq_sql, "ON CONFLICT (\"coupon_id\") DO UPDATE SET") != null);
    try std.testing.expect(std.mem.indexOf(u8, sq_sql, "\"receive_num\"=\"zigshop_coupon\".\"receive_num\" + 1") != null);
}

test "ForUpdateWith flows lock options into the generated SELECT" {
    const allocator = std.testing.allocator;

    const Order = schema("Order", .{
        .table_name = "orders",
        .fields = &.{
            field.Int("tenant_id"),
            field.Int("amount"),
        },
    });
    const info = comptime fromSchema(Order);
    const infos = &[_]TypeInfo{info};
    const OrderEntity = comptime EntityGen(infos, info);
    const OrderQuery = QueryBuilder(infos, info, OrderEntity);

    // PostgreSQL: OF + SKIP LOCKED reach the SELECT suffix.
    var mock_pg = MockDriver{ .value = .null, .no_rows = true, .capture_sql = true, .dialect_override = .postgres };
    var q_pg = OrderQuery.init(allocator, mock_pg.asDriver(), null);
    defer q_pg.deinit();
    _ = try q_pg.Where(&.{sql.EQ("tenant_id", .{ .int = 1 })});
    _ = q_pg.ForUpdateWith(.{ .of = "orders", .skip_locked = true });
    var rows_pg = try q_pg.All();
    defer rows_pg.deinit();
    try std.testing.expectEqual(@as(usize, 0), rows_pg.items.len);
    const pg_sql = mock_pg.last_sql_owned orelse return error.MissingCapture;
    defer allocator.free(pg_sql);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "FOR UPDATE OF \"orders\" SKIP LOCKED") != null);

    // Plain ForUpdate still renders the bare suffix (backwards compatible).
    var mock_plain = MockDriver{ .value = .null, .no_rows = true, .capture_sql = true, .dialect_override = .postgres };
    var q_plain = OrderQuery.init(allocator, mock_plain.asDriver(), null);
    defer q_plain.deinit();
    _ = q_plain.ForUpdate();
    var rows_plain = try q_plain.All();
    defer rows_plain.deinit();
    const plain_sql = mock_plain.last_sql_owned orelse return error.MissingCapture;
    defer allocator.free(plain_sql);
    try std.testing.expect(std.mem.indexOf(u8, plain_sql, "FOR UPDATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain_sql, "SKIP LOCKED") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain_sql, "NOWAIT") == null);
}
