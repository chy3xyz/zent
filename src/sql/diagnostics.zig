const std = @import("std");
const Value = @import("builder.zig").Value;

/// Diagnostic context captured when SQL statement execution or query encounters a failure.
pub const SqlDiagnostic = struct {
    sql: []const u8 = "",
    args_count: usize = 0,
    table_name: []const u8 = "",
    db_err_code: i32 = 0,
    db_err_msg: []const u8 = "",
    err: ?anyerror = null,

    /// Formats the diagnostic into a human-readable string for logging or debugging.
    /// Caller owns the returned string and must free it using `allocator.free()`.
    pub fn format(self: SqlDiagnostic, allocator: std.mem.Allocator) ![]const u8 {
        var list = try std.array_list.Managed(u8).initCapacity(allocator, 256);
        defer list.deinit();

        try list.appendSlice("SQL Failure Diagnostic:\n");
        if (self.err) |e| {
            try list.print("  Error: {s}\n", .{@errorName(e)});
        }
        if (self.db_err_code != 0 or self.db_err_msg.len > 0) {
            try list.print("  DB Native Code [{d}]: {s}\n", .{ self.db_err_code, self.db_err_msg });
        }
        if (self.table_name.len > 0) {
            try list.print("  Table: {s}\n", .{self.table_name});
        }
        try list.print("  SQL: {s}\n", .{self.sql});
        try list.print("  Args Count: {d}\n", .{self.args_count});

        return allocator.dupe(u8, list.items);
    }
};

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "SqlDiagnostic format output" {
    const allocator = std.testing.allocator;
    const diag = SqlDiagnostic{
        .sql = "SELECT * FROM users WHERE id = ?",
        .args_count = 1,
        .table_name = "users",
        .db_err_code = 19,
        .db_err_msg = "UNIQUE constraint failed",
        .err = error.QueryFailed,
    };

    const formatted = try diag.format(allocator);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "SQL Failure Diagnostic:") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Error: QueryFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "DB Native Code [19]: UNIQUE constraint failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Table: users") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "SQL: SELECT * FROM users WHERE id = ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Args Count: 1") != null);
}
