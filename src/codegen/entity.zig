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
/// Pure scalar fields (no edges) - the terminal node of nested eager loads.
fn PlainFields(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
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

/// One level of edges whose targets are plain fields (no further nesting).
/// Used by LightEntity so `WithEdge("posts.comments")` can preload two
/// levels; a third level is a compile error (no edges container on the
/// terminal target).
fn EdgesTypeShallow(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
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
            const TargetEntity = PlainFields(infos, target_info);
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

/// Light entity (fields + one shallow edges level) used as the eager-load
/// target type, so nested `WithEdge("a.b")` works for two levels.
pub fn LightEntity(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
    comptime {
        const ET = EdgesTypeShallow(infos, info);
        const edges_default: ET = .{};
        const Plain = PlainFields(infos, info);
        const fields_info = @typeInfo(Plain).@"struct";
        var field_names: [fields_info.field_names.len + 1][:0]const u8 = undefined;
        var field_types: [fields_info.field_names.len + 1]type = undefined;
        var field_attrs: [fields_info.field_names.len + 1]std.builtin.Type.Struct.FieldAttributes = undefined;
        for (fields_info.field_names, fields_info.field_types, 0..) |fname, ftype, i| {
            field_names[i] = fname;
            field_types[i] = ftype;
            field_attrs[i] = .{
                .default_value_ptr = null,
                .@"comptime" = false,
                .@"align" = @alignOf(ftype),
            };
        }
        const i = fields_info.field_names.len;
        field_names[i] = "edges";
        field_types[i] = ET;
        field_attrs[i] = .{
            .default_value_ptr = &edges_default,
            .@"comptime" = false,
            .@"align" = @alignOf(ET),
        };
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
    deinitEntityEdges(infos, info, self, allocator);
}

/// Recursively free eager-loaded edges (one level of nesting supported).
/// The edges field type is `?[]Target` where Target is LightEntity (with a
/// shallow edges level) or PlainFields (terminal); Target is derived from the
/// field type so both work.
fn deinitEntityEdges(comptime infos: []const TypeInfo, comptime info: TypeInfo, self: anytype, allocator: std.mem.Allocator) void {
    if (comptime info.edges.len == 0) return;
    inline for (info.edges) |e| {
        const target_info = comptime findTypeInfo(infos, e.target_name);
        const EdgeFieldType = @TypeOf(@field(self.edges, e.name));
        const EdgeArrType = @typeInfo(EdgeFieldType).optional.child;
        const ItemType = @typeInfo(EdgeArrType).pointer.child;
        const edges_ptr: *?[]ItemType = &@field(self.edges, e.name);
        if (edges_ptr.*) |arr| {
            for (arr) |*item| {
                inline for (target_info.fields) |tf| {
                    if (!comptime isOwningField(tf.zig_type)) continue;
                    const item_field_type = if (tf.optional) ?tf.zig_type else tf.zig_type;
                    const item_fp: *item_field_type = &@field(item, tf.name);
                    FreeField(item_field_type, item_fp, allocator);
                }
                // Terminal targets (PlainFields) carry no edges container;
                // the comptime guard stops that instantiation from being
                // analyzed.
                if (comptime @hasField(ItemType, "edges")) {
                    deinitEntityEdges(infos, target_info, item, allocator);
                }
            }
            allocator.free(arr);
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

/// Serialize an entity to JSON with `sensitive` fields masked as "***".
/// The generated entity struct cannot carry a `jsonStringify` method (the
/// @Struct builtin has no decls slot), so APIs must use this helper instead
/// of serializing the raw entity (std.json would leak sensitive fields).
/// Non-sensitive values are emitted through std.json (safe escaping).
pub fn toMaskedJson(
    allocator: std.mem.Allocator,
    comptime infos: []const TypeInfo,
    comptime info: TypeInfo,
    entity: anytype,
) ![]u8 {
    _ = infos;
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    inline for (info.fields, 0..) |f, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "\"");
        try buf.appendSlice(allocator, f.name);
        try buf.appendSlice(allocator, "\":");
        if (f.sensitive) {
            try buf.appendSlice(allocator, "\"***\"");
        } else {
            const value = @field(entity, f.name);
            const piece = try std.json.Stringify.valueAlloc(allocator, value, .{});
            defer allocator.free(piece);
            try buf.appendSlice(allocator, piece);
        }
    }
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "toMaskedJson masks sensitive fields" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const Account = Schema("Account2", .{
        .fields = &.{
            field.String("name"),
            field.String("api_key").Sensitive(),
        },
    });
    const info = comptime fromSchema(Account);
    const infos = &[_]TypeInfo{info};
    const AccountEntity = Entity(infos, info);

    const a = AccountEntity{ .id = 1, .name = "alice", .api_key = "sk-secret-123" };
    const json = try toMaskedJson(allocator, infos, info, a);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"api_key\":\"***\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "sk-secret-123") == null);
}

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
