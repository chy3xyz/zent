const std = @import("std");
const dialect_mod = @import("../sql/dialect.zig");

/// Field type category.
pub const FieldType = enum {
    bool,
    int,
    float,
    string,
    text,
    bytes,
    time,
    json,
    enum_,
    uuid,
    /// Exact fixed-point money/decimal values. Scanned as owned text
    /// (`[]const u8`) — never silently truncated to f64.
    decimal,
    /// A fixed-dimension vector (`field.Vector`), the `vector(n)` type the
    /// pgvector extension provides. Zig type `[]const f32`; see `Vector`.
    vector,
    other,
};

/// Default value container for comptime.
pub const DefaultValue = union(enum) {
    none,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
};

/// Validator kind.
pub const Validator = union(enum) {
    positive,
    range: struct { min: i64, max: i64 },
    match: []const u8,
    custom: []const u8,
    not_empty,
    length: struct { min: usize, max: usize },
    email,
    phone,
};

/// Field descriptor used at comptime.
pub const Field = struct {
    name: []const u8,
    field_type: FieldType,
    zig_type: ?type = null,
    optional: bool = false,
    nillable: bool = false,
    unique: bool = false,
    immutable: bool = false,
    is_version: bool = false,
    default: DefaultValue = .none,
    validators: []const Validator = &.{},
    enum_values: []const []const u8 = &.{},
    json_schema: ?type = null,
    sensitive: bool = false,
    /// Explicit SQL column name. When null the column name equals `name`.
    /// Set it to map a Zig field onto a differently-named column in an
    /// existing table (ent's `StorageKey`).
    storage_key: ?[]const u8 = null,
    /// Declared maximum string length (`VarChar(n)`). Only ever non-null on
    /// a `.string` field — the modifier refuses every other type. Drives the
    /// MySQL column width (`VARCHAR(n)` instead of `VARCHAR(255)`, see
    /// `sqlTypeMax`) and the write-path ceiling (`validateSqlValue`); a
    /// field that does not declare a length keeps today's behaviour
    /// byte-for-byte on every dialect.
    max_length: ?usize = null,
    /// Explicit SQL type for the column, overriding the dialect mapping — set
    /// by `.SqlType(s)` on any field kind, and by `Other(name, s)`.
    ///
    /// It is applied on **PostgreSQL only**: the strings it names are the
    /// extension and custom types a PostgreSQL schema declares (`vector(1536)`,
    /// `citext`, `inet`, `tsvector`, `integer[]`) and there is no way to check
    /// one spelling against the other servers — emitting it verbatim on MySQL
    /// or SQLite would hand them a type they cannot parse. Every other dialect
    /// falls back to the field kind's own mapping (`Other` → `TEXT`).
    ///
    /// Priority, where the override applies: an explicit `.SqlType` **wins**
    /// over `VarChar(n)` — the two answer the same question and the explicit one
    /// is the later, narrower statement (`field.String("s").VarChar(10).SqlType("citext")`
    /// emits `citext`, not `VARCHAR(10)`). On MySQL and SQLite the `VarChar(n)`
    /// width is what remains, since the override is not emitted there at all.
    /// It is also what `checkSchema` compares against: `integer[]` matches the
    /// `ARRAY`/`_int4` column PostgreSQL reports, and nothing else does.
    sql_type: ?[]const u8 = null,
    /// The declared dimension of a `field.Vector` column. Only ever non-null on
    /// a `.vector` field — `Vector` refuses a zero and every other constructor
    /// leaves it null. Drives the PostgreSQL DDL (`vector(n)`) and the write
    /// path's element-count check; see `Vector`.
    vector_dims: ?usize = null,

    // Builder methods
    /// Map this field onto a differently-named SQL column. User-facing APIs
    /// keep using the Zig field `name`; only SQL generation uses `key`.
    pub fn StorageKey(self: Field, key: []const u8) Field {
        var f = self;
        f.storage_key = key;
        return f;
    }

    pub fn Optional(self: Field) Field {
        var f = self;
        f.optional = true;
        return f;
    }

    /// A nullable column **and** a nullable Zig field — the same thing as
    /// `Optional()`, plus the flag ent uses.
    ///
    /// `nillable` alone used to leave the generated field non-optional while the
    /// DDL made the column nullable, so a NULL in that column failed to scan
    /// with `error.TypeMismatch` and `setFieldValue("x", null)` did not compile.
    /// Ten places decide nullability, and only some of them looked at
    /// `nillable`; setting both flags fixes all of them at once and cannot make
    /// an existing column NOT NULL (`not_null = !optional and !nillable` is
    /// unchanged). Aligned with ent, where `Nillable()` implies `Optional()`.
    pub fn Nillable(self: Field) Field {
        var f = self;
        f.nillable = true;
        f.optional = true;
        return f;
    }

    pub fn Unique(self: Field) Field {
        var f = self;
        f.unique = true;
        return f;
    }

    pub fn Immutable(self: Field) Field {
        var f = self;
        f.immutable = true;
        return f;
    }

    pub fn Sensitive(self: Field) Field {
        var f = self;
        f.sensitive = true;
        return f;
    }

    pub fn Default(self: Field, comptime val: anytype) Field {
        var f = self;
        const T = @TypeOf(val);
        switch (@typeInfo(T)) {
            .bool => f.default = .{ .bool = val },
            .int => f.default = .{ .int = val },
            .float => f.default = .{ .float = val },
            .comptime_int => f.default = .{ .int = val },
            .comptime_float => f.default = .{ .float = val },
            else => {
                const info = @typeInfo(T);
                if (T == []const u8) {
                    f.default = .{ .string = val };
                } else if (info == .pointer and info.pointer.size == .one) {
                    const child_info = @typeInfo(info.pointer.child);
                    if (child_info == .array and child_info.array.child == u8) {
                        f.default = .{ .string = val };
                    } else {
                        @compileError("Unsupported default value type: " ++ @typeName(T));
                    }
                } else {
                    @compileError("Unsupported default value type: " ++ @typeName(T));
                }
            },
        }
        return f;
    }

    pub fn Positive(self: Field) Field {
        var f = self;
        f.validators = f.validators ++ &[_]Validator{.positive};
        return f;
    }

    pub fn Range(self: Field, comptime min: i64, comptime max: i64) Field {
        var f = self;
        const v = Validator{ .range = .{ .min = min, .max = max } };
        f.validators = f.validators ++ &[_]Validator{v};
        return f;
    }

    pub fn Match(self: Field, comptime pattern: []const u8) Field {
        var f = self;
        const v = Validator{ .match = pattern };
        f.validators = f.validators ++ &[_]Validator{v};
        return f;
    }

    /// Wildcard validation (`*` any sequence, `?` one char).
    pub fn Custom(self: Field, comptime pattern: []const u8) Field {
        var f = self;
        const v = Validator{ .custom = pattern };
        f.validators = f.validators ++ &[_]Validator{v};
        return f;
    }

    /// Reject empty strings.
    pub fn NotEmpty(self: Field) Field {
        var f = self;
        f.validators = f.validators ++ &[_]Validator{.not_empty};
        return f;
    }

    /// Constrain string length (inclusive).
    pub fn Length(self: Field, comptime min: usize, comptime max: usize) Field {
        var f = self;
        const v: Validator = .{ .length = .{ .min = min, .max = max } };
        f.validators = f.validators ++ &[_]Validator{v};
        return f;
    }

    /// Lightweight email format check.
    pub fn Email(self: Field) Field {
        var f = self;
        f.validators = f.validators ++ &[_]Validator{.email};
        return f;
    }

    /// Lightweight phone check: optional leading +, digits only, 7-15 chars.
    pub fn Phone(self: Field) Field {
        var f = self;
        f.validators = f.validators ++ &[_]Validator{.phone};
        return f;
    }

    /// Declare a maximum length for the column's string values. On MySQL the
    /// column becomes `VARCHAR(n)` instead of the default `VARCHAR(255)`;
    /// PostgreSQL and SQLite keep `TEXT` — the dialect split `.string`
    /// already has, unchanged. The write path rejects a value longer than
    /// `n` with `error.ValidationFailed`, so an over-long string fails as a
    /// named error before the server can (strict mode rejects it outright,
    /// permissive mode silently truncates it).
    ///
    /// Compile-time checked: valid only on `field.String` fields.
    /// `field.Text` is deliberately the unbounded type (see `sqlType`) and
    /// `field.Enum` has a fixed value set, so neither takes a length; a
    /// negative `n` cannot type-check against `usize`.
    pub fn VarChar(self: Field, comptime n: usize) Field {
        if (n == 0) @compileError("VarChar(n) requires n > 0 — a zero-length column could hold no value at all");
        if (self.field_type != .string) @compileError("VarChar(n) is only valid on field.String fields: field.Text is deliberately unbounded and field.Enum has a fixed value set");
        var f = self;
        f.max_length = n;
        return f;
    }

    /// Declare the column's SQL type explicitly, bypassing the dialect mapping.
    ///
    /// For the PostgreSQL types zent has no field kind for — extension types
    /// (`vector(1536)`, `citext`), the built-in network/range/full-text types
    /// (`inet`, `cidr`, `macaddr`, `tsvector`, `jsonpath`, `interval`,
    /// `int4range`) and arrays (`integer[]`). `checkSchema` compares the
    /// declared string against what the catalog reports for such a column
    /// (`USER-DEFINED` + `udt_name`, `ARRAY` + `_int4`), so the declaration is
    /// what makes a drift check pass — and only for a column that really is that
    /// type.
    ///
    /// The value is emitted **verbatim** and on PostgreSQL only (see
    /// `Field.sql_type`): MySQL and SQLite keep the mapping for the field kind,
    /// so a schema declaring `vector(1536)` still migrates on them — it gets a
    /// `TEXT` column, and `checkSchema` agrees with it there.
    ///
    /// The Zig type is unchanged: a `.text` field stays a string, and
    /// `field.Other` is `[]const u8` on every dialect, so the write path is the
    /// declaration's business (a `vector` value is sent as its text form).
    /// Compile-time checked: the type name cannot be empty.
    pub fn SqlType(self: Field, comptime s: []const u8) Field {
        if (s.len == 0) @compileError("SqlType requires a non-empty type name — omit the modifier to keep the dialect mapping");
        var f = self;
        f.sql_type = s;
        return f;
    }
};

// Field constructors

pub fn Bool(name: []const u8) Field {
    return .{ .name = name, .field_type = .bool };
}

pub fn Int(name: []const u8) Field {
    return .{ .name = name, .field_type = .int };
}

pub fn Float(name: []const u8) Field {
    return .{ .name = name, .field_type = .float };
}

pub fn String(name: []const u8) Field {
    return .{ .name = name, .field_type = .string };
}

pub fn Text(name: []const u8) Field {
    return .{ .name = name, .field_type = .text };
}

pub fn Bytes(name: []const u8) Field {
    return .{ .name = name, .field_type = .bytes };
}

pub fn Time(name: []const u8) Field {
    return .{ .name = name, .field_type = .time };
}

pub fn JSON(name: []const u8, comptime T: type) Field {
    return .{ .name = name, .field_type = .json, .zig_type = T };
}

/// JSON field with an untyped document value (`std.json.Value`) — for
/// dynamic-shape data (product specs, config blobs) where a fixed struct
/// type is unknown at schema time. The parsed value lives in the entity's
/// json_arena and is freed by deinitEntity, same as typed JSON fields.
pub fn JSONValue(name: []const u8) Field {
    return JSON(name, std.json.Value);
}

pub fn Enum(name: []const u8, comptime values: []const []const u8) Field {
    return .{ .name = name, .field_type = .enum_, .enum_values = values };
}

pub fn UUID(name: []const u8) Field {
    return .{ .name = name, .field_type = .uuid };
}

/// Exact decimal/money column. The Zig type is `[]const u8` (owned text):
/// MySQL `DECIMAL` and PG `NUMERIC` both arrive as text on the wire, so the
/// value is preserved byte-for-byte — no f64 rounding, no silent truncation.
/// Parse to cents/fixed-point in application code when arithmetic is needed.
pub fn Decimal(name: []const u8) Field {
    return .{ .name = name, .field_type = .decimal };
}

pub fn Version(name: []const u8) Field {
    var f = Int(name);
    f.is_version = true;
    f.default = .{ .int = 0 };
    return f;
}

/// A column whose SQL type is declared explicitly — PostgreSQL's extension and
/// custom types, and its arrays.
///
/// ```zig
/// field.Other("embedding", "vector(1536)")
/// field.Other("tags", "integer[]")
/// field.Other("addr", "inet")
/// ```
///
/// The Zig type is `[]const u8` (the value travels as its text form, as
/// `field.Text` does) and the declared string is emitted as the column type on
/// PostgreSQL — which is what `checkSchema` compares the catalog's
/// `USER-DEFINED`/`ARRAY` answer against. Passing `null` is the same as
/// `field.Text(name)`: no override, `TEXT` everywhere.
///
/// Equivalent to `field.Text(name).SqlType(s)` for the DDL, but it also records
/// `.other` as the logical type, so a field with no natural kind among
/// `Int`/`String`/`UUID`/… is not described as text. Prefer this constructor.
/// Compile-time checked: the type name cannot be empty.
pub fn Other(name: []const u8, comptime sql_type: ?[]const u8) Field {
    if (sql_type) |s| {
        if (s.len == 0) @compileError("Other requires a non-empty type name, or null for no override — an empty string would emit a nameless column type");
    }
    return .{ .name = name, .field_type = .other, .sql_type = sql_type };
}

/// A fixed-dimension vector, first-class: PostgreSQL emits pgvector's
/// `vector(n)`, MySQL and SQLite emit `TEXT` (see `sqlType`), and the Zig type
/// is an owned `[]const f32` that `deinitEntity` releases.
///
/// ```zig
/// field.Vector("embedding", 1536)
/// ```
///
/// The value travels in pgvector's **text form** — `[1,2,3]`, the same string
/// `vector_out` prints and `vector_in` accepts — which is what makes one Zig
/// type work on all three dialects: MySQL and SQLite have no native vector
/// type, so the text form is the storage there, and on PostgreSQL it is the
/// parameter/result spelling the driver already carries. Distance operators
/// (`<->`, `<=>`, `<#>`) and the `ivfflat`/`hnsw` index types are pgvector's
/// own and remain raw SQL; zent stores and returns the vector.
///
/// Elements are formatted with `{d}`, the shortest decimal that round-trips
/// through `f32`. pgvector's own element type is `float4`, so an `f32` value
/// survives the round trip exactly: the same 4 bytes go out and come back, and
/// there is no widening to `f64` anywhere on the path. `f64` inputs are not
/// accepted — cast at the call site, where the precision loss is visible.
///
/// The write path (`setFieldValue`) rejects a value whose element count is not
/// `dims` with `error.ValidationFailed`, before the server can answer
/// `expected n dimensions, not m`.
///
/// `dims` is checked at comptime: a zero-dimension vector is not a value
/// pgvector can hold.
pub fn Vector(name: []const u8, comptime dims: usize) Field {
    if (dims == 0) @compileError("Vector(name, dims) requires dims > 0 — pgvector rejects a zero-dimension vector outright, so the column could never hold a legal value");
    return .{ .name = name, .field_type = .vector, .vector_dims = dims };
}

// ------------------------------------------------------------------
// SQL type mapping
// ------------------------------------------------------------------

pub const Dialect = dialect_mod.Dialect;

pub fn sqlType(comptime field_type: FieldType, dialect: Dialect) []const u8 {
    switch (field_type) {
        .bool => return "BOOLEAN",
        .int => return "INTEGER",
        .float => return "REAL",
        .string => {
            // MySQL refuses the three things a primary string column is
            // normally asked to do when that column is TEXT: it cannot be
            // indexed or UNIQUE without a key length (errno 1170), and it
            // cannot carry a DEFAULT (errno 1101). VARCHAR(255) — the same
            // length ent uses — has none of those restrictions. A prefix index
            // (`name(255)`) is not the fix: for UNIQUE it would silently
            // constrain only the first 255 characters.
            if (dialect.kind() == .mysql) return "VARCHAR(255)";
            return "TEXT";
        },
        .text => return "TEXT",
        .bytes => {
            if (dialect.kind() == .postgres) return "BYTEA";
            return "BLOB";
        },
        .time => {
            // Epoch-second integer everywhere: the application layer reads and
            // writes i64 epochs (zigType(.time) == i64) and the audit default
            // is EXTRACT(EPOCH FROM now()) — mapping this to TIMESTAMPTZ
            // (PG) / DATETIME (MySQL) made the column type disagree with the
            // bigint default expression, breaking CREATE TABLE on Postgres.
            return "BIGINT";
        },
        .json => {
            if (dialect.kind() == .postgres) return "JSONB";
            return "TEXT";
        },
        .enum_ => {
            // Same MySQL BLOB/TEXT restrictions as `.string` (errno 1170 for
            // indexes and UNIQUE, errno 1101 for DEFAULT). The value set is
            // fixed and finite, so VARCHAR(255) is the right width; MySQL's
            // native ENUM(...) would put the value list into the DDL and its
            // semantics differ between MySQL and MariaDB.
            if (dialect.kind() == .mysql) return "VARCHAR(255)";
            return "TEXT";
        },
        .uuid => {
            if (dialect.kind() == .postgres) return "UUID";
            // MySQL cannot index TEXT without a key length, so a UUID primary
            // key would fail CREATE TABLE (errno 1170). CHAR(36) holds the
            // canonical 8-4-4-4-12 form and is indexable.
            if (dialect.kind() == .mysql) return "CHAR(36)";
            return "TEXT";
        },
        .decimal => {
            if (dialect.kind() == .postgres) return "NUMERIC";
            // MySQL DECIMAL without precision defaults to (10,0) and would
            // truncate fractional cents — pin an explicit precision instead.
            if (dialect.kind() == .mysql) return "DECIMAL(38,10)";
            // SQLite TEXT affinity keeps the literal bytes exact; NUMERIC
            // affinity would silently rewrite "1.10" to the REAL 1.1.
            return "TEXT";
        },
        .vector => {
            // A vector column's PostgreSQL type carries its dimension
            // (`vector(1536)`), which this dimension-less entry point cannot
            // spell — `sqlTypeResolved` has the declaration in hand and is what
            // every caller holding a `Field`/`FieldInfo` uses. Reaching here
            // means a hand-built descriptor that declared no dimension; `TEXT`
            // is the same column MySQL and SQLite get. MySQL (8/9, and the
            // MariaDB CI runs) and SQLite have no vector type at all, and
            // pgvector's distance operators are PostgreSQL-only, so the text
            // form is the storage there rather than a lossy fallback.
            return "TEXT";
        },
        .other => return "TEXT",
    }
}

/// The DDL spelling of a declared `VarChar(n)` limit. A comptime helper
/// because the string is needed where nothing can format into it:
/// `FieldInfo.sql_type` and `migrate.zig`'s `columnSQLType` (a runtime fn
/// whose return value is borrowed, so it has no allocator to print into).
pub fn varCharSQL(comptime n: usize) []const u8 {
    return "VARCHAR(" ++ std.fmt.comptimePrint("{d}", .{n}) ++ ")";
}

/// `sqlType`, length-aware. A `.string` field that declared `VarChar(n)`
/// emits `VARCHAR(n)` on MySQL instead of the default `VARCHAR(255)`;
/// every other combination — the undeclared default included — resolves
/// through `sqlType` byte-for-byte unchanged (PostgreSQL and SQLite keep
/// `TEXT`, the dialect split `.string` already had).
pub fn sqlTypeMax(comptime field_type: FieldType, comptime max_length: ?usize, dialect: Dialect) []const u8 {
    if (max_length) |n| {
        if (field_type == .string and dialect.kind() == .mysql) return varCharSQL(n);
    }
    return sqlType(field_type, dialect);
}

/// `sqlTypeMax`, plus the explicit `.SqlType(s)` / `field.Other(name, s)`
/// override — the spelling of a column that declared its own type.
///
/// The override applies on PostgreSQL only and wins over `VarChar(n)`; every
/// other dialect resolves through `sqlTypeMax` byte-for-byte unchanged, which
/// is what keeps a `field.Other("x", "vector(1536)")` schema migratable on
/// MySQL and SQLite (it gets the kind's own mapping, `TEXT`).
///
/// `sqlType` itself cannot carry the override — it takes a type and a dialect
/// only — so the resolution lives here, next to `sqlTypeMax`'s, and the callers
/// that *do* have a `Field`/`FieldInfo` in hand (`graph.toFieldInfoDialect`,
/// `migrate.columnSQLType`) use this one.
pub fn sqlTypeOverride(
    comptime field_type: FieldType,
    comptime max_length: ?usize,
    comptime sql_type_override: ?[]const u8,
    dialect: Dialect,
) []const u8 {
    return sqlTypeResolved(field_type, max_length, null, sql_type_override, dialect);
}

/// `sqlTypeOverride`, plus a `field.Vector`'s declared dimension — the whole
/// declaration resolved to one column type, in the priority order the two
/// modifiers established:
///
/// 1. an explicit `.SqlType(s)` / `field.Other(name, s)`, on PostgreSQL;
/// 2. a `field.Vector`'s `vector(n)`, on PostgreSQL — the dimension-less entry
///    points cannot spell it, so it is resolved here;
/// 3. `VarChar(n)` on MySQL;
/// 4. the field kind's own mapping.
///
/// Everything except a declared vector resolves byte-for-byte through
/// `sqlTypeOverride`, which is why the callers that have no dimension keep
/// using that one.
pub fn sqlTypeResolved(
    comptime field_type: FieldType,
    comptime max_length: ?usize,
    comptime vector_dims: ?usize,
    comptime sql_type_override: ?[]const u8,
    dialect: Dialect,
) []const u8 {
    if (sql_type_override) |s| {
        if (dialect.kind() == .postgres) return s;
    }
    if (field_type == .vector) {
        if (dialect.kind() == .postgres) {
            if (vector_dims) |dims| return vectorSQL(dims);
        }
        // MySQL and SQLite: the text form, in a column of the same affinity a
        // `.text` field gets. Not a lossy fallback — `[1,2,3]` is exactly what
        // pgvector's own text form is, and what a consumer migrating a schema
        // between engines carries.
        return "TEXT";
    }
    return sqlTypeMax(field_type, max_length, dialect);
}

/// The DDL spelling of a declared `field.Vector` dimension: `vector(1536)`.
/// Comptime for the same reason `varCharSQL` is — `migrate.zig`'s
/// `columnSQLType` is a runtime fn returning a borrowed slice it cannot print
/// into, so the dimension travels into the migration as a string.
pub fn vectorSQL(comptime dims: usize) []const u8 {
    if (dims == 0) @compileError("vectorSQL(0) is not a type pgvector has: a zero-dimension vector cannot be created or stored");
    return "vector(" ++ std.fmt.comptimePrint("{d}", .{dims}) ++ ")";
}

/// Map a FieldType to a Zig type for generated code.
pub fn zigType(comptime field_type: FieldType, comptime custom_type: ?type) type {
    switch (field_type) {
        .bool => return bool,
        .int => return i64,
        .float => return f64,
        .string, .text, .enum_, .uuid, .decimal, .other => return []const u8,
        .bytes => return []const u8,
        // An owned slice: the scan parses the column's text form into
        // `allocator`-owned memory and `deinitEntity` releases it (see the
        // memory-ownership contract). `f32`, not `f64` — pgvector stores
        // `float4`, so the Zig type names exactly what survives the round trip.
        .vector => return custom_type orelse []const f32,
        .time => return i64, // timestamp as epoch for simplicity
        .json => return custom_type orelse []const u8,
    }
}

// ------------------------------------------------------------------
// Vector codec — pgvector's text form, in one place
// ------------------------------------------------------------------
//
// Both directions of the `[]const f32` <-> `[1,2,3]` conversion live here as
// pure functions, so they can be pinned without a server: the write path
// (`codegen.field_value.vectorTextAlloc`) and the read path
// (`sql.scan.scanColumn`) both call them, and neither re-implements the
// grammar. The text form is pgvector's own: `vector_out` prints it and
// `vector_in` parses it, so a value written by zent is the value
// `SELECT embedding <-> '[...]'` compares.

/// A vector's text form is not a value: a malformed one is a `TypeMismatch`,
/// the same member the scanner already uses for a column it cannot read.
/// Elements are formatted with `{d}` — the shortest decimal that round-trips
/// through `f32`. pgvector's element type is `float4`, so the round trip is
/// exact for every finite `f32`; `inf`/`nan` are printed as `inf`/`nan`, which
/// `strtof` (what `vector_in` parses with) reads back the same way.
pub fn encodeVector(allocator: std.mem.Allocator, values: []const f32) error{OutOfMemory}![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try buf.append('[');
    for (values, 0..) |v, i| {
        if (i > 0) try buf.append(',');
        try buf.print("{d}", .{v});
    }
    try buf.append(']');
    return buf.toOwnedSlice();
}

/// The bracket-enclosed body of a text form, or null when the brackets are
/// missing or the text is too short to hold them.
fn vectorInner(text: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len < 2 or t[0] != '[' or t[t.len - 1] != ']') return null;
    return t[1 .. t.len - 1];
}

/// The element count of pgvector's text form, validated but **not** allocated —
/// the shape a `field.Vector`'s dimension check needs. `null` means the text is
/// not a vector: no brackets, an empty element (a trailing or doubled comma), or
/// an element `f32` cannot parse. `[]` is a well-formed zero-element vector.
pub fn vectorElementCount(text: []const u8) ?usize {
    const inner = vectorInner(text) orelse return null;
    if (std.mem.trim(u8, inner, " \t\r\n").len == 0) return 0;
    var it = std.mem.splitScalar(u8, inner, ',');
    var count: usize = 0;
    while (it.next()) |raw| {
        const token = std.mem.trim(u8, raw, " \t\r\n");
        if (token.len == 0) return null;
        _ = std.fmt.parseFloat(f32, token) catch return null;
        count += 1;
    }
    return count;
}

/// Parse pgvector's text form into owned `[]f32`.
///
/// `expected_dims` is the declared dimension when the caller knows it (the
/// write path does); a count that differs is a `TypeMismatch`, the same error a
/// malformed document gets. The read path passes `null`: the positional scanner
/// dispatches on the Zig type alone (`[]const f32` carries no dimension) and has
/// no schema in hand, so the dimension is a write-path invariant there — see
/// `sql/scan.zig`.
pub fn parseVectorAlloc(allocator: std.mem.Allocator, text: []const u8, expected_dims: ?usize) error{ TypeMismatch, OutOfMemory }![]f32 {
    const inner = vectorInner(text) orelse return error.TypeMismatch;
    const count = vectorElementCount(text) orelse return error.TypeMismatch;
    if (expected_dims) |dims| {
        if (count != dims) return error.TypeMismatch;
    }
    const out = try allocator.alloc(f32, count);
    errdefer allocator.free(out);
    // An empty body (`[]`, or one holding only whitespace) has no element to
    // read — and `splitScalar` would still hand back one empty token for it.
    if (count == 0) return out;
    var it = std.mem.splitScalar(u8, inner, ',');
    var i: usize = 0;
    while (it.next()) |raw| : (i += 1) {
        out[i] = std.fmt.parseFloat(f32, std.mem.trim(u8, raw, " \t\r\n")) catch return error.TypeMismatch;
    }
    return out;
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Field builders" {
    const f = Int("age").Positive().Default(18);
    try std.testing.expectEqualStrings("age", f.name);
    try std.testing.expectEqual(FieldType.int, f.field_type);
    try std.testing.expect(f.default.int == 18);
    try std.testing.expectEqual(@as(usize, 1), f.validators.len);
}

test "SQL type mapping" {
    try std.testing.expectEqualStrings("INTEGER", sqlType(.int, .{ .name = "sqlite3" }));
    try std.testing.expectEqualStrings("TEXT", sqlType(.string, .{ .name = "sqlite3" }));
    // .time maps to BIGINT epoch seconds on every dialect (see the sqlType
    // comment: TIMESTAMPTZ/DATETIME disagreed with the bigint audit default).
    try std.testing.expectEqualStrings("BIGINT", sqlType(.time, .{ .name = "mysql" }));
    try std.testing.expectEqualStrings("BIGINT", sqlType(.time, .{ .name = "postgres" }));
    try std.testing.expectEqualStrings("JSONB", sqlType(.json, .{ .name = "postgres" }));
    try std.testing.expectEqualStrings("UUID", sqlType(.uuid, .{ .name = "postgres" }));
    try std.testing.expectEqualStrings("BLOB", sqlType(.bytes, .{ .name = "sqlite3" }));
    try std.testing.expectEqualStrings("BYTEA", sqlType(.bytes, .{ .name = "postgres" }));
    // Decimal: exact text everywhere; MySQL pins explicit precision so the
    // (10,0) default cannot truncate fractional cents.
    try std.testing.expectEqualStrings("NUMERIC", sqlType(.decimal, .{ .name = "postgres" }));
    try std.testing.expectEqualStrings("DECIMAL(38,10)", sqlType(.decimal, .{ .name = "mysql" }));
    try std.testing.expectEqualStrings("TEXT", sqlType(.decimal, .{ .name = "sqlite3" }));
    try std.testing.expectEqual([]const u8, zigType(.decimal, null));
}

test "SQL type mapping: String/Enum are VARCHAR on MySQL, TEXT elsewhere" {
    const mysql = Dialect{ .name = "mysql" };
    const postgres = Dialect{ .name = "postgres" };
    const sqlite = Dialect{ .name = "sqlite3" };

    // MySQL rejects a TEXT column that is indexed/UNIQUE (errno 1170) or
    // defaulted (errno 1101), so the indexable primary string type is VARCHAR.
    try std.testing.expectEqualStrings("VARCHAR(255)", sqlType(.string, mysql));
    try std.testing.expectEqualStrings("VARCHAR(255)", sqlType(.enum_, mysql));

    // PostgreSQL and SQLite keep TEXT — this change is MySQL-only.
    try std.testing.expectEqualStrings("TEXT", sqlType(.string, postgres));
    try std.testing.expectEqualStrings("TEXT", sqlType(.string, sqlite));
    try std.testing.expectEqualStrings("TEXT", sqlType(.enum_, postgres));
    try std.testing.expectEqualStrings("TEXT", sqlType(.enum_, sqlite));

    // `.text` stays unbounded TEXT even on MySQL: the DEFAULT/UNIQUE
    // restrictions are MySQL's own and apply to an intentionally unbounded
    // column (ent behaves the same way).
    try std.testing.expectEqualStrings("TEXT", sqlType(.text, mysql));
    try std.testing.expectEqualStrings("TEXT", sqlType(.json, mysql));
    try std.testing.expectEqualStrings("TEXT", sqlType(.other, mysql));
}

test "MySQL CREATE TABLE emits an indexable, defaultable unique String column" {
    const migrate = @import("../sql/schema/migrate.zig");

    const table = migrate.TableDef{
        .name = "account",
        .columns = &.{
            .{ .name = "id", .sql_type = "INTEGER", .logical_type = .int, .primary_key = true },
            .{ .name = "email", .sql_type = "TEXT", .logical_type = .string, .not_null = true, .unique = true },
            .{ .name = "status", .sql_type = "TEXT", .logical_type = .enum_, .not_null = true, .default_value = "'new'" },
        },
        .primary_keys = &.{"id"},
    };

    const sql = try migrate.createTableSQL(table, Dialect{ .name = "mysql" });
    defer std.heap.page_allocator.free(sql);

    // UNIQUE and DEFAULT are emitted inline by createTableSQL; both are only
    // legal because the column is VARCHAR rather than TEXT.
    try std.testing.expect(std.mem.indexOf(u8, sql, "`email` VARCHAR(255) NOT NULL UNIQUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "`status` VARCHAR(255) NOT NULL DEFAULT 'new'") != null);

    // A TEXT column would reproduce the two errno failures on this dialect.
    try std.testing.expect(std.mem.indexOf(u8, sql, "TEXT NOT NULL UNIQUE") == null);

    // PostgreSQL is untouched: the same schema still produces TEXT.
    const pg_sql = try migrate.createTableSQL(table, Dialect{ .name = "postgres" });
    defer std.heap.page_allocator.free(pg_sql);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "\"email\" TEXT NOT NULL UNIQUE") != null);
}

test "VarChar: declared width on MySQL, TEXT elsewhere, undeclared unchanged" {
    const mysql = Dialect{ .name = "mysql" };
    const postgres = Dialect{ .name = "postgres" };
    const sqlite = Dialect{ .name = "sqlite3" };

    const bio = comptime String("bio").VarChar(120);
    try std.testing.expectEqual(@as(?usize, 120), bio.max_length);

    // MySQL: the declared width replaces the default VARCHAR(255).
    try std.testing.expectEqualStrings("VARCHAR(120)", sqlTypeMax(.string, bio.max_length, mysql));
    // PG/SQLite keep TEXT — the dialect split is the existing behaviour.
    try std.testing.expectEqualStrings("TEXT", sqlTypeMax(.string, bio.max_length, postgres));
    try std.testing.expectEqualStrings("TEXT", sqlTypeMax(.string, bio.max_length, sqlite));

    // Undeclared: byte-for-byte the old mapping on every dialect.
    try std.testing.expectEqualStrings("VARCHAR(255)", sqlTypeMax(.string, null, mysql));
    try std.testing.expectEqualStrings("TEXT", sqlTypeMax(.string, null, postgres));
    try std.testing.expectEqualStrings("TEXT", sqlTypeMax(.string, null, sqlite));

    // A length never reaches the mapping of a type it cannot be declared on
    // (`VarChar` refuses those at comptime) — belt and braces for hand-built
    // Field/FieldInfo values.
    try std.testing.expectEqualStrings("TEXT", sqlTypeMax(.text, 120, mysql));
    try std.testing.expectEqualStrings("INTEGER", sqlTypeMax(.int, 120, mysql));
    try std.testing.expectEqualStrings("VARCHAR(255)", sqlTypeMax(.enum_, 120, mysql));
}

test "VarChar: MySQL CREATE TABLE emits the declared width, other dialects TEXT" {
    const migrate = @import("../sql/schema/migrate.zig");

    const table = migrate.TableDef{
        .name = "profile",
        .columns = &.{
            .{ .name = "id", .sql_type = "INTEGER", .logical_type = .int, .primary_key = true },
            // Declared: VARCHAR(120) on MySQL, TEXT elsewhere.
            .{ .name = "bio", .sql_type = "TEXT", .logical_type = .string, .varchar_sql = varCharSQL(120) },
            // Undeclared: the default VARCHAR(255) on MySQL, unchanged.
            .{ .name = "nick", .sql_type = "TEXT", .logical_type = .string },
        },
        .primary_keys = &.{"id"},
    };

    const mysql_sql = try migrate.createTableSQL(table, Dialect{ .name = "mysql" });
    defer std.heap.page_allocator.free(mysql_sql);
    try std.testing.expect(std.mem.indexOf(u8, mysql_sql, "`bio` VARCHAR(120)") != null);
    try std.testing.expect(std.mem.indexOf(u8, mysql_sql, "`nick` VARCHAR(255)") != null);

    const pg_sql = try migrate.createTableSQL(table, Dialect{ .name = "postgres" });
    defer std.heap.page_allocator.free(pg_sql);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "\"bio\" TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "VARCHAR") == null);

    const sqlite_sql = try migrate.createTableSQL(table, Dialect{ .name = "sqlite3" });
    defer std.heap.page_allocator.free(sqlite_sql);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_sql, "\"bio\" TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_sql, "VARCHAR") == null);
}

test "Other/SqlType: the declared type is PostgreSQL-only, and wins over VarChar" {
    const mysql = Dialect{ .name = "mysql" };
    const postgres = Dialect{ .name = "postgres" };
    const sqlite = Dialect{ .name = "sqlite3" };

    // The constructors are the declaration; the mapping is what the dialect
    // does with it.
    const emb = comptime Other("embedding", "vector(1536)");
    try std.testing.expectEqual(FieldType.other, emb.field_type);
    try std.testing.expectEqualStrings("vector(1536)", emb.sql_type.?);
    try std.testing.expectEqual([]const u8, zigType(emb.field_type, emb.zig_type));
    // `null` is "no override": the same column `field.Text` declares.
    const plain = comptime Other("body", null);
    try std.testing.expectEqual(FieldType.other, plain.field_type);
    try std.testing.expectEqual(@as(?[]const u8, null), plain.sql_type);

    // PostgreSQL: the declared string, verbatim — `vector(1536)` and an array
    // type alike (the parens and the `[]` are part of the declaration).
    try std.testing.expectEqualStrings("vector(1536)", sqlTypeOverride(.other, null, emb.sql_type, postgres));
    try std.testing.expectEqualStrings("integer[]", sqlTypeOverride(.other, null, "integer[]", postgres));
    try std.testing.expectEqualStrings("citext", sqlTypeOverride(.text, null, Text("t").SqlType("citext").sql_type, postgres));

    // MySQL/SQLite: the field kind's own mapping, unchanged. The override names
    // a PostgreSQL type and there is no way to check one spelling against the
    // other servers — a verbatim `vector(1536)` would fail CREATE TABLE there.
    try std.testing.expectEqualStrings("TEXT", sqlTypeOverride(.other, null, emb.sql_type, mysql));
    try std.testing.expectEqualStrings("TEXT", sqlTypeOverride(.other, null, emb.sql_type, sqlite));
    try std.testing.expectEqualStrings("TEXT", sqlTypeOverride(.text, null, "citext", mysql));
    // ...which is per-kind: the UUID mapping is what an overridden UUID field
    // gets on MySQL, not the override.
    try std.testing.expectEqualStrings("CHAR(36)", sqlTypeOverride(.uuid, null, "uuid", mysql));

    // `.SqlType` beats `VarChar(n)` where the override applies: the two answer
    // the same question and the explicit one is the later statement.
    try std.testing.expectEqualStrings("citext", sqlTypeOverride(.string, 120, "citext", postgres));
    // On MySQL the override is unused, so the declared width is what remains.
    try std.testing.expectEqualStrings("VARCHAR(120)", sqlTypeOverride(.string, 120, "citext", mysql));

    // No override: byte-for-byte `sqlTypeMax`, on every dialect.
    try std.testing.expectEqualStrings(sqlTypeMax(.string, 120, mysql), sqlTypeOverride(.string, 120, null, mysql));
    try std.testing.expectEqualStrings(sqlTypeMax(.string, 120, postgres), sqlTypeOverride(.string, 120, null, postgres));
    try std.testing.expectEqualStrings(sqlTypeMax(.json, null, postgres), sqlTypeOverride(.json, null, null, postgres));
    try std.testing.expectEqualStrings("TEXT", sqlTypeOverride(.other, null, null, postgres));
}

// ------------------------------------------------------------------
// vector: the field kind, its Zig type and its DDL
// ------------------------------------------------------------------

test "Vector: the declared dimension reaches the Zig type and the DDL" {
    const mysql = Dialect{ .name = "mysql" };
    const postgres = Dialect{ .name = "postgres" };
    const sqlite = Dialect{ .name = "sqlite3" };

    const embedding = comptime Vector("embedding", 1536);
    try std.testing.expectEqual(FieldType.vector, embedding.field_type);
    try std.testing.expectEqual(@as(?usize, 1536), embedding.vector_dims);
    // No `.SqlType` declaration of its own: the dimension is the declaration,
    // and leaving the override slot empty is what keeps `.SqlType(s)` able to
    // win over it (see below).
    try std.testing.expectEqual(@as(?[]const u8, null), embedding.sql_type);

    // The Zig type is an owned `[]const f32` — not `[]const u8`, and not
    // `f64`: pgvector's element type is `float4`.
    try std.testing.expectEqual([]const f32, zigType(embedding.field_type, embedding.zig_type));

    // PostgreSQL spells the dimension out; MySQL and SQLite have no vector
    // type, so the text form lands in a TEXT column.
    try std.testing.expectEqualStrings("vector(1536)", sqlTypeResolved(.vector, null, embedding.vector_dims, embedding.sql_type, postgres));
    try std.testing.expectEqualStrings("TEXT", sqlTypeResolved(.vector, null, embedding.vector_dims, embedding.sql_type, mysql));
    try std.testing.expectEqualStrings("TEXT", sqlTypeResolved(.vector, null, embedding.vector_dims, embedding.sql_type, sqlite));
    try std.testing.expectEqualStrings("vector(3)", vectorSQL(3));
    try std.testing.expectEqualStrings("vector(1536)", vectorSQL(1536));

    // The dimension-less entry point cannot spell a dimension; a hand-built
    // descriptor that declared none gets the MySQL/SQLite column everywhere,
    // and the same is true of `sqlTypeMax`'s own fall-through.
    try std.testing.expectEqualStrings("TEXT", sqlType(.vector, postgres));
    try std.testing.expectEqualStrings("TEXT", sqlType(.vector, mysql));
    try std.testing.expectEqualStrings("TEXT", sqlTypeResolved(.vector, null, null, null, postgres));

    // `.SqlType(s)` still wins on PostgreSQL — the override is the later,
    // narrower statement, and a `.vector` field is no exception.
    try std.testing.expectEqualStrings("halfvec(1536)", sqlTypeResolved(.vector, null, embedding.vector_dims, "halfvec(1536)", postgres));
    // On MySQL/SQLite it is not emitted at all, so the vector mapping remains.
    try std.testing.expectEqualStrings("TEXT", sqlTypeResolved(.vector, null, embedding.vector_dims, "halfvec(1536)", mysql));

    // A vector field declares no `VarChar` (the modifier refuses other kinds),
    // so a stray length could not reach here; if one did, the dimension wins
    // on PostgreSQL and the length is not a vector's business on MySQL either.
    try std.testing.expectEqualStrings("vector(3)", sqlTypeResolved(.vector, 10, 3, null, postgres));
    try std.testing.expectEqualStrings("TEXT", sqlTypeResolved(.vector, 10, 3, null, mysql));
}

test "Vector: the CREATE TABLE names a dimension on PostgreSQL, a TEXT column elsewhere" {
    const migrate = @import("../sql/schema/migrate.zig");

    const table = migrate.TableDef{
        .name = "doc",
        .columns = &.{
            .{ .name = "id", .sql_type = "INTEGER", .logical_type = .int, .primary_key = true },
            .{ .name = "embedding", .sql_type = "TEXT", .logical_type = .vector, .not_null = true, .vector_sql = vectorSQL(3) },
            // A declared dimension is required for the PostgreSQL type; a
            // column with none falls back to TEXT rather than emitting a
            // nameless type.
            .{ .name = "loose", .sql_type = "TEXT", .logical_type = .vector },
        },
        .primary_keys = &.{"id"},
    };

    const pg_sql = try migrate.createTableSQL(table, Dialect{ .name = "postgres" });
    defer std.heap.page_allocator.free(pg_sql);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "\"embedding\" vector(3) NOT NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, pg_sql, "\"loose\" TEXT") != null);

    // MySQL and SQLite: the text form, in a TEXT column — the declaration is
    // still emitted nowhere, so `CREATE TABLE` succeeds on both.
    const mysql_sql = try migrate.createTableSQL(table, Dialect{ .name = "mysql" });
    defer std.heap.page_allocator.free(mysql_sql);
    try std.testing.expect(std.mem.indexOf(u8, mysql_sql, "`embedding` TEXT NOT NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, mysql_sql, "vector") == null);

    const sqlite_sql = try migrate.createTableSQL(table, Dialect{ .name = "sqlite3" });
    defer std.heap.page_allocator.free(sqlite_sql);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_sql, "\"embedding\" TEXT NOT NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_sql, "vector") == null);
}

test "Vector: encodeVector and parseVectorAlloc round-trip, and refuse what is not a vector" {
    const a = std.testing.allocator;

    // Round trip: ordinary values, negatives, the formats a `{d}` print and an
    // `f32` parse have to agree on.
    const cases = [_][]const f32{
        &.{1},
        &.{ 1, 2, 3 },
        &.{ 0.0, -0.0, 1.5, -1.5 },
        &.{ -3.25, 1e-7, 1e30, 3.4028235e38 },
        &[_]f32{std.math.floatMin(f32)},
        &[_]f32{std.math.floatMax(f32)},
        &.{},
    };
    for (cases) |case| {
        const text = try encodeVector(a, case);
        defer a.free(text);
        const back = try parseVectorAlloc(a, text, case.len);
        defer a.free(back);
        try std.testing.expectEqualSlices(f32, case, back);
    }

    // The text form itself, so a change to the punctuation is visible.
    {
        const text = try encodeVector(a, &.{ 1, 2.5, -3 });
        defer a.free(text);
        try std.testing.expectEqualStrings("[1,2.5,-3]", text);
        const back = try parseVectorAlloc(a, "[1,2.5,-3]", 3);
        defer a.free(back);
        try std.testing.expectEqualSlices(f32, &.{ 1, 2.5, -3 }, back);
    }
    {
        // pgvector's own output spelling, parsed rather than produced: the two
        // directions must agree with the server, not merely with each other.
        const v = try parseVectorAlloc(a, "[1,2,3]", 3);
        defer a.free(v);
        try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3 }, v);
        // Surrounding whitespace and an exponent form are accepted; the count
        // is what the server would report.
        try std.testing.expectEqual(@as(?usize, 2), vectorElementCount(" [1e2, -3] "));
        try std.testing.expectEqual(@as(?usize, 3), vectorElementCount("[1.5,2,3]"));
        try std.testing.expectEqual(@as(?usize, 0), vectorElementCount("[]"));
        try std.testing.expectEqual(@as(?usize, 0), vectorElementCount(" [ ] "));
    }

    // Malformed: not a vector at all, in every way it can fail to be one.
    const malformed = [_][]const u8{
        "", // empty
        "1,2,3", // no brackets
        "[1,2,3", // unbalanced
        "1,2,3]", // unbalanced
        "[]]", // trailing garbage behind a closed vector
        "[1,2,3]x", // ...and surrounding whitespace is the only slack given
        "[1,2,]", // trailing empty element
        "[,]", // both empty
        "[1,,2]", // doubled comma
        "[1 2]", // no separator
        "[a]", // not a number
        "[1,2", // truncated
        "[[1]]", // nested
        "{}",
    };
    for (malformed) |text| {
        try std.testing.expectEqual(@as(?usize, null), vectorElementCount(text));
        try std.testing.expectError(error.TypeMismatch, parseVectorAlloc(a, text, null));
        try std.testing.expectError(error.TypeMismatch, parseVectorAlloc(a, text, 3));
    }

    // A count that is not the declared dimension is a `TypeMismatch` on the
    // read side (the write side answers `ValidationFailed`, see
    // `codegen/field_value.zig`).
    try std.testing.expectError(error.TypeMismatch, parseVectorAlloc(a, "[1,2]", 3));
    try std.testing.expectError(error.TypeMismatch, parseVectorAlloc(a, "[1,2,3,4]", 3));
    // ...and a null dimension accepts whatever the text holds.
    {
        const v = try parseVectorAlloc(a, "[1,2]", null);
        defer a.free(v);
        try std.testing.expectEqualSlices(f32, &.{ 1, 2 }, v);
    }
    // The allocation failure path releases the partially built slice — the
    // testing allocator is what makes that observable.
    {
        const v = try parseVectorAlloc(a, "[1,2,3]", 3);
        defer a.free(v);
    }
}

test "Vector: encodeVector renders the shortest f32 that round-trips" {
    const a = std.testing.allocator;
    // `{d}`'s contract is the shortest decimal that parses back to the same
    // `f32`, which is what makes the text form lossless on an engine whose
    // element type is `float4`. A `{any}`/`{}` spelling would not be: it is
    // scientific (`1.5e0`), and a consumer comparing text forms would see a
    // different string for the same value.
    const text = try encodeVector(a, &.{@as(f32, 0.1)});
    defer a.free(text);
    try std.testing.expectEqualStrings("[0.1]", text);
    const back = try parseVectorAlloc(a, text, 1);
    defer a.free(back);
    try std.testing.expectEqual(@as(f32, 0.1), back[0]);
}
