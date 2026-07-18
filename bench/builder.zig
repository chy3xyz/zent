const std = @import("std");
const main = @import("main.zig");
const sql = @import("zent").sql;

const Benchmark = main.Benchmark;
const Result = main.Result;

const SimpleCtx = struct {
    b: *sql.Builder,
};

fn benchSimpleSelect(allocator: std.mem.Allocator, io: std.Io) !Result {
    var b = sql.Builder.initCapacity(allocator, 256, 8, .sqlite) catch sql.Builder.init(allocator, .sqlite);
    defer b.deinit();
    var ctx = SimpleCtx{ .b = &b };
    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *SimpleCtx = @ptrCast(@alignCast(ptr));
            c.b.buffer.clearRetainingCapacity();
            c.b.args.clearRetainingCapacity();
            try c.b.writeString("SELECT ");
            try sql.Table("users").c("id").appendTo(c.b);
            try c.b.writeString(", ");
            try sql.Table("users").c("name").appendTo(c.b);
            try c.b.writeString(" FROM ");
            try sql.Table("users").appendTo(c.b);
            _ = c.b.query();
        }
    }.body);
}

const ComplexCtx = struct {
    b: *sql.Builder,
    predicates: []const sql.Predicate,
    order_terms: []const sql.Order,
};

fn benchComplexWhere(allocator: std.mem.Allocator, io: std.Io) !Result {
    var b = sql.Builder.initCapacity(allocator, 512, 16, .sqlite) catch sql.Builder.init(allocator, .sqlite);
    defer b.deinit();

    const predicates = &.{
        sql.Predicate{ .gte = .{ .column = "age", .value = .{ .int = 18 } } },
        sql.Predicate{ .lte = .{ .column = "age", .value = .{ .int = 65 } } },
        sql.Predicate{ .like = .{ .column = "name", .value = .{ .string = "A%" } } },
    };
    const order_terms = &.{
        sql.Order{ .column = .{ .name = "age", .desc = false } },
        sql.Order{ .column = .{ .name = "name", .desc = true } },
    };

    var ctx = ComplexCtx{
        .b = &b,
        .predicates = predicates,
        .order_terms = order_terms,
    };

    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *ComplexCtx = @ptrCast(@alignCast(ptr));
            c.b.buffer.clearRetainingCapacity();
            c.b.args.clearRetainingCapacity();
            try c.b.writeString("SELECT * FROM ");
            try sql.Table("users").appendTo(c.b);
            try c.b.writeString(" WHERE ");
            for (c.predicates, 0..) |p, i| {
                if (i > 0) try c.b.writeString(" AND ");
                try p.appendTo(c.b);
            }
            try c.b.writeString(" ORDER BY ");
            for (c.order_terms, 0..) |o, i| {
                if (i > 0) try c.b.writeString(", ");
                try o.appendTo(c.b);
            }
            try c.b.writeString(" GROUP BY ");
            try c.b.ident("status");
            try c.b.writeString(" LIMIT ");
            try c.b.arg(.{ .int = 10 });
            try c.b.writeString(" OFFSET ");
            try c.b.arg(.{ .int = 20 });
            _ = c.b.query();
        }
    }.body);
}

pub const benchmarks: []const Benchmark = &[_]Benchmark{
    .{ .name = "builder/simple_select", .run = benchSimpleSelect },
    .{ .name = "builder/complex_where", .run = benchComplexWhere },
};
