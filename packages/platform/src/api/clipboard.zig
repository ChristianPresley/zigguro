//! Clipboard, primary selection and drag-and-drop payload types.

const types = @import("types.zig");

/// Which selection a clipboard command or event refers to.
pub const Selection = enum(u8) {
    /// The regular clipboard (Ctrl+C / Ctrl+V).
    clipboard,
    /// The X11/Wayland primary selection (select / middle-click). Win32
    /// has none; commands on it are ignored there.
    primary,
};

/// A data format. The common formats have fixed ids; backends translate
/// them to MIME types (Wayland, X11 targets) or clipboard formats (Win32).
pub const MimeId = enum(u16) {
    /// `text/plain;charset=utf-8` (Win32 `CF_UNICODETEXT`).
    text_utf8,
    /// `text/uri-list` (Win32 `CF_HDROP`).
    uri_list,
    /// `text/html`.
    html,
    /// `image/png`.
    png,
    /// `application/x-zigguro-internal`, for in-app drags.
    zigguro_internal,
    /// Further formats registered by the backend at runtime.
    _,

    /// The MIME type for a known id, or null for a runtime-registered one.
    pub fn mimeType(m: MimeId) ?[]const u8 {
        return switch (m) {
            .text_utf8 => "text/plain;charset=utf-8",
            .uri_list => "text/uri-list",
            .html => "text/html",
            .png => "image/png",
            .zigguro_internal => "application/x-zigguro-internal",
            _ => null,
        };
    }
};

/// One representation of the data being written or dragged.
pub const ClipItem = struct {
    /// Its format.
    mime: MimeId,
    /// The bytes; copied by `Platform.submit`.
    data: []const u8,
};

/// Drag-and-drop actions, as a set.
pub const DragActions = packed struct(u8) {
    /// Copy the data.
    copy: bool = false,
    /// Move the data (the source deletes it after the drop).
    move: bool = false,
    /// Create a link to the data.
    link: bool = false,
    /// Ask the user (Wayland `ask`, Win32 right-drag menu).
    ask: bool = false,
    _pad: u4 = 0,
};

/// The stage of a drag over one of our windows.
pub const DropPhase = enum(u8) {
    /// The drag entered the window; `mimes` lists the offered formats.
    enter,
    /// The pointer moved while dragging.
    over,
    /// The drag left the window or was cancelled.
    leave,
    /// The user dropped; `data` holds the accepted format's bytes.
    drop,
    /// A drag we started (`Command.start_drag`) ended: `win` is the
    /// window it started from and `allowed` holds the action the target
    /// performed, empty when it was cancelled or refused.
    source_finished,
};

/// A drag-and-drop event. The app answers `enter` and `over` with
/// `Command.set_drop_effect`; the backend caches the answer for OS
/// callbacks that need it synchronously. On `drop`, `allowed` holds the
/// action the drop performs.
pub const DropEvent = struct {
    /// The window under the pointer.
    win: types.WindowId,
    /// What happened.
    phase: DropPhase,
    /// Actions the source allows.
    allowed: DragActions,
    /// Pointer position in physical pixels.
    pos_px: [2]f32,
    /// Offered formats as a packed array of little-endian `u16` `MimeId`
    /// values (`enter` only; empty otherwise).
    mimes: types.PayloadSlice = .empty,
    /// The dropped bytes in the format accepted by `set_drop_effect`
    /// (`drop` only; empty otherwise).
    data: types.PayloadSlice = .empty,
};
