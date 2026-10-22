//! Dotted circles for broken syllables (HarfBuzz's
//! `hb_syllabic_insert_dotted_circles`), shared by the syllabic shapers:
//! a syllable the machine could only parse as broken (a mark with no base)
//! gets U+25CC as its base, after a leading repha.

const std = @import("std");
const Allocator = std.mem.Allocator;
const buffer = @import("../buffer.zig");
const Buffer = buffer.Buffer;
const GlyphInfo = buffer.GlyphInfo;
const Face = @import("../../ot/root.zig").Face;

/// U+25CC DOTTED CIRCLE.
pub const dotted_circle: u21 = 0x25CC;

/// Syllable types live in the low 4 bits of `GlyphInfo.syllable`, the
/// serial in the high 4.
pub inline fn syllableType(g: GlyphInfo) u4 {
    return @truncate(g.syllable);
}

/// The end of the syllable starting at `start`.
pub fn syllableEnd(infos: []const GlyphInfo, start: usize) usize {
    const s = infos[start].syllable;
    var e = start + 1;
    while (e < infos.len and infos[e].syllable == s) e += 1;
    return e;
}

/// Inserts a dotted circle at the start of each syllable of type
/// `broken_type`, after glyphs whose `shaper` category is `repha` (when
/// given). The circle takes the syllable's cluster, mask and syllable and
/// gets `category` as its `shaper` value and `position` as its
/// `shaper_aux` value. Does nothing when the font has no
/// dotted circle; returns whether any was inserted.
pub fn insertDottedCircles(b: *Buffer, face: *const Face, broken_type: u4, category: u8, repha: ?u8, position: u8) Allocator.Error!bool {
    const has_broken = for (b.infos.items) |g| {
        if (syllableType(g) == broken_type) break true;
    } else false;
    if (!has_broken) return false;
    const gid = face.glyphIndex(dotted_circle);
    if (gid == 0) return false;

    var i: usize = 0;
    var last_syllable: u8 = 0;
    var inserted = false;
    while (i < b.len()) {
        const cur = b.infos.items[i];
        if (cur.syllable == last_syllable or syllableType(cur) != broken_type) {
            i += 1;
            continue;
        }
        last_syllable = cur.syllable;
        if (repha) |r| {
            while (i < b.len() and b.infos.items[i].syllable == last_syllable and b.infos.items[i].shaper == r) i += 1;
        }
        // Like HarfBuzz, the circle carries no GDEF class.
        try b.insertAt(i, .{
            .gid = gid,
            .cluster = cur.cluster,
            .mask = cur.mask,
            .cp = dotted_circle,
            .syllable = cur.syllable,
            .gc = .So,
            .shaper = category,
            .shaper_aux = position,
        });
        inserted = true;
        i += 1;
    }
    return inserted;
}
