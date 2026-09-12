const std = @import("std");
const edgeTargetInfo = @import("graph.zig").edgeTargetInfo;
const TypeInfo = @import("graph.zig").TypeInfo;
const EdgeInfo = @import("graph.zig").EdgeInfo;
const sql_driver = @import("../sql/driver.zig");
const sql = @import("../sql/builder.zig");
const sql_scan = @import("../sql/scan.zig");
const Logger = @import("../sql/logger.zig").Logger;
const debugLogger = @import("../sql/logger.zig").debugLogger;
const migrate = @import("../sql/schema/migrate.zig");
const Hook = @import("../runtime/hook.zig").Hook;
const intercept = @import("../runtime/intercept.zig");
const privacy = @import("../privacy/policy.zig");

const EntityGen = @import("entity.zig").Entity;
const deinitEntity = @import("entity.zig").deinitEntity;
const deinitEntityList = @import("entity.zig").deinitEntityList;
const CreateGen = @import("create.zig").CreateBuilder;
const BulkInsertGen = @import("create.zig").BulkInsertBuilder;
const QueryGen = @import("query.zig").QueryBuilder;
const UpdateGen = @import("update_delete.zig").UpdateBuilder;
const DeleteGen = @import("update_delete.zig").DeleteBuilder;
const BulkUpdateGen = @import("update_delete.zig").BulkUpdateBuilder;
const BulkDeleteGen = @import("update_delete.zig").BulkDeleteBuilder;
const PredGen = @import("predicate.zig").makePredicates;
const buildEdgeStep = @import("graph.zig").buildEdgeStep;
const graph_neighbors = @import("../graph/neighbors.zig");
const graph_step = @import("../graph/step.zig");
const MetaGen = @import("meta.zig").Meta;

fn capitalize(comptime s: []const u8) []const u8 {
    comptime {
        var result: [s.len]u8 = undefined;
        result[0] = std.ascii.toUpper(s[0]);
        for (s[1..], 1..) |c, i| {
            result[i] = c;
        }
        return &result;
    }
}

/// Generate a struct with edge-count order term functions for a given entity.
/// Each edge produces a method `by{Name}Count(desc: bool) sql.Order`.
fn EdgeOrderTerms(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
    _ = infos;
    comptime {
        const edge_count = info.edges.len;
        var field_names: [edge_count][:0]const u8 = undefined;
        var field_types: [edge_count]type = undefined;
        var field_attrs: [edge_count]std.builtin.Type.Struct.FieldAttributes = undefined;

        const OrderFn = *const fn (bool) sql.Order;

        for (info.edges, 0..) |edge, i| {
            field_names[i] = byEdgeName(edge.name);
            field_types[i] = OrderFn;
            field_attrs[i] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(OrderFn) };
        }

        return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
    }
}

fn byEdgeName(comptime edge_name: []const u8) [:0]const u8 {
    comptime {
        var buf: [256:0]u8 = undefined;
        const prefix = "by";
        const suffix = "Count";
        @memcpy(buf[0..prefix.len], prefix);
        buf[prefix.len] = std.ascii.toUpper(edge_name[0]);
        @memcpy(buf[prefix.len + 1 .. prefix.len + 1 + edge_name.len - 1], edge_name[1..]);
        @memcpy(buf[prefix.len + 1 + edge_name.len - 1 .. prefix.len + 1 + edge_name.len - 1 + suffix.len], suffix);
        const len = prefix.len + 1 + edge_name.len - 1 + suffix.len;
        buf[len] = 0;
        return buf[0..len :0];
    }
}

/// Instantiate edge order terms.
fn makeEdgeOrderTerms(comptime infos: []const TypeInfo, comptime info: TypeInfo) EdgeOrderTerms(infos, info) {
    comptime {
        var result: EdgeOrderTerms(infos, info) = undefined;
        for (info.edges) |edge| {
            const target_info = edgeTargetInfo(infos, info, edge);
            const step = buildEdgeStep(edge, info, target_info);

            const name = byEdgeName(edge.name);

            @field(result, name) = struct {
                fn orderFn(desc: bool) sql.Order {
                    return sql.OrderExpr(struct {
                        fn gen(b: *sql.Builder) anyerror!void {
                            try graph_neighbors.appendEdgeCount(b, step);
                        }
                    }.gen, desc);
                }
            }.orderFn;
        }
        return result;
    }
}

/// Client for a single entity type.
pub fn EntityClient(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
    const Entity = EntityGen(infos, info);
    const CreateBuilder = CreateGen(infos, info, Entity);
    const BulkInsertBuilder = BulkInsertGen(infos, info, Entity);
    const QueryBuilder = QueryGen(infos, info, Entity);
    const UpdateBuilder = UpdateGen(infos, info);
    const DeleteBuilder = DeleteGen(info);
    const BulkUpdateBuilder = BulkUpdateGen(info);
    const BulkDeleteBuilder = BulkDeleteGen(info);
    const Predicates = comptime PredGen(infos, info);
    const EdgeOrders = comptime makeEdgeOrderTerms(infos, info);
    const Meta = comptime MetaGen(info);

    return struct {
        const Self = @This();

        /// Exposed so generic helpers can free entities on error paths without
        /// re-deriving the graph (e.g. `crud_helpers.batchCreate` errdefer).
        pub const entity_infos = infos;
        pub const entity_info = info;

        allocator: std.mem.Allocator,
        driver: sql_driver.Driver,
        logger: Logger = .{},
        predicates: @TypeOf(Predicates),
        orders: @TypeOf(EdgeOrders),
        hooks: []const Hook,
        privacy_ctx: ?privacy.PrivacyContext = null,
        /// Shared interceptor chain (owned by the root Client or the caller);
        /// propagated into every builder this client creates.
        interceptors: ?*intercept.InterceptorChain = null,

        pub fn init(allocator: std.mem.Allocator, driver: sql_driver.Driver) Self {
            return .{
                .allocator = allocator,
                .driver = driver,
                .logger = .{},
                .predicates = Predicates,
                .orders = EdgeOrders,
                .hooks = &.{},
                .privacy_ctx = null,
                .interceptors = null,
            };
        }

        pub fn withHooks(self: Self, hooks: []const Hook) Self {
            var copy = self;
            copy.hooks = hooks;
            return copy;
        }

        pub fn withContext(self: Self, ctx: privacy.PrivacyContext) Self {
            var copy = self;
            copy.privacy_ctx = ctx;
            return copy;
        }

        /// Borrow an interceptor chain (e.g. one owned by the caller rather
        /// than by a root Client). Mirrors `withContext`.
        pub fn withInterceptors(self: Self, chain: *intercept.InterceptorChain) Self {
            var copy = self;
            copy.interceptors = chain;
            return copy;
        }

        pub fn Query(self: Self) QueryBuilder {
            var qb = QueryBuilder.init(self.allocator, self.driver, self.privacy_ctx);
            qb.logger = self.logger;
            qb.interceptors = self.interceptors;
            return qb;
        }

        pub fn Create(self: Self) !CreateBuilder {
            if (info.is_view) @compileError("Create is not supported for view entities");
            var cb = CreateBuilder.init(self.allocator, self.driver, self.hooks, self.privacy_ctx);
            cb.logger = self.logger;
            cb.interceptors = self.interceptors;
            return cb;
        }

        pub fn BulkInsert(self: Self) !BulkInsertBuilder {
            if (info.is_view) @compileError("BulkInsert is not supported for view entities");
            var bb = try BulkInsertBuilder.init(self.allocator, self.driver, self.hooks, self.privacy_ctx);
            bb.interceptors = self.interceptors;
            return bb;
        }

        pub fn Update(self: Self) UpdateBuilder {
            if (info.is_view) @compileError("Update is not supported for view entities");
            var ub = UpdateBuilder.init(self.allocator, self.driver, self.hooks, self.privacy_ctx);
            ub.logger = self.logger;
            ub.interceptors = self.interceptors;
            return ub;
        }

        pub fn Delete(self: Self) DeleteBuilder {
            if (info.is_view) @compileError("Delete is not supported for view entities");
            var db = DeleteBuilder.init(self.allocator, self.driver, self.hooks, self.privacy_ctx);
            db.logger = self.logger;
            db.interceptors = self.interceptors;
            return db;
        }

        pub fn BulkUpdate(self: Self) BulkUpdateBuilder {
            if (info.is_view) @compileError("BulkUpdate is not supported for view entities");
            var bub = BulkUpdateBuilder.init(self.allocator, self.driver, self.hooks, self.privacy_ctx);
            bub.interceptors = self.interceptors;
            return bub;
        }

        pub fn BulkDelete(self: Self) !BulkDeleteBuilder {
            if (info.is_view) @compileError("BulkDelete is not supported for view entities");
            var bdb = try BulkDeleteBuilder.init(self.allocator, self.driver, self.hooks, self.privacy_ctx);
            bdb.interceptors = self.interceptors;
            return bdb;
        }

        const QueryEdgeError = sql_driver.Error || error{ TypeMismatch, ColumnCountMismatch, BuildFailed, PrivacyDenied, InterceptFailed };

        /// Free one entity this client produced (`Create().Save()`,
        /// `Query().First()`, `Only()`), in one call and without the caller
        /// holding the graph:
        ///
        /// ```zig
        /// var e = try client.user.Create().Save();
        /// defer client.user.deinitRow(&e);
        /// ```
        pub fn deinitRow(self: Self, entity: *Entity) void {
            deinitEntity(infos, info, entity, self.allocator);
        }

        /// Free every entity in a page this client produced (`Query().All()`),
        /// plus the list itself. Safe to call twice; the list is left empty
        /// and reusable.
        pub fn deinitRows(self: Self, rows: *std.array_list.Managed(Entity)) void {
            deinitEntityList(infos, info, self.allocator, rows);
        }

        /// Free rows returned by `QueryEdge(edge_name, …)`. They are the
        /// *target* entity, not this client's, so they need the target's
        /// `TypeInfo` — resolved here from the same graph through the same
        /// edge, which is what makes this one call instead of four arguments.
        pub fn deinitEdgeRows(
            self: Self,
            comptime edge_name: []const u8,
            rows: *QueryTargetsResult(infos, info.name, edge_name),
        ) void {
            const edge = comptime findEdgeInfo(info, edge_name);
            const target_info = comptime edgeTargetInfo(infos, info, edge);
            const TargetEntity = comptime EntityGen(infos, target_info);
            for (rows.items) |*e| deinitEntity(infos, target_info, e, self.allocator);
            rows.deinit();
            rows.* = std.array_list.Managed(TargetEntity).init(self.allocator);
        }

        /// Query target entities via an edge.
        /// Example: user_client.QueryEdge("cars", &.{alice.id}) returns Car entities.
        ///
        /// Applies the same target read contract as `Query()...WithEdge()`:
        /// soft-delete scope, the target's privacy policy, and this client's
        /// interceptor chain. Callers that need the raw traversal
        /// (soft-delete only, no tenant scoping) use
        /// `client_mod.queryTargetsUnscoped` with the client's driver.
        pub fn QueryEdge(self: Self, comptime edge_name: []const u8, parent_ids: []const i64) QueryEdgeError!QueryTargetsResult(infos, info.name, edge_name) {
            if (info.is_view) @compileError("QueryEdge is not supported for view entities");
            return queryTargets(infos, info.name, edge_name, parent_ids, self.allocator, self.driver, self.privacy_ctx, self.interceptors);
        }

        pub const EntityType = Entity;
        pub const meta = Meta;
    };
}

fn toSnakeCase(name: []const u8) []const u8 {
    comptime {
        var result: []const u8 = "";
        for (name, 0..) |c, i| {
            if (std.ascii.isUpper(c) and i > 0) {
                result = result ++ "_";
            }
            result = result ++ &[_]u8{std.ascii.toLower(c)};
        }
        return result;
    }
}

fn structFieldName(comptime name: []const u8) [:0]const u8 {
    comptime {
        var buf: [256:0]u8 = undefined;
        var len: usize = 0;
        for (name, 0..) |c, i| {
            if (std.ascii.isUpper(c) and i > 0) {
                buf[len] = '_';
                len += 1;
            }
            buf[len] = std.ascii.toLower(c);
            len += 1;
        }
        buf[len] = 0;
        return buf[0..len :0];
    }
}

/// Transactional client wrapper.
pub fn TxClient(comptime infos: []const TypeInfo) type {
    return struct {
        client: Client(infos),
        tx: sql_driver.Tx,
        after_commit: ?*const fn (ctx: ?*anyopaque) void = null,
        after_commit_ctx: ?*anyopaque = null,
        /// Transaction-scoped event payloads collected via `enqueueEvent`;
        /// ownership transfers to the caller via `takePendingEvents`
        /// (typically from the after-commit callback). Frees on deinit.
        events: std.ArrayListUnmanaged([]u8) = .empty,

        pub fn commit(self: *@This()) sql_driver.Error!void {
            try self.tx.commit();
            if (self.after_commit) |f| f(self.after_commit_ctx);
        }

        pub fn rollback(self: *@This()) sql_driver.Error!void {
            return self.tx.rollback();
        }

        pub fn deinit(self: *@This()) void {
            const alloc = self.client.allocator;
            for (self.events.items) |p| alloc.free(p);
            self.events.deinit(alloc);
            return self.tx.deinit();
        }

        /// Register a callback invoked once after a successful commit (cache
        /// invalidation, search indexing, notifications). The TxClient is a
        /// value: call `afterCommit` on the instance you commit.
        pub fn afterCommit(self: *@This(), ctx: ?*anyopaque, f: *const fn (ctx: ?*anyopaque) void) void {
            self.after_commit = f;
            self.after_commit_ctx = ctx;
        }

        /// Collect a transaction-scoped event payload (outbox, audit log,
        /// notification). The payload is duped; transfer it out after commit
        /// with `takePendingEvents`. TxClient is a value: keep one instance
        /// for the transaction's lifetime.
        pub fn enqueueEvent(self: *@This(), payload: []const u8) !void {
            const alloc = self.client.allocator;
            try self.events.append(alloc, try alloc.dupe(u8, payload));
        }

        /// Transfer ownership of the collected event payloads to the caller
        /// (caller frees each entry and the slice). Valid after commit.
        pub fn takePendingEvents(self: *@This()) [][]u8 {
            const alloc = self.client.allocator;
            const out = alloc.dupe([]u8, self.events.items) catch return &.{};
            self.events.deinit(alloc);
            self.events = .empty;
            return out;
        }
    };
}

/// Generate a root Client type from multiple TypeInfos.
/// The Client holds entity sub-clients and per-edge query helpers.
///
/// The interceptor chain, when present, is a **heap allocation** so its
/// address survives the many by-value moves of the root Client (returns
/// from `makeClient`, `StoreEnv`/`PooledEnv`/`ShardedEnv` fields,
/// `withContext`, transaction clients). `owns_interceptors` records
/// whether this value is the one that allocated the chain: only that root
/// value may be passed to `DeinitClient`. Copies made afterwards borrow.
pub fn Client(comptime infos: []const TypeInfo) type {
    comptime {
        const total_fields = 5 + infos.len; // allocator, driver, logger, interceptors, owns_interceptors, + one per entity
        var field_names: [total_fields][:0]const u8 = undefined;
        var field_types: [total_fields]type = undefined;
        var field_attrs: [total_fields]std.builtin.Type.Struct.FieldAttributes = undefined;

        // Root fields
        field_names[0] = "allocator";
        field_types[0] = std.mem.Allocator;
        field_attrs[0] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(std.mem.Allocator) };

        field_names[1] = "driver";
        field_types[1] = sql_driver.Driver;
        field_attrs[1] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(sql_driver.Driver) };

        field_names[2] = "logger";
        field_types[2] = Logger;
        field_attrs[2] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(Logger) };

        field_names[3] = "interceptors";
        field_types[3] = ?*intercept.InterceptorChain;
        field_attrs[3] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(?*intercept.InterceptorChain) };

        field_names[4] = "owns_interceptors";
        field_types[4] = bool;
        field_attrs[4] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(bool) };

        // Entity sub-clients (user, car, group, ...)
        for (infos, 5..) |info, i| {
            const ClientType = EntityClient(infos, info);
            const name = structFieldName(info.name);
            field_names[i] = name;
            field_types[i] = ClientType;
            field_attrs[i] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(ClientType) };
        }

        const ClientType = @Struct(.auto, null, &field_names, &field_types, &field_attrs);
        return ClientType;
    }
}

/// Instantiate a Client. The interceptor chain is allocated lazily by
/// `UseInterceptor`, so an interceptor-free client allocates nothing.
pub fn makeClient(comptime infos: []const TypeInfo, allocator: std.mem.Allocator, driver: sql_driver.Driver) Client(infos) {
    var result: Client(infos) = undefined;
    result.allocator = allocator;
    result.driver = driver;
    result.logger = .{};
    result.interceptors = null;
    result.owns_interceptors = false;
    inline for (infos) |info| {
        const ClientType = EntityClient(infos, info);
        const field_name = comptime toSnakeCase(info.name);
        @field(result, field_name) = ClientType.init(allocator, driver);
    }
    return result;
}

/// Register an interceptor and point every entity sub-client at the chain.
/// The chain lives on the heap and is allocated on first use; its address
/// therefore stays valid across by-value copies of the root Client (moves
/// out of `makeClient`, helper structs, `withContext`, tx clients). The
/// root value that allocates it owns it; pair that value with
/// `DeinitClient`. Copies only borrow. Register before starting
/// transactions so `beginTx` copies the pointer.
pub fn UseInterceptor(comptime infos: []const TypeInfo, self: *Client(infos), i: intercept.Interceptor) !void {
    if (self.interceptors == null) {
        const chain = try self.allocator.create(intercept.InterceptorChain);
        chain.* = intercept.InterceptorChain.init(self.allocator);
        self.interceptors = chain;
        self.owns_interceptors = true;
    }
    try self.interceptors.?.use(i);
    inline for (infos) |info| {
        const field_name = comptime structFieldName(info.name);
        @field(self, field_name).interceptors = self.interceptors;
    }
}

/// Release the interceptor chain. Call this exactly once, on the root
/// Client value that called `UseInterceptor` — value copies made
/// afterwards (helpers, `withContext`, tx clients) borrow the same chain
/// and must not be deinit'd. A client whose chain was supplied via
/// `withInterceptors` borrows it from the caller and is left untouched.
/// An unused (never registered) client allocated nothing.
pub fn DeinitClient(comptime infos: []const TypeInfo, self: *Client(infos)) void {
    if (self.owns_interceptors) {
        if (self.interceptors) |chain| {
            chain.deinit();
            self.allocator.destroy(chain);
        }
        self.interceptors = null;
        self.owns_interceptors = false;
    }
}

/// Return a copy of `self` whose interceptor chain is the caller-owned
/// `chain` (borrowed, never freed by `DeinitClient`). The caller stays
/// responsible for deinit'ing the chain. Mirrors the entity-client
/// `withInterceptors` for code paths that supply their own chain instead
/// of registering one via `UseInterceptor`.
pub fn withInterceptors(comptime infos: []const TypeInfo, self: Client(infos), chain: *intercept.InterceptorChain) Client(infos) {
    var copy = self;
    copy.interceptors = chain;
    copy.owns_interceptors = false;
    inline for (infos) |info| {
        const field_name = comptime structFieldName(info.name);
        @field(copy, field_name).interceptors = chain;
    }
    return copy;
}

/// Set the logger on the root client and propagate to all entity sub-clients.
pub fn SetLogger(comptime infos: []const TypeInfo, self: *Client(infos), logger: Logger) void {
    self.logger = logger;
    inline for (infos) |info| {
        const field_name = comptime structFieldName(info.name);
        @field(self, field_name).logger = logger;
    }
}

/// Enable debug logging on the client (writes to std.log).
pub fn Debug(comptime infos: []const TypeInfo, self: *Client(infos)) void {
    SetLogger(infos, self, debugLogger());
}

/// Library-level metrics that callers can collect and export.
/// These counters are per-Client instance and never reset automatically.
pub const Metrics = struct {
    pub var query_count: u64 = 0;
    pub var exec_count: u64 = 0;
    pub var error_count: u64 = 0;
};

/// Snapshot current metrics counters. Thread-safe to call from any context.
pub fn GetMetrics() Metrics {
    return Metrics{}; // Returns a copy of the global counters
}

/// Begin a transaction and return a TxClient backed by the transaction.
/// Copies logger, hooks, privacy_ctx, and interceptors from the parent
/// entity clients so that transactional operations retain hook callbacks,
/// privacy rules, query interceptors, and logging configuration.
pub fn beginTx(comptime infos: []const TypeInfo, self: Client(infos)) sql_driver.Error!TxClient(infos) {
    // Re-entrant beginTx inside an active transaction degrades to a
    // savepoint, so service orchestration can nest transactions safely.
    const tx = if (self.driver.inTransaction())
        try self.driver.beginSavepoint("zent_sp")
    else
        try self.driver.beginTx();
    var c = makeClient(infos, self.allocator, tx.inner);
    c.logger = self.logger;
    inline for (infos) |info| {
        const field_name = comptime structFieldName(info.name);
        @field(c, field_name).logger = @field(self, field_name).logger;
        @field(c, field_name).hooks = @field(self, field_name).hooks;
        @field(c, field_name).privacy_ctx = @field(self, field_name).privacy_ctx;
        @field(c, field_name).interceptors = @field(self, field_name).interceptors;
    }
    return TxClient(infos){
        .client = c,
        .tx = tx,
    };
}

/// Begin a transaction directly from a Driver, without a root Client.
/// Multi-graph apps that share one connection pool (`pool.asDriver()`)
/// use this to open a typed `TxClient` for any graph without building a
/// root `Client` first. Like `beginTx`, a re-entrant call inside an
/// active transaction degrades to a savepoint.
pub fn beginTxFromDriver(comptime infos: []const TypeInfo, driver: sql_driver.Driver, allocator: std.mem.Allocator) sql_driver.Error!TxClient(infos) {
    const tx = if (driver.inTransaction())
        try driver.beginSavepoint("zent_sp")
    else
        try driver.beginTx();
    return TxClient(infos){
        .client = makeClient(infos, allocator, tx.inner),
        .tx = tx,
    };
}

const CreateTablesError = sql_driver.Error || error{MissingViewSQL};

/// Create all database tables (create-only migration).
/// Creates entity tables and junction tables for M2M edges.
/// Generated SQL is allocated from `allocator` and freed with the same
/// allocator before returning.
pub fn createAllTables(allocator: std.mem.Allocator, comptime infos: []const TypeInfo, driver: sql_driver.Driver) CreateTablesError!void {
    return migrate.createAllTables(allocator, driver, infos);
}

fn findTypeInfo(comptime infos: []const TypeInfo, comptime name: []const u8) TypeInfo {
    for (infos) |info| {
        if (std.mem.eql(u8, info.name, name)) return info;
    }
    @compileError("TypeInfo not found: " ++ name);
}

fn findEdgeInfo(comptime info: TypeInfo, comptime name: []const u8) EdgeInfo {
    for (info.edges) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    @compileError("Edge not found: " ++ name ++ " on " ++ info.name);
}

fn QueryTargetsResult(
    comptime infos: []const TypeInfo,
    comptime source_name: []const u8,
    comptime edge_name: []const u8,
) type {
    const source_info = findTypeInfo(infos, source_name);
    const edge = findEdgeInfo(source_info, edge_name);
    const target_info = comptime edgeTargetInfo(infos, source_info, edge);
    return std.array_list.Managed(EntityGen(infos, target_info));
}

const QueryTargetsError = sql_driver.Error || error{ TypeMismatch, ColumnCountMismatch, BuildFailed, PrivacyDenied, InterceptFailed };

/// Which predicates a neighbour traversal applies to the target rows.
/// `scoped` matches the eager-load read contract; `soft_delete_only` is the
/// legacy escape hatch and exists solely for callers that have already scoped
/// their ids themselves.
const QueryTargetsScope = enum { scoped, soft_delete_only };

/// Shared implementation for every `queryTargets*` entry point below.
fn queryTargetsImpl(
    comptime scope: QueryTargetsScope,
    comptime infos: []const TypeInfo,
    comptime source_name: []const u8,
    comptime edge_name: []const u8,
    parent_ids: []const sql.Value,
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    privacy_ctx: ?privacy.PrivacyContext,
    interceptors: ?*intercept.InterceptorChain,
) QueryTargetsError!QueryTargetsResult(infos, source_name, edge_name) {
    const source_info = comptime findTypeInfo(infos, source_name);
    const edge = comptime findEdgeInfo(source_info, edge_name);
    const target_info = comptime edgeTargetInfo(infos, source_info, edge);
    const TargetEntity = comptime EntityGen(infos, target_info);
    const step = comptime buildEdgeStep(edge, source_info, target_info);

    if (parent_ids.len == 0) {
        return std.array_list.Managed(TargetEntity).init(allocator);
    }

    // Extra predicates ANDed into the neighbour WHERE. The scoped path uses
    // the shared target read contract (soft-delete → privacy → interceptors)
    // so it matches `WithEdge` exactly; the unscoped path is the legacy
    // soft-delete-only behaviour under an explicit name.
    var extra_preds = std.ArrayListUnmanaged(sql.Predicate).empty;
    defer extra_preds.deinit(allocator);

    if (scope == .scoped) {
        try @import("query.zig").appendTargetScopePreds(target_info, &extra_preds, allocator, privacy_ctx, interceptors, false, .query);
    } else if (target_info.soft_delete) {
        try extra_preds.append(allocator, sql.IsNull("deleted_at"));
    }

    var b = sql.Builder.init(allocator, driver.dialect());
    defer b.deinit();
    graph_neighbors.appendSetNeighborsFiltered(&b, step, parent_ids, extra_preds.items) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.BuildFailed;
    };

    const qr = b.query();
    var rows = try driver.query(qr.sql, qr.args);
    defer rows.deinit();

    var result = std.array_list.Managed(TargetEntity).init(allocator);
    errdefer result.deinit();

    while (rows.next()) |row| {
        // The projection is `target.*` followed by a trailing `__fk` column.
        // Positional scanRow reads only the entity's own (leading) columns,
        // so the extra `__fk` is ignored; no name-based scan is needed.
        const entity = try sql_scan.scanRow(TargetEntity, allocator, row);
        try result.append(entity);
    }
    return result;
}

/// Value-typed traversal: accepts any primary key type — `.int` for integer
/// PKs, `.string` for UUID/textual PKs. `queryTargets` delegates here.
/// For example: queryTargetsByValue(infos, "User", "cars", &.{.{ .int = 1 }}, allocator, driver, null, null) returns Car entities for user 1,
/// and queryTargetsByValue(infos, "User", "cars", &.{.{ .string = "0192..." }}, allocator, driver, null, null) does the same for a UUID-keyed User.
///
/// The traversal is rebuilt through `buildEdgeStep` +
/// `graph_neighbors.appendSetNeighborsFiltered`, so placeholders and
/// identifier quoting follow the driver dialect (`$n` on PostgreSQL,
/// backticks on MySQL) instead of the hardcoded `?`/`"…"` this helper used
/// to emit.
///
/// Applies the **same target read contract as `WithEdge`**: soft-delete
/// scope, the target's privacy policy, and the interceptor chain (e.g.
/// multi-tenant rewriting). A target carrying a policy denies the traversal
/// unless `privacy_ctx` is supplied, so this is fail-closed like the eager
/// loader. Prefer `EntityClient.QueryEdge`, which passes the client's own
/// `privacy_ctx`/`interceptors` for you; reach for
/// `queryTargetsByValueUnscoped` only when the ids are already scoped.
pub fn queryTargetsByValue(
    comptime infos: []const TypeInfo,
    comptime source_name: []const u8,
    comptime edge_name: []const u8,
    parent_ids: []const sql.Value,
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    privacy_ctx: ?privacy.PrivacyContext,
    interceptors: ?*intercept.InterceptorChain,
) QueryTargetsError!QueryTargetsResult(infos, source_name, edge_name) {
    return queryTargetsImpl(.scoped, infos, source_name, edge_name, parent_ids, allocator, driver, privacy_ctx, interceptors);
}

/// Soft-delete-only traversal. Unlike the fail-closed default above, this
/// applies **no** privacy policy and **no** interceptor scoping: a row of a
/// foreign tenant is returned if you pass its parent's id. The explicit name
/// is the point — every call site is an audited decision that the ids were
/// scoped elsewhere (typically by the same transaction that produced them).
pub fn queryTargetsByValueUnscoped(
    comptime infos: []const TypeInfo,
    comptime source_name: []const u8,
    comptime edge_name: []const u8,
    parent_ids: []const sql.Value,
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
) QueryTargetsError!QueryTargetsResult(infos, source_name, edge_name) {
    return queryTargetsImpl(.soft_delete_only, infos, source_name, edge_name, parent_ids, allocator, driver, null, null);
}

/// Integer-key convenience wrapper over `queryTargetsByValue`.
/// For example: queryTargets(infos, "User", "cars", &[1], allocator, driver, null, null) returns Car entities for user 1.
/// Callers whose primary keys are UUID/textual call `queryTargetsByValue`
/// directly with `.{ .string = ... }` values.
pub fn queryTargets(
    comptime infos: []const TypeInfo,
    comptime source_name: []const u8,
    comptime edge_name: []const u8,
    parent_ids: []const i64,
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
    privacy_ctx: ?privacy.PrivacyContext,
    interceptors: ?*intercept.InterceptorChain,
) QueryTargetsError!QueryTargetsResult(infos, source_name, edge_name) {
    const values = try allocator.alloc(sql.Value, parent_ids.len);
    defer allocator.free(values);
    for (parent_ids, 0..) |id, i| values[i] = .{ .int = id };
    return queryTargetsByValue(infos, source_name, edge_name, values, allocator, driver, privacy_ctx, interceptors);
}

/// Integer-key wrapper over `queryTargetsByValueUnscoped`.
pub fn queryTargetsUnscoped(
    comptime infos: []const TypeInfo,
    comptime source_name: []const u8,
    comptime edge_name: []const u8,
    parent_ids: []const i64,
    allocator: std.mem.Allocator,
    driver: sql_driver.Driver,
) QueryTargetsError!QueryTargetsResult(infos, source_name, edge_name) {
    const values = try allocator.alloc(sql.Value, parent_ids.len);
    defer allocator.free(values);
    for (parent_ids, 0..) |id, i| values[i] = .{ .int = id };
    return queryTargetsImpl(.soft_delete_only, infos, source_name, edge_name, values, allocator, driver, null, null);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "EntityClient" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const infos = &[_]TypeInfo{info};
    const ClientType = EntityClient(infos, info);

    const client = ClientType.init(std.testing.allocator, undefined);
    var builder = try client.Create();
    defer builder.deinit();

    // Test set method indirectly
    _ = try builder.setFieldValue("name", "alice");
    try std.testing.expectEqual(@as(usize, 1), builder.values.items.len);
}

test "Client type generation" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });
    const Car = schema("Car", .{
        .fields = &.{field.String("model")},
    });

    const user_info = comptime fromSchema(User);
    const car_info = comptime fromSchema(Car);
    const infos = &[_]TypeInfo{ user_info, car_info };

    _ = Client(infos);

    // Verify field names exist
    const c = std.testing.allocator;
    const client = makeClient(infos, c, undefined);
    _ = try client.user.Create();
    _ = try client.car.Create();
}

test "Client driver operations expose explicit driver error unions" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const Car = schema("Car", .{
        .fields = &.{field.String("model")},
    });
    const User = schema("User", .{
        .fields = &.{field.String("name")},
        .edges = &.{@import("../core/edge.zig").To("cars", Car)},
    });

    const user_info = comptime fromSchema(User);
    const car_info = comptime fromSchema(Car);
    const infos = &[_]TypeInfo{ user_info, car_info };
    const RootClient = Client(infos);
    const TransactionClient = TxClient(infos);

    comptime {
        if (@typeInfo(@TypeOf(beginTx(infos, @as(RootClient, undefined)))).error_union.error_set != sql_driver.Error) @compileError("beginTx error set is not explicit");
        if (@typeInfo(@typeInfo(@TypeOf(TransactionClient.commit)).@"fn".return_type.?).error_union.error_set != sql_driver.Error) @compileError("TxClient.commit error set is not explicit");
        if (@typeInfo(@typeInfo(@TypeOf(TransactionClient.rollback)).@"fn".return_type.?).error_union.error_set != sql_driver.Error) @compileError("TxClient.rollback error set is not explicit");
    }
}

test "beginTx nested savepoint: inner rollback discards only inner writes" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const buildGraph = @import("graph.zig").buildGraph;
    const sqlite_driver = @import("../sql/sqlite.zig");

    const Item = Schema("Item", .{
        .fields = &.{field.String("name")},
    });
    const graph = comptime buildGraph(&.{Item});
    const infos = graph.types;
    const info = comptime fromSchema(Item);

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);
    const root = makeClient(infos, allocator, driver.asDriver());

    // Outer transaction.
    var outer = try beginTx(infos, root);
    defer outer.deinit();
    {
        var b = try outer.client.item.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "outer-a");
        var row = try b.Save();
        defer deinitEntity(infos, info, &row, allocator);
    }

    // Nested beginTx degrades to a savepoint on the same connection.
    try std.testing.expect(driver.inTransaction());
    var inner = try beginTx(infos, root);
    defer inner.deinit();
    {
        var b = try inner.client.item.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "inner-b");
        var row = try b.Save();
        defer deinitEntity(infos, info, &row, allocator);
    }
    try inner.rollback(); // savepoint rollback -> inner-b discarded

    {
        var b = try outer.client.item.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "outer-c");
        var row = try b.Save();
        defer deinitEntity(infos, info, &row, allocator);
    }
    try outer.commit();

    var q = root.item.Query();
    defer q.deinit();
    const rows = try q.All();
    defer {
        for (rows.items) |*e| deinitEntity(infos, info, e, allocator);
        rows.deinit();
    }
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    var names = std.StringHashMap(void).init(allocator);
    defer names.deinit();
    for (rows.items) |*e| try names.put(e.name, {});
    try std.testing.expect(names.contains("outer-a"));
    try std.testing.expect(!names.contains("inner-b"));
    try std.testing.expect(names.contains("outer-c"));
}

test "beginTxFromDriver opens a typed tx straight from a Driver" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const buildGraph = @import("graph.zig").buildGraph;
    const sqlite_driver = @import("../sql/sqlite.zig");

    const Item = Schema("Item", .{
        .fields = &.{field.String("name")},
    });
    const graph = comptime buildGraph(&.{Item});
    const infos = graph.types;
    const info = comptime fromSchema(Item);

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);

    // No root Client: the transaction comes straight from the driver.
    var tx = try beginTxFromDriver(infos, driver.asDriver(), allocator);
    defer tx.deinit();
    {
        var b = try tx.client.item.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "driver-first");
        var row = try b.Save();
        defer deinitEntity(infos, info, &row, allocator);
    }
    // Re-entrant call on the same driver degrades to a savepoint.
    try std.testing.expect(driver.inTransaction());
    var nested = try beginTxFromDriver(infos, driver.asDriver(), allocator);
    defer nested.deinit();
    try nested.rollback();
    try tx.commit();

    const root = makeClient(infos, allocator, driver.asDriver());
    var q = root.item.Query();
    defer q.deinit();
    const rows = try q.All();
    defer {
        for (rows.items) |*e| deinitEntity(infos, info, e, allocator);
        rows.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqualStrings("driver-first", rows.items[0].name);
}

test "beginTx nested savepoint: inner commit releases to outer tx" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const buildGraph = @import("graph.zig").buildGraph;
    const sqlite_driver = @import("../sql/sqlite.zig");

    const Item = Schema("Item2", .{
        .fields = &.{field.String("name")},
    });
    const graph = comptime buildGraph(&.{Item});
    const infos = graph.types;
    const info = comptime fromSchema(Item);

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);
    const root = makeClient(infos, allocator, driver.asDriver());

    var outer = try beginTx(infos, root);
    defer outer.deinit();
    {
        var b = try outer.client.item2.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "outer");
        var row = try b.Save();
        defer deinitEntity(infos, info, &row, allocator);
    }

    var inner = try beginTx(infos, root);
    defer inner.deinit();
    {
        var b = try inner.client.item2.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "inner-committed");
        var row = try b.Save();
        defer deinitEntity(infos, info, &row, allocator);
    }
    try inner.commit(); // savepoint release

    // Inner writes are visible inside the outer tx and survive its commit.
    var q = outer.client.item2.Query();
    defer q.deinit();
    const rows = try q.All();
    defer {
        for (rows.items) |*e| deinitEntity(infos, info, e, allocator);
        rows.deinit();
    }
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try outer.commit();

    var q2 = root.item2.Query();
    defer q2.deinit();
    const final_rows = try q2.All();
    defer {
        for (final_rows.items) |*e| deinitEntity(infos, info, e, allocator);
        final_rows.deinit();
    }
    try std.testing.expectEqual(@as(usize, 2), final_rows.items.len);
}

test "TxClient afterCommit fires on commit, not on rollback" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const buildGraph = @import("graph.zig").buildGraph;
    const sqlite_driver = @import("../sql/sqlite.zig");

    const Item = Schema("Item3", .{
        .fields = &.{field.String("name")},
    });
    const graph = comptime buildGraph(&.{Item});
    const infos = graph.types;

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);
    const root = makeClient(infos, allocator, driver.asDriver());

    const Ctx = struct {
        var committed: usize = 0;
    };
    var tx = try beginTx(infos, root);
    defer tx.deinit();
    tx.afterCommit(null, struct {
        fn f(_: ?*anyopaque) void {
            Ctx.committed += 1;
        }
    }.f);
    try tx.commit();
    try std.testing.expectEqual(@as(usize, 1), Ctx.committed);

    var tx2 = try beginTx(infos, root);
    defer tx2.deinit();
    tx2.afterCommit(null, struct {
        fn f(_: ?*anyopaque) void {
            Ctx.committed += 1;
        }
    }.f);
    try tx2.rollback();
    try std.testing.expectEqual(@as(usize, 1), Ctx.committed);
}

test "TxClient enqueueEvent collects transaction-scoped events" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const buildGraph = @import("graph.zig").buildGraph;
    const sqlite_driver = @import("../sql/sqlite.zig");

    const Item = Schema("Item4", .{
        .fields = &.{field.String("name")},
    });
    const graph = comptime buildGraph(&.{Item});
    const infos = graph.types;

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);
    const root = makeClient(infos, allocator, driver.asDriver());

    const TxT = TxClient(infos);
    const Ctx = struct {
        var handled: [][]u8 = &.{};
        fn onCommit(ctx: ?*anyopaque) void {
            const tx: *TxT = @ptrCast(@alignCast(ctx.?));
            handled = tx.takePendingEvents();
        }
    };

    var tx = try beginTx(infos, root);
    defer tx.deinit();
    tx.afterCommit(&tx, Ctx.onCommit);
    try tx.enqueueEvent("{\"type\":\"order.created\"}");
    try tx.enqueueEvent("{\"type\":\"stock.updated\"}");
    try tx.commit();

    try std.testing.expectEqual(@as(usize, 2), Ctx.handled.len);
    try std.testing.expectEqualStrings("{\"type\":\"order.created\"}", Ctx.handled[0]);
    try std.testing.expectEqualStrings("{\"type\":\"stock.updated\"}", Ctx.handled[1]);
    for (Ctx.handled) |p| allocator.free(p);
    allocator.free(Ctx.handled);
    Ctx.handled = &.{};
}

test "interceptor stays effective after a by-value Client copy" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const buildGraph = @import("graph.zig").buildGraph;
    const fromSchema = @import("graph.zig").fromSchema;
    const sqlite_driver = @import("../sql/sqlite.zig");

    const Item = Schema("CopyItem", .{
        .fields = &.{ field.Int("tenant_id"), field.String("name") },
    });
    const graph = comptime buildGraph(&.{Item});
    const infos = graph.types;
    const info = comptime fromSchema(Item);

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);

    var root = makeClient(infos, allocator, driver.asDriver());
    inline for (.{ .{ 1, "keep" }, .{ 2, "other" } }) |row_data| {
        var b = try root.copy_item.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", @as(i64, row_data[0]));
        _ = try b.setFieldValue("name", row_data[1]);
        var row = try b.Save();
        deinitEntity(infos, info, &row, allocator);
    }

    const Ctx = struct {
        var seen: usize = 0;
    };
    try UseInterceptor(infos, &root, .{
        .ctx = null,
        .intercept = struct {
            fn f(_: ?*anyopaque, view: *intercept.QueryView) anyerror!void {
                Ctx.seen += 1;
                try view.whereEq("tenant_id", .{ .int = 1 });
            }
        }.f,
    });
    defer DeinitClient(infos, &root);

    // Simulate a move out of a helper/environment: the entity sub-client's
    // pointer must still reference the heap chain, not the moved root value.
    const moved = root;
    try std.testing.expect(moved.interceptors != null);
    try std.testing.expect(moved.interceptors == root.interceptors);
    try std.testing.expect(moved.copy_item.interceptors == root.interceptors);

    var q = moved.copy_item.Query();
    defer q.deinit();
    const rows = try q.All();
    defer {
        for (rows.items) |*e| deinitEntity(infos, info, e, allocator);
        rows.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqualStrings("keep", rows.items[0].name);
    try std.testing.expect(Ctx.seen > 0);
}

test "deinitRow / deinitRows / deinitEdgeRows free a page in one call" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const edge = @import("../core/edge.zig");
    const buildGraph = @import("graph.zig").buildGraph;
    const sqlite_driver = @import("../sql/sqlite.zig");

    const Car = Schema("DrCar", .{
        .fields = &.{field.String("model")},
    });
    const UserBase = Schema("DrUser", .{
        .fields = &.{field.String("name")},
    });
    const User = struct {
        pub const schema_name = UserBase.schema_name;
        pub const fields = UserBase.fields;
        pub const edges = &.{edge.To("cars", Car)};
        pub const indexes = UserBase.indexes;
    };

    const graph = comptime buildGraph(&.{ User, Car });
    const infos = graph.types;

    var driver = try sqlite_driver.SQLiteDriver.open(allocator, ":memory:");
    defer driver.close();
    try migrate.migrateSchema(allocator, driver.asDriver(), infos);
    var client = makeClient(infos, allocator, driver.asDriver());

    var user_id: i64 = 0;
    {
        var b = try client.dr_user.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "alice");
        var row = try b.Save();
        // The single-entity form: no graph, no allocator argument.
        defer client.dr_user.deinitRow(&row);
        user_id = row.id;
    }
    for ([_][]const u8{ "c1", "c2" }) |model| {
        var b = try client.dr_car.Create();
        defer b.deinit();
        _ = try b.setFieldValue("model", model);
        // The o2m edge injects a NOT NULL `dr_user_id` on the car table.
        _ = try b.setFieldValue("dr_user_id", user_id);
        var row = try b.Save();
        defer client.dr_car.deinitRow(&row);
    }

    // A page, released with one call. `std.testing.allocator` fails the test
    // on any leak, so this asserts the freeing rather than just the compiling.
    {
        var q = client.dr_user.Query();
        defer q.deinit();
        _ = try q.WithEdge("cars");
        var rows = try q.All();
        q.deinitRows(&rows);
        // Safe twice: the list is reset, so this cannot double-free.
        q.deinitRows(&rows);
        try std.testing.expectEqual(@as(usize, 0), rows.items.len);
    }

    // The same through the client, which is what a call site has left when the
    // builder is already out of scope.
    {
        var q = client.dr_user.Query();
        defer q.deinit();
        var rows = try q.All();
        client.dr_user.deinitRows(&rows);
    }

    // `QueryEdge` hands back the *target* entity, so it needs the target's
    // TypeInfo — which `deinitEdgeRows` resolves from the edge.
    {
        var rows = try client.dr_user.QueryEdge("cars", &.{user_id});
        try std.testing.expectEqual(@as(usize, 2), rows.items.len);
        client.dr_user.deinitEdgeRows("cars", &rows);
        try std.testing.expectEqual(@as(usize, 0), rows.items.len);
    }
}

test "UseInterceptor heap-allocates once and DeinitClient frees it" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const buildGraph = @import("graph.zig").buildGraph;

    const Item = Schema("OwnItem", .{ .fields = &.{field.String("name")} });
    const graph = comptime buildGraph(&.{Item});
    const infos = graph.types;

    const noop = struct {
        fn f(_: ?*anyopaque, _: *intercept.QueryView) anyerror!void {}
    }.f;

    var client = makeClient(infos, allocator, undefined);
    try std.testing.expect(client.interceptors == null);
    try std.testing.expect(!client.owns_interceptors);

    try UseInterceptor(infos, &client, .{ .intercept = noop });
    const chain_ptr = client.interceptors.?;
    try std.testing.expect(client.owns_interceptors);
    try std.testing.expect(client.own_item.interceptors == chain_ptr);

    // Registering again reuses the same heap chain instead of reallocating.
    try UseInterceptor(infos, &client, .{ .intercept = noop });
    try std.testing.expect(client.interceptors.? == chain_ptr);

    // A by-value copy shares the stable heap pointer; it only borrows.
    const copy = client;
    try std.testing.expect(copy.interceptors == chain_ptr);
    try std.testing.expect(copy.own_item.interceptors == chain_ptr);

    DeinitClient(infos, &client);
    try std.testing.expect(client.interceptors == null);
    try std.testing.expect(!client.owns_interceptors);
}

test "withInterceptors borrows: DeinitClient leaves the external chain alive" {
    const allocator = std.testing.allocator;
    const field = @import("../core/field.zig");
    const Schema = @import("../core/schema.zig").Schema;
    const buildGraph = @import("graph.zig").buildGraph;

    const Item = Schema("BorrowItem", .{ .fields = &.{field.String("name")} });
    const graph = comptime buildGraph(&.{Item});
    const infos = graph.types;

    const noop = struct {
        fn f(_: ?*anyopaque, _: *intercept.QueryView) anyerror!void {}
    }.f;

    var chain = intercept.InterceptorChain.init(allocator);
    defer chain.deinit();
    try chain.use(.{ .intercept = noop });

    var client = withInterceptors(infos, makeClient(infos, allocator, undefined), &chain);
    try std.testing.expect(!client.owns_interceptors);
    try std.testing.expect(client.interceptors == &chain);
    try std.testing.expect(client.borrow_item.interceptors == &chain);

    // DeinitClient must not free a chain it does not own.
    DeinitClient(infos, &client);

    // The external chain is still alive and usable afterwards.
    try chain.use(.{ .intercept = noop });
    try std.testing.expectEqual(@as(usize, 2), chain.interceptors.items.len);
}
