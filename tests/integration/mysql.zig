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
const index = zent.core.index;
const edge = zent.core.edge;
const migrate = zent.sql_schema;
const schema = zent.core.schema.Schema;
const testing = std.testing;
const c_mysql = @import("mysql_c");
const Hook = zent.runtime.hook.Hook;
const HookContext = zent.runtime.hook.HookContext;
const HookError = zent.runtime.hook.HookError;
const Op = zent.runtime.hook.Op;

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

test "MySQL returns long strings without truncation" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    _ = try drv.exec("DROP TABLE IF EXISTS zent_long_test", &.{});
    _ = try drv.exec("CREATE TABLE zent_long_test (id INTEGER PRIMARY KEY, payload TEXT)", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS zent_long_test", &.{}) catch {};

    const long = try allocator.alloc(u8, 300);
    defer allocator.free(long);
    @memset(long, 'a');
    _ = try drv.exec("INSERT INTO zent_long_test (id, payload) VALUES (?, ?)", &.{ .{ .int = 1 }, .{ .string = long } });

    var rows = try drv.query("SELECT payload FROM zent_long_test", &.{});
    defer rows.deinit();

    const row = rows.next() orelse return error.NoRow;
    const got = row.getText(0) orelse return error.NoText;
    try testing.expectEqualStrings(long, got);
}

test "MySQL: migrateSchema is idempotent with existing table" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    _ = try drv.exec("DROP TABLE IF EXISTS my_migration", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS my_migration", &.{}) catch {};
    _ = try drv.exec("CREATE TABLE my_migration (id INTEGER PRIMARY KEY, score INTEGER NOT NULL)", &.{});

    const MyMigration = schema("MyMigration", .{
        .fields = &.{
            field.Int("score"),
            field.String("label"),
        },
        .indexes = &.{
            index.Named("idx_my_migration_score", &.{"score"}),
        },
    });
    const graph = comptime buildGraph(&.{MyMigration});

    try migrate.migrateSchema(allocator, drv.asDriver(), graph.types);
    try migrate.migrateSchema(allocator, drv.asDriver(), graph.types);

    var column_rows = try drv.query(
        "SELECT COUNT(*) FROM information_schema.columns WHERE table_name = ? AND table_schema = DATABASE() AND column_name = ?",
        &.{ .{ .string = "my_migration" }, .{ .string = "label" } },
    );
    defer column_rows.deinit();
    const column_row = column_rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 1), column_row.getInt(0).?);

    var index_rows = try drv.query(
        "SELECT COUNT(*) FROM information_schema.statistics WHERE table_name = ? AND table_schema = DATABASE() AND index_name = ?",
        &.{ .{ .string = "my_migration" }, .{ .string = "idx_my_migration_score" } },
    );
    defer index_rows.deinit();
    const index_row = index_rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 1), index_row.getInt(0).?);

    // The create-only API must also tolerate an existing MySQL index.
    try Client.createAllTables(graph.types, drv.asDriver());
    try Client.createAllTables(graph.types, drv.asDriver());
}

test "MySQL: prepared statement cache" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // Enable prepared-statement cache.
    drv.cache = zent.sql_cache.PreparedCache(16, *c_mysql.MYSQL_STMT){};

    _ = try drv.exec("DROP TABLE IF EXISTS zent_cache_test", &.{});
    _ = try drv.exec("CREATE TABLE zent_cache_test (id INT AUTO_INCREMENT PRIMARY KEY, val VARCHAR(255))", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS zent_cache_test", &.{}) catch {};

    _ = try drv.exec("INSERT INTO zent_cache_test (val) VALUES (?)", &.{.{ .string = "hello_cache" }});

    // First query — populates cache.
    var rows1 = try drv.query("SELECT val FROM zent_cache_test WHERE val = ?", &.{.{ .string = "hello_cache" }});
    defer rows1.deinit();
    const row1 = rows1.next() orelse return error.NoRow;
    try testing.expectEqualStrings("hello_cache", row1.getText(0).?);

    // Second query — should reuse cached statement.
    var rows2 = try drv.query("SELECT val FROM zent_cache_test WHERE val = ?", &.{.{ .string = "hello_cache" }});
    defer rows2.deinit();
    const row2 = rows2.next() orelse return error.NoRow;
    try testing.expectEqualStrings("hello_cache", row2.getText(0).?);
}

test "MySQL: connection pool basic operations" {
    const allocator = testing.allocator;

    // Pre-check: ensure MySQL is reachable before constructing the pool.
    var probe = connect(allocator) catch |err| return skipIfNoServer(err);
    probe.close();

    const Pool = zent.sql_pool.ConnPool(MySQLDriver);
    var pool = try Pool.init(allocator, .{
        .connect = connect,
        .min_connections = 2,
        .max_connections = 2,
        .health_check_on_borrow = false,
        .max_retries = 0,
    });
    defer pool.deinit();

    // Verify pool warmed up with min_connections.
    try testing.expectEqual(@as(usize, 2), pool.all.items.len);

    const drv = pool.asDriver();

    _ = try drv.exec("DROP TABLE IF EXISTS zent_pool_test", &.{});
    _ = try drv.exec("CREATE TABLE zent_pool_test (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255))", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS zent_pool_test", &.{}) catch {};

    _ = try drv.exec("INSERT INTO zent_pool_test (name) VALUES (?)", &.{.{ .string = "pooled" }});

    var rows = try drv.query("SELECT name FROM zent_pool_test", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqualStrings("pooled", row.getText(0).?);
}

test "MySQL: privacy deny blocks query" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const PrivateEntity = schema("PrivateEntity", .{
        .fields = &.{
            field.String("secret"),
        },
        .policy = zent.privacy.AlwaysDeny,
    });

    const graph = comptime buildGraph(&.{PrivateEntity});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS private_entity", &.{}) catch {};

    // Insert a row via raw SQL so there is data to deny.
    _ = try drv.exec("INSERT INTO private_entity (id, secret) VALUES (?, ?)", &.{ .{ .int = 1 }, .{ .string = "classified" } });

    var client = Client.makeClient(infos, allocator, drv.asDriver());
    client.private_entity = client.private_entity.withContext(zent.privacy.PrivacyContext{});

    try testing.expectError(error.PrivacyDenied, blk: {
        var qb = client.private_entity.Query();
        defer qb.deinit();
        break :blk qb.All();
    });
}

test "MySQL: hooks fire on create/update" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const HookedUser = schema("HookedUser", .{
        .fields = &.{
            field.String("note"),
            field.Int("counter"),
        },
    });

    const graph = comptime buildGraph(&.{HookedUser});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS hooked_user", &.{}) catch {};

    // Flag to verify before-create hook fired.
    const before_create_flag = struct {
        var called: bool = false;
    };
    const before_create_fn = struct {
        fn f(ctx: *HookContext) HookError!void {
            before_create_flag.called = true;
            if (ctx.op != .create) return error.HookFailed;
            if (!std.mem.eql(u8, ctx.table_name, "hooked_user")) return error.HookFailed;
        }
    }.f;

    // Flag to verify after-update hook fired.
    const after_update_flag = struct {
        var called: bool = false;
    };
    const after_update_fn = struct {
        fn f(ctx: *HookContext) HookError!void {
            after_update_flag.called = true;
            if (ctx.op != .update) return error.HookFailed;
            if (!std.mem.eql(u8, ctx.table_name, "hooked_user")) return error.HookFailed;
        }
    }.f;

    const hook1 = Hook.initBefore(.create, before_create_fn);
    const hook2 = Hook.initAfter(.update, after_update_fn);

    var client = Client.makeClient(infos, allocator, drv.asDriver());
    client.hooked_user = client.hooked_user.withHooks(&.{ hook1, hook2 });

    // Create — before-create hook should fire.
    {
        var b = try client.hooked_user.Create();
        defer b.deinit();
        _ = try b.setFieldValue("id", @as(i64, 1));
        _ = try b.setFieldValue("note", "hello");
        _ = try b.setFieldValue("counter", @as(i64, 1));
        var entity = try b.Save();
        defer zent.codegen.deinitEntity(infos, graph.types[0], &entity, allocator);
    }
    try testing.expect(before_create_flag.called);

    // Update — after-update hook should fire.
    {
        var b = client.hooked_user.Update();
        defer b.deinit();
        _ = try b.set("note", .{ .string = "world" });
        _ = try b.set("counter", .{ .int = 2 });
        _ = try b.Where(.{client.hooked_user.predicates.noteEQ(.{ .string = "hello" })});
        _ = try b.Save();
    }
    try testing.expect(after_update_flag.called);
}

test "MySQL: multi-insert and count" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const BulkItem = schema("BulkItem", .{
        .fields = &.{
            field.String("label"),
        },
    });

    const graph = comptime buildGraph(&.{BulkItem});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS bulk_item", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Insert 3 entities individually (avoids RETURNING not supported on older MySQL).
    {
        var b1 = try client.bulk_item.Create();
        defer b1.deinit();
        _ = try b1.setFieldValue("id", @as(i64, 1));
        _ = try b1.setFieldValue("label", "a");
        var e1 = try b1.Save();
        defer zent.codegen.deinitEntity(infos, graph.types[0], &e1, allocator);

        var b2 = try client.bulk_item.Create();
        defer b2.deinit();
        _ = try b2.setFieldValue("id", @as(i64, 2));
        _ = try b2.setFieldValue("label", "b");
        var e2 = try b2.Save();
        defer zent.codegen.deinitEntity(infos, graph.types[0], &e2, allocator);

        var b3 = try client.bulk_item.Create();
        defer b3.deinit();
        _ = try b3.setFieldValue("id", @as(i64, 3));
        _ = try b3.setFieldValue("label", "c");
        var e3 = try b3.Save();
        defer zent.codegen.deinitEntity(infos, graph.types[0], &e3, allocator);
    }

    // Count them.
    var count_qb = client.bulk_item.Query();
    defer count_qb.deinit();
    const count = try count_qb.Count();
    try testing.expectEqual(@as(i64, 3), count);
}

test "MySQL: ForUpdate in transaction" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const LockItem = schema("LockItem", .{
        .fields = &.{
            field.String("payload"),
        },
    });

    const graph = comptime buildGraph(&.{LockItem});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS lock_item", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Insert a row.
    {
        var b = try client.lock_item.Create();
        defer b.deinit();
        _ = try b.setFieldValue("id", @as(i64, 1));
        _ = try b.setFieldValue("payload", "locked");
        var entity = try b.Save();
        defer zent.codegen.deinitEntity(infos, graph.types[0], &entity, allocator);
    }

    // Begin transaction, SELECT ... FOR UPDATE, verify within tx, then commit.
    var tx_client = try Client.beginTx(infos, client);
    defer tx_client.deinit();

    var lock_qb = tx_client.client.lock_item.Query();
    defer lock_qb.deinit();
    _ = lock_qb.ForUpdate();
    var entities = try lock_qb.All();
    defer {
        for (entities.items) |*e| {
            zent.codegen.deinitEntity(infos, graph.types[0], e, allocator);
        }
        entities.deinit();
    }

    try testing.expectEqual(@as(usize, 1), entities.items.len);
    try testing.expectEqualStrings("locked", entities.items[0].payload);

    try tx_client.commit();
}

test "MySQL: MySQL-specific types (VARCHAR length, TEXT, BOOL round-trip)" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const TypeTest = schema("TypeTest", .{
        .fields = &.{
            field.String("short_text"),
            field.Text("long_text"),
            field.Bool("active"),
        },
    });

    const graph = comptime buildGraph(&.{TypeTest});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS type_test", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Create with specific type values.
    const long_str = try allocator.alloc(u8, 200);
    defer allocator.free(long_str);
    @memset(long_str, 'x');

    const created_id = blk: {
        var b = try client.type_test.Create();
        defer b.deinit();
        _ = try b.setFieldValue("id", @as(i64, 1));
        _ = try b.setFieldValue("short_text", "hello_types");
        _ = try b.setFieldValue("long_text", long_str);
        _ = try b.setFieldValue("active", true);
        var entity = try b.Save();
        defer zent.codegen.deinitEntity(infos, graph.types[0], &entity, allocator);
        break :blk @as(i64, 1);
    };

    // Read back and verify values survive round-trip.
    var type_qb = client.type_test.Query();
    defer type_qb.deinit();
    _ = try type_qb.Where(.{client.type_test.predicates.short_textEQ(.{ .string = "hello_types" })});
    var entities = try type_qb.All();
    defer {
        for (entities.items) |*e| {
            zent.codegen.deinitEntity(infos, graph.types[0], e, allocator);
        }
        entities.deinit();
    }

    try testing.expectEqual(@as(usize, 1), entities.items.len);
    const entity = entities.items[0];
    try testing.expectEqual(created_id, entity.id);
    try testing.expectEqualStrings("hello_types", entity.short_text);
    try testing.expectEqualStrings(long_str, entity.long_text);
    try testing.expectEqual(true, entity.active);
}

test "MySQL: SaveOrUpdate preserves auto-increment id and child rows" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const MyUpsertParent = schema("MyUpsertParent", .{
        .fields = &.{
            field.String("name"),
        },
    });
    const MyUpsertChild = schema("MyUpsertChild", .{
        .fields = &.{
            field.String("label"),
        },
        .edges = &.{
            edge.From("parent", MyUpsertParent).Required(),
        },
    });

    const graph = comptime buildGraph(&.{ MyUpsertParent, MyUpsertChild });
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS my_upsert_parent", &.{}) catch {};
    defer _ = drv.exec("DROP TABLE IF EXISTS my_upsert_child", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // First SaveOrUpdate: creates the parent row.
    var b1 = try client.my_upsert_parent.Create();
    defer b1.deinit();
    _ = try b1.setFieldValue("id", @as(i64, 1));
    _ = try b1.setFieldValue("name", "alice");
    var parent1 = try b1.SaveOrUpdate();
    defer zent.codegen.deinitEntity(infos, infos[0], &parent1, allocator);
    const original_id = parent1.id;
    try testing.expect(original_id != 0);

    // Insert a child referencing the parent.
    var cb = try client.my_upsert_child.Create();
    defer cb.deinit();
    _ = try cb.setFieldValue("parent_id", original_id);
    _ = try cb.setFieldValue("label", "child-of-alice");
    var child = try cb.Save();
    defer zent.codegen.deinitEntity(infos, infos[1], &child, allocator);

    // Second SaveOrUpdate with the same unique key: should UPDATE in place.
    var b2 = try client.my_upsert_parent.Create();
    defer b2.deinit();
    _ = try b2.setFieldValue("id", @as(i64, 1));
    _ = try b2.setFieldValue("name", "alice-updated");
    var parent2 = try b2.SaveOrUpdate();
    defer zent.codegen.deinitEntity(infos, infos[0], &parent2, allocator);

    // The id must be preserved (REPLACE INTO would delete and re-insert).
    try testing.expectEqual(original_id, parent2.id);

    // The child row must still exist.
    var rows = try drv.query("SELECT COUNT(*) FROM my_upsert_child WHERE parent_id = ?", &.{.{ .int = original_id }});
    defer rows.deinit();
    const r = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 1), r.getInt(0).?);

    // The parent name must reflect the update.
    var parent_rows = try drv.query("SELECT name FROM my_upsert_parent WHERE id = ?", &.{.{ .int = original_id }});
    defer parent_rows.deinit();
    const pr = parent_rows.next() orelse return error.NoRow;
    try testing.expectEqualStrings("alice-updated", pr.getText(0).?);
}
