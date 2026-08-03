//! Outbox pattern for zent - the schema-as-code counterpart of zmsaas'
//! `zigmodu.OutboxPublisher/Poller`. Domain events are written in the SAME
//! transaction as the business write (pass `tx.client`), so a commit makes
//! the events visible atomically with the change; a background dispatcher
//! polls pending rows and publishes them with at-least-once semantics
//! (status + attempts drive retries).
//!
//! Wiring:
//!   const infos = zent.codegen.graph.buildGraph(&.{
//!       model.Tenant, model.Product, zent.outbox.OutboxMessage,
//!   }).types;
//!   const Outbox = zent.outbox.Outbox(infos, zent.outbox.info);
//!   // inside a transaction:
//!   var tx = try zent.codegen.beginTx(infos, client);
//!   ... business writes via tx.client ...
//!   _ = try Outbox.enqueue(allocator, tx.client, now_ms, .{ ... });
//!   try tx.commit();          // event committed atomically
//!   // after commit:
//!   _ = try Outbox.dispatch(allocator, client, now_ms, publisher, 100);

const std = @import("std");
const field = @import("core/field.zig");
const Schema = @import("core/schema.zig").Schema;
const fromSchema = @import("codegen/graph.zig").fromSchema;
const TypeInfo = @import("codegen/graph.zig").TypeInfo;
const deinitEntity = @import("codegen/entity.zig").deinitEntity;
const sql = @import("sql/builder.zig");

/// Outbox table schema - include this type in your schema list so the
/// generated client exposes the `outbox_message` entity.
pub const OutboxMessage = Schema("OutboxMessage", .{
    .fields = &.{
        field.String("aggregate_type"),
        field.Int("aggregate_id"),
        field.String("event_type"),
        field.String("payload"),
        field.String("status"),
        field.Int("attempts"),
        field.Time("created_at"),
        field.Time("published_at"),
    },
});

pub const info: TypeInfo = fromSchema(OutboxMessage);

pub const Status = struct {
    pub const pending = "pending";
    pub const published = "published";
    pub const failed = "failed";
};

pub const EnqueueInput = struct {
    aggregate_type: []const u8,
    aggregate_id: i64,
    event_type: []const u8,
    payload: []const u8,
};

/// A pending outbox row. String fields are owned by the caller (duped into
/// the allocator passed to `pending`); free with `freeEntries`.
pub const Entry = struct {
    id: i64,
    aggregate_type: []const u8,
    aggregate_id: i64,
    event_type: []const u8,
    payload: []const u8,
    attempts: i64,
    created_at: i64,
};

pub const Publisher = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, entry: Entry) anyerror!void,
};

/// Outbox operations bound to a generated client whose `infos` include
/// `OutboxMessage`. `client` is the root Client - pass `tx.client` inside a
/// transaction so enqueue shares the transaction with business writes.
pub fn Outbox(comptime infos: []const TypeInfo, comptime outbox_info: TypeInfo) type {
    return struct {
        pub fn enqueue(client: anytype, now_ms: i64, msg: EnqueueInput) !i64 {
            const ec = @field(client, "outbox_message");
            var b = try ec.Create();
            defer b.deinit();
            _ = try b.setFieldValue("aggregate_type", msg.aggregate_type);
            _ = try b.setFieldValue("aggregate_id", msg.aggregate_id);
            _ = try b.setFieldValue("event_type", msg.event_type);
            _ = try b.setFieldValue("payload", msg.payload);
            _ = try b.setFieldValue("status", Status.pending);
            _ = try b.setFieldValue("attempts", @as(i64, 0));
            _ = try b.setFieldValue("created_at", now_ms);
            _ = try b.setFieldValue("published_at", @as(i64, 0));
            var row = try b.Save();
            defer deinitEntity(infos, outbox_info, &row, ec.allocator);
            return row.id;
        }

        /// Enqueue inside a transaction (atomic with the business write).
        pub fn enqueueTx(tx: anytype, now_ms: i64, msg: EnqueueInput) !i64 {
            return enqueue(tx.client, now_ms, msg);
        }

        /// Fetch up to `limit` pending rows, oldest first. Caller frees the
        /// returned slice + strings via `freeEntries`.
        pub fn pending(allocator: std.mem.Allocator, client: anytype, limit: usize) ![]Entry {
            const ec = @field(client, "outbox_message");
            var q = ec.Query();
            defer q.deinit();
            _ = try q.Where(.{ec.predicates.statusEQ(.{ .string = Status.pending })});
            _ = try q.OrderBy(&.{sql.OrderAsc("created_at")});
            _ = q.Limit(limit);
            var found = try q.All();
            defer {
                for (found.items) |*e| deinitEntity(infos, outbox_info, e, ec.allocator);
                found.deinit();
            }
            const out = try allocator.alloc(Entry, found.items.len);
            errdefer allocator.free(out);
            for (found.items, 0..) |e, i| {
                out[i] = .{
                    .id = e.id,
                    .aggregate_type = try allocator.dupe(u8, e.aggregate_type),
                    .aggregate_id = e.aggregate_id,
                    .event_type = try allocator.dupe(u8, e.event_type),
                    .payload = try allocator.dupe(u8, e.payload),
                    .attempts = e.attempts,
                    .created_at = e.created_at,
                };
            }
            return out;
        }

        pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
            for (entries) |e| {
                allocator.free(e.aggregate_type);
                allocator.free(e.event_type);
                allocator.free(e.payload);
            }
            allocator.free(entries);
        }

        pub fn markPublished(allocator: std.mem.Allocator, client: anytype, id: i64, now_ms: i64) !void {
            _ = allocator;
            const ec = @field(client, "outbox_message");
            var b = ec.Update();
            defer b.deinit();
            _ = try b.setFieldValue("status", Status.published);
            _ = try b.setFieldValue("published_at", now_ms);
            _ = try b.Where(.{ec.predicates.idEQ(.{ .int = id })});
            _ = try b.Save();
        }

        pub fn markFailed(allocator: std.mem.Allocator, client: anytype, id: i64, attempts: i64) !void {
            _ = allocator;
            const ec = @field(client, "outbox_message");
            var b = ec.Update();
            defer b.deinit();
            _ = try b.setFieldValue("status", Status.failed);
            _ = try b.setFieldValue("attempts", attempts);
            _ = try b.Where(.{ec.predicates.idEQ(.{ .int = id })});
            _ = try b.Save();
        }

        /// Requeue a failed row for another attempt (status back to pending
        /// with an incremented attempt counter).
        pub fn requeue(allocator: std.mem.Allocator, client: anytype, id: i64, attempts: i64) !void {
            _ = allocator;
            const ec = @field(client, "outbox_message");
            var b = ec.Update();
            defer b.deinit();
            _ = try b.setFieldValue("status", Status.pending);
            _ = try b.setFieldValue("attempts", attempts);
            _ = try b.Where(.{ec.predicates.idEQ(.{ .int = id })});
            _ = try b.Save();
        }

        /// At-least-once dispatch: publish each pending row, marking it
        /// published on success; on error the row is requeued (pending,
        /// attempts+1) until `max_attempts` is reached, then marked failed.
        /// Returns the number of successfully dispatched rows.
        pub fn dispatch(
            allocator: std.mem.Allocator,
            client: anytype,
            now_ms: i64,
            publisher: Publisher,
            batch_size: usize,
            max_attempts: usize,
        ) !usize {
            const entries = try pending(allocator, client, batch_size);
            defer freeEntries(allocator, entries);
            var dispatched: usize = 0;
            for (entries) |e| {
                publisher.call(publisher.ctx, e) catch {
                    const next = e.attempts + 1;
                    if (next >= max_attempts) {
                        try markFailed(allocator, client, e.id, next);
                    } else {
                        try requeue(allocator, client, e.id, next);
                    }
                    continue;
                };
                try markPublished(allocator, client, e.id, now_ms);
                dispatched += 1;
            }
            return dispatched;
        }
    };
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

const TestSchema = struct {
    const Product = Schema("Product", .{
        .fields = &.{
            field.Int("tenant_id"),
            field.String("name"),
        },
    });
};

test "outbox enqueue + dispatch + retry semantics" {
    const allocator = testing.allocator;
    const graph = comptime @import("codegen/graph.zig").buildGraph(&.{ TestSchema.Product, OutboxMessage });
    const infos = graph.types;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");
    const client_mod = @import("codegen/client.zig");
    const OutboxOps = Outbox(infos, info);

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);

    const root = client_mod.makeClient(infos, allocator, driver.asDriver());

    // Transactional enqueue: rollback must discard the event.
    {
        var tx = try client_mod.beginTx(infos, root);
        defer tx.deinit();
        _ = try OutboxOps.enqueueTx(tx, 1000, .{
            .aggregate_type = "product",
            .aggregate_id = 1,
            .event_type = "product.created",
            .payload = "{\"id\":1}",
        });
        try tx.rollback();
    }
    const after_rollback = try OutboxOps.pending(allocator, root, 10);
    defer OutboxOps.freeEntries(allocator, after_rollback);
    try testing.expectEqual(@as(usize, 0), after_rollback.len);

    // Commit makes the event visible (atomic with the business write).
    {
        var tx = try client_mod.beginTx(infos, root);
        defer tx.deinit();
        _ = try OutboxOps.enqueueTx(tx, 2000, .{
            .aggregate_type = "product",
            .aggregate_id = 1,
            .event_type = "product.created",
            .payload = "{\"id\":1}",
        });
        _ = try OutboxOps.enqueueTx(tx, 2000, .{
            .aggregate_type = "product",
            .aggregate_id = 2,
            .event_type = "product.updated",
            .payload = "{\"id\":2}",
        });
        try tx.commit();
    }

    // First dispatch: second event fails once, first succeeds.
    const PubCtx = struct {
        seen_created: bool = false,
        seen_updated: bool = false,
        count: usize = 0,
        fail_once: bool,
    };
    var pub_ctx = PubCtx{
        .fail_once = true,
    };
    const dispatched = try OutboxOps.dispatch(allocator, root, 3000, .{
        .ctx = &pub_ctx,
        .call = struct {
            fn call(ctx: ?*anyopaque, entry: Entry) anyerror!void {
                const c: *PubCtx = @ptrCast(@alignCast(ctx.?));
                if (std.mem.eql(u8, entry.event_type, "product.created")) c.seen_created = true;
                if (std.mem.eql(u8, entry.event_type, "product.updated")) c.seen_updated = true;
                c.count += 1;
                if (c.fail_once and entry.aggregate_id == 2) return error.PublisherDown;
            }
        }.call,
    }, 10, 3);
    try testing.expectEqual(@as(usize, 1), dispatched);
    try testing.expect(pub_ctx.seen_created);
    // Both rows were attempted; the failing one did not count as dispatched.
    try testing.expectEqual(@as(usize, 2), pub_ctx.count);

    // Second dispatch: the failed row retries and succeeds.
    pub_ctx.fail_once = false;
    const dispatched2 = try OutboxOps.dispatch(allocator, root, 3000, .{
        .ctx = &pub_ctx,
        .call = struct {
            fn call(ctx: ?*anyopaque, entry: Entry) anyerror!void {
                const c: *PubCtx = @ptrCast(@alignCast(ctx.?));
                if (std.mem.eql(u8, entry.event_type, "product.updated")) c.seen_updated = true;
                c.count += 1;
            }
        }.call,
    }, 10, 3);
    try testing.expectEqual(@as(usize, 1), dispatched2);
    try testing.expect(pub_ctx.seen_updated);
    try testing.expectEqual(@as(usize, 3), pub_ctx.count);

    // Nothing left pending.
    const remaining = try OutboxOps.pending(allocator, root, 10);
    defer OutboxOps.freeEntries(allocator, remaining);
    try testing.expectEqual(@as(usize, 0), remaining.len);
}

test "outbox failed rows carry attempts" {
    const allocator = testing.allocator;
    const graph = comptime @import("codegen/graph.zig").buildGraph(&.{ TestSchema.Product, OutboxMessage });
    const infos = graph.types;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");
    const client_mod = @import("codegen/client.zig");
    const OutboxOps = Outbox(infos, info);

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);
    const root = client_mod.makeClient(infos, allocator, driver.asDriver());

    const id = try OutboxOps.enqueue(root, 1, .{
        .aggregate_type = "order",
        .aggregate_id = 9,
        .event_type = "order.placed",
        .payload = "{}",
    });
    try OutboxOps.markFailed(allocator, root, id, 2);

    var q = @field(root, "outbox_message").Query();
    defer q.deinit();
    const ec = @field(root, "outbox_message");
    _ = try q.Where(.{ec.predicates.idEQ(.{ .int = id })});
    var found = try q.All();
    defer {
        for (found.items) |*e| deinitEntity(infos, info, e, allocator);
        found.deinit();
    }
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqualStrings(Status.failed, found.items[0].status);
    try testing.expectEqual(@as(i64, 2), found.items[0].attempts);
}
