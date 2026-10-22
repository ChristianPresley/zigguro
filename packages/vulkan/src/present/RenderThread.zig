//! The render thread (E02.F04.S03.T01): owns a `Renderer` and renders the
//! latest `DrawList` the UI thread posted, when the `FramePacer` allows.
//!
//! Mailbox: three lists circulate between the UI thread (one it fills),
//! `pending` (the latest posted) and the render thread (the one it
//! renders, then the free slots). `post` publishes with a compare-and-swap
//! and never blocks: if the previous post was not taken yet, its window
//! damage is merged into the new list and the old list is returned for
//! reuse (latest wins). The render thread waits on one event for
//! (pending and pacer ready), a platform signal, a configure or shutdown;
//! it never polls, so an idle window costs no wakeups.
//!
//! Layer cache: lists ask `layerQuery`, which answers from a table kept
//! here (renderer state is touched only on the render thread). Layers a
//! posted list draws count as cached at once. A list dropped by
//! latest-wins loses its layer content: those layers are dropped from the
//! table and destroyed after the next frame, and the UI is woken with
//! `needs_full_redraw` so it repaints them in full.
//!
//! Textures: the renderer is only touched here, so the UI queues texture
//! work (`createTexture`, `updateTexture`, `destroyTexture`). The queue is
//! applied in order before the next frame renders, so a list posted after
//! an upload sees it. `createTexture` waits for its id (at most one
//! frame); the others return at once.

const std = @import("std");
const zg_core = @import("zg_core");
const r2d = @import("../r2d/root.zig");
const FramePacer = @import("FramePacer.zig");

const Io = std.Io;
const DrawList = r2d.DrawList;
const Renderer = r2d.Renderer;
const LayerId = r2d.LayerId;
const Size = r2d.Size;
const TextureId = r2d.TextureId;
const TextureDesc = r2d.TextureDesc;
const PxRect = r2d.PxRect;

const log = std.log.scoped(.zg_vulkan);

const RenderThread = @This();

/// Wakes the UI thread (e.g. `platform.wake`) after a frame that needs
/// its attention: lost layer content or a failed render. (A renderer's
/// own full repaint needs nothing: a list holds the whole frame.)
pub const Notify = struct { ctx: *anyopaque, wake_ui: *const fn (*anyopaque) void };

/// Platform events E04 forwards.
pub const FrameSignal = union(enum) {
    /// Frame callback (Wayland frame done, X11 CompleteNotify).
    frame,
    /// The target changed size or scale.
    configure: struct { size: Size, scale: f32 },
    /// A frame reached the screen.
    present_feedback: struct { present_id: u64, presented_ns: u64 },
};

pub const Options = struct {
    pacing: FramePacer.Mode = .immediate,
    /// Refresh interval for timer pacing.
    refresh_ns: u64 = 16_666_667,
    notify: ?Notify = null,
};

const Slot = struct {
    dl: DrawList,
    /// Post sequence number (0 = never posted).
    seq: u64 = 0,
};

const CachedLayer = struct { id: LayerId, size: Size, seq: u64 };

/// A `createTexture` waiting for the render thread.
const CreateReq = struct {
    desc: TextureDesc,
    result: r2d.RenderError!TextureId = error.InvalidArgument,
    done: Io.Event = .unset,
};

/// Queued texture work; `update` owns a copy of its pixels.
const TexOp = union(enum) {
    create: *CreateReq,
    update: struct { id: TextureId, rect: PxRect, pixels: []u8, row_pitch: u32 },
    destroy: TextureId,
};

gpa: std.mem.Allocator,
io: Io,
renderer: Renderer,
notify: ?Notify,
slots: [3]Slot,
/// The list the UI fills (UI thread only).
ui: *Slot,
post_seq: u64 = 0,
pending: std.atomic.Value(?*Slot) = .init(null),
free: [2]std.atomic.Value(?*Slot) = .{ .init(null), .init(null) },
wake: Io.Event = .unset,
quit: std.atomic.Value(bool) = .init(false),
frame_signal: std.atomic.Value(bool) = .init(false),
has_configure: std.atomic.Value(bool) = .init(false),
/// Guards `configure`, `cached`, `lost`, `last_stats`, `presented` and
/// `ops`.
lock: Io.Mutex = .init,
configure: struct { size: Size, scale: f32 } = .{ .size = .{ .w = 0, .h = 0 }, .scale = 1 },
cached: std.ArrayList(CachedLayer) = .empty,
lost: std.ArrayList(LayerId) = .empty,
last_stats: r2d.FrameStats = .{},
/// Latest present feedback (id, time).
presented: [2]u64 = .{ 0, 0 },
/// Frames rendered (render thread).
frames: u64 = 0,
/// Texture work queued by the UI.
ops: std.ArrayList(TexOp) = .empty,
/// The batch being applied (render thread).
ops_work: std.ArrayList(TexOp) = .empty,
/// The `seq` of the last list rendered (lists dropped by latest-wins
/// count as done once a newer one renders).
done_seq: std.atomic.Value(u64) = .init(0),
/// A frame asked the UI for a full repaint (see `takeRedraw`).
redraw: std.atomic.Value(bool) = .init(false),
pacer: FramePacer,
future: ?Io.Future(void) = null,

/// Starts a render thread that owns `renderer` (destroyed by `shutdown`).
pub fn spawn(gpa: std.mem.Allocator, io: Io, renderer: Renderer, opts: Options) !*RenderThread {
    const self = try gpa.create(RenderThread);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .renderer = renderer,
        .notify = opts.notify,
        .slots = .{ .{ .dl = .init(gpa) }, .{ .dl = .init(gpa) }, .{ .dl = .init(gpa) } },
        .ui = undefined,
        .pacer = .init(opts.pacing, opts.refresh_ns),
    };
    for (&self.slots) |*s| s.dl.layer_query = .{ .ctx = self, .isValid = queryValid };
    self.ui = &self.slots[0];
    self.free[0].store(&self.slots[1], .release);
    self.free[1].store(&self.slots[2], .release);
    self.future = try io.concurrent(run, .{self});
    return self;
}

/// Stops the thread, then destroys the renderer, the lists and `self`.
/// UI thread.
pub fn shutdown(self: *RenderThread) void {
    self.quit.store(true, .release);
    self.wake.set(self.io);
    if (self.future) |*f| f.await(self.io);
    // The thread has stopped: apply what is left here (frees the copies).
    self.applyOps();
    self.renderer.deinit();
    for (&self.slots) |*s| s.dl.deinit();
    self.cached.deinit(self.gpa);
    self.lost.deinit(self.gpa);
    self.ops.deinit(self.gpa);
    self.ops_work.deinit(self.gpa);
    self.gpa.destroy(self);
}

/// Creates a texture on the render thread and waits for its id. UI
/// thread.
pub fn createTexture(self: *RenderThread, desc: TextureDesc) r2d.RenderError!TextureId {
    var req: CreateReq = .{ .desc = desc };
    try self.queue(.{ .create = &req });
    req.done.waitUncancelable(self.io);
    return req.result;
}

/// Queues an upload of `pixels` (copied) into `rect` of `id`; it lands
/// before the next posted list renders. UI thread.
pub fn updateTexture(self: *RenderThread, id: TextureId, rect: PxRect, pixels: []const u8, row_pitch: u32) r2d.RenderError!void {
    const copy = self.gpa.dupe(u8, pixels) catch return error.OutOfMemory;
    errdefer self.gpa.free(copy);
    try self.queue(.{ .update = .{ .id = id, .rect = rect, .pixels = copy, .row_pitch = row_pitch } });
}

/// Queues the destruction of `id`. UI thread.
pub fn destroyTexture(self: *RenderThread, id: TextureId) void {
    self.queue(.{ .destroy = id }) catch {
        // Out of memory: the texture lives until the renderer goes.
    };
}

fn queue(self: *RenderThread, op: TexOp) error{OutOfMemory}!void {
    self.lock.lockUncancelable(self.io);
    const r = self.ops.append(self.gpa, op);
    self.lock.unlock(self.io);
    try r;
    self.wake.set(self.io);
}

/// Applies the queued texture work in order. Render thread (or the UI
/// after the thread stopped).
fn applyOps(self: *RenderThread) void {
    self.lock.lockUncancelable(self.io);
    std.mem.swap(std.ArrayList(TexOp), &self.ops, &self.ops_work);
    self.lock.unlock(self.io);
    for (self.ops_work.items) |op| switch (op) {
        .create => |req| {
            req.result = self.renderer.createTexture(req.desc);
            req.done.set(self.io);
        },
        .update => |u| {
            self.renderer.updateTexture(u.id, u.rect, u.pixels, u.row_pitch) catch |err| log.err("texture upload failed: {t}", .{err});
            self.gpa.free(u.pixels);
        },
        .destroy => |id| self.renderer.destroyTexture(id),
    };
    self.ops_work.clearRetainingCapacity();
}

/// Whether a frame asked for a full repaint since the last call (a lost
/// layer or a renderer that needs one). UI thread.
pub fn takeRedraw(self: *RenderThread) bool {
    return self.redraw.swap(false, .acq_rel);
}

/// Waits until every list posted so far has rendered, or `timeout_ns`
/// passes (returns false). UI thread; for tests and screenshots.
pub fn waitIdle(self: *RenderThread, timeout_ns: u64) bool {
    const start = zg_core.time.nowNs(self.io);
    while (self.done_seq.load(.acquire) < self.post_seq) {
        if (zg_core.time.nowNs(self.io) - start > timeout_ns) return false;
        self.io.sleep(.fromMicroseconds(200), .awake) catch {};
    }
    return true;
}

/// The list the UI fills first (later ones come from `post`).
pub fn firstList(self: *RenderThread) *DrawList {
    return &self.ui.dl;
}

/// Publishes `dl` (a list from `firstList` or `post`) and returns the
/// list to fill next. UI thread; never blocks on the render thread.
pub fn post(self: *RenderThread, dl: *DrawList) *DrawList {
    const slot: *Slot = @fieldParentPtr("dl", dl);
    self.post_seq += 1;
    slot.seq = self.post_seq;
    var cur = self.pending.load(.acquire);
    while (true) {
        // The render thread only reads lists, so `cur` can be read even if
        // it is taken meanwhile (the merge is then a harmless superset).
        if (cur) |c| mergeDamage(&slot.dl, &c.dl);
        cur = self.pending.cmpxchgWeak(cur, slot, .acq_rel, .acquire) orelse break;
    }
    self.lock.lockUncancelable(self.io);
    if (cur) |dropped| for (dropped.dl.layers.items) |l| {
        if (!l.drawn) continue;
        self.lost.append(self.gpa, l.id) catch {};
        self.forget(l.id);
    };
    for (slot.dl.layers.items) |l| {
        if (!l.drawn or self.isLost(l.id)) continue;
        self.remember(l.id, l.size, slot.seq);
    }
    self.lock.unlock(self.io);
    self.wake.set(self.io);

    const next = cur orelse self.takeFree();
    self.ui = next;
    return &next.dl;
}

fn takeFree(self: *RenderThread) *Slot {
    // With the UI's list and `pending` accounted for, the render thread
    // holds at most one list, so a free slot exists (it may be in the
    // middle of being returned: retry).
    while (true) {
        for (&self.free) |*f| if (f.swap(null, .acq_rel)) |s| return s;
        std.atomic.spinLoopHint();
    }
}

/// Forwards a platform event. UI thread; never blocks.
pub fn onPlatformFrame(self: *RenderThread, ev: FrameSignal) void {
    switch (ev) {
        .frame => self.frame_signal.store(true, .release),
        .configure => |c| {
            self.lock.lockUncancelable(self.io);
            self.configure = .{ .size = c.size, .scale = c.scale };
            self.lock.unlock(self.io);
            self.has_configure.store(true, .release);
        },
        .present_feedback => |p| {
            self.lock.lockUncancelable(self.io);
            self.presented = .{ p.present_id, p.presented_ns };
            self.lock.unlock(self.io);
            return;
        },
    }
    self.wake.set(self.io);
}

/// The last completed frame's stats.
pub fn stats(self: *RenderThread) r2d.FrameStats {
    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    return self.last_stats;
}

/// A `DrawList.LayerQuery` answered from this thread's cache table.
fn queryValid(ctx: *anyopaque, id: LayerId, size: Size) bool {
    const self: *RenderThread = @ptrCast(@alignCast(ctx));
    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    for (self.cached.items) |c| if (c.id == id) return c.size.w == size.w and c.size.h == size.h;
    return false;
}

fn remember(self: *RenderThread, id: LayerId, size: Size, seq: u64) void {
    for (self.cached.items) |*c| if (c.id == id) {
        c.* = .{ .id = id, .size = size, .seq = seq };
        return;
    };
    self.cached.append(self.gpa, .{ .id = id, .size = size, .seq = seq }) catch {};
}

fn forget(self: *RenderThread, id: LayerId) void {
    for (self.cached.items, 0..) |c, i| if (c.id == id) {
        _ = self.cached.swapRemove(i);
        return;
    };
}

fn isLost(self: *const RenderThread, id: LayerId) bool {
    return std.mem.indexOfScalar(LayerId, self.lost.items, id) != null;
}

/// Adds `src`'s window damage to `dst` (a dropped frame's changes must
/// still reach the screen).
fn mergeDamage(dst: *DrawList, src: *const DrawList) void {
    if (src.damage_full or src.alloc_failed or src.extent.w != dst.extent.w or src.extent.h != dst.extent.h) {
        dst.damageAll();
        return;
    }
    for (src.damageRects()) |r| dst.addDamage(r);
}

fn run(self: *RenderThread) void {
    const io = self.io;
    while (true) {
        self.wake.reset();
        if (self.quit.load(.acquire)) return;
        self.applyOps();
        if (self.has_configure.swap(false, .acq_rel)) {
            self.lock.lockUncancelable(io);
            const c = self.configure;
            self.lock.unlock(io);
            self.renderer.resize(c.size, c.scale);
        }
        if (self.frame_signal.swap(false, .acq_rel)) self.pacer.onPlatformFrame();
        if (self.pending.load(.acquire) == null) {
            self.wake.waitUncancelable(io);
            continue;
        }
        const now = zg_core.time.nowNs(io);
        switch (self.pacer.readiness(now)) {
            .now => {},
            .signal => {
                self.wake.waitUncancelable(io);
                continue;
            },
            .at => |t| {
                const d: Io.Clock.Duration = .{ .raw = .fromNanoseconds(@intCast(t - now)), .clock = .awake };
                self.wake.waitTimeout(io, .{ .duration = d }) catch {};
                continue;
            },
        }
        if (self.pacer.waitReady(null) == .lost) log.warn("present wait reported a lost surface", .{});
        const slot = self.pending.swap(null, .acq_rel) orelse continue;
        // Uploads queued before this list was posted land first.
        self.applyOps();
        self.renderOne(slot);
        self.done_seq.store(slot.seq, .release);
        self.release(slot);
    }
}

fn renderOne(self: *RenderThread, slot: *Slot) void {
    const io = self.io;
    const start = zg_core.time.nowNs(io);
    var failed = false;
    var s = self.renderer.render(&slot.dl) catch |err| blk: {
        log.err("render failed: {t}", .{err});
        failed = true;
        break :blk r2d.FrameStats{ .needs_full_redraw = true };
    };
    self.frames += 1;
    self.pacer.frameDone(start, s.present_id != 0);

    var wake_ui = failed;
    self.lock.lockUncancelable(io);
    // Layers the renderer dropped (evicted, failed) that no newer list has
    // drawn are no longer cached.
    var i: usize = 0;
    while (i < self.cached.items.len) {
        const c = self.cached.items[i];
        if (c.seq <= slot.seq and !self.renderer.vtable.layerValid(self.renderer.ptr, c.id, c.size)) {
            _ = self.cached.swapRemove(i);
        } else i += 1;
    }
    // Content lost to latest-wins: start those layers over.
    for (self.lost.items) |id| self.renderer.destroyLayer(id);
    if (self.lost.items.len != 0) {
        self.lost.clearRetainingCapacity();
        s.needs_full_redraw = true;
        wake_ui = true;
    }
    self.last_stats = s;
    self.lock.unlock(io);
    if (wake_ui) {
        self.redraw.store(true, .release);
        if (self.notify) |n| n.wake_ui(n.ctx);
    }
}

fn release(self: *RenderThread, slot: *Slot) void {
    while (true) {
        for (&self.free) |*f| if (f.cmpxchgStrong(null, slot, .acq_rel, .acquire) == null) return;
        std.atomic.spinLoopHint();
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A renderer that records what it rendered and can be held inside
/// `render`.
const FakeRenderer = struct {
    io: Io,
    gate: Io.Event = .is_set,
    entered: Io.Event = .unset,
    rendered: std.atomic.Value(u32) = .init(0),
    last_prims: std.atomic.Value(u32) = .init(0),
    last_damage_full: std.atomic.Value(bool) = .init(false),
    last_damage_len: std.atomic.Value(u32) = .init(0),
    destroyed: std.atomic.Value(u32) = .init(0),
    valid: std.atomic.Value(bool) = .init(true),
    textures: std.atomic.Value(u32) = .init(0),
    uploads: std.atomic.Value(u32) = .init(0),
    last_upload: std.atomic.Value(u8) = .init(0),
    /// `uploads` when the last frame rendered.
    uploads_at_render: std.atomic.Value(u32) = .init(0),
    tex_destroyed: std.atomic.Value(u32) = .init(0),

    fn renderer(self: *FakeRenderer) Renderer {
        return .{ .ptr = self, .vtable = &.{
            .render = render,
            .resize = resize,
            .createTexture = fakeCreate,
            .updateTexture = fakeUpdate,
            .destroyTexture = fakeDestroy,
            .destroyLayer = destroyLayer,
            .backend = backend,
            .deinit = deinit,
            .layerValid = layerValid,
        } };
    }
    fn cast(p: *anyopaque) *FakeRenderer {
        return @ptrCast(@alignCast(p));
    }
    fn render(p: *anyopaque, dl: *const DrawList) r2d.RenderError!r2d.FrameStats {
        const self = cast(p);
        self.entered.set(self.io);
        self.gate.waitUncancelable(self.io);
        self.last_prims.store(@intCast(dl.prims.items.len), .release);
        self.last_damage_full.store(dl.damage_full, .release);
        self.last_damage_len.store(dl.damage_len, .release);
        self.uploads_at_render.store(self.uploads.load(.acquire), .release);
        _ = self.rendered.fetchAdd(1, .acq_rel);
        return .{ .present_id = 1 };
    }
    fn resize(_: *anyopaque, _: Size, _: f32) void {}
    fn fakeCreate(p: *anyopaque, d: r2d.TextureDesc) r2d.RenderError!r2d.TextureId {
        if (d.width == 0) return error.InvalidArgument;
        return @enumFromInt(cast(p).textures.fetchAdd(1, .acq_rel) + 1);
    }
    fn fakeUpdate(p: *anyopaque, _: r2d.TextureId, _: r2d.PxRect, px: []const u8, _: u32) r2d.RenderError!void {
        const self = cast(p);
        self.last_upload.store(px[0], .release);
        _ = self.uploads.fetchAdd(1, .acq_rel);
    }
    fn fakeDestroy(p: *anyopaque, _: r2d.TextureId) void {
        _ = cast(p).tex_destroyed.fetchAdd(1, .acq_rel);
    }
    fn destroyLayer(p: *anyopaque, _: LayerId) void {
        _ = cast(p).destroyed.fetchAdd(1, .acq_rel);
    }
    fn backend(_: *anyopaque) r2d.Backend {
        return .software;
    }
    fn deinit(_: *anyopaque) void {}
    fn layerValid(p: *anyopaque, _: LayerId, _: Size) bool {
        return cast(p).valid.load(.acquire);
    }
};

fn waitFor(io: Io, v: *std.atomic.Value(u32), want: u32) !void {
    var tries: u32 = 0;
    while (v.load(.acquire) < want) : (tries += 1) {
        if (tries > 5000) return error.Timeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "mailbox: latest wins and damage unioned" {
    const io = testing.io;
    var fake: FakeRenderer = .{ .io = io };
    const rt = spawn(testing.allocator, io, fake.renderer(), .{}) catch |e| switch (e) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
        else => return e,
    };
    defer rt.shutdown();
    const ext: Size = .{ .w = 100, .h = 100 };
    // Hold the render thread inside frame 1.
    fake.gate.reset();
    var dl = rt.firstList();
    dl.reset(ext, 1);
    dl.addDamage(.{ .x = 0, .y = 0, .w = 1, .h = 1 });
    dl = rt.post(dl);
    fake.entered.waitUncancelable(io);
    // Two more posts while it is busy: the second replaces the first.
    dl.reset(ext, 1);
    dl.addDamage(.{ .x = 10, .y = 10, .w = 2, .h = 2 });
    dl.rect(.{ .x = 0, .y = 0, .w = 5, .h = 5 }, r2d.Color.white, .{});
    dl = rt.post(dl);
    dl.reset(ext, 1);
    dl.addDamage(.{ .x = 50, .y = 50, .w = 3, .h = 3 });
    dl.rect(.{ .x = 0, .y = 0, .w = 5, .h = 5 }, r2d.Color.white, .{});
    dl.rect(.{ .x = 0, .y = 0, .w = 5, .h = 5 }, r2d.Color.white, .{});
    dl = rt.post(dl);
    fake.gate.set(io);
    try waitFor(io, &fake.rendered, 2);
    // Give a wrongly queued third frame the chance to show up.
    try io.sleep(.fromMilliseconds(20), .awake);
    try testing.expectEqual(@as(u32, 2), fake.rendered.load(.acquire));
    try testing.expectEqual(@as(u32, 2), fake.last_prims.load(.acquire));
    try testing.expectEqual(@as(u32, 2), fake.last_damage_len.load(.acquire));
}

test "mailbox: post never blocks" {
    const io = testing.io;
    var fake: FakeRenderer = .{ .io = io };
    const rt = spawn(testing.allocator, io, fake.renderer(), .{}) catch |e| switch (e) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
        else => return e,
    };
    defer rt.shutdown();
    fake.gate.reset(); // the consumer sleeps inside its first frame
    var dl = rt.firstList();
    const t0 = zg_core.time.nowNs(io);
    var i: u32 = 0;
    while (i < 1_000_000) : (i += 1) {
        dl.reset(.{ .w = 64, .h = 64 }, 1);
        dl.addDamage(.{ .x = @intCast(i % 64), .y = 0, .w = 1, .h = 1 });
        dl = rt.post(dl);
    }
    const elapsed = zg_core.time.nowNs(io) - t0;
    fake.gate.set(io);
    try waitFor(io, &fake.rendered, 2);
    // A million posts finish while one frame is held, well under 10 s even
    // in Debug builds.
    try testing.expect(elapsed < 10 * std.time.ns_per_s);
    // The surviving frame carries the union of the dropped frames' damage.
    try io.sleep(.fromMilliseconds(20), .awake);
    try testing.expect(fake.last_damage_full.load(.acquire) or fake.last_damage_len.load(.acquire) == 64);
}

test "mailbox: dropped layer content is redrawn" {
    const io = testing.io;
    var fake: FakeRenderer = .{ .io = io };
    var woken: std.atomic.Value(u32) = .init(0);
    const W = struct {
        fn wake(ctx: *anyopaque) void {
            const w: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx));
            _ = w.fetchAdd(1, .acq_rel);
        }
    };
    const rt = spawn(testing.allocator, io, fake.renderer(), .{ .notify = .{ .ctx = &woken, .wake_ui = W.wake } }) catch |e| switch (e) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
        else => return e,
    };
    defer rt.shutdown();
    const ext: Size = .{ .w = 64, .h = 64 };
    const id: LayerId = @enumFromInt(7);
    const lsz: Size = .{ .w = 32, .h = 32 };
    fake.gate.reset();
    var dl = rt.firstList();
    dl.reset(ext, 1);
    dl.damageAll();
    dl = rt.post(dl);
    fake.entered.waitUncancelable(io);
    // This frame draws the layer but is replaced before it renders.
    dl.reset(ext, 1);
    dl.damageAll();
    try testing.expect(dl.beginLayer(id, lsz, &.{}));
    dl.endLayer();
    dl.drawLayer(id, .{ .x = 0, .y = 0, .w = 32, .h = 32 }, .{}, 1);
    dl = rt.post(dl);
    try testing.expect(dl.layerCached(id, lsz)); // optimistic
    dl.reset(ext, 1);
    dl.addDamage(.{ .x = 0, .y = 0, .w = 1, .h = 1 });
    // The newer frame believed it cached: it is not drawn here.
    try testing.expect(!dl.beginLayer(id, lsz, &.{}));
    dl.drawLayer(id, .{ .x = 0, .y = 0, .w = 32, .h = 32 }, .{}, 1);
    dl = rt.post(dl);
    // The drop forgot it at once.
    try testing.expect(!dl.layerCached(id, lsz));
    fake.gate.set(io);
    try waitFor(io, &fake.rendered, 2);
    try waitFor(io, &woken, 1);
    try waitFor(io, &fake.destroyed, 1);
    // The UI's next frame repaints the layer in full.
    try testing.expect(!dl.layerCached(id, lsz));
}

test "textures: queued in order, applied before the next frame" {
    const io = testing.io;
    var fake: FakeRenderer = .{ .io = io };
    const rt = spawn(testing.allocator, io, fake.renderer(), .{}) catch |e| switch (e) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
        else => return e,
    };
    defer rt.shutdown();
    const t = try rt.createTexture(.{ .width = 4, .height = 4, .format = .r8 });
    try testing.expectEqual(@as(u32, 1), @intFromEnum(t));
    try testing.expectError(error.InvalidArgument, rt.createTexture(.{ .width = 0, .height = 4, .format = .r8 }));
    // Hold the thread in a frame; uploads queued meanwhile land before
    // the next list renders.
    fake.gate.reset();
    var dl = rt.firstList();
    dl.reset(.{ .w = 8, .h = 8 }, 1);
    dl.damageAll();
    dl = rt.post(dl);
    fake.entered.waitUncancelable(io);
    var px = [_]u8{7} ** 16;
    try rt.updateTexture(t, .{ .x = 0, .y = 0, .w = 4, .h = 4 }, &px, 4);
    px[0] = 9; // the queue holds a copy
    try rt.updateTexture(t, .{ .x = 0, .y = 0, .w = 4, .h = 4 }, &px, 4);
    dl.reset(.{ .w = 8, .h = 8 }, 1);
    dl.damageAll();
    dl = rt.post(dl);
    fake.gate.set(io);
    try testing.expect(rt.waitIdle(5 * std.time.ns_per_s));
    try testing.expectEqual(@as(u32, 2), fake.uploads_at_render.load(.acquire));
    try testing.expectEqual(@as(u8, 9), fake.last_upload.load(.acquire));
    rt.destroyTexture(t);
    try testing.expect(rt.waitIdle(5 * std.time.ns_per_s));
}

test "textures: work queued at shutdown is still applied" {
    const io = testing.io;
    var fake: FakeRenderer = .{ .io = io };
    const rt = spawn(testing.allocator, io, fake.renderer(), .{}) catch |e| switch (e) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
        else => return e,
    };
    const t = try rt.createTexture(.{ .width = 2, .height = 2, .format = .r8 });
    const px = [_]u8{1} ** 4;
    try rt.updateTexture(t, .{ .x = 0, .y = 0, .w = 2, .h = 2 }, &px, 2);
    rt.destroyTexture(t);
    rt.shutdown();
    try testing.expectEqual(@as(u32, 1), fake.uploads.load(.acquire));
    try testing.expectEqual(@as(u32, 1), fake.tex_destroyed.load(.acquire));
}
