//! Exact-width text dumps of the screen for the conformance harness: one
//! line per row, every cell rendered, so wide characters, blanks and
//! spacers are visible in diffs.

const std = @import("std");
const Terminal = @import("../term/Terminal.zig");
const Screen = @import("../screen/Screen.zig");
const PageList = @import("../screen/PageList.zig");
const Pin = PageList.Pin;

/// How cells are rendered.
pub const DumpOptions = struct {
    /// An empty cell (also a wide-wrap spacer head).
    blank: []const u8 = "·",
    /// The right half of a wide character.
    spacer: []const u8 = "‹",
};

/// The active screen of `t`.
pub fn activeScreen(t: *const Terminal) *const Screen {
    return if (t.alt_active) &t.alternate else &t.primary;
}

/// Writes one row: a grapheme cluster per cell (base and combining marks),
/// `o.blank` for empty cells and `o.spacer` for wide-character tails.
pub fn dumpRow(p: Pin, w: *std.Io.Writer, o: DumpOptions) !void {
    var buf: [4]u8 = undefined;
    for (p.cells()) |*c| {
        switch (c.wide) {
            .spacer_tail => {
                try w.writeAll(o.spacer);
                continue;
            },
            .spacer_head => {
                try w.writeAll(o.blank);
                continue;
            },
            .narrow, .wide => {},
        }
        const cp = c.codepoint();
        if (cp == 0) {
            try w.writeAll(o.blank);
            continue;
        }
        try w.writeAll(buf[0 .. std.unicode.utf8Encode(cp, &buf) catch 0]);
        if (p.node.page.grapheme(c)) |extra| for (extra) |e| {
            try w.writeAll(buf[0 .. std.unicode.utf8Encode(e, &buf) catch 0]);
        };
    }
}

/// Writes every active row of `t`, each followed by a newline.
pub fn dumpScreen(t: *const Terminal, w: *std.Io.Writer, o: DumpOptions) !void {
    const s = activeScreen(t);
    for (0..s.height()) |y| {
        try dumpRow(s.rowPin(@intCast(y)), w, o);
        try w.writeByte('\n');
    }
}

/// Writes every scrollback row of `t`'s active screen, oldest first, each
/// followed by a newline.
pub fn dumpScrollback(t: *const Terminal, w: *std.Io.Writer, o: DumpOptions) !void {
    const pl = &activeScreen(t).pages;
    var left = pl.scrollbackRows();
    var p = pl.screenRow(0);
    while (left > 0) : (left -= 1) {
        const pin = p orelse break;
        try dumpRow(pin, w, o);
        try w.writeByte('\n');
        p = PageList.next(pin);
    }
}

test "dump shows blanks, wide spacers and combining marks" {
    const gpa = std.testing.allocator;
    var t = try Terminal.init(gpa, .{ .cols = 6, .rows = 2 });
    defer t.deinit();
    t.feed("a\u{65E5}e\u{301}\r\n\x1b[3Cz");
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try dumpScreen(&t, &out.writer, .{});
    try std.testing.expectEqualStrings("a日‹e\u{301}··\n···z··\n", out.written());
}
