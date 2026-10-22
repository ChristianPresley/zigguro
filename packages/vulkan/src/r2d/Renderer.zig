//! The renderer interface E04 holds: a type-erased backend (Vulkan,
//! software, later Metal). One thread owns a `Renderer` at a time (the
//! render thread); `render` never blocks the UI thread because the UI
//! thread never calls it. `zg_vulkan.createRenderer` picks the backend.

const std = @import("std");
const platform = @import("zg_platform");
const types = @import("types.zig");
const shading = @import("shading.zig");
const DrawList = @import("DrawList.zig");

const Size = types.Size;
const PxRect = types.PxRect;
const TextureId = types.TextureId;
const LayerId = types.LayerId;
const TextureDesc = types.TextureDesc;
const RenderError = types.RenderError;
const FrameStats = types.FrameStats;
const Backend = types.Backend;

const Renderer = @This();

/// Backend state.
ptr: *anyopaque,
/// Backend functions.
vtable: *const VTable,

/// The functions every backend implements.
pub const VTable = struct {
    /// Renders and presents one frame.
    render: *const fn (*anyopaque, *const DrawList) RenderError!FrameStats,
    /// The target changed to `size` physical pixels at `scale`.
    resize: *const fn (*anyopaque, Size, f32) void,
    /// Creates a texture; its id stays valid until `destroyTexture`.
    createTexture: *const fn (*anyopaque, TextureDesc) RenderError!TextureId,
    /// Replaces texels `rect` of a texture from `data` with `row_pitch`
    /// bytes per row. Takes effect for the next `render`.
    updateTexture: *const fn (*anyopaque, TextureId, PxRect, []const u8, u32) RenderError!void,
    /// Destroys a texture once no frame in flight uses it.
    destroyTexture: *const fn (*anyopaque, TextureId) void,
    /// Drops a cached layer.
    destroyLayer: *const fn (*anyopaque, LayerId) void,
    /// The backend kind.
    backend: *const fn (*anyopaque) Backend,
    /// Destroys the renderer and everything it owns.
    deinit: *const fn (*anyopaque) void,
    /// Answers `DrawList.beginLayer`'s cache question.
    layerValid: *const fn (*anyopaque, LayerId, Size) bool,
};

/// See `VTable.render`.
pub fn render(r: Renderer, dl: *const DrawList) RenderError!FrameStats {
    return r.vtable.render(r.ptr, dl);
}
/// See `VTable.resize`.
pub fn resize(r: Renderer, size: Size, scale: f32) void {
    r.vtable.resize(r.ptr, size, scale);
}
/// See `VTable.createTexture`.
pub fn createTexture(r: Renderer, desc: TextureDesc) RenderError!TextureId {
    return r.vtable.createTexture(r.ptr, desc);
}
/// See `VTable.updateTexture`.
pub fn updateTexture(r: Renderer, id: TextureId, rect: PxRect, data: []const u8, row_pitch: u32) RenderError!void {
    return r.vtable.updateTexture(r.ptr, id, rect, data, row_pitch);
}
/// See `VTable.destroyTexture`.
pub fn destroyTexture(r: Renderer, id: TextureId) void {
    r.vtable.destroyTexture(r.ptr, id);
}
/// See `VTable.destroyLayer`.
pub fn destroyLayer(r: Renderer, id: LayerId) void {
    r.vtable.destroyLayer(r.ptr, id);
}
/// See `VTable.backend`.
pub fn backend(r: Renderer) Backend {
    return r.vtable.backend(r.ptr);
}
/// See `VTable.deinit`.
pub fn deinit(r: Renderer) void {
    r.vtable.deinit(r.ptr);
}
/// A `DrawList.LayerQuery` backed by this renderer. Only valid while the
/// renderer is not rendering on another thread (the render thread fills
/// the list's query in when it takes the list).
pub fn layerQuery(r: Renderer) DrawList.LayerQuery {
    return .{ .ctx = r.ptr, .isValid = r.vtable.layerValid };
}

/// Presentation preferences (E15 `render.present_mode`, `render.frames_in_flight`).
pub const PresentPrefs = struct {
    /// Present mode preference.
    mode: enum { auto, fifo, mailbox, fifo_latest_ready } = .auto,
    /// Frames the GPU may queue (1–3).
    frames_in_flight: u8 = 2,
};

/// Debug and test overrides, collected by the apps from
/// `std.process.Init.environ_map` (Zig 0.16 has no global getenv).
pub const EnvOverrides = struct {
    /// `ZG_VK_LOADER_PATH`: load this Vulkan loader instead of the system one.
    vk_loader_path: ?[]const u8 = null,
    /// `ZG_GPU`: substring of the device name to prefer (e.g. "llvmpipe").
    gpu: ?[]const u8 = null,
    /// `ZG_VK_VALIDATION`: force validation on (1) or off (0).
    vk_validation: ?bool = null,
    /// `ZG_VK_FAULT`: fault injection spec (Debug and test builds only).
    vk_fault: ?[]const u8 = null,
    /// `ZG_RENDER_DEBUG`: debug overlays such as "damage".
    render_debug: ?[]const u8 = null,

    /// Reads the `ZG_*` variables from `map`. Slices point into the map.
    pub fn fromMap(map: *const std.process.Environ.Map) EnvOverrides {
        return .{
            .vk_loader_path = nonEmpty(map.get("ZG_VK_LOADER_PATH")),
            .gpu = nonEmpty(map.get("ZG_GPU")),
            .vk_validation = if (map.get("ZG_VK_VALIDATION")) |v| parseBool(v) else null,
            .vk_fault = nonEmpty(map.get("ZG_VK_FAULT")),
            .render_debug = nonEmpty(map.get("ZG_RENDER_DEBUG")),
        };
    }

    fn nonEmpty(v: ?[]const u8) ?[]const u8 {
        const s = v orelse return null;
        return if (s.len == 0) null else s;
    }

    fn parseBool(v: []const u8) ?bool {
        if (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "on")) return true;
        if (std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false") or std.ascii.eqlIgnoreCase(v, "off")) return false;
        return null;
    }
};

/// Which backend `createRenderer` should use.
pub const BackendPref = enum {
    /// Vulkan when it initialises, software otherwise.
    auto,
    /// Vulkan only (fails without it).
    vulkan,
    /// The CPU renderer.
    software,
};

/// Everything a backend needs to start.
pub const RendererOptions = struct {
    /// Where frames go.
    target: platform.surface.SurfaceTarget,
    /// The window, passed back to `HeadlessSink.write` and presenters.
    window: platform.types.WindowId = @enumFromInt(0),
    /// Initial target size in physical pixels.
    size: Size = .{ .w = 0, .h = 0 },
    /// Backend choice (E15 `render.backend`).
    backend: BackendPref = .auto,
    /// Presentation preferences.
    present: PresentPrefs = .{},
    /// Text coverage parameters.
    text: shading.TextParams = .{},
    /// Directory for the pipeline cache.
    cache_dir: ?std.Io.Dir = null,
    /// Preferred GPU name substring (E15 `render.gpu`).
    gpu: ?[]const u8 = null,
    /// Environment overrides.
    env: EnvOverrides = .{},
    /// Software renderer worker threads (0 = min(cores, 8)).
    sw_threads: u8 = 0,
};

test "options: env overrides parsed" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("ZG_GPU", "llvmpipe");
    try map.put("ZG_VK_VALIDATION", "0");
    try map.put("ZG_RENDER_DEBUG", "");
    try map.put("PATH", "/bin");
    const e = EnvOverrides.fromMap(&map);
    try std.testing.expectEqualStrings("llvmpipe", e.gpu.?);
    try std.testing.expectEqual(@as(?bool, false), e.vk_validation);
    try std.testing.expectEqual(@as(?[]const u8, null), e.render_debug);
    try std.testing.expectEqual(@as(?[]const u8, null), e.vk_loader_path);
}
