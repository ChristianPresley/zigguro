//! EWMH and Motif window-manager messages (E01.F05.S02.T01): reading
//! `_NET_WM_STATE`, `_NET_WM_MOVERESIZE` directions, `_NET_WM_PING`
//! replies and `_MOTIF_WM_HINTS` for client-side decorations. Pure
//! functions over wire bytes; the backend sends them.

const std = @import("std");
const types = @import("../api/types.zig");
const proto = @import("proto.zig");
const ResizeEdge = types.ResizeEdge;

/// `_NET_WM_STATE` client-message actions.
pub const StateAction = struct {
    /// Clear the states.
    pub const remove: u32 = 0;
    /// Set the states.
    pub const add: u32 = 1;
    /// Flip the states.
    pub const toggle: u32 = 2;
};

/// `_NET_WM_MOVERESIZE` direction for a keyboard-less move.
pub const move_direction: u32 = 8;

/// Source indication in EWMH client messages.
pub const Source = struct {
    /// A normal application.
    pub const application: u32 = 1;
    /// A pager or direct user action.
    pub const user: u32 = 2;
};

/// The `_NET_WM_MOVERESIZE` direction that resizes `e`.
pub fn resizeDirection(e: ResizeEdge) u32 {
    return switch (e) {
        .top_left => 0,
        .top => 1,
        .top_right => 2,
        .right => 3,
        .bottom_right => 4,
        .bottom => 5,
        .bottom_left => 6,
        .left => 7,
    };
}

/// `_MOTIF_WM_HINTS` asking for no decorations: flags = decorations (2),
/// functions 0, decorations 0, input mode 0, status 0.
pub fn motifNoDecorations() [5 * 4]u8 {
    var out: [5 * 4]u8 = @splat(0);
    std.mem.writeInt(u32, out[0..4], 2, .little);
    return out;
}

/// The state atoms `parseState` looks for.
pub const StateAtoms = struct {
    max_vert: u32,
    max_horz: u32,
    fullscreen: u32,
    hidden: u32,
};

/// A window's `_NET_WM_STATE`, as far as we use it.
pub const WmState = struct {
    /// Maximized both ways.
    maximized: bool = false,
    fullscreen: bool = false,
    /// Minimized (iconic).
    hidden: bool = false,
};

/// Reads a `_NET_WM_STATE` property value (a list of 32-bit atoms).
pub fn parseState(value: []const u8, a: StateAtoms) WmState {
    var vert = false;
    var horz = false;
    var st: WmState = .{};
    var i: usize = 0;
    while (i + 4 <= value.len) : (i += 4) {
        const x = std.mem.readInt(u32, value[i..][0..4], .little);
        if (x == a.max_vert) vert = true;
        if (x == a.max_horz) horz = true;
        if (x == a.fullscreen) st.fullscreen = true;
        if (x == a.hidden) st.hidden = true;
    }
    st.maximized = vert and horz;
    return st;
}

/// The reply to a `_NET_WM_PING` client message `ev`: the same event with
/// its window set to `root`, to be sent to the root window.
pub fn pong(ev: []const u8, root: u32) [32]u8 {
    var out: [32]u8 = undefined;
    @memcpy(&out, ev[0..32]);
    out[0] = proto.EventCode.client_message;
    std.mem.writeInt(u32, out[4..8], root, .little);
    return out;
}

/// True when `atoms` (a `_NET_SUPPORTED` value) lists `atom`.
pub fn lists(atoms: []const u8, atom: u32) bool {
    var i: usize = 0;
    while (i + 4 <= atoms.len) : (i += 4) {
        if (std.mem.readInt(u32, atoms[i..][0..4], .little) == atom) return true;
    }
    return false;
}

const testing = std.testing;

fn atomList(comptime xs: []const u32) [xs.len * 4]u8 {
    var out: [xs.len * 4]u8 = undefined;
    for (xs, 0..) |x, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], x, .little);
    return out;
}

test "_NET_WM_MOVERESIZE directions" {
    const want = [_]struct { ResizeEdge, u32 }{
        .{ .top_left, 0 },     .{ .top, 1 },    .{ .top_right, 2 },   .{ .right, 3 },
        .{ .bottom_right, 4 }, .{ .bottom, 5 }, .{ .bottom_left, 6 }, .{ .left, 7 },
    };
    for (want) |w| try testing.expectEqual(w[1], resizeDirection(w[0]));
    try testing.expectEqual(8, move_direction);
}

test "_NET_WM_STATE parsing: maximized needs both directions" {
    const a: StateAtoms = .{ .max_vert = 10, .max_horz = 11, .fullscreen = 12, .hidden = 13 };
    try testing.expectEqual(WmState{}, parseState(&.{}, a));
    try testing.expectEqual(WmState{}, parseState(&atomList(&.{ 10, 99 }), a));
    try testing.expectEqual(WmState{ .maximized = true }, parseState(&atomList(&.{ 11, 10 }), a));
    try testing.expectEqual(WmState{ .fullscreen = true, .hidden = true }, parseState(&atomList(&.{ 12, 13 }), a));
    // A trailing partial atom is ignored.
    try testing.expectEqual(WmState{ .fullscreen = true }, parseState(&(atomList(&.{12}) ++ [_]u8{ 13, 0 }), a));
}

test "ping reply and supported lists; Motif hints" {
    var ev: [32]u8 = @splat(0);
    ev[0] = proto.EventCode.client_message | 0x80;
    ev[1] = 32;
    std.mem.writeInt(u32, ev[4..8], 0x400001, .little);
    std.mem.writeInt(u32, ev[16..20], 1234, .little);
    const r = pong(&ev, 0x2a);
    try testing.expectEqual(proto.EventCode.client_message, r[0]);
    try testing.expectEqual(0x2a, std.mem.readInt(u32, r[4..8], .little));
    try testing.expectEqual(1234, std.mem.readInt(u32, r[16..20], .little));

    try testing.expect(lists(&atomList(&.{ 5, 6, 7 }), 6));
    try testing.expect(!lists(&atomList(&.{ 5, 7 }), 6));

    const m = motifNoDecorations();
    try testing.expectEqual(2, std.mem.readInt(u32, m[0..4], .little));
    try testing.expectEqual(0, std.mem.readInt(u32, m[8..12], .little));
}
