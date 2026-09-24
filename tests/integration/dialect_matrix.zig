//! Cross-dialect matrix: one logical operation, three dialects, **one answer**.
//!
//! The per-dialect integration files (`sqlite.zig`, `postgres.zig`,
//! `mysql.zig`) are each self-consistent: every assertion in them is checked
//! against the server that file talks to. That is how this repository shipped
//! the same class of defect over and over — a call whose answer depended on
//! which server was behind it, noticed only when a consumer reported it:
//!
//!   * MySQL counts **changed** rows, SQLite and PostgreSQL **matched** rows, so
//!     an idempotent write-back answered `0`/`false` on MySQL alone
//!     (`crud.update`, `crud_helpers.update`, `crud_helpers.increment`,
//!     `batchSaveOrUpdate`);
//!   * an eager-loaded target was projected as `<table>.*`, i.e. in *physical*
//!     column order, while the scanner walks the entity in *field* order — the
//!     symptom differed per dialect (SQLite coerced the text to `0` and returned
//!     silently wrong values, MySQL's binary protocol made the getter answer
//!     null and the scan fail with `TypeMismatch`);
//!   * `rows_affected_known` had to be introduced because MySQL answers a real
//!     `0` for DDL where SQLite and PostgreSQL answer "unknown";
//!   * a repeat soft delete rewrote `deleted_at` and counted the row a second
//!     time where the hard path answers `0`;
//!   * a bulk insert derived ids as `base + i`, which is wrong the moment a row
//!     in the chunk is updated instead of inserted.
//!
//! This file is the harness for that class: a table of **cases**, each one a
//! logical operation paired with a dialect-independent **observable answer**. A
//! case runs on every dialect whose server is reachable and the answers must be
//! byte-identical. Fewer than two reachable dialects is a **skip**, never a
//! pass — a one-dialect run proves nothing about agreement.
//!
//! ## What a case may observe
//!
//! Only semantics: a returned bool, a count an API reported, the rows or field
//! values read back, or a named error. The answer is rendered as a canonical
//! string of `name=value` pairs joined by `|`, so a mismatch prints as a diff
//! rather than as a bare `false`. `err:` means the case let an error escape
//! (that name is then part of the answer, because "this dialect refuses the
//! operation" is one of the things the dialects have to agree about).
//!
//! Each case also pins the string it expects. Comparing the dialects alone
//! would go green when all three fail the same way (a setup error on all three
//! renders as the same `err:…`), and the cross-dialect claim is only half the
//! contract: the other half is *which* answer the library promises. A case that
//! cannot state its answer ahead of time carries `expect = null` and is
//! compared across dialects only.
//!
//! Set `DM_TRACE=1` to print every dialect's answer for every case, not only
//! the failing ones (useful when a new server, e.g. CI's MariaDB, first runs
//! the matrix).
//!
//! ## Known divergence — a defect the matrix found, recorded, not blessed
//!
//! A case may carry `known_divergence` when the dialects are known to disagree
//! *today*. Such a case still runs, still compares, and the disagreement is
//! still printed (at `warn` level on every run, so it is visible in CI without
//! failing it) — but it is not allowed to become green: each reachable dialect's
//! answer is pinned with `expect_by_dialect`, and if the dialects ever start
//! agreeing the case fails with `KnownDivergenceResolved` so it gets promoted.
//! An exclusion is for a difference that is *legitimate*; this is for one that
//! is a bug and is waiting for a fix.
//!
//! One case is registered this way:
//!
//! **A wrong-length binding list marks a PostgreSQL connection dead.** Measured
//! through this harness against `PostgreSQL 17.10 (Homebrew)` (libpq 17, the
//! driver linked by `build.zig`); the PostgreSQL half is server-version
//! independent — the SQLSTATE is produced by libpq/the server's protocol
//! handling, and the classification that follows is client-side:
//!
//! ```
//! drv.exec("INSERT INTO t (name, score) VALUES ($1, $2)", &.{ .{ .string = "a" } })
//!     -> error.DriverFailed            (SQLSTATE 08P01, bind message supplies 1
//!                                      parameters, but prepared statement "" requires 2)
//! drv.exec("INSERT INTO t (name, score) VALUES ($1, $2)", &.{ ... , ... })
//!     -> error.DriverFailed            the *correct* list, same statement
//! drv.query("SELECT 1", &.{})
//!     -> error.DriverFailed            a statement that was never involved
//! drv.ping()                           (PQexec, simple protocol)
//!     -> ok                            the socket is fine
//! ```
//!
//! The chain, from the library: `sqlstateToError` maps every SQLSTATE in class
//! `08` (connection exception) to `error.ConnectionFailed`, and the wrong-length
//! Bind arrives as `08P01` `protocol_violation` — the client's own fault, not a
//! broken socket. `PostgresDriver.noteError` then sets `dead = true`, so every
//! later call fails at `ensureAlive` (`PQstatus` is still `CONNECTION_OK`, and
//! `ping` proves it). Consequences: one caller's argument-count bug costs the
//! **connection**, not the statement — and a pool treats the connection as a
//! corpse (`dead` is what keeps it out of `available`), so the next borrower
//! gets a fresh connection but the current one is destroyed. On SQLite and MySQL
//! the same mistake costs one statement (`error.ParamCountMismatch`) and leaves
//! the connection usable. Neither `AGENTS.md` nor `driver.Error`'s doc records
//! this as deliberate, unlike the naming difference (exclusion 2), which is
//! why this one is a case rather than an exclusion. No fix is attempted here:
//! the change (narrow class `08`, or drop the `dead` marking) is a
//! classification decision with its own evidence in the pool's
//! `release`-never-pools-a-corrupt-connection invariant.
//!
//! ## Excluded — differences that are legitimate, dialect by dialect
//!
//! Read this before adding a case that touches the same ground. Each item is a
//! difference a matrix case would otherwise flag as a defect.
//!
//! 1. **Raw `driver.Result.rows_affected`.** MySQL reports *changed* rows
//!    (`CLIENT_FOUND_ROWS` is off), SQLite and PostgreSQL report *matched* rows,
//!    so an idempotent UPDATE legitimately answers `0` on MySQL alone. A
//!    statement whose count was never obtained reports `0` together with
//!    `rows_affected_known == false` (SQLite after a non-DML, PostgreSQL for a
//!    command with no count tag, MySQL for a prepared SELECT) — that flag is the
//!    contract, the number is not. The *normalized* counts are comparable and are
//!    cases below: `crud_helpers.update`, `crud_helpers.increment`,
//!    `crud.update` and `batchSaveOrUpdate` all promise "matched" on every
//!    dialect.
//! 2. **`checkStatement`'s detection ability.** SQLite classifies a failure from
//!    the message text, PostgreSQL reports SQLSTATE `25P02`/`0A000`, and MySQL
//!    answers `not_checkable` for a statement its prepare protocol refuses
//!    (errno 1295, `BEGIN`). That is the designed contract: a driver that cannot
//!    prepare says so instead of guessing, and a bulk audit must not stop
//!    halfway. The *shape* of the answer (`ok` / `failed` / `not_checkable`) is
//!    comparable; which statements land in which bucket is not.
//!
//!    The same applies to the **name** of the wrong-length-binding error, which
//!    is why the case below pins per-dialect answers rather than one shared
//!    answer: `driver.Error`'s own doc records that PostgreSQL does not report
//!    `error.ParamCountMismatch` (libpq answers the same mistake from its Bind
//!    error as `DriverFailed`, and its diagnostics are deliberately not folded
//!    into that name), while SQLite and MySQL both do. `AGENTS.md` records the
//!    same decision. So `short=ParamCountMismatch|long=ParamCountMismatch` is
//!    **not** a cross-dialect contract; `short`/`long` may name the refusal
//!    differently per dialect. What *is* a contract — and what the case asserts
//!    — is that the refusal costs one statement and leaves `after=ok|rows=2`.
//! 3. **Catalog text forms.** `information_schema.column_default` comes back
//!    with the quoting stripped on MySQL 8+ and as the literal expression text
//!    (`'kept'`) on MariaDB; `data_type` spellings differ (`integer` vs `int` vs
//!    `INTEGER`). Compare the *meaning* (is the column nullable, does a
//!    constraint exist), never the string.
//! 4. **Functional indexes.** `CREATE INDEX … ((lower(c)))` is MySQL 8.0.13+;
//!    MariaDB rejects the syntax (errno 1064). CI's `mysql` service is MariaDB
//!    10.11 while a development machine usually runs MySQL 8/9, so no case may
//!    require one on both servers.
//! 5. **`field.Text` with a DEFAULT.** MariaDB creates the column, MySQL refuses
//!    it (errno 1101), and the DDL layer cannot tell the two servers apart. Both
//!    answers are correct for the server that gave them.
//! 6. **Time zone and time precision.** `deleted_at`/`created_at` are epoch
//!    seconds written by the *client* (`time(null)`), while any server-side
//!    clock or `NOW()` may carry a different precision or zone. A case may
//!    compare a timestamp against another timestamp it wrote in the same run
//!    (the soft-delete case below does), never against a literal.
//! 7. **Row order without `ORDER BY`.** No dialect promises one; a case that
//!    reads a page sorts it in the assertion.
//! 8. **Storage classes for `field.Text` / `.json`.** `TEXT` vs MySQL's `JSON`
//!    vs PostgreSQL's `JSONB`: the value round-trips identically, the type name
//!    does not.
//! 9. **Auto-increment values.** They depend on the server's history (the shared
//!    `zent_test` database carries rows from other runs, and another lane may be
//!    writing to it), so a case may assert that an id *addresses the row it was
//!    written for*, never that it equals a particular number.
//! 10. **`isMariaDB` branches.** Where MySQL and MariaDB genuinely differ, the
//!    per-server files branch on `isMariaDB` and assert on both branches. A
//!    matrix case cannot do that (it is one answer for all three dialects), so a
//!    difference that needs the branch belongs in `mysql.zig` — see exclusions
//!    4 and 5 for the two known ones.
//! 11. **`SELECT`-list of an aggregate.** The *shape* of `MAX`/`MIN`/`COUNT`
//!    values differs (`COUNT` is a 64-bit integer everywhere, but SQLite's
//!    `MAX` on an empty set is NULL while a typed column may coerce) — a case
//!    comparing aggregate outputs must compare the value after the library's own
//!    mapping, which is what the per-dialect files already pin.
//! 12. **Empty `IN ()`.** SQLite accepts it and matches nothing; PostgreSQL and
//!    MySQL reject it. The builders never emit it (an empty list is a named
//!    error on the way in), so this only constrains raw SQL — which is out of
//!    scope for a case that goes through the fluent API.

const std = @import("std");
const zent = @import("zent");
const build_options = @import("build_options");
const testing = std.testing;

const Driver = zent.sql_driver.Driver;
const Value = zent.sql.Value;
const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
const buildGraph = zent.codegen.graph.buildGraph;
const Client = zent.codegen.client;
const field = zent.core.field;
const edge = zent.core.edge;
const schema = zent.core.schema.Schema;
const client_mod = zent.codegen.client;

// ------------------------------------------------------------------
// Harness
// ------------------------------------------------------------------

/// One case: a logical operation and the answer it must give on every dialect.
const Case = struct {
    /// Shown in the failure dump and in the test name.
    name: []const u8,
    /// The canonical answer every dialect must produce. `null` only for a case
    /// whose answer cannot be stated ahead of time; the cross-dialect
    /// comparison still runs.
    expect: ?[]const u8 = null,
    /// Set only for a case whose dialects are **known** to disagree today,
    /// with the reason and the measurement. Such a case is not allowed to
    /// agree — but it is allowed to disagree, and each reachable dialect's
    /// answer must then match its `expect_by_dialect` pin, so neither side can
    /// drift unnoticed. See "Known divergence" in the file doc.
    known_divergence: ?[]const u8 = null,
    /// The per-dialect pins of a `known_divergence` case. Harder than `expect`,
    /// not weaker: the disagreement itself is pinned, dialect by dialect.
    expect_by_dialect: []const DialectPin = &.{},
    run: RunFn,
};

/// One dialect's pinned answer. Names come from `Obs.dialect` (`sqlite3`,
/// `postgres`, `mysql`); a dialect with no pin is only compared to the others.
const DialectPin = struct {
    dialect: []const u8,
    answer: []const u8,
};

/// `a` is an arena the harness releases after the whole case has been compared,
/// so an answer may be built from as many temporary strings as it likes.
/// Anything a case allocates on `testing.allocator` is its own to free, and a
/// leak fails the run.
const RunFn = *const fn (a: std.mem.Allocator, drv: Driver) anyerror![]const u8;

const Obs = struct {
    dialect: []const u8,
    answer: []const u8,
};

fn runMatrix(c: Case) !void {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var obs: [3]Obs = undefined;
    var n: usize = 0;

    try observeSqlite(a, allocator, c, &obs, &n);
    try observePg(a, allocator, c, &obs, &n);
    try observeMysql(a, allocator, c, &obs, &n);

    if (n < 2) {
        std.debug.print(
            "dialect-matrix SKIP [{s}]: {d} reachable dialect(s) — agreement needs at least 2\n",
            .{ c.name, n },
        );
        return error.SkipZigTest;
    }

    if (std.process.Environ.getPosix(testing.environ, "DM_TRACE") != null) {
        std.debug.print("dialect-matrix [{s}]\n", .{c.name});
        for (obs[0..n]) |o| std.debug.print("  {s:<9} {s}\n", .{ o.dialect, o.answer });
    }

    var divergent = false;
    for (obs[1..n]) |o| {
        if (!std.mem.eql(u8, o.answer, obs[0].answer)) divergent = true;
    }
    var unpinned: ?Obs = null;
    if (c.expect) |want| {
        for (obs[0..n]) |o| {
            if (!std.mem.eql(u8, o.answer, want)) unpinned = o;
        }
    }

    // A case recording a known divergence must actually diverge. If the
    // dialects start agreeing, the defect was fixed (or the case stopped
    // reaching it) and the case has to be promoted to a plain one: leaving the
    // record in place would hide the change, and that is the one way this file
    // could go stale-green.
    if (!divergent and c.known_divergence != null) {
        std.debug.print(
            "\ndialect-matrix FAIL [{s}]\n  the recorded divergence is gone: the dialects now agree, so this case no longer needs `known_divergence` — promote it and pin `expect`\n  recorded reason: {s}\n",
            .{ c.name, c.known_divergence.? },
        );
        for (obs[0..n]) |o| std.debug.print("  {s:<9} {s}\n", .{ o.dialect, o.answer });
        return error.KnownDivergenceResolved;
    }

    if (divergent and c.known_divergence == null) {
        std.debug.print("\ndialect-matrix FAIL [{s}]\n", .{c.name});
        for (obs[0..n]) |o| {
            std.debug.print("  {s:<9} {s}\n", .{ o.dialect, o.answer });
        }
        if (c.expect) |want| std.debug.print("  {s:<9} {s}\n", .{ "expected", want });
        std.debug.print("  the dialects disagree with each other\n", .{});
        return error.DialectDivergence;
    }

    // Per-dialect pins: the recorded disagreement is checked answer by answer.
    var pin_miss: ?struct { obs: Obs, want: []const u8 } = null;
    for (obs[0..n]) |o| {
        for (c.expect_by_dialect) |pin| {
            if (std.mem.eql(u8, pin.dialect, o.dialect) and !std.mem.eql(u8, pin.answer, o.answer)) {
                pin_miss = .{ .obs = o, .want = pin.answer };
            }
        }
    }

    if (pin_miss == null and unpinned == null) {
        if (divergent and std.process.Environ.getPosix(testing.environ, "DM_TRACE") == null) {
            std.log.warn("dialect-matrix: [{s}] the dialects disagree, as recorded — {s}", .{ c.name, c.known_divergence.? });
            for (obs[0..n]) |o| std.log.warn("  {s:<9} {s}", .{ o.dialect, o.answer });
        }
        return;
    }

    std.debug.print("\ndialect-matrix FAIL [{s}]\n", .{c.name});
    for (obs[0..n]) |o| {
        std.debug.print("  {s:<9} {s}\n", .{ o.dialect, o.answer });
    }
    if (c.expect) |want| std.debug.print("  {s:<9} {s}\n", .{ "expected", want });
    if (pin_miss) |miss| {
        std.debug.print("  pinned     {s} = {s}\n", .{ miss.obs.dialect, miss.want });
        if (c.known_divergence) |why| std.debug.print("  recorded reason: {s}\n", .{why});
        return error.DialectPinMiss;
    }
    std.debug.print("  every dialect agrees, but not on the promised answer\n", .{});
    return error.DialectContractViolation;
}

/// Run `c` on one dialect and record the answer. A case that returns an error is
/// *not* a harness error: the error name becomes the answer, because "this
/// dialect refuses the operation" is one of the things the dialects have to
/// agree about. An unreachable server records nothing, which is what makes a
/// case skip instead of pass.
fn observeSqlite(a: std.mem.Allocator, allocator: std.mem.Allocator, c: Case, obs: *[3]Obs, n: *usize) !void {
    var drv = try SQLiteDriver.open(allocator, ":memory:");
    defer drv.close();
    obs[n.*] = .{ .dialect = "sqlite3", .answer = try attempt(a, c, drv.asDriver()) };
    n.* += 1;
}

fn observePg(a: std.mem.Allocator, allocator: std.mem.Allocator, c: Case, obs: *[3]Obs, n: *usize) !void {
    if (comptime build_options.have_pg) {
        const PgDriver = zent.sql_postgres.PostgresDriver;
        const conninfo = try pgConninfo(allocator);
        defer allocator.free(conninfo);
        var drv = PgDriver.connect(allocator, conninfo) catch |err| {
            std.log.warn("dialect-matrix: postgres unavailable ({s})", .{@errorName(err)});
            return;
        };
        defer drv.close();
        obs[n.*] = .{ .dialect = "postgres", .answer = try attempt(a, c, drv.asDriver()) };
        n.* += 1;
    }
}

fn observeMysql(a: std.mem.Allocator, allocator: std.mem.Allocator, c: Case, obs: *[3]Obs, n: *usize) !void {
    if (comptime build_options.have_mysql) {
        const MyDriver = zent.sql_mysql.MySQLDriver;
        const d = mysqlEnv();
        var drv = MyDriver.connect(allocator, d.host, d.port, d.user, d.pass, d.db) catch |err| {
            std.log.warn("dialect-matrix: mysql unavailable ({s})", .{@errorName(err)});
            return;
        };
        defer drv.close();
        obs[n.*] = .{ .dialect = "mysql", .answer = try attempt(a, c, drv.asDriver()) };
        n.* += 1;
    }
}

fn attempt(a: std.mem.Allocator, c: Case, drv: Driver) ![]const u8 {
    return c.run(a, drv) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.fmt.allocPrint(a, "err:{s}", .{@errorName(err)}) catch "err:OutOfMemory",
    };
}

/// `PG_DSN` when set, else the local Homebrew default: database `zent_test` owned
/// by the current OS user. The SQLite and MySQL halves of this file follow
/// `sqlite.zig`/`postgres.zig`/`mysql.zig`'s conventions so one environment runs
/// all of them.
fn pgConninfo(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.Environ.getPosix(testing.environ, "SKIP_PG") != null) return error.SkipZigTest;
    if (std.process.Environ.getPosix(testing.environ, "PG_DSN")) |dsn| return allocator.dupe(u8, dsn);
    const user = std.process.Environ.getPosix(testing.environ, "USER") orelse "n0x";
    return std.fmt.allocPrint(allocator, "host=localhost dbname=zent_test user={s}", .{user});
}

const MyEnv = struct {
    host: [:0]const u8,
    port: u32,
    user: [:0]const u8,
    pass: [:0]const u8,
    db: [:0]const u8,
};

fn mysqlEnv() MyEnv {
    const port_s = std.process.Environ.getPosix(testing.environ, "MYSQL_PORT") orelse "3306";
    return .{
        .host = std.process.Environ.getPosix(testing.environ, "MYSQL_HOST") orelse "localhost",
        .port = std.fmt.parseInt(u32, port_s, 10) catch 3306,
        .user = std.process.Environ.getPosix(testing.environ, "MYSQL_USER") orelse "root",
        .pass = std.process.Environ.getPosix(testing.environ, "MYSQL_PASS") orelse "",
        .db = std.process.Environ.getPosix(testing.environ, "MYSQL_DB") orelse "zent_test",
    };
}

/// Append a `,`-joined list of names, so an answer can carry "the rows the ids
/// named" without the renderer needing to know about slices.
fn joinNames(a: std.mem.Allocator, names: []const []const u8) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(a);
    for (names, 0..) |name, i| {
        if (i > 0) try buf.append(',');
        try buf.appendSlice(name);
    }
    return buf.toOwnedSlice();
}

/// Drop a table this file created, ignoring every failure. Used on the way out
/// of a case so the shared `zent_test` database is left as it was found.
fn dropTable(drv: Driver, table: []const u8) void {
    var buf: [128]u8 = undefined;
    const stmt = std.fmt.bufPrint(&buf, "DROP TABLE IF EXISTS {s}", .{table}) catch return;
    _ = drv.exec(stmt, &.{}) catch {};
}

/// Drop the table and create it from `infos`.
///
/// The drop is not decoration: the SQLite half owns its database (`:memory:`),
/// but PostgreSQL and MySQL use the shared `zent_test` database, which the other
/// integration files (and other worktrees) also write to, so a run that stopped
/// halfway leaves its table behind and `CREATE TABLE` would fail on the next one.
/// Drop the case's tables and create them from `infos`.
///
/// The drop is not decoration: the SQLite half owns its database (`:memory:`),
/// but PostgreSQL and MySQL use the shared `zent_test` database, which the other
/// integration files (and other worktrees) also write to, so a run that stopped
/// halfway leaves its table behind — `CREATE TABLE IF NOT EXISTS` would keep the
/// stale one and the case would run against last run's shape.
fn freshTable(allocator: std.mem.Allocator, drv: Driver, comptime infos: []const zent.codegen.graph.TypeInfo, tables: []const []const u8) !void {
    for (tables) |table| dropTable(drv, table);
    try Client.createAllTables(allocator, infos, drv);
}

/// `ok` when the call returned, else the error's name. The payload is whatever
/// the call reports (`usize` for a builder's `Exec`, `driver.Result` for a raw
/// `exec`); only "did it fail, and with what name" is being compared.
fn resultName(result: anytype) []const u8 {
    _ = result catch |err| return @errorName(err);
    return "ok";
}

/// Whether a call was refused, without saying *what* it was called. Used where
/// the name is a recorded per-dialect difference (see exclusion 2): a case built
/// on the name could never go green, while the question the case is actually
/// about — was the statement refused, and did the refusal cost anything — is
/// comparable. The measured names live in that exclusion and in the case's own
/// doc comment.
fn refused(result: anytype) []const u8 {
    _ = result catch return "true";
    return "false";
}

/// Render `?`-style SQL for the dialects that spell placeholders differently
/// (`$1`, `$2`, … on PostgreSQL). The builders do this internally; a case that
/// writes raw SQL *because it is about the raw statement* has to ask.
fn withPlaceholders(a: std.mem.Allocator, drv: Driver, sql_text: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, drv.dialect().name, "postgres")) return a.dupe(u8, sql_text);
    var buf = std.array_list.Managed(u8).init(a);
    var n: usize = 0;
    for (sql_text) |ch| {
        if (ch == '?') {
            n += 1;
            try buf.print("${d}", .{n});
        } else {
            try buf.append(ch);
        }
    }
    return buf.toOwnedSlice();
}

// ------------------------------------------------------------------
// Cases: the answer must not depend on the server
// ------------------------------------------------------------------

/// `crud.update` writes back a row the caller just fetched, so "the values did
/// not change" is the normal case, not an edge case. The row exists in tenant 1,
/// so the answer is `true` — MySQL counts *changed* rows and would answer
/// `false` from the raw count, which is why the zero path re-checks existence
/// with the same (tenant, id) scope. The other three answers pin that the
/// re-check did not replace the meaning: a real change is `true`, a foreign
/// tenant and a missing id are `false`.
fn caseCrudServiceIdempotentPut(a: std.mem.Allocator, drv: Driver) ![]const u8 {
    const allocator = testing.allocator;
    const DmIdemProduct = schema("DmIdemProduct", .{
        .fields = &.{
            field.Int("tenant_id"),
            field.String("name"),
            field.Int("price_cents"),
        },
    });

    const graph = comptime buildGraph(&.{DmIdemProduct});
    const infos = graph.types;
    try freshTable(allocator, drv, infos, &.{"dm_idem_product"});
    defer dropTable(drv, "dm_idem_product");

    const client = client_mod.EntityClient(infos, infos[0]).init(allocator, drv);
    const Service = zent.crud.CrudService(infos, infos[0], "tenant_id");
    var svc = Service.init(allocator, client);

    const id = try svc.create(.{ .id = 0, .tenant_id = 0, .name = "widget", .price_cents = 100 }, 1);

    var got = (try svc.getOwned(allocator, 1, id)) orelse return error.NoRow;
    defer zent.codegen.deinitEntity(infos, infos[0], &got, allocator);

    const idempotent = try svc.update(got, 1);

    var changed = got;
    changed.price_cents = 150;
    const real_change = try svc.update(changed, 1);

    const other_tenant = try svc.update(changed, 2);
    const missing = try svc.update(changed, id + 100_000);

    return std.fmt.allocPrint(a, "idempotent={}|changed={}|other_tenant={}|missing={}", .{
        idempotent, real_change, other_tenant, missing,
    });
}

/// `crud_helpers.update` promises the count of rows the predicate **matched**.
/// The idempotent write-back is the case MySQL cannot answer from the statement
/// alone (0 changed rows) while SQLite and PostgreSQL answer 1 natively, so all
/// three have to come back with the same number or the call means different
/// things on different servers. `missing = 0` is the control: the re-check must
/// not turn "matched nothing" into 1.
fn caseCrudHelpersUpdateCountsMatched(a: std.mem.Allocator, drv: Driver) ![]const u8 {
    const allocator = testing.allocator;
    const DmUpdCoupon = schema("DmUpdCoupon", .{
        .fields = &.{
            field.Int("tenant_id"),
            field.String("name"),
            field.Int("status"),
        },
    });

    const graph = comptime buildGraph(&.{DmUpdCoupon});
    const infos = graph.types;
    try freshTable(allocator, drv, infos, &.{"dm_upd_coupon"});
    defer dropTable(drv, "dm_upd_coupon");

    const client = Client.makeClient(infos, allocator, drv);
    var created = try zent.crud_helpers.create(client.dm_upd_coupon, .{ .tenant_id = 1, .name = "new", .status = 20 });
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);

    const id_pred = client.dm_upd_coupon.predicates.idEQ(.{ .int = created.id });
    const changed = try zent.crud_helpers.update(client.dm_upd_coupon, .{ .status = 30 }, .{id_pred});
    const idempotent = try zent.crud_helpers.update(client.dm_upd_coupon, .{ .status = 30 }, .{id_pred});
    const missing = try zent.crud_helpers.update(client.dm_upd_coupon, .{ .status = 40 }, .{
        client.dm_upd_coupon.predicates.idEQ(.{ .int = created.id + 100_000 }),
    });

    return std.fmt.allocPrint(a, "changed={d}|idempotent={d}|missing={d}", .{ changed, idempotent, missing });
}

/// `SET hits = hits + 0` changes nothing anywhere, but only MySQL reports it as
/// zero rows touched. A caller reading `0` as "no such row" takes a different
/// branch per server for the same input, so the helper's zero path re-checks —
/// and `missing = 0` keeps that re-check from answering 1 for a predicate that
/// matches nothing.
fn caseCrudHelpersIncrementZeroDelta(a: std.mem.Allocator, drv: Driver) ![]const u8 {
    const allocator = testing.allocator;
    const DmHits = schema("DmHits", .{
        .fields = &.{
            field.String("name"),
            field.Int("hits"),
        },
    });

    const graph = comptime buildGraph(&.{DmHits});
    const infos = graph.types;
    try freshTable(allocator, drv, infos, &.{"dm_hits"});
    defer dropTable(drv, "dm_hits");

    const client = Client.makeClient(infos, allocator, drv);
    var created = try zent.crud_helpers.create(client.dm_hits, .{ .name = "page", .hits = 10 });
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);

    const id_pred = client.dm_hits.predicates.idEQ(.{ .int = created.id });
    const plus = try zent.crud_helpers.increment(client.dm_hits, "hits", 5, .{id_pred});
    const zero = try zent.crud_helpers.increment(client.dm_hits, "hits", 0, .{id_pred});
    const missing = try zent.crud_helpers.increment(client.dm_hits, "hits", 0, .{
        client.dm_hits.predicates.idEQ(.{ .int = created.id + 100_000 }),
    });

    return std.fmt.allocPrint(a, "plus={d}|zero={d}|missing={d}", .{ plus, zero, missing });
}

/// A row that is already in the trash is not deleted a second time. The count is
/// the visible half (the hard-deleting path answers 0 for a row that is gone, so
/// the soft path has to answer 0 too); `deleted_at` is the half that matters for
/// the data — a second call rewrote it, so the timestamp of *when the row was
/// really trashed* was lost and a row trashed twice answered 1 forever.
///
/// The timestamp half is measured against a **planted** value, not against the
/// one the first call wrote: `deleted_at` is an epoch second, and the two calls
/// land in the same second, so comparing two real timestamps would report "kept"
/// even when the second call rewrote the column (that is exactly what an
/// injected rewrite did — the count caught it, the timestamp did not). Planting
/// `999` makes "the second call wrote nothing" observable on its own, without a
/// sleep and without a clock reading.
/// A column-level `UNIQUE` lives inside `CREATE TABLE`, so a table created
/// before the field was marked unique has nothing enforcing it — and with no
/// unique index the statement `SaveOrUpdateOn` builds is rejected by the server
/// ("ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint" on
/// SQLite and PostgreSQL), so every upsert against that table fails at runtime
/// while the schema says it works. The migration adds the index; the refused
/// duplicate is the observable, and it is the same one on all three servers.
///
/// The table is created by hand here because that is the state under test: a
/// table that predates the declaration. The DDL is the portable subset —
/// `INTEGER PRIMARY KEY` and `TEXT` are accepted by all three, and no
/// auto-increment is needed since the case never inserts a row without an id.
/// Whether the report holds the `.unique_constraint` drift for the column this
/// case declares UNIQUE.
fn hasUniqueConstraintDrift(drifts: []const zent.sql_schema.SchemaDrift) bool {
    for (drifts) |d| {
        if (d.kind == .unique_constraint and std.mem.eql(u8, d.column, "email")) return true;
    }
    return false;
}

/// `Count()` on a builder with `GroupBy` set. The library answers the number of
/// **groups** (`SELECT COUNT(*) FROM (SELECT 1 … GROUP BY …) AS __zent_groups`),
/// which is a derived table — and a derived table is where the servers differ:
/// PostgreSQL requires it to be named, SQLite and MySQL accept a name but do not
/// demand one. A run where only one server accepts the shape would be a
/// consumer's production surprise rather than a test failure, so the answer is
/// pinned here.
///
/// Before v0.78.0 the same call read the first row of
/// `SELECT COUNT(*) … GROUP BY …`, i.e. the first group's size (3 here, not 2),
/// and answered `error.NotFound` for a grouping with no rows at all.
fn caseGroupedCountTotals(a: std.mem.Allocator, drv: Driver) ![]const u8 {
    const allocator = testing.allocator;
    const DmCountRow = schema("DmCountRow", .{
        .table_name = "dm_count_row",
        .fields = &.{ field.String("grp"), field.Int("amount") },
    });

    const graph = comptime buildGraph(&.{DmCountRow});
    const infos = graph.types;
    try freshTable(allocator, drv, infos, &.{"dm_count_row"});
    defer dropTable(drv, "dm_count_row");

    const client = Client.makeClient(infos, allocator, drv);

    // Three rows in "a", one in "b": the first group's size and the group count
    // differ, so an implementation that reads the first row cannot pass by
    // accident.
    for ([_][2][]const u8{
        .{ "a", "1" },
        .{ "a", "2" },
        .{ "a", "3" },
        .{ "b", "4" },
    }) |pair| {
        var b = try client.dm_count_row.Create();
        defer b.deinit();
        _ = try b.setFieldValue("grp", pair[0]);
        _ = try b.setFieldValue("amount", std.fmt.parseInt(i64, pair[1], 10) catch unreachable);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, infos[0], &row, allocator);
    }

    var grouped = client.dm_count_row.Query();
    defer grouped.deinit();
    _ = try grouped.GroupBy(&.{"grp"});
    const groups = try grouped.Count();

    // Nothing matches: the answer is zero groups, not "no such row".
    var empty = client.dm_count_row.Query();
    defer empty.deinit();
    _ = try empty.GroupBy(&.{"grp"});
    _ = try empty.Where(.{client.dm_count_row.predicates.grpEQ(.{ .string = "zzz" })});
    const none = empty.Count() catch |err| return std.fmt.allocPrint(a, "empty=err:{s}", .{@errorName(err)});

    var plain = client.dm_count_row.Query();
    defer plain.deinit();
    const all = try plain.Count();

    return std.fmt.allocPrint(a, "groups={d}|empty={d}|ungrouped={d}", .{ groups, none, all });
}

fn caseUniqueIndexAddedToExistingTable(a: std.mem.Allocator, drv: Driver) ![]const u8 {
    const allocator = testing.allocator;
    const DmUqRow = schema("DmUqRow", .{
        .table_name = "dm_uq_row",
        .fields = &.{field.String("email").Unique()},
    });

    const graph = comptime buildGraph(&.{DmUqRow});
    const infos = graph.types;
    dropTable(drv, "dm_uq_row");
    defer dropTable(drv, "dm_uq_row");

    // The table as a database that predates the `Unique()` has it: the column
    // exists, nothing forces it. Written per dialect because the schema's own
    // types are dialect-specific (`field.String` is `TEXT` on SQLite and
    // `VARCHAR(255)` elsewhere, `field.Int` is `INTEGER` on SQLite and `BIGINT`
    // elsewhere) — getting those wrong would add a *type* drift and make the
    // count below a different question.
    const ddl = if (std.mem.eql(u8, drv.dialect().name, "sqlite3"))
        "CREATE TABLE dm_uq_row (id INTEGER PRIMARY KEY, email TEXT NOT NULL)"
    else
        "CREATE TABLE dm_uq_row (id BIGINT PRIMARY KEY, email VARCHAR(255) NOT NULL)";
    _ = try drv.exec(ddl, &.{});

    const before = try zent.sql_schema.checkSchema(allocator, drv, infos);
    defer zent.sql_schema.freeSchemaDrift(allocator, before);

    // No duplicate row is planted before this: the migration would refuse to
    // build the index over data that already violates it (which is the point of
    // the fix — loud, and rolled back — but a different observation).
    try zent.sql_schema.migrateSchema(allocator, drv, infos);

    const after = try zent.sql_schema.checkSchema(allocator, drv, infos);
    defer zent.sql_schema.freeSchemaDrift(allocator, after);

    // The id is supplied rather than left to the server: `INTEGER PRIMARY KEY`
    // is a rowid alias on SQLite but a plain column elsewhere, so an id-less
    // insert would be a dialect difference of its own.
    const insert = try withPlaceholders(a, drv, "INSERT INTO dm_uq_row (id, email) VALUES (?, ?)");
    _ = try drv.exec(insert, &.{ .{ .int = 1 }, .{ .string = "dup@example.test" } });
    const duplicate = resultName(drv.exec(insert, &.{ .{ .int = 2 }, .{ .string = "dup@example.test" } }));

    // The question is this drift, not the length of the list: a hand-written
    // table can differ from the schema in ways that have nothing to do with the
    // declaration under test (an auto-increment column's default, say), and
    // those differences belong to other cases.
    return std.fmt.allocPrint(a, "unique_drift_before={s}|unique_drift_after={s}|duplicate={s}", .{
        if (hasUniqueConstraintDrift(before)) "yes" else "no",
        if (hasUniqueConstraintDrift(after)) "yes" else "no",
        if (std.mem.eql(u8, duplicate, "ok")) "accepted" else "refused",
    });
}

fn caseRepeatSoftDelete(a: std.mem.Allocator, drv: Driver) ![]const u8 {
    const allocator = testing.allocator;
    const DmSoftRow = schema("DmSoftRow", .{
        .fields = &.{field.String("title")},
        .mixins = &.{zent.core.mixin.SoftDeleteMixin},
        .soft_delete = true,
    });

    const graph = comptime buildGraph(&.{DmSoftRow});
    const infos = graph.types;
    try freshTable(allocator, drv, infos, &.{"dm_soft_row"});
    defer dropTable(drv, "dm_soft_row");

    const client = Client.makeClient(infos, allocator, drv);

    var created = try zent.crud_helpers.create(client.dm_soft_row, .{ .title = "t" });
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);

    const id_pred = client.dm_soft_row.predicates.idEQ(.{ .int = created.id });

    var first = client.dm_soft_row.Delete();
    defer first.deinit();
    _ = try first.Where(.{id_pred});
    const first_count = try first.Exec();

    // A value no library path would produce, written with raw SQL (the setup is
    // allowed to know the table; the observation stays inside the API).
    const sentinel: i64 = 999;
    const plant = try withPlaceholders(a, drv, "UPDATE dm_soft_row SET deleted_at = ? WHERE id = ?");
    const planted = try drv.exec(plant, &.{ .{ .int = sentinel }, .{ .int = created.id } });
    if (!planted.rows_affected_known or planted.rows_affected != 1) return error.SentinelNotPlanted;

    var second = client.dm_soft_row.Delete();
    defer second.deinit();
    _ = try second.Where(.{id_pred});
    const second_count = try second.Exec();

    const after_second = try readSoftDeletedAt(client, created.id);
    const stamp = if (after_second == null)
        "absent"
    else if (after_second.? == sentinel)
        "kept"
    else
        "rewritten";

    var live = client.dm_soft_row.Query();
    defer live.deinit();
    const visible = try live.Count();

    return std.fmt.allocPrint(a, "first={d}|second={d}|deleted_at={s}|visible={d}", .{
        first_count, second_count, stamp, visible,
    });
}

/// Read `deleted_at` back through the entity (`WithTrashed`: the row is in the
/// trash by design), which is the copy a caller would see.
fn readSoftDeletedAt(client: anytype, id: i64) !?i64 {
    var q = client.dm_soft_row.Query();
    defer q.deinit();
    _ = q.WithTrashed();
    _ = try q.Where(.{client.dm_soft_row.predicates.idEQ(.{ .int = id })});
    var rows = try q.All();
    defer client.dm_soft_row.deinitRows(&rows);
    if (rows.items.len != 1) return error.NoRow;
    return rows.items[0].deleted_at;
}

/// `batchSaveOrUpdate` splits a batch into created/updated counts. The split is
/// a claim about each item ("this one did not exist"), and the update half is
/// the same matched-versus-changed problem one level down: on MySQL a second
/// pass over two unchanged-by-shape items reports 0 changed rows each, so the
/// updated count would read 0 where SQLite and PostgreSQL read 2. The items
/// carry a business key only — no id — so a pass is a write of the values the
/// caller holds, which is the shape the helper documents.
fn caseBatchSaveOrUpdateCounts(a: std.mem.Allocator, drv: Driver) ![]const u8 {
    const allocator = testing.allocator;
    const DmBatchDoc = schema("DmBatchDoc", .{
        .fields = &.{
            field.String("doc_code"),
            field.String("title"),
        },
    });

    const graph = comptime buildGraph(&.{DmBatchDoc});
    const infos = graph.types;
    try freshTable(allocator, drv, infos, &.{"dm_batch_doc"});
    defer dropTable(drv, "dm_batch_doc");

    const client = Client.makeClient(infos, allocator, drv);

    const items = &[_]struct { doc_code: []const u8, title: []const u8 }{
        .{ .doc_code = "DOC_01", .title = "v1" },
        .{ .doc_code = "DOC_02", .title = "v1" },
    };

    const first = try zent.crud_helpers.batchSaveOrUpdate(client.dm_batch_doc, items, "doc_code");
    const second = try zent.crud_helpers.batchSaveOrUpdate(client.dm_batch_doc, items, "doc_code");

    return std.fmt.allocPrint(a, "first={d}/{d}|second={d}/{d}", .{
        first.created_count, first.updated_count, second.created_count, second.updated_count,
    });
}

/// A bulk write that constrains nothing is refused by name, not resolved into
/// either a full-table delete or a silent `0` — which of the two a caller got
/// used to depended on the entity's `soft_delete`, so a schema change turned a
/// dangerous call into a destructive one without any code changing. The count of
/// surviving rows is part of the answer: "refused" has to mean *nothing was
/// touched*, on every dialect. Both variants (hard- and soft-deleting entity)
/// run, because they were the two different answers.
fn caseBulkDeleteWithoutPredicate(a: std.mem.Allocator, drv: Driver) ![]const u8 {
    const allocator = testing.allocator;
    const DmBulkHardRow = schema("DmBulkHardRow", .{ .fields = &.{field.String("title")} });
    const DmBulkSoftRow = schema("DmBulkSoftRow", .{
        .fields = &.{field.String("title")},
        .mixins = &.{zent.core.mixin.SoftDeleteMixin},
        .soft_delete = true,
    });

    const graph = comptime buildGraph(&.{ DmBulkHardRow, DmBulkSoftRow });
    const infos = graph.types;
    try freshTable(allocator, drv, infos, &.{ "dm_bulk_hard_row", "dm_bulk_soft_row" });
    defer {
        dropTable(drv, "dm_bulk_hard_row");
        dropTable(drv, "dm_bulk_soft_row");
    }

    const client = Client.makeClient(infos, allocator, drv);

    for (0..3) |_| {
        var h = try zent.crud_helpers.create(client.dm_bulk_hard_row, .{ .title = "t" });
        zent.codegen.deinitEntity(infos, infos[0], &h, allocator);
        var s = try zent.crud_helpers.create(client.dm_bulk_soft_row, .{ .title = "t" });
        zent.codegen.deinitEntity(infos, infos[1], &s, allocator);
    }

    var hard = try client.dm_bulk_hard_row.BulkDelete();
    defer hard.deinit();
    const hard_result = resultName(hard.Exec());

    var soft = try client.dm_bulk_soft_row.BulkDelete();
    defer soft.deinit();
    const soft_result = resultName(soft.Exec());

    var hq = client.dm_bulk_hard_row.Query();
    defer hq.deinit();
    const hard_live = try hq.Count();

    var sq = client.dm_bulk_soft_row.Query();
    defer sq.deinit();
    const soft_live = try sq.Count();

    return std.fmt.allocPrint(a, "hard={s}|soft={s}|hard_live={d}|soft_live={d}", .{
        hard_result, soft_result, hard_live, soft_live,
    });
}

/// v0.68.0: an eager-loaded target's SELECT list is the target's columns in
/// **field order**, never `<table>.*`. The two orders differ on any migrated
/// database — a column added by `ALTER TABLE … ADD COLUMN` sits last in the table
/// while the schema keeps it where the author declared it — and the result set is
/// scanned positionally, so with `*` every target field takes the wrong column.
/// The symptom is dialect-dependent (SQLite coerces and returns wrong values
/// silently, MySQL answers null from the getter and fails the scan with
/// `TypeMismatch`), which is exactly why the *values* have to be asserted on all
/// three at once.
///
/// The table is created from schema A (`app_id, qty, label`) and read through
/// schema B (`app_id, label, qty`): same table, same columns, different
/// declaration order — a migrated database, without hand-writing per-dialect
/// DDL. The premise is checked, not assumed: if the physical order ever stopped
/// differing from the field order the case would still pass while testing
/// nothing, so the answer carries the verdict and `expect` pins it to `differs`.
fn caseEagerLoadedTargetColumnOrder(a: std.mem.Allocator, drv: Driver) ![]const u8 {
    const allocator = testing.allocator;

    const DmEagerTargetV1 = schema("DmEagerTarget", .{
        .fields = &.{
            field.Int("app_id"),
            field.Int("qty"),
            field.String("label"),
        },
    });
    const DmEagerTarget = schema("DmEagerTarget", .{
        .fields = &.{
            field.Int("app_id"),
            field.String("label"),
            field.Int("qty"),
        },
    });
    const DmEagerOwningBase = schema("DmEagerOwning", .{
        .fields = &.{field.String("code")},
    });
    const DmEagerOwning = struct {
        pub const schema_name = DmEagerOwningBase.schema_name;
        pub const fields = DmEagerOwningBase.fields;
        pub const edges = &.{edge.From("thing", DmEagerTarget).Field("thing_id")};
        pub const indexes = DmEagerOwningBase.indexes;
    };

    const graph = comptime buildGraph(&.{ DmEagerTarget, DmEagerOwning });
    const infos = graph.types;

    // The target's table comes from schema A, so its physical order is A's; the
    // owning table comes from the same graph the case reads through. The second
    // call re-states the target's `CREATE TABLE IF NOT EXISTS` — the table is
    // already there, so it is a no-op and the divergence survives.
    const v1_graph = comptime buildGraph(&.{DmEagerTargetV1});
    try freshTable(allocator, drv, v1_graph.types, &.{"dm_eager_target"});
    dropTable(drv, "dm_eager_owning");
    try Client.createAllTables(allocator, infos, drv);
    defer {
        dropTable(drv, "dm_eager_owning");
        dropTable(drv, "dm_eager_target");
    }

    const client = Client.makeClient(infos, allocator, drv);

    const physical = try physicalColumns(a, drv, "dm_eager_target");
    var field_order = std.array_list.Managed([]const u8).init(a);
    inline for (infos[0].fields) |f| try field_order.append(f.column_name);
    const order = if (sameOrder(physical, field_order.items)) "matches" else "differs";

    var tb = try client.dm_eager_target.Create();
    defer tb.deinit();
    _ = try tb.setFieldValue("app_id", @as(i64, 1));
    _ = try tb.setFieldValue("label", "widget");
    _ = try tb.setFieldValue("qty", @as(i64, 5));
    var target = try tb.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &target, allocator);

    var ob = try client.dm_eager_owning.Create();
    defer ob.deinit();
    _ = try ob.setFieldValue("code", "own-1");
    _ = try ob.setFieldValue("thing_id", target.id);
    var owner = try ob.Save();
    defer zent.codegen.deinitEntity(infos, infos[1], &owner, allocator);

    var q = client.dm_eager_owning.Query();
    defer q.deinit();
    _ = try q.WithEdge("thing");
    var rows = try q.All();
    defer client.dm_eager_owning.deinitRows(&rows);
    if (rows.items.len != 1) return error.NoRow;
    const loaded = rows.items[0].edges.thing orelse return error.NoEdge;
    if (loaded.len != 1) return error.NoEdge;

    return std.fmt.allocPrint(a, "order={s}|app_id={d}|label={s}|qty={d}", .{
        order, loaded[0].app_id, loaded[0].label, loaded[0].qty,
    });
}

/// The physical column names of `table`, in ordinal order. Three small catalog
/// queries live in this one helper because it is the only place the *shape* of a
/// table (as opposed to its contents) is observed, and the text forms are
/// spelled per dialect on purpose — what leaves this function is a list of
/// names, not a catalog rendering (exclusion 3).
fn physicalColumns(a: std.mem.Allocator, drv: Driver, table: []const u8) ![][]const u8 {
    const is_sqlite = std.mem.eql(u8, drv.dialect().name, "sqlite3");
    const is_pg = std.mem.eql(u8, drv.dialect().name, "postgres");
    const stmt = if (is_sqlite)
        try std.fmt.allocPrint(a, "PRAGMA table_info({s})", .{table})
    else if (is_pg)
        try a.dupe(u8, "SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 ORDER BY ordinal_position")
    else
        try a.dupe(u8, "SELECT column_name FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? ORDER BY ordinal_position");

    const name_col: usize = if (is_sqlite) 1 else 0;
    const args: []const Value = if (is_sqlite) &.{} else &.{.{ .string = table }};

    var rows = try drv.query(stmt, args);
    defer rows.deinit();
    var out = std.array_list.Managed([]const u8).init(a);
    while (rows.next()) |row| {
        try out.append(try a.dupe(u8, row.columnName(name_col)));
    }
    if (rows.nextError()) |e| return e;
    return out.toOwnedSlice();
}

fn sameOrder(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// A foreign key is worth what the connection enforcing it is worth. The library
/// declares the constraint on all three dialects — `createTableSQLAlloc` writes
/// `FOREIGN KEY (…) REFERENCES … ON DELETE CASCADE ON UPDATE CASCADE` — but
/// SQLite ships `PRAGMA foreign_keys` **OFF** and the pragma is per connection,
/// so on that dialect "the schema declares an FK" and "a dangling reference is
/// refused" used to be two different statements. They are one now, and this is
/// where the three dialects have to agree: the *same named* error
/// (`driver.Error.ForeignKeyViolation`, from SQLite's `SQLITE_CONSTRAINT_FOREIGNKEY`
/// 787, PostgreSQL's SQLSTATE 23503 and MySQL's errno 1452), no row stored, and
/// the DDL's cascading delete taking the children with the parent.
///
/// Both follow-ups are half of the same contract. A refusal that still left the
/// row behind would be worse than no refusal, and "the children went with the
/// parent" is the answer an application gets for the DDL this library generates
/// — on a dialect where the constraint was never enforced it got a different
/// one (the delete silently succeeded and the children stayed).
fn caseForeignKeyEnforcement(a: std.mem.Allocator, drv: Driver) ![]const u8 {
    const allocator = testing.allocator;

    const DmFkParent = schema("DmFkParent", .{ .fields = &.{field.String("name")} });
    const DmFkChildBase = schema("DmFkChild", .{ .fields = &.{field.String("label")} });
    const DmFkChild = struct {
        pub const schema_name = DmFkChildBase.schema_name;
        pub const fields = DmFkChildBase.fields;
        pub const edges = &.{edge.From("parent", DmFkParent).Required()};
        pub const indexes = DmFkChildBase.indexes;
    };

    const graph = comptime buildGraph(&.{ DmFkParent, DmFkChild });
    const infos = graph.types;

    // The child holds the foreign key, so it goes first: on MySQL a parent drop
    // with the constraint still in place is errno 3730, and the `dropTable`
    // helper would swallow it and leave the parent behind for the next run.
    try freshTable(allocator, drv, infos, &.{ "dm_fk_child", "dm_fk_parent" });
    defer {
        dropTable(drv, "dm_fk_child");
        dropTable(drv, "dm_fk_parent");
    }

    const client = Client.makeClient(infos, allocator, drv);

    // A child naming a parent row that is not there.
    const dangling = resultName(drv.exec(
        "INSERT INTO dm_fk_child (label, parent_id) VALUES ('orphan', 424242)",
        &.{},
    ));

    var orphans = client.dm_fk_child.Query();
    defer orphans.deinit();
    const orphans_stored = try orphans.Count();

    // The same statement against a parent that exists, through the builder — so
    // the refusal above was about the reference and not about the row.
    var parent_b = try client.dm_fk_parent.Create();
    defer parent_b.deinit();
    _ = try parent_b.setFieldValue("name", "p");
    var parent = try parent_b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &parent, allocator);

    const linked: []const u8 = blk: {
        var b = try client.dm_fk_child.Create();
        defer b.deinit();
        _ = try b.setFieldValue("label", "linked");
        _ = try b.setFieldValue("parent_id", parent.id);
        var created = b.Save() catch |err| break :blk @errorName(err);
        zent.codegen.deinitEntity(infos, infos[1], &created, allocator);
        break :blk "ok";
    };

    // `ON DELETE CASCADE` is what the generated DDL says (`ForeignKeyDef`'s
    // default), so the children go with the parent.
    var buf: [128]u8 = undefined;
    const delete_parent = try std.fmt.bufPrint(&buf, "DELETE FROM dm_fk_parent WHERE id = {d}", .{parent.id});
    _ = try drv.exec(delete_parent, &.{});

    var remaining = client.dm_fk_child.Query();
    defer remaining.deinit();
    const after_parent_delete = try remaining.Count();

    return std.fmt.allocPrint(a, "dangling={s}|orphans={d}|linked={s}|after_parent_delete={d}", .{
        dangling, orphans_stored, linked, after_parent_delete,
    });
}

/// Every id a bulk write returns must name the row its own input row wrote.
/// MySQL has no `INSERT … RETURNING`, so a multi-row statement there reports one
/// `last_insert_id` — the statement's *first generated* value — while an
/// `ON DUPLICATE KEY UPDATE` arm that updated a row answers that row's existing
/// id. Deriving `base + i` from it invents ids as soon as a chunk collides:
/// measured on MySQL 9.3, a three-row ODKU whose first row collided reported
/// `base = 2` for true ids [1, 2, 3], so the last fabricated id named no row at
/// all. The observable therefore reads each id back and asks which row it named,
/// which is comparable across dialects (the ids themselves are not: they depend
/// on the server's history, see exclusion 9).
fn caseBulkWriteIdsNameTheirRows(a: std.mem.Allocator, drv: Driver) ![]const u8 {
    const allocator = testing.allocator;
    const DmBulkSku = schema("DmBulkSku", .{
        .fields = &.{
            field.String("sku").Unique(),
            field.Int("score"),
        },
    });

    const graph = comptime buildGraph(&.{DmBulkSku});
    const infos = graph.types;
    try freshTable(allocator, drv, infos, &.{"dm_bulk_sku"});
    defer dropTable(drv, "dm_bulk_sku");

    const client = Client.makeClient(infos, allocator, drv);

    // Plain multi-row insert: every id must name the row it was set for.
    const plain_skus = [_][]const u8{ "a1", "b1", "c1" };
    var insert = try client.dm_bulk_sku.BulkInsert();
    defer insert.deinit();
    for (plain_skus, 0..) |sku, i| {
        if (i > 0) _ = try insert.Next();
        _ = try insert.setFieldValue("sku", sku);
        _ = try insert.setFieldValue("score", @as(i64, @intCast(i + 1)));
    }
    const insert_ids = try insert.Save();
    defer insert_ids.deinit();
    const insert_names = try namesForIds(a, client, insert_ids.items);

    // Upsert with a collision on the *first* row of the batch: that row is
    // updated (no AUTO_INCREMENT spent), so the rows after it are exactly where
    // a derived id drifts.
    var seed = try zent.crud_helpers.create(client.dm_bulk_sku, .{ .sku = "seed", .score = 1 });
    zent.codegen.deinitEntity(infos, infos[0], &seed, allocator);

    const upsert_skus = [_][]const u8{ "seed", "b2", "c2" };
    var upsert = try client.dm_bulk_sku.BulkInsert();
    defer upsert.deinit();
    for (upsert_skus, 0..) |sku, i| {
        if (i > 0) _ = try upsert.Next();
        _ = try upsert.setFieldValue("sku", sku);
        _ = try upsert.setFieldValue("score", @as(i64, @intCast(i + 10)));
    }
    const upsert_ids = try upsert.SaveOrUpdateOn(&.{"sku"});
    defer upsert_ids.deinit();
    const upsert_names = try namesForIds(a, client, upsert_ids.items);

    return std.fmt.allocPrint(a, "insert_n={d}|insert={s}|upsert_n={d}|upsert={s}", .{
        insert_ids.items.len, insert_names, upsert_ids.items.len, upsert_names,
    });
}

/// Read the `sku` each id points at, in the order the ids were returned.
fn namesForIds(a: std.mem.Allocator, client: anytype, ids: []const i64) ![]const u8 {
    var names = std.array_list.Managed([]const u8).init(a);
    for (ids) |id| {
        var q = client.dm_bulk_sku.Query();
        defer q.deinit();
        _ = try q.Where(.{client.dm_bulk_sku.predicates.idEQ(.{ .int = id })});
        var rows = try q.All();
        defer client.dm_bulk_sku.deinitRows(&rows);
        if (rows.items.len != 1) try names.append("<no-row>") else try names.append(try a.dupe(u8, rows.items[0].sku));
    }
    return joinNames(a, names.items);
}

/// A positional scan is column-count guarded: `<table>.*` follows the table's
/// physical order, `ALTER TABLE … ADD COLUMN` changes that order, and the drivers
/// do not all bounds-check — so the guard in `scanRow*` is the only thing between
/// a narrow result set and a read past the end of the row. The claim is the same
/// on every dialect ("refuse, do not read garbage"), and the control pins that
/// the guard does not fire for a row that fits, on a probe whose values would be
/// visibly wrong if the scan read the wrong columns.
fn caseScanRowColumnCountGuard(a: std.mem.Allocator, drv: Driver) ![]const u8 {
    const allocator = testing.allocator;
    const DmScanPair = schema("DmScanPair", .{
        .fields = &.{
            field.Int("x"),
            field.Int("y"),
        },
    });

    const graph = comptime buildGraph(&.{DmScanPair});
    const infos = graph.types;
    try freshTable(allocator, drv, infos, &.{"dm_scan_pair"});
    defer dropTable(drv, "dm_scan_pair");

    const client = Client.makeClient(infos, allocator, drv);
    var b = try client.dm_scan_pair.Create();
    defer b.deinit();
    _ = try b.setFieldValue("x", @as(i64, 7));
    _ = try b.setFieldValue("y", @as(i64, 8));
    var row = try b.Save();
    defer zent.codegen.deinitEntity(infos, infos[0], &row, allocator);

    var rows = try drv.query("SELECT x, y FROM dm_scan_pair", &.{});
    defer rows.deinit();
    const raw = rows.next() orelse return error.NoRow;

    const Narrow = struct { x: i64, y: i64, z: i64 };
    const narrow_result = zent.sql_scan.scanRow(Narrow, allocator, raw);
    const narrow: []const u8 = if (narrow_result) |_| "ok" else |err| @errorName(err);
    const exact_result = zent.sql_scan.scanRow(struct { x: i64, y: i64 }, allocator, raw);
    const exact: []const u8 = if (exact_result) |value|
        (if (value.x == 7 and value.y == 8) "ok" else "wrong-values")
    else |err|
        @errorName(err);

    return std.fmt.allocPrint(a, "narrow={s}|exact={s}", .{ narrow, exact });
}

/// A statement and its argument list that disagree is the caller's own bug: the
/// statement is refused, and nothing is written. SQLite and MySQL answer it with
/// one name (`error.ParamCountMismatch`) so a caller can tell "I built the
/// arguments wrong" from "the query is wrong" without switching on the driver.
///
/// **PostgreSQL does neither, and this case is how that was found.** Two things
/// go wrong there, both measured through this harness (see "Known divergence" in
/// the file doc for the reproduction):
///
///   * the refusal is reported as `error.DriverFailed` while the other two report
///     `error.ParamCountMismatch` — documented as deliberate (`driver.Error`'s own
///     doc: libpq answers the same mistake from its Bind error and its
///     diagnostics are not folded into `ParamCountMismatch`), so the *name* is in
///     the exclusions and is **not** part of this observable;
///   * the refusal **marks the connection dead**. The server reports the
///     wrong-length Bind as SQLSTATE `08P01` (`protocol_violation`, class `08` =
///     connection exception), `sqlstateToError` maps the whole class to
///     `error.ConnectionFailed`, and `noteError` then sets `dead = true` —
///     although `PQstatus` is still `CONNECTION_OK`. Every later call on that
///     connection fails at `ensureAlive`, including a plain `SELECT 1` and a
///     statement that was never involved. A pool discards the connection rather
///     than lending it out again (the `dead` flag is exactly what stops the
///     corpse being recycled), so one caller's argument-count bug costs a
///     connection instead of a statement. That is a defect, not a legitimate
///     difference, so the case stays in the matrix and its per-dialect answers
///     are pinned instead of the shared one.
///
/// What is compared, therefore, is the part that *is* a contract: the call was
/// refused, and the statement (and the connection) still work afterwards. The
/// order is deliberate — the list that fits runs first, so a divergence cannot be
/// explained by a statement that was never valid.
fn caseWrongLengthBindingListIsRefused(a: std.mem.Allocator, drv: Driver) ![]const u8 {
    const allocator = testing.allocator;
    const DmParamRow = schema("DmParamRow", .{
        .fields = &.{
            field.String("name"),
            field.Int("score"),
        },
    });

    const graph = comptime buildGraph(&.{DmParamRow});
    const infos = graph.types;
    try freshTable(allocator, drv, infos, &.{"dm_param_row"});
    defer dropTable(drv, "dm_param_row");

    const insert = try withPlaceholders(a, drv, "INSERT INTO dm_param_row (name, score) VALUES (?, ?)");

    const exact = resultName(drv.exec(insert, &.{ .{ .string = "alice" }, .{ .int = 1 } }));
    const short_refused = refused(drv.exec(insert, &.{.{ .string = "alice" }}));
    const long_refused = refused(drv.exec(insert, &.{
        .{ .string = "alice" },
        .{ .int = 1 },
        .{ .int = 2 },
    }));
    // The statement and the connection afterwards: the correct list again, and
    // a read-back of what the table actually holds (2 rows when the refused
    // calls left the connection usable, 1 when only the first insert ran). The
    // read is part of the observable and not a `try`: on a connection that can no
    // longer answer anything, the *name* of the failure here is the answer.
    const after = resultName(drv.exec(insert, &.{ .{ .string = "bob" }, .{ .int = 2 } }));
    const written = try countRows(a, drv, "dm_param_row");

    return std.fmt.allocPrint(a, "exact={s}|short_refused={s}|long_refused={s}|after={s}|rows={s}", .{
        exact, short_refused, long_refused, after, written,
    });
}

/// The row count read back, or the name of the error the read failed with.
fn countRows(a: std.mem.Allocator, drv: Driver, table: []const u8) ![]const u8 {
    const stmt = try std.fmt.allocPrint(a, "SELECT COUNT(*) FROM {s}", .{table});
    var rows = drv.query(stmt, &.{}) catch |err| return @errorName(err);
    defer rows.deinit();
    const row = rows.next() orelse return "no-row";
    const n = row.getInt(0) orelse return "no-value";
    return std.fmt.allocPrint(a, "{d}", .{n});
}

/// `Restore` is documented as "true when a row was restored", and its statement
/// is an UPDATE (`SET deleted_at = NULL WHERE id = ?`). SQLite and PostgreSQL
/// count the rows that UPDATE *matched*, so a live row — the one that was never
/// in the trash — is reported as restored; MySQL counts *changed* rows and
/// answers false. Same shape as the repeat-delete case: the answer is a count of
/// rows the call actually moved, or it means different things per server.
fn caseRestoreLiveRow(a: std.mem.Allocator, drv: Driver) ![]const u8 {
    const allocator = testing.allocator;
    const DmRestoreRow = schema("DmRestoreRow", .{
        .fields = &.{field.String("title")},
        .mixins = &.{zent.core.mixin.SoftDeleteMixin},
        .soft_delete = true,
    });

    const graph = comptime buildGraph(&.{DmRestoreRow});
    const infos = graph.types;
    try freshTable(allocator, drv, infos, &.{"dm_restore_row"});
    defer dropTable(drv, "dm_restore_row");

    const client = Client.makeClient(infos, allocator, drv);
    var created = try zent.crud_helpers.create(client.dm_restore_row, .{ .title = "t" });
    defer zent.codegen.deinitEntity(infos, infos[0], &created, allocator);

    const live = blk: {
        var db = client.dm_restore_row.Delete();
        defer db.deinit();
        break :blk try db.Restore(created.id);
    };

    {
        var db = client.dm_restore_row.Delete();
        defer db.deinit();
        _ = try db.Where(.{client.dm_restore_row.predicates.idEQ(.{ .int = created.id })});
        const trashed_count = try db.Exec();
        if (trashed_count != 1) return error.NotTrashed;
    }

    const trashed = blk: {
        var db = client.dm_restore_row.Delete();
        defer db.deinit();
        break :blk try db.Restore(created.id);
    };

    const missing = blk: {
        var db = client.dm_restore_row.Delete();
        defer db.deinit();
        break :blk try db.Restore(created.id + 100_000);
    };

    return std.fmt.allocPrint(a, "live={}|trashed={}|missing={}", .{ live, trashed, missing });
}

// ------------------------------------------------------------------
// The table
// ------------------------------------------------------------------

const cases = [_]Case{
    .{
        .name = "crud.update: an idempotent PUT answers true (changed vs matched rows)",
        .expect = "idempotent=true|changed=true|other_tenant=false|missing=false",
        .run = caseCrudServiceIdempotentPut,
    },
    .{
        .name = "crud_helpers.update: the count means matched, not changed",
        .expect = "changed=1|idempotent=1|missing=0",
        .run = caseCrudHelpersUpdateCountsMatched,
    },
    .{
        .name = "crud_helpers.increment: a zero delta still matches its row",
        .expect = "plus=1|zero=1|missing=0",
        .run = caseCrudHelpersIncrementZeroDelta,
    },
    .{
        .name = "soft delete: a repeat delete answers 0 and keeps deleted_at",
        .expect = "first=1|second=0|deleted_at=kept|visible=0",
        .run = caseRepeatSoftDelete,
    },
    .{
        .name = "batchSaveOrUpdate: the created/updated split is per row, not per changed row",
        .expect = "first=2/0|second=0/2",
        .run = caseBatchSaveOrUpdateCounts,
    },
    .{
        .name = "a grouped Count() answers the number of groups, on every server",
        .expect = "groups=2|empty=0|ungrouped=4",
        .run = caseGroupedCountTotals,
    },
    .{
        .name = "migrate: a column-level UNIQUE is enforced on a table that already exists",
        .expect = "unique_drift_before=yes|unique_drift_after=no|duplicate=refused",
        .run = caseUniqueIndexAddedToExistingTable,
    },
    .{
        .name = "bulk delete without a predicate: one named error, nothing deleted",
        .expect = "hard=NoPredicate|soft=NoPredicate|hard_live=3|soft_live=3",
        .run = caseBulkDeleteWithoutPredicate,
    },
    .{
        .name = "eager load: the target is read by field order, whatever the table order is",
        .expect = "order=differs|app_id=1|label=widget|qty=5",
        .run = caseEagerLoadedTargetColumnOrder,
    },
    .{
        .name = "bulk write: every returned id names the row it was written for",
        .expect = "insert_n=3|insert=a1,b1,c1|upsert_n=3|upsert=seed,b2,c2",
        .run = caseBulkWriteIdsNameTheirRows,
    },
    .{
        .name = "scanRow: a result set narrower than the struct is refused",
        .expect = "narrow=ColumnCountMismatch|exact=ok",
        .run = caseScanRowColumnCountGuard,
    },
    .{
        .name = "a wrong-length binding list is refused without costing the connection",
        // Not `expect`: the dialects are known to disagree (see the case's own
        // doc and "Known divergence" in the file doc), so the disagreement is
        // pinned dialect by dialect instead. The observable deliberately drops
        // the *name* of the refusal — that one is a recorded per-dialect
        // decision (exclusion 2) — so the only difference left is the defect,
        // and the case promotes itself to a plain one the moment it is fixed.
        .known_divergence = "PostgreSQL reports the refusal as a dead connection: the server answers " ++
            "SQLSTATE 08P01, sqlstateToError maps class 08 to ConnectionFailed, and " ++
            "noteError sets `dead` although PQstatus is CONNECTION_OK (PostgreSQL 17.10). " ++
            "Remove this field once the refusal stops killing the connection: the three " ++
            "dialects then agree on \"exact=ok|short_refused=true|long_refused=true|after=ok|rows=2\", " ++
            "and this case fails with `KnownDivergenceResolved` until it is promoted.",
        .expect_by_dialect = &.{
            .{ .dialect = "sqlite3", .answer = "exact=ok|short_refused=true|long_refused=true|after=ok|rows=2" },
            .{ .dialect = "postgres", .answer = "exact=ok|short_refused=true|long_refused=true|after=DriverFailed|rows=DriverFailed" },
            .{ .dialect = "mysql", .answer = "exact=ok|short_refused=true|long_refused=true|after=ok|rows=2" },
        },
        .run = caseWrongLengthBindingListIsRefused,
    },
    .{
        .name = "Restore: a live row was not restored",
        .expect = "live=false|trashed=true|missing=false",
        .run = caseRestoreLiveRow,
    },
    .{
        .name = "foreign keys: a dangling reference is refused, and the parent's delete cascades",
        .expect = "dangling=ForeignKeyViolation|orphans=0|linked=ok|after_parent_delete=0",
        .run = caseForeignKeyEnforcement,
    },
};

test "dialect matrix: one operation, one answer, three dialects" {
    // Every case runs, and every failure is reported: stopping at the first one
    // hides the rest of the picture, and the point of the file is to see which
    // operations depend on the server, not which one happens to run first.
    var failed: usize = 0;
    var skipped: usize = 0;
    for (cases) |c| {
        std.log.info("dialect-matrix: {s}", .{c.name});
        runMatrix(c) catch |err| switch (err) {
            error.SkipZigTest => {
                skipped += 1;
                std.debug.print("dialect-matrix: [{s}] skipped (< 2 reachable dialects)\n", .{c.name});
            },
            else => {
                failed += 1;
                std.debug.print("dialect-matrix: [{s}] failed with {s}\n", .{ c.name, @errorName(err) });
            },
        };
    }
    if (failed > 0) return error.DialectMatrixFailed;
    // Nothing ran: one reachable dialect proves nothing about agreement, and a
    // green run would say "all dialects agree" without ever asking.
    if (skipped == cases.len) return error.SkipZigTest;
    if (skipped > 0) {
        std.log.warn(
            "dialect-matrix: {d} of {d} cases skipped — a server became unreachable mid-run",
            .{ skipped, cases.len },
        );
    }
}
