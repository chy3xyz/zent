const zent = @import("zent");
const field = zent.core.field;
const edge = zent.core.edge;
const Schema = zent.core.schema.Schema;

fn withEdges(comptime Base: type, comptime es: []const edge.Edge) type {
    return struct {
        pub const schema_name = Base.schema_name;
        pub const fields = Base.fields;
        pub const edges = es;
        pub const indexes = Base.indexes;
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
    },
});

// Note: Car.From references User with .Ref("cars") which points to UserBase's edge name.
// The edge resolution looks up the "cars" edge on the target type (UserBase).
// Since UserBase doesn't have edges defined, the relation falls back to defaults.
pub const Car = withEdges(CarBase, &.{edge.From("owner", UserBase).Ref("cars").Unique()});
pub const Group = withEdges(GroupBase, &.{edge.To("users", UserBase)});
pub const User = withEdges(UserBase, &.{ edge.To("cars", Car), edge.From("groups", Group).Ref("users") });
