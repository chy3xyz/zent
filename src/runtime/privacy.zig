const std = @import("std");

/// Maximum number of filter predicates retained inline by a DecisionSet.
const max_filters = 8;

/// Operation type for privacy evaluation. Mirrors hook.Op.
pub const Op = enum { create, update, delete, query };

/// Carries caller identity through the query/mutation pipeline.
/// Value-type, copy-passed; immutable after construction.
pub const PrivacyContext = struct {
    user_id: ?i64 = null,
    role: ?[]const u8 = null,
    tenant_id: ?i64 = null,
    extra: ?*anyopaque = null,
    /// Current operation being checked. Set by codegen at call time.
    /// Allows policies to differentiate between create/update/delete/query.
    op: Op = .query,
};

/// Decision returned by privacy rule evaluation.
pub const Decision = enum {
    allow,
    deny,
};

/// Result of evaluating a set of privacy rules. Filter pointers are stored
/// inline so returning DecisionSet by value never exposes a stack-backed slice.
pub const DecisionSet = struct {
    decision: Decision,
    filters: [max_filters]*const anyopaque = undefined,
    filter_count: usize = 0,

    /// Return the accumulated filter pointers as a slice.
    pub fn getFilters(self: *const DecisionSet) []*const anyopaque {
        return @constCast(self.filters[0..self.filter_count]);
    }
};

/// A filter rule: carries a predicate function that, given a PrivacyContext,
/// returns an optional opaque filter pointer (null = filter not applicable).
pub const FilterRule = struct {
    predicate: *const fn (PrivacyContext) ?*const anyopaque,
};

/// Privacy rule variants.
/// - skip: no-op, continue to next rule.
/// - deny: immediately reject.
/// - allow: lock in allow; continue collecting remaining filters.
/// - filter: apply a data-level filter (row-level security).
pub const Rule = union(enum) {
    skip,
    deny,
    allow,
    filter: FilterRule,
    /// Applies `decision` only when ctx.op matches `op`; otherwise the rule
    /// is skipped. Flat on purpose (an `on: {op, rule}` would recurse).
    on_op: struct { op: Op, decision: Decision },
};

/// Evaluate privacy rules in order with AND semantics.
///
/// Rules are processed sequentially:
/// - .skip → continue to next rule.
/// - .deny → return a deny DecisionSet with no filters immediately.
/// - .allow → lock in .allow; remaining rules are still scanned for filters.
/// - .filter → invoke predicate(ctx); if non-null, accumulate the opaque pointer.
///
/// `rules` is a runtime slice of `Rule`.
pub fn evalPolicy(
    ctx: PrivacyContext,
    rules: []const Rule,
) DecisionSet {
    var result = DecisionSet{ .decision = .allow };

    for (rules) |rule| {
        switch (rule) {
            .skip => continue,
            .deny => return .{ .decision = .deny },
            .allow => {
                // Lock in allow; continue collecting remaining filters.
            },
            .filter => |fr| {
                if (fr.predicate(ctx)) |pred| {
                    if (result.filter_count >= result.filters.len) {
                        // Capacity exhausted. Truncating would silently widen
                        // the result set of a security policy, and asserting
                        // would abort the process under ReleaseSafe — so fail
                        // closed instead: deny, and say why. (warn, not err:
                        // the deny is the signal, and an err-level log would
                        // fail any test whose policy exercises this path.)
                        std.log.warn(
                            "privacy: policy produced more than {d} row filters; denying rather than dropping one",
                            .{result.filters.len},
                        );
                        return .{ .decision = .deny };
                    }
                    result.filters[result.filter_count] = pred;
                    result.filter_count += 1;
                }
            },
            .on_op => |o| {
                // Operation-specific rule: active only for its own op.
                if (ctx.op != o.op) continue;
                if (o.decision == .deny) return .{ .decision = .deny };
                // allow: lock in allow, keep scanning for filters.
            },
        }
    }
    return result;
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "PrivacyContext defaults" {
    const ctx = PrivacyContext{};
    try std.testing.expectEqual(@as(?i64, null), ctx.user_id);
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.role);
    try std.testing.expectEqual(@as(?i64, null), ctx.tenant_id);
    try std.testing.expectEqual(@as(?*anyopaque, null), ctx.extra);
}

test "PrivacyContext custom values" {
    const ctx = PrivacyContext{
        .user_id = 42,
        .role = "admin",
        .tenant_id = 1,
    };
    try std.testing.expectEqual(@as(?i64, 42), ctx.user_id);
    try std.testing.expectEqualStrings("admin", ctx.role.?);
    try std.testing.expectEqual(@as(?i64, 1), ctx.tenant_id);
}

test "evalPolicy: deny wins immediately" {
    const ctx = PrivacyContext{};
    const rules = comptime [_]Rule{
        .deny,
        .allow,
    };
    const result = evalPolicy(ctx, &rules);
    try std.testing.expectEqual(Decision.deny, result.decision);
    try std.testing.expectEqual(@as(usize, 0), result.filter_count);
}

test "evalPolicy: allow after skip" {
    const ctx = PrivacyContext{};
    const rules = comptime [_]Rule{
        .skip,
        .skip,
        .allow,
    };
    const result = evalPolicy(ctx, &rules);
    try std.testing.expectEqual(Decision.allow, result.decision);
}

test "evalPolicy: deny before allow" {
    const ctx = PrivacyContext{};
    const rules = comptime [_]Rule{
        .allow,
        .deny,
    };
    const result = evalPolicy(ctx, &rules);
    try std.testing.expectEqual(Decision.deny, result.decision);
}

test "evalPolicy: pure allow" {
    const ctx = PrivacyContext{};
    const rules = comptime [_]Rule{.allow};
    const result = evalPolicy(ctx, &rules);
    try std.testing.expectEqual(Decision.allow, result.decision);
    try std.testing.expectEqual(@as(usize, 0), result.filter_count);
}

test "evalPolicy: filter accumulates" {
    const ctx = PrivacyContext{ .user_id = 1 };
    const rules = comptime [_]Rule{
        .allow,
        Rule{
            .filter = .{
                .predicate = struct {
                    fn p(c: PrivacyContext) ?*const anyopaque {
                        _ = c;
                        return @ptrCast(&struct { x: i32 = 1 });
                    }
                }.p,
            },
        },
        Rule{
            .filter = .{
                .predicate = struct {
                    fn p(c: PrivacyContext) ?*const anyopaque {
                        _ = c;
                        return @ptrCast(&struct { x: i32 = 2 });
                    }
                }.p,
            },
        },
    };
    const result = evalPolicy(ctx, &rules);
    try std.testing.expectEqual(Decision.allow, result.decision);
    try std.testing.expectEqual(@as(usize, 2), result.filter_count);
}

test "evalPolicy: filter returning null is skipped" {
    const ctx = PrivacyContext{};
    const rules = comptime [_]Rule{
        .allow,
        Rule{
            .filter = .{
                .predicate = struct {
                    fn p(c: PrivacyContext) ?*const anyopaque {
                        _ = c;
                        return null; // no filter for anonymous users
                    }
                }.p,
            },
        },
    };
    const result = evalPolicy(ctx, &rules);
    try std.testing.expectEqual(Decision.allow, result.decision);
    try std.testing.expectEqual(@as(usize, 0), result.filter_count);
}

test "evalPolicy: deny short-circuits before filters" {
    const ctx = PrivacyContext{ .user_id = 1 };
    const rules = comptime [_]Rule{
        Rule{
            .filter = .{
                .predicate = struct {
                    fn p(c: PrivacyContext) ?*const anyopaque {
                        _ = c;
                        return @ptrCast(&struct { x: i32 = 1 });
                    }
                }.p,
            },
        },
        .deny,
    };
    const result = evalPolicy(ctx, &rules);
    try std.testing.expectEqual(Decision.deny, result.decision);
    try std.testing.expectEqual(@as(usize, 0), result.filter_count);
}

test "evalPolicy: context-dependent filter" {
    const ctx = PrivacyContext{ .user_id = 5 };
    const rules = comptime [_]Rule{
        .allow,
        Rule{
            .filter = .{
                .predicate = struct {
                    fn p(c: PrivacyContext) ?*const anyopaque {
                        if (c.user_id) |uid| {
                            _ = uid;
                            return @ptrCast(&struct { uid: i64 = 0 });
                        }
                        return null;
                    }
                }.p,
            },
        },
    };
    const result = evalPolicy(ctx, &rules);
    try std.testing.expectEqual(Decision.allow, result.decision);
    try std.testing.expectEqual(@as(usize, 1), result.filter_count);
}

test "evalPolicy: empty rules defaults to allow" {
    const ctx = PrivacyContext{};
    const rules = comptime [_]Rule{};
    const result = evalPolicy(ctx, &rules);
    try std.testing.expectEqual(Decision.allow, result.decision);
    try std.testing.expectEqual(@as(usize, 0), result.filter_count);
}

test "evalPolicy denies instead of overflowing the filter array" {
    // max_filters is 8; a policy with more filtering rules than capacity must
    // fail closed (deny) rather than assert or silently drop a row filter.
    const rule = Rule{ .filter = .{ .predicate = struct {
        fn p(_: PrivacyContext) ?*const anyopaque {
            return @ptrCast(&struct {
                var marker: u8 = 1;
            }.marker);
        }
    }.p } };

    var rules: [max_filters + 1]Rule = undefined;
    for (&rules) |*r| r.* = rule;

    const result = evalPolicy(PrivacyContext{ .op = .query }, &rules);
    try std.testing.expectEqual(Decision.deny, result.decision);

    // Capacity itself still works: exactly max_filters rules are collected.
    const ok = evalPolicy(PrivacyContext{ .op = .query }, rules[0..max_filters]);
    try std.testing.expectEqual(Decision.allow, ok.decision);
    try std.testing.expectEqual(@as(usize, max_filters), ok.filter_count);
}
