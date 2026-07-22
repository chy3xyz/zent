const std = @import("std");
const main = @import("main.zig");
const sql_scan = @import("zent").sql_scan;
const driver = @import("zent").sql_driver;

const Benchmark = main.Benchmark;
const Result = main.Result;

const MockRow = struct {
    pub const vtable = driver.Row.VTable{
        .columnCount = columnCount,
        .columnName = columnName,
        .getInt = getInt,
        .getFloat = getFloat,
        .getText = getText,
        .getBlob = getBlob,
        .getBool = getBool,
        .isNull = isNull,
    };

    fn columnCount(_: *anyopaque) usize {
        return 4;
    }
    fn columnName(_: *anyopaque, index: usize) []const u8 {
        const names = [_][]const u8{ "id", "name", "age", "score" };
        return names[index];
    }
    fn getInt(_: *anyopaque, index: usize) ?i64 {
        return switch (index) {
            0 => 42,
            2 => 30,
            3 => 100,
            else => null,
        };
    }
    fn getFloat(_: *anyopaque, _: usize) ?f64 {
        return null;
    }
    fn getText(_: *anyopaque, index: usize) ?[]const u8 {
        if (index == 1) return "Alice";
        return null;
    }
    fn getBlob(_: *anyopaque, _: usize) ?[]const u8 {
        return null;
    }
    fn getBool(_: *anyopaque, _: usize) ?bool {
        return null;
    }
    fn isNull(_: *anyopaque, _: usize) bool {
        return false;
    }
};

fn makeRow() driver.Row {
    return .{ .ptr = undefined, .vtable = &MockRow.vtable };
}

const User = struct {
    id: i64,
    name: []const u8,
    age: i64,
    score: i64,
};

const UserLite = struct {
    id: i64,
    age: i64,
    score: i64,
};

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    row: driver.Row,
};

fn benchScanSingle(allocator: std.mem.Allocator, io: std.Io) !Result {
    var ctx = ScanCtx{ .allocator = allocator, .row = makeRow() };
    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *ScanCtx = @ptrCast(@alignCast(ptr));
            const user = try sql_scan.scanRow(User, c.allocator, c.row);
            c.allocator.free(user.name);
        }
    }.body);
}

const ScanBatchCtx = struct {
    allocator: std.mem.Allocator,
    row: driver.Row,
    batch_size: usize,
};

fn benchScanBatch100(allocator: std.mem.Allocator, io: std.Io) !Result {
    var ctx = ScanBatchCtx{ .allocator = allocator, .row = makeRow(), .batch_size = 100 };
    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *ScanBatchCtx = @ptrCast(@alignCast(ptr));
            var i: usize = 0;
            while (i < c.batch_size) : (i += 1) {
                const user = try sql_scan.scanRow(User, c.allocator, c.row);
                c.allocator.free(user.name);
            }
        }
    }.body);
}

const MockRowLite = struct {
    pub const vtable = driver.Row.VTable{
        .columnCount = columnCount,
        .columnName = columnName,
        .getInt = getInt,
        .getFloat = getFloat,
        .getText = getText,
        .getBlob = getBlob,
        .getBool = getBool,
        .isNull = isNull,
    };

    fn columnCount(_: *anyopaque) usize {
        return 3;
    }
    fn columnName(_: *anyopaque, index: usize) []const u8 {
        const names = [_][]const u8{ "id", "age", "score" };
        return names[index];
    }
    fn getInt(_: *anyopaque, index: usize) ?i64 {
        return switch (index) {
            0 => 42,
            1 => 30,
            2 => 100,
            else => null,
        };
    }
    fn getFloat(_: *anyopaque, _: usize) ?f64 {
        return null;
    }
    fn getText(_: *anyopaque, _: usize) ?[]const u8 {
        return null;
    }
    fn getBlob(_: *anyopaque, _: usize) ?[]const u8 {
        return null;
    }
    fn getBool(_: *anyopaque, _: usize) ?bool {
        return null;
    }
    fn isNull(_: *anyopaque, _: usize) bool {
        return false;
    }
};

fn makeLiteRow() driver.Row {
    return .{ .ptr = undefined, .vtable = &MockRowLite.vtable };
}

const ScanBatchNoAllocCtx = struct {
    row: driver.Row,
    batch_size: usize,
};

fn benchScanBatch100NoAlloc(allocator: std.mem.Allocator, io: std.Io) !Result {
    _ = allocator;
    var ctx = ScanBatchNoAllocCtx{ .row = makeLiteRow(), .batch_size = 100 };
    return main.runForCtx(io, std.time.ns_per_s, &ctx, struct {
        fn body(ptr: *anyopaque) !void {
            const c: *ScanBatchNoAllocCtx = @ptrCast(@alignCast(ptr));
            var i: usize = 0;
            while (i < c.batch_size) : (i += 1) {
                _ = try sql_scan.scanRowNoAlloc(UserLite, c.row);
            }
        }
    }.body);
}

pub const benchmarks: []const Benchmark = &[_]Benchmark{
    .{ .name = "scan/single_entity", .run = benchScanSingle },
    .{ .name = "scan/batch_100", .run = benchScanBatch100 },
    .{ .name = "scan/batch_100_no_alloc", .run = benchScanBatch100NoAlloc },
};
