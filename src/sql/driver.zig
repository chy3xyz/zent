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
    /// The pool has no idle connections and has reached its maximum size.
    PoolExhausted,
    /// The pool has been shut down and cannot serve new requests.
    PoolClosed,
    ConnectionFailed,
    ExecFailed,
    QueryFailed,
    TxFailed,
    PingFailed,
    BindFailed,
    PrepareFailed,
    ProtocolError,
    DriverFailed,
    /// Retained for source compatibility; pooled operations no longer synthesize
    /// timeout errors after a driver operation has already completed.
    QueryTimeout,
    /// An UPDATE or DELETE affected zero rows because the optimistic-lock
    /// version value did not match the current row.
    OptimisticLockConflict,
    /// A UNIQUE index/constraint was violated (duplicate key).
    UniqueViolation,
    /// A NOT NULL constraint was violated.
    NotNullViolation,
    /// A foreign key constraint was violated.
    ForeignKeyViolation,
};

/// A single database row exposed for scanning.
pub const Row = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        columnCount: *const fn (ptr: *anyopaque) usize,
        columnName: *const fn (ptr: *anyopaque, index: usize) []const u8,
        getBool: *const fn (ptr: *anyopaque, index: usize) ?bool,
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

    pub fn getBool(self: Row, index: usize) ?bool {
        return self.vtable.getBool(self.ptr, index);
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

    pub const GetError = error{NullColumn};

    /// Error-union variant of `getBool`. Returns `error.NullColumn` when the
    /// column is NULL.
    pub fn tryGetBool(self: Row, index: usize) GetError!bool {
        return self.getBool(index) orelse error.NullColumn;
    }

    /// Error-union variant of `getInt`. Returns `error.NullColumn` when the
    /// column is NULL.
    pub fn tryGetInt(self: Row, index: usize) GetError!i64 {
        return self.getInt(index) orelse error.NullColumn;
    }

    /// Error-union variant of `getFloat`. Returns `error.NullColumn` when the
    /// column is NULL.
    pub fn tryGetFloat(self: Row, index: usize) GetError!f64 {
        return self.getFloat(index) orelse error.NullColumn;
    }

    /// Error-union variant of `getText`. Returns `error.NullColumn` when the
    /// column is NULL.
    pub fn tryGetText(self: Row, index: usize) GetError![]const u8 {
        return self.getText(index) orelse error.NullColumn;
    }

    /// Error-union variant of `getBlob`. Returns `error.NullColumn` when the
    /// column is NULL.
    pub fn tryGetBlob(self: Row, index: usize) GetError![]const u8 {
        return self.getBlob(index) orelse error.NullColumn;
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
        nextError: ?*const fn (ptr: *anyopaque) ?Error = null,
    };

    pub fn next(self: Rows) ?Row {
        return self.vtable.next(self.ptr);
    }

    pub fn deinit(self: Rows) void {
        self.vtable.deinit(self.ptr);
    }

    /// Returns the last per-iteration error, if the driver exposes one.
    /// Call after `next()` returns null to distinguish EOF from fetch failures.
    pub fn nextError(self: Rows) ?Error {
        const f = self.vtable.nextError orelse return null;
        return f(self.ptr);
    }
};

pub fn monotonicNs() i64 {
    var ts: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    if (rc != 0) unreachable;
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
}

/// Execution context carried by driver operations.
///
/// Currently holds an absolute monotonic deadline; drivers may use it to
/// bound waiting for locks, network I/O, or query execution time.
pub const ExecutionContext = struct {
    deadline_ns: ?i64 = null,

    pub fn remainingMs(self: ExecutionContext) ?u32 {
        const d = self.deadline_ns orelse return null;
        const now = monotonicNs();
        if (now >= d) return 0;
        const remaining = @as(u64, @intCast(d - now)) / std.time.ns_per_ms;
        return if (remaining > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(remaining);
    }
};

test "ExecutionContext.remainingMs around deadline" {
    const past = monotonicNs() - 1_000_000;
    const ctx_past = ExecutionContext{ .deadline_ns = past };
    try std.testing.expectEqual(@as(?u32, 0), ctx_past.remainingMs());

    const future = monotonicNs() + 10 * std.time.ns_per_ms;
    const ctx_future = ExecutionContext{ .deadline_ns = future };
    const remaining = ctx_future.remainingMs().?;
    try std.testing.expect(remaining <= 10);

    const ctx_null = ExecutionContext{ .deadline_ns = null };
    try std.testing.expectEqual(@as(?u32, null), ctx_null.remainingMs());
}

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
    savepointFn: ?*const fn (ptr: *anyopaque, name: []const u8) Error!void = null,
    savepointRollbackFn: ?*const fn (ptr: *anyopaque, name: []const u8) Error!void = null,
    savepointReleaseFn: ?*const fn (ptr: *anyopaque, name: []const u8) Error!void = null,

    pub fn commit(self: Tx) !void {
        return self.commitFn(self.ptr);
    }

    pub fn rollback(self: Tx) !void {
        return self.rollbackFn(self.ptr);
    }

    pub fn deinit(self: Tx) void {
        self.deinitFn(self.ptr);
    }

    pub fn savepoint(self: Tx, name: []const u8) !void {
        if (self.savepointFn) |f| return f(self.ptr, name);
        return error.SavepointUnsupported;
    }

    pub fn savepointRollback(self: Tx, name: []const u8) !void {
        if (self.savepointRollbackFn) |f| return f(self.ptr, name);
        return error.SavepointUnsupported;
    }

    pub fn savepointRelease(self: Tx, name: []const u8) !void {
        if (self.savepointReleaseFn) |f| return f(self.ptr, name);
        return error.SavepointUnsupported;
    }

    pub fn exec(self: Tx, sql: []const u8, args: []const Value) !Result {
        return self.inner.exec(sql, args);
    }

    pub fn query(self: Tx, sql: []const u8, args: []const Value) !Rows {
        return self.inner.query(sql, args);
    }

    pub fn execCtx(self: Tx, ctx: ?*const ExecutionContext, sql: []const u8, args: []const Value) !Result {
        return self.inner.execCtx(ctx, sql, args);
    }

    pub fn queryCtx(self: Tx, ctx: ?*const ExecutionContext, sql: []const u8, args: []const Value) !Rows {
        return self.inner.queryCtx(ctx, sql, args);
    }
};

/// Database driver abstraction.
pub const Driver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        exec: *const fn (ptr: *anyopaque, ctx: ?*const ExecutionContext, query: []const u8, args: []const Value) Error!Result,
        query: *const fn (ptr: *anyopaque, ctx: ?*const ExecutionContext, query: []const u8, args: []const Value) Error!Rows,
        beginTx: *const fn (ptr: *anyopaque) Error!Tx,
        close: *const fn (ptr: *anyopaque) void,
        dialect: *const fn (ptr: *anyopaque) Dialect,
        ping: *const fn (ptr: *anyopaque) Error!void,
        /// Returns true if the connection currently has an active transaction.
        inTransaction: *const fn (ptr: *anyopaque) bool,
        beginSavepoint: *const fn (ptr: *anyopaque, name: []const u8) Error!Tx,
    };

    pub fn exec(self: Driver, query_sql: []const u8, args: []const Value) !Result {
        return self.vtable.exec(self.ptr, null, query_sql, args);
    }

    pub fn query(self: Driver, query_sql: []const u8, args: []const Value) !Rows {
        return self.vtable.query(self.ptr, null, query_sql, args);
    }

    pub fn execCtx(self: Driver, ctx: ?*const ExecutionContext, query_sql: []const u8, args: []const Value) !Result {
        return self.vtable.exec(self.ptr, ctx, query_sql, args);
    }

    pub fn queryCtx(self: Driver, ctx: ?*const ExecutionContext, query_sql: []const u8, args: []const Value) !Rows {
        return self.vtable.query(self.ptr, ctx, query_sql, args);
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

    pub fn beginSavepoint(self: Driver, name: []const u8) !Tx {
        return self.vtable.beginSavepoint(self.ptr, name);
    }
};
