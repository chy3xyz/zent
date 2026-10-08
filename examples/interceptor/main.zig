const std = @import("std");
const zent = @import("zent");

const sql = zent.sql;
const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
const buildGraph = zent.codegen.graph.buildGraph;
const Client = zent.codegen.client;
const migrate = zent.sql_schema;
const Schema = zent.core.schema.Schema;
const field = zent.core.field;

/// A single table carrying a `tenant_id` column. In a real multi-tenant app
/// every scoped table has this column; the interceptor injects it into each
/// query/update/delete so callers never have to remember to filter.
const Doc = Schema("Doc", .{
    .fields = &.{
        field.Int("tenant_id"),
        field.String("title"),
        field.String("body").Optional(),
    },
});

pub fn main() !void {
    // page_allocator keeps the demo short; query pages are still released
    // with the pairing `q.deinitRows(&docs)` (see printTitles), and the
    // client's interceptor chain with `DeinitClient` below. For production
    // also release the single entities via `client.<entity>.deinitRow(&e)` —
    // the ownership contract is in docs/ARCHITECTURE.md.
    const allocator = std.heap.page_allocator;

    const graph = comptime buildGraph(&.{Doc});
    const infos = graph.types;

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    try migrate.migrateSchema(allocator, drv.asDriver(), infos);

    var client = Client.makeClient(infos, allocator, drv.asDriver());
    defer Client.DeinitClient(infos, &client);

    // Seed two tenants before the interceptor is registered so we can insert
    // both tenant_id values explicitly. After UseInterceptor the create path
    // runs the same `whereEq` as a *filler*: a Create that omits tenant_id is
    // filled from ctx (an explicitly set tenant_id still wins) — demonstrated
    // right after registration below.
    try insertDoc(&client, 1, "tenant-1 doc A", "alpha");
    try insertDoc(&client, 1, "tenant-1 doc B", "beta");
    try insertDoc(&client, 2, "tenant-2 doc C", "gamma");

    // The current tenant id is runtime state carried by the interceptor ctx.
    var tenant: i64 = 1;
    try Client.UseInterceptor(infos, &client, .{
        .ctx = &tenant,
        .intercept = struct {
            fn f(ctx: ?*anyopaque, view: *zent.runtime.intercept.QueryView) anyerror!void {
                const id: *i64 = @ptrCast(@alignCast(ctx.?));
                // Adds `tenant_id = ?` to the WHERE clause of every
                // query/update/delete on any table that has the field.
                try view.whereEq("tenant_id", .{ .int = id.* });
            }
        }.f,
    });

    // The comment above promised it: a Create that omits tenant_id is filled
    // from ctx (set-if-missing), so the row lands in tenant 1 without the
    // caller naming a tenant. The Count()/printTitles() right below read the
    // row back from the database and show it scoped to tenant 1.
    var auto_b = try client.doc.Create();
    defer auto_b.deinit();
    _ = try auto_b.setFieldValue("title", "tenant-1 doc D (tenant_id filled)");
    _ = try auto_b.setFieldValue("body", "no tenant_id set by the caller");
    const auto_doc = try auto_b.Save();
    std.debug.print(
        "tenant={d}: Create() without tenant_id saved with tenant_id={d}\n",
        .{ tenant, auto_doc.tenant_id },
    );

    var q1 = client.doc.Query();
    defer q1.deinit();
    std.debug.print("tenant={d}: Count() = {d}\n", .{ tenant, try q1.Count() });
    try printTitles(&client);

    // Switch tenant at runtime — the same code path now sees tenant 2 only.
    tenant = 2;
    var q2 = client.doc.Query();
    defer q2.deinit();
    std.debug.print("tenant={d}: Count() = {d}\n", .{ tenant, try q2.Count() });
    try printTitles(&client);

    // Update is transparently scoped: no Where clause, yet only the current
    // tenant's rows are touched.
    tenant = 1;
    var ub = client.doc.Update();
    defer ub.deinit();
    _ = try ub.setFieldValue("title", "rewritten by tenant-1");
    const updated = try ub.Save();
    std.debug.print("tenant={d}: Update().Save() affected {d} row(s)\n", .{ tenant, updated });

    // Delete is scoped the same way.
    var db = client.doc.Delete();
    defer db.deinit();
    const deleted = try db.Exec();
    std.debug.print("tenant={d}: Delete().Exec() affected {d} row(s)\n", .{ tenant, deleted });

    // Tenant 2's row survived both the update and the delete.
    tenant = 2;
    var q3 = client.doc.Query();
    defer q3.deinit();
    std.debug.print("tenant={d}: Count() after tenant-1 update+delete = {d}\n", .{ tenant, try q3.Count() });
}

fn insertDoc(client: anytype, tenant: i64, title: []const u8, body: []const u8) !void {
    var b = try client.doc.Create();
    defer b.deinit();
    _ = try b.setFieldValue("tenant_id", tenant);
    _ = try b.setFieldValue("title", title);
    _ = try b.setFieldValue("body", body);
    _ = try b.Save();
}

fn printTitles(client: anytype) !void {
    var q = client.doc.Query();
    defer q.deinit();
    var docs = try q.All();
    // One call frees the entities and the list — the pairing release for an
    // `All()` page (no per-item deinitEntity loop to keep in step).
    defer q.deinitRows(&docs);
    for (docs.items) |*d| {
        std.debug.print("    id={d} tenant={d} title={s}\n", .{ d.id, d.tenant_id, d.title });
    }
}
