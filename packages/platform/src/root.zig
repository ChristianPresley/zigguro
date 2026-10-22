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
/// The headless backend and `.zgtrace` traces.
pub const headless = struct {
    /// See `headless/backend.zig`.
    pub const Headless = @import("headless/backend.zig").Headless;
    /// See `headless/backend.zig`.
    pub const HeadlessOptions = @import("headless/backend.zig").HeadlessOptions;
    /// See `headless/backend.zig`.
    pub const FrameImage = @import("headless/backend.zig").FrameImage;
    /// See `headless/backend.zig`.
    pub const DialogAnswer = @import("headless/backend.zig").DialogAnswer;
    /// See `headless/trace.zig`.
    pub const trace = @import("headless/trace.zig");
};

/// Starts the backend chosen by `platform.selectBackend`. Only headless
/// exists so far; the OS backends (E01.F02, E01.F04, E01.F05) return
/// `error.BackendUnavailable` until they land.
pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: InitOptions) Error!Platform {
    return switch (platform.selectBackend(opts)) {
        .headless => {
            const h = headless.Headless.init(gpa, io, .{}) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.SystemResources,
            };
            return h.platform();
        },
        else => error.BackendUnavailable,
    };
}

/// Recursive file watching.
pub const fswatch = struct {
    /// See `fswatch/api.zig`.
    pub const api = @import("fswatch/api.zig");
    /// See `fswatch/api.zig`.
    pub const Watcher = api.Watcher;
    /// See `fswatch/api.zig`.
    pub const FsEvent = api.FsEvent;
    /// See `fswatch/ignore.zig`.
    pub const IgnoreFilter = api.IgnoreFilter;
    /// See `fswatch/ignore.zig`.
    pub const NameList = @import("fswatch/ignore.zig").NameList;
    /// See `fswatch/coalesce.zig`.
    pub const Coalescer = @import("fswatch/coalesce.zig").Coalescer;
};

/// Child processes: PTYs for terminals, and plain spawns under a policy.
pub const process = struct {
    /// See `process/pty.zig`.
    pub const pty = @import("process/pty.zig");
    /// See `process/pty.zig`.
    pub const Pty = pty.Pty;
    /// See `process/env.zig`.
    pub const env = @import("process/env.zig");
    /// Linux process spawning without a PTY.
    pub const spawn_linux = if (@import("builtin").os.tag == .linux) @import("process/spawn_linux.zig") else struct {};
};

/// XKB keymaps: parsing the text format, keysyms and key resolution.
pub const xkb = struct {
    /// See `xkb/keymap.zig`.
    pub const Keymap = @import("xkb/keymap.zig").Keymap;
    /// See `xkb/keymap.zig`.
    pub const ModState = @import("xkb/keymap.zig").ModState;
    /// See `xkb/keymap.zig`.
    pub const Resolved = @import("xkb/keymap.zig").Resolved;
    /// See `xkb/keymap.zig`.
    pub const ParseError = @import("xkb/keymap.zig").ParseError;
    /// See `xkb/parser.zig`.
    pub const Diagnostic = @import("xkb/parser.zig").Diagnostic;
    /// See `xkb/keysyms.zig`.
    pub const keysyms = @import("xkb/keysyms.zig");
    /// See `xkb/keysyms.zig`.
    pub const keysymToCodepoint = keysyms.keysymToCodepoint;
    /// See `xkb/keysyms.zig`.
    pub const keysymName = keysyms.keysymName;
    /// See `xkb/keysyms.zig`.
    pub const keysymFromName = keysyms.keysymFromName;
    /// See `xkb/evdev.zig`.
    pub const evdevToKey = @import("xkb/evdev.zig").evdevToKey;
    /// See `xkb/lexer.zig`.
    pub const lexer = @import("xkb/lexer.zig");
    /// See `xkb/parser.zig`.
    pub const parser = @import("xkb/parser.zig");
    /// See `xkb/compose.zig`.
    pub const ComposeTable = @import("xkb/compose.zig").ComposeTable;
    /// See `xkb/compose.zig`.
    pub const ComposeState = @import("xkb/compose.zig").ComposeState;
    /// See `xkb/compose.zig`.
    pub const compose = @import("xkb/compose.zig");
    /// See `xkb/compose_parser.zig`.
    pub const compose_parser = @import("xkb/compose_parser.zig");
};

/// The Wayland client: generated protocol bindings (`wl_gen`) and the
/// wire connection (Linux).
pub const wayland = struct {
    /// Typed encoders and decoders for every vendored protocol, generated
    /// at build time by zg_build's `wayland_scanner`.
    pub const protocol = @import("wl_gen");
    /// See `wayland/wire/connection.zig`.
    pub const wire = if (is_linux) struct {
        /// See `wayland/wire/connection.zig`.
        pub const Connection = @import("wayland/wire/connection.zig").Connection;
        /// See `wayland/wire/connection.zig`.
        pub const Error = @import("wayland/wire/connection.zig").Error;
        /// See `wayland/wire/connection.zig`.
        pub const DisplayError = @import("wayland/wire/connection.zig").DisplayError;
        /// See `wayland/wire/connection.zig`.
        pub const display_id = @import("wayland/wire/connection.zig").display_id;
        /// See `wayland/wire/objects.zig`.
        pub const Handler = @import("wayland/wire/objects.zig").Handler;
        /// See `wayland/wire/fdqueue.zig`.
        pub const FdQueue = @import("wayland/wire/fdqueue.zig").FdQueue;
        /// See `wayland/wire/registry.zig`.
        pub const Registry = @import("wayland/wire/registry.zig").Registry;
        /// See `wayland/wire/registry.zig`.
        pub const Global = @import("wayland/wire/registry.zig").Global;
        /// See `wayland/wire/registry.zig`.
        pub const RemoveCallback = @import("wayland/wire/registry.zig").RemoveCallback;
        /// See `wayland/wire/marshal.zig`.
        pub const marshal = @import("wayland/wire/marshal.zig");
    } else struct {};
    /// See `wayland/testing/fake_compositor.zig`.
    pub const testing = if (is_linux) @import("wayland/testing/fake_compositor.zig") else struct {};
};

const is_linux = @import("builtin").os.tag == .linux;

/// A minimal D-Bus client for portals, notifications and AT-SPI (Linux).
pub const dbus = struct {
    /// See `dbus/signature.zig`.
    pub const signature = @import("dbus/signature.zig");
    /// See `dbus/marshal.zig`.
    pub const marshal = @import("dbus/marshal.zig");
    /// See `dbus/variant.zig`.
    pub const Value = @import("dbus/variant.zig").Value;
    /// See `dbus/message.zig`.
    pub const message = @import("dbus/message.zig");
    /// See `dbus/auth.zig`.
    pub const auth = @import("dbus/auth.zig");
    /// See `dbus/conn.zig`.
    pub const conn = if (@import("builtin").os.tag == .linux) @import("dbus/conn.zig") else struct {};
    /// See `dbus/conn.zig`.
    pub const Bus = if (@import("builtin").os.tag == .linux) conn.Bus else void;
};

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
/// See `platform.detectBackend`.
pub const detectBackend = platform.detectBackend;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(queue);
    std.testing.refAllDecls(headless);
    std.testing.refAllDecls(process);
    std.testing.refAllDecls(fswatch);
    std.testing.refAllDecls(dbus);
    std.testing.refAllDecls(xkb);
    _ = @import("xkb/resolve.zig");
    inline for (wayland.protocol.interfaces) |I| std.testing.refAllDecls(I);
    std.testing.refAllDecls(wayland.wire);
    if (is_linux) {
        _ = @import("wayland/wire/socket.zig");
        _ = @import("wayland/wire/objects.zig");
        _ = @import("wayland/wire/fuzz.zig");
    }
    if (@import("builtin").os.tag == .linux) _ = @import("fswatch/linux_inotify.zig");
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
    .{ .path = "queue/event_ring.zig", .src = @embedFile("queue/event_ring.zig") },
    .{ .path = "queue/payload_arena.zig", .src = @embedFile("queue/payload_arena.zig") },
    .{ .path = "queue/command_queue.zig", .src = @embedFile("queue/command_queue.zig") },
    .{ .path = "queue/wake.zig", .src = @embedFile("queue/wake.zig") },
    .{ .path = "headless/backend.zig", .src = @embedFile("headless/backend.zig") },
    .{ .path = "headless/trace.zig", .src = @embedFile("headless/trace.zig") },
    .{ .path = "process/pty.zig", .src = @embedFile("process/pty.zig") },
    .{ .path = "fswatch/api.zig", .src = @embedFile("fswatch/api.zig") },
    .{ .path = "fswatch/ignore.zig", .src = @embedFile("fswatch/ignore.zig") },
    .{ .path = "fswatch/coalesce.zig", .src = @embedFile("fswatch/coalesce.zig") },
    .{ .path = "fswatch/linux_inotify.zig", .src = @embedFile("fswatch/linux_inotify.zig") },
    .{ .path = "process/env.zig", .src = @embedFile("process/env.zig") },
    .{ .path = "process/spawn_linux.zig", .src = @embedFile("process/spawn_linux.zig") },
    .{ .path = "process/pty_linux.zig", .src = @embedFile("process/pty_linux.zig") },
    .{ .path = "dbus/signature.zig", .src = @embedFile("dbus/signature.zig") },
    .{ .path = "dbus/marshal.zig", .src = @embedFile("dbus/marshal.zig") },
    .{ .path = "dbus/variant.zig", .src = @embedFile("dbus/variant.zig") },
    .{ .path = "dbus/message.zig", .src = @embedFile("dbus/message.zig") },
    .{ .path = "dbus/auth.zig", .src = @embedFile("dbus/auth.zig") },
    .{ .path = "dbus/conn.zig", .src = @embedFile("dbus/conn.zig") },
    .{ .path = "xkb/lexer.zig", .src = @embedFile("xkb/lexer.zig") },
    .{ .path = "xkb/ast.zig", .src = @embedFile("xkb/ast.zig") },
    .{ .path = "xkb/parser.zig", .src = @embedFile("xkb/parser.zig") },
    .{ .path = "xkb/keymap.zig", .src = @embedFile("xkb/keymap.zig") },
    .{ .path = "xkb/resolve.zig", .src = @embedFile("xkb/resolve.zig") },
    .{ .path = "xkb/keysyms.zig", .src = @embedFile("xkb/keysyms.zig") },
    .{ .path = "xkb/keysym_data.zig", .src = @embedFile("xkb/keysym_data.zig") },
    .{ .path = "xkb/evdev.zig", .src = @embedFile("xkb/evdev.zig") },
    .{ .path = "xkb/compose.zig", .src = @embedFile("xkb/compose.zig") },
    .{ .path = "xkb/compose_parser.zig", .src = @embedFile("xkb/compose_parser.zig") },
    .{ .path = "wayland/wire/connection.zig", .src = @embedFile("wayland/wire/connection.zig") },
    .{ .path = "wayland/wire/socket.zig", .src = @embedFile("wayland/wire/socket.zig") },
    .{ .path = "wayland/wire/fdqueue.zig", .src = @embedFile("wayland/wire/fdqueue.zig") },
    .{ .path = "wayland/wire/marshal.zig", .src = @embedFile("wayland/wire/marshal.zig") },
    .{ .path = "wayland/wire/objects.zig", .src = @embedFile("wayland/wire/objects.zig") },
    .{ .path = "wayland/wire/registry.zig", .src = @embedFile("wayland/wire/registry.zig") },
    .{ .path = "wayland/testing/fake_compositor.zig", .src = @embedFile("wayland/testing/fake_compositor.zig") },
};

test "init starts the headless backend" {
    const p = try init(std.testing.allocator, std.testing.io, .{ .backend = .headless });
    defer p.deinit();
    try std.testing.expectError(error.BackendUnavailable, init(std.testing.allocator, std.testing.io, .{ .backend = .wayland }));
}

test "every pub declaration has a doc comment" {
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
