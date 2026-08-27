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
