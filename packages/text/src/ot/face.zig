//! `Face`: one font face over borrowed bytes, and `MappedFont`, which owns a
//! read-only memory map of a font file. Opening a face decodes only the
//! table directory and the fixed-size headers; it never allocates.

const std = @import("std");
const reader = @import("reader.zig");
const sfnt = @import("sfnt.zig");
const cmap_mod = @import("cmap.zig");
const Head = @import("head.zig").Head;
const Hhea = @import("hhea.zig").Hhea;
const Hmtx = @import("hmtx.zig").Hmtx;
const Maxp = @import("maxp.zig").Maxp;
const Os2 = @import("os2.zig").Os2;
const Post = @import("post.zig").Post;
const name_mod = @import("name.zig");

const GlyphId = reader.GlyphId;
const Tag = reader.Tag;
const KnownTag = sfnt.KnownTag;
pub const TableDir = sfnt.TableDir;
pub const NameTable = name_mod.NameTable;

/// Font-wide metrics in design units.
pub const FontMetrics = struct {
    ascender: i16,
    descender: i16,
    line_gap: i16,
    cap_height: i16,
    x_height: i16,
    underline_pos: i16,
    underline_thickness: i16,
    strikeout_pos: i16,
    strikeout_thickness: i16,
    units_per_em: u16,
};

/// Style attributes used for font matching.
pub const Style = struct {
    /// CSS weight, 1..1000 (OS/2 usWeightClass).
    weight: u16,
    /// OS/2 usWidthClass, 1 (ultra-condensed) .. 9 (ultra-expanded).
    width: u16,
    italic: bool,
    oblique: bool,
    monospace: bool,
};

/// Outline format of a face.
pub const OutlineKind = enum { glyf, cff, cff2, none };

/// One face: views into borrowed bytes plus the parsed headers. Immutable
/// after `init`, so it may be shared across threads.
pub const Face = struct {
    /// The whole file (all faces of a collection).
    bytes: []const u8,
    /// Face index within a collection.
    index: u32,
    tables: TableDir,
    units_per_em: u16,
    num_glyphs: u16,
    loca_long: bool,
    outline_kind: OutlineKind,
    head: Head,
    hhea: Hhea,
    hmtx: Hmtx,
    os2: ?Os2,
    post: ?Post,
    /// The chosen Unicode cmap subtable; null when the font has none.
    cmap: ?cmap_mod.Cmap,
    /// Optional lazily built BMP pages; see `attachPageCache`.
    page_cache: ?*cmap_mod.BmpPageCache = null,

    /// Opens face `index` of `bytes` (a plain sfnt or a TTC).
    pub fn init(bytes: []const u8, index: u32) error{ Malformed, Unsupported, IndexOutOfRange }!Face {
        const off = try sfnt.faceOffset(bytes, index);
        const dir = try TableDir.parse(bytes, off);
        const head_bytes = dir.get(bytes, .head) orelse return error.Unsupported;
        const maxp_bytes = dir.get(bytes, .maxp) orelse return error.Unsupported;
        const hhea_bytes = dir.get(bytes, .hhea) orelse return error.Unsupported;
        const hmtx_bytes = dir.get(bytes, .hmtx) orelse return error.Unsupported;
        const head = try Head.parse(head_bytes);
        const maxp = try Maxp.parse(maxp_bytes);
        const hhea = try Hhea.parse(hhea_bytes);
        const kind: OutlineKind = if (dir.get(bytes, .glyf) != null and dir.get(bytes, .loca) != null)
            .glyf
        else if (dir.get(bytes, .cff2) != null)
            .cff2
        else if (dir.get(bytes, .cff) != null)
            .cff
        else
            .none;
        var face: Face = .{
            .bytes = bytes,
            .index = index,
            .tables = dir,
            .units_per_em = head.units_per_em,
            .num_glyphs = maxp.num_glyphs,
            .loca_long = head.loca_long,
            .outline_kind = kind,
            .head = head,
            .hhea = hhea,
            .hmtx = Hmtx.init(hmtx_bytes, hhea.number_of_hmetrics, maxp.num_glyphs),
            .os2 = if (dir.get(bytes, .os2)) |t| Os2.parse(t) catch null else null,
            .post = if (dir.get(bytes, .post)) |t| Post.parse(t) catch null else null,
            .cmap = null,
        };
        if (dir.get(bytes, .cmap)) |t| face.cmap = cmap_mod.Cmap.initGlyphs(t, maxp.num_glyphs) catch null;
        return face;
    }

    /// Number of faces in `bytes`: the TTC count, or 1 for a plain sfnt.
    pub fn faceCount(bytes: []const u8) error{Malformed}!u32 {
        return sfnt.faceCount(bytes);
    }

    /// The bytes of table `t`, if present.
    pub fn table(f: *const Face, t: Tag) ?[]const u8 {
        return f.tables.find(f.bytes, t);
    }

    /// The bytes of a known table, if present.
    pub fn knownTable(f: *const Face, k: KnownTag) ?[]const u8 {
        return f.tables.get(f.bytes, k);
    }

    /// Uses `pc` for BMP lookups beyond page 0. `pc` must outlive the face
    /// and every copy of it.
    pub fn attachPageCache(f: *Face, pc: *cmap_mod.BmpPageCache) void {
        f.page_cache = pc;
    }

    /// The glyph for `cp`; 0 (.notdef) when unmapped.
    pub inline fn glyphIndex(f: *const Face, cp: u21) GlyphId {
        const c = &(f.cmap orelse return 0);
        if (cp < 256) return c.page0[cp];
        if (f.page_cache) |pc| return pc.lookup(c, cp);
        return c.lookupSlow(cp);
    }

    /// The glyph for variation sequence `cp` + `vs` (cmap format 14), the
    /// default glyph when the sequence uses it, or null when not supported.
    pub fn glyphVariant(f: *const Face, cp: u21, vs: u21) ?GlyphId {
        const c = &(f.cmap orelse return null);
        return switch (c.lookupVariant(cp, vs)) {
            .not_found => null,
            .use_default => f.glyphIndex(cp),
            .glyph => |g| g,
        };
    }

    /// Advance width of `gid` (default instance, design units).
    pub fn advance(f: *const Face, gid: GlyphId) u16 {
        return f.hmtx.advance(gid);
    }

    /// Left side bearing of `gid` (default instance, design units).
    pub fn lsb(f: *const Face, gid: GlyphId) i16 {
        return f.hmtx.lsb(gid);
    }

    /// Font-wide metrics following the OS/2 USE_TYPO_METRICS rule.
    pub fn metrics(f: *const Face) FontMetrics {
        var m: FontMetrics = .{
            .ascender = f.hhea.ascender,
            .descender = f.hhea.descender,
            .line_gap = f.hhea.line_gap,
            .cap_height = 0,
            .x_height = 0,
            .underline_pos = 0,
            .underline_thickness = 0,
            .strikeout_pos = 0,
            .strikeout_thickness = 0,
            .units_per_em = f.units_per_em,
        };
        if (f.os2) |o| {
            if (o.fs_selection & Os2.sel_use_typo_metrics != 0) {
                m.ascender = o.typo_ascender;
                m.descender = o.typo_descender;
                m.line_gap = o.typo_line_gap;
            } else if (m.ascender == 0 and m.descender == 0 and m.line_gap == 0) {
                m.ascender = @intCast(@min(o.win_ascent, std.math.maxInt(i16)));
                m.descender = -@as(i16, @intCast(@min(o.win_descent, std.math.maxInt(i16))));
            }
            m.cap_height = o.cap_height;
            m.x_height = o.x_height;
            m.strikeout_pos = o.strikeout_position;
            m.strikeout_thickness = o.strikeout_size;
        }
        if (f.post) |p| {
            m.underline_pos = p.underline_position;
            m.underline_thickness = p.underline_thickness;
        }
        return m;
    }

    /// The naming table (empty when absent).
    pub fn names(f: *const Face) NameTable {
        return .{ .data = f.knownTable(.name) orelse &.{} };
    }

    /// Weight, width, slant and monospace classification.
    pub fn style(f: *const Face) Style {
        var s: Style = .{ .weight = 400, .width = 5, .italic = false, .oblique = false, .monospace = false };
        if (f.os2) |o| {
            s.weight = o.weight_class;
            s.width = o.width_class;
            s.italic = o.fs_selection & Os2.sel_italic != 0;
            s.oblique = o.version >= 4 and o.fs_selection & Os2.sel_oblique != 0;
        } else if (f.head.mac_style & 1 != 0) s.weight = 700;
        if (f.head.mac_style & 2 != 0) s.italic = true;
        s.monospace = f.isMonospace();
        return s;
    }

    fn isMonospace(f: *const Face) bool {
        if (f.post) |p| if (p.is_fixed_pitch) return true;
        if (f.os2) |o| {
            // PANOSE family kind 2 (Latin text): bProportion 9 is monospaced.
            if (o.panose[0] == 2 and o.panose[3] == 9) return true;
        }
        // All non-zero advances equal, sampling at most 512 glyphs.
        const n = @min(f.num_glyphs, 512);
        var width: u16 = 0;
        var seen: u32 = 0;
        for (0..n) |g| {
            const a = f.advance(@intCast(g));
            if (a == 0) continue;
            if (width == 0) width = a else if (a != width) return false;
            seen += 1;
        }
        return seen > 1;
    }

    /// Verifies every table checksum and the `head` checksum adjustment
    /// (font DB "repair" mode; not done at init for cost).
    pub fn validateChecksums(f: *const Face) bool {
        var it = f.tables.records(f.bytes);
        while (it.next()) |rec| {
            if (rec.off > f.bytes.len or f.bytes.len - rec.off < rec.len) return false;
            var data = f.bytes[rec.off..][0..rec.len];
            var sum = sfnt.checksum(data);
            if (rec.tag == reader.tag("head") and data.len >= 12) {
                // checkSumAdjustment is computed with itself as zero.
                sum -%= std.mem.readInt(u32, data[8..12], .big);
            }
            if (sum != rec.checksum) return false;
        }
        return true;
    }
};

/// A read-only memory map of a font file (or, when mapping fails, the file
/// read into memory). `bytes()` stays valid until `close`.
pub const MappedFont = struct {
    map: ?std.Io.File.MemoryMap,
    file: ?std.Io.File,
    owned: ?[]u8,
    gpa: ?std.mem.Allocator,

    /// Maps `path` (relative to `dir`) read-only. Falls back to reading the
    /// file with `std.heap.page_allocator` when mapping fails.
    pub fn open(io: std.Io, dir: std.Io.Dir, path: []const u8) !MappedFont {
        return openAlloc(io, dir, path, std.heap.page_allocator);
    }

    /// `open` with an explicit allocator for the read fallback.
    pub fn openAlloc(io: std.Io, dir: std.Io.Dir, path: []const u8, gpa: std.mem.Allocator) !MappedFont {
        var file = try dir.openFile(io, path, .{});
        const len = file.length(io) catch |e| {
            file.close(io);
            return e;
        };
        if (len > 0) {
            if (file.createMemoryMap(io, .{
                .len = @intCast(len),
                .protection = .{ .read = true, .write = false },
                .populate = false,
            })) |map| {
                return .{ .map = map, .file = file, .owned = null, .gpa = null };
            } else |_| {}
        }
        file.close(io);
        const data = try dir.readFileAlloc(io, path, gpa, .limited(256 << 20));
        return .{ .map = null, .file = null, .owned = data, .gpa = gpa };
    }

    /// Unmaps (or frees) the bytes and closes the file.
    pub fn close(self: *MappedFont, io: std.Io) void {
        if (self.map) |*m| m.destroy(io);
        if (self.file) |f| f.close(io);
        if (self.owned) |o| self.gpa.?.free(o);
        self.* = undefined;
    }

    /// The file contents.
    pub fn bytes(self: *const MappedFont) []const u8 {
        if (self.map) |m| return m.memory;
        return self.owned.?;
    }
};

test {
    _ = @import("face_test.zig");
}
