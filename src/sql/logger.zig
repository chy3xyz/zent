const std = @import("std");
const Value = @import("builder.zig").Value;

pub const LogContext = struct {
    sql: []const u8,
    args: ?[]const Value = null,
    duration_us: u64 = 0,
    rows_affected: usize = 0,
    @"error": ?anyerror = null,
    table_name: []const u8 = "",
};

pub const Logger = struct {
    onQuery: ?*const fn (ctx: LogContext) void = null,
    onExec: ?*const fn (ctx: LogContext) void = null,
    onError: ?*const fn (ctx: LogContext) void = null,
};

pub fn debugLogger() Logger {
    return .{
        .onQuery = struct {
            fn log(ctx: LogContext) void {
                std.log.debug("QUERY [{s}] {s} ({d}us, {d} rows)", .{ ctx.table_name, ctx.sql, ctx.duration_us, ctx.rows_affected });
            }
        }.log,
        .onExec = struct {
            fn log(ctx: LogContext) void {
                std.log.debug("EXEC [{s}] {s} ({d}us, affected={d})", .{ ctx.table_name, ctx.sql, ctx.duration_us, ctx.rows_affected });
            }
        }.log,
        .onError = struct {
            fn log(ctx: LogContext) void {
                std.log.err("ERROR [{s}] {s} ({d}us): {any}", .{ ctx.table_name, ctx.sql, ctx.duration_us, ctx.@"error" });
            }
        }.log,
    };
}

/// Returns current time as microseconds since an arbitrary epoch.
/// Suitable for measuring elapsed durations.
pub fn nowUs() u64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @as(u64, @intCast(tv.sec)) * std.time.us_per_s + @as(u64, @intCast(tv.usec));
}
