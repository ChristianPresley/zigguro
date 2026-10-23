//! Sticky anchors for document sessions (E13.F04.S01.T01): positions that
//! follow the user's edits. Each edit shifts the anchors after it; an
//! anchor inside replaced text moves to the edge its bias names. An anchor
//! also keeps up to 64 bytes of the text around it, so a position that
//! drifted (edits the session missed, a reload) is found again by its
//! quote, the nearest occurrence winning.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const AnchorId = u32;

/// Which side of an insertion at the anchor it stays on.
pub const Bias = enum { left, right };

pub const quote_max = 64;

pub const Anchor = struct {
    offset: u32,
    bias: Bias,
    /// The text around the anchor when it was made.
    quote: [quote_max]u8 = undefined,
    quote_len: u8 = 0,
    /// Where the anchor sits within `quote`.
    quote_at: u8 = 0,
    live: bool = true,

    pub fn quoteText(a: *const Anchor) []const u8 {
        return a.quote[0..a.quote_len];
    }
};

pub const Resolved = struct {
    offset: u32,
    /// False when the quote was not found and the offset is a guess.
    exact: bool,
};

/// The anchor position of the occurrence of `needle` nearest to `off`,
/// where the anchor sits `at` bytes into the needle.
fn locate(text: []const u8, needle: []const u8, off: u32, at: u32) ?u32 {
    const centre: usize = if (off >= at) off - at else 0;
    if (centre + needle.len <= text.len and std.mem.eql(u8, text[centre .. centre + needle.len], needle)) return off;
    const after = std.mem.indexOfPos(u8, text, @min(centre, text.len), needle);
    const before = std.mem.lastIndexOf(u8, text[0..@min(text.len, centre + needle.len - 1)], needle);
    const best = if (after) |x| (if (before) |y| (if (x - centre <= centre - y) x else y) else x) else before;
    return if (best) |b| @intCast(b + at) else null;
}

pub const Anchors = struct {
    items: std.ArrayList(Anchor) = .empty,

    pub fn deinit(s: *Anchors, gpa: Allocator) void {
        s.items.deinit(gpa);
    }

    /// An anchor at `offset` in `text`.
    pub fn create(s: *Anchors, gpa: Allocator, text: []const u8, offset: u32, bias: Bias) Allocator.Error!AnchorId {
        const off = @min(offset, @as(u32, @intCast(text.len)));
        var a: Anchor = .{ .offset = off, .bias = bias };
        const before = @min(off, quote_max / 2);
        const from = off - before;
        const to = @min(text.len, from + quote_max);
        @memcpy(a.quote[0 .. to - from], text[from..to]);
        a.quote_len = @intCast(to - from);
        a.quote_at = @intCast(before);
        try s.items.append(gpa, a);
        return @intCast(s.items.items.len - 1);
    }

    pub fn remove(s: *Anchors, id: AnchorId) void {
        if (id < s.items.items.len) s.items.items[id].live = false;
    }

    pub fn get(s: *const Anchors, id: AnchorId) ?Anchor {
        if (id >= s.items.items.len or !s.items.items[id].live) return null;
        return s.items.items[id];
    }

    /// Follows an edit that replaced `old_len` bytes at `start` with
    /// `new_len` bytes.
    pub fn applyEdit(s: *Anchors, start: u32, old_len: u32, new_len: u32) void {
        const old_end = start + old_len;
        for (s.items.items) |*a| {
            if (!a.live) continue;
            if (a.offset < start or (a.offset == start and old_len == 0 and a.bias == .left)) continue;
            if (a.offset >= old_end and !(a.offset == start and old_len == 0)) {
                a.offset = a.offset - old_len + new_len;
            } else {
                // Inside the replaced text (or at an insertion point).
                a.offset = if (a.bias == .left) start else start + new_len;
            }
        }
    }

    /// Where anchor `id` is in `text`: its offset when the text around it
    /// is unchanged, else the nearest place its quote (or, after an edit
    /// near it, the part of the quote after or before it) occurs, else its
    /// offset, flagged inexact.
    pub fn resolve(s: *const Anchors, id: AnchorId, text: []const u8) ?Resolved {
        const a = s.get(id) orelse return null;
        const off = @min(a.offset, @as(u32, @intCast(text.len)));
        const q = a.quoteText();
        if (q.len == 0) return .{ .offset = off, .exact = true };
        if (locate(text, q, off, a.quote_at)) |x| return .{ .offset = x, .exact = true };
        const tail = q[a.quote_at..];
        if (tail.len >= 8) if (locate(text, tail, off, 0)) |x| return .{ .offset = x, .exact = true };
        const head = q[0..a.quote_at];
        if (head.len >= 8) if (locate(text, head, off, @intCast(head.len))) |x| return .{ .offset = x, .exact = true };
        return .{ .offset = off, .exact = false };
    }
};
