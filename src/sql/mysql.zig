const std = @import("std");
const c = @cImport({
    @cDefine("MYSQL_NO_DATA", "1");
    @cInclude("mariadb/mysql.h");
});
const Value = @import("builder.zig").Value;
const Dialect = @import("dialect.zig").Dialect;
const driver = @import("driver.zig");

pub const MySQLDriver = struct {
    conn: *c.MYSQL,
    allocator: std.mem.Allocator,

    pub fn connect(allocator: std.mem.Allocator, host: [:0]const u8, port: u32, user: [:0]const u8, passwd: [:0]const u8, dbname: [:0]const u8) !MySQLDriver {
        const conn = c.mysql_init(null);
        if (conn == null) return error.MySQLInitFailed;

        const ret = c.mysql_real_connect(conn, host.ptr, user.ptr, passwd.ptr, dbname.ptr, @intCast(port), null, 0);
        if (ret == null) {
            defer c.mysql_close(conn);
            const msg = c.mysql_error(conn);
            std.log.err("mysql connect failed: {s}", .{std.mem.span(msg)});
            return error.MySQLConnectFailed;
        }

        // Set UTF-8
        _ = c.mysql_set_character_set(conn, "utf8mb4");

        return MySQLDriver{ .conn = conn, .allocator = allocator };
    }

    pub fn close(self: *MySQLDriver) void {
        c.mysql_close(self.conn);
    }

    fn logMySQLError(conn: *c.MYSQL, context: []const u8) void {
        const msg = c.mysql_error(conn);
        std.log.err("mysql error ({s}): {s}", .{ context, std.mem.span(msg) });
    }

    pub fn exec(self: *MySQLDriver, sql: []const u8, args: []const Value) !driver.Result {
        if (args.len == 0) {
            // Simple query without parameters
            const sql_z = try self.allocator.dupeZ(u8, sql);
            defer self.allocator.free(sql_z);

            if (c.mysql_real_query(self.conn, sql_z.ptr, @intCast(sql_z.len)) != 0) {
                logMySQLError(self.conn, "exec");
                return error.MySQLExecFailed;
            }

            return driver.Result{
                .rows_affected = @intCast(c.mysql_affected_rows(self.conn)),
                .last_insert_id = @intCast(c.mysql_insert_id(self.conn)),
            };
        }

        // Use prepared statement for parameterized query
        const stmt = c.mysql_stmt_init(self.conn);
        if (stmt == null) {
            logMySQLError(self.conn, "stmt_init");
            return error.MySQLStmtFailed;
        }
        defer _ = c.mysql_stmt_close(stmt);

        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        if (c.mysql_stmt_prepare(stmt, sql_z.ptr, @intCast(sql_z.len)) != 0) {
            logMySQLError(self.conn, "stmt_prepare");
            return error.MySQLStmtFailed;
        }

        // Bind parameters
        const n_params = c.mysql_stmt_param_count(stmt);
        if (n_params != args.len) {
            std.log.err("mysql: expected {d} params, got {d}", .{ n_params, args.len });
            return error.MySQLParamCountMismatch;
        }

        var binds = try self.allocator.alloc(c.MYSQL_BIND, @intCast(n_params));
        defer self.allocator.free(binds);

        // Storage for string/blob data to keep alive during execute
        var str_data = std.ArrayListUnmanaged([]const u8){};
        defer {
            for (str_data.items) |s| {
                self.allocator.free(s);
            }
            str_data.deinit(self.allocator);
        }

        // Storage for integer/float buffers to keep alive during execute
        var int_bufs = std.ArrayListUnmanaged(i64){};
        var float_bufs = std.ArrayListUnmanaged(f64){};
        defer {
            int_bufs.deinit(self.allocator);
            float_bufs.deinit(self.allocator);
        }

        try int_bufs.resize(self.allocator, args.len);
        try float_bufs.resize(self.allocator, args.len);
        @memset(binds, std.mem.zeroes(c.MYSQL_BIND));

        for (args, 0..) |arg, i| {
            switch (arg) {
                .null => {
                    binds[i].buffer_type = c.MYSQL_TYPE_NULL;
                    binds[i].is_null = @ptrCast(&std.mem.zeroes(c.my_bool));
                },
                .bool => |v| {
                    binds[i].buffer_type = c.MYSQL_TYPE_TINY;
                    const buf = try self.allocator.create(i8);
                    buf.* = if (v) 1 else 0;
                    binds[i].buffer = buf;
                    binds[i].is_null = @ptrCast(&std.mem.zeroes(c.my_bool));
                    _ = &buf;
                },
                .int => |v| {
                    binds[i].buffer_type = c.MYSQL_TYPE_LONGLONG;
                    int_bufs.items[i] = v;
                    binds[i].buffer = &int_bufs.items[i];
                    binds[i].is_null = @ptrCast(&std.mem.zeroes(c.my_bool));
                },
                .float => |v| {
                    binds[i].buffer_type = c.MYSQL_TYPE_DOUBLE;
                    float_bufs.items[i] = v;
                    binds[i].buffer = &float_bufs.items[i];
                    binds[i].is_null = @ptrCast(&std.mem.zeroes(c.my_bool));
                },
                .string => |v| {
                    binds[i].buffer_type = c.MYSQL_TYPE_STRING;
                    const dup = try self.allocator.dupe(u8, v);
                    try str_data.append(self.allocator, dup);
                    binds[i].buffer = dup.ptr;
                    binds[i].buffer_length = @intCast(dup.len);
                    binds[i].is_null = @ptrCast(&std.mem.zeroes(c.my_bool));
                },
                .bytes => |v| {
                    binds[i].buffer_type = c.MYSQL_TYPE_BLOB;
                    const dup = try self.allocator.dupe(u8, v);
                    try str_data.append(self.allocator, dup);
                    binds[i].buffer = dup.ptr;
                    binds[i].buffer_length = @intCast(dup.len);
                    binds[i].is_null = @ptrCast(&std.mem.zeroes(c.my_bool));
                },
            }
        }

        if (c.mysql_stmt_bind_param(stmt, binds.ptr) != 0) {
            logMySQLError(self.conn, "stmt_bind_param");
            return error.MySQLStmtFailed;
        }

        if (c.mysql_stmt_execute(stmt) != 0) {
            logMySQLError(self.conn, "stmt_execute");
            return error.MySQLStmtFailed;
        }

        return driver.Result{
            .rows_affected = @intCast(c.mysql_stmt_affected_rows(stmt)),
            .last_insert_id = @intCast(c.mysql_stmt_insert_id(stmt)),
        };
    }

    pub fn query(self: *MySQLDriver, query_sql: []const u8, args: []const Value) !driver.Rows {
        const stmt = c.mysql_stmt_init(self.conn);
        if (stmt == null) {
            logMySQLError(self.conn, "stmt_init");
            return error.MySQLStmtFailed;
        }
        errdefer _ = c.mysql_stmt_close(stmt);

        const sql_z = try self.allocator.dupeZ(u8, query_sql);
        defer self.allocator.free(sql_z);

        if (c.mysql_stmt_prepare(stmt, sql_z.ptr, @intCast(sql_z.len)) != 0) {
            logMySQLError(self.conn, "stmt_prepare");
            return error.MySQLStmtFailed;
        }

        // Bind parameters
        const n_params = c.mysql_stmt_param_count(stmt);
        if (n_params != args.len) {
            std.log.err("mysql: expected {d} params, got {d}", .{ n_params, args.len });
            return error.MySQLParamCountMismatch;
        }

        var binds = try self.allocator.alloc(c.MYSQL_BIND, @intCast(n_params));
        errdefer self.allocator.free(binds);

        var str_data = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (str_data.items) |s| {
                self.allocator.free(s);
            }
            str_data.deinit(self.allocator);
        }

        var int_bufs = std.ArrayListUnmanaged(i64){};
        var float_bufs = std.ArrayListUnmanaged(f64){};
        errdefer {
            int_bufs.deinit(self.allocator);
            float_bufs.deinit(self.allocator);
        }

        try int_bufs.resize(self.allocator, args.len);
        try float_bufs.resize(self.allocator, args.len);
        @memset(binds, std.mem.zeroes(c.MYSQL_BIND));

        for (args, 0..) |arg, i| {
            switch (arg) {
                .null => {
                    binds[i].buffer_type = c.MYSQL_TYPE_NULL;
                    binds[i].is_null = @ptrCast(&std.mem.zeroes(c.my_bool));
                },
                .bool => |v| {
                    binds[i].buffer_type = c.MYSQL_TYPE_TINY;
                    const buf = try self.allocator.create(i8);
                    buf.* = if (v) 1 else 0;
                    binds[i].buffer = buf;
                    binds[i].is_null = @ptrCast(&std.mem.zeroes(c.my_bool));
                },
                .int => |v| {
                    binds[i].buffer_type = c.MYSQL_TYPE_LONGLONG;
                    int_bufs.items[i] = v;
                    binds[i].buffer = &int_bufs.items[i];
                    binds[i].is_null = @ptrCast(&std.mem.zeroes(c.my_bool));
                },
                .float => |v| {
                    binds[i].buffer_type = c.MYSQL_TYPE_DOUBLE;
                    float_bufs.items[i] = v;
                    binds[i].buffer = &float_bufs.items[i];
                    binds[i].is_null = @ptrCast(&std.mem.zeroes(c.my_bool));
                },
                .string => |v| {
                    binds[i].buffer_type = c.MYSQL_TYPE_STRING;
                    const dup = try self.allocator.dupe(u8, v);
                    try str_data.append(self.allocator, dup);
                    binds[i].buffer = dup.ptr;
                    binds[i].buffer_length = @intCast(dup.len);
                    binds[i].is_null = @ptrCast(&std.mem.zeroes(c.my_bool));
                },
                .bytes => |v| {
                    binds[i].buffer_type = c.MYSQL_TYPE_BLOB;
                    const dup = try self.allocator.dupe(u8, v);
                    try str_data.append(self.allocator, dup);
                    binds[i].buffer = dup.ptr;
                    binds[i].buffer_length = @intCast(dup.len);
                    binds[i].is_null = @ptrCast(&std.mem.zeroes(c.my_bool));
                },
            }
        }

        if (c.mysql_stmt_bind_param(stmt, binds.ptr) != 0) {
            logMySQLError(self.conn, "stmt_bind_param");
            return error.MySQLStmtFailed;
        }

        if (c.mysql_stmt_execute(stmt) != 0) {
            logMySQLError(self.conn, "stmt_execute");
            return error.MySQLStmtFailed;
        }

        // Get result metadata
        const metadata = c.mysql_stmt_result_metadata(stmt);
        if (metadata == null) {
            // Not a result set (e.g. INSERT/UPDATE)
            return error.MySQLNotAQuery;
        }
        errdefer c.mysql_free_result(metadata);

        const num_fields = c.mysql_num_fields(metadata);
        const fields = c.mysql_fetch_fields(metadata);

        // Store result on client side
        if (c.mysql_stmt_store_result(stmt) != 0) {
            logMySQLError(self.conn, "stmt_store_result");
            return error.MySQLStmtFailed;
        }

        const rows_ptr = try self.allocator.create(MySQLRows);
        errdefer self.allocator.destroy(rows_ptr);
        rows_ptr.* = MySQLRows{
            .stmt = stmt,
            .metadata = metadata,
            .fields = fields,
            .num_fields = @intCast(num_fields),
            .allocator = self.allocator,
            .done = false,
        };

        return driver.Rows{
            .ptr = rows_ptr,
            .vtable = &MySQLRows.vtable,
        };
    }

    pub fn beginTx(self: *MySQLDriver) !driver.Tx {
        // MySQL autocommit is on by default, so BEGIN disables it within the tx
        _ = try self.exec("BEGIN", &.{});

        const tx_ptr = try self.allocator.create(MySQLTx);
        errdefer self.allocator.destroy(tx_ptr);
        tx_ptr.* = MySQLTx{
            .driver = self,
            .committed = false,
        };

        return driver.Tx{
            .inner = self.asDriver(),
            .commitFn = MySQLTx.commit,
            .rollbackFn = MySQLTx.rollback,
            .ptr = tx_ptr,
        };
    }

    pub fn asDriver(self: *MySQLDriver) driver.Driver {
        return driver.Driver{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = driver.Driver.VTable{
        .exec = struct {
            fn f(ptr: *anyopaque, q: []const u8, a: []const Value) anyerror!driver.Result {
                const self_ptr: *MySQLDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.exec(q, a);
            }
        }.f,
        .query = struct {
            fn f(ptr: *anyopaque, q: []const u8, a: []const Value) anyerror!driver.Rows {
                const self_ptr: *MySQLDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.query(q, a);
            }
        }.f,
        .beginTx = struct {
            fn f(ptr: *anyopaque) anyerror!driver.Tx {
                const self_ptr: *MySQLDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.beginTx();
            }
        }.f,
        .close = struct {
            fn f(ptr: *anyopaque) void {
                const self_ptr: *MySQLDriver = @ptrCast(@alignCast(ptr));
                self_ptr.close();
            }
        }.f,
        .dialect = struct {
            fn f(_: *anyopaque) Dialect {
                return Dialect.mysql;
            }
        }.f,
    };
};

const MySQLTx = struct {
    driver: *MySQLDriver,
    committed: bool,

    fn commit(ptr: *anyopaque) !void {
        const self: *MySQLTx = @ptrCast(@alignCast(ptr));
        if (self.committed) return;
        defer self.driver.allocator.destroy(self);
        _ = try self.driver.exec("COMMIT", &.{});
        self.committed = true;
    }

    fn rollback(ptr: *anyopaque) !void {
        const self: *MySQLTx = @ptrCast(@alignCast(ptr));
        if (self.committed) return;
        defer self.driver.allocator.destroy(self);
        _ = try self.driver.exec("ROLLBACK", &.{});
        self.committed = true;
    }
};

const MySQLRows = struct {
    stmt: *c.MYSQL_STMT,
    metadata: *c.MYSQL_RES,
    fields: [*c]c.MYSQL_FIELD,
    num_fields: usize,
    allocator: std.mem.Allocator,
    done: bool,

    // Per-row buffer
    row_bind: ?[]c.MYSQL_BIND = null,
    string_buffers: ?std.ArrayListUnmanaged([]u8) = null,
    int_buffers: ?std.ArrayListUnmanaged(i64) = null,
    float_buffers: ?std.ArrayListUnmanaged(f64) = null,
    null_indicators: ?std.ArrayListUnmanaged(c.my_bool) = null,
    lengths: ?std.ArrayListUnmanaged(c_ulong) = null,

    const vtable = driver.Rows.VTable{
        .next = next,
        .deinit = deinit,
    };

    fn ensureBuffers(self: *MySQLRows) !void {
        if (self.row_bind != null) return;

        const n = self.num_fields;
        var binds = try self.allocator.alloc(c.MYSQL_BIND, n);
        errdefer self.allocator.free(binds);

        var str_bufs = std.ArrayListUnmanaged([]u8){};
        var int_bufs = std.ArrayListUnmanaged(i64){};
        var float_bufs = std.ArrayListUnmanaged(f64){};
        var nulls = std.ArrayListUnmanaged(c.my_bool){};
        var lens = std.ArrayListUnmanaged(c_ulong){};

        try str_bufs.resize(self.allocator, n);
        try int_bufs.resize(self.allocator, n);
        try float_bufs.resize(self.allocator, n);
        try nulls.resize(self.allocator, n);
        try lens.resize(self.allocator, n);

        @memset(binds, std.mem.zeroes(c.MYSQL_BIND));

        for (0..n) |i| {
            const field = &self.fields[i];
            _ = field;

            // We allocate per-row buffers for each column
            // For simplicity, use string-based fetching for all types
            // then parse in getInt/getFloat/getText
            const buf_len: usize = 256;
            const buf = try self.allocator.alloc(u8, buf_len);
            str_bufs.items[i] = buf;

            binds[i].buffer_type = c.MYSQL_TYPE_STRING;
            binds[i].buffer = buf.ptr;
            binds[i].buffer_length = @intCast(buf_len);
            binds[i].is_null = &nulls.items[i];
            binds[i].length = &lens.items[i];
            binds[i].@"error" = &std.mem.zeroes(c.my_bool);
        }

        if (c.mysql_stmt_bind_result(self.stmt, binds.ptr) != 0) {
            self.allocator.free(binds);
            str_bufs.deinit(self.allocator);
            int_bufs.deinit(self.allocator);
            float_bufs.deinit(self.allocator);
            nulls.deinit(self.allocator);
            lens.deinit(self.allocator);
            return error.MySQLBindResultFailed;
        }

        self.row_bind = binds;
        self.string_buffers = str_bufs;
        self.int_buffers = int_bufs;
        self.float_buffers = float_bufs;
        self.null_indicators = nulls;
        self.lengths = lens;
    }

    fn next(ptr: *anyopaque) ?driver.Row {
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        if (self.done) return null;

        self.ensureBuffers() catch {
            self.done = true;
            return null;
        };

        const rc = c.mysql_stmt_fetch(self.stmt);
        if (rc == c.MYSQL_NO_DATA) {
            self.done = true;
            return null;
        }
        if (rc != 0) {
            self.done = true;
            return null;
        }

        return driver.Row{
            .ptr = self,
            .vtable = &row_vtable,
        };
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        c.mysql_free_result(self.metadata);
        _ = c.mysql_stmt_free_result(self.stmt);
        _ = c.mysql_stmt_close(self.stmt);

        if (self.row_bind) |binds| {
            self.allocator.free(binds);
        }
        if (self.string_buffers) |sb| {
            for (sb.items) |s| {
                self.allocator.free(s);
            }
            sb.deinit(self.allocator);
        }
        if (self.int_buffers) |ib| {
            ib.deinit(self.allocator);
        }
        if (self.float_buffers) |fb| {
            fb.deinit(self.allocator);
        }
        if (self.null_indicators) |ni| {
            ni.deinit(self.allocator);
        }
        if (self.lengths) |l| {
            l.deinit(self.allocator);
        }

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
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        return self.num_fields;
    }

    fn columnName(ptr: *anyopaque, index: usize) []const u8 {
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        return std.mem.span(self.fields[@intCast(index)].name);
    }

    fn getInt(ptr: *anyopaque, index: usize) ?i64 {
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        const binds = self.row_bind orelse return null;
        if (binds[index].is_null.* != 0) return null;
        const sb = self.string_buffers.?;
        const len = self.lengths.?;
        const text = sb.items[index][0..len.items[index]];
        return std.fmt.parseInt(i64, text, 10) catch null;
    }

    fn getFloat(ptr: *anyopaque, index: usize) ?f64 {
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        const binds = self.row_bind orelse return null;
        if (binds[index].is_null.* != 0) return null;
        const sb = self.string_buffers.?;
        const len = self.lengths.?;
        const text = sb.items[index][0..len.items[index]];
        return std.fmt.parseFloat(f64, text) catch null;
    }

    fn getText(ptr: *anyopaque, index: usize) ?[]const u8 {
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        const binds = self.row_bind orelse return null;
        if (binds[index].is_null.* != 0) return null;
        const sb = self.string_buffers.?;
        const len = self.lengths.?;
        return sb.items[index][0..len.items[index]];
    }

    fn getBlob(ptr: *anyopaque, index: usize) ?[]const u8 {
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        const binds = self.row_bind orelse return null;
        if (binds[index].is_null.* != 0) return null;
        const sb = self.string_buffers.?;
        const len = self.lengths.?;
        return sb.items[index][0..len.items[index]];
    }

    fn isNull(ptr: *anyopaque, index: usize) bool {
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        if (self.row_bind == null) return true;
        const ni = self.null_indicators.?;
        return ni.items[index] != 0;
    }
};

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "MySQL placeholder style" {
    var buf: [16]u8 = undefined;
    const ph = try Dialect.mysql.placeholder(&buf, 1);
    try std.testing.expectEqualStrings("?", ph);
}

test "MySQL quote ident" {
    var buf: [64]u8 = undefined;
    const q = try Dialect.mysql.quoteIdent(&buf, "my_table");
    try std.testing.expectEqualStrings("`my_table`", q);
}
