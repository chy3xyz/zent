const std = @import("std");
const zent = @import("zent");

const sql = zent.sql;
const Dialect = zent.sql_dialect.Dialect;
const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
const scanRow = zent.sql_scan.scanRow;
const fromSchema = zent.codegen.graph.fromSchema;

const start_schema = @import("schema.zig");

const User = start_schema.User;
const Car = start_schema.Car;
const Group = start_schema.Group;

const UserRow = struct {
    id: i64,
    name: []const u8,
    age: i64,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // --- Phase 1: Schema definition and comptime introspection ---
    const user_info = comptime fromSchema(User);
    const car_info = comptime fromSchema(Car);
    const group_info = comptime fromSchema(Group);

    std.debug.print("=== Phase 1: Schema Introspection ===\n", .{});
    std.debug.print("Entity: {s}, Table: {s}, Fields: {d}, Edges: {d}\n", .{
        user_info.name, user_info.table_name, user_info.fields.len, user_info.edges.len,
    });
    inline for (user_info.fields) |f| {
        std.debug.print("  Field: {s} (sql={s}, zig={s})\n", .{ f.name, f.sql_type, @typeName(f.zig_type) });
    }
    inline for (user_info.edges) |e| {
        std.debug.print("  Edge: {s} -> {s} (relation={s}, inverse={s})\n", .{
            e.name,
            e.target_name,
            @tagName(e.relation),
            e.inverse_name orelse "none",
        });
    }

    std.debug.print("Entity: {s}, Table: {s}, Fields: {d}, Edges: {d}\n", .{
        car_info.name, car_info.table_name, car_info.fields.len, car_info.edges.len,
    });
    inline for (car_info.fields) |f| {
        std.debug.print("  Field: {s} (sql={s})\n", .{ f.name, f.sql_type });
    }
    inline for (car_info.edges) |e| {
        std.debug.print("  Edge: {s} -> {s} (relation={s}, inverse={s})\n", .{
            e.name,
            e.target_name,
            @tagName(e.relation),
            e.inverse_name orelse "none",
        });
    }

    std.debug.print("Entity: {s}, Table: {s}, Fields: {d}, Edges: {d}\n", .{
        group_info.name, group_info.table_name, group_info.fields.len, group_info.edges.len,
    });

    // --- Phase 0: SQL Builder Demo ---
    std.debug.print("\n=== Phase 0: SQL Builder ===\n", .{});
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
    std.debug.print("\n=== Phase 0: SQLite Driver ===\n", .{});
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec(
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)",
        &.{},
    );
    _ = try drv.exec(
        "INSERT INTO users (name, age) VALUES (?, ?)",
        &.{ .{ .string = "Alice" }, .{ .int = 30 } },
    );
    _ = try drv.exec(
        "INSERT INTO users (name, age) VALUES (?, ?)",
        &.{ .{ .string = "Bob" }, .{ .int = 25 } },
    );

    var rows = try drv.query(
        "SELECT id, name, age FROM users WHERE age = ?",
        &.{.{ .int = 30 }},
    );
    defer rows.deinit();

    while (rows.next()) |row| {
        const user = try scanRow(UserRow, row);
        std.debug.print("User: id={d}, name={s}, age={d}\n", .{ user.id, user.name, user.age });
    }

    std.debug.print("\nPhase 0 + Phase 1 completed successfully.\n", .{});
}
