const std = @import("std");
const sql = @import("../sql/builder.zig");
const sql_driver = @import("../sql/driver.zig");
const Dialect = @import("../sql/dialect.zig").Dialect;
const TypeInfo = @import("graph.zig").TypeInfo;
const fromSchema = @import("graph.zig").fromSchema;
const EntityGen = @import("entity.zig").Entity;
const QueryBuilder = @import("query.zig").QueryBuilder;
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

    const vtable = sql_driver.Driver.VTable{
        .exec = exec,
        .query = query,
        .beginTx = beginTx,
        .close = close,
        .dialect = dialect,
        .ping = ping,
        .inTransaction = inTransaction,
    };

    fn asDriver(self: *MockDriver) sql_driver.Driver {
        return sql_driver.Driver{ .ptr = self, .vtable = &vtable };
    }

    fn exec(_: *anyopaque, _: ?*const sql_driver.ExecutionContext, _: []const u8, _: []const sql.Value) sql_driver.Error!sql_driver.Result {
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

    fn close(_: *anyopaque) void {}

    fn dialect(_: *anyopaque) Dialect {
        return .sqlite;
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
