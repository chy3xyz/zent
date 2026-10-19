//! The compile-time IR: what a schema becomes once it is flattened for codegen.
//!
//! `codegen/graph.zig` *builds* these (`fromSchema`, `buildGraph`); this module
//! only *declares* them. They live here because they are the one thing the two
//! consumers share — the code generators import the builder, and
//! `graph/mermaid.zig` / `graph/doc_exporter.zig` render a graph from the IR
//! alone — and keeping the declaration inside the builder made those two import
//! it, which is what turned `codegen` and `graph` into a cycle.
//!
//! No logic beyond the tiny per-field helpers (`sqlType`), and no dependency on
//! either consumer: only `base`, `core`, `privacy`.

const field_mod = @import("core/field.zig");
const edge_mod = @import("core/edge.zig");
const Dialect = @import("base/dialect.zig").Dialect;
const Policy = @import("privacy/policy.zig").Policy;
const Annotation = @import("core/schema.zig").Annotation;
const value = @import("base/value.zig");

pub const FieldInfo = struct {
    /// Zig struct field name. Used for `@field(entity, name)` access and as
    /// the argument users pass to the fluent API (`setFieldValue`, typed
    /// predicates, `Select`, interceptors' `whereEq`, …). This is NOT the SQL
    /// column name.
    name: []const u8,
    /// SQL column name. Equals `name` unless the schema declared
    /// `.StorageKey("...")` on the field. Every SQL identifier the codegen
    /// emits (INSERT column lists, UPDATE SET, WHERE/ORDER BY/GROUP BY,
    /// DDL columns, indexes) MUST use `column_name`, never `name`.
    column_name: []const u8,
    field_type: field_mod.FieldType,
    zig_type: type,
    /// Legacy SQLite-oriented type string retained for API compatibility.
    /// Migration SQL must call `sqlType` with the active dialect.
    sql_type: []const u8,
    /// Explicit type declared by `.SqlType(s)` / `field.Other(name, s)`, null
    /// when the schema declared none. Carried beside `sql_type` because the
    /// override applies on PostgreSQL only and `sql_type` is resolved once, for
    /// the dialect the graph was built with — `migrate.columnSQLType` needs the
    /// declaration itself to resolve it against the *run-time* dialect.
    sql_type_override: ?[]const u8 = null,
    optional: bool,
    nillable: bool,
    unique: bool,
    immutable: bool,
    default: field_mod.DefaultValue,
    validators: []const field_mod.Validator,
    enum_values: []const []const u8,
    is_id: bool,
    is_version: bool = false,
    sensitive: bool = false,
    /// Declared maximum string length (`field.VarChar(n)`), null when the
    /// schema declared none. Consumed by `create.validateSqlValue` as the
    /// write-path ceiling and by the DDL resolution below (`VARCHAR(n)` on
    /// MySQL instead of the default `VARCHAR(255)`).
    max_length: ?usize = null,
    /// Declared dimension of a `field.Vector` column (`vector(n)`), null on
    /// every other kind. Consumed by `sqlType` below (PostgreSQL's
    /// `vector(n)`), by the migration's `ColumnDef.vector_sql`, and by the
    /// write path's element-count check.
    vector_dims: ?usize = null,

    pub fn sqlType(comptime self: FieldInfo, dialect: Dialect) []const u8 {
        return field_mod.sqlTypeResolved(self.field_type, self.max_length, self.vector_dims, self.sql_type_override, dialect);
    }
};

pub const EdgeInfo = struct {
    name: []const u8,
    target: type,
    target_name: []const u8,
    kind: edge_mod.EdgeKind,
    relation: edge_mod.Relation,
    unique: bool,
    required: bool,
    immutable: bool,
    ref: ?[]const u8,
    field_name: ?[]const u8,
    inverse_name: ?[]const u8,
    through: ?type,
    through_name: ?[]const u8,
    order_by: ?[]const u8 = null,
    desc: bool = false,
    limit: ?usize = null,
    filter: ?value.Filter = null,
};

pub const IndexInfo = struct {
    name: []const u8,
    columns: []const []const u8,
    unique: bool,
    /// `Index.method` / `Index.opclass` carried through verbatim — the DDL
    /// layer is the one that decides which dialect renders them, and it runs
    /// against a driver whose dialect need not be the one this graph was built
    /// with (see `migrate.IndexDef.method`). `null` keeps the `CREATE INDEX`
    /// byte-for-byte what it was before the declaration existed.
    method: ?[]const u8 = null,
    opclass: ?[]const u8 = null,
};

pub const TypeInfo = struct {
    name: []const u8,
    table_name: []const u8,
    /// Primary-key field name. Defaults to `"id"`; schemas with a custom PK
    /// (e.g. `push_id`) declare it via `Schema(..., .pk = "push_id")`.
    pk_field: []const u8 = "id",
    fields: []const FieldInfo,
    edges: []const EdgeInfo,
    indexes: []const IndexInfo,
    policy: ?Policy = null,
    is_view: bool = false,
    view_sql: ?[]const u8 = null,
    soft_delete: bool = false,
    annotations: []const Annotation = &.{},
};
