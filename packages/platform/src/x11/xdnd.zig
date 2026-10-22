//! XDND v5 drag and drop for the X11 backend (E01.F05.S03.T03): the
//! atoms, ClientMessage encoding and decoding, action mapping, and the
//! state of a drag over our windows (`Target`) and of a drag we started
//! (`Source`). The backend does the I/O: it answers positions with
//! `XdndStatus`, reads drops from `XdndSelection` through
//! `selection.zig`, grabs the pointer while dragging, and finds targets
//! under the pointer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../api/types.zig");
const clipboard = @import("../api/clipboard.zig");
const proto = @import("proto.zig");

const DragActions = clipboard.DragActions;
const WindowId = types.WindowId;
const le = std.builtin.Endian.little;

/// The protocol version we speak.
pub const version: u32 = 5;

/// Atoms XDND needs.
pub const atom_names = [_][]const u8{
    "XdndAware",
    "XdndEnter",
    "XdndPosition",
    "XdndStatus",
    "XdndLeave",
    "XdndDrop",
    "XdndFinished",
    "XdndTypeList",
    "XdndProxy",
    "XdndActionCopy",
    "XdndActionMove",
    "XdndActionLink",
    "XdndActionAsk",
    "XdndActionPrivate",
};
/// The interned `atom_names`.
pub const Atoms = @import("atoms.zig").AtomTable(&atom_names);

fn u32At(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], le);
}

/// A format-32 ClientMessage for `window` of type `ty` with `l`.
pub fn clientMessage(window: u32, ty: u32, l: [5]u32) [32]u8 {
    var ev: [32]u8 = @splat(0);
    ev[0] = proto.EventCode.client_message;
    ev[1] = 32;
    std.mem.writeInt(u32, ev[4..8], window, le);
    std.mem.writeInt(u32, ev[8..12], ty, le);
    for (l, 0..) |v, i| std.mem.writeInt(u32, ev[12 + i * 4 ..][0..4], v, le);
    return ev;
}

/// An XDND message we received.
pub const Message = union(enum) {
    /// A drag entered `window` (ours) from `source`.
    enter: struct { source: u32, version: u8, more_types: bool, types: [3]u32 },
    /// The pointer is at `root` (root coordinates) asking for `action`.
    position: struct { source: u32, root: [2]i16, time: u32, action: u32 },
    /// The target under our drag answered a position.
    status: struct { target: u32, accept: bool, action: u32 },
    /// The drag left.
    leave: struct { source: u32 },
    /// The user dropped at `time`.
    drop: struct { source: u32, time: u32 },
    /// The target finished with our drop.
    finished: struct { target: u32, accepted: bool, action: u32 },
};

/// Decodes a ClientMessage; null if it is not XDND.
pub fn decode(a: *const Atoms, ev: []const u8) ?Message {
    if (ev.len < 32 or ev[1] != 32) return null;
    const ty = u32At(ev, 8);
    const l = [5]u32{ u32At(ev, 12), u32At(ev, 16), u32At(ev, 20), u32At(ev, 24), u32At(ev, 28) };
    if (ty == a.get("XdndEnter")) return .{ .enter = .{ .source = l[0], .version = @truncate(l[1] >> 24), .more_types = l[1] & 1 != 0, .types = .{ l[2], l[3], l[4] } } };
    if (ty == a.get("XdndPosition")) return .{ .position = .{ .source = l[0], .root = .{ @bitCast(@as(u16, @truncate(l[2] >> 16))), @bitCast(@as(u16, @truncate(l[2]))) }, .time = l[3], .action = l[4] } };
    if (ty == a.get("XdndStatus")) return .{ .status = .{ .target = l[0], .accept = l[1] & 1 != 0, .action = l[4] } };
    if (ty == a.get("XdndLeave")) return .{ .leave = .{ .source = l[0] } };
    if (ty == a.get("XdndDrop")) return .{ .drop = .{ .source = l[0], .time = l[2] } };
    if (ty == a.get("XdndFinished")) return .{ .finished = .{ .target = l[0], .accepted = l[1] & 1 != 0, .action = l[2] } };
    return null;
}

/// The action an action atom names (private counts as copy).
pub fn actionOf(a: *const Atoms, atom: u32) DragActions {
    if (atom == a.get("XdndActionCopy") or atom == a.get("XdndActionPrivate")) return .{ .copy = true };
    if (atom == a.get("XdndActionMove")) return .{ .move = true };
    if (atom == a.get("XdndActionLink")) return .{ .link = true };
    if (atom == a.get("XdndActionAsk")) return .{ .ask = true };
    return .{};
}

/// The atom for one action of `set`: `requested` if `set` has it, else
/// copy, move, link, ask; 0 (None) for an empty set.
pub fn chooseAction(a: *const Atoms, set: DragActions, requested: u32) u32 {
    const r = actionOf(a, requested);
    if (@as(u8, @bitCast(r)) != 0 and @as(u8, @bitCast(r)) & @as(u8, @bitCast(set)) != 0) return requested;
    if (set.copy) return a.get("XdndActionCopy");
    if (set.move) return a.get("XdndActionMove");
    if (set.link) return a.get("XdndActionLink");
    if (set.ask) return a.get("XdndActionAsk");
    return 0;
}

/// Packs root coordinates for `XdndPosition`.
pub fn packRoot(x: i16, y: i16) u32 {
    return @as(u32, @as(u16, @bitCast(x))) << 16 | @as(u16, @bitCast(y));
}

/// A drag over one of our windows.
pub const Target = struct {
    source: u32,
    win: WindowId,
    /// Our window's id.
    xid: u32,
    /// min(ours, theirs).
    version: u8,
    /// Offered target atoms.
    types: std.ArrayList(u32) = .empty,
    /// Whether `drop{enter}` went out (on the first position, which
    /// carries the pointer position).
    entered: bool = false,
    /// Window position minus root position, found on the first position.
    offset: ?[2]i32 = null,
    pos: [2]f32 = .{ 0, 0 },
    /// The action the source asks for.
    requested: u32 = 0,
    /// The app's `set_drop_effect`.
    accept: ?clipboard.MimeId = null,
    effect: DragActions = .{},
    /// When the last message arrived; the drag ends 30 s later.
    last_ns: u64,
    /// Reading the dropped data; `action` is the atom performed.
    dropping: bool = false,
    action: u32 = 0,

    /// Frees the type list.
    pub fn deinit(t: *Target, gpa: Allocator) void {
        t.types.deinit(gpa);
    }

    /// Whether the app accepts a format the source offers.
    pub fn accepting(t: *const Target, offers: anytype) bool {
        const m = t.accept orelse return false;
        for (t.types.items) |ty| if (offers.mimeOfTarget(ty) == m) return @as(u8, @bitCast(t.effect)) != 0;
        return false;
    }

    /// The `XdndStatus` answer to send now.
    pub fn status(t: *const Target, a: *const Atoms, offers: anytype) [5]u32 {
        const ok = t.accepting(offers);
        // Bit 1: keep sending positions; the rectangle is empty.
        return .{ t.xid, @as(u32, @intFromBool(ok)) | 2, 0, 0, if (ok) chooseAction(a, t.effect, t.requested) else 0 };
    }

    /// The offered formats as packed little-endian `u16` `MimeId`s, each
    /// once.
    pub fn mimeIds(t: *const Target, offers: anytype, ours: bool, out: []u8) []u8 {
        var n: usize = 0;
        for (t.types.items) |ty| {
            const m = offers.mimeOfTarget(ty) orelse continue;
            if (m == .zigguro_internal and !ours) continue;
            const v: u16 = @intFromEnum(m);
            var seen = false;
            var i: usize = 0;
            while (i < n) : (i += 2) {
                if (std.mem.readInt(u16, out[i..][0..2], le) == v) seen = true;
            }
            if (seen or n + 2 > out.len) continue;
            std.mem.writeInt(u16, out[n..][0..2], v, le);
            n += 2;
        }
        return out[0..n];
    }
};

/// A drag we started.
pub const Source = struct {
    win: WindowId,
    allowed: DragActions,
    /// The target atoms we offer.
    types: std.ArrayList(u32) = .empty,
    /// The pointer grab is still to be taken (on the dispatching thread).
    grab_pending: bool = true,
    grabbed: bool = false,
    time: u32,
    /// The top-level window under the pointer last time, and the XDND
    /// window found in it.
    top: u32 = 0,
    found: ?Found = null,
    /// The current target and its answers.
    target: ?Found = null,
    waiting_status: bool = false,
    pending: ?[2]i16 = null,
    accepted: bool = false,
    action: u32 = 0,
    /// The button went up while a position was unanswered: the drop
    /// (or leave) waits for the status.
    release_pending: bool = false,
    /// After the drop: waiting for `XdndFinished` until `deadline_ns`.
    dropped: bool = false,
    deadline_ns: u64 = 0,

    /// An XDND-aware window: where messages go (`proxy`) and the window
    /// they name (`window`).
    pub const Found = struct { window: u32, proxy: u32, version: u8 };

    /// Frees the type list.
    pub fn deinit(s: *Source, gpa: Allocator) void {
        s.types.deinit(gpa);
    }

    /// The `XdndEnter` data: up to three types inline, else bit 0 (the
    /// list is in `XdndTypeList`).
    pub fn enterData(s: *const Source, source_win: u32, ver: u8) [5]u32 {
        var l: [5]u32 = .{ source_win, @as(u32, @min(ver, version)) << 24, 0, 0, 0 };
        if (s.types.items.len > 3) {
            l[1] |= 1;
        } else for (s.types.items, 0..) |t, i| {
            l[2 + i] = t;
        }
        return l;
    }

    /// The pointer moved to `root`: whether to send a position now (one
    /// is in flight otherwise, and `root` waits as the latest pending).
    pub fn moved(s: *Source, root: [2]i16) bool {
        if (s.waiting_status) {
            s.pending = root;
            return false;
        }
        s.waiting_status = true;
        return true;
    }

    /// The target answered: the pending position to send next, if any.
    pub fn statusArrived(s: *Source, accept: bool, action: u32) ?[2]i16 {
        s.waiting_status = false;
        s.accepted = accept;
        s.action = action;
        const p = s.pending orelse return null;
        s.pending = null;
        s.waiting_status = true;
        return p;
    }

    /// A new target (or none): answers and pending positions reset.
    pub fn retarget(s: *Source, f: ?Found) void {
        s.target = f;
        s.waiting_status = false;
        s.pending = null;
        s.accepted = false;
        s.action = 0;
    }
};

const testing = std.testing;

fn testAtoms() Atoms {
    var a: Atoms = .{};
    for (&a.ids, 0..) |*v, i| v.* = @intCast(300 + i);
    return a;
}

/// Stand-in for `Selections.mimeOfTarget` in tests: 1 = uri-list,
/// 2 = UTF8_STRING, 3 = private.
const FakeOffers = struct {
    fn mimeOfTarget(_: FakeOffers, atom: u32) ?clipboard.MimeId {
        return switch (atom) {
            1 => .uri_list,
            2 => .text_utf8,
            3 => .zigguro_internal,
            else => null,
        };
    }
};

test "enter, position and drop messages decode; root coordinates pack" {
    const a = testAtoms();
    const enter = clientMessage(7, a.get("XdndEnter"), .{ 0x400001, 5 << 24 | 1, 10, 11, 12 });
    const e = decode(&a, &enter).?.enter;
    try testing.expectEqual(@as(u32, 0x400001), e.source);
    try testing.expectEqual(@as(u8, 5), e.version);
    try testing.expect(e.more_types);
    try testing.expectEqual([3]u32{ 10, 11, 12 }, e.types);
    const pos = clientMessage(7, a.get("XdndPosition"), .{ 0x400001, 0, packRoot(300, -2), 99, a.get("XdndActionMove") });
    const p = decode(&a, &pos).?.position;
    try testing.expectEqual([2]i16{ 300, -2 }, p.root);
    try testing.expectEqual(@as(u32, 99), p.time);
    try testing.expectEqual(DragActions{ .move = true }, actionOf(&a, p.action));
    const drop = clientMessage(7, a.get("XdndDrop"), .{ 0x400001, 0, 1234, 0, 0 });
    try testing.expectEqual(@as(u32, 1234), decode(&a, &drop).?.drop.time);
    const other = clientMessage(7, 5, .{ 0, 0, 0, 0, 0 });
    try testing.expect(decode(&a, &other) == null);
}

test "position → status layout: accept bit, empty rect, action" {
    const a = testAtoms();
    var t: Target = .{ .source = 1, .win = @enumFromInt(1), .xid = 0x200001, .version = 5, .last_ns = 0 };
    defer t.deinit(testing.allocator);
    try t.types.appendSlice(testing.allocator, &.{ 2, 1 });
    t.requested = a.get("XdndActionMove");
    // Before the app answers: refused, no action, positions wanted.
    try testing.expectEqual([5]u32{ 0x200001, 2, 0, 0, 0 }, t.status(&a, FakeOffers{}));
    t.accept = .uri_list;
    t.effect = .{ .copy = true, .move = true };
    try testing.expectEqual([5]u32{ 0x200001, 3, 0, 0, a.get("XdndActionMove") }, t.status(&a, FakeOffers{}));
    t.effect = .{ .copy = true };
    try testing.expectEqual(a.get("XdndActionCopy"), t.status(&a, FakeOffers{})[4]);
    // A format the source does not offer is refused.
    t.accept = .png;
    try testing.expectEqual(@as(u32, 2), t.status(&a, FakeOffers{})[1]);
}

test "offered mime ids skip unknown and foreign private types" {
    var t: Target = .{ .source = 1, .win = @enumFromInt(1), .xid = 1, .version = 5, .last_ns = 0 };
    defer t.deinit(testing.allocator);
    try t.types.appendSlice(testing.allocator, &.{ 9, 1, 2, 3, 2 });
    var buf: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), t.mimeIds(FakeOffers{}, false, &buf).len);
    try testing.expectEqual(@as(usize, 6), t.mimeIds(FakeOffers{}, true, &buf).len);
}

test "source: enter data inline or by list; one position in flight" {
    var s: Source = .{ .win = @enumFromInt(1), .allowed = .{ .copy = true }, .time = 0 };
    defer s.deinit(testing.allocator);
    try s.types.appendSlice(testing.allocator, &.{ 1, 2 });
    try testing.expectEqual([5]u32{ 9, 4 << 24, 1, 2, 0 }, s.enterData(9, 4));
    try s.types.appendSlice(testing.allocator, &.{ 3, 4 });
    try testing.expectEqual([5]u32{ 9, 5 << 24 | 1, 0, 0, 0 }, s.enterData(9, 7));

    try testing.expect(s.moved(.{ 1, 1 }));
    try testing.expect(!s.moved(.{ 2, 2 }));
    try testing.expect(!s.moved(.{ 3, 3 }));
    // The status releases only the latest pending position.
    try testing.expectEqual(@as(?[2]i16, .{ 3, 3 }), s.statusArrived(true, 77));
    try testing.expect(s.accepted);
    try testing.expectEqual(@as(?[2]i16, null), s.statusArrived(true, 77));
    try testing.expect(s.moved(.{ 4, 4 }));
    s.retarget(null);
    try testing.expect(!s.accepted and !s.waiting_status);
}

test "choose action: requested when allowed, else copy first" {
    const a = testAtoms();
    try testing.expectEqual(a.get("XdndActionMove"), chooseAction(&a, .{ .copy = true, .move = true }, a.get("XdndActionMove")));
    try testing.expectEqual(a.get("XdndActionCopy"), chooseAction(&a, .{ .copy = true }, a.get("XdndActionMove")));
    try testing.expectEqual(a.get("XdndActionLink"), chooseAction(&a, .{ .link = true }, 0));
    try testing.expectEqual(@as(u32, 0), chooseAction(&a, .{}, a.get("XdndActionCopy")));
}
