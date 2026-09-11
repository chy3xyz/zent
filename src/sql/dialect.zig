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

    /// Quote an identifier, doubling any embedded quote character
    /// (`"` for standard dialects, `` ` `` for MySQL) as required by the SQL
    /// standard. Otherwise a name carrying the quote would terminate the
    /// identifier early.
    ///
    /// `buf` must hold at least `2 * name.len + 2` bytes; a smaller buffer
    /// returns `error.NoSpaceLeft`.
    pub fn quoteIdent(d: Dialect, buf: []u8, name: []const u8) ![]const u8 {
        const quote: u8 = if (std.mem.eql(u8, d.name, "mysql")) '`' else '"';

        var i: usize = 0;
        if (buf.len < 2 * name.len + 2) return error.NoSpaceLeft;

        buf[i] = quote;
        i += 1;
        for (name) |c| {
            buf[i] = c;
            i += 1;
            if (c == quote) {
                buf[i] = c;
                i += 1;
            }
        }
        buf[i] = quote;
        i += 1;
        return buf[0..i];
    }
};

test "quoteIdent doubles embedded quote characters" {
    var buf: [64]u8 = undefined;

    try std.testing.expectEqualStrings("\"we\"\"ird\"", try Dialect.sqlite.quoteIdent(&buf, "we\"ird"));
    try std.testing.expectEqualStrings("\"we\"\"ird\"", try Dialect.postgres.quoteIdent(&buf, "we\"ird"));
    try std.testing.expectEqualStrings("`we``ird`", try Dialect.mysql.quoteIdent(&buf, "we`ird"));
}

test "quoteIdent errors when the buffer is too small" {
    var buf: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, Dialect.sqlite.quoteIdent(&buf, "0123456789"));
}
