//! E-commerce domain schema for the complex example.
//!
//! Entities:
//!   Customer  ──O2M──► Order  ──O2M──► OrderItem ◄──M2O── Product ◄──M2M──► Tag
//!
//! Demonstrates: M2M via junction table, O2M/M2O edges, hooks,
//! soft-delete, privacy policy, enums, floats, boolean fields.

const std = @import("std");
const zent = @import("zent");
const field = zent.core.field;
const edge = zent.core.edge;
const Schema = zent.core.schema.Schema;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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

fn activeOnly(op: zent.privacy.Op, _: []const u8) zent.privacy.Decision {
    return if (op == .query) .allow else .allow;
}

// ---------------------------------------------------------------------------
// Schema definitions
// ---------------------------------------------------------------------------

pub const CustomerBase = Schema("Customer", .{
    .fields = &.{
        field.String("name"),
        field.String("email"),
        field.Float("balance").Default("0.0"),
        field.Bool("is_active").Default("true"),
    },
    .indexes = &.{
        zent.core.index.Fields(&.{"email"}),
    },
});

pub const ProductBase = Schema("Product", .{
    .fields = &.{
        field.String("name"),
        field.Float("price"),
        field.Int("stock").Default("0"),
        field.String("description").Default(""),
    },
});

pub const OrderStatus = enum {
    pending,
    shipped,
    delivered,
    cancelled,
};

pub const OrderBase = Schema("Order", .{
    .fields = &.{
        field.Float("total"),
        field.Enum("status", &.{ "pending", "shipped", "delivered", "cancelled" }),
        field.Time("created_at"),
    },
});

pub const OrderItemBase = Schema("OrderItem", .{
    .fields = &.{
        field.Int("quantity"),
    },
});

pub const TagBase = Schema("Tag", .{
    .fields = &.{
        field.String("value"),
    },
});

// ---------------------------------------------------------------------------
// Edges
// ---------------------------------------------------------------------------

pub const Tag = withEdges(TagBase, &.{
    edge.To("products", ProductBase),
});

pub const Product = withEdges(ProductBase, &.{
    edge.To("tags", TagBase),
    edge.To("orderItems", OrderItemBase),
});

pub const OrderItem = withEdges(OrderItemBase, &.{
    edge.From("order", OrderBase).Ref("items"),
    edge.From("product", ProductBase).Ref("orderItems"),
});

pub const Order = withEdges(OrderBase, &.{
    edge.From("customer", CustomerBase).Ref("orders"),
    edge.To("items", OrderItemBase).Ref("order"),
});

pub const Customer = withEdges(CustomerBase, &.{
    edge.To("orders", OrderBase).Ref("customer"),
});
