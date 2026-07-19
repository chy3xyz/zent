const std = @import("std");
const Row = @import("driver.zig").Row;

/// Scan a database row into a value of type T.
/// Supports primitives, optional primitives, and structs.
/// String slices are duplicated using the provided allocator.
///
/// For struct types, columns are assumed to be in declaration order
/// matching the SELECT projection — no name-based lookup is performed.
/// This eliminates O(n*m) string comparisons per row.
///
/// NOTE: scanRow does not have access to the entity, so JSON struct fields
/// parsed here are allocated directly into `allocator` and are NOT freed by
/// deinitEntity. The caller must free them manually, or use the codegen Create
/// path which stores parsed JSON in the entity's json_arena.
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
            var col_idx: usize = 0;
            inline for (s.field_names, s.field_types) |field_name, field_type| {
                if (comptime std.mem.eql(u8, field_name, "edges")) {
                    @field(value, field_name) = @as(@TypeOf(@field(value, field_name)), .{});
                } else if (comptime std.mem.eql(u8, field_name, "json_arena")) {
                    @field(value, field_name) = @as(@TypeOf(@field(value, field_name)), null);
                } else {
                    @field(value, field_name) = try scanColumn(field_type, allocator, row, col_idx);
                    col_idx += 1;
                }
            }
            return value;
        },
        else => @compileError("Unsupported type for scanning: " ++ @typeName(T)),
    }
}

/// Like scanRow but uses the column `offset` to map struct fields to
/// result-set columns. The struct's i-th non-edge field maps to row
/// column `offset + i`. Used when the entity is part of a larger
/// multi-table projection.
pub fn scanRowOffset(comptime T: type, allocator: std.mem.Allocator, row: Row, comptime offset: usize) !T {
    return scanRowInner(T, allocator, row, offset);
}

/// Scan a database row into a value of type T without using an allocator.
///
/// Only primitive, non-allocating types are supported:
///   - signed integers up to 64 bits
///   - floats up to 64 bits
///   - booleans
///   - optionals of the above
///   - structs whose fields are exclusively the above
///
/// String slices, nested structs, and JSON-decoded fields are rejected at
/// compile time. This is intended for hot paths where every allocation matters.
pub fn scanRowNoAlloc(comptime T: type, row: Row) !T {
    comptime {
        const info = @typeInfo(T);
        if (info != .@"struct") {
            @compileError("scanRowNoAlloc only supports structs; got " ++ @typeName(T));
        }
        for (info.@"struct".field_types) |FieldType| {
            switch (@typeInfo(FieldType)) {
                .int, .float, .bool => {},
                .optional => |opt| {
                    switch (@typeInfo(opt.child)) {
                        .int, .float, .bool => {},
                        else => @compileError("scanRowNoAlloc does not support allocating types in optional: " ++ @typeName(FieldType)),
                    }
                },
                else => @compileError("scanRowNoAlloc does not support allocating types: " ++ @typeName(FieldType)),
            }
        }
    }
    return scanRowInnerNoAlloc(T, row, 0);
}

fn scanColumnNoAlloc(comptime T: type, row: Row, index: usize) !T {
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
        .optional => |opt| {
            if (row.isNull(index)) return null;
            return try scanColumnNoAlloc(opt.child, row, index);
        },
        else => @compileError("Unsupported type for no-alloc scanning: " ++ @typeName(T)),
    }
}

fn scanRowInnerNoAlloc(comptime T: type, row: Row, comptime offset: usize) !T {
    const info = @typeInfo(T);
    var value: T = undefined;
    var col_idx: usize = offset;
    inline for (info.@"struct".field_names, info.@"struct".field_types) |field_name, field_type| {
        if (comptime std.mem.eql(u8, field_name, "edges")) {
            @field(value, field_name) = @as(@TypeOf(@field(value, field_name)), .{});
        } else if (comptime std.mem.eql(u8, field_name, "json_arena")) {
            @field(value, field_name) = @as(@TypeOf(@field(value, field_name)), null);
        } else {
            @field(value, field_name) = try scanColumnNoAlloc(field_type, row, col_idx);
            col_idx += 1;
        }
    }
    return value;
}

fn scanRowInner(comptime T: type, allocator: std.mem.Allocator, row: Row, comptime offset: usize) !T {
    const info = @typeInfo(T);
    switch (info) {
        .int, .float, .bool, .pointer, .optional => return scanRow(T, allocator, row),
        .@"struct" => |s| {
            var value: T = undefined;
            var col_idx: usize = offset;
            inline for (s.field_names, s.field_types) |field_name, field_type| {
                if (comptime std.mem.eql(u8, field_name, "edges")) {
                    @field(value, field_name) = @as(@TypeOf(@field(value, field_name)), .{});
                } else if (comptime std.mem.eql(u8, field_name, "json_arena")) {
                    @field(value, field_name) = @as(@TypeOf(@field(value, field_name)), null);
                } else {
                    @field(value, field_name) = try scanColumn(field_type, allocator, row, col_idx);
                    col_idx += 1;
                }
            }
            return value;
        },
        else => @compileError("Unsupported type for scanning: " ++ @typeName(T)),
    }
}

pub fn findColumnIndex(row: Row, name: []const u8) ?usize {
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
        .@"struct" => {
            const text = row.getText(index) orelse return error.TypeMismatch;
            // NOTE: scanRow does not have access to the entity, so JSON structs
            // parsed here are allocated directly into `allocator`. Ownership is
            // leaked to the caller unless they free the data manually.
            return std.json.parseFromSliceLeaky(T, allocator, text, .{}) catch return error.TypeMismatch;
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
    defer std.testing.allocator.free(user.name);
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
