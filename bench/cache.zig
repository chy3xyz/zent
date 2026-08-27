const std = @import("std");
const main = @import("main.zig");
const zent = @import("zent");

const Benchmark = main.Benchmark;
const Result = main.Result;
const PreparedCache = zent.sql_cache.PreparedCache;

const capacity = 16;
const Cache = PreparedCache(capacity, *anyopaque);

/// Distinct ORM-shaped SQL strings (~250 bytes each), sharing a long common
/// prefix so failed lookups byte-compare deep into the string (same length,
/// differing only in the trailing query id) — the realistic worst case for
/// the cache's full-text comparison.
const sqls: [32][]const u8 = blk: {
    const template = "SELECT \"users\".\"id\", \"users\".\"name\", \"users\".\"email\", \"users\".\"age\", \"users\".\"created_at\", \"users\".\"updated_at\" FROM \"users\" WHERE \"users\".\"tenant_id\" = ?1 AND \"users\".\"status\" = ?2 AND \"users\".\"deleted_at\" IS NULL ORDER BY \"users\".\"created_at\" DESC LIMIT ?3 OFFSET ?4 -- q{d:0>2}";
    var out: [32][]const u8 = undefined;
    for (0..32) |i| {
        out[i] = std.fmt.comptimePrint(template, .{i});
    }
    break :blk out;
};

/// Fake prepare/deinit pair: handles are integers-as-pointers, both stubs
/// only count invocations. No database is touched.
const Stub = struct {
    prepare_count: usize = 0,
    deinit_count: usize = 0,
};

fn stubPrepare(ctx: *Stub, sql: []const u8) !*anyopaque {
    _ = sql;
    ctx.prepare_count += 1;
    return @ptrFromInt(ctx.prepare_count);
}

fn stubDeinit(ctx: *Stub, h: *anyopaque) void {
    _ = h;
    ctx.deinit_count += 1;
}

/// Fill the cache with `sqls[0..capacity]`; handle for sqls[i] is
/// @ptrFromInt(i + 1).
fn prefill(cch: *Cache, stub: *Stub) !void {
    for (sqls[0..capacity]) |s| {
        const p = try cch.getOrPrepare(s, stub, stubPrepare, stub, stubDeinit);
        if (!p.cached) return error.BenchmarkMismatch;
    }
    if (stub.prepare_count != capacity) return error.BenchmarkMismatch;
}

const GetCtx = struct {
    cch: *Cache,
    stub: *Stub,
    sql: []const u8,
};

fn benchCacheHit(allocator: std.mem.Allocator, io: std.Io) !Result {
    _ = allocator;
    var cch: Cache = .{};
    var stub = Stub{};
    try prefill(&cch, &stub);

    // One-shot correctness check: hitting the hottest entry (first in the
    // linear scan) returns the same handle without re-preparing.
    {
        const expected: *anyopaque = @ptrFromInt(1);
        const p = try cch.getOrPrepare(sqls[0], &stub, stubPrepare, &stub, stubDeinit);
        if (!p.cached or p.stmt != expected) return error.BenchmarkMismatch;
        if (stub.prepare_count != capacity) return error.BenchmarkMismatch;
    }

    var ctx = GetCtx{ .cch = &cch, .stub = &stub, .sql = sqls[0] };
    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *GetCtx = @ptrCast(@alignCast(ptr));
            const p = try c.cch.getOrPrepare(c.sql, c.stub, stubPrepare, c.stub, stubDeinit);
            if (!p.cached) return error.BenchmarkMismatch;
        }
    }.body);
}

fn benchCacheHitColdTail(allocator: std.mem.Allocator, io: std.Io) !Result {
    _ = allocator;
    var cch: Cache = .{};
    var stub = Stub{};
    try prefill(&cch, &stub);

    // One-shot correctness check: the LRU-tail entry sits last in the linear
    // scan, so every hit pays 15 failed byte-compares before matching.
    {
        const expected: *anyopaque = @ptrFromInt(capacity);
        const p = try cch.getOrPrepare(sqls[capacity - 1], &stub, stubPrepare, &stub, stubDeinit);
        if (!p.cached or p.stmt != expected) return error.BenchmarkMismatch;
        if (stub.prepare_count != capacity) return error.BenchmarkMismatch;
    }

    var ctx = GetCtx{ .cch = &cch, .stub = &stub, .sql = sqls[capacity - 1] };
    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *GetCtx = @ptrCast(@alignCast(ptr));
            const p = try c.cch.getOrPrepare(c.sql, c.stub, stubPrepare, c.stub, stubDeinit);
            if (!p.cached) return error.BenchmarkMismatch;
        }
    }.body);
}

const TakeCtx = struct {
    cch: *Cache,
    stub: *Stub,
    sql: []const u8,
};

fn benchCacheTakeReturn(allocator: std.mem.Allocator, io: std.Io) !Result {
    _ = allocator;
    var cch: Cache = .{};
    var stub = Stub{};

    const p = try cch.getOrPrepare(sqls[0], &stub, stubPrepare, &stub, stubDeinit);
    if (!p.cached) return error.BenchmarkMismatch;

    // One-shot correctness check: take reserves the slot, return makes the
    // same statement available again without a new prepare.
    {
        const t = try cch.takeOrPrepare(sqls[0], &stub, stubPrepare);
        if (t.slot == null or t.stmt != p.stmt) return error.BenchmarkMismatch;
        cch.returnStmt(t.slot.?, t.stmt, &stub, stubDeinit);
        const t2 = try cch.takeOrPrepare(sqls[0], &stub, stubPrepare);
        if (t2.slot == null or t2.stmt != p.stmt) return error.BenchmarkMismatch;
        if (stub.prepare_count != 1) return error.BenchmarkMismatch;
        cch.returnStmt(t2.slot.?, t2.stmt, &stub, stubDeinit);
    }

    var ctx = TakeCtx{ .cch = &cch, .stub = &stub, .sql = sqls[0] };
    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *TakeCtx = @ptrCast(@alignCast(ptr));
            const t = try c.cch.takeOrPrepare(c.sql, c.stub, stubPrepare);
            if (t.slot == null) return error.BenchmarkMismatch;
            c.cch.returnStmt(t.slot.?, t.stmt, c.stub, stubDeinit);
        }
    }.body);
}

const ChurnCtx = struct {
    cch: *Cache,
    stub: *Stub,
    next: usize,
};

fn benchCacheEvictChurn(allocator: std.mem.Allocator, io: std.Io) !Result {
    _ = allocator;
    var cch: Cache = .{};
    var stub = Stub{};
    try prefill(&cch, &stub);

    // One-shot correctness check: inserting a 17th distinct SQL into a full
    // cache evicts the LRU entry (deinit stub fires exactly once).
    {
        const p = try cch.getOrPrepare(sqls[capacity], &stub, stubPrepare, &stub, stubDeinit);
        if (!p.cached) return error.BenchmarkMismatch;
        if (stub.prepare_count != capacity + 1) return error.BenchmarkMismatch;
        if (stub.deinit_count != 1) return error.BenchmarkMismatch;
    }

    var ctx = ChurnCtx{ .cch = &cch, .stub = &stub, .next = capacity + 1 };
    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *ChurnCtx = @ptrCast(@alignCast(ptr));
            // Rotate through the extra SQLs so every iteration misses,
            // forcing an LRU eviction (deinit stub) plus insert.
            const i = c.next;
            c.next = if (i + 1 >= sqls.len) capacity else i + 1;
            const p = try c.cch.getOrPrepare(sqls[i], c.stub, stubPrepare, c.stub, stubDeinit);
            if (!p.cached) return error.BenchmarkMismatch;
        }
    }.body);
}

pub const benchmarks: []const Benchmark = &[_]Benchmark{
    .{ .name = "cache/hit", .run = benchCacheHit },
    .{ .name = "cache/hit_cold_tail", .run = benchCacheHitColdTail },
    .{ .name = "cache/take_return", .run = benchCacheTakeReturn },
    .{ .name = "cache/evict_churn", .run = benchCacheEvictChurn },
};
