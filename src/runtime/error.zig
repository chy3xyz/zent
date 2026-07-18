const std = @import("std");

/// Centralized error set for zent ORM.
///
/// Usage:
///   return ZentError.NotFound;
///   return ZentError.ValidationFailed;
///
/// For passing dynamic context, use `ZentError` with the message API:
///   return error.NotFound; // via the global error set
/// Database operation errors.
pub const DbError = error{
    /// The requested entity was not found.
    NotFound,
    /// Expected a single result but got multiple.
    NotSingular,
    /// A field value failed validation.
    ValidationFailed,
    /// The operation was denied by a privacy policy.
    PrivacyDenied,
    /// A required column was not present in the result set.
    MissingColumn,
    /// A database value could not be converted to the expected Zig type.
    TypeMismatch,
    /// Attempted to write to an immutable field.
    ImmutableField,
    /// The requested edge is invalid for this entity.
    InvalidEdge,
};

/// Driver-layer errors.
pub const DriverError = error{
    /// Failed to open the database.
    OpenFailed,
    /// Failed to prepare an SQL statement.
    PrepareFailed,
    /// Failed to execute an SQL statement.
    ExecFailed,
    /// A view schema is missing a view_sql definition.
    MissingViewSQL,
};

/// Build a human-readable error message from an error.
pub fn formatError(err: anyerror) []const u8 {
    return @errorName(err);
}

/// Wrapper that logs and returns the error.
pub fn logAndReturn(comptime src: std.builtin.SourceLocation, err: anyerror) anyerror {
    std.log.err("zent error at {s}:{d}: {s}", .{ src.file, src.line, @errorName(err) });
    return err;
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Error names" {
    try std.testing.expectEqualStrings("NotFound", @errorName(error.NotFound));
    try std.testing.expectEqualStrings("NotSingular", @errorName(error.NotSingular));
    try std.testing.expectEqualStrings("ValidationFailed", @errorName(error.ValidationFailed));
    try std.testing.expectEqualStrings("PrivacyDenied", @errorName(error.PrivacyDenied));
}

test "DbError set membership" {
    const err: DbError!void = error.NotFound;
    try std.testing.expectError(error.NotFound, err);
}
