const std = @import("std");
const zent = @import("zent");

const SQLiteDriver = zent.sql_sqlite.SQLiteDriver;
const PostgresDriver = zent.sql_postgres.PostgresDriver;
const MySQLDriver = zent.sql_mysql.MySQLDriver;
const migrate = zent.sql_schema;

const AnyDriver = union(enum) {
    sqlite: SQLiteDriver,
    postgres: PostgresDriver,
    mysql: MySQLDriver,

    fn asDriver(self: *AnyDriver) zent.sql_driver.Driver {
        switch (self.*) {
            inline else => |*drv| return drv.asDriver(),
        }
    }

    fn close(self: *AnyDriver) void {
        switch (self.*) {
            inline else => |*drv| drv.close(),
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const dsn = init.environ_map.get("ZENT_DSN") orelse "sqlite:zent.db";
    const dir = init.environ_map.get("ZENT_MIGRATIONS_DIR") orelse "migrations";
    const command = init.environ_map.get("ZENT_MIGRATE_CMD") orelse "up";

    var any_driver = try connectFromDsn(allocator, dsn);
    defer any_driver.close();
    const driver = any_driver.asDriver();

    if (std.mem.eql(u8, command, "up")) {
        try migrate.migrateFromFiles(init.io, allocator, driver, dir);
        std.debug.print("Migrations applied successfully.\n", .{});
    } else if (std.mem.eql(u8, command, "down")) {
        const steps_str = init.environ_map.get("ZENT_MIGRATE_STEPS") orelse "1";
        const steps = try std.fmt.parseInt(usize, steps_str, 10);
        try migrate.rollbackFiles(init.io, allocator, driver, dir, steps);
        std.debug.print("Rolled back {d} migration(s).\n", .{steps});
    } else {
        std.debug.print("Unknown ZENT_MIGRATE_CMD: {s} (expected 'up' or 'down')\n", .{command});
        return error.InvalidCommand;
    }
}

fn connectFromDsn(allocator: std.mem.Allocator, dsn: []const u8) !AnyDriver {
    if (std.mem.startsWith(u8, dsn, "sqlite:")) {
        const path = dsn[7..];
        return .{ .sqlite = try SQLiteDriver.open(allocator, path) };
    }

    if (std.mem.startsWith(u8, dsn, "postgres://") or std.mem.startsWith(u8, dsn, "postgresql://")) {
        return .{ .postgres = try PostgresDriver.connect(allocator, dsn) };
    }

    if (std.mem.startsWith(u8, dsn, "mysql://")) {
        const parsed = try parseMysqlDsn(allocator, dsn[8..]);
        return .{ .mysql = try MySQLDriver.connect(
            allocator,
            try allocator.dupeSentinel(u8, parsed.host, 0),
            parsed.port,
            try allocator.dupeSentinel(u8, parsed.user, 0),
            try allocator.dupeSentinel(u8, parsed.pass, 0),
            try allocator.dupeSentinel(u8, parsed.db, 0),
        ) };
    }

    return error.UnsupportedDriver;
}

const MysqlDsn = struct {
    user: []const u8,
    pass: []const u8,
    host: []const u8,
    port: u32,
    db: []const u8,
};

fn parseMysqlDsn(allocator: std.mem.Allocator, s: []const u8) !MysqlDsn {
    // Expected: user:pass@host:port/db
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return error.InvalidDsn;
    const creds = s[0..at];
    const host_port_db = s[at + 1 ..];

    const colon = std.mem.indexOfScalar(u8, creds, ':');
    const user = if (colon) |c| creds[0..c] else creds;
    const pass = if (colon) |c| creds[c + 1 ..] else "";

    const slash = std.mem.indexOfScalar(u8, host_port_db, '/') orelse return error.InvalidDsn;
    const host_port = host_port_db[0..slash];
    const db = host_port_db[slash + 1 ..];

    const port_colon = std.mem.indexOfScalar(u8, host_port, ':');
    const host = if (port_colon) |c| host_port[0..c] else host_port;
    const port: u32 = if (port_colon) |c| try std.fmt.parseInt(u32, host_port[c + 1 ..], 10) else 3306;

    return MysqlDsn{
        .user = try allocator.dupe(u8, user),
        .pass = try allocator.dupe(u8, pass),
        .host = try allocator.dupe(u8, host),
        .port = port,
        .db = try allocator.dupe(u8, db),
    };
}
