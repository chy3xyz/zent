const std = @import("std");
const TypeInfo = @import("graph.zig").TypeInfo;
const FieldInfo = @import("graph.zig").FieldInfo;
const sql = @import("../sql/builder.zig");
const sql_driver = @import("../sql/driver.zig");
const Dialect = @import("../sql/dialect.zig").Dialect;

const FieldValue = @import("create.zig").FieldValue;

/// Generate an Update builder for an entity.
pub fn UpdateBuilder(comptime info: TypeInfo) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        driver: sql_driver.Driver,
        values: std.array_list.Managed(FieldValue),
        predicates: std.array_list.Managed(sql.Predicate),

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver) Self {
            return .{
                .allocator = allocator,
                .driver = driver,
                .values = std.array_list.Managed(FieldValue).init(allocator),
                .predicates = std.array_list.Managed(sql.Predicate).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.values.deinit();
            self.predicates.deinit();
        }

        pub fn set(self: *Self, comptime field_name: []const u8, value: anytype) *Self {
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
            self.values.append(.{ .name = field_name, .value = toValue(value) }) catch unreachable;
            return self;
        }

        pub fn Where(self: *Self, ps: []const sql.Predicate) *Self {
            for (ps) |p| {
                self.predicates.append(p) catch unreachable;
            }
            return self;
        }

        pub fn Save(self: *Self) !usize {
            var builder = sql.Update(self.allocator, self.driver.dialect(), info.table_name);
            defer builder.deinit();

            for (self.values.items) |fv| {
                _ = builder.set(fv.name, fv.value);
            }
            for (self.predicates.items) |pred| {
                _ = builder.where(pred);
            }

            const q = try builder.query();
            const res = try self.driver.exec(q.sql, q.args);
            return res.rows_affected;
        }

        fn toValue(v: anytype) sql.Value {
            const T = @TypeOf(v);
            if (T == comptime_int) return .{ .int = v };
            if (T == comptime_float) return .{ .float = v };
            switch (@typeInfo(T)) {
                .bool => return .{ .bool = v },
                .int => return .{ .int = v },
                .float => return .{ .float = v },
                else => {
                    if (T == []const u8) return .{ .string = v };
                    @compileError("Unsupported value type: " ++ @typeName(T));
                },
            }
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

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver) Self {
            return .{
                .allocator = allocator,
                .driver = driver,
                .predicates = std.array_list.Managed(sql.Predicate).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.predicates.deinit();
        }

        pub fn Where(self: *Self, ps: []const sql.Predicate) *Self {
            for (ps) |p| {
                self.predicates.append(p) catch unreachable;
            }
            return self;
        }

        pub fn Exec(self: *Self) !usize {
            var builder = sql.Delete(self.allocator, self.driver.dialect(), info.table_name);
            defer builder.deinit();

            for (self.predicates.items) |pred| {
                _ = builder.where(pred);
            }

            const q = try builder.query();
            const res = try self.driver.exec(q.sql, q.args);
            return res.rows_affected;
        }
    };
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Update and Delete builders" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const Upd = UpdateBuilder(info);
    const Del = DeleteBuilder(info);

    var u = Upd.init(std.testing.allocator, undefined);
    defer u.deinit();
    _ = u.set("name", "alice").Where(&.{sql.EQ("id", .{ .int = 1 })});
    try std.testing.expectEqual(@as(usize, 1), u.values.items.len);

    var d = Del.init(std.testing.allocator, undefined);
    defer d.deinit();
    _ = d.Where(&.{sql.EQ("id", .{ .int = 1 })});
    try std.testing.expectEqual(@as(usize, 1), d.predicates.items.len);
}
