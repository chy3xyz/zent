const std = @import("std");
const c = @import("sqlite3_c");
const Value = @import("builder.zig").Value;
const Dialect = @import("dialect.zig").Dialect;
const driver = @import("driver.zig");
const cache = @import("cache.zig");

pub const SQLiteDriver = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,
    /// Optional prepared-statement cache. Set this field after `open()` to
    /// enable caching; null (the default) disables it.
    cache: ?cache.PreparedCache(16, *c.sqlite3_stmt) = null,

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
        _ = c.sqlite3_busy_timeout(db.?, 5000);
        return SQLiteDriver{ .db = db.?, .allocator = allocator };
    }

    pub fn close(self: *SQLiteDriver) void {
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
            error.TxNotActive => error.TxFailed,
            else => error.DriverFailed,
        };
    }

    pub fn exec(self: *SQLiteDriver, sql: []const u8, args: []const Value) !driver.Result {
        // DDL invalidates cached prepared statements.
        if (self.cache) |*cached| {
            if (cache.isDDL(sql)) {
                cached.evictAll({}, finalizeStmt);
            }
        }

        const stmt = if (self.cache) |*cached|
            try cached.getOrPrepare(sql, self.db, prepareStmt, {}, finalizeStmt)
        else blk: {
            var out: ?*c.sqlite3_stmt = null;
            const rc = c.sqlite3_prepare_v2(self.db, @ptrCast(sql.ptr), @intCast(sql.len), @ptrCast(&out), null);
            if (rc != c.SQLITE_OK or out == null) {
                logSqliteError(self.db, "prepare");
                return error.SqlitePrepareFailed;
            }
            break :blk out.?;
        };

        // Reset before rebinding (needed when stmt came from cache).
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);
        try bindArgs(stmt, args);
        const step_rc = c.sqlite3_step(stmt);
        if (step_rc != c.SQLITE_DONE and step_rc != c.SQLITE_ROW) {
            logSqliteError(self.db, "exec");
            return error.SqliteExecFailed;
        }
        return driver.Result{
            .rows_affected = @intCast(c.sqlite3_changes(self.db)),
            .last_insert_id = c.sqlite3_last_insert_rowid(self.db),
        };
    }

    pub fn query(self: *SQLiteDriver, query_sql: []const u8, args: []const Value) !driver.Rows {
        const stmt = if (self.cache) |*cached|
            try cached.takeOrPrepare(query_sql, self.db, prepareStmtQuery)
        else blk: {
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
        };

        return driver.Rows{
            .ptr = rows_ptr,
            .vtable = &SQLiteRows.vtable,
        };
    }

    pub fn beginTx(self: *SQLiteDriver) !driver.Tx {
        _ = try self.exec("BEGIN", &.{});
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
            .ptr = tx_ptr,
        };
    }

    pub fn ping(self: *SQLiteDriver) !void {
        _ = try self.exec("SELECT 1", &.{});
    }

    /// Returns true if a transaction is currently active on this connection.
    /// SQLite is in autocommit mode when not inside an explicit transaction.
    pub fn inTransaction(self: *SQLiteDriver) bool {
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
            fn f(ptr: *anyopaque, q: []const u8, a: []const Value) driver.Error!driver.Result {
                const self_ptr: *SQLiteDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.exec(q, a) catch |err| return toDriverError(err);
            }
        }.f,
        .query = struct {
            fn f(ptr: *anyopaque, q: []const u8, a: []const Value) driver.Error!driver.Rows {
                const self_ptr: *SQLiteDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.query(q, a) catch |err| return toDriverError(err);
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
    };
};

const SQLiteTx = struct {
    driver: *SQLiteDriver,
    state: enum { active, committed, rolled_back },

    fn commit(self: *SQLiteTx) !void {
        if (self.state != .active) return error.TxNotActive;
        _ = try self.driver.exec("COMMIT", &.{});
        self.state = .committed;
    }

    fn rollback(self: *SQLiteTx) !void {
        if (self.state != .active) return;
        // Best-effort; ignore failure (driver may have already closed).
        _ = self.driver.exec("ROLLBACK", &.{}) catch {};
        self.state = .rolled_back;
    }

    fn deinit(self: *SQLiteTx) void {
        if (self.state == .active) {
            std.log.warn("sqlite tx deinit without commit/rollback; rolling back", .{});
            _ = self.driver.exec("ROLLBACK", &.{}) catch {};
        }
        self.driver.allocator.destroy(self);
    }
};

const SQLiteRows = struct {
    stmt: *c.sqlite3_stmt,
    allocator: std.mem.Allocator,
    done: bool,

    const vtable = driver.Rows.VTable{
        .next = next,
        .deinit = deinit,
        .nextError = null,
    };

    fn next(ptr: *anyopaque) ?driver.Row {
        const self: *SQLiteRows = @ptrCast(@alignCast(ptr));
        if (self.done) return null;
        const rc = c.sqlite3_step(self.stmt);
        if (rc == c.SQLITE_DONE) {
            self.done = true;
            return null;
        }
        if (rc != c.SQLITE_ROW) {
            self.done = true;
            return null;
        }
        return driver.Row{
            .ptr = self,
            .vtable = &row_vtable,
        };
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *SQLiteRows = @ptrCast(@alignCast(ptr));
        _ = c.sqlite3_finalize(self.stmt);
        const alloc = self.allocator;
        alloc.destroy(self);
    }

    const row_vtable = driver.Row.VTable{
        .columnCount = columnCount,
        .columnName = columnName,
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
