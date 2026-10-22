//! Simple case folding (UTS #18 RL1.5) over the generated orbit tables: an
//! orbit is the set of code points sharing one simple case fold, e.g.
//! {K, k, U+212A KELVIN SIGN}.

const std = @import("std");
const tables = @import("regex_tables");

/// One entry of the orbit index.
pub const Entry = @TypeOf(tables.fold_index[0]);

/// Every code point that belongs to a non-trivial orbit, sorted.
pub fn index() []const Entry {
    return &tables.fold_index;
}

/// The members of `e`'s orbit, sorted.
pub fn orbitOf(e: Entry) []const u21 {
    return tables.orbit_cps[e.orbit.start..][0..e.orbit.len];
}

/// All code points with the same simple case fold as `cp` (including `cp`),
/// sorted; a one-element slice when `cp` has no case variants.
pub fn simpleFoldOrbit(cp: u21) []const u21 {
    const idx = index();
    var lo: usize = 0;
    var hi: usize = idx.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (idx[mid].cp < cp) lo = mid + 1 else hi = mid;
    }
    if (lo < idx.len and idx[lo].cp == cp) return orbitOf(idx[lo]);
    return singletons[0..0];
}

// Stand-in for "no orbit": callers treat an empty slice as {cp}.
const singletons = [_]u21{};

test "casefold: orbit symmetric (k, K, U+212A KELVIN SIGN)" {
    const want = [_]u21{ 'K', 'k', 0x212A };
    for (want) |cp| try std.testing.expectEqualSlices(u21, &want, simpleFoldOrbit(cp));
    try std.testing.expectEqual(@as(usize, 0), simpleFoldOrbit('1').len);
    // Sigma: Σ σ ς.
    try std.testing.expectEqualSlices(u21, &.{ 0x3A3, 0x3C2, 0x3C3 }, simpleFoldOrbit(0x3C2));
    // Every orbit is symmetric.
    for (index()) |e| {
        for (orbitOf(e)) |m| try std.testing.expectEqualSlices(u21, orbitOf(e), simpleFoldOrbit(m));
    }
}
