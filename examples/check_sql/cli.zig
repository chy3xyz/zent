//! `check_sql` — a command line front end for
//! `zent.sql_statement.checkStatement`: is this raw SQL runnable, and if not,
//! what did the server say?
//!
//! This is the entry point the Z28 report asked for (`docs/ISSUES_FROM_ZAPI.md`):
//! read `.sql` files or `--sql` text, split it into statements, prepare each one
//! against the database named by `--dsn`, print one line per statement, and exit
//! non-zero if any of them failed. It **never executes** anything — the only
//! call into the database is `checkStatement`, which is prepare-and-discard
//! (`src/sql/statement.zig` documents what each dialect can see at that stage).
//!
//! This file is a consumer of the library, not part of it: it lives under
//! `examples/` and is deliberately absent from `src/root.zig`'s exports.
//!
//! # Statement splitting
//!
//! A `.sql` file usually holds more than one statement, and passing the whole
//! file to the driver would answer the wrong question: PostgreSQL rejects a
//! multi-statement string at prepare time (42601) and SQLite prepares only the
//! first statement of one, silently skipping the rest — which is exactly the
//! "it was fine when I ran it by hand" failure this tool exists to prevent. So
//! the input is split here, and every statement is checked on its own.
//!
//! The splitter tracks the constructs a semicolon can hide inside: `'strings'`
//! (with `''` doubling), `"quoted identifiers"`, `` `backtick identifiers` ``,
//! `--` line comments, `/* block comments */` nested the way PostgreSQL nests
//! them, and PostgreSQL's `$tag$ dollar-quoted $tag$` bodies. The limits it
//! does not pretend to cover are listed in `usage`; the important one is that
//! an unterminated quote or comment swallows the rest of the input into one
//! statement, which the database then reports as a syntax error instead of the
//! splitter silently dropping text.
//!
//! Each statement carries the 1-based line it starts on, so a report points
//! back at the file rather than at an offset into it.

const std = @import("std");

const zent = @import("zent");
const build_options = @import("build_options");

const sql_driver = zent.sql_driver;
const sql_statement = zent.sql_statement;
const Value = zent.sql.Value;
const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
// PG/MySQL are only referenced when their C bindings were discovered at build
// time (see build.zig); a `void` placeholder keeps the union uniform on
// machines without the headers, and every use is guarded by a comptime branch
// so the placeholder is never analyzed.
const PostgresDriver = if (build_options.have_pg) zent.sql_postgres.PostgresDriver else void;
const MySQLDriver = if (build_options.have_mysql) zent.sql_mysql.MySQLDriver else void;

/// Nothing failed: every statement prepared cleanly, or could not be judged.
pub const exit_ok: u8 = 0;
/// At least one statement did not prepare.
pub const exit_statements_failed: u8 = 1;
/// The run itself could not happen: bad options, an unreadable input, no
/// connection, a check that errored, or no statement found at all.
pub const exit_unusable: u8 = 2;

/// Default connection. SQLite in memory is enough for every statement that
/// names no table, and it cannot touch anything on disk.
const default_dsn = "sqlite::memory:";

/// Refuse a runaway input rather than allocating it.
const max_file_bytes: usize = 64 * 1024 * 1024;

/// What the run did, and the only thing the exit code is computed from.
pub const Stats = struct {
    /// Statements that reached the checker.
    statements: usize = 0,
    ok: usize = 0,
    failed: usize = 0,
    not_checkable: usize = 0,
    /// Statements whose *check* errored (a dead connection, out of memory) as
    /// opposed to statements that were judged and failed. The library reserves
    /// its error union for exactly this distinction.
    check_errors: usize = 0,
    /// Inputs that produced no statement at all (comments and whitespace only).
    empty_inputs: usize = 0,
};

/// The exit-code contract, in one place.
///
/// `not_checkable` is not a failure — it means this channel cannot judge the
/// statement (`docs/BEST_PRACTICES.md` §5) — so it does not move the code. A
/// run that judged nothing is an error rather than a pass: a glob that matched
/// only empty files must not look like a green build.
pub fn exitCodeFor(stats: Stats) u8 {
    if (stats.check_errors > 0) return exit_unusable;
    if (stats.failed > 0) return exit_statements_failed;
    if (stats.statements == 0) return exit_unusable;
    return exit_ok;
}

/// Run the tool. `argv` includes `argv[0]`, which is only used as "the program
/// name is over here". `env_dsn` is `$ZENT_DSN`, if the environment has one.
/// Returns the process exit code; the error union is for the run being
/// impossible to finish at all (out of memory, a write that failed).
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    argv: []const []const u8,
    env_dsn: ?[]const u8,
) !u8 {
    var files = std.array_list.Managed([]const u8).init(gpa);
    defer files.deinit();
    var sqls = std.array_list.Managed([]const u8).init(gpa);
    defer sqls.deinit();
    var params = std.array_list.Managed(Value).init(gpa);
    defer params.deinit();

    var dsn: ?[]const u8 = null;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try usage(out);
            return exit_ok;
        }
        if (std.mem.eql(u8, arg, "--dsn") or std.mem.eql(u8, arg, "-d")) {
            dsn = (try optionValue(argv, &i, arg, err)) orelse return exit_unusable;
            continue;
        }
        if (std.mem.eql(u8, arg, "--sql")) {
            try sqls.append((try optionValue(argv, &i, arg, err)) orelse return exit_unusable);
            continue;
        }
        if (std.mem.eql(u8, arg, "--param")) {
            const value = (try optionValue(argv, &i, arg, err)) orelse return exit_unusable;
            // A prepare-only check cannot observe a parameter's type, only how
            // many there are, so every value goes in as text. See `usage`.
            try params.append(.{ .string = value });
            continue;
        }
        if (arg.len > 1 and arg[0] == '-') {
            try err.print("check_sql: unknown option '{s}'\n", .{arg});
            try err.writeAll("check_sql: run 'check_sql --help' for usage\n");
            return exit_unusable;
        }
        try files.append(arg);
    }

    if (files.items.len == 0 and sqls.items.len == 0) {
        try err.writeAll("check_sql: no input: pass one or more .sql files, or --sql \"SELECT 1\"\n");
        try err.writeAll("check_sql: run 'check_sql --help' for usage\n");
        return exit_unusable;
    }

    const connection_string = dsn orelse env_dsn orelse default_dsn;
    var connection = connectFromDsn(gpa, connection_string) catch |e| {
        try err.print("check_sql: cannot connect to '{s}': {s}\n", .{ connection_string, @errorName(e) });
        return exit_unusable;
    };
    defer connection.close();
    const drv = connection.asDriver();

    var stats = Stats{};
    try out.print("check_sql: {d} input(s) against {s} ({s})\n", .{
        files.items.len + sqls.items.len,
        drv.dialect().name,
        connection_string,
    });

    // Files first, each in the order given, then the `--sql` texts — the same
    // order the report prints in.
    for (files.items) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch |e| {
            try err.print("check_sql: cannot read '{s}': {s}\n", .{ path, @errorName(e) });
            return exit_unusable;
        };
        defer gpa.free(text);
        if (try checkText(gpa, drv, path, text, params.items, out, err, &stats) == .aborted) return exit_unusable;
    }
    for (sqls.items, 1..) |text, index| {
        const label = try std.fmt.allocPrint(gpa, "--sql#{d}", .{index});
        defer gpa.free(label);
        if (try checkText(gpa, drv, label, text, params.items, out, err, &stats) == .aborted) return exit_unusable;
    }

    try out.print("check_sql: {d} statement(s): {d} ok, {d} failed, {d} not_checkable\n", .{
        stats.statements, stats.ok, stats.failed, stats.not_checkable,
    });
    if (stats.not_checkable > 0) {
        try err.print(
            "check_sql: {d} statement(s) could not be judged by this channel (not_checkable) — that is not a failure, and the exit code says so\n",
            .{stats.not_checkable},
        );
    }
    if (stats.statements == 0) {
        try err.writeAll("check_sql: no statement found in the input (nothing but comments and whitespace?) — an empty run is a mistake, not a pass\n");
    }
    return exitCodeFor(stats);
}

const Outcome = enum { done, aborted };

/// Check every statement of one input, printing one conclusion line each.
/// `.aborted` means a check errored (the connection is gone), which stops the
/// run: the remaining statements cannot be judged either.
fn checkText(
    gpa: std.mem.Allocator,
    drv: sql_driver.Driver,
    label: []const u8,
    text: []const u8,
    params: []const Value,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    stats: *Stats,
) !Outcome {
    const statements = try splitStatements(gpa, text);
    defer gpa.free(statements);

    if (statements.len == 0) {
        stats.empty_inputs += 1;
        try err.print("check_sql: {s}: no statements (comments and whitespace only)\n", .{label});
        return .done;
    }

    for (statements) |statement| {
        var diagnosis = sql_statement.checkStatement(gpa, drv, statement.text, params) catch |e| {
            // The check failed; the statement was not judged. Counted apart
            // from `failed` so the report cannot be read as a verdict.
            stats.check_errors += 1;
            try err.print("check_sql: {s}:{d}: the check could not run: {s}\n", .{ label, statement.line, @errorName(e) });
            return .aborted;
        };
        defer sql_statement.freeStatementDiagnosis(gpa, &diagnosis);

        try writeConclusion(out, label, statement, diagnosis);
        stats.statements += 1;
        switch (diagnosis.status()) {
            .ok => stats.ok += 1,
            .failed => stats.failed += 1,
            .not_checkable => stats.not_checkable += 1,
        }
    }
    return .done;
}

/// `<input>:<line>: <status> problem=<p> [params=N] [native_code=N]
/// [sqlstate=...] [heuristic] [message="..."]` — one line, whatever the driver
/// put in the message.
fn writeConclusion(
    out: *std.Io.Writer,
    label: []const u8,
    statement: Statement,
    diagnosis: sql_statement.StatementDiagnosis,
) !void {
    try out.print("{s}:{d}: {s} problem={s}", .{
        label,
        statement.line,
        @tagName(diagnosis.status()),
        @tagName(diagnosis.problem),
    });
    if (diagnosis.param_count) |count| try out.print(" params={d}", .{count});
    if (diagnosis.native_code != 0) try out.print(" native_code={d}", .{diagnosis.native_code});
    if (diagnosis.sqlstate) |state| try out.print(" sqlstate={s}", .{state});
    // SQLite reports every prepare failure under one code, so its label is read
    // out of the message; the line says so instead of dressing it up.
    if (diagnosis.problem_heuristic) try out.writeAll(" heuristic");
    if (diagnosis.message) |message| {
        try out.writeAll(" message=");
        try writeQuoted(out, message);
    }
    try out.writeAll("\n");
}

/// Render text as a quoted one-liner: PostgreSQL's messages carry their own
/// trailing newlines, and a report line per statement is the contract.
fn writeQuoted(out: *std.Io.Writer, text: []const u8) !void {
    try out.writeByte('"');
    for (text) |byte| switch (byte) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        '\t' => try out.writeAll("\\t"),
        else => {
            if (byte < 0x20 or byte == 0x7f) {
                try out.print("\\x{x:0>2}", .{byte});
            } else {
                try out.writeByte(byte);
            }
        },
    };
    try out.writeByte('"');
}

fn optionValue(argv: []const []const u8, index: *usize, option: []const u8, err: *std.Io.Writer) !?[]const u8 {
    if (index.* + 1 >= argv.len) {
        try err.print("check_sql: {s} needs a value\n", .{option});
        try err.writeAll("check_sql: run 'check_sql --help' for usage\n");
        return null;
    }
    index.* += 1;
    return argv[index.*];
}

// ------------------------------------------------------------------
// Statement splitting
// ------------------------------------------------------------------

/// One statement, with where it came from. `text` borrows from the input it
/// was split out of.
pub const Statement = struct {
    text: []const u8,
    /// 1-based line of the input where the statement's first token sits.
    line: usize,
};

/// Split `source` into statements at the semicolons that are really statement
/// terminators. The returned slice owns nothing but itself: every `text` points
/// into `source`, which the caller must keep alive. Free it with
/// `allocator.free`.
///
/// A trailing statement without a semicolon is returned too (a one-statement
/// file usually has no need for one), and whitespace, comments and empty
/// statements produce nothing at all.
pub fn splitStatements(allocator: std.mem.Allocator, source: []const u8) ![]Statement {
    var list = std.array_list.Managed(Statement).init(allocator);
    errdefer list.deinit();

    var i: usize = 0;
    var line: usize = 1;
    // Index of the first token of the statement being collected, if any.
    var start: ?usize = null;
    var start_line: usize = 1;

    while (i < source.len) {
        const byte = source[i];

        if (byte == '\n') {
            line += 1;
            i += 1;
            continue;
        }
        if (byte == ' ' or byte == '\t' or byte == '\r') {
            i += 1;
            continue;
        }
        // Comments: skipped, and never part of a statement's first token, so
        // the reported line is the statement's own.
        if (byte == '-' and i + 1 < source.len and source[i + 1] == '-') {
            i = skipLineComment(source, i);
            continue;
        }
        if (byte == '/' and i + 1 < source.len and source[i + 1] == '*') {
            const from = i;
            i = skipBlockComment(source, i);
            line += newlinesIn(source[from..i]);
            continue;
        }
        if (byte == '\'' or byte == '"' or byte == '`') {
            if (start == null) {
                start = i;
                start_line = line;
            }
            const from = i;
            i = skipQuoted(source, i, byte);
            line += newlinesIn(source[from..i]);
            continue;
        }
        if (byte == '$') {
            if (skipDollarQuoted(source, i)) |end| {
                if (start == null) {
                    start = i;
                    start_line = line;
                }
                line += newlinesIn(source[i..end]);
                i = end;
                continue;
            }
        }
        if (byte == ';') {
            if (start) |from| {
                const text = std.mem.trim(u8, source[from..i], " \t\r\n");
                if (text.len > 0) try list.append(.{ .text = text, .line = start_line });
            }
            start = null;
            i += 1;
            continue;
        }
        if (start == null) {
            start = i;
            start_line = line;
        }
        i += 1;
    }

    // The last statement of a file needs no semicolon.
    if (start) |from| {
        const text = std.mem.trim(u8, source[from..], " \t\r\n");
        if (text.len > 0) try list.append(.{ .text = text, .line = start_line });
    }

    return list.toOwnedSlice();
}

/// End of a `-- comment`: the newline that ends it stays for the caller to
/// consume, since it moves the line counter.
fn skipLineComment(source: []const u8, start: usize) usize {
    return std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
}

/// End of a `/* comment */`, past the closing delimiter. Nesting is honoured
/// the way PostgreSQL honours it: SQLite and MySQL do not nest, and a nested
/// comment is a syntax error for them either way, so reading it as one comment
/// keeps the statement intact for the engine that allows it.
fn skipBlockComment(source: []const u8, start: usize) usize {
    var depth: usize = 0;
    var i = start;
    while (i + 1 < source.len) {
        if (source[i] == '/' and source[i + 1] == '*') {
            depth += 1;
            i += 2;
            continue;
        }
        if (source[i] == '*' and source[i + 1] == '/') {
            depth -= 1;
            i += 2;
            if (depth == 0) return i;
            continue;
        }
        i += 1;
    }
    return source.len;
}

/// End of a quoted run: a string literal, or an identifier quoted with `"` or a
/// backtick. A doubled quote is an escaped one, not the end. An unterminated
/// quote runs to the end of the input, which the database then reports as a
/// syntax error rather than the splitter quietly dropping the text.
fn skipQuoted(source: []const u8, start: usize, quote: u8) usize {
    var i = start + 1;
    while (i < source.len) {
        if (source[i] == quote) {
            if (i + 1 < source.len and source[i + 1] == quote) {
                i += 2;
                continue;
            }
            return i + 1;
        }
        i += 1;
    }
    return source.len;
}

/// End of a PostgreSQL `$tag$ ... $tag$` body, or null when the `$` opens no
/// such body (`$1`, a `$` inside an identifier). Like the quotes, an
/// unterminated body runs to the end of the input.
///
/// The caller does not know the dialect yet — the splitter runs before the
/// connection exists — so dollar-quoting is honoured everywhere. Outside
/// PostgreSQL it only fires on text that would not be valid SQL anyway.
fn skipDollarQuoted(source: []const u8, start: usize) ?usize {
    var i = start + 1;
    while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) : (i += 1) {}
    if (i >= source.len or source[i] != '$') return null;
    // `$1` is a parameter, not the start of a body: a tag may not start with a
    // digit, and PostgreSQL's lexer reads digits as the parameter number.
    if (i > start + 1 and std.ascii.isDigit(source[start + 1])) return null;

    const delimiter = source[start .. i + 1];
    const body_end = std.mem.indexOfPos(u8, source, i + 1, delimiter) orelse return source.len;
    return body_end + delimiter.len;
}

fn newlinesIn(text: []const u8) usize {
    return std.mem.count(u8, text, "\n");
}

// ------------------------------------------------------------------
// Connection
// ------------------------------------------------------------------

/// Same DSN shape the migrate example takes: `sqlite:<path>`, `postgres://…`,
/// `mysql://…`.
const AnyDriver = union(enum) {
    sqlite: SQLiteDriver,
    postgres: PostgresDriver,
    mysql: MySQLDriver,

    fn asDriver(self: *AnyDriver) sql_driver.Driver {
        switch (self.*) {
            .sqlite => |*drv| return drv.asDriver(),
            .postgres => |*drv| {
                if (comptime build_options.have_pg) return drv.asDriver();
                unreachable;
            },
            .mysql => |*drv| {
                if (comptime build_options.have_mysql) return drv.asDriver();
                unreachable;
            },
        }
    }

    fn close(self: *AnyDriver) void {
        switch (self.*) {
            .sqlite => |*drv| drv.close(),
            .postgres => |*drv| {
                if (comptime build_options.have_pg) drv.close();
            },
            .mysql => |*drv| {
                if (comptime build_options.have_mysql) drv.close();
            },
        }
    }
};

fn connectFromDsn(allocator: std.mem.Allocator, dsn: []const u8) !AnyDriver {
    if (std.mem.startsWith(u8, dsn, "sqlite:")) {
        const path = dsn[7..];
        return .{ .sqlite = try SQLiteDriver.open(allocator, path) };
    }

    if (std.mem.startsWith(u8, dsn, "postgres://") or std.mem.startsWith(u8, dsn, "postgresql://")) {
        if (comptime build_options.have_pg) {
            return .{ .postgres = try PostgresDriver.connect(allocator, dsn) };
        }
        return error.UnsupportedDriver;
    }

    if (std.mem.startsWith(u8, dsn, "mysql://")) {
        if (comptime build_options.have_mysql) {
            return .{ .mysql = try connectMysql(allocator, dsn[8..]) };
        }
        return error.UnsupportedDriver;
    }

    // libpq takes its own keyword/value conninfo (`host=… dbname=… user=…`), not
    // only a URI, and that is the shape `PG_DSN` has in CI. The migrate example
    // stops at the URI, which would make this tool unusable with the DSN a
    // project already has in its environment.
    if (comptime build_options.have_pg) {
        if (isPgKeywordConninfo(dsn)) {
            return .{ .postgres = try PostgresDriver.connect(allocator, dsn) };
        }
    }

    return error.UnsupportedDriver;
}

/// `host=… dbname=…`: a keyword/value conninfo rather than a URI or a path.
fn isPgKeywordConninfo(dsn: []const u8) bool {
    const equals = std.mem.indexOfScalar(u8, dsn, '=') orelse return false;
    const colon = std.mem.indexOfScalar(u8, dsn, ':');
    return colon == null or colon.? > equals;
}

const MysqlDsn = struct {
    user: []const u8,
    pass: []const u8,
    host: []const u8,
    port: u32,
    db: []const u8,
};

/// The MariaDB client copies the strings it is handed while connecting, so the
/// parsing scratch and the sentinels live in an arena that ends with this call.
/// (examples/migrate/main.zig connects the same way.)
fn connectMysql(allocator: std.mem.Allocator, rest: []const u8) !MySQLDriver {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const parsed = try parseMysqlDsn(arena, rest);
    return MySQLDriver.connect(
        allocator,
        try arena.dupeSentinel(u8, parsed.host, 0),
        parsed.port,
        try arena.dupeSentinel(u8, parsed.user, 0),
        try arena.dupeSentinel(u8, parsed.pass, 0),
        try arena.dupeSentinel(u8, parsed.db, 0),
    );
}

fn parseMysqlDsn(allocator: std.mem.Allocator, s: []const u8) !MysqlDsn {
    // Expected: user:pass@host:port/db
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return error.InvalidDsn;
    const creds = s[0..at];
    const host_port_db = s[at + 1 ..];

    const colon = std.mem.indexOfScalar(u8, creds, ':');
    const user = if (colon) |c| creds[0..c] else creds;
    const pass = if (colon) |c| creds[c + 1 ..] else "";

    const slash = std.mem.indexOfScalar(u8, host_port_db, '/') orelse return error.InvalidDsn;
    const host_port = host_port_db[0..slash];
    const db = host_port_db[slash + 1 ..];

    const port_colon = std.mem.indexOfScalar(u8, host_port, ':');
    const host = if (port_colon) |c| host_port[0..c] else host_port;
    const port: u32 = if (port_colon) |c| try std.fmt.parseInt(u32, host_port[c + 1 ..], 10) else 3306;

    return MysqlDsn{
        .user = try allocator.dupe(u8, user),
        .pass = try allocator.dupe(u8, pass),
        .host = try allocator.dupe(u8, host),
        .port = port,
        .db = try allocator.dupe(u8, db),
    };
}

// ------------------------------------------------------------------
// Help
// ------------------------------------------------------------------

pub fn usage(out: *std.Io.Writer) !void {
    try out.writeAll(help_text);
}

const help_text =
    \\check_sql — check raw SQL against a database without running it
    \\            (zent.sql_statement.checkStatement)
    \\
    \\Usage:
    \\  check_sql [options] file.sql [file2.sql ...]
    \\  check_sql [options] --sql "SELECT * FROM t WHERE id = 1"
    \\
    \\Every statement of the input is prepared with the driver and discarded:
    \\tables, columns, parameter counts and syntax are checked, and nothing is
    \\executed — a checked INSERT inserts nothing. One line per statement, then
    \\a summary line.
    \\
    \\Options:
    \\  -h, --help        Print this help and exit 0.
    \\  -d, --dsn <dsn>   What to check against. Default: $ZENT_DSN, else
    \\                    "sqlite::memory:".
    \\                      sqlite:<path>                    sqlite:app.db
    \\                      sqlite::memory:
    \\                      postgres://user:pw@host:port/db
    \\                      mysql://user:pw@host:port/db
    \\                    A PostgreSQL keyword/value conninfo works too, since
    \\                    that is the shape PG_DSN usually has:
    \\                      "host=localhost dbname=zent_test user=postgres"
    \\      --sql <text>  Check <text> instead of a file. Repeatable. Files are
    \\                    checked first, each list in the order given.
    \\      --param <val> Parameter passed to every statement checked
    \\                    (repeatable). The values exist so the parameter
    \\                    *count* can match: a prepare-only check never binds
    \\                    them to anything it runs, and cannot see a parameter's
    \\                    type, so every value is passed as text.
    \\
    \\Statement splitting:
    \\  A semicolon ends a statement only outside of 'strings', "quoted
    \\  identifiers", `backtick identifiers`, -- line comments, /* block
    \\  comments */ (nested, the way PostgreSQL nests them) and $tag$ dollar
    \\  quoted $tag$ bodies. Semicolons inside those do not split, and the last
    \\  statement of an input needs no trailing semicolon.
    \\  Known limits: '#' does not start a comment (MySQL only), a backslash
    \\  does not escape a quote inside a string (MySQL without
    \\  NO_BACKSLASH_ESCAPES), and an unterminated quote or comment swallows the
    \\  rest of the input into one statement — the database then reports it as a
    \\  syntax error rather than the splitter dropping text in silence.
    \\
    \\What "failed" means per dialect — prepare is not the same question
    \\everywhere:
    \\  sqlite    SQLite resolves tables and columns while preparing, so unknown
    \\            relations, unknown columns, arity mistakes and parse errors all
    \\            surface here. Every one arrives as SQLITE_ERROR with the reason
    \\            only in the message, so the label is read from the text and the
    \\            line says `heuristic` when it is. Constraints (NOT NULL,
    \\            CHECK, UNIQUE, foreign keys) are evaluated while stepping —
    \\            this never steps, so they are not detected.
    \\  postgres  Parses and plans, so syntax errors, unknown relations and
    \\            columns, and parameter typing are caught; `sqlstate` carries
    \\            the class (42601 syntax, 42P01 unknown table, 42703 unknown
    \\            column). 25P02 (a statement attempted in an aborted
    \\            transaction) and 0A000 come back `not_checkable`: they are
    \\            about the situation, not about the SQL.
    \\  mysql     The same class of failures from mysql_stmt_prepare, with errno
    \\            as a structured code (1064 syntax, 1146/1109 unknown table,
    \\            1054 unknown column). Two boundaries: constraints are invisible
    \\            until execution, and statements the prepared-statement protocol
    \\            refuses although they are valid SQL (BEGIN, LOCK TABLES, ... —
    \\            errno 1295) come back `not_checkable`.
    \\  On every dialect a `not_checkable` statement is not a failure: it means
    \\  this channel cannot judge it, and it does not change the exit code. The
    \\  summary counts such statements separately for that reason.
    \\
    \\Exit codes:
    \\  0  every statement prepared cleanly, or could not be judged
    \\     (not_checkable)
    \\  1  at least one statement failed to prepare
    \\  2  the run itself could not happen: bad options, an unreadable file, no
    \\     connection, a check that errored — or no statement found at all
    \\
;
