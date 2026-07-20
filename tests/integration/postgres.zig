//! Integration tests for the PostgreSQL driver against a local server.
//!
//! Expects a database `zent_test` on localhost:5432 accessible by the
//! current OS user without a password (common Homebrew default).
//! Set PG_DSN to override, e.g.:
//!   PG_DSN="host=localhost dbname=zent_test user=postgres password=secret"

const std = @import("std");
const zent = @import("zent");
const pg_c = @import("pg_c");
const PostgresDriver = zent.sql_postgres.PostgresDriver;
const buildGraph = zent.codegen.graph.buildGraph;
const Client = zent.codegen.client;
const field = zent.core.field;
const index = zent.core.index;
const migrate = zent.sql_schema;
const schema = zent.core.schema.Schema;
const privacy = zent.privacy;
const Hook = zent.runtime.hook.Hook;
const HookError = zent.runtime.hook.HookError;
const ConnPool = zent.sql_pool.ConnPool;
const PreparedCache = zent.sql_cache.PreparedCache;
const sql = zent.sql;
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

test "Postgres: SaveOrUpdate with long column name" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // 70 bytes, longer than PostgreSQL's effective identifier limit; the
    // point is that formatting the upsert piece no longer overflows a
    // 128-byte stack buffer before PostgreSQL truncates the identifier.
    const long_name = "a_very_long_column_name_that_used_to_overflow_the_upsert_piece_buffer_";

    const PgLongCol = schema("PgLongCol", .{
        .fields = &.{
            field.Int(long_name),
        },
    });

    const graph = comptime buildGraph(&.{PgLongCol});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_long_col", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b1 = try client.pg_long_col.Create();
    defer b1.deinit();
    _ = try b1.setFieldValue("id", @as(i64, 99));
    _ = try b1.setFieldValue(long_name, @as(i64, 100));
    _ = try b1.SaveOrUpdate();

    var b2 = try client.pg_long_col.Create();
    defer b2.deinit();
    _ = try b2.setFieldValue("id", @as(i64, 99));
    _ = try b2.setFieldValue(long_name, @as(i64, 200));
    _ = try b2.SaveOrUpdate();

    var rows = try drv.query("SELECT " ++ long_name ++ " FROM pg_long_col WHERE id = $1", &.{.{ .int = 99 }});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 200), row.getInt(0).?);
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

test "Postgres: migrateSchema is idempotent with existing table" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    _ = try drv.exec("DROP TABLE IF EXISTS pg_migration", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_migration", &.{}) catch {};
    _ = try drv.exec("CREATE TABLE pg_migration (id INTEGER PRIMARY KEY, score INTEGER NOT NULL)", &.{});

    const PgMigration = schema("PgMigration", .{
        .fields = &.{
            field.Int("score"),
            field.String("label"),
        },
        .indexes = &.{
            index.Named("idx_pg_migration_score", &.{"score"}),
        },
    });
    const graph = comptime buildGraph(&.{PgMigration});

    try migrate.migrateSchema(allocator, drv.asDriver(), graph.types);
    try migrate.migrateSchema(allocator, drv.asDriver(), graph.types);

    var column_rows = try drv.query(
        "SELECT COUNT(*) FROM information_schema.columns WHERE table_name = $1 AND table_schema = current_schema() AND column_name = $2",
        &.{ .{ .string = "pg_migration" }, .{ .string = "label" } },
    );
    defer column_rows.deinit();
    const column_row = column_rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 1), column_row.getInt(0).?);

    var index_rows = try drv.query(
        "SELECT COUNT(*) FROM pg_indexes WHERE tablename = $1 AND schemaname = current_schema() AND indexname = $2",
        &.{ .{ .string = "pg_migration" }, .{ .string = "idx_pg_migration_score" } },
    );
    defer index_rows.deinit();
    const index_row = index_rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 1), index_row.getInt(0).?);
}

test "Postgres: PG-specific types (TIMESTAMPTZ, JSONB, UUID, BYTEA)" {
    if (std.process.Environ.getPosix(std.testing.environ, "SKIP_PG") != null) return error.SkipZigTest;
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    _ = try drv.exec("DROP TABLE IF EXISTS pg_type_test", &.{});
    _ = try drv.exec(
        \\CREATE TABLE pg_type_test (
        \\  id SERIAL PRIMARY KEY,
        \\  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        \\  data JSONB,
        \\  uid UUID DEFAULT gen_random_uuid(),
        \\  payload BYTEA
        \\)
    , &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_type_test", &.{}) catch {};

    const now_str = "2025-01-15T10:30:00+00:00";
    const json_str = "{\"key\":\"value\",\"num\":42}";
    const uuid_str = "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11";
    const bytes_data = "hello world";

    const res = try drv.exec(
        \\INSERT INTO pg_type_test (created_at, data, uid, payload)
        \\VALUES ($1::TIMESTAMPTZ, $2::JSONB, $3::UUID, $4::BYTEA) RETURNING id
    , &.{
        .{ .string = now_str },
        .{ .string = json_str },
        .{ .string = uuid_str },
        .{ .bytes = bytes_data },
    });
    try testing.expectEqual(@as(usize, 1), res.rows_affected);
    try testing.expect(res.last_insert_id != null);

    // Round-trip: read back with text casts.
    var rows = try drv.query(
        \\SELECT id, created_at, data::TEXT, uid::TEXT, encode(payload, 'escape')
        \\FROM pg_type_test WHERE id = $1
    , &.{.{ .int = res.last_insert_id.? }});
    defer rows.deinit();

    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 1), row.getInt(0).?);
    try testing.expect(row.getText(1) != null); // created_at
    try testing.expect(row.getText(2) != null); // JSONB data
    try testing.expectEqualStrings(uuid_str, row.getText(3).?);
    try testing.expectEqualStrings("hello world", row.getText(4).?);

    // Verify PG type names in information_schema.
    var type_rows = try drv.query(
        \\SELECT column_name, data_type FROM information_schema.columns
        \\WHERE table_name = $1 AND table_schema = current_schema()
        \\ORDER BY ordinal_position
    , &.{.{ .string = "pg_type_test" }});
    defer type_rows.deinit();

    // id → integer
    {
        const r = type_rows.next() orelse return error.NoRow;
        try testing.expectEqualStrings("id", r.getText(0).?);
        try testing.expectEqualStrings("integer", r.getText(1).?);
    }
    // created_at → timestamp with time zone
    {
        const r = type_rows.next() orelse return error.NoRow;
        try testing.expectEqualStrings("created_at", r.getText(0).?);
        try testing.expectEqualStrings("timestamp with time zone", r.getText(1).?);
    }
    // data → jsonb
    {
        const r = type_rows.next() orelse return error.NoRow;
        try testing.expectEqualStrings("data", r.getText(0).?);
        try testing.expectEqualStrings("jsonb", r.getText(1).?);
    }
    // uid → uuid
    {
        const r = type_rows.next() orelse return error.NoRow;
        try testing.expectEqualStrings("uid", r.getText(0).?);
        try testing.expectEqualStrings("uuid", r.getText(1).?);
    }
    // payload → bytea
    {
        const r = type_rows.next() orelse return error.NoRow;
        try testing.expectEqualStrings("payload", r.getText(0).?);
        try testing.expectEqualStrings("bytea", r.getText(1).?);
    }
}

test "Postgres: prepared statement cache hit" {
    if (std.process.Environ.getPosix(std.testing.environ, "SKIP_PG") != null) return error.SkipZigTest;
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // Enable the prepared-statement cache.
    drv.cache = PreparedCache(16, *pg_c.PGresult){};

    _ = try drv.exec("DROP TABLE IF EXISTS pg_cache_test", &.{});
    _ = try drv.exec("CREATE TABLE pg_cache_test (id SERIAL PRIMARY KEY, val INT)", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_cache_test", &.{}) catch {};

    // Execute the same INSERT twice — second call should hit the cache.
    _ = try drv.exec("INSERT INTO pg_cache_test (val) VALUES ($1)", &.{.{ .int = 1 }});
    _ = try drv.exec("INSERT INTO pg_cache_test (val) VALUES ($1)", &.{.{ .int = 2 }});

    // Verify both rows were inserted.
    var rows = try drv.query("SELECT COUNT(*) FROM pg_cache_test", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 2), row.getInt(0).?);

    // The prepared statement should be visible in the session.
    var prep_rows = try drv.query("SELECT COUNT(*) FROM pg_prepared_statements WHERE name LIKE 'p\\_%'", &.{});
    defer prep_rows.deinit();
    const prep_row = prep_rows.next() orelse return error.NoRow;
    try testing.expect(prep_row.getInt(0).? >= 1);

    // Execute the same query again (3rd time) — still correct.
    _ = try drv.exec("INSERT INTO pg_cache_test (val) VALUES ($1)", &.{.{ .int = 3 }});
    var rows3 = try drv.query("SELECT COUNT(*) FROM pg_cache_test", &.{});
    defer rows3.deinit();
    const row3 = rows3.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 3), row3.getInt(0).?);
}

test "Postgres: connection pool basic operations" {
    if (std.process.Environ.getPosix(std.testing.environ, "SKIP_PG") != null) return error.SkipZigTest;
    const allocator = testing.allocator;

    const BorrowReleaseCounters = struct {
        borrow: usize = 0,
        release: usize = 0,
    };
    var counters = BorrowReleaseCounters{};

    var pool = ConnPool(PostgresDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !PostgresDriver {
                if (std.process.Environ.getPosix(std.testing.environ, "PG_DSN")) |dsn| {
                    return PostgresDriver.connect(a, dsn);
                }
                const user = std.process.Environ.getPosix(std.testing.environ, "USER") orelse "n0x";
                const conninfo = try std.fmt.allocPrint(a, "host=localhost dbname=zent_test user={s}", .{user});
                defer a.free(conninfo);
                return PostgresDriver.connect(a, conninfo);
            }
        }.f,
        .min_connections = 2,
        .max_connections = 2,
        .health_check_on_borrow = false,
        .metrics = .{
            .onBorrow = struct {
                fn f(ctx: ?*anyopaque, _: u32) void {
                    const c: *BorrowReleaseCounters = @ptrCast(@alignCast(ctx));
                    c.borrow += 1;
                }
            }.f,
            .onRelease = struct {
                fn f(ctx: ?*anyopaque) void {
                    const c: *BorrowReleaseCounters = @ptrCast(@alignCast(ctx));
                    c.release += 1;
                }
            }.f,
            .context = &counters,
        },
    }) catch |err| return skipIfNoServer(err);
    defer pool.deinit();

    // Verify warm-up: min_connections opened.
    try testing.expectEqual(@as(usize, 2), pool.all.items.len);
    try testing.expectEqual(@as(usize, 2), pool.available.items.len);

    const drv = pool.asDriver();
    try drv.ping();

    // Create table and CRUD through pooled driver.
    _ = try drv.exec("DROP TABLE IF EXISTS pg_pool_test", &.{});
    _ = try drv.exec("CREATE TABLE pg_pool_test (id SERIAL PRIMARY KEY, name TEXT)", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_pool_test", &.{}) catch {};

    _ = try drv.exec("INSERT INTO pg_pool_test (name) VALUES ($1)", &.{.{ .string = "pooled" }});
    var rows = try drv.query("SELECT name FROM pg_pool_test WHERE name = $1", &.{.{ .string = "pooled" }});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqualStrings("pooled", row.getText(0).?);

    // Metrics should have recorded borrow and release calls.
    try testing.expect(counters.borrow >= 1);
    try testing.expect(counters.release >= 1);
}

test "Postgres: privacy deny blocks query" {
    if (std.process.Environ.getPosix(std.testing.environ, "SKIP_PG") != null) return error.SkipZigTest;
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const PgPriv = schema("PgPriv", .{
        .fields = &.{
            field.String("name"),
        },
        .policy = privacy.AlwaysDeny,
    });

    const graph = comptime buildGraph(&.{PgPriv});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_priv", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // With a privacy context, AlwaysDeny should block queries.
    var ec = client.pg_priv.withContext(.{ .user_id = 1 });
    var qb = ec.Query();
    try testing.expectError(error.PrivacyDenied, qb.All());

    // Also blocks Create.
    var cb = try ec.Create();
    defer cb.deinit();
    _ = try cb.setFieldValue("id", @as(i64, 1));
    _ = try cb.setFieldValue("name", "test");
    try testing.expectError(error.PrivacyDenied, cb.Save());
}

test "Postgres: hooks fire on create/update" {
    if (std.process.Environ.getPosix(std.testing.environ, "SKIP_PG") != null) return error.SkipZigTest;
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const PgHook = schema("PgHook", .{
        .fields = &.{
            field.String("name"),
        },
    });

    const graph = comptime buildGraph(&.{PgHook});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_hook", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Track hook invocations.
    const HookState = struct {
        var before_create_called: bool = false;
        var before_table_name: ?[]const u8 = null;
        var after_update_called: bool = false;
    };

    const beforeCreateHook = Hook.initBefore(.create, struct {
        fn f(ctx: *zent.runtime.hook.HookContext) HookError!void {
            HookState.before_create_called = true;
            HookState.before_table_name = ctx.table_name;
        }
    }.f);

    const afterUpdateHook = Hook.initAfter(.update, struct {
        fn f(ctx: *zent.runtime.hook.HookContext) HookError!void {
            HookState.after_update_called = true;
            _ = ctx;
        }
    }.f);

    const hooks = [_]Hook{ beforeCreateHook, afterUpdateHook };
    var ec = client.pg_hook.withHooks(&hooks);

    // Before-create hook fires.
    {
        var b = try ec.Create();
        defer b.deinit();
        _ = try b.setFieldValue("id", @as(i64, 1));
        _ = try b.setFieldValue("name", "hook-test");
        var entity = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &entity, allocator);
        try testing.expect(HookState.before_create_called);
        try testing.expectEqualStrings("pg_hook", HookState.before_table_name.?);
    }

    // After-update hook fires. Use raw SQL to update to avoid type issues.
    {
        _ = try drv.exec("UPDATE pg_hook SET name = $1 WHERE id = $2", &.{ .{ .string = "updated-name" }, .{ .int = 1 } });

        // Also update through the entity client to trigger hooks.
        var ub = ec.Update();
        defer ub.deinit();
        _ = try ub.set("name", .{ .string = "hooked-name" });
        _ = try ub.Where(.{sql.EQ("id", .{ .int = 1 })});
        _ = try ub.Save();
        try testing.expect(HookState.after_update_called);
    }

    // Verify the data was updated.
    {
        var qb = ec.Query();
        var result = try qb.All();
        defer {
            for (result.items) |*e| zent.codegen.deinitEntity(infos, infos[infos.len - 1], e, allocator);
            result.deinit();
        }
        try testing.expectEqual(@as(usize, 1), result.items.len);
        try testing.expectEqualStrings("hooked-name", result.items[0].name);
    }
}

test "Postgres: bulk insert and count" {
    if (std.process.Environ.getPosix(std.testing.environ, "SKIP_PG") != null) return error.SkipZigTest;
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const PgBulk = schema("PgBulk", .{
        .fields = &.{
            field.String("label"),
        },
    });

    const graph = comptime buildGraph(&.{PgBulk});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_bulk", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // BulkInsert 3 entities.
    var bulk = try client.pg_bulk.BulkInsert();
    defer bulk.deinit();

    _ = try bulk.setFieldValue("id", @as(i64, 1));
    _ = try bulk.setFieldValue("label", "a");
    _ = try bulk.Next();
    _ = try bulk.setFieldValue("id", @as(i64, 2));
    _ = try bulk.setFieldValue("label", "b");
    _ = try bulk.Next();
    _ = try bulk.setFieldValue("id", @as(i64, 3));
    _ = try bulk.setFieldValue("label", "c");

    var ids = try bulk.Save();
    defer ids.deinit();

    try testing.expectEqual(@as(usize, 3), ids.items.len);

    // Verify IDs are returned in insertion order.
    try testing.expectEqual(@as(i64, 1), ids.items[0]);
    try testing.expectEqual(@as(i64, 2), ids.items[1]);
    try testing.expectEqual(@as(i64, 3), ids.items[2]);

    // Count matches.
    var q_count = client.pg_bulk.Query();
    const count = try q_count.Count();
    try testing.expectEqual(@as(i64, 3), count);
}

test "Postgres: ForUpdate / ForShare in transaction" {
    if (std.process.Environ.getPosix(std.testing.environ, "SKIP_PG") != null) return error.SkipZigTest;
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    _ = try drv.exec("DROP TABLE IF EXISTS pg_lock_test", &.{});
    _ = try drv.exec("CREATE TABLE pg_lock_test (id SERIAL PRIMARY KEY, val INT)", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_lock_test", &.{}) catch {};

    // Insert test data.
    _ = try drv.exec("INSERT INTO pg_lock_test (val) VALUES ($1)", &.{.{ .int = 10 }});
    _ = try drv.exec("INSERT INTO pg_lock_test (val) VALUES ($1)", &.{.{ .int = 20 }});

    // SELECT ... FOR UPDATE inside a transaction.
    {
        var tx = try drv.beginTx();
        defer tx.deinit();

        var rows = try tx.query("SELECT id, val FROM pg_lock_test WHERE id = $1 FOR UPDATE", &.{.{ .int = 1 }});
        defer rows.deinit();
        const row = rows.next() orelse return error.NoRow;
        try testing.expectEqual(@as(i64, 1), row.getInt(0).?);
        try testing.expectEqual(@as(i64, 10), row.getInt(1).?);

        // No more rows expected.
        try testing.expect(rows.next() == null);

        try tx.commit();
    }

    // SELECT ... FOR SHARE inside a transaction.
    {
        var tx = try drv.beginTx();
        defer tx.deinit();

        var rows = try tx.query("SELECT id, val FROM pg_lock_test FOR SHARE", &.{});
        defer rows.deinit();

        var count: usize = 0;
        while (rows.next()) |_| {
            count += 1;
        }
        try testing.expectEqual(@as(usize, 2), count);

        try tx.commit();
    }
}
