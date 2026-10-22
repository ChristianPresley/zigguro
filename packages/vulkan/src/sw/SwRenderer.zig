//! The software renderer: executes a `DrawList` on the CPU with the shared
//! shading math. Tiles of 64×64 pixels are binned, then shaded by up to 8
//! workers that claim tiles from an atomic counter; each tile belongs to one
//! worker, so the output is identical for every thread count.
//!
//! Targets: a headless sink (a persistent backbuffer, damage passed on), an
//! external presenter in shm mode (a ring of `allocCpuBuffer` buffers with
//! buffer-age repaint), or a caller-owned `CpuImage` (`renderToImage`).
//! Layers are CPU textures repainted in their own pass before the window.

const std = @import("std");
const platform = @import("zg_platform");
const zg_core = @import("zg_core");
const r2d = @import("../r2d/root.zig");
const bin = @import("bin.zig");
const raster = @import("raster.zig");
const texture = @import("texture.zig");
const CpuImage = @import("../testing/CpuImage.zig");

const Allocator = std.mem.Allocator;
const DrawList = r2d.DrawList;
const PxRect = r2d.PxRect;
const Size = r2d.Size;
const CpuTexture = texture.CpuTexture;
const RenderError = r2d.RenderError;

const SwRenderer = @This();

/// DRM fourcc of the shm buffers (B, G, R, A bytes in memory).
pub const fourcc_argb8888: u32 = 0x34325241;
/// Frames of damage remembered for buffer age.
const history_len = 4;
/// Presenter buffers in the shm ring.
const ring_len = 3;

const Layer = struct {
    tex: CpuTexture,
    valid: bool,
};

const Slot = struct {
    buf: platform.surface.CpuBuffer,
    busy: bool = false,
    /// Frame number last rendered into this buffer (0 = never).
    frame: u64 = 0,
};

const FrameDamage = struct {
    rects: [DrawList.max_damage]PxRect = undefined,
    len: u8 = 0,
    full: bool = true,
};

gpa: Allocator,
io: std.Io,
opts: r2d.RendererOptions,
size: Size,
scale: f32 = 1,
threads: u32,
/// Textures by id; slot 0 is reserved for "none".
textures: std.ArrayList(?*const CpuTexture) = .empty,
free_ids: std.ArrayList(u16) = .empty,
layers: std.AutoHashMapUnmanaged(r2d.LayerId, *Layer) = .empty,
layer_view: std.ArrayList(?*const CpuTexture) = .empty,
bins: bin.Bins = .{},
scratch: []raster.Scratch,
repaint: std.ArrayList(PxRect) = .empty,
/// Headless backbuffer (BGRA).
back: ?CpuImage = null,
ring: [ring_len]?Slot = .{ null, null, null },
history: [history_len]FrameDamage = .{FrameDamage{}} ** history_len,
frame: u64 = 0,
needs_full: bool = true,

/// Creates a software renderer for `opts.target` (headless, external
/// presenter, or none for `renderToImage` use with a headless sink).
pub fn create(gpa: Allocator, io: std.Io, opts: r2d.RendererOptions) !*SwRenderer {
    switch (opts.target) {
        .headless, .external => {},
        // A CPU path for Win32 and Metal needs a presenter from E01.
        .win32, .metal_layer => return error.Unsupported,
    }
    const cores: u32 = @intCast(std.Thread.getCpuCount() catch 1);
    const n: u32 = if (opts.sw_threads != 0) opts.sw_threads else @min(cores, 8);
    const self = try gpa.create(SwRenderer);
    errdefer gpa.destroy(self);
    const scratch = try gpa.alloc(raster.Scratch, n);
    errdefer gpa.free(scratch);
    self.* = .{ .gpa = gpa, .io = io, .opts = opts, .size = opts.size, .threads = n, .scratch = scratch };
    try self.textures.append(gpa, null);
    return self;
}

/// Frees everything.
pub fn destroy(self: *SwRenderer) void {
    const gpa = self.gpa;
    for (self.textures.items) |t| if (t) |tex| {
        const m: *CpuTexture = @constCast(tex);
        m.deinit(gpa);
        gpa.destroy(m);
    };
    self.textures.deinit(gpa);
    self.free_ids.deinit(gpa);
    var it = self.layers.valueIterator();
    while (it.next()) |l| {
        l.*.tex.deinit(gpa);
        gpa.destroy(l.*);
    }
    self.layers.deinit(gpa);
    self.layer_view.deinit(gpa);
    self.bins.deinit(gpa);
    self.repaint.deinit(gpa);
    gpa.free(self.scratch);
    if (self.back) |*b| b.deinit(gpa);
    self.releaseRing();
    gpa.destroy(self);
}

/// The type-erased interface.
pub fn renderer(self: *SwRenderer) r2d.Renderer {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: r2d.Renderer.VTable = .{
    .render = vRender,
    .resize = vResize,
    .createTexture = vCreateTexture,
    .updateTexture = vUpdateTexture,
    .destroyTexture = vDestroyTexture,
    .destroyLayer = vDestroyLayer,
    .backend = vBackend,
    .deinit = vDeinit,
    .layerValid = vLayerValid,
};

fn cast(p: *anyopaque) *SwRenderer {
    return @ptrCast(@alignCast(p));
}

fn vRender(p: *anyopaque, dl: *const DrawList) RenderError!r2d.FrameStats {
    return cast(p).render(dl);
}
fn vResize(p: *anyopaque, size: Size, scale: f32) void {
    const self = cast(p);
    if (size.w != self.size.w or size.h != self.size.h) self.needs_full = true;
    self.size = size;
    self.scale = scale;
}
fn vCreateTexture(p: *anyopaque, desc: r2d.TextureDesc) RenderError!r2d.TextureId {
    return cast(p).createTexture(desc);
}
fn vUpdateTexture(p: *anyopaque, id: r2d.TextureId, rect: PxRect, data: []const u8, pitch: u32) RenderError!void {
    return cast(p).updateTexture(id, rect, data, pitch);
}
fn vDestroyTexture(p: *anyopaque, id: r2d.TextureId) void {
    cast(p).destroyTexture(id);
}
fn vDestroyLayer(p: *anyopaque, id: r2d.LayerId) void {
    const self = cast(p);
    if (self.layers.fetchRemove(id)) |kv| {
        kv.value.tex.deinit(self.gpa);
        self.gpa.destroy(kv.value);
    }
}
fn vBackend(_: *anyopaque) r2d.Backend {
    return .software;
}
fn vDeinit(p: *anyopaque) void {
    cast(p).destroy();
}
fn vLayerValid(p: *anyopaque, id: r2d.LayerId, size: Size) bool {
    const self = cast(p);
    const l = self.layers.get(id) orelse return false;
    return l.valid and l.tex.width == size.w and l.tex.height == size.h;
}

/// Creates a zeroed texture.
pub fn createTexture(self: *SwRenderer, desc: r2d.TextureDesc) RenderError!r2d.TextureId {
    if (desc.width == 0 or desc.height == 0 or desc.width > 16384 or desc.height > 16384) return error.InvalidArgument;
    const t = self.gpa.create(CpuTexture) catch return error.OutOfMemory;
    errdefer self.gpa.destroy(t);
    t.* = CpuTexture.init(self.gpa, desc) catch return error.OutOfMemory;
    errdefer t.deinit(self.gpa);
    if (self.free_ids.pop()) |id| {
        self.textures.items[id] = t;
        return @enumFromInt(id);
    }
    if (self.textures.items.len > std.math.maxInt(u16)) return error.OutOfMemory;
    self.textures.append(self.gpa, t) catch return error.OutOfMemory;
    return @enumFromInt(self.textures.items.len - 1);
}

/// Copies texels into a texture.
pub fn updateTexture(self: *SwRenderer, id: r2d.TextureId, rect: PxRect, data: []const u8, pitch: u32) RenderError!void {
    const i = @intFromEnum(id);
    if (i == 0 or i >= self.textures.items.len) return error.InvalidArgument;
    const t = self.textures.items[i] orelse return error.InvalidArgument;
    return @constCast(t).update(rect, data, pitch);
}

/// Destroys a texture (the software backend has no frames in flight).
pub fn destroyTexture(self: *SwRenderer, id: r2d.TextureId) void {
    const i = @intFromEnum(id);
    if (i == 0 or i >= self.textures.items.len) return;
    const t = self.textures.items[i] orelse return;
    const m: *CpuTexture = @constCast(t);
    m.deinit(self.gpa);
    self.gpa.destroy(m);
    self.textures.items[i] = null;
    self.free_ids.append(self.gpa, @intCast(i)) catch {};
}

/// Renders `dl` into `out`, repainting the list's damage (or everything
/// when the list says `damage_full`). `out` keeps its other pixels.
pub fn renderToImage(self: *SwRenderer, dl: *const DrawList, out: *CpuImage) RenderError!r2d.FrameStats {
    const start = zg_core.time.nowNs(self.io);
    const full = [_]PxRect{.{ .x = 0, .y = 0, .w = out.width, .h = out.height }};
    const repaint: []const PxRect = if (dl.damage_full or dl.alloc_failed) &full else dl.damageRects();
    var stats = try self.renderTarget(dl, .{ .pixels = out.pixels, .stride = out.stride, .width = out.width, .height = out.height, .bgra = out.order == .bgra }, repaint);
    stats.needs_full_redraw = repaint.ptr == &full;
    stats.cpu_encode_ns = zg_core.time.nowNs(self.io) - start;
    return stats;
}

/// Renders and presents one frame to the configured target.
pub fn render(self: *SwRenderer, dl: *const DrawList) RenderError!r2d.FrameStats {
    const start = zg_core.time.nowNs(self.io);
    const extent = dl.extent;
    if (extent.w == 0 or extent.h == 0) return .{ .backend = .software, .prims = @intCast(dl.prims.items.len) };
    var full_frame = self.needs_full or dl.damage_full or dl.alloc_failed;
    if (extent.w != self.size.w or extent.h != self.size.h) {
        self.size = extent;
        full_frame = true;
    }
    if (!full_frame and dl.damage_len == 0) {
        return .{ .backend = .software, .prims = @intCast(dl.prims.items.len) };
    }
    self.frame += 1;
    const h = &self.history[self.frame % history_len];
    h.full = full_frame;
    h.len = 0;
    if (!full_frame) {
        @memcpy(h.rects[0..dl.damage_len], dl.damageRects());
        h.len = dl.damage_len;
    }
    const full_rect = [_]PxRect{.{ .x = 0, .y = 0, .w = extent.w, .h = extent.h }};
    const frame_damage: []const PxRect = if (full_frame) &full_rect else h.rects[0..h.len];

    var stats: r2d.FrameStats = .{ .backend = .software };
    switch (self.opts.target) {
        .headless => |sink| {
            if (self.back == null or self.back.?.width != extent.w or self.back.?.height != extent.h) {
                if (self.back) |*b| b.deinit(self.gpa);
                self.back = null;
                self.back = CpuImage.initOrder(self.gpa, extent.w, extent.h, .bgra) catch return error.OutOfMemory;
            }
            const b = &self.back.?;
            stats = try self.renderTarget(dl, .{ .pixels = b.pixels, .stride = b.stride, .width = b.width, .height = b.height, .bgra = true }, frame_damage);
            sink.write(sink.ptr, self.opts.window, frame_damage, b.pixels, b.stride);
        },
        .external => |presenter| {
            const slot = try self.acquireSlot(presenter.*, extent) orelse {
                // No buffer free: drop this frame and repaint fully next time.
                self.needs_full = true;
                return .{ .backend = .software, .prims = @intCast(dl.prims.items.len) };
            };
            const age = if (slot.frame == 0) std.math.maxInt(u64) else self.frame - slot.frame;
            const repaint = self.bufferAgeDamage(age, &full_rect) catch return error.OutOfMemory;
            stats = try self.renderTarget(dl, .{ .pixels = slot.buf.pixels, .stride = slot.buf.stride, .width = extent.w, .height = extent.h, .bgra = true }, repaint);
            slot.frame = self.frame;
            slot.busy = true;
            presenter.present(slot.buf.handle, if (full_frame) &.{} else frame_damage, .none, null) catch return error.PresentFailed;
        },
        .win32, .metal_layer => return error.SurfaceLost,
    }
    self.needs_full = false;
    stats.needs_full_redraw = full_frame;
    stats.present_id = self.frame;
    stats.cpu_encode_ns = zg_core.time.nowNs(self.io) - start;
    return stats;
}

fn releaseRing(self: *SwRenderer) void {
    for (&self.ring) |*s| if (s.*) |slot| {
        switch (self.opts.target) {
            .external => |pr| pr.releaseBuffer(slot.buf.handle),
            else => {},
        }
        s.* = null;
    };
}

fn acquireSlot(self: *SwRenderer, presenter: platform.surface.Presenter, extent: Size) RenderError!?*Slot {
    var released: [8]platform.surface.BufferHandle = undefined;
    const n = presenter.pollReleased(&released);
    for (released[0..n]) |h| {
        for (&self.ring) |*s| if (s.*) |*slot| {
            if (slot.buf.handle == h) slot.busy = false;
        };
    }
    // Drop buffers of the wrong size.
    for (&self.ring) |*s| if (s.*) |slot| {
        if (slot.buf.stride < extent.w * 4 or slot.buf.pixels.len < @as(usize, slot.buf.stride) * extent.h or
            slot.buf.pixels.len > @as(usize, slot.buf.stride) * extent.h + slot.buf.stride)
        {
            if (!slot.busy) {
                presenter.releaseBuffer(slot.buf.handle);
                s.* = null;
            }
        }
    };
    // Prefer the free buffer rendered most recently (smallest age).
    var best: ?*Slot = null;
    for (&self.ring) |*s| if (s.*) |*slot| {
        if (!slot.busy and (best == null or slot.frame > best.?.frame)) best = slot;
    };
    if (best) |b| return b;
    for (&self.ring) |*s| if (s.* == null) {
        const buf = presenter.allocCpuBuffer(extent.w, extent.h, fourcc_argb8888) catch return error.OutOfMemory;
        s.* = .{ .buf = buf };
        return &s.*.?;
    };
    return null;
}

/// The union (as a list) of the damage of the last `age` frames, or the
/// whole target when the history is too short.
fn bufferAgeDamage(self: *SwRenderer, age: u64, full: []const PxRect) ![]const PxRect {
    if (age == 0 or age > history_len) return full;
    self.repaint.clearRetainingCapacity();
    var k: u64 = 0;
    while (k < age) : (k += 1) {
        const h = &self.history[(self.frame - k) % history_len];
        if (h.full) return full;
        try self.repaint.appendSlice(self.gpa, h.rects[0..h.len]);
    }
    return self.repaint.items;
}

const Job = struct {
    self: *SwRenderer,
    target: raster.Target,
    grid: bin.TileGrid,
    repaint: []const PxRect,
    prims: []const r2d.Prim,
    ctx: *const raster.ShadeCtx,
    next: std.atomic.Value(u32) = .init(0),
    pixels: std.atomic.Value(u64) = .init(0),
    tiles: std.atomic.Value(u32) = .init(0),
};

fn work(job: *Job, worker: u32) void {
    const scratch = &job.self.scratch[worker];
    var px: u64 = 0;
    var shaded: u32 = 0;
    const ntiles = job.grid.count();
    while (true) {
        const t = job.next.fetchAdd(1, .monotonic);
        if (t >= ntiles) break;
        const items = job.self.bins.tileItems(t);
        if (items.len == 0) continue;
        const tile = job.grid.tile(t);
        var mask: raster.TileMask = @splat(0);
        for (job.repaint) |r| {
            const s = bin.Span.fromPx(r).intersect(.{ .x0 = tile.x, .y0 = tile.y, .x1 = tile.x + tile.w, .y1 = tile.y + tile.h });
            if (s.empty()) continue;
            const w: u6 = @intCast(s.x1 - s.x0 - 1);
            const bits: u64 = (@as(u64, std.math.maxInt(u64)) >> @intCast(63 - @as(u32, w))) << @intCast(s.x0 - tile.x);
            var y = s.y0;
            while (y < s.y1) : (y += 1) mask[@intCast(y - tile.y)] |= bits;
        }
        for (mask[0..tile.h]) |m| px += @popCount(m);
        shaded += 1;
        raster.shadeTile(8, tile, items, job.prims, job.ctx, job.target, &mask, scratch);
    }
    _ = job.pixels.fetchAdd(px, .monotonic);
    _ = job.tiles.fetchAdd(shaded, .monotonic);
}

fn workTask(job: *Job, worker: u32) std.Io.Cancelable!void {
    work(job, worker);
}

/// Bins and shades prims of `layer` (0 = window) into `target`.
fn pass(self: *SwRenderer, dl: *const DrawList, range: [2]u32, layer: u16, target: raster.Target, repaint: []const PxRect, ctx: *const raster.ShadeCtx) RenderError!struct { px: u64, tiles: u32 } {
    const grid: bin.TileGrid = .{ .width = target.width, .height = target.height };
    bin.binPrims(self.gpa, dl.prims.items, range, layer, dl.clips.items, grid, repaint, &self.bins) catch return error.OutOfMemory;
    var job: Job = .{ .self = self, .target = target, .grid = grid, .repaint = repaint, .prims = dl.prims.items, .ctx = ctx };
    var group: std.Io.Group = .init;
    var spawned: u32 = 1;
    const want = @min(self.threads, grid.count());
    while (spawned < want) : (spawned += 1) {
        group.concurrent(self.io, workTask, .{ &job, spawned }) catch break;
    }
    work(&job, 0);
    group.await(self.io) catch {};
    return .{ .px = job.pixels.load(.monotonic), .tiles = job.tiles.load(.monotonic) };
}

fn renderTarget(self: *SwRenderer, dl: *const DrawList, target: raster.Target, repaint: []const PxRect) RenderError!r2d.FrameStats {
    var stats: r2d.FrameStats = .{ .backend = .software, .prims = @intCast(dl.prims.items.len) };
    var ctx: raster.ShadeCtx = .{ .clips = dl.clips.items, .textures = self.textures.items, .layers = &.{}, .text = self.opts.text };
    // Layer passes.
    self.layer_view.resize(self.gpa, dl.layers.items.len) catch return error.OutOfMemory;
    for (dl.layers.items, 0..) |lu, i| {
        self.layer_view.items[i] = null;
        if (!lu.drawn) {
            if (self.layers.get(lu.id)) |l| self.layer_view.items[i] = &l.tex;
            continue;
        }
        const l = try self.getLayer(lu.id, lu.size);
        const full = [_]PxRect{.{ .x = 0, .y = 0, .w = lu.size.w, .h = lu.size.h }};
        const dmg = dl.layerDamage(lu);
        const rep: []const PxRect = if (!l.valid or dmg.len == 0) &full else dmg;
        for (rep) |r| l.tex.clear(r);
        const res = try self.pass(dl, .{ lu.prim_start, lu.prim_end }, @intCast(i + 1), .{ .pixels = l.tex.pixels, .stride = l.tex.stride, .width = lu.size.w, .height = lu.size.h, .bgra = false }, rep, &ctx);
        l.valid = true;
        self.layer_view.items[i] = &l.tex;
        stats.repainted_px += res.px;
        stats.draws += res.tiles;
    }
    ctx.layers = self.layer_view.items;
    const res = try self.pass(dl, .{ 0, @intCast(dl.prims.items.len) }, 0, target, repaint, &ctx);
    stats.repainted_px += res.px;
    stats.draws += res.tiles;
    return stats;
}

fn getLayer(self: *SwRenderer, id: r2d.LayerId, size: Size) RenderError!*Layer {
    if (size.w == 0 or size.h == 0 or size.w > 16384 or size.h > 16384) return error.InvalidArgument;
    if (self.layers.get(id)) |l| {
        if (l.tex.width == size.w and l.tex.height == size.h) return l;
        const t = CpuTexture.init(self.gpa, .{ .width = size.w, .height = size.h, .format = .rgba8 }) catch return error.OutOfMemory;
        l.tex.deinit(self.gpa);
        l.tex = t;
        l.valid = false;
        return l;
    }
    const l = self.gpa.create(Layer) catch return error.OutOfMemory;
    errdefer self.gpa.destroy(l);
    l.* = .{ .tex = CpuTexture.init(self.gpa, .{ .width = size.w, .height = size.h, .format = .rgba8 }) catch return error.OutOfMemory, .valid = false };
    errdefer l.tex.deinit(self.gpa);
    self.layers.put(self.gpa, id, l) catch return error.OutOfMemory;
    return l;
}

const testing = std.testing;

fn nullSink() platform.surface.HeadlessSink {
    return .{ .ptr = undefined, .write = struct {
        fn w(_: *anyopaque, _: platform.types.WindowId, _: []const PxRect, _: []const u8, _: u32) void {}
    }.w };
}

fn testScene(dl: *DrawList, rnd: std.Random) void {
    dl.reset(.{ .w = 200, .h = 150 }, 1);
    dl.damageAll();
    dl.rect(.{ .x = 0, .y = 0, .w = 200, .h = 150 }, r2d.Color.fromHex("#202830"), .{});
    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        const r: r2d.RectF = .{ .x = rnd.float(f32) * 200 - 20, .y = rnd.float(f32) * 150 - 20, .w = rnd.float(f32) * 60, .h = rnd.float(f32) * 40 };
        const c: r2d.Color = .{ .r = rnd.int(u8), .g = rnd.int(u8), .b = rnd.int(u8), .a = rnd.int(u8) };
        switch (i % 5) {
            0 => dl.rect(r, c, r2d.Radii.all(rnd.float(f32) * 10)),
            1 => dl.border(r, r2d.Insets.all(rnd.float(f32) * 4), c, r2d.Radii.all(rnd.float(f32) * 8)),
            2 => dl.shadow(r, r2d.Radii.all(4), rnd.float(f32) * 6, 2, c),
            3 => dl.linearGradient(r, .{ .x = r.x, .y = r.y }, .{ .x = r.x + r.w, .y = r.y + r.h }, c, r2d.Color.white, .{}),
            else => {
                dl.pushClip(.{ .x = r.x, .y = r.y, .w = r.w * 0.6, .h = r.h }, r2d.Radii.all(5));
                dl.rect(r, c, .{});
                dl.popClip();
            },
        }
    }
}

test "sw: scalar vs vector shading identical" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(11);
    var dl = DrawList.init(gpa);
    defer dl.deinit();
    testScene(&dl, prng.random());
    const ctx: raster.ShadeCtx = .{ .clips = dl.clips.items, .textures = &.{}, .layers = &.{}, .text = .{} };
    const tile: bin.TileRect = .{ .x = 64, .y = 64, .w = 64, .h = 64 };
    const s1 = try gpa.create(raster.Scratch);
    defer gpa.destroy(s1);
    const s8 = try gpa.create(raster.Scratch);
    defer gpa.destroy(s8);
    @memset(&s1.r, 0.1);
    @memset(&s1.g, 0.2);
    @memset(&s1.b, 0.3);
    @memset(&s1.a, 1);
    s8.* = s1.*;
    for (dl.prims.items) |*p| {
        raster.shadePrim(1, tile, p, &ctx, s1);
        raster.shadePrim(8, tile, p, &ctx, s8);
    }
    try testing.expectEqualSlices(f32, &s1.r, &s8.r);
    try testing.expectEqualSlices(f32, &s1.g, &s8.g);
    try testing.expectEqualSlices(f32, &s1.b, &s8.b);
    try testing.expectEqualSlices(f32, &s1.a, &s8.a);
}

test "sw: deterministic across thread counts" {
    const gpa = testing.allocator;
    var sink = nullSink();
    var outs: [2]CpuImage = undefined;
    for ([_]u8{ 1, 8 }, 0..) |n, k| {
        var prng = std.Random.DefaultPrng.init(5);
        var dl = DrawList.init(gpa);
        defer dl.deinit();
        testScene(&dl, prng.random());
        const sw = try SwRenderer.create(gpa, testing.io, .{ .target = .{ .headless = &sink }, .sw_threads = n });
        defer sw.destroy();
        outs[k] = try CpuImage.init(gpa, 200, 150);
        _ = try sw.renderToImage(&dl, &outs[k]);
    }
    defer for (&outs) |*o| o.deinit(gpa);
    try testing.expectEqualSlices(u8, outs[0].pixels, outs[1].pixels);
    // Something was drawn.
    try testing.expect(std.mem.indexOfNone(u8, outs[0].pixels, &.{0}) != null);
}

test "sw: damage-limited render leaves other pixels untouched" {
    const gpa = testing.allocator;
    var sink = nullSink();
    const sw = try SwRenderer.create(gpa, testing.io, .{ .target = .{ .headless = &sink }, .sw_threads = 2 });
    defer sw.destroy();
    var img = try CpuImage.init(gpa, 100, 100);
    defer img.deinit(gpa);
    img.fill(.{ 7, 7, 7, 7 });
    var dl = DrawList.init(gpa);
    defer dl.deinit();
    dl.reset(.{ .w = 100, .h = 100 }, 1);
    dl.rect(.{ .x = 0, .y = 0, .w = 100, .h = 100 }, r2d.Color.white, .{});
    dl.addDamage(.{ .x = 10, .y = 20, .w = 5, .h = 3 });
    dl.addDamage(.{ .x = 70, .y = 60, .w = 30, .h = 40 });
    const st = try sw.renderToImage(&dl, &img);
    try testing.expectEqual(@as(u64, 15 + 1200), st.repainted_px);
    var y: u32 = 0;
    while (y < 100) : (y += 1) {
        var x: u32 = 0;
        while (x < 100) : (x += 1) {
            const in = (x >= 10 and x < 15 and y >= 20 and y < 23) or (x >= 70 and y >= 60);
            const want: [4]u8 = if (in) .{ 255, 255, 255, 255 } else .{ 7, 7, 7, 7 };
            try testing.expectEqual(want, img.get(x, y));
        }
    }
}

test "sw: textures, glyphs and layers render" {
    const gpa = testing.allocator;
    var sink = nullSink();
    const sw = try SwRenderer.create(gpa, testing.io, .{ .target = .{ .headless = &sink }, .sw_threads = 1 });
    defer sw.destroy();
    const r = sw.renderer();
    const atlas = try r.createTexture(.{ .width = 4, .height = 4, .format = .r8 });
    try r.updateTexture(atlas, .{ .x = 0, .y = 0, .w = 4, .h = 4 }, &(.{ 255, 0, 255, 0 } ** 4), 4);
    var dl = DrawList.init(gpa);
    defer dl.deinit();
    dl.layer_query = r.layerQuery();
    var img = try CpuImage.init(gpa, 32, 32);
    defer img.deinit(gpa);
    for (0..2) |frame| {
        dl.reset(.{ .w = 32, .h = 32 }, 1);
        dl.damageAll();
        dl.rect(.{ .x = 0, .y = 0, .w = 32, .h = 32 }, r2d.Color.white, .{});
        const q = [_]r2d.GlyphQuad{.{ .dst = .{ 0, 0, 4, 4 }, .uv = .{ 0, 0, 1, 1 }, .page = @intCast(@intFromEnum(atlas)), .format = .r8 }};
        dl.glyphs(&q, r2d.Color.black, .grayscale);
        const drew = dl.beginLayer(@enumFromInt(1), .{ .w = 8, .h = 8 }, &.{});
        try testing.expectEqual(frame == 0, drew);
        if (drew) {
            dl.rect(.{ .x = 0, .y = 0, .w = 8, .h = 8 }, r2d.Color.fromHex("#ff0000"), .{});
            dl.endLayer();
        }
        dl.drawLayer(@enumFromInt(1), .{ .x = 16, .y = 16, .w = 8, .h = 8 }, .{}, 1);
        _ = try sw.renderToImage(&dl, &img);
        try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, img.get(0, 0));
        try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, img.get(1, 0));
        try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, img.get(20, 20));
        try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, img.get(24, 20));
    }
    r.destroyTexture(atlas);
    try testing.expectEqual(atlas, try r.createTexture(.{ .width = 1, .height = 1, .format = .rgba8 }));
}

test "sw: headless target passes damage to the sink" {
    const gpa = testing.allocator;
    const Rec = struct {
        frames: u32 = 0,
        last_damage: usize = 0,
        px: u8 = 0,
        fn w(ctx: *anyopaque, _: platform.types.WindowId, damage: []const PxRect, pixels: []const u8, _: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.frames += 1;
            self.last_damage = damage.len;
            self.px = pixels[0];
        }
    };
    var rec: Rec = .{};
    var sink: platform.surface.HeadlessSink = .{ .ptr = &rec, .write = Rec.w };
    const sw = try SwRenderer.create(gpa, testing.io, .{ .target = .{ .headless = &sink }, .sw_threads = 1 });
    const r = sw.renderer();
    defer r.deinit();
    var dl = DrawList.init(gpa);
    defer dl.deinit();
    dl.reset(.{ .w = 10, .h = 10 }, 1);
    dl.rect(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, r2d.Color.fromHex("#0000ff"), .{});
    const s1 = try r.render(&dl);
    try testing.expect(s1.needs_full_redraw);
    try testing.expectEqual(@as(u8, 255), rec.px); // BGRA: blue first
    // No damage, nothing to do.
    const s2 = try r.render(&dl);
    try testing.expectEqual(@as(u64, 0), s2.present_id);
    try testing.expectEqual(@as(u32, 1), rec.frames);
    dl.addDamage(.{ .x = 0, .y = 0, .w = 2, .h = 2 });
    dl.addDamage(.{ .x = 5, .y = 5, .w = 2, .h = 2 });
    const s3 = try r.render(&dl);
    try testing.expectEqual(@as(u64, 8), s3.repainted_px);
    try testing.expectEqual(@as(usize, 2), rec.last_damage);
}

test "sw: shm presenter ring uses buffer age" {
    const gpa = testing.allocator;
    const Fake = struct {
        bufs: [3][]u8 = undefined,
        n: u32 = 0,
        presented: std.ArrayList(u32) = .empty,
        released: std.ArrayList(platform.surface.BufferHandle) = .empty,

        fn drm(_: *anyopaque) ?platform.surface.DrmDevice {
            return null;
        }
        fn formats(_: *anyopaque, _: []platform.surface.FormatModifier) usize {
            return 0;
        }
        fn sync(_: *anyopaque) platform.surface.SyncMode {
            return .cpu_only;
        }
        fn import(_: *anyopaque, _: *const platform.surface.BufferDesc) anyerror!platform.surface.BufferHandle {
            return error.Unsupported;
        }
        fn present(ctx: *anyopaque, buf: platform.surface.BufferHandle, _: []const PxRect, _: platform.surface.SyncPoint, _: ?platform.surface.ConfigureAck) anyerror!void {
            const f: *@This() = @ptrCast(@alignCast(ctx));
            try f.presented.append(testing.allocator, @intFromEnum(buf));
            // The compositor releases the previous buffer.
            if (f.presented.items.len >= 2) try f.released.append(testing.allocator, @enumFromInt(f.presented.items[f.presented.items.len - 2]));
        }
        fn release(_: *anyopaque, _: platform.surface.BufferHandle) void {}
        fn poll(ctx: *anyopaque, out: []platform.surface.BufferHandle) usize {
            const f: *@This() = @ptrCast(@alignCast(ctx));
            const n = @min(out.len, f.released.items.len);
            @memcpy(out[0..n], f.released.items[0..n]);
            f.released.clearRetainingCapacity();
            return n;
        }
        fn alloc(ctx: *anyopaque, w: u32, h: u32, _: u32) anyerror!platform.surface.CpuBuffer {
            const f: *@This() = @ptrCast(@alignCast(ctx));
            f.bufs[f.n] = try testing.allocator.alloc(u8, w * h * 4);
            @memset(f.bufs[f.n], 0);
            f.n += 1;
            return .{ .handle = @enumFromInt(f.n - 1), .pixels = f.bufs[f.n - 1], .stride = w * 4 };
        }
    };
    var fake: Fake = .{};
    defer {
        for (fake.bufs[0..fake.n]) |b| gpa.free(b);
        fake.presented.deinit(gpa);
        fake.released.deinit(gpa);
    }
    const vt: platform.surface.PresenterVTable = .{ .drmDevice = Fake.drm, .formats = Fake.formats, .syncMode = Fake.sync, .importBuffer = Fake.import, .present = Fake.present, .releaseBuffer = Fake.release, .pollReleased = Fake.poll, .allocCpuBuffer = Fake.alloc };
    var presenter: platform.surface.Presenter = .{ .ptr = &fake, .vtable = &vt };
    const sw = try SwRenderer.create(gpa, testing.io, .{ .target = .{ .external = &presenter }, .sw_threads = 1 });
    defer sw.destroy();
    var dl = DrawList.init(gpa);
    defer dl.deinit();
    dl.reset(.{ .w = 16, .h = 16 }, 1);
    dl.rect(.{ .x = 0, .y = 0, .w = 16, .h = 16 }, r2d.Color.white, .{});
    _ = try sw.render(&dl); // buffer 0, full
    dl.addDamage(.{ .x = 0, .y = 0, .w = 1, .h = 1 });
    const s2 = try sw.render(&dl); // buffer 1, never drawn: full
    try testing.expectEqual(@as(u64, 256), s2.repainted_px);
    const s3 = try sw.render(&dl); // buffer 0 again, age 2: damage of frames 2 and 3
    try testing.expectEqual(@as(u64, 1), s3.repainted_px);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 0 }, fake.presented.items);
    try testing.expectEqual(@as(u8, 255), fake.bufs[1][100]);
}
