const std = @import("std");
const TypeInfo = @import("graph.zig").TypeInfo;
const FieldInfo = @import("graph.zig").FieldInfo;
const sql = @import("../sql/builder.zig");
const sql_driver = @import("../sql/driver.zig");
const Dialect = @import("../sql/dialect.zig").Dialect;
const Hook = @import("../runtime/hook.zig").Hook;
const HookContext = @import("../runtime/hook.zig").HookContext;
const HookError = @import("../runtime/hook.zig").HookError;
const Op = @import("../runtime/hook.zig").Op;
const rthook = @import("../runtime/hook.zig");
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

/// Generate an Update builder for an entity.
pub fn UpdateBuilder(comptime info: TypeInfo) type {
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
        hooks: []const Hook,
        privacy_ctx: ?privacy.PrivacyContext = null,
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

        const SaveError = sql_driver.Error || HookError || error{ PrivacyDenied, ImmutableField, ValidationFailed };
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
                    const expr = try self.allocator.alloc(u8, vf.name.len + 4);
                    defer self.allocator.free(expr);
                    @memcpy(expr[0..vf.name.len], vf.name);
                    @memcpy(expr[vf.name.len..], " + 1");
                    _ = try builder.setExpr(vf.name, expr);
                }

                for (self.values.items) |fv| {
                    if (version_locked and std.mem.eql(u8, fv.name, vf.name)) continue;
                    _ = try builder.set(fv.name, fv.value);
                }

                if (version_old_value) |v| {
                    _ = try builder.where(sql.EQ(vf.name, v));
                }
            } else {
                for (self.values.items) |fv| {
                    _ = try builder.set(fv.name, fv.value);
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
                _ = try builder.setExprArgs(fe.name, fe.expr, fe.args);
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

        const ExecError = sql_driver.Error || HookError || error{PrivacyDenied};
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
            _ = try builder.where(sql.EQ(info.pk_field, .{ .int = id }));
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
                    const expr = try self.allocator.alloc(u8, vf.name.len + 4);
                    defer self.allocator.free(expr);
                    @memcpy(expr[0..vf.name.len], vf.name);
                    @memcpy(expr[vf.name.len..], " + 1");
                    _ = try builder.setExpr(vf.name, expr);
                }

                if (self.version_value) |v| {
                    _ = try builder.where(sql.EQ(vf.name, v));
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
                    _ = try builder.where(sql.EQ(vf.name, v));
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
        timeout_ms: ?u32 = null,
        execution_context: sql_driver.ExecutionContext = .{},

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver, hooks: []const Hook, privacy_ctx: ?privacy.PrivacyContext) Self {
            return .{
                .allocator = allocator,
                .driver = driver,
                .hooks = hooks,
                .privacy_ctx = privacy_ctx,
                .b = sql.BulkUpdateBuilder.init(allocator, driver.dialect(), info.table_name),
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
            _ = try self.b.set(field_name, value);
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

        const SaveError = sql_driver.Error || HookError || error{ PrivacyDenied, ImmutableField, ValidationFailed };

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
                        if (std.mem.eql(u8, f.name, s.column)) {
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

        const ExecError = sql_driver.Error || HookError || error{PrivacyDenied};

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
    const Upd = UpdateBuilder(info);

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
    const Upd = UpdateBuilder(info);
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
    const Upd = UpdateBuilder(info);
    const Del = DeleteBuilder(info);
    const BulkUpd = BulkUpdateBuilder(info);
    const BulkDel = BulkDeleteBuilder(info);
    const SaveError = sql_driver.Error || HookError || error{ PrivacyDenied, ImmutableField, ValidationFailed };
    const SaveOneError = SaveError || error{ NotFound, NotSingular };
    const ExecError = sql_driver.Error || HookError || error{PrivacyDenied};
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
