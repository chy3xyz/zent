const std = @import("std");
const Value = @import("builder.zig").Value;
const OwnedQuery = @import("builder.zig").OwnedQuery;
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
    /// The server detected a deadlock between concurrent transactions and
    /// aborted this one (PostgreSQL SQLSTATE 40P01, MySQL errno 1213). The
    /// whole transaction must be replayed; see `retryTx`.
    DeadlockDetected,
    /// The transaction could not be serialized against a concurrent commit
    /// (PostgreSQL SQLSTATE 40001). Produced only under SERIALIZABLE /
    /// REPEATABLE READ isolation; the whole transaction must be replayed.
    SerializationFailure,
    /// A lock (or the statement) exceeded the configured lock/statement
    /// timeout (PostgreSQL SQLSTATE 55P03, MySQL errno 1205, SQLite
    /// SQLITE_BUSY / SQLITE_LOCKED). The statement may succeed on retry once
    /// the competing transaction finishes.
    LockTimeout,
};

/// Returns true when `err` is transient and the operation may be retried.
///
/// These errors do not indicate a bad statement or bad data; they mean the
/// attempt lost a race (deadlock, serialization conflict, lock timeout) or the
/// connection dropped. For transaction-scoped errors the retry must replay the
/// whole transaction — use `retryTx` rather than retrying a single statement.
pub fn isRetryable(err: Error) bool {
    return isRetryableAny(err);
}

/// `anyerror`-accepting form of `isRetryable`, used by `retryTx` whose body
/// may surface errors outside `driver.Error`.
fn isRetryableAny(err: anyerror) bool {
    return switch (err) {
        error.DeadlockDetected,
        error.SerializationFailure,
        error.LockTimeout,
        error.ConnectionFailed,
        => true,
        else => false,
    };
}

/// Backoff policy for `retryTx`.
pub const RetryOpts = struct {
    /// Total attempts, including the first. `1` disables retrying.
    max_attempts: u32 = 3,
    /// Delay before the first retry; doubled on every subsequent retry.
    base_backoff_ms: u32 = 50,
    /// Upper bound for a single retry delay.
    max_backoff_ms: u32 = 1000,
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

    /// Look up a column's zero-based index by name (e.g. a `SelectExpr`
    /// alias). Returns null when no column carries that name.
    pub fn columnIndex(self: Row, name: []const u8) ?usize {
        var i: usize = 0;
        while (i < self.columnCount()) : (i += 1) {
            if (std.mem.eql(u8, self.columnName(i), name)) return i;
        }
        return null;
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

/// Read a clock into nanoseconds, or null when the syscall fails.
fn readClockNs(clock: std.c.CLOCK) ?i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(clock, &ts) != 0) return null;
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
}

pub fn monotonicNs() i64 {
    if (readClockNs(std.c.CLOCK.MONOTONIC)) |ns| return ns;
    // CLOCK_MONOTONIC is always available on the platforms this library
    // targets, but a hard `unreachable` here would be undefined behaviour in
    // ReleaseFast and would abort the process in ReleaseSafe. Degrade to the
    // wall clock (non-monotonic, so deadline arithmetic is approximate) and
    // say so rather than trapping.
    std.log.warn("clock_gettime(CLOCK_MONOTONIC) failed; timing falls back to the wall clock", .{});
    if (readClockNs(std.c.CLOCK.REALTIME)) |ns| return ns;
    // Both clocks failed: report 0 so deadlines computed from here still
    // compare consistently (a deadline is `now + budget`).
    return 0;
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

    /// Execute an `OwnedQuery` built by `Builder.takeQuery` /
    /// `Selector.takeQuery`. The query stays owned by the caller — `deinit`
    /// it after the returned `Rows` are consumed.
    pub fn queryOwned(self: Driver, q: OwnedQuery) !Rows {
        return self.vtable.query(self.ptr, null, q.sql, q.args);
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

fn sleepBackoffMs(ms: u64) void {
    if (ms == 0) return;
    var req = std.c.timespec{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&req, null);
}

fn backoffDelay(attempt: u32, opts: RetryOpts) u64 {
    var delay: u64 = opts.base_backoff_ms;
    var i: u32 = 1;
    while (i < attempt) : (i += 1) {
        delay = @min(delay *| 2, @as(u64, opts.max_backoff_ms));
    }
    return delay;
}

/// Run `body` inside a transaction, replaying the WHOLE transaction when an
/// attempt fails with a retryable error (`isRetryable`).
///
/// Retrying a single statement is not enough: PostgreSQL's 40001/40P01 and
/// MySQL's 1205/1213 abort the transaction, so every statement issued after
/// the failure is rejected until the transaction is rolled back. `retryTx`
/// therefore opens a fresh transaction per attempt.
///
/// `body` is invoked as `body(ctx, tx)` and runs statements through
/// `tx.exec` / `tx.query`; it must NOT call `tx.commit` / `tx.rollback` /
/// `tx.deinit` itself — the helper owns the transaction lifecycle. On success
/// the transaction is committed; on failure it is rolled back. `Tx.deinit` is
/// called exactly once per attempt (the driver contract), including attempts
/// that fail and attempts that are retried. Between retryable attempts the
/// helper sleeps with exponential backoff derived from `opts`.
///
/// Example:
///     fn transfer(ctx: *Ctx, tx: driver.Tx) anyerror!void {
///         _ = try tx.exec("UPDATE account SET bal = bal - 1 WHERE id = $1", &.{...});
///     }
///     try driver.retryTx(d, &ctx, transfer, .{ .max_attempts = 5 });
pub fn retryTx(d: Driver, ctx: anytype, body: anytype, opts: RetryOpts) anyerror!void {
    var attempt: u32 = 0;
    while (true) {
        attempt += 1;
        const tx = d.beginTx() catch |err| {
            if (isRetryableAny(err) and attempt < opts.max_attempts) {
                sleepBackoffMs(backoffDelay(attempt, opts));
                continue;
            }
            return err;
        };

        if (body(ctx, tx)) |_| {
            tx.commit() catch |err| {
                // A failed commit still requires exactly one deinit.
                tx.rollback() catch {};
                tx.deinit();
                if (isRetryableAny(err) and attempt < opts.max_attempts) {
                    sleepBackoffMs(backoffDelay(attempt, opts));
                    continue;
                }
                return err;
            };
            tx.deinit();
            return;
        } else |err| {
            tx.rollback() catch {};
            tx.deinit();
            if (isRetryableAny(err) and attempt < opts.max_attempts) {
                sleepBackoffMs(backoffDelay(attempt, opts));
                continue;
            }
            return err;
        }
    }
}

const MockTxState = struct {
    begin_calls: u32 = 0,
    commit_calls: u32 = 0,
    rollback_calls: u32 = 0,
    deinit_calls: u32 = 0,
    body_calls: u32 = 0,
    fail_times: u32 = 0,
    fail_with: anyerror = error.DeadlockDetected,
};

fn mockExec(_: *anyopaque, _: ?*const ExecutionContext, _: []const u8, _: []const Value) Error!Result {
    return .{ .rows_affected = 0, .last_insert_id = null };
}

fn mockQuery(_: *anyopaque, _: ?*const ExecutionContext, _: []const u8, _: []const Value) Error!Rows {
    return error.QueryFailed;
}

fn mockCommit(ptr: *anyopaque) Error!void {
    const s: *MockTxState = @ptrCast(@alignCast(ptr));
    s.commit_calls += 1;
}

fn mockRollback(ptr: *anyopaque) Error!void {
    const s: *MockTxState = @ptrCast(@alignCast(ptr));
    s.rollback_calls += 1;
}

fn mockTxDeinit(ptr: *anyopaque) void {
    const s: *MockTxState = @ptrCast(@alignCast(ptr));
    s.deinit_calls += 1;
}

const mock_vtable = Driver.VTable{
    .exec = mockExec,
    .query = mockQuery,
    .beginTx = struct {
        fn f(ptr: *anyopaque) Error!Tx {
            const s: *MockTxState = @ptrCast(@alignCast(ptr));
            s.begin_calls += 1;
            return Tx{
                .inner = .{ .ptr = ptr, .vtable = &mock_vtable },
                .commitFn = mockCommit,
                .rollbackFn = mockRollback,
                .deinitFn = mockTxDeinit,
                .ptr = ptr,
            };
        }
    }.f,
    .close = struct {
        fn f(_: *anyopaque) void {}
    }.f,
    .dialect = struct {
        fn f(_: *anyopaque) Dialect {
            return Dialect.sqlite;
        }
    }.f,
    .ping = struct {
        fn f(_: *anyopaque) Error!void {}
    }.f,
    .inTransaction = struct {
        fn f(_: *anyopaque) bool {
            return false;
        }
    }.f,
    .beginSavepoint = struct {
        fn f(_: *anyopaque, _: []const u8) Error!Tx {
            return error.QueryFailed;
        }
    }.f,
};

test "isRetryable classifies transient errors" {
    try std.testing.expect(isRetryable(error.DeadlockDetected));
    try std.testing.expect(isRetryable(error.SerializationFailure));
    try std.testing.expect(isRetryable(error.LockTimeout));
    try std.testing.expect(isRetryable(error.ConnectionFailed));
    // Non-transient: a duplicate key or a syntax error will fail again.
    try std.testing.expect(!isRetryable(error.UniqueViolation));
    try std.testing.expect(!isRetryable(error.ExecFailed));
    try std.testing.expect(!isRetryable(error.OutOfMemory));
}

fn bodyFailFirst(state: *MockTxState, tx: Tx) anyerror!void {
    _ = tx;
    state.body_calls += 1;
    if (state.body_calls <= state.fail_times) return state.fail_with;
}

test "retryTx replays the whole transaction on a retryable error" {
    var state = MockTxState{ .fail_times = 1, .fail_with = error.DeadlockDetected };
    const drv = Driver{ .ptr = &state, .vtable = &mock_vtable };

    try retryTx(drv, &state, bodyFailFirst, .{ .max_attempts = 3, .base_backoff_ms = 0, .max_backoff_ms = 0 });

    try std.testing.expectEqual(@as(u32, 2), state.body_calls);
    try std.testing.expectEqual(@as(u32, 2), state.begin_calls);
    // First attempt rolled back, second committed.
    try std.testing.expectEqual(@as(u32, 1), state.rollback_calls);
    try std.testing.expectEqual(@as(u32, 1), state.commit_calls);
    // deinit exactly once per attempt (the hard driver contract).
    try std.testing.expectEqual(@as(u32, 2), state.deinit_calls);
}

test "retryTx does not retry a non-retryable error" {
    var state = MockTxState{ .fail_times = 5, .fail_with = error.UniqueViolation };
    const drv = Driver{ .ptr = &state, .vtable = &mock_vtable };

    try std.testing.expectError(
        error.UniqueViolation,
        retryTx(drv, &state, bodyFailFirst, .{ .max_attempts = 3, .base_backoff_ms = 0, .max_backoff_ms = 0 }),
    );

    try std.testing.expectEqual(@as(u32, 1), state.body_calls);
    try std.testing.expectEqual(@as(u32, 1), state.begin_calls);
    try std.testing.expectEqual(@as(u32, 1), state.rollback_calls);
    try std.testing.expectEqual(@as(u32, 0), state.commit_calls);
    try std.testing.expectEqual(@as(u32, 1), state.deinit_calls);
}

test "retryTx stops after max_attempts and returns the last error" {
    var state = MockTxState{ .fail_times = 100, .fail_with = error.LockTimeout };
    const drv = Driver{ .ptr = &state, .vtable = &mock_vtable };

    try std.testing.expectError(
        error.LockTimeout,
        retryTx(drv, &state, bodyFailFirst, .{ .max_attempts = 3, .base_backoff_ms = 0, .max_backoff_ms = 0 }),
    );

    try std.testing.expectEqual(@as(u32, 3), state.begin_calls);
    try std.testing.expectEqual(@as(u32, 3), state.deinit_calls);
    try std.testing.expectEqual(@as(u32, 0), state.commit_calls);
}
