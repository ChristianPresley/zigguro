//! Tiled rasterization (E13.F07.S01.T02): a display list scaled to
//! device pixels, cut into 256×256 tiles of premultiplied RGBA8, and an
//! LRU cache of tiles keyed by (display-list hash, scale, tile).
//!
//! Fills (and stroke outlines) are flattened in device space and
//! accumulated with E03's coverage rasterizer: |signed area| clamped to
//! 1, the non-zero rule for same-direction overlaps. Segments are clipped
//! to the tile exactly (parts above or below dropped, parts left or right
//! moved onto the tile's edge as vertical lines, which carries their
//! area), so tiles meet without seams. Text is not rasterized here: the UI draws it as
//! glyph quads from E03's atlas so it stays crisp.
//!
//! `rasterizeTiles` runs tiles on workers (`Io.Group`); call it off the
//! UI thread. The cache is shared: workers insert, the UI looks up and
//! trims.

const std = @import("std");
const zg_text = @import("zg_text");
const path_mod = @import("path.zig");
const stroke_mod = @import("stroke.zig");
const dl_mod = @import("display_list.zig");
const composite = @import("composite.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Rect = path_mod.Rect;
const Affine = path_mod.Affine;
const DisplayList = dl_mod.DisplayList;
const Accumulator = zg_text.raster.coverage.Accumulator;

pub const tile_size = 256;
pub const tile_bytes = tile_size * tile_size * 4;
/// Flattening tolerance in device pixels.
pub const device_tolerance: f32 = 0.25;

/// Per-thread buffers.
pub const Scratch = struct {
    acc: Accumulator = .{},
    cov: []u8 = &.{},
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator) Scratch {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.acc.deinit(gpa);
        gpa.free(s.cov);
        s.arena.deinit();
    }
};

/// Rasterizes tile (`tx`, `ty`) of `dl` at `scale` device pixels per
/// unit into `out` (`tile_bytes`, premultiplied RGBA, cleared first).
/// Tile (0, 0) has its corner at the display list's origin.
pub fn rasterizeTile(gpa: Allocator, s: *Scratch, dl: *const DisplayList, scale: f32, tx: i32, ty: i32, out: []u8) !void {
    std.debug.assert(out.len == tile_bytes);
    @memset(out, 0);
    if (s.cov.len < tile_size * tile_size) {
        gpa.free(s.cov);
        s.cov = try gpa.alloc(u8, tile_size * tile_size);
    }
    defer _ = s.arena.reset(.retain_capacity);
    const a = s.arena.allocator();
    const ox: f32 = @floatFromInt(@as(i64, tx) * tile_size);
    const oy: f32 = @floatFromInt(@as(i64, ty) * tile_size);
    // Display-list units → tile pixels.
    const m: Affine = .scaleTranslate(scale, -ox, -oy);
    const full: Rect = .{ .x0 = 0, .y0 = 0, .x1 = tile_size, .y1 = tile_size };

    var clips: std.ArrayListUnmanaged(Rect) = .empty;
    var clip = full;
    for (dl.items) |it| switch (it) {
        .clip_push => |r| {
            try clips.append(a, clip);
            const tr: Rect = .{ .x0 = r.x0 * scale - ox, .y0 = r.y0 * scale - oy, .x1 = r.x1 * scale - ox, .y1 = r.y1 * scale - oy };
            clip = clip.intersect(tr);
        },
        .clip_pop => clip = clips.pop() orelse full,
        .text => {},
        .fill => |f| try fillPath(gpa, s, f.path, m, scale, clip, f.color, out),
        .stroke => |st| {
            const outline = if (st.tol * scale > device_tolerance) blk: {
                // Zoomed past the recorded outline's precision: stroke
                // again for this scale.
                const p = try a.create(path_mod.Path);
                p.* = try stroke_mod.strokeToFill(a, st.path, st.style, device_tolerance / scale);
                break :blk p;
            } else st.outline;
            try fillPath(gpa, s, outline, m, scale, clip, st.color, out);
        },
    };
}

fn fillPath(gpa: Allocator, s: *Scratch, p: *const path_mod.Path, m: Affine, scale: f32, clip: Rect, color: dl_mod.Color, out: []u8) !void {
    if (clip.isEmpty()) return;
    const b = p.bounds();
    if (!(b.x0 <= b.x1 and b.y0 <= b.y1)) return;
    const tb: Rect = .{ .x0 = b.x0 * scale + m.e, .y0 = b.y0 * scale + m.f, .x1 = b.x1 * scale + m.e, .y1 = b.y1 * scale + m.f };
    const vis = tb.intersect(clip);
    if (!(vis.x0 < vis.x1 and vis.y0 < vis.y1)) return;
    // Only the pixels the fill can touch: a bar or a marker costs its own
    // area, not the tile's.
    const px: composite.PxRect = .{
        .x0 = @intFromFloat(@max(0, @floor(vis.x0))),
        .y0 = @intFromFloat(@max(0, @floor(vis.y0))),
        .x1 = @intFromFloat(@min(tile_size, @ceil(vis.x1))),
        .y1 = @intFromFloat(@min(tile_size, @ceil(vis.y1))),
    };
    const bw = px.x1 - px.x0;
    const bh = px.y1 - px.y0;
    if (bw == 0 or bh == 0) return;
    var mb = m;
    mb.e -= @floatFromInt(px.x0);
    mb.f -= @floatFromInt(px.y0);
    try s.acc.reset(gpa, bw, bh);
    addPath(&s.acc, p, mb);
    s.acc.integrate(s.cov, bw);
    // Clips are pixel-aligned (axis-aligned rectangles at chart edges).
    const stride = tile_size * 4;
    composite.srcOver(out[px.y0 * stride + px.x0 * 4 ..], stride, s.cov, bw, color, .{ .x0 = 0, .y0 = 0, .x1 = bw, .y1 = bh });
}

/// Adds every subpath of `p` (transformed by `m`) to `acc`, each
/// closed. A subpath whose bounds miss the bitmap is skipped: a closed
/// outline wholly beside the bitmap adds nothing inside it, and a
/// stroked series is hundreds of small pieces of which a tile sees few.
pub fn addPath(acc: *Accumulator, p: *const path_mod.Path, m: Affine) void {
    const verbs = p.verbs.items;
    const pts = p.points.items;
    const w: f32 = @floatFromInt(acc.w);
    const h: f32 = @floatFromInt(acc.h);
    var vi: usize = 0;
    var pi: usize = 0;
    while (vi < verbs.len) {
        var ve = vi;
        var pe = pi;
        while (ve < verbs.len and (ve == vi or verbs[ve] != .move)) : (ve += 1) pe += path_mod.Path.pointCount(verbs[ve]);
        defer {
            vi = ve;
            pi = pe;
        }
        if (pe - pi < 2) continue;
        var b: Rect = .empty;
        for (pts[pi..pe]) |q| b = b.include(m.apply(q));
        if (!(b.x0 < w and b.x1 > 0 and b.y0 < h and b.y1 > 0)) continue;
        var sink: Sink = .{ .acc = acc };
        var start = m.apply(pts[pi]);
        var cur = start;
        var k = pi;
        for (verbs[vi..ve]) |v| {
            switch (v) {
                .move => {
                    start = m.apply(pts[k]);
                    cur = start;
                },
                .line => {
                    const q = m.apply(pts[k]);
                    clipLine(acc, cur, q);
                    cur = q;
                },
                .quad => {
                    const p2 = m.apply(pts[k + 1]);
                    zg_text.raster.flatten.quadTo(&sink, cur, m.apply(pts[k]), p2, device_tolerance);
                    cur = p2;
                },
                .cubic => {
                    const p3 = m.apply(pts[k + 2]);
                    zg_text.raster.flatten.cubicTo(&sink, cur, m.apply(pts[k]), m.apply(pts[k + 1]), p3, device_tolerance);
                    cur = p3;
                },
                .close => {
                    clipLine(acc, cur, start);
                    cur = start;
                },
            }
            k += path_mod.Path.pointCount(v);
        }
        // Every subpath is filled closed.
        if (cur[0] != start[0] or cur[1] != start[1]) clipLine(acc, cur, start);
    }
}

const Sink = struct {
    acc: *Accumulator,
    pub fn segment(sk: *Sink, p0: [2]f32, p1: [2]f32) void {
        clipLine(sk.acc, p0, p1);
    }
};

/// Adds `p0`→`p1` to `acc`, clipped to its bitmap so that the area
/// inside is exact.
pub fn clipLine(acc: *Accumulator, p0_in: [2]f32, p1_in: [2]f32) void {
    if (!std.math.isFinite(p0_in[0]) or !std.math.isFinite(p0_in[1]) or !std.math.isFinite(p1_in[0]) or !std.math.isFinite(p1_in[1])) return;
    const h: f32 = @floatFromInt(acc.h);
    const w: f32 = @floatFromInt(acc.w);
    var p0 = p0_in;
    var p1 = p1_in;
    // Rows outside the bitmap hold no area: cut to [0, h].
    if ((p0[1] <= 0 and p1[1] <= 0) or (p0[1] >= h and p1[1] >= h) or p0[1] == p1[1]) return;
    inline for (.{ 0, 1 }) |edge| {
        const ey: f32 = if (edge == 0) 0 else h;
        const out0 = if (edge == 0) p0[1] < ey else p0[1] > ey;
        const out1 = if (edge == 0) p1[1] < ey else p1[1] > ey;
        if (out0 != out1) {
            const t = (ey - p0[1]) / (p1[1] - p0[1]);
            const q = [2]f32{ p0[0] + (p1[0] - p0[0]) * t, ey };
            if (out0) p0 = q else p1 = q;
        }
    }
    // Columns: split at x = 0 and x = w; outside parts become vertical
    // edges on the boundary.
    var pts: [4][2]f32 = undefined;
    var n: usize = 0;
    pts[n] = p0;
    n += 1;
    var cuts: [2]f32 = undefined;
    var nc: usize = 0;
    inline for (.{ 0, 1 }) |edge| {
        const ex: f32 = if (edge == 0) 0 else w;
        if ((p0[0] < ex) != (p1[0] < ex) and p0[0] != p1[0]) {
            cuts[nc] = (ex - p0[0]) / (p1[0] - p0[0]);
            nc += 1;
        }
    }
    if (nc == 2 and cuts[0] > cuts[1]) std.mem.swap(f32, &cuts[0], &cuts[1]);
    for (cuts[0..nc]) |t| {
        pts[n] = .{ p0[0] + (p1[0] - p0[0]) * t, p0[1] + (p1[1] - p0[1]) * t };
        n += 1;
    }
    pts[n] = p1;
    n += 1;
    for (pts[0 .. n - 1], pts[1..n]) |a, b| {
        const mid = (a[0] + b[0]) / 2;
        const x: ?f32 = if (mid < 0) 0 else if (mid > w) w else null;
        if (x) |edge_x| acc.line(.{ edge_x, a[1] }, .{ edge_x, b[1] }) else lineSplit(acc, a, b);
    }
}

/// The accumulator steps x row by row, which drifts by ~1e-4 px a row
/// at large x: long edges go in pieces of at most `split_rows` rows,
/// each placed from the segment's own endpoints, so a tile and a whole
/// bitmap agree to a level.
const split_rows = 16;

fn lineSplit(acc: *Accumulator, a: [2]f32, b: [2]f32) void {
    const rows = @abs(b[1] - a[1]);
    if (!(rows > split_rows)) return acc.line(a, b);
    const n: u32 = @intFromFloat(@ceil(rows / split_rows));
    var prev = a;
    for (1..n + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const q: [2]f32 = if (i == n) b else .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t };
        acc.line(prev, q);
        prev = q;
    }
}

/// The tiles covering `rect` (device pixels).
pub fn tilesFor(rect: Rect) struct { x0: i32, y0: i32, x1: i32, y1: i32 } {
    const ts: f32 = tile_size;
    return .{
        .x0 = @intFromFloat(@floor(rect.x0 / ts)),
        .y0 = @intFromFloat(@floor(rect.y0 / ts)),
        .x1 = @intFromFloat(@ceil(rect.x1 / ts)),
        .y1 = @intFromFloat(@ceil(rect.y1 / ts)),
    };
}

/// Scales are keyed to a thousandth.
pub fn quantizeScale(scale: f32) u32 {
    return @intFromFloat(@round(@max(0, scale) * 1000));
}

pub const Key = struct {
    hash: u64,
    scale_q: u32,
    tx: i32,
    ty: i32,
};

pub const Tile = struct {
    key: Key,
    pixels: []u8,
    last_used: u64,
    /// Opaque to the cache (the UI keeps its texture id here).
    user: u64 = 0,
};

/// An LRU cache of tiles under a byte budget.
pub const TileCache = struct {
    gpa: Allocator,
    budget: usize,
    used: usize = 0,
    mutex: Io.Mutex = .init,
    map: std.AutoHashMapUnmanaged(Key, *Tile) = .empty,
    tick: u64 = 0,
    /// Pixel buffers of evicted tiles, reused by `takePixels` (fresh
    /// pages cost a fault each; a 20-tile view is 5 MiB of them).
    spare: std.ArrayListUnmanaged([]u8) = .empty,
    /// Worker scratch kept between `rasterizeTiles` calls.
    scratch: std.ArrayListUnmanaged(*Scratch) = .empty,
    /// Called (on the trimming thread) for every tile evicted, before
    /// its pixels are freed.
    on_evict: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, t: *Tile) void } = null,

    pub const default_budget = 64 << 20;
    /// At most this many spare buffers are kept (4 MiB).
    pub const max_spare = 16;

    pub fn init(gpa: Allocator, budget_bytes: usize) TileCache {
        return .{ .gpa = gpa, .budget = budget_bytes };
    }

    pub fn deinit(c: *TileCache) void {
        var it = c.map.valueIterator();
        while (it.next()) |t| c.free(t.*);
        c.map.deinit(c.gpa);
        for (c.spare.items) |px| c.gpa.free(px);
        c.spare.deinit(c.gpa);
        for (c.scratch.items) |sc| {
            sc.deinit(c.gpa);
            c.gpa.destroy(sc);
        }
        c.scratch.deinit(c.gpa);
    }

    fn free(c: *TileCache, t: *Tile) void {
        if (c.on_evict) |e| e.f(e.ctx, t);
        c.recycle(t.pixels);
        c.gpa.destroy(t);
    }

    /// Mutex held.
    fn recycle(c: *TileCache, px: []u8) void {
        if (px.len == tile_bytes and c.spare.items.len < max_spare) {
            if (c.spare.append(c.gpa, px)) return else |_| {}
        }
        c.gpa.free(px);
    }

    /// A `tile_bytes` buffer for `put`: a spare one or a new one.
    pub fn takePixels(c: *TileCache, io: Io) ![]u8 {
        {
            c.mutex.lockUncancelable(io);
            defer c.mutex.unlock(io);
            if (c.spare.pop()) |px| return px;
        }
        return c.gpa.alloc(u8, tile_bytes);
    }

    fn takeScratch(c: *TileCache, io: Io) !*Scratch {
        {
            c.mutex.lockUncancelable(io);
            defer c.mutex.unlock(io);
            if (c.scratch.pop()) |sc| return sc;
        }
        const sc = try c.gpa.create(Scratch);
        sc.* = .init(c.gpa);
        return sc;
    }

    fn returnScratch(c: *TileCache, io: Io, sc: *Scratch) void {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        c.scratch.append(c.gpa, sc) catch {
            sc.deinit(c.gpa);
            c.gpa.destroy(sc);
        };
    }

    /// Evicts every tile.
    pub fn clear(c: *TileCache, io: Io) void {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        var it = c.map.valueIterator();
        while (it.next()) |t| c.free(t.*);
        c.map.clearRetainingCapacity();
        c.used = 0;
    }

    /// The tile, marked used.
    pub fn get(c: *TileCache, io: Io, key: Key) ?*Tile {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        const t = c.map.get(key) orelse return null;
        c.tick += 1;
        t.last_used = c.tick;
        return t;
    }

    pub fn contains(c: *TileCache, io: Io, key: Key) bool {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        return c.map.contains(key);
    }

    /// Adds a tile, taking `pixels` (allocated with the cache's gpa).
    /// A tile already there is kept and `pixels` freed.
    pub fn put(c: *TileCache, io: Io, key: Key, pixels: []u8) !void {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        const gop = try c.map.getOrPut(c.gpa, key);
        if (gop.found_existing) {
            c.recycle(pixels);
            return;
        }
        const t = c.gpa.create(Tile) catch |e| {
            c.map.removeByPtr(gop.key_ptr);
            return e;
        };
        c.tick += 1;
        t.* = .{ .key = key, .pixels = pixels, .last_used = c.tick };
        gop.value_ptr.* = t;
        c.used += pixels.len;
    }

    /// Evicts least recently used tiles until the cache fits its budget,
    /// sparing tiles used at or after `keep_since` (this frame's).
    pub fn trim(c: *TileCache, io: Io, keep_since: u64) void {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        while (c.used > c.budget) {
            var oldest: ?*Tile = null;
            var it = c.map.valueIterator();
            while (it.next()) |t| {
                if (t.*.last_used >= keep_since) continue;
                if (oldest == null or t.*.last_used < oldest.?.last_used) oldest = t.*;
            }
            const o = oldest orelse return;
            _ = c.map.remove(o.key);
            c.used -= o.pixels.len;
            c.free(o);
        }
    }

    /// The current tick (pass to `trim` to spare what is used after it).
    pub fn now(c: *TileCache, io: Io) u64 {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        return c.tick + 1;
    }

    pub fn count(c: *TileCache, io: Io) usize {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        return c.map.count();
    }
};

/// Rasterizes `keys` (all of `dl` at the keys' scale) on workers and
/// puts them in `cache` (allocating with the cache's allocator). Blocks
/// until done; run it off the UI thread.
pub fn rasterizeTiles(io: Io, cache: *TileCache, dl: *const DisplayList, keys: []const Key, threads: usize) !void {
    if (keys.len == 0) return;
    const Job = struct {
        next: std.atomic.Value(usize) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),
        keys: []const Key,
        dl: *const DisplayList,
        cache: *TileCache,
        io: Io,

        fn work(j: *@This()) void {
            const s = j.cache.takeScratch(j.io) catch {
                j.failed.store(true, .release);
                return;
            };
            defer j.cache.returnScratch(j.io, s);
            while (!j.failed.load(.acquire)) {
                const i = j.next.fetchAdd(1, .monotonic);
                if (i >= j.keys.len) return;
                const k = j.keys[i];
                j.one(s, k) catch {
                    j.failed.store(true, .release);
                    return;
                };
            }
        }

        fn one(j: *@This(), s: *Scratch, k: Key) !void {
            const px = try j.cache.takePixels(j.io);
            errdefer j.cache.gpa.free(px);
            try rasterizeTile(j.cache.gpa, s, j.dl, @as(f32, @floatFromInt(k.scale_q)) / 1000, k.tx, k.ty, px);
            try j.cache.put(j.io, k, px);
        }
    };
    var job: Job = .{ .keys = keys, .dl = dl, .cache = cache, .io = io };
    const n = @max(1, @min(threads, keys.len));
    if (n == 1) {
        job.work();
    } else {
        var group: Io.Group = .init;
        for (0..n) |_| group.async(io, Job.work, .{&job});
        try group.await(io);
    }
    if (job.failed.load(.acquire)) return error.OutOfMemory;
}
