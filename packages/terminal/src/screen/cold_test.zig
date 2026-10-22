//! Cold page tests: cell-exact round trips at the same width, decoding at
//! other widths against reflow, plain text, row counts without decoding,
//! compression, corrupt input, and the cold_roundtrip fuzz target.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Terminal = @import("../term/Terminal.zig");
const PageList = @import("PageList.zig");
const Pin = PageList.Pin;
const cold = @import("cold.zig");

/// Encodes every row of the primary screen.
fn encodeAll(t: *const Terminal, o: cold.EncodeOptions) !cold.ColdPage {
    const pl = &t.primary.pages;
    return cold.encode(testing.allocator, pl.screenRow(0).?, pl.totalRows(), o);
}

/// Decodes `cp` into a fresh list at `cols`; the list's first row is the
/// blank row `init` creates, the decoded rows follow it.
fn decodeAt(cp: *const cold.ColdPage, cols: u16) !PageList {
    var pl: PageList = try .init(testing.allocator, cols, 1, .{});
    errdefer pl.deinit();
    try cp.decode(testing.allocator, &pl);
    return pl;
}

fn expectSameCell(ap: Pin, ac: *const @import("cell.zig").Cell, bp: Pin, bc: *const @import("cell.zig").Cell) !void {
    try testing.expectEqual(ac.codepoint(), bc.codepoint());
    try testing.expectEqual(ac.wide, bc.wide);
    try testing.expectEqual(ac.tag, bc.tag);
    try testing.expectEqual(ac.protected, bc.protected);
    try testing.expectEqual(ac.semantic, bc.semantic);
    if (ac.tag == .bg_palette or ac.tag == .bg_rgb) try testing.expectEqual(ac.content, bc.content);
    try testing.expect(ap.node.page.styleOf(ac.*).eql(bp.node.page.styleOf(bc.*).*));
    const ag = ap.node.page.grapheme(ac) orelse &.{};
    const bg = bp.node.page.grapheme(bc) orelse &.{};
    try testing.expectEqualSlices(u21, ag, bg);
    const al = ap.node.page.hyperlinkOf(ac);
    const bl = bp.node.page.hyperlinkOf(bc);
    try testing.expectEqual(al == null, bl == null);
    if (al) |l| {
        try testing.expectEqualStrings(l.uri, bl.?.uri);
        try testing.expectEqualStrings(l.id, bl.?.id);
    }
}

/// Every row of `a` (from row 0) equals the rows of `b` from row 1.
fn expectSameRows(a: *const PageList, b: *const PageList) !void {
    try testing.expectEqual(a.totalRows() + 1, b.totalRows());
    var pa: ?Pin = a.screenRow(0);
    var pb: ?Pin = b.screenRow(1);
    while (pa) |ra| : ({
        pa = PageList.next(ra);
        pb = PageList.next(pb.?);
    }) {
        const rb = pb.?;
        const x = ra.row().*;
        const y = rb.row().*;
        try testing.expectEqual(x.wrap, y.wrap);
        try testing.expectEqual(x.wrap_continuation, y.wrap_continuation);
        try testing.expectEqual(x.mark, y.mark);
        try testing.expectEqual(x.synthetic, y.synthetic);
        for (ra.cells(), rb.cells()) |*ca, *cb| try expectSameCell(ra, ca, rb, cb);
    }
}

/// Logical lines of `pl` from row `from`, soft wraps joined, spacers
/// skipped, empty cells as spaces, trailing spaces of each line dropped.
fn logicalText(gpa: Allocator, pl: *const PageList, from: u64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var p: ?Pin = pl.screenRow(from);
    var buf: [4]u8 = undefined;
    while (p) |row| : (p = PageList.next(row)) {
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
        if (!row.row().wrap) {
            while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
            try out.append(gpa, '\n');
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') out.items.len -= 1;
    return out.toOwnedSlice(gpa);
}

/// `text` output with each line's trailing spaces dropped.
fn coldText(cp: *const cold.ColdPage) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(testing.allocator);
    try cp.text(testing.allocator, &raw);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    var it = std.mem.splitScalar(u8, raw.items, '\n');
    var first = true;
    while (it.next()) |l| {
        if (!first) try out.append(testing.allocator, '\n');
        first = false;
        try out.appendSlice(testing.allocator, std.mem.trimEnd(u8, l, " "));
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') out.items.len -= 1;
    return out.toOwnedSlice(testing.allocator);
}

const sample =
    "plain line\r\n" ++
    "\x1b[1;31mbold red\x1b[0m and \x1b[4:3;58;2;1;2;3mcurly\x1b[0m\r\n" ++
    "wide 日本語 and e\u{301} and 🙂 and 👍🏽\r\n" ++
    "\x1b]8;id=a;https://x.example/\x07link\x1b]8;;\x07 after\r\n" ++
    "\x1b[44m\x1b[K\x1b[0mbackground row\r\n" ++
    "\x1b]133;A\x07$ prompt\r\n" ++
    "a very long line that wraps several times at twenty columns, with 漢字 near the edges";

test "a round trip at the same width is cell-identical" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 20, .rows = 12 });
    defer t.deinit();
    t.feed(sample);
    for ([_]bool{ false, true }) |deflate| {
        var cp = try encodeAll(&t, .{ .deflate = deflate });
        defer cp.deinit(testing.allocator);
        var pl = try decodeAt(&cp, 20);
        defer pl.deinit();
        try expectSameRows(&t.primary.pages, &pl);
        try pl.verify();
    }
}

test "decoding at another width matches reflow" {
    for ([_]u16{ 7, 13, 33, 80 }) |cols| {
        var t = try Terminal.init(testing.allocator, .{ .cols = 20, .rows = 12 });
        defer t.deinit();
        t.feed(sample);
        var cp = try encodeAll(&t, .{});
        defer cp.deinit(testing.allocator);
        var pl = try decodeAt(&cp, cols);
        defer pl.deinit();
        try pl.verify();
        try testing.expectEqual(pl.totalRows() - 1, try cp.rowsAt(testing.allocator, cols));
        // Reflow the terminal to the same width: same logical text.
        try t.resize(cols, 12);
        const want = try logicalText(testing.allocator, &t.primary.pages, 0);
        defer testing.allocator.free(want);
        const got = try logicalText(testing.allocator, &pl, 1);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);
    }
}

test "text matches the rows without decoding them" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 20, .rows = 12 });
    defer t.deinit();
    t.feed(sample);
    var cp = try encodeAll(&t, .{});
    defer cp.deinit(testing.allocator);
    const want = try logicalText(testing.allocator, &t.primary.pages, 0);
    defer testing.allocator.free(want);
    const got = try coldText(&cp);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "rowsAt counts wide characters at the edge and caches per width" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 10, .rows = 3 });
    defer t.deinit();
    t.feed("abc日日日日\r\nabcdefghij");
    var cp = try encodeAll(&t, .{ .deflate = false });
    defer cp.deinit(testing.allocator);
    // At 4 columns "abc日日日日" takes abc|日日|日日 = 3 rows (spacer head on
    // the first) and "abcdefghij" 3 rows; at 10 the first line still wraps.
    try testing.expectEqual(@as(u32, 6), try cp.rowsAt(testing.allocator, 4));
    try testing.expectEqual(@as(u16, 4), cp.cached_cols);
    try testing.expectEqual(@as(u32, 6), try cp.rowsAt(testing.allocator, 4));
    try testing.expectEqual(@as(u32, 3), try cp.rowsAt(testing.allocator, 10));
}

test "repetitive output deflates well, the encoding stays small" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit();
    for (0..400) |i| {
        var buf: [96]u8 = undefined;
        t.feed(std.fmt.bufPrint(&buf, "\x1b[32mINFO\x1b[0m request {d} served in {d}ms\r\n", .{ i, i % 17 }) catch unreachable);
    }
    var raw = try encodeAll(&t, .{ .deflate = false });
    defer raw.deinit(testing.allocator);
    var z = try encodeAll(&t, .{});
    defer z.deinit(testing.allocator);
    try testing.expect(z.compressed);
    try testing.expect(z.blob.len * 3 < raw.blob.len);
    // Raw: well under the 8 bytes a hot cell costs, per printed cell.
    try testing.expect(raw.blob.len < 400 * 40 * 2);
    const want = try coldText(&raw);
    defer testing.allocator.free(want);
    const got = try coldText(&z);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "corrupt input is an error, not a crash" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 20, .rows = 4 });
    defer t.deinit();
    t.feed(sample);
    var cp = try encodeAll(&t, .{ .deflate = false });
    defer cp.deinit(testing.allocator);
    const good = cp.blob;
    defer cp.blob = good;
    // Every truncation either decodes or fails cleanly.
    var n: usize = 0;
    while (n < good.len) : (n += 7) {
        cp.blob = good[0..n];
        var pl: PageList = try .init(testing.allocator, 20, 1, .{});
        defer pl.deinit();
        if (cp.decode(testing.allocator, &pl)) |_| {} else |err| try testing.expectEqual(error.CorruptColdPage, err);
    }
}

/// Random content: a same-width round trip is cell-identical, other widths
/// keep the logical text and the predicted row count.
fn fuzzRoundtrip(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = testing.allocator;
    const cols = smith.valueRangeAtMost(u16, 2, 30);
    var t = try Terminal.init(gpa, .{ .cols = cols, .rows = smith.valueRangeAtMost(u16, 2, 8) });
    defer t.deinit();
    const pieces = [_][]const u8{ "a", "bc", "日", "e\u{301}", "\r\n", "\x1b[1m", "\x1b[0m", "\x1b[44m", "\x1b[K", "\x1b]8;;https://h.example/\x07", "\x1b]8;;\x07", "     ", "xyz", "🙂", "\t", "\x1b]133;A\x07", "\x1b[1\"q", "\x1b[0\"q" };
    var n: usize = 0;
    while (!smith.eos() and n < 200) : (n += 1) t.feed(pieces[smith.valueRangeAtMost(u8, 0, pieces.len - 1)]);
    var cp = try encodeAll(&t, .{ .deflate = smith.valueRangeAtMost(u8, 0, 1) == 1 });
    defer cp.deinit(gpa);
    {
        var pl = try decodeAt(&cp, cols);
        defer pl.deinit();
        try expectSameRows(&t.primary.pages, &pl);
        try pl.verify();
    }
    const other = smith.valueRangeAtMost(u16, 1, 40);
    var pl = try decodeAt(&cp, other);
    defer pl.deinit();
    try pl.verify();
    try testing.expectEqual(pl.totalRows() - 1, try cp.rowsAt(gpa, other));
    const want = try coldText(&cp);
    defer gpa.free(want);
    const got = try logicalText(gpa, &pl, 1);
    defer gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

test "fuzz: cold_roundtrip" {
    try std.testing.fuzz({}, fuzzRoundtrip, .{});
}

test "a linked wide character round-trips without linking its spacer" {
    // Found by the cold_roundtrip fuzz target.
    var t = try Terminal.init(testing.allocator, .{ .cols = 6, .rows = 2 });
    defer t.deinit();
    t.feed("\x1b]8;;https://h.example/\x07\x1b[44m🙂     ");
    var cp = try encodeAll(&t, .{ .deflate = false });
    defer cp.deinit(testing.allocator);
    var pl = try decodeAt(&cp, 6);
    defer pl.deinit();
    try expectSameRows(&t.primary.pages, &pl);
}
