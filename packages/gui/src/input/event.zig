//! Input events as widgets see them, and `EventCx`, the handle a widget's
//! `event` function uses to respond, take focus or capture the pointer.
//! Positions are logical pixels in window coordinates.

const std = @import("std");
const zg_platform = @import("zg_platform");
const geom = @import("../core/geom.zig");
const ids = @import("../core/ids.zig");
const response = @import("../core/response.zig");

const keys = zg_platform.keys;

/// Mouse buttons.
pub const Button = enum(u8) { left, right, middle, back, forward };

/// A pointer event.
pub const Pointer = struct {
    pos: geom.Vec2,
    button: Button = .left,
    clicks: u8 = 1,
    mods: keys.Mods = .{},
};

/// A key event.
pub const KeyPress = struct {
    key: keys.Key,
    mods: keys.Mods = .{},
    action: keys.KeyAction = .press,
    /// The character the key produces, or 0.
    codepoint: u21 = 0,
};

/// A wheel or touchpad scroll; positive `dy` scrolls content up.
pub const Scroll = struct {
    pos: geom.Vec2,
    dx: f32,
    dy: f32,
    /// True for pixel-precise (touchpad) deltas, false for wheel lines.
    precise: bool = false,
};

/// An event delivered to a widget.
pub const InputEvent = union(enum) {
    pointer_move: Pointer,
    pointer_down: Pointer,
    pointer_up: Pointer,
    /// The pointer left the node (hover ended).
    pointer_leave,
    scroll: Scroll,
    key: KeyPress,
    /// Committed text (typing, IME commit, paste).
    text: []const u8,
    focus_gained,
    focus_lost,
    /// Activation by keyboard (Enter/Space on a focused control).
    activate,
};

/// Dispatch phase.
pub const Phase = enum(u8) { capture, target, bubble };

/// The window-side operations an `EventCx` forwards to.
pub const Sink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// The operations.
    pub const VTable = struct {
        respond: *const fn (*anyopaque, ids.NodeId, response.Response) void,
        repaint: *const fn (*anyopaque, ids.NodeId) void,
        focus: *const fn (*anyopaque, ids.NodeId) void,
        capture: *const fn (*anyopaque, ids.NodeId) void,
        release: *const fn (*anyopaque) void,
        setCursor: *const fn (*anyopaque, zg_platform.cursor.CursorShape) void,
        nodeRect: *const fn (*anyopaque, ids.NodeId) geom.Rect,
    };
};

/// Passed to `W.event(ec, props, state, ev)`.
pub const EventCx = struct {
    sink: Sink,
    node: ids.NodeId,
    target: ids.NodeId,
    phase: Phase,
    /// Set by `stopPropagation`.
    stopped: bool = false,

    /// Reports interaction flags to the owning view's next build (sets
    /// `Response` bits and schedules the view).
    pub fn respond(ec: *EventCx, r: response.Response) void {
        ec.sink.vtable.respond(ec.sink.ptr, ec.node, r);
    }

    /// Repaints the node without rebuilding its view.
    pub fn repaint(ec: *EventCx) void {
        ec.sink.vtable.repaint(ec.sink.ptr, ec.node);
    }

    /// Moves keyboard focus to this node.
    pub fn focus(ec: *EventCx) void {
        ec.sink.vtable.focus(ec.sink.ptr, ec.node);
    }

    /// Routes pointer events to this node until `releaseCapture`.
    pub fn capture(ec: *EventCx) void {
        ec.sink.vtable.capture(ec.sink.ptr, ec.node);
    }

    /// Ends pointer capture.
    pub fn releaseCapture(ec: *EventCx) void {
        ec.sink.vtable.release(ec.sink.ptr);
    }

    /// Sets the pointer cursor shape.
    pub fn setCursor(ec: *EventCx, shape: zg_platform.cursor.CursorShape) void {
        ec.sink.vtable.setCursor(ec.sink.ptr, shape);
    }

    /// Stops the event from reaching further nodes.
    pub fn stopPropagation(ec: *EventCx) void {
        ec.stopped = true;
    }

    /// The node's absolute rectangle from the last paint.
    pub fn rect(ec: *EventCx) geom.Rect {
        return ec.sink.vtable.nodeRect(ec.sink.ptr, ec.node);
    }

    /// `p` relative to the node's top-left corner.
    pub fn local(ec: *EventCx, p: geom.Vec2) geom.Vec2 {
        const r = ec.rect();
        return .{ .x = p.x - r.x, .y = p.y - r.y };
    }
};

test {
    std.testing.refAllDecls(@This());
}
