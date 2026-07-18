const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---------------------------------------------------------------
    // Translate-C steps: convert C headers → Zig binding modules
    // ---------------------------------------------------------------

    // sqlite3 — always available
    const sqlite_tc = b.addTranslateC(.{
        .root_source_file = b.path("src/sql/sqlite3_include.h"),
        .target = target,
        .optimize = optimize,
    });
    sqlite_tc.linkSystemLibrary("sqlite3", .{});
    const sqlite_c_mod = sqlite_tc.createModule();

    // libpq (PostgreSQL) — optional, only if headers are installed.
    // Try the user-supplied version (or "postgresql@<v>" common Homebrew
    // symlinks) on both Apple Silicon and Intel Homebrew locations.
    const pg_c_mod = blk: {
        const pg_versions = [_][]const u8{ "postgresql@18", "postgresql@17", "postgresql@16", "postgresql" };
        const pg_homes = [_][]const u8{ "/opt/homebrew/opt", "/usr/local/opt" };
        for (pg_homes) |home| {
            for (pg_versions) |pkg| {
                const header = b.fmt("{s}/{s}/include/libpq-fe.h", .{ home, pkg });
                if (pathExists(header)) {
                    const tc = b.addTranslateC(.{
                        .root_source_file = b.path("src/sql/pg_include.h"),
                        .target = target,
                        .optimize = optimize,
                    });
                    const inc = b.fmt("{s}/{s}/include", .{ home, pkg });
                    tc.addSystemIncludePath(.{ .cwd_relative = inc });
                    tc.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/postgresql", .{inc}) });
                    break :blk tc.createModule();
                }
            }
        }
        break :blk null;
    };

    // mariadb — optional, only if headers are installed.
    const my_c_mod = blk: {
        const my_homes = [_][]const u8{ "/opt/homebrew/opt", "/usr/local/opt" };
        for (my_homes) |home| {
            const header = b.fmt("{s}/mariadb-connector-c/include/mariadb/mysql.h", .{home});
            if (pathExists(header)) {
                const tc = b.addTranslateC(.{
                    .root_source_file = b.path("src/sql/mysql_include.h"),
                    .target = target,
                    .optimize = optimize,
                });
                tc.defineCMacro("MYSQL_NO_DATA", "100");
                tc.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/mariadb-connector-c/include", .{home}) });
                break :blk tc.createModule();
            }
        }
        break :blk null;
    };

    // ---------------------------------------------------------------
    // Library module
    // ---------------------------------------------------------------
    const zent_mod = b.addModule("zent", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zent_mod.addImport("sqlite3_c", sqlite_c_mod);
    if (pg_c_mod) |m| zent_mod.addImport("pg_c", m);
    if (my_c_mod) |m| zent_mod.addImport("mysql_c", m);

    // ---------------------------------------------------------------
    // Library tests — links all drivers
    // ---------------------------------------------------------------
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("sqlite3_c", sqlite_c_mod);
    if (pg_c_mod) |m| test_mod.addImport("pg_c", m);
    if (my_c_mod) |m| test_mod.addImport("mysql_c", m);
    test_mod.linkSystemLibrary("sqlite3", .{});
    if (pg_c_mod != null) {
        const pg_versions = [_][]const u8{ "postgresql@18", "postgresql@17", "postgresql@16", "postgresql" };
        const pg_homes = [_][]const u8{ "/opt/homebrew/opt", "/usr/local/opt" };
        outer: for (pg_homes) |home| {
            for (pg_versions) |pkg| {
                const header = b.fmt("{s}/{s}/include/libpq-fe.h", .{ home, pkg });
                if (pathExists(header)) {
                    test_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/{s}/include/postgresql", .{ home, pkg }) });
                    test_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/{s}/lib/postgresql", .{ home, pkg }) });
                    break :outer;
                }
            }
        }
        test_mod.linkSystemLibrary("pq", .{});
    }
    if (my_c_mod != null) {
        const my_homes = [_][]const u8{ "/opt/homebrew/opt", "/usr/local/opt" };
        for (my_homes) |home| {
            if (pathExists(b.fmt("{s}/mariadb-connector-c/include/mariadb/mysql.h", .{home}))) {
                test_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/mariadb-connector-c/include", .{home}) });
                test_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/mariadb-connector-c/lib", .{home}) });
                break;
            }
        }
        test_mod.linkSystemLibrary("mariadb", .{});
    }

    const lib_unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // ---------------------------------------------------------------
    // Example: start
    // ---------------------------------------------------------------
    const start_mod = b.createModule(.{
        .root_source_file = b.path("examples/start/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    start_mod.addImport("zent", zent_mod);
    start_mod.addImport("sqlite3_c", sqlite_c_mod);
    start_mod.linkSystemLibrary("sqlite3", .{});
    const start_exe = b.addExecutable(.{
        .name = "start",
        .root_module = start_mod,
    });
    b.installArtifact(start_exe);

    const run_start = b.addRunArtifact(start_exe);
    const start_step = b.step("run-start", "Run the start example");
    start_step.dependOn(&run_start.step);

    // ---------------------------------------------------------------
    // Example: complex (e-commerce demo)
    // ---------------------------------------------------------------
    const complex_mod = b.createModule(.{
        .root_source_file = b.path("examples/complex/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    complex_mod.addImport("zent", zent_mod);
    complex_mod.addImport("sqlite3_c", sqlite_c_mod);
    complex_mod.linkSystemLibrary("sqlite3", .{});
    const complex_exe = b.addExecutable(.{
        .name = "complex",
        .root_module = complex_mod,
    });
    b.installArtifact(complex_exe);

    const run_complex = b.addRunArtifact(complex_exe);
    const complex_step = b.step("run-complex", "Run the complex e-commerce example");
    complex_step.dependOn(&run_complex.step);

    // ---------------------------------------------------------------
    // Example: pool (connection-pool demo)
    // ---------------------------------------------------------------
    const pool_mod = b.createModule(.{
        .root_source_file = b.path("examples/pool/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    pool_mod.addImport("zent", zent_mod);
    pool_mod.addImport("sqlite3_c", sqlite_c_mod);
    pool_mod.linkSystemLibrary("sqlite3", .{});
    const pool_exe = b.addExecutable(.{
        .name = "pool",
        .root_module = pool_mod,
    });
    b.installArtifact(pool_exe);

    const run_pool = b.addRunArtifact(pool_exe);
    const pool_step = b.step("run-pool", "Run the connection pool example");
    pool_step.dependOn(&run_pool.step);

    // ---------------------------------------------------------------
    // Top-level test step
    // ---------------------------------------------------------------
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // ---------------------------------------------------------------
    // Integration tests (SQLite only — pg/mysql need running servers)
    // ---------------------------------------------------------------
    const integ_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    integ_mod.addImport("zent", zent_mod);
    integ_mod.addImport("sqlite3_c", sqlite_c_mod);
    integ_mod.linkSystemLibrary("sqlite3", .{});

    const integ_tests = b.addTest(.{
        .root_module = integ_mod,
    });
    const run_integ_tests = b.addRunArtifact(integ_tests);
    const integ_step = b.step("test-integration", "Run integration tests (SQLite)");
    integ_step.dependOn(&run_integ_tests.step);
}

/// Returns true if `path` points to an existing regular file. Uses the
/// classic `stat` via extern (works on macOS; build runner may or may not
/// link libc on Linux). We keep this limited to a small set of well-known
/// Homebrew include paths.
fn fileExists(path: [*:0]const u8) bool {
    var buf: [144]u8 = undefined;
    return stat(path, @ptrCast(&buf)) == 0;
}

extern "c" fn stat(path: [*:0]const u8, buf: *anyopaque) c_int;

/// Version of `fileExists` that accepts a normal `[]const u8`. The
/// path MUST be short enough to fit in the small stack buffer we use
/// for null-termination (Homebrew paths are comfortably within 400B).
fn pathExists(path: []const u8) bool {
    var zbuf: [512:0]u8 = undefined;
    if (path.len >= zbuf.len) return false;
    @memcpy(zbuf[0..path.len], path);
    return fileExists(@ptrCast(&zbuf));
}
