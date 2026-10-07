//! Distributed-safe ID generation: uuidv4 (random) and uuidv7
//! (time-ordered, ideal for keyset pagination and cross-shard writes where
//! auto-increment ids would collide). uuids are stored as TEXT via
//! `field.UUID("id")` (Postgres maps to the native UUID type).
//!
//! Each thread seeds its own ChaCha CSPRNG once from OS entropy —
//! getentropy on macOS, getrandom on Linux, /dev/urandom as the portable
//! fallback — and panics if no source answers: ASLR addresses are not
//! entropy, and a predictable uuidv4 is not random.

const builtin = @import("builtin");
const std = @import("std");

pub const Uuid = [16]u8;

/// std.c only re-exports `getentropy` for android/emscripten in 0.17, but
/// libSystem has shipped it since macOS 10.12.
extern "c" fn getentropy(buffer: [*]u8, size: usize) c_int;

/// libc `getrandom` exists on glibc >= 2.25 and musl; anything older takes
/// the raw syscall. Not `arc4random_buf`: glibc < 2.36 does not have it.
const use_libc_getrandom = builtin.link_libc and @TypeOf(std.c.getrandom) != void;

/// Per-thread CSPRNG. Thread-local on purpose: the instance mutates on every
/// draw, so one shared static would be a data race between threads.
threadlocal var csprng: ?std.Random.DefaultCsprng = null;

fn getRandom() std.Random {
    if (csprng) |*c| return c.random();
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    fillEntropy(&seed);
    csprng = .init(seed);
    return csprng.?.random();
}

/// Fills `buf` with OS entropy and panics if every source fails — a UUID
/// generator must never silently fall back to a predictable seed.
fn fillEntropy(buf: []u8) void {
    if (builtin.target.os.tag == .macos) {
        if (getentropy(buf.ptr, buf.len) == 0) return;
    } else if (builtin.target.os.tag == .linux and fillWithGetrandom(buf)) {
        return;
    }
    fillWithUrandom(buf) catch @panic("OS entropy unavailable");
}

fn fillWithGetrandom(buf: []u8) bool {
    const getrandom = if (use_libc_getrandom) std.c.getrandom else std.os.linux.getrandom;
    var filled: usize = 0;
    while (filled < buf.len) {
        const rc = getrandom(buf[filled..].ptr, buf.len - filled, 0);
        switch (if (use_libc_getrandom) std.posix.errno(rc) else std.os.linux.errno(rc)) {
            .SUCCESS => filled += @intCast(rc),
            .INTR => continue,
            else => return false,
        }
    }
    return true;
}

/// std.fs in 0.17 needs an `Io` handle this layer does not carry, so
/// /dev/urandom is read through the POSIX calls instead.
fn fillWithUrandom(buf: []u8) !void {
    const flags: std.posix.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
    const fd = try std.posix.openat(std.posix.AT.FDCWD, "/dev/urandom", flags, 0);
    defer _ = std.posix.system.close(fd);
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = try std.posix.read(fd, buf[filled..]);
        if (n == 0) return error.EntropyUnavailable;
        filled += n;
    }
}

/// Random (version 4) UUID — no clock needed.
pub fn uuidv4() Uuid {
    var b: Uuid = undefined;
    const rng = getRandom();
    const val = rng.int(u128);
    std.mem.writeInt(u128, &b, val, .little);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    return b;
}

/// Time-ordered (version 7) UUID: 48-bit Unix-millisecond prefix + random
/// suffix. `now_ms` must be monotonic-ish wall-clock milliseconds.
pub fn uuidv7(now_ms: i64) Uuid {
    var b: Uuid = undefined;
    const rng = getRandom();
    const val = rng.int(u128);
    std.mem.writeInt(u128, &b, val, .little);
    const ms: u64 = @intCast(now_ms);
    b[0] = @truncate(ms >> 40);
    b[1] = @truncate(ms >> 32);
    b[2] = @truncate(ms >> 24);
    b[3] = @truncate(ms >> 16);
    b[4] = @truncate(ms >> 8);
    b[5] = @truncate(ms);
    b[6] = (b[6] & 0x0f) | 0x70;
    b[8] = (b[8] & 0x3f) | 0x80;
    return b;
}

/// Canonical lowercase form: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.
pub fn format(u: Uuid, buf: *[36]u8) []const u8 {
    const hex = "0123456789abcdef";
    var pos: usize = 0;
    for (u, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buf[pos] = '-';
            pos += 1;
        }
        buf[pos] = hex[byte >> 4];
        buf[pos + 1] = hex[byte & 0x0f];
        pos += 2;
    }
    return buf[0..36];
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

test "uuidv4 sets version/variant bits" {
    const u = uuidv4();
    try testing.expectEqual(@as(u8, 0x40), u[6] & 0xf0);
    try testing.expectEqual(@as(u8, 0x80), u[8] & 0xc0);
}

test "uuidv7 time prefix is monotonic and version bits set" {
    const a = uuidv7(1000);
    const b = uuidv7(2000);
    const a_prefix = std.mem.readInt(u64, a[0..8], .big);
    const b_prefix = std.mem.readInt(u64, b[0..8], .big);
    try testing.expect(b_prefix > a_prefix);
    try testing.expectEqual(@as(u8, 0x70), a[6] & 0xf0);
    try testing.expectEqual(@as(u8, 0x80), a[8] & 0xc0);
}

test "uuid format is canonical" {
    var buf: [36]u8 = undefined;
    const s = format(uuidv4(), &buf);
    try testing.expectEqual(@as(usize, 36), s.len);
    try testing.expectEqual(@as(u8, '-'), s[8]);
    try testing.expectEqual(@as(u8, '-'), s[13]);
    try testing.expectEqual(@as(u8, '-'), s[18]);
    try testing.expectEqual(@as(u8, '-'), s[23]);
}

test "concurrent uuidv4 across threads yields distinct values" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const thread_count = 4;
    const per_thread = 32;

    const Worker = struct {
        fn run(out: *[thread_count][per_thread]Uuid, row: usize) void {
            for (0..per_thread) |i| out[row][i] = uuidv4();
        }
    };

    // Pure value type: collected into stack arrays, nothing to free — a run
    // under std.testing.allocator still fails if generation ever leaks.
    var out: [thread_count][per_thread]Uuid = undefined;
    var threads: [thread_count]std.Thread = undefined;
    for (0..thread_count) |t| {
        threads[t] = try std.Thread.spawn(.{}, Worker.run, .{ &out, t });
    }
    for (threads) |t| t.join();

    var seen: [thread_count * per_thread]Uuid = undefined;
    var seen_len: usize = 0;
    for (0..thread_count) |t| {
        for (0..per_thread) |i| {
            for (seen[0..seen_len]) |s| {
                try testing.expect(!std.mem.eql(u8, &s, &out[t][i]));
            }
            seen[seen_len] = out[t][i];
            seen_len += 1;
        }
    }
}
