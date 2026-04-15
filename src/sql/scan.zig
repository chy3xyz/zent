const std = @import("std");
const Row = @import("driver.zig").Row;

/// Scan a database row into a value of type T.
/// Supports primitives, optional primitives, and structs.
/// String slices are duplicated using the provided allocator.
pub fn scanRow(comptime T: type, allocator: std.mem.Allocator, row: Row) !T {
    const info = @typeInfo(T);
    switch (info) {
        .int => |int| {
            if (int.bits <= 64 and int.signedness == .signed) {
                const v = row.getInt(0) orelse return error.TypeMismatch;
                return @intCast(v);
            }
            @compileError("Unsupported integer type for scanning: " ++ @typeName(T));
        },
        .float => |float| {
            if (float.bits <= 64) {
                const v = row.getFloat(0) orelse return error.TypeMismatch;
                if (T == f32) return @floatCast(v);
                return v;
            }
            @compileError("Unsupported float type for scanning: " ++ @typeName(T));
        },
        .bool => {
            const v = row.getInt(0) orelse return error.TypeMismatch;
            return v != 0;
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                const text = row.getText(0) orelse return error.TypeMismatch;
                return try allocator.dupe(u8, text);
            }
            @compileError("Unsupported pointer type for scanning: " ++ @typeName(T));
        },
        .optional => |opt| {
            if (row.isNull(0)) return null;
            return try scanRow(opt.child, allocator, row);
        },
        .@"struct" => |s| {
            var value: T = undefined;
            inline for (s.fields) |field| {
                const col_index = findColumnIndex(row, field.name);
                if (col_index) |idx| {
                    @field(value, field.name) = try scanColumn(field.type, allocator, row, idx);
                } else {
                    if (@typeInfo(field.type) == .optional) {
                        @field(value, field.name) = null;
                    } else {
                        return error.MissingColumn;
                    }
                }
            }
            return value;
        },
        else => @compileError("Unsupported type for scanning: " ++ @typeName(T)),
    }
}

fn findColumnIndex(row: Row, name: []const u8) ?usize {
    const n = row.columnCount();
    for (0..n) |i| {
        if (std.mem.eql(u8, row.columnName(i), name)) {
            return i;
        }
    }
    return null;
}

fn scanColumn(comptime T: type, allocator: std.mem.Allocator, row: Row, index: usize) !T {
    const info = @typeInfo(T);
    switch (info) {
        .int => |int| {
            if (int.bits <= 64 and int.signedness == .signed) {
                const v = row.getInt(index) orelse return error.TypeMismatch;
                return @intCast(v);
            }
            @compileError("Unsupported integer type for scanning: " ++ @typeName(T));
        },
        .float => |float| {
            if (float.bits <= 64) {
                const v = row.getFloat(index) orelse return error.TypeMismatch;
                if (T == f32) return @floatCast(v);
                return v;
            }
            @compileError("Unsupported float type for scanning: " ++ @typeName(T));
        },
        .bool => {
            const v = row.getInt(index) orelse return error.TypeMismatch;
            return v != 0;
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                const text = row.getText(index) orelse return error.TypeMismatch;
                return try allocator.dupe(u8, text);
            }
            @compileError("Unsupported pointer type for scanning: " ++ @typeName(T));
        },
        .optional => |opt| {
            if (row.isNull(index)) return null;
            return try scanColumn(opt.child, allocator, row, index);
        },
        else => @compileError("Unsupported column type for scanning: " ++ @typeName(T)),
    }
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const MockRowData = struct {
    ints: []const ?i64,
    floats: []const ?f64,
    texts: []const ?[]const u8,
    nulls: []const bool,

    fn columnCountFn(ptr: *anyopaque) usize {
        const self: *const MockRowData = @ptrCast(@alignCast(ptr));
        return self.ints.len;
    }

    fn columnNameFn(ptr: *anyopaque, index: usize) []const u8 {
        _ = ptr;
        const names = [_][]const u8{ "id", "name", "age", "score", "bio" };
        return names[index];
    }

    fn getIntFn(ptr: *anyopaque, index: usize) ?i64 {
        const self: *const MockRowData = @ptrCast(@alignCast(ptr));
        return self.ints[index];
    }

    fn getFloatFn(ptr: *anyopaque, index: usize) ?f64 {
        const self: *const MockRowData = @ptrCast(@alignCast(ptr));
        return self.floats[index];
    }

    fn getTextFn(ptr: *anyopaque, index: usize) ?[]const u8 {
        const self: *const MockRowData = @ptrCast(@alignCast(ptr));
        return self.texts[index];
    }

    fn getBlobFn(_: *anyopaque, _: usize) ?[]const u8 {
        return null;
    }

    fn isNullFn(ptr: *anyopaque, index: usize) bool {
        const self: *const MockRowData = @ptrCast(@alignCast(ptr));
        return self.nulls[index];
    }
};

const mock_vtable = Row.VTable{
    .columnCount = MockRowData.columnCountFn,
    .columnName = MockRowData.columnNameFn,
    .getInt = MockRowData.getIntFn,
    .getFloat = MockRowData.getFloatFn,
    .getText = MockRowData.getTextFn,
    .getBlob = MockRowData.getBlobFn,
    .isNull = MockRowData.isNullFn,
};

test "scan primitive" {
    const data = MockRowData{
        .ints = &.{42},
        .floats = &.{null},
        .texts = &.{null},
        .nulls = &.{false},
    };
    const row = Row{ .ptr = @ptrCast(@constCast(&data)), .vtable = &mock_vtable };
    const v = try scanRow(i32, std.testing.allocator, row);
    try std.testing.expectEqual(@as(i32, 42), v);
}

test "scan struct" {
    const User = struct {
        id: i64,
        name: []const u8,
        age: i32,
    };
    const data = MockRowData{
        .ints = &.{ 1, null, 30 },
        .floats = &.{ null, null, null },
        .texts = &.{ null, "alice", null },
        .nulls = &.{ false, false, false },
    };
    const row = Row{ .ptr = @ptrCast(@constCast(&data)), .vtable = &mock_vtable };
    const user = try scanRow(User, std.testing.allocator, row);
    try std.testing.expectEqual(@as(i64, 1), user.id);
    try std.testing.expectEqualStrings("alice", user.name);
    try std.testing.expectEqual(@as(i32, 30), user.age);
}

test "scan optional null" {
    const data = MockRowData{
        .ints = &.{null},
        .floats = &.{null},
        .texts = &.{null},
        .nulls = &.{true},
    };
    const row = Row{ .ptr = @ptrCast(@constCast(&data)), .vtable = &mock_vtable };
    const v = try scanRow(?i32, std.testing.allocator, row);
    try std.testing.expect(v == null);
}
