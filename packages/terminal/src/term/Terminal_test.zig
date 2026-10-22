//! Terminal tests: control functions against screen dumps, modes, replies,
//! OSC/DCS handling and effects.

const std = @import("std");
const testing = std.testing;
const Terminal = @import("Terminal.zig");
const mark = @import("../shell/mark.zig");
const Style = @import("../screen/style.zig").Style;

const gpa = testing.allocator;

/// A 10x5 terminal, as the spec's unit tests use.
pub fn small() !Terminal {
    return Terminal.init(gpa, .{ .cols = 10, .rows = 5 });
}

/// The active screen as text with trailing empty lines removed.
pub fn text(t: *Terminal) ![]u8 {
    const d = try t.dump(gpa);
    var end = d.len;
    while (end > 0 and d[end - 1] == '\n') end -= 1;
    const out = try gpa.dupe(u8, d[0..end]);
    gpa.free(d);
    return out;
}

/// Expects the screen text.
pub fn expectText(t: *Terminal, want: []const u8) !void {
    const got = try text(t);
    defer gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

/// Expects the cursor at 0-based (x, y).
pub fn expectCursor(t: *Terminal, x: u16, y: u16) !void {
    const c = t.screen().cursor;
    if (c.x != x or c.y != y) {
        std.debug.print("cursor at {d},{d}; want {d},{d}\n", .{ c.x, c.y, x, y });
        return error.TestUnexpectedResult;
    }
}

/// Feeds `in` and expects exactly `want` as replies.
pub fn expectReply(t: *Terminal, in: []const u8, want: []const u8) !void {
    t.clearReplies();
    t.feed(in);
    try testing.expectEqualStrings(want, t.replies.items);
    t.clearReplies();
}

test "print, CR LF, wrap" {
    var t = try small();
    defer t.deinit();
    t.feed("hello\r\nworld");
    try expectText(&t, "hello\nworld");
    try expectCursor(&t, 5, 1);
    t.feed("\r\n0123456789AB");
    try expectText(&t, "hello\nworld\n0123456789\nAB");
    try t.screen().checkInvariants();
}

test "C0: BS, HT, LF with LNM, SO/SI, BEL rate limit" {
    var t = try small();
    defer t.deinit();
    t.feed("ab\x08X");
    try expectText(&t, "aX");
    t.feed("\r\tY");
    try expectCursor(&t, 9, 0);
    t.feed("\x1b[20h\nZ");
    try expectCursor(&t, 1, 1);
    t.feed("\x1b[20l\x1b)0\x0eq\x0fq");
    try expectText(&t, "aX      Y\nZ─q");
    t.now_ms = 1000;
    t.feed("\x07\x07");
    t.now_ms = 1200;
    t.feed("\x07");
    var bells: usize = 0;
    for (t.effects.pending()) |e| if (e == .bell) {
        bells += 1;
    };
    try testing.expectEqual(@as(usize, 2), bells);
    try testing.expectEqual(@as(u32, 1), t.stats.bells_suppressed);
}

test "BS at last column with pending wrap; reverse wrap" {
    var t = try small();
    defer t.deinit();
    t.feed("0123456789\x08X");
    try expectText(&t, "01234567X9");
    t.feed("\x1b[2J\x1b[H0123456789ab\x1b[?45h\r\x08\x08Z");
    try expectText(&t, "01234567Z9\nab");
    try expectCursor(&t, 9, 0);
}

test "cursor movement: CUU/CUD/CUF/CUB, CNL/CPL, CHA, CUP, VPA, VPR, HPA, HPR" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b[3;4H");
    try expectCursor(&t, 3, 2);
    t.feed("\x1b[A");
    try expectCursor(&t, 3, 1);
    t.feed("\x1b[0B");
    try expectCursor(&t, 3, 2);
    t.feed("\x1b[99C");
    try expectCursor(&t, 9, 2);
    t.feed("\x1b[99D");
    try expectCursor(&t, 0, 2);
    t.feed("\x1b[5G\x1b[E");
    try expectCursor(&t, 0, 3);
    t.feed("\x1b[5G\x1b[2F");
    try expectCursor(&t, 0, 1);
    t.feed("\x1b[4d");
    try expectCursor(&t, 0, 3);
    t.feed("\x1b[9e");
    try expectCursor(&t, 0, 4);
    t.feed("\x1b[7`");
    try expectCursor(&t, 6, 4);
    t.feed("\x1b[2a");
    try expectCursor(&t, 8, 4);
    t.feed("\x1b[f");
    try expectCursor(&t, 0, 0);
    t.feed("\x1b[99;99f");
    try expectCursor(&t, 9, 4);
}

test "cursor moves stop at margins only from inside" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b[2;4r"); // rows 2-4, homes
    try expectCursor(&t, 0, 0);
    t.feed("\x1b[9B");
    try expectCursor(&t, 0, 3);
    t.feed("\x1b[9A");
    try expectCursor(&t, 0, 1);
    t.feed("\x1b[5;1H\x1b[9A");
    try expectCursor(&t, 0, 1);
    t.feed("\x1b[1;1H\x1b[9B");
    try expectCursor(&t, 0, 3);
}

test "origin mode addressing and CPR" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b[2;4r\x1b[?6h");
    try expectCursor(&t, 0, 1);
    t.feed("\x1b[9;9H");
    try expectCursor(&t, 8, 3);
    try expectReply(&t, "\x1b[6n", "\x1b[3;9R");
    try expectReply(&t, "\x1b[?6n", "\x1b[?3;9;1R");
    t.feed("\x1b[?69h\x1b[3;6s");
    try expectCursor(&t, 2, 1);
    t.feed("\x1b[1;99H");
    try expectCursor(&t, 5, 1);
    try expectReply(&t, "\x1b[6n", "\x1b[1;4R");
    t.feed("\x1b[?6l");
    try expectCursor(&t, 0, 0);
}

test "ED, EL, ECH with BCE" {
    var t = try small();
    defer t.deinit();
    t.feed("aaaaaaaaaa\r\nbbbbbbbbbb\r\ncccccccccc\x1b[2;5H");
    t.feed("\x1b[K");
    try expectText(&t, "aaaaaaaaaa\nbbbb\ncccccccccc");
    t.feed("\x1b[1K");
    try expectText(&t, "aaaaaaaaaa\n\ncccccccccc");
    t.feed("\x1b[3;3H\x1b[3X");
    try expectText(&t, "aaaaaaaaaa\n\ncc   ccccc");
    try expectCursor(&t, 2, 2);
    t.feed("\x1b[J");
    try expectText(&t, "aaaaaaaaaa\n\ncc");
    t.feed("\x1b[1;5H\x1b[1J");
    try expectText(&t, "     aaaaa\n\ncc");
    t.feed("\x1b[44m\x1b[2K\x1b[m");
    const p = t.screen().rowPin(0);
    try testing.expectEqual(@import("../screen/cell.zig").Tag.bg_palette, p.cells()[3].tag);
}

test "ED 2 pushes to scrollback; ED 3 clears it; alt screen does not push" {
    var t = try small();
    defer t.deinit();
    t.feed("one\r\ntwo\x1b[2J");
    try expectText(&t, "");
    try testing.expectEqual(@as(u64, 2), t.primary.pages.scrollbackRows());
    try expectCursor(&t, 3, 1);
    t.feed("\x1b[3J");
    try testing.expectEqual(@as(u64, 0), t.primary.pages.scrollbackRows());
    t.feed("\x1b[?1049hx\x1b[2J");
    try testing.expectEqual(@as(u64, 0), t.primary.pages.scrollbackRows());
}

test "selective erase keeps protected cells" {
    var t = try small();
    defer t.deinit();
    t.feed("ab\x1b[1\"qcd\x1b[0\"qef\x1b[?2K");
    try expectText(&t, "  cd");
    t.feed("\x1b[2K");
    try expectText(&t, "");
}

test "ICH, DCH, IL, DL, SU, SD" {
    var t = try small();
    defer t.deinit();
    t.feed("0123456789\x1b[1;3H\x1b[2@");
    try expectText(&t, "01  234567");
    t.feed("\x1b[3P");
    try expectText(&t, "0134567");
    t.feed("\r\nline1\r\nline2\x1b[2;1H\x1b[L");
    try expectText(&t, "0134567\n\nline1\nline2");
    try expectCursor(&t, 0, 1);
    t.feed("\x1b[2M");
    try expectText(&t, "0134567\nline2");
    t.feed("\x1b[S");
    try expectText(&t, "line2");
    t.feed("\x1b[2T");
    try expectText(&t, "\n\nline2");
}

test "IL/DL outside the region and ICH outside left/right margins are no-ops" {
    var t = try small();
    defer t.deinit();
    t.feed("a\r\nb\r\nc\x1b[2;3r\x1b[1;1H\x1b[L");
    try expectText(&t, "a\nb\nc");
    t.feed("\x1b[?69h\x1b[3;5s\x1b[1;1H\x1b[@");
    try expectText(&t, "a\nb\nc");
}

test "scroll region: LF at bottom margin and RI at top" {
    var t = try small();
    defer t.deinit();
    t.feed("1\r\n2\r\n3\r\n4\r\n5\x1b[2;4r\x1b[4;1H\n");
    try expectText(&t, "1\n3\n4\n\n5");
    t.feed("\x1b[2;1H\x1bM");
    try expectText(&t, "1\n\n3\n4\n5");
    try testing.expectEqual(@as(u64, 0), t.primary.pages.scrollbackRows());
}

test "left/right margins: printing wraps at the right margin; DECIC/DECDC" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b[?69h\x1b[3;6s\x1b[1;3Habcdefg");
    try expectText(&t, "  abcd\n  efg");
    t.feed("\x1b[1;4H\x1b['}");
    try expectText(&t, "  a bc\n  e fg");
    t.feed("\x1b[2'~");
    try expectText(&t, "  ac\n  eg");
    t.feed("\x1b[?69l\x1b[1;1H\x1b[r");
    try expectCursor(&t, 0, 0);
}

test "tabs: HTS, TBC, CHT, CBT" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b[3g\x1b[1;3H\x1bH\x1b[1;6H\x1bH\r\t");
    try expectCursor(&t, 2, 0);
    t.feed("\x1b[2I");
    try expectCursor(&t, 9, 0);
    t.feed("\x1b[Z");
    try expectCursor(&t, 5, 0);
    t.feed("\x1b[0g\r\x1b[2I");
    try expectCursor(&t, 9, 0);
}

test "charsets: DEC line drawing, single shifts, UK" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b(0lqqk\x1b(B x");
    try expectText(&t, "┌──┐ x");
    t.feed("\r\n\x1b*0\x1bNq\x1b(A#");
    try expectText(&t, "┌──┐ x\n─£");
}

test "DECSC/DECRC restore position, style, charsets, origin, autowrap" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b[2;4r\x1b[?6h\x1b[2;3H\x1b[1;31m\x1b(0\x1b[?7l\x1b7");
    t.feed("\x1b[m\x1b(B\x1b[?6l\x1b[?7h\x1b[5;5H");
    t.feed("\x1b8");
    try expectCursor(&t, 2, 2);
    try testing.expect(t.modes.get(.origin));
    try testing.expect(!t.modes.get(.autowrap));
    try testing.expect(!t.screen().modes.autowrap);
    try testing.expect(t.screen().cursor.style.flags.bold);
    t.feed("q");
    try expectText(&t, "\n\n  ─");
}

test "DECRC without DECSC homes and resets attributes" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b[3;3H\x1b[1m\x1b8");
    try expectCursor(&t, 0, 0);
    try testing.expect(t.screen().cursor.style.isDefault());
}

test "SCOSC/SCORC; CSI s is DECSLRM with DECLRMM" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b[2;3H\x1b[s\x1b[H\x1b[u");
    try expectCursor(&t, 2, 1);
    t.feed("\x1b[?69h\x1b[2;5s");
    try testing.expectEqual(@as(u16, 1), t.screen().region.left);
    try testing.expectEqual(@as(u16, 4), t.screen().region.right);
    t.feed("\x1b[5;5s"); // too narrow: ignored
    try testing.expectEqual(@as(u16, 1), t.screen().region.left);
}

test "DECALN" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b[2;3r\x1b[3;3H\x1b#8");
    try expectText(&t, "EEEEEEEEEE\nEEEEEEEEEE\nEEEEEEEEEE\nEEEEEEEEEE\nEEEEEEEEEE");
    try expectCursor(&t, 0, 0);
    try testing.expectEqual(@as(u16, 4), t.screen().region.bottom);
}

test "REP repeats the last printed character only right after a print" {
    var t = try small();
    defer t.deinit();
    t.feed("ab\x1b[3b");
    try expectText(&t, "abbbb");
    t.feed("\r\n\x1b[3b");
    try expectText(&t, "abbbb");
}

test "DECBI/DECFI" {
    var t = try small();
    defer t.deinit();
    t.feed("abc\r\x1b6");
    try expectText(&t, " abc");
    t.feed("\x1b[1;10H\x1b9");
    try expectText(&t, "abc");
}

test "RIS and DECSTR" {
    var t = try small();
    defer t.deinit();
    t.feed("x\x1b[2;3r\x1b[?6h\x1b[4h\x1b[1m\x1b]2;hi\x07\x1b[?25l\x1b[!p");
    try testing.expect(!t.modes.get(.origin));
    try testing.expect(!t.modes.get(.insert));
    try testing.expect(t.modes.get(.cursor_visible));
    try testing.expect(t.screen().cursor.style.isDefault());
    try testing.expectEqual(@as(u16, 4), t.screen().region.bottom);
    try expectText(&t, "x");
    try testing.expectEqualStrings("hi", t.title.items);
    t.feed("\x1b]4;1;#123456\x07\x1bc");
    try expectText(&t, "");
    try expectCursor(&t, 0, 0);
    try testing.expectEqualStrings("", t.title.items);
    try testing.expectEqual(t.default_palette.ansi[1], t.palette.ansi[1]);
}

test "SGR applies to printed cells: truecolor, curly underline, underline colour" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b[38:2::255:0:0;4:3;58:5:196mX\x1b[38;2;255;0;0mY");
    const s = t.screen();
    const p = s.rowPin(0);
    const page = &p.node.page;
    const st = page.styleOf(p.cells()[0]);
    try testing.expect(st.fg.eql(.rgb(255, 0, 0)));
    try testing.expectEqual(@import("../screen/style.zig").Underline.curly, st.underline);
    try testing.expect(st.ul_color.eql(.palette(196)));
    const st2 = page.styleOf(p.cells()[1]);
    try testing.expect(st2.fg.eql(.rgb(255, 0, 0)));
}

test "DECRQM for the spec's modes; unknown is 0" {
    var t = try small();
    defer t.deinit();
    try expectReply(&t, "\x1b[?2026$p", "\x1b[?2026;2$y");
    try expectReply(&t, "\x1b[?2027h\x1b[?2027$p", "\x1b[?2027;1$y");
    try expectReply(&t, "\x1b[?2004$p", "\x1b[?2004;2$y");
    try expectReply(&t, "\x1b[?1006h\x1b[?1006$p", "\x1b[?1006;1$y");
    try expectReply(&t, "\x1b[?8$p", "\x1b[?8;3$y");
    try expectReply(&t, "\x1b[?5522$p", "\x1b[?5522;4$y");
    try expectReply(&t, "\x1b[?31337$p", "\x1b[?31337;0$y");
    try expectReply(&t, "\x1b[4$p", "\x1b[4;2$y");
}

test "XTSAVE/XTRESTORE" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b[?2004h\x1b[?2004s\x1b[?2004l\x1b[?2004r");
    try testing.expect(t.modes.get(.bracketed_paste));
}

test "mouse modes exclusivity" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b[?1000h\x1b[?1003h");
    try testing.expect(!t.modes.get(.mouse_normal));
    try testing.expect(t.modes.get(.mouse_any));
    t.feed("\x1b[?1003l");
    try testing.expect(!t.modes.get(.mouse_any));
    try testing.expect(!t.modes.get(.mouse_normal));
}

test "alternate screen 1049 restores primary and cursor; not in scrollback" {
    var t = try small();
    defer t.deinit();
    t.feed("prompt\x1b[1;4H\x1b[?1049h");
    try expectText(&t, "");
    try testing.expect(t.alt_active);
    t.feed("vim1\r\nvim2\r\n\n\n\n\n\n");
    t.feed("\x1b[?1049l");
    try testing.expect(!t.alt_active);
    try expectText(&t, "prompt");
    try expectCursor(&t, 3, 0);
    try testing.expectEqual(@as(u64, 0), t.primary.pages.scrollbackRows());
}

test "alternate screen 47 and 1047" {
    var t = try small();
    defer t.deinit();
    t.feed("main\x1b[?47hAlt");
    try expectText(&t, "    Alt");
    t.feed("\x1b[?47l");
    try expectText(&t, "mainAlt"[0..4]);
    t.feed("\x1b[?1047h");
    try expectText(&t, "    Alt");
    t.feed("\x1b[?1047l\x1b[?1047h");
    try expectText(&t, "");
}

test "DECSCUSR and DECRQSS" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b[5 q");
    try testing.expectEqual(Terminal.CursorShape.blinking_bar, t.cursor_shape);
    try expectReply(&t, "\x1bP$q q\x1b\\", "\x1bP1$r5 q\x1b\\");
    try expectReply(&t, "\x1b[1;38:2::255:0:0m\x1bP$qm\x1b\\", "\x1bP1$r0;1;38:2::255:0:0m\x1b\\");
    try expectReply(&t, "\x1b[2;4r\x1bP$qr\x1b\\", "\x1bP1$r2;4r\x1b\\");
    try expectReply(&t, "\x1bP$qs\x1b\\", "\x1bP1$r1;10s\x1b\\");
    try expectReply(&t, "\x1bP$q\"q\x1b\\", "\x1bP1$r0\"q\x1b\\");
    try expectReply(&t, "\x1bP$q\"p\x1b\\", "\x1bP1$r62;1\"p\x1b\\");
    try expectReply(&t, "\x1bP$qzz\x1b\\", "\x1bP0$r\x1b\\");
}

test "DA1, DA2, DA3, XTVERSION, DSR" {
    var t = try small();
    defer t.deinit();
    try expectReply(&t, "\x1b[c", "\x1b[?62;22c");
    try expectReply(&t, "\x1b[0c", "\x1b[?62;22c");
    try expectReply(&t, "\x1b[>c", "\x1b[>1;10;0c");
    try expectReply(&t, "\x1b[=c", "\x1bP!|7A475552\x1b\\");
    try expectReply(&t, "\x1b[>q", "\x1bP>|zigguro(0.1.0)\x1b\\");
    try expectReply(&t, "\x1b[>0q", "\x1bP>|zigguro(0.1.0)\x1b\\");
    try expectReply(&t, "\x1b[5n", "\x1b[0n");
    try expectReply(&t, "\x1b[2;3H\x1b[6n", "\x1b[2;3R");
    try expectReply(&t, "\x1b[?15n", "\x1b[?13n");
    try expectReply(&t, "\x1b[?26n", "\x1b[?27;1;0;0n");
}

test "XTGETTCAP" {
    var t = try small();
    defer t.deinit();
    // "TN" = 544E, "Co" = 436F, "xx" = 7878.
    try expectReply(&t, "\x1bP+q544E;7878\x1b\\", "\x1bP1+r544E=787465726D2D323536636F6C6F72\x1b\\\x1bP0+r7878\x1b\\");
    try expectReply(&t, "\x1bP+q436F\x1b\\", "\x1bP1+r436F=323536\x1b\\");
    try expectReply(&t, "\x1bP+qZZ\x1b\\", "\x1bP0+r\x1b\\");
}

test "XTWINOPS sizes and the title stack; title reports are disabled" {
    var t = try small();
    defer t.deinit();
    t.cell_px = .{ .w = 8, .h = 16 };
    try expectReply(&t, "\x1b[18t", "\x1b[8;5;10t");
    try expectReply(&t, "\x1b[16t", "\x1b[6;16;8t");
    try expectReply(&t, "\x1b[14t", "\x1b[4;80;80t");
    try expectReply(&t, "\x1b]2;secret\x07\x1b[21t\x1b[20t", "");
    t.feed("\x1b[22t\x1b]2;other\x07\x1b[23t");
    try testing.expectEqualStrings("secret", t.title.items);
    for (0..15) |i| {
        var b: [32]u8 = undefined;
        t.feed(try std.fmt.bufPrint(&b, "\x1b]2;t{d}\x07\x1b[22t", .{i}));
    }
    try testing.expectEqual(@as(usize, Terminal.title_stack_max), t.title_stack.items.len);
    for (0..20) |_| t.feed("\x1b[23t");
    try testing.expectEqualStrings("t5", t.title.items);
}

test "colour OSCs: set, query with BEL and ST, reset" {
    var t = try small();
    defer t.deinit();
    try expectReply(&t, "\x1b]4;1;?\x07", "\x1b]4;1;rgb:cdcd/0000/0000\x07");
    try expectReply(&t, "\x1b]4;1;#102030;2;?\x1b\\", "\x1b]4;2;rgb:0000/cdcd/0000\x1b\\");
    try testing.expectEqual([3]u8{ 0x10, 0x20, 0x30 }, t.palette.ansi[1]);
    try expectReply(&t, "\x1b]11;?\x07", "\x1b]11;rgb:0000/0000/0000\x07");
    t.feed("\x1b]10;rgb:ff/ff/ff;#000080\x07");
    try testing.expectEqual([3]u8{ 0, 0, 0x80 }, t.palette.bg);
    t.feed("\x1b]104;1\x07\x1b]111\x07");
    try testing.expectEqual(t.default_palette.ansi[1], t.palette.ansi[1]);
    try testing.expectEqual(t.default_palette.bg, t.palette.bg);
    var changed: usize = 0;
    for (t.effects.pending()) |e| if (e == .palette_changed) {
        changed += 1;
    };
    try testing.expect(changed >= 3);
}

test "reply limiter: 10 MiB of ESC[c produces at most 640 KiB of replies" {
    var t = try small();
    defer t.deinit();
    const chunk = "\x1b[c" ** 1024;
    const limit = 10 * 1024 * 1024;
    var total: usize = 0;
    var fed: usize = 0;
    while (fed < limit) {
        // Never exceed exactly 10 MiB of input.
        const n = @min(chunk.len, (limit - fed) / 3 * 3);
        if (n == 0) break;
        t.feed(chunk[0..n]);
        fed += n;
        total += t.replies.items.len;
        t.clearReplies();
    }
    try testing.expect(total <= 640 * 1024);
    try testing.expect(total >= 600 * 1024);
    var dropped: usize = 0;
    for (t.effects.pending()) |e| if (e == .replies_dropped) {
        dropped += 1;
    };
    try testing.expect(dropped >= 1);
}

test "OSC 0/1/2 titles are sanitised" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b]0;a\x01b\xffc\x1b\\");
    try testing.expectEqualStrings("ab\u{FFFD}c", t.title.items);
    try testing.expectEqualStrings("ab\u{FFFD}c", t.icon.items);
    t.feed("\x1b]2;" ++ "x" ** 2000 ++ "\x07");
    try testing.expectEqual(@as(usize, Terminal.title_max), t.title.items.len);
    t.feed("\x1b]x;bad\x07");
    try testing.expectEqual(@as(usize, Terminal.title_max), t.title.items.len);
}

fn lastEffect(t: *Terminal) ?@import("effects.zig").Effect {
    const p = t.effects.pending();
    return if (p.len == 0) null else p[p.len - 1];
}

test "OSC 7 percent-decoding and host classification" {
    var t = try Terminal.init(gpa, .{ .cols = 10, .rows = 5, .hostname = "box" });
    defer t.deinit();
    t.feed("\x1b]7;file://box/home/a%20b\x07");
    const e = lastEffect(&t).?.cwd;
    try testing.expectEqualStrings("/home/a b", e.path);
    try testing.expect(!e.remote);
    t.feed("\x1b]7;file://other/srv\x1b\\");
    try testing.expect(lastEffect(&t).?.cwd.remote);
    t.feed("\x1b]7;kitty-shell-cwd://localhost/tmp\x07");
    try testing.expect(!lastEffect(&t).?.cwd.remote);
    try testing.expectEqualStrings("/tmp", lastEffect(&t).?.cwd.path);
}

test "OSC 8 id grouping and close; too long and schemeless URIs are ignored" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b]8;id=x;https://a.example\x1b\\ab\x1b]8;;\x1b\\c");
    const s = t.screen();
    const p = s.rowPin(0);
    const page = &p.node.page;
    const l0 = page.hyperlinkOf(&p.cells()[0]).?;
    try testing.expectEqualStrings("https://a.example", l0.uri);
    try testing.expectEqualStrings("x", l0.id);
    try testing.expect(page.hyperlinkOf(&p.cells()[1]) != null);
    try testing.expect(page.hyperlinkOf(&p.cells()[2]) == null);
    t.feed("\x1b]8;;" ++ "h:" ++ "a" ** 2082 ++ "\x07d");
    try testing.expect(page.hyperlinkOf(&p.cells()[3]) == null);
    t.feed("\x1b]8;;no-scheme\x07e");
    try testing.expect(page.hyperlinkOf(&p.cells()[4]) == null);
    t.feed("\x1b]8;id=" ++ "i" ** 251 ++ ";https://b\x07f");
    try testing.expect(page.hyperlinkOf(&p.cells()[5]) == null);
}

test "OSC 52: write, empty Pc is s0, query waits for approval, deny sends nothing" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b]52;c;aGVs bG8=\x07");
    const w = lastEffect(&t).?.clipboard_write;
    try testing.expectEqualStrings("hello", w.data.?);
    try testing.expect(w.targets.c);
    t.feed("\x1b]52;;aGk\x07");
    const w2 = lastEffect(&t).?.clipboard_write;
    try testing.expectEqualStrings("hi", w2.data.?);
    try testing.expect(w2.targets.s and w2.targets.cut == 1);
    const before = t.effects.pending().len;
    t.feed("\x1b]52;c;!!!\x07");
    try testing.expectEqual(before, t.effects.pending().len);
    t.feed("\x1b]52;c;?\x1b\\");
    try testing.expect(lastEffect(&t).? == .clipboard_read);
    try testing.expectEqualStrings("", t.replies.items);
    t.answerClipboardRead(null); // denied
    try testing.expectEqualStrings("", t.replies.items);
    t.answerClipboardRead("late"); // nothing pending any more
    try testing.expectEqualStrings("", t.replies.items);
    t.feed("\x1b]52;c;?\x1b\\");
    t.answerClipboardRead("ok");
    try testing.expectEqualStrings("\x1b]52;c;b2s=\x1b\\", t.replies.items);
}

test "OSC 52 over the size cap is dropped" {
    var t = try Terminal.init(gpa, .{ .cols = 10, .rows = 5, .clipboard_max = 4 });
    defer t.deinit();
    t.feed("\x1b]52;c;aGVsbG8=\x07");
    try testing.expectEqual(@as(usize, 0), t.effects.pending().len);
}

fn rowOfPin(p: @import("../screen/PageList.zig").Pin) u64 {
    return p.y;
}

test "OSC 133 sequence A,B,C,D;2 forwards 4 marks with pins at correct rows" {
    var t = try small();
    defer t.deinit();
    var rec: mark.RecordingMarkSink = .{ .gpa = gpa, .rowOf = rowOfPin };
    defer rec.deinit();
    t.mark_sink = rec.sink();
    t.feed("\x1b]133;A;aid=1;k=s\x07$ \x1b]133;B\x07ls\r\n\x1b]133;C\x07out\r\n\x1b]133;D;2\x07");
    try testing.expectEqualStrings("A k=secondary aid=1\nB\nC\nD 2\n", rec.log.items);
    try testing.expectEqualSlices(u64, &.{ 0, 0, 1, 2 }, rec.rows.items);
}

test "OSC 633 E trusted only with the nonce; P properties" {
    var t = try Terminal.init(gpa, .{ .cols = 10, .rows = 5, .shell_nonce = "abc" });
    defer t.deinit();
    var rec: mark.RecordingMarkSink = .{ .gpa = gpa };
    defer rec.deinit();
    t.mark_sink = rec.sink();
    t.feed("\x1b]633;E;ls\\x3b -l\\\\;abc\x07\x1b]633;E;rm;zzz\x07\x1b]633;P;Shell=bash\x07\x1b]633;D\x07");
    try testing.expectEqualStrings("E trusted ls; -l\\\nE untrusted rm\nP Shell=bash\nD -\n", rec.log.items);
}

test "OSC 9 progress, cwd and notifications; 777; rate limit" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b]9;4;1;42\x07");
    const pr = lastEffect(&t).?.progress;
    try testing.expectEqual(@as(u8, 42), pr.percent);
    try testing.expect(pr.state == .normal);
    t.feed("\x1b]9;9;\"C:\\work\"\x07");
    try testing.expectEqualStrings("C:\\work", lastEffect(&t).?.cwd.path);
    t.now_ms = 5000;
    t.feed("\x1b]9;build done\x07");
    try testing.expectEqualStrings("build done", lastEffect(&t).?.notify.body);
    t.feed("\x1b]777;notify;T;B\x07");
    try testing.expectEqual(@as(u32, 1), t.stats.notifications_suppressed);
    t.now_ms = 6500;
    t.feed("\x1b]777;notify;T;B\x07");
    try testing.expectEqualStrings("T", lastEffect(&t).?.notify.title);
}

test "OSC 1337 user vars, current dir, mark; OSC 22 pointer" {
    var t = try small();
    defer t.deinit();
    var rec: mark.RecordingMarkSink = .{ .gpa = gpa };
    defer rec.deinit();
    t.mark_sink = rec.sink();
    t.feed("\x1b]1337;SetUserVar=foo=YmFy\x07");
    try testing.expectEqualStrings("bar", t.user_vars.get("foo").?);
    t.feed("\x1b]1337;CurrentDir=/x\x07\x1b]1337;SetMark\x07\x1b]22;text\x07");
    try testing.expectEqualStrings("cwd /x\nbookmark\n", rec.log.items);
    try testing.expectEqualStrings("text", lastEffect(&t).?.pointer_shape);
}

test "DCS =1s/=2s maps to 2026; tmux passthrough and APC are ignored" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1bP=1s\x1b\\");
    try testing.expect(t.modes.get(.synchronized_output));
    t.feed("\x1bP=2s\x1b\\");
    try testing.expect(!t.modes.get(.synchronized_output));
    try expectReply(&t, "\x1bPtmux;hello\x1b\\\x1b_Gx\x1b\\", "");
}

test "kitty keyboard flag stack" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b[>5u");
    try expectReply(&t, "\x1b[?u", "\x1b[?5u");
    t.feed("\x1b[=2;2u");
    try expectReply(&t, "\x1b[?u", "\x1b[?7u");
    t.feed("\x1b[<u");
    try expectReply(&t, "\x1b[?u", "\x1b[?0u");
}

test "mode 2048 sends a size report on set and resize" {
    var t = try small();
    defer t.deinit();
    try expectReply(&t, "\x1b[?2048h", "\x1b[48;5;10;0;0t");
    try t.resize(12, 6);
    try testing.expectEqualStrings("\x1b[48;6;12;0;0t", t.replies.items);
}

test "grapheme mode 2027 is wired to the print path" {
    var t = try small();
    defer t.deinit();
    t.feed("\x1b[?2027h");
    try testing.expect(t.screen().modes.grapheme);
    t.feed("\x1b[?7l");
    try testing.expect(!t.screen().modes.autowrap);
    try testing.expect(!t.alternate.modes.autowrap);
}

test "handlers do not allocate after warm-up" {
    var counting = @import("zg_core").alloc.CountingAllocator.init(gpa);
    var t = try Terminal.init(counting.allocator(), .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 1 << 20 });
    defer t.deinit();
    const seq = "\x1b[1;31mhello\x1b[m\r\n\x1b[2J\x1b[H\x1b[5;5H\x1b[K\x1b[2@\x1b[P\x1b[L\x1b[M\x1b[S\x1b[T" ++
        "\x1b[?25l\x1b[?25h\x1b[2;4r\x1b[r\x1b[?2026h\x1b[?2026l\x1b[6n\x1b(0q\x1b(B\x1b[3b\x1b7\x1b8\r\n\n\n";
    for (0..20_000) |_| {
        t.feed(seq);
        t.clearReplies();
        t.effects.clear();
    }
    const before = counting.allocs.load(.monotonic);
    for (0..1000) |_| {
        t.feed(seq);
        t.clearReplies();
        t.effects.clear();
    }
    try testing.expectEqual(before, counting.allocs.load(.monotonic));
    try t.screen().checkInvariants();
}

fn fuzzTerminal(_: void, s: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const input = buf[0..s.slice(&buf)];
    var chunks: [8][]const u8 = undefined;
    const parts = @import("zg_core").testkit.fuzz.chunked(s, input, 8, &chunks);
    var t = try Terminal.init(gpa, .{ .cols = 12, .rows = 6, .max_scrollback_bytes = 1 << 16, .clipboard_max = 256, .parser = .{ .osc_max = 512, .osc52_max = 1024, .dcs_max = 1024, .apc_max = 1024 } });
    defer t.deinit();
    for (parts) |c| {
        t.feed(c);
        try t.screen().checkInvariants();
        try t.primary.checkInvariants();
        try t.alternate.checkInvariants();
        t.clearReplies();
        if (t.clip_read != null) t.answerClipboardRead("x");
        t.effects.clear();
    }
    // A resize in the middle of arbitrary state must keep the invariants.
    try t.resize(7, 3);
    t.feed(input);
    try t.screen().checkInvariants();
}

test "fuzz: terminal" {
    try std.testing.fuzz({}, fuzzTerminal, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "terminal") });
}
