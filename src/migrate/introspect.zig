//! Reading what the database already has: columns, indexes, foreign keys and
//! views, one function per dialect, plus the capability probes that decide
//! whether a read may be sent at all.
//!
//! Split out of `migrate.zig` for the same reason as `types.zig` and `ddl.zig`:
//! this is the only layer that talks to the server, and keeping it apart is what
//! lets drift comparison and DDL planning be read (and tested) without a
//! database. Every function here answers a **named** error when the server
//! cannot answer the question at all (`IndexCatalogUnavailable`,
//! `ForeignKeyCatalogUnavailable`) rather than a raw driver failure, because the
//! caller's decision differs: "unknown" skips the comparison, "failed" aborts.

const std = @import("std");

const budget = @import("../base/budget.zig");
const Dialect = @import("../base/dialect.zig").Dialect;
const zent_log = @import("../base/log.zig");
const sql_driver = @import("../sql/driver.zig");
const Value = @import("../base/value.zig").Value;
const types = @import("types.zig");
const TypeInfo = @import("../codegen/graph.zig").TypeInfo;

const requiredPostgresExtensions = types.requiredPostgresExtensions;
const requiredExtensionsJoined = types.requiredExtensionsJoined;
const postgres_extension_types = types.postgres_extension_types;
const quoteIdentToBuffer = @import("ddl.zig").quoteIdentToBuffer;

/// The opening of `pgRelationListed`'s statement.
///
/// Named once and used by both the producer and the stubs that answer it
/// (`ExtensionStub`, `PostgresIndexCatalogStub`, and the catalog stub in
/// `src/test/allocation_failures_plan.zig`), because the catalog queries
/// themselves join `pg_class` — a stub keying on that substring alone would
/// answer the *index read* with the probe's `count(*)` row and look, from the
/// test's side, exactly like a probe asked twice. `pub` for that third stub;
/// nothing outside the tests reads it.
pub const pg_relation_probe_prefix = "SELECT count(*) FROM pg_class WHERE relname";

/// Refuse a PostgreSQL migration whose schema declares a type this database has
/// no extension for — **before any DDL**, so the caller gets one named error
/// instead of `ERROR: type "vector" does not exist` from the middle of a
/// `CREATE TABLE`, with no way to tell a missing extension from a typo.
///
/// Never probed unless the schema needs something (`requiredPostgresExtensions`
/// is empty for a graph built from the built-in field kinds), and never on
/// another dialect — `pg_extension` is PostgreSQL's own catalog.
///
/// Only *installed* extensions count. An extension that is merely available
/// still needs a `CREATE EXTENSION` the caller has to run, and doing it here
/// would be a schema change outside the plan, with privileges the migration has
/// no business assuming — so the fix is stated and the decision stays with the
/// caller.
///
/// **A server with no `pg_extension` is not a server without the type.** The
/// catalog is how the check proves an extension is *missing*; it is not the
/// only way the type can exist. A wire-compatible server may carry the type
/// natively (HeliosDB Nano has no `pg_extension` at all and yet provides
/// `vector`), and refusing the migration on a catalog it does not have would
/// block a schema that would migrate perfectly — the opposite of what this
/// check is for. Two things therefore answer "this server cannot be asked":
///
/// - The **catalog is not listed** (`pgRelationListed`): the query is never
///   sent, one warning says so, and the run continues. This is the path a
///   wire-compatible server takes, and the reason the read is gated at all —
///   sending it anyway would abort the caller's transaction and turn one
///   unknown capability into a migration that dies somewhere unrelated.
/// - The catalog *is* listed and the **statement is rejected** anyway (SQLSTATE
///   42P01, which reaches this function as `error.ExecFailed` or as the
///   `error.DriverFailed` PostgreSQL's driver maps it to, both of them
///   `postgresStatementRefused`): warned the same way and the run continues.
///   Kept as a safety net behind the gate rather than as the mechanism, because
///   by the time it fires the transaction it ran in is already dead.
///
/// Either way the declared types go to the server as declared, and a server
/// that really cannot provide them answers its own, louder error at the
/// `CREATE TABLE`. Every other failure — a lost connection, a protocol error —
/// still propagates, because the check cannot tell "no catalog" from "no
/// connection" for those and guessing would be worse than failing.
pub fn checkPostgresExtensions(drv: sql_driver.Driver, comptime infos: []const TypeInfo) !void {
    if (drv.dialect().kind() != .postgres) return;
    const required = comptime requiredPostgresExtensions(infos);
    if (required.len == 0) return;

    // Ahead of the query: a rejection here would abort the caller's transaction
    // (see `pgRelationListed`), so a server that does not carry the catalog is
    // answered without asking it the question that would fail.
    if (!pgRelationListed(drv, "pg_extension")) {
        zent_log.warn(
            "zent: cannot verify the PostgreSQL extension(s) this schema declares ({s}) — this server does not list `pg_extension` in its catalog; the declared types are sent to the server as declared, which a server without that catalog may well provide natively",
            .{comptime requiredExtensionsJoined(infos)},
        );
        return;
    }

    // One bit per required extension. Every member of `required` came out of
    // `postgres_extension_types`, so the table's length bounds the index.
    var installed: [postgres_extension_types.len]bool = @splat(false);
    var rows = drv.query("SELECT extname FROM pg_extension", &.{}) catch |err| {
        if (!postgresStatementRefused(err)) return err;
        // Warned, with what was asked and what came back: the returned value is
        // `void`, so this line is the only trace of the check having been
        // skipped. `{s}` for the declared types so the reader knows which
        // `CREATE TABLE` is now on its own — and the last sentence names why
        // that is often fine.
        zent_log.warn(
            "zent: cannot verify the PostgreSQL extension(s) this schema declares ({s}) — `SELECT extname FROM pg_extension` failed with {s}; the declared types are sent to the server as declared, which a server without that catalog may well provide natively",
            .{ comptime requiredExtensionsJoined(infos), @errorName(err) },
        );
        return;
    };
    defer rows.deinit();
    while (rows.next()) |row| {
        const name = row.getText(0) orelse continue;
        for (required, 0..) |want, i| {
            if (std.ascii.eqlIgnoreCase(name, want)) installed[i] = true;
        }
    }
    // A fetch that broke is not "the extension is missing": a reader that skips
    // this reports a short result set as a successful one.
    if (rows.nextError()) |err| return err;

    for (required, 0..) |want, i| {
        if (installed[i]) continue;
        zent_log.warn(
            "zent: the schema declares a column type provided by the PostgreSQL extension '{s}', which this database does not have installed; run `CREATE EXTENSION IF NOT EXISTS {s};` and migrate again",
            .{ want, want },
        );
        return error.MissingPostgresExtension;
    }
}

/// A column as the *database* reports it. Owned: `name`, `sql_type` and
/// `udt_name` are allocated, release the list with `freeExistingColumns`.
pub const ExistingColumn = struct {
    name: []const u8,
    /// `information_schema.columns.data_type` — the driver's own type name for
    /// the column (`text`, `integer`, `varchar`), lower-cased. On PostgreSQL a
    /// type that is *not* one of its built-ins answers `user-defined` or
    /// `array`, with the concrete name in `udt_name`.
    sql_type: []const u8,
    /// PostgreSQL's `udt_name`, lower-cased; empty on every other dialect
    /// (MySQL's and SQLite's catalogs have no such column). It holds the
    /// concrete `pg_type.typname` — `vector` for a `vector(1536)` column,
    /// `_int4` for an `integer[]` one — i.e. exactly the name
    /// `information_schema.columns.data_type` replaces with `user-defined` /
    /// `array`. See `columnTypesAgree`.
    udt_name: []const u8 = "",
    not_null: bool,
    pk: bool,
};

/// An index as the *database* reports it. Owned: `name` and every string in
/// `columns` are allocated, release the list with `freeExistingIndexes`.
pub const ExistingIndex = struct {
    name: []const u8,
    unique: bool,
    /// The index's key columns, **in index order**. Empty unless
    /// `columns_comparable`.
    columns: []const []const u8 = &.{},
    /// Whether `columns` may be compared against a declared index at all.
    ///
    /// False whenever the database's answer cannot be read reliably: an
    /// expression/functional key, a partial index (`WHERE`), a non-btree
    /// access method (PostgreSQL `USING gin/hash/...`), an index PostgreSQL
    /// marks invalid, a key list with `INCLUDE` columns, or a key list that
    /// did not come back at all. A caller that compares anyway reports a
    /// difference that is not one — and index drift is a
    /// performance/consistency signal, not a broken read, so a false report
    /// costs a blocked deploy via `assertSchema` while a missed one costs a
    /// log line. **Skip, never guess.**
    columns_comparable: bool = false,
};

/// The introspection helpers' error set.
///
/// `InvalidTableName` is SQLite's alone and exists for one reason: `PRAGMA`
/// statements take their argument as **syntax** (`PRAGMA table_info(?)` is a
/// parse error), so a table name has to be interpolated there. A name carrying
/// the quote that closes the literal would end the argument early and turn the
/// rest of the name into more statement — the injection shape a bound
/// parameter exists to remove. The names come from a comptime schema and never
/// from user input, so this is a fail-closed guard rather than a sanitiser:
/// refuse the name, and say which one.
///
/// `IndexCatalogUnavailable` and `ForeignKeyCatalogUnavailable` are
/// PostgreSQL's alone, and each is the answer to a server that speaks the wire
/// protocol without carrying the catalog the comparison needs: `pg_index` and
/// `pg_class` answer while `pg_am` does not (`getPostgresIndexes`), or the
/// catalogs answer while `pg_proc` — where `generate_subscripts` would have to
/// live — does not (`getPostgresForeignKeys`). Both are *named* errors rather
/// than propagated driver failures, so a consumer can tell "this server cannot
/// compare this at all" from "the migration broke", and both are returned
/// before the statement that would be refused rather than after it: a refusal
/// poisons the caller's transaction (see `pgRelationListed`).
pub const IntrospectionError = sql_driver.Error || error{ UnsupportedDialect, InvalidTableName, IndexCatalogUnavailable, ForeignKeyCatalogUnavailable };

/// True when `name` can be interpolated into a SQLite `PRAGMA` argument.
///
/// SQLite accepts `'`, `"` and `` ` `` as identifier quotes, and the argument
/// here is interpolated — not escaped — so any of the three would end it
/// early; a NUL truncates the statement on the C side before SQLite ever sees
/// the rest. Everything else, spaces and non-ASCII included, is a legal
/// argument inside the quotes: this rejects the shapes that break the
/// statement, not the shapes one would not have chosen.
pub fn sqlitePragmaNameUsable(name: []const u8) bool {
    for (name) |c| {
        switch (c) {
            '\'', '"', '`', 0 => return false,
            else => {},
        }
    }
    return true;
}

/// Whether `err` is *the server refusing the statement* — the one condition the
/// two PostgreSQL catalog fallbacks in this file are written against
/// (`getPostgresIndexes`'s retry without `pg_am`, `checkPostgresExtensions`'s
/// tolerance for a server with no `pg_extension`).
///
/// `sql_driver.classify(err) == .client` is the direct spelling of it, and it is
/// the whole answer on a driver that reports a rejected statement as
/// `error.ExecFailed`.
///
/// `error.DriverFailed` is PostgreSQL's own spelling of the same event, and at
/// this level it is indistinguishable from a driver fault: `sqlstateToError`
/// maps SQLSTATE 42P01 (`undefined_table`) to `error.ExecFailed`, and
/// `toDriverError` — which every call through the `Driver` vtable goes through
/// — funnels everything outside its short list of named errors, `ExecFailed`
/// included, into `error.DriverFailed`. So "this server has no such catalog"
/// *arrives here as `DriverFailed` on PostgreSQL*, measured against HeliosDB
/// 4.41.1: the `pg_am` join is refused with SQLSTATE 42P01 and the migration
/// sees `error.DriverFailed`. Without this arm both fallbacks are dead code on
/// the very server they were written for.
///
/// Treating it as a refusal is safe because the two are told apart by *asking
/// again*: each fallback either succeeds (a degraded but honest answer) or
/// returns an error — never a silent success — so a genuine driver fault stays
/// a failure, just a named one. `.capacity` (a dead connection, a pool with
/// nothing to give) is in neither answer and propagates unchanged, which is
/// what a caller reacting to a lost connection needs.
pub fn postgresStatementRefused(err: anyerror) bool {
    return sql_driver.classify(err) == .client or err == error.DriverFailed;
}

/// Query existing columns for a table using dialect-specific metadata.
///
/// The table name is **bound** on PostgreSQL (`$1`) and MySQL (`?`), never
/// interpolated into a string literal, so a name carrying a quote cannot end
/// the predicate early. SQLite is the exception and cannot be: `PRAGMA` takes
/// no placeholders, so the name is checked first
/// (`sqlitePragmaNameUsable`) and refused with `error.InvalidTableName`
/// rather than emitted into a statement it would break.
pub fn getExistingColumns(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingColumn) {
    var result = std.array_list.Managed(ExistingColumn).init(allocator);
    errdefer freeExistingColumns(allocator, &result);

    const kind = driver_drv.dialect().kind();
    const is_sqlite = kind == .sqlite;
    const is_postgres = kind == .postgres;
    const is_mysql = kind == .mysql;

    if (is_sqlite and !sqlitePragmaNameUsable(table_name)) {
        reportUnusableSqliteName("table_info", table_name);
        return error.InvalidTableName;
    }

    // PostgreSQL's `udt_name` is appended to the select list, not folded into
    // the middle of it: it is the only place the concrete type of a column shows
    // up when `data_type` answers `USER-DEFINED` (an extension or custom type:
    // `vector`, `citext`, a domain) or `ARRAY` (any array: `_int4` for
    // `integer[]`) — comparing `data_type` alone reported a `type_mismatch` for
    // every such column — and keeping the first three columns exactly where they
    // were keeps every model of this query that already exists honest (the
    // allocation-failure sweep's catalog stub answers three). MySQL and SQLite
    // have no such column (MySQL's `information_schema.columns` is its own
    // catalog, not PostgreSQL's), so their query text is unchanged and their
    // `udt_name` stays empty.
    const sql_text = if (is_sqlite)
        try allocator.print("PRAGMA table_info(\"{s}\")", .{table_name})
    else if (is_postgres)
        try allocator.dupe(u8, "SELECT column_name, data_type, is_nullable, column_default, udt_name FROM information_schema.columns WHERE table_name = $1 AND table_schema = current_schema()")
    else if (is_mysql)
        try allocator.dupe(u8, "SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_name = ? AND table_schema = DATABASE()")
    else
        return error.UnsupportedDialect;
    defer allocator.free(sql_text);

    var rows = if (is_sqlite)
        try driver_drv.query(sql_text, &.{})
    else
        try driver_drv.query(sql_text, &.{.{ .string = table_name }});
    defer rows.deinit();

    while (rows.next()) |row| {
        const name = row.getText(if (is_sqlite) 1 else 0) orelse continue;
        const sql_type = row.getText(if (is_sqlite) 2 else 1) orelse "";
        // A driver that does not answer the trailing column reads as "no
        // `udt_name`" rather than as an error, and `columnTypesAgree` has a
        // fallback for exactly that.
        const udt_name = if (is_postgres) (row.getText(4) orelse "") else "";
        const not_null = if (is_sqlite)
            (row.getInt(3) orelse 0) != 0
        else
            std.ascii.eqlIgnoreCase(row.getText(2) orelse "YES", "NO");
        const pk = is_sqlite and (row.getInt(5) orelse 0) != 0;

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_type = try dupeLower(allocator, sql_type);
        errdefer allocator.free(owned_type);
        // Not allocated when absent, so `udt_name` is never a slice
        // `freeExistingColumns` would have to tell apart from the empty
        // default the struct carries on the other dialects.
        const owned_udt: []const u8 = if (udt_name.len == 0) "" else try dupeLower(allocator, udt_name);
        errdefer if (owned_udt.len > 0) allocator.free(owned_udt);

        try result.append(.{
            .name = owned_name,
            .sql_type = owned_type,
            .udt_name = owned_udt,
            .not_null = not_null,
            .pk = pk,
        });
    }
    if (rows.nextError()) |err| return err;
    return result;
}

/// Query existing indexes for a table using dialect-specific metadata.
///
/// Every dialect reads the key columns from a **structured catalog** — MySQL's
/// `information_schema.statistics`, PostgreSQL's `pg_index`/`pg_attribute`,
/// SQLite's `PRAGMA index_info` — never by parsing a rendered statement. An
/// index whose key list cannot be compared comes back with
/// `columns_comparable = false` (see `ExistingIndex`), which is the signal a
/// caller must honour instead of guessing.
pub fn getExistingIndexes(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingIndex) {
    return switch (driver_drv.dialect().kind()) {
        .sqlite => getSQLiteIndexes(allocator, driver_drv, table_name),
        .postgres => getPostgresIndexes(allocator, driver_drv, table_name),
        .mysql => getMySQLIndexes(allocator, driver_drv, table_name),
        // An unnamed dialect has no catalog query of its own; it was the
        // fallthrough before, and it still is.
        .unknown => error.UnsupportedDialect,
    };
}

/// Hand the accumulated key columns to the index at `current` and reset the
/// accumulator for the next one. A no-op before the first index.
///
/// `comparable` is the caller's verdict, which may depend on more than the
/// columns themselves (PostgreSQL's key count, SQLite's partial flag). An
/// index with no readable key at all is never comparable, a key list being
/// what an index is.
pub fn closeExistingIndex(
    result: *std.array_list.Managed(ExistingIndex),
    current: ?usize,
    keys: *std.array_list.Managed([]const u8),
    comparable: bool,
) !void {
    const idx = current orelse return;
    result.items[idx].columns = try keys.toOwnedSlice();
    result.items[idx].columns_comparable = comparable and result.items[idx].columns.len > 0;
}

/// `information_schema.statistics` is one row per (index, column), so
/// `seq_in_index` is what orders a multi-column index's key list.
///
/// Two shapes cannot be compared against the schema's key list:
///
///   - `column_name` is NULL for a **functional index** (MySQL 8.0.13+): the
///     key is an expression, not a column.
///   - `sub_part` is non-NULL for a **prefix index** (`KEY (c(10))`): the key
///     covers the first N characters, so reporting its column list as equal to
///     a schema index over the full column would claim a match that does not
///     exist — a prefix index is not the index the schema asked for.
///
/// MySQL has no partial indexes and InnoDB only btree access methods, so those
/// two cases are the whole of it here.
///
/// `pub` for the alloc-failure sweep in `src/test/allocation_failures_plan.zig`
/// — its only caller outside this module; `getExistingIndexes` remains the only
/// one inside it.
pub fn getMySQLIndexes(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingIndex) {
    var result = std.array_list.Managed(ExistingIndex).init(allocator);
    errdefer freeExistingIndexes(allocator, &result);

    var keys = std.array_list.Managed([]const u8).init(allocator);
    defer {
        // Reached on an error path only: `toOwnedSlice` hands the finished
        // list to the index it belongs to.
        for (keys.items) |k| allocator.free(k);
        keys.deinit();
    }

    var rows = try driver_drv.query(
        "SELECT index_name, non_unique, column_name, sub_part FROM information_schema.statistics WHERE table_name = ? AND table_schema = DATABASE() ORDER BY index_name, seq_in_index",
        &.{.{ .string = table_name }},
    );
    defer rows.deinit();

    var current: ?usize = null;
    var comparable = true;
    while (rows.next()) |row| {
        const name = row.getText(0) orelse continue;
        if (current == null or !std.mem.eql(u8, result.items[current.?].name, name)) {
            try closeExistingIndex(&result, current, &keys, comparable);
            // The copy is made first and released by `errdefer` when `append`
            // fails — declared inside the loop body, so it covers this
            // iteration only. Same shape as `getSQLiteIndexes`, and pinned the
            // same way: the sweep in `src/test/allocation_failures_plan.zig`
            // reaches this line through its MySQL catalog stub and fails each
            // `append` in turn.
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            try result.append(.{
                .name = owned_name,
                .unique = (row.getInt(1) orelse 1) == 0,
            });
            current = result.items.len - 1;
            comparable = true;
        }
        if (row.getText(2)) |column| {
            const owned_column = try allocator.dupe(u8, column);
            errdefer allocator.free(owned_column);
            try keys.append(owned_column);
        } else {
            comparable = false; // functional index: the key is an expression
        }
        if (row.getText(3) != null) comparable = false; // prefix index: partial coverage
    }
    if (rows.nextError()) |err| return err;
    try closeExistingIndex(&result, current, &keys, comparable);
    return result;
}

/// PostgreSQL, from the catalog: `pg_index` for the flags and `pg_attribute`
/// (joined through `indkey`) for the key columns.
///
/// `indkey` is an `int2vector` whose text form is the attribute numbers in key
/// order — `array_position` over it restores that order for the join, so the
/// rows arrive in index order. `pg_indexes.indexdef` is *not* used: its key
/// list is a rendered expression (`lower(a)`, `a DESC`, `("a")`), and parsing
/// SQL text back into a column list is how a comparison starts lying.
///
/// Nothing here can distinguish "the schema's index lost a column" from "this
/// is a different kind of index", so every index whose keys are not plain
/// columns of the table — expression keys, `WHERE` predicates, non-btree
/// access methods, `INCLUDE` payload columns, invalid indexes, or a key list
/// that does not add up — is reported as not comparable.
///
/// **A server that has no `pg_am` is still read, by name and uniqueness.**
/// PostgreSQL's access-method catalog is not part of what a wire-compatible
/// server has to carry, and one that omits it (HeliosDB Nano answers
/// `Table 'pg_am' does not exist` with SQLSTATE 42P01) refuses the whole
/// statement — so *every* index would go unreported, and the migration would
/// treat each declared index as missing and re-`CREATE` it. The access method is
/// therefore asked about **before** any query that joins it
/// (`pgRelationListed`), because a rejection poisons the transaction this runs
/// in: "is `pg_am` there?" is answered without a statement that can fail, and
/// the answer selects which read is sent. **Not listed** means the read without
/// the access-method join goes first — a server in that shape is read, not
/// refused, and the read is the one `readIndexCatalog` describes below.
/// **Listed** means the full read goes first, and a statement rejection behind
/// the gate is still handled the way it always was (a server can answer the
/// probe and refuse the query) — refused twice, the answer is
/// `error.IndexCatalogUnavailable` rather than a failure dressed as an empty
/// catalog. Either way, in the retry **no index is comparable**: the key list's
/// order is restored by the dropped `array_position` term and the access method
/// that decides `btree` is exactly what is missing, so the honest answer is
/// "unknown" — not "btree, go ahead and compare". Names and uniqueness survive
/// because neither needs `pg_am`, and those two are what the migration plans
/// against (`indexExists`) and what the drift report gates the key list on.
///
/// `pub` for the alloc-failure sweep in `src/test/allocation_failures_plan.zig`
/// — its only caller outside this module; `getExistingIndexes` remains the only
/// one inside it.
pub fn getPostgresIndexes(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingIndex) {
    var result = std.array_list.Managed(ExistingIndex).init(allocator);
    errdefer freeExistingIndexes(allocator, &result);

    // The access method before the query that joins it: on a server without it
    // the rejection would abort the migration's transaction, and a retry inside
    // a dead transaction cannot answer anything (see `pgRelationListed`). Only
    // this one relation is probed — `pg_index`, `pg_attribute` and
    // `pg_namespace` are read on both shapes below and a server may answer a
    // query over them without listing them in `pg_class` (HeliosDB Nano does).
    const access_method_listed = pgRelationListed(driver_drv, "pg_am");

    const args = [_]Value{.{ .string = table_name }};

    // The table name is bound (`$1`), not interpolated: a name carrying a
    // quote would otherwise end the predicate early. `relkind = 'r'` and the
    // schema predicate stay literal — they are this function's own constants.
    const sql_text =
        \\SELECT i.relname,
        \\       (ix.indisunique)::int,
        \\       (ix.indisvalid)::int,
        \\       (ix.indpred IS NOT NULL)::int,
        \\       (ix.indnatts <> ix.indnkeyatts)::int,
        \\       ix.indnkeyatts::int,
        \\       am.amname,
        \\       a.attname
        \\FROM pg_index ix
        \\JOIN pg_class i ON i.oid = ix.indexrelid
        \\JOIN pg_class t ON t.oid = ix.indrelid
        \\JOIN pg_am am ON am.oid = i.relam
        \\LEFT JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY (ix.indkey)
        \\WHERE t.relname = $1 AND t.relkind = 'r'
        \\  AND t.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = current_schema())
        \\ORDER BY i.relname, array_position(string_to_array(ix.indkey::text, ' ')::smallint[], a.attnum)
    ;

    // The retry: `sql_text` with the `pg_am` join and its column removed, and
    // the three `::int` casts on a boolean written as `CASE … THEN 1 ELSE 0
    // END`. The case form is not cosmetic — the server that has no `pg_am`
    // refuses `Boolean(false)::INT4` too ("Cannot cast Boolean(false) to
    // INT4"), so leaving the casts in would make the retry fail for the same
    // class of reason it exists to work around. The `ORDER BY` loses its
    // `array_position` term with the same justification: it exists to restore
    // the key *order*, and no key order is read on this path.
    const sql_no_am =
        \\SELECT i.relname,
        \\       CASE WHEN ix.indisunique THEN 1 ELSE 0 END,
        \\       CASE WHEN ix.indisvalid THEN 1 ELSE 0 END,
        \\       CASE WHEN ix.indpred IS NOT NULL THEN 1 ELSE 0 END,
        \\       CASE WHEN ix.indnatts <> ix.indnkeyatts THEN 1 ELSE 0 END,
        \\       ix.indnkeyatts::int,
        \\       a.attname
        \\FROM pg_index ix
        \\JOIN pg_class i ON i.oid = ix.indexrelid
        \\JOIN pg_class t ON t.oid = ix.indrelid
        \\LEFT JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY (ix.indkey)
        \\WHERE t.relname = $1 AND t.relkind = 'r'
        \\  AND t.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = current_schema())
        \\ORDER BY i.relname
    ;

    // Which of the two shapes answered. `true` also means the rows carry the
    // `amname` column, which shifts every column after `indnkeyatts` by one —
    // the parse below reads that offset off this flag instead of running twice.
    var method_known = access_method_listed;
    // The error the full read was refused with, when the probe said the catalog
    // is there and the server refused the query anyway. `null` on the probe's
    // own path: nothing failed, the access method is simply not listed.
    var refused_reason: ?[]const u8 = null;

    // The full read, when the access method is there to join. A refusal is the
    // one thing that makes the retry worth asking — `postgresStatementRefused`
    // is the whole condition, so `.capacity` (the connection is gone) is not
    // repaired by asking a shorter question and propagates unchanged instead;
    // see the helper for why `DriverFailed` counts as a refusal on this dialect.
    var full: ?sql_driver.Rows = null;
    if (access_method_listed) {
        full = driver_drv.query(sql_text, &args) catch |err| refused: {
            if (!postgresStatementRefused(err)) return err;
            refused_reason = @errorName(err);
            method_known = false;
            break :refused null;
        };
    }

    // The read that is sent whenever the full one was not: the probe said the
    // access method is not listed, or the server refused the statement that
    // joins it. Refused here too, this server has no index catalog to read at
    // all — named, not a raw driver error, so the caller can tell it from a
    // migration that broke.
    const rows = full orelse retry: {
        const retried = driver_drv.query(sql_no_am, &args) catch |retry_err| {
            if (!postgresStatementRefused(retry_err)) return retry_err;
            zent_log.warn(
                "zent: this PostgreSQL-wire server has no PostgreSQL index catalog — reading the indexes of table {s} failed with {s}, with and without the pg_am access-method join; indexes do not take part in the comparison",
                .{ table_name, @errorName(retry_err) },
            );
            return error.IndexCatalogUnavailable;
        };
        break :retry retried;
    };
    defer rows.deinit();

    if (!method_known) {
        // One line per table, naming the reason the key lists cannot be
        // compared — the error, when there was one, and the probe's answer when
        // there was not.
        zent_log.warn(
            "zent: this PostgreSQL-wire server has no `pg_am` ({s}), so the indexes of table {s} are read without the access method; they are still matched by name and uniqueness, but their key columns are not compared",
            .{ refused_reason orelse "not listed in its catalog", table_name },
        );
    }

    var keys = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit();
    }

    // Which shape answered decides one offset and one verdict, so it is read
    // here rather than duplicated into a second parse loop: the retry's select
    // list is `amname` shorter, which moves `attname` from column 7 to 6, and
    // it carries no access method at all.
    const attname_col: usize = if (method_known) 7 else 6;

    var current: ?usize = null;
    var comparable = true;
    var expected_keys: i64 = 0;
    var seen_keys: i64 = 0;
    while (rows.next()) |row| {
        const name = row.getText(0) orelse continue;
        if (current == null or !std.mem.eql(u8, result.items[current.?].name, name)) {
            try closeExistingIndex(&result, current, &keys, comparable and seen_keys == expected_keys);
            // As in `getMySQLIndexes`: the copy is made first, and released by
            // an `errdefer` scoped to this loop iteration when `append` fails.
            // The sweep in `src/test/allocation_failures_plan.zig` reaches this
            // line through its PostgreSQL catalog stub.
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            try result.append(.{
                .name = owned_name,
                .unique = (row.getInt(1) orelse 0) != 0,
            });
            current = result.items.len - 1;
            comparable = (row.getInt(2) orelse 0) != 0 // indisvalid
            and (row.getInt(3) orelse 1) == 0 // indpred IS NULL
            and (row.getInt(4) orelse 1) == 0 // indnatts == indnkeyatts (no INCLUDE)
                // No access method was read, so no key list is comparable — the
                // `and` short-circuits before column 6, which does not exist in
                // that shape. An unknown method is *not* `btree`: assuming it is
                // would compare a `USING gin`/`hash` index's keys as if it keyed
                // the declared columns, which is the guess `columns_comparable`
                // exists to refuse. The index keeps its name and its uniqueness,
                // and only the key list becomes "unknown".
            and method_known and std.mem.eql(u8, row.getText(6) orelse "", "btree");
            expected_keys = row.getInt(5) orelse 0;
            seen_keys = 0;
        }
        seen_keys += 1;
        if (comparable) {
            // A NULL attname is an expression key (attnum 0), which no
            // declared column list can be equal to.
            if (row.getText(attname_col)) |column| {
                const owned_column = try allocator.dupe(u8, column);
                errdefer allocator.free(owned_column);
                try keys.append(owned_column);
            } else {
                comparable = false;
            }
        }
    }
    if (rows.nextError()) |err| return err;
    try closeExistingIndex(&result, current, &keys, comparable and seen_keys == expected_keys);
    return result;
}

/// SQLite, in two phases: `PRAGMA index_list` for the names, then
/// `PRAGMA index_info` per index for its key columns.
///
/// The split is not cosmetic — the SQLite driver holds its connection mutex
/// for as long as a `Rows` value lives, so the first statement must be
/// finished before the second can be prepared.
///
/// `PRAGMA` takes no placeholders, so the table name is interpolated here and
/// checked first (`sqlitePragmaNameUsable`); `error.InvalidTableName` is the
/// answer for a name that would break the statement. The index names in the
/// second phase come from the catalog, not from a declaration, and go through
/// `quoteIdentToBuffer`, which doubles the quote.
pub fn getSQLiteIndexes(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingIndex) {
    var result = std.array_list.Managed(ExistingIndex).init(allocator);
    errdefer freeExistingIndexes(allocator, &result);

    const dialect = driver_drv.dialect();

    if (!sqlitePragmaNameUsable(table_name)) {
        reportUnusableSqliteName("index_list", table_name);
        return error.InvalidTableName;
    }

    {
        const list_sql = try allocator.print("PRAGMA index_list(\"{s}\")", .{table_name});
        defer allocator.free(list_sql);
        var rows = try driver_drv.query(list_sql, &.{});
        defer rows.deinit();
        while (rows.next()) |row| {
            const name = row.getText(1) orelse continue;
            // Column 4 is `partial`, available since SQLite 3.16; a partial
            // index has no equivalent in an IndexDef, so it is never compared.
            const partial = row.columnCount() > 4 and (row.getInt(4) orelse 0) != 0;
            // The name is duplicated before the list grows, and growing it is
            // an allocation: an `append(.{ .name = try dupe(…) })` whose
            // `append` fails leaves the copy owned by nobody. The `errdefer` is
            // dropped at the end of this iteration, so it covers exactly the
            // window between the copy and the item entering the list.
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            try result.append(.{
                .name = owned_name,
                .unique = (row.getInt(2) orelse 0) != 0,
                .columns_comparable = !partial,
            });
        }
        if (rows.nextError()) |err| return err;
    }

    var keys = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit();
    }

    for (result.items) |*idx| {
        var quoted = std.array_list.Managed(u8).init(allocator);
        defer quoted.deinit();
        try quoteIdentToBuffer(dialect, &quoted, idx.name);
        const info_sql = try allocator.print("PRAGMA index_info({s})", .{quoted.items});
        defer allocator.free(info_sql);

        var rows = try driver_drv.query(info_sql, &.{});
        defer rows.deinit();

        const declared_comparable = idx.columns_comparable;
        var columns_readable = true;
        while (rows.next()) |row| {
            // (seqno, cid, name): a NULL name is an expression key, and a
            // `cid` of -1 means the rowid, which no declared index names.
            const column = row.getText(2);
            const cid = row.getInt(1) orelse -1;
            if (column == null or cid < 0) {
                columns_readable = false;
                continue;
            }
            // Same window as the name above: the copy exists before the append
            // that would hand it to `keys`, so the append's failure has to
            // release it.
            const owned_column = try allocator.dupe(u8, column.?);
            errdefer allocator.free(owned_column);
            try keys.append(owned_column);
        }
        if (rows.nextError()) |err| return err;

        idx.columns = try keys.toOwnedSlice();
        idx.columns_comparable = declared_comparable and columns_readable and idx.columns.len > 0;
    }

    return result;
}

/// A foreign key as the *database* reports it. Owned: `ref_table` and every
/// string in `columns` / `ref_columns` are allocated, release the list with
/// `freeExistingForeignKeys`.
///
/// There is deliberately **no name**: the comparison is by shape (see
/// `checkSchema`), and a name is the one thing the three catalogs do not agree
/// on — PostgreSQL and MySQL generate one, SQLite keeps none. `ON DELETE` /
/// `ON UPDATE` are not read either.
pub const ExistingForeignKey = struct {
    /// Local columns, in constraint order.
    columns: []const []const u8,
    /// The referenced table, as the database spells it.
    ref_table: []const u8,
    /// Referenced columns, in constraint order. Empty unless
    /// `ref_columns_comparable`.
    ref_columns: []const []const u8 = &.{},
    /// Whether `ref_columns` may be compared at all. False for exactly one
    /// shape: SQLite's `REFERENCES t` with no column list, where
    /// `PRAGMA foreign_key_list` reports a NULL `to` because the target is the
    /// other table's primary key. The constraint is real and its shape is not
    /// wrong — it is *unreadable*, and a caller that reads that as a difference
    /// blocks a deploy over its own guess.
    ref_columns_comparable: bool = true,
};

/// Query the foreign keys a table declares, using dialect-specific catalogs.
///
/// Every dialect reads a **structured catalog** — PostgreSQL's `pg_constraint`
/// (`contype = 'f'`) with its `conkey`/`confkey` arrays, MySQL/MariaDB's
/// `information_schema.key_column_usage`, SQLite's
/// `PRAGMA foreign_key_list(<table>)` — and never the `REFERENCES` clause out of
/// rendered DDL text, for the same reason `getExistingIndexes` does not parse
/// `indexdef`.
///
/// The table name is **bound** on PostgreSQL (`$1`) and MySQL (`?`), never
/// interpolated into a string literal. SQLite is the exception and cannot be:
/// `PRAGMA` takes no placeholders, so the name is checked first
/// (`sqlitePragmaNameUsable`) and refused with `error.InvalidTableName` rather
/// than emitted into a statement it would break.
///
/// A table that does not exist answers an **empty list**, not an error — on
/// SQLite because `PRAGMA` has no opinion about a name it cannot find, and on
/// the other two because a `WHERE table_name = …` over a catalog that does not
/// contain the table matches no rows. That is why `checkSchema` calls this only
/// after `getExistingColumns` has said the table is there: "no foreign keys" and
/// "no table at all" are different answers, and only the caller knows which
/// question it asked.
pub fn getExistingForeignKeys(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingForeignKey) {
    return switch (driver_drv.dialect().kind()) {
        .sqlite => getSQLiteForeignKeys(allocator, driver_drv, table_name),
        .postgres => getPostgresForeignKeys(allocator, driver_drv, table_name),
        .mysql => getMySQLForeignKeys(allocator, driver_drv, table_name),
        .unknown => error.UnsupportedDialect,
    };
}

/// Hand the accumulated columns to the foreign key at `current` and reset the
/// accumulators for the next one. A no-op before the first key.
///
/// `comparable` is the caller's verdict about the *referenced* column list,
/// which is only ever false when the database did not record one. A key that
/// came back with fewer referenced columns than local ones is not comparable
/// either: the two lists are positional, and a short one cannot be lined up.
pub fn closeExistingForeignKey(
    result: *std.array_list.Managed(ExistingForeignKey),
    current: ?usize,
    columns: *std.array_list.Managed([]const u8),
    ref_columns: *std.array_list.Managed([]const u8),
    comparable: bool,
) !void {
    const idx = current orelse return;
    result.items[idx].columns = try columns.toOwnedSlice();
    result.items[idx].ref_columns = try ref_columns.toOwnedSlice();
    result.items[idx].ref_columns_comparable = comparable and
        result.items[idx].ref_columns.len == result.items[idx].columns.len;
}

/// `information_schema.key_column_usage`, filtered to foreign keys by
/// `referenced_table_name IS NOT NULL` — the same row shape every other
/// constraint kind would have, minus the reference, so that one predicate is
/// what keeps only the constraints asked for.
///
/// `ordinal_position` restarts at 1 for each constraint and the rows arrive
/// ordered by it, which is what groups them without a name to group on.
///
/// This is standard `information_schema`, not a server-specific view: the same
/// statement runs unchanged on MySQL and MariaDB.
pub fn getMySQLForeignKeys(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingForeignKey) {
    var result = std.array_list.Managed(ExistingForeignKey).init(allocator);
    errdefer freeExistingForeignKeys(allocator, &result);

    var cols = std.array_list.Managed([]const u8).init(allocator);
    defer {
        // Reached on an error path only: `toOwnedSlice` hands each finished
        // list to the constraint it belongs to.
        for (cols.items) |c| allocator.free(c);
        cols.deinit();
    }
    var refs = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (refs.items) |c| allocator.free(c);
        refs.deinit();
    }

    var rows = try driver_drv.query(
        "SELECT column_name, referenced_table_name, referenced_column_name, ordinal_position FROM information_schema.key_column_usage WHERE table_name = ? AND table_schema = DATABASE() AND referenced_table_name IS NOT NULL ORDER BY constraint_name, ordinal_position",
        &.{.{ .string = table_name }},
    );
    defer rows.deinit();

    var current: ?usize = null;
    var comparable = true;
    while (rows.next()) |row| {
        const position = row.getInt(3) orelse continue;
        if (current == null or position == 1) {
            try closeExistingForeignKey(&result, current, &cols, &refs, comparable);
            // Same copy-then-append shape as `getMySQLIndexes`: the dupe is
            // released by an `errdefer` declared in the loop body when the
            // `append` itself fails — the entry never reached `result`, so the
            // function's `errdefer freeExistingForeignKeys` cannot free it.
            const owned_ref_table = try allocator.dupe(u8, row.getText(1) orelse "");
            errdefer allocator.free(owned_ref_table);
            try result.append(.{
                .columns = &.{},
                .ref_table = owned_ref_table,
            });
            current = result.items.len - 1;
            comparable = true;
        }
        if (row.getText(0)) |column| {
            const owned_column = try allocator.dupe(u8, column);
            errdefer allocator.free(owned_column);
            try cols.append(owned_column);
        } else {
            comparable = false; // no local column: not a shape to compare
        }
        if (row.getText(2)) |ref_column| {
            const owned_ref_column = try allocator.dupe(u8, ref_column);
            errdefer allocator.free(owned_ref_column);
            try refs.append(owned_ref_column);
        } else {
            comparable = false; // referenced column not recorded
        }
    }
    if (rows.nextError()) |err| return err;
    try closeExistingForeignKey(&result, current, &cols, &refs, comparable);
    return result;
}

/// PostgreSQL, from `pg_constraint` alone — no `pg_get_constraintdef()` text,
/// which would have to be parsed back into a shape and is exactly the kind of
/// comparison that starts lying.
///
/// `conkey` and `confkey` are the local and referenced attribute numbers **in
/// constraint order**, so `generate_subscripts` walks the two in step and each
/// `pg_attribute` join resolves one position of each side to a name. `contype =
/// 'f'` is the foreign-key filter; the namespace join keeps a same-named table
/// in another schema out of the answer.
///
/// **A server that cannot answer this is skipped, not refused.** The set
/// returning function in the `FROM` clause is what makes the read a single
/// statement, and it is a PostgreSQL function, not a catalog a wire-compatible
/// server has to carry: HeliosDB Nano answers `Table 'generate_subscripts' does
/// not exist` (SQLSTATE 42P01) and, like every rejected statement, leaves the
/// caller's transaction unusable — so the read is gated on `pg_proc` first
/// (`pgRelationListed`), the catalog such a function would be listed in. Not
/// listed means one warning and `error.ForeignKeyCatalogUnavailable`, which the
/// two callers turn into "this comparison is skipped" rather than a failed
/// migration: a declared key that cannot be compared must not be reported as
/// missing, because the report is what makes the planner emit a second
/// `ADD CONSTRAINT` for a key the database may already have.
pub fn getPostgresForeignKeys(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingForeignKey) {
    var result = std.array_list.Managed(ExistingForeignKey).init(allocator);
    errdefer freeExistingForeignKeys(allocator, &result);

    // Ahead of the query, never behind it: see the doc comment above.
    if (!pgRelationListed(driver_drv, "pg_proc")) {
        zent_log.warn(
            "zent: this PostgreSQL-wire server does not list `pg_proc`, so the foreign keys of table {s} are not compared — a declared key is left alone rather than reported missing and added a second time",
            .{table_name},
        );
        return error.ForeignKeyCatalogUnavailable;
    }

    // The table name is bound (`$1`), not interpolated: a name carrying a
    // quote would otherwise end the predicate early. `contype` and the schema
    // predicate stay literal — they are this function's own constants.
    const sql_text =
        \\SELECT con.conname,
        \\       a.attname,
        \\       rc.relname,
        \\       ra.attname,
        \\       k.ord
        \\FROM pg_constraint con
        \\JOIN pg_class t ON t.oid = con.conrelid
        \\JOIN pg_class rc ON rc.oid = con.confrelid
        \\JOIN pg_namespace n ON n.oid = t.relnamespace
        \\JOIN generate_subscripts(con.conkey, 1) AS k(ord) ON true
        \\JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = con.conkey[k.ord]
        \\JOIN pg_attribute ra ON ra.attrelid = rc.oid AND ra.attnum = con.confkey[k.ord]
        \\WHERE con.contype = 'f'
        \\  AND t.relname = $1
        \\  AND n.nspname = current_schema()
        \\ORDER BY con.conname, k.ord
    ;

    var rows = try driver_drv.query(sql_text, &.{.{ .string = table_name }});
    defer rows.deinit();

    var cols = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (cols.items) |c| allocator.free(c);
        cols.deinit();
    }
    var refs = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (refs.items) |c| allocator.free(c);
        refs.deinit();
    }

    var current: ?usize = null;
    var comparable = true;
    while (rows.next()) |row| {
        // `generate_subscripts` counts from 1, so a position of 1 is the start
        // of the next constraint.
        const position = row.getInt(4) orelse continue;
        if (current == null or position == 1) {
            try closeExistingForeignKey(&result, current, &cols, &refs, comparable);
            // Same copy-then-append shape as `getMySQLIndexes`: the dupe is
            // released by an `errdefer` declared in the loop body when the
            // `append` itself fails.
            const owned_ref_table = try allocator.dupe(u8, row.getText(2) orelse "");
            errdefer allocator.free(owned_ref_table);
            try result.append(.{
                .columns = &.{},
                .ref_table = owned_ref_table,
            });
            current = result.items.len - 1;
            comparable = true;
        }
        if (row.getText(1)) |column| {
            const owned_column = try allocator.dupe(u8, column);
            errdefer allocator.free(owned_column);
            try cols.append(owned_column);
        } else {
            comparable = false;
        }
        if (row.getText(3)) |ref_column| {
            const owned_ref_column = try allocator.dupe(u8, ref_column);
            errdefer allocator.free(owned_ref_column);
            try refs.append(owned_ref_column);
        } else {
            comparable = false;
        }
    }
    if (rows.nextError()) |err| return err;
    try closeExistingForeignKey(&result, current, &cols, &refs, comparable);
    return result;
}

/// SQLite, from `PRAGMA foreign_key_list(<table>)`: one row per (constraint,
/// column) shaped `(id, seq, "table", "from", "to", on_update, on_delete,
/// match)`.
///
/// There is no constraint name and no `ORDER BY`, so the rows are grouped by
/// `seq` restarting at 0 — SQLite emits one constraint's rows consecutively,
/// outermost loop over the constraint. `to` is NULL when the DDL said
/// `REFERENCES t` with no column list, which is recorded as *unreadable* rather
/// than as an empty list (see `ExistingForeignKey`).
///
/// Column 2 is the table **referenced**, not the table being asked about: the
/// pragma is a list of outgoing references.
///
/// `PRAGMA` takes no placeholders, so the table name is interpolated and checked
/// first (`sqlitePragmaNameUsable`); a name for a table that does not exist
/// answers an empty list, exactly like a table with no foreign keys.
pub fn getSQLiteForeignKeys(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, table_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingForeignKey) {
    var result = std.array_list.Managed(ExistingForeignKey).init(allocator);
    errdefer freeExistingForeignKeys(allocator, &result);

    if (!sqlitePragmaNameUsable(table_name)) {
        reportUnusableSqliteName("foreign_key_list", table_name);
        return error.InvalidTableName;
    }

    const sql_text = try allocator.print("PRAGMA foreign_key_list(\"{s}\")", .{table_name});
    defer allocator.free(sql_text);

    var rows = try driver_drv.query(sql_text, &.{});
    defer rows.deinit();

    var cols = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (cols.items) |c| allocator.free(c);
        cols.deinit();
    }
    var refs = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (refs.items) |c| allocator.free(c);
        refs.deinit();
    }

    var current: ?usize = null;
    var comparable = true;
    while (rows.next()) |row| {
        const seq = row.getInt(1) orelse continue;
        if (current == null or seq == 0) {
            try closeExistingForeignKey(&result, current, &cols, &refs, comparable);
            // Same copy-then-append shape as `getMySQLIndexes`: the dupe is
            // released by an `errdefer` declared in the loop body when the
            // `append` itself fails.
            const owned_ref_table = try allocator.dupe(u8, row.getText(2) orelse "");
            errdefer allocator.free(owned_ref_table);
            try result.append(.{
                .columns = &.{},
                .ref_table = owned_ref_table,
            });
            current = result.items.len - 1;
            comparable = true;
        }
        if (row.getText(3)) |column| {
            const owned_column = try allocator.dupe(u8, column);
            errdefer allocator.free(owned_column);
            try cols.append(owned_column);
        } else {
            comparable = false;
        }
        if (row.getText(4)) |ref_column| {
            const owned_ref_column = try allocator.dupe(u8, ref_column);
            errdefer allocator.free(owned_ref_column);
            try refs.append(owned_ref_column);
        } else {
            comparable = false;
        }
    }
    if (rows.nextError()) |err| return err;
    try closeExistingForeignKey(&result, current, &cols, &refs, comparable);
    return result;
}

/// A view as the *database* reports it. Owned: `name` and `definition` are
/// allocated, release the list with `freeExistingViews`.
pub const ExistingView = struct {
    /// The view's name, as the database spells it.
    name: []const u8,
    /// The definition **as the database stores it** — which is why it is not
    /// comparable with the schema's `view_sql`; see `getExistingViews`.
    definition: []const u8,
};

/// Query the view the database holds under `view_name`, from the catalog each
/// dialect keeps: PostgreSQL's `pg_views`, MySQL/MariaDB's
/// `information_schema.views`, SQLite's `sqlite_master` (`type = 'view'`). Never
/// from a rendered `CREATE VIEW` statement parsed back into shape, for the same
/// reason `getExistingIndexes` does not parse `indexdef`.
///
/// **`definition` cannot be compared against `TypeInfo.view_sql`**, and nothing
/// here tries to. The database does not keep the text the schema wrote:
///
///   - PostgreSQL stores a **rewritten** query in `pg_views.definition` —
///     explicit `::text`/`::integer` casts, added parentheses, schema-qualified
///     relation names, `WHERE ((status)::text = 'active'::text)` for a schema
///     that wrote `WHERE status = 'active'`.
///   - MySQL and MariaDB store their own normalization (backtick-quoted
///     identifiers, added parentheses), and the two servers differ from each
///     other in how much they rewrite.
///   - SQLite keeps the original statement text, but for a view this library
///     created that text begins `CREATE VIEW IF NOT EXISTS "<name>" AS ` — the
///     prefix is zent's, so the strings differ even there.
///
/// A string comparison would therefore report a difference on **every** database
/// and, through `assertSchema`, block every deploy — the false-report trap this
/// module's comparisons are written to avoid. That is why `checkSchema` reports
/// a missing relation (`missing_view`) but never a changed definition, and why
/// **a stale `view_sql` stays invisible**: the caller who wants to compare can
/// normalize per dialect from this function and decide, which is a judgement
/// this layer must not make for them.
///
/// The name is **bound** on all three dialects (`$1`, `?`), never interpolated:
/// every query here is an ordinary catalog `SELECT`, not a `PRAGMA`, so no name
/// has to be refused up front and `error.InvalidTableName` is never returned
/// from this function.
///
/// A name that is not a view of this schema answers an **empty list**, not an
/// error — a table of that name, a view in another schema, and no relation at
/// all are all "no view", which is the question asked here. (`checkSchema` asks
/// a different one — *any* relation of that name — which is why it probes with
/// `getExistingColumns`; see its doc comment.)
///
/// PostgreSQL withholds `definition` (NULL) from a user without privilege on the
/// view, and MySQL does the same without `SHOW VIEW`; the row is still returned,
/// with an empty `definition`, because the view's *existence* is the answer this
/// call also carries.
pub fn getExistingViews(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, view_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingView) {
    return switch (driver_drv.dialect().kind()) {
        .sqlite => getSQLiteViews(allocator, driver_drv, view_name),
        .postgres => getPostgresViews(allocator, driver_drv, view_name),
        .mysql => getMySQLViews(allocator, driver_drv, view_name),
        .unknown => error.UnsupportedDialect,
    };
}

/// The body the three dialect wrappers share: one catalog row per view, two
/// columns — the name and the stored definition — with the name bound as the
/// single parameter. `sql_text` is a comptime literal from each caller; nothing
/// is built from `view_name` at runtime.
pub fn getViewsByQuery(
    allocator: std.mem.Allocator,
    driver_drv: sql_driver.Driver,
    sql_text: []const u8,
    view_name: []const u8,
) IntrospectionError!std.array_list.Managed(ExistingView) {
    var result = std.array_list.Managed(ExistingView).init(allocator);
    errdefer freeExistingViews(allocator, &result);

    var rows = try driver_drv.query(sql_text, &.{.{ .string = view_name }});
    defer rows.deinit();

    while (rows.next()) |row| {
        const name = row.getText(0) orelse continue;
        // NULL means the catalog withheld the text (no privilege), not that the
        // view has an empty definition — see `getExistingViews`.
        const definition = row.getText(1) orelse "";

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_definition = try allocator.dupe(u8, definition);
        errdefer allocator.free(owned_definition);

        try result.append(.{ .name = owned_name, .definition = owned_definition });
    }
    if (rows.nextError()) |err| return err;
    return result;
}

/// SQLite: `sqlite_master`'s `sql` column, which is the statement text SQLite
/// kept — see `getExistingViews` for why that still differs from the schema's
/// `view_sql`. `sqlite_master` is an ordinary table, so the name is bound and
/// `sqlitePragmaNameUsable` is not needed (no statement text is built here).
pub fn getSQLiteViews(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, view_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingView) {
    return getViewsByQuery(
        allocator,
        driver_drv,
        "SELECT name, sql FROM sqlite_master WHERE type = 'view' AND name = ?",
        view_name,
    );
}

/// PostgreSQL: `pg_views`, filtered by `current_schema()` — the same schema
/// predicate `getExistingColumns` uses, so a view of another schema is not
/// mistaken for this one.
pub fn getPostgresViews(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, view_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingView) {
    return getViewsByQuery(
        allocator,
        driver_drv,
        "SELECT viewname, definition FROM pg_views WHERE schemaname = current_schema() AND viewname = $1",
        view_name,
    );
}

/// MySQL and MariaDB: `information_schema.views`, filtered by `DATABASE()` like
/// every other MySQL introspection here. Standard `information_schema`, not a
/// server-specific view, so the same statement runs on both servers.
pub fn getMySQLViews(allocator: std.mem.Allocator, driver_drv: sql_driver.Driver, view_name: []const u8) IntrospectionError!std.array_list.Managed(ExistingView) {
    return getViewsByQuery(
        allocator,
        driver_drv,
        "SELECT table_name, view_definition FROM information_schema.views WHERE table_schema = DATABASE() AND table_name = ?",
        view_name,
    );
}

/// Look up an ExistingIndex by name. Returns null when not found.
pub fn getExistingIndexByName(indexes: []const ExistingIndex, name: []const u8) ?ExistingIndex {
    for (indexes) |i| {
        if (std.mem.eql(u8, i.name, name)) return i;
    }
    return null;
}

/// Look up an ExistingColumn by name. Returns null when not found.
pub fn getExistingColumnByName(columns: []const ExistingColumn, name: []const u8) ?ExistingColumn {
    for (columns) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

pub fn freeExistingColumns(allocator: std.mem.Allocator, columns: *std.array_list.Managed(ExistingColumn)) void {
    for (columns.items) |c| {
        allocator.free(c.name);
        allocator.free(c.sql_type);
        // Only a PostgreSQL column carries one, and the empty default is not an
        // allocation (see `getExistingColumns`).
        if (c.udt_name.len > 0) allocator.free(c.udt_name);
    }
    columns.deinit();
}

pub fn freeExistingIndexes(allocator: std.mem.Allocator, indexes: *std.array_list.Managed(ExistingIndex)) void {
    for (indexes.items) |i| {
        allocator.free(i.name);
        for (i.columns) |c| allocator.free(c);
        allocator.free(i.columns);
    }
    indexes.deinit();
}

pub fn freeExistingForeignKeys(allocator: std.mem.Allocator, foreign_keys: *std.array_list.Managed(ExistingForeignKey)) void {
    for (foreign_keys.items) |fk| {
        for (fk.columns) |c| allocator.free(c);
        allocator.free(fk.columns);
        allocator.free(fk.ref_table);
        for (fk.ref_columns) |c| allocator.free(c);
        allocator.free(fk.ref_columns);
    }
    foreign_keys.deinit();
}

pub fn freeExistingViews(allocator: std.mem.Allocator, views: *std.array_list.Managed(ExistingView)) void {
    for (views.items) |v| {
        allocator.free(v.name);
        allocator.free(v.definition);
    }
    views.deinit();
}

/// Whether `pg_class` lists the relation `name` — the probe that decides
/// whether a PostgreSQL-catalog query may be sent at all.
///
/// **Why a probe rather than a retry.** A rejected statement aborts the
/// transaction it runs in on every PostgreSQL-compatible server ("current
/// transaction is aborted, commands ignored until end of transaction block"),
/// and this introspection runs inside the caller's migration transaction — so
/// recovering from the rejection is not recovery: the migration would carry on
/// over a dead transaction and fail somewhere else entirely (measured against
/// HeliosDB Nano, which refuses `pg_am` with SQLSTATE 42P01 *and* leaves the
/// transaction unusable). Asking a question that cannot fail keeps the decision
/// ahead of the damage: `pg_class` is the one catalog both full PostgreSQL and
/// the wire-compatible servers that lack the rest do have.
///
/// **One relation at a time, because the answer is per relation.** A
/// wire-compatible server may have the table and still not list it here —
/// HeliosDB Nano answers 0 for `pg_index` while `SELECT count(*) FROM pg_index`
/// returns its real rows — so a probe asking about several names at once would
/// read "none of them" and throw away reads that would have worked. The two
/// names asked about in this module are exactly the ones whose *absence* is
/// what has to be known in advance: `pg_am` (the join `getPostgresIndexes`
/// cannot send when it is missing) and `pg_extension` (the catalog
/// `checkPostgresExtensions` cannot read).
///
/// The statement is assembled rather than bound, and `name` is a `comptime`
/// parameter, so the literal is this module's own constant and never caller
/// input — a bind list could not spell `relname = '…'` either.
///
/// Conservative by construction: any problem reading `pg_class` — including
/// being inside an already-aborted transaction — answers "not listed", so the
/// caller drops to the reading that does not need it rather than assuming it is
/// there.
pub fn pgRelationListed(drv: sql_driver.Driver, comptime name: []const u8) bool {
    const sql = comptime pg_relation_probe_prefix ++ " = '" ++ name ++ "'";
    var rows = drv.query(sql, &.{}) catch return false;
    defer rows.deinit();
    const row = rows.next() orelse return false;
    const n = row.getInt(0) orelse return false;
    return n > 0;
}

/// The error carries no payload, so the name it refused is logged instead —
/// `warn`, because this is a diagnostic the caller is about to see as a
/// returned error, not a failed statement of its own.
pub fn reportUnusableSqliteName(pragma: []const u8, table_name: []const u8) void {
    zent_log.warn(
        "zent: refusing to build SQLite PRAGMA {s} for table {s} — the name contains a quote or NUL that would end the statement early; rename the table or reach it through a dialect that binds the name",
        .{ pragma, table_name },
    );
}

/// A lower-cased, owned copy of `text` — what `ExistingColumn` stores.
///
/// The comparison in `columnTypesAgree` is case-insensitive by construction,
/// and both catalog answers (`data_type`, `udt_name`) arrive in the server's own
/// spelling, so every string this struct owns is normalized once, here, rather
/// than at each comparison.
pub fn dupeLower(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const owned = try allocator.alloc(u8, text.len);
    for (text, owned) |byte, *dest| dest.* = std.ascii.toLower(byte);
    return owned;
}
