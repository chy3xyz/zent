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

        /// Optional metrics callbacks. Borrow/release/error callbacks run after
        /// the pool mutex is released, so they may safely re-enter the pool
        /// (e.g. read pool state) without deadlocking; slow-query callbacks run
        /// after the driver call. Callbacks should still be fast and
        /// non-blocking to avoid delaying the caller.
        ///
        /// Known limitation: the borrow-path health check runs inside the
        /// mutex, so `health_check_on_borrow` serializes concurrent borrows
        /// while the ping is in flight.
        pub const Metrics = struct {
            /// Called when a connection is successfully borrowed.
            /// `wait_ms` is the total time spent waiting for a connection.
            onBorrow: ?*const fn (ctx: ?*anyopaque, wait_ms: u32) void = null,
            /// Called when a connection is released back to the pool.
            onRelease: ?*const fn (ctx: ?*anyopaque) void = null,
            /// Called when a caller starts waiting for an available connection.
            /// Fires at most once per `borrow`, after the pool mutex is
            /// released, and only when `max_wait_ms > 0` actually blocks the
            /// caller.
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
            /// Factory that opens a new connection. Omit when `connectCtx`
            /// is provided (e.g. a factory closing over runtime config).
            connect: ?ConnectFn = null,
            /// Optional context + factory pair: lets the connect factory close
            /// over runtime configuration (e.g. a file path) instead of
            /// relying on globals. When set, `connectCtx` wins over `connect`.
            connect_ctx: ?*anyopaque = null,
            connectCtx: ?*const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!D = null,
            /// I/O abstraction used for blocking synchronization. When omitted, the pool
            /// creates and owns a thread-safe `std.Io.Threaded` instance. Applications that
            /// want to share an `Io` across multiple pools or use a custom implementation
            /// can provide an explicit `std.Io` here.
            io: ?std.Io = null,
            /// Total time budget in milliseconds that a single `borrow` may
            /// spend waiting for a connection once the pool is exhausted.
            ///
            /// When non-zero, borrowers block on the pool condition variable
            /// instead of polling and are woken as soon as a connection is
            /// released (see `borrow` for the waiting/fairness contract). When
            /// the budget is used up, `borrow` falls back to the
            /// `max_retries` + `retry_backoff_ms` path and then reports
            /// `error.PoolExhausted`.
            ///
            /// Zero (the default) means non-blocking: no waiting happens and a
            /// failed attempt immediately returns `error.PoolExhausted` (after
            /// the legacy retries). This preserves the historical behavior.
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
            /// Optional per-query timeout in milliseconds. When set and a builder
            /// does not provide its own deadline, the pool computes an absolute
            /// deadline before invoking the underlying driver.
            query_timeout_ms: ?u32 = null,
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
        options: Options,
        dialect: Dialect,
        io: std.Io,
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        all: std.ArrayListUnmanaged(*PooledEntry) = .empty,
        available: std.ArrayListUnmanaged(*PooledEntry) = .empty,
        closed: bool = false,
        /// Source of waiter tickets, handed out under `mutex`. See `borrow`.
        next_ticket: u64 = 0,
        /// Tickets of the borrowers currently blocked on `cond`, in ascending
        /// arrival order (tickets are assigned under the mutex, so appends stay
        /// sorted). Best-effort fairness bookkeeping only — see `borrow`.
        wait_tickets: std.ArrayListUnmanaged(u64) = .empty,
        owned_io: ?*std.Io.Threaded = null,

        /// Create a thread-safe Io instance owned by the pool.
        fn createOwnedIo(allocator: std.mem.Allocator) !*std.Io.Threaded {
            const threaded = try allocator.create(std.Io.Threaded);
            errdefer allocator.destroy(threaded);
            threaded.* = std.Io.Threaded.init(allocator, .{});
            return threaded;
        }

        /// Open a pool and warm up `min_connections`.
        pub fn init(allocator: std.mem.Allocator, options: Options) !Self {
            assert(options.min_connections > 0);
            assert(options.min_connections <= options.max_connections);

            var self = Self{
                .allocator = allocator,
                .options = options,
                .dialect = Dialect.sqlite, // overwritten after first conn
                .io = undefined,
            };

            if (options.io) |io| {
                self.io = io;
            } else {
                const threaded = try createOwnedIo(allocator);
                self.owned_io = threaded;
                self.io = threaded.io();
            }
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
        ///
        /// # Caller contract
        ///
        /// No other thread may be inside `borrow`, `release`, or any `asDriver`
        /// operation — **including a thread currently blocked waiting for a
        /// connection** — while `deinit` runs. Waiters are woken by the
        /// `broadcast` below and return `error.PoolClosed` once they observe
        /// `closed`, but that observation requires the pool mutex and the
        /// owned `Io` to still be alive: `deinit` destroys the owned `Io`
        /// immediately after releasing the mutex and then sets `self` to
        /// `undefined`, so a waiter still inside `borrow` at that point touches
        /// freed state. Using `deinit` to interrupt blocked borrowers is
        /// therefore undefined behavior; drain or cancel them first.
        pub fn deinit(self: *Self) void {
            const io = self.io;
            self.mutex.lockUncancelable(io);
            self.closed = true;
            // Wake any waiters so they observe the closed state (see the
            // caller contract above: this is only safe when none are blocked).
            self.cond.broadcast(io);
            for (self.all.items) |entry| {
                entry.conn.close();
                self.allocator.destroy(entry);
            }
            self.all.deinit(self.allocator);
            self.available.deinit(self.allocator);
            self.wait_tickets.deinit(self.allocator);
            self.mutex.unlock(io);
            if (self.owned_io) |t| {
                t.deinit();
                self.allocator.destroy(t);
            }
            self.* = undefined;
        }

        fn addConnection(self: *Self) !void {
            var conn = try self.openConnection();
            errdefer conn.close();

            // Each entry lives in its own heap allocation so its address is
            // stable for the connection's lifetime. `available` holds raw
            // pointers into `all`; if entries were stored by value in `all`,
            // a `swapRemove` would move a still-borrowed entry and leave a
            // borrowed pointer aliasing a recycled slot (use-after-free).
            const entry = try self.allocator.create(PooledEntry);
            errdefer self.allocator.destroy(entry);

            entry.* = .{
                .conn = conn,
                .created_at = unixTimestamp(),
                .idle_since = unixTimestamp(),
            };

            try self.all.append(self.allocator, entry);
            errdefer _ = self.all.pop();

            try self.available.append(self.allocator, entry);
        }

        /// Open a new connection honoring either factory (connectCtx wins).
        fn openConnection(self: *Self) !D {
            if (self.options.connectCtx) |f| return f(self.options.connect_ctx, self.allocator);
            if (self.options.connect) |f| return f(self.allocator);
            return error.MissingConnectFactory;
        }

        /// Close a connection and remove it from the pool.
        /// The caller must hold `self.mutex`.
        ///
        /// Entries are heap-allocated and never move, so removal is by pointer
        /// identity from both lists — no `swapRemove` and no pointer-patching.
        /// The entry being closed is never currently borrowed (callers only
        /// close idle or freshly-opened-but-failed entries), so it can appear
        /// in `available` at most once.
        fn closeConnection(self: *Self, entry: *PooledEntry) void {
            const all_idx = for (self.all.items, 0..) |item, i| {
                if (item == entry) break i;
            } else unreachable;
            _ = self.all.orderedRemove(all_idx);

            for (self.available.items, 0..) |item, i| {
                if (item == entry) {
                    _ = self.available.orderedRemove(i);
                    break;
                }
            }

            entry.conn.close();
            self.allocator.destroy(entry);
        }

        /// Non-blocking borrow attempt. Returns a pooled entry or null when
        /// the pool is exhausted. The caller must hold `self.mutex`.
        fn tryBorrowNoLock(self: *Self) ?*PooledEntry {
            while (true) {
                const entry = self.available.pop() orelse {
                    if (self.all.items.len < self.options.max_connections) {
                        // Open a new connection.
                        var new_conn = self.openConnection() catch return null;
                        const entry = self.allocator.create(PooledEntry) catch {
                            new_conn.close();
                            return null;
                        };
                        entry.* = .{
                            .conn = new_conn,
                            .created_at = unixTimestamp(),
                            .idle_since = null,
                        };
                        self.all.append(self.allocator, entry) catch {
                            entry.conn.close();
                            self.allocator.destroy(entry);
                            return null;
                        };
                        // Newly created connections must also pass the health
                        // check before being handed out. If they fail, close the
                        // entry and let the caller's retry loop decide whether to
                        // attempt again; otherwise we could spin forever creating
                        // and discarding dead connections.
                        if (self.options.health_check_on_borrow) {
                            entry.conn.asDriver().ping() catch {
                                self.closeConnection(entry);
                                return null;
                            };
                        }
                        return entry;
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

        /// How many times a younger waiter steps aside for an older ticket
        /// before taking an available connection itself. Bounds the fairness
        /// deferral so a descheduled or about-to-time-out older waiter can
        /// never stall another borrower.
        const max_fair_deferrals: u32 = 8;

        /// Best-effort fairness decision: true when `ticket` should let an
        /// older waiting ticket take a connection that the pool looks able to
        /// hand out right now. The caller must hold `self.mutex`.
        fn shouldDeferNoLock(self: *Self, ticket: u64) bool {
            if (self.wait_tickets.items.len == 0) return false;
            // Tickets are assigned and appended under the mutex, so the list is
            // sorted by arrival and the head is the oldest waiting ticket.
            if (self.wait_tickets.items[0] >= ticket) return false;
            return self.available.items.len > 0 or self.all.items.len < self.options.max_connections;
        }

        /// Claim the next waiter ticket and record it as waiting. Returns null
        /// when the bookkeeping allocation fails; the caller then falls back to
        /// the non-blocking retry path instead of blocking untracked. The
        /// caller must hold `self.mutex`.
        fn registerWaiterNoLock(self: *Self) ?u64 {
            const ticket = self.next_ticket;
            self.wait_tickets.append(self.allocator, ticket) catch return null;
            self.next_ticket += 1;
            return ticket;
        }

        /// Drop `ticket` from the waiting set; no-op when it is not present.
        /// The caller must hold `self.mutex`.
        fn unregisterWaiterNoLock(self: *Self, ticket: u64) void {
            for (self.wait_tickets.items, 0..) |t, i| {
                if (t == ticket) {
                    _ = self.wait_tickets.orderedRemove(i);
                    return;
                }
            }
        }

        /// Release the ticket held by this call, if any. The caller must hold
        /// `self.mutex`.
        fn dropTicketNoLock(self: *Self, ticket: *?u64) void {
            if (ticket.*) |t| {
                self.unregisterWaiterNoLock(t);
                ticket.* = null;
            }
        }

        /// Borrow a connection from the pool.
        ///
        /// Performs idle eviction and health checks on each attempt.
        ///
        /// With the default `max_wait_ms == 0` the call is non-blocking: a
        /// failed attempt is retried up to `max_retries` times with linear
        /// `retry_backoff_ms` backoff, then reports `error.PoolExhausted`.
        ///
        /// When `max_wait_ms > 0` and no connection can be handed out or
        /// opened (the pool is exhausted, or opening one failed), the caller
        /// blocks on the pool condition variable instead of polling, and is
        /// woken as soon as a connection is released. `max_wait_ms` is the
        /// total budget for the whole call, measured from entry; once it runs
        /// out the call falls back to the legacy retry/backoff path and then
        /// reports `error.PoolExhausted`. A closed pool reports
        /// `error.PoolClosed`.
        ///
        /// Waiting is **best-effort fair, not strict FIFO**: every blocked
        /// borrower holds a ticket and defers to a lower (older) ticket that is
        /// still waiting when a connection looks available. A waiter that is
        /// descheduled, timing out, or could not be ticketed (bookkeeping OOM)
        /// never blocks another borrower forever — after a bounded number of
        /// deferrals the connection goes to whichever waiter is awake.
        pub fn borrow(self: *Self) !*D {
            const io = self.io;
            const waiting_enabled = self.options.max_wait_ms > 0;

            // Absolute deadline for the total wait budget; `.none` selects the
            // legacy non-blocking path, which needs no clock reads.
            const wait_start: ?std.Io.Clock.Timestamp = if (waiting_enabled)
                std.Io.Clock.Timestamp.now(io, .awake)
            else
                null;
            const wait_deadline: std.Io.Timeout = if (wait_start) |start|
                .{ .deadline = start.addDuration(.{
                    .raw = std.Io.Duration.fromMilliseconds(@intCast(self.options.max_wait_ms)),
                    .clock = .awake,
                }) }
            else
                .none;

            var ticket: ?u64 = null;
            var deferrals: u32 = 0;
            var wait_done = !waiting_enabled;
            var attempt: u32 = 0;

            while (true) {
                // The locked section only records the outcome; the metrics
                // callbacks fire after the mutex is released so they can safely
                // re-enter the pool.
                var borrowed: ?*PooledEntry = null;
                var was_closed = false;
                var deferred = false;
                var started_waiting = false;

                self.mutex.lockUncancelable(io);
                {
                    if (self.closed) {
                        self.dropTicketNoLock(&ticket);
                        was_closed = true;
                    } else if (!wait_done and ticket != null and
                        deferrals < max_fair_deferrals and self.shouldDeferNoLock(ticket.?))
                    {
                        deferrals += 1;
                        deferred = true;
                    } else if (self.tryBorrowNoLock()) |entry| {
                        self.dropTicketNoLock(&ticket);
                        borrowed = entry;
                    } else if (!wait_done) {
                        if (ticket == null) {
                            ticket = self.registerWaiterNoLock();
                            started_waiting = ticket != null;
                        }
                        if (ticket != null) {
                            // Registration above and this wait share one critical
                            // section, so a `release` cannot slip in between and
                            // lose its signal. `waitTimeout` drops the mutex while
                            // blocked and re-acquires it before returning.
                            self.cond.waitTimeout(io, &self.mutex, wait_deadline) catch |err| switch (err) {
                                error.Timeout => wait_done = true,
                                // `borrow` has no `Canceled` in its error set
                                // (callers go through `driver.Error`), so treat
                                // a canceled wait as budget exhaustion and let
                                // the legacy retry path finish.
                                error.Canceled => wait_done = true,
                            };
                            if (wait_done) self.dropTicketNoLock(&ticket);
                        } else {
                            // No ticket available, so do not block untracked.
                            wait_done = true;
                        }
                    }
                }
                self.mutex.unlock(io);

                if (borrowed) |entry| {
                    if (self.options.metrics.onBorrow) |cb| {
                        const wait_ms: u32 = if (wait_start) |start| blk: {
                            const elapsed = start.untilNow(io).raw.toMilliseconds();
                            break :blk @intCast(std.math.clamp(elapsed, 0, std.math.maxInt(u32)));
                        } else 0;
                        cb(self.options.metrics.context, wait_ms);
                    }
                    return &entry.conn;
                }
                if (was_closed) return error.PoolClosed;
                if (started_waiting) {
                    if (self.options.metrics.onWait) |cb| cb(self.options.metrics.context);
                }
                if (deferred) {
                    // Let the older ticket reach the mutex first.
                    io.sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
                    continue;
                }
                if (!wait_done) continue;

                if (attempt >= self.options.max_retries) break;
                const backoff_ms: i64 = @as(i64, self.options.retry_backoff_ms) * (@as(i64, attempt) + 1);
                attempt += 1;
                io.sleep(std.Io.Duration.fromMilliseconds(backoff_ms), .awake) catch {};
            }

            if (self.options.metrics.onError) |cb| cb(self.options.metrics.context, error.PoolExhausted);
            return error.PoolExhausted;
        }

        /// Return a borrowed connection to the pool.
        pub fn release(self: *Self, conn: *D) void {
            const entry: *PooledEntry = @fieldParentPtr("conn", conn);
            const io = self.io;
            // Only the outcomes that currently report `onRelease` (normal
            // return and max-lifetime eviction) set this; the dead-connection
            // path stays silent. The callback fires after the mutex is
            // released so it can safely re-enter the pool.
            var notify_release = false;
            {
                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                if (self.closed) return;
                const found = for (self.all.items) |item| {
                    if (item == entry) break true;
                } else false;
                if (!found) return;

                // 连接已死（Lost connection）→ 直接关闭丢弃，不再回池复用；
                // 否则后续操作触碰 libmysql 已释放句柄会段错误。
                if (@hasField(D, "dead") and conn.dead) {
                    self.closeConnection(entry);
                    self.cond.signal(io);
                    return;
                }

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
                var evicted = false;
                if (self.options.max_lifetime_secs > 0) {
                    const age_secs = unixTimestamp() - entry.created_at;
                    if (age_secs > self.options.max_lifetime_secs) {
                        self.closeConnection(entry);
                        self.cond.signal(io);
                        evicted = true;
                    }
                }

                // Bookkeeping failure is fatal for this entry: close it rather than
                // leaving a borrowed connection unreachable. `closeConnection`
                // frees the entry, so it must not be touched afterwards.
                if (!evicted) {
                    if (self.available.append(self.allocator, entry)) |_| {
                        entry.idle_since = unixTimestamp();
                    } else |_| {
                        self.closeConnection(entry);
                    }
                    self.cond.signal(io);
                }
                notify_release = true;
            }

            if (notify_release) {
                if (self.options.metrics.onRelease) |cb| cb(self.options.metrics.context);
            }
        }

        /// Proactively scan idle connections in the pool and close those that have been
        /// idle for longer than `max_idle_secs`. Returns the number of reaped connections.
        pub fn reapIdleConnections(self: *Self, max_idle_secs: i64) usize {
            const io = self.io;
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.closed or max_idle_secs <= 0) return 0;

            const now = unixTimestamp();
            var reaped: usize = 0;
            var i: usize = self.available.items.len;
            while (i > 0) {
                i -= 1;
                const entry = self.available.items[i];
                if (entry.idle_since) |idle_since| {
                    if (now - idle_since >= max_idle_secs) {
                        // closeConnection removes the entry from both lists;
                        // iterating in reverse makes the orderedRemove safe.
                        self.closeConnection(entry);
                        reaped += 1;
                    }
                }
            }
            // Closing connections frees room below `max_connections`, so blocked
            // borrowers may be able to open a fresh one instead of waiting out
            // their `max_wait_ms` budget.
            if (reaped > 0) self.cond.broadcast(io);
            return reaped;
        }

        /// Actively ping all idle connections in the pool and drop dead ones.
        /// Returns the count of remaining healthy idle connections.
        pub fn pingIdleConnections(self: *Self) usize {
            const io = self.io;
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.closed) return 0;

            var i: usize = self.available.items.len;
            var healthy: usize = 0;
            var dropped: usize = 0;
            while (i > 0) {
                i -= 1;
                const entry = self.available.items[i];
                entry.conn.asDriver().ping() catch {
                    // closeConnection removes the entry from both lists;
                    // iterating in reverse makes the orderedRemove safe.
                    self.closeConnection(entry);
                    dropped += 1;
                    continue;
                };
                healthy += 1;
            }
            // Dropping dead connections frees room below `max_connections`, so
            // blocked borrowers may be able to open a fresh one.
            if (dropped > 0) self.cond.broadcast(io);
            return healthy;
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

        /// Query rows wrapper that holds the borrowed connection until
        /// `deinit()`, so callers can safely iterate rows without another
        /// thread reusing the connection (and its prepared statements).
        const PooledRows = struct {
            pool: *Self,
            conn: *D,
            inner: driver.Rows,

            fn next(ptr: *anyopaque) ?driver.Row {
                const self: *PooledRows = @ptrCast(@alignCast(ptr));
                return self.inner.next();
            }

            fn nextError(ptr: *anyopaque) ?driver.Error {
                const self: *PooledRows = @ptrCast(@alignCast(ptr));
                if (self.inner.vtable.nextError) |ne| return ne(self.inner.ptr);
                return null;
            }

            fn deinit(ptr: *anyopaque) void {
                const self: *PooledRows = @ptrCast(@alignCast(ptr));
                self.inner.deinit();
                self.pool.release(self.conn);
                self.pool.allocator.destroy(self);
            }
        };

        const pooled_rows_vtable = driver.Rows.VTable{
            .next = PooledRows.next,
            .deinit = PooledRows.deinit,
            .nextError = PooledRows.nextError,
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

        fn mergeExecutionContext(pool: *Self, ctx: ?*const driver.ExecutionContext) driver.ExecutionContext {
            var merged: driver.ExecutionContext = .{};
            if (ctx) |cx| merged.deadline_ns = cx.deadline_ns;
            if (merged.deadline_ns == null) {
                if (pool.options.query_timeout_ms) |ms| {
                    merged.deadline_ns = driver.monotonicNs() + @as(i64, ms) * std.time.ns_per_ms;
                }
            }
            return merged;
        }

        fn driverExec(ptr: *anyopaque, ctx: ?*const driver.ExecutionContext, query_sql: []const u8, args: []const Value) driver.Error!driver.Result {
            const pool: *Self = @ptrCast(@alignCast(ptr));
            const conn = try pool.borrowForDriver();
            defer pool.release(conn);
            var merged = pool.mergeExecutionContext(ctx);
            const ctx_ptr: ?*const driver.ExecutionContext = if (merged.deadline_ns != null) &merged else null;
            if (pool.options.slow_query_threshold_ms > 0) {
                const start = std.Io.Clock.Timestamp.now(pool.io, .awake);
                const result = conn.asDriver().execCtx(ctx_ptr, query_sql, args);
                const elapsed_ms: u64 = @intCast(start.untilNow(pool.io).raw.toMilliseconds());
                if (elapsed_ms >= pool.options.slow_query_threshold_ms) {
                    if (pool.options.metrics.onSlowQuery) |cb| {
                        cb(pool.options.metrics.context, query_sql, elapsed_ms);
                    }
                }
                return result;
            }
            return conn.asDriver().execCtx(ctx_ptr, query_sql, args);
        }

        fn driverQuery(ptr: *anyopaque, ctx: ?*const driver.ExecutionContext, query_sql: []const u8, args: []const Value) driver.Error!driver.Rows {
            const pool: *Self = @ptrCast(@alignCast(ptr));
            const conn = try pool.borrowForDriver();
            var merged = pool.mergeExecutionContext(ctx);
            const ctx_ptr: ?*const driver.ExecutionContext = if (merged.deadline_ns != null) &merged else null;
            const result = if (pool.options.slow_query_threshold_ms > 0) blk: {
                const start = std.Io.Clock.Timestamp.now(pool.io, .awake);
                const inner = conn.asDriver().queryCtx(ctx_ptr, query_sql, args);
                const elapsed_ms: u64 = @intCast(start.untilNow(pool.io).raw.toMilliseconds());
                if (elapsed_ms >= pool.options.slow_query_threshold_ms) {
                    if (pool.options.metrics.onSlowQuery) |cb| {
                        cb(pool.options.metrics.context, query_sql, elapsed_ms);
                    }
                }
                break :blk inner;
            } else conn.asDriver().queryCtx(ctx_ptr, query_sql, args);

            // 关键：Rows 持有连接直到 deinit。若在此 release，调用方迭代 Rows 时
            // 连接已回池，另一线程借出执行查询（预编译缓存驱逐 stmt）→ use-after-free。
            const inner = result catch |err| {
                pool.release(conn);
                return err;
            };
            const wrapper = pool.allocator.create(PooledRows) catch {
                inner.deinit();
                pool.release(conn);
                return error.OutOfMemory;
            };
            wrapper.* = .{ .pool = pool, .conn = conn, .inner = inner };
            return .{ .ptr = wrapper, .vtable = &pooled_rows_vtable };
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

        fn driverBeginSavepoint(ptr: *anyopaque, name: []const u8) driver.Error!driver.Tx {
            const pool: *Self = @ptrCast(@alignCast(ptr));
            const conn = try pool.borrowForDriver();
            errdefer pool.release(conn);

            const tx = try conn.asDriver().beginSavepoint(name);
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
            .beginSavepoint = driverBeginSavepoint,
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

        fn mockExec(_: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const Value) driver.Error!driver.Result {
            unreachable;
        }
        fn mockQuery(_: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const Value) driver.Error!driver.Rows {
            unreachable;
        }
        fn mockBeginTx(_: *anyopaque) driver.Error!driver.Tx {
            unreachable;
        }
        fn mockBeginSavepoint(_: *anyopaque, _: []const u8) driver.Error!driver.Tx {
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
            .beginSavepoint = mockBeginSavepoint,
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

    // Make the next entry allocation fail: the freshly-opened connection must
    // be closed exactly once and no entry added to `all`.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    pool.allocator = failing.allocator();

    const all_len_before = pool.all.items.len;
    try std.testing.expectError(error.OutOfMemory, pool.addConnection());

    try std.testing.expectEqual(@as(usize, all_len_before), pool.all.items.len);
    try std.testing.expectEqual(@as(usize, 1), MockDriver.closes);
    try std.testing.expectEqual(@as(usize, 2), MockDriver.opens);

    pool.allocator = allocator;
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

        fn mockExec(_: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const Value) driver.Error!driver.Result {
            unreachable;
        }
        fn mockQuery(_: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const Value) driver.Error!driver.Rows {
            unreachable;
        }
        fn mockBeginTx(_: *anyopaque) driver.Error!driver.Tx {
            unreachable;
        }
        fn mockBeginSavepoint(_: *anyopaque, _: []const u8) driver.Error!driver.Tx {
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
            .beginSavepoint = mockBeginSavepoint,
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
    // buffer. Entry allocation (#0) and all.append succeed (capacity was
    // reserved during init), so the failure lands on available.append (#1).
    pool.available.shrinkAndFree(allocator, 0);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
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

test "ConnPool evicts connection on failed health check during borrow" {
    const MockDriver = struct {
        pub var opens: usize = 0;
        pub var closes: usize = 0;
        pub var pings: usize = 0;
        pub var ping_should_fail: bool = false;

        id: usize = 0,

        pub fn asDriver(self: *@This()) driver.Driver {
            return .{ .ptr = self, .vtable = &vtable };
        }

        pub fn close(self: *@This()) void {
            _ = self;
            closes += 1;
        }

        fn mockExec(_: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const Value) driver.Error!driver.Result {
            unreachable;
        }
        fn mockQuery(_: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const Value) driver.Error!driver.Rows {
            unreachable;
        }
        fn mockBeginTx(_: *anyopaque) driver.Error!driver.Tx {
            unreachable;
        }
        fn mockBeginSavepoint(_: *anyopaque, _: []const u8) driver.Error!driver.Tx {
            unreachable;
        }
        fn mockClose(_: *anyopaque) void {
            unreachable;
        }
        fn mockDialect(_: *anyopaque) Dialect {
            return .sqlite;
        }
        fn mockPing(_: *anyopaque) driver.Error!void {
            pings += 1;
            if (ping_should_fail) return error.ConnectionFailed;
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
            .beginSavepoint = mockBeginSavepoint,
        };
    };

    MockDriver.opens = 0;
    MockDriver.closes = 0;
    MockDriver.pings = 0;
    MockDriver.ping_should_fail = true;

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
        .health_check_on_borrow = true,
        .max_retries = 0,
    });
    defer pool.deinit();

    // The only available connection fails the health check, so it is closed
    // and the borrow returns PoolExhausted (no retries and no new connection).
    try std.testing.expectError(error.PoolExhausted, pool.borrow());
    // One ping for the initial idle connection and one for the newly created
    // connection that also failed the health check.
    try std.testing.expectEqual(@as(usize, 2), MockDriver.pings);
    try std.testing.expectEqual(@as(usize, 2), MockDriver.closes);
}

test "ConnPool evicts connection exceeding max lifetime on release" {
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

        fn mockExec(_: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const Value) driver.Error!driver.Result {
            unreachable;
        }
        fn mockQuery(_: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const Value) driver.Error!driver.Rows {
            unreachable;
        }
        fn mockBeginTx(_: *anyopaque) driver.Error!driver.Tx {
            unreachable;
        }
        fn mockBeginSavepoint(_: *anyopaque, _: []const u8) driver.Error!driver.Tx {
            unreachable;
        }
        fn mockClose(_: *anyopaque) void {
            unreachable;
        }
        fn mockDialect(_: *anyopaque) Dialect {
            return .sqlite;
        }
        fn mockPing(_: *anyopaque) driver.Error!void {}
        fn mockInTransaction(_: *anyopaque) bool {
            return false;
        }

        const vtable = driver.Driver.VTable{
            .exec = mockExec,
            .query = mockQuery,
            .beginTx = mockBeginTx,
            .close = mockClose,
            .dialect = mockDialect,
            .ping = mockPing,
            .inTransaction = mockInTransaction,
            .beginSavepoint = mockBeginSavepoint,
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
        .max_connections = 1,
        .health_check_on_borrow = false,
        .max_lifetime_secs = 1,
        .max_retries = 0,
    });
    defer pool.deinit();

    const c1 = try pool.borrow();
    // Wait long enough for the connection to exceed its 1-second lifetime.
    pool.io.sleep(std.Io.Duration.fromMilliseconds(2100), .awake) catch {};
    pool.release(c1);

    try std.testing.expectEqual(@as(usize, 1), MockDriver.closes);
    try std.testing.expectEqual(@as(usize, 0), pool.available.items.len);
}

test "ConnPool never aliases a borrowed entry when another is closed" {
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

        fn mockExec(_: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const Value) driver.Error!driver.Result {
            unreachable;
        }
        fn mockQuery(_: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const Value) driver.Error!driver.Rows {
            unreachable;
        }
        fn mockBeginTx(_: *anyopaque) driver.Error!driver.Tx {
            unreachable;
        }
        fn mockBeginSavepoint(_: *anyopaque, _: []const u8) driver.Error!driver.Tx {
            unreachable;
        }
        fn mockClose(_: *anyopaque) void {
            unreachable;
        }
        fn mockDialect(_: *anyopaque) Dialect {
            return .sqlite;
        }
        fn mockPing(_: *anyopaque) driver.Error!void {}
        fn mockInTransaction(_: *anyopaque) bool {
            return false;
        }

        const vtable = driver.Driver.VTable{
            .exec = mockExec,
            .query = mockQuery,
            .beginTx = mockBeginTx,
            .close = mockClose,
            .dialect = mockDialect,
            .ping = mockPing,
            .inTransaction = mockInTransaction,
            .beginSavepoint = mockBeginSavepoint,
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
                return .{ .id = MockDriver.opens };
            }
        }.f,
        .min_connections = 2,
        .max_connections = 2,
        .health_check_on_borrow = false,
        .max_retries = 0,
    });
    defer pool.deinit();

    // available = [e0, e1]; borrow pops the last entry (e1).
    const borrowed = try pool.borrow();
    const borrowed_id = borrowed.id;
    try std.testing.expectEqual(@as(usize, 2), MockDriver.opens);

    // Close the *other* entry (e0) while e1 is still borrowed. The old
    // value-array + swapRemove design moved e1 into e0's slot and left a
    // stale copy that a subsequent append overwrote, aliasing the borrowed
    // pointer (use-after-free).
    const other = pool.available.items[0];
    {
        const io = pool.io;
        pool.mutex.lockUncancelable(io);
        pool.closeConnection(other);
        pool.mutex.unlock(io);
    }
    try std.testing.expectEqual(@as(usize, 1), MockDriver.closes);

    // Force a new connection to fill the (previously recycled) slot.
    const extra = try pool.borrow();
    try std.testing.expectEqual(@as(usize, 3), MockDriver.opens);
    try std.testing.expect(extra.id != borrowed_id);

    // Releasing the original borrow must not be confused by the new entry.
    pool.release(borrowed);
    try std.testing.expectEqual(@as(usize, 1), pool.available.items.len);
    pool.release(extra);
    try std.testing.expectEqual(@as(usize, 2), pool.available.items.len);
}

test "ConnPool supports concurrent borrow and release across threads" {
    const SQLiteDriver = @import("sqlite.zig").SQLiteDriver;
    // std.testing.allocator (SafeAllocator) is single-threaded; sharing it
    // across the spawned threads is UB and intermittently corrupts its
    // bookkeeping. Use a thread-safe allocator for the concurrency exercise.
    const allocator = std.heap.page_allocator;

    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                var drv = try SQLiteDriver.open(a, "file::memory:?cache=shared");
                _ = try drv.exec("CREATE TABLE IF NOT EXISTS t (id INTEGER)", &.{});
                return drv;
            }
        }.f,
        .min_connections = 1,
        .max_connections = 4,
        .health_check_on_borrow = false,
        .max_retries = 0,
    });
    defer pool.deinit();

    const Ctx = struct {
        pool: *ConnPool(SQLiteDriver),
        done: std.atomic.Value(usize),

        fn run(ctx: *@This()) void {
            for (0..50) |_| {
                const conn = ctx.pool.borrow() catch unreachable;
                _ = conn.asDriver().exec("INSERT INTO t (id) VALUES (?)", &.{.{ .int = 1 }}) catch unreachable;
                ctx.pool.release(conn);
            }
            _ = ctx.done.fetchAdd(1, .monotonic);
        }
    };

    var ctx = Ctx{
        .pool = &pool,
        .done = std.atomic.Value(usize).init(0),
    };

    const thread_count = 4;
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = std.Thread.spawn(.{}, Ctx.run, .{&ctx}) catch unreachable;
    }
    for (&threads) |*t| {
        t.join();
    }

    try std.testing.expectEqual(@as(usize, thread_count), ctx.done.load(.monotonic));

    var rows = try pool.asDriver().query("SELECT COUNT(*) FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try std.testing.expectEqual(@as(i64, 50 * thread_count), row.getInt(0).?);
}

test "ConnPool explicit io is not owned or destroyed by the pool" {
    const SQLiteDriver = @import("sqlite.zig").SQLiteDriver;
    const allocator = std.testing.allocator;

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();

    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                return SQLiteDriver.open(a, ":memory:");
            }
        }.f,
        .min_connections = 1,
        .max_connections = 1,
        .health_check_on_borrow = false,
        .io = threaded_io.io(),
    });
    defer pool.deinit();

    // The pool should not have created an owned Io.
    try std.testing.expectEqual(@as(?*std.Io.Threaded, null), pool.owned_io);

    // A borrow/release cycle should still work with the explicit Io.
    const conn = try pool.borrow();
    pool.release(conn);
}

test "ConnPool metrics callbacks run outside the mutex and may re-enter" {
    const SQLiteDriver = @import("sqlite.zig").SQLiteDriver;
    const allocator = std.testing.allocator;
    const P = ConnPool(SQLiteDriver);

    const Ctx = struct {
        pool: *P = undefined,
        borrow_calls: usize = 0,
        release_calls: usize = 0,
        reentered_borrow: bool = false,
        reentered_release: bool = false,

        fn onBorrow(ctx: ?*anyopaque, _: u32) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.borrow_calls += 1;
            // Re-enter exactly once: the nested borrow runs this callback
            // again, so gate it on a flag (bounded recursion).
            if (!c.reentered_borrow) {
                c.reentered_borrow = true;
                const inner = c.pool.borrow() catch return;
                c.pool.release(inner);
            }
        }

        fn onRelease(ctx: ?*anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.release_calls += 1;
            if (!c.reentered_release) {
                c.reentered_release = true;
                const inner = c.pool.borrow() catch return;
                c.pool.release(inner);
            }
        }
    };

    var ctx = Ctx{};
    var pool = try P.init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !SQLiteDriver {
                return SQLiteDriver.open(a, ":memory:");
            }
        }.f,
        .min_connections = 2,
        .max_connections = 2,
        .health_check_on_borrow = false,
        .metrics = .{
            .onBorrow = Ctx.onBorrow,
            .onRelease = Ctx.onRelease,
            .context = &ctx,
        },
    });
    defer pool.deinit();
    ctx.pool = &pool;

    // If the callbacks ran while the mutex was held, these re-entrant
    // borrows would deadlock on the non-recursive pool mutex.
    const c1 = try pool.borrow();
    pool.release(c1);

    try std.testing.expect(ctx.reentered_borrow);
    try std.testing.expect(ctx.reentered_release);
    try std.testing.expect(ctx.borrow_calls >= 2);
    try std.testing.expect(ctx.release_calls >= 2);

    // State is intact: the pool still hands out and takes back connections.
    const c2 = try pool.borrow();
    pool.release(c2);
    try std.testing.expectEqual(@as(usize, 2), pool.available.items.len);
}

/// Minimal driver for the blocking-borrow tests: it opens, closes, and reports
/// "not in a transaction" (the only driver call `release` makes on the plain
/// return path). These tests never execute SQL, so the rest is `unreachable`.
const StubDriver = struct {
    /// Present so the driver has non-trivial alignment; `release` derives the
    /// enclosing `PooledEntry` with `@fieldParentPtr("conn", …)`.
    id: usize = 0,

    pub fn asDriver(self: *@This()) driver.Driver {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn close(self: *@This()) void {
        _ = self;
    }

    fn stubExec(_: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const Value) driver.Error!driver.Result {
        unreachable;
    }
    fn stubQuery(_: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const Value) driver.Error!driver.Rows {
        unreachable;
    }
    fn stubBeginTx(_: *anyopaque) driver.Error!driver.Tx {
        unreachable;
    }
    fn stubBeginSavepoint(_: *anyopaque, _: []const u8) driver.Error!driver.Tx {
        unreachable;
    }
    fn stubClose(_: *anyopaque) void {
        unreachable;
    }
    fn stubDialect(_: *anyopaque) Dialect {
        return .sqlite;
    }
    fn stubPing(_: *anyopaque) driver.Error!void {}
    fn stubInTransaction(_: *anyopaque) bool {
        return false;
    }

    const vtable = driver.Driver.VTable{
        .exec = stubExec,
        .query = stubQuery,
        .beginTx = stubBeginTx,
        .close = stubClose,
        .dialect = stubDialect,
        .ping = stubPing,
        .inTransaction = stubInTransaction,
        .beginSavepoint = stubBeginSavepoint,
    };
};

fn stubConnect(allocator: std.mem.Allocator) anyerror!StubDriver {
    _ = allocator;
    return StubDriver{};
}

test "ConnPool blocked borrow is served by a release" {
    // std.testing.allocator (SafeAllocator) is single-threaded; the pool here is
    // shared with spawned threads, so use a thread-safe allocator.
    const allocator = std.heap.page_allocator;
    const P = ConnPool(StubDriver);

    var pool = try P.init(allocator, .{
        .connect = stubConnect,
        .min_connections = 1,
        .max_connections = 1,
        .health_check_on_borrow = false,
        .max_wait_ms = 5000,
        .max_retries = 0,
    });
    defer pool.deinit();

    const Holder = struct {
        pool: *P,
        held: std.atomic.Value(bool),
        release_now: std.atomic.Value(bool),

        fn run(self: *@This()) void {
            const conn = self.pool.borrow() catch unreachable;
            self.held.store(true, .release);
            // `std.Thread.yield` rather than `Io.sleep`: this thread was not
            // spawned by the pool's `Io`. The loop is bounded because every
            // main-thread path (including failures) flips `release_now`.
            while (!self.release_now.load(.acquire)) std.Thread.yield() catch {};
            self.pool.release(conn);
        }
    };

    const Waiter = struct {
        pool: *P,
        got: std.atomic.Value(bool),

        fn run(self: *@This()) void {
            const conn = self.pool.borrow() catch return;
            self.pool.release(conn);
            self.got.store(true, .release);
        }
    };

    var holder = Holder{
        .pool = &pool,
        .held = std.atomic.Value(bool).init(false),
        .release_now = std.atomic.Value(bool).init(false),
    };
    var waiter = Waiter{ .pool = &pool, .got = std.atomic.Value(bool).init(false) };

    const holder_thread = try std.Thread.spawn(.{}, Holder.run, .{&holder});
    var holder_ready = false;
    var spins: usize = 0;
    while (!holder_ready and spins < 5000) : (spins += 1) {
        holder_ready = holder.held.load(.acquire);
        if (!holder_ready) pool.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }

    const waiter_thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});

    // Deterministic synchronization point: a waiter registers its ticket and
    // starts waiting inside one critical section, so once the ticket is visible
    // the waiter is committed to parking and cannot miss the release. No
    // timing-based ordering is involved.
    var waiter_parked = false;
    spins = 0;
    while (!waiter_parked and spins < 5000) : (spins += 1) {
        const io = pool.io;
        pool.mutex.lockUncancelable(io);
        waiter_parked = pool.wait_tickets.items.len > 0;
        pool.mutex.unlock(io);
        if (!waiter_parked) pool.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }

    // Release unconditionally so a broken borrow fails assertions (or the
    // bounded `max_wait_ms` elapses) instead of hanging the test.
    holder.release_now.store(true, .release);
    holder_thread.join();
    waiter_thread.join();

    try std.testing.expect(holder_ready);
    try std.testing.expect(waiter_parked);
    try std.testing.expect(waiter.got.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), pool.wait_tickets.items.len);
}

test "ConnPool zero wait budget does not park a borrower" {
    const allocator = std.testing.allocator;
    const P = ConnPool(StubDriver);

    var pool = try P.init(allocator, .{
        .connect = stubConnect,
        .min_connections = 1,
        .max_connections = 1,
        .health_check_on_borrow = false,
        .max_wait_ms = 0,
        .max_retries = 0,
    });
    defer pool.deinit();

    const c1 = try pool.borrow();
    defer pool.release(c1);

    const started = std.Io.Clock.Timestamp.now(pool.io, .awake);
    try std.testing.expectError(error.PoolExhausted, pool.borrow());
    const elapsed_ms = started.untilNow(pool.io).raw.toMilliseconds();

    // The wait path is never entered: no ticket is taken and no condition wait
    // happens. The elapsed check is a generous sanity bound, not a timing
    // assertion.
    try std.testing.expectEqual(@as(usize, 0), pool.wait_tickets.items.len);
    try std.testing.expect(elapsed_ms < 1000);
}

test "ConnPool wait budget expiry returns PoolExhausted" {
    const allocator = std.testing.allocator;
    const P = ConnPool(StubDriver);

    var pool = try P.init(allocator, .{
        .connect = stubConnect,
        .min_connections = 1,
        .max_connections = 1,
        .health_check_on_borrow = false,
        .max_wait_ms = 50,
        .max_retries = 0,
    });
    defer pool.deinit();

    // Hold the only connection: the second borrow must park for its whole
    // budget and then report exhaustion rather than returning at once or
    // waiting forever.
    const c1 = try pool.borrow();
    defer pool.release(c1);

    const started = std.Io.Clock.Timestamp.now(pool.io, .awake);
    try std.testing.expectError(error.PoolExhausted, pool.borrow());
    const elapsed_ms = started.untilNow(pool.io).raw.toMilliseconds();

    try std.testing.expect(elapsed_ms >= 40);
    // The timed-out waiter must not leave a phantom ticket behind, or later
    // waiters would defer to a borrower that is no longer there.
    try std.testing.expectEqual(@as(usize, 0), pool.wait_tickets.items.len);
}
