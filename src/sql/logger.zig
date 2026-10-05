const std = @import("std");
const Value = @import("builder.zig").Value;
const driver = @import("driver.zig");

pub const LogContext = struct {
    sql: []const u8,
    args: ?[]const Value = null,
    duration_us: u64 = 0,
    /// How many rows the statement touched — **only meaningful when
    /// `rows_affected_known` is true**. The mirror of `driver.Result`, which
    /// cannot express "the driver never obtained a count" in the number
    /// itself: SQLite answers `sqlite3_changes` for a `SELECT`/`PRAGMA`/DDL
    /// with the *previous* DML's count, MySQL's `mysql_stmt_affected_rows` is
    /// `(my_ulonglong)-1` for a prepared `SELECT`, PostgreSQL's `PQcmdTuples`
    /// is `""` for a command that reports none. In those cases the number
    /// here is a placeholder — a log line printing it as `0` claims the
    /// statement matched nothing.
    rows_affected: usize = 0,
    /// False when `rows_affected` is a placeholder rather than a count that
    /// was actually obtained. A logger must render the unknown case so it
    /// cannot be read as `0`; `debugLogger` prints `?`. Defaults to true
    /// because every in-tree call site either counted rows itself (the
    /// builders know how many rows they returned) or forwards the driver's
    /// own flag.
    rows_affected_known: bool = true,
    @"error": ?anyerror = null,
    table_name: []const u8 = "",
    /// Caller-supplied trace identifier. The library never generates or mutates
    /// this value — it only passes it through to logger callbacks so callers
    /// can correlate queries with distributed traces.
    trace_id: ?[]const u8 = null,
};

pub const Logger = struct {
    onQuery: ?*const fn (ctx: LogContext) void = null,
    onExec: ?*const fn (ctx: LogContext) void = null,
    onError: ?*const fn (ctx: LogContext) void = null,
};

/// Renders `rows_affected` for a log line, or `?` when the count is unknown.
/// The placeholder number must never reach the text: `0` in a log line is a
/// claim that the statement matched nothing, and "the driver never obtained a
/// count" is a different statement from "the count is zero".
fn rowsAffectedText(ctx: LogContext, buf: []u8) []const u8 {
    if (!ctx.rows_affected_known) return "?";
    return std.fmt.bufPrint(buf, "{d}", .{ctx.rows_affected}) catch "?";
}

pub fn debugLogger() Logger {
    return .{
        .onQuery = struct {
            fn log(ctx: LogContext) void {
                var buf: [32]u8 = undefined;
                std.log.debug("QUERY [{s}] {s} ({d}us, {s} rows)", .{ ctx.table_name, ctx.sql, ctx.duration_us, rowsAffectedText(ctx, &buf) });
            }
        }.log,
        .onExec = struct {
            fn log(ctx: LogContext) void {
                var buf: [32]u8 = undefined;
                std.log.debug("EXEC [{s}] {s} ({d}us, affected={s})", .{ ctx.table_name, ctx.sql, ctx.duration_us, rowsAffectedText(ctx, &buf) });
            }
        }.log,
        .onError = struct {
            fn log(ctx: LogContext) void {
                std.log.err("ERROR [{s}] {s} ({d}us): {any}", .{ ctx.table_name, ctx.sql, ctx.duration_us, ctx.@"error" });
            }
        }.log,
    };
}

/// Current time in microseconds from the **monotonic** clock, not the wall
/// clock. The call sites only ever take durations (`nowUs() - start`), and a
/// wall clock is the wrong source for that: an NTP step or a manual clock set
/// moves the wall clock under the measurement, so the difference goes
/// negative and wraps into a huge u64 in the log line. Monotonic microseconds
/// are therefore **only for measuring elapsed durations** — they carry no
/// relation to the Unix epoch and must never be stored as a timestamp.
///
/// Shares `driver.monotonicNs`'s clock and its documented fallback chain
/// (wall clock, then 0) rather than keeping a second copy that can drift
/// from it.
pub fn nowUs() u64 {
    return @intCast(@divTrunc(driver.monotonicNs(), std.time.ns_per_us));
}

test "an unknown row count is not rendered as zero" {
    var buf: [32]u8 = undefined;

    // The driver never obtained a count (SQLite after a SELECT/PRAGMA/DDL,
    // MySQL for a prepared SELECT, PostgreSQL for a command with no count
    // tag). The number stored alongside is a placeholder, so the log line
    // must not claim the statement matched nothing.
    const unknown = LogContext{ .sql = "SELECT 1", .rows_affected = 0, .rows_affected_known = false };
    try std.testing.expectEqualStrings("?", rowsAffectedText(unknown, &buf));

    // A count that was obtained still prints as a number — including a
    // genuine zero. "matched no row" and "count not known" are different
    // statements, and only the first one may appear as `0`.
    const known_zero = LogContext{ .sql = "DELETE FROM t WHERE 1 = 0", .rows_affected = 0 };
    try std.testing.expectEqualStrings("0", rowsAffectedText(known_zero, &buf));
    const known = LogContext{ .sql = "UPDATE t SET a = 1", .rows_affected = 3 };
    try std.testing.expectEqualStrings("3", rowsAffectedText(known, &buf));
}
