const std = @import("std");
const TypeInfo = @import("graph.zig").TypeInfo;
const EdgeInfo = @import("graph.zig").EdgeInfo;
const sql_driver = @import("../sql/driver.zig");
const sql = @import("../sql/builder.zig");
const sql_scan = @import("../sql/scan.zig");
const migrate = @import("../sql/schema/migrate.zig");
const Hook = @import("../runtime/hook.zig").Hook;

const EntityGen = @import("entity.zig").Entity;
const CreateGen = @import("create.zig").CreateBuilder;
const QueryGen = @import("query.zig").QueryBuilder;
const UpdateGen = @import("update_delete.zig").UpdateBuilder;
const DeleteGen = @import("update_delete.zig").DeleteBuilder;
const PredGen = @import("predicate.zig").makePredicates;
const MetaGen = @import("meta.zig").Meta;

fn capitalize(comptime s: []const u8) []const u8 {
    comptime {
        var result: [s.len]u8 = undefined;
        result[0] = std.ascii.toUpper(s[0]);
        for (s[1..], 1..) |c, i| {
            result[i] = c;
        }
        return &result;
    }
}

/// Client for a single entity type.
pub fn EntityClient(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
    const Entity = EntityGen(info);
    const CreateBuilder = CreateGen(infos, info, Entity);
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
        hooks: []const Hook,

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver) Self {
            return .{
                .allocator = allocator,
                .driver = driver,
                .predicates = Predicates,
                .hooks = &.{},
            };
        }

        pub fn withHooks(self: Self, hooks: []const Hook) Self {
            var copy = self;
            copy.hooks = hooks;
            return copy;
        }

        pub fn Query(self: Self) QueryBuilder {
            return QueryBuilder.init(self.allocator, self.driver);
        }

        pub fn Create(self: Self) CreateBuilder {
            if (info.is_view) @compileError("Create is not supported for view entities");
            return CreateBuilder.init(self.allocator, self.driver, self.hooks);
        }

        pub fn Update(self: Self) UpdateBuilder {
            if (info.is_view) @compileError("Update is not supported for view entities");
            return UpdateBuilder.init(self.allocator, self.driver, self.hooks);
        }

        pub fn Delete(self: Self) DeleteBuilder {
            if (info.is_view) @compileError("Delete is not supported for view entities");
            return DeleteBuilder.init(self.allocator, self.driver, self.hooks);
        }

        /// Query target entities via an edge.
        /// Example: user_client.QueryEdge("cars", &.{alice.id}) returns Car entities.
        pub fn QueryEdge(self: Self, comptime edge_name: []const u8, parent_ids: []const i64) !QueryTargetsResult(infos, info.name, edge_name) {
            if (info.is_view) @compileError("QueryEdge is not supported for view entities");
            return queryTargets(infos, info.name, edge_name, parent_ids, self.allocator, self.driver);
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

/// Transactional client wrapper.
pub fn TxClient(comptime infos: []const TypeInfo) type {
    return struct {
        client: Client(infos),
        tx: sql_driver.Tx,

        pub fn commit(self: *@This()) !void {
            return self.tx.commit();
        }

        pub fn rollback(self: *@This()) !void {
            return self.tx.rollback();
        }
    };
}

/// Generate a root Client type from multiple TypeInfos.
/// The Client holds entity sub-clients and per-edge query helpers.
pub fn Client(comptime infos: []const TypeInfo) type {
    comptime {
        var fields: []const std.builtin.Type.StructField = &.{};

        // Root fields
        fields = fields ++ &[_]std.builtin.Type.StructField{.{
            .name = "allocator",
            .type = std.mem.Allocator,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(std.mem.Allocator),
        }};
        fields = fields ++ &[_]std.builtin.Type.StructField{.{
            .name = "driver",
            .type = sql_driver.Driver,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(sql_driver.Driver),
        }};

        // Entity sub-clients (user, car, group, ...)
        for (infos) |info| {
            const ClientType = EntityClient(infos, info);

            fields = fields ++ &[_]std.builtin.Type.StructField{.{
                .name = structFieldName(info.name),
                .type = ClientType,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(ClientType),
            }};
        }

        const ClientType = @Type(.{
            .@"struct" = .{
                .layout = .auto,
                .fields = fields,
                .decls = &.{},
                .is_tuple = false,
            },
        });

        return ClientType;
    }
}

/// Instantiate a Client.
pub fn makeClient(comptime infos: []const TypeInfo, allocator: std.mem.Allocator, driver: sql_driver.Driver) Client(infos) {
    var result: Client(infos) = undefined;
    result.allocator = allocator;
    result.driver = driver;
    inline for (infos) |info| {
        const ClientType = EntityClient(infos, info);
        const field_name = comptime toSnakeCase(info.name);
        @field(result, field_name) = ClientType.init(allocator, driver);
    }
    return result;
}

/// Begin a transaction and return a TxClient backed by the transaction.
pub fn beginTx(comptime infos: []const TypeInfo, self: Client(infos)) !TxClient(infos) {
    const tx = try self.driver.beginTx();
    return TxClient(infos){
        .client = makeClient(infos, self.allocator, tx.inner),
        .tx = tx,
    };
}

/// Create all database tables (create-only migration).
/// Creates entity tables and junction tables for M2M edges.
pub fn createAllTables(comptime infos: []const TypeInfo, driver: sql_driver.Driver) !void {
    return migrate.createAllTables(driver, infos);
}

fn findTypeInfo(comptime infos: []const TypeInfo, comptime name: []const u8) TypeInfo {
    for (infos) |info| {
        if (std.mem.eql(u8, info.name, name)) return info;
    }
    @compileError("TypeInfo not found: " ++ name);
}

fn findEdgeInfo(comptime info: TypeInfo, comptime name: []const u8) EdgeInfo {
    for (info.edges) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    @compileError("Edge not found: " ++ name ++ " on " ++ info.name);
}

fn getEdgeFKColumn(comptime edge: EdgeInfo, comptime source_info: TypeInfo, comptime target_info: TypeInfo) []const u8 {
    if (edge.kind == .to) {
        // Target table holds the FK. Look for inverse From edge.
        for (target_info.edges) |target_edge| {
            if (target_edge.kind == .from) {
                if (target_edge.ref) |ref| {
                    if (std.mem.eql(u8, ref, edge.name)) {
                        return target_edge.name ++ "_id";
                    }
                }
            }
        }
        return toSnakeCase(source_info.name) ++ "_id";
    } else {
        // From edge: this entity holds the FK
        return edge.name ++ "_id";
    }
}

fn QueryTargetsResult(
    comptime infos: []const TypeInfo,
    comptime source_name: []const u8,
    comptime edge_name: []const u8,
) type {
    const source_info = findTypeInfo(infos, source_name);
    const edge = findEdgeInfo(source_info, edge_name);
    const target_info = findTypeInfo(infos, edge.target_name);
    return std.array_list.Managed(EntityGen(target_info));
}

/// Query target entities via an O2M/M2M edge.
/// For example: queryTargets(infos, "User", "cars", &[1], allocator, driver) returns Car entities for user 1.
pub fn queryTargets(
    comptime infos: []const TypeInfo,
    comptime source_name: []const u8,
    comptime edge_name: []const u8,
    parent_ids: []const i64,
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
) !QueryTargetsResult(infos, source_name, edge_name) {
    const source_info = comptime findTypeInfo(infos, source_name);
    const edge = comptime findEdgeInfo(source_info, edge_name);
    const target_info = comptime findTypeInfo(infos, edge.target_name);
    const TargetEntity = comptime EntityGen(target_info);

    if (parent_ids.len == 0) {
        return std.array_list.Managed(TargetEntity).init(allocator);
    }

    if (edge.relation == .m2m) {
        // M2M: query via junction table or edge schema (through)
        const source_table = source_info.table_name;
        const target_table = target_info.table_name;
        const junction_table = if (edge.through_name) |tn|
            tn
        else if (std.mem.lessThan(u8, source_table, target_table))
            source_table ++ "_" ++ target_table
        else
            target_table ++ "_" ++ source_table;
        const source_col = source_table ++ "_id";
        const target_col = target_table ++ "_id";

        // Build SQL with placeholders
        var buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();
        try writer.print("SELECT * FROM \"{s}\" WHERE \"id\" IN (SELECT \"{s}\" FROM \"{s}\" WHERE \"{s}\" IN (", .{
            target_table, target_col, junction_table, source_col,
        });
        for (parent_ids, 0..) |_, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll("?");
        }
        try writer.writeAll("))");
        const sql_text = fbs.getWritten();

        var args = try allocator.alloc(sql.Value, parent_ids.len);
        defer allocator.free(args);
        for (parent_ids, 0..) |id, i| {
            args[i] = .{ .int = id };
        }

        var rows = try driver.query(sql_text, args);
        defer rows.deinit();

        var result = std.array_list.Managed(TargetEntity).init(allocator);
        errdefer result.deinit();

        while (rows.next()) |row| {
            const entity = try sql_scan.scanRow(TargetEntity, allocator, row);
            result.append(entity) catch unreachable;
        }
        return result;
    } else {
        // O2M / O2O
        const target_table = target_info.table_name;
        const fk_col = comptime getEdgeFKColumn(edge, source_info, target_info);

        var buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        if (edge.kind == .to) {
            // To edge: FK is in target table
            try writer.print("SELECT * FROM \"{s}\" WHERE \"{s}\" IN (", .{ target_table, fk_col });
        } else {
            // From edge: FK is in source table; use subquery
            const source_table = source_info.table_name;
            try writer.print("SELECT * FROM \"{s}\" WHERE \"id\" IN (SELECT \"{s}\" FROM \"{s}\" WHERE \"id\" IN (", .{
                target_table, fk_col, source_table,
            });
        }
        for (parent_ids, 0..) |_, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll("?");
        }
        if (edge.kind == .from) {
            try writer.writeAll("))");
        } else {
            try writer.writeAll(")");
        }
        const sql_text = fbs.getWritten();

        var args = try allocator.alloc(sql.Value, parent_ids.len);
        defer allocator.free(args);
        for (parent_ids, 0..) |id, i| {
            args[i] = .{ .int = id };
        }

        var rows = try driver.query(sql_text, args);
        defer rows.deinit();

        var result = std.array_list.Managed(TargetEntity).init(allocator);
        errdefer result.deinit();

        while (rows.next()) |row| {
            const entity = try sql_scan.scanRow(TargetEntity, allocator, row);
            result.append(entity) catch unreachable;
        }
        return result;
    }
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
    const infos = &[_]TypeInfo{info};
    const ClientType = EntityClient(infos, info);

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
