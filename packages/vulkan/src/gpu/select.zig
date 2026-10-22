//! Physical-device probing and selection (E02.F02.S01.T02). `choose` and
//! `score` are pure functions over `Probe`, so the policy is tested with
//! synthetic devices (`testdata/probes/*.zon`).
//!
//! Policy:
//! 1. Reject devices below Vulkan 1.2, without timeline semaphores or
//!    descriptor indexing, without dynamic rendering and synchronization2
//!    (core 1.3 or the KHR extensions), or without a graphics queue that
//!    can present.
//! 2. `forced` (`ZG_GPU`, `render.gpu`) picks by index or by a
//!    case-insensitive substring of the name.
//! 3. The device the compositor scans out from (`drm_device`) wins.
//! 4. Otherwise the highest `score`; ties go to the lower index.

const std = @import("std");
const vk = @import("../vk/vk.zig");
const loader = @import("../loader/loader.zig");
const platform = @import("zg_platform");
const tables = loader.tables;
const FeatureSet = @import("features.zig").FeatureSet;
const info = @import("info.zig");
const device = @import("device.zig");
const SurfaceKind = @import("instance.zig").SurfaceKind;

const log = std.log.scoped(.vk);
const ExtSet = loader.ExtSet;

/// Why a device cannot be used.
pub const RejectReason = enum {
    api_too_old,
    no_timeline_semaphore,
    no_descriptor_indexing,
    no_dynamic_rendering,
    no_sync2,
    no_graphics_present_queue,
};

/// GPU preference (E15 `render.gpu_preference`).
pub const Preference = enum { auto, high_performance, low_power };

/// What selection depends on.
pub const SelectOptions = struct {
    surface: SurfaceKind = .headless,
    prefer: Preference = .auto,
    /// The compositor's device (E01 `Presenter.drmDevice()`).
    drm_device: ?platform.surface.DrmDevice = null,
    /// `ZG_GPU` / `render.gpu`: a device index or a name substring.
    forced: ?[]const u8 = null,
    /// dmabuf export is wanted (Linux external presenters); devices
    /// without it score lower since the shm path still works.
    need_dmabuf_export: bool = false,
};

/// Everything selection and device creation need to know about a device.
pub const Probe = struct {
    pdev: vk.PhysicalDevice = .null_handle,
    props: vk.PhysicalDeviceProperties = .{},
    /// The API version usable with it: min(device, instance).
    api: vk.Version = .fromInt(vk.api_version_1_0),
    driver_name: [vk.max_driver_name_size]u8 = @splat(0),
    /// `maxDescriptorSetUpdateAfterBindSampledImages` (1.2 properties).
    max_update_after_bind_sampled: u32 = 0,
    drm: ?vk.PhysicalDeviceDrmPropertiesEXT = null,
    feat: FeatureSet = .{},
    exts: ExtSet = .initEmpty(),
    queues: []const vk.QueueFamilyProperties = &.{},
    /// Bit i: family i has GRAPHICS and can present to the surface kind.
    present_mask: u64 = 0,
    mem: vk.PhysicalDeviceMemoryProperties = .{},
    reject: ?RejectReason = null,

    pub fn name(p: *const Probe) []const u8 {
        return std.mem.sliceTo(&p.props.device_name, 0);
    }

    pub fn driverName(p: *const Probe) []const u8 {
        return std.mem.sliceTo(&p.driver_name, 0);
    }

    pub fn kind(p: *const Probe) vk.PhysicalDeviceType {
        return p.props.device_type;
    }
};

/// The first requirement `p` fails, or null. Pure.
pub fn rejectReason(p: *const Probe) ?RejectReason {
    if (!p.api.atLeast(1, 2)) return .api_too_old;
    const f = &p.feat;
    if (f.v12.timeline_semaphore != .true) return .no_timeline_semaphore;
    if (f.v12.runtime_descriptor_array != .true or f.v12.descriptor_binding_partially_bound != .true or
        f.v12.descriptor_binding_sampled_image_update_after_bind != .true or f.v12.shader_sampled_image_array_non_uniform_indexing != .true)
        return .no_descriptor_indexing;
    const core13 = p.api.atLeast(1, 3);
    if (!(if (core13) f.v13.dynamic_rendering == .true else p.exts.contains(.khr_dynamic_rendering) and f.dyn_khr.dynamic_rendering == .true))
        return .no_dynamic_rendering;
    if (!(if (core13) f.v13.synchronization2 == .true else p.exts.contains(.khr_synchronization2) and f.sync2_khr.synchronization2 == .true))
        return .no_sync2;
    if (p.present_mask == 0) return .no_graphics_present_queue;
    return null;
}

/// The device's score under `opts`. Pure.
pub fn score(p: *const Probe, opts: SelectOptions) i32 {
    var s: i32 = switch (p.kind()) {
        .discrete_gpu => if (opts.prefer == .high_performance) 1000 else 500,
        .integrated_gpu => if (opts.prefer == .low_power) 1000 else 400,
        .virtual_gpu => 300,
        .cpu => -10000,
        else => 0,
    };
    const caps = info.capsOf(p, device.deviceExtensions(p.exts, p.api, opts.surface));
    if (caps.present_wait) s += 50;
    if (caps.dual_src_blend) s += 20;
    if (info.hasRebar(&p.mem)) s += 10;
    if (opts.need_dmabuf_export and !caps.dmabuf_export) s -= 200;
    return s;
}

/// True if `p` is the DRM device `d` (primary or render node).
pub fn drmMatches(p: *const Probe, d: platform.surface.DrmDevice) bool {
    const drm = p.drm orelse return false;
    if (drm.has_primary == .true and drm.primary_major == d.major and drm.primary_minor == d.minor) return true;
    return drm.has_render == .true and drm.render_major == d.major and drm.render_minor == d.minor;
}

/// The index of the device to use, or null when none qualifies. Pure.
pub fn choose(probes: []const Probe, opts: SelectOptions) ?usize {
    if (opts.forced) |f| {
        if (std.fmt.parseInt(usize, f, 10)) |i| {
            if (i < probes.len and probes[i].reject == null) return i;
        } else |_| for (probes, 0..) |*p, i| {
            if (p.reject == null and std.ascii.indexOfIgnoreCase(p.name(), f) != null) return i;
        }
    }
    if (opts.drm_device) |d| for (probes, 0..) |*p, i| {
        if (p.reject == null and drmMatches(p, d)) return i;
    };
    var best: ?usize = null;
    var best_score: i32 = std.math.minInt(i32);
    for (probes, 0..) |*p, i| {
        if (p.reject != null) continue;
        const s = score(p, opts);
        if (s > best_score) {
            best = i;
            best_score = s;
        }
    }
    return best;
}

/// Logs one line per device with its score or reject reason.
pub fn logTable(probes: []const Probe, chosen: ?usize, opts: SelectOptions) void {
    for (probes, 0..) |*p, i| {
        const mark: []const u8 = if (chosen == i) "*" else " ";
        if (p.reject) |r| {
            log.info("{s}gpu {d}: {s} ({s}, Vulkan {d}.{d}) rejected: {s}", .{ mark, i, p.name(), @tagName(p.kind()), p.api.major, p.api.minor, @tagName(r) });
        } else {
            log.info("{s}gpu {d}: {s} ({s}, Vulkan {d}.{d}) score {d}", .{ mark, i, p.name(), @tagName(p.kind()), p.api.major, p.api.minor, score(p, opts) });
        }
    }
}

/// Probes every physical device of `inst` (created with API `inst_api`).
/// `win32` asks for Win32 presentation support. Free with `freeProbes`.
pub fn probeAll(gpa: std.mem.Allocator, inst: vk.Instance, d: *const tables.Instance, inst_api: vk.Version, win32: bool) ![]Probe {
    const pdevs = try vk.enumerateAlloc(vk.PhysicalDevice, gpa, d.enumerate_physical_devices, .{inst});
    defer gpa.free(pdevs);
    const probes = try gpa.alloc(Probe, pdevs.len);
    var done: usize = 0;
    errdefer freeProbes(gpa, probes[0..done]);
    for (pdevs, probes) |pdev, *p| {
        p.* = try probeOne(gpa, d, pdev, inst_api, win32);
        done += 1;
    }
    return probes;
}

pub fn freeProbes(gpa: std.mem.Allocator, probes: []Probe) void {
    for (probes) |*p| gpa.free(p.queues);
    gpa.free(probes);
}

fn probeOne(gpa: std.mem.Allocator, d: *const tables.Instance, pdev: vk.PhysicalDevice, inst_api: vk.Version, win32: bool) !Probe {
    var p: Probe = .{ .pdev = pdev };
    const ext_props = try vk.enumerateAlloc(vk.ExtensionProperties, gpa, d.enumerate_device_extension_properties, .{ pdev, null });
    defer gpa.free(ext_props);
    p.exts = @import("instance.zig").extSetOf(ext_props);

    d.get_physical_device_properties(pdev, &p.props);
    const dev_api: vk.Version = .fromInt(p.props.api_version);
    p.api = .fromInt(vk.makeApiVersion(0, dev_api.major, dev_api.minor, 0));
    if (p.api.toInt() > inst_api.toInt()) p.api = inst_api;

    var props2: vk.PhysicalDeviceProperties2 = .{};
    var driver: vk.PhysicalDeviceDriverProperties = .{};
    var v12: vk.PhysicalDeviceVulkan12Properties = .{};
    var drm: vk.PhysicalDeviceDrmPropertiesEXT = .{};
    if (p.api.atLeast(1, 2)) {
        vk.chain(&props2, &driver);
        vk.chain(&props2, &v12);
    }
    if (p.exts.contains(.ext_physical_device_drm)) vk.chain(&props2, &drm);
    d.get_physical_device_properties2(pdev, &props2);
    p.driver_name = driver.driver_name;
    p.max_update_after_bind_sampled = v12.max_descriptor_set_update_after_bind_sampled_images;
    if (p.exts.contains(.ext_physical_device_drm)) {
        drm.p_next = null;
        p.drm = drm;
    }

    p.feat.query(d, pdev, p.exts, p.api);
    d.get_physical_device_memory_properties(pdev, &p.mem);
    const queues = try vk.enumerateAlloc(vk.QueueFamilyProperties, gpa, d.get_physical_device_queue_family_properties, .{pdev});
    p.queues = queues;
    for (queues, 0..) |q, i| {
        if (i >= 64 or !q.queue_flags.graphics) continue;
        const ok = !win32 or d.get_physical_device_win32_presentation_support_khr(pdev, @intCast(i)) == .true;
        if (ok) p.present_mask |= @as(u64, 1) << @intCast(i);
    }
    p.reject = rejectReason(&p);
    return p;
}

// Synthetic devices for the selection tests.
const Fixture = struct {
    name: []const u8,
    kind: vk.PhysicalDeviceType = .discrete_gpu,
    api: [2]u10 = .{ 1, 3 },
    exts: []const vk.Extension = &.{},
    /// Feature bits the device lacks ("v12.timeline_semaphore").
    unsupported: []const []const u8 = &.{},
    drm_primary: ?[2]i64 = null,
    drm_render: ?[2]i64 = null,
    present: bool = true,
    /// A DEVICE_LOCAL|HOST_VISIBLE heap larger than 256 MiB.
    rebar: bool = false,

    fn probe(f: Fixture) Probe {
        var p: Probe = .{ .api = .fromInt(vk.makeApiVersion(0, 1, f.api[1], 0)), .feat = .full(), .present_mask = if (f.present) 1 else 0 };
        p.props.device_type = f.kind;
        @memcpy(p.props.device_name[0..f.name.len], f.name);
        for (f.exts) |e| p.exts.insert(e);
        for (f.unsupported) |u| std.debug.assert(p.feat.set(u, false));
        if (f.drm_primary != null or f.drm_render != null) {
            p.drm = .{};
            if (f.drm_primary) |m| {
                p.drm.?.has_primary = .true;
                p.drm.?.primary_major = m[0];
                p.drm.?.primary_minor = m[1];
            }
            if (f.drm_render) |m| {
                p.drm.?.has_render = .true;
                p.drm.?.render_major = m[0];
                p.drm.?.render_minor = m[1];
            }
        }
        p.mem.memory_heap_count = 1;
        p.mem.memory_heaps[0] = .{ .size = 8 << 30, .flags = .{ .device_local = true } };
        p.mem.memory_type_count = 1;
        p.mem.memory_types[0] = .{ .property_flags = .{ .device_local = true, .host_visible = f.rebar } };
        p.reject = rejectReason(&p);
        return p;
    }
};

fn fixtures(comptime list: []const Fixture) [list.len]Probe {
    var out: [list.len]Probe = undefined;
    for (list, &out) |f, *p| p.* = f.probe();
    return out;
}

const hybrid: []const Fixture = @import("testdata/probes/hybrid_laptop.zon");
const old_and_khr: []const Fixture = @import("testdata/probes/old_and_khr.zon");
const ci: []const Fixture = @import("testdata/probes/ci_lavapipe.zon");

test "select: rejects 1.1 device" {
    const ps = fixtures(old_and_khr);
    try std.testing.expectEqual(RejectReason.api_too_old, ps[0].reject.?);
    try std.testing.expectEqual(RejectReason.no_timeline_semaphore, ps[2].reject.?);
    try std.testing.expectEqual(RejectReason.no_dynamic_rendering, ps[3].reject.?);
    try std.testing.expectEqual(RejectReason.no_graphics_present_queue, ps[4].reject.?);
    try std.testing.expectEqual(@as(?usize, 1), choose(&ps, .{}));
    // Forcing a rejected device does not override the requirements.
    try std.testing.expectEqual(@as(?usize, 1), choose(&ps, .{ .forced = "0" }));
}

test "select: 1.2 + KHR accepted, core13=false" {
    const ps = fixtures(old_and_khr);
    try std.testing.expectEqual(@as(?RejectReason, null), ps[1].reject);
    const caps = info.capsOf(&ps[1], device.deviceExtensions(ps[1].exts, ps[1].api, .headless));
    try std.testing.expect(!caps.core13);
    try std.testing.expect(caps.dynamic_rendering_khr and caps.sync2_khr);
}

test "select: DRM match beats discrete" {
    const ps = fixtures(hybrid);
    // Without the compositor's device: the discrete GPU.
    try std.testing.expectEqual(@as(?usize, 1), choose(&ps, .{}));
    try std.testing.expectEqual(@as(?usize, 0), choose(&ps, .{ .prefer = .low_power }));
    // The compositor scans out from the iGPU (render node 226:128).
    try std.testing.expectEqual(@as(?usize, 0), choose(&ps, .{ .drm_device = .{ .major = 226, .minor = 128 } }));
    // Primary node match works too.
    try std.testing.expectEqual(@as(?usize, 1), choose(&ps, .{ .drm_device = .{ .major = 226, .minor = 1 } }));
}

test "select: forced by name substring" {
    const ps = fixtures(hybrid);
    try std.testing.expectEqual(@as(?usize, 0), choose(&ps, .{ .forced = "intel" }));
    try std.testing.expectEqual(@as(?usize, 2), choose(&ps, .{ .forced = "LLVMPIPE" }));
    try std.testing.expectEqual(@as(?usize, 0), choose(&ps, .{ .forced = "0" }));
    // No match: normal selection.
    try std.testing.expectEqual(@as(?usize, 1), choose(&ps, .{ .forced = "nvidia" }));
}

test "select: lavapipe only when forced or alone" {
    const ps = fixtures(hybrid);
    try std.testing.expect(choose(&ps, .{}) != 2);
    try std.testing.expect(score(&ps[2], .{}) < 0);
    const alone = fixtures(ci);
    try std.testing.expectEqual(@as(?usize, 0), choose(&alone, .{}));
    try std.testing.expectEqual(@as(?usize, null), choose(&.{}, .{}));
}

test "select: score bonuses" {
    const ps = fixtures(hybrid);
    // Present wait counts only for win32 (where it is enabled), rebar always.
    const s_headless = score(&ps[1], .{});
    const s_win32 = score(&ps[1], .{ .surface = .win32 });
    try std.testing.expectEqual(@as(i32, 500 + 20 + 10), s_headless);
    try std.testing.expectEqual(s_headless + 50, s_win32);
    // Missing dmabuf export is a penalty, not a rejection.
    try std.testing.expect(score(&ps[1], .{ .surface = .external, .need_dmabuf_export = true }) < score(&ps[0], .{ .surface = .external, .need_dmabuf_export = true }));
}
