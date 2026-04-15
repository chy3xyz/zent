const std = @import("std");
const TypeInfo = @import("graph.zig").TypeInfo;
const FieldInfo = @import("graph.zig").FieldInfo;
const EdgeInfo = @import("graph.zig").EdgeInfo;
const sql = @import("../sql/builder.zig");
const sql_driver = @import("../sql/driver.zig");
const sql_scan = @import("../sql/scan.zig");
const Dialect = @import("../sql/dialect.zig").Dialect;
const privacy = @import("../privacy/policy.zig");

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
        distinct: bool,
        with_trashed: bool,

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver) Self {
            return .{
                .allocator = allocator,
                .driver = driver,
                .predicates = std.array_list.Managed(sql.Predicate).init(allocator),
                .order_terms = std.array_list.Managed(sql.Order).init(allocator),
                .limit_val = null,
                .offset_val = null,
                .distinct = false,
                .with_trashed = false,
            };
        }

        pub fn deinit(self: *Self) void {
            self.predicates.deinit();
            self.order_terms.deinit();
        }

        pub fn Where(self: *Self, predicates: anytype) *Self {
            switch (@typeInfo(@TypeOf(predicates))) {
                .pointer, .array => {
                    for (predicates) |p| {
                        self.predicates.append(p) catch unreachable;
                    }
                },
                .@"struct" => |s| {
                    if (s.is_tuple) {
                        inline for (predicates) |p| {
                            self.predicates.append(p) catch unreachable;
                        }
                    } else {
                        @compileError("Where expects a tuple or slice of sql.Predicate");
                    }
                },
                else => @compileError("Where expects a tuple or slice of sql.Predicate"),
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

        pub fn Page(self: *Self, page_num: usize, per_page: usize) *Self {
            self.limit_val = per_page;
            self.offset_val = (page_num - 1) * per_page;
            return self;
        }

        pub fn Distinct(self: *Self) *Self {
            self.distinct = true;
            return self;
        }

        pub fn WithTrashed(self: *Self) *Self {
            self.with_trashed = true;
            return self;
        }

        fn checkPolicy(comptime op: privacy.Op) !void {
            if (info.policy) |p| {
                if (p.evalQuery(op, info.table_name) == .deny) {
                    return error.PrivacyDenied;
                }
            }
        }

        pub fn All(self: *Self) !std.array_list.Managed(Entity) {
            try checkPolicy(.query);
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
            try checkPolicy(.query);
            self.limit_val = 1;
            const q = try self.buildQuery(info.fields.len);
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();

            const row = rows.next() orelse return null;
            return try sql_scan.scanRow(Entity, self.allocator, row);
        }

        pub fn Only(self: *Self) !Entity {
            try checkPolicy(.query);
            const q = try self.buildQuery(info.fields.len);
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();

            const row = rows.next() orelse return error.NotFound;
            const entity = try sql_scan.scanRow(Entity, self.allocator, row);
            if (rows.next() != null) return error.NotSingular;
            return entity;
        }

        pub fn IDs(self: *Self) !std.array_list.Managed(i64) {
            try checkPolicy(.query);
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
            try checkPolicy(.query);
            const q = try self.buildCountQuery();
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();

            const row = rows.next() orelse return error.NotFound;
            return row.getInt(0) orelse return error.TypeMismatch;
        }

        pub fn Exist(self: *Self) !bool {
            try checkPolicy(.query);
            self.limit_val = 1;
            const q = try self.buildQuery(1);
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();
            return rows.next() != null;
        }

        pub fn Sum(self: *Self, comptime field_name: []const u8) !i64 {
            try checkPolicy(.query);
            const q = try self.buildAggregateQuery("SUM(\"" ++ field_name ++ "\")");
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();
            const row = rows.next() orelse return error.NotFound;
            return row.getInt(0) orelse return error.TypeMismatch;
        }

        pub fn Avg(self: *Self, comptime field_name: []const u8) !f64 {
            try checkPolicy(.query);
            const q = try self.buildAggregateQuery("AVG(\"" ++ field_name ++ "\")");
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();
            const row = rows.next() orelse return error.NotFound;
            return row.getFloat(0) orelse return error.TypeMismatch;
        }

        pub fn Max(self: *Self, comptime field_name: []const u8) !sql.Value {
            try checkPolicy(.query);
            const q = try self.buildAggregateQuery("MAX(\"" ++ field_name ++ "\")");
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();
            const row = rows.next() orelse return error.NotFound;
            if (row.isNull(0)) return .null;
            if (row.getInt(0)) |v| return .{ .int = v };
            if (row.getFloat(0)) |v| return .{ .float = v };
            if (row.getText(0)) |v| return .{ .string = v };
            return error.TypeMismatch;
        }

        pub fn Min(self: *Self, comptime field_name: []const u8) !sql.Value {
            try checkPolicy(.query);
            const q = try self.buildAggregateQuery("MIN(\"" ++ field_name ++ "\")");
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();
            const row = rows.next() orelse return error.NotFound;
            if (row.isNull(0)) return .null;
            if (row.getInt(0)) |v| return .{ .int = v };
            if (row.getFloat(0)) |v| return .{ .float = v };
            if (row.getText(0)) |v| return .{ .string = v };
            return error.TypeMismatch;
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
            _ = selector.setDistinct(self.distinct);

            if (self.predicates.items.len > 0) {
                for (self.predicates.items) |pred| {
                    _ = selector.where(pred);
                }
            }
            if (info.soft_delete and !self.with_trashed) {
                _ = selector.where(sql.IsNull("deleted_at"));
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
            if (info.soft_delete and !self.with_trashed) {
                _ = selector.where(sql.IsNull("deleted_at"));
            }
            return try selector.query();
        }

        fn buildAggregateQuery(self: *Self, comptime agg_expr: []const u8) !sql.QueryResult {
            const t = sql.Table(info.table_name);
            const agg_col = sql.ColumnRef{ .table = null, .name = agg_expr, .raw = true };
            var selector = sql.Select(self.allocator, self.driver.dialect(), &.{agg_col});
            _ = selector.from(t);
            if (self.predicates.items.len > 0) {
                for (self.predicates.items) |pred| {
                    _ = selector.where(pred);
                }
            }
            if (info.soft_delete and !self.with_trashed) {
                _ = selector.where(sql.IsNull("deleted_at"));
            }
            if (self.limit_val) |n| {
                _ = selector.limit(n);
            }
            if (self.offset_val) |n| {
                _ = selector.offset(n);
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
