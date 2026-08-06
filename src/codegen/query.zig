const std = @import("std");
const TypeInfo = @import("graph.zig").TypeInfo;
const FieldInfo = @import("graph.zig").FieldInfo;
const EdgeInfo = @import("graph.zig").EdgeInfo;
const buildEdgeStep = @import("graph.zig").buildEdgeStep;
const sql = @import("../sql/builder.zig");
const sql_driver = @import("../sql/driver.zig");
const sql_scan = @import("../sql/scan.zig");

/// Scan an entity row, routing JSON struct fields into a per-entity arena
/// that deinitEntity releases — the same ownership contract as the Create
/// path. Bare (non-entity) scans keep the caller-owned behavior.
fn scanEntity(comptime T: type, allocator: std.mem.Allocator, row: sql_driver.Row) !T {
    if (comptime @hasField(T, "json_arena")) {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        return try sql_scan.scanRowWithArena(T, allocator, row, arena);
    }
    return sql_scan.scanRow(T, allocator, row);
}

/// Like `scanEntity` for the name-based (partial projection) scanner.
fn scanEntityNamed(comptime T: type, allocator: std.mem.Allocator, row: sql_driver.Row) !T {
    if (comptime @hasField(T, "json_arena")) {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        return try sql_scan.scanRowNamedWithArena(T, allocator, row, arena);
    }
    return sql_scan.scanRowNamed(T, allocator, row);
}
const Dialect = @import("../sql/dialect.zig").Dialect;
const privacy = @import("../privacy/policy.zig");
const Logger = @import("../sql/logger.zig").Logger;
const LogContext = @import("../sql/logger.zig").LogContext;
const nowUs = @import("../sql/logger.zig").nowUs;
const deinitEntity = @import("entity.zig").deinitEntity;
const EntityGen = @import("entity.zig").Entity;
const graph_step = @import("../graph/step.zig");
const graph_neighbors = @import("../graph/neighbors.zig");
const explain = @import("../sql/explain.zig");

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

fn splitEdgePath(path: []const u8) struct { head: []const u8, rest: []const u8 } {
    if (std.mem.indexOfScalar(u8, path, '.')) |dot| {
        return .{ .head = path[0..dot], .rest = path[dot + 1 ..] };
    }
    return .{ .head = path, .rest = "" };
}

/// Convert an entity primary key to a SQL value, supporting numeric (i64)
/// and textual (uuid) keys.
fn idValue(id: anytype) sql.Value {
    const T = @TypeOf(id);
    return if (comptime T == i64)
        .{ .int = id }
    else if (comptime T == []const u8 or T == [:0]const u8)
        .{ .string = id }
    else
        @compileError("Unsupported primary key type: " ++ @typeName(T));
}

/// Eager-load one or two levels of edges for a set of parent entities.
/// A dot path (`"posts.comments"`) recurses once into the loaded targets;
/// the terminal target type has no edges container, so deeper paths are a
/// compile error.
fn loadEdgePath(
    comptime infos: []const TypeInfo,
    comptime ParentInfo: TypeInfo,
    comptime ParentEntity: type,
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    execution_context: sql_driver.ExecutionContext,
    entities: []ParentEntity,
    path: []const u8,
) !void {
    if (entities.len == 0 or path.len == 0) return;
    const split = splitEdgePath(path);

    // Support both integer and textual (uuid) primary keys: the neighbor map
    // and __fk read are selected at compile time.
    const IdType = @TypeOf(@as(ParentEntity, undefined).id);

    inline for (ParentInfo.edges) |edge| {
        if (std.mem.eql(u8, edge.name, split.head)) {
            const target_info = comptime findTypeInfo(infos, edge.target_name);
            // Target type mirrors the parent's edges field: LightEntity for
            // the first level (so nesting can continue), PlainFields for the
            // terminal level.
            const EdgeFieldType = @TypeOf(@field(@as(ParentEntity, undefined).edges, edge.name));
            const TargetEntity = @typeInfo(@typeInfo(EdgeFieldType).optional.child).pointer.child;
            const step = comptime buildEdgeStep(edge, ParentInfo, target_info);
            const MapT = if (comptime IdType == i64)
                std.AutoHashMap(i64, std.ArrayListUnmanaged(TargetEntity))
            else if (comptime IdType == []const u8 or IdType == [:0]const u8)
                std.StringHashMap(std.ArrayListUnmanaged(TargetEntity))
            else
                @compileError("Unsupported primary key type for edges: " ++ @typeName(IdType));

            var parent_id_values = try allocator.alloc(sql.Value, entities.len);
            defer allocator.free(parent_id_values);
            for (entities, 0..) |e, i| {
                parent_id_values[i] = idValue(e.id);
            }

            var b = sql.Builder.init(allocator, driver.dialect());
            defer b.deinit();
            graph_neighbors.appendSetNeighbors(&b, step, parent_id_values) catch |err| {
                return if (err == error.OutOfMemory) error.OutOfMemory else error.BuildFailed;
            };
            const qr = b.query();

            var rows = try driver.queryCtx(&execution_context, qr.sql, qr.args);
            defer rows.deinit();

            var map = MapT.init(allocator);
            defer {
                var it = map.iterator();
                while (it.next()) |entry| {
                    if (comptime IdType != i64) allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                map.deinit();
            }

            while (rows.next()) |row| {
                // Eager-loaded targets get the same arena-based JSON ownership
                // contract as full entities (deinitEntityEdges releases it).
                const target = if (comptime @hasField(TargetEntity, "json_arena")) blk: {
                    const arena = try allocator.create(std.heap.ArenaAllocator);
                    arena.* = std.heap.ArenaAllocator.init(allocator);
                    errdefer {
                        arena.deinit();
                        allocator.destroy(arena);
                    }
                    break :blk try sql_scan.scanRowWithArena(TargetEntity, allocator, row, arena);
                } else try sql_scan.scanRow(TargetEntity, allocator, row);
                const fk_idx = sql_scan.findColumnIndex(row, "__fk") orelse return error.MissingColumn;
                const parent_id: IdType = if (comptime IdType == i64)
                    row.getInt(fk_idx) orelse return error.TypeMismatch
                else blk: {
                    const text = row.getText(fk_idx) orelse return error.TypeMismatch;
                    break :blk try allocator.dupe(u8, text);
                };

                var gop = try map.getOrPut(parent_id);
                if (gop.found_existing) {
                    if (comptime IdType != i64) allocator.free(parent_id);
                } else {
                    gop.value_ptr.* = std.ArrayListUnmanaged(TargetEntity).empty;
                }
                try gop.value_ptr.append(allocator, target);
            }
            if (rows.nextError()) |e| return e;

            for (entities) |*e| {
                if (map.get(e.id)) |list| {
                    const slice = try allocator.dupe(TargetEntity, list.items);
                    @field(e.edges, edge.name) = slice;
                }
            }

            // Recurse one level into the loaded targets. The terminal
            // eager-load target (PlainFields) carries no edges container;
            // the comptime guard stops its instantiation from being
            // analyzed (a third nesting level stays a compile error).
            if (comptime @hasField(TargetEntity, "edges")) {
                if (split.rest.len > 0) {
                    for (entities) |*e| {
                        const arr = @field(e.edges, edge.name);
                        if (arr) |items| {
                            try loadEdgePath(infos, target_info, TargetEntity, allocator, driver, execution_context, @constCast(items), split.rest);
                        }
                    }
                }
            }
            return;
        }
    }
    return error.InvalidEdge;
}

/// Generate a Query builder for an entity.
pub fn QueryBuilder(comptime infos: []const TypeInfo, comptime info: TypeInfo, comptime Entity: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        driver: sql_driver.Driver,
        predicates: std.array_list.Managed(sql.Predicate),
        /// EntQL predicate trees owned by this builder (added via WhereEntQL).
        /// The element values are shallow copies of the ones in `predicates`;
        /// deinit releases their internal allocations here, then the array.
        entql_owned: std.array_list.Managed(sql.Predicate),
        order_terms: std.array_list.Managed(sql.Order),
        limit_val: ?usize,
        offset_val: ?usize,
        cursor_col: ?[]const u8 = null,
        cursor_val: ?sql.Value = null,
        cursor_id: ?i64 = null,
        cursor_desc: bool = false,
        distinct: bool,
        with_trashed: bool,
        with_edges: std.ArrayListUnmanaged([]const u8),
        group_cols: std.ArrayListUnmanaged([]const u8),
        or_in_chunks: std.ArrayListUnmanaged([]const []const sql.Value),
        having_pred: ?sql.Predicate,
        /// Optional column projection (Select); rows are scanned by column
        /// name and unselected fields keep zero values (read-only entities).
        select_cols: ?[]const []const u8 = null,
        for_update: bool,
        for_share: bool,
        privacy_ctx: ?privacy.PrivacyContext = null,
        logger: Logger = .{},
        timeout_ms: ?u32 = null,
        execution_context: sql_driver.ExecutionContext = .{},

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver, privacy_ctx: ?privacy.PrivacyContext) Self {
            return .{
                .allocator = allocator,
                .driver = driver,
                .predicates = std.array_list.Managed(sql.Predicate).init(allocator),
                .entql_owned = std.array_list.Managed(sql.Predicate).init(allocator),
                .order_terms = std.array_list.Managed(sql.Order).init(allocator),
                .limit_val = null,
                .offset_val = null,
                .distinct = false,
                .with_trashed = false,
                .with_edges = .empty,
                .group_cols = .empty,
                .or_in_chunks = .empty,
                .having_pred = null,
                .for_update = false,
                .for_share = false,
                .privacy_ctx = privacy_ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.or_in_chunks.items) |chunks| self.allocator.free(chunks);
            self.or_in_chunks.deinit(self.allocator);
            // Release internal allocations of EntQL trees (predicates array
            // itself only holds shallow copies).
            const entql = @import("../entql/parser.zig");
            for (self.entql_owned.items) |*p| entql.deinitPred(self.allocator, p);
            self.entql_owned.deinit();
            self.predicates.deinit();
            self.order_terms.deinit();
            self.with_edges.deinit(self.allocator);
            self.group_cols.deinit(self.allocator);
        }

        /// Set a per-query timeout in milliseconds. The deadline is computed
        /// immediately before the query is executed and passed to the driver.
        pub fn withTimeout(self: *Self, ms: u32) *Self {
            self.timeout_ms = ms;
            return self;
        }

        fn ensureDeadline(self: *Self) void {
            if (self.timeout_ms) |ms| {
                self.execution_context.deadline_ns = sql_driver.monotonicNs() + @as(i64, ms) * std.time.ns_per_ms;
            }
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

        /// Parse an EntQL expression string and add it as a WHERE predicate.
        /// `has(edge)` / `not_has(edge)` / `has(edge, expr)` are lowered to
        /// schema-aware EXISTS subqueries (see predicate.lowerHasEdge).
        /// The predicate tree is owned by the builder and freed on deinit.
        pub fn WhereEntQL(self: *Self, input: []const u8) !*Self {
            const entql = @import("../entql/parser.zig");
            const lowerHasEdge = @import("predicate.zig").lowerHasEdge;
            var parsed = try entql.parse(self.allocator, input);
            errdefer entql.deinitPred(self.allocator, &parsed);
            try lowerHasEdge(infos, info, self.allocator, &parsed);
            try self.predicates.append(parsed);
            try self.entql_owned.append(parsed);
            return self;
        }

        /// Add `column IN (…)` with automatic chunking (drivers cap parameter
        /// counts), OR-joined across chunks.
        pub fn WhereIn(self: *Self, column: []const u8, values: []const sql.Value) !*Self {
            if (values.len == 0) return error.EmptyInValues;
            const chunk_size: usize = 500;
            const count = (values.len + chunk_size - 1) / chunk_size;
            // Chunks outlive WhereIn: owned by the query builder (freed in
            // deinit), so the value-semantics or_in predicate is safe.
            const chunks = try self.allocator.alloc([]const sql.Value, count);
            errdefer self.allocator.free(chunks);
            var start: usize = 0;
            var i: usize = 0;
            while (start < values.len) : (start += chunk_size) {
                const end = @min(start + chunk_size, values.len);
                chunks[i] = values[start..end];
                i += 1;
            }
            try self.or_in_chunks.append(self.allocator, chunks);
            try self.predicates.append(sql.OrIn(column, chunks));
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
        /// and uses `limit_val` as the page size. Offset is cleared to enforce
        /// mutual exclusion with offset pagination.
        pub fn Cursor(self: *Self, column: []const u8, value: sql.Value) *Self {
            self.cursor_col = column;
            self.cursor_val = value;
            self.cursor_id = null;
            self.cursor_desc = false;
            self.offset_val = null;
            return self;
        }

        /// Composite keyset pagination on `(column, id)`: the generated
        /// query appends `WHERE (col > ?) OR (col = ? AND id > ?)
        /// ORDER BY col ASC, id ASC` (desc variants with `<`). Ties on the
        /// cursor column no longer drop rows between pages.
        pub fn CursorKeyset(self: *Self, column: []const u8, value: sql.Value, id_value: i64, desc: bool) *Self {
            self.cursor_col = column;
            self.cursor_val = value;
            self.cursor_id = id_value;
            self.cursor_desc = desc;
            self.offset_val = null;
            return self;
        }

        /// Set a descending cursor column and value for reverse keyset pagination.
        /// Uses `WHERE (col < ?) ORDER BY col DESC` instead of the ascending variant.
        pub fn CursorDesc(self: *Self, column: []const u8, value: sql.Value) *Self {
            self.cursor_col = column;
            self.cursor_val = value;
            self.cursor_id = null;
            self.cursor_desc = true;
            self.offset_val = null;
            return self;
        }

        /// Set a cursor to page after a given entity, using its `id` field.
        pub fn CursorAfter(self: *Self, entity: Entity) *Self {
            self.cursor_col = "id";
            self.cursor_val = idValue(entity.id);
            self.cursor_id = null;
            self.cursor_desc = false;
            self.offset_val = null;
            return self;
        }

        pub fn Distinct(self: *Self) *Self {
            self.distinct = true;
            return self;
        }

        /// Restrict the query to a column subset (skips large text/blob
        /// fields). Projected entities have zero values for unselected
        /// fields — treat them as read-only (do not deinit string fields).
        pub fn Select(self: *Self, comptime cols: []const []const u8) *Self {
            comptime {
                for (cols) |c| {
                    var found = false;
                    for (info.fields) |f| {
                        if (std.mem.eql(u8, f.name, c)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) @compileError("Unknown column in Select: " ++ c);
                }
            }
            self.select_cols = cols;
            return self;
        }

        pub fn WithTrashed(self: *Self) *Self {
            self.with_trashed = true;
            return self;
        }

        /// Eager-load one or two levels of edges. Dot paths preload nested
        /// relations, e.g. `WithEdge("posts.comments")` loads each row's
        /// posts and each post's comments (two levels max).
        pub fn WithEdge(self: *Self, comptime edge_path: []const u8) !*Self {
            const head = comptime blk: {
                if (std.mem.indexOfScalar(u8, edge_path, '.')) |dot| break :blk edge_path[0..dot];
                break :blk edge_path;
            };
            _ = comptime findEdgeInfo(info, head);
            try self.with_edges.append(self.allocator, edge_path);
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

        const QueryError = sql_driver.Error || error{ PrivacyDenied, NotFound, NotSingular, TypeMismatch, MissingColumn, InvalidEdge, InvalidCursor, BuildFailed, UuidEdgesUnsupported };
        const BuildError = error{ OutOfMemory, BuildFailed };
        const ExplainError = error{ OutOfMemory, BuildFailed, InvalidCursor, UnsupportedDialect };

        /// Return the dialect-prefixed EXPLAIN SQL for the current query.
        /// The caller owns the returned `ExplainResult` and must call `deinit`.
        pub fn Explain(self: *Self, allocator: std.mem.Allocator, format: explain.Format) ExplainError!explain.ExplainResult {
            var q = try self.buildQuery(info.fields.len);
            defer q.deinit();
            return explain.explainSql(allocator, self.driver.dialect(), q.sql, format);
        }

        /// Streaming row iterator. Wraps driver.Rows and advances one entity
        /// at a time. Each call to `next()` frees the previous entity, so only
        /// one entity is held in memory at a time — safe for large result sets.
        pub const QueryIterator = struct {
            rows: sql_driver.Rows,
            allocator: std.mem.Allocator,
            select_cols: ?[]const []const u8 = null,
            current: ?Entity = null,

            const IterSelf = @This();

            /// Advance to the next row. Frees the previous entity automatically.
            /// Returns null when exhausted. After null, call deinit() to release
            /// driver resources.
            pub fn next(self: *IterSelf) QueryError!?Entity {
                if (self.current) |*e| {
                    deinitEntity(infos, info, e, self.allocator);
                }
                self.current = null;

                const row = self.rows.next() orelse {
                    if (self.rows.nextError()) |e| return e;
                    return null;
                };
                const entity = if (self.select_cols != null)
                    try scanEntityNamed(Entity, self.allocator, row)
                else
                    try scanEntity(Entity, self.allocator, row);
                self.current = entity;
                return entity;
            }

            /// Release all resources. Safe to call even if partially consumed.
            /// Frees the current entity (if any), drains remaining rows, and
            /// calls rows.deinit().
            pub fn deinit(self: *IterSelf) void {
                if (self.current) |*e| {
                    deinitEntity(infos, info, e, self.allocator);
                    self.current = null;
                }
                while (self.rows.next()) |_| {}
                self.rows.deinit();
            }
        };

        fn mapBuildError(err: anyerror) BuildError {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.BuildFailed,
            };
        }

        fn checkPolicy(self: *const Self) error{PrivacyDenied}!privacy.DecisionSet {
            if (info.policy) |p| {
                var ctx = self.privacy_ctx orelse return error.PrivacyDenied;
                ctx.op = .query;
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

        /// Fetch every matching row. Returns `std.array_list.Managed(Entity)`:
        /// iterate via `result.items` (a slice) and free each entity with
        /// `deinitEntity(infos, info, &item, allocator)` before `result.deinit()`.
        /// Contrast with `paged()`, which returns a `PagedResult` whose rows
        /// live at `result.items.items` and whose `deinit()` frees the entities.
        pub fn All(self: *Self) QueryError!std.array_list.Managed(Entity) {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            var q = try self.buildQuery(info.fields.len);
            defer q.deinit();
            self.ensureDeadline();
            const start = nowUs();
            var rows = try self.driver.queryCtx(&self.execution_context, q.sql, q.args);
            defer rows.deinit();

            var result = std.array_list.Managed(Entity).init(self.allocator);
            errdefer {
                for (result.items) |*e| deinitEntity(infos, info, e, self.allocator);
                result.deinit();
            }

            while (rows.next()) |row| {
                var entity = if (self.select_cols != null)
                    try scanEntityNamed(Entity, self.allocator, row)
                else
                    try scanEntity(Entity, self.allocator, row);
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

        /// Execute the query and return a streaming iterator that yields entities
        /// one row at a time. Unlike All(), this does not load the full result set
        /// into memory — safe for large tables.
        ///
        /// The returned QueryIterator MUST be deinited. Does NOT support
        /// eager edge loading (WithEdge); use All() for that.
        pub fn Iterate(self: *Self) QueryError!QueryIterator {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            var q = try self.buildQuery(info.fields.len);
            defer q.deinit();
            self.ensureDeadline();
            const start = nowUs();
            const rows = try self.driver.queryCtx(&self.execution_context, q.sql, q.args);

            const duration_us: u64 = nowUs() - start;
            if (self.logger.onQuery) |log| {
                log(.{
                    .sql = q.sql,
                    .args = q.args,
                    .duration_us = duration_us,
                    .rows_affected = 0,
                    .table_name = info.table_name,
                });
            }

            return QueryIterator{
                .rows = rows,
                .allocator = self.allocator,
                .select_cols = self.select_cols,
            };
        }

        pub fn First(self: *Self) QueryError!?Entity {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            self.limit_val = 1;
            var q = try self.buildQuery(info.fields.len);
            defer q.deinit();
            self.ensureDeadline();
            const start = nowUs();
            var rows = try self.driver.queryCtx(&self.execution_context, q.sql, q.args);
            defer rows.deinit();

            const row = rows.next() orelse {
                if (rows.nextError()) |e| return e;
                return null;
            };
            var entity = if (self.select_cols != null)
                try scanEntityNamed(Entity, self.allocator, row)
            else
                try scanEntity(Entity, self.allocator, row);
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
            self.ensureDeadline();
            const start = nowUs();
            var rows = try self.driver.queryCtx(&self.execution_context, q.sql, q.args);
            defer rows.deinit();

            const row = rows.next() orelse {
                if (rows.nextError()) |e| return e;
                return error.NotFound;
            };
            var entity = if (self.select_cols != null)
                try scanEntityNamed(Entity, self.allocator, row)
            else
                try scanEntity(Entity, self.allocator, row);
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
            self.ensureDeadline();
            var rows = try self.driver.queryCtx(&self.execution_context, q.sql, q.args);
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
            self.ensureDeadline();
            var rows = try self.driver.queryCtx(&self.execution_context, q.sql, q.args);
            defer rows.deinit();

            const row = rows.next() orelse {
                if (rows.nextError()) |e| return e;
                return error.NotFound;
            };
            return row.getInt(0) orelse return error.TypeMismatch;
        }

        /// Owned paged result: one `count` query + one `limit/offset` fetch.
        /// Callers release entities with `deinit`.
        pub const PagedResult = struct {
            items: std.array_list.Managed(Entity),
            total: i64,

            pub fn deinit(self: *PagedResult) void {
                const allocator = self.items.allocator;
                for (self.items.items) |*e| deinitEntity(infos, info, e, allocator);
                self.items.deinit();
                self.* = undefined;
            }
        };

        /// One-call pagination: total via Count, page slice via All with
        /// limit/offset. Reuses the same predicates/order — no duplicate
        /// count+fetch loops or per-module free helpers.
        /// Returns a `PagedResult`: rows live at `result.items.items` (the
        /// inner `std.array_list.Managed(Entity)`), `result.total` is the
        /// count, and `result.deinit()` frees both entities and the list —
        /// do NOT call `deinitEntity` per row yourself. Contrast with `All()`,
        /// which returns the plain `std.array_list.Managed(Entity)`.
        pub fn paged(self: *Self, page: usize, page_size: usize) (QueryError || error{InvalidPageSize})!PagedResult {
            if (page_size == 0) return error.InvalidPageSize;
            const total = try self.Count();
            if (total == 0) {
                return .{ .items = std.array_list.Managed(Entity).init(self.allocator), .total = 0 };
            }
            self.limit_val = page_size;
            self.offset_val = (page -| 1) * page_size;
            const items = try self.All();
            return .{ .items = items, .total = total };
        }

        /// One GROUP BY query: `SELECT <col>, COUNT(*) FROM … WHERE … GROUP BY <col>`.
        /// Replaces N separate Count() calls with a single round trip.
        pub const GroupCount = struct { key: i64, count: i64 };

        pub fn CountBy(self: *Self, comptime field_name: []const u8) QueryError!std.array_list.Managed(GroupCount) {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            var q = try self.buildGroupedCountQuery(field_name);
            defer q.deinit();
            self.ensureDeadline();
            var rows = try self.driver.queryCtx(&self.execution_context, q.sql, q.args);
            defer rows.deinit();

            var result = std.array_list.Managed(GroupCount).init(self.allocator);
            errdefer result.deinit();
            while (rows.next()) |row| {
                try result.append(.{
                    .key = row.getInt(0) orelse return error.TypeMismatch,
                    .count = row.getInt(1) orelse return error.TypeMismatch,
                });
            }
            if (rows.nextError()) |e| return e;
            return result;
        }

        fn buildGroupedCountQuery(self: *Self, comptime field_name: []const u8) !sql.OwnedQuery {
            const t = sql.Table(info.table_name);
            const key_col = sql.ColumnRef{ .table = null, .name = field_name, .raw = false };
            const cnt_col = sql.ColumnRef{ .table = null, .name = "COUNT(*)", .raw = true };
            var selector = try sql.Select(self.allocator, self.driver.dialect(), &.{ key_col, cnt_col });
            _ = selector.from(t);
            if (self.predicates.items.len > 0) {
                for (self.predicates.items) |pred| {
                    _ = try selector.where(pred);
                }
            }
            if (info.soft_delete and !self.with_trashed) {
                _ = try selector.where(sql.IsNull("deleted_at"));
            }
            _ = try selector.groupBy(&.{field_name});
            if (self.having_pred) |pred| {
                _ = selector.having(pred);
            }
            return selector.takeQuery() catch |err| return mapBuildError(err);
        }

        pub fn Exist(self: *Self) QueryError!bool {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            self.limit_val = 1;
            var q = try self.buildQuery(1);
            defer q.deinit();
            self.ensureDeadline();
            var rows = try self.driver.queryCtx(&self.execution_context, q.sql, q.args);
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
            self.ensureDeadline();
            var rows = try self.driver.queryCtx(&self.execution_context, q.sql, q.args);
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
            self.ensureDeadline();
            var rows = try self.driver.queryCtx(&self.execution_context, q.sql, q.args);
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
            self.ensureDeadline();
            var rows = try self.driver.queryCtx(&self.execution_context, q.sql, q.args);
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
            self.ensureDeadline();
            var rows = try self.driver.queryCtx(&self.execution_context, q.sql, q.args);
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

        fn loadEdges(self: *Self, edge_path: []const u8, entities: []Entity) !void {
            return loadEdgePath(infos, info, Entity, self.allocator, self.driver, self.execution_context, entities, edge_path);
        }

        fn buildQuery(self: *Self, comptime column_count: usize) !sql.OwnedQuery {
            const t = sql.Table(info.table_name);
            var all_cols: [column_count][]const u8 = undefined;
            inline for (info.fields[0..column_count], 0..) |f, i| all_cols[i] = f.name;
            const cols: []const []const u8 = self.select_cols orelse all_cols[0..column_count];
            var columns: [info.fields.len]sql.ColumnRef = undefined;
            for (cols, 0..) |cname, i| columns[i] = t.c(cname);
            var selector = try sql.Select(self.allocator, self.driver.dialect(), columns[0..cols.len]);
            _ = selector.from(t);
            _ = selector.setDistinct(self.distinct);

            if (self.predicates.items.len > 0) {
                for (self.predicates.items) |pred| {
                    _ = try selector.where(pred);
                }
            }
            if (self.cursor_col) |col| {
                if (self.cursor_val) |val| {
                    if (val == .null) return error.InvalidCursor;
                    // Validate cursor column against entity fields
                    var col_valid = false;
                    inline for (info.fields) |f| {
                        if (std.mem.eql(u8, f.name, col)) {
                            col_valid = true;
                            break;
                        }
                    }
                    if (!col_valid) return error.InvalidCursor;
                    if (self.cursor_id) |id_val| {
                        // Composite keyset: (col > ?) OR (col = ? AND id > ?)
                        // — ties on the cursor column never drop rows.
                        const col_cmp = if (self.cursor_desc) sql.LT(col, val) else sql.GT(col, val);
                        const col_eq = sql.EQ(col, val);
                        const id_cmp = if (self.cursor_desc)
                            sql.LT("id", .{ .int = id_val })
                        else
                            sql.GT("id", .{ .int = id_val });
                        _ = try selector.where(sql.Or(&col_cmp, &sql.And(&col_eq, &id_cmp)));
                    } else {
                        // Single-column cursor (backward compatible).
                        if (self.cursor_desc) {
                            _ = try selector.where(sql.LT(col, val));
                        } else {
                            _ = try selector.where(sql.GT(col, val));
                        }
                    }
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
                // When cursor pagination is active, ensure ORDER BY col ASC/DESC is present.
                if (self.order_terms.items.len == 0) {
                    if (self.cursor_desc) {
                        _ = try selector.orderBy(sql.OrderDesc(col));
                    } else {
                        _ = try selector.orderBy(sql.OrderAsc(col));
                    }
                }
                // Auto-add id tie-breaker for stable keyset pagination
                if (!std.mem.eql(u8, col, "id")) {
                    var has_id: bool = false;
                    for (self.order_terms.items) |term| {
                        switch (term) {
                            .column => |o| {
                                if (std.mem.eql(u8, o.name, "id")) {
                                    has_id = true;
                                    break;
                                }
                            },
                            else => {},
                        }
                    }
                    if (!has_id) {
                        if (self.cursor_desc) {
                            _ = try selector.orderBy(sql.OrderDesc("id"));
                        } else {
                            _ = try selector.orderBy(sql.OrderAsc("id"));
                        }
                    }
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

test "WithEdge nested two-level preload" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const edge = @import("../core/edge.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const buildGraph = @import("graph.zig").buildGraph;
    const migrate = @import("../sql/schema/migrate.zig");
    const sqlite_driver = @import("../sql/sqlite.zig");
    const client_mod = @import("client.zig");

    const Comment = schema("Comment", .{
        .fields = &.{
            field.Int("post_id"),
            field.String("body"),
        },
    });
    const Post = schema("Post", .{
        .fields = &.{
            field.Int("user_id"),
            field.String("title"),
        },
        .edges = &.{edge.To("comments", Comment)},
    });
    const User = schema("User", .{
        .fields = &.{field.String("name")},
        .edges = &.{edge.To("posts", Post)},
    });

    const graph = comptime buildGraph(&.{ User, Post, Comment });
    const infos = graph.types;
    const user_info = comptime fromSchema(User);
    const post_info = comptime fromSchema(Post);
    const comment_info = comptime fromSchema(Comment);

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);

    const root = client_mod.makeClient(infos, allocator, driver.asDriver());

    // Seed: user 1 with two posts; post 1 has two comments, post 2 has one.
    const alice_id = id: {
        var b = try root.user.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "alice");
        var row = try b.Save();
        defer deinitEntity(infos, user_info, &row, allocator);
        break :id row.id;
    };
    const p1 = id: {
        var b = try root.post.Create();
        defer b.deinit();
        _ = try b.setFieldValue("user_id", alice_id);
        _ = try b.setFieldValue("title", "hello");
        var row = try b.Save();
        defer deinitEntity(infos, post_info, &row, allocator);
        break :id row.id;
    };
    const p2 = id: {
        var b = try root.post.Create();
        defer b.deinit();
        _ = try b.setFieldValue("user_id", alice_id);
        _ = try b.setFieldValue("title", "world");
        var row = try b.Save();
        defer deinitEntity(infos, post_info, &row, allocator);
        break :id row.id;
    };
    {
        var b = try root.comment.Create();
        defer b.deinit();
        _ = try b.setFieldValue("post_id", p1);
        _ = try b.setFieldValue("body", "first");
        var row = try b.Save();
        defer deinitEntity(infos, comment_info, &row, allocator);
    }
    {
        var b = try root.comment.Create();
        defer b.deinit();
        _ = try b.setFieldValue("post_id", p1);
        _ = try b.setFieldValue("body", "second");
        var row = try b.Save();
        defer deinitEntity(infos, comment_info, &row, allocator);
    }
    {
        var b = try root.comment.Create();
        defer b.deinit();
        _ = try b.setFieldValue("post_id", p2);
        _ = try b.setFieldValue("body", "only");
        var row = try b.Save();
        defer deinitEntity(infos, comment_info, &row, allocator);
    }
    // Two-level eager load: user.posts[].comments[] populated in 3 queries.
    var q = root.user.Query();
    defer q.deinit();
    _ = try q.WithEdge("posts.comments");
    const users = try q.All();
    defer {
        for (users.items) |*e| deinitEntity(infos, user_info, e, allocator);
        users.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), users.items.len);
    const posts = users.items[0].edges.posts.?;
    try std.testing.expectEqual(@as(usize, 2), posts.len);
    // Post 1 -> two comments; post 2 -> one comment.
    const c1 = posts[0].edges.comments.?;
    const c2 = posts[1].edges.comments.?;
    try std.testing.expectEqual(@as(usize, 2), c1.len);
    try std.testing.expectEqual(@as(usize, 1), c2.len);
    try std.testing.expectEqualStrings("second", c1[1].body);
    try std.testing.expectEqualStrings("only", c2[0].body);
    try std.testing.expectEqual(@as(i64, p1), posts[0].id);
    try std.testing.expectEqual(@as(i64, p2), posts[1].id);
}

test "WithEdge honors edge order_by + limit" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const edge = @import("../core/edge.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const buildGraph = @import("graph.zig").buildGraph;
    const migrate = @import("../sql/schema/migrate.zig");
    const sqlite_driver = @import("../sql/sqlite.zig");
    const client_mod = @import("client.zig");

    const Comment = schema("FeedComment", .{
        .fields = &.{
            field.Int("post_id"),
            field.String("body"),
        },
    });
    const Post = schema("FeedPost", .{
        .fields = &.{
            field.Int("author_id"),
            field.String("title"),
        },
        .edges = &.{edge.To("comments", Comment).OrderBy("id").Desc().Limit(1).Field("post_id")},
    });

    const graph = comptime buildGraph(&.{ Post, Comment });
    const infos = graph.types;
    const post_info = comptime fromSchema(Post);
    const comment_info = comptime fromSchema(Comment);

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);
    const root = client_mod.makeClient(infos, allocator, driver.asDriver());

    const pid = id: {
        var b = try root.feed_post.Create();
        defer b.deinit();
        _ = try b.setFieldValue("author_id", @as(i64, 1));
        _ = try b.setFieldValue("title", "t");
        var row = try b.Save();
        defer deinitEntity(infos, post_info, &row, allocator);
        break :id row.id;
    };
    inline for (.{ "c1", "c2", "c3" }) |body| {
        var b = try root.feed_comment.Create();
        defer b.deinit();
        _ = try b.setFieldValue("post_id", pid);
        _ = try b.setFieldValue("body", body);
        var row = try b.Save();
        defer deinitEntity(infos, comment_info, &row, allocator);
    }

    var q = root.feed_post.Query();
    defer q.deinit();
    _ = try q.WithEdge("comments");
    const posts = try q.All();
    defer {
        for (posts.items) |*p| deinitEntity(infos, post_info, p, allocator);
        posts.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), posts.items.len);
    const comments = posts.items[0].edges.comments.?;
    // Limit(1) + Desc: only the newest comment per post.
    try std.testing.expectEqual(@as(usize, 1), comments.len);
    try std.testing.expectEqualStrings("c3", comments[0].body);
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
    const QueryError = sql_driver.Error || error{ PrivacyDenied, NotFound, NotSingular, TypeMismatch, MissingColumn, InvalidEdge, InvalidCursor, BuildFailed, UuidEdgesUnsupported };

    comptime {
        const method_names = .{ "All", "Iterate", "First", "Only", "IDs", "Count", "Exist", "Sum", "Avg", "Max", "Min" };
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

test "query contract tests" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGenerator = @import("entity.zig").Entity;

    const User = schema("User", .{ .fields = &.{ field.String("name"), field.Int("age") } });
    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGenerator(infos, info);
    const QB = QueryBuilder(infos, info, UserEntity);
    const QE = sql_driver.Error || error{ PrivacyDenied, NotFound, NotSingular, TypeMismatch, MissingColumn, InvalidEdge, BuildFailed, InvalidCursor, UuidEdgesUnsupported };

    comptime {
        // Verify all public query method error sets are explicit
        if (@typeInfo(@typeInfo(@TypeOf(QB.All)).@"fn".return_type.?).error_union.error_set != QE) @compileError("Query.All error set");
        if (@typeInfo(@typeInfo(@TypeOf(QB.Iterate)).@"fn".return_type.?).error_union.error_set != QE) @compileError("Query.Iterate error set");
        if (@typeInfo(@typeInfo(@TypeOf(QB.First)).@"fn".return_type.?).error_union.error_set != QE) @compileError("Query.First error set");
        if (@typeInfo(@typeInfo(@TypeOf(QB.Only)).@"fn".return_type.?).error_union.error_set != QE) @compileError("Query.Only error set");
        if (@typeInfo(@typeInfo(@TypeOf(QB.IDs)).@"fn".return_type.?).error_union.error_set != QE) @compileError("Query.IDs error set");
        if (@typeInfo(@typeInfo(@TypeOf(QB.Count)).@"fn".return_type.?).error_union.error_set != QE) @compileError("Query.Count error set");
        if (@typeInfo(@typeInfo(@TypeOf(QB.Exist)).@"fn".return_type.?).error_union.error_set != QE) @compileError("Query.Exist error set");
    }
}

test "Query builder Explain prefixes SQL" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGenerator = @import("entity.zig").Entity;

    const MockDriver = struct {
        pub fn asDriver(self: *@This()) sql_driver.Driver {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn mockExec(_: *anyopaque, _: ?*const sql_driver.ExecutionContext, _: []const u8, _: []const sql.Value) sql_driver.Error!sql_driver.Result {
            unreachable;
        }
        fn mockQuery(_: *anyopaque, _: ?*const sql_driver.ExecutionContext, _: []const u8, _: []const sql.Value) sql_driver.Error!sql_driver.Rows {
            unreachable;
        }
        fn mockBeginTx(_: *anyopaque) sql_driver.Error!sql_driver.Tx {
            unreachable;
        }
        fn mockClose(_: *anyopaque) void {
            unreachable;
        }
        fn mockDialect(_: *anyopaque) Dialect {
            return .sqlite;
        }
        fn mockPing(_: *anyopaque) sql_driver.Error!void {
            unreachable;
        }
        fn mockInTransaction(_: *anyopaque) bool {
            unreachable;
        }
        fn mockBeginSavepoint(_: *anyopaque, _: []const u8) sql_driver.Error!sql_driver.Tx {
            unreachable;
        }

        const vtable = sql_driver.Driver.VTable{
            .exec = mockExec,
            .query = mockQuery,
            .beginTx = mockBeginTx,
            .close = mockClose,
            .dialect = mockDialect,
            .ping = mockPing,
            .inTransaction = mockInTransaction,
            .beginSavepoint = mockBeginSavepoint,
        };
    };

    var mock = MockDriver{};

    const User = schema("User", .{ .fields = &.{ field.String("name"), field.Int("age") } });
    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGenerator(infos, info);
    const UserQuery = QueryBuilder(infos, info, UserEntity);

    var q = UserQuery.init(std.testing.allocator, mock.asDriver(), null);
    defer q.deinit();

    var plan = try q.Explain(std.testing.allocator, .text);
    defer plan.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("EXPLAIN QUERY PLAN SELECT \"user\".\"id\", \"user\".\"name\", \"user\".\"age\" FROM \"user\"", plan.sql);
}

test "CursorKeyset composite pagination does not drop rows on ties" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const buildGraph = @import("graph.zig").buildGraph;
    const migrate = @import("../sql/schema/migrate.zig");
    const sqlite_driver = @import("../sql/sqlite.zig");
    const client_mod = @import("client.zig");

    const FeedItem = schema("FeedItem", .{
        .fields = &.{
            field.Time("created_at"),
            field.String("body"),
        },
    });
    const graph = comptime buildGraph(&.{FeedItem});
    const infos = graph.types;
    const info = comptime fromSchema(FeedItem);

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);
    const root = client_mod.makeClient(infos, allocator, driver.asDriver());

    // Seed 6 rows with duplicate timestamps (ties the naive cursor drops).
    const times = [_]i64{ 100, 100, 100, 200, 200, 300 };
    for (times) |t| {
        var b = try root.feed_item.Create();
        defer b.deinit();
        _ = try b.setFieldValue("created_at", t);
        _ = try b.setFieldValue("body", "x");
        var row = try b.Save();
        defer deinitEntity(infos, info, &row, allocator);
    }

    var seen = std.AutoHashMap(i64, void).init(allocator);
    defer seen.deinit();
    var collected: usize = 0;
    var cursor_col: []const u8 = "created_at";
    var cursor_val: i64 = 0;
    var cursor_id: i64 = 0;

    while (true) {
        var q = root.feed_item.Query();
        defer q.deinit();
        _ = q.CursorKeyset(cursor_col, .{ .int = cursor_val }, cursor_id, false);
        _ = q.Limit(2);
        const rows = try q.All();
        defer {
            for (rows.items) |*e| deinitEntity(infos, info, e, allocator);
            rows.deinit();
        }
        if (rows.items.len == 0) break;
        for (rows.items) |*e| {
            try std.testing.expect(!seen.contains(e.id));
            try seen.put(e.id, {});
            collected += 1;
            cursor_col = "created_at";
            cursor_val = e.created_at;
            cursor_id = e.id;
        }
    }
    try std.testing.expectEqual(@as(usize, 6), collected);
}

test "WithEdge applies edge filter (only visible comments)" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const edge = @import("../core/edge.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const buildGraph = @import("graph.zig").buildGraph;
    const migrate = @import("../sql/schema/migrate.zig");
    const sqlite_driver = @import("../sql/sqlite.zig");
    const client_mod = @import("client.zig");

    const FComment = schema("FComment", .{
        .fields = &.{
            field.Int("post_id"),
            field.String("body"),
            field.String("status"),
        },
    });
    const FPost = schema("FPost", .{
        .fields = &.{field.String("title")},
        .edges = &.{edge.To("comments", FComment)
            .Field("post_id")
            .WhereRaw("\"status\" = ?", &.{.{ .string = "visible" }})},
    });
    const graph = comptime buildGraph(&.{ FPost, FComment });
    const infos = graph.types;
    const post_info = comptime fromSchema(FPost);
    const comment_info = comptime fromSchema(FComment);

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);
    const root = client_mod.makeClient(infos, allocator, driver.asDriver());

    const pid = id: {
        var b = try root.f_post.Create();
        defer b.deinit();
        _ = try b.setFieldValue("title", "t");
        var row = try b.Save();
        defer deinitEntity(infos, post_info, &row, allocator);
        break :id row.id;
    };
    inline for (.{ .{ "v1", "visible" }, .{ "v2", "visible" }, .{ "h1", "hidden" } }) |seed| {
        var b = try root.f_comment.Create();
        defer b.deinit();
        _ = try b.setFieldValue("post_id", pid);
        _ = try b.setFieldValue("body", seed[0]);
        _ = try b.setFieldValue("status", seed[1]);
        var row = try b.Save();
        defer deinitEntity(infos, comment_info, &row, allocator);
    }

    var q = root.f_post.Query();
    defer q.deinit();
    _ = try q.WithEdge("comments");
    const posts = try q.All();
    defer {
        for (posts.items) |*p| deinitEntity(infos, post_info, p, allocator);
        posts.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), posts.items.len);
    const comments = posts.items[0].edges.comments.?;
    try std.testing.expectEqual(@as(usize, 2), comments.len);
    for (comments) |c| try std.testing.expectEqualStrings("visible", c.status);
}

test "uuid primary key works with create, query and CursorAfter" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const edge = @import("../core/edge.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const buildGraph = @import("graph.zig").buildGraph;
    const migrate = @import("../sql/schema/migrate.zig");
    const sqlite_driver = @import("../sql/sqlite.zig");
    const client_mod = @import("client.zig");
    const idgen = @import("../core/id.zig");

    const UComment = schema("UComment", .{
        .fields = &.{
            field.String("post_id"),
            field.String("body"),
        },
    });
    const UPost = schema("UPost", .{
        .fields = &.{
            field.UUID("id"),
            field.String("title"),
        },
        .edges = &.{edge.To("comments", UComment).Field("post_id")},
    });
    const graph = comptime buildGraph(&.{ UPost, UComment });
    const infos = graph.types;
    const post_info = comptime fromSchema(UPost);
    const comment_info = comptime fromSchema(UComment);

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);
    const root = client_mod.makeClient(infos, allocator, driver.asDriver());

    var uuid_buf: [36]u8 = undefined;
    const pid_str = idgen.format(idgen.uuidv7(1000), &uuid_buf);
    const pid = id: {
        var b = try root.u_post.Create();
        defer b.deinit();
        _ = try b.setFieldValue("id", pid_str);
        _ = try b.setFieldValue("title", "u");
        var row = try b.Save();
        const id_copy = try allocator.dupe(u8, row.id);
        defer deinitEntity(infos, post_info, &row, allocator);
        break :id id_copy;
    };
    defer allocator.free(pid);
    try std.testing.expectEqualStrings(pid_str, pid);

    inline for (.{ "c1", "c2" }) |body| {
        var b = try root.u_comment.Create();
        defer b.deinit();
        _ = try b.setFieldValue("post_id", pid_str);
        _ = try b.setFieldValue("body", body);
        var row = try b.Save();
        defer deinitEntity(infos, comment_info, &row, allocator);
    }

    // Query by uuid id.
    var q = root.u_post.Query();
    defer q.deinit();
    _ = try q.Where(.{root.u_post.predicates.idEQ(.{ .string = pid_str })});
    var posts = try q.All();
    defer {
        for (posts.items) |*p| deinitEntity(infos, post_info, p, allocator);
        posts.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), posts.items.len);

    // Eager edges on a uuid-keyed parent.
    var qe = root.u_post.Query();
    defer qe.deinit();
    _ = try qe.WithEdge("comments");
    const posts_with_edges = try qe.All();
    defer {
        for (posts_with_edges.items) |*p| deinitEntity(infos, post_info, p, allocator);
        posts_with_edges.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), posts_with_edges.items.len);
    const comments = posts_with_edges.items[0].edges.comments.?;
    try std.testing.expectEqual(@as(usize, 2), comments.len);

    // CursorAfter uses the textual id value.
    var q2 = root.u_post.Query();
    defer q2.deinit();
    _ = q2.CursorAfter(posts.items[0]).Limit(10);
    try std.testing.expectEqualStrings(pid_str, q2.cursor_val.?.string);
}

test "Select projects columns and leaves others zero" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const buildGraph = @import("graph.zig").buildGraph;
    const migrate = @import("../sql/schema/migrate.zig");
    const sqlite_driver = @import("../sql/sqlite.zig");
    const client_mod = @import("client.zig");

    const Doc = schema("DocProj", .{
        .fields = &.{
            field.String("title"),
            field.String("body"),
        },
    });
    const graph = comptime buildGraph(&.{Doc});
    const infos = graph.types;
    const info = comptime fromSchema(Doc);

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);
    const root = client_mod.makeClient(infos, allocator, driver.asDriver());

    {
        var b = try root.doc_proj.Create();
        defer b.deinit();
        _ = try b.setFieldValue("title", "t1");
        _ = try b.setFieldValue("body", "long body text");
        var row = try b.Save();
        defer deinitEntity(infos, info, &row, allocator);
    }

    var q = root.doc_proj.Query();
    defer q.deinit();
    _ = q.Select(&.{ "id", "title" });
    const rows = try q.All();
    defer {
        for (rows.items) |*e| deinitEntity(infos, info, e, allocator);
        rows.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqualStrings("t1", rows.items[0].title);
    // Unselected string field keeps its zero value (empty, read-only).
    try std.testing.expectEqual(@as(usize, 0), rows.items[0].body.len);
}
