//! Connection pool demo.
//!
//! Shows how to replace a single SQLite connection with a warmed-up,
//! health-checked pool and pass it transparently to `Client.makeClient`.
//!
//! Build and run:
//!   zig build run-pool

const std = @import("std");
const zent = @import("zent");

const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
const ConnPool = zent.sql_pool.ConnPool;
const buildGraph = zent.codegen.graph.buildGraph;
const Client = zent.codegen.client;
const migrate = zent.sql_schema;

const User = @import("schema.zig").User;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const graph = comptime buildGraph(&.{User});
    const user_info = graph.types[0];
    const infos = &[_]zent.codegen.graph.TypeInfo{user_info};

    // Warm up a pool of SQLite connections.
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

    // Migrate using the pooled driver.
    try migrate.migrateSchema(allocator, pool.asDriver(), infos);
    std.debug.print("Tables created via pooled driver.\n", .{});

    // The generated client accepts the pooled driver transparently.
    var client = Client.makeClient(infos, allocator, pool.asDriver());

    var b = try client.user.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "Alice");
    _ = try b.setFieldValue("age", 30);
    const alice = try b.Save();
    std.debug.print("Created user: id={d}, name={s}, age={d}\n", .{ alice.id, alice.name, alice.age });

    var q = client.user.Query();
    defer q.deinit();
    const found = try q.Only();
    std.debug.print("Queried user: id={d}, name={s}, age={d}\n", .{ found.id, found.name, found.age });

    std.debug.print("Pool size: {d} (available {d})\n", .{ pool.all.items.len, pool.available.items.len });
}
