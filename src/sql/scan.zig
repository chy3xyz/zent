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
/// NOTE: bare scanRow has no access to the entity, so JSON struct fields
/// parsed here are allocated into `allocator` and are NOT freed by
/// deinitEntity. Entity scans must use `scanRowWithArena` (or the named/
/// offset variants), which routes JSON parsing into a per-entity arena that
/// deinitEntity frees — see src/codegen/query.zig.
pub fn scanRow(comptime T: type, allocator: std.mem.Allocator, row: Row) !T {
    return scanRowWithArena(T, allocator, row, null);
}

/// Like `scanRow`, but JSON struct fields are parsed into `json_arena` so a
/// single arena deinit releases them. Used by entity scans; the entity's
/// json_arena field is set to `json_arena` so deinitEntity can free it.
pub fn scanRowWithArena(comptime T: type, allocator: std.mem.Allocator, row: Row, json_arena: ?*std.heap.ArenaAllocator) !T {
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
            return try scanRowWithArena(opt.child, allocator, row, json_arena);
        },
        .@"struct" => |s| {
            var value: T = undefined;
            var col_idx: usize = 0;
            inline for (s.field_names, s.field_types) |field_name, field_type| {
                if (comptime std.mem.eql(u8, field_name, "edges")) {
                    @field(value, field_name) = @as(@TypeOf(@field(value, field_name)), .{});
                } else if (comptime std.mem.eql(u8, field_name, "json_arena")) {
                    @field(value, field_name) = json_arena;
                } else {
                    @field(value, field_name) = try scanColumn(field_type, allocator, row, col_idx, json_arena);
                    col_idx += 1;
                }
            }
            return value;
        },
        .@"enum" => return try scanColumn(T, allocator, row, 0, json_arena),
        else => @compileError("Unsupported type for scanning: " ++ @typeName(T)),
    }
}

/// Like scanRow but resolves columns by name (Row.findColumnIndex), so a
/// partial projection (`QueryBuilder.Select`) scans only the selected
/// columns; unselected fields keep their zero value and must not be freed
/// (treat projected entities as read-only).
pub fn scanRowNamed(comptime T: type, allocator: std.mem.Allocator, row: Row) !T {
    return scanRowNamedWithArena(T, allocator, row, null);
}

/// Field-by-field zero-initialization. `std.mem.zeroes` rejects structs that
/// carry a `std.json.Value` field (std forbids zeroing Value), so those
/// fields default to `.null` while everything else is zeroed. Used by entity
/// scans and the create path.
pub fn zeroInit(comptime T: type) T {
    var value: T = undefined;
    const ei = @typeInfo(T).@"struct";
    inline for (ei.field_names, ei.field_types) |fname, ftype| {
        if (comptime ftype == std.json.Value) {
            @field(value, fname) = .null;
        } else {
            @field(value, fname) = std.mem.zeroes(ftype);
        }
    }
    return value;
}

/// Like `scanRowNamed`, but JSON struct fields are parsed into `json_arena`.
pub fn scanRowNamedWithArena(comptime T: type, allocator: std.mem.Allocator, row: Row, json_arena: ?*std.heap.ArenaAllocator) !T {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("scanRowNamed supports structs only");
    var value: T = zeroInit(T);
    inline for (info.@"struct".field_names, info.@"struct".field_types) |field_name, field_type| {
        if (comptime std.mem.eql(u8, field_name, "edges")) {
            @field(value, field_name) = @as(@TypeOf(@field(value, field_name)), .{});
        } else if (comptime std.mem.eql(u8, field_name, "json_arena")) {
            @field(value, field_name) = json_arena;
        } else {
            if (findColumnIndex(row, field_name)) |idx| {
                @field(value, field_name) = try scanColumn(field_type, allocator, row, idx, json_arena);
            }
        }
    }
    return value;
}

/// Like scanRow but uses the column `offset` to map struct fields to
/// result-set columns. The struct's i-th non-edge field maps to row
/// column `offset + i`. Used when the entity is part of a larger
/// multi-table projection.
pub fn scanRowOffset(comptime T: type, allocator: std.mem.Allocator, row: Row, comptime offset: usize) !T {
    return scanRowInner(T, allocator, row, offset, null);
}

/// Like `scanRowOffset`, but JSON struct fields are parsed into `json_arena`.
pub fn scanRowOffsetWithArena(comptime T: type, allocator: std.mem.Allocator, row: Row, comptime offset: usize, json_arena: ?*std.heap.ArenaAllocator) !T {
    return scanRowInner(T, allocator, row, offset, json_arena);
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
            const v = row.getBool(index) orelse return error.TypeMismatch;
            return v;
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

fn scanRowInner(comptime T: type, allocator: std.mem.Allocator, row: Row, comptime offset: usize, json_arena: ?*std.heap.ArenaAllocator) !T {
    const info = @typeInfo(T);
    switch (info) {
        .int, .float, .bool, .pointer, .optional, .@"enum" => return scanRowWithArena(T, allocator, row, json_arena),
        .@"struct" => |s| {
            var value: T = undefined;
            var col_idx: usize = offset;
            inline for (s.field_names, s.field_types) |field_name, field_type| {
                if (comptime std.mem.eql(u8, field_name, "edges")) {
                    @field(value, field_name) = @as(@TypeOf(@field(value, field_name)), .{});
                } else if (comptime std.mem.eql(u8, field_name, "json_arena")) {
                    @field(value, field_name) = json_arena;
                } else {
                    @field(value, field_name) = try scanColumn(field_type, allocator, row, col_idx, json_arena);
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

fn scanColumn(comptime T: type, allocator: std.mem.Allocator, row: Row, index: usize, json_arena: ?*std.heap.ArenaAllocator) !T {
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
            const v = row.getBool(index) orelse return error.TypeMismatch;
            return v;
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
            return try scanColumn(opt.child, allocator, row, index, json_arena);
        },
        .@"struct" => {
            const text = row.getText(index) orelse return error.TypeMismatch;
            // Entity scans pass a per-entity arena so deinitEntity frees the
            // parsed JSON in one shot; bare scans (json_arena == null) fall
            // back to the caller's allocator, so those strings stay
            // caller-owned (unfreed by deinitEntity).
            const a = if (json_arena) |arena| arena.allocator() else allocator;
            return std.json.parseFromSliceLeaky(T, a, text, .{}) catch return error.TypeMismatch;
        },
        .@"union" => {
            // Only std.json.Value (field.JSONValue) is supported as an
            // untyped JSON document.
            if (T != std.json.Value)
                @compileError("Unsupported union type for scanning: " ++ @typeName(T));
            const text = row.getText(index) orelse return error.TypeMismatch;
            const a = if (json_arena) |arena| arena.allocator() else allocator;
            return std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return error.TypeMismatch;
        },
        .@"enum" => {
            if (row.getInt(index)) |v| {
                const int_val = std.math.cast(@typeInfo(T).@"enum".tag_type, v) orelse return error.TypeMismatch;
                return @fromBackingInt(@intCast(int_val));
            }
            if (row.getText(index)) |text| {
                return std.meta.stringToEnum(T, text) orelse return error.TypeMismatch;
            }
            return error.TypeMismatch;
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
    bools: []const ?bool,
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

    fn getBoolFn(ptr: *anyopaque, index: usize) ?bool {
        const self: *const MockRowData = @ptrCast(@alignCast(ptr));
        return self.bools[index];
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
    .getBool = MockRowData.getBoolFn,
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
        .bools = &.{null},
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
        .bools = &.{ null, null, null },
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
        .bools = &.{null},
        .nulls = &.{true},
    };
    const row = Row{ .ptr = @ptrCast(@constCast(&data)), .vtable = &mock_vtable };
    const v = try scanRow(?i32, std.testing.allocator, row);
    try std.testing.expectEqual(@as(?i32, null), v);
}

test "scan enum from int and string" {
    const Status = enum { active, pending, deleted };

    // Scan enum from integer index 1 (pending)
    {
        const data = MockRowData{
            .ints = &.{1},
            .floats = &.{null},
            .texts = &.{null},
            .bools = &.{null},
            .nulls = &.{false},
        };
        const row = Row{ .ptr = @ptrCast(@constCast(&data)), .vtable = &mock_vtable };
        const st = try scanRow(Status, std.testing.allocator, row);
        try std.testing.expectEqual(Status.pending, st);
    }

    // Scan enum from string "deleted"
    {
        const data = MockRowData{
            .ints = &.{null},
            .floats = &.{null},
            .texts = &.{"deleted"},
            .bools = &.{null},
            .nulls = &.{false},
        };
        const row = Row{ .ptr = @ptrCast(@constCast(&data)), .vtable = &mock_vtable };
        const st = try scanRow(Status, std.testing.allocator, row);
        try std.testing.expectEqual(Status.deleted, st);
    }
}
