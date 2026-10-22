//! The Vulkan renderer behind `createRenderer`, with device-loss recovery
//! (E02.F02.S02.T01).
//!
//! It owns a `VkRenderer` and a CPU copy of every texture
//! (`TextureRegistry`). When a frame or texture call reports
//! `DeviceLost` and the device latched the loss, `lost.Recovery.onLost`
//! runs:
//! - Teardown destroys the renderer. Nothing waits on a lost device, and
//!   the pipeline cache file is not rewritten.
//! - Recreate probes and picks a device again, builds a new renderer and
//!   uploads every texture again under its old id.
//! - After `LostPolicy.max_losses` losses within the window, the software
//!   renderer takes over the same target, with the same texture ids.
//!
//! The frame that hit the loss returns `error.DeviceLost`, as does the
//! first frame after a delayed recreation. The render thread then asks
//! the UI for a full repaint, which also redraws the layers the new
//! renderer does not have.
//!
//! Win32 windows have no CPU present path yet (E01). There, instead of
//! switching to software, frames are skipped and Vulkan is retried every
//! `retry_ns`.
//!
//! One thread owns the renderer, as for any `Renderer`. The present
//! waiter runs on that thread too (the render thread's pacer).

const Recovering = @This();

const std = @import("std");
const zg_core = @import("zg_core");
const r2d = @import("../root.zig");
const lost = @import("../../gpu/lost.zig");
const FramePacer = @import("../../present/FramePacer.zig");
const SwRenderer = @import("../../sw/SwRenderer.zig");
const TextureRegistry = @import("../texture_registry.zig");
const VkRenderer = @import("VkRenderer.zig");

const log = std.log.scoped(.zg_vulkan);

const RenderError = r2d.RenderError;
const TextureId = r2d.TextureId;
const PxRect = r2d.PxRect;
const Size = r2d.Size;

/// How long a Win32 window waits between Vulkan recreation attempts.
pub const retry_ns: u64 = 5 * std.time.ns_per_s;

pub const Inner = union(enum) {
    vulkan: *VkRenderer,
    software: *SwRenderer,
    /// Torn down; Vulkan is retried at `retry_at`.
    none,
};

gpa: std.mem.Allocator,
io: std.Io,
opts: r2d.RendererOptions,
inner: Inner,
/// CPU copies of the textures (empty once on software, which keeps its
/// own).
shadows: TextureRegistry = .{},
recovery: lost.Recovery = .{},
retry_at: u64 = 0,
/// Swapchain presents made by renderers already destroyed: the pacer's
/// present ids continue across recreations.
present_base: u64 = 0,

/// Creates a Vulkan renderer for `opts` (see `VkRenderer.create`).
pub fn create(gpa: std.mem.Allocator, io: std.Io, opts: r2d.RendererOptions) !*Recovering {
    const v = try VkRenderer.create(gpa, io, opts);
    errdefer v.destroy();
    const self = try gpa.create(Recovering);
    self.* = .{ .gpa = gpa, .io = io, .opts = opts, .inner = .{ .vulkan = v } };
    return self;
}

pub fn destroy(self: *Recovering) void {
    switch (self.inner) {
        .vulkan => |v| v.destroy(),
        .software => |s| s.destroy(),
        .none => {},
    }
    self.shadows.deinit(self.gpa);
    self.gpa.destroy(self);
}

/// The type-erased interface.
pub fn renderer(self: *Recovering) r2d.Renderer {
    return .{ .ptr = self, .vtable = &vtable };
}

/// Whether `r` is a `Recovering`.
pub fn is(r: r2d.Renderer) bool {
    return r.vtable == &vtable;
}

/// The `Recovering` behind `r` (`is(r)` must hold).
pub fn of(r: r2d.Renderer) *Recovering {
    std.debug.assert(is(r));
    return cast(r.ptr);
}

pub const vtable: r2d.Renderer.VTable = .{
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

fn cast(p: *anyopaque) *Recovering {
    return @ptrCast(@alignCast(p));
}
fn vRender(p: *anyopaque, dl: *const r2d.DrawList) RenderError!r2d.FrameStats {
    return cast(p).render(dl);
}
fn vResize(p: *anyopaque, size: Size, scale: f32) void {
    const self = cast(p);
    self.opts.size = size;
    switch (self.inner) {
        .vulkan => |v| v.renderer().resize(size, scale),
        .software => |s| s.renderer().resize(size, scale),
        .none => {},
    }
}
fn vCreateTexture(p: *anyopaque, desc: r2d.TextureDesc) RenderError!TextureId {
    return cast(p).createTexture(desc);
}
fn vUpdateTexture(p: *anyopaque, id: TextureId, rect: PxRect, data: []const u8, pitch: u32) RenderError!void {
    return cast(p).updateTexture(id, rect, data, pitch);
}
fn vDestroyTexture(p: *anyopaque, id: TextureId) void {
    const self = cast(p);
    self.shadows.remove(self.gpa, id);
    switch (self.inner) {
        .vulkan => |v| v.destroyTexture(id),
        .software => |s| s.destroyTexture(id),
        .none => {},
    }
}
fn vDestroyLayer(p: *anyopaque, id: r2d.LayerId) void {
    switch (cast(p).inner) {
        .vulkan => |v| v.renderer().destroyLayer(id),
        .software => |s| s.renderer().destroyLayer(id),
        .none => {},
    }
}
fn vBackend(p: *anyopaque) r2d.Backend {
    return switch (cast(p).inner) {
        .vulkan, .none => .vulkan,
        .software => .software,
    };
}
fn vDeinit(p: *anyopaque) void {
    cast(p).destroy();
}
fn vLayerValid(p: *anyopaque, id: r2d.LayerId, size: Size) bool {
    return switch (cast(p).inner) {
        .vulkan => |v| v.renderer().vtable.layerValid(v, id, size),
        .software => |s| s.renderer().vtable.layerValid(s, id, size),
        .none => false,
    };
}

/// Renders `dl`; see the file comment for what happens on a loss.
pub fn render(self: *Recovering, dl: *const r2d.DrawList) RenderError!r2d.FrameStats {
    switch (self.inner) {
        .software => |s| return s.render(dl),
        .none => {
            const now = zg_core.time.nowNs(self.io);
            if (now < self.retry_at) return .{ .backend = .vulkan, .skipped = true };
            self.recreate() catch |err| {
                log.info("Vulkan recreation failed: {t}; retrying in {d} s", .{ err, retry_ns / std.time.ns_per_s });
                self.retry_at = now + retry_ns;
                return .{ .backend = .vulkan, .skipped = true };
            };
            // The UI repaints everything, layers included.
            return error.DeviceLost;
        },
        .vulkan => |v| {
            var stats = v.render(dl) catch |err| {
                if (v.isLost()) self.onLost();
                return err;
            };
            if (v.sc != null and stats.present_id != 0) stats.present_id += self.present_base;
            return stats;
        },
    }
}

pub fn createTexture(self: *Recovering, desc: r2d.TextureDesc) RenderError!TextureId {
    switch (self.inner) {
        .software => |s| return s.createTexture(desc),
        .vulkan => |v| {
            const id = v.createTexture(desc) catch |err| {
                if (!v.isLost()) return err;
                // Create it on whatever recovery left in place.
                self.onLost();
                return self.createTexture(desc);
            };
            self.shadows.put(self.gpa, id, desc) catch {
                v.destroyTexture(id);
                return error.OutOfMemory;
            };
            return id;
        },
        .none => {
            if (desc.width == 0 or desc.height == 0) return error.InvalidArgument;
            const id = self.shadows.freeId();
            try self.shadows.put(self.gpa, id, desc);
            return id;
        },
    }
}

pub fn updateTexture(self: *Recovering, id: TextureId, rect: PxRect, data: []const u8, pitch: u32) RenderError!void {
    switch (self.inner) {
        .software => |s| return s.updateTexture(id, rect, data, pitch),
        .vulkan => |v| {
            try self.shadows.update(id, rect, data, pitch);
            v.updateTexture(id, rect, data, pitch) catch |err| {
                // The copy has it: recovery uploads it with the rest.
                if (v.isLost()) return self.onLost();
                return err;
            };
        },
        .none => try self.shadows.update(id, rect, data, pitch),
    }
}

/// The present waiter for `RenderThread.Options.waiter`: forwards to the
/// current swapchain and maps the pacer's ids to its own. Null when the
/// renderer has no present-wait support.
pub fn presentWaiter(self: *Recovering) ?FramePacer.PresentWaiter {
    const v = switch (self.inner) {
        .vulkan => |v| v,
        else => return null,
    };
    _ = v.presentWaiter() orelse return null;
    return .{ .ctx = self, .wait = waitPresent };
}

fn waitPresent(ctx: *anyopaque, id: u64, timeout_ns: u64) FramePacer.WaitResult {
    const self = cast(ctx);
    // Presents of a destroyed swapchain are over.
    if (id <= self.present_base) return .ready;
    const v = switch (self.inner) {
        .vulkan => |v| v,
        else => return .ready,
    };
    const w = v.presentWaiter() orelse return .ready;
    return w.wait(w.ctx, id - self.present_base, timeout_ns);
}

/// See `VkRenderer.pacerCaps`; software frames pace as without a swapchain.
pub fn pacerCaps(self: *const Recovering) FramePacer.Caps {
    return switch (self.inner) {
        .vulkan => |v| v.pacerCaps(),
        else => .{ .headless = self.opts.target == .headless, .platform_frames = self.opts.target == .external },
    };
}

// ------------------------------------------------------------- recovery

fn onLost(self: *Recovering) void {
    const now = zg_core.time.nowNs(self.io);
    const outcome = self.recovery.onLost(now, .{
        .ctx = self,
        .teardown = hookTeardown,
        .recreate = hookRecreate,
        .switchToSoftware = hookSoftware,
    }) catch |err| {
        log.warn("no software fallback for this target ({t}); retrying Vulkan in {d} s", .{ err, retry_ns / std.time.ns_per_s });
        self.retry_at = now + retry_ns;
        return;
    };
    log.info("device lost: {t} ({d} losses recorded)", .{ outcome, self.recovery.history().len });
}

fn hookTeardown(ctx: *anyopaque) void {
    const self = cast(ctx);
    switch (self.inner) {
        .vulkan => |v| {
            self.present_base += v.present_count;
            v.destroy();
        },
        else => {},
    }
    self.inner = .none;
}

fn hookRecreate(ctx: *anyopaque) anyerror!void {
    return cast(ctx).recreate();
}

fn hookSoftware(ctx: *anyopaque) anyerror!void {
    const self = cast(ctx);
    const s = try SwRenderer.create(self.gpa, self.io, self.opts);
    errdefer s.destroy();
    try restore(s, &self.shadows);
    self.inner = .{ .software = s };
    // The software renderer keeps its own copies.
    self.shadows.deinit(self.gpa);
    self.shadows = .{};
    log.info("switched to the software renderer", .{});
}

/// A new device and renderer, with every texture uploaded again.
fn recreate(self: *Recovering) !void {
    const v = try VkRenderer.create(self.gpa, self.io, self.opts);
    errdefer v.destroy();
    try restore(v, &self.shadows);
    self.inner = .{ .vulkan = v };
}

/// Recreates the registry's textures in `r` under their ids.
fn restore(r: anytype, reg: *const TextureRegistry) !void {
    for (reg.entries.items, 0..) |e, i| {
        const sh = e orelse continue;
        const id: TextureId = @enumFromInt(i);
        try r.createTextureAt(sh.desc, id);
        try r.updateTexture(id, .{ .x = 0, .y = 0, .w = sh.desc.width, .h = sh.desc.height }, sh.pixels, sh.rowBytes());
    }
}
