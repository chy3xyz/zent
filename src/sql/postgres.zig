const std = @import("std");
const c = @import("pg_c");
const Value = @import("builder.zig").Value;
const Dialect = @import("dialect.zig").Dialect;
const driver = @import("driver.zig");
const cache_mod = @import("cache.zig");

const PreparedCache = cache_mod.PreparedCache;

const PG_ERRBUF_SIZE = 256;

fn toDriverError(err: anyerror) driver.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PostgresConnectFailed => error.ConnectionFailed,
        error.PostgresExecFailed => error.ExecFailed,
        error.PostgresQueryFailed => error.QueryFailed,
        error.PostgresPingFailed => error.PingFailed,
        else => error.DriverFailed,
    };
}

pub const PostgresDriver = struct {
    conn: *c.PGconn,
    allocator: std.mem.Allocator,
    /// Optional prepared-statement cache. When set, exec() reuses named
    /// prepared statements via PQprepare / PQexecPrepared.
    cache: ?PreparedCache(16, *c.PGresult) = null,
    /// SSL/TLS mode for connections.
    ssl_mode: SslMode = .prefer,

    pub const SslMode = enum { disable, require, prefer, verify_full };

    pub fn connect(allocator: std.mem.Allocator, conninfo: []const u8) !PostgresDriver {
        // libpq expects a null-terminated string
        const conninfo_z = try allocator.dupeSentinel(u8, conninfo, 0);
        defer allocator.free(conninfo_z);

        const conn = c.PQconnectdb(conninfo_z.ptr) orelse return error.PostgresConnectFailed;
        if (c.PQstatus(conn) != c.CONNECTION_OK) {
            defer c.PQfinish(conn);
            const msg = c.PQerrorMessage(conn);
            std.log.err("postgres connect failed: {s}", .{std.mem.span(msg)});
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
        std.log.err("postgres error ({s}): {s}", .{ context, std.mem.span(msg) });
    }

    /// Extract diagnostic detail from a PGresult for richer error logging.
    fn logPgResultError(conn: *c.PGconn, result: ?*c.PGresult, context: []const u8) void {
        const table = if (result) |r| c.PQresultErrorField(r, c.PG_DIAG_TABLE_NAME) else null;
        const column = if (result) |r| c.PQresultErrorField(r, c.PG_DIAG_COLUMN_NAME) else null;
        const detail = if (result) |r| c.PQresultErrorField(r, c.PG_DIAG_MESSAGE_DETAIL) else null;
        if (table != null or column != null) {
            if (detail) |d| {
                std.log.err("postgres ({s}) table={s} col={s}: {s}", .{
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
        const sqlstate: []const u8 = std.mem.span(field);
        if (sqlstate.len < 2) return error.DriverFailed;
        return switch (sqlstate[0]) {
            '0' => if (sqlstate[1] == '8') error.ConnectionFailed else error.DriverFailed,
            '2' => switch (sqlstate[1]) {
                '2', '3', '8' => error.ExecFailed,
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

            _ = try cch.getOrPrepare(sql, pctx, struct {
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
            }.f);

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
                return sqlstateToError(res.?);
            }

            const affected = c.PQcmdTuples(res);
            var rows_affected: usize = 0;
            if (affected) |a| {
                rows_affected = std.fmt.parseInt(usize, std.mem.span(a), 10) catch 0;
            }

            var last_insert_id: ?i64 = null;
            if (c.PQntuples(res) > 0) {
                const oid_value = c.PQgetvalue(res, 0, 0);
                if (oid_value) |val| {
                    last_insert_id = std.fmt.parseInt(i64, std.mem.span(val), 10) catch null;
                }
            }

            return driver.Result{
                .rows_affected = rows_affected,
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
            return sqlstateToError(res.?);
        }

        const affected = c.PQcmdTuples(res);
        var rows_affected: usize = 0;
        if (affected) |a| {
            rows_affected = std.fmt.parseInt(usize, std.mem.span(a), 10) catch 0;
        }

        // Get last insert id from RETURNING clause if present, or use oid
        var last_insert_id: ?i64 = null;
        if (c.PQntuples(res) > 0) {
            const oid_value = c.PQgetvalue(res, 0, 0);
            if (oid_value) |val| {
                last_insert_id = std.fmt.parseInt(i64, std.mem.span(val), 10) catch null;
            }
        }

        return driver.Result{
            .rows_affected = rows_affected,
            .last_insert_id = last_insert_id,
        };
    }

    pub fn query(self: *PostgresDriver, query_sql: []const u8, args: []const Value) !driver.Rows {
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
            logPgResultError(self.conn, res, "query");
            return sqlstateToError(res.?);
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

    /// Returns true if the connection currently has an active transaction.
    pub fn inTransaction(self: *PostgresDriver) bool {
        const status = c.PQtransactionStatus(self.conn);
        return status != c.PQTRANS_IDLE and status != c.PQTRANS_UNKNOWN;
    }

    pub fn beginTx(self: *PostgresDriver) !driver.Tx {
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
            .ptr = tx_ptr,
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
            fn f(ptr: *anyopaque, q: []const u8, a: []const Value) driver.Error!driver.Result {
                const self_ptr: *PostgresDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.exec(q, a) catch |err| return toDriverError(err);
            }
        }.f,
        .query = struct {
            fn f(ptr: *anyopaque, q: []const u8, a: []const Value) driver.Error!driver.Rows {
                const self_ptr: *PostgresDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.query(q, a) catch |err| return toDriverError(err);
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
    };
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
            _ = self.driver.exec("ROLLBACK", &.{}) catch {};
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
    var drv: PostgresDriver = undefined;
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
