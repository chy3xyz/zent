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
//! | `String`/`Text`/`UUID`/`Decimal`/`Bytes`/`Other` | `[]const u8`, or a pointer to a `u8` array (a string literal) |
//! | `Vector` | `[]const f32`, or a pointer to an `f32` array |
//! | `JSON` | exactly the field's own Zig type (a struct, or `std.json.Value` for `field.JSONValue`) |
//! | `Optional(T)` | anything accepted for `T`, or an `?T` value |
//!
//! A bare `null` is accepted for an optional field (no `@as(?T, null)` needed)
//! and rejected for a non-optional one.
//!
//! Rejected: any integer type other than `i64`/`comptime_int`, a `[N]u8`
//! **array value** (pass a slice or a literal), a Zig `enum` value for an
//! `Enum` field (its Zig type is `[]const u8`, so pass the tag string), and a
//! plain `struct` for a non-JSON field.
//!
//! A rejection is a `@compileError` at the `setFieldValue` call site, naming
//! the field and both types.
//!
//! ## One column type, two `Value` tags
//!
//! `toSqlValue` takes the field's **logical type** as well as the value,
//! because the Zig type alone does not name the wire shape: `field.Bytes` and
//! `field.String` are both `[]const u8`, but a byte column's parameter must
//! travel as `Value.bytes` (binary) rather than `Value.string` (text). Sending
//! the bytes of a `BYTEA` column as text hands them to PostgreSQL's `byteain`
//! input function, which reads them against `client_encoding` and then decodes
//! backslashes — so a NUL truncates the value, non-UTF-8 bytes are rejected
//! outright, and `\nnn` is silently decoded into a different byte. The tag is
//! therefore decided by what the column *is*, never by `@TypeOf(value)`.

const std = @import("std");
const sql = @import("../sql/builder.zig");
const field_mod = @import("../core/field.zig");

const FieldType = field_mod.FieldType;

/// Whether a value of Zig type `Actual` may be assigned to a field of Zig type
/// `Expected`. See the module docs for the table.
pub fn accepts(comptime Expected: type, comptime Actual: type) bool {
    const Unwrapped = if (@typeInfo(Expected) == .optional)
        @typeInfo(Expected).optional.child
    else
        Expected;

    // A bare `null` literal: only for an optional field, but allowed without the
    // `@as(?T, null)` spelling. `@TypeOf(null)` is its own type, so it never
    // matches the cases below, and the compile error it used to produce
    // ("expected ?[]const u8, got @TypeOf(null)") read as "null is not
    // supported" to more than one reader.
    if (Actual == @TypeOf(null)) return @typeInfo(Expected) == .optional;

    if (Expected == Actual) return true;
    if (Unwrapped == Actual) return true; // optional field accepts a bare value
    if (Unwrapped == i64 and Actual == comptime_int) return true;
    if (Unwrapped == f64 and Actual == comptime_float) return true;
    if (Unwrapped == []const u8) return isStringLike(Actual);
    if (Unwrapped == []const f32) return isSliceOf(Actual, f32);
    return false;
}

/// A `u8` slice, or a pointer to a `u8` array — which is what a Zig string
/// literal is (`*const [N:0]u8`). Deliberately **not** an array value: see the
/// module docs.
pub fn isStringLike(comptime T: type) bool {
    return isSliceOf(T, u8);
}

/// A `Child` slice, or a pointer to a `Child` array — the shapes a literal can
/// be written in without naming a slice type. Deliberately **not** an array
/// *value*: see the module docs.
pub fn isSliceOf(comptime T: type, comptime Child: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == Child) return true;
            if (ptr.size == .one) {
                return switch (@typeInfo(ptr.child)) {
                    .array => |arr| arr.child == Child,
                    else => false,
                };
            }
            return false;
        },
        else => false,
    };
}

/// Convert an accepted value into its column representation, for a field whose
/// logical type is `ft`. The logical type is required — see "One column type,
/// two `Value` tags" in the module docs: `[]const u8` is the Zig type of both a
/// `String` and a `Bytes` field, and only the field says which `Value` tag the
/// bytes must travel under. Shapes outside the table reach the `@compileError`
/// at the bottom.
pub fn toSqlValue(comptime ft: FieldType, v: anytype) sql.Value {
    const T = @TypeOf(v);
    if (T == comptime_int) return .{ .int = v };
    if (T == comptime_float) return .{ .float = v };
    if (T == @TypeOf(null)) return .null;

    switch (@typeInfo(T)) {
        .optional => {
            if (v) |payload| return toSqlValue(ft, payload);
            return .null;
        },
        .bool => return .{ .bool = v },
        .int => return .{ .int = v },
        .float => return .{ .float = v },
        .pointer => {
            if (comptime isSliceOf(T, f32)) {
                @compileError("A `field.Vector` value reaches the driver as its text form: setFieldValue encodes it, so it never passes through toSqlValue.");
            }
            if (comptime isStringLike(T)) {
                // The column's own type picks the tag: a `bytea`/`BLOB` column
                // takes the raw bytes (binary format on PostgreSQL), every
                // other string-shaped column takes text.
                if (ft == .bytes) return .{ .bytes = v };
                return .{ .string = v };
            }
        },
        // Explicit rather than falling into the generic message: an array value
        // is a plausible mistake and deserves to say what to write instead.
        .array => @compileError("setFieldValue cannot take a `" ++ @typeName(T) ++
            "` array value — it would have to hand back a pointer to its own parameter. Pass a slice, or a string literal."),
        else => {},
    }
    @compileError("Unsupported value type: " ++ @typeName(T));
}

/// Encode an accepted `field.Vector` value into pgvector's text form, or null
/// for a null value. A value whose element count is not `dims` is
/// `error.ValidationFailed` — the write-path check, alongside the type check
/// and with the same error a `VarChar` overrun gets.
///
/// The check lives **here** rather than in `create.validateSqlValue`, which is
/// where `VarChar(n)`'s is, for three reasons that all point the same way:
///
///   * this is the single funnel every typed write goes through — `Create`,
///     `BulkInsert`, `Update` and `BulkUpdate` all reach the codec through
///     `setFieldValue`. `validateSqlValue` is consulted by the create paths
///     only (the update paths call no validator at all), so a check placed
///     there would let `Update().setFieldValue("embedding", …)` through and
///     leave the server to answer `expected 3 dimensions, not 2`.
///   * the element count is in hand here and nowhere else: `validateSqlValue`
///     sees the already-encoded `Value.string` and could only recover the
///     count by re-parsing the text this function has just produced.
///   * the dimension still reaches `FieldInfo.vector_dims`, so the DDL and any
///     future check that works on the declaration keep it.
///
/// The raw escape hatches (`set`/`setValue` with a hand-built `sql.Value`)
/// bypass every typed check by design — `VarChar`'s length ceiling included —
/// and are not what "the write path" means here.
pub fn vectorTextAlloc(allocator: std.mem.Allocator, v: anytype, dims: usize) error{ ValidationFailed, OutOfMemory }!?[]u8 {
    const T = @TypeOf(v);
    if (T == @TypeOf(null)) return null;

    switch (@typeInfo(T)) {
        .optional => {
            if (v) |payload| return vectorTextAlloc(allocator, payload, dims);
            return null;
        },
        .pointer => |ptr| {
            // `[]const f32`, or a pointer to an `f32` array (a literal), which
            // coerces to the slice the codec takes. An array *value* is refused
            // by `accepts`, for the reason the module docs give. Both tests are
            // comptime (`ptr` comes from `@typeInfo` of a comptime type), so the
            // prong is only analyzed for the shape it actually has — which is
            // what keeps the `@compileError` below from firing on every legal
            // call.
            if (ptr.size == .slice and ptr.child == f32) {
                if (v.len != dims) return error.ValidationFailed;
                return try field_mod.encodeVector(allocator, v);
            }
            if (ptr.size == .one) {
                if (@typeInfo(ptr.child) == .array) {
                    if (@typeInfo(ptr.child).array.child == f32) {
                        const values: []const f32 = v;
                        if (values.len != dims) return error.ValidationFailed;
                        return try field_mod.encodeVector(allocator, values);
                    }
                }
            }
        },
        else => {},
    }
    @compileError("field.Vector accepts `[]const f32` (or an `f32` array literal): got " ++ @typeName(T));
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
    // Vectors: `[]const f32` and an `f32` literal, and the two do not cross
    // with the string shapes (`[]const u8` is not a vector, and vice versa).
    try testing.expect(accepts([]const f32, []const f32));
    try testing.expect(accepts([]const f32, *const [3]f32));
    try testing.expect(accepts(?[]const f32, *const [3]f32));
    try testing.expect(!accepts([]const f32, [3]f32)); // an array value
    try testing.expect(!accepts([]const f32, []const u8));
    try testing.expect(!accepts([]const u8, []const f32));
    try testing.expect(!accepts([]const f32, []const f64));
    // Optionals take a bare value, and `null` only as `?T`.
    try testing.expect(accepts(?i64, i64));
    try testing.expect(accepts(?i64, ?i64));
    try testing.expect(accepts(?i64, @TypeOf(7)));
    try testing.expect(accepts(?[]const u8, *const [4:0]u8));
    try testing.expect(!accepts(?[]const u8, [4:0]u8));
    // A bare `null` literal, for optional fields only.
    try testing.expect(accepts(?i64, @TypeOf(null)));
    try testing.expect(accepts(?[]const u8, @TypeOf(null)));
    try testing.expect(!accepts(i64, @TypeOf(null)));
    try testing.expect(!accepts([]const u8, @TypeOf(null)));
    try testing.expect(!accepts(bool, @TypeOf(null)));
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
    try testing.expect(!isStringLike([]const f32));
}

test "field_value.toSqlValue converts every accepted shape" {
    const a: []const u8 = "slice";
    try testing.expectEqual(@as(i64, 7), toSqlValue(.int, 7).int);
    try testing.expectEqual(@as(i64, 7), toSqlValue(.int, @as(i64, 7)).int);
    try testing.expectEqual(@as(f64, 1.5), toSqlValue(.float, 1.5).float);
    try testing.expectEqual(true, toSqlValue(.bool, true).bool);
    try testing.expectEqualStrings("literal", toSqlValue(.string, "literal").string);
    try testing.expectEqualStrings("slice", toSqlValue(.text, a).string);
    try testing.expectEqualStrings("owned", toSqlValue(.string, @as(?[]const u8, "owned")).string);
    const null_int: ?i64 = null;
    try testing.expect(toSqlValue(.int, null_int) == .null);
    try testing.expect(toSqlValue(.string, null) == .null);
    // A `.bytes` field is the same Zig type as a `.string` one and must not
    // share its tag: the bytes travel in the binary format.
    try testing.expectEqualStrings("slice", toSqlValue(.bytes, a).bytes);
    try testing.expectEqualStrings("literal", toSqlValue(.bytes, "literal").bytes);
    try testing.expectEqualStrings("owned", toSqlValue(.bytes, @as(?[]const u8, "owned")).bytes);
    try testing.expect(toSqlValue(.bytes, @as(?[]const u8, null)) == .null);
    // ...and a `.string` field never gets the byte tag, whatever the caller
    // passed it.
    try testing.expect(toSqlValue(.uuid, a) == .string);
    try testing.expect(toSqlValue(.decimal, a) == .string);
    try testing.expect(toSqlValue(.other, a) == .string);
}

test "field_value.vectorTextAlloc: the same bytes a scalar write produces, and the dimension check" {
    const a = testing.allocator;

    // The shapes `accepts` admits for a vector field: a slice, and a pointer to
    // an `f32` array (what a literal is).
    {
        const slice: []const f32 = &.{ 1, 2, 3 };
        const text = (try vectorTextAlloc(a, slice, 3)).?;
        defer a.free(text);
        try testing.expectEqualStrings("[1,2,3]", text);
    }
    {
        const text = (try vectorTextAlloc(a, &[_]f32{ 1.5, -2 }, 2)).?;
        defer a.free(text);
        try testing.expectEqualStrings("[1.5,-2]", text);
    }
    // An optional value unwraps, and a null one is a NULL column, not `[]`.
    {
        const text = (try vectorTextAlloc(a, @as(?[]const f32, &.{7}), 1)).?;
        defer a.free(text);
        try testing.expectEqualStrings("[7]", text);
        try testing.expectEqual(@as(?[]u8, null), try vectorTextAlloc(a, @as(?[]const f32, null), 1));
        try testing.expectEqual(@as(?[]u8, null), try vectorTextAlloc(a, null, 1));
    }

    // The dimension check: the whole reason this is not `toSqlValue`. Both
    // directions of "wrong count" and the boundary cases.
    const wrong = [_][]const f32{ &.{}, &.{1}, &.{ 1, 2 }, &.{ 1, 2, 3, 4 } };
    for (wrong) |v| {
        try testing.expectError(error.ValidationFailed, vectorTextAlloc(a, v, 3));
    }
    {
        const empty: []const f32 = &.{};
        try testing.expectError(error.ValidationFailed, vectorTextAlloc(a, empty, 3));
        try testing.expectError(error.ValidationFailed, vectorTextAlloc(a, &[_]f32{}, 1));
    }
    // An empty value against a declared zero: the count *does* match, and the
    // codec's `[]` is what comes out. Unreachable from a schema — `Vector`
    // refuses `dims == 0` at comptime — so this pins the codec's own answer
    // rather than a legal write.
    {
        const text = (try vectorTextAlloc(a, &[_]f32{}, 0)).?;
        defer a.free(text);
        try testing.expectEqualStrings("[]", text);
    }

    // A failure part-way through allocates nothing that is not released: the
    // testing allocator is the ledger.
    try testing.expectError(error.ValidationFailed, vectorTextAlloc(a, &[_]f32{ 1, 2 }, 3));
}
