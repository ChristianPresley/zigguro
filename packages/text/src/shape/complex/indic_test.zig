//! Indic shaper tests: configuration, syllables, normalization hooks and
//! selection. Shaped goldens are in `shaper_test.zig`.

const std = @import("std");
const testing = std.testing;
const default = @import("default.zig");
const indic = @import("indic.zig");
const tables = @import("indic_tables.zig");
const Buffer = @import("../buffer.zig").Buffer;
const ot = @import("../../ot/root.zig");

test "indic configs" {
    try testing.expectEqual(@as(u21, 0x094D), indic.configFor(.Deva).virama);
    try testing.expectEqual(indic.RephPosition.after_sub, indic.configFor(.Beng).reph_pos);
    try testing.expectEqual(indic.RephMode.explicit, indic.configFor(.Telu).reph_mode);
    try testing.expectEqual(indic.BlwfMode.post_only, indic.configFor(.Knda).blwf_mode);
    try testing.expectEqual(indic.RephMode.log_repha, indic.configFor(.Mlym).reph_mode);
    try testing.expect(!indic.configFor(.Latn).has_old_spec);
}

test "indic selection" {
    try testing.expectEqualStrings("indic", default.select(.Deva, ot.tag("dev2")).name);
    try testing.expectEqualStrings("indic", default.select(.Deva, ot.tag("deva")).name);
    try testing.expectEqualStrings("indic", default.select(.Mlym, null).name);
    try testing.expectEqualStrings("use", default.select(.Taml, ot.tag("tml3")).name);
    try testing.expectEqualStrings("default", default.select(.Guru, ot.tag("latn")).name);
}

test "indic syllables" {
    // RA VIRAMA KA I | SPACE | (broken) I | SPACE | KA VIRAMA ZWNJ.
    const text = [_]u21{ 0x0930, 0x094D, 0x0915, 0x093F, ' ', 0x093F, ' ', 0x0915, 0x094D, 0x200C };
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    for (text, 0..) |cp, i| {
        try b.infos.append(testing.allocator, .{ .cp = cp, .cluster = @intCast(i) });
        b.infos.items[i].shaper = @intFromEnum(tables.categories(cp).cat);
    }
    try indic.findSyllables(testing.allocator, &b);
    const T = indic.SyllableType;
    const want = [_]struct { u8, T }{
        .{ 1, .consonant }, .{ 1, .consonant }, .{ 1, .consonant }, .{ 1, .consonant },
        .{ 2, .non_indic }, .{ 3, .broken },    .{ 4, .non_indic }, .{ 5, .consonant },
        .{ 5, .consonant }, .{ 5, .consonant },
    };
    for (want, b.infos.items) |w, gi| {
        try testing.expectEqual(w[0], gi.syllable >> 4);
        try testing.expectEqual(@intFromEnum(w[1]), @as(u4, @truncate(gi.syllable)));
    }
}

test "indic normalization hooks" {
    const d = indic.shaper.decompose.?;
    try testing.expect(d(0x0931) == null); // DEVANAGARI RRA stays whole
    try testing.expect(d(0x09DC) == null);
    try testing.expectEqual(@as(u21, 0x0928), d(0x0929).?.a); // NNNA decomposes
    const c = indic.shaper.compose.?;
    try testing.expectEqual(@as(?u21, 0x09DF), c(0x09AF, 0x09BC)); // BENGALI YYA
    try testing.expect(c(0x09C7, 0x09BE) == null); // split matras stay split
}
