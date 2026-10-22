//! `FaceInstance`: one face at one variation position, with the region
//! scalars of each delta store computed once so per-glyph queries are a
//! few multiply-adds. Immutable after `init`, so it can be shared across
//! threads. Caches elsewhere key instances by the registry's
//! `instance_id`, not by coordinates.

const std = @import("std");
const Allocator = std.mem.Allocator;
const reader = @import("../reader.zig");
const face_mod = @import("../face.zig");
const Os2 = @import("../os2.zig").Os2;
const ivs = @import("ivs.zig");
const fvar_mod = @import("fvar.zig");
const Avar = @import("avar.zig").Avar;
const Hvar = @import("hvar.zig").Hvar;
const Mvar = @import("mvar.zig").Mvar;
const gvar_mod = @import("gvar.zig");
const Gvar = gvar_mod.Gvar;
const glyf_mod = @import("../glyf.zig");
const cff_mod = @import("../cff.zig");
const Path = @import("../../outline/path.zig").Path;

const Face = face_mod.Face;
const GlyphId = reader.GlyphId;
const tag = reader.tag;

/// Font-wide metrics in design units at an instance.
pub const FontMetricsF = struct {
    ascender: f32,
    descender: f32,
    line_gap: f32,
    cap_height: f32,
    x_height: f32,
    underline_pos: f32,
    underline_thickness: f32,
    strikeout_pos: f32,
    strikeout_thickness: f32,
    units_per_em: u16,
};

/// The face's `fvar`, if present and well formed.
pub fn fvarOf(face: *const Face) ?fvar_mod.Fvar {
    return fvar_mod.Fvar.init(face.knownTable(.fvar) orelse return null) catch null;
}

/// The face's named instances (none without `fvar`), for style matching.
pub fn namedInstances(face: *const Face) fvar_mod.NamedInstanceIterator {
    return .{ .f = fvarOf(face) };
}

/// Reusable outline buffers; one per worker thread.
pub const OutlineScratch = struct {
    glyf: glyf_mod.Scratch = .{},
    gvar: gvar_mod.GvarScratch = .{},

    /// Frees the buffers.
    pub fn deinit(s: *OutlineScratch, gpa: Allocator) void {
        s.glyf.deinit(gpa);
        s.gvar.deinit(gpa);
    }
};

/// One face at one position in its design space.
pub const FaceInstance = struct {
    face: *const Face,
    coords: [fvar_mod.max_axes]i16 = @splat(0),
    axis_count: u8 = 0,
    hvar: ?Hvar = null,
    mvar: ?Mvar = null,
    gvar: ?Gvar = null,
    /// Region scalars of HVAR's store (empty without HVAR).
    hvar_scalars: []f32 = &.{},
    /// HVAR's data subtables, parsed once (a malformed one has no items).
    hvar_data: []ivs.ItemVariationStore.Data = &.{},
    /// Region scalars of MVAR's store (empty without MVAR).
    mvar_scalars: []f32 = &.{},
    /// The CFF/CFF2 table, parsed once (null for TrueType faces).
    cff: ?cff_mod.Cff = null,
    /// Region scalars of the CFF2 VariationStore (empty at the default).
    cff_scalars: []f32 = &.{},

    /// The instance at `user` settings (normalized through fvar and avar).
    /// A face without `fvar` gives the default instance.
    pub fn init(gpa: Allocator, face: *const Face, user: []const fvar_mod.AxisValue) Allocator.Error!FaceInstance {
        var coords: [fvar_mod.max_axes]i16 = @splat(0);
        var n: usize = 0;
        if (fvarOf(face)) |f| {
            const av: ?Avar = if (face.knownTable(.avar)) |t| Avar.init(t) catch null else null;
            fvar_mod.normalize(&f, if (av) |*a| a else null, user, &coords);
            n = f.axis_count;
        }
        return initNormalized(gpa, face, coords[0..n]);
    }

    /// The instance at already-normalized coordinates (extra ones dropped).
    pub fn initNormalized(gpa: Allocator, face: *const Face, coords: ivs.VarCoords) Allocator.Error!FaceInstance {
        var fi: FaceInstance = .{ .face = face };
        const axes: usize = if (fvarOf(face)) |f| f.axis_count else 0;
        fi.axis_count = @intCast(@min(axes, coords.len));
        @memcpy(fi.coords[0..fi.axis_count], coords[0..fi.axis_count]);
        fi.cff = face.cff();
        if (fi.isDefault()) return fi;
        errdefer fi.deinit(gpa);
        if (fi.cff) |c| if (c.store) |st| {
            fi.cff_scalars = try gpa.alloc(f32, st.region_count);
            st.regionScalars(fi.coordsSlice(), fi.cff_scalars);
        };
        if (face.knownTable(.hvar)) |t| if (Hvar.init(t)) |h| {
            fi.hvar_scalars = try gpa.alloc(f32, h.store.region_count);
            h.store.regionScalars(fi.coordsSlice(), fi.hvar_scalars);
            fi.hvar_data = try gpa.alloc(ivs.ItemVariationStore.Data, h.store.data_count);
            for (fi.hvar_data, 0..) |*d, i| d.* = h.store.itemData(@intCast(i)) catch .{ .item_count = 0, .word_count = 0, .long_words = false, .regions = &.{}, .rows = &.{} };
            fi.hvar = h;
        } else |_| {};
        if (face.knownTable(.gvar)) |t| {
            fi.gvar = Gvar.init(t, @intCast(axes), face.num_glyphs) catch null;
        }
        if (face.knownTable(.mvar)) |t| if (Mvar.init(t)) |m| {
            if (m.store) |s| {
                fi.mvar_scalars = try gpa.alloc(f32, s.region_count);
                s.regionScalars(fi.coordsSlice(), fi.mvar_scalars);
            }
            fi.mvar = m;
        } else |_| {};
        return fi;
    }

    /// Frees the scalar caches.
    pub fn deinit(fi: *FaceInstance, gpa: Allocator) void {
        gpa.free(fi.hvar_scalars);
        gpa.free(fi.hvar_data);
        gpa.free(fi.mvar_scalars);
        gpa.free(fi.cff_scalars);
        fi.cff_scalars = &.{};
        fi.hvar_data = &.{};
        fi.hvar_scalars = &.{};
        fi.mvar_scalars = &.{};
    }

    /// The normalized coordinates.
    pub fn coordsSlice(fi: *const FaceInstance) ivs.VarCoords {
        return fi.coords[0..fi.axis_count];
    }

    /// True when every coordinate is 0 (no deltas apply).
    pub fn isDefault(fi: *const FaceInstance) bool {
        for (fi.coordsSlice()) |c| if (c != 0) return false;
        return true;
    }

    /// Advance of `gid` in design units: hmtx plus the HVAR delta, or,
    /// without HVAR, the gvar phantom-point delta.
    pub fn advance(fi: *const FaceInstance, gid: GlyphId) f32 {
        const base: f32 = @floatFromInt(fi.face.advance(gid));
        const h = &(fi.hvar orelse return base + fi.phantomAdvanceDelta(gid));
        const i = h.advanceIdx(gid);
        if (i.outer >= fi.hvar_data.len) return base;
        return base + fi.hvar_data[i.outer].deltaScaled(i.inner, fi.hvar_scalars);
    }

    fn phantomAdvanceDelta(fi: *const FaceInstance, gid: GlyphId) f32 {
        const gv = &(fi.gvar orelse return 0);
        const g = fi.face.glyf() orelse return 0;
        const n = g.pointCount(gid) catch return 0;
        const d = gv.phantomDeltas(gid, fi.coordsSlice(), n) catch return 0;
        return d[1][0] - d[0][0];
    }

    /// The advance from gvar phantom points (hmtx advance plus the
    /// right-minus-left phantom delta), whether or not the face has HVAR.
    pub fn advanceFromPhantoms(fi: *const FaceInstance, gid: GlyphId) f32 {
        return @as(f32, @floatFromInt(fi.face.advance(gid))) + fi.phantomAdvanceDelta(gid);
    }

    /// Appends the outline of `gid` at this instance to `out`: TrueType in
    /// font units with the origin at the left phantom point, CFF in
    /// charstring units (see `Cff.fontMatrix`; the usual 0.001 matrix with
    /// a 1000-unit em makes them font units). Allocation-free once `scratch`
    /// and `out` are warm.
    pub fn outline(fi: *const FaceInstance, gpa: Allocator, gid: GlyphId, scratch: *OutlineScratch, out: *Path) error{ Malformed, OutOfMemory, LimitExceeded, Unsupported }!void {
        if (fi.cff) |*c| {
            const blend: ?cff_mod.BlendCtx = if (fi.cff_scalars.len > 0) .{ .scalars = fi.cff_scalars } else null;
            return c.outline(gid, blend, out, gpa);
        }
        const g = fi.face.glyf() orelse return error.Unsupported;
        const hook: ?glyf_mod.DeltaHook = if (fi.gvar) |*gv| gv.hook(gpa, fi.coordsSlice(), &scratch.gvar) else null;
        _ = try g.outline(gpa, gid, &scratch.glyf, hook, out);
    }

    /// Font-wide metrics with MVAR deltas. Ascender, descender and line gap
    /// take `hasc`/`hdsc`/`hlgp` whichever table they come from (as
    /// HarfBuzz does), or `hcla`/`hcld` when they fall back to OS/2 win
    /// metrics.
    pub fn metrics(fi: *const FaceInstance) FontMetricsF {
        const m = fi.face.metrics();
        var out: FontMetricsF = .{
            .ascender = @floatFromInt(m.ascender),
            .descender = @floatFromInt(m.descender),
            .line_gap = @floatFromInt(m.line_gap),
            .cap_height = @floatFromInt(m.cap_height),
            .x_height = @floatFromInt(m.x_height),
            .underline_pos = @floatFromInt(m.underline_pos),
            .underline_thickness = @floatFromInt(m.underline_thickness),
            .strikeout_pos = @floatFromInt(m.strikeout_pos),
            .strikeout_thickness = @floatFromInt(m.strikeout_thickness),
            .units_per_em = m.units_per_em,
        };
        const mv = &(fi.mvar orelse return out);
        const s = fi.mvar_scalars;
        const win = if (fi.face.os2) |o|
            o.fs_selection & Os2.sel_use_typo_metrics == 0 and fi.face.hhea.ascender == 0 and fi.face.hhea.descender == 0 and fi.face.hhea.line_gap == 0
        else
            false;
        if (win) {
            out.ascender += mv.delta(tag("hcla"), s);
            out.descender -= mv.delta(tag("hcld"), s);
        } else {
            out.ascender += mv.delta(tag("hasc"), s);
            out.descender += mv.delta(tag("hdsc"), s);
            out.line_gap += mv.delta(tag("hlgp"), s);
        }
        out.cap_height += mv.delta(tag("cpht"), s);
        out.x_height += mv.delta(tag("xhgt"), s);
        out.underline_pos += mv.delta(tag("undo"), s);
        out.underline_thickness += mv.delta(tag("unds"), s);
        out.strikeout_pos += mv.delta(tag("stro"), s);
        out.strikeout_thickness += mv.delta(tag("strs"), s);
        return out;
    }
};
