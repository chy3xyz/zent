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

        /// Optional metrics callbacks. All callbacks are invoked while holding
        /// the pool mutex, so they should be fast and non-blocking.
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
            /// pool is exhausted. Zero means non-blocking (returns
            /// `error.PoolExhausted` immediately).
            max_wait_ms: u32 = 0,
            /// Optional metrics callbacks.
            metrics: Metrics = .{},
        };

        allocator: std.mem.Allocator,
        connect: ConnectFn,
        options: Options,
        dialect: Dialect,
        io: std.Io,
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        all: std.ArrayListUnmanaged(D) = .empty,
        available: std.ArrayListUnmanaged(*D) = .empty,
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
            self.dialect = self.all.items[0].asDriver().dialect();

            return self;
        }

        /// Close every connection and free pool bookkeeping.
        pub fn deinit(self: *Self) void {
            const io = self.io;
            self.mutex.lockUncancelable(io);
            self.closed = true;
            // Wake any waiters so they observe the closed state.
            self.cond.broadcast(io);
            for (self.all.items) |*conn| {
                conn.close();
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
            ptr.* = conn;
            errdefer {
                _ = self.all.pop(); // remove dangling pointer
                conn.close();
            }
            try self.available.append(self.allocator, ptr);
        }

        /// Close a connection and remove it from the pool.
        /// The caller must hold `self.mutex`.
        fn closeConnection(self: *Self, conn: *D) void {
            conn.close();
            const idx = for (self.all.items, 0..) |*item, i| {
                if (item == conn) break i;
            } else unreachable;

            const last = &self.all.items[self.all.items.len - 1];
            if (last != conn) {
                // `swapRemove` moves `last` to `idx`. Fix any available pointer
                // that still references `last`.
                for (self.available.items) |*avail| {
                    if (avail.* == last) {
                        avail.* = conn;
                    }
                }
            }
            _ = self.all.swapRemove(idx);
        }

        fn makeTimeout(self: *const Self) ?std.Io.Timeout {
            const ms = self.options.max_wait_ms;
            if (ms == 0) return null;
            return .{ .duration = .{
                .raw = .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms },
                .clock = .awake,
            } };
        }

        /// Borrow a connection from the pool.
        ///
        /// If the pool is below `max_connections`, a new connection is opened.
        /// Otherwise the caller waits up to `max_wait_ms` milliseconds for a
        /// connection to be released. If the timeout expires, `error.PoolExhausted`
        /// is returned.
        pub fn borrow(self: *Self) !*D {
            const io = self.io;
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.closed) return error.PoolClosed;

            var waited: bool = false;
            var wait_start: ?std.Io.Clock.Timestamp = null;

            while (true) {
                const conn = self.available.pop() orelse {
                    if (self.all.items.len < self.options.max_connections) {
                        var new_conn = try self.connect(self.allocator);
                        const ptr = blk: {
                            errdefer new_conn.close(); // only runs if all.addOne fails
                            const p = try self.all.addOne(self.allocator);
                            break :blk p;
                        };
                        ptr.* = new_conn;
                        errdefer {
                            _ = self.all.pop(); // remove dangling pointer
                            new_conn.close();
                        }
                        return self.finishBorrow(ptr, wait_start);
                    }

                    const timeout = self.makeTimeout() orelse {
                        if (self.options.metrics.onError) |cb| cb(self.options.metrics.context, error.PoolExhausted);
                        return error.PoolExhausted;
                    };

                    if (!waited) {
                        waited = true;
                        wait_start = std.Io.Clock.Timestamp.now(io, .awake);
                        if (self.options.metrics.onWait) |cb| cb(self.options.metrics.context);
                    }

                    self.cond.waitTimeout(io, &self.mutex, timeout) catch |err| {
                        if (self.options.metrics.onError) |cb| cb(self.options.metrics.context, err);
                        return error.PoolExhausted;
                    };
                    continue;
                };

                if (self.options.health_check_on_borrow) {
                    conn.asDriver().ping() catch {
                        // Connection is dead; drop it and try the next one.
                        self.closeConnection(conn);
                        continue;
                    };
                }

                return self.finishBorrow(conn, wait_start);
            }
        }

        fn finishBorrow(self: *Self, conn: *D, wait_start: ?std.Io.Clock.Timestamp) *D {
            const wait_ms: u32 = blk: {
                const start = wait_start orelse break :blk 0;
                const elapsed = start.untilNow(self.io).raw.toMilliseconds();
                break :blk @intCast(@max(0, elapsed));
            };
            if (self.options.metrics.onBorrow) |cb| cb(self.options.metrics.context, wait_ms);
            return conn;
        }

        /// Return a borrowed connection to the pool.
        pub fn release(self: *Self, conn: *D) void {
            const io = self.io;
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.closed) return;

            // Verify the connection still belongs to the pool.
            const found = for (self.all.items) |*item| {
                if (item == conn) break true;
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

            self.available.append(self.allocator, conn) catch {
                // If bookkeeping fails, drop the connection.
                self.closeConnection(conn);
            };
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

        const PooledTx = struct {
            pool: *Self,
            conn: *D,
            tx: driver.Tx,
            finished: bool = false,
        };

        fn pooledCommit(ptr: *anyopaque) anyerror!void {
            const wrapper: *PooledTx = @ptrCast(@alignCast(ptr));
            if (wrapper.finished) return;
            try wrapper.tx.commit();
            wrapper.finished = true;
        }

        fn pooledRollback(ptr: *anyopaque) anyerror!void {
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

        fn driverExec(ptr: *anyopaque, query_sql: []const u8, args: []const Value) anyerror!driver.Result {
            const pool: *Self = @ptrCast(@alignCast(ptr));
            const conn = try pool.borrow();
            defer pool.release(conn);
            return conn.asDriver().exec(query_sql, args);
        }

        fn driverQuery(ptr: *anyopaque, query_sql: []const u8, args: []const Value) anyerror!driver.Rows {
            const pool: *Self = @ptrCast(@alignCast(ptr));
            const conn = try pool.borrow();
            defer pool.release(conn);
            return conn.asDriver().query(query_sql, args);
        }

        fn driverBeginTx(ptr: *anyopaque) anyerror!driver.Tx {
            const pool: *Self = @ptrCast(@alignCast(ptr));
            const conn = try pool.borrow();
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

        fn driverPing(ptr: *anyopaque) anyerror!void {
            const pool: *Self = @ptrCast(@alignCast(ptr));
            const conn = try pool.borrow();
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

        fn mockExec(_: *anyopaque, _: []const u8, _: []const Value) anyerror!driver.Result {
            unreachable;
        }
        fn mockQuery(_: *anyopaque, _: []const u8, _: []const Value) anyerror!driver.Rows {
            unreachable;
        }
        fn mockBeginTx(_: *anyopaque) anyerror!driver.Tx {
            unreachable;
        }
        fn mockClose(_: *anyopaque) void {
            unreachable;
        }
        fn mockDialect(_: *anyopaque) Dialect {
            return .sqlite;
        }
        fn mockPing(_: *anyopaque) anyerror!void {
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

        fn mockExec(_: *anyopaque, _: []const u8, _: []const Value) anyerror!driver.Result {
            unreachable;
        }
        fn mockQuery(_: *anyopaque, _: []const u8, _: []const Value) anyerror!driver.Rows {
            unreachable;
        }
        fn mockBeginTx(_: *anyopaque) anyerror!driver.Tx {
            unreachable;
        }
        fn mockClose(_: *anyopaque) void {
            unreachable;
        }
        fn mockDialect(_: *anyopaque) Dialect {
            return .sqlite;
        }
        fn mockPing(_: *anyopaque) anyerror!void {
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
