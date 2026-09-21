const std = @import("std");
const c = @import("pg_c");
const Value = @import("builder.zig").Value;
const Dialect = @import("dialect.zig").Dialect;
const driver = @import("driver.zig");
const cache_mod = @import("cache.zig");

const PreparedCache = cache_mod.PreparedCache;

const PG_ERRBUF_SIZE = 256;

/// Copy a failed result's SQLSTATE (e.g. `"42P01"`) into `allocator`, or null
/// when the result carries none.
fn dupeSqlstate(allocator: std.mem.Allocator, result: *c.PGresult) !?[]u8 {
    const field = c.PQresultErrorField(result, c.PG_DIAG_SQLSTATE) orelse return null;
    const sqlstate = std.mem.span(field);
    if (sqlstate.len == 0) return null;
    return try allocator.dupe(u8, sqlstate);
}

fn toDriverError(err: anyerror) driver.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PostgresConnectFailed => error.ConnectionFailed,
        error.PostgresExecFailed => error.ExecFailed,
        error.PostgresQueryFailed => error.QueryFailed,
        error.PostgresPingFailed => error.PingFailed,
        error.QueryTimeout => error.QueryTimeout,
        error.UniqueViolation => error.UniqueViolation,
        error.NotNullViolation => error.NotNullViolation,
        error.ForeignKeyViolation => error.ForeignKeyViolation,
        else => error.DriverFailed,
    };
}

/// What libpq's command tag said about the rows a command affected: the count,
/// and whether it reported one at all.
///
/// An empty tag is **not** "zero rows". `PQcmdTuples` is `""` for every command
/// that reports no such count — DDL, `BEGIN`/`COMMIT`, `SET`, `VACUUM`,
/// `ANALYZE`, `DO`, `TRUNCATE` all come back as `PGRES_COMMAND_OK` with an empty
/// tag, and `TRUNCATE` is the pointed example: it removes every row and still
/// reports nothing. Reporting 0 for those is indistinguishable from a statement
/// that really matched no rows, which is what `UpdateBuilder.Save` (version
/// lock) and `SaveOne` read as `OptimisticLockConflict` / `error.NotFound`.
///
/// `known` is false only for the empty tag; a decimal tag — including `"0"`,
/// which a `SELECT`, an `UPDATE` or a `DELETE` really does report — is a count
/// the driver obtained.
const ReportedRows = struct {
    rows: usize,
    known: bool,
};

fn reportedRowsFromCommandTag(tag: []const u8) error{DriverFailed}!ReportedRows {
    if (tag.len == 0) return .{ .rows = 0, .known = false };
    const rows = std.fmt.parseInt(usize, tag, 10) catch {
        std.log.warn("postgres: PQcmdTuples reported a row count of '{s}', which is not a number", .{tag});
        return error.DriverFailed;
    };
    return .{ .rows = rows, .known = true };
}

pub const PostgresDriver = struct {
    conn: *c.PGconn,
    allocator: std.mem.Allocator,
    /// Optional prepared-statement cache. When set, exec() reuses named
    /// prepared statements via PQprepare / PQexecPrepared.
    cache: ?PreparedCache(16, *c.PGresult) = null,
    /// SSL/TLS mode for connections.
    ssl_mode: SslMode = .prefer,
    /// Set once libpq reports the connection is gone, so the pool can discard it
    /// instead of handing it to the next borrower.
    ///
    /// `ConnPool` already evicts a released connection whose type has a `dead`
    /// field (it is how the MySQL driver works); PostgreSQL had no such field, so
    /// a connection that failed with `ConnectionFailed` — a server restart, a
    /// `pg_terminate_backend`, an idle-timeout kill — went straight back into the
    /// pool and kept failing for whoever borrowed it next.
    ///
    /// Marked from `PQstatus`, i.e. lazily: libpq learns the connection is gone
    /// when an I/O attempt fails, so the *failing* call marks it (via `noteError`)
    /// and the next borrower fails fast instead of talking to a corpse. At most
    /// one request pays for a break.
    dead: bool = false,

    /// Statement timeout currently set on this connection, in milliseconds.
    /// `null` means the server DEFAULT (no timeout). Tracked so a statement
    /// only pays a `SET statement_timeout` round trip when the desired value
    /// actually differs from what the connection already has.
    current_statement_timeout_ms: ?u32 = null,

    pub const SslMode = enum { disable, require, prefer, verify_full };

    /// Fail fast on a connection that is already known to be gone: every
    /// operation would fail anyway, and the caller (the pool) is about to
    /// discard it.
    fn ensureAlive(self: *PostgresDriver) driver.Error!void {
        if (self.dead or c.PQstatus(self.conn) != c.CONNECTION_OK) {
            self.dead = true;
            return error.ConnectionFailed;
        }
    }

    /// Route an error through the connection's health: a `ConnectionFailed` means
    /// the socket is unusable, so the pool must not see this connection again.
    fn noteError(self: *PostgresDriver, err: driver.Error) driver.Error {
        if (err == error.ConnectionFailed or c.PQstatus(self.conn) != c.CONNECTION_OK) self.dead = true;
        return err;
    }

    pub fn connect(allocator: std.mem.Allocator, conninfo: []const u8) !PostgresDriver {
        // libpq expects a null-terminated string
        const conninfo_z = try allocator.dupeSentinel(u8, conninfo, 0);
        defer allocator.free(conninfo_z);

        const conn = c.PQconnectdb(conninfo_z.ptr) orelse return error.PostgresConnectFailed;
        if (c.PQstatus(conn) != c.CONNECTION_OK) {
            defer c.PQfinish(conn);
            const msg = c.PQerrorMessage(conn);
            // warn (not err): a refused connection is an expected, recoverable
            // outcome (server not running / integration-test skip path), and
            // the test framework fails on err-level logs even in skipped tests.
            std.log.warn("postgres connect failed: {s}", .{std.mem.span(msg)});
            return error.PostgresConnectFailed;
        }
        // Set client encoding to UTF8 for consistent text handling.
        {
            const set_res = c.PQexec(conn, "SET client_encoding = 'UTF8'");
            defer c.PQclear(set_res);
        }
        return PostgresDriver{ .conn = conn, .allocator = allocator };
    }

    pub fn connectDb(allocator: std.mem.Allocator, host: []const u8, port: u16, dbname: []const u8, user: []const u8, password: []const u8) !PostgresDriver {
        const conninfo = try std.fmt.allocPrint(
            allocator,
            "host={s} port={d} dbname={s} user={s} password={s} sslmode=prefer connect_timeout=10",
            .{ host, port, dbname, user, password },
        );
        defer allocator.free(conninfo);
        return connect(allocator, conninfo);
    }

    pub fn close(self: *PostgresDriver) void {
        if (self.cache) |*cch| {
            cch.evictAll(self, struct {
                fn f(ctx: anytype, h: *c.PGresult) void {
                    _ = ctx;
                    c.PQclear(h);
                }
            }.f);
        }
        c.PQfinish(self.conn);
    }

    fn logPgError(conn: *c.PGconn, context: []const u8) void {
        const msg = c.PQerrorMessage(conn);
        // `warn`, not `err`: a failed statement is the caller's to handle (a
        // constraint violation, a deadlock, an expected 4xx), and the caller already
        // receives the error. Error level would mean double-reporting into whatever
        // alerts on it — and, concretely, a test could not exercise a failure path at
        // all, because Zig's test runner treats a logged error as a test failure.
        // `connect` failures have been `warn` for the same reason.
        std.log.warn("postgres error ({s}): {s}", .{ context, std.mem.span(msg) });
    }

    /// Extract diagnostic detail from a PGresult for richer error logging.
    fn logPgResultError(conn: *c.PGconn, result: ?*c.PGresult, context: []const u8) void {
        const table = if (result) |r| c.PQresultErrorField(r, c.PG_DIAG_TABLE_NAME) else null;
        const column = if (result) |r| c.PQresultErrorField(r, c.PG_DIAG_COLUMN_NAME) else null;
        const detail = if (result) |r| c.PQresultErrorField(r, c.PG_DIAG_MESSAGE_DETAIL) else null;
        if (table != null or column != null) {
            if (detail) |d| {
                std.log.warn("postgres ({s}) table={s} col={s}: {s}", .{
                    context,
                    if (table) |t| std.mem.span(t) else "?",
                    if (column) |col| std.mem.span(col) else "?",
                    std.mem.span(d),
                });
                return;
            }
        }
        logPgError(conn, context);
    }

    /// Apply the statement timeout requested by `ctx`, sending a `SET` only
    /// when the connection's current value differs from `desired`.
    ///
    /// This removes the per-statement round-trip tax the old implementation
    /// paid: a statement with no deadline previously issued both a leading
    /// `SET ... = DEFAULT`-or-timeout and an unconditional trailing
    /// `SET statement_timeout = DEFAULT`. Now a statement with no deadline
    /// costs zero extra round trips, and a statement with a deadline only pays
    /// when the deadline differs from the last value applied.
    ///
    /// Leaving a non-default value on a pooled connection is safe: the next
    /// statement either sets its own deadline or restores DEFAULT here,
    /// because `current_statement_timeout_ms` travels with the connection.
    fn applyStatementTimeout(self: *PostgresDriver, ctx: ?*const driver.ExecutionContext) driver.Error!void {
        const desired: ?u32 = if (ctx) |exec_ctx| exec_ctx.remainingMs() else null;
        if (desired) |ms| {
            // An already-expired deadline must fail before touching the wire.
            if (ms == 0) return error.QueryTimeout;
        }
        if (self.current_statement_timeout_ms == desired) return;

        const sql = if (desired) |ms|
            try std.fmt.allocPrint(self.allocator, "SET statement_timeout = '{d}ms'", .{ms})
        else
            try self.allocator.dupe(u8, "SET statement_timeout = DEFAULT");
        defer self.allocator.free(sql);
        const sql_z = try self.allocator.dupeSentinel(u8, sql, 0);
        defer self.allocator.free(sql_z);

        const res = c.PQexecParams(self.conn, sql_z.ptr, 0, null, null, null, null, 0);
        if (res == null) return self.noteError(error.ConnectionFailed);
        defer c.PQclear(res);
        const status = c.PQresultStatus(res);
        if (status != c.PGRES_COMMAND_OK) return self.noteError(sqlstateToError(res.?));
        self.current_statement_timeout_ms = desired;
    }

    /// Free all parameters that were allocated (int, float, string, bytes).
    /// Bool params point to static "t"/"f" strings and are not freed.
    /// Uses the saved allocation length (NOT std.mem.span) so that values
    /// containing embedded NULs are freed correctly.
    fn freeParams(
        allocator: std.mem.Allocator,
        paramValues: std.ArrayListUnmanaged(?[*:0]const u8),
        owned_lens: *std.ArrayListUnmanaged(?usize),
    ) void {
        for (paramValues.items, 0..) |pv, i| {
            if (pv) |_| {
                if (owned_lens.items[i]) |len| {
                    // The allocated buffer started at pv; we know its size.
                    const base: [*]u8 = @ptrCast(@constCast(pv));
                    allocator.free(base[0..len]);
                }
            }
        }
        owned_lens.deinit(allocator);
    }

    fn bindParams(
        allocator: std.mem.Allocator,
        args: []const Value,
        paramValues: *std.ArrayListUnmanaged(?[*:0]const u8),
        paramLengths: *std.ArrayListUnmanaged(c_int),
        paramFormats: *std.ArrayListUnmanaged(c_int),
        owned_lens: *std.ArrayListUnmanaged(?usize),
    ) !void {
        try paramValues.resize(allocator, args.len);
        try paramLengths.resize(allocator, args.len);
        try paramFormats.resize(allocator, args.len);
        try owned_lens.resize(allocator, args.len);
        @memset(owned_lens.items, null);

        for (args, 0..) |arg, i| {
            switch (arg) {
                .null => {
                    paramValues.items[i] = null;
                    paramLengths.items[i] = 0;
                    paramFormats.items[i] = 0;
                },
                .bool => |v| {
                    const s = if (v) "t" else "f";
                    paramValues.items[i] = @ptrCast(s.ptr);
                    paramLengths.items[i] = @intCast(s.len);
                    paramFormats.items[i] = 0;
                },
                .int => |v| {
                    const s = try std.fmt.allocPrintSentinel(allocator, "{d}\x00", .{v}, 0);
                    paramValues.items[i] = s.ptr;
                    paramLengths.items[i] = @intCast(s.len - 1); // libpq reads by len, no NUL
                    paramFormats.items[i] = 0;
                    owned_lens.items[i] = s.len + 1;
                },
                .float => |v| {
                    const s = try std.fmt.allocPrintSentinel(allocator, "{d}\x00", .{v}, 0);
                    paramValues.items[i] = s.ptr;
                    paramLengths.items[i] = @intCast(s.len - 1);
                    paramFormats.items[i] = 0;
                    owned_lens.items[i] = s.len + 1;
                },
                .string => |v| {
                    // dupeZ appends a NUL; we own the full buffer.
                    const s = try allocator.dupeSentinel(u8, v, 0);
                    paramValues.items[i] = s.ptr;
                    paramLengths.items[i] = @intCast(v.len);
                    paramFormats.items[i] = 0;
                    owned_lens.items[i] = s.len + 1;
                },
                .bytes => |v| {
                    const s = try allocator.dupeSentinel(u8, v, 0);
                    paramValues.items[i] = s.ptr;
                    paramLengths.items[i] = @intCast(v.len);
                    paramFormats.items[i] = 1; // binary format
                    owned_lens.items[i] = s.len + 1;
                },
            }
        }
    }

    /// Map a SQLSTATE error code to driver.Error for precise diagnostics.
    fn sqlstateToError(result: *c.PGresult) driver.Error {
        const field = c.PQresultErrorField(result, c.PG_DIAG_SQLSTATE) orelse return error.DriverFailed;
        return sqlstateCodeToError(std.mem.span(field));
    }

    /// The classification above, on the code alone, so it can be pinned by a
    /// test: a `PGresult` is what the call sites have, and one is not
    /// constructible without a server.
    fn sqlstateCodeToError(sqlstate: []const u8) driver.Error {
        if (sqlstate.len < 2) return error.DriverFailed;
        if (sqlstate.len >= 5) {
            if (std.mem.eql(u8, sqlstate[0..5], "57014")) return error.QueryTimeout;
            // Retryable transaction-abort conditions (see driver.isRetryable):
            // 40P01 deadlock_detected, 40001 serialization_failure,
            // 55P03 lock_not_available.
            if (std.mem.eql(u8, sqlstate[0..5], "40P01")) return error.DeadlockDetected;
            if (std.mem.eql(u8, sqlstate[0..5], "40001")) return error.SerializationFailure;
            if (std.mem.eql(u8, sqlstate[0..5], "55P03")) return error.LockTimeout;
        }
        return switch (sqlstate[0]) {
            '0' => if (sqlstate[1] == '8') error.ConnectionFailed else error.DriverFailed,
            '2' => switch (sqlstate[1]) {
                // Integrity constraint violation: classify the common codes.
                //
                // The class is the first **two** characters (`23`), so the
                // specific condition sits at offset 3 — offset 2 is `5` for the
                // whole `235xx` family. Reading it there made `23502`
                // (not_null) and `23503` (foreign_key) answer
                // `UniqueViolation`, the third code to arrive in that family.
                // Measured through `dialect_matrix`'s foreign-key case: a
                // dangling reference came back as `UniqueViolation` on
                // PostgreSQL while SQLite and MySQL answered
                // `ForeignKeyViolation`.
                '3' => if (sqlstate.len >= 5) switch (sqlstate[3]) {
                    '0' => switch (sqlstate[4]) {
                        '5' => error.UniqueViolation, // 23505 unique_violation
                        '2' => error.NotNullViolation, // 23502 not_null_violation
                        '3' => error.ForeignKeyViolation, // 23503 foreign_key_violation
                        else => error.ExecFailed,
                    },
                    else => error.ExecFailed,
                } else error.ExecFailed,
                '2', '8' => error.ExecFailed,
                '5', 'D' => error.TxFailed,
                else => error.DriverFailed,
            },
            '3' => if (sqlstate[1] == 'D') error.ExecFailed else error.DriverFailed,
            '4' => switch (sqlstate[1]) {
                '0' => error.TxFailed,
                '2' => error.ExecFailed,
                else => error.DriverFailed,
            },
            '5' => switch (sqlstate[1]) {
                '3' => error.ConnectionFailed,
                '7', '8' => error.ExecFailed,
                else => error.DriverFailed,
            },
            else => error.DriverFailed,
        };
    }

    pub fn exec(self: *PostgresDriver, sql: []const u8, args: []const Value) driver.Error!driver.Result {
        try self.ensureAlive();
        const sql_z = try self.allocator.dupeSentinel(u8, sql, 0);
        defer self.allocator.free(sql_z);

        var paramValues: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
        var paramLengths: std.ArrayListUnmanaged(c_int) = .empty;
        var paramFormats: std.ArrayListUnmanaged(c_int) = .empty;
        var owned_lens: std.ArrayListUnmanaged(?usize) = .empty;
        defer {
            freeParams(self.allocator, paramValues, &owned_lens);
            paramValues.deinit(self.allocator);
            paramLengths.deinit(self.allocator);
            paramFormats.deinit(self.allocator);
        }

        try bindParams(self.allocator, args, &paramValues, &paramLengths, &paramFormats, &owned_lens);

        // DDL invalidates every cached prepared statement.
        if (self.cache) |*cch| {
            if (cache_mod.isDDL(sql)) {
                cch.evictAll(self, struct {
                    fn f(ctx: anytype, h: *c.PGresult) void {
                        _ = ctx;
                        c.PQclear(h);
                    }
                }.f);
            }
        }

        // Use named prepared statements when cache is enabled and we have args.
        if (self.cache != null and args.len > 0) {
            const cch = &self.cache.?;
            const hash = std.hash.Wyhash.hash(0, sql);
            var name_buf: [20]u8 = std.mem.zeroes([20]u8);
            const name_str = std.fmt.bufPrint(&name_buf, "p_{x}", .{hash}) catch {
                std.log.err("postgres: bufPrint for prepared name failed", .{});
                return error.DriverFailed;
            };
            const name_z: [*:0]const u8 = @ptrCast(name_str.ptr);

            const PrepareCtx = struct {
                conn: *c.PGconn,
                name: [*:0]const u8,
                sql: [*:0]const u8,
                nParams: c_int,
            };
            const pctx = PrepareCtx{
                .conn = self.conn,
                .name = name_z,
                .sql = sql_z.ptr,
                .nParams = @intCast(args.len),
            };

            _ = cch.getOrPrepare(sql, pctx, struct {
                fn f(ctx: PrepareCtx, s: []const u8) !*c.PGresult {
                    _ = s;
                    const res = c.PQprepare(ctx.conn, ctx.name, ctx.sql, ctx.nParams, null) orelse {
                        logPgError(ctx.conn, "PQprepare");
                        return error.DriverFailed;
                    };
                    if (c.PQresultStatus(res) != c.PGRES_COMMAND_OK) {
                        logPgError(ctx.conn, "PQprepare");
                        return sqlstateToError(res);
                    }
                    return res;
                }
            }.f, self, struct {
                fn f(ctx: anytype, h: *c.PGresult) void {
                    _ = ctx;
                    c.PQclear(h);
                }
            }.f) catch |err| return self.noteError(if (err == error.OutOfMemory) error.OutOfMemory else error.DriverFailed);

            const res = c.PQexecPrepared(
                self.conn,
                name_z,
                @intCast(args.len),
                paramValues.items.ptr,
                paramLengths.items.ptr,
                paramFormats.items.ptr,
                0, // text results
            );
            if (res == null) {
                logPgError(self.conn, "exec-prepared");
                return error.DriverFailed;
            }
            defer c.PQclear(res);

            const status = c.PQresultStatus(res);
            if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) {
                logPgResultError(self.conn, res, "exec-prepared");
                return self.noteError(sqlstateToError(res.?));
            }

            const affected = c.PQcmdTuples(res);
            const reported = try reportedRowsFromCommandTag(if (affected) |a| std.mem.span(a) else "");

            var last_insert_id: ?i64 = null;
            if (c.PQntuples(res) > 0) {
                const oid_value = c.PQgetvalue(res, 0, 0);
                if (oid_value) |val| {
                    last_insert_id = std.fmt.parseInt(i64, std.mem.span(val), 10) catch null;
                }
            }

            return driver.Result{
                .rows_affected = reported.rows,
                .rows_affected_known = reported.known,
                .last_insert_id = last_insert_id,
            };
        }

        // Fallback: PQexecParams (no cache, or no args).
        const res = c.PQexecParams(
            self.conn,
            sql_z.ptr,
            @intCast(args.len),
            null, // let libpq infer param types from text
            paramValues.items.ptr,
            paramLengths.items.ptr,
            paramFormats.items.ptr,
            0, // text results
        );
        if (res == null) {
            logPgError(self.conn, "exec");
            return error.DriverFailed;
        }
        defer c.PQclear(res);

        const status = c.PQresultStatus(res);
        if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) {
            logPgResultError(self.conn, res, "exec");
            return self.noteError(sqlstateToError(res.?));
        }

        const affected = c.PQcmdTuples(res);
        const reported = try reportedRowsFromCommandTag(if (affected) |a| std.mem.span(a) else "");

        // Get last insert id from RETURNING clause if present, or use oid
        var last_insert_id: ?i64 = null;
        if (c.PQntuples(res) > 0) {
            const oid_value = c.PQgetvalue(res, 0, 0);
            if (oid_value) |val| {
                last_insert_id = std.fmt.parseInt(i64, std.mem.span(val), 10) catch null;
            }
        }

        return driver.Result{
            .rows_affected = reported.rows,
            .rows_affected_known = reported.known,
            .last_insert_id = last_insert_id,
        };
    }

    pub fn query(self: *PostgresDriver, query_sql: []const u8, args: []const Value) !driver.Rows {
        try self.ensureAlive();
        const sql_z = try self.allocator.dupeSentinel(u8, query_sql, 0);
        defer self.allocator.free(sql_z);

        var paramValues: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
        var paramLengths: std.ArrayListUnmanaged(c_int) = .empty;
        var paramFormats: std.ArrayListUnmanaged(c_int) = .empty;
        var owned_lens: std.ArrayListUnmanaged(?usize) = .empty;
        defer {
            freeParams(self.allocator, paramValues, &owned_lens);
            paramValues.deinit(self.allocator);
            paramLengths.deinit(self.allocator);
            paramFormats.deinit(self.allocator);
        }

        try bindParams(self.allocator, args, &paramValues, &paramLengths, &paramFormats, &owned_lens);

        const res = c.PQexecParams(
            self.conn,
            sql_z.ptr,
            @intCast(args.len),
            null,
            paramValues.items.ptr,
            paramLengths.items.ptr,
            paramFormats.items.ptr,
            0,
        );
        if (res == null) {
            logPgError(self.conn, "query");
            return error.DriverFailed;
        }
        errdefer c.PQclear(res);

        const status = c.PQresultStatus(res);
        if (status != c.PGRES_TUPLES_OK) {
            const err = self.noteError(sqlstateToError(res.?));
            // A statement timeout is the intended outcome of withTimeout,
            // not a fault — don't log it as an error.
            // Timeouts and constraint violations are intended outcomes
            // (e.g. upsert probing for UniqueViolation) — don't log them
            // as errors.
            if (err != error.QueryTimeout and err != error.UniqueViolation and
                err != error.NotNullViolation and err != error.ForeignKeyViolation)
            {
                logPgResultError(self.conn, res, "query");
            }
            return err;
        }

        const rows_ptr = try self.allocator.create(PostgresRows);
        errdefer self.allocator.destroy(rows_ptr);
        rows_ptr.* = PostgresRows{
            .result = res.?,
            .allocator = self.allocator,
            .row_index = 0,
            .num_rows = @intCast(c.PQntuples(res)),
            .num_fields = @intCast(c.PQnfields(res)),
        };
        // result ownership transferred to PostgresRows
        _ = &res;

        return driver.Rows{
            .ptr = rows_ptr,
            .vtable = &PostgresRows.vtable,
        };
    }

    pub fn ping(self: *PostgresDriver) !void {
        const result = c.PQexec(self.conn, "SELECT 1");
        defer c.PQclear(result);
        if (c.PQresultStatus(result) != c.PGRES_TUPLES_OK) {
            logPgError(self.conn, "ping");
            return error.PostgresPingFailed;
        }
    }

    /// Parse and plan `sql` on the server with `args` parameters, then discard
    /// the unnamed prepared statement: `PQprepare` sends Parse + Describe and
    /// stops there, so nothing in `sql` runs.
    ///
    /// `PQprepare` treats `nParams == 0` as "infer", not as "no parameters", so
    /// the parameter count is read back with `PQdescribePrepared` instead of
    /// being taken from `args.len`. That also catches the opposite case —
    /// PostgreSQL accepts a Parse that declares more parameters than the
    /// statement uses, so without the Describe an over-supplied `args` would go
    /// unnoticed here (`PQexecParams` accepts it too, but MySQL's driver and
    /// SQLite's parameter list do not, and one answer across the three is worth
    /// more than matching PostgreSQL's laxity).
    ///
    /// Not logged, unlike the exec path: a statement that fails to prepare is
    /// the expected outcome of a check.
    pub fn prepareCheck(self: *PostgresDriver, allocator: std.mem.Allocator, sql: []const u8, args: []const Value, out: *driver.CheckReport) driver.Error!void {
        try self.ensureAlive();
        const sql_z = try self.allocator.dupeSentinel(u8, sql, 0);
        defer self.allocator.free(sql_z);

        const res = c.PQprepare(self.conn, "", sql_z.ptr, @intCast(args.len), null) orelse {
            return self.noteError(error.DriverFailed);
        };
        defer c.PQclear(res);

        if (c.PQresultStatus(res) != c.PGRES_COMMAND_OK) {
            out.* = .{
                .kind = .prepare_failed,
                .sqlstate = try dupeSqlstate(allocator, res),
                .message = try allocator.dupe(u8, std.mem.span(c.PQresultErrorMessage(res))),
            };
            return;
        }

        // A statement that prepared is a statement that prepares; a Describe
        // that fails is not evidence against it, so the count is left unknown
        // rather than turned into a verdict.
        const described = c.PQdescribePrepared(self.conn, "") orelse {
            out.* = .{ .kind = .ok };
            return;
        };
        defer c.PQclear(described);
        if (c.PQresultStatus(described) != c.PGRES_COMMAND_OK) {
            out.* = .{ .kind = .ok };
            return;
        }

        const n_params: usize = @intCast(c.PQnparams(described));
        out.* = if (n_params == args.len)
            .{ .kind = .ok, .param_count = n_params }
        else
            .{ .kind = .param_mismatch, .param_count = n_params };
    }

    /// Returns true if the connection currently has an active transaction.
    pub fn inTransaction(self: *PostgresDriver) bool {
        const status = c.PQtransactionStatus(self.conn);
        return status != c.PQTRANS_IDLE and status != c.PQTRANS_UNKNOWN;
    }

    pub fn beginTx(self: *PostgresDriver) !driver.Tx {
        try self.ensureAlive();
        _ = try self.exec("BEGIN", &.{});

        const tx_ptr = try self.allocator.create(PostgresTx);
        errdefer self.allocator.destroy(tx_ptr);
        tx_ptr.* = PostgresTx{
            .driver = self,
            .state = .active,
        };

        return driver.Tx{
            .inner = self.asDriver(),
            .commitFn = PostgresTx.commit,
            .rollbackFn = PostgresTx.rollback,
            .deinitFn = PostgresTx.deinit,
            .savepointFn = struct {
                fn f(ptr: *anyopaque, name: []const u8) driver.Error!void {
                    const self_ptr: *PostgresDriver = @ptrCast(@alignCast(ptr));
                    return execSavepointStmt(self_ptr, "SAVEPOINT", name) catch |err| return toDriverError(err);
                }
            }.f,
            .savepointRollbackFn = struct {
                fn f(ptr: *anyopaque, name: []const u8) driver.Error!void {
                    const self_ptr: *PostgresDriver = @ptrCast(@alignCast(ptr));
                    return execSavepointStmt(self_ptr, "ROLLBACK TO", name) catch |err| return toDriverError(err);
                }
            }.f,
            .savepointReleaseFn = struct {
                fn f(ptr: *anyopaque, name: []const u8) driver.Error!void {
                    const self_ptr: *PostgresDriver = @ptrCast(@alignCast(ptr));
                    return execSavepointStmt(self_ptr, "RELEASE", name) catch |err| return toDriverError(err);
                }
            }.f,
            .ptr = tx_ptr,
        };
    }

    /// Open a nested savepoint on an already-active transaction.
    pub fn beginSavepoint(self: *PostgresDriver, name: []const u8) !driver.Tx {
        try execSavepointStmt(self, "SAVEPOINT", name);
        const sp = try self.allocator.create(PostgresSavepoint);
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
                    const s: *PostgresSavepoint = @ptrCast(@alignCast(ptr));
                    return s.commit() catch |err| return toDriverError(err);
                }
            }.f,
            .rollbackFn = struct {
                fn f(ptr: *anyopaque) driver.Error!void {
                    const s: *PostgresSavepoint = @ptrCast(@alignCast(ptr));
                    return s.rollback() catch |err| return toDriverError(err);
                }
            }.f,
            .deinitFn = struct {
                fn f(ptr: *anyopaque) void {
                    const s: *PostgresSavepoint = @ptrCast(@alignCast(ptr));
                    s.deinit();
                }
            }.f,
            .ptr = sp,
        };
    }

    pub fn asDriver(self: *PostgresDriver) driver.Driver {
        return driver.Driver{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = driver.Driver.VTable{
        .exec = struct {
            fn f(ptr: *anyopaque, ctx: ?*const driver.ExecutionContext, q: []const u8, a: []const Value) driver.Error!driver.Result {
                const self_ptr: *PostgresDriver = @ptrCast(@alignCast(ptr));
                // applyStatementTimeout only sends SET when the desired value
                // differs from the connection's current one, so there is no
                // trailing reset to defer (and no defer-before-query hazard).
                try self_ptr.applyStatementTimeout(ctx);
                return self_ptr.exec(q, a) catch |err| return toDriverError(err);
            }
        }.f,
        .query = struct {
            fn f(ptr: *anyopaque, ctx: ?*const driver.ExecutionContext, q: []const u8, a: []const Value) driver.Error!driver.Rows {
                const self_ptr: *PostgresDriver = @ptrCast(@alignCast(ptr));
                // See note in .exec above.
                try self_ptr.applyStatementTimeout(ctx);
                return self_ptr.query(q, a) catch |err| return toDriverError(err);
            }
        }.f,
        .prepareCheck = struct {
            fn f(ptr: *anyopaque, allocator: std.mem.Allocator, q: []const u8, a: []const Value, out: *driver.CheckReport) driver.Error!void {
                const self_ptr: *PostgresDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.prepareCheck(allocator, q, a, out);
            }
        }.f,
        .beginTx = struct {
            fn f(ptr: *anyopaque) driver.Error!driver.Tx {
                const self_ptr: *PostgresDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.beginTx() catch |err| return toDriverError(err);
            }
        }.f,
        .close = struct {
            fn f(ptr: *anyopaque) void {
                const self_ptr: *PostgresDriver = @ptrCast(@alignCast(ptr));
                self_ptr.close();
            }
        }.f,
        .dialect = struct {
            fn f(_: *anyopaque) Dialect {
                return Dialect.postgres;
            }
        }.f,
        .ping = struct {
            fn f(ptr: *anyopaque) driver.Error!void {
                const self_ptr: *PostgresDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.ping() catch |err| return toDriverError(err);
            }
        }.f,
        .inTransaction = struct {
            fn f(ptr: *anyopaque) bool {
                const self_ptr: *PostgresDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.inTransaction();
            }
        }.f,
        .beginSavepoint = struct {
            fn f(ptr: *anyopaque, name: []const u8) driver.Error!driver.Tx {
                const self_ptr: *PostgresDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.beginSavepoint(name) catch |err| return toDriverError(err);
            }
        }.f,
    };
};

fn execSavepointStmt(d: *PostgresDriver, stmt: []const u8, name: []const u8) !void {
    const sql = try std.fmt.allocPrint(d.allocator, "{s} \"{s}\"", .{ stmt, name });
    defer d.allocator.free(sql);
    _ = try d.exec(sql, &.{});
}

const PostgresSavepoint = struct {
    driver: *PostgresDriver,
    name: []u8,
    active: bool,

    fn commit(self: *PostgresSavepoint) !void {
        if (!self.active) return;
        try execSavepointStmt(self.driver, "RELEASE", self.name);
        self.active = false;
    }

    fn rollback(self: *PostgresSavepoint) !void {
        if (!self.active) return;
        try execSavepointStmt(self.driver, "ROLLBACK TO", self.name);
        self.active = false;
    }

    fn deinit(self: *PostgresSavepoint) void {
        self.rollback() catch |err| {
            std.log.warn("postgres savepoint deinit: rollback failed ({s})", .{@errorName(err)});
        };
        self.driver.allocator.free(self.name);
        self.driver.allocator.destroy(self);
    }
};

const PostgresTx = struct {
    driver: *PostgresDriver,
    state: enum { active, committed, rolled_back },

    fn commit(ptr: *anyopaque) driver.Error!void {
        const self: *PostgresTx = @ptrCast(@alignCast(ptr));
        if (self.state != .active) return;
        _ = self.driver.exec("COMMIT", &.{}) catch |err| return toDriverError(err);
        self.state = .committed;
    }

    fn rollback(ptr: *anyopaque) driver.Error!void {
        const self: *PostgresTx = @ptrCast(@alignCast(ptr));
        if (self.state != .active) return;
        _ = self.driver.exec("ROLLBACK", &.{}) catch |err| return toDriverError(err);
        self.state = .rolled_back;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *PostgresTx = @ptrCast(@alignCast(ptr));
        if (self.state == .active) {
            _ = self.driver.exec("ROLLBACK", &.{}) catch |err| {
                std.log.warn("postgres tx deinit: rollback failed ({s})", .{@errorName(err)});
            };
        }
        self.driver.allocator.destroy(self);
    }
};

const PostgresRows = struct {
    result: *c.PGresult,
    allocator: std.mem.Allocator,
    row_index: c_int,
    num_rows: c_int,
    num_fields: c_int,

    const vtable = driver.Rows.VTable{
        .next = next,
        .deinit = deinit,
        .nextError = null,
    };

    fn next(ptr: *anyopaque) ?driver.Row {
        const self: *PostgresRows = @ptrCast(@alignCast(ptr));
        if (self.row_index >= self.num_rows) return null;
        const row = driver.Row{
            .ptr = self,
            .vtable = &row_vtable,
        };
        self.row_index += 1;
        return row;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *PostgresRows = @ptrCast(@alignCast(ptr));
        c.PQclear(self.result);
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
        .getBool = getBool,
        .isNull = isNull,
    };

    fn currentRow(self: *PostgresRows) c_int {
        return self.row_index - 1;
    }

    fn columnCount(ptr: *anyopaque) usize {
        const self: *PostgresRows = @ptrCast(@alignCast(ptr));
        return @intCast(self.num_fields);
    }

    fn columnName(ptr: *anyopaque, index: usize) []const u8 {
        const self: *PostgresRows = @ptrCast(@alignCast(ptr));
        const name = c.PQfname(self.result, @intCast(index));
        return std.mem.span(name);
    }

    fn getInt(ptr: *anyopaque, index: usize) ?i64 {
        const self: *PostgresRows = @ptrCast(@alignCast(ptr));
        if (c.PQgetisnull(self.result, self.currentRow(), @intCast(index)) != 0) return null;
        const val = c.PQgetvalue(self.result, self.currentRow(), @intCast(index));
        if (val == null) return null;
        return std.fmt.parseInt(i64, std.mem.span(val), 10) catch null;
    }

    fn getFloat(ptr: *anyopaque, index: usize) ?f64 {
        const self: *PostgresRows = @ptrCast(@alignCast(ptr));
        if (c.PQgetisnull(self.result, self.currentRow(), @intCast(index)) != 0) return null;
        const val = c.PQgetvalue(self.result, self.currentRow(), @intCast(index));
        if (val == null) return null;
        return std.fmt.parseFloat(f64, std.mem.span(val)) catch null;
    }

    fn getText(ptr: *anyopaque, index: usize) ?[]const u8 {
        const self: *PostgresRows = @ptrCast(@alignCast(ptr));
        if (c.PQgetisnull(self.result, self.currentRow(), @intCast(index)) != 0) return null;
        const val = c.PQgetvalue(self.result, self.currentRow(), @intCast(index));
        if (val == null) return null;
        return std.mem.span(val);
    }

    fn getBlob(ptr: *anyopaque, index: usize) ?[]const u8 {
        const self: *PostgresRows = @ptrCast(@alignCast(ptr));
        if (c.PQgetisnull(self.result, self.currentRow(), @intCast(index)) != 0) return null;
        var length: c_int = 0;
        const val = c.PQgetvalue(self.result, self.currentRow(), @intCast(index));
        if (val == null) return null;
        // For binary format, PQgetlength gives the byte length
        length = c.PQgetlength(self.result, self.currentRow(), @intCast(index));
        return val[0..@intCast(length)];
    }

    fn getBool(ptr: *anyopaque, index: usize) ?bool {
        const self: *PostgresRows = @ptrCast(@alignCast(ptr));
        if (c.PQgetisnull(self.result, self.currentRow(), @intCast(index)) != 0) return null;
        const val = c.PQgetvalue(self.result, self.currentRow(), @intCast(index));
        if (val == null) return null;
        return val[0] == 't';
    }

    fn isNull(ptr: *anyopaque, index: usize) bool {
        const self: *PostgresRows = @ptrCast(@alignCast(ptr));
        return c.PQgetisnull(self.result, self.currentRow(), @intCast(index)) != 0;
    }
};

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Postgres placeholder style" {
    var buf: [16]u8 = undefined;
    const ph = try Dialect.postgres.placeholder(&buf, 1);
    try std.testing.expectEqualStrings("$1", ph);
}

test "Postgres quote ident" {
    var buf: [64]u8 = undefined;
    const q = try Dialect.postgres.quoteIdent(&buf, "my_table");
    try std.testing.expectEqualStrings("\"my_table\"", q);
}

test "PostgresDriver cache field is optional" {
    // Verifies the cache field defaults to null and can be set.
    // `.{}`-style init with explicit placeholders: reading `cache` from an
    // `undefined` struct is UB and flaky across std/compiler versions.
    var drv: PostgresDriver = .{ .conn = undefined, .allocator = undefined };
    try std.testing.expect(drv.cache == null);

    drv.cache = PreparedCache(16, *c.PGresult){};
    try std.testing.expect(drv.cache != null);
}

test "PostgresDriver cache DDL eviction" {
    // DDL SQL should be detected and trigger cache eviction.
    var cch: PreparedCache(4, *c.PGresult) = .{};
    try std.testing.expectEqual(@as(usize, 0), cch.len);

    // Manually insert an entry (simulate a prepared statement).
    // We use getOrPrepare with a no-op prepare that returns a dummy pointer.
    const dummy: *c.PGresult = @ptrFromInt(0x1);
    _ = cch.getOrPrepare(
        "SELECT 1",
        dummy,
        struct {
            fn f(ctx: *c.PGresult, sql: []const u8) !*c.PGresult {
                _ = sql;
                return ctx;
            }
        }.f,
        dummy,
        struct {
            fn f(ctx: *c.PGresult, h: *c.PGresult) void {
                _ = ctx;
                _ = h;
            }
        }.f,
    ) catch unreachable;
    try std.testing.expectEqual(@as(usize, 1), cch.len);

    // Simulate DDL: evict all.
    try std.testing.expect(cache_mod.isDDL("CREATE TABLE foo (id INT)"));
    try std.testing.expect(cache_mod.isDDL("ALTER TABLE foo ADD x INT"));
    try std.testing.expect(cache_mod.isDDL("DROP TABLE foo"));
    try std.testing.expect(!cache_mod.isDDL("INSERT INTO foo VALUES (1)"));

    cch.evictAll(dummy, struct {
        fn f(ctx: *c.PGresult, h: *c.PGresult) void {
            _ = ctx;
            _ = h;
        }
    }.f);
    try std.testing.expectEqual(@as(usize, 0), cch.len);
}

test "PostgresDriver cache getOrPrepare hit" {
    var cch: PreparedCache(4, *c.PGresult) = .{};
    var prepare_count: usize = 0;

    const Ctx = struct {
        count: *usize,
    };
    var ctx = Ctx{ .count = &prepare_count };

    const h1 = try cch.getOrPrepare("SELECT 1", &ctx, struct {
        fn f(ctx_: *Ctx, sql: []const u8) !*c.PGresult {
            _ = sql;
            ctx_.count.* += 1;
            return @ptrFromInt(ctx_.count.*);
        }
    }.f, &ctx, struct {
        fn f(ctx_: *Ctx, h: *c.PGresult) void {
            _ = ctx_;
            _ = h;
        }
    }.f);
    try std.testing.expectEqual(@as(usize, 1), prepare_count);

    const h2 = try cch.getOrPrepare("SELECT 1", &ctx, struct {
        fn f(ctx_: *Ctx, sql: []const u8) !*c.PGresult {
            _ = sql;
            ctx_.count.* += 1;
            return @ptrFromInt(ctx_.count.*);
        }
    }.f, &ctx, struct {
        fn f(ctx_: *Ctx, h: *c.PGresult) void {
            _ = ctx_;
            _ = h;
        }
    }.f);
    // Same SQL should hit cache, no new prepare.
    try std.testing.expectEqual(h1, h2);
    try std.testing.expectEqual(@as(usize, 1), prepare_count);
}

test "PostgresDriver cache different SQL different entries" {
    var cch: PreparedCache(4, *c.PGresult) = .{};
    var prepare_count: usize = 0;

    const Ctx = struct {
        count: *usize,
    };
    var ctx = Ctx{ .count = &prepare_count };

    _ = try cch.getOrPrepare("SELECT 1", &ctx, struct {
        fn f(ctx_: *Ctx, sql: []const u8) !*c.PGresult {
            _ = sql;
            ctx_.count.* += 1;
            return @ptrFromInt(ctx_.count.*);
        }
    }.f, &ctx, struct {
        fn f(ctx_: *Ctx, h: *c.PGresult) void {
            _ = ctx_;
            _ = h;
        }
    }.f);
    _ = try cch.getOrPrepare("SELECT 2", &ctx, struct {
        fn f(ctx_: *Ctx, sql: []const u8) !*c.PGresult {
            _ = sql;
            ctx_.count.* += 1;
            return @ptrFromInt(ctx_.count.*);
        }
    }.f, &ctx, struct {
        fn f(ctx_: *Ctx, h: *c.PGresult) void {
            _ = ctx_;
            _ = h;
        }
    }.f);
    try std.testing.expectEqual(@as(usize, 2), prepare_count);
    try std.testing.expectEqual(@as(usize, 2), cch.len);
}

test "Postgres: only a reported decimal command tag counts as a known row count" {
    // `PQcmdTuples` is "" for every command that reports no row count — DDL,
    // BEGIN/COMMIT, SET, VACUUM, ANALYZE, DO, TRUNCATE — and libpq always prints
    // the count as decimal for the statements that do report one:
    //   CREATE TABLE -> ""      UPDATE ... WHERE id = -1 -> "0"
    //   COMMIT       -> ""      INSERT ... VALUES (...)  -> "1"
    //   TRUNCATE     -> ""
    // The empty tag is the only one that may become 0, and it must say it is not
    // a count: `TRUNCATE` removes every row and still reports nothing, so 0
    // there would be a count for a statement that emptied the table.
    const none = try reportedRowsFromCommandTag("");
    try std.testing.expectEqual(@as(usize, 0), none.rows);
    try std.testing.expect(!none.known);

    // A reported zero really is a count and has to stay known — this is the tag
    // an `UPDATE ... WHERE` that matched nothing produces, which is exactly what
    // the optimistic-lock check reads.
    const zero = try reportedRowsFromCommandTag("0");
    try std.testing.expectEqual(@as(usize, 0), zero.rows);
    try std.testing.expect(zero.known);

    const one = try reportedRowsFromCommandTag("1");
    try std.testing.expectEqual(@as(usize, 1), one.rows);
    try std.testing.expect(one.known);

    const many = try reportedRowsFromCommandTag("42");
    try std.testing.expectEqual(@as(usize, 42), many.rows);
    try std.testing.expect(many.known);

    // A tag that is neither: 0 here would be a lie no caller could detect —
    // `UpdateBuilder.Save` compares it against 0 for the version lock, and
    // `SaveOne` turns it into `error.NotFound`, so a write that did happen
    // would be reported as "no such row".
    try std.testing.expectError(error.DriverFailed, reportedRowsFromCommandTag("INSERT 0 1"));
    try std.testing.expectError(error.DriverFailed, reportedRowsFromCommandTag("-1"));
    try std.testing.expectError(error.DriverFailed, reportedRowsFromCommandTag("n/a"));
}

test "Postgres: the SQLSTATE of each constraint failure maps to its own error" {
    // The class is the first two characters, so the condition sits at offset 3:
    // every `235xx` code has `5` at offset 2, which is where the not-null and
    // foreign-key codes used to be read from — both answered `UniqueViolation`,
    // the code that happened to be first in that family.
    //
    // Measured (dialect_matrix's foreign-key case, PostgreSQL 17.10): a dangling
    // reference reported `dangling=UniqueViolation` on PostgreSQL while SQLite
    // and MySQL reported `ForeignKeyViolation` for the same statement. The
    // offset is the whole difference, so it is pinned here, code by code.
    try std.testing.expectEqual(driver.Error.UniqueViolation, PostgresDriver.sqlstateCodeToError("23505"));
    try std.testing.expectEqual(driver.Error.NotNullViolation, PostgresDriver.sqlstateCodeToError("23502"));
    try std.testing.expectEqual(driver.Error.ForeignKeyViolation, PostgresDriver.sqlstateCodeToError("23503"));

    // A `235xx` code this driver does not classify stays "a failed statement",
    // not a constraint name a caller would branch on.
    try std.testing.expectEqual(driver.Error.ExecFailed, PostgresDriver.sqlstateCodeToError("23514"));

    // The codes that were already right, so the fix above did not move them.
    try std.testing.expectEqual(driver.Error.QueryTimeout, PostgresDriver.sqlstateCodeToError("57014"));
    try std.testing.expectEqual(driver.Error.DeadlockDetected, PostgresDriver.sqlstateCodeToError("40P01"));
    try std.testing.expectEqual(driver.Error.SerializationFailure, PostgresDriver.sqlstateCodeToError("40001"));
    try std.testing.expectEqual(driver.Error.LockTimeout, PostgresDriver.sqlstateCodeToError("55P03"));
    try std.testing.expectEqual(driver.Error.ConnectionFailed, PostgresDriver.sqlstateCodeToError("08006"));
    try std.testing.expectEqual(driver.Error.TxFailed, PostgresDriver.sqlstateCodeToError("25P02"));

    // Shorter than a class: never read past the end for a code that has no
    // condition to read.
    try std.testing.expectEqual(driver.Error.DriverFailed, PostgresDriver.sqlstateCodeToError("2"));
    try std.testing.expectEqual(driver.Error.ExecFailed, PostgresDriver.sqlstateCodeToError("235"));
}
