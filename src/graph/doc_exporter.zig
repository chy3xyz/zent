const std = @import("std");
const TypeInfo = @import("../codegen/graph.zig").TypeInfo;
const Dialect = @import("../sql/dialect.zig").Dialect;

/// Options for generating Markdown documentation.
pub const DocOptions = struct {
    dialect: Dialect = Dialect.sqlite,
    title: []const u8 = "Schema Data Dictionary",
};

/// Generates a comprehensive Markdown Data Dictionary for the given schemas.
/// Caller owns the returned string and must free it with `allocator.free()`.
pub fn toMarkdownDoc(allocator: std.mem.Allocator, comptime infos: []const TypeInfo, options: DocOptions) ![]const u8 {
    var buf = try std.array_list.Managed(u8).initCapacity(allocator, 1024);
    defer buf.deinit();

    try buf.print("# {s}\n\n", .{options.title});

    inline for (infos) |info| {
        try buf.print("## Entity: `{s}` (Table: `{s}`)\n\n", .{ info.name, info.table_name });

        // Fields table
        try buf.appendSlice("### Fields\n\n");
        try buf.appendSlice("| Field | Type | SQL Type | Key | Unique | Nullable | Sensitive |\n");
        try buf.appendSlice("| :--- | :--- | :--- | :---: | :---: | :---: | :---: |\n");

        inline for (info.fields) |f| {
            const key_str = if (f.is_id) "PK" else "";
            const uniq_str = if (f.unique) "Yes" else "No";
            const null_str = if (f.optional or f.nillable) "Yes" else "No";
            const sens_str = if (f.sensitive) "Yes" else "No";
            const sql_t = f.sqlType(options.dialect);

            try buf.print("| `{s}` | `{s}` | `{s}` | {s} | {s} | {s} | {s} |\n", .{
                f.name,
                @tagName(f.field_type),
                sql_t,
                key_str,
                uniq_str,
                null_str,
                sens_str,
            });
        }
        try buf.appendSlice("\n");

        // Edges table
        if (info.edges.len > 0) {
            try buf.appendSlice("### Edges (Relationships)\n\n");
            try buf.appendSlice("| Edge | Target Entity | Type | Required |\n");
            try buf.appendSlice("| :--- | :--- | :--- | :---: |\n");

            inline for (info.edges) |e| {
                const edge_t = if (e.unique) "One-to-One" else "One-to-Many";
                const req_str = if (e.required) "Yes" else "No";

                try buf.print("| `{s}` | `{s}` | {s} | {s} |\n", .{
                    e.name,
                    e.target_name,
                    edge_t,
                    req_str,
                });
            }
            try buf.appendSlice("\n");
        }

        try buf.appendSlice("---\n\n");
    }

    return allocator.dupe(u8, buf.items);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Markdown data dictionary generation" {
    const field = @import("../core/field.zig");
    const edge = @import("../core/edge.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("../codegen/graph.zig").fromSchema;

    const S = struct {
        var User: type = undefined;
        var Order: type = undefined;
    };

    S.Order = schema("Order", .{
        .fields = &.{
            field.String("order_number").unique(),
            field.Int("amount"),
        },
    });

    S.User = schema("User", .{
        .fields = &.{
            field.String("email").unique(),
            field.String("password").sensitive(),
        },
        .edges = &.{
            edge.To("orders", S.Order),
        },
    });

    const user_info = comptime fromSchema(S.User);
    const order_info = comptime fromSchema(S.Order);

    const doc = try toMarkdownDoc(std.testing.allocator, &.{ user_info, order_info }, .{});
    defer std.testing.allocator.free(doc);

    try std.testing.expect(std.mem.indexOf(u8, doc, "# Schema Data Dictionary") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "## Entity: `User`") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "| `email` | `string` |") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "| `password` | `string` |") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "### Edges (Relationships)") != null);
}
