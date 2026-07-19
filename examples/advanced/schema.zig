const zent = @import("zent");
const Schema = zent.core.schema.Schema;

pub const department = Schema("Department", .{
    .fields = &.{
        zent.core.field.Int("id"),
        zent.core.field.String("name").Unique(),
        zent.core.field.Float("budget"),
    },
});

pub const employee = Schema("Employee", .{
    .fields = &.{
        zent.core.field.Int("id"),
        zent.core.field.String("name"),
        zent.core.field.Float("salary"),
        zent.core.field.Time("hired_at"),
        zent.core.field.Enum("level", &.{ "junior", "mid", "senior", "lead", "principal" }),
        zent.core.field.String("ssn").Sensitive(),
        zent.core.field.Int("tenant_id"),
    },
    .edges = &.{
        zent.core.edge.To("department", department).Ref("department_id").Unique(),
        zent.core.edge.To("projects", project),
    },
    .indexes = &.{
        zent.core.index.Fields(&.{"salary"}),
        zent.core.index.Fields(&.{ "level", "department_id" }),
    },
    .annotations = &.{
        .{ .key = "owner", .value = "hr-platform" },
        .{ .key = "data_classification", .value = "pii" },
    },
});

pub const project = Schema("Project", .{
    .fields = &.{
        zent.core.field.Int("id"),
        zent.core.field.String("name").Unique(),
        zent.core.field.Float("budget"),
        zent.core.field.Time("deadline"),
        zent.core.field.Enum("status", &.{ "planning", "active", "on_hold", "completed", "cancelled" }),
    },
    .edges = &.{
        zent.core.edge.To("department", department).Ref("department_id").Unique(),
    },
});

pub const task = Schema("Task", .{
    .fields = &.{
        zent.core.field.Int("id"),
        zent.core.field.String("title"),
        zent.core.field.Bool("completed"),
        zent.core.field.Int("priority"),
    },
    .edges = &.{
        zent.core.edge.To("project", project).Ref("project_id").Unique(),
        zent.core.edge.To("assignee", employee).Ref("assignee_id"),
    },
});
