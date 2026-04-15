const std = @import("std");
const zent = @import("zent");

const sql = zent.sql;
const Dialect = zent.sql_dialect.Dialect;
const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
const scanRow = zent.sql_scan.scanRow;
const fromSchema = zent.codegen.graph.fromSchema;
const Entity = zent.codegen.entity;
const Client = zent.codegen.client;

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

    // --- Phase 2: Generated Client + CRUD ---
    std.debug.print("\n=== Phase 2: Generated CRUD ===\n", .{});
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // Create tables manually for demo (migration comes in Phase 4)
    _ = try drv.exec(
        "CREATE TABLE \"user\" (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)",
        &.{},
    );

    // Generate client
    const infos = comptime &[_]zent.codegen.graph.TypeInfo{ user_info, car_info, group_info };
    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // CREATE
    std.debug.print("-- CREATE --\n", .{});
    var create_builder1 = client.user.Create();
    defer create_builder1.deinit();
    _ = create_builder1.setValue("name", .{ .string = "Alice" });
    _ = create_builder1.setValue("age", .{ .int = 30 });
    const alice = try create_builder1.Save();
    std.debug.print("Created user: id={d}, name={s}, age={d}\n", .{ alice.id, alice.name, alice.age });

    var create_builder2 = client.user.Create();
    defer create_builder2.deinit();
    _ = create_builder2.setValue("name", .{ .string = "Bob" });
    _ = create_builder2.setValue("age", .{ .int = 25 });
    const bob = try create_builder2.Save();
    std.debug.print("Created user: id={d}, name={s}, age={d}\n", .{ bob.id, bob.name, bob.age });

    // QUERY with predicates
    std.debug.print("\n-- QUERY --\n", .{});
    const user_preds = client.user.predicates;

    var qbuilder = client.user.Query();
    defer qbuilder.deinit();
    _ = qbuilder.Where(&.{user_preds.ageEQ(.{ .int = 30 })});
    var users = try qbuilder.All();
    defer users.deinit();
    std.debug.print("Users with age=30: {d}\n", .{users.items.len});
    for (users.items) |u| {
        std.debug.print("  id={d}, name={s}, age={d}\n", .{ u.id, u.name, u.age });
    }

    // FIRST / ONLY
    var q2 = client.user.Query();
    defer q2.deinit();
    _ = q2.Where(&.{user_preds.nameEQ(.{ .string = "Alice" })});
    const only_alice = try q2.Only();
    std.debug.print("Only Alice: id={d}, name={s}\n", .{ only_alice.id, only_alice.name });

    // COUNT
    var q3 = client.user.Query();
    defer q3.deinit();
    const count = try q3.Count();
    std.debug.print("Total users: {d}\n", .{count});

    // UPDATE
    std.debug.print("\n-- UPDATE --\n", .{});
    var upd = client.user.Update();
    defer upd.deinit();
    _ = upd.set("age", 31)
        .Where(&.{user_preds.nameEQ(.{ .string = "Alice" })});
    const updated = try upd.Save();
    std.debug.print("Updated {d} row(s)\n", .{updated});

    // DELETE
    std.debug.print("\n-- DELETE --\n", .{});
    var del = client.user.Delete();
    defer del.deinit();
    _ = del.Where(&.{user_preds.nameEQ(.{ .string = "Bob" })});
    const deleted = try del.Exec();
    std.debug.print("Deleted {d} row(s)\n", .{deleted});

    var q4 = client.user.Query();
    defer q4.deinit();
    const count_after = try q4.Count();
    std.debug.print("Users after delete: {d}\n", .{count_after});

    std.debug.print("\nPhase 0 + Phase 1 + Phase 2 completed successfully.\n", .{});
}
