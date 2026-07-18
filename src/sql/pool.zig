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

/// Blocking acquire for `std.atomic.Mutex` (this Zig version only exposes
/// `tryLock`).
fn mutexLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) {
        std.atomic.spinLoopHint();
    }
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

        pub const Options = struct {
            /// Initial number of connections opened during `init`.
            min_connections: usize = 1,
            /// Hard upper bound on total connections.
            max_connections: usize = 8,
            /// Run `ping()` before handing out a connection.
            health_check_on_borrow: bool = true,
            /// Factory that opens a new connection.
            connect: ConnectFn,
        };

        allocator: std.mem.Allocator,
        connect: ConnectFn,
        options: Options,
        dialect: Dialect,
        mutex: std.atomic.Mutex = .unlocked,
        all: std.ArrayListUnmanaged(D) = .empty,
        available: std.ArrayListUnmanaged(*D) = .empty,
        closed: bool = false,

        /// Open a pool and warm up `min_connections`.
        pub fn init(allocator: std.mem.Allocator, options: Options) !Self {
            assert(options.min_connections > 0);
            assert(options.min_connections <= options.max_connections);

            var self = Self{
                .allocator = allocator,
                .connect = options.connect,
                .options = options,
                .dialect = Dialect.sqlite, // overwritten after first conn
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
            mutexLock(&self.mutex);
            self.closed = true;
            for (self.all.items) |*conn| {
                conn.close();
            }
            self.all.deinit(self.allocator);
            self.available.deinit(self.allocator);
            self.mutex.unlock();
            self.* = undefined;
        }

        fn addConnection(self: *Self) !void {
            const conn = try self.connect(self.allocator);
            const ptr = try self.all.addOne(self.allocator);
            ptr.* = conn;
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

        /// Borrow a connection from the pool.
        ///
        /// If the pool is below `max_connections`, a new connection is opened.
        /// Otherwise `error.PoolExhausted` is returned.
        pub fn borrow(self: *Self) !*D {
            mutexLock(&self.mutex);
            defer self.mutex.unlock();
            if (self.closed) return error.PoolClosed;

            while (true) {
                const conn = self.available.pop() orelse {
                    if (self.all.items.len < self.options.max_connections) {
                        const new_conn = try self.connect(self.allocator);
                        const ptr = try self.all.addOne(self.allocator);
                        ptr.* = new_conn;
                        return ptr;
                    }
                    return error.PoolExhausted;
                };

                if (self.options.health_check_on_borrow) {
                    conn.asDriver().ping() catch {
                        // Connection is dead; drop it and try the next one.
                        self.closeConnection(conn);
                        continue;
                    };
                }

                return conn;
            }
        }

        /// Return a borrowed connection to the pool.
        pub fn release(self: *Self, conn: *D) void {
            mutexLock(&self.mutex);
            defer self.mutex.unlock();
            if (self.closed) return;

            // Verify the connection still belongs to the pool.
            const found = for (self.all.items) |*item| {
                if (item == conn) break true;
            } else false;
            if (!found) return;

            self.available.append(self.allocator, conn) catch {
                // If bookkeeping fails, drop the connection.
                self.closeConnection(conn);
            };
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

        const driver_vtable = driver.Driver.VTable{
            .exec = driverExec,
            .query = driverQuery,
            .beginTx = driverBeginTx,
            .close = driverClose,
            .dialect = driverDialect,
            .ping = driverPing,
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
