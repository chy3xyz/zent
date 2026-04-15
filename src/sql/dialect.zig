const std = @import("std");

pub const Dialect = struct {
    name: []const u8,

    pub const sqlite = Dialect{ .name = "sqlite3" };
    pub const postgres = Dialect{ .name = "postgres" };
    pub const mysql = Dialect{ .name = "mysql" };

    pub fn placeholder(d: Dialect, buf: []u8, index: usize) ![]const u8 {
        if (std.mem.eql(u8, d.name, "postgres")) {
            return std.fmt.bufPrint(buf, "${d}", .{index});
        }
        return "?";
    }

    pub fn quoteIdent(d: Dialect, writer: anytype, name: []const u8) !void {
        if (std.mem.eql(u8, d.name, "mysql")) {
            try writer.print("`{s}`", .{name});
        } else {
            try writer.print("\"{s}\"", .{name});
        }
    }
};
