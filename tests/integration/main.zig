//! Integration test runner for zent database drivers.
//!
//! Run: `zig build test-integration` (requires no external database server for SQLite;
//!      postgres/mysql tests need running servers — they are skipped when unavailable).

const std = @import("std");

pub fn main() !void {
    // Tests are discovered and run by the Zig test framework.
    // This file exists as an entry point for the integration test build step.
    _ = @import("sqlite.zig");
    _ = @import("pool.zig");

    // TODO: conditionally add postgres and mysql integration tests
    // when a test database is available.
    //
    //   _ = @import("postgres.zig");
    //   _ = @import("mysql.zig");
}

test {
    _ = @import("sqlite.zig");
}
