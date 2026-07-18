//! Integration tests for the connection pool (SQLite).

const std = @import("std");
const zent = @import("zent");

const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
const ConnPool = zent.sql_pool.ConnPool;
const testing = std.testing;

test "Pool: transparent driver interface" {
    const allocator = testing.allocator;

    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                return SQLiteDriver.open(a, ":memory:");
            }
        }.f,
        .min_connections = 2,
        .max_connections = 4,
        .health_check_on_borrow = true,
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

    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                return SQLiteDriver.open(a, ":memory:");
            }
        }.f,
        .min_connections = 1,
        .max_connections = 1,
    });
    defer pool.deinit();

    const drv = pool.asDriver();
    _ = try drv.exec("CREATE TABLE t (id INTEGER)", &.{});

    var tx = try drv.beginTx();
    defer tx.deinit();
    _ = try tx.exec("INSERT INTO t (id) VALUES (?)", &.{.{ .int = 7 }});
    try tx.commit();

    // Connection must have been returned after tx.deinit.
    try testing.expectEqual(@as(usize, 1), pool.available.items.len);

    var rows = try drv.query("SELECT id FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 7), row.getInt(0).?);
}

test "Pool: concurrent borrows respect max_connections" {
    const allocator = testing.allocator;

    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                return SQLiteDriver.open(a, ":memory:");
            }
        }.f,
        .min_connections = 1,
        .max_connections = 2,
    });
    defer pool.deinit();

    const drv = pool.asDriver();
    _ = try drv.exec("CREATE TABLE t (id INTEGER)", &.{});

    const Ctx = struct {
        drv: zent.sql_driver.Driver,
        allocator: std.mem.Allocator,

        fn run(self: @This()) void {
            var tx = self.drv.beginTx() catch |err| @panic(@errorName(err));
            defer tx.deinit();
            _ = tx.exec("INSERT INTO t (id) VALUES (?)", &.{.{ .int = 1 }}) catch |err| @panic(@errorName(err));
            tx.commit() catch |err| @panic(@errorName(err));
        }
    };

    const t1 = try std.Thread.spawn(.{}, Ctx.run, .{Ctx{ .drv = drv, .allocator = allocator }});
    const t2 = try std.Thread.spawn(.{}, Ctx.run, .{Ctx{ .drv = drv, .allocator = allocator }});
    t1.join();
    t2.join();

    var rows = try drv.query("SELECT COUNT(*) FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 2), row.getInt(0).?);
}
