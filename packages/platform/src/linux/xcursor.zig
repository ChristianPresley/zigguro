//! Xcursor themes (Xcursor(3)): the file parser, theme lookup through
//! `Inherits=`, and CSS cursor names with their legacy fallbacks. Shared
//! by the Wayland fallback path (no cursor-shape-v1) and the X11 backend.
//! Parsing is pure; only `loadXcursor` reads files.

const std = @import("std");
const Allocator = std.mem.Allocator;
const CursorShape = @import("../api/cursor.zig").CursorShape;

/// One cursor image: ARGB premultiplied, row-major.
pub const CursorImage = struct {
    width: u32,
    height: u32,
    hot_x: u32,
    hot_y: u32,
    /// Frame time for animated cursors, in ms.
    delay_ms: u32,
    pixels: []u32,
};

/// The frames of one nominal size.
pub const CursorFrames = struct {
    frames: []CursorImage,
    nominal_size: u32,

    /// Frees the frames.
    pub fn deinit(f: *CursorFrames, gpa: Allocator) void {
        for (f.frames) |fr| gpa.free(fr.pixels);
        gpa.free(f.frames);
        f.* = undefined;
    }
};

/// Parse errors.
pub const ParseError = error{ BadMagic, Malformed, TooLarge, NoImages, OutOfMemory };

const magic: u32 = 0x72756358; // "Xcur" little-endian
const image_type: u32 = 0xfffd0002;
const max_dim: u32 = 0x7fff;
/// Decoded pixel bytes allowed per file.
const max_bytes: usize = 16 * 1024 * 1024;

/// The frames in `file` whose nominal size is closest to `size_px`.
pub fn parse(gpa: Allocator, file: []const u8, size_px: u32) ParseError!CursorFrames {
    if (file.len < 16) return error.Malformed;
    if (rd(file, 0) != magic) return error.BadMagic;
    const header = rd(file, 4);
    const ntoc = rd(file, 12);
    if (header < 16 or ntoc > 4096) return error.Malformed;
    const toc_end = @as(usize, header) + @as(usize, ntoc) * 12;
    if (toc_end > file.len) return error.Malformed;

    // The nearest nominal size among image entries.
    var best: ?u32 = null;
    for (0..ntoc) |i| {
        const e = header + i * 12;
        if (rd(file, e) != image_type) continue;
        const sz = rd(file, e + 4);
        if (best == null or dist(sz, size_px) < dist(best.?, size_px)) best = sz;
    }
    const nominal = best orelse return error.NoImages;

    var frames: std.ArrayList(CursorImage) = .empty;
    errdefer {
        for (frames.items) |fr| gpa.free(fr.pixels);
        frames.deinit(gpa);
    }
    var total: usize = 0;
    for (0..ntoc) |i| {
        const e = header + i * 12;
        if (rd(file, e) != image_type or rd(file, e + 4) != nominal) continue;
        const pos: usize = rd(file, e + 8);
        if (pos > file.len or file.len - pos < 36) return error.Malformed;
        if (rd(file, pos) != 36 or rd(file, pos + 4) != image_type) return error.Malformed;
        const w = rd(file, pos + 16);
        const h = rd(file, pos + 20);
        const hx = rd(file, pos + 24);
        const hy = rd(file, pos + 28);
        if (w == 0 or h == 0 or w > max_dim or h > max_dim or hx > w or hy > h) return error.Malformed;
        const n = @as(usize, w) * h;
        total += n * 4;
        if (total > max_bytes) return error.TooLarge;
        if ((file.len - pos - 36) / 4 < n) return error.Malformed;
        const px = try gpa.alloc(u32, n);
        errdefer gpa.free(px);
        for (px, 0..) |*p, k| p.* = rd(file, pos + 36 + k * 4);
        try frames.append(gpa, .{ .width = w, .height = h, .hot_x = hx, .hot_y = hy, .delay_ms = rd(file, pos + 32), .pixels = px });
    }
    return .{ .frames = try frames.toOwnedSlice(gpa), .nominal_size = nominal };
}

fn dist(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

fn rd(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

/// Xcursor names for `shape`: the CSS name first, then legacy names.
pub fn cssToXcursorNames(shape: CursorShape) []const []const u8 {
    return switch (shape) {
        .default => &.{ "default", "left_ptr", "arrow" },
        .text => &.{ "text", "xterm", "ibeam" },
        .pointer => &.{ "pointer", "hand2", "pointing_hand", "hand1" },
        .wait => &.{ "wait", "watch" },
        .progress => &.{ "progress", "left_ptr_watch", "half-busy" },
        .crosshair => &.{ "crosshair", "cross", "tcross" },
        .not_allowed => &.{ "not-allowed", "crossed_circle", "forbidden" },
        .grab => &.{ "grab", "openhand", "hand1" },
        .grabbing => &.{ "grabbing", "closedhand", "fleur" },
        .move => &.{ "move", "fleur", "size_all" },
        .copy => &.{ "copy", "dnd-copy" },
        .alias => &.{ "alias", "dnd-link" },
        .no_drop => &.{ "no-drop", "dnd-no-drop", "forbidden" },
        .ew_resize => &.{ "ew-resize", "sb_h_double_arrow", "size_hor" },
        .ns_resize => &.{ "ns-resize", "sb_v_double_arrow", "size_ver" },
        .nesw_resize => &.{ "nesw-resize", "fd_double_arrow", "size_bdiag" },
        .nwse_resize => &.{ "nwse-resize", "bd_double_arrow", "size_fdiag" },
        .col_resize => &.{ "col-resize", "sb_h_double_arrow", "split_h" },
        .row_resize => &.{ "row-resize", "sb_v_double_arrow", "split_v" },
        .all_scroll => &.{ "all-scroll", "fleur" },
        .zoom_in => &.{ "zoom-in", "zoom_in" },
        .zoom_out => &.{ "zoom-out", "zoom_out" },
        .context_menu => &.{ "context-menu", "left_ptr" },
        .help => &.{ "help", "question_arrow", "whats_this" },
        .cell => &.{ "cell", "plus" },
        .vertical_text => &.{ "vertical-text", "xterm" },
        .hidden => &.{},
    };
}

/// Where themes are searched and which one to use.
pub const SearchPath = struct {
    /// Directories, in order.
    dirs: []const []const u8,
    theme: []const u8 = "default",
    /// Prepended to every path opened (a fake root in tests).
    root: []const u8 = "",
};

/// The upstream defaults below `home` when `XCURSOR_PATH` is unset.
pub fn defaultDirs(buf: [][]const u8, path_buf: []u8, home: ?[]const u8) [][]const u8 {
    var n: usize = 0;
    var used: usize = 0;
    if (home) |h| {
        for ([_][]const u8{ "/.local/share/icons", "/.icons" }) |suffix| {
            const s = std.fmt.bufPrint(path_buf[used..], "{s}{s}", .{ h, suffix }) catch continue;
            used += s.len;
            buf[n] = s;
            n += 1;
        }
    }
    for ([_][]const u8{ "/usr/share/icons", "/usr/share/pixmaps" }) |d| {
        buf[n] = d;
        n += 1;
    }
    return buf[0..n];
}

/// Loads `name` from `sp.theme` (following `Inherits=`, then `default`)
/// at the size closest to `size_px`; null if no theme has it.
pub fn loadXcursor(gpa: Allocator, io: std.Io, sp: SearchPath, name: []const u8, size_px: u32) !?CursorFrames {
    var seen: [8][]const u8 = undefined;
    var n_seen: usize = 0;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    if (try loadTheme(gpa, arena.allocator(), io, sp, sp.theme, name, size_px, &seen, &n_seen, 0)) |f| return f;
    if (!std.mem.eql(u8, sp.theme, "default")) {
        for (seen[0..n_seen]) |t| if (std.mem.eql(u8, t, "default")) return null;
        return loadTheme(gpa, arena.allocator(), io, sp, "default", name, size_px, &seen, &n_seen, 0);
    }
    return null;
}

fn loadTheme(gpa: Allocator, scratch: Allocator, io: std.Io, sp: SearchPath, theme: []const u8, name: []const u8, size_px: u32, seen: *[8][]const u8, n_seen: *usize, depth: usize) !?CursorFrames {
    if (depth >= 8 or n_seen.* >= seen.len) return null;
    for (seen[0..n_seen.*]) |t| if (std.mem.eql(u8, t, theme)) return null;
    seen[n_seen.*] = try scratch.dupe(u8, theme);
    n_seen.* += 1;
    for (sp.dirs) |dir| {
        const path = try std.fmt.allocPrint(scratch, "{s}{s}/{s}/cursors/{s}", .{ sp.root, dir, theme, name });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, scratch, .limited(max_bytes + 64 * 1024)) catch continue;
        return parse(gpa, bytes, size_px) catch continue;
    }
    for (sp.dirs) |dir| {
        const path = try std.fmt.allocPrint(scratch, "{s}{s}/{s}/index.theme", .{ sp.root, dir, theme });
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, scratch, .limited(64 * 1024)) catch continue;
        var parents = inheritsOf(text);
        while (parents.next()) |parent| {
            if (try loadTheme(gpa, scratch, io, sp, parent, name, size_px, seen, n_seen, depth + 1)) |f| return f;
        }
        break;
    }
    return null;
}

/// The comma-separated `Inherits=` names of an index.theme.
fn inheritsOf(text: []const u8) std.mem.TokenIterator(u8, .any) {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "Inherits")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.trim(u8, line["Inherits".len..eq], " \t").len != 0) continue;
        return std.mem.tokenizeAny(u8, line[eq + 1 ..], ", \t\"");
    }
    return std.mem.tokenizeAny(u8, "", ",");
}

// ---- tests ----

const testing = std.testing;

/// A test encoder: `images` as (nominal size, width, height, hot, delay,
/// fill colour).
const TestImage = struct { size: u32, w: u32, h: u32, hx: u32, hy: u32, delay: u32, color: u32 };

fn encode(gpa: Allocator, images: []const TestImage) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const w = struct {
        fn u(o: *std.ArrayList(u8), a: Allocator, v: u32) !void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, .little);
            try o.appendSlice(a, &b);
        }
    }.u;
    try w(&out, gpa, magic);
    try w(&out, gpa, 16);
    try w(&out, gpa, 0x10000);
    try w(&out, gpa, @intCast(images.len));
    var pos: u32 = 16 + @as(u32, @intCast(images.len)) * 12;
    for (images) |im| {
        try w(&out, gpa, image_type);
        try w(&out, gpa, im.size);
        try w(&out, gpa, pos);
        pos += 36 + im.w * im.h * 4;
    }
    for (images) |im| {
        for ([_]u32{ 36, image_type, im.size, 1, im.w, im.h, im.hx, im.hy, im.delay }) |v| try w(&out, gpa, v);
        for (0..im.w * im.h) |_| try w(&out, gpa, im.color);
    }
    return out.toOwnedSlice(gpa);
}

test "Xcursor parse: 2 sizes x 2 frames; nearest nominal size" {
    const file = try encode(testing.allocator, &.{
        .{ .size = 24, .w = 24, .h = 24, .hx = 3, .hy = 4, .delay = 50, .color = 0xff000000 },
        .{ .size = 24, .w = 24, .h = 24, .hx = 3, .hy = 4, .delay = 50, .color = 0xffffffff },
        .{ .size = 48, .w = 48, .h = 48, .hx = 6, .hy = 8, .delay = 50, .color = 0xff112233 },
        .{ .size = 48, .w = 48, .h = 48, .hx = 6, .hy = 8, .delay = 70, .color = 0xff445566 },
    });
    defer testing.allocator.free(file);
    var small = try parse(testing.allocator, file, 30);
    defer small.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 24), small.nominal_size);
    try testing.expectEqual(@as(usize, 2), small.frames.len);
    try testing.expectEqual(@as(u32, 0xffffffff), small.frames[1].pixels[0]);
    var big = try parse(testing.allocator, file, 40);
    defer big.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 48), big.nominal_size);
    try testing.expectEqual(@as(u32, 6), big.frames[0].hot_x);
    try testing.expectEqual(@as(u32, 70), big.frames[1].delay_ms);
    try testing.expectEqual(@as(u32, 0xff112233), big.frames[0].pixels[48 * 48 - 1]);
}

test "Xcursor parse: malformed files give errors, not crashes" {
    try testing.expectError(error.BadMagic, parse(testing.allocator, "Xcux" ++ "\x10\x00\x00\x00" ** 3, 24));
    const file = try encode(testing.allocator, &.{.{ .size = 24, .w = 4, .h = 4, .hx = 0, .hy = 0, .delay = 0, .color = 1 }});
    defer testing.allocator.free(file);
    // Truncated pixels.
    try testing.expectError(error.Malformed, parse(testing.allocator, file[0 .. file.len - 4], 24));
    // TOC entry pointing past the end.
    const bad = try testing.allocator.dupe(u8, file);
    defer testing.allocator.free(bad);
    std.mem.writeInt(u32, bad[24..28], 0xfffffff0, .little);
    try testing.expectError(error.Malformed, parse(testing.allocator, bad, 24));
    // Huge TOC.
    std.mem.writeInt(u32, bad[12..16], 0xffffff, .little);
    try testing.expectError(error.Malformed, parse(testing.allocator, bad, 24));
    // Fuzz-ish: every truncation of a valid file.
    for (0..file.len) |n| {
        if (parse(testing.allocator, file[0..n], 24)) |f| {
            var ff = f;
            ff.deinit(testing.allocator);
        } else |_| {}
    }
}

test "Xcursor parse: random bytes" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    var buf: [512]u8 = undefined;
    for (0..2000) |i| {
        r.bytes(&buf);
        if (i % 2 == 0) std.mem.writeInt(u32, buf[0..4], magic, .little);
        if (i % 4 == 0) std.mem.writeInt(u32, buf[4..8], 16, .little);
        if (i % 4 == 0) std.mem.writeInt(u32, buf[12..16], r.uintLessThan(u32, 40), .little);
        if (parse(testing.allocator, buf[0..r.uintLessThan(usize, buf.len)], 24)) |f| {
            var ff = f;
            ff.deinit(testing.allocator);
        } else |_| {}
    }
}

test "CSS names with legacy fallbacks" {
    try testing.expectEqualStrings("xterm", cssToXcursorNames(.text)[1]);
    try testing.expectEqualStrings("hand2", cssToXcursorNames(.pointer)[1]);
    try testing.expectEqualStrings("sb_h_double_arrow", cssToXcursorNames(.ew_resize)[1]);
    for (std.enums.values(CursorShape)) |s| if (s != .hidden) try testing.expect(cssToXcursorNames(s).len >= 2);
}

test "theme lookup follows Inherits, survives a cycle, falls back to default" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try encode(testing.allocator, &.{.{ .size = 24, .w = 2, .h = 2, .hx = 1, .hy = 1, .delay = 0, .color = 7 }});
    defer testing.allocator.free(file);
    const d = tmp.dir;
    try d.createDirPath(testing.io, "icons/a");
    try d.createDirPath(testing.io, "icons/b");
    try d.createDirPath(testing.io, "icons/c/cursors");
    try d.createDirPath(testing.io, "icons/default/cursors");
    try d.writeFile(testing.io, .{ .sub_path = "icons/a/index.theme", .data = "[Icon Theme]\nName=A\nInherits=b\n" });
    // b inherits a (a cycle) and then c, which has the cursor.
    try d.writeFile(testing.io, .{ .sub_path = "icons/b/index.theme", .data = "[Icon Theme]\nInherits=a,c\n" });
    try d.writeFile(testing.io, .{ .sub_path = "icons/c/cursors/xterm", .data = file });
    try d.writeFile(testing.io, .{ .sub_path = "icons/default/cursors/left_ptr", .data = file });
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try d.realPath(testing.io, &root_buf);
    const icons = try std.fmt.allocPrint(testing.allocator, "{s}/icons", .{root_buf[0..root_len]});
    defer testing.allocator.free(icons);
    const sp: SearchPath = .{ .dirs = &.{icons}, .theme = "a" };
    var f = (try loadXcursor(testing.allocator, testing.io, sp, "xterm", 24)).?;
    f.deinit(testing.allocator);
    // Not in a's chain: the default theme.
    var g = (try loadXcursor(testing.allocator, testing.io, sp, "left_ptr", 24)).?;
    g.deinit(testing.allocator);
    try testing.expectEqual(@as(?CursorFrames, null), try loadXcursor(testing.allocator, testing.io, sp, "nope", 24));
}
