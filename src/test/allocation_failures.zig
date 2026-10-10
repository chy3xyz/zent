//! `std.testing.checkAllAllocationFailures` over the assembly paths that build
//! something owned out of several allocations.
//!
//! The repository's whole ownership story is errdefer chains: a fragment, a
//! query, a plan — each assembled from a handful of `Allocator.print`/`dupe`/
//! `append` calls, each of which can fail with `OutOfMemory` while the earlier
//! ones have already succeeded. Where the chain is wrong the result is a leak,
//! a double free, or an OOM that is swallowed into a value; all three are
//! invisible in the happy path and were found by hand before (the two insert
//! log sites, the eager-load cleanup, `CrudService`'s partial-dupe teardown).
//!
//! `checkAllAllocationFailures` is the mechanical version of that hunt: it runs
//! the function once to count the allocations, then fails each one in turn and
//! asserts the run either completes or fails with `OutOfMemory` — with the
//! allocator's byte ledger balanced, so a leak at any single point fails the
//! test by name and index.

const std = @import("std");
const sql = @import("../sql/builder.zig");
const scope = @import("../codegen/scope.zig");
const graph_mod = @import("../codegen/graph.zig");
const privacy = @import("../privacy/policy.zig");
const field = @import("../core/field.zig");
const schema_mod = @import("../core/schema.zig");
const shard_mod = @import("../shard.zig");
const TypeInfo = graph_mod.TypeInfo;

/// A pass-through allocator whose `remap` always declines, so a list that
/// grows is forced through `alignedAlloc` + copy instead of the in-place
/// `remap` fast path.
///
/// `checkAllAllocationFailures` counts *allocations*, and an `ArrayList`'s
/// growth asks `allocator.remap` first (see `ensureTotalCapacityPrecise`): a
/// remap that happens to succeed counts nothing. Whether it succeeds depends
/// on the addresses a run is given, so on a platform whose allocator can grow
/// in place (`mremap` on Linux) the number of counted allocation points varies
/// run to run and the sweep reports `NondeterministicMemoryUsage` — a failure
/// that is invisible on macOS, where remap declines. Declining every remap
/// makes each growth an alloc+copy the sweep can fail deterministically.
/// `takeQuery`'s `toOwnedSlice` is a remap too, so the same wrapper pins the
/// move-out path.
///
/// The joined-build sweep in `codegen/query.zig` carries the same adapter
/// (kept as a local copy here rather than importing a test-only file from
/// another test).
const NoRemap = struct {
    inner: std.mem.Allocator,

    fn asAllocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.inner.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, alignment, ra);
    }
};

var caaf_scope_pred: sql.Predicate = undefined;

fn caafScopeFilter(ctx: privacy.PrivacyContext) ?*const anyopaque {
    const tenant = ctx.tenant_id orelse return null;
    caaf_scope_pred = sql.EQ("tenant", .{ .int = @intCast(tenant) });
    return @ptrCast(&caaf_scope_pred);
}

const CaafRow = schema_mod.Schema("CaafRow", .{
    .table_name = "caaf_row",
    .fields = &.{ field.String("tenant"), field.String("title") },
    .mixins = &.{@import("../core/mixin.zig").SoftDeleteMixin},
    .soft_delete = true,
    .policy = privacy.Policy{ .rules = &.{ privacy.Allow, privacy.Filter(caafScopeFilter) } },
});

const caaf_graph = graph_mod.buildGraph(&.{CaafRow});
const caaf_infos: []const TypeInfo = caaf_graph.types;

test "scope.forTable unwinds cleanly when any single allocation fails" {
    // Soft delete + a policy filter + an interceptor-free render: the fragment
    // allocates while collecting predicates, once for each of the builder's
    // two preallocated buffers (`sql.Builder.initCapacity` at
    // `codegen/scope.zig:120`), and once more when ownership is handed over by
    // `takeQuery`. (The sweep passes with the old, OOM-swallowing `Builder.init`
    // as well — the next write into the fallback's empty buffer re-raises the
    // failure — so what it pins is the fragment's ownership, not the swallow.)
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(child: std.mem.Allocator) !void {
            // The builder's buffers grow and shrink through `remap`; declining
            // it keeps the counted allocation points fixed (see `NoRemap`).
            var no_remap = NoRemap{ .inner = child };
            const allocator = no_remap.asAllocator();
            var frag = try scope.forTable(
                caaf_infos,
                "caaf_row",
                allocator,
                .sqlite,
                privacy.PrivacyContext{ .tenant_id = 7 },
                null,
                .{},
            );
            defer frag.deinit();
            try std.testing.expect(frag.sql.len > 0);
            try std.testing.expect(frag.args.len == 1);
        }
    }.run, .{});
}

test "scope.forTable on a numbered dialect with an alias unwinds cleanly when any single allocation fails" {
    // The same `sql.Builder.initCapacity` site (`codegen/scope.zig:120`) on the
    // other render shape a caller can ask for: a PostgreSQL fragment, every
    // predicate qualified with the alias the caller's statement uses, and
    // numbering that starts after the four arguments the head already bound —
    // `"t"."deleted_at" IS NULL AND "t"."tenant" = $5`. The placeholder buffer
    // and the qualified-identifier path allocate differently from the SQLite
    // case above, so this is a second, independent pass over the same two
    // preallocations.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(child: std.mem.Allocator) !void {
            var no_remap = NoRemap{ .inner = child };
            const allocator = no_remap.asAllocator();
            var frag = try scope.forTable(
                caaf_infos,
                "caaf_row",
                allocator,
                .postgres,
                privacy.PrivacyContext{ .tenant_id = 7 },
                null,
                .{ .alias = "t", .arg_index = 5 },
            );
            defer frag.deinit();
            try std.testing.expect(std.mem.indexOf(u8, frag.sql, "\"t\".\"deleted_at\" IS NULL") != null);
            try std.testing.expect(std.mem.indexOf(u8, frag.sql, "\"t\".\"tenant\" = $5") != null);
            try std.testing.expectEqual(@as(usize, 1), frag.args.len);
        }
    }.run, .{});
}

test "an assembled SELECT unwinds cleanly when any single allocation fails" {
    // The other half of the same story: identifiers, predicates and bound args
    // are appended into one buffer, and `takeQuery` transfers ownership of the
    // text and the argument slice together.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const t = sql.Table("caaf_row");
            var sel = try sql.Select(allocator, .sqlite, &.{ t.c("id"), t.c("title") });
            // `deinit` is safe after `takeQuery`: that call moves the SQL
            // buffer and args out and leaves them empty.
            defer sel.deinit();
            _ = sel.from(t);
            _ = try sel.where(sql.EQ("tenant", .{ .int = 7 }));
            _ = try sel.where(sql.Like("title", .{ .string = "%a%" }));
            _ = try sel.orderBy(.{ .column = .{ .name = "title", .desc = true } });
            _ = sel.limit(10);
            var q = try sel.takeQuery();
            defer q.deinit();
            try std.testing.expect(q.sql.len > 0);
            try std.testing.expect(q.args.len == 2);
        }
    }.run, .{});
}

test "scope.withClause unwinds cleanly when any single allocation fails" {
    // The clause path copies the fragment under a caller-provided allocator,
    // which is a second owned buffer over the same fragment.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var frag = try scope.forTable(
                caaf_infos,
                "caaf_row",
                allocator,
                .sqlite,
                privacy.PrivacyContext{ .tenant_id = 7 },
                null,
                .{},
            );
            defer frag.deinit();
            const clause = try scope.withClause(frag, allocator, "SELECT * FROM caaf_row", true);
            defer allocator.free(clause);
            try std.testing.expect(std.mem.startsWith(u8, clause, "SELECT * FROM caaf_row AND ("));
        }
    }.run, .{});
}

// ------------------------------------------------------------------
// bulk delete builder
// ------------------------------------------------------------------

test "BulkDeleteBuilder.init unwinds cleanly when any single allocation fails" {
    // `init` owns three allocations: the builder's SQL buffer and its args
    // array (`initCapacity` at `sql/builder.zig:2049`), then the first
    // predicate group appended to `groups`. A failure of that last append is
    // the case the builder's own `errdefer self.b.deinit()` covers — without
    // it the two buffers the struct literal already took ownership of are
    // stranded (measured: remove the `errdefer` and this case fails at
    // `fail_index 2/6`, reporting the 256-byte SQL buffer and the 192-byte args
    // array leaked). `takeQuery` then re-walks the whole statement, including
    // the predicate render and the move-out of both buffers.
    //
    // A predicate is mandatory (Z34): a group-less or predicate-less bulk
    // delete answers `error.NoPredicate` instead of deleting every row, so the
    // case supplies one and pins that `takeQuery` succeeds.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(child: std.mem.Allocator) !void {
            var no_remap = NoRemap{ .inner = child };
            const allocator = no_remap.asAllocator();

            var d = try sql.BulkDeleteBuilder.init(allocator, .sqlite, "caaf_row");
            defer d.deinit();
            _ = try d.where(sql.EQ("tenant", .{ .int = 7 }));

            var q = try d.takeQuery();
            defer q.deinit();
            try std.testing.expect(std.mem.startsWith(u8, q.sql, "DELETE FROM \"caaf_row\" WHERE "));
            try std.testing.expectEqual(@as(usize, 1), q.args.len);
            try std.testing.expectEqual(@as(i64, 7), q.args[0].int);
        }
    }.run, .{});
}

// ------------------------------------------------------------------
// shard routing
// ------------------------------------------------------------------

const ShardAllocDoc = schema_mod.Schema("ShardAllocDoc", .{
    .table_name = "shard_alloc_doc",
    .fields = &.{ field.Int("tenant_id"), field.String("title") },
});

const shard_alloc_infos: []const TypeInfo = graph_mod.buildGraph(&.{ShardAllocDoc}).types;

test "ShardRouter.assignTenant growth unwinds cleanly when any single allocation fails" {
    // 64 tenants walk the map through several capacities, so the sweep fails
    // the initial allocation and every growth rehash in turn; a failure has
    // to leave the map consistent so `deinit` releases exactly what is still
    // allocated.
    const Grow = struct {
        fn run(child: std.mem.Allocator) !void {
            var router = try shard_mod.ShardRouter.init(child, 4);
            defer router.deinit();
            for (0..64) |i| {
                try router.assignTenant(@intCast(i), i % 4);
            }
            try std.testing.expectEqual(@as(usize, 64), router.tenant_map.count());
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Grow.run, .{});
}

test "ShardSet.init's client copy unwinds cleanly when the single allocation fails" {
    const allocator = std.testing.allocator;
    const codegen_client = @import("../codegen/client.zig");
    const sqlite_driver = @import("../sql/sqlite.zig");

    const Shards = shard_mod.ShardSet(shard_alloc_infos);

    // The clients (and the driver behind them) live outside the sweep: the
    // only allocation `init` makes is the `dupe` of the client slice. Since
    // `ShardSet` borrows the router, the set's `deinit` frees exactly that
    // copy while the router's map is released here, by its owner — under the
    // old absorbed-router contract this run double-freed the map.
    var db = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer db.close();
    const client_a = codegen_client.makeClient(shard_alloc_infos, allocator, db.asDriver());
    const client_b = codegen_client.makeClient(shard_alloc_infos, allocator, db.asDriver());
    const clients: []const Shards.RootClient = &.{ client_a, client_b };

    var router = try shard_mod.ShardRouter.init(allocator, clients.len);
    defer router.deinit();
    try router.assignTenant(1, 0);

    const InitSweep = struct {
        fn run(child: std.mem.Allocator, r: shard_mod.ShardRouter, cs: []const Shards.RootClient) !void {
            var shards = try Shards.init(child, r, cs);
            defer shards.deinit();
            try std.testing.expectEqual(cs.len, shards.clients.len);
            // The borrowed router keeps answering through the set.
            try std.testing.expectEqual(@as(usize, 0), shards.shardOf(1));
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, InitSweep.run, .{ router, clients });
}
