//! IME on Wayland through `zwp_text_input_v3` (E01.F04.S03.T01): the
//! state each window asked for with `set_ime_state`, what we sent the
//! compositor, and the event batches it answers with.
//!
//! Requests: the first state after an `enter` sends `enable`; every state
//! sends `set_content_type`, `set_text_change_cause` with
//! `set_surrounding_text` (a window of at most 4000 bytes around the
//! caret and anchor, cut at UTF-8 boundaries), `set_cursor_rectangle` in
//! surface-local logical coordinates, then `commit`, counted in
//! `commit_count`. Disabling sends `disable` and `commit`.
//!
//! Events: `preedit_string`, `commit_string` and
//! `delete_surrounding_text` are buffered until `done`, which stages
//! `ime_delete_surrounding`, `text_input` and `ime_preedit` in that order
//! (the protocol's order of application). A preedit not repeated in a
//! batch is gone, so a shown preedit is cleared with an empty one. When
//! `done`'s serial is not our `commit_count`, the IME saw an older state:
//! the events still apply, and the caller sends the current state again.
//! `leave` clears a shown preedit; the compositor disables the text input
//! then, so the next `enter` enables it again.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wl = @import("wl_gen");
const types = @import("../api/types.zig");
const ImePurpose = @import("../api/ime.zig").ImePurpose;
const Surrounding = @import("../api/ime.zig").Surrounding;
const scale = @import("scale.zig");
const WindowId = types.WindowId;
const TI = wl.zwp_text_input_v3;

/// The protocol's limit on surrounding text, in bytes.
pub const max_surrounding: usize = 4000;

/// The content type for `p`.
pub fn contentType(p: ImePurpose) struct { hint: TI.ContentHint, purpose: TI.ContentPurpose } {
    const hint: TI.ContentHint = switch (p) {
        .normal => .{ .completion = true, .spellcheck = true },
        .password, .pin => .{ .hidden_text = true, .sensitive_data = true },
        .name => .{ .auto_capitalization = true },
        else => .{},
    };
    return .{ .hint = hint, .purpose = @enumFromInt(@intFromEnum(p)) };
}

/// The part of the surrounding text to send: `text[start..end]` with the
/// caret and anchor relative to `start`.
pub const SurroundingWindow = struct { start: usize, end: usize, cursor: u32, anchor: u32 };

fn isCont(c: u8) bool {
    return c & 0xC0 == 0x80;
}

/// Back to the start of the character containing byte `i`.
fn floorChar(text: []const u8, i: usize) usize {
    var j = @min(i, text.len);
    while (j > 0 and j < text.len and isCont(text[j])) j -= 1;
    return j;
}

/// At most `max` bytes of `text` around `cursor` and `anchor`, cut at
/// character boundaries. A selection longer than `max` keeps the caret's
/// end, with the anchor clamped into the window.
pub fn surroundingWindow(text: []const u8, cursor_in: u32, anchor_in: u32, max: usize) SurroundingWindow {
    const cursor = floorChar(text, cursor_in);
    const anchor = floorChar(text, anchor_in);
    var start: usize = 0;
    var end: usize = text.len;
    if (text.len > max) {
        const lo = @min(cursor, anchor);
        const hi = @max(cursor, anchor);
        // Centre the selection, or the caret alone when it does not fit.
        const a, const z = if (hi - lo <= max) .{ lo, hi } else .{ cursor, cursor };
        const slack = max - (z - a);
        start = a -| slack / 2;
        end = @min(text.len, start + max);
        start = end -| max;
        // Shrink to character boundaries.
        while (start < text.len and start > 0 and isCont(text[start])) start += 1;
        end = floorChar(text, end);
    }
    return .{
        .start = start,
        .end = end,
        .cursor = @intCast(std.math.clamp(cursor, start, end) - start),
        .anchor = @intCast(std.math.clamp(anchor, start, end) - start),
    };
}

/// A rectangle in physical pixels as surface-local logical coordinates.
pub fn logicalRect(r: types.PxRect, scale120: u32) [4]i32 {
    const s: i64 = @max(scale120, 1);
    const u: i64 = scale.unit;
    const div = struct {
        fn f(v: i64, d: i64) i32 {
            return @intCast(@divFloor(v * u + @divFloor(d, 2), d));
        }
    }.f;
    return .{ div(r.x, s), div(r.y, s), div(r.w, s), div(r.h, s) };
}

/// What the app asked for one window with `set_ime_state`.
pub const Want = struct {
    enabled: bool = false,
    purpose: ImePurpose = .normal,
    caret: types.PxRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Owned copy of the surrounding text.
    text: ?[]u8 = null,
    cursor: u32 = 0,
    anchor: u32 = 0,

    /// Replaces the state with a copy of the command's.
    pub fn set(w: *Want, gpa: Allocator, enabled: bool, purpose: ImePurpose, caret: types.PxRect, sur: ?Surrounding) !void {
        const text: ?[]u8 = if (sur) |s| try gpa.dupe(u8, s.text) else null;
        w.deinit(gpa);
        w.* = .{ .enabled = enabled, .purpose = purpose, .caret = caret, .text = text };
        if (sur) |s| {
            w.cursor = s.cursor_byte;
            w.anchor = s.anchor_byte;
        }
    }

    /// Frees the text.
    pub fn deinit(w: *Want, gpa: Allocator) void {
        if (w.text) |t| gpa.free(t);
        w.text = null;
    }
};

/// Events buffered until `done`.
pub const Pending = struct {
    preedit: ?[]u8 = null,
    begin: i32 = -1,
    end: i32 = -1,
    commit: ?[]u8 = null,
    delete: ?[2]u32 = null,

    fn put(gpa: Allocator, slot: *?[]u8, text: ?[]const u8) !void {
        const copy: ?[]u8 = if (text) |t| try gpa.dupe(u8, t) else null;
        if (slot.*) |old| gpa.free(old);
        slot.* = copy;
    }

    /// Frees everything.
    pub fn clear(p: *Pending, gpa: Allocator) void {
        if (p.preedit) |x| gpa.free(x);
        if (p.commit) |x| gpa.free(x);
        p.* = .{};
    }
};

/// The text input's state.
pub const State = struct {
    /// The window whose surface the text input entered.
    focus: ?WindowId = null,
    /// `enable` sent since the last `enter`.
    enabled: bool = false,
    /// `commit` requests sent.
    commit_count: u32 = 0,
    pending: Pending = .{},
    /// A non-empty preedit is showing.
    preedit_shown: bool = false,
    /// The IME changed the text since the last state we sent.
    ime_edited: bool = false,

    /// Frees the buffered events.
    pub fn deinit(s: *State, gpa: Allocator) void {
        s.pending.clear(gpa);
    }

    /// `preedit_string`.
    pub fn onPreedit(s: *State, gpa: Allocator, text: ?[]const u8, begin: i32, end: i32) !void {
        try Pending.put(gpa, &s.pending.preedit, text);
        s.pending.begin = begin;
        s.pending.end = end;
    }

    /// `commit_string`.
    pub fn onCommit(s: *State, gpa: Allocator, text: ?[]const u8) !void {
        try Pending.put(gpa, &s.pending.commit, text);
    }

    /// `delete_surrounding_text`.
    pub fn onDelete(s: *State, before: u32, after: u32) void {
        s.pending.delete = .{ before, after };
    }

    /// `enter` on `win`'s surface: the caller sends `win`'s state.
    pub fn onEnter(s: *State, gpa: Allocator, win: WindowId) void {
        s.pending.clear(gpa);
        s.focus = win;
        s.enabled = false;
    }

    /// `leave`: clears a shown preedit.
    pub fn onLeave(s: *State, gpa: Allocator, out: anytype) !void {
        s.pending.clear(gpa);
        if (s.focus) |w| if (s.preedit_shown) try out.stage(.{ .ime_preedit = .{ .win = w, .text = .empty, .cursor_begin = -1, .cursor_end = -1 } });
        s.preedit_shown = false;
        s.focus = null;
        s.enabled = false;
    }

    /// `done`: stages the batch. Returns whether the caller must send
    /// the current state again (the serial is stale).
    pub fn onDone(s: *State, gpa: Allocator, out: anytype, serial: u32) !bool {
        defer s.pending.clear(gpa);
        const p = &s.pending;
        if (s.focus) |w| {
            if (p.delete) |d| {
                try out.stage(.{ .ime_delete_surrounding = .{ .win = w, .before_bytes = d[0], .after_bytes = d[1] } });
                s.ime_edited = true;
            }
            if (p.commit) |t| if (t.len > 0) {
                try out.stage(.{ .text_input = .{ .win = w, .text = out.text(t) } });
                s.ime_edited = true;
            };
            if (p.preedit) |t| if (t.len > 0) {
                try out.stage(.{ .ime_preedit = .{ .win = w, .text = out.text(t), .cursor_begin = p.begin, .cursor_end = p.end } });
                s.preedit_shown = true;
                return serial != s.commit_count;
            };
            if (s.preedit_shown) try out.stage(.{ .ime_preedit = .{ .win = w, .text = .empty, .cursor_begin = -1, .cursor_end = -1 } });
            s.preedit_shown = false;
        }
        return serial != s.commit_count;
    }

    /// Sends `want` (focus window, `scale120`) and commits.
    pub fn send(s: *State, gpa: Allocator, conn: anytype, ti: TI.Id, want: *const Want, scale120: u32) !void {
        if (!want.enabled) {
            if (!s.enabled) return;
            try TI.disable(conn, ti);
            try TI.commit(conn, ti);
            s.enabled = false;
            s.commit_count +%= 1;
            return;
        }
        if (!s.enabled) try TI.enable(conn, ti);
        s.enabled = true;
        const ct = contentType(want.purpose);
        try TI.setContentType(conn, ti, ct.hint, ct.purpose);
        if (want.text) |text| {
            const win = surroundingWindow(text, want.cursor, want.anchor, max_surrounding);
            const z = try gpa.dupeZ(u8, text[win.start..win.end]);
            defer gpa.free(z);
            try TI.setTextChangeCause(conn, ti, if (s.ime_edited) .input_method else .other);
            try TI.setSurroundingText(conn, ti, z, @intCast(win.cursor), @intCast(win.anchor));
        }
        s.ime_edited = false;
        const r = logicalRect(want.caret, scale120);
        try TI.setCursorRectangle(conn, ti, r[0], r[1], r[2], r[3]);
        try TI.commit(conn, ti);
        s.commit_count +%= 1;
    }
};

const testing = std.testing;

const Rec = struct {
    events: std.ArrayList(@import("../api/event.zig").Event) = .empty,
    texts: std.ArrayList([]u8) = .empty,

    fn deinit(r: *Rec) void {
        for (r.texts.items) |t| testing.allocator.free(t);
        r.texts.deinit(testing.allocator);
        r.events.deinit(testing.allocator);
    }
    /// Records `ev`.
    pub fn stage(r: *Rec, ev: @import("../api/event.zig").Event) !void {
        try r.events.append(testing.allocator, ev);
    }
    /// Keeps a copy of `bytes`; `off` is its index.
    pub fn text(r: *Rec, bytes: []const u8) types.PayloadSlice {
        const owned = testing.allocator.dupe(u8, bytes) catch return .empty;
        r.texts.append(testing.allocator, owned) catch unreachable;
        return .{ .off = @intCast(r.texts.items.len - 1), .len = @intCast(bytes.len) };
    }
    fn textOf(r: *const Rec, p: types.PayloadSlice) []const u8 {
        return if (p.len == 0) "" else r.texts.items[p.off];
    }
};

const w1: WindowId = @enumFromInt(1);

test "done applies in protocol order and clears a preedit not repeated" {
    const gpa = testing.allocator;
    var r: Rec = .{};
    defer r.deinit();
    var s: State = .{};
    defer s.deinit(gpa);
    s.onEnter(gpa, w1);
    s.commit_count = 3;
    try s.onPreedit(gpa, "nǐ", 0, 3);
    try testing.expect(!try s.onDone(gpa, &r, 3));
    try s.onCommit(gpa, "你");
    s.onDelete(2, 0);
    try s.onPreedit(gpa, "h", -1, -1);
    try testing.expect(!try s.onDone(gpa, &r, 3));
    const E = @import("../api/event.zig").Event;
    const tags = [_]std.meta.Tag(E){ .ime_preedit, .ime_delete_surrounding, .text_input, .ime_preedit };
    try testing.expectEqual(tags.len, r.events.items.len);
    for (tags, r.events.items) |t, e| try testing.expectEqual(t, std.meta.activeTag(e));
    try testing.expectEqualStrings("nǐ", r.textOf(r.events.items[0].ime_preedit.text));
    try testing.expectEqual(3, r.events.items[0].ime_preedit.cursor_end);
    try testing.expectEqual(2, r.events.items[1].ime_delete_surrounding.before_bytes);
    try testing.expectEqualStrings("你", r.textOf(r.events.items[2].text_input.text));
    try testing.expectEqual(-1, r.events.items[3].ime_preedit.cursor_begin);
    // A batch without a preedit ends the shown one; then nothing more.
    try testing.expect(try s.onDone(gpa, &r, 2));
    try testing.expectEqual(0, r.events.items[4].ime_preedit.text.len);
    _ = try s.onDone(gpa, &r, 3);
    try testing.expectEqual(5, r.events.items.len);
}

test "leave clears a shown preedit and needs a new enable" {
    const gpa = testing.allocator;
    var r: Rec = .{};
    defer r.deinit();
    var s: State = .{};
    defer s.deinit(gpa);
    s.onEnter(gpa, w1);
    s.enabled = true;
    try s.onPreedit(gpa, "a", 1, 1);
    _ = try s.onDone(gpa, &r, 0);
    try s.onPreedit(gpa, "ab", 2, 2);
    try s.onLeave(gpa, &r);
    try testing.expectEqual(2, r.events.items.len);
    try testing.expectEqual(0, r.events.items[1].ime_preedit.text.len);
    try testing.expectEqual(null, s.focus);
    try testing.expect(!s.enabled);
    // Without focus, a stray batch stages nothing.
    try s.onCommit(gpa, "x");
    _ = try s.onDone(gpa, &r, 0);
    try testing.expectEqual(2, r.events.items.len);
}

test "surrounding text windowing keeps offsets valid at UTF-8 boundaries" {
    // Short text: all of it.
    const w0 = surroundingWindow("héllo", 3, 1, max_surrounding);
    try testing.expectEqual(SurroundingWindow{ .start = 0, .end = 6, .cursor = 3, .anchor = 1 }, w0);
    // A caret inside a character moves to its start.
    try testing.expectEqual(1, surroundingWindow("héllo", 2, 2, max_surrounding).cursor);

    // 3-byte characters, a window of 10 bytes around byte 30.
    const text = "日本語日本語日本語日本語日本語日本語日本語";
    const w = surroundingWindow(text, 30, 30, 10);
    try testing.expect(w.end - w.start <= 10);
    try testing.expect(std.unicode.utf8ValidateSlice(text[w.start..w.end]));
    try testing.expectEqual(30, w.start + w.cursor);
    // A selection that fits is kept whole.
    const sel = surroundingWindow(text, 33, 27, 10);
    try testing.expectEqual(27, sel.start + sel.anchor);
    try testing.expectEqual(33, sel.start + sel.cursor);
    try testing.expect(std.unicode.utf8ValidateSlice(text[sel.start..sel.end]));
    // A longer one keeps the caret; the anchor is clamped to the edge.
    const long = surroundingWindow(text, 60, 0, 10);
    try testing.expectEqual(60, long.start + long.cursor);
    try testing.expectEqual(0, long.anchor);
    try testing.expect(std.unicode.utf8ValidateSlice(text[long.start..long.end]));
    // At the ends of the text.
    const head = surroundingWindow(text, 0, 0, 10);
    try testing.expectEqual(0, head.start);
    const tail = surroundingWindow(text, text.len, text.len, 10);
    try testing.expectEqual(text.len, tail.end);
    try testing.expectEqual(text.len - tail.start, tail.cursor);
}

test "content types and logical rectangles" {
    const pw = contentType(.password);
    try testing.expect(pw.hint.sensitive_data and pw.hint.hidden_text);
    try testing.expectEqual(TI.ContentPurpose.password, pw.purpose);
    try testing.expectEqual(TI.ContentPurpose.terminal, contentType(.terminal).purpose);
    try testing.expectEqual(TI.ContentPurpose.datetime, contentType(.datetime).purpose);
    // 1.5x: physical / 1.5.
    try testing.expectEqual([4]i32{ 20, -10, 2, 13 }, logicalRect(.{ .x = 30, .y = -15, .w = 3, .h = 20 }, 180));
}
