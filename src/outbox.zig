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
const zent_log = @import("runtime/log.zig");

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

/// The `claimed_at` cutoff (epoch ms) for a positive `older_than_secs`: a row
/// is stale when its stamp is *below* `staleCutoffMs(now, older_than_secs)`,
/// i.e. older than `now - older_than_secs * 1000`. `older_than_secs <= 0`
/// means "no age test at all" and is decided by the caller, not here.
///
/// **Overflow saturates towards "nothing is that old", never towards
/// "everything is".** A threshold in milliseconds too large for an i64
/// describes an age no row can have, so the cutoff belongs at the far past
/// end of the range (`minInt`) and matches no realistic stamp — the same
/// verdict the arithmetic gives just below the overflow point, so the
/// function stays monotonic in `older_than_secs` across it. Landing on 0
/// instead ("claimed before 1970") would make negative stamps — pre-epoch
/// clocks, skewed hosts — stale, i.e. it would widen the sweep the caller
/// asked to narrow, and a sweeper whose threshold is too large would start
/// reclaiming rows a live dispatcher is still publishing. Widening is the
/// dangerous direction here; `requeueStale(…, 0)` is the supported way to say
/// "reclaim every processing row".
fn staleCutoffMs(now_ms: i64, older_than_secs: i64) i64 {
    const age_ms = std.math.mul(i64, older_than_secs, std.time.ms_per_s) catch
        return std.math.minInt(i64);
    return std.math.sub(i64, now_ms, age_ms) catch std.math.minInt(i64);
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
        /// A threshold so large that its millisecond form overflows an i64 is
        /// beyond any age, so nothing is stale under it — that is *not* the same
        /// as `0`, which reclaims everything (see `staleCutoffMs`).
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
                const cutoff = staleCutoffMs(nowMs(), older_than_secs);
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
            switch (dialect.kind()) {
                .postgres => {
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
                },
                .sqlite => {
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
                },
                // MySQL is the remaining built-in, and an unrecognised dialect
                // lands with it exactly as the old `else` did: both take the
                // reservation transaction below instead of a single statement.
                .mysql, .unknown => {},
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
        ///
        /// A step failure ends the scan the same way the end of the result set
        /// does, so it is read back from `nextError` and returned: `claim` must
        /// not report "these are the rows I reserved" for a batch the driver
        /// gave up on halfway.
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
            // A step failure surfaces as `next() == null` — indistinguishable
            // from a complete scan until the driver is asked. Returning the
            // error keeps a broken claim from looking like a small batch
            // (the rows it did return are freed by the errdefer above).
            if (rows.nextError()) |err| return err;
            return try list.toOwnedSlice(allocator);
        }

        /// at-least-once dispatch: claim a batch of pending rows, publish each
        /// one, marking it published on success; on error the row is requeued
        /// (pending, attempts+1) until `max_attempts` is reached, then marked
        /// failed. Returns the number of successfully dispatched rows.
        ///
        /// One failing row does not abort the batch, and the publisher's error
        /// is not propagated: it is logged (`warn`, with the row id and the
        /// attempt count) and recorded on the row itself. A batch in which
        /// every publish failed therefore returns `0`, exactly like a claim
        /// that found nothing — the per-row `status`/`attempts` and the log
        /// are where the difference lives, not in this count.
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
                publisher.call(publisher.ctx, e) catch |err| {
                    const next = e.attempts + 1;
                    if (next >= max_attempts) {
                        try markFailed(allocator, client, e.id, next);
                    } else {
                        try requeue(allocator, client, e.id, next);
                    }
                    // The error is deliberately not propagated — one poison
                    // message must not abort the batch — but it is not
                    // discarded either: `dispatched` counts successes, so
                    // without this line "the queue was empty" and "every row
                    // failed" produce the same `0` and the publisher's reason
                    // never reaches a log anywhere.
                    zent_log.warn(
                        "outbox: publish failed for row {d} (event '{s}', attempt {d}/{d}): {s}",
                        .{ e.id, e.event_type, next, max_attempts, @errorName(err) },
                    );
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

// File-scope imports for the stress scaffolding below; the older tests keep
// their own local imports under the plain names.
const stress_migrate = @import("sql/schema/migrate.zig");
const stress_sqlite = @import("sql/sqlite.zig");
const stress_client = @import("codegen/client.zig");

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

test "outbox claim reports a step failure instead of half a batch" {
    // SQLite's claim is one `UPDATE ... RETURNING` whose rows arrive through
    // `step`. A step failure ends that scan with `next() == null`, exactly like
    // the end of a complete result set, so only `nextError()` says which of the
    // two happened. A claim that read the truncated batch as the whole batch
    // would report rows as reserved that the driver never returned — and the
    // dispatcher would never publish them, while `dispatch` still counted the
    // call as a success. The failure is injected with a driver stub because
    // SQLITE_FULL cannot be aimed at this particular UPDATE.
    const allocator = testing.allocator;
    const graph = comptime @import("codegen/graph.zig").buildGraph(&.{ TestSchema.Product, OutboxMessage });
    const OutboxOps = Outbox(graph.types, info);

    const StubClient = struct { driver: sql_driver.Driver };
    var stub_driver = StubDriver{};
    var stub = StubClient{ .driver = stub_driver.asDriver() };

    // The one row the stub did hand over must not be returned as a claimed
    // batch: the caller would mark it published and count it as dispatched.
    try testing.expectError(error.ExecFailed, OutboxOps.claim(allocator, &stub, 10));
}

/// Test scaffolding for the claim step-failure test: one well-formed outbox row,
/// then a step failure. `next()` answers null for both, so only `nextError()`
/// tells them apart — which is the point of that test.
const StubRows = struct {
    delivered: bool = false,

    const rows_vtable = sql_driver.Rows.VTable{
        .next = next,
        .deinit = deinit,
        .nextError = nextError,
    };
    const row_vtable = sql_driver.Row.VTable{
        .columnCount = columnCount,
        .columnName = columnName,
        .getBool = getBool,
        .getInt = getInt,
        .getFloat = getFloat,
        .getText = getText,
        .getBlob = getBlob,
        .isNull = isNull,
    };

    /// One well-formed outbox row, then the failure.
    fn next(ptr: *anyopaque) ?sql_driver.Row {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.delivered) return null;
        self.delivered = true;
        return sql_driver.Row{ .ptr = self, .vtable = &row_vtable };
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        std.testing.allocator.destroy(self);
    }

    fn nextError(_: *anyopaque) ?sql_driver.Error {
        return error.ExecFailed;
    }

    fn columnCount(_: *anyopaque) usize {
        return 7;
    }

    fn columnName(_: *anyopaque, _: usize) []const u8 {
        return "";
    }

    fn getBool(_: *anyopaque, _: usize) ?bool {
        return null;
    }

    fn getInt(_: *anyopaque, index: usize) ?i64 {
        return switch (index) {
            0 => 1, // id
            2 => 7, // aggregate_id
            5 => 0, // attempts
            6 => 1000, // created_at
            else => null,
        };
    }

    fn getFloat(_: *anyopaque, _: usize) ?f64 {
        return null;
    }

    fn getText(_: *anyopaque, index: usize) ?[]const u8 {
        return switch (index) {
            1 => "product", // aggregate_type
            3 => "product.created", // event_type
            4 => "{}", // payload
            else => null,
        };
    }

    fn getBlob(_: *anyopaque, _: usize) ?[]const u8 {
        return null;
    }

    fn isNull(_: *anyopaque, _: usize) bool {
        return false;
    }
};

const StubDriver = struct {
    const vtable = sql_driver.Driver.VTable{
        .exec = exec,
        .query = query,
        .beginTx = beginTx,
        .close = close,
        .dialect = dialect,
        .ping = ping,
        .inTransaction = inTransaction,
        .beginSavepoint = beginSavepoint,
    };

    fn asDriver(self: *@This()) sql_driver.Driver {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn exec(_: *anyopaque, _: ?*const sql_driver.ExecutionContext, _: []const u8, _: []const sql.Value) sql_driver.Error!sql_driver.Result {
        return .{ .rows_affected = 0, .last_insert_id = null };
    }

    fn query(_: *anyopaque, _: ?*const sql_driver.ExecutionContext, _: []const u8, _: []const sql.Value) sql_driver.Error!sql_driver.Rows {
        const rows = try std.testing.allocator.create(StubRows);
        rows.* = .{};
        return .{ .ptr = rows, .vtable = &StubRows.rows_vtable };
    }

    fn beginTx(_: *anyopaque) sql_driver.Error!sql_driver.Tx {
        return error.TxFailed;
    }

    fn close(_: *anyopaque) void {}

    fn dialect(_: *anyopaque) @import("sql/dialect.zig").Dialect {
        return .sqlite;
    }

    fn ping(_: *anyopaque) sql_driver.Error!void {}

    fn inTransaction(_: *anyopaque) bool {
        return false;
    }

    fn beginSavepoint(_: *anyopaque, _: []const u8) sql_driver.Error!sql_driver.Tx {
        return error.TxFailed;
    }
};

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

test "staleCutoffMs saturates an unrepresentable threshold at the far past, not at 0" {
    const now_ms: i64 = 1_758_000_000_000;

    // Ordinary case: plain subtraction, and a larger threshold is a lower
    // cutoff (a smaller stale set).
    try testing.expectEqual(now_ms - 5 * std.time.ms_per_s, staleCutoffMs(now_ms, 5));
    try testing.expect(staleCutoffMs(now_ms, 3600) < staleCutoffMs(now_ms, 60));

    // The largest threshold in seconds whose millisecond form still fits: the
    // cutoff is already far in the past, and no realistic stamp is below it.
    const largest_fitting = std.math.maxInt(i64) / std.time.ms_per_s;
    const below_overflow = staleCutoffMs(now_ms, largest_fitting);
    try testing.expect(below_overflow < now_ms - 9_000_000_000_000_000_000);

    // Every threshold past that point lands at the same end of the range:
    // `minInt` = "no stamp can be that old". It must not jump *up* to 0 —
    // "claimed before 1970" — which would make a negative stamp stale under a
    // threshold nothing is older than, i.e. grow the stale set as the caller
    // raises the threshold.
    try testing.expectEqual(std.math.minInt(i64), staleCutoffMs(now_ms, std.math.maxInt(i64)));
    try testing.expect(staleCutoffMs(now_ms, std.math.maxInt(i64)) <= below_overflow);
}

test "requeueStale with a threshold too large to be representable reclaims nothing, not everything" {
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
    // A `processing` row with a *negative* stamp. It is the only stamp that
    // tells the two saturation targets apart: `cutoff = minInt` leaves it
    // alone (nothing was claimed 292 million years ago), while the widening
    // `cutoff = 0` reads it as "claimed before 1970" and reclaims it.
    {
        const ec = @field(root, "outbox_message");
        var b = ec.Update();
        defer b.deinit();
        _ = try b.setFieldValue("status", Status.processing);
        _ = try b.setFieldValue("claimed_at", @as(?i64, -1));
        _ = try b.Where(.{ec.predicates.idEQ(.{ .int = id1 })});
        _ = try b.Save();
    }
    try expectRowState(root, infos, id1, Status.processing, false);

    try testing.expectEqual(
        @as(usize, 0),
        try OutboxOps.requeueStale(allocator, root, std.math.maxInt(i64)),
    );
    try expectRowState(root, infos, id1, Status.processing, false);

    // Control: the same row *is* reclaimed when the caller asks for
    // "everything" (threshold 0 skips the age test), so the 0 above is the
    // threshold's verdict on a row the sweep can otherwise see.
    try testing.expectEqual(@as(usize, 1), try OutboxOps.requeueStale(allocator, root, 0));
    try expectRowState(root, infos, id1, Status.pending, true);
}

// Stress tests: concurrent dispatchers hammering claim/markPublished
// ------------------------------------------------------------------
//
// `claim`'s mutual exclusion is a database-level guarantee, not an
// application lock: SQLite flips pending -> processing in one
// `UPDATE ... RETURNING` (the single-writer UPDATE is atomic on its own),
// PostgreSQL/MySQL add `FOR UPDATE SKIP LOCKED`. The probe below therefore
// runs real dispatchers against a real database and asserts invariants,
// never schedules:
//
//   1. claiming is exclusive: every claimed row id shows up in the
//      cross-thread ledger exactly once (a duplicate is two dispatchers
//      processing the same row);
//   2. the state machine never regresses: with a never-failing publisher
//      the run must settle with every row `published`, `attempts` untouched
//      (a spurious requeue would bump it), `claimed_at` cleared, and no
//      row pending / processing / failed;
//   3. the dispatched count is honest: the sum of every `dispatch` return
//      equals the number of rows actually marked published, and the
//      published set is exactly the enqueued set (checked by summing
//      `aggregate_id` inside the publisher, before any mark runs).
//
// Two shapes are covered because both are production wiring: dispatchers on
// separate connections (the multi-process dispatcher pool, here against one
// SQLite file with the driver's 5 s busy timeout absorbing writer
// contention) and dispatchers on one shared connection (one process, many
// worker threads — the shape `SQLiteDriver.mutex` exists for).

/// Spin lock for the claim ledger, same shape as the pool stress harness:
/// the critical sections are a couple of hash-map operations wide.
const OutboxStressLock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *@This()) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *@This()) void {
        self.inner.unlock();
    }
};

/// Fixed `now_ms` every dispatcher passes to `markPublished`, so the
/// final-state assertion can tell "marked by a dispatch" from any other path.
const stress_publish_stamp: i64 = 7777;

/// Cross-thread ledger for the stress tests. The `claimed` map is the
/// double-claim probe: a row id that is already registered when a second
/// dispatcher's publisher sees it is `claim` having handed the row out
/// twice.
const OutboxStressRegistry = struct {
    allocator: std.mem.Allocator,
    lock: OutboxStressLock = .{},
    /// Claimed row id -> claiming dispatcher index.
    claimed: std.AutoHashMapUnmanaged(i64, u8) = .empty,
    dup_claims: usize = 0,
    register_failures: usize = 0,
    /// Sum of `aggregate_id` over every published entry, across threads.
    published_id_sum: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    /// Sum of every `dispatch` return value.
    dispatched: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Driver/op failures a dispatcher hit (an open or busy error).
    op_failures: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

fn OutboxStressDispatcher(comptime infos: []const TypeInfo, comptime Client: type) type {
    return struct {
        const Self = @This();
        const Ops = Outbox(infos, info);

        registry: *OutboxStressRegistry,
        idx: u8,
        allocator: std.mem.Allocator,
        /// Multi-connection mode: the dispatcher opens its own connection
        /// to this path — the production shape of N dispatcher processes.
        path: ?[]const u8 = null,
        /// Shared-connection mode: every dispatcher drives this one client;
        /// the driver's recursive mutex serializes each call.
        shared: ?Client = null,
        total_rows: usize,
        max_rounds: usize,

        fn publish(ctx: ?*anyopaque, entry: Entry) anyerror!void {
            const d: *Self = @ptrCast(@alignCast(ctx.?));
            d.registry.lock.lock();
            defer d.registry.lock.unlock();
            const slot = d.registry.claimed.getOrPut(d.registry.allocator, entry.id) catch {
                d.registry.register_failures += 1;
                return;
            };
            if (slot.found_existing) {
                d.registry.dup_claims += 1;
            } else {
                slot.value_ptr.* = d.idx;
            }
            _ = d.registry.published_id_sum.fetchAdd(entry.aggregate_id, .monotonic);
        }

        fn run(self: *Self) void {
            if (self.path) |p| {
                var drv = stress_sqlite.SQLiteDriver.open(self.allocator, p) catch {
                    _ = self.registry.op_failures.fetchAdd(1, .monotonic);
                    return;
                };
                defer drv.close();
                const client = stress_client.makeClient(infos, self.allocator, drv.asDriver());
                self.loop(client);
            } else {
                self.loop(self.shared.?);
            }
        }

        fn loop(self: *Self, client: Client) void {
            var rounds: usize = 0;
            while (rounds < self.max_rounds) : (rounds += 1) {
                const n = Ops.dispatch(self.allocator, client, stress_publish_stamp, .{
                    .ctx = self,
                    .call = publish,
                }, 5, 3) catch {
                    _ = self.registry.op_failures.fetchAdd(1, .monotonic);
                    std.Thread.yield() catch {};
                    continue;
                };
                _ = self.registry.dispatched.fetchAdd(n, .monotonic);
                // Every row is dispatched: further claims can only come back
                // empty, and the other dispatchers will see the same total
                // and exit too. `max_rounds` bounds the empty polls.
                if (n == 0 and self.registry.dispatched.load(.acquire) == self.total_rows) break;
                std.Thread.yield() catch {};
            }
        }
    };
}

fn expectOutboxStressInvariants(
    registry: *OutboxStressRegistry,
    client: anytype,
    comptime infos: []const TypeInfo,
    row_count: usize,
) !void {
    // Invariant 1: claiming was exclusive and total — every row exactly
    // once, no ledger or driver failure anywhere.
    try testing.expectEqual(@as(usize, 0), registry.dup_claims);
    try testing.expectEqual(@as(usize, 0), registry.register_failures);
    try testing.expectEqual(@as(usize, 0), registry.op_failures.load(.monotonic));
    try testing.expectEqual(row_count, registry.claimed.count());
    // Invariant 3: the dispatched count equals the rows actually marked
    // published, and the published set is exactly the enqueued set.
    try testing.expectEqual(row_count, registry.dispatched.load(.monotonic));
    try testing.expectEqual(
        @as(i64, @intCast(row_count * (row_count + 1) / 2)),
        registry.published_id_sum.load(.monotonic),
    );

    // Invariant 2, settled form: with a never-failing publisher every row
    // must end `published` exactly once — no row left pending/processing/
    // failed (a state machine regression would strand or duplicate rows),
    // `attempts` untouched (a spurious requeue would bump it), the claim
    // stamp cleared, and the publish stamp the one dispatch wrote.
    const ec = @field(client, "outbox_message");
    var q = ec.Query();
    defer q.deinit();
    var found = try q.All();
    defer {
        for (found.items) |*e| deinitEntity(infos, info, e, testing.allocator);
        found.deinit();
    }
    try testing.expectEqual(row_count, found.items.len);
    for (found.items) |e| {
        try testing.expectEqualStrings(Status.published, e.status);
        try testing.expectEqual(@as(i64, 0), e.attempts);
        try testing.expectEqual(stress_publish_stamp, e.published_at);
        try testing.expect(e.claimed_at == null);
    }
}

test "outbox stress: concurrent dispatchers on separate connections never double-claim" {
    const allocator = testing.allocator;
    const graph = comptime @import("codegen/graph.zig").buildGraph(&.{ TestSchema.Product, OutboxMessage });
    const infos = graph.types;
    const OutboxOps = Outbox(infos, info);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/outbox_stress.db", .{tmp.sub_path});
    defer allocator.free(path);

    var drv = try stress_sqlite.SQLiteDriver.open(allocator, path);
    defer drv.close();
    try stress_migrate.migrateSchema(allocator, drv.asDriver(), infos);
    const setup_client = stress_client.makeClient(infos, allocator, drv.asDriver());

    const row_count = 100;
    for (0..row_count) |i| {
        _ = try OutboxOps.enqueue(setup_client, @intCast(i + 1), .{
            .aggregate_type = "p",
            .aggregate_id = @intCast(i + 1),
            .event_type = "e",
            .payload = "{}",
        });
    }

    var registry = OutboxStressRegistry{ .allocator = allocator };
    defer registry.claimed.deinit(allocator);
    // `publish` runs under the ledger spin lock and must not allocate there.
    try registry.claimed.ensureTotalCapacity(allocator, row_count);

    const Dispatcher = OutboxStressDispatcher(infos, @TypeOf(setup_client));
    const dispatchers = 4;
    var states: [dispatchers]Dispatcher = undefined;
    var threads: [dispatchers]std.Thread = undefined;
    var spawned: usize = 0;
    for (&states, &threads, 0..) |*d, *t, i| {
        d.* = .{
            .registry = &registry,
            .idx = @intCast(i),
            .allocator = allocator,
            .path = path,
            .total_rows = row_count,
            .max_rounds = 1000,
        };
        t.* = std.Thread.spawn(.{}, Dispatcher.run, .{d}) catch |err| {
            // Bounded way out: the spawned dispatchers finish their bounded
            // loops — never unwind the defers under live threads.
            for (threads[0..spawned]) |*jt| jt.join();
            return err;
        };
        spawned += 1;
    }
    for (&threads) |*t| t.join();

    try expectOutboxStressInvariants(&registry, setup_client, infos, row_count);
}

test "outbox stress: concurrent dispatchers on a shared connection never double-claim" {
    const allocator = testing.allocator;
    const graph = comptime @import("codegen/graph.zig").buildGraph(&.{ TestSchema.Product, OutboxMessage });
    const infos = graph.types;
    const OutboxOps = Outbox(infos, info);

    var drv = try stress_sqlite.SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    try stress_migrate.migrateSchema(allocator, drv.asDriver(), infos);
    const root = stress_client.makeClient(infos, allocator, drv.asDriver());

    const row_count = 100;
    for (0..row_count) |i| {
        _ = try OutboxOps.enqueue(root, @intCast(i + 1), .{
            .aggregate_type = "p",
            .aggregate_id = @intCast(i + 1),
            .event_type = "e",
            .payload = "{}",
        });
    }

    var registry = OutboxStressRegistry{ .allocator = allocator };
    defer registry.claimed.deinit(allocator);
    try registry.claimed.ensureTotalCapacity(allocator, row_count);

    const Dispatcher = OutboxStressDispatcher(infos, @TypeOf(root));
    const dispatchers = 4;
    var states: [dispatchers]Dispatcher = undefined;
    var threads: [dispatchers]std.Thread = undefined;
    var spawned: usize = 0;
    for (&states, &threads, 0..) |*d, *t, i| {
        d.* = .{
            .registry = &registry,
            .idx = @intCast(i),
            .allocator = allocator,
            .shared = root,
            .total_rows = row_count,
            .max_rounds = 1000,
        };
        t.* = std.Thread.spawn(.{}, Dispatcher.run, .{d}) catch |err| {
            for (threads[0..spawned]) |*jt| jt.join();
            return err;
        };
        spawned += 1;
    }
    for (&threads) |*t| t.join();

    try expectOutboxStressInvariants(&registry, root, infos, row_count);
}
