/// Schema factory. Returns an opaque type that carries comptime metadata.
pub fn Schema(comptime name: []const u8, comptime config: struct {
    fields: []const @import("field.zig").Field = &.{},
    edges: []const @import("edge.zig").Edge = &.{},
    indexes: []const @import("index.zig").Index = &.{},
}) type {
    return struct {
        pub const schema_name = name;
        pub const fields = config.fields;
        pub const edges = config.edges;
        pub const indexes = config.indexes;
    };
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const field = @import("field.zig");
const edge = @import("edge.zig");
const index = @import("index.zig");

test "Schema definition" {
    const Car = Schema("Car", .{
        .fields = &.{
            field.String("model"),
            field.Time("registered_at"),
        },
    });

    const User = Schema("User", .{
        .fields = &.{
            field.Int("age").Positive(),
            field.String("name").Default("unknown"),
        },
        .edges = &.{
            edge.To("cars", Car),
        },
        .indexes = &.{
            index.Fields(&.{"name"}).Unique(),
        },
    });

    try @import("std").testing.expectEqualStrings("User", User.schema_name);
    try @import("std").testing.expectEqual(@as(usize, 2), User.fields.len);
    try @import("std").testing.expectEqual(@as(usize, 1), User.edges.len);
    try @import("std").testing.expectEqual(@as(usize, 1), User.indexes.len);
}
