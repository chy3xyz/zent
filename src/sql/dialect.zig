const std = @import("std");

pub const Dialect = struct {
    name: []const u8,

    pub const sqlite = Dialect{ .name = "sqlite3" };
    pub const postgres = Dialect{ .name = "postgres" };
    pub const mysql = Dialect{ .name = "mysql" };

    /// What dispatch should switch on.
    ///
    /// The dialects used to be compared by name at every site —
    /// `std.mem.eql(u8, dialect.name, "mysql")` and its relatives, 66 of them —
    /// which is a string comparison that cannot be checked: a misspelt literal
    /// is simply always false and the branch silently never runs. One did:
    /// `maxBindParams` asked for `"sqlite"` while `Dialect.sqlite.name` is
    /// `"sqlite3"`, so SQLite chunks were sized for the 65535 cap instead of its
    /// 999 and a large batch hit the server's variable limit instead of being
    /// split. A `switch` over this enum is exhaustive, so a dialect added later
    /// is a compile error at every site that has to think about it.
    ///
    /// `.unknown` is a `Dialect` whose `name` is none of the three — a consumer
    /// may build one (`Dialect{ .name = "cockroach" }`) — and it behaves as
    /// SQLite has always been treated: `?` placeholders and double-quoted
    /// identifiers. Naming it keeps that fallback visible at each site instead of
    /// hiding it in an `else`.
    pub const Kind = enum { sqlite, postgres, mysql, unknown };

    pub fn kind(d: Dialect) Kind {
        if (std.mem.eql(u8, d.name, "sqlite3")) return .sqlite;
        if (std.mem.eql(u8, d.name, "postgres")) return .postgres;
        if (std.mem.eql(u8, d.name, "mysql")) return .mysql;
        return .unknown;
    }

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

test "kind names each built-in dialect, and an unknown name is not silently one of them" {
    try std.testing.expectEqual(Dialect.Kind.sqlite, Dialect.sqlite.kind());
    try std.testing.expectEqual(Dialect.Kind.postgres, Dialect.postgres.kind());
    try std.testing.expectEqual(Dialect.Kind.mysql, Dialect.mysql.kind());
    // The spelling that made `maxBindParams` dead code: "sqlite" is *not* the
    // name of `Dialect.sqlite`, and `kind` says so instead of matching neither
    // and falling through to a wrong branch.
    try std.testing.expectEqual(Dialect.Kind.unknown, (Dialect{ .name = "sqlite" }).kind());
    try std.testing.expectEqual(Dialect.Kind.unknown, (Dialect{ .name = "cockroach" }).kind());
}
