const std = @import("std");

/// Relation cardinality for graph edges.
/// Mirrors ent's sqlgraph.Rel.
/// Relation cardinality for graph edges.
/// Mirrors ent's sqlgraph.Rel.
pub const Rel = enum {
    o2o,
    o2m,
    m2o,
    m2m,
};

/// Step describes one hop in a graph traversal.
///
/// It encodes the source entity, the edge to traverse, and
/// the target entity — mirroring ent's `sqlgraph.Step`.
///
/// For example, to traverse from User to Car via the "cars" edge (O2M):
///   from_table="user", from_column="id"
///   to_table="car",   to_column="id"
///   edge_rel=o2m, edge_table="car", edge_columns=&[_][]const u8{"owner_id"}
///   inverse=false
///
/// For M2M via a junction table (User ↔ Group via user_group):
///   from_table="user",      from_column="id"
///   to_table="group",       to_column="id"
///   edge_rel=m2m,           edge_table="user_group"
///   edge_columns=&[_][]const u8{"group_id", "user_id"}  // pk1=pk_target, pk2=pk_source
///   inverse=false
pub const Step = struct {
    /// Source table and its join column (usually "id").
    from_table: []const u8,
    from_column: []const u8,

    /// Target (neighbor) table and its join column (usually "id").
    to_table: []const u8,
    to_column: []const u8,

    /// Edge relation type.
    edge_rel: Rel,

    /// Table that holds the edge columns.
    /// - For O2M/M2O/O2O: the table that contains the foreign-key column.
    /// - For M2M: the junction (edge) table.
    edge_table: []const u8,

    /// Edge columns.
    /// - For O2O/M2O (FromEdgeOwner): [fk_column]  (1 column)
    /// - For O2M (ToEdgeOwner): [fk_column]  (1 column, FK lives in target)
    /// - For M2M: [pk_target, pk_source]  (2 columns)
    edge_columns: []const []const u8,

    /// Inverse indicates if traversal goes in the inverse direction
    /// (i.e. following a `from` edge rather than a `to` edge).
    inverse: bool,

    /// Returns true if the step proceeds *from* the edge owner
    /// (the table that holds the foreign-key).
    /// Applies to: M2O, O2O-inverse
    pub fn fromEdgeOwner(self: Step) bool {
        return self.edge_rel == .m2o or (self.edge_rel == .o2o and self.inverse);
    }

    /// Returns true if the step proceeds *to* the edge owner
    /// (the table that holds the foreign-key).
    /// Applies to: O2M, O2O (non-inverse)
    pub fn toEdgeOwner(self: Step) bool {
        return self.edge_rel == .o2m or (self.edge_rel == .o2o and !self.inverse);
    }

    /// Returns true if the edge goes through a join table (M2M).
    pub fn throughEdgeTable(self: Step) bool {
        return self.edge_rel == .m2m;
    }

    /// Return the primary-key column of the junction table
    /// that references the target table (for M2M).
    pub fn targetPK(self: Step) []const u8 {
        if (self.inverse) return self.edge_columns[1];
        return self.edge_columns[0];
    }

    /// Return the primary-key column of the junction table
    /// that references the source table (for M2M).
    pub fn sourcePK(self: Step) []const u8 {
        if (self.inverse) return self.edge_columns[0];
        return self.edge_columns[1];
    }
};

test "Step helper methods" {
    // O2M: User → Car via "owner_id" FK in car table
    const o2m_step = Step{
        .from_table = "user",
        .from_column = "id",
        .to_table = "car",
        .to_column = "id",
        .edge_rel = .o2m,
        .edge_table = "car",
        .edge_columns = &[_][]const u8{"owner_id"},
        .inverse = false,
    };
    try std.testing.expect(!o2m_step.fromEdgeOwner());
    try std.testing.expect(o2m_step.toEdgeOwner());
    try std.testing.expect(!o2m_step.throughEdgeTable());

    // M2M: User → Group via user_group junction
    const m2m_step = Step{
        .from_table = "user",
        .from_column = "id",
        .to_table = "group",
        .to_column = "id",
        .edge_rel = .m2m,
        .edge_table = "user_group",
        .edge_columns = &[_][]const u8{"group_id", "user_id"},
        .inverse = false,
    };
    try std.testing.expect(!m2m_step.fromEdgeOwner());
    try std.testing.expect(!m2m_step.toEdgeOwner());
    try std.testing.expect(m2m_step.throughEdgeTable());
    try std.testing.expectEqualStrings("group_id", m2m_step.targetPK());
    try std.testing.expectEqualStrings("user_id", m2m_step.sourcePK());

    // M2M inverse
    const m2m_inv = Step{
        .from_table = "group",
        .from_column = "id",
        .to_table = "user",
        .to_column = "id",
        .edge_rel = .m2m,
        .edge_table = "user_group",
        .edge_columns = &[_][]const u8{"group_id", "user_id"},
        .inverse = true,
    };
    try std.testing.expectEqualStrings("user_id", m2m_inv.targetPK());
    try std.testing.expectEqualStrings("group_id", m2m_inv.sourcePK());

    // M2O: Car → User (inverse of O2M)
    const m2o_step = Step{
        .from_table = "car",
        .from_column = "owner_id",
        .to_table = "user",
        .to_column = "id",
        .edge_rel = .m2o,
        .edge_table = "car",
        .edge_columns = &[_][]const u8{"owner_id"},
        .inverse = false,
    };
    try std.testing.expect(m2o_step.fromEdgeOwner());
    try std.testing.expect(!m2o_step.toEdgeOwner());
    try std.testing.expect(!m2o_step.throughEdgeTable());
}
