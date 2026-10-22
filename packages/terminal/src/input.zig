//! Input encoding: keys (legacy xterm and kitty), mouse, paste and focus,
//! from the modes the application set (`Terminal.encoderState`).

const key_encode = @import("input/key_encode.zig");

/// Interim key and modifier types (mirror zg_platform until E01 lands).
pub const keys = @import("input/keys.zig");
/// Functional-key tables.
pub const keytables = @import("input/keytables.zig");
/// The kitty keyboard protocol encoder.
pub const kitty = @import("input/kitty.zig");
/// Mouse reporting.
pub const mouse = @import("input/mouse.zig");
/// Paste encoding.
pub const paste = @import("input/paste.zig");
/// Focus reporting.
pub const focus = @import("input/focus.zig");

pub const Key = keys.Key;
pub const Mods = keys.Mods;
pub const KeyInput = key_encode.KeyInput;
pub const Action = key_encode.Action;
pub const EncoderState = key_encode.EncoderState;
pub const encodeKey = key_encode.encodeKey;
pub const encodeMouse = mouse.encodeMouse;
pub const encodePaste = paste.encodePaste;
pub const encodeFocus = focus.encodeFocus;

test {
    _ = key_encode;
    _ = kitty;
    _ = mouse;
    _ = paste;
    _ = focus;
}
