const std = @import("std");

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
    default: DefaultValue = .none,
    validators: []const Validator = &.{},

    // Builder methods
    pub fn Optional(self: Field) Field {
        var f = self;
        f.optional = true;
        return f;
    }

    pub fn Nillable(self: Field) Field {
        var f = self;
        f.nillable = true;
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

pub fn Enum(name: []const u8, comptime values: []const []const u8) Field {
    // Store values as a comma-separated string for simplicity in comptime.
    // In a real implementation we might use a more structured approach.
    _ = values;
    return .{ .name = name, .field_type = .enum_ };
}

pub fn UUID(name: []const u8) Field {
    return .{ .name = name, .field_type = .uuid };
}

// ------------------------------------------------------------------
// SQL type mapping
// ------------------------------------------------------------------

pub const Dialect = @import("../sql/dialect.zig").Dialect;

pub fn sqlType(comptime field_type: FieldType, dialect: Dialect) []const u8 {
    switch (field_type) {
        .bool => return "BOOLEAN",
        .int => return "INTEGER",
        .float => return "REAL",
        .string => return "TEXT",
        .text => return "TEXT",
        .bytes => return "BLOB",
        .time => {
            if (std.mem.eql(u8, dialect.name, "mysql")) return "DATETIME";
            if (std.mem.eql(u8, dialect.name, "postgres")) return "TIMESTAMPTZ";
            return "DATETIME";
        },
        .json => {
            if (std.mem.eql(u8, dialect.name, "postgres")) return "JSONB";
            return "TEXT";
        },
        .enum_ => return "TEXT",
        .uuid => {
            if (std.mem.eql(u8, dialect.name, "postgres")) return "UUID";
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
        .string, .text, .enum_, .uuid, .other => return []const u8,
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
    try std.testing.expectEqualStrings("JSONB", sqlType(.json, .{ .name = "postgres" }));
}
