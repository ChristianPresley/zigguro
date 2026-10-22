//! The editor view in a headless zg_gui window: typing, movement, mouse,
//! clipboard, undo, multiple carets, scrolling, syntax colours and
//! decorations.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_syntax = @import("zg_syntax");
const document = @import("../model/document.zig");
const cs_mod = @import("../model/edit/change_set.zig");
const syntax_mod = @import("../model/syntax.zig");
const deco_store = @import("../model/decorations/store.zig");
const view_mod = @import("editor_view.zig");
const widget = @import("widget.zig");
const colors = @import("syntax_colors.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Ui = zg_gui.Ui;
const TestApp = zg_gui.testing.TestApp;
const EditorView = view_mod.EditorView;
const Document = document.Document;

const Page = struct {
    view: *EditorView,

    pub fn build(self: *Page, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .w = .{ .pct = 100 }, .h = .{ .pct = 100 } } });
        defer ui.close();
        _ = widget.editor(ui, .{ .view = self.view });
    }
};

const Fx = struct {
    doc: *Document,
    view: *EditorView,
    page: Page,
    t: *TestApp,

    fn init(f: *Fx, initial: []const u8) !void {
        f.doc = try Document.initBytes(gpa, @enumFromInt(1), initial);
        f.view = try EditorView.init(gpa, f.doc, .{});
        f.page = .{ .view = f.view };
        f.t = try TestApp.init(gpa, .{ .root = .of(&f.page), .size = .{ .w = 400, .h = 200 } });
        _ = f.t.settle();
        try f.t.click(.{ .role = .textbox });
        f.view.setSelection(.caret(0));
        _ = f.t.settle();
    }

    fn deinit(f: *Fx) void {
        f.t.deinit();
        f.view.deinit();
        f.doc.deinit();
    }

    fn text(f: *Fx) ![]u8 {
        return f.view.allText(gpa);
    }

    fn expectText(f: *Fx, want: []const u8) !void {
        const got = try f.text();
        defer gpa.free(got);
        try testing.expectEqualStrings(want, got);
    }

    fn head(f: *Fx) u64 {
        return f.view.primarySel().head;
    }

    fn press(f: *Fx, key: zg_gui.input.event.KeyPress) void {
        f.t.win.dispatch(.{ .key = key });
        var up = key;
        up.action = .release;
        f.t.win.dispatch(.{ .key = up });
        _ = f.t.settle();
    }

    /// The node-local point of the text position (line, col) in a
    /// monospace grid.
    fn pointAt(f: *Fx, line: u32, col: u32) !zg_gui.core.Vec2 {
        const r = try f.t.rectOf(.{ .role = .textbox });
        const lh = f.view.lineHeight();
        const cw = f.t.mono.system().advance(f.view.textStyle(), ' ');
        return .{ .x = r.x + f.view.gutter_w + cw * @as(f32, @floatFromInt(col)) + 1, .y = r.y + lh * (@as(f32, @floatFromInt(line)) + 0.5) };
    }

    fn clickAt(f: *Fx, line: u32, col: u32, clicks: u8, mods: zg_gui.input.event.KeyPress) !void {
        const p = try f.pointAt(line, col);
        f.t.win.dispatch(.{ .pointer_move = .{ .pos = p } });
        f.t.win.dispatch(.{ .pointer_down = .{ .pos = p, .clicks = clicks, .mods = mods.mods } });
        f.t.win.dispatch(.{ .pointer_up = .{ .pos = p, .clicks = clicks, .mods = mods.mods } });
        _ = f.t.settle();
    }
};

const no_mods: zg_gui.input.event.KeyPress = .{ .key = .unknown };

test "view: typing, newline keeps indentation, backspace" {
    var f: Fx = undefined;
    try f.init("");
    defer f.deinit();
    f.t.typeText("fn");
    f.t.typeText(" main");
    try f.expectText("fn main");
    f.view.setSelection(.caret(0));
    f.t.typeText("    ");
    f.view.setSelection(.caret(f.doc.len()));
    f.press(.{ .key = .enter });
    f.t.typeText("x");
    try f.expectText("    fn main\n    x");
    f.press(.{ .key = .backspace });
    f.press(.{ .key = .backspace, .mods = .{ .ctrl = true } });
    try f.expectText("    fn main\n");
    try testing.expectEqual(f.doc.len(), f.head());
}

test "view: undo groups typing and redo restores it" {
    var f: Fx = undefined;
    try f.init("");
    defer f.deinit();
    f.t.typeText("a");
    f.t.typeText("b");
    f.t.typeText(" ");
    f.t.advance(2000);
    f.t.typeText("c");
    try f.expectText("ab c");
    f.press(.{ .key = .key_z, .mods = .{ .ctrl = true } });
    try f.expectText("ab ");
    f.press(.{ .key = .key_z, .mods = .{ .ctrl = true } });
    try f.expectText("");
    try testing.expectEqual(@as(u64, 0), f.head());
    f.press(.{ .key = .key_y, .mods = .{ .ctrl = true } });
    try f.expectText("ab ");
    f.press(.{ .key = .key_z, .mods = .{ .ctrl = true, .shift = true } });
    try f.expectText("ab c");
}

test "view: arrows, words, home and end" {
    var f: Fx = undefined;
    try f.init("  alpha beta\nxy\nlonger line");
    defer f.deinit();
    f.press(.{ .key = .end });
    try testing.expectEqual(@as(u64, 12), f.head());
    f.press(.{ .key = .home });
    try testing.expectEqual(@as(u64, 2), f.head());
    f.press(.{ .key = .home });
    try testing.expectEqual(@as(u64, 0), f.head());
    f.press(.{ .key = .arrow_right, .mods = .{ .ctrl = true } });
    try testing.expectEqual(@as(u64, 7), f.head());
    f.press(.{ .key = .arrow_right, .mods = .{ .ctrl = true, .shift = true } });
    try testing.expectEqual(@as(u64, 12), f.head());
    try testing.expectEqual(@as(u64, 7), f.view.primarySel().anchor);
    // Down keeps the column through a short line.
    f.press(.{ .key = .arrow_down });
    try testing.expectEqual(@as(u64, 15), f.head()); // end of "xy"
    f.press(.{ .key = .arrow_down });
    try testing.expectEqual(@as(u64, 16 + 11), f.head()); // col 12 clamps to the end of "longer line"
    f.press(.{ .key = .home, .mods = .{ .ctrl = true } });
    try testing.expectEqual(@as(u64, 0), f.head());
    f.press(.{ .key = .arrow_left });
    try testing.expectEqual(@as(u64, 0), f.head());
}

test "view: click, shift-click, double and triple click" {
    var f: Fx = undefined;
    try f.init("hello world\nsecond line\n");
    defer f.deinit();
    try f.clickAt(0, 6, 1, no_mods);
    try testing.expectEqual(@as(u64, 6), f.head());
    try f.clickAt(1, 3, 1, .{ .key = .unknown, .mods = .{ .shift = true } });
    try testing.expectEqual(@as(u64, 6), f.view.primarySel().anchor);
    try testing.expectEqual(@as(u64, 15), f.head());
    try f.clickAt(0, 2, 2, no_mods);
    try testing.expectEqual(cs_mod.Range{ .start = 0, .end = 5 }, f.view.primarySel().range());
    try f.clickAt(1, 2, 3, no_mods);
    try testing.expectEqual(cs_mod.Range{ .start = 12, .end = 24 }, f.view.primarySel().range());
}

test "view: copy, cut and paste, including whole lines" {
    var f: Fx = undefined;
    try f.init("one\ntwo\n");
    defer f.deinit();
    // Caret-only copy takes the line.
    f.press(.{ .key = .key_c, .mods = .{ .ctrl = true } });
    try testing.expectEqualStrings("one\n", f.t.app.clipboard.get());
    f.press(.{ .key = .key_x, .mods = .{ .ctrl = true } });
    try f.expectText("two\n");
    f.press(.{ .key = .key_v, .mods = .{ .ctrl = true } });
    try f.expectText("one\ntwo\n");
    f.view.selectAll();
    f.press(.{ .key = .key_x, .mods = .{ .ctrl = true } });
    try f.expectText("");
    try testing.expectEqualStrings("one\ntwo\n", f.t.app.clipboard.get());
}

test "view: alt-click adds carets that type and paste together" {
    var f: Fx = undefined;
    try f.init("a\nb\nc");
    defer f.deinit();
    try f.clickAt(0, 1, 1, no_mods);
    try f.clickAt(1, 1, 1, .{ .key = .unknown, .mods = .{ .alt = true } });
    try f.clickAt(2, 1, 1, .{ .key = .unknown, .mods = .{ .alt = true } });
    try testing.expectEqual(@as(usize, 3), f.view.sels.items.len);
    f.t.typeText("!");
    try f.expectText("a!\nb!\nc!");
    // One clipboard line per caret.
    f.t.app.clipboard.replace(gpa, "1\n2\n3");
    f.press(.{ .key = .key_v, .mods = .{ .ctrl = true } });
    try f.expectText("a!1\nb!2\nc!3");
    f.press(.{ .key = .escape });
    try testing.expectEqual(@as(usize, 1), f.view.sels.items.len);
}

test "view: edits from elsewhere move the carets" {
    var f: Fx = undefined;
    try f.init("hello");
    defer f.deinit();
    f.view.setSelection(.caret(5));
    var cs = try cs_mod.ChangeSet.fromEdits(gpa, f.doc.len(), &.{.{ .range = .{ .start = 0, .end = 0 }, .text = ">> " }});
    defer cs.deinit();
    try f.doc.applyChangeSet(&cs, .{ .agent = 1 });
    try testing.expectEqual(@as(u64, 8), f.head());
}

test "view: scrolling only draws visible rows and follows the caret" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (0..1000) |i| try buf.print(gpa, "line {d}\n", .{i});
    var f: Fx = undefined;
    try f.init(buf.items);
    defer f.deinit();
    const vis = f.view.visibleLines();
    try testing.expect(vis[1] - vis[0] < 20);
    f.press(.{ .key = .end, .mods = .{ .ctrl = true } });
    try testing.expect(f.view.visibleLines()[1] >= 999);
    try testing.expect(std.mem.indexOf(u8, f.t.paintSnapshot(), "glyphs") != null);
    f.press(.{ .key = .home, .mods = .{ .ctrl = true } });
    try testing.expectEqual(@as(f32, 0), f.view.scroll.y);
    const r = try f.t.rectOf(.{ .role = .textbox });
    f.t.win.dispatch(.{ .scroll = .{ .pos = .{ .x = r.x + 50, .y = r.y + 50 }, .dx = 0, .dy = -2 } });
    _ = f.t.settle();
    try testing.expectEqual(@as(u64, 6), f.view.visibleLines()[0]);
}

test "view: syntax colours and decorations paint" {
    var reg = try zg_syntax.defaultRegistry(gpa);
    defer reg.deinit(gpa);
    var f: Fx = undefined;
    try f.init("const x = 1; // hi\n");
    defer f.deinit();
    var ds = try syntax_mod.DocumentSyntax.init(gpa, reg.get(.zig).?, &reg, &f.doc.tree, f.doc.version);
    defer ds.deinit();
    f.view.syntax = &ds;
    var store = deco_store.DecorationStore.init(gpa, f.doc);
    defer store.deinit();
    const owner = try store.registerOwner("find", 0);
    _ = try store.add(.{ .range = .{ .start = 6, .end = 7 }, .owner = owner, .kind = .{ .highlight = @enumFromInt(1) } });
    f.view.decorations = &store;
    f.view.setSelection(.caret(0));
    f.t.win.markAllDirty();
    _ = f.t.settle();
    const snap = f.t.paintSnapshot();
    const bg = f.t.app.theme.color(.bg_base);
    const kw = colors.colorOf(colors.forBackground(bg), .keyword, .hex(0));
    var buf: [16]u8 = undefined;
    const kw_hex = try std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ kw.r, kw.g, kw.b, kw.a });
    try testing.expect(std.mem.indexOf(u8, snap, kw_hex) != null);
    // The comment has its own colour too.
    const cm = colors.colorOf(colors.forBackground(bg), .comment, .hex(0));
    const cm_hex = try std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ cm.r, cm.g, cm.b, cm.a });
    try testing.expect(std.mem.indexOf(u8, snap, cm_hex) != null);
    // Typing keeps the highlighter in step.
    f.view.setSelection(.caret(0));
    f.t.typeText("pub ");
    try testing.expectEqual(f.doc.version, ds.version);
}

test "view: the IME follows the primary caret" {
    var f: Fx = undefined;
    try f.init("first\nsecond line");
    defer f.deinit();
    const im = &f.t.win.ime;
    // Focus enabled it (the click in init).
    try testing.expect(im.enabled);

    f.press(.{ .key = .arrow_down });
    f.press(.{ .key = .end });
    const s1 = im.serial;
    try testing.expectEqualStrings("second line", im.surrounding().?.text);
    try testing.expectEqual(@as(u32, 11), im.surrounding().?.cursor_byte);
    // The caret rect is where the caret is drawn: line 2, after the text.
    const want = try f.pointAt(1, 11);
    try testing.expectApproxEqAbs(want.x, im.caret.x, 1.5);
    try testing.expect(want.y >= im.caret.y and want.y <= im.caret.y + im.caret.h);

    // End again moves nothing: nothing is resent.
    f.press(.{ .key = .end });
    try testing.expectEqual(s1, im.serial);

    f.t.typeText("!");
    try testing.expect(im.serial != s1);
    try testing.expectEqualStrings("second line!", im.surrounding().?.text);

    f.t.win.setFocus(.none, false);
    _ = f.t.settle();
    try testing.expect(!im.enabled);
}
