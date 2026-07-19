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
const Logger = @import("../sql/logger.zig").Logger;
const LogContext = @import("../sql/logger.zig").LogContext;
const nowUs = @import("../sql/logger.zig").nowUs;
const deinitEntity = @import("entity.zig").deinitEntity;
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
        cursor_col: ?[]const u8 = null,
        cursor_val: ?sql.Value = null,
        distinct: bool,
        with_trashed: bool,
        with_edges: std.ArrayListUnmanaged([]const u8),
        group_cols: std.ArrayListUnmanaged([]const u8),
        having_pred: ?sql.Predicate,
        for_update: bool,
        for_share: bool,
        privacy_ctx: ?privacy.PrivacyContext = null,
        logger: Logger = .{},

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver, privacy_ctx: ?privacy.PrivacyContext) Self {
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
                .privacy_ctx = privacy_ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            self.predicates.deinit();
            self.order_terms.deinit();
            self.with_edges.deinit(self.allocator);
            self.group_cols.deinit(self.allocator);
        }

        pub fn Where(self: *Self, predicates: anytype) !*Self {
            const PredT = @TypeOf(predicates);
            const pred_info = @typeInfo(PredT);
            switch (pred_info) {
                .pointer => |ptr| {
                    switch (@typeInfo(ptr.child)) {
                        .array => {
                            for (predicates) |p| {
                                try self.predicates.append(p);
                            }
                        },
                        .@"struct" => |s| {
                            if (s.is_tuple) {
                                inline for (predicates.*) |p| {
                                    try self.predicates.append(p);
                                }
                            } else {
                                @compileError("Where expects a tuple or slice of sql.Predicate");
                            }
                        },
                        else => @compileError("Where expects a tuple or slice of sql.Predicate"),
                    }
                },
                .array => {
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

        /// Set a cursor column and value for keyset/cursor-based pagination.
        /// When set, the generated query appends `WHERE (col > ?) ORDER BY col ASC`
        /// and uses `limit_val` as the page size. Mutually exclusive with `Offset`/`Page`.
        pub fn Cursor(self: *Self, column: []const u8, value: sql.Value) *Self {
            self.cursor_col = column;
            self.cursor_val = value;
            return self;
        }

        /// Set a cursor to page after a given entity, using its `id` field.
        pub fn CursorAfter(self: *Self, entity: Entity) *Self {
            self.cursor_col = "id";
            self.cursor_val = .{ .int = entity.id };
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

        const QueryError = sql_driver.Error || error{ PrivacyDenied, NotFound, NotSingular, TypeMismatch, MissingColumn, InvalidEdge, BuildFailed };
        const BuildError = error{ OutOfMemory, BuildFailed };

        fn mapBuildError(err: anyerror) BuildError {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.BuildFailed,
            };
        }

        fn checkPolicy(self: *const Self) error{PrivacyDenied}!privacy.DecisionSet {
            if (info.policy) |p| {
                const ctx = self.privacy_ctx orelse return error.PrivacyDenied;
                const result = p.eval(ctx);
                if (result.decision == .deny) return error.PrivacyDenied;
                return result;
            }
            return privacy.DecisionSet{ .decision = .allow };
        }

        /// Inject privacy row-level filters (DecisionSet.filters) into the query predicates.
        fn injectPrivacyFilters(self: *Self, decision_set: privacy.DecisionSet) !void {
            const filters = decision_set.getFilters();
            for (filters) |opaque_ptr| {
                const pred: *const sql.Predicate = @ptrCast(@alignCast(opaque_ptr));
                try self.predicates.append(pred.*);
            }
        }

        pub fn All(self: *Self) QueryError!std.array_list.Managed(Entity) {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            var q = try self.buildQuery(info.fields.len);
            defer q.deinit();
            const start = nowUs();
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();

            var result = std.array_list.Managed(Entity).init(self.allocator);
            errdefer {
                for (result.items) |*e| deinitEntity(infos, info, e, self.allocator);
                result.deinit();
            }

            while (rows.next()) |row| {
                var entity = try sql_scan.scanRow(Entity, self.allocator, row);
                errdefer deinitEntity(infos, info, &entity, self.allocator);
                try result.append(entity);
            }
            if (rows.nextError()) |e| return e;

            const duration_us: u64 = nowUs() - start;
            if (self.logger.onQuery) |log| {
                log(.{
                    .sql = q.sql,
                    .args = q.args,
                    .duration_us = duration_us,
                    .rows_affected = result.items.len,
                    .table_name = info.table_name,
                });
            }

            for (self.with_edges.items) |edge_name| {
                try self.loadEdges(edge_name, result.items);
            }
            return result;
        }

        pub fn First(self: *Self) QueryError!?Entity {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            self.limit_val = 1;
            var q = try self.buildQuery(info.fields.len);
            defer q.deinit();
            const start = nowUs();
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();

            const row = rows.next() orelse {
                if (rows.nextError()) |e| return e;
                return null;
            };
            var entity = try sql_scan.scanRow(Entity, self.allocator, row);
            errdefer deinitEntity(infos, info, &entity, self.allocator);

            const duration_us: u64 = nowUs() - start;
            if (self.logger.onQuery) |log| {
                log(.{
                    .sql = q.sql,
                    .args = q.args,
                    .duration_us = duration_us,
                    .rows_affected = 1,
                    .table_name = info.table_name,
                });
            }

            var entities_arr = [_]Entity{entity};
            for (self.with_edges.items) |edge_name| {
                try self.loadEdges(edge_name, &entities_arr);
            }
            return entities_arr[0];
        }

        pub fn Only(self: *Self) QueryError!Entity {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            var q = try self.buildQuery(info.fields.len);
            defer q.deinit();
            const start = nowUs();
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();

            const row = rows.next() orelse {
                if (rows.nextError()) |e| return e;
                return error.NotFound;
            };
            var entity = try sql_scan.scanRow(Entity, self.allocator, row);
            errdefer deinitEntity(infos, info, &entity, self.allocator);
            if (rows.next()) |_| return error.NotSingular;
            if (rows.nextError()) |e| return e;

            const duration_us: u64 = nowUs() - start;
            if (self.logger.onQuery) |log| {
                log(.{
                    .sql = q.sql,
                    .args = q.args,
                    .duration_us = duration_us,
                    .rows_affected = 1,
                    .table_name = info.table_name,
                });
            }

            var entities_arr = [_]Entity{entity};
            for (self.with_edges.items) |edge_name| {
                try self.loadEdges(edge_name, &entities_arr);
            }
            return entities_arr[0];
        }

        pub fn IDs(self: *Self) QueryError!std.array_list.Managed(i64) {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            var q = try self.buildQuery(1); // only id column
            defer q.deinit();
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();

            var result = std.array_list.Managed(i64).init(self.allocator);
            errdefer result.deinit();

            while (rows.next()) |row| {
                const id = row.getInt(0) orelse return error.TypeMismatch;
                try result.append(id);
            }
            if (rows.nextError()) |e| return e;
            return result;
        }

        pub fn Count(self: *Self) QueryError!i64 {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            var q = try self.buildCountQuery();
            defer q.deinit();
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();

            const row = rows.next() orelse {
                if (rows.nextError()) |e| return e;
                return error.NotFound;
            };
            return row.getInt(0) orelse return error.TypeMismatch;
        }

        pub fn Exist(self: *Self) QueryError!bool {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            self.limit_val = 1;
            var q = try self.buildQuery(1);
            defer q.deinit();
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();
            const maybe_row = rows.next();
            if (maybe_row == null) {
                if (rows.nextError()) |e| return e;
                return false;
            }
            return true;
        }

        pub fn Sum(self: *Self, comptime field_name: []const u8) QueryError!i64 {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            var q = try self.buildAggregateQuery("SUM(\"" ++ field_name ++ "\")");
            defer q.deinit();
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();
            const row = rows.next() orelse {
                if (rows.nextError()) |e| return e;
                return error.NotFound;
            };
            return row.getInt(0) orelse return error.TypeMismatch;
        }

        pub fn Avg(self: *Self, comptime field_name: []const u8) QueryError!f64 {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            var q = try self.buildAggregateQuery("AVG(\"" ++ field_name ++ "\")");
            defer q.deinit();
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();
            const row = rows.next() orelse {
                if (rows.nextError()) |e| return e;
                return error.NotFound;
            };
            return row.getFloat(0) orelse return error.TypeMismatch;
        }

        pub fn Max(self: *Self, comptime field_name: []const u8) QueryError!sql.Value {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            var q = try self.buildAggregateQuery("MAX(\"" ++ field_name ++ "\")");
            defer q.deinit();
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();
            const row = rows.next() orelse {
                if (rows.nextError()) |e| return e;
                return error.NotFound;
            };
            if (row.isNull(0)) return .null;
            if (row.getInt(0)) |v| return .{ .int = v };
            if (row.getFloat(0)) |v| return .{ .float = v };
            // Dup text while rows is still alive: row.getText borrows from the
            // driver-internal buffer which is freed on rows.deinit.
            if (row.getText(0)) |v| {
                const duped = try self.allocator.dupe(u8, v);
                return .{ .string = duped };
            }
            return error.TypeMismatch;
        }

        pub fn Min(self: *Self, comptime field_name: []const u8) QueryError!sql.Value {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            var q = try self.buildAggregateQuery("MIN(\"" ++ field_name ++ "\")");
            defer q.deinit();
            var rows = try self.driver.query(q.sql, q.args);
            defer rows.deinit();
            const row = rows.next() orelse {
                if (rows.nextError()) |e| return e;
                return error.NotFound;
            };
            if (row.isNull(0)) return .null;
            if (row.getInt(0)) |v| return .{ .int = v };
            if (row.getFloat(0)) |v| return .{ .float = v };
            if (row.getText(0)) |v| {
                const duped = try self.allocator.dupe(u8, v);
                return .{ .string = duped };
            }
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
                    graph_neighbors.appendSetNeighbors(&b, step, parent_id_values) catch |err| return mapBuildError(err);
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
                    if (rows.nextError()) |e| return e;

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

        fn buildQuery(self: *Self, comptime column_count: usize) !sql.OwnedQuery {
            const t = sql.Table(info.table_name);
            var columns: [column_count]sql.ColumnRef = undefined;
            inline for (info.fields[0..column_count], 0..) |f, i| {
                columns[i] = t.c(f.name);
            }
            var selector = try sql.Select(self.allocator, self.driver.dialect(), &columns);
            _ = selector.from(t);
            _ = selector.setDistinct(self.distinct);

            if (self.predicates.items.len > 0) {
                for (self.predicates.items) |pred| {
                    _ = try selector.where(pred);
                }
            }
            if (self.cursor_col) |col| {
                if (self.cursor_val) |val| {
                    _ = try selector.where(sql.GT(col, val));
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
            if (self.cursor_col) |col| {
                // When cursor pagination is active, ensure ORDER BY col ASC is present.
                if (self.order_terms.items.len == 0) {
                    _ = try selector.orderBy(sql.OrderAsc(col));
                }
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
            return selector.takeQuery() catch |err| return mapBuildError(err);
        }

        fn buildCountQuery(self: *Self) !sql.OwnedQuery {
            const t = sql.Table(info.table_name);
            const count_col = sql.ColumnRef{ .table = null, .name = "COUNT(*)", .raw = true };
            var selector = try sql.Select(self.allocator, self.driver.dialect(), &.{count_col});
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
            return selector.takeQuery() catch |err| return mapBuildError(err);
        }

        fn buildAggregateQuery(self: *Self, comptime agg_expr: []const u8) !sql.OwnedQuery {
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
            return selector.takeQuery() catch |err| return mapBuildError(err);
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

    var q = UserQuery.init(std.testing.allocator, undefined, null);
    defer q.deinit();

    _ = try q.Where(&.{sql.EQ("age", .{ .int = 30 })});
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

    var q = UserQuery.init(std.testing.allocator, undefined, null);
    defer q.deinit();

    _ = try q.WithEdge("cars");
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

    var q = UserQuery.init(std.testing.allocator, undefined, null);
    defer q.deinit();

    _ = (try q.GroupBy(&.{"age"})).Having(sql.GT("COUNT(*)", .{ .int = 1 }));
    try std.testing.expectEqual(@as(usize, 1), q.group_cols.items.len);
    try std.testing.expectEqualStrings("age", q.group_cols.items[0]);
}

test "Query builder execution methods expose explicit driver error union" {
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
    const QueryError = sql_driver.Error || error{ PrivacyDenied, NotFound, NotSingular, TypeMismatch, MissingColumn, InvalidEdge, BuildFailed };

    comptime {
        const method_names = .{ "All", "First", "Only", "IDs", "Count", "Exist", "Sum", "Avg", "Max", "Min" };
        for (method_names) |method_name| {
            const return_type = @typeInfo(@TypeOf(@field(UserQuery, method_name))).@"fn".return_type.?;
            if (@typeInfo(return_type).error_union.error_set != QueryError) {
                @compileError("QueryBuilder." ++ method_name ++ " error set is not explicit");
            }
        }
    }
}

test "Query builder cursor pagination" {
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

    var q = UserQuery.init(std.testing.allocator, undefined, null);
    defer q.deinit();

    _ = q.Cursor("id", .{ .int = 42 }).Limit(10);
    try std.testing.expectEqualStrings("id", q.cursor_col.?);
    try std.testing.expectEqual(@as(i64, 42), q.cursor_val.?.int);
    try std.testing.expectEqual(@as(usize, 10), q.limit_val.?);
}

test "Query builder CursorAfter sets id" {
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

    var q = UserQuery.init(std.testing.allocator, undefined, null);
    defer q.deinit();

    const entity = UserEntity{ .id = 99, .name = "", .age = 0 };
    _ = q.CursorAfter(entity).Limit(5);
    try std.testing.expectEqualStrings("id", q.cursor_col.?);
    try std.testing.expectEqual(@as(i64, 99), q.cursor_val.?.int);
}
