//! JPEG decoding against fixtures in testdata/images: a 37×29 synthetic
//! pattern saved by libjpeg (through Pillow) as baseline 4:4:4, 4:2:2 and
//! 4:2:0, grayscale, progressive 4:2:0 and 4:4:4 (spectral selection and
//! successive approximation), with a restart interval of 2 MCUs, as
//! Adobe CMYK, and with EXIF orientation 6. Each `.ref` is libjpeg's
//! decode; ours must be within 3 per channel.

const std = @import("std");
const jpeg = @import("jpeg.zig");
const image = @import("image.zig");
const decode = @import("decode.zig");
const downscale = @import("downscale.zig");

const testing = std.testing;
const gpa = testing.allocator;

const W = 37;
const H = 29;

fn load(name: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/testdata/images/{s}", .{ @import("zg_options").package_root, name });
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(1 << 20));
}

/// The largest channel difference between `img` and the reference
/// decode (`channels` 3 or 1 per pixel).
fn maxDiff(img: *const image.Image, ref: []const u8, channels: usize) u8 {
    var worst: u8 = 0;
    for (0..img.w * img.h) |i| {
        for (0..3) |c| {
            const want = ref[i * channels + (if (channels == 1) 0 else c)];
            const got = img.rgba[i * 4 + c];
            worst = @max(worst, if (got > want) got - want else want - got);
        }
    }
    return worst;
}

fn expectMatches(name: []const u8, channels: usize) !void {
    var n_buf: [64]u8 = undefined;
    const file = try load(try std.fmt.bufPrint(&n_buf, "{s}.jpg", .{name}));
    defer gpa.free(file);
    const ref = try load(try std.fmt.bufPrint(&n_buf, "{s}.ref", .{name}));
    defer gpa.free(ref);
    var img = try decode.decode(gpa, file, .{});
    defer img.deinit(gpa);
    try testing.expectEqual(image.Format.jpeg, img.format);
    try testing.expectEqual(@as(u32, W), img.w);
    try testing.expectEqual(@as(u32, H), img.h);
    try testing.expectEqual(ref.len, @as(usize, W) * H * channels);
    const d = maxDiff(&img, ref, channels);
    if (d > 3) std.debug.print("{s}: max channel difference {d}\n", .{ name, d });
    try testing.expect(d <= 3);
    for (0..W * H) |i| try testing.expectEqual(@as(u8, 255), img.rgba[i * 4 + 3]);
}

test "jpeg: baseline 4:4:4, 4:2:2 and 4:2:0" {
    try expectMatches("baseline444", 3);
    try expectMatches("baseline422", 3);
    try expectMatches("baseline420", 3);
}

test "jpeg: grayscale" {
    try expectMatches("gray", 1);
}

test "jpeg: progressive" {
    try expectMatches("progressive420", 3);
    try expectMatches("progressive444", 3);
}

test "jpeg: restart interval" {
    try expectMatches("restart", 3);
}

test "jpeg: Adobe CMYK" {
    try expectMatches("cmyk", 3);
}

test "jpeg: exif orientation 6 turns the image upright" {
    const file = try load("orient6.jpg");
    defer gpa.free(file);
    const ref = try load("baseline444.ref");
    defer gpa.free(ref);
    try testing.expectEqual(@as(u8, 6), (try jpeg.info(file)).orientation);
    var img = try decode.decode(gpa, file, .{});
    defer img.deinit(gpa);
    try testing.expectEqual(@as(u32, H), img.w);
    try testing.expectEqual(@as(u32, W), img.h);
    // Display (x, y) shows source (y, H - 1 - x).
    var worst: u8 = 0;
    for (0..img.h) |y| for (0..img.w) |x| {
        const s = ((H - 1 - x) * W + y) * 3;
        for (0..3) |c| {
            const a = img.rgba[(y * img.w + x) * 4 + c];
            const b = ref[s + c];
            worst = @max(worst, if (a > b) a - b else b - a);
        }
    };
    try testing.expect(worst <= 3);
}

test "jpeg: orientations 1-8 map pixels" {
    // A 3×2 image with distinct pixels.
    const src = [_]u8{ 0, 1, 2, 3, 4, 5 };
    const want = [9][]const u8{
        &.{}, &.{ 0, 1, 2, 3, 4, 5 }, // 1
        &.{ 2, 1, 0, 5, 4, 3 }, // 2 mirror
        &.{ 5, 4, 3, 2, 1, 0 }, // 3 rotate 180
        &.{ 3, 4, 5, 0, 1, 2 }, // 4 flip
        &.{ 0, 3, 1, 4, 2, 5 }, // 5 transpose
        &.{ 3, 0, 4, 1, 5, 2 }, // 6 rotate 90 CW
        &.{ 5, 2, 4, 1, 3, 0 }, // 7 transverse
        &.{ 2, 5, 1, 4, 0, 3 }, // 8 rotate 90 CCW
    };
    for (1..9) |o| {
        const px = try gpa.alloc(u8, 24);
        for (src, 0..) |v, i| px[i * 4 ..][0..4].* = .{ v, 0, 0, 255 };
        var img = try jpeg.orient(gpa, .{ .w = 3, .h = 2, .rgba = px, .format = .jpeg }, @intCast(o));
        defer img.deinit(gpa);
        for (want[o], 0..) |v, i| try testing.expectEqual(v, img.rgba[i * 4]);
        try testing.expectEqual(@as(u32, if (o >= 5) 2 else 3), img.w);
    }
}

test "jpeg: scaled decode 1/8 matches downscale within tolerance" {
    const file = try load("baseline444.jpg");
    defer gpa.free(file);
    var small = try decode.decodeScaled(gpa, file, 5, .{});
    defer small.deinit(gpa);
    try testing.expectEqual(@as(u32, 5), small.w);
    try testing.expectEqual(@as(u32, 4), small.h);
    var full = try decode.decode(gpa, file, .{});
    defer full.deinit(gpa);
    // Each 1/8 pixel is its block's DC: the mean of the block's full-size
    // samples (whole blocks only: the right and bottom ones are padded).
    for (0..3) |by| for (0..4) |bx| for (0..3) |c| {
        var sum: u32 = 0;
        for (0..8) |y| for (0..8) |x| {
            sum += full.rgba[((by * 8 + y) * W + bx * 8 + x) * 4 + c];
        };
        const mean: i32 = @intCast((sum + 32) / 64);
        const got: i32 = small.rgba[(by * 5 + bx) * 4 + c];
        try testing.expect(@abs(got - mean) <= 4);
    };
    // The linear-light box filter gives the same size.
    var boxed = try downscale.downscale(gpa, &full, 5);
    defer boxed.deinit(gpa);
    try testing.expectEqual(small.w, boxed.w);
    try testing.expectEqual(small.h, boxed.h);
    // 1/2 and 1/4 too.
    var half = try decode.decodeScaled(gpa, file, 19, .{});
    defer half.deinit(gpa);
    try testing.expectEqual(@as(u32, 19), half.w);
    var quarter = try decode.decodeScaled(gpa, file, 10, .{});
    defer quarter.deinit(gpa);
    try testing.expectEqual(@as(u32, 10), quarter.w);
}

test "jpeg: truncated, unsupported and oversized files" {
    const file = try load("baseline420.jpg");
    defer gpa.free(file);
    try testing.expectError(error.Malformed, decode.decode(gpa, file[0 .. file.len - 200], .{}));
    try testing.expectError(error.Malformed, decode.decode(gpa, file[0..100], .{}));
    // SOF3 (lossless) is not supported.
    const copy = try gpa.dupe(u8, file);
    defer gpa.free(copy);
    const sof = std.mem.indexOf(u8, copy, "\xFF\xC0").?;
    copy[sof + 1] = 0xC3;
    try testing.expectError(error.Unsupported, decode.decode(gpa, copy, .{}));
    // A huge frame is refused before anything is allocated.
    copy[sof + 1] = 0xC0;
    std.mem.writeInt(u16, copy[sof + 5 ..][0..2], 60000, .big);
    std.mem.writeInt(u16, copy[sof + 7 ..][0..2], 60000, .big);
    try testing.expectError(error.TooLarge, decode.decode(gpa, copy, .{}));
}

test "jpeg: output is deterministic" {
    // Golden hashes of the decodes: the IDCT and colour conversion are
    // integer only, so every target must produce these exact bytes.
    const cases = [_]struct { name: []const u8, hash: u64 }{
        .{ .name = "baseline420.jpg", .hash = 0xd1dfde33c2372537 },
        .{ .name = "progressive444.jpg", .hash = 0xd8f3843c7f5fb18c },
    };
    for (cases) |c| {
        const file = try load(c.name);
        defer gpa.free(file);
        var img = try decode.decode(gpa, file, .{});
        defer img.deinit(gpa);
        const h = std.hash.Wyhash.hash(0, img.rgba);
        try testing.expectEqual(c.hash, h);
    }
}

test "fuzz: image-jpeg" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            if (jpeg.decodeJpeg(testing.allocator, input, .{ .max_pixels = 1 << 16 }, 1, null)) |img| {
                var m = img;
                try testing.expectEqual(@as(usize, m.w) * m.h * 4, m.rgba.len);
                m.deinit(testing.allocator);
            } else |_| {}
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "image-jpeg") });
}
