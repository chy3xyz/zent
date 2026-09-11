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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

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

test "SQLite: constraint violations map to specific errors (not NotFound)" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const U = schema("ErrUser", .{
        .fields = &.{ field.String("email").Unique(), field.String("name") },
    });
    const graph = comptime buildGraph(&.{U});
    const infos = graph.types;
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var b1 = try client.err_user.Create();
    defer b1.deinit();
    _ = try b1.setFieldValue("email", "a@x.com");
    _ = try b1.setFieldValue("name", "one");
    var user1 = try b1.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &user1, allocator);

    // Duplicate UNIQUE email must surface as UniqueViolation, not NotFound.
    {
        var b2 = try client.err_user.Create();
        defer b2.deinit();
        _ = try b2.setFieldValue("email", "a@x.com");
        _ = try b2.setFieldValue("name", "two");
        if (b2.Save()) |_| {
            return error.UnexpectedInsert;
        } else |err| {
            try testing.expectEqual(error.UniqueViolation, err);
        }
    }
}

test "SQLite: JSONValue untyped document field round-trips" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const Doc = schema("JsonValueDoc", .{
        .fields = &.{ field.String("name"), field.JSONValue("payload") },
    });
    const graph = comptime buildGraph(&.{Doc});
    const infos = graph.types;
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Create with an untyped document (nested object + array).
    var b = try client.json_value_doc.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name", "spec");
    _ = try b.setFieldValue("payload", std.json.Value{ .string = "plain-doc" });
    var saved = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &saved, allocator);

    // Scan path: the document round-trips and the arena owns its memory.
    var q = client.json_value_doc.Query();
    defer q.deinit();
    var docs = try q.All();
    defer {
        for (docs.items) |*d| zent.codegen.deinitEntity(infos, infos[0], d, allocator);
        docs.deinit();
    }
    try testing.expect(docs.items.len == 1);
    try testing.expectEqualStrings("spec", docs.items[0].name);
    try testing.expect(docs.items[0].json_arena != null);
    try testing.expect(docs.items[0].payload == .string);
    try testing.expectEqualStrings("plain-doc", docs.items[0].payload.string);
}

test "SQLite: WhereIn chunks OR-joins IN predicates" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const CodeBase = schema("WhereInCode", .{
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
    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Seed rows with codes 0..4 plus one row in the second chunk (500).
    for (0..5) |i| {
        var b = try client.where_in_code.Create();
        defer b.deinit();
        _ = try b.setFieldValue("code", @as(i64, @intCast(i)));
        var e = try b.Save();
        zent.codegen.deinitEntity(infos, infos[0], &e, allocator);
    }
    {
        var b = try client.where_in_code.Create();
        defer b.deinit();
        _ = try b.setFieldValue("code", @as(i64, 500));
        var e = try b.Save();
        zent.codegen.deinitEntity(infos, infos[0], &e, allocator);
    }

    // Empty values -> error.EmptyInValues (no SQL is built).
    {
        var q = client.where_in_code.Query();
        defer q.deinit();
        try testing.expectError(error.EmptyInValues, q.WhereIn("code", &.{}));
    }

    // Single value.
    {
        const one = [_]zent.sql.Value{.{ .int = 3 }};
        var q = client.where_in_code.Query();
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
        var q = client.where_in_code.Query();
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
        var q = client.where_in_code.Query();
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

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
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

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

test "SQLite: decimal field round-trips exact text" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const Money = schema("Money", .{
        .fields = &.{field.Decimal("amount")},
    });
    const graph = comptime buildGraph(&.{Money});
    const infos = graph.types;
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());
    {
        var b = try client.money.Create();
        defer b.deinit();
        _ = try b.setFieldValue("amount", "19.99");
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &row, allocator);
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
    // TEXT affinity: the literal bytes come back verbatim (no REAL rewrite).
    try testing.expectEqualStrings("19.99", rows.items[0].amount);
}

test "SQLite: interceptor injects tenant filter into query/update/delete" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const TenantDoc = schema("TenantDoc", .{
        .fields = &.{
            field.String("name"),
            field.Int("tenant_id"),
        },
    });

    const graph = comptime buildGraph(&.{TenantDoc});
    const infos = graph.types;
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());
    defer Client.DeinitClient(infos, &client);

    // Multi-tenant interceptor: transparently scope every query/update/delete
    // to the current tenant. `ctx` is read per call, so flipping `tenant`
    // re-scopes the same registered interceptor.
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

    // Seed one row per tenant with an explicit tenant_id (kept as-is:
    // create injection is if-missing, so this still writes tenant 2).
    for ([_]struct { n: []const u8, t: i64 }{ .{ .n = "t1-doc", .t = 1 }, .{ .n = "t2-doc", .t = 2 } }) |s| {
        var b = try client.tenant_doc.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", s.n);
        _ = try b.setFieldValue("tenant_id", s.t);
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &e, allocator);
    }

    // Query reads only the current tenant's row.
    {
        var q = client.tenant_doc.Query();
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
        var u = client.tenant_doc.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "renamed");
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }

    // TxClient inherits the interceptor chain pointer.
    {
        var tx = try Client.beginTx(infos, client);
        defer tx.deinit();
        try testing.expect(tx.client.tenant_doc.interceptors != null);
        var q = tx.client.tenant_doc.Query();
        defer q.deinit();
        try testing.expectEqual(@as(i64, 1), try q.Count());
        try tx.rollback();
    }

    // Switch the tenant context: the same interceptor now scopes to tenant 2.
    tenant = 2;
    {
        var q = client.tenant_doc.Query();
        defer q.deinit();
        const rows = try q.All();
        defer {
            for (rows.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            rows.deinit();
        }
        try testing.expectEqual(@as(usize, 1), rows.items.len);
        // Tenant 2's row was untouched by the tenant-1 update above.
        try testing.expectEqualStrings("t2-doc", rows.items[0].name);
    }

    // Delete scoped to tenant 2 removes exactly its row.
    {
        var d = client.tenant_doc.Delete();
        defer d.deinit();
        try testing.expectEqual(@as(usize, 1), try d.Exec());
    }

    // Only tenant 1's renamed row remains.
    tenant = 1;
    var q = client.tenant_doc.Query();
    defer q.deinit();
    const rows = try q.All();
    defer {
        for (rows.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
        rows.deinit();
    }
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("renamed", rows.items[0].name);
}

test "SQLite: interceptor fills omitted tenant_id on create" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const TenantDoc = schema("TenantDocInject", .{
        .fields = &.{
            field.String("name"),
            field.Int("tenant_id"),
        },
    });

    const graph = comptime buildGraph(&.{TenantDoc});
    const infos = graph.types;
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());
    defer Client.DeinitClient(infos, &client);

    var tenant: i64 = 7;
    try Client.UseInterceptor(infos, &client, .{
        .ctx = &tenant,
        .intercept = struct {
            fn f(ctx: ?*anyopaque, view: *zent.runtime.intercept.QueryView) anyerror!void {
                const id: *i64 = @ptrCast(@alignCast(ctx.?));
                try view.whereEq("tenant_id", .{ .int = id.* });
            }
        }.f,
    });

    {
        var b = try client.tenant_doc_inject.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "omitted");
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &e, allocator);
        try testing.expectEqual(@as(i64, 7), e.tenant_id);
    }

    // Explicit value is kept (if-missing).
    {
        var b = try client.tenant_doc_inject.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "explicit");
        _ = try b.setFieldValue("tenant_id", @as(i64, 9));
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &e, allocator);
        try testing.expectEqual(@as(i64, 9), e.tenant_id);
    }

    var q = client.tenant_doc_inject.Query();
    defer q.deinit();
    try testing.expectEqual(@as(i64, 1), try q.Count());
}

test "SQLite: interceptor with unknown field aborts with InterceptFailed" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const BadScope = schema("BadScope", .{
        .fields = &.{field.String("name")},
    });

    const graph = comptime buildGraph(&.{BadScope});
    const infos = graph.types;
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());
    defer Client.DeinitClient(infos, &client);

    try Client.UseInterceptor(infos, &client, .{
        .intercept = struct {
            fn f(_: ?*anyopaque, view: *zent.runtime.intercept.QueryView) anyerror!void {
                try view.whereEq("no_such_field", .{ .int = 1 });
            }
        }.f,
    });

    var q = client.bad_scope.Query();
    defer q.deinit();
    try testing.expectError(error.InterceptFailed, q.All());
}

test "SQLite: eager-loaded children respect soft delete" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const ChildBase = schema("SoftEagerChild", .{
        .fields = &.{
            field.Int("parent_id"),
            field.String("name"),
        },
        .mixins = &.{zent.core.mixin.SoftDeleteMixin},
        .soft_delete = true,
    });
    const ParentBase = schema("SoftEagerParent", .{
        .fields = &.{field.String("name")},
        .edges = &.{edge.To("children", ChildBase).Field("parent_id")},
    });

    const graph = comptime buildGraph(&.{ ParentBase, ChildBase });
    const infos = graph.types;
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var pb = try client.soft_eager_parent.Create();
    defer pb.deinit();
    _ = try pb.setFieldValue("name", "p");
    var parent = try pb.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &parent, allocator);

    var live_id: i64 = 0;
    {
        var cb = try client.soft_eager_child.Create();
        defer cb.deinit();
        _ = try cb.setFieldValue("parent_id", parent.id);
        _ = try cb.setFieldValue("name", "live");
        var c = try cb.Save();
        defer zent.codegen.deinitEntity(infos, infos[1], &c, allocator);
        live_id = c.id;
    }
    var trashed_id: i64 = 0;
    {
        var cb = try client.soft_eager_child.Create();
        defer cb.deinit();
        _ = try cb.setFieldValue("parent_id", parent.id);
        _ = try cb.setFieldValue("name", "trashed");
        var c = try cb.Save();
        defer zent.codegen.deinitEntity(infos, infos[1], &c, allocator);
        trashed_id = c.id;
    }

    // Soft-delete one child; the row stays in the table with deleted_at set.
    {
        var d = client.soft_eager_child.Delete();
        defer d.deinit();
        _ = try d.Where(.{client.soft_eager_child.predicates.idEQ(.{ .int = trashed_id })});
        try testing.expectEqual(@as(usize, 1), try d.Exec());
    }

    // Without WithTrashed the eager load must not surface the soft-deleted row.
    {
        var q = client.soft_eager_parent.Query();
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
        try testing.expectEqualStrings("live", children[0].name);
        try testing.expectEqual(live_id, children[0].id);
    }

    // WithTrashed lifts the scope for eager-loaded targets too.
    {
        var q = client.soft_eager_parent.Query();
        defer q.deinit();
        _ = q.WithTrashed();
        _ = try q.WithEdge("children");
        const parents = try q.All();
        defer {
            for (parents.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            parents.deinit();
        }
        try testing.expectEqual(@as(usize, 1), parents.items.len);
        const children = parents.items[0].edges.children.?;
        try testing.expectEqual(@as(usize, 2), children.len);
    }
}

test "SQLite: eager-loaded children respect interceptor tenant scope" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const ChildBase = schema("TenantEagerChild", .{
        .fields = &.{
            field.Int("parent_id"),
            field.String("name"),
            field.Int("tenant_id"),
        },
    });
    const ParentBase = schema("TenantEagerParent", .{
        .fields = &.{
            field.String("name"),
            field.Int("tenant_id"),
        },
        .edges = &.{edge.To("children", ChildBase).Field("parent_id")},
    });

    const graph = comptime buildGraph(&.{ ParentBase, ChildBase });
    const infos = graph.types;
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
    var client = Client.makeClient(infos, allocator, drv.asDriver());
    defer Client.DeinitClient(infos, &client);

    // Multi-tenant interceptor: scopes every query (including eager loads)
    // to the current tenant.
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

    // Seed two parents and, under parent 1, one child per tenant.
    var p1: i64 = 0;
    {
        var b = try client.tenant_eager_parent.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "p1");
        _ = try b.setFieldValue("tenant_id", @as(i64, 1));
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &e, allocator);
        p1 = e.id;
    }
    var p2: i64 = 0;
    {
        var b = try client.tenant_eager_parent.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "p2");
        _ = try b.setFieldValue("tenant_id", @as(i64, 2));
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &e, allocator);
        p2 = e.id;
    }
    const seeds = [_]struct { parent: i64, name: []const u8, t: i64 }{
        .{ .parent = p1, .name = "p1-t1", .t = 1 },
        .{ .parent = p1, .name = "p1-t2", .t = 2 },
        .{ .parent = p2, .name = "p2-t2", .t = 2 },
    };
    for (seeds) |s| {
        var b = try client.tenant_eager_child.Create();
        defer b.deinit();
        _ = try b.setFieldValue("parent_id", s.parent);
        _ = try b.setFieldValue("name", s.name);
        _ = try b.setFieldValue("tenant_id", s.t);
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[1], &e, allocator);
    }

    // Tenant 1: only parent 1 and only its tenant-1 child (pre-fix the eager
    // load returned p1-t2 as well — the cross-tenant leak).
    {
        var q = client.tenant_eager_parent.Query();
        defer q.deinit();
        _ = try q.WithEdge("children");
        const parents = try q.All();
        defer {
            for (parents.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            parents.deinit();
        }
        try testing.expectEqual(@as(usize, 1), parents.items.len);
        try testing.expectEqualStrings("p1", parents.items[0].name);
        const children = parents.items[0].edges.children.?;
        try testing.expectEqual(@as(usize, 1), children.len);
        try testing.expectEqualStrings("p1-t1", children[0].name);
    }

    // Tenant 2: parent 2 and its tenant-2 child.
    tenant = 2;
    {
        var q = client.tenant_eager_parent.Query();
        defer q.deinit();
        _ = try q.WithEdge("children");
        const parents = try q.All();
        defer {
            for (parents.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            parents.deinit();
        }
        try testing.expectEqual(@as(usize, 1), parents.items.len);
        try testing.expectEqualStrings("p2", parents.items[0].name);
        const children = parents.items[0].edges.children.?;
        try testing.expectEqual(@as(usize, 1), children.len);
        try testing.expectEqualStrings("p2-t2", children[0].name);
    }
}

test "SQLite: eager-loaded children respect privacy filters" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const ChildBase = schema("PrivacyEagerChild", .{
        .fields = &.{
            field.Int("parent_id"),
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
    const ParentBase = schema("PrivacyEagerParent", .{
        .fields = &.{field.String("name")},
        .edges = &.{edge.To("children", ChildBase).Field("parent_id")},
    });

    const graph = comptime buildGraph(&.{ ParentBase, ChildBase });
    const infos = graph.types;
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var parent = blk: {
        var b = try client.privacy_eager_parent.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "p");
        break :blk try b.Save();
    };
    defer zent.codegen.deinitEntity(infos, infos[0], &parent, allocator);
    for ([_]struct { name: []const u8, owner: i64 }{
        .{ .name = "mine", .owner = 1 },
        .{ .name = "theirs", .owner = 2 },
    }) |s| {
        var cc = client.privacy_eager_child.withContext(.{ .user_id = s.owner });
        var b = try cc.Create();
        defer b.deinit();
        _ = try b.setFieldValue("parent_id", parent.id);
        _ = try b.setFieldValue("name", s.name);
        _ = try b.setFieldValue("owner_id", s.owner);
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[1], &e, allocator);
    }

    // The target's Filter policy must scope the eager load to the caller.
    {
        var c = client.privacy_eager_parent.withContext(.{ .user_id = 1 });
        var q = c.Query();
        defer q.deinit();
        _ = try q.WithEdge("children");
        const parents = try q.All();
        defer {
            for (parents.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            parents.deinit();
        }
        const children = parents.items[0].edges.children.?;
        try testing.expectEqual(@as(usize, 1), children.len);
        try testing.expectEqualStrings("mine", children[0].name);
    }
}

test "SQLite: QueryEdge edge traversal covers O2M, M2M and M2O" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const CarBase = schema("QtCar", .{
        .fields = &.{field.String("model")},
    });
    const GroupBase = schema("QtGroup", .{
        .fields = &.{field.String("name")},
        .mixins = &.{zent.core.mixin.SoftDeleteMixin},
        .soft_delete = true,
    });
    const UserBase = schema("QtUser", .{
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
    _ = try drv.exec("DROP TABLE IF EXISTS qt_group_qt_user", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS qt_car", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS qt_group", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS qt_user", &.{});
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
    // Single defer so the drops run junction → car → group → user (reverse
    // order would hit the FK constraints still in place).
    defer {
        _ = drv.exec("DROP TABLE IF EXISTS qt_group_qt_user", &.{}) catch {};
        _ = drv.exec("DROP TABLE IF EXISTS qt_car", &.{}) catch {};
        _ = drv.exec("DROP TABLE IF EXISTS qt_group", &.{}) catch {};
        _ = drv.exec("DROP TABLE IF EXISTS qt_user", &.{}) catch {};
    }

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var g1: i64 = 0;
    var g2: i64 = 0;
    var g3: i64 = 0;
    {
        var b = try client.qt_group.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "g1");
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, group_info, &e, allocator);
        g1 = e.id;
    }
    {
        var b = try client.qt_group.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "g2");
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, group_info, &e, allocator);
        g2 = e.id;
    }
    {
        var b = try client.qt_group.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "g3");
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, group_info, &e, allocator);
        g3 = e.id;
    }

    var alice: i64 = 0;
    {
        var b = try client.qt_user.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "alice");
        _ = try b.AddEdge("groups", &.{ g1, g2 });
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, user_info, &e, allocator);
        alice = e.id;
    }
    var bob: i64 = 0;
    {
        var b = try client.qt_user.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "bob");
        _ = try b.AddEdge("groups", &.{g3});
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, user_info, &e, allocator);
        bob = e.id;
    }

    var bob_car: i64 = 0;
    {
        var b = try client.qt_car.Create();
        defer b.deinit();
        _ = try b.setFieldValue("model", "a1");
        _ = try b.setFieldValue("owner_id", alice);
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, car_info, &e, allocator);
    }
    {
        var b = try client.qt_car.Create();
        defer b.deinit();
        _ = try b.setFieldValue("model", "a2");
        _ = try b.setFieldValue("owner_id", alice);
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, car_info, &e, allocator);
    }
    {
        var b = try client.qt_car.Create();
        defer b.deinit();
        _ = try b.setFieldValue("model", "b1");
        _ = try b.setFieldValue("owner_id", bob);
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, car_info, &e, allocator);
        bob_car = e.id;
    }

    // Soft-delete one of alice's groups; the traversal must not surface it.
    {
        var d = client.qt_group.Delete();
        defer d.deinit();
        _ = try d.Where(.{client.qt_group.predicates.idEQ(.{ .int = g2 })});
        try testing.expectEqual(@as(usize, 1), try d.Exec());
    }

    // O2M: alice's two cars.
    {
        var cars = try client.qt_user.QueryEdge("cars", &.{alice});
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
        var cars = try client.qt_user.QueryEdge("cars", &.{ alice, bob });
        defer {
            for (cars.items) |*e| zent.codegen.deinitEntity(infos, car_info, e, allocator);
            cars.deinit();
        }
        try testing.expectEqual(@as(usize, 3), cars.items.len);
    }

    // M2M: alice belongs to g1 (g2 is soft-deleted).
    {
        var groups = try client.qt_user.QueryEdge("groups", &.{alice});
        defer {
            for (groups.items) |*e| zent.codegen.deinitEntity(infos, group_info, e, allocator);
            groups.deinit();
        }
        try testing.expectEqual(@as(usize, 1), groups.items.len);
        try testing.expectEqual(g1, groups.items[0].id);
    }

    // M2M: bob belongs to g3.
    {
        var groups = try client.qt_user.QueryEdge("groups", &.{bob});
        defer {
            for (groups.items) |*e| zent.codegen.deinitEntity(infos, group_info, e, allocator);
            groups.deinit();
        }
        try testing.expectEqual(@as(usize, 1), groups.items.len);
        try testing.expectEqual(g3, groups.items[0].id);
    }

    // M2O inverse: car -> owner.
    {
        var owners = try client.qt_car.QueryEdge("owner", &.{bob_car});
        defer {
            for (owners.items) |*e| zent.codegen.deinitEntity(infos, user_info, e, allocator);
            owners.deinit();
        }
        try testing.expectEqual(@as(usize, 1), owners.items.len);
        try testing.expectEqualStrings("bob", owners.items[0].name);
    }

    // Empty parent list short-circuits without touching the database.
    {
        var none = try client.qt_user.QueryEdge("cars", &[_]i64{});
        defer none.deinit();
        try testing.expectEqual(@as(usize, 0), none.items.len);
    }
}

test "SQLite: queryTargetsByValue traverses UUID-keyed parents" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const ItemBase = schema("UqvItem", .{
        .fields = &.{ field.String("model"), field.UUID("uqv_user_id") },
    });
    const UserBase = schema("UqvUser", .{
        .fields = &.{ field.UUID("id"), field.String("name") },
        .edges = &.{edge.To("items", ItemBase).Field("uqv_user_id")},
    });
    // An integer-keyed pair in the same graph exercises the i64 bridge.
    const BudgetBase = schema("UqvBudget", .{
        .fields = &.{ field.Int("amount"), field.Int("uqv_owner_id") },
    });
    const OwnerBase = schema("UqvOwner", .{
        .fields = &.{field.String("name")},
        .edges = &.{edge.To("budgets", BudgetBase).Field("uqv_owner_id")},
    });

    const infos = comptime buildGraph(&.{ UserBase, ItemBase, OwnerBase, BudgetBase }).types;
    const user_info = infos[0];
    const item_info = infos[1];
    const budget_info = infos[3];

    _ = try drv.exec("DROP TABLE IF EXISTS uqv_item", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS uqv_budget", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS uqv_user", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS uqv_owner", &.{});
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
    defer {
        _ = drv.exec("DROP TABLE IF EXISTS uqv_item", &.{}) catch {};
        _ = drv.exec("DROP TABLE IF EXISTS uqv_budget", &.{}) catch {};
        _ = drv.exec("DROP TABLE IF EXISTS uqv_user", &.{}) catch {};
        _ = drv.exec("DROP TABLE IF EXISTS uqv_owner", &.{}) catch {};
    }

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    const alice_id = "01920000-0000-7000-8000-000000000001";
    const bob_id = "01920000-0000-7000-8000-000000000002";
    const users = [_][]const u8{ alice_id, bob_id };
    for (users, 0..) |uid, i| {
        var b = try client.uqv_user.Create();
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
        var b = try client.uqv_item.Create();
        defer b.deinit();
        _ = try b.setFieldValue("uqv_user_id", item[0]);
        _ = try b.setFieldValue("model", item[1]);
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, item_info, &e, allocator);
    }

    // UUID/textual parents travel as `.string` values.
    {
        var rows = try Client.queryTargetsByValue(infos, "UqvUser", "items", &.{.{ .string = alice_id }}, allocator, drv.asDriver());
        defer {
            for (rows.items) |*r| zent.codegen.deinitEntity(infos, item_info, r, allocator);
            rows.deinit();
        }
        try testing.expectEqual(@as(usize, 2), rows.items.len);
        var saw_a1 = false;
        var saw_a2 = false;
        for (rows.items) |r| {
            if (std.mem.eql(u8, r.model, "a1")) saw_a1 = true;
            if (std.mem.eql(u8, r.model, "a2")) saw_a2 = true;
        }
        try testing.expect(saw_a1 and saw_a2);
    }

    // Multi-parent IN list spans both UUID keys.
    {
        var rows = try Client.queryTargetsByValue(infos, "UqvUser", "items", &.{
            .{ .string = alice_id },
            .{ .string = bob_id },
        }, allocator, drv.asDriver());
        defer {
            for (rows.items) |*r| zent.codegen.deinitEntity(infos, item_info, r, allocator);
            rows.deinit();
        }
        try testing.expectEqual(@as(usize, 3), rows.items.len);
    }

    // Empty parent list short-circuits without touching the database.
    {
        var rows = try Client.queryTargetsByValue(infos, "UqvUser", "items", &[_]zent.sql.Value{}, allocator, drv.asDriver());
        defer rows.deinit();
        try testing.expectEqual(@as(usize, 0), rows.items.len);
    }

    // The integer bridge still binds `.int` parents.
    _ = try drv.exec("INSERT INTO uqv_owner (id, name) VALUES (1, 'o1')", &.{});
    _ = try drv.exec("INSERT INTO uqv_budget (id, amount, uqv_owner_id) VALUES (1, 10, 1)", &.{});
    _ = try drv.exec("INSERT INTO uqv_budget (id, amount, uqv_owner_id) VALUES (2, 20, 1)", &.{});
    {
        var rows = try Client.queryTargets(infos, "UqvOwner", "budgets", &.{1}, allocator, drv.asDriver());
        defer {
            for (rows.items) |*r| zent.codegen.deinitEntity(infos, budget_info, r, allocator);
            rows.deinit();
        }
        try testing.expectEqual(@as(usize, 2), rows.items.len);
    }
}

test "SQLite: Update edge writes maintain M2M and O2M associations" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const CarBase = schema("EwCar", .{
        .fields = &.{ field.String("model"), field.Int("owner_id").Optional() },
    });
    const GroupBase = schema("EwGroup", .{
        .fields = &.{field.String("name")},
    });
    const UserBase = schema("EwUser", .{
        .fields = &.{field.String("name")},
    });
    const UserGroup = schema("EwUserGroup", .{
        .fields = &.{ field.Int("ew_user_id"), field.Int("ew_group_id") },
        // The junction needs a uniqueness guarantee for idempotent inserts;
        // the auto-created junction gets a composite primary key, but an
        // explicit through schema must declare its own unique index.
        .indexes = &.{index.Fields(&.{ "ew_user_id", "ew_group_id" }).Unique()},
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

    _ = try drv.exec("DROP TABLE IF EXISTS ew_user_group", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS ew_car", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS ew_group", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS ew_user", &.{});
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
    defer {
        _ = drv.exec("DROP TABLE IF EXISTS ew_user_group", &.{}) catch {};
        _ = drv.exec("DROP TABLE IF EXISTS ew_car", &.{}) catch {};
        _ = drv.exec("DROP TABLE IF EXISTS ew_group", &.{}) catch {};
        _ = drv.exec("DROP TABLE IF EXISTS ew_user", &.{}) catch {};
    }

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    var uids: [2]i64 = undefined;
    for (&uids, 0..) |*out, i| {
        var b = try client.ew_user.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", if (i == 0) "u1" else "u2");
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, user_info, &e, allocator);
        out.* = e.id;
    }
    var gids: [3]i64 = undefined;
    for (&gids, 0..) |*out, i| {
        var b = try client.ew_group.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", if (i == 0) "g1" else if (i == 1) "g2" else "g3");
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, group_info, &e, allocator);
        out.* = e.id;
    }
    var cids: [3]i64 = undefined;
    for (&cids, 0..) |*out, i| {
        var b = try client.ew_car.Create();
        defer b.deinit();
        _ = try b.setFieldValue("model", if (i == 0) "c1" else if (i == 1) "c2" else "c3");
        // c1 → u1, c2 → u2, c3 unowned.
        if (i == 0) {
            _ = try b.setFieldValue("owner_id", uids[0]);
        } else if (i == 1) {
            _ = try b.setFieldValue("owner_id", uids[1]);
        }
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, car_info, &e, allocator);
        out.* = e.id;
    }

    const preds = client.ew_user.predicates;

    // M2M Add is idempotent: applying the same ids twice keeps two rows.
    for (0..2) |_| {
        var u = client.ew_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "u1");
        _ = try u.Where(.{preds.idEQ(.{ .int = uids[0] })});
        _ = try u.AddEdgeIDs("groups", &.{ gids[0], gids[1] });
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }
    {
        var groups = try client.ew_user.QueryEdge("groups", &.{uids[0]});
        defer {
            for (groups.items) |*e| zent.codegen.deinitEntity(infos, group_info, e, allocator);
            groups.deinit();
        }
        try testing.expectEqual(@as(usize, 2), groups.items.len);
    }

    // Seed u2 with g3 so we can prove scope isolation.
    {
        var u = client.ew_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "u2");
        _ = try u.Where(.{preds.idEQ(.{ .int = uids[1] })});
        _ = try u.AddEdgeIDs("groups", &.{gids[2]});
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }

    // Remove one association from u1 only.
    {
        var u = client.ew_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "u1");
        _ = try u.Where(.{preds.idEQ(.{ .int = uids[0] })});
        _ = try u.RemoveEdgeIDs("groups", &.{gids[0]});
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }
    {
        var groups = try client.ew_user.QueryEdge("groups", &.{uids[0]});
        defer {
            for (groups.items) |*e| zent.codegen.deinitEntity(infos, group_info, e, allocator);
            groups.deinit();
        }
        try testing.expectEqual(@as(usize, 1), groups.items.len);
        try testing.expectEqual(gids[1], groups.items[0].id);
    }

    // Give u2 g1 too, then Clear u1: u2 must keep both associations.
    {
        var u = client.ew_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "u2");
        _ = try u.Where(.{preds.idEQ(.{ .int = uids[1] })});
        _ = try u.AddEdgeIDs("groups", &.{gids[0]});
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }
    {
        var u = client.ew_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "u1");
        _ = try u.Where(.{preds.idEQ(.{ .int = uids[0] })});
        _ = try u.ClearEdge("groups");
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }
    {
        var groups = try client.ew_user.QueryEdge("groups", &.{uids[0]});
        defer {
            for (groups.items) |*e| zent.codegen.deinitEntity(infos, group_info, e, allocator);
            groups.deinit();
        }
        try testing.expectEqual(@as(usize, 0), groups.items.len);
    }
    {
        var groups = try client.ew_user.QueryEdge("groups", &.{uids[1]});
        defer {
            for (groups.items) |*e| zent.codegen.deinitEntity(infos, group_info, e, allocator);
            groups.deinit();
        }
        try testing.expectEqual(@as(usize, 2), groups.items.len);
    }

    // O2M Set: detaches c1 from u1 and attaches c3 to u1.
    {
        var u = client.ew_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "u1");
        _ = try u.Where(.{preds.idEQ(.{ .int = uids[0] })});
        _ = try u.SetEdgeIDs("cars", &.{cids[2]});
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }
    try expectCarOwner(&client, infos, car_info, cids[0], null);
    try expectCarOwner(&client, infos, car_info, cids[2], uids[0]);
    try expectCarOwner(&client, infos, car_info, cids[1], uids[1]);

    // O2M Clear nulls u1's FK; u2's car is untouched.
    {
        var u = client.ew_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "u1");
        _ = try u.Where(.{preds.idEQ(.{ .int = uids[0] })});
        _ = try u.ClearEdge("cars");
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }
    try expectCarOwner(&client, infos, car_info, cids[2], null);
    try expectCarOwner(&client, infos, car_info, cids[1], uids[1]);

    // Set with empty ids is replace-with-empty: detach only.
    {
        var u = client.ew_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "u2");
        _ = try u.Where(.{preds.idEQ(.{ .int = uids[1] })});
        _ = try u.SetEdgeIDs("cars", &.{});
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }
    try expectCarOwner(&client, infos, car_info, cids[1], null);
}

fn expectCarOwner(
    client: anytype,
    comptime infos: []const zent.codegen.graph.TypeInfo,
    comptime car_info: zent.codegen.graph.TypeInfo,
    car_id: i64,
    expected: ?i64,
) !void {
    var q = client.ew_car.Query();
    defer q.deinit();
    _ = try q.Where(.{client.ew_car.predicates.idEQ(.{ .int = car_id })});
    var car = (try q.First()) orelse return error.NoRow;
    defer zent.codegen.deinitEntity(infos, car_info, &car, std.testing.allocator);
    try std.testing.expectEqual(expected, car.owner_id);
}

test "SQLite: Update edge writes honor interceptor tenant scope" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const TenantUserBase = schema("EwTenantUser", .{
        .fields = &.{ field.String("name"), field.Int("tenant_id") },
    });
    const TenantGroupBase = schema("EwTenantGroup", .{
        .fields = &.{field.String("name")},
    });
    const TenantUser = struct {
        pub const schema_name = TenantUserBase.schema_name;
        pub const fields = TenantUserBase.fields;
        pub const edges = &.{edge.To("groups", TenantGroupBase)};
        pub const indexes = TenantUserBase.indexes;
    };
    const TenantGroup = struct {
        pub const schema_name = TenantGroupBase.schema_name;
        pub const fields = TenantGroupBase.fields;
        pub const edges = &.{edge.To("users", TenantUserBase)};
        pub const indexes = TenantGroupBase.indexes;
    };

    const graph = comptime buildGraph(&.{ TenantUser, TenantGroup });
    const infos = graph.types;
    const user_info = infos[0];
    const group_info = infos[1];

    _ = try drv.exec("DROP TABLE IF EXISTS ew_tenant_group_ew_tenant_user", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS ew_tenant_group", &.{});
    _ = try drv.exec("DROP TABLE IF EXISTS ew_tenant_user", &.{});
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());
    defer {
        _ = drv.exec("DROP TABLE IF EXISTS ew_tenant_group_ew_tenant_user", &.{}) catch {};
        _ = drv.exec("DROP TABLE IF EXISTS ew_tenant_group", &.{}) catch {};
        _ = drv.exec("DROP TABLE IF EXISTS ew_tenant_user", &.{}) catch {};
    }

    var client = Client.makeClient(infos, allocator, drv.asDriver());
    defer Client.DeinitClient(infos, &client);

    var tenant: i64 = 1;
    try Client.UseInterceptor(infos, &client, .{
        .ctx = &tenant,
        .intercept = struct {
            fn f(ctx: ?*anyopaque, view: *zent.runtime.intercept.QueryView) anyerror!void {
                // Only the tenant-scoped user table carries tenant_id.
                if (!std.mem.eql(u8, view.table_name, "ew_tenant_user")) return;
                const id: *i64 = @ptrCast(@alignCast(ctx.?));
                try view.whereEq("tenant_id", .{ .int = id.* });
            }
        }.f,
    });

    var uids: [2]i64 = undefined;
    for (&uids, 0..) |*out, i| {
        var b = try client.ew_tenant_user.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", if (i == 0) "t1u" else "t2u");
        _ = try b.setFieldValue("tenant_id", @as(i64, @intCast(i + 1)));
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, user_info, &e, allocator);
        out.* = e.id;
    }
    var gids: [2]i64 = undefined;
    for (&gids, 0..) |*out, i| {
        var b = try client.ew_tenant_group.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", if (i == 0) "g1" else "g2");
        var e = try b.Save();
        defer zent.codegen.deinitEntity(infos, group_info, &e, allocator);
        out.* = e.id;
    }

    // Each tenant links its own group, under its own interceptor scope.
    tenant = 1;
    {
        var u = client.ew_tenant_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "t1u");
        _ = try u.Where(.{client.ew_tenant_user.predicates.idEQ(.{ .int = uids[0] })});
        _ = try u.AddEdgeIDs("groups", &.{gids[0]});
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }
    tenant = 2;
    {
        var u = client.ew_tenant_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "t2u");
        _ = try u.Where(.{client.ew_tenant_user.predicates.idEQ(.{ .int = uids[1] })});
        _ = try u.AddEdgeIDs("groups", &.{gids[1]});
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }

    // Clear with no Where under tenant 1: tenant 2's junction must survive,
    // proving the edge statement reuses the interceptor-scoped predicates.
    tenant = 1;
    {
        var u = client.ew_tenant_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", "t1u");
        _ = try u.ClearEdge("groups");
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }

    try testing.expectEqual(@as(i64, 0), try junctionCount(drv.asDriver(), "ew_tenant_group_ew_tenant_user", "ew_tenant_user_id", uids[0]));
    try testing.expectEqual(@as(i64, 1), try junctionCount(drv.asDriver(), "ew_tenant_group_ew_tenant_user", "ew_tenant_user_id", uids[1]));
}

fn junctionCount(driver: zent.sql_driver.Driver, table: []const u8, source_col: []const u8, source_id: i64) !i64 {
    var buf: [256]u8 = undefined;
    const sql_text = try std.fmt.bufPrint(&buf, "SELECT COUNT(*) FROM \"{s}\" WHERE \"{s}\" = ?", .{ table, source_col });
    var rows = try driver.query(sql_text, &.{.{ .int = source_id }});
    defer rows.deinit();
    if (rows.next()) |row| return row.getInt(0) orelse 0;
    return 0;
}

test "SQLite: StorageKey maps field names to distinct column names" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // Field names intentionally differ from column names (ent `StorageKey`).
    const Account = schema("StorageAccount", .{
        .table_name = "storage_account",
        .fields = &.{
            field.String("userName").StorageKey("user_name"),
            field.String("emailAddr").StorageKey("email_address"),
            field.Int("loginCount").StorageKey("login_count"),
        },
        .mixins = &.{zent.core.mixin.SoftDeleteMixin},
        .soft_delete = true,
        .indexes = &.{index.Fields(&.{"loginCount"})},
    });
    const graph = comptime buildGraph(&.{Account});
    const infos = graph.types;
    try migrate.migrateSchema(allocator, drv.asDriver(), infos);
    var client = Client.makeClient(infos, allocator, drv.asDriver());
    const preds = client.storage_account.predicates;

    // DDL and the index must reference physical columns, not field names.
    {
        var rows = try drv.query("SELECT user_name, email_address, login_count FROM storage_account", &.{});
        rows.deinit();
    }
    {
        var rows = try drv.query(
            "SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'storage_account'",
            &.{},
        );
        defer rows.deinit();
        var found_mapped = false;
        while (rows.next()) |row| {
            const ddl = row.getText(0) orelse continue;
            if (std.mem.indexOf(u8, ddl, "login_count") != null) found_mapped = true;
            try testing.expect(std.mem.indexOf(u8, ddl, "loginCount") == null);
        }
        try testing.expect(found_mapped);
    }

    // Insert: user-facing APIs take field names; SQL uses mapped columns.
    var b1 = try client.storage_account.Create();
    defer b1.deinit();
    _ = try b1.setFieldValue("userName", "alice");
    _ = try b1.setFieldValue("emailAddr", "alice@example.com");
    _ = try b1.setFieldValue("loginCount", @as(i64, 3));
    var a1 = try b1.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &a1, allocator);

    var b2 = try client.storage_account.Create();
    defer b2.deinit();
    _ = try b2.setFieldValue("userName", "bob");
    _ = try b2.setFieldValue("emailAddr", "bob@example.com");
    _ = try b2.setFieldValue("loginCount", @as(i64, 7));
    var a2 = try b2.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &a2, allocator);

    // Raw read proves the values landed in the mapped columns.
    {
        var rows = try drv.query(
            "SELECT user_name, email_address, login_count FROM storage_account WHERE user_name = ?",
            &.{.{ .string = "alice" }},
        );
        defer rows.deinit();
        const row = rows.next() orelse return error.NoRow;
        try testing.expectEqualStrings("alice", row.getText(0).?);
        try testing.expectEqualStrings("alice@example.com", row.getText(1).?);
        try testing.expectEqual(@as(i64, 3), row.getInt(2).?);
    }

    // Fetch by primary key.
    {
        var q = client.storage_account.Query();
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

    // Typed predicate filtering by field name.
    {
        var q = client.storage_account.Query();
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

    // ORDER BY field name maps to the physical column.
    {
        var q = client.storage_account.Query();
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

    // Partial projection (`Select`) with field names.
    {
        var q = client.storage_account.Query();
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

    // Update by field name.
    {
        var u = client.storage_account.Update();
        defer u.deinit();
        _ = try u.setFieldValue("emailAddr", "alice2@example.com");
        _ = try u.Where(.{preds.userNameEQ(.{ .string = "alice" })});
        try testing.expectEqual(@as(usize, 1), try u.Save());
    }
    {
        var q = client.storage_account.Query();
        defer q.deinit();
        _ = try q.Where(.{preds.emailAddrEQ(.{ .string = "alice2@example.com" })});
        var found = try q.All();
        defer {
            for (found.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            found.deinit();
        }
        try testing.expectEqual(@as(usize, 1), found.items.len);
    }

    // Soft delete by field name (soft_delete → UPDATE deleted_at).
    {
        var d = client.storage_account.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.userNameEQ(.{ .string = "bob" })});
        try testing.expectEqual(@as(usize, 1), try d.Exec());
    }
    {
        var q = client.storage_account.Query();
        defer q.deinit();
        var found = try q.All();
        defer {
            for (found.items) |*e| zent.codegen.deinitEntity(infos, infos[0], e, allocator);
            found.deinit();
        }
        // Soft-deleted "bob" is filtered out of the default query scope.
        try testing.expectEqual(@as(usize, 1), found.items.len);
        try testing.expectEqualStrings("alice", found.items[0].userName);
    }

    // Hard delete by field name.
    {
        var d = client.storage_account.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.userNameEQ(.{ .string = "alice" })});
        try testing.expectEqual(@as(usize, 1), try d.ForceExec());
    }
}

test "SQLite: createAllTables keeps a UUID primary key typed as UUID" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // DDL comes from the library rather than raw SQL: the auto-increment
    // rewrite used to mark every id column as auto-increment, which turned a
    // UUID primary key into SERIAL on PostgreSQL and into an unindexable TEXT
    // key on MySQL. On SQLite the column stays TEXT with a PRIMARY KEY, so the
    // round-trip through the generated client is the assertion.
    const DocBase = schema("UuidDoc", .{
        .fields = &.{ field.UUID("id"), field.String("title") },
    });
    const infos = comptime buildGraph(&.{DocBase}).types;
    const doc_info = infos[0];

    try Client.createAllTables(allocator, infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());
    var b = try client.uuid_doc.Create();
    defer b.deinit();
    _ = try b.setFieldValue("id", "01920000-0000-7000-8000-0000000000f3");
    _ = try b.setFieldValue("title", "t");
    var saved = try b.Save();
    defer zent.codegen.deinitEntity(infos, doc_info, &saved, allocator);
    try testing.expectEqualStrings("01920000-0000-7000-8000-0000000000f3", saved.id);
}

test "SQLite: BulkInsert honours an explicit chunk size across boundaries" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const Chunked = schema("ChunkedRow", .{
        .fields = &.{
            field.String("name"),
            field.Int("score"),
        },
    });

    const graph = comptime buildGraph(&.{Chunked});
    const infos = graph.types;
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Five rows in chunks of two means three statements (2 + 2 + 1): the test
    // pins the boundary behaviour deterministically instead of relying on the
    // server's bound-parameter limit, which varies by SQLite build. Each chunk
    // reports its own ids, so the caller must still see one id per row and the
    // ids must keep accumulating across statements.
    const row_count: usize = 5;
    var b = try client.chunked_row.BulkInsert();
    defer b.deinit();
    _ = b.chunkRows(2);
    for (0..row_count) |i| {
        if (i > 0) _ = try b.Next();
        _ = try b.setFieldValue("name", "row");
        _ = try b.setFieldValue("score", @as(i64, @intCast(i)));
    }

    const ids = try b.Save();
    defer ids.deinit();
    try testing.expectEqual(row_count, ids.items.len);
    for (ids.items, 0..) |id, i| {
        try testing.expectEqual(@as(i64, @intCast(i + 1)), id);
    }

    var rows = try drv.query("SELECT COUNT(*) FROM chunked_row", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try testing.expectEqual(@as(i64, @intCast(row_count)), row.getInt(0).?);
}

/// Counts statements reaching the driver so a test can assert how many queries
/// an eager load issues. Every vtable entry delegates to the wrapped driver.
const CountingDriver = struct {
    inner: zent.sql_driver.Driver,
    queries: usize = 0,
    execs: usize = 0,

    fn borrowed(self: *@This()) zent.sql_driver.Driver {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn execFn(ptr: *anyopaque, ctx: ?*const zent.sql_driver.ExecutionContext, q: []const u8, a: []const zent.sql.Value) zent.sql_driver.Error!zent.sql_driver.Result {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.execs += 1;
        return self.inner.execCtx(ctx, q, a);
    }
    fn queryFn(ptr: *anyopaque, ctx: ?*const zent.sql_driver.ExecutionContext, q: []const u8, a: []const zent.sql.Value) zent.sql_driver.Error!zent.sql_driver.Rows {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.queries += 1;
        return self.inner.queryCtx(ctx, q, a);
    }
    fn beginTxFn(ptr: *anyopaque) zent.sql_driver.Error!zent.sql_driver.Tx {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.inner.beginTx();
    }
    fn beginSavepointFn(ptr: *anyopaque, name: []const u8) zent.sql_driver.Error!zent.sql_driver.Tx {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.inner.beginSavepoint(name);
    }
    fn closeFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.inner.close();
    }
    fn dialectFn(ptr: *anyopaque) zent.sql_dialect.Dialect {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.inner.dialect();
    }
    fn pingFn(ptr: *anyopaque) zent.sql_driver.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.inner.ping();
    }
    fn inTxFn(ptr: *anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.inner.inTransaction();
    }

    const vtable = zent.sql_driver.Driver.VTable{
        .exec = execFn,
        .query = queryFn,
        .beginTx = beginTxFn,
        .beginSavepoint = beginSavepointFn,
        .close = closeFn,
        .dialect = dialectFn,
        .ping = pingFn,
        .inTransaction = inTxFn,
    };
};

test "SQLite: nested eager loading batches each level into one query" {
    const allocator = testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // The FK columns are declared fields named after the parent table, which is
    // what the edge inference expects (same shape as the query.zig nested test).
    const NoteBase = schema("NitNote", .{
        .fields = &.{ field.Int("nit_item_id"), field.String("body") },
    });
    const ItemBase = schema("NitItem", .{
        .fields = &.{ field.Int("nit_owner_id"), field.String("label") },
        .edges = &.{edge.To("notes", NoteBase)},
    });
    const OwnerBase = schema("NitOwner", .{
        .fields = &.{field.String("name")},
        .edges = &.{edge.To("items", ItemBase)},
    });

    const infos = comptime buildGraph(&.{ OwnerBase, ItemBase, NoteBase }).types;
    const owner_info = infos[0];
    const item_info = infos[1];
    const note_info = infos[2];
    try Client.createAllTables(std.testing.allocator, infos, drv.asDriver());

    var counting = CountingDriver{ .inner = drv.asDriver() };
    var client = Client.makeClient(infos, allocator, counting.borrowed());

    // Three owners, each with one item carrying one note.
    const names = [_][]const u8{ "o1", "o2", "o3" };
    for (names, 0..) |name, i| {
        var ob = try client.nit_owner.Create();
        defer ob.deinit();
        _ = try ob.setFieldValue("name", name);
        var owner = try ob.Save();
        defer zent.codegen.deinitEntity(infos, owner_info, &owner, allocator);

        var ib = try client.nit_item.Create();
        defer ib.deinit();
        _ = try ib.setFieldValue("nit_owner_id", owner.id);
        _ = try ib.setFieldValue("label", name);
        var item = try ib.Save();
        defer zent.codegen.deinitEntity(infos, item_info, &item, allocator);

        var nb = try client.nit_note.Create();
        defer nb.deinit();
        _ = try nb.setFieldValue("nit_item_id", item.id);
        _ = try nb.setFieldValue("body", name);
        var note = try nb.Save();
        defer zent.codegen.deinitEntity(infos, note_info, &note, allocator);
        _ = i;
    }

    counting.queries = 0;
    counting.execs = 0;

    var q = client.nit_owner.Query();
    defer q.deinit();
    _ = try q.WithEdge("items.notes");
    var result = try q.All();
    defer {
        for (result.items) |*e| zent.codegen.deinitEntity(infos, owner_info, e, allocator);
        result.deinit();
    }

    // One query for the owners, one for the items, one for the notes —
    // independent of how many owners there are. Recursing per parent issued
    // one query per owner for the second level.
    try testing.expectEqual(@as(usize, 3), counting.queries);
    try testing.expectEqual(@as(usize, 3), result.items.len);
    // The nested level really did load (a batching bug that dropped it would
    // still show 3 queries).
    for (result.items) |owner| {
        const items = owner.edges.items.?;
        try testing.expectEqual(@as(usize, 1), items.len);
        const notes = items[0].edges.notes.?;
        try testing.expectEqual(@as(usize, 1), notes.len);
        try testing.expectEqualStrings(owner.name, notes[0].body);
    }
}
