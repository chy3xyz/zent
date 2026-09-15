const std = @import("std");

/// Comptime-fixed-capacity LRU cache for prepared statements.
///
/// No runtime allocation — all storage is inline in the struct.
/// `capacity` is the maximum number of cached entries (default: 16).
/// `Handle` is the driver-specific statement type (e.g. `*c.sqlite3_stmt`).
///
/// Entries are keyed by the full SQL text (stored inline, byte-compared on
/// lookup) — never by hash alone — so a hash collision can never hand back a
/// statement prepared for different SQL. SQL longer than `max_sql_len`
/// bypasses the cache entirely (prepared fresh, released by the caller).
pub fn PreparedCache(comptime capacity: usize, comptime Handle: type) type {
    return PreparedCacheSized(capacity, Handle, 2048);
}

pub fn PreparedCacheSized(comptime capacity: usize, comptime Handle: type, comptime max_sql_len: usize) type {
    return struct {
        const Self = @This();

        /// Result of `getOrPrepare`: the statement plus whether it is owned by
        /// the cache. Callers must release the handle themselves when
        /// `cached == false` (oversized SQL or no evictable slot).
        pub const Prepared = struct { stmt: Handle, cached: bool };

        /// Result of `takeOrPrepare`: the statement plus the reserved cache
        /// slot to pass back to `returnStmt`. `slot == null` means the
        /// statement is not cached; the caller owns it and must release it.
        pub const Taken = struct { stmt: Handle, slot: ?usize };

        const Entry = struct {
            sql_len: usize,
            sql_buf: [max_sql_len]u8,
            stmt: Handle,
            /// True while a query() Rows iterator owns the statement. Taken
            /// entries keep their slot (and SQL key) reserved: they are
            /// invisible to lookups and never chosen for eviction.
            taken: bool,
        };

        entries: [capacity]Entry = undefined,
        len: usize = 0,
        /// LRU order: index 0 is MRU, index len-1 is LRU.
        order: [capacity]usize = undefined,

        fn sqlEql(e: *const Entry, sql: []const u8) bool {
            return e.sql_len == sql.len and std.mem.eql(u8, e.sql_buf[0..e.sql_len], sql);
        }

        fn cacheable(sql: []const u8) bool {
            return sql.len <= max_sql_len;
        }

        fn writeEntry(self: *Self, idx: usize, sql: []const u8, stmt: Handle) void {
            self.entries[idx].sql_len = sql.len;
            @memcpy(self.entries[idx].sql_buf[0..sql.len], sql);
            self.entries[idx].stmt = stmt;
            self.entries[idx].taken = false;
        }

        /// Find a non-taken entry whose SQL byte-matches `sql`.
        fn findEntry(self: *Self, sql: []const u8) ?usize {
            // Linear scan (small capacity; fine for ≤ ~64 entries). The length
            // check short-circuits almost all byte compares.
            for (self.entries[0..self.len], 0..) |*e, i| {
                if (!e.taken and sqlEql(e, sql)) return i;
            }
            return null;
        }

        /// Insert a fresh entry, evicting the LRU non-taken entry when full.
        /// Returns false when no slot is available (all entries taken).
        fn insert(self: *Self, sql: []const u8, stmt: Handle, deinitCtx: anytype, deinitFn: anytype) bool {
            if (self.len < capacity) {
                self.writeEntry(self.len, sql, stmt);
                // Newest entry is MRU; shift existing order right.
                var j: usize = self.len;
                while (j > 0) : (j -= 1) {
                    self.order[j] = self.order[j - 1];
                }
                self.order[0] = self.len;
                self.len += 1;
                return true;
            }
            // Evict the least-recently-used non-taken entry, if any.
            var p: usize = self.len;
            while (p > 0) {
                p -= 1;
                const idx = self.order[p];
                if (self.entries[idx].taken) continue;
                deinitFn(deinitCtx, self.entries[idx].stmt);
                self.writeEntry(idx, sql, stmt);
                self.moveToFront(idx);
                return true;
            }
            return false;
        }

        /// Get a cached statement or prepare a new one.
        /// When `cached` is true the returned handle remains in the cache;
        /// callers must reset it before binding (e.g. `sqlite3_reset` /
        /// `mysql_stmt_reset`). When false the caller owns the handle.
        ///
        /// `prepareFn(prepareCtx, sql)` must return a Handle on success.
        /// `deinitFn(deinitCtx, handle)` is called on evicted entries to release the handle.
        pub fn getOrPrepare(
            self: *Self,
            sql: []const u8,
            prepareCtx: anytype,
            prepareFn: anytype,
            deinitCtx: anytype,
            deinitFn: anytype,
        ) !Prepared {
            if (self.findEntry(sql)) |i| {
                self.moveToFront(i);
                return .{ .stmt = self.entries[i].stmt, .cached = true };
            }

            // Cache miss — prepare.
            const stmt = try prepareFn(prepareCtx, sql);
            if (!cacheable(sql)) return .{ .stmt = stmt, .cached = false };
            const inserted = self.insert(sql, stmt, deinitCtx, deinitFn);
            return .{ .stmt = stmt, .cached = inserted };
        }

        /// Take a cached statement for exclusive use or prepare a new one.
        /// The entry's slot stays reserved until `returnStmt` is called, so a
        /// concurrent query for the same SQL gets a distinct statement.
        /// Use this for query() where the statement lifetime is managed by a Rows iterator.
        pub fn takeOrPrepare(
            self: *Self,
            sql: []const u8,
            ctx: anytype,
            prepareFn: anytype,
        ) !Taken {
            if (self.findEntry(sql)) |i| {
                self.entries[i].taken = true;
                return .{ .stmt = self.entries[i].stmt, .slot = i };
            }
            return .{ .stmt = try prepareFn(ctx, sql), .slot = null };
        }

        /// Return a statement taken via `takeOrPrepare`, making its slot
        /// available for lookups again. `slot` must be the value returned by
        /// `takeOrPrepare`. The slot may have gone stale (evictAll reset the
        /// cache while the statement was checked out); in that case the
        /// statement is released via `deinitFn` instead of being re-cached.
        pub fn returnStmt(self: *Self, slot: usize, stmt: Handle, deinitCtx: anytype, deinitFn: anytype) void {
            if (slot < self.len and self.entries[slot].taken and self.entries[slot].stmt == stmt) {
                self.entries[slot].taken = false;
                self.moveToFront(slot);
            } else {
                deinitFn(deinitCtx, stmt);
            }
        }

        /// Evict and deinitialize all cached statements. Taken entries belong
        /// to in-flight Rows iterators: their handles stay valid (owned by the
        /// iterator), but their slots are dropped — a later `returnStmt` sees
        /// the stale slot and releases the handle instead of re-caching it.
        pub fn evictAll(self: *Self, deinitCtx: anytype, deinitFn: anytype) void {
            for (self.entries[0..self.len]) |*e| {
                if (!e.taken) deinitFn(deinitCtx, e.stmt);
            }
            self.len = 0;
        }

        /// Move the entry at `entry_idx` to the MRU position (order[0]).
        fn moveToFront(self: *Self, entry_idx: usize) void {
            var pos: ?usize = null;
            for (self.order[0..self.len], 0..) |o, i| {
                if (o == entry_idx) {
                    pos = i;
                    break;
                }
            }
            if (pos) |p| {
                // Shift entries before p right by one.
                var j = p;
                while (j > 0) : (j -= 1) {
                    self.order[j] = self.order[j - 1];
                }
                self.order[0] = entry_idx;
            }
        }
    };
}

/// Returns true if `sql` is a DDL statement (CREATE / ALTER / DROP).
/// DDL invalidates all cached prepared statements.
pub fn isDDL(sql: []const u8) bool {
    const s = ltrim(sql, " \t\n\r");
    const first_word = if (std.mem.indexOfAny(u8, s, " \t\n\r")) |idx| s[0..idx] else s;
    return std.ascii.eqlIgnoreCase(first_word, "CREATE") or
        std.ascii.eqlIgnoreCase(first_word, "ALTER") or
        std.ascii.eqlIgnoreCase(first_word, "DROP");
}

fn ltrim(s: []const u8, chars: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and std.mem.indexOfScalar(u8, chars, s[i]) != null) : (i += 1) {}
    return s[i..];
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const TestCtx = struct {
    prepare_count: usize = 0,
    evict_order: [10]usize = undefined,
    evict_count: usize = 0,
};

fn testPrepare(ctx: *TestCtx, sql: []const u8) !*anyopaque {
    _ = sql;
    ctx.prepare_count += 1;
    return @ptrFromInt(ctx.prepare_count);
}

fn testDeinit(ctx: *TestCtx, h: *anyopaque) void {
    ctx.evict_order[ctx.evict_count] = @intFromPtr(h);
    ctx.evict_count += 1;
}

fn testDeinitCount(ctx: *TestCtx, h: *anyopaque) void {
    _ = h;
    ctx.evict_count += 1;
}

test "PreparedCache: getOrPrepare caches by SQL text" {
    var cch: PreparedCache(4, *anyopaque) = .{};
    var ctx = TestCtx{};

    const p1 = try cch.getOrPrepare("SELECT 1", &ctx, testPrepare, &ctx, testDeinitCount);
    const p2 = try cch.getOrPrepare("SELECT 1", &ctx, testPrepare, &ctx, testDeinitCount);
    try std.testing.expectEqual(p1.stmt, p2.stmt);
    try std.testing.expect(p1.cached and p2.cached);
    try std.testing.expectEqual(@as(usize, 1), ctx.prepare_count);
}

test "PreparedCache: lookup byte-compares SQL (no hash-only match)" {
    // Same length, different bytes: must never share an entry, regardless of
    // what any hash of them would be.
    var cch: PreparedCache(4, *anyopaque) = .{};
    var ctx = TestCtx{};

    const p1 = try cch.getOrPrepare("AAAA", &ctx, testPrepare, &ctx, testDeinitCount);
    const p2 = try cch.getOrPrepare("AAAB", &ctx, testPrepare, &ctx, testDeinitCount);
    try std.testing.expect(p1.stmt != p2.stmt);
    try std.testing.expectEqual(@as(usize, 2), ctx.prepare_count);
    // Both cached and hit independently.
    _ = try cch.getOrPrepare("AAAA", &ctx, testPrepare, &ctx, testDeinitCount);
    _ = try cch.getOrPrepare("AAAB", &ctx, testPrepare, &ctx, testDeinitCount);
    try std.testing.expectEqual(@as(usize, 2), ctx.prepare_count);
}

test "PreparedCache: different SQL = different entries" {
    var cch: PreparedCache(8, *anyopaque) = .{};
    var ctx = TestCtx{};

    _ = try cch.getOrPrepare("SELECT 1", &ctx, testPrepare, &ctx, testDeinitCount);
    _ = try cch.getOrPrepare("SELECT 2", &ctx, testPrepare, &ctx, testDeinitCount);
    try std.testing.expectEqual(@as(usize, 2), ctx.prepare_count);
}

test "PreparedCache: evicts LRU when full" {
    var cch: PreparedCache(2, *anyopaque) = .{};
    var ctx = TestCtx{};

    // Fill cache: stmt 1, stmt 2.
    _ = try cch.getOrPrepare("A", &ctx, testPrepare, &ctx, testDeinit);
    _ = try cch.getOrPrepare("B", &ctx, testPrepare, &ctx, testDeinit);
    try std.testing.expectEqual(@as(usize, 2), cch.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.evict_count);

    // Access A (makes it MRU), B becomes LRU.
    _ = try cch.getOrPrepare("A", &ctx, testPrepare, &ctx, testDeinit);
    // Insert C: evicts B (LRU).
    _ = try cch.getOrPrepare("C", &ctx, testPrepare, &ctx, testDeinit);
    try std.testing.expectEqual(@as(usize, 1), ctx.evict_count);
    try std.testing.expectEqual(@as(usize, 2), ctx.evict_order[0]); // stmt 2 was evicted
    try std.testing.expectEqual(@as(usize, 2), cch.len);

    // A is still cached (should not cause new prepare).
    const before = ctx.prepare_count;
    _ = try cch.getOrPrepare("A", &ctx, testPrepare, &ctx, testDeinit);
    try std.testing.expectEqual(before, ctx.prepare_count);
}

test "PreparedCache: evictAll clears all entries" {
    var cch: PreparedCache(4, *anyopaque) = .{};
    var ctx = TestCtx{};

    _ = try cch.getOrPrepare("A", &ctx, testPrepare, &ctx, testDeinitCount);
    _ = try cch.getOrPrepare("B", &ctx, testPrepare, &ctx, testDeinitCount);
    cch.evictAll(&ctx, testDeinitCount);
    try std.testing.expectEqual(@as(usize, 0), cch.len);
    try std.testing.expectEqual(@as(usize, 2), ctx.evict_count);
}

test "PreparedCache: take reserves slot, returnStmt releases it" {
    var cch: PreparedCache(4, *anyopaque) = .{};
    var ctx = TestCtx{};

    // Populate via exec path.
    _ = try cch.getOrPrepare("SELECT 1", &ctx, testPrepare, &ctx, testDeinitCount);

    // Take marks the entry taken (slot reserved, len unchanged).
    const t1 = try cch.takeOrPrepare("SELECT 1", &ctx, testPrepare);
    try std.testing.expect(t1.slot != null);
    try std.testing.expectEqual(@as(usize, 1), cch.len);
    try std.testing.expectEqual(@as(usize, 1), ctx.prepare_count);

    // While taken, the same SQL prepares a fresh statement instead of
    // handing out the in-use one.
    const t2 = try cch.takeOrPrepare("SELECT 1", &ctx, testPrepare);
    try std.testing.expect(t2.slot == null);
    try std.testing.expect(t2.stmt != t1.stmt);
    try std.testing.expectEqual(@as(usize, 2), ctx.prepare_count);

    // Return the first; the next take reuses it without preparing.
    cch.returnStmt(t1.slot.?, t1.stmt, &ctx, testDeinitCount);
    const t3 = try cch.takeOrPrepare("SELECT 1", &ctx, testPrepare);
    try std.testing.expectEqual(t1.stmt, t3.stmt);
    try std.testing.expectEqual(@as(usize, 2), ctx.prepare_count);
}

test "PreparedCache: eviction skips taken entries" {
    var cch: PreparedCache(2, *anyopaque) = .{};
    var ctx = TestCtx{};

    _ = try cch.getOrPrepare("A", &ctx, testPrepare, &ctx, testDeinit);
    _ = try cch.getOrPrepare("B", &ctx, testPrepare, &ctx, testDeinit);

    // Take A (MRU after this) and B; cache is now entirely taken.
    const ta = try cch.takeOrPrepare("A", &ctx, testPrepare);
    const tb = try cch.takeOrPrepare("B", &ctx, testPrepare);

    // New SQL with no evictable slot: caller owns the statement.
    const p = try cch.getOrPrepare("C", &ctx, testPrepare, &ctx, testDeinit);
    try std.testing.expect(!p.cached);
    try std.testing.expectEqual(@as(usize, 0), ctx.evict_count);

    // Return B, then inserting D evicts B (only non-taken entry).
    cch.returnStmt(tb.slot.?, tb.stmt, &ctx, testDeinit);
    _ = try cch.getOrPrepare("D", &ctx, testPrepare, &ctx, testDeinit);
    try std.testing.expectEqual(@as(usize, 1), ctx.evict_count);
    try std.testing.expectEqual(@as(usize, 2), ctx.evict_order[0]); // stmt 2 (B) evicted

    // A's slot survived; returning it works.
    cch.returnStmt(ta.slot.?, ta.stmt, &ctx, testDeinitCount);
}

test "PreparedCache: returnStmt after evictAll releases instead of caching" {
    var cch: PreparedCache(2, *anyopaque) = .{};
    var ctx = TestCtx{};

    _ = try cch.getOrPrepare("A", &ctx, testPrepare, &ctx, testDeinitCount);
    const t = try cch.takeOrPrepare("A", &ctx, testPrepare);

    // DDL-style invalidation while the statement is checked out.
    cch.evictAll(&ctx, testDeinitCount);
    try std.testing.expectEqual(@as(usize, 0), ctx.evict_count); // taken stmt untouched

    // Returning to the stale slot releases the handle directly.
    cch.returnStmt(t.slot.?, t.stmt, &ctx, testDeinitCount);
    try std.testing.expectEqual(@as(usize, 1), ctx.evict_count);
    try std.testing.expectEqual(@as(usize, 0), cch.len);
}

test "PreparedCache: oversized SQL bypasses the cache" {
    var cch: PreparedCacheSized(2, *anyopaque, 4) = .{};
    var ctx = TestCtx{};

    const p1 = try cch.getOrPrepare("SELECT 1", &ctx, testPrepare, &ctx, testDeinitCount);
    try std.testing.expect(!p1.cached);
    try std.testing.expectEqual(@as(usize, 0), cch.len);
    const p2 = try cch.getOrPrepare("SELECT 1", &ctx, testPrepare, &ctx, testDeinitCount);
    try std.testing.expect(!p2.cached);
    try std.testing.expectEqual(@as(usize, 2), ctx.prepare_count); // never cached

    const t = try cch.takeOrPrepare("SELECT 1", &ctx, testPrepare);
    try std.testing.expect(t.slot == null);

    // Short SQL still caches.
    const p3 = try cch.getOrPrepare("SEL", &ctx, testPrepare, &ctx, testDeinitCount);
    try std.testing.expect(p3.cached);
}

test "PreparedCache: default-null integration pattern" {
    // Verify that optional cache works: null => no op, non-null => used.
    var maybe: ?PreparedCache(2, *anyopaque) = null;
    try std.testing.expect(maybe == null);

    maybe = PreparedCache(2, *anyopaque){};
    try std.testing.expect(maybe != null);
}

test "isDDL detection" {
    try std.testing.expect(isDDL("CREATE TABLE foo (id INT)"));
    try std.testing.expect(isDDL("  create index idx on foo(id)"));
    try std.testing.expect(isDDL("ALTER TABLE foo ADD COLUMN x TEXT"));
    try std.testing.expect(isDDL("drop table foo"));
    try std.testing.expect(isDDL("\t\n DROP   DATABASE test"));

    try std.testing.expect(!isDDL("SELECT 1"));
    try std.testing.expect(!isDDL("INSERT INTO foo VALUES (1)"));
    try std.testing.expect(!isDDL("UPDATE foo SET x=1"));
    try std.testing.expect(!isDDL("DELETE FROM foo"));
}

// Stress tests: the cache under concurrent exec/query churn and eviction
// -----------------------------------------------------------------------
//
// The cache carries no lock of its own; the drivers guard it with the
// connection mutex (`SQLiteDriver.mutex` — one connection, many handler
// threads, everything serialized behind it). This test replicates exactly
// that pattern — one shared cache behind the driver's own `RecursiveMutex`,
// workers running the two driver call shapes (`getOrPrepare`+step for exec,
// `takeOrPrepare`+step+`returnStmt` for query), and one evictor thread
// alternating insert-storms with `evictAll` — and asserts invariants, never
// schedules: whatever the interleaving,
//
//   1. a handle the cache hands out is the live statement for the SQL that
//      was asked for, never one that was evicted and re-prepared for other
//      SQL (probe: `sqlite3_sql` of the returned handle byte-matches the
//      request, and the handle is still in the not-finalized ledger);
//   2. a handle checked out via `takeOrPrepare` is never finalized, nor
//      handed to a second borrower, while checked out (probes: the taken
//      registry and a finalize-time check against it);
//   3. the books balance at the end: every prepared handle is either still
//      cached or finalized exactly once, the taken registry is empty, and
//      the cache's own bookkeeping (`len`, `order`) is a self-consistent
//      permutation — no lost entry, no duplicate.
//
// The statements are real SQLite statements on one shared in-memory
// database: handle addresses are stable and their contents verifiable,
// which is what makes invariant 1 observable from outside the cache.
//
// Failure discipline (same as the pool stress tests): every `try` that can
// fail runs only after all threads are joined — a red assertion must never
// unwind the defers while workers still hold pointers into the shared
// state, or the teardown itself becomes the crash under investigation.

const c = @import("sqlite3_c");
const sqlite_driver = @import("sqlite.zig");

/// The cache capacity for the stress test. Deliberately far below the SQL
/// set size so LRU eviction churns constantly.
const stress_capacity = 8;
const stress_sqls = blk: {
    @setEvalBranchQuota(10_000);
    var arr: [24][]const u8 = undefined;
    for (0..24) |i| arr[i] = std.fmt.comptimePrint("SELECT {d}", .{i});
    break :blk arr;
};

/// Spin lock for the ledger. The critical sections are a few hash-map
/// operations wide, and it is always taken while holding the statement
/// mutex (never the other way around), so a raw try-lock loop like the pool
/// stress harness is enough.
const StressLock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *@This()) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *@This()) void {
        self.inner.unlock();
    }
};

/// Shared, cross-thread bookkeeping for the cache stress test.
///
/// Lock order is always `mutex` (statements) -> `lock` (ledger): every
/// probe runs while the caller holds the statement mutex, and no ledger
/// section ever touches the cache or a statement, so the two never invert.
const CacheStressState = struct {
    allocator: std.mem.Allocator,
    /// Serializes all cache and statement access, exactly like
    /// `SQLiteDriver.mutex` — it is the driver's own mutex type.
    mutex: sqlite_driver.RecursiveMutex = .{},
    /// Serializes the ledger maps and counters below.
    lock: StressLock = .{},
    db: *c.sqlite3 = undefined,
    cache: PreparedCache(stress_capacity, *c.sqlite3_stmt) = .{},

    /// Handle address -> prepare serial, one entry per live (not finalized)
    /// statement. Reserved up front: `stressPrepare` runs under the ledger
    /// spin lock and must not allocate there.
    prepared: std.AutoHashMapUnmanaged(usize, u64) = .empty,
    /// Handle address -> checkout token, one entry per statement currently
    /// checked out via `takeOrPrepare`.
    taken: std.AutoHashMapUnmanaged(usize, u64) = .empty,
    serial: u64 = 0,
    next_token: u64 = 0,
    /// Finalize calls, and the violations they must never be: a finalize of
    /// a checked-out handle, or of a handle that was never prepared (or was
    /// already finalized — a double free).
    finalized: usize = 0,
    finalize_while_taken: usize = 0,
    stray_finalizes: usize = 0,
    /// Cache hits whose handle fails a probe: the statement's own SQL text
    /// does not byte-match the request (a recycled/reused slot), or the
    /// handle is not in the live ledger (already finalized — a freed hit),
    /// or the cache handed out a handle that is checked out right now.
    canary_violations: usize = 0,
    freed_hits: usize = 0,
    hits_on_taken: usize = 0,
    /// `takeOrPrepare` returned a handle that is already checked out.
    double_takes: usize = 0,
    /// A checkout's return found no matching registry entry.
    stray_returns: usize = 0,
    /// The ledger itself could not record — an allocation failure, not a
    /// cache bug, but it would silently blind the probes, so it fails too.
    register_failures: usize = 0,

    prepares: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// `evictAll` calls a worker ran while one of its takes was checked
    /// out — the DDL-invalidation shape; asserted after the joins.
    evictall_during_take: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    prepare_errors: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    step_errors: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Tells the evictor the storm is over.
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// `prepareFn` for the stress cache: prepare a real statement and register
/// it. Called with the statement mutex held (inside the cache call).
fn stressPrepare(state: *CacheStressState, sql: []const u8) !*c.sqlite3_stmt {
    var out: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(state.db, @ptrCast(sql.ptr), @intCast(sql.len), @ptrCast(&out), null);
    if (rc != c.SQLITE_OK or out == null) return error.PrepareFailed;
    const stmt = out.?;
    state.lock.lock();
    defer state.lock.unlock();
    state.serial += 1;
    state.prepares.store(state.serial, .monotonic);
    const slot = state.prepared.getOrPut(state.allocator, @intFromPtr(stmt)) catch {
        state.register_failures += 1;
        return stmt;
    };
    if (slot.found_existing) {
        // A live statement's address must be unique; a repeat means the
        // ledger lost track of one (or sqlite reused a live pointer).
        state.register_failures += 1;
    } else {
        slot.value_ptr.* = state.serial;
    }
    return stmt;
}

/// `deinitFn` for the stress cache: run the ledger probes, then finalize.
/// Called with the statement mutex held (inside the cache call, or from the
/// worker releasing a caller-owned statement).
fn stressDeinit(state: *CacheStressState, stmt: *c.sqlite3_stmt) void {
    state.lock.lock();
    const addr = @intFromPtr(stmt);
    if (state.taken.contains(addr)) state.finalize_while_taken += 1;
    if (!state.prepared.remove(addr)) state.stray_finalizes += 1;
    state.finalized += 1;
    state.lock.unlock();
    _ = c.sqlite3_finalize(stmt);
}

/// Run the hit-side probes on a handle the cache just handed back. The
/// caller holds the statement mutex, so the statement is quiescent.
fn checkHit(state: *CacheStressState, sql: []const u8, stmt: *c.sqlite3_stmt) void {
    state.lock.lock();
    defer state.lock.unlock();
    const addr = @intFromPtr(stmt);
    if (!state.prepared.contains(addr)) {
        // The cache returned a handle that is not in the live ledger: it
        // was finalized already (freed memory handed back out).
        state.freed_hits += 1;
    }
    if (state.taken.contains(addr)) {
        // The cache handed out a handle that is checked out right now.
        state.hits_on_taken += 1;
    }
    const raw = c.sqlite3_sql(stmt);
    if (raw == null) {
        state.canary_violations += 1;
        return;
    }
    if (!std.mem.eql(u8, sql, std.mem.span(raw))) {
        // The handle is a statement prepared for different SQL: the slot
        // was evicted and recycled underneath a borrower.
        state.canary_violations += 1;
    }
}

fn registerTake(state: *CacheStressState, t: PreparedCache(stress_capacity, *c.sqlite3_stmt).Taken) void {
    state.lock.lock();
    defer state.lock.unlock();
    state.next_token += 1;
    const slot = state.taken.getOrPut(state.allocator, @intFromPtr(t.stmt)) catch {
        state.register_failures += 1;
        return;
    };
    if (slot.found_existing) {
        state.double_takes += 1;
    } else {
        slot.value_ptr.* = state.next_token;
    }
}

fn unregisterTake(state: *CacheStressState, t: PreparedCache(stress_capacity, *c.sqlite3_stmt).Taken) void {
    state.lock.lock();
    defer state.lock.unlock();
    if (!state.taken.remove(@intFromPtr(t.stmt))) state.stray_returns += 1;
}

/// A worker running both driver call shapes against the shared cache:
/// exec-path (`getOrPrepare`, statement stays in the cache) and query-path
/// (`takeOrPrepare`, use, `returnStmt`). Each statement is really stepped,
/// and the take is held across a yield so the threads contend for the same
/// slots instead of running one after the other.
const CacheStressWorker = struct {
    state: *CacheStressState,
    seed: u64,
    iterations: usize,
    /// Nested exec-path calls issued per take while that take is checked
    /// out. This is the shape the driver's recursive mutex exists for — a
    /// Rows iterator open on the same thread (entry taken) while an exec
    /// runs nested — and it is what makes "taken entries survive eviction"
    /// observable: without it, the statement mutex keeps every take inside
    /// one critical section, so no eviction can ever see a taken entry and
    /// the taken probes stay theoretical.
    nested_per_take: usize = 4,

    fn run(self: *@This()) void {
        var rng = self.seed;
        for (0..self.iterations) |_| {
            rng = rng *% 6364136223846793005 +% 1442695040888963407;
            const sql_exec = stress_sqls[(rng >> 33) % stress_sqls.len];
            rng = rng *% 6364136223846793005 +% 1442695040888963407;
            const sql_query = stress_sqls[(rng >> 33) % stress_sqls.len];

            // Exec path. A cached hit stays cache-owned; an uncached result
            // (no evictable slot — unreachable while the mutex serializes
            // checkouts, kept for parity with the driver) is caller-owned
            // and released like `SQLiteDriver.execInner`'s defer.
            self.state.mutex.lock();
            const p = self.state.cache.getOrPrepare(sql_exec, self.state, stressPrepare, self.state, stressDeinit) catch {
                self.state.mutex.unlock();
                _ = self.state.prepare_errors.fetchAdd(1, .monotonic);
                continue;
            };
            if (p.cached) {
                checkHit(self.state, sql_exec, p.stmt);
                _ = c.sqlite3_reset(p.stmt);
                const rc = c.sqlite3_step(p.stmt);
                if (rc != c.SQLITE_ROW) _ = self.state.step_errors.fetchAdd(1, .monotonic);
            } else {
                _ = c.sqlite3_reset(p.stmt);
                const rc = c.sqlite3_step(p.stmt);
                if (rc != c.SQLITE_ROW) _ = self.state.step_errors.fetchAdd(1, .monotonic);
                stressDeinit(self.state, p.stmt);
            }
            self.state.mutex.unlock();

            // Query path: take, use, return. The slot (if any) stays
            // reserved for the whole hold, exactly like the driver holding
            // its mutex until the Rows iterator deinits.
            self.state.mutex.lock();
            const t = self.state.cache.takeOrPrepare(sql_query, self.state, stressPrepare) catch {
                self.state.mutex.unlock();
                _ = self.state.prepare_errors.fetchAdd(1, .monotonic);
                continue;
            };
            // Canary first, registration second: the take itself is about
            // to own this handle, and `checkHit` must not see its own
            // checkout in the taken registry — the probe is for handles
            // handed out *while another thread holds them*.
            if (t.slot != null) checkHit(self.state, sql_query, t.stmt);
            registerTake(self.state, t);
            // Nested exec-path calls with the take still checked out (the
            // recursive mutex makes these legal on this thread, exactly
            // like an exec nested inside an open Rows iterator). Misses
            // insert with this entry taken, so eviction must skip it; a hit
            // on the taken SQL prepares a second statement instead of
            // handing out the in-use one. Every fourth nested call is a DDL
            // invalidation (`evictAll`) instead — the same path
            // `SQLiteDriver.execInner` takes for DDL — which drops the
            // slots of still-checked-out statements and turns the following
            // `returnStmt` into the stale-slot release path.
            for (0..self.nested_per_take) |nested_i| {
                self.state.mutex.lock();
                if (nested_i % 4 == 3) {
                    self.state.cache.evictAll(self.state, stressDeinit);
                    _ = self.state.evictall_during_take.fetchAdd(1, .monotonic);
                    self.state.mutex.unlock();
                    continue;
                }
                rng = rng *% 6364136223846793005 +% 1442695040888963407;
                const sql_nested = stress_sqls[(rng >> 33) % stress_sqls.len];
                const np = self.state.cache.getOrPrepare(sql_nested, self.state, stressPrepare, self.state, stressDeinit) catch {
                    self.state.mutex.unlock();
                    _ = self.state.prepare_errors.fetchAdd(1, .monotonic);
                    continue;
                };
                if (np.cached) {
                    checkHit(self.state, sql_nested, np.stmt);
                } else {
                    stressDeinit(self.state, np.stmt);
                }
                self.state.mutex.unlock();
            }
            _ = c.sqlite3_reset(t.stmt);
            const rc = c.sqlite3_step(t.stmt);
            if (rc != c.SQLITE_ROW) _ = self.state.step_errors.fetchAdd(1, .monotonic);
            std.Thread.yield() catch {};
            _ = c.sqlite3_reset(t.stmt);
            _ = c.sqlite3_clear_bindings(t.stmt);
            unregisterTake(self.state, t);
            if (t.slot) |slot| {
                self.state.cache.returnStmt(slot, t.stmt, self.state, stressDeinit);
            } else {
                // Uncached take (cache miss): caller-owned, released here.
                stressDeinit(self.state, t.stmt);
            }
            self.state.mutex.unlock();
        }
    }
};

/// The eviction pressure, mirroring what `SQLiteDriver` does on DDL and on
/// connection teardown: even passes run an insert-storm that forces LRU
/// eviction with the cache at capacity, odd passes `evictAll` everything.
/// Note what can and cannot race here: the driver pattern under test holds
/// the statement mutex from `takeOrPrepare` through `returnStmt`, so an
/// eviction pass can never overlap one checked-out take — the taken-entry
/// probes below are tripwires for that contract being weakened, not
/// observations of an overlap this run proves. What the storm does exercise
/// is the real multi-thread interleaving of complete operations: taken
/// flags and LRU order persist across lock regions, `evictAll` drops
/// entries between one worker's calls and the next, and every hit is
/// canary-checked as it happens.
const CacheStressEvictor = struct {
    state: *CacheStressState,
    /// Written only by the evictor thread, read after the join.
    passes: usize = 0,
    evictall_passes: usize = 0,
    insert_passes: usize = 0,

    fn run(self: *@This()) void {
        while (!self.state.stop.load(.acquire)) {
            self.state.mutex.lock();
            if (self.passes % 2 == 0) {
                // Insert storm: more distinct SQL than the capacity, so at
                // least one insert evicts a live non-taken entry.
                for (stress_sqls[0 .. stress_capacity + 4]) |sql| {
                    const p = self.state.cache.getOrPrepare(sql, self.state, stressPrepare, self.state, stressDeinit) catch continue;
                    if (p.cached) {
                        checkHit(self.state, sql, p.stmt);
                    } else {
                        stressDeinit(self.state, p.stmt);
                    }
                }
                self.insert_passes += 1;
            } else {
                self.state.cache.evictAll(self.state, stressDeinit);
                self.evictall_passes += 1;
            }
            self.passes += 1;
            self.state.mutex.unlock();
            std.Thread.yield() catch {};
        }
    }
};

fn expectCacheStressInvariants(state: *CacheStressState) !void {
    const testing = std.testing;
    // Invariant 1: every handle the cache handed out was the live statement
    // for the SQL that was asked.
    try testing.expectEqual(@as(usize, 0), state.canary_violations);
    try testing.expectEqual(@as(usize, 0), state.freed_hits);
    try testing.expectEqual(@as(usize, 0), state.hits_on_taken);
    // Invariant 2: no checked-out handle was finalized or handed out twice.
    try testing.expectEqual(@as(usize, 0), state.finalize_while_taken);
    try testing.expectEqual(@as(usize, 0), state.double_takes);
    try testing.expectEqual(@as(usize, 0), state.stray_returns);
    // The harness itself kept its eyes open.
    try testing.expectEqual(@as(usize, 0), state.stray_finalizes);
    try testing.expectEqual(@as(usize, 0), state.register_failures);
    try testing.expectEqual(@as(usize, 0), state.prepare_errors.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), state.step_errors.load(.monotonic));
    // Nothing is checked out any more.
    try testing.expectEqual(@as(usize, 0), state.taken.count());

    // Invariant 3, the ledger: every prepared handle is either still cached
    // or finalized exactly once — no leak, no double finalize.
    const cch = &state.cache;
    try testing.expect(cch.len <= stress_capacity);
    try testing.expectEqual(cch.len, state.prepared.count());
    try testing.expectEqual(state.prepares.load(.monotonic), state.finalized + cch.len);

    // Invariant 3, the cache's own books: `order` lists each live slot
    // exactly once, and every entry is untaken with a live, unique handle
    // whose statement still answers its own SQL.
    var seen: [stress_capacity]bool = undefined;
    for (&seen) |*s| s.* = false;
    for (cch.order[0..cch.len]) |idx| {
        try testing.expect(idx < cch.len);
        try testing.expect(!seen[idx]);
        seen[idx] = true;
    }
    for (seen[0..cch.len]) |s| try testing.expect(s);
    for (0..cch.len) |i| {
        const e = &cch.entries[i];
        try testing.expect(!e.taken);
        const raw = c.sqlite3_sql(e.stmt);
        try testing.expect(raw != null);
        try testing.expect(std.mem.eql(u8, e.sql_buf[0..e.sql_len], std.mem.span(raw)));
        for (0..i) |j| try testing.expect(cch.entries[j].stmt != e.stmt);
    }
}

test "PreparedCache stress: concurrent take/put racing eviction never recycles or loses a handle" {
    // `std.testing.allocator` is a `SafeAllocator`, documented thread-safe
    // (per-thread tables, atomic counters) in this Zig version — the same
    // choice the pool stress tests make — so it can be handed to the
    // spawned threads and the run keeps its leak detection.
    const allocator = std.testing.allocator;
    var state: CacheStressState = .{ .allocator = allocator };
    var db: ?*c.sqlite3 = null;
    try std.testing.expect(c.sqlite3_open(":memory:", &db) == c.SQLITE_OK);
    try std.testing.expect(db != null);
    state.db = db.?;
    // Mirror `SQLiteDriver.close` in reverse declaration (defers run LIFO):
    // evictAll finalizes every cached statement, then the database closes,
    // and only then may the ledger maps be deinit'd — `stressDeinit` still
    // reads them during evictAll.
    defer state.taken.deinit(allocator);
    defer state.prepared.deinit(allocator);
    defer _ = c.sqlite3_close(db.?);
    defer state.cache.evictAll(&state, stressDeinit);

    // `stressPrepare`/`registerTake`/`checkHit` run under the ledger spin
    // lock and must not allocate there.
    try state.prepared.ensureTotalCapacity(allocator, 256);
    try state.taken.ensureTotalCapacity(allocator, 64);

    const thread_count = 4;
    const iterations = 150;

    var evictor = CacheStressEvictor{ .state = &state };
    const evictor_thread = try std.Thread.spawn(.{}, CacheStressEvictor.run, .{&evictor});

    var workers: [thread_count]CacheStressWorker = undefined;
    var threads: [thread_count]std.Thread = undefined;
    var spawned: usize = 0;
    for (&workers, &threads, 0..) |*worker, *thread, i| {
        worker.* = .{
            .state = &state,
            .seed = 0x9e3779b97f4a7c15 +% (i *% 0x85ebca6b),
            .iterations = iterations,
        };
        thread.* = std.Thread.spawn(.{}, CacheStressWorker.run, .{worker}) catch |err| {
            // Bounded way out, like the pool tests: stop the evictor, let
            // the already-spawned workers finish their bounded loops, then
            // propagate — never unwind the defers under live threads.
            state.stop.store(true, .release);
            evictor_thread.join();
            for (threads[0..spawned]) |*t| t.join();
            return err;
        };
        spawned += 1;
    }

    for (&threads) |*thread| thread.join();
    state.stop.store(true, .release);
    evictor_thread.join();

    // Coverage, all observed facts: both eviction shapes ran, churn
    // happened, and finalize calls really occurred.
    try std.testing.expect(evictor.insert_passes > 0);
    try std.testing.expect(evictor.evictall_passes > 0);
    try std.testing.expect(state.evictall_during_take.load(.monotonic) > 0);
    try std.testing.expect(state.prepares.load(.monotonic) > stress_capacity);
    try std.testing.expect(state.finalized > 0);

    try expectCacheStressInvariants(&state);
}
