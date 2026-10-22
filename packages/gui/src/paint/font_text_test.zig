//! `FontText` with real fonts from zg_text's test corpus (Inter and
//! JetBrains Mono, OFL).

const std = @import("std");
const zg_text = @import("zg_text");
const FontText = @import("font_text.zig").FontText;

const testing = std.testing;

/// Font bytes read from zg_text's testdata.
pub const TestFonts = struct {
    ui: []u8,
    mono: []u8,

    pub fn load(gpa: std.mem.Allocator) !TestFonts {
        const ui = try read(gpa, "Inter[opsz,wght].ttf");
        errdefer gpa.free(ui);
        return .{ .ui = ui, .mono = try read(gpa, "JetBrainsMono[wght].ttf") };
    }

    fn read(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/testdata/fonts/{s}", .{ zg_text.dev.package_root, name });
        return std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(4 << 20));
    }

    pub fn deinit(f: TestFonts, gpa: std.mem.Allocator) void {
        gpa.free(f.ui);
        gpa.free(f.mono);
    }
};

test "metrics, advances and glyph quads" {
    const gpa = testing.allocator;
    const fonts = try TestFonts.load(gpa);
    defer fonts.deinit(gpa);
    const ft = try FontText.create(gpa, .{ .ui = fonts.ui, .mono = fonts.mono });
    defer ft.destroy();
    const ts = ft.system();

    const m = ts.metrics(.{ .size = 13 });
    try testing.expect(m.ascent > 9 and m.ascent < 15);
    try testing.expect(m.descent > 1 and m.descent < 6);
    try testing.expect(m.line_h >= 15 and m.line_h <= 20);

    // Proportional UI text, fixed-width code.
    try testing.expect(ts.advance(.{ .size = 13 }, 'i') < ts.advance(.{ .size = 13 }, 'W'));
    const mono_i = ts.advance(.{ .font = .mono, .size = 13 }, 'i');
    try testing.expectApproxEqAbs(mono_i, ts.advance(.{ .font = .mono, .size = 13 }, 'W'), 0.001);

    // A glyph lands in the atlas with normalised uvs and a sane box.
    const q = ts.glyph(.{ .size = 13 }, 'H', .{ .x = 10.3, .y = 20 }).?;
    try testing.expect(q.uv[0] >= 0 and q.uv[2] > q.uv[0] and q.uv[2] <= 1);
    try testing.expect(q.uv[1] >= 0 and q.uv[3] > q.uv[1] and q.uv[3] <= 1);
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(ft.pageSize())) * (q.uv[2] - q.uv[0]), q.dst[2], 0.001);
    try testing.expect(q.dst[1] < 20 and q.dst[1] + q.dst[3] > 19); // sits on the baseline
    try testing.expect(q.dst[3] > 7 and q.dst[3] < 13); // cap height at 13 px
    try testing.expectEqual(zg_text.cache.AtlasFormat.r8, q.format);
    try testing.expect(ts.glyph(.{ .size = 13 }, ' ', .{ .x = 0, .y = 0 }) == null);

    var ups: std.ArrayList(zg_text.cache.AtlasUpdate) = .empty;
    defer ups.deinit(gpa);
    try ft.takeUpdates(&ups);
    try testing.expectEqual(@as(usize, 1), ups.items.len);
    // The same glyph again is a cache hit: nothing new to upload.
    _ = ts.glyph(.{ .size = 13 }, 'H', .{ .x = 40.3, .y = 20 }).?;
    ups.clearRetainingCapacity();
    try ft.takeUpdates(&ups);
    try testing.expectEqual(@as(usize, 0), ups.items.len);

    // At scale 2 the bitmap is twice the size, the logical box the same.
    ft.scale = 2;
    const q2 = ts.glyph(.{ .size = 13 }, 'H', .{ .x = 10.3, .y = 20 }).?;
    try testing.expectApproxEqAbs(q.dst[3], q2.dst[3], 1);
    try testing.expectApproxEqAbs(2 * q2.dst[3], @as(f32, @floatFromInt(ft.pageSize())) * (q2.uv[3] - q2.uv[1]), 0.001);
}

test "unmapped codepoints fall back to the other face, then notdef" {
    const gpa = testing.allocator;
    const fonts = try TestFonts.load(gpa);
    defer fonts.deinit(gpa);
    const ft = try FontText.create(gpa, .{ .ui = fonts.ui, .mono = fonts.mono });
    defer ft.destroy();
    const ts = ft.system();
    // Box drawing is in JetBrains Mono, not in the Inter subset.
    try testing.expect(ts.advance(.{ .size = 13 }, 0x2500) > 0);
    try testing.expect(ts.glyph(.{ .size = 13 }, 0x2500, .{ .x = 0, .y = 20 }) != null);
    // Neither face has U+10FFFD: notdef, still drawn.
    try testing.expect(ts.advance(.{ .size = 13 }, 0x10FFFD) > 0);
}

test "shaped lines: kerning, widths and glyph quads" {
    const gpa = testing.allocator;
    const fonts = try TestFonts.load(gpa);
    defer fonts.deinit(gpa);
    const ft = try FontText.create(gpa, .{ .ui = fonts.ui, .mono = fonts.mono });
    defer ft.destroy();
    const ts = ft.system();
    const st: @import("text.zig").TextStyle = .{ .size = 32 };

    // Inter kerns "AV": the shaped width is less than the advances.
    const sum = ts.advance(st, 'A') + ts.advance(st, 'V');
    const w = ts.width(st, "AV");
    try testing.expect(w < sum - 0.5);
    const sh = ts.shape(st, "AV").?;
    try testing.expectEqual(@as(usize, 2), sh.glyphs.len);
    try testing.expectApproxEqAbs(w, sh.width, 0.01);
    try testing.expect(sh.glyphs[1].x < ts.advance(st, 'A') - 0.5);
    try testing.expect(ts.shapedGlyph(st, sh.glyphs[0].id, .{ .x = 10, .y = 40 }) != null);

    // Unshaped styles keep per-codepoint advances.
    var flat = st;
    flat.shape = false;
    try testing.expect(ts.shape(flat, "AV") == null);
    try testing.expectApproxEqAbs(sum, ts.width(flat, "AV"), 0.01);

    // Mono text keeps its grid width; a codepoint missing from the mono
    // face falls back to the UI face.
    const mono: @import("text.zig").TextStyle = .{ .font = .mono, .size = 13 };
    try testing.expectApproxEqAbs(ts.advance(mono, 'x') * 4, ts.width(mono, "abcd"), 0.05);
    try testing.expectEqual(@as(f32, 0), ts.width(st, ""));
}

test "shaped text paints through PaintCx" {
    const gpa = testing.allocator;
    const fonts = try TestFonts.load(gpa);
    defer fonts.deinit(gpa);
    const ft = try FontText.create(gpa, .{ .ui = fonts.ui, .mono = fonts.mono });
    defer ft.destroy();
    const canvas = @import("canvas.zig");
    var ops: canvas.OpList = .{};
    defer ops.deinit(gpa);
    var pc: @import("paint_cx.zig").PaintCx = .{ .gpa = gpa, .ops = &ops, .theme = &@import("../theme/theme.zig").zigguro_dark, .text_sys = ft.system(), .size = .{ .w = 200, .h = 40 } };
    pc.textLine("AVA", .{ .size = 32 }, @import("../core/geom.zig").Color.hex(0xffffff), .{ .x = 0, .y = 30 });
    try testing.expectEqual(@as(usize, 1), ops.ops.items.len);
    try testing.expectEqual(@as(u32, 3), ops.ops.items[0].glyphs.len);
}
