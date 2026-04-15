const std = @import("std");
const zent = @import("zent");

const sql = zent.sql;
const Dialect = zent.sql_dialect.Dialect;
const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
const scanRow = zent.sql_scan.scanRow;

const User = struct {
    id: i64,
    name: []const u8,
    age: i64,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // --- SQL Builder Demo (Phase 0 Acceptance Criteria) ---
    const t = sql.Table("users");
    var query = sql.Select(allocator, Dialect.sqlite, &.{
        t.c("id"),
        t.c("name"),
    });
    defer query.deinit();
    _ = query.from(t).where(sql.EQ("age", .{ .int = 30 }));
    const q = try query.query();
    std.debug.print("SQL: {s}\n", .{q.sql});
    std.debug.print("Args count: {d}\n", .{q.args.len});

    // --- SQLite Driver Demo ---
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // Create table
    _ = try drv.exec(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)",
        &.{},
    );

    // Insert data
    _ = try drv.exec(
        "INSERT INTO users (name, age) VALUES (?, ?)",
        &.{ .{ .string = "Alice" }, .{ .int = 30 } },
    );
    _ = try drv.exec(
        "INSERT INTO users (name, age) VALUES (?, ?)",
        &.{ .{ .string = "Bob" }, .{ .int = 25 } },
    );

    // Query and scan
    var rows = try drv.query(
        "SELECT id, name, age FROM users WHERE age = ?",
        &.{.{ .int = 30 }},
    );
    defer rows.deinit();

    while (rows.next()) |row| {
        const user = try scanRow(User, row);
        std.debug.print("User: id={d}, name={s}, age={d}\n", .{ user.id, user.name, user.age });
    }

    std.debug.print("Phase 0 completed successfully.\n", .{});
}
