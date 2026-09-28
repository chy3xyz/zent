const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------------------
    // Translate-C steps: convert C headers -> Zig binding modules
    // -------------------------------------------------------------

    // Which driver bindings to translate. The default is unchanged — a driver
    // whose headers are on the machine is translated — but "the headers are
    // installed" is the wrong question for a build host: a PostgreSQL-only
    // deployment was paying for three `translate-c` steps, which on a cold
    // global cache is ~30 s and up to ~570 MB peak *each*, i.e. the bulk of a
    // consumer's first build. A consumer that links one driver can now say so:
    //   zig build -Dsqlite=false -Dmysql=false     // PostgreSQL only
    // Turning off a driver you *do* link fails with "no module named
    // sqlite3_c/pg_c/mysql_c" at the first use, which names the mistake.
    const use_sqlite = b.option(bool, "sqlite", "translate the SQLite driver bindings (default: true)") orelse true;
    const want_pg = b.option(bool, "pg", "translate the PostgreSQL driver bindings when libpq headers are present (default: true)") orelse true;
    const want_mysql = b.option(bool, "mysql", "translate the MySQL driver bindings when the MariaDB/MySQL headers are present (default: true)") orelse true;

    // Driver discovery runs once, here, and is applied through `DriverLink` so
    // that every module linking a C library takes the same paths — this build's
    // modules and, through `linkDrivers`, a consumer's. See the doc comment on
    // `DriverLink` for why "the same paths" is the whole point.
    const root = crossRoot(b);
    const link = DriverLink{ .b = b, .target = target, .root = root };
    warnCrossWithoutRoot(b, target, root);

    // Headers and libraries come from the target's own root when there is one,
    // and from the build host only when the target *is* the build host.
    const pg: ?PgInfo = blk: {
        if (!want_pg) break :blk null;
        break :blk discoverPg(b, target, root);
    };
    const my: ?MySQLInfo = blk: {
        if (!want_mysql) break :blk null;
        break :blk discoverMySQL(b, target, root);
    };

    // sqlite3 — translated unless the consumer says it links no SQLite.
    const sqlite_c_mod: ?*std.Build.Module = if (use_sqlite) blk: {
        const tc = b.addTranslateC(.{
            .root_source_file = b.path("src/sql/sqlite3_include.h"),
            .target = target,
            .optimize = optimize,
        });
        // A cross root carries the target's `sqlite3.h`; without the path the
        // step quietly takes the host's header for a foreign target.
        if (root) |r| tc.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{r}) });
        const mod = tc.createModule();
        // The link belongs on the module, not on the `TranslateC` step: the
        // step has no `addLibraryPath`, so a cross build that needed the
        // target's `-L` for sqlite3 died inside the translate-c node, before
        // the link that could have said so.
        link.sqlite(mod);
        break :blk mod;
    } else null;

    // PostgreSQL client — optional, only if the target has libpq headers.
    const pg_c_mod = blk: {
        const info = pg orelse break :blk null;
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

    // MariaDB/MySQL client — optional, only if the target has those headers.
    const my_c_mod = blk: {
        const info = my orelse break :blk null;
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
    if (sqlite_c_mod) |sqlite_c| zent_mod.addImport("sqlite3_c", sqlite_c);
    if (pg_c_mod) |m| zent_mod.addImport("pg_c", m);
    if (my_c_mod) |m| zent_mod.addImport("mysql_c", m);

    // Build options: tell the test roots which DB C bindings are available,
    // so `zig build test` still compiles on machines without libpq/libmariadb.
    const build_options = b.addOptions();
    build_options.addOption(bool, "have_pg", pg_c_mod != null);
    build_options.addOption(bool, "have_mysql", my_c_mod != null);
    const build_options_mod = build_options.createModule();

    // -------------------------------------------------------------
    // Library unit tests
    // -------------------------------------------------------------
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (sqlite_c_mod) |sqlite_c| test_mod.addImport("sqlite3_c", sqlite_c);
    if (pg_c_mod) |m| test_mod.addImport("pg_c", m);
    if (my_c_mod) |m| test_mod.addImport("mysql_c", m);
    test_mod.addImport("build_options", build_options_mod);
    link.sqlite(test_mod);
    if (pg) |info| link.pg(test_mod, info);
    if (my) |info| link.mysql(test_mod, info);

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
    if (sqlite_c_mod) |sqlite_c| start_mod.addImport("sqlite3_c", sqlite_c);
    link.sqlite(start_mod);
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
    if (sqlite_c_mod) |sqlite_c| complex_mod.addImport("sqlite3_c", sqlite_c);
    link.sqlite(complex_mod);
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
    if (sqlite_c_mod) |sqlite_c| pool_mod.addImport("sqlite3_c", sqlite_c);
    link.sqlite(pool_mod);
    const pool_exe = b.addExecutable(.{
        .name = "pool",
        .root_module = pool_mod,
    });
    b.installArtifact(pool_exe);

    const run_pool = b.addRunArtifact(pool_exe);
    const pool_step = b.step("run-pool", "Run the connection pool example");
    pool_step.dependOn(&run_pool.step);

    // -------------------------------------------------------------
    // Example: advanced (unique index / paged / masking / outbox)
    // -------------------------------------------------------------
    const advanced_mod = b.createModule(.{
        .root_source_file = b.path("examples/advanced/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    advanced_mod.addImport("zent", zent_mod);
    if (sqlite_c_mod) |sqlite_c| advanced_mod.addImport("sqlite3_c", sqlite_c);
    link.sqlite(advanced_mod);
    const advanced_exe = b.addExecutable(.{
        .name = "advanced",
        .root_module = advanced_mod,
    });
    b.installArtifact(advanced_exe);

    const run_advanced = b.addRunArtifact(advanced_exe);
    const advanced_step = b.step("run-advanced", "Run the advanced patterns example");
    advanced_step.dependOn(&run_advanced.step);

    // -------------------------------------------------------------
    // Example: migrate (file-based migrations)
    // -------------------------------------------------------------
    const migrate_mod = b.createModule(.{
        .root_source_file = b.path("examples/migrate/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    migrate_mod.addImport("zent", zent_mod);
    if (sqlite_c_mod) |sqlite_c| migrate_mod.addImport("sqlite3_c", sqlite_c);
    if (pg_c_mod) |m| migrate_mod.addImport("pg_c", m);
    if (my_c_mod) |m| migrate_mod.addImport("mysql_c", m);
    migrate_mod.addImport("build_options", build_options_mod);
    link.sqlite(migrate_mod);
    if (pg) |info| link.pg(migrate_mod, info);
    if (my) |info| link.mysql(migrate_mod, info);

    const migrate_exe = b.addExecutable(.{
        .name = "migrate",
        .root_module = migrate_mod,
    });
    b.installArtifact(migrate_exe);

    const run_migrate = b.addRunArtifact(migrate_exe);
    const migrate_step = b.step("migrate", "Apply pending migrations from ZENT_MIGRATIONS_DIR (default: migrations)");
    migrate_step.dependOn(&run_migrate.step);

    const run_rollback = b.addRunArtifact(migrate_exe);
    run_rollback.setEnvironmentVariable("ZENT_MIGRATE_CMD", "down");
    const rollback_step = b.step("migrate-rollback", "Roll back the most recent migration");
    rollback_step.dependOn(&run_rollback.step);

    // -------------------------------------------------------------
    // Example: interceptor (multi-tenant query rewriting)
    // -------------------------------------------------------------
    const interceptor_mod = b.createModule(.{
        .root_source_file = b.path("examples/interceptor/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    interceptor_mod.addImport("zent", zent_mod);
    if (sqlite_c_mod) |sqlite_c| interceptor_mod.addImport("sqlite3_c", sqlite_c);
    link.sqlite(interceptor_mod);
    const interceptor_exe = b.addExecutable(.{
        .name = "interceptor",
        .root_module = interceptor_mod,
    });
    b.installArtifact(interceptor_exe);

    const run_interceptor = b.addRunArtifact(interceptor_exe);
    const interceptor_step = b.step("run-interceptor", "Run the interceptor (multi-tenant) example");
    interceptor_step.dependOn(&run_interceptor.step);

    // -------------------------------------------------------------
    // Example: check_sql (validate raw SQL without running it)
    // -------------------------------------------------------------
    // The tool body is its own module so `tests/integration/check_sql_cli.zig`
    // can drive it in-process — no subprocess, no second test harness.
    const check_sql_cli_mod = b.createModule(.{
        .root_source_file = b.path("examples/check_sql/cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    check_sql_cli_mod.addImport("zent", zent_mod);
    if (sqlite_c_mod) |sqlite_c| check_sql_cli_mod.addImport("sqlite3_c", sqlite_c);
    if (pg_c_mod) |m| check_sql_cli_mod.addImport("pg_c", m);
    if (my_c_mod) |m| check_sql_cli_mod.addImport("mysql_c", m);
    check_sql_cli_mod.addImport("build_options", build_options_mod);
    link.sqlite(check_sql_cli_mod);
    if (pg) |info| link.pg(check_sql_cli_mod, info);
    if (my) |info| link.mysql(check_sql_cli_mod, info);

    const check_sql_mod = b.createModule(.{
        .root_source_file = b.path("examples/check_sql/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    check_sql_mod.addImport("check_sql_cli", check_sql_cli_mod);
    link.sqlite(check_sql_mod);
    if (pg) |info| link.pg(check_sql_mod, info);
    if (my) |info| link.mysql(check_sql_mod, info);

    const check_sql_exe = b.addExecutable(.{
        .name = "check_sql",
        .root_module = check_sql_mod,
    });
    b.installArtifact(check_sql_exe);

    const run_check_sql = b.addRunArtifact(check_sql_exe);
    // A smoke run over the sample: every statement in it is clean, so the step
    // is green. The DSN is pinned so a developer's $ZENT_DSN cannot change it.
    run_check_sql.addFileArg(b.path("examples/check_sql/sample.sql"));
    run_check_sql.setEnvironmentVariable("ZENT_DSN", "sqlite::memory:");
    const check_sql_step = b.step("run-check-sql", "Check examples/check_sql/sample.sql without executing it");
    check_sql_step.dependOn(&run_check_sql.step);

    // -------------------------------------------------------------
    // Benchmarks
    // -------------------------------------------------------------
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("zent", zent_mod);
    if (sqlite_c_mod) |sqlite_c| bench_mod.addImport("sqlite3_c", sqlite_c);
    link.sqlite(bench_mod);
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
    if (sqlite_c_mod) |sqlite_c| integ_mod.addImport("sqlite3_c", sqlite_c);
    if (pg_c_mod) |m| integ_mod.addImport("pg_c", m);
    if (my_c_mod) |m| integ_mod.addImport("mysql_c", m);
    integ_mod.addImport("build_options", build_options_mod);
    // The check_sql CLI is a consumer of the library, so its end-to-end test
    // lives with the other integration tests and drives the real tool body.
    integ_mod.addImport("check_sql_cli", check_sql_cli_mod);
    link.sqlite(integ_mod);
    if (pg) |info| link.pg(integ_mod, info);
    if (my) |info| link.mysql(integ_mod, info);

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

/// True when the build's target is the machine the build script runs on.
///
/// Compared on the resolved triple rather than `target.query.isNative()`, so an
/// explicit `-Dtarget=aarch64-macos` on an aarch64 Mac is still a host build,
/// while anything with a foreign arch/os/abi is not — and must never be handed
/// the host's `-I`/`-L`. Those directories hold the host's own objects for a
/// foreign link: `ld` answers with one "undefined symbol" per symbol in the
/// archive, and the log names none of the paths that caused it.
fn isHostTarget(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = b.graph.host.result;
    return target.result.cpu.arch == host.cpu.arch and
        target.result.os.tag == host.os.tag and
        target.result.abi == host.abi;
}

/// The **target's** root — a Debian/Ubuntu sysroot or a distro rootfs — or
/// null when the caller named none.
///
/// Two spellings, because there are two kinds of caller. `XCOMPILE_ROOT` (or
/// `ZENT_XROOT`) is what a cross build in this ecosystem already exports, and it
/// is the one that works from a shell. The `xroot` **option** is for a parent
/// build script that already reads its own `-Dxroot=` (a CLI flag is validated
/// against the root package, so a dependency can never see it directly — it has
/// to arrive through `b.dependency("zent", .{ .xroot = … })`). The option wins
/// when the parent forwards one, so a caller that sets both gets what it passed.
fn crossRoot(b: *std.Build) ?[]const u8 {
    const forwarded = b.option(
        []const u8,
        "xroot",
        "cross-compile root: the target's headers and libraries (empty = $XCOMPILE_ROOT/$ZENT_XROOT, else probe the host when the target is the host)",
    );
    if (forwarded) |root| {
        if (root.len > 0) return root;
    }
    return envValue(b, "XCOMPILE_ROOT") orelse envValue(b, "ZENT_XROOT");
}

/// `getenv` for a build script, with an empty value treated as unset: the
/// `XCOMPILE_ROOT=` line a wrapper script leaves behind means "unset", not
/// "/". The returned slice is owned by the build graph and outlives the script.
fn envValue(b: *std.Build, name: []const u8) ?[]const u8 {
    const value = b.graph.environ_map.get(name) orelse return null;
    if (value.len == 0) return null;
    return value;
}

/// The GNU multiarch triple for `arch`, the directory Debian and Ubuntu keep
/// their libraries in (`/usr/lib/aarch64-linux-gnu`). Null for an arch whose
/// spelling this does not know: the plain `usr/lib` candidates are searched
/// either way, so an unknown triple costs a directory, not the build.
fn multiarchTriple(arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (arch) {
        .aarch64, .aarch64_be => "aarch64-linux-gnu",
        .x86_64 => "x86_64-linux-gnu",
        .arm, .armeb, .thumb, .thumbeb => "arm-linux-gnueabihf",
        .riscv64 => "riscv64-linux-gnu",
        else => null,
    };
}

/// The target's library directories inside `root`, in search order: the
/// multiarch spellings first, where Debian and Ubuntu put everything, then the
/// plain ones for RHEL/SUSE and hand-rolled rootfs. Only directories that exist
/// are returned — a path the target does not have is noise in every verbose
/// log and a directory the linker will not have either.
///
/// A value type rather than an allocation: discovery runs on both this build's
/// path and a consumer's, and the build arena is not worth gambling on for four
/// strings.
const LibDirs = struct {
    buf: [4][]const u8 = undefined,
    len: usize = 0,

    fn slice(dirs: *const LibDirs) []const []const u8 {
        return dirs.buf[0..dirs.len];
    }

    fn add(dirs: *LibDirs, b: *std.Build, dir: []const u8) void {
        if (pathExists(b, dir)) {
            dirs.buf[dirs.len] = dir;
            dirs.len += 1;
        }
    }
};

fn targetLibDirs(b: *std.Build, target: std.Build.ResolvedTarget, root: []const u8) LibDirs {
    var dirs: LibDirs = .{};
    if (multiarchTriple(target.result.cpu.arch)) |triple| {
        dirs.add(b, b.fmt("{s}/usr/lib/{s}", .{ root, triple }));
        dirs.add(b, b.fmt("{s}/lib/{s}", .{ root, triple }));
    }
    dirs.add(b, b.fmt("{s}/usr/lib64", .{root}));
    dirs.add(b, b.fmt("{s}/usr/lib", .{root}));
    return dirs;
}

/// Which MySQL client library to link: `mariadb` (MariaDB Connector/C, what
/// this build has always linked) or `mysqlclient` (Debian's
/// `libmysqlclient-dev`, Homebrew's `mysql-client`). A target is free to ship
/// either, and `-lmariadb` against a root holding only `libmysqlclient` is
/// exactly the reported failure — the link named `libmysqlclient.a` and the
/// build never asked for it. Null when there is no directory to read the
/// answer from.
fn probeMySqlLibName(b: *std.Build, lib_dirs: []const []const u8) ?[]const u8 {
    const names = [_][]const u8{ "mariadb", "mysqlclient" };
    const exts = [_][]const u8{ "so", "so.3", "dylib", "a" };
    for (names) |name| {
        for (lib_dirs) |dir| {
            for (exts) |ext| {
                if (pathExists(b, b.fmt("{s}/lib{s}.{s}", .{ dir, name, ext }))) return name;
            }
        }
    }
    return null;
}

/// The library name to link, from whichever directory can answer: an explicit
/// `ZENT_MYSQL_LIB_DIR`, the host's install directory, or a cross root's own
/// directories. Falls back to `mariadb`, which is what the native path has
/// always linked and must keep linking — a Homebrew install whose library name
/// cannot be read is not a reason to change it.
fn mysqlLibName(b: *std.Build, target: std.Build.ResolvedTarget, root: ?[]const u8, lib_dir: ?[]const u8) []const u8 {
    if (lib_dir) |dir| {
        const one = [_][]const u8{dir};
        return probeMySqlLibName(b, &one) orelse "mariadb";
    }
    if (root) |r| {
        const dirs = targetLibDirs(b, target, r);
        return probeMySqlLibName(b, dirs.slice()) orelse "mariadb";
    }
    return "mariadb";
}

const PgInfo = struct {
    include_dir: []const u8,
    /// Null when the library directory is not this discovery's to name: a cross
    /// root adds its own directories wholesale (`DriverLink.addTargetLibDirs`),
    /// and an include-only override expects the consumer to supply the `-L`.
    lib_dir: ?[]const u8,
};

/// Find libpq for `target`: from the target's own root when there is one, from
/// this machine only when `target` is this machine.
fn discoverPg(b: *std.Build, target: std.Build.ResolvedTarget, root: ?[]const u8) ?PgInfo {
    const allocator = b.allocator;

    // 1. Explicit override — it wins over everything, including a root, because
    //    whoever set it is describing one specific target's install.
    if (envValue(b, "ZENT_PG_INCLUDE_DIR")) |inc| {
        return .{ .include_dir = inc, .lib_dir = envValue(b, "ZENT_PG_LIB_DIR") };
    }

    // 2. A cross root: the three layouts libpq headers arrive in.
    if (root) |r| {
        const layouts = [_][]const u8{
            "/usr/include/libpq-fe.h",
            "/usr/include/postgresql/libpq-fe.h",
            "/usr/include/pgsql/libpq-fe.h",
        };
        for (layouts) |layout| {
            const header = b.fmt("{s}{s}", .{ r, layout });
            if (pathExists(b, header)) {
                return .{ .include_dir = std.fs.path.dirname(header).?, .lib_dir = null };
            }
        }
        return null;
    }

    // 3. The build host — reachable only for a host target. Probing it for a
    //    foreign target is the defect this function was rewritten for.
    if (!isHostTarget(b, target)) return null;

    // 3a. pg_config (official PostgreSQL client installs)
    if (execOutput(b, &.{ "pg_config", "--includedir" })) |inc| {
        if (execOutput(b, &.{ "pg_config", "--libdir" })) |lib| {
            const header = std.fs.path.join(allocator, &.{ inc, "libpq-fe.h" }) catch return null;
            if (pathExists(b, header)) {
                return .{ .include_dir = inc, .lib_dir = lib };
            }
        }
    }

    // 3b. pkg-config
    if (firstIncludeDirFromCflags(execOutput(b, &.{ "pkg-config", "--cflags-only-I", "libpq" }))) |inc| {
        if (firstLibDirFromLibs(execOutput(b, &.{ "pkg-config", "--libs-only-L", "libpq" }))) |lib| {
            const header = std.fs.path.join(allocator, &.{ inc, "libpq-fe.h" }) catch return null;
            if (pathExists(b, header)) {
                return .{ .include_dir = inc, .lib_dir = lib };
            }
        }
    }

    // 3c. Homebrew fallback
    return discoverPgHomebrew(b);
}

fn discoverPgHomebrew(b: *std.Build) ?PgInfo {
    // `libpq` is the keg-only brew package name (no pg_config binary); the
    // postgresql@N formulas expose the same header under a versioned prefix.
    const versions = [_][]const u8{ "postgresql@18", "postgresql@17", "postgresql@16", "postgresql@15", "postgresql@14", "postgresql", "libpq" };
    const homes = [_][]const u8{ "/opt/homebrew/opt", "/usr/local/opt" };
    for (homes) |home| {
        for (versions) |pkg| {
            const versioned = b.fmt("{s}/{s}/include/{s}/libpq-fe.h", .{ home, pkg, pkg });
            const plain = b.fmt("{s}/{s}/include/libpq-fe.h", .{ home, pkg });
            const header = if (pathExists(b, versioned)) versioned else if (pathExists(b, plain)) plain else continue;
            const include_dir = std.fs.path.dirname(header).?;
            const lib_home = if (std.mem.eql(u8, home, "/opt/homebrew/opt")) "/opt/homebrew/lib" else "/usr/local/lib";
            // keg-only packages keep their libraries under the opt prefix.
            const lib_dir = if (std.mem.eql(u8, pkg, "libpq"))
                b.fmt("{s}/libpq/lib", .{home})
            else
                b.fmt("{s}/{s}", .{ lib_home, pkg });
            return .{ .include_dir = include_dir, .lib_dir = lib_dir };
        }
    }
    return null;
}

const MySQLInfo = struct {
    include_dir: []const u8,
    /// See `PgInfo.lib_dir`.
    lib_dir: ?[]const u8,
    /// `mariadb` or `mysqlclient` — probed from the library directory, see
    /// `probeMySqlLibName`.
    lib_name: []const u8,
};

/// Find the MariaDB/MySQL client headers for `target`, from the target's own
/// root when there is one, from this machine only when `target` is this machine.
fn discoverMySQL(b: *std.Build, target: std.Build.ResolvedTarget, root: ?[]const u8) ?MySQLInfo {
    const allocator = b.allocator;

    // 1. Explicit override.
    if (envValue(b, "ZENT_MYSQL_INCLUDE_DIR")) |inc| {
        const lib_dir = envValue(b, "ZENT_MYSQL_LIB_DIR");
        return .{
            .include_dir = inc,
            .lib_dir = lib_dir,
            .lib_name = mysqlLibName(b, target, root, lib_dir),
        };
    }

    // 2. A cross root: `mysql.h` under either client's spelling, plus the bare
    //    layout. All three mean `usr/include`, which is where the clients
    //    install.
    //
    //    Only the `mariadb/` layout satisfies `<mariadb/mysql.h>`, the spelling
    //    `src/sql/mysql_include.h` uses: a root carrying only `mysql/mysql.h`
    //    discovers the driver here and then fails loudly at the translate-c
    //    step naming the header, which is better than a step that silently
    //    links against headers the binding cannot include.
    if (root) |r| {
        const layouts = [_][]const u8{
            "/usr/include/mariadb/mysql.h",
            "/usr/include/mysql/mysql.h",
            "/usr/include/mysql.h",
        };
        for (layouts) |layout| {
            if (pathExists(b, b.fmt("{s}{s}", .{ r, layout }))) {
                return .{
                    .include_dir = b.fmt("{s}/usr/include", .{r}),
                    .lib_dir = null,
                    .lib_name = mysqlLibName(b, target, root, null),
                };
            }
        }
        return null;
    }

    // 3. The build host — reachable only for a host target.
    if (!isHostTarget(b, target)) return null;

    // 3a. mariadb_config (MariaDB Connector/C)
    if (execOutput(b, &.{ "mariadb_config", "--variable=pkgincludedir" })) |inc| {
        if (execOutput(b, &.{ "mariadb_config", "--variable=pkglibdir" })) |lib| {
            const header = std.fs.path.join(allocator, &.{ inc, "mysql.h" }) catch return null;
            if (pathExists(b, header)) {
                // <mariadb/mysql.h> resolves against the parent of pkgincludedir.
                const include_dir = std.fs.path.dirname(inc) orelse inc;
                return .{
                    .include_dir = include_dir,
                    .lib_dir = lib,
                    .lib_name = mysqlLibName(b, target, root, lib),
                };
            }
        }
    }

    // 3b. pkg-config
    if (firstIncludeDirFromCflags(execOutput(b, &.{ "pkg-config", "--cflags-only-I", "libmariadb" }))) |inc| {
        if (firstLibDirFromLibs(execOutput(b, &.{ "pkg-config", "--libs-only-L", "libmariadb" }))) |lib| {
            const header = std.fs.path.join(allocator, &.{ inc, "mariadb", "mysql.h" }) catch return null;
            if (pathExists(b, header)) {
                return .{
                    .include_dir = inc,
                    .lib_dir = lib,
                    .lib_name = mysqlLibName(b, target, root, lib),
                };
            }
        }
    }

    // 3c. Homebrew fallback
    return discoverMySQLHomebrew(b, target);
}

fn discoverMySQLHomebrew(b: *std.Build, target: std.Build.ResolvedTarget) ?MySQLInfo {
    const homes = [_][]const u8{ "/opt/homebrew/opt", "/usr/local/opt" };
    for (homes) |home| {
        const header = b.fmt("{s}/mariadb-connector-c/include/mariadb/mysql.h", .{home});
        if (pathExists(b, header)) {
            const include_dir = b.fmt("{s}/mariadb-connector-c/include", .{home});
            const lib_dir = b.fmt("{s}/mariadb-connector-c/lib", .{home});
            return .{
                .include_dir = include_dir,
                .lib_dir = lib_dir,
                .lib_name = mysqlLibName(b, target, null, lib_dir),
            };
        }
    }
    return null;
}

/// One place that turns (target, driver) into `-I`/`-L`/`-l` on a module: every
/// module in this build that links a C library goes through it, and
/// `linkDrivers` hands the same one to consumers.
///
/// The single place matters, because the two drifting apart is a real defect
/// rather than a hypothetical: a sibling project's copy of this discovery
/// branched on the *host* triple, so a Linux link was handed
/// `/opt/homebrew/opt/mysql`'s `libmysqlclient.a` (a Mach-O archive) on top of
/// the consumer's own sysroot `-L`, and the link failed naming every symbol in
/// it. Host paths are legitimate only for a host target; a cross build's paths
/// come from `XCOMPILE_ROOT` or the per-driver overrides.
const DriverLink = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    /// The target's root, or null — see `crossRoot`.
    root: ?[]const u8,

    /// Add the target root's own library directories. A no-op without a root:
    /// on a host build the driver's own `lib_dir` already names them.
    fn addTargetLibDirs(self: DriverLink, m: *std.Build.Module) void {
        const root = self.root orelse return;
        const dirs = targetLibDirs(self.b, self.target, root);
        for (dirs.slice()) |dir| {
            m.addLibraryPath(.{ .cwd_relative = dir });
        }
    }

    fn sqlite(self: DriverLink, m: *std.Build.Module) void {
        self.addTargetLibDirs(m);
        m.linkSystemLibrary("sqlite3", .{});
    }

    fn pg(self: DriverLink, m: *std.Build.Module, info: PgInfo) void {
        self.addTargetLibDirs(m);
        m.addIncludePath(.{ .cwd_relative = info.include_dir });
        if (info.lib_dir) |dir| m.addLibraryPath(.{ .cwd_relative = dir });
        m.linkSystemLibrary("pq", .{});
    }

    fn mysql(self: DriverLink, m: *std.Build.Module, info: MySQLInfo) void {
        self.addTargetLibDirs(m);
        m.addIncludePath(.{ .cwd_relative = info.include_dir });
        if (info.lib_dir) |dir| m.addLibraryPath(.{ .cwd_relative = dir });
        m.linkSystemLibrary(info.lib_name, .{});
    }
};

/// Which of the three drivers a consumer links, and where the target's headers
/// and libraries are.
pub const Drivers = struct {
    sqlite: bool = true,
    pg: bool = true,
    mysql: bool = true,
    /// The **target's** root, when the caller has one (its own `-Dxroot=`, an
    /// env var it read, a sysroot it knows). Passed in rather than read from an
    /// option here: this function runs inside the *consumer's* build script, and
    /// `b.option` panics if the same name is declared twice on one builder — a
    /// consumer with its own `xroot` option is the normal case, not an edge.
    /// `null` falls back to `XCOMPILE_ROOT`/`ZENT_XROOT`, then to host probing
    /// when the target is the host.
    root: ?[]const u8 = null,
};

/// Link the driver libraries `mod` needs, with the same discovery this build
/// uses — one place that knows a host's Homebrew prefixes *and* a target's
/// root, so a consumer's build script cannot hand the build machine's libraries
/// to a foreign link. See `DriverLink`.
///
/// From the consumer's `build` function, with `zent` declared as a dependency:
///
/// ```zig
/// const zent_dep = b.dependency("zent", .{ .target = target, .optimize = optimize });
/// exe.root_module.addImport("zent", zent_dep.module("zent"));
/// const zent_build = b.lazyImport(@This(), "zent").?;
/// zent_build.linkDrivers(b, exe.root_module, target, .{});
/// ```
///
/// `b` and `target` are the consumer's own (the `standardTargetOptions`
/// result, the same one passed to `b.dependency`): that pair is what decides
/// whether the host's prefixes may be used at all. Pass
/// `.{ .pg = false, .mysql = false }` to link SQLite alone.
///
/// A driver whose headers were not found is skipped, never an error: the
/// consumer decides what it links, and a cross build with no `XCOMPILE_ROOT`
/// finds no headers at all. (It still warns, once, that host discovery was
/// skipped — see `warnCrossWithoutRoot`.)
pub fn linkDrivers(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, drivers: Drivers) void {
    const root = drivers.root orelse envValue(b, "XCOMPILE_ROOT") orelse envValue(b, "ZENT_XROOT");
    warnCrossWithoutRoot(b, target, root);
    const link = DriverLink{ .b = b, .target = target, .root = root };
    if (drivers.sqlite) link.sqlite(mod);
    if (drivers.pg) {
        if (discoverPg(b, target, root)) |info| link.pg(mod, info);
    }
    if (drivers.mysql) {
        if (discoverMySQL(b, target, root)) |info| link.mysql(mod, info);
    }
}

/// Say so, once, when a cross build has nowhere to look. Silence would read as
/// "zent found your drivers", when the truth is "host discovery was skipped by
/// design": the build machine's libpq is the wrong ABI for the target, and the
/// alternative to saying so is a link error that names none of this.
fn warnCrossWithoutRoot(b: *std.Build, target: std.Build.ResolvedTarget, root: ?[]const u8) void {
    if (isHostTarget(b, target)) return;
    if (root != null) return;
    if (envValue(b, "ZENT_PG_INCLUDE_DIR") != null or envValue(b, "ZENT_MYSQL_INCLUDE_DIR") != null) return;
    std.log.warn(
        "cross-compiling for {s}-{s}: skipping host driver discovery (pg_config, pkg-config, Homebrew), whose paths belong to the build machine. Set XCOMPILE_ROOT to the target's root (a sysroot or a distro rootfs), or point ZENT_PG_INCLUDE_DIR/ZENT_PG_LIB_DIR and ZENT_MYSQL_INCLUDE_DIR/ZENT_MYSQL_LIB_DIR at the target's headers and libraries. sqlite3 is expected from the target's own library path.",
        .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) },
    );
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

/// Returns true if `path` points to an existing file system object.
/// Uses Zig Io (no `extern "c"`) so the build runner need not link libc.
fn pathExists(b: *std.Build, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(b.graph.io, path, .{}) catch return false;
    return true;
}
