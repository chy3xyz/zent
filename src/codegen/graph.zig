const std = @import("std");
const field_mod = @import("../core/field.zig");
const edge_mod = @import("../core/edge.zig");
const index_mod = @import("../core/index.zig");
const Dialect = @import("../sql/dialect.zig").Dialect;

pub const FieldInfo = struct {
    name: []const u8,
    field_type: field_mod.FieldType,
    zig_type: type,
    sql_type: []const u8,
    optional: bool,
    nillable: bool,
    unique: bool,
    immutable: bool,
    default: field_mod.DefaultValue,
    validators: []const field_mod.Validator,
    is_id: bool,
};

pub const EdgeInfo = struct {
    name: []const u8,
    target: type,
    target_name: []const u8,
    kind: edge_mod.EdgeKind,
    relation: edge_mod.Relation,
    unique: bool,
    required: bool,
    immutable: bool,
    ref: ?[]const u8,
    field_name: ?[]const u8,
    inverse_name: ?[]const u8,
};

pub const IndexInfo = struct {
    name: []const u8,
    columns: []const []const u8,
    unique: bool,
};

pub const TypeInfo = struct {
    name: []const u8,
    table_name: []const u8,
    fields: []const FieldInfo,
    edges: []const EdgeInfo,
    indexes: []const IndexInfo,
};

/// Build a TypeInfo from a schema type at comptime.
pub fn fromSchema(comptime S: type) TypeInfo {
    comptime {
        const schema_fields = S.fields;
        const schema_edges = S.edges;
        const schema_indexes = S.indexes;
        const name = S.schema_name;

        // Auto-inject ID if not present.
        const has_id = hasFieldNamed(schema_fields, "id");
        const id_field = if (!has_id)
            &[_]field_mod.Field{field_mod.Int("id")}
        else
            &[_]field_mod.Field{};
        const all_schema_fields = id_field ++ schema_fields;

        var fields: []const FieldInfo = &.{};
        for (all_schema_fields) |f| {
            fields = fields ++ &[_]FieldInfo{toFieldInfo(f)};
        }

        var edges: []const EdgeInfo = &.{};
        for (schema_edges) |e| {
            edges = edges ++ &[_]EdgeInfo{toEdgeInfo(e)};
        }

        var indexes: []const IndexInfo = &.{};
        for (schema_indexes) |i| {
            indexes = indexes ++ &[_]IndexInfo{toIndexInfo(i, name)};
        }

        return TypeInfo{
            .name = name,
            .table_name = toSnakeCase(name),
            .fields = fields,
            .edges = edges,
            .indexes = indexes,
        };
    }
}

fn hasFieldNamed(comptime fields: []const field_mod.Field, name: []const u8) bool {
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

fn toFieldInfo(comptime f: field_mod.Field) FieldInfo {
    comptime {
        const is_id = std.mem.eql(u8, f.name, "id");
        return FieldInfo{
            .name = f.name,
            .field_type = f.field_type,
            .zig_type = field_mod.zigType(f.field_type, f.zig_type),
            .sql_type = field_mod.sqlType(f.field_type, Dialect.sqlite),
            .optional = f.optional,
            .nillable = f.nillable,
            .unique = f.unique,
            .immutable = f.immutable,
            .default = f.default,
            .validators = f.validators,
            .is_id = is_id,
        };
    }
}

fn toEdgeInfo(comptime e: edge_mod.Edge) EdgeInfo {
    comptime {
        var relation: edge_mod.Relation = .m2m;
        var inverse_name: ?[]const u8 = null;

        if (e.kind == .from) {
            // From edge: look up the target's edge that we reference.
            if (e.ref) |ref_name| {
                const target_edges = e.target.edges;
                const inverse = findEdge(target_edges, ref_name);
                if (inverse) |inv| {
                    relation = edge_mod.resolveRelation(e, inv);
                    inverse_name = inv.name;
                }
            }
        } else {
            // To edge: look for a From edge in the target that references us.
            const target_edges = e.target.edges;
            if (findInverse(target_edges, e.name)) |inv| {
                relation = edge_mod.resolveRelation(e, inv);
                inverse_name = inv.name;
            } else {
                relation = edge_mod.resolveRelation(e, null);
            }
        }

        return EdgeInfo{
            .name = e.name,
            .target = e.target,
            .target_name = e.target.schema_name,
            .kind = e.kind,
            .relation = relation,
            .unique = e.unique,
            .required = e.required,
            .immutable = e.immutable,
            .ref = e.ref,
            .field_name = e.field_name,
            .inverse_name = inverse_name,
        };
    }
}

fn findEdge(comptime edges: []const edge_mod.Edge, name: []const u8) ?edge_mod.Edge {
    inline for (edges) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

fn findInverse(comptime edges: []const edge_mod.Edge, edge_name: []const u8) ?edge_mod.Edge {
    inline for (edges) |e| {
        if (e.kind == .from) {
            if (e.ref) |ref| {
                if (std.mem.eql(u8, ref, edge_name)) return e;
            }
        }
    }
    return null;
}

fn toIndexInfo(comptime i: index_mod.Index, comptime type_name: []const u8) IndexInfo {
    comptime {
        const name = i.name orelse generateIndexName(type_name, i.columns);
        return IndexInfo{
            .name = name,
            .columns = i.columns,
            .unique = i.unique,
        };
    }
}

fn generateIndexName(comptime type_name: []const u8, comptime columns: []const []const u8) []const u8 {
    comptime {
        var result: []const u8 = type_name;
        for (columns) |col| {
            result = result ++ "_" ++ col;
        }
        return result;
    }
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

/// A Graph holds multiple TypeInfos.
pub const Graph = struct {
    types: []const TypeInfo,
};

pub fn buildGraph(comptime schemas: []const type) Graph {
    comptime {
        var types: []const TypeInfo = &.{};
        for (schemas) |S| {
            types = types ++ &[_]TypeInfo{fromSchema(S)};
        }
        return Graph{ .types = types };
    }
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Graph from schemas" {
    const field = @import("../core/field.zig");
    const edge = @import("../core/edge.zig");
    const schema = @import("../core/schema.zig").Schema;

    const Car = schema("Car", .{
        .fields = &.{
            field.String("model"),
            field.Time("registered_at"),
        },
    });

    const User = schema("User", .{
        .fields = &.{
            field.Int("age").Positive(),
            field.String("name").Default("unknown"),
        },
        .edges = &.{
            edge.To("cars", Car),
        },
    });

    // Add inverse edge to Car for full relation resolution
    const CarWithInverse = schema("Car", .{
        .fields = &.{
            field.String("model"),
            field.Time("registered_at"),
        },
        .edges = &.{
            edge.From("owner", User).Ref("cars").Unique(),
        },
    });

    const User2 = schema("User", .{
        .fields = &.{
            field.Int("age").Positive(),
            field.String("name").Default("unknown"),
        },
        .edges = &.{
            edge.To("cars", CarWithInverse),
        },
    });

    const user_info = comptime fromSchema(User2);
    try std.testing.expectEqualStrings("User", user_info.name);
    try std.testing.expectEqualStrings("user", user_info.table_name);
    try std.testing.expectEqual(@as(usize, 3), user_info.fields.len); // id + age + name

    try std.testing.expectEqual(@as(usize, 1), user_info.edges.len);
    const car_edge = user_info.edges[0];
    try std.testing.expectEqualStrings("cars", car_edge.name);
    try std.testing.expectEqual(edge_mod.Relation.o2m, car_edge.relation);
    try std.testing.expectEqualStrings("owner", car_edge.inverse_name.?);
}

test "Auto-injected ID" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;

    const Simple = schema("Simple", .{
        .fields = &.{field.String("name")},
    });

    const info = comptime fromSchema(Simple);
    try std.testing.expectEqual(@as(usize, 2), info.fields.len);
    try std.testing.expectEqualStrings("id", info.fields[0].name);
    try std.testing.expect(info.fields[0].is_id);
    try std.testing.expectEqualStrings("name", info.fields[1].name);
}
