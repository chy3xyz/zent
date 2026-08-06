//! Advanced patterns demo: composite unique index, paged listing,
//! sensitive-field masking (toMaskedJson) and the transactional outbox.
//!
//! Run: `zig build run-advanced`

const std = @import("std");
const zent = @import("zent");
const field = zent.core.field;
const edge = zent.core.edge;
const index = zent.core.index;
const Schema = zent.core.schema.Schema;
const buildGraph = zent.codegen.graph.buildGraph;
const Client = zent.codegen.client;
const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;

const Order = Schema("AdvOrder", .{
    .fields = &.{
        field.String("user_email"),
        field.String("code"),
        field.Int("amount"),
        field.String("api_key").Sensitive(),
    },
    // Composite UNIQUE (user_email, code): the DB index backs the
    // application-level duplicate check against concurrent races.
    .indexes = &.{index.Fields(&.{ "user_email", "code" }).Unique()},
});

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    const graph = comptime buildGraph(&.{ Order, zent.outbox.OutboxMessage });
    const infos = graph.types;
    try zent.sql_schema.migrateSchema(allocator, drv.asDriver(), graph.types);
    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // --- 1. Composite unique: duplicate (user, code) is rejected by the DB ---
    const mk = struct {
        fn create(c: anytype, alloc2: std.mem.Allocator, email: []const u8, code: []const u8) !void {
            var b = try c.adv_order.Create();
            defer b.deinit();
            _ = try b.setFieldValue("user_email", email);
            _ = try b.setFieldValue("code", code);
            _ = try b.setFieldValue("amount", 100);
            const api_key = try std.fmt.allocPrint(alloc2, "sk-{s}", .{code});
            defer alloc2.free(api_key);
            _ = try b.setFieldValue("api_key", api_key);
            var saved = try b.Save();
            defer zent.codegen.deinitEntity(infos, infos[0], &saved, alloc2);
        }
    }.create;
    try mk(&client, allocator, "a@x.com", "A1");
    try mk(&client, allocator, "a@x.com", "A2");
    std.debug.print("inserted two orders (distinct codes)\n", .{});
    if (mk(&client, allocator, "a@x.com", "A1")) |_| {
        std.debug.print("UNEXPECTED: duplicate (user, code) inserted\n", .{});
    } else |err| {
        std.debug.print("duplicate (user, code) rejected by UNIQUE index: {s}\n", .{@errorName(err)});
    }

    // --- 2. Paged listing with total ---
    var q = client.adv_order.Query();
    defer q.deinit();
    var page1 = try q.paged(1, 1);
    defer page1.deinit();
    std.debug.print("paged(1,1): items={d} total={d}\n", .{ page1.items.items.len, page1.total });

    // --- 3. Sensitive-field masking ---
    {
        var qm = client.adv_order.Query();
        defer qm.deinit();
        var rows = try qm.All();
        defer {
            for (rows.items) |*r| zent.codegen.deinitEntity(infos, infos[0], r, allocator);
            rows.deinit();
        }
        const masked = try zent.codegen.toMaskedJson(allocator, infos, infos[0], &rows.items[0]);
        defer allocator.free(masked);
        std.debug.print("masked: {s}\n", .{masked});
    }

    // --- 4. Transactional outbox ---
    {
        const Outbox = zent.outbox.Outbox(infos, zent.outbox.info);
        var tx = try zent.codegen.beginTx(infos, client);
        defer tx.deinit();
        const now: i64 = @intCast(@divFloor(zent.sql_logger.nowUs(), std.time.us_per_s));
        _ = try Outbox.enqueue(tx.client, now, .{
            .aggregate_type = "adv_order",
            .aggregate_id = 1,
            .event_type = "order.created",
            .payload = "order-created",
        });
        _ = try tx.commit();
        std.debug.print("outbox: enqueued inside tx, committed\n", .{});

        var published: usize = 0;
        const publisher = zent.outbox.Publisher{
            .ctx = &published,
            .call = struct {
                fn call(ctx: ?*anyopaque, _: zent.outbox.Entry) anyerror!void {
                    const p: *usize = @ptrCast(@alignCast(ctx.?));
                    p.* += 1;
                }
            }.call,
        };
        _ = try Outbox.dispatch(allocator, client, now, publisher, 10, 3);
        std.debug.print("outbox: published {d} message(s)\n", .{published});
    }

    std.debug.print("advanced example OK\n", .{});
}
