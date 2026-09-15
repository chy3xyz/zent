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
    /// The caller's budget for waiting on a connection ran out (see
    /// `borrowWithTimeout` / `borrowCtx`). Deliberately not `PoolExhausted`:
    /// "the pool is too small" and "this request had only 200 ms to spare" are
    /// different facts, and only the second one is fixed by a shorter query.
    PoolWaitTimeout,
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
        /// The borrow-path health check no longer runs under the mutex: the
        /// entry is selected and marked under it, then pinged after it is
        /// released, so `health_check_on_borrow` no longer serializes concurrent
        /// borrows. Two things still touch the driver with the mutex held —
        /// `openConnection` (only when the pool is below `max_connections`) and
        /// `pingIdleConnections` — because both decide pool bookkeeping as they
        /// go.
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
            /// spend waiting for a connection once the pool is exhausted. It is
            /// an **upper bound**: when the budget is used up, `borrow` returns
            /// `error.PoolWaitTimeout` without the extra
            /// `max_retries` + `retry_backoff_ms` attempts, which used to make
            /// the documented budget overshoot by their sum.
            ///
            /// When non-zero, borrowers block on the pool condition variable
            /// instead of polling and are woken as soon as a connection is
            /// released (see `borrow` for the waiting/fairness contract).
            /// `borrowWithTimeout` / `borrowCtx` cap this per call: their own
            /// budget can only shorten the wait, never extend it.
            ///
            /// Zero (the default) means non-blocking: no waiting happens and a
            /// failed attempt immediately returns `error.PoolExhausted` (after
            /// the legacy retries). This preserves the historical behavior —
            /// including for `borrowWithTimeout`, which cannot turn a
            /// non-blocking pool back into a blocking one.
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
            /// deadline before invoking the underlying driver. The deadline
            /// covers waiting for a connection too: a statement that spends its
            /// whole budget queued behind a saturated pool fails with
            /// `error.PoolWaitTimeout` instead of running with no time left.
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
        /// Total borrows that gave up, for a dashboard: the number that says
        /// "the pool is too small" or "the database is gone".
        exhausted_total: u64 = 0,
        /// Why the most recent borrow attempt produced nothing. `tryBorrowNoLock`
        /// can fail for reasons that are *not* exhaustion — a refused connection,
        /// bad credentials, OOM — and folding all of them into `PoolExhausted`
        /// tells the caller to retry a configuration fault (consumers have mapped
        /// it to 503). Written and read under the mutex.
        last_attempt_error: ?anyerror = null,

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

        /// Map a recorded failure onto the bounded set `borrow` returns. The
        /// specific members a caller already switches on are preserved —
        /// `PoolExhausted` (capacity) stays distinguishable from
        /// `ConnectionFailed` (connectivity) — and anything else folds into
        /// `PoolExhausted` rather than widening this signature to `anyerror`,
        /// which would break `asDriver()`'s explicit error sets. The log line
        /// above carries the unmapped name, so nothing is hidden from operators.
        fn borrowErrorFor(err: anyerror) error{ ConnectionFailed, PingFailed, OutOfMemory, DriverFailed, PoolClosed, PoolExhausted, PoolWaitTimeout } {
            return switch (err) {
                error.ConnectionFailed => error.ConnectionFailed,
                error.PingFailed => error.PingFailed,
                error.OutOfMemory => error.OutOfMemory,
                error.DriverFailed => error.DriverFailed,
                error.PoolClosed => error.PoolClosed,
                error.PoolWaitTimeout => error.PoolWaitTimeout,
                else => error.PoolExhausted,
            };
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

        /// A connection picked by `selectNoLock`, and whether the pool opened it
        /// just now: the health check treats a fresh connection differently (see
        /// `tryBorrowNoLock`).
        const Selection = struct {
            entry: *PooledEntry,
            fresh: bool,
        };

        /// Non-blocking selection: hand out an idle connection (evicting stale
        /// ones) or open a new one, marking it borrowed. No health check runs
        /// here — `tryBorrowNoLock` runs that after dropping the mutex. The
        /// caller must hold `self.mutex`.
        fn selectNoLock(self: *Self) ?Selection {
            // Each attempt answers for itself; a later success means the earlier
            // reason no longer matters.
            self.last_attempt_error = null;
            while (true) {
                const entry = self.available.pop() orelse {
                    if (self.all.items.len < self.options.max_connections) {
                        // Open a new connection. This is the one driver call
                        // that still runs under the mutex: it decides whether
                        // the pool has room, and reserving the slot before the
                        // connect is what keeps `max_connections` a ceiling.
                        var new_conn = self.openConnection() catch |err| {
                            self.last_attempt_error = err;
                            return null;
                        };
                        const entry = self.allocator.create(PooledEntry) catch {
                            new_conn.close();
                            self.last_attempt_error = error.OutOfMemory;
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
                        return .{ .entry = entry, .fresh = true };
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
                            // Closing frees room below `max_connections`, so a
                            // parked borrower may be able to open a fresh one
                            // instead of waiting out its budget.
                            self.cond.signal(self.io);
                            continue;
                        }
                    }
                }

                // Mark as borrowed (no longer idle).
                entry.idle_since = null;
                return .{ .entry = entry, .fresh = false };
            }
        }

        /// `selectNoLock` plus the borrow-path health check, which runs
        /// **outside** the mutex: a ping is a network round trip, and holding
        /// the pool mutex across it serialized every other borrower behind one
        /// slow `PQping` (`ZENT_IMPROVEMENTS.md` item 4). This function
        /// therefore releases and re-acquires `self.mutex` around the ping; the
        /// caller must hold it on entry and holds it again on return.
        ///
        /// The selected entry is safe to ping unlocked: it has been popped from
        /// `available` and only its borrower can reach it, while `reapIdle` /
        /// `pingIdle` only look at entries still in `available` and `release`
        /// only accepts a pointer its own borrower holds.
        fn tryBorrowNoLock(self: *Self) ?*PooledEntry {
            const io = self.io;
            while (true) {
                const selected = self.selectNoLock() orelse return null;
                if (!self.options.health_check_on_borrow) return selected.entry;

                self.mutex.unlock(io);
                const checked = selected.entry.conn.asDriver().ping();
                self.mutex.lockUncancelable(io);

                if (checked) |_| {
                    return selected.entry;
                } else |_| {
                    self.closeConnection(selected.entry);
                    // Closing frees room below `max_connections`, so a parked
                    // borrower may be able to open a fresh one instead of
                    // waiting out its budget.
                    self.cond.signal(io);
                    // A *pooled* connection that fails its check is dropped and
                    // the next idle one is tried, as before. A freshly opened
                    // one that fails means the server is refusing everything:
                    // report no selection so the caller's wait/retry logic
                    // decides, instead of spinning here opening and discarding
                    // connections.
                    if (selected.fresh) return null;
                    continue;
                }
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

        /// Borrow a connection from the pool, waiting at most
        /// `options.max_wait_ms`.
        ///
        /// Performs idle eviction and health checks on each attempt; the health
        /// check runs outside the pool mutex (see `tryBorrowNoLock`).
        ///
        /// With the default `max_wait_ms == 0` the call is non-blocking: a
        /// failed attempt is retried up to `max_retries` times with linear
        /// `retry_backoff_ms` backoff, then reports `error.PoolExhausted`.
        ///
        /// When `max_wait_ms > 0` and no connection can be handed out or
        /// opened (the pool is exhausted, or opening one failed), the caller
        /// blocks on the pool condition variable instead of polling, and is
        /// woken as soon as a connection is released. `max_wait_ms` is the
        /// total budget for the whole call, measured from entry, and it is a
        /// **hard upper bound**: when it runs out the call reports
        /// `error.PoolWaitTimeout` rather than adding the legacy
        /// retry/backoff attempts on top of it. A failure that kept connections
        /// away (a refused connect, a failed health check, OOM) is still
        /// reported as itself; a closed pool reports `error.PoolClosed`.
        ///
        /// Waiting is **best-effort fair, not strict FIFO**: every blocked
        /// borrower holds a ticket and defers to a lower (older) ticket that is
        /// still waiting when a connection looks available. A waiter that is
        /// descheduled, timing out, or could not be ticketed (bookkeeping OOM)
        /// never blocks another borrower forever — after a bounded number of
        /// deferrals the connection goes to whichever waiter is awake.
        pub fn borrow(self: *Self) !*D {
            return self.borrowWithBudget(self.options.max_wait_ms);
        }

        /// `borrow` with a request-level budget of `request_ms`: the wait is
        /// capped at `min(request_ms, options.max_wait_ms)`, so a request can
        /// shorten the pool's wait but never lengthen it. A pool configured
        /// non-blocking (`max_wait_ms == 0`) stays non-blocking whatever the
        /// request asks for.
        ///
        /// Expiry reports `error.PoolWaitTimeout`, which says "this call's
        /// budget is gone" — not `PoolExhausted`, which says "the pool is too
        /// small" and is the answer to a different question
        /// (`ZENT_IMPROVEMENTS.md` item 3).
        pub fn borrowWithTimeout(self: *Self, request_ms: u32) !*D {
            return self.borrowWithBudget(@min(request_ms, self.options.max_wait_ms));
        }

        /// `borrow` bounded by the caller's own deadline: the budget is the
        /// execution context's remaining time, or `options.max_wait_ms` when
        /// the context carries no deadline, capped by `options.max_wait_ms`
        /// exactly like `borrowWithTimeout`. An already-expired deadline gets a
        /// single non-blocking attempt.
        ///
        /// Every pooled statement goes through here, so
        /// `Query().withTimeout(200)` spends that budget waiting for a
        /// connection instead of borrowing first (potentially for
        /// `max_wait_ms`) and only then noticing the deadline.
        pub fn borrowCtx(self: *Self, ctx: ?*const driver.ExecutionContext) !*D {
            const budget = if (ctx) |cx|
                (cx.remainingMs() orelse self.options.max_wait_ms)
            else
                self.options.max_wait_ms;
            return self.borrowWithBudget(@min(budget, self.options.max_wait_ms));
        }

        /// Shared body of every borrow entry point. `budget_ms` is the total
        /// wall-clock budget for this call; 0 selects the legacy non-blocking
        /// path, which needs no clock reads.
        fn borrowWithBudget(self: *Self, budget_ms: u32) !*D {
            const io = self.io;
            const waiting_enabled = budget_ms > 0;

            const wait_start: ?std.Io.Clock.Timestamp = if (waiting_enabled)
                std.Io.Clock.Timestamp.now(io, .awake)
            else
                null;
            const wait_deadline: std.Io.Timeout = if (wait_start) |start|
                .{ .deadline = start.addDuration(.{
                    .raw = std.Io.Duration.fromMilliseconds(@intCast(budget_ms)),
                    .clock = .awake,
                }) }
            else
                .none;

            var ticket: ?u64 = null;
            var deferrals: u32 = 0;
            var wait_done = !waiting_enabled;
            var attempt: u32 = 0;
            // Set when the blocked wait itself ran out: the caller had a budget
            // and the budget is what ended the call, which is a different
            // answer from "the pool is too small".
            var timed_out = false;

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
                                error.Timeout => {
                                    wait_done = true;
                                    timed_out = true;
                                },
                                // `borrow` has no `Canceled` in its error set
                                // (callers go through `driver.Error`), so treat
                                // a canceled wait as the end of the wait.
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
                // With a budget in effect, that budget is the whole budget:
                // once the wait ends, the legacy retry/backoff attempts would
                // silently overshoot the documented ceiling by
                // `max_retries × retry_backoff_ms`. The non-blocking path keeps
                // them.
                if (waiting_enabled) break;

                if (attempt >= self.options.max_retries) break;
                const backoff_ms: i64 = @as(i64, self.options.retry_backoff_ms) * (@as(i64, attempt) + 1);
                attempt += 1;
                io.sleep(std.Io.Duration.fromMilliseconds(backoff_ms), .awake) catch {};
            }

            // `PoolExhausted` only when the pool really is at its ceiling with
            // everything lent out and nothing in this call ran out of time;
            // otherwise the failure that actually happened travels to the
            // caller, and a consumer can tell "capacity" from
            // "misconfiguration" (see `ZENT_IMPROVEMENTS.md` item 3).
            self.exhausted_total += 1;
            const reason: anyerror = self.last_attempt_error orelse
                if (timed_out) error.PoolWaitTimeout else error.PoolExhausted;
            if (self.options.metrics.onError) |cb| cb(self.options.metrics.context, reason);
            // Silent exhaustion was the other half of that report: the pool had
            // no log line at all.
            const waited_ms: u64 = if (wait_start) |start|
                @intCast(@max(start.untilNow(io).raw.toMilliseconds(), 0))
            else
                0;
            std.log.warn(
                "zent pool: no connection could be handed out after {d} attempt(s) and {d} ms of waiting: {s}",
                .{ attempt + 1, waited_ms, @errorName(reason) },
            );
            return borrowErrorFor(reason);
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
                // pool. A rollback that **fails** is not ignorable: the connection
                // may still be inside that transaction, and the next borrower would
                // then run its statements inside someone else's transaction — the
                // silent-state-divergence shape this pool has been bitten by
                // before. A connection we could not clean is dropped, not handed on.
                if (conn.asDriver().inTransaction()) {
                    if (conn.asDriver().exec("ROLLBACK", &.{})) |_| {
                        // MySQL tracks transaction state client-side; clear the
                        // stale flag only after a rollback that actually worked.
                        if (@hasField(D, "in_tx")) {
                            conn.in_tx = false;
                        }
                    } else |_| {
                        self.closeConnection(entry);
                        self.cond.signal(io);
                        return;
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

        /// A snapshot of the pool, for a metrics scrape or a health endpoint.
        ///
        /// Everything a consumer previously had to read out of the internal
        /// lists — one of them without holding the mutex, which is a data race
        /// waiting to happen (`examples/pool/main.zig` did exactly that).
        pub const Stats = struct {
            /// Connections the pool holds, idle or lent out.
            total: usize,
            /// Lent out right now.
            in_use: usize,
            /// Idle and available.
            available: usize,
            /// Borrowers blocked on the condition variable.
            waiters: usize,
            /// Borrows that gave up since the pool was created.
            exhausted_total: u64,
            closed: bool,
        };

        pub fn stats(self: *Self) Stats {
            const io = self.io;
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            return .{
                .total = self.all.items.len,
                .in_use = self.all.items.len - self.available.items.len,
                .available = self.available.items.len,
                .waiters = self.wait_tickets.items.len,
                .exhausted_total = self.exhausted_total,
                .closed = self.closed,
            };
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
            // The deadline is computed *before* borrowing so it covers the
            // wait for a connection: previously the statement's budget only
            // started once a connection had been found, so on a saturated pool
            // twelve statements each waited out `max_wait_ms` and then ran with
            // the time already spent (`ZENT_IMPROVEMENTS.md` item 3).
            var merged = pool.mergeExecutionContext(ctx);
            const ctx_ptr: ?*const driver.ExecutionContext = if (merged.deadline_ns != null) &merged else null;
            const conn = try pool.borrowCtx(ctx_ptr);
            defer pool.release(conn);
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
            var merged = pool.mergeExecutionContext(ctx);
            const ctx_ptr: ?*const driver.ExecutionContext = if (merged.deadline_ns != null) &merged else null;
            const conn = try pool.borrowCtx(ctx_ptr);
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

        fn driverPrepareCheck(ptr: *anyopaque, allocator: std.mem.Allocator, sql: []const u8, args: []const Value, out: *driver.CheckReport) driver.Error!void {
            const pool: *Self = @ptrCast(@alignCast(ptr));
            const conn = try pool.borrowForDriver();
            defer pool.release(conn);
            return conn.asDriver().prepareCheck(allocator, sql, args, out);
        }

        fn driverBeginTx(ptr: *anyopaque) driver.Error!driver.Tx {
            const pool: *Self = @ptrCast(@alignCast(ptr));
            return beginTxWithCtx(pool, null);
        }

        fn driverBeginTxCtx(ptr: *anyopaque, ctx: ?*const driver.ExecutionContext) driver.Error!driver.Tx {
            const pool: *Self = @ptrCast(@alignCast(ptr));
            return beginTxWithCtx(pool, ctx);
        }

        /// Acquiring a transaction is a borrow plus a `BEGIN`, and the borrow is
        /// the part that can block. With a deadline in `ctx` it is bounded by
        /// that deadline: a request with 200 ms left must fail there rather than
        /// queue for `max_wait_ms` behind a saturated pool and then run its
        /// statements with no time left. Without one the pool's `max_wait_ms`
        /// applies, exactly as `borrow` would.
        fn beginTxWithCtx(pool: *Self, ctx: ?*const driver.ExecutionContext) driver.Error!driver.Tx {
            const conn = try pool.borrowCtx(ctx);
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
            .prepareCheck = driverPrepareCheck,
            .beginTx = driverBeginTx,
            .beginTxCtx = driverBeginTxCtx,
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

/// A driver that claims to be inside a transaction and **fails** to roll it
/// back — the shape the pool's transaction-leak protection has to refuse to hand
/// on. `close` records the id so a test can tell whether the pool dropped the
/// connection or put it back in `available`.
const StuckTxDriver = struct {
    id: usize = 0,

    var next_id: usize = 0;
    var closed_id: usize = 0;

    pub fn asDriver(self: *@This()) driver.Driver {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn close(self: *@This()) void {
        closed_id = self.id;
    }

    fn stuckExec(_: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const Value) driver.Error!driver.Result {
        // The only statement this path issues is `ROLLBACK`, and it fails: the
        // connection is stuck inside someone else's transaction.
        return error.ExecFailed;
    }
    fn stuckQuery(_: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const Value) driver.Error!driver.Rows {
        unreachable;
    }
    fn stuckBeginTx(_: *anyopaque) driver.Error!driver.Tx {
        unreachable;
    }
    fn stuckBeginSavepoint(_: *anyopaque, _: []const u8) driver.Error!driver.Tx {
        unreachable;
    }
    fn stuckClose(_: *anyopaque) void {
        unreachable;
    }
    fn stuckDialect(_: *anyopaque) Dialect {
        return .sqlite;
    }
    fn stuckPing(_: *anyopaque) driver.Error!void {}
    fn stuckInTransaction(_: *anyopaque) bool {
        return true;
    }

    const vtable = driver.Driver.VTable{
        .exec = stuckExec,
        .query = stuckQuery,
        .beginTx = stuckBeginTx,
        .close = stuckClose,
        .dialect = stuckDialect,
        .ping = stuckPing,
        .inTransaction = stuckInTransaction,
        .beginSavepoint = stuckBeginSavepoint,
    };
};

fn stuckConnect(allocator: std.mem.Allocator) anyerror!StuckTxDriver {
    _ = allocator;
    StuckTxDriver.next_id += 1;
    return StuckTxDriver{ .id = StuckTxDriver.next_id };
}

test "a connection whose leaked transaction cannot be rolled back is dropped" {
    // The leak protection rolls back a connection returned with an active
    // transaction. When that rollback FAILS the connection may still be inside
    // the transaction, and pooling it would leave the next borrower running its
    // statements inside someone else's — so it must be closed instead. The
    // successful-rollback case has a test; the failing one did not, which is
    // why the error was swallowed rather than acted on.
    const allocator = std.heap.page_allocator;
    const P = ConnPool(StuckTxDriver);
    StuckTxDriver.closed_id = 0;

    var pool = try P.init(allocator, .{
        .connect = stuckConnect,
        .min_connections = 1,
        .max_connections = 1,
        .health_check_on_borrow = false,
        .max_retries = 0,
    });
    defer pool.deinit();

    const conn = try pool.borrow();
    try std.testing.expectEqual(@as(usize, 1), pool.stats().total);
    const id = conn.id;

    pool.release(conn);

    // Not pooled: the pool grew a connection to lend and holds none after it.
    try std.testing.expectEqual(id, StuckTxDriver.closed_id);
    const stats = pool.stats();
    try std.testing.expectEqual(@as(usize, 0), stats.total);
    try std.testing.expectEqual(@as(usize, 0), stats.available);
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

test "ConnPool wait budget expiry returns PoolWaitTimeout" {
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
    // budget and then report *its own* budget expiring rather than returning at
    // once, waiting forever, or answering `PoolExhausted` — which says "the
    // pool is too small" and is the wrong thing to tell a caller that asked for
    // a bounded wait (`ZENT_IMPROVEMENTS.md` item 3).
    const c1 = try pool.borrow();
    defer pool.release(c1);

    const started = std.Io.Clock.Timestamp.now(pool.io, .awake);
    try std.testing.expectError(error.PoolWaitTimeout, pool.borrow());
    const elapsed_ms = started.untilNow(pool.io).raw.toMilliseconds();

    try std.testing.expect(elapsed_ms >= 40);
    // The timed-out waiter must not leave a phantom ticket behind, or later
    // waiters would defer to a borrower that is no longer there.
    try std.testing.expectEqual(@as(usize, 0), pool.wait_tickets.items.len);
    try std.testing.expectEqual(@as(u64, 1), pool.stats().exhausted_total);
}

test "max_wait_ms is a hard upper bound, not a floor for the retry path" {
    const allocator = std.testing.allocator;
    const P = ConnPool(StubDriver);

    var pool = try P.init(allocator, .{
        .connect = stubConnect,
        .min_connections = 1,
        .max_connections = 1,
        .health_check_on_borrow = false,
        .max_wait_ms = 50,
        // With the legacy fallback these add 100+200+…+800 = 3600 ms of sleeps
        // *after* the 50 ms budget, which is how a documented budget turned into
        // "whatever the retry policy says".
        .max_retries = 8,
        .retry_backoff_ms = 100,
    });
    defer pool.deinit();

    const c1 = try pool.borrow();
    defer pool.release(c1);

    const started = std.Io.Clock.Timestamp.now(pool.io, .awake);
    try std.testing.expectError(error.PoolWaitTimeout, pool.borrow());
    const elapsed_ms = started.untilNow(pool.io).raw.toMilliseconds();

    try std.testing.expect(elapsed_ms >= 40);
    try std.testing.expect(elapsed_ms < 500);
}

test "borrowWithTimeout caps the wait, and cannot un-cap a non-blocking pool" {
    const allocator = std.testing.allocator;
    const P = ConnPool(StubDriver);

    // A 50 ms request budget under a 1000 ms pool budget: the request wins.
    var pool = try P.init(allocator, .{
        .connect = stubConnect,
        .min_connections = 1,
        .max_connections = 1,
        .health_check_on_borrow = false,
        .max_wait_ms = 1000,
        .max_retries = 0,
    });
    defer pool.deinit();

    const c1 = try pool.borrow();
    defer pool.release(c1);

    const started = std.Io.Clock.Timestamp.now(pool.io, .awake);
    try std.testing.expectError(error.PoolWaitTimeout, pool.borrowWithTimeout(50));
    const elapsed_ms = started.untilNow(pool.io).raw.toMilliseconds();
    try std.testing.expect(elapsed_ms >= 40);
    try std.testing.expect(elapsed_ms < 400);

    // A pool that never blocks stays that way: the request budget can only
    // shorten the pool's wait, never introduce one.
    var nb = try P.init(allocator, .{
        .connect = stubConnect,
        .min_connections = 1,
        .max_connections = 1,
        .health_check_on_borrow = false,
        .max_wait_ms = 0,
        .max_retries = 0,
    });
    defer nb.deinit();

    const nb_held = try nb.borrow();
    defer nb.release(nb_held);

    const nb_started = std.Io.Clock.Timestamp.now(nb.io, .awake);
    try std.testing.expectError(error.PoolExhausted, nb.borrowWithTimeout(500));
    const nb_elapsed_ms = nb_started.untilNow(nb.io).raw.toMilliseconds();
    try std.testing.expect(nb_elapsed_ms < 200);
    try std.testing.expectEqual(@as(usize, 0), nb.wait_tickets.items.len);
}

test "borrowCtx spends the request deadline, not the pool budget" {
    const allocator = std.testing.allocator;
    const P = ConnPool(StubDriver);

    var pool = try P.init(allocator, .{
        .connect = stubConnect,
        .min_connections = 1,
        .max_connections = 1,
        .health_check_on_borrow = false,
        .max_wait_ms = 1000,
        .max_retries = 0,
    });
    defer pool.deinit();

    const c1 = try pool.borrow();
    defer pool.release(c1);

    // The deadline a builder puts on a statement (`Query().withTimeout(…)`)
    // becomes the borrow budget, so a request that is nearly out of time does
    // not queue for the pool's full second.
    const ctx = driver.ExecutionContext{ .deadline_ns = driver.monotonicNs() + 50 * std.time.ns_per_ms };
    const started = std.Io.Clock.Timestamp.now(pool.io, .awake);
    try std.testing.expectError(error.PoolWaitTimeout, pool.borrowCtx(&ctx));
    const elapsed_ms = started.untilNow(pool.io).raw.toMilliseconds();
    try std.testing.expect(elapsed_ms >= 40);
    try std.testing.expect(elapsed_ms < 400);

    // The cap works in both directions: a request with 5 s to spare still gets
    // the pool's 50 ms, so no caller can extend the wait the pool was
    // configured with.
    var tight = try P.init(allocator, .{
        .connect = stubConnect,
        .min_connections = 1,
        .max_connections = 1,
        .health_check_on_borrow = false,
        .max_wait_ms = 50,
        .max_retries = 0,
    });
    defer tight.deinit();

    const held = try tight.borrow();
    defer tight.release(held);

    const generous = driver.ExecutionContext{ .deadline_ns = driver.monotonicNs() + 5000 * std.time.ns_per_ms };
    const started2 = std.Io.Clock.Timestamp.now(tight.io, .awake);
    try std.testing.expectError(error.PoolWaitTimeout, tight.borrowCtx(&generous));
    const elapsed_ms2 = started2.untilNow(tight.io).raw.toMilliseconds();
    try std.testing.expect(elapsed_ms2 >= 40);
    try std.testing.expect(elapsed_ms2 < 400);
}

test "an unusable factory reports its own error instead of PoolExhausted" {
    const SQLiteDriver = @import("sqlite.zig").SQLiteDriver;
    // `PoolExhausted` means "at the ceiling with everything lent out". A refused
    // connection or a bad password is not that, and consumers act on the
    // difference (one mapped `PoolExhausted` to 503 and retried a configuration
    // fault forever). The cause must survive, and the metrics callback must see
    // it rather than a constant.
    const allocator = std.testing.allocator;
    const testing = std.testing;

    // Succeeds once (so `init` can warm up), then refuses: the second borrow has
    // to open a connection, which is the path being tested.
    const Factory = struct {
        opened: usize = 0,

        fn f(ctx: ?*anyopaque, a: std.mem.Allocator) anyerror!SQLiteDriver {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.opened += 1;
            if (self.opened == 1) return SQLiteDriver.open(a, ":memory:");
            return error.ConnectionFailed;
        }
    };
    const OnError = struct {
        fn f(ctx: ?*anyopaque, err: anyerror) void {
            const slot: *?anyerror = @ptrCast(@alignCast(ctx.?));
            slot.* = err;
        }
    };

    var factory = Factory{};
    var seen: ?anyerror = null;
    var pool = try ConnPool(SQLiteDriver).init(allocator, .{
        .min_connections = 1,
        .max_connections = 2,
        .connect_ctx = &factory,
        .connectCtx = Factory.f,
        .health_check_on_borrow = false,
        .max_retries = 0,
        .metrics = .{ .context = &seen, .onError = OnError.f, .onWait = null },
    });
    defer pool.deinit();

    const first = try pool.borrow();
    // `stats()` is the observability the report asked for (#13): a snapshot
    // under the mutex, where the shipping example used to read the internal
    // lists unlocked.
    {
        const held = pool.stats();
        try testing.expectEqual(@as(usize, 1), held.total);
        try testing.expectEqual(@as(usize, 1), held.in_use);
        try testing.expectEqual(@as(usize, 0), held.available);
        try testing.expectEqual(@as(u64, 0), held.exhausted_total);
    }
    // Nothing is available and the pool is below its ceiling, so this one has to
    // open a connection — and the factory refuses.
    try std.testing.expectError(error.ConnectionFailed, pool.borrow());
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionFailed), seen);
    try testing.expectEqual(@as(u64, 1), pool.stats().exhausted_total);
    pool.release(first);
    {
        const idle = pool.stats();
        try testing.expectEqual(@as(usize, 0), idle.in_use);
        try testing.expectEqual(@as(usize, 1), idle.available);
    }
}

test "a pooled statement's deadline bounds its wait for a connection" {
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
        .max_wait_ms = 1000,
        .max_retries = 0,
    });
    defer pool.deinit();

    // Hold the only connection: the statement below has nowhere to run. Its own
    // 50 ms deadline must end the call — the deadline used to be merged only
    // *after* a connection had been borrowed, so a request could spend the
    // whole pool budget queued and then run its statements with no time left
    // (`ZENT_IMPROVEMENTS.md` item 3: twelve statements per request, each
    // waiting `max_wait_ms`).
    const held = try pool.borrow();
    defer pool.release(held);

    const ctx = driver.ExecutionContext{ .deadline_ns = driver.monotonicNs() + 50 * std.time.ns_per_ms };
    const started = std.Io.Clock.Timestamp.now(pool.io, .awake);
    try std.testing.expectError(error.PoolWaitTimeout, pool.asDriver().execCtx(&ctx, "SELECT 1", &.{}));
    const elapsed_ms = started.untilNow(pool.io).raw.toMilliseconds();
    try std.testing.expect(elapsed_ms >= 40);
    try std.testing.expect(elapsed_ms < 400);
}

test "a pooled transaction's deadline bounds its wait for a connection" {
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
        .max_wait_ms = 1000,
        .max_retries = 0,
    });
    defer pool.deinit();
    const drv = pool.asDriver();

    // The fallback path stays intact: no ctx, no deadline, the pool's own
    // budget applies and an uncontended acquisition just works.
    {
        var tx = try drv.beginTxCtx(null);
        try tx.commit();
        tx.deinit();
    }

    const held = try pool.borrow();
    defer pool.release(held);

    const ctx = driver.ExecutionContext{ .deadline_ns = driver.monotonicNs() + 50 * std.time.ns_per_ms };
    const started = std.Io.Clock.Timestamp.now(pool.io, .awake);
    try std.testing.expectError(error.PoolWaitTimeout, drv.beginTxCtx(&ctx));
    const elapsed_ms = started.untilNow(pool.io).raw.toMilliseconds();
    try std.testing.expect(elapsed_ms >= 40);
    try std.testing.expect(elapsed_ms < 400);
}

test "ConnPool runs the borrow-path health check outside the mutex" {
    // A ping is a network round trip. Running it under the pool mutex made
    // `health_check_on_borrow` serialize every borrower behind one slow
    // `PQping`; the consumer measured that and turned the check off, which left
    // them no way to notice a dead connection at all.
    const BlockingPing = struct {
        pub var ping_started = std.atomic.Value(bool).init(false);
        pub var release_ping = std.atomic.Value(bool).init(false);

        id: usize = 0,

        pub fn asDriver(self: *@This()) driver.Driver {
            return .{ .ptr = self, .vtable = &vtable };
        }

        pub fn close(self: *@This()) void {
            _ = self;
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
            ping_started.store(true, .release);
            while (!release_ping.load(.acquire)) std.Thread.yield() catch {};
        }
        fn mockInTransaction(_: *anyopaque) bool {
            // `release` asks this of every connection it takes back.
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

    // Threads share the pool, so the single-threaded testing allocator is out.
    const allocator = std.heap.page_allocator;
    const P = ConnPool(BlockingPing);

    var pool = try P.init(allocator, .{
        .connect = struct {
            fn f(a: std.mem.Allocator) !BlockingPing {
                _ = a;
                return BlockingPing{};
            }
        }.f,
        .min_connections = 1,
        .max_connections = 1,
        .health_check_on_borrow = true,
        .max_wait_ms = 0,
        .max_retries = 0,
    });
    defer pool.deinit();

    const Borrower = struct {
        pool: *P,
        got: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            const conn = self.pool.borrow() catch return;
            self.pool.release(conn);
            self.got.store(true, .release);
        }
    };
    const Observer = struct {
        pool: *P,
        stats_done: std.atomic.Value(bool),

        fn run(self: *@This()) void {
            _ = self.pool.stats();
            self.stats_done.store(true, .release);
        }
    };

    var borrower = Borrower{ .pool = &pool };
    const borrower_thread = try std.Thread.spawn(.{}, Borrower.run, .{&borrower});

    // The borrower is now inside the driver's ping, which blocks until we let
    // it go — so whatever the pool does next, it does while a ping is in flight.
    var spins: usize = 0;
    while (!BlockingPing.ping_started.load(.acquire) and spins < 5000) : (spins += 1) {
        pool.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(BlockingPing.ping_started.load(.acquire));

    var observer = Observer{ .pool = &pool, .stats_done = std.atomic.Value(bool).init(false) };
    const observer_thread = try std.Thread.spawn(.{}, Observer.run, .{&observer});

    spins = 0;
    while (!observer.stats_done.load(.acquire) and spins < 300) : (spins += 1) {
        pool.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    // Read *before* the ping is released: if the mutex were held across the
    // ping, `stats()` could not have returned while the ping was in flight.
    const stats_returned_during_ping = observer.stats_done.load(.acquire);

    // Unblock unconditionally, so a regression fails the assertion below
    // instead of hanging the run.
    BlockingPing.release_ping.store(true, .release);
    borrower_thread.join();
    observer_thread.join();

    try std.testing.expect(stats_returned_during_ping);
    try std.testing.expect(borrower.got.load(.acquire));
}

// ------------------------------------------------------------------
// Stress tests: a pool under concurrent borrow, release and eviction
// ------------------------------------------------------------------
//
// Both of the pool's historical failures were bookkeeping bugs, not logic
// bugs: one entry lent to two borrowers while a `swapRemove` recycled the slot
// it lived in (the borrowed pointer aliased a recycled slot), and one
// connection returned to `available` still carrying somebody else's
// transaction. Neither is reachable from a single-threaded test, and neither
// shows up as a *timing* claim: where the bug lands depends on the scheduler,
// so a timing assertion would be flaky rather than wrong.
//
// Everything below therefore asserts invariants — facts that must hold after
// every operation, whatever the interleaving — and never an ordering or a
// duration. Each invariant is a probe for one of those shapes:
//
//   1. a connection is never inside two borrowers at once (`holder`,
//      `live`);
//   2. a borrowed connection is still its own entry after a storm of
//      insert/evict churn (`guard`);
//   3. closing connections concurrently with borrowing them (ping failures,
//      `reapIdleConnections`, `pingIdleConnections`) does not break 1 or 2;
//   4. the books balance once everyone has let go: `total == available`,
//      `in_use == 0`, `waiters == 0`;
//   5. the pool never lends out more than `max_connections` at one time;
//   6. every parked waiter is eventually served.

/// A spin lock for the harness registry. `std.atomic.Mutex` is a raw try-lock
/// and that is enough here: the critical sections are a couple of hash-map
/// operations wide, and the lock is taken from threads the pool did not spawn
/// (an `Io.Mutex` needs an `Io` to unlock).
const StressLock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *@This()) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *@This()) void {
        self.inner.unlock();
    }
};

/// Shared, cross-thread bookkeeping for the stress tests.
///
/// The registry (`live`) is the direct probe for a double lend: a connection
/// address that is already in the table when another borrower arrives is the
/// pool having handed one entry to two borrowers. `peak` is the same table's
/// high-water mark, which is what proves `max_connections` stayed a ceiling.
const StressState = struct {
    allocator: std.mem.Allocator,
    lock: StressLock = .{},

    /// Connection address -> borrower token, one entry per live borrow.
    live: std.AutoHashMapUnmanaged(usize, u64) = .empty,
    /// Highest number of simultaneous borrows seen.
    peak: usize = 0,
    /// Borrows registered, releases unregistered.
    borrows: usize = 0,
    releases: usize = 0,
    /// A borrower found the driver canary overwritten (invariant 2).
    guard_violations: usize = 0,
    /// A borrower entered, or left, a connection whose holder slot said
    /// somebody else was inside it (invariant 1).
    holder_violations: usize = 0,
    /// A connection address was already registered as lent (invariant 1).
    double_lends: usize = 0,
    /// A release unregistered an address that was never lent.
    stray_releases: usize = 0,
    /// The harness itself could not record — an allocation failure, not a pool
    /// bug, but it would silently blind the probes, so it fails the test too.
    registry_failures: usize = 0,

    connects: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    closes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    pings: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    ping_failures: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Borrows that returned an error instead of a connection.
    borrow_errors: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Borrows that had to park (`Metrics.onWait`).
    waits: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Connections `reapIdleConnections` dropped, and how often it ran.
    reaped: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    reap_passes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    idle_ping_passes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// 0 = every connection passes its health check. Otherwise a connection
    /// fails from its `fail_ping_after`-th check onwards, so the pool drops it
    /// — from `selectNoLock`'s borrow path, or from `pingIdleConnections` —
    /// and opens a replacement while other threads are inside other entries.
    /// That close-open pair is where the historical slot-recycling aliased a
    /// live borrow.
    ///
    /// The check right after the pool opened a connection has to pass, which is
    /// why this counts checks per connection rather than connections: a *fresh*
    /// connection that fails its check makes `borrow` park until its budget
    /// runs out even though the pool has room to open another, and with a
    /// borrower holding a connection for the whole storm there is nobody left
    /// to signal it. That stall is a real behaviour of this pool (it is not
    /// what these tests are about), and it is not what makes a connection get
    /// dropped while another is in flight — the later checks are.
    fail_ping_after: usize = 0,
    /// Tells the threads that outlive the borrowers (the reaper, the holder)
    /// that the storm is over.
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// A live borrow: the connection and the token registered for it.
    const Borrow = struct {
        conn: *StressDriver,
        token: u64,
    };

    fn setup(self: *StressState, allocator: std.mem.Allocator) !void {
        self.* = .{ .allocator = allocator };
        // Reserved up front: `enter` runs under a spin lock and must not
        // allocate there.
        try self.live.ensureTotalCapacity(allocator, 64);
    }

    /// Pool options shared by the stress tests: a real health check on borrow
    /// (the path that evicts stale entries), no legacy retry/backoff, and a
    /// wait budget so a borrower queues instead of failing outright.
    fn options(self: *StressState, min: usize, max: usize, wait_ms: u32) StressPool.Options {
        return .{
            .connect_ctx = self,
            .connectCtx = StressDriver.connectCtx,
            .min_connections = min,
            .max_connections = max,
            .health_check_on_borrow = true,
            .max_wait_ms = wait_ms,
            .max_retries = 0,
            .metrics = .{ .context = self, .onWait = onWait },
        };
    }

    fn onWait(ctx: ?*anyopaque) void {
        const self: *StressState = @ptrCast(@alignCast(ctx.?));
        _ = self.waits.fetchAdd(1, .monotonic);
    }

    /// Borrow and register. Null when the pool reported an error instead of a
    /// connection (the caller counts it; the tests assert on how many).
    fn borrowOne(self: *StressState, pool: *StressPool) ?Borrow {
        const conn = pool.borrow() catch {
            _ = self.borrow_errors.fetchAdd(1, .monotonic);
            return null;
        };
        return .{ .conn = conn, .token = self.enter(conn) };
    }

    /// Unregister and hand back. The probes run first: after `release` the
    /// entry may be closed and its memory gone.
    fn releaseOne(self: *StressState, pool: *StressPool, b: Borrow) void {
        self.leave(b.conn, b.token);
        pool.release(b.conn);
    }

    /// Run the borrow-side probes and register the connection as lent. Returns
    /// the token `leave` expects.
    fn enter(self: *StressState, conn: *StressDriver) u64 {
        self.lock.lock();
        defer self.lock.unlock();

        if (conn.guard != StressDriver.guard_value) self.guard_violations += 1;

        self.borrows += 1;
        const token: u64 = self.borrows;
        if (conn.holder.cmpxchgStrong(0, token, .acq_rel, .acquire) != null) {
            // Somebody else is already inside this connection.
            self.holder_violations += 1;
        }

        const slot = self.live.getOrPut(self.allocator, @intFromPtr(conn)) catch {
            self.registry_failures += 1;
            return token;
        };
        if (slot.found_existing) {
            self.double_lends += 1;
        } else {
            slot.value_ptr.* = token;
        }
        const lent = self.live.count();
        if (lent > self.peak) self.peak = lent;
        return token;
    }

    /// Run the release-side probes and unregister the connection.
    fn leave(self: *StressState, conn: *StressDriver, token: u64) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (conn.guard != StressDriver.guard_value) self.guard_violations += 1;
        self.releases += 1;
        if (conn.holder.cmpxchgStrong(token, 0, .acq_rel, .acquire) != null) {
            // The slot was not ours any more: either the entry was lent twice,
            // or the memory we are standing on is no longer our entry.
            self.holder_violations += 1;
        }
        if (!self.live.remove(@intFromPtr(conn))) self.stray_releases += 1;
    }
};

/// A connection for the stress tests. The fields are probes rather than
/// payload:
///
///   * `guard` is a canary written once, when the pool constructs the
///     connection. Borrowers re-read it on entry and before handing the
///     connection back, so memory that was moved or recycled underneath a live
///     borrow shows up as a missing canary instead of as a silent alias.
///   * `holder` names the borrower currently inside the connection, `0` when
///     nobody holds it. The pool must never lend one entry to two borrowers,
///     and that is what the `cmpxchg` in `enter` refuses to let happen twice.
///   * `checks` counts the health checks this one connection has answered; see
///     `StressState.fail_ping_after` for what the count drives.
const StressDriver = struct {
    const guard_value: u64 = 0x5eed_0cce_c0de_5eed;

    guard: u64 = guard_value,
    holder: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    checks: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    state: *StressState,

    pub fn asDriver(self: *@This()) driver.Driver {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn close(self: *@This()) void {
        _ = self.state.closes.fetchAdd(1, .monotonic);
    }

    fn connectCtx(ctx: ?*anyopaque, _: std.mem.Allocator) anyerror!StressDriver {
        const state: *StressState = @ptrCast(@alignCast(ctx.?));
        _ = state.connects.fetchAdd(1, .monotonic);
        return .{ .state = state };
    }

    fn stressExec(_: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const Value) driver.Error!driver.Result {
        unreachable;
    }
    fn stressQuery(_: *anyopaque, _: ?*const driver.ExecutionContext, _: []const u8, _: []const Value) driver.Error!driver.Rows {
        unreachable;
    }
    fn stressBeginTx(_: *anyopaque) driver.Error!driver.Tx {
        unreachable;
    }
    fn stressBeginSavepoint(_: *anyopaque, _: []const u8) driver.Error!driver.Tx {
        unreachable;
    }
    fn stressClose(_: *anyopaque) void {
        unreachable;
    }
    fn stressDialect(_: *anyopaque) Dialect {
        return .sqlite;
    }
    fn stressPing(ptr: *anyopaque) driver.Error!void {
        const self: *StressDriver = @ptrCast(@alignCast(ptr));
        _ = self.state.pings.fetchAdd(1, .monotonic);
        const after = self.state.fail_ping_after;
        if (after != 0 and self.checks.fetchAdd(1, .monotonic) + 1 >= after) {
            _ = self.state.ping_failures.fetchAdd(1, .monotonic);
            return error.PingFailed;
        }
    }
    fn stressInTransaction(_: *anyopaque) bool {
        return false;
    }

    const vtable = driver.Driver.VTable{
        .exec = stressExec,
        .query = stressQuery,
        .beginTx = stressBeginTx,
        .close = stressClose,
        .dialect = stressDialect,
        .ping = stressPing,
        .inTransaction = stressInTransaction,
        .beginSavepoint = stressBeginSavepoint,
    };
};

const StressPool = ConnPool(StressDriver);

/// A borrower that hammers the pool the way a request-serving thread does.
const StressWorker = struct {
    state: *StressState,
    pool: *StressPool,
    iterations: usize,
    /// Backdate the entry this worker holds, so the pool's own max-lifetime
    /// rule drops it in `release` instead of pooling it. That makes the
    /// close-a-connection-while-another-is-borrowed race deterministic: without
    /// it the pool can sit at its ceiling with the same connections for a whole
    /// run and never recycle an entry, which is exactly what made the first
    /// version of this test miss the path it was written for. `created_at` is
    /// only read by `release` (by this same thread) and written at creation, so
    /// the borrower may touch it before handing the connection back.
    evict_on_release: bool = false,

    fn run(self: *@This()) void {
        for (0..self.iterations) |_| {
            const b = self.state.borrowOne(self.pool) orelse continue;
            // Hold the connection across a scheduling point so the threads
            // really contend for the same slots instead of running one after
            // the other.
            std.Thread.yield() catch {};
            if (self.evict_on_release) {
                const entry: *StressPool.PooledEntry = @fieldParentPtr("conn", b.conn);
                entry.created_at = unixTimestamp() - 3600;
            }
            self.state.releaseOne(self.pool, b);
        }
    }
};

/// A borrower that stays inside one connection for the whole storm.
///
/// The *pointer* a borrower holds cannot move — what can move is the memory at
/// the other end of it, which is exactly what the historical entry-recycling
/// bug did (an entry `swapRemove`d while borrowed, or a `PooledEntry` freed and
/// re-created at the same address for another borrower). The borrowed driver
/// carries a canary and its own holder slot, so re-reading both after the storm
/// says whether the connection is still the same live entry; touching it
/// afterwards is the use-after-free the old layout produced.
const StressHolder = struct {
    state: *StressState,
    pool: *StressPool,
    /// Set once the connection is in hand, so the test starts the storm knowing
    /// a live borrow is in flight.
    holding: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set when the connection still passed its probes after the storm.
    intact: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *@This()) void {
        const b = self.state.borrowOne(self.pool) orelse {
            // Nothing to hold: unblock the test instead of hanging it.
            self.state.stop.store(true, .release);
            return;
        };
        self.holding.store(true, .release);
        while (!self.state.stop.load(.acquire)) std.Thread.yield() catch {};

        const canary_ok = b.conn.guard == StressDriver.guard_value;
        const still_ours = b.conn.holder.load(.acquire) == b.token;
        // Use the connection the way its borrower would after the storm. With
        // the entry freed or recycled underneath it, this read is the
        // use-after-free the old layout produced (the historical symptom was a
        // segfault inside the driver's own health check).
        b.conn.asDriver().ping() catch {};
        self.intact.store(canary_ok and still_ours, .release);

        self.state.releaseOne(self.pool, b);
    }
};

/// The eviction pressure: everything the pool closes while other threads are
/// borrowing.
const StressReaper = struct {
    state: *StressState,
    pool: *StressPool,
    /// Set once a full pass has run, so the test can start its assertions
    /// knowing the idle-scan paths met live borrowers rather than trusting that
    /// the thread was scheduled.
    passed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *@This()) void {
        while (!self.state.stop.load(.acquire)) {
            // Idleness is measured in whole `unixTimestamp()` seconds, so a
            // real reap would need the test to sit idle for a second — and even
            // then it would only happen if a connection was idle across a
            // second boundary. Backdating what is idle right now is the same
            // thing from the pool's point of view while the pool mutex is held,
            // and it keeps the storm short.
            //
            // A borrower that picks up a backdated entry usually closes it
            // itself (`selectNoLock` applies the same idle rule), so what the
            // reap below catches is whatever the borrowers left behind — the
            // point of the pass is that closing and borrowing overlap, not that
            // a particular call site does the closing.
            const io = self.pool.io;
            self.pool.mutex.lockUncancelable(io);
            const now = unixTimestamp();
            for (self.pool.available.items) |entry| entry.idle_since = now - 60;
            self.pool.mutex.unlock(io);

            _ = self.state.idle_ping_passes.fetchAdd(1, .monotonic);
            _ = self.pool.pingIdleConnections();
            _ = self.state.reap_passes.fetchAdd(1, .monotonic);
            _ = self.state.reaped.fetchAdd(self.pool.reapIdleConnections(1), .monotonic);
            self.passed.store(true, .release);
        }
    }
};

/// A waiter that parks, is woken, and does it again.
const StressWaiter = struct {
    state: *StressState,
    pool: *StressPool,
    cycles: usize,

    fn run(self: *@This()) void {
        for (0..self.cycles) |_| {
            const b = self.state.borrowOne(self.pool) orelse return;
            std.Thread.yield() catch {};
            self.state.releaseOne(self.pool, b);
        }
    }
};

/// The invariants every stress test must leave behind, split by what they are
/// about: the registry (nothing was lent twice, nothing was lost track of), the
/// ceiling, and the pool's own accounting.
fn expectStressInvariants(state: *StressState, pool: *StressPool, max_connections: usize) !void {
    const testing = std.testing;
    // Invariant 1 and 2: no connection was live twice, and no canary went
    // missing while a borrower was inside it.
    try testing.expectEqual(@as(usize, 0), state.double_lends);
    try testing.expectEqual(@as(usize, 0), state.holder_violations);
    try testing.expectEqual(@as(usize, 0), state.guard_violations);
    try testing.expectEqual(@as(usize, 0), state.stray_releases);
    try testing.expectEqual(@as(usize, 0), state.registry_failures);
    // Every borrow the harness recorded was handed back, and none twice.
    try testing.expectEqual(state.borrows, state.releases);
    try testing.expectEqual(@as(usize, 0), state.live.count());
    // Invariant 5: the ceiling held the whole way through.
    try testing.expect(state.peak <= max_connections);
    // Invariant 4: drained, with the pool's totals agreeing with reality.
    const snapshot = pool.stats();
    try testing.expectEqual(@as(usize, 0), snapshot.in_use);
    try testing.expectEqual(snapshot.total, snapshot.available);
    try testing.expectEqual(@as(usize, 0), snapshot.waiters);
}

test "ConnPool stress: a connection is never lent to two borrowers" {
    // `std.testing.allocator` is a `SafeAllocator`, which is documented
    // thread-safe (per-thread tables, atomic counters) in this Zig version, so
    // unlike the older concurrency tests in this file it can be handed to the
    // spawned threads — and the run keeps its leak detection. That matters
    // here: entry create/destroy is the pool's allocation traffic, and this is
    // the test that hammers it.
    const allocator = std.testing.allocator;
    var state: StressState = undefined;
    try state.setup(allocator);
    defer state.live.deinit(allocator);

    const max_connections = 4;
    const thread_count = 8;
    const iterations = 50;

    var pool = try StressPool.init(allocator, state.options(2, max_connections, 3000));
    defer pool.deinit();

    var workers: [thread_count]StressWorker = undefined;
    var threads: [thread_count]std.Thread = undefined;
    for (&workers, &threads) |*worker, *thread| {
        worker.* = .{ .state = &state, .pool = &pool, .iterations = iterations };
        thread.* = try std.Thread.spawn(.{}, StressWorker.run, .{worker});
    }
    for (&threads) |*thread| thread.join();

    // Eight threads turning four connections over: a borrow that gives up means
    // a parked borrower was not woken inside its 3 s budget.
    try std.testing.expectEqual(@as(usize, 0), state.borrow_errors.load(.monotonic));
    try std.testing.expectEqual(@as(usize, thread_count * iterations), state.borrows);
    try expectStressInvariants(&state, &pool, max_connections);
}

test "ConnPool stress: eviction racing with borrow never recycles a live connection" {
    const allocator = std.testing.allocator;
    var state: StressState = undefined;
    try state.setup(allocator);
    defer state.live.deinit(allocator);
    // Every connection starts failing its health check after the first one, so
    // the pool keeps dropping entries and opening replacements while borrowers
    // are inside other ones.
    state.fail_ping_after = 4;

    const max_connections = 4;
    const thread_count = 8;
    const iterations = 30;

    var options = state.options(1, max_connections, 1000);
    // An entry the reaper backdated is stale by the pool's own rule too, so the
    // borrow-path eviction can drop it as well; and `max_lifetime_secs` is what
    // turns the evicting workers' backdated `created_at` into a close.
    options.max_idle_secs = 30;
    options.max_lifetime_secs = 1;
    var pool = try StressPool.init(allocator, options);
    defer pool.deinit();

    // The idle-scan entry points, checked once deterministically before the
    // storm. They have no other coverage in this file, and the storm itself
    // cannot assert on them: which thread closes a backdated entry depends on
    // who reaches the pool mutex first, and a borrower that picks one up closes
    // it in `selectNoLock` rather than leaving it for the reaper.
    {
        const io = pool.io;
        pool.mutex.lockUncancelable(io);
        const now = unixTimestamp();
        for (pool.available.items) |entry| entry.idle_since = now - 60;
        const idle_now = pool.available.items.len;
        pool.mutex.unlock(io);
        try std.testing.expectEqual(idle_now, pool.reapIdleConnections(1));
        try std.testing.expect(idle_now > 0);
    }

    // Start the borrowers first (they never wait on `stop`), then the thread
    // that holds one connection for the whole storm, then the reaper: every
    // spawn failure below has a bounded way out, so a failure cannot leave a
    // thread running past the test body.
    var workers: [thread_count]StressWorker = undefined;
    var threads: [thread_count]std.Thread = undefined;
    for (&workers, &threads, 0..) |*worker, *thread, i| {
        // One borrower in four drops the connection it was given instead of
        // pooling it, so `closeConnection` keeps running against live borrows
        // while the other three hand connections back and forth — which is what
        // keeps both halves of the race alive at once: entries being closed,
        // and entries being lent and returned. Leaving most of the borrowers
        // pooling their connections also keeps the pool from draining to
        // nothing, where every borrow would have no choice but to open a
        // connection and the entries would never be shared at all.
        worker.* = .{
            .state = &state,
            .pool = &pool,
            .iterations = iterations,
            .evict_on_release = (i % 4) == 3,
        };
        thread.* = try std.Thread.spawn(.{}, StressWorker.run, .{worker});
    }

    var holder = StressHolder{ .state = &state, .pool = &pool };
    const holder_thread = std.Thread.spawn(.{}, StressHolder.run, .{&holder}) catch |err| {
        for (&threads) |*thread| thread.join();
        return err;
    };
    var spins: usize = 0;
    while (!holder.holding.load(.acquire) and spins < 5000) : (spins += 1) {
        pool.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    const holder_started = holder.holding.load(.acquire);

    var reaper = StressReaper{ .state = &state, .pool = &pool };
    const reaper_thread = std.Thread.spawn(.{}, StressReaper.run, .{&reaper}) catch |err| {
        state.stop.store(true, .release);
        holder_thread.join();
        for (&threads) |*thread| thread.join();
        return err;
    };
    // Wait for a full pass before letting the storm end, so "the idle scans ran
    // while connections were lent out" is a fact about this run rather than
    // about the scheduler.
    spins = 0;
    while (!reaper.passed.load(.acquire) and spins < 5000) : (spins += 1) {
        pool.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    const reaper_passed = reaper.passed.load(.acquire);

    for (&threads) |*thread| thread.join();
    state.stop.store(true, .release);
    reaper_thread.join();
    holder_thread.join();

    // Invariant 2: the connection was in one borrower's hands for the whole
    // storm, and it is still the entry the pool lent out.
    try std.testing.expect(holder_started);
    try std.testing.expect(holder.intact.load(.acquire));
    try std.testing.expect(state.peak >= 2);
    // ... and the storm really did close connections while others were lent
    // out: the reaper's scans ran against live borrowers, the evicting
    // borrowers saw their own connection dropped on release, and the health
    // checks dropped pooled connections whose replacement the pool then opened.
    // The pool holds at most `max_connections`, so the borrows that are served
    // on top of that are served by reusing or opening — and with the borrowers
    // that drop what they were given, `connects` has to run far above the eight
    // a connection needs to reach its fourth check below.
    try std.testing.expect(reaper_passed);
    try std.testing.expect(state.reap_passes.load(.monotonic) > 0);
    try std.testing.expect(state.closes.load(.monotonic) > 0);
    try std.testing.expect(state.connects.load(.monotonic) >= 8);
    try std.testing.expect(state.ping_failures.load(.monotonic) > 0);
    // Every borrower was served: with a 1 s budget and the pool's own release
    // and reap signals in flight, a borrow that gives up means a parked
    // borrower was not woken.
    try std.testing.expectEqual(@as(usize, 0), state.borrow_errors.load(.monotonic));
    try std.testing.expectEqual(@as(usize, thread_count * iterations + 1), state.borrows);
    try expectStressInvariants(&state, &pool, max_connections);
}

test "ConnPool stress: every parked waiter is served when connections come back" {
    const allocator = std.testing.allocator;
    var state: StressState = undefined;
    try state.setup(allocator);
    defer state.live.deinit(allocator);

    // More borrowers than connections, all of them parked before a single
    // connection is handed back: the pool has to wake every waiter it parked,
    // not just the first one it happens to serve.
    const max_connections = 4;
    const waiters = 8;
    const cycles = 5;

    var pool = try StressPool.init(allocator, state.options(max_connections, max_connections, 8000));
    defer pool.deinit();

    // Take the whole pool, so the waiters have nowhere to go.
    var held: [max_connections]StressState.Borrow = undefined;
    for (&held) |*b| b.* = state.borrowOne(&pool) orelse return error.PoolExhausted;

    var waiter_states: [waiters]StressWaiter = undefined;
    var threads: [waiters]std.Thread = undefined;
    for (&waiter_states, &threads) |*waiter, *thread| {
        waiter.* = .{ .state = &state, .pool = &pool, .cycles = cycles };
        thread.* = try std.Thread.spawn(.{}, StressWaiter.run, .{waiter});
    }

    // Deterministic synchronization point (the same one the single-waiter case
    // uses): a waiter registers its ticket and starts waiting inside one
    // critical section, so once all eight tickets are visible every thread is
    // committed to parking and cannot miss a release.
    var all_parked = false;
    var spins: usize = 0;
    while (!all_parked and spins < 2000) : (spins += 1) {
        const io = pool.io;
        pool.mutex.lockUncancelable(io);
        all_parked = pool.wait_tickets.items.len == waiters;
        pool.mutex.unlock(io);
        if (!all_parked) pool.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }

    // Release unconditionally, so a pool that loses a wake-up fails the
    // assertions below (on the waiter's budget) instead of hanging the run.
    for (&held) |*b| state.releaseOne(&pool, b.*);

    for (&threads) |*thread| thread.join();

    try std.testing.expect(all_parked);
    // Coverage rather than timing: the parks were observed above, so the wait
    // path was entered and `onWait` cannot have stayed at zero.
    try std.testing.expect(state.waits.load(.monotonic) >= waiters);
    try std.testing.expectEqual(@as(usize, 0), state.borrow_errors.load(.monotonic));
    try std.testing.expectEqual(@as(usize, max_connections + waiters * cycles), state.borrows);
    try expectStressInvariants(&state, &pool, max_connections);
}
