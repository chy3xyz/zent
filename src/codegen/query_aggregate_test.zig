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
    };

    const row_vtable = sql_driver.Row.VTable{
        .columnCount = columnCount,
        .columnName = columnName,
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

    fn exec(_: *anyopaque, _: []const u8, _: []const sql.Value) anyerror!sql_driver.Result {
        return .{ .rows_affected = 0, .last_insert_id = null };
    }

    fn query(ptr: *anyopaque, _: []const u8, _: []const sql.Value) anyerror!sql_driver.Rows {
        const self: *MockDriver = @ptrCast(@alignCast(ptr));
        const rows = try std.testing.allocator.create(MockRows);
        rows.* = .{ .value = self.value, .returned = false };
        return sql_driver.Rows{ .ptr = rows, .vtable = &MockRows.vtable };
    }

    fn beginTx(_: *anyopaque) anyerror!sql_driver.Tx {
        return error.Unsupported;
    }

    fn close(_: *anyopaque) void {}

    fn dialect(_: *anyopaque) Dialect {
        return .sqlite;
    }

    fn ping(_: *anyopaque) anyerror!void {}

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
        var q_max = UserQuery.init(allocator, mock_max.asDriver());
        defer q_max.deinit();
        const max = try q_max.Max("name");
        defer if (max == .string) allocator.free(max.string);
        try expectValueEqual(value, max);

        var mock_min = MockDriver{ .value = value };
        var q_min = UserQuery.init(allocator, mock_min.asDriver());
        defer q_min.deinit();
        const min = try q_min.Min("name");
        defer if (min == .string) allocator.free(min.string);
        try expectValueEqual(value, min);
    }
}
