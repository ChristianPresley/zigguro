//! GIF decoding against files built by a small encoder here: palettes,
//! transparency, interlacing, disposal, loop counts, deferred clears and
//! truncation.

const std = @import("std");
const gif = @import("gif.zig");
const lzw = @import("lzw.zig");
const image = @import("image.zig");
const decode = @import("decode.zig");

const testing = std.testing;
const gpa = testing.allocator;

const FrameSpec = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16,
    h: u16,
    /// Row-major indices (in display order; interlaced on write when set).
    idx: []const u8,
    local: ?[]const u8 = null,
    interlace: bool = false,
    /// 0 none, 1 keep, 2 background, 3 previous.
    disposal: u3 = 0,
    delay_cs: u16 = 10,
    transparent: ?u8 = null,
    defer_clear: bool = false,
};

const Gif = struct {
    w: u16,
    h: u16,
    global: ?[]const u8 = null,
    loop: ?u16 = null,
    frames: []const FrameSpec,
};

/// Builds a GIF89a file.
fn build(spec: Gif) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "GIF89a");
    try put16(&out, spec.w);
    try put16(&out, spec.h);
    if (spec.global) |g| {
        try out.appendSlice(gpa, &.{ 0x80 | sizeBits(g.len), 0, 0 });
        try out.appendSlice(gpa, g);
    } else try out.appendSlice(gpa, &.{ 0, 0, 0 });
    if (spec.loop) |l| {
        try out.appendSlice(gpa, &.{ 0x21, 0xFF, 11 });
        try out.appendSlice(gpa, "NETSCAPE2.0");
        try out.appendSlice(gpa, &.{ 3, 1 });
        try put16(&out, l);
        try out.append(gpa, 0);
    }
    for (spec.frames) |f| {
        try out.appendSlice(gpa, &.{ 0x21, 0xF9, 4, @as(u8, f.disposal) << 2 | @intFromBool(f.transparent != null) });
        try put16(&out, f.delay_cs);
        try out.appendSlice(gpa, &.{ f.transparent orelse 0, 0 });
        try out.append(gpa, 0x2C);
        try put16(&out, f.x);
        try put16(&out, f.y);
        try put16(&out, f.w);
        try put16(&out, f.h);
        var pk: u8 = if (f.interlace) 0x40 else 0;
        if (f.local) |l| pk |= 0x80 | sizeBits(l.len);
        try out.append(gpa, pk);
        if (f.local) |l| try out.appendSlice(gpa, l);
        // Interlaced files store rows in pass order.
        const stored = try gpa.alloc(u8, f.idx.len);
        defer gpa.free(stored);
        if (f.interlace) {
            var k: usize = 0;
            for ([_][2]usize{ .{ 0, 8 }, .{ 4, 8 }, .{ 2, 4 }, .{ 1, 2 } }) |p| {
                var row = p[0];
                while (row < f.h) : (row += p[1]) {
                    @memcpy(stored[k * f.w ..][0..f.w], f.idx[row * f.w ..][0..f.w]);
                    k += 1;
                }
            }
        } else @memcpy(stored, f.idx);
        const min: u4 = 8;
        try out.append(gpa, min);
        const data = try lzw.encode(gpa, min, stored, f.defer_clear);
        defer gpa.free(data);
        var i: usize = 0;
        while (i < data.len) {
            const n = @min(255, data.len - i);
            try out.append(gpa, @intCast(n));
            try out.appendSlice(gpa, data[i..][0..n]);
            i += n;
        }
        try out.append(gpa, 0);
    }
    try out.append(gpa, 0x3B);
    return out.toOwnedSlice(gpa);
}

fn put16(out: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

/// The colour-table size field for `len` bytes (a power of two of
/// entries, at least 2).
fn sizeBits(len: usize) u8 {
    const n = len / 3;
    var bits: u8 = 0;
    while ((@as(usize, 2) << @intCast(bits)) < n) bits += 1;
    return bits;
}

/// 4 colours: red, green, blue, white.
const pal4 = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255 };

fn px(img_rgba: []const u8, w: u32, x: u32, y: u32) [4]u8 {
    return img_rgba[(y * w + x) * 4 ..][0..4].*;
}

test "gif: single frame with the global palette" {
    const file = try build(.{ .w = 2, .h = 2, .global = &pal4, .frames = &.{.{ .w = 2, .h = 2, .idx = &.{ 0, 1, 2, 3 } }} });
    defer gpa.free(file);
    var img = try decode.decode(gpa, file, .{});
    defer img.deinit(gpa);
    try testing.expectEqual(image.Format.gif, img.format);
    try testing.expect(!img.animated());
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, px(img.rgba, 2, 0, 0));
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, px(img.rgba, 2, 1, 0));
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, px(img.rgba, 2, 0, 1));
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, px(img.rgba, 2, 1, 1));
}

test "gif: local palette and transparency" {
    const local = [_]u8{ 10, 20, 30, 40, 50, 60 };
    const file = try build(.{ .w = 2, .h = 1, .global = &pal4, .frames = &.{.{ .w = 2, .h = 1, .idx = &.{ 0, 1 }, .local = &local, .transparent = 1 }} });
    defer gpa.free(file);
    var img = try gif.decodeGif(gpa, file, .{});
    defer img.deinit(gpa);
    try testing.expectEqual([4]u8{ 10, 20, 30, 255 }, px(img.rgba, 2, 0, 0));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, px(img.rgba, 2, 1, 0));
}

test "gif: interlace" {
    var idx: [4 * 10]u8 = undefined;
    for (0..10) |r| @memset(idx[r * 4 ..][0..4], @intCast(r % 4));
    const file = try build(.{ .w = 4, .h = 10, .global = &pal4, .frames = &.{.{ .w = 4, .h = 10, .idx = &idx, .interlace = true }} });
    defer gpa.free(file);
    var img = try gif.decodeGif(gpa, file, .{});
    defer img.deinit(gpa);
    for (0..10) |r| {
        const c = pal4[(r % 4) * 3 ..][0..3];
        try testing.expectEqual([4]u8{ c[0], c[1], c[2], 255 }, px(img.rgba, 4, 3, @intCast(r)));
    }
}

test "gif: disposal keep, background and previous; loop count and delays" {
    // Frame 1 fills red (keep). Frame 2 draws green at (0,0) and asks to
    // restore the previous canvas. Frame 3 draws blue at (1,0) and asks
    // for background. Frame 4 draws nothing visible (transparent pixel).
    const file = try build(.{ .w = 2, .h = 1, .global = &pal4, .loop = 3, .frames = &.{
        .{ .w = 2, .h = 1, .idx = &.{ 0, 0 }, .disposal = 1, .delay_cs = 1 },
        .{ .w = 1, .h = 1, .idx = &.{1}, .disposal = 3, .delay_cs = 5 },
        .{ .x = 1, .w = 1, .h = 1, .idx = &.{2}, .disposal = 2 },
        .{ .w = 1, .h = 1, .idx = &.{3}, .transparent = 3 },
    } });
    defer gpa.free(file);
    var img = try gif.decodeGif(gpa, file, .{});
    defer img.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), img.frames.len);
    try testing.expectEqual(@as(u16, 3), img.loop_count);
    const red = [4]u8{ 255, 0, 0, 255 };
    try testing.expectEqual(red, px(img.frames[0].rgba, 2, 1, 0));
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, px(img.frames[1].rgba, 2, 0, 0));
    // Previous: frame 2's green is undone before frame 3.
    try testing.expectEqual(red, px(img.frames[2].rgba, 2, 0, 0));
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, px(img.frames[2].rgba, 2, 1, 0));
    // Background: frame 3's rect is cleared to transparent.
    try testing.expectEqual(red, px(img.frames[3].rgba, 2, 0, 0));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, px(img.frames[3].rgba, 2, 1, 0));
    // Under 20 ms plays as 100 ms.
    try testing.expectEqual(@as(u32, 100), img.frames[0].delay_ms);
    try testing.expectEqual(@as(u32, 50), img.frames[1].delay_ms);
    const info = try gif.animInfo(file);
    try testing.expectEqual(@as(u32, 4), info.frame_count);
    try testing.expectEqual(@as(u16, 3), info.loop_count);
}

test "gif: deferred clear decodes a large frame" {
    const w = 128;
    const h = 128;
    var idx: [w * h]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(11);
    for (&idx) |*b| b.* = prng.random().int(u8) & 3;
    const file = try build(.{ .w = w, .h = h, .global = &pal4, .frames = &.{.{ .w = w, .h = h, .idx = &idx, .defer_clear = true }} });
    defer gpa.free(file);
    var img = try gif.decodeGif(gpa, file, .{});
    defer img.deinit(gpa);
    for (idx, 0..) |c, i| try testing.expectEqual(pal4[@as(usize, c) * 3], img.rgba[i * 4]);
}

test "gif: truncated file keeps the frames before the cut" {
    const file = try build(.{ .w = 1, .h = 1, .global = &pal4, .frames = &.{
        .{ .w = 1, .h = 1, .idx = &.{0} },
        .{ .w = 1, .h = 1, .idx = &.{1} },
    } });
    defer gpa.free(file);
    // Cut inside the second frame's data.
    const cut = file.len - 3;
    var img = try gif.decodeGif(gpa, file[0..cut], .{});
    defer img.deinit(gpa);
    try testing.expect(img.truncated);
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, px(img.rgba, 1, 0, 0));
    // Nothing decodable at all.
    try testing.expectError(error.Malformed, gif.decodeGif(gpa, file[0..12], .{}));
}

test "gif: limits enforced before alloc" {
    var hdr = "GIF89a\xff\xff\xff\xff\x00\x00\x00".*;
    try testing.expectError(error.TooLarge, gif.decodeGif(gpa, &hdr, .{ .max_pixels = 1000 }));
    const file = try build(.{ .w = 1, .h = 1, .global = &pal4, .frames = &.{ .{ .w = 1, .h = 1, .idx = &.{0} }, .{ .w = 1, .h = 1, .idx = &.{1} } } });
    defer gpa.free(file);
    var img = try gif.decodeGif(gpa, file, .{ .max_frames = 1 });
    defer img.deinit(gpa);
    try testing.expect(img.truncated and !img.animated());
}

test "fuzz: image-gif" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            if (gif.decodeGif(testing.allocator, input, .{ .max_pixels = 1 << 16, .max_frames = 16 })) |img| {
                var m = img;
                try testing.expectEqual(@as(usize, m.w) * m.h * 4, m.rgba.len);
                m.deinit(testing.allocator);
            } else |_| {}
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "image-gif") });
}
