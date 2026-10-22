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

/// Starts the backend chosen by `platform.selectBackend`, falling back
/// along Wayland → X11 when the backend was detected rather than forced
/// (by `opts.backend` or `ZG_PLATFORM`) and it cannot connect. The app
/// falls back to headless itself. Cocoa (E01.F08) returns
/// `error.BackendUnavailable` until it lands.
pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: InitOptions) Error!Platform {
    const first = platform.selectBackend(opts);
    if (initBackend(gpa, io, first, opts)) |p| return p else |err| {
        if (platform.isForced(opts) or first != .wayland) return err;
        const env = opts.environ_map orelse return err;
        const display = env.get("DISPLAY") orelse return err;
        if (display.len == 0) return err;
        std.log.scoped(.platform).info("Wayland unavailable ({t}); trying X11", .{err});
        return initBackend(gpa, io, .x11, opts);
    }
}

/// Starts exactly `backend`, mapping its errors to `Error`.
pub fn initBackend(gpa: std.mem.Allocator, io: std.Io, backend: Backend, opts: InitOptions) Error!Platform {
    const log = std.log.scoped(.platform);
    switch (backend) {
        .headless => {
            const h = headless.Headless.init(gpa, io, .{}) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.SystemResources,
            };
            return h.platform();
        },
        .wayland => if (is_linux) {
            const b = wayland.WaylandBackend.init(gpa, io, .{ .environ_map = opts.environ_map }) catch |err| {
                log.info("Wayland backend unavailable: {t}", .{err});
                return if (err == error.OutOfMemory) error.OutOfMemory else error.BackendUnavailable;
            };
            return b.platform();
        },
        .x11 => if (is_linux) {
            const b = x11.X11Backend.init(gpa, io, .{ .environ_map = opts.environ_map }) catch |err| {
                log.info("X11 backend unavailable: {t}", .{err});
                return if (err == error.OutOfMemory) error.OutOfMemory else error.BackendUnavailable;
            };
            return b.platform();
        },
        .win32 => if (is_windows) {
            const b = win32.Win32Backend.init(gpa, io, .{ .raw_mouse = opts.raw_mouse }) catch |err| {
                log.info("Win32 backend unavailable: {t}", .{err});
                return if (err == error.OutOfMemory) error.OutOfMemory else error.BackendUnavailable;
            };
            return b.platform();
        },
        .cocoa => {},
    }
    return error.BackendUnavailable;
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
    /// Windows command lines and environment blocks (builds everywhere).
    pub const cmdline_windows = @import("process/cmdline_windows.zig");
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
        /// See `wayland/wire/registry.zig`.
        pub const AddCallback = @import("wayland/wire/registry.zig").AddCallback;
        /// See `wayland/wire/marshal.zig`.
        pub const marshal = @import("wayland/wire/marshal.zig");
    } else struct {};
    /// See `wayland/testing/fake_compositor.zig`.
    pub const testing = if (is_linux) @import("wayland/testing/fake_compositor.zig") else struct {};
    /// See `wayland/backend.zig`.
    pub const WaylandBackend = if (is_linux) @import("wayland/backend.zig").WaylandBackend else void;
    /// See `wayland/backend.zig`.
    pub const InitOptions = if (is_linux) @import("wayland/backend.zig").InitOptions else void;
    /// See `wayland/scale.zig`.
    pub const scale = @import("wayland/scale.zig");
    /// See `wayland/output.zig`.
    pub const output = @import("wayland/output.zig");
    /// See `wayland/window.zig`.
    pub const window = @import("wayland/window.zig");
    /// See `wayland/dmabuf.zig`.
    pub const dmabuf = if (is_linux) @import("wayland/dmabuf.zig") else struct {};
};

const is_linux = @import("builtin").os.tag == .linux;
const is_windows = @import("builtin").os.tag == .windows;

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

/// xdg-desktop-portal clients: file dialogs, opening URIs, appearance
/// settings (Linux).
pub const portal = if (is_linux) struct {
    /// See `portal/request.zig`.
    pub const request = @import("portal/request.zig");
    /// See `portal/file_chooser.zig`.
    pub const file_chooser = @import("portal/file_chooser.zig");
    /// See `portal/open_uri.zig`.
    pub const open_uri = @import("portal/open_uri.zig");
    /// See `portal/settings.zig`.
    pub const settings = @import("portal/settings.zig");
    /// See `portal/window_handle.zig`.
    pub const window_handle = @import("portal/window_handle.zig");
} else struct {};

/// A pure-Zig X11 client: connection setup, request serialization,
/// replies, errors and events (Linux).
pub const x11 = if (is_linux) struct {
    /// See `x11/conn.zig`.
    pub const Conn = @import("x11/conn.zig").Conn;
    /// See `x11/auth.zig`.
    pub const auth = @import("x11/auth.zig");
    /// See `x11/setup.zig`.
    pub const setup = @import("x11/setup.zig");
    /// See `x11/proto.zig`.
    pub const proto = @import("x11/proto.zig");
    /// See `x11/ext.zig`.
    pub const ext = @import("x11/ext.zig");
    /// See `x11/atoms.zig`.
    pub const AtomTable = @import("x11/atoms.zig").AtomTable;
    /// See `x11/testing/fake_server.zig`.
    pub const testing = @import("x11/testing/fake_server.zig");
    /// See `x11/backend.zig`.
    pub const X11Backend = @import("x11/backend.zig").X11Backend;
    /// See `x11/backend.zig`.
    pub const InitOptions = @import("x11/backend.zig").InitOptions;
    /// See `x11/backend.zig`.
    pub const XvfbForTest = @import("x11/backend.zig").XvfbForTest;
    /// See `x11/present.zig`.
    pub const present = @import("x11/present.zig");
    /// See `x11/dri3.zig`.
    pub const dri3 = @import("x11/dri3.zig");
    /// See `x11/dpi.zig`.
    pub const dpi = @import("x11/dpi.zig");
    /// See `x11/keymap.zig`.
    pub const keymap = @import("x11/keymap.zig");
} else struct {};

/// Win32 bindings (user32, kernel32, gdi32, imm32, ole32, shell32, dwmapi,
/// advapi32), COM helpers and UTF-16 conversion. The pure parts (types,
/// `com`, `wide`) build on every OS; the DLL bindings only on Windows.
pub const win32 = struct {
    /// See `win32/bindings/types.zig`.
    pub const types = @import("win32/bindings/types.zig");
    /// See `win32/com.zig`.
    pub const com = @import("win32/com.zig");
    /// See `win32/wide.zig`.
    pub const wide = @import("win32/wide.zig");
    /// See `win32/bindings/user32.zig`.
    pub const user32 = if (is_windows) @import("win32/bindings/user32.zig") else struct {};
    /// See `win32/bindings/kernel32.zig`.
    pub const kernel32 = if (is_windows) @import("win32/bindings/kernel32.zig") else struct {};
    /// See `win32/bindings/gdi32.zig`.
    pub const gdi32 = if (is_windows) @import("win32/bindings/gdi32.zig") else struct {};
    /// See `win32/bindings/imm32.zig`.
    pub const imm32 = if (is_windows) @import("win32/bindings/imm32.zig") else struct {};
    /// See `win32/bindings/ole32.zig`.
    pub const ole32 = if (is_windows) @import("win32/bindings/ole32.zig") else struct {};
    /// See `win32/bindings/shell32.zig`.
    pub const shell32 = if (is_windows) @import("win32/bindings/shell32.zig") else struct {};
    /// See `win32/bindings/dwmapi.zig`.
    pub const dwmapi = if (is_windows) @import("win32/bindings/dwmapi.zig") else struct {};
    /// See `win32/bindings/advapi32.zig`.
    pub const advapi32 = if (is_windows) @import("win32/bindings/advapi32.zig") else struct {};
    /// See `win32/msgs.zig`.
    pub const msgs = @import("win32/msgs.zig");
    /// See `win32/keys.zig`.
    pub const keys = @import("win32/keys.zig");
    /// See `win32/dpi.zig`.
    pub const dpi = @import("win32/dpi.zig");
    /// See `win32/cpu_present.zig`.
    pub const cpu_present = @import("win32/cpu_present.zig");
    /// See `win32/cf_html.zig`.
    pub const cf_html = @import("win32/cf_html.zig");
    /// See `win32/hdrop.zig`.
    pub const hdrop = @import("win32/hdrop.zig");
    /// See `win32/frame.zig`.
    pub const frame = @import("win32/frame.zig");
    /// See `win32/cursor.zig`.
    pub const cursor = @import("win32/cursor.zig");
    /// See `win32/ime.zig`.
    pub const ime = @import("win32/ime.zig");
    /// See `win32/pointer.zig`.
    pub const pointer = @import("win32/pointer.zig");
    /// See `win32/backend.zig`.
    pub const Win32Backend = if (is_windows) @import("win32/backend.zig").Win32Backend else void;
    /// See `win32/backend.zig`.
    pub const InitOptions = if (is_windows) @import("win32/backend.zig").InitOptions else void;
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
    _ = wayland.scale;
    _ = wayland.output;
    _ = wayland.window;
    std.testing.refAllDecls(portal);
    std.testing.refAllDecls(x11);
    std.testing.refAllDecls(win32);
    _ = win32.types;
    if (is_windows) {
        inline for (.{ "user32", "kernel32", "gdi32", "imm32", "ole32", "shell32", "dwmapi", "advapi32" }) |n| std.testing.refAllDecls(@field(win32, n));
        _ = @import("win32/bindings/windows_test.zig");
        _ = @import("win32/backend.zig");
    }
    _ = win32.keys;
    _ = win32.dpi;
    _ = win32.cpu_present;
    _ = win32.cf_html;
    _ = win32.hdrop;
    _ = win32.frame;
    _ = win32.cursor;
    _ = win32.ime;
    if (is_linux) {
        _ = @import("wayland/wire/socket.zig");
        _ = @import("wayland/wire/objects.zig");
        _ = @import("wayland/wire/fuzz.zig");
        _ = @import("wayland/backend.zig");
        _ = @import("wayland/shm.zig");
        _ = @import("wayland/dmabuf.zig");
        _ = @import("portal/fake_portal.zig");
        std.testing.refAllDecls(x11.Conn);
        _ = @import("x11/testing/fake_server.zig");
        _ = @import("x11/backend.zig");
        _ = @import("x11/dri3.zig");
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
    .{ .path = "process/pty_windows.zig", .src = @embedFile("process/pty_windows.zig") },
    .{ .path = "process/cmdline_windows.zig", .src = @embedFile("process/cmdline_windows.zig") },
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
    .{ .path = "portal/request.zig", .src = @embedFile("portal/request.zig") },
    .{ .path = "portal/file_chooser.zig", .src = @embedFile("portal/file_chooser.zig") },
    .{ .path = "portal/open_uri.zig", .src = @embedFile("portal/open_uri.zig") },
    .{ .path = "portal/settings.zig", .src = @embedFile("portal/settings.zig") },
    .{ .path = "portal/window_handle.zig", .src = @embedFile("portal/window_handle.zig") },
    .{ .path = "portal/fake_portal.zig", .src = @embedFile("portal/fake_portal.zig") },
    .{ .path = "xkb/compose_parser.zig", .src = @embedFile("xkb/compose_parser.zig") },
    .{ .path = "wayland/wire/connection.zig", .src = @embedFile("wayland/wire/connection.zig") },
    .{ .path = "wayland/wire/socket.zig", .src = @embedFile("wayland/wire/socket.zig") },
    .{ .path = "wayland/wire/fdqueue.zig", .src = @embedFile("wayland/wire/fdqueue.zig") },
    .{ .path = "wayland/wire/marshal.zig", .src = @embedFile("wayland/wire/marshal.zig") },
    .{ .path = "wayland/wire/objects.zig", .src = @embedFile("wayland/wire/objects.zig") },
    .{ .path = "wayland/wire/registry.zig", .src = @embedFile("wayland/wire/registry.zig") },
    .{ .path = "wayland/backend.zig", .src = @embedFile("wayland/backend.zig") },
    .{ .path = "wayland/window.zig", .src = @embedFile("wayland/window.zig") },
    .{ .path = "wayland/output.zig", .src = @embedFile("wayland/output.zig") },
    .{ .path = "wayland/scale.zig", .src = @embedFile("wayland/scale.zig") },
    .{ .path = "wayland/shm.zig", .src = @embedFile("wayland/shm.zig") },
    .{ .path = "wayland/dmabuf.zig", .src = @embedFile("wayland/dmabuf.zig") },
    .{ .path = "wayland/testing/fake_compositor.zig", .src = @embedFile("wayland/testing/fake_compositor.zig") },
    .{ .path = "x11/conn.zig", .src = @embedFile("x11/conn.zig") },
    .{ .path = "x11/auth.zig", .src = @embedFile("x11/auth.zig") },
    .{ .path = "x11/setup.zig", .src = @embedFile("x11/setup.zig") },
    .{ .path = "x11/proto.zig", .src = @embedFile("x11/proto.zig") },
    .{ .path = "x11/ext.zig", .src = @embedFile("x11/ext.zig") },
    .{ .path = "x11/atoms.zig", .src = @embedFile("x11/atoms.zig") },
    .{ .path = "x11/testing/fake_server.zig", .src = @embedFile("x11/testing/fake_server.zig") },
    .{ .path = "x11/backend.zig", .src = @embedFile("x11/backend.zig") },
    .{ .path = "x11/present.zig", .src = @embedFile("x11/present.zig") },
    .{ .path = "x11/dri3.zig", .src = @embedFile("x11/dri3.zig") },
    .{ .path = "x11/dpi.zig", .src = @embedFile("x11/dpi.zig") },
    .{ .path = "x11/keymap.zig", .src = @embedFile("x11/keymap.zig") },
    .{ .path = "win32/bindings/types.zig", .src = @embedFile("win32/bindings/types.zig") },
    .{ .path = "win32/bindings/user32.zig", .src = @embedFile("win32/bindings/user32.zig") },
    .{ .path = "win32/bindings/kernel32.zig", .src = @embedFile("win32/bindings/kernel32.zig") },
    .{ .path = "win32/bindings/gdi32.zig", .src = @embedFile("win32/bindings/gdi32.zig") },
    .{ .path = "win32/bindings/imm32.zig", .src = @embedFile("win32/bindings/imm32.zig") },
    .{ .path = "win32/bindings/ole32.zig", .src = @embedFile("win32/bindings/ole32.zig") },
    .{ .path = "win32/bindings/shell32.zig", .src = @embedFile("win32/bindings/shell32.zig") },
    .{ .path = "win32/bindings/dwmapi.zig", .src = @embedFile("win32/bindings/dwmapi.zig") },
    .{ .path = "win32/bindings/advapi32.zig", .src = @embedFile("win32/bindings/advapi32.zig") },
    .{ .path = "win32/com.zig", .src = @embedFile("win32/com.zig") },
    .{ .path = "win32/wide.zig", .src = @embedFile("win32/wide.zig") },
    .{ .path = "win32/msgs.zig", .src = @embedFile("win32/msgs.zig") },
    .{ .path = "win32/keys.zig", .src = @embedFile("win32/keys.zig") },
    .{ .path = "win32/dpi.zig", .src = @embedFile("win32/dpi.zig") },
    .{ .path = "win32/cpu_present.zig", .src = @embedFile("win32/cpu_present.zig") },
    .{ .path = "win32/cf_html.zig", .src = @embedFile("win32/cf_html.zig") },
    .{ .path = "win32/hdrop.zig", .src = @embedFile("win32/hdrop.zig") },
    .{ .path = "win32/clipboard.zig", .src = @embedFile("win32/clipboard.zig") },
    .{ .path = "win32/frame.zig", .src = @embedFile("win32/frame.zig") },
    .{ .path = "win32/cursor.zig", .src = @embedFile("win32/cursor.zig") },
    .{ .path = "win32/ime.zig", .src = @embedFile("win32/ime.zig") },
    .{ .path = "win32/pointer.zig", .src = @embedFile("win32/pointer.zig") },
    .{ .path = "win32/backend.zig", .src = @embedFile("win32/backend.zig") },
};

test "init starts the headless backend" {
    const p = try init(std.testing.allocator, std.testing.io, .{ .backend = .headless });
    defer p.deinit();
    try std.testing.expectError(error.BackendUnavailable, init(std.testing.allocator, std.testing.io, .{ .backend = .wayland }));
    if (!is_windows) try std.testing.expectError(error.BackendUnavailable, init(std.testing.allocator, std.testing.io, .{ .backend = .win32 }));
}

test "init falls back from an unreachable Wayland display to X11" {
    if (!is_linux) return error.SkipZigTest;
    var x = x11.XvfbForTest.start(4) catch return error.SkipZigTest;
    defer x.stop();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_RUNTIME_DIR", dir);
    try env.put("WAYLAND_DISPLAY", "zg-no-such-socket");
    try env.put("DISPLAY", x.display());
    const p = try init(std.testing.allocator, std.testing.io, .{ .environ_map = &env });
    defer p.deinit();
    const win = try p.createWindow(.{ .title = "fallback", .size = .{ .w = 8, .h = 8 } });
    try std.testing.expect(p.native().windowHandle(p.native().ptr, win) == .x11);
    // Forcing Wayland does not fall back.
    try env.put("ZG_PLATFORM", "wayland");
    try std.testing.expectError(error.BackendUnavailable, init(std.testing.allocator, std.testing.io, .{ .environ_map = &env }));
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
