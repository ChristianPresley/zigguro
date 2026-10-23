//! The canvas, display list hashing, tile seams and the tile cache.

const std = @import("std");
const vector = @import("root.zig");
const util = @import("test_util.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const tiles = vector.tiles;

/// One shape a list: blending two layers can round each by one level.
fn seamShape(c: *vector.VectorCanvas, i: usize) !void {
    switch (i) {
        0 => try c.line(10, 20, 700, 600, .{ .width = 3, .cap = .round }, .rgb(0x204080)),
        1 => try c.line(700, 30, 40, 700, .{ .width = 1.5 }, vector.Color.rgb(0xC02020).withAlpha(200)),
        2 => try c.line(255.5, 0, 256.5, 760, .{ .width = 1 }, .rgb(0x000000)),
        3 => try c.circle(256, 256, 40, vector.Color.rgb(0x10A010).withAlpha(128)),
        else => {
            const p = try c.path();
            try p.moveTo(c.arena, 0, 500);
            try p.cubicTo(c.arena, 300, 100, 500, 900, 760, 260);
            try c.stroke(p, .{ .width = 5, .join = .round }, .rgb(0x806000));
        },
    }
}

test "tile_seams_invisible" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // Diagonals and a curve crossing tile corners and edges at odd
    // angles, each compared with a render into one bitmap.
    for (0..5) |shape| {
        var c: vector.VectorCanvas = .init(arena.allocator());
        try seamShape(&c, shape);
        const dl = try c.finish();
        for ([_]f32{ 1, 1.5 }) |scale| {
            const w: u32 = @intFromFloat(768 * scale);
            const h: u32 = w;
            const tiled = try util.renderTiled(gpa, &dl, scale, w, h);
            defer gpa.free(tiled);
            const whole = try util.renderWhole(gpa, &dl, scale, w, h);
            defer gpa.free(whole);
            var worst: u8 = 0;
            for (tiled, whole) |x, y| worst = @max(worst, if (x > y) x - y else y - x);
            try testing.expect(worst <= 1);
            // Something was drawn.
            try testing.expect(std.mem.indexOfNone(u8, tiled, &.{0}) != null);
        }
    }
}

test "display list hash follows content" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var lists: [3]vector.DisplayList = undefined;
    for (&lists, [_]u24{ 0x112233, 0x112233, 0x112234 }) |*l, col| {
        var c: vector.VectorCanvas = .init(arena.allocator());
        try c.fillRect(.xywh(1, 2, 30, 40), .rgb(col));
        try c.line(0, 0, 50, 50, .{ .width = 2 }, .rgb(0));
        try c.text(.{ .x = 3, .y = 4, .text = "axis" });
        l.* = try c.finish();
    }
    try testing.expectEqual(lists[0].hash, lists[1].hash);
    try testing.expect(lists[0].hash != lists[2].hash);
    try testing.expect(lists[0].bounds.x0 <= 0 and lists[0].bounds.x1 >= 50);
}

test "clips limit fills to their rectangle" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: vector.VectorCanvas = .init(arena.allocator());
    try c.pushClip(.xywh(10, 10, 20, 20));
    try c.fillRect(.xywh(0, 0, 100, 100), .rgb(0xFFFFFF));
    // Left open: `finish` closes it.
    const dl = try c.finish();
    try testing.expectEqual(.clip_pop, std.meta.activeTag(dl.items[dl.items.len - 1]));
    const px = try util.renderTiled(gpa, &dl, 1, 64, 64);
    defer gpa.free(px);
    try testing.expectEqual(255, px[(15 * 64 + 15) * 4 + 3]);
    try testing.expectEqual(0, px[(5 * 64 + 5) * 4 + 3]);
    try testing.expectEqual(0, px[(40 * 64 + 15) * 4 + 3]);
}

const Evicted = struct {
    n: u32 = 0,
    fn f(ctx: *anyopaque, _: *tiles.Tile) void {
        const e: *Evicted = @ptrCast(@alignCast(ctx));
        e.n += 1;
    }
};

fn key(i: i32) tiles.Key {
    return .{ .hash = 7, .scale_q = 1000, .tx = i, .ty = 0 };
}

test "cache_lru_budget" {
    var cache: tiles.TileCache = .init(gpa, 3 * tiles.tile_bytes);
    defer cache.deinit();
    var ev: Evicted = .{};
    cache.on_evict = .{ .ctx = &ev, .f = Evicted.f };
    for (0..3) |i| try cache.put(io, key(@intCast(i)), try gpa.alloc(u8, tiles.tile_bytes));
    // Touch 0 so 1 is the least recently used.
    try testing.expect(cache.get(io, key(0)) != null);
    try cache.put(io, key(3), try gpa.alloc(u8, tiles.tile_bytes));
    // A duplicate put keeps the old tile.
    try cache.put(io, key(3), try gpa.alloc(u8, tiles.tile_bytes));
    try testing.expectEqual(4, cache.count(io));
    cache.trim(io, std.math.maxInt(u64));
    try testing.expectEqual(3, cache.count(io));
    try testing.expectEqual(1, ev.n);
    try testing.expect(!cache.contains(io, key(1)));
    try testing.expect(cache.contains(io, key(0)) and cache.contains(io, key(2)) and cache.contains(io, key(3)));
    try testing.expect(cache.used <= cache.budget);

    // Tiles used this frame are spared even over budget.
    const frame = cache.now(io);
    const live = [_]i32{ 0, 2, 3 };
    for (live) |i| _ = cache.get(io, key(i));
    try cache.put(io, key(4), try gpa.alloc(u8, tiles.tile_bytes));
    cache.trim(io, frame);
    try testing.expectEqual(4, cache.count(io));
    // Next frame, the oldest goes.
    cache.trim(io, cache.now(io));
    try testing.expectEqual(3, cache.count(io));
    try testing.expectEqual(2, ev.n);
}

test "rasterizeTiles fills the cache on workers" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: vector.VectorCanvas = .init(arena.allocator());
    try c.line(0, 0, 600, 300, .{ .width = 4 }, .rgb(0));
    const dl = try c.finish();
    var cache: tiles.TileCache = .init(gpa, tiles.TileCache.default_budget);
    defer cache.deinit();
    const r = tiles.tilesFor(.{ .x0 = 0, .y0 = 0, .x1 = 600, .y1 = 300 });
    var keys: std.ArrayListUnmanaged(tiles.Key) = .empty;
    defer keys.deinit(gpa);
    var ty = r.y0;
    while (ty < r.y1) : (ty += 1) {
        var tx = r.x0;
        while (tx < r.x1) : (tx += 1) try keys.append(gpa, .{ .hash = dl.hash, .scale_q = 1000, .tx = tx, .ty = ty });
    }
    try testing.expectEqual(6, keys.items.len);
    try tiles.rasterizeTiles(io, &cache, &dl, keys.items, 4);
    try testing.expectEqual(6, cache.count(io));
    // Same pixels as a direct render.
    const whole = try util.renderTiled(gpa, &dl, 1, 768, 512);
    defer gpa.free(whole);
    const t = cache.get(io, keys.items[4]).?;
    for (0..tiles.tile_size) |row| {
        const off = ((256 + row) * 768 + 256) * 4;
        try testing.expectEqualSlices(u8, whole[off..][0 .. tiles.tile_size * 4], t.pixels[row * tiles.tile_size * 4 ..][0 .. tiles.tile_size * 4]);
    }
}
