//! Complex e-commerce operations demo.
//!
//! Demonstrates:
//!   1. Multi-entity schema (Customer, Product, Order, OrderItem, Tag)
//!   2. M2M edges (Product ↔ Tag), O2M/M2O (Customer → Order → OrderItem)
//!   3. BulkInsert with RETURNING id
//!   4. Complex queries: filters, ordering, limit/offset
//!   5. Aggregates: Count, Sum, Avg, Max, Min
//!   6. GroupBy + Having
//!   7. Eager loading (WithEdge)
//!   8. EntQL predicate parsing
//!   9. BulkUpdate (CASE WHEN)
//!   10. BulkDelete (OR groups)
//!   11. Transactions (atomic create + deduct)
//!   12. SaveOrUpdate (upsert)
//!   13. Soft delete + ForceDelete
//!
//! Build and run:
//!   zig build run-complex

const std = @import("std");
const zent = @import("zent");

const sql = zent.sql;
const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
const buildGraph = zent.codegen.graph.buildGraph;
const Client = zent.codegen.client;
const migrate = zent.sql_schema;

const schema = @import("schema.zig");
const Customer = schema.Customer;
const Product = schema.Product;
const Order = schema.Order;
const OrderItem = schema.OrderItem;
const Tag = schema.Tag;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // ------------------------------------------------------------------
    // Schema introspection
    // ------------------------------------------------------------------
    const graph = comptime buildGraph(&.{ Customer, Product, Order, OrderItem, Tag });
    const cust_info = graph.types[0];
    const prod_info = graph.types[1];
    const order_info = graph.types[2];
    const item_info = graph.types[3];
    const tag_info = graph.types[4];
    const infos = &[_]zent.codegen.graph.TypeInfo{ cust_info, prod_info, order_info, item_info, tag_info };

    std.debug.print(
        "=== Schema: {s} ({d}f,{d}e), {s} ({d}f,{d}e), {s} ({d}f,{d}e), {s} ({d}f,{d}e), {s} ({d}f,{d}e)\n\n",
        .{ cust_info.name, cust_info.fields.len, cust_info.edges.len, prod_info.name, prod_info.fields.len, prod_info.edges.len, order_info.name, order_info.fields.len, order_info.edges.len, item_info.name, item_info.fields.len, item_info.edges.len, tag_info.name, tag_info.fields.len, tag_info.edges.len },
    );

    // ------------------------------------------------------------------
    // Open DB + migrate
    // ------------------------------------------------------------------
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    try migrate.migrateSchema(allocator, drv.asDriver(), graph.types);
    std.debug.print("Tables created.\n\n", .{});

    var client = Client.makeClient(infos, allocator, drv.asDriver());
    const prod_preds = client.product.predicates;

    // ------------------------------------------------------------------
    // CREATE entities
    // ------------------------------------------------------------------
    std.debug.print("=== CREATE ===\n", .{});

    // ----- Tags -----
    var t1 = try client.tag.Create();
    defer t1.deinit();
    _ = try t1.setFieldValue("value", "electronics");
    const tag_elec = try t1.Save();
    std.debug.print("tag: id={d} value={s}\n", .{ tag_elec.id, tag_elec.value });

    var t2 = try client.tag.Create();
    defer t2.deinit();
    _ = try t2.setFieldValue("value", "kitchen");
    const tag_kitchen = try t2.Save();

    var t3 = try client.tag.Create();
    defer t3.deinit();
    _ = try t3.setFieldValue("value", "luxury");
    const tag_luxury = try t3.Save();

    // ----- Products (with M2M AddEdge) -----
    var pb1 = try client.product.Create();
    defer pb1.deinit();
    _ = try pb1.setFieldValue("name", "Wireless Mouse");
    _ = try pb1.setFieldValue("price", 29.99);
    _ = try pb1.setFieldValue("stock", 150);
    _ = try pb1.AddEdge("tags", &.{tag_elec.id});
    const mouse = try pb1.Save();
    std.debug.print(
        "product: id={d} name={s} price={d:.2} stock={d}\n",
        .{ mouse.id, mouse.name, mouse.price, mouse.stock },
    );

    var pb2 = try client.product.Create();
    defer pb2.deinit();
    _ = try pb2.setFieldValue("name", "Espresso Machine");
    _ = try pb2.setFieldValue("price", 399.00);
    _ = try pb2.setFieldValue("stock", 20);
    _ = try pb2.setFieldValue("description", "15-bar pump");
    _ = try pb2.AddEdge("tags", &.{ tag_kitchen.id, tag_luxury.id });
    const espresso = try pb2.Save();

    var pb3 = try client.product.Create();
    defer pb3.deinit();
    _ = try pb3.setFieldValue("name", "Mechanical Keyboard");
    _ = try pb3.setFieldValue("price", 149.95);
    _ = try pb3.setFieldValue("stock", 80);
    _ = try pb3.AddEdge("tags", &.{ tag_elec.id, tag_luxury.id });
    const keyboard = try pb3.Save();

    // ----- Customers -----
    var cb1 = try client.customer.Create();
    defer cb1.deinit();
    _ = try cb1.setFieldValue("name", "Alice");
    _ = try cb1.setFieldValue("email", "alice@example.com");
    _ = try cb1.setFieldValue("balance", 500.00);
    const alice = try cb1.Save();
    std.debug.print(
        "customer: id={d} name={s} balance={d:.2}\n",
        .{ alice.id, alice.name, alice.balance },
    );

    var cb2 = try client.customer.Create();
    defer cb2.deinit();
    _ = try cb2.setFieldValue("name", "Bob");
    _ = try cb2.setFieldValue("email", "bob@example.com");
    _ = try cb2.setFieldValue("balance", 100.00);
    const bob = try cb2.Save();

    // ----- Orders (with items via FK) -----
    _ = try createOrder(client, alice, mouse, keyboard);
    _ = try createOrder(client, bob, mouse, keyboard);
    {
        // Single-item order (espresso only)
        var ob = try client.order.Create();
        defer ob.deinit();
        _ = try ob.setFieldValue("total", espresso.price);
        _ = try ob.setFieldValue("status", "pending");
        _ = try ob.setFieldValue("created_at", @as(i64, 1700000000));
        const o = try ob.Save();
        std.debug.print("order: id={d} customer={s} total={d:.2}\n", .{ o.id, alice.name, o.total });
        var ib = try client.order_item.Create();
        defer ib.deinit();
        _ = try ib.setFieldValue("quantity", 1);
        _ = try ib.setFieldValue("product_id", espresso.id);
        _ = try ib.setFieldValue("order_id", o.id);
        _ = try ib.Save();
    }

    // ------------------------------------------------------------------
    // QUERIES
    // ------------------------------------------------------------------
    std.debug.print("\n=== QUERIES ===\n", .{});

    // 1 — Filter + order + limit
    std.debug.print("\n-- price > 50, desc --\n", .{});
    {
        var q = client.product.Query();
        defer q.deinit();
        _ = try q.Where(.{prod_preds.priceGT(.{ .float = 50.0 })});
        _ = try q.OrderBy(&.{sql.Order{ .column = .{ .name = "price", .desc = true } }});
        const prods = try q.All();
        defer dropAll(infos, prod_info, allocator, prods);
        for (prods.items) |p| {
            std.debug.print("  {s:20} ${d:>7.2}  stock={d}\n", .{ p.name, p.price, p.stock });
        }
    }

    // 2 — Eager loading: products with tags
    std.debug.print("\n-- Products with tags (eager loaded) --\n", .{});
    {
        var q = client.product.Query();
        defer q.deinit();
        _ = try q.WithEdge("tags");
        const prods = try q.All();
        defer dropAll(infos, prod_info, allocator, prods);
        for (prods.items) |p| {
            std.debug.print("  {s:20}", .{p.name});
            if (p.edges.tags) |tags| {
                std.debug.print("  tags: ", .{});
                for (tags) |t| std.debug.print("{s} ", .{t.value});
            }
            std.debug.print("\n", .{});
        }
    }

    // 3 — Aggregates
    std.debug.print("\n-- Aggregates --\n", .{});
    {
        var q = client.product.Query();
        defer q.deinit();
        std.debug.print("  product count: {d}\n", .{try q.Count()});
    }
    {
        var q = client.order.Query();
        defer q.deinit();
        std.debug.print("  avg order total: ${d:.2}\n", .{try q.Avg("total")});
    }
    {
        var q = client.product.Query();
        defer q.deinit();
        const hi = try q.Max("price");
        const lo = try q.Min("price");
        const hi_f = switch (hi) {
            .float => |v| v,
            .int => |v| @as(f64, @floatFromInt(v)),
            else => @as(f64, 0),
        };
        const lo_f = switch (lo) {
            .float => |v| v,
            .int => |v| @as(f64, @floatFromInt(v)),
            else => @as(f64, 0),
        };
        std.debug.print("  price range: ${d:.2} – ${d:.2}\n", .{ lo_f, hi_f });
    }
    {
        var q = client.order.Query();
        defer q.deinit();
        std.debug.print("  total revenue: ${d:.2}\n", .{try q.Sum("total")});
    }

    // 4 — GroupBy + Having
    std.debug.print("\n-- GroupBy tag value (count >= 2) --\n", .{});
    {
        var q = client.tag.Query();
        defer q.deinit();
        _ = try q.GroupBy(&.{"value"});
        _ = q.Having(sql.GT("COUNT(*)", .{ .int = 1 }));
        const tags = try q.All();
        defer dropAll(infos, tag_info, allocator, tags);
        for (tags.items) |t| {
            std.debug.print("  {s}\n", .{t.value});
        }
    }

    // 5 — EntQL parser
    std.debug.print("\n-- EntQL: 'price > 50 AND stock < 100' --\n", .{});
    {
        const pred = try zent.entql.parse(allocator, "price > 50 AND stock < 100");
        var q = client.product.Query();
        defer q.deinit();
        _ = try q.Where(&[_]sql.Predicate{pred});
        const prods = try q.All();
        defer dropAll(infos, prod_info, allocator, prods);
        for (prods.items) |p| {
            std.debug.print("  {s:20} ${d:>7.2}  stock={d}\n", .{ p.name, p.price, p.stock });
        }
    }

    // 6 — Check existence
    std.debug.print("\n-- Exist (stock < 10) --\n", .{});
    {
        var q = client.product.Query();
        defer q.deinit();
        _ = try q.Where(.{prod_preds.stockLT(.{ .int = 10 })});
        std.debug.print("  exists: {}\n", .{try q.Exist()});
    }

    // ------------------------------------------------------------------
    // BULK OPERATIONS
    // ------------------------------------------------------------------
    std.debug.print("\n=== BULK ===\n", .{});

    // 7 — BulkInsert
    std.debug.print("\n-- BulkInsert 3 products --\n", .{});
    {
        var b = try client.product.BulkInsert();
        defer b.deinit();
        _ = try b.setFieldValue("name", "USB-C Cable");
        _ = try b.setFieldValue("price", 12.50);
        _ = try b.setFieldValue("stock", 500);
        _ = try b.Next();
        _ = try b.setFieldValue("name", "Monitor Stand");
        _ = try b.setFieldValue("price", 89.00);
        _ = try b.setFieldValue("stock", 30);
        _ = try b.Next();
        _ = try b.setFieldValue("name", "Webcam 4K");
        _ = try b.setFieldValue("price", 199.00);
        _ = try b.setFieldValue("stock", 45);
        const ids = try b.Save();
        defer ids.deinit();
        std.debug.print("  inserted {d} products:", .{ids.items.len});
        for (ids.items) |id| std.debug.print(" {d}", .{id});
        std.debug.print("\n", .{});
    }

    // 8 — BulkUpdate: +10% on electronics
    std.debug.print("\n-- BulkUpdate: +10% on electronics (mouse & kb) --\n", .{});
    {
        var bu = client.product.BulkUpdate();
        defer bu.deinit();
        const new_mouse = mouse.price * 1.10;
        const new_kb = keyboard.price * 1.10;
        _ = try bu.Row(mouse.id);
        _ = try bu.set("price", .{ .float = new_mouse });
        _ = try bu.Row(keyboard.id);
        _ = try bu.set("price", .{ .float = new_kb });
        const n = try bu.Save();
        std.debug.print("  updated {d} row(s): mouse ${d:.2}, kb ${d:.2}\n", .{ n, new_mouse, new_kb });
    }

    // 9 — BulkDelete: remove luxury + kitchen tags
    std.debug.print("\n-- BulkDelete: 'luxury' OR 'kitchen' --\n", .{});
    {
        var bd = try client.tag.BulkDelete();
        defer bd.deinit();
        _ = try bd.Where(.{client.tag.predicates.valueEQ(.{ .string = "luxury" })});
        _ = try bd.Next();
        _ = try bd.Where(.{client.tag.predicates.valueEQ(.{ .string = "kitchen" })});
        const n = try bd.Exec();
        std.debug.print("  deleted {d} tag(s)\n", .{n});
    }

    // ------------------------------------------------------------------
    // TRANSACTION
    // ------------------------------------------------------------------
    std.debug.print("\n=== TRANSACTION ===\n", .{});
    {
        var tx = try zent.codegen.client.beginTx(infos, client);
        defer tx.deinit();

        var pb = try tx.client.product.Create();
        defer pb.deinit();
        _ = try pb.setFieldValue("name", "TX Product");
        _ = try pb.setFieldValue("price", 99.00);
        _ = try pb.setFieldValue("stock", 10);
        const tx_prod = try pb.Save();
        std.debug.print("  tx product id={d}\n", .{tx_prod.id});

        try tx.commit();
        std.debug.print("  committed\n", .{});

        // verify
        var vq = client.product.Query();
        defer vq.deinit();
        _ = try vq.Where(.{client.product.predicates.nameEQ(.{ .string = "TX Product" })});
        const verified = try vq.Only();
        std.debug.print("  verified: id={d} name={s}\n", .{ verified.id, verified.name });
    }

    // ------------------------------------------------------------------
    // SaveOrUpdate (upsert)
    // ------------------------------------------------------------------
    std.debug.print("\n=== SaveOrUpdate ===\n", .{});
    {
        var pb = try client.product.Create();
        defer pb.deinit();
        _ = try pb.setFieldValue("name", "Wireless Mouse v2");
        _ = try pb.setFieldValue("price", 34.99);
        _ = try pb.setFieldValue("stock", 200);
        const upserted = try pb.SaveOrUpdate();
        std.debug.print(
            "  upserted: id={d} name={s} price={d:.2}\n",
            .{ upserted.id, upserted.name, upserted.price },
        );
    }

    // ------------------------------------------------------------------
    std.debug.print("\n=== All phases completed ===\n", .{});

    std.debug.print("\n=== All phases completed ===\n", .{});
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn createOrder(
    client: anytype,
    customer: anytype,
    mouse: anytype,
    keyboard: anytype,
) !void {
    // Two items: 2x mouse + 1x keyboard
    const total = mouse.price * 2.0 + keyboard.price * 1.0;
    var ob = try client.order.Create();
    defer ob.deinit();
    _ = try ob.setFieldValue("total", total);
    _ = try ob.setFieldValue("status", "pending");
    _ = try ob.setFieldValue("created_at", @as(i64, 1700000000));
    const order = try ob.Save();
    std.debug.print(
        "order: id={d} customer={s} total={d:.2}\n",
        .{ order.id, customer.name, order.total },
    );

    // Create order-item linking to products (using FK edges)
    {
        var ib = try client.order_item.Create();
        defer ib.deinit();
        _ = try ib.setFieldValue("quantity", 2);
        _ = try ib.setFieldValue("product_id", mouse.id);
        _ = try ib.setFieldValue("order_id", order.id);
        _ = try ib.Save();
    }
    {
        var ib = try client.order_item.Create();
        defer ib.deinit();
        _ = try ib.setFieldValue("quantity", 1);
        _ = try ib.setFieldValue("product_id", keyboard.id);
        _ = try ib.setFieldValue("order_id", order.id);
        _ = try ib.Save();
    }
}

fn dropAll(comptime infos: []const zent.codegen.graph.TypeInfo, comptime ti: zent.codegen.graph.TypeInfo, allocator: std.mem.Allocator, list: anytype) void {
    _ = infos;
    _ = ti;
    _ = allocator;
    list.deinit();
}
