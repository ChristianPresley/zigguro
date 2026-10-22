//! Whole-terminal invariants, checked by the conformance runner after every
//! step and by the `terminal_invariants` fuzz target after every input.

const std = @import("std");
const Terminal = @import("../term/Terminal.zig");
const Screen = @import("../screen/Screen.zig");
const PageList = @import("../screen/PageList.zig");

/// Fails with a descriptive error when any invariant of `t` is broken:
/// page tables, refcounts, wide/spacer pairs and row counts (`Page.verify`
/// and `PageList.verify`), cursor and margin bounds, pending wrap only at
/// the right edge, and live tracked pins.
pub fn checkInvariants(t: *const Terminal) !void {
    try checkScreen(&t.primary);
    try checkScreen(&t.alternate);
    if (t.primary.width() != t.alternate.width() or t.primary.height() != t.alternate.height()) return error.ScreenSizeMismatch;
}

fn checkScreen(s: *const Screen) !void {
    try s.checkInvariants();
    const c = s.cursor;
    if (c.pending_wrap) {
        const right = if (c.x <= s.region.right) s.region.right else s.width() - 1;
        if (c.x != right) return error.PendingWrapNotAtRightEdge;
    }
    try checkPins(&s.pages);
}

fn checkPins(pl: *const PageList) !void {
    for (pl.pins.items) |tp| {
        if (tp.garbage) continue;
        var n: ?*PageList.Node = pl.head;
        const live = while (n) |node| : (n = node.next) {
            if (node == tp.pin.node) break tp.pin.y < node.page.rowCount();
        } else false;
        if (!live) return error.DanglingPin;
    }
}

test "a fresh and a busy terminal hold every invariant" {
    const gpa = std.testing.allocator;
    var t = try Terminal.init(gpa, .{ .cols = 8, .rows = 3, .max_scrollback_bytes = 1 << 16 });
    defer t.deinit();
    try checkInvariants(&t);
    t.feed("\x1b[1;31mhello\u{65E5}\u{65E5}world\x1b[0m\r\n\x1b[?1049h\x1b[2;3rab\x1b[?1049l");
    for (0..200) |_| t.feed("line\r\n");
    try checkInvariants(&t);
}

// Fragments the invariant fuzzer strings together: CSI finals with random
// parameters, ESC sequences, strings, text and controls.
const csi_finals = "@ABCDEFGHIJKLMPSTXZ`abdefghlmnqrstu";
const esc_seqs = [_][]const u8{ "7", "8", "D", "E", "H", "M", "c", "#8", "(0", "(B", ")0", "=", ">" };
const texts = [_][]const u8{ "a", "hello", "日本", "e\u{301}", "\u{1F468}\u{200D}\u{1F469}", "\u{1F1FA}\u{1F1F8}", "\u{2764}\u{FE0F}", "\xff", "\r", "\n", "\t", "\x08", "\x0e", "\x0f" };
const privates = [_]u16{ 1, 6, 7, 25, 47, 69, 1047, 1048, 1049, 2004, 2026, 2027 };

fn token(s: *std.testing.Smith, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    switch (s.valueRangeAtMost(u8, 0, 6)) {
        0, 1 => {
            try out.appendSlice(gpa, "\x1b[");
            const n = s.valueRangeAtMost(u8, 0, 3);
            for (0..n) |i| {
                if (i > 0) try out.append(gpa, ';');
                try out.print(gpa, "{d}", .{s.valueRangeAtMost(u16, 0, 30)});
            }
            try out.append(gpa, csi_finals[s.valueRangeAtMost(u8, 0, csi_finals.len - 1)]);
        },
        2 => try out.print(gpa, "\x1b[?{d}{c}", .{ privates[s.valueRangeAtMost(u8, 0, privates.len - 1)], @as(u8, if (s.value(bool)) 'h' else 'l') }),
        3 => try out.print(gpa, "\x1b{s}", .{esc_seqs[s.valueRangeAtMost(u8, 0, esc_seqs.len - 1)]}),
        4 => try out.print(gpa, "\x1b]{s};x\x07", .{if (s.value(bool)) "2" else "8;;https://e.test"}),
        else => try out.appendSlice(gpa, texts[s.valueRangeAtMost(u8, 0, texts.len - 1)]),
    }
}

fn fuzzInvariants(_: void, s: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var t = try Terminal.init(gpa, .{ .cols = 20, .rows = 8, .max_scrollback_bytes = 1 << 16, .clipboard_max = 256 });
    defer t.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var steps: u16 = 0;
    while (!s.eos() and steps < 256) : (steps += 1) {
        buf.clearRetainingCapacity();
        if (s.valueRangeAtMost(u8, 0, 31) == 0) {
            try t.resize(s.valueRangeAtMost(u16, 1, 30), s.valueRangeAtMost(u16, 1, 12));
        } else try token(s, &buf, gpa);
        t.feed(buf.items);
        try checkInvariants(&t);
        t.clearReplies();
        t.effects.clear();
    }
}

test "fuzz: terminal_invariants" {
    try std.testing.fuzz({}, fuzzInvariants, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "terminal_invariants") });
}
