//! The text field model (E04.F05.S02.T01): `TextBuffer`, a UTF-8 gap
//! buffer, plus the `Selection` and `Preedit` a field keeps per node.
//! Offsets are byte offsets into the logical text (the gap excluded) and
//! always sit on grapheme boundaries once a command has run.

const std = @import("std");

/// A UTF-8 gap buffer sized for text fields (up to a few MB). Edits at
/// the caret are O(edit); moving the gap costs one memmove of the bytes
/// between the old and new position.
pub const TextBuffer = struct {
    gpa: std.mem.Allocator,
    mem: []u8 = &.{},
    gap_start: u32 = 0,
    gap_end: u32 = 0,
    /// Bumped on every change, so views can tell the text changed.
    version: u32 = 0,

    /// A buffer holding a copy of `initial`.
    pub fn init(gpa: std.mem.Allocator, initial: []const u8) !TextBuffer {
        var b: TextBuffer = .{ .gpa = gpa };
        try b.replace(.{ 0, 0 }, initial);
        b.version = 0;
        return b;
    }

    /// Frees the storage.
    pub fn deinit(b: *TextBuffer) void {
        if (b.mem.len > 0) b.gpa.free(b.mem);
        b.* = .{ .gpa = b.gpa };
    }

    /// The length of the text in bytes.
    pub fn len(b: *const TextBuffer) u32 {
        return @intCast(b.mem.len - (b.gap_end - b.gap_start));
    }

    /// The text as one slice. Moves the gap to the end, so the slice stays
    /// valid until the next `replace`.
    pub fn slice(b: *TextBuffer) []const u8 {
        b.moveGap(b.len());
        return b.mem[0..b.gap_start];
    }

    /// The byte at logical offset `i`.
    pub fn byteAt(b: *const TextBuffer, i: u32) u8 {
        return if (i < b.gap_start) b.mem[i] else b.mem[i + (b.gap_end - b.gap_start)];
    }

    /// Replaces the bytes in `range` (start, end) with `text`.
    pub fn replace(b: *TextBuffer, range: [2]u32, text: []const u8) !void {
        std.debug.assert(range[0] <= range[1] and range[1] <= b.len());
        try b.ensureGap(text.len);
        b.moveGap(range[0]);
        b.gap_end += range[1] - range[0];
        @memcpy(b.mem[b.gap_start..][0..text.len], text);
        b.gap_start += @intCast(text.len);
        b.version +%= 1;
    }

    /// Replaces the whole text.
    pub fn setText(b: *TextBuffer, text: []const u8) !void {
        try b.replace(.{ 0, b.len() }, text);
    }

    fn moveGap(b: *TextBuffer, to: u32) void {
        if (to < b.gap_start) {
            const n = b.gap_start - to;
            std.mem.copyBackwards(u8, b.mem[b.gap_end - n .. b.gap_end], b.mem[to..b.gap_start]);
            b.gap_start = to;
            b.gap_end -= n;
        } else if (to > b.gap_start) {
            const n = to - b.gap_start;
            std.mem.copyForwards(u8, b.mem[b.gap_start..][0..n], b.mem[b.gap_end..][0..n]);
            b.gap_start += n;
            b.gap_end += n;
        }
    }

    fn ensureGap(b: *TextBuffer, n: usize) !void {
        if (b.gap_end - b.gap_start >= n) return;
        const used = b.len();
        const cap = @max(b.mem.len * 2, used + n + 64);
        if (cap > std.math.maxInt(u32)) return error.OutOfMemory;
        const mem = try b.gpa.alloc(u8, cap);
        const tail = b.mem.len - b.gap_end;
        @memcpy(mem[0..b.gap_start], b.mem[0..b.gap_start]);
        @memcpy(mem[cap - tail ..], b.mem[b.gap_end..]);
        if (b.mem.len > 0) b.gpa.free(b.mem);
        b.mem = mem;
        b.gap_end = @intCast(cap - tail);
    }
};

/// A selection: `anchor` stays put while `head` (the caret) moves.
pub const Selection = struct {
    anchor: u32 = 0,
    head: u32 = 0,
    /// The x position vertical moves aim for (multi-line), kept across
    /// consecutive Up/Down presses.
    goal_x: ?f32 = null,

    /// A caret at `at`.
    pub fn caret(at: u32) Selection {
        return .{ .anchor = at, .head = at };
    }

    /// The smaller end.
    pub fn start(s: Selection) u32 {
        return @min(s.anchor, s.head);
    }

    /// The larger end.
    pub fn end(s: Selection) u32 {
        return @max(s.anchor, s.head);
    }

    /// The selected range (start, end).
    pub fn range(s: Selection) [2]u32 {
        return .{ s.start(), s.end() };
    }

    /// True for a bare caret.
    pub fn isEmpty(s: Selection) bool {
        return s.anchor == s.head;
    }

    /// Clamps both ends to `n` bytes.
    pub fn clamp(s: *Selection, n: u32) void {
        s.anchor = @min(s.anchor, n);
        s.head = @min(s.head, n);
    }
};

/// IME composition text shown inline at the selection (filled by
/// E04.F05.S02.T02 through `ImeHooks`).
pub const Preedit = struct {
    /// The composing text (owned by the hooks).
    text: []const u8 = "",
    /// The target clause as byte offsets into `text`; -1 hides the caret.
    cursor: [2]i32 = .{ 0, 0 },
    /// The buffer range the preedit stands in for.
    range_in_buffer: [2]u32 = .{ 0, 0 },
};

test {
    std.testing.refAllDecls(@This());
}
