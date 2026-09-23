//! `std.testing.checkAllAllocationFailures` over the assembly paths that build
//! something owned out of several allocations.
//!
//! The repository's whole ownership story is errdefer chains: a fragment, a
//! query, a plan — each assembled from a handful of `allocPrint`/`dupe`/
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
const Dialect = @import("../sql/dialect.zig").Dialect;
const TypeInfo = graph_mod.TypeInfo;

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
    // allocates while collecting predicates, while rendering the builder's
    // buffer, and once more when ownership is handed over.
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
            try std.testing.expect(frag.sql.len > 0);
            try std.testing.expect(frag.args.len == 1);
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
