//! GDEF: glyph classes, mark attachment classes, mark glyph sets and the
//! item variation store used by GPOS VariationIndex tables.

const std = @import("std");
const reader = @import("reader.zig");
const GlyphId = reader.GlyphId;
const readAt = reader.readAt;
const lc = @import("layout_common.zig");
const ClassDef = lc.ClassDef;
const Coverage = lc.Coverage;
const ItemVariationStore = @import("var/ivs.zig").ItemVariationStore;

/// GDEF glyph classes.
pub const GlyphClass = enum(u2) { unclassified, base, ligature, mark };

/// Glyph property bits, HarfBuzz-compatible: the class bits equal the
/// LookupFlag ignore bits, and a mark's attachment class sits in the high
/// byte (as LookupFlag's MarkAttachmentType does).
pub const GlyphProps = struct {
    pub const base: u16 = 0x02;
    pub const ligature: u16 = 0x04;
    pub const mark: u16 = 0x08;
    /// Set by any GSUB substitution of the glyph.
    pub const substituted: u16 = 0x10;
    /// Produced by a ligature substitution.
    pub const ligated: u16 = 0x20;
    /// Produced by a multiple substitution.
    pub const multiplied: u16 = 0x40;
    /// Bits kept when the class is recomputed.
    pub const preserve: u16 = substituted | ligated | multiplied;
    pub const class_mask: u16 = base | ligature | mark;
};

/// A GDEF view.
pub const Gdef = struct {
    glyph_classes: ClassDef = .empty,
    mark_attach: ClassDef = .empty,
    mark_sets: []const u8 = &.{},
    mark_set_count: u16 = 0,
    var_store: ?ItemVariationStore = null,
    has_glyph_classes: bool = false,

    /// Parses GDEF 1.0–1.3. Broken sub-tables are treated as absent.
    pub fn init(bytes: []const u8) reader.Error!Gdef {
        const major = try readAt(u16, bytes, 0);
        const minor = try readAt(u16, bytes, 2);
        if (major != 1) return error.Malformed;
        var g: Gdef = .{};
        const gc = try readAt(u16, bytes, 4);
        if (gc != 0) if (ClassDef.init(bytes, gc)) |c| {
            g.glyph_classes = c;
            g.has_glyph_classes = true;
        } else |_| {};
        const mac = try readAt(u16, bytes, 10);
        g.mark_attach = ClassDef.init(bytes, mac) catch .empty;
        if (minor >= 2) {
            const ms = readAt(u16, bytes, 12) catch 0;
            if (ms != 0) if (reader.sub(bytes, ms)) |d| {
                if ((readAt(u16, d, 0) catch 0) == 1) {
                    const n = readAt(u16, d, 2) catch 0;
                    if (reader.subLen(d, 4, @as(usize, n) * 4)) |_| {
                        g.mark_sets = d;
                        g.mark_set_count = n;
                    } else |_| {}
                }
            } else |_| {};
        }
        if (minor >= 3) {
            const vs = readAt(u32, bytes, 14) catch 0;
            if (vs != 0) if (reader.sub(bytes, vs)) |d| {
                g.var_store = ItemVariationStore.init(d) catch null;
            } else |_| {};
        }
        return g;
    }

    /// The glyph's GDEF class.
    pub fn glyphClass(g: *const Gdef, gid: GlyphId) GlyphClass {
        return switch (g.glyph_classes.class(gid)) {
            1 => .base,
            2 => .ligature,
            3 => .mark,
            else => .unclassified,
        };
    }

    /// The glyph's mark attachment class (0 when none).
    pub fn markAttachClass(g: *const Gdef, gid: GlyphId) u16 {
        return g.mark_attach.class(gid);
    }

    /// True when mark glyph set `set` covers `gid`.
    pub fn inMarkSet(g: *const Gdef, set: u16, gid: GlyphId) bool {
        if (set >= g.mark_set_count) return false;
        const off = std.mem.readInt(u32, g.mark_sets[4 + @as(usize, set) * 4 ..][0..4], .big);
        const c = Coverage.init(g.mark_sets, off) catch return false;
        return c.index(gid) != null;
    }

    /// HarfBuzz-style glyph props for `gid` (see `GlyphProps`).
    pub fn glyphProps(g: *const Gdef, gid: GlyphId) u16 {
        return switch (g.glyphClass(gid)) {
            .base => GlyphProps.base,
            .ligature => GlyphProps.ligature,
            .mark => GlyphProps.mark | (@as(u16, @truncate(g.markAttachClass(gid))) << 8),
            .unclassified => 0,
        };
    }
};

test "gdef: classes, attach classes and mark sets" {
    var b: lc.TestBytes = .{ .gpa = std.testing.allocator };
    defer b.deinit();
    // GDEF 1.2: classes @14, attach classes @28, mark sets @38.
    b.u16s(&.{ 1, 2, 14, 0, 0, 28, 38 });
    b.u16s(&.{ 1, 10, 4, 1, 2, 3, 3 }); // ClassDef1: 10 base, 11 lig, 12/13 mark
    b.u16s(&.{ 1, 12, 2, 1, 2 }); // attach: 12 → 1, 13 → 2
    b.u16s(&.{ 1, 1 }); // mark sets: 1 set
    b.u32_(8);
    b.u16s(&.{ 1, 1, 13 }); // coverage {13}
    const g = try Gdef.init(b.buf.items);
    try std.testing.expectEqual(GlyphClass.base, g.glyphClass(10));
    try std.testing.expectEqual(GlyphClass.ligature, g.glyphClass(11));
    try std.testing.expectEqual(GlyphClass.mark, g.glyphClass(13));
    try std.testing.expectEqual(GlyphClass.unclassified, g.glyphClass(99));
    try std.testing.expectEqual(@as(u16, 2), g.markAttachClass(13));
    try std.testing.expect(g.inMarkSet(0, 13) and !g.inMarkSet(0, 12) and !g.inMarkSet(1, 13));
    try std.testing.expectEqual(GlyphProps.mark | 0x200, g.glyphProps(13));
    try std.testing.expect(g.has_glyph_classes);
}
