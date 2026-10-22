//! Atlas tests: padding, LCD expansion, eviction order and callback,
//! AtlasFull, dirty-region coalescing and uploads, device-loss re-emit,
//! the GlyphQuad layout, and a no-overlap property test with eviction.

const std = @import("std");
const testing = std.testing;
const atlas = @import("atlas.zig");
const Atlas = atlas.Atlas;
const AtlasEntry = atlas.AtlasEntry;
const PxRect = atlas.PxRect;
const Bitmap = @import("../raster/rasterizer.zig").Bitmap;

/// A `w`×`h` bitmap of `format` whose bytes are all `v`, in `buf`.
fn solid(buf: []u8, w: u16, h: u16, format: Bitmap.Format, v: u8) Bitmap {
    const bpp: u32 = switch (format) {
        .gray8, .sdf8 => 1,
        .lcd_rgb8x3 => 3,
        .rgba8_premul => 4,
    };
    const n = @as(usize, w) * h * bpp;
    @memset(buf[0..n], v);
    return .{ .width = w, .height = h, .stride = w * bpp, .left = 1, .top = -7, .format = format, .pixels = buf[0..n] };
}

fn texel(a: *const Atlas, page: u16, x: usize, y: usize) []const u8 {
    const p = a.pages.items[page];
    const bpp = atlas.bytesPerPixel(p.format);
    return p.pixels[(y * a.page_size + x) * bpp ..][0..bpp];
}

test "padding respected" {
    var a = try Atlas.init(testing.allocator, .{ .page_size = 64 });
    defer a.deinit();
    var buf: [64]u8 = undefined;
    var es: [6]AtlasEntry = undefined;
    for (&es) |*e| e.* = try a.insert(&solid(&buf, 5, 3, .gray8, 200), 1);
    for (es) |e| {
        try testing.expect(e.x >= 1 and e.y >= 1);
        try testing.expectEqual(@as(i16, 1), e.left);
        try testing.expectEqual(@as(i16, -7), e.top);
        // The border ring around each glyph stays transparent.
        for (e.y - 1..e.y + e.h + 1) |y| for (e.x - 1..e.x + e.w + 1) |x| {
            const inside = x >= e.x and x < e.x + e.w and y >= e.y and y < e.y + e.h;
            try testing.expectEqual(@as(u8, if (inside) 200 else 0), texel(&a, e.page, x, y)[0]);
        };
    }
    // SDF bitmaps carry their own border.
    const s = try a.insert(&solid(&buf, 4, 4, .sdf8, 9), 1);
    try testing.expectEqual(atlas.AtlasFormat.r8, a.pageFormat(s.page));
}

test "lcd expands to rgb_subpixel with alpha=max" {
    var a = try Atlas.init(testing.allocator, .{ .page_size = 32 });
    defer a.deinit();
    const px = [_]u8{ 10, 200, 30, 0, 0, 0, 255, 1, 2 };
    const bmp: Bitmap = .{ .width = 3, .height = 1, .stride = 9, .format = .lcd_rgb8x3, .pixels = @constCast(&px) };
    const e = try a.insert(&bmp, 1);
    try testing.expectEqual(atlas.AtlasFormat.rgb_subpixel, a.pageFormat(e.page));
    try testing.expectEqualSlices(u8, &.{ 10, 200, 30, 200 }, texel(&a, e.page, e.x, e.y));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, texel(&a, e.page, e.x + 1, e.y));
    try testing.expectEqualSlices(u8, &.{ 255, 1, 2, 255 }, texel(&a, e.page, e.x + 2, e.y));
}

test "colour bitmaps go to colour pages" {
    var a = try Atlas.init(testing.allocator, .{ .page_size = 32 });
    defer a.deinit();
    var buf: [64]u8 = undefined;
    const g = try a.insert(&solid(&buf, 2, 2, .gray8, 1), 1);
    const c = try a.insert(&solid(&buf, 2, 2, .rgba8_premul, 7), 1);
    try testing.expect(g.page != c.page);
    try testing.expectEqual(atlas.AtlasFormat.rgba_color, a.pageFormat(c.page));
    try testing.expectEqualSlices(u8, &.{ 7, 7, 7, 7 }, texel(&a, c.page, c.x + 1, c.y + 1));
}

test "empty and too large" {
    var a = try Atlas.init(testing.allocator, .{ .page_size = 16 });
    defer a.deinit();
    var buf: [400]u8 = undefined;
    const e = try a.insert(&solid(&buf, 0, 0, .gray8, 0), 1);
    try testing.expect(e.isEmpty());
    try testing.expectEqual(@as(usize, 0), a.pages.items.len);
    try testing.expectError(error.TooLarge, a.insert(&solid(&buf, 15, 2, .gray8, 0), 1));
    _ = try a.insert(&solid(&buf, 14, 14, .gray8, 0), 1);
    _ = try a.insert(&solid(&buf, 16, 16, .sdf8, 0), 1);
}

const Evictions = struct {
    pages: [8]u16 = undefined,
    n: usize = 0,
    a: *Atlas,
    /// A texel of the evicted page as the callback saw it.
    seen: [8]u8 = undefined,

    fn cb(ctx: *anyopaque, page: u16) void {
        const ev: *Evictions = @ptrCast(@alignCast(ctx));
        ev.pages[ev.n] = page;
        ev.seen[ev.n] = std.mem.max(u8, ev.a.pages.items[page].pixels);
        ev.n += 1;
    }
};

test "eviction picks oldest page" {
    var a = try Atlas.init(testing.allocator, .{ .page_size = 16, .max_gray_pages = 3 });
    defer a.deinit();
    var ev: Evictions = .{ .a = &a };
    a.setEvictCallback(&ev, Evictions.cb);
    var buf: [256]u8 = undefined;
    // One page-filling glyph per frame: pages 0, 1, 2 used in frames 1, 2, 3.
    for (1..4) |f| _ = try a.insert(&solid(&buf, 14, 14, .gray8, @intCast(f)), @intCast(f));
    a.touch(0, 4); // page 0 drawn again in frame 4
    const e = try a.insert(&solid(&buf, 14, 14, .gray8, 50), 5);
    try testing.expectEqual(@as(usize, 1), ev.n);
    try testing.expectEqual(@as(u16, 1), ev.pages[0]);
    try testing.expectEqual(@as(u16, 1), e.page);
}

test "evict callback invoked before reuse" {
    var a = try Atlas.init(testing.allocator, .{ .page_size = 16, .max_gray_pages = 1 });
    defer a.deinit();
    var ev: Evictions = .{ .a = &a };
    a.setEvictCallback(&ev, Evictions.cb);
    var buf: [256]u8 = undefined;
    _ = try a.insert(&solid(&buf, 14, 14, .gray8, 77), 1);
    const e = try a.insert(&solid(&buf, 10, 10, .gray8, 33), 2);
    try testing.expectEqual(@as(usize, 1), ev.n);
    // The callback ran while the old glyph was still there.
    try testing.expectEqual(@as(u8, 77), ev.seen[0]);
    try testing.expectEqual(@as(u8, 33), texel(&a, e.page, e.x, e.y)[0]);
    try testing.expectEqual(@as(u8, 0), texel(&a, e.page, 13, 13)[0]);
}

test "AtlasFull when all pages used this frame" {
    var a = try Atlas.init(testing.allocator, .{ .page_size = 16, .max_gray_pages = 2 });
    defer a.deinit();
    var buf: [14 * 14 * 4]u8 = undefined;
    _ = try a.insert(&solid(&buf, 14, 14, .gray8, 1), 3);
    _ = try a.insert(&solid(&buf, 14, 14, .gray8, 1), 3);
    try testing.expectError(error.AtlasFull, a.insert(&solid(&buf, 14, 14, .gray8, 1), 3));
    // Other formats are unaffected, and the next frame may evict.
    _ = try a.insert(&solid(&buf, 14, 14, .rgba8_premul, 1), 3);
    _ = try a.insert(&solid(&buf, 14, 14, .gray8, 1), 4);
}

test "dirty coalescing bounds" {
    var a = try Atlas.init(testing.allocator, .{ .page_size = 256, .max_gray_pages = 1 });
    defer a.deinit();
    var buf: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(3);
    const r = prng.random();
    var placed: std.ArrayList(PxRect) = .empty;
    defer placed.deinit(testing.allocator);
    var total: u64 = 0;
    for (0..300) |_| {
        const e = try a.insert(&solid(&buf, r.intRangeAtMost(u16, 3, 20), r.intRangeAtMost(u16, 3, 20), .gray8, 5), 1);
        try placed.append(testing.allocator, .{ .x = e.x - 1, .y = e.y - 1, .w = e.w + 2, .h = e.h + 2 });
        total += @as(u64, e.w + 2) * (e.h + 2);
        const p = a.pages.items[0];
        try testing.expect(p.n_dirty >= 1 and p.n_dirty <= 16);
    }
    // Every inserted region is inside a dirty one.
    const p = a.pages.items[0];
    for (placed.items) |g| {
        var covered = false;
        for (p.dirty[0..p.n_dirty]) |d| {
            if (g.x >= d.x and g.y >= d.y and g.x + g.w <= d.x + d.w and g.y + g.h <= d.y + d.h) covered = true;
        }
        try testing.expect(covered);
    }
    var dirty_area: u64 = 0;
    for (p.dirty[0..p.n_dirty]) |d| dirty_area += @as(u64, d.w) * d.h;
    try testing.expect(dirty_area >= total);
    try testing.expect(dirty_area <= @as(u64, a.page_size) * a.page_size);
}

test "takeUpdates bytes match page memory" {
    var a = try Atlas.init(testing.allocator, .{ .page_size = 64 });
    defer a.deinit();
    var buf: [1024]u8 = undefined;
    for (0..20) |i| _ = try a.insert(&solid(&buf, @intCast(3 + i % 7), @intCast(2 + i % 5), .gray8, @intCast(i + 1)), 1);
    for (0..5) |i| _ = try a.insert(&solid(&buf, 4, 4, .rgba8_premul, @intCast(100 + i)), 1);
    var ups: std.ArrayList(atlas.AtlasUpdate) = .empty;
    defer ups.deinit(testing.allocator);
    try a.takeUpdates(&ups, testing.allocator);
    try testing.expect(ups.items.len >= 2);
    for (ups.items) |u| {
        const bpp = atlas.bytesPerPixel(u.format);
        try testing.expectEqual(u.format, a.pageFormat(u.page));
        try testing.expectEqual(@as(u32, 64) * bpp, u.row_pitch);
        for (0..u.rect.h) |y| {
            const got = u.pixels[y * u.row_pitch ..][0 .. @as(usize, u.rect.w) * bpp];
            try testing.expectEqualSlices(u8, texel(&a, u.page, u.rect.x, u.rect.y + y).ptr[0..got.len], got);
        }
    }
    // Taken once.
    ups.clearRetainingCapacity();
    try a.takeUpdates(&ups, testing.allocator);
    try testing.expectEqual(@as(usize, 0), ups.items.len);
}

test "markAllDirty emits full pages" {
    var a = try Atlas.init(testing.allocator, .{ .page_size = 32 });
    defer a.deinit();
    var buf: [64]u8 = undefined;
    _ = try a.insert(&solid(&buf, 2, 2, .gray8, 1), 1);
    _ = try a.insert(&solid(&buf, 2, 2, .lcd_rgb8x3, 1), 1);
    var ups: std.ArrayList(atlas.AtlasUpdate) = .empty;
    defer ups.deinit(testing.allocator);
    try a.takeUpdates(&ups, testing.allocator);
    ups.clearRetainingCapacity();
    a.markAllDirty();
    try a.takeUpdates(&ups, testing.allocator);
    try testing.expectEqual(@as(usize, 2), ups.items.len);
    for (ups.items) |u| {
        try testing.expectEqual(PxRect{ .x = 0, .y = 0, .w = 32, .h = 32 }, u.rect);
        try testing.expectEqual(@as(usize, 32 * 32) * atlas.bytesPerPixel(u.format), u.pixels.len);
    }
}

test "quadFor matches E02 GlyphQuad layout" {
    try testing.expectEqual(@as(usize, 36), @sizeOf(atlas.GlyphQuad));
    try testing.expectEqual(@as(usize, 0), @offsetOf(atlas.GlyphQuad, "dst"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(atlas.GlyphQuad, "uv"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(atlas.GlyphQuad, "page"));
    try testing.expectEqual(@as(usize, 34), @offsetOf(atlas.GlyphQuad, "format"));
    const e: AtlasEntry = .{ .page = 3, .x = 10, .y = 20, .w = 6, .h = 8, .left = -1, .top = -7, .format = .lcd_rgb8x3 };
    const q = atlas.quadFor(e, 64, 100.5, 50, 1);
    try testing.expectEqual([4]f32{ 99.5, 43, 6, 8 }, q.dst);
    // u0, v0, u1, v1 normalised to the page, as zg_vulkan samples them.
    try testing.expectEqual([4]f32{ 10.0 / 64.0, 20.0 / 64.0, 16.0 / 64.0, 28.0 / 64.0 }, q.uv);
    try testing.expectEqual(@as(u16, 3), q.page);
    try testing.expectEqual(atlas.AtlasFormat.rgb_subpixel, q.format);
    const half = atlas.quadFor(e, 64, 0, 0, 0.5);
    try testing.expectEqual([4]f32{ -0.5, -3.5, 3, 4 }, half.dst);
}

test "never returns overlapping rects" {
    // 1e5 inserts into small pages with eviction: live entries on a page,
    // borders included, never overlap.
    const gpa = testing.allocator;
    var a = try Atlas.init(gpa, .{ .page_size = 128, .max_gray_pages = 3 });
    defer a.deinit();
    const Live = struct {
        rects: [3]std.ArrayList(PxRect) = @splat(.empty),
        fn cb(ctx: *anyopaque, page: u16) void {
            const l: *@This() = @ptrCast(@alignCast(ctx));
            l.rects[page].clearRetainingCapacity();
        }
    };
    var live: Live = .{};
    defer for (&live.rects) |*l| l.deinit(gpa);
    a.setEvictCallback(&live, Live.cb);
    var buf: [32 * 32]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(11);
    const r = prng.random();
    var frame: u32 = 1;
    var full: usize = 0;
    for (0..100_000) |i| {
        if (i % 32 == 0) frame += 1;
        const e = a.insert(&solid(&buf, r.intRangeAtMost(u16, 1, 30), r.intRangeAtMost(u16, 1, 30), .gray8, 1), frame) catch |err| switch (err) {
            // Possible when one frame's glyphs fill every page.
            error.AtlasFull => {
                full += 1;
                continue;
            },
            else => return err,
        };
        const g: PxRect = .{ .x = e.x - 1, .y = e.y - 1, .w = e.w + 2, .h = e.h + 2 };
        for (live.rects[e.page].items) |o| {
            const apart = g.x + g.w <= o.x or o.x + o.w <= g.x or g.y + g.h <= o.y or o.y + o.h <= g.y;
            try testing.expect(apart);
        }
        try live.rects[e.page].append(gpa, g);
    }
    try testing.expect(full < 1000);
}
