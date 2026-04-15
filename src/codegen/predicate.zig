const std = @import("std");
const TypeInfo = @import("graph.zig").TypeInfo;
const FieldInfo = @import("graph.zig").FieldInfo;
const sql = @import("../sql/builder.zig");

fn fieldName(comptime base: []const u8, comptime suffix: []const u8) [:0]const u8 {
    comptime {
        var buf: [256:0]u8 = undefined;
        @memcpy(buf[0..base.len], base);
        @memcpy(buf[base.len .. base.len + suffix.len], suffix);
        buf[base.len + suffix.len] = 0;
        return buf[0 .. base.len + suffix.len :0];
    }
}

/// Build a predicate function namespace.
pub fn Predicates(comptime info: TypeInfo) type {
    comptime {
        var fields: []const std.builtin.Type.StructField = &.{};
        for (info.fields) |f| {
            const PredFn = *const fn (sql.Value) sql.Predicate;
            fields = fields ++ &[_]std.builtin.Type.StructField{
                .{
                    .name = fieldName(f.name, "EQ"),
                    .type = PredFn,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(PredFn),
                },
                .{
                    .name = fieldName(f.name, "NE"),
                    .type = PredFn,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(PredFn),
                },
                .{
                    .name = fieldName(f.name, "GT"),
                    .type = PredFn,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(PredFn),
                },
                .{
                    .name = fieldName(f.name, "GTE"),
                    .type = PredFn,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(PredFn),
                },
                .{
                    .name = fieldName(f.name, "LT"),
                    .type = PredFn,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(PredFn),
                },
                .{
                    .name = fieldName(f.name, "LTE"),
                    .type = PredFn,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(PredFn),
                },
            };
            if (f.field_type == .string or f.field_type == .text) {
                const StringPredFn = *const fn ([]const u8) sql.Predicate;
                fields = fields ++ &[_]std.builtin.Type.StructField{
                    .{
                        .name = fieldName(f.name, "Contains"),
                        .type = StringPredFn,
                        .default_value_ptr = null,
                        .is_comptime = false,
                        .alignment = @alignOf(StringPredFn),
                    },
                };
            }
        }
        return @Type(.{
            .@"struct" = .{
                .layout = .auto,
                .fields = fields,
                .decls = &.{},
                .is_tuple = false,
            },
        });
    }
}

/// Instantiate the predicate namespace with actual function values.
pub fn makePredicates(comptime info: TypeInfo) Predicates(info) {
    comptime {
        var result: Predicates(info) = undefined;
        for (info.fields) |f| {
            const col = f.name;
            @field(result, col ++ "EQ") = struct {
                fn eqFn(v: sql.Value) sql.Predicate {
                    return sql.EQ(col, v);
                }
            }.eqFn;
            @field(result, col ++ "NE") = struct {
                fn neFn(v: sql.Value) sql.Predicate {
                    return sql.NE(col, v);
                }
            }.neFn;
            @field(result, col ++ "GT") = struct {
                fn gtFn(v: sql.Value) sql.Predicate {
                    return sql.GT(col, v);
                }
            }.gtFn;
            @field(result, col ++ "GTE") = struct {
                fn gteFn(v: sql.Value) sql.Predicate {
                    return sql.GTE(col, v);
                }
            }.gteFn;
            @field(result, col ++ "LT") = struct {
                fn ltFn(v: sql.Value) sql.Predicate {
                    return sql.LT(col, v);
                }
            }.ltFn;
            @field(result, col ++ "LTE") = struct {
                fn lteFn(v: sql.Value) sql.Predicate {
                    return sql.LTE(col, v);
                }
            }.lteFn;
            if (f.field_type == .string or f.field_type == .text) {
                @field(result, col ++ "Contains") = struct {
                    fn containsFn(v: []const u8) sql.Predicate {
                        // naive LIKE %v% pattern
                        return sql.Like(col, .{ .string = v });
                    }
                }.containsFn;
            }
        }
        return result;
    }
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Predicates" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const info = comptime fromSchema(User);
    const preds = comptime makePredicates(info);

    const p = preds.nameEQ(.{ .string = "alice" });
    // We can't easily test the predicate internals without a builder,
    // but we can verify compilation succeeds.
    _ = p;
    _ = preds.ageGT(.{ .int = 18 });
    _ = preds.nameContains("ali");
}
