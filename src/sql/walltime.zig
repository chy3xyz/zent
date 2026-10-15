//! Wall-clock readings — the public `zent.walltime`.
//!
//! Zig 0.17 removed the wall-clock readers from `std.time`, and the library
//! answered one need at a time: `driver.monotonicNs` grew a `CLOCK_REALTIME`
//! fallback, `outbox` a `gettimeofday`-based `nowMs`, `pool` a libc `time()`
//! `unixTimestamp`. Meanwhile `sql_logger.nowUs` is deliberately **monotonic**
//! (it measures query durations, see v0.83), so the consumers who had been
//! calling it for a stored `created_at` were left stamping uptime microseconds
//! with no public replacement. This module is that replacement: one
//! `CLOCK_REALTIME` read, one failure policy, four unit adapters, and the three
//! private readers above now delegate here.
//!
//! It sits in `src/sql/` because two of the three readers it replaces do
//! (`driver.zig`, `pool.zig`), and it is exported at the top level as
//! `zent.walltime` because a consumer needs it without reaching into the
//! driver.
//!
//! **This is the wall clock.** NTP, a leap second or a manual `date` steps it,
//! and it can be rolled *backwards*, so the difference of two readings is not a
//! duration. For durations and deadlines use the monotonic clock —
//! `zent.sql_logger.nowUs()` or `zent.sql_driver.monotonicNs()`.
//!
//! Failure policy: a failed `clock_gettime` answers **0** and warns — the same
//! shape `driver.monotonicNs` documents for its own fallback, rather than a
//! second answer (`null`, `-1`) for the same syscall. Note that 0 is the Unix
//! epoch and not "now": a caller that must not confuse the two has to read the
//! clock itself.

const std = @import("std");
const zent_log = @import("../runtime/log.zig");

/// Read `CLOCK_REALTIME` as nanoseconds since the Unix epoch, or null when the
/// syscall fails.
fn readRealtimeNs() ?i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return null;
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
}

/// The one failure path: warn, then answer the epoch.
fn failed() i64 {
    zent_log.warn("clock_gettime(CLOCK_REALTIME) failed; wall-clock reads answer 0 (the Unix epoch)", .{});
    return 0;
}

/// Nanoseconds since the Unix epoch on the wall clock. The primitive the other
/// three units are truncated from, and what `driver.monotonicNs` falls back to
/// when `CLOCK_MONOTONIC` is unavailable.
pub fn nowNanos() i64 {
    return readRealtimeNs() orelse failed();
}

/// Microseconds since the Unix epoch on the wall clock.
pub fn nowMicros() i64 {
    return @divTrunc(nowNanos(), std.time.ns_per_us);
}

/// Milliseconds since the Unix epoch on the wall clock — the unit
/// `outbox.nowMs` stamps `created_at` and `claimed_at` with.
pub fn nowMilli() i64 {
    return @divTrunc(nowNanos(), std.time.ns_per_ms);
}

/// Whole seconds since the Unix epoch on the wall clock — the unit
/// `pool.unixTimestamp` measures connection age in, the unit the migration
/// history's `applied_at` is written in, and the unit zent's `.time` columns
/// (and the `TimeMixin` audit columns) store.
pub fn nowSecs() i64 {
    return @divTrunc(nowNanos(), std.time.ns_per_s);
}

/// True when the reading is where this module expects one: far enough from 0
/// that a monotonic reading, the epoch or a negative is excluded.
fn isEpochScale(ns: i64) bool {
    return ns >= 1_600_000_000 * std.time.ns_per_s and ns <= 4_000_000_000 * std.time.ns_per_s;
}

test "wall-clock readings are epoch-scale and unit-consistent" {
    // A plausible *window*, not a pinned value: the wall clock is whatever the
    // machine's is, so asserting "2026" would fail on a host with a wrong clock
    // and prove nothing about this module. 2020..2096 is wide enough that only
    // a wrong source falls outside it — a monotonic reading (boot-relative,
    // seconds), 0 (the failure answer), or a negative.
    const secs = nowSecs();
    try std.testing.expect(isEpochScale(secs * std.time.ns_per_s));

    // Units, not values: each reading must describe the *same instant* as the
    // nanosecond one, within two of its own units. A swapped unit — `nowMicros`
    // returning nanoseconds, `nowMilli` returning microseconds — is three
    // orders of magnitude away and fails here. The tolerance covers a tick
    // between two calls, and `@abs` keeps the assertion indifferent to which
    // call ran first.
    const nanos = nowNanos();
    try std.testing.expect(isEpochScale(nanos));
    try std.testing.expect(@abs(nanos - secs * std.time.ns_per_s) < 2 * std.time.ns_per_s);
    try std.testing.expect(@abs(nanos - nowMicros() * std.time.ns_per_us) < 2 * std.time.ns_per_us);
    try std.testing.expect(@abs(nanos - nowMilli() * std.time.ns_per_ms) < 2 * std.time.ns_per_ms);
}

test "the wall clock does not step backwards between two consecutive reads" {
    // Consecutive reads of one clock can only decrease if the clock was
    // *stepped* (NTP correction, a manual `date`, a leap second), which is a
    // property of the machine rather than of this module — so the tolerance is
    // exactly that step and no more. Without it the test would be flaky on a
    // host whose clock was just corrected, and a flaky test is worse than none;
    // with it, a clock wired to the wrong source still fails (a monotonic
    // reading is seconds, not epoch-scale, so the test above catches it).
    const before = nowNanos();
    const after = nowNanos();
    try std.testing.expect(after >= before - std.time.ns_per_ms);

    // Whole-unit truncation keeps the same order, which is what the
    // `staleCutoffMs` / pool-age callers rely on.
    const before_ms = nowMilli();
    const after_ms = nowMilli();
    try std.testing.expect(after_ms >= before_ms - 1);

    const before_s = nowSecs();
    const after_s = nowSecs();
    try std.testing.expect(after_s >= before_s - 1);
}
