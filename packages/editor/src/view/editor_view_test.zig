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

test "view: key hook sees keys first and can consume them" {
    var f: Fx = undefined;
    try f.init("a");
    defer f.deinit();
    const Hook = struct {
        seen: u32 = 0,
        fn onKey(ctx: *anyopaque, _: *EditorView, k: zg_gui.input.event.KeyPress) bool {
            const h: *@This() = @ptrCast(@alignCast(ctx));
            h.seen += 1;
            return k.key == .tab;
        }
    };
    var h: Hook = .{};
    f.view.key_hook = .{ .ctx = &h, .f = Hook.onKey };
    f.view.setSelection(.caret(1));
    // Tab is consumed (no indent); Enter falls through to the editor.
    f.press(.{ .key = .tab });
    try f.expectText("a");
    f.press(.{ .key = .enter });
    try f.expectText("a\n");
    // Presses only; releases are not offered.
    try testing.expectEqual(@as(u32, 2), h.seen);
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

test "view: undoing back to the saved text makes the document clean" {
    var f: Fx = undefined;
    try f.init("abc");
    defer f.deinit();
    try testing.expect(!f.doc.isDirty());
    f.t.typeText("x");
    try testing.expect(f.doc.isDirty());
    f.press(.{ .key = .key_z, .mods = .{ .ctrl = true } });
    try f.expectText("abc");
    try testing.expect(!f.doc.isDirty());
    f.press(.{ .key = .key_y, .mods = .{ .ctrl = true } });
    try testing.expect(f.doc.isDirty());

    // A change from outside the view's history (an agent edit) keeps the
    // document dirty even when the view's undo is back at the saved state.
    f.press(.{ .key = .key_z, .mods = .{ .ctrl = true } });
    try testing.expect(!f.doc.isDirty());
    f.t.typeText("y");
    var cs = try cs_mod.ChangeSet.fromEdits(gpa, f.doc.len(), &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "agent " }});
    defer cs.deinit();
    try f.doc.applyChangeSet(&cs, .{ .agent = 1 });
    f.press(.{ .key = .key_z, .mods = .{ .ctrl = true } });
    try testing.expect(f.doc.isDirty());
}

test "view: on_caret reports caret moves, not every repaint" {
    var f: Fx = undefined;
    try f.init("one\ntwo");
    defer f.deinit();
    var calls: u32 = 0;
    f.view.on_caret = .{ .ctx = &calls, .f = struct {
        fn bump(ctx: *anyopaque, _: *EditorView) void {
            const n: *u32 = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    }.bump };
    f.press(.{ .key = .arrow_right });
    try testing.expectEqual(@as(u32, 1), calls);
    f.press(.{ .key = .arrow_down });
    try testing.expectEqual(@as(u32, 2), calls);
    // A repaint or a scroll without a caret move reports nothing.
    f.t.win.markAllDirty();
    _ = f.t.settle();
    try testing.expectEqual(@as(u32, 2), calls);
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

test "view: selections become PRIMARY; middle click pastes it" {
    var f: Fx = undefined;
    try f.init("hello world\nsecond line\n");
    defer f.deinit();
    f.t.app.has_primary = true;
    // A double click selects "world" and publishes it on release.
    try f.clickAt(0, 7, 2, no_mods);
    try testing.expectEqualStrings("world", f.t.app.primary.get());
    try testing.expectEqualStrings("", f.t.app.clipboard.get());
    // Shift+End from a caret selects to the end of the line.
    try f.clickAt(1, 7, 1, no_mods);
    f.press(.{ .key = .end, .mods = .{ .shift = true } });
    try testing.expectEqualStrings("line", f.t.app.primary.get());

    // Middle click at (0, 0) pastes PRIMARY there, one undo step.
    f.t.app.primary.replace(gpa, ">> ");
    const p = try f.pointAt(0, 0);
    f.t.win.dispatch(.{ .pointer_down = .{ .pos = p, .button = .middle } });
    f.t.win.dispatch(.{ .pointer_up = .{ .pos = p, .button = .middle } });
    _ = f.t.settle();
    try f.expectText(">> hello world\nsecond line\n");
    f.press(.{ .key = .key_z, .mods = .{ .ctrl = true } });
    try f.expectText("hello world\nsecond line\n");
}

test "view: alt-click adds carets that type and paste together" {
    var f: Fx = undefined;
    try f.init("a\nb\nc");
    defer f.deinit();
    try f.clickAt(0, 1, 1, no_mods);
    try f.clickAt(1, 1, 1, .{ .key = .unknown, .mods = .{ .alt = true } });
    try f.clickAt(2, 1, 1, .{ .key = .unknown, .mods = .{ .alt = true } });
    try testing.expectEqual(@as(usize, 3), f.view.selections().len);
    f.t.typeText("!");
    try f.expectText("a!\nb!\nc!");
    // One clipboard line per caret.
    f.t.app.clipboard.replace(gpa, "1\n2\n3");
    f.press(.{ .key = .key_v, .mods = .{ .ctrl = true } });
    try f.expectText("a!1\nb!2\nc!3");
    f.press(.{ .key = .escape });
    try testing.expectEqual(@as(usize, 1), f.view.selections().len);
}

test "view: multi-cursor keys run the model's commands" {
    var f: Fx = undefined;
    try f.init("foo bar\nfoo baz\nfoo");
    defer f.deinit();
    // Ctrl+D from a caret selects the word, then its next occurrences.
    f.view.setSelection(.caret(1));
    const ctrl_d: zg_gui.input.event.KeyPress = .{ .key = .key_d, .mods = .{ .ctrl = true } };
    f.press(ctrl_d);
    f.press(ctrl_d);
    try testing.expectEqual(@as(usize, 2), f.view.selections().len);
    // Ctrl+U takes the last one back.
    f.press(.{ .key = .key_u, .mods = .{ .ctrl = true } });
    try testing.expectEqual(@as(usize, 1), f.view.selections().len);
    // Ctrl+Shift+L: every occurrence; typing replaces them all.
    f.press(.{ .key = .key_l, .mods = .{ .ctrl = true, .shift = true } });
    try testing.expectEqual(@as(usize, 3), f.view.selections().len);
    f.t.typeText("qux");
    try f.expectText("qux bar\nqux baz\nqux");
    f.press(.{ .key = .escape });
    try testing.expectEqual(@as(usize, 1), f.view.selections().len);

    // Ctrl+Alt+Down adds a caret on the next line, same column.
    f.view.setSelection(.caret(2));
    f.press(.{ .key = .arrow_down, .mods = .{ .ctrl = true, .alt = true } });
    try testing.expectEqual(@as(usize, 2), f.view.selections().len);
    f.t.typeText("_");
    try f.expectText("qu_x bar\nqu_x baz\nqux");

    // Alt+Shift+I splits a multi-line range into one per line.
    f.view.selectAll();
    f.press(.{ .key = .key_i, .mods = .{ .alt = true, .shift = true } });
    try testing.expectEqual(@as(usize, 3), f.view.selections().len);
}

test "view: alt-shift drag selects a column" {
    var f: Fx = undefined;
    try f.init("abcd\nefgh\nij");
    defer f.deinit();
    const from = try f.pointAt(0, 1);
    const to = try f.pointAt(2, 3);
    const mods = (zg_gui.input.event.KeyPress{ .key = .unknown, .mods = .{ .alt = true, .shift = true } }).mods;
    f.t.win.dispatch(.{ .pointer_move = .{ .pos = from } });
    f.t.win.dispatch(.{ .pointer_down = .{ .pos = from, .clicks = 1, .mods = mods } });
    f.t.win.dispatch(.{ .pointer_move = .{ .pos = to } });
    f.t.win.dispatch(.{ .pointer_up = .{ .pos = to, .clicks = 1, .mods = mods } });
    _ = f.t.settle();
    const sels = f.view.selections();
    try testing.expectEqual(@as(usize, 3), sels.len);
    try testing.expectEqual(@as(u64, 1), sels[0].start());
    try testing.expectEqual(@as(u64, 3), sels[0].end());
    // The short last row stops at its end.
    try testing.expectEqual(@as(u64, 11), sels[2].start());
    try testing.expectEqual(@as(u64, 12), sels[2].end());
    f.t.typeText("-");
    try f.expectText("a-d\ne-h\ni-");
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

test "view: squiggles, gutter marks and the overview ruler paint; new decorations repaint" {
    var f: Fx = undefined;
    try f.init("const x = 1;\nvar y = 2;\n");
    defer f.deinit();
    var store = deco_store.DecorationStore.init(gpa, f.doc);
    defer store.deinit();
    const owner = try store.registerOwner("lsp.diagnostics", 10);
    const Colours = struct {
        fn of(_: ?*anyopaque, s: deco_store.StyleRef) ?zg_gui.core.Color {
            return switch (@intFromEnum(s)) {
                1 => .hex(0xff0102),
                2 => .hex(0x01ff03),
                3 => .hex(0x0104ff),
                else => null,
            };
        }
    };
    f.view.decorations = &store;
    f.view.styles = .{ .color = Colours.of };
    f.t.win.markAllDirty();
    _ = f.t.settle();
    try testing.expect(std.mem.indexOf(u8, f.t.paintSnapshot(), "#ff0102ff") == null);
    // Added after the last paint: the next frame repaints (the store's
    // generation is in the paint hash).
    _ = try store.add(.{ .range = .{ .start = 6, .end = 7 }, .owner = owner, .kind = .{ .underline = .{ .kind = .squiggle, .style = @enumFromInt(1) } } });
    _ = try store.add(.{ .range = .{ .start = 13, .end = 16 }, .owner = owner, .kind = .{ .gutter = .{ .icon = 1, .style = @enumFromInt(2) } } });
    _ = try store.add(.{ .range = .{ .start = 13, .end = 16 }, .owner = owner, .kind = .{ .overview = .{ .style = @enumFromInt(3) } } });
    _ = try store.add(.{ .range = .{ .start = 17, .end = 18 }, .owner = owner, .kind = .{ .underline = .{ .kind = .dotted, .style = @enumFromInt(1) } } });
    _ = try store.add(.{ .range = .{ .start = 0, .end = 5 }, .owner = owner, .kind = .{ .text_style = @enumFromInt(9) } });
    f.t.win.markAllDirty();
    _ = f.t.settle();
    const snap = f.t.paintSnapshot();
    try testing.expect(std.mem.indexOf(u8, snap, "#ff0102ff") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "#01ff03ff") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "#0104ffff") != null);
    f.view.decorations = null;
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

test "view: smart typing closes pairs, types over closers and indents" {
    var f: Fx = undefined;
    try f.init("");
    defer f.deinit();
    var reg = try zg_syntax.defaultRegistry(gpa);
    defer reg.deinit(gpa);
    var ds = try syntax_mod.DocumentSyntax.init(gpa, reg.get(.zig).?, &reg, &f.doc.tree, f.doc.version);
    defer ds.deinit();
    f.view.syntax = &ds;
    defer f.view.syntax = null;

    for ("fn m(") |c| f.t.typeText(&.{c});
    try f.expectText("fn m()");
    try testing.expectEqual(@as(u64, 5), f.head());
    // Backspace takes the auto-inserted pair as one.
    f.press(.{ .key = .backspace });
    try f.expectText("fn m");
    f.t.typeText("(");
    f.t.typeText(")");
    try f.expectText("fn m()");
    try testing.expectEqual(@as(u64, 6), f.head());
    for (" {") |c| f.t.typeText(&.{c});
    try f.expectText("fn m() {}");
    // Enter between the braces opens an indented line.
    f.press(.{ .key = .enter });
    try f.expectText("fn m() {\n    \n}");
    try testing.expectEqual(@as(u64, 13), f.head());
    // Each smart edit is one undo step.
    f.press(.{ .key = .key_z, .mods = .{ .ctrl = true } });
    try f.expectText("fn m() {}");
    // Inside a string, quotes and brackets type as themselves.
    f.view.setSelection(.caret(f.doc.len()));
    for ("\"(") |c| f.t.typeText(&.{c});
    try f.expectText("fn m() {}\"(\"");
}

test "view: smart typing indents with the unit the file uses" {
    var f: Fx = undefined;
    try f.init("a {\n\tb\n}\n");
    defer f.deinit();
    try testing.expect(f.view.indent_unit.?.tabs);
    f.view.setSelection(.caret(3));
    f.press(.{ .key = .enter });
    try f.expectText("a {\n\t\n\tb\n}\n");
    // Off: Enter keeps the line's indentation only.
    f.view.opts.smart_typing = false;
    f.view.setSelection(.caret(0));
    f.t.typeText("(");
    try f.expectText("(a {\n\t\n\tb\n}\n");
}

test "view: a Vim mode gets keys first" {
    var f: Fx = undefined;
    try f.init("hello world");
    defer f.deinit();
    const modes = @import("../modes.zig");
    var vs: modes.VimState = .init(gpa);
    defer vs.deinit();
    f.view.mode = vs.handler();
    defer f.view.mode = null;
    try testing.expectEqual(modes.mode.CaretShape.block, f.view.caretShape());

    // Normal mode: `x` deletes, `w` moves a word, `dw` deletes one.
    f.t.typeText("x");
    try f.expectText("ello world");
    f.t.typeText("w");
    try testing.expectEqual(@as(u64, 5), f.head());
    f.t.typeText("d");
    try testing.expectEqual(modes.mode.CaretShape.half_block, f.view.caretShape());
    f.t.typeText("w");
    try f.expectText("ello ");
    // Insert mode types; Escape leaves it.
    f.t.typeText("I");
    try testing.expectEqualStrings("-- INSERT --", f.view.modeStatus());
    try testing.expectEqual(modes.mode.CaretShape.bar, f.view.caretShape());
    f.t.typeText("h");
    try f.expectText("hello ");
    f.press(.{ .key = .escape });
    try testing.expectEqualStrings("", f.view.modeStatus());
    // `u` undoes the insert as one step.
    f.t.typeText("u");
    try f.expectText("ello ");
    // Without the mode, typing inserts again.
    f.view.mode = null;
    f.view.setSelection(.caret(0));
    f.t.typeText("x");
    try f.expectText("xello ");
}

/// Records the blocks a `BlockPainter` was asked to paint.
const BlockLog = struct {
    seen: [8]view_mod.BlockInfo = undefined,
    rects: [8]zg_gui.core.Rect = undefined,
    n: usize = 0,

    fn paint(ctx: ?*anyopaque, _: *zg_gui.paint.PaintCx, rect: zg_gui.core.Rect, b: view_mod.BlockInfo) void {
        const l: *BlockLog = @ptrCast(@alignCast(ctx.?));
        if (l.n == l.seen.len) return;
        l.seen[l.n] = b;
        l.rects[l.n] = rect;
        l.n += 1;
    }
};

test "view: block decorations take rows, follow edits and give their slot" {
    var f: Fx = undefined;
    try f.init("one\ntwo\nthree\nfour\n");
    defer f.deinit();
    var store = deco_store.DecorationStore.init(gpa, f.doc);
    defer store.deinit();
    const sub = try f.doc.subscribe(store.listener());
    defer f.doc.unsubscribe(sub);
    const bar = try store.registerOwner("inline-edit", 0);
    // A two-row bar above "three" (offset 8).
    try store.setOwnerDecorations(bar, f.doc.version, &.{.{ .range = .{ .start = 8, .end = 8 }, .owner = bar, .stick = .point_left, .kind = .{ .block_above = .{ .rows = 2, .payload = 7 } } }});
    var log: BlockLog = .{};
    f.view.decorations = &store;
    f.view.block_painter = .{ .ctx = &log, .paint = BlockLog.paint };
    f.t.win.markAllDirty();
    _ = f.t.settle();
    const lh = f.view.lineHeight();
    try testing.expectEqual(@as(f32, 1) * lh, f.view.lineTop(1));
    try testing.expectEqual(@as(f32, 4) * lh, f.view.lineTop(2));
    try testing.expectEqual(@as(f32, 2) * lh, f.view.blocksTop(2));
    try testing.expectEqual(@as(f32, 5) * lh, f.view.posOf(14).y);
    // The slot sits between "two" and "three", across the text area.
    const slot = f.view.blockRect(bar, 7).?;
    try testing.expectEqual(2 * lh, slot.y);
    try testing.expectEqual(2 * lh, slot.h);
    try testing.expectEqual(f.view.gutter_w, slot.x);
    try testing.expect(f.view.blockRect(bar, 8) == null);
    // The painter was asked for it.
    try testing.expectEqual(@as(usize, 1), log.n);
    try testing.expectEqual(@as(u64, 7), log.seen[0].payload);
    try testing.expect(log.seen[0].above);
    // Clicks below the bar land on "three"; in it, on the line before.
    try f.clickAt(4, 1, 1, no_mods);
    try testing.expectEqual(@as(u64, 9), f.head());
    try testing.expectEqual(@as(u64, 1), f.view.lineAtY(2.5 * lh));
    // Typing above moves the bar with its line.
    f.view.setSelection(.caret(0));
    f.t.typeText("zero\n");
    try testing.expectEqual(@as(f32, 3) * lh, f.view.blockRect(bar, 7).?.y);
    // Resizing keeps the slot: same owner and payload.
    try store.setOwnerDecorations(bar, f.doc.version, &.{.{ .range = .{ .start = 13, .end = 13 }, .owner = bar, .stick = .point_left, .kind = .{ .block_above = .{ .rows = 4, .payload = 7 } } }});
    try testing.expectEqual(4 * lh, f.view.blockRect(bar, 7).?.h);
    try testing.expectEqual(@as(f32, 7) * lh, f.view.lineTop(3));
}

test "view: revealRange keeps a bar above the selection in view" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (0..100) |i| try buf.print(gpa, "line {d}\n", .{i});
    var f: Fx = undefined;
    try f.init(buf.items);
    defer f.deinit();
    var store = deco_store.DecorationStore.init(gpa, f.doc);
    defer store.deinit();
    const bar = try store.registerOwner("inline-edit", 0);
    f.view.decorations = &store;
    f.view.scrollToLine(40);
    const at = f.view.lineRange(40).start;
    try store.setOwnerDecorations(bar, f.doc.version, &.{.{ .range = .{ .start = at, .end = at }, .owner = bar, .stick = .point_left, .kind = .{ .block_above = .{ .rows = 2, .payload = 1 } } }});
    // The bar pushed line 40 down; the view still starts at the old y,
    // which is now inside the bar's lines.
    f.view.revealRange(f.view.lineRange(40));
    try testing.expectEqual(f.view.blocksTop(40), f.view.scroll.y);
    try testing.expect(f.view.blockRect(bar, 1).?.y >= 0);
}

test "view: inline texts shift the text after them" {
    var f: Fx = undefined;
    try f.init("abc def\n");
    defer f.deinit();
    var store = deco_store.DecorationStore.init(gpa, f.doc);
    defer store.deinit();
    const ghost = try store.registerOwner("ghost", 0);
    _ = try store.add(.{ .range = .{ .start = 3, .end = 3 }, .owner = ghost, .stick = .point_left, .kind = .{ .inline_after = .{ .text = "XY", .style = @enumFromInt(0) } } });
    f.view.decorations = &store;
    f.t.win.markAllDirty();
    _ = f.t.settle();
    const cw = f.t.mono.system().advance(f.view.textStyle(), ' ');
    // The caret at 3 stays before the inlay; 4 is after it.
    try testing.expectEqual(3 * cw, f.view.posOf(3).x);
    try testing.expectEqual(6 * cw, f.view.posOf(4).x);
    // A click on the inlay's right half lands after it, on the text.
    try testing.expectEqual(@as(u64, 4), f.view.offsetAt(.{ .x = 5.6 * cw, .y = 1 }));
    try testing.expectEqual(@as(u64, 3), f.view.offsetAt(.{ .x = 3.2 * cw, .y = 1 }));
    // Drawn in the faded text colour (no style resolver).
    const c = f.t.app.theme.color(.fg).fade(0.55);
    var buf: [16]u8 = undefined;
    const hex = try std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b, c.a });
    try testing.expect(std.mem.indexOf(u8, f.t.paintSnapshot(), hex) != null);
}

test "view: focusEditor takes focus back from another widget" {
    var f: Fx = undefined;
    try f.init("abc\n");
    defer f.deinit();
    const ed = f.view.ui_node;
    try testing.expect(!ed.isNone());
    f.t.win.setFocus(.none, false);
    try testing.expect(!f.t.win.focus.eql(ed));
    f.view.focusEditor();
    try testing.expect(f.t.win.focus.eql(ed));
}

/// A text system that shapes: every grapheme is 10 px wide and a
/// combining acute (U+0301) joins the character before it, so the only
/// caret stops are at grapheme starts.
const ShapingText = struct {
    stops: [64]zg_gui.paint.text.CaretStop = undefined,
    calls: u32 = 0,

    fn system(s: *ShapingText) zg_gui.paint.TextSystem {
        return .{ .ptr = s, .vtable = &.{ .metrics = metrics, .advance = advance, .glyph = glyph, .shape = shape, .carets = carets } };
    }

    fn metrics(_: *anyopaque, _: zg_gui.paint.text.TextStyle) zg_gui.paint.text.LineMetrics {
        return .{ .ascent = 12, .descent = 4, .line_h = 16 };
    }

    fn advance(_: *anyopaque, _: zg_gui.paint.text.TextStyle, cp: u21) f32 {
        return if (cp == 0x301) 0 else 10;
    }

    fn glyph(_: *anyopaque, _: zg_gui.paint.text.TextStyle, _: u21, _: zg_gui.core.Vec2) ?zg_gui.paint.canvas.GlyphQuad {
        return null;
    }

    fn shape(_: *anyopaque, _: zg_gui.paint.text.TextStyle, _: []const u8) ?zg_gui.paint.text.Shaped {
        return .{ .glyphs = &.{}, .width = 0 };
    }

    fn carets(p: *anyopaque, _: zg_gui.paint.text.TextStyle, s: []const u8, _: f32) ?[]const zg_gui.paint.text.CaretStop {
        const self: *ShapingText = @ptrCast(@alignCast(p));
        self.calls += 1;
        var n: usize = 0;
        var x: f32 = 0;
        var it = (std.unicode.Utf8View.init(s) catch return null).iterator();
        var i: usize = 0;
        while (it.nextCodepointSlice()) |cs| : (i += cs.len) {
            const cp = std.unicode.utf8Decode(cs) catch 0xfffd;
            if (cp == 0x301) continue;
            self.stops[n] = .{ .offset = @intCast(i), .x = x };
            n += 1;
            x += 10;
        }
        self.stops[n] = .{ .offset = @intCast(s.len), .x = x };
        return self.stops[0 .. n + 1];
    }
};

test "view: shaped rows place carets at grapheme stops" {
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "e\u{301}xy");
    defer doc.deinit();
    const v = try EditorView.init(gpa, doc, .{});
    defer v.deinit();
    var sh: ShapingText = .{};
    v.text_sys = sh.system();
    const row = "e\u{301}xy";
    // Byte 1 is inside the first grapheme: its caret is the grapheme's.
    try testing.expectEqual(@as(f32, 0), v.xInLine(row, 1));
    try testing.expectEqual(@as(f32, 10), v.xInLine(row, 3));
    try testing.expectEqual(@as(f32, 30), v.xInLine(row, row.len));
    // Hit testing never lands inside a grapheme.
    try testing.expectEqual(@as(usize, 3), v.colAt(row, 8));
    try testing.expectEqual(@as(usize, 0), v.colAt(row, 4));
    try testing.expectEqual(@as(usize, row.len), v.colAt(row, 99));
    // The row's stops are computed once.
    try testing.expectEqual(@as(u32, 1), sh.calls);
    // Unshaped, the advances add up per codepoint.
    v.opts.shape_text = false;
    try testing.expectEqual(@as(f32, 10), v.xInLine(row, 1));
}
