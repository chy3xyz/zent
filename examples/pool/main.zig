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

/// A pool keeps several connections open, and every `:memory:` open creates
/// its own private database — tables migrated through one connection are
/// invisible to the next, so with `min_connections = 2` this demo only ran
/// when the pool's LIFO borrow happened to hand back the migrating connection.
/// A shared-cache URI (`file:…?mode=memory&cache=shared`) cannot rescue it:
/// zent's `SQLiteDriver.open` calls `sqlite3_open` without `SQLITE_OPEN_URI`
/// (and nothing enables `SQLITE_CONFIG_URI`), so URI filenames are not
/// honored. Every connection therefore opens the same real file.
const db_path = "zentpool-demo.db";

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const graph = comptime buildGraph(&.{User});
    const user_info = graph.types[0];
    const infos = &[_]zent.codegen.graph.TypeInfo{user_info};

    // A leftover file from an earlier run would carry its rows into this one
    // (the `Only()` below expects exactly one user), so start empty and remove
    // the file on the way out. This defer is declared before the pool's, so
    // it runs after `pool.deinit()` has closed every connection. (`std.c.unlink`
    // because the demo links libc and needs no `Io` just to remove a file.)
    _ = std.c.unlink(db_path);
    defer _ = std.c.unlink(db_path);

    // Warm up a pool of SQLite connections.
    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                return SQLiteDriver.open(a, db_path);
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

    // `stats()` rather than the internal lists: it takes the mutex, and the
    // unlocked read this example used to do is a data race.
    const st = pool.stats();
    std.debug.print("Pool: total={d} in_use={d} available={d} waiters={d} exhausted={d}\n", .{
        st.total, st.in_use, st.available, st.waiters, st.exhausted_total,
    });
}
