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
        @setEvalBranchQuota(1000000);

        // Count fields
        var total_fields: usize = 0;
        for (info.fields) |f| {
            total_fields += 6; // EQ, NE, GT, GTE, LT, LTE
            total_fields += 4; // In, NotIn, IsNull, NotNil
            if (f.field_type == .string or f.field_type == .text) {
                total_fields += 2; // Contains + ContainsEscaped
                total_fields += 4; // HasPrefix, HasSuffix, ContainsFold, EQFold
            }
        }

        // Count edge predicates: each edge gets Has{Edge} + Has{Edge}With + NotHas{Edge}
        const edge_count = info.edges.len * 3;

        var field_names: [total_fields + edge_count][:0]const u8 = undefined;
        var field_types: [total_fields + edge_count]type = undefined;
        var field_attrs: [total_fields + edge_count]std.builtin.Type.Struct.FieldAttributes = undefined;
        var idx: usize = 0;

        // Field-based predicates
        const PredFn = *const fn (sql.Value) sql.Predicate;
        const StringPredFn = *const fn ([]const u8) sql.Predicate;
        const ListPredFn = *const fn ([]const sql.Value) sql.Predicate;
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

            const in_name = fieldName(f.name, "In");
            const not_in_name = fieldName(f.name, "NotIn");
            for ([_][:0]const u8{ in_name, not_in_name }) |name| {
                field_names[idx] = name;
                field_types[idx] = ListPredFn;
                field_attrs[idx] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(ListPredFn) };
                idx += 1;
            }

            const is_null_name = fieldName(f.name, "IsNull");
            const not_nil_name = fieldName(f.name, "NotNil");
            for ([_][:0]const u8{ is_null_name, not_nil_name }) |name| {
                field_names[idx] = name;
                field_types[idx] = NoArgPredFn;
                field_attrs[idx] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(NoArgPredFn) };
                idx += 1;
            }

            if (f.field_type == .string or f.field_type == .text) {
                const contains_name = fieldName(f.name, "Contains");
                field_names[idx] = contains_name;
                field_types[idx] = StringPredFn;
                field_attrs[idx] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(StringPredFn) };
                idx += 1;
                const contains_esc_name = fieldName(f.name, "ContainsEscaped");
                field_names[idx] = contains_esc_name;
                field_types[idx] = StringPredFn;
                field_attrs[idx] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(StringPredFn) };
                idx += 1;

                const str_names = [_][:0]const u8{
                    fieldName(f.name, "HasPrefix"),
                    fieldName(f.name, "HasSuffix"),
                    fieldName(f.name, "ContainsFold"),
                    fieldName(f.name, "EQFold"),
                };
                for (str_names) |name| {
                    field_names[idx] = name;
                    field_types[idx] = StringPredFn;
                    field_attrs[idx] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(StringPredFn) };
                    idx += 1;
                }
            }
        }

        // Edge-based predicates: Has{Edge}(), Has{Edge}With(preds), NotHas{Edge}()
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

            const not_has_name = edgePredName("NotHas", edge.name);
            field_names[idx] = not_has_name;
            field_types[idx] = NoArgPredFn;
            field_attrs[idx] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(NoArgPredFn) };
            idx += 1;
        }

        return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
    }
}

/// Instantiate the predicate namespace with actual function values.
pub fn makePredicates(comptime infos: []const TypeInfo, comptime info: TypeInfo) Predicates(infos, info) {
    comptime {
        @setEvalBranchQuota(1000000);
        var result: Predicates(infos, info) = undefined;

        // Field-based predicates. `col` names the generated predicate method
        // (field name); `sql_col` is the physical column the predicate filters.
        for (info.fields) |f| {
            const col = f.name;
            const sql_col = f.column_name;
            @field(result, col ++ "EQ") = struct {
                fn eqFn(v: sql.Value) sql.Predicate {
                    return sql.EQ(sql_col, v);
                }
            }.eqFn;
            @field(result, col ++ "NE") = struct {
                fn neFn(v: sql.Value) sql.Predicate {
                    return sql.NE(sql_col, v);
                }
            }.neFn;
            @field(result, col ++ "GT") = struct {
                fn gtFn(v: sql.Value) sql.Predicate {
                    return sql.GT(sql_col, v);
                }
            }.gtFn;
            @field(result, col ++ "GTE") = struct {
                fn gteFn(v: sql.Value) sql.Predicate {
                    return sql.GTE(sql_col, v);
                }
            }.gteFn;
            @field(result, col ++ "LT") = struct {
                fn ltFn(v: sql.Value) sql.Predicate {
                    return sql.LT(sql_col, v);
                }
            }.ltFn;
            @field(result, col ++ "LTE") = struct {
                fn lteFn(v: sql.Value) sql.Predicate {
                    return sql.LTE(sql_col, v);
                }
            }.lteFn;
            @field(result, col ++ "In") = struct {
                fn inFn(vals: []const sql.Value) sql.Predicate {
                    return sql.In(sql_col, vals);
                }
            }.inFn;
            @field(result, col ++ "NotIn") = struct {
                fn notInFn(vals: []const sql.Value) sql.Predicate {
                    return sql.NotIn(sql_col, vals);
                }
            }.notInFn;
            @field(result, col ++ "IsNull") = struct {
                fn isNullFn() sql.Predicate {
                    return sql.IsNull(sql_col);
                }
            }.isNullFn;
            @field(result, col ++ "NotNil") = struct {
                fn notNilFn() sql.Predicate {
                    return sql.IsNotNull(sql_col);
                }
            }.notNilFn;
            if (f.field_type == .string or f.field_type == .text) {
                @field(result, col ++ "Contains") = struct {
                    fn containsFn(v: []const u8) sql.Predicate {
                        return sql.Like(sql_col, .{ .string = v });
                    }
                }.containsFn;
                @field(result, col ++ "ContainsEscaped") = struct {
                    fn containsEscapedFn(v: []const u8) sql.Predicate {
                        return sql.ContainsEscaped(sql_col, v);
                    }
                }.containsEscapedFn;
                @field(result, col ++ "HasPrefix") = struct {
                    fn hasPrefixFn(v: []const u8) sql.Predicate {
                        return sql.HasPrefixEscaped(sql_col, v);
                    }
                }.hasPrefixFn;
                @field(result, col ++ "HasSuffix") = struct {
                    fn hasSuffixFn(v: []const u8) sql.Predicate {
                        return sql.HasSuffixEscaped(sql_col, v);
                    }
                }.hasSuffixFn;
                @field(result, col ++ "ContainsFold") = struct {
                    fn containsFoldFn(v: []const u8) sql.Predicate {
                        return sql.ContainsFoldEscaped(sql_col, v);
                    }
                }.containsFoldFn;
                @field(result, col ++ "EQFold") = struct {
                    fn eqFoldFn(v: []const u8) sql.Predicate {
                        return sql.EQFold(sql_col, .{ .string = v });
                    }
                }.eqFoldFn;
            }
        }

        // Edge-based predicates: Has{Edge}(), Has{Edge}With(preds), NotHas{Edge}()
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

            const not_has_name = edgePredName("NotHas", edge.name);
            @field(result, not_has_name) = struct {
                fn notHasFn() sql.Predicate {
                    return .{ .not_exists_fn = &struct {
                        fn gen(b: *sql.Builder) anyerror!void {
                            try graph_neighbors.appendHasNeighbors(b, step);
                        }
                    }.gen };
                }
            }.notHasFn;
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

/// Lower schema-unaware `.has_edge` / `.not_has_edge` placeholders produced by
/// the EntQL parser into schema-aware EXISTS predicates, reusing the same
/// machinery as the generated `Has{Edge}()` / `Has{Edge}With()` functions.
/// Recurses into AND/OR/NOT and nested `has()` predicates.
///
/// Ownership: nested predicate nodes are copied into a heap slice owned by the
/// resulting `.has_neighbors_with` and the original nodes are destroyed; the
/// caller must release the tree with `entql.deinitPred` (which frees
/// `.has_neighbors_with` slices recursively).
pub fn lowerHasEdge(
    comptime infos: []const TypeInfo,
    comptime info: TypeInfo,
    allocator: std.mem.Allocator,
    pred: *sql.Predicate,
) error{ UnknownEdge, OutOfMemory }!void {
    switch (pred.*) {
        .has_edge => |*h| {
            // Comptime edge-name -> Step table (Step values are runtime
            // readable), matched by the runtime edge_name string.
            const edge_steps = comptime blk: {
                var steps: [info.edges.len]struct { name: []const u8, step: @import("../graph/step.zig").Step } = undefined;
                for (info.edges, 0..) |e, i| {
                    const target_info = findTypeInfo(infos, e.target_name);
                    steps[i] = .{ .name = e.name, .step = buildEdgeStep(e, info, target_info) };
                }
                break :blk steps;
            };
            var lowered = false;
            for (edge_steps) |es| {
                if (std.mem.eql(u8, es.name, h.edge_name)) {
                    if (h.pred) |nested| {
                        try lowerHasEdge(infos, info, allocator, @constCast(nested));
                        const preds = try allocator.alloc(sql.Predicate, 1);
                        preds[0] = nested.*;
                        allocator.destroy(nested);
                        pred.* = .{ .has_neighbors_with = .{ .step = es.step, .preds = preds } };
                    } else {
                        pred.* = .{ .has_neighbors_with = .{ .step = es.step, .preds = &.{} } };
                    }
                    lowered = true;
                    break;
                }
            }
            if (!lowered) return error.UnknownEdge;
        },
        .not_has_edge => |*h| {
            const edge_steps = comptime blk: {
                var steps: [info.edges.len]struct { name: []const u8, step: @import("../graph/step.zig").Step } = undefined;
                for (info.edges, 0..) |e, i| {
                    const target_info = findTypeInfo(infos, e.target_name);
                    steps[i] = .{ .name = e.name, .step = buildEdgeStep(e, info, target_info) };
                }
                break :blk steps;
            };
            var lowered = false;
            for (edge_steps) |es| {
                if (std.mem.eql(u8, es.name, h.edge_name)) {
                    const inner = try allocator.create(sql.Predicate);
                    inner.* = .{ .has_neighbors_with = .{ .step = es.step, .preds = &.{} } };
                    pred.* = .{ .not_ = inner };
                    lowered = true;
                    break;
                }
            }
            if (!lowered) return error.UnknownEdge;
        },
        .and_ => |*a| {
            try lowerHasEdge(infos, info, allocator, @constCast(a.left));
            try lowerHasEdge(infos, info, allocator, @constCast(a.right));
        },
        .or_ => |*o| {
            try lowerHasEdge(infos, info, allocator, @constCast(o.left));
            try lowerHasEdge(infos, info, allocator, @constCast(o.right));
        },
        .not_ => |*n| {
            try lowerHasEdge(infos, info, allocator, @constCast(n.*));
        },
        else => {},
    }
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

test "Predicates: typed In/NotIn/IsNull/NotNil render dialect SQL" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
    });

    const user_info = comptime fromSchema(User);
    const infos = comptime &[_]TypeInfo{user_info};
    const preds = comptime makePredicates(infos, infos[0]);

    const allocator = std.testing.allocator;
    var s = try sql.Select(allocator, @import("../sql/dialect.zig").Dialect.sqlite, &.{.{ .table = null, .name = "id" }});
    defer s.deinit();
    _ = s.from(sql.Table("users"));

    const vals = [_]sql.Value{ .{ .int = 1 }, .{ .int = 2 } };
    _ = try s.where(preds.ageIn(&vals));
    _ = try s.where(preds.nameNotNil());
    const q = try s.query();
    try std.testing.expect(std.mem.indexOf(u8, q.sql, "\"age\" IN (?, ?)") != null);
    try std.testing.expect(std.mem.indexOf(u8, q.sql, "\"name\" IS NOT NULL") != null);
    try std.testing.expectEqual(@as(usize, 2), q.args.len);

    var s2 = try sql.Select(allocator, @import("../sql/dialect.zig").Dialect.sqlite, &.{.{ .table = null, .name = "id" }});
    defer s2.deinit();
    _ = s2.from(sql.Table("users"));
    _ = try s2.where(preds.nameIsNull());
    _ = try s2.where(preds.ageNotIn(&vals));
    const q2 = try s2.query();
    try std.testing.expect(std.mem.indexOf(u8, q2.sql, "\"name\" IS NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, q2.sql, "\"age\" NOT IN (?, ?)") != null);
}

test "Predicates: prefix/suffix/fold LIKE variants and edge negation" {
    const field = @import("../core/field.zig");
    const edge = @import("../core/edge.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const Car = schema("Car", .{ .fields = &.{field.String("model")} });
    const User = schema("User", .{
        .fields = &.{ field.String("name"), field.Int("age") },
        .edges = &.{edge.To("cars", Car)},
    });

    const car_info = comptime fromSchema(Car);
    const user_info = comptime fromSchema(User);
    const infos = comptime &[_]TypeInfo{ user_info, car_info };
    const resolved = comptime @import("graph.zig").resolveGraphEdges(infos);
    const preds = comptime makePredicates(resolved, resolved[0]);

    const allocator = std.testing.allocator;
    var s = try sql.Select(allocator, @import("../sql/dialect.zig").Dialect.sqlite, &.{.{ .table = null, .name = "id" }});
    defer s.deinit();
    _ = s.from(sql.Table("users"));
    _ = try s.where(preds.nameHasPrefix("a%"));
    _ = try s.where(preds.nameHasSuffix("z_"));
    _ = try s.where(preds.nameContainsFold("BoB"));
    const q = try s.query();
    // Wildcards in user input stay literal (escaped), and the mode decides
    // which side gets the trailing wildcard.
    try std.testing.expect(std.mem.indexOf(u8, q.sql, "\"name\" LIKE 'a\\%%' ESCAPE '\\'") != null);
    try std.testing.expect(std.mem.indexOf(u8, q.sql, "\"name\" LIKE '%z\\_' ESCAPE '\\'") != null);
    try std.testing.expect(std.mem.indexOf(u8, q.sql, "LOWER(\"name\") LIKE LOWER('%BoB%') ESCAPE '\\'") != null);
    try std.testing.expectEqual(@as(usize, 0), q.args.len);

    // NotHas{Edge} negates the same EXISTS subquery as Has{Edge}.
    _ = preds.nameEQFold("ALICE");
    const not_has = preds.NotHasCars();
    try std.testing.expect(not_has == .not_exists_fn);
    var s2 = try sql.Select(allocator, @import("../sql/dialect.zig").Dialect.sqlite, &.{.{ .table = null, .name = "id" }});
    defer s2.deinit();
    _ = s2.from(sql.Table("users"));
    _ = try s2.where(not_has);
    const q2 = try s2.query();
    try std.testing.expect(std.mem.indexOf(u8, q2.sql, "NOT EXISTS (") != null);
}

test "Predicates: Has{Edge}With accepts the target entity's typed predicates" {
    const field = @import("../core/field.zig");
    const edge = @import("../core/edge.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const Car = schema("Car", .{
        .fields = &.{ field.String("model"), field.Int("year") },
    });
    const User = schema("User", .{
        .fields = &.{field.String("name")},
        .edges = &.{edge.To("cars", Car)},
    });

    const car_info = comptime fromSchema(Car);
    const user_info = comptime fromSchema(User);
    const infos = comptime &[_]TypeInfo{ user_info, car_info };
    const resolved = comptime @import("graph.zig").resolveGraphEdges(infos);

    const user_preds = comptime makePredicates(resolved, resolved[0]);
    const car_preds = comptime makePredicates(resolved, resolved[1]);

    // The target's own typed predicates compose straight into Has{Edge}With,
    // so a traversal filter needs no hand-written sql.EQ/Raw.
    const typed = [_]sql.Predicate{
        car_preds.modelEQ(.{ .string = "Tesla" }),
        car_preds.yearGTE(.{ .int = 2020 }),
    };
    const has_with = user_preds.HasCarsWith(&typed);
    try std.testing.expect(has_with == .has_neighbors_with);
    try std.testing.expectEqual(@as(usize, 2), has_with.has_neighbors_with.preds.len);

    const allocator = std.testing.allocator;
    var s = try sql.Select(allocator, @import("../sql/dialect.zig").Dialect.postgres, &.{.{ .table = null, .name = "id" }});
    defer s.deinit();
    _ = s.from(sql.Table("users"));
    _ = try s.where(has_with);
    const q = try s.query();
    try std.testing.expect(std.mem.indexOf(u8, q.sql, "EXISTS (") != null);
    try std.testing.expect(std.mem.indexOf(u8, q.sql, "\"model\" =") != null);
    try std.testing.expect(std.mem.indexOf(u8, q.sql, "\"year\" >=") != null);
}

test "Predicates: Contains binds the pattern, ContainsEscaped wraps it" {
    const field = @import("../core/field.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;

    const User = schema("User", .{ .fields = &.{field.String("name")} });
    const info = comptime fromSchema(User);
    const infos = comptime &[_]TypeInfo{info};
    const preds = comptime makePredicates(infos, infos[0]);

    const allocator = std.testing.allocator;

    // `Contains` binds the value verbatim: the caller supplies the wildcards
    // (this is why it is the MySQL-safe variant and why passing "foo" is an
    // exact match, not a substring search).
    {
        var s = try sql.Select(allocator, @import("../sql/dialect.zig").Dialect.mysql, &.{.{ .table = null, .name = "id" }});
        defer s.deinit();
        _ = s.from(sql.Table("users"));
        _ = try s.where(preds.nameContains("foo"));
        const q = try s.query();
        try std.testing.expectEqualStrings("SELECT `id` FROM `users` WHERE `name` LIKE ?", q.sql);
        try std.testing.expectEqual(@as(usize, 1), q.args.len);
        try std.testing.expectEqualStrings("foo", q.args[0].string);

        var s2 = try sql.Select(allocator, @import("../sql/dialect.zig").Dialect.mysql, &.{.{ .table = null, .name = "id" }});
        defer s2.deinit();
        _ = s2.from(sql.Table("users"));
        _ = try s2.where(preds.nameContains("%foo%"));
        const q2 = try s2.query();
        try std.testing.expectEqualStrings("%foo%", q2.args[0].string);
    }

    // `ContainsEscaped` adds the wildcards itself and escapes the input, so it
    // takes a literal substring and renders no bound arguments.
    {
        var s = try sql.Select(allocator, @import("../sql/dialect.zig").Dialect.mysql, &.{.{ .table = null, .name = "id" }});
        defer s.deinit();
        _ = s.from(sql.Table("users"));
        _ = try s.where(preds.nameContainsEscaped("fo%o"));
        const q = try s.query();
        try std.testing.expectEqualStrings("SELECT `id` FROM `users` WHERE `name` LIKE '%fo!%o%' ESCAPE '!'", q.sql);
        try std.testing.expectEqual(@as(usize, 0), q.args.len);
    }
}
