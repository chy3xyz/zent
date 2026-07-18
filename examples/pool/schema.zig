const field = @import("zent").core.field;
const Schema = @import("zent").core.schema.Schema;

pub const User = Schema("User", .{
    .fields = &.{
        field.String("name"),
        field.Int("age"),
    },
});
