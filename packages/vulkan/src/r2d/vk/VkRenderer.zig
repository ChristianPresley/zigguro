//! The Vulkan 2D backend (E02.F06.S01.T02): turns a `DrawList` into one
//! recorded and submitted frame.
//!
//! 1. `FrameScheduler.begin` waits for the frame slot and recycles it.
//! 2. The repaint region comes from the target's image age and the
//!    list's damage (`DamageHistory`, at most 16 rects).
//! 3. Prims and clips go to the upload ring (bound once as the prim and
//!    clip storage buffers; `firstInstance` and `clip_base` select the
//!    frame's part); pending texture uploads are recorded first.
//! 4. One dynamic-rendering pass: each repaint rect is cleared, scissored
//!    and drawn with its culled batches (`batch.zig`).
//! 5. The target copies the repainted rects out (Readback) and delivers
//!    them when the frame retires.
//!
//! Targets today: headless and in-memory Readback. Layers (E02.F06.S03),
//! the Win32 swapchain, the Linux dmabuf ring and GPU timing follow; until
//! layers land, layer content and layer prims are not drawn.

const VkRenderer = @This();

const std = @import("std");
const platform = @import("zg_platform");
const zg_core = @import("zg_core");
const r2d = @import("../root.zig");
const vk = @import("../../vk/vk.zig");
const Gpu = @import("../../gpu/Gpu.zig");
const DeviceMemory = @import("../../mem/DeviceMemory.zig");
const Texture = @import("../../mem/Texture.zig");
const UploadRing = @import("../../mem/UploadRing.zig");
const Uploader = @import("../../mem/Uploader.zig");
const barriers = @import("../../mem/barriers.zig");
const pipeline = @import("../../pipeline/root.zig");
const iface = @import("../../shaders/interface.zig");
const FrameScheduler = @import("../../present/FrameScheduler.zig");
const Readback = @import("../../present/Readback.zig");
const Damage = @import("../../present/Damage.zig");
const CpuImage = @import("../../testing/CpuImage.zig");
const batch = @import("batch.zig");

const log = std.log.scoped(.zg_vulkan);

const DrawList = r2d.DrawList;
const PxRect = r2d.PxRect;
const Size = r2d.Size;
const RenderError = r2d.RenderError;

/// Initial upload ring bytes per frame (grown on demand).
const initial_ring_bytes = 256 << 10;

gpa: std.mem.Allocator,
io: std.Io,
opts: r2d.RendererOptions,
gpu: *Gpu,
owns_gpu: bool,
mem: DeviceMemory,
sched: FrameScheduler,
heap: pipeline.DescriptorHeap,
cache: pipeline.PipelineCache,
pipes: pipeline.Pipelines,
ring: UploadRing,
uploader: Uploader,
readback: Readback,
history: Damage.DamageHistory = .{},
/// Textures by id (= descriptor slot); null when free.
textures: std.ArrayList(?*Texture) = .empty,
/// Created textures not yet initialised on the GPU.
fresh: std.ArrayList(*Texture) = .empty,
/// Textures destroyed by the caller, retired with the next frame.
doomed: std.ArrayList(u32) = .empty,
batches: std.ArrayList(batch.Batch) = .empty,
clip_scratch: std.ArrayList(iface.ClipGpu) = .empty,
extent: Size = .{ .w = 0, .h = 0 },
scale: f32 = 1,
needs_full: bool = true,
warned_layers: bool = false,

/// Creates a Vulkan device for `opts` and a renderer on it. Headless
/// targets only for now (`error.Unsupported` otherwise).
pub fn create(gpa: std.mem.Allocator, io: std.Io, opts: r2d.RendererOptions) !*VkRenderer {
    switch (opts.target) {
        .headless => {},
        else => return error.Unsupported,
    }
    const gpu = try Gpu.create(gpa, io, .{
        .instance = .{ .env_validation = opts.env.vk_validation },
        .forced = opts.env.gpu orelse opts.gpu,
        .loader_path = opts.env.vk_loader_path,
        .fault = opts.env.vk_fault,
    });
    errdefer gpu.destroy();
    const self = try createWithGpu(gpa, io, gpu, opts);
    self.owns_gpu = true;
    return self;
}

/// A renderer on an existing device (tests share a validated one). The
/// device must outlive the renderer.
pub fn createWithGpu(gpa: std.mem.Allocator, io: std.Io, gpu: *Gpu, opts: r2d.RendererOptions) !*VkRenderer {
    const sink: Readback.Sink = switch (opts.target) {
        .headless => |s| .{ .headless = s },
        else => return error.Unsupported,
    };
    const self = try gpa.create(VkRenderer);
    errdefer gpa.destroy(self);
    const frames: u8 = std.math.clamp(opts.present.frames_in_flight, 1, FrameScheduler.max_frames_in_flight);
    self.gpa = gpa;
    self.io = io;
    self.opts = opts;
    self.gpu = gpu;
    self.owns_gpu = false;
    self.mem = DeviceMemory.init(gpu, gpa, .{});
    errdefer self.mem.deinit();
    self.sched = try FrameScheduler.init(gpu, &self.mem, frames);
    errdefer self.sched.deinit();
    self.heap = try pipeline.DescriptorHeap.init(gpu, pipeline.DescriptorHeap.default_max_textures);
    errdefer self.heap.deinit();
    self.cache = pipeline.PipelineCache.load(io, gpu, opts.cache_dir, pipeline.shaderIdentity());
    errdefer self.cache.destroy();
    self.readback = Readback.init(gpu, &self.mem, &self.sched, sink, opts.window);
    self.pipes = try pipeline.createPipelines(gpu, &self.cache, &self.heap, self.readback.vkFormat());
    errdefer self.pipes.deinit();
    self.ring = try UploadRing.init(&self.mem, frames, initial_ring_bytes);
    errdefer self.ring.deinit();
    // Uploads go through staging buffers (retired with their frame), so
    // texture updates between frames never touch a ring slot in flight.
    self.uploader = .{ .gpa = gpa, .mem = &self.mem, .ring = null };
    self.history = .{};
    self.textures = .empty;
    self.fresh = .empty;
    self.doomed = .empty;
    self.batches = .empty;
    self.clip_scratch = .empty;
    self.extent = opts.size;
    self.scale = 1;
    self.needs_full = true;
    self.warned_layers = false;
    try self.textures.append(gpa, null); // slot 0 = none
    self.bindRing();
    return self;
}

pub fn destroy(self: *VkRenderer) void {
    const gpa = self.gpa;
    self.sched.waitValue(self.sched.submitted) catch {};
    self.readback.deinit();
    self.uploader.deinit();
    for (self.textures.items) |t| if (t) |tex| {
        tex.destroy(&self.mem);
        gpa.destroy(tex);
    };
    self.textures.deinit(gpa);
    self.fresh.deinit(gpa);
    self.doomed.deinit(gpa);
    self.batches.deinit(gpa);
    self.clip_scratch.deinit(gpa);
    self.ring.deinit();
    self.sched.deinit();
    self.pipes.deinit();
    if (self.opts.cache_dir) |dir| self.cache.saveIfChanged(self.io, dir);
    self.cache.destroy();
    self.heap.deinit();
    self.mem.deinit();
    const gpu = self.gpu;
    const owns = self.owns_gpu;
    gpa.destroy(self);
    if (owns) gpu.destroy();
}

/// The type-erased interface.
pub fn renderer(self: *VkRenderer) r2d.Renderer {
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

fn cast(p: *anyopaque) *VkRenderer {
    return @ptrCast(@alignCast(p));
}
fn vRender(p: *anyopaque, dl: *const DrawList) RenderError!r2d.FrameStats {
    return cast(p).render(dl);
}
fn vResize(p: *anyopaque, size: Size, scale: f32) void {
    const self = cast(p);
    if (size.w != self.extent.w or size.h != self.extent.h) self.needs_full = true;
    self.extent = size;
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
fn vDestroyLayer(_: *anyopaque, _: r2d.LayerId) void {}
fn vBackend(_: *anyopaque) r2d.Backend {
    return .vulkan;
}
fn vDeinit(p: *anyopaque) void {
    cast(p).destroy();
}
fn vLayerValid(_: *anyopaque, _: r2d.LayerId, _: Size) bool {
    return false;
}

fn mapErr(err: anyerror) RenderError {
    return switch (err) {
        error.OutOfMemory, error.OutOfHostMemory, error.OutOfDeviceMemory => error.OutOfMemory,
        error.DeviceLost => error.DeviceLost,
        else => blk: {
            log.err("render failed: {t}", .{err});
            break :blk error.DeviceLost;
        },
    };
}

// ------------------------------------------------------------- textures

/// Creates a zeroed texture; its id is its descriptor slot.
pub fn createTexture(self: *VkRenderer, desc: r2d.TextureDesc) RenderError!r2d.TextureId {
    if (desc.width == 0 or desc.height == 0 or desc.width > Texture.max_side or desc.height > Texture.max_side) return error.InvalidArgument;
    const fmt: Texture.Format = switch (desc.format) {
        .r8 => .r8_unorm,
        .rgba8 => .rgba8_unorm,
    };
    const t = self.gpa.create(Texture) catch return error.OutOfMemory;
    errdefer self.gpa.destroy(t);
    t.* = Texture.create(&self.mem, desc.width, desc.height, fmt, .sampled, "r2d-texture") catch |e| return mapErr(e);
    errdefer t.destroy(&self.mem);
    const slot = self.heap.allocSlot(t.view, .linear_clamp) catch return error.OutOfMemory;
    t.slot = slot;
    if (slot >= self.textures.items.len) self.textures.resize(self.gpa, slot + 1) catch return error.OutOfMemory;
    self.textures.items[slot] = t;
    self.fresh.append(self.gpa, t) catch return error.OutOfMemory;
    return @enumFromInt(slot);
}

fn texture(self: *VkRenderer, id: r2d.TextureId) ?*Texture {
    const i = @intFromEnum(id);
    if (i == 0 or i >= self.textures.items.len) return null;
    return self.textures.items[i];
}

/// Queues an upload of `rect`; it lands before the next frame draws.
pub fn updateTexture(self: *VkRenderer, id: r2d.TextureId, rect: PxRect, data: []const u8, pitch: u32) RenderError!void {
    const t = self.texture(id) orelse return error.InvalidArgument;
    if (rect.x < 0 or rect.y < 0 or rect.w == 0 or rect.h == 0) return error.InvalidArgument;
    const r: Uploader.Rect16 = .{ .x = @intCast(rect.x), .y = @intCast(rect.y), .w = @intCast(rect.w), .h = @intCast(rect.h) };
    self.uploader.writeRegion(t, r, data, pitch) catch |e| return switch (e) {
        error.OutOfBounds, error.ShortPixels, error.EmptyRect => error.InvalidArgument,
        else => mapErr(e),
    };
}

/// Destroys a texture once no frame uses it.
pub fn destroyTexture(self: *VkRenderer, id: r2d.TextureId) void {
    if (self.texture(id) == null) return;
    self.doomed.append(self.gpa, @intFromEnum(id)) catch {
        // Keep it alive rather than freeing something in use.
    };
}

/// Zero-initialises textures created since the last frame.
fn initFresh(self: *VkRenderer, cb: vk.CommandBuffer) void {
    const d = &self.gpu.ddisp;
    for (self.fresh.items) |t| {
        barriers.imageTransition(cb, d, t.image.handle, .undefined, .transfer_dst, .{ .color = true });
        d.cmd_clear_color_image(cb, t.image.handle, .transfer_dst_optimal, &.{ .float32 = .{ 0, 0, 0, 0 } }, 1, @ptrCast(&barriers.color_range));
        barriers.imageTransition(cb, d, t.image.handle, .transfer_dst, .shader_read, .{ .color = true });
        t.access = .shader_read;
    }
    self.fresh.clearRetainingCapacity();
}

/// Retires the textures destroyed by the caller with the frame being
/// recorded.
fn retireDoomed(self: *VkRenderer) void {
    const value = self.sched.submitted + 1;
    for (self.doomed.items) |slot| {
        const t = self.textures.items[slot] orelse continue;
        self.textures.items[slot] = null;
        for (self.fresh.items, 0..) |f, i| if (f == t) {
            _ = self.fresh.swapRemove(i);
            break;
        };
        self.heap.freeSlot(slot, value);
        self.sched.deferDestroy(.{ .texture = t.* });
        self.gpa.destroy(t);
    }
    self.doomed.clearRetainingCapacity();
}

// ------------------------------------------------------------- frames

fn bindRing(self: *VkRenderer) void {
    const buf = self.ring.gpuBuffer();
    self.heap.bindBuffers(.{ .buffer = buf, .offset = 0, .range = vk.whole_size }, .{ .buffer = buf, .offset = 0, .range = vk.whole_size });
}

/// Grows the ring (after the GPU drained it) when a frame would not fit.
fn ensureRing(self: *VkRenderer, need: u64) !void {
    if (need <= self.ring.per_frame) return;
    var size: u64 = self.ring.per_frame;
    while (size < need) size *= 2;
    try self.sched.waitValue(self.sched.submitted);
    try self.ring.resize(size);
    self.bindRing();
}

/// Renders `dl` and hands the result to the target.
pub fn render(self: *VkRenderer, dl: *const DrawList) RenderError!r2d.FrameStats {
    return self.renderInner(dl) catch |e| mapErr(e);
}

/// Renders `dl` into `out` (its channel order picks the target format;
/// it must match the renderer's) and waits for the pixels. Damage applies
/// as for windows: `out` keeps the pixels of earlier calls.
pub fn renderToImage(self: *VkRenderer, dl: *const DrawList, out: *CpuImage) RenderError!r2d.FrameStats {
    const prev = self.readback.sink;
    self.readback.setSink(.{ .memory = out });
    defer self.readback.setSink(prev);
    const stats = try self.render(dl);
    self.readback.waitIdle();
    return stats;
}

fn renderInner(self: *VkRenderer, dl: *const DrawList) !r2d.FrameStats {
    const start = zg_core.time.nowNs(self.io);
    const extent = dl.extent;
    var stats: r2d.FrameStats = .{ .backend = .vulkan, .prims = @intCast(dl.prims.items.len) };
    if (extent.w == 0 or extent.h == 0) return stats;
    if (extent.w != self.extent.w or extent.h != self.extent.h) {
        self.extent = extent;
        self.needs_full = true;
    }
    const full_frame = self.needs_full or dl.damage_full or dl.alloc_failed;
    if (!full_frame and dl.damage_len == 0) {
        // Idle: nothing changed, nothing is submitted.
        self.readback.poll();
        return stats;
    }
    if (!self.warned_layers and dl.layers.items.len != 0) {
        self.warned_layers = true;
        log.warn("layers are not drawn by the Vulkan backend yet", .{});
    }

    const prim_bytes = dl.prims.items.len * @sizeOf(r2d.prim.Prim);
    const clip_bytes = dl.clips.items.len * @sizeOf(iface.ClipGpu);
    try self.ensureRing(prim_bytes + clip_bytes + 1024);

    const fs = try self.sched.begin();
    self.ring.beginFrame(fs.index);
    self.heap.reclaim(self.sched.completed());
    self.readback.poll();
    const acq = try self.readback.acquire(extent);

    var repaint: Damage.RectList = .{};
    const r2d_rect = r2d.rect;
    if (full_frame) {
        repaint.add(r2d_rect.full(extent));
    } else {
        self.history.repaintFor(acq.age, dl.damageRects(), extent, &repaint);
    }
    const full_repaint = repaint.isFull(extent);

    // Prims and clips into the ring.
    var first_instance: u32 = 0;
    var clip_base: u32 = 0;
    if (prim_bytes > 0) {
        const s = try self.ring.alloc(prim_bytes, @sizeOf(r2d.prim.Prim));
        @memcpy(s.bytes(), std.mem.sliceAsBytes(dl.prims.items));
        first_instance = @intCast(s.offset / @sizeOf(r2d.prim.Prim));
    }
    if (clip_bytes > 0) {
        const s = try self.ring.alloc(clip_bytes, @sizeOf(iface.ClipGpu));
        const out: []iface.ClipGpu = @alignCast(std.mem.bytesAsSlice(iface.ClipGpu, s.bytes()));
        for (out, dl.clips.items) |*c, src| c.* = .{ .bounds = src.bounds, .radii = src.radii };
        clip_base = @intCast(s.offset / @sizeOf(iface.ClipGpu));
    }

    const cb = fs.cb;
    const d = &self.gpu.ddisp;
    self.initFresh(cb);
    try self.uploader.record(cb, d);
    for (self.uploader.staging.items) |b| self.sched.deferDestroy(.{ .buffer = b });
    self.uploader.staging.clearRetainingCapacity();
    try self.ring.endFrame(cb, d);

    // The pass.
    const img = acq.image;
    barriers.imageTransition(cb, d, img.image.handle, if (acq.age == 0) .undefined else img.access, .color_attachment, .{ .color = true });
    img.access = .color_attachment;
    const attach = [_]vk.RenderingAttachmentInfo{.{
        .image_view = img.view,
        .image_layout = .color_attachment_optimal,
        .resolve_image_layout = .undefined,
        .load_op = if (full_repaint) .clear else .load,
        .store_op = .store,
        .clear_value = .{ .color = .{ .float32 = .{ 0, 0, 0, 0 } } },
    }};
    const area: vk.Rect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = extent.w, .height = extent.h } };
    d.cmd_begin_rendering(cb, &.{ .render_area = area, .layer_count = 1, .view_mask = 0, .color_attachment_count = 1, .p_color_attachments = &attach });
    const vp = [_]vk.Viewport{.{ .x = 0, .y = 0, .width = @floatFromInt(extent.w), .height = @floatFromInt(extent.h), .min_depth = 0, .max_depth = 1 }};
    d.cmd_set_viewport(cb, 0, 1, &vp);
    self.heap.bind(cb);
    const pc: iface.PushConstants = .{
        .viewport_px = .{ @floatFromInt(extent.w), @floatFromInt(extent.h) },
        .inv_viewport = .{ 1.0 / @as(f32, @floatFromInt(extent.w)), 1.0 / @as(f32, @floatFromInt(extent.h)) },
        .clip_base = clip_base,
        .text_gamma = self.opts.text.gamma,
        .text_contrast = self.opts.text.contrast,
    };
    d.cmd_push_constants(cb, self.heap.pipeline_layout, .{ .vertex = true, .fragment = true }, 0, @sizeOf(iface.PushConstants), &pc);
    const dual_src = self.pipes.text_subpixel != null;
    var bound: ?batch.Pipeline = null;
    for (repaint.slice()) |r| {
        const sc = [_]vk.Rect2D{.{ .offset = .{ .x = r.x, .y = r.y }, .extent = .{ .width = r.w, .height = r.h } }};
        if (!full_repaint) {
            // Each repainted rect starts transparent, like the software renderer.
            const ca = [_]vk.ClearAttachment{.{ .aspect_mask = .{ .color = true }, .color_attachment = 0, .clear_value = .{ .color = .{ .float32 = .{ 0, 0, 0, 0 } } } }};
            const cr = [_]vk.ClearRect{.{ .rect = sc[0], .base_array_layer = 0, .layer_count = 1 }};
            d.cmd_clear_attachments(cb, 1, &ca, 1, &cr);
        }
        d.cmd_set_scissor(cb, 0, 1, &sc);
        self.batches.clearRetainingCapacity();
        try batch.buildBatches(self.gpa, dl.prims.items, dl.clips.items, if (full_repaint) null else r, dual_src, &self.batches);
        for (self.batches.items) |b| {
            if (bound != b.pipeline) {
                d.cmd_bind_pipeline(cb, .graphics, switch (b.pipeline) {
                    .prim => self.pipes.prim,
                    .text_subpixel => self.pipes.text_subpixel.?,
                });
                bound = b.pipeline;
            }
            d.cmd_draw(cb, 4, b.count, 0, first_instance + b.first);
            stats.draws += 1;
        }
        stats.repainted_px += r2d_rect.area(r);
    }
    d.cmd_end_rendering(cb);

    try self.readback.recordCopy(fs, repaint.slice());
    self.retireDoomed();
    try self.sched.submit(fs, &.{}, &.{});
    self.readback.present(fs);
    if (full_frame) self.history.pushFull() else self.history.push(dl.damageRects());
    self.needs_full = false;
    stats.needs_full_redraw = full_repaint;
    stats.present_id = fs.timeline_value;
    stats.cpu_encode_ns = @intCast(zg_core.time.nowNs(self.io) - start);
    return stats;
}
