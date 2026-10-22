//! Movement: the word-stop table (docs/editor/word-movement.md),
//! graphemes across pieces, subwords, smart home, display rows, brackets,
//! paragraphs, delete commands and the boundary property.

const std = @import("std");
const zg_syntax = @import("zg_syntax");
const movement = @import("movement.zig");
const word = @import("word.zig");
const cmds = @import("commands_move.zig");
const mc = @import("multi_cursor.zig");
const sel_mod = @import("selection.zig");
const document = @import("../document.zig");
const snapshot_mod = @import("../snapshot.zig");

const gpa = std.testing.allocator;
const Unit = movement.Unit;
const Dir = movement.Dir;
const Document = document.Document;
const SelectionSet = sel_mod.SelectionSet;

/// The caret marker in table strings.
const mark = "¦";

const Case = struct { unit: Unit, dir: Dir, from: []const u8, to: []const u8, lang: ?*const zg_syntax.Language = null };

fn split(s: []const u8, text: []u8) struct { text: []const u8, pos: u64 } {
    const i = std.mem.indexOf(u8, s, mark).?;
    @memcpy(text[0..i], s[0..i]);
    @memcpy(text[i..][0 .. s.len - i - mark.len], s[i + mark.len ..]);
    return .{ .text = text[0 .. s.len - mark.len], .pos = i };
}

fn check(c: Case) !void {
    var b1: [512]u8 = undefined;
    var b2: [512]u8 = undefined;
    const a = split(c.from, &b1);
    const want = split(c.to, &b2);
    try std.testing.expectEqualStrings(a.text, want.text);
    const doc = try Document.initBytes(gpa, @enumFromInt(1), a.text);
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.release();
    const got = movement.move(&snap, a.pos, c.unit, c.dir, .{ .lang = c.lang });
    if (got != want.pos) {
        var out: [600]u8 = undefined;
        const shown = try std.fmt.bufPrint(&out, "{s}" ++ mark ++ "{s}", .{ a.text[0..@intCast(got)], a.text[@intCast(got)..] });
        std.debug.print("{s} {s}: from \"{s}\"\n  want \"{s}\"\n  got  \"{s}\"\n", .{ @tagName(c.unit), @tagName(c.dir), c.from, c.to, shown });
        return error.TestUnexpectedResult;
    }
}

/// The word-stop table. VS Code semantics: word right skips whitespace
/// and lands at the end of the next run (identifier, punctuation, CJK or
/// emoji); word left lands at the start of the previous run; an EOL is a
/// stop of its own.
pub const word_stops = [_]Case{
    // code
    .{ .unit = .word, .dir = .forward, .from = "¦const x = 1;", .to = "const¦ x = 1;" },
    .{ .unit = .word, .dir = .forward, .from = "const¦ x = 1;", .to = "const x¦ = 1;" },
    .{ .unit = .word, .dir = .forward, .from = "const x¦ = 1;", .to = "const x =¦ 1;" },
    .{ .unit = .word, .dir = .forward, .from = "const x = 1¦;", .to = "const x = 1;¦" },
    .{ .unit = .word, .dir = .forward, .from = "¦foo_bar.baz()", .to = "foo_bar¦.baz()" },
    .{ .unit = .word, .dir = .forward, .from = "foo_bar¦.baz()", .to = "foo_bar.¦baz()" },
    .{ .unit = .word, .dir = .forward, .from = "foo_bar.baz¦()", .to = "foo_bar.baz()¦" },
    .{ .unit = .word, .dir = .forward, .from = "a¦ -> b", .to = "a ->¦ b" },
    .{ .unit = .word, .dir = .forward, .from = "x¦ += 2", .to = "x +=¦ 2" },
    .{ .unit = .word, .dir = .forward, .from = "if (a¦ || b)", .to = "if (a ||¦ b)" },
    .{ .unit = .word, .dir = .forward, .from = "¦0x1F + 3.5", .to = "0x1F¦ + 3.5" },
    .{ .unit = .word, .dir = .forward, .from = "0x1F + 3¦.5", .to = "0x1F + 3.¦5" },
    .{ .unit = .word, .dir = .forward, .from = "¦$scope.x", .to = "$¦scope.x" },
    .{ .unit = .word, .dir = .forward, .from = "¦$scope.x", .to = "$scope¦.x", .lang = &zg_syntax.langs.js.javascript_language },
    .{ .unit = .word, .dir = .forward, .from = "¦@import(\"std\")", .to = "@¦import(\"std\")" },
    .{ .unit = .word, .dir = .forward, .from = "¦@import(\"std\")", .to = "@import¦(\"std\")", .lang = &zg_syntax.langs.zig.zig_language },
    .{ .unit = .word, .dir = .forward, .from = "¦margin-top: 0", .to = "margin-top¦: 0", .lang = &zg_syntax.langs.css.css_language },
    .{ .unit = .word, .dir = .forward, .from = "¦margin-top: 0", .to = "margin¦-top: 0" },
    .{ .unit = .word, .dir = .backward, .from = "const x = 1;¦", .to = "const x = 1¦;" },
    .{ .unit = .word, .dir = .backward, .from = "const x = 1¦;", .to = "const x = ¦1;" },
    .{ .unit = .word, .dir = .backward, .from = "const x ¦= 1;", .to = "const ¦x = 1;" },
    .{ .unit = .word, .dir = .backward, .from = "foo_bar.baz()¦", .to = "foo_bar.baz¦()" },
    .{ .unit = .word, .dir = .backward, .from = "foo_bar.baz¦()", .to = "foo_bar.¦baz()" },
    .{ .unit = .word, .dir = .backward, .from = "a ->¦ b", .to = "a ¦-> b" },
    .{ .unit = .word, .dir = .backward, .from = "    ¦x", .to = "¦    x" },
    // whitespace and lines
    .{ .unit = .word, .dir = .forward, .from = "a¦   \nb", .to = "a   ¦\nb" },
    .{ .unit = .word, .dir = .forward, .from = "a   ¦\nb", .to = "a   \n¦b" },
    .{ .unit = .word, .dir = .forward, .from = "a¦\r\nb", .to = "a\r\n¦b" },
    .{ .unit = .word, .dir = .backward, .from = "a\n¦b", .to = "a¦\nb" },
    .{ .unit = .word, .dir = .backward, .from = "a\r\n¦b", .to = "a¦\r\nb" },
    .{ .unit = .word, .dir = .backward, .from = "a\n   ¦b", .to = "a\n¦   b" },
    .{ .unit = .word, .dir = .forward, .from = "\t¦\tx y", .to = "\t\tx¦ y" },
    .{ .unit = .word, .dir = .forward, .from = "end¦", .to = "end¦" },
    .{ .unit = .word, .dir = .backward, .from = "¦start", .to = "¦start" },
    // prose
    .{ .unit = .word, .dir = .forward, .from = "¦Hello, world!", .to = "Hello¦, world!" },
    .{ .unit = .word, .dir = .forward, .from = "Hello¦, world!", .to = "Hello,¦ world!" },
    .{ .unit = .word, .dir = .forward, .from = "Hello, world¦!", .to = "Hello, world!¦" },
    .{ .unit = .word, .dir = .forward, .from = "¦don't stop", .to = "don¦'t stop" },
    .{ .unit = .word, .dir = .forward, .from = "¦naïve café", .to = "naïve¦ café" },
    .{ .unit = .word, .dir = .forward, .from = "naïve¦ café", .to = "naïve café¦" },
    .{ .unit = .word, .dir = .backward, .from = "naïve café¦", .to = "naïve ¦café" },
    .{ .unit = .word, .dir = .forward, .from = "¦Straße—weiter", .to = "Straße¦—weiter" },
    .{ .unit = .word, .dir = .forward, .from = "Straße¦—weiter", .to = "Straße—¦weiter" },
    .{ .unit = .word, .dir = .forward, .from = "¦«quoted»", .to = "«¦quoted»" },
    .{ .unit = .word, .dir = .forward, .from = "¦e\u{301}t\u{e9}", .to = "e\u{301}t\u{e9}¦" },
    // CJK
    .{ .unit = .word, .dir = .forward, .from = "¦中文字 abc", .to = "中文字¦ abc" },
    .{ .unit = .word, .dir = .forward, .from = "¦日本語テキスト", .to = "日本語テキスト¦" },
    .{ .unit = .word, .dir = .forward, .from = "¦한국어 단어", .to = "한국어¦ 단어" },
    .{ .unit = .word, .dir = .forward, .from = "¦abc中文", .to = "abc¦中文" },
    .{ .unit = .word, .dir = .backward, .from = "abc中文¦", .to = "abc¦中文" },
    .{ .unit = .word, .dir = .forward, .from = "¦中文，好", .to = "中文¦，好" },
    .{ .unit = .word, .dir = .forward, .from = "中文¦，好", .to = "中文，¦好" },
    // emoji
    .{ .unit = .word, .dir = .forward, .from = "¦👍👍 ok", .to = "👍👍¦ ok" },
    .{ .unit = .word, .dir = .forward, .from = "¦ok👍", .to = "ok¦👍" },
    .{ .unit = .word, .dir = .forward, .from = "¦👨\u{200d}👩\u{200d}👧 x", .to = "👨\u{200d}👩\u{200d}👧¦ x" },
    .{ .unit = .word, .dir = .backward, .from = "a 🎉🎉¦", .to = "a ¦🎉🎉" },
    // Arabic and Hebrew
    .{ .unit = .word, .dir = .forward, .from = "¦مرحبا بالعالم", .to = "مرحبا¦ بالعالم" },
    .{ .unit = .word, .dir = .backward, .from = "مرحبا بالعالم¦", .to = "مرحبا ¦بالعالم" },
    .{ .unit = .word, .dir = .forward, .from = "¦שלום עולם", .to = "שלום¦ עולם" },
    // mixed punctuation
    .{ .unit = .word, .dir = .forward, .from = "¦...rest", .to = "...¦rest" },
    .{ .unit = .word, .dir = .forward, .from = "x¦ !== y", .to = "x !==¦ y" },
    .{ .unit = .word, .dir = .forward, .from = "¦/* note */", .to = "/*¦ note */" },
    .{ .unit = .word, .dir = .backward, .from = "a::<T>()¦", .to = "a::<T¦>()" },
    .{ .unit = .word, .dir = .forward, .from = "path¦/to/file.zig", .to = "path/¦to/file.zig" },
    .{ .unit = .word, .dir = .forward, .from = "¦#include <x>", .to = "#¦include <x>" },
    .{ .unit = .word, .dir = .forward, .from = "¦#include <x>", .to = "#include¦ <x>", .lang = &zg_syntax.langs.c.c_language },
    // Vim word ends and WORDs
    .{ .unit = .word_end, .dir = .forward, .from = "¦foo bar", .to = "foo¦ bar" },
    .{ .unit = .word_end, .dir = .forward, .from = "fo¦o bar", .to = "foo bar¦" },
    .{ .unit = .word_end, .dir = .forward, .from = "foo¦\n\n  bar", .to = "foo\n\n  bar¦" },
    .{ .unit = .word_end, .dir = .backward, .from = "foo bar¦", .to = "foo¦ bar" },
    .{ .unit = .word_end, .dir = .backward, .from = "foo.ba¦r", .to = "foo.¦bar" },
    .{ .unit = .whitespace_word, .dir = .forward, .from = "¦a.b(c) next", .to = "a.b(c) ¦next" },
    .{ .unit = .whitespace_word, .dir = .backward, .from = "a.b(c) ne¦xt", .to = "a.b(c) ¦next" },
    .{ .unit = .whitespace_word, .dir = .backward, .from = "a.b(c) ¦next", .to = "¦a.b(c) next" },
};

test "movement: word stops golden" {
    try std.testing.expect(word_stops.len >= 60);
    var failed: usize = 0;
    for (word_stops) |c| check(c) catch {
        failed += 1;
    };
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "movement: subword HTTPServer/snake_case/kebab-case/digits" {
    const cases = [_]Case{
        .{ .unit = .subword, .dir = .forward, .from = "¦HTTPServer", .to = "HTTP¦Server" },
        .{ .unit = .subword, .dir = .forward, .from = "HTTP¦Server", .to = "HTTPServer¦" },
        .{ .unit = .subword, .dir = .backward, .from = "HTTPServer¦", .to = "HTTP¦Server" },
        .{ .unit = .subword, .dir = .backward, .from = "HTTP¦Server", .to = "¦HTTPServer" },
        .{ .unit = .subword, .dir = .forward, .from = "¦fooBarBaz", .to = "foo¦BarBaz" },
        .{ .unit = .subword, .dir = .forward, .from = "foo¦BarBaz", .to = "fooBar¦Baz" },
        .{ .unit = .subword, .dir = .backward, .from = "fooBar¦Baz", .to = "foo¦BarBaz" },
        .{ .unit = .subword, .dir = .forward, .from = "¦snake_case_name", .to = "snake¦_case_name" },
        .{ .unit = .subword, .dir = .forward, .from = "snake¦_case_name", .to = "snake_case¦_name" },
        .{ .unit = .subword, .dir = .backward, .from = "snake_case_name¦", .to = "snake_case_¦name" },
        .{ .unit = .subword, .dir = .backward, .from = "snake_case_¦name", .to = "snake_¦case_name" },
        .{ .unit = .subword, .dir = .forward, .from = "¦kebab-case", .to = "kebab¦-case", .lang = &zg_syntax.langs.css.css_language },
        .{ .unit = .subword, .dir = .forward, .from = "kebab¦-case", .to = "kebab-case¦", .lang = &zg_syntax.langs.css.css_language },
        .{ .unit = .subword, .dir = .forward, .from = "¦utf8Decode", .to = "utf¦8Decode" },
        .{ .unit = .subword, .dir = .forward, .from = "utf¦8Decode", .to = "utf8¦Decode" },
        .{ .unit = .subword, .dir = .forward, .from = "¦x  fooBar", .to = "x¦  fooBar" },
        .{ .unit = .subword, .dir = .forward, .from = "x¦  fooBar", .to = "x  foo¦Bar" },
    };
    var failed: usize = 0;
    for (cases) |c| check(c) catch {
        failed += 1;
    };
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "movement: grapheme across piece boundary" {
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "ab");
    defer doc.deinit();
    // Insert "e" + combining acute, then a flag, as separate pieces.
    const cs_mod = @import("change_set.zig");
    inline for (.{ .{ 1, "e" }, .{ 2, "\u{301}" }, .{ 4, "\u{1F1FA}" }, .{ 8, "\u{1F1F8}" } }) |e| {
        var cs = try cs_mod.ChangeSet.fromEdits(gpa, doc.len(), &.{.{ .range = .{ .start = e[0], .end = e[0] }, .text = e[1] }});
        defer cs.deinit();
        try doc.applyChangeSet(&cs, .{ .user = 0 });
    }
    // "a" "e\u301" "🇺🇸" "b"
    var snap = doc.snapshot();
    defer snap.release();
    const stops_f = [_]u64{ 1, 4, 12, 13 };
    var p: u64 = 0;
    for (stops_f) |want| {
        p = movement.move(&snap, p, .grapheme, .forward, .{});
        try std.testing.expectEqual(want, p);
    }
    const stops_b = [_]u64{ 12, 4, 1, 0 };
    for (stops_b) |want| {
        p = movement.move(&snap, p, .grapheme, .backward, .{});
        try std.testing.expectEqual(want, p);
    }
    // Invalid UTF-8 bytes are single units; CRLF is one.
    const bad = try Document.initBytes(gpa, @enumFromInt(2), "\xff\xfex\r\ny");
    defer bad.deinit();
    var s2 = bad.snapshot();
    defer s2.release();
    try std.testing.expectEqual(@as(u64, 1), movement.move(&s2, 0, .grapheme, .forward, .{}));
    try std.testing.expectEqual(@as(u64, 5), movement.move(&s2, 3, .grapheme, .forward, .{}));
    try std.testing.expectEqual(@as(u64, 3), movement.move(&s2, 5, .grapheme, .backward, .{}));
}

test "movement: smart home toggles" {
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "x\n    return 1;");
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.release();
    try std.testing.expectEqual(@as(u64, 6), movement.move(&snap, 12, .smart_home, .backward, .{}));
    try std.testing.expectEqual(@as(u64, 2), movement.move(&snap, 6, .smart_home, .backward, .{}));
    try std.testing.expectEqual(@as(u64, 6), movement.move(&snap, 2, .smart_home, .backward, .{}));
    try std.testing.expectEqual(@as(u64, 4), movement.move(&snap, 4, .line_boundary, .backward, .{}) + 2);
    try std.testing.expectEqual(@as(u64, 15), movement.move(&snap, 4, .line_boundary, .forward, .{}));
}

/// A display map with fixed-width rows of `w` columns over a list of
/// line lengths (soft wrap), for display_row tests.
const WrapMap = struct {
    snap: *const snapshot_mod.Snapshot,
    w: u64,

    fn rows(m: *const WrapMap) u64 {
        var n: u64 = 0;
        for (0..m.snap.tree.lineCount()) |l| {
            const lr = m.snap.tree.lineRange(l);
            n += @max(1, (lr.end - lr.start + m.w - 1) / m.w);
        }
        return n;
    }

    fn rowCount(ptr: *anyopaque) u64 {
        return @as(*WrapMap, @ptrCast(@alignCast(ptr))).rows();
    }

    fn hitTest(ptr: *anyopaque, row: u64, x: f32) mc.Hit {
        const m: *WrapMap = @ptrCast(@alignCast(ptr));
        var r: u64 = 0;
        for (0..m.snap.tree.lineCount()) |l| {
            const lr = m.snap.tree.lineRange(l);
            const n = @max(1, (lr.end - lr.start + m.w - 1) / m.w);
            if (row < r + n) {
                const start = lr.start + (row - r) * m.w;
                const end = @min(lr.end, start + m.w);
                return .{ .offset = @min(end, start + @as(u64, @intFromFloat(x))) };
            }
            r += n;
        }
        return .{ .offset = m.snap.tree.len() };
    }

    fn rowOf(ptr: *anyopaque, pos: u64) mc.RowPos {
        const m: *WrapMap = @ptrCast(@alignCast(ptr));
        var r: u64 = 0;
        for (0..m.snap.tree.lineCount()) |l| {
            const lr = m.snap.tree.lineRange(l);
            const n = @max(1, (lr.end - lr.start + m.w - 1) / m.w);
            if (pos <= lr.end) {
                const k = @min((pos - lr.start) / m.w, n - 1);
                return .{ .row = r + k, .x = @floatFromInt(pos - lr.start - k * m.w) };
            }
            r += n;
        }
        return .{ .row = r, .x = 0 };
    }

    fn query(m: *WrapMap) mc.DisplayMapQuery {
        return .{ .ptr = m, .rowCountFn = rowCount, .hitTestFn = hitTest, .rowOfFn = rowOf };
    }
};

test "movement: display_row keeps goal_x through short lines" {
    // Rows of 10: "0123456789abcdefghij" wraps into two rows; "xy" is short.
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "0123456789abcdefghij\nxy\n0123456789");
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.release();
    var wm: WrapMap = .{ .snap = &snap, .w = 10 };
    var s = try SelectionSet.init(gpa, .caret(7));
    defer s.deinit();
    const ctx: movement.MoveContext = .{ .display = wm.query() };
    cmds.moveSelections(&snap, &s, .display_row, .forward, false, ctx);
    try std.testing.expectEqual(@as(u64, 17), s.primary().head); // second visual row of line 0
    cmds.moveSelections(&snap, &s, .display_row, .forward, false, ctx);
    try std.testing.expectEqual(@as(u64, 23), s.primary().head); // end of "xy"
    cmds.moveSelections(&snap, &s, .display_row, .forward, false, ctx);
    try std.testing.expectEqual(@as(u64, 31), s.primary().head); // column 7 again
    cmds.moveSelections(&snap, &s, .display_row, .backward, true, ctx);
    try std.testing.expectEqual(@as(u64, 31), s.primary().anchor);
    try std.testing.expectEqual(@as(u64, 23), s.primary().head);

    // Headless: buffer lines and display columns (tab = 4).
    const d2 = try Document.initBytes(gpa, @enumFromInt(2), "\tabc\nab\n12345");
    defer d2.deinit();
    var s2 = d2.snapshot();
    defer s2.release();
    var t = try SelectionSet.init(gpa, .caret(3)); // column 6
    defer t.deinit();
    cmds.moveSelections(&s2, &t, .buffer_line, .forward, false, .{});
    try std.testing.expectEqual(@as(u64, 7), t.primary().head); // end of "ab"
    cmds.moveSelections(&s2, &t, .buffer_line, .forward, false, .{});
    try std.testing.expectEqual(@as(u64, 13), t.primary().head); // goal column 6 kept: end of "12345"
    try std.testing.expectEqual(@as(?f32, 6), t.primary().goal_x);
}

test "movement: matching bracket" {
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "f(a[1], {b: (c)}) x");
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.release();
    try std.testing.expectEqual(@as(u64, 16), movement.move(&snap, 1, .bracket, .forward, .{}));
    try std.testing.expectEqual(@as(u64, 1), movement.move(&snap, 16, .bracket, .forward, .{}));
    try std.testing.expectEqual(@as(u64, 15), movement.move(&snap, 8, .bracket, .forward, .{}));
    try std.testing.expectEqual(@as(u64, 3), movement.move(&snap, 6, .bracket, .forward, .{})); // just after ']'
    try std.testing.expectEqual(@as(u64, 18), movement.move(&snap, 18, .bracket, .forward, .{}));
}

test "movement: paragraphs and document" {
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "a\nb\n\n  \nc\nd\n\ne");
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.release();
    try std.testing.expectEqual(@as(u64, 4), movement.move(&snap, 0, .paragraph, .forward, .{}));
    try std.testing.expectEqual(@as(u64, 12), movement.move(&snap, 4, .paragraph, .forward, .{}));
    try std.testing.expectEqual(@as(u64, 14), movement.move(&snap, 12, .paragraph, .forward, .{}));
    try std.testing.expectEqual(@as(u64, 5), movement.move(&snap, 12, .paragraph, .backward, .{})); // the whitespace-only line
    try std.testing.expectEqual(@as(u64, 0), movement.move(&snap, 4, .paragraph, .backward, .{}));
    try std.testing.expectEqual(@as(u64, 14), movement.move(&snap, 3, .document, .forward, .{}));
}

fn textOf(doc: *Document) ![]u8 {
    return doc.tree.copyRange(gpa, .{ .start = 0, .end = doc.len() });
}

test "delete: wordLeft whitespace semantics" {
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "foo bar   \nx");
    defer doc.deinit();
    var s = try SelectionSet.init(gpa, .caret(10));
    defer s.deinit();
    _ = try cmds.deleteBy(doc, &s, .word, .backward, .{}, .{ .user = 0 });
    const a = try textOf(doc);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("foo \nx", a);
    try std.testing.expectEqual(@as(u64, 4), s.primary().head);
    _ = try cmds.deleteBy(doc, &s, .word, .backward, .{}, .{ .user = 0 });
    const b = try textOf(doc);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("\nx", b);
}

test "delete: left to tab stop, ranges, line, multiple carets" {
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "      x\nabc\ndef");
    defer doc.deinit();
    var s = try SelectionSet.init(gpa, .caret(6));
    defer s.deinit();
    _ = try cmds.deleteBy(doc, &s, .grapheme, .backward, .{}, .{ .user = 0 });
    const a = try textOf(doc);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("    x\nabc\ndef", a);
    _ = try cmds.deleteBy(doc, &s, .grapheme, .backward, .{ .use_tab_stops = false }, .{ .user = 0 });
    const b = try textOf(doc);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("   x\nabc\ndef", b);

    // Several carets plus a range, deleting right.
    try s.set(&.{ .caret(0), .{ .anchor = 5, .head = 7 }, .caret(9) }, 0);
    _ = try cmds.deleteBy(doc, &s, .grapheme, .forward, .{}, .{ .user = 0 });
    const c = try textOf(doc);
    defer gpa.free(c);
    try std.testing.expectEqualStrings("  x\nc\nef", c);

    // delete.line on the middle and last lines.
    try s.set(&.{ .caret(5), .caret(7) }, 0);
    _ = try cmds.deleteLines(doc, &s, .{ .user = 0 });
    const d = try textOf(doc);
    defer gpa.free(d);
    try std.testing.expectEqualStrings("  x", d);
}

test "movement: move then back lands on a boundary at or before" {
    const texts = [_][]const u8{
        "fn main() { return a->b + 中文; }  // 👍🏽 done\n\tnext_line(HTTPServer, x1);\r\nend",
        "مرحبا, e\u{301}! \xff\xfe ...",
    };
    for (texts) |t| {
        const doc = try Document.initBytes(gpa, @enumFromInt(1), t);
        defer doc.deinit();
        var snap = doc.snapshot();
        defer snap.release();
        // Graphemes: from every boundary, forward then back returns to it.
        var p: u64 = 0;
        while (p < t.len) {
            const f = movement.move(&snap, p, .grapheme, .forward, .{});
            try std.testing.expect(f > p);
            try std.testing.expectEqual(p, movement.move(&snap, f, .grapheme, .backward, .{}));
            p = f;
        }
        // Words: back from a forward stop lands at or before it, on a
        // start from which forward reaches the same stop.
        for ([_]Unit{ .word, .subword }) |unit| {
            p = 0;
            while (p <= t.len) : (p += 1) {
                // Code point starts only.
                if (p < t.len and t[p] & 0xc0 == 0x80) continue;
                const f = movement.move(&snap, p, unit, .forward, .{});
                try std.testing.expect(f >= p);
                const back = movement.move(&snap, f, unit, .backward, .{});
                try std.testing.expect(back <= f);
                if (back < f) try std.testing.expectEqual(f, movement.move(&snap, back, unit, .forward, .{}));
            }
        }
    }
}

test "movement: commands table" {
    try std.testing.expectEqual(@as(usize, 32), cmds.move_commands.len);
    const c = cmds.moveCommand("cursor.wordRightSelect").?;
    try std.testing.expect(c.select and c.unit == .word and c.dir == .forward);
    try std.testing.expect(cmds.moveCommand("cursor.nope") == null);
    try std.testing.expectEqual(word.WordClass.ident, word.classify('_', &.{}));
    try std.testing.expectEqual(word.WordClass.punct, word.classify('-', &.{}));
    try std.testing.expectEqual(word.WordClass.ident, word.classify('-', &.{'-'}));
}
