const std = @import("std");
const c = @import("mysql_c");
const Value = @import("builder.zig").Value;
const Dialect = @import("dialect.zig").Dialect;
const driver = @import("driver.zig");
const cache = @import("cache.zig");

fn toDriverError(err: anyerror) driver.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.MySQLInitFailed, error.MySQLConnectFailed, error.MySQLConfigFailed => error.ConnectionFailed,
        error.MySQLExecFailed => error.ExecFailed,
        error.MySQLStmtFailed, error.MySQLBindResultFailed, error.MySQLParamCountMismatch, error.MySQLNotAQuery => error.QueryFailed,
        error.MySQLPingFailed => error.PingFailed,
        error.MySQLDataTruncated => error.ProtocolError,
        error.MySQLFetchFailed => error.ProtocolError,
        error.QueryTimeout => error.QueryTimeout,
        error.UniqueViolation => error.UniqueViolation,
        error.NotNullViolation => error.NotNullViolation,
        error.ForeignKeyViolation => error.ForeignKeyViolation,
        else => error.DriverFailed,
    };
}

/// Log a failed mysql_options call (non-fatal: connection can still proceed
/// with defaults, e.g. a missing socket timeout just loses the guard).
fn checkOpt(name: []const u8, rc: c_int) void {
    if (rc != 0) std.log.warn("mysql_options({s}) failed rc={d}", .{ name, rc });
}

/// Hard-fail when a security-relevant option could not be applied. Silently
/// downgrading SSL enforcement would violate the caller's stated policy.
fn requireOpt(name: []const u8, rc: c_int) !void {
    if (rc != 0) {
        std.log.err("mysql_options({s}) failed rc={d}", .{ name, rc });
        return error.MySQLConfigFailed;
    }
}

/// Map a MySQL errno to a driver.Error variant.
pub fn errnoToError(errno: c_uint) driver.Error {
    return switch (errno) {
        1040, 1043, 1129, 1130 => error.ConnectionFailed, // Too many connections / host blocked
        1045, 1044 => error.ConnectionFailed, // Access denied
        1062, 1586 => error.UniqueViolation, // Duplicate entry
        1048 => error.NotNullViolation, // Column cannot be null
        1451, 1452 => error.ForeignKeyViolation, // FK constraint fails
        1064, 1146, 1054, 1060 => error.QueryFailed, // Syntax / no such table / bad column
        1142, 1143 => error.ExecFailed, // Permission denied
        1205, 1213 => error.TxFailed, // Lock wait / deadlock
        1317, 1406 => error.ExecFailed, // Query interrupted / data too long
        1969 => error.QueryTimeout, // MariaDB ER_STATEMENT_TIMEOUT
        2002, 2003, 2006, 2013 => error.ConnectionFailed, // Connection lost
        3024 => error.QueryTimeout, // ER_QUERY_TIMEOUT
        else => error.DriverFailed,
    };
}

pub const MySQLDriver = struct {
    conn: *c.MYSQL,
    allocator: std.mem.Allocator,
    /// Default socket timeouts used when no ExecutionContext deadline is present.
    default_read_timeout: c_uint = 30,
    default_write_timeout: c_uint = 30,
    /// Tracks whether the connection currently has an active transaction.
    in_tx: bool = false,
    /// Set when the server-side connection is lost (errno 2002/2003/2006/2013).
    /// Once dead, every operation fails fast WITHOUT touching the C handle —
    /// libmysqlclient dereferences freed/poisoned memory on dead connections,
    /// which segfaults under concurrent load. Pool must close & discard it.
    dead: bool = false,
    /// Optional prepared-statement cache. Set this field after `connect()` to
    /// enable caching; null (the default) disables it.
    cache: ?cache.PreparedCache(16, *c.MYSQL_STMT) = null,

    /// Fail fast when the connection has been lost (avoids segfault on the
    /// stale libmysqlclient handle).
    fn ensureAlive(self: *MySQLDriver) driver.Error!void {
        if (self.dead) return error.ConnectionFailed;
    }

    /// Mark the connection dead after a lost-connection errno.
    fn markDead(self: *MySQLDriver, err: anyerror) void {
        if (err == error.ConnectionFailed) self.dead = true;
    }

    /// MySQL SSL mode.
    pub const SslMode = enum(u32) {
        disabled = 1,
        preferred = 2,
        required = 3,
        verify_ca = 4,
    };

    pub fn connect(allocator: std.mem.Allocator, host: [:0]const u8, port: u32, user: [:0]const u8, passwd: [:0]const u8, dbname: [:0]const u8) !MySQLDriver {
        return connectOpts(allocator, host, port, user, passwd, dbname, .preferred);
    }

    pub fn connectOpts(allocator: std.mem.Allocator, host: [:0]const u8, port: u32, user: [:0]const u8, passwd: [:0]const u8, dbname: [:0]const u8, ssl_mode: SslMode) !MySQLDriver {
        return connectOptsSocket(allocator, host, port, user, passwd, dbname, ssl_mode, null);
    }

    pub fn connectOptsSocket(allocator: std.mem.Allocator, host: [:0]const u8, port: u32, user: [:0]const u8, passwd: [:0]const u8, dbname: [:0]const u8, ssl_mode: SslMode, unix_socket: ?[:0]const u8) !MySQLDriver {
        const conn = c.mysql_init(null);
        if (conn == null) return error.MySQLInitFailed;

        // Set connect timeout (10s) and read/write timeouts (30s).
        const default_read_timeout: c_uint = 30;
        const default_write_timeout: c_uint = 30;
        {
            const connect_timeout: c_uint = 10;
            checkOpt("connect_timeout", c.mysql_options(conn, c.MYSQL_OPT_CONNECT_TIMEOUT, &connect_timeout));
            checkOpt("read_timeout", c.mysql_options(conn, c.MYSQL_OPT_READ_TIMEOUT, &default_read_timeout));
            checkOpt("write_timeout", c.mysql_options(conn, c.MYSQL_OPT_WRITE_TIMEOUT, &default_write_timeout));
        }

        // SSL mode. Note: this mariadb-connector-c build exposes
        // MYSQL_OPT_SSL_ENFORCE but not MYSQL_OPT_SSL_MODE; calling
        // mysql_ssl_set implicitly enforces SSL (that combination broke
        // plain servers like the CI mariadb container), so PREFERRED only
        // sets ENFORCE=0 and lets the client fall back to plaintext.
        switch (ssl_mode) {
            .required => {
                _ = c.mysql_ssl_set(conn, null, null, null, null, null);
                const enforce: c_uint = 1;
                try requireOpt("ssl_enforce(required)", c.mysql_options(conn, c.MYSQL_OPT_SSL_ENFORCE, &enforce));
            },
            .preferred => {
                const enforce: c_uint = 0;
                checkOpt("ssl_enforce(preferred)", c.mysql_options(conn, c.MYSQL_OPT_SSL_ENFORCE, &enforce));
            },
            .disabled => {
                // No SSL at all.
            },
            .verify_ca => {
                _ = c.mysql_ssl_set(conn, null, null, null, null, null);
                const enforce: c_uint = 1;
                try requireOpt("ssl_enforce(verify_ca)", c.mysql_options(conn, c.MYSQL_OPT_SSL_ENFORCE, &enforce));
                const verify: c_uint = 1;
                try requireOpt("ssl_verify_server_cert", c.mysql_options(conn, c.MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &verify));
            },
        }

        const sock_ptr: ?[*:0]const u8 = if (unix_socket) |s| s.ptr else null;
        const ret = c.mysql_real_connect(conn, host.ptr, user.ptr, passwd.ptr, dbname.ptr, @intCast(port), sock_ptr, 0);
        if (ret == null) {
            defer c.mysql_close(conn);
            const msg = c.mysql_error(conn);
            std.log.err("mysql connect failed: {s}", .{std.mem.span(msg)});
            return error.MySQLConnectFailed;
        }

        // Set UTF-8
        _ = c.mysql_set_character_set(conn, "utf8mb4");

        return MySQLDriver{
            .conn = conn,
            .allocator = allocator,
            .default_read_timeout = default_read_timeout,
            .default_write_timeout = default_write_timeout,
        };
    }

    pub fn close(self: *MySQLDriver) void {
        if (self.cache) |*cached| {
            cached.evictAll({}, closeStmt);
        }
        c.mysql_close(self.conn);
    }

    fn logMySQLError(drv: *MySQLDriver, conn: *c.MYSQL, context: []const u8) void {
        // 连接已死时禁止触碰 C 句柄（mysql_error 在已释放句柄上会段错误）。
        if (drv.dead) return;
        const msg = c.mysql_error(conn);
        const errno = c.mysql_errno(conn);
        std.log.err("mysql error ({s}) [errno={d}]: {s}", .{ context, errno, std.mem.span(msg) });
    }

    const SavedTimeouts = struct {
        read: c_uint,
        write: c_uint,
    };

    fn applySocketTimeout(self: *MySQLDriver, ctx: ?*const driver.ExecutionContext, saved: *SavedTimeouts) driver.Error!void {
        saved.* = .{
            .read = self.default_read_timeout,
            .write = self.default_write_timeout,
        };
        if (ctx) |cx| {
            if (cx.remainingMs()) |ms| {
                const sec: c_uint = if (ms == 0) 1 else @intCast((ms + 999) / 1000);
                _ = c.mysql_options(self.conn, c.MYSQL_OPT_READ_TIMEOUT, &sec);
                _ = c.mysql_options(self.conn, c.MYSQL_OPT_WRITE_TIMEOUT, &sec);
            }
        }
        return {};
    }

    fn restoreSocketTimeout(self: *MySQLDriver, saved: SavedTimeouts) void {
        _ = c.mysql_options(self.conn, c.MYSQL_OPT_READ_TIMEOUT, &saved.read);
        _ = c.mysql_options(self.conn, c.MYSQL_OPT_WRITE_TIMEOUT, &saved.write);
    }

    /// Server-side statement timeout. Socket read timeouts do not interrupt a
    /// query the server is already executing, so SELECTs with a deadline also
    /// set max_execution_time (MySQL 8) or max_statement_time (MariaDB; the
    /// variable name is unknown to MySQL and vice versa, hence the fallback).
    /// max_execution_time takes milliseconds; max_statement_time takes seconds.
    fn applyServerTimeout(self: *MySQLDriver, ctx: ?*const driver.ExecutionContext) driver.Error!void {
        const ms_opt = if (ctx) |cx| cx.remainingMs() else null;
        const ms = ms_opt orelse return {};
        const sql = try std.fmt.allocPrint(self.allocator, "SET SESSION max_execution_time = {d}", .{ms});
        defer self.allocator.free(sql);
        if (self.exec(sql, &.{})) |_| {
            return {};
        } else |err| {
            // MySQL 8 accepts max_execution_time; MariaDB doesn't, so fall
            // back to max_statement_time (seconds). If that also fails the
            // query will run without a server-side timeout — log it rather
            // than hanging silently.
            const sec: u32 = if (ms == 0) 1 else @intCast((ms + 999) / 1000);
            const sql2 = try std.fmt.allocPrint(self.allocator, "SET SESSION max_statement_time = {d}", .{sec});
            defer self.allocator.free(sql2);
            if (self.exec(sql2, &.{})) |_| {
                return {};
            } else |err2| {
                std.log.warn("mysql: could not set server-side statement timeout ({s}, {s})", .{ @errorName(err), @errorName(err2) });
            }
        }
    }

    fn resetServerTimeout(self: *MySQLDriver) void {
        _ = self.exec("SET SESSION max_execution_time = DEFAULT", &.{}) catch {
            _ = self.exec("SET SESSION max_statement_time = DEFAULT", &.{}) catch |err| {
                std.log.warn("mysql: could not reset server-side statement timeout ({s})", .{@errorName(err)});
            };
        };
    }

    /// Bind `args` to `binds`/`str_bufs`/`int_bufs`/`float_bufs`/`bool_bufs`.
    /// On success, callers MUST keep these arrays alive until
    /// `mysql_stmt_execute` returns; libmysql copies the values internally
    /// so the buffers can be freed immediately after.
    fn bindParams(
        allocator: std.mem.Allocator,
        args: []const Value,
        binds: []c.MYSQL_BIND,
        is_nulls: []c.my_bool,
        str_bufs: *std.ArrayListUnmanaged([]u8),
        int_bufs: *std.ArrayListUnmanaged(i64),
        float_bufs: *std.ArrayListUnmanaged(f64),
        bool_bufs: *std.ArrayListUnmanaged(i8),
    ) !void {
        for (args, 0..) |arg, i| {
            binds[i].is_null = &is_nulls[i];
            switch (arg) {
                .null => {
                    binds[i].buffer_type = c.MYSQL_TYPE_NULL;
                    is_nulls[i] = 1;
                },
                .bool => |v| {
                    binds[i].buffer_type = c.MYSQL_TYPE_TINY;
                    bool_bufs.items[i] = if (v) 1 else 0;
                    binds[i].buffer = &bool_bufs.items[i];
                },
                .int => |v| {
                    binds[i].buffer_type = c.MYSQL_TYPE_LONGLONG;
                    int_bufs.items[i] = v;
                    binds[i].buffer = &int_bufs.items[i];
                },
                .float => |v| {
                    binds[i].buffer_type = c.MYSQL_TYPE_DOUBLE;
                    float_bufs.items[i] = v;
                    binds[i].buffer = &float_bufs.items[i];
                },
                .string => |v| {
                    binds[i].buffer_type = c.MYSQL_TYPE_STRING;
                    const dup = try allocator.dupe(u8, v);
                    errdefer allocator.free(dup);
                    try str_bufs.append(allocator, dup);
                    binds[i].buffer = dup.ptr;
                    binds[i].buffer_length = @intCast(dup.len);
                },
                .bytes => |v| {
                    binds[i].buffer_type = c.MYSQL_TYPE_BLOB;
                    const dup = try allocator.dupe(u8, v);
                    errdefer allocator.free(dup);
                    try str_bufs.append(allocator, dup);
                    binds[i].buffer = dup.ptr;
                    binds[i].buffer_length = @intCast(dup.len);
                },
            }
        }
    }

    pub fn exec(self: *MySQLDriver, sql: []const u8, args: []const Value) !driver.Result {
        try self.ensureAlive();
        if (args.len == 0) {
            // Simple query without parameters
            const sql_z = try self.allocator.dupeSentinel(u8, sql, 0);
            defer self.allocator.free(sql_z);

            if (c.mysql_real_query(self.conn, sql_z.ptr, @intCast(sql_z.len)) != 0) {
                const errno = c.mysql_errno(self.conn);
                // 1193 = "Unknown system variable": this is the expected
                // probe failure when applyServerTimeout tries
                // max_execution_time against MariaDB — not a real error.
                if (errno != 1193) logMySQLError(self, self.conn, "exec");
                const err = errnoToError(errno);
                self.markDead(err);
                // Timeouts and constraint violations are distinct outcomes
                // (callers rely on e.g. UniqueViolation for upsert fallbacks);
                // everything else collapses to the generic exec failure.
                if (err == error.QueryTimeout or err == error.UniqueViolation or
                    err == error.NotNullViolation or err == error.ForeignKeyViolation) return err;
                return error.MySQLExecFailed;
            }

            return driver.Result{
                .rows_affected = @intCast(c.mysql_affected_rows(self.conn)),
                .last_insert_id = @intCast(c.mysql_insert_id(self.conn)),
            };
        }

        // Use prepared statement for parameterized query
        // DDL invalidates cached prepared statements.
        if (self.cache) |*cached| {
            if (cache.isDDL(sql)) {
                cached.evictAll({}, closeStmt);
            }
        }

        const stmt = if (self.cache) |*cached|
            try cached.getOrPrepare(sql, self, prepareMySQLStmt, {}, closeStmt)
        else
            try prepareMySQLStmt(self, sql);
        defer {
            if (self.cache == null) _ = c.mysql_stmt_close(stmt);
        }

        // Reset before rebinding (needed when stmt came from cache).
        _ = c.mysql_stmt_reset(stmt);

        // Bind parameters
        const n_params = c.mysql_stmt_param_count(stmt);
        if (n_params != args.len) {
            std.log.err("mysql: expected {d} params, got {d}", .{ n_params, args.len });
            return error.MySQLParamCountMismatch;
        }

        const binds = try self.allocator.alloc(c.MYSQL_BIND, @intCast(n_params));
        defer self.allocator.free(binds);
        const is_nulls = try self.allocator.alloc(c.my_bool, args.len);
        defer self.allocator.free(is_nulls);
        @memset(is_nulls, 0);

        var str_bufs = std.ArrayListUnmanaged([]u8).empty;
        var int_bufs = std.ArrayListUnmanaged(i64).empty;
        var float_bufs = std.ArrayListUnmanaged(f64).empty;
        var bool_bufs = std.ArrayListUnmanaged(i8).empty;
        defer {
            for (str_bufs.items) |s| self.allocator.free(s);
            str_bufs.deinit(self.allocator);
            int_bufs.deinit(self.allocator);
            float_bufs.deinit(self.allocator);
            bool_bufs.deinit(self.allocator);
        }

        try str_bufs.ensureUnusedCapacity(self.allocator, args.len);
        try int_bufs.resize(self.allocator, args.len);
        try float_bufs.resize(self.allocator, args.len);
        try bool_bufs.resize(self.allocator, args.len);
        @memset(binds, std.mem.zeroes(c.MYSQL_BIND));

        try bindParams(self.allocator, args, binds, is_nulls, &str_bufs, &int_bufs, &float_bufs, &bool_bufs);

        if (c.mysql_stmt_bind_param(stmt, binds.ptr) != 0) {
            logMySQLError(self, self.conn, "stmt_bind_param");
            return error.MySQLStmtFailed;
        }

        if (c.mysql_stmt_execute(stmt) != 0) {
            const err = errnoToError(c.mysql_errno(self.conn));
            self.markDead(err);
            // Statement timeouts and constraint violations are distinct
            // outcomes; the rest collapse to the generic stmt failure.
            if (err == error.QueryTimeout or err == error.UniqueViolation or
                err == error.NotNullViolation or err == error.ForeignKeyViolation) return err;
            logMySQLError(self, self.conn, "stmt_execute");
            return error.MySQLStmtFailed;
        }

        return driver.Result{
            .rows_affected = @intCast(c.mysql_stmt_affected_rows(stmt)),
            .last_insert_id = @intCast(c.mysql_stmt_insert_id(stmt)),
        };
    }

    pub fn query(self: *MySQLDriver, query_sql: []const u8, args: []const Value) !driver.Rows {
        try self.ensureAlive();
        const stmt = if (self.cache) |*cached|
            try cached.takeOrPrepare(query_sql, self, prepareMySQLStmt)
        else
            try prepareMySQLStmt(self, query_sql);
        errdefer _ = c.mysql_stmt_close(stmt);

        // Reset before rebinding (needed when stmt came from cache).
        _ = c.mysql_stmt_free_result(stmt);
        _ = c.mysql_stmt_reset(stmt);

        // Bind parameters
        const n_params = c.mysql_stmt_param_count(stmt);
        if (n_params != args.len) {
            std.log.err("mysql: expected {d} params, got {d}", .{ n_params, args.len });
            return error.MySQLParamCountMismatch;
        }

        const binds = try self.allocator.alloc(c.MYSQL_BIND, @intCast(n_params));
        defer self.allocator.free(binds);
        const is_nulls = try self.allocator.alloc(c.my_bool, args.len);
        defer self.allocator.free(is_nulls);
        @memset(is_nulls, 0);

        var str_bufs = std.ArrayListUnmanaged([]u8).empty;
        var int_bufs = std.ArrayListUnmanaged(i64).empty;
        var float_bufs = std.ArrayListUnmanaged(f64).empty;
        var bool_bufs = std.ArrayListUnmanaged(i8).empty;
        defer {
            for (str_bufs.items) |s| self.allocator.free(s);
            str_bufs.deinit(self.allocator);
            int_bufs.deinit(self.allocator);
            float_bufs.deinit(self.allocator);
            bool_bufs.deinit(self.allocator);
        }

        try str_bufs.ensureUnusedCapacity(self.allocator, args.len);
        try int_bufs.resize(self.allocator, args.len);
        try float_bufs.resize(self.allocator, args.len);
        try bool_bufs.resize(self.allocator, args.len);
        @memset(binds, std.mem.zeroes(c.MYSQL_BIND));

        try bindParams(self.allocator, args, binds, is_nulls, &str_bufs, &int_bufs, &float_bufs, &bool_bufs);

        if (c.mysql_stmt_bind_param(stmt, binds.ptr) != 0) {
            logMySQLError(self, self.conn, "stmt_bind_param");
            return error.MySQLStmtFailed;
        }

        // Ask the client to compute the actual max length of each column so
        // we can size row buffers accurately and avoid silent truncation.
        var update_max_length: c.my_bool = 1;
        if (c.mysql_stmt_attr_set(stmt, c.STMT_ATTR_UPDATE_MAX_LENGTH, &update_max_length) != 0) {
            logMySQLError(self, self.conn, "stmt_attr_set");
            return error.MySQLStmtFailed;
        }

        if (c.mysql_stmt_execute(stmt) != 0) {
            const err = errnoToError(c.mysql_errno(self.conn));
            self.markDead(err);
            // Statement timeouts and constraint violations are distinct
            // outcomes; the rest collapse to the generic stmt failure.
            if (err == error.QueryTimeout or err == error.UniqueViolation or
                err == error.NotNullViolation or err == error.ForeignKeyViolation) return err;
            logMySQLError(self, self.conn, "stmt_execute");
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
            const err = errnoToError(c.mysql_errno(self.conn));
            // Statement timeouts are the intended outcome of withTimeout.
            if (err == error.QueryTimeout) return err;
            logMySQLError(self, self.conn, "stmt_store_result");
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
            .last_error = null,
            .cache = if (self.cache) |*cch| cch else null,
            .cache_sql_hash = std.hash.Wyhash.hash(0, query_sql),
            .cache_sql_len = query_sql.len,
        };

        return driver.Rows{
            .ptr = rows_ptr,
            .vtable = &MySQLRows.vtable,
        };
    }

    pub fn ping(self: *MySQLDriver) !void {
        try self.ensureAlive();
        if (c.mysql_ping(self.conn) != 0) {
            logMySQLError(self, self.conn, "ping");
            self.markDead(error.ConnectionFailed);
            return error.MySQLPingFailed;
        }
    }

    /// Returns true if the connection currently has an active transaction.
    pub fn inTransaction(self: *MySQLDriver) bool {
        return self.in_tx;
    }

    pub fn beginTx(self: *MySQLDriver) !driver.Tx {
        try self.ensureAlive();
        // MySQL autocommit is on by default, so BEGIN disables it within the tx
        _ = try self.exec("BEGIN", &.{});
        self.in_tx = true;

        const tx_ptr = try self.allocator.create(MySQLTx);
        errdefer self.allocator.destroy(tx_ptr);
        tx_ptr.* = MySQLTx{
            .driver = self,
            .state = .active,
        };

        return driver.Tx{
            .inner = self.asDriver(),
            .commitFn = MySQLTx.commit,
            .rollbackFn = MySQLTx.rollback,
            .deinitFn = MySQLTx.deinit,
            .savepointFn = struct {
                fn f(ptr: *anyopaque, name: []const u8) driver.Error!void {
                    const self_ptr: *MySQLDriver = @ptrCast(@alignCast(ptr));
                    return execSavepointStmt(self_ptr, "SAVEPOINT", name) catch |err| return toDriverError(err);
                }
            }.f,
            .savepointRollbackFn = struct {
                fn f(ptr: *anyopaque, name: []const u8) driver.Error!void {
                    const self_ptr: *MySQLDriver = @ptrCast(@alignCast(ptr));
                    return execSavepointStmt(self_ptr, "ROLLBACK TO", name) catch |err| return toDriverError(err);
                }
            }.f,
            .savepointReleaseFn = struct {
                fn f(ptr: *anyopaque, name: []const u8) driver.Error!void {
                    const self_ptr: *MySQLDriver = @ptrCast(@alignCast(ptr));
                    return execSavepointStmt(self_ptr, "RELEASE", name) catch |err| return toDriverError(err);
                }
            }.f,
            .ptr = tx_ptr,
        };
    }

    /// Open a nested savepoint on an already-active transaction.
    pub fn beginSavepoint(self: *MySQLDriver, name: []const u8) !driver.Tx {
        try execSavepointStmt(self, "SAVEPOINT", name);
        const sp = try self.allocator.create(MySQLSavepoint);
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
                    const s: *MySQLSavepoint = @ptrCast(@alignCast(ptr));
                    return s.commit() catch |err| return toDriverError(err);
                }
            }.f,
            .rollbackFn = struct {
                fn f(ptr: *anyopaque) driver.Error!void {
                    const s: *MySQLSavepoint = @ptrCast(@alignCast(ptr));
                    return s.rollback() catch |err| return toDriverError(err);
                }
            }.f,
            .deinitFn = struct {
                fn f(ptr: *anyopaque) void {
                    const s: *MySQLSavepoint = @ptrCast(@alignCast(ptr));
                    s.deinit();
                }
            }.f,
            .ptr = sp,
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
            fn f(ptr: *anyopaque, ctx: ?*const driver.ExecutionContext, q: []const u8, a: []const Value) driver.Error!driver.Result {
                const self_ptr: *MySQLDriver = @ptrCast(@alignCast(ptr));
                var saved: SavedTimeouts = undefined;
                try self_ptr.applySocketTimeout(ctx, &saved);
                defer self_ptr.restoreSocketTimeout(saved);
                return self_ptr.exec(q, a) catch |err| return toDriverError(err);
            }
        }.f,
        .query = struct {
            fn f(ptr: *anyopaque, ctx: ?*const driver.ExecutionContext, q: []const u8, a: []const Value) driver.Error!driver.Rows {
                const self_ptr: *MySQLDriver = @ptrCast(@alignCast(ptr));
                var saved: SavedTimeouts = undefined;
                try self_ptr.applySocketTimeout(ctx, &saved);
                defer self_ptr.restoreSocketTimeout(saved);
                try self_ptr.applyServerTimeout(ctx);
                defer self_ptr.resetServerTimeout();
                return self_ptr.query(q, a) catch |err| return toDriverError(err);
            }
        }.f,
        .beginTx = struct {
            fn f(ptr: *anyopaque) driver.Error!driver.Tx {
                const self_ptr: *MySQLDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.beginTx() catch |err| return toDriverError(err);
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
        .ping = struct {
            fn f(ptr: *anyopaque) driver.Error!void {
                const self_ptr: *MySQLDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.ping() catch |err| return toDriverError(err);
            }
        }.f,
        .inTransaction = struct {
            fn f(ptr: *anyopaque) bool {
                const self_ptr: *MySQLDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.inTransaction();
            }
        }.f,
        .beginSavepoint = struct {
            fn f(ptr: *anyopaque, name: []const u8) driver.Error!driver.Tx {
                const self_ptr: *MySQLDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.beginSavepoint(name) catch |err| return toDriverError(err);
            }
        }.f,
    };
};

fn execSavepointStmt(d: *MySQLDriver, stmt: []const u8, name: []const u8) !void {
    const sql = try std.fmt.allocPrint(d.allocator, "{s} `{s}`", .{ stmt, name });
    defer d.allocator.free(sql);
    _ = try d.exec(sql, &.{});
}

const MySQLSavepoint = struct {
    driver: *MySQLDriver,
    name: []u8,
    active: bool,

    fn commit(self: *MySQLSavepoint) !void {
        if (!self.active) return;
        try execSavepointStmt(self.driver, "RELEASE", self.name);
        self.active = false;
    }

    fn rollback(self: *MySQLSavepoint) !void {
        if (!self.active) return;
        try execSavepointStmt(self.driver, "ROLLBACK TO", self.name);
        self.active = false;
    }

    fn deinit(self: *MySQLSavepoint) void {
        self.rollback() catch |err| {
            std.log.warn("mysql savepoint deinit: rollback failed ({s})", .{@errorName(err)});
        };
        self.driver.allocator.free(self.name);
        self.driver.allocator.destroy(self);
    }
};

const MySQLTx = struct {
    driver: *MySQLDriver,
    state: enum { active, committed, rolled_back },

    fn commit(ptr: *anyopaque) driver.Error!void {
        const self: *MySQLTx = @ptrCast(@alignCast(ptr));
        if (self.state != .active) return;
        _ = self.driver.exec("COMMIT", &.{}) catch |err| return toDriverError(err);
        self.state = .committed;
        self.driver.in_tx = false;
    }

    fn rollback(ptr: *anyopaque) driver.Error!void {
        const self: *MySQLTx = @ptrCast(@alignCast(ptr));
        if (self.state != .active) return;
        _ = self.driver.exec("ROLLBACK", &.{}) catch |err| return toDriverError(err);
        self.state = .rolled_back;
        self.driver.in_tx = false;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *MySQLTx = @ptrCast(@alignCast(ptr));
        if (self.state == .active) {
            self.driver.in_tx = false;
            _ = self.driver.exec("ROLLBACK", &.{}) catch |err| {
                std.log.warn("mysql tx deinit: rollback failed ({s})", .{@errorName(err)});
            };
        }
        self.driver.allocator.destroy(self);
    }
};

pub const MySQLRows = struct {
    stmt: *c.MYSQL_STMT,
    metadata: *c.MYSQL_RES,
    fields: [*c]c.MYSQL_FIELD,
    num_fields: usize,
    allocator: std.mem.Allocator,
    done: bool,
    last_error: ?anyerror = null,
    cache: ?*cache.PreparedCache(16, *c.MYSQL_STMT) = null,
    cache_sql_hash: u64 = 0,
    cache_sql_len: usize = 0,

    // Per-row buffer
    row_bind: ?[]c.MYSQL_BIND = null,
    string_buffers: ?std.ArrayListUnmanaged([]u8) = null,
    int_buffers: ?std.ArrayListUnmanaged(i64) = null,
    float_buffers: ?std.ArrayListUnmanaged(f64) = null,
    null_indicators: ?std.ArrayListUnmanaged(c.my_bool) = null,
    error_indicators: ?std.ArrayListUnmanaged(c.my_bool) = null,
    lengths: ?std.ArrayListUnmanaged(c_ulong) = null,

    const vtable = driver.Rows.VTable{
        .next = next,
        .deinit = deinit,
        .nextError = nextErrorVTable,
    };

    fn ensureBuffers(self: *MySQLRows) !void {
        if (self.row_bind != null) return;

        const n = self.num_fields;
        var binds = try self.allocator.alloc(c.MYSQL_BIND, n);
        errdefer self.allocator.free(binds);

        var str_bufs = std.ArrayListUnmanaged([]u8).empty;
        var int_bufs = std.ArrayListUnmanaged(i64).empty;
        var float_bufs = std.ArrayListUnmanaged(f64).empty;
        var nulls = std.ArrayListUnmanaged(c.my_bool).empty;
        var errors = std.ArrayListUnmanaged(c.my_bool).empty;
        var lens = std.ArrayListUnmanaged(c_ulong).empty;

        resize_all: {
            try str_bufs.resize(self.allocator, n);
            errdefer str_bufs.deinit(self.allocator);
            try int_bufs.resize(self.allocator, n);
            errdefer int_bufs.deinit(self.allocator);
            try float_bufs.resize(self.allocator, n);
            errdefer float_bufs.deinit(self.allocator);
            try nulls.resize(self.allocator, n);
            errdefer nulls.deinit(self.allocator);
            try errors.resize(self.allocator, n);
            errdefer errors.deinit(self.allocator);
            try lens.resize(self.allocator, n);
            errdefer lens.deinit(self.allocator);
            break :resize_all;
        }

        @memset(binds, std.mem.zeroes(c.MYSQL_BIND));

        {
            var i: usize = 0;
            errdefer {
                for (str_bufs.items[0..i]) |s| self.allocator.free(s);
                str_bufs.deinit(self.allocator);
                int_bufs.deinit(self.allocator);
                float_bufs.deinit(self.allocator);
                nulls.deinit(self.allocator);
                errors.deinit(self.allocator);
                lens.deinit(self.allocator);
            }
            while (i < n) : (i += 1) {
                const field = &self.fields[i];

                // Size buffers from field metadata when available; fallback to a
                // conservative default. Long TEXT/BLOB values previously truncated
                // silently because this was hard-coded to 256 bytes.
                const buf_len: usize = if (field.max_length > 0) field.max_length else 256;
                const buf = try self.allocator.alloc(u8, buf_len);
                str_bufs.items[i] = buf;

                binds[i].buffer_type = c.MYSQL_TYPE_STRING;
                binds[i].buffer = buf.ptr;
                binds[i].buffer_length = @intCast(buf_len);
                binds[i].is_null = &nulls.items[i];
                binds[i].length = &lens.items[i];
                binds[i].@"error" = &errors.items[i];
            }
        }

        if (c.mysql_stmt_bind_result(self.stmt, binds.ptr) != 0) {
            // Let the outer errdefer free `binds`; clean up the rest here.
            for (str_bufs.items) |s| self.allocator.free(s);
            str_bufs.deinit(self.allocator);
            int_bufs.deinit(self.allocator);
            float_bufs.deinit(self.allocator);
            nulls.deinit(self.allocator);
            errors.deinit(self.allocator);
            lens.deinit(self.allocator);
            return error.MySQLBindResultFailed;
        }

        self.row_bind = binds;
        self.string_buffers = str_bufs;
        self.int_buffers = int_bufs;
        self.float_buffers = float_bufs;
        self.null_indicators = nulls;
        self.error_indicators = errors;
        self.lengths = lens;
    }

    fn nextErrorVTable(ptr: *anyopaque) ?driver.Error {
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        return self.nextError();
    }

    fn next(ptr: *anyopaque) ?driver.Row {
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        if (self.done) return null;
        self.last_error = null;

        self.ensureBuffers() catch |err| {
            self.done = true;
            self.last_error = err;
            return null;
        };

        const rc = c.mysql_stmt_fetch(self.stmt);
        if (rc == c.MYSQL_NO_DATA) {
            self.done = true;
            return null;
        }
        if (rc == c.MYSQL_DATA_TRUNCATED) {
            self.last_error = error.MySQLDataTruncated;
            self.done = true;
            return null;
        }
        if (rc != 0) {
            self.last_error = error.MySQLFetchFailed;
            self.done = true;
            return null;
        }

        return driver.Row{
            .ptr = self,
            .vtable = &row_vtable,
        };
    }

    /// Returns the last error encountered while iterating, if any. Consumers
    /// should check this after `next()` returns null to distinguish normal
    /// end-of-results from fetch failures or silent data truncation.
    pub fn nextError(self: *MySQLRows) ?driver.Error {
        const err = self.last_error orelse return null;
        return toDriverError(err);
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        c.mysql_free_result(self.metadata);
        _ = c.mysql_stmt_free_result(self.stmt);

        if (self.cache) |cch| {
            _ = c.mysql_stmt_reset(self.stmt);
            cch.returnStmtByHash(self.cache_sql_hash, self.cache_sql_len, self.stmt, {}, struct {
                fn f(_: anytype, s: *c.MYSQL_STMT) void {
                    _ = c.mysql_stmt_close(s);
                }
            }.f);
        } else {
            _ = c.mysql_stmt_close(self.stmt);
        }

        if (self.row_bind) |binds| {
            self.allocator.free(binds);
        }
        if (self.string_buffers) |sb| {
            var sb_mut = sb;
            for (sb_mut.items) |s| {
                self.allocator.free(s);
            }
            sb_mut.deinit(self.allocator);
        }
        if (self.int_buffers) |ib| {
            var ib_mut = ib;
            ib_mut.deinit(self.allocator);
        }
        if (self.float_buffers) |fb| {
            var fb_mut = fb;
            fb_mut.deinit(self.allocator);
        }
        if (self.null_indicators) |ni| {
            var ni_mut = ni;
            ni_mut.deinit(self.allocator);
        }
        if (self.error_indicators) |ei| {
            var ei_mut = ei;
            ei_mut.deinit(self.allocator);
        }
        if (self.lengths) |l| {
            var l_mut = l;
            l_mut.deinit(self.allocator);
        }

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
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        return self.num_fields;
    }

    fn columnName(ptr: *anyopaque, index: usize) []const u8 {
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        return std.mem.span(self.fields[@intCast(index)].name);
    }

    fn getBool(ptr: *anyopaque, index: usize) ?bool {
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        const binds = self.row_bind orelse return null;
        if (binds[index].is_null.* != 0) return null;
        const sb = self.string_buffers.?;
        const len = self.lengths.?;
        const text = sb.items[index][0..len.items[index]];
        return !std.mem.eql(u8, text, "0") and !std.ascii.eqlIgnoreCase(text, "false");
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
// Prepared-statement cache helpers
// ------------------------------------------------------------------

fn closeStmt(_: void, stmt: *c.MYSQL_STMT) void {
    _ = c.mysql_stmt_close(stmt);
}

fn prepareMySQLStmt(drv: *MySQLDriver, sql: []const u8) !*c.MYSQL_STMT {
    try drv.ensureAlive();
    const stmt = c.mysql_stmt_init(drv.conn);
    if (stmt == null) {
        MySQLDriver.logMySQLError(drv, drv.conn, "stmt_init");
        return error.MySQLStmtFailed;
    }
    errdefer _ = c.mysql_stmt_close(stmt);

    const sql_z = try drv.allocator.dupeSentinel(u8, sql, 0);
    defer drv.allocator.free(sql_z);

    if (c.mysql_stmt_prepare(stmt, sql_z.ptr, @intCast(sql_z.len)) != 0) {
        MySQLDriver.logMySQLError(drv, drv.conn, "stmt_prepare");
        return error.MySQLStmtFailed;
    }
    return stmt;
}

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
