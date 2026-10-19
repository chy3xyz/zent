//! The SQL type vocabulary migration planning works in: the column/table/index
//! shapes, and the mapping from a declared field to the type a dialect emits.
//!
//! Split out of `migrate.zig` (which had grown to one file of 226 declarations):
//! this half is pure — no driver, no catalog, no I/O — so it can be read and
//! tested without a database, and the DDL planner and the introspection code
//! both sit on top of it instead of beside it.

const std = @import("std");

pub const budget = @import("../base/budget.zig");
pub const field_mod = @import("../core/field.zig");
pub const Dialect = @import("../base/dialect.zig").Dialect;
pub const dialect_expr = @import("../sql/dialect_expr.zig");
pub const TypeInfo = @import("../codegen/graph.zig").TypeInfo;

/// Returns true if `sql_type` is an integer type that supports AUTO_INCREMENT in MySQL.
pub fn isMySqlAutoIncrementType(sql_type: []const u8) bool {
    const types = &[_][]const u8{ "INTEGER", "INT", "BIGINT", "SMALLINT", "TINYINT", "MEDIUMINT" };
    for (types) |t| {
        if (std.ascii.eqlIgnoreCase(sql_type, t)) return true;
    }
    return false;
}

/// MySQL's BLOB/TEXT/JSON family, spelled in lower case for a
/// case-insensitive comparison.
pub const mysql_blob_text_json_types = [_][]const u8{
    "text", "tinytext", "mediumtext", "longtext",
    "blob", "tinyblob", "mediumblob", "longblob",
    "json",
};

/// True when `sql_type` is in MySQL's BLOB/TEXT/JSON family.
///
/// These are the types MySQL refuses to use in a key specification without a
/// key length (errno 1170, `BLOB/TEXT column used in key specification
/// without a key length`) and — the TEXT and BLOB members — refuses to give a
/// literal `DEFAULT` (errno 1101). PostgreSQL and SQLite have neither
/// restriction, which is why `field.Text` keeps mapping to `TEXT` on every
/// dialect (`src/core/field.zig`): the difference is diagnosed here, at DDL
/// generation, instead of being papered over in the type mapping.
///
/// A parenthesized modifier (`TEXT(100)`, `BLOB(16)`) is ignored, the same
/// way `normalizeSqlType` ignores it.
pub fn isMySqlBlobTextJsonType(sql_type: []const u8) bool {
    var base = sql_type;
    if (std.mem.indexOfScalar(u8, base, '(')) |paren| base = base[0..paren];
    base = std.mem.trimEnd(u8, base, " ");
    for (mysql_blob_text_json_types) |candidate| {
        if (std.ascii.eqlIgnoreCase(base, candidate)) return true;
    }
    return false;
}

/// Which server is behind a `.mysql`-kind connection, for the DDL rules the two
/// server families do not share.
///
/// MySQL and MariaDB speak the same wire protocol and share the errno
/// numbering, but not every rule: **MariaDB >= 10.2.1 accepts a `DEFAULT` on a
/// BLOB/TEXT column**, which MySQL refuses with errno 1101 (the column cannot
/// have a default value). Everything else `findMySqlTextRestriction` classifies
/// — the key-length restriction behind errno 1170 — is refused by both, so it is
/// the same on either server.
///
/// The name is derived once per migration from `SELECT VERSION()` (see
/// `detectMySqlServer`) and threaded through the DDL generators, so a preview
/// and the run it previews classify identically.
pub const MySqlServer = enum {
    /// MySQL — or a server that could not be identified, which is deliberately
    /// treated as MySQL so an unknown server never gets a rule relaxed for it.
    mysql,
    /// MariaDB, identified by "MariaDB" in `SELECT VERSION()`.
    mariadb,
};

/// The named errors a MySQL BLOB/TEXT/JSON restriction turns into.
///
/// Two names rather than one `MySQLTextColumnRestriction`, because they have
/// different fixes and different blast radii: a stray `DEFAULT` is dropped
/// from the declaration, while a key constraint has to move off the column
/// (usually to `field.String`, which is `VARCHAR(255)` on MySQL). A caller
/// switching on the error can tell the two apart; the unified name would fold
/// that back into a log line. Neither name can carry the table/column, which
/// is why the generator logs the detail (`MySqlTextRestriction`) before
/// returning.
pub const MySqlTextError = error{
    MySQLTextColumnCannotHaveDefault,
    MySQLTextColumnCannotBeIndexed,
};

/// The three ways a declared index method/opclass can be malformed. They are
/// raised while the DDL is generated, so every entry point that builds tables
/// carries them (`createTables` / `createAllTables` / the planner) and the
/// codegen client re-states this set in `CreateTablesError`.
pub const IndexDeclError = error{
    /// The `method` (or its `opclass`) is not a bare identifier — the DDL
    /// concatenates it verbatim, so anything else would be an injection hole.
    InvalidIndexMethod,
    InvalidIndexOpClass,
    /// A PostgreSQL opclass describes *one* indexed column
    /// (`(embedding vector_cosine_ops)`); declaring it over a multi-column
    /// index has no legal rendering.
    OpClassNeedsSingleColumn,
};

/// The named error a migration returns when a declared column type needs a
/// PostgreSQL extension this database does not have installed.
///
/// One name rather than one per extension: the fix is the same statement in
/// every case (`CREATE EXTENSION IF NOT EXISTS <name>`), and which extension is
/// missing is what the log line the check emits before returning carries — an
/// error tag cannot.
pub const PostgresExtensionError = error{
    /// The schema declares a column type provided by an extension
    /// (`vector(n)`, `citext`, `hstore`, `ltree`, PostGIS's `geometry` /
    /// `geography`) and `pg_extension` does not list that extension. Raised
    /// *before* any DDL, so the run leaves the database exactly as it was.
    MissingPostgresExtension,
};

/// A restriction MySQL puts on a BLOB/TEXT/JSON column that the DDL about to
/// be generated would trip.
///
/// The error carries no payload, so this is both the detail the generator logs
/// and the shape a caller can inspect *before* generating (via
/// `findMySqlTextRestriction`) when it wants to decide rather than fail.
pub const MySqlTextRestriction = struct {
    table: []const u8,
    column: []const u8,
    /// The column's MySQL type as `columnSQLType` resolves it (e.g. `TEXT`).
    sql_type: []const u8,
    kind: Kind,
    /// Set only for `.index`: the index whose key list names `column`.
    index_name: []const u8 = "",

    pub const Kind = enum {
        /// `DEFAULT` on the column — errno 1101.
        default_value,
        /// `UNIQUE` on the column — errno 1170.
        unique,
        /// `PRIMARY KEY`, inline or listed in a composite `PRIMARY KEY (...)` —
        /// errno 1170.
        primary_key,
        /// A key column of a `CREATE INDEX` — errno 1170.
        index,
    };
};

pub fn nameInList(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

pub fn columnDefByName(table: TableDef, name: []const u8) ?ColumnDef {
    for (table.columns) |col| {
        if (std.mem.eql(u8, col.name, name)) return col;
    }
    return null;
}

/// A PostgreSQL column type whose *provider is an extension*, and the extension
/// that provides it.
///
/// Deliberately small and exact. `zent` cannot ask a server "which extension
/// owns this type?" before the type exists, so the only safe default is silence:
/// a name this table does not know is not an extension type as far as the check
/// is concerned, and the migration proceeds exactly as it did before the check
/// existed. Guessing the other way would refuse a migration that would have
/// worked.
pub const PostgresExtensionType = struct {
    /// The declared type's bare name, lower case.
    declared_type: []const u8,
    /// The extension that provides it — also the name `CREATE EXTENSION` takes
    /// (pgvector's extension is `vector`, PostGIS's is `postgis`).
    extension: []const u8,
};

/// The known type → extension pairs: PostgreSQL's own types are all built in,
/// so what is left is the extension types a schema realistically declares.
///
/// `vector` is the one a `field.Vector` reaches (its spelling is `vector(n)`,
/// and the dimension is stripped before the lookup); the rest arrive through
/// `.SqlType(s)` / `field.Other(name, s)`, which on PostgreSQL is emitted
/// verbatim and can therefore name anything.
pub const postgres_extension_types = [_]PostgresExtensionType{
    .{ .declared_type = "vector", .extension = "vector" }, // pgvector
    .{ .declared_type = "citext", .extension = "citext" },
    .{ .declared_type = "hstore", .extension = "hstore" },
    .{ .declared_type = "ltree", .extension = "ltree" },
    .{ .declared_type = "geometry", .extension = "postgis" },
    .{ .declared_type = "geography", .extension = "postgis" },
    // Not a type PostGIS defines (`geometry` and `geography` are), but a
    // declaration that says `postgis` is asking for the same extension and
    // deserves the same diagnosis rather than silence.
    .{ .declared_type = "postgis", .extension = "postgis" },
};

/// The bare type name a declaration starts with: `vector(1536)` → `vector`,
/// `public.citext` → `citext`, `hstore[]` → `hstore`.
///
/// The declaration is what the schema wrote, so it carries everything a type
/// reference may: a schema qualifier, a dimension/scale, an array marker. Only
/// the bare name is comparable to the table above. Pure, so the decision can be
/// pinned without a server.
pub fn bareDeclaredType(declared: []const u8) []const u8 {
    var name = std.mem.trim(u8, declared, " \t");
    // A schema qualifier. The *last* dot, because a quoted qualifier may itself
    // contain one.
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name = name[dot + 1 ..];
    var end = name.len;
    if (std.mem.indexOfScalar(u8, name, '(')) |paren| end = @min(end, paren);
    if (std.mem.indexOfScalar(u8, name, '[')) |bracket| end = @min(end, bracket);
    return std.mem.trim(u8, name[0..end], " \t");
}

/// The extension a declared column type needs, or `null` when the name is not
/// one this module knows — the common answer, since it covers every type
/// PostgreSQL itself provides.
pub fn postgresExtensionForDeclaredType(declared: []const u8) ?[]const u8 {
    const bare = bareDeclaredType(declared);
    if (bare.len == 0) return null;
    for (postgres_extension_types) |entry| {
        if (std.ascii.eqlIgnoreCase(bare, entry.declared_type)) return entry.extension;
    }
    return null;
}

/// Every PostgreSQL extension this graph's *declarations* need, deduplicated,
/// in first-seen order.
///
/// Pure and comptime, so a schema that needs none answers with an empty list and
/// the catalog is never asked. That is the same rule `graphHasMySqlTextDefault`
/// follows and for the same reason: the statement-modelling stubs in
/// `src/test/allocation_failures_plan.zig` claim every statement the planner
/// issues, so a probe a schema did not warrant must not be issued at all.
///
/// Two declarations can need one. A `field.Vector` column always needs pgvector
/// (its `vector(n)` type is the extension's), and an explicit `.SqlType(s)` /
/// `field.Other(name, s)` override may name an extension type — it is emitted
/// verbatim on PostgreSQL. The built-in field kinds cannot: `field.Json` is
/// `JSONB`, `field.Bytes` is `BYTEA`, and every other kind maps to a type
/// PostgreSQL owns.
pub fn requiredPostgresExtensions(comptime infos: []const TypeInfo) []const []const u8 {
    comptime {
        @setEvalBranchQuota(budget.graph(infos.len));
        var needed: []const []const u8 = &.{};
        for (infos) |info| {
            if (info.is_view) continue;
            for (info.fields) |f| {
                const extension: ?[]const u8 = blk: {
                    if (f.field_type == .vector) break :blk "vector";
                    if (f.sql_type_override) |override| break :blk postgresExtensionForDeclaredType(override);
                    break :blk null;
                };
                const name = extension orelse continue;
                var seen = false;
                for (needed) |existing| {
                    if (std.mem.eql(u8, existing, name)) seen = true;
                }
                if (!seen) needed = needed ++ &[_][]const u8{name};
            }
        }
        return needed;
    }
}

/// `requiredPostgresExtensions` as one comma-separated string, for the warning
/// `checkPostgresExtensions` emits when the catalog cannot be read: the
/// returned value carries no text, so the line has to name what was asked
/// about. Pure and comptime, like the list it renders.
pub fn requiredExtensionsJoined(comptime infos: []const TypeInfo) []const u8 {
    comptime {
        @setEvalBranchQuota(budget.graph(infos.len));
        var out: []const u8 = "";
        for (requiredPostgresExtensions(infos), 0..) |name, i| {
            if (i > 0) out = out ++ ", ";
            out = out ++ name;
        }
        return out;
    }
}

/// Column definition for CREATE TABLE.
pub const ColumnDef = struct {
    name: []const u8,
    /// Explicit SQL type for synthetic columns and backwards-compatible callers.
    sql_type: []const u8,
    /// Logical schema type. When present, migration SQL resolves it through the
    /// active dialect instead of reusing the SQLite-oriented `sql_type` value.
    logical_type: ?field_mod.FieldType = null,
    /// DDL spelling for a string column that declared `VarChar(n)` —
    /// comptime-formatted (`"VARCHAR(120)"`), because `columnSQLType` is a
    /// runtime fn returning a borrowed slice it cannot print into.
    /// `columnSQLType` uses it only for a MySQL dialect (replacing the
    /// default `VARCHAR(255)`); PostgreSQL and SQLite keep the `TEXT` the
    /// `.string` family already resolves to there. null for every column
    /// that declared no length.
    varchar_sql: ?[]const u8 = null,
    /// DDL spelling for a `field.Vector` column — comptime-formatted
    /// (`"vector(3)"`) for the same reason `varchar_sql` is:
    /// `columnSQLType` is a runtime fn returning a borrowed slice it cannot
    /// print into. `columnSQLType` uses it on a PostgreSQL dialect only;
    /// MySQL and SQLite get the field kind's mapping (`TEXT`). null for every
    /// column that declared no dimension.
    vector_sql: ?[]const u8 = null,
    /// Explicit SQL type declared by `.SqlType(s)` / `field.Other(name, s)`,
    /// null when the schema declared none. `columnSQLType` emits it verbatim
    /// and on a PostgreSQL dialect only; it wins over `varchar_sql`. Beside
    /// `logical_type` rather than inside `sql_type` for the same reason
    /// `varchar_sql` is: `sql_type` is the graph's comptime-resolved value for
    /// the dialect the graph was built with, while the override has to be
    /// resolved against the dialect the migration is actually running on.
    sql_type_override: ?[]const u8 = null,
    primary_key: bool = false,
    not_null: bool = false,
    unique: bool = false,
    default_value: ?[]const u8 = null,
    auto_increment: bool = false,
};

pub fn columnSQLType(column: ColumnDef, dialect: Dialect) []const u8 {
    // A declared `.SqlType(s)` / `field.Other(name, s)` names the column's type
    // outright, so it is resolved first — ahead of the kind's mapping and ahead
    // of a declared `VarChar(n)`. PostgreSQL only: the strings this names are
    // PostgreSQL's own extension/custom types and arrays, and a server that
    // cannot parse the name would fail `CREATE TABLE` rather than fall back.
    if (column.sql_type_override) |override| {
        if (dialect.kind() == .postgres) return override;
    }
    if (column.logical_type) |logical_type| {
        // A declared `VarChar(n)` replaces the default VARCHAR(255) on MySQL
        // only; every other dialect — and every undeclared column — resolves
        // through `sqlType` byte-for-byte unchanged.
        if (logical_type == .string) {
            if (column.varchar_sql) |varchar| {
                if (dialect.kind() == .mysql) return varchar;
            }
        }
        // A `field.Vector`'s type is dimension-bearing (`vector(3)`), which the
        // dimension-less `sqlType` cannot spell — the migration carries the
        // declaration as the comptime-formatted string, exactly as `VarChar(n)`
        // does. PostgreSQL only: MySQL and SQLite have no vector type, so they
        // take the `TEXT` mapping below (pgvector's own text form, `[1,2,3]`).
        if (logical_type == .vector) {
            if (column.vector_sql) |vector| {
                if (dialect.kind() == .postgres) return vector;
            }
        }
        return switch (logical_type) {
            inline else => |field_type| field_mod.sqlType(field_type, dialect),
        };
    }
    return column.sql_type;
}

/// What a column declared, and what this dialect will actually emit, when the
/// two differ because the declaration names a type the dialect does not have.
pub const DeclaredTypeRewrite = struct {
    /// The type the schema declared (`vector(1536)`, `citext`).
    declared: []const u8,
    /// The type `columnSQLType` resolves it to on this dialect (`TEXT`).
    emitted: []const u8,
};

/// The rewrite a column's declaration is about to suffer, or `null` when the
/// declaration is what gets emitted.
///
/// Two declarations can be rewritten, because only they name a type the schema
/// chose rather than a kind the dialect mapping owns:
///
///   - a `field.Vector` column: PostgreSQL gets `vector(n)` (pgvector),
///     MySQL/SQLite get the kind's `TEXT` (`field.sqlType`'s `.vector` arm),
///     which is a column of a different type, not a different spelling of the
///     same one;
///   - a `.SqlType(s)` / `field.Other(name, s)` override: `columnSQLType`
///     emits it verbatim on PostgreSQL **only**, so every other dialect falls
///     back to the field kind's mapping.
///
/// Everything else is a *mapping*, not a rewrite: `field.String` is `TEXT` on
/// PostgreSQL/SQLite and `VARCHAR(255)` on MySQL, `field.Json` is `JSONB` or
/// `TEXT` — the schema declared a kind and the dialect rendered it, which is
/// the dialect support working as documented. Those must stay silent, or every
/// schema warns.
///
/// Decided by comparing the declaration with `columnSQLType`'s own answer
/// rather than by re-deriving which arm fires, so the warning cannot disagree
/// with the SQL it accompanies (a hand-built `ColumnDef` whose `sql_type`
/// already *is* its override, for instance, is emitted as declared and stays
/// silent). Pure, so both dialects can be pinned without a server.
pub fn declaredTypeRewrite(col: ColumnDef, dialect: Dialect) ?DeclaredTypeRewrite {
    const declared: ?[]const u8 = if (col.sql_type_override) |override|
        override
    else if (col.logical_type != null and col.logical_type.? == .vector)
        (col.vector_sql orelse "vector")
    else
        null;
    const declared_type = declared orelse return null;
    const emitted = columnSQLType(col, dialect);
    if (std.mem.eql(u8, declared_type, emitted)) return null;
    return .{ .declared = declared_type, .emitted = emitted };
}

/// The dialect's name as the person reading the log says it.
pub fn dialectDisplayName(kind: Dialect.Kind) []const u8 {
    return switch (kind) {
        .sqlite => "SQLite",
        .postgres => "PostgreSQL",
        .mysql => "MySQL",
        .unknown => "this dialect",
    };
}

/// Dialect-aware epoch default for the conventional audit timestamp columns
/// (`created_at` / `updated_at` of logical type `.time`), matching zent's
/// i64-epoch representation (CURRENT_TIMESTAMP would store text and break
/// integer scanning). Returns null when the column has an explicit default
/// or is not an audit column.
pub fn auditTimestampDefault(column: ColumnDef, dialect: Dialect) ?[]const u8 {
    if (column.default_value != null) return null;
    if (column.logical_type == null or column.logical_type.? != .time) return null;
    if (!std.mem.eql(u8, column.name, "created_at") and !std.mem.eql(u8, column.name, "updated_at")) return null;
    // The spelling lives in `sql/dialect_expr.zig`; this form is the same
    // expression with the parentheses a DDL `DEFAULT` needs.
    return dialect_expr.nowSecsParenthesized(dialect);
}

/// Normalize a SQL type name for dialect-agnostic comparison by:
/// - Lowercasing
/// - Stripping size/precision modifiers: `varchar(255)` → `varchar`
/// - Canonicalizing aliases: `character varying` → `varchar`, `int` → `integer`
/// - Trimming whitespace
/// - On MySQL, mapping the server's storage names back onto the declared
///   family (see `server_canonical` below)
pub fn normalizeSqlType(sql_type: []const u8, buf: []u8, dialect: Dialect) ![]u8 {
    if (sql_type.len > buf.len) return error.NoSpaceLeft;

    // Lowercase and copy to buf
    for (sql_type, 0..) |c, i| buf[i] = std.ascii.toLower(c);

    // Strip parenthesized modifiers: e.g., "varchar(255)" → "varchar"
    var end = sql_type.len;
    if (std.mem.indexOfScalar(u8, buf[0..end], '(')) |paren_idx| {
        end = paren_idx;
        while (end > 0 and buf[end - 1] == ' ') end -= 1; // trim trailing space
    }

    const normalized = buf[0..end];

    // Canonicalize aliases — copy canonical name into buffer and return
    const canonical: ?[]const u8 = if (std.mem.eql(u8, normalized, "character varying")) "varchar" else if (std.mem.eql(u8, normalized, "int") or std.mem.eql(u8, normalized, "int4")) "integer" else if (std.mem.eql(u8, normalized, "double")) "double precision" else if (std.mem.eql(u8, normalized, "bool")) "boolean" else if (std.mem.eql(u8, normalized, "serial")) "integer" else if (std.mem.eql(u8, normalized, "bigserial")) "bigint" else if (std.mem.eql(u8, normalized, "timestamptz")) "timestamp with time zone" else null;

    // MySQL answers `information_schema.columns.data_type` with the **storage
    // type**, not the spelling the DDL used: BOOLEAN lands as `tinyint` (a
    // `tinyint(1)`) and REAL as `double` (REAL is a DOUBLE synonym there;
    // MariaDB behaves the same). zent emits both spellings dialect-independently
    // (`field.sqlType`), so without mapping the server's answer back every MySQL
    // table carrying a bool or a float reported a false `.type_mismatch` — and a
    // run with `allow_data_loss` then planned an ALTER TYPE to "repair" it,
    // which `alterColumnTypeSQL` refuses with `MySQLTypeChangeUnsafe`: planning
    // failed hard, dry-run included, and the version was never recorded.
    // Deliberately only these two, and gated on the dialect so PostgreSQL and
    // SQLite normalize exactly as before: `tinyint` cannot collide with a real
    // difference (zent's `.int` is emitted INTEGER and MySQL stores it as `int`,
    // normalized to `integer` — a genuine `tinyint` column is still not an
    // `.int`), and MySQL FLOAT keeps reporting `float`, distinct from the DOUBLE
    // family REAL belongs to.
    const server_canonical: ?[]const u8 = if (dialect.kind() != .mysql) null else if (std.mem.eql(u8, normalized, "tinyint")) "boolean" else if (std.mem.eql(u8, normalized, "real")) "double precision" else null;

    if (server_canonical orelse canonical) |canon| {
        if (canon.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[0..canon.len], canon);
        return buf[0..canon.len];
    }

    return normalized;
}

/// Foreign key definition.
pub const ForeignKeyDef = struct {
    columns: []const []const u8,
    ref_table: []const u8,
    ref_columns: []const []const u8,
    on_delete: []const u8 = "CASCADE",
    on_update: []const u8 = "CASCADE",
};

/// Index definition.
pub const IndexDef = struct {
    name: []const u8,
    columns: []const []const u8,
    unique: bool = false,
    /// Access method (`USING <method>`), `null` when the schema declared none.
    ///
    /// **Not compared by `checkSchema`.** It could be — PostgreSQL's
    /// `getPostgresIndexes` already joins `pg_am` (it uses `am.amname` to decide
    /// whether the key list is comparable at all), and MySQL carries
    /// `information_schema.statistics.INDEX_TYPE` — but a mismatch is a
    /// performance fact, and every drift reported here is one `assertSchema`
    /// turns into a blocked deploy. The comparison would also have to answer
    /// "equivalent?" rather than "equal?" for a great many pairs (a `btree`
    /// index and an undeclared method are the same thing; so are `USING BTREE`
    /// and the default on MySQL), and a wrong answer on either side is worse
    /// than no answer. So the method is written and never read: declaring it is
    /// free of drift risk, and changing it on an index that already exists by
    /// name is not repaired (an existing index is never re-created).
    method: ?[]const u8 = null,
    /// Operator class for the index's single key column (`"vector_cosine_ops"`,
    /// …). PostgreSQL only; see `createIndexSQLAlloc` for what the other two
    /// dialects do with a declaration they cannot express. Like `method`, it is
    /// never compared by `checkSchema`.
    opclass: ?[]const u8 = null,
};

/// Table definition for CREATE TABLE.
pub const TableDef = struct {
    name: []const u8,
    columns: []const ColumnDef,
    primary_keys: []const []const u8,
    foreign_keys: []const ForeignKeyDef = &.{},
    indexes: []const IndexDef = &.{},
};

pub fn isSQLiteDialect(dialect: Dialect) bool {
    return dialect.kind() == .sqlite;
}

/// A declared PostgreSQL type split into the name its element/own type is
/// compared under, and whether the declaration is an array of it.
pub const DeclaredPgType = struct {
    name: []const u8,
    is_array: bool,
};

/// Split a declared PostgreSQL type: drop every `[]` suffix and any `schema.`
/// qualifier, and report whether the declaration was an array.
///
/// Every `[]` goes, not just one: PostgreSQL's catalog reports `integer[][]`
/// and `integer[]` identically (`ARRAY` + `_int4`) — the dimensionality is not
/// in `information_schema.columns` at all — so refusing the multi-dimensional
/// spelling would be a drift report for a difference the server cannot express.
/// The qualifier goes because `udt_name` is the bare `pg_type.typname` with no
/// schema in it: a `public.vector(1536)` declaration has to compare equal to
/// the `vector` the catalog answers, and `udt_schema` (which would tell them
/// apart) is deliberately not read.
pub fn declaredPgType(schema_type: []const u8) DeclaredPgType {
    var name = std.mem.trim(u8, schema_type, " ");
    var is_array = false;
    while (std.mem.endsWith(u8, name, "[]")) {
        name = std.mem.trimEnd(u8, name[0 .. name.len - 2], " ");
        is_array = true;
    }
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name = name[dot + 1 ..];
    return .{ .name = name, .is_array = is_array };
}

/// `normalizeSqlType` into a caller-provided stack buffer, falling back to the
/// heap when the declared type does not fit. The dialect rides along because
/// the comparison is not spelling-identity on every server: MySQL reports its
/// storage types under different names (see `normalizeSqlType`).
///
/// The fallback is the point. This comparison used to read
/// `normalizeSqlType(...) catch null` with a 128-byte stack buffer, so a type
/// longer than that — a hand-written `sql_type`, a `longtext CHARACTER SET …
/// COLLATE …`, an `ENUM` dump — made the whole comparison **disappear**, and
/// "no `type_mismatch` reported" is indistinguishable from "the types agree".
/// That is the one outcome a drift check must never fake, so a type that does
/// not fit is normalized on the heap rather than skipped.
pub fn normalizeTypeForCompare(
    allocator: std.mem.Allocator,
    sql_type: []const u8,
    stack_buf: *[128]u8,
    dialect: Dialect,
) error{OutOfMemory}!NormalizedType {
    if (normalizeSqlType(sql_type, stack_buf, dialect)) |norm| {
        return .{ .text = norm, .owned = null };
    } else |err| switch (err) {
        error.NoSpaceLeft => {},
    }

    const heap = try allocator.alloc(u8, sql_type.len);
    if (normalizeSqlType(sql_type, heap, dialect)) |norm| {
        return .{ .text = norm, .owned = heap };
    } else |_| {
        allocator.free(heap);
        return error.OutOfMemory;
    }
}

/// `udt_name`'s spellings for the built-in types that have one, mapped onto
/// `information_schema`'s — `_float8` is a `double precision[]` column, so its
/// element is compared as `double precision`, and `_int2` as `smallint`.
///
/// The shared alias table (`normalizeSqlType`) already carries `int4` →
/// `integer`; this is the rest of the family. It is consulted from the
/// `USER-DEFINED`/`ARRAY` branch only, so the built-in comparison keeps its
/// exact behaviour, and every entry maps two spellings of *one* PostgreSQL
/// type — it can turn a false drift into a match, never a difference into one.
/// (`_bpchar` is `character`, whose element name would otherwise not match.)
pub fn pgInternalSpelling(name: []const u8) []const u8 {
    const aliases = [_]struct { udt: []const u8, info_schema: []const u8 }{
        .{ .udt = "int2", .info_schema = "smallint" },
        .{ .udt = "int8", .info_schema = "bigint" },
        .{ .udt = "float4", .info_schema = "real" },
        .{ .udt = "float8", .info_schema = "double precision" },
        .{ .udt = "bpchar", .info_schema = "character" },
    };
    for (aliases) |alias| {
        if (std.ascii.eqlIgnoreCase(name, alias.udt)) return alias.info_schema;
    }
    return name;
}

pub const NormalizedType = struct {
    text: []const u8,
    /// Set when `text` came from the heap and the caller must free it.
    owned: ?[]u8,

    pub fn deinit(self: NormalizedType, allocator: std.mem.Allocator) void {
        if (self.owned) |buf| allocator.free(buf);
    }
};

/// The element type behind an `ARRAY` column's `udt_name`: PostgreSQL names
/// every array type after its element with a leading `_` (`_int4`, `_citext`).
/// A name without the prefix is returned as it is.
pub fn pgUdtBaseName(udt_name: []const u8, is_array: bool) []const u8 {
    if (is_array and udt_name.len > 1 and udt_name[0] == '_') return udt_name[1..];
    return udt_name;
}
