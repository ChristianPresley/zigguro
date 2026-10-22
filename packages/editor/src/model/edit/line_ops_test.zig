//! Line operations and the clipboard: goldens
//! (`testdata/golden/line_ops/cases.txt`, keys are `LineOp` names, `␍`
//! marks a CR) and unit tests.

const std = @import("std");
const line_ops = @import("line_ops.zig");
const clipboard = @import("clipboard.zig");
const smart = @import("smart_edit.zig");
const sel_mod = @import("selection.zig");
const golden = @import("golden_testing.zig");
const document = @import("../document.zig");
const deco = @import("../decorations/store.zig");

const gpa = std.testing.allocator;
const Selection = sel_mod.Selection;
const SelectionSet = sel_mod.SelectionSet;
const Document = document.Document;

const cr_mark = "␍";

const Harness = struct {
    doc: *Document,
    sels: SelectionSet,

    fn init(h: *Harness, marked: []const u8) !void {
        const plain = try std.mem.replaceOwned(u8, gpa, marked, cr_mark, "\r");
        defer gpa.free(plain);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        var sels: std.ArrayList(Selection) = .empty;
        defer sels.deinit(gpa);
        try golden.parseMarked(plain, &text, &sels);
        h.doc = try Document.initBytes(gpa, @enumFromInt(1), text.items);
        errdefer h.doc.deinit();
        h.sels = try .init(gpa, .caret(0));
        if (sels.items.len > 0) try h.sels.set(sels.items, sels.items.len - 1);
    }

    fn deinit(h: *Harness) void {
        h.sels.deinit();
        h.doc.deinit();
    }

    fn render(h: *Harness) ![]u8 {
        const text = try h.doc.tree.copyRange(gpa, .{ .start = 0, .end = h.doc.len() });
        defer gpa.free(text);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try golden.renderMarked(text, h.sels.slice(), &out);
        return std.mem.replaceOwned(u8, gpa, out.items, "\r", cr_mark);
    }
};

fn runScenario(_: void, sc: golden.Scenario) ![]u8 {
    var h: Harness = undefined;
    try h.init(sc.before);
    defer h.deinit();
    var it = std.mem.tokenizeAny(u8, sc.keys, " \n");
    while (it.next()) |k| {
        const op = std.meta.stringToEnum(line_ops.LineOp, k) orelse return error.UnknownOp;
        _ = try line_ops.lineOp(h.doc, &h.sels, op, .{});
    }
    return h.render();
}

test "line_ops: golden" {
    try golden.runGolden("testdata/golden/line_ops/cases.txt", 40, {}, runScenario);
}

fn expectOp(before: []const u8, op: line_ops.LineOp, after: []const u8) !void {
    var h: Harness = undefined;
    try h.init(before);
    defer h.deinit();
    const v = h.doc.version;
    _ = try line_ops.lineOp(h.doc, &h.sels, op, .{});
    try std.testing.expect(h.doc.version <= v + 1);
    const got = try h.render();
    defer gpa.free(got);
    try std.testing.expectEqualStrings(after, got);
}

test "line_ops: move line keeps decorations" {
    var h: Harness = undefined;
    try h.init("a\nbb¦\ncc\n");
    defer h.deinit();
    var store: deco.DecorationStore = .init(gpa, h.doc);
    defer store.deinit();
    _ = try h.doc.subscribe(store.listener());
    const owner = try store.registerOwner("test", 0);
    // "bb" on line 1.
    const id = try store.add(.{ .range = .{ .start = 2, .end = 4 }, .owner = owner, .kind = .{ .highlight = @enumFromInt(1) } });
    _ = try line_ops.lineOp(h.doc, &h.sels, .move_up, .{});
    const text = try h.doc.tree.copyRange(gpa, .{ .start = 0, .end = h.doc.len() });
    defer gpa.free(text);
    try std.testing.expectEqualStrings("bb\na\ncc\n", text);
    const r = store.get(id).?.range;
    try std.testing.expectEqual(@as(u64, 0), r.start);
    try std.testing.expectEqual(@as(u64, 2), r.end);
    _ = try line_ops.lineOp(h.doc, &h.sels, .move_down, .{});
    _ = try line_ops.lineOp(h.doc, &h.sels, .move_down, .{});
    const r2 = store.get(id).?.range;
    try std.testing.expectEqual(@as(u64, 5), r2.start);
    try std.testing.expectEqual(@as(u64, 7), r2.end);
}

test "line_ops: sort_unique keeps first" {
    try expectOp("«b\na\nb\nA\na»", .sort_unique, "«A\na\nb»");
    try expectOp("«c\nb\na\n»", .sort_asc, "«a\nb\nc\n»");
}

test "line_ops: upper with length change keeps selections valid" {
    try expectOp("«straße» x «ß»", .upper, "«STRASSE» x «SS»");
    try expectOp("stra¦ße", .upper, "STRA¦SSE");
    try expectOp("«ΣΑΣ»", .lower, "«σας»");
}

fn clip(pieces: []const []const u8, linewise: bool) !clipboard.Clipboard {
    const ps = try gpa.alloc([]u8, pieces.len);
    for (ps, pieces) |*d, s| d.* = try gpa.dupe(u8, s);
    return .{ .gpa = gpa, .pieces = ps, .linewise = linewise };
}

fn expectPaste(before: []const u8, cb: *const clipboard.Clipboard, ctx: smart.EditCtx, after: []const u8) !void {
    var h: Harness = undefined;
    try h.init(before);
    defer h.deinit();
    _ = try clipboard.paste(h.doc, &h.sels, cb, ctx);
    const got = try h.render();
    defer gpa.free(got);
    try std.testing.expectEqualStrings(after, got);
}

test "clipboard: distribute pieces to cursors" {
    var h: Harness = undefined;
    try h.init("«one» «two» «three»");
    defer h.deinit();
    var cb = try clipboard.copy(h.doc, &h.sels, gpa);
    defer cb.deinit();
    try std.testing.expectEqual(@as(usize, 3), cb.pieces.len);
    try std.testing.expect(!cb.linewise);
    try expectPaste("a¦\nb¦\nc¦", &cb, .{}, "aone¦\nbtwo¦\ncthree¦");
}

test "clipboard: N pieces M cursors joins" {
    var cb = try clip(&.{ "x", "y" }, false);
    defer cb.deinit();
    try expectPaste("¦ ¦ ¦", &cb, .{}, "x\ny¦ x\ny¦ x\ny¦");
    try expectPaste("a␍\n¦", &cb, .{}, "a␍\nx␍\ny¦");
}

test "clipboard: linewise paste above line" {
    var h: Harness = undefined;
    try h.init("ab¦c\nd");
    defer h.deinit();
    var cb = try clipboard.cut(h.doc, &h.sels, gpa, .{});
    defer cb.deinit();
    try std.testing.expect(cb.linewise);
    try std.testing.expectEqualStrings("abc\n", cb.pieces[0]);
    const got = try h.render();
    defer gpa.free(got);
    try std.testing.expectEqualStrings("¦d", got);
    try expectPaste("x\ny¦y", &cb, .{}, "x\nabc\ny¦y");
    // A selection is replaced as usual.
    try expectPaste("«x»", &cb, .{}, "abc\n¦");
}

test "clipboard: reindent on paste tabs→spaces" {
    var cb = try clip(&.{"\tif (a) {\n\t\tb();\n\t}\n"}, true);
    defer cb.deinit();
    const ctx: smart.EditCtx = .{ .reindent_on_paste = true };
    try expectPaste("    x¦", &cb, ctx, "    if (a) {\n        b();\n    }\n    x¦");
    var mid = try clip(&.{"f(\n\t\t\ta,\n\t\t\tb)"}, false);
    defer mid.deinit();
    try expectPaste("  y = ¦", &mid, ctx, "  y = f(\n  a,\n  b)¦");
}

test "clipboard: platform encode/decode round-trip" {
    var cb = try clip(&.{ "a\n", "b\n" }, true);
    defer cb.deinit();
    var pc = try clipboard.encodePlatform(&cb, gpa);
    defer pc.deinit(gpa);
    try std.testing.expectEqualStrings("a\nb\n", pc.text);
    var back = try clipboard.decodePlatform(pc.text, pc.private, gpa);
    defer back.deinit();
    try std.testing.expect(back.linewise);
    try std.testing.expectEqual(@as(usize, 2), back.pieces.len);
    try std.testing.expectEqualStrings("b\n", back.pieces[1]);
    // Another app replaced the text: the private pieces are ignored.
    var other = try clipboard.decodePlatform("zzz", pc.private, gpa);
    defer other.deinit();
    try std.testing.expect(!other.linewise);
    try std.testing.expectEqualStrings("zzz", other.pieces[0]);
    var bad = try clipboard.decodePlatform("q", "{not json", gpa);
    defer bad.deinit();
    try std.testing.expectEqualStrings("q", bad.pieces[0]);
}
