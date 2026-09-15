//! Generic CRUD service for zent — the schema-as-code answer to
//! zmsaas' sqlx `CrudService`: one `CrudService(infos, info, tenant_col)`
//! gives list/get/create/update/delete over the generated EntityClient,
//! and writes publish `CrudEvent{created,updated,deleted}` to an optional
//! listener (the after-hook surface — no sqlx, no string SQL).
//!
//! Ownership follows zent's caller-owned contract: `list` returns
//! `PagedResult` (deinit once), `get` returns an entity whose strings are
//! owned (caller frees via `zent.codegen.deinitEntity`).

const std = @import("std");
const graph_mod = @import("codegen/graph.zig");
const codegen = @import("codegen/client.zig");
const EntityGen = @import("codegen/entity.zig").Entity;
const QueryGen = @import("codegen/query.zig").QueryBuilder;
const sql = @import("sql/builder.zig");
const sql_driver = @import("sql/driver.zig");
const Dialect = @import("sql/dialect.zig").Dialect;

pub fn CrudEvent(comptime infos: []const graph_mod.TypeInfo, comptime info: graph_mod.TypeInfo) type {
    _ = infos;
    _ = info;
    return union(enum) {
        created: i64,
        updated: i64,
        deleted: i64,
    };
}

pub fn CrudService(
    comptime infos: []const graph_mod.TypeInfo,
    comptime info: graph_mod.TypeInfo,
    comptime tenant_col: []const u8,
) type {
    const Entity = EntityGen(infos, info);
    const Client = codegen.EntityClient(infos, info);
    const PagedResult = QueryGen(infos, info, Entity).PagedResult;

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        client: Client,
        /// Event source: called after each successful write (the zent
        /// after-hook surface). App wires it to its own bus.
        on_event: ?*const fn (CrudEvent(infos, info)) void = null,

        pub fn init(allocator: std.mem.Allocator, client: Client) Self {
            return .{ .allocator = allocator, .client = client };
        }

        pub fn setEventListener(self: *Self, listener: *const fn (CrudEvent(infos, info)) void) void {
            self.on_event = listener;
        }

        fn tenantPred(self: *Self, tenant_id: i64) sql.Predicate {
            return @field(self.client.predicates, tenant_col ++ "EQ")(.{ .int = tenant_id });
        }

        fn idPred(self: *Self, id: i64) sql.Predicate {
            return @field(self.client.predicates, info.pk_field ++ "EQ")(.{ .int = id });
        }

        /// Paged list scoped to the tenant (zent paged(): one count + one
        /// limit/offset). Caller `defer result.deinit()`.
        pub fn list(self: *Self, tenant_id: i64, page: usize, size: usize) !PagedResult {
            var q = self.client.Query();
            defer q.deinit();
            _ = try q.Where(.{self.tenantPred(tenant_id)});
            return q.paged(page, size);
        }

        /// Single row scoped to the tenant. Caller frees via
        /// `zent.codegen.deinitEntity(infos, info, &e, alloc)`.
        pub fn get(self: *Self, allocator: std.mem.Allocator, tenant_id: i64, id: i64) !?Entity {
            var q = self.client.Query();
            defer q.deinit();
            _ = try q.Where(.{ self.tenantPred(tenant_id), self.idPred(id) });
            var found = try q.All();
            defer {
                for (found.items) |*e| {
                    // Scan rows are allocated with the *client* allocator —
                    // freeing them with the caller's allocator (e.g. a request
                    // arena) is mismatched-free UB and corrupts arena state.
                    zent_deinit(infos, info, e, self.allocator);
                }
                found.deinit();
            }
            return if (found.items.len > 0) try ownedCopy(allocator, found.items[0]) else null;
        }

        /// Create from a scalar-field entity; publishes CrudEvent.created.
        ///
        /// `tenant_id` is a **parameter**, like every other method on this
        /// service, and it is the value that gets written to `tenant_col`. It is
        /// deliberately not read from `entity`: the write loop used to copy every
        /// field including the tenant column, and the interceptor that scopes
        /// creates only fills a column it finds *missing* — so a caller-supplied
        /// entity with the zero value (the default of a freshly built one) won
        /// the race against the bound tenant and wrote `0`. Taking it as an
        /// argument removes the ambiguity rather than documenting it.
        pub fn create(self: *Self, entity: Entity, tenant_id: i64) !i64 {
            var b = try self.client.Create();
            defer b.deinit();
            _ = try b.setFieldValue(tenant_col, tenant_id);
            inline for (info.fields) |f| {
                // id is auto-generated; the tenant column comes from the
                // parameter above; audit fields (created_by/updated_by) are owned
                // by fillAuditUser from the privacy context.
                if (!f.is_id and
                    !std.mem.eql(u8, f.name, "created_by") and
                    !std.mem.eql(u8, f.name, "updated_by") and
                    !std.mem.eql(u8, f.name, tenant_col))
                {
                    _ = try b.setFieldValue(f.name, @field(entity, f.name));
                }
            }
            var row = try b.Save();
            defer zent_deinit(infos, info, &row, self.allocator);
            if (self.on_event) |cb| cb(.{ .created = row.id });
            return row.id;
        }

        /// Update a tenant-scoped row (id + tenant fixed); publishes
        /// CrudEvent.updated. Returns false when the row is missing — "missing"
        /// meaning the (id, tenant) pair matches no row, not "nothing changed":
        /// an idempotent PUT that writes the fetched values back must answer
        /// true on every dialect.
        pub fn update(self: *Self, entity: Entity, tenant_id: i64) !bool {
            var b = self.client.Update();
            defer b.deinit();
            inline for (info.fields) |f| {
                if (!f.is_id and !std.mem.eql(u8, f.name, tenant_col) and !std.mem.eql(u8, f.name, "created_by") and !std.mem.eql(u8, f.name, "updated_by")) {
                    _ = try b.setFieldValue(f.name, @field(entity, f.name));
                }
            }
            _ = try b.Where(.{ self.tenantPred(tenant_id), self.idPred(entity.id) });
            const affected = try b.Save();
            var found = affected > 0;
            if (!found) {
                // MySQL reports *changed* rows (CLIENT_FOUND_ROWS is off), so an
                // idempotent PUT answers 0 although the row exists; SQLite and
                // PostgreSQL report *matched* rows and never reach this branch.
                // The contract above is "false = row missing", so the zero path
                // re-checks existence with the same (tenant, id) scope instead
                // of trusting the count — the shape updateWithVersion already
                // uses for its optimistic-lock zero. One extra query, only on
                // the zero path, only on MySQL in practice.
                var q = self.client.Query();
                defer q.deinit();
                _ = try q.Where(.{ self.tenantPred(tenant_id), self.idPred(entity.id) });
                found = (try q.Count()) > 0;
            }
            if (found) {
                if (self.on_event) |cb| cb(.{ .updated = entity.id });
            }
            return found;
        }

        /// Delete a tenant-scoped row; publishes CrudEvent.deleted.
        pub fn delete(self: *Self, tenant_id: i64, id: i64) !bool {
            var b = self.client.Delete();
            defer b.deinit();
            _ = try b.Where(.{ self.tenantPred(tenant_id), self.idPred(id) });
            const affected = try b.Exec();
            if (affected > 0) {
                if (self.on_event) |cb| cb(.{ .deleted = id });
            }
            return affected > 0;
        }

        /// Batch insert in one statement (id auto-generated). Caller deinits
        /// the returned id list. Emits one CrudEvent.created per row.
        pub fn insertMany(self: *Self, entities: []const Entity) !std.array_list.Managed(i64) {
            var b = try self.client.BulkInsert();
            defer b.deinit();
            for (entities) |e| {
                inline for (info.fields) |f| {
                    if (f.is_id) continue;
                    _ = try b.setFieldValue(f.name, @field(e, f.name));
                }
                _ = try b.Next();
            }
            const ids = try b.Save();
            if (self.on_event) |cb| {
                for (ids.items) |id| cb(.{ .created = id });
            }
            return ids;
        }

        /// Batch upsert in one statement (`INSERT … ON CONFLICT DO UPDATE` /
        /// `ON DUPLICATE KEY UPDATE`). The conflict key (id) is written, so
        /// rows with an existing id update and new ids insert. Caller deinits
        /// the returned id list. No CrudEvent is emitted (insert-vs-update is
        /// indistinguishable from the returned ids).
        pub fn upsertMany(self: *Self, entities: []const Entity) !std.array_list.Managed(i64) {
            var b = try self.client.BulkInsert();
            defer b.deinit();
            for (entities) |e| {
                inline for (info.fields) |f| {
                    _ = try b.setFieldValue(f.name, @field(e, f.name));
                }
                _ = try b.Next();
            }
            return b.SaveOrUpdate();
        }
    };
}

const zent_deinit = @import("codegen/entity.zig").deinitEntity;

/// Owned copy of a scanned entity: struct fields are copied and string
/// fields are duplicated into `allocator`.
fn ownedCopy(allocator: std.mem.Allocator, src: anytype) !@TypeOf(src) {
    const T = @TypeOf(src);
    var out: T = src;
    const fields = @typeInfo(T).@"struct".field_names;
    const types = @typeInfo(T).@"struct".field_types;
    inline for (fields, types) |fname, ftype| {
        if (ftype == []const u8) {
            @field(out, fname) = try allocator.dupe(u8, @field(src, fname));
        } else if (ftype == ?[]const u8) {
            if (@field(src, fname)) |s| {
                @field(out, fname) = try allocator.dupe(u8, s);
            }
        }
    }
    return out;
}

test "CrudService list/get/create/update/delete with events and tenant isolation" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");
    const deinitEntity = @import("codegen/entity.zig").deinitEntity;

    const Product = Schema("Product", .{ .fields = &.{
        field.Int("tenant_id"),
        field.String("name"),
        field.Int("price_cents"),
    } });

    const info = comptime fromSchema(Product);
    const TypeInfo = graph_mod.TypeInfo;
    const infos = &[_]TypeInfo{info};
    const Service = CrudService(infos, info, "tenant_id");

    const Recorder = struct {
        var count: usize = 0;
        var created: i64 = 0;
        var updated: i64 = 0;
        var deleted: i64 = 0;
        fn on(e: CrudEvent(infos, info)) void {
            count += 1;
            switch (e) {
                .created => |id| created = id,
                .updated => |id| updated = id,
                .deleted => |id| deleted = id,
            }
        }
    };

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);

    const Client = codegen.EntityClient(infos, info);
    const client = Client.init(allocator, driver.asDriver());
    var svc = Service.init(allocator, client);
    svc.setEventListener(&Recorder.on);

    const a_id = try svc.create(.{ .id = 0, .tenant_id = 0, .name = "a", .price_cents = 100 }, 1);
    const b_id = try svc.create(.{ .id = 0, .tenant_id = 0, .name = "b", .price_cents = 200 }, 1);
    const c_id = try svc.create(.{ .id = 0, .tenant_id = 0, .name = "c", .price_cents = 300 }, 2);
    try std.testing.expectEqual(@as(i64, 3), Recorder.created);
    try std.testing.expectEqual(@as(usize, 3), Recorder.count);

    var page1 = try svc.list(1, 1, 10);
    defer page1.deinit();
    try std.testing.expectEqual(@as(i64, 2), page1.total);
    try std.testing.expectEqual(@as(usize, 2), page1.items.items.len);

    var page2 = try svc.list(2, 1, 10);
    defer page2.deinit();
    try std.testing.expectEqual(@as(usize, 1), page2.items.items.len);

    var got = (try svc.get(allocator, 1, a_id)).?;
    defer deinitEntity(infos, info, &got, allocator);
    try std.testing.expectEqualStrings("a", got.name);
    // Tenant isolation: tenant 2 must not see tenant 1's row.
    try std.testing.expect((try svc.get(allocator, 2, a_id)) == null);

    var updated = got;
    updated.name = "a2";
    try std.testing.expect(try svc.update(updated, 1));
    try std.testing.expectEqual(a_id, Recorder.updated);

    try std.testing.expect(try svc.delete(2, c_id));
    try std.testing.expectEqual(c_id, Recorder.deleted);
    try std.testing.expect(!try svc.delete(2, c_id)); // already gone

    _ = b_id;
}

test "CrudService get with mismatched allocator (arena copy)" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");
    const deinitEntity = @import("codegen/entity.zig").deinitEntity;

    const Item = Schema("Item", .{ .fields = &.{
        field.Int("tenant_id"),
        field.String("name"),
    } });
    const info = comptime fromSchema(Item);
    const TypeInfo = graph_mod.TypeInfo;
    const infos = &[_]TypeInfo{info};
    const Service = CrudService(infos, info, "tenant_id");

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);

    const Client = codegen.EntityClient(infos, info);
    const client = Client.init(allocator, driver.asDriver());
    var svc = Service.init(allocator, client);
    const id = try svc.create(.{ .id = 0, .tenant_id = 0, .name = "hello-world" }, 7);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var got = (try svc.get(arena.allocator(), 7, id)).?;
    defer deinitEntity(infos, info, &got, arena.allocator());
    try std.testing.expectEqualStrings("hello-world", got.name);

    // The entity above carries `tenant_id = 0`, and the row belongs to 7: the
    // parameter is what is written, not the caller's entity. Before this both
    // reads below found the row, because the write loop copied the entity's
    // tenant column and the interceptor only fills a column it finds missing.
    try std.testing.expect((try svc.get(arena.allocator(), 8, id)) == null);
    try std.testing.expect((try svc.get(arena.allocator(), 0, id)) == null);
}

test "CrudService insertMany/upsertMany batch writes" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");

    const Product = Schema("BatchProduct", .{
        .fields = &.{
            field.Int("tenant_id"),
            field.String("name"),
            field.Int("price_cents"),
        },
    });
    const info = comptime fromSchema(Product);
    const TypeInfo = graph_mod.TypeInfo;
    const infos = &[_]TypeInfo{info};
    const Service = CrudService(infos, info, "tenant_id");

    const Recorder = struct {
        var created: usize = 0;
        fn on(e: CrudEvent(infos, info)) void {
            switch (e) {
                .created => created += 1,
                else => {},
            }
        }
    };

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);

    const Client = codegen.EntityClient(infos, info);
    const client = Client.init(allocator, driver.asDriver());
    var svc = Service.init(allocator, client);
    svc.setEventListener(&Recorder.on);

    const ids = try svc.insertMany(&.{
        .{ .id = 0, .tenant_id = 1, .name = "a", .price_cents = 100 },
        .{ .id = 0, .tenant_id = 1, .name = "b", .price_cents = 200 },
        .{ .id = 0, .tenant_id = 1, .name = "c", .price_cents = 300 },
    });
    defer ids.deinit();
    try std.testing.expectEqual(@as(usize, 3), ids.items.len);
    try std.testing.expectEqual(@as(usize, 3), Recorder.created);

    var page = try svc.list(1, 1, 10);
    defer page.deinit();
    try std.testing.expectEqual(@as(i64, 3), page.total);

    // Upsert: update existing id + insert a new row (id 0 -> new).
    const ups = try svc.upsertMany(&.{
        .{ .id = ids.items[0], .tenant_id = 1, .name = "a2", .price_cents = 150 },
        .{ .id = 0, .tenant_id = 1, .name = "d", .price_cents = 400 },
    });
    defer ups.deinit();
    try std.testing.expectEqual(@as(usize, 2), ups.items.len);

    var page2 = try svc.list(1, 1, 10);
    defer page2.deinit();
    try std.testing.expectEqual(@as(i64, 4), page2.total);
}

test "CrudService handles optional string fields in create/get" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");
    const deinitEntity = @import("codegen/entity.zig").deinitEntity;

    const Product = Schema("OptionalProduct", .{
        .fields = &.{
            field.Int("tenant_id"),
            field.String("name"),
            field.String("description").Optional(),
        },
    });
    const info = comptime fromSchema(Product);
    const TypeInfo = graph_mod.TypeInfo;
    const infos = &[_]TypeInfo{info};
    const Service = CrudService(infos, info, "tenant_id");

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);
    const client = codegen.EntityClient(infos, info).init(allocator, driver.asDriver());
    var svc = Service.init(allocator, client);

    const a_id = try svc.create(.{ .id = 0, .tenant_id = 0, .name = "a", .description = null }, 1);
    const b_id = try svc.create(.{ .id = 0, .tenant_id = 0, .name = "b", .description = "desc" }, 1);

    var got_a = (try svc.get(allocator, 1, a_id)).?;
    defer deinitEntity(infos, info, &got_a, allocator);
    try std.testing.expect(got_a.description == null);

    var got_b = (try svc.get(allocator, 1, b_id)).?;
    defer deinitEntity(infos, info, &got_b, allocator);
    try std.testing.expectEqualStrings("desc", got_b.description.?);
}

/// A driver that answers every statement with the shape MySQL produces for an
/// idempotent write: the UPDATE reports **0 changed rows** (CLIENT_FOUND_ROWS
/// is off) while the row exists, and the existence re-check `Count()` query
/// reports a configurable row count. Lets the zero path of
/// `CrudService.update` be observed without a MySQL server.
const ChangedRowsDriver = struct {
    /// What the count query answers: 1 = row exists, 0 = row missing.
    count_value: i64 = 0,
    update_calls: usize = 0,
    count_queries: usize = 0,
    row_consumed: bool = false,

    fn execFn(ptr: *anyopaque, _: ?*const sql_driver.ExecutionContext, query_sql: []const u8, _: []const sql.Value) sql_driver.Error!sql_driver.Result {
        const self: *ChangedRowsDriver = @ptrCast(@alignCast(ptr));
        if (std.mem.startsWith(u8, query_sql, "UPDATE")) self.update_calls += 1;
        return .{ .rows_affected = 0, .rows_affected_known = true, .last_insert_id = null };
    }

    fn queryFn(ptr: *anyopaque, _: ?*const sql_driver.ExecutionContext, _: []const u8, _: []const sql.Value) sql_driver.Error!sql_driver.Rows {
        const self: *ChangedRowsDriver = @ptrCast(@alignCast(ptr));
        self.count_queries += 1;
        self.row_consumed = false;
        return .{ .ptr = self, .vtable = &rows_vtable };
    }

    fn beginTxFn(_: *anyopaque) sql_driver.Error!sql_driver.Tx {
        return error.TxFailed;
    }

    fn closeFn(_: *anyopaque) void {}

    fn dialectFn(_: *anyopaque) Dialect {
        return .mysql;
    }

    fn pingFn(_: *anyopaque) sql_driver.Error!void {}

    fn inTxFn(_: *anyopaque) bool {
        return false;
    }

    fn savepointFn(_: *anyopaque, _: []const u8) sql_driver.Error!sql_driver.Tx {
        return error.TxFailed;
    }

    const vtable = sql_driver.Driver.VTable{
        .exec = execFn,
        .query = queryFn,
        .beginTx = beginTxFn,
        .close = closeFn,
        .dialect = dialectFn,
        .ping = pingFn,
        .inTransaction = inTxFn,
        .beginSavepoint = savepointFn,
    };

    fn asDriver(self: *ChangedRowsDriver) sql_driver.Driver {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const rows_vtable = sql_driver.Rows.VTable{
        .next = rowsNext,
        .deinit = rowsDeinit,
    };

    fn rowsNext(ptr: *anyopaque) ?sql_driver.Row {
        const self: *ChangedRowsDriver = @ptrCast(@alignCast(ptr));
        if (self.row_consumed) return null;
        self.row_consumed = true;
        return .{ .ptr = self, .vtable = &row_vtable };
    }

    fn rowsDeinit(_: *anyopaque) void {}

    const row_vtable = sql_driver.Row.VTable{
        .columnCount = rowColumnCount,
        .columnName = rowColumnName,
        .getBool = rowGetBool,
        .getInt = rowGetInt,
        .getFloat = rowGetFloat,
        .getText = rowGetText,
        .getBlob = rowGetBlob,
        .isNull = rowIsNull,
    };

    fn rowColumnCount(_: *anyopaque) usize {
        return 1;
    }
    fn rowColumnName(_: *anyopaque, _: usize) []const u8 {
        return "count";
    }
    fn rowGetBool(_: *anyopaque, _: usize) ?bool {
        return null;
    }
    fn rowGetInt(ptr: *anyopaque, _: usize) ?i64 {
        const self: *ChangedRowsDriver = @ptrCast(@alignCast(ptr));
        return self.count_value;
    }
    fn rowGetFloat(_: *anyopaque, _: usize) ?f64 {
        return null;
    }
    fn rowGetText(_: *anyopaque, _: usize) ?[]const u8 {
        return null;
    }
    fn rowGetBlob(_: *anyopaque, _: usize) ?[]const u8 {
        return null;
    }
    fn rowIsNull(_: *anyopaque, _: usize) bool {
        return false;
    }
};

test "CrudService update answers true for an idempotent write (0 changed rows, row exists)" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;

    const Product = Schema("ChangedRowsProduct", .{ .fields = &.{
        field.Int("tenant_id"),
        field.String("name"),
        field.Int("price_cents"),
    } });
    const info = comptime fromSchema(Product);
    const TypeInfo = graph_mod.TypeInfo;
    const infos = &[_]TypeInfo{info};
    const Service = CrudService(infos, info, "tenant_id");

    const Recorder = struct {
        var updated: i64 = -1;
        fn on(e: CrudEvent(infos, info)) void {
            switch (e) {
                .updated => |id| updated = id,
                else => {},
            }
        }
    };

    var mock = ChangedRowsDriver{ .count_value = 1 };
    const client = codegen.EntityClient(infos, info).init(allocator, mock.asDriver());
    var svc = Service.init(allocator, client);
    svc.setEventListener(&Recorder.on);

    // The UPDATE reports 0 changed rows — MySQL's answer when the values are
    // written back unchanged — but the row exists. The answer must be true
    // (what SQLite/PostgreSQL already answer with their matched-rows count),
    // and the updated event must fire exactly as it does on those dialects.
    try std.testing.expect(try svc.update(.{ .id = 7, .tenant_id = 0, .name = "a", .price_cents = 100 }, 1));
    try std.testing.expectEqual(@as(i64, 7), Recorder.updated);
    try std.testing.expectEqual(@as(usize, 1), mock.update_calls);
    // The zero path cost exactly one existence query.
    try std.testing.expectEqual(@as(usize, 1), mock.count_queries);
}

test "CrudService update answers false when the row is missing (0 changed rows, no row)" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;

    const Product = Schema("MissingRowProduct", .{ .fields = &.{
        field.Int("tenant_id"),
        field.String("name"),
    } });
    const info = comptime fromSchema(Product);
    const TypeInfo = graph_mod.TypeInfo;
    const infos = &[_]TypeInfo{info};
    const Service = CrudService(infos, info, "tenant_id");

    const Recorder = struct {
        var fired: bool = false;
        fn on(e: CrudEvent(infos, info)) void {
            switch (e) {
                .updated => fired = true,
                else => {},
            }
        }
    };

    var mock = ChangedRowsDriver{ .count_value = 0 };
    const client = codegen.EntityClient(infos, info).init(allocator, mock.asDriver());
    var svc = Service.init(allocator, client);
    svc.setEventListener(&Recorder.on);

    // 0 changed rows and the existence re-check finds nothing: false, and no
    // updated event — the 404 answer the doc comment promises.
    try std.testing.expect(!(try svc.update(.{ .id = 42, .tenant_id = 0, .name = "a" }, 1)));
    try std.testing.expect(!Recorder.fired);
}

test "CrudService update idempotent write-back on sqlite returns true; missing row returns false" {
    const allocator = std.testing.allocator;
    const field = @import("core/field.zig");
    const Schema = @import("core/schema.zig").Schema;
    const fromSchema = @import("codegen/graph.zig").fromSchema;
    const migrate = @import("sql/schema/migrate.zig");
    const sqlite_driver = @import("sql/sqlite.zig");
    const deinitEntity = @import("codegen/entity.zig").deinitEntity;

    const Product = Schema("IdempotentProduct", .{ .fields = &.{
        field.Int("tenant_id"),
        field.String("name"),
        field.Int("price_cents"),
    } });
    const info = comptime fromSchema(Product);
    const TypeInfo = graph_mod.TypeInfo;
    const infos = &[_]TypeInfo{info};
    const Service = CrudService(infos, info, "tenant_id");

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);

    const client = codegen.EntityClient(infos, info).init(allocator, driver.asDriver());
    var svc = Service.init(allocator, client);

    const id = try svc.create(.{ .id = 0, .tenant_id = 0, .name = "a", .price_cents = 100 }, 1);

    var got = (try svc.get(allocator, 1, id)).?;
    defer deinitEntity(infos, info, &got, allocator);
    // Idempotent PUT: the fetched row written back unchanged. On MySQL the
    // UPDATE counts 0 changed rows; on SQLite it counts the matched row —
    // either way the answer is true (the MySQL-shaped case is pinned against
    // a real server in tests/integration/mysql.zig and against
    // ChangedRowsDriver above).
    try std.testing.expect(try svc.update(got, 1));

    // Missing row: false, through the same zero path with a real driver.
    var gone = got;
    gone.id = 999999;
    try std.testing.expect(!(try svc.update(gone, 1)));
}
