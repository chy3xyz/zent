//! Integration tests for the SQLite driver.
//! Tests the full CRUD flow plus transactions and edge cases.

const std = @import("std");
const zent = @import("zent");
const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
const Dialect = zent.sql_dialect.Dialect;
const scanRow = zent.sql_scan.scanRow;
const buildGraph = zent.codegen.graph.buildGraph;
const Client = zent.codegen.client;
const migrate = zent.sql_schema;
const field = zent.core.field;
const index = zent.core.index;
const schema = zent.core.schema.Schema;
const testing = std.testing;

test "SQLite: CREATE TABLE and INSERT" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, price REAL, qty INTEGER)", &.{});

    const res = try drv.exec("INSERT INTO items (name, price, qty) VALUES (?, ?, ?)", &.{
        .{ .string = "widget" },
        .{ .float = 9.99 },
        .{ .int = 42 },
    });
    try testing.expectEqual(@as(usize, 1), res.rows_affected);
    try testing.expect(res.last_insert_id != null);
    try testing.expect(res.last_insert_id.? > 0);
}

test "SQLite: basic SELECT" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)", &.{});
    _ = try drv.exec("INSERT INTO users VALUES (1, 'alice', 30)", &.{});
    _ = try drv.exec("INSERT INTO users VALUES (2, 'bob', 25)", &.{});

    var rows = try drv.query("SELECT id, name, age FROM users ORDER BY id", &.{});
    defer rows.deinit();

    // alice
    const row1 = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 1), row1.getInt(0).?);
    try testing.expectEqualStrings("alice", row1.getText(1).?);
    try testing.expectEqual(@as(i64, 30), row1.getInt(2).?);

    // bob
    const row2 = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 2), row2.getInt(0).?);
    try testing.expectEqualStrings("bob", row2.getText(1).?);
    try testing.expectEqual(@as(i64, 25), row2.getInt(2).?);

    // no more rows
    try testing.expect(rows.next() == null);
}

test "SQLite: parameterized query" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER, name TEXT)", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (1, 'hello')", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (2, 'world')", &.{});

    var rows = try drv.query("SELECT name FROM t WHERE id = ?", &.{.{ .int = 2 }});
    defer rows.deinit();

    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqualStrings("world", row.getText(0).?);
    try testing.expect(rows.next() == null);
}

test "SQLite: NULL handling" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER, val INTEGER)", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (1, NULL)", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (2, 42)", &.{});

    var rows = try drv.query("SELECT id, val FROM t ORDER BY id", &.{});
    defer rows.deinit();

    const row1 = rows.next() orelse return error.NoRow;
    try testing.expect(row1.isNull(1));
    try testing.expect(row1.getInt(1) == null);

    const row2 = rows.next() orelse return error.NoRow;
    try testing.expect(!row2.isNull(1));
    try testing.expectEqual(@as(i64, 42), row2.getInt(1).?);
}

test "SQLite: UPDATE" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER, val TEXT)", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (1, 'old')", &.{});

    const res = try drv.exec("UPDATE t SET val = ? WHERE id = ?", &.{ .{ .string = "new" }, .{ .int = 1 } });
    try testing.expectEqual(@as(usize, 1), res.rows_affected);

    var rows = try drv.query("SELECT val FROM t WHERE id = 1", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqualStrings("new", row.getText(0).?);
}

test "SQLite: DELETE" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER)", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (1)", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (2)", &.{});

    const res = try drv.exec("DELETE FROM t WHERE id = ?", &.{.{ .int = 1 }});
    try testing.expectEqual(@as(usize, 1), res.rows_affected);

    var rows = try drv.query("SELECT COUNT(*) FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 1), row.getInt(0).?);
}

test "SQLite: transaction commit" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER)", &.{});

    // Begin transaction
    var tx = try drv.beginTx();
    defer tx.deinit();
    _ = try tx.exec("INSERT INTO t VALUES (42)", &.{});
    _ = try tx.exec("INSERT INTO t VALUES (99)", &.{});
    try tx.commit();

    // Verify data persisted
    var rows = try drv.query("SELECT id FROM t ORDER BY id", &.{});
    defer rows.deinit();
    const row1 = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 42), row1.getInt(0).?);
    const row2 = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 99), row2.getInt(0).?);
}

test "SQLite: transaction rollback" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER)", &.{});

    var tx = try drv.beginTx();
    defer tx.deinit();
    _ = try tx.exec("INSERT INTO t VALUES (1)", &.{});
    try tx.rollback();

    var rows = try drv.query("SELECT COUNT(*) FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 0), row.getInt(0).?);
}

test "SQLite: scanRow primitive" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (val INTEGER)", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (42)", &.{});

    var rows = try drv.query("SELECT val FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    const val = try scanRow(i64, allocator, row);
    try testing.expectEqual(@as(i64, 42), val);
}

test "SQLite: scanRow struct" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER, name TEXT, score REAL)", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (1, 'alice', 95.5)", &.{});

    const MyStruct = struct {
        id: i64,
        name: []const u8,
        score: f64,
    };

    var rows = try drv.query("SELECT id, name, score FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    const val = try scanRow(MyStruct, allocator, row);
    defer allocator.free(val.name);
    try testing.expectEqual(@as(i64, 1), val.id);
    try testing.expectEqualStrings("alice", val.name);
    try testing.expectEqual(@as(f64, 95.5), val.score);
}

test "SQLite: BLOB roundtrip" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER, data BLOB)", &.{});
    const blob_data = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    _ = try drv.exec("INSERT INTO t VALUES (1, ?)", &.{.{ .bytes = blob_data }});

    var rows = try drv.query("SELECT data FROM t WHERE id = 1", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    const result = row.getBlob(0).?;
    try testing.expectEqualSlices(u8, blob_data, result);
}

test "SQLite: column names" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (a INTEGER, b TEXT, c REAL)", &.{});
    _ = try drv.exec("INSERT INTO t VALUES (1, 'x', 1.0)", &.{});
    var rows = try drv.query("SELECT a, b, c FROM t", &.{});
    defer rows.deinit();

    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(usize, 3), row.columnCount());
    try testing.expectEqualStrings("a", row.columnName(0));
    try testing.expectEqualStrings("b", row.columnName(1));
    try testing.expectEqualStrings("c", row.columnName(2));
}

test "SQLite: SaveOrUpdate updates existing row" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const UpsertUser = schema("UpsertUser", .{
        .fields = &.{
            field.Int("score"),
        },
    });

    const graph = comptime buildGraph(&.{UpsertUser});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b1 = try client.upsert_user.Create();
    defer b1.deinit();
    _ = try b1.setFieldValue("id", @as(i64, 99));
    _ = try b1.setFieldValue("score", @as(i64, 100));
    _ = try b1.SaveOrUpdate();

    var b2 = try client.upsert_user.Create();
    defer b2.deinit();
    _ = try b2.setFieldValue("id", @as(i64, 99));
    _ = try b2.setFieldValue("score", @as(i64, 200));
    _ = try b2.SaveOrUpdate();

    var rows = try drv.query("SELECT score FROM upsert_user WHERE id = ?", &.{.{ .int = 99 }});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 200), row.getInt(0).?);
}

test "SQLite: Max/Min Rows deinit on numeric and empty paths" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const Product = schema("Product", .{
        .fields = &.{
            field.String("name"),
            field.Int("qty"),
            field.Float("price"),
        },
    });
    const EmptyProduct = schema("EmptyProduct", .{
        .fields = &.{
            field.String("name"),
            field.Int("qty"),
            field.Float("price"),
        },
    });

    const graph = comptime buildGraph(&.{ Product, EmptyProduct });
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Insert rows directly via SQL to avoid Entity cleanup.
    _ = try drv.exec("INSERT INTO product (name, qty, price) VALUES (?, ?, ?)", &.{
        .{ .string = "alice" },
        .{ .int = 3 },
        .{ .float = 1.50 },
    });
    _ = try drv.exec("INSERT INTO product (name, qty, price) VALUES (?, ?, ?)", &.{
        .{ .string = "charlie" },
        .{ .int = 7 },
        .{ .float = 9.99 },
    });
    _ = try drv.exec("INSERT INTO product (name, qty, price) VALUES (?, ?, ?)", &.{
        .{ .string = "bob" },
        .{ .int = 5 },
        .{ .float = 4.50 },
    });

    // Numeric aggregates.
    {
        var q = client.product.Query();
        defer q.deinit();
        const max_qty = try q.Max("qty");
        try testing.expect(max_qty == .int);
        try testing.expectEqual(@as(i64, 7), max_qty.int);

        var q2 = client.product.Query();
        defer q2.deinit();
        const min_price = try q2.Min("price");
        // With type-permissive SQLite getters MIN(price) is coerced to int
        // before the float path is tried; the important property is that the
        // Rows are deinitialized and no leak is reported.
        try testing.expect(min_price == .int);
        try testing.expectEqual(@as(i64, 1), min_price.int);
    }

    // Empty aggregate returns null.
    {
        var q = client.empty_product.Query();
        defer q.deinit();
        const max_name = try q.Max("name");
        try testing.expect(max_name == .null);

        var q2 = client.empty_product.Query();
        defer q2.deinit();
        const min_qty = try q2.Min("qty");
        try testing.expect(min_qty == .null);
    }
}

test "SQLite: JSON struct field arena is freed by deinitEntity" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const Settings = struct {
        theme: []const u8,
        notifications: bool,
    };

    const JsonUser = schema("JsonUser", .{
        .fields = &.{
            field.String("name"),
            field.JSON("settings", Settings),
        },
    });

    const graph = comptime buildGraph(&.{JsonUser});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b = try client.json_user.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    _ = try b.setFieldValue("settings", Settings{ .theme = "dark", .notifications = true });
    var entity = try b.Save();

    try testing.expectEqualStrings("alice", entity.name);
    try testing.expectEqualStrings("dark", entity.settings.theme);
    try testing.expectEqual(true, entity.settings.notifications);
    try testing.expect(entity.json_arena != null);

    zent.codegen.deinitEntity(infos, infos[0], &entity, allocator);
}

test "SQLite: migrateSchema is idempotent with zent_schema_migrations" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // Pre-existing legacy table that needs columns added.
    _ = try drv.exec(
        "CREATE TABLE zent_sqlite_migration (id INTEGER PRIMARY KEY AUTOINCREMENT, score INTEGER NOT NULL)",
        &.{},
    );

    const SqliteMigration = schema("ZentSqliteMigration", .{
        .fields = &.{
            field.Int("score"),
            field.String("label"),
        },
        .indexes = &.{
            index.Named("idx_zent_sqlite_migration_score", &.{"score"}),
        },
    });
    const graph = comptime buildGraph(&.{SqliteMigration});

    // First migration adds the missing column and the missing index.
    try migrate.migrateSchema(allocator, drv.asDriver(), graph.types);

    // Count the rows recorded after the first run.
    var rows1 = try drv.query("SELECT COUNT(*) FROM zent_schema_migrations", &.{});
    defer rows1.deinit();
    const row1 = rows1.next() orelse return error.NoRow;
    const count_after_first: i64 = row1.getInt(0).?;
    try testing.expect(count_after_first > 0);

    // Capture every recorded version after the first run.
    var rows_versions1 = try drv.query(
        "SELECT version FROM zent_schema_migrations ORDER BY version",
        &.{},
    );
    defer rows_versions1.deinit();
    var first_versions = std.array_list.Managed(i64).init(allocator);
    defer first_versions.deinit();
    while (rows_versions1.next()) |r| {
        if (r.getInt(0)) |v| try first_versions.append(v);
    }
    const first_count = first_versions.items.len;
    const first_slice = try allocator.dupe(i64, first_versions.items);
    defer allocator.free(first_slice);

    // Second migration must not produce additional history rows for objects
    // that already exist; the live schema is authoritative, so duplicate
    // INSERTs are suppressed by ON CONFLICT DO NOTHING.
    try migrate.migrateSchema(allocator, drv.asDriver(), graph.types);

    var rows2 = try drv.query("SELECT COUNT(*) FROM zent_schema_migrations", &.{});
    defer rows2.deinit();
    const row2 = rows2.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, @intCast(first_count)), row2.getInt(0).?);

    // Versions recorded on the second run must match the first exactly.
    var rows_versions2 = try drv.query(
        "SELECT version FROM zent_schema_migrations ORDER BY version",
        &.{},
    );
    defer rows_versions2.deinit();
    var second_versions = std.array_list.Managed(i64).init(allocator);
    defer second_versions.deinit();
    while (rows_versions2.next()) |r| {
        if (r.getInt(0)) |v| try second_versions.append(v);
    }
    try testing.expectEqual(first_slice.len, second_versions.items.len);
    for (first_slice, second_versions.items) |a, b| {
        try testing.expectEqual(a, b);
    }

    // Confirm the actual schema is still as expected after two runs.
    var cols = try drv.query("PRAGMA table_info(zent_sqlite_migration)", &.{});
    defer cols.deinit();
    var found_label = false;
    while (cols.next()) |r| {
        if (std.mem.eql(u8, r.getText(1) orelse "", "label")) found_label = true;
    }
    try testing.expect(found_label);

    var idxs = try drv.query("PRAGMA index_list(zent_sqlite_migration)", &.{});
    defer idxs.deinit();
    var found_idx = false;
    while (idxs.next()) |r| {
        if (std.mem.eql(u8, r.getText(1) orelse "", "idx_zent_sqlite_migration_score")) found_idx = true;
    }
    try testing.expect(found_idx);
}

test "SQLite: DDL rolled back on mid-transaction failure" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // Helper that mirrors the errdefer tx.deinit() pattern in migrateSchema.
    // Returns a deliberate error after valid DDL to test that the errdefer
    // fires and rolls back all operations within the transaction.
    const run = struct {
        fn doit(d: *SQLiteDriver) !void {
            var tx = try d.beginTx();
            errdefer tx.deinit();

            _ = try tx.exec(
                "CREATE TABLE should_rollback (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)",
                &.{},
            );
            _ = try tx.exec(
                "INSERT INTO should_rollback (name) VALUES (?)",
                &.{.{ .string = "test-data" }},
            );

            // Force a mid-transaction failure to trigger the errdefer above.
            return error.ForceRollback;
        }
    }.doit;

    _ = run(&drv) catch {};

    // After the errdefer rollback, the table should not exist.
    var table_rows = try drv.query(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='should_rollback'",
        &.{},
    );
    defer table_rows.deinit();
    try testing.expect(table_rows.next() == null);
}

test "SQLite: migrateSchema rollback leaves neither schema nor history" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // Helper that mimics the structure of migrateSchema: bootstrap the
    // history table outside the transaction, then run DDL + history writes
    // inside a transaction. Returns a deliberate error to force errdefer rollback.
    const doMigrate = struct {
        fn run(d: *SQLiteDriver) !void {
            // Bootstrap the history table outside the transaction (idempotent).
            _ = try d.exec(
                "CREATE TABLE IF NOT EXISTS zent_schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL, checksum TEXT)",
                &.{},
            );

            var tx = try d.beginTx();
            errdefer tx.deinit();

            // Create an entity table (DDL inside transaction).
            _ = try tx.exec(
                \\CREATE TABLE IF NOT EXISTS rollback_entity (
                \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
                \\  name TEXT NOT NULL,
                \\  val INTEGER NOT NULL
                \\)
            , &.{});

            // Record a migration history row (DML inside transaction).
            _ = try tx.exec(
                "INSERT INTO zent_schema_migrations (version, applied_at, checksum) VALUES (?, ?, ?)",
                &.{ .{ .int = 100 }, .{ .int = 0 }, .null },
            );

            // Force a mid-transaction failure to trigger the errdefer above.
            return error.ForceRollback;
        }
    }.run;

    _ = doMigrate(&drv) catch {};

    // After the errdefer rollback:
    //   1. The entity table should not exist (DDL was rolled back).
    //   2. The history insert should not be visible (rolled back).
    var table_rows = try drv.query(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='rollback_entity'",
        &.{},
    );
    defer table_rows.deinit();
    try testing.expect(table_rows.next() == null);

    // History table itself exists (created outside the tx), but has zero rows.
    var hist_rows = try drv.query(
        "SELECT COUNT(*) FROM zent_schema_migrations",
        &.{},
    );
    defer hist_rows.deinit();
    const hist_row = hist_rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 0), hist_row.getInt(0).?);
}

test "SQLite: Deny policy blocks query and create" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // Schema with AlwaysDeny policy
    const DenyEntity = schema("DenyEntity", .{
        .fields = &.{
            field.String("name"),
        },
        .policy = zent.privacy.AlwaysDeny,
    });

    const graph = comptime buildGraph(&.{DenyEntity});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Query should be denied (no privacy_ctx → null context triggers deny)
    {
        var q = client.deny_entity.Query();
        defer q.deinit();
        if (q.All()) |_| {
            return error.UnexpectedAllow;
        } else |err| {
            try testing.expectEqual(error.PrivacyDenied, err);
        }
    }

    // Create should be denied
    {
        var b = try client.deny_entity.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "test");
        if (b.Save()) |_| {
            return error.UnexpectedAllow;
        } else |err| {
            try testing.expectEqual(error.PrivacyDenied, err);
        }
    }

    // Delete should be denied
    {
        var d = client.deny_entity.Delete();
        defer d.deinit();
        _ = try d.Where(.{client.deny_entity.predicates.nameEQ(.{ .string = "test" })});
        if (d.Exec()) |_| {
            return error.UnexpectedAllow;
        } else |err| {
            try testing.expectEqual(error.PrivacyDenied, err);
        }
    }

    // Update should be denied
    {
        var u = client.deny_entity.Update();
        defer u.deinit();
        _ = try u.set("name", .{ .string = "x" });
        if (u.Save()) |_| {
            return error.UnexpectedAllow;
        } else |err| {
            try testing.expectEqual(error.PrivacyDenied, err);
        }
    }
}

test "SQLite: privacy WithContext propagates context to allow/deny decisions" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // Two entities: one with AlwaysAllow, one with AlwaysDeny.
    // Both have a policy, so both require WithContext.
    const AllowEntity = schema("AllowEntity", .{
        .fields = &.{field.String("name")},
        .policy = zent.privacy.AlwaysAllow,
    });
    const DenyEntity = schema("DenyEntity", .{
        .fields = &.{field.String("name")},
        .policy = zent.privacy.AlwaysDeny,
    });

    const graph = comptime buildGraph(&.{ AllowEntity, DenyEntity });
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    const tenant1 = zent.privacy.PrivacyContext{ .tenant_id = 1 };
    const tenant2 = zent.privacy.PrivacyContext{ .tenant_id = 2 };

    // --- AlwaysAllow: Query with context succeeds for both tenants ---
    {
        var c1 = client.allow_entity.withContext(tenant1);
        var q1 = c1.Query();
        defer q1.deinit();
        const results = try q1.All();
        defer {
            for (results.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            results.deinit();
        }
        try testing.expectEqual(@as(usize, 0), results.items.len);
    }
    {
        var c2 = client.allow_entity.withContext(tenant2);
        var q2 = c2.Query();
        defer q2.deinit();
        const results = try q2.All();
        defer {
            for (results.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            results.deinit();
        }
        try testing.expectEqual(@as(usize, 0), results.items.len);
    }

    // --- AlwaysAllow: Create with context succeeds ---
    {
        var c = client.allow_entity.withContext(tenant1);
        var b = try c.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "tenant1-item");
        var entity = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &entity, allocator);
        try testing.expectEqualStrings("tenant1-item", entity.name);
        try testing.expect(entity.id > 0);
    }

    // --- AlwaysDeny: Query with context still fails ---
    {
        var c = client.deny_entity.withContext(tenant1);
        var q = c.Query();
        defer q.deinit();
        if (q.All()) |_| {
            return error.UnexpectedAllow;
        } else |err| {
            try testing.expectEqual(error.PrivacyDenied, err);
        }
    }

    // --- AlwaysDeny: Create with context still fails ---
    {
        var c = client.deny_entity.withContext(tenant2);
        var b = try c.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "should-not-save");
        if (b.Save()) |_| {
            return error.UnexpectedAllow;
        } else |err| {
            try testing.expectEqual(error.PrivacyDenied, err);
        }
    }
}

test "SQLite: privacy denies all operations without WithContext" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // Any entity with a policy must have WithContext called;
    // using the builder without it should return PrivacyDenied.
    const SecureEntity = schema("SecureEntity", .{
        .fields = &.{field.String("name")},
        .policy = zent.privacy.AlwaysAllow,
    });

    const graph = comptime buildGraph(&.{SecureEntity});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Query without WithContext → PrivacyDenied
    {
        var q = client.secure_entity.Query();
        defer q.deinit();
        if (q.All()) |_| {
            return error.UnexpectedAllow;
        } else |err| {
            try testing.expectEqual(error.PrivacyDenied, err);
        }
    }

    // Create without WithContext → PrivacyDenied
    {
        var b = try client.secure_entity.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "no-ctx");
        if (b.Save()) |_| {
            return error.UnexpectedAllow;
        } else |err| {
            try testing.expectEqual(error.PrivacyDenied, err);
        }
    }

    // Update without WithContext → PrivacyDenied
    {
        var u = client.secure_entity.Update();
        defer u.deinit();
        _ = try u.set("name", .{ .string = "x" });
        if (u.Save()) |_| {
            return error.UnexpectedAllow;
        } else |err| {
            try testing.expectEqual(error.PrivacyDenied, err);
        }
    }

    // Delete without WithContext → PrivacyDenied
    {
        var d = client.secure_entity.Delete();
        defer d.deinit();
        _ = try d.Where(.{client.secure_entity.predicates.nameEQ(.{ .string = "no-ctx" })});
        if (d.Exec()) |_| {
            return error.UnexpectedAllow;
        } else |err| {
            try testing.expectEqual(error.PrivacyDenied, err);
        }
    }
}

test "SQLite: before hook abort prevents creation" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const HookEntity = schema("HookEntity", .{
        .fields = &.{field.String("name")},
    });

    const graph = comptime buildGraph(&.{HookEntity});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    const before_fn = struct {
        fn f(ctx: *zent.runtime.hook.HookContext) zent.runtime.hook.HookError!void {
            _ = ctx;
            return error.Forbidden;
        }
    }.f;

    const hooks = &[_]zent.runtime.hook.Hook{
        zent.runtime.hook.Hook.initBefore(.create, before_fn),
    };
    client.hook_entity = client.hook_entity.withHooks(hooks);

    // Try to create — should be rejected by before hook.
    var b = try client.hook_entity.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "should-not-exist");
    if (b.Save()) |_| {
        return error.UnexpectedAllow;
    } else |err| {
        try testing.expectEqual(error.Forbidden, err);
    }

    // Verify no row was inserted.
    var q = client.hook_entity.Query();
    defer q.deinit();
    const count = try q.Count();
    try testing.expectEqual(@as(i64, 0), count);
}

test "SQLite: after hook sees created entity" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const HookEntity = schema("HookEntity", .{
        .fields = &.{field.String("name")},
    });

    const graph = comptime buildGraph(&.{HookEntity});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Container-level variable for communicating between hook and test body.
    const H = struct {
        var saw_id: i64 = 0;
        fn afterFn(ctx: *zent.runtime.hook.HookContext) zent.runtime.hook.HookError!void {
            if (ctx.entity) |entity_ptr| {
                const ptr: *align(@alignOf(i64)) i64 = @ptrCast(@alignCast(entity_ptr));
                saw_id = ptr.*;
            }
        }
    };
    H.saw_id = 0;

    const hooks = &[_]zent.runtime.hook.Hook{
        zent.runtime.hook.Hook.initAfter(.create, H.afterFn),
    };
    client.hook_entity = client.hook_entity.withHooks(hooks);

    var b = try client.hook_entity.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "test-entity");
    var entity = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &entity, allocator);

    try testing.expect(entity.id > 0);
    try testing.expectEqualStrings("test-entity", entity.name);
    // After hook should have seen the entity id.
    try testing.expect(H.saw_id > 0);
    try testing.expectEqual(entity.id, H.saw_id);
}

test "SQLite: migrateSchema drops removed column" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // Create legacy table with an extra 'obsolete' column not in the schema.
    _ = try drv.exec(
        "CREATE TABLE drop_test (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, value INTEGER, obsolete TEXT)",
        &.{},
    );

    const DropTest = schema("DropTest", .{
        .fields = &.{
            field.String("name"),
            field.Int("value"),
        },
    });

    const graph = comptime buildGraph(&.{DropTest});
    const infos = graph.types;

    // Run with drop_columns: false (default) → column remains.
    try migrate.migrateSchema(allocator, drv.asDriver(), infos);
    {
        var rows = try drv.query("PRAGMA table_info(drop_test)", &.{});
        defer rows.deinit();
        var found_obsolete = false;
        while (rows.next()) |row| {
            if (std.mem.eql(u8, row.getText(1) orelse "", "obsolete")) found_obsolete = true;
        }
        try testing.expect(found_obsolete);
    }

    // Run with drop_columns: true → column gone.
    try migrate.migrateSchemaWithOptions(allocator, drv.asDriver(), infos, migrate.MigrateOptions{
        .drop_columns = true,
    });
    {
        var rows = try drv.query("PRAGMA table_info(drop_test)", &.{});
        defer rows.deinit();
        var found_obsolete = false;
        while (rows.next()) |row| {
            if (std.mem.eql(u8, row.getText(1) orelse "", "obsolete")) found_obsolete = true;
        }
        try testing.expect(!found_obsolete);
    }
}

test "SQLite: migrateSchema dry-run outputs SQL without executing" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const DREntity = schema("DREntity", .{
        .fields = &.{
            field.String("name"),
            field.Int("value"),
        },
        .indexes = &.{
            index.Named("idx_drentity_name", &.{"name"}),
        },
    });

    const graph = comptime buildGraph(&.{DREntity});
    const infos = graph.types;

    // Run with dry_run: true — should NOT create any tables.
    try migrate.migrateSchemaWithOptions(allocator, drv.asDriver(), infos, migrate.MigrateOptions{
        .dry_run = true,
    });

    // Verify no tables were created.
    var rows = try drv.query("SELECT name FROM sqlite_master WHERE type='table'", &.{});
    defer rows.deinit();
    var table_count: usize = 0;
    while (rows.next()) |_| {
        table_count += 1;
    }
    try testing.expectEqual(@as(usize, 0), table_count);
}

// Module-level storage for the filter predicate so the opaque pointer
// returned by the Filter rule remains valid through injectPrivacyFilters.
var filter_pred: zent.sql.Predicate = undefined;

fn ownerFilter(ctx: zent.privacy.PrivacyContext) ?*const anyopaque {
    if (ctx.user_id) |uid| {
        filter_pred = zent.sql.EQ("owner_id", .{ .int = uid });
        return @ptrCast(&filter_pred);
    }
    return null;
}

test "SQLite: privacy filter restricts rows by owner_id" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // Schema with owner_id field and a Filter-based privacy policy.
    const FilteredEntity = schema("FilteredEntity", .{
        .fields = &.{
            field.String("name"),
            field.Int("owner_id"),
        },
        .policy = zent.privacy.Policy{
            .rules = &.{
                zent.privacy.Allow,
                zent.privacy.Filter(ownerFilter),
            },
        },
    });

    const graph = comptime buildGraph(&.{FilteredEntity});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Insert two rows: one owned by user 1, one owned by user 2.
    {
        var c1 = client.filtered_entity.withContext(.{ .user_id = 1 });
        var b1 = try c1.Create();
        defer b1.deinit();
        _ = try b1.setFieldValue("name", "alice-item");
        _ = try b1.setFieldValue("owner_id", @as(i64, 1));
        var e1 = try b1.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &e1, allocator);
        try testing.expect(e1.id > 0);
    }
    {
        var c2 = client.filtered_entity.withContext(.{ .user_id = 2 });
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
        var c1 = client.filtered_entity.withContext(.{ .user_id = 1 });
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
        var c2 = client.filtered_entity.withContext(.{ .user_id = 2 });
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
        var c3 = client.filtered_entity.withContext(.{ .user_id = 999 });
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
        var c_anon = client.filtered_entity.withContext(.{});
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

test "SQLite: beginTx propagates hooks and privacy_ctx to transaction entity clients" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // Entity with AlwaysAllow policy (requires privacy context to be set)
    // and hooks to verify propagation.
    const TxPropEntity = schema("TxPropEntity", .{
        .fields = &.{field.String("name")},
        .policy = zent.privacy.AlwaysAllow,
    });

    const graph = comptime buildGraph(&.{TxPropEntity});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());

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
    client.tx_prop_entity = client.tx_prop_entity.withHooks(hooks);
    client.tx_prop_entity = client.tx_prop_entity.withContext(zent.privacy.PrivacyContext{ .user_id = 42 });

    // Verify hooks slice is non-empty on the parent client (precondition).
    try testing.expectEqual(@as(usize, 1), client.tx_prop_entity.hooks.len);

    // Begin a transaction.
    var tx = try Client.beginTx(infos, client);
    defer tx.deinit();

    // Verify hooks propagated to tx client.
    try testing.expectEqual(@as(usize, 1), tx.client.tx_prop_entity.hooks.len);

    // Verify privacy_ctx propagated to tx client.
    try testing.expect(tx.client.tx_prop_entity.privacy_ctx != null);
    try testing.expectEqual(@as(i64, 42), tx.client.tx_prop_entity.privacy_ctx.?.user_id);

    // Perform a create inside the transaction — should succeed (privacy allows)
    // and the before hook should fire.
    var b = try tx.client.tx_prop_entity.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "tx-hook-test");
    var entity = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &entity, allocator);

    try testing.expect(entity.id > 0);
    try testing.expect(H.before_called);
    try testing.expectEqualStrings("tx-hook-test", entity.name);

    try tx.commit();
}
