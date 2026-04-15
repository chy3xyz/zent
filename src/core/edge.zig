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
/// For a From edge: the current entity holds the FK pointing to the target.
///   - M2O: Many current entities can point to one target (e.g., Car→User, many cars owned by one user)
///   - O2O: One current entity points to one target (e.g., User→Profile, one user has one profile)
/// For a To edge: the target entity holds the FK pointing back to us.
///   - O2M: One current entity can have many targets (e.g., User→cars, one user has many cars)
///   - O2O: One current entity has one target (e.g., User→card, one user has one card)
pub fn resolveRelation(edge: Edge, comptime inverse: ?Edge) Relation {
    const is_unique = edge.unique;
    const inverse_unique = if (inverse) |inv| inv.unique else false;

    if (edge.kind == .from) {
        // From edge: this entity has a FK column pointing to the target.
        // unique=true → each entity points to at most one target → M2O or O2O
        // unique=false → would mean M2M, but From edges don't have non-unique semantics
        if (is_unique and inverse_unique) return .o2o;
        if (is_unique) return .m2o; // Many cars → one user (Car.owner is unique per car)
        return .m2m; // Fallback for non-unique From
    }

    // To edge: target has FK column pointing back to us.
    // unique=false → target can have many of us → O2M (one user → many cars)
    // unique=true → target has unique FK → O2O (one user → one card)
    if (is_unique and inverse_unique) return .o2o;
    if (is_unique) return .o2o; // To with unique = O2O (one user has one card)
    return .o2m; // To without unique = O2M (one user has many cars)
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
