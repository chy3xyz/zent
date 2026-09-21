const std = @import("std");
const edgeTargetInfo = @import("graph.zig").edgeTargetInfo;
const TypeInfo = @import("graph.zig").TypeInfo;
const FieldInfo = @import("graph.zig").FieldInfo;
const EdgeInfo = @import("graph.zig").EdgeInfo;
const buildEdgeStep = @import("graph.zig").buildEdgeStep;
const columnName = @import("graph.zig").columnName;
const pkColumn = @import("graph.zig").pkColumn;
const sql = @import("../sql/builder.zig");
const sql_driver = @import("../sql/driver.zig");
const sql_scan = @import("../sql/scan.zig");

/// Scan an entity row, routing JSON struct fields into a per-entity arena
/// that deinitEntity releases — the same ownership contract as the Create
/// path. Bare (non-entity) scans keep the caller-owned behavior.
fn scanEntity(comptime info: TypeInfo, comptime T: type, allocator: std.mem.Allocator, row: sql_driver.Row) !T {
    if (comptime @hasField(T, "json_arena")) {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        return sql_scan.scanRowWithArena(T, allocator, row, arena) catch |err| {
            if (err == error.TypeMismatch) explainScanFailure(info, T, row);
            return err;
        };
    }
    return sql_scan.scanRow(T, allocator, row) catch |err| {
        if (err == error.TypeMismatch) explainScanFailure(info, T, row);
        return err;
    };
}

/// Explain a failed row scan in terms of the schema, because `error.TypeMismatch`
/// on its own names neither the table nor the column it came from.
///
/// Emitted at `warn` level, not `err`: the error itself is already returned to
/// the caller, this is the context that error lacks, and the Zig test runner
/// treats a logged error as a test failure (which would make the diagnostic
/// untestable).
///
/// Runs **only on failure** — the happy path pays nothing — and walks the
/// struct's fields against the row to say which one did not fit. The common
/// cause in a schema-over-legacy-DB setup is a NULL in a column the schema
/// declares non-optional, which is reported as exactly that rather than as a
/// bare type mismatch.
fn explainScanFailure(comptime info: TypeInfo, comptime T: type, row: sql_driver.Row) void {
    const field_names = @typeInfo(T).@"struct".field_names;
    const field_types = @typeInfo(T).@"struct".field_types;
    var col: usize = 0;
    inline for (field_names, field_types) |fname, ftype| {
        if (comptime std.mem.eql(u8, fname, "edges") or std.mem.eql(u8, fname, "json_arena")) continue;
        const idx = col;
        col += 1;
        if (idx >= row.columnCount()) {
            std.log.warn("zent: scanning table '{s}' failed: the result set has {d} column(s) but field '{s}' needs column {d} ({s})", .{ info.table_name, row.columnCount(), fname, idx + 1, @typeName(ftype) });
            return;
        }
        if (@typeInfo(ftype) == .optional) continue;
        if (row.isNull(idx)) {
            std.log.warn("zent: table '{s}' column '{s}' is NULL, but field '{s}' ({s}) is not optional — the database allows NULL where the schema does not; make the field Optional()/Nillable(), or fix the column", .{ info.table_name, row.columnName(idx), fname, @typeName(ftype) });
            return;
        }
    }
    // No NULL explains it (and the field types are optional-tolerant), so a
    // value does not fit its field. Find which one: replay the scan field by
    // field in the same order and report the first that throws. Without this
    // the message named no column at all, which left a misaligned projection —
    // e.g. an eager-loaded target read in table order instead of field order —
    // to be found by bisecting the query shape by hand.
    const Scratch = struct {
        var arena: ?*std.heap.ArenaAllocator = null;
    };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    _ = &Scratch;
    var idx2: usize = 0;
    inline for (field_names, field_types) |fname, ftype| {
        if (comptime std.mem.eql(u8, fname, "edges") or std.mem.eql(u8, fname, "json_arena")) continue;
        const col2 = idx2;
        idx2 += 1;
        _ = sql_scan.scanColumn(ftype, arena.allocator(), row, col2, null) catch {
            const col_name = if (col2 < row.columnCount()) row.columnName(col2) else "<past the end>";
            const value = if (col2 < row.columnCount()) (row.getText(col2) orelse "<null>") else "<none>";
            std.log.warn("zent: scanning table '{s}' failed: column {d} is '{s}' with value '{s}', which field '{s}' ({s}) cannot hold — the projection does not line up with the schema's field order (an eager-loaded target is scanned positionally, so its SELECT list must be the target's columns in field order)", .{ info.table_name, col2 + 1, col_name, value, fname, @typeName(ftype) });
            return;
        };
    }
    std.log.warn("zent: scanning table '{s}' failed: no NULL found among the {d} projected column(s), so a value does not fit its field's type (check the SELECT projection order against the schema)", .{ info.table_name, row.columnCount() });
}

/// Like `scanEntity` for the name-based (partial projection) scanner. The
/// projection emits physical column names, so the row is matched by
/// `column_name` while values are written back to the Zig `name` fields.
fn scanEntityNamed(comptime info: TypeInfo, comptime T: type, allocator: std.mem.Allocator, row: sql_driver.Row) !T {
    const maps = comptime blk: {
        var m: [info.fields.len]sql_scan.ColumnMap = undefined;
        for (info.fields, 0..) |f, i| m[i] = .{ .name = f.name, .column = f.column_name };
        break :blk m;
    };
    if (comptime @hasField(T, "json_arena")) {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        return try sql_scan.scanRowNamedMappedWithArena(T, allocator, row, &maps, arena);
    }
    return sql_scan.scanRowNamedMapped(T, allocator, row, &maps);
}
const Dialect = @import("../sql/dialect.zig").Dialect;
const privacy = @import("../privacy/policy.zig");
const intercept_op = @import("../runtime/hook.zig");
const privacy_op = @import("../runtime/privacy.zig");

/// `PrivacyContext.op` and `QueryView.op` are the same four operations as two
/// distinct enums. Mapped explicitly rather than by ordinal, so adding a
/// member to either one is a compile error instead of a silent
/// reinterpretation.
fn toPrivacyOp(op: intercept_op.Op) privacy_op.Op {
    return switch (op) {
        .create => .create,
        .update => .update,
        .delete => .delete,
        .query => .query,
    };
}
const hook = @import("../runtime/hook.zig");
const intercept = @import("../runtime/intercept.zig");
const Logger = @import("../sql/logger.zig").Logger;
const LogContext = @import("../sql/logger.zig").LogContext;
const nowUs = @import("../sql/logger.zig").nowUs;
const deinitEntity = @import("entity.zig").deinitEntity;
const deinitEntityList = @import("entity.zig").deinitEntityList;
const EntityGen = @import("entity.zig").Entity;
const graph_step = @import("../graph/step.zig");
const graph_neighbors = @import("../graph/neighbors.zig");
const explain = @import("../sql/explain.zig");

fn findEdgeInfo(comptime info: TypeInfo, comptime name: []const u8) EdgeInfo {
    for (info.edges) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    @compileError("Edge not found: " ++ name ++ " on " ++ info.name);
}

/// QueryView sink for an eager-loaded target: validates the field against the
/// target schema and collects `field = value` predicates to AND into the
/// neighbor WHERE. `tinfo` is comptime so the field list can be scanned with
/// `inline for` (FieldInfo carries a `type` and cannot be read at runtime).
///
/// Shared by `QueryBuilder.WithEdge` and `client.queryTargets*` so both
/// neighbour readers accept exactly the same interceptor fields.
pub fn EdgeInterceptorSink(comptime tinfo: TypeInfo) type {
    return struct {
        preds: *std.ArrayListUnmanaged(sql.Predicate),
        allocator: std.mem.Allocator,

        fn addEq(sink: *anyopaque, field_name: []const u8, value: sql.Value) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(sink));
            var found = false;
            inline for (tinfo.fields) |f| {
                if (std.mem.eql(u8, f.name, field_name)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.UnknownField;
            try self.preds.append(self.allocator, sql.EQ(columnName(tinfo, field_name), value));
        }
    };
}

/// Append the read-contract predicates that scope a batch of neighbour rows
/// addressed by parent id: soft-delete scope, then the target's privacy
/// policy, then the interceptor chain (multi-tenant rewriting and friends).
///
/// This is the single implementation of "what may an edge-loaded target
/// show?". `QueryBuilder.WithEdge` and `client.queryTargets*` both call it so
/// the two bulk-neighbour readers cannot drift into different security
/// postures again — the divergence that previously left `queryTargets`
/// fail-open while eager loading was fail-closed.
///
/// `op` is what the privacy policy and the interceptors see, so a raw
/// UPDATE/DELETE can scope itself with the same fragment a SELECT uses
/// (`zent.scope`).
///
/// Errors: `PrivacyDenied` when the target carries a policy but no context
/// was supplied (fail-closed), `InterceptFailed` when the chain rejects.
pub fn appendTargetScopePreds(
    comptime target_info: TypeInfo,
    preds: *std.ArrayListUnmanaged(sql.Predicate),
    allocator: std.mem.Allocator,
    privacy_ctx: ?privacy.PrivacyContext,
    interceptors: ?*intercept.InterceptorChain,
    with_trashed: bool,
    op: intercept_op.Op,
) !void {
    if (target_info.soft_delete and !with_trashed) {
        try preds.append(allocator, sql.IsNull("deleted_at"));
    }

    if (target_info.policy) |policy| {
        var ctx = privacy_ctx orelse return error.PrivacyDenied;
        ctx.op = toPrivacyOp(op);
        const decision_set = policy.eval(ctx);
        if (decision_set.decision == .deny) return error.PrivacyDenied;
        for (decision_set.getFilters()) |opaque_ptr| {
            const pred: *const sql.Predicate = @ptrCast(@alignCast(opaque_ptr));
            try preds.append(allocator, pred.*);
        }
    }

    if (interceptors) |chain| {
        const Sink = EdgeInterceptorSink(target_info);
        var sink = Sink{ .preds = preds, .allocator = allocator };
        var view = intercept.QueryView{
            .op = op,
            .table_name = target_info.table_name,
            .sink = &sink,
            .add_eq_fn = Sink.addEq,
        };
        chain.run(&view) catch return error.InterceptFailed;
    }
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
    /// Parents addressed by pointer: the loaded edge slices are written back
    /// into these elements, so a copy would silently lose them.
    entities: []const *ParentEntity,
    path: []const u8,
    privacy_ctx: ?privacy.PrivacyContext,
    interceptors: ?*intercept.InterceptorChain,
    with_trashed: bool,
) !void {
    if (entities.len == 0 or path.len == 0) return;
    const split = splitEdgePath(path);

    // Support both integer and textual (uuid) primary keys: the neighbor map
    // and __fk read are selected at compile time.
    const IdType = @TypeOf(@field(@as(ParentEntity, undefined), ParentInfo.pk_field));

    inline for (ParentInfo.edges) |edge| {
        if (std.mem.eql(u8, edge.name, split.head)) {
            const target_info = comptime edgeTargetInfo(infos, ParentInfo, edge);
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
                parent_id_values[i] = idValue(@field(e.*, ParentInfo.pk_field));
            }

            var b = sql.Builder.init(allocator, driver.dialect());
            defer b.deinit();

            // Eager-loaded neighbors honor the same read contract as the
            // parent query: soft-delete scope, privacy policy filters, and
            // registered interceptors (e.g. multi-tenant rewriting). They are
            // ANDed into the neighbor WHERE before any per-parent limit, so a
            // trashed or foreign-tenant row cannot consume a limit slot.
            // The contract itself lives in `appendTargetScopePreds` so
            // `client.queryTargets*` applies the identical set.
            var extra_preds = std.ArrayListUnmanaged(sql.Predicate).empty;
            defer extra_preds.deinit(allocator);
            try appendTargetScopePreds(target_info, &extra_preds, allocator, privacy_ctx, interceptors, with_trashed, .query);

            graph_neighbors.appendSetNeighborsFiltered(&b, step, parent_id_values, extra_preds.items) catch |err| {
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
                    break :blk sql_scan.scanRowWithArena(TargetEntity, allocator, row, arena) catch |err| {
                        if (err == error.TypeMismatch) explainScanFailure(target_info, TargetEntity, row);
                        return err;
                    };
                } else sql_scan.scanRow(TargetEntity, allocator, row) catch |err| {
                    if (err == error.TypeMismatch) explainScanFailure(target_info, TargetEntity, row);
                    return err;
                };
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

            for (entities) |e| {
                if (map.get(@field(e.*, ParentInfo.pk_field))) |list| {
                    const slice = try allocator.dupe(TargetEntity, list.items);
                    @field(e.edges, edge.name) = slice;
                }
            }

            // Recurse one level into the loaded targets. The terminal
            // eager-load target (PlainFields) carries no edges container;
            // the comptime guard stops its instantiation from being
            // analyzed (a third nesting level stays a compile error).
            // Recurse one level into the loaded targets. Every level-1 target
            // goes into one pointer list so the next level is a single query;
            // recursing per parent issued one query per parent (N+1).
            if (comptime @hasField(TargetEntity, "edges")) {
                if (split.rest.len > 0) {
                    var next: std.ArrayListUnmanaged(*TargetEntity) = .empty;
                    defer next.deinit(allocator);
                    for (entities) |e| {
                        if (@field(e.edges, edge.name)) |items| {
                            try next.ensureUnusedCapacity(allocator, items.len);
                            for (items) |*t| next.appendAssumeCapacity(t);
                        }
                    }
                    if (next.items.len > 0) {
                        try loadEdgePath(infos, target_info, TargetEntity, allocator, driver, execution_context, next.items, split.rest, privacy_ctx, interceptors, with_trashed);
                    }
                }
            }
            return;
        }
    }
    return error.InvalidEdge;
}

/// How `WithEdgeOptions` joins an eager-loaded edge.
pub const EdgeJoinKind = enum {
    /// Keep parents with no matching edge targets (edge slice stays null).
    left,
    /// Filter the parent query with a schema-aware EXISTS subquery so only
    /// parents with at least one edge target are returned. SQL LIMIT then
    /// applies after the filter — no limit skew.
    inner,
};

/// Controls when the parent LIMIT applies relative to edge filtering.
pub const EdgeLimitMode = enum {
    /// LIMIT in the parent SQL (default).
    before_edges,
    /// With `.inner` joins the EXISTS filter runs in SQL, so LIMIT already
    /// applies after the edge filter — this flag documents that intent.
    /// With `.left` joins edge loading never changes the parent set, so
    /// this mode is a no-op.
    after_edges,
};

/// Options for `QueryBuilder.WithEdgeOptions`.
pub const WithEdgeOpts = struct {
    join: EdgeJoinKind = .left,
    limit_mode: EdgeLimitMode = .before_edges,
};

const WithEdgeEntry = struct {
    path: []const u8,
    opts: WithEdgeOpts,
};

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
        with_edges: std.ArrayListUnmanaged(WithEdgeEntry),
        group_cols: std.ArrayListUnmanaged([]const u8),
        or_in_chunks: std.ArrayListUnmanaged([]const []const sql.Value),
        having_pred: ?sql.Predicate,
        /// Optional column projection (Select); rows are scanned by column
        /// name and unselected fields keep zero values (read-only entities).
        select_cols: ?[]const []const u8 = null,
        for_update: bool,
        for_share: bool,
        for_update_of: ?[]const u8 = null,
        skip_locked: bool = false,
        nowait: bool = false,
        privacy_ctx: ?privacy.PrivacyContext = null,
        /// Shared interceptor chain borrowed from the entity client; run
        /// before every execution method (after privacy filter injection).
        interceptors: ?*intercept.InterceptorChain = null,
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

        /// Add predicates to the WHERE clause.
        ///
        /// Accepts a single `sql.Predicate`, a tuple/array/slice of them, or a
        /// pointer to any of those (`&.{ … }` is the common literal form). The
        /// full shape table lives on `sql.appendPredicates`, which is the one
        /// implementation all builders delegate to.
        pub fn Where(self: *Self, predicates: anytype) !*Self {
            try sql.appendPredicates(&self.predicates, predicates, "QueryBuilder.Where");
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
            try self.predicates.append(sql.OrIn(columnName(info, column), chunks));
            return self;
        }

        /// Append ORDER BY terms. A plain `.column` term is treated as a
        /// field name and mapped to its physical column; `.expr`/`.raw` are
        /// emitted verbatim.
        pub fn OrderBy(self: *Self, terms: []const sql.Order) !*Self {
            for (terms) |t| {
                switch (t) {
                    .column => |o| try self.order_terms.append(.{ .column = .{
                        .name = columnName(info, o.name),
                        .desc = o.desc,
                    } }),
                    else => try self.order_terms.append(t),
                }
            }
            return self;
        }

        /// Order results by the count of neighbors reachable via `edge_name`.
        /// For example, `OrderByEdgeCount("cars", .desc)` produces:
        ///   ORDER BY (SELECT COUNT(*) FROM "car" WHERE "car"."owner_id" = "user"."id") DESC
        pub fn OrderByEdgeCount(self: *Self, comptime edge_name: []const u8, comptime desc: bool) !*Self {
            const edge = comptime findEdgeInfo(info, edge_name);
            const target_info = comptime edgeTargetInfo(infos, info, edge);
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

        /// Set a cursor to page after a given entity, using its primary-key field.
        pub fn CursorAfter(self: *Self, entity: Entity) *Self {
            self.cursor_col = info.pk_field;
            self.cursor_val = idValue(@field(entity, info.pk_field));
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
            return self.WithEdgeOptions(edge_path, .{});
        }

        /// Eager-load an edge with options. `.join = .inner` adds a
        /// schema-aware EXISTS filter on the head edge: parents without
        /// targets are excluded in SQL, so LIMIT applies after the filter
        /// (no limit skew from post-load filtering). Nested dot paths
        /// filter on the head edge only.
        pub fn WithEdgeOptions(self: *Self, comptime edge_path: []const u8, opts: WithEdgeOpts) !*Self {
            const head = comptime blk: {
                if (std.mem.indexOfScalar(u8, edge_path, '.')) |dot| break :blk edge_path[0..dot];
                break :blk edge_path;
            };
            _ = comptime findEdgeInfo(info, head);
            if (opts.join == .inner) {
                const lowerHasEdge = @import("predicate.zig").lowerHasEdge;
                var pred = sql.Predicate{ .has_edge = .{ .edge_name = head, .fk_col = "", .pred = null } };
                try lowerHasEdge(infos, info, self.allocator, &pred);
                try self.predicates.append(pred);
            }
            try self.with_edges.append(self.allocator, .{ .path = edge_path, .opts = opts });
            return self;
        }

        pub fn GroupBy(self: *Self, columns: []const []const u8) !*Self {
            for (columns) |c| {
                try self.group_cols.append(self.allocator, columnName(info, c));
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

        /// Row-lock variants: `of` scopes the lock (PostgreSQL only),
        /// `skip_locked`/`nowait` avoid blocking (PostgreSQL 9.5+, MySQL 8+).
        pub fn ForUpdateWith(self: *Self, opts: sql.Selector.LockOpts) *Self {
            self.for_update = true;
            self.for_update_of = opts.of;
            self.skip_locked = opts.skip_locked;
            self.nowait = opts.nowait;
            return self;
        }

        /// Free every entity `All()` / `First()` handed back, plus the list
        /// itself — the one-call form of the loop every call site writes out:
        ///
        /// ```zig
        /// var users = try q.All();
        /// defer q.deinitRows(&users);
        /// ```
        ///
        /// Safe to call twice (the list is left empty and reusable), and safe
        /// after `q.deinit()` — the graph is comptime and the allocator is a
        /// plain copy. `client.<entity>.deinitRows` is the same call when the
        /// builder is already out of scope.
        pub fn deinitRows(self: *Self, rows: *std.array_list.Managed(Entity)) void {
            deinitEntityList(infos, info, self.allocator, rows);
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

        const QueryError = sql_driver.Error || error{ PrivacyDenied, NotFound, NotSingular, TypeMismatch, ColumnCountMismatch, MissingColumn, InvalidEdge, InvalidCursor, BuildFailed, UuidEdgesUnsupported, InterceptFailed };
        const BuildError = error{ OutOfMemory, BuildFailed };
        const ExplainError = error{ OutOfMemory, BuildFailed, InvalidCursor, UnsupportedDialect };
        /// `Sum` / `Avg` only. A separate set rather than a member of
        /// `QueryError`, which every reader shares: adding to that one would
        /// widen `All()`, `First()` and the rest with an error none of them can
        /// return, and break callers that switch over the set exhaustively.
        const AggregateError = QueryError || error{EmptyAggregate};

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
                    try scanEntityNamed(info, Entity, self.allocator, row)
                else
                    try scanEntity(info, Entity, self.allocator, row);
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

        /// Run the interceptor chain against this query. Interceptor errors
        /// collapse to `error.InterceptFailed` so execution methods keep
        /// their explicit error sets.
        fn runInterceptors(self: *Self, op: hook.Op) error{InterceptFailed}!void {
            const chain = self.interceptors orelse return;
            var view = intercept.QueryView{
                .op = op,
                .table_name = info.table_name,
                .sink = self,
                .add_eq_fn = addEqPredicate,
            };
            chain.run(&view) catch return error.InterceptFailed;
        }

        /// QueryView sink: append `field_name = value` after validating the
        /// field against the entity schema (unknown fields are rejected).
        fn addEqPredicate(sink: *anyopaque, field_name: []const u8, value: sql.Value) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(sink));
            var found = false;
            inline for (info.fields) |f| {
                if (std.mem.eql(u8, f.name, field_name)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.UnknownField;
            try sql.appendEqUnlessPresent(&self.predicates, columnName(info, field_name), value);
        }

        /// Fetch every matching row. Returns `std.array_list.Managed(Entity)`:
        /// iterate via `result.items` (a slice) and free each entity with
        /// `deinitEntity(infos, info, &item, allocator)` before `result.deinit()`.
        /// Contrast with `paged()`, which returns a `PagedResult` whose rows
        /// live at `result.items.items` and whose `deinit()` frees the entities.
        ///
        /// For a page whose whole lifetime is one arena, use `AllIn`.
        pub fn All(self: *Self) QueryError!std.array_list.Managed(Entity) {
            return std.array_list.Managed(Entity).fromOwnedSlice(
                self.allocator,
                try self.readAll(self.allocator),
            );
        }

        /// `All`, with every byte the page owns coming from `arena`: the row
        /// slice, every `[]const u8` / slice field, every JSON payload (its
        /// per-entity arena is a child of `arena`), and every eager-loaded
        /// edge. Nothing needs freeing — `arena.deinit()` is the release, and
        /// the rows must **not** be passed to `deinitRows`/`deinitEntity`,
        /// which would free them into the wrong allocator.
        ///
        /// Use it when the request itself owns a `std.heap.ArenaAllocator`
        /// (HTTP handlers, one-shot reports): the whole page disappears with
        /// the request, instead of a per-entity teardown the caller has to
        /// remember. `All`'s caller-owned contract is unchanged.
        pub fn AllIn(self: *Self, arena: *std.heap.ArenaAllocator) QueryError![]Entity {
            return self.readAll(arena.allocator());
        }

        /// Shared implementation of `All` / `AllIn`. `alloc` is the *scan*
        /// allocator — the one that owns the rows — as distinct from
        /// `self.allocator`, which still owns the SQL text and the argument
        /// list released by `q.deinit()` below.
        fn readAll(self: *Self, alloc: std.mem.Allocator) QueryError![]Entity {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            try self.runInterceptors(.query);
            var q = try self.buildQuery(info.fields.len);
            defer q.deinit();
            self.ensureDeadline();
            const start = nowUs();
            var rows = try self.driver.queryCtx(&self.execution_context, q.sql, q.args);
            defer rows.deinit();

            var result = std.array_list.Managed(Entity).init(alloc);
            errdefer {
                for (result.items) |*e| deinitEntity(infos, info, e, alloc);
                result.deinit();
            }

            while (rows.next()) |row| {
                var entity = if (self.select_cols != null)
                    try scanEntityNamed(info, Entity, alloc, row)
                else
                    try scanEntity(info, Entity, alloc, row);
                errdefer deinitEntity(infos, info, &entity, alloc);
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

            for (self.with_edges.items) |we| {
                try self.loadEdges(alloc, we.path, result.items);
            }
            // The backing slice is handed back as-is: with the caller's
            // allocator the page still owns it (`deinitRows` frees it), with
            // an arena the arena does.
            return try result.toOwnedSlice();
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
            try self.runInterceptors(.query);
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
                    // No row has been read yet — the iterator the caller gets
                    // back has not run — so there is no count to report. `0`
                    // here would read as "the query matched nothing".
                    .rows_affected = 0,
                    .rows_affected_known = false,
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
            return self.readFirst(self.allocator);
        }

        /// `First`, with the entity owned by `arena` instead of the builder's
        /// allocator: every string/slice field, its JSON payload and its
        /// eager-loaded edges come from `arena`, so `arena.deinit()` is the
        /// release and `deinitEntity` must not be called on the result.
        ///
        /// Returns `null` when nothing matches; the arena is untouched then.
        pub fn FirstIn(self: *Self, arena: *std.heap.ArenaAllocator) QueryError!?Entity {
            return self.readFirst(arena.allocator());
        }

        /// Shared implementation of `First` / `FirstIn`; `alloc` owns the
        /// returned entity (see `readAll`).
        fn readFirst(self: *Self, alloc: std.mem.Allocator) QueryError!?Entity {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            try self.runInterceptors(.query);
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
                try scanEntityNamed(info, Entity, alloc, row)
            else
                try scanEntity(info, Entity, alloc, row);
            errdefer deinitEntity(infos, info, &entity, alloc);

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
            for (self.with_edges.items) |we| {
                try self.loadEdges(alloc, we.path, &entities_arr);
            }
            return entities_arr[0];
        }

        pub fn Only(self: *Self) QueryError!Entity {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            try self.runInterceptors(.query);
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
                try scanEntityNamed(info, Entity, self.allocator, row)
            else
                try scanEntity(info, Entity, self.allocator, row);
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
            for (self.with_edges.items) |we| {
                try self.loadEdges(self.allocator, we.path, &entities_arr);
            }
            return entities_arr[0];
        }

        pub fn IDs(self: *Self) QueryError!std.array_list.Managed(i64) {
            // A textual (uuid) primary key has no id to hand back: SQLite
            // coerces the text to a number (a leading-digit prefix, else 0)
            // and the other dialects would refuse outright, so a list of
            // integers that name no row is the one answer this must not give.
            if (comptime @TypeOf(@field(@import("../sql/scan.zig").zeroInit(Entity), info.pk_field)) != i64) {
                @compileError("IDs() requires an i64 primary key; a textual key has no id to return");
            }
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            try self.runInterceptors(.query);
            // The primary key, not the first declared field: a custom `pk`
            // keeps the declaration order (`fromSchema` injects `id` first only
            // for the default key), so `fields[0]` is the key only by
            // convention.
            var q = try self.buildQueryWithFirst(1, pkColumn(info));
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
            try self.runInterceptors(.query);
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

        /// One group row from `AggregateBy`: the group key and the aggregate
        /// result. String/bytes payloads are duped — free with
        /// `freeGroupMetrics`.
        pub const GroupMetric = struct { key: sql.Value, value: sql.Value };

        /// Free duped string/bytes payloads in each entry, then the list.
        pub fn freeGroupMetrics(list: *std.array_list.Managed(GroupMetric)) void {
            for (list.items) |*m| {
                if (m.key == .string) list.allocator.free(m.key.string);
                if (m.key == .bytes) list.allocator.free(m.key.bytes);
                if (m.value == .string) list.allocator.free(m.value.string);
                if (m.value == .bytes) list.allocator.free(m.value.bytes);
            }
            list.deinit();
        }

        fn readAggValue(row: sql_driver.Row, col: usize, allocator: std.mem.Allocator) QueryError!sql.Value {
            if (row.isNull(col)) return .null;
            if (row.getInt(col)) |v| return .{ .int = v };
            if (row.getFloat(col)) |v| return .{ .float = v };
            // Dup text/blob while rows is alive: getters borrow driver buffers.
            if (row.getText(col)) |v| return .{ .string = try allocator.dupe(u8, v) };
            if (row.getBlob(col)) |v| return .{ .bytes = try allocator.dupe(u8, v) };
            return error.TypeMismatch;
        }

        pub fn CountBy(self: *Self, comptime field_name: []const u8) QueryError!std.array_list.Managed(GroupCount) {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            try self.runInterceptors(.query);
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
            const col = comptime columnName(info, field_name);
            const key_col = sql.ColumnRef{ .table = null, .name = col, .raw = false };
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
            _ = try selector.groupBy(&.{col});
            if (self.having_pred) |pred| {
                _ = selector.having(pred);
            }
            return selector.takeQuery() catch |err| return mapBuildError(err);
        }

        pub fn Exist(self: *Self) QueryError!bool {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            try self.runInterceptors(.query);
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

        /// `SUM(col)` over the matching rows, as `f64`.
        ///
        /// `error.EmptyAggregate` when no row matched (or every value is NULL):
        /// SQL's `SUM` is NULL there, and "there is no data" is a different
        /// statement from `error.TypeMismatch`, which means a value came back
        /// that is not a number. `SumOrZero` is the variant that answers `0`
        /// instead of the error, and `Max` / `Min` answer `sql.Value` so their
        /// NULL stays visible in the value.
        pub fn Sum(self: *Self, comptime field_name: []const u8) AggregateError!f64 {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            try self.runInterceptors(.query);
            const col = comptime columnName(info, field_name);
            var q = try self.buildAggregateQuery("SUM(\"" ++ col ++ "\")");
            defer q.deinit();
            self.ensureDeadline();
            var rows = try self.driver.queryCtx(&self.execution_context, q.sql, q.args);
            defer rows.deinit();
            const row = rows.next() orelse {
                if (rows.nextError()) |e| return e;
                return error.NotFound;
            };
            // empty set (or an all-NULL column) makes SQL's SUM NULL; the
            // numeric result parses via the text representation.
            return row.getFloat(0) orelse if (row.isNull(0)) error.EmptyAggregate else error.TypeMismatch;
        }

        /// `AVG(col)` over the matching rows — `error.EmptyAggregate` on an
        /// empty set, exactly as `Sum` (see its doc; `getFloat` answers null
        /// both for a SQL NULL and for a value it cannot read as a number, so
        /// the column's own null check is what tells the two apart).
        pub fn Avg(self: *Self, comptime field_name: []const u8) AggregateError!f64 {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            try self.runInterceptors(.query);
            const col = comptime columnName(info, field_name);
            var q = try self.buildAggregateQuery("AVG(\"" ++ col ++ "\")");
            defer q.deinit();
            self.ensureDeadline();
            var rows = try self.driver.queryCtx(&self.execution_context, q.sql, q.args);
            defer rows.deinit();
            const row = rows.next() orelse {
                if (rows.nextError()) |e| return e;
                return error.NotFound;
            };
            // As in `Sum`: an empty set is NULL, not a type problem.
            return row.getFloat(0) orelse if (row.isNull(0)) error.EmptyAggregate else error.TypeMismatch;
        }

        pub fn Max(self: *Self, comptime field_name: []const u8) QueryError!sql.Value {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            try self.runInterceptors(.query);
            const col = comptime columnName(info, field_name);
            var q = try self.buildAggregateQuery("MAX(\"" ++ col ++ "\")");
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
            try self.runInterceptors(.query);
            const col = comptime columnName(info, field_name);
            var q = try self.buildAggregateQuery("MIN(\"" ++ col ++ "\")");
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

        /// COALESCE(SUM(field), 0): an empty set yields 0 instead of the
        /// `error.TypeMismatch` a bare `Sum` returns on SQL NULL.
        pub fn SumOrZero(self: *Self, comptime field_name: []const u8) QueryError!f64 {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            try self.runInterceptors(.query);
            const col = comptime columnName(info, field_name);
            var q = try self.buildAggregateQuery("COALESCE(SUM(\"" ++ col ++ "\"), 0)");
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

        /// Generic single-expression aggregate, e.g. `AggregateOne("COUNT(DISTINCT user_id)")`.
        /// The expression is emitted verbatim — never interpolate user input.
        /// String results are duped; free with the query allocator when
        /// the returned value is `.string`/`.bytes`.
        pub fn AggregateOne(self: *Self, comptime agg_expr: []const u8) QueryError!sql.Value {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            try self.runInterceptors(.query);
            var q = try self.buildAggregateQuery(agg_expr);
            defer q.deinit();
            self.ensureDeadline();
            var rows = try self.driver.queryCtx(&self.execution_context, q.sql, q.args);
            defer rows.deinit();
            const row = rows.next() orelse {
                if (rows.nextError()) |e| return e;
                return error.NotFound;
            };
            return readAggValue(row, 0, self.allocator);
        }

        /// Exact text form of an aggregate (e.g. DECIMAL `SUM`), avoiding
        /// float rounding for money columns. Returns null on SQL NULL.
        /// Caller owns the returned slice (free with the query allocator).
        pub fn AggregateText(self: *Self, comptime agg_expr: []const u8) QueryError!?[]u8 {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            try self.runInterceptors(.query);
            var q = try self.buildAggregateQuery(agg_expr);
            defer q.deinit();
            self.ensureDeadline();
            var rows = try self.driver.queryCtx(&self.execution_context, q.sql, q.args);
            defer rows.deinit();
            const row = rows.next() orelse {
                if (rows.nextError()) |e| return e;
                return error.NotFound;
            };
            if (row.isNull(0)) return null;
            const text = row.getText(0) orelse return error.TypeMismatch;
            return try self.allocator.dupe(u8, text);
        }

        /// Grouped aggregate: `SELECT group_field, <agg_expr> ... GROUP BY
        /// group_field`. When `GroupBy` was already called with extra columns
        /// they are appended after `group_field`. Honors Where/Having and
        /// soft-delete filtering like `CountBy`. `agg_expr` is emitted
        /// verbatim — never interpolate user input.
        /// Caller frees the result with `freeGroupMetrics`.
        pub fn AggregateBy(self: *Self, comptime agg_expr: []const u8, comptime group_field: []const u8) QueryError!std.array_list.Managed(GroupMetric) {
            const pol = try self.checkPolicy();
            try self.injectPrivacyFilters(pol);
            try self.runInterceptors(.query);
            const t = sql.Table(info.table_name);
            const group_col = comptime columnName(info, group_field);
            const key_col = sql.ColumnRef{ .table = null, .name = group_col, .raw = false };
            const val_col = sql.ColumnRef{ .table = null, .name = agg_expr, .raw = true };
            var selector = try sql.Select(self.allocator, self.driver.dialect(), &.{ key_col, val_col });
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
            } else {
                _ = try selector.groupBy(&.{group_col});
            }
            if (self.having_pred) |pred| {
                _ = selector.having(pred);
            }
            var q = selector.takeQuery() catch |err| return mapBuildError(err);
            defer q.deinit();
            self.ensureDeadline();
            var rows = try self.driver.queryCtx(&self.execution_context, q.sql, q.args);
            defer rows.deinit();
            var result = std.array_list.Managed(GroupMetric).init(self.allocator);
            errdefer freeGroupMetrics(&result);
            while (rows.next()) |row| {
                const key = try readAggValue(row, 0, self.allocator);
                errdefer {
                    if (key == .string) self.allocator.free(key.string);
                    if (key == .bytes) self.allocator.free(key.bytes);
                }
                const value = try readAggValue(row, 1, self.allocator);
                try result.append(.{ .key = key, .value = value });
            }
            if (rows.nextError()) |e| return e;
            return result;
        }

        /// Eager-load `edge_path` for `entities`. `alloc` owns every byte the
        /// loaded edges keep: the slice written back into each parent, the
        /// neighbour rows' strings, and their JSON arenas. It is
        /// `self.allocator` for `All`/`First`/`Only`, and the caller's arena
        /// for `AllIn`/`FirstIn`.
        fn loadEdges(self: *Self, alloc: std.mem.Allocator, edge_path: []const u8, entities: []Entity) !void {
            if (entities.len == 0) return;
            const ptrs = try alloc.alloc(*Entity, entities.len);
            defer alloc.free(ptrs);
            for (entities, 0..) |*e, i| ptrs[i] = e;
            return loadEdgePath(infos, info, Entity, alloc, self.driver, self.execution_context, ptrs, edge_path, self.privacy_ctx, self.interceptors, self.with_trashed);
        }

        fn buildQuery(self: *Self, comptime column_count: usize) !sql.OwnedQuery {
            return self.buildQueryWithFirst(column_count, null);
        }

        /// `buildQuery`, with the first projected column named explicitly.
        /// `IDs()` uses it to project the primary key — which is not
        /// necessarily the first declared field — and, by naming its own
        /// column, also ignores a caller-supplied `Select(...)`: the method's
        /// contract is the keys of the matching rows, not a projection.
        fn buildQueryWithFirst(self: *Self, comptime column_count: usize, comptime first_col: ?[]const u8) !sql.OwnedQuery {
            const t = sql.Table(info.table_name);
            var all_cols: [column_count][]const u8 = undefined;
            inline for (info.fields[0..column_count], 0..) |f, i| all_cols[i] = f.column_name;
            if (comptime first_col) |fc| all_cols[0] = fc;
            const cols: []const []const u8 = if (comptime first_col != null)
                all_cols[0..column_count]
            else
                self.select_cols orelse all_cols[0..column_count];
            var columns: [info.fields.len]sql.ColumnRef = undefined;
            // `Select` stores field names; emit their physical columns.
            for (cols, 0..) |cname, i| columns[i] = t.c(columnName(info, cname));
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
                    const col_sql = columnName(info, col);
                    const pk_col = pkColumn(info);
                    if (self.cursor_id) |id_val| {
                        // Composite keyset: (col > ?) OR (col = ? AND id > ?)
                        // — ties on the cursor column never drop rows.
                        const col_cmp = if (self.cursor_desc) sql.LT(col_sql, val) else sql.GT(col_sql, val);
                        const col_eq = sql.EQ(col_sql, val);
                        const id_cmp = if (self.cursor_desc)
                            sql.LT(pk_col, .{ .int = id_val })
                        else
                            sql.GT(pk_col, .{ .int = id_val });
                        _ = try selector.where(sql.Or(&col_cmp, &sql.And(&col_eq, &id_cmp)));
                    } else {
                        // Single-column cursor (backward compatible).
                        if (self.cursor_desc) {
                            _ = try selector.where(sql.LT(col_sql, val));
                        } else {
                            _ = try selector.where(sql.GT(col_sql, val));
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
                const col_sql = columnName(info, col);
                const pk_col = pkColumn(info);
                // When cursor pagination is active, ensure ORDER BY col ASC/DESC is present.
                if (self.order_terms.items.len == 0) {
                    if (self.cursor_desc) {
                        _ = try selector.orderBy(sql.OrderDesc(col_sql));
                    } else {
                        _ = try selector.orderBy(sql.OrderAsc(col_sql));
                    }
                }
                // Auto-add pk tie-breaker for stable keyset pagination
                if (!std.mem.eql(u8, col, info.pk_field)) {
                    var has_id: bool = false;
                    for (self.order_terms.items) |term| {
                        switch (term) {
                            .column => |o| {
                                if (std.mem.eql(u8, o.name, pk_col)) {
                                    has_id = true;
                                    break;
                                }
                            },
                            else => {},
                        }
                    }
                    if (!has_id) {
                        if (self.cursor_desc) {
                            _ = try selector.orderBy(sql.OrderDesc(pk_col));
                        } else {
                            _ = try selector.orderBy(sql.OrderAsc(pk_col));
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
                _ = selector.forUpdateWith(.{
                    .of = self.for_update_of,
                    .skip_locked = self.skip_locked,
                    .nowait = self.nowait,
                });
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
    try std.testing.expectEqualStrings("cars", q.with_edges.items[0].path);
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
    const QueryError = sql_driver.Error || error{ PrivacyDenied, NotFound, NotSingular, TypeMismatch, ColumnCountMismatch, MissingColumn, InvalidEdge, InvalidCursor, BuildFailed, UuidEdgesUnsupported, InterceptFailed };

    comptime {
        const method_names = .{ "All", "Iterate", "First", "Only", "IDs", "Count", "Exist", "Max", "Min" };
        for (method_names) |method_name| {
            const return_type = @typeInfo(@TypeOf(@field(UserQuery, method_name))).@"fn".return_type.?;
            if (@typeInfo(return_type).error_union.error_set != QueryError) {
                @compileError("QueryBuilder." ++ method_name ++ " error set is not explicit");
            }
        }
    }

    comptime {
        // `Sum` / `Avg` add `error.EmptyAggregate` — an empty set makes SQL's
        // aggregate NULL, which is not the type problem `TypeMismatch` names —
        // and only they do: the five readers above keep the set they had, so a
        // caller switching over `QueryError` is not disturbed by it.
        const AggregateError = QueryError || error{EmptyAggregate};
        const aggregate_names = .{ "Sum", "Avg" };
        for (aggregate_names) |method_name| {
            const return_type = @typeInfo(@TypeOf(@field(UserQuery, method_name))).@"fn".return_type.?;
            if (@typeInfo(return_type).error_union.error_set != AggregateError) {
                @compileError("QueryBuilder." ++ method_name ++ " error set is not AggregateError");
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
    const QE = sql_driver.Error || error{ PrivacyDenied, NotFound, NotSingular, TypeMismatch, ColumnCountMismatch, MissingColumn, InvalidEdge, BuildFailed, InvalidCursor, UuidEdgesUnsupported, InterceptFailed };

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

test "an unread streaming page reaches the log without a row count" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGenerator = @import("entity.zig").Entity;
    const sql_logger = @import("../sql/logger.zig");

    // What the logger saw lives at container level: the callbacks carry no
    // user pointer (same shape as `client.zig`'s SqlSink).
    const Seen = struct {
        var calls: usize = 0;
        var rows: usize = 0;
        var known: bool = false;

        fn onQuery(ctx: sql_logger.LogContext) void {
            calls += 1;
            rows = ctx.rows_affected;
            known = ctx.rows_affected_known;
        }
    };

    const EmptyRows = struct {
        fn next(_: *anyopaque) ?sql_driver.Row {
            return null;
        }
        fn deinit(_: *anyopaque) void {}
        const vtable = sql_driver.Rows.VTable{ .next = next, .deinit = deinit };
    };

    const MockDriver = struct {
        pub fn asDriver(self: *@This()) sql_driver.Driver {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn mockExec(_: *anyopaque, _: ?*const sql_driver.ExecutionContext, _: []const u8, _: []const sql.Value) sql_driver.Error!sql_driver.Result {
            unreachable;
        }
        fn mockQuery(ptr: *anyopaque, _: ?*const sql_driver.ExecutionContext, _: []const u8, _: []const sql.Value) sql_driver.Error!sql_driver.Rows {
            return .{ .ptr = ptr, .vtable = &EmptyRows.vtable };
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
    q.logger = .{ .onQuery = Seen.onQuery };

    Seen.calls = 0;
    Seen.known = true;

    // `Iterate` hands the caller a stream that has not been read yet, so no
    // row count exists at the moment of the log call. Shipping the `0`
    // placeholder as a known count is the "statement matched nothing" claim
    // the drivers stopped making in v0.63.0, and the log is the last layer
    // that still made it.
    var it = try q.Iterate();
    defer it.deinit();

    try std.testing.expectEqual(@as(usize, 1), Seen.calls);
    try std.testing.expect(!Seen.known);
    try std.testing.expectEqual(@as(usize, 0), Seen.rows);
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

test "WithEdgeOptions inner join filters parents and honors SQL limit" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const edge = @import("../core/edge.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const buildGraph = @import("graph.zig").buildGraph;
    const sqlite_driver = @import("../sql/sqlite.zig");
    const client_mod = @import("client.zig");
    const migrate = @import("../sql/schema/migrate.zig");

    const User = Schema("InnerUser", .{
        .fields = &.{field.String("name")},
    });
    const Post = Schema("InnerPost", .{
        .fields = &.{
            field.Int("inner_user_id"),
            field.String("title"),
        },
        .edges = &.{edge.From("author", User).Field("inner_user_id")},
    });
    const UserWithEdge = Schema("InnerUser", .{
        .fields = &.{field.String("name")},
        .edges = &.{edge.To("posts", Post)},
    });

    const graph = comptime buildGraph(&.{ UserWithEdge, Post });
    const infos = graph.types;
    const user_info = comptime fromSchema(UserWithEdge);
    const post_info = comptime fromSchema(Post);

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);
    const root = client_mod.makeClient(infos, allocator, driver.asDriver());

    // Seed: u1 no posts, u2 two posts, u3 no posts.
    for (1..4) |i| {
        var b = try root.inner_user.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", switch (i) {
            1 => "u1",
            2 => "u2",
            else => "u3",
        });
        var row = try b.Save();
        defer deinitEntity(infos, user_info, &row, allocator);
        if (i == 2) {
            for (0..2) |j| {
                var pb = try root.inner_post.Create();
                defer pb.deinit();
                _ = try pb.setFieldValue("inner_user_id", row.id);
                _ = try pb.setFieldValue("title", if (j == 0) "p1" else "p2");
                var prow = try pb.Save();
                defer deinitEntity(infos, post_info, &prow, allocator);
            }
        }
    }

    // Inner join: only u2 survives; its posts are loaded.
    {
        var q = root.inner_user.Query();
        defer q.deinit();
        _ = try q.WithEdgeOptions("posts", .{ .join = .inner });
        const users = try q.All();
        defer {
            for (users.items) |*e| deinitEntity(infos, user_info, e, allocator);
            users.deinit();
        }
        try std.testing.expectEqual(@as(usize, 1), users.items.len);
        try std.testing.expectEqualStrings("u2", users.items[0].name);
        try std.testing.expectEqual(@as(usize, 2), users.items[0].edges.posts.?.len);
    }

    // Limit skew fix: LIMIT 1 with the inner filter returns u2, not u1.
    {
        var q = root.inner_user.Query();
        defer q.deinit();
        _ = try q.OrderBy(&.{sql.OrderAsc("id")});
        _ = q.Limit(1);
        _ = try q.WithEdgeOptions("posts", .{ .join = .inner, .limit_mode = .after_edges });
        const users = try q.All();
        defer {
            for (users.items) |*e| deinitEntity(infos, user_info, e, allocator);
            users.deinit();
        }
        try std.testing.expectEqual(@as(usize, 1), users.items.len);
        try std.testing.expectEqualStrings("u2", users.items[0].name);
    }

    // Default (left) join keeps everyone.
    {
        var q = root.inner_user.Query();
        defer q.deinit();
        _ = try q.WithEdge("posts");
        const users = try q.All();
        defer {
            for (users.items) |*e| deinitEntity(infos, user_info, e, allocator);
            users.deinit();
        }
        try std.testing.expectEqual(@as(usize, 3), users.items.len);
    }
}

test "IDs projects the primary key, not the first declared field" {
    // `buildQuery(1)` projected `info.fields[0]`, and a custom `pk` keeps the
    // declaration order (`fromSchema` injects `id` first only for the default
    // key), so `IDs()` answered with whatever the first declared field held.
    // Nothing in the tree exercised `IDs()`, which is why it went unnoticed.
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const migrate = @import("../sql/schema/migrate.zig");
    const sqlite_driver = @import("../sql/sqlite.zig");
    const client_mod = @import("client.zig");

    const Item = schema("IdsItem", .{
        .table_name = "ids_item",
        .pk = "push_id",
        .fields = &.{ field.Int("age"), field.Int("push_id") },
    });
    const info = comptime fromSchema(Item);
    const infos = &[_]TypeInfo{info};

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);

    const Client = client_mod.EntityClient(infos, info);
    const client = Client.init(allocator, driver.asDriver());

    for ([_][2]i64{ .{ 7, 100 }, .{ 9, 200 } }) |pair| {
        var b = try client.Create();
        defer b.deinit();
        _ = try b.setFieldValue("age", pair[0]);
        _ = try b.setFieldValue("push_id", pair[1]);
        var row = try b.Save();
        deinitEntity(infos, info, &row, allocator);
    }

    var q = client.Query();
    defer q.deinit();
    var ids = try q.IDs();
    defer ids.deinit();
    try std.testing.expectEqual(@as(usize, 2), ids.items.len);
    // Sorted here rather than ordered by the query: the assertion is about
    // *which* column came back, not about the rows' order.
    std.mem.sort(i64, ids.items, {}, std.sort.asc(i64));
    try std.testing.expectEqualSlices(i64, &.{ 100, 200 }, ids.items);
}

test "EntQL has/not_has and WithEdgeOptions inner join keep the target's soft-delete scope" {
    // The lowers built `.has_neighbors_with` without the target's soft-delete
    // flag (the payload defaults to false), while the typed `Has{Edge}()` /
    // `NotHas{Edge}()` predicates have always carried it — "a trashed row
    // cannot satisfy an existence filter". So `has(cars)` passed for a parent
    // whose only car was trashed and `not_has(cars)` failed, both disagreeing
    // with the typed predicates, and an inner-joined eager load kept a parent
    // whose `edges.cars` then came back null.
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const edge = @import("../core/edge.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const buildGraph = @import("graph.zig").buildGraph;
    const sqlite_driver = @import("../sql/sqlite.zig");
    const client_mod = @import("client.zig");
    const migrate = @import("../sql/schema/migrate.zig");
    const SoftDeleteMixin = @import("../core/mixin.zig").SoftDeleteMixin;

    const UserBase = Schema("SoftUser", .{ .fields = &.{field.String("name")} });
    const Car = Schema("SoftCar", .{
        .fields = &.{ field.Int("soft_user_id"), field.String("model") },
        .edges = &.{edge.From("owner", UserBase).Field("soft_user_id")},
        .mixins = &.{SoftDeleteMixin},
        .soft_delete = true,
    });
    const User = Schema("SoftUser", .{
        .fields = &.{field.String("name")},
        .edges = &.{edge.To("cars", Car)},
    });

    const graph = comptime buildGraph(&.{ User, Car });
    const infos = graph.types;
    const user_info = comptime fromSchema(User);
    const preds = comptime @import("predicate.zig").makePredicates(infos, user_info);

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);
    const root = client_mod.makeClient(infos, allocator, driver.asDriver());

    // One user with exactly one car, then the car is trashed — the user has no
    // live car left, so no existence filter may be satisfied by it.
    var user_id: i64 = 0;
    {
        var b = try root.soft_user.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "u1");
        var row = try b.Save();
        defer deinitEntity(infos, user_info, &row, allocator);
        user_id = row.id;
    }
    {
        var b = try root.soft_car.Create();
        defer b.deinit();
        _ = try b.setFieldValue("soft_user_id", user_id);
        _ = try b.setFieldValue("model", "c1");
        var row = try b.Save();
        defer deinitEntity(infos, fromSchema(Car), &row, allocator);
    }
    {
        var d = root.soft_car.Delete();
        defer d.deinit();
        try std.testing.expectEqual(@as(usize, 1), try d.Exec());
    }

    // The typed predicates are the reference answer: one user, no live car.
    {
        var q = root.soft_user.Query();
        defer q.deinit();
        _ = try q.Where(.{preds.HasCars()});
        const users = try q.All();
        defer {
            for (users.items) |*e| deinitEntity(infos, user_info, e, allocator);
            users.deinit();
        }
        try std.testing.expectEqual(@as(usize, 0), users.items.len);
    }
    {
        var q = root.soft_user.Query();
        defer q.deinit();
        _ = try q.Where(.{preds.NotHasCars()});
        const users = try q.All();
        defer {
            for (users.items) |*e| deinitEntity(infos, user_info, e, allocator);
            users.deinit();
        }
        try std.testing.expectEqual(@as(usize, 1), users.items.len);
    }

    // The EntQL lowering must answer the same as the typed predicates.
    {
        var q = root.soft_user.Query();
        defer q.deinit();
        _ = try q.WhereEntQL("has(cars)");
        const users = try q.All();
        defer {
            for (users.items) |*e| deinitEntity(infos, user_info, e, allocator);
            users.deinit();
        }
        try std.testing.expectEqual(@as(usize, 0), users.items.len);
    }
    {
        var q = root.soft_user.Query();
        defer q.deinit();
        _ = try q.WhereEntQL("not_has(cars)");
        const users = try q.All();
        defer {
            for (users.items) |*e| deinitEntity(infos, user_info, e, allocator);
            users.deinit();
        }
        try std.testing.expectEqual(@as(usize, 1), users.items.len);
    }

    // The inner-joined eager load applies the same EXISTS, so the parent is
    // gone from the page rather than present with a null `edges.cars`.
    {
        var q = root.soft_user.Query();
        defer q.deinit();
        _ = try q.WithEdgeOptions("cars", .{ .join = .inner });
        const users = try q.All();
        defer {
            for (users.items) |*e| deinitEntity(infos, user_info, e, allocator);
            users.deinit();
        }
        try std.testing.expectEqual(@as(usize, 0), users.items.len);
    }
}

test "an m2m has() predicate is qualified to the target table" {
    // The M2M EXISTS body joins the junction `j` and the target `t`, and the
    // junction's columns are literally `<table>_id`. The caller's predicates
    // were rendered bare, so an EntQL `has(groups, user_id = …)` — a field
    // Group does not have — bound to `j.user_id`, and since `j.user_id =
    // <outer>.id` is already in the statement the filter degenerated into "the
    // outer row's id is …" and answered without an error. A predicate about the
    // target belongs qualified to it, which makes the unknown field fail at
    // prepare time instead.
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const edge = @import("../core/edge.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const buildGraph = @import("graph.zig").buildGraph;
    const sqlite_driver = @import("../sql/sqlite.zig");
    const client_mod = @import("client.zig");
    const migrate = @import("../sql/schema/migrate.zig");

    const GroupBase = Schema("D5QualGroup", .{ .fields = &.{field.String("name")} });
    const UserBase = Schema("D5QualUser", .{ .fields = &.{field.String("name")} });
    const Group = struct {
        pub const schema_name = GroupBase.schema_name;
        pub const fields = GroupBase.fields;
        pub const edges = &.{edge.To("users", UserBase)};
        pub const indexes = GroupBase.indexes;
    };
    const User = struct {
        pub const schema_name = UserBase.schema_name;
        pub const fields = UserBase.fields;
        pub const edges = &.{edge.To("groups", GroupBase)};
        pub const indexes = UserBase.indexes;
    };

    const graph = comptime buildGraph(&.{ User, Group });
    const infos = graph.types;
    const user_info = comptime fromSchema(User);

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);
    const root = client_mod.makeClient(infos, allocator, driver.asDriver());

    var group_ids: [2]i64 = undefined;
    for ([_][]const u8{ "x", "y" }, 0..) |name, i| {
        var b = try root.d5_qual_group.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", name);
        var row = try b.Save();
        defer deinitEntity(infos, fromSchema(Group), &row, allocator);
        group_ids[i] = row.id;
    }
    var user_ids: [2]i64 = undefined;
    for ([_][]const u8{ "u1", "u2" }, 0..) |name, i| {
        var b = try root.d5_qual_user.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", name);
        var row = try b.Save();
        defer deinitEntity(infos, user_info, &row, allocator);
        user_ids[i] = row.id;
    }
    // u1 belongs to group "x", u2 to group "y".
    for (0..2) |i| {
        var u = root.d5_qual_user.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", if (i == 0) "u1" else "u2");
        _ = try u.Where(.{root.d5_qual_user.predicates.idEQ(.{ .int = user_ids[i] })});
        _ = try u.AddEdgeIDs("groups", &.{group_ids[i]});
        try std.testing.expectEqual(@as(usize, 1), try u.Save());
    }

    // A predicate on a real target column keeps working — the qualification
    // does not cost the ordinary case. (This half passes unqualified too: only
    // the target has a `name` column, so it is a regression guard.)
    {
        var q = root.d5_qual_user.Query();
        defer q.deinit();
        _ = try q.WhereEntQL("has(groups, name = \"x\")");
        const users = try q.All();
        defer {
            for (users.items) |*e| deinitEntity(infos, user_info, e, allocator);
            users.deinit();
        }
        try std.testing.expectEqual(@as(usize, 1), users.items.len);
        try std.testing.expectEqualStrings("u1", users.items[0].name);
    }

    // The field Group does not have must not resolve to the junction's column:
    // the statement has to fail, not answer a filtered-by-accident row set.
    {
        const entql_sql = try std.fmt.allocPrint(allocator, "has(groups, user_id = {d})", .{user_ids[0]});
        defer allocator.free(entql_sql);
        var q = root.d5_qual_user.Query();
        defer q.deinit();
        _ = try q.WhereEntQL(entql_sql);
        if (q.All()) |users| {
            var leaked = users;
            defer {
                for (leaked.items) |*e| deinitEntity(infos, user_info, e, allocator);
                leaked.deinit();
            }
            return error.ExpectedPrepareFailure;
        } else |_| {}
    }
}
