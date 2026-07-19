const std = @import("std");
const rtp = @import("../runtime/privacy.zig");

// Re-export types from runtime/privacy.zig (canonical definitions).
pub const PrivacyContext = rtp.PrivacyContext;
pub const Decision = rtp.Decision;
pub const DecisionSet = rtp.DecisionSet;
pub const FilterRule = rtp.FilterRule;
pub const Rule = rtp.Rule;

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

/// Deny all — used as placeholders for operation-specific policies
/// that will be wired by Task 3 (codegen layer).
pub const OnCreate = Policy{ .rules = &.{Deny} };
pub const OnUpdate = Policy{ .rules = &.{Deny} };
pub const OnDelete = Policy{ .rules = &.{Deny} };
pub const OnQuery = Policy{ .rules = &.{Deny} };

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Policy: AlwaysAllow" {
    const ctx = PrivacyContext{};
    const result = AlwaysAllow.eval(ctx);
    try std.testing.expectEqual(Decision.allow, result.decision);
    try std.testing.expectEqual(@as(usize, 0), result.filters.len);
}

test "Policy: AlwaysDeny" {
    const ctx = PrivacyContext{};
    const result = AlwaysDeny.eval(ctx);
    try std.testing.expectEqual(Decision.deny, result.decision);
}

test "Policy: OnCreate/OnUpdate/OnDelete/OnQuery all deny" {
    const ctx = PrivacyContext{};
    try std.testing.expectEqual(Decision.deny, OnCreate.eval(ctx).decision);
    try std.testing.expectEqual(Decision.deny, OnUpdate.eval(ctx).decision);
    try std.testing.expectEqual(Decision.deny, OnDelete.eval(ctx).decision);
    try std.testing.expectEqual(Decision.deny, OnQuery.eval(ctx).decision);
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
    try std.testing.expectEqual(@as(usize, 1), result.filters.len);
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
