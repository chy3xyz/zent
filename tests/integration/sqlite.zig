//! Integration tests for the SQLite driver.
//! Tests the full CRUD flow plus transactions and edge cases.

const std = @import("std");
const zent = @import("zent");
const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
const Dialect = zent.sql_dialect.Dialect;
const scanRow = zent.sql_scan.scanRow;
const buildGraph = zent.codegen.graph.buildGraph;
const Client = zent.codegen.client;
const field = zent.core.field;
const schema = zent.core.schema.Schema;
const testing = std.testing;

test "SQLite: CREATE TABLE and INSERT" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, price REAL, qty INTEGER)", &.{});

    const res = try drv.exec("INSERT INTO items (name, price, qty) VALUES (?, ?, ?)", &.{
        .{ .string = "widget" },
        .{ .float = 9.99 },
        .{ .int = 42 },
    });
    try testing.expectEqual(@as(usize, 1), res.rows_affected);
    try testing.expect(res.last_insert_id != null);
    try testing.expect(res.last_insert_id.? > 0);
}

test "SQLite: basic SELECT" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)", &.{});
    _ = try drv.exec("INSERT INTO users VALUES (1, 'alice', 30)", &.{});
    _ = try drv.exec("INSERT INTO users VALUES (2, 'bob', 25)", &.{});

    var rows = try drv.query("SELECT id, name, age FROM users ORDER BY id", &.{});
    defer rows.deinit();

    // alice
    const row1 = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 1), row1.getInt(0).?);
    try testing.expectEqualStrings("alice", row1.getText(1).?);
    try testing.expectEqual(@as(i64, 30), row1.getInt(2).?);

    // bob
    const row2 = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 2), row2.getInt(0).?);
    try testing.expectEqualStrings("bob", row2.getText(1).?);
    try testing.expectEqual(@as(i64, 25), row2.getInt(2).?);

    // no more rows
    try testing.expect(rows.next() == null);
}

test "SQLite: parameterized query" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER, name TEXT)", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (1, 'hello')", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (2, 'world')", &.{});

    var rows = try drv.query("SELECT name FROM t WHERE id = ?", &.{.{ .int = 2 }});
    defer rows.deinit();

    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqualStrings("world", row.getText(0).?);
    try testing.expect(rows.next() == null);
}

test "SQLite: NULL handling" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER, val INTEGER)", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (1, NULL)", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (2, 42)", &.{});

    var rows = try drv.query("SELECT id, val FROM t ORDER BY id", &.{});
    defer rows.deinit();

    const row1 = rows.next() orelse return error.NoRow;
    try testing.expect(row1.isNull(1));
    try testing.expect(row1.getInt(1) == null);

    const row2 = rows.next() orelse return error.NoRow;
    try testing.expect(!row2.isNull(1));
    try testing.expectEqual(@as(i64, 42), row2.getInt(1).?);
}

test "SQLite: UPDATE" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER, val TEXT)", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (1, 'old')", &.{});

    const res = try drv.exec("UPDATE t SET val = ? WHERE id = ?", &.{ .{ .string = "new" }, .{ .int = 1 } });
    try testing.expectEqual(@as(usize, 1), res.rows_affected);

    var rows = try drv.query("SELECT val FROM t WHERE id = 1", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqualStrings("new", row.getText(0).?);
}

test "SQLite: DELETE" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER)", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (1)", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (2)", &.{});

    const res = try drv.exec("DELETE FROM t WHERE id = ?", &.{.{ .int = 1 }});
    try testing.expectEqual(@as(usize, 1), res.rows_affected);

    var rows = try drv.query("SELECT COUNT(*) FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 1), row.getInt(0).?);
}

test "SQLite: transaction commit" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER)", &.{});

    // Begin transaction
    var tx = try drv.beginTx();
    defer tx.deinit();
    _ = try tx.exec("INSERT INTO t VALUES (42)", &.{});
    _ = try tx.exec("INSERT INTO t VALUES (99)", &.{});
    try tx.commit();

    // Verify data persisted
    var rows = try drv.query("SELECT id FROM t ORDER BY id", &.{});
    defer rows.deinit();
    const row1 = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 42), row1.getInt(0).?);
    const row2 = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 99), row2.getInt(0).?);
}

test "SQLite: transaction rollback" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER)", &.{});

    var tx = try drv.beginTx();
    defer tx.deinit();
    _ = try tx.exec("INSERT INTO t VALUES (1)", &.{});
    try tx.rollback();

    var rows = try drv.query("SELECT COUNT(*) FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 0), row.getInt(0).?);
}

test "SQLite: scanRow primitive" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (val INTEGER)", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (42)", &.{});

    var rows = try drv.query("SELECT val FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    const val = try scanRow(i64, allocator, row);
    try testing.expectEqual(@as(i64, 42), val);
}

test "SQLite: scanRow struct" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER, name TEXT, score REAL)", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (1, 'alice', 95.5)", &.{});

    const MyStruct = struct {
        id: i64,
        name: []const u8,
        score: f64,
    };

    var rows = try drv.query("SELECT id, name, score FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    const val = try scanRow(MyStruct, allocator, row);
    defer allocator.free(val.name);
    try testing.expectEqual(@as(i64, 1), val.id);
    try testing.expectEqualStrings("alice", val.name);
    try testing.expectEqual(@as(f64, 95.5), val.score);
}

test "SQLite: BLOB roundtrip" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER, data BLOB)", &.{});
    const blob_data = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    _ = try drv.exec("INSERT INTO t VALUES (1, ?)", &.{.{ .bytes = blob_data }});

    var rows = try drv.query("SELECT data FROM t WHERE id = 1", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    const result = row.getBlob(0).?;
    try testing.expectEqualSlices(u8, blob_data, result);
}

test "SQLite: column names" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (a INTEGER, b TEXT, c REAL)", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (1, 'x', 1.0)", &.{});
    var rows = try drv.query("SELECT a, b, c FROM t", &.{});
    defer rows.deinit();

    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(usize, 3), row.columnCount());
    try testing.expectEqualStrings("a", row.columnName(0));
    try testing.expectEqualStrings("b", row.columnName(1));
    try testing.expectEqualStrings("c", row.columnName(2));
}

test "SQLite: SaveOrUpdate updates existing row" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const UpsertUser = schema("UpsertUser", .{
        .fields = &.{
            field.Int("score"),
        },
    });

    const graph = comptime buildGraph(&.{UpsertUser});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b1 = try client.upsert_user.Create();
    defer b1.deinit();
    _ = try b1.setFieldValue("id", @as(i64, 99));
    _ = try b1.setFieldValue("score", @as(i64, 100));
    _ = try b1.SaveOrUpdate();

    var b2 = try client.upsert_user.Create();
    defer b2.deinit();
    _ = try b2.setFieldValue("id", @as(i64, 99));
    _ = try b2.setFieldValue("score", @as(i64, 200));
    _ = try b2.SaveOrUpdate();

    var rows = try drv.query("SELECT score FROM upsert_user WHERE id = ?", &.{.{ .int = 99 }});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 200), row.getInt(0).?);
}
