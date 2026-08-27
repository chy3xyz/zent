const std = @import("std");
const main = @import("main.zig");
const zent = @import("zent");

const Benchmark = main.Benchmark;
const Result = main.Result;

const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
const buildGraph = zent.codegen.graph.buildGraph;
const client_mod = zent.codegen.client;
const Client = zent.codegen.client.Client;
const field = zent.core.field;
const edge = zent.core.edge;
const schema = zent.core.schema.Schema;
const deinitEntity = zent.codegen.deinitEntity;

/// O2M pair: one eager user -> many pets. The Pet side declares no inverse
/// From edge, so the FK column is derived from the source name
/// (`eager_user_id`) — the same minimal shape the integration tests use.
const PetBase = schema("EagerPet", .{
    .fields = &.{field.String("name")},
});
const UserBase = schema("EagerUser", .{
    .fields = &.{field.String("name")},
});

const Pet = struct {
    pub const schema_name = PetBase.schema_name;
    pub const fields = PetBase.fields;
    pub const edges = PetBase.edges;
    pub const indexes = PetBase.indexes;
    pub const policy = PetBase.policy;
    pub const is_view = PetBase.is_view;
    pub const view_sql = PetBase.view_sql;
    pub const soft_delete = PetBase.soft_delete;
};

const User = struct {
    pub const schema_name = UserBase.schema_name;
    pub const fields = UserBase.fields;
    pub const edges = &.{edge.To("pets", PetBase)};
    pub const indexes = UserBase.indexes;
    pub const policy = UserBase.policy;
    pub const is_view = UserBase.is_view;
    pub const view_sql = UserBase.view_sql;
    pub const soft_delete = UserBase.soft_delete;
};

const graph = buildGraph(&.{ User, Pet });
const infos = graph.types;
const user_info = infos[0];
const pet_info = infos[1];
const ClientT = Client(infos);

const user_count = 100;
const pets_per_user = 3;

const EagerCtx = struct {
    allocator: std.mem.Allocator,
    client: *ClientT,
};

fn benchEagerLoad(allocator: std.mem.Allocator, io: std.Io) !Result {
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    try client_mod.createAllTables(infos, drv.asDriver());
    var client = client_mod.makeClient(infos, allocator, drv.asDriver());

    // Seed N users with K pets each (raw SQL — setup is not timed).
    for (0..user_count) |i| {
        const uid: i64 = @intCast(i + 1);
        _ = try drv.exec("INSERT INTO eager_user (id, name) VALUES (?, ?)", &.{
            .{ .int = uid },
            .{ .string = "user" },
        });
        for (0..pets_per_user) |_| {
            _ = try drv.exec("INSERT INTO eager_pet (name, eager_user_id) VALUES (?, ?)", &.{
                .{ .string = "pet" },
                .{ .int = uid },
            });
        }
    }

    // One-shot correctness check: right parent count, right neighbor count
    // per parent, and the eager-loaded slice is actually populated.
    {
        var q = client.eager_user.Query();
        defer q.deinit();
        _ = try q.WithEdge("pets");
        var users = try q.All();
        defer {
            for (users.items) |*u| deinitEntity(infos, user_info, u, allocator);
            users.deinit();
        }
        if (users.items.len != user_count) return error.BenchmarkMismatch;
        for (users.items) |*u| {
            const pets = u.edges.pets orelse return error.BenchmarkMismatch;
            if (pets.len != pets_per_user) return error.BenchmarkMismatch;
        }
    }

    var ctx = EagerCtx{ .allocator = allocator, .client = &client };
    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *EagerCtx = @ptrCast(@alignCast(ptr));
            var q = c.client.eager_user.Query();
            defer q.deinit();
            _ = try q.WithEdge("pets");
            var users = try q.All();
            defer {
                for (users.items) |*u| deinitEntity(infos, user_info, u, c.allocator);
                users.deinit();
            }
        }
    }.body);
}

pub const benchmarks: []const Benchmark = &[_]Benchmark{
    .{ .name = "eager/with_edge_o2m", .run = benchEagerLoad },
};
