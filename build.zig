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

    // libpq (PostgreSQL) — optional, only if headers are installed
    const pg_c_mod = blk: {
        const pg_header = "/usr/local/opt/postgresql@18/include/libpq-fe.h";
        if (fileExists(pg_header)) {
            const tc = b.addTranslateC(.{
                .root_source_file = b.path("src/sql/pg_include.h"),
                .target = target,
                .optimize = optimize,
            });
            tc.addSystemIncludePath(.{ .cwd_relative = "/usr/local/opt/postgresql@18/include" });
            tc.addSystemIncludePath(.{ .cwd_relative = "/usr/local/opt/postgresql@18/include/postgresql" });
            break :blk tc.createModule();
        }
        break :blk null;
    };

    // mariadb — optional, only if headers are installed
    const my_c_mod = blk: {
        const my_header = "/usr/local/opt/mariadb-connector-c/include/mariadb/mysql.h";
        if (fileExists(my_header)) {
            const tc = b.addTranslateC(.{
                .root_source_file = b.path("src/sql/mysql_include.h"),
                .target = target,
                .optimize = optimize,
            });
            tc.defineCMacro("MYSQL_NO_DATA", "1");
            tc.addSystemIncludePath(.{ .cwd_relative = "/usr/local/opt/mariadb-connector-c/include" });
            break :blk tc.createModule();
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
        test_mod.addIncludePath(.{ .cwd_relative = "/usr/local/opt/postgresql@18/include/postgresql" });
        test_mod.addLibraryPath(.{ .cwd_relative = "/usr/local/opt/postgresql@18/lib/postgresql" });
        test_mod.linkSystemLibrary("pq", .{});
    }
    if (my_c_mod != null) {
        test_mod.addIncludePath(.{ .cwd_relative = "/usr/local/opt/mariadb-connector-c/include" });
        test_mod.addLibraryPath(.{ .cwd_relative = "/usr/local/opt/mariadb-connector-c/lib" });
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

fn fileExists(path: [*:0]const u8) bool {
    var buf: [144]u8 = undefined;
    return stat(path, @ptrCast(&buf)) == 0;
}

extern "c" fn stat(path: [*:0]const u8, buf: *anyopaque) c_int;
