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

        /// A read-only snapshot of the cache's counters, for a metrics scrape
        /// or a health endpoint. Reach it through `stats()`, or through a
        /// driver's `cacheStats()` accessor, which also takes that driver's
        /// connection lock.
        ///
        /// **What each counter counts (and what it does not).** A *lookup* is
        /// one `getOrPrepare` or `takeOrPrepare` call — the two entry points
        /// are counted together, so a statement the exec path cached and the
        /// query path later takes is a `hits`, not a second kind of anything.
        /// A lookup lands in exactly one of `hits`, `misses` or
        /// `taken_misses`:
        ///
        ///  * `hits` — the SQL matched an entry that was live (not checked
        ///    out), and that entry's handle is what the caller got back. The
        ///    entry was moved to the MRU position.
        ///  * `misses` — no live entry matched: the SQL is not in the cache at
        ///    all. Includes SQL too long for `max_sql_len`, which can never be
        ///    cached (see `oversized_bypass`, the subset).
        ///  * `taken_misses` — the SQL *is* in the cache, but every matching
        ///    entry is checked out by a `Rows` iterator, so the lookup could
        ///    not use it and the caller got a freshly prepared statement.
        ///    Rare (one per in-flight iterator for the same SQL) and the one
        ///    miss a bigger cache cannot fix; keeping it out of `misses` is
        ///    what makes "cold" and "contended" distinguishable.
        ///
        /// The other counters are not lookup outcomes:
        ///
        ///  * `prepares` — statements the cache successfully prepared on a
        ///    lookup that missed. Equal to `misses + taken_misses` on a run
        ///    with no prepare failure; a failed `prepareFn` is counted in the
        ///    lookup but not here, which is how the two can disagree.
        ///  * `evictions` — entries dropped by `insert` to make room for a new
        ///    one (the LRU tail). One per insert that had to evict; the entry
        ///    that was replaced had its handle released through `deinitFn`.
        ///  * `invalidations` — entries dropped by `evictAll` (DDL, connection
        ///    close). Counts *entries*, not calls, and never the checked-out
        ///    ones: those belong to their iterator and keep their handle.
        ///  * `oversized_bypass` — a missed lookup whose SQL exceeds
        ///    `max_sql_len`, so the prepared statement is handed back
        ///    caller-owned instead of being inserted. A subset of `misses`,
        ///    and the answer to "why does this statement never hit?".
        ///  * `uncached_inserts` — a missed lookup that wanted to cache its
        ///    statement but found no evictable slot (every entry checked out);
        ///    the caller owns the handle. A subset of `misses`, and the only
        ///    miss caused by `capacity`.
        ///  * `returned` — a taken entry handed back through `returnStmt` (or
        ///    `releaseTaken`) whose slot was still valid: the entry is live
        ///    and MRU again. The success path for a `takeOrPrepare`.
        ///  * `stale_returns` — a return whose slot could not be re-armed
        ///    because `evictAll` dropped it while the statement was checked
        ///    out (or the handle did not match the slot); the handle was
        ///    released through `deinitFn` instead of being re-cached. Before
        ///    v0.85 this shape lost the statement; it is counted so the
        ///    loss is visible rather than silent.
        ///  * `released_uncached` — `releaseTaken` on a `takeOrPrepare` that
        ///    missed (no slot): the caller-owned handle was released, as it
        ///    must be. Not a cache loss — nothing was cached to lose.
        pub const Stats = struct {
            /// Lookups answered from a live entry.
            hits: usize = 0,
            /// Lookups that found no entry for the SQL (cold miss).
            misses: usize = 0,
            /// Lookups whose SQL was present but checked out (contended miss).
            taken_misses: usize = 0,
            /// Statements the cache prepared on a missed lookup.
            prepares: usize = 0,
            /// Entries dropped by `insert` to make room (LRU eviction).
            evictions: usize = 0,
            /// Entries dropped by `evictAll` (DDL / close).
            invalidations: usize = 0,
            /// Missed lookups whose SQL can never be cached (too long).
            oversized_bypass: usize = 0,
            /// Missed lookups that found no evictable slot — caller-owned.
            uncached_inserts: usize = 0,
            /// Taken entries successfully returned to their slot.
            returned: usize = 0,
            /// Returns whose slot was invalidated while checked out.
            stale_returns: usize = 0,
            /// `releaseTaken` calls with no cache-owned slot.
            released_uncached: usize = 0,
        };

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
        /// The counters behind `stats()`. Plain fields, no atomics: a cache is
        /// driven by one thread at a time (the drivers serialize their calls —
        /// the SQLite driver behind its `mutex`), and an atomic here would
        /// claim a thread-safety the cache does not otherwise have.
        counts: Stats = .{},

        /// A snapshot of the counters as of this call. See `Stats` for what
        /// each one means and when it is incremented. This is a plain read: it
        /// does not lock, so a caller racing a cache operation needs its own
        /// synchronization (the drivers' `cacheStats()` accessors take the
        /// connection lock for you).
        pub fn stats(self: *const Self) Stats {
            return self.counts;
        }

        inline fn sqlEql(e: *const Entry, sql: []const u8) bool {
            return e.sql_len == sql.len and std.mem.eql(u8, e.sql_buf[0..e.sql_len], sql);
        }

        inline fn cacheable(sql: []const u8) bool {
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
                if (e.taken) {
                    // Checked-out entries are rare: at most one per in-flight
                    // Rows iterator.
                    @branchHint(.cold);
                    continue;
                }
                if (sqlEql(e, sql)) return i;
            }
            return null;
        }

        /// True when a *checked-out* entry's SQL byte-matches `sql`. Only
        /// consulted on the miss path (to tell a contended miss from a cold
        /// one), so its second scan costs nothing on the hit path.
        fn hasTakenEntry(self: *Self, sql: []const u8) bool {
            for (self.entries[0..self.len]) |*e| {
                if (e.taken and sqlEql(e, sql)) return true;
            }
            return false;
        }

        /// Record which kind of miss this lookup was: the SQL is in the cache
        /// but unavailable (`taken_misses`), or it is not there at all
        /// (`misses`).
        inline fn countMiss(self: *Self, sql: []const u8) void {
            if (self.hasTakenEntry(sql)) {
                self.counts.taken_misses += 1;
            } else {
                self.counts.misses += 1;
            }
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
                self.counts.evictions += 1;
                return true;
            }
            self.counts.uncached_inserts += 1;
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
                @branchHint(.likely);
                self.counts.hits += 1;
                self.moveToFront(i);
                return .{ .stmt = self.entries[i].stmt, .cached = true };
            } else {
                @branchHint(.cold);
                self.countMiss(sql);
                // Cache miss — prepare.
                const stmt = try prepareFn(prepareCtx, sql);
                self.counts.prepares += 1;
                if (!cacheable(sql)) {
                    self.counts.oversized_bypass += 1;
                    return .{ .stmt = stmt, .cached = false };
                }
                const inserted = self.insert(sql, stmt, deinitCtx, deinitFn);
                return .{ .stmt = stmt, .cached = inserted };
            }
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
                @branchHint(.likely);
                self.counts.hits += 1;
                self.entries[i].taken = true;
                return .{ .stmt = self.entries[i].stmt, .slot = i };
            } else {
                @branchHint(.cold);
                self.countMiss(sql);
                const stmt = try prepareFn(ctx, sql);
                self.counts.prepares += 1;
                return .{ .stmt = stmt, .slot = null };
            }
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
                self.counts.returned += 1;
            } else {
                deinitFn(deinitCtx, stmt);
                self.counts.stale_returns += 1;
            }
        }

        /// Failure-path twin of `returnStmt`: release a statement handed out
        /// by `takeOrPrepare` when its consumer fails before a Rows iterator
        /// takes ownership (a failed bind, an allocation failure). A taken
        /// slot goes back through `returnStmt`, which also handles a slot
        /// invalidated by `evictAll` while the statement was checked out; a
        /// `null` slot was never cached (cache miss, oversized SQL), so the
        /// caller-owned handle is released with `deinitFn` — the same shape
        /// the exec path's `owns_stmt` cleanup implements. The caller resets
        /// the statement first, mirroring what `Rows.deinit` does on the
        /// success path.
        pub fn releaseTaken(self: *Self, slot: ?usize, stmt: Handle, deinitCtx: anytype, deinitFn: anytype) void {
            if (slot) |s| {
                self.returnStmt(s, stmt, deinitCtx, deinitFn);
            } else {
                deinitFn(deinitCtx, stmt);
                self.counts.released_uncached += 1;
            }
        }

        /// Evict and deinitialize all cached statements. Taken entries belong
        /// to in-flight Rows iterators: their handles stay valid (owned by the
        /// iterator), but their slots are dropped — a later `returnStmt` sees
        /// the stale slot and releases the handle instead of re-caching it.
        pub fn evictAll(self: *Self, deinitCtx: anytype, deinitFn: anytype) void {
            for (self.entries[0..self.len]) |*e| {
                if (!e.taken) {
                    deinitFn(deinitCtx, e.stmt);
                    self.counts.invalidations += 1;
                }
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

/// The statement words that invalidate every cached prepared statement.
/// Compared case-insensitively through `eqlAsciiIgnoreCase`: SQL arrives in
/// either case, and the caller's cache coherence depends on this answer.
const ddl_keywords = std.StaticStringMapWithEql(void, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
    .{ "create", {} },
    .{ "alter", {} },
    .{ "drop", {} },
});

/// Returns true if `sql` is a DDL statement (CREATE / ALTER / DROP).
/// DDL invalidates all cached prepared statements.
pub fn isDDL(sql: []const u8) bool {
    const s = ltrim(sql, " \t\n\r");
    const first_word = if (std.mem.indexOfAny(u8, s, " \t\n\r")) |idx| s[0..idx] else s;
    return ddl_keywords.has(first_word);
}

inline fn ltrim(s: []const u8, chars: []const u8) []const u8 {
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

test "PreparedCache: releaseTaken puts a taken slot back on a failure path" {
    // The shape the drivers hit when a consumer fails after `takeOrPrepare`
    // but before a Rows iterator owns the statement (a failed bind): the
    // handle is cache-owned, so releasing it must not finalize it and must
    // not strand the reservation.
    var cch: PreparedCache(4, *anyopaque) = .{};
    var ctx = TestCtx{};

    // The statement is already cached (the exec path put it there).
    _ = try cch.getOrPrepare("SELECT 1", &ctx, testPrepare, &ctx, testDeinitCount);

    const t = try cch.takeOrPrepare("SELECT 1", &ctx, testPrepare);
    try std.testing.expect(t.slot != null);
    cch.releaseTaken(t.slot, t.stmt, &ctx, testDeinitCount);

    // Nothing was burned: same length, nothing finalized, nothing taken.
    try std.testing.expectEqual(@as(usize, 1), cch.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.evict_count);
    for (cch.entries[0..cch.len]) |e| try std.testing.expect(!e.taken);

    // The same SQL is a hit again — the failed consumer prepared nothing.
    const again = try cch.takeOrPrepare("SELECT 1", &ctx, testPrepare);
    try std.testing.expectEqual(t.stmt, again.stmt);
    try std.testing.expectEqual(@as(usize, 1), ctx.prepare_count);
    cch.releaseTaken(again.slot, again.stmt, &ctx, testDeinitCount);
}

test "PreparedCache: releaseTaken finalizes a statement that was never cached" {
    var cch: PreparedCache(4, *anyopaque) = .{};
    var ctx = TestCtx{};

    // A take that missed the cache answers slot == null and a handle the
    // caller owns; the null arm releases it, the way the exec path's
    // `owns_stmt` cleanup does.
    const t = try cch.takeOrPrepare("SELECT 1", &ctx, testPrepare);
    try std.testing.expect(t.slot == null);
    cch.releaseTaken(t.slot, t.stmt, &ctx, testDeinitCount);
    try std.testing.expectEqual(@as(usize, 1), ctx.evict_count);
    try std.testing.expectEqual(@as(usize, 0), cch.len);
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

// Counters (`stats()`)
// -----------------------------------------------------------------------
//
// The counters are the only way a consumer can tell "the cache is working"
// from "the cache is being bypassed" or "the cache is thrashing", so each
// increment point is pinned here against the operation that causes it.

/// All-zero counters, for asserting on a single field without repeating the
/// other ten.
fn expectFreshStats(st: PreparedCacheSized(4, *anyopaque, 2048).Stats) !void {
    try std.testing.expectEqual(PreparedCacheSized(4, *anyopaque, 2048).Stats{}, st);
}

test "PreparedCache: stats counts hits, cold misses and prepares" {
    var cch: PreparedCache(4, *anyopaque) = .{};
    var ctx = TestCtx{};
    try expectFreshStats(cch.stats());

    // Two distinct SQL: two cold misses, two prepares, no hits.
    _ = try cch.getOrPrepare("A", &ctx, testPrepare, &ctx, testDeinitCount);
    _ = try cch.getOrPrepare("B", &ctx, testPrepare, &ctx, testDeinitCount);
    var st = cch.stats();
    try std.testing.expectEqual(@as(usize, 0), st.hits);
    try std.testing.expectEqual(@as(usize, 2), st.misses);
    try std.testing.expectEqual(@as(usize, 2), st.prepares);
    try std.testing.expectEqual(@as(usize, 0), st.taken_misses);

    // A repeat of each is a hit, whichever entry point asks. The exec path
    // and the query path share one counter: a statement cached by one and
    // taken by the other is a hit, not a second kind of anything.
    _ = try cch.getOrPrepare("A", &ctx, testPrepare, &ctx, testDeinitCount);
    const t = try cch.takeOrPrepare("B", &ctx, testPrepare);
    st = cch.stats();
    try std.testing.expectEqual(@as(usize, 2), st.hits);
    try std.testing.expectEqual(@as(usize, 2), st.misses);
    try std.testing.expectEqual(@as(usize, 2), st.prepares);
    // A take is not a return: the entry is checked out until `returnStmt`.
    try std.testing.expectEqual(@as(usize, 0), st.returned);
    cch.returnStmt(t.slot.?, t.stmt, &ctx, testDeinitCount);
    try std.testing.expectEqual(@as(usize, 1), cch.stats().returned);
}

test "PreparedCache: stats separates a contended miss from a cold one" {
    var cch: PreparedCache(4, *anyopaque) = .{};
    var ctx = TestCtx{};

    _ = try cch.getOrPrepare("A", &ctx, testPrepare, &ctx, testDeinitCount);
    const t = try cch.takeOrPrepare("A", &ctx, testPrepare);
    const before = cch.stats();

    // The SQL *is* in the cache, but its entry is checked out: a fresh
    // statement is prepared, and `len` grows (the taken entry keeps its slot,
    // so this is a second entry under the same key).
    const p = try cch.getOrPrepare("A", &ctx, testPrepare, &ctx, testDeinitCount);
    try std.testing.expect(p.cached);
    try std.testing.expect(p.stmt != t.stmt);
    try std.testing.expectEqual(@as(usize, 2), cch.len);

    const after = cch.stats();
    try std.testing.expectEqual(before.taken_misses + 1, after.taken_misses);
    try std.testing.expectEqual(before.misses, after.misses); // not a cold miss
    try std.testing.expectEqual(before.prepares + 1, after.prepares);
    try std.testing.expectEqual(before.hits, after.hits); // no hit was served

    cch.releaseTaken(t.slot, t.stmt, &ctx, testDeinitCount);
    try std.testing.expectEqual(@as(usize, 1), cch.stats().returned);
}

test "PreparedCache: stats counts an LRU eviction and an entry no slot could take" {
    var cch: PreparedCache(2, *anyopaque) = .{};
    var ctx = TestCtx{};

    _ = try cch.getOrPrepare("A", &ctx, testPrepare, &ctx, testDeinitCount);
    _ = try cch.getOrPrepare("B", &ctx, testPrepare, &ctx, testDeinitCount);
    try std.testing.expectEqual(@as(usize, 0), cch.stats().evictions);

    // Third entry into a 2-entry cache: one LRU eviction (A is the tail).
    _ = try cch.getOrPrepare("C", &ctx, testPrepare, &ctx, testDeinitCount);
    var st = cch.stats();
    try std.testing.expectEqual(@as(usize, 1), st.evictions);
    try std.testing.expectEqual(@as(usize, 0), st.uncached_inserts);
    try std.testing.expectEqual(@as(usize, 3), st.misses + st.taken_misses);
    try std.testing.expectEqual(@as(usize, 3), st.prepares);

    // Every slot checked out (C and B survived the eviction): the next miss
    // prepares a statement the cache cannot keep, which is its own counter —
    // and it is not an eviction (no cache-owned handle was released).
    const tc = try cch.takeOrPrepare("C", &ctx, testPrepare);
    const tb = try cch.takeOrPrepare("B", &ctx, testPrepare);
    try std.testing.expect(tc.slot != null and tb.slot != null);
    const p = try cch.getOrPrepare("D", &ctx, testPrepare, &ctx, testDeinitCount);
    try std.testing.expect(!p.cached);
    st = cch.stats();
    try std.testing.expectEqual(@as(usize, 1), st.uncached_inserts);
    try std.testing.expectEqual(@as(usize, 1), st.evictions);

    cch.releaseTaken(tc.slot, tc.stmt, &ctx, testDeinitCount);
    cch.releaseTaken(tb.slot, tb.stmt, &ctx, testDeinitCount);
}

test "PreparedCache: stats counts evictAll by entry, and the stale return it causes" {
    var cch: PreparedCache(4, *anyopaque) = .{};
    var ctx = TestCtx{};

    _ = try cch.getOrPrepare("A", &ctx, testPrepare, &ctx, testDeinitCount);
    _ = try cch.getOrPrepare("B", &ctx, testPrepare, &ctx, testDeinitCount);
    const t = try cch.takeOrPrepare("A", &ctx, testPrepare);

    // DDL invalidation drops the one non-taken entry (B) and leaves A's slot
    // to the iterator that owns it — counted by entry, so the checked-out one
    // is not in the number.
    cch.evictAll(&ctx, testDeinitCount);
    try std.testing.expectEqual(@as(usize, 1), cch.stats().invalidations);

    // The return finds its slot gone: the handle is released rather than
    // re-cached, and that loss is visible instead of silent (the v0.85 shape).
    cch.returnStmt(t.slot.?, t.stmt, &ctx, testDeinitCount);
    const st = cch.stats();
    try std.testing.expectEqual(@as(usize, 1), st.stale_returns);
    try std.testing.expectEqual(@as(usize, 0), st.returned);
    try std.testing.expectEqual(@as(usize, 0), st.released_uncached);
}

test "PreparedCache: stats counts a failed-take release, cached or not" {
    var cch: PreparedCache(4, *anyopaque) = .{};
    var ctx = TestCtx{};

    _ = try cch.getOrPrepare("A", &ctx, testPrepare, &ctx, testDeinitCount);

    // The v0.85 shape: the query path checked A out, then failed before a Rows
    // iterator took ownership. The slot goes back — a `returned`, never a
    // `released_uncached`, because the handle is still the cache's.
    const hit_take = try cch.takeOrPrepare("A", &ctx, testPrepare);
    cch.releaseTaken(hit_take.slot, hit_take.stmt, &ctx, testDeinitCount);
    var st = cch.stats();
    try std.testing.expectEqual(@as(usize, 1), st.returned);
    try std.testing.expectEqual(@as(usize, 0), st.released_uncached);
    try std.testing.expectEqual(@as(usize, 0), st.stale_returns);

    // A take that missed: the handle is the caller's, and releasing it is not
    // a cache event — nothing was cached to lose.
    const miss_take = try cch.takeOrPrepare("B", &ctx, testPrepare);
    try std.testing.expect(miss_take.slot == null);
    cch.releaseTaken(miss_take.slot, miss_take.stmt, &ctx, testDeinitCount);
    st = cch.stats();
    try std.testing.expectEqual(@as(usize, 1), st.released_uncached);
    try std.testing.expectEqual(@as(usize, 1), st.returned);
    // The take itself was a cold miss and a prepare, like any other.
    try std.testing.expectEqual(@as(usize, 2), st.misses);
    try std.testing.expectEqual(@as(usize, 2), st.prepares);
}

test "PreparedCache: stats counts the oversized-SQL bypass" {
    var cch: PreparedCacheSized(2, *anyopaque, 4) = .{};
    var ctx = TestCtx{};

    _ = try cch.getOrPrepare("SELECT 1", &ctx, testPrepare, &ctx, testDeinitCount);
    _ = try cch.getOrPrepare("SELECT 1", &ctx, testPrepare, &ctx, testDeinitCount);
    var st = cch.stats();
    // It misses every time, by construction: nothing is ever stored. The
    // subset counter is what answers "why does this statement never hit?".
    try std.testing.expectEqual(@as(usize, 2), st.oversized_bypass);
    try std.testing.expectEqual(@as(usize, 2), st.misses);
    try std.testing.expectEqual(@as(usize, 2), st.prepares);
    try std.testing.expectEqual(@as(usize, 0), st.evictions);
    try std.testing.expectEqual(@as(usize, 0), st.uncached_inserts);

    // Short SQL takes the ordinary path and is not counted as oversized.
    _ = try cch.getOrPrepare("SEL", &ctx, testPrepare, &ctx, testDeinitCount);
    st = cch.stats();
    try std.testing.expectEqual(@as(usize, 2), st.oversized_bypass);
    try std.testing.expectEqual(@as(usize, 3), st.misses);
    try std.testing.expectEqual(@as(usize, 1), cch.len);
}

test "PreparedCache: a failed prepare is a miss but not a prepare" {
    // `prepares` counts statements the cache really prepared; the lookup that
    // asked for one is counted either way. A failing `prepareFn` is the only
    // way the two numbers can disagree, and the docs say so.
    var cch: PreparedCache(4, *anyopaque) = .{};
    var ctx = TestCtx{};
    try std.testing.expectError(
        error.PrepareFailed,
        cch.getOrPrepare("A", &ctx, struct {
            fn f(_: *TestCtx, _: []const u8) !*anyopaque {
                return error.PrepareFailed;
            }
        }.f, &ctx, testDeinitCount),
    );
    const st = cch.stats();
    try std.testing.expectEqual(@as(usize, 1), st.misses);
    try std.testing.expectEqual(@as(usize, 0), st.prepares);
    try std.testing.expectEqual(@as(usize, 0), cch.len);
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
