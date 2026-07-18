const std = @import("std");
const c = @import("pg_c");
const Value = @import("builder.zig").Value;
const Dialect = @import("dialect.zig").Dialect;
const driver = @import("driver.zig");

const PG_ERRBUF_SIZE = 256;

pub const PostgresDriver = struct {
    conn: *c.PGconn,
    allocator: std.mem.Allocator,

    pub fn connect(allocator: std.mem.Allocator, conninfo: []const u8) !PostgresDriver {
        // libpq expects a null-terminated string
        const conninfo_z = try allocator.dupeZ(u8, conninfo);
        defer allocator.free(conninfo_z);

        const conn = c.PQconnectdb(conninfo_z.ptr);
        if (c.PQstatus(conn) != c.CONNECTION_OK) {
            defer c.PQfinish(conn);
            const msg = c.PQerrorMessage(conn);
            std.log.err("postgres connect failed: {s}", .{std.mem.span(msg)});
            return error.PostgresConnectFailed;
        }
        return PostgresDriver{ .conn = conn, .allocator = allocator };
    }

    pub fn connectDb(allocator: std.mem.Allocator, host: []const u8, port: u16, dbname: []const u8, user: []const u8, password: []const u8) !PostgresDriver {
        const conninfo = try std.fmt.allocPrint(
            allocator,
            "host={s} port={d} dbname={s} user={s} password={s}",
            .{ host, port, dbname, user, password },
        );
        defer allocator.free(conninfo);
        return connect(allocator, conninfo);
    }

    pub fn close(self: *PostgresDriver) void {
        c.PQfinish(self.conn);
    }

    fn logPgError(conn: *c.PGconn, context: []const u8) void {
        const msg = c.PQerrorMessage(conn);
        std.log.err("postgres error ({s}): {s}", .{ context, std.mem.span(msg) });
    }

    /// Free all parameters that were allocated (int, float, string, bytes).
    /// Bool params point to static "t"/"f" strings and are not freed.
    /// Uses the saved allocation length (NOT std.mem.span) so that values
    /// containing embedded NULs are freed correctly.
    fn freeParams(
        allocator: std.mem.Allocator,
        paramValues: std.ArrayListUnmanaged(?[*:0]const u8),
        owned_lens: std.ArrayListUnmanaged(?usize),
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
                    owned_lens.items[i] = s.len;
                },
                .float => |v| {
                    const s = try std.fmt.allocPrintSentinel(allocator, "{d}\x00", .{v}, 0);
                    paramValues.items[i] = s.ptr;
                    paramLengths.items[i] = @intCast(s.len - 1);
                    paramFormats.items[i] = 0;
                    owned_lens.items[i] = s.len;
                },
                .string => |v| {
                    // dupeZ appends a NUL; we own the full buffer.
                    const s = try allocator.dupeZ(u8, v);
                    paramValues.items[i] = s.ptr;
                    paramLengths.items[i] = @intCast(v.len);
                    paramFormats.items[i] = 0;
                    owned_lens.items[i] = s.len;
                },
                .bytes => |v| {
                    const s = try allocator.dupeZ(u8, v);
                    paramValues.items[i] = s.ptr;
                    paramLengths.items[i] = @intCast(v.len);
                    paramFormats.items[i] = 1; // binary format
                    owned_lens.items[i] = s.len;
                },
            }
        }
    }

    pub fn exec(self: *PostgresDriver, sql: []const u8, args: []const Value) !driver.Result {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var paramValues: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
        var paramLengths: std.ArrayListUnmanaged(c_int) = .empty;
        var paramFormats: std.ArrayListUnmanaged(c_int) = .empty;
        var owned_lens: std.ArrayListUnmanaged(?usize) = .empty;
        defer {
            freeParams(self.allocator, paramValues, owned_lens);
            paramValues.deinit(self.allocator);
            paramLengths.deinit(self.allocator);
            paramFormats.deinit(self.allocator);
        }

        try bindParams(self.allocator, args, &paramValues, &paramLengths, &paramFormats, &owned_lens);

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
            return error.PostgresExecFailed;
        }
        defer c.PQclear(res);

        const status = c.PQresultStatus(res);
        if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) {
            logPgError(self.conn, "exec");
            return error.PostgresExecFailed;
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
        const sql_z = try self.allocator.dupeZ(u8, query_sql);
        defer self.allocator.free(sql_z);

        var paramValues: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
        var paramLengths: std.ArrayListUnmanaged(c_int) = .empty;
        var paramFormats: std.ArrayListUnmanaged(c_int) = .empty;
        var owned_lens: std.ArrayListUnmanaged(?usize) = .empty;
        defer {
            freeParams(self.allocator, paramValues, owned_lens);
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
            return error.PostgresQueryFailed;
        }
        errdefer c.PQclear(res);

        const status = c.PQresultStatus(res);
        if (status != c.PGRES_TUPLES_OK) {
            logPgError(self.conn, "query");
            return error.PostgresQueryFailed;
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
        if (c.PQstatus(self.conn) != c.CONNECTION_OK) {
            logPgError(self.conn, "ping");
            return error.PostgresPingFailed;
        }
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
            fn f(ptr: *anyopaque, q: []const u8, a: []const Value) anyerror!driver.Result {
                const self_ptr: *PostgresDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.exec(q, a);
            }
        }.f,
        .query = struct {
            fn f(ptr: *anyopaque, q: []const u8, a: []const Value) anyerror!driver.Rows {
                const self_ptr: *PostgresDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.query(q, a);
            }
        }.f,
        .beginTx = struct {
            fn f(ptr: *anyopaque) anyerror!driver.Tx {
                const self_ptr: *PostgresDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.beginTx();
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
            fn f(ptr: *anyopaque) anyerror!void {
                const self_ptr: *PostgresDriver = @ptrCast(@alignCast(ptr));
                return self_ptr.ping();
            }
        }.f,
    };
};

const PostgresTx = struct {
    driver: *PostgresDriver,
    state: enum { active, committed, rolled_back },

    fn commit(ptr: *anyopaque) !void {
        const self: *PostgresTx = @ptrCast(@alignCast(ptr));
        if (self.state != .active) return;
        self.state = .committed;
        _ = try self.driver.exec("COMMIT", &.{});
    }

    fn rollback(ptr: *anyopaque) !void {
        const self: *PostgresTx = @ptrCast(@alignCast(ptr));
        if (self.state != .active) return;
        self.state = .rolled_back;
        _ = try self.driver.exec("ROLLBACK", &.{});
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
