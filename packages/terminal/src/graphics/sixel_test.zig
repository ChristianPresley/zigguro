const std = @import("std");
const testing = std.testing;
const gpa = testing.allocator;
const Terminal = @import("../term/Terminal.zig");
const sixel = @import("sixel.zig");
const SixelDecoder = sixel.SixelDecoder;

fn decode(p2: u16, data: []const u8) !sixel.Image {
    var d: SixelDecoder = .init(gpa, p2, 64, 64);
    defer d.deinit();
    d.put(data);
    return d.finish() orelse error.NoImage;
}

fn px(img: sixel.Image, x: u32, y: u32) [4]u8 {
    return img.rgba[(y * img.w + x) * 4 ..][0..4].*;
}

const red = [4]u8{ 255, 0, 0, 255 };
const green = [4]u8{ 0, 255, 0, 255 };
const clear = [4]u8{ 0, 0, 0, 0 };

test "sixel: one band in one colour, bit 0 at the top" {
    // '~' is all six bits; 'A' (2) only the second row.
    const img = try decode(1, "#1;2;100;0;0~A");
    defer gpa.free(img.rgba);
    try testing.expectEqual(@as(u32, 2), img.w);
    try testing.expectEqual(@as(u32, 6), img.h);
    for (0..6) |y| try testing.expectEqual(red, px(img, 0, @intCast(y)));
    try testing.expectEqual(clear, px(img, 1, 0));
    try testing.expectEqual(red, px(img, 1, 1));
    try testing.expectEqual(clear, px(img, 1, 2));
}

test "sixel: repeats, carriage return overprint and new bands" {
    const img = try decode(1, "#1;2;100;0;0!3~$#2;2;0;100;0@-!2N");
    defer gpa.free(img.rgba);
    try testing.expectEqual(@as(u32, 3), img.w);
    // Two whole bands.
    try testing.expectEqual(@as(u32, 12), img.h);
    // '@' (1) overprints the top pixel of column 0 in green.
    try testing.expectEqual(green, px(img, 0, 0));
    try testing.expectEqual(red, px(img, 0, 1));
    try testing.expectEqual(red, px(img, 2, 5));
    // 'N' (15) in the second band: rows 6..9 of columns 0 and 1.
    try testing.expectEqual(green, px(img, 1, 9));
    try testing.expectEqual(clear, px(img, 1, 10));
    try testing.expectEqual(clear, px(img, 2, 6));
}

test "sixel: HLS registers (DEC hue: 0 blue, 120 red, 240 green) and the VT340 defaults" {
    const img = try decode(1, "#3;1;120;50;100~#4;1;240;50;100~#5;1;0;50;100~#2~");
    defer gpa.free(img.rgba);
    try testing.expectEqual(red, px(img, 0, 0));
    try testing.expectEqual(green, px(img, 1, 0));
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, px(img, 2, 0));
    // Register 2 is the VT340's red (80, 13, 13 percent).
    try testing.expectEqual([4]u8{ 204, 33, 33, 255 }, px(img, 3, 0));
}

test "sixel: P2 = 1 keeps unpainted pixels transparent, 0 fills them with register 0" {
    const t1 = try decode(1, "#1;2;100;0;0@");
    defer gpa.free(t1.rgba);
    try testing.expectEqual(clear, px(t1, 0, 1));
    const t0 = try decode(0, "#0;2;0;0;100#1;2;100;0;0@");
    defer gpa.free(t0.rgba);
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, px(t0, 0, 1));
    try testing.expectEqual(red, px(t0, 0, 0));
}

test "sixel: raster attributes set the aspect ratio; the canvas grows and clips at the maximum" {
    const img = try decode(1, "\"2;1;4;12#1;2;100;0;0@");
    defer gpa.free(img.rgba);
    // The declared 4 x 12 size; 2:1: each sixel row is two pixel rows.
    try testing.expectEqual(@as(u32, 4), img.w);
    try testing.expectEqual(@as(u32, 12), img.h);
    try testing.expectEqual(red, px(img, 0, 1));
    try testing.expectEqual(clear, px(img, 0, 2));
    // 100 columns into a 64-pixel maximum.
    const wide = try decode(1, "#1;2;100;0;0!100~-!100~");
    defer gpa.free(wide.rgba);
    try testing.expectEqual(@as(u32, 64), wide.w);
    try testing.expectEqual(@as(u32, 12), wide.h);
    // Nothing painted: no image.
    try testing.expectError(error.NoImage, decode(1, "#1;2;1;2;3$-"));
}

/// Our own encoder: one band per six rows, one colour register per
/// distinct colour, run-length coded.
fn encode(out: *std.ArrayList(u8), w: u32, h: u32, rgb: []const [3]u8) !void {
    var colors: std.ArrayList([3]u8) = .empty;
    defer colors.deinit(gpa);
    for (rgb) |c| {
        for (colors.items) |k| {
            if (std.mem.eql(u8, &k, &c)) break;
        } else try colors.append(gpa, c);
    }
    try out.appendSlice(gpa, "\x1bP0;1;0q");
    try out.print(gpa, "\"1;1;{d};{d}", .{ w, h });
    for (colors.items, 0..) |c, i| try out.print(gpa, "#{d};2;{d};{d};{d}", .{ i, @as(u32, c[0]) * 100 / 255, @as(u32, c[1]) * 100 / 255, @as(u32, c[2]) * 100 / 255 });
    var band: u32 = 0;
    while (band * 6 < h) : (band += 1) {
        for (colors.items, 0..) |c, ci| {
            try out.print(gpa, "#{d}", .{ci});
            var x: u32 = 0;
            while (x < w) {
                var bits: u8 = 0;
                for (0..6) |b| {
                    const y = band * 6 + @as(u32, @intCast(b));
                    if (y < h and std.mem.eql(u8, &rgb[y * w + x], &c)) bits |= @as(u8, 1) << @intCast(b);
                }
                var n: u32 = 1;
                while (x + n < w) : (n += 1) {
                    var b2: u8 = 0;
                    for (0..6) |b| {
                        const y = band * 6 + @as(u32, @intCast(b));
                        if (y < h and std.mem.eql(u8, &rgb[y * w + x + n], &c)) b2 |= @as(u8, 1) << @intCast(b);
                    }
                    if (b2 != bits) break;
                }
                if (n > 3) try out.print(gpa, "!{d}{c}", .{ n, bits + '?' }) else for (0..n) |_| try out.append(gpa, bits + '?');
                x += n;
            }
            try out.append(gpa, '$');
        }
        try out.append(gpa, '-');
    }
    try out.appendSlice(gpa, "\x1b\\");
}

test "sixel: reference images survive our encoder and the terminal's decoder" {
    const refs = [_]struct { w: u32, h: u32, f: *const fn (x: u32, y: u32) [3]u8 }{
        .{ .w = 16, .h = 16, .f = struct {
            fn f(x: u32, y: u32) [3]u8 {
                return if ((x / 4 + y / 4) % 2 == 0) .{ 255, 255, 255 } else .{ 0, 0, 0 };
            }
        }.f },
        .{ .w = 30, .h = 13, .f = struct {
            fn f(x: u32, _: u32) [3]u8 {
                return .{ @intCast(x * 255 / 29 / 51 * 51), 0, 255 };
            }
        }.f },
        .{ .w = 7, .h = 20, .f = struct {
            fn f(x: u32, y: u32) [3]u8 {
                return if (x == y % 7) .{ 255, 0, 0 } else .{ 0, 255, 0 };
            }
        }.f },
    };
    for (refs) |r| {
        const rgb = try gpa.alloc([3]u8, r.w * r.h);
        defer gpa.free(rgb);
        for (0..r.h) |y| for (0..r.w) |x| {
            rgb[y * r.w + x] = r.f(@intCast(x), @intCast(y));
        };
        var stream: std.ArrayList(u8) = .empty;
        defer stream.deinit(gpa);
        try encode(&stream, r.w, r.h, rgb);
        var t: Terminal = try .init(gpa, .{ .cols = 20, .rows = 10 });
        defer t.deinit();
        t.feed(stream.items);
        const img = t.images.images.values()[0].pixels;
        try testing.expectEqual(r.w, img.w);
        try testing.expectEqual(r.h, img.h);
        for (0..r.h) |y| for (0..r.w) |x| {
            const got = img.rgba[(y * r.w + x) * 4 ..][0..3];
            const want = rgb[y * r.w + x];
            // Percent registers round to within 2/255.
            for (0..3) |i| try testing.expect(@abs(@as(i32, got[i]) - want[i]) <= 2);
        };
    }
}

test "sixel: the cursor moves below the image; with DECSDM it is placed at home and the cursor stays" {
    var t: Terminal = try .init(gpa, .{ .cols = 20, .rows = 10 });
    defer t.deinit();
    t.cell_px = .{ .w = 10, .h = 20 };
    // 25 x 30 px: 3 cols, 2 rows.
    t.feed("\x1b[3;5H\x1bPq#1;2;100;0;0!25~-!25~-!25~-!25~-!25~\x1b\\");
    try testing.expectEqual(@as(usize, 1), t.images.placements.items.len);
    const p = t.images.placements.items[0];
    try testing.expectEqual(@as(u16, 3), p.cols);
    try testing.expectEqual(@as(u16, 2), p.rows);
    try testing.expectEqual(@as(u16, 4), p.pin.pin.x);
    try testing.expectEqual(@as(u16, 4), t.primary.cursor.y);
    try testing.expectEqual(@as(u16, 4), t.primary.cursor.x);

    t.feed("\x1b[?80h\x1b[6;6H\x1bPq#1~\x1b\\");
    const q = t.images.placements.items[1];
    try testing.expectEqual(@as(u16, 0), q.pin.pin.x);
    try testing.expectEqual(@as(u64, 0), t.primary.pages.rowIndex(q.pin.pin) - t.primary.pages.rowIndex(t.primary.rowPin(0)));
    try testing.expectEqual(@as(u16, 5), t.primary.cursor.y);
    try testing.expectEqual(@as(u16, 5), t.primary.cursor.x);

    // A sixel image goes with its placement.
    t.feed("\x1bc");
    try testing.expectEqual(@as(usize, 0), t.images.images.count());
}

test "sixel: turned off, DCS q is ignored and DA1 does not advertise it" {
    var t: Terminal = try .init(gpa, .{ .cols = 20, .rows = 10, .graphics = .{ .sixel = false } });
    defer t.deinit();
    t.feed("\x1bPq#1~\x1b\\\x1b[c");
    try testing.expectEqual(@as(usize, 0), t.images.images.count());
    try testing.expectEqualStrings("\x1b[?62;22c", t.replies.items);
}
