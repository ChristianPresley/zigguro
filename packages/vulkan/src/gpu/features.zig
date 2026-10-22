//! The device feature chain: what a device supports (`query`) and the
//! minimal set zigguro enables (`required`) (E02.F02.S01.T02).
//!
//! A struct is chained only when its API version or extension is in
//! effect; chaining any other is a validation error.

const std = @import("std");
const vk = @import("../vk/vk.zig");
const loader = @import("../loader/loader.zig");
const tables = loader.tables;

const ExtSet = loader.ExtSet;

pub const FeatureSet = struct {
    v10: vk.PhysicalDeviceFeatures = .{},
    v11: vk.PhysicalDeviceVulkan11Features = .{},
    v12: vk.PhysicalDeviceVulkan12Features = .{},
    v13: vk.PhysicalDeviceVulkan13Features = .{},
    /// `VK_KHR_dynamic_rendering` on 1.2 devices.
    dyn_khr: vk.PhysicalDeviceDynamicRenderingFeatures = .{},
    /// `VK_KHR_synchronization2` on 1.2 devices.
    sync2_khr: vk.PhysicalDeviceSynchronization2Features = .{},
    present_id: vk.PhysicalDevicePresentIdFeaturesKHR = .{},
    present_wait: vk.PhysicalDevicePresentWaitFeaturesKHR = .{},
    present_id2: vk.PhysicalDevicePresentId2FeaturesKHR = .{},
    present_wait2: vk.PhysicalDevicePresentWait2FeaturesKHR = .{},
    swapchain_maint1: vk.PhysicalDeviceSwapchainMaintenance1FeaturesKHR = .{},
    fifo_latest_ready: vk.PhysicalDevicePresentModeFifoLatestReadyFeaturesKHR = .{},

    /// The chained structs (every field but `v10`, which lives in
    /// `VkPhysicalDeviceFeatures2`).
    const chained = .{ "v11", "v12", "v13", "dyn_khr", "sync2_khr", "present_id", "present_wait", "present_id2", "present_wait2", "swapchain_maint1", "fifo_latest_ready" };

    /// True if the struct in field `name` may be chained for a device with
    /// API version `api` and extensions `exts`.
    pub fn applies(comptime name: []const u8, api: vk.Version, exts: ExtSet) bool {
        const eq = std.mem.eql;
        if (comptime eq(u8, name, "v11") or eq(u8, name, "v12")) return api.atLeast(1, 2);
        if (comptime eq(u8, name, "v13")) return api.atLeast(1, 3);
        if (comptime eq(u8, name, "dyn_khr")) return !api.atLeast(1, 3) and exts.contains(.khr_dynamic_rendering);
        if (comptime eq(u8, name, "sync2_khr")) return !api.atLeast(1, 3) and exts.contains(.khr_synchronization2);
        if (comptime eq(u8, name, "present_id")) return exts.contains(.khr_present_id);
        if (comptime eq(u8, name, "present_wait")) return exts.contains(.khr_present_wait);
        if (comptime eq(u8, name, "present_id2")) return exts.contains(.khr_present_id2);
        if (comptime eq(u8, name, "present_wait2")) return exts.contains(.khr_present_wait2);
        if (comptime eq(u8, name, "swapchain_maint1")) return exts.contains(.khr_swapchain_maintenance1) or exts.contains(.ext_swapchain_maintenance1);
        if (comptime eq(u8, name, "fifo_latest_ready")) return exts.contains(.khr_present_mode_fifo_latest_ready) or exts.contains(.ext_present_mode_fifo_latest_ready);
        @compileError("unknown feature struct " ++ name);
    }

    /// Links the applicable structs behind `f2` (which receives `v10`).
    /// `self` must not move until `unlink`.
    pub fn link(self: *FeatureSet, f2: *vk.PhysicalDeviceFeatures2, api: vk.Version, exts: ExtSet) void {
        f2.* = .{ .features = self.v10 };
        var tail: *?*anyopaque = &f2.p_next;
        inline for (chained) |name| if (applies(name, api, exts)) {
            const s = &@field(self, name);
            s.p_next = null;
            tail.* = s;
            tail = &s.p_next;
        };
    }

    /// Clears the chain pointers so `self` is plain data again.
    pub fn unlink(self: *FeatureSet) void {
        inline for (chained) |name| @field(self, name).p_next = null;
    }

    /// Fills `self` with what `pdev` supports.
    pub fn query(self: *FeatureSet, d: *const tables.Instance, pdev: vk.PhysicalDevice, exts: ExtSet, api: vk.Version) void {
        self.* = .{};
        var f2: vk.PhysicalDeviceFeatures2 = .{};
        self.link(&f2, api, exts);
        d.get_physical_device_features2(pdev, &f2);
        self.v10 = f2.features;
        self.unlink();
    }

    /// The features zigguro enables when supported. Every bit outside
    /// this set stays off.
    pub const wanted: FeatureSet = .{
        .v10 = .{ .dual_src_blend = .true },
        .v12 = .{
            .timeline_semaphore = .true,
            .descriptor_indexing = .true,
            .runtime_descriptor_array = .true,
            .descriptor_binding_partially_bound = .true,
            .descriptor_binding_sampled_image_update_after_bind = .true,
            .descriptor_binding_variable_descriptor_count = .true,
            .descriptor_binding_update_unused_while_pending = .true,
            .shader_sampled_image_array_non_uniform_indexing = .true,
            .host_query_reset = .true,
            .scalar_block_layout = .true,
        },
        .v13 = .{ .dynamic_rendering = .true, .synchronization2 = .true, .maintenance4 = .true },
        .dyn_khr = .{ .dynamic_rendering = .true },
        .sync2_khr = .{ .synchronization2 = .true },
        .present_id = .{ .present_id = .true },
        .present_wait = .{ .present_wait = .true },
        .present_id2 = .{ .present_id2 = .true },
        .present_wait2 = .{ .present_wait2 = .true },
        .swapchain_maint1 = .{ .swapchain_maintenance1 = .true },
        .fifo_latest_ready = .{ .present_mode_fifo_latest_ready = .true },
    };

    /// The minimal enable set: `wanted` ∩ supported (`self`). Whether a
    /// struct is chained at all is decided by the enabled extensions.
    pub fn required(self: *const FeatureSet) FeatureSet {
        return intersect(self, &wanted);
    }

    /// Bitwise AND of every `VkBool32` member.
    pub fn intersect(a: *const FeatureSet, b: *const FeatureSet) FeatureSet {
        var out: FeatureSet = .{};
        inline for (@typeInfo(FeatureSet).@"struct".fields) |sf| {
            const S = sf.type;
            inline for (@typeInfo(S).@"struct".fields) |f| if (f.type == vk.Bool32) {
                const on = @field(@field(a, sf.name), f.name) == .true and @field(@field(b, sf.name), f.name) == .true;
                @field(@field(out, sf.name), f.name) = if (on) .true else .false;
            };
        }
        return out;
    }

    /// True if every bit set in `self` is also set in `other`.
    pub fn subsetOf(self: *const FeatureSet, other: *const FeatureSet) bool {
        inline for (@typeInfo(FeatureSet).@"struct".fields) |sf| {
            inline for (@typeInfo(sf.type).@"struct".fields) |f| if (f.type == vk.Bool32) {
                if (@field(@field(self, sf.name), f.name) == .true and @field(@field(other, sf.name), f.name) != .true) return false;
            };
        }
        return true;
    }

    /// Every bit set (test fixtures).
    pub fn full() FeatureSet {
        var out: FeatureSet = .{};
        inline for (@typeInfo(FeatureSet).@"struct".fields) |sf| {
            inline for (@typeInfo(sf.type).@"struct".fields) |f| if (f.type == vk.Bool32) {
                @field(@field(out, sf.name), f.name) = .true;
            };
        }
        return out;
    }

    /// Sets the bit named `path` ("v12.timeline_semaphore"). Returns false
    /// when there is no such bit.
    pub fn set(self: *FeatureSet, path: []const u8, on: bool) bool {
        const dot = std.mem.indexOfScalar(u8, path, '.') orelse return false;
        inline for (@typeInfo(FeatureSet).@"struct".fields) |sf| if (std.mem.eql(u8, sf.name, path[0..dot])) {
            inline for (@typeInfo(sf.type).@"struct".fields) |f| if (f.type == vk.Bool32 and std.mem.eql(u8, f.name, path[dot + 1 ..])) {
                @field(@field(self, sf.name), f.name) = if (on) .true else .false;
                return true;
            };
        };
        return false;
    }
};

test "features: required set minimal" {
    // A device supporting everything gets exactly `wanted`.
    const all = FeatureSet.full();
    const r = all.required();
    try std.testing.expect(r.subsetOf(&FeatureSet.wanted) and FeatureSet.wanted.subsetOf(&r));
    try std.testing.expectEqual(vk.Bool32.false, r.v10.robust_buffer_access);
    try std.testing.expectEqual(vk.Bool32.false, r.v12.buffer_device_address);

    // No bit is enabled that is not supported.
    var some = FeatureSet.full();
    try std.testing.expect(some.set("v10.dual_src_blend", false));
    try std.testing.expect(some.set("v12.scalar_block_layout", false));
    try std.testing.expect(some.set("v13.maintenance4", false));
    try std.testing.expect(!some.set("v12.no_such_bit", false));
    const r2 = some.required();
    try std.testing.expect(r2.subsetOf(&some));
    try std.testing.expectEqual(vk.Bool32.false, r2.v10.dual_src_blend);
    try std.testing.expectEqual(vk.Bool32.true, r2.v12.timeline_semaphore);
}

test "features: chain only applicable structs" {
    var fs: FeatureSet = .{};
    var f2: vk.PhysicalDeviceFeatures2 = .{};
    // 1.2 device with the KHR fallbacks.
    var exts: ExtSet = .initEmpty();
    exts.insert(.khr_dynamic_rendering);
    exts.insert(.khr_synchronization2);
    fs.link(&f2, .fromInt(vk.api_version_1_2), exts);
    var n: usize = 0;
    var p: ?*anyopaque = f2.p_next;
    while (p) |q| : (n += 1) {
        const base: *vk.BaseOutStructure = @ptrCast(@alignCast(q));
        try std.testing.expect(base.s_type != .physical_device_vulkan_1_3_features);
        p = @ptrCast(base.p_next);
    }
    try std.testing.expectEqual(@as(usize, 4), n); // v11, v12, dyn_khr, sync2_khr
    fs.unlink();
    // 1.3 device: no KHR structs.
    fs.link(&f2, .fromInt(vk.api_version_1_3), exts);
    n = 0;
    p = f2.p_next;
    while (p) |q| : (n += 1) p = @ptrCast(@as(*vk.BaseOutStructure, @ptrCast(@alignCast(q))).p_next);
    try std.testing.expectEqual(@as(usize, 3), n);
}
