//! Packing of pairs of f16 values into u32 fields of `Prim`
//! (radii, shadow sigma/spread). The GPU unpacks them with `unpackHalf2x16`;
//! the low half is the first value.

const std = @import("std");

/// Packs `lo` and `hi` as two IEEE half floats (round to nearest even).
pub fn pack2(lo: f32, hi: f32) u32 {
    const a: u16 = @bitCast(@as(f16, @floatCast(lo)));
    const b: u16 = @bitCast(@as(f16, @floatCast(hi)));
    return @as(u32, a) | (@as(u32, b) << 16);
}

/// Unpacks the two halves written by `pack2`.
pub fn unpack2(v: u32) [2]f32 {
    const a: f16 = @bitCast(@as(u16, @truncate(v)));
    const b: f16 = @bitCast(@as(u16, @truncate(v >> 16)));
    return .{ @floatCast(a), @floatCast(b) };
}

/// Rounds `x` to the nearest f16-representable value, as stored by `pack2`.
pub fn round(x: f32) f32 {
    return @floatCast(@as(f16, @floatCast(x)));
}

test "f16: pack/unpack exact for small integers and halves" {
    const vals = [_]f32{ 0, 0.5, 1, 4, 12.5, 100, 2048 };
    for (vals) |a| for (vals) |b| {
        const u = unpack2(pack2(a, b));
        try std.testing.expectEqual(a, u[0]);
        try std.testing.expectEqual(b, u[1]);
    };
}

test "f16: round matches unpack" {
    try std.testing.expectEqual(round(1.0 / 3.0), unpack2(pack2(1.0 / 3.0, 0))[0]);
}
