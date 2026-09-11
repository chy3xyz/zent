//! Outbox pattern for zent - the schema-as-code counterpart of zmsaas'
//! `zigmodu.OutboxPublisher/Poller`. Domain events are written in the SAME
//! transaction as the business write (pass `tx.client`), so a commit makes
//! the events visible atomically with the change; a background dispatcher
//! claims pending rows (pending -> processing) and publishes them with
//! at-least-once semantics (status + attempts drive retries). Claiming is
//! atomic, so concurrent dispatchers never publish the same row twice.
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
//!   // periodic sweeper (crash recovery):
//!   _ = try Outbox.requeueStale(allocator, client, 300);

const std = @import("std");
const field = @import("core/field.zig");
const Schema = @import("core/schema.zig").Schema;
const fromSchema = @import("codegen/graph.zig").fromSchema;
const TypeInfo = @import("codegen/graph.zig").TypeInfo;
const deinitEntity = @import("codegen/entity.zig").deinitEntity;
const sql_driver = @import("sql/driver.zig");
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
        // Epoch-ms stamp written by `claim` when a row moves to `processing`;
        // cleared by `markPublished` / `markFailed` / `requeue`.
        // `requeueStale` uses it to reclaim rows stranded by a dispatcher that
        // died mid-publish. Optional, so adding it to an existing table is a
        // plain ADD COLUMN migration: `migrateSchema` adds it automatically,
        // but downgrading past this version must DROP the column by hand.
        field.Time("claimed_at").Optional(),
    },
});

pub const info: TypeInfo = fromSchema(OutboxMessage);

pub const Status = struct {
    pub const pending = "pending";
    /// Rows claimed by a dispatcher and awaiting publish/requeue. `status` is
    /// a plain string column, so adding this value needs no DDL change.
    pub const processing = "processing";
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

/// Wall-clock milliseconds since the Unix epoch (the unit used for
/// `created_at` / `claimed_at`). `claim` and `requeueStale` read the same
/// clock, so claim stamps and the staleness cutoff stay comparable. Falls
/// back to 0 if the syscall fails.
fn nowMs() i64 {
    var tv: std.c.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) != 0) return 0;
    return @as(i64, @intCast(tv.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(tv.usec)), std.time.us_per_ms);
}

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

        /// Fetch up to `limit` pending rows, oldest first, WITHOUT claiming
        /// them. Intended for inspection/backfill; to drive a dispatcher when
        /// more than one may run, use `claim` instead so two dispatchers do
        /// not pick the same rows.
        /// Caller frees the returned slice + strings via `freeEntries`.
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
            _ = try b.setFieldValue("claimed_at", @as(?i64, null));
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
            _ = try b.setFieldValue("claimed_at", @as(?i64, null));
            _ = try b.Where(.{ec.predicates.idEQ(.{ .int = id })});
            _ = try b.Save();
        }

        /// Requeue a failed row for another attempt (status back to pending
        /// with an incremented attempt counter) and clear `claimed_at`.
        pub fn requeue(allocator: std.mem.Allocator, client: anytype, id: i64, attempts: i64) !void {
            _ = allocator;
            const ec = @field(client, "outbox_message");
            var b = ec.Update();
            defer b.deinit();
            _ = try b.setFieldValue("status", Status.pending);
            _ = try b.setFieldValue("attempts", attempts);
            _ = try b.setFieldValue("claimed_at", @as(?i64, null));
            _ = try b.Where(.{ec.predicates.idEQ(.{ .int = id })});
            _ = try b.Save();
        }

        /// Reclaim `processing` rows whose claim has gone stale, returning them
        /// to `pending` with `claimed_at` cleared, and return how many rows were
        /// affected.
        ///
        /// A row is stale when its `claimed_at` is older than
        /// `now - older_than_secs * 1000` (both in epoch ms). A NULL
        /// `claimed_at` is always stale: it covers rows claimed before this
        /// column existed and rows whose claim stamp was never written, so NULL
        /// rows are reclaimed regardless of the threshold. `older_than_secs <= 0`
        /// skips the age test entirely and reclaims every `processing` row
        /// ("start over").
        ///
        /// This is the crash-recovery companion to `claim`: a dispatcher that
        /// died after claiming leaves rows in `processing`, and this call moves
        /// them back for a later `dispatch`/`claim`. Run it from a periodic
        /// sweeper (e.g. every minute) with a threshold several times the
        /// longest expected publish, so a live dispatcher's in-flight rows are
        /// not stolen. The UPDATE is idempotent, so overlapping sweepers are
        /// harmless.
        pub fn requeueStale(allocator: std.mem.Allocator, client: anytype, older_than_secs: i64) !usize {
            const d = @field(client, "driver");
            const table = outbox_info.table_name;

            var b = sql.Update(allocator, d.dialect(), table);
            defer b.deinit();
            _ = try b.set("status", .{ .string = Status.pending });
            _ = try b.set("claimed_at", .null);
            _ = try b.where(sql.EQ("status", .{ .string = Status.processing }));
            if (older_than_secs > 0) {
                const now_ms = nowMs();
                const age_ms = std.math.mul(i64, older_than_secs, std.time.ms_per_s) catch std.math.maxInt(i64);
                const cutoff = now_ms -| age_ms;
                const never_claimed = sql.IsNull("claimed_at");
                const claimed_too_long_ago = sql.LT("claimed_at", .{ .int = cutoff });
                _ = try b.where(sql.Or(&never_claimed, &claimed_too_long_ago));
            }
            const q = try b.query();
            const res = try d.exec(q.sql, q.args);
            return res.rows_affected;
        }

        /// Atomically claim up to `limit` pending rows for this dispatcher by
        /// flipping them to `processing` in the same statement (SQLite /
        /// PostgreSQL) or transaction (MySQL) that selects them, stamping
        /// `claimed_at` with the claim time (epoch ms). A concurrent claimer
        /// therefore never gets the same rows: PostgreSQL/MySQL use
        /// `FOR UPDATE SKIP LOCKED` so a second dispatcher skips locked rows
        /// instead of blocking on them; SQLite's single-writer `UPDATE` is
        /// atomic on its own.
        ///
        /// The returned entries are owned by the caller; free them with
        /// `freeEntries`. Claimed rows stay `processing` until
        /// `markPublished` / `markFailed` / `requeue` moves them on (each clears
        /// `claimed_at`).
        ///
        /// Crash recovery: if the process dies after a claim the row is left in
        /// `processing` with a stale `claimed_at`; no dispatcher picks it up on
        /// its own. Call `requeueStale` from a periodic sweeper to return such
        /// rows to `pending`.
        pub fn claim(allocator: std.mem.Allocator, client: anytype, limit: usize) ![]Entry {
            const d = @field(client, "driver");
            const dialect = d.dialect();
            const table = outbox_info.table_name;
            const now = nowMs();

            // SQLite and PostgreSQL select and flip the rows in one statement,
            // so the claim is atomic without an explicit transaction.
            // PostgreSQL adds FOR UPDATE SKIP LOCKED so a concurrent claimer
            // skips locked rows instead of blocking.
            if (std.mem.eql(u8, dialect.name, "postgres")) {
                const q = comptime std.fmt.comptimePrint(
                    "UPDATE \"{s}\" SET \"status\" = $1, \"claimed_at\" = $2 WHERE \"id\" IN (" ++
                        "SELECT \"id\" FROM \"{s}\" WHERE \"status\" = $3 " ++
                        "ORDER BY \"created_at\" ASC LIMIT $4 FOR UPDATE SKIP LOCKED" ++
                        ") RETURNING \"id\", \"aggregate_type\", \"aggregate_id\", " ++
                        "\"event_type\", \"payload\", \"attempts\", \"created_at\"",
                    .{ table, table },
                );
                var rows = try d.query(q, &.{
                    .{ .string = Status.processing },
                    .{ .int = now },
                    .{ .string = Status.pending },
                    .{ .int = @intCast(limit) },
                });
                defer rows.deinit();
                return try collectRows(allocator, rows);
            }

            if (std.mem.eql(u8, dialect.name, "sqlite3")) {
                const q = comptime std.fmt.comptimePrint(
                    "UPDATE \"{s}\" SET \"status\" = ?, \"claimed_at\" = ? WHERE \"id\" IN (" ++
                        "SELECT \"id\" FROM \"{s}\" WHERE \"status\" = ? " ++
                        "ORDER BY \"created_at\" ASC LIMIT ?" ++
                        ") RETURNING \"id\", \"aggregate_type\", \"aggregate_id\", " ++
                        "\"event_type\", \"payload\", \"attempts\", \"created_at\"",
                    .{ table, table },
                );
                var rows = try d.query(q, &.{
                    .{ .string = Status.processing },
                    .{ .int = now },
                    .{ .string = Status.pending },
                    .{ .int = @intCast(limit) },
                });
                defer rows.deinit();
                return try collectRows(allocator, rows);
            }

            // MySQL has no UPDATE ... RETURNING, so reserve the rows inside a
            // transaction: SELECT ... FOR UPDATE SKIP LOCKED locks them (a
            // concurrent claimer skips them), the UPDATE flips them to
            // processing, and the commit releases the locks with the rows
            // already claimed. Every row is stamped with the same `now` read
            // above so the batch shares one claim time.
            const select_sql = comptime std.fmt.comptimePrint(
                "SELECT `id`, `aggregate_type`, `aggregate_id`, `event_type`, " ++
                    "`payload`, `attempts`, `created_at` FROM `{s}` " ++
                    "WHERE `status` = ? ORDER BY `created_at` ASC LIMIT ? FOR UPDATE SKIP LOCKED",
                .{table},
            );
            const update_sql = comptime std.fmt.comptimePrint(
                "UPDATE `{s}` SET `status` = ?, `claimed_at` = ? WHERE `id` = ?",
                .{table},
            );

            const tx = if (d.inTransaction())
                try d.beginSavepoint("zent_outbox_claim")
            else
                try d.beginTx();
            defer tx.deinit();
            errdefer tx.rollback() catch {};

            var rows = try tx.query(select_sql, &.{
                .{ .string = Status.pending },
                .{ .int = @intCast(limit) },
            });
            defer rows.deinit();
            const claimed = try collectRows(allocator, rows);
            errdefer freeEntries(allocator, claimed);

            for (claimed) |e| {
                _ = try tx.exec(update_sql, &.{
                    .{ .string = Status.processing },
                    .{ .int = now },
                    .{ .int = e.id },
                });
            }
            try tx.commit();
            return claimed;
        }

        /// Duplicate every row of `rows` into an owned `[]Entry`. The caller
        /// still owns `rows` (it must call `deinit`).
        fn collectRows(allocator: std.mem.Allocator, rows: sql_driver.Rows) ![]Entry {
            var list: std.ArrayListUnmanaged(Entry) = .empty;
            errdefer {
                for (list.items) |e| {
                    allocator.free(e.aggregate_type);
                    allocator.free(e.event_type);
                    allocator.free(e.payload);
                }
                list.deinit(allocator);
            }
            while (rows.next()) |row| {
                const id = row.getInt(0) orelse return error.OutboxRowMissingColumn;
                const aggregate_type = try allocator.dupe(u8, row.getText(1) orelse return error.OutboxRowMissingColumn);
                errdefer allocator.free(aggregate_type);
                const aggregate_id = row.getInt(2) orelse return error.OutboxRowMissingColumn;
                const event_type = try allocator.dupe(u8, row.getText(3) orelse return error.OutboxRowMissingColumn);
                errdefer allocator.free(event_type);
                const payload = try allocator.dupe(u8, row.getText(4) orelse return error.OutboxRowMissingColumn);
                errdefer allocator.free(payload);
                const attempts = row.getInt(5) orelse return error.OutboxRowMissingColumn;
                const created_at = row.getInt(6) orelse return error.OutboxRowMissingColumn;
                try list.append(allocator, .{
                    .id = id,
                    .aggregate_type = aggregate_type,
                    .aggregate_id = aggregate_id,
                    .event_type = event_type,
                    .payload = payload,
                    .attempts = attempts,
                    .created_at = created_at,
                });
            }
            return try list.toOwnedSlice(allocator);
        }

        /// At-least-once dispatch: claim a batch of pending rows, publish each
        /// one, marking it published on success; on error the row is requeued
        /// (pending, attempts+1) until `max_attempts` is reached, then marked
        /// failed. Returns the number of successfully dispatched rows.
        ///
        /// Rows are claimed (pending -> processing, `claimed_at` stamped)
        /// before publishing, so concurrent dispatchers never publish the same
        /// row. A crash after the claim leaves the row in `processing` with a
        /// stale `claimed_at`; recover it with `requeueStale` from a periodic
        /// sweeper — dispatching alone will not pick it up again.
        pub fn dispatch(
            allocator: std.mem.Allocator,
            client: anytype,
            now_ms: i64,
            publisher: Publisher,
            batch_size: usize,
            max_attempts: usize,
        ) !usize {
            const entries = try claim(allocator, client, batch_size);
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

test "outbox dispatch exhausts max_attempts then marks failed" {
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

    _ = try OutboxOps.enqueue(root, 1, .{
        .aggregate_type = "order",
        .aggregate_id = 9,
        .event_type = "order.placed",
        .payload = "{}",
    });

    const FailingPublisher = Publisher{
        .ctx = null,
        .call = struct {
            fn call(_: ?*anyopaque, _: Entry) anyerror!void {
                return error.PublisherDown;
            }
        }.call,
    };

    // max_attempts=2: first dispatch requeues (attempts 0->1), second marks
    // failed (attempts 1->2). Neither round counts as dispatched.
    const d1 = try OutboxOps.dispatch(allocator, root, 100, FailingPublisher, 10, 2);
    try testing.expectEqual(@as(usize, 0), d1);
    const d2 = try OutboxOps.dispatch(allocator, root, 200, FailingPublisher, 10, 2);
    try testing.expectEqual(@as(usize, 0), d2);

    // The row is now failed with attempts=2 and no longer pending.
    const ec = @field(root, "outbox_message");
    var q = ec.Query();
    defer q.deinit();
    var found = try q.All();
    defer {
        for (found.items) |*e| deinitEntity(infos, info, e, allocator);
        found.deinit();
    }
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqualStrings(Status.failed, found.items[0].status);
    try testing.expectEqual(@as(i64, 2), found.items[0].attempts);

    const remaining = try OutboxOps.pending(allocator, root, 10);
    defer OutboxOps.freeEntries(allocator, remaining);
    try testing.expectEqual(@as(usize, 0), remaining.len);
}

test "outbox pending returns oldest-first and respects limit" {
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

    // Enqueue out of order: created_at 3000, 1000, 2000.
    _ = try OutboxOps.enqueue(root, 3000, .{ .aggregate_type = "p", .aggregate_id = 1, .event_type = "e3", .payload = "{}" });
    _ = try OutboxOps.enqueue(root, 1000, .{ .aggregate_type = "p", .aggregate_id = 2, .event_type = "e1", .payload = "{}" });
    _ = try OutboxOps.enqueue(root, 2000, .{ .aggregate_type = "p", .aggregate_id = 3, .event_type = "e2", .payload = "{}" });

    const pending = try OutboxOps.pending(allocator, root, 2);
    defer OutboxOps.freeEntries(allocator, pending);
    try testing.expectEqual(@as(usize, 2), pending.len);
    try testing.expectEqual(@as(i64, 1000), pending[0].created_at);
    try testing.expectEqual(@as(i64, 2000), pending[1].created_at);
}

test "outbox claim is exclusive and requeue re-enables a row" {
    const allocator = testing.allocator;
    const graph = comptime @import("codegen/graph.zig").buildGraph(&.{ TestSchema.Product, OutboxMessage });
    const infos = graph.types;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");
    const client_mod = @import("codegen/client.zig");
    const OutboxOps = Outbox(infos, info);

    var drv = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    try migrate.migrateSchema(allocator, drv.asDriver(), infos);
    const root = client_mod.makeClient(infos, allocator, drv.asDriver());

    const id1 = try OutboxOps.enqueue(root, 1000, .{
        .aggregate_type = "p",
        .aggregate_id = 1,
        .event_type = "a",
        .payload = "{}",
    });
    _ = try OutboxOps.enqueue(root, 2000, .{
        .aggregate_type = "p",
        .aggregate_id = 2,
        .event_type = "b",
        .payload = "{}",
    });

    // The first claim flips both rows to processing and returns them.
    const first = try OutboxOps.claim(allocator, root, 10);
    defer OutboxOps.freeEntries(allocator, first);
    try testing.expectEqual(@as(usize, 2), first.len);

    // A second claimer sees none of the rows the first one claimed.
    const second = try OutboxOps.claim(allocator, root, 10);
    defer OutboxOps.freeEntries(allocator, second);
    try testing.expectEqual(@as(usize, 0), second.len);

    // The unclaimed `pending` read path agrees: nothing is pending.
    const pend = try OutboxOps.pending(allocator, root, 10);
    defer OutboxOps.freeEntries(allocator, pend);
    try testing.expectEqual(@as(usize, 0), pend.len);

    // The claimed row really carries the processing status.
    {
        const ec = @field(root, "outbox_message");
        var q = ec.Query();
        defer q.deinit();
        _ = try q.Where(.{ec.predicates.idEQ(.{ .int = id1 })});
        var found = try q.All();
        defer {
            for (found.items) |*e| deinitEntity(infos, info, e, allocator);
            found.deinit();
        }
        try testing.expectEqual(@as(usize, 1), found.items.len);
        try testing.expectEqualStrings(Status.processing, found.items[0].status);
    }

    // requeue puts a claimed row back to pending, so it can be claimed again.
    try OutboxOps.requeue(allocator, root, id1, 1);
    const third = try OutboxOps.claim(allocator, root, 10);
    defer OutboxOps.freeEntries(allocator, third);
    try testing.expectEqual(@as(usize, 1), third.len);
    try testing.expectEqual(id1, third[0].id);

    // Publishing removes it from the claimable set for good.
    try OutboxOps.markPublished(allocator, root, third[0].id, 5000);
    const fourth = try OutboxOps.claim(allocator, root, 10);
    defer OutboxOps.freeEntries(allocator, fourth);
    try testing.expectEqual(@as(usize, 0), fourth.len);
}

test "outbox dispatch claims before publish so a nested dispatcher cannot double-publish" {
    const allocator = testing.allocator;
    const graph = comptime @import("codegen/graph.zig").buildGraph(&.{ TestSchema.Product, OutboxMessage });
    const infos = graph.types;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");
    const client_mod = @import("codegen/client.zig");
    const OutboxOps = Outbox(infos, info);

    var drv = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    try migrate.migrateSchema(allocator, drv.asDriver(), infos);
    const root = client_mod.makeClient(infos, allocator, drv.asDriver());

    _ = try OutboxOps.enqueue(root, 1000, .{
        .aggregate_type = "p",
        .aggregate_id = 1,
        .event_type = "a",
        .payload = "{}",
    });

    const Ctx = struct {
        client: *const @TypeOf(root),
        published: usize = 0,
        nested_claimed: usize = 0,

        fn publish(ctx: ?*anyopaque, _: Entry) anyerror!void {
            const c: *@This() = @ptrCast(@alignCast(ctx.?));
            c.published += 1;
            // The row being published is `processing`, so a second dispatcher
            // running at this instant must claim nothing.
            const nested = try OutboxOps.claim(std.testing.allocator, c.client.*, 10);
            defer OutboxOps.freeEntries(std.testing.allocator, nested);
            c.nested_claimed += nested.len;
        }
    };

    var ctx = Ctx{ .client = &root };
    const dispatched = try OutboxOps.dispatch(allocator, root, 3000, .{
        .ctx = &ctx,
        .call = Ctx.publish,
    }, 10, 3);
    try testing.expectEqual(@as(usize, 1), dispatched);
    try testing.expectEqual(@as(usize, 1), ctx.published);
    try testing.expectEqual(@as(usize, 0), ctx.nested_claimed);
}

/// Assert one outbox row's status and whether `claimed_at` is NULL.
fn expectRowState(
    client: anytype,
    comptime infos: []const TypeInfo,
    id: i64,
    want_status: []const u8,
    want_claimed_null: bool,
) !void {
    const ec = @field(client, "outbox_message");
    var q = ec.Query();
    defer q.deinit();
    _ = try q.Where(.{ec.predicates.idEQ(.{ .int = id })});
    var found = try q.All();
    defer {
        for (found.items) |*e| deinitEntity(infos, info, e, testing.allocator);
        found.deinit();
    }
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqualStrings(want_status, found.items[0].status);
    const claimed = found.items[0].claimed_at;
    try testing.expectEqual(want_claimed_null, claimed == null);
}

test "outbox claim stamps claimed_at and requeueStale reclaims stale rows" {
    const allocator = testing.allocator;
    const graph = comptime @import("codegen/graph.zig").buildGraph(&.{ TestSchema.Product, OutboxMessage });
    const infos = graph.types;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");
    const client_mod = @import("codegen/client.zig");
    const OutboxOps = Outbox(infos, info);

    var drv = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    try migrate.migrateSchema(allocator, drv.asDriver(), infos);
    const root = client_mod.makeClient(infos, allocator, drv.asDriver());

    const id1 = try OutboxOps.enqueue(root, 1000, .{
        .aggregate_type = "p",
        .aggregate_id = 1,
        .event_type = "a",
        .payload = "{}",
    });

    // claim stamps claimed_at in the same statement that flips to processing.
    const first = try OutboxOps.claim(allocator, root, 10);
    defer OutboxOps.freeEntries(allocator, first);
    try testing.expectEqual(@as(usize, 1), first.len);
    try expectRowState(root, infos, id1, Status.processing, false);

    // Threshold 0 reclaims every processing row, clearing claimed_at.
    try testing.expectEqual(@as(usize, 1), try OutboxOps.requeueStale(allocator, root, 0));
    try expectRowState(root, infos, id1, Status.pending, true);

    // The reclaimed row can be claimed again.
    const second = try OutboxOps.claim(allocator, root, 10);
    defer OutboxOps.freeEntries(allocator, second);
    try testing.expectEqual(@as(usize, 1), second.len);
    try testing.expectEqual(id1, second[0].id);

    // A huge threshold leaves a freshly claimed row alone.
    try testing.expectEqual(@as(usize, 0), try OutboxOps.requeueStale(allocator, root, 100_000_000));
    try expectRowState(root, infos, id1, Status.processing, false);

    // Publishing clears claimed_at.
    try OutboxOps.markPublished(allocator, root, id1, 9000);
    try expectRowState(root, infos, id1, Status.published, true);

    // requeue clears claimed_at too.
    const id2 = try OutboxOps.enqueue(root, 2000, .{
        .aggregate_type = "p",
        .aggregate_id = 2,
        .event_type = "b",
        .payload = "{}",
    });
    const third = try OutboxOps.claim(allocator, root, 10);
    defer OutboxOps.freeEntries(allocator, third);
    try testing.expectEqual(@as(usize, 1), third.len);
    try testing.expectEqual(id2, third[0].id);
    try OutboxOps.requeue(allocator, root, id2, 1);
    try expectRowState(root, infos, id2, Status.pending, true);

    // A NULL claimed_at is stale even under a huge threshold: it covers rows
    // claimed before the column existed or whose stamp was never written.
    const id3 = try OutboxOps.enqueue(root, 3000, .{
        .aggregate_type = "p",
        .aggregate_id = 3,
        .event_type = "c",
        .payload = "{}",
    });
    {
        const ec = @field(root, "outbox_message");
        var b = ec.Update();
        defer b.deinit();
        _ = try b.setFieldValue("status", Status.processing);
        _ = try b.Where(.{ec.predicates.idEQ(.{ .int = id3 })});
        _ = try b.Save();
    }
    try expectRowState(root, infos, id3, Status.processing, true);
    try testing.expectEqual(@as(usize, 1), try OutboxOps.requeueStale(allocator, root, 100_000_000));
    try expectRowState(root, infos, id3, Status.pending, true);
}
