const std = @import("std");
const zent = @import("zent");
const field = zent.core.field;
const edge = zent.core.edge;
const Schema = zent.core.schema.Schema;

pub const UserSettings = struct {
    theme: []const u8,
    notifications: bool,
};

fn denyDelete(op: zent.privacy.Op, _: []const u8) zent.privacy.Decision {
    return if (op == .delete) .deny else .allow;
}

fn withEdges(comptime Base: type, comptime es: []const edge.Edge) type {
    return struct {
        pub const schema_name = Base.schema_name;
        pub const fields = Base.fields;
        pub const edges = es;
        pub const indexes = Base.indexes;
        pub const policy = if (@hasDecl(Base, "policy")) Base.policy else null;
    };
}

const CarBase = Schema("Car", .{
    .fields = &.{
        field.String("model"),
        field.Time("registered_at"),
    },
});

const GroupBase = Schema("Group", .{
    .fields = &.{
        field.String("name"),
    },
});

const UserBase = Schema("User", .{
    .fields = &.{
        field.Int("age").Positive(),
        field.String("name").Default("unknown"),
        field.Enum("status", &.{ "active", "inactive" }),
        field.JSON("settings", UserSettings),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
    .policy = zent.privacy.Policy{
        .mutation = denyDelete,
    },
});

pub const ActiveUserView = Schema("ActiveUserView", .{
    .view = true,
    .view_sql = "SELECT id, name, age, status, settings, created_at, updated_at FROM user WHERE status = 'active'",
    .fields = &.{
        field.Int("age"),
        field.String("name"),
        field.Enum("status", &.{ "active", "inactive" }),
        field.JSON("settings", UserSettings),
    },
    .mixins = &.{zent.core.mixin.TimeMixin},
});

// M2M is declared with To on both sides.
// O2M is declared with To on the "one" side and From on the "many" side.
pub const Car = withEdges(CarBase, &.{edge.From("owner", UserBase).Ref("cars")});
pub const Group = withEdges(GroupBase, &.{edge.To("users", UserBase)});
pub const User = withEdges(UserBase, &.{ edge.To("cars", Car), edge.To("groups", GroupBase) });
