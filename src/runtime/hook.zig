const std = @import("std");

/// Operation type for hooks.
pub const Op = enum {
    create,
    update,
    delete,
    query,
};

/// Mutation context passed to hooks.
pub const Context = struct {
    op: Op,
    table_name: []const u8,
    allocator: std.mem.Allocator,

    /// Optional user-defined context data.
    user_data: ?*anyopaque = null,

    /// Optional record ID (if available).
    record_id: ?i64 = null,

    /// Optional field information (for field-level hooks).
    field_name: ?[]const u8 = null,
};

/// A simple hook that can run before or after a mutation.
/// Backward compatible API.
pub const Hook = struct {
    op: Op,
    before: ?*const fn (op: Op, table_name: []const u8) void = null,
    after: ?*const fn (op: Op, table_name: []const u8) void = null,

    /// Create a hook that runs before an operation (backward compatible).
    pub fn initBefore(op: Op, callback: *const fn (op: Op, table_name: []const u8) void) Hook {
        return .{
            .op = op,
            .before = callback,
        };
    }

    /// Create a hook that runs after an operation (backward compatible).
    pub fn initAfter(op: Op, callback: *const fn (op: Op, table_name: []const u8) void) Hook {
        return .{
            .op = op,
            .after = callback,
        };
    }
};

/// A chain of hooks that can be executed in sequence.
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

    /// Execute all before hooks for a specific operation (backward compatible).
    pub fn executeBefore(self: *const HookChain, op: Op, table_name: []const u8) void {
        for (self.hooks.items) |hook| {
            if (hook.op == op and hook.before) |before| {
                before(op, table_name);
            }
        }
    }

    /// Execute all after hooks for a specific operation (backward compatible).
    pub fn executeAfter(self: *const HookChain, op: Op, table_name: []const u8) void {
        for (self.hooks.items) |hook| {
            if (hook.op == op and hook.after) |after| {
                after(op, table_name);
            }
        }
    }
};

// ------------------------------------------------------------------
// Built-in hooks
// ------------------------------------------------------------------

/// A simple logging hook that logs operation starts and ends.
pub const LoggingHook = struct {
    pub fn beforeCreate(op: Op, table_name: []const u8) void {
        _ = op;
        std.debug.print("[Hook] Before create on {s}\n", .{table_name});
    }

    pub fn afterCreate(op: Op, table_name: []const u8) void {
        _ = op;
        std.debug.print("[Hook] After create on {s}\n", .{table_name});
    }

    pub fn beforeUpdate(op: Op, table_name: []const u8) void {
        _ = op;
        std.debug.print("[Hook] Before update on {s}\n", .{table_name});
    }

    pub fn afterUpdate(op: Op, table_name: []const u8) void {
        _ = op;
        std.debug.print("[Hook] After update on {s}\n", .{table_name});
    }

    pub fn beforeDelete(op: Op, table_name: []const u8) void {
        _ = op;
        std.debug.print("[Hook] Before delete on {s}\n", .{table_name});
    }

    pub fn afterDelete(op: Op, table_name: []const u8) void {
        _ = op;
        std.debug.print("[Hook] After delete on {s}\n", .{table_name});
    }

    pub fn beforeQuery(op: Op, table_name: []const u8) void {
        _ = op;
        std.debug.print("[Hook] Before query on {s}\n", .{table_name});
    }

    pub fn afterQuery(op: Op, table_name: []const u8) void {
        _ = op;
        std.debug.print("[Hook] After query on {s}\n", .{table_name});
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
        fn f(op: Op, table: []const u8) void {
            _ = op;
            _ = table;
        }
    }.f;

    const after_fn = struct {
        fn f(op: Op, table: []const u8) void {
            _ = op;
            _ = table;
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
