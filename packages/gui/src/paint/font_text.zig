//! `FontText`: the production `TextSystem`, drawing real fonts through
//! zg_text: cmap lookup and advances from the face, outlines rasterized at
//! the window's physical size (quarter-pixel horizontal positions), and
//! bitmaps packed into zg_text's atlas. Glyph quads carry normalised
//! texture coordinates (u0, v0, u1, v1), as r2d samples them.
//!
//! The Host uploads the atlas: `takeUpdates` hands out the dirty regions
//! (each page becomes one renderer texture; an evicted page comes back
//! dirty in full).
//!
//! Until E03's shaping and font registry land (E03.F06, E03.F07), there is
//! no shaping, kerning or per-script fallback: each codepoint maps to one
//! glyph of the `ui` or `mono` face, falling back to the other face, then
//! to `.notdef`.

const std = @import("std");
const zg_text = @import("zg_text");
const geom = @import("../core/geom.zig");
const text = @import("text.zig");
const canvas = @import("canvas.zig");

const ot = zg_text.ot;
const Atlas = zg_text.cache.Atlas;
const AtlasEntry = zg_text.cache.AtlasEntry;
const AtlasUpdate = zg_text.cache.AtlasUpdate;
const FaceInstance = ot.variation.FaceInstance;
const Rasterizer = zg_text.raster.Rasterizer;
const TextStyle = text.TextStyle;
const Vec2 = geom.Vec2;

/// Font files for the two slots. The bytes must outlive the `FontText`.
pub const Fonts = struct {
    ui: []const u8,
    mono: []const u8,
};

/// Fonts, glyph cache and atlas behind a `TextSystem`.
pub const FontText = struct {
    gpa: std.mem.Allocator,
    faces: [2]ot.Face,
    inst: [2]FaceInstance,
    /// Font units per em, ascender, descender (negative) and line gap.
    upem: [2]f32,
    asc: [2]f32,
    desc: [2]f32,
    gap: [2]f32,
    raster: Rasterizer,
    atlas: Atlas,
    /// (slot, codepoint) → resolved face and glyph, plus its advance.
    cmap: std.AutoHashMapUnmanaged(u32, Mapped) = .empty,
    glyphs: std.AutoHashMapUnmanaged(GlyphKey, AtlasEntry) = .empty,
    /// Physical pixels per logical pixel for the window being painted.
    scale: f32 = 1,
    /// Bumped by the Host per frame; drives atlas LRU eviction.
    frame: u32 = 0,
    /// Bumped when a page is evicted: retained paint ops may point at
    /// cleared texels, so the Host repaints every window.
    evictions: u32 = 0,

    const Mapped = struct { face: u8, gid: u16, adv: f32 };

    const GlyphKey = struct {
        face: u8,
        /// Quarter-pixel horizontal position.
        sub: u8,
        bold: bool,
        gid: u16,
        /// Pixels per em × 64.
        px64: u32,
    };

    /// Loads both faces. Fails when a font cannot be parsed.
    pub fn create(gpa: std.mem.Allocator, fonts: Fonts) !*FontText {
        const ft = try gpa.create(FontText);
        errdefer gpa.destroy(ft);
        ft.* = .{
            .gpa = gpa,
            .faces = .{ try ot.Face.init(fonts.ui, 0), try ot.Face.init(fonts.mono, 0) },
            .inst = undefined,
            .upem = undefined,
            .asc = undefined,
            .desc = undefined,
            .gap = undefined,
            .raster = .init(gpa),
            .atlas = try .init(gpa, .{}),
        };
        errdefer ft.atlas.deinit();
        ft.inst[0] = try .init(gpa, &ft.faces[0], &.{});
        errdefer ft.inst[0].deinit(gpa);
        ft.inst[1] = try .init(gpa, &ft.faces[1], &.{});
        for (0..2) |i| {
            const m = ft.inst[i].metrics();
            ft.upem[i] = @floatFromInt(@max(m.units_per_em, 1));
            ft.asc[i] = m.ascender;
            ft.desc[i] = m.descender;
            ft.gap[i] = m.line_gap;
        }
        ft.atlas.setEvictCallback(ft, onEvict);
        return ft;
    }

    /// Frees everything.
    pub fn destroy(ft: *FontText) void {
        const gpa = ft.gpa;
        ft.cmap.deinit(gpa);
        ft.glyphs.deinit(gpa);
        ft.atlas.deinit();
        ft.raster.deinit();
        for (&ft.inst) |*i| i.deinit(gpa);
        gpa.destroy(ft);
    }

    /// The `TextSystem` interface.
    pub fn system(ft: *FontText) text.TextSystem {
        return .{ .ptr = ft, .vtable = &vtable };
    }

    /// The atlas's dirty regions since the last call (pixels valid until
    /// the next glyph is rasterized).
    pub fn takeUpdates(ft: *FontText, out: *std.ArrayList(AtlasUpdate)) !void {
        try ft.atlas.takeUpdates(out, ft.gpa);
    }

    /// Marks every page dirty in full, so a new renderer gets all of them.
    pub fn reuploadAll(ft: *FontText) void {
        ft.atlas.markAllDirty();
    }

    /// The atlas page size in texels.
    pub fn pageSize(ft: *const FontText) u16 {
        return ft.atlas.page_size;
    }

    fn onEvict(p: *anyopaque, page: u16) void {
        const ft: *FontText = @ptrCast(@alignCast(p));
        ft.evictions +%= 1;
        // Drop every glyph on the page; they are rasterized again on use.
        var it = ft.glyphs.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.page == page and !e.value_ptr.isEmpty()) {
                ft.glyphs.removeByPtr(e.key_ptr);
                it = ft.glyphs.iterator();
            }
        }
    }

    const vtable: text.TextSystem.VTable = .{ .metrics = metrics, .advance = advance, .glyph = glyph };

    fn self(p: *anyopaque) *FontText {
        return @ptrCast(@alignCast(p));
    }

    fn slot(st: TextStyle) u8 {
        return if (st.font == .mono) 1 else 0;
    }

    fn metrics(p: *anyopaque, st: TextStyle) text.LineMetrics {
        const ft = self(p);
        const i = slot(st);
        const k = st.size / ft.upem[i];
        const ascent = ft.asc[i] * k;
        const descent = -ft.desc[i] * k;
        return .{ .ascent = ascent, .descent = descent, .line_h = @round(@max(ascent + descent + ft.gap[i] * k, st.size * 1.2)) };
    }

    /// The face and glyph for `cp` in slot `s`, cached.
    fn map(ft: *FontText, s: u8, cp: u21) Mapped {
        const key = (@as(u32, s) << 21) | cp;
        if (ft.cmap.get(key)) |m| return m;
        var face = s;
        var gid = ft.faces[s].glyphIndex(cp);
        if (gid == 0) {
            const other = 1 - s;
            const g2 = ft.faces[other].glyphIndex(cp);
            if (g2 != 0) {
                face = other;
                gid = g2;
            }
        }
        const m: Mapped = .{ .face = face, .gid = gid, .adv = ft.inst[face].advance(gid) / ft.upem[face] };
        ft.cmap.put(ft.gpa, key, m) catch {};
        return m;
    }

    fn advance(p: *anyopaque, st: TextStyle, cp: u21) f32 {
        if (cp == '\n') return 0;
        const ft = self(p);
        return ft.map(slot(st), cp).adv * st.size;
    }

    fn glyph(p: *anyopaque, st: TextStyle, cp: u21, pen: Vec2) ?canvas.GlyphQuad {
        const ft = self(p);
        if (cp == ' ' or cp == '\n' or cp == '\t') return null;
        const m = ft.map(slot(st), cp);
        const s = ft.scale;
        const px = st.size * s;
        // Snap the pen to quarter pixels horizontally, whole pixels vertically.
        const x4 = @round(pen.x * s * 4);
        const ix = @floor(x4 / 4);
        const sub: u8 = @intFromFloat(x4 - ix * 4);
        const by = @round(pen.y * s);
        const key: GlyphKey = .{ .face = m.face, .sub = sub, .bold = st.weight >= 600, .gid = m.gid, .px64 = @intFromFloat(@round(px * 64)) };
        const e = ft.glyphs.get(key) orelse blk: {
            const bmp = ft.raster.rasterizeGlyph(&ft.inst[m.face], m.gid, .{
                .px_per_em = px,
                .subpixel_x = @as(f32, @floatFromInt(sub)) / 4,
                .synth_bold = key.bold,
                .synth_oblique = st.italic,
            }) catch return null;
            const entry = ft.atlas.insert(&bmp, ft.frame) catch return null;
            ft.glyphs.put(ft.gpa, key, entry) catch return null;
            break :blk entry;
        };
        if (e.isEmpty()) return null;
        ft.atlas.touch(e.page, ft.frame);
        const ps: f32 = @floatFromInt(ft.atlas.page_size);
        const fx: f32 = @floatFromInt(e.x);
        const fy: f32 = @floatFromInt(e.y);
        const fw: f32 = @floatFromInt(e.w);
        const fh: f32 = @floatFromInt(e.h);
        return .{
            .dst = .{ (ix + @as(f32, @floatFromInt(e.left))) / s, (by + @as(f32, @floatFromInt(e.top))) / s, fw / s, fh / s },
            .uv = .{ fx / ps, fy / ps, (fx + fw) / ps, (fy + fh) / ps },
            .page = e.page,
            .format = zg_text.cache.atlas.formatOf(e.format),
        };
    }
};

test {
    std.testing.refAllDecls(@This());
}
