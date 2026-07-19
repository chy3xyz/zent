const std = @import("std");
const Value = @import("builder.zig").Value;
const Dialect = @import("dialect.zig").Dialect;

pub const Result = struct {
    rows_affected: usize,
    last_insert_id: ?i64,
};

/// Unified error set returned by all driver implementations.
pub const Error = error{
    OutOfMemory,
    ConnectionFailed,
    ExecFailed,
    QueryFailed,
    TxFailed,
    PingFailed,
    BindFailed,
    PrepareFailed,
    ProtocolError,
    DriverFailed,
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
        /// Optional accessor for per-iteration errors that are not reported
        /// through `next()` returning a Row (e.g. MySQL fetch/truncation).
        nextError: ?*const fn (ptr: *anyopaque) ?anyerror = null,
    };

    pub fn next(self: Rows) ?Row {
        return self.vtable.next(self.ptr);
    }

    pub fn deinit(self: Rows) void {
        self.vtable.deinit(self.ptr);
    }

    /// Returns the last per-iteration error, if the driver exposes one.
    /// Call after `next()` returns null to distinguish EOF from fetch failures.
    pub fn nextError(self: Rows) ?anyerror {
        const f = self.vtable.nextError orelse return null;
        return f(self.ptr);
    }
};

/// Transaction handle.
///
/// The caller MUST call `deinit` exactly once, regardless of whether
/// `commit` or `rollback` was used. After deinit, the handle is invalid.
pub const Tx = struct {
    inner: Driver,
    commitFn: *const fn (ptr: *anyopaque) Error!void,
    rollbackFn: *const fn (ptr: *anyopaque) Error!void,
    deinitFn: *const fn (ptr: *anyopaque) void,
    ptr: *anyopaque,

    pub fn commit(self: Tx) !void {
        return self.commitFn(self.ptr);
    }

    pub fn rollback(self: Tx) !void {
        return self.rollbackFn(self.ptr);
    }

    pub fn deinit(self: Tx) void {
        self.deinitFn(self.ptr);
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
        exec: *const fn (ptr: *anyopaque, query: []const u8, args: []const Value) Error!Result,
        query: *const fn (ptr: *anyopaque, query: []const u8, args: []const Value) Error!Rows,
        beginTx: *const fn (ptr: *anyopaque) Error!Tx,
        close: *const fn (ptr: *anyopaque) void,
        dialect: *const fn (ptr: *anyopaque) Dialect,
        ping: *const fn (ptr: *anyopaque) Error!void,
        /// Returns true if the connection currently has an active transaction.
        inTransaction: *const fn (ptr: *anyopaque) bool,
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

    pub fn ping(self: Driver) !void {
        return self.vtable.ping(self.ptr);
    }

    pub fn inTransaction(self: Driver) bool {
        return self.vtable.inTransaction(self.ptr);
    }
};
