//! zg_platform: windows, input, clipboard, IME and presentation for every
//! OS behind one API. `api/` holds the OS-independent types (no OS imports);
//! backends implement `Platform` for Win32, Wayland, X11 and headless.
//! See epic E01 (#2) and feature E01.F01 (#20) for the design.

const std = @import("std");

/// Geometry, ids and small shared enums.
pub const types = @import("api/types.zig");
/// Physical keys and modifiers.
pub const keys = @import("api/keys.zig");
/// Events delivered by `Platform.pollEvents`.
pub const event = @import("api/event.zig");
/// Window options, state and commands.
pub const window = @import("api/window.zig");
/// The presentation contract with the renderer.
pub const surface = @import("api/surface.zig");
/// Clipboard and drag-and-drop types.
pub const clipboard = @import("api/clipboard.zig");
/// IME types.
pub const ime = @import("api/ime.zig");
/// Cursor shapes.
pub const cursor = @import("api/cursor.zig");
/// File dialog requests.
pub const dialog = @import("api/dialog.zig");
/// Native integration hooks.
pub const native = @import("api/native.zig");
/// The `Platform` interface and backend selection.
pub const platform = @import("api/platform.zig");
/// The shared backend conformance suite.
pub const conformance = @import("testing/conformance.zig");
/// The transport between the platform and UI threads, used by backends.
pub const queue = struct {
    /// See `queue/event_ring.zig`.
    pub const EventRing = @import("queue/event_ring.zig").EventRing;
    /// See `queue/payload_arena.zig`.
    pub const PayloadArena = @import("queue/payload_arena.zig").PayloadArena;
    /// See `queue/command_queue.zig`.
    pub const CommandQueue = @import("queue/command_queue.zig").CommandQueue;
    /// See `queue/wake.zig`.
    pub const Wake = @import("queue/wake.zig").Wake;
};

/// See `types.WindowId`.
pub const WindowId = types.WindowId;
/// See `types.PxPoint`.
pub const PxPoint = types.PxPoint;
/// See `types.PxSize`.
pub const PxSize = types.PxSize;
/// See `types.PxRect`.
pub const PxRect = types.PxRect;
/// See `types.Scale`.
pub const Scale = types.Scale;
/// See `types.PayloadSlice`.
pub const PayloadSlice = types.PayloadSlice;
/// See `types.MonitorInfo`.
pub const MonitorInfo = types.MonitorInfo;
/// See `keys.Key`.
pub const Key = keys.Key;
/// See `keys.Mods`.
pub const Mods = keys.Mods;
/// See `event.Event`.
pub const Event = event.Event;
/// See `event.KeyEvent`.
pub const KeyEvent = event.KeyEvent;
/// See `event.Appearance`.
pub const Appearance = event.Appearance;
/// See `window.WindowOptions`.
pub const WindowOptions = window.WindowOptions;
/// See `window.WindowState`.
pub const WindowState = window.WindowState;
/// See `window.Command`.
pub const Command = window.Command;
/// See `surface.SurfaceTarget`.
pub const SurfaceTarget = surface.SurfaceTarget;
/// See `surface.Presenter`.
pub const Presenter = surface.Presenter;
/// See `native.NativeHooks`.
pub const NativeHooks = native.NativeHooks;
/// See `platform.Platform`.
pub const Platform = platform.Platform;
/// See `platform.Backend`.
pub const Backend = platform.Backend;
/// See `platform.Error`.
pub const Error = platform.Error;
/// See `platform.InitOptions`.
pub const InitOptions = platform.InitOptions;
/// See `platform.init`.
pub const init = platform.init;
/// See `platform.detectBackend`.
pub const detectBackend = platform.detectBackend;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(queue);
}

const documented_sources = [_]struct { path: []const u8, src: []const u8 }{
    .{ .path = "root.zig", .src = @embedFile("root.zig") },
    .{ .path = "api/types.zig", .src = @embedFile("api/types.zig") },
    .{ .path = "api/keys.zig", .src = @embedFile("api/keys.zig") },
    .{ .path = "api/event.zig", .src = @embedFile("api/event.zig") },
    .{ .path = "api/window.zig", .src = @embedFile("api/window.zig") },
    .{ .path = "api/surface.zig", .src = @embedFile("api/surface.zig") },
    .{ .path = "api/clipboard.zig", .src = @embedFile("api/clipboard.zig") },
    .{ .path = "api/ime.zig", .src = @embedFile("api/ime.zig") },
    .{ .path = "api/cursor.zig", .src = @embedFile("api/cursor.zig") },
    .{ .path = "api/dialog.zig", .src = @embedFile("api/dialog.zig") },
    .{ .path = "api/native.zig", .src = @embedFile("api/native.zig") },
    .{ .path = "api/platform.zig", .src = @embedFile("api/platform.zig") },
    .{ .path = "testing/conformance.zig", .src = @embedFile("testing/conformance.zig") },
};

test "every pub declaration in api/ has a doc comment" {
    var missing: usize = 0;
    for (documented_sources) |f| {
        var prev: []const u8 = "";
        var it = std.mem.splitScalar(u8, f.src, '\n');
        var line_no: usize = 0;
        while (it.next()) |raw| {
            line_no += 1;
            const line = std.mem.trim(u8, raw, " \r");
            if (std.mem.startsWith(u8, line, "pub ") and !std.mem.startsWith(u8, prev, "///")) {
                std.debug.print("{s}:{d}: pub declaration without a doc comment\n", .{ f.path, line_no });
                missing += 1;
            }
            if (line.len > 0) prev = line;
        }
    }
    try std.testing.expectEqual(0, missing);
}

test "api/ imports nothing OS-specific" {
    for (documented_sources) |f| {
        if (!std.mem.startsWith(u8, f.path, "api/")) continue;
        for ([_][]const u8{ "std.os", "std.posix", "std.c.", "@cImport", "builtin.os" }) |bad| {
            if (std.mem.indexOf(u8, f.src, bad)) |_| {
                // Backend selection is the one place allowed to look at the OS.
                if (std.mem.eql(u8, f.path, "api/platform.zig") and std.mem.eql(u8, bad, "builtin.os")) continue;
                std.debug.print("{s} uses {s}\n", .{ f.path, bad });
                return error.OsImportInApi;
            }
        }
    }
}
