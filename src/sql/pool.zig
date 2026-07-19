//! Generic, mutex-backed database connection pool.
//!
//! The pool is driver-agnostic: `ConnPool(D)` stores instances of driver
//! struct `D` (e.g. `SQLiteDriver`) and exposes the same `driver.Driver`
//! interface via `pool.asDriver()`, so it can be passed to generated clients
//! without code changes.

const std = @import("std");
const assert = std.debug.assert;
const driver = @import("driver.zig");
const Dialect = @import("dialect.zig").Dialect;
const Value = @import("builder.zig").Value;

extern fn time(time_t: [*c]c_long) c_long;

/// Current Unix timestamp in seconds. Uses libc `time()` because Zig 0.17
/// removed `unixTimestamp()`.
fn unixTimestamp() i64 {
    return @as(i64, @intCast(time(null)));
}

/// Errors returned by the connection pool.
pub const Error = error{
    PoolClosed,
    PoolExhausted,
};

/// A mutex-backed connection pool for driver type `D`.
///
/// `D` must provide:
///   - `asDriver(self: *D) driver.Driver`
///   - `close(self: *D) void`
///
/// Construction of `D` instances is supplied by the caller via `Options.connect`.
pub fn ConnPool(comptime D: type) type {
    comptime {
        if (!std.meta.hasFn(D, "asDriver")) {
            @compileError(@typeName(D) ++ " must provide `asDriver()` to be pooled");
        }
        if (!std.meta.hasFn(D, "close")) {
            @compileError(@typeName(D) ++ " must provide `close()` to be pooled");
        }
    }

    return struct {
        const Self = @This();

        /// Factory used to create a new `D` instance.
        pub const ConnectFn = *const fn (allocator: std.mem.Allocator) anyerror!D;

        /// Optional metrics callbacks. Borrow/release callbacks run while the
        /// pool mutex is held; slow-query callbacks run after the driver call.
        /// All callbacks should be fast and non-blocking.
        pub const Metrics = struct {
            /// Called when a connection is successfully borrowed.
            /// `wait_ms` is the total time spent waiting for a connection.
            onBorrow: ?*const fn (ctx: ?*anyopaque, wait_ms: u32) void = null,
            /// Called when a connection is released back to the pool.
            onRelease: ?*const fn (ctx: ?*anyopaque) void = null,
            /// Called when a caller starts waiting for an available connection.
            onWait: ?*const fn (ctx: ?*anyopaque) void = null,
            /// Called when borrow fails with a pool-level or connection error.
            onError: ?*const fn (ctx: ?*anyopaque, err: anyerror) void = null,
            /// Called after a query or exec reaches the configured slow-query threshold.
            onSlowQuery: ?*const fn (ctx: ?*anyopaque, sql: []const u8, elapsed_ms: u64) void = null,
            /// User context passed to every callback.
            context: ?*anyopaque = null,
        };

        pub const Options = struct {
            /// Initial number of connections opened during `init`.
            min_connections: usize = 1,
            /// Hard upper bound on total connections.
            max_connections: usize = 8,
            /// Run `ping()` before handing out a connection.
            health_check_on_borrow: bool = true,
            /// Factory that opens a new connection.
            connect: ConnectFn,
            /// I/O abstraction used for blocking synchronization. When omitted,
            /// the global single-threaded `Io` instance is used. Applications
            /// that need cross-thread blocking waits must provide an explicit
            /// `std.Io` (e.g. `std.Io.Threaded.init(...).io()`).
            io: ?std.Io = null,
            /// Maximum time in milliseconds to wait for a connection when the
            /// DEPRECATED: replaced by `max_retries` + `retry_backoff_ms`.
            /// pool is exhausted. Zero means non-blocking (returns
            /// `error.PoolExhausted` immediately).
            max_wait_ms: u32 = 0,
            /// Elapsed time in milliseconds at which a pooled query/exec is
            /// reported through `Metrics.onSlowQuery`. Zero disables reporting.
            slow_query_threshold_ms: u32 = 0,
            /// Max retry attempts for borrowing a connection. 0 = no retry.
            max_retries: u32 = 3,
            /// Retry backoff base in milliseconds.
            retry_backoff_ms: u32 = 100,
            /// Max idle time for a connection in seconds. 0 = permanent.
            max_idle_secs: u32 = 300,
            /// Max total lifetime for a connection in seconds. 0 = permanent.
            max_lifetime_secs: u32 = 3600,
            /// Optional metrics callbacks.
            metrics: Metrics = .{},
        };

        /// A pooled connection entry wrapping the driver with bookkeeping metadata.
        pub const PooledEntry = struct {
            /// The actual driver instance.
            conn: D,
            /// Unix timestamp when this entry was created.
            created_at: i64,
            /// Unix timestamp when the connection was last released to the pool,
            /// or null when currently borrowed.
            idle_since: ?i64,
        };

        allocator: std.mem.Allocator,
        connect: ConnectFn,
        options: Options,
        dialect: Dialect,
        io: std.Io,
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        all: std.ArrayListUnmanaged(PooledEntry) = .empty,
        available: std.ArrayListUnmanaged(*PooledEntry) = .empty,
        closed: bool = false,

        /// Open a pool and warm up `min_connections`.
        pub fn init(allocator: std.mem.Allocator, options: Options) !Self {
            assert(options.min_connections > 0);
            assert(options.min_connections <= options.max_connections);

            const io = options.io orelse std.Io.Threaded.global_single_threaded.io();

            var self = Self{
                .allocator = allocator,
                .connect = options.connect,
                .options = options,
                .dialect = Dialect.sqlite, // overwritten after first conn
                .io = io,
            };
            errdefer self.deinit();

            try self.all.ensureTotalCapacity(allocator, options.max_connections);
            try self.available.ensureTotalCapacity(allocator, options.max_connections);

            // Warm up the pool.
            for (0..options.min_connections) |_| {
                try self.addConnection();
            }

            // Cache dialect from the first connection.
            self.dialect = self.all.items[0].conn.asDriver().dialect();

            return self;
        }

        /// Close every connection and free pool bookkeeping.
        pub fn deinit(self: *Self) void {
            const io = self.io;
            self.mutex.lockUncancelable(io);
            self.closed = true;
            // Wake any waiters so they observe the closed state.
            self.cond.broadcast(io);
            for (self.all.items) |*entry| {
                entry.conn.close();
            }
            self.all.deinit(self.allocator);
            self.available.deinit(self.allocator);
            self.mutex.unlock(io);
            self.* = undefined;
        }

        fn addConnection(self: *Self) !void {
            var conn = try self.connect(self.allocator);
            const ptr = blk: {
                errdefer conn.close(); // only runs if all.addOne fails
                const p = try self.all.addOne(self.allocator);
                break :blk p;
            };
            ptr.* = .{
                .conn = conn,
                .created_at = unixTimestamp(),
                .idle_since = unixTimestamp(),
            };
            errdefer {
                _ = self.all.pop(); // remove dangling pointer
                conn.close();
            }
            try self.available.append(self.allocator, ptr);
        }

        /// Close a connection and remove it from the pool.
        /// The caller must hold `self.mutex`.
        fn closeConnection(self: *Self, entry: *PooledEntry) void {
            entry.conn.close();
            const idx = for (self.all.items, 0..) |*item, i| {
                if (item == entry) break i;
            } else unreachable;

            const last = &self.all.items[self.all.items.len - 1];
            if (last != entry) {
                // `swapRemove` moves `last` to `idx`. Fix any available pointer
                // that still references `last`.
                for (self.available.items) |*avail| {
                    if (avail.* == last) {
                        avail.* = entry;
                    }
                }
            }
            _ = self.all.swapRemove(idx);
        }

        /// Non-blocking borrow attempt. Returns a pooled entry or null when
        /// the pool is exhausted. The caller must hold `self.mutex`.
        fn tryBorrowNoLock(self: *Self) ?*PooledEntry {
            while (true) {
                const entry = self.available.pop() orelse {
                    if (self.all.items.len < self.options.max_connections) {
                        // Open a new connection.
                        var new_conn = self.connect(self.allocator) catch return null;
                        const ptr = blk: {
                            errdefer new_conn.close();
                            const p = self.all.addOne(self.allocator) catch {
                                new_conn.close();
                                return null;
                            };
                            break :blk p;
                        };
                        ptr.* = .{
                            .conn = new_conn,
                            .created_at = unixTimestamp(),
                            .idle_since = null,
                        };
                        return ptr;
                    }
                    return null;
                };

                // Idle eviction: if the connection has been idle too long, close
                // it and try the next one.
                if (self.options.max_idle_secs > 0) {
                    if (entry.idle_since) |idle_since| {
                        const idle_secs = unixTimestamp() - idle_since;
                        if (idle_secs > self.options.max_idle_secs) {
                            self.closeConnection(entry);
                            continue;
                        }
                    }
                }

                // Health check before handing out.
                if (self.options.health_check_on_borrow) {
                    entry.conn.asDriver().ping() catch {
                        // Connection is dead; drop it and try the next one.
                        self.closeConnection(entry);
                        continue;
                    };
                }

                // Mark as borrowed (no longer idle).
                entry.idle_since = null;
                return entry;
            }
        }

        /// Borrow a connection from the pool.
        ///
        /// Retries up to `max_retries` times with linear backoff when the
        /// pool is exhausted. Performs idle eviction and health checks on each
        /// borrow attempt.
        pub fn borrow(self: *Self) !*D {
            const io = self.io;
            var attempt: u32 = 0;
            while (true) : (attempt += 1) {
                {
                    self.mutex.lockUncancelable(io);
                    defer self.mutex.unlock(io);

                    if (self.closed) return error.PoolClosed;

                    if (self.tryBorrowNoLock()) |entry| {
                        if (self.options.metrics.onBorrow) |cb| cb(self.options.metrics.context, 0);
                        return &entry.conn;
                    }
                }

                if (attempt >= self.options.max_retries) break;
                const backoff_ms: i64 = @as(i64, self.options.retry_backoff_ms) * (@as(i64, attempt) + 1);
                self.io.sleep(std.Io.Duration.fromMilliseconds(backoff_ms), .awake) catch {};
            }

            if (self.options.metrics.onError) |cb| cb(self.options.metrics.context, error.PoolExhausted);
            return error.PoolExhausted;
        }

        /// Return a borrowed connection to the pool.
        pub fn release(self: *Self, conn: *D) void {
            const entry: *PooledEntry = @fieldParentPtr("conn", conn);
            const io = self.io;
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.closed) return;

            // Verify the connection still belongs to the pool.
            const found = for (self.all.items) |*item| {
                if (item == entry) break true;
            } else false;
            if (!found) return;

            // Transaction leak protection: if the connection was returned with
            // an active transaction, roll it back before returning it to the
            // pool. Ignore errors because the transaction may already be aborted.
            if (conn.asDriver().inTransaction()) {
                _ = conn.asDriver().exec("ROLLBACK", &.{}) catch {};
                // MySQL tracks transaction state client-side; clear the stale
                // flag after a successful rollback attempt.
                if (@hasField(D, "in_tx")) {
                    conn.in_tx = false;
                }
            }

            // Max lifetime eviction: close connections that have lived too long.
            if (self.options.max_lifetime_secs > 0) {
                const age_secs = unixTimestamp() - entry.created_at;
                if (age_secs > self.options.max_lifetime_secs) {
                    self.closeConnection(entry);
                    self.cond.signal(io);
                    if (self.options.metrics.onRelease) |cb| cb(self.options.metrics.context);
                    return;
                }
            }

            self.available.append(self.allocator, entry) catch {
                // If bookkeeping fails, drop the connection.
                self.closeConnection(entry);
            };
            entry.idle_since = unixTimestamp();
            self.cond.signal(io);

            if (self.options.metrics.onRelease) |cb| cb(self.options.metrics.context);
        }

        /// Return a `driver.Driver` view of this pool.
        ///
        /// The returned handle borrows a connection per operation and returns
        /// it automatically. Transactions keep a connection checked out until
        /// `Tx.deinit` is called.
        pub fn asDriver(self: *Self) driver.Driver {
            return .{
                .ptr = self,
                .vtable = &driver_vtable,
            };
        }

        fn borrowForDriver(self: *Self) driver.Error!*D {
            return self.borrow();
        }

        const PooledTx = struct {
            pool: *Self,
            conn: *D,
            tx: driver.Tx,
            finished: bool = false,
        };

        fn pooledCommit(ptr: *anyopaque) driver.Error!void {
            const wrapper: *PooledTx = @ptrCast(@alignCast(ptr));
            if (wrapper.finished) return;
            try wrapper.tx.commit();
            wrapper.finished = true;
        }

        fn pooledRollback(ptr: *anyopaque) driver.Error!void {
            const wrapper: *PooledTx = @ptrCast(@alignCast(ptr));
            if (wrapper.finished) return;
            try wrapper.tx.rollback();
            wrapper.finished = true;
        }

        fn pooledTxDeinit(ptr: *anyopaque) void {
            const wrapper: *PooledTx = @ptrCast(@alignCast(ptr));
            wrapper.tx.deinit();
            wrapper.pool.release(wrapper.conn);
            wrapper.pool.allocator.destroy(wrapper);
        }

        fn driverExec(ptr: *anyopaque, query_sql: []const u8, args: []const Value) driver.Error!driver.Result {
            const pool: *Self = @ptrCast(@alignCast(ptr));
            const conn = try pool.borrowForDriver();
            defer pool.release(conn);
            if (pool.options.slow_query_threshold_ms > 0) {
                const start = std.Io.Clock.Timestamp.now(pool.io, .awake);
                const result = conn.asDriver().exec(query_sql, args);
                const elapsed_ms: u64 = @intCast(start.untilNow(pool.io).raw.toMilliseconds());
                if (elapsed_ms >= pool.options.slow_query_threshold_ms) {
                    if (pool.options.metrics.onSlowQuery) |cb| {
                        cb(pool.options.metrics.context, query_sql, elapsed_ms);
                    }
                }
                return result;
            }
            return conn.asDriver().exec(query_sql, args);
        }

        fn driverQuery(ptr: *anyopaque, query_sql: []const u8, args: []const Value) driver.Error!driver.Rows {
            const pool: *Self = @ptrCast(@alignCast(ptr));
            const conn = try pool.borrowForDriver();
            defer pool.release(conn);
            if (pool.options.slow_query_threshold_ms > 0) {
                const start = std.Io.Clock.Timestamp.now(pool.io, .awake);
                const result = conn.asDriver().query(query_sql, args);
                const elapsed_ms: u64 = @intCast(start.untilNow(pool.io).raw.toMilliseconds());
                if (elapsed_ms >= pool.options.slow_query_threshold_ms) {
                    if (pool.options.metrics.onSlowQuery) |cb| {
                        cb(pool.options.metrics.context, query_sql, elapsed_ms);
                    }
                }
                return result;
            }
            return conn.asDriver().query(query_sql, args);
        }

        fn driverBeginTx(ptr: *anyopaque) driver.Error!driver.Tx {
            const pool: *Self = @ptrCast(@alignCast(ptr));
            const conn = try pool.borrowForDriver();
            errdefer pool.release(conn);

            const tx = try conn.asDriver().beginTx();
            errdefer tx.deinit();

            const wrapper = try pool.allocator.create(PooledTx);
            errdefer pool.allocator.destroy(wrapper);
            wrapper.* = .{
                .pool = pool,
                .conn = conn,
                .tx = tx,
            };

            return .{
                .inner = tx.inner,
                .commitFn = pooledCommit,
                .rollbackFn = pooledRollback,
                .deinitFn = pooledTxDeinit,
                .ptr = wrapper,
            };
        }

        fn driverClose(ptr: *anyopaque) void {
            const pool: *Self = @ptrCast(@alignCast(ptr));
            pool.deinit();
        }

        fn driverDialect(ptr: *anyopaque) Dialect {
            // Cached during init; no need to borrow a connection.
            const pool: *Self = @ptrCast(@alignCast(ptr));
            return pool.dialect;
        }

        fn driverPing(ptr: *anyopaque) driver.Error!void {
            const pool: *Self = @ptrCast(@alignCast(ptr));
            const conn = try pool.borrowForDriver();
            defer pool.release(conn);
            return conn.asDriver().ping();
        }

        fn driverInTransaction(ptr: *anyopaque) bool {
            const pool: *Self = @ptrCast(@alignCast(ptr));
            const conn = pool.borrow() catch return false;
            defer pool.release(conn);
            return conn.asDriver().inTransaction();
        }

        const driver_vtable = driver.Driver.VTable{
            .exec = driverExec,
            .query = driverQuery,
            .beginTx = driverBeginTx,
            .close = driverClose,
            .dialect = driverDialect,
            .ping = driverPing,
            .inTransaction = driverInTransaction,
        };
    };
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "ConnPool warms up and reuses connections" {
    const SQLiteDriver = @import("sqlite.zig").SQLiteDriver;
    const allocator = std.testing.allocator;

    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                return SQLiteDriver.open(a, ":memory:");
            }
        }.f,
        .min_connections = 2,
        .max_connections = 4,
    });
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 2), pool.all.items.len);
    try std.testing.expectEqual(@as(usize, 2), pool.available.items.len);

    const c1 = try pool.borrow();
    try std.testing.expectEqual(@as(usize, 1), pool.available.items.len);
    pool.release(c1);
    try std.testing.expectEqual(@as(usize, 2), pool.available.items.len);
}

test "ConnPool asDriver exec and query reuse connection" {
    const SQLiteDriver = @import("sqlite.zig").SQLiteDriver;
    const allocator = std.testing.allocator;

    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                return SQLiteDriver.open(a, ":memory:");
            }
        }.f,
        .min_connections = 1,
        .max_connections = 2,
    });
    defer pool.deinit();

    const drv = pool.asDriver();
    _ = try drv.exec("CREATE TABLE t (id INTEGER)", &.{});
    _ = try drv.exec("INSERT INTO t (id) VALUES (?)", &.{.{ .int = 42 }});

    var rows = try drv.query("SELECT id FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try std.testing.expectEqual(@as(i64, 42), row.getInt(0).?);
}

test "ConnPool transaction holds connection" {
    const SQLiteDriver = @import("sqlite.zig").SQLiteDriver;
    const allocator = std.testing.allocator;

    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                return SQLiteDriver.open(a, ":memory:");
            }
        }.f,
        .min_connections = 1,
        .max_connections = 1,
    });
    defer pool.deinit();

    const drv = pool.asDriver();
    _ = try drv.exec("CREATE TABLE t (id INTEGER)", &.{});

    var tx = try drv.beginTx();
    _ = try tx.exec("INSERT INTO t (id) VALUES (?)", &.{.{ .int = 1 }});
    try tx.commit();
    tx.deinit();

    // Pool should have released the connection after tx.deinit.
    try std.testing.expectEqual(@as(usize, 1), pool.available.items.len);
}

test "ConnPool rolls back leaked transaction on release" {
    const SQLiteDriver = @import("sqlite.zig").SQLiteDriver;
    const allocator = std.testing.allocator;

    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                return SQLiteDriver.open(a, ":memory:");
            }
        }.f,
        .min_connections = 1,
        .max_connections = 1,
    });
    defer pool.deinit();

    const drv = pool.asDriver();
    _ = try drv.exec("CREATE TABLE t (id INTEGER)", &.{});

    // Begin a transaction directly on the pooled driver and deliberately
    // leak it by calling deinit before commit/rollback.
    var tx = try drv.beginTx();
    _ = try tx.exec("INSERT INTO t (id) VALUES (?)", &.{.{ .int = 1 }});
    tx.deinit();

    // The leaked transaction should have been rolled back, so the row is gone.
    var rows = try drv.query("SELECT COUNT(*) FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try std.testing.expectEqual(@as(i64, 0), row.getInt(0).?);
}

test "ConnPool exhausted returns PoolExhausted without wait" {
    const SQLiteDriver = @import("sqlite.zig").SQLiteDriver;
    const allocator = std.testing.allocator;

    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                return SQLiteDriver.open(a, ":memory:");
            }
        }.f,
        .min_connections = 1,
        .max_connections = 1,
        .max_wait_ms = 0,
        .max_retries = 0,
    });
    defer pool.deinit();

    const c1 = try pool.borrow();
    try std.testing.expectError(error.PoolExhausted, pool.borrow());
    pool.release(c1);
}

test "ConnPool metrics hooks fire" {
    const SQLiteDriver = @import("sqlite.zig").SQLiteDriver;
    const allocator = std.testing.allocator;

    const Counters = struct {
        borrow: usize = 0,
        release: usize = 0,
        slow_query: usize = 0,
    };
    var counters = Counters{};

    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                return SQLiteDriver.open(a, ":memory:");
            }
        }.f,
        .min_connections = 1,
        .max_connections = 1,
        .max_retries = 0,
        .slow_query_threshold_ms = 1,
        .metrics = .{
            .onBorrow = struct {
                fn f(ctx: ?*anyopaque, _: u32) void {
                    const c: *Counters = @ptrCast(@alignCast(ctx));
                    c.borrow += 1;
                }
            }.f,
            .onRelease = struct {
                fn f(ctx: ?*anyopaque) void {
                    const c: *Counters = @ptrCast(@alignCast(ctx));
                    c.release += 1;
                }
            }.f,
            .onSlowQuery = struct {
                fn f(ctx: ?*anyopaque, _: []const u8, _: u64) void {
                    const c: *Counters = @ptrCast(@alignCast(ctx));
                    c.slow_query += 1;
                }
            }.f,
            .context = &counters,
        },
    });
    defer pool.deinit();

    const c1 = try pool.borrow();
    try std.testing.expectEqual(@as(usize, 1), counters.borrow);
    try std.testing.expectEqual(@as(usize, 0), counters.release);

    pool.release(c1);
    try std.testing.expectEqual(@as(usize, 1), counters.borrow);
    try std.testing.expectEqual(@as(usize, 1), counters.release);

    const drv = pool.asDriver();
    _ = try drv.exec(
        "WITH RECURSIVE cnt(x) AS (VALUES(0) UNION ALL SELECT x + 1 FROM cnt WHERE x < 100000) SELECT sum(x) FROM cnt",
        &.{},
    );
    try std.testing.expectEqual(@as(usize, 1), counters.slow_query);
}

test "ConnPool closes connection when bookkeeping allocation fails" {
    const MockDriver = struct {
        pub var opens: usize = 0;
        pub var closes: usize = 0;

        id: usize = 0,

        pub fn asDriver(self: *@This()) driver.Driver {
            return .{ .ptr = self, .vtable = &vtable };
        }

        pub fn close(self: *@This()) void {
            _ = self;
            closes += 1;
        }

        fn mockExec(_: *anyopaque, _: []const u8, _: []const Value) driver.Error!driver.Result {
            unreachable;
        }
        fn mockQuery(_: *anyopaque, _: []const u8, _: []const Value) driver.Error!driver.Rows {
            unreachable;
        }
        fn mockBeginTx(_: *anyopaque) driver.Error!driver.Tx {
            unreachable;
        }
        fn mockClose(_: *anyopaque) void {
            unreachable;
        }
        fn mockDialect(_: *anyopaque) Dialect {
            return .sqlite;
        }
        fn mockPing(_: *anyopaque) driver.Error!void {
            unreachable;
        }
        fn mockInTransaction(_: *anyopaque) bool {
            unreachable;
        }

        const vtable = driver.Driver.VTable{
            .exec = mockExec,
            .query = mockQuery,
            .beginTx = mockBeginTx,
            .close = mockClose,
            .dialect = mockDialect,
            .ping = mockPing,
            .inTransaction = mockInTransaction,
        };
    };

    MockDriver.opens = 0;
    MockDriver.closes = 0;

    // fail_index = 2: init performs two capacity allocations (all, available),
    // then the next allocation inside addConnection's all.addOne must fail.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 2,
    });
    const allocator = failing.allocator();

    var pool = try ConnPool(MockDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !MockDriver {
                _ = a;
                MockDriver.opens += 1;
                return MockDriver{};
            }
        }.f,
        .min_connections = 1,
        .max_connections = 2,
        .health_check_on_borrow = false,
    });
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 1), MockDriver.opens);
    try std.testing.expectEqual(@as(usize, 0), MockDriver.closes);

    // Fill the pre-allocated capacity so the next addConnection is forced to
    // grow self.all, which triggers the FailingAllocator.
    pool.options.max_connections = 100;
    while (pool.all.items.len < pool.all.capacity) {
        try pool.addConnection();
    }

    try std.testing.expectError(error.OutOfMemory, pool.addConnection());

    // The connection opened for the failed bookkeeping allocation must be closed.
    try std.testing.expectEqual(@as(usize, pool.all.items.len + 1), MockDriver.opens);
    try std.testing.expectEqual(@as(usize, 1), MockDriver.closes);
}

test "ConnPool closes connection once when available.append fails" {
    const MockDriver = struct {
        pub var opens: usize = 0;
        pub var closes: usize = 0;

        id: usize = 0,

        pub fn asDriver(self: *@This()) driver.Driver {
            return .{ .ptr = self, .vtable = &vtable };
        }

        pub fn close(self: *@This()) void {
            _ = self;
            closes += 1;
        }

        fn mockExec(_: *anyopaque, _: []const u8, _: []const Value) driver.Error!driver.Result {
            unreachable;
        }
        fn mockQuery(_: *anyopaque, _: []const u8, _: []const Value) driver.Error!driver.Rows {
            unreachable;
        }
        fn mockBeginTx(_: *anyopaque) driver.Error!driver.Tx {
            unreachable;
        }
        fn mockClose(_: *anyopaque) void {
            unreachable;
        }
        fn mockDialect(_: *anyopaque) Dialect {
            return .sqlite;
        }
        fn mockPing(_: *anyopaque) driver.Error!void {
            unreachable;
        }
        fn mockInTransaction(_: *anyopaque) bool {
            unreachable;
        }

        const vtable = driver.Driver.VTable{
            .exec = mockExec,
            .query = mockQuery,
            .beginTx = mockBeginTx,
            .close = mockClose,
            .dialect = mockDialect,
            .ping = mockPing,
            .inTransaction = mockInTransaction,
        };
    };

    MockDriver.opens = 0;
    MockDriver.closes = 0;

    const allocator = std.testing.allocator;
    var pool = try ConnPool(MockDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !MockDriver {
                _ = a;
                MockDriver.opens += 1;
                return MockDriver{};
            }
        }.f,
        .min_connections = 1,
        .max_connections = 2,
        .health_check_on_borrow = false,
    });
    defer pool.deinit();

    // Force the next available.append to allocate by freeing the available
    // buffer. all.addOne will still succeed because capacity was reserved
    // during init.
    pool.available.shrinkAndFree(allocator, 0);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    pool.allocator = failing.allocator();

    const all_len_before = pool.all.items.len;
    try std.testing.expectError(error.OutOfMemory, pool.addConnection());

    // The pointer must be rolled back and the connection closed exactly once.
    try std.testing.expectEqual(@as(usize, all_len_before), pool.all.items.len);
    try std.testing.expectEqual(@as(usize, 1), MockDriver.closes);
    try std.testing.expectEqual(@as(usize, 2), MockDriver.opens);

    pool.allocator = allocator;
}

test "pool retries on exhaustion with backoff" {
    const SQLiteDriver = @import("sqlite.zig").SQLiteDriver;
    const allocator = std.testing.allocator;

    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                return SQLiteDriver.open(a, ":memory:");
            }
        }.f,
        .min_connections = 1,
        .max_connections = 1,
        .health_check_on_borrow = false,
        .max_retries = 2,
        .retry_backoff_ms = 10,
    });
    defer pool.deinit();

    // Borrow the only connection — exhausts the pool.
    const c1 = try pool.borrow();
    defer pool.release(c1);

    // Second borrow should retry twice and then fail with PoolExhausted.
    try std.testing.expectError(error.PoolExhausted, pool.borrow());
}
