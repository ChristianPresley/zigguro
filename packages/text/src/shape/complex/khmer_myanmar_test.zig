//! Khmer and Myanmar shaper tests: selection, syllables and the Khmer
//! split vowels. Shaped goldens are in `shaper_test.zig`.

const std = @import("std");
const testing = std.testing;
const default = @import("default.zig");
const khmer = @import("khmer.zig");
const myanmar = @import("myanmar.zig");
const tables = @import("indic_tables.zig");
const dotted = @import("dotted_circle.zig");
const Buffer = @import("../buffer.zig").Buffer;
const ot = @import("../../ot/root.zig");

test "khmer and myanmar selection" {
    try testing.expectEqualStrings("khmer", default.select(.Khmr, null).name);
    try testing.expectEqualStrings("khmer", default.select(.Khmr, ot.tag("DFLT")).name);
    try testing.expectEqualStrings("myanmar", default.select(.Mymr, ot.tag("mym2")).name);
    try testing.expectEqualStrings("myanmar", default.select(.Mymr, null).name);
    try testing.expectEqualStrings("default", default.select(.Mymr, ot.tag("mymr")).name);
    try testing.expectEqualStrings("default", default.select(.Mymr, ot.tag("latn")).name);
}

fn syllables(comptime find: anytype, text: []const u21) ![]u8 {
    var b: Buffer = .init(testing.allocator);
    defer b.deinit();
    for (text, 0..) |cp, i| {
        try b.infos.append(testing.allocator, .{ .cp = cp, .cluster = @intCast(i) });
        b.infos.items[i].shaper = @intFromEnum(tables.categories(cp).cat);
    }
    try find(testing.allocator, &b);
    const out = try testing.allocator.alloc(u8, text.len);
    for (out, b.infos.items) |*o, g| o.* = g.syllable;
    return out;
}

test "khmer syllables" {
    // KA COENG KA AA | SPACE | (broken) COENG KA.
    const s = try syllables(khmer.findSyllables, &.{ 0x1780, 0x17D2, 0x1780, 0x17B6, ' ', 0x17D2, 0x1780 });
    defer testing.allocator.free(s);
    const C: u8 = @intFromEnum(khmer.SyllableType.consonant);
    const B: u8 = @intFromEnum(khmer.SyllableType.broken);
    const N: u8 = @intFromEnum(khmer.SyllableType.non_khmer);
    try testing.expectEqualSlices(u8, &.{ 0x10 | C, 0x10 | C, 0x10 | C, 0x10 | C, 0x20 | N, 0x30 | B, 0x30 | B }, s);
}

test "myanmar syllables" {
    // Kinzi + GA | SPACE | (broken) E.
    const s = try syllables(myanmar.findSyllables, &.{ 0x1004, 0x103A, 0x1039, 0x1002, ' ', 0x1031 });
    defer testing.allocator.free(s);
    const C: u8 = @intFromEnum(myanmar.SyllableType.consonant);
    const B: u8 = @intFromEnum(myanmar.SyllableType.broken);
    const N: u8 = @intFromEnum(myanmar.SyllableType.non_myanmar);
    try testing.expectEqualSlices(u8, &.{ 0x10 | C, 0x10 | C, 0x10 | C, 0x10 | C, 0x20 | N, 0x30 | B }, s);
    try testing.expectEqual(@as(u4, B), dotted.syllableType(.{ .cp = 0, .cluster = 0, .syllable = 0x30 | B }));
}

test "khmer split vowels" {
    const d = khmer.shaper.decompose.?;
    try testing.expectEqual(@as(u21, 0x17C1), d(0x17BE).?.a);
    try testing.expectEqual(@as(u21, 0x17BE), d(0x17BE).?.b);
    try testing.expectEqual(@as(u21, 0x17C1), d(0x17C5).?.a);
    try testing.expect(d(0x1780) == null);
    // Not recomposed: U+17C1 is a mark.
    try testing.expect(khmer.shaper.compose.?(0x17C1, 0x17B8) == null);
}
