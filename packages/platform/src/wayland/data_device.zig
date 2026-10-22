//! Selection bookkeeping shared by `wl_data_device` (the clipboard) and
//! `zwp_primary_selection_device_v1` (the primary selection), which have
//! the same shape: offers announce MIME types, `selection` names the
//! current offer, `receive` hands it a pipe; our sources answer `send`.
//! The backend decodes the protocols and calls these with its mutex held.

const std = @import("std");
const Allocator = std.mem.Allocator;
const clipboard = @import("../api/clipboard.zig");
const MimeId = clipboard.MimeId;
const Selection = clipboard.Selection;

/// Text MIME types, best first. `UTF8_STRING`, `TEXT` and `STRING` are
/// what X11 clients offer through Xwayland.
const text_mimes = [_][:0]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "TEXT", "STRING" };

/// The MIME types we offer, and accept, for `m`, best first.
pub fn mimesFor(m: MimeId) []const [:0]const u8 {
    return switch (m) {
        .text_utf8 => &text_mimes,
        .uri_list => &.{"text/uri-list"},
        .html => &.{"text/html"},
        .png => &.{"image/png"},
        .zigguro_internal => &.{"application/x-zigguro-internal"},
        _ => &.{},
    };
}

/// The format a `send(mime)` asks for.
pub fn idForMime(mime: []const u8) ?MimeId {
    inline for (.{ MimeId.text_utf8, .uri_list, .html, .png, .zigguro_internal }) |m| {
        for (mimesFor(m)) |s| if (std.mem.eql(u8, s, mime)) return m;
    }
    return null;
}

/// The best of `offered` for reading `want`, or null.
pub fn pickMime(want: MimeId, offered: []const [:0]u8) ?[:0]const u8 {
    for (mimesFor(want)) |s| for (offered) |o| if (std.mem.eql(u8, s, o)) return s;
    return null;
}

/// One offer the compositor created.
pub const Offer = struct {
    id: u32,
    /// The protocol it came from.
    which: Selection,
    /// MIME types announced so far.
    mimes: std.ArrayList([:0]u8) = .empty,

    fn deinit(o: *Offer, gpa: Allocator) void {
        for (o.mimes.items) |m| gpa.free(m);
        o.mimes.deinit(gpa);
    }
};

/// Live offers and the current one of each selection.
pub const Offers = struct {
    list: std.ArrayList(Offer) = .empty,
    /// The offer `selection` named last, per selection.
    current: [2]?u32 = .{ null, null },

    /// Frees everything.
    pub fn deinit(o: *Offers, gpa: Allocator) void {
        for (o.list.items) |*x| x.deinit(gpa);
        o.list.deinit(gpa);
    }

    /// `data_offer`: a new offer.
    pub fn add(o: *Offers, gpa: Allocator, id: u32, which: Selection) !void {
        try o.list.append(gpa, .{ .id = id, .which = which });
    }

    /// `offer(mime)` on offer `id`.
    pub fn addMime(o: *Offers, gpa: Allocator, id: u32, mime: []const u8) !void {
        const x = o.get(id) orelse return;
        if (x.mimes.items.len >= 64) return;
        const z = try gpa.dupeZ(u8, mime);
        errdefer gpa.free(z);
        try x.mimes.append(gpa, z);
    }

    /// The offer with object id `id`.
    pub fn get(o: *Offers, id: u32) ?*Offer {
        for (o.list.items) |*x| if (x.id == id) return x;
        return null;
    }

    /// The current offer of `which`.
    pub fn currentOf(o: *Offers, which: Selection) ?*Offer {
        return o.get(o.current[@intFromEnum(which)] orelse return null);
    }

    /// `selection(id)`. Returns the previous offer if it must now be
    /// destroyed (it is no longer current); the caller sends `destroy`
    /// and calls `remove`.
    pub fn setSelection(o: *Offers, which: Selection, id: ?u32) ?u32 {
        const slot = &o.current[@intFromEnum(which)];
        const old = slot.*;
        slot.* = id;
        if (old == null or old == id) return null;
        return old;
    }

    /// Forgets offer `id`.
    pub fn remove(o: *Offers, gpa: Allocator, id: u32) void {
        for (o.list.items, 0..) |*x, i| if (x.id == id) {
            x.deinit(gpa);
            _ = o.list.swapRemove(i);
            break;
        };
        for (&o.current) |*c| if (c.* == id) {
            c.* = null;
        };
    }
};

const testing = std.testing;

test "text prefers utf-8, then UTF8_STRING, then text/plain" {
    var a = [_][:0]u8{ @constCast("STRING"), @constCast("text/plain"), @constCast("UTF8_STRING") };
    try testing.expectEqualStrings("UTF8_STRING", pickMime(.text_utf8, &a).?);
    var b = [_][:0]u8{ @constCast("text/plain"), @constCast("text/plain;charset=utf-8") };
    try testing.expectEqualStrings("text/plain;charset=utf-8", pickMime(.text_utf8, &b).?);
    try testing.expectEqual(@as(?[:0]const u8, null), pickMime(.png, &b));
    try testing.expectEqual(MimeId.text_utf8, idForMime("UTF8_STRING").?);
    try testing.expectEqual(MimeId.uri_list, idForMime("text/uri-list").?);
    try testing.expectEqual(@as(?MimeId, null), idForMime("image/jpeg"));
}

test "offers: selection replaces and frees the old offer" {
    var o: Offers = .{};
    defer o.deinit(testing.allocator);
    try o.add(testing.allocator, 0xff000001, .clipboard);
    try o.addMime(testing.allocator, 0xff000001, "text/plain");
    try testing.expectEqual(@as(?u32, null), o.setSelection(.clipboard, 0xff000001));
    try testing.expectEqualStrings("text/plain", o.currentOf(.clipboard).?.mimes.items[0]);
    try o.add(testing.allocator, 0xff000002, .clipboard);
    try testing.expectEqual(@as(?u32, 0xff000001), o.setSelection(.clipboard, 0xff000002));
    o.remove(testing.allocator, 0xff000001);
    try testing.expectEqual(@as(?u32, 0xff000002), o.current[0]);
    try testing.expectEqual(@as(?u32, 0xff000002), o.setSelection(.clipboard, null));
    o.remove(testing.allocator, 0xff000002);
    try testing.expectEqual(@as(usize, 0), o.list.items.len);
    try testing.expectEqual(@as(?*Offer, null), o.currentOf(.primary));
}
