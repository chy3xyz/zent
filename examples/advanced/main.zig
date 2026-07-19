const std = @import("std");
const zent = @import("zent");
const schema = @import("schema.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const buildGraph = zent.codegen.graph.buildGraph;
    const Client = zent.codegen.client;
    const graph = comptime buildGraph(&.{ schema.department, schema.employee, schema.project, schema.task });
    const infos = graph.types;

    const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    try zent.sql_schema.migrateSchema(allocator, drv.asDriver(), infos);
    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // ═══ 1. CREATE seed ═══
    std.debug.print("-- 1. CREATE seed --\n", .{});
    var cb = try client.department.Create(); defer cb.deinit();
    _ = try cb.setFieldValue("name", "Engineering");
    _ = try cb.setFieldValue("budget", @as(f64, 2_500_000));
    const dept_eng = try cb.Save();

    var cb2 = try client.department.Create(); defer cb2.deinit();
    _ = try cb2.setFieldValue("name", "Sales");
    _ = try cb2.setFieldValue("budget", @as(f64, 800_000));
    const dept_sales = try cb2.Save();

    var eb = try client.employee.Create(); defer eb.deinit();
    _ = try eb.setFieldValue("name", "Alice Chen");
    _ = try eb.setFieldValue("salary", @as(f64, 180_000));
    _ = try eb.setFieldValue("level", "senior");
    _ = try eb.setFieldValue("tenant_id", @as(i64, 1));
    _ = try eb.setFieldValue("department_id", dept_eng.id);
    const alice = try eb.Save();

    var eb2 = try client.employee.Create(); defer eb2.deinit();
    _ = try eb2.setFieldValue("name", "Bob Marley");
    _ = try eb2.setFieldValue("salary", @as(f64, 150_000));
    _ = try eb2.setFieldValue("level", "mid");
    _ = try eb2.setFieldValue("tenant_id", @as(i64, 1));
    _ = try eb2.setFieldValue("department_id", dept_eng.id);
    const bob = try eb2.Save();

    var eb3 = try client.employee.Create(); defer eb3.deinit();
    _ = try eb3.setFieldValue("name", "Carol Davis");
    _ = try eb3.setFieldValue("salary", @as(f64, 200_000));
    _ = try eb3.setFieldValue("level", "lead");
    _ = try eb3.setFieldValue("tenant_id", @as(i64, 1));
    _ = try eb3.setFieldValue("department_id", dept_sales.id);
    const carol = try eb3.Save();

    var eb4 = try client.employee.Create(); defer eb4.deinit();
    _ = try eb4.setFieldValue("name", "Dave Wilson");
    _ = try eb4.setFieldValue("salary", @as(f64, 85_000));
    _ = try eb4.setFieldValue("level", "junior");
    _ = try eb4.setFieldValue("tenant_id", @as(i64, 2));
    _ = try eb4.setFieldValue("department_id", dept_eng.id);
    const dave = try eb4.Save();

    var pb = try client.project.Create(); defer pb.deinit();
    _ = try pb.setFieldValue("name", "Alpha Platform");
    _ = try pb.setFieldValue("budget", @as(f64, 800_000));
    _ = try pb.setFieldValue("status", "active");
    _ = try pb.setFieldValue("department_id", dept_eng.id);
    const proj_alpha = try pb.Save();

    var pb2 = try client.project.Create(); defer pb2.deinit();
    _ = try pb2.setFieldValue("name", "Beta CRM");
    _ = try pb2.setFieldValue("budget", @as(f64, 400_000));
    _ = try pb2.setFieldValue("status", "active");
    _ = try pb2.setFieldValue("department_id", dept_sales.id);
    const proj_beta = try pb2.Save();

    var tb = try client.task.Create(); defer tb.deinit();
    _ = try tb.setFieldValue("title", "Design API v2");
    _ = try tb.setFieldValue("priority", @as(i64, 1));
    _ = try tb.setFieldValue("project_id", proj_alpha.id);
    _ = try tb.setFieldValue("assignee_id", alice.id);
    _ = try tb.Save();

    var tb2 = try client.task.Create(); defer tb2.deinit();
    _ = try tb2.setFieldValue("title", "Implement auth");
    _ = try tb2.setFieldValue("priority", @as(i64, 1));
    _ = try tb2.setFieldValue("project_id", proj_alpha.id);
    _ = try tb2.Save();

    var tb3 = try client.task.Create(); defer tb3.deinit();
    _ = try tb3.setFieldValue("title", "Deploy staging");
    _ = try tb3.setFieldValue("priority", @as(i64, 3));
    _ = try tb3.setFieldValue("project_id", proj_alpha.id);
    _ = try tb3.Save();

    std.debug.print("Seeded: 2 depts, 4 emps, 2 projs, 3 tasks\n", .{});

    // ═══ 2. EAGER LOADING ═══
    std.debug.print("\n-- 2. EAGER LOADING --\n", .{});
    {
        var q = try client.employee.Query();
        defer q.deinit();
        try q.WithEdge(client.employee.edges.department);
        try q.Where(.{client.employee.predicates.salaryGT(.{ .float = 100_000 })});
        const emps = try q.All(allocator);
        defer { for (emps.items) |*e| e.deinit(); emps.deinit(); }
        for (emps.items) |e| {
            std.debug.print("{s} (${d:.0}, {s})\n", .{ e.name, e.salary, e.level });
            if (e.edges.department) |d| std.debug.print("  dept: {s}\n", .{d.name});
        }
    }

    // ═══ 3. AGGREGATION ═══
    std.debug.print("\n-- 3. AGGREGATION --\n", .{});
    {
        var q = try client.employee.Query(); defer q.deinit();
        std.debug.print("Total salary: ${d:.0}\n", .{try q.Sum("salary")});
    }
    {
        var q = try client.employee.Query(); defer q.deinit();
        std.debug.print("Avg salary: ${d:.2}\n", .{try q.Avg("salary")});
    }
    {
        var q = try client.employee.Query(); defer q.deinit();
        const mn = try q.Min("salary");
        var q2 = try client.employee.Query(); defer q2.deinit();
        const mx = try q2.Max("salary");
        std.debug.print("Salary range: {d:.0}-{d:.0}\n", .{ mn.int, mx.int });
    }
    {
        var q = try client.employee.Query(); defer q.deinit();
        try q.Where(.{client.employee.predicates.levelEQ(.{ .string = "senior" })});
        std.debug.print("Count senior: {d}\n", .{try q.Count()});
    }

    // ═══ 4. CTE ═══
    std.debug.print("\n-- 4. CTE: task count per project --\n", .{});
    {
        var cte = zent.sql.Builder.init(allocator, zent.sql.Dialect.sqlite);
        defer cte.deinit();
        try cte.Select("task", &.{"project_id"});
        try cte.CountAs("cnt");
        try cte.GroupBy("project_id");
        const cteq = try cte.takeQuery();

        var mb = zent.sql.Builder.init(allocator, zent.sql.Dialect.sqlite);
        defer mb.deinit();
        try mb.with("task_counts", cteq);
        try mb.Select("project", &.{ "name" });
        _ = try mb.AddColumn("tc.cnt");
        try mb.InnerJoin("task_counts", "tc", "project.id = tc.project_id");
        try mb.OrderBy("tc.cnt", .desc);

        const rows = try drv.asDriver().query(mb.peekSQL(), mb.peekArgs());
        defer rows.deinit();
        while (rows.next()) |row| {
            std.debug.print("{s}: {d} tasks\n", .{ row.getText(0).?, row.getInt(1).? });
        }
    }

    // ═══ 5. CURSOR PAGINATION ═══
    std.debug.print("\n-- 5. CURSOR pagination --\n", .{});
    {
        var q = try client.employee.Query(); defer q.deinit();
        q.CursorDesc("salary", .{ .float = 999_999 });
        _ = q.Limit(2);
        const p1 = try q.All(allocator);
        defer { for (p1.items) |*e| e.deinit(); p1.deinit(); }
        std.debug.print("Top-paid (2/4):\n", .{});
        for (p1.items) |e| std.debug.print("  {s} ${d:.0}\n", .{ e.name, e.salary });
    }

    // ═══ 6. ENTQL ═══
    std.debug.print("\n-- 6. ENTQL: level IN(senior,lead) AND salary > 160k --\n", .{});
    {
        const pred = try zent.entql.parse(allocator, "level IN (\"senior\", \"lead\") AND salary > 160000");
        defer pred.deinit(allocator);
        var q = try client.employee.Query(); defer q.deinit();
        try q.Where(pred);
        const res = try q.All(allocator);
        defer { for (res.items) |*e| e.deinit(); res.deinit(); }
        for (res.items) |e| std.debug.print("{s} ({s}) ${d:.0}\n", .{ e.name, e.level, e.salary });
    }

    // ═══ 7. TRANSACTION ═══
    std.debug.print("\n-- 7. TRANSACTION --\n", .{});
    {
        var tx = try client.beginTx();
        defer tx.deinit();
        var upd = try tx.client.employee.Update();
        defer upd.deinit();
        _ = try upd.setFieldValue("level", "mid");
        _ = try upd.setFieldValue("salary", @as(f64, 110_000));
        _ = try upd.Where(.{tx.client.employee.predicates.idEQ(.{ .int = dave.id })});
        std.debug.print("Promoted {d} employee(s)\n", .{try upd.Save()});
        try tx.commit();
    }
    // Verify
    {
        var q = try client.employee.Query(); defer q.deinit();
        _ = try q.Where(.{client.employee.predicates.idEQ(.{ .int = dave.id })});
        const d = try q.Only(allocator);
        std.debug.print("Verified: {s} now {s}, ${d:.0}\n", .{ d.name, d.level, d.salary });
    }

    // ═══ 8. BULK INSERT ═══
    std.debug.print("\n-- 8. BULK insert + update --\n", .{});
    {
        var bulk = try client.task.BulkInsert();
        defer bulk.deinit();
        {
            var a = try bulk.Add();
            _ = try a.setFieldValue("title", "Code review");
            _ = try a.setFieldValue("priority", @as(i64, 3));
            _ = try a.setFieldValue("project_id", proj_alpha.id);
        }
        {
            var a2 = try bulk.Add();
            _ = try a2.setFieldValue("title", "Perf audit");
            _ = try a2.setFieldValue("priority", @as(i64, 2));
            _ = try a2.setFieldValue("project_id", proj_alpha.id);
        }
        const ids = try bulk.Save();
        defer allocator.free(ids);
        std.debug.print("Bulk inserted {d} tasks\n", .{ids.len});
    }
    {
        var bu = try client.task.BulkUpdate();
        defer bu.deinit();
        _ = try bu.setFieldValue("completed", @as(bool, true));
        _ = try bu.Where(.{client.task.predicates.priorityLTE(.{ .int = 1 })});
        std.debug.print("Bulk updated {d} high-priority tasks to completed\n", .{try bu.Save()});
    }

    // ═══ 9. EXISTS subquery ═══
    std.debug.print("\n-- 9. EXISTS: employees with tasks --\n", .{});
    {
        var q = try client.employee.Query(); defer q.deinit();
        try q.Where(.{client.employee.predicates.hasTasks()});
        std.debug.print("Employees with tasks: {d}\n", .{try q.Count()});
    }

    // ═══ 10. PRIVACY + UPSERT ═══
    std.debug.print("\n-- 10. PRIVACY context + UPSERT --\n", .{});
    {
        var q = try client.employee.Query(); defer q.deinit();
        q.WithContext(.{ .tenant_id = 1 });
        std.debug.print("Tenant 1 can see {d} employees\n", .{try q.Count()});
    }

    // UPSERT Demo
    {
        var up = try client.department.Create(); defer up.deinit();
        _ = try up.setFieldValue("name", "Engineering");
        _ = try up.setFieldValue("budget", @as(f64, 3_000_000));
        const d = try up.SaveOrUpdate();
        std.debug.print("Upserted Engineering: budget ${d:.0}\n", .{d.budget});
    }

    // ═══ VERIFY counts ═══
    std.debug.print("\n-- Summary --\n", .{});
    {
        var q = try client.employee.Query(); defer q.deinit();
        std.debug.print("Employees: {d}\n", .{try q.Count()});
    }
    {
        var q = try client.department.Query(); defer q.deinit();
        std.debug.print("Departments: {d}\n", .{try q.Count()});
    }
    {
        var q = try client.project.Query(); defer q.deinit();
        std.debug.print("Projects: {d}\n", .{try q.Count()});
    }
    {
        var q = try client.task.Query(); defer q.deinit();
        std.debug.print("Tasks: {d}\n", .{try q.Count()});
    }

    std.debug.print("\nAll advanced scenarios completed.\n", .{});
}

test {
    _ = @import("schema.zig");
}
