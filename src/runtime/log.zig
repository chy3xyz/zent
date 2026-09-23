//! Where this library's own diagnostics go.
//!
//! `std.log` stays the default and the forwarded call is the same one the call
//! sites used before: `log.warn(fmt, args)` with no sink installed emits
//! `std.log.warn(fmt, args)` at the root scope, byte for byte what the message
//! was. That matters — consumers grep these lines (a shutdown-leak gate reads
//! the text), so the default path cannot drift.
//!
//! What the sink adds is what a *library* cannot otherwise offer: `std_options`
//! (and with it `logFn`) belongs to the root module, so a consumer that wants
//! these lines in its own handler had no way to get them, and a test that wants
//! to assert one had none either. Install a sink and every message this library
//! emits arrives formatted.
//!
//! Scope: the one-off diagnostics — a dropped pool connection, a refused DDL, a
//! dialect difference. Per-query logging is `sql_logger.Logger`'s contract and
//! stays there (it carries SQL, args, duration and row counts, which a
//! line-oriented sink would flatten).
//!
//! Threading: `setSink` writes one pointer and emits read it. Install during
//! startup, before the pool spawns anything, or accept that a line emitted
//! concurrently may be missed — the sink itself runs on the emitting thread, so
//! it is the caller's handler that has to be thread-safe.

const std = @import("std");

pub const Level = enum { err, warn, info, debug };

/// Receives the formatted line. The slice is a stack buffer owned by this
/// module's `emit` call and is **not** valid after the sink returns; copy what
/// you keep.
pub const Sink = *const fn (level: Level, message: []const u8) void;

var installed: ?Sink = null;

/// Install a sink, or `null` to go back to `std.log`.
pub fn setSink(sink: ?Sink) void {
    installed = sink;
}

/// Whether a sink is installed — the default path is `std.log`, and a caller
/// that only wants the default has nothing to do.
pub fn hasSink() bool {
    return installed != null;
}

/// Format `fmt`/`args` and hand the line to the sink, or forward to `std.log`.
///
/// A diagnostic longer than the buffer arrives truncated rather than dropped:
/// the first 1024 bytes still name the table and the reason, and losing the
/// line entirely would hide the condition it reports.
pub fn emit(comptime level: Level, comptime fmt: []const u8, args: anytype) void {
    const sink = installed orelse {
        // The original spelling, so the default output is unchanged.
        return switch (level) {
            .err => std.log.err(fmt, args),
            .warn => std.log.warn(fmt, args),
            .info => std.log.info(fmt, args),
            .debug => std.log.debug(fmt, args),
        };
    };
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print(fmt, args) catch {};
    sink(level, w.buffered());
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    emit(.err, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    emit(.warn, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    emit(.info, fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    emit(.debug, fmt, args);
}

const Capture = struct {
    var level: Level = .warn;
    var count: usize = 0;
    var text: [512]u8 = undefined;
    var len: usize = 0;

    fn sink(l: Level, message: []const u8) void {
        level = l;
        count += 1;
        len = @min(message.len, text.len);
        @memcpy(text[0..len], message[0..len]);
    }

    fn reset() void {
        count = 0;
        len = 0;
    }

    fn last() []const u8 {
        return text[0..len];
    }
};

test "a sink receives the formatted line and its level" {
    defer setSink(null);
    Capture.reset();
    setSink(Capture.sink);

    warn("pool: dropped connection {d} after {s}", .{ 42, "timeout" });

    try std.testing.expect(hasSink());
    try std.testing.expectEqual(@as(usize, 1), Capture.count);
    try std.testing.expectEqual(Level.warn, Capture.level);
    try std.testing.expectEqualStrings("pool: dropped connection 42 after timeout", Capture.last());
}

test "the level travels with the message" {
    defer setSink(null);
    Capture.reset();
    setSink(Capture.sink);

    info("migrate: applying {s}", .{"001_create_users"});
    try std.testing.expectEqual(Level.info, Capture.level);
    try std.testing.expectEqualStrings("migrate: applying 001_create_users", Capture.last());
}

test "a line longer than the buffer is truncated, not dropped" {
    defer setSink(null);
    Capture.reset();
    setSink(Capture.sink);

    var long: [4000]u8 = @splat('x');
    warn("table={s}", .{long[0..]});

    try std.testing.expectEqual(@as(usize, 1), Capture.count);
    try std.testing.expect(std.mem.startsWith(u8, Capture.last(), "table=xxx"));
    try std.testing.expect(Capture.last().len >= 512);
}

test "with no sink the default path is std.log" {
    defer setSink(null);
    setSink(null);
    try std.testing.expect(!hasSink());
}
