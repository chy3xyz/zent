const std = @import("std");
const edgeTargetInfo = @import("graph.zig").edgeTargetInfo;
const TypeInfo = @import("graph.zig").TypeInfo;
const FieldInfo = @import("graph.zig").FieldInfo;
const EdgeInfo = @import("graph.zig").EdgeInfo;
const columnName = @import("graph.zig").columnName;
const pkColumn = @import("graph.zig").pkColumn;
const sql = @import("../sql/builder.zig");
const field_value = @import("field_value.zig");
const sql_driver = @import("../sql/driver.zig");
const Dialect = @import("../sql/dialect.zig").Dialect;
const Hook = @import("../runtime/hook.zig").Hook;
const HookContext = @import("../runtime/hook.zig").HookContext;
const HookError = @import("../runtime/hook.zig").HookError;
const Op = @import("../runtime/hook.zig").Op;
const rthook = @import("../runtime/hook.zig");
const zent_log = @import("../runtime/log.zig");
const privacy = @import("../privacy/policy.zig");
const Logger = @import("../sql/logger.zig").Logger;
const LogContext = @import("../sql/logger.zig").LogContext;
const nowUs = @import("../sql/logger.zig").nowUs;
const intercept = @import("../runtime/intercept.zig");

fn mapBuildError(err: anyerror) sql_driver.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.DriverFailed,
    };
}

/// A runtime field value entry.
pub const FieldValue = struct {
    name: []const u8,
    value: sql.Value,
};

fn findEdgeInfo(comptime info: TypeInfo, comptime name: []const u8) EdgeInfo {
    for (info.edges) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    @compileError("Edge not found: " ++ name ++ " on " ++ info.name);
}

/// The caller's own value for a textual (uuid) primary key, or `null` when the
/// values hold none. `setFieldValue` binds a `string` / `uuid` / `text` field as
/// `.string`, so any other shape for the key — an explicit `.null`, or a name
/// that was never set — leaves the key just as unknown as an omitted one, and
/// the caller gets `error.MissingPrimaryKey` rather than `""`.
fn textPrimaryKeyFrom(values: []const FieldValue, pk_field: []const u8) ?[]const u8 {
    for (values) |fv| {
        if (std.mem.eql(u8, fv.name, pk_field) and fv.value == .string) return fv.value.string;
    }
    return null;
}

/// Generate a Create builder for an entity.
pub fn CreateBuilder(comptime infos: []const TypeInfo, comptime info: TypeInfo, comptime Entity: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        driver: sql_driver.Driver,
        values: std.array_list.Managed(FieldValue),
        edge_values: std.array_list.Managed(EdgeValue),
        json_strings: std.array_list.Managed([]const u8),
        hooks: []const Hook,
        privacy_ctx: ?privacy.PrivacyContext = null,
        logger: Logger = .{},
        timeout_ms: ?u32 = null,
        execution_context: sql_driver.ExecutionContext = .{},
        upsert_conflict_columns: ?[]const []const u8 = null,
        upsert_set_exprs: ?[]const UpsertSetExpr = null,
        interceptors: ?*intercept.InterceptorChain = null,

        const EdgeValue = struct {
            edge: []const u8,
            ids: []const i64,
        };

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver, hooks: []const Hook, privacy_ctx: ?privacy.PrivacyContext) Self {
            return .{
                .allocator = allocator,
                .driver = driver,
                .hooks = hooks,
                .privacy_ctx = privacy_ctx,
                .values = std.array_list.Managed(FieldValue).init(allocator),
                .edge_values = std.array_list.Managed(EdgeValue).init(allocator),
                .json_strings = std.array_list.Managed([]const u8).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.json_strings.items) |s| self.allocator.free(s);
            self.json_strings.deinit();
            self.values.deinit();
            self.edge_values.deinit();
        }

        /// Set a per-query timeout in milliseconds. The deadline is computed
        /// immediately before execution and passed to the driver.
        pub fn withTimeout(self: *Self, ms: u32) *Self {
            self.timeout_ms = ms;
            return self;
        }

        fn ensureDeadline(self: *Self) void {
            if (self.timeout_ms) |ms| {
                self.execution_context.deadline_ns = sql_driver.monotonicNs() + @as(i64, ms) * std.time.ns_per_ms;
            }
        }

        // Set field value helper (dynamic, no compile-time checking).
        pub fn setValue(self: *Self, name: []const u8, value: sql.Value) !*Self {
            try self.values.append(.{ .name = name, .value = value });
            return self;
        }

        /// Set a field value with compile-time name and type checking.
        ///
        /// The accepted shapes are decided by `codegen.field_value` and pinned
        /// in both directions by its tests: `Int` ← `i64`/`comptime_int`,
        /// `Float` ← `f64`/`comptime_float`, `Bool` ← `bool`, string-ish fields
        /// ← `[]const u8` or a string literal, `JSON` ← the field's own Zig
        /// type (or `std.json.Value` for `field.JSONValue`), `Optional(T)` ← a
        /// bare value for `T`, an `?T`, or a bare `null` literal. A wrong pair is a `@compileError`
        /// naming the field and both types.
        pub fn setFieldValue(self: *Self, comptime field_name: []const u8, value: anytype) !*Self {
            comptime var needs_json = false;
            comptime {
                var found = false;
                for (info.fields) |f| {
                    if (std.mem.eql(u8, f.name, field_name)) {
                        const Expected = if (f.optional) ?f.zig_type else f.zig_type;
                        const Actual = @TypeOf(value);
                        if (!field_value.accepts(Expected, Actual)) {
                            @compileError("Type mismatch for field '" ++ field_name ++ "': expected " ++ @typeName(Expected) ++ ", got " ++ @typeName(Actual));
                        }
                        if (f.field_type == .json and
                            (@typeInfo(Actual) == .@"struct" or Actual == std.json.Value))
                        {
                            needs_json = true;
                        }
                        found = true;
                        break;
                    }
                }
                if (!found) @compileError("Unknown field: " ++ field_name);
            }

            if (comptime needs_json) {
                const json_str = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
                try self.json_strings.append(json_str);
                return try self.setValue(field_name, .{ .string = json_str });
            }

            return try self.setValue(field_name, field_value.toSqlValue(value));
        }

        /// Add target IDs for an M2M edge.
        /// After Save(), junction table rows will be inserted automatically.
        pub fn AddEdge(self: *Self, comptime edge_name: []const u8, ids: []const i64) !*Self {
            comptime {
                const edge = findEdgeInfo(info, edge_name);
                if (edge.relation != .m2m) {
                    @compileError("AddEdge is only supported for M2M edges: " ++ edge_name);
                }
            }
            try self.edge_values.append(.{ .edge = edge_name, .ids = ids });
            return self;
        }

        /// Explicit, and it **grows**: v0.67.0 added `MissingLastInsertId`,
        /// v0.69.0 `InconsistentRowFields`, v0.69.0 `MissingPrimaryKey`. A
        /// member is only ever added for a failure a caller could act on,
        /// never renamed — but a caller that switches over this set must end
        /// with `else =>`, or a minor release will not compile. See
        /// `docs/BEST_PRACTICES.md` ("Error sets that grow").
        const SaveError = sql_driver.Error || HookError || error{ PrivacyDenied, NotFound, TypeMismatch, ColumnCountMismatch, ValidationFailed, InterceptFailed, MissingLastInsertId, MissingPrimaryKey };

        /// Run the interceptor chain (`.create`). `whereEq` fills omitted
        /// columns; already-set fields are left alone. Errors collapse to
        /// `error.InterceptFailed` so Save keeps an explicit error set.
        fn runInterceptors(self: *Self) error{InterceptFailed}!void {
            const chain = self.interceptors orelse return;
            var view = intercept.QueryView{
                .op = .create,
                .table_name = info.table_name,
                .sink = self,
                .add_eq_fn = addEqField,
            };
            chain.run(&view) catch return error.InterceptFailed;
        }

        /// QueryView sink: set `field_name = value` when the caller omitted
        /// it. Unknown fields are rejected; a duplicate name is a no-op.
        fn addEqField(sink: *anyopaque, field_name: []const u8, value: sql.Value) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(sink));
            var found = false;
            inline for (info.fields) |f| {
                if (std.mem.eql(u8, f.name, field_name)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.UnknownField;
            for (self.values.items) |fv| {
                if (std.mem.eql(u8, fv.name, field_name)) return;
            }
            try self.values.append(.{ .name = field_name, .value = value });
        }

        /// Insert the row and return it with its primary key filled in.
        ///
        /// `error.MissingLastInsertId` means the statement ran but the driver
        /// reported no id for it, so the row's key is unknown. The row is not
        /// re-read to find it (`Save` has no unique key to look it up by), and
        /// `0` would name a row that does not exist.
        ///
        /// `error.MissingPrimaryKey` is the same "the key is unknown" on the
        /// path that has no id to report in the first place: a textual (uuid)
        /// key on MySQL, which has no `RETURNING`, so the caller's own value is
        /// the only source — the library generates no key (`core/id.zig` is a
        /// helper set the caller drives) and MySQL fills no `CHAR(36)` key in.
        /// It is decided **before** the statement runs, so no row is written: an
        /// empty string names a row that does not exist, and every later call
        /// would pass it around as an id.
        pub fn Save(self: *Self) SaveError!Entity {
            return self.saveInternal(false, false, null, self.allocator);
        }

        /// `Save`, with the returned entity owned by `arena`: its string /
        /// slice fields and its JSON payload (parsed into an arena that is a
        /// child of `arena`) all come from there, so `arena.deinit()` is the
        /// release. The entity must **not** be passed to `deinitEntity` /
        /// `deinitRow` afterwards.
        ///
        /// The complement of `AllIn`: a handler that owns one arena can
        /// create and read through it without tracking anything per row.
        pub fn SaveIn(self: *Self, arena: *std.heap.ArenaAllocator) SaveError!Entity {
            return self.saveInternal(false, false, null, arena.allocator());
        }

        pub fn SaveOrUpdate(self: *Self) SaveError!Entity {
            return self.saveInternal(true, false, null, self.allocator);
        }

        /// Insert the row, silently ignoring unique-key conflicts.
        /// MySQL → INSERT IGNORE, PostgreSQL → ON CONFLICT DO NOTHING,
        /// SQLite → INSERT OR IGNORE.
        pub fn SaveIgnore(self: *Self) SaveError!Entity {
            return self.saveInternal(false, true, null, self.allocator);
        }

        /// Upsert using the given columns as the conflict target instead of
        /// the primary key. Requires a matching UNIQUE index on those columns.
        pub fn SaveOrUpdateOn(self: *Self, conflict_columns: []const []const u8) SaveError!Entity {
            self.upsert_conflict_columns = conflict_columns;
            return self.saveInternal(true, false, conflict_columns, self.allocator);
        }

        /// Upsert with a custom conflict target AND per-column SET
        /// expressions. Columns without an entry keep the default
        /// `col = EXCLUDED.col` assignment. Requires a matching UNIQUE index
        /// on `conflict_columns`.
        pub fn SaveOrUpdateOnWith(self: *Self, conflict_columns: []const []const u8, update_exprs: []const UpsertSetExpr) SaveError!Entity {
            self.upsert_conflict_columns = conflict_columns;
            self.upsert_set_exprs = update_exprs;
            return self.saveInternal(true, false, conflict_columns, self.allocator);
        }

        /// `entity_alloc` owns the *returned entity* only — its owning fields
        /// and its JSON arena. The statement itself (columns, args, SQL text,
        /// builders) stays on `self.allocator`, which is what the `defer`s in
        /// here free; handing those to an arena would just strand them until
        /// the arena dies. `Save` passes `self.allocator` (unchanged
        /// behaviour), `SaveIn` passes the caller's arena.
        fn saveInternal(self: *Self, comptime or_replace: bool, comptime ignore_conflicts: bool, conflict_columns: ?[]const []const u8, entity_alloc: std.mem.Allocator) SaveError!Entity {
            if (info.policy) |p| {
                var ctx = self.privacy_ctx orelse return error.PrivacyDenied;
                ctx.op = .create;
                const result = p.eval(ctx);
                if (result.decision == .deny) return error.PrivacyDenied;
            }
            fillAuditUser(info, self.privacy_ctx, &self.values, false);
            try self.runInterceptors();
            // Build mutated slice from field values for hook context.
            const mutated = try self.allocator.alloc(sql.Value, self.values.items.len);
            defer self.allocator.free(mutated);
            for (self.values.items, 0..) |fv, i| {
                mutated[i] = fv.value;
            }
            var hook_ctx = HookContext{
                .op = .create,
                .table_name = info.table_name,
                .mutated = mutated,
                .privacy = blk: {
                    var pc = self.privacy_ctx orelse privacy.PrivacyContext{};
                    pc.op = .create;
                    break :blk pc;
                },
            };
            try rthook.globalBefore(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .create) {
                    if (h.before) |f| try f(&hook_ctx);
                }
            }
            errdefer {
                rthook.globalAfter(&hook_ctx);
                for (self.hooks) |h| {
                    if (h.op == .create) {
                        if (h.after) |f| f(&hook_ctx) catch |err| {
                            zent_log.warn("after-hook failed on table '{s}' ({s}): {s}", .{ hook_ctx.table_name, @tagName(hook_ctx.op), @errorName(err) });
                        };
                    }
                }
            }

            var columns = std.array_list.Managed([]const u8).init(self.allocator);
            defer columns.deinit();
            var args = std.array_list.Managed(sql.Value).init(self.allocator);
            defer args.deinit();

            for (self.values.items) |fv| {
                inline for (info.fields) |f| {
                    if (std.mem.eql(u8, f.name, fv.name)) {
                        try validateSqlValue(f, fv.value);
                    }
                }
                try columns.append(columnName(info, fv.name));
                try args.append(fv.value);
            }

            // Insert the entity. For dialects that support RETURNING (PostgreSQL,
            // SQLite 3.35+) we use a query path to fetch the id atomically; for
            // MySQL we fall back to driver.exec and read last_insert_id.
            const dialect = self.driver.dialect();
            const dialect_kind = dialect.kind();
            const supports_returning = dialect_kind != .mysql;
            const is_postgres = dialect_kind == .postgres;
            const is_sqlite = dialect_kind == .sqlite;

            // Build the upsert suffix per dialect. For SQLite we use the
            // built-in InsertOrReplace builder. For PG we append ON CONFLICT
            // (cols) DO UPDATE SET col=excluded.col ... For MySQL we generate
            // ON DUPLICATE KEY UPDATE (the old REPLACE prefix has been removed).
            // For plain Save (or_replace=false) the suffix is empty.
            const is_mysql = dialect_kind == .mysql;
            // Conflict targets are field names on the API surface; translate
            // them to physical column names before emitting SQL.
            const mapped_conflict: ?[]const []const u8 = if (conflict_columns) |cc| blk: {
                const buf = try self.allocator.alloc([]const u8, cc.len);
                for (cc, 0..) |c, i| buf[i] = columnName(info, c);
                break :blk buf;
            } else null;
            defer if (mapped_conflict) |m| self.allocator.free(m);
            const pk_col = pkColumn(info);
            const upsert_conflict_cols: []const []const u8 = mapped_conflict orelse &[_][]const u8{pk_col};
            const pk_is_integer = comptime @TypeOf(@field(@import("../sql/scan.zig").zeroInit(Entity), info.pk_field)) == i64;
            const upsert_suffix: []const u8 = try buildUpsertSuffix(self.allocator, or_replace, is_postgres, is_sqlite, is_mysql, columns.items, upsert_conflict_cols, pk_col, pk_is_integer, self.upsert_set_exprs, info.table_name);
            defer if (upsert_suffix.len > 0) self.allocator.free(upsert_suffix);

            const ignore_suffix: []const u8 = if (ignore_conflicts and is_postgres) " ON CONFLICT DO NOTHING" else "";

            // std.mem.zeroes(Entity) is not allowed when an entity carries a
            // std.json.Value field (std rejects zeroing Value); zeroInit
            // handles that (Value fields default to .null).
            var entity: Entity = @import("../sql/scan.zig").zeroInit(Entity);
            if (supports_returning) {
                // A textual (uuid) primary key has no source but the caller's
                // own value here too — RETURNING only hands back what the
                // statement wrote. Resolved *before* the statement runs — the
                // same decision as the MySQL branch below, so the two
                // dialects cannot drift — because the two servers disagree on
                // a key that was never set: PostgreSQL rejects the INSERT
                // (NOT NULL), while SQLite's rowid-table quirk ACCEPTS the
                // NULL into a TEXT PRIMARY KEY and RETURNING then hands back
                // NULL *after* the write. Answering `TypeMismatch` there would
                // name a type error for what is actually a missing key, with
                // the keyless row already on disk.
                if (comptime @TypeOf(@field(entity, info.pk_field)) != i64) {
                    if (textPrimaryKeyFrom(self.values.items, info.pk_field) == null) return error.MissingPrimaryKey;
                }
                var builder = if (or_replace and is_sqlite and self.upsert_set_exprs == null)
                    sql.InsertOrReplace(self.allocator, dialect, info.table_name)
                else if (ignore_conflicts and is_sqlite)
                    sql.InsertOrIgnore(self.allocator, dialect, info.table_name)
                else
                    sql.Insert(self.allocator, dialect, info.table_name);
                defer builder.deinit();
                _ = try builder.columns(columns.items);
                _ = try builder.values(args.items);
                var q = builder.takeQuery() catch |err| return mapBuildError(err);
                defer q.deinit();

                // Build the full SQL: q.sql + ignore suffix + PG/SQLite UPSERT suffix + RETURNING.
                // MySQL never reaches this branch because it does not support RETURNING.
                const ret_suffix = try std.fmt.allocPrint(self.allocator, " RETURNING \"{s}\"", .{pk_col});
                defer self.allocator.free(ret_suffix);

                const full_sql_len = q.sql.len + ignore_suffix.len + upsert_suffix.len + ret_suffix.len;
                const full_sql = try self.allocator.alloc(u8, full_sql_len);
                defer self.allocator.free(full_sql);
                var pos: usize = 0;
                @memcpy(full_sql[pos..][0..q.sql.len], q.sql);
                pos += q.sql.len;
                @memcpy(full_sql[pos..][0..ignore_suffix.len], ignore_suffix);
                pos += ignore_suffix.len;
                @memcpy(full_sql[pos..][0..upsert_suffix.len], upsert_suffix);
                pos += upsert_suffix.len;
                @memcpy(full_sql[pos..][0..ret_suffix.len], ret_suffix);

                self.ensureDeadline();
                const start = nowUs();
                var rows = try self.driver.queryCtx(&self.execution_context, full_sql, q.args);
                defer rows.deinit();
                var returned_row = false;
                if (rows.next()) |row| {
                    returned_row = true;
                    if (comptime @TypeOf(@field(entity, info.pk_field)) == i64) {
                        @field(entity, info.pk_field) = @intCast(row.getInt(0) orelse return error.TypeMismatch);
                    } else {
                        // Textual primary key (uuid): RETURNING gives the value
                        // back. A NULL here means a supplied value came back
                        // NULL — a genuine anomaly; the pre-check above owns
                        // the "caller never set it" case.
                        @field(entity, info.pk_field) = try entity_alloc.dupe(u8, row.getText(0) orelse return error.TypeMismatch);
                    }
                } else {
                    // For ignore mode a missing RETURNING row means the row
                    // already existed and was ignored. Return the entity with
                    // ID left at zero; callers can query the existing row.
                    if (!ignore_conflicts) {
                        // Distinguish a driver error (e.g. a UNIQUE/NOT NULL
                        // constraint on INSERT ... RETURNING) from a genuinely
                        // missing RETURNING row.
                        if (rows.nextError()) |e| return e;
                        return error.NotFound;
                    }
                }
                const duration_us: u64 = nowUs() - start;

                if (self.logger.onExec) |log| {
                    var log_args = try self.allocator.alloc(sql.Value, args.items.len);
                    defer self.allocator.free(log_args);
                    @memcpy(log_args, args.items);
                    for (self.values.items, 0..) |fv, i| {
                        inline for (info.fields) |f| {
                            if (std.mem.eql(u8, f.name, fv.name) and f.sensitive) {
                                log_args[i] = .{ .string = "***" };
                            }
                        }
                    }
                    log(.{
                        .sql = full_sql,
                        .args = log_args,
                        .duration_us = duration_us,
                        // RETURNING answers at most one row per inserted row,
                        // so the count is decided here: outside ignore mode a
                        // missing row already returned earlier, and inside it
                        // a missing row means nothing was written.
                        .rows_affected = if (returned_row) 1 else 0,
                        .rows_affected_known = true,
                        .table_name = info.table_name,
                    });
                }
            } else {
                // MySQL path: normal INSERT plus ON DUPLICATE KEY UPDATE suffix,
                // or INSERT IGNORE for conflict-ignore mode.
                //
                // A textual (uuid) primary key has no `RETURNING` here, so the
                // caller's own value is the only source — and a caller that
                // never wrote one leaves the key unknown. Resolved *before* the
                // statement runs, because MySQL would otherwise write whatever
                // the schema defaults to (an empty string on a lenient
                // `sql_mode`, a server error on a strict one) and the entity
                // would come back carrying `""`, which names no row while
                // looking like a key that names one — the same shape as the
                // `last_insert_id orelse 0` this path's integer branch refuses.
                if (comptime @TypeOf(@field(entity, info.pk_field)) != i64) {
                    if (textPrimaryKeyFrom(self.values.items, info.pk_field) == null) return error.MissingPrimaryKey;
                }
                var builder = if (ignore_conflicts)
                    sql.InsertOrIgnore(self.allocator, dialect, info.table_name)
                else
                    sql.Insert(self.allocator, dialect, info.table_name);
                defer builder.deinit();
                _ = try builder.columns(columns.items);
                _ = try builder.values(args.items);
                var q = builder.takeQuery() catch |err| return mapBuildError(err);
                defer q.deinit();

                const full_sql_len = q.sql.len + upsert_suffix.len;
                const full_sql = try self.allocator.alloc(u8, full_sql_len);
                defer self.allocator.free(full_sql);
                @memcpy(full_sql[0..q.sql.len], q.sql);
                @memcpy(full_sql[q.sql.len..], upsert_suffix);

                self.ensureDeadline();
                const start = nowUs();
                const res = try self.driver.execCtx(&self.execution_context, full_sql, q.args);
                const duration_us: u64 = nowUs() - start;
                if (comptime @TypeOf(@field(entity, info.pk_field)) == i64) {
                    // `last_insert_id` is `?i64` because a driver may have no
                    // id to give, and a `0` written here is indistinguishable
                    // from a real key — the entity would look like a row that
                    // exists, with the caller's own insert hidden behind it.
                    // (The in-tree MySQL driver always answers `Some`; a
                    // wrapper or a custom driver need not.)
                    @field(entity, info.pk_field) = @intCast(res.last_insert_id orelse return error.MissingLastInsertId);
                } else {
                    // Textual primary key (uuid) on MySQL: no RETURNING — keep
                    // the caller-provided id from the values. Presence was
                    // established above; the `orelse` keeps the two from
                    // drifting into a panic instead of the named error.
                    @field(entity, info.pk_field) = try entity_alloc.dupe(u8, textPrimaryKeyFrom(self.values.items, info.pk_field) orelse return error.MissingPrimaryKey);
                }

                if (self.logger.onExec) |log| {
                    var log_args = try self.allocator.alloc(sql.Value, args.items.len);
                    defer self.allocator.free(log_args);
                    @memcpy(log_args, args.items);
                    for (self.values.items, 0..) |fv, i| {
                        inline for (info.fields) |f| {
                            if (std.mem.eql(u8, f.name, fv.name) and f.sensitive) {
                                log_args[i] = .{ .string = "***" };
                            }
                        }
                    }
                    log(.{
                        .sql = full_sql,
                        .args = log_args,
                        .duration_us = duration_us,
                        // Forward the driver's own count: a MySQL upsert that
                        // updated reports 2, an INSERT IGNORE that ignored
                        // reports 0 — a hardcoded 1 claimed a row either way.
                        .rows_affected = res.rows_affected,
                        .rows_affected_known = res.rows_affected_known,
                        .table_name = info.table_name,
                    });
                }
            }

            // Fill other fields from mutation values
            for (self.values.items) |fv| {
                if (std.mem.eql(u8, fv.name, info.pk_field)) continue;
                try setEntityField(&entity, fv.name, fv.value, entity_alloc);
            }

            // Insert M2M junction table rows (or edge schema rows)
            // Pre-compute junction table info at comptime
            const JunctionInfo = struct {
                edge_name: []const u8,
                junction_table: []const u8,
                source_col: []const u8,
                target_col: []const u8,
            };

            comptime var junction_infos: []const JunctionInfo = &.{};
            comptime {
                for (info.edges) |edge| {
                    if (edge.relation == .m2m) {
                        const target_info = edgeTargetInfo(infos, info, edge);
                        const source_table = info.table_name;
                        const target_table = target_info.table_name;

                        const junction_table = if (edge.through_name) |tn|
                            tn
                        else if (std.mem.lessThan(u8, source_table, target_table))
                            source_table ++ "_" ++ target_table
                        else
                            target_table ++ "_" ++ source_table;

                        junction_infos = junction_infos ++ &[_]JunctionInfo{.{
                            .edge_name = edge.name,
                            .junction_table = junction_table,
                            .source_col = source_table ++ "_id",
                            .target_col = target_table ++ "_id",
                        }};
                    }
                }
            }

            // Now use the pre-computed info at runtime
            for (self.edge_values.items) |ev| {
                inline for (junction_infos) |ji| {
                    if (std.mem.eql(u8, ev.edge, ji.edge_name)) {
                        for (ev.ids) |target_id| {
                            // Use the dialect-aware Insert builder so the
                            // generated SQL has the correct placeholders
                            // ($1, $2 for PG; ?, ? for SQLite/MySQL) and
                            // identifier quoting (` for MySQL, " otherwise).
                            var ib = sql.Insert(self.allocator, self.driver.dialect(), ji.junction_table);
                            defer ib.deinit();
                            _ = try ib.columns(&.{ ji.source_col, ji.target_col });
                            _ = try ib.values(&.{
                                .{ .int = @field(entity, info.pk_field) },
                                .{ .int = target_id },
                            });
                            var iq = ib.takeQuery() catch |err| return mapBuildError(err);
                            defer iq.deinit();
                            self.ensureDeadline();
                            _ = try self.driver.execCtx(&self.execution_context, iq.sql, iq.args);
                        }
                    }
                }
            }

            // After hooks on success: entity is fully populated.
            hook_ctx.entity = &entity;
            rthook.globalAfter(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .create) {
                    if (h.after) |f| f(&hook_ctx) catch |err| {
                        zent_log.warn("after-hook failed on table '{s}' ({s}): {s}", .{ hook_ctx.table_name, @tagName(hook_ctx.op), @errorName(err) });
                    };
                }
            }

            return entity;
        }

        fn setEntityField(entity: *Entity, name: []const u8, value: sql.Value, allocator: std.mem.Allocator) !void {
            inline for (info.fields) |f| {
                if (std.mem.eql(u8, f.name, name)) {
                    if (value == .null) {
                        if (f.optional) {
                            @field(entity, f.name) = @as(?f.zig_type, null);
                        } else {
                            return error.TypeMismatch;
                        }
                        return;
                    }
                    @field(entity, f.name) = try valueToType(f.zig_type, f.field_type, value, allocator, entity);
                    return;
                }
            }
        }

        fn valueToType(comptime T: type, comptime ft: @import("../core/field.zig").FieldType, value: sql.Value, allocator: std.mem.Allocator, entity: *Entity) error{ OutOfMemory, TypeMismatch }!T {
            _ = ft;
            return switch (@typeInfo(T)) {
                .int => @intCast(value.int),
                .bool => value.bool,
                .float => @floatCast(value.float),
                else => {
                    if (T == []const u8) {
                        return try allocator.dupe(u8, value.string);
                    }
                    // Struct/JSON: parse into a per-entity arena so deinitEntity can free it.
                    if (comptime @hasField(Entity, "json_arena")) {
                        const arena = if (entity.json_arena) |a| a else blk: {
                            const a = try allocator.create(std.heap.ArenaAllocator);
                            a.* = std.heap.ArenaAllocator.init(allocator);
                            errdefer allocator.destroy(a);
                            entity.json_arena = a;
                            break :blk a;
                        };
                        return std.json.parseFromSliceLeaky(T, arena.allocator(), value.string, .{}) catch |err| switch (err) {
                            error.OutOfMemory => error.OutOfMemory,
                            else => error.TypeMismatch,
                        };
                    }
                    // Fallback for entities without a json_arena field (non-JSON structs).
                    return std.json.parseFromSliceLeaky(T, allocator, value.string, .{}) catch |err| switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => error.TypeMismatch,
                    };
                },
            };
        }
    };
}

pub fn validateSqlValue(comptime field: FieldInfo, value: sql.Value) !void {
    if (value == .null) return; // null is valid for optional fields
    for (field.validators) |v| {
        switch (v) {
            .positive => {
                const int_val = switch (value) {
                    .int => |i| i,
                    else => return error.ValidationFailed,
                };
                if (int_val <= 0) return error.ValidationFailed;
            },
            .range => |r| {
                const int_val = switch (value) {
                    .int => |i| i,
                    else => return error.ValidationFailed,
                };
                if (int_val < r.min or int_val > r.max) return error.ValidationFailed;
            },
            .match => |pattern| {
                const str_val = switch (value) {
                    .string => |s| s,
                    else => return error.ValidationFailed,
                };
                if (std.mem.indexOf(u8, str_val, pattern) == null) return error.ValidationFailed;
            },
            .not_empty => {
                const str_val = switch (value) {
                    .string => |s| s,
                    else => return error.ValidationFailed,
                };
                if (str_val.len == 0) return error.ValidationFailed;
            },
            .length => |l| {
                const str_val = switch (value) {
                    .string => |s| s,
                    else => return error.ValidationFailed,
                };
                if (str_val.len < l.min or str_val.len > l.max) return error.ValidationFailed;
            },
            .email => {
                const str_val = switch (value) {
                    .string => |s| s,
                    else => return error.ValidationFailed,
                };
                if (!isEmail(str_val)) return error.ValidationFailed;
            },
            .phone => {
                const str_val = switch (value) {
                    .string => |s| s,
                    else => return error.ValidationFailed,
                };
                if (!isPhone(str_val)) return error.ValidationFailed;
            },
            .custom => |pattern| {
                const str_val = switch (value) {
                    .string => |s| s,
                    else => return error.ValidationFailed,
                };
                if (!wildcardMatch(pattern, str_val)) return error.ValidationFailed;
            },
        }
    }
}

/// Simple wildcard matcher: `*` matches any sequence, `?` matches one char.
fn wildcardMatch(pattern: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (i < s.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == s[i])) {
            p += 1;
            i += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            mark = i;
        } else if (star) |sp| {
            p = sp + 1;
            mark += 1;
            i = mark;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn isEmail(s: []const u8) bool {
    if (s.len < 3 or s.len > 254) return false;
    var has_at = false;
    var at_pos: usize = 0;
    for (s, 0..) |c, i| {
        if (c == ' ' or c == '\n' or c == '\r' or c == '\t') return false;
        if (c == '@') {
            if (has_at) return false;
            has_at = true;
            at_pos = i;
        }
    }
    if (!has_at or at_pos == 0 or at_pos == s.len - 1) return false;
    // Domain must contain a dot after the @.
    return std.mem.indexOfScalarPos(u8, s, at_pos + 1, '.') != null;
}

fn isPhone(s: []const u8) bool {
    if (s.len < 7 or s.len > 15) return false;
    var start: usize = 0;
    if (s[0] == '+') start = 1;
    if (start >= s.len) return false;
    for (s[start..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Auto-fill `created_by` / `updated_by` (AuditMixin) from the privacy
/// context's user id, unless the caller set them explicitly.
pub fn fillAuditUser(
    comptime info: TypeInfo,
    privacy_ctx: ?privacy.PrivacyContext,
    values: *std.array_list.Managed(FieldValue),
    is_update: bool,
) void {
    const user = if (privacy_ctx) |ctx| ctx.user_id else null;
    if (user == null) return;
    const has_created_by = comptime blk: {
        for (info.fields) |f| {
            if (std.mem.eql(u8, f.name, "created_by")) break :blk true;
        }
        break :blk false;
    };
    const has_updated_by = comptime blk: {
        for (info.fields) |f| {
            if (std.mem.eql(u8, f.name, "updated_by")) break :blk true;
        }
        break :blk false;
    };
    if (!has_created_by and !has_updated_by) return;

    const set = struct {
        fn fieldSet(vals: []const FieldValue, name: []const u8) bool {
            for (vals) |fv| {
                if (std.mem.eql(u8, fv.name, name)) return true;
            }
            return false;
        }
    }.fieldSet;

    if (!is_update and has_created_by and !set(values.items, "created_by")) {
        values.append(.{ .name = "created_by", .value = .{ .int = user.? } }) catch |err| {
            // Audit columns are best-effort; the write still proceeds, but an
            // OOM dropping created_by silently would corrupt the audit trail.
            zent_log.warn("fillAuditUser: created_by dropped ({s})", .{@errorName(err)});
        };
    }
    if (has_updated_by and !set(values.items, "updated_by")) {
        values.append(.{ .name = "updated_by", .value = .{ .int = user.? } }) catch |err| {
            zent_log.warn("fillAuditUser: updated_by dropped ({s})", .{@errorName(err)});
        };
    }
}

/// Dialect-aware upsert suffix shared by single-row `SaveOrUpdate` and the
/// bulk `SaveOrUpdate`. The single-row SQLite path deliberately returns ""
/// (it uses INSERT OR REPLACE instead); the bulk path passes
/// `is_sqlite=false` and falls into the ON CONFLICT branch — SQLite supports
/// ON CONFLICT for multi-row INSERTs. Returns "" when `or_replace` is false.
/// Custom SET expression for one column on the upsert DO UPDATE path.
/// Tokens in `expr`: `{t:col}` → qualified target-table column,
/// `{x:col}` → the proposed row's column (`EXCLUDED."col"` on
/// PG/SQLite, `VALUES(col)` on MySQL). Anything else is emitted
/// verbatim — never interpolate user input.
/// Example increment: `.{ .column = "receive_num", .expr = "{t:receive_num} + 1" }`.
pub const UpsertSetExpr = struct { column: []const u8, expr: []const u8 };

/// Expand `{t:col}` / `{x:col}` tokens in an upsert SET expression for the
/// target dialect. Column names must be bare identifiers (letters, digits,
/// underscore) — anything else is `error.ValidationFailed`.
fn findUpsertExpr(update_exprs: ?[]const UpsertSetExpr, column: []const u8) ?[]const u8 {
    const exprs = update_exprs orelse return null;
    for (exprs) |e| {
        if (std.mem.eql(u8, e.column, column)) return e.expr;
    }
    return null;
}

fn expandUpsertExpr(allocator: std.mem.Allocator, is_mysql: bool, table_name: []const u8, expr: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var rest = expr;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        try out.appendSlice(rest[0..open]);
        const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse return error.ValidationFailed;
        const tok = rest[open + 1 .. close];
        if (tok.len < 3 or tok[1] != ':') return error.ValidationFailed;
        const col = tok[2..];
        for (col) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return error.ValidationFailed;
        }
        switch (tok[0]) {
            't' => {
                if (is_mysql) {
                    try out.append('`');
                    try out.appendSlice(table_name);
                    try out.appendSlice("`.`");
                    try out.appendSlice(col);
                    try out.append('`');
                } else {
                    try out.append('"');
                    try out.appendSlice(table_name);
                    try out.appendSlice("\".\"");
                    try out.appendSlice(col);
                    try out.append('"');
                }
            },
            'x' => {
                if (is_mysql) {
                    try out.appendSlice("VALUES(`");
                    try out.appendSlice(col);
                    try out.appendSlice("`)");
                } else {
                    try out.appendSlice("EXCLUDED.\"");
                    try out.appendSlice(col);
                    try out.append('"');
                }
            },
            else => return error.ValidationFailed,
        }
        rest = rest[close + 1 ..];
    }
    try out.appendSlice(rest);
    return try out.toOwnedSlice();
}

fn buildUpsertSuffix(
    allocator: std.mem.Allocator,
    or_replace: bool,
    is_postgres: bool,
    is_sqlite: bool,
    is_mysql: bool,
    columns: []const []const u8,
    conflict_columns: []const []const u8,
    pk_field: []const u8,
    pk_is_integer: bool,
    update_exprs: ?[]const UpsertSetExpr,
    table_name: []const u8,
) ![]const u8 {
    // SQLite single-row upsert normally goes through INSERT OR REPLACE, but
    // a custom SET expr needs the ON CONFLICT form (SQLite ≥3.24 supports
    // the PG spelling) — REPLACE cannot express per-column update math.
    const sqlite_expr_path = is_sqlite and update_exprs != null;
    if (!or_replace or (is_sqlite and !sqlite_expr_path)) return "";
    if (is_mysql) {
        var buf = std.array_list.Managed(u8).init(allocator);
        errdefer buf.deinit();
        try buf.appendSlice(" ON DUPLICATE KEY UPDATE ");
        // Preserve the row id through LAST_INSERT_ID so callers receive the
        // existing auto-increment value on UPDATE as well as on INSERT. This is
        // only valid when the PK is an integer column: for a varchar/string PK
        // (e.g. xdaofood_setting.key) LAST_INSERT_ID(string) coerces the value
        // to an int and fails with "Truncated incorrect INTEGER value" (errno
        // 1292). In that case fall back to VALUES(`pk`) which carries the real
        // string unchanged.
        if (pk_is_integer) {
            try buf.print("`{s}`=LAST_INSERT_ID(`{s}`)", .{ pk_field, pk_field });
        } else {
            try buf.print("`{s}`=VALUES(`{s}`)", .{ pk_field, pk_field });
        }
        for (columns) |col| {
            if (std.mem.eql(u8, col, pk_field)) continue;
            try buf.appendSlice(", ");
            if (findUpsertExpr(update_exprs, col)) |expr| {
                const expanded = try expandUpsertExpr(allocator, true, table_name, expr);
                defer allocator.free(expanded);
                try buf.print("`{s}`={s}", .{ col, expanded });
            } else {
                try buf.print("`{s}`=VALUES(`{s}`)", .{ col, col });
            }
        }
        return try buf.toOwnedSlice();
    }
    // PostgreSQL AND SQLite (bulk path): ON CONFLICT ("cols") DO UPDATE SET …
    // (is_postgres is unused beyond this branch — keep for signature clarity).
    _ = is_postgres;
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try buf.appendSlice(" ON CONFLICT (");
    for (conflict_columns, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(", ");
        try buf.print("\"{s}\"", .{col});
    }
    try buf.appendSlice(") DO UPDATE SET ");
    var first = true;
    for (columns) |col| {
        if (std.mem.eql(u8, col, pk_field)) continue;
        var is_conflict_col = false;
        for (conflict_columns) |cc| {
            if (std.mem.eql(u8, col, cc)) {
                is_conflict_col = true;
                break;
            }
        }
        if (is_conflict_col) continue;
        if (!first) try buf.appendSlice(", ");
        first = false;
        if (findUpsertExpr(update_exprs, col)) |expr| {
            const expanded = try expandUpsertExpr(allocator, false, table_name, expr);
            defer allocator.free(expanded);
            try buf.print("\"{s}\"={s}", .{ col, expanded });
        } else {
            try buf.print("\"{s}\"=EXCLUDED.\"{s}\"", .{ col, col });
        }
    }
    return try buf.toOwnedSlice();
}

/// Maximum number of bound parameters one statement may carry. SQLite's
/// SQLITE_MAX_VARIABLE_NUMBER is 999 on builds older than 3.32, which is the
/// binding constraint here; PostgreSQL and MySQL cap placeholders at 65535.
/// Callers chunk rows so a large batch degrades into several statements
/// instead of failing on the driver's limit.
fn maxBindParams(dialect: Dialect) usize {
    return switch (dialect.kind()) {
        // `Dialect.sqlite`'s name is "sqlite3"; the arm used to ask for
        // "sqlite", which matched nothing and left SQLite sized for the 65535
        // cap. `.unknown` takes the conservative cap too: a name this library
        // does not know gets the value that cannot produce a statement a server
        // refuses, at the cost of a smaller batch.
        .sqlite, .unknown => 999,
        .postgres, .mysql => 65535,
    };
}

/// Generate a Bulk Insert builder for an entity.
/// Supports INSERT ... VALUES (...), (...) RETURNING "id" for backends
/// that support RETURNING (SQLite 3.35+, PostgreSQL, MySQL 8.0.19+).
pub fn BulkInsertBuilder(comptime infos: []const TypeInfo, comptime info: TypeInfo, comptime Entity: type) type {
    _ = infos;
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        driver: sql_driver.Driver,
        rows: std.array_list.Managed(std.array_list.Managed(FieldValue)),
        json_strings: std.array_list.Managed([]const u8),
        hooks: []const Hook,
        privacy_ctx: ?privacy.PrivacyContext = null,
        timeout_ms: ?u32 = null,
        execution_context: sql_driver.ExecutionContext = .{},
        upsert_conflict_columns: ?[]const []const u8 = null,
        interceptors: ?*intercept.InterceptorChain = null,
        /// Explicit per-statement row budget; 0 derives it from the dialect's
        /// bound-parameter limit. Set it to bound statement size (e.g. for
        /// MySQL max_allowed_packet) or to exercise chunk boundaries.
        chunk_rows_override: usize = 0,

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver, hooks: []const Hook, privacy_ctx: ?privacy.PrivacyContext) !Self {
            var self = Self{
                .allocator = allocator,
                .driver = driver,
                .hooks = hooks,
                .privacy_ctx = privacy_ctx,
                .rows = std.array_list.Managed(std.array_list.Managed(FieldValue)).init(allocator),
                .json_strings = std.array_list.Managed([]const u8).init(allocator),
            };
            try self.rows.append(std.array_list.Managed(FieldValue).init(allocator));
            return self;
        }

        pub fn deinit(self: *Self) void {
            for (self.json_strings.items) |s| self.allocator.free(s);
            self.json_strings.deinit();
            for (self.rows.items) |*row| row.deinit();
            self.rows.deinit();
        }

        /// Set a per-query timeout in milliseconds. The deadline is computed
        /// immediately before execution and passed to the driver.
        pub fn withTimeout(self: *Self, ms: u32) *Self {
            self.timeout_ms = ms;
            return self;
        }

        /// Override the derived per-statement row budget (0 = derive from the
        /// dialect's bound-parameter limit). Rows are inserted in chunks of at
        /// most this many rows; every chunk reports its own ids, so the caller
        /// still receives one id per row.
        pub fn chunkRows(self: *Self, rows: usize) *Self {
            self.chunk_rows_override = rows;
            return self;
        }

        fn ensureDeadline(self: *Self) void {
            if (self.timeout_ms) |ms| {
                self.execution_context.deadline_ns = sql_driver.monotonicNs() + @as(i64, ms) * std.time.ns_per_ms;
            }
        }

        /// Start a new row in the bulk insert batch.
        pub fn Next(self: *Self) !*Self {
            try self.rows.append(std.array_list.Managed(FieldValue).init(self.allocator));
            return self;
        }

        pub fn setValue(self: *Self, name: []const u8, value: sql.Value) !*Self {
            var row = &self.rows.items[self.rows.items.len - 1];
            try row.append(.{ .name = name, .value = value });
            return self;
        }

        /// Set a field value with compile-time name and type checking.
        ///
        /// The accepted shapes are decided by `codegen.field_value` and pinned
        /// in both directions by its tests: `Int` ← `i64`/`comptime_int`,
        /// `Float` ← `f64`/`comptime_float`, `Bool` ← `bool`, string-ish fields
        /// ← `[]const u8` or a string literal, `JSON` ← the field's own Zig
        /// type (or `std.json.Value` for `field.JSONValue`), `Optional(T)` ← a
        /// bare value for `T`, an `?T`, or a bare `null` literal. A wrong pair is a `@compileError`
        /// naming the field and both types.
        pub fn setFieldValue(self: *Self, comptime field_name: []const u8, value: anytype) !*Self {
            comptime var needs_json = false;
            comptime {
                var found = false;
                for (info.fields) |f| {
                    if (std.mem.eql(u8, f.name, field_name)) {
                        const Expected = if (f.optional) ?f.zig_type else f.zig_type;
                        const Actual = @TypeOf(value);
                        if (!field_value.accepts(Expected, Actual)) {
                            @compileError("Type mismatch for field '" ++ field_name ++ "': expected " ++ @typeName(Expected) ++ ", got " ++ @typeName(Actual));
                        }
                        if (f.field_type == .json and
                            (@typeInfo(Actual) == .@"struct" or Actual == std.json.Value))
                        {
                            needs_json = true;
                        }
                        found = true;
                        break;
                    }
                }
                if (!found) @compileError("Unknown field: " ++ field_name);
            }

            if (comptime needs_json) {
                const json_str = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
                try self.json_strings.append(json_str);
                return try self.setValue(field_name, .{ .string = json_str });
            }

            return try self.setValue(field_name, field_value.toSqlValue(value));
        }

        const SaveError = sql_driver.Error || HookError || error{ PrivacyDenied, TypeMismatch, ColumnCountMismatch, ValidationFailed, InterceptFailed, MissingLastInsertId, InconsistentRowFields };

        fn runInterceptors(self: *Self) error{InterceptFailed}!void {
            const chain = self.interceptors orelse return;
            var view = intercept.QueryView{
                .op = .create,
                .table_name = info.table_name,
                .sink = self,
                .add_eq_fn = addEqField,
            };
            chain.run(&view) catch return error.InterceptFailed;
        }

        /// Fill omitted columns on every row already in the batch.
        fn addEqField(sink: *anyopaque, field_name: []const u8, value: sql.Value) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(sink));
            var found = false;
            inline for (info.fields) |f| {
                if (std.mem.eql(u8, f.name, field_name)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.UnknownField;
            for (self.rows.items) |*row| {
                var already = false;
                for (row.items) |fv| {
                    if (std.mem.eql(u8, fv.name, field_name)) {
                        already = true;
                        break;
                    }
                }
                if (!already) try row.append(.{ .name = field_name, .value = value });
            }
        }

        /// Insert every row of the batch and return one id per row, in the order
        /// the rows were added.
        ///
        /// A batch is **one** multi-row statement (per chunk), so it carries one
        /// column list — the first row's — and every row must name the same
        /// fields in the same order. A row that does not is rejected with
        /// `error.InconsistentRowFields` *before* any statement runs: the values
        /// of such a row are flattened in its own order, so a row missing a
        /// field would leave allocator-fill bytes bound as its value, an extra
        /// field would run past the flattened buffer, and the length check in
        /// `sql.MultiInsert` would hold throughout. The batch is not written and
        /// the row index is reported in a `warn`.
        pub fn Save(self: *Self) SaveError!std.array_list.Managed(i64) {
            return self.saveInternal(false, null);
        }

        /// Bulk upsert: INSERT … ON CONFLICT ("id") DO UPDATE SET … for
        /// SQLite/PostgreSQL (single-row SaveOrUpdate uses INSERT OR REPLACE
        /// on SQLite; the bulk path prefers ON CONFLICT so unspecified
        /// columns are preserved), ON DUPLICATE KEY UPDATE for MySQL. Returns
        /// one id per row — `RETURNING` where the dialect has it, and one
        /// statement per row on MySQL, whose `last_insert_id` is the id of the
        /// row it just wrote (the emitted `id=LAST_INSERT_ID(id)` is what makes
        /// an updated row answer its existing id). A driver that reports none
        /// makes the call `error.MissingLastInsertId` rather than a fabricated
        /// run of ids. Rows that disagree on their fields are rejected with
        /// `error.InconsistentRowFields`, as in `Save`.
        pub fn SaveOrUpdate(self: *Self) SaveError!std.array_list.Managed(i64) {
            return self.saveInternal(true, null);
        }

        /// Bulk upsert using the given columns as the conflict target instead
        /// of the primary key. Requires a matching UNIQUE index.
        pub fn SaveOrUpdateOn(self: *Self, conflict_columns: []const []const u8) SaveError!std.array_list.Managed(i64) {
            self.upsert_conflict_columns = conflict_columns;
            return self.saveInternal(true, conflict_columns);
        }

        fn saveInternal(self: *Self, comptime or_replace: bool, conflict_columns: ?[]const []const u8) SaveError!std.array_list.Managed(i64) {
            if (info.policy) |p| {
                var ctx = self.privacy_ctx orelse return error.PrivacyDenied;
                ctx.op = .create;
                const result = p.eval(ctx);
                if (result.decision == .deny) return error.PrivacyDenied;
            }
            try self.runInterceptors();
            var hook_ctx = HookContext{
                .op = .create,
                .table_name = info.table_name,
                .privacy = blk: {
                    var pc = self.privacy_ctx orelse privacy.PrivacyContext{};
                    pc.op = .create;
                    break :blk pc;
                },
            };
            try rthook.globalBefore(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .create) {
                    if (h.before) |f| try f(&hook_ctx);
                }
            }
            errdefer {
                rthook.globalAfter(&hook_ctx);
                for (self.hooks) |h| {
                    if (h.op == .create) {
                        if (h.after) |f| f(&hook_ctx) catch |err| {
                            zent_log.warn("after-hook failed on table '{s}' ({s}): {s}", .{ hook_ctx.table_name, @tagName(hook_ctx.op), @errorName(err) });
                        };
                    }
                }
            }

            // Remove trailing empty row if user called Next() at the end
            while (self.rows.items.len > 0 and self.rows.items[self.rows.items.len - 1].items.len == 0) {
                var last = self.rows.pop().?;
                last.deinit();
            }

            if (self.rows.items.len == 0) {
                return std.array_list.Managed(i64).init(self.allocator);
            }

            // Every row must name the same fields in the same positions as the
            // first one, checked before any statement runs.
            //
            // The batch is emitted as one statement with one column list — the
            // first row's — while each row's values are flattened in *that row's*
            // own order, so a row that disagrees does not fail anywhere: its
            // values are bound to the wrong columns, a row missing a field
            // leaves the tail of its flattened values at allocator-fill bytes
            // (`0xaa` under `std.testing.allocator`), an extra field runs past
            // the flattened buffer, and `MultiInsert`'s
            // `values.len == columns.len * row_count` holds in every one of
            // those cases. A batch that would be written wrong is not written
            // at all.
            //
            // Compared **by position, not as a set**: rows holding the same
            // fields in a different order bind just as wrongly, so a set
            // comparison would let the very bug this rejects through. The
            // container does not reorder a caller's row to guess which reading
            // was meant — `error.NoFieldsToUpdate` (a `SET`-less UPDATE) and
            // `error.NoPredicate` are the other two errors that name the
            // caller's mistake instead of resolving it silently.
            const first_row = self.rows.items[0];
            for (self.rows.items[1..], 1..) |row, row_index| {
                if (row.items.len != first_row.items.len) {
                    zent_log.warn("bulk insert into '{s}': row {d} sets {d} field(s) where row 0 sets {d} — the batch was not executed", .{ info.table_name, row_index, row.items.len, first_row.items.len });
                    return error.InconsistentRowFields;
                }
                for (row.items, first_row.items, 0..) |fv, first_fv, field_index| {
                    if (!std.mem.eql(u8, fv.name, first_fv.name)) {
                        zent_log.warn("bulk insert into '{s}': row {d} sets '{s}' at position {d} where row 0 sets '{s}' — the batch was not executed", .{ info.table_name, row_index, fv.name, field_index, first_fv.name });
                        return error.InconsistentRowFields;
                    }
                }
            }

            // Validate all rows
            for (self.rows.items) |row| {
                for (row.items) |fv| {
                    inline for (info.fields) |f| {
                        if (std.mem.eql(u8, f.name, fv.name)) {
                            try validateSqlValue(f, fv.value);
                        }
                    }
                }
            }

            var columns = std.array_list.Managed([]const u8).init(self.allocator);
            defer columns.deinit();
            for (first_row.items) |fv| {
                try columns.append(columnName(info, fv.name));
            }

            const cols_per_row = columns.items.len;

            // Build multi-row INSERT SQL.
            const dialect = self.driver.dialect();
            const dialect_kind = dialect.kind();
            const supports_returning = dialect_kind != .mysql;
            const is_postgres = dialect_kind == .postgres;
            const is_mysql = dialect_kind == .mysql;
            const mapped_conflict: ?[]const []const u8 = if (conflict_columns) |cc| blk: {
                const buf = try self.allocator.alloc([]const u8, cc.len);
                for (cc, 0..) |c, ci| buf[ci] = columnName(info, c);
                break :blk buf;
            } else null;
            defer if (mapped_conflict) |m| self.allocator.free(m);
            const pk_col = pkColumn(info);
            const upsert_conflict_cols: []const []const u8 = mapped_conflict orelse &[_][]const u8{pk_col};
            const pk_is_integer = comptime @TypeOf(@field(@import("../sql/scan.zig").zeroInit(Entity), info.pk_field)) == i64;
            const upsert_suffix: []const u8 = try buildUpsertSuffix(self.allocator, or_replace, is_postgres, false, is_mysql, columns.items, upsert_conflict_cols, pk_col, pk_is_integer, null, info.table_name);
            defer if (upsert_suffix.len > 0) self.allocator.free(upsert_suffix);

            var ids = std.array_list.Managed(i64).init(self.allocator);
            errdefer ids.deinit();

            // A single INSERT cannot carry more bound parameters than the
            // driver allows (SQLite's SQLITE_MAX_VARIABLE_NUMBER is 999 on
            // older builds), so the rows are inserted in chunks that stay
            // inside the budget instead of failing outright on a large batch.
            const chunk_rows = if (self.chunk_rows_override > 0)
                self.chunk_rows_override
            else
                @max(@as(usize, 1), maxBindParams(dialect) / cols_per_row);

            var start_row: usize = 0;
            while (start_row < self.rows.items.len) {
                const end_row = @min(start_row + chunk_rows, self.rows.items.len);
                const rows_in_chunk = end_row - start_row;

                const chunk_values = try self.allocator.alloc(sql.Value, cols_per_row * rows_in_chunk);
                defer self.allocator.free(chunk_values);
                {
                    var vi: usize = 0;
                    for (self.rows.items[start_row..end_row]) |row| {
                        for (row.items) |fv| {
                            chunk_values[vi] = fv.value;
                            vi += 1;
                        }
                    }
                }

                if (supports_returning) {
                    const query = sql.MultiInsert(self.allocator, dialect, info.table_name, columns.items, rows_in_chunk, chunk_values) catch |err| return mapBuildError(err);
                    defer query.deinit();

                    // SQLite / PostgreSQL: append RETURNING clause and query.
                    const ret_suffix = try std.fmt.allocPrint(self.allocator, " RETURNING \"{s}\"", .{pk_col});
                    defer self.allocator.free(ret_suffix);
                    const full_sql = try self.allocator.alloc(u8, query.sql.len + upsert_suffix.len + ret_suffix.len);
                    defer self.allocator.free(full_sql);
                    var pos: usize = 0;
                    @memcpy(full_sql[pos..][0..query.sql.len], query.sql);
                    pos += query.sql.len;
                    @memcpy(full_sql[pos..][0..upsert_suffix.len], upsert_suffix);
                    pos += upsert_suffix.len;
                    @memcpy(full_sql[pos..][0..ret_suffix.len], ret_suffix);

                    self.ensureDeadline();
                    var rows = try self.driver.queryCtx(&self.execution_context, full_sql, query.args);
                    defer rows.deinit();
                    while (rows.next()) |row| {
                        const id = row.getInt(0) orelse return error.TypeMismatch;
                        try ids.append(id);
                    }
                } else {
                    // MySQL has no RETURNING, and one statement cannot answer a
                    // per-row id either: `LAST_INSERT_ID()` answers the
                    // statement's *first generated* value, while the ODKU arm
                    // that the suffix emits (`id=LAST_INSERT_ID(id)`) answers the
                    // existing id for a row it updated. Deriving `base + i` from
                    // one statement invents ids as soon as a chunk collides —
                    // measured on MySQL 9.3, a 3-row ODKU whose first row
                    // collided reported `base = 2` for true ids [1, 2, 3], so
                    // every fabricated id was wrong and the last (4) named no
                    // row at all. Send the chunk one statement at a time and
                    // keep the id the driver reports for each row: the batch then
                    // answers exactly what the single-row path answers,
                    // including the error for a driver that reports no id —
                    // which `0` cannot express.
                    for (0..rows_in_chunk) |ri| {
                        const row_values = chunk_values[ri * cols_per_row ..][0..cols_per_row];
                        const query = sql.MultiInsert(self.allocator, dialect, info.table_name, columns.items, 1, row_values) catch |err| return mapBuildError(err);
                        defer query.deinit();

                        const full_sql = try self.allocator.alloc(u8, query.sql.len + upsert_suffix.len);
                        defer self.allocator.free(full_sql);
                        @memcpy(full_sql[0..query.sql.len], query.sql);
                        @memcpy(full_sql[query.sql.len..], upsert_suffix);

                        self.ensureDeadline();
                        const res = try self.driver.execCtx(&self.execution_context, full_sql, query.args);
                        try ids.append(res.last_insert_id orelse return error.MissingLastInsertId);
                    }
                }

                start_row = end_row;
            }

            // After hooks on success.
            rthook.globalAfter(&hook_ctx);
            for (self.hooks) |h| {
                if (h.op == .create) {
                    if (h.after) |f| f(&hook_ctx) catch |err| {
                        zent_log.warn("after-hook failed on table '{s}' ({s}): {s}", .{ hook_ctx.table_name, @tagName(hook_ctx.op), @errorName(err) });
                    };
                }
            }

            return ids;
        }
    };
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Create builder basic" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const Builder = CreateBuilder(infos, info, UserEntity);

    var b = Builder.init(std.testing.allocator, undefined, &.{}, null);
    defer b.deinit();

    // Test the internal setValue method
    _ = try b.setValue("name", .{ .string = "alice" });
    try std.testing.expectEqual(@as(usize, 1), b.values.items.len);
}

test "BulkInsert builder basic" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const BulkBuilder = BulkInsertBuilder(infos, info, UserEntity);

    var b = try BulkBuilder.init(std.testing.allocator, undefined, &.{}, null);
    defer b.deinit();

    _ = try b.setFieldValue("name", "alice");
    _ = try b.setFieldValue("age", 30);
    _ = try b.Next();
    _ = try b.setFieldValue("name", "bob");
    _ = try b.setFieldValue("age", 25);

    try std.testing.expectEqual(@as(usize, 2), b.rows.items.len);
    try std.testing.expectEqualStrings("alice", b.rows.items[0].items[0].value.string);
    try std.testing.expectEqual(@as(i64, 25), b.rows.items[1].items[1].value.int);
}

test "validateSqlValue positive" {
    const field_mod = @import("../core/field.zig");
    const f = field_mod.Int("age").Positive();
    const info = FieldInfo{
        .name = f.name,
        .column_name = f.storage_key orelse f.name,
        .field_type = f.field_type,
        .zig_type = i64,
        .sql_type = "INTEGER",
        .optional = false,
        .nillable = false,
        .unique = false,
        .immutable = false,
        .default = .none,
        .validators = f.validators,
        .enum_values = f.enum_values,
        .is_id = false,
    };

    try validateSqlValue(info, .{ .int = 5 });
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info, .{ .int = 0 }));
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info, .{ .int = -1 }));
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info, .{ .string = "x" }));
}

test "validateSqlValue range" {
    const field_mod = @import("../core/field.zig");
    const f = field_mod.Int("age").Range(0, 120);
    const info = FieldInfo{
        .name = f.name,
        .column_name = f.storage_key orelse f.name,
        .field_type = f.field_type,
        .zig_type = i64,
        .sql_type = "INTEGER",
        .optional = false,
        .nillable = false,
        .unique = false,
        .immutable = false,
        .default = .none,
        .validators = f.validators,
        .enum_values = f.enum_values,
        .is_id = false,
    };

    try validateSqlValue(info, .{ .int = 0 });
    try validateSqlValue(info, .{ .int = 120 });
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info, .{ .int = -1 }));
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info, .{ .int = 121 }));
}

test "validateSqlValue match" {
    const field_mod = @import("../core/field.zig");
    const f = field_mod.String("email").Match("@");
    const info = FieldInfo{
        .name = f.name,
        .column_name = f.storage_key orelse f.name,
        .field_type = f.field_type,
        .zig_type = []const u8,
        .sql_type = "TEXT",
        .optional = false,
        .nillable = false,
        .unique = false,
        .immutable = false,
        .default = .none,
        .validators = f.validators,
        .enum_values = f.enum_values,
        .is_id = false,
    };

    try validateSqlValue(info, .{ .string = "a@b.com" });
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info, .{ .string = "invalid" }));
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info, .{ .int = 1 }));
}

test "Create builder SaveOrUpdate compiles" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const Builder = CreateBuilder(infos, info, UserEntity);

    var b = Builder.init(std.testing.allocator, undefined, &.{}, null);
    defer b.deinit();

    _ = try b.setFieldValue("name", "alice");
    _ = try b.setFieldValue("age", 30);
    // We can't actually execute SaveOrUpdate without a real driver,
    // but we verify the method exists and compiles.
    try std.testing.expectEqual(@as(usize, 2), b.values.items.len);
}

test "Create builders expose explicit driver error unions" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const Builder = CreateBuilder(infos, info, UserEntity);
    const BulkBuilder = BulkInsertBuilder(infos, info, UserEntity);
    const SaveError = sql_driver.Error || HookError || error{ PrivacyDenied, NotFound, TypeMismatch, ColumnCountMismatch, ValidationFailed, InterceptFailed, MissingLastInsertId, MissingPrimaryKey };
    const BulkSaveError = sql_driver.Error || HookError || error{ PrivacyDenied, TypeMismatch, ColumnCountMismatch, ValidationFailed, InterceptFailed, MissingLastInsertId, InconsistentRowFields };

    comptime {
        const save_return = @typeInfo(@TypeOf(Builder.Save)).@"fn".return_type.?;
        const save_or_update_return = @typeInfo(@TypeOf(Builder.SaveOrUpdate)).@"fn".return_type.?;
        const bulk_save_return = @typeInfo(@TypeOf(BulkBuilder.Save)).@"fn".return_type.?;
        const bulk_save_or_update_return = @typeInfo(@TypeOf(BulkBuilder.SaveOrUpdate)).@"fn".return_type.?;
        if (@typeInfo(save_return).error_union.error_set != SaveError) @compileError("Create.Save error set is not explicit");
        if (@typeInfo(save_or_update_return).error_union.error_set != SaveError) @compileError("Create.SaveOrUpdate error set is not explicit");
        if (@typeInfo(bulk_save_return).error_union.error_set != BulkSaveError) @compileError("BulkInsert.Save error set is not explicit");
        if (@typeInfo(bulk_save_or_update_return).error_union.error_set != BulkSaveError) @compileError("BulkInsert.SaveOrUpdate error set is not explicit");
    }
}

test "validators: not_empty / length / email / phone" {
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const Profile = Schema("ProfileV", .{
        .fields = &.{
            field.String("username").NotEmpty().Length(3, 20),
            field.String("email").Email(),
            field.String("phone").Phone(),
        },
    });
    const info = comptime fromSchema(Profile);

    try validateSqlValue(info.fields[1], .{ .string = "abc" });
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info.fields[1], .{ .string = "" }));
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info.fields[1], .{ .string = "ab" }));
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info.fields[1], .{ .string = "abcdefghijklmnopqrstu" }));

    try validateSqlValue(info.fields[2], .{ .string = "a@b.com" });
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info.fields[2], .{ .string = "a@" }));
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info.fields[2], .{ .string = "a b@c.com" }));

    try validateSqlValue(info.fields[3], .{ .string = "+8613800138000" });
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info.fields[3], .{ .string = "123" }));
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info.fields[3], .{ .string = "12ab89012" }));
}

test "custom validator uses wildcard matching" {
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const Order = Schema("OrderNo", .{
        .fields = &.{
            field.String("no").Custom("ORD-*"),
            field.String("code").Custom("AB?X"),
        },
    });
    const info = comptime fromSchema(Order);

    try validateSqlValue(info.fields[1], .{ .string = "ORD-12345" });
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info.fields[1], .{ .string = "X-1" }));

    try validateSqlValue(info.fields[2], .{ .string = "AB9X" });
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info.fields[2], .{ .string = "AB99X" }));
    try std.testing.expectError(error.ValidationFailed, validateSqlValue(info.fields[2], .{ .string = "A9X" }));
}

test "create with edges schema setFieldValue compiles" {
    const field = @import("../core/field.zig");
    const edge = @import("../core/edge.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;

    const Comment = schema("Comment2", .{ .fields = &.{field.String("body")} });
    const Post = schema("Post2", .{
        .fields = &.{ field.Int("author_id"), field.String("title") },
        .edges = &.{edge.To("comments", Comment)},
    });
    const post_info = comptime fromSchema(Post);
    const comment_info = comptime fromSchema(Comment);
    const infos = &[_]TypeInfo{ post_info, comment_info };
    const Builder = CreateBuilder(infos, post_info, EntityGen(infos, post_info));
    var b = Builder.init(std.testing.allocator, undefined, &.{}, null);
    defer b.deinit();
    _ = try b.setFieldValue("title", "hello");
}

/// A driver whose `exec` answers the ids in `script`, one call at a time, and
/// `null` where it has none to give. `driver.Result.last_insert_id` is `?i64`
/// *because* a driver may have nothing to report — the in-tree MySQL driver
/// always answers `Some`, so only a driver that says "no id" on purpose can
/// reach those branches, the same way `UncountedDriver` reaches the
/// unknown-row-count one.
const IdScriptDriver = struct {
    /// One entry per `exec` call; a `null` entry is a driver with no id.
    script: []const ?i64,
    /// Answered by calls past the end of `script`.
    repeat: ?i64 = null,
    exec_calls: usize = 0,
    /// Rows the next `exec` reports as affected; defaults to the in-tree
    /// drivers' one-row INSERT answer so existing callers see no change.
    exec_rows_affected: usize = 1,
    /// Copy of the statement the last `exec` saw — copied because the builder
    /// that produced it is deinit'd before the test can look at it.
    last_sql_owned: ?[]u8 = null,

    const vtable = sql_driver.Driver.VTable{
        .exec = exec,
        .query = query,
        .beginTx = beginTx,
        .beginSavepoint = beginSavepoint,
        .close = close,
        .dialect = dialect,
        .ping = ping,
        .inTransaction = inTransaction,
    };

    fn asDriver(self: *IdScriptDriver) sql_driver.Driver {
        return sql_driver.Driver{ .ptr = self, .vtable = &vtable };
    }

    fn freeCapture(self: *IdScriptDriver) void {
        if (self.last_sql_owned) |s| std.testing.allocator.free(s);
        self.last_sql_owned = null;
    }

    fn exec(ptr: *anyopaque, _: ?*const sql_driver.ExecutionContext, query_sql: []const u8, _: []const sql.Value) sql_driver.Error!sql_driver.Result {
        const self: *IdScriptDriver = @ptrCast(@alignCast(ptr));
        const id = if (self.exec_calls < self.script.len) self.script[self.exec_calls] else self.repeat;
        self.exec_calls += 1;
        self.freeCapture();
        self.last_sql_owned = std.testing.allocator.dupe(u8, query_sql) catch null;
        return .{ .rows_affected = self.exec_rows_affected, .last_insert_id = id };
    }

    fn query(_: *anyopaque, _: ?*const sql_driver.ExecutionContext, _: []const u8, _: []const sql.Value) sql_driver.Error!sql_driver.Rows {
        return error.QueryFailed;
    }

    fn beginTx(_: *anyopaque) sql_driver.Error!sql_driver.Tx {
        return error.TxFailed;
    }

    fn beginSavepoint(_: *anyopaque, _: []const u8) sql_driver.Error!sql_driver.Tx {
        return error.TxFailed;
    }

    fn close(_: *anyopaque) void {}

    fn dialect(_: *anyopaque) Dialect {
        return .mysql;
    }

    fn ping(_: *anyopaque) sql_driver.Error!void {}

    fn inTransaction(_: *anyopaque) bool {
        return false;
    }
};

/// The RETURNING-path sibling of `IdScriptDriver`: `dialect` says `sqlite3`,
/// which the builders treat as a RETURNING dialect, so `Save` drives `query`
/// rather than `exec`. `query` hands back the scripted pk text one call at a
/// time — or no row at all for a `null` entry, the INSERT-or-IGNORE shape —
/// and `error.QueryFailed` past the end of the script, the way the MySQL
/// sibling's `query` always fails. `exec` never runs on this path, so it
/// fails loudly instead of answering.
const ReturningScriptDriver = struct {
    /// One entry per `query` call: the pk text RETURNING hands back, or
    /// `null` for a statement that wrote nothing and returned no row.
    script: []const ?[]const u8,
    /// Answered by calls past the end of `script`.
    repeat: ?[]const u8 = null,
    query_calls: usize = 0,
    /// Copy of the statement the last `query` saw — copied because the
    /// builder that produced it is deinit'd before the test can look at it.
    last_sql_owned: ?[]u8 = null,

    const RowState = struct {
        has_row: bool,
        text: ?[]const u8,
        used: bool = false,
    };

    const rows_vtable = sql_driver.Rows.VTable{
        .next = rowsNext,
        .deinit = rowsDeinit,
        .nextError = null,
    };

    const row_vtable = sql_driver.Row.VTable{
        .columnCount = rowColumnCount,
        .columnName = rowColumnName,
        .getBool = rowGetBool,
        .getInt = rowGetInt,
        .getFloat = rowGetFloat,
        .getText = rowGetText,
        .getBlob = rowGetBlob,
        .isNull = rowIsNull,
    };

    const vtable = sql_driver.Driver.VTable{
        .exec = exec,
        .query = query,
        .beginTx = beginTx,
        .beginSavepoint = beginSavepoint,
        .close = close,
        .dialect = dialect,
        .ping = ping,
        .inTransaction = inTransaction,
    };

    fn asDriver(self: *ReturningScriptDriver) sql_driver.Driver {
        return sql_driver.Driver{ .ptr = self, .vtable = &vtable };
    }

    fn freeCapture(self: *ReturningScriptDriver) void {
        if (self.last_sql_owned) |s| std.testing.allocator.free(s);
        self.last_sql_owned = null;
    }

    fn exec(_: *anyopaque, _: ?*const sql_driver.ExecutionContext, _: []const u8, _: []const sql.Value) sql_driver.Error!sql_driver.Result {
        return error.ExecFailed;
    }

    fn query(ptr: *anyopaque, _: ?*const sql_driver.ExecutionContext, query_sql: []const u8, _: []const sql.Value) sql_driver.Error!sql_driver.Rows {
        const self: *ReturningScriptDriver = @ptrCast(@alignCast(ptr));
        defer self.freeCapture();
        self.last_sql_owned = std.testing.allocator.dupe(u8, query_sql) catch null;
        if (self.query_calls >= self.script.len and self.repeat == null) {
            self.query_calls += 1;
            return error.QueryFailed;
        }
        const entry: ?[]const u8 = if (self.query_calls < self.script.len) self.script[self.query_calls] else self.repeat;
        self.query_calls += 1;
        const state = try std.testing.allocator.create(RowState);
        state.* = .{ .has_row = entry != null, .text = entry };
        return sql_driver.Rows{ .ptr = state, .vtable = &rows_vtable };
    }

    fn beginTx(_: *anyopaque) sql_driver.Error!sql_driver.Tx {
        return error.TxFailed;
    }

    fn beginSavepoint(_: *anyopaque, _: []const u8) sql_driver.Error!sql_driver.Tx {
        return error.TxFailed;
    }

    fn close(_: *anyopaque) void {}

    fn dialect(_: *anyopaque) Dialect {
        return .sqlite;
    }

    fn ping(_: *anyopaque) sql_driver.Error!void {}

    fn inTransaction(_: *anyopaque) bool {
        return false;
    }

    fn rowsNext(ptr: *anyopaque) ?sql_driver.Row {
        const self: *RowState = @ptrCast(@alignCast(ptr));
        if (self.used) return null;
        self.used = true;
        if (!self.has_row) return null;
        return sql_driver.Row{ .ptr = @ptrCast(self), .vtable = &row_vtable };
    }

    fn rowsDeinit(ptr: *anyopaque) void {
        std.testing.allocator.destroy(@as(*RowState, @ptrCast(@alignCast(ptr))));
    }

    fn rowColumnCount(_: *anyopaque) usize {
        return 1;
    }

    fn rowColumnName(_: *anyopaque, _: usize) []const u8 {
        return "id";
    }

    fn rowGetBool(_: *anyopaque, _: usize) ?bool {
        return null;
    }

    fn rowGetInt(_: *anyopaque, _: usize) ?i64 {
        return null;
    }

    fn rowGetFloat(_: *anyopaque, _: usize) ?f64 {
        return null;
    }

    fn rowGetText(ptr: *anyopaque, _: usize) ?[]const u8 {
        const self: *RowState = @ptrCast(@alignCast(ptr));
        return self.text;
    }

    fn rowGetBlob(_: *anyopaque, _: usize) ?[]const u8 {
        return null;
    }

    fn rowIsNull(ptr: *anyopaque, _: usize) bool {
        const self: *RowState = @ptrCast(@alignCast(ptr));
        return self.text == null;
    }
};

test "create: a driver that reports no last_insert_id is an error, not a key of 0" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const Builder = CreateBuilder(infos, info, UserEntity);

    var drv = IdScriptDriver{ .script = &.{null} };
    defer drv.freeCapture();
    var b = Builder.init(std.testing.allocator, drv.asDriver(), &.{}, null);
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    _ = try b.setFieldValue("age", @as(i64, 30));

    // The row was written (the driver ran the statement); the id is what is
    // missing, and `0` is not a report of it.
    try std.testing.expectError(error.MissingLastInsertId, b.Save());
    try std.testing.expectEqual(@as(usize, 1), drv.exec_calls);
}

test "create: an integer key still comes from last_insert_id, unchanged" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;
    const deinitEntity = @import("entity.zig").deinitEntity;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const Builder = CreateBuilder(infos, info, UserEntity);

    var drv = IdScriptDriver{ .script = &.{7} };
    defer drv.freeCapture();
    var b = Builder.init(std.testing.allocator, drv.asDriver(), &.{}, null);
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    _ = try b.setFieldValue("age", @as(i64, 30));

    var entity = try b.Save();
    defer deinitEntity(infos, info, &entity, std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 7), entity.id);
    try std.testing.expectEqualStrings("alice", entity.name);
}

test "bulk insert: one statement per row on MySQL, ids as reported" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const BulkBuilder = BulkInsertBuilder(infos, info, UserEntity);

    // A server handing out consecutive keys: the batch answers 7, 8, 9 — what
    // the old `base_id + i` derivation answered too, so a caller sees no
    // change here.
    var consecutive = IdScriptDriver{ .script = &.{ 7, 8, 9 } };
    defer consecutive.freeCapture();
    var b = try BulkBuilder.init(std.testing.allocator, consecutive.asDriver(), &.{}, null);
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    _ = try b.setFieldValue("age", @as(i64, 30));
    _ = try b.Next();
    _ = try b.setFieldValue("name", "bob");
    _ = try b.setFieldValue("age", @as(i64, 25));
    _ = try b.Next();
    _ = try b.setFieldValue("name", "carol");
    _ = try b.setFieldValue("age", @as(i64, 40));

    const ids = try b.Save();
    defer ids.deinit();
    try std.testing.expectEqualSlices(i64, &.{ 7, 8, 9 }, ids.items);
    try std.testing.expectEqual(@as(usize, 3), consecutive.exec_calls);

    // ... and an upsert whose rows collide answers each row's own id rather
    // than a run offset by the collision (the third is not 3, and not 2 + i).
    var colliding = IdScriptDriver{ .script = &.{ 1, 5, 6 } };
    defer colliding.freeCapture();
    var u = try BulkBuilder.init(std.testing.allocator, colliding.asDriver(), &.{}, null);
    defer u.deinit();
    _ = try u.setFieldValue("name", "alice");
    _ = try u.setFieldValue("age", @as(i64, 30));
    _ = try u.Next();
    _ = try u.setFieldValue("name", "bob");
    _ = try u.setFieldValue("age", @as(i64, 25));
    _ = try u.Next();
    _ = try u.setFieldValue("name", "carol");
    _ = try u.setFieldValue("age", @as(i64, 40));

    const upsert_ids = try u.SaveOrUpdate();
    defer upsert_ids.deinit();
    try std.testing.expectEqualSlices(i64, &.{ 1, 5, 6 }, upsert_ids.items);
    try std.testing.expectEqual(@as(usize, 3), colliding.exec_calls);
    // Each statement carries one row, and still carries the ODKU suffix.
    const sql_text = colliding.last_sql_owned orelse return error.MissingCapture;
    try std.testing.expect(std.mem.indexOf(u8, sql_text, "ON DUPLICATE KEY UPDATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql_text, "), (") == null);
}

test "bulk insert: a driver that reports no last_insert_id is an error, not a run of ids" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const BulkBuilder = BulkInsertBuilder(infos, info, UserEntity);

    var drv = IdScriptDriver{ .script = &.{null} };
    defer drv.freeCapture();
    var b = try BulkBuilder.init(std.testing.allocator, drv.asDriver(), &.{}, null);
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    _ = try b.setFieldValue("age", @as(i64, 30));
    _ = try b.Next();
    _ = try b.setFieldValue("name", "bob");
    _ = try b.setFieldValue("age", @as(i64, 25));

    try std.testing.expectError(error.MissingLastInsertId, b.Save());
    // It stops at the first unanswerable row rather than writing the batch and
    // reporting ids for it afterwards.
    try std.testing.expectEqual(@as(usize, 1), drv.exec_calls);
}

test "bulk insert: a row that names different fields is rejected, and nothing is written" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const BulkBuilder = BulkInsertBuilder(infos, info, UserEntity);

    // Row 0 sets (name, age); row 1 sets `age` only. The batch is one INSERT
    // with row 0's column list, so `25` would be bound to the `name` column and
    // the allocator-fill bytes behind the flattened values to `age` — the
    // statement's own length check (`columns.len * row_count == values.len`)
    // would still hold, because the buffer it reads is allocated for the column
    // list, not sized by what the rows actually set.
    var short_row = IdScriptDriver{ .script = &.{ 1, 2 } };
    defer short_row.freeCapture();
    var b = try BulkBuilder.init(std.testing.allocator, short_row.asDriver(), &.{}, null);
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    _ = try b.setFieldValue("age", @as(i64, 30));
    _ = try b.Next();
    _ = try b.setFieldValue("age", @as(i64, 25));

    try std.testing.expectError(error.InconsistentRowFields, b.Save());
    // Rejected before the statement: the driver was never asked to run it, so
    // no row of the batch exists.
    try std.testing.expectEqual(@as(usize, 0), short_row.exec_calls);
    try std.testing.expectEqual(@as(?[]u8, null), short_row.last_sql_owned);

    // Row 1 sets one field more than row 0 (a name the schema does not have,
    // through the unchecked `setValue`). Flattened, its third value ran past
    // the buffer sized from row 0 — an index-out-of-bounds panic in a safe
    // build rather than a wrong write.
    var long_row = IdScriptDriver{ .script = &.{ 3, 4 } };
    defer long_row.freeCapture();
    var b2 = try BulkBuilder.init(std.testing.allocator, long_row.asDriver(), &.{}, null);
    defer b2.deinit();
    _ = try b2.setFieldValue("name", "carol");
    _ = try b2.setFieldValue("age", @as(i64, 40));
    _ = try b2.Next();
    _ = try b2.setFieldValue("name", "dave");
    _ = try b2.setFieldValue("age", @as(i64, 50));
    _ = try b2.setValue("nickname", .{ .string = "d" });

    try std.testing.expectError(error.InconsistentRowFields, b2.Save());
    try std.testing.expectEqual(@as(usize, 0), long_row.exec_calls);
}

test "bulk insert: rows holding the same fields in another order are rejected too" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const BulkBuilder = BulkInsertBuilder(infos, info, UserEntity);

    // Same *set* of names, different order. A set comparison would call this
    // batch consistent and then bind row 1's `25` to `name` and `"bob"` to
    // `age`, silently — which is why the check compares by position.
    var drv = IdScriptDriver{ .script = &.{ 1, 2 } };
    defer drv.freeCapture();
    var b = try BulkBuilder.init(std.testing.allocator, drv.asDriver(), &.{}, null);
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    _ = try b.setFieldValue("age", @as(i64, 30));
    _ = try b.Next();
    _ = try b.setFieldValue("age", @as(i64, 25));
    _ = try b.setFieldValue("name", "bob");

    try std.testing.expectError(error.InconsistentRowFields, b.Save());
    try std.testing.expectEqual(@as(usize, 0), drv.exec_calls);
}

test "bulk insert: a leading empty row is a named error, not a divide by zero" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const BulkBuilder = BulkInsertBuilder(infos, info, UserEntity);

    // `Next()` before the first `setFieldValue` — a plausible reading of the
    // API ("start the first row") — leaves row 0 empty while row 1 carries the
    // fields. Only *trailing* empty rows are trimmed, so the column list came
    // from an empty row: `maxBindParams / 0` divided by zero before anything
    // compared the rows.
    var drv = IdScriptDriver{ .script = &.{1} };
    defer drv.freeCapture();
    var b = try BulkBuilder.init(std.testing.allocator, drv.asDriver(), &.{}, null);
    defer b.deinit();
    _ = try b.Next();
    _ = try b.setFieldValue("name", "alice");
    _ = try b.setFieldValue("age", @as(i64, 30));

    try std.testing.expectError(error.InconsistentRowFields, b.Save());
    try std.testing.expectEqual(@as(usize, 0), drv.exec_calls);
}

test "create: a MySQL uuid key is the caller's value, and the driver needs no id" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;
    const deinitEntity = @import("entity.zig").deinitEntity;

    const Doc = schema("MyUuidDoc", .{
        .fields = &.{ field.UUID("id"), field.String("title") },
    });

    const info = comptime fromSchema(Doc);
    const infos = &[_]TypeInfo{info};
    const DocEntity = comptime EntityGen(infos, info);
    const Builder = CreateBuilder(infos, info, DocEntity);

    // A driver with no id to report at all: a textual key does not come from
    // `last_insert_id`, so the insert still answers the row the caller named.
    var drv = IdScriptDriver{ .script = &.{} };
    defer drv.freeCapture();
    var b = Builder.init(std.testing.allocator, drv.asDriver(), &.{}, null);
    defer b.deinit();
    _ = try b.setFieldValue("id", "01920000-0000-7000-8000-0000000000f2");
    _ = try b.setFieldValue("title", "t");

    var entity = try b.Save();
    defer deinitEntity(infos, info, &entity, std.testing.allocator);
    try std.testing.expectEqualStrings("01920000-0000-7000-8000-0000000000f2", entity.id);
    try std.testing.expectEqualStrings("t", entity.title);
    try std.testing.expectEqual(@as(usize, 1), drv.exec_calls);
}

test "create: a MySQL uuid key the caller never set is an error before the statement" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;

    const Doc = schema("MyUuidDoc", .{
        .fields = &.{ field.UUID("id"), field.String("title") },
    });

    const info = comptime fromSchema(Doc);
    const infos = &[_]TypeInfo{info};
    const DocEntity = comptime EntityGen(infos, info);
    const Builder = CreateBuilder(infos, info, DocEntity);

    // MySQL has no RETURNING and the library generates no key, so the entity's
    // id used to stay at the zero value — an empty string, which names no row
    // while looking like a key that names one, and which every later call would
    // pass around as an id.
    var insert_drv = IdScriptDriver{ .script = &.{ 7, 8 } };
    defer insert_drv.freeCapture();
    var b = Builder.init(std.testing.allocator, insert_drv.asDriver(), &.{}, null);
    defer b.deinit();
    _ = try b.setFieldValue("title", "t");

    try std.testing.expectError(error.MissingPrimaryKey, b.Save());
    // Decided before the statement: no key-less row is written for the caller
    // to find later.
    try std.testing.expectEqual(@as(usize, 0), insert_drv.exec_calls);

    // The upsert path resolves its conflict target the same way.
    var upsert_drv = IdScriptDriver{ .script = &.{9} };
    defer upsert_drv.freeCapture();
    var b2 = Builder.init(std.testing.allocator, upsert_drv.asDriver(), &.{}, null);
    defer b2.deinit();
    _ = try b2.setFieldValue("title", "t");

    try std.testing.expectError(error.MissingPrimaryKey, b2.SaveOrUpdate());
    try std.testing.expectEqual(@as(usize, 0), upsert_drv.exec_calls);
}

test "create: a RETURNING-dialect uuid key the caller never set is an error before the statement" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;

    const Doc = schema("RetUuidDoc", .{
        .fields = &.{ field.UUID("id"), field.String("title") },
    });

    const info = comptime fromSchema(Doc);
    const infos = &[_]TypeInfo{info};
    const DocEntity = comptime EntityGen(infos, info);
    const Builder = CreateBuilder(infos, info, DocEntity);

    // Same mistake as the MySQL case above, one name: without the pre-check
    // the statement runs — PostgreSQL answers NOT NULL, while SQLite accepts
    // the NULL into a TEXT PRIMARY KEY and RETURNING then hands back NULL,
    // reported as `TypeMismatch` *after* the keyless row was written.
    var insert_drv = ReturningScriptDriver{ .script = &.{} };
    defer insert_drv.freeCapture();
    var b = Builder.init(std.testing.allocator, insert_drv.asDriver(), &.{}, null);
    defer b.deinit();
    _ = try b.setFieldValue("title", "t");

    try std.testing.expectError(error.MissingPrimaryKey, b.Save());
    // Decided before the statement: nothing was sent to the driver at all.
    try std.testing.expectEqual(@as(usize, 0), insert_drv.query_calls);

    // The upsert path takes the same RETURNING branch and resolves the same way.
    var upsert_drv = ReturningScriptDriver{ .script = &.{} };
    defer upsert_drv.freeCapture();
    var b2 = Builder.init(std.testing.allocator, upsert_drv.asDriver(), &.{}, null);
    defer b2.deinit();
    _ = try b2.setFieldValue("title", "t");

    try std.testing.expectError(error.MissingPrimaryKey, b2.SaveOrUpdate());
    try std.testing.expectEqual(@as(usize, 0), upsert_drv.query_calls);
}

test "create: SaveIgnore on the RETURNING path logs the rows it actually wrote" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;
    const deinitEntity = @import("entity.zig").deinitEntity;

    // What the logger saw lives at container level: the callbacks carry no
    // user pointer (same shape as `update_delete.zig`'s Seen).
    const Seen = struct {
        var calls: usize = 0;
        var rows: usize = 999;
        var known: bool = false;

        fn onExec(ctx: LogContext) void {
            calls += 1;
            rows = ctx.rows_affected;
            known = ctx.rows_affected_known;
        }
    };

    const Doc = schema("IgnoreLogDoc", .{
        .fields = &.{ field.Int("id"), field.String("title") },
    });

    const info = comptime fromSchema(Doc);
    const infos = &[_]TypeInfo{info};
    const DocEntity = comptime EntityGen(infos, info);
    const Builder = CreateBuilder(infos, info, DocEntity);

    // A `null` script entry is the ignored-insert shape: the statement ran,
    // the server wrote nothing, and RETURNING came back with no row.
    var drv = ReturningScriptDriver{ .script = &.{null} };
    defer drv.freeCapture();
    var b = Builder.init(std.testing.allocator, drv.asDriver(), &.{}, null);
    defer b.deinit();
    b.logger = .{ .onExec = Seen.onExec };
    _ = try b.setFieldValue("title", "t");

    var entity = try b.SaveIgnore();
    defer deinitEntity(infos, info, &entity, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), Seen.calls);
    try std.testing.expectEqual(@as(usize, 0), Seen.rows);
    try std.testing.expect(Seen.known);
}

test "create: the MySQL exec path logs the driver's row count" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;
    const deinitEntity = @import("entity.zig").deinitEntity;

    const Seen = struct {
        var calls: usize = 0;
        var rows: usize = 999;
        var known: bool = false;

        fn onExec(ctx: LogContext) void {
            calls += 1;
            rows = ctx.rows_affected;
            known = ctx.rows_affected_known;
        }
    };

    const User = schema("ExecLogUser", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const Builder = CreateBuilder(infos, info, UserEntity);

    // The upsert-updated shape: MySQL counts the UPDATE, so `affected_rows`
    // is 2 while `last_insert_id` still names the row's own key. A hardcoded
    // `1` in the log claimed a single row either way.
    var drv = IdScriptDriver{ .script = &.{7}, .exec_rows_affected = 2 };
    defer drv.freeCapture();
    var b = Builder.init(std.testing.allocator, drv.asDriver(), &.{}, null);
    defer b.deinit();
    b.logger = .{ .onExec = Seen.onExec };
    _ = try b.setFieldValue("name", "alice");
    _ = try b.setFieldValue("age", @as(i64, 30));

    var entity = try b.SaveOrUpdate();
    defer deinitEntity(infos, info, &entity, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), Seen.calls);
    try std.testing.expectEqual(@as(usize, 2), Seen.rows);
    try std.testing.expect(Seen.known);
}

test "create: the after-hook failure warning reaches an installed log sink" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const EntityGen = @import("entity.zig").Entity;
    const deinitEntity = @import("entity.zig").deinitEntity;
    const zent = @import("../root.zig");

    // What the sink saw lives at container level: the callback carries no user
    // pointer (same shape as the `Seen` captures above).
    const Capture = struct {
        var level: zent.runtime.log.Level = .debug;
        var count: usize = 0;
        var text: [256]u8 = undefined;
        var len: usize = 0;

        fn sink(l: zent.runtime.log.Level, message: []const u8) void {
            level = l;
            count += 1;
            len = @min(message.len, text.len);
            @memcpy(text[0..len], message[0..len]);
        }

        fn last() []const u8 {
            return text[0..len];
        }
    };

    const FailingAfter = struct {
        fn after(_: *HookContext) HookError!void {
            return error.HookFailed;
        }
    };

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const UserEntity = comptime EntityGen(infos, info);
    const Builder = CreateBuilder(infos, info, UserEntity);

    zent.runtime.log.setSink(Capture.sink);
    defer zent.runtime.log.setSink(null);
    Capture.count = 0;
    Capture.len = 0;

    const hooks = [_]Hook{Hook.initAfter(.create, FailingAfter.after)};
    var drv = IdScriptDriver{ .script = &.{7} };
    defer drv.freeCapture();
    var b = Builder.init(std.testing.allocator, drv.asDriver(), &hooks, null);
    defer b.deinit();
    _ = try b.setFieldValue("name", "alice");
    _ = try b.setFieldValue("age", @as(i64, 30));

    // The row is written and `Save` succeeds: the hook failure is surfaced,
    // not propagated. It used to go to `std.log` unconditionally, where a
    // consumer had no way to receive it.
    var entity = try b.Save();
    defer deinitEntity(infos, info, &entity, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), Capture.count);
    try std.testing.expectEqual(zent.runtime.log.Level.warn, Capture.level);
    try std.testing.expectEqualStrings("after-hook failed on table 'user' (create): HookFailed", Capture.last());
}

test "the bulk-insert chunk cap is SQLite's 999, not the PostgreSQL/MySQL 65535" {
    // `maxBindParams` decides how many rows a bulk insert puts in one statement
    // (`chunk_rows = maxBindParams / cols_per_row`). It asked for `"sqlite"`,
    // which is not the name of `Dialect.sqlite` (`"sqlite3"`), so the SQLite arm
    // never ran and a wide batch was sized for 65535 bound parameters — past
    // SQLite's `SQLITE_MAX_VARIABLE_NUMBER` (999 on builds before 3.32), which is
    // the failure mode the function exists to prevent. The assertion is on the
    // cap rather than on a statement count because the cap is what chunks are
    // computed from.
    const DialectKind = @import("../sql/dialect.zig").Dialect;
    try std.testing.expectEqual(@as(usize, 999), maxBindParams(DialectKind.sqlite));
    try std.testing.expectEqual(@as(usize, 65535), maxBindParams(DialectKind.postgres));
    try std.testing.expectEqual(@as(usize, 65535), maxBindParams(DialectKind.mysql));
    // A dialect nobody named is treated as SQLite here: the conservative cap is
    // the one that cannot produce a statement a server rejects.
    try std.testing.expectEqual(@as(usize, 999), maxBindParams(Dialect{ .name = "cockroach" }));
    // The spelling mistake itself, pinned so it cannot come back as a literal.
    try std.testing.expectEqual(@as(usize, 999), maxBindParams(Dialect{ .name = "sqlite" }));
}
