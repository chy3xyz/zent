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
const edge = zent.core.edge;
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
    // SKIP_PG skips every PG integration test (checked once at the shared
    // entry point, mirroring SKIP_MYSQL in mysql.zig).
    if (std.process.Environ.getPosix(std.testing.environ, "SKIP_PG") != null) return error.SkipZigTest;
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

test "Postgres: JSONValue + WhereEntQL has(edge) work" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const CarBase = schema("PqJCar", .{
        .fields = &.{ field.String("model"), field.JSONValue("meta") },
    });
    const UserBase = schema("PqJUser", .{
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
    defer _ = drv.exec("DROP TABLE IF EXISTS pq_j_user", &.{}) catch {};
    defer _ = drv.exec("DROP TABLE IF EXISTS pq_j_car", &.{}) catch {};

    var c = Client.makeClient(infos, allocator, drv.asDriver());

    // User with untyped JSON document.
    var ub = try c.pq_j_user.Create();
    defer ub.deinit();
    _ = try ub.setFieldValue("name", "alice");
    _ = try ub.setFieldValue("settings", std.json.Value{ .string = "s1" });
    var u = try ub.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &u, allocator);

    // Car with untyped JSON + FK to user.
    var cb = try c.pq_j_car.Create();
    defer cb.deinit();
    _ = try cb.setFieldValue("model", "m");
    _ = try cb.setFieldValue("meta", std.json.Value{ .integer = 7 });
    _ = try cb.setFieldValue("pq_j_user_id", u.id);
    var car = try cb.Save();
    defer zent.codegen.deinitEntity(infos, infos[1], &car, allocator);

    // JSONValue round-trip via query.
    {
        var q = c.pq_j_car.Query();
        defer q.deinit();
        var rows = try q.All();
        defer {
            for (rows.items) |*e| zent.codegen.deinitEntity(infos, infos[1], e, allocator);
            rows.deinit();
        }
        try testing.expect(rows.items[0].meta == .integer);
        try testing.expectEqual(@as(i64, 7), rows.items[0].meta.integer);
    }

    // WhereEntQL has(cars) returns the user with a car.
    {
        var q = c.pq_j_user.Query();
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

test "Postgres: UNIQUE violation surfaces as UniqueViolation" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const U = schema("PqErrUser", .{
        .fields = &.{ field.String("email").Unique(), field.String("name") },
    });
    const graph = comptime buildGraph(&.{U});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS pq_err_user", &.{}) catch {};

    var c = Client.makeClient(infos, allocator, drv.asDriver());
    var b1 = try c.pq_err_user.Create();
    defer b1.deinit();
    _ = try b1.setFieldValue("email", "a@x.com");
    _ = try b1.setFieldValue("name", "one");
    var user1 = try b1.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &user1, allocator);

    var b2 = try c.pq_err_user.Create();
    defer b2.deinit();
    _ = try b2.setFieldValue("email", "a@x.com");
    _ = try b2.setFieldValue("name", "two");
    if (b2.Save()) |_| {
        return error.UnexpectedInsert;
    } else |err| {
        try testing.expectEqual(error.UniqueViolation, err);
    }
}

test "Postgres: TimeMixin audit columns build (epoch BIGINT)" {
    // .time columns must map to BIGINT: the audit default is
    // EXTRACT(EPOCH FROM now())::bigint, so TIMESTAMPTZ + bigint default
    // made CREATE TABLE fail on Postgres.
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const T = schema("TmAudit", .{
        .fields = &.{field.String("name")},
        .mixins = &.{zent.core.mixin.TimeMixin},
    });
    const graph = comptime buildGraph(&.{T});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS tm_audit", &.{}) catch {};

    // Insert picks up the epoch default and round-trips as i64.
    var cb = try Client.makeClient(infos, allocator, drv.asDriver()).tm_audit.Create();
    defer cb.deinit();
    _ = try cb.setFieldValue("name", "x");
    var saved = try cb.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &saved, allocator);

    // created_at is set by the DB default; read it back via a query.
    var q = Client.makeClient(infos, allocator, drv.asDriver()).tm_audit.Query();
    defer q.deinit();
    var rows = try q.All();
    defer {
        for (rows.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
        rows.deinit();
    }
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expect(rows.items[0].created_at.? > 0);
    try testing.expect(rows.items[0].updated_at.? > 0);
}

test "Postgres: slow query times out" {
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
    defer _ = drv.exec("DROP TABLE IF EXISTS \"user\"", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Insert a row first: on an empty table the WHERE clause is never
    // evaluated, so pg_sleep never runs and the query returns instantly
    // without ever hitting statement_timeout.
    var cb = try client.user.Create();
    defer cb.deinit();
    _ = try cb.setFieldValue("name", "slow");
    _ = try cb.setFieldValue("age", 1);
    var saved = try cb.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &saved, allocator);

    var q = client.user.Query();
    defer q.deinit();
    _ = q.withTimeout(100);
    _ = try q.Where(&.{sql.Raw("pg_sleep(2) IS NULL")});
    const result = q.All();
    try testing.expectError(error.QueryTimeout, result);

    // Driver should still be usable after the timeout.
    try drv.ping();

    var rows = try drv.query("SELECT 1 AS one", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 1), row.getInt(0).?);
}

test "Postgres: boolean column scans via getBool (t/f wire format)" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const FlagBase = schema("PqFlag", .{
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
    defer _ = drv.exec("DROP TABLE IF EXISTS pq_flag", &.{}) catch {};

    var c = Client.makeClient(infos, allocator, drv.asDriver());

    // Rows with both boolean values; Postgres stores them as "t"/"f".
    var b1 = try c.pq_flag.Create();
    defer b1.deinit();
    _ = try b1.setFieldValue("name", "on");
    _ = try b1.setFieldValue("active", true);
    var e1 = try b1.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &e1, allocator);

    var b2 = try c.pq_flag.Create();
    defer b2.deinit();
    _ = try b2.setFieldValue("name", "off");
    _ = try b2.setFieldValue("active", false);
    var e2 = try b2.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &e2, allocator);

    var q = c.pq_flag.Query();
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

test "Postgres: decimal (NUMERIC) field round-trips exact text" {
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
        _ = try b.setFieldValue("amount", "0.1000000001");
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &row, allocator);
        try testing.expectEqualStrings("0.1000000001", row.amount);
    }

    var q = client.money.Query();
    defer q.deinit();
    const rows = try q.All();
    defer {
        for (rows.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
        rows.deinit();
    }
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("0.1000000001", rows.items[0].amount);
}

test "Postgres: optimistic lock conflict" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const User = schema("PgLockedUser", .{
        .fields = &.{
            field.Int("id"),
            field.String("name"),
            field.Version("version"),
        },
    });

    const graph = comptime buildGraph(&.{User});
    const infos = graph.types;

    try migrate.migrateSchema(allocator, drv.asDriver(), infos);
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_locked_user", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b = try client.pg_locked_user.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    var created = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);
    try testing.expectEqual(@as(i64, 0), created.version);

    // Simulate stale update: the row exists but the version value is wrong.
    var stale = created;
    stale.name = "bob";
    stale.version = 999;

    var ub = client.pg_locked_user.Update();
    defer ub.deinit();
    _ = try ub.set("name", .{ .string = "bob" });
    _ = try ub.setFieldValue("version", stale.version);
    _ = try ub.Where(.{sql.EQ("id", .{ .int = stale.id })});
    const result = ub.SaveOne();
    try testing.expectError(error.OptimisticLockConflict, result);
}

test "Postgres: optimistic lock update increments version" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const User = schema("PgLockedUser", .{
        .fields = &.{
            field.Int("id"),
            field.String("name"),
            field.Version("version"),
        },
    });

    const graph = comptime buildGraph(&.{User});
    const infos = graph.types;

    try migrate.migrateSchema(allocator, drv.asDriver(), infos);
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_locked_user", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b = try client.pg_locked_user.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    var created = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);
    try testing.expectEqual(@as(i64, 0), created.version);

    var update = client.pg_locked_user.Update();
    defer update.deinit();
    _ = try update.set("name", .{ .string = "bob" });
    _ = try update.setFieldValue("version", created.version);
    _ = try update.Where(.{client.pg_locked_user.predicates.idEQ(.{ .int = created.id })});
    const affected = try update.Save();
    try testing.expectEqual(@as(usize, 1), affected);

    var q = client.pg_locked_user.Query();
    defer q.deinit();
    _ = try q.Where(.{client.pg_locked_user.predicates.idEQ(.{ .int = created.id })});
    const results = try q.All();
    defer {
        for (results.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
        results.deinit();
    }
    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("bob", results.items[0].name);
    try testing.expectEqual(@as(i64, 1), results.items[0].version);
}

test "Postgres: optimistic lock delete conflict" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const User = schema("PgLockedUser", .{
        .fields = &.{
            field.Int("id"),
            field.String("name"),
            field.Version("version"),
        },
    });

    const graph = comptime buildGraph(&.{User});
    const infos = graph.types;

    try migrate.migrateSchema(allocator, drv.asDriver(), infos);
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_locked_user", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b = try client.pg_locked_user.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    var created = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);
    try testing.expectEqual(@as(i64, 0), created.version);

    var db = client.pg_locked_user.Delete();
    defer db.deinit();
    _ = db.setVersion(999);
    _ = try db.Where(.{client.pg_locked_user.predicates.idEQ(.{ .int = created.id })});
    const result = db.ExecOne();
    try testing.expectError(error.OptimisticLockConflict, result);
}

test "Postgres: optimistic lock soft delete conflict and success" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const SoftLockedUser = schema("PgSoftLockedUser", .{
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
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_soft_locked_user", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b = try client.pg_soft_locked_user.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    var created = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);
    try testing.expectEqual(@as(i64, 0), created.version);

    // Stale version should fail with optimistic lock conflict.
    {
        var db = client.pg_soft_locked_user.Delete();
        defer db.deinit();
        _ = db.setVersion(999);
        _ = try db.Where(.{client.pg_soft_locked_user.predicates.idEQ(.{ .int = created.id })});
        const result = db.ExecOne();
        try testing.expectError(error.OptimisticLockConflict, result);
    }

    // Correct version should soft-delete the row and bump the version.
    {
        var db = client.pg_soft_locked_user.Delete();
        defer db.deinit();
        _ = db.setVersion(created.version);
        _ = try db.Where(.{client.pg_soft_locked_user.predicates.idEQ(.{ .int = created.id })});
        const affected = try db.Exec();
        try testing.expectEqual(@as(usize, 1), affected);
    }

    // Verify the row is still present but marked deleted and version incremented.
    var rows = try drv.query("SELECT deleted_at, version FROM pg_soft_locked_user WHERE id = $1", &.{
        .{ .int = created.id },
    });
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expect(row.getInt(0) != null);
    try testing.expect(row.getInt(0).? > 0);
    try testing.expectEqual(@as(i64, 1), row.getInt(1).?);
}

test "Postgres: migrateSchema drops removed column" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // Create legacy table with an extra 'obsolete' column not in the schema.
    _ = try drv.exec("DROP TABLE IF EXISTS pg_drop_test", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_drop_test", &.{}) catch {};
    _ = try drv.exec(
        "CREATE TABLE pg_drop_test (id SERIAL PRIMARY KEY, name TEXT, value INTEGER, obsolete TEXT)",
        &.{},
    );

    const DropTest = schema("PgDropTest", .{
        .fields = &.{
            field.String("name"),
            field.Int("value"),
        },
    });

    const graph = comptime buildGraph(&.{DropTest});
    const infos = graph.types;

    const obsolete_count_sql =
        "SELECT COUNT(*) FROM information_schema.columns WHERE table_name = $1 AND table_schema = current_schema() AND column_name = 'obsolete'";

    // Run with drop_columns: false (default) → column remains.
    try migrate.migrateSchema(allocator, drv.asDriver(), infos);
    {
        var rows = try drv.query(obsolete_count_sql, &.{.{ .string = "pg_drop_test" }});
        defer rows.deinit();
        const row = rows.next() orelse return error.NoRow;
        try testing.expectEqual(@as(i64, 1), row.getInt(0).?);
    }

    // Run with drop_columns: true → column gone.
    try migrate.migrateSchemaWithOptions(allocator, drv.asDriver(), infos, migrate.MigrateOptions{
        .drop_columns = true,
    });
    {
        var rows = try drv.query(obsolete_count_sql, &.{.{ .string = "pg_drop_test" }});
        defer rows.deinit();
        const row = rows.next() orelse return error.NoRow;
        try testing.expectEqual(@as(i64, 0), row.getInt(0).?);
    }
}

test "Postgres: migrateSchema dry-run outputs SQL without executing" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const DREntity = schema("PgDrEntity", .{
        .fields = &.{
            field.String("name"),
            field.Int("value"),
        },
        .indexes = &.{
            index.Named("idx_pg_drentity_name", &.{"name"}),
        },
    });

    const graph = comptime buildGraph(&.{DREntity});
    const infos = graph.types;

    // The table must not exist beforehand — drop leftovers from a previous run.
    _ = try drv.exec("DROP TABLE IF EXISTS pg_dr_entity", &.{});

    // Run with dry_run: true — should NOT create any tables.
    try migrate.migrateSchemaWithOptions(allocator, drv.asDriver(), infos, migrate.MigrateOptions{
        .dry_run = true,
    });

    // Verify the table was not created (the DB is shared, so check the
    // specific table rather than counting all tables like the SQLite test).
    var rows = try drv.query(
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = $1 AND table_schema = current_schema()",
        &.{.{ .string = "pg_dr_entity" }},
    );
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 0), row.getInt(0).?);
}

test "Postgres: WhereIn chunks OR-joins IN predicates" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const CodeBase = schema("PgWhereInCode", .{
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
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_where_in_code", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Seed rows with codes 0..4 plus one row in the second chunk (500).
    for (0..5) |i| {
        var b = try client.pg_where_in_code.Create();
        defer b.deinit();
        _ = try b.setFieldValue("code", @as(i64, @intCast(i)));
        var e = try b.Save();
        zent.codegen.deinitEntity(infos, infos[0], &e, allocator);
    }
    {
        var b = try client.pg_where_in_code.Create();
        defer b.deinit();
        _ = try b.setFieldValue("code", @as(i64, 500));
        var e = try b.Save();
        zent.codegen.deinitEntity(infos, infos[0], &e, allocator);
    }

    // Empty values -> error.EmptyInValues (no SQL is built).
    {
        var q = client.pg_where_in_code.Query();
        defer q.deinit();
        try testing.expectError(error.EmptyInValues, q.WhereIn("code", &.{}));
    }

    // Single value.
    {
        const one = [_]zent.sql.Value{.{ .int = 3 }};
        var q = client.pg_where_in_code.Query();
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
        var q = client.pg_where_in_code.Query();
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
        var q = client.pg_where_in_code.Query();
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
var pg_filter_pred: zent.sql.Predicate = undefined;

fn pgOwnerFilter(ctx: zent.privacy.PrivacyContext) ?*const anyopaque {
    if (ctx.user_id) |uid| {
        pg_filter_pred = zent.sql.EQ("owner_id", .{ .int = uid });
        return @ptrCast(&pg_filter_pred);
    }
    return null;
}

test "Postgres: privacy filter restricts rows by owner_id" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // Schema with owner_id field and a Filter-based privacy policy.
    const FilteredEntity = schema("PgFilteredEntity", .{
        .fields = &.{
            field.String("name"),
            field.Int("owner_id"),
        },
        .policy = zent.privacy.Policy{
            .rules = &.{
                zent.privacy.Allow,
                zent.privacy.Filter(pgOwnerFilter),
            },
        },
    });

    const graph = comptime buildGraph(&.{FilteredEntity});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_filtered_entity", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Insert two rows: one owned by user 1, one owned by user 2.
    {
        var c1 = client.pg_filtered_entity.withContext(.{ .user_id = 1 });
        var b1 = try c1.Create();
        defer b1.deinit();
        _ = try b1.setFieldValue("name", "alice-item");
        _ = try b1.setFieldValue("owner_id", @as(i64, 1));
        var e1 = try b1.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &e1, allocator);
        try testing.expect(e1.id > 0);
    }
    {
        var c2 = client.pg_filtered_entity.withContext(.{ .user_id = 2 });
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
        var c1 = client.pg_filtered_entity.withContext(.{ .user_id = 1 });
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
        var c2 = client.pg_filtered_entity.withContext(.{ .user_id = 2 });
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
        var c3 = client.pg_filtered_entity.withContext(.{ .user_id = 999 });
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
        var c_anon = client.pg_filtered_entity.withContext(.{});
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

test "Postgres: BulkInsert multi-row RETURNING" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const BulkEntity = schema("PgBulkEntity", .{
        .fields = &.{
            field.String("name"),
            field.Int("score"),
        },
    });

    const graph = comptime buildGraph(&.{BulkEntity});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_bulk_entity", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Insert 3 rows in a single round-trip.
    var b = try client.pg_bulk_entity.BulkInsert();
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
    // IDs come from a fresh sequence; assert they are distinct and increasing.
    try testing.expect(ids.items[0] > 0);
    try testing.expect(ids.items[1] > ids.items[0]);
    try testing.expect(ids.items[2] > ids.items[1]);

    // Verify rows actually exist in the DB.
    var rows = try drv.query("SELECT id, name, score FROM pg_bulk_entity ORDER BY id", &.{});
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

test "Postgres: file-based migrations" {
    const allocator = testing.allocator;
    const io = testing.io;

    const dir_name = "test_migrations_file_pg";
    try std.Io.Dir.cwd().createDirPath(io, dir_name);
    defer std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var dir = try std.Io.Dir.cwd().openDir(io, dir_name, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{
            .sub_path = "900101_create_pg_file_items.up.sql",
            .data =
            \\CREATE TABLE pg_file_items (id INTEGER PRIMARY KEY, name TEXT);
            \\INSERT INTO pg_file_items (id, name) VALUES (1, 'first');
            ,
        });
        try dir.writeFile(io, .{
            .sub_path = "900101_create_pg_file_items.down.sql",
            .data = "DELETE FROM pg_file_items;",
        });
        try dir.writeFile(io, .{
            .sub_path = "900102_add_second_item.up.sql",
            .data = "INSERT INTO pg_file_items (id, name) VALUES (2, 'second');",
        });
    }

    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // Clean leftovers from a previous run: the shared zent_schema_migrations
    // history would otherwise mark these versions as already applied.
    _ = try drv.exec("DROP TABLE IF EXISTS pg_file_items", &.{});
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_file_items", &.{}) catch {};
    _ = try drv.exec("DELETE FROM zent_schema_migrations WHERE version IN ($1, $2)", &.{ .{ .int = 900101 }, .{ .int = 900102 } });
    defer _ = drv.exec("DELETE FROM zent_schema_migrations WHERE version IN ($1, $2)", &.{ .{ .int = 900101 }, .{ .int = 900102 } }) catch {};

    try migrate.migrateFromFiles(io, allocator, drv.asDriver(), dir_name);

    var rows = try drv.query("SELECT COUNT(*) FROM pg_file_items", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 2), row.getInt(0).?);

    try migrate.rollbackFiles(io, allocator, drv.asDriver(), dir_name, 1);

    var rows2 = try drv.query("SELECT COUNT(*) FROM pg_file_items", &.{});
    defer rows2.deinit();
    const row2 = rows2.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 0), row2.getInt(0).?);
}

test "Postgres: database-level cascade delete" {
    const allocator = testing.allocator;

    const User = schema("PgCascadeUser", .{
        .fields = &.{ field.Int("id"), field.String("name") },
    });
    const Order = schema("PgCascadeOrder", .{
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

    _ = try drv.exec("DROP TABLE IF EXISTS pg_cascade_order", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS pg_cascade_user", &.{});
    // Drop the child first at cleanup: defers run LIFO, and pg_cascade_order
    // holds the FK referencing pg_cascade_user.
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_cascade_user", &.{}) catch {};
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_cascade_order", &.{}) catch {};

    // Unlike SQLite, PostgreSQL always enforces declared FK constraints.
    try migrate.migrateSchema(allocator, drv.asDriver(), infos);

    _ = try drv.exec("INSERT INTO pg_cascade_user (id, name) VALUES (1, 'alice')", &.{});
    _ = try drv.exec("INSERT INTO pg_cascade_order (id, user_id) VALUES (10, 1)", &.{});
    _ = try drv.exec("INSERT INTO pg_cascade_order (id, user_id) VALUES (11, 1)", &.{});

    _ = try drv.exec("DELETE FROM pg_cascade_user WHERE id = 1", &.{});

    var rows = try drv.query("SELECT COUNT(*) FROM pg_cascade_order", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 0), row.getInt(0).?);
}

test "Postgres: stream iterator avoids loading all rows" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const StreamEntity = schema("PgStreamEntity", .{
        .fields = &.{
            field.String("name"),
            field.Int("idx"),
        },
    });

    const graph = comptime buildGraph(&.{StreamEntity});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_stream_entity", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Create 50 entities.
    for (0..50) |i| {
        var b = try client.pg_stream_entity.Create();
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
        var q = client.pg_stream_entity.Query();
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

test "Postgres: beginTx propagates hooks and privacy_ctx to transaction entity clients" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    // Entity with AlwaysAllow policy (requires privacy context to be set)
    // and hooks to verify propagation.
    const TxPropEntity = schema("PgTxPropEntity", .{
        .fields = &.{field.String("name")},
        .policy = zent.privacy.AlwaysAllow,
    });

    const graph = comptime buildGraph(&.{TxPropEntity});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_tx_prop_entity", &.{}) catch {};

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Container for verifying hook fired.
    const H = struct {
        var before_called: bool = false;
        fn beforeFn(ctx: *zent.runtime.hook.HookContext) zent.runtime.hook.HookError!void {
            _ = ctx;
            before_called = true;
        }
    };
    H.before_called = false;

    const hooks = &[_]zent.runtime.hook.Hook{
        zent.runtime.hook.Hook.initBefore(.create, H.beforeFn),
    };

    // Set hooks and privacy context on the entity client.
    client.pg_tx_prop_entity = client.pg_tx_prop_entity.withHooks(hooks);
    client.pg_tx_prop_entity = client.pg_tx_prop_entity.withContext(zent.privacy.PrivacyContext{ .user_id = 42 });

    // Verify hooks slice is non-empty on the parent client (precondition).
    try testing.expectEqual(@as(usize, 1), client.pg_tx_prop_entity.hooks.len);

    // Begin a transaction.
    var tx = try Client.beginTx(infos, client);
    defer tx.deinit();

    // Verify hooks propagated to tx client.
    try testing.expectEqual(@as(usize, 1), tx.client.pg_tx_prop_entity.hooks.len);

    // Verify privacy_ctx propagated to tx client.
    try testing.expect(tx.client.pg_tx_prop_entity.privacy_ctx != null);
    try testing.expectEqual(@as(i64, 42), tx.client.pg_tx_prop_entity.privacy_ctx.?.user_id);

    // Perform a create inside the transaction — should succeed (privacy allows)
    // and the before hook should fire.
    var b = try tx.client.pg_tx_prop_entity.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "tx-hook-test");
    var entity = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &entity, allocator);

    try testing.expect(entity.id > 0);
    try testing.expect(H.before_called);
    try testing.expectEqualStrings("tx-hook-test", entity.name);

    try tx.commit();
}

test "Postgres: interceptor injects tenant filter into query/update/delete" {
    const allocator = testing.allocator;
    var drv = connect(allocator) catch |err| return skipIfNoServer(err);
    defer drv.close();

    const TenantDoc = schema("PgTenantDoc", .{
        .fields = &.{
            field.String("name"),
            field.Int("tenant_id"),
        },
    });

    const graph = comptime buildGraph(&.{TenantDoc});
    const infos = graph.types;
    _ = try drv.exec("DROP TABLE IF EXISTS pg_tenant_doc", &.{});
    try Client.createAllTables(infos, drv.asDriver());
    defer _ = drv.exec("DROP TABLE IF EXISTS pg_tenant_doc", &.{}) catch {};

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
        var b = try client.pg_tenant_doc.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", s.n);
        _ = try b.setFieldValue("tenant_id", s.t);
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &e, allocator);
    }

    // Query reads only the current tenant's row.
    {
        var q = client.pg_tenant_doc.Query();
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
        var u = client.pg_tenant_doc.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "renamed");
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }

    // Delete scoped to tenant 2 removes exactly its row.
    tenant = 2;
    {
        var d = client.pg_tenant_doc.Delete();
        defer d.deinit();
        try testing.expectEqual(@as(usize, 1), try d.Exec());
    }

    // Only tenant 1's renamed row remains.
    tenant = 1;
    var q = client.pg_tenant_doc.Query();
    defer q.deinit();
    const rows = try q.All();
    defer {
        for (rows.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
        rows.deinit();
    }
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("renamed", rows.items[0].name);
}
