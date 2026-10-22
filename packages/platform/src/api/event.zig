//! Events from the platform thread to the UI thread, read with
//! `Platform.pollEvents`. An `Event` is at most 64 bytes, so one fits a
//! cache line in the event ring; variable-length data travels as a
//! `PayloadSlice`.

const std = @import("std");
const types = @import("types.zig");
const keys = @import("keys.zig");
const window_api = @import("window.zig");
const clipboard = @import("clipboard.zig");

const WindowId = types.WindowId;
const PayloadSlice = types.PayloadSlice;

/// A key press, release or repeat.
pub const KeyEvent = struct {
    /// The physical key.
    key: keys.Key,
    /// The layout's keysym (X11/XKB keysym values on every backend).
    keysym: u32,
    /// The character the key produces under the current layout and
    /// modifiers, or 0. Text input uses `text`, not this.
    codepoint: u21,
    /// Modifiers held, including this key's own effect on release.
    mods: keys.Mods,
    /// Press, release or repeat.
    action: keys.KeyAction,
    /// UTF-8 text the key produces (dead keys and compose already
    /// applied); empty for non-text keys.
    text: PayloadSlice,
    /// The OS scancode: evdev code on Linux, `MapVirtualKey` scancode
    /// (with 0xE0 prefix as bit 8) on Win32.
    native_scancode: u32,
    /// Win32 only: the virtual-key code, for E06 win32-input-mode.
    native_vk: u16 = 0,
    /// Win32 only: `KEY_EVENT_RECORD.dwControlKeyState` bits.
    native_ctrl_state: u16 = 0,
    /// Event time in nanoseconds on the monotonic clock.
    time_ns: u64,
};

/// The light/dark preference.
pub const ColorScheme = enum(u8) {
    /// The user expressed no preference.
    no_preference,
    /// Prefer a light theme.
    light,
    /// Prefer a dark theme.
    dark,
};

/// The contrast preference.
pub const Contrast = enum(u8) {
    /// Normal contrast.
    normal,
    /// High contrast requested (Windows high-contrast mode, portal
    /// `contrast` = 1).
    high,
};

/// The desktop's appearance settings.
pub const Appearance = struct {
    /// Light or dark.
    scheme: ColorScheme = .no_preference,
    /// Accent colour as sRGB, meaningful when `has_accent`.
    accent: [3]u8 = .{ 0, 0, 0 },
    /// The desktop provides an accent colour.
    has_accent: bool = false,
    /// Contrast preference.
    contrast: Contrast = .normal,
    /// The user asked for reduced motion; animations should be skipped.
    reduced_motion: bool = false,
};

/// Units of a scroll delta.
pub const ScrollUnit = enum(u8) {
    /// Physical pixels (touchpads, smooth scrolling).
    pixels,
    /// Lines (wheel notches; one notch is usually 3 lines).
    lines,
};

/// Bit flags of `Event.present_feedback.flags`, following
/// wp_presentation_feedback.
pub const PresentFlags = struct {
    /// Presentation was synchronised to vblank.
    pub const vsync: u8 = 0x1;
    /// The timestamp comes from the display hardware.
    pub const hw_clock: u8 = 0x2;
    /// Completion was signalled by the hardware.
    pub const hw_completion: u8 = 0x4;
    /// The buffer was scanned out directly (no composition).
    pub const zero_copy: u8 = 0x8;
    /// The frame was discarded without being shown.
    pub const discarded: u8 = 0x80;
};

/// Something that happened on the platform thread.
pub const Event = union(enum(u8)) {
    /// The user asked to close the window; the app decides whether to.
    window_close_requested: WindowId,
    /// The window's size, scale or state changed. Render the next frame at
    /// `size` and pass `serial` back in the present's `ConfigureAck`.
    window_configure: struct {
        win: WindowId,
        size: types.PxSize,
        scale: types.Scale,
        state: window_api.WindowState,
        serial: u32,
        /// Content origin on screen; null on Wayland.
        screen_origin_px: ?types.PxPoint,
    },
    /// Keyboard focus moved to or from the window.
    window_focus: struct { win: WindowId, focused: bool },
    /// The window became fully hidden or visible again.
    window_occluded: struct { win: WindowId, occluded: bool },
    /// A key event.
    key: struct { win: WindowId, ev: KeyEvent },
    /// Committed text without a key mapping (IME commit, compose result).
    text_input: struct { win: WindowId, text: PayloadSlice },
    /// IME preedit text; an empty text ends preedit. Cursor offsets are
    /// bytes, -1 hides the cursor.
    ime_preedit: struct { win: WindowId, text: PayloadSlice, cursor_begin: i32, cursor_end: i32 },
    /// The IME asks to delete bytes around the caret before the next commit.
    ime_delete_surrounding: struct { win: WindowId, before_bytes: u32, after_bytes: u32 },
    /// The pointer moved; position in physical pixels.
    pointer_move: struct { win: WindowId, pos_px: [2]f32, mods: keys.Mods, time_ns: u64 },
    /// A pointer button changed; `clicks` counts multi-clicks (1, 2, 3).
    pointer_button: struct { win: WindowId, button: types.Button, pressed: bool, pos_px: [2]f32, mods: keys.Mods, clicks: u8, time_ns: u64 },
    /// The pointer entered or left the window.
    pointer_enter_leave: struct { win: WindowId, entered: bool },
    /// Scrolling; positive `dy` scrolls content up (towards the end).
    scroll: struct { win: WindowId, dx: f32, dy: f32, unit: ScrollUnit, source: types.ScrollSource, phase: types.Phase },
    /// A touch point changed; `id` is stable during one touch.
    touch: struct { win: WindowId, id: i32, phase: types.Phase, pos_px: [2]f32 },
    /// Drag-and-drop over one of our windows.
    drop: clipboard.DropEvent,
    /// Another client took ownership of a selection.
    clipboard_changed: clipboard.Selection,
    /// The answer to `Command.clipboard_read`; empty `data` means the
    /// format was unavailable.
    clipboard_data: struct { request: u32, data: PayloadSlice, mime: clipboard.MimeId },
    /// Render now: the compositor is ready for a frame expected at
    /// `target_ns`; `refresh_ns` is the current refresh period.
    frame: struct { win: WindowId, target_ns: u64, refresh_ns: u32 },
    /// A presented frame reached the screen at `presented_ns`;
    /// `flags` holds `PresentFlags` bits.
    present_feedback: struct { win: WindowId, presented_ns: u64, seq: u64, flags: u8 },
    /// Monitors were added, removed or changed; call `Platform.monitors`.
    monitors_changed,
    /// The desktop appearance changed.
    appearance_changed: Appearance,
    /// The answer to `Command.open_dialog`: NUL-separated UTF-8 paths.
    dialog_result: struct { request: u32, paths: PayloadSlice, cancelled: bool },
    /// `Platform.wake` was called.
    wake,

    /// The tag type.
    pub const Tag = std.meta.Tag(Event);

    /// The window the event belongs to, if it has one.
    pub fn window(e: Event) ?WindowId {
        switch (e) {
            inline else => |payload| {
                const P = @TypeOf(payload);
                if (P == WindowId) return payload;
                if (@typeInfo(P) == .@"struct" and @hasField(P, "win")) return payload.win;
                return null;
            },
        }
    }
};

comptime {
    std.debug.assert(@sizeOf(Event) <= 64);
}

test "Event.window" {
    const w: WindowId = @enumFromInt(7);
    try std.testing.expectEqual(w, (Event{ .window_close_requested = w }).window().?);
    try std.testing.expectEqual(w, (Event{ .window_focus = .{ .win = w, .focused = true } }).window().?);
    try std.testing.expectEqual(@as(?WindowId, null), (Event{ .wake = {} }).window());
    try std.testing.expectEqual(@as(?WindowId, null), (Event{ .clipboard_changed = .primary }).window());
}

test "Event fits 64 bytes" {
    try std.testing.expect(@sizeOf(Event) <= 64);
    try std.testing.expect(@sizeOf(KeyEvent) <= 48);
}
