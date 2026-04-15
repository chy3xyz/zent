const std = @import("std");
const TypeInfo = @import("graph.zig").TypeInfo;
const sql_driver = @import("../sql/driver.zig");

const EntityGen = @import("entity.zig").Entity;
const CreateGen = @import("create.zig").CreateBuilder;
const QueryGen = @import("query.zig").QueryBuilder;
const UpdateGen = @import("update_delete.zig").UpdateBuilder;
const DeleteGen = @import("update_delete.zig").DeleteBuilder;
const PredGen = @import("predicate.zig").makePredicates;
const MetaGen = @import("meta.zig").Meta;

/// Client for a single entity type.
pub fn EntityClient(comptime info: TypeInfo) type {
    const Entity = EntityGen(info);
    const CreateBuilder = CreateGen(info, Entity);
    const QueryBuilder = QueryGen(info, Entity);
    const UpdateBuilder = UpdateGen(info);
    const DeleteBuilder = DeleteGen(info);
    const Predicates = comptime PredGen(info);
    const Meta = comptime MetaGen(info);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        driver: sql_driver.Driver,
        predicates: @TypeOf(Predicates),

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver) Self {
            return .{
                .allocator = allocator,
                .driver = driver,
                .predicates = Predicates,
            };
        }

        pub fn Create(self: Self) CreateBuilder {
            return CreateBuilder.init(self.allocator, self.driver);
        }

        pub fn Query(self: Self) QueryBuilder {
            return QueryBuilder.init(self.allocator, self.driver);
        }

        pub fn Update(self: Self) UpdateBuilder {
            return UpdateBuilder.init(self.allocator, self.driver);
        }

        pub fn Delete(self: Self) DeleteBuilder {
            return DeleteBuilder.init(self.allocator, self.driver);
        }

        pub const EntityType = Entity;
        pub const meta = Meta;
    };
}

fn toSnakeCase(name: []const u8) []const u8 {
    comptime {
        var result: []const u8 = "";
        for (name, 0..) |c, i| {
            if (std.ascii.isUpper(c) and i > 0) {
                result = result ++ "_";
            }
            result = result ++ &[_]u8{std.ascii.toLower(c)};
        }
        return result;
    }
}

fn structFieldName(comptime name: []const u8) [:0]const u8 {
    comptime {
        var buf: [256:0]u8 = undefined;
        var len: usize = 0;
        for (name, 0..) |c, i| {
            if (std.ascii.isUpper(c) and i > 0) {
                buf[len] = '_';
                len += 1;
            }
            buf[len] = std.ascii.toLower(c);
            len += 1;
        }
        buf[len] = 0;
        return buf[0..len :0];
    }
}

/// Generate a root Client type from multiple TypeInfos.
pub fn Client(comptime infos: []const TypeInfo) type {
    comptime {
        var fields: []const std.builtin.Type.StructField = &.{};

        for (infos) |info| {
            const ClientType = EntityClient(info);

            fields = fields ++ &[_]std.builtin.Type.StructField{.{
                .name = structFieldName(info.name),
                .type = ClientType,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(ClientType),
            }};
        }

        return @Type(.{
            .@"struct" = .{
                .layout = .auto,
                .fields = fields,
                .decls = &.{},
                .is_tuple = false,
            },
        });
    }
}

/// Instantiate a Client.
pub fn makeClient(comptime infos: []const TypeInfo, allocator: std.mem.Allocator, driver: sql_driver.Driver) Client(infos) {
    var result: Client(infos) = undefined;
    inline for (infos) |info| {
        const ClientType = EntityClient(info);
        const field_name = comptime toSnakeCase(info.name);
        @field(result, field_name) = ClientType.init(allocator, driver);
    }
    return result;
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "EntityClient" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const ClientType = EntityClient(info);

    const client = ClientType.init(std.testing.allocator, undefined);
    var builder = client.Create();
    defer builder.deinit();

    // Test set method indirectly
    _ = builder.setValue("name", .{ .string = "alice" });
    try std.testing.expectEqual(@as(usize, 1), builder.values.items.len);
}

test "Client type generation" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });
    const Car = schema("Car", .{
        .fields = &.{field.String("model")},
    });

    const user_info = comptime fromSchema(User);
    const car_info = comptime fromSchema(Car);
    const infos = &[_]TypeInfo{ user_info, car_info };

    _ = Client(infos);

    // Verify field names exist
    const c = std.testing.allocator;
    var client = makeClient(infos, c, undefined);
    _ = client.user.Create();
    _ = client.car.Create();
}
