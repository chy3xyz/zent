//! Integration tests for the connection pool (SQLite).
//!
//! Each test uses a separate on-disk database file so that multiple
//! connections opened by the pool share the same database (unlike
//! ":memory:" databases, which are per-connection).

const std = @import("std");
const zent = @import("zent");

const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
const ConnPool = zent.sql_pool.ConnPool;
const testing = std.testing;

fn cleanup(path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
}

test "Pool: transparent driver interface" {
    const allocator = testing.allocator;
    const path = "tests/integration/.pool_transparent.db";
    cleanup(path);
    defer cleanup(path);

    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                return SQLiteDriver.open(a, path);
            }
        }.f,
        .min_connections = 2,
        .max_connections = 4,
        .health_check_on_borrow = true,
        .io = testing.io,
    });
    defer pool.deinit();

    const drv = pool.asDriver();
    try std.testing.expectEqual(zent.sql_dialect.Dialect.sqlite, drv.dialect());

    _ = try drv.exec("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try drv.exec("INSERT INTO items (name) VALUES (?)", &.{.{ .string = "pool-test" }});

    var rows = try drv.query("SELECT name FROM items", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqualStrings("pool-test", row.getText(0).?);
}

test "Pool: transaction holds connection until deinit" {
    const allocator = testing.allocator;
    const path = "tests/integration/.pool_tx.db";
    cleanup(path);
    defer cleanup(path);

    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                return SQLiteDriver.open(a, path);
            }
        }.f,
        .min_connections = 1,
        .max_connections = 1,
        .io = testing.io,
    });
    defer pool.deinit();

    const drv = pool.asDriver();
    _ = try drv.exec("CREATE TABLE t (id INTEGER)", &.{});

    {
        var tx = try drv.beginTx();
        _ = try tx.exec("INSERT INTO t (id) VALUES (?)", &.{.{ .int = 7 }});
        try tx.commit();
        tx.deinit();
    }

    // Connection must have been returned after tx.deinit.
    try testing.expectEqual(@as(usize, 1), pool.available.items.len);

    var rows = try drv.query("SELECT id FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 7), row.getInt(0).?);
}

test "Pool: concurrent borrows respect max_connections" {
    const allocator = testing.allocator;
    const path = "tests/integration/.pool_concurrent.db";
    cleanup(path);
    defer cleanup(path);

    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                return SQLiteDriver.open(a, path);
            }
        }.f,
        .min_connections = 1,
        .max_connections = 2,
        .io = testing.io,
    });
    defer pool.deinit();

    const drv = pool.asDriver();
    _ = try drv.exec("CREATE TABLE t (id INTEGER)", &.{});

    const Ctx = struct {
        drv: zent.sql_driver.Driver,

        fn run(self: @This()) void {
            var tx = self.drv.beginTx() catch |err| @panic(@errorName(err));
            defer tx.deinit();
            _ = tx.exec("INSERT INTO t (id) VALUES (?)", &.{.{ .int = 1 }}) catch |err| @panic(@errorName(err));
            tx.commit() catch |err| @panic(@errorName(err));
        }
    };

    const t1 = try std.Thread.spawn(.{}, Ctx.run, .{Ctx{ .drv = drv }});
    const t2 = try std.Thread.spawn(.{}, Ctx.run, .{Ctx{ .drv = drv }});
    t1.join();
    t2.join();

    var rows = try drv.query("SELECT COUNT(*) FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 2), row.getInt(0).?);
}
