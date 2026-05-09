const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Helper: add postgres include paths (needed for C imports in src/sql/postgres.zig)
    const addPostgresPaths = struct {
        fn add(mod: *std.Build.Module) void {
            mod.addIncludePath(.{ .cwd_relative = "/usr/local/opt/postgresql@18/include/postgresql" });
            mod.addLibraryPath(.{ .cwd_relative = "/usr/local/opt/postgresql@18/lib/postgresql" });
        }
    }.add;

    // Helper: add mariadb include paths (needed for C imports in src/sql/mysql.zig)
    const addMariadbPaths = struct {
        fn add(mod: *std.Build.Module) void {
            mod.addIncludePath(.{ .cwd_relative = "/usr/local/opt/mariadb-connector-c/include" });
            mod.addLibraryPath(.{ .cwd_relative = "/usr/local/opt/mariadb-connector-c/lib" });
        }
    }.add;

    // Library module – includes pg/mysql C import paths (but doesn't link them)
    const zent_mod = b.addModule("zent", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addPostgresPaths(zent_mod);
    addMariadbPaths(zent_mod);

    // Library tests — links all drivers
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.linkSystemLibrary("sqlite3", .{});
    addPostgresPaths(test_mod);
    test_mod.linkSystemLibrary("pq", .{});
    addMariadbPaths(test_mod);
    test_mod.linkSystemLibrary("mariadb", .{});

    const lib_unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Example: start
    const start_mod = b.createModule(.{
        .root_source_file = b.path("examples/start/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    start_mod.addImport("zent", zent_mod);
    const start_exe = b.addExecutable(.{
        .name = "start",
        .root_module = start_mod,
    });
    start_mod.linkSystemLibrary("sqlite3", .{});
    b.installArtifact(start_exe);

    const run_start = b.addRunArtifact(start_exe);
    const start_step = b.step("run-start", "Run the start example");
    start_step.dependOn(&run_start.step);

    // Top-level test step
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Integration tests (SQLite only — postgres/mysql require running servers)
    const integ_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    integ_mod.addImport("zent", zent_mod);
    integ_mod.linkSystemLibrary("sqlite3", .{});

    const integ_tests = b.addTest(.{
        .root_module = integ_mod,
    });
    const run_integ_tests = b.addRunArtifact(integ_tests);
    const integ_step = b.step("test-integration", "Run integration tests (SQLite)");
    integ_step.dependOn(&run_integ_tests.step);
}
