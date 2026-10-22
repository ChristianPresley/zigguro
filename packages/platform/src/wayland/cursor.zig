//! Wayland cursors: `CursorShape` → cursor-shape-v1 values, and the
//! Xcursor fallback's theme settings (`XCURSOR_THEME`, `XCURSOR_SIZE`,
//! `XCURSOR_PATH`) for compositors without the protocol. The backend
//! loads themes on its platform thread and shows them on a cursor
//! surface.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wl = @import("wl_gen");
const CursorShape = @import("../api/cursor.zig").CursorShape;
const xcursor = @import("../linux/xcursor.zig");

/// The protocol value for `shape`; null for `hidden` (no cursor).
pub fn protocolShape(shape: CursorShape) ?wl.wp_cursor_shape_device_v1.Shape {
    return switch (shape) {
        .hidden => null,
        inline else => |s| @field(wl.wp_cursor_shape_device_v1.Shape, @tagName(s)),
    };
}

/// The Xcursor theme settings, copied from the environment.
pub const Theme = struct {
    name: []u8,
    /// Logical size in pixels at scale 1.
    size: u32,
    /// Search directories (owned strings).
    dirs: [][]u8,

    /// Reads `XCURSOR_THEME` (default `default`), `XCURSOR_SIZE` (24) and
    /// `XCURSOR_PATH` (else the upstream defaults under `HOME`).
    pub fn fromEnv(gpa: Allocator, env: ?*const std.process.Environ.Map) !Theme {
        const get = struct {
            fn f(e: ?*const std.process.Environ.Map, k: []const u8) ?[]const u8 {
                return if (e) |m| m.get(k) else null;
            }
        }.f;
        const name = try gpa.dupe(u8, get(env, "XCURSOR_THEME") orelse "default");
        errdefer gpa.free(name);
        const size = if (get(env, "XCURSOR_SIZE")) |s| std.fmt.parseInt(u32, s, 10) catch 24 else 24;
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |d| gpa.free(d);
            list.deinit(gpa);
        }
        if (get(env, "XCURSOR_PATH")) |p| {
            var it = std.mem.tokenizeScalar(u8, p, ':');
            while (it.next()) |d| try list.append(gpa, try gpa.dupe(u8, d));
        } else {
            var bufs: [4][]const u8 = undefined;
            var path_buf: [2 * std.Io.Dir.max_path_bytes]u8 = undefined;
            for (xcursor.defaultDirs(&bufs, &path_buf, get(env, "HOME"))) |d| try list.append(gpa, try gpa.dupe(u8, d));
        }
        return .{ .name = name, .size = std.math.clamp(size, 8, 256), .dirs = try list.toOwnedSlice(gpa) };
    }

    /// Frees the strings.
    pub fn deinit(t: *Theme, gpa: Allocator) void {
        for (t.dirs) |d| gpa.free(d);
        gpa.free(t.dirs);
        gpa.free(t.name);
    }

    /// Loads `shape` at `size_px`, trying its CSS name and then the
    /// legacy names.
    pub fn load(t: *const Theme, gpa: Allocator, io: std.Io, shape: CursorShape, size_px: u32) ?xcursor.CursorFrames {
        const dirs: []const []const u8 = @ptrCast(t.dirs);
        const sp: xcursor.SearchPath = .{ .dirs = dirs, .theme = t.name };
        for (xcursor.cssToXcursorNames(shape)) |n| {
            if (xcursor.loadXcursor(gpa, io, sp, n, size_px) catch null) |f| return f;
        }
        return null;
    }
};

const testing = std.testing;

test "every shape maps to a protocol value" {
    for (std.enums.values(CursorShape)) |s| {
        if (s == .hidden) {
            try testing.expectEqual(@as(?wl.wp_cursor_shape_device_v1.Shape, null), protocolShape(s));
        } else try testing.expect(@intFromEnum(protocolShape(s).?) >= 1);
    }
    try testing.expectEqual(@as(u32, 9), @intFromEnum(protocolShape(.text).?));
    try testing.expectEqual(@as(u32, 26), @intFromEnum(protocolShape(.ew_resize).?));
}

test "theme settings from the environment" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("XCURSOR_THEME", "Adwaita");
    try env.put("XCURSOR_SIZE", "32");
    try env.put("XCURSOR_PATH", "/a:/b");
    var t = try Theme.fromEnv(testing.allocator, &env);
    defer t.deinit(testing.allocator);
    try testing.expectEqualStrings("Adwaita", t.name);
    try testing.expectEqual(@as(u32, 32), t.size);
    try testing.expectEqual(@as(usize, 2), t.dirs.len);
    var d = try Theme.fromEnv(testing.allocator, null);
    defer d.deinit(testing.allocator);
    try testing.expectEqualStrings("default", d.name);
    try testing.expectEqual(@as(u32, 24), d.size);
    try testing.expectEqualStrings("/usr/share/icons", d.dirs[0]);
}
