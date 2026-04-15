const TypeInfo = @import("graph.zig").TypeInfo;

/// Generate meta constants for an entity.
pub fn Meta(comptime info: TypeInfo) type {
    return struct {
        pub const Table = info.table_name;
        pub const Label = info.name;

        // Field name constants
        pub const FieldID = "id";

        // Column names array
        pub const Columns = blk: {
            var cols: [info.fields.len][]const u8 = undefined;
            for (info.fields, 0..) |f, i| cols[i] = f.name;
            break :blk cols;
        };

        // Edge name constants
        pub const Edges = blk: {
            var edges: [info.edges.len][]const u8 = undefined;
            for (info.edges, 0..) |e, i| edges[i] = e.name;
            break :blk &edges;
        };

        // Helper to check if a column is valid
        pub fn ValidColumn(col: []const u8) bool {
            for (Columns) |c| {
                if (std.mem.eql(u8, c, col)) return true;
            }
            return false;
        }
    };
}

const std = @import("std");

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Meta constants" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const UserMeta = comptime Meta(info);

    try std.testing.expectEqualStrings("user", UserMeta.Table);
    try std.testing.expectEqualStrings("User", UserMeta.Label);
    try std.testing.expectEqualStrings("id", UserMeta.FieldID);
    try std.testing.expectEqual(@as(usize, 3), UserMeta.Columns.len);
    try std.testing.expect(UserMeta.ValidColumn("name"));
    try std.testing.expect(!UserMeta.ValidColumn("invalid"));
}
