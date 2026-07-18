const std = @import("std");
const main = @import("main.zig");
const zent = @import("zent");

const Benchmark = main.Benchmark;
const Result = main.Result;
const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
const ConnPool = zent.sql_pool.ConnPool;

const PoolCtx = struct {
    pool: *ConnPool(SQLiteDriver),
};

fn openInMemory(allocator: std.mem.Allocator) !SQLiteDriver {
    return SQLiteDriver.open(allocator, ":memory:");
}

fn benchBorrowRelease(allocator: std.mem.Allocator, io: std.Io) !Result {
    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = openInMemory,
        .min_connections = 1,
        .max_connections = 1,
        .health_check_on_borrow = true,
    });
    defer pool.deinit();

    var ctx = PoolCtx{ .pool = &pool };
    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *PoolCtx = @ptrCast(@alignCast(ptr));
            const conn = try c.pool.borrow();
            c.pool.release(conn);
        }
    }.body);
}

fn benchBorrowReleaseNoHealthCheck(allocator: std.mem.Allocator, io: std.Io) !Result {
    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = openInMemory,
        .min_connections = 1,
        .max_connections = 1,
        .health_check_on_borrow = false,
    });
    defer pool.deinit();

    var ctx = PoolCtx{ .pool = &pool };
    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *PoolCtx = @ptrCast(@alignCast(ptr));
            const conn = try c.pool.borrow();
            c.pool.release(conn);
        }
    }.body);
}

pub const benchmarks: []const Benchmark = &[_]Benchmark{
    .{ .name = "pool/borrow_release", .run = benchBorrowRelease },
    .{ .name = "pool/borrow_release_no_health", .run = benchBorrowReleaseNoHealthCheck },
};
