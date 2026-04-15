const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module
    const zent_mod = b.addModule("zent", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Library tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
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
    b.installArtifact(start_exe);

    const run_start = b.addRunArtifact(start_exe);
    const start_step = b.step("run-start", "Run the start example");
    start_step.dependOn(&run_start.step);

    // Top-level test step
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
