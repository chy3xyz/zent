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

fn isStringLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
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

fn canSetField(comptime Expected: type, Actual: type) bool {
    const Unwrapped = if (@typeInfo(Expected) == .optional)
        @typeInfo(Expected).optional.child
    else
        Expected;

    if (Expected == Actual) return true;
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
        .bool => .{ .bool = v },
        .int => .{ .int = v },
        .float => .{ .float = v },
        else => {
            if (isStringLike(T)) return .{ .string = v };
            @compileError("Unsupported value type: " ++ @typeName(T));
        },
    };
}

/// Generate an Update builder for an entity.
pub fn UpdateBuilder(comptime info: TypeInfo) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        driver: sql_driver.Driver,
        values: std.array_list.Managed(FieldValue),
        predicates: std.array_list.Managed(sql.Predicate),
        json_strings: std.array_list.Managed([]const u8),
        hooks: []const Hook,
        privacy_ctx: ?privacy.PrivacyContext = null,
        logger: Logger = .{},

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver, hooks: []const Hook, privacy_ctx: ?privacy.PrivacyContext) Self {
            return .{
                .allocator = allocator,
                .driver = driver,
                .hooks = hooks,
                .privacy_ctx = privacy_ctx,
                .values = std.array_list.Managed(FieldValue).init(allocator),
                .predicates = std.array_list.Managed(sql.Predicate).init(allocator),
                .json_strings = std.array_list.Managed([]const u8).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.json_strings.items) |s| self.allocator.free(s);
            self.json_strings.deinit();
            self.values.deinit();
            self.predicates.deinit();
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
                        const Expected = f.zig_type;
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

        const SaveError = sql_driver.Error || HookError || error{ PrivacyDenied, ImmutableField, ValidationFailed };
        const SaveOneError = SaveError || error{ NotFound, NotSingular };

        /// Execute the UPDATE and return rows affected.
        pub fn Save(self: *Self) SaveError!usize {
            if (info.policy) |p| {
                const ctx = self.privacy_ctx orelse return error.PrivacyDenied;
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
                .privacy = self.privacy_ctx orelse .{},
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
                        if (h.after) |f| f(&hook_ctx) catch {};
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

            var builder = sql.Update(self.allocator, self.driver.dialect(), info.table_name);
            defer builder.deinit();

            for (self.values.items) |fv| {
                _ = try builder.set(fv.name, fv.value);
            }

            for (self.predicates.items) |pred| {
                _ = try builder.where(pred);
            }

            const q = builder.query() catch |err| return mapBuildError(err);
            const start = nowUs();
            const res = try self.driver.exec(q.sql, q.args);
            const duration_us: u64 = nowUs() - start;

            // After hooks on success.
            rthook.globalAfter(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .update) {
                    if (h.after) |f| f(&hook_ctx) catch {};
                }
            }

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
        hooks: []const Hook,
        privacy_ctx: ?privacy.PrivacyContext = null,
        logger: Logger = .{},

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver, hooks: []const Hook, privacy_ctx: ?privacy.PrivacyContext) Self {
            return .{
                .allocator = allocator,
                .driver = driver,
                .hooks = hooks,
                .privacy_ctx = privacy_ctx,
                .predicates = std.array_list.Managed(sql.Predicate).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.predicates.deinit();
        }

        /// Add predicates for WHERE clause.
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

        fn execSoftDelete(self: *Self) ExecError!usize {
            if (info.policy) |p| {
                const ctx = self.privacy_ctx orelse return error.PrivacyDenied;
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
                .privacy = self.privacy_ctx orelse .{},
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
                        if (h.after) |f| f(&hook_ctx) catch {};
                    }
                }
            }

            // Get current timestamp (seconds since epoch)
            const now: i64 = @intCast(time(null));
            var builder = sql.Update(self.allocator, self.driver.dialect(), info.table_name);
            defer builder.deinit();
            _ = try builder.set("deleted_at", .{ .int = now });

            for (self.predicates.items) |pred| {
                _ = try builder.where(pred);
            }

            const q = builder.query() catch |err| return mapBuildError(err);
            const start = nowUs();
            const res = try self.driver.exec(q.sql, q.args);
            const duration_us: u64 = nowUs() - start;

            // After hooks on success.
            rthook.globalAfter(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .delete) {
                    if (h.after) |f| f(&hook_ctx) catch {};
                }
            }

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
                const ctx = self.privacy_ctx orelse return error.PrivacyDenied;
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
                .privacy = self.privacy_ctx orelse .{},
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
                        if (h.after) |f| f(&hook_ctx) catch {};
                    }
                }
            }

            var builder = sql.Delete(self.allocator, self.driver.dialect(), info.table_name);
            defer builder.deinit();

            for (self.predicates.items) |pred| {
                _ = try builder.where(pred);
            }

            const q = builder.query() catch |err| return mapBuildError(err);
            const start = nowUs();
            const res = try self.driver.exec(q.sql, q.args);
            const duration_us: u64 = nowUs() - start;

            // After hooks on success.
            rthook.globalAfter(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .delete) {
                    if (h.after) |f| f(&hook_ctx) catch {};
                }
            }

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
                        const Expected = f.zig_type;
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
                const ctx = self.privacy_ctx orelse return error.PrivacyDenied;
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
                .privacy = self.privacy_ctx orelse .{},
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
                        if (h.after) |f| f(&hook_ctx) catch {};
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
            const res = try self.driver.exec(q.sql, q.args);

            // After hooks on success.
            rthook.globalAfter(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .update) {
                    if (h.after) |f| f(&hook_ctx) catch {};
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

        /// Start a new predicate group for the next row to delete.
        pub fn Next(self: *Self) !*Self {
            _ = try self.b.next();
            return self;
        }

        /// Add predicates for the current row's WHERE clause.
        /// Groups are ORed together in the final DELETE.
        pub fn Where(self: *Self, predicates: anytype) !*Self {
            switch (@typeInfo(@TypeOf(predicates))) {
                .pointer, .array => {
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
                        @compileError("Where expects a tuple or slice of sql.Predicate");
                    }
                },
                else => @compileError("Where expects a tuple or slice of sql.Predicate"),
            }
            return self;
        }

        const ExecError = sql_driver.Error || HookError || error{PrivacyDenied};

        /// Execute the bulk DELETE and return rows affected.
        pub fn Exec(self: *Self) ExecError!usize {
            if (info.soft_delete) {
                @compileError("BulkDelete does not support soft_delete entities; use Update or individual Delete");
            }
            return self.execHardDelete();
        }

        fn execHardDelete(self: *Self) ExecError!usize {
            if (info.policy) |p| {
                const ctx = self.privacy_ctx orelse return error.PrivacyDenied;
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
                .privacy = self.privacy_ctx orelse .{},
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
                        if (h.after) |f| f(&hook_ctx) catch {};
                    }
                }
            }

            if (self.b.groups.items.len == 0) return 0;

            const q = self.b.query() catch |err| return mapBuildError(err);
            const res = try self.driver.exec(q.sql, q.args);

            // After hooks on success.
            rthook.globalAfter(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .delete) {
                    if (h.after) |f| f(&hook_ctx) catch {};
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

    _ = u.set("name", .{ .string = "bob" });
    try std.testing.expectEqual(@as(usize, 1), u.values.items.len);

    _ = u.Where(&.{sql.EQ("id", .{ .int = 1 })});
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

    _ = d.Where(&.{sql.EQ("id", .{ .int = 1 })});
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
    _ = u.set("name", .{ .string = "bob" }).Where(&.{sql.EQ("id", .{ .int = 1 })});

    var d = Del.init(std.testing.allocator, undefined, &.{}, null);
    defer d.deinit();
    _ = d.Where(&.{sql.EQ("id", .{ .int = 1 })});

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

    var u = BulkUpd.init(std.testing.allocator, undefined, &.{}, null);
    defer u.deinit();

    _ = u.Row(1).setFieldValue("name", "alice").setFieldValue("age", 31);
    _ = u.Row(2).setFieldValue("name", "bob");

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

    var d = BulkDel.init(std.testing.allocator, undefined, &.{}, null);
    defer d.deinit();

    _ = d.Where(&.{sql.EQ("id", .{ .int = 1 })});
    _ = d.Next().Where(&.{sql.EQ("id", .{ .int = 2 })});

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
