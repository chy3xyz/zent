const std = @import("std");
const TypeInfo = @import("graph.zig").TypeInfo;
const FieldInfo = @import("graph.zig").FieldInfo;
const EdgeInfo = @import("graph.zig").EdgeInfo;
const buildEdgeStep = @import("graph.zig").buildEdgeStep;
const columnName = @import("graph.zig").columnName;
const pkColumn = @import("graph.zig").pkColumn;
const graph_step = @import("../graph/step.zig");
const sql = @import("../sql/builder.zig");
const sql_driver = @import("../sql/driver.zig");
const Dialect = @import("../sql/dialect.zig").Dialect;
const Hook = @import("../runtime/hook.zig").Hook;
const HookContext = @import("../runtime/hook.zig").HookContext;
const HookError = @import("../runtime/hook.zig").HookError;
const Op = @import("../runtime/hook.zig").Op;
const rthook = @import("../runtime/hook.zig");
const intercept = @import("../runtime/intercept.zig");
const privacy = @import("../privacy/policy.zig");
const Logger = @import("../sql/logger.zig").Logger;
const LogContext = @import("../sql/logger.zig").LogContext;
const nowUs = @import("../sql/logger.zig").nowUs;

fn mapBuildError(err: anyerror) sql_driver.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.DriverFailed,
    };
}

const FieldValue = @import("create.zig").FieldValue;

// C time() — libc is linked via build.zig
extern "c" fn time(tloc: ?*anyopaque) c_long;
const validateSqlValue = @import("create.zig").validateSqlValue;
const fillAuditUser = @import("create.zig").fillAuditUser;

fn isStringLike(comptime T: type) bool {
    return comptime switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return true;
            if (ptr.size == .one) {
                return switch (@typeInfo(ptr.child)) {
                    .array => |arr| arr.child == u8,
                    else => false,
                };
            }
            return false;
        },
        .array => |arr| arr.child == u8,
        else => false,
    };
}

/// Dialect SQL expression producing the current Unix epoch (seconds) as an
/// integer, matching zent's i64 Time representation.
fn epochExpr(dialect: anytype) []const u8 {
    const name: []const u8 = dialect.name;
    if (std.mem.eql(u8, name, "postgres")) return "EXTRACT(EPOCH FROM now())::bigint";
    if (std.mem.eql(u8, name, "mysql")) return "UNIX_TIMESTAMP()";
    return "(unixepoch())";
}

/// Copy `args` and mask values that came from `sensitive` fields (matched by
/// field name against `values`), so exec/query logs never leak secrets.
/// `value_arg_count` is how many of the leading args belong to the SET values
/// (predicate args follow).
fn maskSensitiveArgs(
    allocator: std.mem.Allocator,
    comptime info: TypeInfo,
    values: []const FieldValue,
    args: []const sql.Value,
    value_arg_count: usize,
    skip_field: ?[]const u8,
) ![]sql.Value {
    const out = try allocator.dupe(sql.Value, args);
    errdefer allocator.free(out);
    var arg_idx: usize = 0;
    for (values) |fv| {
        if (arg_idx >= value_arg_count) break;
        if (skip_field) |sf| {
            if (std.mem.eql(u8, fv.name, sf)) continue;
        }
        inline for (info.fields) |f| {
            if (std.mem.eql(u8, f.name, fv.name) and f.sensitive) {
                out[arg_idx] = .{ .string = "***" };
            }
        }
        arg_idx += 1;
    }
    return out;
}

fn canSetField(comptime Expected: type, Actual: type) bool {
    const Unwrapped = if (@typeInfo(Expected) == .optional)
        @typeInfo(Expected).optional.child
    else
        Expected;

    if (Expected == Actual) return true;
    if (Unwrapped == Actual) return true; // optional field accepts bare value
    if (Unwrapped == i64 and Actual == comptime_int) return true;
    if (Unwrapped == f64 and Actual == comptime_float) return true;
    if (Unwrapped == []const u8) {
        return switch (@typeInfo(Actual)) {
            .pointer => |ptr| {
                if (ptr.child == u8 and ptr.size == .slice) return true;
                if (ptr.size == .one) {
                    return switch (@typeInfo(ptr.child)) {
                        .array => |arr| arr.child == u8,
                        else => false,
                    };
                }
                return false;
            },
            .array => |arr| arr.child == u8,
            else => false,
        };
    }
    return false;
}

fn toSqlValue(v: anytype) sql.Value {
    const T = @TypeOf(v);
    if (T == comptime_int) return .{ .int = v };
    if (T == comptime_float) return .{ .float = v };
    return switch (@typeInfo(T)) {
        .optional => {
            if (v) |payload| return toSqlValue(payload);
            return .null;
        },
        .bool => .{ .bool = v },
        .int => .{ .int = v },
        .float => .{ .float = v },
        else => {
            if (comptime isStringLike(T)) return .{ .string = v };
            @compileError("Unsupported value type: " ++ @typeName(T));
        },
    };
}

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

fn findField(comptime info: TypeInfo, comptime name: []const u8) ?FieldInfo {
    for (info.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

/// A deferred edge write registered on an Update builder. The ids slice is
/// borrowed from the caller (matching `CreateBuilder.AddEdge`) and must stay
/// valid until `Save()`.
const EdgeAction = struct {
    op: EdgeOp,
    edge_name: []const u8,
    ids: []const i64,
};

const EdgeOp = enum {
    /// M2M: insert junction rows.
    add_ids,
    /// M2M: delete the given junction rows.
    remove_ids,
    /// O2M/O2O: point the given target rows at the matched source.
    set_ids,
    /// M2M: delete all junction rows of the matched sources.
    /// O2M/O2O: NULL the FK of target rows pointing at the matched sources.
    clear,
};

/// Build the idempotent junction insert for one target id:
///   INSERT OR IGNORE / INSERT IGNORE / INSERT
///   INTO <junction> (<source_col>, <target_col>)
///   SELECT <source_pk>, <target_id> FROM <source_table> WHERE <preds>
///
/// The source ids come from the WHERE subquery, so the statement never
/// pre-SELECTs ids or builds an IN list (no read-then-write race, no
/// parameter-count ceiling). PostgreSQL has no ignore prefix, so the
/// `ON CONFLICT DO NOTHING` clause is appended there.
fn buildM2MAddQuery(
    allocator: std.mem.Allocator,
    dialect: Dialect,
    step: graph_step.Step,
    source_table: []const u8,
    target_id: i64,
    preds: []const sql.Predicate,
) !sql.OwnedQuery {
    var ib = sql.InsertOrIgnore(allocator, dialect, step.edge_table);
    defer ib.deinit();
    _ = try ib.columns(&.{ step.sourcePK(), step.targetPK() });
    var items = [_]sql.SelectItem{
        .{ .column = step.from_column },
        .{ .value = .{ .int = target_id } },
    };
    _ = try ib.fromSelect(source_table, &items, preds);
    var q = try ib.takeQuery();
    errdefer q.deinit();
    if (std.mem.eql(u8, dialect.name, "postgres")) {
        const full = try std.fmt.allocPrint(allocator, "{s} ON CONFLICT DO NOTHING", .{q.sql});
        allocator.free(q.sql);
        q.sql = full;
    }
    return q;
}

/// DELETE the given target ids from the junction for every matched source.
fn buildM2MRemoveQuery(
    allocator: std.mem.Allocator,
    dialect: Dialect,
    step: graph_step.Step,
    source_table: []const u8,
    ids: []const i64,
    preds: []const sql.Predicate,
) !sql.OwnedQuery {
    var vals = try allocator.alloc(sql.Value, ids.len);
    defer allocator.free(vals);
    for (ids, 0..) |id, i| vals[i] = .{ .int = id };
    var db = sql.Delete(allocator, dialect, step.edge_table);
    defer db.deinit();
    _ = try db.where(sql.In(step.targetPK(), vals));
    _ = try db.where(sql.InSelect(step.sourcePK(), source_table, step.from_column, preds));
    return db.takeQuery();
}

/// DELETE every junction row whose source is matched by the update predicate.
fn buildM2MClearQuery(
    allocator: std.mem.Allocator,
    dialect: Dialect,
    step: graph_step.Step,
    source_table: []const u8,
    preds: []const sql.Predicate,
) !sql.OwnedQuery {
    var db = sql.Delete(allocator, dialect, step.edge_table);
    defer db.deinit();
    _ = try db.where(sql.InSelect(step.sourcePK(), source_table, step.from_column, preds));
    return db.takeQuery();
}

/// NULL the FK of every target row pointing at a matched source. Soft-deleted
/// targets are skipped when the target entity has soft delete enabled, so a
/// trashed row is never treated as a live association.
fn buildTargetDetachQuery(
    allocator: std.mem.Allocator,
    dialect: Dialect,
    step: graph_step.Step,
    source_table: []const u8,
    target_soft_delete: bool,
    preds: []const sql.Predicate,
) !sql.OwnedQuery {
    var ub = sql.Update(allocator, dialect, step.to_table);
    defer ub.deinit();
    _ = try ub.set(step.edge_columns[0], .null);
    _ = try ub.where(sql.InSelect(step.edge_columns[0], source_table, step.from_column, preds));
    if (target_soft_delete) _ = try ub.where(sql.IsNull("deleted_at"));
    return ub.takeQuery();
}

/// Point the given target ids at the matched source:
///   UPDATE <target> SET <fk> = (SELECT <source_pk> FROM <source> WHERE <preds>)
///   WHERE <target_pk> IN (<ids>)
///
/// The scalar subquery must resolve to exactly one source row; O2M/O2O `Set`
/// is therefore scoped to a single source (ent parity with UpdateOne).
fn buildTargetAttachQuery(
    allocator: std.mem.Allocator,
    dialect: Dialect,
    step: graph_step.Step,
    source_table: []const u8,
    target_soft_delete: bool,
    ids: []const i64,
    preds: []const sql.Predicate,
) !sql.OwnedQuery {
    var vals = try allocator.alloc(sql.Value, ids.len);
    defer allocator.free(vals);
    for (ids, 0..) |id, i| vals[i] = .{ .int = id };
    var ub = sql.Update(allocator, dialect, step.to_table);
    defer ub.deinit();
    _ = try ub.setSubquery(step.edge_columns[0], source_table, step.from_column, preds);
    _ = try ub.where(sql.In(step.to_column, vals));
    if (target_soft_delete) _ = try ub.where(sql.IsNull("deleted_at"));
    return ub.takeQuery();
}

/// Generate an Update builder for an entity.
///
/// Edge writes (`AddEdgeIDs` / `RemoveEdgeIDs` / `SetEdgeIDs` / `ClearEdge`)
/// are deferred and executed by `Save` in registration order, after the main
/// UPDATE. They are scoped by the *same* source predicate set the UPDATE uses
/// (caller `Where` + privacy filters + interceptor predicates), expressed as
/// an `IN (SELECT …)` subquery so no ids are read out first. On a
/// pool/transaction client they run on the same connection/transaction, but
/// atomicity across the main UPDATE plus the edge statements requires the
/// caller to wrap the work in `beginTx`.
pub fn UpdateBuilder(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
    const FieldExpr = struct {
        name: []const u8,
        expr: []const u8,
        args: []const sql.Value,
    };

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        driver: sql_driver.Driver,
        values: std.array_list.Managed(FieldValue),
        expr_values: std.array_list.Managed(FieldExpr),
        predicates: std.array_list.Managed(sql.Predicate),
        json_strings: std.array_list.Managed([]const u8),
        edge_actions: std.array_list.Managed(EdgeAction),
        hooks: []const Hook,
        privacy_ctx: ?privacy.PrivacyContext = null,
        /// Shared interceptor chain borrowed from the entity client.
        interceptors: ?*intercept.InterceptorChain = null,
        logger: Logger = .{},
        timeout_ms: ?u32 = null,
        execution_context: sql_driver.ExecutionContext = .{},

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver, hooks: []const Hook, privacy_ctx: ?privacy.PrivacyContext) Self {
            return .{
                .allocator = allocator,
                .driver = driver,
                .hooks = hooks,
                .privacy_ctx = privacy_ctx,
                .values = std.array_list.Managed(FieldValue).init(allocator),
                .expr_values = std.array_list.Managed(FieldExpr).init(allocator),
                .predicates = std.array_list.Managed(sql.Predicate).init(allocator),
                .json_strings = std.array_list.Managed([]const u8).init(allocator),
                .edge_actions = std.array_list.Managed(EdgeAction).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.json_strings.items) |s| self.allocator.free(s);
            self.json_strings.deinit();
            self.values.deinit();
            for (self.expr_values.items) |fe| {
                self.allocator.free(fe.expr);
                self.allocator.free(fe.args);
            }
            self.expr_values.deinit();
            self.predicates.deinit();
            self.edge_actions.deinit();
        }

        /// Set a column to an expression with bound parameters, e.g. atomic
        /// stock decrement: `setExprArgs("stock", "stock - ?", &.{ .{ .int = n } })`.
        pub fn setExprArgs(self: *Self, comptime field_name: []const u8, expr: []const u8, args: []const sql.Value) !*Self {
            comptime {
                var found = false;
                for (info.fields) |f| {
                    if (std.mem.eql(u8, f.name, field_name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) @compileError("Unknown field: " ++ field_name);
            }
            const expr_copy = try self.allocator.dupe(u8, expr);
            errdefer self.allocator.free(expr_copy);
            const args_copy = try self.allocator.dupe(sql.Value, args);
            errdefer self.allocator.free(args_copy);
            try self.expr_values.append(.{
                .name = field_name,
                .expr = expr_copy,
                .args = args_copy,
            });
            return self;
        }

        /// Set a per-query timeout in milliseconds. The deadline is computed
        /// immediately before execution and passed to the driver.
        pub fn withTimeout(self: *Self, ms: u32) *Self {
            self.timeout_ms = ms;
            return self;
        }

        fn ensureDeadline(self: *Self) void {
            if (self.timeout_ms) |ms| {
                self.execution_context.deadline_ns = sql_driver.monotonicNs() + @as(i64, ms) * std.time.ns_per_ms;
            }
        }

        /// Set a field value dynamically (no compile-time checking).
        pub fn set(self: *Self, field_name: []const u8, value: sql.Value) !*Self {
            try self.values.append(.{ .name = field_name, .value = value });
            return self;
        }

        /// Set a field value with compile-time name and type checking.
        pub fn setFieldValue(self: *Self, comptime field_name: []const u8, value: anytype) !*Self {
            comptime var needs_json = false;
            comptime {
                var found = false;
                for (info.fields) |f| {
                    if (std.mem.eql(u8, f.name, field_name)) {
                        const Expected = if (f.optional) ?f.zig_type else f.zig_type;
                        const Actual = @TypeOf(value);
                        if (!canSetField(Expected, Actual)) {
                            @compileError("Type mismatch for field '" ++ field_name ++ "': expected " ++ @typeName(Expected) ++ ", got " ++ @typeName(Actual));
                        }
                        if (f.field_type == .enum_ and f.enum_values.len > 0) {
                            const actual_info = @typeInfo(Actual);
                            if (actual_info == .array and actual_info.array.child == u8) {
                                var valid = false;
                                for (f.enum_values) |ev| {
                                    if (std.mem.eql(u8, ev, value)) valid = true;
                                }
                                if (!valid) @compileError("Invalid enum value for field '" ++ field_name ++ "': '" ++ value ++ "'");
                            }
                        }
                        if (f.field_type == .json and @typeInfo(Actual) == .@"struct") {
                            needs_json = true;
                        }
                        if (f.immutable) @compileError("Field is immutable: " ++ field_name);
                        found = true;
                        break;
                    }
                }
                if (!found) @compileError("Unknown field: " ++ field_name);
            }

            if (comptime needs_json) {
                const json_str = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
                try self.json_strings.append(json_str);
                return try self.set(field_name, .{ .string = json_str });
            }

            return try self.set(field_name, toSqlValue(value));
        }

        /// Add predicates for WHERE clause.
        pub fn Where(self: *Self, predicates: anytype) !*Self {
            const PredT = @TypeOf(predicates);
            const pred_info = @typeInfo(PredT);
            switch (pred_info) {
                .@"union" => {
                    try self.predicates.append(predicates);
                },
                .pointer => |ptr| {
                    if (ptr.size == .one and @typeInfo(ptr.child) == .@"union") {
                        try self.predicates.append(predicates.*);
                    } else if (ptr.size == .one and @typeInfo(ptr.child) == .@"struct" and @typeInfo(ptr.child).@"struct".is_tuple) {
                        inline for (predicates.*) |p| {
                            try self.predicates.append(p);
                        }
                    } else {
                        for (predicates) |p| {
                            try self.predicates.append(p);
                        }
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
                        @compileError("Where expects a predicate, tuple, array, or slice of sql.Predicate");
                    }
                },
                else => @compileError("Where expects a predicate, tuple, array, or slice of sql.Predicate"),
            }
            return self;
        }

        // ------------------------------------------------------------------
        // Edge writes
        // ------------------------------------------------------------------
        //
        // These methods register deferred statements that `Save` runs after
        // the main UPDATE, scoped to the source rows the UPDATE matched. The
        // per-edge methods are generated at comptime from `info.edges`.
        //
        // A `from` edge (the FK lives on *this* row) has no method here: set
        // the FK column directly with `setFieldValue` — an UPDATE on the row
        // already expresses detach/attach for it.

        /// M2M: add junction rows linking every matched source to each target
        /// id. Idempotent — a repeat add is a no-op (INSERT OR IGNORE /
        /// INSERT IGNORE / ON CONFLICT DO NOTHING). Empty `ids` is a no-op.
        pub fn AddEdgeIDs(self: *Self, comptime edge_name: []const u8, ids: []const i64) !*Self {
            comptime {
                const edge = findEdgeInfo(info, edge_name);
                if (edge.relation != .m2m) {
                    @compileError("AddEdgeIDs requires an M2M edge (junction/through table): " ++ edge_name ++ " on " ++ info.name);
                }
            }
            try self.edge_actions.append(.{ .op = .add_ids, .edge_name = edge_name, .ids = ids });
            return self;
        }

        /// M2M: delete junction rows linking every matched source to the
        /// given target ids. Empty `ids` is a no-op.
        pub fn RemoveEdgeIDs(self: *Self, comptime edge_name: []const u8, ids: []const i64) !*Self {
            comptime {
                const edge = findEdgeInfo(info, edge_name);
                if (edge.relation != .m2m) {
                    @compileError("RemoveEdgeIDs requires an M2M edge (junction/through table): " ++ edge_name ++ " on " ++ info.name);
                }
            }
            try self.edge_actions.append(.{ .op = .remove_ids, .edge_name = edge_name, .ids = ids });
            return self;
        }

        /// O2M/O2O (FK in the target table): point the given target ids at the
        /// matched source, detaching them from their previous owner first.
        /// Replace semantics: an empty `ids` clears the association, like
        /// `ClearEdge`.
        ///
        /// The update predicate must match exactly one source row — the attach
        /// statement resolves the source id with a scalar subquery, so a
        /// multi-row source set is rejected by PostgreSQL/MySQL rather than
        /// silently picking one (ent UpdateOne parity for bulk Update).
        pub fn SetEdgeIDs(self: *Self, comptime edge_name: []const u8, ids: []const i64) !*Self {
            comptime {
                const edge = findEdgeInfo(info, edge_name);
                if (!(edge.kind == .to and (edge.relation == .o2m or edge.relation == .o2o))) {
                    @compileError("SetEdgeIDs requires a To edge whose FK lives in the target table (o2m/o2o): " ++ edge_name ++ " on " ++ info.name);
                }
                checkDetachableFK(edge);
            }
            try self.edge_actions.append(.{ .op = .set_ids, .edge_name = edge_name, .ids = ids });
            return self;
        }

        /// M2M: delete every junction row of the matched sources.
        /// O2M/O2O: NULL the FK of target rows pointing at the matched sources.
        ///
        /// With no `Where` predicate this affects every source row, matching
        /// ent's bulk `Clear` semantics.
        pub fn ClearEdge(self: *Self, comptime edge_name: []const u8) !*Self {
            comptime {
                const edge = findEdgeInfo(info, edge_name);
                const writable = edge.relation == .m2m or
                    (edge.kind == .to and (edge.relation == .o2m or edge.relation == .o2o));
                if (!writable) {
                    @compileError("ClearEdge supports M2M and To o2m/o2o edges only; a 'from' edge stores its FK on this row — use setFieldValue to detach it: " ++ edge_name);
                }
                if (edge.relation != .m2m) checkDetachableFK(edge);
            }
            try self.edge_actions.append(.{ .op = .clear, .edge_name = edge_name, .ids = &.{} });
            return self;
        }

        /// Compile-time guard: detaching targets needs a nullable FK column.
        fn checkDetachableFK(comptime edge: EdgeInfo) void {
            const target_info = comptime findTypeInfo(infos, edge.target_name);
            const step = comptime buildEdgeStep(edge, info, target_info);
            const fk_col = step.edge_columns[0];
            if (comptime findField(target_info, fk_col)) |f| {
                if (!f.optional and !f.nillable) {
                    @compileError("Edge FK column '" ++ fk_col ++ "' on " ++ target_info.name ++ " is NOT NULL; detaching targets requires a nullable FK");
                }
            }
        }

        /// Run every registered edge write, in registration order. Each
        /// statement reuses `self.predicates` (caller `Where` + privacy +
        /// interceptor scope) as its source subquery. Soft-deleted targets are
        /// excluded from O2M/O2O FK writes; M2M junction rows are skipped for
        /// trashed targets by the read paths, not by the write.
        fn execEdgeActions(self: *Self) SaveError!void {
            if (self.edge_actions.items.len == 0) return;
            const dialect = self.driver.dialect();
            inline for (info.edges) |edge| {
                if (comptime edge.relation == .m2m) {
                    const target_info = comptime findTypeInfo(infos, edge.target_name);
                    const step = comptime buildEdgeStep(edge, info, target_info);
                    for (self.edge_actions.items) |action| {
                        if (!std.mem.eql(u8, action.edge_name, edge.name)) continue;
                        switch (action.op) {
                            .add_ids => for (action.ids) |target_id| {
                                var q = buildM2MAddQuery(self.allocator, dialect, step, info.table_name, target_id, self.predicates.items) catch |err| return mapBuildError(err);
                                defer q.deinit();
                                self.ensureDeadline();
                                _ = try self.driver.execCtx(&self.execution_context, q.sql, q.args);
                            },
                            .remove_ids => {
                                if (action.ids.len == 0) continue;
                                var q = buildM2MRemoveQuery(self.allocator, dialect, step, info.table_name, action.ids, self.predicates.items) catch |err| return mapBuildError(err);
                                defer q.deinit();
                                self.ensureDeadline();
                                _ = try self.driver.execCtx(&self.execution_context, q.sql, q.args);
                            },
                            .clear => {
                                var q = buildM2MClearQuery(self.allocator, dialect, step, info.table_name, self.predicates.items) catch |err| return mapBuildError(err);
                                defer q.deinit();
                                self.ensureDeadline();
                                _ = try self.driver.execCtx(&self.execution_context, q.sql, q.args);
                            },
                            .set_ids => unreachable,
                        }
                    }
                } else if (comptime edge.kind == .to and (edge.relation == .o2m or edge.relation == .o2o)) {
                    const target_info = comptime findTypeInfo(infos, edge.target_name);
                    const step = comptime buildEdgeStep(edge, info, target_info);
                    const target_soft_delete = target_info.soft_delete;
                    for (self.edge_actions.items) |action| {
                        if (!std.mem.eql(u8, action.edge_name, edge.name)) continue;
                        switch (action.op) {
                            .set_ids => {
                                {
                                    var dq = buildTargetDetachQuery(self.allocator, dialect, step, info.table_name, target_soft_delete, self.predicates.items) catch |err| return mapBuildError(err);
                                    defer dq.deinit();
                                    self.ensureDeadline();
                                    _ = try self.driver.execCtx(&self.execution_context, dq.sql, dq.args);
                                }
                                if (action.ids.len == 0) continue;
                                var aq = buildTargetAttachQuery(self.allocator, dialect, step, info.table_name, target_soft_delete, action.ids, self.predicates.items) catch |err| return mapBuildError(err);
                                defer aq.deinit();
                                self.ensureDeadline();
                                _ = try self.driver.execCtx(&self.execution_context, aq.sql, aq.args);
                            },
                            .clear => {
                                var q = buildTargetDetachQuery(self.allocator, dialect, step, info.table_name, target_soft_delete, self.predicates.items) catch |err| return mapBuildError(err);
                                defer q.deinit();
                                self.ensureDeadline();
                                _ = try self.driver.execCtx(&self.execution_context, q.sql, q.args);
                            },
                            .add_ids, .remove_ids => unreachable,
                        }
                    }
                }
            }
        }

        /// Run the interceptor chain (`.update`). Interceptor errors
        /// collapse to `error.InterceptFailed` to keep explicit error sets.
        fn runInterceptors(self: *Self, op: Op) error{InterceptFailed}!void {
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

        const SaveError = sql_driver.Error || HookError || error{ PrivacyDenied, ImmutableField, ValidationFailed, InterceptFailed };
        const SaveOneError = SaveError || error{ NotFound, NotSingular };

        /// Execute the UPDATE and return rows affected.
        pub fn Save(self: *Self) SaveError!usize {
            if (info.policy) |p| {
                var ctx = self.privacy_ctx orelse return error.PrivacyDenied;
                ctx.op = .update;
                const result = p.eval(ctx);
                if (result.decision == .deny) return error.PrivacyDenied;
                const filters = result.getFilters();
                for (filters) |opaque_ptr| {
                    const pred: *const sql.Predicate = @ptrCast(@alignCast(opaque_ptr));
                    try self.predicates.append(pred.*);
                }
            }
            try self.runInterceptors(.update);
            // Build mutated slice from field values for hook context.
            const mutated = try self.allocator.alloc(sql.Value, self.values.items.len);
            defer self.allocator.free(mutated);
            for (self.values.items, 0..) |fv, i| {
                mutated[i] = fv.value;
            }
            var hook_ctx = HookContext{
                .op = .update,
                .table_name = info.table_name,
                .mutated = mutated,
                .privacy = blk: {
                    var pc = self.privacy_ctx orelse privacy.PrivacyContext{};
                    pc.op = .update;
                    break :blk pc;
                },
            };
            try rthook.globalBefore(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .update) {
                    if (h.before) |f| try f(&hook_ctx);
                }
            }
            var after_hooks_fired = false;
            errdefer {
                if (!after_hooks_fired) {
                    rthook.globalAfter(&hook_ctx);
                    for (self.hooks) |h| {
                        if (h.op == .update) {
                            if (h.after) |f| f(&hook_ctx) catch |err| {
                                std.log.warn("after-hook failed on table '{s}' ({s}): {s}", .{ hook_ctx.table_name, @tagName(hook_ctx.op), @errorName(err) });
                            };
                        }
                    }
                }
            }

            for (self.values.items) |fv| {
                inline for (info.fields) |f| {
                    if (std.mem.eql(u8, f.name, fv.name)) {
                        try validateSqlValue(f, fv.value);
                        if (f.immutable) return error.ImmutableField;
                    }
                }
            }
            fillAuditUser(info, self.privacy_ctx, &self.values, true);

            const version_field: ?FieldInfo = comptime blk: {
                for (info.fields) |f| {
                    if (f.is_version) break :blk f;
                }
                break :blk null;
            };

            // If the entity has a version field and the caller supplied its
            // current value, use it for optimistic locking.
            var version_old_value: ?sql.Value = null;
            if (version_field) |vf| {
                for (self.values.items) |fv| {
                    if (std.mem.eql(u8, fv.name, vf.name)) {
                        version_old_value = fv.value;
                        break;
                    }
                }
            }
            const version_locked = version_field != null and version_old_value != null;

            var builder = sql.Update(self.allocator, self.driver.dialect(), info.table_name);
            defer builder.deinit();

            if (version_field) |vf| {
                if (version_locked) {
                    const expr = try self.allocator.alloc(u8, vf.column_name.len + 4);
                    defer self.allocator.free(expr);
                    @memcpy(expr[0..vf.column_name.len], vf.column_name);
                    @memcpy(expr[vf.column_name.len..], " + 1");
                    _ = try builder.setExpr(vf.column_name, expr);
                }

                for (self.values.items) |fv| {
                    if (version_locked and std.mem.eql(u8, fv.name, vf.name)) continue;
                    _ = try builder.set(columnName(info, fv.name), fv.value);
                }

                if (version_old_value) |v| {
                    _ = try builder.where(sql.EQ(vf.column_name, v));
                }
            } else {
                for (self.values.items) |fv| {
                    _ = try builder.set(columnName(info, fv.name), fv.value);
                }
            }

            // Auto-maintain updated_at (TimeMixin convention) unless the
            // caller set it explicitly. Uses a dialect epoch expression so
            // the stored value stays an integer (i64) like zent's Time type.
            const has_updated_at = comptime blk: {
                for (info.fields) |f| {
                    if (std.mem.eql(u8, f.name, "updated_at") and f.field_type == .time) break :blk true;
                }
                break :blk false;
            };
            if (comptime has_updated_at) {
                var explicit_updated_at = false;
                for (self.values.items) |fv| {
                    if (std.mem.eql(u8, fv.name, "updated_at")) {
                        explicit_updated_at = true;
                        break;
                    }
                }
                if (!explicit_updated_at) {
                    _ = try builder.setExpr("updated_at", epochExpr(self.driver.dialect()));
                }
            }

            for (self.expr_values.items) |fe| {
                _ = try builder.setExprArgs(columnName(info, fe.name), fe.expr, fe.args);
            }

            for (self.predicates.items) |pred| {
                _ = try builder.where(pred);
            }

            const q = builder.query() catch |err| return mapBuildError(err);
            self.ensureDeadline();
            const start = nowUs();
            const res = try self.driver.execCtx(&self.execution_context, q.sql, q.args);
            const duration_us: u64 = nowUs() - start;

            // Optimistic-lock conflict: no row was updated, so after-hooks must
            // not run. Mark them fired so the errdefer above is skipped.
            if (version_locked and res.rows_affected == 0) {
                after_hooks_fired = true;
                return error.OptimisticLockConflict;
            }

            // Edge maintenance runs after the main UPDATE (matching
            // CreateBuilder.AddEdge, which inserts junction rows before its
            // after-hooks) and is scoped by the same source predicates.
            try self.execEdgeActions();

            // After hooks on success.
            rthook.globalAfter(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .update) {
                    if (h.after) |f| f(&hook_ctx) catch |err| {
                        std.log.warn("after-hook failed on table '{s}' ({s}): {s}", .{ hook_ctx.table_name, @tagName(hook_ctx.op), @errorName(err) });
                    };
                }
            }
            after_hooks_fired = true;

            if (self.logger.onExec) |log| {
                const log_args = try maskSensitiveArgs(
                    self.allocator,
                    info,
                    self.values.items,
                    q.args,
                    self.values.items.len,
                    if (version_locked and version_field != null) version_field.?.name else null,
                );
                defer self.allocator.free(log_args);
                log(.{
                    .sql = q.sql,
                    .args = log_args,
                    .duration_us = duration_us,
                    .rows_affected = res.rows_affected,
                    .table_name = info.table_name,
                });
            }

            return res.rows_affected;
        }

        /// Execute the UPDATE and expect exactly one row to be affected.
        pub fn SaveOne(self: *Self) SaveOneError!void {
            const affected = try self.Save();
            if (affected == 0) return error.NotFound;
            if (affected > 1) return error.NotSingular;
        }
    };
}

/// Generate a Delete builder for an entity.
pub fn DeleteBuilder(comptime info: TypeInfo) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        driver: sql_driver.Driver,
        predicates: std.array_list.Managed(sql.Predicate),
        version_value: ?sql.Value,
        hooks: []const Hook,
        privacy_ctx: ?privacy.PrivacyContext = null,
        /// Shared interceptor chain borrowed from the entity client.
        interceptors: ?*intercept.InterceptorChain = null,
        logger: Logger = .{},
        timeout_ms: ?u32 = null,
        execution_context: sql_driver.ExecutionContext = .{},

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver, hooks: []const Hook, privacy_ctx: ?privacy.PrivacyContext) Self {
            return .{
                .allocator = allocator,
                .driver = driver,
                .hooks = hooks,
                .privacy_ctx = privacy_ctx,
                .predicates = std.array_list.Managed(sql.Predicate).init(allocator),
                .version_value = null,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.version_value) |v| {
                switch (v) {
                    .string => |s| self.allocator.free(s),
                    .bytes => |b| self.allocator.free(b),
                    else => {},
                }
            }
            self.predicates.deinit();
        }

        /// Set a per-query timeout in milliseconds. The deadline is computed
        /// immediately before execution and passed to the driver.
        pub fn withTimeout(self: *Self, ms: u32) *Self {
            self.timeout_ms = ms;
            return self;
        }

        fn ensureDeadline(self: *Self) void {
            if (self.timeout_ms) |ms| {
                self.execution_context.deadline_ns = sql_driver.monotonicNs() + @as(i64, ms) * std.time.ns_per_ms;
            }
        }

        /// Set the expected optimistic-lock version for the row to delete.
        /// Compile error if the entity has no `is_version` field.
        pub fn setVersion(self: *Self, value: i64) *Self {
            comptime {
                var has_version = false;
                for (info.fields) |f| {
                    if (f.is_version) {
                        has_version = true;
                        break;
                    }
                }
                if (!has_version) @compileError("Entity has no version field for optimistic locking");
            }
            self.version_value = .{ .int = value };
            return self;
        }

        /// Add predicates for WHERE clause.
        pub fn Where(self: *Self, predicates: anytype) !*Self {
            const PredT = @TypeOf(predicates);
            const pred_info = @typeInfo(PredT);
            switch (pred_info) {
                .@"union" => {
                    try self.predicates.append(predicates);
                },
                .pointer => |ptr| {
                    if (ptr.size == .one and @typeInfo(ptr.child) == .@"union") {
                        try self.predicates.append(predicates.*);
                    } else if (ptr.size == .one and @typeInfo(ptr.child) == .@"struct" and @typeInfo(ptr.child).@"struct".is_tuple) {
                        inline for (predicates.*) |p| {
                            try self.predicates.append(p);
                        }
                    } else {
                        for (predicates) |p| {
                            try self.predicates.append(p);
                        }
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
                        @compileError("Where expects a predicate, tuple, array, or slice of sql.Predicate");
                    }
                },
                else => @compileError("Where expects a predicate, tuple, array, or slice of sql.Predicate"),
            }
            return self;
        }

        /// Run the interceptor chain (`.delete`). Interceptor errors
        /// collapse to `error.InterceptFailed` to keep explicit error sets.
        fn runInterceptors(self: *Self, op: Op) error{InterceptFailed}!void {
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

        const ExecError = sql_driver.Error || HookError || error{ PrivacyDenied, InterceptFailed };
        const ExecOneError = ExecError || error{ NotFound, NotSingular };

        /// Execute the DELETE and return rows affected.
        /// If the entity has soft_delete enabled, this updates deleted_at instead.
        pub fn Exec(self: *Self) ExecError!usize {
            if (info.soft_delete) {
                return self.execSoftDelete();
            }
            return self.execHardDelete();
        }

        /// Force a hard DELETE even if soft_delete is enabled.
        pub fn ForceExec(self: *Self) ExecError!usize {
            return self.execHardDelete();
        }

        /// Execute the DELETE and expect exactly one row to be affected.
        pub fn ExecOne(self: *Self) ExecOneError!void {
            const affected = try self.Exec();
            if (affected == 0) return error.NotFound;
            if (affected > 1) return error.NotSingular;
        }

        /// Force a hard DELETE and expect exactly one row to be affected.
        pub fn ForceExecOne(self: *Self) ExecOneError!void {
            const affected = try self.ForceExec();
            if (affected == 0) return error.NotFound;
            if (affected > 1) return error.NotSingular;
        }

        /// Restore a soft-deleted row (clears `deleted_at`). Compile error
        /// unless the entity has soft_delete enabled. Returns true when a
        /// row was restored.
        pub fn Restore(self: *Self, id: i64) !bool {
            if (!info.soft_delete) @compileError("Restore requires soft_delete on the entity");
            if (info.policy) |p| {
                var ctx = self.privacy_ctx orelse return error.PrivacyDenied;
                ctx.op = .update;
                const result = p.eval(ctx);
                if (result.decision == .deny) return error.PrivacyDenied;
            }
            var builder = sql.Update(self.allocator, self.driver.dialect(), info.table_name);
            defer builder.deinit();
            _ = try builder.set("deleted_at", .null);
            _ = try builder.where(sql.EQ(pkColumn(info), .{ .int = id }));
            const q = try builder.query();
            self.ensureDeadline();
            const res = try self.driver.execCtx(&self.execution_context, q.sql, q.args);
            return res.rows_affected > 0;
        }

        fn execSoftDelete(self: *Self) ExecError!usize {
            if (info.policy) |p| {
                var ctx = self.privacy_ctx orelse return error.PrivacyDenied;
                ctx.op = .delete;
                const result = p.eval(ctx);
                if (result.decision == .deny) return error.PrivacyDenied;
                const filters = result.getFilters();
                for (filters) |opaque_ptr| {
                    const pred: *const sql.Predicate = @ptrCast(@alignCast(opaque_ptr));
                    try self.predicates.append(pred.*);
                }
            }
            try self.runInterceptors(.delete);
            var hook_ctx = HookContext{
                .op = .delete,
                .table_name = info.table_name,
                .privacy = blk: {
                    var pc = self.privacy_ctx orelse privacy.PrivacyContext{};
                    pc.op = .delete;
                    break :blk pc;
                },
            };
            try rthook.globalBefore(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .delete) {
                    if (h.before) |f| try f(&hook_ctx);
                }
            }
            var after_hooks_fired = false;
            errdefer {
                if (!after_hooks_fired) {
                    rthook.globalAfter(&hook_ctx);
                    for (self.hooks) |h| {
                        if (h.op == .delete) {
                            if (h.after) |f| f(&hook_ctx) catch |err| {
                                std.log.warn("after-hook failed on table '{s}' ({s}): {s}", .{ hook_ctx.table_name, @tagName(hook_ctx.op), @errorName(err) });
                            };
                        }
                    }
                }
            }

            const version_field: ?FieldInfo = comptime blk: {
                for (info.fields) |f| {
                    if (f.is_version) break :blk f;
                }
                break :blk null;
            };
            const version_locked = version_field != null and self.version_value != null;

            // Get current timestamp (seconds since epoch)
            const now: i64 = @intCast(time(null));
            var builder = sql.Update(self.allocator, self.driver.dialect(), info.table_name);
            defer builder.deinit();
            _ = try builder.set("deleted_at", .{ .int = now });

            if (version_field) |vf| {
                if (version_locked) {
                    const expr = try self.allocator.alloc(u8, vf.column_name.len + 4);
                    defer self.allocator.free(expr);
                    @memcpy(expr[0..vf.column_name.len], vf.column_name);
                    @memcpy(expr[vf.column_name.len..], " + 1");
                    _ = try builder.setExpr(vf.column_name, expr);
                }

                if (self.version_value) |v| {
                    _ = try builder.where(sql.EQ(vf.column_name, v));
                }
            }

            for (self.predicates.items) |pred| {
                _ = try builder.where(pred);
            }

            const q = builder.query() catch |err| return mapBuildError(err);
            self.ensureDeadline();
            const start = nowUs();
            const res = try self.driver.execCtx(&self.execution_context, q.sql, q.args);
            const duration_us: u64 = nowUs() - start;

            if (version_locked and res.rows_affected == 0) {
                after_hooks_fired = true;
                return error.OptimisticLockConflict;
            }

            // After hooks on success.
            rthook.globalAfter(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .delete) {
                    if (h.after) |f| f(&hook_ctx) catch |err| {
                        std.log.warn("after-hook failed on table '{s}' ({s}): {s}", .{ hook_ctx.table_name, @tagName(hook_ctx.op), @errorName(err) });
                    };
                }
            }
            after_hooks_fired = true;

            if (self.logger.onExec) |log| {
                log(.{
                    .sql = q.sql,
                    .args = q.args,
                    .duration_us = duration_us,
                    .rows_affected = res.rows_affected,
                    .table_name = info.table_name,
                });
            }

            return res.rows_affected;
        }

        fn execHardDelete(self: *Self) ExecError!usize {
            if (info.policy) |p| {
                var ctx = self.privacy_ctx orelse return error.PrivacyDenied;
                ctx.op = .delete;
                const result = p.eval(ctx);
                if (result.decision == .deny) return error.PrivacyDenied;
                const filters = result.getFilters();
                for (filters) |opaque_ptr| {
                    const pred: *const sql.Predicate = @ptrCast(@alignCast(opaque_ptr));
                    try self.predicates.append(pred.*);
                }
            }
            try self.runInterceptors(.delete);
            var hook_ctx = HookContext{
                .op = .delete,
                .table_name = info.table_name,
                .privacy = blk: {
                    var pc = self.privacy_ctx orelse privacy.PrivacyContext{};
                    pc.op = .delete;
                    break :blk pc;
                },
            };
            try rthook.globalBefore(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .delete) {
                    if (h.before) |f| try f(&hook_ctx);
                }
            }
            var after_hooks_fired = false;
            errdefer {
                if (!after_hooks_fired) {
                    rthook.globalAfter(&hook_ctx);
                    for (self.hooks) |h| {
                        if (h.op == .delete) {
                            if (h.after) |f| f(&hook_ctx) catch |err| {
                                std.log.warn("after-hook failed on table '{s}' ({s}): {s}", .{ hook_ctx.table_name, @tagName(hook_ctx.op), @errorName(err) });
                            };
                        }
                    }
                }
            }

            const version_field: ?FieldInfo = comptime blk: {
                for (info.fields) |f| {
                    if (f.is_version) break :blk f;
                }
                break :blk null;
            };
            const version_locked = version_field != null and self.version_value != null;

            var builder = sql.Delete(self.allocator, self.driver.dialect(), info.table_name);
            defer builder.deinit();

            if (version_field) |vf| {
                if (self.version_value) |v| {
                    _ = try builder.where(sql.EQ(vf.column_name, v));
                }
            }

            for (self.predicates.items) |pred| {
                _ = try builder.where(pred);
            }

            const q = builder.query() catch |err| return mapBuildError(err);
            self.ensureDeadline();
            const start = nowUs();
            const res = try self.driver.execCtx(&self.execution_context, q.sql, q.args);
            const duration_us: u64 = nowUs() - start;

            if (version_locked and res.rows_affected == 0) {
                after_hooks_fired = true;
                return error.OptimisticLockConflict;
            }

            // After hooks on success.
            rthook.globalAfter(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .delete) {
                    if (h.after) |f| f(&hook_ctx) catch |err| {
                        std.log.warn("after-hook failed on table '{s}' ({s}): {s}", .{ hook_ctx.table_name, @tagName(hook_ctx.op), @errorName(err) });
                    };
                }
            }
            after_hooks_fired = true;

            if (self.logger.onExec) |log| {
                log(.{
                    .sql = q.sql,
                    .args = q.args,
                    .duration_us = duration_us,
                    .rows_affected = res.rows_affected,
                    .table_name = info.table_name,
                });
            }

            return res.rows_affected;
        }
    };
}

/// Generate a Bulk Update builder for an entity.
/// Updates multiple rows in a single statement using CASE WHEN.
pub fn BulkUpdateBuilder(comptime info: TypeInfo) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        driver: sql_driver.Driver,
        b: sql.BulkUpdateBuilder,
        json_strings: std.array_list.Managed([]const u8),
        hooks: []const Hook,
        privacy_ctx: ?privacy.PrivacyContext = null,
        /// Shared interceptor chain borrowed from the entity client.
        interceptors: ?*intercept.InterceptorChain = null,
        timeout_ms: ?u32 = null,
        execution_context: sql_driver.ExecutionContext = .{},

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver, hooks: []const Hook, privacy_ctx: ?privacy.PrivacyContext) Self {
            var b = sql.BulkUpdateBuilder.init(allocator, driver.dialect(), info.table_name);
            b.id_column = pkColumn(info);
            return .{
                .allocator = allocator,
                .driver = driver,
                .hooks = hooks,
                .privacy_ctx = privacy_ctx,
                .b = b,
                .json_strings = std.array_list.Managed([]const u8).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.json_strings.items) |s| self.allocator.free(s);
            self.json_strings.deinit();
            self.b.deinit();
        }

        /// Set a per-query timeout in milliseconds. The deadline is computed
        /// immediately before execution and passed to the driver.
        pub fn withTimeout(self: *Self, ms: u32) *Self {
            self.timeout_ms = ms;
            return self;
        }

        fn ensureDeadline(self: *Self) void {
            if (self.timeout_ms) |ms| {
                self.execution_context.deadline_ns = sql_driver.monotonicNs() + @as(i64, ms) * std.time.ns_per_ms;
            }
        }

        /// Start a new row with the given id.
        pub fn Row(self: *Self, id: i64) !*Self {
            _ = try self.b.row(id);
            return self;
        }

        /// Set a field value dynamically (no compile-time checking).
        pub fn set(self: *Self, field_name: []const u8, value: sql.Value) !*Self {
            _ = try self.b.set(columnName(info, field_name), value);
            return self;
        }

        /// Set a field value with compile-time name and type checking.
        pub fn setFieldValue(self: *Self, comptime field_name: []const u8, value: anytype) !*Self {
            comptime var needs_json = false;
            comptime {
                var found = false;
                for (info.fields) |f| {
                    if (std.mem.eql(u8, f.name, field_name)) {
                        const Expected = if (f.optional) ?f.zig_type else f.zig_type;
                        const Actual = @TypeOf(value);
                        if (!canSetField(Expected, Actual)) {
                            @compileError("Type mismatch for field '" ++ field_name ++ "': expected " ++ @typeName(Expected) ++ ", got " ++ @typeName(Actual));
                        }
                        if (f.field_type == .enum_ and f.enum_values.len > 0) {
                            const actual_info = @typeInfo(Actual);
                            if (actual_info == .array and actual_info.array.child == u8) {
                                var valid = false;
                                for (f.enum_values) |ev| {
                                    if (std.mem.eql(u8, ev, value)) valid = true;
                                }
                                if (!valid) @compileError("Invalid enum value for field '" ++ field_name ++ "': '" ++ value ++ "'");
                            }
                        }
                        if (f.field_type == .json and @typeInfo(Actual) == .@"struct") {
                            needs_json = true;
                        }
                        if (f.immutable) @compileError("Field is immutable: " ++ field_name);
                        found = true;
                        break;
                    }
                }
                if (!found) @compileError("Unknown field: " ++ field_name);
            }

            if (comptime needs_json) {
                const json_str = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
                try self.json_strings.append(json_str);
                return try self.set(field_name, .{ .string = json_str });
            }

            return try self.set(field_name, toSqlValue(value));
        }

        /// Run the interceptor chain (`.update`). Interceptor errors
        /// collapse to `error.InterceptFailed` to keep explicit error sets.
        fn runInterceptors(self: *Self, op: Op) error{InterceptFailed}!void {
            const chain = self.interceptors orelse return;
            var view = intercept.QueryView{
                .op = op,
                .table_name = info.table_name,
                .sink = self,
                .add_eq_fn = addEqPredicate,
            };
            chain.run(&view) catch return error.InterceptFailed;
        }

        /// QueryView sink: add a global `field_name = value` predicate after
        /// validating the field against the entity schema.
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
            _ = try self.b.where(sql.EQ(columnName(info, field_name), value));
        }

        const SaveError = sql_driver.Error || HookError || error{ PrivacyDenied, ImmutableField, ValidationFailed, InterceptFailed };

        /// Execute the bulk UPDATE and return rows affected.
        pub fn Save(self: *Self) SaveError!usize {
            if (info.policy) |p| {
                var ctx = self.privacy_ctx orelse return error.PrivacyDenied;
                ctx.op = .update;
                const result = p.eval(ctx);
                if (result.decision == .deny) return error.PrivacyDenied;
                const filters = result.getFilters();
                for (filters) |opaque_ptr| {
                    const pred: *const sql.Predicate = @ptrCast(@alignCast(opaque_ptr));
                    try self.b.where(pred.*);
                }
            }
            try self.runInterceptors(.update);
            var hook_ctx = HookContext{
                .op = .update,
                .table_name = info.table_name,
                .privacy = blk: {
                    var pc = self.privacy_ctx orelse privacy.PrivacyContext{};
                    pc.op = .update;
                    break :blk pc;
                },
            };
            try rthook.globalBefore(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .update) {
                    if (h.before) |f| try f(&hook_ctx);
                }
            }
            errdefer {
                rthook.globalAfter(&hook_ctx);
                for (self.hooks) |h| {
                    if (h.op == .update) {
                        if (h.after) |f| f(&hook_ctx) catch |err| {
                            std.log.warn("after-hook failed on table '{s}' ({s}): {s}", .{ hook_ctx.table_name, @tagName(hook_ctx.op), @errorName(err) });
                        };
                    }
                }
            }

            if (self.b.rows.items.len == 0) return 0;

            for (self.b.rows.items) |r| {
                for (r.sets.items) |s| {
                    inline for (info.fields) |f| {
                        if (std.mem.eql(u8, f.column_name, s.column)) {
                            try validateSqlValue(f, s.value);
                            if (f.immutable) return error.ImmutableField;
                        }
                    }
                }
            }

            const q = self.b.query() catch |err| return mapBuildError(err);
            self.ensureDeadline();
            const res = try self.driver.execCtx(&self.execution_context, q.sql, q.args);

            // After hooks on success.
            rthook.globalAfter(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .update) {
                    if (h.after) |f| f(&hook_ctx) catch |err| {
                        std.log.warn("after-hook failed on table '{s}' ({s}): {s}", .{ hook_ctx.table_name, @tagName(hook_ctx.op), @errorName(err) });
                    };
                }
            }

            return res.rows_affected;
        }
    };
}

/// Generate a Bulk Delete builder for an entity.
pub fn BulkDeleteBuilder(comptime info: TypeInfo) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        driver: sql_driver.Driver,
        b: sql.BulkDeleteBuilder,
        hooks: []const Hook,
        privacy_ctx: ?privacy.PrivacyContext = null,
        /// Shared interceptor chain borrowed from the entity client.
        interceptors: ?*intercept.InterceptorChain = null,
        timeout_ms: ?u32 = null,
        execution_context: sql_driver.ExecutionContext = .{},

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver, hooks: []const Hook, privacy_ctx: ?privacy.PrivacyContext) !Self {
            return .{
                .allocator = allocator,
                .driver = driver,
                .hooks = hooks,
                .privacy_ctx = privacy_ctx,
                .b = try sql.BulkDeleteBuilder.init(allocator, driver.dialect(), info.table_name),
            };
        }

        pub fn deinit(self: *Self) void {
            self.b.deinit();
        }

        /// Set a per-query timeout in milliseconds. The deadline is computed
        /// immediately before execution and passed to the driver.
        pub fn withTimeout(self: *Self, ms: u32) *Self {
            self.timeout_ms = ms;
            return self;
        }

        fn ensureDeadline(self: *Self) void {
            if (self.timeout_ms) |ms| {
                self.execution_context.deadline_ns = sql_driver.monotonicNs() + @as(i64, ms) * std.time.ns_per_ms;
            }
        }

        /// Start a new predicate group for the next row to delete.
        pub fn Next(self: *Self) !*Self {
            _ = try self.b.next();
            return self;
        }

        /// Add predicates for the current row's WHERE clause.
        /// Groups are ORed together in the final DELETE.
        pub fn Where(self: *Self, predicates: anytype) !*Self {
            const PredT = @TypeOf(predicates);
            const pred_info = @typeInfo(PredT);
            switch (pred_info) {
                .@"union" => {
                    _ = try self.b.where(predicates);
                },
                .pointer => |ptr| {
                    if (ptr.size == .one and @typeInfo(ptr.child) == .@"union") {
                        _ = try self.b.where(predicates.*);
                    } else if (ptr.size == .one and @typeInfo(ptr.child) == .@"struct" and @typeInfo(ptr.child).@"struct".is_tuple) {
                        inline for (predicates.*) |p| {
                            _ = try self.b.where(p);
                        }
                    } else {
                        for (predicates) |p| {
                            _ = try self.b.where(p);
                        }
                    }
                },
                .array => {
                    for (predicates) |p| {
                        _ = try self.b.where(p);
                    }
                },
                .@"struct" => |s| {
                    if (s.is_tuple) {
                        inline for (predicates) |p| {
                            _ = try self.b.where(p);
                        }
                    } else {
                        @compileError("Where expects a predicate, tuple, array, or slice of sql.Predicate");
                    }
                },
                else => @compileError("Where expects a predicate, tuple, array, or slice of sql.Predicate"),
            }
            return self;
        }

        /// Run the interceptor chain (`.delete`). Interceptor errors
        /// collapse to `error.InterceptFailed` to keep explicit error sets.
        fn runInterceptors(self: *Self, op: Op) error{InterceptFailed}!void {
            const chain = self.interceptors orelse return;
            var view = intercept.QueryView{
                .op = op,
                .table_name = info.table_name,
                .sink = self,
                .add_eq_fn = addEqPredicate,
            };
            chain.run(&view) catch return error.InterceptFailed;
        }

        /// QueryView sink: add `field_name = value` to every WHERE group
        /// (groups are ORed, so the filter must AND into each one), after
        /// validating the field against the entity schema.
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
            const pred = sql.EQ(columnName(info, field_name), value);
            for (self.b.groups.items) |*group| {
                try group.append(pred);
            }
        }

        const ExecError = sql_driver.Error || HookError || error{ PrivacyDenied, InterceptFailed };

        /// Execute the bulk DELETE and return rows affected.
        pub fn Exec(self: *Self) ExecError!usize {
            if (info.soft_delete) {
                return self.execSoftDelete();
            }
            return self.execHardDelete();
        }

        /// Bulk soft delete: UPDATE deleted_at for every WHERE group (ORed),
        /// so soft_delete entities get the same batch semantics as hard
        /// delete. No hooks fire (management operation).
        fn execSoftDelete(self: *Self) ExecError!usize {
            if (info.policy) |p| {
                var ctx = self.privacy_ctx orelse return error.PrivacyDenied;
                ctx.op = .delete;
                const result = p.eval(ctx);
                if (result.decision == .deny) return error.PrivacyDenied;
            }
            try self.runInterceptors(.delete);
            if (self.b.groups.items.len == 0) return 0;

            // Each WHERE group becomes its own UPDATE (OR semantics across
            // groups); avoids pointer-based And/Or trees that would dangle.
            var total: usize = 0;
            for (self.b.groups.items) |g| {
                if (g.items.len == 0) continue;
                var builder = sql.Update(self.allocator, self.driver.dialect(), info.table_name);
                defer builder.deinit();
                _ = try builder.setExpr("deleted_at", epochExpr(self.driver.dialect()));
                for (g.items) |p| {
                    _ = try builder.where(p);
                }
                const q = builder.query() catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.ExecFailed,
                };
                self.ensureDeadline();
                const res = try self.driver.execCtx(&self.execution_context, q.sql, q.args);
                total += res.rows_affected;
            }
            return total;
        }

        fn execHardDelete(self: *Self) ExecError!usize {
            if (info.policy) |p| {
                var ctx = self.privacy_ctx orelse return error.PrivacyDenied;
                ctx.op = .delete;
                const result = p.eval(ctx);
                if (result.decision == .deny) return error.PrivacyDenied;
                const filters = result.getFilters();
                for (filters) |opaque_ptr| {
                    const pred: *const sql.Predicate = @ptrCast(@alignCast(opaque_ptr));
                    for (self.b.groups.items) |*group| {
                        try group.append(pred.*);
                    }
                }
            }
            try self.runInterceptors(.delete);
            var hook_ctx = HookContext{
                .op = .delete,
                .table_name = info.table_name,
                .privacy = blk: {
                    var pc = self.privacy_ctx orelse privacy.PrivacyContext{};
                    pc.op = .delete;
                    break :blk pc;
                },
            };
            try rthook.globalBefore(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .delete) {
                    if (h.before) |f| try f(&hook_ctx);
                }
            }
            errdefer {
                rthook.globalAfter(&hook_ctx);
                for (self.hooks) |h| {
                    if (h.op == .delete) {
                        if (h.after) |f| f(&hook_ctx) catch |err| {
                            std.log.warn("after-hook failed on table '{s}' ({s}): {s}", .{ hook_ctx.table_name, @tagName(hook_ctx.op), @errorName(err) });
                        };
                    }
                }
            }

            if (self.b.groups.items.len == 0) return 0;

            const q = self.b.query() catch |err| return mapBuildError(err);
            self.ensureDeadline();
            const res = try self.driver.execCtx(&self.execution_context, q.sql, q.args);

            // After hooks on success.
            rthook.globalAfter(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .delete) {
                    if (h.after) |f| f(&hook_ctx) catch |err| {
                        std.log.warn("after-hook failed on table '{s}' ({s}): {s}", .{ hook_ctx.table_name, @tagName(hook_ctx.op), @errorName(err) });
                    };
                }
            }

            return res.rows_affected;
        }
    };
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Update builder basic" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const Upd = UpdateBuilder(&.{info}, info);

    var u = Upd.init(std.testing.allocator, undefined, &.{}, null);
    defer u.deinit();

    const bob: []const u8 = "bob";
    _ = try u.setFieldValue("name", bob);
    try std.testing.expectEqual(@as(usize, 1), u.values.items.len);

    _ = try u.Where(.{sql.EQ("id", .{ .int = 1 })});
    try std.testing.expectEqual(@as(usize, 1), u.predicates.items.len);
}

test "Delete builder basic" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const Del = DeleteBuilder(info);

    var d = Del.init(std.testing.allocator, undefined, &.{}, null);
    defer d.deinit();

    _ = try d.Where(.{sql.EQ("id", .{ .int = 1 })});
    try std.testing.expectEqual(@as(usize, 1), d.predicates.items.len);
}

test "Update builder SaveOne and Delete builder ExecOne compile" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const Upd = UpdateBuilder(&.{info}, info);
    const Del = DeleteBuilder(info);

    var u = Upd.init(std.testing.allocator, undefined, &.{}, null);
    defer u.deinit();
    const bob: []const u8 = "bob";
    _ = try u.setFieldValue("name", bob);
    _ = try u.Where(.{sql.EQ("id", .{ .int = 1 })});

    var d = Del.init(std.testing.allocator, undefined, &.{}, null);
    defer d.deinit();
    _ = try d.Where(.{sql.EQ("id", .{ .int = 1 })});

    // Compilation check only; actual execution requires a real driver.
    try std.testing.expectEqual(@as(usize, 1), u.values.items.len);
    try std.testing.expectEqual(@as(usize, 1), d.predicates.items.len);
}

test "BulkUpdate builder basic" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const BulkUpd = BulkUpdateBuilder(info);

    var driver = try @import("../sql/sqlite.zig").SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer driver.close();
    var u = BulkUpd.init(std.testing.allocator, driver.asDriver(), &.{}, null);
    defer u.deinit();

    _ = try u.Row(1);
    const alice: []const u8 = "alice";
    const bob: []const u8 = "bob";
    _ = try u.setFieldValue("name", alice);
    _ = try u.setFieldValue("age", 31);
    _ = try u.Row(2);
    _ = try u.setFieldValue("name", bob);

    try std.testing.expectEqual(@as(usize, 2), u.b.rows.items.len);
    try std.testing.expectEqual(@as(i64, 1), u.b.rows.items[0].id);
    try std.testing.expectEqual(@as(i64, 2), u.b.rows.items[1].id);
    try std.testing.expectEqual(@as(usize, 2), u.b.rows.items[0].sets.items.len);
    try std.testing.expectEqual(@as(usize, 1), u.b.rows.items[1].sets.items.len);
}

test "BulkDelete builder basic" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const BulkDel = BulkDeleteBuilder(info);

    var driver = try @import("../sql/sqlite.zig").SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer driver.close();
    var d = try BulkDel.init(std.testing.allocator, driver.asDriver(), &.{}, null);
    defer d.deinit();

    _ = try d.Where(.{sql.EQ("id", .{ .int = 1 })});
    _ = try d.Next();
    _ = try d.Where(.{sql.EQ("id", .{ .int = 2 })});

    try std.testing.expectEqual(@as(usize, 2), d.b.groups.items.len);
    try std.testing.expectEqual(@as(usize, 1), d.b.groups.items[0].items.len);
    try std.testing.expectEqual(@as(usize, 1), d.b.groups.items[1].items.len);
}

test "Update and delete execution methods expose explicit driver error unions" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const Upd = UpdateBuilder(&.{info}, info);
    const Del = DeleteBuilder(info);
    const BulkUpd = BulkUpdateBuilder(info);
    const BulkDel = BulkDeleteBuilder(info);
    const SaveError = sql_driver.Error || HookError || error{ PrivacyDenied, ImmutableField, ValidationFailed, InterceptFailed };
    const SaveOneError = SaveError || error{ NotFound, NotSingular };
    const ExecError = sql_driver.Error || HookError || error{ PrivacyDenied, InterceptFailed };
    const ExecOneError = ExecError || error{ NotFound, NotSingular };

    comptime {
        if (@typeInfo(@typeInfo(@TypeOf(Upd.Save)).@"fn".return_type.?).error_union.error_set != SaveError) @compileError("Update.Save error set is not explicit");
        if (@typeInfo(@typeInfo(@TypeOf(Upd.SaveOne)).@"fn".return_type.?).error_union.error_set != SaveOneError) @compileError("Update.SaveOne error set is not explicit");
        if (@typeInfo(@typeInfo(@TypeOf(Del.Exec)).@"fn".return_type.?).error_union.error_set != ExecError) @compileError("Delete.Exec error set is not explicit");
        if (@typeInfo(@typeInfo(@TypeOf(Del.ForceExec)).@"fn".return_type.?).error_union.error_set != ExecError) @compileError("Delete.ForceExec error set is not explicit");
        if (@typeInfo(@typeInfo(@TypeOf(Del.ExecOne)).@"fn".return_type.?).error_union.error_set != ExecOneError) @compileError("Delete.ExecOne error set is not explicit");
        if (@typeInfo(@typeInfo(@TypeOf(Del.ForceExecOne)).@"fn".return_type.?).error_union.error_set != ExecOneError) @compileError("Delete.ForceExecOne error set is not explicit");
        if (@typeInfo(@typeInfo(@TypeOf(BulkUpd.Save)).@"fn".return_type.?).error_union.error_set != SaveError) @compileError("BulkUpdate.Save error set is not explicit");
        if (@typeInfo(@typeInfo(@TypeOf(BulkDel.Exec)).@"fn".return_type.?).error_union.error_set != ExecError) @compileError("BulkDelete.Exec error set is not explicit");
    }
}

test "setExprArgs atomic stock decrement prevents oversell" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const migrate = @import("../sql/schema/migrate.zig");
    const sqlite_driver = @import("../sql/sqlite.zig");
    const client_mod = @import("client.zig");
    const deinitEntity = @import("entity.zig").deinitEntity;

    const Sku = Schema("Sku", .{
        .fields = &.{
            field.Int("stock"),
            field.Version("version"),
        },
    });
    const info = comptime fromSchema(Sku);
    const infos = &[_]TypeInfo{info};

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);

    const EntityClient = client_mod.EntityClient(infos, info);
    const client = EntityClient.init(allocator, driver.asDriver());

    // Seed stock = 10.
    {
        var b = try client.Create();
        defer b.deinit();
        _ = try b.setFieldValue("stock", @as(i64, 10));
        var row = try b.Save();
        defer deinitEntity(infos, info, &row, allocator);
    }

    const preds = client.predicates;

    // Atomic decrement: SET stock = stock - ? WHERE id = ? AND stock >= ?.
    {
        var u = client.Update();
        defer u.deinit();
        _ = try u.setExprArgs("stock", "stock - ?", &.{.{ .int = 3 }});
        _ = try u.Where(.{ preds.idEQ(.{ .int = 1 }), preds.stockGTE(.{ .int = 3 }) });
        try std.testing.expectEqual(@as(usize, 1), try u.Save());
    }

    // Second decrement of 5 succeeds (7 >= 5).
    {
        var u = client.Update();
        defer u.deinit();
        _ = try u.setExprArgs("stock", "stock - ?", &.{.{ .int = 5 }});
        _ = try u.Where(.{ preds.idEQ(.{ .int = 1 }), preds.stockGTE(.{ .int = 5 }) });
        try std.testing.expectEqual(@as(usize, 1), try u.Save());
    }

    // Oversell attempt: stock 2 < 3 -> 0 rows affected, stock unchanged.
    {
        var u = client.Update();
        defer u.deinit();
        _ = try u.setExprArgs("stock", "stock - ?", &.{.{ .int = 3 }});
        _ = try u.Where(.{ preds.idEQ(.{ .int = 1 }), preds.stockGTE(.{ .int = 3 }) });
        try std.testing.expectEqual(@as(usize, 0), try u.Save());
    }

    var q = client.Query();
    defer q.deinit();
    _ = try q.Where(.{preds.idEQ(.{ .int = 1 })});
    var found = try q.All();
    defer {
        for (found.items) |*e| deinitEntity(infos, info, e, allocator);
        found.deinit();
    }
    try std.testing.expectEqual(@as(i64, 2), found.items[0].stock);
}

test "setExprArgs with clamping expression (GREATEST-style floor at zero)" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const migrate = @import("../sql/schema/migrate.zig");
    const sqlite_driver = @import("../sql/sqlite.zig");
    const client_mod = @import("client.zig");
    const deinitEntity = @import("entity.zig").deinitEntity;

    const Sku = Schema("SkuClamp", .{
        .fields = &.{field.Int("stock")},
    });
    const info = comptime fromSchema(Sku);
    const infos = &[_]TypeInfo{info};

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);

    const EntityClient = client_mod.EntityClient(infos, info);
    const client = EntityClient.init(allocator, driver.asDriver());

    {
        var b = try client.Create();
        defer b.deinit();
        _ = try b.setFieldValue("stock", @as(i64, 4));
        var row = try b.Save();
        defer deinitEntity(infos, info, &row, allocator);
    }

    const preds = client.predicates;

    // SQLite spells GREATEST as the multi-arg max() scalar; MySQL/PG use
    // GREATEST(num - ?, 0) — the fluent shape is identical across dialects.
    {
        var u = client.Update();
        defer u.deinit();
        _ = try u.setExprArgs("stock", "MAX(stock - ?, 0)", &.{.{ .int = 10 }});
        _ = try u.Where(.{preds.idEQ(.{ .int = 1 })});
        try std.testing.expectEqual(@as(usize, 1), try u.Save());
    }

    var q = client.Query();
    defer q.deinit();
    var found = try q.All();
    defer {
        for (found.items) |*e| deinitEntity(infos, info, e, allocator);
        found.deinit();
    }
    // Decrement of 10 against stock 4 clamps at 0 instead of going negative.
    try std.testing.expectEqual(@as(i64, 0), found.items[0].stock);
}

test "maskSensitiveArgs masks sensitive field values in logs" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = Schema("User9", .{
        .fields = &.{
            field.String("name"),
            field.String("api_key").Sensitive(),
        },
    });
    const info = comptime fromSchema(User);
    const values = [_]FieldValue{
        .{ .name = "api_key", .value = .{ .string = "sk-secret" } },
        .{ .name = "name", .value = .{ .string = "alice" } },
    };
    const args = [_]sql.Value{
        .{ .string = "sk-secret" },
        .{ .string = "alice" },
        .{ .int = 7 },
    };
    const masked = try maskSensitiveArgs(allocator, info, &values, &args, 2, null);
    defer allocator.free(masked);
    try std.testing.expectEqualStrings("***", masked[0].string);
    try std.testing.expectEqualStrings("alice", masked[1].string);
    try std.testing.expectEqual(@as(i64, 7), masked[2].int);
}

test "AuditMixin auto-fills created_by/updated_by from privacy context" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const migrate = @import("../sql/schema/migrate.zig");
    const sqlite_driver = @import("../sql/sqlite.zig");
    const client_mod = @import("client.zig");
    const deinitEntity = @import("entity.zig").deinitEntity;
    const AuditMixin = @import("../core/mixin.zig").AuditMixin;

    const Note = Schema("NoteAudit", .{
        .fields = &.{field.String("body")},
        .mixins = &.{AuditMixin},
    });
    const info = comptime fromSchema(Note);
    const infos = &[_]TypeInfo{info};

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);
    const base = client_mod.EntityClient(infos, info).init(allocator, driver.asDriver());
    const preds = base.predicates;

    const note_id = id: {
        const client = base.withContext(.{ .user_id = 7 });
        var b = try client.Create();
        defer b.deinit();
        _ = try b.setFieldValue("body", "hello");
        var row = try b.Save();
        defer deinitEntity(infos, info, &row, allocator);
        try std.testing.expectEqual(@as(?i64, 7), row.created_by);
        try std.testing.expectEqual(@as(?i64, 7), row.updated_by);
        break :id row.id;
    };

    const client9 = base.withContext(.{ .user_id = 9 });
    {
        var u = client9.Update();
        defer u.deinit();
        _ = try u.setFieldValue("body", "hello2");
        _ = try u.Where(.{preds.idEQ(.{ .int = note_id })});
        try std.testing.expectEqual(@as(usize, 1), try u.Save());
    }

    var q = base.Query();
    defer q.deinit();
    _ = try q.Where(.{preds.idEQ(.{ .int = note_id })});
    var rows = try q.All();
    defer {
        for (rows.items) |*e| deinitEntity(infos, info, e, allocator);
        rows.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqual(@as(?i64, 7), rows.items[0].created_by);
    try std.testing.expectEqual(@as(?i64, 9), rows.items[0].updated_by);
}

test "soft-delete restore brings the row back" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const migrate = @import("../sql/schema/migrate.zig");
    const sqlite_driver = @import("../sql/sqlite.zig");
    const client_mod = @import("client.zig");
    const deinitEntity = @import("entity.zig").deinitEntity;

    const Post = Schema("PostSoft", .{
        .fields = &.{field.String("title")},
        .mixins = &.{@import("../core/mixin.zig").SoftDeleteMixin},
        .soft_delete = true,
    });
    const info = comptime fromSchema(Post);
    const infos = &[_]TypeInfo{info};

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);
    const client = client_mod.EntityClient(infos, info).init(allocator, driver.asDriver());
    const preds = client.predicates;

    const post_id = id: {
        var b = try client.Create();
        defer b.deinit();
        _ = try b.setFieldValue("title", "hello");
        var row = try b.Save();
        defer deinitEntity(infos, info, &row, allocator);
        break :id row.id;
    };

    // Soft delete.
    {
        var d = client.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.idEQ(.{ .int = post_id })});
        try std.testing.expectEqual(@as(usize, 1), try d.Exec());
    }
    // Hidden from normal queries.
    {
        var q = client.Query();
        defer q.deinit();
        var rows = try q.All();
        defer {
            for (rows.items) |*e| deinitEntity(infos, info, e, allocator);
            rows.deinit();
        }
        try std.testing.expectEqual(@as(usize, 0), rows.items.len);
    }
    // Visible with WithTrashed.
    {
        var q = client.Query();
        defer q.deinit();
        _ = q.WithTrashed();
        var rows = try q.All();
        defer {
            for (rows.items) |*e| deinitEntity(infos, info, e, allocator);
            rows.deinit();
        }
        try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    }
    // Restore brings it back.
    {
        var d = client.Delete();
        defer d.deinit();
        try std.testing.expect(try d.Restore(post_id));
    }
    {
        var q = client.Query();
        defer q.deinit();
        var rows = try q.All();
        defer {
            for (rows.items) |*e| deinitEntity(infos, info, e, allocator);
            rows.deinit();
        }
        try std.testing.expectEqual(@as(usize, 1), rows.items.len);
        try std.testing.expectEqualStrings("hello", rows.items[0].title);
    }
}

test "BulkDelete soft_delete performs bulk soft delete" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const migrate = @import("../sql/schema/migrate.zig");
    const sqlite_driver = @import("../sql/sqlite.zig");
    const client_mod = @import("client.zig");
    const deinitEntity = @import("entity.zig").deinitEntity;

    const Post = Schema("PostSoftBulk", .{
        .fields = &.{field.String("title")},
        .mixins = &.{@import("../core/mixin.zig").SoftDeleteMixin},
        .soft_delete = true,
    });
    const info = comptime fromSchema(Post);
    const infos = &[_]TypeInfo{info};

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);
    const client = client_mod.EntityClient(infos, info).init(allocator, driver.asDriver());
    const preds = client.predicates;

    var ids: [3]i64 = undefined;
    for (&ids) |*out| {
        var b = try client.Create();
        defer b.deinit();
        _ = try b.setFieldValue("title", "t");
        var row = try b.Save();
        defer deinitEntity(infos, info, &row, allocator);
        out.* = row.id;
    }

    var d = try BulkDeleteBuilder(info).init(allocator, driver.asDriver(), &.{}, null);
    defer d.deinit();
    for (ids) |id| {
        _ = try d.Next();
        _ = try d.Where(.{preds.idEQ(.{ .int = id })});
    }
    try std.testing.expectEqual(@as(usize, 3), try d.Exec());

    // All rows hidden from normal queries, visible with trashed.
    {
        var q = client.Query();
        defer q.deinit();
        var rows = try q.All();
        defer {
            for (rows.items) |*e| deinitEntity(infos, info, e, allocator);
            rows.deinit();
        }
        try std.testing.expectEqual(@as(usize, 0), rows.items.len);
    }
    {
        var q = client.Query();
        defer q.deinit();
        _ = q.WithTrashed();
        var rows = try q.All();
        defer {
            for (rows.items) |*e| deinitEntity(infos, info, e, allocator);
            rows.deinit();
        }
        try std.testing.expectEqual(@as(usize, 3), rows.items.len);
    }
}

test "updated_at auto-maintained by UpdateBuilder (TimeMixin)" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const migrate = @import("../sql/schema/migrate.zig");
    const sqlite_driver = @import("../sql/sqlite.zig");
    const client_mod = @import("client.zig");
    const deinitEntity = @import("entity.zig").deinitEntity;
    const TimeMixin = @import("../core/mixin.zig").TimeMixin;

    const Note = Schema("Note", .{
        .fields = &.{
            field.String("body"),
        },
        .mixins = &.{TimeMixin},
    });
    const info = comptime fromSchema(Note);
    const infos = &[_]TypeInfo{info};

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);

    const EntityClient = client_mod.EntityClient(infos, info);
    const client = EntityClient.init(allocator, driver.asDriver());
    const preds = client.predicates;

    // Create without timestamps: DB default fills created_at/updated_at.
    const note_id = id: {
        var b = try client.Create();
        defer b.deinit();
        _ = try b.setFieldValue("body", "hello");
        var row = try b.Save();
        defer deinitEntity(infos, info, &row, allocator);
        break :id row.id;
    };
    var q1 = client.Query();
    defer q1.deinit();
    var after_create = (try q1.First()) orelse return error.NoRow;
    defer deinitEntity(infos, info, &after_create, allocator);
    try std.testing.expect(after_create.created_at != null);
    const created_ms = after_create.created_at.?;

    // Update without touching updated_at: auto-refresh.
    {
        var u = client.Update();
        defer u.deinit();
        _ = try u.setFieldValue("body", "hello2");
        _ = try u.Where(.{preds.idEQ(.{ .int = note_id })});
        try std.testing.expectEqual(@as(usize, 1), try u.Save());
    }
    var q2 = client.Query();
    defer q2.deinit();
    var after_update = (try q2.First()) orelse return error.NoRow;
    defer deinitEntity(infos, info, &after_update, allocator);
    try std.testing.expect(after_update.updated_at != null);
    try std.testing.expect(after_update.updated_at.? >= created_ms);

    // Explicit updated_at wins over the auto-maintenance.
    {
        var u = client.Update();
        defer u.deinit();
        _ = try u.setFieldValue("body", "hello3");
        _ = try u.setFieldValue("updated_at", @as(i64, 42));
        _ = try u.Where(.{preds.idEQ(.{ .int = note_id })});
        try std.testing.expectEqual(@as(usize, 1), try u.Save());
    }
    var q3 = client.Query();
    defer q3.deinit();
    var after_explicit = (try q3.First()) orelse return error.NoRow;
    defer deinitEntity(infos, info, &after_explicit, allocator);
    try std.testing.expectEqual(@as(?i64, 42), after_explicit.updated_at);
}

// ------------------------------------------------------------------
// Edge write tests
// ------------------------------------------------------------------

const m2m_test_step = graph_step.Step{
    .from_table = "user",
    .from_column = "id",
    .to_table = "group",
    .to_column = "id",
    .edge_rel = .m2m,
    .edge_table = "user_group",
    .edge_columns = &[_][]const u8{ "group_id", "user_id" },
    .inverse = false,
};

const o2m_test_step = graph_step.Step{
    .from_table = "user",
    .from_column = "id",
    .to_table = "car",
    .to_column = "id",
    .edge_rel = .o2m,
    .edge_table = "car",
    .edge_columns = &[_][]const u8{"owner_id"},
    .inverse = false,
};

test "edge write SQL shape: M2M add is idempotent per dialect" {
    const allocator = std.testing.allocator;
    const preds = [_]sql.Predicate{sql.EQ("id", .{ .int = 1 })};

    {
        var q = try buildM2MAddQuery(allocator, Dialect.sqlite, m2m_test_step, "user", 9, &preds);
        defer q.deinit();
        try std.testing.expectEqualStrings(
            "INSERT OR IGNORE INTO \"user_group\" (\"user_id\", \"group_id\") SELECT \"id\", ? FROM \"user\" WHERE \"id\" = ?",
            q.sql,
        );
        try std.testing.expectEqual(@as(usize, 2), q.args.len);
        try std.testing.expectEqual(@as(i64, 9), q.args[0].int);
        try std.testing.expectEqual(@as(i64, 1), q.args[1].int);
    }
    {
        var q = try buildM2MAddQuery(allocator, Dialect.postgres, m2m_test_step, "user", 9, &preds);
        defer q.deinit();
        try std.testing.expectEqualStrings(
            "INSERT INTO \"user_group\" (\"user_id\", \"group_id\") SELECT \"id\", $1 FROM \"user\" WHERE \"id\" = $2 ON CONFLICT DO NOTHING",
            q.sql,
        );
    }
    {
        var q = try buildM2MAddQuery(allocator, Dialect.mysql, m2m_test_step, "user", 9, &preds);
        defer q.deinit();
        try std.testing.expectEqualStrings(
            "INSERT IGNORE INTO `user_group` (`user_id`, `group_id`) SELECT `id`, ? FROM `user` WHERE `id` = ?",
            q.sql,
        );
    }
}

test "edge write SQL shape: M2M remove and clear scope by source subquery" {
    const allocator = std.testing.allocator;
    const preds = [_]sql.Predicate{sql.EQ("id", .{ .int = 1 })};

    {
        var q = try buildM2MRemoveQuery(allocator, Dialect.sqlite, m2m_test_step, "user", &.{ 2, 3 }, &preds);
        defer q.deinit();
        try std.testing.expectEqualStrings(
            "DELETE FROM \"user_group\" WHERE \"group_id\" IN (?, ?) AND \"user_id\" IN (SELECT \"id\" FROM \"user\" WHERE \"id\" = ?)",
            q.sql,
        );
        try std.testing.expectEqual(@as(usize, 3), q.args.len);
    }
    {
        var q = try buildM2MClearQuery(allocator, Dialect.postgres, m2m_test_step, "user", &preds);
        defer q.deinit();
        try std.testing.expectEqualStrings(
            "DELETE FROM \"user_group\" WHERE \"user_id\" IN (SELECT \"id\" FROM \"user\" WHERE \"id\" = $1)",
            q.sql,
        );
    }
}

test "edge write SQL shape: O2M detach and attach" {
    const allocator = std.testing.allocator;
    const preds = [_]sql.Predicate{sql.EQ("id", .{ .int = 1 })};

    {
        var q = try buildTargetDetachQuery(allocator, Dialect.sqlite, o2m_test_step, "user", false, &preds);
        defer q.deinit();
        try std.testing.expectEqualStrings(
            "UPDATE \"car\" SET \"owner_id\" = ? WHERE \"owner_id\" IN (SELECT \"id\" FROM \"user\" WHERE \"id\" = ?)",
            q.sql,
        );
    }
    {
        var q = try buildTargetDetachQuery(allocator, Dialect.sqlite, o2m_test_step, "user", true, &preds);
        defer q.deinit();
        try std.testing.expectEqualStrings(
            "UPDATE \"car\" SET \"owner_id\" = ? WHERE \"owner_id\" IN (SELECT \"id\" FROM \"user\" WHERE \"id\" = ?) AND \"deleted_at\" IS NULL",
            q.sql,
        );
    }
    {
        var q = try buildTargetAttachQuery(allocator, Dialect.postgres, o2m_test_step, "user", false, &.{ 5, 6 }, &preds);
        defer q.deinit();
        try std.testing.expectEqualStrings(
            "UPDATE \"car\" SET \"owner_id\" = (SELECT \"id\" FROM \"user\" WHERE \"id\" = $1) WHERE \"id\" IN ($2, $3)",
            q.sql,
        );
    }
}

test "UpdateBuilder registers edge writes and reuses source predicates" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const edge_mod = @import("../core/edge.zig");
    const buildGraph = @import("graph.zig").buildGraph;

    const CarBase = schema("EwCar", .{
        .fields = &.{ field.String("model"), field.Int("owner_id").Optional() },
    });
    const GroupBase = schema("EwGroup", .{
        .fields = &.{field.String("name")},
    });
    const UserBase = schema("EwUser", .{
        .fields = &.{field.String("name")},
    });
    const Car = struct {
        pub const schema_name = CarBase.schema_name;
        pub const fields = CarBase.fields;
        pub const edges = &.{edge_mod.From("owner", UserBase).Ref("cars")};
        pub const indexes = CarBase.indexes;
    };
    const Group = struct {
        pub const schema_name = GroupBase.schema_name;
        pub const fields = GroupBase.fields;
        pub const edges = &.{edge_mod.To("users", UserBase)};
        pub const indexes = GroupBase.indexes;
    };
    const User = struct {
        pub const schema_name = UserBase.schema_name;
        pub const fields = UserBase.fields;
        pub const edges = &.{ edge_mod.To("cars", CarBase), edge_mod.To("groups", GroupBase) };
        pub const indexes = UserBase.indexes;
    };

    const graph = comptime buildGraph(&.{ User, Car, Group });
    const infos = graph.types;
    const user_info = comptime findTypeInfo(infos, "EwUser");
    const Upd = UpdateBuilder(infos, user_info);

    var u = Upd.init(std.testing.allocator, undefined, &.{}, null);
    defer u.deinit();

    _ = try u.AddEdgeIDs("groups", &.{1});
    _ = try u.RemoveEdgeIDs("groups", &.{2});
    _ = try u.ClearEdge("groups");
    _ = try u.SetEdgeIDs("cars", &.{3});
    _ = try u.ClearEdge("cars");
    try std.testing.expectEqual(@as(usize, 5), u.edge_actions.items.len);
    try std.testing.expectEqual(EdgeOp.add_ids, u.edge_actions.items[0].op);
    try std.testing.expectEqual(EdgeOp.set_ids, u.edge_actions.items[3].op);
}
