//! The Vulkan 2D backend (E02.F06.S01.T02): turns a `DrawList` into one
//! recorded and submitted frame.
//!
//! 1. `FrameScheduler.begin` waits for the frame slot and recycles it.
//! 2. The repaint region comes from the target's image age and the
//!    list's damage (`DamageHistory`, at most 16 rects).
//! 3. Prims and clips go to the upload ring (bound once as the prim and
//!    clip storage buffers; `firstInstance` and `clip_base` select the
//!    frame's part); pending texture uploads are recorded first.
//! 4. Layer passes (E02.F06.S03.T01): each layer redrawn this frame gets
//!    its own dynamic-rendering pass on its texture, one scissored piece
//!    per wrapped damage rect (`r2d/layers.zig`); pieces shown at an offset
//!    draw translated copies of the layer's prims and clips, uploaded with
//!    the frame. The texture then becomes shader-readable (sync2 barrier).
//! 5. One dynamic-rendering pass on the target: each repaint rect is
//!    cleared, scissored and drawn with its culled batches (`batch.zig`);
//!    layer composites sample the layer's slot (repeat sampler for scroll
//!    layers).
//! 6. The target copies the repainted rects out (Readback) and delivers
//!    them when the frame retires.
//!
//! Timestamps around the uploads, layer passes and window pass are read
//! back when their slot is reused (`gpu_timing.zig`), so `FrameStats.gpu_ns`
//! lags by up to frames_in_flight frames and never blocks.
//!
//! Layers not used in a frame are evicted least recently used first once
//! they exceed `RendererOptions.layer_budget_bytes`.
//!
//! Targets today: Readback to a headless sink, to memory, or to an
//! external presenter's shm buffers. The Win32 swapchain and the Linux
//! dmabuf ring follow.

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
const GpuTimer = @import("gpu_timing.zig");
const wrap = r2d.layers;

const log = std.log.scoped(.zg_vulkan);

const DrawList = r2d.DrawList;
const PxRect = r2d.PxRect;
const Size = r2d.Size;
const RenderError = r2d.RenderError;

/// Initial upload ring bytes per frame (grown on demand).
const initial_ring_bytes = 256 << 10;

const LayerTable = wrap.LayerTable(*Texture);

/// One scissored piece of a layer pass.
const LayerPiece = struct {
    /// Texels repainted.
    rect: PxRect,
    /// Drawn from translated copies (`xprims`, `xclips`) instead of the list.
    translated: bool,
    /// Translated: first prim in `xprims` and prim count.
    first: u32 = 0,
    count: u32 = 0,
    /// Translated: first clip in `xclips`.
    clip_off: u32 = 0,
};

/// A layer redrawn this frame.
const LayerPass = struct {
    /// Index in the list's `layers`.
    index: u16,
    tex: *Texture,
    /// New texture: cleared on load.
    fresh: bool,
    pieces_start: u32,
    pieces_end: u32,
};

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
layers: LayerTable = .{},
/// Per frame: the descriptor slot of each list layer (0 = none).
layer_slots: std.ArrayList(u32) = .empty,
layer_passes: std.ArrayList(LayerPass) = .empty,
pieces: std.ArrayList(LayerPiece) = .empty,
/// Translated prims and clips of wrapped layer pieces.
xprims: std.ArrayList(r2d.prim.Prim) = .empty,
xclips: std.ArrayList(r2d.ClipRect) = .empty,
/// Frames rendered (layer LRU clock).
frame_no: u64 = 0,
extent: Size = .{ .w = 0, .h = 0 },
scale: f32 = 1,
needs_full: bool = true,
/// GPU timestamps (null when the queue has none).
timer: ?GpuTimer = null,
/// The latest durations read back (from frames_in_flight frames ago).
last_gpu: ?GpuTimer.Durations = null,

/// Creates a Vulkan device for `opts` and a renderer on it. Headless and
/// external (shm readback) targets for now (`error.Unsupported`
/// otherwise).
pub fn create(gpa: std.mem.Allocator, io: std.Io, opts: r2d.RendererOptions) !*VkRenderer {
    switch (opts.target) {
        .headless, .external => {},
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
        // Until the dmabuf ring lands, external presenters get shm
        // buffers filled by readback.
        .external => |p| .{ .shm = p },
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
    self.layers = .{};
    self.layer_slots = .empty;
    self.layer_passes = .empty;
    self.pieces = .empty;
    self.xprims = .empty;
    self.xclips = .empty;
    self.frame_no = 0;
    self.extent = opts.size;
    self.scale = 1;
    self.needs_full = true;
    self.timer = GpuTimer.init(gpu, frames) catch null;
    self.last_gpu = null;
    try self.textures.append(gpa, null); // slot 0 = none
    self.bindRing();
    return self;
}

pub fn destroy(self: *VkRenderer) void {
    const gpa = self.gpa;
    self.sched.waitValue(self.sched.submitted) catch {};
    if (self.timer) |*t| t.deinit();
    self.readback.deinit();
    self.uploader.deinit();
    for (self.textures.items) |t| if (t) |tex| {
        tex.destroy(&self.mem);
        gpa.destroy(tex);
    };
    self.textures.deinit(gpa);
    for (self.layers.entries.items) |e| {
        e.res.destroy(&self.mem);
        gpa.destroy(e.res);
    }
    self.layers.deinit(gpa);
    self.layer_slots.deinit(gpa);
    self.layer_passes.deinit(gpa);
    self.pieces.deinit(gpa);
    self.xprims.deinit(gpa);
    self.xclips.deinit(gpa);
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
fn vDestroyLayer(p: *anyopaque, id: r2d.LayerId) void {
    const self = cast(p);
    if (self.layers.remove(id)) |e| self.retireLayerTex(e.res);
}
fn vBackend(_: *anyopaque) r2d.Backend {
    return .vulkan;
}
fn vDeinit(p: *anyopaque) void {
    cast(p).destroy();
}
fn vLayerValid(p: *anyopaque, id: r2d.LayerId, size: Size) bool {
    const l = cast(p).layers.find(id) orelse return false;
    return l.valid and l.size.w == size.w and l.size.h == size.h;
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
    // Layer textures take slots too; their entries here stay null.
    while (slot >= self.textures.items.len) self.textures.append(self.gpa, null) catch return error.OutOfMemory;
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

// ------------------------------------------------------------- layers

/// The texture of layer `id`, created or recreated for `size` and `kind`
/// (a new texture is not valid).
fn ensureLayer(self: *VkRenderer, id: r2d.LayerId, size: Size, kind: r2d.LayerKind) !*LayerTable.Entry {
    if (size.w == 0 or size.h == 0 or size.w > Texture.max_side or size.h > Texture.max_side) return error.InvalidArgument;
    if (self.layers.find(id)) |l| {
        if (l.size.w == size.w and l.size.h == size.h and l.kind == kind) return l;
        // The sampler is fixed per slot, so a kind change recreates too.
        const t = try self.newLayerTex(size, kind);
        self.retireLayerTex(l.res);
        l.* = .{ .id = id, .size = size, .kind = kind, .last_used = self.frame_no, .res = t };
        return l;
    }
    const t = try self.newLayerTex(size, kind);
    errdefer self.retireLayerTex(t);
    return self.layers.put(self.gpa, .{ .id = id, .size = size, .kind = kind, .last_used = self.frame_no, .res = t });
}

fn newLayerTex(self: *VkRenderer, size: Size, kind: r2d.LayerKind) !*Texture {
    const t = try self.gpa.create(Texture);
    errdefer self.gpa.destroy(t);
    t.* = try Texture.create(&self.mem, size.w, size.h, self.readback.format, .render_target, "r2d-layer");
    errdefer t.destroy(&self.mem);
    t.slot = try self.heap.allocSlot(t.view, if (kind == .scroll) .linear_repeat else .linear_clamp);
    return t;
}

/// Destroys a layer texture once the frame being recorded retires.
fn retireLayerTex(self: *VkRenderer, t: *Texture) void {
    if (t.slot != std.math.maxInt(u32)) self.heap.freeSlot(t.slot, self.sched.submitted + 1);
    self.sched.deferDestroy(.{ .texture = t.* });
    self.gpa.destroy(t);
}

/// Plans this frame's layer passes: textures, pieces and translated
/// copies. Fills `layer_slots` for the composites.
fn planLayers(self: *VkRenderer, dl: *const DrawList) !void {
    const gpa = self.gpa;
    self.layer_passes.clearRetainingCapacity();
    self.pieces.clearRetainingCapacity();
    self.xprims.clearRetainingCapacity();
    self.xclips.clearRetainingCapacity();
    try self.layer_slots.resize(gpa, dl.layers.items.len);
    for (dl.layers.items, 0..) |lu, i| {
        self.layer_slots.items[i] = 0;
        self.layers.markUsed(lu.id, self.frame_no);
        if (!lu.drawn) {
            if (self.layers.find(lu.id)) |l| {
                if (l.valid) self.layer_slots.items[i] = l.res.slot;
            }
            continue;
        }
        const l = try self.ensureLayer(lu.id, lu.size, lu.kind);
        const full = [_]PxRect{.{ .x = 0, .y = 0, .w = lu.size.w, .h = lu.size.h }};
        const dmg = dl.layerDamage(lu);
        const fresh = !l.valid;
        const rep: []const PxRect = if (fresh or dmg.len == 0) &full else dmg;
        l.valid = true;
        const z: u16 = @intCast(i + 1);
        const start: u32 = @intCast(self.pieces.items.len);
        for (rep) |r| {
            var pcs: [4]wrap.Piece = undefined;
            const n = wrap.wrapRects(r, lu.origin, lu.size, &pcs);
            for (pcs[0..n]) |pc| {
                if (pc.offset[0] == 0 and pc.offset[1] == 0) {
                    try self.pieces.append(gpa, .{ .rect = pc.rect, .translated = false });
                    continue;
                }
                const first: u32 = @intCast(self.xprims.items.len);
                const clip_off: u32 = @intCast(self.xclips.items.len);
                try wrap.appendTranslated(gpa, dl.prims.items[lu.prim_start..lu.prim_end], z, dl.clips.items, pc, &self.xprims);
                try wrap.appendTranslatedClips(gpa, dl.clips.items, pc.offset, &self.xclips);
                try self.pieces.append(gpa, .{ .rect = pc.rect, .translated = true, .first = first, .count = @as(u32, @intCast(self.xprims.items.len)) - first, .clip_off = clip_off });
            }
        }
        try self.layer_passes.append(gpa, .{ .index = @intCast(i), .tex = l.res, .fresh = fresh, .pieces_start = start, .pieces_end = @intCast(self.pieces.items.len) });
        self.layer_slots.items[i] = l.res.slot;
    }
    // Least recently composited layers beyond the budget go (never one
    // used this frame).
    while (self.layers.evictOne(self.opts.layer_budget_bytes, self.frame_no)) |e| self.retireLayerTex(e.res);
}

fn pushConstants(self: *VkRenderer, cb: vk.CommandBuffer, size: Size, clip_base: u32) void {
    const pc: iface.PushConstants = .{
        .viewport_px = .{ @floatFromInt(size.w), @floatFromInt(size.h) },
        .inv_viewport = .{ 1.0 / @as(f32, @floatFromInt(size.w)), 1.0 / @as(f32, @floatFromInt(size.h)) },
        .clip_base = clip_base,
        .text_gamma = self.opts.text.gamma,
        .text_contrast = self.opts.text.contrast,
    };
    self.gpu.ddisp.cmd_push_constants(cb, self.heap.pipeline_layout, .{ .vertex = true, .fragment = true }, 0, @sizeOf(iface.PushConstants), &pc);
}

fn beginPass(self: *VkRenderer, cb: vk.CommandBuffer, view: vk.ImageView, size: Size, clear: bool) void {
    const d = &self.gpu.ddisp;
    const attach = [_]vk.RenderingAttachmentInfo{.{
        .image_view = view,
        .image_layout = .color_attachment_optimal,
        .resolve_image_layout = .undefined,
        .load_op = if (clear) .clear else .load,
        .store_op = .store,
        .clear_value = .{ .color = .{ .float32 = .{ 0, 0, 0, 0 } } },
    }};
    const area: vk.Rect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = size.w, .height = size.h } };
    d.cmd_begin_rendering(cb, &.{ .render_area = area, .layer_count = 1, .view_mask = 0, .color_attachment_count = 1, .p_color_attachments = &attach });
    const vp = [_]vk.Viewport{.{ .x = 0, .y = 0, .width = @floatFromInt(size.w), .height = @floatFromInt(size.h), .min_depth = 0, .max_depth = 1 }};
    d.cmd_set_viewport(cb, 0, 1, &vp);
}

/// Clears (unless the pass cleared on load) and scissors to `r`.
fn startRect(self: *VkRenderer, cb: vk.CommandBuffer, r: PxRect, clear: bool) void {
    const d = &self.gpu.ddisp;
    const sc = [_]vk.Rect2D{.{ .offset = .{ .x = r.x, .y = r.y }, .extent = .{ .width = r.w, .height = r.h } }};
    if (clear) {
        // Each repainted rect starts transparent, like the software renderer.
        const ca = [_]vk.ClearAttachment{.{ .aspect_mask = .{ .color = true }, .color_attachment = 0, .clear_value = .{ .color = .{ .float32 = .{ 0, 0, 0, 0 } } } }};
        const cr = [_]vk.ClearRect{.{ .rect = sc[0], .base_array_layer = 0, .layer_count = 1 }};
        d.cmd_clear_attachments(cb, 1, &ca, 1, &cr);
    }
    d.cmd_set_scissor(cb, 0, 1, &sc);
}

/// Draws `self.batches` with instances starting at `first_instance`.
fn drawBatches(self: *VkRenderer, cb: vk.CommandBuffer, first_instance: u32, bound: *?batch.Pipeline, stats: *r2d.FrameStats) void {
    const d = &self.gpu.ddisp;
    for (self.batches.items) |b| {
        if (bound.* != b.pipeline) {
            d.cmd_bind_pipeline(cb, .graphics, switch (b.pipeline) {
                .prim => self.pipes.prim,
                .text_subpixel => self.pipes.text_subpixel.?,
            });
            bound.* = b.pipeline;
        }
        d.cmd_draw(cb, 4, b.count, 0, first_instance + b.first);
        stats.draws += 1;
    }
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
    const layers_drawn = for (dl.layers.items) |l| {
        if (l.drawn) break true;
    } else false;
    if (!full_frame and dl.damage_len == 0 and !layers_drawn) {
        // Idle: nothing changed, nothing is submitted.
        self.readback.poll();
        return stats;
    }
    self.frame_no += 1;
    try self.planLayers(dl);

    const Prim = r2d.prim.Prim;
    const prim_bytes = dl.prims.items.len * @sizeOf(Prim);
    const xprim_bytes = self.xprims.items.len * @sizeOf(Prim);
    const clip_bytes = dl.clips.items.len * @sizeOf(iface.ClipGpu);
    const xclip_bytes = self.xclips.items.len * @sizeOf(iface.ClipGpu);
    try self.ensureRing(prim_bytes + xprim_bytes + clip_bytes + xclip_bytes + 4096);

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

    // Prims and clips (and the translated layer copies) into the ring.
    var first_instance: u32 = 0;
    var x_first_instance: u32 = 0;
    var clip_base: u32 = 0;
    var x_clip_base: u32 = 0;
    if (prim_bytes > 0) {
        const s = try self.ring.alloc(prim_bytes, @sizeOf(Prim));
        const out: []Prim = @alignCast(std.mem.bytesAsSlice(Prim, s.bytes()));
        @memcpy(out, dl.prims.items);
        // Composites sample their layer's texture slot.
        if (dl.layers.items.len != 0) for (dl.prims.items, 0..) |p, i| {
            if (p.kind == .layer and p.params < self.layer_slots.items.len) out[i].tex = @intCast(self.layer_slots.items[p.params]);
        };
        first_instance = @intCast(s.offset / @sizeOf(Prim));
    }
    if (xprim_bytes > 0) {
        const s = try self.ring.alloc(xprim_bytes, @sizeOf(Prim));
        @memcpy(s.bytes(), std.mem.sliceAsBytes(self.xprims.items));
        x_first_instance = @intCast(s.offset / @sizeOf(Prim));
    }
    inline for (.{ .{ clip_bytes, dl.clips.items, &clip_base }, .{ xclip_bytes, self.xclips.items, &x_clip_base } }) |c| {
        if (c[0] > 0) {
            const s = try self.ring.alloc(c[0], @sizeOf(iface.ClipGpu));
            const out: []iface.ClipGpu = @alignCast(std.mem.bytesAsSlice(iface.ClipGpu, s.bytes()));
            for (out, c[1]) |*o, src| o.* = .{ .bounds = src.bounds, .radii = src.radii };
            c[2].* = @intCast(s.offset / @sizeOf(iface.ClipGpu));
        }
    }

    const cb = fs.cb;
    const d = &self.gpu.ddisp;
    // The slot retired in `begin`: read its timestamps, then reuse them.
    var timer: ?*GpuTimer = null;
    if (self.timer) |*t| {
        if (t.collect(fs.index, self.io)) |g| self.last_gpu = g;
        t.begin(cb, fs.index);
        t.mark(cb, fs.index, .frame, .start);
        t.mark(cb, fs.index, .uploads, .start);
        timer = t;
    }
    self.initFresh(cb);
    try self.uploader.record(cb, d);
    for (self.uploader.staging.items) |b| self.sched.deferDestroy(.{ .buffer = b });
    self.uploader.staging.clearRetainingCapacity();
    try self.ring.endFrame(cb, d);
    if (timer) |t| t.mark(cb, fs.index, .uploads, .end);
    self.heap.bind(cb);
    const dual_src = self.pipes.text_subpixel != null;
    var bound: ?batch.Pipeline = null;

    // Layer passes.
    if (timer) |t| if (self.layer_passes.items.len != 0) t.mark(cb, fs.index, .layers, .start);
    for (self.layer_passes.items) |lp| {
        const lu = dl.layers.items[lp.index];
        const tex = lp.tex;
        barriers.imageTransition(cb, d, tex.image.handle, if (lp.fresh) .undefined else tex.access, .color_attachment, .{ .color = true });
        tex.access = .color_attachment;
        self.beginPass(cb, tex.view, lu.size, lp.fresh);
        const z: u16 = lp.index + 1;
        for (self.pieces.items[lp.pieces_start..lp.pieces_end]) |pc| {
            self.batches.clearRetainingCapacity();
            if (pc.translated) {
                self.pushConstants(cb, lu.size, x_clip_base + pc.clip_off);
                const clips = self.xclips.items[pc.clip_off..][0..dl.clips.items.len];
                try batch.buildBatches(self.gpa, self.xprims.items[pc.first..][0..pc.count], clips, .{ .z = z, .base = pc.first }, pc.rect, dual_src, &self.batches);
            } else {
                self.pushConstants(cb, lu.size, clip_base);
                try batch.buildBatches(self.gpa, dl.prims.items[lu.prim_start..lu.prim_end], dl.clips.items, .{ .z = z, .base = lu.prim_start }, pc.rect, dual_src, &self.batches);
            }
            self.startRect(cb, pc.rect, !lp.fresh);
            self.drawBatches(cb, if (pc.translated) x_first_instance else first_instance, &bound, &stats);
            stats.repainted_px += r2d_rect.area(pc.rect);
        }
        d.cmd_end_rendering(cb);
        barriers.imageTransition(cb, d, tex.image.handle, .color_attachment, .shader_read, .{ .color = true });
        tex.access = .shader_read;
    }

    if (timer) |t| if (self.layer_passes.items.len != 0) t.mark(cb, fs.index, .layers, .end);

    // The window pass.
    if (repaint.slice().len != 0) {
        if (timer) |t| t.mark(cb, fs.index, .main, .start);
        defer if (timer) |t| t.mark(cb, fs.index, .main, .end);
        const img = acq.image;
        barriers.imageTransition(cb, d, img.image.handle, if (acq.age == 0) .undefined else img.access, .color_attachment, .{ .color = true });
        img.access = .color_attachment;
        self.beginPass(cb, img.view, extent, full_repaint);
        self.pushConstants(cb, extent, clip_base);
        for (repaint.slice()) |r| {
            self.startRect(cb, r, !full_repaint);
            self.batches.clearRetainingCapacity();
            try batch.buildBatches(self.gpa, dl.prims.items, dl.clips.items, .{ .layer_slots = self.layer_slots.items }, if (full_repaint) null else r, dual_src, &self.batches);
            self.drawBatches(cb, first_instance, &bound, &stats);
            stats.repainted_px += r2d_rect.area(r);
        }
        d.cmd_end_rendering(cb);
    }

    try self.readback.recordCopy(fs, repaint.slice());
    if (timer) |t| t.mark(cb, fs.index, .frame, .end);
    self.retireDoomed();
    try self.sched.submit(fs, &.{}, &.{});
    self.readback.present(fs);
    if (full_frame) self.history.pushFull() else self.history.push(dl.damageRects());
    self.needs_full = false;
    stats.needs_full_redraw = full_repaint;
    stats.present_id = fs.timeline_value;
    if (self.last_gpu) |g| stats.gpu_ns = g.frame_ns;
    stats.cpu_encode_ns = @intCast(zg_core.time.nowNs(self.io) - start);
    return stats;
}
