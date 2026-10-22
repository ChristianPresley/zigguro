//! Glyph cache tests against a real face: the sync budget on a fake
//! clock, async delivery through the runtime mailbox, pending dedupe,
//! eviction (no stale UVs), prewarm, and an allocation-free lookup.

const std = @import("std");
const testing = std.testing;
const zg_core = @import("zg_core");
const Runtime = zg_core.runtime.Runtime;
const fonts = @import("../testing/fonts.zig");
const Face = @import("../ot/face.zig").Face;
const FaceInstance = @import("../ot/var/instance.zig").FaceInstance;
const Rasterizer = @import("../raster/rasterizer.zig").Rasterizer;
const atlas_mod = @import("atlas.zig");
const Atlas = atlas_mod.Atlas;
const key_mod = @import("glyph_key.zig");
const GlyphKey = key_mod.GlyphKey;
const gc = @import("glyph_cache.zig");
const GlyphCache = gc.GlyphCache;
const raster_queue = @import("raster_queue.zig");

/// One face at its default instance, built in place (the instance points
/// at `face`).
const Fixture = struct {
    data: []u8,
    face: Face,
    inst: FaceInstance,

    fn init(f: *Fixture, name: []const u8) !void {
        f.data = try fonts.font(testing.allocator, name);
        errdefer testing.allocator.free(f.data);
        f.face = try Face.init(f.data, 0);
        f.inst = try FaceInstance.init(testing.allocator, &f.face, &.{});
    }

    fn deinit(f: *Fixture) void {
        f.inst.deinit(testing.allocator);
        testing.allocator.free(f.data);
    }

    fn resolve(ctx: *const anyopaque, k: GlyphKey) ?gc.Resolved {
        const f: *const Fixture = @ptrCast(@alignCast(ctx));
        if (k.instance != 1) return null;
        return .{ .instance = &f.inst };
    }

    fn source(f: *const Fixture) gc.GlyphSource {
        return .{ .ctx = f, .resolveFn = resolve };
    }

    fn key(f: *const Fixture, cp: u21, px: f32) GlyphKey {
        return .{ .instance = 1, .glyph = f.face.glyphIndex(cp), .size_q = key_mod.quantizeSize(px) };
    }
};

/// A clock that advances `step` ns on every read.
const FakeClock = struct {
    t: u64 = 0,
    step: u64,

    fn now(ctx: ?*anyopaque) u64 {
        const c: *FakeClock = @ptrCast(@alignCast(ctx.?));
        c.t += c.step;
        return c.t;
    }

    fn clock(c: *FakeClock) gc.Clock {
        return .{ .ctx = c, .nowFn = now };
    }
};

const ascii = blk: {
    var cps: [95]u21 = undefined;
    for (&cps, 0..) |*c, i| c.* = @intCast(0x20 + i);
    break :blk cps;
};

test "glyph cache: sync budget respected" {
    var f: Fixture = undefined;
    try f.init("JetBrainsMono[wght].ttf");
    defer f.deinit();
    var rt: Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var atlas = try Atlas.init(testing.allocator, .{ .page_size = 512 });
    defer atlas.deinit();
    var clock: FakeClock = .{ .step = 300_000 };
    var c: GlyphCache = undefined;
    try c.init(testing.allocator, &rt, &atlas, .{ .workers = 0, .clock = clock.clock() });
    defer c.deinit();

    // 300 µs per clock read and a 1 ms budget: three glyphs fit per frame.
    c.beginFrame(1);
    var hits: usize = 0;
    for ("ABCDEFG") |ch| {
        if (c.get(f.key(ch, 14), f.source()) == .hit) hits += 1;
    }
    try testing.expectEqual(@as(usize, 3), hits);
    try testing.expectEqual(@as(u64, 3), c.stats.sync_rasters);
    // Next frame: three more, the first three stay resident.
    c.beginFrame(2);
    hits = 0;
    for ("ABCDEFG") |ch| {
        if (c.get(f.key(ch, 14), f.source()) == .hit) hits += 1;
    }
    try testing.expectEqual(@as(usize, 6), hits);
    // Expensive glyphs never rasterize synchronously.
    c.beginFrame(3);
    try testing.expectEqual(gc.Lookup.miss, c.get(f.key('Q', 64), f.source()));
}

fn drainInto(rt: *Runtime, c: *GlyphCache, want: usize) !void {
    var got: usize = 0;
    var buf: [64]zg_core.runtime.UiMsg = undefined;
    var tries: usize = 0;
    while (got < want) : (tries += 1) {
        if (tries > 5000) return error.Timeout;
        const n = rt.drain(&buf);
        for (buf[0..n]) |m| {
            try testing.expectEqual(raster_queue.ui_msg_kind, m.kind);
            c.onRasterDone(m);
        }
        got += n;
        if (n == 0) try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "glyph cache: async results delivered via runtime" {
    var f: Fixture = undefined;
    try f.init("JetBrainsMono[wght].ttf");
    defer f.deinit();
    var rt: Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var atlas = try Atlas.init(testing.allocator, .{ .page_size = 1024 });
    defer atlas.deinit();
    var c: GlyphCache = undefined;
    try c.init(testing.allocator, &rt, &atlas, .{ .workers = 2, .sync_budget_ns = 0 });
    defer c.deinit();

    c.beginFrame(1);
    for (ascii) |cp| try testing.expect(c.get(f.key(cp, 20), f.source()) != .miss);
    // Space maps to a glyph with no outline, but it still goes async.
    const queued = c.stats.async_submits;
    try testing.expect(queued > 50);
    try drainInto(&rt, &c, queued);
    c.beginFrame(2);
    var r = Rasterizer.init(testing.allocator);
    defer r.deinit();
    for (ascii) |cp| {
        const k = f.key(cp, 20);
        const e = switch (c.lookup(k)) {
            .hit => |e| e,
            else => return error.NotResident,
        };
        const bm = try r.rasterizeGlyph(&f.inst, k.glyph, key_mod.rasterParams(k, .{}));
        try testing.expectEqual(bm.width, e.w);
        try testing.expectEqual(bm.height, e.h);
        try expectAtlasHolds(&atlas, e, bm);
    }
}

fn expectAtlasHolds(atlas: *const Atlas, e: atlas_mod.AtlasEntry, bm: @import("../raster/rasterizer.zig").Bitmap) !void {
    if (e.isEmpty()) return;
    const p = atlas.pages.items[e.page];
    for (0..e.h) |y| {
        const src = bm.row(y);
        const dst = p.pixels[(@as(usize, e.y) + y) * atlas.page_size + e.x ..][0..e.w];
        try testing.expectEqualSlices(u8, src, dst);
    }
}

test "glyph cache: pending dedupe" {
    var f: Fixture = undefined;
    try f.init("JetBrainsMono[wght].ttf");
    defer f.deinit();
    var rt: Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var atlas = try Atlas.init(testing.allocator, .{ .page_size = 256 });
    defer atlas.deinit();
    var c: GlyphCache = undefined;
    try c.init(testing.allocator, &rt, &atlas, .{ .workers = 1, .sync_budget_ns = 0 });
    defer c.deinit();

    c.beginFrame(1);
    const k = f.key('W', 14);
    try testing.expectEqual(gc.Lookup.pending, c.get(k, f.source()));
    try testing.expectEqual(gc.Lookup.pending, c.get(k, f.source()));
    try testing.expectEqual(gc.Lookup.pending, c.lookup(k));
    try testing.expectEqual(@as(u64, 1), c.queue.?.submitted.load(.monotonic));
    try drainInto(&rt, &c, 1);
    try testing.expect(c.lookup(k) == .hit);
    try testing.expectEqual(@as(u64, 1), c.queue.?.submitted.load(.monotonic));
}

test "glyph cache: eviction invalidates entries" {
    var f: Fixture = undefined;
    try f.init("JetBrainsMono[wght].ttf");
    defer f.deinit();
    var rt: Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    // Two tiny pages: a frame of new glyphs evicts the older page.
    var atlas = try Atlas.init(testing.allocator, .{ .page_size = 96, .max_gray_pages = 2 });
    defer atlas.deinit();
    var c: GlyphCache = undefined;
    try c.init(testing.allocator, &rt, &atlas, .{ .workers = 0, .sync_budget_ns = std.math.maxInt(u64) });
    defer c.deinit();
    var r = Rasterizer.init(testing.allocator);
    defer r.deinit();

    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    var frame: u32 = 1;
    while (frame < 120) : (frame += 1) {
        c.beginFrame(frame);
        // Each frame draws a few random glyphs at a few sizes; every hit
        // must still show that glyph's pixels.
        for (0..6) |_| {
            const cp = ascii[1 + rnd.uintLessThan(usize, ascii.len - 1)];
            const k = f.key(cp, @floatFromInt(10 + 2 * rnd.uintLessThan(u32, 6)));
            switch (c.get(k, f.source())) {
                .hit => |e| {
                    const bm = try r.rasterizeGlyph(&f.inst, k.glyph, key_mod.rasterParams(k, .{}));
                    try expectAtlasHolds(&atlas, e, bm);
                },
                .miss => {}, // both pages drawn this frame
                .pending => return error.UnexpectedPending,
            }
        }
    }
    try testing.expect(c.stats.evicted_entries > 0);
    // Every surviving entry points at a page that still holds it.
    for (c.table.keys) |kb| if (kb != 0) {
        const k = GlyphKey.fromBits(kb);
        const e = c.lookup(k).hit;
        const bm = try r.rasterizeGlyph(&f.inst, k.glyph, key_mod.rasterParams(k, .{}));
        try expectAtlasHolds(&atlas, e, bm);
    };
}

test "glyph cache: prewarm makes ASCII resident" {
    var f: Fixture = undefined;
    try f.init("JetBrainsMono[wght].ttf");
    defer f.deinit();
    var rt: Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var atlas = try Atlas.init(testing.allocator, .{});
    defer atlas.deinit();
    var c: GlyphCache = undefined;
    // A zero budget: prewarm ignores it.
    try c.init(testing.allocator, &rt, &atlas, .{ .workers = 0, .sync_budget_ns = 0 });
    defer c.deinit();
    c.beginFrame(1);
    c.prewarm(f.source(), 1, key_mod.quantizeSize(13), &ascii);
    for (ascii) |cp| try testing.expect(c.lookup(f.key(cp, 13)) == .hit);
    try testing.expectEqual(gc.Lookup.miss, c.lookup(f.key('A', 14)));
    // Unknown instances resolve to nothing and prewarm nothing.
    c.prewarm(f.source(), 2, key_mod.quantizeSize(13), &ascii);
}

test "glyph cache: lookup allocates nothing" {
    var f: Fixture = undefined;
    try f.init("JetBrainsMono[wght].ttf");
    defer f.deinit();
    var rt: Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var atlas = try Atlas.init(failing.allocator(), .{ .page_size = 512 });
    defer atlas.deinit();
    var c: GlyphCache = undefined;
    try c.init(failing.allocator(), &rt, &atlas, .{ .workers = 0, .sync_budget_ns = std.math.maxInt(u64) });
    defer c.deinit();
    c.beginFrame(1);
    for ("hello world") |ch| _ = c.get(f.key(ch, 12), f.source());
    const before = failing.allocations;
    failing.fail_index = failing.alloc_index; // any further allocation fails
    for (0..1000) |i| {
        c.beginFrame(@intCast(2 + i / 100));
        for ("hello world") |ch| try testing.expect(c.lookup(f.key(ch, 12)) == .hit);
        try testing.expect(c.lookup(f.key('Z', 12)) == .miss);
    }
    try testing.expectEqual(before, failing.allocations);
}

test "glyph cache: failed raster stores an empty entry" {
    var f: Fixture = undefined;
    try f.init("JetBrainsMono[wght].ttf");
    defer f.deinit();
    var rt: Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var atlas = try Atlas.init(testing.allocator, .{ .page_size = 256 });
    defer atlas.deinit();
    var c: GlyphCache = undefined;
    try c.init(testing.allocator, &rt, &atlas, .{ .workers = 0, .sync_budget_ns = std.math.maxInt(u64) });
    defer c.deinit();
    c.beginFrame(1);
    // A glyph id past the face's glyph count is malformed.
    const k: GlyphKey = .{ .instance = 1, .glyph = 0xFFFF, .size_q = key_mod.quantizeSize(12) };
    const l = c.get(k, f.source());
    try testing.expect(l == .hit and l.hit.isEmpty());
    try testing.expectEqual(@as(u64, 1), c.stats.failures);
    _ = c.get(k, f.source());
    try testing.expectEqual(@as(u64, 1), c.stats.sync_rasters);
}
