const std = @import("std");
const c = @cImport(@cInclude("sqlite3.h"));
const Value = @import("builder.zig").Value;
const Dialect = @import("dialect.zig").Dialect;
const driver = @import("driver.zig");

pub const SQLiteDriver = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !SQLiteDriver {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path.ptr, &db);
        if (rc != c.SQLITE_OK or db == null) {
            if (db) |handle| {
                const msg = c.sqlite3_errmsg(handle);
                std.log.err("sqlite open failed: {s}", .{msg});
                _ = c.sqlite3_close(handle);
            }
            return error.SqliteOpenFailed;
        }
        return SQLiteDriver{ .db = db.?, .allocator = allocator };
    }

    pub fn close(self: *SQLiteDriver) void {
        _ = c.sqlite3_close(self.db);
    }

    pub fn exec(self: *SQLiteDriver, sql: []const u8, args: []const Value) !driver.Result {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);
        try bindArgs(stmt.?, args);
        const step_rc = c.sqlite3_step(stmt.?);
        if (step_rc != c.SQLITE_DONE and step_rc != c.SQLITE_ROW) {
            return error.SqliteExecFailed;
        }
        return driver.Result{
            .rows_affected = @intCast(c.sqlite3_changes(self.db)),
            .last_insert_id = c.sqlite3_last_insert_rowid(self.db),
        };
    }

    pub fn query(self: *SQLiteDriver, query_sql: []const u8, args: []const Value) !driver.Rows {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, query_sql.ptr, @intCast(query_sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) {
            return error.SqlitePrepareFailed;
        }
        try bindArgs(stmt.?, args);

        const rows_ptr = try self.allocator.create(SQLiteRows);
        errdefer self.allocator.destroy(rows_ptr);
        rows_ptr.* = SQLiteRows{
            .stmt = stmt.?,
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
            .committed = false,
        };
        return driver.Tx{
            .inner = self.asDriver(),
            .commitFn = SQLiteTx.commit,
            .rollbackFn = SQLiteTx.rollback,
            .ptr = tx_ptr,
        };
    }

    pub fn asDriver(self: *SQLiteDriver) driver.Driver {
        return driver.Driver{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = driver.Driver.VTable{
        .exec = struct {
            fn f(ptr: *anyopaque, q: []const u8, a: []const Value) anyerror!driver.Result {
                const self_ptr: *SQLiteDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.exec(q, a);
            }
        }.f,
        .query = struct {
            fn f(ptr: *anyopaque, q: []const u8, a: []const Value) anyerror!driver.Rows {
                const self_ptr: *SQLiteDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.query(q, a);
            }
        }.f,
        .beginTx = struct {
            fn f(ptr: *anyopaque) anyerror!driver.Tx {
                const self_ptr: *SQLiteDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.beginTx();
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
    };
};

const SQLiteTx = struct {
    driver: *SQLiteDriver,
    committed: bool,

    fn commit(ptr: *anyopaque) !void {
        const self: *SQLiteTx = @ptrCast(@alignCast(ptr));
        if (self.committed) return;
        _ = try self.driver.exec("COMMIT", &.{});
        self.committed = true;
    }

    fn rollback(ptr: *anyopaque) !void {
        const self: *SQLiteTx = @ptrCast(@alignCast(ptr));
        if (self.committed) return;
        _ = try self.driver.exec("ROLLBACK", &.{});
        self.committed = true;
    }
};

const SQLiteRows = struct {
    stmt: *c.sqlite3_stmt,
    allocator: std.mem.Allocator,
    done: bool,

    const vtable = driver.Rows.VTable{
        .next = next,
        .deinit = deinit,
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
                _ = c.sqlite3_bind_text(stmt, idx, v.ptr, @intCast(v.len), c.SQLITE_TRANSIENT);
            },
            .bytes => |v| {
                _ = c.sqlite3_bind_blob(stmt, idx, v.ptr, @intCast(v.len), c.SQLITE_TRANSIENT);
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
    _ = try tx.exec("INSERT INTO t (id) VALUES (?)", &.{.{ .int = 42 }});
    try tx.commit();

    var rows = try drv.query("SELECT id FROM t", &.{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRow;
    try std.testing.expectEqual(@as(i64, 42), row.getInt(0).?);
}
