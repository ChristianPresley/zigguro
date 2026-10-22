//! Geometry, identifiers and small enums shared by every other `api/` file.
//! Pixel types are physical (device) pixels unless a name says otherwise.

const std = @import("std");

/// Identifies a window for the lifetime of the `Platform` that created it.
/// Ids are never reused while the platform is alive.
pub const WindowId = enum(u32) { _ };

/// A point in physical pixels, relative to the window's top-left corner
/// unless stated otherwise.
pub const PxPoint = extern struct {
    /// Horizontal offset; grows to the right.
    x: i32,
    /// Vertical offset; grows downwards.
    y: i32,
};

/// A size in physical pixels.
pub const PxSize = extern struct {
    /// Width.
    w: u32,
    /// Height.
    h: u32,
};

/// An axis-aligned rectangle in physical pixels.
pub const PxRect = extern struct {
    /// Left edge.
    x: i32,
    /// Top edge.
    y: i32,
    /// Width.
    w: u32,
    /// Height.
    h: u32,
};

/// The scale from logical to physical pixels.
pub const Scale = struct {
    /// 1.0 is 96 dpi. Wayland reports `preferred_scale / 120`.
    factor: f32 = 1.0,
};

/// Bytes carried by an event (key text, preedit, clipboard data, paths).
/// Small payloads live in one of the platform's two `PayloadArena` slabs and
/// stay valid until the next `Platform.pollEvents`. Payloads over 64 KiB are
/// a separate `LargePayload` (`large == true`) that stays valid until the app
/// passes the slice to `Platform.release`.
pub const PayloadSlice = packed struct(u64) {
    /// Byte offset into the slab, or the large-payload id.
    off: u30 = 0,
    /// Which arena slab holds the bytes.
    slab: u1 = 0,
    /// The bytes are a `LargePayload` that must be released.
    large: bool = false,
    /// Length in bytes.
    len: u32 = 0,

    /// The empty payload.
    pub const empty: PayloadSlice = .{};
};

/// A pointer button.
pub const Button = enum(u8) {
    /// Primary button.
    left,
    /// Secondary button.
    right,
    /// Wheel click.
    middle,
    /// Thumb button, "back" (X1).
    back,
    /// Thumb button, "forward" (X2).
    forward,
    /// Any further button, numbered by the backend.
    _,
};

/// The device that produced a scroll event.
pub const ScrollSource = enum(u8) {
    /// A notched wheel; deltas come in whole or fractional detents.
    wheel,
    /// A touchpad or touchscreen; deltas are continuous and the gesture has
    /// begin/end phases with kinetic scrolling left to the app.
    finger,
    /// A continuous device without phases, such as a trackpoint.
    continuous,
    /// Horizontal wheel tilt.
    wheel_tilt,
};

/// The phase of a gesture (scroll or touch).
pub const Phase = enum(u8) {
    /// The device has no phases (a wheel notch).
    none,
    /// First event of a gesture (finger down).
    begin,
    /// The gesture continues.
    update,
    /// Last event of a gesture (finger up).
    end,
    /// The OS cancelled the gesture; undo its effect.
    cancel,
};

/// A window edge or corner, for interactive resize.
pub const ResizeEdge = enum(u8) {
    /// Top edge.
    top,
    /// Bottom edge.
    bottom,
    /// Left edge.
    left,
    /// Right edge.
    right,
    /// Top-left corner.
    top_left,
    /// Top-right corner.
    top_right,
    /// Bottom-left corner.
    bottom_left,
    /// Bottom-right corner.
    bottom_right,
};

/// What a point in a client-decorated window does, as answered by the app's
/// `HitTestFn`. Win32 maps this to `WM_NCHITTEST` results; Wayland and X11
/// turn presses on non-client regions into move/resize requests.
pub const HitRegion = enum(u8) {
    /// Ordinary content: events go to the app.
    client,
    /// The title bar: drag moves, double-click maximizes.
    caption,
    /// Top resize border.
    resize_top,
    /// Bottom resize border.
    resize_bottom,
    /// Left resize border.
    resize_left,
    /// Right resize border.
    resize_right,
    /// Top-left resize corner.
    resize_top_left,
    /// Top-right resize corner.
    resize_top_right,
    /// Bottom-left resize corner.
    resize_bottom_left,
    /// Bottom-right resize corner.
    resize_bottom_right,
    /// Minimize button (Windows 11 snap layouts need this).
    button_min,
    /// Maximize button.
    button_max,
    /// Close button.
    button_close,
};

/// One monitor, as returned by `Platform.monitors`.
pub const MonitorInfo = struct {
    /// Backend-stable id, unchanged while the monitor stays connected.
    id: u32,
    /// Position and size in physical pixels in the global layout. Wayland
    /// does not expose positions, so `x` and `y` are 0 there.
    rect_px: PxRect,
    /// Work area (minus panels and taskbars), or `rect_px` when unknown.
    work_px: PxRect,
    /// Preferred scale.
    scale: Scale,
    /// Refresh rate in millihertz; 0 when unknown.
    refresh_mhz: u32,
    /// This is the primary monitor.
    primary: bool,
    /// Bytes of `name_buf` in use.
    name_len: u8 = 0,
    /// Connector or model name, such as "DP-1", truncated to 64 bytes.
    name_buf: [64]u8 = undefined,

    /// The monitor's name.
    pub fn name(m: *const MonitorInfo) []const u8 {
        return m.name_buf[0..m.name_len];
    }
};

test "geometry types are extern-compatible and small" {
    try std.testing.expectEqual(8, @sizeOf(PxPoint));
    try std.testing.expectEqual(8, @sizeOf(PxSize));
    try std.testing.expectEqual(16, @sizeOf(PxRect));
    try std.testing.expectEqual(8, @sizeOf(PayloadSlice));
    try std.testing.expectEqual(1, @sizeOf(Button));
}
