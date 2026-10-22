//! Reflow tests: re-wrapping long lines, wide characters at the new edge,
//! cursor and saved-cursor preservation, styles and links, the alternate
//! screen, bottom anchoring, and the reflow_roundtrip fuzz target.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Terminal = @import("../term/Terminal.zig");
const Screen = @import("Screen.zig");
const PageList = @import("PageList.zig");
const Cell = @import("cell.zig").Cell;

/// Every logical line of `s` (scrollback included), soft wraps joined,
/// trailing blank lines dropped.
fn logicalText(gpa: Allocator, s: *const Screen) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var p: ?PageList.Pin = s.pages.screenRow(0);
    while (p) |row| : (p = PageList.next(row)) {
        const r = row.row();
        if (r.wrap) {
            // A wrapped row carries all its cells; skip spacers.
            var buf: [4]u8 = undefined;
            for (row.cells()) |*c| {
                if (c.wide == .spacer_tail or c.wide == .spacer_head) continue;
                const cp = c.codepoint();
                const n = std.unicode.utf8Encode(if (cp == 0) ' ' else cp, &buf) catch unreachable;
                try out.appendSlice(gpa, buf[0..n]);
                if (row.node.page.grapheme(c)) |extra| for (extra) |e| {
                    const m = std.unicode.utf8Encode(e, &buf) catch unreachable;
                    try out.appendSlice(gpa, buf[0..m]);
                };
            }
        } else {
            try Screen.pinText(row, &out, gpa);
            try out.append(gpa, '\n');
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') out.items.len -= 1;
    return out.toOwnedSlice(gpa);
}

fn rowStr(t: *Terminal, y: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try t.screen().rowText(y, &out, testing.allocator);
    return out.toOwnedSlice(testing.allocator);
}

fn expectRow(t: *Terminal, y: u16, want: []const u8) !void {
    const got = try rowStr(t, y);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "a 500-character line re-wraps at 120, 50 and 80 columns" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit();
    var line: [500]u8 = undefined;
    for (&line, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
    t.feed(&line);
    const before = try logicalText(testing.allocator, &t.primary);
    defer testing.allocator.free(before);
    for ([_]u16{ 120, 50, 80 }) |cols| {
        try t.resize(cols, 24);
        const now = try logicalText(testing.allocator, &t.primary);
        defer testing.allocator.free(now);
        try testing.expectEqualStrings(before, now);
        // The cursor stays just after the last character.
        const s = t.screen();
        const rows_used = (500 + cols - 1) / cols;
        try testing.expectEqual(@as(u16, @intCast(rows_used - 1)), s.cursor.y);
        try testing.expectEqual(@as(u16, @intCast(if (500 % cols == 0) cols - 1 else 500 % cols)), s.cursor.x);
        try testing.expectEqual(500 % cols == 0, s.cursor.pending_wrap);
    }
    try expectRow(&t, 0, line[0..80]);
    try expectRow(&t, 6, line[480..500]);
}

test "narrowing wraps a long row, widening joins it again" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 10, .rows = 4 });
    defer t.deinit();
    t.feed("abcdefgh\r\nxy");
    try t.resize(5, 4);
    try expectRow(&t, 0, "abcde");
    try expectRow(&t, 1, "fgh");
    try expectRow(&t, 2, "xy");
    try testing.expect(t.screen().rowPin(0).row().wrap);
    try testing.expectEqual(@as(u16, 2), t.screen().cursor.y);
    try testing.expectEqual(@as(u16, 2), t.screen().cursor.x);
    try t.resize(10, 4);
    try expectRow(&t, 0, "abcdefgh");
    try expectRow(&t, 1, "xy");
    try testing.expect(!t.screen().rowPin(0).row().wrap);
}

test "a wide character at the new edge leaves a spacer head" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 10, .rows = 3 });
    defer t.deinit();
    t.feed("abcd日x");
    try t.resize(5, 3);
    const s = t.screen();
    const r0 = s.rowPin(0).cells();
    try testing.expectEqual(.spacer_head, r0[4].wide);
    const r1 = s.rowPin(1).cells();
    try testing.expectEqual(@as(u21, '日'), r1[0].codepoint());
    try testing.expectEqual(.wide, r1[0].wide);
    try testing.expectEqual(.spacer_tail, r1[1].wide);
    try testing.expectEqual(@as(u21, 'x'), r1[2].codepoint());
    // Widening drops the spacer head again.
    try t.resize(10, 3);
    try expectRow(&t, 0, "abcd日x");
    try testing.expectEqual(.wide, s.rowPin(0).cells()[4].wide);
}

test "styles and links survive reflow" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 6, .rows = 3 });
    defer t.deinit();
    t.feed("ab\x1b[1;31mcd\x1b]8;;https://x.example/\x07ef\x1b]8;;\x07\x1b[0mgh");
    try t.resize(4, 3);
    const s = t.screen();
    const r0 = s.rowPin(0);
    const c2 = r0.cells()[2];
    try testing.expect(r0.node.page.styleOf(c2).flags.bold);
    const r1 = s.rowPin(1);
    try testing.expectEqualStrings("https://x.example/", r1.node.page.hyperlinkOf(&r1.cells()[0]).?.uri);
    try testing.expectEqual(@as(u21, 'g'), r1.cells()[2].codepoint());
    try testing.expect(r1.node.page.hyperlinkOf(&r1.cells()[2]) == null);
    try s.pages.verify();
}

test "the alternate screen is truncated, the primary beneath reflowed" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 10, .rows = 3 });
    defer t.deinit();
    t.feed("0123456789x\x1b[?1049h\x1b[HALTERNATE!");
    try t.resize(5, 3);
    try expectRow(&t, 0, "ALTER");
    try expectRow(&t, 1, "");
    t.feed("\x1b[?1049l");
    try expectRow(&t, 0, "01234");
    try expectRow(&t, 1, "56789");
    try expectRow(&t, 2, "x");
}

test "blank rows below the cursor keep the cursor's distance from the bottom" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 10, .rows = 4 });
    defer t.deinit();
    t.feed("1\r\n2\r\n3\r\n4\r\n5\r\n0123456789abc\x1b[3;1H\x1b[J");
    // Cursor on row 3 of 4; row 4 is blank.
    try t.resize(5, 4);
    try testing.expectEqual(@as(u16, 2), t.screen().cursor.y);
    try expectRow(&t, 3, "");
}

test "the saved cursor keeps its logical position" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 10, .rows = 4 });
    defer t.deinit();
    t.feed("0123456789ab\x1b7\r\n");
    // Saved after "ab" on the continuation row: offset 12, which at six
    // columns is just past the end of the second row.
    try t.resize(6, 4);
    const sv = t.screen().saved.?;
    try testing.expectEqual(@as(u16, 1), sv.y);
    try testing.expectEqual(@as(u16, 5), sv.x);
}

test "shrinking pushes reflowed rows into scrollback" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 10, .rows = 2 });
    defer t.deinit();
    t.feed("0123456789\r\nabcdefghij");
    try t.resize(5, 2);
    try expectRow(&t, 0, "abcde");
    try expectRow(&t, 1, "fghij");
    try testing.expectEqual(@as(u64, 2), t.primary.pages.scrollbackRows());
    try t.screen().pages.verify();
}

/// Random content, random widths, back to the original width: the logical
/// text is unchanged and every invariant holds.
fn fuzzRoundtrip(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = testing.allocator;
    const cols0 = smith.valueRangeAtMost(u16, 4, 30);
    var t = try Terminal.init(gpa, .{ .cols = cols0, .rows = smith.valueRangeAtMost(u16, 2, 8) });
    defer t.deinit();
    const pieces = [_][]const u8{ "a", "bc", "日", "e\u{301}", "\r\n", "\x1b[1m", "\x1b[0m", "\x1b[44m", "\x1b]8;;https://h.example/\x07", "\x1b]8;;\x07", "     ", "xyz", "🙂", "\t" };
    var n: usize = 0;
    while (!smith.eos() and n < 200) : (n += 1) t.feed(pieces[smith.valueRangeAtMost(u8, 0, pieces.len - 1)]);
    const before = try logicalText(gpa, &t.primary);
    defer gpa.free(before);
    const rows = t.primary.height();
    for (0..smith.valueRangeAtMost(u8, 1, 4)) |_| {
        try t.resize(smith.valueRangeAtMost(u16, 2, 40), rows);
        try t.primary.checkInvariants();
    }
    try t.resize(cols0, rows);
    try t.primary.checkInvariants();
    const after = try logicalText(gpa, &t.primary);
    defer gpa.free(after);
    // Tabs and trailing blanks are not text; compare without them.
    try testing.expectEqualStrings(std.mem.trimEnd(u8, before, " "), std.mem.trimEnd(u8, after, " "));
}

test "fuzz: reflow_roundtrip" {
    try std.testing.fuzz({}, fuzzRoundtrip, .{});
}
