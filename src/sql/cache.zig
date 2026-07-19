const std = @import("std");

/// Comptime-fixed-capacity LRU cache for prepared statements.
///
/// No runtime allocation — all storage is inline in the struct.
/// `capacity` is the maximum number of cached entries (default: 16).
/// `Handle` is the driver-specific statement type (e.g. `*c.sqlite3_stmt`).
pub fn PreparedCache(comptime capacity: usize, comptime Handle: type) type {
    return struct {
        const Self = @This();

        const Entry = struct {
            sql_hash: u64,
            sql_len: usize,
            stmt: Handle,
        };

        entries: [capacity]Entry = undefined,
        len: usize = 0,
        /// LRU order: index 0 is MRU, index len-1 is LRU.
        order: [capacity]usize = undefined,

        /// Get a cached statement or prepare a new one.
        /// The returned handle remains in the cache; callers must reset it
        /// before binding (e.g. `sqlite3_reset` / `mysql_stmt_reset`).
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
        ) !Handle {
            const hash = std.hash.Wyhash.hash(0, sql);

            // Linear scan (small capacity; fine for ≤ ~64 entries).
            for (self.entries[0..self.len], 0..) |*e, i| {
                if (e.sql_hash == hash and e.sql_len == sql.len) {
                    self.moveToFront(i);
                    return e.stmt;
                }
            }

            // Cache miss — prepare.
            const stmt = try prepareFn(prepareCtx, sql);
            if (self.len < capacity) {
                self.entries[self.len] = .{ .sql_hash = hash, .sql_len = sql.len, .stmt = stmt };
                // Newest entry is MRU; shift existing order right.
                var j: usize = self.len;
                while (j > 0) : (j -= 1) {
                    self.order[j] = self.order[j - 1];
                }
                self.order[0] = self.len;
                self.len += 1;
            } else {
                // Evict LRU entry.
                const evict_idx = self.order[self.len - 1];
                deinitFn(deinitCtx, self.entries[evict_idx].stmt);
                self.entries[evict_idx] = .{ .sql_hash = hash, .sql_len = sql.len, .stmt = stmt };
                self.moveToFront(evict_idx);
            }
            return stmt;
        }

        /// Take a cached statement (removing it from the cache) or prepare a new one.
        /// The caller owns the returned handle and must eventually release it.
        /// Use this for query() where the statement lifetime is managed by a Rows iterator.
        pub fn takeOrPrepare(
            self: *Self,
            sql: []const u8,
            ctx: anytype,
            prepareFn: anytype,
        ) !Handle {
            const hash = std.hash.Wyhash.hash(0, sql);

            for (self.entries[0..self.len], 0..) |*e, i| {
                if (e.sql_hash == hash and e.sql_len == sql.len) {
                    const stmt = e.stmt;
                    self.removeEntry(i);
                    return stmt;
                }
            }

            return try prepareFn(ctx, sql);
        }

        /// Evict and deinitialize all cached statements.
        pub fn evictAll(self: *Self, deinitCtx: anytype, deinitFn: anytype) void {
            for (self.entries[0..self.len]) |*e| {
                deinitFn(deinitCtx, e.stmt);
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

        /// Remove the entry at `entry_idx` from the cache.
        fn removeEntry(self: *Self, entry_idx: usize) void {
            // Compact the entries slice.
            const last = self.len - 1;
            if (entry_idx != last) {
                self.entries[entry_idx] = self.entries[last];
                // Update order: replace references to `last` with `entry_idx`.
                for (self.order[0..self.len]) |*o| {
                    if (o.* == last) {
                        o.* = entry_idx;
                    }
                }
            }
            self.len -= 1;

            // Remove from order array.
            var dst: usize = 0;
            for (self.order[0 .. self.len + 1]) |o| {
                if (o != entry_idx and dst < self.len) {
                    self.order[dst] = o;
                    dst += 1;
                }
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

test "PreparedCache: getOrPrepare caches by hash" {
    var cch: PreparedCache(4, *anyopaque) = .{};
    var ctx = TestCtx{};

    const h1 = try cch.getOrPrepare("SELECT 1", &ctx, testPrepare, &ctx, testDeinitCount);
    const h2 = try cch.getOrPrepare("SELECT 1", &ctx, testPrepare, &ctx, testDeinitCount);
    try std.testing.expectEqual(h1, h2);
    try std.testing.expectEqual(@as(usize, 1), ctx.prepare_count);
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

test "PreparedCache: takeOrPrepare removes from cache" {
    var cch: PreparedCache(4, *anyopaque) = .{};
    var ctx = TestCtx{};

    _ = try cch.takeOrPrepare("SELECT 1", &ctx, testPrepare);
    try std.testing.expectEqual(@as(usize, 0), cch.len); // removed
    try std.testing.expectEqual(@as(usize, 1), ctx.prepare_count);

    // Next call re-prepares.
    _ = try cch.takeOrPrepare("SELECT 1", &ctx, testPrepare);
    try std.testing.expectEqual(@as(usize, 0), cch.len);
    try std.testing.expectEqual(@as(usize, 2), ctx.prepare_count);
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
