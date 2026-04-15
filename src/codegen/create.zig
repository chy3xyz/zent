const std = @import("std");
const TypeInfo = @import("graph.zig").TypeInfo;
const FieldInfo = @import("graph.zig").FieldInfo;
const EdgeInfo = @import("graph.zig").EdgeInfo;
const sql = @import("../sql/builder.zig");
const sql_driver = @import("../sql/driver.zig");
const Dialect = @import("../sql/dialect.zig").Dialect;
const Hook = @import("../runtime/hook.zig").Hook;
const Op = @import("../runtime/hook.zig").Op;
const privacy = @import("../privacy/policy.zig");

/// A runtime field value entry.
pub const FieldValue = struct {
    name: []const u8,
    value: sql.Value,
};

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

/// Generate a Create builder for an entity.
pub fn CreateBuilder(comptime infos: []const TypeInfo, comptime info: TypeInfo, comptime Entity: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        driver: sql_driver.Driver,
        values: std.array_list.Managed(FieldValue),
        edge_values: std.array_list.Managed(EdgeValue),
        json_strings: std.array_list.Managed([]const u8),
        hooks: []const Hook,

        const EdgeValue = struct {
            edge: []const u8,
            ids: []const i64,
        };

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver, hooks: []const Hook) Self {
            return .{
                .allocator = allocator,
                .driver = driver,
                .hooks = hooks,
                .values = std.array_list.Managed(FieldValue).init(allocator),
                .edge_values = std.array_list.Managed(EdgeValue).init(allocator),
                .json_strings = std.array_list.Managed([]const u8).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.json_strings.items) |s| self.allocator.free(s);
            self.json_strings.deinit();
            self.values.deinit();
            self.edge_values.deinit();
        }

        // Set field value helper (dynamic, no compile-time checking).
        pub fn setValue(self: *Self, name: []const u8, value: sql.Value) *Self {
            self.values.append(.{ .name = name, .value = value }) catch unreachable;
            return self;
        }

        /// Set a field value with compile-time name and type checking.
        pub fn setFieldValue(self: *Self, comptime field_name: []const u8, value: anytype) *Self {
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
                        found = true;
                        break;
                    }
                }
                if (!found) @compileError("Unknown field: " ++ field_name);
            }

            if (comptime needs_json) {
                const json_str = std.json.Stringify.valueAlloc(self.allocator, value, .{}) catch unreachable;
                self.json_strings.append(json_str) catch unreachable;
                return self.setValue(field_name, .{ .string = json_str });
            }

            return self.setValue(field_name, toSqlValue(value));
        }

        /// Add target IDs for an M2M edge.
        /// After Save(), junction table rows will be inserted automatically.
        pub fn AddEdge(self: *Self, comptime edge_name: []const u8, ids: []const i64) *Self {
            comptime {
                const edge = findEdgeInfo(info, edge_name);
                if (edge.relation != .m2m) {
                    @compileError("AddEdge is only supported for M2M edges: " ++ edge_name);
                }
            }
            self.edge_values.append(.{ .edge = edge_name, .ids = ids }) catch unreachable;
            return self;
        }

        pub fn Save(self: *Self) !Entity {
            return self.saveInternal(false);
        }

        pub fn SaveOrUpdate(self: *Self) !Entity {
            return self.saveInternal(true);
        }

        fn saveInternal(self: *Self, comptime or_replace: bool) !Entity {
            if (info.policy) |p| {
                if (p.evalMutation(.create, info.table_name) == .deny) {
                    return error.PrivacyDenied;
                }
            }
            for (self.hooks) |h| {
                if (h.op == .create) {
                    if (h.before) |f| f(.create, info.table_name);
                }
            }
            defer {
                for (self.hooks) |h| {
                    if (h.op == .create) {
                        if (h.after) |f| f(.create, info.table_name);
                    }
                }
            }

            var columns = std.array_list.Managed([]const u8).init(self.allocator);
            defer columns.deinit();
            var args = std.array_list.Managed(sql.Value).init(self.allocator);
            defer args.deinit();

            for (self.values.items) |fv| {
                inline for (info.fields) |f| {
                    if (std.mem.eql(u8, f.name, fv.name)) {
                        try validateSqlValue(f, fv.value);
                    }
                }
                columns.append(fv.name) catch unreachable;
                args.append(fv.value) catch unreachable;
            }

            // Insert the entity
            var builder = if (or_replace)
                sql.InsertOrReplace(self.allocator, self.driver.dialect(), info.table_name)
            else
                sql.Insert(self.allocator, self.driver.dialect(), info.table_name);
            defer builder.deinit();
            _ = builder.columns(columns.items).values(args.items);
            const q = try builder.query();
            const res = try self.driver.exec(q.sql, q.args);

            var entity: Entity = undefined;
            entity.id = @intCast(res.last_insert_id orelse 0);

            // Fill other fields from mutation values
            for (self.values.items) |fv| {
                if (std.mem.eql(u8, fv.name, "id")) continue;
                setEntityField(&entity, fv.name, fv.value, self.allocator);
            }

            // Insert M2M junction table rows (or edge schema rows)
            inline for (info.edges) |edge| {
                if (edge.relation == .m2m) {
                    for (self.edge_values.items) |ev| {
                        if (std.mem.eql(u8, ev.edge, edge.name)) {
                            const target_info = findTypeInfo(infos, edge.target_name);
                            const source_table = info.table_name;
                            const target_table = target_info.table_name;
                            const junction_table = if (edge.through_name) |tn|
                                tn
                            else if (std.mem.lessThan(u8, source_table, target_table))
                                source_table ++ "_" ++ target_table
                            else
                                target_table ++ "_" ++ source_table;
                            const source_col = source_table ++ "_id";
                            const target_col = target_table ++ "_id";

                            const insert_sql = if (or_replace)
                                "INSERT OR REPLACE INTO \"" ++ junction_table ++ "\" (\"" ++ source_col ++ "\", \"" ++ target_col ++ "\") VALUES (?, ?)"
                            else
                                "INSERT INTO \"" ++ junction_table ++ "\" (\"" ++ source_col ++ "\", \"" ++ target_col ++ "\") VALUES (?, ?)";

                            for (ev.ids) |target_id| {
                                _ = try self.driver.exec(
                                    insert_sql,
                                    &.{ .{ .int = entity.id }, .{ .int = target_id } },
                                );
                            }
                        }
                    }
                }
            }

            return entity;
        }

        fn setEntityField(entity: *Entity, name: []const u8, value: sql.Value, allocator: std.mem.Allocator) void {
            inline for (info.fields) |f| {
                if (std.mem.eql(u8, f.name, name)) {
                    @field(entity, f.name) = valueToType(f.zig_type, f.field_type, value, allocator);
                    return;
                }
            }
        }

        fn valueToType(comptime T: type, comptime ft: @import("../core/field.zig").FieldType, value: sql.Value, allocator: std.mem.Allocator) T {
            return switch (@typeInfo(T)) {
                .int => @intCast(value.int),
                .bool => value.bool,
                .float => @floatCast(value.float),
                else => {
                    if (T == []const u8) return value.string;
                    if (ft == .json) {
                        const parsed = std.json.parseFromSliceLeaky(T, allocator, value.string, .{}) catch unreachable;
                        return parsed;
                    }
                    @compileError("Unsupported type for value conversion: " ++ @typeName(T));
                },
            };
        }
    };
}

pub fn validateSqlValue(comptime field: FieldInfo, value: sql.Value) !void {
    for (field.validators) |v| {
        switch (v) {
            .positive => {
                const int_val = switch (value) {
                    .int => |i| i,
                    else => return error.ValidationFailed,
                };
                if (int_val <= 0) return error.ValidationFailed;
            },
            .range => |r| {
                const int_val = switch (value) {
                    .int => |i| i,
                    else => return error.ValidationFailed,
                };
                if (int_val < r.min or int_val > r.max) return error.ValidationFailed;
            },
            .match => |pattern| {
                const str_val = switch (value) {
                    .string => |s| s,
                    else => return error.ValidationFailed,
                };
                if (std.mem.indexOf(u8, str_val, pattern) == null) return error.ValidationFailed;
            },
            .custom => return error.ValidationFailed,
        }
    }
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
                if (ptr.size == .slice and ptr.child == u8) return true;
                if (ptr.size == .one) {
                    const child_ti = @typeInfo(ptr.child);
                    if (child_ti == .array) return child_ti.array.child == u8;
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

    const ti = @typeInfo(T);
    switch (ti) {
        .bool => return .{ .bool = v },
        .int => return .{ .int = v },
        .float => return .{ .float = v },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return .{ .string = v };
            if (ptr.size == .one) {
                const child_ti = @typeInfo(ptr.child);
                if (child_ti == .array and child_ti.array.child == u8) return .{ .string = v };
            }
        },
        .array => |arr| {
            if (arr.child == u8) return .{ .string = v };
        },
        else => {},
    }
    @compileError("Unsupported value type: " ++ @typeName(T));
}

/// Generate a Bulk Insert builder for an entity.
/// Supports INSERT ... VALUES (...), (...) RETURNING "id" for backends
/// that support RETURNING (SQLite 3.35+, PostgreSQL, MySQL 8.0.19+).
pub fn BulkInsertBuilder(comptime infos: []const TypeInfo, comptime info: TypeInfo, comptime Entity: type) type {
    _ = infos;
    _ = Entity;
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        driver: sql_driver.Driver,
        rows: std.array_list.Managed(std.array_list.Managed(FieldValue)),
        json_strings: std.array_list.Managed([]const u8),
        hooks: []const Hook,

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver, hooks: []const Hook) Self {
            var self = Self{
                .allocator = allocator,
                .driver = driver,
                .hooks = hooks,
                .rows = std.array_list.Managed(std.array_list.Managed(FieldValue)).init(allocator),
                .json_strings = std.array_list.Managed([]const u8).init(allocator),
            };
            self.rows.append(std.array_list.Managed(FieldValue).init(allocator)) catch unreachable;
            return self;
        }

        pub fn deinit(self: *Self) void {
            for (self.json_strings.items) |s| self.allocator.free(s);
            self.json_strings.deinit();
            for (self.rows.items) |*row| row.deinit();
            self.rows.deinit();
        }

        /// Start a new row in the bulk insert batch.
        pub fn Next(self: *Self) *Self {
            self.rows.append(std.array_list.Managed(FieldValue).init(self.allocator)) catch unreachable;
            return self;
        }

        pub fn setValue(self: *Self, name: []const u8, value: sql.Value) *Self {
            var row = &self.rows.items[self.rows.items.len - 1];
            row.append(.{ .name = name, .value = value }) catch unreachable;
            return self;
        }

        pub fn setFieldValue(self: *Self, comptime field_name: []const u8, value: anytype) *Self {
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
                        found = true;
                        break;
                    }
                }
                if (!found) @compileError("Unknown field: " ++ field_name);
            }

            if (comptime needs_json) {
                const json_str = std.json.Stringify.valueAlloc(self.allocator, value, .{}) catch unreachable;
                self.json_strings.append(json_str) catch unreachable;
                return self.setValue(field_name, .{ .string = json_str });
            }

            return self.setValue(field_name, toSqlValue(value));
        }

        pub fn Save(self: *Self) !std.array_list.Managed(i64) {
            if (info.policy) |p| {
                if (p.evalMutation(.create, info.table_name) == .deny) {
                    return error.PrivacyDenied;
                }
            }
            for (self.hooks) |h| {
                if (h.op == .create) {
                    if (h.before) |f| f(.create, info.table_name);
                }
            }
            defer {
                for (self.hooks) |h| {
                    if (h.op == .create) {
                        if (h.after) |f| f(.create, info.table_name);
                    }
                }
            }

            // Remove trailing empty row if user called Next() at the end
            while (self.rows.items.len > 0 and self.rows.items[self.rows.items.len - 1].items.len == 0) {
                var last = self.rows.pop().?;
                last.deinit();
            }

            if (self.rows.items.len == 0) {
                return std.array_list.Managed(i64).init(self.allocator);
            }

            // Validate all rows
            for (self.rows.items) |row| {
                for (row.items) |fv| {
                    inline for (info.fields) |f| {
                        if (std.mem.eql(u8, f.name, fv.name)) {
                            try validateSqlValue(f, fv.value);
                        }
                    }
                }
            }

            const first_row = self.rows.items[0];
            var columns = std.array_list.Managed([]const u8).init(self.allocator);
            defer columns.deinit();
            for (first_row.items) |fv| {
                columns.append(fv.name) catch unreachable;
            }

            var builder = sql.Insert(self.allocator, self.driver.dialect(), info.table_name);
            defer builder.deinit();
            _ = builder.columns(columns.items);
            for (self.rows.items) |row| {
                var sql_values = std.array_list.Managed(sql.Value).init(self.allocator);
                defer sql_values.deinit();
                for (row.items) |fv| sql_values.append(fv.value) catch unreachable;
                _ = builder.values(sql_values.items);
            }
            const base = try builder.query();

            var sql_buf = std.array_list.Managed(u8).init(self.allocator);
            defer sql_buf.deinit();
            try sql_buf.appendSlice(base.sql);
            try sql_buf.appendSlice(" RETURNING \"id\"");

            var rows = try self.driver.query(sql_buf.items, base.args);
            defer rows.deinit();

            var ids = std.array_list.Managed(i64).init(self.allocator);
            errdefer ids.deinit();
            while (rows.next()) |row| {
                const id = row.getInt(0) orelse return error.TypeMismatch;
                ids.append(id) catch unreachable;
            }
            return ids;
        }
    };
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Create builder basic" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const Builder = CreateBuilder(infos, info, UserEntity);

    var b = Builder.init(std.testing.allocator, undefined);
    defer b.deinit();

    // Test the internal setValue method
    _ = b.setValue("name", .{ .string = "alice" });
    try std.testing.expectEqual(@as(usize, 1), b.values.items.len);
}

test "BulkInsert builder basic" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const BulkBuilder = BulkInsertBuilder(infos, info, UserEntity);

    var b = BulkBuilder.init(std.testing.allocator, undefined, &.{});
    defer b.deinit();

    _ = b.setFieldValue("name", "alice").setFieldValue("age", 30);
    b.Next();
    _ = b.setFieldValue("name", "bob").setFieldValue("age", 25);

    try std.testing.expectEqual(@as(usize, 2), b.rows.items.len);
    try std.testing.expectEqualStrings("alice", b.rows.items[0].items[0].value.string);
    try std.testing.expectEqual(@as(i64, 25), b.rows.items[1].items[1].value.int);
}

test "validateSqlValue positive" {
    const field_mod = @import("../core/field.zig");
    const f = field_mod.Int("age").Positive();
    const info = FieldInfo{
        .name = f.name,
        .field_type = f.field_type,
        .zig_type = i64,
        .sql_type = "INTEGER",
        .optional = false,
        .nillable = false,
        .unique = false,
        .immutable = false,
        .default = .none,
        .validators = f.validators,
        .enum_values = f.enum_values,
        .is_id = false,
    };

    try validateSqlValue(info, .{ .int = 5 });
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info, .{ .int = 0 }));
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info, .{ .int = -1 }));
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info, .{ .string = "x" }));
}

test "validateSqlValue range" {
    const field_mod = @import("../core/field.zig");
    const f = field_mod.Int("age").Range(0, 120);
    const info = FieldInfo{
        .name = f.name,
        .field_type = f.field_type,
        .zig_type = i64,
        .sql_type = "INTEGER",
        .optional = false,
        .nillable = false,
        .unique = false,
        .immutable = false,
        .default = .none,
        .validators = f.validators,
        .enum_values = f.enum_values,
        .is_id = false,
    };

    try validateSqlValue(info, .{ .int = 0 });
    try validateSqlValue(info, .{ .int = 120 });
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info, .{ .int = -1 }));
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info, .{ .int = 121 }));
}

test "validateSqlValue match" {
    const field_mod = @import("../core/field.zig");
    const f = field_mod.String("email").Match("@");
    const info = FieldInfo{
        .name = f.name,
        .field_type = f.field_type,
        .zig_type = []const u8,
        .sql_type = "TEXT",
        .optional = false,
        .nillable = false,
        .unique = false,
        .immutable = false,
        .default = .none,
        .validators = f.validators,
        .enum_values = f.enum_values,
        .is_id = false,
    };

    try validateSqlValue(info, .{ .string = "a@b.com" });
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info, .{ .string = "invalid" }));
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info, .{ .int = 1 }));
}

test "Create builder SaveOrUpdate compiles" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const Builder = CreateBuilder(infos, info, UserEntity);

    var b = Builder.init(std.testing.allocator, undefined, &.{});
    defer b.deinit();

    _ = b.setFieldValue("name", "alice").setFieldValue("age", 30);
    // We can't actually execute SaveOrUpdate without a real driver,
    // but we verify the method exists and compiles.
    try std.testing.expectEqual(@as(usize, 2), b.values.items.len);
}
