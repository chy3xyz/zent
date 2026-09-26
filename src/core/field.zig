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
        .other => return "TEXT",
    }
}

/// Map a FieldType to a Zig type for generated code.
pub fn zigType(comptime field_type: FieldType, comptime custom_type: ?type) type {
    switch (field_type) {
        .bool => return bool,
        .int => return i64,
        .float => return f64,
        .string, .text, .enum_, .uuid, .decimal, .other => return []const u8,
        .bytes => return []const u8,
        .time => return i64, // timestamp as epoch for simplicity
        .json => return custom_type orelse []const u8,
    }
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
