const std = @import("std");
const sql = @import("../sql/builder.zig");
const Step = @import("step.zig").Step;

// ------------------------------------------------------------------
// Internal helpers
// ------------------------------------------------------------------

fn writeInClause(b: *sql.Builder, parent_ids: []const sql.Value) !void {
    try b.writeByte('(');
    for (parent_ids, 0..) |id, i| {
        if (i > 0) try b.writeString(", ");
        try b.arg(id);
    }
    try b.writeByte(')');
}

fn writeEagerLoadColumns(b: *sql.Builder, step: Step) !void {
    // The result set includes target.* plus a computed __fk column that
    // identifies which parent row each result belongs to.
    try b.writeString("SELECT ");
    try b.ident(step.to_table);
    try b.writeString(".*, ");

    switch (step.edge_rel) {
        .o2m, .o2o => {
            // ToEdgeOwner: FK resides in target table → FK column IS __fk.
            try b.ident(step.edge_columns[0]);
        },
        .m2o => {
            // FromEdgeOwner: FK in source table → source.pk column IS __fk.
            try b.ident("s");
            try b.writeByte('.');
            try b.ident(step.from_column);
        },
        .m2m => {
            // M2M via junction → junction.source_pk column IS __fk.
            try b.ident("j");
            try b.writeByte('.');
            try b.ident(step.sourcePK());
        },
    }
    try b.writeString(" AS __fk");
}

// ------------------------------------------------------------------
// Public API — all functions write into a caller-owned Builder.
// ------------------------------------------------------------------

/// Append SQL to `b` that SELECTs all neighbors of a *set* of parent
/// entities (eager loading).  The result columns are `target.*` plus a
/// `__fk` alias that holds the parent row's primary-key value.
///
/// The caller owns `b` and is responsible for calling `b.query()` and
/// `b.deinit()`.
pub fn appendSetNeighbors(b: *sql.Builder, step: Step, parent_ids: []const sql.Value) !void {
    try writeEagerLoadColumns(b, step);
    try b.writeString(" FROM ");
    try b.ident(step.to_table);

    switch (step.edge_rel) {
        .o2m, .o2o => {
            // ToEdgeOwner: FK is in target table.
            //   SELECT t.*, t.fk AS __fk FROM target t WHERE t.fk IN (...)
            try b.writeString(" WHERE ");
            try b.ident(step.edge_columns[0]);
            try b.writeString(" IN ");
            try writeInClause(b, parent_ids);
        },
        .m2o => {
            // FromEdgeOwner: FK is in source table.
            //   SELECT t.*, s.pk AS __fk FROM target t
            //     JOIN source s ON t.pk = s.fk
            //     WHERE s.pk IN (...)
            try b.writeString(" INNER JOIN ");
            try b.ident(step.from_table);
            try b.writeString(" s ON ");
            try b.ident(step.to_table);
            try b.writeByte('.');
            try b.ident(step.to_column);
            try b.writeString(" = s.");
            try b.ident(step.edge_columns[0]);
            try b.writeString(" WHERE s.");
            try b.ident(step.from_column);
            try b.writeString(" IN ");
            try writeInClause(b, parent_ids);
        },
        .m2m => {
            // ThroughEdgeTable: M2M via junction table.
            //   SELECT t.*, j.source_pk AS __fk FROM target t
            //     JOIN junction j ON t.pk = j.target_pk
            //     WHERE j.source_pk IN (...)
            try b.writeString(" INNER JOIN ");
            try b.ident(step.edge_table);
            try b.writeString(" j ON ");
            try b.ident(step.to_table);
            try b.writeByte('.');
            try b.ident(step.to_column);
            try b.writeString(" = j.");
            try b.ident(step.targetPK());
            try b.writeString(" WHERE j.");
            try b.ident(step.sourcePK());
            try b.writeString(" IN ");
            try writeInClause(b, parent_ids);
        },
    }
}

/// Convenience: append a single-vertex neighbor query.
pub fn appendNeighbors(b: *sql.Builder, step: Step, parent_id: sql.Value) !void {
    const ids = &[_]sql.Value{parent_id};
    try appendSetNeighbors(b, step, ids);
}

/// Append the body of an EXISTS subquery that checks whether a row has
/// neighbors through the given edge.  The caller is responsible for
/// wrapping the result with `EXISTS (...)`.
///
/// Produces:
///   O2M:  SELECT 1 FROM target WHERE fk = source.id
///   M2O:  SELECT 1 FROM target   WHERE target.pk = source.fk
///   M2M:  SELECT 1 FROM junction WHERE junction.source_pk = source.id
pub fn appendHasNeighbors(b: *sql.Builder, step: Step) !void {
    switch (step.edge_rel) {
        .o2m, .o2o => {
            try b.writeString("SELECT 1 FROM ");
            try b.ident(step.edge_table);
            try b.writeString(" WHERE ");
            try b.ident(step.edge_columns[0]);
            try b.writeString(" = ");
            try b.ident(step.from_table);
            try b.writeByte('.');
            try b.ident(step.from_column);
        },
        .m2o => {
            try b.writeString("SELECT 1 FROM ");
            try b.ident(step.to_table);
            try b.writeString(" WHERE ");
            try b.ident(step.to_table);
            try b.writeByte('.');
            try b.ident(step.to_column);
            try b.writeString(" = ");
            try b.ident(step.from_table);
            try b.writeByte('.');
            try b.ident(step.edge_columns[0]);
        },
        .m2m => {
            try b.writeString("SELECT 1 FROM ");
            try b.ident(step.edge_table);
            try b.writeString(" WHERE ");
            try b.ident(step.edge_table);
            try b.writeByte('.');
            try b.ident(step.sourcePK());
            try b.writeString(" = ");
            try b.ident(step.from_table);
            try b.writeByte('.');
            try b.ident(step.from_column);
        },
    }
}

/// Append the body of an EXISTS subquery with additional filter predicates
/// on the neighbor side.  The caller is responsible for wrapping with
/// `EXISTS (...)`.  Prefer using `.has_neighbors_with` on `sql.Predicate`
/// for new code.
pub fn appendHasNeighborsWith(b: *sql.Builder, step: Step, preds: []const sql.Predicate) !void {
    try b.writeString("SELECT 1 FROM ");
    switch (step.edge_rel) {
        .o2m, .o2o => {
            try b.ident(step.edge_table);
            try b.writeString(" WHERE ");
            try b.ident(step.edge_columns[0]);
            try b.writeString(" = ");
            try b.ident(step.from_table);
            try b.writeByte('.');
            try b.ident(step.from_column);
        },
        .m2o => {
            try b.ident(step.to_table);
            try b.writeString(" WHERE ");
            try b.ident(step.to_table);
            try b.writeByte('.');
            try b.ident(step.to_column);
            try b.writeString(" = ");
            try b.ident(step.from_table);
            try b.writeByte('.');
            try b.ident(step.edge_columns[0]);
        },
        .m2m => {
            try b.ident(step.edge_table);
            try b.writeString(" j INNER JOIN ");
            try b.ident(step.to_table);
            try b.writeString(" t ON j.");
            try b.ident(step.targetPK());
            try b.writeString(" = t.");
            try b.ident(step.to_column);
            try b.writeString(" WHERE j.");
            try b.ident(step.sourcePK());
            try b.writeString(" = ");
            try b.ident(step.from_table);
            try b.writeByte('.');
            try b.ident(step.from_column);
        },
    }
    if (preds.len > 0) {
        try b.writeString(" AND (");
        for (preds, 0..) |pred, i| {
            if (i > 0) try b.writeString(" AND ");
            try pred.appendTo(b);
        }
        try b.writeByte(')');
    }
}

/// Append a scalar subquery that returns the count of neighbors for
/// the current row.  The resulting SQL is suitable for use in ORDER BY:
///
///   (SELECT COUNT(*) FROM "car" WHERE "car"."owner_id" = "user"."id")
///
/// The subquery references the source table via `step.from_table` /
/// `step.from_column`, so it must be used in a query where the source
/// table is in scope (typically the same FROM clause).
pub fn appendEdgeCount(b: *sql.Builder, step: Step) !void {
    try b.writeString("(SELECT COUNT(*) FROM ");
    switch (step.edge_rel) {
        .o2m, .o2o => {
            // FK lives in target table: COUNT(*) FROM target WHERE fk = source.pk
            try b.ident(step.edge_table);
            try b.writeString(" WHERE ");
            try b.ident(step.edge_columns[0]);
            try b.writeString(" = ");
            try b.ident(step.from_table);
            try b.writeByte('.');
            try b.ident(step.from_column);
        },
        .m2o => {
            // FK lives in source table: COUNT(*) FROM target WHERE target.pk = source.fk
            try b.ident(step.to_table);
            try b.writeString(" WHERE ");
            try b.ident(step.to_table);
            try b.writeByte('.');
            try b.ident(step.to_column);
            try b.writeString(" = ");
            try b.ident(step.from_table);
            try b.writeByte('.');
            try b.ident(step.edge_columns[0]);
        },
        .m2m => {
            // Via junction: COUNT(*) FROM junction WHERE junction.source_pk = source.pk
            try b.ident(step.edge_table);
            try b.writeString(" WHERE ");
            try b.ident(step.edge_table);
            try b.writeByte('.');
            try b.ident(step.sourcePK());
            try b.writeString(" = ");
            try b.ident(step.from_table);
            try b.writeByte('.');
            try b.ident(step.from_column);
        },
    }
    try b.writeByte(')');
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

fn runSQL(allocator: std.mem.Allocator, comptime f: anytype, step: Step, extra: anytype) !sql.QueryResult {
    var b = sql.Builder.init(allocator, .{ .name = "sqlite" });
    defer b.deinit();
    if (@typeInfo(@TypeOf(extra)) == .@"struct" and @typeInfo(@TypeOf(extra)).@"struct".fields.len > 0) {
        try @call(.auto, f, .{ &b, step } ++ extra);
    } else {
        try @call(.auto, f, .{ &b, step });
    }
    return b.query();
}

test "appendSetNeighbors O2M" {
    const step = Step{
        .from_table = "user",
        .from_column = "id",
        .to_table = "car",
        .to_column = "id",
        .edge_rel = .o2m,
        .edge_table = "car",
        .edge_columns = &[_][]const u8{"owner_id"},
        .inverse = false,
    };
    const ids = &[_]sql.Value{ .{ .int = 1 }, .{ .int = 2 } };
    var b = sql.Builder.init(testing.allocator, .{ .name = "sqlite" });
    defer b.deinit();
    try appendSetNeighbors(&b, step, ids);
    const result = b.query();

    try testing.expectEqual(2, result.args.len);
    try testing.expectEqual(@as(i64, 1), result.args[0].int);
    try testing.expectEqual(@as(i64, 2), result.args[1].int);
    try testing.expect(std.mem.indexOf(u8, result.sql, "SELECT \"car\".*, \"car\".\"owner_id\" AS __fk") != null);
    try testing.expect(std.mem.indexOf(u8, result.sql, "FROM \"car\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.sql, "WHERE \"owner_id\" IN (?, ?)") != null);
}

test "appendSetNeighbors M2M" {
    const step = Step{
        .from_table = "user",
        .from_column = "id",
        .to_table = "group",
        .to_column = "id",
        .edge_rel = .m2m,
        .edge_table = "user_group",
        .edge_columns = &[_][]const u8{"group_id", "user_id"},
        .inverse = false,
    };
    var b = sql.Builder.init(testing.allocator, .{ .name = "sqlite" });
    defer b.deinit();
    try appendSetNeighbors(&b, step, &[_]sql.Value{.{ .int = 1 }});
    const result = b.query();

    try testing.expect(std.mem.indexOf(u8, result.sql, "SELECT \"group\".*, \"j\".\"user_id\" AS __fk") != null);
    try testing.expect(std.mem.indexOf(u8, result.sql, "INNER JOIN \"user_group\" j") != null);
    try testing.expect(std.mem.indexOf(u8, result.sql, "WHERE \"j\".\"user_id\" IN (?)") != null);
}

test "appendSetNeighbors M2O" {
    const step = Step{
        .from_table = "car",
        .from_column = "owner_id",
        .to_table = "user",
        .to_column = "id",
        .edge_rel = .m2o,
        .edge_table = "car",
        .edge_columns = &[_][]const u8{"owner_id"},
        .inverse = false,
    };
    var b = sql.Builder.init(testing.allocator, .{ .name = "sqlite" });
    defer b.deinit();
    try appendSetNeighbors(&b, step, &[_]sql.Value{.{ .int = 1 }});
    const result = b.query();

    try testing.expect(std.mem.indexOf(u8, result.sql, "INNER JOIN \"car\" s ON \"user\".\"id\" = s.\"owner_id\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.sql, "WHERE \"s\".\"owner_id\" IN (?)") != null);
}

test "appendHasNeighbors O2M" {
    const step = Step{
        .from_table = "user",
        .from_column = "id",
        .to_table = "car",
        .to_column = "id",
        .edge_rel = .o2m,
        .edge_table = "car",
        .edge_columns = &[_][]const u8{"owner_id"},
        .inverse = false,
    };
    var b = sql.Builder.init(testing.allocator, .{ .name = "sqlite" });
    defer b.deinit();
    try appendHasNeighbors(&b, step);
    const result = b.query();

    try testing.expect(std.mem.indexOf(u8, result.sql, "SELECT 1 FROM \"car\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.sql, "\"owner_id\" = \"user\".\"id\"") != null);
}

test "appendHasNeighbors M2M" {
    const step = Step{
        .from_table = "user",
        .from_column = "id",
        .to_table = "group",
        .to_column = "id",
        .edge_rel = .m2m,
        .edge_table = "user_group",
        .edge_columns = &[_][]const u8{"group_id", "user_id"},
        .inverse = false,
    };
    var b = sql.Builder.init(testing.allocator, .{ .name = "sqlite" });
    defer b.deinit();
    try appendHasNeighbors(&b, step);
    const result = b.query();

    try testing.expect(std.mem.indexOf(u8, result.sql, "SELECT 1 FROM \"user_group\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.sql, "\"user_group\".\"user_id\" = \"user\".\"id\"") != null);
}

test "appendHasNeighborsWith M2M" {
    const step = Step{
        .from_table = "user",
        .from_column = "id",
        .to_table = "group",
        .to_column = "id",
        .edge_rel = .m2m,
        .edge_table = "user_group",
        .edge_columns = &[_][]const u8{"group_id", "user_id"},
        .inverse = false,
    };
    var b = sql.Builder.init(testing.allocator, .{ .name = "sqlite" });
    defer b.deinit();
    const pred = sql.EQ("group.name", .{ .string = "admins" });
    try appendHasNeighborsWith(&b, step, &.{pred});
    const result = b.query();

    try testing.expect(std.mem.indexOf(u8, result.sql, "AND (") != null);
    try testing.expect(std.mem.indexOf(u8, result.sql, "\"group\".\"name\" = ?") != null);
    try testing.expectEqual(@as(usize, 1), result.args.len);
    try testing.expectEqualStrings("admins", result.args[0].string);
}

test "appendEdgeCount O2M" {
    const step = Step{
        .from_table = "user",
        .from_column = "id",
        .to_table = "car",
        .to_column = "id",
        .edge_rel = .o2m,
        .edge_table = "car",
        .edge_columns = &[_][]const u8{"owner_id"},
        .inverse = false,
    };
    var b = sql.Builder.init(testing.allocator, .{ .name = "sqlite" });
    defer b.deinit();
    try appendEdgeCount(&b, step);
    const result = b.query();

    try testing.expect(std.mem.indexOf(u8, result.sql, "SELECT COUNT(*)") != null);
    try testing.expect(std.mem.indexOf(u8, result.sql, "\"owner_id\" = \"user\".\"id\"") != null);
}

test "appendEdgeCount M2M" {
    const step = Step{
        .from_table = "user",
        .from_column = "id",
        .to_table = "group",
        .to_column = "id",
        .edge_rel = .m2m,
        .edge_table = "user_group",
        .edge_columns = &[_][]const u8{"group_id", "user_id"},
        .inverse = false,
    };
    var b = sql.Builder.init(testing.allocator, .{ .name = "sqlite" });
    defer b.deinit();
    try appendEdgeCount(&b, step);
    const result = b.query();

    try testing.expect(std.mem.indexOf(u8, result.sql, "SELECT COUNT(*)") != null);
    try testing.expect(std.mem.indexOf(u8, result.sql, "\"user_group\".\"user_id\" = \"user\".\"id\"") != null);
}

test "appendEdgeCount M2O" {
    const step = Step{
        .from_table = "car",
        .from_column = "owner_id",
        .to_table = "user",
        .to_column = "id",
        .edge_rel = .m2o,
        .edge_table = "car",
        .edge_columns = &[_][]const u8{"owner_id"},
        .inverse = false,
    };
    var b = sql.Builder.init(testing.allocator, .{ .name = "sqlite" });
    defer b.deinit();
    try appendEdgeCount(&b, step);
    const result = b.query();

    try testing.expect(std.mem.indexOf(u8, result.sql, "SELECT COUNT(*)") != null);
    try testing.expect(std.mem.indexOf(u8, result.sql, "\"user\".\"id\" = \"car\".\"owner_id\"") != null);
}
