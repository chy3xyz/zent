const std = @import("std");
const c = @import("mysql_c");
const Value = @import("builder.zig").Value;
const Dialect = @import("dialect.zig").Dialect;
const driver = @import("driver.zig");
const cache = @import("cache.zig");
const zent_log = @import("../runtime/log.zig");

/// The value `mysql_affected_rows` and `mysql_stmt_affected_rows` return when
/// they have no count to give. The C API documents it as `(my_ulonglong)-1`, so
/// it is the all-ones value rather than a negative number — comparing the
/// unsigned result against this constant is what keeps it out of `usize`.
const no_affected_rows: c.my_ulonglong = ~@as(c.my_ulonglong, 0);

fn toDriverError(err: anyerror) driver.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.MySQLInitFailed, error.MySQLConnectFailed, error.MySQLConfigFailed => error.ConnectionFailed,
        error.MySQLExecFailed => error.ExecFailed,
        error.MySQLParamCountMismatch => error.ParamCountMismatch,
        error.MySQLStmtFailed, error.MySQLBindResultFailed, error.MySQLNotAQuery => error.QueryFailed,
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

/// Errnos whose driver.Error carries caller-actionable meaning (constraint
/// violations, timeouts, retryable transaction aborts, and a lost connection)
/// and must be propagated verbatim instead of collapsing into the generic
/// MySQLExecFailed / MySQLStmtFailed. `ConnectionFailed` belongs here because
/// the pool has to tell "this connection is gone, discard it" from "this
/// statement failed"; the PostgreSQL driver reports the same condition, so
/// leaving it out also made the two dialects answer differently.
fn isDistinctErrno(err: driver.Error) bool {
    return switch (err) {
        error.ConnectionFailed,
        error.QueryTimeout,
        error.UniqueViolation,
        error.NotNullViolation,
        error.ForeignKeyViolation,
        error.DeadlockDetected,
        error.SerializationFailure,
        error.LockTimeout,
        => true,
        else => false,
    };
}

/// Log a failed mysql_options call (non-fatal: connection can still proceed
/// with defaults, e.g. a missing socket timeout just loses the guard).
fn checkOpt(name: []const u8, rc: c_int) void {
    if (rc != 0) zent_log.warn("mysql_options({s}) failed rc={d}", .{ name, rc });
}

/// Hard-fail when a security-relevant option could not be applied. Silently
/// downgrading SSL enforcement would violate the caller's stated policy.
fn requireOpt(name: []const u8, rc: c_int) !void {
    if (rc != 0) {
        zent_log.err("mysql_options({s}) failed rc={d}", .{ name, rc });
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
        1213 => error.DeadlockDetected, // ER_LOCK_DEADLOCK
        1205 => error.LockTimeout, // ER_LOCK_WAIT_TIMEOUT
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
    /// Server-side statement timeout currently set on this connection, in
    /// milliseconds. `null` means the server DEFAULT (no timeout). Tracked so
    /// a statement only pays a `SET SESSION` round trip when the desired value
    /// differs from what the connection already has.
    current_server_timeout_ms: ?u32 = null,

    /// Fail fast when the connection has been lost (avoids segfault on the
    /// stale libmysqlclient handle).
    fn ensureAlive(self: *MySQLDriver) driver.Error!void {
        if (self.dead) {
            @branchHint(.cold);
            return error.ConnectionFailed;
        }
    }

    /// Mark the connection dead after a lost-connection errno.
    inline fn markDead(self: *MySQLDriver, err: anyerror) void {
        if (err == error.ConnectionFailed) self.dead = true;
    }

    /// Record a failed C call on the driver and return the classification to
    /// report, or `null` when the caller must collapse it into its generic
    /// failure.
    ///
    /// Every collapse site funnels through here so a lost connection is always
    /// flagged (`markDead`, so the pool discards the handle and nothing reads
    /// from it again) and always reported as `ConnectionFailed` — the retryable
    /// class callers switch on — rather than as `ExecFailed` / `QueryFailed`.
    /// Timeouts and constraint violations keep their own classification for the
    /// same reason; anything else returns `null`.
    fn classifyFailure(self: *MySQLDriver, errno: c_uint) ?driver.Error {
        const err = errnoToError(errno);
        self.markDead(err);
        return if (isDistinctErrno(err)) err else null;
    }

    /// MySQL SSL mode.
    pub const SslMode = enum(u32) {
        disabled = 1,
        preferred = 2,
        required = 3,
        verify_ca = 4,
    };

    /// TLS material for the `connectOptsSsl*` entry points. Paths are PEM
    /// files, all null-terminated, and are borrowed only for the duration of
    /// the connect call.
    ///
    /// The mode on its own is not enough to verify anything: `verify_ca`
    /// needs `ca` (or `capath`) to have something to validate the server
    /// certificate against — with neither, the connector can still complete
    /// the handshake, so the mode alone is only a policy hint. Mutual TLS
    /// (e.g. a server-side `REQUIRE X509`) needs both `cert` and `key`;
    /// supplying only one leaves the server unsatisfied.
    ///
    /// Supplying any path also makes the handshake mandatory in this
    /// connector build (`mysql_ssl_set` implies enforcement), so `preferred`
    /// falls back to plaintext only when no material is given.
    pub const SslConfig = struct {
        mode: SslMode = .preferred,
        /// PEM bundle of trusted CAs (mysql_ssl_set's `ca`).
        ca: ?[:0]const u8 = null,
        /// Directory of hashed CA certificates (mysql_ssl_set's `capath`).
        capath: ?[:0]const u8 = null,
        /// Client certificate for mutual TLS (mysql_ssl_set's `cert`).
        cert: ?[:0]const u8 = null,
        /// Client private key for mutual TLS (mysql_ssl_set's `key`).
        key: ?[:0]const u8 = null,
        /// Cipher list (mysql_ssl_set's `cipher`).
        cipher: ?[:0]const u8 = null,
    };

    pub fn connect(allocator: std.mem.Allocator, host: [:0]const u8, port: u32, user: [:0]const u8, passwd: [:0]const u8, dbname: [:0]const u8) !MySQLDriver {
        return connectOpts(allocator, host, port, user, passwd, dbname, .preferred);
    }

    pub fn connectOpts(allocator: std.mem.Allocator, host: [:0]const u8, port: u32, user: [:0]const u8, passwd: [:0]const u8, dbname: [:0]const u8, ssl_mode: SslMode) !MySQLDriver {
        return connectOptsSsl(allocator, host, port, user, passwd, dbname, .{ .mode = ssl_mode });
    }

    /// Connect with a unix socket instead of TCP. `unix_socket == null`
    /// means TCP.
    pub fn connectOptsSocket(allocator: std.mem.Allocator, host: [:0]const u8, port: u32, user: [:0]const u8, passwd: [:0]const u8, dbname: [:0]const u8, ssl_mode: SslMode, unix_socket: ?[:0]const u8) !MySQLDriver {
        return connectOptsSslSocket(allocator, host, port, user, passwd, dbname, .{ .mode = ssl_mode }, unix_socket);
    }

    /// Like `connectOpts`, but carries CA/client-certificate/key/cipher.
    pub fn connectOptsSsl(allocator: std.mem.Allocator, host: [:0]const u8, port: u32, user: [:0]const u8, passwd: [:0]const u8, dbname: [:0]const u8, cfg: SslConfig) !MySQLDriver {
        return connectOptsSslSocket(allocator, host, port, user, passwd, dbname, cfg, null);
    }

    pub fn connectOptsSslSocket(allocator: std.mem.Allocator, host: [:0]const u8, port: u32, user: [:0]const u8, passwd: [:0]const u8, dbname: [:0]const u8, cfg: SslConfig, unix_socket: ?[:0]const u8) !MySQLDriver {
        const conn = c.mysql_init(null);
        if (conn == null) return error.MySQLInitFailed;
        errdefer c.mysql_close(conn);

        // Set connect timeout (10s) and read/write timeouts (30s).
        const default_read_timeout: c_uint = 30;
        const default_write_timeout: c_uint = 30;
        {
            const connect_timeout: c_uint = 10;
            checkOpt("connect_timeout", c.mysql_options(conn, c.MYSQL_OPT_CONNECT_TIMEOUT, &connect_timeout));
            checkOpt("read_timeout", c.mysql_options(conn, c.MYSQL_OPT_READ_TIMEOUT, &default_read_timeout));
            checkOpt("write_timeout", c.mysql_options(conn, c.MYSQL_OPT_WRITE_TIMEOUT, &default_write_timeout));
        }

        // mysql_ssl_set's parameter order is (key, cert, ca, capath, cipher).
        const key_ptr: ?[*:0]const u8 = if (cfg.key) |v| v.ptr else null;
        const cert_ptr: ?[*:0]const u8 = if (cfg.cert) |v| v.ptr else null;
        const ca_ptr: ?[*:0]const u8 = if (cfg.ca) |v| v.ptr else null;
        const capath_ptr: ?[*:0]const u8 = if (cfg.capath) |v| v.ptr else null;
        const cipher_ptr: ?[*:0]const u8 = if (cfg.cipher) |v| v.ptr else null;
        const has_material = cfg.ca != null or cfg.capath != null or
            cfg.cert != null or cfg.key != null or cfg.cipher != null;

        // SSL mode. Note: this mariadb-connector-c build exposes
        // MYSQL_OPT_SSL_ENFORCE but not MYSQL_OPT_SSL_MODE; calling
        // mysql_ssl_set implicitly enforces SSL (that combination broke
        // plain servers like the CI mariadb container), so PREFERRED does not
        // touch SSL at all unless the caller explicitly supplied material —
        // those files would otherwise be silently ignored, and a caller that
        // names a CA/cert wants TLS regardless of the fallback hint.
        switch (cfg.mode) {
            .required => {
                _ = c.mysql_ssl_set(conn, key_ptr, cert_ptr, ca_ptr, capath_ptr, cipher_ptr);
                const enforce: c_uint = 1;
                try requireOpt("ssl_enforce(required)", c.mysql_options(conn, c.MYSQL_OPT_SSL_ENFORCE, &enforce));
            },
            .preferred => {
                if (has_material) {
                    _ = c.mysql_ssl_set(conn, key_ptr, cert_ptr, ca_ptr, capath_ptr, cipher_ptr);
                }
                const enforce: c_uint = 0;
                checkOpt("ssl_enforce(preferred)", c.mysql_options(conn, c.MYSQL_OPT_SSL_ENFORCE, &enforce));
            },
            .disabled => {
                // No SSL at all; any TLS material is intentionally ignored.
            },
            .verify_ca => {
                _ = c.mysql_ssl_set(conn, key_ptr, cert_ptr, ca_ptr, capath_ptr, cipher_ptr);
                const enforce: c_uint = 1;
                try requireOpt("ssl_enforce(verify_ca)", c.mysql_options(conn, c.MYSQL_OPT_SSL_ENFORCE, &enforce));
                const verify: c_uint = 1;
                try requireOpt("ssl_verify_server_cert", c.mysql_options(conn, c.MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &verify));
            },
        }

        const sock_ptr: ?[*:0]const u8 = if (unix_socket) |s| s.ptr else null;
        const ret = c.mysql_real_connect(conn, host.ptr, user.ptr, passwd.ptr, dbname.ptr, @intCast(port), sock_ptr, 0);
        if (ret == null) {
            const msg = c.mysql_error(conn);
            // warn (not err): a refused connection is an expected, recoverable
            // outcome (server not running / integration-test skip path), and
            // the test framework fails on err-level logs even in skipped tests.
            zent_log.warn("mysql connect failed: {s}", .{std.mem.span(msg)});
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

    /// Prepare `sql` and read its parameter list back, then close the statement
    /// without executing it (`mysql_stmt_prepare` is the whole of it — the row
    /// count of a checked `INSERT` is where it was before).
    ///
    /// Because MySQL's driver always runs parameterized SQL through the
    /// prepared-statement protocol, this is the same channel `exec` uses, with
    /// one exception worth knowing about: the protocol rejects some perfectly
    /// valid statements (`BEGIN`, `LOCK TABLES`, ... — errno 1295), and those
    /// are reported as `CheckReport.Kind.unsupported` rather than as a
    /// statement defect. `exec` runs them through `mysql_real_query` instead,
    /// so "unsupported" means "this channel cannot judge it", not "invalid".
    ///
    /// Not logged, unlike the exec path: a statement that fails to prepare is
    /// the expected outcome of a check.
    pub fn prepareCheck(self: *MySQLDriver, allocator: std.mem.Allocator, sql: []const u8, args: []const Value, out: *driver.CheckReport) driver.Error!void {
        try self.ensureAlive();

        const stmt = c.mysql_stmt_init(self.conn) orelse return error.DriverFailed;
        // Closing the statement frees the buffer `mysql_stmt_error` points
        // into, so the text is copied before this runs.
        defer _ = c.mysql_stmt_close(stmt);

        const sql_z = try self.allocator.dupeSentinel(u8, sql, 0);
        defer self.allocator.free(sql_z);

        if (c.mysql_stmt_prepare(stmt, sql_z.ptr, @intCast(sql_z.len)) != 0) {
            const errno = c.mysql_stmt_errno(stmt);
            // A dead socket is not a statement verdict. markDead keeps the
            // pool from handing this connection to the next borrower.
            const err = errnoToError(errno);
            self.markDead(err);
            if (err == error.ConnectionFailed) return error.ConnectionFailed;
            out.* = .{
                .kind = if (errno == 1295) .unsupported else .prepare_failed,
                .native_code = @intCast(errno),
                .message = try allocator.dupe(u8, std.mem.span(c.mysql_stmt_error(stmt))),
            };
            return;
        }

        const n_params: usize = @intCast(c.mysql_stmt_param_count(stmt));
        out.* = if (n_params == args.len)
            .{ .kind = .ok, .param_count = n_params }
        else
            .{ .kind = .param_mismatch, .param_count = n_params };
    }

    fn logMySQLError(drv: *MySQLDriver, conn: *c.MYSQL, context: []const u8) void {
        // 连接已死时禁止触碰 C 句柄（mysql_error 在已释放句柄上会段错误）。
        if (drv.dead) return;
        const msg = c.mysql_error(conn);
        const errno = c.mysql_errno(conn);
        // `warn`, not `err`: a failed statement is the caller's to handle (a
        // constraint violation, a deadlock, an expected 4xx), and the caller already
        // receives the error. Error level would mean double-reporting into whatever
        // alerts on it — and, concretely, a test could not exercise a failure path at
        // all, because Zig's test runner treats a logged error as a test failure.
        // `connect` failures have been `warn` for the same reason.
        zent_log.warn("mysql error ({s}) [errno={d}]: {s}", .{ context, errno, std.mem.span(msg) });
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
    ///
    /// Only sends `SET SESSION` when the desired value differs from the
    /// connection's current one: a statement with no deadline costs zero extra
    /// round trips (the old code reset unconditionally after every statement),
    /// and a statement with a deadline skips the trailing reset because the
    /// next statement restores DEFAULT for itself. Leaving a non-default value
    /// on a pooled connection is harmless for the same reason.
    fn applyServerTimeout(self: *MySQLDriver, ctx: ?*const driver.ExecutionContext) driver.Error!void {
        const desired: ?u32 = if (ctx) |cx| cx.remainingMs() else null;
        if (self.current_server_timeout_ms == desired) return;

        if (desired == null) {
            if (self.exec("SET SESSION max_execution_time = DEFAULT", &.{})) |_| {
                self.current_server_timeout_ms = null;
                return;
            } else |err| {
                // MariaDB doesn't know max_execution_time.
                if (self.exec("SET SESSION max_statement_time = DEFAULT", &.{})) |_| {
                    self.current_server_timeout_ms = null;
                    return;
                } else |err2| {
                    zent_log.warn("mysql: could not reset server-side statement timeout ({s}, {s})", .{ @errorName(err), @errorName(err2) });
                    return;
                }
            }
        }

        const ms = desired.?;
        const sql = try self.allocator.print("SET SESSION max_execution_time = {d}", .{ms});
        defer self.allocator.free(sql);
        if (self.exec(sql, &.{})) |_| {
            self.current_server_timeout_ms = desired;
            return;
        } else |err| {
            // MySQL 8 accepts max_execution_time; MariaDB doesn't, so fall
            // back to max_statement_time (seconds). If that also fails the
            // query will run without a server-side timeout — log it rather
            // than hanging silently.
            const sec: u32 = if (ms == 0) 1 else @intCast((ms + 999) / 1000);
            const sql2 = try self.allocator.print("SET SESSION max_statement_time = {d}", .{sec});
            defer self.allocator.free(sql2);
            if (self.exec(sql2, &.{})) |_| {
                self.current_server_timeout_ms = desired;
                return;
            } else |err2| {
                zent_log.warn("mysql: could not set server-side statement timeout ({s}, {s})", .{ @errorName(err), @errorName(err2) });
            }
        }
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
                if (self.classifyFailure(errno)) |err| return err;
                return error.MySQLExecFailed;
            }

            // A statement that returns rows (a no-arg `SELECT` issued through
            // exec) leaves its result set pending; libmysql then rejects the
            // next command with errno 2014 "Commands out of sync". Consume and
            // free it. Statements with no result set (INSERT/UPDATE/DDL) yield
            // NULL here with errno 0 — the common exec path.
            if (c.mysql_store_result(self.conn)) |res| {
                c.mysql_free_result(res);
            } else if (c.mysql_errno(self.conn) != 0) {
                if (self.classifyFailure(c.mysql_errno(self.conn))) |err| return err;
                return error.MySQLExecFailed;
            }

            const raw = c.mysql_affected_rows(self.conn);
            // `mysql_insert_id()` documents 0 as "no AUTO_INCREMENT value was
            // set (and no rows were written)" — the C API's "no id", not a key
            // of 0. Reporting `null` here is what makes a plain insert into a
            // table without AUTO_INCREMENT surface as `MissingLastInsertId`
            // instead of silently writing pk = 0. `ON DUPLICATE KEY UPDATE`
            // keeps an id on both branches — the insert reports the new row's,
            // the update branch the updated row's — so `null` never means "the
            // row was already there".
            const raw_id = c.mysql_insert_id(self.conn);
            return driver.Result{
                .rows_affected = if (raw == no_affected_rows) 0 else @intCast(raw),
                .rows_affected_known = raw != no_affected_rows,
                .last_insert_id = if (raw_id != 0) @as(?i64, @intCast(raw_id)) else null,
            };
        }

        // Use prepared statement for parameterized query
        // DDL invalidates cached prepared statements.
        if (self.cache) |*cached| {
            if (cache.isDDL(sql)) {
                cached.evictAll({}, closeStmt);
            }
        }

        var owns_stmt = true;
        const stmt = if (self.cache) |*cached| blk: {
            const p = try cached.getOrPrepare(sql, self, prepareMySQLStmt, {}, closeStmt);
            owns_stmt = !p.cached;
            break :blk p.stmt;
        } else try prepareMySQLStmt(self, sql);
        defer {
            if (owns_stmt) _ = c.mysql_stmt_close(stmt);
        }

        // Reset before rebinding (needed when stmt came from cache).
        _ = c.mysql_stmt_reset(stmt);

        // Bind parameters
        const n_params = c.mysql_stmt_param_count(stmt);
        if (n_params != args.len) {
            // `warn`, not `err`: the caller gets the error back and has to
            // handle it, and a test that pins this path could not run at all if
            // the log level made the test runner fail (same reason the SQLite
            // driver logs its statement failures at warn).
            zent_log.warn("mysql: expected {d} params, got {d}", .{ n_params, args.len });
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
            if (self.classifyFailure(c.mysql_errno(self.conn))) |err| return err;
            logMySQLError(self, self.conn, "stmt_execute");
            return error.MySQLStmtFailed;
        }

        // `mysql_stmt_affected_rows` answers `(my_ulonglong)-1` — not 0 — while
        // it has no count: on error, and for a statement whose result set has
        // not been consumed, which is every SELECT issued through this
        // parameterized path (measured with a zero error code, so it is live).
        // `@intCast`ing that to `usize` used to store 18446744073709551615.
        const raw = c.mysql_stmt_affected_rows(stmt);
        // Same "0 is no id" rule as the simple path above: the C API documents
        // `mysql_stmt_insert_id()` as answering 0 when the statement produced
        // no AUTO_INCREMENT value. `ON DUPLICATE KEY UPDATE` reports the
        // updated row's own id on its update branch (the emitted
        // `id=LAST_INSERT_ID(id)` is what makes that so), so `null` here is
        // exactly "the driver has no id".
        const raw_id = c.mysql_stmt_insert_id(stmt);
        return driver.Result{
            .rows_affected = if (raw == no_affected_rows) 0 else @intCast(raw),
            .rows_affected_known = raw != no_affected_rows,
            .last_insert_id = if (raw_id != 0) @as(?i64, @intCast(raw_id)) else null,
        };
    }

    pub fn query(self: *MySQLDriver, query_sql: []const u8, args: []const Value) !driver.Rows {
        try self.ensureAlive();
        var cache_slot: ?usize = null;
        const stmt = if (self.cache) |*cached| blk: {
            const t = try cached.takeOrPrepare(query_sql, self, prepareMySQLStmt);
            cache_slot = t.slot;
            break :blk t.stmt;
        } else try prepareMySQLStmt(self, query_sql);
        // Failure before the Rows iterator takes ownership: a statement held
        // on a taken slot goes back to the cache (reset first, the way
        // `MySQLRows.deinit` returns it) instead of being closed beneath an
        // entry that still points at it and keeps the slot reserved — that
        // burned one slot per distinct SQL that hit and failed, until the
        // connection's prepare cache never hit again. A caller-owned handle
        // (cache miss) is closed.
        errdefer {
            if (self.cache) |*cached| {
                _ = c.mysql_stmt_free_result(stmt);
                _ = c.mysql_stmt_reset(stmt);
                cached.releaseTaken(cache_slot, stmt, {}, closeStmt);
            } else {
                _ = c.mysql_stmt_close(stmt);
            }
        }

        // Reset before rebinding (needed when stmt came from cache).
        _ = c.mysql_stmt_free_result(stmt);
        _ = c.mysql_stmt_reset(stmt);

        // Bind parameters
        const n_params = c.mysql_stmt_param_count(stmt);
        if (n_params != args.len) {
            // `warn`, not `err`: the caller gets the error back and has to
            // handle it, and a test that pins this path could not run at all if
            // the log level made the test runner fail (same reason the SQLite
            // driver logs its statement failures at warn).
            zent_log.warn("mysql: expected {d} params, got {d}", .{ n_params, args.len });
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
            if (self.classifyFailure(c.mysql_errno(self.conn))) |err| return err;
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
            // Statement timeouts (the intended outcome of withTimeout) and a
            // lost connection are both distinct; the latter also marks the
            // handle dead so the pool discards it.
            if (self.classifyFailure(c.mysql_errno(self.conn))) |err| return err;
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
            .cache = if (cache_slot != null) &self.cache.? else null,
            .cache_slot = cache_slot,
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

        const tx_ptr = try self.allocator.create(MySQLTx);
        errdefer self.allocator.destroy(tx_ptr);
        tx_ptr.* = MySQLTx{
            .driver = self,
            .state = .active,
        };

        // MySQL autocommit is on by default, so BEGIN disables it within the tx
        _ = try self.exec("BEGIN", &.{});
        self.in_tx = true;

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
                try self_ptr.applyServerTimeout(ctx);
                return self_ptr.exec(q, a) catch |err| return toDriverError(err);
            }
        }.f,
        .query = struct {
            fn f(ptr: *anyopaque, ctx: ?*const driver.ExecutionContext, q: []const u8, a: []const Value) driver.Error!driver.Rows {
                const self_ptr: *MySQLDriver = @ptrCast(@alignCast(ptr));
                var saved: SavedTimeouts = undefined;
                try self_ptr.applySocketTimeout(ctx, &saved);
                defer self_ptr.restoreSocketTimeout(saved);
                // applyServerTimeout only sends SET when the connection's
                // current value differs, so no trailing reset is needed.
                try self_ptr.applyServerTimeout(ctx);
                return self_ptr.query(q, a) catch |err| return toDriverError(err);
            }
        }.f,
        .prepareCheck = struct {
            fn f(ptr: *anyopaque, allocator: std.mem.Allocator, q: []const u8, a: []const Value, out: *driver.CheckReport) driver.Error!void {
                const self_ptr: *MySQLDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.prepareCheck(allocator, q, a, out);
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
    const sql = try d.allocator.print("{s} `{s}`", .{ stmt, name });
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
            zent_log.warn("mysql savepoint deinit: rollback failed ({s})", .{@errorName(err)});
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
            // Clear the flag only after the ROLLBACK actually succeeded. The
            // pool reads `inTransaction()` to decide whether a returned
            // connection still holds a transaction, so clearing it up front
            // would let a connection whose rollback failed (for any reason
            // other than a lost connection) go back into `available` while a
            // server-side transaction is still open — the next borrower would
            // then run inside it. ConnPool.release reasons the same way and
            // drops a connection it could not clean.
            if (self.driver.exec("ROLLBACK", &.{})) |_| {
                self.driver.in_tx = false;
            } else |err| {
                zent_log.warn("mysql tx deinit: rollback failed ({s})", .{@errorName(err)});
            }
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
    cache_slot: ?usize = null,

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

        if (self.cache_slot) |slot| {
            _ = c.mysql_stmt_reset(self.stmt);
            self.cache.?.returnStmt(slot, self.stmt, {}, struct {
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

    /// The column's text as bound by the last fetch, or null when the cell is
    /// NULL. getBool/getInt/getFloat parse from this one copy; isNull cannot
    /// share it (it reads `null_indicators`, not the row bind).
    fn textOf(self: *MySQLRows, index: usize) ?[]const u8 {
        const binds = self.row_bind orelse return null;
        if (binds[index].is_null.* != 0) return null;
        const sb = self.string_buffers.?;
        const len = self.lengths.?;
        return sb.items[index][0..len.items[index]];
    }

    fn getBool(ptr: *anyopaque, index: usize) ?bool {
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        const text = self.textOf(index) orelse return null;
        return !std.mem.eql(u8, text, "0") and !std.ascii.eqlIgnoreCase(text, "false");
    }

    fn getInt(ptr: *anyopaque, index: usize) ?i64 {
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        const text = self.textOf(index) orelse return null;
        return std.fmt.parseInt(i64, text, 10) catch null;
    }

    fn getFloat(ptr: *anyopaque, index: usize) ?f64 {
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        const text = self.textOf(index) orelse return null;
        return std.fmt.parseFloat(f64, text) catch null;
    }

    fn getText(ptr: *anyopaque, index: usize) ?[]const u8 {
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        return self.textOf(index);
    }

    fn getBlob(ptr: *anyopaque, index: usize) ?[]const u8 {
        const self: *MySQLRows = @ptrCast(@alignCast(ptr));
        return self.textOf(index);
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
        if (drv.classifyFailure(c.mysql_errno(drv.conn))) |err| return err;
        MySQLDriver.logMySQLError(drv, drv.conn, "stmt_prepare");
        zent_log.debug("mysql stmt_prepare sql: {s}", .{sql});
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

test "MySQL errnoToError maps common errnos" {
    try std.testing.expectEqual(driver.Error.UniqueViolation, errnoToError(1062));
    try std.testing.expectEqual(driver.Error.UniqueViolation, errnoToError(1586));
    try std.testing.expectEqual(driver.Error.NotNullViolation, errnoToError(1048));
    try std.testing.expectEqual(driver.Error.ForeignKeyViolation, errnoToError(1451));
    try std.testing.expectEqual(driver.Error.ForeignKeyViolation, errnoToError(1452));
    try std.testing.expectEqual(driver.Error.DeadlockDetected, errnoToError(1213));
    try std.testing.expectEqual(driver.Error.LockTimeout, errnoToError(1205));
    try std.testing.expect(driver.isRetryable(errnoToError(1213)));
    try std.testing.expect(driver.isRetryable(errnoToError(1205)));
    try std.testing.expectEqual(driver.Error.QueryTimeout, errnoToError(1969));
    try std.testing.expectEqual(driver.Error.QueryTimeout, errnoToError(3024));
    try std.testing.expectEqual(driver.Error.ConnectionFailed, errnoToError(2006));
    try std.testing.expectEqual(driver.Error.DriverFailed, errnoToError(999999));
}

test "MySQL toDriverError maps native errors to the unified set" {
    try std.testing.expectEqual(driver.Error.ConnectionFailed, toDriverError(error.MySQLConnectFailed));
    try std.testing.expectEqual(driver.Error.ExecFailed, toDriverError(error.MySQLExecFailed));
    try std.testing.expectEqual(driver.Error.QueryFailed, toDriverError(error.MySQLStmtFailed));
    // Not `QueryFailed`: the caller can now tell "my argument list is wrong"
    // from "the query failed", and the same name is what SQLite reports for
    // the same mistake.
    try std.testing.expectEqual(driver.Error.ParamCountMismatch, toDriverError(error.MySQLParamCountMismatch));
    try std.testing.expectEqual(driver.Error.ProtocolError, toDriverError(error.MySQLDataTruncated));
    try std.testing.expectEqual(driver.Error.QueryTimeout, toDriverError(error.QueryTimeout));
    try std.testing.expectEqual(driver.Error.UniqueViolation, toDriverError(error.UniqueViolation));
    try std.testing.expectEqual(driver.Error.DriverFailed, toDriverError(error.Unexpected));
}

// ------------------------------------------------------------------
// Lost-connection handling
// ------------------------------------------------------------------

test "MySQL: a lost connection keeps its classification instead of collapsing" {
    // The collapse sites (`exec`, `query` and the prepared-statement failures)
    // must keep a distinction the caller and the pool act on. `ConnectionFailed`
    // used to be missing from the whitelist, so a lost connection came back as
    // MySQLExecFailed / MySQLStmtFailed: the pool could not tell it should
    // discard the handle, and a consumer switching on the error got a different
    // answer than the PostgreSQL driver gives for the same condition.
    try std.testing.expect(driver.isRetryable(error.ConnectionFailed));
    try std.testing.expect(isDistinctErrno(errnoToError(2002))); // CR_CONN_HOST_ERROR
    try std.testing.expect(isDistinctErrno(errnoToError(2003))); // CR_CONNECTION_ERROR
    try std.testing.expect(isDistinctErrno(errnoToError(2006))); // CR_SERVER_GONE_ERROR
    try std.testing.expect(isDistinctErrno(errnoToError(2013))); // CR_SERVER_LOST

    // The exact decision every collapse site makes: propagate the lost
    // connection (and remember the handle is unusable) instead of collapsing.
    var drv: MySQLDriver = .{ .conn = undefined, .allocator = undefined };
    try std.testing.expectEqual(driver.Error.ConnectionFailed, drv.classifyFailure(2006).?);
    try std.testing.expect(drv.dead);

    // ... but the whitelist did not become a catch-all: an ordinary exec
    // failure still collapses to the caller's generic error, while a
    // caller-actionable errno still survives.
    var drv2: MySQLDriver = .{ .conn = undefined, .allocator = undefined };
    try std.testing.expect(drv2.classifyFailure(1142) == null); // ER_TABLEACCESS_DENIED_ERROR -> ExecFailed
    try std.testing.expect(!drv2.dead);
    try std.testing.expectEqual(driver.Error.UniqueViolation, drv2.classifyFailure(1062).?); // ER_DUP_ENTRY
}

test "MySQL: prepare failure on a lost connection marks the driver dead and reports ConnectionFailed" {
    // Defect C (path 1): `prepareMySQLStmt` used to return MySQLStmtFailed
    // without calling markDead, so the pool would hand the lost handle to the
    // next borrower and the error looked like a bad statement.
    var drv = try disconnectedDriver();
    defer drv.close();
    try std.testing.expectError(error.ConnectionFailed, prepareMySQLStmt(&drv, "SELECT 1"));
    try std.testing.expect(drv.dead);
}

test "MySQL: store_result failure on a lost connection marks the driver dead and reports ConnectionFailed" {
    // Defect C (path 2), the `query` store_result branch. Without a server the
    // statement can neither be prepared nor executed, so this asserts the
    // decision the branch now shares with the prepare path above (which is
    // exercised end to end) rather than the C call that cannot run here. Before
    // the fix the branch neither marked the handle dead nor reported the lost
    // connection — and it is the branch that runs after a result set is
    // fetched, where a dropped connection is most likely.
    var drv: MySQLDriver = .{ .conn = undefined, .allocator = undefined };
    try std.testing.expectEqual(driver.Error.ConnectionFailed, drv.classifyFailure(2013).?);
    try std.testing.expect(drv.dead);
}

test "MySQL: tx deinit keeps in_tx set when the rollback fails" {
    // Defect E: deinit used to clear `in_tx` before issuing ROLLBACK, so a
    // rollback that failed for a non-connection reason left the flag false
    // while the server-side transaction stayed open — and ConnPool.release
    // reads `inTransaction()` to decide whether it must clean the connection
    // up before reuse. The failure is injected through the allocation `exec`
    // does for the NUL-terminated SQL, so it is a non-connection failure
    // (OutOfMemory) and the driver is not marked dead: the connection is one
    // the pool would otherwise consider reusable.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var drv: MySQLDriver = .{
        .conn = undefined,
        .allocator = failing.allocator(),
        .in_tx = true,
    };
    const tx = try std.testing.allocator.create(MySQLTx);
    tx.* = .{ .driver = &drv, .state = .active };
    MySQLTx.deinit(tx);
    try std.testing.expect(!drv.dead);
    try std.testing.expect(drv.inTransaction());
}

/// A real libmariadb handle that was never connected. Every C call on it fails
/// with errno 2006 ("server has gone away") without a server, which is how the
/// lost-connection paths are reached in these tests.
fn disconnectedDriver() !MySQLDriver {
    return .{
        .conn = c.mysql_init(null) orelse return error.MySQLInitFailed,
        .allocator = std.testing.allocator,
    };
}
