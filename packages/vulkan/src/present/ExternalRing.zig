//! The ExternalRing target (E02.F04.S02.T01): up to three exportable
//! dmabuf images, rendered in place and handed to E01's `Presenter`
//! (Wayland `zwp_linux_dmabuf_v1`, X11 DRI3/Present). Zero copy: the
//! frame's only transfer commands are uploads.
//!
//! - Modifiers: the compositor's list for our fourcc, intersected with the
//!   single-plane modifiers the device renders to and can export
//!   (`drm_formats.negotiate`). An empty intersection, or a device without
//!   `VK_EXT_image_drm_format_modifier` / dmabuf export, is
//!   `error.ExportUnsupported`: the caller falls back to `Readback` with
//!   the shm sink.
//! - Ownership: after the window pass the image is released to
//!   `VK_QUEUE_FAMILY_FOREIGN_EXT` (EXTERNAL without that extension) in
//!   `GENERAL` layout, the layout dmabuf consumers expect (Mesa's WSI does
//!   the same); a reused image is acquired back from FOREIGN, an image
//!   whose contents are discarded (age 0) just leaves UNDEFINED.
//! - Sync: with `implicit_sync_file` (or `drm_syncobj`, which E01 does
//!   not accept yet) and an exportable SYNC_FD semaphore, each frame slot
//!   signals a binary semaphore whose sync_file goes to `present`
//!   (exporting resets it, so it is reused). Otherwise the render thread
//!   waits for the frame on the CPU and presents with `.none`.
//! - Buffers: `pollReleased` frees held images; with none free,
//!   `acquire` returns `error.NoFreeBuffer` and the frame is skipped (the
//!   caller retries after the next frame signal, never spins). A resize
//!   reallocates lazily.

const ExternalRing = @This();

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("zg_platform");
const vk = @import("../vk/vk.zig");
const Gpu = @import("../gpu/Gpu.zig");
const DeviceMemory = @import("../mem/DeviceMemory.zig");
const Texture = @import("../mem/Texture.zig");
const barriers = @import("../mem/barriers.zig");
const FrameScheduler = @import("FrameScheduler.zig");
const drm = @import("drm_formats.zig");
const rect = @import("../r2d/rect.zig");

const surface = platform.surface;
const PxRect = rect.PxRect;
const Size = rect.Size;

pub const ring_len = 3;
const max_modifiers = 32;

pub const InitError = error{ ExportUnsupported, OutOfDeviceMemory, OutOfHostMemory, DeviceLost };
pub const AcquireError = error{ NoFreeBuffer, OutOfDeviceMemory, OutOfHostMemory, DeviceLost, PresentFailed };

/// How a frame's completion reaches the presenter.
pub const Sync = enum { sync_file, cpu_wait };

/// Which ring image a frame renders into. Pure bookkeeping, shared by the
/// Vulkan code and the tests.
pub const Book = struct {
    pub const State = enum { empty, free, rendering, held };
    pub const Pick = union(enum) {
        /// Reuse image `index`, `age` frames old (0 = contents unknown).
        reuse: struct { index: u8, age: u32 },
        /// Create image `index`.
        create: u8,
        /// Every image is held by the presenter.
        none,
    };

    state: [ring_len]State = @splat(.empty),
    handles: [ring_len]surface.BufferHandle = undefined,
    /// The frame each image last showed (0 = never).
    rendered: [ring_len]u64 = @splat(0),
    /// Frames presented so far.
    frame: u64 = 0,

    /// A free image, the most recently rendered first; else an empty
    /// slot to fill.
    pub fn pick(self: *const Book) Pick {
        var best: ?u8 = null;
        for (self.state, 0..) |s, i| {
            if (s == .free and (best == null or self.rendered[i] > self.rendered[best.?])) best = @intCast(i);
        }
        if (best) |b| return .{ .reuse = .{ .index = b, .age = self.ageOf(b) } };
        for (self.state, 0..) |s, i| if (s == .empty) return .{ .create = @intCast(i) };
        return .none;
    }

    pub fn ageOf(self: *const Book, i: u8) u32 {
        if (self.rendered[i] == 0) return 0;
        return @intCast(@min(self.frame + 1 - self.rendered[i], std.math.maxInt(u32)));
    }

    /// Image `i` was created and registered as `h`.
    pub fn added(self: *Book, i: u8, h: surface.BufferHandle) void {
        self.state[i] = .free;
        self.handles[i] = h;
        self.rendered[i] = 0;
    }

    pub fn begin(self: *Book, i: u8) void {
        std.debug.assert(self.state[i] == .free);
        self.state[i] = .rendering;
    }

    /// Image `i` went to the presenter.
    pub fn presented(self: *Book, i: u8) void {
        std.debug.assert(self.state[i] == .rendering);
        self.frame += 1;
        self.rendered[i] = self.frame;
        self.state[i] = .held;
    }

    /// Image `i` was acquired but not presented: free, contents unknown.
    pub fn abandoned(self: *Book, i: u8) void {
        self.state[i] = .free;
        self.rendered[i] = 0;
    }

    /// Image `i` was acquired but left untouched: free, contents kept.
    pub fn cancelled(self: *Book, i: u8) void {
        std.debug.assert(self.state[i] == .rendering);
        self.state[i] = .free;
    }

    /// The presenter returned `h`.
    pub fn released(self: *Book, h: surface.BufferHandle) void {
        for (&self.state, self.handles) |*s, x| {
            if (s.* == .held and x == h) s.* = .free;
        }
    }

    /// Forgets image `i`.
    pub fn removed(self: *Book, i: u8) void {
        self.state[i] = .empty;
        self.rendered[i] = 0;
    }
};

const RingImage = struct {
    tex: Texture,
    fd: i32,
    modifier: u64,
    handle: surface.BufferHandle,
};

pub const Acquired = struct { image: *Texture, age: u32, index: u8 };

gpu: *Gpu,
mem: *DeviceMemory,
sched: *FrameScheduler,
presenter: *surface.Presenter,
format: Texture.Format = .bgra8_unorm,
fourcc: u32 = drm.argb8888,
modifiers: [max_modifiers]u64 = undefined,
n_modifiers: usize = 0,
sync: Sync,
/// Binary SYNC_FD semaphores, one per frame slot (`.sync_file` only).
semaphores: [FrameScheduler.max_frames_in_flight]vk.Semaphore = @splat(.null_handle),
foreign_family: u32,
images: [ring_len]?RingImage = @splat(null),
book: Book = .{},
extent: Size = .{ .w = 0, .h = 0 },
/// The configure to acknowledge with the next present.
ack: ?surface.ConfigureAck = null,

/// A ring for `presenter`, or `error.ExportUnsupported` when the device
/// and the compositor have no dmabuf path in common.
pub fn init(gpu: *Gpu, mem: *DeviceMemory, sched: *FrameScheduler, presenter: *surface.Presenter) InitError!ExternalRing {
    const caps = gpu.info.caps;
    if (!caps.dmabuf_export or !caps.drm_modifier) return error.ExportUnsupported;
    const mode = presenter.syncMode();
    if (mode == .cpu_only) return error.ExportUnsupported;
    var self: ExternalRing = .{
        .gpu = gpu,
        .mem = mem,
        .sched = sched,
        .presenter = presenter,
        .sync = .cpu_wait,
        .foreign_family = if (gpu.exts.contains(.ext_queue_family_foreign)) vk.queue_family_foreign_ext else vk.queue_family_external,
    };
    var comp: [256]surface.FormatModifier = undefined;
    const n_comp = presenter.formats(&comp);
    var dev: [max_modifiers]drm.DeviceModifier = undefined;
    const n_dev = self.deviceModifiers(&dev);
    self.n_modifiers = drm.negotiate(self.fourcc, comp[0..n_comp], dev[0..n_dev], &self.modifiers);
    if (self.n_modifiers == 0) return error.ExportUnsupported;

    if ((mode == .implicit_sync_file or mode == .drm_syncobj) and caps.sync_fd_export and self.syncFdExportable()) {
        self.sync = .sync_file;
        const d = &gpu.ddisp;
        const exp: vk.ExportSemaphoreCreateInfo = .{ .handle_types = .{ .sync_fd = true } };
        for (&self.semaphores) |*s| {
            _ = vk.check(d.create_semaphore(gpu.dev, &.{ .p_next = &exp }, null, s)) catch |e| {
                self.destroySemaphores();
                return mapInit(e);
            };
            gpu.name(s.*, "external-ring-sync");
        }
    }
    return self;
}

/// Releases every image. The GPU must be idle.
pub fn deinit(self: *ExternalRing) void {
    for (&self.images, 0..) |*img, i| if (img.*) |*ri| {
        self.dropImage(@intCast(i), ri, false);
        img.* = null;
    };
    self.destroySemaphores();
    self.* = undefined;
}

pub fn vkFormat(self: *const ExternalRing) vk.Format {
    return self.format.vkFormat();
}

/// The image for this frame at `extent`, (re)allocating on a size
/// change; `error.NoFreeBuffer` when the presenter holds them all.
pub fn acquire(self: *ExternalRing, extent: Size) AcquireError!Acquired {
    self.reclaim();
    if (extent.w != self.extent.w or extent.h != self.extent.h) {
        for (&self.images, 0..) |*img, i| if (img.*) |*ri| {
            self.dropImage(@intCast(i), ri, true);
            img.* = null;
        };
        self.extent = extent;
    }
    const index, const age = switch (self.book.pick()) {
        .reuse => |r| .{ r.index, r.age },
        .create => |i| blk: {
            self.images[i] = try self.createImage(extent);
            self.book.added(i, self.images[i].?.handle);
            break :blk .{ i, 0 };
        },
        .none => return error.NoFreeBuffer,
    };
    self.book.begin(index);
    return .{ .image = &self.images[index].?.tex, .age = age, .index = index };
}

/// Records the transition into COLOR_ATTACHMENT for the window pass:
/// from UNDEFINED for age 0, else an acquire from the foreign family.
pub fn beginRendering(self: *ExternalRing, cb: vk.CommandBuffer, a: Acquired) void {
    const img = a.image;
    var b = barriers.imageBarrier(img.image.handle, if (a.age == 0) .undefined else .external_foreign, .color_attachment, .{ .color = true });
    if (a.age != 0) {
        b.src_queue_family_index = self.foreign_family;
        b.dst_queue_family_index = self.gpu.gfx.family;
        b.src_stage_mask = .{};
        b.src_access_mask = .{};
    }
    barriers.pipelineBarrier(cb, &self.gpu.ddisp, &.{b}, &.{});
    img.access = .color_attachment;
}

/// Records the release to the foreign family after the window pass.
pub fn endRendering(self: *ExternalRing, cb: vk.CommandBuffer, a: Acquired) void {
    const img = a.image;
    var b = barriers.imageBarrier(img.image.handle, .color_attachment, .external_foreign, .{ .color = true });
    b.src_queue_family_index = self.gpu.gfx.family;
    b.dst_queue_family_index = self.foreign_family;
    b.dst_stage_mask = .{};
    b.dst_access_mask = .{};
    barriers.pipelineBarrier(cb, &self.gpu.ddisp, &.{b}, &.{});
    img.access = .external_foreign;
}

/// The extra signal for `fs`'s submit (`.sync_file` only).
pub fn signalFor(self: *const ExternalRing, fs: *const FrameScheduler.FrameSlot) ?vk.SemaphoreSubmitInfo {
    if (self.sync != .sync_file) return null;
    return .{ .semaphore = self.semaphores[fs.index], .value = 0, .stage_mask = .{ .all_commands = true }, .device_index = 0 };
}

/// Hands image `a` to the presenter after `fs` was submitted. `damage`
/// lists the frame's changed rects (empty = everything).
pub fn present(self: *ExternalRing, fs: *const FrameScheduler.FrameSlot, a: Acquired, damage: []const PxRect) AcquireError!void {
    const ri = &self.images[a.index].?;
    var sp: surface.SyncPoint = .none;
    switch (self.sync) {
        .sync_file => {
            var fd: c_int = -1;
            const r = self.gpu.ddisp.get_semaphore_fd_khr(self.gpu.dev, &.{ .semaphore = self.semaphores[fs.index], .handle_type = .{ .sync_fd = true } }, &fd);
            if (r != .success) {
                // Could not export: wait on the CPU instead.
                self.sched.waitValue(fs.timeline_value) catch {};
            } else sp = .{ .sync_file = fd };
        },
        .cpu_wait => self.sched.waitValue(fs.timeline_value) catch {},
    }
    // E01 takes ownership of the sync_file fd, also on failure.
    self.presenter.present(ri.handle, damage, sp, self.ack) catch {
        self.book.abandoned(a.index);
        return error.PresentFailed;
    };
    self.ack = null;
    self.book.presented(a.index);
}

/// Frees image `a` acquired for a frame that was not presented.
pub fn abandon(self: *ExternalRing, a: Acquired) void {
    self.book.abandoned(a.index);
}

/// Returns image `a` unused (nothing was recorded into it).
pub fn cancel(self: *ExternalRing, a: Acquired) void {
    self.book.cancelled(a.index);
}

/// The compositor's formats changed: reallocate at the next acquire.
pub fn onFeedbackChanged(self: *ExternalRing) void {
    var comp: [256]surface.FormatModifier = undefined;
    const n_comp = self.presenter.formats(&comp);
    var dev: [max_modifiers]drm.DeviceModifier = undefined;
    const n_dev = self.deviceModifiers(&dev);
    const n = drm.negotiate(self.fourcc, comp[0..n_comp], dev[0..n_dev], &self.modifiers);
    if (n != 0) self.n_modifiers = n;
    self.extent = .{ .w = 0, .h = 0 };
}

fn reclaim(self: *ExternalRing) void {
    var released: [8]surface.BufferHandle = undefined;
    while (true) {
        const n = self.presenter.pollReleased(&released);
        for (released[0..n]) |h| self.book.released(h);
        if (n < released.len) break;
    }
}

fn dropImage(self: *ExternalRing, i: u8, ri: *RingImage, deferred: bool) void {
    self.presenter.releaseBuffer(ri.handle);
    closeFd(ri.fd);
    if (deferred) self.sched.deferDestroy(.{ .texture = ri.tex }) else ri.tex.destroy(self.mem);
    self.book.removed(i);
}

fn createImage(self: *ExternalRing, extent: Size) AcquireError!RingImage {
    const gpu = self.gpu;
    const d = &gpu.ddisp;
    var list: vk.ImageDrmFormatModifierListCreateInfoEXT = .{ .drm_format_modifier_count = @intCast(self.n_modifiers), .p_drm_format_modifiers = &self.modifiers };
    var ci: vk.ImageCreateInfo = .{
        .image_type = .@"2d",
        .format = self.format.vkFormat(),
        .extent = .{ .width = extent.w, .height = extent.h, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1" = true },
        .tiling = .drm_format_modifier_ext,
        .usage = .{ .color_attachment = true, .transfer_src = true, .transfer_dst = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    };
    vk.chain(&ci, &list);
    const img = self.mem.createImage(ci, .gpu_only, "external-ring", true) catch |e| return mapAcq(e);
    errdefer self.mem.destroyImage(img);
    var view: vk.ImageView = .null_handle;
    _ = vk.check(d.create_image_view(gpu.dev, &.{
        .image = img.handle,
        .view_type = .@"2d",
        .format = self.format.viewFormat(),
        .components = self.format.swizzle(),
        .subresource_range = barriers.color_range,
    }, null, &view)) catch |e| return mapAcq(e);
    var tex: Texture = .{ .image = img, .view = view, .format = self.format, .width = extent.w, .height = extent.h };
    errdefer d.destroy_image_view(gpu.dev, view, null);

    var mp: vk.ImageDrmFormatModifierPropertiesEXT = .{};
    _ = vk.check(d.get_image_drm_format_modifier_properties_ext(gpu.dev, img.handle, &mp)) catch |e| return mapAcq(e);
    var layout: vk.SubresourceLayout = undefined;
    d.get_image_subresource_layout(gpu.dev, img.handle, &.{ .aspect_mask = .{ .memory_plane_0_ext = true }, .mip_level = 0, .array_layer = 0 }, &layout);
    var fd: c_int = -1;
    _ = vk.check(d.get_memory_fd_khr(gpu.dev, &.{ .memory = img.alloc.memory, .handle_type = .{ .dma_buf_ext = true } }, &fd)) catch |e| return mapAcq(e);
    errdefer closeFd(fd);
    const planes = [_]surface.Plane{.{ .fd = fd, .offset = @intCast(layout.offset), .stride = @intCast(layout.row_pitch) }};
    const desc: surface.BufferDesc = .{ .width = extent.w, .height = extent.h, .fourcc = self.fourcc, .modifier = mp.drm_format_modifier, .planes = &planes, .kind = .dmabuf };
    const h = self.presenter.importBuffer(&desc) catch return error.PresentFailed;
    tex.access = .undefined;
    return .{ .tex = tex, .fd = fd, .modifier = mp.drm_format_modifier, .handle = h };
}

/// The device's modifiers for our format, with exportability checked.
fn deviceModifiers(self: *ExternalRing, out: []drm.DeviceModifier) usize {
    const gpu = self.gpu;
    const idisp = &gpu.instance.disp;
    var props: [max_modifiers]vk.DrmFormatModifierProperties2EXT = undefined;
    var list: vk.DrmFormatModifierPropertiesList2EXT = .{};
    var fp: vk.FormatProperties2 = .{};
    vk.chain(&fp, &list);
    idisp.get_physical_device_format_properties2(gpu.pdev, self.format.vkFormat(), &fp);
    list.drm_format_modifier_count = @min(list.drm_format_modifier_count, max_modifiers);
    list.p_drm_format_modifier_properties = &props;
    idisp.get_physical_device_format_properties2(gpu.pdev, self.format.vkFormat(), &fp);
    const n = @min(list.drm_format_modifier_count, out.len);
    for (props[0..n], out[0..n]) |p, *o| {
        o.* = .{
            .modifier = p.drm_format_modifier,
            .planes = p.drm_format_modifier_plane_count,
            .color_attachment = p.drm_format_modifier_tiling_features.color_attachment,
            .exportable = self.modifierExportable(p.drm_format_modifier),
        };
    }
    return n;
}

fn modifierExportable(self: *ExternalRing, modifier: u64) bool {
    const gpu = self.gpu;
    var mi: vk.PhysicalDeviceImageDrmFormatModifierInfoEXT = .{ .drm_format_modifier = modifier, .sharing_mode = .exclusive };
    var ei: vk.PhysicalDeviceExternalImageFormatInfo = .{ .handle_type = .{ .dma_buf_ext = true } };
    var info: vk.PhysicalDeviceImageFormatInfo2 = .{
        .format = self.format.vkFormat(),
        .type = .@"2d",
        .tiling = .drm_format_modifier_ext,
        .usage = .{ .color_attachment = true, .transfer_src = true, .transfer_dst = true },
    };
    vk.chain(&info, &mi);
    vk.chain(&info, &ei);
    var ep: vk.ExternalImageFormatProperties = .{};
    var ip: vk.ImageFormatProperties2 = .{};
    vk.chain(&ip, &ep);
    if (gpu.instance.disp.get_physical_device_image_format_properties2(gpu.pdev, &info, &ip) != .success) return false;
    return ep.external_memory_properties.external_memory_features.exportable;
}

fn syncFdExportable(self: *ExternalRing) bool {
    var p: vk.ExternalSemaphoreProperties = .{};
    self.gpu.instance.disp.get_physical_device_external_semaphore_properties(self.gpu.pdev, &.{ .handle_type = .{ .sync_fd = true } }, &p);
    return p.external_semaphore_features.exportable;
}

fn destroySemaphores(self: *ExternalRing) void {
    for (&self.semaphores) |*s| if (s.* != .null_handle) {
        self.gpu.ddisp.destroy_semaphore(self.gpu.dev, s.*, null);
        s.* = .null_handle;
    };
}

fn closeFd(fd: i32) void {
    if (fd < 0) return;
    if (comptime builtin.os.tag == .linux) _ = std.os.linux.close(fd);
}

fn mapInit(e: anyerror) InitError {
    return switch (e) {
        error.OutOfDeviceMemory => error.OutOfDeviceMemory,
        error.DeviceLost => error.DeviceLost,
        else => error.OutOfHostMemory,
    };
}

fn mapAcq(e: anyerror) AcquireError {
    return switch (e) {
        error.OutOfDeviceMemory => error.OutOfDeviceMemory,
        error.DeviceLost => error.DeviceLost,
        else => error.OutOfHostMemory,
    };
}

const testing = std.testing;

test "external: release/age bookkeeping" {
    var b: Book = .{};
    // Empty ring: images are created in order.
    try testing.expectEqual(Book.Pick{ .create = 0 }, b.pick());
    b.added(0, @enumFromInt(10));
    try testing.expectEqual(Book.Pick{ .reuse = .{ .index = 0, .age = 0 } }, b.pick());
    b.begin(0);
    b.presented(0); // frame 1 on image 0, held
    try testing.expectEqual(Book.Pick{ .create = 1 }, b.pick());
    b.added(1, @enumFromInt(11));
    b.begin(1);
    b.presented(1); // frame 2 on image 1
    // Image 0 comes back: it shows frame 1, so it is 2 frames old.
    b.released(@enumFromInt(10));
    try testing.expectEqual(Book.Pick{ .reuse = .{ .index = 0, .age = 2 } }, b.pick());
    b.begin(0);
    b.presented(0); // frame 3
    b.released(@enumFromInt(11));
    try testing.expectEqual(Book.Pick{ .reuse = .{ .index = 1, .age = 2 } }, b.pick());
    // Releasing a buffer that is not ours changes nothing.
    b.released(@enumFromInt(99));
    try testing.expectEqual(Book.State.held, b.state[0]);
    // A cancelled acquire keeps the contents (and age).
    b.begin(1);
    b.cancelled(1);
    try testing.expectEqual(Book.Pick{ .reuse = .{ .index = 1, .age = 2 } }, b.pick());
    // An abandoned frame leaves the image free with unknown contents.
    b.begin(1);
    b.abandoned(1);
    try testing.expectEqual(Book.Pick{ .reuse = .{ .index = 1, .age = 0 } }, b.pick());
    b.removed(1);
    try testing.expectEqual(Book.Pick{ .create = 1 }, b.pick());
}

test "external: no free buffer -> NoFreeBuffer, never spins" {
    var b: Book = .{};
    for (0..ring_len) |i| {
        try testing.expectEqual(Book.Pick{ .create = @intCast(i) }, b.pick());
        b.added(@intCast(i), @enumFromInt(i));
        b.begin(@intCast(i));
        b.presented(@intCast(i));
    }
    // All held: `pick` answers at once, every time.
    for (0..1000) |_| try testing.expectEqual(Book.Pick.none, b.pick());
    b.released(@enumFromInt(1));
    // Image 1 shows frame 2 of 3.
    try testing.expectEqual(Book.Pick{ .reuse = .{ .index = 1, .age = 2 } }, b.pick());
    // The most recently rendered free image wins (smallest age).
    b.released(@enumFromInt(2));
    try testing.expectEqual(Book.Pick{ .reuse = .{ .index = 2, .age = 1 } }, b.pick());
}
