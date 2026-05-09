const std = @import("std");
const TypeInfo = @import("graph.zig").TypeInfo;
const FieldInfo = @import("graph.zig").FieldInfo;
const EdgeInfo = @import("graph.zig").EdgeInfo;
const buildEdgeStep = @import("graph.zig").buildEdgeStep;
const sql = @import("../sql/builder.zig");
const sql_driver = @import("../sql/driver.zig");
const sql_scan = @import("../sql/scan.zig");
const Dialect = @import("../sql/dialect.zig").Dialect;
const privacy = @import("../privacy/policy.zig");
const EntityGen = @import("entity.zig").Entity;
const LightEntityGen = @import("entity.zig").LightEntity;
const graph_step = @import("../graph/step.zig");
const graph_neighbors = @import("../graph/neighbors.zig");

fn findTypeInfo(comptime infos: []const TypeInfo, comptime name: []const u8) TypeInfo {
    for (infos) |ti| {
        if (std.mem.eql(u8, ti.name, name)) return ti;
    }
    @compileError("TypeInfo not found: " ++ name);
}

fn findEdgeInfo(comptime info: TypeInfo, comptime name: []const u8) EdgeInfo {
    for (info.edges) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    @compileError("Edge not found: " ++ name ++ " on " ++ info.name);
}

/// Generate a Query builder for an entity.
pub fn QueryBuilder(comptime infos: []const TypeInfo, comptime info: TypeInfo, comptime Entity: type) type {
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
        with_edges: std.ArrayListUnmanaged([]const u8),
        group_cols: std.ArrayListUnmanaged([]const u8),
        having_pred: ?sql.Predicate,
        for_update: bool,
        for_share: bool,

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
                .with_edges = .empty,
                .group_cols = .empty,
                .having_pred = null,
                .for_update = false,
                .for_share = false,
            };
        }

        pub fn deinit(self: *Self) void {
            self.predicates.deinit();
            self.order_terms.deinit();
            self.with_edges.deinit(self.allocator);
            self.group_cols.deinit(self.allocator);
        }

        pub fn Where(self: *Self, predicates: anytype) !*Self {
            switch (@typeInfo(@TypeOf(predicates))) {
                .pointer, .array => {
                    for (predicates) |p| {
                        try self.predicates.append(p);
                    }
                },
                .@"struct" => |s| {
                    if (s.is_tuple) {
                        inline for (predicates) |p| {
                            try self.predicates.append(p);
                        }
                    } else {
                        @compileError("Where expects a tuple or slice of sql.Predicate");
                    }
                },
                else => @compileError("Where expects a tuple or slice of sql.Predicate"),
            }
            return self;
        }

        pub fn OrderBy(self: *Self, terms: []const sql.Order) !*Self {
            for (terms) |t| {
                try self.order_terms.append(t);
            }
            return self;
        }

        /// Order results by the count of neighbors reachable via `edge_name`.
        /// For example, `OrderByEdgeCount("cars", .desc)` produces:
        ///   ORDER BY (SELECT COUNT(*) FROM "car" WHERE "car"."owner_id" = "user"."id") DESC
        pub fn OrderByEdgeCount(self: *Self, comptime edge_name: []const u8, comptime desc: bool) !*Self {
            const edge = comptime findEdgeInfo(info, edge_name);
            const target_info = comptime findTypeInfo(infos, edge.target_name);
            const step = comptime buildEdgeStep(edge, info, target_info);
            const order = sql.OrderExpr(struct {
                fn gen(b: *sql.Builder) anyerror!void {
                    try graph_neighbors.appendEdgeCount(b, step);
                }
            }.gen, desc);
            try self.order_terms.append(order);
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

        pub fn WithEdge(self: *Self, comptime edge_name: []const u8) !*Self {
            _ = comptime findEdgeInfo(info, edge_name);
            try self.with_edges.append(self.allocator, edge_name);
            return self;
        }

        pub fn GroupBy(self: *Self, columns: []const []const u8) !*Self {
            for (columns) |c| {
                try self.group_cols.append(self.allocator, c);
            }
            return self;
        }

        pub fn Having(self: *Self, pred: sql.Predicate) *Self {
            self.having_pred = pred;
            return self;
        }

        pub fn ForUpdate(self: *Self) *Self {
            self.for_update = true;
            return self;
        }

        pub fn ForShare(self: *Self) *Self {
            self.for_share = true;
            return self;
        }

        /// Free all eagerly-loaded edge slices on the given entities.
        pub fn deinitEdges(self: *Self, entities: []Entity) void {
            inline for (info.edges) |edge| {
                for (entities) |*e| {
                    if (@field(e.edges, edge.name)) |slice| {
                        self.allocator.free(slice);
                        @field(e.edges, edge.name) = null;
                    }
                }
            }
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
                try result.append(entity);
            }

            for (self.with_edges.items) |edge_name| {
                try self.loadEdges(edge_name, result.items);
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
            const entity = try sql_scan.scanRow(Entity, self.allocator, row);
            var entities_arr = [_]Entity{entity};
            for (self.with_edges.items) |edge_name| {
                try self.loadEdges(edge_name, &entities_arr);
            }
            return entities_arr[0];
        }

        pub fn Only(self: *Self) !Entity {
            try checkPolicy(.query);
            const q = try self.buildQuery(info.fields.len);
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();

            const row = rows.next() orelse return error.NotFound;
            const entity = try sql_scan.scanRow(Entity, self.allocator, row);
            if (rows.next() != null) return error.NotSingular;
            var entities_arr = [_]Entity{entity};
            for (self.with_edges.items) |edge_name| {
                try self.loadEdges(edge_name, &entities_arr);
            }
            return entities_arr[0];
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
                try result.append(id);
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

        fn loadEdges(self: *Self, edge_name: []const u8, entities: []Entity) !void {
            if (entities.len == 0) return;

            inline for (info.edges) |edge| {
                if (std.mem.eql(u8, edge_name, edge.name)) {
                    const target_info = comptime findTypeInfo(infos, edge.target_name);
                    const TargetEntity = comptime LightEntityGen(infos, target_info);
                    const step = comptime buildEdgeStep(edge, info, target_info);

                    // Build parent ID values
                    var parent_id_values = try self.allocator.alloc(sql.Value, entities.len);
                    defer self.allocator.free(parent_id_values);
                    for (entities, 0..) |e, i| {
                        parent_id_values[i] = .{ .int = e.id };
                    }

                    // Use the graph layer to build the neighbor query
                    var b = sql.Builder.init(self.allocator, self.driver.dialect());
                    defer b.deinit();
                    try graph_neighbors.appendSetNeighbors(&b, step, parent_id_values);
                    const qr = b.query();

                    var rows = try self.driver.query(qr.sql, qr.args);
                    defer rows.deinit();

                    var map = std.AutoHashMap(i64, std.ArrayListUnmanaged(TargetEntity)).init(self.allocator);
                    defer {
                        var it = map.iterator();
                        while (it.next()) |entry| {
                            entry.value_ptr.deinit(self.allocator);
                        }
                        map.deinit();
                    }

                    while (rows.next()) |row| {
                        const target = try sql_scan.scanRow(TargetEntity, self.allocator, row);
                        const fk_idx = sql_scan.findColumnIndex(row, "__fk") orelse return error.MissingColumn;
                        const parent_id = row.getInt(fk_idx) orelse return error.TypeMismatch;

                        var gop = try map.getOrPut(parent_id);
                        if (!gop.found_existing) {
                            gop.value_ptr.* = std.ArrayListUnmanaged(TargetEntity).empty;
                        }
                        try gop.value_ptr.append(self.allocator, target);
                    }

                    for (entities) |*e| {
                        if (map.get(e.id)) |list| {
                            const slice = try self.allocator.dupe(TargetEntity, list.items);
                            @field(e.edges, edge.name) = slice;
                        }
                    }
                    return;
                }
            }
            return error.InvalidEdge;
        }

        fn buildQuery(self: *Self, comptime column_count: usize) !sql.QueryResult {
            const t = sql.Table(info.table_name);
            var columns: [column_count]sql.ColumnRef = undefined;
            inline for (info.fields[0..column_count], 0..) |f, i| {
                columns[i] = t.c(f.name);
            }
            var selector = try sql.Select(self.allocator, self.driver.dialect(), &columns);
            // NOTE: defer selector.deinit() would free the SQL buffer before caller uses it.
            _ = selector.from(t);
            _ = selector.setDistinct(self.distinct);

            if (self.predicates.items.len > 0) {
                for (self.predicates.items) |pred| {
                    _ = try selector.where(pred);
                }
            }
            if (info.soft_delete and !self.with_trashed) {
                _ = try selector.where(sql.IsNull("deleted_at"));
            }
            if (self.group_cols.items.len > 0) {
                _ = try selector.groupBy(self.group_cols.items);
            }
            if (self.having_pred) |pred| {
                _ = selector.having(pred);
            }
            if (self.order_terms.items.len > 0) {
                for (self.order_terms.items) |term| {
                    _ = try selector.orderBy(term);
                }
            }
            if (self.limit_val) |n| {
                _ = selector.limit(n);
            }
            if (self.offset_val) |n| {
                _ = selector.offset(n);
            }
            if (self.for_update) {
                _ = selector.forUpdate();
            } else if (self.for_share) {
                _ = selector.forShare();
            }
            return try selector.query();
        }

        fn buildCountQuery(self: *Self) !sql.QueryResult {
            const t = sql.Table(info.table_name);
            const count_col = sql.ColumnRef{ .table = null, .name = "COUNT(*)", .raw = true };
            var selector = try sql.Select(self.allocator, self.driver.dialect(), &.{count_col});
            // NOTE: defer selector.deinit() would free the SQL buffer before caller uses it.
            _ = selector.from(t);
            if (self.predicates.items.len > 0) {
                for (self.predicates.items) |pred| {
                    _ = try selector.where(pred);
                }
            }
            if (info.soft_delete and !self.with_trashed) {
                _ = try selector.where(sql.IsNull("deleted_at"));
            }
            if (self.group_cols.items.len > 0) {
                _ = try selector.groupBy(self.group_cols.items);
            }
            if (self.having_pred) |pred| {
                _ = selector.having(pred);
            }
            return try selector.query();
        }

        fn buildAggregateQuery(self: *Self, comptime agg_expr: []const u8) !sql.QueryResult {
            const t = sql.Table(info.table_name);
            const agg_col = sql.ColumnRef{ .table = null, .name = agg_expr, .raw = true };
            var selector = try sql.Select(self.allocator, self.driver.dialect(), &.{agg_col});
            _ = selector.from(t);
            if (self.predicates.items.len > 0) {
                for (self.predicates.items) |pred| {
                    _ = try selector.where(pred);
                }
            }
            if (info.soft_delete and !self.with_trashed) {
                _ = try selector.where(sql.IsNull("deleted_at"));
            }
            if (self.group_cols.items.len > 0) {
                _ = try selector.groupBy(self.group_cols.items);
            }
            if (self.having_pred) |pred| {
                _ = selector.having(pred);
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
    const EntityGenerator = @import("entity.zig").Entity;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGenerator(infos, info);
    const UserQuery = QueryBuilder(infos, info, UserEntity);

    var q = UserQuery.init(std.testing.allocator, undefined);
    defer q.deinit();

    _ = q.Where(&.{sql.EQ("age", .{ .int = 30 })});
    try std.testing.expectEqual(@as(usize, 1), q.predicates.items.len);
}

test "Query builder WithEdge compiles" {
    const field = @import("../core/field.zig");
    const edge = @import("../core/edge.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGenerator = @import("entity.zig").Entity;

    const Car = schema("Car", .{
        .fields = &.{field.String("model")},
    });

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
        .edges = &.{edge.To("cars", Car)},
    });

    const user_info = comptime fromSchema(User);
    const car_info = comptime fromSchema(Car);
    const infos = &[_]TypeInfo{ user_info, car_info };
    const UserEntity = comptime EntityGenerator(infos, user_info);
    const UserQuery = QueryBuilder(infos, user_info, UserEntity);

    var q = UserQuery.init(std.testing.allocator, undefined);
    defer q.deinit();

    _ = q.WithEdge("cars");
    try std.testing.expectEqual(@as(usize, 1), q.with_edges.items.len);
    try std.testing.expectEqualStrings("cars", q.with_edges.items[0]);
}

test "Query builder GroupBy and Having" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGenerator = @import("entity.zig").Entity;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGenerator(infos, info);
    const UserQuery = QueryBuilder(infos, info, UserEntity);

    var q = UserQuery.init(std.testing.allocator, undefined);
    defer q.deinit();

    _ = q.GroupBy(&.{"age"}).Having(sql.GT("COUNT(*)", .{ .int = 1 }));
    try std.testing.expectEqual(@as(usize, 1), q.group_cols.items.len);
    try std.testing.expectEqualStrings("age", q.group_cols.items[0]);
}
