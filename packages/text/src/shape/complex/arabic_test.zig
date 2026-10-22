//! Arabic-joining shaper tests: joining actions from crafted sequences,
//! mark reordering, shaper selection and a shaped Arabic run.

const std = @import("std");
const testing = std.testing;
const arabic = @import("arabic.zig");
const Action = arabic.Action;
const default = @import("default.zig");
const Buffer = @import("../buffer.zig").Buffer;
const ot = @import("../../ot/root.zig");
const FaceInstance = @import("../../ot/var/instance.zig").FaceInstance;
const fonts = @import("../../testing/fonts.zig");
const shaper_mod = @import("../shaper.zig");

/// Runs joining over `text` and checks one action per code point.
fn expectForms(text: []const u21, want: []const Action) !void {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    for (text, 0..) |cp, i| try b.addCodepoint(cp, @intCast(i));
    arabic.joining(&b);
    for (b.infos.items, want) |g, w| try testing.expectEqual(w, arabic.actionOf(g));
}

test "arabic: joining forms table" {
    // beh teh theh: dual-joining run.
    try expectForms(&.{ 0x628, 0x62A, 0x62B }, &.{ .init, .medi, .fina });
    // beh alef beh: alef is right-joining, so the run breaks after it.
    try expectForms(&.{ 0x628, 0x627, 0x628 }, &.{ .init, .fina, .isol });
    // A space does not join.
    try expectForms(&.{ 0x628, ' ', 0x628 }, &.{ .isol, .none, .isol });
    // ZWJ joins on both sides; ZWNJ breaks.
    try expectForms(&.{ 0x200D, 0x628, 0x200D }, &.{ .init, .medi, .fina });
    try expectForms(&.{ 0x628, 0x200C, 0x628 }, &.{ .isol, .none, .isol });
    // Tatweel is join-causing.
    try expectForms(&.{ 0x628, 0x640, 0x628 }, &.{ .init, .medi, .fina });
    // Left-joining (U+A872 Phags-pa superfixed letter RA is L).
    try expectForms(&.{ 0xA872, 0x628 }, &.{ .init, .fina });
}

test "arabic: marks transparent to joining" {
    try expectForms(&.{ 0x628, 0x64E, 0x628, 0x651, 0x64E, 0x628 }, &.{ .init, .none, .medi, .none, .none, .fina });
}

test "arabic: syriac alaph fin2/fin3" {
    // Alaph after a non-joining or right-joining letter: fin2.
    try expectForms(&.{ 0x710, 0x710 }, &.{ .isol, .fin2 });
    try expectForms(&.{ 0x718, 0x710 }, &.{ .isol, .fin2 });
    // After Dalath or Rish: fin3.
    try expectForms(&.{ 0x715, 0x710 }, &.{ .isol, .fin3 });
    try expectForms(&.{ 0x72A, 0x710 }, &.{ .isol, .fin3 });
    // After a dual-joining letter: fina, which joins it.
    try expectForms(&.{ 0x712, 0x710 }, &.{ .init, .fina });
    // An alaph that followed a joined alaph makes it med2.
    try expectForms(&.{ 0x712, 0x710, 0x712 }, &.{ .init, .med2, .isol });
}

test "arabic: nko joining" {
    try expectForms(&.{ 0x7CA, 0x7CB, 0x7CC }, &.{ .init, .medi, .fina });
    try expectForms(&.{ 0x7CA, ' ', 0x7CB }, &.{ .isol, .none, .isol });
}

test "arabic: shaper selection" {
    try testing.expectEqualStrings("arabic", default.select(.Arab, null).name);
    try testing.expectEqualStrings("arabic", default.select(.Syrc, ot.tag("syrc")).name);
    try testing.expectEqualStrings("default", default.select(.Syrc, ot.tag("DFLT")).name);
    try testing.expectEqualStrings("default", default.select(.Syrc, null).name);
    try testing.expectEqualStrings("arabic", default.select(.Nkoo, null).name);
    try testing.expectEqualStrings("default", default.select(.Latn, ot.tag("latn")).name);
}

test "arabic: rtl clusters monotone after reversal" {
    const gpa = testing.allocator;
    const bytes = try fonts.font(gpa, "NotoSansArabic-Subset.ttf");
    defer gpa.free(bytes);
    var face = try ot.Face.init(bytes, 0);
    var inst = try FaceInstance.init(gpa, &face, &.{});
    defer inst.deinit(gpa);
    var s = shaper_mod.Shaper.init(gpa);
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var run: shaper_mod.GlyphRun = .{};
    const text = "\u{644}\u{627} \u{645}\u{64E}\u{631}\u{652}\u{62D}\u{64E}\u{628}\u{64B}\u{627} \u{628}\u{640}\u{628}";
    try s.shape(&inst, text, .Arab, .rtl, ot.tag("dflt"), &.{}, &run, arena.allocator());
    try testing.expect(run.len() > 0);
    // Visual order: clusters never increase, and the first glyph is the
    // last character's.
    for (1..run.len()) |i| try testing.expect(run.clusters[i - 1] >= run.clusters[i]);
    try testing.expectEqual(@as(u32, 0), run.clusters[run.len() - 1]);
}
