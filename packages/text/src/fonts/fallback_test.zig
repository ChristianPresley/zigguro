//! Fallback resolution against the test fonts.

const std = @import("std");
const testing = std.testing;
const ot = @import("../ot/root.zig");
const FaceInstance = @import("../ot/var/instance.zig").FaceInstance;
const fonts = @import("../testing/fonts.zig");
const registry = @import("registry.zig");
const fallback = @import("fallback.zig");

/// A loaded test font.
pub const TestFont = struct {
    bytes: []u8,
    face: ot.Face,
    inst: FaceInstance,

    /// Loads `name` in place (the instance points at the face).
    pub fn load(tf: *TestFont, gpa: std.mem.Allocator, name: []const u8) !void {
        tf.bytes = try fonts.font(gpa, name);
        errdefer gpa.free(tf.bytes);
        tf.face = try ot.Face.init(tf.bytes, 0);
        tf.inst = try FaceInstance.init(gpa, &tf.face, &.{});
    }

    /// Frees the font.
    pub fn deinit(tf: *TestFont, gpa: std.mem.Allocator) void {
        tf.inst.deinit(gpa);
        gpa.free(tf.bytes);
    }
};

test "fallback: emoji presentation" {
    const ep = fallback.emojiPresentation;
    try testing.expect(ep("\u{1F600}"));
    try testing.expect(!ep("\u{263A}"));
    try testing.expect(ep("\u{263A}\u{FE0F}"));
    try testing.expect(!ep("\u{1F600}\u{FE0E}"));
    try testing.expect(ep("1\u{FE0F}\u{20E3}"));
    try testing.expect(ep("\u{1F1EF}\u{1F1F5}"));
    try testing.expect(ep("\u{1F44D}\u{1F3FD}"));
    try testing.expect(!ep("a"));
    try testing.expect(!ep("#"));
}

test "fallback: cluster resolves along the chain" {
    const gpa = testing.allocator;
    var inter: TestFont = undefined;
    try inter.load(gpa, "Inter[opsz,wght].ttf");
    defer inter.deinit(gpa);
    var han: TestFont = undefined;
    try han.load(gpa, "SourceHanSansJP-Subset.otf");
    defer han.deinit(gpa);
    var emoji: TestFont = undefined;
    try emoji.load(gpa, "NotoColorEmoji-CBDT-Subset.ttf");
    defer emoji.deinit(gpa);

    var reg = registry.FontRegistry.init(gpa);
    defer reg.deinit();
    const i_inter = try reg.register(&inter.inst);
    const i_han = try reg.register(&han.inst);
    const i_emoji = try reg.register(&emoji.inst);
    try testing.expectEqual(i_inter, try reg.register(&inter.inst));
    try testing.expect(reg.get(i_emoji).color and !reg.get(i_inter).color);

    var fb = fallback.Fallback.init(gpa, &reg);
    defer fb.deinit();
    const chain = try fb.chainOf(&.{ i_inter, i_han, i_emoji });
    try testing.expectEqual(chain, try fb.chainOf(&.{ i_inter, i_han, i_emoji }));
    try testing.expectEqual(i_inter, fb.resolve(chain, "a", .default));
    try testing.expectEqual(i_inter, fb.resolve(chain, "e\u{301}", .default));
    try testing.expectEqual(i_han, fb.resolve(chain, "\u{65E5}", .default));
    try testing.expectEqual(i_emoji, fb.resolve(chain, "\u{1F600}", .default));
    // Nothing covers it: the primary draws .notdef.
    try testing.expectEqual(i_inter, fb.resolve(chain, "\u{10FFFD}", .default));
}
