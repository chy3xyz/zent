//! `checkStatement`: is this raw statement runnable, and if not, what did the
//! server say?
//!
//! The entry point prepares `sql` with `args` through the driver and **discards
//! it without executing anything** — `sqlite3_prepare_v2` with no step,
//! `PQprepare` with no Bind, `mysql_stmt_prepare` with no execute. A checked
//! `INSERT` inserts nothing (there is a test per dialect for exactly that, plus
//! UPDATE/DELETE on SQLite) — and prepare only compiles, so neither does
//! anything else that is checked. That is the whole point: hundreds of
//! hand-written statements and no way to ask a database about them short of
//! running them.
//!
//! ```zig
//! var d = try checkStatement(allocator, drv.asDriver(), "SELECT * FROM users WHERE id = ?", &.{.{ .int = 1 }});
//! defer freeStatementDiagnosis(allocator, &d);
//! if (d.problem == .missing_column) std.log.warn("{s}: {s}", .{ sql, d.message.? });
//! ```
//!
//! # What each dialect can see at this stage
//!
//! Prepare is not the same question in the three engines, and this module does
//! not pretend otherwise. What a `failed` diagnosis means, per dialect:
//!
//! - **SQLite** resolves every table and column while preparing, so unknown
//!   relations, unknown columns, arity mistakes and parse errors are all caught
//!   here. All of them arrive as `SQLITE_ERROR` with the reason only in the
//!   message, so `problem_heuristic` is set when the label was read from the
//!   text. Constraints (NOT NULL, CHECK, UNIQUE, foreign keys) are **not**
//!   detected: SQLite evaluates them while stepping, which this never does.
//!   Only the first statement of a multi-statement string is prepared, matching
//!   what `exec` would run.
//! - **PostgreSQL** parses and plans (Parse + Describe), so syntax errors,
//!   unknown relations/columns and parameter typing are caught; SQLSTATE carries
//!   the class (`42P01` undefined_table, `42703` undefined_column, `42601`
//!   syntax_error, `42P18` indeterminate_datatype). Constraint violations are
//!   not detected — they happen during execution. A multi-statement string is
//!   rejected here (`42601`), because `PQexecParams` rejects it too.
//! - **MySQL** catches the same syntax/table/column class from
//!   `mysql_stmt_prepare`, with errno (`1064`, `1146`, `1054`) as a structured
//!   code. Two boundaries: constraints are invisible until execution, and the
//!   prepared-statement protocol rejects statements that are nevertheless valid
//!   SQL (`BEGIN`, `LOCK TABLES`, ... — errno 1295). Those come back as
//!   `not_checkable`, never as `failed`.
//!
//! A dialect that has no prepare channel at all — a driver that does not
//! implement `VTable.prepareCheck` — is `not_checkable` too, with a message
//! saying so, rather than an error to fish out of a batch loop.
//!
//! For those `not_checkable` cases `explain.zig`'s `explainSql` builds the
//! dialect's own EXPLAIN statement for the caller to run instead. It is
//! deliberately not wired in here: EXPLAIN takes no arguments, so it cannot
//! validate the binding this entry point exists for, and on MySQL it answers
//! "syntax error" for exactly the statements the prepare channel honestly
//! reports as unjudgeable (`EXPLAIN BEGIN` is not valid either).
//!
//! # Errors
//!
//! The error union is for the *check* failing (a dead connection, OOM), not for
//! the statement failing: a statement that does not prepare is data, and comes
//! back as `Status.failed`. `driver.classify` answers capacity/transient/
//! client/bug for the error union; a `failed` diagnosis is always the
//! statement's own fault.

const std = @import("std");
const Dialect = @import("dialect.zig").Dialect;
const sql_driver = @import("driver.zig");
const Value = @import("builder.zig").Value;

/// The one-line answer to "can this statement run?".
pub const Status = enum {
    /// It prepared with the supplied `args`.
    ok,
    /// The statement is the problem: it does not prepare, or `args` does not
    /// match its parameters.
    failed,
    /// Nothing was learned, and nothing ran. See `Problem.not_checkable`.
    not_checkable,
};

/// Why the answer came out the way it did.
pub const Problem = enum {
    none,
    /// The parser rejected the text.
    syntax,
    /// It names a table or view that does not exist.
    missing_relation,
    /// It names a column that does not exist in the table it is used against.
    missing_column,
    /// `args` is not what the statement takes: `param_count` says what it
    /// wants.
    ///
    /// Whether execution would also fail is dialect-specific — MySQL's driver
    /// refuses any difference, PostgreSQL refuses a missing parameter at Bind
    /// time, while SQLite binds an absent one as NULL and ignores an extra one.
    /// A mismatch is reported as `failed` on all three: a statement that runs
    /// with an unbound parameter is the "endpoint returned empty for months"
    /// class of bug, and `param_count` is there for a caller that wants to
    /// decide otherwise.
    parameter_mismatch,
    /// `sql` is empty or all whitespace, so there is nothing to prepare. The
    /// dialects disagree about that (PostgreSQL prepares `""` without
    /// complaint, MySQL answers errno 1065, SQLite hands back a null statement),
    /// so it is answered here rather than by whichever driver happens to be
    /// underneath.
    empty,
    /// This channel cannot judge the statement: the driver implements no
    /// prepare check, or its prepare protocol does not accept this kind of
    /// statement (MySQL errno 1295 — `BEGIN`, `LOCK TABLES`, ...). Says nothing
    /// about whether the statement is valid.
    not_checkable,
    /// The driver reported a failure this module does not classify. `message`
    /// and `native_code`/`sqlstate` are the authoritative parts.
    other,
};

/// What a driver had to say about a statement. Owns text; release it with
/// `freeStatementDiagnosis`.
pub const StatementDiagnosis = struct {
    problem: Problem = .none,
    /// True when `problem` was read out of the driver's message text instead of
    /// a structured code: SQLite reports every prepare failure as
    /// `SQLITE_ERROR`, so its `syntax` / `missing_relation` / `missing_column`
    /// can only come from the message. The message is always the truth; this
    /// says how much to trust the label beside it.
    problem_heuristic: bool = false,
    /// The dialect's own numeric code: SQLite's extended result code, MySQL's
    /// errno. PostgreSQL has no numeric code (see `sqlstate`), so it stays 0
    /// there.
    native_code: i32 = 0,
    /// PostgreSQL's SQLSTATE, e.g. `"42P01"`. Null on the other dialects, which
    /// do not report one.
    sqlstate: ?[]const u8 = null,
    /// The driver's own error text. Null when the driver had nothing to say: on
    /// a clean check, and on a mismatch, where the text is synthesized here
    /// because there is no driver error to quote.
    message: ?[]const u8 = null,
    /// How many parameters the statement takes, when the channel could report
    /// it.
    param_count: ?usize = null,

    pub fn status(self: StatementDiagnosis) Status {
        return switch (self.problem) {
            .none => .ok,
            .not_checkable => .not_checkable,
            else => .failed,
        };
    }

    pub fn isOk(self: StatementDiagnosis) bool {
        return self.problem == .none;
    }
};

/// Release the text a diagnosis owns. A no-op after the first call: the fields
/// come back null, so the second call cannot double-free.
pub fn freeStatementDiagnosis(allocator: std.mem.Allocator, diagnosis: *StatementDiagnosis) void {
    if (diagnosis.sqlstate) |s| allocator.free(s);
    if (diagnosis.message) |m| allocator.free(m);
    diagnosis.* = .{};
}

/// Prepare `sql` with `args` through `drv` and throw it away — see the module
/// doc for what each dialect can and cannot see at that stage.
///
/// Nothing is executed: this validates, it does not try-and-roll-back.
pub fn checkStatement(
    allocator: std.mem.Allocator,
    drv: sql_driver.Driver,
    sql: []const u8,
    args: []const Value,
) !StatementDiagnosis {
    const trimmed = std.mem.trim(u8, sql, " \t\r\n");
    if (trimmed.len == 0) {
        return .{ .problem = .empty, .message = try allocator.dupe(u8, "the statement is empty") };
    }

    var report: sql_driver.CheckReport = .{};
    // Frees what is left behind on an error out of `prepareCheck` after it has
    // already allocated, and nothing at all once the move below has happened.
    defer report.deinit(allocator);
    try drv.prepareCheck(allocator, sql, args, &report);

    // Ownership of the driver's text transfers to the diagnosis here.
    const kind = report.kind;
    var diagnosis = StatementDiagnosis{
        .native_code = report.native_code,
        .sqlstate = report.sqlstate,
        .message = report.message,
        .param_count = report.param_count,
    };
    report = .{};
    errdefer freeStatementDiagnosis(allocator, &diagnosis);

    switch (kind) {
        .ok => {},
        .prepare_failed => {
            const classified = classify(drv.dialect(), diagnosis);
            diagnosis.problem = classified.problem;
            diagnosis.problem_heuristic = classified.heuristic;
        },
        .param_mismatch => {
            diagnosis.problem = .parameter_mismatch;
            if (diagnosis.message == null) {
                diagnosis.message = if (diagnosis.param_count) |n|
                    try std.fmt.allocPrint(allocator, "the statement takes {d} parameter(s), {d} were supplied", .{ n, args.len })
                else
                    try std.fmt.allocPrint(allocator, "the statement does not take the {d} supplied parameter(s)", .{args.len});
            }
        },
        .unsupported => {
            diagnosis.problem = .not_checkable;
            if (diagnosis.message == null and drv.vtable.prepareCheck == null) {
                diagnosis.message = try allocator.dupe(u8, "the driver implements no statement check (VTable.prepareCheck)");
            }
        },
    }
    return diagnosis;
}

const Classification = struct {
    problem: Problem,
    heuristic: bool = false,
};

/// Label a driver failure. SQLite's prepare failures all carry one code, so its
/// label is read from the message and flagged as a heuristic; PostgreSQL and
/// MySQL both hand back a structured code, and their labels are certain.
fn classify(dialect: Dialect, diagnosis: StatementDiagnosis) Classification {
    return switch (dialect.kind()) {
        .mysql => classifyMysql(diagnosis.native_code),
        .postgres => classifyPostgres(diagnosis.sqlstate orelse ""),
        .sqlite => classifySqlite(diagnosis.message orelse ""),
        // A dialect this code does not know carries no code to read, so it
        // stays undiagnosed rather than borrowing another server's numbering.
        .unknown => .{ .problem = .other },
    };
}

/// MySQL errno: 1064 ER_PARSE_ERROR, 1146 ER_NO_SUCH_TABLE, 1109
/// ER_UNKNOWN_TABLE, 1054 ER_BAD_FIELD_ERROR.
fn classifyMysql(errno: i32) Classification {
    return .{ .problem = switch (errno) {
        1064 => .syntax,
        1146, 1109 => .missing_relation,
        1054 => .missing_column,
        else => .other,
    } };
}

/// PostgreSQL SQLSTATE. 25P02 (a statement attempted in an aborted transaction)
/// and 0A000 (feature_not_supported) are about the situation rather than the
/// statement, and are reported as such instead of as a defect.
fn classifyPostgres(sqlstate: []const u8) Classification {
    if (sqlstate.len < 5) return .{ .problem = .other };
    const code = sqlstate[0..5];
    if (std.mem.eql(u8, code, "42601")) return .{ .problem = .syntax };
    if (std.mem.eql(u8, code, "42P01")) return .{ .problem = .missing_relation };
    if (std.mem.eql(u8, code, "3F000")) return .{ .problem = .missing_relation };
    if (std.mem.eql(u8, code, "3D000")) return .{ .problem = .missing_relation };
    if (std.mem.eql(u8, code, "42703")) return .{ .problem = .missing_column };
    if (std.mem.eql(u8, code, "42P18")) return .{ .problem = .parameter_mismatch };
    if (std.mem.eql(u8, code, "42P02")) return .{ .problem = .parameter_mismatch };
    if (std.mem.eql(u8, code, "0A000")) return .{ .problem = .not_checkable };
    if (std.mem.eql(u8, code, "25P02")) return .{ .problem = .not_checkable };
    return .{ .problem = .other };
}

/// SQLite hands back `SQLITE_ERROR` (extended code 1) for every prepare
/// failure, so the class has to come from the message text: `no such table: x`,
/// `no such column: x`, `table t has N columns but M values were supplied`,
/// `near "...": syntax error`, `incomplete input`.
fn classifySqlite(message: []const u8) Classification {
    if (std.mem.indexOf(u8, message, "no such table:") != null) return .{ .problem = .missing_relation, .heuristic = true };
    if (std.mem.indexOf(u8, message, "no such column:") != null) return .{ .problem = .missing_column, .heuristic = true };
    if (std.mem.indexOf(u8, message, "has no column named") != null) return .{ .problem = .missing_column, .heuristic = true };
    if (std.mem.indexOf(u8, message, "syntax error") != null) return .{ .problem = .syntax, .heuristic = true };
    if (std.mem.indexOf(u8, message, "incomplete input") != null) return .{ .problem = .syntax, .heuristic = true };
    if (std.mem.indexOf(u8, message, "unrecognized token") != null) return .{ .problem = .syntax, .heuristic = true };
    return .{ .problem = .other };
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

/// A driver that answers `prepareCheck` from a script instead of a database.
const MockState = struct {
    /// What the hook reports. Text in here borrows program literals; the hook
    /// copies it with the caller's allocator, as the real drivers do.
    report: sql_driver.CheckReport = .{},
    dialect: Dialect = Dialect.sqlite,
    calls: usize = 0,
    last_sql: []const u8 = "",
    last_args_len: usize = 0,
    /// When set, the hook fails after it has already allocated a message — the
    /// shape a real driver has when it runs out of memory mid-report. The
    /// allocation is deliberately left in `out`; what frees it is the caller's
    /// ownership of the report, which is the point of the test that uses this.
    fail_after_alloc: bool = false,
};

fn mockPrepareCheck(ptr: *anyopaque, allocator: std.mem.Allocator, sql: []const u8, args: []const Value, out: *sql_driver.CheckReport) sql_driver.Error!void {
    const s: *MockState = @ptrCast(@alignCast(ptr));
    s.calls += 1;
    s.last_sql = sql;
    s.last_args_len = args.len;
    out.* = .{
        .kind = s.report.kind,
        .native_code = s.report.native_code,
        .param_count = s.report.param_count,
    };
    if (s.report.message) |m| out.message = try allocator.dupe(u8, m);
    if (s.report.sqlstate) |ss| out.sqlstate = try allocator.dupe(u8, ss);
    if (s.fail_after_alloc) return error.ConnectionFailed;
}

const mock_vtable = sql_driver.Driver.VTable{
    .exec = struct {
        fn f(_: *anyopaque, _: ?*const sql_driver.ExecutionContext, _: []const u8, _: []const Value) sql_driver.Error!sql_driver.Result {
            unreachable;
        }
    }.f,
    .query = struct {
        fn f(_: *anyopaque, _: ?*const sql_driver.ExecutionContext, _: []const u8, _: []const Value) sql_driver.Error!sql_driver.Rows {
            unreachable;
        }
    }.f,
    .prepareCheck = mockPrepareCheck,
    .beginTx = struct {
        fn f(_: *anyopaque) sql_driver.Error!sql_driver.Tx {
            unreachable;
        }
    }.f,
    .close = struct {
        fn f(_: *anyopaque) void {}
    }.f,
    .dialect = struct {
        fn f(ptr: *anyopaque) Dialect {
            return (@as(*MockState, @ptrCast(@alignCast(ptr)))).dialect;
        }
    }.f,
    .ping = struct {
        fn f(_: *anyopaque) sql_driver.Error!void {}
    }.f,
    .inTransaction = struct {
        fn f(_: *anyopaque) bool {
            return false;
        }
    }.f,
    .beginSavepoint = struct {
        fn f(_: *anyopaque, _: []const u8) sql_driver.Error!sql_driver.Tx {
            unreachable;
        }
    }.f,
};

/// The same driver, with no prepare channel of its own.
const mock_vtable_no_hook: sql_driver.Driver.VTable = blk: {
    var v = mock_vtable;
    v.prepareCheck = null;
    break :blk v;
};

fn mockDriver(state: *MockState) sql_driver.Driver {
    return .{ .ptr = state, .vtable = &mock_vtable };
}

test "checkStatement reports a statement the driver prepared cleanly as ok" {
    const allocator = std.testing.allocator;
    var state = MockState{ .report = .{ .kind = .ok, .param_count = 2 } };

    var d = try checkStatement(allocator, mockDriver(&state), "SELECT * FROM t WHERE a = ? AND b = ?", &.{ .{ .int = 1 }, .{ .int = 2 } });
    defer freeStatementDiagnosis(allocator, &d);

    try std.testing.expectEqual(Status.ok, d.status());
    try std.testing.expect(d.isOk());
    try std.testing.expectEqual(Problem.none, d.problem);
    try std.testing.expectEqual(@as(?usize, 2), d.param_count);
    try std.testing.expect(d.message == null);
    try std.testing.expect(d.sqlstate == null);
    // The statement and the args reached the driver, they were not invented.
    try std.testing.expectEqualStrings("SELECT * FROM t WHERE a = ? AND b = ?", state.last_sql);
    try std.testing.expectEqual(@as(usize, 2), state.last_args_len);
}

test "checkStatement answers an empty statement itself, without asking the driver" {
    const allocator = std.testing.allocator;
    var state = MockState{ .report = .{ .kind = .ok } };

    var d = try checkStatement(allocator, mockDriver(&state), "  \t\n ", &.{});
    defer freeStatementDiagnosis(allocator, &d);

    try std.testing.expectEqual(Problem.empty, d.problem);
    try std.testing.expectEqual(Status.failed, d.status());
    try std.testing.expectEqualStrings("the statement is empty", d.message.?);
    // PostgreSQL would have said ok to `""` and MySQL would have said errno
    // 1065; the answer does not depend on which driver is underneath.
    try std.testing.expectEqual(@as(usize, 0), state.calls);
}

test "checkStatement labels a MySQL failure from errno and passes the text through" {
    const allocator = std.testing.allocator;

    {
        var state = MockState{
            .dialect = Dialect.mysql,
            .report = .{ .kind = .prepare_failed, .native_code = 1146, .message = "Table 'zent_test.no_such' doesn't exist" },
        };
        var d = try checkStatement(allocator, mockDriver(&state), "SELECT * FROM no_such", &.{});
        defer freeStatementDiagnosis(allocator, &d);
        try std.testing.expectEqual(Problem.missing_relation, d.problem);
        try std.testing.expectEqual(Status.failed, d.status());
        try std.testing.expectEqual(@as(i32, 1146), d.native_code);
        try std.testing.expectEqualStrings("Table 'zent_test.no_such' doesn't exist", d.message.?);
        // A structured code, so the label is not a guess.
        try std.testing.expect(!d.problem_heuristic);
    }
    {
        var state = MockState{
            .dialect = Dialect.mysql,
            .report = .{ .kind = .prepare_failed, .native_code = 1064, .message = "You have an error in your SQL syntax; ... near 'SELEC 1' at line 1" },
        };
        var d = try checkStatement(allocator, mockDriver(&state), "SELEC 1", &.{});
        defer freeStatementDiagnosis(allocator, &d);
        try std.testing.expectEqual(Problem.syntax, d.problem);
        try std.testing.expect(!d.problem_heuristic);
    }
    {
        var state = MockState{
            .dialect = Dialect.mysql,
            .report = .{ .kind = .prepare_failed, .native_code = 1054, .message = "Unknown column 'bogus' in 'field list'" },
        };
        var d = try checkStatement(allocator, mockDriver(&state), "SELECT bogus FROM t", &.{});
        defer freeStatementDiagnosis(allocator, &d);
        try std.testing.expectEqual(Problem.missing_column, d.problem);
    }
}

test "checkStatement labels a PostgreSQL failure from SQLSTATE" {
    const allocator = std.testing.allocator;

    {
        var state = MockState{
            .dialect = Dialect.postgres,
            .report = .{ .kind = .prepare_failed, .sqlstate = "42P01", .message = "ERROR:  relation \"no_such_table\" does not exist\n" },
        };
        var d = try checkStatement(allocator, mockDriver(&state), "SELECT * FROM no_such_table", &.{});
        defer freeStatementDiagnosis(allocator, &d);
        try std.testing.expectEqual(Problem.missing_relation, d.problem);
        try std.testing.expectEqualStrings("42P01", d.sqlstate.?);
        try std.testing.expect(!d.problem_heuristic);
        try std.testing.expect(std.mem.indexOf(u8, d.message.?, "does not exist") != null);
    }
    {
        var state = MockState{
            .dialect = Dialect.postgres,
            .report = .{ .kind = .prepare_failed, .sqlstate = "42703", .message = "ERROR:  column \"bogus\" does not exist\n" },
        };
        var d = try checkStatement(allocator, mockDriver(&state), "SELECT bogus FROM t", &.{});
        defer freeStatementDiagnosis(allocator, &d);
        try std.testing.expectEqual(Problem.missing_column, d.problem);
    }
    {
        var state = MockState{
            .dialect = Dialect.postgres,
            .report = .{ .kind = .prepare_failed, .sqlstate = "42601", .message = "ERROR:  syntax error at or near \"SELEC\"\n" },
        };
        var d = try checkStatement(allocator, mockDriver(&state), "SELEC 1", &.{});
        defer freeStatementDiagnosis(allocator, &d);
        try std.testing.expectEqual(Problem.syntax, d.problem);
    }
    {
        // 25P02 is the situation, not the statement: the caller's transaction
        // was already aborted, so this says nothing about the SQL.
        var state = MockState{
            .dialect = Dialect.postgres,
            .report = .{ .kind = .prepare_failed, .sqlstate = "25P02", .message = "ERROR:  current transaction is aborted\n" },
        };
        var d = try checkStatement(allocator, mockDriver(&state), "SELECT 1", &.{});
        defer freeStatementDiagnosis(allocator, &d);
        try std.testing.expectEqual(Problem.not_checkable, d.problem);
        try std.testing.expectEqual(Status.not_checkable, d.status());
    }
}

test "checkStatement labels a SQLite failure from the message and says so" {
    const allocator = std.testing.allocator;

    {
        var state = MockState{
            .report = .{ .kind = .prepare_failed, .native_code = 1, .message = "no such table: users" },
        };
        var d = try checkStatement(allocator, mockDriver(&state), "SELECT * FROM users", &.{});
        defer freeStatementDiagnosis(allocator, &d);
        try std.testing.expectEqual(Problem.missing_relation, d.problem);
        try std.testing.expectEqual(@as(i32, 1), d.native_code);
        try std.testing.expectEqualStrings("no such table: users", d.message.?);
        // SQLite's code is 1 whatever went wrong, so the label is a heuristic
        // and the diagnosis admits it.
        try std.testing.expect(d.problem_heuristic);
    }
    {
        var state = MockState{
            .report = .{ .kind = .prepare_failed, .native_code = 1, .message = "no such column: bogus" },
        };
        var d = try checkStatement(allocator, mockDriver(&state), "SELECT bogus FROM t", &.{});
        defer freeStatementDiagnosis(allocator, &d);
        try std.testing.expectEqual(Problem.missing_column, d.problem);
        try std.testing.expect(d.problem_heuristic);
    }
    {
        var state = MockState{
            .report = .{ .kind = .prepare_failed, .native_code = 1, .message = "near \"SELEC\": syntax error" },
        };
        var d = try checkStatement(allocator, mockDriver(&state), "SELEC 1", &.{});
        defer freeStatementDiagnosis(allocator, &d);
        try std.testing.expectEqual(Problem.syntax, d.problem);
        try std.testing.expect(d.problem_heuristic);
    }
    {
        // A message this module does not recognise stays `other`: the label is
        // not guessed at, and `problem_heuristic` is false because nothing was
        // inferred.
        var state = MockState{
            .report = .{ .kind = .prepare_failed, .native_code = 1, .message = "table t has 2 columns but 3 values were supplied" },
        };
        var d = try checkStatement(allocator, mockDriver(&state), "INSERT INTO t VALUES (1, 2, 3)", &.{});
        defer freeStatementDiagnosis(allocator, &d);
        try std.testing.expectEqual(Problem.other, d.problem);
        try std.testing.expect(!d.problem_heuristic);
        try std.testing.expectEqualStrings("table t has 2 columns but 3 values were supplied", d.message.?);
    }
}

test "checkStatement reports a parameter mismatch with the count it was given" {
    const allocator = std.testing.allocator;
    var state = MockState{ .report = .{ .kind = .param_mismatch, .param_count = 2 } };

    var d = try checkStatement(allocator, mockDriver(&state), "SELECT * FROM t WHERE a = ? AND b = ?", &.{.{ .int = 1 }});
    defer freeStatementDiagnosis(allocator, &d);

    try std.testing.expectEqual(Problem.parameter_mismatch, d.problem);
    try std.testing.expectEqual(Status.failed, d.status());
    try std.testing.expectEqual(@as(?usize, 2), d.param_count);
    try std.testing.expect(std.mem.indexOf(u8, d.message.?, "takes 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.message.?, "1 were supplied") != null);
}

test "checkStatement reports a statement the prepare channel rejects as not_checkable" {
    const allocator = std.testing.allocator;

    // MySQL errno 1295: `BEGIN` is valid SQL that the prepared-statement
    // protocol refuses, which is not a reason to call the statement broken.
    var state = MockState{
        .dialect = Dialect.mysql,
        .report = .{ .kind = .unsupported, .native_code = 1295, .message = "This command is not supported in the prepared statement protocol yet" },
    };
    var d = try checkStatement(allocator, mockDriver(&state), "BEGIN", &.{});
    defer freeStatementDiagnosis(allocator, &d);

    try std.testing.expectEqual(Problem.not_checkable, d.problem);
    try std.testing.expectEqual(Status.not_checkable, d.status());
    try std.testing.expect(!d.isOk());
    try std.testing.expectEqualStrings("This command is not supported in the prepared statement protocol yet", d.message.?);
    try std.testing.expectEqual(@as(i32, 1295), d.native_code);
}

test "a driver with no prepare channel is not_checkable rather than an error" {
    const allocator = std.testing.allocator;
    var state = MockState{};
    const drv = sql_driver.Driver{ .ptr = &state, .vtable = &mock_vtable_no_hook };

    var d = try checkStatement(allocator, drv, "SELECT 1", &.{});
    defer freeStatementDiagnosis(allocator, &d);

    try std.testing.expectEqual(Status.not_checkable, d.status());
    try std.testing.expectEqual(Problem.not_checkable, d.problem);
    try std.testing.expectEqualStrings("the driver implements no statement check (VTable.prepareCheck)", d.message.?);
    // The hook was not there to be called, and nothing was run in its place.
    try std.testing.expectEqual(@as(usize, 0), state.calls);
}

test "the diagnosis owns the driver's text, and freeing it twice is safe" {
    const allocator = std.testing.allocator;
    var state = MockState{
        .dialect = Dialect.postgres,
        .report = .{ .kind = .prepare_failed, .sqlstate = "42703", .message = "ERROR:  column \"bogus\" does not exist\n" },
    };

    var d = try checkStatement(allocator, mockDriver(&state), "SELECT bogus FROM t", &.{});
    // Everything the diagnosis points at was allocated with this allocator, so
    // `std.testing.allocator` fails the test if any of it leaks.
    try std.testing.expect(d.message != null);
    try std.testing.expect(d.sqlstate != null);
    freeStatementDiagnosis(allocator, &d);
    try std.testing.expect(d.message == null);
    try std.testing.expect(d.sqlstate == null);
    try std.testing.expectEqual(Problem.none, d.problem);
    freeStatementDiagnosis(allocator, &d);
}

test "a driver error after the hook allocated a report does not leak it" {
    const allocator = std.testing.allocator;
    var state = MockState{
        .dialect = Dialect.mysql,
        .report = .{ .kind = .prepare_failed, .native_code = 1146, .message = "Table 'x' doesn't exist" },
        .fail_after_alloc = true,
    };

    // The error is the check failing (a dead connection, OOM inside the
    // driver), not a verdict about the statement.
    try std.testing.expectError(
        error.ConnectionFailed,
        checkStatement(allocator, mockDriver(&state), "SELECT * FROM x", &.{}),
    );
    // The report's text is reachable only through the hook's `out`, so the leak
    // check in `std.testing.allocator` is what proves the defer covered it.
}

test "StatementDiagnosis.status maps every problem" {
    const cases = [_]struct { problem: Problem, expected: Status }{
        .{ .problem = .none, .expected = .ok },
        .{ .problem = .syntax, .expected = .failed },
        .{ .problem = .missing_relation, .expected = .failed },
        .{ .problem = .missing_column, .expected = .failed },
        .{ .problem = .parameter_mismatch, .expected = .failed },
        .{ .problem = .empty, .expected = .failed },
        .{ .problem = .other, .expected = .failed },
        .{ .problem = .not_checkable, .expected = .not_checkable },
    };
    for (cases) |case| {
        const d = StatementDiagnosis{ .problem = case.problem };
        try std.testing.expectEqual(case.expected, d.status());
    }
}
