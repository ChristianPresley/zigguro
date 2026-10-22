//! The Emacs kill ring (GNU Emacs manual, "Kill Ring"): up to
//! `kill-ring-max` (120) killed texts, newest last. Consecutive kills
//! append to the newest entry (forward kills after it, backward kills
//! before it). `C-y` yanks the entry at the yank pointer and `M-y` moves
//! the pointer to older entries, wrapping around; a later `C-y` yanks
//! where the pointer was left, as in Emacs.
//!
//! An entry keeps one piece per cursor so a multi-cursor kill yanks back
//! one piece per cursor; the ring and the clipboard see the pieces joined
//! with line breaks (the multi-cursor clipboard rule). The system
//! clipboard follows every kill; when it changed outside the editor since
//! the last kill, `C-y` pushes its text onto the ring and yanks that
//! (Emacs's interprogram paste).

const std = @import("std");
const mode = @import("../mode.zig");

const Allocator = std.mem.Allocator;
pub const ClipboardPort = mode.ClipboardPort;

pub const Append = enum { no, after, before };

pub const Entry = struct {
    /// One piece per cursor that killed (one for a single cursor).
    pieces: [][]u8,
    /// The pieces joined with "\n".
    joined: []u8,

    fn deinit(e: *Entry, gpa: Allocator) void {
        for (e.pieces) |p| gpa.free(p);
        gpa.free(e.pieces);
        gpa.free(e.joined);
    }

    fn rejoin(e: *Entry, gpa: Allocator) !void {
        const j = try std.mem.join(gpa, "\n", e.pieces);
        gpa.free(e.joined);
        e.joined = j;
    }
};

pub const KillRing = struct {
    gpa: Allocator,
    max: u32 = 120,
    /// Oldest first.
    entries: std.ArrayList(Entry) = .empty,
    /// The entry `C-y` yanks (index into `entries`).
    yank_index: usize = 0,
    clipboard: ?ClipboardPort = null,
    /// The clipboard text as the ring last set or took it.
    last_clip: ?[]u8 = null,

    pub fn init(gpa: Allocator) KillRing {
        return .{ .gpa = gpa };
    }

    pub fn deinit(k: *KillRing) void {
        for (k.entries.items) |*e| e.deinit(k.gpa);
        k.entries.deinit(k.gpa);
        if (k.last_clip) |c| k.gpa.free(c);
    }

    pub fn len(k: *const KillRing) usize {
        return k.entries.items.len;
    }

    /// Kills `text` (one cursor).
    pub fn kill(k: *KillRing, text: []const u8, append: Append) !void {
        return k.killPieces(&.{text}, append);
    }

    /// Kills one piece per cursor. With `append` and an entry to append
    /// to, each piece joins the matching piece of the newest entry (or the
    /// whole texts join when the counts differ).
    pub fn killPieces(k: *KillRing, pieces: []const []const u8, append: Append) !void {
        const gpa = k.gpa;
        if (append != .no and k.entries.items.len > 0) {
            const e = &k.entries.items[k.entries.items.len - 1];
            if (e.pieces.len == pieces.len) {
                for (e.pieces, pieces) |*old, new| old.* = try joinTwo(gpa, old.*, new, append);
            } else {
                const all = try std.mem.join(gpa, "\n", pieces);
                defer gpa.free(all);
                const merged = try joinTwo(gpa, try gpa.dupe(u8, e.joined), all, append);
                for (e.pieces) |p| gpa.free(p);
                gpa.free(e.pieces);
                e.pieces = try gpa.alloc([]u8, 1);
                e.pieces[0] = merged;
            }
            try e.rejoin(gpa);
        } else {
            const own = try gpa.alloc([]u8, pieces.len);
            var n: usize = 0;
            errdefer {
                for (own[0..n]) |p| gpa.free(p);
                gpa.free(own);
            }
            for (pieces) |p| {
                own[n] = try gpa.dupe(u8, p);
                n += 1;
            }
            var e: Entry = .{ .pieces = own, .joined = try std.mem.join(gpa, "\n", own) };
            errdefer e.deinit(gpa);
            try k.push(e);
        }
        k.yank_index = k.entries.items.len - 1;
        const newest = k.entries.items[k.yank_index].joined;
        try k.noteClip(newest);
        if (k.clipboard) |cb| cb.setFn(cb.ctx, .clipboard, newest) catch {};
    }

    fn push(k: *KillRing, e: Entry) !void {
        if (k.entries.items.len >= k.max) {
            var old = k.entries.orderedRemove(0);
            old.deinit(k.gpa);
        }
        try k.entries.append(k.gpa, e);
    }

    fn noteClip(k: *KillRing, text: []const u8) !void {
        const copy = try k.gpa.dupe(u8, text);
        if (k.last_clip) |c| k.gpa.free(c);
        k.last_clip = copy;
    }

    /// Emacs `current-kill`: moves the yank pointer `n` entries toward
    /// older ones (negative: newer), wrapping, and returns that entry.
    /// With `n` 0 the clipboard is consulted first. Null when empty.
    pub fn current(k: *KillRing, n: i64) !?*const Entry {
        if (n == 0) try k.takeClipboard();
        const count = k.entries.items.len;
        if (count == 0) return null;
        const c: i64 = @intCast(count);
        const i: i64 = @intCast(k.yank_index);
        k.yank_index = @intCast(@mod(i - n, c));
        return &k.entries.items[k.yank_index];
    }

    /// The text `C-y` inserts (joined), or null when there is nothing.
    pub fn yank(k: *KillRing) !?[]const u8 {
        const e = try k.current(0) orelse return null;
        return e.joined;
    }

    /// The next older entry, for `M-y` right after a yank.
    pub fn yankPop(k: *KillRing) ?[]const u8 {
        const e = (k.current(1) catch unreachable) orelse return null;
        return e.joined;
    }

    /// Pushes the clipboard's text when it changed outside the ring.
    fn takeClipboard(k: *KillRing) !void {
        const cb = k.clipboard orelse return;
        const text = (cb.getFn(cb.ctx, .clipboard, k.gpa) catch return) orelse return;
        defer k.gpa.free(text);
        if (text.len == 0) return;
        if (k.last_clip) |c| if (std.mem.eql(u8, c, text)) return;
        const own = try k.gpa.alloc([]u8, 1);
        own[0] = k.gpa.dupe(u8, text) catch |e| {
            k.gpa.free(own);
            return e;
        };
        var e: Entry = .{ .pieces = own, .joined = undefined };
        e.joined = k.gpa.dupe(u8, text) catch |err| {
            k.gpa.free(own[0]);
            k.gpa.free(own);
            return err;
        };
        errdefer e.deinit(k.gpa);
        try k.push(e);
        k.yank_index = k.entries.items.len - 1;
        try k.noteClip(text);
    }
};

/// `old` with `new` after (or before) it; frees `old`.
fn joinTwo(gpa: Allocator, old: []u8, new: []const u8, append: Append) ![]u8 {
    defer gpa.free(old);
    return if (append == .before)
        std.mem.concat(gpa, u8, &.{ new, old })
    else
        std.mem.concat(gpa, u8, &.{ old, new });
}

test "emacs: kill append forward/backward" {
    const gpa = std.testing.allocator;
    var k: KillRing = .init(gpa);
    defer k.deinit();
    try k.kill("foo", .no);
    try k.kill(" bar", .after);
    try k.kill("<", .before);
    try std.testing.expectEqualStrings("<foo bar", (try k.yank()).?);
    try std.testing.expectEqual(@as(usize, 1), k.len());
    try k.kill("next", .no);
    try std.testing.expectEqual(@as(usize, 2), k.len());
    // Multi-cursor pieces append piecewise.
    try k.killPieces(&.{ "a", "b" }, .no);
    try k.killPieces(&.{ "1", "2" }, .after);
    const e = (try k.current(0)).?;
    try std.testing.expectEqualStrings("a1", e.pieces[0]);
    try std.testing.expectEqualStrings("b2", e.pieces[1]);
    try std.testing.expectEqualStrings("a1\nb2", e.joined);
}

test "emacs: yank-pop rotation" {
    const gpa = std.testing.allocator;
    var k: KillRing = .init(gpa);
    defer k.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), try k.yank());
    k.max = 3;
    for ([_][]const u8{ "one", "two", "three", "four" }) |t| try k.kill(t, .no);
    // The oldest fell off.
    try std.testing.expectEqual(@as(usize, 3), k.len());
    try std.testing.expectEqualStrings("four", (try k.yank()).?);
    try std.testing.expectEqualStrings("three", k.yankPop().?);
    try std.testing.expectEqualStrings("two", k.yankPop().?);
    try std.testing.expectEqualStrings("four", k.yankPop().?);
    try std.testing.expectEqualStrings("three", k.yankPop().?);
    // C-y yanks where M-y left the pointer.
    try std.testing.expectEqualStrings("three", (try k.yank()).?);
    // A new kill resets it.
    try k.kill("five", .no);
    try std.testing.expectEqualStrings("five", (try k.yank()).?);
}

test "emacs: clipboard interop" {
    const gpa = std.testing.allocator;
    const Fake = struct {
        text: ?[]const u8 = null,
        buf: [64]u8 = undefined,
        fn get(ctx: *anyopaque, _: ClipboardPort.Which, a: Allocator) anyerror!?[]u8 {
            const f: *@This() = @ptrCast(@alignCast(ctx));
            return if (f.text) |t| try a.dupe(u8, t) else null;
        }
        fn set(ctx: *anyopaque, _: ClipboardPort.Which, t: []const u8) anyerror!void {
            const f: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(f.buf[0..t.len], t);
            f.text = f.buf[0..t.len];
        }
    };
    var fake: Fake = .{};
    var k: KillRing = .init(gpa);
    defer k.deinit();
    k.clipboard = .{ .ctx = &fake, .getFn = Fake.get, .setFn = Fake.set };
    // A kill sets the clipboard.
    try k.kill("killed", .no);
    try std.testing.expectEqualStrings("killed", fake.text.?);
    // Unchanged clipboard: the ring's entry is yanked, nothing is pushed.
    try std.testing.expectEqualStrings("killed", (try k.yank()).?);
    try std.testing.expectEqual(@as(usize, 1), k.len());
    // Another program copied: C-y yanks that and keeps it in the ring.
    fake.text = "from outside";
    try std.testing.expectEqualStrings("from outside", (try k.yank()).?);
    try std.testing.expectEqual(@as(usize, 2), k.len());
    try std.testing.expectEqualStrings("killed", k.yankPop().?);
    // M-y does not look at the clipboard again.
    try std.testing.expectEqualStrings("from outside", k.yankPop().?);
    try std.testing.expectEqual(@as(usize, 2), k.len());
}
