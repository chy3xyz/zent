const std = @import("std");
const TypeInfo = @import("graph.zig").TypeInfo;
const FieldInfo = @import("graph.zig").FieldInfo;
const EdgeInfo = @import("graph.zig").EdgeInfo;
const sql = @import("../sql/builder.zig");
const sql_driver = @import("../sql/driver.zig");
const sql_scan = @import("../sql/scan.zig");
const Dialect = @import("../sql/dialect.zig").Dialect;

/// Generate a Query builder for an entity.
pub fn QueryBuilder(comptime info: TypeInfo, comptime Entity: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        driver: sql_driver.Driver,
        predicates: std.array_list.Managed(sql.Predicate),
        order_terms: std.array_list.Managed(sql.Order),
        limit_val: ?usize,
        offset_val: ?usize,

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver) Self {
            return .{
                .allocator = allocator,
                .driver = driver,
                .predicates = std.array_list.Managed(sql.Predicate).init(allocator),
                .order_terms = std.array_list.Managed(sql.Order).init(allocator),
                .limit_val = null,
                .offset_val = null,
            };
        }

        pub fn deinit(self: *Self) void {
            self.predicates.deinit();
            self.order_terms.deinit();
        }

        pub fn Where(self: *Self, ps: []const sql.Predicate) *Self {
            for (ps) |p| {
                self.predicates.append(p) catch unreachable;
            }
            return self;
        }

        pub fn OrderBy(self: *Self, terms: []const sql.Order) *Self {
            for (terms) |t| {
                self.order_terms.append(t) catch unreachable;
            }
            return self;
        }

        pub fn Limit(self: *Self, n: usize) *Self {
            self.limit_val = n;
            return self;
        }

        pub fn Offset(self: *Self, n: usize) *Self {
            self.offset_val = n;
            return self;
        }

        pub fn All(self: *Self) !std.array_list.Managed(Entity) {
            const q = try self.buildQuery(info.fields.len);
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();

            var result = std.array_list.Managed(Entity).init(self.allocator);
            errdefer result.deinit();

            while (rows.next()) |row| {
                const entity = try sql_scan.scanRow(Entity, self.allocator, row);
                result.append(entity) catch unreachable;
            }
            return result;
        }

        pub fn First(self: *Self) !?Entity {
            self.limit_val = 1;
            const q = try self.buildQuery(info.fields.len);
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();

            const row = rows.next() orelse return null;
            return try sql_scan.scanRow(Entity, self.allocator, row);
        }

        pub fn Only(self: *Self) !Entity {
            const q = try self.buildQuery(info.fields.len);
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();

            const row = rows.next() orelse return error.NotFound;
            const entity = try sql_scan.scanRow(Entity, self.allocator, row);
            if (rows.next() != null) return error.NotSingular;
            return entity;
        }

        pub fn IDs(self: *Self) !std.array_list.Managed(i64) {
            const q = try self.buildQuery(1); // only id column
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();

            var result = std.array_list.Managed(i64).init(self.allocator);
            errdefer result.deinit();

            while (rows.next()) |row| {
                const id = row.getInt(0) orelse return error.TypeMismatch;
                result.append(id) catch unreachable;
            }
            return result;
        }

        pub fn Count(self: *Self) !i64 {
            const q = try self.buildCountQuery();
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();

            const row = rows.next() orelse return error.NotFound;
            return row.getInt(0) orelse return error.TypeMismatch;
        }

        pub fn Exist(self: *Self) !bool {
            self.limit_val = 1;
            const q = try self.buildQuery(1);
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();
            return rows.next() != null;
        }

        fn buildQuery(self: *Self, comptime column_count: usize) !sql.QueryResult {
            const t = sql.Table(info.table_name);
            var columns: [column_count]sql.ColumnRef = undefined;
            inline for (info.fields[0..column_count], 0..) |f, i| {
                columns[i] = t.c(f.name);
            }
            var selector = sql.Select(self.allocator, self.driver.dialect(), &columns);
            // NOTE: defer selector.deinit() would free the SQL buffer before caller uses it.
            _ = selector.from(t);

            if (self.predicates.items.len > 0) {
                for (self.predicates.items) |pred| {
                    _ = selector.where(pred);
                }
            }
            if (self.order_terms.items.len > 0) {
                for (self.order_terms.items) |term| {
                    _ = selector.orderBy(term);
                }
            }
            if (self.limit_val) |n| {
                _ = selector.limit(n);
            }
            if (self.offset_val) |n| {
                _ = selector.offset(n);
            }
            return try selector.query();
        }

        fn buildCountQuery(self: *Self) !sql.QueryResult {
            const t = sql.Table(info.table_name);
            const count_col = sql.ColumnRef{ .table = null, .name = "COUNT(*)", .raw = true };
            var selector = sql.Select(self.allocator, self.driver.dialect(), &.{count_col});
            // NOTE: defer selector.deinit() would free the SQL buffer before caller uses it.
            _ = selector.from(t);
            if (self.predicates.items.len > 0) {
                for (self.predicates.items) |pred| {
                    _ = selector.where(pred);
                }
            }
            return try selector.query();
        }
    };
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Query builder basic" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const UserEntity = comptime EntityGen(info);
    const UserQuery = QueryBuilder(info, UserEntity);

    var q = UserQuery.init(std.testing.allocator, undefined);
    defer q.deinit();

    _ = q.Where(&.{sql.EQ("age", .{ .int = 30 })});
    try std.testing.expectEqual(@as(usize, 1), q.predicates.items.len);
}
