const std = @import("std");
const TypeInfo = @import("graph.zig").TypeInfo;
const FieldInfo = @import("graph.zig").FieldInfo;
const buildEdgeStep = @import("graph.zig").buildEdgeStep;
const sql = @import("../sql/builder.zig");
const graph_neighbors = @import("../graph/neighbors.zig");

fn fieldName(comptime base: []const u8, comptime suffix: []const u8) [:0]const u8 {
    comptime {
        var buf: [256:0]u8 = undefined;
        @memcpy(buf[0..base.len], base);
        @memcpy(buf[base.len .. base.len + suffix.len], suffix);
        buf[base.len + suffix.len] = 0;
        return buf[0 .. base.len + suffix.len :0];
    }
}

fn edgePredName(comptime prefix: []const u8, comptime edge_name: []const u8) [:0]const u8 {
    comptime {
        // Prepend prefix, then capitalize edge name, e.g. "Has" + "cars" → "HasCars"
        var buf: [256:0]u8 = undefined;
        @memcpy(buf[0..prefix.len], prefix);
        buf[prefix.len] = std.ascii.toUpper(edge_name[0]);
        @memcpy(buf[prefix.len + 1 .. prefix.len + edge_name.len], edge_name[1..]);
        buf[prefix.len + edge_name.len] = 0;
        return buf[0 .. prefix.len + edge_name.len :0];
    }
}

/// Build a predicate function namespace, including field-based and
/// edge-based predicates.
pub fn Predicates(comptime infos: []const TypeInfo, comptime info: TypeInfo) type {
    _ = infos;
    comptime {
        @setEvalBranchQuota(10000);

        // Count fields
        var total_fields: usize = 0;
        for (info.fields) |f| {
            total_fields += 6; // EQ, NE, GT, GTE, LT, LTE
            if (f.field_type == .string or f.field_type == .text) {
                total_fields += 1; // Contains
            }
        }

        // Count edge predicates: each edge gets Has{Edge} + Has{Edge}With
        const edge_count = info.edges.len * 2;

        var field_names: [total_fields + edge_count][:0]const u8 = undefined;
        var field_types: [total_fields + edge_count]type = undefined;
        var field_attrs: [total_fields + edge_count]std.builtin.Type.StructField.Attributes = undefined;
        var idx: usize = 0;

        // Field-based predicates
        const PredFn = *const fn (sql.Value) sql.Predicate;
        const StringPredFn = *const fn ([]const u8) sql.Predicate;
        const NoArgPredFn = *const fn () sql.Predicate;

        for (info.fields) |f| {
            const eq_name = fieldName(f.name, "EQ");
            const ne_name = fieldName(f.name, "NE");
            const gt_name = fieldName(f.name, "GT");
            const gte_name = fieldName(f.name, "GTE");
            const lt_name = fieldName(f.name, "LT");
            const lte_name = fieldName(f.name, "LTE");

            for ([_][:0]const u8{ eq_name, ne_name, gt_name, gte_name, lt_name, lte_name }) |name| {
                field_names[idx] = name;
                field_types[idx] = PredFn;
                field_attrs[idx] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(PredFn) };
                idx += 1;
            }

            if (f.field_type == .string or f.field_type == .text) {
                const contains_name = fieldName(f.name, "Contains");
                field_names[idx] = contains_name;
                field_types[idx] = StringPredFn;
                field_attrs[idx] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(StringPredFn) };
                idx += 1;
            }
        }

        // Edge-based predicates: Has{Edge}() and Has{Edge}With(preds)
        const PredWithFn = *const fn ([]const sql.Predicate) sql.Predicate;
        for (info.edges) |edge| {
            const has_name = edgePredName("Has", edge.name);
            field_names[idx] = has_name;
            field_types[idx] = NoArgPredFn;
            field_attrs[idx] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(NoArgPredFn) };
            idx += 1;

            const has_with_name = fieldName(edgePredName("Has", edge.name), "With");
            field_names[idx] = has_with_name;
            field_types[idx] = PredWithFn;
            field_attrs[idx] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(PredWithFn) };
            idx += 1;
        }

        return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
    }
}

/// Instantiate the predicate namespace with actual function values.
pub fn makePredicates(comptime infos: []const TypeInfo, comptime info: TypeInfo) Predicates(infos, info) {
    comptime {
        @setEvalBranchQuota(10000);
        var result: Predicates(infos, info) = undefined;

        // Field-based predicates
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
                        return sql.Like(col, .{ .string = v });
                    }
                }.containsFn;
            }
        }

        // Edge-based predicates: Has{Edge}() and Has{Edge}With(preds)
        for (info.edges) |edge| {
            const target_info = findTypeInfo(infos, edge.target_name);
            const step = buildEdgeStep(edge, info, target_info);

            const has_name = edgePredName("Has", edge.name);
            @field(result, has_name) = struct {
                fn hasFn() sql.Predicate {
                    return .{ .exists_fn = &struct {
                        fn gen(b: *sql.Builder) anyerror!void {
                            try graph_neighbors.appendHasNeighbors(b, step);
                        }
                    }.gen };
                }
            }.hasFn;

            const has_with_name = fieldName(edgePredName("Has", edge.name), "With");
            @field(result, has_with_name) = struct {
                fn hasWithFn(preds: []const sql.Predicate) sql.Predicate {
                    return .{ .has_neighbors_with = .{ .step = step, .preds = preds } };
                }
            }.hasWithFn;
        }

        return result;
    }
}

fn findTypeInfo(comptime infos: []const TypeInfo, comptime name: []const u8) TypeInfo {
    for (infos) |ti| {
        if (std.mem.eql(u8, ti.name, name)) return ti;
    }
    @compileError("TypeInfo not found: " ++ name);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Predicates" {
    const field = @import("../core/field.zig");
    const edge = @import("../core/edge.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const Car = schema("Car", .{
        .fields = &.{field.String("model")},
    });
    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
        .edges = &.{edge.To("cars", Car)},
    });

    const car_info = comptime fromSchema(Car);
    const user_info = comptime fromSchema(User);
    const infos = comptime &[_]TypeInfo{ user_info, car_info };
    const resolved_infos = comptime @import("graph.zig").resolveGraphEdges(infos);

    const preds = comptime makePredicates(resolved_infos, resolved_infos[0]);

    // Field-based predicates compile
    _ = preds.nameEQ(.{ .string = "alice" });
    _ = preds.ageGT(.{ .int = 18 });
    _ = preds.nameContains("ali");

    // Edge-based predicates compile
    const has_cars = preds.HasCars();
    try std.testing.expect(has_cars == .exists_fn);

    const car_pred = sql.EQ("model", .{ .string = "Tesla" });
    const has_with = preds.HasCarsWith(&.{car_pred});
    try std.testing.expect(has_with == .has_neighbors_with);
    try std.testing.expectEqual(@as(usize, 1), has_with.has_neighbors_with.preds.len);
}
