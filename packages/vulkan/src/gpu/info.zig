//! `GpuInfo`, the capability report every E02 module reads, and the
//! `zg doctor gpu` report (E02.F02.S01.T02, E02.F02.S02.T01).

const std = @import("std");
const vk = @import("../vk/vk.zig");
const loader = @import("../loader/loader.zig");
const select = @import("select.zig");

const ExtSet = loader.ExtSet;

/// What the chosen device can do, given its enabled extensions.
pub const Caps = packed struct(u32) {
    core13: bool = false,
    dynamic_rendering_khr: bool = false,
    sync2_khr: bool = false,
    dual_src_blend: bool = false,
    present_id: bool = false,
    present_wait: bool = false,
    present_id2: bool = false,
    present_wait2: bool = false,
    incremental_present: bool = false,
    swapchain_maint1: bool = false,
    fifo_latest_ready: bool = false,
    memory_budget: bool = false,
    dmabuf_export: bool = false,
    drm_modifier: bool = false,
    sync_fd_export: bool = false,
    physical_device_drm: bool = false,
    calibrated_timestamps: bool = false,
    host_query_reset: bool = false,
    _pad: u14 = 0,
};

/// Device limits the renderer uses.
pub const Limits = struct {
    max_image_dim_2d: u32,
    timestamp_period_ns: f32,
    timestamp_valid_bits: u32,
    non_coherent_atom: u64,
    min_storage_align: u64,
    max_sampled_images_update_after_bind: u32,
};

pub const GpuInfo = struct {
    api_version: vk.Version,
    driver_name: [vk.max_driver_name_size]u8,
    device_name: [vk.max_physical_device_name_size]u8,
    vendor_id: u32,
    device_id: u32,
    kind: vk.PhysicalDeviceType,
    caps: Caps,
    limits: Limits,
    /// A DEVICE_LOCAL|HOST_VISIBLE memory type in a heap over 256 MiB.
    rebar: bool,
    /// Integrated GPU whose device-local heaps are all host-visible.
    uma: bool,
    pipeline_cache_uuid: [vk.uuid_size]u8,

    pub fn name(self: *const GpuInfo) []const u8 {
        return std.mem.sliceTo(&self.device_name, 0);
    }
};

/// The capabilities of `p` with device extensions `enabled`. Pure.
pub fn capsOf(p: *const select.Probe, enabled: ExtSet) Caps {
    const f = &p.feat;
    const core13 = p.api.atLeast(1, 3);
    const has = struct {
        fn any(set: ExtSet, a: vk.Extension, b: vk.Extension) bool {
            return set.contains(a) or set.contains(b);
        }
    }.any;
    return .{
        .core13 = core13,
        .dynamic_rendering_khr = !core13 and enabled.contains(.khr_dynamic_rendering),
        .sync2_khr = !core13 and enabled.contains(.khr_synchronization2),
        .dual_src_blend = f.v10.dual_src_blend == .true,
        .present_id = enabled.contains(.khr_present_id) and f.present_id.present_id == .true,
        .present_wait = enabled.contains(.khr_present_wait) and f.present_wait.present_wait == .true,
        .present_id2 = enabled.contains(.khr_present_id2) and f.present_id2.present_id2 == .true,
        .present_wait2 = enabled.contains(.khr_present_wait2) and f.present_wait2.present_wait2 == .true,
        .incremental_present = enabled.contains(.khr_incremental_present),
        .swapchain_maint1 = has(enabled, .khr_swapchain_maintenance1, .ext_swapchain_maintenance1) and f.swapchain_maint1.swapchain_maintenance1 == .true,
        .fifo_latest_ready = has(enabled, .khr_present_mode_fifo_latest_ready, .ext_present_mode_fifo_latest_ready) and f.fifo_latest_ready.present_mode_fifo_latest_ready == .true,
        .memory_budget = enabled.contains(.ext_memory_budget),
        .dmabuf_export = enabled.contains(.khr_external_memory_fd) and enabled.contains(.ext_external_memory_dma_buf),
        .drm_modifier = enabled.contains(.ext_image_drm_format_modifier),
        .sync_fd_export = enabled.contains(.khr_external_semaphore_fd),
        .physical_device_drm = enabled.contains(.ext_physical_device_drm),
        .calibrated_timestamps = has(enabled, .khr_calibrated_timestamps, .ext_calibrated_timestamps),
        .host_query_reset = p.api.atLeast(1, 2) and f.v12.host_query_reset == .true,
    };
}

/// True if a DEVICE_LOCAL|HOST_VISIBLE type lives in a heap over 256 MiB.
pub fn hasRebar(mem: *const vk.PhysicalDeviceMemoryProperties) bool {
    for (mem.memory_types[0..mem.memory_type_count]) |t| {
        const f = t.property_flags;
        if (f.device_local and f.host_visible and mem.memory_heaps[t.heap_index].size > 256 << 20) return true;
    }
    return false;
}

/// True for an integrated GPU whose device-local heaps are all host-visible.
pub fn isUma(kind: vk.PhysicalDeviceType, mem: *const vk.PhysicalDeviceMemoryProperties) bool {
    if (kind != .integrated_gpu) return false;
    for (mem.memory_heaps[0..mem.memory_heap_count], 0..) |h, i| {
        if (!h.flags.device_local) continue;
        const visible = for (mem.memory_types[0..mem.memory_type_count]) |t| {
            if (t.heap_index == i and t.property_flags.host_visible) break true;
        } else false;
        if (!visible) return false;
    }
    return true;
}

/// The `GpuInfo` of `p` with device extensions `enabled`, using queue
/// family `gfx_family`.
pub fn gpuInfo(p: *const select.Probe, enabled: ExtSet, gfx_family: u32) GpuInfo {
    const l = &p.props.limits;
    return .{
        .api_version = p.api,
        .driver_name = p.driver_name,
        .device_name = p.props.device_name,
        .vendor_id = p.props.vendor_id,
        .device_id = p.props.device_id,
        .kind = p.kind(),
        .caps = capsOf(p, enabled),
        .limits = .{
            .max_image_dim_2d = l.max_image_dimension2d,
            .timestamp_period_ns = l.timestamp_period,
            .timestamp_valid_bits = if (gfx_family < p.queues.len) p.queues[gfx_family].timestamp_valid_bits else 0,
            .non_coherent_atom = l.non_coherent_atom_size,
            .min_storage_align = l.min_storage_buffer_offset_alignment,
            .max_sampled_images_update_after_bind = p.max_update_after_bind_sampled,
        },
        .rebar = hasRebar(&p.mem),
        .uma = isUma(p.kind(), &p.mem),
        .pipeline_cache_uuid = p.props.pipeline_cache_uuid,
    };
}

/// Input of `writeReport`.
pub const Report = struct {
    loader_path: []const u8 = "",
    loader_version: ?vk.Version = null,
    probes: []const select.Probe,
    chosen: ?usize,
    opts: select.SelectOptions = .{},
    /// Monotonic nanoseconds of device losses this session.
    losses: []const u64 = &.{},
};

pub const ReportFormat = enum { text, json };

/// Writes the `zg doctor gpu` report: one block per device in text, or
/// the JSON schema `{loader:{path,version}, devices:[{name,vendor,device,
/// driver,api,type,score,reject}], chosen, caps, extensions:[], losses:[]}`.
pub fn writeReport(w: *std.Io.Writer, r: Report, fmt: ReportFormat) std.Io.Writer.Error!void {
    switch (fmt) {
        .text => try writeText(w, r),
        .json => try writeJson(w, r),
    }
}

fn chosenCaps(r: Report) ?struct { Caps, ExtSet } {
    const i = r.chosen orelse return null;
    const p = &r.probes[i];
    const exts = @import("device.zig").deviceExtensions(p.exts, p.api, r.opts.surface);
    return .{ capsOf(p, exts), exts };
}

fn writeText(w: *std.Io.Writer, r: Report) std.Io.Writer.Error!void {
    if (r.loader_version) |v| {
        try w.print("loader: {s} (Vulkan {d}.{d}.{d})\n", .{ r.loader_path, v.major, v.minor, v.patch });
    } else try w.writeAll("loader: not found\n");
    for (r.probes, 0..) |*p, i| {
        const mark: []const u8 = if (r.chosen == i) " (chosen)" else "";
        try w.print("\ndevice {d}{s}: {s}\n", .{ i, mark, p.name() });
        try w.print("  type:    {s}\n  vendor:  0x{x:0>4}  device: 0x{x:0>4}\n  driver:  {s}\n  api:     {d}.{d}\n", .{ @tagName(p.kind()), p.props.vendor_id, p.props.device_id, p.driverName(), p.api.major, p.api.minor });
        if (p.reject) |why| {
            try w.print("  status:  rejected ({s})\n", .{@tagName(why)});
        } else try w.print("  score:   {d}\n", .{select.score(p, r.opts)});
    }
    if (chosenCaps(r)) |c| {
        try w.writeAll("\ncaps:");
        inline for (@typeInfo(Caps).@"struct".fields) |f| if (f.type == bool and @field(c[0], f.name)) try w.print(" {s}", .{f.name});
        try w.writeAll("\nextensions:");
        var it = c[1].iterator();
        while (it.next()) |e| try w.print(" {s}", .{vk.extensionInfo(e).name});
        try w.writeByte('\n');
    }
    if (r.losses.len > 0) try w.print("device losses: {d}\n", .{r.losses.len});
}

fn writeJson(w: *std.Io.Writer, r: Report) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("loader");
    try s.beginObject();
    try s.objectField("path");
    try s.write(r.loader_path);
    try s.objectField("version");
    if (r.loader_version) |v| {
        var buf: [32]u8 = undefined;
        try s.write(std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch }) catch unreachable);
    } else try s.write(null);
    try s.endObject();
    try s.objectField("devices");
    try s.beginArray();
    for (r.probes) |*p| {
        var api_buf: [16]u8 = undefined;
        try s.beginObject();
        try s.objectField("name");
        try s.write(p.name());
        try s.objectField("vendor");
        try s.write(p.props.vendor_id);
        try s.objectField("device");
        try s.write(p.props.device_id);
        try s.objectField("driver");
        try s.write(p.driverName());
        try s.objectField("api");
        try s.write(std.fmt.bufPrint(&api_buf, "{d}.{d}", .{ p.api.major, p.api.minor }) catch unreachable);
        try s.objectField("type");
        try s.write(@tagName(p.kind()));
        try s.objectField("score");
        if (p.reject == null) try s.write(select.score(p, r.opts)) else try s.write(null);
        try s.objectField("reject");
        if (p.reject) |why| try s.write(@tagName(why)) else try s.write(null);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("chosen");
    try s.write(r.chosen);
    const c = chosenCaps(r);
    try s.objectField("caps");
    try s.beginArray();
    if (c) |cc| inline for (@typeInfo(Caps).@"struct".fields) |f| if (f.type == bool and @field(cc[0], f.name)) try s.write(f.name);
    try s.endArray();
    try s.objectField("extensions");
    try s.beginArray();
    if (c) |cc| {
        var it = cc[1].iterator();
        while (it.next()) |e| try s.write(vk.extensionInfo(e).name);
    }
    try s.endArray();
    try s.objectField("losses");
    try s.write(r.losses);
    try s.endObject();
    try w.writeByte('\n');
}

fn reportFixture() [3]select.Probe {
    var ps: [3]select.Probe = .{ .{}, .{}, .{} };
    const names = [_][]const u8{ "Intel(R) Graphics", "NVIDIA GeForce RTX 4060", "Old GPU" };
    const kinds = [_]vk.PhysicalDeviceType{ .integrated_gpu, .discrete_gpu, .discrete_gpu };
    for (&ps, names, kinds, 0..) |*p, n, k, i| {
        @memcpy(p.props.device_name[0..n.len], n);
        p.props.device_type = k;
        p.props.vendor_id = @intCast(0x8086 + i);
        p.props.device_id = @intCast(0xa7a0 + i);
        @memcpy(p.driver_name[0..4], "test");
        p.api = .fromInt(vk.api_version_1_3);
        p.feat = .full();
        p.present_mask = 1;
        p.exts.insert(.khr_swapchain);
        p.exts.insert(.ext_memory_budget);
    }
    ps[2].api = .fromInt(vk.api_version_1_1);
    for (&ps) |*p| p.reject = select.rejectReason(p);
    return ps;
}

test "report: json schema stable" {
    const ps = reportFixture();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeReport(&out.writer, .{
        .loader_path = "libvulkan.so.1",
        .loader_version = .fromInt(vk.makeApiVersion(0, 1, 3, 275)),
        .probes = &ps,
        .chosen = select.choose(&ps, .{}),
        .losses = &.{ 1_000_000, 2_000_000 },
    }, .json);
    try @import("zg_core").testkit.golden.expectGoldenOpts(std.testing.io, @src(), "report_json", out.written(), .{ .root = @import("zg_options").package_root });
}

test "report: text" {
    const ps = reportFixture();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeReport(&out.writer, .{ .loader_path = "libvulkan.so.1", .loader_version = .fromInt(vk.makeApiVersion(0, 1, 3, 275)), .probes = &ps, .chosen = 1 }, .text);
    try @import("zg_core").testkit.golden.expectGoldenOpts(std.testing.io, @src(), "report_text", out.written(), .{ .root = @import("zg_options").package_root });
}

test "info: rebar and uma" {
    var mem: vk.PhysicalDeviceMemoryProperties = .{};
    mem.memory_heap_count = 2;
    mem.memory_heaps[0] = .{ .size = 8 << 30, .flags = .{ .device_local = true } };
    mem.memory_heaps[1] = .{ .size = 16 << 30 };
    mem.memory_type_count = 2;
    mem.memory_types[0] = .{ .property_flags = .{ .device_local = true }, .heap_index = 0 };
    mem.memory_types[1] = .{ .property_flags = .{ .host_visible = true, .host_coherent = true }, .heap_index = 1 };
    try std.testing.expect(!hasRebar(&mem));
    try std.testing.expect(!isUma(.integrated_gpu, &mem));
    mem.memory_types[0].property_flags.host_visible = true;
    try std.testing.expect(hasRebar(&mem));
    try std.testing.expect(isUma(.integrated_gpu, &mem));
    try std.testing.expect(!isUma(.discrete_gpu, &mem));
}
