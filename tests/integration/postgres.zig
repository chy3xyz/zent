//! Integration tests for the PostgreSQL driver against a local server.
//!
//! Expects a database `zent_test` on localhost:5432 accessible by the
//! current OS user without a password (common Homebrew default).
//! Set PG_DSN to override, e.g.:
//!   PG_DSN="host=localhost dbname=zent_test user=postgres password=secret"

const std = @import("std");
const zent = @import("zent");
const PostgresDriver = zent.sql_postgres.PostgresDriver;
const buildGraph = zent.codegen.graph.buildGraph;
const Client = zent.codegen.client;
const field = zent.core.field;
const schema = zent.core.schema.Schema;
const testing = std.testing;

fn connect(allocator: std.mem.Allocator) !PostgresDriver {
    const dsn = std.process.Environ.getPosix(std.testing.environ, "PG_DSN") orelse {
        const user = std.process.Environ.getPosix(std.testing.environ, "USER") orelse "n0x";
        const conninfo = try std.fmt.allocPrint(allocator, "host=localhost dbname=zent_test user={s}", .{user});
        defer allocator.free(conninfo);
        return PostgresDriver.connect(allocator, conninfo);
    };
    return PostgresDriver.connect(allocator, dsn);
}

fn skipIfNoServer(e: anyerror) anyerror!void {
    switch (e) {
        error.PostgresConnectFailed => {
            std.log.warn("Postgres integration test skipped: {s}", .{@errorName(e)});
            return error.SkipZigTest;
        },
        else => return e,
    }
}

test "Postgres: ping and basic CRUD" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    try drv.ping();

    _ = try drv.exec("DROP TABLE IF EXISTS zent_pg_test", &.{});
    _ = try drv.exec(
        \\CREATE TABLE zent_pg_test (
        \\  id SERIAL PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  score INT
        \\)
    , &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS zent_pg_test", &.{}) catch {};

    const res = try drv.exec(
        "INSERT INTO zent_pg_test (name, score) VALUES ($1, $2) RETURNING id",
        &.{ .{ .string = "alice" }, .{ .int = 42 } },
    );
    try testing.expectEqual(@as(usize, 1), res.rows_affected);
    try testing.expect(res.last_insert_id != null);

    var rows = try drv.query("SELECT id, name, score FROM zent_pg_test WHERE score = $1", &.{.{ .int = 42 }});
    defer rows.deinit();

    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqualStrings("alice", row.getText(1).?);
    try testing.expectEqual(@as(i64, 42), row.getInt(2).?);
}

test "Postgres: transaction commit/rollback" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    _ = try drv.exec("DROP TABLE IF EXISTS zent_pg_tx", &.{});
    _ = try drv.exec("CREATE TABLE zent_pg_tx (id SERIAL PRIMARY KEY, val INT)", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS zent_pg_tx", &.{}) catch {};

    {
        var tx = try drv.beginTx();
        defer tx.deinit();
        _ = try tx.exec("INSERT INTO zent_pg_tx (val) VALUES ($1)", &.{.{ .int = 1 }});
        try tx.commit();
    }

    {
        var tx = try drv.beginTx();
        defer tx.deinit();
        _ = try tx.exec("INSERT INTO zent_pg_tx (val) VALUES ($1)", &.{.{ .int = 2 }});
        try tx.rollback();
    }

    var rows = try drv.query("SELECT COUNT(*) FROM zent_pg_tx", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 1), row.getInt(0).?);
}

test "Postgres: SaveOrUpdate updates existing row" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const PgUpsertUser = schema("PgUpsertUser", .{
        .fields = &.{
            field.Int("score"),
        },
    });

    const graph = comptime buildGraph(&.{PgUpsertUser});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_upsert_user", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b1 = try client.pg_upsert_user.Create();
    defer b1.deinit();
    _ = try b1.setFieldValue("id", @as(i64, 99));
    _ = try b1.setFieldValue("score", @as(i64, 100));
    _ = try b1.SaveOrUpdate();

    var b2 = try client.pg_upsert_user.Create();
    defer b2.deinit();
    _ = try b2.setFieldValue("id", @as(i64, 99));
    _ = try b2.setFieldValue("score", @as(i64, 200));
    _ = try b2.SaveOrUpdate();

    var rows = try drv.query("SELECT score FROM pg_upsert_user WHERE id = $1", &.{.{ .int = 99 }});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 200), row.getInt(0).?);
}
