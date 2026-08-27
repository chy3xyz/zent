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
    // Symmetric with SKIP_PG in postgres.zig: setting SKIP_MYSQL skips every
    // MySQL integration test without needing a server. connect() is the
    // shared entry point, so one check covers all tests.
    if (std.process.Environ.getPosix(std.testing.environ, "SKIP_MYSQL") != null) return error.SkipZigTest;
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

test "MySQL: SaveIgnore ignores unique-key conflict" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const MyIgnoreUser = schema("MyIgnoreUser", .{
        .fields = &.{
            field.Int("score"),
        },
    });

    const graph = comptime buildGraph(&.{MyIgnoreUser});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS my_ignore_user", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b1 = try client.my_ignore_user.Create();
    defer b1.deinit();
    _ = try b1.setFieldValue("id", @as(i64, 99));
    _ = try b1.setFieldValue("score", @as(i64, 100));
    _ = try b1.SaveIgnore();

    // Second insert with the same PK must not error.
    var b2 = try client.my_ignore_user.Create();
    defer b2.deinit();
    _ = try b2.setFieldValue("id", @as(i64, 99));
    _ = try b2.setFieldValue("score", @as(i64, 200));
    _ = try b2.SaveIgnore();

    var rows = try drv.query("SELECT score FROM my_ignore_user WHERE id = ?", &.{.{ .int = 99 }});
    defer rows.deinit();
    const r = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 100), r.getInt(0).?);
}

test "MySQL: SaveOrUpdateOn uses business-key conflict target" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const MySetting = schema("MySetting", .{
        .fields = &.{
            field.String("key"),
            field.Int("app_id"),
            field.String("value"),
        },
    });

    const graph = comptime buildGraph(&.{MySetting});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS my_setting", &.{}) catch {};

    // Business-key unique index required by ON CONFLICT / ODKU.
    // MySQL requires a length prefix on TEXT columns used in indexes.
    _ = try drv.exec("CREATE UNIQUE INDEX idx_my_setting_key_app ON my_setting(`key`(255), app_id)", &.{});

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b1 = try client.my_setting.Create();
    defer b1.deinit();
    _ = try b1.setFieldValue("key", "site_name");
    _ = try b1.setFieldValue("app_id", @as(i64, 42));
    _ = try b1.setFieldValue("value", "zent");
    var e1 = try b1.SaveOrUpdateOn(&.{ "key", "app_id" });
    defer zent.codegen.deinitEntity(infos, infos[0], &e1, allocator);

    var b2 = try client.my_setting.Create();
    defer b2.deinit();
    _ = try b2.setFieldValue("key", "site_name");
    _ = try b2.setFieldValue("app_id", @as(i64, 42));
    _ = try b2.setFieldValue("value", "zapi");
    var e2 = try b2.SaveOrUpdateOn(&.{ "key", "app_id" });
    defer zent.codegen.deinitEntity(infos, infos[0], &e2, allocator);

    var rows = try drv.query("SELECT value FROM my_setting WHERE `key` = ? AND app_id = ?", &.{ .{ .string = "site_name" }, .{ .int = 42 } });
    defer rows.deinit();
    const r = rows.next() orelse return error.NoRow;
    try testing.expectEqualStrings("zapi", r.getText(0).?);
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

test "MySQL: JSONValue + WhereEntQL has(edge) work" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const CarBase = schema("MyJCar", .{
        .fields = &.{ field.String("model"), field.JSONValue("meta") },
    });
    const UserBase = schema("MyJUser", .{
        .fields = &.{ field.String("name"), field.JSONValue("settings") },
    });
    const Car = struct {
        pub const schema_name = CarBase.schema_name;
        pub const fields = CarBase.fields;
        pub const edges = CarBase.edges;
        pub const indexes = CarBase.indexes;
        pub const policy = CarBase.policy;
        pub const is_view = CarBase.is_view;
        pub const view_sql = CarBase.view_sql;
        pub const soft_delete = CarBase.soft_delete;
    };
    const User = struct {
        pub const schema_name = UserBase.schema_name;
        pub const fields = UserBase.fields;
        pub const edges = &.{edge.To("cars", CarBase)};
        pub const indexes = UserBase.indexes;
        pub const policy = UserBase.policy;
        pub const is_view = UserBase.is_view;
        pub const view_sql = UserBase.view_sql;
        pub const soft_delete = UserBase.soft_delete;
    };
    const graph = comptime buildGraph(&.{ User, Car });
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS my_j_user", &.{}) catch {};
    defer _ = drv.exec("DROP TABLE IF EXISTS my_j_car", &.{}) catch {};

    var c = Client.makeClient(infos, allocator, drv.asDriver());

    var ub = try c.my_j_user.Create();
    defer ub.deinit();
    _ = try ub.setFieldValue("name", "alice");
    _ = try ub.setFieldValue("settings", std.json.Value{ .string = "s1" });
    var u = try ub.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &u, allocator);

    var cb = try c.my_j_car.Create();
    defer cb.deinit();
    _ = try cb.setFieldValue("model", "m");
    _ = try cb.setFieldValue("meta", std.json.Value{ .integer = 7 });
    _ = try cb.setFieldValue("my_j_user_id", u.id);
    var car = try cb.Save();
    defer zent.codegen.deinitEntity(infos, infos[1], &car, allocator);

    {
        var q = c.my_j_car.Query();
        defer q.deinit();
        var rows = try q.All();
        defer {
            for (rows.items) |*e| zent.codegen.deinitEntity(infos, infos[1], e, allocator);
            rows.deinit();
        }
        try testing.expect(rows.items[0].meta == .integer);
        try testing.expectEqual(@as(i64, 7), rows.items[0].meta.integer);
    }

    {
        var q = c.my_j_user.Query();
        defer q.deinit();
        _ = try q.WhereEntQL("has(cars)");
        var users = try q.All();
        defer {
            for (users.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            users.deinit();
        }
        try testing.expectEqual(@as(usize, 1), users.items.len);
        try testing.expectEqualStrings("alice", users.items[0].name);
    }
}

test "MySQL: slow query times out" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const User = schema("User", .{
        .fields = &.{
            field.String("name"),
            field.Int("age"),
        },
    });

    const graph = comptime buildGraph(&.{User});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS user", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Insert a row first: on an empty table the WHERE clause is never
    // evaluated, so SLEEP never runs and the query returns instantly
    // without ever hitting the timeout.
    var cb = try client.user.Create();
    defer cb.deinit();
    _ = try cb.setFieldValue("name", "slow");
    _ = try cb.setFieldValue("age", 1);
    var saved = try cb.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &saved, allocator);

    var q = client.user.Query();
    defer q.deinit();
    _ = q.withTimeout(100);
    _ = try q.Where(&.{zent.sql.Raw("SLEEP(2) = 0")});
    const result = q.All();
    // MySQL/MariaDB interrupt SLEEP() server-side by returning 1 instead of
    // 0 (so `1 = 0` yields zero rows) rather than raising a timeout error.
    // Either zero rows (interrupted) or a QueryTimeout error proves the slow
    // query was cut short; an un-interrupted run would return the row.
    if (result) |rows| {
        defer rows.deinit();
        try testing.expectEqual(@as(usize, 0), rows.items.len);
    } else |err| {
        try testing.expectEqual(error.QueryTimeout, err);
    }

    // Driver should still be usable after the timeout.
    try drv.ping();

    var rows = try drv.query("SELECT 1 AS one", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 1), row.getInt(0).?);
}

test "MySQL: boolean column scans via getBool" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const FlagBase = schema("MyFlag", .{
        .fields = &.{ field.String("name"), field.Bool("active") },
    });
    const Flag = struct {
        pub const schema_name = FlagBase.schema_name;
        pub const fields = FlagBase.fields;
        pub const edges = FlagBase.edges;
        pub const indexes = FlagBase.indexes;
        pub const policy = FlagBase.policy;
        pub const is_view = FlagBase.is_view;
        pub const view_sql = FlagBase.view_sql;
        pub const soft_delete = FlagBase.soft_delete;
    };
    const graph = comptime buildGraph(&.{Flag});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS my_flag", &.{}) catch {};

    var c = Client.makeClient(infos, allocator, drv.asDriver());

    var b1 = try c.my_flag.Create();
    defer b1.deinit();
    _ = try b1.setFieldValue("name", "on");
    _ = try b1.setFieldValue("active", true);
    var e1 = try b1.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &e1, allocator);

    var b2 = try c.my_flag.Create();
    defer b2.deinit();
    _ = try b2.setFieldValue("name", "off");
    _ = try b2.setFieldValue("active", false);
    var e2 = try b2.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &e2, allocator);

    var q = c.my_flag.Query();
    defer q.deinit();
    var rows = try q.All();
    defer {
        for (rows.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
        rows.deinit();
    }
    try testing.expectEqual(@as(usize, 2), rows.items.len);
    var seen_on = false;
    var seen_off = false;
    for (rows.items) |e| {
        if (std.mem.eql(u8, e.name, "on")) {
            try testing.expect(e.active);
            seen_on = true;
        } else {
            try testing.expect(!e.active);
            seen_off = true;
        }
    }
    try testing.expect(seen_on and seen_off);
}

test "MySQL: decimal (DECIMAL(38,10)) field round-trips without truncation" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const Money = schema("Money", .{
        .fields = &.{field.Decimal("amount")},
    });
    const graph = comptime buildGraph(&.{Money});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS money", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());
    {
        var b = try client.money.Create();
        defer b.deinit();
        _ = try b.setFieldValue("amount", "19.99");
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &row, allocator);
        // MySQL has no RETURNING: Save echoes the input values back.
        try testing.expectEqualStrings("19.99", row.amount);
    }

    var q = client.money.Query();
    defer q.deinit();
    const rows = try q.All();
    defer {
        for (rows.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
        rows.deinit();
    }
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("19.9900000000", rows.items[0].amount);
}

test "MySQL: optimistic lock conflict" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const User = schema("MyLockedUser", .{
        .fields = &.{
            field.Int("id"),
            field.String("name"),
            field.Version("version"),
        },
    });

    const graph = comptime buildGraph(&.{User});
    const infos = graph.types;

    try migrate.migrateSchema(allocator, drv.asDriver(), infos);
    defer _ = drv.exec("DROP TABLE IF EXISTS my_locked_user", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b = try client.my_locked_user.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    var created = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);
    try testing.expectEqual(@as(i64, 0), created.version);

    // Simulate stale update: the row exists but the version value is wrong.
    var stale = created;
    stale.name = "bob";
    stale.version = 999;

    var ub = client.my_locked_user.Update();
    defer ub.deinit();
    _ = try ub.set("name", .{ .string = "bob" });
    _ = try ub.setFieldValue("version", stale.version);
    _ = try ub.Where(.{zent.sql.EQ("id", .{ .int = stale.id })});
    const result = ub.SaveOne();
    try testing.expectError(error.OptimisticLockConflict, result);
}

test "MySQL: optimistic lock update increments version" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const User = schema("MyLockedUser", .{
        .fields = &.{
            field.Int("id"),
            field.String("name"),
            field.Version("version"),
        },
    });

    const graph = comptime buildGraph(&.{User});
    const infos = graph.types;

    try migrate.migrateSchema(allocator, drv.asDriver(), infos);
    defer _ = drv.exec("DROP TABLE IF EXISTS my_locked_user", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b = try client.my_locked_user.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    var created = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);
    try testing.expectEqual(@as(i64, 0), created.version);

    var update = client.my_locked_user.Update();
    defer update.deinit();
    _ = try update.set("name", .{ .string = "bob" });
    _ = try update.setFieldValue("version", created.version);
    _ = try update.Where(.{client.my_locked_user.predicates.idEQ(.{ .int = created.id })});
    const affected = try update.Save();
    try testing.expectEqual(@as(usize, 1), affected);

    var q = client.my_locked_user.Query();
    defer q.deinit();
    _ = try q.Where(.{client.my_locked_user.predicates.idEQ(.{ .int = created.id })});
    const results = try q.All();
    defer {
        for (results.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
        results.deinit();
    }
    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("bob", results.items[0].name);
    try testing.expectEqual(@as(i64, 1), results.items[0].version);
}

test "MySQL: optimistic lock delete conflict" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const User = schema("MyLockedUser", .{
        .fields = &.{
            field.Int("id"),
            field.String("name"),
            field.Version("version"),
        },
    });

    const graph = comptime buildGraph(&.{User});
    const infos = graph.types;

    try migrate.migrateSchema(allocator, drv.asDriver(), infos);
    defer _ = drv.exec("DROP TABLE IF EXISTS my_locked_user", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b = try client.my_locked_user.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    var created = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);
    try testing.expectEqual(@as(i64, 0), created.version);

    var db = client.my_locked_user.Delete();
    defer db.deinit();
    _ = db.setVersion(999);
    _ = try db.Where(.{client.my_locked_user.predicates.idEQ(.{ .int = created.id })});
    const result = db.ExecOne();
    try testing.expectError(error.OptimisticLockConflict, result);
}

test "MySQL: optimistic lock soft delete conflict and success" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const SoftLockedUser = schema("MySoftLockedUser", .{
        .fields = &.{
            field.Int("id"),
            field.String("name"),
            field.Version("version"),
        },
        .mixins = &.{zent.core.mixin.SoftDeleteMixin},
        .soft_delete = true,
    });

    const graph = comptime buildGraph(&.{SoftLockedUser});
    const infos = graph.types;

    try migrate.migrateSchema(allocator, drv.asDriver(), infos);
    defer _ = drv.exec("DROP TABLE IF EXISTS my_soft_locked_user", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b = try client.my_soft_locked_user.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    var created = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);
    try testing.expectEqual(@as(i64, 0), created.version);

    // Stale version should fail with optimistic lock conflict.
    {
        var db = client.my_soft_locked_user.Delete();
        defer db.deinit();
        _ = db.setVersion(999);
        _ = try db.Where(.{client.my_soft_locked_user.predicates.idEQ(.{ .int = created.id })});
        const result = db.ExecOne();
        try testing.expectError(error.OptimisticLockConflict, result);
    }

    // Correct version should soft-delete the row and bump the version.
    {
        var db = client.my_soft_locked_user.Delete();
        defer db.deinit();
        _ = db.setVersion(created.version);
        _ = try db.Where(.{client.my_soft_locked_user.predicates.idEQ(.{ .int = created.id })});
        const affected = try db.Exec();
        try testing.expectEqual(@as(usize, 1), affected);
    }

    // Verify the row is still present but marked deleted and version incremented.
    var rows = try drv.query("SELECT deleted_at, version FROM my_soft_locked_user WHERE id = ?", &.{
        .{ .int = created.id },
    });
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expect(row.getInt(0) != null);
    try testing.expect(row.getInt(0).? > 0);
    try testing.expectEqual(@as(i64, 1), row.getInt(1).?);
}

test "MySQL: migrateSchema drops removed column" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // Create legacy table with an extra 'obsolete' column not in the schema.
    _ = try drv.exec("DROP TABLE IF EXISTS my_drop_test", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS my_drop_test", &.{}) catch {};
    _ = try drv.exec(
        "CREATE TABLE my_drop_test (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255), value INT, obsolete VARCHAR(255))",
        &.{},
    );

    const DropTest = schema("MyDropTest", .{
        .fields = &.{
            field.String("name"),
            field.Int("value"),
        },
    });

    const graph = comptime buildGraph(&.{DropTest});
    const infos = graph.types;

    const obsolete_count_sql =
        "SELECT COUNT(*) FROM information_schema.columns WHERE table_name = ? AND table_schema = DATABASE() AND column_name = 'obsolete'";

    // Run with drop_columns: false (default) → column remains.
    try migrate.migrateSchema(allocator, drv.asDriver(), infos);
    {
        var rows = try drv.query(obsolete_count_sql, &.{.{ .string = "my_drop_test" }});
        defer rows.deinit();
        const row = rows.next() orelse return error.NoRow;
        try testing.expectEqual(@as(i64, 1), row.getInt(0).?);
    }

    // Run with drop_columns: true → column gone.
    try migrate.migrateSchemaWithOptions(allocator, drv.asDriver(), infos, migrate.MigrateOptions{
        .drop_columns = true,
    });
    {
        var rows = try drv.query(obsolete_count_sql, &.{.{ .string = "my_drop_test" }});
        defer rows.deinit();
        const row = rows.next() orelse return error.NoRow;
        try testing.expectEqual(@as(i64, 0), row.getInt(0).?);
    }
}

test "MySQL: migrateSchema dry-run outputs SQL without executing" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const DREntity = schema("MyDrEntity", .{
        .fields = &.{
            field.String("name"),
            field.Int("value"),
        },
        .indexes = &.{
            index.Named("idx_my_drentity_name", &.{"name"}),
        },
    });

    const graph = comptime buildGraph(&.{DREntity});
    const infos = graph.types;

    // The table must not exist beforehand — drop leftovers from a previous run.
    _ = try drv.exec("DROP TABLE IF EXISTS my_dr_entity", &.{});

    // Run with dry_run: true — should NOT create any tables.
    try migrate.migrateSchemaWithOptions(allocator, drv.asDriver(), infos, migrate.MigrateOptions{
        .dry_run = true,
    });

    // Verify the table was not created (the DB is shared, so check the
    // specific table rather than counting all tables like the SQLite test).
    var rows = try drv.query(
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = ? AND table_schema = DATABASE()",
        &.{.{ .string = "my_dr_entity" }},
    );
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 0), row.getInt(0).?);
}

test "MySQL: WhereIn chunks OR-joins IN predicates" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const CodeBase = schema("MyWhereInCode", .{
        .fields = &.{field.Int("code")},
    });
    const Code = struct {
        pub const schema_name = CodeBase.schema_name;
        pub const fields = CodeBase.fields;
        pub const edges = CodeBase.edges;
        pub const indexes = CodeBase.indexes;
        pub const policy = CodeBase.policy;
        pub const is_view = CodeBase.is_view;
        pub const view_sql = CodeBase.view_sql;
        pub const soft_delete = CodeBase.soft_delete;
    };
    const graph = comptime buildGraph(&.{Code});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS my_where_in_code", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Seed rows with codes 0..4 plus one row in the second chunk (500).
    for (0..5) |i| {
        var b = try client.my_where_in_code.Create();
        defer b.deinit();
        _ = try b.setFieldValue("code", @as(i64, @intCast(i)));
        var e = try b.Save();
        zent.codegen.deinitEntity(infos, infos[0], &e, allocator);
    }
    {
        var b = try client.my_where_in_code.Create();
        defer b.deinit();
        _ = try b.setFieldValue("code", @as(i64, 500));
        var e = try b.Save();
        zent.codegen.deinitEntity(infos, infos[0], &e, allocator);
    }

    // Empty values -> error.EmptyInValues (no SQL is built).
    {
        var q = client.my_where_in_code.Query();
        defer q.deinit();
        try testing.expectError(error.EmptyInValues, q.WhereIn("code", &.{}));
    }

    // Single value.
    {
        const one = [_]zent.sql.Value{.{ .int = 3 }};
        var q = client.my_where_in_code.Query();
        defer q.deinit();
        _ = try q.WhereIn("code", &one);
        var items = try q.All();
        defer {
            for (items.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            items.deinit();
        }
        try testing.expectEqual(@as(usize, 1), items.items.len);
        try testing.expectEqual(@as(i64, 3), items.items[0].code);
    }

    // Multiple values.
    {
        const few = [_]zent.sql.Value{ .{ .int = 1 }, .{ .int = 3 } };
        var q = client.my_where_in_code.Query();
        defer q.deinit();
        _ = try q.WhereIn("code", &few);
        var items = try q.All();
        defer {
            for (items.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            items.deinit();
        }
        try testing.expectEqual(@as(usize, 2), items.items.len);
        var found_one = false;
        var found_three = false;
        for (items.items) |e| {
            if (e.code == 1) found_one = true;
            if (e.code == 3) found_three = true;
        }
        try testing.expect(found_one and found_three);
    }

    // >500 values force two IN chunks joined by OR (chunk_size = 500);
    // values 0..500 cover the seeded rows across both chunk boundaries,
    // so the second chunk must return the code-500 row.
    {
        var many: [501]zent.sql.Value = undefined;
        for (0..501) |i| many[i] = .{ .int = @intCast(i) };
        var q = client.my_where_in_code.Query();
        defer q.deinit();
        _ = try q.WhereIn("code", &many);
        var items = try q.All();
        defer {
            for (items.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            items.deinit();
        }
        try testing.expectEqual(@as(usize, 6), items.items.len);
        var found_500 = false;
        for (items.items) |e| {
            if (e.code == 500) found_500 = true;
        }
        try testing.expect(found_500);
    }
}

// Module-level storage for the filter predicate so the opaque pointer
// returned by the Filter rule remains valid through injectPrivacyFilters.
var my_filter_pred: zent.sql.Predicate = undefined;

fn myOwnerFilter(ctx: zent.privacy.PrivacyContext) ?*const anyopaque {
    if (ctx.user_id) |uid| {
        my_filter_pred = zent.sql.EQ("owner_id", .{ .int = uid });
        return @ptrCast(&my_filter_pred);
    }
    return null;
}

test "MySQL: privacy filter restricts rows by owner_id" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // Schema with owner_id field and a Filter-based privacy policy.
    const FilteredEntity = schema("MyFilteredEntity", .{
        .fields = &.{
            field.String("name"),
            field.Int("owner_id"),
        },
        .policy = zent.privacy.Policy{
            .rules = &.{
                zent.privacy.Allow,
                zent.privacy.Filter(myOwnerFilter),
            },
        },
    });

    const graph = comptime buildGraph(&.{FilteredEntity});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS my_filtered_entity", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Insert two rows: one owned by user 1, one owned by user 2.
    {
        var c1 = client.my_filtered_entity.withContext(.{ .user_id = 1 });
        var b1 = try c1.Create();
        defer b1.deinit();
        _ = try b1.setFieldValue("name", "alice-item");
        _ = try b1.setFieldValue("owner_id", @as(i64, 1));
        var e1 = try b1.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &e1, allocator);
        try testing.expect(e1.id > 0);
    }
    {
        var c2 = client.my_filtered_entity.withContext(.{ .user_id = 2 });
        var b2 = try c2.Create();
        defer b2.deinit();
        _ = try b2.setFieldValue("name", "bob-item");
        _ = try b2.setFieldValue("owner_id", @as(i64, 2));
        var e2 = try b2.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &e2, allocator);
        try testing.expect(e2.id > 0);
    }

    // User 1 can only see their own row.
    {
        var c1 = client.my_filtered_entity.withContext(.{ .user_id = 1 });
        var q = c1.Query();
        defer q.deinit();
        const results = try q.All();
        defer {
            for (results.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            results.deinit();
        }
        try testing.expectEqual(@as(usize, 1), results.items.len);
        try testing.expectEqualStrings("alice-item", results.items[0].name);
        try testing.expectEqual(@as(i64, 1), results.items[0].owner_id);
    }

    // User 2 can only see their own row.
    {
        var c2 = client.my_filtered_entity.withContext(.{ .user_id = 2 });
        var q = c2.Query();
        defer q.deinit();
        const results = try q.All();
        defer {
            for (results.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            results.deinit();
        }
        try testing.expectEqual(@as(usize, 1), results.items.len);
        try testing.expectEqualStrings("bob-item", results.items[0].name);
        try testing.expectEqual(@as(i64, 2), results.items[0].owner_id);
    }

    // User 3 sees nothing (filter doesn't match any row).
    {
        var c3 = client.my_filtered_entity.withContext(.{ .user_id = 999 });
        var q = c3.Query();
        defer q.deinit();
        const results = try q.All();
        defer {
            for (results.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            results.deinit();
        }
        try testing.expectEqual(@as(usize, 0), results.items.len);
    }

    // Anonymous user (no user_id) gets null from filter → no filter applied, sees all.
    {
        var c_anon = client.my_filtered_entity.withContext(.{});
        var q = c_anon.Query();
        defer q.deinit();
        const results = try q.All();
        defer {
            for (results.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            results.deinit();
        }
        try testing.expectEqual(@as(usize, 2), results.items.len);
    }
}

test "MySQL: BulkInsert multi-row derives ids from last_insert_id" {
    // Oracle MySQL 8.0 has no INSERT ... RETURNING: the codegen falls back to
    // driver.exec and derives one id per row from last_insert_id (see
    // src/codegen/create.zig, BulkInsert Save). This test pins that fallback.
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const BulkEntity = schema("MyBulkEntity", .{
        .fields = &.{
            field.String("name"),
            field.Int("score"),
        },
    });

    const graph = comptime buildGraph(&.{BulkEntity});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS my_bulk_entity", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Insert 3 rows in a single round-trip.
    var b = try client.my_bulk_entity.BulkInsert();
    defer b.deinit();
    _ = try b.setFieldValue("name", "alpha");
    _ = try b.setFieldValue("score", @as(i64, 100));
    _ = try b.Next();
    _ = try b.setFieldValue("name", "beta");
    _ = try b.setFieldValue("score", @as(i64, 200));
    _ = try b.Next();
    _ = try b.setFieldValue("name", "gamma");
    _ = try b.setFieldValue("score", @as(i64, 300));

    const ids = try b.Save();
    defer ids.deinit();

    try testing.expectEqual(@as(usize, 3), ids.items.len);
    // AUTO_INCREMENT ids from a single multi-row INSERT are consecutive.
    try testing.expect(ids.items[0] > 0);
    try testing.expectEqual(ids.items[0] + 1, ids.items[1]);
    try testing.expectEqual(ids.items[0] + 2, ids.items[2]);

    // Verify rows actually exist in the DB.
    var rows = try drv.query("SELECT id, name, score FROM my_bulk_entity ORDER BY id", &.{});
    defer rows.deinit();

    const r1 = rows.next() orelse return error.NoRow;
    try testing.expectEqual(ids.items[0], r1.getInt(0).?);
    try testing.expectEqualStrings("alpha", r1.getText(1).?);
    try testing.expectEqual(@as(i64, 100), r1.getInt(2).?);

    const r2 = rows.next() orelse return error.NoRow;
    try testing.expectEqual(ids.items[1], r2.getInt(0).?);
    try testing.expectEqualStrings("beta", r2.getText(1).?);
    try testing.expectEqual(@as(i64, 200), r2.getInt(2).?);

    const r3 = rows.next() orelse return error.NoRow;
    try testing.expectEqual(ids.items[2], r3.getInt(0).?);
    try testing.expectEqualStrings("gamma", r3.getText(1).?);
    try testing.expectEqual(@as(i64, 300), r3.getInt(2).?);

    try testing.expect(rows.next() == null);
}

test "MySQL: file-based migrations" {
    const allocator = testing.allocator;
    const io = testing.io;

    const dir_name = "test_migrations_file_mysql";
    try std.Io.Dir.cwd().createDirPath(io, dir_name);
    defer std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var dir = try std.Io.Dir.cwd().openDir(io, dir_name, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{
            .sub_path = "900201_create_my_file_items.up.sql",
            .data =
            \\CREATE TABLE my_file_items (id INTEGER PRIMARY KEY, name VARCHAR(255));
            \\INSERT INTO my_file_items (id, name) VALUES (1, 'first');
            ,
        });
        try dir.writeFile(io, .{
            .sub_path = "900201_create_my_file_items.down.sql",
            .data = "DELETE FROM my_file_items;",
        });
        try dir.writeFile(io, .{
            .sub_path = "900202_add_second_item.up.sql",
            .data = "INSERT INTO my_file_items (id, name) VALUES (2, 'second');",
        });
    }

    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // Clean leftovers from a previous run: the shared zent_schema_migrations
    // history would otherwise mark these versions as already applied.
    _ = try drv.exec("DROP TABLE IF EXISTS my_file_items", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS my_file_items", &.{}) catch {};
    _ = try drv.exec("DELETE FROM zent_schema_migrations WHERE version IN (?, ?)", &.{ .{ .int = 900201 }, .{ .int = 900202 } });
    defer _ = drv.exec("DELETE FROM zent_schema_migrations WHERE version IN (?, ?)", &.{ .{ .int = 900201 }, .{ .int = 900202 } }) catch {};

    try migrate.migrateFromFiles(io, allocator, drv.asDriver(), dir_name);

    var rows = try drv.query("SELECT COUNT(*) FROM my_file_items", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 2), row.getInt(0).?);

    try migrate.rollbackFiles(io, allocator, drv.asDriver(), dir_name, 1);

    var rows2 = try drv.query("SELECT COUNT(*) FROM my_file_items", &.{});
    defer rows2.deinit();
    const row2 = rows2.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 0), row2.getInt(0).?);
}

test "MySQL: database-level cascade delete" {
    const allocator = testing.allocator;

    const User = schema("MyCascadeUser", .{
        .fields = &.{ field.Int("id"), field.String("name") },
    });
    const Order = schema("MyCascadeOrder", .{
        .fields = &.{
            field.Int("id"),
        },
        .edges = &.{
            // O2M From edge: order.user -> user
            edge.From("user", User).Required(),
        },
    });

    const graph = comptime buildGraph(&.{ User, Order });
    const infos = graph.types;

    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    _ = try drv.exec("DROP TABLE IF EXISTS my_cascade_order", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS my_cascade_user", &.{});
    // Drop the child first at cleanup: defers run LIFO, and my_cascade_order
    // holds the FK referencing my_cascade_user.
    defer _ = drv.exec("DROP TABLE IF EXISTS my_cascade_user", &.{}) catch {};
    defer _ = drv.exec("DROP TABLE IF EXISTS my_cascade_order", &.{}) catch {};

    // Requires InnoDB (default engine on MySQL 8 / MariaDB 10) for FK
    // enforcement; createTableSQL emits FOREIGN KEY ... ON DELETE CASCADE.
    try migrate.migrateSchema(allocator, drv.asDriver(), infos);

    _ = try drv.exec("INSERT INTO my_cascade_user (id, name) VALUES (1, 'alice')", &.{});
    _ = try drv.exec("INSERT INTO my_cascade_order (id, user_id) VALUES (10, 1)", &.{});
    _ = try drv.exec("INSERT INTO my_cascade_order (id, user_id) VALUES (11, 1)", &.{});

    _ = try drv.exec("DELETE FROM my_cascade_user WHERE id = 1", &.{});

    var rows = try drv.query("SELECT COUNT(*) FROM my_cascade_order", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 0), row.getInt(0).?);
}

test "MySQL: stream iterator avoids loading all rows" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const StreamEntity = schema("MyStreamEntity", .{
        .fields = &.{
            field.String("name"),
            field.Int("idx"),
        },
    });

    const graph = comptime buildGraph(&.{StreamEntity});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS my_stream_entity", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Create 50 entities.
    for (0..50) |i| {
        var b = try client.my_stream_entity.Create();
        defer b.deinit();
        const name = try std.fmt.allocPrint(allocator, "entity_{d}", .{i});
        defer allocator.free(name);
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("idx", @as(i64, @intCast(i)));
        var entity = try b.Save();
        zent.codegen.deinitEntity(infos, infos[0], &entity, allocator);
    }

    // Stream all rows via iterator.
    {
        var q = client.my_stream_entity.Query();
        defer q.deinit();
        _ = try q.OrderBy(&.{zent.sql.OrderAsc("idx")});
        var iter = try q.Iterate();
        defer iter.deinit();

        var count: usize = 0;
        while (try iter.next()) |entity| {
            const expected_name = try std.fmt.allocPrint(allocator, "entity_{d}", .{count});
            defer allocator.free(expected_name);
            try testing.expectEqualStrings(expected_name, entity.name);
            try testing.expectEqual(@as(i64, @intCast(count)), entity.idx);
            count += 1;
        }
        try testing.expectEqual(@as(usize, 50), count);
    }
}

test "MySQL: beginTx propagates hooks and privacy_ctx to transaction entity clients" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // Entity with AlwaysAllow policy (requires privacy context to be set)
    // and hooks to verify propagation.
    const TxPropEntity = schema("MyTxPropEntity", .{
        .fields = &.{field.String("name")},
        .policy = zent.privacy.AlwaysAllow,
    });

    const graph = comptime buildGraph(&.{TxPropEntity});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS my_tx_prop_entity", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Container for verifying hook fired.
    const H = struct {
        var before_called: bool = false;
        fn beforeFn(ctx: *HookContext) HookError!void {
            _ = ctx;
            before_called = true;
        }
    };
    H.before_called = false;

    const hooks = &[_]Hook{
        Hook.initBefore(.create, H.beforeFn),
    };

    // Set hooks and privacy context on the entity client.
    client.my_tx_prop_entity = client.my_tx_prop_entity.withHooks(hooks);
    client.my_tx_prop_entity = client.my_tx_prop_entity.withContext(zent.privacy.PrivacyContext{ .user_id = 42 });

    // Verify hooks slice is non-empty on the parent client (precondition).
    try testing.expectEqual(@as(usize, 1), client.my_tx_prop_entity.hooks.len);

    // Begin a transaction.
    var tx = try Client.beginTx(infos, client);
    defer tx.deinit();

    // Verify hooks propagated to tx client.
    try testing.expectEqual(@as(usize, 1), tx.client.my_tx_prop_entity.hooks.len);

    // Verify privacy_ctx propagated to tx client.
    try testing.expect(tx.client.my_tx_prop_entity.privacy_ctx != null);
    try testing.expectEqual(@as(i64, 42), tx.client.my_tx_prop_entity.privacy_ctx.?.user_id);

    // Perform a create inside the transaction — should succeed (privacy allows)
    // and the before hook should fire.
    var b = try tx.client.my_tx_prop_entity.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "tx-hook-test");
    var entity = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &entity, allocator);

    try testing.expect(entity.id > 0);
    try testing.expect(H.before_called);
    try testing.expectEqualStrings("tx-hook-test", entity.name);

    try tx.commit();
}

test "MySQL: interceptor injects tenant filter into query/update/delete" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const TenantDoc = schema("MyTenantDoc", .{
        .fields = &.{
            field.String("name"),
            field.Int("tenant_id"),
        },
    });

    const graph = comptime buildGraph(&.{TenantDoc});
    const infos = graph.types;
    _ = try drv.exec("DROP TABLE IF EXISTS my_tenant_doc", &.{});
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS my_tenant_doc", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());
    defer Client.DeinitClient(infos, &client);

    // Multi-tenant interceptor: transparently scope every query/update/delete
    // to the current tenant (see the SQLite twin test for the full matrix).
    var tenant: i64 = 1;
    try Client.UseInterceptor(infos, &client, .{
        .ctx = &tenant,
        .intercept = struct {
            fn f(ctx: ?*anyopaque, view: *zent.runtime.intercept.QueryView) anyerror!void {
                const id: *i64 = @ptrCast(@alignCast(ctx.?));
                try view.whereEq("tenant_id", .{ .int = id.* });
            }
        }.f,
    });

    for ([_]struct { n: []const u8, t: i64 }{ .{ .n = "t1-doc", .t = 1 }, .{ .n = "t2-doc", .t = 2 } }) |s| {
        var b = try client.my_tenant_doc.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", s.n);
        _ = try b.setFieldValue("tenant_id", s.t);
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &e, allocator);
    }

    // Query reads only the current tenant's row.
    {
        var q = client.my_tenant_doc.Query();
        defer q.deinit();
        const rows = try q.All();
        defer {
            for (rows.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            rows.deinit();
        }
        try testing.expectEqual(@as(usize, 1), rows.items.len);
        try testing.expectEqualStrings("t1-doc", rows.items[0].name);
    }

    // Update without an explicit Where touches only the current tenant.
    {
        var u = client.my_tenant_doc.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "renamed");
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }

    // Delete scoped to tenant 2 removes exactly its row.
    tenant = 2;
    {
        var d = client.my_tenant_doc.Delete();
        defer d.deinit();
        try testing.expectEqual(@as(usize, 1), try d.Exec());
    }

    // Only tenant 1's renamed row remains.
    tenant = 1;
    var q = client.my_tenant_doc.Query();
    defer q.deinit();
    const rows = try q.All();
    defer {
        for (rows.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
        rows.deinit();
    }
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("renamed", rows.items[0].name);
}
