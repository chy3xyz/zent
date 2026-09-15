//! End-to-end tests for the `check_sql` CLI (`examples/check_sql`).
//!
//! The CLI is a consumer of `zent.sql_statement.checkStatement`, not part of the
//! library, so there is no test artifact of its own to hang tests on: these
//! drive the module the executable is built from (`check_sql_cli`, wired up in
//! build.zig) against a real SQLite database and a real `.sql` file on disk,
//! and assert the exit code the process would return. What is deliberately not
//! covered here is the `std.process` argv plumbing in `main.zig` — that is the
//! three lines around the call, and `zig build run-check-sql` exercises them.
//!
//! Everything here is SQLite: it is the one driver that is always available, so
//! no case can go red on a machine (or in a CI job) that has no PostgreSQL or
//! MariaDB. The dialect-specific reach of the check itself is already pinned by
//! the driver integration tests and by `src/sql/statement.zig`'s unit tests.

const std = @import("std");
const testing = std.testing;
const zent = @import("zent");
const cli = @import("check_sql_cli");
const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;

/// Big enough that the `fixed` writer never runs out of room in these tests.
const report_bytes = 8192;
const diagnostic_bytes = 2048;

const RunResult = struct {
    code: u8,
    out_buffer: [report_bytes]u8 = undefined,
    err_buffer: [diagnostic_bytes]u8 = undefined,
    out_len: usize = 0,
    err_len: usize = 0,

    /// What the tool printed: one line per statement, plus a header and a summary.
    fn out(self: *const RunResult) []const u8 {
        return self.out_buffer[0..self.out_len];
    }

    /// What it printed to stderr: usage errors, and the notes that are not part
    /// of the per-statement report.
    fn err(self: *const RunResult) []const u8 {
        return self.err_buffer[0..self.err_len];
    }
};

/// Run the tool exactly as `main.zig` does, with output captured.
fn runCli(allocator: std.mem.Allocator, argv: []const []const u8, env_dsn: ?[]const u8) !RunResult {
    var result = RunResult{ .code = cli.exit_ok };
    var out = std.Io.Writer.fixed(&result.out_buffer);
    var err = std.Io.Writer.fixed(&result.err_buffer);
    result.code = try cli.run(allocator, testing.io, &out, &err, argv, env_dsn);
    result.out_len = out.buffered().len;
    result.err_len = err.buffered().len;
    return result;
}

/// The whole line the needle sits on — the unit a report is read in.
fn lineContaining(haystack: []const u8, needle: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, haystack, needle) orelse return null;
    const line_start: usize = if (std.mem.lastIndexOfScalar(u8, haystack[0..at], '\n')) |i| i + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, haystack, at, '\n') orelse haystack.len;
    return haystack[line_start..line_end];
}

/// Write `source` into the test's temp directory and hand back the path, which
/// is relative to the build root (the cwd of a test run).
fn writeSqlFile(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8, source: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
    errdefer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = source });
    return path;
}

test "check_sql: a semicolon only splits outside strings, identifiers and comments" {
    const allocator = testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        expected: []const []const u8,
    }{
        // The case the splitter exists for.
        .{ .source = "SELECT 'a;b';SELECT 2", .expected = &.{ "SELECT 'a;b'", "SELECT 2" } },
        // A doubled quote escapes a quote, it does not end the literal.
        .{ .source = "SELECT 'it''s; fine' AS s", .expected = &.{"SELECT 'it''s; fine' AS s"} },
        // Quoted identifiers, in the two flavours the dialects spell.
        .{ .source = "SELECT \"a;b\" FROM t; SELECT 2", .expected = &.{ "SELECT \"a;b\" FROM t", "SELECT 2" } },
        .{ .source = "SELECT `a;b` FROM t", .expected = &.{"SELECT `a;b` FROM t"} },
        // Comments: line, block, and a nested block (PostgreSQL's rule).
        .{ .source = "-- a; comment\nSELECT 1", .expected = &.{"SELECT 1"} },
        .{ .source = "/* a; /* b; */ c; */ SELECT 1", .expected = &.{"SELECT 1"} },
        // A dollar-quoted body carries its own semicolons.
        .{ .source = "CREATE FUNCTION f() RETURNS int AS $body$ SELECT 1; $body$ LANGUAGE sql", .expected = &.{"CREATE FUNCTION f() RETURNS int AS $body$ SELECT 1; $body$ LANGUAGE sql"} },
        // `$1` is a parameter, not the start of a quoted body.
        .{ .source = "SELECT $1; SELECT 2", .expected = &.{ "SELECT $1", "SELECT 2" } },
        // The last statement needs no semicolon; extra ones are empty.
        .{ .source = "SELECT 1", .expected = &.{"SELECT 1"} },
        .{ .source = ";; ;", .expected = &.{} },
        .{ .source = "-- only a comment ;\n/* and another ; */", .expected = &.{} },
        .{ .source = "", .expected = &.{} },
    };
    for (cases) |case| {
        const statements = try cli.splitStatements(allocator, case.source);
        defer allocator.free(statements);
        try testing.expectEqual(case.expected.len, statements.len);
        for (case.expected, statements) |expected, statement| {
            try testing.expectEqualStrings(expected, statement.text);
        }
    }
}

test "check_sql: every statement is reported with the line it starts on" {
    const allocator = testing.allocator;
    const source =
        \\-- a comment that mentions a semicolon ;
        \\SELECT 1;
        \\
        \\SELEC 1;
        \\SELECT 3
    ;
    const statements = try cli.splitStatements(allocator, source);
    defer allocator.free(statements);

    try testing.expectEqual(@as(usize, 3), statements.len);
    // The comment is not part of any statement: line 2, not line 1.
    try testing.expectEqual(@as(usize, 2), statements[0].line);
    try testing.expectEqualStrings("SELECT 1", statements[0].text);
    try testing.expectEqual(@as(usize, 4), statements[1].line);
    try testing.expectEqual(@as(usize, 5), statements[2].line);
}

test "check_sql: a file with a clean and a broken statement exits non-zero, one line each" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeSqlFile(allocator, &tmp, "mixed.sql",
        \\-- a comment with a semicolon ; in it
        \\SELECT 'a;b' AS s;
        \\SELEC 1;
    );
    defer allocator.free(path);

    const result = try runCli(allocator, &.{ "check_sql", "--dsn", "sqlite::memory:", path }, null);

    // The exit code is what CI reads: a broken statement makes the run fail.
    try testing.expect(result.code != 0);
    try testing.expectEqual(cli.exit_statements_failed, result.code);

    const report = result.out();
    const clean_marker = try std.fmt.allocPrint(allocator, "{s}:2: ok", .{path});
    defer allocator.free(clean_marker);
    const broken_marker = try std.fmt.allocPrint(allocator, "{s}:3: failed problem=syntax", .{path});
    defer allocator.free(broken_marker);

    const clean_line = lineContaining(report, clean_marker) orelse return error.NoCleanLine;
    const broken_line = lineContaining(report, broken_marker) orelse return error.NoBrokenLine;

    // Two statements, two different conclusions — and the broken one carries
    // the driver's own text, with the heuristic flag SQLite's single error code
    // forces on the label. The message is quoted on the line, so its own quotes
    // arrive escaped.
    try testing.expect(!std.mem.eql(u8, clean_line, broken_line));
    try testing.expect(std.mem.indexOf(u8, broken_line, "heuristic") != null);
    try testing.expect(std.mem.indexOf(u8, broken_line, "message=\"near \\\"SELEC\\\": syntax error\"") != null);
    try testing.expect(std.mem.indexOf(u8, report, "check_sql: 2 statement(s): 1 ok, 1 failed, 0 not_checkable") != null);
}

test "check_sql: --param supplies the count a statement is checked against" {
    const allocator = testing.allocator;

    // `SELECT ?` prepares, but wants one parameter and is given none.
    const without = try runCli(allocator, &.{ "check_sql", "--sql", "SELECT ?" }, null);
    try testing.expectEqual(cli.exit_statements_failed, without.code);
    try testing.expect(std.mem.indexOf(u8, without.out(), "failed problem=parameter_mismatch") != null);

    const with = try runCli(allocator, &.{ "check_sql", "--sql", "SELECT ?", "--param", "x" }, null);
    try testing.expectEqual(cli.exit_ok, with.code);
    try testing.expect(std.mem.indexOf(u8, with.out(), "ok problem=none params=1") != null);
}

test "check_sql: not_checkable is not a failure, and an empty run is not a pass" {
    // The exit-code contract, asserted directly: the driver-vs-statement
    // distinction the library draws has to survive the trip to a process code.
    try testing.expectEqual(cli.exit_ok, cli.exitCodeFor(.{ .statements = 3, .ok = 2, .not_checkable = 1 }));
    try testing.expectEqual(cli.exit_statements_failed, cli.exitCodeFor(.{ .statements = 3, .ok = 2, .not_checkable = 1, .failed = 1 }));
    // A check that errored is the run failing, not the statement.
    try testing.expectEqual(cli.exit_unusable, cli.exitCodeFor(.{ .statements = 1, .ok = 1, .check_errors = 1 }));
    // Nothing judged at all: a mistake (an empty file, a glob that matched
    // comments) rather than a green build.
    try testing.expectEqual(cli.exit_unusable, cli.exitCodeFor(.{ .empty_inputs = 1 }));
}

test "check_sql: an input that holds only comments is reported, not silently green" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeSqlFile(allocator, &tmp, "comments.sql", "-- nothing to check ;\n");
    defer allocator.free(path);

    const result = try runCli(allocator, &.{ "check_sql", path }, null);

    try testing.expectEqual(cli.exit_unusable, result.code);
    try testing.expect(std.mem.indexOf(u8, result.err(), "no statements") != null);
    try testing.expect(std.mem.indexOf(u8, result.out(), "0 statement(s)") != null);
}

test "check_sql: a statement that would write writes nothing" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/target.db", .{tmp.sub_path});
    defer allocator.free(db_path);

    {
        var drv = try SQLiteDriver.open(allocator, db_path);
        defer drv.close();
        _ = try drv.exec("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)", &.{});
    }

    const dsn = try std.fmt.allocPrint(allocator, "sqlite:{s}", .{db_path});
    defer allocator.free(dsn);
    const result = try runCli(allocator, &.{
        "check_sql",
        "--dsn",
        dsn,
        "--sql",
        "INSERT INTO items (id, name) VALUES (7, 'inserted')",
    }, null);

    // It prepares, so it is reported clean — and it ran nothing.
    try testing.expectEqual(cli.exit_ok, result.code);
    try testing.expect(std.mem.indexOf(u8, result.out(), "ok problem=none") != null);

    var drv = try SQLiteDriver.open(allocator, db_path);
    defer drv.close();
    var rows = try drv.query("SELECT COUNT(*) FROM items", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 0), row.getInt(0).?);
}

test "check_sql: the DSN comes from --dsn first, then $ZENT_DSN, then SQLite in memory" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/env.db", .{tmp.sub_path});
    defer allocator.free(db_path);

    {
        // A database that exists only under the environment's DSN: whichever
        // connection is used is the one the header line names.
        var drv = try SQLiteDriver.open(allocator, db_path);
        defer drv.close();
        _ = try drv.exec("CREATE TABLE env_marker (id INTEGER PRIMARY KEY)", &.{});
    }

    const env_dsn = try std.fmt.allocPrint(allocator, "sqlite:{s}", .{db_path});
    defer allocator.free(env_dsn);
    const missing = try std.fmt.allocPrint(allocator, "sqlite:.zig-cache/tmp/{s}/does_not_exist.db", .{tmp.sub_path});
    defer allocator.free(missing);

    // The env DSN applies when --dsn is absent...
    const from_env = try runCli(allocator, &.{ "check_sql", "--sql", "SELECT id FROM env_marker" }, env_dsn);
    try testing.expectEqual(cli.exit_ok, from_env.code);
    try testing.expect(std.mem.indexOf(u8, from_env.out(), env_dsn) != null);

    // ...and --dsn wins over it, which the missing table then shows.
    const explicit = try runCli(allocator, &.{ "check_sql", "--dsn", missing, "--sql", "SELECT id FROM env_marker" }, env_dsn);
    try testing.expectEqual(cli.exit_statements_failed, explicit.code);
    try testing.expect(std.mem.indexOf(u8, explicit.out(), "failed problem=missing_relation") != null);
}

test "check_sql: --help documents the tool and exits 0 without a connection" {
    const allocator = testing.allocator;
    const result = try runCli(allocator, &.{"check_sql"}, null);
    // No input is a usage error, not a silent pass.
    try testing.expectEqual(cli.exit_unusable, result.code);
    try testing.expect(std.mem.indexOf(u8, result.err(), "--help") != null);

    const help = try runCli(allocator, &.{ "check_sql", "--help" }, null);
    try testing.expectEqual(cli.exit_ok, help.code);
    const text = help.out();
    try testing.expect(std.mem.indexOf(u8, text, "--dsn") != null);
    try testing.expect(std.mem.indexOf(u8, text, "not_checkable") != null);
    // The three dialects' reach is stated, not implied.
    try testing.expect(std.mem.indexOf(u8, text, "sqlite") != null);
    try testing.expect(std.mem.indexOf(u8, text, "postgres") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mysql") != null);
}
