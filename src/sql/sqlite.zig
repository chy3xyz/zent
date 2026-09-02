const std = @import("std");
const c = @import("sqlite3_c");
const Value = @import("builder.zig").Value;
const Dialect = @import("dialect.zig").Dialect;
const driver = @import("driver.zig");
const cache = @import("cache.zig");

pub const SQLiteDriver = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,
    /// Default busy timeout used when no ExecutionContext deadline is present.
    default_busy_timeout: c_int = 5000,
    /// Optional prepared-statement cache. Set this field after `open()` to
    /// enable caching; null (the default) disables it.
    cache: ?cache.PreparedCache(16, *c.sqlite3_stmt) = null,
    /// Serializes all access to the connection. Servers (e.g. zigmodu) run
    /// handlers on multiple worker threads while sqlite (and the stmt cache,
    /// and the allocator) behind a single connection is not safe for
    /// concurrent use — observed as SEGV inside sqlite3_prepare_v2 when two
    /// requests race. Recursive so a tx body / eager-load recursion can issue
    /// nested statements on the same thread while holding the lock.
    mutex: RecursiveMutex = .{},

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !SQLiteDriver {
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_z);

        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path_z.ptr, &db);
        if (rc != c.SQLITE_OK or db == null) {
            if (db) |handle| {
                const msg = c.sqlite3_errmsg(handle);
                std.log.err("sqlite open failed: {s}", .{msg});
                _ = c.sqlite3_close(handle);
            }
            return error.SqliteOpenFailed;
        }
        const default_busy_timeout: c_int = 5000;
        _ = c.sqlite3_busy_timeout(db.?, default_busy_timeout);
        return SQLiteDriver{ .db = db.?, .allocator = allocator, .default_busy_timeout = default_busy_timeout };
    }

    pub fn close(self: *SQLiteDriver) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.cache) |*cached| {
            cached.evictAll({}, finalizeStmt);
        }
        _ = c.sqlite3_close(self.db);
    }

    fn logSqliteError(db: *c.sqlite3, context: []const u8) void {
        const msg = c.sqlite3_errmsg(db);
        std.log.err("SQLite error ({s}): {s}", .{ context, std.mem.span(msg) });
    }

    fn toDriverError(err: anyerror) driver.Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SqliteOpenFailed => error.ConnectionFailed,
            error.SqlitePrepareFailed => error.PrepareFailed,
            error.SqliteExecFailed => error.ExecFailed,
            error.SqliteInterrupt => error.QueryTimeout,
            error.TxNotActive => error.TxFailed,
            error.QueryTimeout => error.QueryTimeout,
            error.UniqueViolation => error.UniqueViolation,
            error.NotNullViolation => error.NotNullViolation,
            error.ForeignKeyViolation => error.ForeignKeyViolation,
            else => error.DriverFailed,
        };
    }

    fn applyDeadline(self: *SQLiteDriver, ctx: ?*const driver.ExecutionContext, saved_timeout: *c_int) void {
        saved_timeout.* = self.default_busy_timeout;
        if (ctx) |cx| {
            if (cx.remainingMs()) |ms| {
                _ = c.sqlite3_busy_timeout(self.db, @intCast(ms));
            }
        }
    }

    fn restoreDeadline(self: *SQLiteDriver, saved_timeout: c_int) void {
        _ = c.sqlite3_busy_timeout(self.db, saved_timeout);
    }

    fn progressCallback(ctx: ?*anyopaque) callconv(.c) c_int {
        const ec: *const driver.ExecutionContext = @ptrCast(@alignCast(ctx.?));
        if (ec.remainingMs()) |ms| {
            if (ms == 0) return 1; // interrupt
        }
        return 0;
    }

    pub fn exec(self: *SQLiteDriver, sql: []const u8, args: []const Value) !driver.Result {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.execInner(null, sql, args);
    }

    /// Body of exec; assumes `self.mutex` is already held by this thread.
    fn execInner(self: *SQLiteDriver, ctx: ?*const driver.ExecutionContext, sql: []const u8, args: []const Value) !driver.Result {
        var saved_busy: c_int = undefined;
        self.applyDeadline(ctx, &saved_busy);
        if (ctx) |cx| {
            c.sqlite3_progress_handler(self.db, 100, progressCallback, @ptrCast(@constCast(cx)));
        }
        defer {
            if (ctx != null) {
                c.sqlite3_progress_handler(self.db, 0, null, null);
            }
            self.restoreDeadline(saved_busy);
        }

        // DDL invalidates cached prepared statements.
        if (self.cache) |*cached| {
            if (cache.isDDL(sql)) {
                cached.evictAll({}, finalizeStmt);
            }
        }

        var owns_stmt = true;
        const stmt = if (self.cache) |*cached| blk: {
            const p = try cached.getOrPrepare(sql, self.db, prepareStmt, {}, finalizeStmt);
            owns_stmt = !p.cached;
            break :blk p.stmt;
        } else blk: {
            var out: ?*c.sqlite3_stmt = null;
            const rc = c.sqlite3_prepare_v2(self.db, @ptrCast(sql.ptr), @intCast(sql.len), @ptrCast(&out), null);
            if (rc != c.SQLITE_OK or out == null) {
                logSqliteError(self.db, "prepare");
                return error.SqlitePrepareFailed;
            }
            break :blk out.?;
        };
        defer {
            if (owns_stmt) _ = c.sqlite3_finalize(stmt);
        }

        // Reset before rebinding (needed when stmt came from cache).
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);
        try bindArgs(stmt, args);
        const step_rc = c.sqlite3_step(stmt);
        if (step_rc != c.SQLITE_DONE and step_rc != c.SQLITE_ROW) {
            logSqliteError(self.db, "exec");
            if (step_rc == c.SQLITE_INTERRUPT) return error.SqliteInterrupt;
            if (step_rc == c.SQLITE_CONSTRAINT) return toDriverError(sqliteErrnoToDriver(self.db, error.ExecFailed));
            return error.SqliteExecFailed;
        }
        return driver.Result{
            .rows_affected = @intCast(c.sqlite3_changes(self.db)),
            .last_insert_id = c.sqlite3_last_insert_rowid(self.db),
        };
    }

    pub fn query(self: *SQLiteDriver, query_sql: []const u8, args: []const Value) !driver.Rows {
        self.mutex.lock();
        errdefer self.mutex.unlock();
        return self.queryInner(null, query_sql, args);
    }

    /// Body of query; assumes `self.mutex` is already held by this thread.
    /// On success the lock ownership transfers to the returned Rows, whose
    /// deinit() restores the deadline/progress handler and unlocks.
    fn queryInner(self: *SQLiteDriver, ctx: ?*const driver.ExecutionContext, query_sql: []const u8, args: []const Value) !driver.Rows {
        var saved_busy: c_int = undefined;
        self.applyDeadline(ctx, &saved_busy);
        if (ctx) |cx| {
            c.sqlite3_progress_handler(self.db, 100, progressCallback, @ptrCast(@constCast(cx)));
        }
        errdefer {
            if (ctx != null) {
                c.sqlite3_progress_handler(self.db, 0, null, null);
            }
            self.restoreDeadline(saved_busy);
        }

        var cache_slot: ?usize = null;
        const stmt = if (self.cache) |*cached| blk: {
            const t = try cached.takeOrPrepare(query_sql, self.db, prepareStmtQuery);
            cache_slot = t.slot;
            break :blk t.stmt;
        } else blk: {
            var out: ?*c.sqlite3_stmt = null;
            const rc = c.sqlite3_prepare_v2(
                self.db,
                @ptrCast(query_sql.ptr),
                @intCast(query_sql.len),
                @ptrCast(&out),
                null,
            );
            if (rc != c.SQLITE_OK or out == null) {
                logSqliteError(self.db, "prepare query");
                return error.SqlitePrepareFailed;
            }
            break :blk out.?;
        };
        errdefer _ = c.sqlite3_finalize(stmt);

        // Reset before rebinding (needed when stmt came from cache).
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);
        try bindArgs(stmt, args);

        const rows_ptr = try self.allocator.create(SQLiteRows);
        errdefer self.allocator.destroy(rows_ptr);
        rows_ptr.* = SQLiteRows{
            .stmt = stmt,
            .allocator = self.allocator,
            .done = false,
            .cache = if (cache_slot != null) &self.cache.? else null,
            .cache_slot = cache_slot,
            .driver = self,
            .saved_busy = saved_busy,
            .clear_progress = ctx != null,
        };

        return driver.Rows{
            .ptr = rows_ptr,
            .vtable = &SQLiteRows.vtable,
        };
    }

    pub fn beginTx(self: *SQLiteDriver) !driver.Tx {
        self.mutex.lock();
        errdefer self.mutex.unlock();
        _ = try self.execInner(null, "BEGIN", &.{});
        const tx_ptr = try self.allocator.create(SQLiteTx);
        errdefer self.allocator.destroy(tx_ptr);
        tx_ptr.* = SQLiteTx{
            .driver = self,
            .state = .active,
        };
        return driver.Tx{
            .inner = self.asDriver(),
            .commitFn = struct {
                fn f(ptr: *anyopaque) driver.Error!void {
                    const self_ptr: *SQLiteTx = @ptrCast(@alignCast(ptr));
                    return self_ptr.commit() catch |err| return toDriverError(err);
                }
            }.f,
            .rollbackFn = struct {
                fn f(ptr: *anyopaque) driver.Error!void {
                    const self_ptr: *SQLiteTx = @ptrCast(@alignCast(ptr));
                    return self_ptr.rollback() catch |err| return toDriverError(err);
                }
            }.f,
            .deinitFn = struct {
                fn f(ptr: *anyopaque) void {
                    const self_ptr: *SQLiteTx = @ptrCast(@alignCast(ptr));
                    self_ptr.deinit();
                }
            }.f,
            .savepointFn = struct {
                fn f(ptr: *anyopaque, name: []const u8) driver.Error!void {
                    const self_ptr: *SQLiteDriver = @ptrCast(@alignCast(ptr));
                    return execSavepointStmt(self_ptr, "SAVEPOINT", name) catch |err| return toDriverError(err);
                }
            }.f,
            .savepointRollbackFn = struct {
                fn f(ptr: *anyopaque, name: []const u8) driver.Error!void {
                    const self_ptr: *SQLiteDriver = @ptrCast(@alignCast(ptr));
                    return execSavepointStmt(self_ptr, "ROLLBACK TO", name) catch |err| return toDriverError(err);
                }
            }.f,
            .savepointReleaseFn = struct {
                fn f(ptr: *anyopaque, name: []const u8) driver.Error!void {
                    const self_ptr: *SQLiteDriver = @ptrCast(@alignCast(ptr));
                    return execSavepointStmt(self_ptr, "RELEASE", name) catch |err| return toDriverError(err);
                }
            }.f,
            .ptr = tx_ptr,
        };
    }

    /// Open a nested savepoint on an already-active transaction.
    pub fn beginSavepoint(self: *SQLiteDriver, name: []const u8) !driver.Tx {
        try execSavepointStmt(self, "SAVEPOINT", name);
        const sp = try self.allocator.create(SQLiteSavepoint);
        errdefer self.allocator.destroy(sp);
        sp.* = .{
            .driver = self,
            .name = try self.allocator.dupe(u8, name),
            .active = true,
        };
        return driver.Tx{
            .inner = self.asDriver(),
            .commitFn = struct {
                fn f(ptr: *anyopaque) driver.Error!void {
                    const s: *SQLiteSavepoint = @ptrCast(@alignCast(ptr));
                    return s.commit() catch |err| return toDriverError(err);
                }
            }.f,
            .rollbackFn = struct {
                fn f(ptr: *anyopaque) driver.Error!void {
                    const s: *SQLiteSavepoint = @ptrCast(@alignCast(ptr));
                    return s.rollback() catch |err| return toDriverError(err);
                }
            }.f,
            .deinitFn = struct {
                fn f(ptr: *anyopaque) void {
                    const s: *SQLiteSavepoint = @ptrCast(@alignCast(ptr));
                    s.deinit();
                }
            }.f,
            .ptr = sp,
        };
    }

    pub fn ping(self: *SQLiteDriver) !void {
        _ = try self.exec("SELECT 1", &.{});
    }

    /// Returns true if a transaction is currently active on this connection.
    /// SQLite is in autocommit mode when not inside an explicit transaction.
    pub fn inTransaction(self: *SQLiteDriver) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return c.sqlite3_get_autocommit(self.db) == 0;
    }

    pub fn asDriver(self: *SQLiteDriver) driver.Driver {
        return driver.Driver{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = driver.Driver.VTable{
        .exec = struct {
            fn f(ptr: *anyopaque, ctx: ?*const driver.ExecutionContext, q: []const u8, a: []const Value) driver.Error!driver.Result {
                const self_ptr: *SQLiteDriver = @ptrCast(@alignCast(ptr));
                self_ptr.mutex.lock();
                defer self_ptr.mutex.unlock();
                return self_ptr.execInner(ctx, q, a) catch |err| return toDriverError(err);
            }
        }.f,
        .query = struct {
            fn f(ptr: *anyopaque, ctx: ?*const driver.ExecutionContext, q: []const u8, a: []const Value) driver.Error!driver.Rows {
                const self_ptr: *SQLiteDriver = @ptrCast(@alignCast(ptr));
                self_ptr.mutex.lock();
                errdefer self_ptr.mutex.unlock();
                // 成功路径锁所有权随 Rows 转移（deinit 时释放）。
                return self_ptr.queryInner(ctx, q, a) catch |err| return toDriverError(err);
            }
        }.f,
        .beginTx = struct {
            fn f(ptr: *anyopaque) driver.Error!driver.Tx {
                const self_ptr: *SQLiteDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.beginTx() catch |err| return toDriverError(err);
            }
        }.f,
        .close = struct {
            fn f(ptr: *anyopaque) void {
                const self_ptr: *SQLiteDriver = @ptrCast(@alignCast(ptr));
                self_ptr.close();
            }
        }.f,
        .dialect = struct {
            fn f(_: *anyopaque) Dialect {
                return Dialect.sqlite;
            }
        }.f,
        .ping = struct {
            fn f(ptr: *anyopaque) driver.Error!void {
                const self_ptr: *SQLiteDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.ping() catch |err| return toDriverError(err);
            }
        }.f,
        .inTransaction = struct {
            fn f(ptr: *anyopaque) bool {
                const self_ptr: *SQLiteDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.inTransaction();
            }
        }.f,
        .beginSavepoint = struct {
            fn f(ptr: *anyopaque, name: []const u8) driver.Error!driver.Tx {
                const self_ptr: *SQLiteDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.beginSavepoint(name) catch |err| return toDriverError(err);
            }
        }.f,
    };
};

/// Map a sqlite3_step error to a driver.Error, classifying the extended
/// constraint codes (sqlite3_step returns the primary code; the extended
/// code — SQLITE_CONSTRAINT_UNIQUE etc — comes from extended_errcode).
fn sqliteErrnoToDriver(db: *c.sqlite3, fallback: driver.Error) driver.Error {
    return switch (c.sqlite3_extended_errcode(db)) {
        2067 => error.UniqueViolation, // SQLITE_CONSTRAINT_UNIQUE
        1299 => error.NotNullViolation, // SQLITE_CONSTRAINT_NOTNULL
        787 => error.ForeignKeyViolation, // SQLITE_CONSTRAINT_FOREIGNKEY
        else => fallback,
    };
}

fn execSavepointStmt(d: *SQLiteDriver, stmt: []const u8, name: []const u8) !void {
    const sql = try std.fmt.allocPrint(d.allocator, "{s} \"{s}\"", .{ stmt, name });
    defer d.allocator.free(sql);
    _ = try d.exec(sql, &.{});
}

const SQLiteSavepoint = struct {
    driver: *SQLiteDriver,
    name: []u8,
    active: bool,

    fn commit(self: *SQLiteSavepoint) !void {
        if (!self.active) return;
        try execSavepointStmt(self.driver, "RELEASE", self.name);
        self.active = false;
    }

    fn rollback(self: *SQLiteSavepoint) !void {
        if (!self.active) return;
        try execSavepointStmt(self.driver, "ROLLBACK TO", self.name);
        self.active = false;
    }

    fn deinit(self: *SQLiteSavepoint) void {
        self.rollback() catch {};
        self.driver.allocator.free(self.name);
        self.driver.allocator.destroy(self);
    }
};

const SQLiteTx = struct {
    driver: *SQLiteDriver,
    state: enum { active, committed, rolled_back },

    fn commit(self: *SQLiteTx) !void {
        if (self.state != .active) return error.TxNotActive;
        _ = try self.driver.execInner(null, "COMMIT", &.{});
        self.state = .committed;
        self.driver.mutex.unlock();
    }

    fn rollback(self: *SQLiteTx) !void {
        if (self.state != .active) return;
        // Best-effort; ignore failure (driver may have already closed).
        _ = self.driver.execInner(null, "ROLLBACK", &.{}) catch {};
        self.state = .rolled_back;
        self.driver.mutex.unlock();
    }

    fn deinit(self: *SQLiteTx) void {
        if (self.state == .active) {
            std.log.warn("sqlite tx deinit without commit/rollback; rolling back", .{});
            _ = self.driver.execInner(null, "ROLLBACK", &.{}) catch {};
            self.driver.mutex.unlock();
        }
        self.driver.allocator.destroy(self);
    }
};

const SQLiteRows = struct {
    stmt: *c.sqlite3_stmt,
    allocator: std.mem.Allocator,
    done: bool,
    next_error: ?driver.Error = null,
    cache: ?*cache.PreparedCache(16, *c.sqlite3_stmt) = null,
    cache_slot: ?usize = null,
    /// Lock ownership transferred from queryInner; deinit restores the
    /// deadline/progress handler and releases the driver mutex.
    driver: *SQLiteDriver,
    saved_busy: c_int,
    clear_progress: bool,

    const vtable = driver.Rows.VTable{
        .next = next,
        .deinit = deinit,
        .nextError = nextErrorFn,
    };

    fn nextErrorFn(ptr: *anyopaque) ?driver.Error {
        const self: *SQLiteRows = @ptrCast(@alignCast(ptr));
        return self.next_error;
    }

    fn next(ptr: *anyopaque) ?driver.Row {
        const self: *SQLiteRows = @ptrCast(@alignCast(ptr));
        if (self.done) return null;
        const rc = c.sqlite3_step(self.stmt);
        if (rc == c.SQLITE_DONE) {
            self.done = true;
            return null;
        }
        if (rc != c.SQLITE_ROW) {
            // A step error (e.g. a NOT NULL/UNIQUE constraint hit mid-INSERT
            // ... RETURNING) must be surfaced via nextError, not swallowed as
            // "no more rows" (which used to surface as error.NotFound).
            self.done = true;
            if (rc == c.SQLITE_CONSTRAINT) {
                const db = c.sqlite3_db_handle(self.stmt) orelse return null;
                self.next_error = sqliteErrnoToDriver(db, error.ExecFailed);
            }
            return null;
        }
        return driver.Row{
            .ptr = self,
            .vtable = &row_vtable,
        };
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *SQLiteRows = @ptrCast(@alignCast(ptr));
        if (self.cache_slot) |slot| {
            _ = c.sqlite3_reset(self.stmt);
            _ = c.sqlite3_clear_bindings(self.stmt);
            self.cache.?.returnStmt(slot, self.stmt, {}, struct {
                fn f(_: anytype, s: *c.sqlite3_stmt) void {
                    _ = c.sqlite3_finalize(s);
                }
            }.f);
        } else {
            _ = c.sqlite3_finalize(self.stmt);
        }
        if (self.clear_progress) {
            c.sqlite3_progress_handler(self.driver.db, 0, null, null);
        }
        self.driver.restoreDeadline(self.saved_busy);
        self.driver.mutex.unlock();
        const alloc = self.allocator;
        alloc.destroy(self);
    }

    const row_vtable = driver.Row.VTable{
        .columnCount = columnCount,
        .columnName = columnName,
        .getBool = getBool,
        .getInt = getInt,
        .getFloat = getFloat,
        .getText = getText,
        .getBlob = getBlob,
        .isNull = isNull,
    };

    fn columnCount(ptr: *anyopaque) usize {
        const self: *SQLiteRows = @ptrCast(@alignCast(ptr));
        return @intCast(c.sqlite3_column_count(self.stmt));
    }

    fn columnName(ptr: *anyopaque, index: usize) []const u8 {
        const self: *SQLiteRows = @ptrCast(@alignCast(ptr));
        const name = c.sqlite3_column_name(self.stmt, @intCast(index));
        return std.mem.span(name);
    }

    fn getBool(ptr: *anyopaque, index: usize) ?bool {
        const self: *SQLiteRows = @ptrCast(@alignCast(ptr));
        if (c.sqlite3_column_type(self.stmt, @intCast(index)) == c.SQLITE_NULL) return null;
        return c.sqlite3_column_int(self.stmt, @intCast(index)) != 0;
    }

    fn getInt(ptr: *anyopaque, index: usize) ?i64 {
        const self: *SQLiteRows = @ptrCast(@alignCast(ptr));
        if (c.sqlite3_column_type(self.stmt, @intCast(index)) == c.SQLITE_NULL) return null;
        return c.sqlite3_column_int64(self.stmt, @intCast(index));
    }

    fn getFloat(ptr: *anyopaque, index: usize) ?f64 {
        const self: *SQLiteRows = @ptrCast(@alignCast(ptr));
        if (c.sqlite3_column_type(self.stmt, @intCast(index)) == c.SQLITE_NULL) return null;
        return c.sqlite3_column_double(self.stmt, @intCast(index));
    }

    fn getText(ptr: *anyopaque, index: usize) ?[]const u8 {
        const self: *SQLiteRows = @ptrCast(@alignCast(ptr));
        if (c.sqlite3_column_type(self.stmt, @intCast(index)) == c.SQLITE_NULL) return null;
        const text = c.sqlite3_column_text(self.stmt, @intCast(index));
        const len = c.sqlite3_column_bytes(self.stmt, @intCast(index));
        if (text == null) return null;
        return text[0..@intCast(len)];
    }

    fn getBlob(ptr: *anyopaque, index: usize) ?[]const u8 {
        const self: *SQLiteRows = @ptrCast(@alignCast(ptr));
        if (c.sqlite3_column_type(self.stmt, @intCast(index)) == c.SQLITE_NULL) return null;
        const blob = c.sqlite3_column_blob(self.stmt, @intCast(index));
        const len = c.sqlite3_column_bytes(self.stmt, @intCast(index));
        if (blob == null) return null;
        const ptr_u8: [*]const u8 = @ptrCast(blob);
        return ptr_u8[0..@intCast(len)];
    }

    fn isNull(ptr: *anyopaque, index: usize) bool {
        const self: *SQLiteRows = @ptrCast(@alignCast(ptr));
        return c.sqlite3_column_type(self.stmt, @intCast(index)) == c.SQLITE_NULL;
    }
};

fn finalizeStmt(_: void, stmt: *c.sqlite3_stmt) void {
    _ = c.sqlite3_finalize(stmt);
}

/// Same-thread recursive mutex, so a transaction (or eager-load recursion)
/// can run nested statements while holding the driver lock. Blocking wait via
/// pthread mutex (std.Io.Mutex would need an Io this layer doesn't have, and
/// std.Thread.Futex no longer exists in this Zig).
const RecursiveMutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    owner: std.atomic.Value(std.Thread.Id) = .init(0),
    recursion: usize = 0,

    fn lock(self: *RecursiveMutex) void {
        const tid = std.Thread.getCurrentId();
        // Only the owner thread ever mutates `recursion`; a live holder always
        // has a unique thread id, so a same-id hit means we are the holder.
        if (self.owner.load(.acquire) == tid) {
            self.recursion += 1;
            return;
        }
        _ = std.c.pthread_mutex_lock(&self.inner);
        self.owner.store(tid, .release);
        self.recursion = 1;
    }

    fn unlock(self: *RecursiveMutex) void {
        self.recursion -= 1;
        if (self.recursion != 0) return;
        self.owner.store(0, .release);
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

fn prepareStmt(db: *c.sqlite3, sql: []const u8) !*c.sqlite3_stmt {
    var out: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, @ptrCast(sql.ptr), @intCast(sql.len), @ptrCast(&out), null);
    if (rc != c.SQLITE_OK or out == null) {
        SQLiteDriver.logSqliteError(db, "prepare");
        return error.SqlitePrepareFailed;
    }
    return out.?;
}

fn prepareStmtQuery(db: *c.sqlite3, sql: []const u8) !*c.sqlite3_stmt {
    var out: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, @ptrCast(sql.ptr), @intCast(sql.len), @ptrCast(&out), null);
    if (rc != c.SQLITE_OK or out == null) {
        SQLiteDriver.logSqliteError(db, "prepare query");
        return error.SqlitePrepareFailed;
    }
    return out.?;
}

fn bindArgs(stmt: *c.sqlite3_stmt, args: []const Value) !void {
    for (args, 0..) |arg, i| {
        const idx: c_int = @intCast(i + 1);
        switch (arg) {
            .null => {
                _ = c.sqlite3_bind_null(stmt, idx);
            },
            .bool => |v| {
                _ = c.sqlite3_bind_int64(stmt, idx, if (v) 1 else 0);
            },
            .int => |v| {
                _ = c.sqlite3_bind_int64(stmt, idx, v);
            },
            .float => |v| {
                _ = c.sqlite3_bind_double(stmt, idx, v);
            },
            .string => |v| {
                _ = c.sqlite3_bind_text(stmt, idx, v.ptr, @intCast(v.len), null);
            },
            .bytes => |v| {
                _ = c.sqlite3_bind_blob(stmt, idx, v.ptr, @intCast(v.len), null);
            },
        }
    }
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "SQLite driver basic operations" {
    const allocator = std.testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    // Create table
    _ = try drv.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)", &.{});

    // Insert
    const res = try drv.exec("INSERT INTO users (name, age) VALUES (?, ?)", &.{ .{ .string = "alice" }, .{ .int = 30 } });
    try std.testing.expectEqual(@as(usize, 1), res.rows_affected);
    try std.testing.expect(res.last_insert_id != null);

    // Query
    var rows = try drv.query("SELECT id, name, age FROM users WHERE age = ?", &.{.{ .int = 30 }});
    defer rows.deinit();

    const row = rows.next() orelse return error.NoRow;
    try std.testing.expectEqual(@as(usize, 3), row.columnCount());
    try std.testing.expectEqualStrings("id", row.columnName(0));
    try std.testing.expectEqual(@as(i64, 1), row.getInt(0).?);
    try std.testing.expectEqualStrings("alice", row.getText(1).?);
    try std.testing.expectEqual(@as(i64, 30), row.getInt(2).?);

    // No more rows
    try std.testing.expect(rows.next() == null);
}

test "SQLite transaction" {
    const allocator = std.testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER)", &.{});

    var tx = try drv.beginTx();
    defer tx.deinit();
    _ = try tx.exec("INSERT INTO t (id) VALUES (?)", &.{.{ .int = 42 }});
    try tx.commit();

    var rows = try drv.query("SELECT id FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try std.testing.expectEqual(@as(i64, 42), row.getInt(0).?);
}

test "SQLite uncached exec finalizes statements after success" {
    var drv = try SQLiteDriver.open(std.testing.allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER)", &.{});

    try std.testing.expect(c.sqlite3_next_stmt(drv.db, null) == null);
}

test "SQLite concurrent access from multiple threads is serialized" {
    // Regression: a shared connection used from several threads raced inside
    // sqlite3_prepare_v2 / the stmt cache and segfaulted. The driver mutex
    // must serialize exec / query(→Rows lifetime) / tx across threads.
    const allocator = std.testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();

    _ = try drv.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)", &.{});

    const Worker = struct {
        fn run(d: *SQLiteDriver, base: i64) void {
            var i: i64 = 0;
            while (i < 200) : (i += 1) {
                // tx path (holds the lock across nested execs)
                var tx = d.beginTx() catch return;
                _ = tx.exec("INSERT INTO t (v) VALUES (?)", &.{.{ .int = base + i }}) catch {
                    tx.deinit();
                    return;
                };
                tx.commit() catch {
                    tx.deinit();
                    return;
                };
                tx.deinit();
                // query path (lock held until rows.deinit)
                var rows = d.query("SELECT COUNT(*) FROM t WHERE v >= ?", &.{.{ .int = base }}) catch return;
                defer rows.deinit();
                _ = rows.next() orelse return;
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*th, k| {
        th.* = try std.Thread.spawn(.{}, Worker.run, .{ &drv, @as(i64, @intCast(k)) * 1000 });
    }
    for (&threads) |*th| th.join();

    var rows = try drv.query("SELECT COUNT(*) FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try std.testing.expectEqual(@as(i64, 4 * 200), row.getInt(0).?);
}
