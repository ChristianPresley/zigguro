//! The last-resort glyph: what a code point no installed face maps is
//! drawn as, so text never shows blank tofu. A 1 px box inset by 1 px
//! with the code point's hex digits inside (4 digits as 2×2, 5–6 as
//! 2×3), the digits drawn from a built-in seven-segment stroke font
//! through the coverage rasterizer, so any size renders crisply.
//!
//! Glyph keys: the virtual instance `last_resort_instance` (0) with a
//! glyph id from `LastResortTable`: the code point itself below U+E000,
//! otherwise an interned id from U+E000 up (lock-free to read, so raster
//! workers can map ids back). The glyph is 1 em wide at the text size;
//! terminal cells scale it into their cells like any other glyph.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Accumulator = @import("../raster/coverage.zig").Accumulator;
const Bitmap = @import("../raster/rasterizer.zig").Bitmap;

pub const last_resort_instance = @import("registry.zig").last_resort_instance;

/// Glyph ids of last-resort code points.
pub const LastResortTable = struct {
    /// Code points of interned ids `first_interned + i`.
    cps: ?*[capacity]u32 = null,
    len: std.atomic.Value(u32) = .init(0),
    lock: std.atomic.Mutex = .unlocked,

    pub const first_interned: u16 = 0xE000;
    /// Ids 0xE000..0xFFFE; 0xFFFF stands for any code point past them.
    pub const capacity = 0xFFFF - first_interned;
    pub const overflow: u16 = 0xFFFF;

    pub fn deinit(t: *LastResortTable, gpa: Allocator) void {
        if (t.cps) |p| gpa.destroy(p);
        t.* = undefined;
    }

    /// The glyph id of `cp` (interning it when needed).
    pub fn glyph(t: *LastResortTable, gpa: Allocator, cp: u21) u16 {
        if (cp < first_interned) return @intCast(cp);
        const n = t.len.load(.acquire);
        if (t.cps) |p| for (p[0..n], 0..) |c, i| if (c == cp) return @intCast(first_interned + i);
        while (!t.lock.tryLock()) std.atomic.spinLoopHint();
        defer t.lock.unlock();
        const m = t.len.load(.monotonic);
        if (t.cps) |p| for (p[n..m], n..) |c, i| if (c == cp) return @intCast(first_interned + i);
        if (m >= capacity) return overflow;
        if (t.cps == null) t.cps = gpa.create([capacity]u32) catch return overflow;
        t.cps.?[m] = cp;
        t.len.store(m + 1, .release);
        return @intCast(first_interned + m);
    }

    /// The code point glyph id `g` stands for (U+FFFD for `overflow`).
    pub fn codepoint(t: *const LastResortTable, g: u16) u21 {
        if (g < first_interned) return g;
        const i = g - first_interned;
        if (g == overflow or i >= t.len.load(.acquire)) return 0xFFFD;
        return @intCast(t.cps.?[i]);
    }
};

/// Seven segments: a top, b top right, c bottom right, d bottom, e bottom
/// left, f top left, g middle.
const Seg = enum(u3) { a, b, c, d, e, f, g };

/// Segment bits (a = bit 0) of the hex digits 0–F.
const digits = [16]u7{
    0b0111111, 0b0000110, 0b1011011, 0b1001111, 0b1100110, 0b1101101, 0b1111101, 0b0000111,
    0b1111111, 0b1101111, 0b1110111, 0b1111100, 0b0111001, 0b1011110, 0b1111001, 0b1110001,
};

/// Endpoints of a segment on the 1×2 digit grid (y down).
fn ends(s: Seg) [2][2]f32 {
    return switch (s) {
        .a => .{ .{ 0, 0 }, .{ 1, 0 } },
        .b => .{ .{ 1, 0 }, .{ 1, 1 } },
        .c => .{ .{ 1, 1 }, .{ 1, 2 } },
        .d => .{ .{ 0, 2 }, .{ 1, 2 } },
        .e => .{ .{ 0, 1 }, .{ 0, 2 } },
        .f => .{ .{ 0, 0 }, .{ 0, 1 } },
        .g => .{ .{ 0, 1 }, .{ 1, 1 } },
    };
}

/// Draws the last-resort box for `cp` filling a `w`×`h` gray bitmap
/// (`out.pixels` is allocated from `gpa`; the caller frees it). The
/// bearings are left at 0; see `glyphBitmap` for text placement.
pub fn lastResortBitmap(cp: u21, w: u16, h: u16, out: *Bitmap, gpa: Allocator) Allocator.Error!void {
    const W: u32 = @max(w, 4);
    const H: u32 = @max(h, 6);
    const pixels = try gpa.alloc(u8, W * H);
    errdefer gpa.free(pixels);
    @memset(pixels, 0);
    out.* = .{ .width = @intCast(W), .height = @intCast(H), .stride = W, .format = .gray8, .pixels = pixels };
    // The 1 px frame, inset by 1 px.
    for (1..W - 1) |x| {
        pixels[1 * W + x] = 255;
        pixels[(H - 2) * W + x] = 255;
    }
    for (1..H - 1) |y| {
        pixels[y * W + 1] = 255;
        pixels[y * W + W - 2] = 255;
    }
    // Digits: two rows of two (BMP) or three, in the frame's interior
    // with a margin; each digit cell is u wide and 2u tall, with gaps of
    // u/2, all on whole pixels so strokes stay crisp.
    const n: u32 = if (cp > 0xFFFF) 6 else 4;
    const cols: u32 = n / 2;
    var hex: [6]u4 = undefined;
    for (0..n) |i| hex[i] = @truncate(cp >> @intCast(4 * (n - 1 - i)));
    const fw: f32 = @floatFromInt(W);
    const fh: f32 = @floatFromInt(H);
    const iw = fw - 6;
    const ih = fh - 6;
    if (iw < 3 or ih < 5) return;
    const fc: f32 = @floatFromInt(cols);
    const stroke = @max(1, @round(@min(iw / (fc + (fc - 1) * 0.5), ih / 4.5) * 0.2));
    // Stroke-inclusive digit size: u + stroke wide, 2u + stroke tall.
    const u = @max(1, @floor(@min((iw - fc * stroke) / (fc + (fc - 1) * 0.5), (ih - 2 * stroke) / 4.5)));
    const gap = @max(1, @round(u / 2));
    const block_w = fc * (u + stroke) + (fc - 1) * gap;
    const block_h = 2 * (2 * u + stroke) + gap;
    const gx = @round(3 + (iw - block_w) / 2);
    const gy = @round(3 + (ih - block_h) / 2);
    var acc: Accumulator = .{};
    defer acc.deinit(gpa);
    const tmp = try gpa.alloc(u8, W * H);
    defer gpa.free(tmp);
    try acc.reset(gpa, W, H);
    for (0..n) |i| {
        const row: f32 = @floatFromInt(i / cols);
        const col: f32 = @floatFromInt(i % cols);
        const ox = gx + col * (u + stroke + gap);
        const oy = gy + row * (2 * u + stroke + gap);
        const bits = digits[hex[i]];
        for (0..7) |si| {
            if (bits >> @intCast(si) & 1 == 0) continue;
            const e = ends(@enumFromInt(si));
            // Each segment's rectangle runs from its first grid point to
            // its second plus the stroke, so joins overlap.
            const x0 = ox + e[0][0] * u;
            const y0 = oy + e[0][1] * u;
            const x1 = ox + e[1][0] * u + stroke;
            const y1 = oy + e[1][1] * u + stroke;
            rect(&acc, x0, y0, x1, y1);
        }
    }
    acc.integrate(tmp, W);
    for (pixels, tmp) |*d, sv| d.* = @max(d.*, sv);
}

/// Adds an axis-aligned rectangle; overlapping rectangles add up, which
/// `integrate` clamps.
fn rect(acc: *Accumulator, x0: f32, y0: f32, x1: f32, y1: f32) void {
    acc.line(.{ x0, y0 }, .{ x1, y0 });
    acc.line(.{ x1, y0 }, .{ x1, y1 });
    acc.line(.{ x1, y1 }, .{ x0, y1 });
    acc.line(.{ x0, y1 }, .{ x0, y0 });
}

/// The last-resort glyph for text at `px` per em: 1 em wide (the advance
/// layout gives it), from 0.8 em above the baseline to 0.2 em below.
pub fn glyphBitmap(cp: u21, px: f32, out: *Bitmap, gpa: Allocator) Allocator.Error!void {
    const em: u16 = @intFromFloat(@max(6, @round(px)));
    try lastResortBitmap(cp, em, em, out, gpa);
    out.left = 0;
    out.top = -@as(i16, @intFromFloat(@round(@as(f32, @floatFromInt(em)) * 0.8)));
}
