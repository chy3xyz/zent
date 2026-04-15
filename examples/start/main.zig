const std = @import("std");
const zent = @import("zent");

const sql = zent.sql;
const Dialect = zent.sql_dialect.Dialect;
const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
const scanRow = zent.sql_scan.scanRow;
const fromSchema = zent.codegen.graph.fromSchema;
const buildGraph = zent.codegen.graph.buildGraph;
const Entity = zent.codegen.entity;
const Client = zent.codegen.client;
const migrate = zent.sql_schema;

const start_schema = @import("schema.zig");

const User = start_schema.User;
const Car = start_schema.Car;
const Group = start_schema.Group;
const UserGroup = start_schema.UserGroup;
const UserSettings = start_schema.UserSettings;
const ActiveUserView = start_schema.ActiveUserView;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // --- Phase 1: Schema definition and comptime introspection ---
    const graph = comptime buildGraph(&.{ User, Car, Group, ActiveUserView, UserGroup });
    const user_info = graph.types[0];
    const car_info = graph.types[1];
    const group_info = graph.types[2];
    const view_info = graph.types[3];
    const user_group_info = graph.types[4];

    std.debug.print("=== Phase 1: Schema Introspection ===\n", .{});
    std.debug.print("Entity: {s}, Table: {s}, Fields: {d}, Edges: {d}\n", .{
        user_info.name, user_info.table_name, user_info.fields.len, user_info.edges.len,
    });
    inline for (user_info.fields) |f| {
        std.debug.print("  Field: {s} (sql={s}, zig={s})\n", .{ f.name, f.sql_type, @typeName(f.zig_type) });
    }
    inline for (user_info.edges) |e| {
        std.debug.print("  Edge: {s} -> {s} (relation={s}, inverse={s})\n", .{
            e.name,
            e.target_name,
            @tagName(e.relation),
            e.inverse_name orelse "none",
        });
    }

    std.debug.print("Entity: {s}, Table: {s}, Fields: {d}, Edges: {d}\n", .{
        car_info.name, car_info.table_name, car_info.fields.len, car_info.edges.len,
    });

    std.debug.print("Entity: {s}, Table: {s}, Fields: {d}, Edges: {d}\n", .{
        group_info.name, group_info.table_name, group_info.fields.len, group_info.edges.len,
    });
    std.debug.print("View: {s}, Table: {s}, Fields: {d}, is_view={}\n", .{
        view_info.name, view_info.table_name, view_info.fields.len, view_info.is_view,
    });
    std.debug.print("Edge Schema: {s}, Table: {s}, Fields: {d}\n", .{
        user_group_info.name, user_group_info.table_name, user_group_info.fields.len,
    });

    // --- Phase 0: SQL Builder Demo ---
    std.debug.print("\n=== Phase 0: SQL Builder ===\n", .{});
    const t = sql.Table("users");
    var query = sql.Select(allocator, Dialect.sqlite, &.{
        t.c("id"),
        t.c("name"),
    });
    defer query.deinit();
    _ = query.from(t).where(sql.EQ("age", .{ .int = 30 }));
    const q = try query.query();
    std.debug.print("SQL: {s}\n", .{q.sql});
    std.debug.print("Args count: {d}\n", .{q.args.len});

    // --- Phase 4: Migration (Create Tables) ---
    std.debug.print("\n=== Phase 4: Migration ===\n", .{});
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const infos = graph.types;

    // Use automatic migration instead of manual CREATE TABLE
    std.debug.print("Creating tables via migration...\n", .{});
    try migrate.createAllTables(drv.asDriver(), infos);
    std.debug.print("Tables created successfully.\n", .{});

    // Debug: show table structure
    var table_check = try drv.query("SELECT sql FROM sqlite_master WHERE type='table'", &.{});
    defer table_check.deinit();
    while (table_check.next()) |row| {
        if (row.getText(0)) |sql_text| {
            std.debug.print("  Table SQL: {s}\n", .{sql_text});
        }
    }

    // --- Phase 2: Generated Client + CRUD ---
    std.debug.print("\n=== Phase 2: Generated CRUD ===\n", .{});
    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // Attach a simple hook to the user client for demonstration
    const user_hooks = &[_]zent.runtime.hook.Hook{
        .{ .op = .create, .before = struct {
            fn f(op: zent.runtime.hook.Op, table: []const u8) void {
                std.debug.print("[HOOK] Before {s} on {s}\n", .{ @tagName(op), table });
            }
        }.f },
        .{ .op = .create, .after = struct {
            fn f(op: zent.runtime.hook.Op, table: []const u8) void {
                std.debug.print("[HOOK] After {s} on {s}\n", .{ @tagName(op), table });
            }
        }.f },
    };
    client.user = client.user.withHooks(user_hooks);

    // CREATE Group
    std.debug.print("-- CREATE Group --\n", .{});
    var group1_builder = client.group.Create();
    defer group1_builder.deinit();
    _ = group1_builder.setFieldValue("name", "Admins");
    const group1 = try group1_builder.Save();
    std.debug.print("Created group: id={d}, name={s}\n", .{ group1.id, group1.name });

    var group2_builder = client.group.Create();
    defer group2_builder.deinit();
    _ = group2_builder.setFieldValue("name", "Users");
    const group2 = try group2_builder.Save();
    std.debug.print("Created group: id={d}, name={s}\n", .{ group2.id, group2.name });

    // CREATE User with M2M edge adder
    std.debug.print("\n-- CREATE User --\n", .{});
    var create_builder1 = client.user.Create();
    defer create_builder1.deinit();
    _ = create_builder1.setFieldValue("name", "Alice");
    _ = create_builder1.setFieldValue("age", 30);
    _ = create_builder1.setFieldValue("status", "active");
    _ = create_builder1.setFieldValue("settings", UserSettings{ .theme = "dark", .notifications = true });
    _ = create_builder1.AddEdge("groups", &.{group1.id});
    const alice = try create_builder1.Save();
    std.debug.print("Created user: id={d}, name={s}, age={d}, status={s}, theme={s}\n", .{ alice.id, alice.name, alice.age, alice.status, alice.settings.theme });

    var create_builder2 = client.user.Create();
    defer create_builder2.deinit();
    _ = create_builder2.setFieldValue("name", "Bob");
    _ = create_builder2.setFieldValue("age", 25);
    _ = create_builder2.setFieldValue("status", "inactive");
    _ = create_builder2.setFieldValue("settings", UserSettings{ .theme = "light", .notifications = false });
    _ = create_builder2.AddEdge("groups", &.{group2.id});
    const bob = try create_builder2.Save();
    std.debug.print("Created user: id={d}, name={s}, age={d}, status={s}, theme={s}\n", .{ bob.id, bob.name, bob.age, bob.status, bob.settings.theme });

    // CREATE Car (with O2M owner edge)
    std.debug.print("\n-- CREATE Car --\n", .{});
    var car1_builder = client.car.Create();
    defer car1_builder.deinit();
    _ = car1_builder.setFieldValue("model", "Tesla Model S");
    _ = car1_builder.setFieldValue("registered_at", 1705318200);
    // The owner_id FK column was auto-generated by migration
    _ = car1_builder.setFieldValue("owner_id", alice.id);
    const car1 = try car1_builder.Save();
    std.debug.print("Created car: id={d}, model={s}\n", .{ car1.id, car1.model });

    var car2_builder = client.car.Create();
    defer car2_builder.deinit();
    _ = car2_builder.setFieldValue("model", "Toyota Camry");
    _ = car2_builder.setFieldValue("registered_at", 1687269600);
    _ = car2_builder.setFieldValue("owner_id", alice.id);
    const car2 = try car2_builder.Save();
    std.debug.print("Created car: id={d}, model={s}\n", .{ car2.id, car2.model });

    std.debug.print("Added users to groups via AddEdge.\n", .{});

    // CREATE UserGroup edge record directly (edge schema with extra field)
    std.debug.print("\n-- CREATE UserGroup edge record --\n", .{});
    var ug_builder = client.user_group.Create();
    defer ug_builder.deinit();
    _ = ug_builder.setFieldValue("user_id", alice.id);
    _ = ug_builder.setFieldValue("group_id", group2.id);
    _ = ug_builder.setFieldValue("joined_at", 1705318200);
    const ug = try ug_builder.Save();
    std.debug.print("Created user_group: user_id={d}, group_id={d}, joined_at={d}\n", .{ ug.user_id, ug.group_id, ug.joined_at.? });

    const user_preds = client.user.predicates;

    // TRANSACTION demo
    std.debug.print("\n-- TRANSACTION --\n", .{});
    var tx = try zent.codegen.client.beginTx(infos, client);
    var tx_group_builder = tx.client.group.Create();
    defer tx_group_builder.deinit();
    _ = tx_group_builder.setFieldValue("name", "TX Group");
    const tx_group = try tx_group_builder.Save();
    std.debug.print("Created group in tx: id={d}, name={s}\n", .{ tx_group.id, tx_group.name });

    var tx_user_builder = tx.client.user.Create();
    defer tx_user_builder.deinit();
    _ = tx_user_builder.setFieldValue("name", "TX User");
    _ = tx_user_builder.setFieldValue("age", 99);
    _ = tx_user_builder.setFieldValue("status", "active");
    _ = tx_user_builder.setFieldValue("settings", UserSettings{ .theme = "tx", .notifications = false });
    const tx_user = try tx_user_builder.Save();
    std.debug.print("Created user in tx: id={d}, name={s}\n", .{ tx_user.id, tx_user.name });

    try tx.commit();
    std.debug.print("Transaction committed.\n", .{});

    // Verify tx data is visible outside tx
    var qtx = client.user.Query();
    defer qtx.deinit();
    _ = qtx.Where(.{user_preds.nameEQ(.{ .string = "TX User" })});
    const tx_user_outside = try qtx.Only();
    std.debug.print("Verified tx user outside tx: id={d}, name={s}\n", .{ tx_user_outside.id, tx_user_outside.name });

    // QUERY with predicates
    std.debug.print("\n-- QUERY Users --\n", .{});

    var qbuilder = client.user.Query();
    defer qbuilder.deinit();
    _ = qbuilder.Where(.{user_preds.ageEQ(.{ .int = 30 })});
    var users = try qbuilder.All();
    defer users.deinit();
    std.debug.print("Users with age=30: {d}\n", .{users.items.len});
    for (users.items) |u| {
        std.debug.print("  id={d}, name={s}, age={d}, status={s}, theme={s}\n", .{ u.id, u.name, u.age, u.status, u.settings.theme });
    }

    // FIRST / ONLY
    var q2 = client.user.Query();
    defer q2.deinit();
    _ = q2.Where(.{user_preds.nameEQ(.{ .string = "Alice" })});
    const only_alice = try q2.Only();
    std.debug.print("Only Alice: id={d}, name={s}, status={s}, theme={s}\n", .{ only_alice.id, only_alice.name, only_alice.status, only_alice.settings.theme });

    // QUERY View (read-only entity)
    std.debug.print("\n-- QUERY ActiveUserView (view) --\n", .{});
    var view_query = client.active_user_view.Query();
    defer view_query.deinit();
    var active_users = try view_query.All();
    defer active_users.deinit();
    std.debug.print("Active users from view: {d}\n", .{active_users.items.len});
    for (active_users.items) |u| {
        std.debug.print("  id={d}, name={s}, status={s}\n", .{ u.id, u.name, u.status });
    }

    // QUERY Cars by owner (O2M edge traversal)
    std.debug.print("\n-- QUERY Cars (edge traversal) --\n", .{});
    var cars = try client.user.QueryEdge("cars", &.{alice.id});
    defer cars.deinit();
    std.debug.print("Cars owned by Alice: {d}\n", .{cars.items.len});
    for (cars.items) |c| {
        std.debug.print("  id={d}, model={s}\n", .{ c.id, c.model });
    }

    // QUERY Groups by user (M2M edge traversal)
    std.debug.print("\n-- QUERY Groups (M2M edge traversal) --\n", .{});
    var groups = try client.user.QueryEdge("groups", &.{alice.id});
    defer groups.deinit();
    std.debug.print("Groups Alice belongs to: {d}\n", .{groups.items.len});
    for (groups.items) |g| {
        std.debug.print("  id={d}, name={s}\n", .{ g.id, g.name });
    }

    // COUNT
    var q3 = client.user.Query();
    defer q3.deinit();
    const count = try q3.Count();
    std.debug.print("\nTotal users: {d}\n", .{count});

    // UPDATE
    std.debug.print("\n-- UPDATE --\n", .{});
    var upd = client.user.Update();
    defer upd.deinit();
    _ = upd.setFieldValue("age", 31)
        .setFieldValue("settings", UserSettings{ .theme = "auto", .notifications = true })
        .Where(.{user_preds.nameEQ(.{ .string = "Alice" })});
    const updated = try upd.Save();
    std.debug.print("Updated {d} row(s)\n", .{updated});

    // DELETE (should be denied by privacy policy)
    std.debug.print("\n-- DELETE (Privacy Policy Demo) --\n", .{});
    var del = client.user.Delete();
    defer del.deinit();
    _ = del.Where(.{user_preds.nameEQ(.{ .string = "Bob" })});
    const deleted = del.Exec() catch |err| switch (err) {
        error.PrivacyDenied => blk: {
            std.debug.print("Delete denied by privacy policy (OnDelete)\n", .{});
            break :blk @as(usize, 0);
        },
        else => return err,
    };
    std.debug.print("Deleted {d} row(s)\n", .{deleted});

    var q4 = client.user.Query();
    defer q4.deinit();
    const count_after = try q4.Count();
    std.debug.print("Users after delete attempt: {d}\n", .{count_after});

    std.debug.print("\nAll phases (0-4) completed successfully.\n", .{});
}
