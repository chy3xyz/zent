//! Integration tests for the MySQL/MariaDB driver against a local server.
//!
//! Expects a database `zent_test` on localhost:3306 accessible by root
//! without a password (common Homebrew MariaDB default).
//! Set MYSQL_DSN parts to override:
//!   MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASS, MYSQL_DB

const std = @import("std");
const zent = @import("zent");
const MySQLDriver = zent.sql_mysql.MySQLDriver;
const sql_statement = zent.sql_statement;
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

const Dsn = struct {
    host: [:0]const u8,
    port: u32,
    user: [:0]const u8,
    pass: [:0]const u8,
    db: [:0]const u8,
};

fn dsn() !Dsn {
    // Symmetric with SKIP_PG in postgres.zig: setting SKIP_MYSQL skips every
    // MySQL integration test without needing a server. dsn() is the shared
    // entry point, so one check covers all tests.
    if (std.process.Environ.getPosix(std.testing.environ, "SKIP_MYSQL") != null) return error.SkipZigTest;
    const port_s = std.process.Environ.getPosix(std.testing.environ, "MYSQL_PORT") orelse "3306";
    return .{
        .host = std.process.Environ.getPosix(std.testing.environ, "MYSQL_HOST") orelse "localhost",
        .port = try std.fmt.parseInt(u32, port_s, 10),
        .user = std.process.Environ.getPosix(std.testing.environ, "MYSQL_USER") orelse "root",
        .pass = std.process.Environ.getPosix(std.testing.environ, "MYSQL_PASS") orelse "",
        .db = std.process.Environ.getPosix(std.testing.environ, "MYSQL_DB") orelse "zent_test",
    };
}

fn connect(allocator: std.mem.Allocator) !MySQLDriver {
    const d = try dsn();
    return MySQLDriver.connect(allocator, d.host, d.port, d.user, d.pass, d.db);
}

fn connectSsl(allocator: std.mem.Allocator, cfg: MySQLDriver.SslConfig) !MySQLDriver {
    const d = try dsn();
    return MySQLDriver.connectOptsSsl(allocator, d.host, d.port, d.user, d.pass, d.db, cfg);
}

fn skipIfNoServer(e: anyerror) anyerror!void {
    switch (e) {
        error.MySQLConnectFailed => return error.SkipZigTest,
        else => return e,
    }
}

/// True when the server is MariaDB rather than MySQL.
///
/// The two share the wire protocol and the errno numbering but are not
/// behaviour-compatible, and this file is run against both: CI's service is
/// MariaDB 10.11, while a development machine usually has MySQL 8/9. A test
/// that asserts one server's behaviour fails on the other — which has twice
/// shipped a red tag (MySQL's stripped `column_default` quoting; MariaDB having
/// no functional indexes, and accepting `BEGIN` through its prepared-statement
/// protocol). Where the two genuinely differ, branch on this rather than
/// weakening the assertion to something both happen to satisfy.
fn isMariaDB(drv: *MySQLDriver) !bool {
    var rows = try drv.query("SELECT VERSION()", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return false;
    const version = row.getText(0) orelse return false;
    return std.mem.indexOf(u8, version, "MariaDB") != null;
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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

test "MySQL: crud.update answers true for an idempotent PUT (changed vs matched rows)" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const CfIdemProduct = schema("CfIdemProduct", .{
        .fields = &.{
            field.Int("tenant_id"),
            field.String("name"),
            field.Int("price_cents"),
        },
    });

    const graph = comptime buildGraph(&.{CfIdemProduct});
    const infos = graph.types;
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS cf_idem_product", &.{}) catch {};

    const client = zent.codegen.client.EntityClient(infos, infos[0]).init(allocator, drv.asDriver());
    const Service = zent.crud.CrudService(infos, infos[0], "tenant_id");
    var svc = Service.init(allocator, client);

    const id = try svc.create(.{ .id = 0, .tenant_id = 0, .name = "widget", .price_cents = 100 }, 1);

    var got = (try svc.get(allocator, 1, id)).?;
    defer zent.codegen.deinitEntity(infos, infos[0], &got, allocator);

    // Idempotent PUT: the fetched row written back unchanged. This server
    // reports *changed* rows for UPDATE (CLIENT_FOUND_ROWS is off), so the
    // statement itself answers 0 — the pre-fix `affected > 0` read that as
    // "missing" and answered false (a 404 upstream). The row exists, so the
    // answer must be true. MariaDB shares the changed-rows default
    // (mysql_stmt_affected_rows is the same wire call), so this holds on CI's
    // MariaDB 10.11 too and needs no isMariaDB branch.
    try testing.expect(try svc.update(got, 1));

    // A row that actually changes: affected > 0 on every dialect.
    var changed = got;
    changed.price_cents = 150;
    try testing.expect(try svc.update(changed, 1));

    // The (id, tenant) pair matches no row for another tenant: false.
    try testing.expect(!(try svc.update(changed, 2)));

    // A missing id in the right tenant: false.
    var missing = got;
    missing.id = id + 100000;
    try testing.expect(!(try svc.update(missing, 1)));
}

test "MySQL: crud_helpers.update reports matched rows, not changed rows" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const CfMatchCoupon = schema("CfMatchCoupon", .{
        .fields = &.{
            field.Int("tenant_id"),
            field.String("name"),
            field.Int("status"),
        },
    });

    const graph = comptime buildGraph(&.{CfMatchCoupon});
    const infos = graph.types;
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS cf_match_coupon", &.{}) catch {};

    const client = Client.makeClient(infos, allocator, drv.asDriver());

    var created = try zent.crud_helpers.create(client.cf_match_coupon, .{ .tenant_id = 1, .name = "new", .status = 20 });
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);

    const id_pred = client.cf_match_coupon.predicates.idEQ(.{ .int = created.id });
    try testing.expectEqual(@as(usize, 1), try zent.crud_helpers.update(client.cf_match_coupon, .{ .status = 30 }, .{id_pred}));

    // Idempotent write-back: 0 changed rows on this server, but the predicate
    // matches the row, so the count is 1 — the same answer SQLite/PostgreSQL
    // give natively, and what a `> 0` or `== 0` caller can rely on.
    try testing.expectEqual(@as(usize, 1), try zent.crud_helpers.update(client.cf_match_coupon, .{ .status = 30 }, .{id_pred}));

    // No row matches: 0 on every dialect.
    try testing.expectEqual(@as(usize, 0), try zent.crud_helpers.update(client.cf_match_coupon, .{ .status = 40 }, .{client.cf_match_coupon.predicates.idEQ(.{ .int = created.id + 100000 })}));
}

test "MySQL: crud_helpers.increment reports matched rows for a zero delta" {
    // `SET hits = hits + 0` changes nothing, so this server counts 0 changed
    // rows — measured as ROW_COUNT() = 0 against SQLite's changes() = 1 and
    // PostgreSQL's `UPDATE 1`. A caller reading 0 as "no such row" took the
    // wrong branch, so the zero path re-checks with the same count query
    // `update` uses. MariaDB reports changed rows the same way, so no
    // isMariaDB branch is needed.
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const CfIncrement = schema("CfIncrement", .{
        .fields = &.{
            field.String("name"),
            field.Int("hits"),
        },
    });

    const graph = comptime buildGraph(&.{CfIncrement});
    const infos = graph.types;
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS cf_increment", &.{}) catch {};

    const client = Client.makeClient(infos, allocator, drv.asDriver());

    var created = try zent.crud_helpers.create(client.cf_increment, .{ .name = "page", .hits = 10 });
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);

    const id_pred = client.cf_increment.predicates.idEQ(.{ .int = created.id });

    // A real increment changes the value, so the server counts the row.
    try testing.expectEqual(@as(usize, 1), try zent.crud_helpers.increment(client.cf_increment, "hits", 5, .{id_pred}));

    // A zero delta matches without changing: 0 changed rows on this server, and
    // the answer must still be 1.
    try testing.expectEqual(@as(usize, 1), try zent.crud_helpers.increment(client.cf_increment, "hits", 0, .{id_pred}));

    // A predicate that matches nothing is still 0.
    try testing.expectEqual(@as(usize, 0), try zent.crud_helpers.increment(
        client.cf_increment,
        "hits",
        0,
        .{client.cf_increment.predicates.idEQ(.{ .int = created.id + 100000 })},
    ));
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS my_setting", &.{}) catch {};

    // Business-key unique index required by ON CONFLICT / ODKU. `key` is a
    // VARCHAR(255) now, so the index needs no key length — a prefix index
    // would have made the uniqueness only cover the first 255 characters.
    _ = try drv.exec("CREATE UNIQUE INDEX idx_my_setting_key_app ON my_setting(`key`, app_id)", &.{});

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
    try Client.createAllTables(std.testing.allocator, graph.types, drv.asDriver());
    try Client.createAllTables(std.testing.allocator, graph.types, drv.asDriver());
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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

/// Read whichever server-side statement-timeout variable this server exposes
/// (MySQL: max_execution_time; MariaDB: max_statement_time) as text.
fn readServerTimeout(allocator: std.mem.Allocator, d: zent.sql_driver.Driver) ![]u8 {
    var rows = try d.query("SHOW VARIABLES LIKE 'max_execution_time'", &.{});
    defer rows.deinit();
    if (rows.next()) |row| return allocator.dupe(u8, row.getText(1).?);

    var rows2 = try d.query("SHOW VARIABLES LIKE 'max_statement_time'", &.{});
    defer rows2.deinit();
    if (rows2.next()) |row| return allocator.dupe(u8, row.getText(1).?);
    return allocator.dupe(u8, "");
}

test "MySQL: deadline-free statements after a deadline keep server timeout consistent" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();
    const d = drv.asDriver();

    const baseline = try readServerTimeout(allocator, d);
    defer allocator.free(baseline);

    // A deadline applies a non-default server timeout. `DO 1` produces no
    // result set, which exec() does not consume on the parameterless path.
    var ctx = zent.sql_driver.ExecutionContext{
        .deadline_ns = zent.sql_driver.monotonicNs() + 2 * std.time.ns_per_s,
    };
    _ = try d.execCtx(&ctx, "DO 1", &.{});

    // Two statements with no deadline: the first must restore DEFAULT, the
    // second is a no-op for the timeout state. Neither may error.
    _ = try d.exec("DO 1", &.{});
    var rows = try d.query("SELECT 1 AS one", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 1), row.getInt(0).?);

    // The connection must be back to the server default.
    const after = try readServerTimeout(allocator, d);
    defer allocator.free(after);
    try testing.expectEqualStrings(baseline, after);
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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

test "MySQL: allow_nullability_change adds a NOT NULL column with a backfill default" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // The legacy table matches the schema except for the missing `added`, so
    // the only operation the migration has to perform is the ADD COLUMN.
    _ = try drv.exec("DROP TABLE IF EXISTS my_nn_doc", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS my_nn_doc", &.{}) catch {};
    _ = try drv.exec(
        "CREATE TABLE my_nn_doc (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255) NOT NULL)",
        &.{},
    );
    _ = try drv.exec("INSERT INTO my_nn_doc (name) VALUES ('before')", &.{});

    // `added` is an Int on purpose: `field.String` maps to MySQL `TEXT`, and
    // MySQL rejects a DEFAULT on a TEXT column (errno 1101), which would fail
    // the CREATE TABLE long before this test reaches the ADD COLUMN.
    const NnDoc = schema("MyNnDoc", .{
        .fields = &.{
            field.String("name"),
            field.Int("added").Default(7),
        },
    });

    const graph = comptime buildGraph(&.{NnDoc});
    const infos = graph.types;

    try migrate.migrateSchemaWithOptions(allocator, drv.asDriver(), infos, migrate.MigrateOptions{
        .allow_nullability_change = true,
    });

    var rows = try drv.query(
        "SELECT is_nullable FROM information_schema.columns WHERE table_name = 'my_nn_doc' AND table_schema = DATABASE() AND column_name = 'added'",
        &.{},
    );
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqualStrings("NO", row.getText(0).?);

    // MySQL filled the row that predates the column from the DEFAULT.
    var value_rows = try drv.query("SELECT added FROM my_nn_doc", &.{});
    defer value_rows.deinit();
    const value_row = value_rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 7), value_row.getInt(0).?);
}

test "MySQL: an ALTER ADD COLUMN that would be errno 1101 is refused before it is emitted" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const drop = "DROP TABLE IF EXISTS my_alter_guard";
    _ = try drv.exec(drop, &.{});
    defer _ = drv.exec(drop, &.{}) catch {};

    // Two schemas over one table name, run in order. The first is the table as
    // a previous deploy left it; migrating it records the `create_table`
    // version, so the second run takes the ALTER path and never generates a
    // CREATE TABLE — which is exactly the case the CREATE-side MySQL guard
    // cannot cover, because for a table that already exists there is no
    // CREATE to guard.
    const BeforeBase = schema("MyAlterGuard", .{
        .fields = &.{field.String("name")},
    });
    const before_graph = comptime buildGraph(&.{BeforeBase});
    try migrate.migrateSchema(allocator, drv.asDriver(), before_graph.types);

    // `field.Text` is TEXT on MySQL (only `String`/`Enum` are VARCHAR(255)),
    // and MySQL refuses a DEFAULT on it — so the ADD COLUMN this schema asks
    // for is errno 1101. The refusal is zent's own error, raised client-side
    // before the statement is sent, which is why it is the same on MySQL and
    // on MariaDB (whose 10.2+ *does* allow a TEXT default — the guard is
    // deliberately the stricter of the two servers' rules).
    const AfterBase = schema("MyAlterGuard", .{
        .fields = &.{
            field.String("name"),
            field.Text("body").Default("none"),
        },
    });
    const after_graph = comptime buildGraph(&.{AfterBase});
    try testing.expectError(
        error.MySQLTextColumnCannotHaveDefault,
        migrate.migrateSchema(allocator, drv.asDriver(), after_graph.types),
    );

    // The statement never reached the server: the column is not there, and the
    // history did not record the step as applied.
    var rows = try drv.query(
        "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ?",
        &.{ .{ .string = "my_alter_guard" }, .{ .string = "body" } },
    );
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 0), row.getInt(0).?);

    // The dry run answers the same way, and it does so through the CREATE-side
    // guard: it prints the CREATE TABLE this schema would need, and that
    // statement carries the same DEFAULT. (It emits no ALTER at all — see the
    // note on `MigrateOptions.dry_run` — so this is the only guard it can
    // reach, and the point here is that it reaches one instead of printing SQL
    // the server would reject.)
    try testing.expectError(
        error.MySQLTextColumnCannotHaveDefault,
        migrate.migrateSchemaWithOptions(allocator, drv.asDriver(), after_graph.types, migrate.MigrateOptions{ .dry_run = true }),
    );
}

test "MySQL: an existing column's nullability fails closed, it does not get a MODIFY" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // `loose` is nullable where the schema says NOT NULL. MySQL changes a
    // column only through `MODIFY COLUMN`, which replaces the *whole*
    // definition — and the introspection here reports a bare `data_type` with
    // no DEFAULT and no AUTO_INCREMENT, so the rewrite would drop attributes it
    // never saw. The migration must refuse rather than guess.
    _ = try drv.exec("DROP TABLE IF EXISTS my_nn_loose_doc", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS my_nn_loose_doc", &.{}) catch {};
    _ = try drv.exec(
        "CREATE TABLE my_nn_loose_doc (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255) NOT NULL, loose VARCHAR(255) DEFAULT 'kept')",
        &.{},
    );

    const NnLooseDoc = schema("MyNnLooseDoc", .{
        .fields = &.{
            field.String("name"),
            field.String("loose"),
        },
    });

    const graph = comptime buildGraph(&.{NnLooseDoc});
    const infos = graph.types;

    try testing.expectError(error.MySQLNullabilityChangeUnsafe, migrate.migrateSchemaWithOptions(
        allocator,
        drv.asDriver(),
        infos,
        migrate.MigrateOptions{ .allow_nullability_change = true },
    ));

    // Nothing was rewritten: the column is still nullable and still carries the
    // DEFAULT a `MODIFY COLUMN` would have stripped.
    var rows = try drv.query(
        "SELECT is_nullable, column_default FROM information_schema.columns WHERE table_name = 'my_nn_loose_doc' AND table_schema = DATABASE() AND column_name = 'loose'",
        &.{},
    );
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqualStrings("YES", row.getText(0).?);

    // MariaDB reports `column_default` as the literal expression text, so its
    // string default comes back quoted ('kept'), while MySQL 8+ strips the
    // quoting and reports `kept`. Both mean the DEFAULT survived — which is the
    // assertion here — so compare the content, not the vendor's rendering.
    const reported = row.getText(1).?;
    const unquoted = if (reported.len >= 2 and reported[0] == '\'' and reported[reported.len - 1] == '\'')
        reported[1 .. reported.len - 1]
    else
        reported;
    try testing.expectEqualStrings("kept", unquoted);
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

test "MySQL: dry-run previews an incremental migration without applying it" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // A legacy table that matches V1 of the schema (created by hand, so the
    // migration history has no create_table version for it). Runs on both
    // MySQL and MariaDB: the assertions below are existence-only, which both
    // servers answer identically.
    _ = try drv.exec("DROP TABLE IF EXISTS my_dr_inc", &.{});
    _ = try drv.exec("CREATE TABLE my_dr_inc (id BIGINT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255) NOT NULL)", &.{});
    _ = try drv.exec("INSERT INTO my_dr_inc (name) VALUES ('a')", &.{});

    // V2 adds a column.
    const DrInc = schema("MyDrInc", .{
        .fields = &.{
            field.String("name"),
            field.Int("age"),
        },
    });
    const graph = comptime buildGraph(&.{DrInc});

    // The preview: runs clean, changes nothing — the new column is not added.
    try migrate.migrateSchemaWithOptions(allocator, drv.asDriver(), graph.types, migrate.MigrateOptions{
        .dry_run = true,
    });
    {
        var rows = try drv.query(
            "SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'my_dr_inc' AND table_schema = DATABASE() AND column_name = 'age'",
            &.{},
        );
        defer rows.deinit();
        const row = rows.next() orelse return error.NoRow;
        try testing.expectEqual(@as(i64, 0), row.getInt(0).?);
    }

    // The real run applies what the preview showed.
    try migrate.migrateSchema(allocator, drv.asDriver(), graph.types);
    {
        var rows = try drv.query(
            "SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'my_dr_inc' AND table_schema = DATABASE() AND column_name = 'age'",
            &.{},
        );
        defer rows.deinit();
        const row = rows.next() orelse return error.NoRow;
        try testing.expectEqual(@as(i64, 1), row.getInt(0).?);
    }
}

test "MySQL: dry-run fails closed on a TEXT DEFAULT in ALTER like the real path" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // V1 migrated for real, so the history has the create_table version and
    // the V2 diff reaches the ALTER ADD COLUMN generator — the guard the
    // BLOB/TEXT restriction lives on for existing tables (errno 1101).
    _ = try drv.exec("DROP TABLE IF EXISTS my_dr_text", &.{});
    const V1 = schema("MyDrText", .{
        .fields = &.{
            field.String("name"),
        },
    });
    const graph_v1 = comptime buildGraph(&.{V1});
    try migrate.migrateSchema(allocator, drv.asDriver(), graph_v1.types);

    // V2 adds a TEXT column with a DEFAULT — a shape MySQL rejects, which
    // must be diagnosed at generation time on BOTH paths, never printed or
    // executed. The guard is a pure function of the schema, so this holds on
    // MariaDB too.
    const V2 = schema("MyDrText", .{
        .fields = &.{
            field.String("name"),
            field.Text("body").Default("x"),
        },
    });
    const graph_v2 = comptime buildGraph(&.{V2});

    try testing.expectError(
        error.MySQLTextColumnCannotHaveDefault,
        migrate.migrateSchemaWithOptions(allocator, drv.asDriver(), graph_v2.types, migrate.MigrateOptions{ .dry_run = true }),
    );
    try testing.expectError(
        error.MySQLTextColumnCannotHaveDefault,
        migrate.migrateSchemaWithOptions(allocator, drv.asDriver(), graph_v2.types, .{}),
    );

    // Neither run added the column.
    var rows = try drv.query(
        "SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'my_dr_text' AND table_schema = DATABASE() AND column_name = 'body'",
        &.{},
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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

test "MySQL: eager-loaded children respect interceptor tenant scope" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const ChildBase = schema("MyEagerTenantChild", .{
        .fields = &.{
            field.Int("parent_id"),
            field.String("name"),
            field.Int("tenant_id"),
        },
    });
    const ParentBase = schema("MyEagerTenantParent", .{
        .fields = &.{
            field.String("name"),
            field.Int("tenant_id"),
        },
        .edges = &.{edge.To("children", ChildBase).Field("parent_id")},
    });

    const graph = comptime buildGraph(&.{ ParentBase, ChildBase });
    const infos = graph.types;
    _ = try drv.exec("DROP TABLE IF EXISTS my_eager_tenant_child", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS my_eager_tenant_parent", &.{});
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
    // Child first at cleanup (defer LIFO): it holds the FK to the parent.
    defer _ = drv.exec("DROP TABLE IF EXISTS my_eager_tenant_parent", &.{}) catch {};
    defer _ = drv.exec("DROP TABLE IF EXISTS my_eager_tenant_child", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());
    defer Client.DeinitClient(infos, &client);

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

    var p1: i64 = 0;
    {
        var b = try client.my_eager_tenant_parent.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "p1");
        _ = try b.setFieldValue("tenant_id", @as(i64, 1));
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &e, allocator);
        p1 = e.id;
    }
    var p2: i64 = 0;
    {
        var b = try client.my_eager_tenant_parent.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "p2");
        _ = try b.setFieldValue("tenant_id", @as(i64, 2));
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &e, allocator);
        p2 = e.id;
    }
    for ([_]struct { parent: i64, name: []const u8, t: i64 }{
        .{ .parent = p1, .name = "p1-t1", .t = 1 },
        .{ .parent = p1, .name = "p1-t2", .t = 2 },
        .{ .parent = p2, .name = "p2-t2", .t = 2 },
    }) |s| {
        var b = try client.my_eager_tenant_child.Create();
        defer b.deinit();
        _ = try b.setFieldValue("parent_id", s.parent);
        _ = try b.setFieldValue("name", s.name);
        _ = try b.setFieldValue("tenant_id", s.t);
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[1], &e, allocator);
    }

    // Tenant 1 must not see parent 1's tenant-2 child through the eager load.
    {
        var q = client.my_eager_tenant_parent.Query();
        defer q.deinit();
        _ = try q.WithEdge("children");
        const parents = try q.All();
        defer {
            for (parents.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            parents.deinit();
        }
        try testing.expectEqual(@as(usize, 1), parents.items.len);
        const children = parents.items[0].edges.children.?;
        try testing.expectEqual(@as(usize, 1), children.len);
        try testing.expectEqualStrings("p1-t1", children[0].name);
    }
}

test "MySQL: eager-load interceptor scope is unambiguous on JOIN edges (m2o + m2m)" {
    // Companion to the o2m test above: the m2o neighbour query joins the
    // source table and the m2m one joins the junction. When either carries the
    // same tenant column as the target, an unqualified interceptor EQ fails
    // with "Column 'app_id' in where clause is ambiguous" (the shape zmshop
    // hit on the checkout path).
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const FileBase = schema("MyXjFile", .{
        .fields = &.{ field.String("path"), field.Int("app_id") },
    });
    const ImageBase = schema("MyXjImage", .{
        .fields = &.{
            field.String("caption"),
            field.Int("app_id"),
            field.Int("file_id").Optional(),
        },
    });
    const TagBase = schema("MyXjTag", .{
        .fields = &.{ field.String("label"), field.Int("app_id") },
    });
    const PostBase = schema("MyXjPost", .{
        .fields = &.{ field.String("title"), field.Int("app_id") },
    });
    const PostTag = schema("MyXjPostTag", .{
        .fields = &.{
            field.Int("my_xj_post_id"),
            field.Int("my_xj_tag_id"),
            field.Int("app_id"),
        },
        .indexes = &.{index.Fields(&.{ "my_xj_post_id", "my_xj_tag_id" }).Unique()},
    });

    const Image = struct {
        pub const schema_name = ImageBase.schema_name;
        pub const fields = ImageBase.fields;
        pub const edges = &.{edge.From("file", FileBase).Field("file_id")};
        pub const indexes = ImageBase.indexes;
    };
    const Tag = struct {
        pub const schema_name = TagBase.schema_name;
        pub const fields = TagBase.fields;
        pub const edges = &.{edge.To("posts", PostBase).Through(PostTag)};
        pub const indexes = TagBase.indexes;
    };
    const Post = struct {
        pub const schema_name = PostBase.schema_name;
        pub const fields = PostBase.fields;
        pub const edges = &.{edge.To("tags", TagBase).Through(PostTag)};
        pub const indexes = PostBase.indexes;
    };

    const graph = comptime buildGraph(&.{ FileBase, Image, Tag, Post, PostTag });
    const infos = graph.types;
    const file_info = infos[0];
    const image_info = infos[1];
    const tag_info = infos[2];
    const post_info = infos[3];

    _ = try drv.exec("DROP TABLE IF EXISTS my_xj_post_tag", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS my_xj_image", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS my_xj_tag", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS my_xj_post", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS my_xj_file", &.{});
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
    // Defer LIFO drops the junction and the FK holder before their targets.
    defer _ = drv.exec("DROP TABLE IF EXISTS my_xj_file", &.{}) catch {};
    defer _ = drv.exec("DROP TABLE IF EXISTS my_xj_post", &.{}) catch {};
    defer _ = drv.exec("DROP TABLE IF EXISTS my_xj_tag", &.{}) catch {};
    defer _ = drv.exec("DROP TABLE IF EXISTS my_xj_image", &.{}) catch {};
    defer _ = drv.exec("DROP TABLE IF EXISTS my_xj_post_tag", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());
    defer Client.DeinitClient(infos, &client);

    var tenant: i64 = 1;
    try Client.UseInterceptor(infos, &client, .{
        .ctx = &tenant,
        .intercept = struct {
            fn f(ctx: ?*anyopaque, view: *zent.runtime.intercept.QueryView) anyerror!void {
                const id: *i64 = @ptrCast(@alignCast(ctx.?));
                try view.whereEq("app_id", .{ .int = id.* });
            }
        }.f,
    });

    // f1/app1, f2/app2, f3/app1.
    var file_ids: [3]i64 = undefined;
    for (&file_ids, 0..) |*out, i| {
        var b = try client.my_xj_file.Create();
        defer b.deinit();
        _ = try b.setFieldValue("path", if (i == 0) "f1" else if (i == 1) "f2" else "f3");
        _ = try b.setFieldValue("app_id", @as(i64, if (i == 1) 2 else 1));
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, file_info, &e, allocator);
        out.* = e.id;
    }
    // i1/app1→f1, i2/app1→f2 (cross-tenant reference), i3/app2→f3.
    for ([_]struct { caption: []const u8, app: i64, file: usize }{
        .{ .caption = "i1", .app = 1, .file = 0 },
        .{ .caption = "i2", .app = 1, .file = 1 },
        .{ .caption = "i3", .app = 2, .file = 2 },
    }) |s| {
        var b = try client.my_xj_image.Create();
        defer b.deinit();
        _ = try b.setFieldValue("caption", s.caption);
        _ = try b.setFieldValue("app_id", s.app);
        _ = try b.setFieldValue("file_id", file_ids[s.file]);
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, image_info, &e, allocator);
    }

    {
        var q = client.my_xj_image.Query();
        defer q.deinit();
        _ = try q.WithEdge("file");
        const images = try q.All();
        defer {
            for (images.items) |*e| zent.codegen.deinitEntity(infos, image_info, e, allocator);
            images.deinit();
        }
        try testing.expectEqual(@as(usize, 2), images.items.len);
        try testing.expectEqualStrings("f1", images.items[0].edges.file.?[0].path);
        try testing.expect(images.items[1].edges.file == null);
    }
    tenant = 2;
    {
        var q = client.my_xj_image.Query();
        defer q.deinit();
        _ = try q.WithEdge("file");
        const images = try q.All();
        defer {
            for (images.items) |*e| zent.codegen.deinitEntity(infos, image_info, e, allocator);
            images.deinit();
        }
        try testing.expectEqual(@as(usize, 1), images.items.len);
        try testing.expect(images.items[0].edges.file == null);
    }

    // t1/app1, t2/app2, t3/app1.
    var tag_ids: [3]i64 = undefined;
    for (&tag_ids, 0..) |*out, i| {
        var b = try client.my_xj_tag.Create();
        defer b.deinit();
        _ = try b.setFieldValue("label", if (i == 0) "t1" else if (i == 1) "t2" else "t3");
        _ = try b.setFieldValue("app_id", @as(i64, if (i == 1) 2 else 1));
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, tag_info, &e, allocator);
        out.* = e.id;
    }
    // p1/app1, p2/app2.
    var post_ids: [2]i64 = undefined;
    for (&post_ids, 0..) |*out, i| {
        var b = try client.my_xj_post.Create();
        defer b.deinit();
        _ = try b.setFieldValue("title", if (i == 0) "p1" else "p2");
        _ = try b.setFieldValue("app_id", @as(i64, @intCast(i + 1)));
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, post_info, &e, allocator);
        out.* = e.id;
    }
    for ([_]struct { post: usize, tag: usize }{
        .{ .post = 0, .tag = 0 }, // app1 ↔ app1
        .{ .post = 0, .tag = 1 }, // app1 post linked to an app2 tag
        .{ .post = 1, .tag = 2 }, // app2 post linked to an app1 tag
    }) |l| {
        _ = try drv.exec(
            "INSERT INTO my_xj_post_tag (my_xj_post_id, my_xj_tag_id, app_id) VALUES (?, ?, ?)",
            &.{
                .{ .int = post_ids[l.post] },
                .{ .int = tag_ids[l.tag] },
                .{ .int = if (l.post == 0) 1 else 2 },
            },
        );
    }

    tenant = 1;
    {
        var q = client.my_xj_post.Query();
        defer q.deinit();
        _ = try q.WithEdge("tags");
        const posts = try q.All();
        defer {
            for (posts.items) |*e| zent.codegen.deinitEntity(infos, post_info, e, allocator);
            posts.deinit();
        }
        try testing.expectEqual(@as(usize, 1), posts.items.len);
        try testing.expectEqualStrings("p1", posts.items[0].title);
        const tags = posts.items[0].edges.tags.?;
        try testing.expectEqual(@as(usize, 1), tags.len);
        try testing.expectEqualStrings("t1", tags[0].label);
    }
    tenant = 2;
    {
        var q = client.my_xj_post.Query();
        defer q.deinit();
        _ = try q.WithEdge("tags");
        const posts = try q.All();
        defer {
            for (posts.items) |*e| zent.codegen.deinitEntity(infos, post_info, e, allocator);
            posts.deinit();
        }
        try testing.expectEqual(@as(usize, 1), posts.items.len);
        try testing.expectEqualStrings("p2", posts.items[0].title);
        try testing.expect(posts.items[0].edges.tags == null);
    }
}

test "MySQL: no-arg exec consumes a SELECT result set" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // A no-arg SELECT through exec returns rows; if that result set is left
    // pending, libmysql rejects the NEXT command with errno 2014
    // ("Commands out of sync"). Exercise select-then-select and
    // select-then-parameterized-exec to cover both follow-up paths.
    _ = try drv.exec("SELECT 1", &.{});
    _ = try drv.exec("SELECT 2", &.{});
    _ = try drv.exec("DO 1", &.{});

    var rows = try drv.query("SELECT 7 AS seven", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 7), row.getInt(0).?);

    // Parameterized exec still works right after the no-arg ones.
    _ = try drv.exec("DO ?", &.{.{ .int = 1 }});
}

test "MySQL: QueryEdge edge traversal uses dialect placeholders and quoting" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const CarBase = schema("MyQtCar", .{
        .fields = &.{field.String("model")},
    });
    const GroupBase = schema("MyQtGroup", .{
        .fields = &.{field.String("name")},
        .mixins = &.{zent.core.mixin.SoftDeleteMixin},
        .soft_delete = true,
    });
    const UserBase = schema("MyQtUser", .{
        .fields = &.{field.String("name")},
    });
    const Car = struct {
        pub const schema_name = CarBase.schema_name;
        pub const fields = CarBase.fields;
        pub const edges = &.{edge.From("owner", UserBase).Ref("cars")};
        pub const indexes = CarBase.indexes;
        pub const policy = CarBase.policy;
        pub const is_view = CarBase.is_view;
        pub const view_sql = CarBase.view_sql;
        pub const soft_delete = CarBase.soft_delete;
    };
    const Group = struct {
        pub const schema_name = GroupBase.schema_name;
        pub const fields = GroupBase.fields;
        pub const edges = &.{edge.To("users", UserBase)};
        pub const indexes = GroupBase.indexes;
        pub const policy = GroupBase.policy;
        pub const is_view = GroupBase.is_view;
        pub const view_sql = GroupBase.view_sql;
        pub const soft_delete = GroupBase.soft_delete;
    };
    const User = struct {
        pub const schema_name = UserBase.schema_name;
        pub const fields = UserBase.fields;
        pub const edges = &.{ edge.To("cars", CarBase), edge.To("groups", GroupBase) };
        pub const indexes = UserBase.indexes;
        pub const policy = UserBase.policy;
        pub const is_view = UserBase.is_view;
        pub const view_sql = UserBase.view_sql;
        pub const soft_delete = UserBase.soft_delete;
    };

    const graph = comptime buildGraph(&.{ User, Car, Group });
    const infos = graph.types;
    const user_info = infos[0];
    const car_info = infos[1];
    const group_info = infos[2];

    // Junction first: it references both entity tables.
    _ = try drv.exec("DROP TABLE IF EXISTS my_qt_group_my_qt_user", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS my_qt_car", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS my_qt_group", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS my_qt_user", &.{});
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
    // Single defer so the drops run junction → car → group → user (reverse
    // order would hit MySQL error 3730 for the still-referencing FKs).
    defer {
        _ = drv.exec("DROP TABLE IF EXISTS my_qt_group_my_qt_user", &.{}) catch {};
        _ = drv.exec("DROP TABLE IF EXISTS my_qt_car", &.{}) catch {};
        _ = drv.exec("DROP TABLE IF EXISTS my_qt_group", &.{}) catch {};
        _ = drv.exec("DROP TABLE IF EXISTS my_qt_user", &.{}) catch {};
    }

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var g1: i64 = 0;
    var g2: i64 = 0;
    var g3: i64 = 0;
    {
        var b = try client.my_qt_group.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "g1");
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, group_info, &e, allocator);
        g1 = e.id;
    }
    {
        var b = try client.my_qt_group.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "g2");
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, group_info, &e, allocator);
        g2 = e.id;
    }
    {
        var b = try client.my_qt_group.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "g3");
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, group_info, &e, allocator);
        g3 = e.id;
    }

    var alice: i64 = 0;
    {
        var b = try client.my_qt_user.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "alice");
        _ = try b.AddEdge("groups", &.{ g1, g2 });
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, user_info, &e, allocator);
        alice = e.id;
    }
    var bob: i64 = 0;
    {
        var b = try client.my_qt_user.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "bob");
        _ = try b.AddEdge("groups", &.{g3});
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, user_info, &e, allocator);
        bob = e.id;
    }

    var bob_car: i64 = 0;
    {
        var b = try client.my_qt_car.Create();
        defer b.deinit();
        _ = try b.setFieldValue("model", "a1");
        _ = try b.setFieldValue("owner_id", alice);
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, car_info, &e, allocator);
    }
    {
        var b = try client.my_qt_car.Create();
        defer b.deinit();
        _ = try b.setFieldValue("model", "a2");
        _ = try b.setFieldValue("owner_id", alice);
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, car_info, &e, allocator);
    }
    {
        var b = try client.my_qt_car.Create();
        defer b.deinit();
        _ = try b.setFieldValue("model", "b1");
        _ = try b.setFieldValue("owner_id", bob);
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, car_info, &e, allocator);
        bob_car = e.id;
    }

    // Soft-delete one of alice's groups; the traversal must not surface it.
    {
        var d = client.my_qt_group.Delete();
        defer d.deinit();
        _ = try d.Where(.{client.my_qt_group.predicates.idEQ(.{ .int = g2 })});
        try testing.expectEqual(@as(usize, 1), try d.Exec());
    }

    // O2M: alice's two cars.
    {
        var cars = try client.my_qt_user.QueryEdge("cars", &.{alice});
        defer {
            for (cars.items) |*e| zent.codegen.deinitEntity(infos, car_info, e, allocator);
            cars.deinit();
        }
        try testing.expectEqual(@as(usize, 2), cars.items.len);
        var saw_a1 = false;
        var saw_a2 = false;
        for (cars.items) |c| {
            if (std.mem.eql(u8, c.model, "a1")) saw_a1 = true;
            if (std.mem.eql(u8, c.model, "a2")) saw_a2 = true;
        }
        try testing.expect(saw_a1 and saw_a2);
    }

    // Multi-parent O2M: the IN list spans both users.
    {
        var cars = try client.my_qt_user.QueryEdge("cars", &.{ alice, bob });
        defer {
            for (cars.items) |*e| zent.codegen.deinitEntity(infos, car_info, e, allocator);
            cars.deinit();
        }
        try testing.expectEqual(@as(usize, 3), cars.items.len);
    }

    // M2M: alice belongs to g1 (g2 is soft-deleted).
    {
        var groups = try client.my_qt_user.QueryEdge("groups", &.{alice});
        defer {
            for (groups.items) |*e| zent.codegen.deinitEntity(infos, group_info, e, allocator);
            groups.deinit();
        }
        try testing.expectEqual(@as(usize, 1), groups.items.len);
        try testing.expectEqual(g1, groups.items[0].id);
    }

    // M2M: bob belongs to g3.
    {
        var groups = try client.my_qt_user.QueryEdge("groups", &.{bob});
        defer {
            for (groups.items) |*e| zent.codegen.deinitEntity(infos, group_info, e, allocator);
            groups.deinit();
        }
        try testing.expectEqual(@as(usize, 1), groups.items.len);
        try testing.expectEqual(g3, groups.items[0].id);
    }

    // M2O inverse: car -> owner.
    {
        var owners = try client.my_qt_car.QueryEdge("owner", &.{bob_car});
        defer {
            for (owners.items) |*e| zent.codegen.deinitEntity(infos, user_info, e, allocator);
            owners.deinit();
        }
        try testing.expectEqual(@as(usize, 1), owners.items.len);
        try testing.expectEqualStrings("bob", owners.items[0].name);
    }

    // Empty parent list short-circuits without touching the database.
    {
        var none = try client.my_qt_user.QueryEdge("cars", &[_]i64{});
        defer none.deinit();
        try testing.expectEqual(@as(usize, 0), none.items.len);
    }
}

test "MySQL: Update edge writes maintain M2M and O2M associations" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const CarBase = schema("MyEwCar", .{
        .fields = &.{ field.String("model"), field.Int("owner_id").Optional() },
    });
    const GroupBase = schema("MyEwGroup", .{
        .fields = &.{field.String("name")},
    });
    const UserBase = schema("MyEwUser", .{
        .fields = &.{field.String("name")},
    });
    const UserGroup = schema("MyEwUserGroup", .{
        .fields = &.{ field.Int("my_ew_user_id"), field.Int("my_ew_group_id") },
        // Explicit through schemas need their own uniqueness guarantee for
        // idempotent `INSERT IGNORE`.
        .indexes = &.{index.Fields(&.{ "my_ew_user_id", "my_ew_group_id" }).Unique()},
    });
    const Car = struct {
        pub const schema_name = CarBase.schema_name;
        pub const fields = CarBase.fields;
        pub const edges = &.{edge.From("owner", UserBase).Ref("cars")};
        pub const indexes = CarBase.indexes;
    };
    const Group = struct {
        pub const schema_name = GroupBase.schema_name;
        pub const fields = GroupBase.fields;
        pub const edges = &.{edge.To("users", UserBase).Through(UserGroup)};
        pub const indexes = GroupBase.indexes;
    };
    const User = struct {
        pub const schema_name = UserBase.schema_name;
        pub const fields = UserBase.fields;
        pub const edges = &.{
            edge.To("cars", CarBase),
            edge.To("groups", GroupBase).Through(UserGroup),
        };
        pub const indexes = UserBase.indexes;
    };

    const graph = comptime buildGraph(&.{ User, Car, Group, UserGroup });
    const infos = graph.types;
    const user_info = infos[0];
    const car_info = infos[1];
    const group_info = infos[2];

    _ = try drv.exec("DROP TABLE IF EXISTS my_ew_user_group", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS my_ew_car", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS my_ew_group", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS my_ew_user", &.{});
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
    defer {
        _ = drv.exec("DROP TABLE IF EXISTS my_ew_user_group", &.{}) catch {};
        _ = drv.exec("DROP TABLE IF EXISTS my_ew_car", &.{}) catch {};
        _ = drv.exec("DROP TABLE IF EXISTS my_ew_group", &.{}) catch {};
        _ = drv.exec("DROP TABLE IF EXISTS my_ew_user", &.{}) catch {};
    }

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var uids: [2]i64 = undefined;
    for (&uids, 0..) |*out, i| {
        var b = try client.my_ew_user.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", if (i == 0) "u1" else "u2");
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, user_info, &e, allocator);
        out.* = e.id;
    }
    var gids: [3]i64 = undefined;
    for (&gids, 0..) |*out, i| {
        var b = try client.my_ew_group.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", if (i == 0) "g1" else if (i == 1) "g2" else "g3");
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, group_info, &e, allocator);
        out.* = e.id;
    }
    var cids: [3]i64 = undefined;
    for (&cids, 0..) |*out, i| {
        var b = try client.my_ew_car.Create();
        defer b.deinit();
        _ = try b.setFieldValue("model", if (i == 0) "c1" else if (i == 1) "c2" else "c3");
        if (i == 0) {
            _ = try b.setFieldValue("owner_id", uids[0]);
        } else if (i == 1) {
            _ = try b.setFieldValue("owner_id", uids[1]);
        }
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, car_info, &e, allocator);
        out.* = e.id;
    }

    const preds = client.my_ew_user.predicates;

    // M2M Add is idempotent: applying the same ids twice keeps two rows.
    for (0..2) |iter| {
        var u = client.my_ew_user.Update();
        defer u.deinit();
        // MySQL reports *changed* rows, not matched rows, so a no-op UPDATE
        // yields 0. Vary the value to keep the row-count assertion meaningful
        // on every dialect; the association assertions below are the point of
        // this loop.
        var name_buf: [16]u8 = undefined;
        _ = try u.setFieldValue("name", try std.fmt.bufPrint(&name_buf, "u1-{d}", .{iter}));
        _ = try u.Where(.{preds.idEQ(.{ .int = uids[0] })});
        _ = try u.AddEdgeIDs("groups", &.{ gids[0], gids[1] });
        // MySQL reports changed rows, not matched rows (a no-op UPDATE is 0),
        // so the row count is not a portable assertion. The association state
        // asserted right after is what this test is about — and because the
        // edge writes share the same WHERE scope, a missed source row would
        // fail those assertions anyway.
        _ = try u.Save();
    }
    {
        var groups = try client.my_ew_user.QueryEdge("groups", &.{uids[0]});
        defer {
            for (groups.items) |*e| zent.codegen.deinitEntity(infos, group_info, e, allocator);
            groups.deinit();
        }
        try testing.expectEqual(@as(usize, 2), groups.items.len);
    }

    // Seed u2 with g3 so we can prove scope isolation.
    {
        var u = client.my_ew_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "u2");
        _ = try u.Where(.{preds.idEQ(.{ .int = uids[1] })});
        _ = try u.AddEdgeIDs("groups", &.{gids[2]});
        // MySQL reports changed rows, not matched rows (a no-op UPDATE is 0),
        // so the row count is not a portable assertion. The association state
        // asserted right after is what this test is about — and because the
        // edge writes share the same WHERE scope, a missed source row would
        // fail those assertions anyway.
        _ = try u.Save();
    }

    // Remove one association from u1 only.
    {
        var u = client.my_ew_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "u1");
        _ = try u.Where(.{preds.idEQ(.{ .int = uids[0] })});
        _ = try u.RemoveEdgeIDs("groups", &.{gids[0]});
        // MySQL reports changed rows, not matched rows (a no-op UPDATE is 0),
        // so the row count is not a portable assertion. The association state
        // asserted right after is what this test is about — and because the
        // edge writes share the same WHERE scope, a missed source row would
        // fail those assertions anyway.
        _ = try u.Save();
    }
    {
        var groups = try client.my_ew_user.QueryEdge("groups", &.{uids[0]});
        defer {
            for (groups.items) |*e| zent.codegen.deinitEntity(infos, group_info, e, allocator);
            groups.deinit();
        }
        try testing.expectEqual(@as(usize, 1), groups.items.len);
        try testing.expectEqual(gids[1], groups.items[0].id);
    }

    // Give u2 g1 too, then Clear u1: u2 must keep both associations.
    {
        var u = client.my_ew_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "u2");
        _ = try u.Where(.{preds.idEQ(.{ .int = uids[1] })});
        _ = try u.AddEdgeIDs("groups", &.{gids[0]});
        // MySQL reports changed rows, not matched rows (a no-op UPDATE is 0),
        // so the row count is not a portable assertion. The association state
        // asserted right after is what this test is about — and because the
        // edge writes share the same WHERE scope, a missed source row would
        // fail those assertions anyway.
        _ = try u.Save();
    }
    {
        var u = client.my_ew_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "u1");
        _ = try u.Where(.{preds.idEQ(.{ .int = uids[0] })});
        _ = try u.ClearEdge("groups");
        // MySQL reports changed rows, not matched rows (a no-op UPDATE is 0),
        // so the row count is not a portable assertion. The association state
        // asserted right after is what this test is about — and because the
        // edge writes share the same WHERE scope, a missed source row would
        // fail those assertions anyway.
        _ = try u.Save();
    }
    {
        var groups = try client.my_ew_user.QueryEdge("groups", &.{uids[0]});
        defer {
            for (groups.items) |*e| zent.codegen.deinitEntity(infos, group_info, e, allocator);
            groups.deinit();
        }
        try testing.expectEqual(@as(usize, 0), groups.items.len);
    }
    {
        var groups = try client.my_ew_user.QueryEdge("groups", &.{uids[1]});
        defer {
            for (groups.items) |*e| zent.codegen.deinitEntity(infos, group_info, e, allocator);
            groups.deinit();
        }
        try testing.expectEqual(@as(usize, 2), groups.items.len);
    }

    // O2M Set: detaches c1 from u1 and attaches c3 to u1.
    {
        var u = client.my_ew_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "u1");
        _ = try u.Where(.{preds.idEQ(.{ .int = uids[0] })});
        _ = try u.SetEdgeIDs("cars", &.{cids[2]});
        // MySQL reports changed rows, not matched rows (a no-op UPDATE is 0),
        // so the row count is not a portable assertion. The association state
        // asserted right after is what this test is about — and because the
        // edge writes share the same WHERE scope, a missed source row would
        // fail those assertions anyway.
        _ = try u.Save();
    }
    try expectMyCarOwner(&client, infos, car_info, cids[0], null);
    try expectMyCarOwner(&client, infos, car_info, cids[2], uids[0]);
    try expectMyCarOwner(&client, infos, car_info, cids[1], uids[1]);

    // O2M Clear nulls u1's FK; u2's car is untouched.
    {
        var u = client.my_ew_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "u1");
        _ = try u.Where(.{preds.idEQ(.{ .int = uids[0] })});
        _ = try u.ClearEdge("cars");
        // MySQL reports changed rows, not matched rows (a no-op UPDATE is 0),
        // so the row count is not a portable assertion. The association state
        // asserted right after is what this test is about — and because the
        // edge writes share the same WHERE scope, a missed source row would
        // fail those assertions anyway.
        _ = try u.Save();
    }
    try expectMyCarOwner(&client, infos, car_info, cids[2], null);
    try expectMyCarOwner(&client, infos, car_info, cids[1], uids[1]);

    // Set with empty ids is replace-with-empty: detach only.
    {
        var u = client.my_ew_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "u2");
        _ = try u.Where(.{preds.idEQ(.{ .int = uids[1] })});
        _ = try u.SetEdgeIDs("cars", &.{});
        // MySQL reports changed rows, not matched rows (a no-op UPDATE is 0),
        // so the row count is not a portable assertion. The association state
        // asserted right after is what this test is about — and because the
        // edge writes share the same WHERE scope, a missed source row would
        // fail those assertions anyway.
        _ = try u.Save();
    }
    try expectMyCarOwner(&client, infos, car_info, cids[1], null);

    // A `From` edge (my_ew_car.owner) writes its FK column in the UPDATE's own
    // SET clause — no companion `setFieldValue`, no detach statement, and the
    // same predicate scopes it. See Z15.
    {
        var u = client.my_ew_car.Update();
        defer u.deinit();
        _ = try u.Where(.{client.my_ew_car.predicates.idEQ(.{ .int = cids[0] })});
        _ = try u.SetEdgeIDs("owner", &.{uids[0]});
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }
    try expectMyCarOwner(&client, infos, car_info, cids[0], uids[0]);
    // Re-point, then clear — both are single-column writes.
    {
        var u = client.my_ew_car.Update();
        defer u.deinit();
        _ = try u.Where(.{client.my_ew_car.predicates.idEQ(.{ .int = cids[0] })});
        _ = try u.SetEdgeIDs("owner", &.{uids[1]});
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }
    try expectMyCarOwner(&client, infos, car_info, cids[0], uids[1]);
    {
        var u = client.my_ew_car.Update();
        defer u.deinit();
        _ = try u.Where(.{client.my_ew_car.predicates.idEQ(.{ .int = cids[0] })});
        _ = try u.ClearEdge("owner");
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }
    try expectMyCarOwner(&client, infos, car_info, cids[0], null);
    // A From edge points at one row: two ids is an argument error.
    {
        var u = client.my_ew_car.Update();
        defer u.deinit();
        _ = try u.Where(.{client.my_ew_car.predicates.idEQ(.{ .int = cids[0] })});
        try testing.expectError(error.TooManyEdgeTargets, u.SetEdgeIDs("owner", &.{ uids[0], uids[1] }));
    }
}

fn expectMyCarOwner(
    client: anytype,
    comptime infos: []const zent.codegen.graph.TypeInfo,
    comptime car_info: zent.codegen.graph.TypeInfo,
    car_id: i64,
    expected: ?i64,
) !void {
    var q = client.my_ew_car.Query();
    defer q.deinit();
    _ = try q.Where(.{client.my_ew_car.predicates.idEQ(.{ .int = car_id })});
    var car = (try q.First()) orelse return error.NoRow;
    defer zent.codegen.deinitEntity(infos, car_info, &car, std.testing.allocator);
    try std.testing.expectEqual(expected, car.owner_id);
}

test "MySQL: outbox claim is exclusive and requeue re-enables a row" {
    const allocator = testing.allocator;
    const outbox = zent.outbox;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const graph = comptime buildGraph(&.{outbox.OutboxMessage});
    const infos = graph.types;
    const OutboxOps = outbox.Outbox(infos, outbox.info);

    _ = try drv.exec("DROP TABLE IF EXISTS outbox_message", &.{});
    try migrate.migrateSchema(allocator, drv.asDriver(), infos);
    defer _ = drv.exec("DROP TABLE IF EXISTS outbox_message", &.{}) catch {};

    const client = Client.makeClient(infos, allocator, drv.asDriver());

    const id1 = try OutboxOps.enqueue(client, 1000, .{
        .aggregate_type = "p",
        .aggregate_id = 1,
        .event_type = "a",
        .payload = "{}",
    });
    _ = try OutboxOps.enqueue(client, 2000, .{
        .aggregate_type = "p",
        .aggregate_id = 2,
        .event_type = "b",
        .payload = "{}",
    });

    // First claim flips both rows to processing; a second claim gets none.
    const first = try OutboxOps.claim(allocator, client, 10);
    defer OutboxOps.freeEntries(allocator, first);
    try testing.expectEqual(@as(usize, 2), first.len);

    const second = try OutboxOps.claim(allocator, client, 10);
    defer OutboxOps.freeEntries(allocator, second);
    try testing.expectEqual(@as(usize, 0), second.len);

    // Fresh claims carry a non-NULL claimed_at, so a generous stale threshold
    // reclaims nothing; threshold 0 reclaims every processing row.
    try testing.expectEqual(@as(usize, 0), try OutboxOps.requeueStale(allocator, client, 3600));
    try testing.expectEqual(@as(usize, 2), try OutboxOps.requeueStale(allocator, client, 0));
    const reclaimed = try OutboxOps.claim(allocator, client, 10);
    defer OutboxOps.freeEntries(allocator, reclaimed);
    try testing.expectEqual(@as(usize, 2), reclaimed.len);

    // requeue returns a row to pending so it can be claimed again.
    try OutboxOps.requeue(allocator, client, id1, 1);
    const third = try OutboxOps.claim(allocator, client, 10);
    defer OutboxOps.freeEntries(allocator, third);
    try testing.expectEqual(@as(usize, 1), third.len);
    try testing.expectEqual(id1, third[0].id);
}

test "MySQL: migration lock times out while another session holds it" {
    const allocator = testing.allocator;

    // Two independent sessions: the first holds the named lock, the second
    // runs the migrator and must give up when GET_LOCK returns 0.
    var holder = connect(allocator) catch |err| return skipIfNoServer(err);
    defer holder.close();
    var waiter = connect(allocator) catch |err| return skipIfNoServer(err);
    defer waiter.close();

    _ = try holder.exec("SELECT GET_LOCK(?, 0)", &.{.{ .string = migrate.mysql_lock_name }});
    defer _ = holder.exec("SELECT RELEASE_LOCK(?)", &.{.{ .string = migrate.mysql_lock_name }}) catch {};

    const LockProbe = schema("MyLockProbe", .{
        .fields = &.{field.String("name")},
    });
    const graph = comptime buildGraph(&.{LockProbe});
    const infos = graph.types;

    // GET_LOCK timeouts are whole seconds, so the migrator waits 1s before
    // reporting the timeout.
    const res = migrate.migrateSchemaWithOptions(allocator, waiter.asDriver(), infos, .{
        .lock_timeout_ms = 1000,
    });
    try testing.expectError(error.MigrationLockTimeout, res);
}

test "MySQL: a binding list of the wrong length is a param count mismatch, not a query failure" {
    // The count is compared on the client side (`mysql_stmt_param_count`), so
    // this behaves identically on MySQL and MariaDB and needs no `isMariaDB`
    // branch. What it pins is the mapping: this used to arrive as
    // `QueryFailed`, which is the same name a syntax error gets, so a caller
    // could not tell "I built the argument list wrong" from "the query is
    // wrong". The direct (`MySQLDriver.exec`) entry point still reports its
    // own `MySQLParamCountMismatch`; the unified name is what the driver
    // interface — and so the ORM — returns.
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    _ = try drv.exec("DROP TABLE IF EXISTS zent_my_params", &.{});
    _ = try drv.exec(
        \\CREATE TABLE zent_my_params (
        \\  id INT AUTO_INCREMENT PRIMARY KEY,
        \\  name VARCHAR(255) NOT NULL,
        \\  score INT
        \\)
    , &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS zent_my_params", &.{}) catch {};

    const d = drv.asDriver();
    const insert = "INSERT INTO zent_my_params (name, score) VALUES (?, ?)";

    try testing.expectError(error.ParamCountMismatch, d.exec(insert, &.{.{ .string = "alice" }}));
    try testing.expectError(
        error.ParamCountMismatch,
        d.exec(insert, &.{ .{ .string = "alice" }, .{ .int = 1 }, .{ .int = 2 } }),
    );
    try testing.expectError(
        error.ParamCountMismatch,
        d.query("SELECT id FROM zent_my_params WHERE name = ? AND score = ?", &.{.{ .string = "alice" }}),
    );

    // Neither rejected statement wrote anything, and the list that fits still
    // works.
    {
        var rows = try d.query("SELECT COUNT(*) FROM zent_my_params", &.{});
        defer rows.deinit();
        try testing.expectEqual(@as(i64, 0), rows.next().?.getInt(0).?);
    }
    const ok = try d.exec(insert, &.{ .{ .string = "alice" }, .{ .int = 1 } });
    try testing.expectEqual(@as(usize, 1), ok.rows_affected);
}

// ---------------------------------------------------------------------------
// TLS / mTLS
//
// These tests need a server whose SSL is enabled and a CA PEM on disk, taken
// from the environment (see sslEnv). Every one of them skips when MYSQL_SSL_CA
// is unset or unreadable, so TLS-less environments (CI containers) stay green.
// ---------------------------------------------------------------------------

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return false;
    return true;
}

const SslEnv = struct {
    ca: [:0]const u8,
    cert: ?[:0]const u8,
    key: ?[:0]const u8,
};

fn sslEnv() !SslEnv {
    const ca = std.process.Environ.getPosix(std.testing.environ, "MYSQL_SSL_CA") orelse return error.SkipZigTest;
    if (!pathExists(ca)) return error.SkipZigTest;
    const cert = std.process.Environ.getPosix(std.testing.environ, "MYSQL_SSL_CERT");
    const key = std.process.Environ.getPosix(std.testing.environ, "MYSQL_SSL_KEY");
    if (cert) |p| if (!pathExists(p)) return error.SkipZigTest;
    if (key) |p| if (!pathExists(p)) return error.SkipZigTest;
    return .{ .ca = ca, .cert = cert, .key = key };
}

/// A self-signed CA that did not issue the test server's certificate. Used as
/// a deliberately wrong trust anchor; kept inline so the negative test needs
/// nothing but MYSQL_SSL_CA.
const wrong_ca_pem =
    \\-----BEGIN CERTIFICATE-----
    \\MIIDGzCCAgOgAwIBAgIUV0rVu7QiQnWdTLQuFfiBf6koMd0wDQYJKoZIhvcNAQEL
    \\BQAwHTEbMBkGA1UEAwwSemVudC10ZXN0LXdyb25nLWNhMB4XDTI2MDkxMTEzNTkw
    \\M1oXDTM2MDkwODEzNTkwM1owHTEbMBkGA1UEAwwSemVudC10ZXN0LXdyb25nLWNh
    \\MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA1d29PJP3y2AwUEscDYkp
    \\gUrYfVWwoPJCzKqu7BBi9jnQmWUSL0Ubq50P9USAntoP8JHxk3bWoY1Azdkbm9N6
    \\JH/p/GcFdH6Ph3OA8Iz6HPasKN6/Q5PmWs2H97+NDFPIeqo4/51H7A8H5bIrzIRP
    \\F3EAYNGe4c1MiUkigewU1O1x9X0vsDYOad8G3KJ/Tn4ZoXK7NAC263dUI14MhfHH
    \\FeHDJ9kNiDZlXz/JIGYOUda3yrrFtFfXOL6OPjoZikfWguXeBFYXMWOswiou1zLN
    \\Ezd8NS5LAU75DjF1q8CMHvE+2b0j6KQKTU7pCtCd+KrMnqKaV4iGJI5ywVUs8oqt
    \\JQIDAQABo1MwUTAdBgNVHQ4EFgQUnShwnCfO1sB47tqqJi2zTMS6QPcwHwYDVR0j
    \\BBgwFoAUnShwnCfO1sB47tqqJi2zTMS6QPcwDwYDVR0TAQH/BAUwAwEB/zANBgkq
    \\hkiG9w0BAQsFAAOCAQEAkiCWoPzYOj7u4fxdbY6mcKy/v3MefvvJBYFCNe2cJPCA
    \\hd4V4Hh7/+z3+eUTZMwzx3/kq6W6j5x+tRkU+GbovMleM7qbWCBjexXlX9TdLDNO
    \\tQCeD19VCF1eRspSqVjOlolZFNNSXFp8HGrho6nEIha2/Kg3W/XeZs/Hma0vrWoK
    \\Cxu5+Po1NDJbABsaEtwWq+3XZjSGEMlVE9DzIKtjdjRDAnMcm93sJ2dv5DiOiko8
    \\2H6N6sq512XlU77pG8e/BTS5sDY2NC7zLVpKu6leEy8lQjo11cWnM+UK89sJp7py
    \\SO4T0DO3GTRAMs7C80/UIFvSoJ4BY6EzNIq4co0J4A==
    \\-----END CERTIFICATE-----
;

test "MySQL: required SSL mode negotiates an encrypted session" {
    const allocator = testing.allocator;
    const ssl = try sslEnv();

    var drv = connectSsl(allocator, .{ .mode = .required, .ca = ssl.ca }) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // A plaintext session reports an empty Ssl_cipher; a non-empty value can
    // only come from a completed TLS handshake.
    var rows = try drv.query("SHOW SESSION STATUS LIKE 'Ssl_cipher'", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    const cipher = row.getText(1) orelse return error.NoRow;
    try testing.expect(cipher.len > 0);
}

test "MySQL: verify_ca accepts the configured CA and rejects a foreign one" {
    const allocator = testing.allocator;
    const ssl = try sslEnv();

    // The server's real CA must validate the server certificate.
    {
        var drv = connectSsl(allocator, .{ .mode = .verify_ca, .ca = ssl.ca }) catch |err| return skipIfNoServer(err);
        drv.close();
    }

    // An unrelated self-signed CA must make the connect fail. This is what
    // proves `ca` actually reaches mysql_ssl_set and is used for
    // verification: drop it (or skip verification) and this connect succeeds.
    const wrong_ca = "zent_test_wrong_ca.pem";
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(testing.io, .{ .sub_path = wrong_ca, .data = wrong_ca_pem });
    defer cwd.deleteFile(testing.io, wrong_ca) catch {};

    const res = connectSsl(allocator, .{ .mode = .verify_ca, .ca = wrong_ca });
    try testing.expectError(error.MySQLConnectFailed, res);
}

test "MySQL: client certificate satisfies REQUIRE X509 and its absence is rejected" {
    const allocator = testing.allocator;
    const ssl = try sslEnv();
    const cert = ssl.cert orelse return error.SkipZigTest;
    const key = ssl.key orelse return error.SkipZigTest;

    var admin = connect(allocator) catch |err| return skipIfNoServer(err);
    defer admin.close();

    // 'localhost' covers both the socket and the TCP path this test uses.
    // REQUIRE X509 makes the server refuse any client without a certificate.
    _ = try admin.exec("DROP USER IF EXISTS 'zent_mtls'@'localhost'", &.{});
    defer _ = admin.exec("DROP USER IF EXISTS 'zent_mtls'@'localhost'", &.{}) catch {};
    _ = try admin.exec("CREATE USER 'zent_mtls'@'localhost' REQUIRE X509", &.{});
    _ = try admin.exec("GRANT SELECT ON *.* TO 'zent_mtls'@'localhost'", &.{});

    const d = try dsn();

    // Presenting cert + key satisfies the server's certificate requirement.
    {
        var with_cert = MySQLDriver.connectOptsSsl(allocator, d.host, d.port, "zent_mtls", "", d.db, .{
            .mode = .required,
            .ca = ssl.ca,
            .cert = cert,
            .key = key,
        }) catch |err| return err;
        defer with_cert.close();
        try with_cert.ping();
    }

    // Without a client certificate the same credentials must be refused.
    const res = MySQLDriver.connectOptsSsl(allocator, d.host, d.port, "zent_mtls", "", d.db, .{
        .mode = .required,
        .ca = ssl.ca,
    });
    try testing.expectError(error.MySQLConnectFailed, res);
}

test "MySQL: StorageKey maps field names to distinct column names" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    _ = drv.exec("DROP TABLE IF EXISTS my_storage_account", &.{}) catch {};
    defer _ = drv.exec("DROP TABLE IF EXISTS my_storage_account", &.{}) catch {};

    const MyStorageAccount = schema("MyStorageAccount", .{
        .table_name = "my_storage_account",
        .fields = &.{
            field.String("userName").StorageKey("user_name"),
            field.String("emailAddr").StorageKey("email_address"),
            field.Int("loginCount").StorageKey("login_count"),
        },
        .mixins = &.{zent.core.mixin.SoftDeleteMixin},
        .soft_delete = true,
        .indexes = &.{index.Fields(&.{"loginCount"})},
    });
    const graph = comptime buildGraph(&.{MyStorageAccount});
    const infos = graph.types;
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
    var client = Client.makeClient(infos, allocator, drv.asDriver());
    const preds = client.my_storage_account.predicates;

    // DDL created the physical columns, not the Zig field names.
    {
        var rows = try drv.query("SELECT user_name, email_address, login_count FROM my_storage_account", &.{});
        rows.deinit();
    }
    // The index definition references the mapped column.
    {
        var rows = try drv.query(
            "SELECT COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'my_storage_account'",
            &.{},
        );
        defer rows.deinit();
        var found_mapped = false;
        while (rows.next()) |row| {
            const col = row.getText(0) orelse continue;
            if (std.mem.eql(u8, col, "login_count")) found_mapped = true;
            try testing.expect(!std.mem.eql(u8, col, "loginCount"));
        }
        try testing.expect(found_mapped);
    }

    var b1 = try client.my_storage_account.Create();
    defer b1.deinit();
    _ = try b1.setFieldValue("userName", "alice");
    _ = try b1.setFieldValue("emailAddr", "alice@example.com");
    _ = try b1.setFieldValue("loginCount", @as(i64, 3));
    var a1 = try b1.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &a1, allocator);

    var b2 = try client.my_storage_account.Create();
    defer b2.deinit();
    _ = try b2.setFieldValue("userName", "bob");
    _ = try b2.setFieldValue("emailAddr", "bob@example.com");
    _ = try b2.setFieldValue("loginCount", @as(i64, 7));
    var a2 = try b2.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &a2, allocator);

    {
        var rows = try drv.query(
            "SELECT user_name, email_address, login_count FROM my_storage_account WHERE user_name = ?",
            &.{.{ .string = "alice" }},
        );
        defer rows.deinit();
        const row = rows.next() orelse return error.NoRow;
        try testing.expectEqualStrings("alice", row.getText(0).?);
        try testing.expectEqualStrings("alice@example.com", row.getText(1).?);
        try testing.expectEqual(@as(i64, 3), row.getInt(2).?);
    }

    {
        var q = client.my_storage_account.Query();
        defer q.deinit();
        _ = try q.Where(.{preds.idEQ(.{ .int = a1.id })});
        var found = try q.All();
        defer {
            for (found.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            found.deinit();
        }
        try testing.expectEqual(@as(usize, 1), found.items.len);
        try testing.expectEqualStrings("alice", found.items[0].userName);
        try testing.expectEqual(@as(i64, 3), found.items[0].loginCount);
    }

    {
        var q = client.my_storage_account.Query();
        defer q.deinit();
        _ = try q.Where(.{preds.emailAddrEQ(.{ .string = "bob@example.com" })});
        var found = try q.All();
        defer {
            for (found.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            found.deinit();
        }
        try testing.expectEqual(@as(usize, 1), found.items.len);
        try testing.expectEqualStrings("bob", found.items[0].userName);
    }

    {
        var q = client.my_storage_account.Query();
        defer q.deinit();
        _ = try q.OrderBy(&.{zent.sql.OrderAsc("userName")});
        var found = try q.All();
        defer {
            for (found.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            found.deinit();
        }
        try testing.expectEqual(@as(usize, 2), found.items.len);
        try testing.expectEqualStrings("alice", found.items[0].userName);
        try testing.expectEqualStrings("bob", found.items[1].userName);
    }

    {
        var q = client.my_storage_account.Query();
        defer q.deinit();
        _ = q.Select(&.{"userName"});
        _ = try q.Where(.{preds.userNameEQ(.{ .string = "alice" })});
        var found = try q.All();
        defer {
            for (found.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            found.deinit();
        }
        try testing.expectEqual(@as(usize, 1), found.items.len);
        try testing.expectEqualStrings("alice", found.items[0].userName);
    }

    {
        var u = client.my_storage_account.Update();
        defer u.deinit();
        _ = try u.setFieldValue("emailAddr", "alice2@example.com");
        _ = try u.Where(.{preds.userNameEQ(.{ .string = "alice" })});
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }
    {
        var q = client.my_storage_account.Query();
        defer q.deinit();
        _ = try q.Where(.{preds.emailAddrEQ(.{ .string = "alice2@example.com" })});
        var found = try q.All();
        defer {
            for (found.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            found.deinit();
        }
        try testing.expectEqual(@as(usize, 1), found.items.len);
    }

    {
        var d = client.my_storage_account.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.userNameEQ(.{ .string = "bob" })});
        try testing.expectEqual(@as(usize, 1), try d.Exec());
    }
    {
        var q = client.my_storage_account.Query();
        defer q.deinit();
        var found = try q.All();
        defer {
            for (found.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            found.deinit();
        }
        try testing.expectEqual(@as(usize, 1), found.items.len);
        try testing.expectEqualStrings("alice", found.items[0].userName);
    }

    {
        var d = client.my_storage_account.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.userNameEQ(.{ .string = "alice" })});
        try testing.expectEqual(@as(usize, 1), try d.ForceExec());
    }
}

test "MySQL: queryTargetsByValue traverses UUID-keyed parents" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // `field.UUID` maps to TEXT, which MySQL rejects as a PRIMARY KEY without
    // a key length, so the tables use CHAR(36) DDL; the FK column is the one
    // the IN comparison probes with a textual parameter.
    const ItemBase = schema("MyUqvItem", .{
        .fields = &.{ field.String("model"), field.UUID("my_uqv_user_id") },
    });
    const UserBase = schema("MyUqvUser", .{
        .fields = &.{ field.UUID("id"), field.String("name") },
        .edges = &.{edge.To("items", ItemBase).Field("my_uqv_user_id")},
    });
    const infos = comptime buildGraph(&.{ UserBase, ItemBase }).types;
    const user_info = infos[0];
    const item_info = infos[1];

    _ = try drv.exec("DROP TABLE IF EXISTS my_uqv_item", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS my_uqv_user", &.{});
    defer {
        _ = drv.exec("DROP TABLE IF EXISTS my_uqv_item", &.{}) catch {};
        _ = drv.exec("DROP TABLE IF EXISTS my_uqv_user", &.{}) catch {};
    }
    _ = try drv.exec("CREATE TABLE my_uqv_user (id CHAR(36) PRIMARY KEY, name VARCHAR(255) NOT NULL)", &.{});
    _ = try drv.exec("CREATE TABLE my_uqv_item (id BIGINT PRIMARY KEY AUTO_INCREMENT, model VARCHAR(255) NOT NULL, my_uqv_user_id CHAR(36) NOT NULL)", &.{});

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    const alice_id = "01920000-0000-7000-8000-000000000001";
    const bob_id = "01920000-0000-7000-8000-000000000002";
    const users = [_][]const u8{ alice_id, bob_id };
    for (users, 0..) |uid, i| {
        var b = try client.my_uqv_user.Create();
        defer b.deinit();
        _ = try b.setFieldValue("id", uid);
        _ = try b.setFieldValue("name", if (i == 0) "alice" else "bob");
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, user_info, &e, allocator);
    }

    const items = [_][2][]const u8{
        .{ alice_id, "a1" },
        .{ alice_id, "a2" },
        .{ bob_id, "b1" },
    };
    for (items) |item| {
        var b = try client.my_uqv_item.Create();
        defer b.deinit();
        _ = try b.setFieldValue("my_uqv_user_id", item[0]);
        _ = try b.setFieldValue("model", item[1]);
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, item_info, &e, allocator);
    }

    {
        var rows = try Client.queryTargetsByValueUnscoped(infos, "MyUqvUser", "items", &.{.{ .string = alice_id }}, allocator, drv.asDriver());
        defer {
            for (rows.items) |*r| zent.codegen.deinitEntity(infos, item_info, r, allocator);
            rows.deinit();
        }
        try testing.expectEqual(@as(usize, 2), rows.items.len);
    }
    {
        var rows = try Client.queryTargetsByValueUnscoped(infos, "MyUqvUser", "items", &.{
            .{ .string = alice_id },
            .{ .string = bob_id },
        }, allocator, drv.asDriver());
        defer {
            for (rows.items) |*r| zent.codegen.deinitEntity(infos, item_info, r, allocator);
            rows.deinit();
        }
        try testing.expectEqual(@as(usize, 3), rows.items.len);
    }
}

test "MySQL: createAllTables keeps a UUID primary key typed as UUID" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // DDL comes from the library rather than raw SQL: the auto-increment
    // rewrite used to mark every id column as auto-increment, which turned a
    // UUID primary key into SERIAL on PostgreSQL and into an unindexable TEXT
    // key on MySQL. This asserts the generated type, then round-trips a row
    // through the generated client to prove the column is usable.
    const DocBase = schema("MyUuidDoc", .{
        .fields = &.{ field.UUID("id"), field.String("title") },
    });
    const infos = comptime buildGraph(&.{DocBase}).types;
    const doc_info = infos[0];

    _ = try drv.exec("DROP TABLE IF EXISTS my_uuid_doc", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS my_uuid_doc", &.{}) catch {};

    try Client.createAllTables(allocator, infos, drv.asDriver());

    {
        var rows = try drv.query(
            "SELECT column_type FROM information_schema.columns " ++
                "WHERE table_name = 'my_uuid_doc' AND column_name = 'id'",
            &.{},
        );
        defer rows.deinit();
        const row = rows.next() orelse return error.NoRow;
        // TEXT cannot be indexed without a key length on MySQL (errno 1170),
        // so a UUID key must come out as a fixed-width character column.
        try testing.expectEqualStrings("char(36)", row.getText(0).?);
    }

    var client = Client.makeClient(infos, allocator, drv.asDriver());
    var b = try client.my_uuid_doc.Create();
    defer b.deinit();
    _ = try b.setFieldValue("id", "01920000-0000-7000-8000-0000000000f2");
    _ = try b.setFieldValue("title", "t");
    var saved = try b.Save();
    defer zent.codegen.deinitEntity(infos, doc_info, &saved, allocator);
    try testing.expectEqualStrings("01920000-0000-7000-8000-0000000000f2", saved.id);
}

test "MySQL: unique/defaulted/indexed String columns build a usable table" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // Every MySQL BLOB/TEXT restriction lands on this schema at once: a TEXT
    // column cannot be UNIQUE without a key length (errno 1170), cannot carry
    // a DEFAULT (errno 1101), and cannot be indexed without a key length
    // (errno 1170 again). `field.String` maps to VARCHAR(255) on MySQL, so
    // createAllTables must now succeed with the declarations as written.
    const StrAccountBase = schema("MyStrAccount", .{
        .fields = &.{
            field.String("email").Unique(),
            field.String("status").Default("new"),
        },
        .indexes = &.{
            index.Named("idx_my_str_account_status", &.{"status"}),
        },
    });
    const infos = comptime buildGraph(&.{StrAccountBase}).types;

    _ = try drv.exec("DROP TABLE IF EXISTS my_str_account", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS my_str_account", &.{}) catch {};

    try Client.createAllTables(allocator, infos, drv.asDriver());

    for ([_][]const u8{ "email", "status" }) |column| {
        var rows = try drv.query(
            "SELECT column_type FROM information_schema.columns " ++
                "WHERE table_name = 'my_str_account' AND table_schema = DATABASE() AND column_name = ?",
            &.{.{ .string = column }},
        );
        defer rows.deinit();
        const row = rows.next() orelse return error.NoRow;
        // VARCHAR, not TEXT: that is what made UNIQUE and DEFAULT legal.
        try testing.expectEqualStrings("varchar(255)", row.getText(0).?);
    }

    // The declared index exists and covers the whole column (no key length).
    {
        var rows = try drv.query(
            "SELECT sub_part FROM information_schema.statistics " ++
                "WHERE table_name = 'my_str_account' AND table_schema = DATABASE() " ++
                "AND index_name = 'idx_my_str_account_status'",
            &.{},
        );
        defer rows.deinit();
        const row = rows.next() orelse return error.NoRow;
        try testing.expect(row.getText(0) == null);
    }

    var client = Client.makeClient(infos, allocator, drv.asDriver());
    {
        var b = try client.my_str_account.Create();
        defer b.deinit();
        _ = try b.setFieldValue("email", "a@b.com");
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &e, allocator);
    }
    {
        // `status` was never set, so the server-side DEFAULT supplied it —
        // the row is also proof the UNIQUE key is enforceable on this column.
        var rows = try drv.query(
            "SELECT COUNT(*) FROM my_str_account WHERE email = ? AND status = ?",
            &.{ .{ .string = "a@b.com" }, .{ .string = "new" } },
        );
        defer rows.deinit();
        const row = rows.next() orelse return error.NoRow;
        try testing.expectEqual(@as(i64, 1), row.getInt(0).?);
    }
}

test "MySQL: checkSchema reports a UNIQUE column and a foreign key the database lacks" {
    // Portable on both servers: plain column-level UNIQUE, a plain
    // `ADD CONSTRAINT … FOREIGN KEY`, and standard `information_schema` — no
    // functional index, no MySQL-only syntax, no server-behaviour assertion.
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const MyDriftOwner = schema("MyDriftOwner", .{ .fields = &.{field.String("name")} });

    _ = try drv.exec("DROP TABLE IF EXISTS my_drift_car", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS my_drift_owner", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS my_drift_owner", &.{}) catch {};
    defer _ = drv.exec("DROP TABLE IF EXISTS my_drift_car", &.{}) catch {};

    // The table as it was built: no UNIQUE on `vin`, and no edge yet.
    const MyDriftCarBefore = schema("MyDriftCar", .{
        .fields = &.{ field.String("model"), field.String("vin") },
    });
    const before_graph = comptime buildGraph(&.{ MyDriftOwner, MyDriftCarBefore });
    try migrate.migrateSchema(allocator, drv.asDriver(), before_graph.types);

    // The schema as it is now: `vin` declared UNIQUE, the edge declared.
    const MyDriftCarAfter = schema("MyDriftCar", .{
        .fields = &.{ field.String("model"), field.String("vin").Unique() },
        .edges = &.{edge.From("owner", MyDriftOwner)},
    });
    const after_graph = comptime buildGraph(&.{ MyDriftOwner, MyDriftCarAfter });
    const infos = after_graph.types;

    // The edge's column exists (added out of band, matching type and
    // nullability), the constraint does not.
    _ = try drv.exec("ALTER TABLE my_drift_car ADD COLUMN owner_id INTEGER", &.{});

    {
        const drifts = try migrate.checkSchema(allocator, drv.asDriver(), infos);
        defer migrate.freeSchemaDrift(allocator, drifts);

        var unique_drift: ?migrate.SchemaDrift = null;
        var fk_drift: ?migrate.SchemaDrift = null;
        for (drifts) |d| {
            try testing.expectEqualStrings("my_drift_car", d.table);
            if (d.kind == .unique_constraint) unique_drift = d;
            if (d.kind == .missing_foreign_key) fk_drift = d;
        }
        try testing.expectEqual(@as(usize, 2), drifts.len);
        try testing.expect(unique_drift != null);
        try testing.expectEqualStrings("vin", unique_drift.?.column);
        try testing.expect(fk_drift != null);
        try testing.expectEqualStrings("owner_id", fk_drift.?.column);
        try testing.expectEqualStrings(
            "schema declares FOREIGN KEY (owner_id) REFERENCES my_drift_owner (id), database has none",
            fk_drift.?.index_detail,
        );
        try testing.expect(!unique_drift.?.breaksReads());
        try testing.expect(!fk_drift.?.breaksReads());
        try migrate.assertSchema(allocator, drv.asDriver(), infos, .read_breaking_only);
        try testing.expectError(error.SchemaDrift, migrate.assertSchema(allocator, drv.asDriver(), infos, .any));
    }

    // Both constraints in the shapes the schema declares: silence, whatever the
    // server called them (`idx_…` for the index, `my_drift_car_ibfk_1` for the
    // foreign key — the comparison is by shape on both sides).
    _ = try drv.exec("CREATE UNIQUE INDEX idx_my_drift_car_vin ON my_drift_car (vin)", &.{});
    _ = try drv.exec(
        "ALTER TABLE my_drift_car ADD CONSTRAINT my_drift_car_owner_fk FOREIGN KEY (owner_id) REFERENCES my_drift_owner (id)",
        &.{},
    );

    const agreeing = try migrate.checkSchema(allocator, drv.asDriver(), infos);
    defer migrate.freeSchemaDrift(allocator, agreeing);
    try testing.expectEqual(@as(usize, 0), agreeing.len);

    // `getExistingForeignKeys` read that constraint back. MySQL auto-created an
    // index for it too; that index is not unique and does not affect the
    // column check above.
    var keys = try migrate.getExistingForeignKeys(allocator, drv.asDriver(), "my_drift_car");
    defer migrate.freeExistingForeignKeys(allocator, &keys);
    try testing.expectEqual(@as(usize, 1), keys.items.len);
    try testing.expectEqualStrings("owner_id", keys.items[0].columns[0]);
    try testing.expectEqualStrings("my_drift_owner", keys.items[0].ref_table);
    try testing.expect(keys.items[0].ref_columns_comparable);
    try testing.expectEqualStrings("id", keys.items[0].ref_columns[0]);

    var absent = try migrate.getExistingForeignKeys(allocator, drv.asDriver(), "my_drift_absent");
    defer migrate.freeExistingForeignKeys(allocator, &absent);
    try testing.expectEqual(@as(usize, 0), absent.items.len);
}

test "MySQL: checkSchema reports a view the database does not have, and getExistingViews reads one it does" {
    // Views were the one declared shape `checkSchema` never looked at. The
    // failure that let through: the view is declared, `migrateSchema` records
    // `create_view`, the view is later dropped out of band — and nothing
    // re-checked it, so `SELECT … FROM the view` errored while `assertSchema`
    // stayed green.
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // Leftovers from an interrupted run. The view is dropped first: a table
    // cannot be dropped while a view still selects from it.
    _ = try drv.exec("DROP VIEW IF EXISTS zent_vw_my_probe", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS zent_vw_my_base", &.{});
    defer _ = drv.exec("DROP VIEW IF EXISTS zent_vw_my_probe", &.{}) catch {};
    defer _ = drv.exec("DROP TABLE IF EXISTS zent_vw_my_base", &.{}) catch {};

    const ZentVwMyBase = schema("ZentVwMyBase", .{ .fields = &.{field.String("name")} });
    const ZentVwMyProbe = schema("ZentVwMyProbe", .{
        .view = true,
        .view_sql = "SELECT id, name FROM zent_vw_my_base",
        .fields = &.{field.String("name")},
    });
    const graph = comptime buildGraph(&.{ ZentVwMyBase, ZentVwMyProbe });
    const infos = graph.types;

    try migrate.migrateSchema(allocator, drv.asDriver(), infos);

    // The view `migrateSchema` built (`CREATE VIEW IF NOT EXISTS`) is a
    // relation `checkSchema` can see, on both gates.
    {
        const agreeing = try migrate.checkSchema(allocator, drv.asDriver(), infos);
        defer migrate.freeSchemaDrift(allocator, agreeing);
        try testing.expectEqual(@as(usize, 0), agreeing.len);
        try migrate.assertSchema(allocator, drv.asDriver(), infos, .any);

        var views = try migrate.getExistingViews(allocator, drv.asDriver(), "zent_vw_my_probe");
        defer migrate.freeExistingViews(allocator, &views);
        try testing.expectEqual(@as(usize, 1), views.items.len);
        try testing.expectEqualStrings("zent_vw_my_probe", views.items[0].name);
        // `information_schema.views.view_definition` is a **normalized** SELECT
        // on both servers this file runs against — backticked identifiers, `AS`
        // aliases, and MariaDB strips the newlines MySQL keeps — so it is never
        // the text the schema wrote. Only that inequality is asserted: the
        // *text* differs between MySQL and MariaDB, and nothing here depends on
        // its shape, which is exactly why no comparison uses it.
        try testing.expect(views.items[0].definition.len > 0);
        try testing.expect(!std.mem.eql(u8, views.items[0].definition, ZentVwMyProbe.view_sql.?));
        try testing.expect(std.mem.indexOf(u8, views.items[0].definition, "zent_vw_my_base") != null);

        // A table of that name is not a view; a name that is not there is an
        // empty answer, not an error.
        var base_is_not_a_view = try migrate.getExistingViews(allocator, drv.asDriver(), "zent_vw_my_base");
        defer migrate.freeExistingViews(allocator, &base_is_not_a_view);
        try testing.expectEqual(@as(usize, 0), base_is_not_a_view.items.len);

        var absent = try migrate.getExistingViews(allocator, drv.asDriver(), "zent_vw_my_absent");
        defer migrate.freeExistingViews(allocator, &absent);
        try testing.expectEqual(@as(usize, 0), absent.items.len);
    }

    // Dropped out of band: reported, and the read-breaking gate fails on it.
    _ = try drv.exec("DROP VIEW zent_vw_my_probe", &.{});
    {
        const drifts = try migrate.checkSchema(allocator, drv.asDriver(), infos);
        defer migrate.freeSchemaDrift(allocator, drifts);
        try testing.expectEqual(@as(usize, 1), drifts.len);
        try testing.expectEqual(migrate.SchemaDrift.Kind.missing_view, drifts[0].kind);
        try testing.expectEqualStrings("zent_vw_my_probe", drifts[0].table);
        try testing.expect(drifts[0].breaksReads());
        // The read really does fail; that is the stake behind `breaksReads`.
        // The error name is the driver's business, so only the failure itself
        // is asserted here.
        if (drv.query("SELECT id, name FROM zent_vw_my_probe", &.{})) |rows| {
            var r = rows;
            r.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
        try testing.expectError(error.SchemaDrift, migrate.assertSchema(allocator, drv.asDriver(), infos, .read_breaking_only));
        try testing.expectError(error.SchemaDrift, migrate.assertSchema(allocator, drv.asDriver(), infos, .any));
    }

    // `migrateSchema` heals it: the recorded `create_view` version is present
    // but the relation is gone, so the view is re-created — the same
    // out-of-band-drop path it has for tables.
    try migrate.migrateSchema(allocator, drv.asDriver(), infos);
    const healed = try migrate.checkSchema(allocator, drv.asDriver(), infos);
    defer migrate.freeSchemaDrift(allocator, healed);
    try testing.expectEqual(@as(usize, 0), healed.len);
}

// ------------------------------------------------------------------
// M2M junction tables
// ------------------------------------------------------------------

test "MySQL: checkSchema reports a missing M2M junction table" {
    // An M2M edge is joined through a junction table that is not an entity, so
    // the loop `checkSchema` walks — `infos` — never looked at it. The failure
    // that let through: the edge is declared, `migrateSchema` records
    // `create_junction`, the table is later dropped out of band — and nothing
    // re-checked it, so a query over the edge errored while `assertSchema`
    // stayed green.
    //
    // Nothing here depends on which server this file runs against (MySQL 8/9
    // locally, MariaDB 10.11 in CI): the assertions are `information_schema`
    // existence, the reported drift and a failing `SELECT` over the dropped
    // table, none of which differ between the two — and the only server-specific
    // value in reach, the driver's error name for that `SELECT`, is deliberately
    // not asserted (see the loose `if (…) |rows| … else |_| {}` below).
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // Leftovers from an interrupted run. The junction table goes first: it
    // holds foreign keys to both entity tables.
    _ = try drv.exec("DROP TABLE IF EXISTS zent_jc_my_member_zent_jc_my_tag", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS zent_jc_my_member", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS zent_jc_my_tag", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS zent_jc_my_member_zent_jc_my_tag", &.{}) catch {};
    defer _ = drv.exec("DROP TABLE IF EXISTS zent_jc_my_member", &.{}) catch {};
    defer _ = drv.exec("DROP TABLE IF EXISTS zent_jc_my_tag", &.{}) catch {};

    const ZentJcMyMemberBase = schema("ZentJcMyMember", .{ .fields = &.{field.String("name")} });
    const ZentJcMyTagBase = schema("ZentJcMyTag", .{ .fields = &.{field.String("label")} });
    // Both sides declare the edge, which is what makes it M2M — and what makes
    // an absent junction table a single report rather than two.
    const ZentJcMyMember = struct {
        pub const schema_name = ZentJcMyMemberBase.schema_name;
        pub const fields = ZentJcMyMemberBase.fields;
        pub const edges = &.{edge.To("tags", ZentJcMyTagBase)};
        pub const indexes = ZentJcMyMemberBase.indexes;
    };
    const ZentJcMyTag = struct {
        pub const schema_name = ZentJcMyTagBase.schema_name;
        pub const fields = ZentJcMyTagBase.fields;
        pub const edges = &.{edge.To("members", ZentJcMyMemberBase)};
        pub const indexes = ZentJcMyTagBase.indexes;
    };
    const graph = comptime buildGraph(&.{ ZentJcMyMember, ZentJcMyTag });
    const infos = graph.types;

    try migrate.migrateSchema(allocator, drv.asDriver(), infos);

    // The junction table `migrateSchema` built is there, and its own primary
    // key and foreign keys produce no other drift: agreement on both gates.
    {
        const agreeing = try migrate.checkSchema(allocator, drv.asDriver(), infos);
        defer migrate.freeSchemaDrift(allocator, agreeing);
        try testing.expectEqual(@as(usize, 0), agreeing.len);
        try migrate.assertSchema(allocator, drv.asDriver(), infos, .any);
    }

    // Dropped out of band: reported, and the read-breaking gate fails on it.
    _ = try drv.exec("DROP TABLE zent_jc_my_member_zent_jc_my_tag", &.{});
    {
        const drifts = try migrate.checkSchema(allocator, drv.asDriver(), infos);
        defer migrate.freeSchemaDrift(allocator, drifts);
        try testing.expectEqual(@as(usize, 1), drifts.len);
        try testing.expectEqual(migrate.SchemaDrift.Kind.missing_junction_table, drifts[0].kind);
        try testing.expectEqualStrings("zent_jc_my_member_zent_jc_my_tag", drifts[0].table);
        try testing.expectEqualStrings("", drifts[0].column);
        try testing.expect(std.mem.indexOf(u8, drifts[0].index_detail, "zent_jc_my_member <-> zent_jc_my_tag") != null);
        try testing.expect(std.mem.indexOf(u8, drifts[0].index_detail, "database has no relation named zent_jc_my_member_zent_jc_my_tag") != null);
        try testing.expect(drifts[0].breaksReads());
        // The relation query really does fail; that is the stake behind
        // `breaksReads`. The error name is the driver's business, so only the
        // failure itself is asserted here.
        if (drv.query("SELECT zent_jc_my_member_id, zent_jc_my_tag_id FROM zent_jc_my_member_zent_jc_my_tag", &.{})) |rows| {
            var r = rows;
            r.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
        try testing.expectError(error.SchemaDrift, migrate.assertSchema(allocator, drv.asDriver(), infos, .read_breaking_only));
        try testing.expectError(error.SchemaDrift, migrate.assertSchema(allocator, drv.asDriver(), infos, .any));
    }

    // `migrateSchema` heals it: the recorded `create_junction` version is
    // present but the relation is gone, so the junction table is re-created.
    try migrate.migrateSchema(allocator, drv.asDriver(), infos);
    const healed = try migrate.checkSchema(allocator, drv.asDriver(), infos);
    defer migrate.freeSchemaDrift(allocator, healed);
    try testing.expectEqual(@as(usize, 0), healed.len);
}

test "MySQL: getExistingIndexes reads the key columns in order" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    _ = try drv.exec("DROP TABLE IF EXISTS zent_idx_probe", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS zent_idx_probe", &.{}) catch {};
    _ = try drv.exec(
        "CREATE TABLE zent_idx_probe (id BIGINT PRIMARY KEY, a VARCHAR(255) NOT NULL, b VARCHAR(255), c VARCHAR(255))",
        &.{},
    );
    _ = try drv.exec("CREATE UNIQUE INDEX idx_zent_inspect_ab ON zent_idx_probe (a, b)", &.{});
    _ = try drv.exec("CREATE INDEX idx_zent_inspect_b ON zent_idx_probe (b)", &.{});
    // A prefix index does not constrain the whole column, so its key list must
    // come back as not comparable. It is also the only not-comparable case
    // creatable on both servers, which is why it carries the portable assertion.
    _ = try drv.exec("CREATE INDEX idx_zent_inspect_pre ON zent_idx_probe (c(10))", &.{});

    // A functional index has no `column_name` in information_schema.statistics.
    // MySQL 8.0.13+ only: MariaDB has no functional indexes and rejects the
    // syntax outright (errno 1064), so it is created on MySQL alone.
    const maria = try isMariaDB(&drv);
    if (!maria) {
        _ = try drv.exec("CREATE INDEX idx_zent_inspect_fn ON zent_idx_probe ((lower(c)))", &.{});
    }

    var indexes = try migrate.getExistingIndexes(allocator, drv.asDriver(), "zent_idx_probe");
    defer migrate.freeExistingIndexes(allocator, &indexes);

    var composite: ?migrate.ExistingIndex = null;
    var single: ?migrate.ExistingIndex = null;
    var prefixed: ?migrate.ExistingIndex = null;
    var functional: ?migrate.ExistingIndex = null;
    for (indexes.items) |i| {
        if (std.mem.eql(u8, i.name, "idx_zent_inspect_ab")) composite = i;
        if (std.mem.eql(u8, i.name, "idx_zent_inspect_b")) single = i;
        if (std.mem.eql(u8, i.name, "idx_zent_inspect_pre")) prefixed = i;
        if (std.mem.eql(u8, i.name, "idx_zent_inspect_fn")) functional = i;
    }

    try testing.expect(composite != null);
    try testing.expect(composite.?.unique);
    try testing.expect(composite.?.columns_comparable);
    try testing.expectEqual(@as(usize, 2), composite.?.columns.len);
    try testing.expectEqualStrings("a", composite.?.columns[0]);
    try testing.expectEqualStrings("b", composite.?.columns[1]);

    try testing.expect(single != null);
    try testing.expect(!single.?.unique);
    try testing.expect(single.?.columns_comparable);
    try testing.expectEqualStrings("b", single.?.columns[0]);

    // Prefix index: the column names would read as a match for a schema index
    // over `c`, so `columns_comparable` is the only thing standing between this
    // and a false "the index is fine".
    try testing.expect(prefixed != null);
    try testing.expectEqualStrings("c", prefixed.?.columns[0]);
    try testing.expect(!prefixed.?.columns_comparable);

    if (!maria) {
        try testing.expect(functional != null);
        try testing.expect(!functional.?.columns_comparable);
    }
}

// ------------------------------------------------------------------
// checkStatement: prepare-and-discard validation of a raw statement
// ------------------------------------------------------------------

test "MySQL: checkStatement accepts a valid statement and its parameter list" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    _ = try drv.exec("DROP TABLE IF EXISTS zent_chk_my", &.{});
    _ = try drv.exec("CREATE TABLE zent_chk_my (id INT PRIMARY KEY, name VARCHAR(64))", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS zent_chk_my", &.{}) catch {};

    var d = try sql_statement.checkStatement(
        allocator,
        drv.asDriver(),
        "SELECT name FROM zent_chk_my WHERE id = ?",
        &.{.{ .int = 1 }},
    );
    defer sql_statement.freeStatementDiagnosis(allocator, &d);

    try testing.expectEqual(sql_statement.Status.ok, d.status());
    try testing.expectEqual(sql_statement.Problem.none, d.problem);
    // The count is the server's own (mysql_stmt_param_count), not args.len.
    try testing.expectEqual(@as(?usize, 1), d.param_count);
}

test "MySQL: checkStatement rejects a syntax error" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    var d = try sql_statement.checkStatement(allocator, drv.asDriver(), "SELEC 1", &.{});
    defer sql_statement.freeStatementDiagnosis(allocator, &d);

    try testing.expectEqual(sql_statement.Status.failed, d.status());
    try testing.expectEqual(sql_statement.Problem.syntax, d.problem);
    try testing.expectEqual(@as(i32, 1064), d.native_code);
    // MySQL's errno is structured, so the label is not a guess.
    try testing.expect(!d.problem_heuristic);
    try testing.expect(std.mem.indexOf(u8, d.message.?, "SQL syntax") != null);
}

test "MySQL: checkStatement rejects a statement naming a missing table" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    var d = try sql_statement.checkStatement(allocator, drv.asDriver(), "SELECT * FROM zent_chk_absent", &.{});
    defer sql_statement.freeStatementDiagnosis(allocator, &d);

    try testing.expectEqual(sql_statement.Problem.missing_relation, d.problem);
    try testing.expectEqual(sql_statement.Status.failed, d.status());
    try testing.expectEqual(@as(i32, 1146), d.native_code);
    try testing.expect(std.mem.indexOf(u8, d.message.?, "zent_chk_absent") != null);
    try testing.expect(!d.problem_heuristic);
}

test "MySQL: checkStatement rejects a statement naming a missing column" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    _ = try drv.exec("DROP TABLE IF EXISTS zent_chk_my", &.{});
    _ = try drv.exec("CREATE TABLE zent_chk_my (id INT PRIMARY KEY, name VARCHAR(64))", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS zent_chk_my", &.{}) catch {};

    var d = try sql_statement.checkStatement(allocator, drv.asDriver(), "SELECT zent_chk_bogus FROM zent_chk_my", &.{});
    defer sql_statement.freeStatementDiagnosis(allocator, &d);

    try testing.expectEqual(sql_statement.Problem.missing_column, d.problem);
    try testing.expectEqual(@as(i32, 1054), d.native_code);
    try testing.expect(std.mem.indexOf(u8, d.message.?, "zent_chk_bogus") != null);
}

test "MySQL: checkStatement reports a parameter that does not match the statement" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    _ = try drv.exec("DROP TABLE IF EXISTS zent_chk_my", &.{});
    _ = try drv.exec("CREATE TABLE zent_chk_my (id INT PRIMARY KEY, name VARCHAR(64))", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS zent_chk_my", &.{}) catch {};

    var d = try sql_statement.checkStatement(allocator, drv.asDriver(), "SELECT name FROM zent_chk_my WHERE id = ?", &.{});
    defer sql_statement.freeStatementDiagnosis(allocator, &d);

    try testing.expectEqual(sql_statement.Problem.parameter_mismatch, d.problem);
    try testing.expectEqual(@as(?usize, 1), d.param_count);
    try testing.expect(std.mem.indexOf(u8, d.message.?, "takes 1") != null);
}

test "MySQL: a checked INSERT adds no row" {
    // mysql_stmt_prepare without mysql_stmt_execute.
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    _ = try drv.exec("DROP TABLE IF EXISTS zent_chk_my", &.{});
    _ = try drv.exec("CREATE TABLE zent_chk_my (id INT PRIMARY KEY, name VARCHAR(64))", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS zent_chk_my", &.{}) catch {};

    var d = try sql_statement.checkStatement(
        allocator,
        drv.asDriver(),
        "INSERT INTO zent_chk_my (id, name) VALUES (999, 'x')",
        &.{},
    );
    defer sql_statement.freeStatementDiagnosis(allocator, &d);
    try testing.expectEqual(sql_statement.Status.ok, d.status());

    var rows = try drv.query("SELECT COUNT(*) FROM zent_chk_my", &.{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 0), (rows.next() orelse return error.NoRow).getInt(0).?);

    // The check used one statement on the connection; ordinary use follows.
    _ = try drv.exec("INSERT INTO zent_chk_my (id, name) VALUES (1, 'real')", &.{});
    var rows2 = try drv.query("SELECT COUNT(*) FROM zent_chk_my", &.{});
    defer rows2.deinit();
    try testing.expectEqual(@as(i64, 1), (rows2.next() orelse return error.NoRow).getInt(0).?);
}

test "MySQL: a statement the prepared protocol rejects is not_checkable, not failed" {
    // `BEGIN` is valid SQL and the two servers differ about it: MySQL's
    // prepared-statement protocol refuses it (errno 1295) while MariaDB's
    // accepts it. The invariant that holds on both is the one that matters —
    // a valid statement is never reported as broken — and `exec` runs it
    // through mysql_real_query, where it works either way.
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    var d = try sql_statement.checkStatement(allocator, drv.asDriver(), "BEGIN", &.{});
    defer sql_statement.freeStatementDiagnosis(allocator, &d);

    try testing.expect(d.status() != .failed);
    if (try isMariaDB(&drv)) {
        // MariaDB prepped it, so the channel could judge it and it is clean.
        try testing.expectEqual(sql_statement.Status.ok, d.status());
    } else {
        // MySQL could not judge it. Saying "broken" would be a false alarm, so
        // the answer must be not_checkable, with the server's own reason.
        try testing.expectEqual(sql_statement.Status.not_checkable, d.status());
        try testing.expectEqual(sql_statement.Problem.not_checkable, d.problem);
        try testing.expectEqual(@as(i32, 1295), d.native_code);
        try testing.expect(std.mem.indexOf(u8, d.message.?, "not supported in the prepared statement protocol") != null);
    }
}

test "MySQL: exec maps the client's missing count to unknown, not to 18446744073709551615" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();
    const d = drv.asDriver();

    _ = try d.exec("DROP TABLE IF EXISTS my_rowcount", &.{});
    _ = try d.exec("CREATE TABLE my_rowcount (id INT PRIMARY KEY, v VARCHAR(32))", &.{});
    defer _ = d.exec("DROP TABLE IF EXISTS my_rowcount", &.{}) catch {};

    // DML: the OK packet carries the count through both paths, zero included —
    // this is what the optimistic-lock check and the NotFound paths read.
    const inserted = try d.exec("INSERT INTO my_rowcount VALUES (1,'a'),(2,'b'),(3,'c')", &.{});
    try testing.expectEqual(@as(usize, 3), inserted.rows_affected);
    try testing.expect(inserted.rows_affected_known);

    const inserted_param = try d.exec("INSERT INTO my_rowcount VALUES (?, ?)", &.{ .{ .int = 4 }, .{ .string = "d" } });
    try testing.expectEqual(@as(usize, 1), inserted_param.rows_affected);
    try testing.expect(inserted_param.rows_affected_known);

    const updated = try d.exec("UPDATE my_rowcount SET v = 'z' WHERE id = ?", &.{.{ .int = 1 }});
    try testing.expectEqual(@as(usize, 1), updated.rows_affected);
    try testing.expect(updated.rows_affected_known);

    const matched_none = try d.exec("UPDATE my_rowcount SET v = 'z' WHERE id = ?", &.{.{ .int = 999 }});
    try testing.expectEqual(@as(usize, 0), matched_none.rows_affected);
    try testing.expect(matched_none.rows_affected_known);

    const deleted_none = try d.exec("DELETE FROM my_rowcount WHERE id = ?", &.{.{ .int = 999 }});
    try testing.expectEqual(@as(usize, 0), deleted_none.rows_affected);
    try testing.expect(deleted_none.rows_affected_known);

    // A SELECT through the parameterized path is the reachable sentinel case,
    // and it is a *client-library* value, not a server one: the connector
    // reports `(my_ulonglong)-1` for as long as the statement has no affected
    // count, which is until its result set is consumed — and this path never
    // consumes it. (Measured against MySQL 9.3 through MariaDB Connector/C
    // 3.4.5 with a zero error code, so the sentinel is not an error path.) The
    // naive `@intCast` stored 18446744073709551615 as a row count.
    const selected = try d.exec("SELECT * FROM my_rowcount WHERE id > ?", &.{.{ .int = 0 }});
    try testing.expectEqual(@as(usize, 0), selected.rows_affected);
    try testing.expect(!selected.rows_affected_known);
}
