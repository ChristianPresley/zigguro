//! The image cache (E04.F06.S02.T02): decodes images on worker threads,
//! keeps the decoded pixels under a CPU budget and the textures under a
//! GPU budget, and plays animations.
//!
//! - `request` starts a decode job (`App.spawn`). A path is read on the
//!   worker. A JPEG much larger than the wanted size first posts a preview
//!   from a DCT-scaled decode, then the full image; other formats post the
//!   full image only. Results reach the UI thread through `App.post`, so
//!   the UI thread never waits on IO or decoding.
//! - `use` (from a view's build) puts the image on the GPU through
//!   `App.images`, which the Host mirrors into each window's renderer.
//!   Images larger than `max_texture_side` are downscaled to it (instead
//!   of tiling: E02 has no tiled textures).
//! - Both budgets evict least recently used entries first, never one the
//!   current frame used (pinned). A GPU eviction keeps the pixels; a CPU
//!   eviction drops pixels and texture and keeps the source, so an image
//!   still referenced decodes again when it is next used. Textures always
//!   have their pixels on the CPU (the Host may need to upload them to a
//!   new window or after a lost device).
//! - Every change notifies one entity; image views observe it.
//! - Animations advance on window timers, only while their view keeps
//!   using them and reduced motion is off.
//!
//! The cache must stay at one address after the first `request`.

const std = @import("std");
const image = @import("image.zig");
const decode_mod = @import("decode.zig");
const jpeg = @import("jpeg.zig");
const downscale_mod = @import("downscale.zig");
const textures = @import("textures.zig");
const AnimPlayer = @import("anim_player.zig").AnimPlayer;
const app_mod = @import("../core/app.zig");
const view_mod = @import("../core/view.zig");
const window_mod = @import("../core/window.zig");
const canvas = @import("../paint/canvas.zig");
const geom = @import("../core/geom.zig");

const Allocator = std.mem.Allocator;
const App = app_mod.App;
const Window = window_mod.Window;
const TextureId = canvas.TextureId;
const Image = image.Image;

/// A requested image (one reference; see `release`).
pub const Handle = enum(u32) { _ };

/// Why an image has no pixels.
pub const LoadError = image.DecodeError || error{ ReadFailed, NotFound };

/// Where an image comes from.
pub const Source = union(enum) {
    /// Encoded bytes; the cache takes ownership (freed with `gpa`).
    bytes: []u8,
    /// A file, read on a worker (the cache copies the path).
    path: []const u8,
    /// An image `insert`ed under this key.
    key: u64,
};

/// What an image is.
pub const TexInfo = struct {
    /// The full image size (upright).
    w: u32,
    h: u32,
    /// The size of the pixels on hand (smaller for a preview or an image
    /// past `max_texture_side`).
    px_w: u32,
    px_h: u32,
    format: image.Format,
    frames: u32 = 1,
    /// The encoded size (0 when inserted decoded).
    file_size: u64 = 0,
};

/// An image's progress.
pub const Status = union(enum) { loading, preview: TexInfo, ready: TexInfo, failed: LoadError };

/// What `use` gives a view to draw.
pub const Use = struct {
    tex: TextureId,
    info: TexInfo,
    /// The animation frame showing.
    frame: u32 = 0,
    preview: bool = false,
};

/// Budgets and limits.
pub const Options = struct {
    cpu_bytes: u64 = 512 << 20,
    gpu_bytes: u64 = 256 << 20,
    /// Reads paths; the app runtime's when null (required without one).
    io: ?std.Io = null,
    limits: image.Limits = .{},
    /// Longer textures are downscaled.
    max_texture_side: u32 = 8192,
    /// Physical pixels per logical pixel (a preview is worth it when the
    /// image exceeds twice the wanted side at this scale).
    scale: f32 = 1,
};

const State = enum { loading, preview, ready, failed, evicted };

const Entry = struct {
    used: bool = false,
    refs: u32 = 0,
    key: u64 = 0,
    /// The job generation; results of older jobs are dropped.
    gen: u32 = 0,
    /// The source, while no job holds it.
    path: ?[]u8 = null,
    bytes: ?[]u8 = null,
    want_side: u32 = 0,
    state: State = .loading,
    err: LoadError = error.Malformed,
    img: ?Image = null,
    delays: []u32 = &.{},
    info: TexInfo = undefined,
    tex: TextureId = .none,
    tex_frame: u32 = 0,
    gpu_bytes: u64 = 0,
    cpu_bytes: u64 = 0,
    /// `App.frame_epoch` when last used (pinned while it is current).
    epoch: u64 = 0,
    /// LRU stamp.
    tick: u64 = 0,
    player: AnimPlayer = .{},
    /// Used since its animation last advanced (it is on screen).
    seen: bool = false,
};

/// See the file comment.
pub const ImageCache = struct {
    gpa: Allocator,
    app: *App,
    opts: Options,
    entries: std.ArrayList(Entry) = .empty,
    free: std.ArrayList(u32) = .empty,
    by_key: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// Notified on every change.
    entity: view_mod.EntityId,
    cpu_used: u64 = 0,
    gpu_used: u64 = 0,
    tick: u64 = 0,
    /// Jobs not yet delivered.
    inflight: u32 = 0,
    /// Jobs whose result could not be posted.
    lost: std.atomic.Value(u32) = .init(0),
    closing: bool = false,
    timer_win: ?*Window = null,
    timer: Window.TimerId = .none,
    timer_at: u64 = 0,
    checker_tex: TextureId = .none,
    checker_key: u64 = 0,
    checker_px: []u8 = &.{},

    /// An empty cache.
    pub fn init(gpa: Allocator, app: *App, opts: Options) !ImageCache {
        const e = try app.new(u8, 0);
        return .{ .gpa = gpa, .app = app, .opts = opts, .entity = e.id };
    }

    /// Waits for running jobs, then frees every image and texture.
    pub fn deinit(c: *ImageCache) void {
        c.closing = true;
        while (c.inflight > c.lost.load(.acquire)) {
            if (c.app.drainMessages() == 0) std.Thread.yield() catch {};
        }
        if (c.timer != .none) if (c.timer_win) |w| w.cancelTimer(c.timer);
        for (c.entries.items, 0..) |e, i| if (e.used) c.removeEntry(@intCast(i));
        if (c.checker_tex != .none) c.app.images.remove(c.gpa, c.checker_tex);
        c.gpa.free(c.checker_px);
        c.entries.deinit(c.gpa);
        c.free.deinit(c.gpa);
        c.by_key.deinit(c.gpa);
        c.app.release(c.entity);
        c.* = undefined;
    }

    /// Requests an image decoded for a view about `want_side` logical
    /// pixels on its longer side (0: no preview). The same source shares
    /// one entry.
    pub fn request(c: *ImageCache, src: Source, want_side: u32) Allocator.Error!Handle {
        const key = switch (src) {
            .bytes => |b| std.hash.Wyhash.hash(1, b),
            .path => |p| std.hash.Wyhash.hash(2, p),
            .key => |k| k,
        };
        if (c.by_key.get(key)) |i| {
            if (src == .bytes) c.gpa.free(src.bytes);
            const e = &c.entries.items[i];
            e.refs += 1;
            e.want_side = @max(e.want_side, want_side);
            return @enumFromInt(i);
        }
        const i = c.newEntry(key) catch |err| {
            if (src == .bytes) c.gpa.free(src.bytes);
            return err;
        };
        const e = &c.entries.items[i];
        e.want_side = want_side;
        switch (src) {
            .bytes => |b| e.bytes = b,
            .path => |p| e.path = c.gpa.dupe(u8, p) catch |err| {
                c.removeEntry(i);
                return err;
            },
            .key => {
                e.state = .failed;
                e.err = error.NotFound;
                return @enumFromInt(i);
            },
        }
        c.startJob(i);
        return @enumFromInt(i);
    }

    /// Adds a decoded image under `key` (the cache owns it now).
    pub fn insert(c: *ImageCache, key: u64, img: Image) Allocator.Error!Handle {
        var m = img;
        if (c.by_key.get(key)) |old| c.removeEntry(old);
        const i = c.newEntry(key) catch |err| {
            m.deinit(c.gpa);
            return err;
        };
        c.setImage(i, m, false, .{ .w = m.w, .h = m.h, .px_w = m.w, .px_h = m.h, .format = m.format, .frames = @intCast(@max(1, m.frames.len)) }) catch {
            c.entries.items[i].state = .failed;
            c.entries.items[i].err = error.OutOfMemory;
        };
        return @enumFromInt(i);
    }

    /// The image's progress.
    pub fn status(c: *const ImageCache, h: Handle) Status {
        const e = &c.entries.items[@intFromEnum(h)];
        return switch (e.state) {
            .loading, .evicted => .loading,
            .preview => .{ .preview = e.info },
            .ready => .{ .ready = e.info },
            .failed => .{ .failed = e.err },
        };
    }

    /// Drops a reference. An unreferenced image stays cached until the
    /// budgets evict it (failed ones go at once).
    pub fn release(c: *ImageCache, h: Handle) void {
        const i = @intFromEnum(h);
        const e = &c.entries.items[i];
        std.debug.assert(e.refs > 0);
        e.refs -= 1;
        if (e.refs == 0 and e.state == .failed) c.removeEntry(i);
    }

    /// Marks the image used by the current frame in window `w` and puts
    /// it on the GPU; null while it has no pixels. Call from a view's
    /// build (views observe `entity` to rebuild when this changes).
    pub fn use(c: *ImageCache, h: Handle, w: *Window) ?Use {
        const i = @intFromEnum(h);
        const e = &c.entries.items[i];
        c.tick += 1;
        e.tick = c.tick;
        e.epoch = c.app.frame_epoch;
        e.seen = true;
        if (e.state == .evicted) {
            c.startJob(i);
            return null;
        }
        const img = &(e.img orelse return null);
        if (img.animated()) {
            if (c.app.reduced_motion) {
                e.player = .{};
            } else {
                if (!e.player.running()) e.player.start(c.app.now_ms, e.delays);
                if (e.player.running()) c.arm(w, e.player.due_ms);
            }
        }
        const frame = e.player.frame;
        const px = if (img.animated()) img.frames[frame].rgba else img.rgba;
        if (e.tex == .none) {
            c.evictGpu(px.len);
            e.tex = c.app.images.add(c.gpa, img.w, img.h, px) catch return null;
            e.gpu_bytes = px.len;
            c.gpu_used += px.len;
        } else if (e.tex_frame != frame) {
            c.app.images.update(e.tex, img.w, img.h, px);
        }
        e.tex_frame = frame;
        return .{ .tex = e.tex, .info = e.info, .frame = frame, .preview = e.state == .preview };
    }

    /// A tiled checkerboard texture (`cell` texels per square, 8 squares
    /// a side) in two colours; one per cache, made again when the colours
    /// change.
    pub fn checker(c: *ImageCache, a: geom.Color, b: geom.Color) TextureId {
        const key = @as(u64, @as(u32, @bitCast(a))) << 32 | @as(u32, @bitCast(b));
        if (c.checker_tex != .none and c.checker_key == key) return c.checker_tex;
        const side = checker_cells * checker_cell;
        if (c.checker_px.len == 0) c.checker_px = c.gpa.alloc(u8, side * side * 4) catch return .none;
        for (0..side) |y| for (0..side) |x| {
            const col = if ((x / checker_cell + y / checker_cell) % 2 == 0) a else b;
            c.checker_px[(y * side + x) * 4 ..][0..4].* = .{ image.premul(col.r, col.a), image.premul(col.g, col.a), image.premul(col.b, col.a), col.a };
        };
        if (c.checker_tex != .none) {
            c.app.images.update(c.checker_tex, side, side, c.checker_px);
        } else {
            c.checker_tex = c.app.images.add(c.gpa, side, side, c.checker_px) catch return .none;
        }
        c.checker_key = key;
        return c.checker_tex;
    }

    /// Texels per checkerboard square.
    pub const checker_cell = 8;
    /// Squares per checkerboard texture side.
    pub const checker_cells = 32;

    /// Bytes on the GPU and the CPU.
    pub fn usage(c: *const ImageCache) struct { cpu: u64, gpu: u64 } {
        return .{ .cpu = c.cpu_used, .gpu = c.gpu_used };
    }

    /// Whether the image has a texture.
    pub fn onGpu(c: *const ImageCache, h: Handle) bool {
        return c.entries.items[@intFromEnum(h)].tex != .none;
    }

    /// Whether the image has pixels on the CPU.
    pub fn onCpu(c: *const ImageCache, h: Handle) bool {
        return c.entries.items[@intFromEnum(h)].img != null;
    }

    // -- entries ---------------------------------------------------------------

    fn newEntry(c: *ImageCache, key: u64) Allocator.Error!u32 {
        try c.by_key.ensureUnusedCapacity(c.gpa, 1);
        const i: u32 = if (c.free.pop()) |i| i else blk: {
            try c.entries.append(c.gpa, .{});
            break :blk @intCast(c.entries.items.len - 1);
        };
        const gen = c.entries.items[i].gen;
        c.entries.items[i] = .{ .used = true, .refs = 1, .key = key, .gen = gen };
        c.by_key.putAssumeCapacity(key, i);
        return i;
    }

    fn removeEntry(c: *ImageCache, i: u32) void {
        const e = &c.entries.items[i];
        c.dropPixels(e);
        if (e.path) |p| c.gpa.free(p);
        if (e.bytes) |b| c.gpa.free(b);
        _ = c.by_key.remove(e.key);
        const gen = e.gen;
        e.* = .{ .gen = gen +% 1 };
        c.free.append(c.gpa, i) catch {};
    }

    fn dropTexture(c: *ImageCache, e: *Entry) void {
        if (e.tex == .none) return;
        c.app.images.remove(c.gpa, e.tex);
        c.gpu_used -= e.gpu_bytes;
        e.tex = .none;
        e.gpu_bytes = 0;
    }

    fn dropPixels(c: *ImageCache, e: *Entry) void {
        c.dropTexture(e);
        if (e.img) |*img| img.deinit(c.gpa);
        e.img = null;
        c.gpa.free(e.delays);
        e.delays = &.{};
        c.cpu_used -= e.cpu_bytes;
        e.cpu_bytes = 0;
        e.player = .{};
    }

    /// Installs pixels (a preview or the full image).
    fn setImage(c: *ImageCache, i: u32, img: Image, preview: bool, info: TexInfo) Allocator.Error!void {
        var m = img;
        errdefer m.deinit(c.gpa);
        const e = &c.entries.items[i];
        const delays: []u32 = if (m.animated()) blk: {
            const d = try c.gpa.alloc(u32, m.frames.len);
            for (m.frames, d) |f, *x| x.* = f.delay_ms;
            break :blk d;
        } else &.{};
        // The old texture goes; `use` uploads the new pixels.
        c.dropPixels(e);
        var bytes: u64 = m.rgba.len;
        if (m.animated()) bytes = @as(u64, m.rgba.len) * m.frames.len;
        e.img = m;
        e.delays = delays;
        e.cpu_bytes = bytes;
        c.cpu_used += bytes;
        e.info = info;
        e.state = if (preview) .preview else .ready;
        c.evictCpu(i);
        c.changed();
    }

    fn changed(c: *ImageCache) void {
        c.app.notifyEntity(c.entity);
    }

    fn pinned(c: *const ImageCache, e: *const Entry) bool {
        return e.epoch == c.app.frame_epoch and e.tick != 0;
    }

    /// Evicts textures until `extra` more bytes fit the GPU budget.
    fn evictGpu(c: *ImageCache, extra: u64) void {
        while (c.gpu_used + extra > c.opts.gpu_bytes) {
            const v = c.victim(.gpu, null) orelse return;
            c.dropTexture(&c.entries.items[v]);
            // Its views must not draw the old slot.
            c.changed();
        }
    }

    /// Evicts pixels other than `keep`'s until the CPU budget holds.
    fn evictCpu(c: *ImageCache, keep: u32) void {
        while (c.cpu_used > c.opts.cpu_bytes) {
            const v = c.victim(.cpu, keep) orelse return;
            const e = &c.entries.items[v];
            if (e.refs == 0) {
                c.removeEntry(v);
            } else {
                c.dropPixels(e);
                e.state = .evicted;
            }
            c.changed();
        }
    }

    /// The least recently used unpinned entry holding a texture (`.gpu`)
    /// or pixels (`.cpu`).
    fn victim(c: *const ImageCache, which: enum { gpu, cpu }, keep: ?u32) ?u32 {
        var best: ?u32 = null;
        for (c.entries.items, 0..) |*e, i| {
            if (!e.used or c.pinned(e) or (keep != null and keep.? == i)) continue;
            switch (which) {
                .gpu => if (e.tex == .none) continue,
                // A referenced image without a source (inserted) could not
                // come back.
                .cpu => if (e.img == null or (e.refs > 0 and e.path == null and e.bytes == null)) continue,
            }
            if (best == null or e.tick < c.entries.items[best.?].tick) best = @intCast(i);
        }
        return best;
    }

    // -- animation -------------------------------------------------------------

    fn arm(c: *ImageCache, w: *Window, at: u64) void {
        if (c.timer != .none) {
            if (c.timer_win == w and c.timer_at <= at) return;
            if (c.timer_win) |old| old.cancelTimer(c.timer);
        }
        c.timer = w.setTimer(at, .{ .ctx = c, .f = onTimer }) catch .none;
        c.timer_win = w;
        c.timer_at = at;
    }

    fn onTimer(ctx: *anyopaque, w: *Window) void {
        const c: *ImageCache = @ptrCast(@alignCast(ctx));
        c.timer = .none;
        const now = c.app.now_ms;
        var any = false;
        var next: ?u64 = null;
        for (c.entries.items) |*e| {
            if (!e.used or e.img == null or !e.player.running()) continue;
            if (!e.seen) {
                // Its view stopped using it (off screen): pause.
                e.player.pause();
                continue;
            }
            const img = &e.img.?;
            if (e.player.advance(now, e.delays, img.loop_count)) {
                any = true;
                // Its view uses it again when it rebuilds.
                e.seen = false;
            } else if (e.player.running()) {
                next = if (next) |n| @min(n, e.player.due_ms) else e.player.due_ms;
            }
        }
        if (next) |n| c.arm(w, n);
        if (any) c.changed();
    }

    // -- decoding --------------------------------------------------------------

    const Job = struct {
        cache: *ImageCache,
        gpa: Allocator,
        app: *App,
        slot: u32,
        gen: u32,
        io: ?std.Io,
        path: ?[]u8,
        bytes: ?[]u8,
        want_px: u32,
        limits: image.Limits,
        max_side: u32,
        file_size: u64 = 0,
        result: LoadError!Image = error.ReadFailed,
        info: TexInfo = undefined,
    };

    const Preview = struct {
        cache: *ImageCache,
        slot: u32,
        gen: u32,
        img: Image,
        info: TexInfo,
    };

    fn startJob(c: *ImageCache, i: u32) void {
        const e = &c.entries.items[i];
        if (e.path == null and e.bytes == null) return; // a job holds the source
        e.gen +%= 1;
        if (e.img == null) e.state = .loading;
        const job = c.gpa.create(Job) catch {
            e.state = .failed;
            e.err = error.OutOfMemory;
            return;
        };
        job.* = .{
            .cache = c,
            .gpa = c.gpa,
            .app = c.app,
            .slot = i,
            .gen = e.gen,
            .io = c.opts.io orelse if (c.app.rt) |rt| rt.io else null,
            .path = e.path,
            .bytes = e.bytes,
            .want_px = @intFromFloat(@as(f32, @floatFromInt(e.want_side)) * c.opts.scale),
            .limits = c.opts.limits,
            .max_side = c.opts.max_texture_side,
        };
        e.path = null;
        e.bytes = null;
        c.inflight += 1;
        c.app.spawn(work, .{job});
    }

    /// Worker: reads, decodes, posts.
    fn work(job: *Job) void {
        const gpa = job.gpa;
        var read: ?[]u8 = null;
        defer if (read) |r| gpa.free(r);
        const bytes = job.bytes orelse blk: {
            const io = job.io orelse {
                job.result = error.ReadFailed;
                return finish(job);
            };
            read = std.Io.Dir.cwd().readFileAlloc(io, job.path.?, gpa, .limited(@intCast(@min(job.limits.max_bytes, std.math.maxInt(usize))))) catch |err| {
                job.result = switch (err) {
                    error.FileNotFound => error.NotFound,
                    error.StreamTooLong => error.TooLarge,
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.ReadFailed,
                };
                return finish(job);
            };
            break :blk read.?;
        };
        job.file_size = bytes.len;
        const format = decode_mod.sniff(bytes);
        // A preview first when a JPEG is much larger than wanted.
        if (format == .jpeg and job.want_px > 0) if (jpeg.info(bytes)) |inf| {
            const turned = inf.orientation >= 5;
            const w = if (turned) inf.h else inf.w;
            const h = if (turned) inf.w else inf.h;
            if (@max(w, h) > 2 * job.want_px) {
                if (decode_mod.decodeScaled(gpa, bytes, job.want_px, job.limits)) |p| {
                    postPreview(job, p, .{ .w = w, .h = h, .px_w = p.w, .px_h = p.h, .format = .jpeg, .file_size = bytes.len });
                } else |_| {}
            }
        } else |_| {};
        job.result = decodeFull(gpa, bytes, job.limits, job.max_side);
        if (job.result) |img| {
            job.info = .{ .w = img.w, .h = img.h, .px_w = img.w, .px_h = img.h, .format = img.format, .frames = @intCast(@max(1, img.frames.len)), .file_size = bytes.len };
        } else |_| {}
        finish(job);
    }

    fn decodeFull(gpa: Allocator, bytes: []const u8, limits: image.Limits, max_side: u32) LoadError!Image {
        var img = try decode_mod.decode(gpa, bytes, limits);
        if (@max(img.w, img.h) <= max_side or img.animated()) return img;
        defer img.deinit(gpa);
        return downscale_mod.downscale(gpa, &img, max_side);
    }

    fn postPreview(job: *Job, img: Image, info: TexInfo) void {
        var m = img;
        const p = job.gpa.create(Preview) catch return m.deinit(job.gpa);
        p.* = .{ .cache = job.cache, .slot = job.slot, .gen = job.gen, .img = m, .info = info };
        if (!postRetry(job.app, .{ .ctx = p, .f = deliverPreview })) {
            m.deinit(job.gpa);
            job.gpa.destroy(p);
        }
    }

    fn finish(job: *Job) void {
        // Keep the full image's own size, but the preview's full size
        // when it was downscaled past `max_side`.
        if (!postRetry(job.app, .{ .ctx = job, .f = deliverFull })) {
            if (job.result) |img| {
                var m = img;
                m.deinit(job.gpa);
            } else |_| {}
            if (job.path) |p| job.gpa.free(p);
            if (job.bytes) |b| job.gpa.free(b);
            const lost = &job.cache.lost;
            job.gpa.destroy(job);
            _ = lost.fetchAdd(1, .release);
        }
    }

    fn postRetry(app: *App, call: App.Call) bool {
        var tries: u32 = 0;
        while (tries < 1000) : (tries += 1) {
            app.post(call) catch |err| switch (err) {
                error.Full => {
                    std.Thread.yield() catch {};
                    continue;
                },
                else => return false,
            };
            return true;
        }
        return false;
    }

    /// The entry a result belongs to, unless it was removed or restarted.
    fn current(c: *ImageCache, slot: u32, gen: u32) ?*Entry {
        if (c.closing or slot >= c.entries.items.len) return null;
        const e = &c.entries.items[slot];
        if (!e.used or e.gen != gen) return null;
        return e;
    }

    fn deliverPreview(ctx: *anyopaque, _: *App) void {
        const p: *Preview = @ptrCast(@alignCast(ctx));
        const c = p.cache;
        defer c.gpa.destroy(p);
        const e = c.current(p.slot, p.gen) orelse return p.img.deinit(c.gpa);
        if (e.state == .ready) return p.img.deinit(c.gpa);
        c.setImage(p.slot, p.img, true, p.info) catch {};
    }

    fn deliverFull(ctx: *anyopaque, _: *App) void {
        const job: *Job = @ptrCast(@alignCast(ctx));
        const c = job.cache;
        defer c.gpa.destroy(job);
        c.inflight -= 1;
        const e = c.current(job.slot, job.gen) orelse {
            if (job.result) |img| {
                var m = img;
                m.deinit(c.gpa);
            } else |_| {}
            if (job.path) |p| c.gpa.free(p);
            if (job.bytes) |b| c.gpa.free(b);
            return;
        };
        // The source comes back for a later decode.
        e.path = job.path;
        e.bytes = job.bytes;
        if (job.result) |img| {
            c.setImage(job.slot, img, false, job.info) catch |err| {
                e.state = .failed;
                e.err = err;
                c.changed();
            };
        } else |err| {
            c.dropPixels(e);
            e.state = .failed;
            e.err = err;
            c.changed();
        }
    }
};
