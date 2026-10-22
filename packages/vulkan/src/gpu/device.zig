//! Logical-device creation: device extensions per surface kind, queue
//! selection and the feature chain (E02.F02.S01.T02).

const std = @import("std");
const vk = @import("../vk/vk.zig");
const loader = @import("../loader/loader.zig");
const tables = loader.tables;
const FeatureSet = @import("features.zig").FeatureSet;
const select = @import("select.zig");
const instance = @import("instance.zig");

const log = std.log.scoped(.vk);
const ExtSet = loader.ExtSet;
const ext_count = @typeInfo(vk.Extension).@"enum".fields.len;

/// A device queue. Queues are externally synchronised: lock `mutex`
/// around submits and presents (the pacing thread presents too).
pub const Queue = struct {
    handle: vk.Queue,
    family: u32,
    timestamp_valid_bits: u32,
    mutex: std.Io.Mutex = .init,
};

/// The device extensions to enable for a device supporting `supported`
/// at API `api`. Pure.
///
/// `VK_KHR_dynamic_rendering` and `VK_KHR_synchronization2` are enabled
/// on 1.2 devices only; their vk.xml dependencies
/// (`VK_KHR_depth_stencil_resolve`, `VK_KHR_create_renderpass2`,
/// `VK_KHR_get_physical_device_properties2`) are core in 1.2, so nothing
/// else is needed.
pub fn deviceExtensions(supported: ExtSet, api: vk.Version, kind: instance.SurfaceKind) ExtSet {
    var want: ExtSet = .initEmpty();
    switch (kind) {
        .win32 => {
            for ([_]vk.Extension{ .khr_swapchain, .khr_present_id, .khr_present_wait, .khr_present_id2, .khr_present_wait2, .khr_incremental_present }) |e| want.insert(e);
            want.insert(if (supported.contains(.khr_swapchain_maintenance1)) .khr_swapchain_maintenance1 else .ext_swapchain_maintenance1);
            want.insert(if (supported.contains(.khr_present_mode_fifo_latest_ready)) .khr_present_mode_fifo_latest_ready else .ext_present_mode_fifo_latest_ready);
        },
        .external => for ([_]vk.Extension{ .khr_external_memory_fd, .ext_external_memory_dma_buf, .ext_image_drm_format_modifier, .khr_external_semaphore_fd, .ext_queue_family_foreign, .ext_physical_device_drm }) |e| want.insert(e),
        .headless => {},
    }
    want.insert(.ext_memory_budget);
    want.insert(.ext_memory_priority);
    want.insert(if (supported.contains(.khr_calibrated_timestamps)) .khr_calibrated_timestamps else .ext_calibrated_timestamps);
    if (!api.atLeast(1, 3)) {
        want.insert(.khr_dynamic_rendering);
        want.insert(.khr_synchronization2);
    }
    return want.intersectWith(supported);
}

/// The queue families to use.
pub const QueuePick = struct {
    gfx: u32,
    /// A dedicated TRANSFER-only family for large uploads and readback.
    transfer: ?u32,
};

/// The first graphics family that can present, and a transfer-only family
/// on non-UMA devices. Pure.
pub fn pickQueues(p: *const select.Probe, uma: bool) ?QueuePick {
    if (p.present_mask == 0) return null;
    const gfx: u32 = @ctz(p.present_mask);
    var transfer: ?u32 = null;
    if (!uma) for (p.queues, 0..) |q, i| {
        const f = q.queue_flags;
        if (f.transfer and !f.graphics and !f.compute and q.queue_count > 0) {
            transfer = @intCast(i);
            break;
        }
    };
    return .{ .gfx = gfx, .transfer = transfer };
}

/// A created logical device.
pub const DeviceBundle = struct {
    dev: vk.Device,
    disp: tables.Device,
    /// The enabled device extensions.
    exts: ExtSet,
    /// The enabled features.
    feat: FeatureSet,
    queues: QueuePick,
};

/// Creates the logical device for `p` with exactly the needed features
/// and extensions. `inst_exts` are the instance's enabled extensions
/// (debug-utils commands load with them).
pub fn createDevice(d: *const tables.Instance, inst_exts: ExtSet, p: *const select.Probe, kind: instance.SurfaceKind, uma: bool) instance.CreateError!DeviceBundle {
    const exts = deviceExtensions(p.exts, p.api, kind);
    const pick = pickQueues(p, uma) orelse return error.NoSuitableDevice;

    var names: [ext_count][*:0]const u8 = undefined;
    var n: u32 = 0;
    var it = exts.iterator();
    while (it.next()) |e| : (n += 1) names[n] = vk.extensionInfo(e).name.ptr;

    const priority = [_]f32{1.0};
    var qci: [2]vk.DeviceQueueCreateInfo = .{
        .{ .queue_family_index = pick.gfx, .queue_count = 1, .p_queue_priorities = &priority },
        .{ .queue_family_index = pick.transfer orelse 0, .queue_count = 1, .p_queue_priorities = &priority },
    };
    var feat = p.feat.required();
    var f2: vk.PhysicalDeviceFeatures2 = .{};
    feat.link(&f2, p.api, exts);
    const ci: vk.DeviceCreateInfo = .{
        .p_next = &f2,
        .queue_create_info_count = if (pick.transfer != null) 2 else 1,
        .p_queue_create_infos = &qci,
        .enabled_extension_count = n,
        .pp_enabled_extension_names = &names,
    };
    var dev: vk.Device = .null_handle;
    _ = try vk.check(d.create_device(p.pdev, &ci, null, &dev));
    feat.unlink();
    var all = exts;
    all.setUnion(inst_exts);
    var diag: loader.Diagnostics = .{};
    const disp = loader.loadDevice(d, dev, loader.apiNumber(p.api), all, &diag) catch |err| {
        if (diag.missing) |m| log.err("device command {s} is missing", .{m});
        const destroy: ?vk.PfnDestroyDevice = @ptrCast(d.get_device_proc_addr(dev, "vkDestroyDevice"));
        if (destroy) |f| f(dev, null);
        return err;
    };
    return .{ .dev = dev, .disp = disp, .exts = exts, .feat = feat, .queues = pick };
}

test "device: extensions per surface kind" {
    const all: ExtSet = .initFull();
    const w = deviceExtensions(all, .fromInt(vk.api_version_1_3), .win32);
    try std.testing.expect(w.contains(.khr_swapchain) and w.contains(.khr_present_wait2) and w.contains(.khr_swapchain_maintenance1));
    try std.testing.expect(!w.contains(.ext_swapchain_maintenance1) and !w.contains(.ext_external_memory_dma_buf));
    try std.testing.expect(!w.contains(.khr_dynamic_rendering));
    const e = deviceExtensions(all, .fromInt(vk.api_version_1_2), .external);
    try std.testing.expect(e.contains(.ext_external_memory_dma_buf) and e.contains(.ext_queue_family_foreign) and !e.contains(.khr_swapchain));
    try std.testing.expect(e.contains(.khr_dynamic_rendering) and e.contains(.khr_synchronization2));
    try std.testing.expect(e.contains(.khr_calibrated_timestamps) and !e.contains(.ext_calibrated_timestamps));
    // Never more than supported.
    var some: ExtSet = .initEmpty();
    some.insert(.ext_calibrated_timestamps);
    const h = deviceExtensions(some, .fromInt(vk.api_version_1_3), .headless);
    try std.testing.expectEqual(@as(usize, 1), h.count());
    try std.testing.expect(h.contains(.ext_calibrated_timestamps));
}

test "device: queue selection" {
    const families = [_]vk.QueueFamilyProperties{
        .{ .queue_flags = .{ .compute = true, .transfer = true }, .queue_count = 4 },
        .{ .queue_flags = .{ .graphics = true, .compute = true, .transfer = true }, .queue_count = 1 },
        .{ .queue_flags = .{ .transfer = true }, .queue_count = 2 },
    };
    var p: select.Probe = .{ .queues = &families, .present_mask = 0b010 };
    try std.testing.expectEqual(QueuePick{ .gfx = 1, .transfer = 2 }, pickQueues(&p, false).?);
    try std.testing.expectEqual(QueuePick{ .gfx = 1, .transfer = null }, pickQueues(&p, true).?);
    p.present_mask = 0;
    try std.testing.expectEqual(@as(?QueuePick, null), pickQueues(&p, false));
}
