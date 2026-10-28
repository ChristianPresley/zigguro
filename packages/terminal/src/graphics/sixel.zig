//! Sixel images (E06.F08.S01.T02): `DCS P1 ; P2 ; P3 q <data> ST`,
//! decoded as it streams in into premultiplied RGBA and placed through
//! the image store like a kitty image.
//!
//! Data bytes `?`..`~` paint six pixels in a column (bit 0 at the top) in
//! the current colour; `!n` repeats the next one `n` times, `$` returns to
//! the left edge, `-` moves down six rows, `#c` picks colour register `c`
//! and `#c;u;x;y;z` defines it (u = 1: HLS, hue 0 at blue as DEC has it;
//! u = 2: RGB in percent). `"a;b;w;h` (raster attributes) gives the pixel
//! aspect ratio (a:b, applied as a whole number of rows per sixel row)
//! and the image's least size. P1's legacy aspect ratio is ignored, as xterm and
//! most current terminals do; P2 = 1 leaves unpainted pixels
//! transparent, otherwise they take register 0's colour.
//!
//! The canvas grows as the image does, up to `max_w` x `max_h`; anything
//! beyond is clipped.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The VT340's 16 colours (RGB percent); registers 16+ start black.
const vt340 = [16][3]u8{
    .{ 0, 0, 0 },    .{ 20, 20, 80 }, .{ 80, 13, 13 }, .{ 20, 80, 20 },
    .{ 80, 20, 80 }, .{ 20, 80, 80 }, .{ 80, 80, 20 }, .{ 53, 53, 53 },
    .{ 26, 26, 26 }, .{ 33, 33, 60 }, .{ 60, 26, 26 }, .{ 33, 60, 33 },
    .{ 60, 33, 60 }, .{ 33, 60, 60 }, .{ 60, 60, 33 }, .{ 80, 80, 80 },
};

pub const Image = struct { w: u32, h: u32, rgba: []u8 };

pub const SixelDecoder = struct {
    gpa: Allocator,
    transparent: bool,
    max_w: u32,
    max_h: u32,
    /// RGBA (opaque), one per register.
    regs: [256][4]u8,
    color: [4]u8,
    /// The canvas: `cap_w * cap_h` pixels; `w`/`h` is what was painted.
    buf: []u8 = &.{},
    cap_w: u32 = 0,
    cap_h: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    x: u32 = 0,
    /// The top pixel row of the current band.
    y: u32 = 0,
    /// Pixel rows per sixel row (the aspect ratio).
    rep_y: u32 = 1,
    state: enum { data, repeat, color, raster } = .data,
    params: [5]u32 = @splat(0),
    nparams: u8 = 0,
    failed: bool = false,
    /// Data has been painted (raster attributes after it are ignored).
    started: bool = false,
    /// Raster attributes gave the size; the image is then that size
    /// (or what was painted beyond it), not whole bands.
    declared: bool = false,
    /// The last pixel row a set bit painted, plus one.
    painted_h: u32 = 0,

    pub fn init(gpa: Allocator, p2: u16, max_w: u32, max_h: u32) SixelDecoder {
        var d: SixelDecoder = .{ .gpa = gpa, .transparent = p2 == 1, .max_w = max_w, .max_h = max_h, .regs = undefined, .color = undefined };
        for (&d.regs, 0..) |*r, i| r.* = if (i < 16) pct(vt340[i][0], vt340[i][1], vt340[i][2]) else .{ 0, 0, 0, 255 };
        d.color = d.regs[0];
        return d;
    }

    pub fn deinit(d: *SixelDecoder) void {
        d.gpa.free(d.buf);
        d.buf = &.{};
    }

    fn pct(r: u32, g: u32, b: u32) [4]u8 {
        return .{ pctByte(r), pctByte(g), pctByte(b), 255 };
    }

    fn pctByte(v: u32) u8 {
        return @intCast((@as(u32, @min(v, 100)) * 255 + 50) / 100);
    }

    /// DEC HLS (hue 0 = blue, 120 = red, 240 = green; L and S in percent).
    fn hls(h: u32, l: u32, s: u32) [4]u8 {
        const hue = @as(f32, @floatFromInt((h + 240) % 360)) / 60.0;
        const lf = @as(f32, @floatFromInt(@min(l, 100))) / 100.0;
        const sf = @as(f32, @floatFromInt(@min(s, 100))) / 100.0;
        const c = (1 - @abs(2 * lf - 1)) * sf;
        const x = c * (1 - @abs(@mod(hue, 2) - 1));
        const m = lf - c / 2;
        const rgb: [3]f32 = switch (@as(u32, @intFromFloat(hue))) {
            0 => .{ c, x, 0 },
            1 => .{ x, c, 0 },
            2 => .{ 0, c, x },
            3 => .{ 0, x, c },
            4 => .{ x, 0, c },
            else => .{ c, 0, x },
        };
        var out: [4]u8 = .{ 0, 0, 0, 255 };
        for (0..3) |i| out[i] = @intFromFloat(@round(std.math.clamp(rgb[i] + m, 0, 1) * 255));
        return out;
    }

    /// Decodes more of the stream.
    pub fn put(d: *SixelDecoder, bytes: []const u8) void {
        for (bytes) |b| d.byte(b);
    }

    fn byte(d: *SixelDecoder, b: u8) void {
        switch (d.state) {
            .data => {},
            .repeat, .color, .raster => {
                if (b >= '0' and b <= '9') {
                    const i = d.nparams -| 1;
                    if (d.nparams == 0) d.nparams = 1;
                    d.params[i] = @min(d.params[i] *| 10 +| (b - '0'), 1 << 24);
                    return;
                }
                if (b == ';') {
                    if (d.nparams == 0) d.nparams = 1;
                    if (d.nparams < d.params.len) {
                        d.params[d.nparams] = 0;
                        d.nparams += 1;
                    }
                    return;
                }
                d.endParams();
            },
        }
        switch (b) {
            '?'...'~' => {
                const n = if (d.state == .repeat) @max(d.params[0], 1) else 1;
                d.state = .data;
                d.sixel(b - '?', n);
            },
            '!' => d.begin(.repeat),
            '#' => d.begin(.color),
            '"' => d.begin(.raster),
            '$' => d.x = 0,
            '-' => {
                d.x = 0;
                d.y +|= 6 * d.rep_y;
            },
            else => {},
        }
    }

    fn begin(d: *SixelDecoder, s: @TypeOf(d.state)) void {
        d.state = s;
        d.params = @splat(0);
        d.nparams = 0;
    }

    /// A parameter list ended (at any byte that is not a digit or `;`).
    fn endParams(d: *SixelDecoder) void {
        const p = d.params;
        switch (d.state) {
            .color => {
                const reg = p[0] & 0xff;
                if (d.nparams >= 5) {
                    d.regs[reg] = switch (p[1]) {
                        1 => hls(p[2], p[3], p[4]),
                        2 => pct(p[2], p[3], p[4]),
                        else => d.regs[reg],
                    };
                }
                d.color = d.regs[reg];
            },
            .raster => if (!d.started) {
                if (p[0] > 0 and p[1] > 0) d.rep_y = std.math.clamp((p[0] + p[1] / 2) / p[1], 1, 16);
                // The declared size is the image's least size.
                if (d.nparams >= 4) {
                    d.reserve(p[2], p[3]);
                    if (!d.failed) {
                        d.w = @min(p[2], d.cap_w);
                        d.h = @min(p[3], d.cap_h);
                        d.declared = true;
                    }
                }
            },
            .repeat, .data => {},
        }
        if (d.state != .repeat) d.state = .data;
    }

    /// Grows the canvas to at least `w` x `h` (clamped to the maximum).
    fn reserve(d: *SixelDecoder, want_w: u32, want_h: u32) void {
        if (d.failed) return;
        const w = @min(want_w, d.max_w);
        const h = @min(want_h, d.max_h);
        if (w <= d.cap_w and h <= d.cap_h) return;
        const nw = if (w > d.cap_w) @min(d.max_w, @max(w, d.cap_w * 2, 64)) else d.cap_w;
        const nh = if (h > d.cap_h) @min(d.max_h, @max(h, d.cap_h * 2, 60)) else d.cap_h;
        const nb = d.gpa.alloc(u8, @as(usize, nw) * nh * 4) catch {
            d.failed = true;
            return;
        };
        @memset(nb, 0);
        for (0..d.cap_h) |y| @memcpy(nb[y * nw * 4 ..][0 .. d.cap_w * 4], d.buf[y * d.cap_w * 4 ..][0 .. d.cap_w * 4]);
        d.gpa.free(d.buf);
        d.buf = nb;
        d.cap_w = nw;
        d.cap_h = nh;
    }

    fn sixel(d: *SixelDecoder, bits: u8, n: u32) void {
        d.started = true;
        const x0 = d.x;
        d.x +|= n;
        if (bits == 0 or x0 >= d.max_w or d.y >= d.max_h) return;
        const x1 = @min(d.x, d.max_w);
        const y1 = @min(d.y + 6 * d.rep_y, d.max_h);
        d.reserve(x1, y1);
        if (d.failed) return;
        const x_end = @min(x1, d.cap_w);
        var bit: u3 = 0;
        while (bit < 6) : (bit += 1) {
            if (bits & (@as(u8, 1) << bit) == 0) continue;
            var r: u32 = 0;
            while (r < d.rep_y) : (r += 1) {
                const y = d.y + @as(u32, bit) * d.rep_y + r;
                if (y >= d.cap_h) break;
                const row = d.buf[(@as(usize, y) * d.cap_w) * 4 ..];
                var x = x0;
                while (x < x_end) : (x += 1) @memcpy(row[x * 4 ..][0..4], &d.color);
                d.painted_h = @max(d.painted_h, y + 1);
            }
        }
        // Without a declared size the image is at least as tall as the
        // band painted in.
        d.h = @max(d.h, if (d.declared) d.painted_h else @min(y1, d.cap_h));
        d.w = @max(d.w, x_end);
    }

    /// The image (owned by the caller), or null when nothing was painted
    /// or memory ran out.
    pub fn finish(d: *SixelDecoder) ?Image {
        if (d.state != .data) d.endParams();
        if (d.failed or d.w == 0 or d.h == 0) return null;
        const out = d.gpa.alloc(u8, @as(usize, d.w) * d.h * 4) catch return null;
        const bg = d.regs[0];
        for (0..d.h) |y| {
            const src = d.buf[y * d.cap_w * 4 ..][0 .. d.w * 4];
            const dst = out[y * d.w * 4 ..][0 .. d.w * 4];
            @memcpy(dst, src);
            if (!d.transparent) {
                var i: usize = 0;
                while (i < dst.len) : (i += 4) if (dst[i + 3] == 0) @memcpy(dst[i..][0..4], &bg);
            }
        }
        return .{ .w = d.w, .h = d.h, .rgba = out };
    }
};

// ---------------------------------------------------------------------------
// The terminal side: `DCS ... q` routed here by `term/dcs.zig`.

const Terminal = @import("../term/Terminal.zig");
const store_mod = @import("store.zig");

/// Starts decoding (`p2` is the DCS's second parameter); false when
/// sixel is turned off or memory ran out.
pub fn hook(t: *Terminal, p2: u16) bool {
    if (!t.opts.graphics.sixel) return false;
    const side: u32 = @intCast(std.math.sqrt(t.opts.graphics.max_image_bytes / 4));
    const d = t.gpa.create(SixelDecoder) catch return false;
    d.* = .init(t.gpa, p2, @min(side, 8192), @min(side, 8192));
    t.sixel = d;
    return true;
}

pub fn put(t: *Terminal, bytes: []const u8) void {
    if (t.sixel) |d| d.put(bytes);
}

/// Places the decoded image: at the cursor, which then moves to the start
/// of the row below it (scrolling as needed), or with sixel display mode
/// (DECSDM) at the top-left corner, clipped to the screen, the cursor
/// left alone.
pub fn unhook(t: *Terminal) void {
    const d = t.sixel orelse return;
    t.sixel = null;
    defer {
        d.deinit();
        t.gpa.destroy(d);
    }
    const img = d.finish() orelse return;
    const px = store_mod.Pixels.create(t.gpa, img.w, img.h, img.rgba) catch {
        t.gpa.free(img.rgba);
        return;
    };
    const lists = t.imageLists();
    const id = t.images.autoId();
    t.images.quota = t.opts.graphics.quota;
    t.images.put(lists, id, 0, px) catch {
        px.release();
        return;
    };
    t.images.get(id).?.transient = true;
    const cw: u32 = if (t.cell_px.w > 0) t.cell_px.w else 10;
    const ch: u32 = if (t.cell_px.h > 0) t.cell_px.h else 20;
    const s = t.screen();
    const sdm = t.modes.get(.sixel_display);
    const cols: u32 = (img.w + cw - 1) / cw;
    var rows: u32 = (img.h + ch - 1) / ch;
    var ph = img.h;
    if (sdm) {
        rows = @min(rows, s.height());
        ph = @min(ph, rows * ch);
    }
    var pin = if (sdm) s.rowPin(0) else s.rowPin(s.cursor.y);
    pin.x = if (sdm) 0 else s.cursor.x;
    const start_x = pin.x;
    const tp = s.pages.track(pin) catch return t.images.removeImage(lists, id);
    t.images.place(lists, .{
        .image_id = id,
        .screen = if (t.alt_active) .alternate else .primary,
        .pin = tp,
        .cols = @intCast(@min(cols, std.math.maxInt(u16))),
        .rows = @intCast(@min(rows, std.math.maxInt(u16))),
        .src_w = img.w,
        .src_h = ph,
        .px_w = img.w,
        .px_h = ph,
    }) catch return t.images.removeImage(lists, id);
    if (sdm) return;
    var n = rows;
    while (n > 0) : (n -= 1) t.lineFeedNoCr();
    s.cursor.x = start_x;
    s.cursor.pending_wrap = false;
}
