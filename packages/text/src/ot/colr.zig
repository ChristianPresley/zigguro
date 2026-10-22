//! `COLR` colour glyphs, versions 0 and 1. Version 0 maps a base glyph to
//! a stack of (glyph, palette index) layers. Version 1 maps it to the root
//! of a paint graph: layers, solid fills, linear/radial/sweep gradients,
//! glyph-outline clips, references to other colour glyphs, affine
//! transforms and composites, plus clip boxes and variation deltas
//! (`VarIndexBase + n` through the DeltaSetIndexMap into the
//! ItemVariationStore).
//!
//! Paints are decoded on demand from their offset in the table; every
//! transform-like format (12–31) decodes to one affine map in glyph space
//! (y up). Rendering is
//! in `raster/colr_render.zig`.

const std = @import("std");
const reader = @import("reader.zig");
const GlyphId = reader.GlyphId;
const Face = @import("face.zig").Face;
const cpal_mod = @import("cpal.zig");
const ivs = @import("var/ivs.zig");
const path_mod = @import("../outline/path.zig");
const Affine = path_mod.Affine;
const Rect = path_mod.Rect;

/// Normalized variation coordinates.
pub const VarCoords = ivs.VarCoords;
/// The CPAL table.
pub const Cpal = cpal_mod.Cpal;
/// Palette index meaning the text colour.
pub const foreground_index = cpal_mod.foreground_index;

/// How a colour line continues outside [0, 1]. Unknown values read as pad.
pub const Extend = enum(u8) { pad, repeat, reflect };

/// PaintComposite modes, in the spec's order.
pub const CompositeMode = enum(u8) {
    clear,
    src,
    dest,
    src_over,
    dest_over,
    src_in,
    dest_in,
    src_out,
    dest_out,
    src_atop,
    dest_atop,
    xor,
    plus,
    screen,
    overlay,
    darken,
    lighten,
    color_dodge,
    color_burn,
    hard_light,
    soft_light,
    difference,
    exclusion,
    multiply,
    hue,
    saturation,
    color,
    luminosity,
};

/// A (Var)ColorLine: its stop records, read with `Colr.stop`.
pub const ColorLine = struct {
    extend: Extend,
    count: u16,
    /// The stop records.
    stops: []const u8,
    /// VarColorStop records (10 bytes) instead of ColorStop (6).
    variable: bool,
};

/// One colour stop with its deltas applied.
pub const ColorStop = struct { offset: f32, palette: u16, alpha: f32 };

/// A decoded paint. Offsets (`child`, `source`, ...) are absolute within
/// the COLR table.
pub const Paint = union(enum) {
    /// Formats 1: `count` paints of the LayerList from `first`.
    layers: struct { first: u32, count: u8 },
    /// Formats 2, 3.
    solid: struct { palette: u16, alpha: f32 },
    /// Formats 4, 5: the colour line runs from p0 to p1, rotated so the
    /// colour bands are parallel to p0p2.
    linear: struct { line: ColorLine, p0: [2]f32, p1: [2]f32, p2: [2]f32 },
    /// Formats 6, 7: a two-circle gradient.
    radial: struct { line: ColorLine, c0: [2]f32, r0: f32, c1: [2]f32, r1: f32 },
    /// Formats 8, 9: angles in degrees, counter-clockwise, y up (stored
    /// as F2Dot14 half-turns biased by -1, so 0° is -1.0 and 360° is 1.0).
    sweep: struct { line: ColorLine, center: [2]f32, start_deg: f32, end_deg: f32 },
    /// Format 10: `child` clipped by the outline of `gid`.
    glyph: struct { gid: GlyphId, child: u32 },
    /// Format 11: another base glyph's paint graph.
    colr_glyph: GlyphId,
    /// Formats 12–31: `child` drawn through `m` (glyph space).
    transform: struct { m: Affine, child: u32 },
    /// Format 32: `source` composited onto `backdrop` with `mode`.
    composite: struct { source: u32, mode: CompositeMode, backdrop: u32 },
};

/// A version-0 layer.
pub const Layer = struct { gid: GlyphId, palette: u16 };

/// Most paints `usesForeground` visits before giving up.
const fg_walk_budget = 1 << 14;
/// Deepest paint nesting `usesForeground` follows.
const fg_walk_depth = 64;

/// A parsed COLR table (and its CPAL, when given and well formed).
pub const Colr = struct {
    data: []const u8,
    cpal: ?Cpal,
    version: u16,
    base_v0: u32,
    num_base_v0: u16,
    layers_v0: u32,
    num_layers_v0: u16,
    /// BaseGlyphList, LayerList and ClipList offsets (0 when absent) and
    /// their record counts.
    base_list: u32 = 0,
    num_base_v1: u32 = 0,
    layer_list: u32 = 0,
    num_layers_v1: u32 = 0,
    clip_list: u32 = 0,
    num_clips: u32 = 0,
    var_map: ?ivs.DeltaSetIndexMap = null,
    store: ?ivs.ItemVariationStore = null,

    /// Validates the header and that every record array fits. A CPAL that
    /// does not parse is ignored (every colour becomes the text colour).
    pub fn init(colr: []const u8, cpal: ?[]const u8) error{Malformed}!Colr {
        if (colr.len >= 1 << 31) return error.Malformed;
        var r = try reader.Reader.at(colr, 0);
        const version = try r.u16_();
        if (version > 1) return error.Malformed;
        var c: Colr = .{
            .data = colr,
            .cpal = if (cpal) |p| Cpal.init(p) catch null else null,
            .version = version,
            .num_base_v0 = try r.u16_(),
            .base_v0 = try r.u32_(),
            .layers_v0 = try r.u32_(),
            .num_layers_v0 = try r.u16_(),
        };
        if (c.num_base_v0 > 0) _ = try reader.subLen(colr, c.base_v0, @as(usize, c.num_base_v0) * 6);
        if (c.num_layers_v0 > 0) _ = try reader.subLen(colr, c.layers_v0, @as(usize, c.num_layers_v0) * 4);
        if (version == 0) return c;
        const base_list = try r.u32_();
        const layer_list = try r.u32_();
        const clip_list = try r.u32_();
        const var_map = try r.u32_();
        const store = try r.u32_();
        if (base_list != 0) {
            c.num_base_v1 = try reader.readAt(u32, colr, base_list);
            _ = try reader.subLen(colr, @as(usize, base_list) + 4, @as(usize, c.num_base_v1) * 6);
            c.base_list = base_list;
        }
        if (layer_list != 0) {
            c.num_layers_v1 = try reader.readAt(u32, colr, layer_list);
            _ = try reader.subLen(colr, @as(usize, layer_list) + 4, @as(usize, c.num_layers_v1) * 4);
            c.layer_list = layer_list;
        }
        if (clip_list != 0) {
            if (try reader.readAt(u8, colr, clip_list) != 1) return error.Malformed;
            c.num_clips = try reader.readAt(u32, colr, @as(usize, clip_list) + 1);
            _ = try reader.subLen(colr, @as(usize, clip_list) + 5, @as(usize, c.num_clips) * 7);
            c.clip_list = clip_list;
        }
        if (var_map != 0) c.var_map = try ivs.DeltaSetIndexMap.init(try reader.sub(colr, var_map));
        if (store != 0) c.store = try ivs.ItemVariationStore.init(try reader.sub(colr, store));
        return c;
    }

    /// From a face, if it has a COLR table that parses.
    pub fn fromFace(face: *const Face) ?Colr {
        const t = face.knownTable(.colr) orelse return null;
        return init(t, face.knownTable(.cpal)) catch null;
    }

    /// True when `gid` has a version-1 paint graph or version-0 layers.
    pub fn hasGlyph(c: *const Colr, gid: GlyphId) bool {
        return c.v1Paint(gid) != null or c.v0Layers(gid) != null;
    }

    /// The root paint of `gid` (absolute offset), from the BaseGlyphList.
    pub fn v1Paint(c: *const Colr, gid: GlyphId) ?u32 {
        if (c.base_list == 0) return null;
        const recs = c.data[c.base_list + 4 ..][0 .. @as(usize, c.num_base_v1) * 6];
        var lo: usize = 0;
        var hi: usize = c.num_base_v1;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const g = std.mem.readInt(u16, recs[mid * 6 ..][0..2], .big);
            if (g == gid) {
                const off = c.base_list + std.mem.readInt(u32, recs[mid * 6 + 2 ..][0..4], .big);
                return if (off < c.data.len) off else null;
            }
            if (g < gid) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// The version-0 layer range of `gid`.
    pub fn v0Layers(c: *const Colr, gid: GlyphId) ?struct { first: u16, count: u16 } {
        var lo: usize = 0;
        var hi: usize = c.num_base_v0;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const rec = c.data[c.base_v0 + mid * 6 ..][0..6];
            const g = std.mem.readInt(u16, rec[0..2], .big);
            if (g == gid) {
                const first = std.mem.readInt(u16, rec[2..4], .big);
                const count = std.mem.readInt(u16, rec[4..6], .big);
                if (@as(u32, first) + count > c.num_layers_v0) return null;
                return .{ .first = first, .count = count };
            }
            if (g < gid) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// Version-0 layer `i` (< num_layers_v0).
    pub fn v0Layer(c: *const Colr, i: u16) Layer {
        const rec = c.data[c.layers_v0 + @as(usize, i) * 4 ..][0..4];
        return .{ .gid = std.mem.readInt(u16, rec[0..2], .big), .palette = std.mem.readInt(u16, rec[2..4], .big) };
    }

    /// Paint `i` of the LayerList (absolute offset).
    pub fn layerPaint(c: *const Colr, i: u32) ?u32 {
        if (c.layer_list == 0 or i >= c.num_layers_v1) return null;
        const off = c.layer_list + std.mem.readInt(u32, c.data[c.layer_list + 4 + @as(usize, i) * 4 ..][0..4], .big);
        return if (off < c.data.len) off else null;
    }

    /// The clip box of `gid` in font units at `coords`, if the ClipList
    /// has one.
    pub fn clipBox(c: *const Colr, gid: GlyphId, coords: VarCoords) ?Rect {
        if (c.clip_list == 0) return null;
        const recs = c.data[c.clip_list + 5 ..][0 .. @as(usize, c.num_clips) * 7];
        // The last clip starting at or before gid.
        var lo: usize = 0;
        var hi: usize = c.num_clips;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (std.mem.readInt(u16, recs[mid * 7 ..][0..2], .big) <= gid) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        const rec = recs[(lo - 1) * 7 ..][0..7];
        if (gid > std.mem.readInt(u16, rec[2..4], .big)) return null;
        const off = @as(usize, c.clip_list) + std.mem.readInt(u24, rec[4..7], .big);
        var r = reader.Reader.at(c.data, off) catch return null;
        const format = r.u8_() catch return null;
        if (format != 1 and format != 2) return null;
        const v = c.fields(&r, &.{ .fword, .fword, .fword, .fword }, format == 2, coords) catch return null;
        return .{ .x0 = @min(v[0], v[2]), .y0 = @min(v[1], v[3]), .x1 = @max(v[0], v[2]), .y1 = @max(v[1], v[3]) };
    }

    /// The delta of variation index `base + n` at `coords`, in the units
    /// the store holds (font units, or raw F2Dot14/Fixed steps).
    pub fn delta(c: *const Colr, base: u32, n: u32, coords: VarCoords) f32 {
        const store = c.store orelse return 0;
        if (base == 0xFFFFFFFF or coords.len == 0) return 0;
        const i = std.math.add(u32, base, n) catch return 0;
        const idx: ivs.VarIdx = if (c.var_map) |*m| m.get(i) else .{ .outer = @truncate(i >> 16), .inner = @truncate(i) };
        return store.delta(idx.outer, idx.inner, coords);
    }

    const Field = enum { fword, ufword, f2dot14, fixed };

    /// Reads `kinds` from `r` and, when `variable`, the VarIndexBase that
    /// follows them, adding each field's delta.
    fn fields(c: *const Colr, r: *reader.Reader, comptime kinds: []const Field, variable: bool, coords: VarCoords) reader.Error![kinds.len]f32 {
        var v: [kinds.len]f32 = undefined;
        inline for (kinds, 0..) |k, i| v[i] = switch (k) {
            .fword => @floatFromInt(try r.i16_()),
            .ufword => @floatFromInt(try r.u16_()),
            .f2dot14 => @as(f32, @floatFromInt(try r.i16_())) / 16384,
            .fixed => @as(f32, @floatFromInt(try r.i32_())) / 65536,
        };
        if (variable) {
            const base = try r.u32_();
            inline for (kinds, 0..) |k, i| {
                const d = c.delta(base, i, coords);
                v[i] += switch (k) {
                    .fword, .ufword => d,
                    .f2dot14 => d / 16384,
                    .fixed => d / 65536,
                };
            }
        }
        return v;
    }

    /// The paint at absolute offset `off`, with deltas at `coords`.
    pub fn paint(c: *const Colr, off: u32, coords: VarCoords) reader.Error!Paint {
        var r = try reader.Reader.at(c.data, off);
        const format = try r.u8_();
        const variable = format >= 3 and format <= 31 and format & 1 == 1 and format != 11;
        switch (format) {
            1 => {
                const n = try r.u8_();
                return .{ .layers = .{ .count = n, .first = try r.u32_() } };
            },
            2, 3 => {
                const pal = try r.u16_();
                const v = try c.fields(&r, &.{.f2dot14}, variable, coords);
                return .{ .solid = .{ .palette = pal, .alpha = v[0] } };
            },
            4, 5 => {
                const line = try c.colorLine(off, try r.u24_(), variable);
                const v = try c.fields(&r, &.{ .fword, .fword, .fword, .fword, .fword, .fword }, variable, coords);
                return .{ .linear = .{ .line = line, .p0 = .{ v[0], v[1] }, .p1 = .{ v[2], v[3] }, .p2 = .{ v[4], v[5] } } };
            },
            6, 7 => {
                const line = try c.colorLine(off, try r.u24_(), variable);
                const v = try c.fields(&r, &.{ .fword, .fword, .ufword, .fword, .fword, .ufword }, variable, coords);
                return .{ .radial = .{ .line = line, .c0 = .{ v[0], v[1] }, .r0 = v[2], .c1 = .{ v[3], v[4] }, .r1 = v[5] } };
            },
            8, 9 => {
                const line = try c.colorLine(off, try r.u24_(), variable);
                const v = try c.fields(&r, &.{ .fword, .fword, .f2dot14, .f2dot14 }, variable, coords);
                return .{ .sweep = .{ .line = line, .center = .{ v[0], v[1] }, .start_deg = (v[2] + 1) * 180, .end_deg = (v[3] + 1) * 180 } };
            },
            10 => {
                const child = try child24(off, try r.u24_());
                return .{ .glyph = .{ .child = child, .gid = try r.u16_() } };
            },
            11 => return .{ .colr_glyph = try r.u16_() },
            12, 13 => {
                const child = try child24(off, try r.u24_());
                var tr = try reader.Reader.at(c.data, try child24(off, try r.u24_()));
                const v = try c.fields(&tr, &.{ .fixed, .fixed, .fixed, .fixed, .fixed, .fixed }, variable, coords);
                return .{ .transform = .{ .child = child, .m = .{ .xx = v[0], .yx = v[1], .xy = v[2], .yy = v[3], .dx = v[4], .dy = v[5] } } };
            },
            14...31 => {
                const child = try child24(off, try r.u24_());
                const m: Affine = switch (format) {
                    14, 15 => blk: {
                        const v = try c.fields(&r, &.{ .fword, .fword }, variable, coords);
                        break :blk .{ .dx = v[0], .dy = v[1] };
                    },
                    16, 17 => blk: {
                        const v = try c.fields(&r, &.{ .f2dot14, .f2dot14 }, variable, coords);
                        break :blk .{ .xx = v[0], .yy = v[1] };
                    },
                    18, 19 => blk: {
                        const v = try c.fields(&r, &.{ .f2dot14, .f2dot14, .fword, .fword }, variable, coords);
                        break :blk around(.{ .xx = v[0], .yy = v[1] }, v[2], v[3]);
                    },
                    20, 21 => blk: {
                        const v = try c.fields(&r, &.{.f2dot14}, variable, coords);
                        break :blk Affine.scale(v[0]);
                    },
                    22, 23 => blk: {
                        const v = try c.fields(&r, &.{ .f2dot14, .fword, .fword }, variable, coords);
                        break :blk around(Affine.scale(v[0]), v[1], v[2]);
                    },
                    24, 25 => blk: {
                        const v = try c.fields(&r, &.{.f2dot14}, variable, coords);
                        break :blk rotation(v[0]);
                    },
                    26, 27 => blk: {
                        const v = try c.fields(&r, &.{ .f2dot14, .fword, .fword }, variable, coords);
                        break :blk around(rotation(v[0]), v[1], v[2]);
                    },
                    28, 29 => blk: {
                        const v = try c.fields(&r, &.{ .f2dot14, .f2dot14 }, variable, coords);
                        break :blk skew(v[0], v[1]);
                    },
                    30, 31 => blk: {
                        const v = try c.fields(&r, &.{ .f2dot14, .f2dot14, .fword, .fword }, variable, coords);
                        break :blk around(skew(v[0], v[1]), v[2], v[3]);
                    },
                    else => unreachable,
                };
                return .{ .transform = .{ .child = child, .m = m } };
            },
            32 => {
                const source = try child24(off, try r.u24_());
                const mode = try r.u8_();
                if (mode > @intFromEnum(CompositeMode.luminosity)) return error.Malformed;
                return .{ .composite = .{ .source = source, .mode = @enumFromInt(mode), .backdrop = try child24(off, try r.u24_()) } };
            },
            else => return error.Malformed,
        }
    }

    /// The colour line at `rel` from the paint at `paint_off`.
    fn colorLine(c: *const Colr, paint_off: u32, rel: u24, variable: bool) reader.Error!ColorLine {
        if (rel == 0) return error.Malformed;
        var r = try reader.Reader.at(c.data, @as(usize, paint_off) + rel);
        const ext = try r.u8_();
        const count = try r.u16_();
        const stops = try r.slice(@as(usize, count) * @as(usize, if (variable) 10 else 6));
        return .{ .extend = if (ext <= 2) @enumFromInt(ext) else .pad, .count = count, .stops = stops, .variable = variable };
    }

    /// Stop `i` (< line.count) of `line` at `coords`.
    pub fn stop(c: *const Colr, line: ColorLine, i: usize, coords: VarCoords) ColorStop {
        const rec = line.stops[i * @as(usize, if (line.variable) 10 else 6) ..];
        var offset: f32 = @as(f32, @floatFromInt(std.mem.readInt(i16, rec[0..2], .big))) / 16384;
        var alpha: f32 = @as(f32, @floatFromInt(std.mem.readInt(i16, rec[4..6], .big))) / 16384;
        if (line.variable) {
            const base = std.mem.readInt(u32, rec[6..10], .big);
            offset += c.delta(base, 0, coords) / 16384;
            alpha += c.delta(base, 1, coords) / 16384;
        }
        return .{ .offset = offset, .palette = std.mem.readInt(u16, rec[2..4], .big), .alpha = alpha };
    }

    /// True when drawing `gid` uses the text colour (palette index 0xFFFF)
    /// anywhere: such glyphs cannot be cached across text colours. Graphs
    /// too deep or too large to walk count as using it.
    pub fn usesForeground(c: *const Colr, gid: GlyphId) bool {
        if (c.v1Paint(gid)) |root| {
            var budget: u32 = fg_walk_budget;
            return c.fgWalk(root, 0, &budget);
        }
        const l = c.v0Layers(gid) orelse return false;
        for (0..l.count) |i| {
            if (c.v0Layer(@intCast(l.first + i)).palette == foreground_index) return true;
        }
        return false;
    }

    fn fgWalk(c: *const Colr, off: u32, depth: u32, budget: *u32) bool {
        if (depth >= fg_walk_depth or budget.* == 0) return true;
        budget.* -= 1;
        const p = c.paint(off, &.{}) catch return false;
        switch (p) {
            .layers => |l| for (0..l.count) |i| {
                const child = c.layerPaint(l.first +| @as(u32, @intCast(i))) orelse continue;
                if (c.fgWalk(child, depth + 1, budget)) return true;
            },
            .solid => |s| return s.palette == foreground_index,
            inline .linear, .radial, .sweep => |g| for (0..g.line.count) |i| {
                if (c.stop(g.line, i, &.{}).palette == foreground_index) return true;
            },
            .glyph => |g| return c.fgWalk(g.child, depth + 1, budget),
            .colr_glyph => |g| return if (c.v1Paint(g)) |root| c.fgWalk(root, depth + 1, budget) else false,
            .transform => |t| return c.fgWalk(t.child, depth + 1, budget),
            .composite => |k| return c.fgWalk(k.source, depth + 1, budget) or c.fgWalk(k.backdrop, depth + 1, budget),
        }
        return false;
    }
};

fn child24(off: u32, rel: u24) reader.Error!u32 {
    if (rel == 0) return error.Malformed;
    return off + rel;
}

/// `m` about the point (cx, cy) instead of the origin.
fn around(m: Affine, cx: f32, cy: f32) Affine {
    return (Affine{ .dx = cx, .dy = cy }).mul(m).mul(.{ .dx = -cx, .dy = -cy });
}

/// A counter-clockwise rotation by `half_turns` × 180°.
fn rotation(half_turns: f32) Affine {
    const a = half_turns * std.math.pi;
    const s = @sin(a);
    const co = @cos(a);
    return .{ .xx = co, .yx = s, .xy = -s, .yy = co };
}

/// PaintSkew: x skewed by -x_half_turns (clockwise is positive, as the
/// spec draws it) and y by y_half_turns.
fn skew(x_half_turns: f32, y_half_turns: f32) Affine {
    return .{ .xy = @tan(-x_half_turns * std.math.pi), .yx = @tan(y_half_turns * std.math.pi) };
}

test {
    _ = cpal_mod;
}
