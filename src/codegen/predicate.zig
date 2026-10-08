const std = @import("std");
const edgeTargetInfo = @import("graph.zig").edgeTargetInfo;
const TypeInfo = @import("graph.zig").TypeInfo;
const FieldInfo = @import("graph.zig").FieldInfo;
const buildEdgeStep = @import("graph.zig").buildEdgeStep;
const sql = @import("../sql/builder.zig");
const graph_neighbors = @import("../graph/neighbors.zig");
const runtime_log = @import("../runtime/log.zig");

fn fieldName(comptime entity_name: []const u8, comptime base: []const u8, comptime suffix: []const u8) [:0]const u8 {
    comptime {
        if (base.len + suffix.len > 255)
            @compileError("zent: predicate name '" ++ base ++ suffix ++ "' for field '" ++ base ++ "' on entity '" ++ entity_name ++ "' exceeds the 255-byte comptime name buffer; shorten the field name");
        var buf: [256:0]u8 = undefined;
        @memcpy(buf[0..base.len], base);
        @memcpy(buf[base.len .. base.len + suffix.len], suffix);
        buf[base.len + suffix.len] = 0;
        return buf[0 .. base.len + suffix.len :0];
    }
}

fn edgePredName(comptime entity_name: []const u8, comptime prefix: []const u8, comptime edge_name: []const u8) [:0]const u8 {
    comptime {
        // Prepend prefix, then capitalize edge name, e.g. "Has" + "cars" → "HasCars"
        // An empty edge name reads past the buffer below; fail naming the
        // entity and prefix instead of a comptime out-of-bounds panic.
        if (edge_name.len == 0)
            @compileError("zent: edge with an empty name on entity '" ++ entity_name ++ "' cannot derive its '" ++ prefix ++ "<Edge>' predicate");
        if (prefix.len + edge_name.len > 255)
            @compileError("zent: predicate name '" ++ prefix ++ edge_name ++ "' for edge '" ++ edge_name ++ "' on entity '" ++ entity_name ++ "' exceeds the 255-byte comptime name buffer; shorten the edge name");
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
                total_fields += 1; // Like (the verbatim-LIKE name for Contains)
                total_fields += 4; // HasPrefix, HasSuffix, ContainsFold, EQFold
            }
        }

        // Count edge predicates: each edge gets Has{Edge} + Has{Edge}With + NotHas{Edge}
        const edge_count = info.edges.len * 3;

        var field_names: [total_fields + edge_count][:0]const u8 = undefined;
        var field_types: [total_fields + edge_count]type = undefined;
        var field_attrs: [total_fields + edge_count]std.lang.Type.Struct.FieldAttributes = undefined;
        var idx: usize = 0;

        // Field-based predicates
        const PredFn = *const fn (sql.Value) sql.Predicate;
        const StringPredFn = *const fn ([]const u8) sql.Predicate;
        const ListPredFn = *const fn ([]const sql.Value) sql.Predicate;
        const NoArgPredFn = *const fn () sql.Predicate;

        for (info.fields) |f| {
            const eq_name = fieldName(info.name, f.name, "EQ");
            const ne_name = fieldName(info.name, f.name, "NE");
            const gt_name = fieldName(info.name, f.name, "GT");
            const gte_name = fieldName(info.name, f.name, "GTE");
            const lt_name = fieldName(info.name, f.name, "LT");
            const lte_name = fieldName(info.name, f.name, "LTE");

            for ([_][:0]const u8{ eq_name, ne_name, gt_name, gte_name, lt_name, lte_name }) |name| {
                field_names[idx] = name;
                field_types[idx] = PredFn;
                field_attrs[idx] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(PredFn) };
                idx += 1;
            }

            const in_name = fieldName(info.name, f.name, "In");
            const not_in_name = fieldName(info.name, f.name, "NotIn");
            for ([_][:0]const u8{ in_name, not_in_name }) |name| {
                field_names[idx] = name;
                field_types[idx] = ListPredFn;
                field_attrs[idx] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(ListPredFn) };
                idx += 1;
            }

            const is_null_name = fieldName(info.name, f.name, "IsNull");
            const not_nil_name = fieldName(info.name, f.name, "NotNil");
            for ([_][:0]const u8{ is_null_name, not_nil_name }) |name| {
                field_names[idx] = name;
                field_types[idx] = NoArgPredFn;
                field_attrs[idx] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(NoArgPredFn) };
                idx += 1;
            }

            if (f.field_type == .string or f.field_type == .text) {
                const contains_name = fieldName(info.name, f.name, "Contains");
                field_names[idx] = contains_name;
                field_types[idx] = StringPredFn;
                field_attrs[idx] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(StringPredFn) };
                idx += 1;
                // `Like` is the same predicate under a name that says what it
                // does. `Contains` binds the pattern verbatim, so it is an
                // equality on the literal string unless the caller supplies
                // the wildcards — a trap that has bitten at least one consumer
                // and one doc. New code should use `Like`; `Contains` stays as
                // the historical alias (renaming it is a breaking change).
                const like_name = fieldName(info.name, f.name, "Like");
                field_names[idx] = like_name;
                field_types[idx] = StringPredFn;
                field_attrs[idx] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(StringPredFn) };
                idx += 1;
                const contains_esc_name = fieldName(info.name, f.name, "ContainsEscaped");
                field_names[idx] = contains_esc_name;
                field_types[idx] = StringPredFn;
                field_attrs[idx] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(StringPredFn) };
                idx += 1;

                const str_names = [_][:0]const u8{
                    fieldName(info.name, f.name, "HasPrefix"),
                    fieldName(info.name, f.name, "HasSuffix"),
                    fieldName(info.name, f.name, "ContainsFold"),
                    fieldName(info.name, f.name, "EQFold"),
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
            const has_name = edgePredName(info.name, "Has", edge.name);
            field_names[idx] = has_name;
            field_types[idx] = NoArgPredFn;
            field_attrs[idx] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(NoArgPredFn) };
            idx += 1;

            const has_with_name = fieldName(info.name, edgePredName(info.name, "Has", edge.name), "With");
            field_names[idx] = has_with_name;
            field_types[idx] = PredWithFn;
            field_attrs[idx] = .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(PredWithFn) };
            idx += 1;

            const not_has_name = edgePredName(info.name, "NotHas", edge.name);
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
                @field(result, col ++ "Like") = struct {
                    fn likeFn(v: []const u8) sql.Predicate {
                        return sql.Like(sql_col, .{ .string = v });
                    }
                }.likeFn;
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
            const target_info = edgeTargetInfo(infos, info, edge);
            const step = buildEdgeStep(edge, info, target_info);
            // `Has{Edge}()` / `NotHas{Edge}()` / `Has{Edge}With()` are EXISTS
            // subqueries over the target table, so they carry the target's
            // soft-delete scope (ent does the same). Privacy filters and the
            // interceptor chain cannot be applied here — a bare predicate has no
            // runtime context — so a tenant-scoped existence check passes its
            // tenant predicate through `Has{Edge}With(…)` explicitly.
            const target_soft_delete = target_info.soft_delete;

            const has_name = edgePredName(info.name, "Has", edge.name);
            @field(result, has_name) = struct {
                fn hasFn() sql.Predicate {
                    return .{ .exists_fn = &struct {
                        fn gen(b: *sql.Builder) anyerror!void {
                            try graph_neighbors.appendHasNeighbors(b, step, target_soft_delete);
                        }
                    }.gen };
                }
            }.hasFn;

            const has_with_name = fieldName(info.name, edgePredName(info.name, "Has", edge.name), "With");
            @field(result, has_with_name) = struct {
                fn hasWithFn(preds: []const sql.Predicate) sql.Predicate {
                    // A hand-written `sql.Predicate` is schema-blind: inside
                    // the EXISTS body, a bare column that only the *other*
                    // side of the edge owns used to bind there — on an m2m
                    // edge the junction `j`, whose columns are literally
                    // `<table>_id` — and the query answered a
                    // filtered-by-accident page with no error at all. Every
                    // column-bearing predicate must address the target, so
                    // the wrapper checks them (see `hasWithPredOffender`).
                    if (hasWithPredsOffender(target_info, preds)) |offender| {
                        runtime_log.warn(
                            "zent: has-with edge predicate on \"{s}\": column \"{s}\" is not a field or column of the target \"{s}\"; the predicate fails with UnknownField when rendered",
                            .{ info.name, offender, target_info.name },
                        );
                        // The generated signature is infallible — callers
                        // compose it straight into `Where` — so the
                        // rejection is a predicate that fails at render:
                        // `Predicate.appendTo` answers `error.UnknownField`,
                        // the same answer the EntQL path gives at parse
                        // time. Through a QueryBuilder the build path
                        // narrows it to `BuildFailed`, exactly as it narrows
                        // an unlowered `.has_edge`.
                        return .{ .exists_fn = &struct {
                            fn unknownFieldGen(_: *sql.Builder) anyerror!void {
                                return error.UnknownField;
                            }
                        }.unknownFieldGen };
                    }
                    return .{ .has_neighbors_with = .{
                        .step = step,
                        .preds = preds,
                        .soft_delete = target_soft_delete,
                    } };
                }
            }.hasWithFn;

            const not_has_name = edgePredName(info.name, "NotHas", edge.name);
            @field(result, not_has_name) = struct {
                fn notHasFn() sql.Predicate {
                    return .{ .not_exists_fn = &struct {
                        fn gen(b: *sql.Builder) anyerror!void {
                            try graph_neighbors.appendHasNeighbors(b, step, target_soft_delete);
                        }
                    }.gen };
                }
            }.notHasFn;
        }

        return result;
    }
}

// ------------------------------------------------------------------
// Has{Edge}With target-column validation
// ------------------------------------------------------------------

/// Whether `name` can address a column of the edge *target* inside a
/// `Has{Edge}With` subquery: the target's API field name, its physical
/// column name (`StorageKey`), or a caller-qualified `t.col` — a dotted name
/// carries its own table, exactly as `sql.appendQualifiedPred` treats it, so
/// it is not second-guessed here.
fn targetColumnKnown(comptime target: TypeInfo, name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, name, '.') != null) return true;
    inline for (target.fields) |f| {
        if (std.mem.eql(u8, f.name, name) or std.mem.eql(u8, f.column_name, name)) return true;
    }
    return false;
}

/// The first column identifier in `pred` that addresses nothing the target
/// entity has, or `null` when every column-bearing predicate addresses it.
/// The shapes checked and the shapes skipped mirror `validateEntqlFields`
/// (codegen/query.zig): fragments carrying their own SQL (`raw`, `raw_args`,
/// subqueries, function-generated EXISTS) are not second-guessed, a
/// `.has_neighbors_with` addresses its *own* target one hop further — which
/// this scope cannot see, so skipping it keeps a nested composition legal —
/// and `.has_edge` / `.not_has_edge` are unlowered placeholders whose
/// rendering already fails loudly.
fn hasWithPredOffender(comptime target: TypeInfo, pred: sql.Predicate) ?[]const u8 {
    switch (pred) {
        .eq, .ne, .gt, .lt, .gte, .lte, .like, .eq_fold => |op| {
            if (!targetColumnKnown(target, op.column)) return op.column;
        },
        .in, .not_in => |op| {
            if (!targetColumnKnown(target, op.column)) return op.column;
        },
        .or_in => |op| {
            if (!targetColumnKnown(target, op.column)) return op.column;
        },
        .like_escaped => |op| {
            if (!targetColumnKnown(target, op.column)) return op.column;
        },
        .is_null, .is_not_null => |column| {
            if (!targetColumnKnown(target, column)) return column;
        },
        .in_subquery => |op| {
            if (!targetColumnKnown(target, op.column)) return op.column;
        },
        .and_ => |op| {
            if (hasWithPredOffender(target, op.left.*)) |column| return column;
            if (hasWithPredOffender(target, op.right.*)) |column| return column;
        },
        .or_ => |op| {
            if (hasWithPredOffender(target, op.left.*)) |column| return column;
            if (hasWithPredOffender(target, op.right.*)) |column| return column;
        },
        .not_ => |inner| return hasWithPredOffender(target, inner.*),
        .not_has_edge,
        .raw,
        .raw_args,
        .exists_subquery,
        .exists_fn,
        .not_exists_fn,
        .has_neighbors_with,
        .in_select,
        .has_edge,
        => {},
    }
    return null;
}

fn hasWithPredsOffender(comptime target: TypeInfo, preds: []const sql.Predicate) ?[]const u8 {
    for (preds) |pred| {
        if (hasWithPredOffender(target, pred)) |column| return column;
    }
    return null;
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
    // Comptime edge-name -> Step table (Step values are runtime readable),
    // matched by the runtime edge_name string. Built once, above the switch:
    // the has_edge and not_has_edge branches consume the same table, and
    // comptime blocks in a function body are evaluated on every analysis of
    // the instantiation regardless of which branch runs — two copies here
    // doubled the O(edges) buildEdgeStep work per entity on every graph.
    const edge_steps = comptime blk: {
        @setEvalBranchQuota(1000000);
        var steps: [info.edges.len]struct { name: []const u8, step: @import("../graph/step.zig").Step, soft_delete: bool } = undefined;
        for (info.edges, 0..) |e, i| {
            const target_info = edgeTargetInfo(infos, info, e);
            // The lowered predicate is an EXISTS over the *target* table, so
            // it carries the target's soft-delete scope exactly as the typed
            // `Has{Edge}()` / `NotHas{Edge}()` predicates above do — a
            // trashed row cannot satisfy an existence filter. Dropping it
            // here made `has(...)` pass for a parent whose rows are all
            // trashed, and `not_has(...)` fail, both disagreeing with the
            // typed predicates.
            steps[i] = .{ .name = e.name, .step = buildEdgeStep(e, info, target_info), .soft_delete = target_info.soft_delete };
        }
        break :blk steps;
    };
    switch (pred.*) {
        .has_edge => |*h| {
            var lowered = false;
            for (edge_steps) |es| {
                if (std.mem.eql(u8, es.name, h.edge_name)) {
                    if (h.pred) |nested| {
                        try lowerHasEdge(infos, info, allocator, @constCast(nested));
                        const preds = try allocator.alloc(sql.Predicate, 1);
                        preds[0] = nested.*;
                        allocator.destroy(nested);
                        pred.* = .{ .has_neighbors_with = .{ .step = es.step, .preds = preds, .soft_delete = es.soft_delete } };
                    } else {
                        pred.* = .{ .has_neighbors_with = .{ .step = es.step, .preds = &.{}, .soft_delete = es.soft_delete } };
                    }
                    lowered = true;
                    break;
                }
            }
            if (!lowered) return error.UnknownEdge;
        },
        .not_has_edge => |*h| {
            var lowered = false;
            for (edge_steps) |es| {
                if (std.mem.eql(u8, es.name, h.edge_name)) {
                    const inner = try allocator.create(sql.Predicate);
                    inner.* = .{ .has_neighbors_with = .{ .step = es.step, .preds = &.{}, .soft_delete = es.soft_delete } };
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

test "Predicates: Has{Edge}With rejects a column the target does not have" {
    // A hand-written `sql.Predicate` is schema-blind. Inside the EXISTS body,
    // a bare column that only the *other* side of the edge owns used to bind
    // there silently — on an m2m edge the junction `j`, whose columns are
    // literally `<table>_id`: `HasCarsWith(&.{sql.EQ("owner_id", …)})`
    // filtered by accident instead of erroring. The generated wrapper checks
    // every column-bearing predicate against the target (field API name or
    // physical column) and an unknown one fails the render with
    // `error.UnknownField`, the same answer the EntQL path gives.
    const field = @import("../core/field.zig");
    const edge = @import("../core/edge.zig");
    const schema = @import("../core/schema.zig").Schema;
    const fromSchema = @import("graph.zig").fromSchema;
    const Dialect = @import("../sql/dialect.zig").Dialect;

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

    const allocator = std.testing.allocator;

    // A non-eq shape over a real target column passes and renders.
    {
        const ok = user_preds.HasCarsWith(&.{sql.GT("year", .{ .int = 2020 })});
        var b = sql.Builder.init(allocator, Dialect.sqlite);
        defer b.deinit();
        try ok.appendTo(&b);
        try std.testing.expect(std.mem.indexOf(u8, b.query().sql, "\"year\" >") != null);
    }

    // `owner_id` — the source-side foreign key, the `<table>_id` shape a
    // junction carries — is neither a Car field nor a Car column. The
    // constructor stays infallible (its signature is pinned by callers
    // composing it into `Where`), so the rejection is a predicate that fails
    // at render, naming the error.
    {
        const bad = user_preds.HasCarsWith(&.{sql.EQ("owner_id", .{ .int = 7 })});
        var b = sql.Builder.init(allocator, Dialect.sqlite);
        defer b.deinit();
        try std.testing.expectError(error.UnknownField, bad.appendTo(&b));
    }

    // The same check recurses through AND/OR/NOT.
    {
        const ok_half = sql.EQ("model", .{ .string = "Tesla" });
        const bad_half = sql.EQ("owner_id", .{ .int = 7 });
        const nested = user_preds.HasCarsWith(&.{sql.And(&ok_half, &bad_half)});
        var b = sql.Builder.init(allocator, Dialect.sqlite);
        defer b.deinit();
        try std.testing.expectError(error.UnknownField, nested.appendTo(&b));
    }

    // `raw` carries its own SQL by convention and is not second-guessed.
    {
        const passthrough = user_preds.HasCarsWith(&.{sql.Raw("\"year\" > 2020")});
        var b = sql.Builder.init(allocator, Dialect.sqlite);
        defer b.deinit();
        try passthrough.appendTo(&b);
        try std.testing.expect(std.mem.indexOf(u8, b.query().sql, "\"year\" > 2020") != null);
    }
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

    // `Like` is the same predicate under a name that does not promise a
    // substring search, so a reader cannot be misled by the call site.
    {
        var s = try sql.Select(allocator, @import("../sql/dialect.zig").Dialect.mysql, &.{.{ .table = null, .name = "id" }});
        defer s.deinit();
        _ = s.from(sql.Table("users"));
        _ = try s.where(preds.nameLike("%foo%"));
        const q = try s.query();
        try std.testing.expectEqualStrings("SELECT `id` FROM `users` WHERE `name` LIKE ?", q.sql);
        try std.testing.expectEqualStrings("%foo%", q.args[0].string);
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
