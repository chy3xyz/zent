//! Shard routing for zent - maps a tenant_id to a per-shard generated
//! Client. Pure routing (explicit tenant -> shard map with hash fallback),
//! mirroring zmsaas/zigmodu ShardRouter without sqlx connection pools:
//! the app opens one driver per shard and hands the clients to `ShardSet`.
//!
//! Usage:
//!   const Shards = zent.shard.ShardSet(infos);
//!   var router = zent.shard.ShardRouter.init(allocator, 2);
//!   defer router.deinit();
//!   try router.assignTenant(1, 0);   // explicit
//!   try router.assignTenant(2, 1);
//!   var shards = try Shards.init(allocator, router, &.{ client_a, client_b });
//!   defer shards.deinit();
//!   const client = shards.clientForTenant(tenant_id);  // routed *Client

const std = @import("std");
const codegen = @import("codegen/client.zig");
const TypeInfo = @import("codegen/graph.zig").TypeInfo;

/// Tenant-to-shard routing: explicit map first, hash fallback otherwise.
pub const ShardRouter = struct {
    allocator: std.mem.Allocator,
    shard_count: usize,
    tenant_map: std.AutoHashMap(i64, usize),

    pub fn init(allocator: std.mem.Allocator, shard_count: usize) ShardRouter {
        return .{
            .allocator = allocator,
            .shard_count = shard_count,
            .tenant_map = std.AutoHashMap(i64, usize).init(allocator),
        };
    }

    pub fn deinit(self: *ShardRouter) void {
        self.tenant_map.deinit();
        self.* = undefined;
    }

    /// Pin a tenant to a shard index (must be < shard_count).
    pub fn assignTenant(self: *ShardRouter, tenant_id: i64, shard_index: usize) !void {
        if (shard_index >= self.shard_count) return error.InvalidShardIndex;
        try self.tenant_map.put(tenant_id, shard_index);
    }

    /// Route a tenant: explicit mapping wins, otherwise a stable hash.
    pub fn route(self: *const ShardRouter, tenant_id: i64) usize {
        if (self.tenant_map.get(tenant_id)) |idx| return idx;
        const hash: u64 = @intCast(tenant_id);
        return @intCast(hash % self.shard_count);
    }

    /// Idempotently move a tenant to `new_index` (rebalance). No-op when the
    /// tenant is already routed there — whether via an explicit mapping or
    /// the hash fallback — so re-running a rebalance plan is safe.
    pub fn moveTenant(self: *ShardRouter, tenant_id: i64, new_index: usize) !bool {
        if (new_index >= self.shard_count) return error.InvalidShardIndex;
        if (self.route(tenant_id) == new_index) return false;
        try self.tenant_map.put(tenant_id, new_index);
        return true;
    }
};

/// A set of per-shard root Clients plus the router that selects among them.
pub fn ShardSet(comptime infos: []const TypeInfo) type {
    return struct {
        const RootClient = codegen.Client(infos);
        const Self = @This();

        allocator: std.mem.Allocator,
        router: ShardRouter,
        clients: []RootClient,

        pub fn init(allocator: std.mem.Allocator, router: ShardRouter, clients: []const RootClient) !Self {
            if (clients.len != router.shard_count) return error.ShardCountMismatch;
            return .{
                .allocator = allocator,
                .router = router,
                .clients = try allocator.dupe(RootClient, clients),
            };
        }

        pub fn deinit(self: *Self) void {
            self.router.deinit();
            self.allocator.free(self.clients);
            self.* = undefined;
        }

        /// Shard index for a tenant.
        pub fn shardOf(self: *const Self, tenant_id: i64) usize {
            return self.router.route(tenant_id);
        }

        /// Routed root client for a tenant.
        pub fn clientForTenant(self: *Self, tenant_id: i64) *RootClient {
            return &self.clients[self.shardOf(tenant_id)];
        }

        /// Client by shard index.
        pub fn clientAt(self: *Self, index: usize) *RootClient {
            return &self.clients[index];
        }

        /// Idempotent rebalance: move a tenant to another shard. Returns true
        /// when the routing actually changed.
        pub fn rebalance(self: *Self, tenant_id: i64, to_shard: usize) !bool {
            return self.router.moveTenant(tenant_id, to_shard);
        }
    };
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

test "ShardRouter explicit map + hash fallback" {
    var router = ShardRouter.init(testing.allocator, 3);
    defer router.deinit();
    try router.assignTenant(10, 1);
    try router.assignTenant(20, 2);
    try testing.expectEqual(@as(usize, 1), router.route(10));
    try testing.expectEqual(@as(usize, 2), router.route(20));
    // Unassigned tenant falls back to a stable hash.
    try testing.expectEqual(router.route(7), router.route(7));
    try testing.expect(router.route(7) < 3);
    try testing.expectError(error.InvalidShardIndex, router.assignTenant(1, 9));
}

test "ShardRouter moveTenant is idempotent" {
    var router = ShardRouter.init(testing.allocator, 3);
    defer router.deinit();
    try router.assignTenant(10, 1);
    // Already explicit -> no-op.
    try testing.expect(!try router.moveTenant(10, 1));
    // Real move.
    try testing.expect(try router.moveTenant(10, 2));
    try testing.expectEqual(@as(usize, 2), router.route(10));
    // Move back -> real change again.
    try testing.expect(try router.moveTenant(10, 1));
    // Hash-routed tenant (route(7) != 0): pinning to a different shard is a
    // real change; repeating the same move is a no-op.
    const hash_shard = router.route(7);
    const other = if (hash_shard == 0) @as(usize, 1) else @as(usize, 0);
    try testing.expect(try router.moveTenant(7, other));
    try testing.expect(!try router.moveTenant(7, other));
    try testing.expectError(error.InvalidShardIndex, router.moveTenant(7, 9));
}

test "ShardSet routes writes to the tenant's shard" {
    const allocator = testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const buildGraph = @import("codegen/graph.zig").buildGraph;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");
    const client_mod = @import("codegen/client.zig");
    const deinitEntity = @import("codegen/entity.zig").deinitEntity;

    const Account = Schema("Account", .{
        .fields = &.{
            field.Int("tenant_id"),
            field.String("name"),
        },
    });
    const graph = comptime buildGraph(&.{Account});
    const infos = graph.types;
    const Shards = ShardSet(infos);

    // Two shards, both migrated.
    var shard_a = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer shard_a.close();
    var shard_b = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer shard_b.close();
    try migrate.migrateSchema(allocator, shard_a.asDriver(), infos);
    try migrate.migrateSchema(allocator, shard_b.asDriver(), infos);

    const client_a = client_mod.makeClient(infos, allocator, shard_a.asDriver());
    const client_b = client_mod.makeClient(infos, allocator, shard_b.asDriver());

    var router = ShardRouter.init(allocator, 2);
    try router.assignTenant(1, 0);
    try router.assignTenant(2, 1);
    const clients: []const Shards.RootClient = &.{ client_a, client_b };
    var shards = try Shards.init(allocator, router, clients);
    defer shards.deinit();

    // Write tenant 1's account to shard A, tenant 2's to shard B.
    {
        var b = try shards.clientForTenant(1).account.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", @as(i64, 1));
        _ = try b.setFieldValue("name", "acme-a");
        var row = try b.Save();
        defer deinitEntity(infos, infos[0], &row, allocator);
    }
    {
        var b = try shards.clientForTenant(2).account.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", @as(i64, 2));
        _ = try b.setFieldValue("name", "globex-b");
        var row = try b.Save();
        defer deinitEntity(infos, infos[0], &row, allocator);
    }

    // Each shard only sees its own row.
    inline for (.{ .{ 0, "acme-a" }, .{ 1, "globex-b" } }) |case| {
        var q = shards.clientAt(case[0]).account.Query();
        defer q.deinit();
        const rows = try q.All();
        defer {
            for (rows.items) |*e| deinitEntity(infos, infos[0], e, allocator);
            rows.deinit();
        }
        try testing.expectEqual(@as(usize, 1), rows.items.len);
        try testing.expectEqualStrings(case[1], rows.items[0].name);
    }
}
