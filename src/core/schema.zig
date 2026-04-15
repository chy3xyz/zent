/// Merge field arrays from mixins into a single array.
fn mergeMixinFields(comptime base: []const @import("field.zig").Field, comptime mixins: []const type) []const @import("field.zig").Field {
    comptime {
        var result: []const @import("field.zig").Field = base;
        for (mixins) |M| {
            if (@hasDecl(M, "fields")) {
                result = result ++ M.fields;
            }
        }
        return result;
    }
}

fn mergeMixinEdges(comptime base: []const @import("edge.zig").Edge, comptime mixins: []const type) []const @import("edge.zig").Edge {
    comptime {
        var result: []const @import("edge.zig").Edge = base;
        for (mixins) |M| {
            if (@hasDecl(M, "edges")) {
                result = result ++ M.edges;
            }
        }
        return result;
    }
}

fn mergeMixinIndexes(comptime base: []const @import("index.zig").Index, comptime mixins: []const type) []const @import("index.zig").Index {
    comptime {
        var result: []const @import("index.zig").Index = base;
        for (mixins) |M| {
            if (@hasDecl(M, "indexes")) {
                result = result ++ M.indexes;
            }
        }
        return result;
    }
}

fn mergeMixinPolicies(comptime base: ?@import("../privacy/policy.zig").Policy, comptime mixins: []const type) ?@import("../privacy/policy.zig").Policy {
    comptime {
        var result = base;
        for (mixins) |M| {
            if (@hasDecl(M, "policy")) {
                if (result) |*r| {
                    if (M.policy.query) |q| r.query = q;
                    if (M.policy.mutation) |m| r.mutation = m;
                } else {
                    result = M.policy;
                }
            }
        }
        return result;
    }
}

/// Schema factory. Returns an opaque type that carries comptime metadata.
pub fn Schema(comptime name: []const u8, comptime config: struct {
    fields: []const @import("field.zig").Field = &.{},
    edges: []const @import("edge.zig").Edge = &.{},
    indexes: []const @import("index.zig").Index = &.{},
    mixins: []const type = &.{},
    policy: ?@import("../privacy/policy.zig").Policy = null,
    view: bool = false,
    view_sql: ?[]const u8 = null,
}) type {
    const all_fields = mergeMixinFields(config.fields, config.mixins);
    const all_edges = mergeMixinEdges(config.edges, config.mixins);
    const all_indexes = mergeMixinIndexes(config.indexes, config.mixins);
    const all_policy = mergeMixinPolicies(config.policy, config.mixins);

    return struct {
        pub const schema_name = name;
        pub const fields = all_fields;
        pub const edges = all_edges;
        pub const indexes = all_indexes;
        pub const policy = all_policy;
        pub const is_view = config.view;
        pub const view_sql = config.view_sql;
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
