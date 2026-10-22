//! `glyf` / `loca`: TrueType quadratic outlines, simple and composite.
//!
//! Points are decoded (and composites flattened) into a reusable `Scratch`
//! in font units, an optional `DeltaHook` moves them (gvar), and the
//! contours are emitted into a `Path`. Composites are flattened at the
//! point level so point-matching anchors can index every point emitted so
//! far. Contours are drawn the way fontTools pens draw them: each starts at
//! its first on-curve point (or, when it has none, at the midpoint of its
//! last and first points), and a closing straight segment is left to the
//! `close`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const reader = @import("reader.zig");
const Hmtx = @import("hmtx.zig").Hmtx;
const path_mod = @import("../outline/path.zig");
const Path = path_mod.Path;

const GlyphId = reader.GlyphId;

/// Maximum composite nesting depth.
pub const max_depth = 8;
/// Maximum components in one flattened composite.
pub const max_components = 512;
/// Maximum points in one flattened glyph.
pub const max_points = 65535;

const on_curve = 0x01;
const x_short = 0x02;
const y_short = 0x04;
const repeat = 0x08;
const x_same_or_pos = 0x10;
const y_same_or_pos = 0x20;

const arg_words = 0x0001;
const args_xy = 0x0002;
const have_scale = 0x0008;
const more_components = 0x0020;
const xy_scale = 0x0040;
const two_by_two = 0x0080;
const use_my_metrics = 0x0200;
const scaled_offset = 0x0800;
const unscaled_offset = 0x1000;

/// Reusable decode buffers; one per worker thread.
pub const Scratch = struct {
    points: std.ArrayList([2]f32) = .empty,
    /// Per point: bit 0 set when on-curve.
    flags: std.ArrayList(u8) = .empty,
    /// Absolute index of each contour's last point.
    ends: std.ArrayList(u16) = .empty,
    /// Stack of component offsets (plus phantoms) handed to the delta hook.
    comps: std.ArrayList([2]f32) = .empty,

    /// Frees the buffers.
    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.points.deinit(gpa);
        s.flags.deinit(gpa);
        s.ends.deinit(gpa);
        s.comps.deinit(gpa);
        s.* = .{};
    }

    fn reset(s: *Scratch) void {
        s.points.clearRetainingCapacity();
        s.flags.clearRetainingCapacity();
        s.ends.clearRetainingCapacity();
        s.comps.clearRetainingCapacity();
    }
};

/// Applies variation deltas. For a simple glyph `pts` holds its points
/// followed by 4 phantom points and `ends` its contour ends (relative to
/// `pts`); for a composite `pts` holds one offset per component followed by
/// the 4 phantoms, and `ends` is empty. Deltas for point-matched components
/// are ignored.
pub const DeltaHook = struct {
    ctx: *anyopaque,
    apply: *const fn (ctx: *anyopaque, gid: GlyphId, pts: [][2]f32, ends: []const u16, is_composite: bool) error{Malformed}!void,
};

/// What `outline` learned besides the path.
pub const Info = struct {
    /// The top-level glyph's phantom points after deltas, in the same
    /// space as the path (so the left one is at x = 0): left and right
    /// side, then top and bottom (zero without `vmtx`). The advance is
    /// `phantom[1][0]`.
    phantom: [4][2]f32,
    /// The component whose metrics the composite uses (USE_MY_METRICS).
    metrics_from: ?GlyphId = null,
};

/// A view of `glyf` and `loca`.
pub const Glyf = struct {
    glyf: []const u8,
    loca: []const u8,
    loca_long: bool,
    num_glyphs: u16,
    /// Source of the horizontal phantom points; without it they are zero.
    /// The vertical ones are always zero (no `vmtx` support), as in
    /// fontTools.
    hmtx: ?Hmtx = null,

    /// Checks that `loca` holds `num_glyphs + 1` entries.
    pub fn init(glyf: []const u8, loca: []const u8, loca_long: bool, num_glyphs: u16) error{Malformed}!Glyf {
        const entry: usize = if (loca_long) 4 else 2;
        if (loca.len < (@as(usize, num_glyphs) + 1) * entry) return error.Malformed;
        return .{ .glyf = glyf, .loca = loca, .loca_long = loca_long, .num_glyphs = num_glyphs };
    }

    fn locaAt(g: *const Glyf, i: usize) u32 {
        // In range: checked by `init`.
        if (g.loca_long) return std.mem.readInt(u32, g.loca[i * 4 ..][0..4], .big);
        return @as(u32, std.mem.readInt(u16, g.loca[i * 2 ..][0..2], .big)) * 2;
    }

    /// The glyph's bytes; empty for a glyph without outline.
    pub fn glyphData(g: *const Glyf, gid: GlyphId) error{Malformed}![]const u8 {
        if (gid >= g.num_glyphs) return error.Malformed;
        const a = g.locaAt(gid);
        const b = g.locaAt(@as(usize, gid) + 1);
        if (a > b or b > g.glyf.len) return error.Malformed;
        if (b - a != 0 and b - a < 10) return error.Malformed;
        return g.glyf[a..b];
    }

    /// The glyph's header bounding box, or null for an empty glyph.
    pub fn headerBounds(g: *const Glyf, gid: GlyphId) error{Malformed}!?path_mod.Rect {
        const d = try g.glyphData(gid);
        if (d.len == 0) return null;
        return .{
            .x0 = @floatFromInt(try reader.readAt(i16, d, 2)),
            .y0 = @floatFromInt(try reader.readAt(i16, d, 4)),
            .x1 = @floatFromInt(try reader.readAt(i16, d, 6)),
            .y1 = @floatFromInt(try reader.readAt(i16, d, 8)),
        };
    }

    /// Decodes glyph `gid` (flattening composites) into `scratch`, lets
    /// `deltas` move the points, and appends the contours to `out`.
    pub fn outline(g: *const Glyf, gpa: Allocator, gid: GlyphId, scratch: *Scratch, deltas: ?DeltaHook, out: *Path) error{ Malformed, OutOfMemory, LimitExceeded }!Info {
        scratch.reset();
        var st: State = .{ .g = g, .gpa = gpa, .s = scratch, .deltas = deltas };
        var info: Info = .{ .phantom = undefined };
        try st.load(gid, 0, &info.phantom, &info.metrics_from);
        // The origin is the left phantom point: when hmtx's lsb differs
        // from xMin (or deltas moved it) the outline shifts, as in
        // FreeType, HarfBuzz and fontTools.
        const shift = info.phantom[0][0];
        if (shift != 0) {
            for (scratch.points.items) |*p| p[0] -= shift;
            for (&info.phantom) |*p| p[0] -= shift;
        }
        try emit(gpa, scratch, out);
        return info;
    }
};

const State = struct {
    g: *const Glyf,
    gpa: Allocator,
    s: *Scratch,
    deltas: ?DeltaHook,
    stack: [max_depth + 1]GlyphId = undefined,
    components: u32 = 0,

    fn phantoms(st: *const State, gid: GlyphId, x_min: i16) [4][2]f32 {
        const m = st.g.hmtx orelse return @splat(.{ 0, 0 });
        const lsb: f32 = @floatFromInt(m.lsb(gid));
        const adv: f32 = @floatFromInt(m.advance(gid));
        const left = @as(f32, @floatFromInt(x_min)) - lsb;
        return .{ .{ left, 0 }, .{ left + adv, 0 }, .{ 0, 0 }, .{ 0, 0 } };
    }

    /// Appends the points of `gid` to the scratch buffers.
    fn load(st: *State, gid: GlyphId, depth: u8, phantom: *[4][2]f32, metrics_from: *?GlyphId) error{ Malformed, OutOfMemory, LimitExceeded }!void {
        if (depth > max_depth) return error.LimitExceeded;
        for (st.stack[0..depth]) |anc| if (anc == gid) return error.LimitExceeded;
        st.stack[depth] = gid;
        const d = try st.g.glyphData(gid);
        if (d.len == 0) {
            phantom.* = st.phantoms(gid, 0);
            try st.emptyDeltas(gid, phantom);
            return;
        }
        const n_contours = try reader.readAt(i16, d, 0);
        const x_min = try reader.readAt(i16, d, 2);
        phantom.* = st.phantoms(gid, x_min);
        if (n_contours >= 0) return st.loadSimple(gid, d, @intCast(n_contours), phantom);
        return st.loadComposite(gid, d, depth, phantom, metrics_from);
    }

    /// Lets the hook move the phantom points of an empty glyph.
    fn emptyDeltas(st: *State, gid: GlyphId, phantom: *[4][2]f32) !void {
        const h = st.deltas orelse return;
        try h.apply(h.ctx, gid, phantom, &.{}, false);
    }

    fn loadSimple(st: *State, gid: GlyphId, d: []const u8, n_contours: u16, phantom: *[4][2]f32) !void {
        const s = st.s;
        const base = s.points.items.len;
        var r = try reader.Reader.at(d, 10);
        // Contour ends, relative to this glyph.
        const ends_at = s.ends.items.len;
        try s.ends.ensureUnusedCapacity(st.gpa, n_contours);
        var n_points: usize = 0;
        for (0..n_contours) |i| {
            const e = try r.u16_();
            if (i > 0 and e < s.ends.items[s.ends.items.len - 1]) return error.Malformed;
            if (i > 0 and e == s.ends.items[s.ends.items.len - 1]) return error.Malformed;
            s.ends.appendAssumeCapacity(e);
            n_points = @as(usize, e) + 1;
        }
        if (base + n_points > max_points) return error.LimitExceeded;
        try r.skip(try r.u16_()); // instructions
        // Flags.
        try s.flags.ensureUnusedCapacity(st.gpa, n_points);
        try s.points.ensureUnusedCapacity(st.gpa, n_points + 4);
        const flags_at = s.flags.items.len;
        while (s.flags.items.len - flags_at < n_points) {
            const f = try r.u8_();
            s.flags.appendAssumeCapacity(f);
            if (f & repeat != 0) {
                const n = try r.u8_();
                if (s.flags.items.len - flags_at + n > n_points) return error.Malformed;
                s.flags.appendNTimesAssumeCapacity(f, n);
            }
        }
        const flags = s.flags.items[flags_at..];
        // Coordinates: all x, then all y.
        s.points.items.len += n_points;
        const pts = s.points.items[base..];
        var v: i32 = 0;
        for (flags, 0..) |f, i| {
            if (f & x_short != 0) {
                const dx = try r.u8_();
                v += if (f & x_same_or_pos != 0) @as(i32, dx) else -@as(i32, dx);
            } else if (f & x_same_or_pos == 0) v += try r.i16_();
            pts[i][0] = @floatFromInt(v);
        }
        v = 0;
        for (flags, 0..) |f, i| {
            if (f & y_short != 0) {
                const dy = try r.u8_();
                v += if (f & y_same_or_pos != 0) @as(i32, dy) else -@as(i32, dy);
            } else if (f & y_same_or_pos == 0) v += try r.i16_();
            pts[i][1] = @floatFromInt(v);
        }
        for (flags) |*f| f.* &= on_curve;
        if (st.deltas) |h| {
            s.points.appendSliceAssumeCapacity(phantom);
            const all = s.points.items[base..];
            try h.apply(h.ctx, gid, all, s.ends.items[ends_at..], false);
            phantom.* = all[n_points..][0..4].*;
            s.points.items.len -= 4;
        }
        // Make the ends absolute.
        if (base != 0) for (s.ends.items[ends_at..]) |*e| {
            e.* += @intCast(base);
        };
    }

    fn loadComposite(st: *State, gid: GlyphId, d: []const u8, depth: u8, phantom: *[4][2]f32, metrics_from: *?GlyphId) !void {
        const s = st.s;
        // First pass: component offsets for the delta hook.
        const comps_at = s.comps.items.len;
        defer s.comps.items.len = comps_at;
        var r = try reader.Reader.at(d, 10);
        while (true) {
            st.components += 1;
            if (st.components > max_components) return error.LimitExceeded;
            const c = try readComponent(&r);
            const off: [2]f32 = if (c.flags & args_xy != 0) .{ @floatFromInt(c.arg1), @floatFromInt(c.arg2) } else .{ 0, 0 };
            try s.comps.append(st.gpa, off);
            if (c.flags & more_components == 0) break;
        }
        const n_comps = s.comps.items.len - comps_at;
        if (st.deltas) |h| {
            try s.comps.appendSlice(st.gpa, phantom);
            const all = s.comps.items[comps_at..];
            try h.apply(h.ctx, gid, all, &.{}, true);
            phantom.* = all[n_comps..][0..4].*;
        }
        // Second pass: load and place each component.
        const base = s.points.items.len;
        r = try reader.Reader.at(d, 10);
        for (0..n_comps) |k| {
            const c = try readComponent(&r);
            const start = s.points.items.len;
            var child_phantom: [4][2]f32 = undefined;
            var child_metrics: ?GlyphId = null;
            try st.load(c.glyph, depth + 1, &child_phantom, &child_metrics);
            if (c.flags & use_my_metrics != 0) {
                metrics_from.* = c.glyph;
                // The composite takes the component's horizontal phantoms.
                phantom[0][0] = child_phantom[0][0];
                phantom[1][0] = child_phantom[1][0];
            }
            const child = s.points.items[start..];
            const m = c.m;
            if (!(m[0] == 1 and m[1] == 0 and m[2] == 0 and m[3] == 1)) {
                for (child) |*p| {
                    const q = p.*; // copy: the literal below would alias p
                    p.* = .{ m[0] * q[0] + m[2] * q[1], m[1] * q[0] + m[3] * q[1] };
                }
            }
            var off: [2]f32 = undefined;
            if (c.flags & args_xy != 0) {
                off = s.comps.items[comps_at + k];
                if (c.flags & scaled_offset != 0 and c.flags & unscaled_offset == 0) {
                    const o = off;
                    off = .{ m[0] * o[0] + m[2] * o[1], m[1] * o[0] + m[3] * o[1] };
                }
            } else {
                // Point matching: parent point arg1 meets child point arg2.
                const p1: usize = @intCast(c.arg1);
                const p2: usize = @intCast(c.arg2);
                if (base + p1 >= start or p2 >= child.len) return error.Malformed;
                const a = s.points.items[base + p1];
                const b = child[p2];
                off = .{ a[0] - b[0], a[1] - b[1] };
            }
            if (off[0] != 0 or off[1] != 0) for (child) |*p| {
                p[0] += off[0];
                p[1] += off[1];
            };
        }
    }
};

const Component = struct {
    flags: u16,
    glyph: GlyphId,
    arg1: i32,
    arg2: i32,
    /// 2x2 matrix as stored: xscale, scale01, scale10, yscale;
    /// x' = m0*x + m2*y, y' = m1*x + m3*y.
    m: [4]f32,
};

fn f2dot14(r: *reader.Reader) !f32 {
    return @as(f32, @floatFromInt(try r.i16_())) / 16384.0;
}

fn readComponent(r: *reader.Reader) !Component {
    const flags = try r.u16_();
    const glyph = try r.u16_();
    var c: Component = .{ .flags = flags, .glyph = glyph, .arg1 = 0, .arg2 = 0, .m = .{ 1, 0, 0, 1 } };
    const xy = flags & args_xy != 0;
    if (flags & arg_words != 0) {
        c.arg1 = if (xy) try r.i16_() else try r.u16_();
        c.arg2 = if (xy) try r.i16_() else try r.u16_();
    } else {
        c.arg1 = if (xy) try r.i8_() else try r.u8_();
        c.arg2 = if (xy) try r.i8_() else try r.u8_();
    }
    if (flags & have_scale != 0) {
        const sc = try f2dot14(r);
        c.m = .{ sc, 0, 0, sc };
    } else if (flags & xy_scale != 0) {
        c.m[0] = try f2dot14(r);
        c.m[3] = try f2dot14(r);
    } else if (flags & two_by_two != 0) {
        for (&c.m) |*v| v.* = try f2dot14(r);
    }
    return c;
}

inline fn mid(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
}

/// Emits every contour of `s` into `out` as lines and quads.
fn emit(gpa: Allocator, s: *const Scratch, out: *Path) Allocator.Error!void {
    const pts = s.points.items;
    const flags = s.flags.items;
    // Worst case per contour of n points: move + n segments + close, and
    // 2 points per segment.
    try out.ensureUnused(gpa, pts.len + 2 * s.ends.items.len, 2 * pts.len + s.ends.items.len);
    var first: usize = 0;
    for (s.ends.items) |e| {
        const last: usize = e;
        defer first = last + 1;
        if (last < first) continue;
        const n = last - first + 1;
        const c = pts[first..][0..n];
        const f = flags[first..][0..n];
        // Start at the first on-curve point, else at the midpoint of the
        // last and first points.
        var k: usize = 0;
        while (k < n and f[k] == 0) k += 1;
        var start: [2]f32 = undefined;
        if (k < n) {
            start = c[k];
        } else {
            start = mid(c[n - 1], c[0]);
            k = n - 1; // the walk below then visits c[0..n]
        }
        out.moveToAssume(start[0], start[1]);
        // Visit the n points after `k` cyclically; with an on-curve start
        // the last one is the start itself, which closes the contour.
        var ctrl: ?[2]f32 = null;
        for (1..n + 1) |step| {
            const i = (k + step) % n;
            const p = c[i];
            if (f[i] != 0) {
                if (ctrl) |q| {
                    out.quadToAssume(q[0], q[1], p[0], p[1]);
                } else if (step != n) {
                    out.lineToAssume(p[0], p[1]);
                }
                ctrl = null;
            } else {
                if (ctrl) |q| {
                    const m = mid(q, p);
                    out.quadToAssume(q[0], q[1], m[0], m[1]);
                }
                ctrl = p;
            }
        }
        // Close back to the start (only pending when the start was implied
        // or the last point before the start was off-curve).
        if (ctrl) |q| out.quadToAssume(q[0], q[1], start[0], start[1]);
        out.closeAssume();
    }
}

test {
    _ = @import("glyf_test.zig");
}
