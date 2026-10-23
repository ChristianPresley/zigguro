//! Dashing (E13.F07.S01.T02): polylines cut into the "on" pieces of a
//! dash pattern by arc length, before stroking.

const std = @import("std");
const Polyline = @import("flatten.zig").Polyline;

const Allocator = std.mem.Allocator;

/// The dashes of `lines` under `pattern` (alternating on and off
/// lengths; an odd-length pattern repeats twice, as in SVG), starting
/// `offset` into the pattern. Each polyline restarts the pattern; a
/// closed one is dashed along its closing segment too. A pattern with no
/// positive length leaves the lines whole.
pub fn dashPolylines(a: Allocator, lines: []const Polyline, pattern_in: []const f32, offset: f32) ![]const Polyline {
    var total: f32 = 0;
    for (pattern_in) |d| {
        if (!(d >= 0) or !std.math.isFinite(d)) return lines;
        total += d;
    }
    if (!(total > 0)) return lines;
    const pattern = if (pattern_in.len % 2 == 1) try std.mem.concat(a, f32, &.{ pattern_in, pattern_in }) else pattern_in;
    const period = if (pattern_in.len % 2 == 1) total * 2 else total;

    var out: std.ArrayListUnmanaged(Polyline) = .empty;
    for (lines) |pl| {
        var pts: std.ArrayListUnmanaged([2]f32) = .empty;
        try pts.appendSlice(a, pl.points);
        if (pl.closed and pl.points.len > 1) try pts.append(a, pl.points[0]);
        if (pts.items.len < 2) continue;

        // Where in the pattern the line starts.
        var idx: usize = 0;
        var left = @mod(offset, period);
        if (left < 0) left += period;
        while (left >= pattern[idx]) {
            left -= pattern[idx];
            idx = (idx + 1) % pattern.len;
        }
        var remaining = pattern[idx] - left;
        var on = idx % 2 == 0;
        var cur: std.ArrayListUnmanaged([2]f32) = .empty;
        if (on) try cur.append(a, pts.items[0]);

        for (pts.items[0 .. pts.items.len - 1], pts.items[1..]) |p0, p1| {
            const dx = p1[0] - p0[0];
            const dy = p1[1] - p0[1];
            const seg = @sqrt(dx * dx + dy * dy);
            var t: f32 = 0;
            while (seg - t > remaining) {
                t += remaining;
                const q = [2]f32{ p0[0] + dx * t / seg, p0[1] + dy * t / seg };
                if (on) {
                    try cur.append(a, q);
                    try out.append(a, .{ .points = try cur.toOwnedSlice(a), .closed = false });
                } else {
                    try cur.append(a, q);
                }
                on = !on;
                idx = (idx + 1) % pattern.len;
                remaining = pattern[idx];
            }
            remaining -= seg - t;
            if (on) try cur.append(a, p1);
        }
        if (on and cur.items.len > 1) try out.append(a, .{ .points = try cur.toOwnedSlice(a), .closed = false });
    }
    return out.items;
}

/// The length of a polyline.
pub fn length(points: []const [2]f32) f32 {
    var l: f32 = 0;
    if (points.len < 2) return 0;
    for (points[0 .. points.len - 1], points[1..]) |p0, p1| {
        const dx = p1[0] - p0[0];
        const dy = p1[1] - p0[1];
        l += @sqrt(dx * dx + dy * dy);
    }
    return l;
}
