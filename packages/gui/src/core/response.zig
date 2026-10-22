//! `Response`: the interaction flags a widget leaf returns to build code.

const std = @import("std");

/// Interaction since the node was last built, plus its live hover, press
/// and focus state.
pub const Response = packed struct(u32) {
    hovered: bool = false,
    pressed: bool = false,
    clicked: bool = false,
    double_clicked: bool = false,
    right_clicked: bool = false,
    focused: bool = false,
    focus_gained: bool = false,
    focus_lost: bool = false,
    changed: bool = false,
    submitted: bool = false,
    cancelled: bool = false,
    drag_started: bool = false,
    dragging: bool = false,
    drag_ended: bool = false,
    _pad: u18 = 0,

    /// The union of two responses.
    pub fn merge(a: Response, b: Response) Response {
        return @bitCast(@as(u32, @bitCast(a)) | @as(u32, @bitCast(b)));
    }

    /// True when no flag is set.
    pub fn isEmpty(r: Response) bool {
        return @as(u32, @bitCast(r)) == 0;
    }
};

test "merge" {
    const r = Response.merge(.{ .clicked = true }, .{ .hovered = true });
    try std.testing.expect(r.clicked and r.hovered and !r.pressed);
    try std.testing.expect((Response{}).isEmpty());
}
