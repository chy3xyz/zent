const std = @import("std");

/// Index descriptor used at comptime.
pub const Index = struct {
    name: ?[]const u8,
    columns: []const []const u8,
    unique: bool = false,

    pub fn Unique(self: Index) Index {
        var i = self;
        i.unique = true;
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
