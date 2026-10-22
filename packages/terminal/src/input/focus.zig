//! Focus reporting (mode 1004): `CSI I` on focus gain, `CSI O` on loss.

const key_encode = @import("key_encode.zig");

/// The focus report, or empty when the application did not ask for it.
pub fn encodeFocus(st: *const key_encode.EncoderState, focused: bool) []const u8 {
    if (!st.focus_events) return "";
    return if (focused) "\x1b[I" else "\x1b[O";
}

test "focus reports only with mode 1004" {
    const std = @import("std");
    var st: key_encode.EncoderState = .{};
    try std.testing.expectEqualStrings("", encodeFocus(&st, true));
    st.focus_events = true;
    try std.testing.expectEqualStrings("\x1b[I", encodeFocus(&st, true));
    try std.testing.expectEqualStrings("\x1b[O", encodeFocus(&st, false));
}
