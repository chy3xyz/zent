const std = @import("std");

/// Edge kind.
pub const EdgeKind = enum {
    to,
    from,
};

/// Relation cardinality.
pub const Relation = enum {
    o2o,
    o2m,
    m2o,
    m2m,
};

/// Edge descriptor used at comptime.
pub const Edge = struct {
    name: []const u8,
    target: type,
    kind: EdgeKind,
    unique: bool = false,
    required: bool = false,
    immutable: bool = false,
    ref: ?[]const u8 = null,
    field_name: ?[]const u8 = null, // explicit FK field binding

    pub fn Unique(self: Edge) Edge {
        var e = self;
        e.unique = true;
        return e;
    }

    pub fn Required(self: Edge) Edge {
        var e = self;
        e.required = true;
        return e;
    }

    pub fn Immutable(self: Edge) Edge {
        var e = self;
        e.immutable = true;
        return e;
    }

    pub fn Ref(self: Edge, comptime edge_name: []const u8) Edge {
        var e = self;
        e.ref = edge_name;
        return e;
    }

    pub fn Field(self: Edge, comptime fk_field: []const u8) Edge {
        var e = self;
        e.field_name = fk_field;
        return e;
    }
};

pub fn To(name: []const u8, comptime Target: type) Edge {
    return .{ .name = name, .target = Target, .kind = .to };
}

pub fn From(name: []const u8, comptime Target: type) Edge {
    return .{ .name = name, .target = Target, .kind = .from };
}

/// Resolve the relation cardinality from the perspective of the owner type.
pub fn resolveRelation(edge: Edge, comptime inverse: ?Edge) Relation {
    const is_unique = edge.unique;
    const inverse_unique = if (inverse) |inv| inv.unique else false;

    if (edge.kind == .from) {
        // From edge: cardinality is the inverse of the referenced edge.
        if (is_unique and inverse_unique) return .o2o;
        if (is_unique and !inverse_unique) return .o2m;
        if (!is_unique and inverse_unique) return .m2o;
        return .m2m;
    }

    // To edge.
    if (is_unique and inverse_unique) return .o2o;
    if (is_unique and !inverse_unique) return .m2o;
    if (!is_unique and inverse_unique) return .o2m;
    return .m2m;
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Edge builders" {
    const Dummy = struct {};
    const e = To("cars", Dummy).Unique().Required();
    try std.testing.expectEqualStrings("cars", e.name);
    try std.testing.expect(e.unique);
    try std.testing.expect(e.required);
    try std.testing.expectEqual(EdgeKind.to, e.kind);
}

test "resolveRelation O2M" {
    const Dummy = struct {};
    const to = To("cars", Dummy);
    const from = From("owner", Dummy).Unique().Ref("cars");
    try std.testing.expectEqual(Relation.o2m, resolveRelation(to, from));
    try std.testing.expectEqual(Relation.m2o, resolveRelation(from, to));
}
