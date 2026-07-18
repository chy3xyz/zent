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

/// Generate an entity struct from TypeInfo.
pub fn Entity(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
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

/// Recursively free heap allocations owned by an entity (fields + eager-loaded
/// edges). The caller still owns the entity itself and the outer `[]Entity` slice.
pub fn deinitEntity(comptime infos: []const TypeInfo, comptime info: TypeInfo, self: anytype, allocator: std.mem.Allocator) void {
    inline for (info.fields) |f| {
        if (!comptime isOwningField(f.zig_type)) continue;
        const fp: *f.zig_type = @constCast(&@field(self, f.name));
        FreeField(f.zig_type, fp, allocator);
    }
    if (comptime info.edges.len > 0) {
        inline for (info.edges) |e| {
            const target_info = comptime findTypeInfo(infos, e.target_name);
            const edges_ptr: *?[]LightEntity(infos, target_info) = @constCast(&@field(self.edges, e.name));
            if (edges_ptr.*) |arr| {
                for (arr) |*item| {
                    inline for (target_info.fields) |tf| {
                        if (!comptime isOwningField(tf.zig_type)) continue;
                        const item_fp: *tf.zig_type = @constCast(&@field(item, tf.name));
                        FreeField(tf.zig_type, item_fp, allocator);
                    }
                }
                allocator.free(arr);
            }
        }
    }
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
