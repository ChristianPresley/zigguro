//! SelectionSet normalization, multi-cursor commands, box selection and
//! the per-selection runner.

const std = @import("std");
const sel_mod = @import("selection.zig");
const mc = @import("multi_cursor.zig");
const runner = @import("runner.zig");
const document = @import("../document.zig");
const snapshot_mod = @import("../snapshot.zig");

const gpa = std.testing.allocator;
const Selection = sel_mod.Selection;
const SelectionSet = sel_mod.SelectionSet;
const Document = document.Document;
const Snapshot = snapshot_mod.Snapshot;

fn text(doc: *Document) ![]u8 {
    return doc.tree.copyRange(gpa, .{ .start = 0, .end = doc.len() });
}

/// "a..b c..d|" style rendering of the selections: `anchor..head`, a
/// caret as its offset, `+v` for virtual columns, `*` on the primary.
fn render(sels: *const SelectionSet, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (sels.slice(), 0..) |s, i| {
        if (i > 0) try w.writeByte(' ');
        if (s.isCaret()) try w.print("{d}", .{s.head}) else try w.print("{d}..{d}", .{ s.anchor, s.head });
        if (s.virtual > 0) try w.print("+{d}", .{s.virtual});
        if (i == sels.primaryIndex()) try w.writeByte('*');
    }
    return w.buffered();
}

fn expectSels(sels: *const SelectionSet, want: []const u8) !void {
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(want, try render(sels, &buf));
}

test "selection: normalize merges and keeps primary" {
    var s = try SelectionSet.init(gpa, .{ .anchor = 2, .head = 6 });
    defer s.deinit();
    try s.add(.caret(10));
    try s.add(.{ .anchor = 8, .head = 4 }); // overlaps the first, becomes primary
    try s.add(.caret(10)); // duplicate caret
    try s.add(.caret(12));
    s.setPrimary(2);
    s.normalize(.for_display);
    try expectSels(&s, "2..8* 10 12");

    // A caret touching a range end merges only for edits.
    var t = try SelectionSet.init(gpa, .{ .anchor = 0, .head = 3 });
    defer t.deinit();
    try t.add(.caret(3));
    t.normalize(.for_display);
    try expectSels(&t, "0..3 3*");
    t.normalize(.for_edit);
    try expectSels(&t, "0..3*");

    // Backward ranges keep their direction when merged.
    var u = try SelectionSet.init(gpa, .{ .anchor = 5, .head = 1 });
    defer u.deinit();
    try u.add(.{ .anchor = 7, .head = 4 });
    u.normalize(.for_display);
    try expectSels(&u, "7..1*");
}

test "selection: undo cursor op and collapse" {
    var s = try SelectionSet.init(gpa, .caret(0));
    defer s.deinit();
    try s.pushHistory();
    try s.add(.caret(4));
    try mc.collapse(&s);
    try expectSels(&s, "4*");
    try std.testing.expect(try s.undoCursorOp());
    try expectSels(&s, "0 4*");
    try std.testing.expect(try s.undoCursorOp());
    try expectSels(&s, "0*");
    try std.testing.expect(!try s.undoCursorOp());
}

test "multi_cursor: add next occurrence wraps and respects whole word" {
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "foo food foo\nFoo foo");
    defer doc.deinit();
    var s = try SelectionSet.init(gpa, .caret(10)); // inside the second "foo"
    defer s.deinit();
    try std.testing.expect(try mc.addNextOccurrence(doc, &s, .{}));
    try expectSels(&s, "9..12*");
    try std.testing.expect(try mc.addNextOccurrence(doc, &s, .{}));
    try expectSels(&s, "9..12 17..20*"); // skips "Foo" (case) and "food" (word)
    try std.testing.expect(try mc.addNextOccurrence(doc, &s, .{}));
    try expectSels(&s, "0..3* 9..12 17..20"); // wrapped
    try std.testing.expect(!try mc.addNextOccurrence(doc, &s, .{}));
    try std.testing.expect(try s.undoCursorOp());
    try expectSels(&s, "9..12 17..20*");

    // From a selection, matching is substring and case-insensitive by default.
    var t = try SelectionSet.init(gpa, .{ .anchor = 0, .head = 3 });
    defer t.deinit();
    try std.testing.expect(try mc.addNextOccurrence(doc, &t, .{}));
    try expectSels(&t, "0..3 4..7*");
    try std.testing.expect(try mc.skipOccurrence(doc, &t, .{}));
    try expectSels(&t, "0..3 9..12*");
    try std.testing.expect(try mc.addNextOccurrence(doc, &t, .{ .case_sensitive = true }));
    try expectSels(&t, "0..3 9..12 17..20*");

    // No wrap: stop at the end.
    var u = try SelectionSet.init(gpa, .{ .anchor = 17, .head = 20 });
    defer u.deinit();
    try std.testing.expect(!try mc.addNextOccurrence(doc, &u, .{ .wrap = false, .case_sensitive = true }));
}

test "multi_cursor: select all occurrences 10k" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    for (0..10_000) |i| try src.print(gpa, "item{d} x;\n", .{i % 7});
    const doc = try Document.initBytes(gpa, @enumFromInt(1), src.items);
    defer doc.deinit();
    var s = try SelectionSet.init(gpa, .caret(src.items.len - 2)); // on the last "x"
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 10_000), try mc.selectAllOccurrences(doc, &s, .{}));
    try std.testing.expectEqual(@as(usize, 10_000), s.count());
    try std.testing.expectEqual(@as(u32, 9_999), s.primaryIndex());
    for (s.slice()) |x| try std.testing.expectEqualStrings("x", src.items[x.start()..x.end()]);

    // Typing replaces every occurrence in one change.
    const v = doc.version;
    _ = try runner.typeText(doc, &s, "yy", .{ .user = 0 });
    try std.testing.expectEqual(v + 1, doc.version);
    const out = try text(doc);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 10_000), std.mem.count(u8, out, " yy;"));
    for (s.slice()) |x| try std.testing.expect(x.isCaret() and std.mem.eql(u8, out[x.head - 2 .. x.head], "yy"));
}

test "multi_cursor: add cursor above and below keeps the display column" {
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "abcdef\n\tx\nab\n\xe4\xb8\xadx");
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.release();
    var s = try SelectionSet.init(gpa, .caret(4)); // column 4
    defer s.deinit();
    try std.testing.expect(try mc.addCursorVertical(&snap, &s, .down, .{ .tab_size = 4 }));
    try expectSels(&s, "4 8*"); // after the tab (column 4)
    try std.testing.expect(try mc.addCursorVertical(&snap, &s, .down, .{ .tab_size = 4 }));
    try expectSels(&s, "4 8 12*"); // end of "ab"
    try std.testing.expect(!try mc.addCursorVertical(&snap, &s, .up, .{}));
    try std.testing.expect(try s.undoCursorOp());
    try expectSels(&s, "4 8*");
}

test "multi_cursor: split selection into lines" {
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "one\ntwo\nthree\n");
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.release();
    var s = try SelectionSet.init(gpa, .{ .anchor = 1, .head = 14 }); // to column 0 of the last line
    defer s.deinit();
    try mc.splitIntoLines(&snap, &s);
    try expectSels(&s, "1..3 4..7 8..13*");
}

/// Renders a box selection over `src` for tab sizes 2, 4 and 8.
fn boxGolden(src: []const u8, b: mc.BoxSelection, want: []const []const u8) !void {
    const doc = try Document.initBytes(gpa, @enumFromInt(1), src);
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.release();
    for ([_]u32{ 2, 4, 8 }, want) |tab, w| {
        var m: mc.ColumnMap = .{ .gpa = gpa, .snap = &snap, .o = .{ .tab_size = tab } };
        defer m.deinit();
        var s = try SelectionSet.init(gpa, .caret(0));
        defer s.deinit();
        try mc.boxToSelections(b, m.query(), &s);
        var buf: [4096]u8 = undefined;
        const got = try render(&s, &buf);
        std.testing.expectEqualStrings(w, got) catch |e| {
            std.debug.print("tab {d}\n", .{tab});
            return e;
        };
    }
}

test "multi_cursor: box selection over tabs and CJK" {
    // Lines: "a\tbc", "\xe4\xb8\xad\xe6\x96\x87xy" (two wide chars), "abcdefgh", "\t\tz".
    const src = "a\tbc\n\xe4\xb8\xad\xe6\x96\x87xy\nabcdefgh\n\t\tz";
    // Columns 1 to 5 over all four lines. A column inside a tab or wide
    // character snaps to its nearer edge (halfway goes right).
    try boxGolden(src, .{ .anchor = .{ .row = 0, .col_px = 1 }, .head = .{ .row = 3, .col_px = 5 } }, &.{
        // tab 2: a|tab(1-2)|b|c, then 1 virtual column; tabs 0-2, 2-4, z at 4.
        "1..4 8..12 15..19 24..26*",
        // tab 4: tab spans 1-4, so column 5 is c; column 1 and 5 round into the tabs on line 3.
        "1..3 8..12 15..19 23..24*",
        // tab 8: column 5 is past the middle of the tab (1-8).
        "1..2 8..12 15..19 23..24*",
    });
    // Right to left, bottom to top: backward ranges, primary on the head's row.
    try boxGolden(src, .{ .anchor = .{ .row = 2, .col_px = 6 }, .head = .{ .row = 1, .col_px = 2 } }, &.{
        "13..8* 20..16",
        "13..8* 20..16",
        "13..8* 20..16",
    });
}

test "multi_cursor: typing in box with virtual space pads" {
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "abcdef\nab\n\nabcd");
    defer doc.deinit();
    var snap = doc.snapshot();
    var m: mc.ColumnMap = .{ .gpa = gpa, .snap = &snap };
    defer m.deinit();
    var s = try SelectionSet.init(gpa, .caret(0));
    defer s.deinit();
    try mc.boxToSelections(.{ .anchor = .{ .row = 0, .col_px = 5 }, .head = .{ .row = 3, .col_px = 5 }, .virtual_space = true }, m.query(), &s);
    snap.release();
    try expectSels(&s, "5 9+3 10+5 15+1*");
    _ = try runner.typeText(doc, &s, "|", .{ .user = 0 });
    const out = try text(doc);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("abcde|f\nab   |\n     |\nabcd |", out);
    try expectSels(&s, "6 14 21 28*");
}

const Ctx = struct { mode: enum { overlap, wrap } };

fn overlapEdit(ctx_ptr: *anyopaque, _: *const Snapshot, sel: Selection, out: *runner.EditBuilder) anyerror!void {
    const ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));
    switch (ctx.mode) {
        // Each selection deletes 3 bytes from its caret: neighbours collide.
        .overlap => {
            _ = try out.delete(.{ .start = sel.head, .end = sel.head + 3 });
            out.select(.{ .in_edit = .{ .edit = 0 } });
        },
        // Wraps the selection in brackets with two edits, keeping it selected.
        .wrap => {
            _ = try out.insert(sel.start(), "[");
            _ = try out.insert(sel.end(), "]");
            out.select(.{ .range_in_edit = .{ .edit = 0, .anchor = 1, .head = 1 + @as(u32, @intCast(sel.end() - sel.start())) } });
        },
    }
}

test "runner: overlapping edits dropped deterministically" {
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "0123456789");
    defer doc.deinit();
    var s = try SelectionSet.init(gpa, .caret(0));
    defer s.deinit();
    try s.add(.caret(2)); // overlaps [0,3)
    try s.add(.caret(5));
    s.normalize(.for_display);
    var ctx: Ctx = .{ .mode = .overlap };
    const r = try runner.runPerSelection(doc, &s, overlapEdit, &ctx, .{ .user = 0 });
    try std.testing.expectEqual(@as(u32, 1), r.dropped);
    const out = try text(doc);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("3489", out);
    // The dropped selection is mapped (into the deleted range: its start).
    try expectSels(&s, "0 2*");
}

test "runner: cursor lands after inserted text for every selection" {
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "ab ab ab");
    defer doc.deinit();
    var s = try SelectionSet.init(gpa, .caret(0));
    defer s.deinit();
    try s.set(&.{ .caret(0), .caret(3), .caret(6), .caret(8) }, 3);
    _ = try runner.typeText(doc, &s, "xy", .{ .user = 0 });
    const out = try text(doc);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("xyab xyab xyabxy", out);
    try expectSels(&s, "2 7 12 16*");

    // Multi-edit commands place ranges inside their own edit.
    var t = try SelectionSet.init(gpa, .{ .anchor = 2, .head = 4 });
    defer t.deinit();
    try t.add(.{ .anchor = 7, .head = 9 });
    var ctx: Ctx = .{ .mode = .wrap };
    _ = try runner.runPerSelection(doc, &t, overlapEdit, &ctx, .{ .user = 0 });
    const out2 = try text(doc);
    defer gpa.free(out2);
    try std.testing.expectEqualStrings("xy[ab] xy[ab] xyabxy", out2);
    try expectSels(&t, "3..5 10..12*");
}
