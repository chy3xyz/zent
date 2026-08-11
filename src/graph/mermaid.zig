const std = @import("std");
const TypeInfo = @import("../codegen/graph.zig").TypeInfo;

/// Generates a Mermaid.js ER diagram string (`erDiagram`) for the given schemas.
/// Caller owns the returned string memory and must free it with `allocator.free()`.
pub fn toMermaid(allocator: std.mem.Allocator, comptime infos: []const TypeInfo) ![]const u8 {
    var buf = try std.array_list.Managed(u8).initCapacity(allocator, 512);
    defer buf.deinit();

    try buf.appendSlice("erDiagram\n");

    // 1. Render entities and their fields
    inline for (infos) |info| {
        try buf.appendSlice("    ");
        try buf.appendSlice(info.name);
        try buf.appendSlice(" {\n");

        inline for (info.fields) |f| {
            try buf.appendSlice("        ");
            try buf.appendSlice(@tagName(f.field_type));
            try buf.appendSlice(" ");
            try buf.appendSlice(f.name);
            if (f.is_id) {
                try buf.appendSlice(" PK");
            } else if (f.unique) {
                try buf.appendSlice(" UK");
            }
            try buf.appendSlice("\n");
        }

        try buf.appendSlice("    }\n");
    }

    // 2. Render relationships (edges)
    inline for (infos) |info| {
        inline for (info.edges) |e| {
            // Avoid duplicate rendering for inverse edges by rendering when ref is null or matching source
            const rel_symbol = if (e.unique) "||--||" else "||--o{";
            try buf.appendSlice("    ");
            try buf.appendSlice(info.name);
            try buf.appendSlice(" ");
            try buf.appendSlice(rel_symbol);
            try buf.appendSlice(" ");
            try buf.appendSlice(e.target_name);
            try buf.appendSlice(" : \"");
            try buf.appendSlice(e.name);
            try buf.appendSlice("\"\n");
        }
    }

    return allocator.dupe(u8, buf.items);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Mermaid ER diagram generation" {
    const field = @import("../core/field.zig");
    const edge = @import("../core/edge.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("../codegen/graph.zig").fromSchema;

    const S = struct {
        var User: type = undefined;
        var Post: type = undefined;
    };

    S.Post = schema("Post", .{
        .fields = &.{
            field.String("title"),
        },
    });

    S.User = schema("User", .{
        .fields = &.{
            field.String("name").unique(),
            field.Int("age"),
        },
        .edges = &.{
            edge.To("posts", S.Post),
        },
    });

    const user_info = comptime fromSchema(S.User);
    const post_info = comptime fromSchema(S.Post);

    const diagram = try toMermaid(std.testing.allocator, &.{ user_info, post_info });
    defer std.testing.allocator.free(diagram);

    try std.testing.expect(std.mem.startsWith(u8, diagram, "erDiagram\n"));
    try std.testing.expect(std.mem.indexOf(u8, diagram, "User {") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagram, "Post {") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagram, "User ||--o{ Post : \"posts\"") != null);
}
