//! Read-contract fragments for **raw SQL**.
//!
//! The interceptor chain and the privacy policy only reach the fluent
//! builders: an injected predicate needs a `QueryView` sink, and the sinks are
//! per-builder. A caller holding a bare statement — `driver.query("SELECT …
//! FROM orders WHERE …", args)` — has no way to ask "what may this table
//! show?", so tenant scoping is silently skipped. That is not a hypothetical
//! hole: a multi-tenant consumer reported 56 cross-tenant reads spread over 15
//! files, all raw call sites.
//!
//! `forTable` closes it by rendering the *same* contract the fluent path uses
//! — `codegen.query.appendTargetScopePreds`, the single implementation of
//! soft-delete → privacy → interceptors — into a fragment the caller splices
//! into their statement:
//!
//! ```zig
//! var scope = try zent.scope.forClient(infos, "order", &client.order, .{ .alias = "o" });
//! defer scope.deinit();
//!
//! var buf = std.ArrayList(u8).init(allocator);
//! try buf.appendSlice("SELECT o.id FROM order o WHERE o.amount > ?");
//! try scope.write(buf.writer(testing.allocator), true);  // safe to call unconditionally
//! ```
//!
//! Two things it deliberately does not do. It cannot rewrite a statement for
//! you: only you know where the clause goes and what the aliases are, so the
//! fragment is append-only and `write` handles the `WHERE` / `AND` choice. And
//! it only knows the tables in the graph you pass — that is what makes
//! `forTable` a compile-time check instead of a runtime string lookup.

const std = @import("std");
const TypeInfo = @import("graph.zig").TypeInfo;
const sql = @import("../sql/builder.zig");
const Dialect = @import("../sql/dialect.zig").Dialect;
const privacy = @import("../privacy/policy.zig");
const intercept = @import("../runtime/intercept.zig");
const appendTargetScopePreds = @import("query.zig").appendTargetScopePreds;

pub const Error = error{ BuildFailed, PrivacyDenied, InterceptFailed, OutOfMemory };

/// The operation enums are what the caller sees; re-exported so a call site
/// does not have to name the runtime module.
pub const Op = @import("../runtime/hook.zig").Op;

pub const Options = struct {
    /// The SQL alias the table carries in *your* statement (e.g. `o` for
    /// `FROM order o`). When set, every injected predicate is rendered
    /// qualified — `"o"."app_id" = ?` — because a bare column is rejected as
    /// ambiguous the moment your statement joins another table that owns the
    /// same column. Leave it null for a single-table statement.
    ///
    /// Aliases are quoted, so use the alias as the database will have folded
    /// it (lowercase unless you quoted it yourself).
    alias: ?[]const u8 = null,
    /// Include soft-deleted rows, as `WithTrashed` does for the fluent path.
    with_trashed: bool = false,
    /// What the privacy policy and the interceptors see. Use `.query` for
    /// SELECT, `.update`/`.delete` for the mutation you are about to run — the
    /// scope of a statement that writes is not the scope of one that reads.
    op: Op = .query,
};

/// `forTable` by physical **table name** (`"order"`) or entity name
/// (`"Order"`); both resolve against `infos` at compile time.
///
/// Returns an owned fragment: `sql` is a parenthesised predicate list
/// (`("o"."deleted_at" IS NULL AND "o"."app_id" = ?)`), empty when this table
/// needs no scoping at all, and `args` are its bound values in SQL order.
/// Release with `deinit()`.
pub fn forTable(
    comptime infos: []const TypeInfo,
    comptime table_name: []const u8,
    allocator: std.mem.Allocator,
    dialect: Dialect,
    privacy_ctx: ?privacy.PrivacyContext,
    interceptors: ?*intercept.InterceptorChain,
    opts: Options,
) Error!sql.OwnedQuery {
    const info = comptime findTypeInfo(infos, table_name) orelse
        @compileError("zent.scope.forTable: no table or entity named '" ++ table_name ++ "' in this graph");

    var preds = std.ArrayListUnmanaged(sql.Predicate).empty;
    defer preds.deinit(allocator);
    try appendTargetScopePreds(info, &preds, allocator, privacy_ctx, interceptors, opts.with_trashed, opts.op);

    var b = sql.Builder.init(allocator, dialect);
    defer b.deinit();
    if (preds.items.len > 0) {
        try b.writeByte('(');
        for (preds.items, 0..) |pred, i| {
            if (i > 0) try b.writeString(" AND ");
            // The same qualification the eager loader applies, from the same
            // helper, so the two cannot disagree about what a scoped
            // predicate looks like.
            sql.appendQualifiedPred(&b, pred, opts.alias) catch |err| return mapBuildError(err);
        }
        try b.writeByte(')');
    }
    const owned = b.takeQuery() catch |err| return mapBuildError(err);
    return owned;
}

/// Rendering a predicate can fail for reasons no caller can act on
/// differently (a placeholder buffer, a raw fragment's own error); collapse
/// them into `BuildFailed` the way the neighbour readers do, and keep
/// `OutOfMemory` distinct.
fn mapBuildError(err: anyerror) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.BuildFailed;
}

/// `forTable` against an entity client, which already carries the allocator,
/// the driver (and therefore the dialect), the `privacy_ctx` and the
/// interceptor chain. This is the shape the fluent builders use internally, so
/// a raw statement scoped through it sees exactly what a builder would.
///
/// ```zig
/// var scope = try zent.scope.forClient(infos, "order", &client.order, .{});
/// ```
pub fn forClient(
    comptime infos: []const TypeInfo,
    comptime table_name: []const u8,
    client: anytype,
    opts: Options,
) Error!sql.OwnedQuery {
    return forTable(infos, table_name, client.allocator, client.driver.dialect(), client.privacy_ctx, client.interceptors, opts);
}

/// Write the fragment as a clause, given whether the statement already has a
/// `WHERE`. Emits `" WHERE (…)"`, `" AND (…)"` or nothing, so it is safe to
/// call unconditionally — forgetting to append the scope is the failure mode
/// this API exists to remove.
///
/// `writer` only needs a `writeAll([]const u8)` method (`std.Io.Writer`
/// qualifies; an `sql.Builder` does not, so render the fragment and splice it
/// into the statement you are already building).
///
/// ```zig
/// var out = std.array_list.Managed(u8).init(allocator);
/// try out.appendSlice("SELECT * FROM order o WHERE o.amount > ?");
/// try zent.scope.writeClause(scope, writerFor(&out), true);
/// ```
pub fn writeClause(fragment: sql.OwnedQuery, writer: anytype, has_where: bool) !void {
    if (fragment.sql.len == 0) return;
    try writer.writeAll(if (has_where) " AND " else " WHERE ");
    try writer.writeAll(fragment.sql);
}

/// `head` with the scope clause appended, as one owned statement ready to
/// hand to `driver.query(statement, fragment.args)`. The caller keeps writing
/// the part they know (tables, joins, their own predicates) and this decides
/// the `WHERE` / `AND` placement for them:
///
/// ```zig
/// var scope = try zent.scope.forClient(infos, "order", &client.order, .{});
/// defer scope.deinit();
/// const stmt = try zent.scope.withClause(scope, allocator, "SELECT o.id FROM order o WHERE o.amount > ?", true);
/// defer allocator.free(stmt);
/// var rows = try client.order.driver.query(stmt, scope.args);
/// ```
///
/// When the table contributes no scope at all the head is returned unchanged,
/// so this is safe to call unconditionally — forgetting to append the scope is
/// the failure mode this API exists to remove.
pub fn withClause(fragment: sql.OwnedQuery, allocator: std.mem.Allocator, head: []const u8, has_where: bool) ![]u8 {
    if (fragment.sql.len == 0) return allocator.dupe(u8, head);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        head,
        if (has_where) " AND " else " WHERE ",
        fragment.sql,
    });
}

/// True when this table contributed no scope at all — no soft-delete column,
/// no policy, no interceptor predicate. Callers that build SQL conditionally
/// can branch on it; `writeClause` already handles the case.
pub fn isEmpty(fragment: sql.OwnedQuery) bool {
    return fragment.sql.len == 0;
}

fn findTypeInfo(comptime infos: []const TypeInfo, comptime name: []const u8) ?TypeInfo {
    for (infos) |ti| {
        if (std.mem.eql(u8, ti.table_name, name)) return ti;
    }
    for (infos) |ti| {
        if (std.mem.eql(u8, ti.name, name)) return ti;
    }
    return null;
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

/// Minimal `writeAll` sink: that single method is the whole contract of
/// `writeClause`, so the test does not depend on the std writer plumbing.
const TestWriter = struct {
    list: *std.array_list.Managed(u8),

    fn writeAll(self: *TestWriter, bytes: []const u8) !void {
        try self.list.appendSlice(bytes);
    }
};

const field = @import("../core/field.zig");
const mixin = @import("../core/mixin.zig");
const schema = @import("../core/schema.zig").Schema;
const buildGraph = @import("graph.zig").buildGraph;

test "scope.forTable renders the tenant and soft-delete contract" {
    const Order = schema("ScopeOrder", .{
        .fields = &.{ field.Int("app_id"), field.String("code") },
        .mixins = &.{mixin.SoftDeleteMixin},
        .soft_delete = true,
    });
    const graph = comptime buildGraph(&.{Order});
    const infos = graph.types;

    var chain = intercept.InterceptorChain.init(testing.allocator);
    defer chain.deinit();
    try chain.use(.{ .intercept = struct {
        fn f(_: ?*anyopaque, view: *intercept.QueryView) anyerror!void {
            try view.whereEq("app_id", .{ .int = 7 });
        }
    }.f });

    // Unaliased: bare columns, one placeholder each, in contract order.
    {
        var fragment = try forTable(infos, "scope_order", testing.allocator, .{ .name = "sqlite" }, null, &chain, .{});
        defer fragment.deinit();
        try testing.expectEqualStrings("(\"deleted_at\" IS NULL AND \"app_id\" = ?)", fragment.sql);
        try testing.expectEqual(@as(usize, 1), fragment.args.len);
        try testing.expectEqual(@as(i64, 7), fragment.args[0].int);
        try testing.expect(!isEmpty(fragment));
    }

    // Aliased: every injected predicate is qualified, which is what keeps a
    // JOIN with a second `app_id` from failing at prepare time.
    {
        var fragment = try forTable(infos, "scope_order", testing.allocator, .{ .name = "mysql" }, null, &chain, .{ .alias = "o" });
        defer fragment.deinit();
        try testing.expectEqualStrings("(`o`.`deleted_at` IS NULL AND `o`.`app_id` = ?)", fragment.sql);
    }

    // The entity name resolves as well as the table name.
    {
        var fragment = try forTable(infos, "ScopeOrder", testing.allocator, .{ .name = "sqlite" }, null, &chain, .{});
        defer fragment.deinit();
        try testing.expectEqualStrings("(\"deleted_at\" IS NULL AND \"app_id\" = ?)", fragment.sql);
    }

    // `WithTrashed` drops the soft-delete half, like the fluent path.
    {
        var fragment = try forTable(infos, "scope_order", testing.allocator, .{ .name = "sqlite" }, null, &chain, .{ .with_trashed = true });
        defer fragment.deinit();
        try testing.expectEqualStrings("(\"app_id\" = ?)", fragment.sql);
    }

    // PostgreSQL placeholders follow the dialect, so the fragment is
    // interchangeable with the ones the builders emit.
    {
        var fragment = try forTable(infos, "scope_order", testing.allocator, .{ .name = "postgres" }, null, &chain, .{ .alias = "o" });
        defer fragment.deinit();
        try testing.expectEqualStrings("(\"o\".\"deleted_at\" IS NULL AND \"o\".\"app_id\" = $1)", fragment.sql);
    }

    // No chain, no policy, not soft-deletable in this configuration: an empty
    // fragment, and `writeClause` then writes nothing at all.
    {
        var fragment = try forTable(infos, "scope_order", testing.allocator, .{ .name = "sqlite" }, null, null, .{ .with_trashed = true });
        defer fragment.deinit();
        try testing.expectEqualStrings("", fragment.sql);
        try testing.expect(isEmpty(fragment));

        var buf = std.array_list.Managed(u8).init(testing.allocator);
        defer buf.deinit();
        var w = TestWriter{ .list = &buf };
        try buf.appendSlice("SELECT * FROM scope_order");
        try writeClause(fragment, &w, false);
        try testing.expectEqualStrings("SELECT * FROM scope_order", buf.items);
    }

    // `writeClause` picks WHERE or AND, so the call site does not have to.
    {
        var fragment = try forTable(infos, "scope_order", testing.allocator, .{ .name = "sqlite" }, null, &chain, .{});
        defer fragment.deinit();

        var buf = std.array_list.Managed(u8).init(testing.allocator);
        defer buf.deinit();
        var w = TestWriter{ .list = &buf };
        try buf.appendSlice("SELECT * FROM scope_order");
        try writeClause(fragment, &w, false);
        try testing.expectEqualStrings(
            "SELECT * FROM scope_order WHERE (\"deleted_at\" IS NULL AND \"app_id\" = ?)",
            buf.items,
        );

        var buf2 = std.array_list.Managed(u8).init(testing.allocator);
        defer buf2.deinit();
        var w2 = TestWriter{ .list = &buf2 };
        try buf2.appendSlice("SELECT * FROM scope_order WHERE code = ?");
        try writeClause(fragment, &w2, true);
        try testing.expectEqualStrings(
            "SELECT * FROM scope_order WHERE code = ? AND (\"deleted_at\" IS NULL AND \"app_id\" = ?)",
            buf2.items,
        );
    }
}

test "scope.forTable is fail-closed for a policy-bearing table" {
    const Secret = schema("ScopeSecret", .{
        .fields = &.{field.Int("owner_id")},
        .policy = privacy.Policy{ .rules = &.{ privacy.Allow, privacy.Deny } },
    });
    const graph = comptime buildGraph(&.{Secret});
    const infos = graph.types;

    // No privacy context: deny, exactly as the fluent path does, rather than
    // returning an unscoped fragment.
    try testing.expectError(
        error.PrivacyDenied,
        forTable(infos, "scope_secret", testing.allocator, .{ .name = "sqlite" }, null, null, .{}),
    );

    // With a context the policy decides; here it denies the operation
    // outright, which must not degrade into "no fragment".
    try testing.expectError(
        error.PrivacyDenied,
        forTable(infos, "scope_secret", testing.allocator, .{ .name = "sqlite" }, privacy.PrivacyContext{ .user_id = 1 }, null, .{}),
    );
}

test "scope.forTable passes a policy filter through" {
    const Doc = schema("ScopeDoc", .{
        .fields = &.{field.Int("owner_id")},
        .policy = privacy.Policy{ .rules = &.{ privacy.Allow, privacy.Filter(docFilter) } },
    });
    const graph = comptime buildGraph(&.{Doc});
    const infos = graph.types;

    var fragment = try forTable(
        infos,
        "scope_doc",
        testing.allocator,
        .{ .name = "sqlite" },
        privacy.PrivacyContext{ .user_id = 42 },
        null,
        .{ .alias = "d" },
    );
    defer fragment.deinit();
    try testing.expectEqualStrings("(\"d\".\"owner_id\" = ?)", fragment.sql);
    try testing.expectEqual(@as(i64, 42), fragment.args[0].int);
}

/// `privacy.Filter` hands back an opaque pointer that must stay valid for the
/// duration of the eval, so the predicate lives at file scope.
var filter_pred: sql.Predicate = undefined;

fn docFilter(ctx: privacy.PrivacyContext) ?*const anyopaque {
    const owner = ctx.user_id orelse return null;
    filter_pred = sql.EQ("owner_id", .{ .int = @intCast(owner) });
    return @ptrCast(&filter_pred);
}
