//! SQL parameter value type. Lives in its own file so lower layers
//! (core/edge, graph/step) can reference it without importing the full
//! builder (which depends back on graph/step).

/// A value that can be passed as a SQL argument.
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    bytes: []const u8,
};

/// Raw WHERE fragment with `?` placeholders and their bound values, used by
/// edge filters (avoids depending on the full builder / Predicate type).
pub const Filter = struct {
    sql: []const u8,
    args: []const Value = &.{},
};
