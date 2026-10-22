//! Procedural terminal glyphs, drawn to fit the cell exactly so lines and
//! blocks join seamlessly across cells at any size: box drawing
//! (U+2500–U+257F), block elements (U+2580–U+259F), braille
//! (U+2800–U+28FF), the Powerline triangles and chevrons (U+E0B0–U+E0B3)
//! and the legacy-computing sextants (U+1FB00–U+1FB3B).
//!
//! Light lines are max(1, round(cell_h / 16)) px, heavy lines twice that;
//! double lines are two light lines one light width apart. Straight parts
//! are filled pixel by pixel; arcs, diagonals and Powerline shapes go
//! through the coverage rasterizer. Output is gray8 coverage, cell sized.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Accumulator = @import("../raster/coverage.zig").Accumulator;

/// True for code points drawn procedurally.
pub fn isProcedural(cp: u21) bool {
    return switch (cp) {
        0x2500...0x259F, 0x2800...0x28FF, 0xE0B0...0xE0B3, 0x1FB00...0x1FB3B => true,
        else => false,
    };
}

/// A compact id (< 512) for a procedural code point, for glyph keys.
pub fn id(cp: u21) u16 {
    return switch (cp) {
        0x2500...0x259F => @intCast(cp - 0x2500),
        0x2800...0x28FF => @intCast(160 + cp - 0x2800),
        0xE0B0...0xE0B3 => @intCast(416 + cp - 0xE0B0),
        0x1FB00...0x1FB3B => @intCast(420 + cp - 0x1FB00),
        else => unreachable,
    };
}

/// The code point of a procedural id.
pub fn codepoint(i: u16) ?u21 {
    return switch (i) {
        0...159 => 0x2500 + @as(u21, i),
        160...415 => 0x2800 + @as(u21, i - 160),
        416...419 => 0xE0B0 + @as(u21, i - 416),
        420...479 => 0x1FB00 + @as(u21, i - 420),
        else => null,
    };
}

/// A gray8 bitmap owned by the caller.
pub const Canvas = struct {
    w: u32,
    h: u32,
    pixels: []u8,

    fn fill(c: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32, v: u8) void {
        const xa: u32 = @intCast(std.math.clamp(x0, 0, @as(i32, @intCast(c.w))));
        const xb: u32 = @intCast(std.math.clamp(x1, 0, @as(i32, @intCast(c.w))));
        const ya: u32 = @intCast(std.math.clamp(y0, 0, @as(i32, @intCast(c.h))));
        const yb: u32 = @intCast(std.math.clamp(y1, 0, @as(i32, @intCast(c.h))));
        if (xa >= xb) return;
        var y = ya;
        while (y < yb) : (y += 1) @memset(c.pixels[y * c.w + xa .. y * c.w + xb], v);
    }

    fn at(c: *const Canvas, x: u32, y: u32) u8 {
        return c.pixels[y * c.w + x];
    }
};

/// Draws `cp` into `c` (zeroed first). `acc` is scratch for the coverage
/// rasterizer. Returns false when `cp` is not procedural.
pub fn draw(cp: u21, c: *Canvas, acc: *Accumulator, gpa: Allocator) Allocator.Error!bool {
    @memset(c.pixels, 0);
    if (c.w == 0 or c.h == 0) return isProcedural(cp);
    switch (cp) {
        0x2500...0x257F => try drawBox(cp, c, acc, gpa),
        0x2580...0x259F => drawBlock(cp, c),
        0x2800...0x28FF => drawBraille(@intCast(cp - 0x2800), c),
        0xE0B0...0xE0B3 => try drawPowerline(cp, c, acc, gpa),
        0x1FB00...0x1FB3B => drawSextant(cp, c),
        else => return false,
    }
    return true;
}

// ---------------------------------------------------------------- box

/// Arm weights.
const W = enum(u2) { none, light, heavy, double };

/// Up, right, down, left.
const Arms = [4]W;

fn arms(s: *const [4]u8) Arms {
    var a: Arms = undefined;
    for (s, 0..) |ch, i| a[i] = @enumFromInt(ch - '0');
    return a;
}

/// U, R, D, L weights for the line-joining characters; "" for dashes,
/// arcs and diagonals, which are drawn separately.
const box_table = [128]*const [4]u8{
    "0101", "0202", "1010", "2020", "----", "----", "----", "----", // 2500
    "----", "----", "----", "----", "0110", "0210", "0120", "0220", // 2508
    "0011", "0012", "0021", "0022", "1100", "1200", "2100", "2200", // 2510
    "1001", "1002", "2001", "2002", "1110", "1210", "2110", "1120", // 2518
    "2120", "2210", "1220", "2220", "1011", "1012", "2011", "1021", // 2520
    "2021", "2012", "1022", "2022", "0111", "0112", "0211", "0212", // 2528
    "0121", "0122", "0221", "0222", "1101", "1102", "1201", "1202", // 2530
    "2101", "2102", "2201", "2202", "1111", "1112", "1211", "1212", // 2538
    "2111", "1121", "2121", "2112", "2211", "1122", "1221", "2212", // 2540
    "1222", "2122", "2221", "2222", "----", "----", "----", "----", // 2548
    "0303", "3030", "0310", "0130", "0330", "0013", "0031", "0033", // 2550
    "1300", "3100", "3300", "1003", "3001", "3003", "1310", "3130", // 2558
    "3330", "1013", "3031", "3033", "0313", "0131", "0333", "1303", // 2560
    "3101", "3303", "1313", "3131", "3333", "----", "----", "----", // 2568
    "----", "----", "----", "----", "0001", "1000", "0100", "0010", // 2570
    "0002", "2000", "0200", "0020", "0201", "1020", "0102", "2010", // 2578
};

/// The arm table, for tests.
pub const box_table_for_tests = box_table;

/// Line metrics for a cell.
const Lines = struct {
    light: i32,
    heavy: i32,
    w: i32,
    h: i32,

    fn of(c: *const Canvas) Lines {
        const h: i32 = @intCast(c.h);
        const light: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(h)) / 16))));
        return .{ .light = light, .heavy = 2 * light, .w = @intCast(c.w), .h = h };
    }

    fn px(l: Lines, wt: W) i32 {
        return switch (wt) {
            .none => 0,
            .light => l.light,
            .heavy => l.heavy,
            .double => 3 * l.light,
        };
    }

    /// Start of a band of thickness `t` centred in `len`.
    fn start(len: i32, t: i32) i32 {
        return @divFloor(len - t, 2);
    }
};

fn drawBox(cp: u21, c: *Canvas, acc: *Accumulator, gpa: Allocator) Allocator.Error!void {
    const l = Lines.of(c);
    const code = box_table[cp - 0x2500];
    if (code[0] != '-') return joinArms(arms(code), c, l);
    switch (cp) {
        0x2504...0x250B, 0x254C...0x254F => drawDashes(cp, c, l),
        0x256D...0x2570 => try drawArc(cp, c, acc, gpa, l),
        0x2571...0x2573 => try drawDiagonals(cp, c, acc, gpa, l),
        else => unreachable,
    }
}

/// Draws the four arms with joins: a line of a horizontal arm stops at the
/// near line of a vertical double that it would otherwise cross, and
/// otherwise reaches across the whole vertical structure (and vice versa).
fn joinArms(a: Arms, c: *Canvas, l: Lines) void {
    const up = a[0];
    const right = a[1];
    const down = a[2];
    const left = a[3];
    const v_double = up == .double or down == .double;
    const h_double = left == .double or right == .double;
    // Vertical structure across x, horizontal structure across y.
    const vt = if (v_double) 3 * l.light else @max(l.px(up), l.px(down));
    const ht = if (h_double) 3 * l.light else @max(l.px(left), l.px(right));
    const v0 = Lines.start(l.w, vt);
    const h0 = Lines.start(l.h, ht);

    // Horizontal arms.
    for ([_]W{ left, right }, 0..) |wt, side| {
        if (wt == .none) continue;
        const lines: []const [2]i32 = if (wt == .double) &.{
            .{ Lines.start(l.h, 3 * l.light), 0 }, // top line, blocked by up
            .{ Lines.start(l.h, 3 * l.light) + 2 * l.light, 1 }, // bottom, by down
        } else &.{.{ Lines.start(l.h, l.px(wt)), 2 }};
        const t = if (wt == .double) l.light else l.px(wt);
        for (lines) |ln| {
            const blocked = v_double and switch (ln[1]) {
                0 => up == .double,
                1 => down == .double,
                else => up == .double and down == .double,
            };
            const reach: [2]i32 = if (vt == 0)
                .{ l.w - @divFloor(l.w, 2), @divFloor(l.w, 2) }
            else if (blocked)
                .{ v0 + l.light, v0 + 2 * l.light }
            else
                .{ v0 + vt, v0 };
            if (side == 0) c.fill(0, ln[0], reach[0], ln[0] + t, 255) else c.fill(reach[1], ln[0], l.w, ln[0] + t, 255);
        }
    }
    // Vertical arms.
    for ([_]W{ up, down }, 0..) |wt, side| {
        if (wt == .none) continue;
        const lines: []const [2]i32 = if (wt == .double) &.{
            .{ Lines.start(l.w, 3 * l.light), 0 }, // left line, blocked by left
            .{ Lines.start(l.w, 3 * l.light) + 2 * l.light, 1 }, // right, by right
        } else &.{.{ Lines.start(l.w, l.px(wt)), 2 }};
        const t = if (wt == .double) l.light else l.px(wt);
        for (lines) |ln| {
            const blocked = h_double and switch (ln[1]) {
                0 => left == .double,
                1 => right == .double,
                else => left == .double and right == .double,
            };
            const reach: [2]i32 = if (ht == 0)
                .{ l.h - @divFloor(l.h, 2), @divFloor(l.h, 2) }
            else if (blocked)
                .{ h0 + l.light, h0 + 2 * l.light }
            else
                .{ h0 + ht, h0 };
            if (side == 0) c.fill(ln[0], 0, ln[0] + t, reach[0], 255) else c.fill(ln[0], reach[1], ln[0] + t, l.h, 255);
        }
    }
}

/// Dashed lines: `n` dashes per cell, each centred in its 1/n of the cell
/// with half a gap at both ends, so neighbouring cells tile evenly.
fn drawDashes(cp: u21, c: *Canvas, l: Lines) void {
    const n: i32, const vertical: bool, const heavy: bool = switch (cp) {
        0x2504 => .{ 3, false, false },
        0x2505 => .{ 3, false, true },
        0x2506 => .{ 3, true, false },
        0x2507 => .{ 3, true, true },
        0x2508 => .{ 4, false, false },
        0x2509 => .{ 4, false, true },
        0x250A => .{ 4, true, false },
        0x250B => .{ 4, true, true },
        0x254C => .{ 2, false, false },
        0x254D => .{ 2, false, true },
        0x254E => .{ 2, true, false },
        0x254F => .{ 2, true, true },
        else => unreachable,
    };
    const t = if (heavy) l.heavy else l.light;
    const len = if (vertical) l.h else l.w;
    const across = Lines.start(if (vertical) l.w else l.h, t);
    const lenf: f32 = @floatFromInt(len);
    const seg = lenf / @as(f32, @floatFromInt(n));
    const gap = @max(1, @round(seg / 3));
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const a: i32 = @intFromFloat(@round(fi * seg + gap / 2));
        const b: i32 = @intFromFloat(@round((fi + 1) * seg - gap / 2));
        if (vertical) c.fill(across, a, across + t, b, 255) else c.fill(a, across, b, across + t, 255);
    }
}

/// Fills `poly` (pixel space, y down) with the coverage rasterizer and
/// merges it into `c` by max.
fn fillPoly(c: *Canvas, acc: *Accumulator, gpa: Allocator, poly: []const [2]f32) Allocator.Error!void {
    try acc.reset(gpa, c.w, c.h);
    for (poly, 0..) |p, i| acc.line(p, poly[(i + 1) % poly.len]);
    try mergeAcc(c, acc, gpa);
}

fn mergeAcc(c: *Canvas, acc: *Accumulator, gpa: Allocator) Allocator.Error!void {
    const tmp = try gpa.alloc(u8, c.w * c.h);
    defer gpa.free(tmp);
    acc.integrate(tmp, c.w);
    for (c.pixels, tmp) |*d, s| d.* = @max(d.*, s);
}

/// Rounded corners: a quarter circle through the centre lines with
/// straight ends to the two cell edges.
fn drawArc(cp: u21, c: *Canvas, acc: *Accumulator, gpa: Allocator, l: Lines) Allocator.Error!void {
    const t = l.light;
    const vx0 = Lines.start(l.w, t);
    const hy0 = Lines.start(l.h, t);
    const cx = @as(f32, @floatFromInt(vx0)) + @as(f32, @floatFromInt(t)) / 2;
    const cy = @as(f32, @floatFromInt(hy0)) + @as(f32, @floatFromInt(t)) / 2;
    // Directions to the two arms: x towards right (+1) or left (-1), y
    // towards down (+1) or up (-1).
    const sx: f32, const sy: f32 = switch (cp) {
        0x256D => .{ 1, 1 }, // down and right
        0x256E => .{ -1, 1 }, // down and left
        0x256F => .{ -1, -1 }, // up and left
        0x2570 => .{ 1, -1 }, // up and right
        else => unreachable,
    };
    const fw: f32 = @floatFromInt(l.w);
    const fh: f32 = @floatFromInt(l.h);
    const room_x = if (sx > 0) fw - cx else cx;
    const room_y = if (sy > 0) fh - cy else cy;
    const r = @min(room_x, room_y);
    // The circle's centre sits diagonally off the corner point.
    const ox = cx + sx * r;
    const oy = cy + sy * r;
    const half = @as(f32, @floatFromInt(t)) / 2;
    const steps = 24;
    var poly: [2 * (steps + 1)][2]f32 = undefined;
    for (0..steps + 1) |k| {
        const ang = @as(f32, @floatFromInt(k)) / steps * (std.math.pi / 2.0);
        // From the vertical arm's end (cx, oy) to the horizontal arm's end
        // (ox, cy).
        const dx = -sx * @cos(ang);
        const dy = -sy * @sin(ang);
        poly[k] = .{ ox + dx * (r + half), oy + dy * (r + half) };
        poly[2 * (steps + 1) - 1 - k] = .{ ox + dx * (r - half), oy + dy * (r - half) };
    }
    try fillPoly(c, acc, gpa, &poly);
    // Straight ends from the arc to the edges.
    const ix: i32 = @intFromFloat(@round(oy));
    if (sy > 0) c.fill(vx0, ix, vx0 + t, l.h, 255) else c.fill(vx0, 0, vx0 + t, ix, 255);
    const iy: i32 = @intFromFloat(@round(ox));
    if (sx > 0) c.fill(iy, hy0, l.w, hy0 + t, 255) else c.fill(0, hy0, iy, hy0 + t, 255);
}

/// Corner-to-corner diagonals of light weight.
fn drawDiagonals(cp: u21, c: *Canvas, acc: *Accumulator, gpa: Allocator, l: Lines) Allocator.Error!void {
    const fw: f32 = @floatFromInt(l.w);
    const fh: f32 = @floatFromInt(l.h);
    // Half the line's horizontal extent for a perpendicular width of t.
    const d = @as(f32, @floatFromInt(l.light)) * @sqrt(fw * fw + fh * fh) / (2 * fh);
    if (cp == 0x2571 or cp == 0x2573) // upper right to lower left
        try fillPoly(c, acc, gpa, &.{ .{ fw - d, 0 }, .{ fw + d, 0 }, .{ d, fh }, .{ -d, fh } });
    if (cp == 0x2572 or cp == 0x2573) // upper left to lower right
        try fillPoly(c, acc, gpa, &.{ .{ -d, 0 }, .{ d, 0 }, .{ fw + d, fh }, .{ fw - d, fh } });
}

// ---------------------------------------------------------------- blocks

fn frac(len: u32, num: u32, den: u32) i32 {
    return @intCast((len * num + den / 2) / den);
}

fn drawBlock(cp: u21, c: *Canvas) void {
    const w: i32 = @intCast(c.w);
    const h: i32 = @intCast(c.h);
    switch (cp) {
        0x2580 => c.fill(0, 0, w, frac(c.h, 1, 2), 255),
        0x2581...0x2588 => c.fill(0, h - frac(c.h, @intCast(cp - 0x2580), 8), w, h, 255),
        0x2589...0x258F => c.fill(0, 0, frac(c.w, @intCast(0x2590 - cp), 8), h, 255),
        0x2590 => c.fill(frac(c.w, 1, 2), 0, w, h, 255),
        0x2591 => c.fill(0, 0, w, h, 64),
        0x2592 => c.fill(0, 0, w, h, 128),
        0x2593 => c.fill(0, 0, w, h, 191),
        0x2594 => c.fill(0, 0, w, frac(c.h, 1, 8), 255),
        0x2595 => c.fill(w - frac(c.w, 1, 8), 0, w, h, 255),
        else => {
            // Quadrants: bits UL, UR, LL, LR.
            const q: u4 = switch (cp) {
                0x2596 => 0b0100,
                0x2597 => 0b1000,
                0x2598 => 0b0001,
                0x2599 => 0b1101,
                0x259A => 0b1001,
                0x259B => 0b0111,
                0x259C => 0b1011,
                0x259D => 0b0010,
                0x259E => 0b0110,
                0x259F => 0b1110,
                else => unreachable,
            };
            const mx = frac(c.w, 1, 2);
            const my = frac(c.h, 1, 2);
            if (q & 1 != 0) c.fill(0, 0, mx, my, 255);
            if (q & 2 != 0) c.fill(mx, 0, w, my, 255);
            if (q & 4 != 0) c.fill(0, my, mx, h, 255);
            if (q & 8 != 0) c.fill(mx, my, w, h, 255);
        },
    }
}

/// Sextants: a 2×3 grid; bit k of the mask is sextant k + 1 (left to
/// right, top to bottom). The code points skip the two half blocks.
fn drawSextant(cp: u21, c: *Canvas) void {
    var mask: u32 = cp - 0x1FB00 + 1;
    if (mask >= 21) mask += 1;
    if (mask >= 42) mask += 1;
    const xs = [3]i32{ 0, frac(c.w, 1, 2), @intCast(c.w) };
    const ys = [4]i32{ 0, frac(c.h, 1, 3), frac(c.h, 2, 3), @intCast(c.h) };
    for (0..6) |k| if (mask >> @intCast(k) & 1 != 0) {
        const col = k % 2;
        const row = k / 2;
        c.fill(xs[col], ys[row], xs[col + 1], ys[row + 1], 255);
    };
}

/// Braille: a 2×4 grid of square dots, each centred in its sub-cell.
fn drawBraille(bits: u8, c: *Canvas) void {
    // Dot order: 1 2 3 left top-down, 4 5 6 right, then 7 left and 8 right
    // on the bottom row.
    const pos = [8][2]u32{ .{ 0, 0 }, .{ 0, 1 }, .{ 0, 2 }, .{ 1, 0 }, .{ 1, 1 }, .{ 1, 2 }, .{ 0, 3 }, .{ 1, 3 } };
    const sub_w = @as(f32, @floatFromInt(c.w)) / 2;
    const sub_h = @as(f32, @floatFromInt(c.h)) / 4;
    const dot: i32 = @max(1, @as(i32, @intFromFloat(@round(@min(sub_w, sub_h) / 2))));
    for (pos, 0..) |p, k| if (bits >> @intCast(k) & 1 != 0) {
        const cx = (@as(f32, @floatFromInt(p[0])) + 0.5) * sub_w;
        const cy = (@as(f32, @floatFromInt(p[1])) + 0.5) * sub_h;
        const x0: i32 = @intFromFloat(@round(cx - @as(f32, @floatFromInt(dot)) / 2));
        const y0: i32 = @intFromFloat(@round(cy - @as(f32, @floatFromInt(dot)) / 2));
        c.fill(x0, y0, x0 + dot, y0 + dot, 255);
    };
}

/// Powerline: solid triangles (E0B0 right-pointing, E0B2 left-pointing)
/// and thin chevrons (E0B1, E0B3).
fn drawPowerline(cp: u21, c: *Canvas, acc: *Accumulator, gpa: Allocator) Allocator.Error!void {
    const fw: f32 = @floatFromInt(c.w);
    const fh: f32 = @floatFromInt(c.h);
    switch (cp) {
        0xE0B0 => try fillPoly(c, acc, gpa, &.{ .{ 0, 0 }, .{ fw, fh / 2 }, .{ 0, fh } }),
        0xE0B2 => try fillPoly(c, acc, gpa, &.{ .{ fw, 0 }, .{ fw, fh }, .{ 0, fh / 2 } }),
        0xE0B1, 0xE0B3 => {
            const t = @as(f32, @floatFromInt(Lines.of(c).light));
            // Horizontal offset giving a perpendicular width of t.
            const d = t * @sqrt(fw * fw + fh * fh / 4) / fh;
            if (cp == 0xE0B1) {
                try fillPoly(c, acc, gpa, &.{ .{ -d, 0 }, .{ d, 0 }, .{ fw, fh / 2 }, .{ d, fh }, .{ -d, fh }, .{ fw - d * 2, fh / 2 } });
            } else {
                try fillPoly(c, acc, gpa, &.{ .{ fw - d, 0 }, .{ fw + d, 0 }, .{ d * 2, fh / 2 }, .{ fw + d, fh }, .{ fw - d, fh }, .{ 0, fh / 2 } });
            }
        },
        else => unreachable,
    }
}
