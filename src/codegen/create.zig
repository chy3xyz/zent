const std = @import("std");
const TypeInfo = @import("graph.zig").TypeInfo;
const FieldInfo = @import("graph.zig").FieldInfo;
const EdgeInfo = @import("graph.zig").EdgeInfo;
const sql = @import("../sql/builder.zig");
const sql_driver = @import("../sql/driver.zig");
const Dialect = @import("../sql/dialect.zig").Dialect;

/// A runtime field value entry.
pub const FieldValue = struct {
    name: []const u8,
    value: sql.Value,
};

/// Generate a Create builder for an entity.
pub fn CreateBuilder(comptime info: TypeInfo, comptime Entity: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        driver: sql_driver.Driver,
        values: std.array_list.Managed(FieldValue),
        edge_values: std.array_list.Managed(EdgeValue),

        const EdgeValue = struct {
            edge: []const u8,
            ids: []const i64,
        };

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver) Self {
            return .{
                .allocator = allocator,
                .driver = driver,
                .values = std.array_list.Managed(FieldValue).init(allocator),
                .edge_values = std.array_list.Managed(EdgeValue).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.values.deinit();
            self.edge_values.deinit();
        }

        // Set field value helper
        pub fn setValue(self: *Self, name: []const u8, value: sql.Value) *Self {
            self.values.append(.{ .name = name, .value = value }) catch unreachable;
            return self;
        }

        pub fn Save(self: *Self) !Entity {
            var columns = std.array_list.Managed([]const u8).init(self.allocator);
            defer columns.deinit();
            var args = std.array_list.Managed(sql.Value).init(self.allocator);
            defer args.deinit();

            for (self.values.items) |fv| {
                columns.append(fv.name) catch unreachable;
                args.append(fv.value) catch unreachable;
            }

            // Insert the entity
            var builder = sql.Insert(self.allocator, self.driver.dialect(), info.table_name);
            defer builder.deinit();
            _ = builder.columns(columns.items).values(args.items);
            const q = try builder.query();
            const res = try self.driver.exec(q.sql, q.args);

            var entity: Entity = undefined;
            entity.id = @intCast(res.last_insert_id orelse 0);

            // Fill other fields from mutation values
            for (self.values.items) |fv| {
                if (std.mem.eql(u8, fv.name, "id")) continue;
                setEntityField(&entity, fv.name, fv.value);
            }

            return entity;
        }

        fn setEntityField(entity: *Entity, name: []const u8, value: sql.Value) void {
            inline for (info.fields) |f| {
                if (std.mem.eql(u8, f.name, name)) {
                    @field(entity, f.name) = valueToType(f.zig_type, value);
                    return;
                }
            }
        }

        fn valueToType(comptime T: type, value: sql.Value) T {
            return switch (@typeInfo(T)) {
                .int => @intCast(value.int),
                .bool => value.bool,
                .float => @floatCast(value.float),
                else => {
                    if (T == []const u8) return value.string;
                    @compileError("Unsupported type for value conversion: " ++ @typeName(T));
                },
            };
        }
    };
}

// ------------------------------------------------------------------
// Tests
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
    const UserEntity = comptime EntityGen(info);
    const Builder = CreateBuilder(info, UserEntity);

    var b = Builder.init(std.testing.allocator, undefined);
    defer b.deinit();

    // Test the internal setValue method
    _ = b.setValue("name", .{ .string = "alice" });
    try std.testing.expectEqual(@as(usize, 1), b.values.items.len);
}
