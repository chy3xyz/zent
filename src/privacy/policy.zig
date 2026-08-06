const std = @import("std");
const rtp = @import("../runtime/privacy.zig");

// Re-export types from runtime/privacy.zig (canonical definitions).
pub const PrivacyContext = rtp.PrivacyContext;
pub const Decision = rtp.Decision;
pub const DecisionSet = rtp.DecisionSet;
pub const FilterRule = rtp.FilterRule;
pub const Rule = rtp.Rule;
pub const Op = rtp.Op;

// Convenience rule constants.
pub const Allow = Rule.allow;
pub const Deny = Rule.deny;
pub const Skip = Rule.skip;

/// Create a filter rule from a comptime predicate function.
/// The predicate receives a PrivacyContext and returns an optional
/// opaque filter pointer (null = filter not applicable).
pub fn Filter(comptime predicate: anytype) Rule {
    return .{ .filter = .{ .predicate = struct {
        fn call(ctx: PrivacyContext) ?*const anyopaque {
            return predicate(ctx);
        }
    }.call } };
}

/// Privacy policy that can be attached to a schema.
/// Carries an ordered list of rules evaluated with AND semantics
/// via runtime.privacy.evalPolicy.
pub const Policy = struct {
    rules: []const Rule,

    pub fn eval(self: Policy, ctx: PrivacyContext) DecisionSet {
        return rtp.evalPolicy(ctx, self.rules);
    }
};

// ------------------------------------------------------------------
// Built-in policies
// ------------------------------------------------------------------

/// Always allow — no restrictions.
pub const AlwaysAllow = Policy{ .rules = &.{Allow} };

/// Always deny — blocks all access.
pub const AlwaysDeny = Policy{ .rules = &.{Deny} };

/// Deny only the matching operation; other operations pass through.
/// The codegen layer sets `PrivacyContext.op` per operation (query/create/
/// update/delete), so a schema with `.policy = OnCreate` blocks creates but
/// still allows reads/writes/deletes. Combine with other rules as needed,
/// e.g. `Policy{ .rules = &.{ OnCreate.rules[0], OnQuery.rules[0] } }`.
fn on(comptime op: Op) Rule {
    return .{ .on_op = .{ .op = op, .decision = .deny } };
}
pub const OnCreate = Policy{ .rules = &.{on(.create)} };
pub const OnUpdate = Policy{ .rules = &.{on(.update)} };
pub const OnDelete = Policy{ .rules = &.{on(.delete)} };
pub const OnQuery = Policy{ .rules = &.{on(.query)} };

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Policy: AlwaysAllow" {
    const ctx = PrivacyContext{};
    const result = AlwaysAllow.eval(ctx);
    try std.testing.expectEqual(Decision.allow, result.decision);
    try std.testing.expectEqual(@as(usize, 0), result.filter_count);
}

test "Policy: AlwaysDeny" {
    const ctx = PrivacyContext{};
    const result = AlwaysDeny.eval(ctx);
    try std.testing.expectEqual(Decision.deny, result.decision);
}

test "Policy: On* policies deny only their own operation" {
    // Matching op -> deny; other ops -> allow (rule skipped).
    try std.testing.expectEqual(Decision.deny, OnCreate.eval(.{ .op = .create }).decision);
    try std.testing.expectEqual(Decision.allow, OnCreate.eval(.{ .op = .query }).decision);
    try std.testing.expectEqual(Decision.deny, OnUpdate.eval(.{ .op = .update }).decision);
    try std.testing.expectEqual(Decision.allow, OnUpdate.eval(.{ .op = .create }).decision);
    try std.testing.expectEqual(Decision.deny, OnDelete.eval(.{ .op = .delete }).decision);
    try std.testing.expectEqual(Decision.allow, OnDelete.eval(.{ .op = .update }).decision);
    try std.testing.expectEqual(Decision.deny, OnQuery.eval(.{ .op = .query }).decision);
    try std.testing.expectEqual(Decision.allow, OnQuery.eval(.{ .op = .delete }).decision);
}

test "Filter factory creates valid rule" {
    const ctx = PrivacyContext{ .user_id = 42 };
    const rule = Filter(struct {
        fn p(c: PrivacyContext) ?*const anyopaque {
            if (c.user_id) |_| {
                return @ptrCast(&struct { uid: i64 = 1 });
            }
            return null;
        }
    }.p);
    const policy = Policy{ .rules = &.{ Allow, rule } };
    const result = policy.eval(ctx);
    try std.testing.expectEqual(Decision.allow, result.decision);
    try std.testing.expectEqual(@as(usize, 1), result.filter_count);
}

test "Policy with multiple rules: deny short-circuits" {
    const ctx = PrivacyContext{};
    const policy = Policy{ .rules = &.{ Allow, Deny, Allow } };
    const result = policy.eval(ctx);
    try std.testing.expectEqual(Decision.deny, result.decision);
}

test "Policy with empty rules defaults to allow" {
    const ctx = PrivacyContext{};
    const policy = Policy{ .rules = &.{} };
    const result = policy.eval(ctx);
    try std.testing.expectEqual(Decision.allow, result.decision);
}
