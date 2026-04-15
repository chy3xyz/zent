const std = @import("std");
const Value = @import("builder.zig").Value;
const Dialect = @import("dialect.zig").Dialect;

pub const Result = struct {
    rows_affected: usize,
    last_insert_id: ?i64,
};

/// A single database row exposed for scanning.
pub const Row = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        columnCount: *const fn (ptr: *anyopaque) usize,
        columnName: *const fn (ptr: *anyopaque, index: usize) []const u8,
        getInt: *const fn (ptr: *anyopaque, index: usize) ?i64,
        getFloat: *const fn (ptr: *anyopaque, index: usize) ?f64,
        getText: *const fn (ptr: *anyopaque, index: usize) ?[]const u8,
        getBlob: *const fn (ptr: *anyopaque, index: usize) ?[]const u8,
        isNull: *const fn (ptr: *anyopaque, index: usize) bool,
    };

    pub fn columnCount(self: Row) usize {
        return self.vtable.columnCount(self.ptr);
    }

    pub fn columnName(self: Row, index: usize) []const u8 {
        return self.vtable.columnName(self.ptr, index);
    }

    pub fn getInt(self: Row, index: usize) ?i64 {
        return self.vtable.getInt(self.ptr, index);
    }

    pub fn getFloat(self: Row, index: usize) ?f64 {
        return self.vtable.getFloat(self.ptr, index);
    }

    pub fn getText(self: Row, index: usize) ?[]const u8 {
        return self.vtable.getText(self.ptr, index);
    }

    pub fn getBlob(self: Row, index: usize) ?[]const u8 {
        return self.vtable.getBlob(self.ptr, index);
    }

    pub fn isNull(self: Row, index: usize) bool {
        return self.vtable.isNull(self.ptr, index);
    }
};

/// Iterator over query results.
pub const Rows = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (ptr: *anyopaque) ?Row,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn next(self: Rows) ?Row {
        return self.vtable.next(self.ptr);
    }

    pub fn deinit(self: Rows) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Transaction handle.
pub const Tx = struct {
    inner: Driver,
    commitFn: *const fn (ptr: *anyopaque) anyerror!void,
    rollbackFn: *const fn (ptr: *anyopaque) anyerror!void,
    ptr: *anyopaque,

    pub fn commit(self: Tx) !void {
        return self.commitFn(self.ptr);
    }

    pub fn rollback(self: Tx) !void {
        return self.rollbackFn(self.ptr);
    }

    pub fn exec(self: Tx, sql: []const u8, args: []const Value) !Result {
        return self.inner.exec(sql, args);
    }

    pub fn query(self: Tx, sql: []const u8, args: []const Value) !Rows {
        return self.inner.query(sql, args);
    }
};

/// Database driver abstraction.
pub const Driver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        exec: *const fn (ptr: *anyopaque, query: []const u8, args: []const Value) anyerror!Result,
        query: *const fn (ptr: *anyopaque, query: []const u8, args: []const Value) anyerror!Rows,
        beginTx: *const fn (ptr: *anyopaque) anyerror!Tx,
        close: *const fn (ptr: *anyopaque) void,
        dialect: *const fn (ptr: *anyopaque) Dialect,
    };

    pub fn exec(self: Driver, query_sql: []const u8, args: []const Value) !Result {
        return self.vtable.exec(self.ptr, query_sql, args);
    }

    pub fn query(self: Driver, query_sql: []const u8, args: []const Value) !Rows {
        return self.vtable.query(self.ptr, query_sql, args);
    }

    pub fn beginTx(self: Driver) !Tx {
        return self.vtable.beginTx(self.ptr);
    }

    pub fn close(self: Driver) void {
        self.vtable.close(self.ptr);
    }

    pub fn dialect(self: Driver) Dialect {
        return self.vtable.dialect(self.ptr);
    }
};
