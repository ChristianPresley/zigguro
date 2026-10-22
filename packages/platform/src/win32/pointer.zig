//! Pen, touch and raw-mouse decoding for the Win32 backend. `WM_POINTER*`
//! carries a pointer id; the backend reads `POINTER_INFO` (and
//! `POINTER_PEN_INFO` for pens) and these functions decide which events
//! that becomes. Touch turns into `Event.touch` while Windows still
//! promotes the primary touch to mouse messages, so mouse-only UI keeps
//! working; pens become pointer events with pressure (contact is the left
//! button, the barrel button at contact the right one), each move preceded
//! by `Event.pointer_pressure`. Raw input (`InitOptions.raw_mouse`) yields
//! relative motion only. Pure functions; they build and test on every OS.

const std = @import("std");
const t = @import("bindings/types.zig");
const types = @import("../api/types.zig");

/// `WM_POINTER*` and `WM_INPUT` message numbers.
pub const WM = struct {
    /// WM_INPUT.
    pub const INPUT: u32 = 0x00FF;
    /// WM_POINTERUPDATE.
    pub const POINTERUPDATE: u32 = 0x0245;
    /// WM_POINTERDOWN.
    pub const POINTERDOWN: u32 = 0x0246;
    /// WM_POINTERUP.
    pub const POINTERUP: u32 = 0x0247;
};

/// `POINTER_INPUT_TYPE` values.
pub const PT = struct {
    /// PT_TOUCH.
    pub const TOUCH: u32 = 2;
    /// PT_PEN.
    pub const PEN: u32 = 3;
};

/// `POINTER_FLAG_*` bits of `POINTER_INFO.pointerFlags`.
pub const POINTER_FLAG = struct {
    /// The pointer touches the surface (pen tip or finger down).
    pub const INCONTACT: u32 = 0x4;
    /// The input was cancelled (palm rejection, a system gesture).
    pub const CANCELED: u32 = 0x8000;
};

/// `PEN_FLAG_*` bits of `POINTER_PEN_INFO.penFlags`.
pub const PEN_FLAG = struct {
    /// The barrel button is pressed.
    pub const BARREL: u32 = 0x1;
    /// The eraser end is in use.
    pub const ERASER: u32 = 0x4;
};

/// Raw input constants.
pub const RAW = struct {
    /// `RID_INPUT` for `GetRawInputData`.
    pub const RID_INPUT: u32 = 0x10000003;
    /// `RIM_TYPEMOUSE`.
    pub const TYPEMOUSE: u32 = 0;
    /// `MOUSE_MOVE_ABSOLUTE` in `RAWMOUSE.usFlags` (tablets, remote desktop).
    pub const MOVE_ABSOLUTE: u16 = 0x1;
    /// HID usage page Generic Desktop.
    pub const usage_page_generic: u16 = 0x01;
    /// HID usage Mouse on that page.
    pub const usage_mouse: u16 = 0x02;
};

/// What a pointer message is about.
pub const Kind = enum { touch, pen, other };

/// The device kind of `POINTER_INFO.pointerType`; mice and touchpads are
/// `other` and keep arriving as mouse messages.
pub fn kindOf(pointer_type: u32) Kind {
    return switch (pointer_type) {
        PT.TOUCH => .touch,
        PT.PEN => .pen,
        else => .other,
    };
}

/// The touch phase of a pointer message, or null for a hover update
/// (touch screens with proximity send those) that is not a touch event.
pub fn touchPhase(msg: u32, flags: u32) ?types.Phase {
    if (flags & POINTER_FLAG.CANCELED != 0) return .cancel;
    return switch (msg) {
        WM.POINTERDOWN => .begin,
        WM.POINTERUP => .end,
        WM.POINTERUPDATE => if (flags & POINTER_FLAG.INCONTACT != 0) .update else null,
        else => null,
    };
}

/// Pen pressure (0–1024) as 0..1; 0 while hovering.
pub fn pressureOf(raw: u32, flags: u32) f32 {
    if (flags & POINTER_FLAG.INCONTACT == 0) return 0;
    return @as(f32, @floatFromInt(@min(raw, 1024))) / 1024;
}

/// A pen button change for one pointer message.
pub const PenButton = struct { button: types.Button, pressed: bool };

/// The button change a pen message makes, given the button held since
/// contact (`held`, null when the pen is up). Contact presses the left
/// button, or the right one when the barrel button is held at contact;
/// lifting (or a cancel) releases whichever was pressed.
pub fn penButton(msg: u32, flags: u32, pen_flags: u32, held: ?types.Button) ?PenButton {
    const contact = flags & POINTER_FLAG.INCONTACT != 0 and flags & POINTER_FLAG.CANCELED == 0;
    if (held) |b| {
        if (!contact or msg == WM.POINTERUP) return .{ .button = b, .pressed = false };
        return null;
    }
    if (contact and msg != WM.POINTERUP) return .{ .button = if (pen_flags & PEN_FLAG.BARREL != 0) .right else .left, .pressed = true };
    return null;
}

/// The relative motion in a raw mouse report, or null for other devices,
/// absolute reports and button-only reports.
pub fn relativeMotion(ri: *const t.RAWINPUT) ?[2]f32 {
    if (ri.header.dwType != RAW.TYPEMOUSE) return null;
    const m = ri.data.mouse;
    if (m.usFlags & RAW.MOVE_ABSOLUTE != 0) return null;
    if (m.lLastX == 0 and m.lLastY == 0) return null;
    return .{ @floatFromInt(m.lLastX), @floatFromInt(m.lLastY) };
}

const testing = std.testing;

test "kindOf and touchPhase" {
    try testing.expectEqual(Kind.touch, kindOf(2));
    try testing.expectEqual(Kind.pen, kindOf(3));
    try testing.expectEqual(Kind.other, kindOf(4)); // PT_MOUSE
    try testing.expectEqual(Kind.other, kindOf(5)); // PT_TOUCHPAD
    const in = POINTER_FLAG.INCONTACT;
    try testing.expectEqual(types.Phase.begin, touchPhase(WM.POINTERDOWN, in).?);
    try testing.expectEqual(types.Phase.update, touchPhase(WM.POINTERUPDATE, in).?);
    try testing.expectEqual(@as(?types.Phase, null), touchPhase(WM.POINTERUPDATE, 0));
    try testing.expectEqual(types.Phase.end, touchPhase(WM.POINTERUP, 0).?);
    try testing.expectEqual(types.Phase.cancel, touchPhase(WM.POINTERUP, POINTER_FLAG.CANCELED).?);
}

test "pen pressure and buttons" {
    const in = POINTER_FLAG.INCONTACT;
    try testing.expectEqual(@as(f32, 0), pressureOf(512, 0));
    try testing.expectEqual(@as(f32, 0.5), pressureOf(512, in));
    try testing.expectEqual(@as(f32, 1), pressureOf(5000, in));
    // Hover: nothing; contact: left; barrel at contact: right.
    try testing.expectEqual(@as(?PenButton, null), penButton(WM.POINTERUPDATE, 0, 0, null));
    try testing.expectEqual(PenButton{ .button = .left, .pressed = true }, penButton(WM.POINTERDOWN, in, 0, null).?);
    try testing.expectEqual(PenButton{ .button = .right, .pressed = true }, penButton(WM.POINTERDOWN, in, PEN_FLAG.BARREL, null).?);
    // Held: drags change nothing; lifting or a cancel releases the held one.
    try testing.expectEqual(@as(?PenButton, null), penButton(WM.POINTERUPDATE, in, 0, .right));
    try testing.expectEqual(PenButton{ .button = .right, .pressed = false }, penButton(WM.POINTERUP, 0, 0, .right).?);
    try testing.expectEqual(PenButton{ .button = .left, .pressed = false }, penButton(WM.POINTERUPDATE, in | POINTER_FLAG.CANCELED, 0, .left).?);
}

test "relativeMotion" {
    var ri: t.RAWINPUT = .{
        .header = .{ .dwType = RAW.TYPEMOUSE, .dwSize = @sizeOf(t.RAWINPUT), .hDevice = null, .wParam = 0 },
        .data = .{ .mouse = .{ .usFlags = 0, .usButtonFlags = 0, .usButtonData = 0, .ulRawButtons = 0, .lLastX = -3, .lLastY = 7, .ulExtraInformation = 0 } },
    };
    try testing.expectEqual([2]f32{ -3, 7 }, relativeMotion(&ri).?);
    ri.data.mouse.usFlags = RAW.MOVE_ABSOLUTE;
    try testing.expectEqual(@as(?[2]f32, null), relativeMotion(&ri));
    ri.data.mouse.usFlags = 0;
    ri.data.mouse.lLastX = 0;
    ri.data.mouse.lLastY = 0;
    try testing.expectEqual(@as(?[2]f32, null), relativeMotion(&ri));
    ri.header.dwType = 1; // RIM_TYPEKEYBOARD
    ri.data.mouse.lLastX = 1;
    try testing.expectEqual(@as(?[2]f32, null), relativeMotion(&ri));
}
