//! The connection setup: the client's opening request and the server's
//! reply with its screens, depths and visuals (X11 protocol, section 8).

const std = @import("std");

/// A visual class (`TrueColor` is what we render to).
pub const VisualClass = enum(u8) {
    static_gray = 0,
    gray_scale = 1,
    static_color = 2,
    pseudo_color = 3,
    true_color = 4,
    direct_color = 5,
    _,
};

/// One visual.
pub const Visual = struct {
    id: u32,
    class: VisualClass,
    bits_per_rgb: u8,
    colormap_entries: u16,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
};

/// The visuals of one depth.
pub const Depth = struct {
    depth: u8,
    visuals: []const Visual,
};

/// One screen (root window).
pub const Screen = struct {
    root: u32,
    default_colormap: u32,
    white_pixel: u32,
    black_pixel: u32,
    current_input_masks: u32,
    width_px: u16,
    height_px: u16,
    width_mm: u16,
    height_mm: u16,
    root_visual: u32,
    root_depth: u8,
    depths: []const Depth,

    /// The visual with `id` and its depth.
    pub fn visual(s: *const Screen, id: u32) ?struct { visual: Visual, depth: u8 } {
        for (s.depths) |d| for (d.visuals) |v| if (v.id == id) return .{ .visual = v, .depth = d.depth };
        return null;
    }

    /// A 32-bit TrueColor visual with an alpha channel (ARGB), for
    /// transparent windows.
    pub fn argbVisual(s: *const Screen) ?Visual {
        for (s.depths) |d| {
            if (d.depth != 32) continue;
            for (d.visuals) |v| {
                if (v.class == .true_color and v.red_mask == 0xff0000 and v.green_mask == 0xff00 and v.blue_mask == 0xff) return v;
            }
        }
        return null;
    }
};

/// A pixmap format.
pub const Format = struct { depth: u8, bits_per_pixel: u8, scanline_pad: u8 };

/// The parsed setup reply. Slices live in the arena given to `parse`.
pub const Setup = struct {
    release: u32,
    resource_id_base: u32,
    resource_id_mask: u32,
    /// In 4-byte units.
    max_request_length: u16,
    min_keycode: u8,
    max_keycode: u8,
    image_byte_order: u8,
    vendor: []const u8,
    formats: []const Format,
    screens: []const Screen,
};

/// Setup errors; for `failed` and `authenticate` the server's reason is
/// logged.
pub const Error = error{ SetupFailed, AuthenticationRequired, Malformed, OutOfMemory };

fn pad4(n: usize) usize {
    return (4 - n % 4) % 4;
}

/// Writes the client's setup request (little-endian) into `out`.
pub fn writeRequest(out: *std.ArrayList(u8), gpa: std.mem.Allocator, auth_name: []const u8, auth_data: []const u8) !void {
    var hdr: [12]u8 = @splat(0);
    hdr[0] = 'l';
    std.mem.writeInt(u16, hdr[2..4], 11, .little);
    std.mem.writeInt(u16, hdr[4..6], 0, .little);
    std.mem.writeInt(u16, hdr[6..8], @intCast(auth_name.len), .little);
    std.mem.writeInt(u16, hdr[8..10], @intCast(auth_data.len), .little);
    try out.appendSlice(gpa, &hdr);
    try out.appendSlice(gpa, auth_name);
    try out.appendNTimes(gpa, 0, pad4(auth_name.len));
    try out.appendSlice(gpa, auth_data);
    try out.appendNTimes(gpa, 0, pad4(auth_data.len));
}

/// The total reply length given its first 8 bytes.
pub fn replyLen(prefix: *const [8]u8) usize {
    return 8 + @as(usize, std.mem.readInt(u16, prefix[6..8], .little)) * 4;
}

const Reader = struct {
    b: []const u8,
    i: usize = 0,

    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (r.b.len - r.i < n) return error.Malformed;
        defer r.i += n;
        return r.b[r.i..][0..n];
    }
    fn int(r: *Reader, comptime T: type) Error!T {
        return std.mem.readInt(T, (try r.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
    fn skip(r: *Reader, n: usize) Error!void {
        _ = try r.take(n);
    }
};

/// Parses a whole setup reply (`replyLen` bytes).
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) Error!Setup {
    if (bytes.len < 8) return error.Malformed;
    var r: Reader = .{ .b = bytes };
    const status = try r.int(u8);
    switch (status) {
        1 => {},
        0, 2 => {
            const reason_len: usize = if (status == 0) bytes[1] else std.mem.readInt(u16, bytes[6..8], .little) * 4;
            const reason = bytes[8..@min(bytes.len, 8 + reason_len)];
            std.log.scoped(.x11).info("X server refused the connection: {s}", .{std.mem.trimEnd(u8, reason, "\x00 \n")});
            return if (status == 0) error.SetupFailed else error.AuthenticationRequired;
        },
        else => return error.Malformed,
    }
    try r.skip(1);
    const major = try r.int(u16);
    if (major != 11) return error.Malformed;
    try r.skip(4); // minor, length
    var s: Setup = undefined;
    s.release = try r.int(u32);
    s.resource_id_base = try r.int(u32);
    s.resource_id_mask = try r.int(u32);
    try r.skip(4); // motion buffer size
    const vendor_len = try r.int(u16);
    s.max_request_length = try r.int(u16);
    const num_roots = try r.int(u8);
    const num_formats = try r.int(u8);
    s.image_byte_order = try r.int(u8);
    try r.skip(3); // bitmap bit order, scanline unit, scanline pad
    s.min_keycode = try r.int(u8);
    s.max_keycode = try r.int(u8);
    try r.skip(4);
    s.vendor = try r.take(vendor_len);
    try r.skip(pad4(vendor_len));
    const formats = try arena.alloc(Format, num_formats);
    for (formats) |*f| {
        f.* = .{ .depth = try r.int(u8), .bits_per_pixel = try r.int(u8), .scanline_pad = try r.int(u8) };
        try r.skip(5);
    }
    s.formats = formats;
    const screens = try arena.alloc(Screen, num_roots);
    for (screens) |*sc| {
        sc.root = try r.int(u32);
        sc.default_colormap = try r.int(u32);
        sc.white_pixel = try r.int(u32);
        sc.black_pixel = try r.int(u32);
        sc.current_input_masks = try r.int(u32);
        sc.width_px = try r.int(u16);
        sc.height_px = try r.int(u16);
        sc.width_mm = try r.int(u16);
        sc.height_mm = try r.int(u16);
        try r.skip(4); // min/max installed maps
        sc.root_visual = try r.int(u32);
        try r.skip(2); // backing stores, save unders
        sc.root_depth = try r.int(u8);
        const num_depths = try r.int(u8);
        const depths = try arena.alloc(Depth, num_depths);
        for (depths) |*d| {
            d.depth = try r.int(u8);
            try r.skip(1);
            const nv = try r.int(u16);
            try r.skip(4);
            if ((r.b.len - r.i) / 24 < nv) return error.Malformed;
            const vs = try arena.alloc(Visual, nv);
            for (vs) |*v| {
                v.id = try r.int(u32);
                v.class = @enumFromInt(try r.int(u8));
                v.bits_per_rgb = try r.int(u8);
                v.colormap_entries = try r.int(u16);
                v.red_mask = try r.int(u32);
                v.green_mask = try r.int(u32);
                v.blue_mask = try r.int(u32);
                try r.skip(4);
            }
            d.visuals = vs;
        }
        sc.depths = depths;
    }
    s.screens = screens;
    return s;
}

/// Builds a setup reply, for the fake server and tests.
pub fn writeReply(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: Setup) !void {
    const start = out.items.len;
    var w = Writer{ .out = out, .gpa = gpa };
    try w.int(u8, 1);
    try w.int(u8, 0);
    try w.int(u16, 11);
    try w.int(u16, 0);
    try w.int(u16, 0); // patched below
    try w.int(u32, s.release);
    try w.int(u32, s.resource_id_base);
    try w.int(u32, s.resource_id_mask);
    try w.int(u32, 0);
    try w.int(u16, @intCast(s.vendor.len));
    try w.int(u16, s.max_request_length);
    try w.int(u8, @intCast(s.screens.len));
    try w.int(u8, @intCast(s.formats.len));
    try w.int(u8, s.image_byte_order);
    try w.bytes(&.{ 0, 32, 32 });
    try w.int(u8, s.min_keycode);
    try w.int(u8, s.max_keycode);
    try w.bytes(&.{ 0, 0, 0, 0 });
    try w.bytes(s.vendor);
    try w.zeros(pad4(s.vendor.len));
    for (s.formats) |f| {
        try w.bytes(&.{ f.depth, f.bits_per_pixel, f.scanline_pad });
        try w.zeros(5);
    }
    for (s.screens) |sc| {
        for ([_]u32{ sc.root, sc.default_colormap, sc.white_pixel, sc.black_pixel, sc.current_input_masks }) |v| try w.int(u32, v);
        for ([_]u16{ sc.width_px, sc.height_px, sc.width_mm, sc.height_mm, 1, 1 }) |v| try w.int(u16, v);
        try w.int(u32, sc.root_visual);
        try w.bytes(&.{ 0, 0, sc.root_depth, @intCast(sc.depths.len) });
        for (sc.depths) |d| {
            try w.bytes(&.{ d.depth, 0 });
            try w.int(u16, @intCast(d.visuals.len));
            try w.zeros(4);
            for (d.visuals) |v| {
                try w.int(u32, v.id);
                try w.bytes(&.{ @intFromEnum(v.class), v.bits_per_rgb });
                try w.int(u16, v.colormap_entries);
                for ([_]u32{ v.red_mask, v.green_mask, v.blue_mask, 0 }) |m| try w.int(u32, m);
            }
        }
    }
    const extra = (out.items.len - start - 8) / 4;
    std.mem.writeInt(u16, out.items[start + 6 ..][0..2], @intCast(extra), .little);
}

const Writer = struct {
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,

    fn int(w: Writer, comptime T: type, v: T) !void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try w.out.appendSlice(w.gpa, &b);
    }
    fn bytes(w: Writer, b: []const u8) !void {
        try w.out.appendSlice(w.gpa, b);
    }
    fn zeros(w: Writer, n: usize) !void {
        try w.out.appendNTimes(w.gpa, 0, n);
    }
};

const testing = std.testing;

/// A two-screen setup used by tests.
pub const test_setup: Setup = .{
    .release = 12101012,
    .resource_id_base = 0x00400000,
    .resource_id_mask = 0x001fffff,
    .max_request_length = 65535,
    .min_keycode = 8,
    .max_keycode = 255,
    .image_byte_order = 0,
    .vendor = "The X.Org Foundation",
    .formats = &.{ .{ .depth = 24, .bits_per_pixel = 32, .scanline_pad = 32 }, .{ .depth = 32, .bits_per_pixel = 32, .scanline_pad = 32 } },
    .screens = &.{
        .{
            .root = 0x3d7,
            .default_colormap = 0x20,
            .white_pixel = 0xffffff,
            .black_pixel = 0,
            .current_input_masks = 0,
            .width_px = 1920,
            .height_px = 1080,
            .width_mm = 508,
            .height_mm = 285,
            .root_visual = 0x21,
            .root_depth = 24,
            .depths = &.{
                .{ .depth = 24, .visuals = &.{.{ .id = 0x21, .class = .true_color, .bits_per_rgb = 8, .colormap_entries = 256, .red_mask = 0xff0000, .green_mask = 0xff00, .blue_mask = 0xff }} },
                .{ .depth = 32, .visuals = &.{.{ .id = 0x5e, .class = .true_color, .bits_per_rgb = 8, .colormap_entries = 256, .red_mask = 0xff0000, .green_mask = 0xff00, .blue_mask = 0xff }} },
            },
        },
        .{
            .root = 0x4d0,
            .default_colormap = 0x30,
            .white_pixel = 0xffffff,
            .black_pixel = 0,
            .current_input_masks = 0,
            .width_px = 1280,
            .height_px = 1024,
            .width_mm = 338,
            .height_mm = 270,
            .root_visual = 0x31,
            .root_depth = 24,
            .depths = &.{.{ .depth = 24, .visuals = &.{.{ .id = 0x31, .class = .true_color, .bits_per_rgb = 8, .colormap_entries = 256, .red_mask = 0xff0000, .green_mask = 0xff00, .blue_mask = 0xff }} }},
        },
    },
};

test "setup parse with 2 screens/visuals" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try writeReply(&out, testing.allocator, test_setup);
    try testing.expectEqual(out.items.len, replyLen(out.items[0..8]));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try parse(arena.allocator(), out.items);
    try testing.expectEqualStrings("The X.Org Foundation", s.vendor);
    try testing.expectEqual(0x00400000, s.resource_id_base);
    try testing.expectEqual(2, s.screens.len);
    try testing.expectEqual(1920, s.screens[0].width_px);
    try testing.expectEqual(0x5e, s.screens[0].argbVisual().?.id);
    try testing.expectEqual(null, s.screens[1].argbVisual());
    try testing.expectEqual(24, s.screens[0].visual(0x21).?.depth);
    try testing.expectEqual(0x31, s.screens[1].root_visual);
    // Truncation is an error, never a crash.
    for (0..out.items.len) |n| {
        if (parse(arena.allocator(), out.items[0..n])) |_| {} else |_| {}
    }
}

test "setup request layout and refusals" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try writeRequest(&out, testing.allocator, "MIT-MAGIC-COOKIE-1", &(@as([16]u8, @splat(0xaa))));
    try testing.expectEqual(12 + 20 + 16, out.items.len);
    try testing.expectEqual('l', out.items[0]);
    try testing.expectEqual(11, std.mem.readInt(u16, out.items[2..4], .little));
    try testing.expectEqual(18, std.mem.readInt(u16, out.items[6..8], .little));
    try testing.expectEqual(16, std.mem.readInt(u16, out.items[8..10], .little));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const failed = [_]u8{ 0, 5, 11, 0, 0, 0, 2, 0 } ++ "nope!\x00\x00\x00".*;
    try testing.expectError(error.SetupFailed, parse(arena.allocator(), &failed));
    const auth = [_]u8{ 2, 0, 0, 0, 0, 0, 1, 0 } ++ "auth".*;
    try testing.expectError(error.AuthenticationRequired, parse(arena.allocator(), &auth));
}
