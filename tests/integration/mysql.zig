//! Integration tests for the MySQL/MariaDB driver against a local server.
//!
//! Expects a database `zent_test` on localhost:3306 accessible by root
//! without a password (common Homebrew MariaDB default).
//! Set MYSQL_DSN parts to override:
//!   MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASS, MYSQL_DB

const std = @import("std");
const zent = @import("zent");
const MySQLDriver = zent.sql_mysql.MySQLDriver;
const buildGraph = zent.codegen.graph.buildGraph;
const Client = zent.codegen.client;
const field = zent.core.field;
const schema = zent.core.schema.Schema;
const testing = std.testing;

fn connect(allocator: std.mem.Allocator) !MySQLDriver {
    const host = std.process.Environ.getPosix(std.testing.environ, "MYSQL_HOST") orelse "localhost";
    const port_s = std.process.Environ.getPosix(std.testing.environ, "MYSQL_PORT") orelse "3306";
    const user = std.process.Environ.getPosix(std.testing.environ, "MYSQL_USER") orelse "root";
    const pass = std.process.Environ.getPosix(std.testing.environ, "MYSQL_PASS") orelse "";
    const db = std.process.Environ.getPosix(std.testing.environ, "MYSQL_DB") orelse "zent_test";

    return MySQLDriver.connect(
        allocator,
        host,
        try std.fmt.parseInt(u32, port_s, 10),
        user,
        pass,
        db,
    );
}

fn skipIfNoServer(e: anyerror) anyerror!void {
    switch (e) {
        error.MySQLConnectFailed => return error.SkipZigTest,
        else => return e,
    }
}

test "MySQL: ping and basic CRUD" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    try drv.ping();

    _ = try drv.exec("DROP TABLE IF EXISTS zent_my_test", &.{});
    _ = try drv.exec(
        \\CREATE TABLE zent_my_test (
        \\  id INT AUTO_INCREMENT PRIMARY KEY,
        \\  name VARCHAR(255) NOT NULL,
        \\  score INT
        \\)
    , &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS zent_my_test", &.{}) catch {};

    const res = try drv.exec(
        "INSERT INTO zent_my_test (name, score) VALUES (?, ?)",
        &.{ .{ .string = "alice" }, .{ .int = 42 } },
    );
    try testing.expectEqual(@as(usize, 1), res.rows_affected);
    try testing.expect(res.last_insert_id != null);

    var rows = try drv.query("SELECT id, name, score FROM zent_my_test WHERE score = ?", &.{.{ .int = 42 }});
    defer rows.deinit();

    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqualStrings("alice", row.getText(1).?);
    try testing.expectEqual(@as(i64, 42), row.getInt(2).?);
}

test "MySQL: transaction commit/rollback" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    _ = try drv.exec("DROP TABLE IF EXISTS zent_my_tx", &.{});
    _ = try drv.exec("CREATE TABLE zent_my_tx (id INT AUTO_INCREMENT PRIMARY KEY, val INT)", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS zent_my_tx", &.{}) catch {};

    {
        var tx = try drv.beginTx();
        defer tx.deinit();
        _ = try tx.exec("INSERT INTO zent_my_tx (val) VALUES (?)", &.{.{ .int = 1 }});
        try tx.commit();
    }

    {
        var tx = try drv.beginTx();
        defer tx.deinit();
        _ = try tx.exec("INSERT INTO zent_my_tx (val) VALUES (?)", &.{.{ .int = 2 }});
        try tx.rollback();
    }

    var rows = try drv.query("SELECT COUNT(*) FROM zent_my_tx", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 1), row.getInt(0).?);
}

test "MySQL: SaveOrUpdate updates existing row" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const MyUpsertUser = schema("MyUpsertUser", .{
        .fields = &.{
            field.Int("score"),
        },
    });

    const graph = comptime buildGraph(&.{MyUpsertUser});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS my_upsert_user", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b1 = try client.my_upsert_user.Create();
    defer b1.deinit();
    _ = try b1.setFieldValue("id", @as(i64, 99));
    _ = try b1.setFieldValue("score", @as(i64, 100));
    _ = try b1.SaveOrUpdate();

    var b2 = try client.my_upsert_user.Create();
    defer b2.deinit();
    _ = try b2.setFieldValue("id", @as(i64, 99));
    _ = try b2.setFieldValue("score", @as(i64, 200));
    _ = try b2.SaveOrUpdate();

    var rows = try drv.query("SELECT score FROM my_upsert_user WHERE id = ?", &.{.{ .int = 99 }});
    defer rows.deinit();
    const r = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 200), r.getInt(0).?);
}
