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
        if (d.kind() == .postgres) {
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
        const quote: u8 = if (d.kind() == .mysql) '`' else '"';

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

/// Rewrite `?` placeholders into the dialect's own spelling — `$1`, `$2`, … on
/// PostgreSQL, unchanged on SQLite and MySQL (their drivers take `?`).
///
/// **Why this exists.** zent's fluent builders translate as they build
/// (`Builder.arg` → `Dialect.placeholder`), so a query written through them is
/// dialect-correct by construction. A *raw* statement handed to
/// `driver.exec` / `driver.query` is not: those take the dialect's native
/// spelling, which means `?` everywhere except PostgreSQL, where the server
/// reads `?` as a literal and answers `syntax error at or near "AND"`. That
/// contract is now stated on both driver methods; this function is what a
/// consumer porting `?`-style raw SQL to PostgreSQL calls, so the rewrite does
/// not have to be re-invented (with its own bugs) in every application.
///
/// **What is a placeholder.** A `?` outside a quoted run, a comment and a
/// PostgreSQL dollar-quoted body, numbered in the order it appears. Everything
/// that carries text differently is copied verbatim:
///
///   - `'…'` (with `''` as the escape), `"…"` and `` `…` `` identifiers;
///   - `--` to end of line, and `/* … */` including PostgreSQL's nesting;
///   - `$tag$ … $tag$` (PostgreSQL only — `$1` is not one of these).
///
/// A literal `?` therefore needs quoting (`'?'`); there is no `??` escape, so
/// an existing `??` means two placeholders. The counter always starts at 1, and
/// the statement must be written in **one** style: a statement that already
/// carries `$n` and `?` would collide.
///
/// Dialects other than PostgreSQL are structurally immune to a mis-scan — every
/// `?` maps to `?`, so the output equals the input whatever the scanner decides
/// — which is also why the escape rules it does not model (`\'` with MySQL's
/// default `NO_BACKSLASH_ESCAPES` off) cannot change an answer here.
///
/// The returned slice is owned by the caller.
pub fn translatePlaceholdersAlloc(dialect: Dialect, allocator: std.mem.Allocator, sql_text: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(sql_text.len + 16);

    var index: usize = 0;
    var i: usize = 0;
    while (i < sql_text.len) {
        switch (sql_text[i]) {
            '?' => {
                index += 1;
                var buf: [16]u8 = undefined;
                try out.appendSlice(try dialect.placeholder(&buf, index));
                i += 1;
            },
            '\'', '"', '`' => i = appendQuoted(&out, sql_text, i),
            '-' => {
                if (i + 1 < sql_text.len and sql_text[i + 1] == '-') {
                    // To end of line, newline included in the copied run's
                    // exclusion: the comment body is data, the newline is not.
                    const end = std.mem.indexOfScalarPos(u8, sql_text, i, '\n') orelse sql_text.len;
                    try out.appendSlice(sql_text[i..end]);
                    i = end;
                } else {
                    try out.append('-');
                    i += 1;
                }
            },
            '/' => {
                if (i + 1 < sql_text.len and sql_text[i + 1] == '*') {
                    i = appendBlockComment(&out, sql_text, i);
                } else {
                    try out.append('/');
                    i += 1;
                }
            },
            '$' => {
                // PostgreSQL's dollar quoting, and only there: `$1` is a
                // placeholder on that dialect too, and `dollarQuoteEnd` refuses
                // a tag that starts with a digit, so the two cannot be confused.
                const end: ?usize = if (dialect.kind() == .postgres) dollarQuoteEnd(sql_text, i) else null;
                if (end) |after| {
                    try out.appendSlice(sql_text[i..after]);
                    i = after;
                } else {
                    try out.append('$');
                    i += 1;
                }
            },
            else => {
                try out.append(sql_text[i]);
                i += 1;
            },
        }
    }
    return out.toOwnedSlice();
}

/// Copy a quoted run starting at `start` verbatim, doubling escapes included,
/// and return the index just past it. An unterminated run copies to the end —
/// the server rejects it either way, and inventing a closing quote would turn
/// one error into a different one.
fn appendQuoted(out: *std.array_list.Managed(u8), sql_text: []const u8, start: usize) usize {
    const quote = sql_text[start];
    out.append(quote) catch return sql_text.len;
    var i = start + 1;
    while (i < sql_text.len) {
        const c = sql_text[i];
        out.append(c) catch return sql_text.len;
        i += 1;
        if (c == quote) {
            // A doubled quote is an escaped quote, not the end of the run.
            if (i < sql_text.len and sql_text[i] == quote) {
                out.append(quote) catch return sql_text.len;
                i += 1;
            } else return i;
        }
    }
    return i;
}

/// `/* … */`, with PostgreSQL's nesting (`/* /* */ */` is one comment). An
/// unterminated comment copies to the end, like `appendQuoted`.
fn appendBlockComment(out: *std.array_list.Managed(u8), sql_text: []const u8, start: usize) usize {
    var depth: usize = 0;
    var i = start;
    while (i < sql_text.len) {
        if (i + 1 < sql_text.len and sql_text[i] == '/' and sql_text[i + 1] == '*') {
            depth += 1;
            out.appendSlice("/*") catch return sql_text.len;
            i += 2;
            continue;
        }
        if (i + 1 < sql_text.len and sql_text[i] == '*' and sql_text[i + 1] == '/') {
            depth -= 1;
            out.appendSlice("*/") catch return sql_text.len;
            i += 2;
            if (depth == 0) return i;
            continue;
        }
        out.append(sql_text[i]) catch return sql_text.len;
        i += 1;
    }
    return i;
}

/// The index just past the dollar-quoted run that starts at `start`, or `null`
/// when `start` does not open one.
///
/// PostgreSQL's rule: `$tag$`, where `tag` is empty or an identifier that does
/// not start with a digit. That is what keeps `$1` — a placeholder — from being
/// read as an empty tag followed by `1` and a terminator.
fn dollarQuoteEnd(sql_text: []const u8, start: usize) ?usize {
    var i = start + 1;
    while (i < sql_text.len and (std.ascii.isAlphanumeric(sql_text[i]) or sql_text[i] == '_')) i += 1;
    if (i >= sql_text.len or sql_text[i] != '$') return null;
    if (i > start + 1 and std.ascii.isDigit(sql_text[start + 1])) return null;
    const tag = sql_text[start .. i + 1]; // "$tag$", brackets included
    const body = i + 1;
    const end = std.mem.indexOfPos(u8, sql_text, body, tag) orelse return null;
    return end + tag.len;
}

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

test "translatePlaceholdersAlloc numbers ? into $n on PostgreSQL and leaves the other dialects alone" {
    const allocator = std.testing.allocator;

    const pg = try translatePlaceholdersAlloc(Dialect.postgres, allocator, "SELECT * FROM t WHERE a = ? AND b = ?");
    defer allocator.free(pg);
    try std.testing.expectEqualStrings("SELECT * FROM t WHERE a = $1 AND b = $2", pg);

    // The two `?`-native dialects get the statement back unchanged — including
    // the one quantifier in a MySQL-only construct.
    for ([_]Dialect{ Dialect.sqlite, Dialect.mysql }) |d| {
        const same = try translatePlaceholdersAlloc(d, allocator, "SELECT * FROM t WHERE a = ? AND b = ?");
        defer allocator.free(same);
        try std.testing.expectEqualStrings("SELECT * FROM t WHERE a = ? AND b = ?", same);
    }
}

test "translatePlaceholdersAlloc never rewrites a ? that is data" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        // A quoted literal, with the doubled-quote escape inside it.
        .{ .in = "WHERE note = 'why?' AND a = ?", .out = "WHERE note = 'why?' AND a = $1" },
        .{ .in = "WHERE note = 'it''s ?' AND a = ?", .out = "WHERE note = 'it''s ?' AND a = $1" },
        // A quoted identifier, and MySQL's backtick form.
        .{ .in = "WHERE \"we?ird\" = ?", .out = "WHERE \"we?ird\" = $1" },
        .{ .in = "WHERE `we?ird` = ?", .out = "WHERE `we?ird` = $1" },
        // Comments: line, block, and PostgreSQL's nested block.
        .{ .in = "SELECT 1 -- what?\nWHERE a = ?", .out = "SELECT 1 -- what?\nWHERE a = $1" },
        .{ .in = "SELECT /* ? */ 1 WHERE a = ?", .out = "SELECT /* ? */ 1 WHERE a = $1" },
        .{ .in = "SELECT /* ? /* ? */ ? */ 1 WHERE a = ?", .out = "SELECT /* ? /* ? */ ? */ 1 WHERE a = $1" },
        // A dollar-quoted body is text, and `$1` is a placeholder rather than an
        // empty tag: the digit-first rule is what separates them.
        .{ .in = "DO $body$ PERFORM '?'$body$; SELECT ?", .out = "DO $body$ PERFORM '?'$body$; SELECT $1" },
        .{ .in = "WHERE a = $2 AND b = ?", .out = "WHERE a = $2 AND b = $1" },
        // A lone `-` and `/` (arithmetic) are not comment starts.
        .{ .in = "SELECT a - - ? , b / ?", .out = "SELECT a - - $1 , b / $2" },
    };
    for (cases) |c| {
        const got = try translatePlaceholdersAlloc(Dialect.postgres, allocator, c.in);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(c.out, got);
    }
}

test "translatePlaceholdersAlloc copies an unterminated run to the end instead of inventing a close" {
    const allocator = std.testing.allocator;
    // The server rejects both of these; the point is that the rewrite does not
    // turn one syntax error into a different one.
    for ([_][]const u8{ "SELECT 'oops", "SELECT /* oops" }) |in| {
        const got = try translatePlaceholdersAlloc(Dialect.postgres, allocator, in);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(in, got);
    }
}
