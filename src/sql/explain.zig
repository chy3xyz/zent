const std = @import("std");
const Dialect = @import("dialect.zig").Dialect;

pub const Format = enum { text, json };

pub const ExplainResult = struct {
    sql: []const u8,

    pub fn deinit(self: *ExplainResult, allocator: std.mem.Allocator) void {
        allocator.free(self.sql);
        self.* = undefined;
    }
};

pub fn explainSql(allocator: std.mem.Allocator, dialect: Dialect, raw_sql: []const u8, format: Format) !ExplainResult {
    const prefix: []const u8 = switch (dialect.name[0]) {
        's' => "EXPLAIN QUERY PLAN ",
        'p' => if (format == .json) "EXPLAIN (FORMAT JSON) " else "EXPLAIN ",
        'm' => "EXPLAIN ",
        else => return error.UnsupportedDialect,
    };
    const sql = try allocator.alloc(u8, prefix.len + raw_sql.len);
    @memcpy(sql[0..prefix.len], prefix);
    @memcpy(sql[prefix.len..], raw_sql);
    return ExplainResult{ .sql = sql };
}

test "SQLite EXPLAIN SQL prefix" {
    const allocator = std.testing.allocator;
    const raw = "SELECT 1";
    var plan = try explainSql(allocator, Dialect.sqlite, raw, .text);
    defer plan.deinit(allocator);
    try std.testing.expectEqualStrings("EXPLAIN QUERY PLAN SELECT 1", plan.sql);
}

test "PostgreSQL EXPLAIN SQL prefix" {
    const allocator = std.testing.allocator;
    const raw = "SELECT 1";

    var text_plan = try explainSql(allocator, Dialect.postgres, raw, .text);
    defer text_plan.deinit(allocator);
    try std.testing.expectEqualStrings("EXPLAIN SELECT 1", text_plan.sql);

    var json_plan = try explainSql(allocator, Dialect.postgres, raw, .json);
    defer json_plan.deinit(allocator);
    try std.testing.expectEqualStrings("EXPLAIN (FORMAT JSON) SELECT 1", json_plan.sql);
}

test "MySQL EXPLAIN SQL prefix" {
    const allocator = std.testing.allocator;
    const raw = "SELECT 1";
    var plan = try explainSql(allocator, Dialect.mysql, raw, .text);
    defer plan.deinit(allocator);
    try std.testing.expectEqualStrings("EXPLAIN SELECT 1", plan.sql);
}
