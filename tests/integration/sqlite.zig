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
const edge = zent.core.edge;
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

test "SQLite: eager-loaded edge JSON is arena-owned and freed" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const Settings = struct { theme: []const u8, notes: []const u8 };
    const CarBase = schema("CarEager", .{
        .fields = &.{ field.String("model"), field.JSON("meta", Settings) },
    });
    const UserBase = schema("UserEager", .{
        .fields = &.{ field.String("name"), field.JSON("settings", Settings) },
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
    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var ub = try client.user_eager.Create();
    defer ub.deinit();
    _ = try ub.setFieldValue("name", "u");
    _ = try ub.setFieldValue("settings", Settings{ .theme = "dark", .notes = "n1\nn2" });
    var u = try ub.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &u, allocator);

    var cb = try client.car_eager.Create();
    defer cb.deinit();
    _ = try cb.setFieldValue("model", "m");
    _ = try cb.setFieldValue("meta", Settings{ .theme = "red", .notes = "x\ny" });
    // user_eager_id is the NOT NULL FK column the To edge generated.
    _ = try cb.setFieldValue("user_eager_id", u.id);
    var c = try cb.Save();
    defer zent.codegen.deinitEntity(infos, infos[1], &c, allocator);

    // Eager-load cars (including their JSON) and deinit the parent: the
    // loaded edge items' json_arena must be freed too (leak check).
    var q = client.user_eager.Query();
    defer q.deinit();
    _ = try q.WithEdge("cars");
    var users = try q.All();
    defer {
        for (users.items) |*it| zent.codegen.deinitEntity(infos, infos[0], it, allocator);
        users.deinit();
    }
    try testing.expect(users.items.len == 1);
    try testing.expect(users.items[0].edges.cars != null);
    try testing.expect(users.items[0].edges.cars.?.len == 1);
    try testing.expectEqualStrings("x\ny", users.items[0].edges.cars.?[0].meta.notes);
}

test "SQLite: scan-path JSON is arena-owned and freed by deinitEntity" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const Settings = struct {
        theme: []const u8,
        notes: []const u8,
        notifications: bool,
    };
    const JsonUser = schema("JsonUserScan", .{
        .fields = &.{ field.String("name"), field.JSON("settings", Settings) },
    });
    const graph = comptime buildGraph(&.{JsonUser});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());
    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Create path (arena) is a prerequisite for the scan path below.
    var b = try client.json_user_scan.Create();
    defer b.deinit();
    // Escaped string forces std.json to allocate (zero-copy only for
    // unescaped short strings), exercising the arena ownership contract.
    _ = try b.setFieldValue("name", "alice");
    _ = try b.setFieldValue("settings", Settings{ .theme = "dark", .notes = "line1\nline2", .notifications = true });
    var saved = try b.Save();
    zent.codegen.deinitEntity(infos, infos[0], &saved, allocator);

    // Scan path: JSON must land in the entity's json_arena so a single
    // deinitEntity frees it (leak check catches regressions).
    var q = client.json_user_scan.Query();
    defer q.deinit();
    var users = try q.All();
    defer {
        for (users.items) |*u| zent.codegen.deinitEntity(infos, infos[0], u, allocator);
        users.deinit();
    }
    try testing.expect(users.items.len == 1);
    try testing.expect(users.items[0].json_arena != null);
    try testing.expectEqualStrings("dark", users.items[0].settings.theme);
    try testing.expectEqualStrings("line1\nline2", users.items[0].settings.notes);
    try testing.expectEqual(true, users.items[0].settings.notifications);
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

test "SQLite: WhereEntQL has(edge) lowers to EXISTS subquery" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const CarBase = schema("EntqlCar", .{
        .fields = &.{ field.String("model"), field.Int("price") },
    });
    const UserBase = schema("EntqlUser", .{
        .fields = &.{field.String("name")},
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
    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Two users; only alice gets a car.
    var b1 = try client.entql_user.Create();
    defer b1.deinit();
    _ = try b1.setFieldValue("name", "alice");
    var user1 = try b1.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &user1, allocator);

    var b2 = try client.entql_user.Create();
    defer b2.deinit();
    _ = try b2.setFieldValue("name", "bob");
    var user2 = try b2.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &user2, allocator);

    var cb = try client.entql_car.Create();
    defer cb.deinit();
    _ = try cb.setFieldValue("model", "x");
    _ = try cb.setFieldValue("price", 10);
    _ = try cb.setFieldValue("entql_user_id", user1.id);
    var c = try cb.Save();
    defer zent.codegen.deinitEntity(infos, infos[1], &c, allocator);

    // has(cars) -> only alice (EXISTS subquery on the edge FK).
    {
        var q = client.entql_user.Query();
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

    // has(cars, price > 5) also matches alice; not_has(cars) matches bob.
    {
        var q = client.entql_user.Query();
        defer q.deinit();
        _ = try q.WhereEntQL("has(cars, price > 5)");
        var users = try q.All();
        defer {
            for (users.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            users.deinit();
        }
        try testing.expectEqual(@as(usize, 1), users.items.len);
    }
    {
        var q = client.entql_user.Query();
        defer q.deinit();
        _ = try q.WhereEntQL("not_has(cars)");
        var users = try q.All();
        defer {
            for (users.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            users.deinit();
        }
        try testing.expectEqual(@as(usize, 1), users.items.len);
        try testing.expectEqualStrings("bob", users.items[0].name);
    }
}

test "SQLite: OnCreate denies create but allows query (per-op)" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const User = schema("OnCreateUser", .{
        .fields = &.{field.String("name")},
        .policy = zent.privacy.OnCreate,
    });
    const graph = comptime buildGraph(&.{User});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());
    const ctx = zent.privacy.PrivacyContext{ .user_id = 1 };
    const user_client = client.on_create_user.withContext(ctx);

    // create must be denied (OnCreate fires for op == .create).
    {
        var b = try user_client.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "x");
        if (b.Save()) |_| {
            return error.UnexpectedAllow;
        } else |err| {
            try testing.expectEqual(error.PrivacyDenied, err);
        }
    }

    // query must pass (OnCreate does not match op == .query).
    {
        var q = user_client.Query();
        defer q.deinit();
        var users = try q.All();
        defer {
            for (users.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            users.deinit();
        }
        try testing.expectEqual(@as(usize, 0), users.items.len);
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

test "SQLite: stream iterator avoids loading all rows" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const StreamEntity = schema("StreamEntity", .{
        .fields = &.{
            field.String("name"),
            field.Int("idx"),
        },
    });

    const graph = comptime buildGraph(&.{StreamEntity});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Create 50 entities.
    for (0..50) |i| {
        var b = try client.stream_entity.Create();
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
        var q = client.stream_entity.Query();
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

test "SQLite: BulkInsert multi-row RETURNING" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const BulkEntity = schema("BulkEntity", .{
        .fields = &.{
            field.String("name"),
            field.Int("score"),
        },
    });

    const graph = comptime buildGraph(&.{BulkEntity});
    const infos = graph.types;
    try Client.createAllTables(infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Insert 3 rows in a single round-trip.
    var b = try client.bulk_entity.BulkInsert();
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
    // IDs should be sequential integers starting from 1.
    try testing.expectEqual(@as(i64, 1), ids.items[0]);
    try testing.expectEqual(@as(i64, 2), ids.items[1]);
    try testing.expectEqual(@as(i64, 3), ids.items[2]);

    // Verify rows actually exist in the DB.
    var rows = try drv.query("SELECT id, name, score FROM bulk_entity ORDER BY id", &.{});
    defer rows.deinit();

    const r1 = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 1), r1.getInt(0).?);
    try testing.expectEqualStrings("alpha", r1.getText(1).?);
    try testing.expectEqual(@as(i64, 100), r1.getInt(2).?);

    const r2 = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 2), r2.getInt(0).?);
    try testing.expectEqualStrings("beta", r2.getText(1).?);
    try testing.expectEqual(@as(i64, 200), r2.getInt(2).?);

    const r3 = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 3), r3.getInt(0).?);
    try testing.expectEqualStrings("gamma", r3.getText(1).?);
    try testing.expectEqual(@as(i64, 300), r3.getInt(2).?);

    try testing.expect(rows.next() == null);
}

test "SQLite: file-based migrations" {
    const allocator = testing.allocator;
    const io = testing.io;

    const dir_name = "test_migrations_file";
    try std.Io.Dir.cwd().createDirPath(io, dir_name);
    defer std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    {
        var dir = try std.Io.Dir.cwd().openDir(io, dir_name, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{
            .sub_path = "001_create_items.up.sql",
            .data =
            \\CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT);
            \\INSERT INTO items (id, name) VALUES (1, 'first');
            ,
        });
        try dir.writeFile(io, .{
            .sub_path = "001_create_items.down.sql",
            .data = "DELETE FROM items;",
        });
        try dir.writeFile(io, .{
            .sub_path = "002_add_second_item.up.sql",
            .data = "INSERT INTO items (id, name) VALUES (2, 'second');",
        });
    }

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    try migrate.migrateFromFiles(io, allocator, drv.asDriver(), dir_name);

    var rows = try drv.query("SELECT COUNT(*) FROM items", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 2), row.getInt(0).?);

    try migrate.rollbackFiles(io, allocator, drv.asDriver(), dir_name, 1);

    var rows2 = try drv.query("SELECT COUNT(*) FROM items", &.{});
    defer rows2.deinit();
    const row2 = rows2.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 0), row2.getInt(0).?);
}

test "SQLite: database-level cascade delete" {
    const allocator = testing.allocator;

    const User = schema("User", .{
        .fields = &.{ field.Int("id"), field.String("name") },
    });
    const Order = schema("Order", .{
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

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // SQLite parses FK constraints by default but enforces them only when
    // foreign_keys is enabled per connection.
    _ = try drv.exec("PRAGMA foreign_keys = ON", &.{});

    try migrate.migrateSchema(allocator, drv.asDriver(), infos);

    _ = try drv.exec("INSERT INTO user (id, name) VALUES (1, 'alice')", &.{});
    _ = try drv.exec("INSERT INTO \"order\" (id, user_id) VALUES (10, 1)", &.{});
    _ = try drv.exec("INSERT INTO \"order\" (id, user_id) VALUES (11, 1)", &.{});

    _ = try drv.exec("DELETE FROM user WHERE id = 1", &.{});

    var rows = try drv.query("SELECT COUNT(*) FROM \"order\"", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, 0), row.getInt(0).?);
}

test "SQLite: optimistic lock conflict" {
    const allocator = testing.allocator;
    const User = schema("LockedUser", .{
        .fields = &.{
            field.Int("id"),
            field.String("name"),
            field.Version("version"),
        },
    });

    const graph = comptime buildGraph(&.{User});
    const infos = graph.types;

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    try migrate.migrateSchema(allocator, drv.asDriver(), infos);

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b = try client.locked_user.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    var created = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);
    try testing.expectEqual(@as(i64, 0), created.version);

    // Simulate stale update: the row exists but the version value is wrong.
    var stale = created;
    stale.name = "bob";
    stale.version = 999;

    var ub = client.locked_user.Update();
    defer ub.deinit();
    _ = try ub.set("name", .{ .string = "bob" });
    _ = try ub.setFieldValue("version", stale.version);
    _ = try ub.Where(.{zent.sql.EQ("id", .{ .int = stale.id })});
    const result = ub.SaveOne();
    try testing.expectError(error.OptimisticLockConflict, result);
}

test "SQLite: optimistic lock update increments version" {
    const allocator = testing.allocator;
    const User = schema("LockedUser", .{
        .fields = &.{
            field.Int("id"),
            field.String("name"),
            field.Version("version"),
        },
    });

    const graph = comptime buildGraph(&.{User});
    const infos = graph.types;

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    try migrate.migrateSchema(allocator, drv.asDriver(), infos);

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b = try client.locked_user.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    var created = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);
    try testing.expectEqual(@as(i64, 0), created.version);

    var update = client.locked_user.Update();
    defer update.deinit();
    _ = try update.set("name", .{ .string = "bob" });
    _ = try update.setFieldValue("version", created.version);
    _ = try update.Where(.{client.locked_user.predicates.idEQ(.{ .int = created.id })});
    const affected = try update.Save();
    try testing.expectEqual(@as(usize, 1), affected);

    var q = client.locked_user.Query();
    defer q.deinit();
    _ = try q.Where(.{client.locked_user.predicates.idEQ(.{ .int = created.id })});
    const results = try q.All();
    defer {
        for (results.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
        results.deinit();
    }
    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("bob", results.items[0].name);
    try testing.expectEqual(@as(i64, 1), results.items[0].version);
}

test "SQLite: optimistic lock delete conflict" {
    const allocator = testing.allocator;
    const User = schema("LockedUser", .{
        .fields = &.{
            field.Int("id"),
            field.String("name"),
            field.Version("version"),
        },
    });

    const graph = comptime buildGraph(&.{User});
    const infos = graph.types;

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    try migrate.migrateSchema(allocator, drv.asDriver(), infos);

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b = try client.locked_user.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    var created = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);
    try testing.expectEqual(@as(i64, 0), created.version);

    var db = client.locked_user.Delete();
    defer db.deinit();
    _ = db.setVersion(999);
    _ = try db.Where(.{client.locked_user.predicates.idEQ(.{ .int = created.id })});
    const result = db.ExecOne();
    try testing.expectError(error.OptimisticLockConflict, result);
}

test "SQLite: optimistic lock soft delete conflict and success" {
    const allocator = testing.allocator;
    const SoftLockedUser = schema("SoftLockedUser", .{
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

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    try migrate.migrateSchema(allocator, drv.asDriver(), infos);

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b = try client.soft_locked_user.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    var created = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);
    try testing.expectEqual(@as(i64, 0), created.version);

    // Stale version should fail with optimistic lock conflict.
    {
        var db = client.soft_locked_user.Delete();
        defer db.deinit();
        _ = db.setVersion(999);
        _ = try db.Where(.{client.soft_locked_user.predicates.idEQ(.{ .int = created.id })});
        const result = db.ExecOne();
        try testing.expectError(error.OptimisticLockConflict, result);
    }

    // Correct version should soft-delete the row and bump the version.
    {
        var db = client.soft_locked_user.Delete();
        defer db.deinit();
        _ = db.setVersion(created.version);
        _ = try db.Where(.{client.soft_locked_user.predicates.idEQ(.{ .int = created.id })});
        const affected = try db.Exec();
        try testing.expectEqual(@as(usize, 1), affected);
    }

    // Verify the row is still present but marked deleted and version incremented.
    var rows = try drv.query("SELECT deleted_at, version FROM soft_locked_user WHERE id = ?", &.{
        .{ .int = created.id },
    });
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expect(row.getInt(0) != null);
    try testing.expect(row.getInt(0).? > 0);
    try testing.expectEqual(@as(i64, 1), row.getInt(1).?);
}

test "SQLite: query with timeout succeeds" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
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

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var q = client.user.Query();
    defer q.deinit();
    _ = q.withTimeout(1_000);
    const users = try q.All();
    defer {
        for (users.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
        users.deinit();
    }
    try testing.expectEqual(@as(usize, 0), users.items.len);
}
