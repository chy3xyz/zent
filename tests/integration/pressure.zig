//! Compile-time stress test: ~30 tables x 8 fields with edges,
//! indexes and JSON fields. Guards against @setEvalBranchQuota
//! regressions and codegen size blowups (real projects hit 20+ tables).
const std = @import("std");
const zent = @import("zent");
const field = zent.core.field;
const edge = zent.core.edge;
const Schema = zent.core.schema.Schema;
const index = zent.core.index;
const buildGraph = zent.codegen.graph.buildGraph;
const Client = zent.codegen.client;
const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
const testing = std.testing;

const Settings = struct { theme: []const u8, notifications: bool };

fn withEdges(comptime Base: type, comptime es: []const edge.Edge) type {
    return struct {
        pub const schema_name = Base.schema_name;
        pub const fields = Base.fields;
        pub const edges = es;
        pub const indexes = Base.indexes;
        pub const policy = if (@hasDecl(Base, "policy")) Base.policy else null;
        pub const is_view = if (@hasDecl(Base, "is_view")) Base.is_view else false;
        pub const view_sql = if (@hasDecl(Base, "view_sql")) Base.view_sql else null;
        pub const soft_delete = if (@hasDecl(Base, "soft_delete")) Base.soft_delete else false;
    };
}

const T01Base = Schema("T01", .{
    .fields = &.{
        field.String("name_t01"),
        field.String("code_t01"),
        field.Int("count_t01"),
        field.Int("score_t01"),
        field.Enum("status_t01", &.{ "a", "b", "c" }),
        field.Bool("active_t01"),
        field.Time("created_at_t01"),
        field.JSON("settings_t01", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t01"})},
});

const T02Base = Schema("T02", .{
    .fields = &.{
        field.String("name_t02"),
        field.String("code_t02"),
        field.Int("count_t02"),
        field.Int("score_t02"),
        field.Enum("status_t02", &.{ "a", "b", "c" }),
        field.Bool("active_t02"),
        field.Time("created_at_t02"),
        field.JSON("settings_t02", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t02"})},
});

const T03Base = Schema("T03", .{
    .fields = &.{
        field.String("name_t03"),
        field.String("code_t03"),
        field.Int("count_t03"),
        field.Int("score_t03"),
        field.Enum("status_t03", &.{ "a", "b", "c" }),
        field.Bool("active_t03"),
        field.Time("created_at_t03"),
        field.JSON("settings_t03", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t03"})},
});

const T04Base = Schema("T04", .{
    .fields = &.{
        field.String("name_t04"),
        field.String("code_t04"),
        field.Int("count_t04"),
        field.Int("score_t04"),
        field.Enum("status_t04", &.{ "a", "b", "c" }),
        field.Bool("active_t04"),
        field.Time("created_at_t04"),
        field.JSON("settings_t04", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t04"})},
});

const T05Base = Schema("T05", .{
    .fields = &.{
        field.String("name_t05"),
        field.String("code_t05"),
        field.Int("count_t05"),
        field.Int("score_t05"),
        field.Enum("status_t05", &.{ "a", "b", "c" }),
        field.Bool("active_t05"),
        field.Time("created_at_t05"),
        field.JSON("settings_t05", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t05"})},
});

const T06Base = Schema("T06", .{
    .fields = &.{
        field.String("name_t06"),
        field.String("code_t06"),
        field.Int("count_t06"),
        field.Int("score_t06"),
        field.Enum("status_t06", &.{ "a", "b", "c" }),
        field.Bool("active_t06"),
        field.Time("created_at_t06"),
        field.JSON("settings_t06", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t06"})},
});

const T07Base = Schema("T07", .{
    .fields = &.{
        field.String("name_t07"),
        field.String("code_t07"),
        field.Int("count_t07"),
        field.Int("score_t07"),
        field.Enum("status_t07", &.{ "a", "b", "c" }),
        field.Bool("active_t07"),
        field.Time("created_at_t07"),
        field.JSON("settings_t07", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t07"})},
});

const T08Base = Schema("T08", .{
    .fields = &.{
        field.String("name_t08"),
        field.String("code_t08"),
        field.Int("count_t08"),
        field.Int("score_t08"),
        field.Enum("status_t08", &.{ "a", "b", "c" }),
        field.Bool("active_t08"),
        field.Time("created_at_t08"),
        field.JSON("settings_t08", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t08"})},
});

const T09Base = Schema("T09", .{
    .fields = &.{
        field.String("name_t09"),
        field.String("code_t09"),
        field.Int("count_t09"),
        field.Int("score_t09"),
        field.Enum("status_t09", &.{ "a", "b", "c" }),
        field.Bool("active_t09"),
        field.Time("created_at_t09"),
        field.JSON("settings_t09", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t09"})},
});

const T10Base = Schema("T10", .{
    .fields = &.{
        field.String("name_t10"),
        field.String("code_t10"),
        field.Int("count_t10"),
        field.Int("score_t10"),
        field.Enum("status_t10", &.{ "a", "b", "c" }),
        field.Bool("active_t10"),
        field.Time("created_at_t10"),
        field.JSON("settings_t10", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t10"})},
});

const T11Base = Schema("T11", .{
    .fields = &.{
        field.String("name_t11"),
        field.String("code_t11"),
        field.Int("count_t11"),
        field.Int("score_t11"),
        field.Enum("status_t11", &.{ "a", "b", "c" }),
        field.Bool("active_t11"),
        field.Time("created_at_t11"),
        field.JSON("settings_t11", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t11"})},
});

const T12Base = Schema("T12", .{
    .fields = &.{
        field.String("name_t12"),
        field.String("code_t12"),
        field.Int("count_t12"),
        field.Int("score_t12"),
        field.Enum("status_t12", &.{ "a", "b", "c" }),
        field.Bool("active_t12"),
        field.Time("created_at_t12"),
        field.JSON("settings_t12", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t12"})},
});

const T13Base = Schema("T13", .{
    .fields = &.{
        field.String("name_t13"),
        field.String("code_t13"),
        field.Int("count_t13"),
        field.Int("score_t13"),
        field.Enum("status_t13", &.{ "a", "b", "c" }),
        field.Bool("active_t13"),
        field.Time("created_at_t13"),
        field.JSON("settings_t13", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t13"})},
});

const T14Base = Schema("T14", .{
    .fields = &.{
        field.String("name_t14"),
        field.String("code_t14"),
        field.Int("count_t14"),
        field.Int("score_t14"),
        field.Enum("status_t14", &.{ "a", "b", "c" }),
        field.Bool("active_t14"),
        field.Time("created_at_t14"),
        field.JSON("settings_t14", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t14"})},
});

const T15Base = Schema("T15", .{
    .fields = &.{
        field.String("name_t15"),
        field.String("code_t15"),
        field.Int("count_t15"),
        field.Int("score_t15"),
        field.Enum("status_t15", &.{ "a", "b", "c" }),
        field.Bool("active_t15"),
        field.Time("created_at_t15"),
        field.JSON("settings_t15", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t15"})},
});

const T16Base = Schema("T16", .{
    .fields = &.{
        field.String("name_t16"),
        field.String("code_t16"),
        field.Int("count_t16"),
        field.Int("score_t16"),
        field.Enum("status_t16", &.{ "a", "b", "c" }),
        field.Bool("active_t16"),
        field.Time("created_at_t16"),
        field.JSON("settings_t16", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t16"})},
});

const T17Base = Schema("T17", .{
    .fields = &.{
        field.String("name_t17"),
        field.String("code_t17"),
        field.Int("count_t17"),
        field.Int("score_t17"),
        field.Enum("status_t17", &.{ "a", "b", "c" }),
        field.Bool("active_t17"),
        field.Time("created_at_t17"),
        field.JSON("settings_t17", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t17"})},
});

const T18Base = Schema("T18", .{
    .fields = &.{
        field.String("name_t18"),
        field.String("code_t18"),
        field.Int("count_t18"),
        field.Int("score_t18"),
        field.Enum("status_t18", &.{ "a", "b", "c" }),
        field.Bool("active_t18"),
        field.Time("created_at_t18"),
        field.JSON("settings_t18", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t18"})},
});

const T19Base = Schema("T19", .{
    .fields = &.{
        field.String("name_t19"),
        field.String("code_t19"),
        field.Int("count_t19"),
        field.Int("score_t19"),
        field.Enum("status_t19", &.{ "a", "b", "c" }),
        field.Bool("active_t19"),
        field.Time("created_at_t19"),
        field.JSON("settings_t19", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t19"})},
});

const T20Base = Schema("T20", .{
    .fields = &.{
        field.String("name_t20"),
        field.String("code_t20"),
        field.Int("count_t20"),
        field.Int("score_t20"),
        field.Enum("status_t20", &.{ "a", "b", "c" }),
        field.Bool("active_t20"),
        field.Time("created_at_t20"),
        field.JSON("settings_t20", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t20"})},
});

const T21Base = Schema("T21", .{
    .fields = &.{
        field.String("name_t21"),
        field.String("code_t21"),
        field.Int("count_t21"),
        field.Int("score_t21"),
        field.Enum("status_t21", &.{ "a", "b", "c" }),
        field.Bool("active_t21"),
        field.Time("created_at_t21"),
        field.JSON("settings_t21", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t21"})},
});

const T22Base = Schema("T22", .{
    .fields = &.{
        field.String("name_t22"),
        field.String("code_t22"),
        field.Int("count_t22"),
        field.Int("score_t22"),
        field.Enum("status_t22", &.{ "a", "b", "c" }),
        field.Bool("active_t22"),
        field.Time("created_at_t22"),
        field.JSON("settings_t22", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t22"})},
});

const T23Base = Schema("T23", .{
    .fields = &.{
        field.String("name_t23"),
        field.String("code_t23"),
        field.Int("count_t23"),
        field.Int("score_t23"),
        field.Enum("status_t23", &.{ "a", "b", "c" }),
        field.Bool("active_t23"),
        field.Time("created_at_t23"),
        field.JSON("settings_t23", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t23"})},
});

const T24Base = Schema("T24", .{
    .fields = &.{
        field.String("name_t24"),
        field.String("code_t24"),
        field.Int("count_t24"),
        field.Int("score_t24"),
        field.Enum("status_t24", &.{ "a", "b", "c" }),
        field.Bool("active_t24"),
        field.Time("created_at_t24"),
        field.JSON("settings_t24", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t24"})},
});

const T25Base = Schema("T25", .{
    .fields = &.{
        field.String("name_t25"),
        field.String("code_t25"),
        field.Int("count_t25"),
        field.Int("score_t25"),
        field.Enum("status_t25", &.{ "a", "b", "c" }),
        field.Bool("active_t25"),
        field.Time("created_at_t25"),
        field.JSON("settings_t25", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t25"})},
});

const T26Base = Schema("T26", .{
    .fields = &.{
        field.String("name_t26"),
        field.String("code_t26"),
        field.Int("count_t26"),
        field.Int("score_t26"),
        field.Enum("status_t26", &.{ "a", "b", "c" }),
        field.Bool("active_t26"),
        field.Time("created_at_t26"),
        field.JSON("settings_t26", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t26"})},
});

const T27Base = Schema("T27", .{
    .fields = &.{
        field.String("name_t27"),
        field.String("code_t27"),
        field.Int("count_t27"),
        field.Int("score_t27"),
        field.Enum("status_t27", &.{ "a", "b", "c" }),
        field.Bool("active_t27"),
        field.Time("created_at_t27"),
        field.JSON("settings_t27", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t27"})},
});

const T28Base = Schema("T28", .{
    .fields = &.{
        field.String("name_t28"),
        field.String("code_t28"),
        field.Int("count_t28"),
        field.Int("score_t28"),
        field.Enum("status_t28", &.{ "a", "b", "c" }),
        field.Bool("active_t28"),
        field.Time("created_at_t28"),
        field.JSON("settings_t28", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t28"})},
});

const T29Base = Schema("T29", .{
    .fields = &.{
        field.String("name_t29"),
        field.String("code_t29"),
        field.Int("count_t29"),
        field.Int("score_t29"),
        field.Enum("status_t29", &.{ "a", "b", "c" }),
        field.Bool("active_t29"),
        field.Time("created_at_t29"),
        field.JSON("settings_t29", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t29"})},
});

const T30Base = Schema("T30", .{
    .fields = &.{
        field.String("name_t01"),
        field.String("code_t01"),
        field.Int("count_t01"),
        field.Int("score_t01"),
        field.Enum("status_t01", &.{ "a", "b", "c" }),
        field.Bool("active_t01"),
        field.Time("created_at_t01"),
        field.JSON("settings_t01", Settings),
    },
    .indexes = &.{index.Fields(&.{"code_t01"})},
});

// One O2M edge pair (T01 -> T02) exercises edge codegen at scale without
// cross-referenced FK columns on every table (a full ring would add a
// NOT NULL t{i-1}_id to each table).
const T01 = withEdges(T01Base, &.{edge.To("t02_items", T02Base)});
const T02 = withEdges(T02Base, &.{edge.From("t01", T01Base).Ref("t02_items")});
const T03 = T03Base;
const T04 = T04Base;
const T05 = T05Base;
const T06 = T06Base;
const T07 = T07Base;
const T08 = T08Base;
const T09 = T09Base;
const T10 = T10Base;
const T11 = T11Base;
const T12 = T12Base;
const T13 = T13Base;
const T14 = T14Base;
const T15 = T15Base;
const T16 = T16Base;
const T17 = T17Base;
const T18 = T18Base;
const T19 = T19Base;
const T20 = T20Base;
const T21 = T21Base;
const T22 = T22Base;
const T23 = T23Base;
const T24 = T24Base;
const T25 = T25Base;
const T26 = T26Base;
const T27 = T27Base;
const T28 = T28Base;
const T29 = T29Base;
const T30 = T30Base;
test "stress: 30 tables compile and basic CRUD works" {
    const allocator = testing.allocator;
    const graph = comptime buildGraph(&.{ T01, T02, T03, T04, T05, T06, T07, T08, T09, T10, T11, T12, T13, T14, T15, T16, T17, T18, T19, T20, T21, T22, T23, T24, T25, T26, T27, T28, T29, T30 });
    const infos = graph.types;
    try testing.expectEqual(@as(usize, 30), infos.len);

    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    try Client.createAllTables(infos, drv.asDriver());
    var client = Client.makeClient(infos, allocator, drv.asDriver());

    // CRUD smoke on T01 (O2M origin; no cross-referenced FK column).
    var b = try client.t01.Create();
    defer b.deinit();
    _ = try b.setFieldValue("name_t01", "x");
    _ = try b.setFieldValue("code_t01", "c1");
    _ = try b.setFieldValue("count_t01", 1);
    _ = try b.setFieldValue("score_t01", 2);
    _ = try b.setFieldValue("status_t01", "a");
    _ = try b.setFieldValue("active_t01", true);
    _ = try b.setFieldValue("created_at_t01", @as(i64, 0));
    _ = try b.setFieldValue("settings_t01", Settings{ .theme = "dark", .notifications = true });
    var saved = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &saved, allocator);
    try testing.expectEqual(@as(i64, 1), saved.id);
}
