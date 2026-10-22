//! `gvar`: TrueType glyph variations. Tuple deltas (shared, embedded or
//! intermediate regions; shared or private packed point numbers; packed
//! deltas) are accumulated per tuple, inferred for unreferenced points by
//! IUP on the default coordinates (simple glyphs only), scaled, summed and
//! added to the glyph's points through `glyf.DeltaHook`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const reader = @import("../reader.zig");
const glyf = @import("../glyf.zig");
const ivs = @import("ivs.zig");

const GlyphId = reader.GlyphId;
const VarCoords = ivs.VarCoords;

const shared_point_numbers = 0x8000;
const count_mask = 0x0FFF;
const embedded_peak = 0x8000;
const intermediate_region = 0x4000;
const private_point_numbers = 0x2000;
const tuple_index_mask = 0x0FFF;

/// Per-thread buffers; reused across glyphs. Bound to a table and an
/// instance by `Gvar.hook`.
pub const GvarScratch = struct {
    /// Accumulated deltas over all tuples.
    deltas: std.ArrayList([2]f32) = .empty,
    /// One tuple's deltas before scaling.
    tuple: std.ArrayList([2]f32) = .empty,
    touched: std.ArrayList(bool) = .empty,
    point_nums: std.ArrayList(u16) = .empty,
    shared_nums: std.ArrayList(u16) = .empty,
    /// Unpacked x then y deltas of one tuple.
    raw: std.ArrayList(f32) = .empty,
    gpa: Allocator = undefined,
    gvar: *const Gvar = undefined,
    coords: VarCoords = &.{},

    /// Frees the buffers.
    pub fn deinit(s: *GvarScratch, gpa: Allocator) void {
        s.deltas.deinit(gpa);
        s.tuple.deinit(gpa);
        s.touched.deinit(gpa);
        s.point_nums.deinit(gpa);
        s.shared_nums.deinit(gpa);
        s.raw.deinit(gpa);
        s.* = .{};
    }
};

/// A packed point-number list: either every point, or the numbers in
/// `nums`.
pub const Points = struct { all: bool, nums: []const u16 };

/// A view of `gvar`.
pub const Gvar = struct {
    data: []const u8,
    axis_count: u16,
    shared_tuples: []const u8,
    glyph_count: u16,
    long_offsets: bool,
    array_off: u32,

    /// Validates the header, the shared tuples and the offset array.
    /// `axis_count` must match fvar.
    pub fn init(table: []const u8, axis_count: u16, num_glyphs: u16) error{Malformed}!Gvar {
        var r = try reader.Reader.at(table, 0);
        if (try r.u16_() != 1) return error.Malformed;
        _ = try r.u16_();
        const axes = try r.u16_();
        if (axes != axis_count) return error.Malformed;
        const n_shared = try r.u16_();
        const shared_off = try r.u32_();
        const count = try r.u16_();
        const flags = try r.u16_();
        const array_off = try r.u32_();
        const long = flags & 1 != 0;
        const glyphs = @min(count, num_glyphs);
        _ = try reader.subLen(table, 20, (@as(usize, count) + 1) * @as(usize, if (long) 4 else 2));
        return .{
            .data = table,
            .axis_count = axes,
            .shared_tuples = try reader.subLen(table, shared_off, @as(usize, n_shared) * axes * 2),
            .glyph_count = glyphs,
            .long_offsets = long,
            .array_off = array_off,
        };
    }

    fn offsetAt(g: *const Gvar, i: usize) u32 {
        // In range: checked by `init`.
        if (g.long_offsets) return std.mem.readInt(u32, g.data[20 + i * 4 ..][0..4], .big);
        return @as(u32, std.mem.readInt(u16, g.data[20 + i * 2 ..][0..2], .big)) * 2;
    }

    /// The glyph's variation data; empty when it has none.
    pub fn glyphData(g: *const Gvar, gid: GlyphId) error{Malformed}![]const u8 {
        if (gid >= g.glyph_count) return &.{};
        const a = g.offsetAt(gid);
        const b = g.offsetAt(@as(usize, gid) + 1);
        if (a > b) return error.Malformed;
        if (a == b) return &.{};
        return reader.subLen(g.data, @as(usize, g.array_off) + a, b - a);
    }

    /// A `glyf.DeltaHook` applying this table at `coords`, using `scratch`
    /// (which must outlive the hook's use).
    pub fn hook(g: *const Gvar, gpa: Allocator, coords: VarCoords, scratch: *GvarScratch) glyf.DeltaHook {
        scratch.gpa = gpa;
        scratch.gvar = g;
        scratch.coords = coords;
        return .{ .ctx = scratch, .apply = hookApply };
    }

    fn hookApply(ctx: *anyopaque, gid: GlyphId, pts: [][2]f32, ends: []const u16, is_composite: bool) error{ Malformed, OutOfMemory }!void {
        const s: *GvarScratch = @ptrCast(@alignCast(ctx));
        return s.gvar.apply(s.gpa, gid, s.coords, pts, ends, is_composite, s);
    }

    /// Adds the deltas at `coords` to `pts` (the glyph's points, or one
    /// offset per component, followed by 4 phantom points).
    pub fn apply(g: *const Gvar, gpa: Allocator, gid: GlyphId, coords: VarCoords, pts: [][2]f32, ends: []const u16, is_composite: bool, s: *GvarScratch) error{ Malformed, OutOfMemory }!void {
        if (isDefault(coords)) return;
        const gvd = try g.glyphData(gid);
        if (gvd.len == 0) return;
        const n = pts.len;
        var it = try TupleIterator.init(g, gvd, coords);
        if (it.shared) |sp| {
            s.shared_nums.clearRetainingCapacity();
            var r = sp;
            it.shared_points = try decodePoints(gpa, &r, &s.shared_nums);
            it.body_start = r.pos;
        }
        try s.deltas.resize(gpa, n);
        @memset(s.deltas.items, .{ 0, 0 });
        var any = false;
        while (try it.next()) |t| {
            var r = t.data;
            var points: Points = undefined;
            if (t.private) {
                s.point_nums.clearRetainingCapacity();
                points = try decodePoints(gpa, &r, &s.point_nums);
            } else points = it.shared_points orelse return error.Malformed;
            const count = if (points.all) n else points.nums.len;
            try s.raw.resize(gpa, 2 * count);
            try decodeDeltas(&r, s.raw.items);
            const dx = s.raw.items[0..count];
            const dy = s.raw.items[count..];
            any = true;
            if (points.all) {
                for (s.deltas.items, dx, dy) |*d, x, y| {
                    d[0] += t.scalar * x;
                    d[1] += t.scalar * y;
                }
                continue;
            }
            try s.tuple.resize(gpa, n);
            try s.touched.resize(gpa, n);
            @memset(s.tuple.items, .{ 0, 0 });
            @memset(s.touched.items, false);
            for (points.nums, dx, dy) |p, x, y| {
                if (p >= n) continue;
                s.tuple.items[p] = .{ x, y };
                s.touched.items[p] = true;
            }
            if (!is_composite) {
                var start: usize = 0;
                for (ends) |e| {
                    if (e >= n) return error.Malformed;
                    iupContour(pts, s.tuple.items, s.touched.items, start, e);
                    start = @as(usize, e) + 1;
                }
            }
            for (s.deltas.items, s.tuple.items) |*d, x| {
                d[0] += t.scalar * x[0];
                d[1] += t.scalar * x[1];
            }
        }
        if (!any) return;
        for (pts, s.deltas.items) |*p, d| {
            p[0] += d[0];
            p[1] += d[1];
        }
    }

    /// The deltas of the 4 phantom points of a glyph with `n_points`
    /// points (or components), without decoding the outline. Used for
    /// advances when the face has no HVAR. Allocation-free.
    pub fn phantomDeltas(g: *const Gvar, gid: GlyphId, coords: VarCoords, n_points: usize) error{Malformed}![4][2]f32 {
        var out: [4][2]f32 = @splat(.{ 0, 0 });
        if (isDefault(coords)) return out;
        const gvd = try g.glyphData(gid);
        if (gvd.len == 0) return out;
        const n = n_points + 4;
        var it = try TupleIterator.init(g, gvd, coords);
        var shared: ?PointStream = null;
        if (it.shared) |sp| {
            var r = sp;
            shared = try PointStream.init(&r);
            try shared.?.skipAll(&r);
            it.body_start = r.pos;
        }
        while (try it.next()) |t| {
            var r = t.data;
            var ps: PointStream = undefined;
            var list_start: usize = undefined;
            if (t.private) {
                list_start = r.pos;
                ps = try PointStream.init(&r);
                var tmp = r;
                try ps.skipAll(&tmp);
                r = tmp;
            } else ps = shared orelse return error.Malformed;
            const count = if (ps.all) n else ps.count;
            for (0..4) |k| {
                const target = n_points + k;
                // Position of `target` in the list (the last occurrence wins).
                var pos: ?usize = null;
                if (ps.all) {
                    pos = target;
                } else {
                    var lr: reader.Reader = undefined;
                    if (t.private) {
                        lr = t.data;
                        lr.pos = @intCast(list_start);
                    } else {
                        lr = it.shared.?;
                    }
                    var st = try PointStream.init(&lr);
                    var i: usize = 0;
                    while (try st.next(&lr)) |p| : (i += 1) {
                        if (p == target) pos = i;
                    }
                }
                const at = pos orelse continue;
                if (at >= count) continue;
                var dr = r;
                const x = try nthDelta(&dr, at, count);
                dr = r;
                const y = try nthDelta(&dr, count + at, 2 * count);
                out[k][0] += t.scalar * x;
                out[k][1] += t.scalar * y;
            }
        }
        return out;
    }
};

fn isDefault(coords: VarCoords) bool {
    for (coords) |c| if (c != 0) return false;
    return true;
}

const Tuple = struct { scalar: f32, private: bool, data: reader.Reader };

/// Walks the tuple headers of one glyph, skipping tuples whose scalar is 0.
const TupleIterator = struct {
    g: *const Gvar,
    gvd: []const u8,
    coords: VarCoords,
    count: u16,
    i: u16 = 0,
    header: reader.Reader,
    /// Reader at the shared point numbers, when the glyph has them.
    shared: ?reader.Reader,
    shared_points: ?Points = null,
    /// Offset of the first tuple's serialized data.
    body_start: usize,

    fn init(g: *const Gvar, gvd: []const u8, coords: VarCoords) error{Malformed}!TupleIterator {
        var r = try reader.Reader.at(gvd, 0);
        const cnt = try r.u16_();
        const data_off = try r.u16_();
        if (data_off > gvd.len) return error.Malformed;
        const body = try reader.Reader.at(gvd, data_off);
        return .{
            .g = g,
            .gvd = gvd,
            .coords = coords,
            .count = cnt & count_mask,
            .header = r,
            .shared = if (cnt & shared_point_numbers != 0) body else null,
            .body_start = data_off,
        };
    }

    fn next(it: *TupleIterator) error{Malformed}!?Tuple {
        const axes = it.g.axis_count;
        while (it.i < it.count) {
            it.i += 1;
            const size = try it.header.u16_();
            const index = try it.header.u16_();
            var peak: []const u8 = undefined;
            if (index & embedded_peak != 0) {
                peak = try it.header.slice(@as(usize, axes) * 2);
            } else {
                const k = index & tuple_index_mask;
                const tl = @as(usize, axes) * 2;
                if ((@as(usize, k) + 1) * tl > it.g.shared_tuples.len) return error.Malformed;
                peak = it.g.shared_tuples[@as(usize, k) * tl ..][0..tl];
            }
            var start: ?[]const u8 = null;
            var end: ?[]const u8 = null;
            if (index & intermediate_region != 0) {
                start = try it.header.slice(@as(usize, axes) * 2);
                end = try it.header.slice(@as(usize, axes) * 2);
            }
            const data_at = it.body_start;
            if (data_at + size > it.gvd.len) return error.Malformed;
            it.body_start += size;
            var scalar: f32 = 1;
            for (0..axes) |a| {
                const p = std.mem.readInt(i16, peak[a * 2 ..][0..2], .big);
                const lo = if (start) |s| std.mem.readInt(i16, s[a * 2 ..][0..2], .big) else @min(p, 0);
                const hi = if (end) |e| std.mem.readInt(i16, e[a * 2 ..][0..2], .big) else @max(p, 0);
                scalar *= ivs.axisScalar(lo, p, hi, ivs.coordAt(it.coords, a));
                if (scalar == 0) break;
            }
            if (scalar == 0) continue;
            const r = try reader.Reader.at(it.gvd[0 .. data_at + size], data_at);
            return .{ .scalar = scalar, .private = index & private_point_numbers != 0, .data = r };
        }
        return null;
    }
};

/// Streams a packed point-number list without storing it.
pub const PointStream = struct {
    all: bool,
    count: usize,
    left: usize,
    run_left: usize = 0,
    words: bool = false,
    value: u32 = 0,

    /// Reads the count; `all` when it is 0.
    pub fn init(r: *reader.Reader) error{Malformed}!PointStream {
        const b0 = try r.u8_();
        if (b0 == 0) return .{ .all = true, .count = 0, .left = 0 };
        const count: usize = if (b0 & 0x80 != 0) (@as(usize, b0 & 0x7F) << 8) | try r.u8_() else b0;
        return .{ .all = false, .count = count, .left = count };
    }

    /// The next point number, or null after the last.
    pub fn next(ps: *PointStream, r: *reader.Reader) error{Malformed}!?u16 {
        if (ps.left == 0) return null;
        if (ps.run_left == 0) {
            const c = try r.u8_();
            ps.words = c & 0x80 != 0;
            ps.run_left = @as(usize, c & 0x7F) + 1;
            if (ps.run_left > ps.left) return error.Malformed;
        }
        const d: u32 = if (ps.words) try r.u16_() else try r.u8_();
        ps.value += d;
        if (ps.value > 0xFFFF) return error.Malformed;
        ps.run_left -= 1;
        ps.left -= 1;
        return @intCast(ps.value);
    }

    fn skipAll(ps: *PointStream, r: *reader.Reader) error{Malformed}!void {
        var copy = ps.*;
        while (try copy.next(r)) |_| {}
    }
};

/// Decodes a packed point-number list into `out`.
pub fn decodePoints(gpa: Allocator, r: *reader.Reader, out: *std.ArrayList(u16)) error{ Malformed, OutOfMemory }!Points {
    var ps = try PointStream.init(r);
    if (ps.all) return .{ .all = true, .nums = &.{} };
    try out.ensureUnusedCapacity(gpa, ps.count);
    while (try ps.next(r)) |p| out.appendAssumeCapacity(p);
    return .{ .all = false, .nums = out.items };
}

const deltas_are_zero = 0x80;
const deltas_are_words = 0x40;
const run_count_mask = 0x3F;

/// Decodes exactly `out.len` packed deltas.
pub fn decodeDeltas(r: *reader.Reader, out: []f32) error{Malformed}!void {
    var i: usize = 0;
    while (i < out.len) {
        const c = try r.u8_();
        const run = @as(usize, c & run_count_mask) + 1;
        if (i + run > out.len) return error.Malformed;
        const kind = c & (deltas_are_zero | deltas_are_words);
        for (out[i..][0..run]) |*d| d.* = switch (kind) {
            deltas_are_zero => 0,
            deltas_are_words => @floatFromInt(try r.i16_()),
            deltas_are_zero | deltas_are_words => @floatFromInt(try r.i32_()), // DELTAS_ARE_LONGS
            else => @floatFromInt(try r.i8_()),
        };
        i += run;
    }
}

/// The `k`th of `total` packed deltas.
fn nthDelta(r: *reader.Reader, k: usize, total: usize) error{Malformed}!f32 {
    var i: usize = 0;
    while (i < total) {
        const c = try r.u8_();
        const run = @as(usize, c & run_count_mask) + 1;
        if (i + run > total) return error.Malformed;
        const kind = c & (deltas_are_zero | deltas_are_words);
        const size: usize = switch (kind) {
            deltas_are_zero => 0,
            deltas_are_words => 2,
            deltas_are_zero | deltas_are_words => 4,
            else => 1,
        };
        if (k < i + run) {
            if (size == 0) return 0;
            try r.skip((k - i) * size);
            return switch (size) {
                1 => @floatFromInt(try r.i8_()),
                2 => @floatFromInt(try r.i16_()),
                else => @floatFromInt(try r.i32_()),
            };
        }
        try r.skip(run * size);
        i += run;
    }
    return error.Malformed;
}

/// Infers the deltas of untouched points of contour `s..=e` from their
/// touched neighbours, on the default coordinates `orig`.
pub fn iupContour(orig: []const [2]f32, d: [][2]f32, touched: []bool, s: usize, e: usize) void {
    if (e < s) return;
    var first: ?usize = null;
    var n_touched: usize = 0;
    for (s..e + 1) |i| if (touched[i]) {
        if (first == null) first = i;
        n_touched += 1;
    };
    const f = first orelse return;
    const len = e - s + 1;
    if (n_touched == len) return;
    if (n_touched == 1) {
        for (s..e + 1) |i| d[i] = d[f];
        return;
    }
    // Walk touched points cyclically from `f`, filling each gap.
    var prev = f;
    var steps: usize = 0;
    var i = f;
    while (steps < len) : (steps += 1) {
        i = if (i == e) s else i + 1;
        if (!touched[i]) continue;
        // Fill (prev, i) exclusive, cyclically.
        var j = if (prev == e) s else prev + 1;
        while (j != i) : (j = if (j == e) s else j + 1) {
            for (0..2) |a| d[j][a] = interp(orig[j][a], orig[prev][a], orig[i][a], d[prev][a], d[i][a]);
        }
        prev = i;
    }
    for (s..e + 1) |k| touched[k] = true;
}

fn interp(c: f32, c1: f32, c2: f32, d1: f32, d2: f32) f32 {
    if (c1 == c2) return if (d1 == d2) d1 else 0;
    const lo = @min(c1, c2);
    const hi = @max(c1, c2);
    if (c <= lo) return if (c1 < c2) d1 else d2;
    if (c >= hi) return if (c1 > c2) d1 else d2;
    return d1 + (c - c1) * (d2 - d1) / (c2 - c1);
}

test {
    _ = @import("gvar_test.zig");
}
