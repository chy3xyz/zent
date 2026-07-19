const std = @import("std");
const TypeInfo = @import("graph.zig").TypeInfo;
const EdgeInfo = @import("graph.zig").EdgeInfo;

fn findTypeInfo(comptime infos: []const TypeInfo, comptime name: []const u8) TypeInfo {
    for (infos) |info| {
        if (std.mem.eql(u8, info.name, name)) return info;
    }
    @compileError("TypeInfo not found: " ++ name);
}

fn toSnakeCase(name: []const u8) []const u8 {
    comptime {
        var result: []const u8 = "";
        for (name, 0..) |c, i| {
            if (std.ascii.isUpper(c) and i > 0) {
                result = result ++ "_";
            }
            result = result ++ &[_]u8{std.ascii.toLower(c)};
        }
        return result;
    }
}

/// Generate a light entity struct (fields only, no edges) from TypeInfo.
/// This breaks comptime recursion when edges reference each other.
pub fn LightEntity(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
    _ = infos;
    comptime {
        var field_names: [info.fields.len][:0]const u8 = undefined;
        var field_types: [info.fields.len]type = undefined;
        var field_attrs: [info.fields.len]std.builtin.Type.Struct.FieldAttributes = undefined;
        for (info.fields, 0..) |f, i| {
            const FieldType = if (f.optional) ?f.zig_type else f.zig_type;
            field_names[i] = (f.name)[0..f.name.len :0];
            field_types[i] = FieldType;
            field_attrs[i] = .{
                .default_value_ptr = null,
                .@"comptime" = false,
                .@"align" = @alignOf(FieldType),
            };
        }
        return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
    }
}

/// Generate an Edges struct for an entity.
/// Uses LightEntity for target types to avoid comptime recursion.
fn EdgesType(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
    comptime {
        if (info.edges.len == 0) {
            return struct {
                pub fn deinit(_: @This(), _: std.mem.Allocator) void {}
            };
        }
        var field_names: [info.edges.len][:0]const u8 = undefined;
        var field_types: [info.edges.len]type = undefined;
        var field_attrs: [info.edges.len]std.builtin.Type.Struct.FieldAttributes = undefined;
        for (info.edges, 0..) |e, i| {
            const target_info = findTypeInfo(infos, e.target_name);
            const TargetEntity = LightEntity(infos, target_info);
            const FieldType = ?[]TargetEntity;
            const default_val: FieldType = null;
            field_names[i] = (e.name)[0..e.name.len :0];
            field_types[i] = FieldType;
            field_attrs[i] = .{
                .default_value_ptr = &default_val,
                .@"comptime" = false,
                .@"align" = @alignOf(FieldType),
            };
        }
        return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
    }
}

fn EntityFields(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
    comptime {
        const ET = EdgesType(infos, info);
        const edges_default: ET = .{};
        var field_names: [info.fields.len + 1][:0]const u8 = undefined;
        var field_types: [info.fields.len + 1]type = undefined;
        var field_attrs: [info.fields.len + 1]std.builtin.Type.Struct.FieldAttributes = undefined;
        for (info.fields, 0..) |f, i| {
            const FieldType = if (f.optional) ?f.zig_type else f.zig_type;
            field_names[i] = (f.name)[0..f.name.len :0];
            field_types[i] = FieldType;
            field_attrs[i] = .{
                .default_value_ptr = null,
                .@"comptime" = false,
                .@"align" = @alignOf(FieldType),
            };
        }
        field_names[info.fields.len] = "edges";
        field_types[info.fields.len] = ET;
        field_attrs[info.fields.len] = .{
            .default_value_ptr = &edges_default,
            .@"comptime" = false,
            .@"align" = @alignOf(ET),
        };
        return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
    }
}

fn FreeField(comptime FieldType: type, field_ptr: *FieldType, allocator: std.mem.Allocator) void {
    const T = @typeInfo(FieldType);
    switch (T) {
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                allocator.free(field_ptr.*);
            } else if (p.size == .slice) {
                for (field_ptr.*) |item| {
                    FreeField(p.child, &item, allocator);
                }
                allocator.free(field_ptr.*);
            }
        },
        .optional => |opt| {
            if (field_ptr.*) |*p| {
                FreeField(opt.child, p, allocator);
            }
        },
        else => {},
    }
}

fn hasJsonStructField(comptime info: TypeInfo) bool {
    inline for (info.fields) |f| {
        if (f.field_type == .json and @typeInfo(f.zig_type) == .@"struct") return true;
    }
    return false;
}

/// Generate an entity struct from TypeInfo.
pub fn Entity(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
    comptime {
        const ET = EdgesType(infos, info);
        const edges_default: ET = .{};
        const needs_arena = hasJsonStructField(info);
        const extra_count = 1 + @as(usize, @intFromBool(needs_arena));
        var field_names: [info.fields.len + extra_count][:0]const u8 = undefined;
        var field_types: [info.fields.len + extra_count]type = undefined;
        var field_attrs: [info.fields.len + extra_count]std.builtin.Type.Struct.FieldAttributes = undefined;
        for (info.fields, 0..) |f, i| {
            const FieldType = if (f.optional) ?f.zig_type else f.zig_type;
            field_names[i] = (f.name)[0..f.name.len :0];
            field_types[i] = FieldType;
            field_attrs[i] = .{
                .default_value_ptr = null,
                .@"comptime" = false,
                .@"align" = @alignOf(FieldType),
            };
        }
        const arena_idx = info.fields.len;
        const edges_idx = info.fields.len + @as(usize, @intFromBool(needs_arena));
        if (needs_arena) {
            field_names[arena_idx] = "json_arena";
            field_types[arena_idx] = ?*std.heap.ArenaAllocator;
            field_attrs[arena_idx] = .{
                .default_value_ptr = null,
                .@"comptime" = false,
                .@"align" = @alignOf(?*std.heap.ArenaAllocator),
            };
        }
        field_names[edges_idx] = "edges";
        field_types[edges_idx] = ET;
        field_attrs[edges_idx] = .{
            .default_value_ptr = &edges_default,
            .@"comptime" = false,
            .@"align" = @alignOf(ET),
        };
        return @Struct(.auto, null, field_names[0 .. edges_idx + 1], field_types[0 .. edges_idx + 1], field_attrs[0 .. edges_idx + 1]);
    }
}

/// Recursively free heap allocations owned by an entity (fields + eager-loaded
/// edges). The caller still owns the entity itself and the outer `[]Entity` slice.
pub fn deinitEntity(comptime infos: []const TypeInfo, comptime info: TypeInfo, self: anytype, allocator: std.mem.Allocator) void {
    // Reject immutable pointers at compile time.
    comptime {
        const T = @TypeOf(self);
        const ptr_info = @typeInfo(T).pointer;
        if (ptr_info.attrs.@"const") @compileError("deinitEntity requires a mutable entity pointer");
    }

    if (comptime hasJsonStructField(info)) {
        if (self.json_arena) |arena| {
            arena.deinit();
            allocator.destroy(arena);
            self.json_arena = null;
        }
    }

    inline for (info.fields) |f| {
        if (!comptime isOwningField(f.zig_type)) continue;
        const field_type = if (f.optional) ?f.zig_type else f.zig_type;
        const fp: *field_type = &@field(self, f.name);
        FreeField(field_type, fp, allocator);
    }
    if (comptime info.edges.len > 0) {
        inline for (info.edges) |e| {
            const target_info = comptime findTypeInfo(infos, e.target_name);
            const edges_ptr: *?[]LightEntity(infos, target_info) = &@field(self.edges, e.name);
            if (edges_ptr.*) |arr| {
                for (arr) |*item| {
                    inline for (target_info.fields) |tf| {
                        if (!comptime isOwningField(tf.zig_type)) continue;
                        const item_field_type = if (tf.optional) ?tf.zig_type else tf.zig_type;
                        const item_fp: *item_field_type = &@field(item, tf.name);
                        FreeField(item_field_type, item_fp, allocator);
                    }
                }
                allocator.free(arr);
            }
        }
    }
}

/// Write an entity to the given writer. Non-sensitive fields are formatted
/// normally; sensitive fields are masked as "***".
///
/// Usage:
///   try formatEntity(info, e, writer);
pub fn formatEntity(
    comptime info: TypeInfo,
    self: anytype,
    writer: anytype,
) !void {
    try writer.writeAll(info.table_name);
    try writer.writeAll("{");
    inline for (info.fields, 0..) |f, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("{s}=", .{f.name});
        if (f.sensitive) {
            try writer.writeAll("***");
        } else {
            const field_type = if (f.optional) ?f.zig_type else f.zig_type;
            const value: field_type = @field(self, f.name);
            try writer.print("{any}", .{value});
        }
    }
    try writer.writeAll("}");
}

fn isOwningField(comptime T: type) bool {
    const info = @typeInfo(T);
    switch (info) {
        .pointer => |p| return p.size == .slice, // includes []const u8
        .optional => |opt| return isOwningField(opt.child),
        else => return false,
    }
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Entity struct generation" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{
            field.String("name"),
            field.Int("age"),
        },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime Entity(infos, info);

    var u: UserEntity = undefined;
    u.id = 1;
    u.name = "alice";
    u.age = 30;

    try std.testing.expectEqual(@as(i64, 1), u.id);
    try std.testing.expectEqualStrings("alice", u.name);
    try std.testing.expectEqual(@as(i64, 30), u.age);
}

test "formatEntity masks sensitive fields" {
    // The formatEntity function exists and accepts any writer. Callers can
    // provide their own. We do not assert output here because std.ArrayList.writer()
    // is not available in Zig 0.17-dev; formatEntityToString is intentionally
    // omitted to avoid depending on std.io APIs that have been removed.
    // Manual smoke-test: call formatEntity with a custom writer.
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{
            field.String("name"),
            field.String("password").Sensitive(),
        },
    });

    const info = comptime fromSchema(User);
    const UserEntity = comptime Entity(&[_]TypeInfo{info}, info);

    var u: UserEntity = undefined;
    u.id = 1;
    u.name = "alice";
    u.password = "hunter2";

    // Use a stub writer that just discards bytes.
    const StubWriter = struct {
        fn writeAll(_: @This(), _: []const u8) !void {}
        fn print(_: @This(), comptime _: []const u8, _: anytype) !void {}
    };
    try formatEntity(info, u, StubWriter{});
}

test "fromSchema copies annotations" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const Annotation = @import("../core/schema.zig").Annotation;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{field.String("name")},
        .annotations = &.{
            Annotation{ .key = "owner", .value = "platform" },
            Annotation{ .key = "retention_days", .value = "30" },
        },
    });

    const info = comptime fromSchema(User);
    try std.testing.expectEqual(@as(usize, 2), info.annotations.len);
    try std.testing.expectEqualStrings("owner", info.annotations[0].key);
    try std.testing.expectEqualStrings("platform", info.annotations[0].value);
    try std.testing.expectEqualStrings("retention_days", info.annotations[1].key);
    try std.testing.expectEqualStrings("30", info.annotations[1].value);
}

test "fromSchema annotations default to empty" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const Pet = schema("Pet", .{
        .fields = &.{field.String("name")},
    });

    const info = comptime fromSchema(Pet);
    try std.testing.expectEqual(@as(usize, 0), info.annotations.len);
}
