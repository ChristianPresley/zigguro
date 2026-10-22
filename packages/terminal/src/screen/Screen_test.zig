//! Screen and print-path tests (E06.F03.S01.T02, T03).

const std = @import("std");
const testing = std.testing;
const Screen = @import("Screen.zig");
const PageList = @import("PageList.zig");
const Page = @import("Page.zig");
const print = @import("print.zig");
const zg_core = @import("zg_core");

fn putStr(s: *Screen, text: []const u8) !void {
    var cps: [256]u21 = undefined;
    var n: usize = 0;
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |cp| : (n += 1) cps[n] = cp;
    s.print(cps[0..n]);
}

fn expectDump(s: *const Screen, want: []const u8) !void {
    const got = try s.dump(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
    try s.checkInvariants();
}

fn newScreen(cols: u16, rows: u16) !Screen {
    return Screen.init(testing.allocator, cols, rows, .{});
}

fn fill(s: *Screen) void {
    for (0..s.height()) |y| {
        s.cursor.x = 0;
        s.cursor.y = @intCast(y);
        s.cursor.pending_wrap = false;
        var line: [64]u8 = undefined;
        for (line[0..s.width()], 0..) |*c, x| c.* = @intCast('a' + (x + y) % 26);
        const saved = s.modes.autowrap;
        s.modes.autowrap = false;
        s.printAscii(line[0..s.width()]);
        s.modes.autowrap = saved;
    }
    s.cursor = .{};
}

test "printAscii wraps at the right margin and scrolls into scrollback" {
    var s = try newScreen(5, 2);
    defer s.deinit();
    s.printAscii("hello world!");
    try expectDump(&s, " worl\nd!\n");
    try testing.expectEqual(@as(u64, 1), s.pages.scrollbackRows());
    try testing.expect(s.pages.screenRow(0).?.row().wrap);
    try testing.expect(s.rowPin(0).row().wrap_continuation);
}

test "scrollUp full screen is O(1): no cell bytes moved" {
    var s = try newScreen(10, 3);
    defer s.deinit();
    fill(&s);
    const before = s.rowPin(1);
    const ptr = before.cells().ptr;
    try s.scrollUp(s.fullRegion(), 1, .{});
    // The old row 1 is now row 0, still at the same storage address.
    try testing.expectEqual(ptr, s.rowPin(0).cells().ptr);
    try expectDump(&s, "bcdefghijk\ncdefghijkl\n\n");
}

test "scroll region with margins rotates rows; outside rows untouched" {
    var s = try newScreen(6, 5);
    defer s.deinit();
    fill(&s);
    try s.scrollUp(.{ .top = 1, .bottom = 3, .left = 1, .right = 3 }, 1, .{});
    try expectDump(&s,
        \\abcdef
        \\bdeffg
        \\cefggh
        \\d   hi
        \\efghij
        \\
    );
    try s.scrollDown(.{ .top = 0, .bottom = 4, .left = 0, .right = 5 }, 2, .{});
    try expectDump(&s,
        \\
        \\
        \\abcdef
        \\bdeffg
        \\cefggh
        \\
    );
}

test "cross-page row copy re-interns styles/graphemes/links" {
    // A screen whose active area straddles a page boundary.
    var s = try newScreen(40, 10);
    defer s.deinit();
    const cap = Page.layoutFor(40, Page.bytesFor(40)).rows_cap;
    for (0..cap - 5) |_| _ = try s.pages.grow();
    try testing.expect(s.rowPin(0).node != s.rowPin(9).node);
    s.cursor.y = 8;
    s.setStyle(.{ .fg = .rgb(9, 9, 9), .flags = .{ .bold = true } });
    try s.setLink(.{ .uri = "https://example.com" });
    try putStr(&s, "linked e\u{301}");
    try s.setLink(null);
    // DL at row 0 pulls row 8 (other page) up through the boundary.
    s.region = .{ .top = 0, .bottom = 9, .left = 0, .right = 39 };
    try s.deleteLines(0, 3, s.region, .{});
    try s.checkInvariants();
    const p = s.rowPin(5);
    const c = p.cells()[0];
    try testing.expect(p.node.page.styleOf(c).flags.bold);
    try testing.expectEqualStrings("https://example.com", p.node.page.hyperlinkOf(&p.cells()[0]).?.uri);
    try testing.expectEqual(@as(u21, 0x301), p.node.page.grapheme(&p.cells()[7]).?[0]);
}

test "erase with BCE writes bg cells; selective erase keeps protected" {
    var s = try newScreen(6, 2);
    defer s.deinit();
    s.cursor.protected = true;
    s.printAscii("ab");
    s.cursor.protected = false;
    s.printAscii("cd");
    s.cursor.x = 0;
    s.eraseCells(0, 0, 6, .{ .selective = true });
    try expectDump(&s, "ab\n\n");
    s.eraseCells(1, 2, 4, .{ .bce = .{ .bg = .palette(4) } });
    const cs = s.rowPin(1).cells();
    try testing.expectEqual(@import("cell.zig").Tag.bg_palette, cs[2].tag);
    try testing.expectEqual(@as(u24, 4), cs[3].content);
    try testing.expectEqual(@import("cell.zig").Tag.codepoint, cs[4].tag);
    try s.eraseDisplay(.all, .{});
    try expectDump(&s, "\n\n");
}

test "insert/delete cells splitting wide chars" {
    var s = try newScreen(8, 1);
    defer s.deinit();
    try putStr(&s, "a日b本c");
    try expectDump(&s, "a日b本c\n");
    // Delete at the tail of 日: both halves go.
    s.deleteCells(0, 2, 1, 7, .{});
    try expectDump(&s, "a b本c\n");
    // Insert pushes c off the edge; 本 still fits.
    s.insertCells(0, 0, 3, 7, .{});
    try expectDump(&s, "   a b本\n");
    // One more column would cut 本 in half: both halves are blanked.
    s.insertCells(0, 0, 1, 7, .{});
    try expectDump(&s, "    a b\n");
}

test "IL/DL respect margins and never touch scrollback" {
    var s = try newScreen(4, 4);
    defer s.deinit();
    fill(&s);
    try s.insertLines(1, 1, s.fullRegion(), .{});
    try expectDump(&s, "abcd\n\nbcde\ncdef\n");
    try s.deleteLines(0, 2, s.fullRegion(), .{});
    try expectDump(&s, "bcde\ncdef\n\n\n");
    try testing.expectEqual(@as(u64, 0), s.pages.scrollbackRows());
}

test "screen without scrollback rotates on full-screen scroll" {
    var s = try Screen.init(testing.allocator, 4, 3, .{ .scrollback = false });
    defer s.deinit();
    s.printAscii("aaaabbbbccccdddd");
    try expectDump(&s, "bbbb\ncccc\ndddd\n");
    try testing.expectEqual(@as(u64, 3), s.pages.totalRows());
}

test "resize keeps the cursor row and drops blank rows first" {
    var s = try newScreen(10, 5);
    defer s.deinit();
    s.printAscii("one");
    s.cursor.x = 0;
    try s.index(.{});
    s.printAscii("two");
    try s.resize(6, 3);
    try expectDump(&s, "one\ntwo\n\n");
    try testing.expectEqual(@as(u16, 1), s.cursor.y);
    try s.resize(3, 2);
    try expectDump(&s, "one\ntwo\n");
}

test "combining mark attaches; at col 0 ignored" {
    var s = try newScreen(10, 2);
    defer s.deinit();
    try putStr(&s, "\u{301}e\u{301}x");
    try expectDump(&s, "e\u{301}x\n\n");
    try testing.expectEqual(@as(u16, 2), s.cursor.x);
}

fn widthOf(mode_grapheme: bool, text: []const u8) !u16 {
    var s = try newScreen(20, 1);
    defer s.deinit();
    s.modes.grapheme = mode_grapheme;
    try putStr(&s, text);
    try s.checkInvariants();
    return s.cursor.x;
}

test "legacy vs grapheme width" {
    const cases = [_]struct { text: []const u8, legacy: u16, grapheme: u16 }{
        .{ .text = "🧑‍🌾", .legacy = 4, .grapheme = 2 },
        .{ .text = "👍🏽", .legacy = 2, .grapheme = 2 },
        .{ .text = "🇯🇵", .legacy = 2, .grapheme = 2 },
        .{ .text = "❤️", .legacy = 1, .grapheme = 2 },
        .{ .text = "❤︎", .legacy = 1, .grapheme = 1 },
        .{ .text = "한", .legacy = 2, .grapheme = 2 },
        .{ .text = "ᄒ\u{1161}\u{11AB}", .legacy = 2, .grapheme = 2 },
        .{ .text = "क्षि", .legacy = 3, .grapheme = 1 }, // ि is a spacing mark (width 1 per code point)
    };
    for (cases) |c| {
        testing.expectEqual(c.legacy, try widthOf(false, c.text)) catch |e| {
            std.debug.print("legacy {s}\n", .{c.text});
            return e;
        };
        testing.expectEqual(c.grapheme, try widthOf(true, c.text)) catch |e| {
            std.debug.print("grapheme {s}\n", .{c.text});
            return e;
        };
    }
}

test "wide at last column with/without autowrap" {
    var s = try newScreen(5, 2);
    defer s.deinit();
    s.printAscii("abcd");
    try putStr(&s, "日");
    try expectDump(&s, "abcd\n日\n");
    try testing.expectEqual(@import("cell.zig").Wide.spacer_head, s.rowPin(0).cells()[4].wide);
    var t = try newScreen(5, 1);
    defer t.deinit();
    t.modes.autowrap = false;
    t.printAscii("abcd");
    try putStr(&t, "日");
    try expectDump(&t, "abc日\n");
}

test "overwrite halves of wide chars" {
    var s = try newScreen(6, 1);
    defer s.deinit();
    try putStr(&s, "日本");
    s.cursor.x = 1;
    s.printAscii("x");
    try expectDump(&s, " x本\n");
    s.cursor.x = 2;
    s.printAscii("y");
    try expectDump(&s, " xy\n");
}

test "IRM shifts within margins and drops cells at right margin" {
    var s = try newScreen(6, 1);
    defer s.deinit();
    s.printAscii("abcdef");
    s.region.right = 3;
    s.cursor.x = 1;
    s.cursor.pending_wrap = false;
    s.modes.insert = true;
    s.printAscii("X");
    try expectDump(&s, "aXbcef\n");
}

test "DEC special graphics lqqk → ┌──┐; SS2 single shift" {
    var s = try newScreen(8, 1);
    defer s.deinit();
    s.charsets.g[0] = .dec_special;
    s.printAscii("lqqk");
    s.charsets.g[0] = .ascii;
    s.charsets.g[2] = .dec_special;
    s.charsets.single = 2;
    s.printAscii("xx");
    try expectDump(&s, "┌──┐│x\n");
}

test "REP after grapheme repeats cluster" {
    var s = try newScreen(10, 1);
    defer s.deinit();
    try putStr(&s, "e\u{301}");
    print.repeat(&s, 2);
    try expectDump(&s, "e\u{301}e\u{301}e\u{301}\n");
}

test "ascii fast path equals general path" {
    var prng: std.Random.DefaultPrng = .init(99);
    const r = prng.random();
    for (0..300) |_| {
        var a = try newScreen(12, 4);
        defer a.deinit();
        var b = try newScreen(12, 4);
        defer b.deinit();
        const left = r.uintLessThan(u16, 6);
        const right = left + 1 + r.uintLessThan(u16, 12 - left - 1);
        const autowrap = r.boolean();
        for ([_]*Screen{ &a, &b }) |s| {
            s.region.left = left;
            s.region.right = right;
            s.region.top = r.uintLessThan(u16, 2);
            s.modes.autowrap = autowrap;
            s.cursor.x = r.uintLessThan(u16, 12);
            s.cursor.y = r.uintLessThan(u16, 4);
        }
        b.region = a.region;
        b.cursor = a.cursor;
        var text: [40]u8 = undefined;
        const n = r.uintAtMost(usize, text.len);
        for (text[0..n]) |*c| c.* = r.intRangeAtMost(u8, 0x20, 0x7E);
        a.printAscii(text[0..n]);
        var cps: [40]u21 = undefined;
        for (text[0..n], cps[0..n]) |c, *cp| cp.* = c;
        b.print(cps[0..n]);
        const da = try a.dump(testing.allocator);
        defer testing.allocator.free(da);
        const db = try b.dump(testing.allocator);
        defer testing.allocator.free(db);
        try testing.expectEqualStrings(db, da);
        try testing.expectEqual(b.cursor.x, a.cursor.x);
        try testing.expectEqual(b.cursor.y, a.cursor.y);
        try testing.expectEqual(b.cursor.pending_wrap, a.cursor.pending_wrap);
        try a.checkInvariants();
    }
}

fn fuzzScreenOps(_: void, sm: *std.testing.Smith) anyerror!void {
    var s = try Screen.init(testing.allocator, 16, 6, .{ .max_bytes = 4 * Page.default_bytes });
    defer s.deinit();
    var n: usize = 0;
    while (!sm.eos() and n < 300) : (n += 1) {
        const w = s.width();
        const h = s.height();
        const y = sm.valueRangeAtMost(u16, 0, h - 1);
        const x = sm.valueRangeAtMost(u16, 0, w - 1);
        const k = sm.valueRangeAtMost(u16, 1, 4);
        switch (sm.valueRangeAtMost(u8, 0, 15)) {
            0 => s.printAscii("hello, world"),
            1 => try putStr(&s, "日本e\u{301}🧑‍🌾🇯🇵❤️"),
            2 => {
                s.cursor.x = x;
                s.cursor.y = y;
                s.cursor.pending_wrap = false;
            },
            3 => try s.scrollUp(s.region, k, .{ .bce = .{ .bg = .palette(1) } }),
            4 => try s.scrollDown(s.region, k, .{}),
            5 => s.eraseCells(y, @min(x, w - 1), w, .{}),
            6 => s.insertCells(s.cursor.y, s.cursor.x, k, s.region.right, .{}),
            7 => s.deleteCells(s.cursor.y, s.cursor.x, k, s.region.right, .{}),
            8 => try s.insertLines(s.cursor.y, k, s.region, .{}),
            9 => try s.deleteLines(s.cursor.y, k, s.region, .{}),
            10 => {
                const t = sm.valueRangeAtMost(u16, 0, h - 1);
                const b = sm.valueRangeAtMost(u16, t, h - 1);
                const l = sm.valueRangeAtMost(u16, 0, w - 1);
                const rr = sm.valueRangeAtMost(u16, l, w - 1);
                s.region = .{ .top = t, .bottom = b, .left = l, .right = rr };
            },
            11 => s.setStyle(.{ .fg = .palette(sm.value(u8)), .flags = .{ .bold = sm.value(bool) } }),
            12 => try s.setLink(if (sm.value(bool)) .{ .uri = "https://z" } else null),
            13 => s.modes.grapheme = !s.modes.grapheme,
            14 => try s.resize(sm.valueRangeAtMost(u16, 2, 30), sm.valueRangeAtMost(u16, 2, 10)),
            else => {
                s.modes.insert = sm.value(bool);
                s.modes.autowrap = sm.value(bool);
            },
        }
        try s.checkInvariants();
    }
}

test "fuzz: screen_ops" {
    try std.testing.fuzz({}, fuzzScreenOps, .{ .corpus = zg_core.testkit.fuzz.corpus(@import("zg_corpus"), "screen_ops") });
}
