//! SIMD scan for runs of printable ASCII (0x20-0x7E), the ground-state fast
//! path in front of the state table.

const std = @import("std");

const lanes = std.simd.suggestVectorLength(u8) orelse 16;
const V = @Vector(lanes, u8);

/// Number of leading bytes of `bytes` in 0x20..0x7E.
pub fn scanPrintable(bytes: []const u8) usize {
    var i: usize = 0;
    const lo: V = @splat(0x20);
    const hi: V = @splat(0x7F);
    while (i + lanes <= bytes.len) : (i += lanes) {
        const v: V = bytes[i..][0..lanes].*;
        const bad = (v < lo) | (v >= hi);
        if (std.simd.firstTrue(bad)) |k| return i + k;
    }
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        if (b < 0x20 or b >= 0x7F) return i;
    }
    return i;
}

fn scalarRef(bytes: []const u8) usize {
    for (bytes, 0..) |b, i| if (b < 0x20 or b >= 0x7F) return i;
    return bytes.len;
}

test "scanPrintable equals scalar reference" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const r = prng.random();
    var buf: [300 + 64]u8 = undefined;
    for (0..301) |len| {
        for (0..lanes) |align_off| {
            const s = buf[align_off..][0..len];
            for (s) |*b| b.* = r.intRangeAtMost(u8, 0x20, 0x7E);
            // Plant zero or one disallowed byte at a random position.
            if (len > 0 and r.boolean()) {
                const bad = [_]u8{ 0x00, 0x1B, 0x1F, 0x7F, 0x80, 0xFF, 0x0A };
                s[r.uintLessThan(usize, len)] = bad[r.uintLessThan(usize, bad.len)];
            }
            try std.testing.expectEqual(scalarRef(s), scanPrintable(s));
        }
    }
}
