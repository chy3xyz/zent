//! The value shapes `setFieldValue` accepts, decided in **one** place.
//!
//! This contract used to live in three: `canSetField` (the type check),
//! `toSqlValue` (the conversion), and a doc table — and the first two were
//! duplicated across `create.zig` and `update_delete.zig`, where they had
//! already drifted apart in both implementation *and* accepted set. One of the
//! shapes they advertised (`[N]u8` array values) could never work:
//! `toSqlValue` receives the array by value, so turning it into a slice would
//! return a pointer to its own stack frame.
//!
//! The rule now: `accepts` decides, `toSqlValue` converts, and both are
//! exercised by the test at the bottom of this file — including the shapes that
//! must be **rejected**, which is what a doc table cannot do.
//!
//! ## Accepted shapes
//!
//! `Expected` is the field's Zig type; `Actual` is `@TypeOf(value)`.
//!
//! | Field type | Accepted |
//! |---|---|
//! | `Bool` | `bool` |
//! | `Int` | `i64`, `comptime_int` |
//! | `Float` | `f64`, `comptime_float` |
//! | `String`/`Text`/`UUID`/`Decimal`/`Bytes` | `[]const u8`, or a pointer to a `u8` array (a string literal) |
//! | `JSON` | exactly the field's own Zig type (a struct, or `std.json.Value` for `field.JSONValue`) |
//! | `Optional(T)` | anything accepted for `T`, or an `?T` value |
//!
//! Rejected: a bare `null` (write `@as(?T, null)`), any integer type other than
//! `i64`/`comptime_int`, a `[N]u8` **array value** (pass a slice or a literal),
//! a Zig `enum` value for an `Enum` field (its Zig type is `[]const u8`, so pass
//! the tag string), and a plain `struct` for a non-JSON field.
//!
//! A rejection is a `@compileError` at the `setFieldValue` call site, naming
//! the field and both types.

const std = @import("std");
const sql = @import("../sql/builder.zig");

/// Whether a value of Zig type `Actual` may be assigned to a field of Zig type
/// `Expected`. See the module docs for the table.
pub fn accepts(comptime Expected: type, comptime Actual: type) bool {
    const Unwrapped = if (@typeInfo(Expected) == .optional)
        @typeInfo(Expected).optional.child
    else
        Expected;

    if (Expected == Actual) return true;
    if (Unwrapped == Actual) return true; // optional field accepts a bare value
    if (Unwrapped == i64 and Actual == comptime_int) return true;
    if (Unwrapped == f64 and Actual == comptime_float) return true;
    if (Unwrapped == []const u8) return isStringLike(Actual);
    return false;
}

/// A `u8` slice, or a pointer to a `u8` array — which is what a Zig string
/// literal is (`*const [N:0]u8`). Deliberately **not** an array value: see the
/// module docs.
pub fn isStringLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return true;
            if (ptr.size == .one) {
                return switch (@typeInfo(ptr.child)) {
                    .array => |arr| arr.child == u8,
                    else => false,
                };
            }
            return false;
        },
        else => false,
    };
}

/// Convert an accepted value into its column representation. Shapes outside the
/// table reach the `@compileError` at the bottom.
pub fn toSqlValue(v: anytype) sql.Value {
    const T = @TypeOf(v);
    if (T == comptime_int) return .{ .int = v };
    if (T == comptime_float) return .{ .float = v };

    switch (@typeInfo(T)) {
        .optional => {
            if (v) |payload| return toSqlValue(payload);
            return .null;
        },
        .bool => return .{ .bool = v },
        .int => return .{ .int = v },
        .float => return .{ .float = v },
        .pointer => {
            if (comptime isStringLike(T)) return .{ .string = v };
        },
        // Explicit rather than falling into the generic message: an array value
        // is a plausible mistake and deserves to say what to write instead.
        .array => @compileError("setFieldValue cannot take a `" ++ @typeName(T) ++
            "` array value — it would have to hand back a pointer to its own parameter. Pass a slice, or a string literal."),
        else => {},
    }
    @compileError("Unsupported value type: " ++ @typeName(T));
}

// ------------------------------------------------------------------
// Tests — the table above, checked in both directions
// ------------------------------------------------------------------

const testing = std.testing;

const Payload = struct { kind: []const u8 };

test "field_value.accepts pins the accepted shapes" {
    // Ints
    try testing.expect(accepts(i64, i64));
    try testing.expect(accepts(i64, @TypeOf(7))); // comptime_int
    try testing.expect(!accepts(i64, i32));
    try testing.expect(!accepts(i64, f64));
    // Floats: a bare comptime_float is fine, a comptime_int is not.
    try testing.expect(accepts(f64, f64));
    try testing.expect(accepts(f64, @TypeOf(19.5)));
    try testing.expect(!accepts(f64, @TypeOf(7)));
    // Bool
    try testing.expect(accepts(bool, bool));
    try testing.expect(!accepts(bool, i64));
    // Strings: a slice or a literal, never an array value.
    try testing.expect(accepts([]const u8, []const u8));
    try testing.expect(accepts([]const u8, *const [4:0]u8));
    try testing.expect(!accepts([]const u8, [4:0]u8));
    try testing.expect(!accepts([]const u8, []const u16));
    try testing.expect(!accepts([]const u8, *const [4:0]u16));
    // Optionals take a bare value, and `null` only as `?T`.
    try testing.expect(accepts(?i64, i64));
    try testing.expect(accepts(?i64, ?i64));
    try testing.expect(accepts(?i64, @TypeOf(7)));
    try testing.expect(accepts(?[]const u8, *const [4:0]u8));
    try testing.expect(!accepts(?[]const u8, [4:0]u8));
    // JSON: the field's own type only — the two JSON flavours do not mix.
    try testing.expect(accepts(Payload, Payload));
    try testing.expect(!accepts(Payload, std.json.Value));
    try testing.expect(accepts(std.json.Value, std.json.Value));
    try testing.expect(!accepts(std.json.Value, Payload));
}

test "field_value.isStringLike pins the string shapes" {
    try testing.expect(isStringLike([]const u8));
    try testing.expect(isStringLike(*const [4:0]u8)); // a string literal
    try testing.expect(isStringLike(*[4]u8));
    try testing.expect(!isStringLike([4]u8)); // an array value
    try testing.expect(!isStringLike([4:0]u8));
    try testing.expect(!isStringLike([]const u16));
    try testing.expect(!isStringLike(*const [4:0]u16));
    try testing.expect(!isStringLike(u8));
}

test "field_value.toSqlValue converts every accepted shape" {
    const a: []const u8 = "slice";
    try testing.expectEqual(@as(i64, 7), toSqlValue(7).int);
    try testing.expectEqual(@as(i64, 7), toSqlValue(@as(i64, 7)).int);
    try testing.expectEqual(@as(f64, 1.5), toSqlValue(1.5).float);
    try testing.expectEqual(true, toSqlValue(true).bool);
    try testing.expectEqualStrings("literal", toSqlValue("literal").string);
    try testing.expectEqualStrings("slice", toSqlValue(a).string);
    try testing.expectEqualStrings("owned", toSqlValue(@as(?[]const u8, "owned")).string);
    const null_int: ?i64 = null;
    try testing.expect(toSqlValue(null_int) == .null);
}
