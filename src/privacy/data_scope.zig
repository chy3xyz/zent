//! Data-scope row-level security for zent - the schema-as-code counterpart
//! of zmsaas' sqlx `DataPermissionContext` (all / self_ / dept_only /
//! dept_and_child / dept_custom). The schema attaches `data_scope.Policy`;
//! the app builds one `DataScopeFilter` per request and passes it through
//! `PrivacyContext.extra`; every query/mutation then gets the scope
//! predicate injected at the SQL layer (no hand-written WHERE clauses).
//!
//! Usage:
//!   const Doc = Schema("Doc", .{
//!       .fields = &.{ field.Int("tenant_id"), field.Int("owner_id"),
//!                       field.Int("dept_id"), field.String("title") },
//!       .policy = data_scope.Policy,   // requires a per-request filter
//!   });
//!   // per request:
//!   var scope = data_scope.DataScopeFilter.init("dept_id", "owner_id",
//!       .self_, .{ .user_id = 7, .self_dept_id = 3, .dept_ids = &.{3, 4} });
//!   const client = client.withContext(scope.context(.{ .user_id = 7 }));
//!   // client.doc.Query() ... - scope predicate auto-injected.

const std = @import("std");
const sql = @import("../sql/builder.zig");
const privacy = @import("policy.zig");
const rtp = @import("../runtime/privacy.zig");

/// Data scope semantics, mirroring Rbac.DataScope / zmsaas DataPermission.
pub const DataScope = enum {
    all,
    self_,
    dept_only,
    dept_and_child,
    dept_custom,
};

/// Max departments supported in one IN-list without allocation.
pub const max_dept_ids = 32;

/// The always-false predicate every fail-closed path in this module shares: a
/// scope that cannot be built denies, and it must never come out looking like
/// "no restriction" (`.all`) — `null` is how the filter rule spells that. The
/// cases are a `dept_ids` list longer than `max_dept_ids`, an empty `dept_ids`
/// list (its `IN ()` has no valid SQL, and a caller in no department sees no
/// rows) and a `PrivacyContext` without `.extra`. `1 = 0`
/// is valid on all three dialects, and carrying no column reference keeps it
/// unambiguous in the joins the predicate is spliced into.
const deny_pred: sql.Predicate = sql.Raw("1 = 0");

/// Per-request data-scope decision. Build one per request (stack or arena),
/// pass its address via `PrivacyContext.extra`, and keep it alive for the
/// duration of the queries - the injected predicate borrows from it.
pub const DataScopeFilter = struct {
    scope: DataScope = .self_,
    user_id: i64 = 0,
    self_dept_id: i64 = 0,
    /// Departments a `.dept_custom` / `.dept_and_child` scope may see. An empty
    /// list denies (the caller belongs to no department); use `.all` to lift
    /// the restriction.
    dept_ids: []const i64 = &.{},
    dept_column: []const u8 = "dept_id",
    user_column: []const u8 = "user_id",
    pred: ?sql.Predicate = null,
    value_buf: [max_dept_ids]sql.Value = undefined,

    /// Configure the scope. `dept_column`/`user_column` are the table columns
    /// the scope applies to. The predicate is materialized lazily by
    /// `ensurePred` so IN-value slices point into this instance's own buffer
    /// (safe across the init() return copy).
    pub fn init(
        comptime dept_column: []const u8,
        comptime user_column: []const u8,
        scope: DataScope,
        opts: struct {
            user_id: i64 = 0,
            self_dept_id: i64 = 0,
            dept_ids: []const i64 = &.{},
        },
    ) DataScopeFilter {
        return .{
            .scope = scope,
            .user_id = opts.user_id,
            .self_dept_id = opts.self_dept_id,
            .dept_ids = opts.dept_ids,
            .dept_column = dept_column,
            .user_column = user_column,
        };
    }

    /// Materialize the scope predicate on this instance (idempotent).
    pub fn ensurePred(self: *DataScopeFilter) void {
        if (self.pred != null) return;
        switch (self.scope) {
            .all => {},
            .self_ => self.pred = sql.EQ(self.user_column, .{ .int = self.user_id }),
            .dept_only => self.pred = sql.EQ(self.dept_column, .{ .int = self.self_dept_id }),
            .dept_and_child, .dept_custom => {
                if (self.dept_ids.len == 0) {
                    // The list names the departments the caller may see, so an
                    // empty one matches no department — the caller belongs to
                    // none and sees no rows. `.all` is already a first-class way
                    // to spell "no restriction", so an empty list has nothing to
                    // mean but this; leaving `pred` null would hand the query
                    // every row, the one reading this branch must not have.
                    // (An empty IN list is not portable SQL either: PostgreSQL
                    // and MySQL reject `dept_id IN ()` as a syntax error, and
                    // SQLite accepts it and matches nothing.)
                    std.log.warn(
                        "data scope: the dept list is empty, so the scope matches no department; denying it rather than reading as no restriction (use `.all` for an unrestricted scope)",
                        .{},
                    );
                    self.pred = deny_pred;
                    return;
                }
                if (self.dept_ids.len > max_dept_ids) {
                    // Over capacity. Truncating to the first `max_dept_ids`
                    // would silently widen the scope, and leaving `pred` null
                    // would widen it entirely — null is the value that means
                    // "no restriction", so the over-long list used to come out
                    // as an unrestricted query. Deny instead and say why, the
                    // same way `runtime.privacy.evalPolicy` handles a policy
                    // with more filters than it can hold.
                    std.log.warn(
                        "data scope: {d} dept ids exceed max_dept_ids ({d}); denying the scope rather than truncating or dropping it",
                        .{ self.dept_ids.len, max_dept_ids },
                    );
                    self.pred = deny_pred;
                    return;
                }
                for (self.dept_ids, 0..) |d, i| self.value_buf[i] = .{ .int = d };
                self.pred = sql.In(self.dept_column, self.value_buf[0..self.dept_ids.len]);
            },
        }
    }

    /// Ensure the predicate is materialized and return it (null = no
    /// restriction, i.e. `.all`). A `.dept_custom` / `.dept_and_child` list that
    /// cannot be built — empty, or longer than `max_dept_ids` — is never "no
    /// restriction": it materializes the always-false predicate instead.
    pub fn predicate(self: *DataScopeFilter) ?*const sql.Predicate {
        self.ensurePred();
        if (self.pred) |*p| return p;
        return null;
    }

    /// Filter-rule predicate used by the policy: returns the materialized
    /// predicate pointer, or null for `.all` (the only unscoped shape).
    ///
    /// A context that carries no filter at all (no `.extra`) denies rather
    /// than returning null: null means "this filter does not apply", and for a
    /// policy that promises a per-request scope it would read as "no
    /// restriction" — an unscoped query over every row.
    fn call(ctx: rtp.PrivacyContext) ?*const anyopaque {
        const extra = ctx.extra orelse {
            std.log.warn(
                "data scope: the privacy context carries no DataScopeFilter; denying the scope instead of leaving the query unscoped",
                .{},
            );
            return &deny_pred;
        };
        const self: *DataScopeFilter = @ptrCast(@alignCast(extra));
        if (self.predicate()) |p| return p;
        return null;
    }

    /// Build a `PrivacyContext` that carries this filter, ready for
    /// `client.withContext(ctx)`.
    pub fn context(self: *DataScopeFilter, opts: struct {
        user_id: ?i64 = null,
        tenant_id: ?i64 = null,
        role: ?[]const u8 = null,
    }) rtp.PrivacyContext {
        return .{
            .user_id = opts.user_id,
            .tenant_id = opts.tenant_id,
            .role = opts.role,
            .extra = @ptrCast(self),
        };
    }
};

/// Comptime rule: reads the request-scoped DataScopeFilter from
/// PrivacyContext.extra and yields its predicate to the query layer.
pub fn DataScopeRule() privacy.Rule {
    return privacy.Filter(struct {
        fn p(ctx: rtp.PrivacyContext) ?*const anyopaque {
            return DataScopeFilter.call(ctx);
        }
    }.p);
}

/// Attach to a schema via `.policy = data_scope.Policy`. Requires every
/// access to pass a context carrying `.extra = &DataScopeFilter`; missing
/// context is denied (`PrivacyDenied`) by the query layer.
pub const Policy = privacy.Policy{ .rules = &.{ privacy.Allow, DataScopeRule() } };

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

test "DataScopeFilter .all injects no predicate" {
    var f = DataScopeFilter.init("dept_id", "owner_id", .all, .{});
    try testing.expect(f.predicate() == null);
    const ctx = f.context(.{ .user_id = 1 });
    try testing.expect(DataScopeFilter.call(ctx) == null);
}

test "DataScopeFilter .self_ builds owner predicate" {
    var f = DataScopeFilter.init("dept_id", "owner_id", .self_, .{ .user_id = 7 });
    var b = sql.Builder.init(std.testing.allocator, .{ .name = "sqlite" });
    defer b.deinit();
    try f.predicate().?.appendTo(&b);
    const out = b.query();
    try testing.expectEqualStrings("\"owner_id\" = ?", out.sql);
    try testing.expectEqual(@as(i64, 7), out.args[0].int);
    const ctx = f.context(.{ .user_id = 7 });
    try testing.expect(DataScopeFilter.call(ctx) != null);
}

test "DataScopeFilter .dept_custom builds IN predicate" {
    const ids = [_]i64{ 3, 4, 9 };
    var f = DataScopeFilter.init("dept_id", "owner_id", .dept_custom, .{ .dept_ids = &ids });
    var b = sql.Builder.init(std.testing.allocator, .{ .name = "sqlite" });
    defer b.deinit();
    try f.predicate().?.appendTo(&b);
    const out = b.query();
    try testing.expectEqualStrings("\"dept_id\" IN (?, ?, ?)", out.sql);
    try testing.expectEqual(@as(i64, 3), out.args[0].int);
    try testing.expectEqual(@as(i64, 9), out.args[2].int);
}

test "DataScopeFilter .dept_only builds dept predicate" {
    var f = DataScopeFilter.init("dept_id", "owner_id", .dept_only, .{ .self_dept_id = 3 });
    var b = sql.Builder.init(std.testing.allocator, .{ .name = "sqlite" });
    defer b.deinit();
    try f.predicate().?.appendTo(&b);
    const out = b.query();
    try testing.expectEqualStrings("\"dept_id\" = ?", out.sql);
    try testing.expectEqual(@as(i64, 3), out.args[0].int);
}

test "DataScopePolicy filters queries at the SQL layer" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("../codegen/graph.zig").fromSchema;
    const migrate = @import("../sql/schema/migrate.zig");
    const sqlite_driver = @import("../sql/sqlite.zig");
    const deinitEntity = @import("../codegen/entity.zig").deinitEntity;

    const Doc = Schema("Doc", .{
        .fields = &.{
            field.Int("tenant_id"),
            field.Int("owner_id"),
            field.Int("dept_id"),
            field.String("title"),
        },
        .policy = Policy,
    });
    const info = comptime fromSchema(Doc);
    const TypeInfo = @import("../codegen/graph.zig").TypeInfo;
    const infos = &[_]TypeInfo{info};

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);

    const Client = @import("../codegen/client.zig").EntityClient(infos, info);
    const base = Client.init(allocator, driver.asDriver());

    // Seed via an .all-scope client (the schema policy requires a context on
    // every Create/Query path).
    var seed_scope = DataScopeFilter.init("dept_id", "owner_id", .all, .{});
    const seed_client = base.withContext(seed_scope.context(.{ .user_id = 0, .tenant_id = 1 }));

    // Seed: two docs for owner 1, one for owner 2 (same tenant).
    {
        var b = try seed_client.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", @as(i64, 1));
        _ = try b.setFieldValue("owner_id", @as(i64, 1));
        _ = try b.setFieldValue("dept_id", @as(i64, 3));
        _ = try b.setFieldValue("title", "mine-a");
        var row = try b.Save();
        deinitEntity(infos, info, &row, allocator);
    }
    {
        var b = try seed_client.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", @as(i64, 1));
        _ = try b.setFieldValue("owner_id", @as(i64, 1));
        _ = try b.setFieldValue("dept_id", @as(i64, 3));
        _ = try b.setFieldValue("title", "mine-b");
        var row = try b.Save();
        deinitEntity(infos, info, &row, allocator);
    }
    {
        var b = try seed_client.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", @as(i64, 1));
        _ = try b.setFieldValue("owner_id", @as(i64, 2));
        _ = try b.setFieldValue("dept_id", @as(i64, 9));
        _ = try b.setFieldValue("title", "other");
        var row = try b.Save();
        deinitEntity(infos, info, &row, allocator);
    }

    // .self_ scope -> only owner 1's rows.
    var self_scope = DataScopeFilter.init("dept_id", "owner_id", .self_, .{ .user_id = 1 });
    const self_client = base.withContext(self_scope.context(.{ .user_id = 1, .tenant_id = 1 }));
    var q1 = self_client.Query();
    defer q1.deinit();
    var rows1 = try q1.All();
    defer {
        for (rows1.items) |*e| deinitEntity(infos, info, e, allocator);
        rows1.deinit();
    }
    try testing.expectEqual(@as(usize, 2), rows1.items.len);

    // .dept_custom scope -> dept 9 only.
    const dept_ids = [_]i64{9};
    var dept_scope = DataScopeFilter.init("dept_id", "owner_id", .dept_custom, .{ .dept_ids = &dept_ids });
    const dept_client = base.withContext(dept_scope.context(.{ .user_id = 1, .tenant_id = 1 }));
    var q2 = dept_client.Query();
    defer q2.deinit();
    var rows2 = try q2.All();
    defer {
        for (rows2.items) |*e| deinitEntity(infos, info, e, allocator);
        rows2.deinit();
    }
    try testing.expectEqual(@as(usize, 1), rows2.items.len);
    try testing.expectEqualStrings("other", rows2.items[0].title);

    // .all scope -> everything visible.
    var all_scope = DataScopeFilter.init("dept_id", "owner_id", .all, .{});
    const all_client = base.withContext(all_scope.context(.{ .user_id = 1, .tenant_id = 1 }));
    var q3 = all_client.Query();
    defer q3.deinit();
    var rows3 = try q3.All();
    defer {
        for (rows3.items) |*e| deinitEntity(infos, info, e, allocator);
        rows3.deinit();
    }
    try testing.expectEqual(@as(usize, 3), rows3.items.len);

    // Missing context -> denied by checkPolicy.
    var q4 = base.Query();
    defer q4.deinit();
    try testing.expectError(error.PrivacyDenied, q4.All());
}

test "DataScopeFilter over-long dept list fails closed, not open" {
    // max_dept_ids is 32. A longer list left `pred` null, and null is the value
    // that means "no restriction" (`.all`) — so a request
    // carrying more departments than the inline buffer holds came out as an
    // unrestricted query over every row. Dropping the extra ids would be just
    // as wrong in the other direction, so the scope must deny.
    var many: [max_dept_ids + 1]i64 = undefined;
    for (&many, 0..) |*d, i| d.* = @intCast(i + 1);

    var wide = DataScopeFilter.init("dept_id", "owner_id", .dept_custom, .{ .dept_ids = &many });
    var b = sql.Builder.init(std.testing.allocator, .{ .name = "sqlite" });
    defer b.deinit();
    const pred = wide.predicate() orelse return error.ScopeDropped;
    try pred.appendTo(&b);
    const out = b.query();
    try testing.expectEqualStrings("(1 = 0)", out.sql);
    try testing.expectEqual(@as(usize, 0), out.args.len);

    // The boundary is inclusive: exactly max_dept_ids still builds the IN list.
    var fits: [max_dept_ids]i64 = undefined;
    for (&fits, 0..) |*d, i| d.* = @intCast(i + 1);
    var ok = DataScopeFilter.init("dept_id", "owner_id", .dept_custom, .{ .dept_ids = &fits });
    var b2 = sql.Builder.init(std.testing.allocator, .{ .name = "sqlite" });
    defer b2.deinit();
    try ok.predicate().?.appendTo(&b2);
    const out2 = b2.query();
    try testing.expect(std.mem.startsWith(u8, out2.sql, "\"dept_id\" IN ("));
    try testing.expectEqual(@as(usize, max_dept_ids), out2.args.len);
}

test "DataScopeFilter empty dept list fails closed, not open" {
    // `.all` is a first-class way to say "no restriction", so an empty dept
    // list has no second meaning to carry: it says the caller sits in no
    // department, i.e. sees no rows. It used to leave `pred` null — the value
    // that spells "no restriction" — and so ran the query over every row.
    inline for (.{ .dept_custom, .dept_and_child }) |scope| {
        var f = DataScopeFilter.init("dept_id", "owner_id", scope, .{ .dept_ids = &.{} });
        var b = sql.Builder.init(std.testing.allocator, .{ .name = "sqlite" });
        defer b.deinit();
        const pred = f.predicate() orelse return error.ScopeDropped;
        try pred.appendTo(&b);
        const out = b.query();
        try testing.expectEqualStrings("(1 = 0)", out.sql);
        try testing.expectEqual(@as(usize, 0), out.args.len);

        // The policy layer gets the deny too: a filter rule can only restrict
        // by handing a predicate over, so the empty list must not answer null.
        const ctx = f.context(.{ .user_id = 7 });
        try testing.expect(DataScopeFilter.call(ctx) != null);
    }
}

test "DataScopeFilter empty-list deny leaves .all and non-empty lists alone" {
    // The contrast: `.all` stays unrestricted — it is how a caller asks for
    // that, and its `dept_ids` is empty by default — and a non-empty list of
    // either dept scope still builds its IN predicate.
    var all = DataScopeFilter.init("dept_id", "owner_id", .all, .{});
    try testing.expect(all.predicate() == null);
    try testing.expect(DataScopeFilter.call(all.context(.{ .user_id = 1 })) == null);

    const ids = [_]i64{ 3, 4 };
    inline for (.{ .dept_custom, .dept_and_child }) |scope| {
        var f = DataScopeFilter.init("dept_id", "owner_id", scope, .{ .dept_ids = &ids });
        var b = sql.Builder.init(std.testing.allocator, .{ .name = "sqlite" });
        defer b.deinit();
        try f.predicate().?.appendTo(&b);
        const out = b.query();
        try testing.expectEqualStrings("\"dept_id\" IN (?, ?)", out.sql);
        try testing.expectEqual(@as(i64, 3), out.args[0].int);
        try testing.expectEqual(@as(i64, 4), out.args[1].int);
    }
}

test "DataScopePolicy applies the over-long dept list as a deny, not as no filter" {
    // The end-to-end shape of the above: through the client, an over-long
    // `.dept_custom` scope must return no rows rather than every row.
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("../codegen/graph.zig").fromSchema;
    const TypeInfo = @import("../codegen/graph.zig").TypeInfo;
    const migrate = @import("../sql/schema/migrate.zig");
    const sqlite_driver = @import("../sql/sqlite.zig");
    const deinitEntity = @import("../codegen/entity.zig").deinitEntity;

    const WideDoc = Schema("WideDoc", .{
        .table_name = "wide_doc",
        .fields = &.{
            field.Int("tenant_id"),
            field.Int("owner_id"),
            field.Int("dept_id"),
            field.String("title"),
        },
        .policy = Policy,
    });
    const info = comptime fromSchema(WideDoc);
    const infos = &[_]TypeInfo{info};

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);

    const Client = @import("../codegen/client.zig").EntityClient(infos, info);
    const base = Client.init(allocator, driver.asDriver());

    var seed_scope = DataScopeFilter.init("dept_id", "owner_id", .all, .{});
    const seed_client = base.withContext(seed_scope.context(.{ .tenant_id = 1 }));
    {
        var b = try seed_client.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", @as(i64, 1));
        _ = try b.setFieldValue("owner_id", @as(i64, 1));
        // Dept 3 is inside the over-long list below, so a truncated IN list
        // would still have matched it — only a deny excludes it.
        _ = try b.setFieldValue("dept_id", @as(i64, 3));
        _ = try b.setFieldValue("title", "seed");
        var row = try b.Save();
        deinitEntity(infos, info, &row, allocator);
    }

    var many: [max_dept_ids + 1]i64 = undefined;
    for (&many, 0..) |*d, i| d.* = @intCast(i + 1);
    var wide = DataScopeFilter.init("dept_id", "owner_id", .dept_custom, .{ .dept_ids = &many });
    const wide_client = base.withContext(wide.context(.{ .tenant_id = 1 }));
    var q = wide_client.Query();
    defer q.deinit();
    var rows = try q.All();
    defer {
        for (rows.items) |*e| deinitEntity(infos, info, e, allocator);
        rows.deinit();
    }
    try testing.expectEqual(@as(usize, 0), rows.items.len);
}

test "DataScopePolicy applies an empty dept list as a deny, not as no filter" {
    // The end-to-end shape of the empty-list case: through the client, a
    // `.dept_custom` scope with no departments must return no rows rather than
    // every row — a tenant that has not assigned the caller a department must
    // not read the whole table.
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("../codegen/graph.zig").fromSchema;
    const TypeInfo = @import("../codegen/graph.zig").TypeInfo;
    const migrate = @import("../sql/schema/migrate.zig");
    const sqlite_driver = @import("../sql/sqlite.zig");
    const deinitEntity = @import("../codegen/entity.zig").deinitEntity;

    const EmptyDoc = Schema("EmptyDoc", .{
        .table_name = "empty_doc",
        .fields = &.{
            field.Int("tenant_id"),
            field.Int("owner_id"),
            field.Int("dept_id"),
            field.String("title"),
        },
        .policy = Policy,
    });
    const info = comptime fromSchema(EmptyDoc);
    const infos = &[_]TypeInfo{info};

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);

    const Client = @import("../codegen/client.zig").EntityClient(infos, info);
    const base = Client.init(allocator, driver.asDriver());

    var seed_scope = DataScopeFilter.init("dept_id", "owner_id", .all, .{});
    const seed_client = base.withContext(seed_scope.context(.{ .tenant_id = 1 }));
    {
        var b = try seed_client.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", @as(i64, 1));
        _ = try b.setFieldValue("owner_id", @as(i64, 1));
        _ = try b.setFieldValue("dept_id", @as(i64, 3));
        _ = try b.setFieldValue("title", "seed");
        var row = try b.Save();
        deinitEntity(infos, info, &row, allocator);
    }

    var empty = DataScopeFilter.init("dept_id", "owner_id", .dept_custom, .{ .dept_ids = &.{} });
    const empty_client = base.withContext(empty.context(.{ .tenant_id = 1 }));
    var q = empty_client.Query();
    defer q.deinit();
    var rows = try q.All();
    defer {
        for (rows.items) |*e| deinitEntity(infos, info, e, allocator);
        rows.deinit();
    }
    try testing.expectEqual(@as(usize, 0), rows.items.len);
}

test "DataScopePolicy denies a context that carries no filter" {
    // A context built without `.extra = &filter` (`withContext(.{ … })`) is a
    // caller that set up the tenant/user but forgot the scope. The rule used to
    // answer "the filter does not apply" — null — and null is how a filter rule
    // says "nothing to add", so the query ran with no scope predicate at all
    // and returned every row. A schema carrying this policy is a promise that a
    // scope is always present, so the missing filter has to deny.
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("../codegen/graph.zig").fromSchema;
    const TypeInfo = @import("../codegen/graph.zig").TypeInfo;
    const migrate = @import("../sql/schema/migrate.zig");
    const sqlite_driver = @import("../sql/sqlite.zig");
    const deinitEntity = @import("../codegen/entity.zig").deinitEntity;

    const ScopedDoc = Schema("ScopedDoc", .{
        .table_name = "scoped_doc",
        .fields = &.{
            field.Int("tenant_id"),
            field.Int("owner_id"),
            field.Int("dept_id"),
            field.String("title"),
        },
        .policy = Policy,
    });
    const info = comptime fromSchema(ScopedDoc);
    const infos = &[_]TypeInfo{info};

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);

    const Client = @import("../codegen/client.zig").EntityClient(infos, info);
    const base = Client.init(allocator, driver.asDriver());

    var seed_scope = DataScopeFilter.init("dept_id", "owner_id", .all, .{});
    const seed_client = base.withContext(seed_scope.context(.{ .tenant_id = 1 }));
    {
        var b = try seed_client.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", @as(i64, 1));
        _ = try b.setFieldValue("owner_id", @as(i64, 1));
        _ = try b.setFieldValue("dept_id", @as(i64, 3));
        _ = try b.setFieldValue("title", "seed");
        var row = try b.Save();
        deinitEntity(infos, info, &row, allocator);
    }

    // The seeded row belongs to owner 1 / dept 3 in tenant 1. A context that
    // names that tenant and user but carries no filter must not see it (nor
    // anything else).
    const bare = base.withContext(.{ .user_id = 1, .tenant_id = 1 });
    var q = bare.Query();
    defer q.deinit();
    var rows = try q.All();
    defer {
        for (rows.items) |*e| deinitEntity(infos, info, e, allocator);
        rows.deinit();
    }
    try testing.expectEqual(@as(usize, 0), rows.items.len);
}
