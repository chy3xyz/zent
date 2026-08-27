const std = @import("std");
const main = @import("main.zig");
const zent = @import("zent");

const Benchmark = main.Benchmark;
const Result = main.Result;

const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
const buildGraph = zent.codegen.graph.buildGraph;
const client_mod = zent.codegen.client;
const Client = zent.codegen.client.Client;
const field = zent.core.field;
const schema = zent.core.schema.Schema;
const deinitEntity = zent.codegen.deinitEntity;

/// Primary-key upsert target: SaveOrUpdate conflicts on "id".
const PkEntity = schema("BenchUpsertPk", .{
    .fields = &.{ field.String("name"), field.Int("score") },
});

/// Business-key upsert target: SaveOrUpdateOn conflicts on the unique "email".
const OnEntity = schema("BenchUpsertOn", .{
    .fields = &.{ field.String("email").Unique(), field.String("name"), field.Int("score") },
});

const pk_graph = buildGraph(&.{PkEntity});
const pk_infos = pk_graph.types;
const pk_info = pk_infos[0];
const PkClient = Client(pk_infos);

const on_graph = buildGraph(&.{OnEntity});
const on_infos = on_graph.types;
const on_info = on_infos[0];
const OnClient = Client(on_infos);

const PkCtx = struct {
    allocator: std.mem.Allocator,
    client: *PkClient,
    score: i64,
};

const OnCtx = struct {
    allocator: std.mem.Allocator,
    client: *OnClient,
    score: i64,
};

fn benchUpsertPk(allocator: std.mem.Allocator, io: std.Io) !Result {
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    try client_mod.createAllTables(pk_infos, drv.asDriver());
    var client = client_mod.makeClient(pk_infos, allocator, drv.asDriver());

    // Seed one row.
    {
        var b = try client.bench_upsert_pk.Create();
        defer b.deinit();
        _ = try b.setFieldValue("id", @as(i64, 1));
        _ = try b.setFieldValue("name", "row");
        _ = try b.setFieldValue("score", @as(i64, 0));
        var e = try b.Save();
        deinitEntity(pk_infos, pk_info, &e, allocator);
    }

    // One-shot correctness check: one upsert on the same id updates in place.
    {
        var b = try client.bench_upsert_pk.Create();
        defer b.deinit();
        _ = try b.setFieldValue("id", @as(i64, 1));
        _ = try b.setFieldValue("name", "row");
        _ = try b.setFieldValue("score", @as(i64, 42));
        var e = try b.SaveOrUpdate();
        defer deinitEntity(pk_infos, pk_info, &e, allocator);
        if (e.id != 1) return error.BenchmarkMismatch;
    }
    {
        var rows = try drv.query("SELECT id, score FROM bench_upsert_pk", &.{});
        defer rows.deinit();
        var count: usize = 0;
        var id: i64 = -1;
        var score: i64 = -1;
        while (rows.next()) |row| {
            count += 1;
            id = row.getInt(0) orelse return error.BenchmarkMismatch;
            score = row.getInt(1) orelse return error.BenchmarkMismatch;
        }
        if (count != 1 or id != 1 or score != 42) return error.BenchmarkMismatch;
    }

    var ctx = PkCtx{ .allocator = allocator, .client = &client, .score = 42 };
    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *PkCtx = @ptrCast(@alignCast(ptr));
            var b = try c.client.bench_upsert_pk.Create();
            defer b.deinit();
            _ = try b.setFieldValue("id", @as(i64, 1));
            _ = try b.setFieldValue("name", "row");
            _ = try b.setFieldValue("score", c.score);
            var e = try b.SaveOrUpdate();
            defer deinitEntity(pk_infos, pk_info, &e, c.allocator);
            if (e.id != 1) return error.BenchmarkMismatch;
            c.score += 1;
        }
    }.body);
}

fn benchUpsertOn(allocator: std.mem.Allocator, io: std.Io) !Result {
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    try client_mod.createAllTables(on_infos, drv.asDriver());
    var client = client_mod.makeClient(on_infos, allocator, drv.asDriver());

    // Seed one row.
    {
        var b = try client.bench_upsert_on.Create();
        defer b.deinit();
        _ = try b.setFieldValue("id", @as(i64, 1));
        _ = try b.setFieldValue("email", "a@x.com");
        _ = try b.setFieldValue("name", "row");
        _ = try b.setFieldValue("score", @as(i64, 0));
        var e = try b.Save();
        deinitEntity(on_infos, on_info, &e, allocator);
    }

    // One-shot correctness check: the unique email is the conflict target.
    {
        var b = try client.bench_upsert_on.Create();
        defer b.deinit();
        _ = try b.setFieldValue("id", @as(i64, 1));
        _ = try b.setFieldValue("email", "a@x.com");
        _ = try b.setFieldValue("name", "row");
        _ = try b.setFieldValue("score", @as(i64, 42));
        var e = try b.SaveOrUpdateOn(&.{"email"});
        defer deinitEntity(on_infos, on_info, &e, allocator);
        if (e.id != 1) return error.BenchmarkMismatch;
    }
    {
        var rows = try drv.query("SELECT id, score FROM bench_upsert_on", &.{});
        defer rows.deinit();
        var count: usize = 0;
        var id: i64 = -1;
        var score: i64 = -1;
        while (rows.next()) |row| {
            count += 1;
            id = row.getInt(0) orelse return error.BenchmarkMismatch;
            score = row.getInt(1) orelse return error.BenchmarkMismatch;
        }
        if (count != 1 or id != 1 or score != 42) return error.BenchmarkMismatch;
    }

    var ctx = OnCtx{ .allocator = allocator, .client = &client, .score = 42 };
    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *OnCtx = @ptrCast(@alignCast(ptr));
            var b = try c.client.bench_upsert_on.Create();
            defer b.deinit();
            _ = try b.setFieldValue("id", @as(i64, 1));
            _ = try b.setFieldValue("email", "a@x.com");
            _ = try b.setFieldValue("name", "row");
            _ = try b.setFieldValue("score", c.score);
            var e = try b.SaveOrUpdateOn(&.{"email"});
            defer deinitEntity(on_infos, on_info, &e, c.allocator);
            if (e.id != 1) return error.BenchmarkMismatch;
            c.score += 1;
        }
    }.body);
}

pub const benchmarks: []const Benchmark = &[_]Benchmark{
    .{ .name = "upsert/save_or_update", .run = benchUpsertPk },
    .{ .name = "upsert/save_or_update_on", .run = benchUpsertOn },
};
