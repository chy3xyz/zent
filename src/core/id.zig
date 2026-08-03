//! Distributed-safe ID generation: uuidv4 (random) and uuidv7
//! (time-ordered, ideal for keyset pagination and cross-shard writes where
//! auto-increment ids would collide). uuids are stored as TEXT via
//! `field.UUID("id")` (Postgres maps to the native UUID type).

const std = @import("std");

pub const Uuid = [16]u8;

fn getRandom() std.Random {
    const Seed = struct {
        var csprng: ?std.Random = null;
        var instance: ?std.Random.DefaultCsprng = null;
    };
    if (Seed.csprng) |r| return r;
    var seed: [32]u8 = undefined;
    // Multi-source entropy (ASLR addresses + salt; zent has no clock, so
    // callers wanting wall-clock mixing can pass now_ms to uuidv7).
    std.mem.writeInt(u64, seed[0..8], @intFromPtr(&seed), .little);
    std.mem.writeInt(u64, seed[8..16], @intFromPtr(&Seed.csprng), .little);
    std.mem.writeInt(u64, seed[16..24], @intFromPtr(&getRandom), .little);
    @memset(seed[24..32], 0xA5);
    // Hold the CSPRNG instance statically: Random.fillFn/ptr point into it,
    // so a stack-local instance would dangle after this function returns.
    Seed.instance = std.Random.DefaultCsprng.init(seed);
    const r = Seed.instance.?.random();
    Seed.csprng = r;
    return r;
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
