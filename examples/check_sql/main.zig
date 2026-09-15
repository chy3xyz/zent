//! `check_sql` — the command line entry point; the tool itself lives in
//! `cli.zig`, next to this file, so a test can drive it without a subprocess.
//!
//! Build and run:
//!   zig build run-check-sql                  (checks examples/check_sql/sample.sql)
//!   zig-out/bin/check_sql --help
//!   zig-out/bin/check_sql --dsn sqlite:app.db queries.sql

const std = @import("std");
const cli = @import("check_sql_cli");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // `argv[0]` is the program name; `cli.run` starts at index 1.
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [8 * 1024]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_file.interface;

    var stderr_buffer: [4 * 1024]u8 = undefined;
    var stderr_file = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_file.interface;

    const code = cli.run(gpa, init.io, stdout, stderr, argv, init.environ_map.get("ZENT_DSN")) catch |e| blk: {
        // Only the run being impossible to finish lands here (out of memory, a
        // write that failed); a statement that does not prepare is data, and
        // comes back as an exit code instead.
        stderr.print("check_sql: the run failed: {s}\n", .{@errorName(e)}) catch {};
        break :blk cli.exit_unusable;
    };

    stdout.flush() catch {};
    stderr.flush() catch {};
    if (code != cli.exit_ok) std.process.exit(code);
}
