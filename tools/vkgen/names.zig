//! Zig names for Vulkan names.
//!
//! - Types drop `Vk` (`VkImageCreateInfo` → `ImageCreateInfo`); function
//!   pointer typedefs become `Pfn...` (`PFN_vkVoidFunction` → `PfnVoidFunction`).
//! - Fields, parameters and commands are snake_case (`pNext` → `p_next`,
//!   `vkCreateImage` → `create_image`).
//! - Enum values drop the prefix derived from their type, `_BIT`, and the
//!   type's own vendor tag (`VK_PRESENT_MODE_FIFO_KHR` in `VkPresentModeKHR`
//!   → `fifo`); values from other vendors keep their tag.
//! - Error names are PascalCase with tags kept (`VK_ERROR_OUT_OF_DATE_KHR`
//!   → `OutOfDateKHR`).

const std = @import("std");

pub const Error = error{OutOfMemory};

/// `VkFoo` → `Foo`, `PFN_vkFoo` → `PfnFoo`; other names are unchanged.
pub fn typeName(a: std.mem.Allocator, vk: []const u8) Error![]const u8 {
    if (std.mem.startsWith(u8, vk, "PFN_vk")) return std.mem.concat(a, u8, &.{ "Pfn", vk[6..] });
    if (std.mem.startsWith(u8, vk, "Vk")) return vk[2..];
    return vk;
}

/// camelCase or PascalCase → snake_case. Digits stay attached to the word
/// before them (`shaderInt64` → `shader_int64`, `vkQueueSubmit2` →
/// `queue_submit2`).
pub fn snake(a: std.mem.Allocator, s: []const u8) Error![]const u8 {
    return snakeOpts(a, s, false);
}

/// `snake` that also breaks before digits (`PipelineStage2` →
/// `pipeline_stage_2`), matching how vk.xml spells enum value prefixes.
pub fn snakeDigits(a: std.mem.Allocator, s: []const u8) Error![]const u8 {
    return snakeOpts(a, s, true);
}

fn snakeOpts(a: std.mem.Allocator, s: []const u8, digit_break: bool) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s, 0..) |c, i| {
        const prev: u8 = if (i > 0) s[i - 1] else 0;
        const next: u8 = if (i + 1 < s.len) s[i + 1] else 0;
        if (std.ascii.isUpper(c)) {
            if (i > 0 and (std.ascii.isLower(prev) or
                (std.ascii.isUpper(prev) and std.ascii.isLower(next)) or
                (std.ascii.isDigit(prev) and (std.ascii.isLower(next) or isTagRest(s[i..])))))
                try out.append(a, '_');
            try out.append(a, std.ascii.toLower(c));
        } else if (std.ascii.isDigit(c)) {
            if (digit_break and i > 0 and std.ascii.isAlphabetic(prev)) try out.append(a, '_');
            try out.append(a, c);
        } else try out.append(a, c);
    }
    return out.items;
}

/// `vkCreateImage` → `create_image`.
pub fn commandName(a: std.mem.Allocator, vk: []const u8) Error![]const u8 {
    return snake(a, if (std.mem.startsWith(u8, vk, "vk")) vk[2..] else vk);
}

/// `VK_MAX_EXTENSION_NAME_SIZE` → `max_extension_name_size`.
pub fn constName(a: std.mem.Allocator, vk: []const u8) Error![]const u8 {
    const s = if (std.mem.startsWith(u8, vk, "VK_")) vk[3..] else vk;
    return std.ascii.allocLowerString(a, s);
}

/// `VK_KHR_swapchain` → `khr_swapchain`.
pub fn extensionName(a: std.mem.Allocator, vk: []const u8) Error![]const u8 {
    return constName(a, vk);
}

/// The value prefix of an enum or FlagBits type: `VkImageUsageFlagBits` →
/// `VK_IMAGE_USAGE_`, `VkPipelineStageFlagBits2` → `VK_PIPELINE_STAGE_2_`.
pub fn enumPrefix(a: std.mem.Allocator, type_name: []const u8, tag: ?[]const u8) Error![]const u8 {
    var s = if (std.mem.startsWith(u8, type_name, "Vk")) type_name[2..] else type_name;
    if (tag) |t| s = s[0 .. s.len - t.len];
    var buf: std.ArrayList(u8) = .empty;
    if (std.mem.indexOf(u8, s, "FlagBits")) |k| {
        try buf.appendSlice(a, s[0..k]);
        try buf.appendSlice(a, s[k + 8 ..]);
        s = buf.items;
    }
    const sn = try snakeDigits(a, s);
    const up = try std.ascii.allocUpperString(a, sn);
    return std.mem.concat(a, u8, &.{ "VK_", up, "_" });
}

/// The Zig name of value `vk` in a type with prefix `prefix` and vendor tag
/// `tag`. `strip_tag = false` keeps the tag (used when stripping collides).
pub fn enumValueName(a: std.mem.Allocator, prefix: []const u8, vk: []const u8, tag: ?[]const u8, strip_tag: bool) Error![]const u8 {
    var s = if (std.mem.startsWith(u8, vk, prefix) and vk.len > prefix.len)
        vk[prefix.len..]
    else if (std.mem.startsWith(u8, vk, "VK_"))
        vk[3..]
    else
        vk;
    var buf: std.ArrayList(u8) = .empty;
    if (strip_tag) if (tag) |t| {
        if (s.len > t.len + 1 and std.mem.endsWith(u8, s, t) and s[s.len - t.len - 1] == '_') s = s[0 .. s.len - t.len - 1];
    };
    // Drop `_BIT`, also before a trailing vendor tag (`_BIT_KHR` → `_KHR`).
    if (std.mem.endsWith(u8, s, "_BIT")) {
        s = s[0 .. s.len - 4];
    } else if (std.mem.lastIndexOf(u8, s, "_BIT_")) |k| {
        const rest = s[k + 5 ..];
        if (rest.len > 0 and isAllUpperAlpha(rest)) {
            try buf.appendSlice(a, s[0..k]);
            try buf.append(a, '_');
            try buf.appendSlice(a, rest);
            s = buf.items;
        }
    }
    if (s.len == 0) s = vk;
    return std.ascii.allocLowerString(a, s);
}

/// `VK_ERROR_OUT_OF_DATE_KHR` → `OutOfDateKHR` (`tags` are kept upper case).
pub fn errorName(a: std.mem.Allocator, vk: []const u8, tags: []const []const u8) Error![]const u8 {
    const s = if (std.mem.startsWith(u8, vk, "VK_ERROR_")) vk[9..] else vk;
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '_');
    while (it.next()) |w| {
        if (w.len == 0) continue;
        const is_tag = for (tags) |t| {
            if (std.mem.eql(u8, t, w)) break true;
        } else false;
        if (is_tag) {
            try out.appendSlice(a, w);
            continue;
        }
        try out.append(a, std.ascii.toUpper(w[0]));
        for (w[1..]) |c| try out.append(a, std.ascii.toLower(c));
    }
    return out.items;
}

/// A vendor tag running to the end of the name (`KHR` in `Capabilities2KHR`).
fn isTagRest(s: []const u8) bool {
    return s.len >= 2 and isAllUpperAlpha(s);
}

fn isAllUpperAlpha(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isUpper(c)) return false;
    return true;
}

/// True if `name` must be written `@"name"`.
pub fn needsQuote(name: []const u8) bool {
    return !std.zig.isValidId(name) or std.zig.primitives.isPrimitive(name);
}

test "names: conversions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const T = std.testing;
    try T.expectEqualStrings("ImageCreateInfo", try typeName(a, "VkImageCreateInfo"));
    try T.expectEqualStrings("PfnVoidFunction", try typeName(a, "PFN_vkVoidFunction"));
    try T.expectEqualStrings("uint32_t", try typeName(a, "uint32_t"));

    const fields = [_][2][]const u8{
        .{ "pNext", "p_next" },
        .{ "sType", "s_type" },
        .{ "ppEnabledExtensionNames", "pp_enabled_extension_names" },
        .{ "deviceID", "device_id" },
        .{ "deviceLUIDValid", "device_luid_valid" },
        .{ "maxImageDimension2D", "max_image_dimension2d" },
        .{ "storageBuffer16BitAccess", "storage_buffer16_bit_access" },
        .{ "shaderInt64", "shader_int64" },
        .{ "float32", "float32" },
        .{ "textureCompressionASTC_HDR", "texture_compression_astc_hdr" },
        .{ "pfnUserCallback", "pfn_user_callback" },
    };
    for (fields) |f| try T.expectEqualStrings(f[1], try snake(a, f[0]));

    try T.expectEqualStrings("create_image", try commandName(a, "vkCreateImage"));
    try T.expectEqualStrings("cmd_begin_rendering_khr", try commandName(a, "vkCmdBeginRenderingKHR"));
    try T.expectEqualStrings("queue_submit2", try commandName(a, "vkQueueSubmit2"));
    try T.expectEqualStrings("get_physical_device_surface_capabilities2_khr", try commandName(a, "vkGetPhysicalDeviceSurfaceCapabilities2KHR"));
    try T.expectEqualStrings("image2d_view_of3d", try snake(a, "image2DViewOf3D"));
    try T.expectEqualStrings("max_extension_name_size", try constName(a, "VK_MAX_EXTENSION_NAME_SIZE"));

    try T.expectEqualStrings("VK_IMAGE_USAGE_", try enumPrefix(a, "VkImageUsageFlagBits", null));
    try T.expectEqualStrings("VK_PIPELINE_STAGE_2_", try enumPrefix(a, "VkPipelineStageFlagBits2", null));
    try T.expectEqualStrings("VK_PRESENT_MODE_", try enumPrefix(a, "VkPresentModeKHR", "KHR"));
    try T.expectEqualStrings("VK_IMAGE_TYPE_", try enumPrefix(a, "VkImageType", null));

    try T.expectEqualStrings("r8_unorm", try enumValueName(a, "VK_FORMAT_", "VK_FORMAT_R8_UNORM", null, true));
    try T.expectEqualStrings("2d", try enumValueName(a, "VK_IMAGE_TYPE_", "VK_IMAGE_TYPE_2D", null, true));
    try T.expectEqualStrings("transfer_src", try enumValueName(a, "VK_IMAGE_USAGE_", "VK_IMAGE_USAGE_TRANSFER_SRC_BIT", null, true));
    try T.expectEqualStrings("fifo", try enumValueName(a, "VK_PRESENT_MODE_", "VK_PRESENT_MODE_FIFO_KHR", "KHR", true));
    try T.expectEqualStrings("fifo_khr", try enumValueName(a, "VK_PRESENT_MODE_", "VK_PRESENT_MODE_FIFO_KHR", "KHR", false));
    try T.expectEqualStrings("dma_buf_ext", try enumValueName(a, "VK_EXTERNAL_MEMORY_HANDLE_TYPE_", "VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT", null, true));
    try T.expectEqualStrings("error_out_of_date_khr", try enumValueName(a, "VK_RESULT_", "VK_ERROR_OUT_OF_DATE_KHR", null, true));
    try T.expectEqualStrings("1", try enumValueName(a, "VK_SAMPLE_COUNT_", "VK_SAMPLE_COUNT_1_BIT", null, true));

    try T.expectEqualStrings("OutOfDateKHR", try errorName(a, "VK_ERROR_OUT_OF_DATE_KHR", &.{ "KHR", "EXT" }));
    try T.expectEqualStrings("OutOfHostMemory", try errorName(a, "VK_ERROR_OUT_OF_HOST_MEMORY", &.{"KHR"}));

    try T.expect(needsQuote("2d"));
    try T.expect(needsQuote("type"));
    try T.expect(needsQuote("u8"));
    try T.expect(!needsQuote("p_next"));
}
