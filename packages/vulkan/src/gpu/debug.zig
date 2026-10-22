//! `VK_EXT_debug_utils`: a messenger that routes validation and driver
//! messages into the zg_core log (scope `vk`), object names and command
//! buffer labels (E02.F02.S01.T01).
//!
//! The callback may run on any thread and never allocates: each message is
//! formatted into a 1 KiB stack buffer and truncated.

const std = @import("std");
const vk = @import("../vk/vk.zig");
const tables = @import("../loader/tables.zig");

const log = std.log.scoped(.vk);

/// Counts what the messenger saw. Lives as long as the instance.
pub const Sink = struct {
    errors: std.atomic.Value(u32) = .init(0),
    warnings: std.atomic.Value(u32) = .init(0),
    /// The message id name (VUID) of the last error, `last_vuid_len` bytes.
    last_vuid: [128]u8 = undefined,
    last_vuid_len: std.atomic.Value(u8) = .init(0),
    /// Receives each formatted message instead of `std.log` (tests capture
    /// messages here, since an error log fails a Zig test).
    emit: ?*const fn (level: std.log.Level, msg: []const u8) void = null,

    /// The last error's VUID, or "" (racy if errors arrive concurrently).
    pub fn lastVuid(self: *const Sink) []const u8 {
        return self.last_vuid[0..self.last_vuid_len.load(.acquire)];
    }
};

/// Severities the messenger reports (VERBOSE is dropped).
pub const severities: vk.DebugUtilsMessageSeverityFlagsEXT = .{ .info = true, .warning = true, .@"error" = true };
/// Message types the messenger reports.
pub const message_types: vk.DebugUtilsMessageTypeFlagsEXT = .{ .general = true, .validation = true, .performance = true };

/// The create info for a messenger reporting into `sink`. Also chained into
/// `VkInstanceCreateInfo` to capture instance creation and destruction.
pub fn createInfo(sink: *Sink) vk.DebugUtilsMessengerCreateInfoEXT {
    return .{
        .message_severity = severities,
        .message_type = message_types,
        .pfn_user_callback = callback,
        .p_user_data = sink,
    };
}

/// A debug-utils messenger.
pub const Debug = struct {
    messenger: vk.DebugUtilsMessengerEXT,

    pub fn init(inst: vk.Instance, d: *const tables.Instance, sink: *Sink) vk.Error!Debug {
        const ci = createInfo(sink);
        var m: vk.DebugUtilsMessengerEXT = .null_handle;
        _ = try vk.check(d.create_debug_utils_messenger_ext(inst, &ci, null, &m));
        return .{ .messenger = m };
    }

    /// Destroy before the instance.
    pub fn deinit(self: *Debug, inst: vk.Instance, d: *const tables.Instance) void {
        d.destroy_debug_utils_messenger_ext(inst, self.messenger, null);
        self.* = undefined;
    }

    /// Opens a label region in `cb`; close it with `endLabel`.
    pub fn label(self: *const Debug, dd: *const tables.Device, cb: vk.CommandBuffer, name: [:0]const u8, color: [4]f32) void {
        _ = self;
        dd.cmd_begin_debug_utils_label_ext(cb, &.{ .p_label_name = name, .color = color });
    }

    /// Closes the innermost label region in `cb`.
    pub fn endLabel(self: *const Debug, dd: *const tables.Device, cb: vk.CommandBuffer) void {
        _ = self;
        dd.cmd_end_debug_utils_label_ext(cb);
    }
};

/// The `VkObjectType` of a handle type.
pub fn objectType(comptime H: type) vk.ObjectType {
    const map = .{
        .{ vk.Instance, .instance },                         .{ vk.PhysicalDevice, .physical_device },
        .{ vk.Device, .device },                             .{ vk.Queue, .queue },
        .{ vk.Semaphore, .semaphore },                       .{ vk.CommandBuffer, .command_buffer },
        .{ vk.Fence, .fence },                               .{ vk.DeviceMemory, .device_memory },
        .{ vk.Buffer, .buffer },                             .{ vk.Image, .image },
        .{ vk.QueryPool, .query_pool },                      .{ vk.ImageView, .image_view },
        .{ vk.ShaderModule, .shader_module },                .{ vk.PipelineCache, .pipeline_cache },
        .{ vk.PipelineLayout, .pipeline_layout },            .{ vk.Pipeline, .pipeline },
        .{ vk.DescriptorSetLayout, .descriptor_set_layout }, .{ vk.Sampler, .sampler },
        .{ vk.DescriptorPool, .descriptor_pool },            .{ vk.DescriptorSet, .descriptor_set },
        .{ vk.CommandPool, .command_pool },                  .{ vk.SwapchainKHR, .swapchain_khr },
    };
    inline for (map) |e| if (e[0] == H) return e[1];
    @compileError("no VkObjectType for " ++ @typeName(H));
}

/// Formats a callback message as `[{id name}] {message}` followed by the
/// named objects and labels, truncated to `buf`.
pub fn format(buf: []u8, data: *const vk.DebugUtilsMessengerCallbackDataEXT) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    write(&w, data) catch {
        const ellipsis = "...";
        if (buf.len >= ellipsis.len) @memcpy(buf[buf.len - ellipsis.len ..], ellipsis);
        return buf;
    };
    return w.buffered();
}

fn write(w: *std.Io.Writer, data: *const vk.DebugUtilsMessengerCallbackDataEXT) std.Io.Writer.Error!void {
    const id = if (data.p_message_id_name) |p| std.mem.span(p) else "";
    const msg = if (data.p_message) |p| std.mem.span(p) else "";
    try w.print("[{s}] {s}", .{ id, msg });
    if (data.p_objects) |objs| for (objs[0..data.object_count]) |o| {
        const n = if (o.p_object_name) |p| std.mem.span(p) else continue;
        try w.print(" (object {s} 0x{x} \"{s}\")", .{ @tagName(o.object_type), o.object_handle, n });
    };
    if (data.p_cmd_buf_labels) |ls| for (ls[0..data.cmd_buf_label_count]) |l| {
        if (l.p_label_name) |p| try w.print(" (label \"{s}\")", .{std.mem.span(p)});
    };
}

/// The messenger callback: ERROR → err, WARNING → warn, INFO → debug.
pub fn callback(
    severity: vk.DebugUtilsMessageSeverityFlagBitsEXT,
    types: vk.DebugUtilsMessageTypeFlagsEXT,
    data: *const vk.DebugUtilsMessengerCallbackDataEXT,
    user: ?*anyopaque,
) callconv(vk.cc) vk.Bool32 {
    _ = types;
    const sink: ?*Sink = @ptrCast(@alignCast(user));
    const level: std.log.Level = if (severity.@"error") .err else if (severity.warning) .warn else if (severity.info) .debug else return .false;
    var buf: [1024]u8 = undefined;
    const msg = format(&buf, data);
    if (sink) |s| {
        switch (level) {
            .err => {
                _ = s.errors.fetchAdd(1, .monotonic);
                const id = if (data.p_message_id_name) |p| std.mem.span(p) else "";
                const n = @min(id.len, s.last_vuid.len);
                @memcpy(s.last_vuid[0..n], id[0..n]);
                s.last_vuid_len.store(@intCast(n), .release);
            },
            .warn => _ = s.warnings.fetchAdd(1, .monotonic),
            else => {},
        }
        if (s.emit) |emit| {
            emit(level, msg);
            return .false;
        }
    }
    switch (level) {
        .err => log.err("{s}", .{msg}),
        .warn => log.warn("{s}", .{msg}),
        else => log.debug("{s}", .{msg}),
    }
    return .false;
}

var test_last: [1024]u8 = undefined;
var test_last_len: usize = 0;
var test_last_level: std.log.Level = .debug;

fn testEmit(level: std.log.Level, msg: []const u8) void {
    @memcpy(test_last[0..msg.len], msg);
    test_last_len = msg.len;
    test_last_level = level;
}

test "debug: callback formats and counts without allocation" {
    var sink: Sink = .{ .emit = testEmit };
    const objs = [_]vk.DebugUtilsObjectNameInfoEXT{
        .{ .object_type = .image, .object_handle = 0x1234, .p_object_name = "atlas-page-0" },
        .{ .object_type = .device, .object_handle = 0x1 },
    };
    const labels = [_]vk.DebugUtilsLabelEXT{.{ .p_label_name = "layer-17", .color = .{ 0, 0, 0, 0 } }};
    const data: vk.DebugUtilsMessengerCallbackDataEXT = .{
        .p_message_id_name = "VUID-VkImageCreateInfo-extent-00944",
        .message_id_number = 7,
        .p_message = "extent.width is 0",
        .object_count = objs.len,
        .p_objects = &objs,
        .cmd_buf_label_count = labels.len,
        .p_cmd_buf_labels = &labels,
    };
    // `callback` has no allocator to fail; the stack buffer is all it uses.
    try std.testing.expectEqual(vk.Bool32.false, callback(.{ .@"error" = true }, .{ .validation = true }, &data, &sink));
    try std.testing.expectEqual(@as(u32, 1), sink.errors.load(.monotonic));
    try std.testing.expectEqualStrings("VUID-VkImageCreateInfo-extent-00944", sink.lastVuid());
    try std.testing.expectEqual(std.log.Level.err, test_last_level);
    try std.testing.expectEqualStrings(
        "[VUID-VkImageCreateInfo-extent-00944] extent.width is 0 (object image 0x1234 \"atlas-page-0\") (label \"layer-17\")",
        test_last[0..test_last_len],
    );

    _ = callback(.{ .warning = true }, .{ .performance = true }, &data, &sink);
    try std.testing.expectEqual(@as(u32, 1), sink.warnings.load(.monotonic));
    try std.testing.expectEqual(std.log.Level.warn, test_last_level);
    // VERBOSE is dropped.
    test_last_len = 0;
    _ = callback(.{ .verbose = true }, .{ .general = true }, &data, &sink);
    try std.testing.expectEqual(@as(usize, 0), test_last_len);
}

test "debug: long messages are truncated" {
    const long = "x" ** 2000;
    const data: vk.DebugUtilsMessengerCallbackDataEXT = .{ .message_id_number = 0, .p_message = long };
    var buf: [64]u8 = undefined;
    const out = format(&buf, &data);
    try std.testing.expectEqual(@as(usize, 64), out.len);
    try std.testing.expect(std.mem.endsWith(u8, out, "..."));
}

test "debug: object types" {
    try std.testing.expectEqual(vk.ObjectType.image, objectType(vk.Image));
    try std.testing.expectEqual(vk.ObjectType.swapchain_khr, objectType(vk.SwapchainKHR));
}
