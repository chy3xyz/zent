//! The package version, readable from Zig at comptime.
//!
//! `build.zig.zon` remains the single source of truth; this file is a mirror
//! kept honest by two gates:
//!  - `scripts/check-version.sh` (CI) fails if the two disagree;
//!  - `scripts/release.sh` / `scripts/bump-version.sh` bump both together.
//!
//! It exists so a consumer can check *which version it is building* without
//! consulting git. Consumers that pinned a dependency by tag used to verify
//! it by comparing their checkout's HEAD against the tag's commit, which
//! breaks the moment a docs commit lands after the tag — a false alarm every
//! release. Compare this constant instead:
//!
//! ```zig
//! const zent = @import("zent");
//! comptime {
//!     if (!std.mem.eql(u8, zent.version, "0.38.0")) @compileError("zent pin drift");
//! }
//! ```
pub const version = "0.41.1";

const std = @import("std");

test "version is a plain x.y.z string" {
    // Guards the mirror's format: the release scripts parse `build.zig.zon`
    // with this shape, so anything else would desync the gates.
    try std.testing.expect(version.len >= 5);
    var dots: usize = 0;
    for (version) |c| {
        if (c == '.') {
            dots += 1;
        } else {
            try std.testing.expect(std.ascii.isDigit(c));
        }
    }
    try std.testing.expectEqual(@as(usize, 2), dots);
}
