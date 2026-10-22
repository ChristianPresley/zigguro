//! `avar`: per-axis segment maps applied after default normalization. v1
//! maps are applied; v2's extra mappings are ignored with a warning.

const std = @import("std");
const reader = @import("../reader.zig");

const log = std.log.scoped(.zg_text);

/// A view of `avar` (v1 segment maps; v2's extra mappings are ignored).
pub const Avar = struct {
    data: []const u8,
    axis_count: u16,
    /// Offset of the first segment map.
    maps_off: usize = 8,

    /// Validates the header and every segment map.
    pub fn init(bytes: []const u8) error{Malformed}!Avar {
        const major = try reader.readAt(u16, bytes, 0);
        if (major != 1 and major != 2) return error.Malformed;
        if (major == 2) log.warn("avar v2: only the v1 segment maps are applied", .{});
        const n = try reader.readAt(u16, bytes, 6);
        var off: usize = 8;
        for (0..n) |_| {
            const count = try reader.readAt(u16, bytes, off);
            _ = try reader.subLen(bytes, off + 2, @as(usize, count) * 4);
            off += 2 + @as(usize, count) * 4;
        }
        return .{ .data = bytes, .axis_count = n };
    }

    /// The segment map of axis `a` as (from, to) F2Dot14 pairs, or null
    /// when it is absent or invalid (no -1→-1, 0→0, 1→1 anchors, or
    /// decreasing `from`), in which case the axis is not remapped.
    pub fn segments(v: *const Avar, a: usize) ?[]const u8 {
        if (a >= v.axis_count) return null;
        var off = v.maps_off;
        for (0..a) |_| off += 2 + @as(usize, std.mem.readInt(u16, v.data[off..][0..2], .big)) * 4;
        const count = std.mem.readInt(u16, v.data[off..][0..2], .big);
        const m = v.data[off + 2 ..][0 .. @as(usize, count) * 4];
        var anchors: u8 = 0;
        var prev: i32 = std.math.minInt(i32);
        for (0..count) |k| {
            const from = std.mem.readInt(i16, m[k * 4 ..][0..2], .big);
            const to = std.mem.readInt(i16, m[k * 4 + 2 ..][0..2], .big);
            if (from < prev) return null;
            prev = from;
            if (from == to and (from == -16384 or from == 0 or from == 16384)) anchors += 1;
        }
        return if (anchors >= 3) m else null;
    }

    /// Applies the axis-`a` map to the F2Dot14 coordinate `v`.
    pub fn map(av: *const Avar, a: usize, v: i16) i16 {
        const m = av.segments(a) orelse return v;
        return mapSegments(m, v);
    }
};

/// The otvaroverview avar algorithm over raw (from, to) pairs.
pub fn mapSegments(m: []const u8, v: i16) i16 {
    const n = m.len / 4;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const from = std.mem.readInt(i16, m[k * 4 ..][0..2], .big);
        if (from >= v) break;
    }
    if (k == n) return v; // cannot happen with a 1→1 anchor
    const f1 = std.mem.readInt(i16, m[k * 4 ..][0..2], .big);
    const t1 = std.mem.readInt(i16, m[k * 4 + 2 ..][0..2], .big);
    if (f1 == v or k == 0) return t1;
    const f0 = std.mem.readInt(i16, m[(k - 1) * 4 ..][0..2], .big);
    const t0 = std.mem.readInt(i16, m[(k - 1) * 4 + 2 ..][0..2], .big);
    const r = @as(f64, @floatFromInt(t0)) + @as(f64, @floatFromInt(@as(i32, t1) - t0)) * @as(f64, @floatFromInt(@as(i32, v) - f0)) / @as(f64, @floatFromInt(@as(i32, f1) - f0));
    return @intFromFloat(std.math.clamp(@round(r), -16384, 16384));
}
