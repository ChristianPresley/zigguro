//! The Win32 swapchain target (E02.F04.S01.T01): a `VK_KHR_win32_surface`
//! swapchain for `SurfaceTarget.win32`.
//!
//! - Format, present mode, image count and alpha come from
//!   `swapchain_choice.zig`. With swapchain maintenance1 every compatible
//!   present mode is declared at creation, so `PresentExt.mode_override`
//!   switches modes without a recreate.
//! - Semaphores: acquire semaphores per frame slot, present semaphores per
//!   swapchain image (the Vulkan Guide's reuse rule), recreated with the
//!   swapchain.
//! - Recreate (resize, OUT_OF_DATE, SUBOPTIMAL) is lazy, at the next
//!   acquire, with `oldSwapchain`. With maintenance1 each present carries a
//!   fence from a pool and a retired swapchain is destroyed once the
//!   fences of its presents have signalled; without it the render thread
//!   waits for the queue to idle first (the documented fallback).
//! - A 0×0 surface (minimised) is `error.Minimized`: no frame until E01
//!   sends a non-zero configure.
//! - Images keep their contents between presents, so `Acquired.age`
//!   feeds buffer-age repaint; the frame moves an image from UNDEFINED
//!   (age 0) or PRESENT_SRC to COLOR_ATTACHMENT and back to PRESENT_SRC.
//! - `presentWaiter` installs `vkWaitForPresent2KHR` / `vkWaitForPresentKHR`
//!   in the FramePacer.

const Swapchain = @This();

const std = @import("std");
const vk = @import("../vk/vk.zig");
const Gpu = @import("../gpu/Gpu.zig");
const Texture = @import("../mem/Texture.zig");
const types = @import("../mem/types.zig");
const barriers = @import("../mem/barriers.zig");
const FrameScheduler = @import("FrameScheduler.zig");
const FramePacer = @import("FramePacer.zig");
const choice = @import("swapchain_choice.zig");

const log = std.log.scoped(.zg_vulkan);

pub const PresentPrefs = choice.PresentPrefs;
pub const max_images = choice.Ages.max_images;

pub const AcquireError = error{ Minimized, SurfaceLost, DeviceLost, OutOfHostMemory, OutOfDeviceMemory, NoSurfaceFormat };
pub const PresentError = error{ SurfaceLost, DeviceLost, OutOfHostMemory, OutOfDeviceMemory };

/// Per-present extras.
pub const PresentExt = struct {
    /// From `FramePacer.nextPresentId` (present_id / present_id2 only).
    present_id: ?u64 = null,
    /// Changed rects (incremental_present only).
    regions: ?[]const vk.RectLayerKHR = null,
    /// Switch the present mode (maintenance1, a declared compatible mode).
    mode_override: ?vk.PresentModeKHR = null,
};

pub const Acquired = struct { image: *Texture, age: u32, index: u32 };

/// A swapchain waiting for its presents to finish before destruction.
const Retired = struct {
    handle: vk.SwapchainKHR,
    views: [max_images]vk.ImageView,
    sems: [max_images]vk.Semaphore,
    count: u32,
};

/// A present fence in flight and the swapchain it presented.
const Inflight = struct { fence: vk.Fence, swapchain: vk.SwapchainKHR };

gpu: *Gpu,
sched: *FrameScheduler,
gpa: std.mem.Allocator,
hinstance: *anyopaque,
hwnd: *anyopaque,
prefs: PresentPrefs,
surface: vk.SurfaceKHR = .null_handle,
handle: vk.SwapchainKHR = .null_handle,
format: Texture.Format = .bgra8_unorm,
color_space: vk.ColorSpaceKHR = .srgb_nonlinear,
extent: vk.Extent2D = .{ .width = 0, .height = 0 },
want: vk.Extent2D,
mode: vk.PresentModeKHR = .fifo,
/// Modes declared at creation (switchable without recreate).
modes: [8]vk.PresentModeKHR = undefined,
n_modes: u32 = 0,
images: [max_images]Texture = undefined,
count: u32 = 0,
present_sems: [max_images]vk.Semaphore = @splat(.null_handle),
acquire_sems: [FrameScheduler.max_frames_in_flight]vk.Semaphore = @splat(.null_handle),
ages: choice.Ages = .{},
needs_recreate: bool = true,
surface_lost: bool = false,
retired: std.ArrayList(Retired) = .empty,
inflight: std.ArrayList(Inflight) = .empty,
free_fences: std.ArrayList(vk.Fence) = .empty,
/// Swapchains created (tests and the trace).
recreates: u32 = 0,

/// A swapchain for the window; the first acquire creates it.
pub fn init(gpu: *Gpu, sched: *FrameScheduler, hinstance: *anyopaque, hwnd: *anyopaque, extent: vk.Extent2D, prefs: PresentPrefs) !*Swapchain {
    const gpa = gpu.gpa;
    const self = try gpa.create(Swapchain);
    errdefer gpa.destroy(self);
    self.* = .{ .gpu = gpu, .sched = sched, .gpa = gpa, .hinstance = hinstance, .hwnd = hwnd, .prefs = prefs, .want = extent };
    try self.createSurface();
    errdefer gpu.instance.disp.destroy_surface_khr(gpu.instance.inst, self.surface, null);
    const sf = try self.pickFormat();
    self.format = if (sf.format == .r8g8b8a8_unorm) .rgba8_unorm else .bgra8_unorm;
    self.color_space = sf.color_space;
    const d = &gpu.ddisp;
    for (&self.acquire_sems) |*s| _ = try vk.check(d.create_semaphore(gpu.dev, &.{}, null, s));
    return self;
}

/// Waits for every present, then destroys everything.
pub fn deinit(self: *Swapchain) void {
    const gpu = self.gpu;
    const d = &gpu.ddisp;
    self.sched.waitValue(self.sched.submitted) catch {};
    for (self.inflight.items) |f| _ = d.wait_for_fences(gpu.dev, 1, @ptrCast(&f.fence), .true, std.time.ns_per_s);
    self.queueWaitIdle();
    for (self.inflight.items) |f| d.destroy_fence(gpu.dev, f.fence, null);
    for (self.free_fences.items) |f| d.destroy_fence(gpu.dev, f, null);
    for (self.retired.items) |r| self.destroyRetired(r);
    if (self.handle != .null_handle) self.destroyRetired(self.current());
    for (self.acquire_sems) |s| if (s != .null_handle) d.destroy_semaphore(gpu.dev, s, null);
    gpu.instance.disp.destroy_surface_khr(gpu.instance.inst, self.surface, null);
    self.inflight.deinit(self.gpa);
    self.free_fences.deinit(self.gpa);
    self.retired.deinit(self.gpa);
    self.gpa.destroy(self);
}

pub fn vkFormat(self: *const Swapchain) vk.Format {
    return self.format.vkFormat();
}

/// The window was resized: recreate at the next acquire.
pub fn requestResize(self: *Swapchain, extent: vk.Extent2D) void {
    if (extent.width != self.want.width or extent.height != self.want.height) {
        self.want = extent;
        self.needs_recreate = true;
    }
}

/// The semaphore `fs`'s submit waits on (the acquire).
pub fn acquireSemaphore(self: *const Swapchain, fs: *const FrameScheduler.FrameSlot) vk.Semaphore {
    return self.acquire_sems[fs.index];
}

/// The semaphore the frame presenting `image_index` signals.
pub fn presentSemaphore(self: *const Swapchain, image_index: u32) vk.Semaphore {
    return self.present_sems[image_index];
}

/// Recycles finished presents and (re)creates the swapchain if needed;
/// `error.Minimized` while the window is 0×0. Call before beginning a
/// frame so a minimised window costs no frame slot.
pub fn prepare(self: *Swapchain) AcquireError!void {
    self.collect();
    if (self.surface_lost) try self.recreateSurface();
    if (self.needs_recreate or self.handle == .null_handle) try self.recreate();
}

/// The next image for frame slot `fs` (the scheduler has begun it).
pub fn acquire(self: *Swapchain, fs: *const FrameScheduler.FrameSlot) AcquireError!Acquired {
    self.collect();
    if (self.surface_lost) try self.recreateSurface();
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        if (self.needs_recreate or self.handle == .null_handle) try self.recreate();
        var index: u32 = 0;
        const r = self.gpu.ddisp.acquire_next_image_khr(self.gpu.dev, self.handle, std.math.maxInt(u64), self.acquire_sems[fs.index], .null_handle, &index);
        switch (r) {
            .success => {},
            .suboptimal_khr => self.needs_recreate = true, // present this one, recreate next
            .error_out_of_date_khr => {
                self.needs_recreate = true;
                if (tries == 0) continue;
                return error.Minimized;
            },
            .error_surface_lost_khr => {
                self.surface_lost = true;
                return error.SurfaceLost;
            },
            else => {
                try self.gpu.checkLost(r);
                _ = vk.check(r) catch |e| return mapErr(e);
            },
        }
        const img = &self.images[index];
        return .{ .image = img, .age = self.ages.age(index), .index = index };
    }
}

/// Records COLOR_ATTACHMENT for the window pass: from UNDEFINED (age 0)
/// or PRESENT_SRC (contents kept).
pub fn beginRendering(self: *Swapchain, cb: vk.CommandBuffer, a: Acquired) void {
    barriers.imageTransition(cb, &self.gpu.ddisp, a.image.image.handle, if (a.age == 0) .undefined else .present, .color_attachment, .{ .color = true });
    a.image.access = .color_attachment;
}

/// Records PRESENT_SRC after the window pass (or after nothing, for a
/// frame that only redrew layers).
pub fn endRendering(self: *Swapchain, cb: vk.CommandBuffer, a: Acquired) void {
    const from: barriers.Access = if (a.image.access == .color_attachment) .color_attachment else if (a.age == 0) .undefined else .present;
    barriers.imageTransition(cb, &self.gpu.ddisp, a.image.image.handle, from, .present, .{ .color = true });
    a.image.access = .present;
}

/// The submit's wait (acquire) and signal (present) semaphores.
pub fn submitInfos(self: *const Swapchain, fs: *const FrameScheduler.FrameSlot, a: Acquired) struct { wait: vk.SemaphoreSubmitInfo, signal: vk.SemaphoreSubmitInfo } {
    return .{
        .wait = .{ .semaphore = self.acquire_sems[fs.index], .value = 0, .stage_mask = .{ .color_attachment_output = true, .all_transfer = true }, .device_index = 0 },
        .signal = .{ .semaphore = self.present_sems[a.index], .value = 0, .stage_mask = .{ .all_commands = true }, .device_index = 0 },
    };
}

/// Presents `a` after `fs` was submitted (signalling its present
/// semaphore).
pub fn present(self: *Swapchain, a: Acquired, ext: PresentExt) PresentError!void {
    const gpu = self.gpu;
    const caps = gpu.info.caps;
    const d = &gpu.ddisp;
    const index = [_]u32{a.index};
    const chains = [_]vk.SwapchainKHR{self.handle};
    const wait = [_]vk.Semaphore{self.present_sems[a.index]};
    var info: vk.PresentInfoKHR = .{ .wait_semaphore_count = 1, .p_wait_semaphores = &wait, .swapchain_count = 1, .p_swapchains = &chains, .p_image_indices = &index };

    var ids: [1]u64 = .{ext.present_id orelse 0};
    var id2: vk.PresentId2KHR = .{ .swapchain_count = 1, .p_present_ids = &ids };
    var id1: vk.PresentIdKHR = .{ .swapchain_count = 1, .p_present_ids = &ids };
    if (ext.present_id != null) {
        if (caps.present_id2) vk.chain(&info, &id2) else if (caps.present_id) vk.chain(&info, &id1);
    }
    var region: [1]vk.PresentRegionKHR = .{.{}};
    var regions: vk.PresentRegionsKHR = .{ .swapchain_count = 1, .p_regions = &region };
    if (ext.regions) |rs| if (caps.incremental_present and rs.len != 0) {
        region[0] = .{ .rectangle_count = @intCast(rs.len), .p_rectangles = rs.ptr };
        vk.chain(&info, &regions);
    };
    var fence: [1]vk.Fence = .{.null_handle};
    var fence_info: vk.SwapchainPresentFenceInfoKHR = .{ .swapchain_count = 1, .p_fences = &fence };
    var mode: [1]vk.PresentModeKHR = .{self.mode};
    var mode_info: vk.SwapchainPresentModeInfoKHR = .{ .swapchain_count = 1, .p_present_modes = &mode };
    if (caps.swapchain_maint1) {
        if (self.takeFence()) |f| {
            fence[0] = f;
            vk.chain(&info, &fence_info);
        } else |_| {}
        if (ext.mode_override) |m| if (std.mem.indexOfScalar(vk.PresentModeKHR, self.modes[0..self.n_modes], m) != null) {
            mode[0] = m;
            self.mode = m;
            vk.chain(&info, &mode_info);
        };
    }

    const q = &gpu.gfx;
    q.mutex.lockUncancelable(gpu.io);
    const r = d.queue_present_khr(q.handle, &info);
    q.mutex.unlock(gpu.io);
    if (fence[0] != .null_handle) {
        // The fence is signalled once the present is done with the image
        // (also on OUT_OF_DATE / SUBOPTIMAL, per maintenance1).
        self.inflight.append(self.gpa, .{ .fence = fence[0], .swapchain = self.handle }) catch {
            _ = d.wait_for_fences(gpu.dev, 1, &fence, .true, std.time.ns_per_s);
            d.destroy_fence(gpu.dev, fence[0], null);
        };
    }
    self.ages.presented(a.index);
    switch (r) {
        .success => {},
        .suboptimal_khr, .error_out_of_date_khr => self.needs_recreate = true,
        .error_surface_lost_khr => {
            self.surface_lost = true;
            return error.SurfaceLost;
        },
        else => {
            try gpu.checkLost(r);
            _ = vk.check(r) catch |e| return mapErr(e);
        },
    }
}

/// A `FramePacer.PresentWaiter` on this swapchain (null without present
/// wait support).
pub fn presentWaiter(self: *Swapchain) ?FramePacer.PresentWaiter {
    const caps = self.gpu.info.caps;
    if (!caps.present_wait2 and !caps.present_wait) return null;
    return .{ .ctx = self, .wait = waitPresent };
}

fn waitPresent(ctx: *anyopaque, id: u64, timeout_ns: u64) FramePacer.WaitResult {
    const self: *Swapchain = @ptrCast(@alignCast(ctx));
    const gpu = self.gpu;
    if (self.handle == .null_handle) return .ready;
    const r = if (gpu.info.caps.present_wait2)
        gpu.ddisp.wait_for_present2_khr(gpu.dev, self.handle, &.{ .present_id = id, .timeout = timeout_ns })
    else
        gpu.ddisp.wait_for_present_khr(gpu.dev, self.handle, id, timeout_ns);
    return switch (r) {
        .success, .suboptimal_khr => .ready,
        .timeout => .timeout,
        // OUT_OF_DATE: the swapchain is being replaced; carry on.
        .error_out_of_date_khr => .ready,
        else => .lost,
    };
}

// ------------------------------------------------------------ internals

fn current(self: *const Swapchain) Retired {
    var r: Retired = .{ .handle = self.handle, .views = undefined, .sems = self.present_sems, .count = self.count };
    for (self.images[0..self.count], 0..) |img, i| r.views[i] = img.view;
    return r;
}

fn createSurface(self: *Swapchain) !void {
    const gpu = self.gpu;
    _ = try vk.check(gpu.instance.disp.create_win32_surface_khr(gpu.instance.inst, &.{ .hinstance = self.hinstance, .hwnd = self.hwnd }, null, &self.surface));
}

fn recreateSurface(self: *Swapchain) AcquireError!void {
    // Everything on the old surface goes first.
    if (self.handle != .null_handle) {
        try self.retireCurrent(true);
    }
    self.gpu.instance.disp.destroy_surface_khr(self.gpu.instance.inst, self.surface, null);
    self.surface = .null_handle;
    self.createSurface() catch return error.SurfaceLost;
    self.surface_lost = false;
    self.needs_recreate = true;
}

fn pickFormat(self: *Swapchain) !vk.SurfaceFormatKHR {
    const gpu = self.gpu;
    var n: u32 = 0;
    _ = try vk.check(gpu.instance.disp.get_physical_device_surface_formats_khr(gpu.pdev, self.surface, &n, null));
    var buf: [64]vk.SurfaceFormatKHR = undefined;
    n = @min(n, buf.len);
    _ = try vk.check(gpu.instance.disp.get_physical_device_surface_formats_khr(gpu.pdev, self.surface, &n, &buf));
    return choice.surfaceFormat(buf[0..n]) orelse error.NoSurfaceFormat;
}

fn surfaceCaps(self: *Swapchain) AcquireError!vk.SurfaceCapabilitiesKHR {
    const gpu = self.gpu;
    var caps: vk.SurfaceCapabilitiesKHR = .{};
    const r = gpu.instance.disp.get_physical_device_surface_capabilities_khr(gpu.pdev, self.surface, &caps);
    if (r == .error_surface_lost_khr) {
        self.surface_lost = true;
        return error.SurfaceLost;
    }
    _ = vk.check(r) catch |e| return mapErr(e);
    return caps;
}

/// The present modes compatible with `mode` (maintenance1), or just it.
fn compatibleModes(self: *Swapchain, mode: vk.PresentModeKHR, out: []vk.PresentModeKHR) u32 {
    const gpu = self.gpu;
    out[0] = mode;
    if (!gpu.info.caps.swapchain_maint1 or !gpu.instance.exts.contains(.khr_get_surface_capabilities2)) return 1;
    var spm: vk.SurfacePresentModeKHR = .{ .present_mode = mode };
    const info: vk.PhysicalDeviceSurfaceInfo2KHR = .{ .p_next = &spm, .surface = self.surface };
    var compat: vk.SurfacePresentModeCompatibilityKHR = .{ .present_mode_count = @intCast(out.len), .p_present_modes = out.ptr };
    var caps2: vk.SurfaceCapabilities2KHR = .{ .p_next = &compat };
    if (gpu.instance.disp.get_physical_device_surface_capabilities2_khr(gpu.pdev, &info, &caps2) != .success or compat.present_mode_count == 0) {
        out[0] = mode;
        return 1;
    }
    return compat.present_mode_count;
}

fn recreate(self: *Swapchain) AcquireError!void {
    const gpu = self.gpu;
    const d = &gpu.ddisp;
    const caps = try self.surfaceCaps();
    const ext = choice.extent(caps, self.want);
    if (ext.width == 0 or ext.height == 0) return error.Minimized;

    var modes: [8]vk.PresentModeKHR = undefined;
    var n_sup: u32 = modes.len;
    _ = vk.check(gpu.instance.disp.get_physical_device_surface_present_modes_khr(gpu.pdev, self.surface, &n_sup, &modes)) catch |e| return mapErr(e);
    const mode = choice.presentMode(self.prefs, modes[0..@min(n_sup, modes.len)]);
    self.n_modes = self.compatibleModes(mode, &self.modes);

    var ci: vk.SwapchainCreateInfoKHR = .{
        .surface = self.surface,
        .min_image_count = @min(choice.imageCount(caps.min_image_count, caps.max_image_count), max_images),
        .image_format = self.format.vkFormat(),
        .image_color_space = self.color_space,
        .image_extent = ext,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment = true, .transfer_dst = true },
        .image_sharing_mode = .exclusive,
        .pre_transform = caps.current_transform,
        .composite_alpha = choice.compositeAlpha(caps.supported_composite_alpha, self.prefs.transparent),
        .present_mode = mode,
        .clipped = .true,
        .old_swapchain = self.handle,
    };
    if (gpu.info.caps.present_id2 and gpu.info.caps.present_wait2) {
        ci.flags.present_id_2 = true;
        ci.flags.present_wait_2 = true;
    }
    var modes_ci: vk.SwapchainPresentModesCreateInfoKHR = .{ .present_mode_count = self.n_modes, .p_present_modes = &self.modes };
    if (gpu.info.caps.swapchain_maint1) {
        ci.flags.deferred_memory_allocation = true;
        vk.chain(&ci, &modes_ci);
    }
    var handle: vk.SwapchainKHR = .null_handle;
    const r = d.create_swapchain_khr(gpu.dev, &ci, null, &handle);
    if (r == .error_surface_lost_khr or r == .error_native_window_in_use_khr) {
        self.surface_lost = true;
        return error.SurfaceLost;
    }
    _ = vk.check(r) catch |e| return mapErr(e);
    gpu.name(handle, "swapchain");

    if (self.handle != .null_handle) try self.retireCurrent(false);
    self.handle = handle;
    self.extent = ext;
    self.mode = mode;
    self.ages.reset();
    self.recreates += 1;

    var imgs: [max_images]vk.Image = undefined;
    var n: u32 = max_images;
    _ = vk.check(d.get_swapchain_images_khr(gpu.dev, handle, &n, &imgs)) catch |e| return mapErr(e);
    self.count = n;
    for (imgs[0..n], 0..) |img, i| {
        var view: vk.ImageView = .null_handle;
        _ = vk.check(d.create_image_view(gpu.dev, &.{
            .image = img,
            .view_type = .@"2d",
            .format = self.format.vkFormat(),
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = barriers.color_range,
        }, null, &view)) catch |e| return mapErr(e);
        self.images[i] = .{
            .image = .{ .handle = img, .alloc = undefined, .extent = ext, .format = self.format.vkFormat() },
            .view = view,
            .format = self.format,
            .width = ext.width,
            .height = ext.height,
        };
        self.present_sems[i] = .null_handle;
        _ = vk.check(d.create_semaphore(gpu.dev, &.{}, null, &self.present_sems[i])) catch |e| return mapErr(e);
    }
    self.needs_recreate = false;
}

/// Moves the current swapchain to the retired list (destroyed once its
/// presents are done). `destroy_now` waits for that (surface loss).
fn retireCurrent(self: *Swapchain, destroy_now: bool) AcquireError!void {
    const r = self.current();
    self.handle = .null_handle;
    self.count = 0;
    if (destroy_now or !self.gpu.info.caps.swapchain_maint1) {
        // Without present fences the only safe point is an idle queue.
        self.sched.waitValue(self.sched.submitted) catch return error.DeviceLost;
        self.queueWaitIdle();
        self.collect();
        self.destroyRetired(r);
        return;
    }
    self.retired.append(self.gpa, r) catch {
        self.queueWaitIdle();
        self.destroyRetired(r);
    };
}

/// Recycles signalled present fences and destroys retired swapchains whose
/// presents are all done. Never waits.
fn collect(self: *Swapchain) void {
    const gpu = self.gpu;
    const d = &gpu.ddisp;
    var i: usize = 0;
    while (i < self.inflight.items.len) {
        const f = self.inflight.items[i];
        if (d.get_fence_status(gpu.dev, f.fence) == .success) {
            _ = d.reset_fences(gpu.dev, 1, @ptrCast(&f.fence));
            self.free_fences.append(self.gpa, f.fence) catch d.destroy_fence(gpu.dev, f.fence, null);
            _ = self.inflight.swapRemove(i);
        } else i += 1;
    }
    var k: usize = 0;
    while (k < self.retired.items.len) {
        const r = self.retired.items[k];
        const busy = for (self.inflight.items) |f| {
            if (f.swapchain == r.handle) break true;
        } else false;
        if (!busy) {
            self.destroyRetired(r);
            _ = self.retired.swapRemove(k);
        } else k += 1;
    }
}

fn destroyRetired(self: *Swapchain, r: Retired) void {
    const d = &self.gpu.ddisp;
    const dev = self.gpu.dev;
    for (r.views[0..r.count]) |v| d.destroy_image_view(dev, v, null);
    for (r.sems[0..r.count]) |s| if (s != .null_handle) d.destroy_semaphore(dev, s, null);
    d.destroy_swapchain_khr(dev, r.handle, null);
}

fn takeFence(self: *Swapchain) !vk.Fence {
    if (self.free_fences.pop()) |f| return f;
    var f: vk.Fence = .null_handle;
    _ = try vk.check(self.gpu.ddisp.create_fence(self.gpu.dev, &.{}, null, &f));
    return f;
}

fn queueWaitIdle(self: *Swapchain) void {
    const q = &self.gpu.gfx;
    q.mutex.lockUncancelable(self.gpu.io);
    _ = self.gpu.ddisp.queue_wait_idle(q.handle);
    q.mutex.unlock(self.gpu.io);
}

fn mapErr(e: anyerror) error{ DeviceLost, OutOfHostMemory, OutOfDeviceMemory } {
    return switch (e) {
        error.OutOfDeviceMemory => error.OutOfDeviceMemory,
        error.DeviceLost => error.DeviceLost,
        else => error.OutOfHostMemory,
    };
}

test {
    _ = choice;
    // Analyse the Vulkan code on every host (it only runs on Windows).
    std.testing.refAllDecls(Swapchain);
}
