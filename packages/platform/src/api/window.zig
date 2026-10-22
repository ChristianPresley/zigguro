//! Window creation options, window state and the commands the app submits
//! to the platform thread.

const types = @import("types.zig");
const cursor = @import("cursor.zig");
const ime = @import("ime.zig");
const clipboard = @import("clipboard.zig");
const dialog = @import("dialog.zig");

const WindowId = types.WindowId;
const PxSize = types.PxSize;
const PxPoint = types.PxPoint;
const PxRect = types.PxRect;

/// Options for `Platform.createWindow`.
pub const WindowOptions = struct {
    /// Initial title (UTF-8).
    title: []const u8,
    /// Initial content size in physical pixels; the compositor may change it.
    size: PxSize,
    /// Minimum content size.
    min_size: ?PxSize = null,
    /// Application id: Wayland `app_id`, X11 `WM_CLASS`, Win32
    /// AppUserModelID.
    app_id: []const u8 = "dev.zigguro.zigguro",
    /// Who draws the title bar and borders.
    decorations: Decorations = .auto,
    /// Request an alpha channel for the window contents.
    transparent: bool = false,
    /// Parent window for dialogs and tool windows.
    parent: ?WindowId = null,
    /// Initial position of the window's outer top-left corner on the
    /// virtual screen, in physical pixels. Win32 and X11 honour it (an X11
    /// window manager may still adjust it); Wayland compositors place
    /// windows themselves and ignore it.
    position: ?PxPoint = null,
    /// Keep the window above normal windows (floating tool windows).
    /// Win32 and X11 (`_NET_WM_STATE_ABOVE`); ignored on Wayland, which
    /// has no protocol for it.
    always_on_top: bool = false,
};

/// Who draws a window's decorations.
pub const Decorations = enum(u8) {
    /// Server-side when the compositor offers it, else client-side.
    auto,
    /// Always client-side: E04 draws them and answers hit tests.
    client,
    /// Server-side; falls back to client-side if unsupported.
    server,
};

/// Window state reported with `Event.window_configure`.
pub const WindowState = packed struct(u16) {
    /// The window is maximized.
    maximized: bool = false,
    /// The window is fullscreen.
    fullscreen: bool = false,
    /// An interactive resize is in progress.
    resizing: bool = false,
    /// The window has keyboard focus and is drawn as active.
    activated: bool = false,
    /// Tiled against the left edge (no shadow or rounded corner there).
    tiled_left: bool = false,
    /// Tiled against the right edge.
    tiled_right: bool = false,
    /// Tiled against the top edge.
    tiled_top: bool = false,
    /// Tiled against the bottom edge.
    tiled_bottom: bool = false,
    /// The window is not visible at all; rendering can stop.
    suspended: bool = false,
    _pad: u7 = 0,
};

/// A window state change requested with `Command.request_state`.
pub const WindowOp = enum(u8) {
    /// Show (map) the window.
    show,
    /// Maximize.
    maximize,
    /// Leave maximized state.
    unmaximize,
    /// Minimize (iconify).
    minimize,
    /// Enter fullscreen.
    fullscreen,
    /// Leave fullscreen.
    unfullscreen,
};

/// Answers "what is at this point?" for client-decorated windows. Called on
/// the platform thread; must not block.
pub const HitTestFn = *const fn (ctx: *anyopaque, p: PxPoint) types.HitRegion;

/// A request to the platform thread, sent with `Platform.submit`. Slices are
/// copied before `submit` returns.
pub const Command = union(enum) {
    /// Change a window's title.
    set_title: struct { win: WindowId, title: []const u8 },
    /// Change the cursor shown over a window.
    set_cursor: struct { win: WindowId, shape: cursor.CursorShape },
    /// Enable or update the IME for a window's focused text field.
    set_ime_state: struct { win: WindowId, enabled: bool, purpose: ime.ImePurpose, caret_rect_px: PxRect, surrounding: ?ime.Surrounding },
    /// Change the minimum content size.
    set_min_size: struct { win: WindowId, size: PxSize },
    /// Move the window's outer top-left corner to `pos` on the virtual
    /// screen (physical pixels). `error.Unsupported` on Wayland, where
    /// only the compositor places windows.
    set_position: struct { win: WindowId, pos: PxPoint },
    /// Keep the window above normal windows, or stop doing so.
    /// `error.Unsupported` on Wayland.
    set_always_on_top: struct { win: WindowId, on: bool },
    /// Ask for a state change; the result arrives as a configure.
    request_state: struct { win: WindowId, op: WindowOp },
    /// Start an interactive move (client-side decorations).
    begin_move: WindowId,
    /// Start an interactive resize from `edge`.
    begin_resize: struct { win: WindowId, edge: types.ResizeEdge },
    /// Show the window manager's window menu at `at`.
    show_window_menu: struct { win: WindowId, at: PxPoint },
    /// Take ownership of a selection with these representations.
    clipboard_write: struct { which: clipboard.Selection, items: []const clipboard.ClipItem },
    /// Read a selection; answered by `Event.clipboard_data` with `request`.
    clipboard_read: struct { which: clipboard.Selection, mime: clipboard.MimeId, request: u32 },
    /// Start a drag from `win` (call while a button is pressed).
    start_drag: struct { win: WindowId, items: []const clipboard.ClipItem, allowed: clipboard.DragActions },
    /// Install the hit-test callback for a client-decorated window.
    set_hit_test: struct { win: WindowId, f: HitTestFn, ctx: *anyopaque },
    /// The app's answer to the current drop enter/over: which format it
    /// accepts (null rejects) and with which effect.
    set_drop_effect: struct { win: WindowId, accept: ?clipboard.MimeId, effect: clipboard.DragActions },
    /// Ask for one `Event.frame` without presenting (Wayland frame callback
    /// plus a bufferless commit).
    request_frame: WindowId,
    /// Raise and focus a window. `token` is an activation token, such as one
    /// from a notification click (xdg-activation).
    activate: struct { win: WindowId, token: ?[]const u8 },
    /// Open a native file dialog.
    open_dialog: dialog.DialogRequest,
    /// Open a URI in the default handler.
    open_uri: []const u8,
    /// Flash the taskbar entry or set the urgency hint.
    request_attention: WindowId,
};
