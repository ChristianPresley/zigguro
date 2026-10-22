//! `GlyphCache`: where each glyph key's bitmap lives in the atlas, for the
//! UI/render thread only.
//!
//! The table is open-addressed with linear probing over two parallel
//! arrays (`keys`, `vals`): the key's bits (0 = empty) and an index into
//! `entries`. Deletion shifts later entries back, so there are no
//! tombstones. `beginFrame` grows the table past a load of 0.375, so a
//! frame's inserts keep it at or below 0.5; a frame that inserts more grows
//! it on insert.
//!
//! A miss is rasterized on the calling thread when it is cheap (coverage
//! at up to 48 px) and the frame's sync budget is not spent; otherwise it
//! goes to the `RasterQueue` and `lookup` reports `.pending` until
//! `onRasterDone` stores it.

const std = @import("std");
const zg_core = @import("zg_core");
const Allocator = std.mem.Allocator;
const Runtime = zg_core.runtime.Runtime;
const UiMsg = zg_core.runtime.UiMsg;
const atlas_mod = @import("atlas.zig");
const Atlas = atlas_mod.Atlas;
const AtlasEntry = atlas_mod.AtlasEntry;
const rasterizer = @import("../raster/rasterizer.zig");
const Rasterizer = rasterizer.Rasterizer;
const Bitmap = rasterizer.Bitmap;
const FaceInstance = @import("../ot/var/instance.zig").FaceInstance;
const key_mod = @import("glyph_key.zig");
const GlyphKey = key_mod.GlyphKey;
const raster_queue = @import("raster_queue.zig");
const RasterQueue = raster_queue.RasterQueue;

const log = std.log.scoped(.zg_text);

/// Result of a lookup.
pub const Lookup = union(enum) {
    /// Resident: draw it (an empty entry draws nothing).
    hit: AtlasEntry,
    /// Being rasterized on a worker; drawn on a later frame.
    pending,
    /// Not resident and not requested.
    miss,
};

/// What a key's instance id resolves to: the face instance and the
/// styles that are not part of the key.
pub const Resolved = struct {
    instance: *const FaceInstance,
    style: key_mod.Style = .{},
};

/// Resolves instance ids to faces (E03.F07's `FontRegistry` provides one;
/// tests use a fixed table). The resolved instance must stay alive while
/// any of its glyphs is pending.
pub const GlyphSource = struct {
    ctx: *const anyopaque,
    resolveFn: *const fn (ctx: *const anyopaque, key: GlyphKey) ?Resolved,

    /// The instance and styles for `key`, or null for an unknown instance.
    pub fn resolve(s: GlyphSource, key: GlyphKey) ?Resolved {
        return s.resolveFn(s.ctx, key);
    }
};

/// A monotonic nanosecond clock (injectable for tests).
pub const Clock = struct {
    ctx: ?*anyopaque,
    nowFn: *const fn (ctx: ?*anyopaque) u64,
};

const golden: u64 = 0x9E3779B97F4A7C15;
const none: u32 = std.math.maxInt(u32);

/// An open-addressed u64 → u32 map with linear probing and backward-shift
/// deletion. Key 0 marks an empty slot.
const KeyTable = struct {
    keys: []u64 = &.{},
    vals: []u32 = &.{},
    len: u32 = 0,
    log2: u6 = 0,

    fn init(gpa: Allocator, log2: u6) Allocator.Error!KeyTable {
        const cap = @as(usize, 1) << log2;
        const keys = try gpa.alloc(u64, cap);
        errdefer gpa.free(keys);
        const vals = try gpa.alloc(u32, cap);
        @memset(keys, 0);
        return .{ .keys = keys, .vals = vals, .log2 = log2 };
    }

    fn deinit(t: *KeyTable, gpa: Allocator) void {
        gpa.free(t.keys);
        gpa.free(t.vals);
        t.* = .{};
    }

    inline fn mask(t: *const KeyTable) usize {
        return t.keys.len - 1;
    }

    inline fn home(t: *const KeyTable, k: u64) usize {
        return @intCast((k *% golden) >> @intCast(@as(u7, 64) - t.log2));
    }

    inline fn find(t: *const KeyTable, k: u64) ?u32 {
        var i = t.home(k);
        while (true) : (i = (i + 1) & t.mask()) {
            const s = t.keys[i];
            if (s == k) return t.vals[i];
            if (s == 0) return null;
        }
    }

    /// Inserts or overwrites; the table must have a free slot.
    fn put(t: *KeyTable, k: u64, v: u32) void {
        var i = t.home(k);
        while (true) : (i = (i + 1) & t.mask()) {
            const s = t.keys[i];
            if (s == k) {
                t.vals[i] = v;
                return;
            }
            if (s == 0) {
                t.keys[i] = k;
                t.vals[i] = v;
                t.len += 1;
                return;
            }
        }
    }

    /// Removes `k`; false when absent.
    fn remove(t: *KeyTable, k: u64) bool {
        const m = t.mask();
        var i = t.home(k);
        while (true) : (i = (i + 1) & m) {
            const s = t.keys[i];
            if (s == 0) return false;
            if (s == k) break;
        }
        // Backward shift: pull later members of the probe run into the hole
        // when the hole lies between their home and their slot.
        var j = (i + 1) & m;
        while (t.keys[j] != 0) : (j = (j + 1) & m) {
            const h = t.home(t.keys[j]);
            if (((j -% h) & m) >= ((j -% i) & m)) {
                t.keys[i] = t.keys[j];
                t.vals[i] = t.vals[j];
                i = j;
            }
        }
        t.keys[i] = 0;
        t.len -= 1;
        return true;
    }

    /// Rehashes into a table of `2^log2` slots.
    fn resize(t: *KeyTable, gpa: Allocator, log2: u6) Allocator.Error!void {
        var n = try KeyTable.init(gpa, log2);
        for (t.keys, t.vals) |k, v| if (k != 0) n.put(k, v);
        t.deinit(gpa);
        t.* = n;
    }

    fn clear(t: *KeyTable) void {
        @memset(t.keys, 0);
        t.len = 0;
    }
};

const EntryData = struct {
    entry: AtlasEntry,
    last_frame: u32,
    key: u64,
    /// Next entry on the same atlas page (`none` ends the list).
    next: u32,
};

/// Counters for tests and the debug overlay.
pub const Stats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    sync_rasters: u64 = 0,
    async_submits: u64 = 0,
    failures: u64 = 0,
    evicted_entries: u64 = 0,
};

/// The cache. UI thread only; must not move after `init` (the atlas holds
/// a pointer to it for eviction).
pub const GlyphCache = struct {
    gpa: Allocator,
    rt: *Runtime,
    atlas: *Atlas,
    opts: Options,
    table: KeyTable,
    pending: KeyTable,
    entries: std.MultiArrayList(EntryData) = .empty,
    free_list: std.ArrayList(u32) = .empty,
    /// First entry of each atlas page's list.
    page_head: std.ArrayList(u32) = .empty,
    frame: u32 = 0,
    frame_start: u64 = 0,
    rast: Rasterizer,
    queue: ?*RasterQueue = null,
    logged_failure: bool = false,
    stats: Stats = .{},

    /// Tuning.
    pub const Options = struct {
        /// Time per frame for synchronous rasterization.
        sync_budget_ns: u64 = 1_000_000,
        /// log2 of the initial slot count (default 32 768).
        capacity_log2: u5 = 15,
        /// Raster worker threads; null picks `RasterQueue.defaultWorkers`,
        /// 0 disables async rasterization (misses over budget stay misses).
        workers: ?u8 = null,
        /// Clock for the sync budget; null uses the runtime's awake clock.
        clock: ?Clock = null,
    };

    /// A cache drawing into `atlas`, with workers on `rt.io`.
    pub fn init(c: *GlyphCache, gpa: Allocator, rt: *Runtime, atlas: *Atlas, opts: Options) !void {
        var table = try KeyTable.init(gpa, @max(opts.capacity_log2, 4));
        errdefer table.deinit(gpa);
        var pending = try KeyTable.init(gpa, 13); // 2 × the queue capacity
        errdefer pending.deinit(gpa);
        c.* = .{ .gpa = gpa, .rt = rt, .atlas = atlas, .opts = opts, .table = table, .pending = pending, .rast = Rasterizer.init(gpa) };
        const workers = opts.workers orelse RasterQueue.defaultWorkers();
        if (workers > 0) {
            const q = try gpa.create(RasterQueue);
            errdefer gpa.destroy(q);
            try q.init(gpa, rt.io, rt, workers);
            c.queue = q;
        }
        atlas.setEvictCallback(c, onEvict);
    }

    /// Stops the workers and frees everything. Results the workers already
    /// posted stay in the mailbox: pass them to `releaseResult`.
    pub fn deinit(c: *GlyphCache) void {
        if (c.queue) |q| {
            q.deinit();
            c.gpa.destroy(q);
        }
        c.rast.deinit();
        c.table.deinit(c.gpa);
        c.pending.deinit(c.gpa);
        c.entries.deinit(c.gpa);
        c.free_list.deinit(c.gpa);
        c.page_head.deinit(c.gpa);
        c.* = undefined;
    }

    fn now(c: *const GlyphCache) u64 {
        if (c.opts.clock) |k| return k.nowFn(k.ctx);
        const t = std.Io.Timestamp.now(c.rt.io, .awake);
        return @intCast(@max(0, t.nanoseconds));
    }

    /// Starts `frame`: stamps the LRU epoch, resets the sync budget and
    /// grows the table when its load is above 0.375.
    pub fn beginFrame(c: *GlyphCache, frame: u32) void {
        c.frame = frame;
        c.frame_start = c.now();
        if (c.table.len * 8 > c.table.keys.len * 3) c.table.resize(c.gpa, c.table.log2 + 1) catch {};
    }

    /// The entry for `key`: resident, pending or missing. No allocation,
    /// locks or atomics.
    pub inline fn lookup(c: *GlyphCache, key: GlyphKey) Lookup {
        const k = key.bits();
        if (c.table.find(k)) |idx| {
            const s = c.entries.slice();
            const e = s.items(.entry)[idx];
            const lf = &s.items(.last_frame)[idx];
            if (lf.* != c.frame) {
                lf.* = c.frame;
                if (!e.isEmpty()) c.atlas.touch(e.page, c.frame);
            }
            return .{ .hit = e };
        }
        if (c.pending.len != 0 and c.pending.find(k) != null) return .pending;
        return .miss;
    }

    /// `lookup`, and on a miss: rasterize now when the glyph is cheap and
    /// the frame's budget allows, else queue it for a worker.
    pub fn get(c: *GlyphCache, key: GlyphKey, src: GlyphSource) Lookup {
        const l = c.lookup(key);
        if (l != .miss) {
            if (l == .hit) c.stats.hits += 1;
            return l;
        }
        c.stats.misses += 1;
        const res = src.resolve(key) orelse return c.storeEmpty(key);
        if (key.isCheap() and c.now() -| c.frame_start < c.opts.sync_budget_ns) return c.rasterizeNow(key, res);
        const q = c.queue orelse return .miss;
        if (c.pending.len * 2 >= c.pending.keys.len) return .miss;
        q.submit(key, .{ .instance = res.instance, .params = key_mod.rasterParams(key, res.style) }) catch return .miss;
        c.pending.put(key.bits(), 0);
        c.stats.async_submits += 1;
        return .pending;
    }

    /// Stores a worker's result (a `raster_queue.ui_msg_kind` message from
    /// `Runtime.drain`) and frees it. Other kinds are ignored.
    pub fn onRasterDone(c: *GlyphCache, msg: UiMsg) void {
        if (msg.kind != raster_queue.ui_msg_kind) return;
        const res = raster_queue.resultOf(msg);
        defer raster_queue.destroyResult(c.gpa, res);
        _ = c.pending.remove(res.key.bits());
        if (c.table.find(res.key.bits()) != null) return;
        if (res.failed) {
            c.noteFailure(res.key);
            _ = c.storeEmpty(res.key);
            return;
        }
        _ = c.storeBitmap(res.key, &res.bitmap);
    }

    /// Frees a `raster_queue.ui_msg_kind` message's result without storing
    /// it (shutdown).
    pub fn releaseResult(gpa: Allocator, msg: UiMsg) void {
        if (msg.kind != raster_queue.ui_msg_kind) return;
        raster_queue.destroyResult(gpa, raster_queue.resultOf(msg));
    }

    /// Rasterizes `cps` (via the instance's cmap) synchronously at
    /// `size_q`, grayscale, regardless of the frame budget.
    pub fn prewarm(c: *GlyphCache, src: GlyphSource, instance: u18, size_q: u13, cps: []const u21) void {
        c.prewarmMode(src, instance, size_q, cps, .gray);
    }

    /// `prewarm` in a given render mode.
    pub fn prewarmMode(c: *GlyphCache, src: GlyphSource, instance: u18, size_q: u13, cps: []const u21, mode: key_mod.RenderMode) void {
        const probe: GlyphKey = .{ .instance = instance, .glyph = 0, .size_q = size_q, .mode = mode };
        const res = src.resolve(probe) orelse return;
        for (cps) |cp| {
            var key = probe;
            key.glyph = res.instance.face.glyphIndex(cp);
            if (c.lookup(key) == .miss) _ = c.rasterizeNow(key, res);
        }
    }

    /// Stores `e` for `key` as if it had been rasterized (benches and
    /// tools that fill the atlas themselves). `e.page` must exist.
    pub fn put(c: *GlyphCache, key: GlyphKey, e: AtlasEntry) Allocator.Error!void {
        if (c.store(key, e) == .miss) return error.OutOfMemory;
    }

    /// Resident entries.
    pub fn count(c: *const GlyphCache) usize {
        return c.table.len;
    }

    /// Drops every entry (e.g. after a font change). Pending jobs still
    /// arrive and are stored.
    pub fn clear(c: *GlyphCache) void {
        c.table.clear();
        c.entries.shrinkRetainingCapacity(0);
        c.free_list.clearRetainingCapacity();
        @memset(c.page_head.items, none);
    }

    fn rasterizeNow(c: *GlyphCache, key: GlyphKey, res: Resolved) Lookup {
        c.stats.sync_rasters += 1;
        const bm = c.rast.rasterizeGlyph(res.instance, key.glyph, key_mod.rasterParams(key, res.style)) catch |e| switch (e) {
            error.OutOfMemory => return .miss,
            else => {
                c.noteFailure(key);
                return c.storeEmpty(key);
            },
        };
        return c.storeBitmap(key, &bm);
    }

    fn noteFailure(c: *GlyphCache, key: GlyphKey) void {
        c.stats.failures += 1;
        if (c.logged_failure) return;
        c.logged_failure = true;
        log.warn("glyph {d} of instance {d} failed to rasterize; drawing nothing (logged once)", .{ key.glyph, key.instance });
    }

    fn storeBitmap(c: *GlyphCache, key: GlyphKey, bm: *const Bitmap) Lookup {
        const e = c.atlas.insert(bm, c.frame) catch |err| switch (err) {
            // Every page was drawn this frame: try again next frame.
            error.AtlasFull, error.OutOfMemory => return .miss,
            error.TooLarge => return c.storeEmpty(key),
        };
        return c.store(key, e);
    }

    fn storeEmpty(c: *GlyphCache, key: GlyphKey) Lookup {
        return c.store(key, .{});
    }

    fn store(c: *GlyphCache, key: GlyphKey, e: AtlasEntry) Lookup {
        c.reserve() catch return .miss;
        const idx: u32 = if (c.free_list.pop()) |i| i else blk: {
            const i: u32 = @intCast(c.entries.len);
            c.entries.appendAssumeCapacity(undefined);
            break :blk i;
        };
        var next = none;
        if (!e.isEmpty()) {
            next = c.page_head.items[e.page];
            c.page_head.items[e.page] = idx;
        }
        c.entries.set(idx, .{ .entry = e, .last_frame = c.frame, .key = key.bits(), .next = next });
        c.table.put(key.bits(), idx);
        return .{ .hit = e };
    }

    /// Makes room for one more entry (table slot, entry, free-list slot and
    /// a head for every atlas page).
    fn reserve(c: *GlyphCache) Allocator.Error!void {
        if ((c.table.len + 1) * 2 > c.table.keys.len) try c.table.resize(c.gpa, c.table.log2 + 1);
        try c.entries.ensureUnusedCapacity(c.gpa, 1);
        try c.free_list.ensureTotalCapacity(c.gpa, c.entries.len + 1);
        const pages = c.atlas.pages.items.len;
        if (c.page_head.items.len < pages) try c.page_head.appendNTimes(c.gpa, none, pages - c.page_head.items.len);
    }

    /// Atlas eviction: drops every entry on `page`.
    fn onEvict(ctx: *anyopaque, page: u16) void {
        const c: *GlyphCache = @ptrCast(@alignCast(ctx));
        if (page >= c.page_head.items.len) return;
        const s = c.entries.slice();
        var i = c.page_head.items[page];
        while (i != none) {
            const next = s.items(.next)[i];
            _ = c.table.remove(s.items(.key)[i]);
            c.free_list.appendAssumeCapacity(i);
            c.stats.evicted_entries += 1;
            i = next;
        }
        c.page_head.items[page] = none;
    }
};

test "glyph cache: insert/lookup/delete random" {
    const gpa = std.testing.allocator;
    var t = try KeyTable.init(gpa, 12);
    defer t.deinit(gpa);
    var model: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer model.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    for (0..1_000_000) |i| {
        // A small key space so removes and overwrites hit often.
        const k = 1 + rnd.uintLessThan(u64, 3000);
        if (rnd.boolean() and t.len < 2048) {
            t.put(k, @intCast(i));
            try model.put(gpa, k, @intCast(i));
        } else {
            try std.testing.expectEqual(model.remove(k), t.remove(k));
        }
        if (i % 4096 == 0) {
            try std.testing.expectEqual(model.count(), t.len);
            var it = model.iterator();
            while (it.next()) |e| try std.testing.expectEqual(e.value_ptr.*, t.find(e.key_ptr.*).?);
        }
        const q = 1 + rnd.uintLessThan(u64, 3000);
        try std.testing.expectEqual(model.get(q), t.find(q));
    }
}

test "glyph cache: backward shift deletion keeps probes valid" {
    const gpa = std.testing.allocator;
    var t = try KeyTable.init(gpa, 6);
    defer t.deinit(gpa);
    // Collect keys sharing one home slot, plus a few that land right after
    // it, so removals in the middle of a run must shift the rest back.
    var same: [6]u64 = undefined;
    var n: usize = 0;
    var k: u64 = 1;
    const target = t.home(1);
    while (n < same.len) : (k += 1) if (t.home(k) == target) {
        same[n] = k;
        n += 1;
    };
    var near: [3]u64 = undefined;
    n = 0;
    k = 1;
    while (n < near.len) : (k += 1) if (t.home(k) == (target + 1) & t.mask() and std.mem.indexOfScalar(u64, &same, k) == null) {
        near[n] = k;
        n += 1;
    };
    for (same, 0..) |key, i| t.put(key, @intCast(i));
    for (near, 0..) |key, i| t.put(key, @intCast(100 + i));
    for ([_]usize{ 2, 0, 5 }) |i| try std.testing.expect(t.remove(same[i]));
    for (same, 0..) |key, i| {
        const want: ?u32 = if (i == 0 or i == 2 or i == 5) null else @intCast(i);
        try std.testing.expectEqual(want, t.find(key));
    }
    for (near, 0..) |key, i| try std.testing.expectEqual(@as(?u32, @intCast(100 + i)), t.find(key));
    try std.testing.expectEqual(@as(u32, 6), t.len);
}

test "glyph cache: resize keeps every key" {
    const gpa = std.testing.allocator;
    var t = try KeyTable.init(gpa, 4);
    defer t.deinit(gpa);
    for (1..8) |i| t.put(i * 7919, @intCast(i));
    try t.resize(gpa, 9);
    for (1..8) |i| try std.testing.expectEqual(@as(?u32, @intCast(i)), t.find(i * 7919));
}
