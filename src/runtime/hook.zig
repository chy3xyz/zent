const std = @import("std");

const builder = @import("../sql/builder.zig");
const Value = builder.Value;

const privacy = @import("privacy.zig");
const PrivacyContext = privacy.PrivacyContext;

/// Operation type for hooks.
pub const Op = enum {
    create,
    update,
    delete,
    query,
};

/// Error set returned by before-hook callbacks.
pub const HookError = error{
    ValidationFailed,
    Forbidden,
    HookFailed,
};

/// Context passed to every hook callback.
pub const HookContext = struct {
    op: Op,
    table_name: []const u8,

    /// Read-only entity pointer. Null for create-before.
    entity: ?*anyopaque = null,

    /// New field values for create/update. Null for delete/query.
    mutated: ?[]const Value = null,

    /// Inherited from the builder.
    privacy: PrivacyContext = .{},

    /// Optional user-defined context data.
    user_data: ?*anyopaque = null,

    /// Optional record ID (if available).
    record_id: ?i64 = null,
};

/// A hook that runs before or after a mutation.
pub const Hook = struct {
    op: Op,

    /// Before-hook callback. Must return HookError!void.
    before: ?*const fn (ctx: *HookContext) HookError!void = null,

    /// After-hook callback. Must return HookError!void.
    after: ?*const fn (ctx: *HookContext) HookError!void = null,

    /// Create a hook with a before callback.
    pub fn initBefore(comptime op: Op, callback: *const fn (ctx: *HookContext) HookError!void) Hook {
        return .{
            .op = op,
            .before = callback,
        };
    }

    /// Create a hook with an after callback.
    pub fn initAfter(comptime op: Op, callback: *const fn (ctx: *HookContext) HookError!void) Hook {
        return .{
            .op = op,
            .after = callback,
        };
    }
};

/// A chain of hooks executed in insertion order.
pub const HookChain = struct {
    allocator: std.mem.Allocator,
    hooks: std.ArrayList(Hook),

    pub fn init(allocator: std.mem.Allocator) HookChain {
        return .{
            .allocator = allocator,
            .hooks = std.ArrayList(Hook).init(allocator),
        };
    }

    pub fn deinit(self: *HookChain) void {
        self.hooks.deinit();
    }

    /// Add a hook to the chain.
    pub fn add(self: *HookChain, hook: Hook) !void {
        try self.hooks.append(hook);
    }

    /// Execute all before-hooks for the given context. Propagates the first error.
    pub fn executeBefore(self: *const HookChain, ctx: *HookContext) HookError!void {
        for (self.hooks.items) |hook| {
            if (hook.op == ctx.op and hook.before) |before| {
                try before(ctx);
            }
        }
    }

    /// Execute all after-hooks for the given context. Errors are logged but not propagated.
    pub fn executeAfter(self: *const HookChain, ctx: *HookContext) void {
        for (self.hooks.items) |hook| {
            if (hook.op == ctx.op and hook.after) |after| {
                after(ctx) catch |err| {
                    std.log.err(
                        "after-hook failed on table '{s}' ({s}): {s}",
                        .{ ctx.table_name, @tagName(ctx.op), @errorName(err) },
                    );
                };
            }
        }
    }
};

// ------------------------------------------------------------------
// Global hook registry
// ------------------------------------------------------------------

var global_registry: ?*HookChain = null;
var global_mutex: std.Thread.Mutex = .{};

/// Register a global hook chain that fires for every table/operation.
pub fn registerGlobal(chain: *HookChain) void {
    global_mutex.lock();
    defer global_mutex.unlock();
    global_registry = chain;
}

/// Execute all global before-hooks. Called by codegen before per-table hooks.
pub fn globalBefore(ctx: *HookContext) HookError!void {
    global_mutex.lock();
    const chain = global_registry;
    global_mutex.unlock();

    if (chain) |c| {
        try c.executeBefore(ctx);
    }
}

/// Execute all global after-hooks. Called by codegen after per-table hooks.
pub fn globalAfter(ctx: *HookContext) void {
    global_mutex.lock();
    const chain = global_registry;
    global_mutex.unlock();

    if (chain) |c| {
        c.executeAfter(ctx);
    }
}

// ------------------------------------------------------------------
// Built-in hooks
// ------------------------------------------------------------------

/// A logging hook that logs operation start and end via std.debug.print.
/// Each callback matches the `*const fn (ctx: *HookContext) HookError!void` signature.
pub const LoggingHook = struct {
    pub fn beforeCreate(ctx: *HookContext) HookError!void {
        std.debug.print("[Hook] Before create on {s}\n", .{ctx.table_name});
    }

    pub fn afterCreate(ctx: *HookContext) HookError!void {
        std.debug.print("[Hook] After create on {s}\n", .{ctx.table_name});
    }

    pub fn beforeUpdate(ctx: *HookContext) HookError!void {
        std.debug.print("[Hook] Before update on {s}\n", .{ctx.table_name});
    }

    pub fn afterUpdate(ctx: *HookContext) HookError!void {
        std.debug.print("[Hook] After update on {s}\n", .{ctx.table_name});
    }

    pub fn beforeDelete(ctx: *HookContext) HookError!void {
        std.debug.print("[Hook] Before delete on {s}\n", .{ctx.table_name});
    }

    pub fn afterDelete(ctx: *HookContext) HookError!void {
        std.debug.print("[Hook] After delete on {s}\n", .{ctx.table_name});
    }

    pub fn beforeQuery(ctx: *HookContext) HookError!void {
        std.debug.print("[Hook] Before query on {s}\n", .{ctx.table_name});
    }

    pub fn afterQuery(ctx: *HookContext) HookError!void {
        std.debug.print("[Hook] After query on {s}\n", .{ctx.table_name});
    }
};

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Hook basic functionality" {
    const hook = Hook{ .op = .create };
    try std.testing.expectEqual(Op.create, hook.op);
}

test "Hook initBefore and initAfter" {
    const before_fn = struct {
        fn f(ctx: *HookContext) HookError!void {
            _ = ctx;
        }
    }.f;

    const after_fn = struct {
        fn f(ctx: *HookContext) HookError!void {
            _ = ctx;
        }
    }.f;

    const hook_before = Hook.initBefore(.create, before_fn);
    const hook_after = Hook.initAfter(.create, after_fn);

    try std.testing.expect(hook_before.before != null);
    try std.testing.expect(hook_after.after != null);
}

test "HookChain basic operations" {
    const allocator = std.testing.allocator;
    var chain = HookChain.init(allocator);
    defer chain.deinit();

    const hook = Hook{ .op = .create };
    try chain.add(hook);

    try std.testing.expectEqual(@as(usize, 1), chain.hooks.items.len);
}

test "HookChain executeBefore with HookContext" {
    const allocator = std.testing.allocator;
    var chain = HookChain.init(allocator);
    defer chain.deinit();

    const before_fn = struct {
        var called: bool = false;
        fn f(ctx: *HookContext) HookError!void {
            _ = ctx;
            called = true;
        }
    }.f;

    const hook = Hook{ .op = .create, .before = before_fn };
    try chain.add(hook);

    var ctx = HookContext{ .op = .create, .table_name = "users" };
    try chain.executeBefore(&ctx);
}

test "HookChain executeAfter catches errors" {
    const allocator = std.testing.allocator;
    var chain = HookChain.init(allocator);
    defer chain.deinit();

    const after_fn = struct {
        fn f(ctx: *HookContext) HookError!void {
            _ = ctx;
            return error.HookFailed;
        }
    }.f;

    const hook = Hook{ .op = .create, .after = after_fn };
    try chain.add(hook);

    var ctx = HookContext{ .op = .create, .table_name = "users" };
    // executeAfter must not propagate the error.
    chain.executeAfter(&ctx);
}

test "global hook registry" {
    const allocator = std.testing.allocator;
    var chain = HookChain.init(allocator);
    defer chain.deinit();

    const before_fn = struct {
        var called: bool = false;
        fn f(ctx: *HookContext) HookError!void {
            _ = ctx;
            called = true;
        }
    }.f;

    const hook = Hook{ .op = .create, .before = before_fn };
    try chain.add(hook);

    registerGlobal(&chain);

    var ctx = HookContext{ .op = .create, .table_name = "users" };
    try globalBefore(&ctx);
    globalAfter(&ctx);
}

test "LoggingHook callbacks match new signature" {
    // Verify the callbacks compile and run without error.
    {
        var ctx = HookContext{ .op = .create, .table_name = "test" };
        try LoggingHook.beforeCreate(&ctx);
        try LoggingHook.afterCreate(&ctx);
    }
    {
        var ctx = HookContext{ .op = .update, .table_name = "test" };
        try LoggingHook.beforeUpdate(&ctx);
        try LoggingHook.afterUpdate(&ctx);
    }
    {
        var ctx = HookContext{ .op = .delete, .table_name = "test" };
        try LoggingHook.beforeDelete(&ctx);
        try LoggingHook.afterDelete(&ctx);
    }
    {
        var ctx = HookContext{ .op = .query, .table_name = "test" };
        try LoggingHook.beforeQuery(&ctx);
        try LoggingHook.afterQuery(&ctx);
    }
}
