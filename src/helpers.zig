//! High-level environment assemblers for zent - the production wiring layer
//! on top of the generated client: single-store, pooled (thread-safe),
//! sharded, and a test factory. Lifted from the ZigModu example
//! `_shared/zent_helpers.zig` into the framework so apps don't copy-paste.

const std = @import("std");
const codegen = @import("codegen/client.zig");
const sql_pool = @import("sql/pool.zig");
const sql_schema = @import("sql/schema/migrate.zig");
const sql_sqlite = @import("sql/sqlite.zig");
const sql_driver = @import("sql/driver.zig");
const shard_mod = @import("shard.zig");

comptime {
    if (!@hasDecl(sql_schema, "migrateSchemaWithOptions")) {
        @compileError("zent.helpers requires zent.sql_schema.migrateSchemaWithOptions");
    }
}

/// RAII wrapper for the standard single-store lifecycle:
/// open driver -> migrate schema -> make client -> close on deinit.
pub fn StoreEnv(comptime Driver: type, comptime Infos: anytype) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        /// Driver is heap-allocated so its address is stable: the generated
        /// Client stores `Driver.ptr` (a pointer to this instance), and
        /// StoreEnv is returned/copied by value - a stack-allocated driver
        /// would leave the client's ptr dangling after the move.
        driver_ptr: *Driver,
        client: codegen.Client(Infos),
        owns_driver: bool,

        /// Open a file-backed store with default migrate options.
        pub fn open(allocator: std.mem.Allocator, path: []const u8) !Self {
            return openWith(allocator, path, .{});
        }

        /// Open an in-memory store (single connection).
        pub fn inMemory(allocator: std.mem.Allocator) !Self {
            return open(allocator, ":memory:");
        }

        /// Open with explicit MigrateOptions.
        pub fn openWith(
            allocator: std.mem.Allocator,
            path: []const u8,
            opts: sql_schema.MigrateOptions,
        ) !Self {
            const driver_ptr = try allocator.create(Driver);
            errdefer allocator.destroy(driver_ptr);
            driver_ptr.* = try Driver.open(allocator, path);
            errdefer driver_ptr.close();

            try sql_schema.migrateSchemaWithOptions(
                allocator,
                driver_ptr.asDriver(),
                Infos,
                opts,
            );

            return .{
                .allocator = allocator,
                .driver_ptr = driver_ptr,
                .client = codegen.makeClient(Infos, allocator, driver_ptr.asDriver()),
                .owns_driver = true,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.owns_driver) {
                self.driver_ptr.close();
                self.allocator.destroy(self.driver_ptr);
                self.owns_driver = false;
            }
        }

        /// Raw driver access (ad-hoc SQL, migrations, testing).
        pub fn driver(self: *Self) sql_driver.Driver {
            return self.driver_ptr.asDriver();
        }
    };
}

/// Test environment factory: each instance is an isolated in-memory store
/// with fresh migrations. `reset()` drops all schema tables and re-migrates
/// them while retaining the same single connection.
pub fn TestEnv(comptime schemas: anytype) type {
    const Store = StoreEnv(sql_sqlite.SQLiteDriver, schemas);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        store: Store,

        pub const Client = codegen.Client(schemas);

        pub fn init(allocator: std.mem.Allocator) !Self {
            var store = try Store.inMemory(allocator);
            errdefer store.deinit();
            return .{ .allocator = allocator, .store = store };
        }

        /// Drop every schema table and the migration history, then migrate.
        pub fn reset(self: *Self) !void {
            const driver = self.store.driver_ptr.asDriver();
            inline for (schemas) |info| {
                const drop_sql = "DROP TABLE IF EXISTS \"" ++ info.table_name ++ "\"";
                _ = try driver.exec(drop_sql, &.{});
            }
            _ = try driver.exec("DROP TABLE IF EXISTS \"zent_schema_migrations\"", &.{});
            try sql_schema.migrateSchema(self.allocator, driver, schemas);
        }

        pub fn deinit(self: *Self) void {
            self.store.deinit();
        }
    };
}

/// Pooled store: a connection pool plus a root client whose driver borrows
/// and releases connections per operation (thread-safe). The connect factory
/// closes over the path via `connectCtx`, so lazy connections created after
/// open() still use the right file.
pub fn PooledEnv(comptime Driver: type, comptime Infos: anytype) type {
    const ConnectCtx = struct {
        path: []u8,
    };
    const Pool = sql_pool.ConnPool(Driver);

    return struct {
        const Self = @This();
        pub const Client = codegen.Client(Infos);

        pub const Options = struct {
            min_connections: usize = 1,
            max_connections: usize = 8,
            migrate: sql_schema.MigrateOptions = .{},
        };

        allocator: std.mem.Allocator,
        /// Pool is heap-allocated so the generated client's `Driver.ptr`
        /// stays valid when PooledEnv is returned/copied by value.
        pool: *Pool,
        client: Client,
        connect_ctx: *ConnectCtx,

        pub fn open(allocator: std.mem.Allocator, path: []const u8, opts: Options) !Self {
            const connect_ctx = try allocator.create(ConnectCtx);
            errdefer allocator.destroy(connect_ctx);
            connect_ctx.* = .{ .path = try allocator.dupe(u8, path) };
            errdefer allocator.free(connect_ctx.path);

            const pool = try allocator.create(Pool);
            errdefer allocator.destroy(pool);
            pool.* = try Pool.init(allocator, .{
                .min_connections = opts.min_connections,
                .max_connections = opts.max_connections,
                .connect_ctx = connect_ctx,
                .connectCtx = struct {
                    fn f(ctx: ?*anyopaque, a: std.mem.Allocator) anyerror!Driver {
                        const c: *const ConnectCtx = @ptrCast(@alignCast(ctx.?));
                        return Driver.open(a, c.path);
                    }
                }.f,
            });
            errdefer pool.deinit();

            // Migrate once on a borrowed connection; the pool is pre-warmed
            // (min_connections >= 1) so every connection sees the schema.
            {
                var conn = try pool.borrow();
                defer pool.release(conn);
                try sql_schema.migrateSchemaWithOptions(allocator, conn.asDriver(), Infos, opts.migrate);
            }

            return .{
                .allocator = allocator,
                .pool = pool,
                .client = codegen.makeClient(Infos, allocator, pool.asDriver()),
                .connect_ctx = connect_ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            self.pool.deinit();
            self.allocator.destroy(self.pool);
            self.allocator.free(self.connect_ctx.path);
            self.allocator.destroy(self.connect_ctx);
            self.* = undefined;
        }
    };
}

/// Sharded store: one driver + migrated client per shard, routed by tenant
/// through `zent.shard.ShardSet` (explicit map + hash fallback).
pub fn ShardedEnv(comptime Driver: type, comptime Infos: anytype) type {
    return struct {
        const Self = @This();
        pub const Client = codegen.Client(Infos);

        allocator: std.mem.Allocator,
        drivers: []*Driver,
        clients: []Client,
        shards: shard_mod.ShardSet(Infos),

        /// Open one shard per entry in `paths`, migrating each schema.
        pub fn open(allocator: std.mem.Allocator, paths: []const []const u8) !Self {
            if (paths.len == 0) return error.NoShards;
            const drivers = try allocator.alloc(*Driver, paths.len);
            errdefer allocator.free(drivers);
            const clients = try allocator.alloc(Client, paths.len);
            errdefer allocator.free(clients);
            var router = shard_mod.ShardRouter.init(allocator, paths.len);
            errdefer router.deinit();

            for (paths, 0..) |p, i| {
                const dp = try allocator.create(Driver);
                errdefer allocator.destroy(dp);
                dp.* = try Driver.open(allocator, p);
                errdefer dp.close();
                try sql_schema.migrateSchema(allocator, dp.asDriver(), Infos);
                drivers[i] = dp;
                clients[i] = codegen.makeClient(Infos, allocator, dp.asDriver());
            }

            var shards = try shard_mod.ShardSet(Infos).init(allocator, router, clients);
            errdefer shards.deinit();
            return .{
                .allocator = allocator,
                .drivers = drivers,
                .clients = clients,
                .shards = shards,
            };
        }

        pub fn deinit(self: *Self) void {
            self.shards.deinit();
            self.allocator.free(self.clients);
            for (self.drivers) |dp| {
                dp.close();
                self.allocator.destroy(dp);
            }
            self.allocator.free(self.drivers);
            self.* = undefined;
        }

        pub fn clientForTenant(self: *Self, tenant_id: i64) *Client {
            return self.shards.clientForTenant(tenant_id);
        }

        pub fn assignTenant(self: *Self, tenant_id: i64, shard_index: usize) !void {
            try self.shards.router.assignTenant(tenant_id, shard_index);
        }

        /// Idempotent rebalance: move a tenant to another shard.
        pub fn rebalance(self: *Self, tenant_id: i64, to_shard: usize) !bool {
            return self.shards.rebalance(tenant_id, to_shard);
        }
    };
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

const field = @import("core/field.zig");
const Schema = @import("core/schema.zig").Schema;
const buildGraph = @import("codegen/graph.zig").buildGraph;
const deinitEntity = @import("codegen/entity.zig").deinitEntity;

const Account = Schema("Account", .{
    .fields = &.{
        field.Int("tenant_id"),
        field.String("name"),
    },
});
const graph = buildGraph(&.{Account});
const TestInfos = graph.types;

test "StoreEnv open/deinit lifecycle" {
    const allocator = testing.allocator;
    var env = try StoreEnv(sql_sqlite.SQLiteDriver, TestInfos).open(allocator, ":memory:");
    defer env.deinit();

    var b = try env.client.account.Create();
    defer b.deinit();
    _ = try b.setFieldValue("tenant_id", @as(i64, 1));
    _ = try b.setFieldValue("name", "acme");
    var row = try b.Save();
    defer deinitEntity(TestInfos, TestInfos[0], &row, allocator);
    try testing.expect(row.id > 0);
}

test "TestEnv init + reset drops and re-migrates" {
    const allocator = testing.allocator;
    var env = try TestEnv(TestInfos).init(allocator);
    defer env.deinit();

    var b = try env.store.client.account.Create();
    defer b.deinit();
    _ = try b.setFieldValue("tenant_id", @as(i64, 1));
    _ = try b.setFieldValue("name", "seed");
    var row = try b.Save();
    defer deinitEntity(TestInfos, TestInfos[0], &row, allocator);

    try env.reset();
    var q = env.store.client.account.Query();
    defer q.deinit();
    var rows = try q.All();
    defer {
        for (rows.items) |*e| deinitEntity(TestInfos, TestInfos[0], e, allocator);
        rows.deinit();
    }
    try testing.expectEqual(@as(usize, 0), rows.items.len);
}

test "PooledEnv opens, migrates and serves queries via the pool driver" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/pool.db", .{tmp.sub_path});
    defer allocator.free(path);

    var env = try PooledEnv(sql_sqlite.SQLiteDriver, TestInfos).open(allocator, path, .{
        .min_connections = 2,
        .max_connections = 4,
    });
    defer env.deinit();

    // Write through the pooled root client (borrows a connection per op).
    var b = try env.client.account.Create();
    defer b.deinit();
    _ = try b.setFieldValue("tenant_id", @as(i64, 1));
    _ = try b.setFieldValue("name", "pooled");
    var row = try b.Save();
    defer deinitEntity(TestInfos, TestInfos[0], &row, allocator);

    var q = env.client.account.Query();
    defer q.deinit();
    var rows = try q.All();
    defer {
        for (rows.items) |*e| deinitEntity(TestInfos, TestInfos[0], e, allocator);
        rows.deinit();
    }
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("pooled", rows.items[0].name);
}

test "ShardedEnv routes tenants and rebalances idempotently" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_a = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/shard_a.db", .{tmp.sub_path});
    defer allocator.free(path_a);
    const path_b = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/shard_b.db", .{tmp.sub_path});
    defer allocator.free(path_b);

    var env = try ShardedEnv(sql_sqlite.SQLiteDriver, TestInfos).open(allocator, &.{ path_a, path_b });
    defer env.deinit();
    try env.assignTenant(1, 0);
    try env.assignTenant(2, 1);

    inline for (.{ .{ 1, "t1-a" }, .{ 2, "t2-b" } }) |case| {
        var b = try env.clientForTenant(case[0]).account.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", @as(i64, case[0]));
        _ = try b.setFieldValue("name", case[1]);
        var row = try b.Save();
        defer deinitEntity(TestInfos, TestInfos[0], &row, allocator);
    }

    var q = env.clientForTenant(1).account.Query();
    defer q.deinit();
    _ = try q.Where(.{env.clientForTenant(1).account.predicates.tenant_idEQ(.{ .int = 1 })});
    var rows = try q.All();
    defer {
        for (rows.items) |*e| deinitEntity(TestInfos, TestInfos[0], e, allocator);
        rows.deinit();
    }
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("t1-a", rows.items[0].name);

    // Idempotent rebalance: tenant 1 -> shard 1.
    try testing.expect(try env.rebalance(1, 1));
    try testing.expect(!try env.rebalance(1, 1));
    var q2 = env.clientForTenant(1).account.Query();
    defer q2.deinit();
    _ = try q2.Where(.{env.clientForTenant(1).account.predicates.tenant_idEQ(.{ .int = 1 })});
    var rows2 = try q2.All();
    defer {
        for (rows2.items) |*e| deinitEntity(TestInfos, TestInfos[0], e, allocator);
        rows2.deinit();
    }
    try testing.expectEqual(@as(usize, 0), rows2.items.len);
}
