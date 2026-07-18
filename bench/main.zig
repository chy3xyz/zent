const std = @import("std");

pub const Result = struct {
    iterations: u64,
    elapsed_ns: u64,

    pub fn nsPerOp(self: Result) u64 {
        return @divFloor(self.elapsed_ns, self.iterations);
    }
};

pub const Benchmark = struct {
    name: []const u8,
    run: *const fn (allocator: std.mem.Allocator, io: std.Io) anyerror!Result,
};

/// Run `body(ctx)` repeatedly for at least `duration_ns` nanoseconds.
pub fn runForCtx(
    io: std.Io,
    duration_ns: u64,
    ctx: *anyopaque,
    body: *const fn (*anyopaque) anyerror!void,
) !Result {
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var iterations: u64 = 0;
    while (true) {
        try body(ctx);
        iterations += 1;
        const elapsed = start.untilNow(io).raw.toNanoseconds();
        if (elapsed >= duration_ns) {
            return .{
                .iterations = iterations,
                .elapsed_ns = @intCast(elapsed),
            };
        }
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const io = std.Io.Threaded.global_single_threaded.io();

    const builder_benches = @import("builder.zig").benchmarks;
    const scan_benches = @import("scan.zig").benchmarks;
    const pool_benches = @import("pool.zig").benchmarks;
    const cases = builder_benches ++ scan_benches ++ pool_benches;

    std.debug.print("{s:40} {s:>12} {s:>12}\n", .{ "Benchmark", "Iterations", "ns/op" });
    std.debug.print("{s}\n", .{"------------------------------------------------------------------"});

    for (cases) |bench| {
        const result = bench.run(allocator, io) catch |err| {
            std.debug.print("{s:40} ERROR: {s}\n", .{ bench.name, @errorName(err) });
            continue;
        };
        std.debug.print("{s:40} {d:>12} {d:>12}\n", .{
            bench.name,
            result.iterations,
            result.nsPerOp(),
        });
    }
}
