//! Pending agent changes in an open document, as tracked changes
//! (E13.F04.S01.T02): the hunks of changesets waiting for review, kept in
//! step with the person's edits, plus provisional text while an agent's
//! `doc_propose_edit` or `doc_insert` call is still streaming in.
//!
//! The editor draws them (insertions as tinted ghost text, deletions
//! struck through, replacements both); this model decides where they are,
//! which one the cursor is on, and what accepting or rejecting does. An
//! edit by the person that touches a hunk drops it (the review shows it
//! as stale); edits elsewhere move hunks along.

const std = @import("std");
const words_mod = @import("words.zig");
const sections = @import("sections.zig");

const Allocator = std.mem.Allocator;
const Hunk = words_mod.Hunk;

pub const Kind = enum { insertion, deletion, replacement };

pub const Change = struct {
    /// Null while the tool call is still streaming.
    changeset: ?u64,
    /// The hunk's index within its changeset.
    hunk: u32 = 0,
    /// The streaming tool call it came from.
    call: u64 = 0,
    /// The range of the document it replaces.
    start: u32,
    end: u32,
    /// The proposed text (owned).
    new: []const u8,

    pub fn provisional(c: *const Change) bool {
        return c.changeset == null;
    }

    pub fn kind(c: *const Change) Kind {
        if (c.start == c.end) return .insertion;
        if (c.new.len == 0) return .deletion;
        return .replacement;
    }
};

/// E12: records a decision on one hunk; `stale` marks a hunk the person
/// edited over.
pub const DecidePort = struct {
    ctx: *anyopaque,
    decide: *const fn (ctx: *anyopaque, changeset: u64, hunk: u32, d: Decision) anyerror!void,
};

pub const Decision = enum { accept, reject, stale };

pub const TrackedChanges = struct {
    gpa: Allocator,
    /// In document order.
    items: std.ArrayList(Change) = .empty,
    port: ?DecidePort = null,
    /// Bumped on every change (views compare it).
    revision: u64 = 0,

    pub fn init(gpa: Allocator, port: ?DecidePort) TrackedChanges {
        return .{ .gpa = gpa, .port = port };
    }

    pub fn deinit(t: *TrackedChanges) void {
        for (t.items.items) |c| t.gpa.free(c.new);
        t.items.deinit(t.gpa);
    }

    /// A changeset's hunks (offsets into the current document).
    pub fn add(t: *TrackedChanges, changeset: u64, hunks: []const Hunk) !void {
        for (hunks, 0..) |h, i| try t.insertSorted(.{ .changeset = changeset, .hunk = @intCast(i), .start = h.start, .end = h.end, .new = try t.gpa.dupe(u8, h.new) });
        t.revision += 1;
    }

    fn insertSorted(t: *TrackedChanges, c: Change) !void {
        var i: usize = t.items.items.len;
        while (i > 0 and t.items.items[i - 1].start > c.start) i -= 1;
        try t.items.insert(t.gpa, i, c);
    }

    // ---- streaming ----

    /// The agent's tool input so far (`tool` is `doc_propose_edit` or
    /// `doc_insert`): shows its `new_text`/`text` provisionally, once
    /// where it goes is known. `text` is the current document.
    pub fn streamDelta(t: *TrackedChanges, call: u64, tool: []const u8, partial_json: []const u8, text: []const u8) !void {
        const insert = std.mem.eql(u8, tool, "doc_insert");
        var scratch: std.heap.ArenaAllocator = .init(t.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const new = (try partialString(a, partial_json, if (insert) "text" else "new_text")) orelse return;
        const idx = t.findCall(call);
        if (idx == null) {
            // Where it goes: the old text (complete), or after the section.
            const range: [2]u32 = if (insert) blk: {
                const after = try partialString(a, partial_json, "after_section");
                if (after) |s| {
                    if (!s.complete) return;
                    const out = try sections.outline(a, text);
                    const i = sections.find(out, s.text) orelse return;
                    break :blk .{ out[i].range.end, out[i].range.end };
                }
                break :blk .{ @intCast(text.len), @intCast(text.len) };
            } else blk: {
                const old = (try partialString(a, partial_json, "old_text")) orelse return;
                if (!old.complete or old.text.len == 0) return;
                const pos = std.mem.indexOf(u8, text, old.text) orelse return;
                break :blk .{ @intCast(pos), @intCast(pos + old.text.len) };
            };
            try t.insertSorted(.{ .changeset = null, .call = call, .start = range[0], .end = range[1], .new = try t.gpa.dupe(u8, new.text) });
        } else {
            const c = &t.items.items[idx.?];
            t.gpa.free(c.new);
            c.new = try t.gpa.dupe(u8, new.text);
        }
        t.revision += 1;
    }

    /// The call finished: its provisional text gives way to the
    /// changeset's hunks (or just goes, when the call failed).
    pub fn streamEnd(t: *TrackedChanges, call: u64, result: ?struct { changeset: u64, hunks: []const Hunk }) !void {
        while (t.findCall(call)) |i| {
            const c = t.items.orderedRemove(i);
            t.gpa.free(c.new);
        }
        if (result) |r| try t.add(r.changeset, r.hunks);
        t.revision += 1;
    }

    fn findCall(t: *const TrackedChanges, call: u64) ?usize {
        for (t.items.items, 0..) |c, i| if (c.provisional() and c.call == call) return i;
        return null;
    }

    // ---- the person's edits ----

    /// The person replaced `old_len` bytes at `start` with `new_len`:
    /// hunks it touches are dropped (and marked stale for review), later
    /// ones move. Returns how many were dropped.
    pub fn onUserEdit(t: *TrackedChanges, start: u32, old_len: u32, new_len: u32) u32 {
        const end = start + old_len;
        var dropped: u32 = 0;
        var i: usize = 0;
        while (i < t.items.items.len) {
            const c = &t.items.items[i];
            const touches = if (c.start == c.end)
                // An insertion point strictly inside the edited range.
                c.start > start and c.start < end
            else if (old_len == 0)
                // Typing strictly inside the hunk's range.
                start > c.start and start < c.end
            else
                start < c.end and end > c.start;
            if (touches) {
                if (c.changeset) |cs| if (t.port) |p| p.decide(p.ctx, cs, c.hunk, .stale) catch {};
                t.gpa.free(c.new);
                _ = t.items.orderedRemove(i);
                dropped += 1;
                continue;
            }
            // At or after the edit (typing right before a hunk pushes it along).
            if (c.start >= end) {
                c.start = c.start - old_len + new_len;
                c.end = c.end - old_len + new_len;
            }
            i += 1;
        }
        if (dropped > 0 or old_len > 0 or new_len > 0) t.revision += 1;
        return dropped;
    }

    // ---- navigation and decisions ----

    /// The change the cursor is on (inside it or at its edges).
    pub fn at(t: *const TrackedChanges, cursor: u32) ?usize {
        for (t.items.items, 0..) |c, i| if (cursor >= c.start and cursor <= c.end) return i;
        return null;
    }

    /// The first change starting after `cursor` (wrapping around).
    pub fn next(t: *const TrackedChanges, cursor: u32) ?usize {
        if (t.items.items.len == 0) return null;
        for (t.items.items, 0..) |c, i| if (c.start > cursor) return i;
        return 0;
    }

    /// The last change starting before `cursor` (wrapping around).
    pub fn prev(t: *const TrackedChanges, cursor: u32) ?usize {
        const n = t.items.items.len;
        if (n == 0) return null;
        var i = n;
        while (i > 0) {
            i -= 1;
            if (t.items.items[i].start < cursor) return i;
        }
        return n - 1;
    }

    /// Accepts or rejects change `i` (provisional ones cannot be decided).
    pub fn decide(t: *TrackedChanges, i: usize, d: Decision) !bool {
        if (i >= t.items.items.len) return false;
        const c = t.items.items[i];
        const cs = c.changeset orelse return false;
        if (t.port) |p| try p.decide(p.ctx, cs, c.hunk, d);
        _ = t.items.orderedRemove(i);
        t.gpa.free(c.new);
        t.revision += 1;
        return true;
    }

    /// Accepts or rejects every decided change within `range`; how many.
    pub fn decideIn(t: *TrackedChanges, range: sections.Range, d: Decision) !u32 {
        var n: u32 = 0;
        var i: usize = 0;
        while (i < t.items.items.len) {
            const c = t.items.items[i];
            if (c.changeset != null and c.start >= range.start and c.end <= range.end) {
                _ = try t.decide(i, d);
                n += 1;
            } else i += 1;
        }
        return n;
    }

    /// Whether any change lies within `range` (the outline's dot).
    pub fn pendingIn(t: *const TrackedChanges, range: sections.Range) bool {
        for (t.items.items) |c| if (c.start >= range.start and c.start < range.end) return true;
        return false;
    }

    /// What a screen reader says for change `i`, such as "insertion
    /// pending, 42 words".
    pub fn describe(t: *const TrackedChanges, a: Allocator, i: usize, text: []const u8) Allocator.Error![]const u8 {
        const c = t.items.items[i];
        const n = switch (c.kind()) {
            .deletion => sections.countWords(text[@min(c.start, text.len)..@min(c.end, text.len)]),
            else => sections.countWords(c.new),
        };
        return std.fmt.allocPrint(a, "{s} {s}, {d} word{s}", .{ @tagName(c.kind()), if (c.provisional()) "streaming" else "pending", n, if (n == 1) "" else "s" });
    }
};

pub const Partial = struct {
    /// Decoded so far.
    text: []const u8,
    /// The closing quote has arrived.
    complete: bool,
};

/// The value of string field `name` in a JSON object that may be cut off
/// anywhere: what has arrived of it, decoded, or null before it starts.
/// Only top-level fields count; an escape cut in half is left for the
/// next delta.
pub fn partialString(a: Allocator, json: []const u8, name: []const u8) Allocator.Error!?Partial {
    var i: usize = 0;
    var depth: u32 = 0;
    // Walk the object: keys at depth 1, skipping strings and nesting.
    while (i < json.len) {
        const c = json[i];
        switch (c) {
            '{', '[' => {
                depth += 1;
                i += 1;
            },
            '}', ']' => {
                depth -|= 1;
                i += 1;
            },
            '"' => {
                const s_end = stringEnd(json, i + 1) orelse return null;
                if (depth == 1 and std.mem.eql(u8, json[i + 1 .. s_end], name)) {
                    var j = s_end + 1;
                    while (j < json.len and isWs(json[j])) j += 1;
                    if (j < json.len and json[j] == ':') {
                        j += 1;
                        while (j < json.len and isWs(json[j])) j += 1;
                        if (j >= json.len) return null;
                        if (json[j] != '"') return null;
                        return try decode(a, json[j + 1 ..]);
                    }
                }
                i = s_end + 1;
            },
            else => i += 1,
        }
    }
    return null;
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// The index of the quote ending a string whose body starts at `from`.
fn stringEnd(s: []const u8, from: usize) ?usize {
    var i = from;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
        } else if (s[i] == '"') return i;
    }
    return null;
}

fn decode(a: Allocator, s: []const u8) Allocator.Error!Partial {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '"') return .{ .text = out.items, .complete = true };
        if (c != '\\') {
            try out.append(a, c);
            i += 1;
            continue;
        }
        if (i + 1 >= s.len) break;
        const e = s[i + 1];
        switch (e) {
            'n' => try out.append(a, '\n'),
            't' => try out.append(a, '\t'),
            'r' => try out.append(a, '\r'),
            'b' => try out.append(a, 8),
            'f' => try out.append(a, 12),
            'u' => {
                if (i + 6 > s.len) break;
                var cp: u21 = std.fmt.parseInt(u16, s[i + 2 .. i + 6], 16) catch 0xFFFD;
                var used: usize = 6;
                if (cp >= 0xD800 and cp < 0xDC00) {
                    if (i + 12 > s.len) break;
                    const lo = std.fmt.parseInt(u16, s[i + 8 .. i + 12], 16) catch 0;
                    if (s[i + 6] == '\\' and s[i + 7] == 'u' and lo >= 0xDC00 and lo < 0xE000) {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        used = 12;
                    } else cp = 0xFFFD;
                } else if (cp >= 0xDC00 and cp < 0xE000) cp = 0xFFFD;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                try out.appendSlice(a, buf[0..n]);
                i += used;
                continue;
            },
            else => try out.append(a, e),
        }
        i += 2;
    }
    return .{ .text = out.items, .complete = false };
}
