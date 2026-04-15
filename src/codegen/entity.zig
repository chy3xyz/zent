const std = @import("std");
const TypeInfo = @import("graph.zig").TypeInfo;

/// Generate an entity struct from TypeInfo.
pub fn Entity(comptime info: TypeInfo) type {
    comptime {
        var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
        for (info.fields, 0..) |f, i| {
            fields[i] = .{
                .name = (f.name)[0..f.name.len :0],
                .type = f.zig_type,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(f.zig_type),
            };
        }
        return @Type(.{
            .@"struct" = .{
                .layout = .auto,
                .fields = &fields,
                .decls = &.{},
                .is_tuple = false,
            },
        });
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
    const UserEntity = comptime Entity(info);

    var u: UserEntity = undefined;
    u.id = 1;
    u.name = "alice";
    u.age = 30;

    try std.testing.expectEqual(@as(i64, 1), u.id);
    try std.testing.expectEqualStrings("alice", u.name);
    try std.testing.expectEqual(@as(i64, 30), u.age);
}
