//! Per-dialect SQL expression fragments for statements the fluent builders do
//! not cover — `zent.sql_dialect_expr`.
//!
//! A raw-SQL caller (a statement composed with `zent.scope`, an audit column, a
//! bulk aggregate) has to spell the same fact differently on each backend, and
//! the spellings are not guessable from each other:
//!
//! | fact | PostgreSQL | MySQL / MariaDB | SQLite |
//! |---|---|---|---|
//! | current epoch seconds | `EXTRACT(EPOCH FROM now())::bigint` | `UNIX_TIMESTAMP()` | `unixepoch()` |
//! | ignore a conflict | `… ON CONFLICT DO NOTHING` (a *suffix*) | `INSERT IGNORE` | `INSERT OR IGNORE` |
//! | a TEXT column in a numeric aggregate | a cast is *required* (`sum(text)` does not exist) | coerces implicitly, inexactly | coerces too; the cast is the documented way to ask |
//!
//! `nowSecs` existed only as the private `epochExpr` in
//! `codegen/update_delete.zig`, so a consumer writing the same audit stamp by
//! hand re-derived the mapping (and got SQLite wrong, since it is the only one
//! whose spelling carries parentheses). It is now one function that
//! `update_delete` itself calls.
//!
//! Two mappings are deliberately **not** here, with the reason:
//!
//! - `insertIgnorePrefix(dialect)` is not a function of its own. PostgreSQL's
//!   ignore clause is a *suffix* (`ON CONFLICT DO NOTHING`, after the VALUES
//!   list or the SELECT), so a prefix cannot express it, and a prefix helper
//!   would have to answer `"INSERT "` on PostgreSQL — a silent trap: the
//!   statement runs and does not ignore anything, which the caller notices only
//!   as a key error (or not at all, without a unique constraint). `insertIgnore`
//!   returns both fragments instead, so the PostgreSQL clause is in the
//!   caller's hand. For a statement whose columns and values are known,
//!   `sql.InsertOrIgnore(…)` (and its `fromSelect` form) already renders exactly
//!   these fragments — reach for the fragments only where the builder cannot
//!   reach, and see the test that keeps the two in step.
//! - `nowSecs` is the *set-expression / operand* form. The DDL `DEFAULT` spelling
//!   lives in `sql/schema/migrate.zig`'s `auditTimestampDefault`, wrapped in the
//!   parentheses a default needs (`(EXTRACT(EPOCH FROM now())::bigint)`); that
//!   is a paren-different form of these strings, not a second opinion, and can
//!   be folded onto this function by adding the parens at the DDL emitter.

const std = @import("std");
const Dialect = @import("dialect.zig").Dialect;

/// The expression that evaluates to the current Unix epoch in whole seconds, as
/// an integer, on `dialect` — the value zent's `.time` columns and the
/// `TimeMixin` audit columns hold.
///
/// PostgreSQL's `now()` is a `timestamptz`, so the `::bigint` cast is what keeps
/// the column (and the scanned `i64`) an integer; SQLite's `unixepoch()` is
/// parenthesized so it drops into a larger expression unchanged
/// (`SET x = (unixepoch()) + 60`); MySQL's `UNIX_TIMESTAMP()` already answers an
/// integer. An unnamed dialect takes SQLite's spelling — the fallback every
/// dialect switch in this library gives it (see `Dialect.Kind`).
///
/// **This reads the database server's clock**, not the application's; the two
/// machines' clocks can disagree. Use `zent.walltime.nowSecs()` when the
/// timestamp has to come from the process that runs the statement.
pub fn nowSecs(dialect: Dialect) []const u8 {
    return switch (dialect.kind()) {
        .postgres => now_secs_postgres,
        .mysql => now_secs_mysql,
        .sqlite, .unknown => now_secs_sqlite,
    };
}

/// The same expression spelled for a DDL `DEFAULT`, which needs the whole thing
/// parenthesized (`(UNIX_TIMESTAMP())`, not `UNIX_TIMESTAMP()`) on MySQL and
/// PostgreSQL. SQLite's spelling already carries its parentheses, so it is
/// emitted unchanged — one definition per backend, two shapes over it.
pub fn nowSecsParenthesized(dialect: Dialect) []const u8 {
    return switch (dialect.kind()) {
        .postgres => "(" ++ now_secs_postgres ++ ")",
        .mysql => "(" ++ now_secs_mysql ++ ")",
        .sqlite, .unknown => now_secs_sqlite,
    };
}

const now_secs_postgres = "EXTRACT(EPOCH FROM now())::bigint";
const now_secs_mysql = "UNIX_TIMESTAMP()";
const now_secs_sqlite = "(unixepoch())";

/// The fragments that turn an `INSERT` into an ignore-on-conflict insert. Use
/// `insertIgnore` to obtain one; `prefix` and `suffix` belong together.
pub const InsertIgnore = struct {
    /// Precedes the `INTO <table>` part, e.g. `INSERT IGNORE INTO …`.
    prefix: []const u8,
    /// Follows the statement body — its `VALUES (…)` list or its `SELECT`.
    /// Empty on MySQL and SQLite, whose ignore is entirely a prefix.
    suffix: []const u8,
};

/// `INSERT IGNORE` / `INSERT OR IGNORE` / `INSERT … ON CONFLICT DO NOTHING`, as
/// the prefix and suffix that together spell it on `dialect`:
///
/// ```zig
/// const ins = sql_dialect_expr.insertIgnore(dialect);
/// const stmt = try allocator.print("{s}INTO {s} ({s}) VALUES (?){s}", .{ ins.prefix, table, columns, ins.suffix });
/// ```
///
/// On PostgreSQL the clause is a suffix, so dropping `suffix` yields a plain
/// `INSERT` rather than a compile error — see the module doc for why this
/// returns both halves instead of a prefix. An unnamed dialect gets plain
/// `INSERT` with no suffix, the same fallback `sql.InsertBuilder` gives it.
pub fn insertIgnore(dialect: Dialect) InsertIgnore {
    return switch (dialect.kind()) {
        .mysql => .{ .prefix = "INSERT IGNORE ", .suffix = "" },
        .sqlite => .{ .prefix = "INSERT OR IGNORE ", .suffix = "" },
        .postgres => .{ .prefix = "INSERT ", .suffix = " ON CONFLICT DO NOTHING" },
        .unknown => .{ .prefix = "INSERT ", .suffix = "" },
    };
}

/// `expr` rendered as a number, for a numeric aggregate or comparison whose
/// input is TEXT on `dialect`.
///
/// This exists because of zent's own column mapping: `.decimal` is `NUMERIC` on
/// PostgreSQL and `DECIMAL(38,10)` on MySQL, but **TEXT on SQLite** on purpose —
/// NUMERIC affinity there would rewrite the literal `"1.10"` into the REAL
/// `1.1`, losing the exact bytes the type promises (`core/field.zig:459-467`).
/// A numeric aggregate over such a column then answers differently per backend,
/// and no two of the three answers are the same. PostgreSQL has no `sum(text)`
/// at all — `SELECT sum(v)` over a TEXT column fails with "function `sum(text)`
/// does not exist", so the cast is what makes the statement run there (and a
/// value that is not a number is an error rather than a zero). MySQL/MariaDB
/// coerce the text to a DOUBLE implicitly, so the cast is about exactness:
/// `SUM(v)` over `'1.10', '2.20'` answers `3.3000000000000003` where
/// `SUM(CAST(v AS DECIMAL(65,30)))` answers the exact `3.3`. SQLite coerces too
/// (`sum()` applies numeric conversion), and its `CAST` is the documented
/// spelling of that conversion — the same one the `v + 0` idiom performs.
///
/// The rendering itself:
///
/// - PostgreSQL, SQLite, unnamed: `CAST(expr AS NUMERIC)`
/// - MySQL, MariaDB: `CAST(expr AS DECIMAL(65,30))` — `NUMERIC` is not one of
///   MySQL's cast targets (errno 1064); `DECIMAL(65,30)` is the widest
///   documented form.
///
/// PostgreSQL and MySQL accept the cast over a column that is already numeric,
/// so it is safe to apply unconditionally. It does **not** make a SQLite
/// aggregate exact: `CAST` performs SQLite's numeric conversion, which turns
/// text that does not parse into 0 and fractional text into a REAL — it changes
/// what SQLite *reads*, not the TEXT-affinity storage that keeps the literal
/// bytes.
///
/// `buf` must hold `expr.len + 24` bytes (the wider of the two wrappings);
/// anything smaller returns `error.NoSpaceLeft`. The result borrows `buf` and
/// `expr`.
pub fn numericTextAsNumber(dialect: Dialect, buf: []u8, expr: []const u8) error{NoSpaceLeft}![]const u8 {
    return switch (dialect.kind()) {
        .postgres, .sqlite, .unknown => std.fmt.bufPrint(buf, "CAST({s} AS NUMERIC)", .{expr}),
        .mysql => std.fmt.bufPrint(buf, "CAST({s} AS DECIMAL(65,30))", .{expr}),
    };
}

test "nowSecs spells the current epoch for each dialect, verbatim" {
    try std.testing.expectEqualStrings("EXTRACT(EPOCH FROM now())::bigint", nowSecs(Dialect.postgres));
    try std.testing.expectEqualStrings("UNIX_TIMESTAMP()", nowSecs(Dialect.mysql));
    try std.testing.expectEqualStrings("(unixepoch())", nowSecs(Dialect.sqlite));
    // An unnamed dialect takes SQLite's spelling — the fallback `Dialect.Kind`
    // documents, and the one the private `epochExpr` this replaced had as its
    // `else`.
    try std.testing.expectEqualStrings("(unixepoch())", nowSecs(Dialect{ .name = "cockroach" }));
}

test "the ignore fragments render what sql.InsertOrIgnore renders" {
    // The module doc sends a caller with a known column list to
    // `sql.InsertOrIgnore` and a hand-written statement to `insertIgnore`, so
    // the two spellings have to agree: if `InsertBuilder`'s per-dialect
    // spelling changes, this fails instead of letting raw SQL and the builder
    // drift apart. Both sides are pinned as literals — comparing the fragments
    // to the builder alone would pass for any pair of matching mistakes.
    const allocator = std.testing.allocator;
    const sql = @import("builder.zig");

    const Case = struct {
        dialect: Dialect,
        /// What `sql.InsertOrIgnore` renders.
        builder_sql: []const u8,
        /// What `insertIgnore` renders for the same body. PostgreSQL is the
        /// one that differs: the builder leaves `ON CONFLICT DO NOTHING` to
        /// its caller (`update_delete.buildM2MAddQuery` appends it), the
        /// fragments carry it.
        fragment_sql: []const u8,
    };

    const columns = [_][]const u8{"id"};
    const values = [_]sql.Value{.{ .int = 1 }};

    inline for (.{
        Case{
            .dialect = Dialect.mysql,
            .builder_sql = "INSERT IGNORE INTO `t` (`id`) VALUES (?)",
            .fragment_sql = "INSERT IGNORE INTO `t` (`id`) VALUES (?)",
        },
        Case{
            .dialect = Dialect.sqlite,
            .builder_sql = "INSERT OR IGNORE INTO \"t\" (\"id\") VALUES (?)",
            .fragment_sql = "INSERT OR IGNORE INTO \"t\" (\"id\") VALUES (?)",
        },
        Case{
            .dialect = Dialect.postgres,
            .builder_sql = "INSERT INTO \"t\" (\"id\") VALUES ($1)",
            .fragment_sql = "INSERT INTO \"t\" (\"id\") VALUES ($1) ON CONFLICT DO NOTHING",
        },
    }) |case| {
        var ib = sql.InsertOrIgnore(allocator, case.dialect, "t");
        defer ib.deinit();
        _ = try ib.columns(&columns);
        _ = try ib.values(&values);
        const q = try ib.query();
        try std.testing.expectEqualStrings(case.builder_sql, q.sql);

        const ins = insertIgnore(case.dialect);
        // The fragments must reproduce the builder's text: the prefix is
        // literally its opening, and appending the suffix gives the assembled
        // statement.
        try std.testing.expect(std.mem.startsWith(u8, case.builder_sql, ins.prefix));
        if (ins.suffix.len == 0) {
            try std.testing.expect(std.mem.endsWith(u8, case.builder_sql, ins.suffix));
        } else {
            // PostgreSQL: the builder does *not* emit the ignore clause — its
            // caller appends it (`update_delete.buildM2MAddQuery`), which is
            // exactly the step a raw-SQL writer forgets. Pin that gap here so
            // the helper's suffix stays the only copy of the clause.
            try std.testing.expect(std.mem.indexOf(u8, case.builder_sql, "ON CONFLICT") == null);
            try std.testing.expect(std.mem.indexOf(u8, case.fragment_sql, ins.suffix) != null);
        }
        var buf: [128]u8 = undefined;
        const composed = try std.fmt.bufPrint(&buf, "{s}{s}{s}", .{
            ins.prefix,
            case.builder_sql[ins.prefix.len..],
            ins.suffix,
        });
        try std.testing.expectEqualStrings(case.fragment_sql, composed);
    }
}

test "numericTextAsNumber renders each dialect's cast, and asks for room" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("CAST(amount AS NUMERIC)", try numericTextAsNumber(Dialect.postgres, &buf, "amount"));
    try std.testing.expectEqualStrings("CAST(amount AS NUMERIC)", try numericTextAsNumber(Dialect.sqlite, &buf, "amount"));
    try std.testing.expectEqualStrings("CAST(amount AS NUMERIC)", try numericTextAsNumber(Dialect{ .name = "cockroach" }, &buf, "amount"));
    // MySQL has no `CAST(… AS NUMERIC)` (errno 1064), so the MySQL spelling is
    // a DECIMAL — and it must not be silently equal to the others.
    try std.testing.expectEqualStrings("CAST(amount AS DECIMAL(65,30))", try numericTextAsNumber(Dialect.mysql, &buf, "amount"));

    // The documented size is `expr.len + 24` — the MySQL wrapping is the wider
    // one — and exactly one byte short must fail rather than truncate.
    const expr = "price";
    var exact: [expr.len + 24]u8 = undefined;
    const sized = try numericTextAsNumber(Dialect.mysql, &exact, expr);
    try std.testing.expectEqualStrings("CAST(price AS DECIMAL(65,30))", sized);
    try std.testing.expectEqual(expr.len + 24, sized.len);

    var too_small: [expr.len + 23]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, numericTextAsNumber(Dialect.mysql, &too_small, expr));
}
