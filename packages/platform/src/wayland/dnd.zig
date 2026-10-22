//! Wayland drag and drop (E01.F04.S03.T03): the state of a drag over our
//! windows (target) and of a drag we started (source), plus conversions
//! between `DragActions` and `wl_data_device_manager.dnd_action` and the
//! `enter` MIME list. The backend drives these from `wl_data_device`,
//! `wl_data_offer` and `wl_data_source` events with its mutex held;
//! payloads move through `linux/pipe_transfer.zig` on the platform thread.

const std = @import("std");
const wl = @import("wl_gen");
const types = @import("../api/types.zig");
const clipboard = @import("../api/clipboard.zig");
const data_device = @import("data_device.zig");

const DragActions = clipboard.DragActions;
const MimeId = clipboard.MimeId;
const DndAction = wl.wl_data_device_manager.DndAction;
const WindowId = types.WindowId;

/// Our actions as protocol actions (Wayland has no link).
pub fn toWl(a: DragActions) DndAction {
    return .{ .copy = a.copy, .move = a.move, .ask = a.ask };
}

/// Protocol actions as ours.
pub fn fromWl(a: DndAction) DragActions {
    return .{ .copy = a.copy, .move = a.move, .ask = a.ask };
}

/// The one action to prefer among `a`: copy, then move, then ask.
pub fn preferred(a: DragActions) DndAction {
    if (a.copy) return .{ .copy = true };
    if (a.move) return .{ .move = true };
    if (a.ask) return .{ .ask = true };
    return .{};
}

/// The offered MIME types as packed little-endian `u16` `MimeId`s (the
/// `enter` event's `mimes`), each once. `application/x-zigguro-internal`
/// counts only when `ours` (the drag is one we started).
pub fn offeredIds(mimes: []const [:0]u8, ours: bool, out: []u8) []u8 {
    var n: usize = 0;
    for (mimes) |m| {
        const id = data_device.idForMime(m) orelse continue;
        if (id == .zigguro_internal and !ours) continue;
        const v: u16 = @intFromEnum(id);
        var seen = false;
        var i: usize = 0;
        while (i < n) : (i += 2) {
            if (std.mem.readInt(u16, out[i..][0..2], .little) == v) seen = true;
        }
        if (seen or n + 2 > out.len) continue;
        std.mem.writeInt(u16, out[n..][0..2], v, .little);
        n += 2;
    }
    return out[0..n];
}

/// A drag over one of our windows.
pub const Target = struct {
    /// The drag's offer (null when the source offers no data).
    offer: ?u32 = null,
    win: WindowId,
    /// The `enter` serial, for `accept`.
    serial: u32,
    pos: [2]f32,
    /// What we told the compositor, once we told it anything.
    sent: ?Answer = null,

    /// An `accept` + `set_actions` pair.
    pub const Answer = struct { mime: ?[:0]const u8, actions: DragActions };

    /// The answer for the app's `set_drop_effect`: the offered MIME type
    /// for `accept` (or none) and, with a type, `effect`.
    pub fn answerFor(offered: []const [:0]u8, accept: ?MimeId, effect: DragActions) Answer {
        const mime = if (accept) |m| data_device.pickMime(m, offered) else null;
        return .{ .mime = mime, .actions = if (mime == null) .{} else effect };
    }

    /// Whether `a` changes the MIME type told so far.
    pub fn mimeChanged(t: *const Target, a: Answer) bool {
        const s = t.sent orelse return true;
        if (s.mime == null or a.mime == null) return (s.mime == null) != (a.mime == null);
        return !std.mem.eql(u8, s.mime.?, a.mime.?);
    }

    /// Whether `a` changes the actions told so far.
    pub fn actionsChanged(t: *const Target, a: Answer) bool {
        const s = t.sent orelse return true;
        return @as(u8, @bitCast(s.actions)) != @as(u8, @bitCast(a.actions));
    }
};

/// A dropped offer whose payload is being read.
pub const Dropped = struct {
    offer: u32,
    win: WindowId,
    pos: [2]f32,
    /// The action the drop performs.
    action: DragActions,
};

/// A drag we started.
pub const Source = struct {
    /// The `wl_data_source`.
    source: u32,
    /// The window it started from.
    win: WindowId,
    /// The action the compositor chose last.
    action: DragActions = .{},
};

const testing = std.testing;

test "actions convert both ways; preferred picks one" {
    const a: DragActions = .{ .copy = true, .move = true, .link = true };
    const w = toWl(a);
    try testing.expect(w.copy and w.move and !w.ask);
    try testing.expectEqual(DragActions{ .copy = true, .move = true }, fromWl(w));
    try testing.expectEqual(DndAction{ .move = true }, preferred(.{ .move = true, .ask = true }));
    try testing.expectEqual(DndAction{}, preferred(.{ .link = true }));
}

test "offered ids: known types once, private only for our drags" {
    var mimes = [_][:0]u8{ @constCast("text/uri-list"), @constCast("UTF8_STRING"), @constCast("text/plain"), @constCast("image/jpeg"), @constCast("application/x-zigguro-internal") };
    var buf: [16]u8 = undefined;
    const theirs = offeredIds(&mimes, false, &buf);
    try testing.expectEqual(@as(usize, 4), theirs.len);
    try testing.expectEqual(@intFromEnum(MimeId.uri_list), std.mem.readInt(u16, theirs[0..2], .little));
    try testing.expectEqual(@intFromEnum(MimeId.text_utf8), std.mem.readInt(u16, theirs[2..4], .little));
    const ours = offeredIds(&mimes, true, &buf);
    try testing.expectEqual(@as(usize, 6), ours.len);
    try testing.expectEqual(@intFromEnum(MimeId.zigguro_internal), std.mem.readInt(u16, ours[4..6], .little));
}

test "answers: accept maps to an offered type; changes are detected" {
    var mimes = [_][:0]u8{ @constCast("text/uri-list"), @constCast("text/plain") };
    var t: Target = .{ .win = @enumFromInt(1), .serial = 5, .pos = .{ 0, 0 } };
    const a = Target.answerFor(&mimes, .uri_list, .{ .copy = true });
    try testing.expectEqualStrings("text/uri-list", a.mime.?);
    try testing.expect(t.mimeChanged(a) and t.actionsChanged(a));
    t.sent = a;
    try testing.expect(!t.mimeChanged(Target.answerFor(&mimes, .uri_list, .{ .copy = true })));
    try testing.expect(t.actionsChanged(Target.answerFor(&mimes, .uri_list, .{ .move = true })));
    const none = Target.answerFor(&mimes, .png, .{ .copy = true });
    try testing.expectEqual(@as(?[:0]const u8, null), none.mime);
    try testing.expectEqual(DragActions{}, none.actions);
    try testing.expect(t.mimeChanged(none));
}
