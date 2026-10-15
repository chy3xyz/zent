const std = @import("std");

/// Index descriptor used at comptime.
///
/// `method` and `opclass` are the two declaration slots an index needs beyond
/// its key list, and both are **optional and dialect-gated** — an index that
/// declares neither renders byte-for-byte the `CREATE INDEX` it always did
/// (see `migrate.createIndexSQLAlloc`).
pub const Index = struct {
    name: ?[]const u8,
    columns: []const []const u8,
    unique: bool = false,
    /// Access method — `USING <method>`: `"hnsw"` / `"ivfflat"` (pgvector), or
    /// `"btree"` / `"hash"`. Where it is emitted, and what happens where it is
    /// not:
    ///
    ///  * PostgreSQL — `USING <method>`, verbatim.
    ///  * MySQL — only `btree` and `hash` exist; either is emitted as
    ///    `USING BTREE` / `USING HASH`. Anything else is **omitted with a
    ///    warning**, because MySQL has no such access method and the statement
    ///    would be a syntax error (errno 1064).
    ///  * SQLite — no access methods at all: omitted with a warning.
    ///
    /// A declared method is **not compared** by `checkSchema`, so declaring one
    /// cannot produce a false drift (see `migrate.IndexDef.method` for why that
    /// is deliberate). The name is validated in the DDL layer, never
    /// interpolated raw.
    method: ?[]const u8 = null,
    /// Operator class for the index's key column: `"vector_cosine_ops"`,
    /// `"vector_l2_ops"`, … Rendered as `<col> <opclass>` on PostgreSQL, and a
    /// pgvector index is the reason the slot exists (`USING hnsw (embedding
    /// vector_cosine_ops)`).
    ///
    /// PostgreSQL only. MySQL has no operator classes and SQLite has neither
    /// them nor access methods, so on those dialects the declaration is
    /// **omitted with a warning** rather than rejected at compile time: one
    /// schema is routinely migrated against PostgreSQL in production and
    /// SQLite in tests, and a `@compileError` here would make the schema
    /// unbuildable on the dialect it is only *not indexed* on — a performance
    /// difference, where refusing to compile is not. The opclass is not part of
    /// any query the library builds, so nothing downstream silently changes
    /// meaning.
    ///
    /// A composite index (more than one key column) cannot carry one — an
    /// operator class belongs to exactly one column — so the DDL layer answers
    /// `error.OpClassNeedsSingleColumn` instead of picking a column to attach
    /// it to.
    opclass: ?[]const u8 = null,

    pub fn Unique(self: Index) Index {
        var i = self;
        i.unique = true;
        return i;
    }

    /// Declare the access method. Chain `.OpClass(s)` for the key column's
    /// operator class, or use `.Using(method, opclass)` for both at once.
    pub fn Method(self: Index, method: []const u8) Index {
        var i = self;
        i.method = method;
        return i;
    }

    /// Declare the key column's operator class.
    pub fn OpClass(self: Index, opclass: []const u8) Index {
        var i = self;
        i.opclass = opclass;
        return i;
    }

    /// `.Method(method).OpClass(opclass)` in one call; a `null` opclass is the
    /// same as omitting it.
    pub fn Using(self: Index, method: []const u8, opclass: ?[]const u8) Index {
        var i = self;
        i.method = method;
        i.opclass = opclass;
        return i;
    }
};

pub fn Fields(columns: []const []const u8) Index {
    return .{ .name = null, .columns = columns };
}

pub fn Named(name: []const u8, columns: []const []const u8) Index {
    return .{ .name = name, .columns = columns };
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "Index builders" {
    const idx = Fields(&.{ "name", "email" }).Unique();
    try std.testing.expectEqual(@as(usize, 2), idx.columns.len);
    try std.testing.expect(idx.unique);
}

test "Index: method and opclass are opt-in and chainable" {
    // Neither declared — every existing declaration, unchanged. The migration
    // layer keys "render nothing extra" off exactly these two `null`s.
    const plain = Fields(&.{"name"});
    try std.testing.expectEqual(@as(?[]const u8, null), plain.method);
    try std.testing.expectEqual(@as(?[]const u8, null), plain.opclass);
    try std.testing.expect(!plain.unique);

    // The pgvector declaration this exists for.
    const hnsw = Named("users_embedding_hnsw", &.{"embedding"})
        .Using("hnsw", "vector_cosine_ops");
    try std.testing.expectEqualStrings("users_embedding_hnsw", hnsw.name.?);
    try std.testing.expectEqualStrings("hnsw", hnsw.method.?);
    try std.testing.expectEqualStrings("vector_cosine_ops", hnsw.opclass.?);
    try std.testing.expect(!hnsw.unique);

    // The modifier spelling, and order-independence with `.Unique()`.
    const chained = Fields(&.{"body"}).Method("hnsw").OpClass("vector_l2_ops").Unique();
    try std.testing.expectEqualStrings("hnsw", chained.method.?);
    try std.testing.expectEqualStrings("vector_l2_ops", chained.opclass.?);
    try std.testing.expect(chained.unique);

    // A method with no opclass, and a `null` opclass through `Using`.
    const btree = Named("t_a", &.{"a"}).Method("btree");
    try std.testing.expectEqualStrings("btree", btree.method.?);
    try std.testing.expectEqual(@as(?[]const u8, null), btree.opclass);
    try std.testing.expectEqual(@as(?[]const u8, null), Fields(&.{"a"}).Using("btree", null).opclass);

    // A modifier copies: the receiver is not mutated in place, so a shared
    // base declaration cannot be rewritten by one use of it.
    const base = Fields(&.{"a"});
    const derived = base.Method("hnsw");
    try std.testing.expectEqual(@as(?[]const u8, null), base.method);
    try std.testing.expectEqualStrings("hnsw", derived.method.?);
}
