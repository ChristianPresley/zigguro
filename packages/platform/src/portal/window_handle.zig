//! Parent-window handles for portal dialogs, in the xdg-desktop-portal
//! "window identifier" format: `wayland:<xdg_foreign handle>` or
//! `x11:<hex XID>`; "" when there is no parent.

const std = @import("std");

/// `wayland:<handle>` for a handle from `zxdg_exported_v2.handle`.
pub fn wayland(out: []u8, handle: []const u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(out, "wayland:{s}", .{handle});
}

/// `x11:<xid>` with the XID in lowercase hex.
pub fn x11(out: []u8, xid: u32) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(out, "x11:{x}", .{xid});
}

test "window handle formats" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("wayland:abc-123", try wayland(&buf, "abc-123"));
    try std.testing.expectEqualStrings("x11:4a0001f", try x11(&buf, 0x4a0001f));
}
