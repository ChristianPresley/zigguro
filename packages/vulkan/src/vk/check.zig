//! Compiles every declaration of the generated `vk.zig` (its comptime block
//! checks the C layouts on 64-bit targets). `zig build check-vk-gen`
//! builds this file for x86_64-windows, x86_64-linux-gnu and
//! aarch64-linux-gnu.

const std = @import("std");
const vk = @import("vk.zig");

/// References every declaration of `T` (and of the containers it declares,
/// `depth` levels down), forcing the layout of every extern type.
fn refAll(comptime T: type, comptime depth: u8) void {
    inline for (comptime std.meta.declarations(T)) |d| {
        const v = @field(T, d.name);
        const V = @TypeOf(v);
        if (V == type) {
            switch (@typeInfo(v)) {
                .@"struct" => |s| {
                    if (s.layout != .auto) _ = @sizeOf(v);
                    if (depth > 0) refAll(v, depth - 1);
                },
                .@"union", .@"enum" => {
                    if (@typeInfo(v) == .@"union") _ = @sizeOf(v);
                    if (depth > 0) refAll(v, depth - 1);
                },
                else => {},
            }
        } else if (@typeInfo(V) == .@"fn") {
            if (!@typeInfo(V).@"fn".is_generic) _ = &v;
        } else {
            _ = &v;
        }
    }
}

test "vk: all declarations compile" {
    @setEvalBranchQuota(1_000_000);
    refAll(vk, 1);
}

test "vk: flags roundtrip" {
    try std.testing.expectEqual(@as(u32, 0x6), (vk.ImageUsageFlags{ .sampled = true, .transfer_dst = true }).toInt());
    const f: vk.ImageUsageFlags = .fromInt(0x6);
    try std.testing.expect(f.sampled and f.transfer_dst and !f.transfer_src);
    try std.testing.expect(f.contains(.{ .sampled = true }));
    try std.testing.expect(!f.contains(.{ .color_attachment = true }));
    // 64-bit flags: VK_PIPELINE_STAGE_2_CLEAR_BIT is bit 35.
    try std.testing.expectEqual(@as(u64, 1) << 35, (vk.PipelineStageFlags2{ .clear = true }).toInt());
}

test "vk: dispatch tables hold exactly the listed commands" {
    const D = vk.Dispatch(.device, &.{ .create_image, .cmd_begin_rendering });
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(D).@"struct".fields.len);
    try std.testing.expect(@FieldType(D, "create_image") == vk.PfnCreateImage);
    try std.testing.expectEqualStrings("vkCmdBeginRendering", vk.commandName(.cmd_begin_rendering));
    try std.testing.expectEqualStrings("vkCmdBeginRenderingKHR", vk.commandAliases(.cmd_begin_rendering)[0]);
    try std.testing.expectEqual(vk.Level.global, vk.commandLevel(.create_instance));
    try std.testing.expectEqual(vk.Level.instance, vk.commandLevel(.enumerate_physical_devices));
    try std.testing.expectEqual(vk.Level.device, vk.commandLevel(.queue_submit2));
}

test "vk: results and extension values" {
    try std.testing.expectEqual(@as(i32, -1000001004), @intFromEnum(vk.Result.error_out_of_date_khr));
    try std.testing.expectEqual(@as(i32, 1000001000), @intFromEnum(vk.StructureType.swapchain_create_info_khr));
    try std.testing.expectError(error.OutOfDateKHR, vk.check(.error_out_of_date_khr));
    try std.testing.expectError(error.Unknown, vk.check(@enumFromInt(-123456)));
    try std.testing.expectEqual(vk.Result.suboptimal_khr, try vk.check(.suboptimal_khr));
    try std.testing.expectEqualStrings("error_device_lost", vk.resultName(.error_device_lost));
    try std.testing.expectEqualStrings("VK_KHR_swapchain", vk.extensionInfo(.khr_swapchain).name);
    try std.testing.expectEqual(vk.Extension.khr_swapchain, vk.extensionByName("VK_KHR_swapchain").?);
    try std.testing.expectEqual(@as(u32, 103), vk.extensionInfo(.khr_dynamic_rendering).promoted_to);
}

test "vk: struct defaults and pNext chaining" {
    var features: vk.PhysicalDeviceFeatures2 = .{};
    var v13: vk.PhysicalDeviceVulkan13Features = .{};
    var v12: vk.PhysicalDeviceVulkan12Features = .{};
    try std.testing.expectEqual(vk.StructureType.physical_device_features_2, features.s_type);
    vk.chain(&features, &v13);
    vk.chain(&features, &v12);
    try std.testing.expect(features.p_next == @as(?*anyopaque, @ptrCast(&v12)));
    try std.testing.expect(v12.p_next == @as(?*anyopaque, @ptrCast(&v13)));
    try std.testing.expect(v13.p_next == null);
    try std.testing.expect(vk.structExtends(vk.PhysicalDeviceVulkan13Features, vk.PhysicalDeviceFeatures2));
    try std.testing.expect(!vk.structExtends(vk.PhysicalDeviceFeatures2, vk.PhysicalDeviceVulkan13Features));
}

test "vk: enumerateAlloc retries on incomplete" {
    const Fake = struct {
        var calls: u32 = 0;
        fn list(_: vk.Instance, n: *u32, out: ?[*]vk.PhysicalDevice) callconv(vk.cc) vk.Result {
            calls += 1;
            // A device appears between the count and the first fill.
            const total: u32 = if (calls == 1) 2 else 3;
            if (out) |o| {
                const k = @min(n.*, total);
                for (0..k) |i| o[i] = @enumFromInt(i + 1);
                n.* = k;
                return if (k < total) .incomplete else .success;
            }
            n.* = total;
            return .success;
        }
    };
    const f: vk.PfnEnumeratePhysicalDevices = Fake.list;
    const devs = try vk.enumerateAlloc(vk.PhysicalDevice, std.testing.allocator, f, .{vk.Instance.null_handle});
    defer std.testing.allocator.free(devs);
    try std.testing.expectEqual(@as(usize, 3), devs.len);
    try std.testing.expectEqual(@as(u32, 4), Fake.calls);
}
