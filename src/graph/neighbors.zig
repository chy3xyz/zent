const std = @import("std");
const sql = @import("../sql/builder.zig");
const Step = @import("step.zig").Step;

// ------------------------------------------------------------------
// Internal helpers
// ------------------------------------------------------------------

/// Write `<qualifier.>column IN (?,?,…) [OR <qualifier.>column IN (?,?,…)]` —
/// parent id lists are chunked so eager loads never exceed the driver
/// parameter limit (e.g. SQLite 999).
///
/// The column predicate is repeated for every chunk: `col IN (a, b) OR (c, d)`
/// is not valid SQL (PostgreSQL rejects a record as an OR operand, SQLite
/// reports "row value misused"), so a two-chunk eager load would fail.
fn writeInClauseChunked(
    b: *sql.Builder,
    qualifier: ?[]const u8,
    column: []const u8,
    parent_ids: []const sql.Value,
) !void {
    const chunk_size: usize = 500;
    var start: usize = 0;
    var first = true;
    while (start < parent_ids.len) {
        const end = @min(start + chunk_size, parent_ids.len);
        if (!first) try b.writeString(" OR ");
        if (qualifier) |q| {
            // Aliases are introduced unquoted by the JOINs above; keep the
            // emitted form byte-compatible with the pre-chunking SQL.
            try b.writeString(q);
            try b.writeByte('.');
        }
        try b.ident(column);
        try b.writeString(" IN (");
        for (parent_ids[start..end], 0..) |id, i| {
            if (i > 0) try b.writeString(", ");
            try b.arg(id);
        }
        try b.writeByte(')');
        start = end;
        first = false;
    }
}

fn writeEagerLoadColumns(b: *sql.Builder, step: Step, include_select: bool) !void {
    // The result set includes target.* plus a computed __fk column that
    // identifies which parent row each result belongs to.
    if (include_select) try b.writeString("SELECT ");
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
    return appendSetNeighborsFiltered(b, step, parent_ids, &.{});
}

/// Like `appendSetNeighbors`, but ANDs `extra_preds` into the neighbor
/// WHERE clause. They are emitted before any per-parent window ranking or
/// ORDER BY, so a per-parent `Limit` ranks only rows that pass the filters
/// (soft-delete / privacy / interceptor scopes) instead of a trashed or
/// foreign-tenant row consuming a limit slot. Predicates are rendered
/// through the caller's builder, so dialect placeholders and bound args
/// stay in text order.
pub fn appendSetNeighborsFiltered(
    b: *sql.Builder,
    step: Step,
    parent_ids: []const sql.Value,
    extra_preds: []const sql.Predicate,
) !void {
    const use_window = step.limit != null;
    if (use_window and step.edge_rel != .o2m and step.edge_rel != .o2o) {
        return error.UnsupportedEdgeLimit;
    }

    if (use_window) {
        try b.writeString("SELECT * FROM (SELECT ");
    }
    try writeEagerLoadColumns(b, step, !use_window);
    if (use_window) {
        // Per-parent row number: PARTITION BY the FK, ordered by the edge's
        // declared order column (required when a limit is set).
        try b.writeString(", ROW_NUMBER() OVER (PARTITION BY ");
        try b.ident(step.edge_columns[0]);
        try b.writeString(" ORDER BY ");
        try b.ident(step.to_table);
        try b.writeByte('.');
        try b.ident(step.order_by orelse return error.MissingEdgeOrder);
        if (step.desc) try b.writeString(" DESC");
        try b.writeString(") AS __rn");
    }
    try b.writeString(" FROM ");
    try b.ident(step.to_table);

    switch (step.edge_rel) {
        .o2m, .o2o => {
            // ToEdgeOwner: FK is in target table.
            //   SELECT t.*, t.fk AS __fk FROM target t WHERE t.fk IN (...)
            try b.writeString(" WHERE ");
            try writeInClauseChunked(b, null, step.edge_columns[0], parent_ids);
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
            try b.writeString(" WHERE ");
            try writeInClauseChunked(b, "s", step.from_column, parent_ids);
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
            try b.writeString(" WHERE ");
            try writeInClauseChunked(b, "j", step.sourcePK(), parent_ids);
        },
    }

    if (step.filter) |*pred| {
        // Inner WHERE (before any window/order), so limits rank filtered rows.
        try b.writeString(" AND ");
        try sql.appendExprWithArgs(b, pred.sql, pred.args);
    }

    for (extra_preds) |pred| {
        try b.writeString(" AND ");
        // Interceptor-injected tenant scoping (`QueryView.whereEq`) arrives as
        // a bare-column EQ, and this query joins the source table, which may
        // own the same column (e.g. `app_id` on both sides). `appendQualifiedPred`
        // qualifies it with the eager-loaded target — otherwise the prepared
        // statement fails with "ambiguous column". Policy filters and raw
        // fragments pass through untouched.
        try sql.appendQualifiedPred(b, pred, step.to_table);
    }

    if (use_window) {
        var num_buf: [32]u8 = undefined;
        const n = try std.fmt.bufPrint(&num_buf, "{d}", .{step.limit.?});
        try b.writeString(") WHERE __rn <= ");
        try b.writeString(n);
    } else if (step.order_by) |col| {
        try b.writeString(" ORDER BY ");
        try b.ident(step.to_table);
        try b.writeByte('.');
        try b.ident(col);
        if (step.desc) try b.writeString(" DESC");
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
    try testing.expect(std.mem.indexOf(u8, result.sql, "SELECT \"car\".*, \"owner_id\" AS __fk") != null);
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
        .edge_columns = &[_][]const u8{ "group_id", "user_id" },
        .inverse = false,
    };
    var b = sql.Builder.init(testing.allocator, .{ .name = "sqlite" });
    defer b.deinit();
    try appendSetNeighbors(&b, step, &[_]sql.Value{.{ .int = 1 }});
    const result = b.query();

    try testing.expect(std.mem.indexOf(u8, result.sql, "SELECT \"group\".*, \"j\".\"user_id\" AS __fk") != null);
    try testing.expect(std.mem.indexOf(u8, result.sql, "INNER JOIN \"user_group\" j") != null);
    try testing.expect(std.mem.indexOf(u8, result.sql, "WHERE j.\"user_id\" IN (?)") != null);
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
    try testing.expect(std.mem.indexOf(u8, result.sql, "WHERE s.\"owner_id\" IN (?)") != null);
}

test "appendSetNeighbors order + per-parent limit uses window function" {
    const step = Step{
        .from_table = "user",
        .from_column = "id",
        .to_table = "post",
        .to_column = "id",
        .edge_rel = .o2m,
        .edge_table = "post",
        .edge_columns = &[_][]const u8{"author_id"},
        .inverse = false,
        .order_by = "created_at",
        .desc = true,
        .limit = 2,
    };
    var b = sql.Builder.init(testing.allocator, .{ .name = "sqlite" });
    defer b.deinit();
    try appendSetNeighbors(&b, step, &[_]sql.Value{.{ .int = 1 }});
    const result = b.query();
    try testing.expect(std.mem.indexOf(u8, result.sql, "SELECT * FROM (SELECT") != null);
    try testing.expect(std.mem.indexOf(u8, result.sql, "ROW_NUMBER() OVER (PARTITION BY \"author_id\" ORDER BY \"post\".\"created_at\" DESC) AS __rn") != null);
    try testing.expect(std.mem.indexOf(u8, result.sql, ") WHERE __rn <= 2") != null);
}

test "appendSetNeighborsFiltered qualifies interceptor EQ with the target table (m2o join)" {
    // Regression: v0.35 started running the interceptor chain on eager-loaded
    // targets. The m2o neighbour query joins the source table, so an
    // unqualified tenant column (`app_id`) made the prepared statement
    // ambiguous. The injected EQ must be qualified with the target table.
    const step = Step{
        .from_table = "product_image",
        .from_column = "id",
        .to_table = "upload_file",
        .to_column = "file_id",
        .edge_rel = .m2o,
        .edge_table = "upload_file",
        .edge_columns = &[_][]const u8{"image_id"},
        .inverse = false,
        .order_by = null,
        .desc = false,
        .limit = null,
    };
    var b = sql.Builder.init(testing.allocator, .{ .name = "mysql" });
    defer b.deinit();
    const extra = [_]sql.Predicate{sql.EQ("app_id", .{ .int = 1 })};
    try appendSetNeighborsFiltered(&b, step, &[_]sql.Value{.{ .int = 5 }}, &extra);
    const result = b.query();
    try testing.expect(std.mem.indexOf(u8, result.sql, "AND `upload_file`.`app_id` = ?") != null);
}

test "appendSetNeighborsFiltered qualifies a soft-delete filter on the m2o join" {
    // Same shape as the tenant EQ above, for the other predicate the read
    // contract injects by itself: a source and target that are both
    // soft-deletable own `deleted_at` on each side of the join.
    const step = Step{
        .from_table = "product_image",
        .from_column = "id",
        .to_table = "upload_file",
        .to_column = "file_id",
        .edge_rel = .m2o,
        .edge_table = "upload_file",
        .edge_columns = &[_][]const u8{"image_id"},
        .inverse = false,
        .order_by = null,
        .desc = false,
        .limit = null,
    };
    var b = sql.Builder.init(testing.allocator, .{ .name = "postgres" });
    defer b.deinit();
    const extra = [_]sql.Predicate{sql.IsNull("deleted_at")};
    try appendSetNeighborsFiltered(&b, step, &[_]sql.Value{.{ .int = 5 }}, &extra);
    const result = b.query();
    try testing.expect(std.mem.indexOf(u8, result.sql, "AND \"upload_file\".\"deleted_at\" IS NULL") != null);

    // A predicate that already carries a qualifier is left alone.
    var b2 = sql.Builder.init(testing.allocator, .{ .name = "postgres" });
    defer b2.deinit();
    const extra2 = [_]sql.Predicate{sql.IsNull("s.deleted_at")};
    try appendSetNeighborsFiltered(&b2, step, &[_]sql.Value{.{ .int = 5 }}, &extra2);
    const result2 = b2.query();
    try testing.expect(std.mem.indexOf(u8, result2.sql, "AND \"s\".\"deleted_at\" IS NULL") != null);
    try testing.expect(std.mem.indexOf(u8, result2.sql, "\"upload_file\".\"s\"") == null);
}

test "appendSetNeighborsFiltered applies extra predicates before the window rank" {
    const step = Step{
        .from_table = "user",
        .from_column = "id",
        .to_table = "post",
        .to_column = "id",
        .edge_rel = .o2m,
        .edge_table = "post",
        .edge_columns = &[_][]const u8{"author_id"},
        .inverse = false,
        .order_by = "created_at",
        .desc = true,
        .limit = 2,
    };
    var b = sql.Builder.init(testing.allocator, .{ .name = "sqlite" });
    defer b.deinit();
    const extra = [_]sql.Predicate{sql.IsNull("deleted_at")};
    try appendSetNeighborsFiltered(&b, step, &[_]sql.Value{.{ .int = 1 }}, &extra);
    const result = b.query();

    // Qualified with the target table like every other injected predicate:
    // when both sides of the join are soft-deletable, a bare `deleted_at`
    // is exactly as ambiguous as a bare tenant column.
    const filter_idx = std.mem.indexOf(u8, result.sql, "AND \"post\".\"deleted_at\" IS NULL");
    const rank_idx = std.mem.indexOf(u8, result.sql, ") WHERE __rn <=");
    try testing.expect(filter_idx != null);
    try testing.expect(rank_idx != null);
    // The filter must run inside the derived table, before the per-parent
    // rank, so a filtered row cannot consume a limit slot.
    try testing.expect(filter_idx.? < rank_idx.?);
}

test "appendSetNeighbors chunks parent ids and repeats the column predicate" {
    const step = Step{
        .from_table = "user",
        .from_column = "id",
        .to_table = "post",
        .to_column = "id",
        .edge_rel = .o2m,
        .edge_table = "post",
        .edge_columns = &[_][]const u8{"author_id"},
        .inverse = false,
    };

    const allocator = testing.allocator;
    // 501 ids → two chunks (chunk_size = 500).
    const ids = try allocator.alloc(sql.Value, 501);
    defer allocator.free(ids);
    for (ids, 0..) |*v, i| v.* = .{ .int = @intCast(i + 1) };

    var b = sql.Builder.init(allocator, .{ .name = "sqlite" });
    defer b.deinit();
    try appendSetNeighbors(&b, step, ids);
    const result = b.query();

    // Each chunk must repeat the column: `col IN (…) OR (…)` is not valid SQL
    // (PostgreSQL rejects a record as an OR operand; SQLite reports
    // "row value misused"), so the predicate is emitted once per chunk.
    const in_count = std.mem.count(u8, result.sql, "\"author_id\" IN (");
    try testing.expectEqual(@as(usize, 2), in_count);
    try testing.expect(std.mem.indexOf(u8, result.sql, ") OR \"author_id\" IN (") != null);
    try testing.expectEqual(@as(usize, 501), result.args.len);

    // The second chunk must still be a plain parenthesised list, never a
    // bare row-value constructor.
    try testing.expect(std.mem.indexOf(u8, result.sql, " OR (") == null);
}

test "appendSetNeighbors rejects limit on m2m" {
    const step = Step{
        .from_table = "user",
        .from_column = "id",
        .to_table = "group",
        .to_column = "id",
        .edge_rel = .m2m,
        .edge_table = "user_group",
        .edge_columns = &[_][]const u8{ "group_id", "user_id" },
        .inverse = false,
        .limit = 2,
    };
    var b = sql.Builder.init(testing.allocator, .{ .name = "sqlite" });
    defer b.deinit();
    try testing.expectError(error.UnsupportedEdgeLimit, appendSetNeighbors(&b, step, &[_]sql.Value{.{ .int = 1 }}));
}

test "appendSetNeighbors applies filter fragment with args" {
    const step = Step{
        .from_table = "post",
        .from_column = "id",
        .to_table = "comment",
        .to_column = "id",
        .edge_rel = .o2m,
        .edge_table = "comment",
        .edge_columns = &[_][]const u8{"post_id"},
        .inverse = false,
        .filter = .{ .sql = "\"status\" = ?", .args = &.{.{ .string = "visible" }} },
    };
    var b = sql.Builder.init(testing.allocator, .{ .name = "sqlite" });
    defer b.deinit();
    try appendSetNeighbors(&b, step, &[_]sql.Value{.{ .int = 1 }});
    const result = b.query();
    try testing.expect(std.mem.indexOf(u8, result.sql, "AND \"status\" = ?") != null);
    try testing.expectEqual(@as(usize, 2), result.args.len);
    try testing.expectEqualStrings("visible", result.args[1].string);
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
        .edge_columns = &[_][]const u8{ "group_id", "user_id" },
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
        .edge_columns = &[_][]const u8{ "group_id", "user_id" },
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
        .edge_columns = &[_][]const u8{ "group_id", "user_id" },
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
