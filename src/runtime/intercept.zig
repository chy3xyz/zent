//! Runtime query interceptors (ent-style `Intercept`).
//!
//! An interceptor observes and transparently rewrites a query before it is
//! executed: it receives a `QueryView` describing the operation and may add
//! equality predicates via `view.whereEq(field, value)`. Errors abort the
//! operation (first error wins). Interceptors complement privacy rules:
//! privacy decides allow/deny plus static row filters, interceptors rewrite
//! or observe the query at runtime (multi-tenant injection, soft-scope
//! enforcement, query logging/counters, ...).
//!
//! Create is intentionally not intercepted — hooks own the create path.

const std = @import("std");

const hook = @import("hook.zig");
const sql = @import("../sql/builder.zig");

/// A view of the query being intercepted. Passed to every interceptor in
/// the chain; mutations go through `whereEq`.
pub const QueryView = struct {
    /// Operation being executed (create is never intercepted).
    op: hook.Op,
    /// Physical table name the operation targets.
    table_name: []const u8,

    /// Opaque destination for added predicates (the calling builder).
    sink: *anyopaque,
    /// Builder-provided callback backing `whereEq`.
    add_eq_fn: *const fn (sink: *anyopaque, field_name: []const u8, value: sql.Value) anyerror!void,

    /// Add an equality predicate `field_name = value` to the intercepted
    /// query. Returns `error.UnknownField` when the entity has no such
    /// field; other errors come from the builder (e.g. OutOfMemory).
    pub fn whereEq(self: *QueryView, field_name: []const u8, value: sql.Value) !void {
        try self.add_eq_fn(self.sink, field_name, value);
    }
};

/// A query interceptor. `ctx` carries user state (tenant id, counters, ...);
/// `intercept` inspects the view and may rewrite the query via `whereEq`.
pub const Interceptor = struct {
    ctx: ?*anyopaque = null,
    intercept: *const fn (ctx: ?*anyopaque, view: *QueryView) anyerror!void,
};

/// An ordered chain of interceptors. Executed in registration order;
/// the first error aborts the chain and propagates to the caller.
pub const InterceptorChain = struct {
    allocator: std.mem.Allocator,
    interceptors: std.ArrayList(Interceptor),

    pub fn init(allocator: std.mem.Allocator) InterceptorChain {
        return .{
            .allocator = allocator,
            .interceptors = std.ArrayList(Interceptor).empty,
        };
    }

    pub fn deinit(self: *InterceptorChain) void {
        self.interceptors.deinit(self.allocator);
    }

    /// Append an interceptor to the chain.
    pub fn use(self: *InterceptorChain, i: Interceptor) !void {
        try self.interceptors.append(self.allocator, i);
    }

    /// Run every interceptor against the view, in registration order.
    /// The first error stops the chain and is returned to the caller.
    pub fn run(self: *const InterceptorChain, view: *QueryView) !void {
        for (self.interceptors.items) |i| {
            try i.intercept(i.ctx, view);
        }
    }
};

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const TestSink = struct {
    fields: std.ArrayList([]const u8),
    values: std.ArrayList(sql.Value),

    fn init() TestSink {
        return .{ .fields = .empty, .values = .empty };
    }

    fn deinit(self: *TestSink, allocator: std.mem.Allocator) void {
        self.fields.deinit(allocator);
        self.values.deinit(allocator);
    }

    fn addEq(sink: *anyopaque, field_name: []const u8, value: sql.Value) anyerror!void {
        const self: *TestSink = @ptrCast(@alignCast(sink));
        // Field validation lives in the generated builders; the test sink
        // accepts anything except a sentinel name to exercise the error path.
        if (std.mem.eql(u8, field_name, "__unknown__")) return error.UnknownField;
        try self.fields.append(std.testing.allocator, field_name);
        try self.values.append(std.testing.allocator, value);
    }

    fn view(self: *TestSink, op: hook.Op) QueryView {
        return .{
            .op = op,
            .table_name = "users",
            .sink = self,
            .add_eq_fn = addEq,
        };
    }
};

test "InterceptorChain runs interceptors in registration order" {
    const allocator = std.testing.allocator;
    var chain = InterceptorChain.init(allocator);
    defer chain.deinit();

    const Order = struct {
        var log: [4]u8 = undefined;
        var len: usize = 0;
        fn push(c: u8) void {
            log[len] = c;
            len += 1;
        }
        fn reset() void {
            len = 0;
        }
    };
    Order.reset();

    const a = struct {
        fn f(_: ?*anyopaque, _: *QueryView) anyerror!void {
            Order.push('a');
        }
    }.f;
    const b = struct {
        fn f(_: ?*anyopaque, _: *QueryView) anyerror!void {
            Order.push('b');
        }
    }.f;

    try chain.use(.{ .intercept = a });
    try chain.use(.{ .intercept = b });

    var sink = TestSink.init();
    defer sink.deinit(allocator);
    var v = sink.view(.query);
    try chain.run(&v);

    try std.testing.expectEqual(@as(usize, 2), Order.len);
    try std.testing.expectEqual(@as(u8, 'a'), Order.log[0]);
    try std.testing.expectEqual(@as(u8, 'b'), Order.log[1]);
}

test "InterceptorChain propagates the first error and stops" {
    const allocator = std.testing.allocator;
    var chain = InterceptorChain.init(allocator);
    defer chain.deinit();

    const State = struct {
        var third_ran: bool = false;
    };
    State.third_ran = false;

    const ok = struct {
        fn f(_: ?*anyopaque, _: *QueryView) anyerror!void {}
    }.f;
    const failing = struct {
        fn f(_: ?*anyopaque, _: *QueryView) anyerror!void {
            return error.Forbidden;
        }
    }.f;
    const third = struct {
        fn f(_: ?*anyopaque, _: *QueryView) anyerror!void {
            State.third_ran = true;
        }
    }.f;

    try chain.use(.{ .intercept = ok });
    try chain.use(.{ .intercept = failing });
    try chain.use(.{ .intercept = third });

    var sink = TestSink.init();
    defer sink.deinit(allocator);
    var v = sink.view(.delete);
    try std.testing.expectError(error.Forbidden, chain.run(&v));
    try std.testing.expect(!State.third_ran);
}

test "QueryView whereEq reaches the sink through the chain" {
    const allocator = std.testing.allocator;
    var chain = InterceptorChain.init(allocator);
    defer chain.deinit();

    var tenant: i64 = 7;
    const inject = struct {
        fn f(ctx: ?*anyopaque, v: *QueryView) anyerror!void {
            const id: *i64 = @ptrCast(@alignCast(ctx.?));
            try v.whereEq("tenant_id", .{ .int = id.* });
        }
    }.f;
    try chain.use(.{ .ctx = &tenant, .intercept = inject });

    var sink = TestSink.init();
    defer sink.deinit(allocator);
    var v = sink.view(.query);
    try chain.run(&v);

    try std.testing.expectEqual(@as(usize, 1), sink.fields.items.len);
    try std.testing.expectEqualStrings("tenant_id", sink.fields.items[0]);
    try std.testing.expectEqual(@as(i64, 7), sink.values.items[0].int);
    try std.testing.expectEqual(hook.Op.query, v.op);
    try std.testing.expectEqualStrings("users", v.table_name);
}

test "QueryView whereEq surfaces sink errors (unknown field)" {
    const allocator = std.testing.allocator;
    var chain = InterceptorChain.init(allocator);
    defer chain.deinit();

    const bad = struct {
        fn f(_: ?*anyopaque, v: *QueryView) anyerror!void {
            try v.whereEq("__unknown__", .{ .int = 1 });
        }
    }.f;
    try chain.use(.{ .intercept = bad });

    var sink = TestSink.init();
    defer sink.deinit(allocator);
    var v = sink.view(.update);
    try std.testing.expectError(error.UnknownField, chain.run(&v));
    try std.testing.expectEqual(@as(usize, 0), sink.fields.items.len);
}
