const std = @import("std");
const Dialect = @import("dialect.zig").Dialect;

/// A value that can be passed as a SQL argument.
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    bytes: []const u8,
};

pub const QueryResult = struct {
    sql: []const u8,
    args: []const Value,
};

/// Base query builder. Tracks the SQL string and bound arguments.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    buffer: std.array_list.Managed(u8),
    args: std.array_list.Managed(Value),
    dialect: Dialect,

    pub fn init(allocator: std.mem.Allocator, dialect: Dialect) Builder {
        return .{
            .allocator = allocator,
            .buffer = std.array_list.Managed(u8).init(allocator),
            .args = std.array_list.Managed(Value).init(allocator),
            .dialect = dialect,
        };
    }

    pub fn deinit(b: *Builder) void {
        b.buffer.deinit();
        b.args.deinit();
    }

    pub fn query(b: *const Builder) QueryResult {
        return .{ .sql = b.buffer.items, .args = b.args.items };
    }

    pub fn writeString(b: *Builder, s: []const u8) !void {
        try b.buffer.appendSlice(s);
    }

    pub fn writeByte(b: *Builder, byte: u8) !void {
        try b.buffer.append(byte);
    }

    pub fn ident(b: *Builder, name: []const u8) !void {
        try b.dialect.quoteIdent(b.buffer.writer(), name);
    }

    pub fn arg(b: *Builder, value: Value) !void {
        try b.args.append(value);
        const idx = b.args.items.len;
        var buf: [16]u8 = undefined;
        const ph = try b.dialect.placeholder(&buf, idx);
        try b.buffer.appendSlice(ph);
    }

    pub fn pad(b: *Builder) !void {
        if (b.buffer.items.len == 0) return;
        if (b.buffer.items[b.buffer.items.len - 1] != ' ') {
            try b.buffer.append(' ');
        }
    }

    pub fn wrap(b: *Builder, comptime f: fn (*Builder) anyerror!void) !void {
        try b.writeByte('(');
        try f(b);
        try b.writeByte(')');
    }

    pub fn join(b: *Builder, sep: []const u8, nodes: anytype) !void {
        const info = @typeInfo(@TypeOf(nodes));
        if (info != .@"struct" or !info.@"struct".is_tuple) {
            @compileError("join expects a tuple of nodes");
        }
        inline for (info.@"struct".fields, 0..) |_, i| {
            if (i > 0) try b.writeString(sep);
            const node = nodes[i];
            try node.appendTo(b);
        }
    }

    pub fn joinComma(b: *Builder, nodes: anytype) !void {
        try b.join(", ", nodes);
    }
};

// ------------------------------------------------------------------
// Table / Column
// ------------------------------------------------------------------

pub const TableBuilder = struct {
    name: []const u8,
    schema: ?[]const u8 = null,

    pub fn c(self: TableBuilder, column: []const u8) ColumnRef {
        return .{ .table = self.name, .name = column };
    }

    pub fn appendTo(self: TableBuilder, b: *Builder) !void {
        if (self.schema) |s| {
            try b.ident(s);
            try b.writeByte('.');
        }
        try b.ident(self.name);
    }
};

pub fn Table(name: []const u8) TableBuilder {
    return .{ .name = name };
}

pub const ColumnRef = struct {
    table: ?[]const u8,
    name: []const u8,
    raw: bool = false,

    pub fn appendTo(self: ColumnRef, b: *Builder) !void {
        if (self.table) |t| {
            try b.ident(t);
            try b.writeByte('.');
        }
        if (self.raw) {
            try b.writeString(self.name);
        } else {
            try b.ident(self.name);
        }
    }
};

// ------------------------------------------------------------------
// Predicate
// ------------------------------------------------------------------

pub const Predicate = union(enum) {
    eq: BinOp,
    ne: BinOp,
    gt: BinOp,
    lt: BinOp,
    gte: BinOp,
    lte: BinOp,
    like: BinOp,
    in: InOp,
    is_null: []const u8,
    is_not_null: []const u8,
    raw: []const u8,
    in_subquery: struct { column: []const u8, sql: []const u8 },
    exists_subquery: []const u8,
    and_: struct { left: *const Predicate, right: *const Predicate },
    or_: struct { left: *const Predicate, right: *const Predicate },
    not_: *const Predicate,

    pub const BinOp = struct { column: []const u8, value: Value };
    pub const InOp = struct { column: []const u8, values: []const Value };

    pub fn appendTo(self: Predicate, b: *Builder) !void {
        switch (self) {
            .eq => |p| {
                try b.ident(p.column);
                try b.writeString(" = ");
                try b.arg(p.value);
            },
            .ne => |p| {
                try b.ident(p.column);
                try b.writeString(" <> ");
                try b.arg(p.value);
            },
            .gt => |p| {
                try b.ident(p.column);
                try b.writeString(" > ");
                try b.arg(p.value);
            },
            .lt => |p| {
                try b.ident(p.column);
                try b.writeString(" < ");
                try b.arg(p.value);
            },
            .gte => |p| {
                try b.ident(p.column);
                try b.writeString(" >= ");
                try b.arg(p.value);
            },
            .lte => |p| {
                try b.ident(p.column);
                try b.writeString(" <= ");
                try b.arg(p.value);
            },
            .like => |p| {
                try b.ident(p.column);
                try b.writeString(" LIKE ");
                try b.arg(p.value);
            },
            .in => |p| {
                try b.ident(p.column);
                try b.writeString(" IN ");
                try b.writeByte('(');
                for (p.values, 0..) |v, i| {
                    if (i > 0) try b.writeString(", ");
                    try b.arg(v);
                }
                try b.writeByte(')');
            },
            .is_null => |col| {
                try b.ident(col);
                try b.writeString(" IS NULL");
            },
            .is_not_null => |col| {
                try b.ident(col);
                try b.writeString(" IS NOT NULL");
            },
            .raw => |sql_text| {
                try b.writeString(sql_text);
            },
            .in_subquery => |p| {
                try b.ident(p.column);
                try b.writeString(" IN (");
                try b.writeString(p.sql);
                try b.writeByte(')');
            },
            .exists_subquery => |sql_text| {
                try b.writeString("EXISTS (");
                try b.writeString(sql_text);
                try b.writeByte(')');
            },
            .and_ => |p| {
                try b.writeByte('(');
                try p.left.appendTo(b);
                try b.writeString(" AND ");
                try p.right.appendTo(b);
                try b.writeByte(')');
            },
            .or_ => |p| {
                try b.writeByte('(');
                try p.left.appendTo(b);
                try b.writeString(" OR ");
                try p.right.appendTo(b);
                try b.writeByte(')');
            },
            .not_ => |p| {
                try b.writeString("NOT ");
                try p.appendTo(b);
            },
        }
    }
};

pub fn EQ(column: []const u8, value: Value) Predicate {
    return .{ .eq = .{ .column = column, .value = value } };
}

pub fn NE(column: []const u8, value: Value) Predicate {
    return .{ .ne = .{ .column = column, .value = value } };
}

pub fn GT(column: []const u8, value: Value) Predicate {
    return .{ .gt = .{ .column = column, .value = value } };
}

pub fn LT(column: []const u8, value: Value) Predicate {
    return .{ .lt = .{ .column = column, .value = value } };
}

pub fn GTE(column: []const u8, value: Value) Predicate {
    return .{ .gte = .{ .column = column, .value = value } };
}

pub fn LTE(column: []const u8, value: Value) Predicate {
    return .{ .lte = .{ .column = column, .value = value } };
}

pub fn Like(column: []const u8, value: Value) Predicate {
    return .{ .like = .{ .column = column, .value = value } };
}

pub fn In(column: []const u8, values: []const Value) Predicate {
    return .{ .in = .{ .column = column, .values = values } };
}

pub fn IsNull(column: []const u8) Predicate {
    return .{ .is_null = column };
}

pub fn IsNotNull(column: []const u8) Predicate {
    return .{ .is_not_null = column };
}

pub fn And(left: *const Predicate, right: *const Predicate) Predicate {
    return .{ .and_ = .{ .left = left, .right = right } };
}

pub fn Or(left: *const Predicate, right: *const Predicate) Predicate {
    return .{ .or_ = .{ .left = left, .right = right } };
}

pub fn Not(pred: *const Predicate) Predicate {
    return .{ .not_ = pred };
}

pub fn Raw(sql_text: []const u8) Predicate {
    return .{ .raw = sql_text };
}

pub fn InSubquery(column: []const u8, sql_text: []const u8) Predicate {
    return .{ .in_subquery = .{ .column = column, .sql = sql_text } };
}

pub fn ExistsSubquery(sql_text: []const u8) Predicate {
    return .{ .exists_subquery = sql_text };
}

// ------------------------------------------------------------------
// Order
// ------------------------------------------------------------------

pub const Order = struct {
    column: []const u8,
    desc: bool = false,

    pub fn appendTo(self: Order, b: *Builder) !void {
        try b.ident(self.column);
        if (self.desc) {
            try b.writeString(" DESC");
        } else {
            try b.writeString(" ASC");
        }
    }
};

// ------------------------------------------------------------------
// Join
// ------------------------------------------------------------------

pub const JoinKind = enum {
    inner,
    left,
    right,
    full,
};

pub const Join = struct {
    kind: JoinKind,
    table: TableBuilder,
    on: Predicate,

    pub fn appendTo(self: Join, b: *Builder) !void {
        switch (self.kind) {
            .inner => try b.writeString("INNER JOIN "),
            .left => try b.writeString("LEFT JOIN "),
            .right => try b.writeString("RIGHT JOIN "),
            .full => try b.writeString("FULL JOIN "),
        }
        try self.table.appendTo(b);
        try b.writeString(" ON ");
        try self.on.appendTo(b);
    }
};

// ------------------------------------------------------------------
// SELECT
// ------------------------------------------------------------------

pub const Selector = struct {
    b: Builder,
    columns: std.array_list.Managed(ColumnRef),
    table: ?TableBuilder,
    joins: std.array_list.Managed(Join),
    predicates: std.array_list.Managed(Predicate),
    group_cols: std.array_list.Managed([]const u8),
    having_pred: ?Predicate,
    order_terms: std.array_list.Managed(Order),
    limit_val: ?usize,
    offset_val: ?usize,
    distinct: bool,

    pub fn init(allocator: std.mem.Allocator, dialect: Dialect, columns: []const ColumnRef) Selector {
        var s = Selector{
            .b = Builder.init(allocator, dialect),
            .columns = std.array_list.Managed(ColumnRef).init(allocator),
            .table = null,
            .joins = std.array_list.Managed(Join).init(allocator),
            .predicates = std.array_list.Managed(Predicate).init(allocator),
            .group_cols = std.array_list.Managed([]const u8).init(allocator),
            .having_pred = null,
            .order_terms = std.array_list.Managed(Order).init(allocator),
            .limit_val = null,
            .offset_val = null,
            .distinct = false,
        };
        s.columns.appendSlice(columns) catch unreachable;
        return s;
    }

    pub fn deinit(s: *Selector) void {
        s.b.deinit();
        s.columns.deinit();
        s.joins.deinit();
        s.predicates.deinit();
        s.group_cols.deinit();
        s.order_terms.deinit();
    }

    pub fn from(s: *Selector, table: TableBuilder) *Selector {
        s.table = table;
        return s;
    }

    pub fn join(s: *Selector, j: Join) *Selector {
        s.joins.append(j) catch unreachable;
        return s;
    }

    pub fn where(s: *Selector, pred: Predicate) *Selector {
        s.predicates.append(pred) catch unreachable;
        return s;
    }

    pub fn groupBy(s: *Selector, columns: []const []const u8) *Selector {
        s.group_cols.appendSlice(columns) catch unreachable;
        return s;
    }

    pub fn having(s: *Selector, pred: Predicate) *Selector {
        s.having_pred = pred;
        return s;
    }

    pub fn orderBy(s: *Selector, o: Order) *Selector {
        s.order_terms.append(o) catch unreachable;
        return s;
    }

    pub fn limit(s: *Selector, n: usize) *Selector {
        s.limit_val = n;
        return s;
    }

    pub fn offset(s: *Selector, n: usize) *Selector {
        s.offset_val = n;
        return s;
    }

    pub fn setDistinct(s: *Selector, d: bool) *Selector {
        s.distinct = d;
        return s;
    }

    pub fn query(s: *Selector) !QueryResult {
        try s.b.writeString("SELECT ");
        if (s.distinct) try s.b.writeString("DISTINCT ");
        for (s.columns.items, 0..) |col, i| {
            if (i > 0) try s.b.writeString(", ");
            try col.appendTo(&s.b);
        }
        if (s.table) |t| {
            try s.b.writeString(" FROM ");
            try t.appendTo(&s.b);
        }
        for (s.joins.items) |j| {
            try s.b.writeByte(' ');
            try j.appendTo(&s.b);
        }
        if (s.predicates.items.len > 0) {
            try s.b.writeString(" WHERE ");
            for (s.predicates.items, 0..) |pred, i| {
                if (i > 0) try s.b.writeString(" AND ");
                try pred.appendTo(&s.b);
            }
        }
        if (s.group_cols.items.len > 0) {
            try s.b.writeString(" GROUP BY ");
            for (s.group_cols.items, 0..) |col, i| {
                if (i > 0) try s.b.writeString(", ");
                try s.b.ident(col);
            }
        }
        if (s.having_pred) |pred| {
            try s.b.writeString(" HAVING ");
            try pred.appendTo(&s.b);
        }
        if (s.order_terms.items.len > 0) {
            try s.b.writeString(" ORDER BY ");
            for (s.order_terms.items, 0..) |o, i| {
                if (i > 0) try s.b.writeString(", ");
                try o.appendTo(&s.b);
            }
        }
        if (s.limit_val) |n| {
            try s.b.writeString(" LIMIT ");
            try s.b.writeString(try std.fmt.allocPrint(s.b.allocator, "{d}", .{n}));
        }
        if (s.offset_val) |n| {
            try s.b.writeString(" OFFSET ");
            try s.b.writeString(try std.fmt.allocPrint(s.b.allocator, "{d}", .{n}));
        }
        const bq = s.b.query();
        return .{ .sql = bq.sql, .args = bq.args };
    }
};

pub fn Select(allocator: std.mem.Allocator, dialect: Dialect, columns: []const ColumnRef) Selector {
    return Selector.init(allocator, dialect, columns);
}

// ------------------------------------------------------------------
// INSERT
// ------------------------------------------------------------------

pub const InsertBuilder = struct {
    b: Builder,
    table: []const u8,
    col_names: std.array_list.Managed([]const u8),
    rows: std.array_list.Managed(std.array_list.Managed(Value)),

    pub fn init(allocator: std.mem.Allocator, dialect: Dialect, table: []const u8) InsertBuilder {
        return .{
            .b = Builder.init(allocator, dialect),
            .table = table,
            .col_names = std.array_list.Managed([]const u8).init(allocator),
            .rows = std.array_list.Managed(std.array_list.Managed(Value)).init(allocator),
        };
    }

    pub fn deinit(i: *InsertBuilder) void {
        i.b.deinit();
        i.col_names.deinit();
        for (i.rows.items) |*row| row.deinit();
        i.rows.deinit();
    }

    pub fn columns(i: *InsertBuilder, cols: []const []const u8) *InsertBuilder {
        i.col_names.appendSlice(cols) catch unreachable;
        return i;
    }

    pub fn values(i: *InsertBuilder, row: []const Value) *InsertBuilder {
        var list = std.array_list.Managed(Value).init(i.b.allocator);
        list.appendSlice(row) catch unreachable;
        i.rows.append(list) catch unreachable;
        return i;
    }

    pub fn query(i: *InsertBuilder) !QueryResult {
        try i.b.writeString("INSERT INTO ");
        try i.b.ident(i.table);
        if (i.col_names.items.len > 0) {
            try i.b.writeString(" (");
            for (i.col_names.items, 0..) |col, idx| {
                if (idx > 0) try i.b.writeString(", ");
                try i.b.ident(col);
            }
            try i.b.writeByte(')');
        }
        try i.b.writeString(" VALUES ");
        for (i.rows.items, 0..) |row, ri| {
            if (ri > 0) try i.b.writeString(", ");
            try i.b.writeByte('(');
            for (row.items, 0..) |val, ci| {
                if (ci > 0) try i.b.writeString(", ");
                try i.b.arg(val);
            }
            try i.b.writeByte(')');
        }
        return i.b.query();
    }
};

pub fn Insert(allocator: std.mem.Allocator, dialect: Dialect, table: []const u8) InsertBuilder {
    return InsertBuilder.init(allocator, dialect, table);
}

// ------------------------------------------------------------------
// UPDATE
// ------------------------------------------------------------------

pub const UpdateSet = struct {
    column: []const u8,
    value: Value,
};

pub const UpdateBuilder = struct {
    b: Builder,
    table: []const u8,
    sets: std.array_list.Managed(UpdateSet),
    wheres: std.array_list.Managed(Predicate),

    pub fn init(allocator: std.mem.Allocator, dialect: Dialect, table: []const u8) UpdateBuilder {
        return .{
            .b = Builder.init(allocator, dialect),
            .table = table,
            .sets = std.array_list.Managed(UpdateSet).init(allocator),
            .wheres = std.array_list.Managed(Predicate).init(allocator),
        };
    }

    pub fn deinit(u: *UpdateBuilder) void {
        u.b.deinit();
        u.sets.deinit();
        u.wheres.deinit();
    }

    pub fn set(u: *UpdateBuilder, column: []const u8, value: Value) *UpdateBuilder {
        u.sets.append(.{ .column = column, .value = value }) catch unreachable;
        return u;
    }

    pub fn where(u: *UpdateBuilder, pred: Predicate) *UpdateBuilder {
        u.wheres.append(pred) catch unreachable;
        return u;
    }

    pub fn query(u: *UpdateBuilder) !QueryResult {
        try u.b.writeString("UPDATE ");
        try u.b.ident(u.table);
        try u.b.writeString(" SET ");
        for (u.sets.items, 0..) |s, i| {
            if (i > 0) try u.b.writeString(", ");
            try u.b.ident(s.column);
            try u.b.writeString(" = ");
            try u.b.arg(s.value);
        }
        if (u.wheres.items.len > 0) {
            try u.b.writeString(" WHERE ");
            for (u.wheres.items, 0..) |pred, i| {
                if (i > 0) try u.b.writeString(" AND ");
                try pred.appendTo(&u.b);
            }
        }
        return u.b.query();
    }
};

pub fn Update(allocator: std.mem.Allocator, dialect: Dialect, table: []const u8) UpdateBuilder {
    return UpdateBuilder.init(allocator, dialect, table);
}

// ------------------------------------------------------------------
// DELETE
// ------------------------------------------------------------------

pub const DeleteBuilder = struct {
    b: Builder,
    table: []const u8,
    wheres: std.array_list.Managed(Predicate),

    pub fn init(allocator: std.mem.Allocator, dialect: Dialect, table: []const u8) DeleteBuilder {
        return .{
            .b = Builder.init(allocator, dialect),
            .table = table,
            .wheres = std.array_list.Managed(Predicate).init(allocator),
        };
    }

    pub fn deinit(d: *DeleteBuilder) void {
        d.b.deinit();
        d.wheres.deinit();
    }

    pub fn where(d: *DeleteBuilder, pred: Predicate) *DeleteBuilder {
        d.wheres.append(pred) catch unreachable;
        return d;
    }

    pub fn query(d: *DeleteBuilder) !QueryResult {
        try d.b.writeString("DELETE FROM ");
        try d.b.ident(d.table);
        if (d.wheres.items.len > 0) {
            try d.b.writeString(" WHERE ");
            for (d.wheres.items, 0..) |pred, i| {
                if (i > 0) try d.b.writeString(" AND ");
                try pred.appendTo(&d.b);
            }
        }
        return d.b.query();
    }
};

pub fn Delete(allocator: std.mem.Allocator, dialect: Dialect, table: []const u8) DeleteBuilder {
    return DeleteBuilder.init(allocator, dialect, table);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "basic SELECT with WHERE" {
    const allocator = std.testing.allocator;
    var s = Select(allocator, Dialect.sqlite, &.{
        Table("users").c("id"),
        Table("users").c("name"),
    });
    defer s.deinit();
    _ = s.from(Table("users")).where(EQ("age", .{ .int = 30 }));
    const q = try s.query();
    try std.testing.expectEqualStrings("SELECT \"id\", \"name\" FROM \"users\" WHERE \"age\" = ?", q.sql);
    try std.testing.expectEqual(@as(usize, 1), q.args.len);
    try std.testing.expectEqual(@as(i64, 30), q.args[0].int);
}

test "SELECT with JOIN, ORDER BY, LIMIT, OFFSET" {
    const allocator = std.testing.allocator;
    var s = Select(allocator, Dialect.sqlite, &.{
        Table("users").c("id"),
        Table("users").c("name"),
    });
    defer s.deinit();
    _ = s.from(Table("users"))
        .join(.{ .kind = .inner, .table = Table("groups"), .on = EQ("groups.id", .{ .int = 1 }) })
        .where(EQ("users.active", .{ .bool = true }))
        .orderBy(.{ .column = "users.id", .desc = true })
        .limit(10)
        .offset(20);
    const q = try s.query();
    try std.testing.expectEqualStrings(
        "SELECT \"id\", \"name\" FROM \"users\" INNER JOIN \"groups\" ON \"groups\".\"id\" = ? WHERE \"users\".\"active\" = ? ORDER BY \"users\".\"id\" DESC LIMIT 10 OFFSET 20",
        q.sql,
    );
    try std.testing.expectEqual(@as(usize, 2), q.args.len);
}

test "INSERT" {
    const allocator = std.testing.allocator;
    var i = Insert(allocator, Dialect.sqlite, "users");
    defer i.deinit();
    _ = i.columns(&.{ "name", "age" }).values(&.{ .{ .string = "alice" }, .{ .int = 30 } });
    const q = try i.query();
    try std.testing.expectEqualStrings("INSERT INTO \"users\" (\"name\", \"age\") VALUES (?, ?)", q.sql);
    try std.testing.expectEqual(@as(usize, 2), q.args.len);
}

test "UPDATE" {
    const allocator = std.testing.allocator;
    var u = Update(allocator, Dialect.sqlite, "users");
    defer u.deinit();
    _ = u.set("name", .{ .string = "bob" }).where(EQ("id", .{ .int = 1 }));
    const q = try u.query();
    try std.testing.expectEqualStrings("UPDATE \"users\" SET \"name\" = ? WHERE \"id\" = ?", q.sql);
    try std.testing.expectEqual(@as(usize, 2), q.args.len);
}

test "DELETE" {
    const allocator = std.testing.allocator;
    var d = Delete(allocator, Dialect.sqlite, "users");
    defer d.deinit();
    _ = d.where(EQ("id", .{ .int = 1 }));
    const q = try d.query();
    try std.testing.expectEqualStrings("DELETE FROM \"users\" WHERE \"id\" = ?", q.sql);
    try std.testing.expectEqual(@as(usize, 1), q.args.len);
}

test "predicate AND/OR/NOT" {
    const allocator = std.testing.allocator;
    const p1 = EQ("age", .{ .int = 18 });
    const p2 = GT("score", .{ .int = 100 });
    const combined = And(&p1, &p2);

    var s = Select(allocator, Dialect.sqlite, &.{Table("users").c("id")});
    defer s.deinit();
    _ = s.from(Table("users")).where(combined);
    const q = try s.query();
    try std.testing.expectEqualStrings("SELECT \"id\" FROM \"users\" WHERE (\"age\" = ? AND \"score\" > ?)", q.sql);
    try std.testing.expectEqual(@as(usize, 2), q.args.len);
}

test "Postgres placeholders" {
    const allocator = std.testing.allocator;
    var s = Select(allocator, Dialect.postgres, &.{Table("users").c("id")});
    defer s.deinit();
    _ = s.from(Table("users")).where(EQ("age", .{ .int = 30 }));
    const q = try s.query();
    try std.testing.expectEqualStrings("SELECT \"id\" FROM \"users\" WHERE \"age\" = $1", q.sql);
}

test "MySQL identifiers" {
    const allocator = std.testing.allocator;
    var s = Select(allocator, Dialect.mysql, &.{Table("users").c("id")});
    defer s.deinit();
    _ = s.from(Table("users"));
    const q = try s.query();
    try std.testing.expectEqualStrings("SELECT `id` FROM `users`", q.sql);
}

test "Raw predicate" {
    const allocator = std.testing.allocator;
    var s = Select(allocator, Dialect.sqlite, &.{Table("users").c("id")});
    defer s.deinit();
    _ = s.from(Table("users")).where(Raw("age > 20"));
    const q = try s.query();
    try std.testing.expectEqualStrings("SELECT \"id\" FROM \"users\" WHERE age > 20", q.sql);
    try std.testing.expectEqual(@as(usize, 0), q.args.len);
}

test "Subquery predicates" {
    const allocator = std.testing.allocator;

    // IN subquery
    var s1 = Select(allocator, Dialect.sqlite, &.{Table("users").c("id")});
    defer s1.deinit();
    _ = s1.from(Table("users")).where(InSubquery("id", "SELECT user_id FROM orders"));
    const q1 = try s1.query();
    try std.testing.expectEqualStrings("SELECT \"id\" FROM \"users\" WHERE \"id\" IN (SELECT user_id FROM orders)", q1.sql);

    // EXISTS subquery
    var s2 = Select(allocator, Dialect.sqlite, &.{Table("users").c("id")});
    defer s2.deinit();
    _ = s2.from(Table("users")).where(ExistsSubquery("SELECT 1 FROM orders WHERE orders.user_id = users.id"));
    const q2 = try s2.query();
    try std.testing.expectEqualStrings("SELECT \"id\" FROM \"users\" WHERE EXISTS (SELECT 1 FROM orders WHERE orders.user_id = users.id)", q2.sql);
}
