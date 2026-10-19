//! SQL parameter value type. Lives in its own file so lower layers
//! (core/edge, graph/step) can reference it without importing the full
//! builder (which depends back on graph/step).

const std = @import("std");

/// A value that can be passed as a SQL argument.
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    bytes: []const u8,
};

/// Structural equality, comparing string/bytes payloads by content.
/// Used to keep interceptor-injected predicates idempotent.
pub fn eql(a: Value, b: Value) bool {
    return switch (a) {
        .null => switch (b) {
            .null => true,
            else => false,
        },
        .bool => |x| switch (b) {
            .bool => |y| x == y,
            else => false,
        },
        .int => |x| switch (b) {
            .int => |y| x == y,
            else => false,
        },
        .float => |x| switch (b) {
            .float => |y| x == y,
            else => false,
        },
        .string => |x| switch (b) {
            .string => |y| std.mem.eql(u8, x, y),
            else => false,
        },
        .bytes => |x| switch (b) {
            .bytes => |y| std.mem.eql(u8, x, y),
            else => false,
        },
    };
}

/// Raw WHERE fragment with `?` placeholders and their bound values, used by
/// edge filters (avoids depending on the full builder / Predicate type).
pub const Filter = struct {
    sql: []const u8,
    args: []const Value = &.{},
};
