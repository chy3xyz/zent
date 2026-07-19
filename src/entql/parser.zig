//! EntQL — a lightweight predicate expression parser for zent.
//!
//! Syntax (inspired by entgo.io/ent/entql):
//!
//!   expr     = or_expr
//!   or_expr  = and_expr ("OR" and_expr)*
//!   and_expr = not_expr ("AND" not_expr)*
//!   not_expr = "NOT" not_expr | primary
//!   primary  = "(" expr ")" | comparison
//!   comparison = field op value
//!   op       = "=" | "!=" | ">" | "<" | ">=" | "<=" | "IN" | "CONTAINS"
//!   field    = IDENTIFIER
//!   value    = STRING | INTEGER | FLOAT | "NULL"
//!
//! Examples:
//!   name = "alice"
//!   age > 18 AND age < 65
//!   status IN ("active", "pending")
//!   name CONTAINS "ali"
//!   age IS NULL
//!   (name = "alice" OR name = "bob") AND age > 18

const std = @import("std");
const sql = @import("../sql/builder.zig");

// ------------------------------------------------------------------
// Tokenizer
// ------------------------------------------------------------------

const Token = union(enum) {
    eof,
    ident: []const u8,
    string: []const u8,
    integer: i64,
    float: f64,
    op_eq,
    op_ne,
    op_gt,
    op_lt,
    op_gte,
    op_lte,
    op_eqfold,
    kw_in,
    kw_contains,
    kw_is,
    kw_null,
    kw_not,
    kw_and,
    kw_or,
    kw_has,
    kw_not_has,
    lparen,
    rparen,
    comma,
};

const Lexer = struct {
    input: []const u8,
    pos: usize,

    fn init(input: []const u8) Lexer {
        return .{ .input = input, .pos = 0 };
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.input.len and std.ascii.isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }
    }

    fn peek(self: *Lexer) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn advance(self: *Lexer) u8 {
        const c = self.input[self.pos];
        self.pos += 1;
        return c;
    }

    fn next(self: *Lexer) !Token {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return .eof;

        const c = self.input[self.pos];

        // Single-character tokens
        if (c == '(') {
            self.pos += 1;
            return .lparen;
        }
        if (c == ')') {
            self.pos += 1;
            return .rparen;
        }
        if (c == ',') {
            self.pos += 1;
            return .comma;
        }

        // Operators starting with special chars
        if (c == '=') {
            if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '~') {
                self.pos += 2;
                return .op_eqfold;
            }
            self.pos += 1;
            return .op_eq;
        }
        if (c == '!') {
            if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '=') {
                self.pos += 2;
                return .op_ne;
            }
            return error.UnknownToken;
        }
        if (c == '>') {
            if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '=') {
                self.pos += 2;
                return .op_gte;
            }
            self.pos += 1;
            return .op_gt;
        }
        if (c == '<') {
            if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '=') {
                self.pos += 2;
                return .op_lte;
            }
            self.pos += 1;
            return .op_lt;
        }

        // String literals
        if (c == '"' or c == '\'') {
            const quote = c;
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] != quote) {
                self.pos += 1;
            }
            if (self.pos >= self.input.len) return error.UnterminatedString;
            const s = self.input[start..self.pos];
            self.pos += 1; // skip closing quote
            return Token{ .string = s };
        }

        // Number literals
        if (std.ascii.isDigit(c) or c == '-') {
            const start = self.pos;
            if (c == '-') self.pos += 1;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
                self.pos += 1;
            }
            var is_float = false;
            if (self.pos < self.input.len and self.input[self.pos] == '.') {
                is_float = true;
                self.pos += 1;
                while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
                    self.pos += 1;
                }
            }
            const num_str = self.input[start..self.pos];
            if (is_float) {
                return Token{ .float = try std.fmt.parseFloat(f64, num_str) };
            } else {
                return Token{ .integer = try std.fmt.parseInt(i64, num_str, 10) };
            }
        }

        // Identifiers and keywords
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = self.pos;
            while (self.pos < self.input.len and (std.ascii.isAlphanumeric(self.input[self.pos]) or self.input[self.pos] == '_')) {
                self.pos += 1;
            }
            const word = self.input[start..self.pos];

            // Check for multi-word keywords (need to look ahead)
            if (std.ascii.eqlIgnoreCase("IS", word)) {
                // Don't consume trailing tokens; let the parser handle
                // `IS NULL` and `IS NOT NULL` so both forms work.
                return .kw_is;
            }

            if (std.ascii.eqlIgnoreCase("NOT", word)) return .kw_not;
            if (std.ascii.eqlIgnoreCase("AND", word)) return .kw_and;
            if (std.ascii.eqlIgnoreCase("OR", word)) return .kw_or;
            if (std.ascii.eqlIgnoreCase("IN", word)) return .kw_in;
            if (std.ascii.eqlIgnoreCase("NULL", word)) return .kw_null;
            if (std.ascii.eqlIgnoreCase("CONTAINS", word)) return .kw_contains;
            if (std.ascii.eqlIgnoreCase("has", word)) return .kw_has;
            if (std.ascii.eqlIgnoreCase("not_has", word)) return .kw_not_has;

            return Token{ .ident = word };
        }

        return error.UnknownToken;
    }
};

// ------------------------------------------------------------------
// Parser
// ------------------------------------------------------------------

const ParseError = error{
    UnexpectedToken,
    ExpectedExpression,
    ExpectedOperator,
    ExpectedValue,
    ExpectedIdentifier,
    ExpectedLParen,
    ExpectedRParen,
    MismatchedTypes,
    UnimplementedHasEdge,
    OutOfMemory,
    UnterminatedString,
    UnknownToken,
    InvalidCharacter,
    Overflow,
};

fn unimplementedHasEdge() ParseError {
    if (@inComptime()) {
        @compileError("EntQL 'has'/'not_has' requires schema-aware codegen; not yet supported");
    }
    return ParseError.UnimplementedHasEdge;
}

const ParserContext = struct {
    lexer: Lexer,
    allocator: std.mem.Allocator,
    current: Token,

    fn init(allocator: std.mem.Allocator, input: []const u8) !ParserContext {
        var lex = Lexer.init(input);
        const tok = try lex.next();
        return ParserContext{
            .lexer = lex,
            .allocator = allocator,
            .current = tok,
        };
    }

    fn next(self: *ParserContext) !Token {
        const tok = self.current;
        self.current = try self.lexer.next();
        return tok;
    }

    fn peek(self: *ParserContext) Token {
        return self.current;
    }

    fn expectIdent(self: *ParserContext) ![]const u8 {
        const tok = try self.next();
        switch (tok) {
            .ident => |name| return name,
            else => return ParseError.ExpectedIdentifier,
        }
    }

    fn expectOp(self: *ParserContext) !Token {
        const tok = try self.next();
        switch (tok) {
            .op_eq, .op_ne, .op_gt, .op_lt, .op_gte, .op_lte, .op_eqfold, .kw_in, .kw_not, .kw_contains, .kw_is => return tok,
            else => return ParseError.ExpectedOperator,
        }
    }

    fn expectValue(self: *ParserContext) !sql.Value {
        const tok = try self.next();
        return switch (tok) {
            .string => |s| sql.Value{ .string = s },
            .integer => |i| sql.Value{ .int = i },
            .float => |f| sql.Value{ .float = f },
            .kw_null => sql.Value.null,
            else => ParseError.ExpectedValue,
        };
    }
};

/// Parse a full EntQL expression and return the resulting Predicate.
/// The returned Predicate owns its data (allocated with `allocator`).
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !sql.Predicate {
    var ctx = try ParserContext.init(allocator, input);
    return try parseExpr(&ctx);
}

fn parseExpr(ctx: *ParserContext) ParseError!sql.Predicate {
    return try parseOr(ctx);
}

fn parseOr(ctx: *ParserContext) ParseError!sql.Predicate {
    var left = try parseAnd(ctx);
    while (true) {
        const tok = ctx.peek();
        switch (tok) {
            .kw_or => {
                _ = try ctx.next(); // consume OR
                const right = try parseAnd(ctx);
                // Allocate left on heap for the Or predicate
                const left_ptr = try ctx.allocator.create(sql.Predicate);
                left_ptr.* = left;
                const right_ptr = try ctx.allocator.create(sql.Predicate);
                right_ptr.* = right;
                left = sql.Predicate{ .or_ = .{ .left = left_ptr, .right = right_ptr } };
            },
            else => break,
        }
    }
    return left;
}

fn parseAnd(ctx: *ParserContext) ParseError!sql.Predicate {
    var left = try parseNot(ctx);
    while (true) {
        const tok = ctx.peek();
        switch (tok) {
            .kw_and => {
                _ = try ctx.next(); // consume AND
                const right = try parseNot(ctx);
                const left_ptr = try ctx.allocator.create(sql.Predicate);
                left_ptr.* = left;
                const right_ptr = try ctx.allocator.create(sql.Predicate);
                right_ptr.* = right;
                left = sql.Predicate{ .and_ = .{ .left = left_ptr, .right = right_ptr } };
            },
            else => break,
        }
    }
    return left;
}

fn parseNot(ctx: *ParserContext) ParseError!sql.Predicate {
    const tok = ctx.peek();
    switch (tok) {
        .kw_not => {
            _ = try ctx.next(); // consume NOT
            const inner = try parseNot(ctx);
            const inner_ptr = try ctx.allocator.create(sql.Predicate);
            inner_ptr.* = inner;
            return sql.Predicate{ .not_ = inner_ptr };
        },
        else => return try parsePrimary(ctx),
    }
}

fn parsePrimary(ctx: *ParserContext) ParseError!sql.Predicate {
    const tok = ctx.peek();
    switch (tok) {
        .lparen => {
            _ = try ctx.next(); // consume (
            const inner = try parseExpr(ctx);
            const close = ctx.peek();
            switch (close) {
                .rparen => {
                    _ = try ctx.next(); // consume )
                    return inner;
                },
                else => return ParseError.ExpectedRParen,
            }
        },
        .kw_has, .kw_not_has => return unimplementedHasEdge(),
        .ident => return try parseComparison(ctx),
        else => return ParseError.ExpectedExpression,
    }
}

fn parseComparison(ctx: *ParserContext) ParseError!sql.Predicate {
    const field = try ctx.expectIdent();
    const op = try ctx.expectOp();

    switch (op) {
        .op_eq => {
            const val = try ctx.expectValue();
            return sql.EQ(field, val);
        },
        .op_ne => {
            const val = try ctx.expectValue();
            return sql.NE(field, val);
        },
        .op_gt => {
            const val = try ctx.expectValue();
            return sql.GT(field, val);
        },
        .op_lt => {
            const val = try ctx.expectValue();
            return sql.LT(field, val);
        },
        .op_gte => {
            const val = try ctx.expectValue();
            return sql.GTE(field, val);
        },
        .op_lte => {
            const val = try ctx.expectValue();
            return sql.LTE(field, val);
        },
        .op_eqfold => {
            const val = try ctx.expectValue();
            return sql.EQFold(field, val);
        },
        .kw_in => {
            // expect LPAREN, values, RPAREN
            const lparen = ctx.peek();
            switch (lparen) {
                .lparen => _ = try ctx.next(),
                else => return ParseError.ExpectedLParen,
            }
            var values = std.array_list.Managed(sql.Value).init(ctx.allocator);
            while (true) {
                const val = try ctx.expectValue();
                try values.append(val);
                const next_tok = ctx.peek();
                switch (next_tok) {
                    .comma => {
                        _ = try ctx.next();
                        continue;
                    },
                    .rparen => {
                        _ = try ctx.next();
                        break;
                    },
                    else => return ParseError.ExpectedRParen,
                }
            }
            return sql.In(field, try values.toOwnedSlice());
        },
        .kw_not => {
            // NOT IN: expect kw_in followed by LPAREN, values, RPAREN
            const next_tok = ctx.peek();
            switch (next_tok) {
                .kw_in => {
                    _ = try ctx.next(); // consume IN
                    const lparen = ctx.peek();
                    switch (lparen) {
                        .lparen => _ = try ctx.next(),
                        else => return ParseError.ExpectedLParen,
                    }
                    var values = std.array_list.Managed(sql.Value).init(ctx.allocator);
                    while (true) {
                        const val = try ctx.expectValue();
                        try values.append(val);
                        const after_val = ctx.peek();
                        switch (after_val) {
                            .comma => {
                                _ = try ctx.next();
                                continue;
                            },
                            .rparen => {
                                _ = try ctx.next();
                                break;
                            },
                            else => return ParseError.ExpectedRParen,
                        }
                    }
                    return sql.NotIn(field, try values.toOwnedSlice());
                },
                else => return ParseError.ExpectedOperator,
            }
        },
        .kw_contains => {
            const val = try ctx.expectValue();
            // Wrap value in % for LIKE
            const s = switch (val) {
                .string => |s| s,
                else => return ParseError.MismatchedTypes,
            };
            const wrapped = try std.fmt.allocPrint(ctx.allocator, "%{s}%", .{s});
            return sql.Like(field, .{ .string = wrapped });
        },
        .kw_is => {
            // Check for NULL or NOT NULL
            const next_tok = ctx.peek();
            switch (next_tok) {
                .kw_null => {
                    _ = try ctx.next();
                    return sql.IsNull(field);
                },
                .kw_not => {
                    _ = try ctx.next();
                    const after = ctx.peek();
                    switch (after) {
                        .kw_null => {
                            _ = try ctx.next();
                            return sql.IsNotNull(field);
                        },
                        else => return ParseError.ExpectedValue,
                    }
                },
                else => return ParseError.ExpectedValue,
            }
        },
        else => return ParseError.ExpectedOperator,
    }
}

// ------------------------------------------------------------------
// Convenience: parse into an allocator-managed predicate with cleanup
// ------------------------------------------------------------------

/// ParsedPredicate wraps a Predicate and provides a `deinit` method
/// to free any heap-allocated memory owned by the predicate tree.
pub const ParsedPredicate = struct {
    pred: sql.Predicate,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ParsedPredicate) void {
        deinitPred(self.allocator, &self.pred);
    }
};

pub fn deinitPred(allocator: std.mem.Allocator, pred: *const sql.Predicate) void {
    switch (pred.*) {
        .in => |p| {
            allocator.free(p.values);
        },
        .not_in => |p| {
            allocator.free(p.values);
        },
        .like => |p| {
            allocator.free(p.value.string);
        },
        .has_edge => |h| {
            if (h.pred) |p| {
                deinitPred(allocator, p);
                allocator.destroy(p);
            }
        },
        .and_ => |p| {
            deinitPred(allocator, p.left);
            deinitPred(allocator, p.right);
            allocator.destroy(p.left);
            allocator.destroy(p.right);
        },
        .or_ => |p| {
            deinitPred(allocator, p.left);
            deinitPred(allocator, p.right);
            allocator.destroy(p.left);
            allocator.destroy(p.right);
        },
        .not_ => |p| {
            deinitPred(allocator, p);
            allocator.destroy(p);
        },
        else => {}, // leaf predicates don't own heap memory
    }
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "EntQL: simple equality" {
    const allocator = std.testing.allocator;
    const pred = try parse(allocator, "name = \"alice\"");
    try std.testing.expectEqualDeep(sql.Predicate{ .eq = .{ .column = "name", .value = .{ .string = "alice" } } }, pred);
}

test "EntQL: numeric comparison" {
    const allocator = std.testing.allocator;
    const pred = try parse(allocator, "age > 18");
    try std.testing.expectEqualDeep(sql.Predicate{ .gt = .{ .column = "age", .value = .{ .int = 18 } } }, pred);
}

test "EntQL: comparison operators" {
    const allocator = std.testing.allocator;
    const p1 = try parse(allocator, "age >= 10");
    try std.testing.expectEqualDeep(sql.Predicate{ .gte = .{ .column = "age", .value = .{ .int = 10 } } }, p1);

    const p2 = try parse(allocator, "age < 65");
    try std.testing.expectEqualDeep(sql.Predicate{ .lt = .{ .column = "age", .value = .{ .int = 65 } } }, p2);

    const p3 = try parse(allocator, "age <= 100");
    try std.testing.expectEqualDeep(sql.Predicate{ .lte = .{ .column = "age", .value = .{ .int = 100 } } }, p3);

    const p4 = try parse(allocator, "name != \"bob\"");
    try std.testing.expectEqualDeep(sql.Predicate{ .ne = .{ .column = "name", .value = .{ .string = "bob" } } }, p4);
}

test "EntQL: IN clause" {
    const allocator = std.testing.allocator;
    const p = try parse(allocator, "status IN (\"active\", \"pending\")");
    switch (p) {
        .in => |inp| {
            try std.testing.expectEqualStrings("status", inp.column);
            try std.testing.expectEqual(@as(usize, 2), inp.values.len);
            try std.testing.expectEqualStrings("active", inp.values[0].string);
            try std.testing.expectEqualStrings("pending", inp.values[1].string);
            allocator.free(inp.values);
        },
        else => @panic("expected IN predicate"),
    }
}

test "EntQL: CONTAINS (LIKE)" {
    const allocator = std.testing.allocator;
    const p = try parse(allocator, "name CONTAINS \"ali\"");
    switch (p) {
        .like => |lp| {
            defer allocator.free(lp.value.string);
            try std.testing.expectEqualStrings("name", lp.column);
            try std.testing.expectEqualStrings("%ali%", lp.value.string);
        },
        else => @panic("expected LIKE predicate"),
    }
}

test "EntQL: IS NULL / IS NOT NULL" {
    const allocator = std.testing.allocator;
    const p1 = try parse(allocator, "deleted_at IS NULL");
    try std.testing.expectEqualDeep(sql.Predicate{ .is_null = "deleted_at" }, p1);

    const p2 = try parse(allocator, "name IS NOT NULL");
    try std.testing.expectEqualDeep(sql.Predicate{ .is_not_null = "name" }, p2);
}

test "EntQL: AND / OR" {
    const allocator = std.testing.allocator;
    const p = try parse(allocator, "age > 18 AND age < 65");
    defer deinitPred(allocator, &p);
    switch (p) {
        .and_ => |a| {
            try std.testing.expectEqualDeep(sql.Predicate{ .gt = .{ .column = "age", .value = .{ .int = 18 } } }, a.left.*);
            try std.testing.expectEqualDeep(sql.Predicate{ .lt = .{ .column = "age", .value = .{ .int = 65 } } }, a.right.*);
        },
        else => @panic("expected AND predicate"),
    }
}

test "EntQL: NOT" {
    const allocator = std.testing.allocator;
    const p = try parse(allocator, "NOT name = \"alice\"");
    defer deinitPred(allocator, &p);
    switch (p) {
        .not_ => |n| {
            try std.testing.expectEqualDeep(sql.Predicate{ .eq = .{ .column = "name", .value = .{ .string = "alice" } } }, n.*);
        },
        else => @panic("expected NOT predicate"),
    }
}

test "EntQL: parenthesized expression" {
    const allocator = std.testing.allocator;
    const p = try parse(allocator, "(name = \"alice\" OR name = \"bob\") AND age > 18");
    defer deinitPred(allocator, &p);
    switch (p) {
        .and_ => |a| {
            switch (a.left.*) {
                .or_ => |o| {
                    try std.testing.expectEqualDeep(sql.Predicate{ .eq = .{ .column = "name", .value = .{ .string = "alice" } } }, o.left.*);
                    try std.testing.expectEqualDeep(sql.Predicate{ .eq = .{ .column = "name", .value = .{ .string = "bob" } } }, o.right.*);
                },
                else => @panic("expected OR"),
            }
            try std.testing.expectEqualDeep(sql.Predicate{ .gt = .{ .column = "age", .value = .{ .int = 18 } } }, a.right.*);
        },
        else => @panic("expected AND"),
    }
}

test "EntQL: SQL builder output" {
    const allocator = std.testing.allocator;
    const Dialect = @import("../sql/dialect.zig").Dialect;

    var b = sql.Builder.init(allocator, Dialect.sqlite);
    defer b.deinit();
    try b.writeString("SELECT * FROM users WHERE ");

    const pred = try parse(allocator, "age > 18 AND name CONTAINS \"ali\"");
    defer deinitPred(allocator, &pred);
    try pred.appendTo(&b);

    const q = b.query();
    try std.testing.expectEqualStrings("SELECT * FROM users WHERE (\"age\" > ? AND \"name\" LIKE ?)", q.sql);
    try std.testing.expectEqual(@as(usize, 2), q.args.len);
    try std.testing.expectEqual(@as(i64, 18), q.args[0].int);
    try std.testing.expectEqualStrings("%ali%", q.args[1].string);
}

test "EntQL: NOT IN" {
    const allocator = std.testing.allocator;
    const p = try parse(allocator, "status NOT IN (\"active\", \"deleted\")");
    switch (p) {
        .not_in => |np| {
            defer allocator.free(np.values);
            try std.testing.expectEqualStrings("status", np.column);
            try std.testing.expectEqual(@as(usize, 2), np.values.len);
            try std.testing.expectEqualStrings("active", np.values[0].string);
            try std.testing.expectEqualStrings("deleted", np.values[1].string);
        },
        else => @panic("expected NOT_IN predicate"),
    }
}

test "EntQL: EQFold =~" {
    const allocator = std.testing.allocator;
    const p = try parse(allocator, "name =~ \"Alice\"");
    try std.testing.expectEqualDeep(sql.Predicate{
        .eq_fold = .{ .column = "name", .value = .{ .string = "Alice" } },
    }, p);
}

test "EntQL: has and not_has require schema-aware codegen" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.UnimplementedHasEdge, parse(allocator, "has(pets)"));
    try std.testing.expectError(error.UnimplementedHasEdge, parse(allocator, "has(pets, name = \"fido\")"));
    try std.testing.expectError(error.UnimplementedHasEdge, parse(allocator, "not_has(pets)"));
}

test "EntQL: SQL builder rejects schema-unaware edge predicates" {
    const allocator = std.testing.allocator;
    const Dialect = @import("../sql/dialect.zig").Dialect;

    var b = sql.Builder.init(allocator, Dialect.sqlite);
    defer b.deinit();

    try std.testing.expectError(error.UnimplementedHasEdge, sql.HasEdge("pets", "user_id").appendTo(&b));
    try std.testing.expectError(error.UnimplementedHasEdge, sql.NotHasEdge("pets", "user_id").appendTo(&b));
}

test "EntQL: NOT IN and EQFold with SQL builder" {
    const allocator = std.testing.allocator;
    const Dialect = @import("../sql/dialect.zig").Dialect;

    // Test NOT IN
    {
        var b = sql.Builder.init(allocator, Dialect.sqlite);
        defer b.deinit();
        try b.writeString("SELECT * FROM users WHERE ");
        const pred = try parse(allocator, "status NOT IN (\"a\", \"b\")");
        defer deinitPred(allocator, &pred);
        try pred.appendTo(&b);
        const q = b.query();
        try std.testing.expectEqualStrings("SELECT * FROM users WHERE \"status\" NOT IN (?, ?)", q.sql);
        try std.testing.expectEqual(@as(usize, 2), q.args.len);
    }

    // Test EQFold
    {
        var b = sql.Builder.init(allocator, Dialect.sqlite);
        defer b.deinit();
        try b.writeString("SELECT * FROM users WHERE ");
        const pred = try parse(allocator, "name =~ \"Alice\"");
        defer deinitPred(allocator, &pred);
        try pred.appendTo(&b);
        const q = b.query();
        try std.testing.expectEqualStrings("SELECT * FROM users WHERE LOWER(\"name\") = LOWER(?)", q.sql);
        try std.testing.expectEqual(@as(usize, 1), q.args.len);
        try std.testing.expectEqualStrings("Alice", q.args[0].string);
    }
}
