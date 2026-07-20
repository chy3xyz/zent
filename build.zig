const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------------------
    // Translate-C steps: convert C headers -> Zig binding modules
    // -------------------------------------------------------------

    // sqlite3 — always available
    const sqlite_tc = b.addTranslateC(.{
        .root_source_file = b.path("src/sql/sqlite3_include.h"),
        .target = target,
        .optimize = optimize,
    });
    sqlite_tc.linkSystemLibrary("sqlite3", .{});
    const sqlite_c_mod = sqlite_tc.createModule();

    // PostgreSQL client — optional, only if libpq headers are installed.
    var pg_include_dir: ?[]const u8 = null;
    var pg_lib_dir: ?[]const u8 = null;
    const pg_c_mod = blk: {
        const info = discoverPg(b) orelse break :blk null;
        pg_include_dir = info.include_dir;
        pg_lib_dir = info.lib_dir;
        const tc = b.addTranslateC(.{
            .root_source_file = b.path("src/sql/pg_include.h"),
            .target = target,
            .optimize = optimize,
        });
        tc.addSystemIncludePath(.{ .cwd_relative = info.include_dir });
        // Some layouts keep libpq companion headers in a `postgresql/` subdir.
        tc.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/postgresql", .{info.include_dir}) });
        break :blk tc.createModule();
    };

    // MariaDB/MySQL client — optional, only if headers are installed.
    var my_include_dir: ?[]const u8 = null;
    var my_lib_dir: ?[]const u8 = null;
    const my_c_mod = blk: {
        const info = discoverMySQL(b) orelse break :blk null;
        my_include_dir = info.include_dir;
        my_lib_dir = info.lib_dir;
        const tc = b.addTranslateC(.{
            .root_source_file = b.path("src/sql/mysql_include.h"),
            .target = target,
            .optimize = optimize,
        });
        tc.defineCMacro("MYSQL_NO_DATA", "100");
        tc.addSystemIncludePath(.{ .cwd_relative = info.include_dir });
        break :blk tc.createModule();
    };

    // -------------------------------------------------------------
    // Library module
    // -------------------------------------------------------------
    const zent_mod = b.addModule("zent", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zent_mod.addImport("sqlite3_c", sqlite_c_mod);
    if (pg_c_mod) |m| zent_mod.addImport("pg_c", m);
    if (my_c_mod) |m| zent_mod.addImport("mysql_c", m);

    // -------------------------------------------------------------
    // Library unit tests
    // -------------------------------------------------------------
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("sqlite3_c", sqlite_c_mod);
    if (pg_c_mod) |m| test_mod.addImport("pg_c", m);
    if (my_c_mod) |m| test_mod.addImport("mysql_c", m);
    linkSqlite(test_mod);
    if (pg_include_dir) |inc| linkPg(test_mod, inc, pg_lib_dir.?);
    if (my_include_dir) |inc| linkMySQL(test_mod, inc, my_lib_dir.?);

    const lib_unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // -------------------------------------------------------------
    // Example: start
    // -------------------------------------------------------------
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

    // -------------------------------------------------------------
    // Example: complex (e-commerce demo)
    // -------------------------------------------------------------
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

    // -------------------------------------------------------------
    // Example: pool (connection-pool demo)
    // -------------------------------------------------------------
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

    // -------------------------------------------------------------
    // Benchmarks
    // -------------------------------------------------------------
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("zent", zent_mod);
    bench_mod.addImport("sqlite3_c", sqlite_c_mod);
    bench_mod.linkSystemLibrary("sqlite3", .{});
    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("benchmark", "Run performance benchmarks");
    bench_step.dependOn(&run_bench.step);

    // -------------------------------------------------------------
    // Top-level test step
    // -------------------------------------------------------------
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // -------------------------------------------------------------
    // Integration tests (SQLite always; Postgres/MySQL when present)
    // -------------------------------------------------------------
    const integ_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    integ_mod.addImport("zent", zent_mod);
    integ_mod.addImport("sqlite3_c", sqlite_c_mod);
    if (pg_c_mod) |m| integ_mod.addImport("pg_c", m);
    if (my_c_mod) |m| integ_mod.addImport("mysql_c", m);
    linkSqlite(integ_mod);
    if (pg_include_dir) |inc| linkPg(integ_mod, inc, pg_lib_dir.?);
    if (my_include_dir) |inc| linkMySQL(integ_mod, inc, my_lib_dir.?);

    const integ_tests = b.addTest(.{
        .root_module = integ_mod,
    });
    const run_integ_tests = b.addRunArtifact(integ_tests);
    const integ_step = b.step("test-integration", "Run integration tests (SQLite/Postgres/MySQL when servers are available)");
    integ_step.dependOn(&run_integ_tests.step);
}

// -----------------------------------------------------------------
// Driver discovery helpers
// -----------------------------------------------------------------

const PgInfo = struct {
    include_dir: []const u8,
    lib_dir: []const u8,
};

fn discoverPg(b: *std.Build) ?PgInfo {
    const allocator = b.allocator;

    // 1. pg_config (official PostgreSQL client installs)
    if (execOutput(b, &.{ "pg_config", "--includedir" })) |inc| {
        if (execOutput(b, &.{ "pg_config", "--libdir" })) |lib| {
            const header = std.fs.path.join(allocator, &.{ inc, "libpq-fe.h" }) catch return null;
            if (pathExists(header)) {
                return .{ .include_dir = inc, .lib_dir = lib };
            }
        }
    }

    // 2. pkg-config
    if (firstIncludeDirFromCflags(execOutput(b, &.{ "pkg-config", "--cflags-only-I", "libpq" }))) |inc| {
        if (firstLibDirFromLibs(execOutput(b, &.{ "pkg-config", "--libs-only-L", "libpq" }))) |lib| {
            const header = std.fs.path.join(allocator, &.{ inc, "libpq-fe.h" }) catch return null;
            if (pathExists(header)) {
                return .{ .include_dir = inc, .lib_dir = lib };
            }
        }
    }

    // 3. Homebrew fallback
    return discoverPgHomebrew(b);
}

fn discoverPgHomebrew(b: *std.Build) ?PgInfo {
    const versions = [_][]const u8{ "postgresql@18", "postgresql@17", "postgresql@16", "postgresql@15", "postgresql@14", "postgresql" };
    const homes = [_][]const u8{ "/opt/homebrew/opt", "/usr/local/opt" };
    for (homes) |home| {
        for (versions) |pkg| {
            const versioned = b.fmt("{s}/{s}/include/{s}/libpq-fe.h", .{ home, pkg, pkg });
            const plain = b.fmt("{s}/{s}/include/libpq-fe.h", .{ home, pkg });
            const header = if (pathExists(versioned)) versioned else if (pathExists(plain)) plain else continue;
            const include_dir = std.fs.path.dirname(header).?;
            const lib_home = if (std.mem.eql(u8, home, "/opt/homebrew/opt")) "/opt/homebrew/lib" else "/usr/local/lib";
            const lib_dir = b.fmt("{s}/{s}", .{ lib_home, pkg });
            return .{ .include_dir = include_dir, .lib_dir = lib_dir };
        }
    }
    return null;
}

const MySQLInfo = struct {
    include_dir: []const u8,
    lib_dir: []const u8,
};

fn discoverMySQL(b: *std.Build) ?MySQLInfo {
    const allocator = b.allocator;

    // 1. mariadb_config (MariaDB Connector/C)
    if (execOutput(b, &.{ "mariadb_config", "--variable=pkgincludedir" })) |inc| {
        if (execOutput(b, &.{ "mariadb_config", "--variable=pkglibdir" })) |lib| {
            const header = std.fs.path.join(allocator, &.{ inc, "mysql.h" }) catch return null;
            if (pathExists(header)) {
                // <mariadb/mysql.h> resolves against the parent of pkgincludedir.
                const include_dir = std.fs.path.dirname(inc) orelse inc;
                return .{ .include_dir = include_dir, .lib_dir = lib };
            }
        }
    }

    // 2. pkg-config
    if (firstIncludeDirFromCflags(execOutput(b, &.{ "pkg-config", "--cflags-only-I", "libmariadb" }))) |inc| {
        if (firstLibDirFromLibs(execOutput(b, &.{ "pkg-config", "--libs-only-L", "libmariadb" }))) |lib| {
            const header = std.fs.path.join(allocator, &.{ inc, "mariadb", "mysql.h" }) catch return null;
            if (pathExists(header)) {
                return .{ .include_dir = inc, .lib_dir = lib };
            }
        }
    }

    // 3. Homebrew fallback
    return discoverMySQLHomebrew(b);
}

fn discoverMySQLHomebrew(b: *std.Build) ?MySQLInfo {
    const homes = [_][]const u8{ "/opt/homebrew/opt", "/usr/local/opt" };
    for (homes) |home| {
        const header = b.fmt("{s}/mariadb-connector-c/include/mariadb/mysql.h", .{home});
        if (pathExists(header)) {
            const include_dir = b.fmt("{s}/mariadb-connector-c/include", .{home});
            const lib_dir = b.fmt("{s}/mariadb-connector-c/lib", .{home});
            return .{ .include_dir = include_dir, .lib_dir = lib_dir };
        }
    }
    return null;
}

fn linkSqlite(m: *std.Build.Module) void {
    m.linkSystemLibrary("sqlite3", .{});
}

fn linkPg(m: *std.Build.Module, include_dir: []const u8, lib_dir: []const u8) void {
    m.addIncludePath(.{ .cwd_relative = include_dir });
    m.addLibraryPath(.{ .cwd_relative = lib_dir });
    m.linkSystemLibrary("pq", .{});
}

fn linkMySQL(m: *std.Build.Module, include_dir: []const u8, lib_dir: []const u8) void {
    m.addIncludePath(.{ .cwd_relative = include_dir });
    m.addLibraryPath(.{ .cwd_relative = lib_dir });
    m.linkSystemLibrary("mariadb", .{});
}

// -----------------------------------------------------------------
// Command / filesystem helpers
// -----------------------------------------------------------------

/// Run a command and return trimmed stdout, or null on failure.
/// Memory is allocated from the build arena and does not need to be freed.
fn execOutput(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(b.allocator, b.graph.io, .{ .argv = argv }) catch return null;
    if (!result.term.success()) return null;
    return std.mem.trim(u8, result.stdout, " \n\r\t");
}

/// Parse the first `-I/path` from `pkg-config --cflags-only-I` output.
fn firstIncludeDirFromCflags(cflags: ?[]const u8) ?[]const u8 {
    const flags = cflags orelse return null;
    var it = std.mem.splitSequence(u8, flags, " ");
    while (it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-I") and flag.len > 2) {
            return flag[2..];
        }
    }
    return null;
}

/// Parse the first `-L/path` from `pkg-config --libs-only-L` output.
fn firstLibDirFromLibs(libs: ?[]const u8) ?[]const u8 {
    const flags = libs orelse return null;
    var it = std.mem.splitSequence(u8, flags, " ");
    while (it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-L") and flag.len > 2) {
            return flag[2..];
        }
    }
    return null;
}

extern "c" fn stat(path: [*:0]const u8, buf: *anyopaque) c_int;

/// Returns true if `path` points to an existing file system object.
/// Limited to short paths (Homebrew locations are well under the buffer).
fn pathExists(path: []const u8) bool {
    var zbuf: [512:0]u8 = std.mem.zeroes([512:0]u8);
    if (path.len >= zbuf.len) return false;
    @memcpy(zbuf[0..path.len], path);
    var st: [144]u8 = undefined;
    return stat(@ptrCast(&zbuf), @ptrCast(&st)) == 0;
}
