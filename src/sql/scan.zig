const std = @import("std");
const driver_mod = @import("driver.zig");
const Row = driver_mod.Row;
const Rows = driver_mod.Rows;
const Driver = driver_mod.Driver;
const Value = @import("value.zig").Value;

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

/// Like `zeroInit`, but a field carrying a declared Zig default keeps that
/// default instead of being zeroed. This is the "default value" the lenient
/// scanners fall back to, so a DTO can express what an absent column means
/// (`retries: u32 = 3`) without an explicit conversion step.
///
/// `std.json.Value` has no zeroable representation, so it still defaults to
/// `.null`.
fn defaultInit(comptime T: type) T {
    var value: T = undefined;
    const ei = @typeInfo(T).@"struct";
    inline for (ei.field_names, ei.field_types, ei.field_attrs) |fname, ftype, attrs| {
        if (attrs.defaultValue(ftype)) |declared| {
            @field(value, fname) = declared;
        } else if (comptime ftype == std.json.Value) {
            @field(value, fname) = .null;
        } else {
            @field(value, fname) = std.mem.zeroes(ftype);
        }
    }
    return value;
}

/// Scan a database row with the **NULL-is-absent** policy: a NULL column
/// leaves its struct field at the default value from `defaultInit` (declared
/// Zig default, else zero; `null` for optionals, `.null` for
/// `std.json.Value`) instead of failing with `error.TypeMismatch`.
///
/// Every other scanner here is strict, which is the right default for entity
/// reads — a NULL in a non-optional schema column means the row does not
/// match the schema. This variant exists for the other, equally common
/// contract: ad-hoc queries and DTOs whose columns are genuinely nullable
/// (`LEFT JOIN`ed lookups, aggregate outputs, PHP-style "absent means
/// default" tables). Without it, callers hand-roll a scanner to get that
/// behaviour.
///
/// Only the NULL policy differs: column mapping stays positional
/// (declaration order), and a NULL for an optional field still yields `null`.
/// Scalar `T` reads a single column and yields its zero value on NULL.
pub fn scanRowLenient(comptime T: type, allocator: std.mem.Allocator, row: Row) !T {
    return scanRowLenientWithArena(T, allocator, row, null);
}

/// Like `scanRowLenient`, but JSON struct fields are parsed into
/// `json_arena`, matching `scanRowWithArena`.
pub fn scanRowLenientWithArena(comptime T: type, allocator: std.mem.Allocator, row: Row, json_arena: ?*std.heap.ArenaAllocator) !T {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |s| {
            var value: T = defaultInit(T);
            var col_idx: usize = 0;
            inline for (s.field_names, s.field_types) |field_name, field_type| {
                if (comptime std.mem.eql(u8, field_name, "edges")) {
                    @field(value, field_name) = @as(@TypeOf(@field(value, field_name)), .{});
                } else if (comptime std.mem.eql(u8, field_name, "json_arena")) {
                    @field(value, field_name) = json_arena;
                } else {
                    if (!row.isNull(col_idx)) {
                        @field(value, field_name) = try scanColumn(field_type, allocator, row, col_idx, json_arena);
                    }
                    col_idx += 1;
                }
            }
            return value;
        },
        else => {
            if (row.isNull(0)) return std.mem.zeroes(T);
            return scanRowWithArena(T, allocator, row, json_arena);
        },
    }
}

/// Maps a Zig struct field to the physical column it is read from.
pub const ColumnMap = struct {
    /// Zig struct field name (the struct field the value is written to).
    name: []const u8,
    /// Physical SQL column name (the result-set column to read).
    column: []const u8,
};

/// Like `scanRowNamed`, but columns are resolved through an explicit
/// `columns` mapping: `ColumnMap.column` is looked up in the row and the
/// value is written to `ColumnMap.name`. Used for entities whose Zig field
/// names differ from their SQL column names (`StorageKey`).
pub fn scanRowNamedMapped(comptime T: type, allocator: std.mem.Allocator, row: Row, columns: []const ColumnMap) !T {
    return scanRowNamedMappedWithArena(T, allocator, row, columns, null);
}

/// Like `scanRowNamedMapped`, but JSON struct fields are parsed into
/// `json_arena`.
pub fn scanRowNamedMappedWithArena(comptime T: type, allocator: std.mem.Allocator, row: Row, columns: []const ColumnMap, json_arena: ?*std.heap.ArenaAllocator) !T {
    return scanRowNamedImpl(T, allocator, row, columns, json_arena, false);
}

fn mappedColumn(columns: []const ColumnMap, field_name: []const u8) ?[]const u8 {
    for (columns) |c| {
        if (std.mem.eql(u8, c.name, field_name)) return c.column;
    }
    return null;
}

/// Like `scanRowNamed`, but JSON struct fields are parsed into `json_arena`.
pub fn scanRowNamedWithArena(comptime T: type, allocator: std.mem.Allocator, row: Row, json_arena: ?*std.heap.ArenaAllocator) !T {
    return scanRowNamedImpl(T, allocator, row, &.{}, json_arena, false);
}

/// Like `scanRowNamedLenient`, but JSON struct fields are parsed into
/// `json_arena`.
pub fn scanRowNamedLenientWithArena(comptime T: type, allocator: std.mem.Allocator, row: Row, json_arena: ?*std.heap.ArenaAllocator) !T {
    return scanRowNamedImpl(T, allocator, row, &.{}, json_arena, true);
}

/// Name-resolved counterpart of `scanRowLenient`, and the variant most
/// partial projections want: a column absent from the result set *or* NULL
/// leaves its field at the default, so a `SELECT` that omits columns and a
/// `LEFT JOIN` that produces NULLs behave the same way.
pub fn scanRowNamedLenient(comptime T: type, allocator: std.mem.Allocator, row: Row) !T {
    return scanRowNamedLenientWithArena(T, allocator, row, null);
}

/// Like `scanRowNamedLenientWithArena`, but columns are resolved through an
/// explicit `columns` mapping (`ColumnMap.column` is read, `ColumnMap.name` is
/// written), matching `scanRowNamedMappedWithArena`.
pub fn scanRowNamedLenientMappedWithArena(comptime T: type, allocator: std.mem.Allocator, row: Row, columns: []const ColumnMap, json_arena: ?*std.heap.ArenaAllocator) !T {
    return scanRowNamedImpl(T, allocator, row, columns, json_arena, true);
}

/// Like `scanRowNamedLenientMappedWithArena` with the caller's allocator for
/// JSON fields.
pub fn scanRowNamedLenientMapped(comptime T: type, allocator: std.mem.Allocator, row: Row, columns: []const ColumnMap) !T {
    return scanRowNamedImpl(T, allocator, row, columns, null, true);
}

/// Shared body of the name-resolved scanners. `lenient` picks the NULL
/// policy; an empty `columns` slice means "field name is the column name".
fn scanRowNamedImpl(
    comptime T: type,
    allocator: std.mem.Allocator,
    row: Row,
    columns: []const ColumnMap,
    json_arena: ?*std.heap.ArenaAllocator,
    comptime lenient: bool,
) !T {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("scanRowNamed supports structs only");
    var value: T = if (lenient) defaultInit(T) else zeroInit(T);
    inline for (info.@"struct".field_names, info.@"struct".field_types) |field_name, field_type| {
        if (comptime std.mem.eql(u8, field_name, "edges")) {
            @field(value, field_name) = @as(@TypeOf(@field(value, field_name)), .{});
        } else if (comptime std.mem.eql(u8, field_name, "json_arena")) {
            @field(value, field_name) = json_arena;
        } else {
            const lookup = mappedColumn(columns, field_name) orelse field_name;
            if (findColumnIndex(row, lookup)) |idx| {
                if (!lenient or !row.isNull(idx)) {
                    @field(value, field_name) = try scanColumn(field_type, allocator, row, idx, json_arena);
                }
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

/// Run `sql_text` on `driver` and scan every row into the DTO type `T`,
/// mapping result columns to struct fields by name (`scanRowNamed`
/// semantics: unselected fields keep zero values).
///
/// Ownership: string fields are duplicated with `allocator`. Release each
/// item with `freeDto(T, allocator, &item)`, then `list.deinit()`. DTOs
/// carrying JSON-struct / `std.json.Value` fields are parsed leaky into
/// `allocator` — scan those under an arena instead of freeing per item.
pub fn queryAll(
    comptime T: type,
    allocator: std.mem.Allocator,
    driver: Driver,
    sql_text: []const u8,
    args: []const Value,
) !std.array_list.Managed(T) {
    var rows = try driver.query(sql_text, args);
    defer rows.deinit();
    var list = std.array_list.Managed(T).init(allocator);
    errdefer {
        for (list.items) |*item| freeDto(T, allocator, item);
        list.deinit();
    }
    while (rows.next()) |row| {
        try list.append(try scanRowNamed(T, allocator, row));
    }
    if (rows.nextError()) |err| return err;
    return list;
}

/// Like `queryAll`, but scans at most the first row; `null` when the
/// result set is empty. Release with `freeDto(T, allocator, &item)`.
pub fn queryOne(
    comptime T: type,
    allocator: std.mem.Allocator,
    driver: Driver,
    sql_text: []const u8,
    args: []const Value,
) !?T {
    var rows = try driver.query(sql_text, args);
    defer rows.deinit();
    const row = rows.next() orelse {
        if (rows.nextError()) |err| return err;
        return null;
    };
    return try scanRowNamed(T, allocator, row);
}

/// Free the memory owned by a DTO scanned with `scanRowNamed`, `queryAll`,
/// or `queryOne`: every `[]u8` / `[]const u8` field (including optionals)
/// duplicated at scan time. Unselected fields are zero-initialized empty
/// slices, which free as no-ops. JSON-struct / `std.json.Value` fields are
/// skipped — those are parsed leaky; use an arena for such DTOs.
pub fn freeDto(comptime T: type, allocator: std.mem.Allocator, dto: *const T) void {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        freeDtoValue(field_type, allocator, @field(dto, field_name));
    }
}

fn freeDtoValue(comptime T: type, allocator: std.mem.Allocator, value: T) void {
    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) allocator.free(value);
        },
        .optional => |opt| {
            if (value) |v| freeDtoValue(opt.child, allocator, v);
        },
        else => {},
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

test "scanRowLenient leaves NULL fields at their default instead of failing" {
    const Dto = struct {
        id: i64,
        name: []const u8,
        age: i32,
        score: i32,
        retries: i32 = 3,
    };
    const data = MockRowData{
        .ints = &.{ 7, null, null, 42, null },
        .floats = &.{ null, null, null, null, null },
        .texts = &.{ null, null, null, null, null },
        .bools = &.{ null, null, null, null, null },
        // `name`, `age` and `retries` are NULL; `id` and `score` are not.
        .nulls = &.{ false, true, true, false, true },
    };
    const row = Row{ .ptr = @ptrCast(@constCast(&data)), .vtable = &mock_vtable };

    // The strict contract is unchanged: a NULL in a non-optional field is an
    // error, which is what keeps the lenient variant opt-in.
    try std.testing.expectError(error.TypeMismatch, scanRow(Dto, std.testing.allocator, row));

    const dto = try scanRowLenient(Dto, std.testing.allocator, row);
    try std.testing.expectEqual(@as(i64, 7), dto.id);
    try std.testing.expectEqual(@as(i32, 42), dto.score);
    try std.testing.expectEqualStrings("", dto.name);
    try std.testing.expectEqual(@as(i32, 0), dto.age);
    // A declared Zig default wins over the zero value.
    try std.testing.expectEqual(@as(i32, 3), dto.retries);
}

test "scanRowLenient keeps null for optional fields and reads scalars" {
    const Dto = struct {
        id: i64,
        nickname: ?[]const u8,
        age: ?i32,
    };
    const data = MockRowData{
        .ints = &.{ 9, null, null },
        .floats = &.{ null, null, null },
        .texts = &.{ null, null, null },
        .bools = &.{ null, null, null },
        .nulls = &.{ false, true, true },
    };
    const row = Row{ .ptr = @ptrCast(@constCast(&data)), .vtable = &mock_vtable };
    const dto = try scanRowLenient(Dto, std.testing.allocator, row);
    try std.testing.expectEqual(@as(i64, 9), dto.id);
    try std.testing.expectEqual(@as(?[]const u8, null), dto.nickname);
    try std.testing.expectEqual(@as(?i32, null), dto.age);

    // Scalar reads: NULL yields the zero value rather than an error.
    const null_scalar = MockRowData{
        .ints = &.{null},
        .floats = &.{null},
        .texts = &.{null},
        .bools = &.{null},
        .nulls = &.{true},
    };
    const srow = Row{ .ptr = @ptrCast(@constCast(&null_scalar)), .vtable = &mock_vtable };
    try std.testing.expectEqual(@as(i64, 0), try scanRowLenient(i64, std.testing.allocator, srow));
}

test "scanRowNamedLenient tolerates NULL and missing columns alike" {
    const Dto = struct {
        id: i64,
        name: []const u8,
    };
    // `name` is NULL; `age`/`score`/`bio` exist in the row but not in the DTO,
    // so they are simply never looked up.
    const data = MockRowData{
        .ints = &.{ 4, null, null, null, null },
        .floats = &.{ null, null, null, null, null },
        .texts = &.{ null, null, null, null, null },
        .bools = &.{ null, null, null, null, null },
        .nulls = &.{ false, true, true, true, true },
    };
    const row = Row{ .ptr = @ptrCast(@constCast(&data)), .vtable = &mock_vtable };

    // Strict named scanning tolerates a *missing* column but not a NULL one —
    // which is exactly the split the lenient scanner removes.
    try std.testing.expectError(error.TypeMismatch, scanRowNamed(Dto, std.testing.allocator, row));

    const dto = try scanRowNamedLenient(Dto, std.testing.allocator, row);
    try std.testing.expectEqual(@as(i64, 4), dto.id);
    try std.testing.expectEqualStrings("", dto.name);

    // The mapped variant resolves physical column names through `columns`.
    const Mapped = struct {
        primary: i64,
        label: []const u8,
    };
    const mapping = [_]ColumnMap{
        .{ .name = "primary", .column = "id" },
        .{ .name = "label", .column = "name" },
    };
    const mapped = try scanRowNamedLenientMapped(Mapped, std.testing.allocator, row, &mapping);
    try std.testing.expectEqual(@as(i64, 4), mapped.primary);
    try std.testing.expectEqualStrings("", mapped.label);
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

// ------------------------------------------------------------------
// queryAll / queryOne / freeDto tests
// ------------------------------------------------------------------

const NamedRowData = struct {
    names: []const []const u8,
    ints: []const ?i64,
    texts: []const ?[]const u8,
    nulls: []const bool,

    fn columnCountFn(ptr: *anyopaque) usize {
        const self: *const NamedRowData = @ptrCast(@alignCast(ptr));
        return self.names.len;
    }

    fn columnNameFn(ptr: *anyopaque, index: usize) []const u8 {
        const self: *const NamedRowData = @ptrCast(@alignCast(ptr));
        return self.names[index];
    }

    fn getIntFn(ptr: *anyopaque, index: usize) ?i64 {
        const self: *const NamedRowData = @ptrCast(@alignCast(ptr));
        return self.ints[index];
    }

    fn getTextFn(ptr: *anyopaque, index: usize) ?[]const u8 {
        const self: *const NamedRowData = @ptrCast(@alignCast(ptr));
        return self.texts[index];
    }

    fn nullFn(_: *anyopaque, _: usize) ?f64 {
        return null;
    }

    fn nullBoolFn(_: *anyopaque, _: usize) ?bool {
        return null;
    }

    fn nullBlobFn(_: *anyopaque, _: usize) ?[]const u8 {
        return null;
    }

    fn isNullFn(ptr: *anyopaque, index: usize) bool {
        const self: *const NamedRowData = @ptrCast(@alignCast(ptr));
        return self.nulls[index];
    }
};

const named_row_vtable = Row.VTable{
    .columnCount = NamedRowData.columnCountFn,
    .columnName = NamedRowData.columnNameFn,
    .getBool = NamedRowData.nullBoolFn,
    .getInt = NamedRowData.getIntFn,
    .getFloat = NamedRowData.nullFn,
    .getText = NamedRowData.getTextFn,
    .getBlob = NamedRowData.nullBlobFn,
    .isNull = NamedRowData.isNullFn,
};

const ListRows = struct {
    data: []const NamedRowData,
    cursor: usize = 0,

    const rows_vtable = Rows.VTable{
        .next = nextFn,
        .deinit = deinitFn,
        .nextError = null,
    };

    fn nextFn(ptr: *anyopaque) ?Row {
        const self: *ListRows = @ptrCast(@alignCast(ptr));
        if (self.cursor >= self.data.len) return null;
        defer self.cursor += 1;
        return Row{ .ptr = @ptrCast(@constCast(&self.data[self.cursor])), .vtable = &named_row_vtable };
    }

    fn deinitFn(ptr: *anyopaque) void {
        std.testing.allocator.destroy(@as(*ListRows, @ptrCast(@alignCast(ptr))));
    }
};

const ListDriver = struct {
    rows_data: []const NamedRowData,
    last_sql: ?[]const u8 = null,

    const driver_vtable = Driver.VTable{
        .exec = execFn,
        .query = queryFn,
        .beginTx = txFailFn,
        .close = closeFn,
        .dialect = dialectFn,
        .ping = pingFn,
        .inTransaction = inTxFn,
        .beginSavepoint = savepointFailFn,
    };

    fn asDriver(self: *ListDriver) Driver {
        return Driver{ .ptr = self, .vtable = &driver_vtable };
    }

    fn execFn(_: *anyopaque, _: ?*const driver_mod.ExecutionContext, _: []const u8, _: []const Value) driver_mod.Error!driver_mod.Result {
        return .{ .rows_affected = 0, .last_insert_id = null };
    }

    fn queryFn(ptr: *anyopaque, _: ?*const driver_mod.ExecutionContext, sql_text: []const u8, _: []const Value) driver_mod.Error!Rows {
        const self: *ListDriver = @ptrCast(@alignCast(ptr));
        self.last_sql = sql_text;
        const rows = try std.testing.allocator.create(ListRows);
        rows.* = .{ .data = self.rows_data };
        return Rows{ .ptr = rows, .vtable = &ListRows.rows_vtable };
    }

    fn txFailFn(_: *anyopaque) driver_mod.Error!driver_mod.Tx {
        return error.TxFailed;
    }

    fn savepointFailFn(_: *anyopaque, _: []const u8) driver_mod.Error!driver_mod.Tx {
        return error.TxFailed;
    }

    fn closeFn(_: *anyopaque) void {}

    fn dialectFn(_: *anyopaque) @import("dialect.zig").Dialect {
        return .sqlite;
    }

    fn pingFn(_: *anyopaque) driver_mod.Error!void {}

    fn inTxFn(_: *anyopaque) bool {
        return false;
    }
};

test "queryAll scans all rows into DTOs by column name and frees cleanly" {
    const allocator = std.testing.allocator;
    const Item = struct {
        sku_id: i64,
        title: []const u8,
        memo: ?[]const u8,
        unselected: i64,
    };
    const rows_data = &[_]NamedRowData{
        .{
            .names = &.{ "sku_id", "title", "memo" },
            .ints = &.{ 1, null, null },
            .texts = &.{ null, "apple", "fresh" },
            .nulls = &.{ false, false, false },
        },
        .{
            .names = &.{ "sku_id", "title", "memo" },
            .ints = &.{ 2, null, null },
            .texts = &.{ null, "banana", null },
            .nulls = &.{ false, false, true },
        },
    };
    var drv = ListDriver{ .rows_data = rows_data };
    var list = try queryAll(Item, allocator, drv.asDriver(), "SELECT sku_id, title, memo FROM sku", &.{});
    defer {
        for (list.items) |*item| freeDto(Item, allocator, item);
        list.deinit();
    }
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(@as(i64, 1), list.items[0].sku_id);
    try std.testing.expectEqualStrings("apple", list.items[0].title);
    try std.testing.expectEqualStrings("fresh", list.items[0].memo.?);
    try std.testing.expectEqual(@as(i64, 0), list.items[0].unselected);
    try std.testing.expectEqual(@as(i64, 2), list.items[1].sku_id);
    try std.testing.expectEqual(@as(?[]const u8, null), list.items[1].memo);
    try std.testing.expectEqualStrings("SELECT sku_id, title, memo FROM sku", drv.last_sql.?);
}

test "queryOne scans the first row and returns null when empty" {
    const allocator = std.testing.allocator;
    const Item = struct {
        sku_id: i64,
        title: []const u8,
    };
    const rows_data = &[_]NamedRowData{
        .{
            .names = &.{ "sku_id", "title" },
            .ints = &.{ 7, null },
            .texts = &.{ null, "pear" },
            .nulls = &.{ false, false },
        },
    };
    var drv = ListDriver{ .rows_data = rows_data };
    const one = (try queryOne(Item, allocator, drv.asDriver(), "SELECT ...", &.{})) orelse return error.ExpectedRow;
    defer freeDto(Item, allocator, &one);
    try std.testing.expectEqual(@as(i64, 7), one.sku_id);
    try std.testing.expectEqualStrings("pear", one.title);

    var drv_empty = ListDriver{ .rows_data = &.{} };
    try std.testing.expect((try queryOne(Item, allocator, drv_empty.asDriver(), "SELECT ...", &.{})) == null);
}

test "queryAll frees scanned items when a later row fails" {
    const allocator = std.testing.allocator;
    const Item = struct {
        sku_id: i64,
        title: []const u8,
    };
    // Second row has sku_id NULL → scanRowNamed raises TypeMismatch after the
    // first item (with an owned string) was already appended; errdefer must
    // free it. std.testing.allocator turns any leak into a test failure.
    const rows_data = &[_]NamedRowData{
        .{
            .names = &.{ "sku_id", "title" },
            .ints = &.{ 1, null },
            .texts = &.{ null, "apple" },
            .nulls = &.{ false, false },
        },
        .{
            .names = &.{ "sku_id", "title" },
            .ints = &.{ null, null },
            .texts = &.{ null, "bad" },
            .nulls = &.{ true, false },
        },
    };
    var drv = ListDriver{ .rows_data = rows_data };
    try std.testing.expectError(error.TypeMismatch, queryAll(Item, allocator, drv.asDriver(), "SELECT ...", &.{}));
}
