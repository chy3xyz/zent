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
        // `warn`, not `err`: a failed statement is the caller's to handle (a
        // constraint violation, a deadlock, an expected 4xx), and the caller already
        // receives the error. Error level would mean double-reporting into whatever
        // alerts on it — and, concretely, a test could not exercise a failure path at
        // all, because Zig's test runner treats a logged error as a test failure.
        // `connect` failures have been `warn` for the same reason.
        std.log.warn("SQLite error ({s}): {s}", .{ context, std.mem.span(msg) });
    }

    fn toDriverError(err: anyerror) driver.Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SqliteOpenFailed => error.ConnectionFailed,
            error.SqlitePrepareFailed => error.PrepareFailed,
            error.SqliteExecFailed => error.ExecFailed,
            error.SqliteBindFailed => error.BindFailed,
            error.SqliteParamCountMismatch => error.ParamCountMismatch,
            error.SqliteInterrupt => error.QueryTimeout,
            error.TxNotActive => error.TxFailed,
            error.QueryTimeout => error.QueryTimeout,
            error.LockTimeout => error.LockTimeout,
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
            // SQLITE_BUSY/LOCKED surface only after sqlite3_busy_timeout gives
            // up, so map them to the retryable lock-timeout classification.
            // Extended codes share the low byte; mask it off.
            const primary_rc = step_rc & 0xff;
            if (primary_rc == c.SQLITE_BUSY or primary_rc == c.SQLITE_LOCKED) return error.LockTimeout;
            if (step_rc == c.SQLITE_CONSTRAINT) return toDriverError(sqliteErrnoToDriver(self.db, error.ExecFailed));
            return error.SqliteExecFailed;
        }
        // A statement that stopped on SQLITE_ROW has not finished emitting rows,
        // and SQLite settles the counter only when the statement runs to
        // completion — so at this point it is still the previous DML's count.
        // (`exec` deliberately steps once, so this is not a rare shape: measured
        // with `INSERT ... VALUES (…) RETURNING id` stepped once, the row is
        // inserted and `sqlite3_changes` still says 0; the same statement
        // stepped to SQLITE_DONE says 1.)
        const counts_rows = step_rc == c.SQLITE_DONE and statementReportsRowCount(sql, stmt);
        return driver.Result{
            .rows_affected = if (counts_rows) @intCast(c.sqlite3_changes(self.db)) else 0,
            .last_insert_id = c.sqlite3_last_insert_rowid(self.db),
            .rows_affected_known = counts_rows,
        };
    }

    /// Whether `sqlite3_changes` holds *this* statement's row count.
    ///
    /// It answers for the most recent INSERT / UPDATE / DELETE that ran on the
    /// connection to completion, and nothing else resets it — so after anything
    /// else it still holds the previous DML's count and reporting it would
    /// answer a question about a different statement. (Measured: insert 3 rows,
    /// step a `SELECT` → `sqlite3_changes` still says 3.)
    ///
    /// Three conditions have to hold, because SQLite's own signal covers only
    /// part of the cases:
    ///
    ///   * the statement must have run to completion (`SQLITE_DONE`, checked by
    ///     the caller). A statement still emitting rows has not settled the
    ///     counter yet, which is why a `RETURNING` DML through `exec` — one step
    ///     only — has no count to report.
    ///   * `sqlite3_stmt_readonly` must be 0. A read-only statement cannot be
    ///     the DML the counter is about. Measured 1 for `SELECT`, `EXPLAIN`,
    ///     `VALUES`, `WITH ... SELECT`, a reading PRAGMA, `BEGIN`/`COMMIT`/
    ///     `SAVEPOINT`/`RELEASE` and `PRAGMA foreign_keys = ON`; measured 0 for
    ///     INSERT / UPDATE / DELETE (including the `... RETURNING` forms).
    ///   * the statement must not be one of the writable statements that are
    ///     not DML — see `writesWithoutReportingChanges`.
    fn statementReportsRowCount(sql: []const u8, stmt: *c.sqlite3_stmt) bool {
        return c.sqlite3_stmt_readonly(stmt) == 0 and !writesWithoutReportingChanges(sql);
    }

    /// The writable statements that are *not* INSERT / UPDATE / DELETE, and so
    /// never set `sqlite3_changes`.
    ///
    /// `sqlite3_stmt_readonly` reports 0 (not read-only) for every one of these,
    /// which is why the read-only check alone is not enough: a `CREATE INDEX`
    /// that runs right after an INSERT leaves the counter at that INSERT's count,
    /// and the driver used to hand that number back as the DDL's own.
    ///
    /// Every entry was measured on SQLite 3.x, after an INSERT that changed 3
    /// rows, and left the counter at 3: `CREATE`, `ALTER`, `DROP`, `ANALYZE`,
    /// `VACUUM`, `REINDEX` (the one entry in the list that reports *read-only* —
    /// kept because the keyword, not the report, is what makes it safe to list)
    /// and a writing PRAGMA. PRAGMA covers both forms deliberately: a reading
    /// PRAGMA is already caught by the read-only check, but not every reading
    /// form reports read-only (`PRAGMA journal_mode` does not), and no PRAGMA
    /// sets the counter either way.
    ///
    /// The list is a blacklist on purpose: an unrecognised statement keeps the
    /// count it had, so the change can only ever remove a number that was never
    /// this statement's. A statement whose first token is not a keyword — a
    /// leading comment, say — is therefore unrecognised and keeps the old
    /// answer; the driver's own DDL never looks like that, and reading past
    /// comments is not worth a SQL lexer here.
    fn writesWithoutReportingChanges(sql: []const u8) bool {
        const rest = std.mem.trimStart(u8, sql, " \t\n\r\x0b\x0c");
        const first_word = rest[0 .. std.mem.indexOfAny(u8, rest, " \t\n\r\x0b\x0c(") orelse rest.len];
        const not_dml = [_][]const u8{ "create", "alter", "drop", "analyze", "vacuum", "pragma", "reindex" };
        for (not_dml) |kw| {
            if (std.ascii.eqlIgnoreCase(first_word, kw)) return true;
        }
        return false;
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

    /// Prepare `sql` (and bind `args`) without ever stepping it: SQLite
    /// resolves tables and columns in `sqlite3_prepare_v2`, so this is where a
    /// broken statement is found — and no statement is executed either way.
    ///
    /// Not logged, unlike the exec path: a statement that fails to prepare is
    /// the expected outcome of a check, not a fault (the same reason the
    /// drivers keep `QueryTimeout` and constraint violations quiet). The text
    /// is handed to the caller in `out.message`.
    pub fn prepareCheck(self: *SQLiteDriver, allocator: std.mem.Allocator, sql: []const u8, args: []const Value, out: *driver.CheckReport) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, @ptrCast(sql.ptr), @intCast(sql.len), @ptrCast(&stmt), null);
        if (rc != c.SQLITE_OK or stmt == null) {
            const msg = std.mem.span(c.sqlite3_errmsg(self.db));
            out.* = .{
                .kind = .prepare_failed,
                .native_code = c.sqlite3_extended_errcode(self.db),
                .message = try allocator.dupe(u8, msg),
            };
            return;
        }
        defer _ = c.sqlite3_finalize(stmt);
        const prepared = stmt.?;

        // SQLite does not insist that every parameter is bound and ignores
        // bindings past the last one, so the count is compared here — where a
        // mismatch is still attributable to the caller.
        const n_params: usize = @intCast(c.sqlite3_bind_parameter_count(prepared));
        if (n_params != args.len) {
            out.* = .{ .kind = .param_mismatch, .param_count = n_params };
            return;
        }
        bindArgs(prepared, args) catch {};
        out.* = .{ .kind = .ok, .param_count = n_params };
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
        .prepareCheck = struct {
            fn f(ptr: *anyopaque, allocator: std.mem.Allocator, q: []const u8, a: []const Value, out: *driver.CheckReport) driver.Error!void {
                const self_ptr: *SQLiteDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.prepareCheck(allocator, q, a, out) catch |err| return toDriverError(err);
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
            const primary_rc = rc & 0xff;
            if (primary_rc == c.SQLITE_BUSY or primary_rc == c.SQLITE_LOCKED) {
                self.next_error = error.LockTimeout;
            } else if (primary_rc == c.SQLITE_CONSTRAINT) {
                // The extended code names the constraint; without a handle to
                // read it from the failure is still a failure.
                const db = c.sqlite3_db_handle(self.stmt) orelse {
                    self.next_error = error.ExecFailed;
                    return null;
                };
                self.next_error = sqliteErrnoToDriver(db, error.ExecFailed);
            } else {
                // Everything else — SQLITE_FULL, SQLITE_IOERR, SQLITE_MISMATCH,
                // SQLITE_TOOBIG, SQLITE_INTERRUPT — is a step failure too.
                // Leaving `next_error` null announced a clean end of results,
                // which is how a failed query came back as a short (or empty)
                // page for a caller that only checks `next()`.
                self.next_error = error.ExecFailed;
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
///
/// Public because the same lock has to guard anything else that fronts one
/// SQLite connection: a `Driver` wrapper that fans out to a shared handle, or
/// the prepared-statement cache when it is driven directly. Re-implementing it
/// at those sites is how two locks that must be the same become two locks.
pub const RecursiveMutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    owner: std.atomic.Value(std.Thread.Id) = .init(0),
    recursion: usize = 0,

    pub fn lock(self: *RecursiveMutex) void {
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

    pub fn unlock(self: *RecursiveMutex) void {
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

/// Bind `args` positionally to `stmt`, refusing both halves of a mismatch
/// instead of letting SQLite paper over them.
///
/// SQLite tolerates a wrong argument count in silence, and in both directions:
/// a binding past the last parameter only returns `SQLITE_RANGE` (the surplus
/// value disappears), and a parameter left unbound reads as NULL, so the
/// statement runs and answers a different question than the caller asked —
/// "the query returned nothing" months before anyone notices. Neither the
/// return codes nor the count were looked at before, so `error.ParamCountMismatch`
/// is new behavior for every caller of this driver.
///
/// The count rule is `sqlite3_bind_parameter_count(stmt) == args.len`, the same
/// one `prepareCheck` already applies to a statement it never executes — a
/// runtime path that disagreed with the diagnostic path would be worse than
/// either. What that number counts, and where the rule is only approximately
/// right:
///  - A repeated named parameter (`:x … :x`) is **one** slot, so `args.len`
///    counts it once too. Positional binding addresses slots in order of first
///    appearance; zent's builder emits only `?`, so named parameters here are a
///    compatibility path for raw SQL, not a claim that the driver resolves
///    names.
///  - An explicit index that leaves a gap reports the **highest** slot number:
///    `… WHERE a = ?5` alone answers 5, not 1. A positional list cannot address
///    slot 5 from position 1 anyway, so rejecting a 1-element list is the right
///    answer — but the error says "count mismatch" where "you used `?NNN`" would
///    be more precise. `?NNN` is not something the builder generates.
///  - A statement with no parameters (`bind_parameter_count == 0`) therefore
///    requires `args.len == 0` and is otherwise unaffected: DDL and argument-less
///    SELECTs pass exactly as before.
fn bindArgs(stmt: *c.sqlite3_stmt, args: []const Value) !void {
    if (c.sqlite3_bind_parameter_count(stmt) != @as(c_int, @intCast(args.len))) {
        return error.SqliteParamCountMismatch;
    }
    for (args, 0..) |arg, i| {
        const idx: c_int = @intCast(i + 1);
        const rc = switch (arg) {
            .null => c.sqlite3_bind_null(stmt, idx),
            .bool => |v| c.sqlite3_bind_int64(stmt, idx, if (v) 1 else 0),
            .int => |v| c.sqlite3_bind_int64(stmt, idx, v),
            .float => |v| c.sqlite3_bind_double(stmt, idx, v),
            .string => |v| c.sqlite3_bind_text(stmt, idx, v.ptr, @intCast(v.len), null),
            .bytes => |v| c.sqlite3_bind_blob(stmt, idx, v.ptr, @intCast(v.len), null),
        };
        if (rc != c.SQLITE_OK) {
            // `SQLITE_RANGE` cannot reach here (the count was just compared), so
            // what is left is a binding that genuinely failed — `SQLITE_NOMEM`,
            // or a value SQLite refuses to store.
            if (c.sqlite3_db_handle(stmt)) |db| SQLiteDriver.logSqliteError(db, "bind");
            return error.SqliteBindFailed;
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

test "SQLite refuses a binding list the statement's parameter count does not fit" {
    const allocator = std.testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    const d = drv.asDriver();

    _ = try d.exec("CREATE TABLE t (a INTEGER, b INTEGER)", &.{});
    _ = try d.exec("INSERT INTO t (a, b) VALUES (?, ?)", &.{ .{ .int = 1 }, .{ .int = 2 } });

    // Too few: SQLite reads the missing parameter as NULL, so this used to run
    // and insert (3, NULL) rather than report anything.
    try std.testing.expectError(
        error.ParamCountMismatch,
        d.exec("INSERT INTO t (a, b) VALUES (?, ?)", &.{.{ .int = 3 }}),
    );
    // Too many: SQLITE_RANGE was discarded, so the surplus value vanished.
    try std.testing.expectError(
        error.ParamCountMismatch,
        d.exec("INSERT INTO t (a, b) VALUES (?, ?)", &.{ .{ .int = 3 }, .{ .int = 4 }, .{ .int = 5 } }),
    );
    // The query path is the one that used to answer a different question
    // quietly (no rows) instead of failing.
    try std.testing.expectError(
        error.ParamCountMismatch,
        d.query("SELECT a FROM t WHERE a = ? AND b = ?", &.{.{ .int = 1 }}),
    );
    // The direct (vtable-free) entry point refuses it as well; it reports the
    // driver's own error name, the way SqlitePrepareFailed does.
    try std.testing.expectError(
        error.SqliteParamCountMismatch,
        drv.query("SELECT a FROM t WHERE a = ? AND b = ?", &.{.{ .int = 1 }}),
    );

    // Neither rejected INSERT wrote anything.
    var rows = try d.query("SELECT COUNT(*) FROM t", &.{});
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 1), rows.next().?.getInt(0).?);
}

test "SQLite statements that take no parameters still run with no bindings" {
    const allocator = std.testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    const d = drv.asDriver();

    // DDL and an argument-free SELECT both report 0 parameters, and 0 bindings
    // has to stay the normal case for them.
    _ = try d.exec("CREATE TABLE t (a INTEGER)", &.{});
    _ = try d.exec("INSERT INTO t (a) VALUES (1)", &.{});
    var rows = try d.query("SELECT a FROM t", &.{});
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 1), rows.next().?.getInt(0).?);
    try std.testing.expect(rows.next() == null);

    // A parameterless statement is a 0 == args.len comparison like any other,
    // so a binding it cannot use is refused rather than dropped.
    try std.testing.expectError(
        error.ParamCountMismatch,
        d.exec("INSERT INTO t (a) VALUES (1)", &.{.{ .int = 9 }}),
    );
    var count = try d.query("SELECT COUNT(*) FROM t", &.{});
    defer count.deinit();
    try std.testing.expectEqual(@as(i64, 1), count.next().?.getInt(0).?);
}

test "SQLite counts a repeated name once and a gapped ?NNN by its number" {
    const allocator = std.testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    const d = drv.asDriver();

    _ = try d.exec("CREATE TABLE t (a INTEGER, b INTEGER)", &.{});
    _ = try d.exec("INSERT INTO t (a, b) VALUES (?, ?)", &.{ .{ .int = 1 }, .{ .int = 1 } });

    // `:x` twice is one slot, so one positional binding is right — and is what
    // sqlite3_bind_parameter_count reports.
    var named = try d.query("SELECT a FROM t WHERE a = :x AND b = :x", &.{.{ .int = 1 }});
    defer named.deinit();
    try std.testing.expectEqual(@as(i64, 1), named.next().?.getInt(0).?);
    try std.testing.expect(named.next() == null);

    // `?5` alone is slot 5, so a one-element list is refused: position 1 is not
    // the slot the statement reads. The comparison can only say the list does
    // not fit, not that `?NNN` was used.
    try std.testing.expectError(
        error.ParamCountMismatch,
        d.query("SELECT a FROM t WHERE a = ?5", &.{.{ .int = 1 }}),
    );
    // Five bindings do fit; slots 1-4 go unused and slot 5 carries the value.
    var gapped = try d.query("SELECT a FROM t WHERE a = ?5", &.{
        .{ .int = 0 }, .{ .int = 0 }, .{ .int = 0 }, .{ .int = 0 }, .{ .int = 1 },
    });
    defer gapped.deinit();
    try std.testing.expectEqual(@as(i64, 1), gapped.next().?.getInt(0).?);
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

test "SQLite busy/locked errors classify as retryable LockTimeout" {
    try std.testing.expectEqual(driver.Error.LockTimeout, SQLiteDriver.toDriverError(error.LockTimeout));
    try std.testing.expect(driver.isRetryable(SQLiteDriver.toDriverError(error.LockTimeout)));
}

test "SQLite: a step failure that is not a lock or a constraint is not read as end-of-rows" {
    // SQLITE_FULL — the one step failure reachable on demand — stands in for
    // every non-lock, non-constraint step error (IOERR, MISMATCH, TOOBIG,
    // INTERRUPT). `next()` answers "no rows" for all of them either way, so a
    // dropped error is indistinguishable from a result set that ended: the
    // caller sees a short page (or `error.NotFound`) instead of a failure.
    const allocator = std.testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    const d = drv.asDriver();

    _ = try d.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB)", &.{});
    // A page ceiling that cannot hold the row below, so sqlite3_step itself
    // gives up rather than a constraint or the busy handler.
    _ = try d.exec("PRAGMA max_page_count = 2", &.{});

    var rows = try d.query("INSERT INTO t (v) VALUES (randomblob(200000))", &.{});
    defer rows.deinit();
    try std.testing.expect(rows.next() == null);
    try std.testing.expectEqual(@as(?driver.Error, error.ExecFailed), rows.nextError());
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

test "SQLite: a non-DML statement does not report the previous DML's row count" {
    const allocator = std.testing.allocator;
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    const d = drv.asDriver();

    _ = try d.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)", &.{});
    const inserted = try d.exec("INSERT INTO t VALUES (1,'a'),(2,'b'),(3,'c')", &.{});
    try std.testing.expectEqual(@as(usize, 3), inserted.rows_affected);
    try std.testing.expect(inserted.rows_affected_known);

    // `sqlite3_changes` still answers 3 for every statement below — the count of
    // the INSERT above. None of them is that INSERT, so none may report its
    // count. The three conditions of the criterion each have a witness here:
    // a SELECT is read-only, a DDL is not read-only but is not DML either, and
    // the statement below that returns no row runs to completion.
    const selected = try d.exec("SELECT * FROM t", &.{});
    try std.testing.expectEqual(@as(usize, 0), selected.rows_affected);
    try std.testing.expect(!selected.rows_affected_known);

    // An empty result set is the shape a SELECT shares with a DML: it steps
    // straight to SQLITE_DONE, so "the statement finished" is not enough to say
    // the count is its own, and only the read-only check separates it from an
    // UPDATE that matched nothing.
    const selected_none = try d.exec("SELECT * FROM t WHERE id = 999", &.{});
    try std.testing.expectEqual(@as(usize, 0), selected_none.rows_affected);
    try std.testing.expect(!selected_none.rows_affected_known);

    // The trap `sqlite3_stmt_readonly` alone does not catch: DDL is not
    // read-only and still reports no count of its own.
    const ddl = try d.exec("CREATE INDEX idx_t_v ON t(v)", &.{});
    try std.testing.expectEqual(@as(usize, 0), ddl.rows_affected);
    try std.testing.expect(!ddl.rows_affected_known);

    // Neither a PRAGMA — `journal_mode` is a *reading* form that SQLite
    // nevertheless reports as not read-only.
    try std.testing.expect(!(try d.exec("PRAGMA user_version = 7", &.{})).rows_affected_known);
    try std.testing.expect(!(try d.exec("PRAGMA journal_mode", &.{})).rows_affected_known);

    // Nor transaction control.
    try std.testing.expect(!(try d.exec("BEGIN", &.{})).rows_affected_known);
    try std.testing.expect(!(try d.exec("COMMIT", &.{})).rows_affected_known);

    // DML keeps its count — including the zero an UPDATE that matched nothing
    // reports, which is the value the optimistic-lock check compares against.
    const updated = try d.exec("UPDATE t SET v = 'z' WHERE id = 1", &.{});
    try std.testing.expectEqual(@as(usize, 1), updated.rows_affected);
    try std.testing.expect(updated.rows_affected_known);

    const matched_none = try d.exec("UPDATE t SET v = 'z' WHERE id = 999", &.{});
    try std.testing.expectEqual(@as(usize, 0), matched_none.rows_affected);
    try std.testing.expect(matched_none.rows_affected_known);

    const deleted_none = try d.exec("DELETE FROM t WHERE id = 999", &.{});
    try std.testing.expectEqual(@as(usize, 0), deleted_none.rows_affected);
    try std.testing.expect(deleted_none.rows_affected_known);

    // `RETURNING` is a DML whose count `exec` cannot have: it stops on the first
    // returned row, and SQLite settles the counter only at completion. Measured:
    // the row really is inserted and `sqlite3_changes` still holds the previous
    // DML's value, so reporting it — as a count, with the flag set — would assert
    // a number from a different statement. The `INSERT` itself still runs.
    const returning = try d.exec("INSERT INTO t VALUES (9,'q') RETURNING id", &.{});
    try std.testing.expectEqual(@as(usize, 0), returning.rows_affected);
    try std.testing.expect(!returning.rows_affected_known);
    var count_rows = try d.query("SELECT count(*) FROM t WHERE id = 9", &.{});
    defer count_rows.deinit();
    const only = count_rows.next() orelse return error.NoRow;
    try std.testing.expectEqual(@as(i64, 1), only.getInt(0).?);
}

test "SQLite: the statements whose count sqlite3_changes does not report" {
    // The keyword half of the criterion, pinned on its own because it is what
    // covers the statements `sqlite3_stmt_readonly` calls writable but whose
    // count the counter never holds.
    for ([_][]const u8{
        "CREATE TABLE t (id INTEGER)",
        "create table t (id INTEGER)",
        "  \n\tCREATE INDEX i ON t(id)",
        "ALTER TABLE t ADD COLUMN v TEXT",
        "DROP TABLE t",
        "ANALYZE",
        "VACUUM",
        "REINDEX",
        "PRAGMA user_version = 7",
        "PRAGMA journal_mode",
    }) |sql| {
        try std.testing.expect(SQLiteDriver.writesWithoutReportingChanges(sql));
    }

    // The DML side must not be caught by the keyword check — a false positive
    // here would drop a count the driver really does have, and an UPDATE that
    // matched nothing is exactly the value the optimistic lock reads.
    for ([_][]const u8{
        "INSERT INTO t VALUES (1)",
        "insert into t values (1)",
        "INSERT OR REPLACE INTO t VALUES (1)",
        "REPLACE INTO t VALUES (1)",
        "UPDATE t SET v = 1",
        "DELETE FROM t WHERE id = 1",
        "INSERT INTO t VALUES (1) RETURNING id",
        "WITH x AS (SELECT 1) SELECT * FROM x",
        "SELECT 1",
    }) |sql| {
        try std.testing.expect(!SQLiteDriver.writesWithoutReportingChanges(sql));
    }
}
