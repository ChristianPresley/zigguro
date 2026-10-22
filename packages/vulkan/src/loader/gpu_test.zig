//! Integration tests against the system Vulkan loader (lavapipe in CI).
//! They need a libc-linked test binary (`zig build test-vulkan-gpu`) and
//! skip when no loader is installed or the build cannot open libraries.

const std = @import("std");
const vk = @import("../vk/vk.zig");
const loader = @import("loader.zig");

fn openOrSkip() !loader.Loader {
    return loader.Loader.open(.{}) catch |err| switch (err) {
        error.VulkanNotInstalled, error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
}

test "gpu: open the system loader, create an instance and list devices" {
    const gpa = std.testing.allocator;
    var l = try openOrSkip();
    defer l.close();
    const g = try l.loadGlobal(null);
    var raw: u32 = vk.api_version_1_0;
    _ = try vk.check(g.enumerate_instance_version(&raw));
    const version: vk.Version = .fromInt(raw);
    if (!version.atLeast(1, 1)) return error.SkipZigTest;

    const app: vk.ApplicationInfo = .{
        .p_application_name = "zigguro-test",
        .application_version = 0,
        .p_engine_name = "zigguro",
        .engine_version = 0,
        .api_version = vk.api_version_1_3,
    };
    var inst: vk.Instance = .null_handle;
    _ = try vk.check(g.create_instance(&.{ .p_application_info = &app }, null, &inst));
    const it = try l.loadInstance(inst, @min(loader.apiNumber(version), 103), .initEmpty(), null);
    defer it.destroy_instance(inst, null);

    const devs = try vk.enumerateAlloc(vk.PhysicalDevice, gpa, it.enumerate_physical_devices, .{inst});
    defer gpa.free(devs);
    try std.testing.expect(devs.len > 0);
    for (devs) |d| {
        var props: vk.PhysicalDeviceProperties2 = .{};
        it.get_physical_device_properties2(d, &props);
        const p = props.properties;
        try std.testing.expect(std.mem.sliceTo(&p.device_name, 0).len > 0);
        try std.testing.expect(vk.Version.fromInt(p.api_version).atLeast(1, 0));
        const families = try vk.enumerateAlloc(vk.QueueFamilyProperties, gpa, it.get_physical_device_queue_family_properties, .{d});
        defer gpa.free(families);
        try std.testing.expect(families.len > 0);
        const exts = try vk.enumerateAlloc(vk.ExtensionProperties, gpa, it.enumerate_device_extension_properties, .{ d, null });
        defer gpa.free(exts);
        try std.testing.expect(exts.len > 0);
    }
}
