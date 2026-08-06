//! Integration test runner for zent database drivers.
//!
//! Run: `zig build test-integration` (requires no external database server for SQLite;
//!      postgres/mysql tests need running servers — they are skipped when unavailable).

const std = @import("std");
const build_options = @import("build_options");

pub fn main() !void {
    // Tests are discovered and run by the Zig test framework.
    // This file exists as an entry point for the integration test build step.
    // postgres/mysql are only imported when their C bindings were discovered.
    _ = @import("sqlite.zig");
    _ = @import("pool.zig");
    _ = @import("pressure.zig");
    if (comptime build_options.have_pg) _ = @import("postgres.zig");
    if (comptime build_options.have_mysql) _ = @import("mysql.zig");
}

test {
    _ = @import("sqlite.zig");
    _ = @import("pool.zig");
    _ = @import("pressure.zig");
    if (comptime build_options.have_pg) _ = @import("postgres.zig");
    if (comptime build_options.have_mysql) _ = @import("mysql.zig");
}
